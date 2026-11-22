#include "common.h"
#include "CRCarplayWindow.h"
#include "CRCarAppSwitcher.h"

/*
Find the CADisplay handling the CarPlay stuff
*/
id getCarplayCADisplay(void)
{
    id carplayAVDisplay = objcInvoke(objc_getClass("AVExternalDevice"), @"currentCarPlayExternalDevice");
    if (!carplayAVDisplay)
    {
        return nil;
    }

    NSString *carplayDisplayUniqueID = objcInvoke(carplayAVDisplay, @"screenIDs")[0];
    for (id display in objcInvoke(objc_getClass("CADisplay"), @"displays"))
    {
        if ([carplayDisplayUniqueID isEqualToString:objcInvoke(display, @"uniqueId")])
        {
            return display;
        }
    }

    return nil;
}

// silently skips setters 18.x doesn't have (these run on every scene update)
static void setSceneInsets(id settings, NSString *selectorName, UIEdgeInsets insets)
{
    SEL selector = NSSelectorFromString(selectorName);
    if ([settings respondsToSelector:selector])
    {
        ((void (*)(id, SEL, UIEdgeInsets))objc_msgSend)(settings, selector, insets);
    }
}

void CRApplyCarplaySceneSettings(id settings, CRCarPlayWindow *window)
{
    if (![settings isKindOfClass:objc_getClass("UIMutableApplicationSceneSettings")])
    {
        return;
    }

    long long orientation = window ? (long long)window.orientation : (long long)UIInterfaceOrientationLandscapeLeft;
    objcInvokeIf_1(settings, @"setForeground:", YES);
    objcInvokeIf_1(settings, @"setInterfaceOrientation:", orientation);
    objcInvokeIf_1(settings, @"setDeviceOrientation:", orientation);

    if (window && window.appContainerView && [settings respondsToSelector:NSSelectorFromString(@"setFrame:")])
    {
        ((void (*)(id, SEL, CGRect))objc_msgSend)(settings, NSSelectorFromString(@"setFrame:"), [window sceneFrame]);
    }

    // the scene still describes the phone's display: drop its notch, status bar and home indicator space
    for (NSString *selectorName in @[@"setPeripheryInsets:", @"setSafeAreaInsetsPortrait:", @"setSafeAreaInsetsPortraitUpsideDown:", @"setSafeAreaInsetsLandscapeLeft:", @"setSafeAreaInsetsLandscapeRight:"])
    {
        setSceneInsets(settings, selectorName, UIEdgeInsetsZero);
    }
    SEL statusBarHeightSelector = NSSelectorFromString(@"setDefaultStatusBarHeight:forOrientation:");
    if ([settings respondsToSelector:statusBarHeightSelector])
    {
        for (long long statusBarOrientation = UIInterfaceOrientationPortrait; statusBarOrientation <= UIInterfaceOrientationLandscapeLeft; statusBarOrientation++)
        {
            ((void (*)(id, SEL, CGFloat, long long))objc_msgSend)(settings, statusBarHeightSelector, 0.0, statusBarOrientation);
        }
    }
}

@interface CRCarPlayWindow ()
// the app's supported orientations when the window last followed them
@property (nonatomic) unsigned long long lastSupportedOrientations;
@property (nonatomic, copy) NSSet *launchActions;
@end

void CRSetPadLayoutMarker(NSString *bundleIdentifier, BOOL padLayout)
{
    id proxy = bundleIdentifier ? objcInvoke_1(objc_getClass("LSApplicationProxy"), @"applicationProxyForIdentifier:", bundleIdentifier) : nil;
    NSURL *container = [proxy respondsToSelector:NSSelectorFromString(@"dataContainerURL")] ? objcInvoke(proxy, @"dataContainerURL") : nil;
    if (!container)
    {
        return;
    }
    NSString *marker = [[container.path stringByAppendingPathComponent:@"tmp"] stringByAppendingPathComponent:kCRPadLayoutMarkerName];
    if (padLayout)
    {
        [[NSFileManager defaultManager] createFileAtPath:marker contents:[NSData data] attributes:nil];
    }
    else
    {
        [[NSFileManager defaultManager] removeItemAtPath:marker error:nil];
    }
}

@implementation CRCarPlayWindow

/*
The scene belongs to the phone's (portrait-native) display, so its frame is in portrait coordinates and UIKit
rotates it by the interface orientation. Hand landscape scenes the container's size swapped so the app ends up
with the full width of the window instead of a narrow, cut-off portrait-shaped layout.
*/
- (CGRect)sceneFrame
{
    CGSize containerSize = self.appContainerView.bounds.size;
    CGFloat scale = _appScale > 0 ? _appScale : 1.0;
    containerSize = CGSizeMake(round(containerSize.width / scale), round(containerSize.height / scale));
    if (UIInterfaceOrientationIsLandscape(self.orientation))
    {
        return CGRectMake(0, 0, containerSize.height, containerSize.width);
    }
    return CGRectMake(0, 0, containerSize.width, containerSize.height);
}

- (NSString *)bundleIdentifier
{
    return objcInvoke(self.application, @"bundleIdentifier");
}

- (void)deliverActions:(NSSet *)actions
{
    id appScene = objcInvoke(objcInvoke(self.appViewController, @"sceneHandle"), @"sceneIfExists");
    if (actions.count && [appScene respondsToSelector:NSSelectorFromString(@"sendActions:")])
    {
        objcInvoke_1(appScene, @"sendActions:", actions);
    }
}

- (id)initWithBundleIdentifier:(id)identifier appFrame:(CGRect)appFrame
{
    return [self initWithBundleIdentifier:identifier appFrame:appFrame launchActions:nil];
}

- (id)initWithBundleIdentifier:(id)identifier appFrame:(CGRect)appFrame launchActions:(NSSet *)launchActions
{
    if ((self = [super init]))
    {
        _launchActions = [launchActions copy];
        _observers = [[NSMutableArray alloc] init];
        // Update this processes' preference cache
        [[CRPreferences sharedInstance] reloadPreferences];
        _nativeLook = [[CRPreferences sharedInstance] nativeCarplayLook];
        _appScale = [[CRPreferences sharedInstance] appScale];

        // Start in landscape
        self.orientation = UIInterfaceOrientationLandscapeLeft;

        self.sessionStatus = [objcInvoke([objc_getClass("CARSessionStatus") alloc], @"initForCarPlayShell") autorelease];

        self.application = objcInvoke_1(objcInvoke(objc_getClass("SBApplicationController"), @"sharedInstance"), @"applicationWithBundleIdentifier:", identifier);
        assertGotExpectedObject(self.application, @"SBApplication");

        // portrait-only apps (Spotify) draw sideways in a landscape scene
        self.lastSupportedOrientations = [self appSupportedOrientations];
        self.orientation = [self orientationFittingMask:self.lastSupportedOrientations];

        if (_drawOnMainScreen)
        {
            self.rootWindow = [[[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
            ((void (*)(id, SEL, long long, BOOL, double, BOOL))objc_msgSend)(self.rootWindow, NSSelectorFromString(@"_rotateWindowToOrientation:updateStatusBar:duration:skipCallbacks:"), 3, YES, 0.0, NO);
        }
        else
        {
            id displayConfiguration = nil;
            for (UIScreen *currentScreen in [UIScreen screens]) {
                if (objcInvokeT(currentScreen, @"_isCarScreen", BOOL)) {
                    
                    displayConfiguration = objcInvoke(currentScreen, @"fbsDisplay");
                    if (displayConfiguration) {
                        break;
                    }
                }
            }
            assertGotExpectedObject(displayConfiguration, @"FBSDisplayConfiguration");

            // Create window on the Carplay screen
            self.rootWindow = [objcInvoke_1([objc_getClass("UIRootSceneWindow") alloc], @"initWithDisplayConfiguration:", displayConfiguration) autorelease];

            if (_nativeLook)
            {
                // take the spot CarPlay gives its own apps: beside its sidebar, above its home screen (level 0)
                // and below its sidebar host, banners, Siri and alerts (5 and up, all in the CarPlay process)
                CGRect displayBounds = self.rootWindow.bounds;
                if (CGRectIsEmpty(appFrame) || !CGRectContainsRect(displayBounds, appFrame))
                {
                    // opened without CarPlay's layout (e.g. by a test tool): assume a left-hand sidebar
                    appFrame = CGRectMake(CARPLAY_SIDEBAR_WIDTH, 0, displayBounds.size.width - CARPLAY_SIDEBAR_WIDTH, displayBounds.size.height);
                }
                self.rootWindow.frame = appFrame;
                self.rootWindow.windowLevel = 1;
            }
            CRLog(@"creating %@ window on display %@ at %@", _nativeLook ? @"native" : @"overlay", objcInvoke(displayConfiguration, @"identity"), NSStringFromCGRect(self.rootWindow.frame));
        }

        // CarPlay's own apps fill their area edge to edge, square; only its sidebar is a rounded panel
        [self.rootWindow.layer setCornerRadius:(_nativeLook ? 0.0f : 13.0f)];
        [self.rootWindow.layer setMasksToBounds:YES];
        if (_nativeLook)
        {
            // CarPlay's app area is opaque, don't let its home screen show through while the app draws
            [self.rootWindow setBackgroundColor:[UIColor blackColor]];
        }
        else
        {
            [self setupWallpaperBackground];
            [self setupDock];
        }

        [self setupLiveAppView];

        // Add the user's wallpaper to the window. It will be visible when the app is in portrait mode
        CGRect rootWindowFrame = [[self rootWindow] frame];

        CGFloat dockWidth = _nativeLook ? 0.0 : CARPLAY_DOCK_WIDTH;
        self.appContainerView = [[[UIView alloc] initWithFrame:CGRectMake(dockWidth, 0, rootWindowFrame.size.width - dockWidth, rootWindowFrame.size.height)] autorelease];
        [[self appContainerView] setBackgroundColor:[UIColor clearColor]];
        [[self rootWindow] addSubview:[self appContainerView]];

        // The scene does not show a launch image, it needs to be created manually.
        [self setupLaunchImage];

        // Add the live app view
        [[self appContainerView] addSubview:objcInvoke(self.appViewController, @"view")];
        [self resizeAppViewForOrientation:self.orientation fullscreen:NO forceUpdate:YES];


        [[self rootWindow] setAlpha:0];
        [[self rootWindow] setHidden:0];

        // "unblank" the screen. This is necessary for animations/video to render when the device is locked.
        // This does not cause the screen to actually light up
        if (orig_BKSDisplayServicesSetScreenBlanked) {
            orig_BKSDisplayServicesSetScreenBlanked(0);
        }

        [UIView animateWithDuration:(_nativeLook ? 0.25 : 1.0) animations:^(void)
        {
            [[self rootWindow] setAlpha:1];
        } completion:nil];

        // Add a placeholder "this app is on the carplay screen" view onto the app on the main screen
        id currentSceneHandle = objcInvoke(self.appViewController, @"sceneHandle");
        for (id appSceneView in CRSceneViewsForSceneHandle(currentSceneHandle, self.rootWindow))
        {
            objcInvoke(appSceneView, @"drawCarplayPlaceholder");
        }

        // CarPlay tracks whether one of these windows is up, so its home button can close it
        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.carplayenable.opened" object:nil userInfo:@{@"identifier": identifier}];

        if (_nativeLook)
        {
            // nothing below is used without the dock: no alignment to follow, no fullscreen to leave
            return self;
        }

        // Add observer the user changing the Dock's Alignment via preferences
        id observer = [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserverForName:PREFERENCES_CHANGED_NOTIFICATION object:kPrefsDockAlignmentChanged queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
            // Update this processes' preference cache
            [[CRPreferences sharedInstance] reloadPreferences];
            // Redraw the dock
            [self setupDock];
            // Relayout the app view
            [self resizeAppViewForOrientation:_orientation fullscreen:_isFullscreen forceUpdate:YES];
        }];
        [_observers addObject:observer];

        _screenTapRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleScreenTapped)];
        id systemGestureManager = objcInvoke(objc_getClass("_UISystemGestureManager"), @"sharedInstance");
        id identity = objcInvoke(objcInvoke(self.rootWindow, @"displayConfiguration"), @"identity");
        objcInvoke_2(systemGestureManager, @"addGestureRecognizer:toDisplayWithIdentity:", _screenTapRecognizer, identity);
    }

    return self;
}

- (void)setupWallpaperBackground
{
//     CGRect rootWindowFrame = [[self rootWindow] frame];

//     UIImageView *wallpaperImageView = [[UIImageView alloc] initWithFrame:rootWindowFrame];
//     id defaultWallpaper = objcInvoke(objc_getClass("CRSUIWallpaperPreferences"), @"defaultWallpaper");
//     if (!defaultWallpaper) {
//         defaultWallpaper = objcInvoke(objc_getClass("CRSUISystemWallpaper"), @"defaultWallpaper");
//         assertGotExpectedObject(defaultWallpaper, @"CRSUISystemWallpaper");
//     }
//     else {
//         assertGotExpectedObject(defaultWallpaper, @"CRSUIWallpaper");
//     }

//     UIImage *wallpaperImage = objcInvoke_1(defaultWallpaper, @"wallpaperImageCompatibleWithTraitCollection:", nil);
//     [wallpaperImageView setImage:wallpaperImage];
//     UIVisualEffectView *wallpaperBlurView = [[UIVisualEffectView alloc] initWithEffect:objcInvoke_1(objc_getClass("UIBlurEffect"), @"effectWithBlurRadius:", 10.0)];
//     [wallpaperBlurView setFrame:rootWindowFrame];
//     [wallpaperImageView addSubview:wallpaperBlurView];
//     [[self rootWindow] addSubview:wallpaperImageView];
}

- (void)setupDock
{
    // If the dock already exists, remove it. This allows the dock to be redrawn easily if the user switches the alignment
    if (_dockView)
    {
        [_dockView removeFromSuperview];
    }

    CGRect rootWindowFrame = [[self rootWindow] frame];
    BOOL rightHandDock = [self shouldUseRightHandDock];

    CGFloat dockXOrigin = (rightHandDock) ? rootWindowFrame.size.width - CARPLAY_DOCK_WIDTH : 0;
    self.dockView = [[UIView alloc] initWithFrame:CGRectMake(dockXOrigin, rootWindowFrame.origin.y, CARPLAY_DOCK_WIDTH, rootWindowFrame.size.height)];

    // Setup dock visual effects
    id blurEffect = objcInvoke_1(objc_getClass("UIBlurEffect"), @"effectWithBlurRadius:", 20.0);
    UIVisualEffectView *effectsView = [[UIVisualEffectView alloc] init];
    [effectsView setFrame:CGRectMake(0, 0, CARPLAY_DOCK_WIDTH, rootWindowFrame.size.height)];
    id colorEffect = objcInvoke_1(objc_getClass("UIColorEffect"), @"colorEffectSaturate:", 2.0);
    id darkEffect = objcInvoke_3(objc_getClass("UIVisualEffect"), @"effectCompositingColor:withMode:alpha:", [UIColor blackColor], 7, 0.6);
    NSArray *effects = @[darkEffect, colorEffect, blurEffect];
    objcInvoke_1(effectsView, @"setBackgroundEffects:", effects);
    [self.dockView addSubview:effectsView];

    [[self rootWindow] addSubview:self.dockView];

    NSBundle *carplayBundle = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/DashBoard.framework"];
    UITraitCollection *carplayTrait = [UITraitCollection traitCollectionWithUserInterfaceIdiom:(UIUserInterfaceIdiom)3];
    UITraitCollection *interfaceStyleTrait = [UITraitCollection traitCollectionWithUserInterfaceStyle:(UIUserInterfaceStyle)1];
    UITraitCollection *traitCollection = [UITraitCollection traitCollectionWithTraitsFromCollections:@[carplayTrait, interfaceStyleTrait]];

    CGFloat buttonSize = 35;
    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    UIImage *homeButtonLightImage = [[UIImage imageNamed:@"CarStatusBarIconsHomeButton" inBundle:carplayBundle compatibleWithTraitCollection:traitCollection] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    [closeButton setImage:homeButtonLightImage forState:UIControlStateNormal];
    [closeButton addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    [closeButton setFrame:CGRectMake((CARPLAY_DOCK_WIDTH - buttonSize) / 2, rootWindowFrame.size.height - buttonSize, buttonSize, buttonSize)];
    [closeButton setTintColor:[UIColor whiteColor]];
    [self.dockView addSubview:closeButton];

    id imageConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightLight];

    buttonSize = 30;

    UIButton *fullscreenButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [fullscreenButton setImage:[UIImage systemImageNamed:@"arrow.up.left.and.arrow.down.right" withConfiguration:imageConfiguration] forState:UIControlStateNormal];
    [fullscreenButton addTarget:self action:@selector(enterFullscreen) forControlEvents:UIControlEventTouchUpInside];
    [fullscreenButton setFrame:CGRectMake((CARPLAY_DOCK_WIDTH - buttonSize) / 2, 10, buttonSize, buttonSize)];
    [fullscreenButton setTintColor:[UIColor whiteColor]];
    [self.dockView addSubview:fullscreenButton];

    UIButton *rotateButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [rotateButton setImage:[UIImage systemImageNamed:@"rotate.right" withConfiguration:imageConfiguration] forState:UIControlStateNormal];
    [rotateButton addTarget:self action:@selector(handleRotate) forControlEvents:UIControlEventTouchUpInside];
    [rotateButton setFrame:CGRectMake((CARPLAY_DOCK_WIDTH - buttonSize) / 2, fullscreenButton.frame.origin.y + 10 + buttonSize, buttonSize, buttonSize)];
    [rotateButton setTintColor:[UIColor whiteColor]];
    [self.dockView addSubview:rotateButton];
}

- (void)setupLaunchImage
{
    LOG_LIFECYCLE_EVENT;
    // Fetch a snapshot to use
    id launchImageSnapshotManifest = objcInvoke_1([objc_getClass("XBApplicationSnapshotManifest") alloc], @"initWithApplicationInfo:", objcInvoke(self.application, @"info"));
    // There's a few variants of snapshots offered: portait/landscape, dark/light.
    // For now just try to find a landscape snapshot. If no landscape, fallback to portait.
    id appSnapshot = nil;
    for (id snapshotGroup in objcInvoke(launchImageSnapshotManifest, @"_allSnapshotGroups"))
    {
        for (id snapshotCandidate in objcInvoke(snapshotGroup, @"snapshots"))
        {
            UIInterfaceOrientation snapshotOrientation = objcInvokeT(snapshotCandidate, @"interfaceOrientation", UIInterfaceOrientation);
            int snapshotContentType = objcInvokeT(snapshotCandidate, @"contentType", int);
            if (UIInterfaceOrientationIsLandscape(snapshotOrientation))
            {
                BOOL isSceneContent = snapshotContentType == 0;
                if (!appSnapshot && isSceneContent)
                {
                    if ([objcInvoke(snapshotCandidate, @"name") isEqualToString:@"CarPlayLaunchImage"])
                    {
                        appSnapshot = snapshotCandidate;
                        break;
                    }
                }

                BOOL isStaticOrGeneratedImage = (snapshotContentType == 1 || snapshotContentType == 2);
                if (isStaticOrGeneratedImage)
                {
                    appSnapshot = snapshotCandidate;
                    break;
                }
            }

            // Portait, but better than nothing
            if (!appSnapshot)
            {
                appSnapshot = snapshotCandidate;
            }
        }
    }
    // If no landscape image was found, queue up a snapshot once the app launches
    self.shouldGenerateSnapshot = UIInterfaceOrientationIsPortrait((UIInterfaceOrientation)objcInvokeT(appSnapshot, @"interfaceOrientation", int));

    // Get the image from the chosen snapshot
    id appSnapshotImage = appSnapshot ? objcInvoke_1(appSnapshot, @"imageForInterfaceOrientation:", (long long)1) : nil;

    // Build an imageview to contain the launch image.
    // The processLaunched handler defined above is responsible for cleaning this up
    self.launchImageView = [[[UIImageView alloc] initWithFrame:CGRectMake(0, 0, [[self appContainerView] frame].size.width, [[self appContainerView] frame].size.height)] autorelease];
    [self.launchImageView setImage:appSnapshotImage];
    [self.launchImageView setContentMode:UIViewContentModeScaleToFill];
    [[self appContainerView] addSubview:self.launchImageView];
}

- (void)setupLiveAppView
{
    LOG_LIFECYCLE_EVENT;
    NSString *appIdentifier = objcInvoke(self.application, @"bundleIdentifier");

    NSMutableArray *lockAssertions = objc_getAssociatedObject([UIApplication sharedApplication], &kPropertyKey_lockAssertionIdentifiers);
    [lockAssertions addObject:appIdentifier];

    id displaySceneManager = objcInvoke(objc_getClass("SBSceneManagerCoordinator"), @"mainDisplaySceneManager");
    assertGotExpectedObject(displaySceneManager, @"SBMainDisplaySceneManager");

    id sceneLayoutManager = objcInvoke(displaySceneManager, @"layoutStateManager");
    if (!sceneLayoutManager) {
        sceneLayoutManager = objcInvoke(displaySceneManager, @"layoutStateManager");
    }
    assertGotExpectedObject(sceneLayoutManager, @"SBMainDisplayLayoutStateManager");

    id mainScreenIdentity = objcInvoke(displaySceneManager, @"displayIdentity");
    assertGotExpectedObject(mainScreenIdentity, @"FBSDisplayIdentity");

    id sceneIdentity = nil;
    if ([displaySceneManager respondsToSelector:NSSelectorFromString(@"_sceneIdentityForApplication:createPrimaryIfRequired:")]) {
        sceneIdentity = objcInvoke_2(displaySceneManager, @"_sceneIdentityForApplication:createPrimaryIfRequired:", self.application, 1);
    }
    else if ([displaySceneManager respondsToSelector:NSSelectorFromString(@"_sceneIdentityForApplication:createPrimaryIfRequired:sceneSessionRole:")]) {
        sceneIdentity = objcInvoke_3(displaySceneManager, @"_sceneIdentityForApplication:createPrimaryIfRequired:sceneSessionRole:", self.application, 1, @"UIWindowSceneSessionRoleApplication");
    }
    else if ([displaySceneManager respondsToSelector:NSSelectorFromString(@"sceneIdentityForApplication:createPrimaryIfRequired:sceneSessionRole:")]) {
        // 18.x
        sceneIdentity = ((id (*)(id, SEL, id, BOOL, id))objc_msgSend)(displaySceneManager, NSSelectorFromString(@"sceneIdentityForApplication:createPrimaryIfRequired:sceneSessionRole:"), self.application, YES, @"UIWindowSceneSessionRoleApplication");
    }
    else if ([displaySceneManager respondsToSelector:NSSelectorFromString(@"newSceneIdentityForApplication:")]) {
        sceneIdentity = objcInvoke_1(displaySceneManager, @"newSceneIdentityForApplication:", self.application);
    }
    assertGotExpectedObject(sceneIdentity, @"FBSSceneIdentity");

    id sceneHandleRequest = objcInvoke_3(objc_getClass("SBApplicationSceneHandleRequest"), @"defaultRequestForApplication:sceneIdentity:displayIdentity:", self.application, sceneIdentity, mainScreenIdentity);
    assertGotExpectedObject(sceneHandleRequest, @"SBApplicationSceneHandleRequest");

    id sceneHandle = objcInvoke_1(displaySceneManager, @"fetchOrCreateApplicationSceneHandleForRequest:", sceneHandleRequest);
    assertGotExpectedObject(sceneHandle, @"SBDeviceApplicationSceneHandle");

    id appSceneEntity = objcInvoke_1([objc_getClass("SBDeviceApplicationSceneEntity") alloc], @"initWithApplicationSceneHandle:", sceneHandle);
    assertGotExpectedObject(appSceneEntity, @"SBDeviceApplicationSceneEntity");

    self.appViewController = [objcInvoke_2([objc_getClass("SBAppViewController") alloc], @"initWithIdentifier:andApplicationSceneEntity:", appIdentifier, appSceneEntity) autorelease];
    assertGotExpectedObject(self.appViewController, @"SBAppViewController");
    objcInvoke_1(self.appViewController, @"setIgnoresOcclusions:", NO);
    objcInvokeIf_1(self.appViewController, @"setAutomatesLifecycle:", NO);
    objcInvokeIf_1(self.appViewController, @"setRequestedMode:", (long long)2);
    objcInvoke(getIvar(self.appViewController, @"_activationSettings"), @"clearActivationSettings");
    if (_launchActions.count)
    {
        objcInvoke_1(appSceneEntity, @"addActions:", _launchActions);
    }

    id sceneUpdateTransaction = objcInvoke_2(self.appViewController, @"_createSceneUpdateTransactionForApplicationSceneEntity:deliveringActions:", appSceneEntity, 1);
    assertGotExpectedObject(sceneUpdateTransaction, @"SBApplicationSceneUpdateTransaction");

    __block NSMutableArray *transactions = getIvar(self.appViewController, @"_activeTransitions");
    objcInvoke_1(sceneUpdateTransaction, @"setCompletionBlock:", ^void(int arg1) {

        [transactions removeObject:sceneUpdateTransaction];

        id processLaunchTransaction = getIvar(sceneUpdateTransaction, @"_processLaunchTransaction");
        assertGotExpectedObject(processLaunchTransaction, @"FBApplicationProcessLaunchTransaction");

        id appProcess = objcInvoke(processLaunchTransaction, @"process");
        assertGotExpectedObject(appProcess, @"FBProcess");

        objcInvoke_1(appProcess, @"_executeBlockAfterLaunchCompletes:", ^void(void) {
            // Wait a sec then remove the splashscreen image. It should already be hidden/covered by the live app view, but it needs to be removed
            // so it doesn't poke through if the App's orientation changes to portait
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [self.launchImageView removeFromSuperview];

                id appScene = objcInvoke(sceneHandle, @"sceneIfExists");
                if (!appScene)
                {
                    NSLog(@"Scene does not exist");
                    return;
                }

                id sceneSettings = [objcInvoke(objcInvoke(appScene, @"settings"), @"mutableCopy") autorelease];
                assertGotExpectedObject(sceneSettings, @"UIMutableApplicationSceneSettings");

                CRApplyCarplaySceneSettings(sceneSettings, self);

               ((void (*)(id, SEL, id, id, id))objc_msgSend)(appScene, NSSelectorFromString(@"updateSettings:withTransitionContext:completion:"), sceneSettings, nil, ^{});

                // the running app may support less than its Info.plist says
                [self followAppSupportedOrientations];

                if (self.shouldGenerateSnapshot)
                {
                    // Now that the app is launched and presumably in landscape mode, save a snapshot.
                    // If an app does not natively support landscape mode and doesn't ship a landscape launch image, this snapshot can be used during cold-launches

                    id snapshotContext = objcInvoke_2(objc_getClass("FBSSceneSnapshotContext"), @"contextWithSceneID:settings:", objcInvoke(appScene, @"identifier"), sceneSettings);
                    objcInvoke_1(snapshotContext, @"setName:", @"CarPlayLaunchImage");
                    objcInvokeIf_1(snapshotContext, @"setScale:", (double)2.0);
                    objcInvokeIf_1(snapshotContext, @"setExpirationInterval:", (double)99999.0);
                    objcInvoke_3(self.application, @"saveSnapshotForSceneHandle:context:completion:", sceneHandle, snapshotContext, nil);
                }
            });

            // Ask the app to rotate to landscape
            [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.carplayenable.orientation" object:appIdentifier userInfo:@{@"orientation": @(self.orientation)}];
        });
    });

    [transactions addObject:sceneUpdateTransaction];
    objcInvoke(sceneUpdateTransaction, @"begin");
    objcInvoke(self.appViewController, @"_createSceneViewController");

    id animationFactory = objcInvoke(objc_getClass("SBApplicationSceneView"), @"defaultDisplayModeAnimationFactory");
    assertGotExpectedObject(animationFactory, @"BSUIAnimationFactory");

    id appView = objcInvoke(self.appViewController, @"appView");
    objcInvoke_3(appView, @"setDisplayMode:animationFactory:completion:", (long long)4, animationFactory, nil);
    [[self.appViewController view] setBackgroundColor:[UIColor clearColor]];

    // Create a scene monitor to watch for the app process dying. The carplay window will dismiss itself.
    NSString *sceneID = objcInvoke(sceneIdentity, @"identifier");
    if (sceneID) {
        // the identity we created the scene with already knows its id
    }
    else if ([sceneLayoutManager respondsToSelector:NSSelectorFromString(@"primarySceneIdentifierForBundleIdentifier:sceneSessionRole:displayIdentity:")]) {
        sceneID = objcInvoke_3(sceneLayoutManager, @"primarySceneIdentifierForBundleIdentifier:sceneSessionRole:displayIdentity:", appIdentifier, @"UIWindowSceneSessionRoleApplication", mainScreenIdentity);
    }
    else if ([sceneLayoutManager respondsToSelector:NSSelectorFromString(@"primarySceneIdentifierForBundleIdentifier:")]) {
        sceneID = objcInvoke_1(sceneLayoutManager, @"primarySceneIdentifierForBundleIdentifier:", appIdentifier);
    }
    else if ([sceneLayoutManager respondsToSelector:NSSelectorFromString(@"primarySceneIdentifierForBundleIdentifier:sceneSessionRole:")]) {
        sceneID = objcInvoke_2(sceneLayoutManager, @"primarySceneIdentifierForBundleIdentifier:sceneSessionRole:", appIdentifier, @"UIWindowSceneSessionRoleApplication");
    }

    self.sceneMonitor = [objcInvoke_1([objc_getClass("FBSceneMonitor") alloc], @"initWithSceneID:", sceneID) autorelease];
    objcInvoke_1(self.sceneMonitor, @"setDelegate:", self);
}

/*
FBSceneMonitor delegate method, invoked when the app process dies.
Use this to close the window on the CarPlay screen if the app crashes or is killed via the App Switcher on main screen
*/
- (void)sceneMonitor:(id)arg1 sceneWasDestroyed:(id)arg2
{
    LOG_LIFECYCLE_EVENT;
    // Close the window
    objcInvoke(self, @"dismiss");
}

- (void)handleScreenTapped
{
    LOG_LIFECYCLE_EVENT;
    // The carplay screen was tapped.
    // If the window is fullscreen'd, exit fullscreen
    if (_isFullscreen)
    {
        [self exitFullscreen];
    }
}

- (void)exitFullscreen
{
    LOG_LIFECYCLE_EVENT;
    if (_isFullscreen)
    {
        [self resizeAppViewForOrientation:self.orientation fullscreen:NO forceUpdate:NO];
    }
}

- (void)enterFullscreen
{
    LOG_LIFECYCLE_EVENT;
    BOOL toFullScreen = 1;
    [UIView animateWithDuration:0.2 animations:^(void) {
        [self resizeAppViewForOrientation:self.orientation fullscreen:toFullScreen forceUpdate:NO];
    } completion:nil];
}

/*
When a CarPlay App is closed: our home button, CarPlay's home button, another app taking the screen, or the app dying
*/
- (void)dismiss
{
    // CarPlay and SpringBoard can both ask while the fade-out runs
    if (_isDismissing)
    {
        return;
    }
    _isDismissing = YES;
    [[CRCarAppSwitcher sharedInstance] noteAppLeaving:[self bundleIdentifier] window:self.rootWindow];

    LOG_LIFECYCLE_EVENT;
    // Invalidate the scene monitor
    [self.sceneMonitor invalidate];

    // Remove any observers. The tokens' blocks hold on to self, so drop them too
    for (id observer in _observers)
    {
        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] removeObserver:observer];
    }
    [_observers removeAllObjects];

    // Disable the screen-tap recognizer (overlay look only)
    if (_screenTapRecognizer)
    {
        id systemGestureManager = objcInvoke(objc_getClass("_UISystemGestureManager"), @"sharedInstance");
        id identity = objcInvoke(objcInvoke(self.rootWindow, @"displayConfiguration"), @"identity");
        objcInvoke_2(systemGestureManager, @"removeGestureRecognizer:fromDisplayWithIdentity:", _screenTapRecognizer, identity);
    }

    NSString *closedBundleID = [self bundleIdentifier];
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.carplayenable.closed" object:nil userInfo:closedBundleID ? @{@"identifier": closedBundleID} : nil];

    void (^cleanupAfterCarplay)() = ^() {
        id sharedApp = [UIApplication sharedApplication];
        NSString *hostedBundleID = objcInvoke(self.application, @"bundleIdentifier");
        // the same app reopened while this window faded out: the app stays on CarPlay, under the new window
        CRCarPlayWindow *replacement = objc_getAssociatedObject(sharedApp, &kPropertyKey_liveCarplayWindow);
        BOOL appStaysOnCarplay = replacement && replacement != self && hostedBundleID && [[replacement bundleIdentifier] isEqualToString:hostedBundleID];

        if (!appStaysOnCarplay)
        {
            // a relaunch on the phone is an iPhone app again
            CRSetPadLayoutMarker(hostedBundleID, NO);
            // Notify the application process to stop enforcing an orientation lock
            int resetOrientationLock = -1;
            NSString *hostedIdentifier = getIvar(self.appViewController, @"_identifier");
            [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.carplayenable.orientation" object:hostedIdentifier userInfo:@{@"orientation": @(resetOrientationLock)}];
        }

        [self.rootWindow setHidden:YES];
        objcInvoke_1(self.appViewController, @"_setCurrentMode:", (long long)0);

        // Find the main sceen's sceneView for the dismissing app and put it in LiveContent mode (from PlaceHolder mode)
        // This removes the placeholder view visible in the app switcher
        id currentSceneHandle = objcInvoke(self.appViewController, @"sceneHandle");
        if (!appStaysOnCarplay)
        {
            for (id appSceneView in CRSceneViewsForSceneHandle(currentSceneHandle, self.rootWindow))
            {
                objcInvoke_3(appSceneView, @"setDisplayMode:animationFactory:completion:", (long long)4, nil, nil);
            }
        }

        // After the scene returns to the device, release the assertion that prevents suspension.
        // Only this window's: a replacement window for the same app added its own
        NSMutableArray *lockAssertions = objc_getAssociatedObject(sharedApp, &kPropertyKey_lockAssertionIdentifiers);
        NSUInteger assertionIndex = hostedBundleID ? [lockAssertions indexOfObject:hostedBundleID] : NSNotFound;
        if (assertionIndex != NSNotFound)
        {
            [lockAssertions removeObjectAtIndex:assertionIndex];
        }

        id appScene = objcInvoke(currentSceneHandle, @"sceneIfExists");
        if (appScene != nil && !appStaysOnCarplay)
        {
            // Send the app to the background *if it is not on the main screen*
            id frontmostApp = objcInvoke(sharedApp, @"_accessibilityFrontMostApplication");
            BOOL isAppOnMainScreen = frontmostApp && [objcInvoke(frontmostApp, @"bundleIdentifier") isEqualToString:hostedBundleID];
            if (!isAppOnMainScreen)
            {
                id sceneSettings = [objcInvoke(objcInvoke(appScene, @"settings"), @"mutableCopy") autorelease];
                if ([sceneSettings isKindOfClass:objc_getClass("UIMutableApplicationSceneSettings")])
                {
                    objcInvokeIf_1(sceneSettings, @"setForeground:", NO);
                    ((void (*)(id, SEL, id, id, id))objc_msgSend)(appScene, NSSelectorFromString(@"updateSettings:withTransitionContext:completion:"), sceneSettings, nil, ^{});
                }
            }
        }

        // If the device is locked and screen off, set the screen state to off
        if (objcInvokeT(sharedApp, @"isLocked", BOOL) == YES)
        {
            void *_BKSHIDServicesGetBacklightFactor = dlsym(RTLD_DEFAULT, "BKSHIDServicesGetBacklightFactor");
            float backlightFactor = _BKSHIDServicesGetBacklightFactor ? ((float (*)(void))_BKSHIDServicesGetBacklightFactor)() : 1.0f;
            if (backlightFactor < 0.2 && orig_BKSDisplayServicesSetScreenBlanked)
            {
                orig_BKSDisplayServicesSetScreenBlanked(1);
            }
        }

        // todo: resign first responder (kb causes glitches on return)
        [self.rootWindow removeFromSuperview];
        // the property owns the window; releasing it here as well was an over-release
        self.rootWindow = nil;

        // a new window may already have replaced this one (switching apps), don't clear that one.
        // drops the last reference to self, keep it last
        if (objc_getAssociatedObject(sharedApp, &kPropertyKey_liveCarplayWindow) == self)
        {
            objc_setAssociatedObject(sharedApp, &kPropertyKey_liveCarplayWindow, nil, OBJC_ASSOCIATION_RETAIN);
        }
        // back to the phone, or onto the window that replaced this one
        CRRelayoutCarplayKeyboards();
    };

    [UIView animateWithDuration:(_nativeLook ? 0.25 : 0.5) animations:^(void)
    {
        [[self rootWindow] setAlpha:0];
    } completion:^(BOOL completed)
    {
        cleanupAfterCarplay();
    }];
}

/*
When the "rotate orientation" button is pressed on a CarplayEnabled app window
*/
- (void)handleRotate
{
    LOG_LIFECYCLE_EVENT;
    [self rotateAppToOrientation:UIInterfaceOrientationIsLandscape(self.orientation) ? UIInterfaceOrientationPortrait : UIInterfaceOrientationLandscapeLeft];
}

- (void)rotateAppToOrientation:(UIInterfaceOrientation)desiredOrientation
{
    id appScene = objcInvoke(objcInvoke([self appViewController], @"sceneHandle"), @"sceneIfExists");
    if (!appScene)
    {
        // The scene doesn't exist - maybe the app hasn't finished launching yet
        return;
    }

    NSString *sceneAppBundleID = CRBundleIDForScene(appScene) ?: objcInvoke(self.application, @"bundleIdentifier");

    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.carplayenable.orientation" object:sceneAppBundleID userInfo:@{@"orientation": @(desiredOrientation)}];
    [self resizeAppViewForOrientation:desiredOrientation fullscreen:self.isFullscreen forceUpdate:NO];
}

/*
Orientations the app can be shown in: what the running app asks for, else what its Info.plist declares (0 if unknown)
*/
- (unsigned long long)appSupportedOrientations
{
    SEL supportedSel = NSSelectorFromString(@"supportedInterfaceOrientations");
    id sceneHandle = self.appViewController ? objcInvoke(self.appViewController, @"sceneHandle") : nil;
    id appScene = [sceneHandle respondsToSelector:NSSelectorFromString(@"sceneIfExists")] ? objcInvoke(sceneHandle, @"sceneIfExists") : nil;
    id clientSettings = [appScene respondsToSelector:NSSelectorFromString(@"clientSettings")] ? objcInvoke(appScene, @"clientSettings") : nil;
    id appInfo = [self.application respondsToSelector:NSSelectorFromString(@"info")] ? objcInvoke(self.application, @"info") : nil;

    for (id source in @[clientSettings ?: [NSNull null], appInfo ?: [NSNull null]])
    {
        if ([source respondsToSelector:supportedSel])
        {
            unsigned long long mask = ((unsigned long long (*)(id, SEL))objc_msgSend)(source, supportedSel);
            if (mask != 0)
            {
                return mask;
            }
        }
    }
    return 0;
}

// the current orientation if the mask allows it, else the first allowed of landscape, portrait, the other landscape
- (UIInterfaceOrientation)orientationFittingMask:(unsigned long long)mask
{
    if (mask == 0 || (mask & (1ULL << self.orientation)))
    {
        return self.orientation;
    }
    for (NSNumber *candidate in @[@(UIInterfaceOrientationLandscapeLeft), @(UIInterfaceOrientationPortrait), @(UIInterfaceOrientationLandscapeRight)])
    {
        if (mask & (1ULL << [candidate integerValue]))
        {
            return (UIInterfaceOrientation)[candidate integerValue];
        }
    }
    return self.orientation;
}

/*
Only reacts when the app's supported orientations change, so the overlay look's rotate button still wins otherwise
*/
- (void)followAppSupportedOrientations
{
    if (_isDismissing)
    {
        return;
    }
    unsigned long long supported = [self appSupportedOrientations];
    if (supported == 0 || supported == self.lastSupportedOrientations)
    {
        return;
    }
    self.lastSupportedOrientations = supported;

    UIInterfaceOrientation fitting = [self orientationFittingMask:supported];
    if (fitting != self.orientation)
    {
        CRLog(@"%@ supports orientations %#llx, showing it in %ld", [self bundleIdentifier], supported, (long)fitting);
        [self rotateAppToOrientation:fitting];
    }
}

/*
Handle resizing the Carplay App window. Called anytime the app orientation changes (including first appearance)
*/
- (void)resizeAppViewForOrientation:(UIInterfaceOrientation)desiredOrientation fullscreen:(BOOL)fullscreen forceUpdate:(BOOL)forceUpdate
{
    LOG_LIFECYCLE_EVENT;

    if (!forceUpdate && desiredOrientation == self.orientation && self.isFullscreen == fullscreen) {
        return;
    }

    // set before touching the scene: the FBScene hook reads the window's orientation
    self.orientation = desiredOrientation;
    self.isFullscreen = fullscreen;

    id deviceVC = getIvar(self.appViewController, @"_deviceAppViewController");
    ((void (*)(id, SEL, unsigned long long))objc_msgSend)(deviceVC, NSSelectorFromString(@"setHomeGrabberDisplayMode:"), 1);

    CGFloat dockWidth = (fullscreen || _nativeLook) ? 0.0 : CARPLAY_DOCK_WIDTH;
    CGRect rootBounds = self.rootWindow.bounds;

    self.appContainerView.transform = CGAffineTransformIdentity;
    self.appContainerView.frame = CGRectMake((_nativeLook || [self shouldUseRightHandDock]) ? 0.0 : dockWidth, 0.0, rootBounds.size.width - dockWidth, rootBounds.size.height);

    CGRect sceneFrame = [self sceneFrame];

    void (^updateSceneGeometry)(void) = ^{
        id sceneHandle = objcInvoke(self.appViewController, @"sceneHandle");
        id appScene = objcInvoke(sceneHandle, @"sceneIfExists");
        if (!appScene) {
            return;
        }

        id settings = [objcInvoke(objcInvoke(appScene, @"settings"), @"mutableCopy") autorelease];

        long long orientation = desiredOrientation;
        CRApplyCarplaySceneSettings(settings, self);

        ((void (*)(id, SEL, id, id, id))objc_msgSend)(appScene, NSSelectorFromString(@"updateSettings:withTransitionContext:completion:"), settings, nil, ^{});
        CRLog(@"scene geometry -> orientation %lld frame %@", orientation, NSStringFromCGRect(sceneFrame));
    };

    updateSceneGeometry();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC), dispatch_get_main_queue(), updateSceneGeometry);

    UIView *appView = objcInvoke(self.appViewController, @"view");
    appView.transform = CGAffineTransformIdentity;
    if (_appScale > 0 && _appScale != 1.0)
    {
        CGSize containerSize = self.appContainerView.bounds.size;
        appView.bounds = CGRectMake(0, 0, round(containerSize.width / _appScale), round(containerSize.height / _appScale));
        appView.center = CGPointMake(containerSize.width / 2.0, containerSize.height / 2.0);
        appView.transform = CGAffineTransformMakeScale(_appScale, _appScale);
    }

    self.dockView.alpha = fullscreen ? 0.0 : 1.0;
    CRRelayoutCarplayKeyboards();

    CRLog(@"layout: screen scale %.2f root %@ container %@ sceneFrame %@ appView %@", self.rootWindow.screen.scale, NSStringFromCGRect(rootBounds), NSStringFromCGRect(self.appContainerView.bounds), NSStringFromCGRect(sceneFrame), NSStringFromCGRect(appView.frame));

    // Update last known orientation and fullscreen status
    self.orientation = desiredOrientation;
    self.isFullscreen = fullscreen;
}

- (BOOL)shouldUseRightHandDock
{
    // Should the dock be drawn on the left or right side of the screen
    switch ([[CRPreferences sharedInstance] dockAlignment])
    {
        case CRDockAlignmentLeft:
            return NO;
        case CRDockAlignmentRight:
            return YES;
        case CRDockAlignmentAuto:
        {
            // Auto mode - determine which alignment Carplay is using and mimick it
            id carplaySession = objcInvoke(self.sessionStatus, @"session");
            id usesRightHand = objcInvoke_1(carplaySession, @"_endpointValueForKey:", @"RightHandDrive");
            return [usesRightHand boolValue];
        }
        default:
        {
            break;
        }
    }

    return NO;
}

@end