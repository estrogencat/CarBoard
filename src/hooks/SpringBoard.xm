#include "../common.h"
#include "../CRCarplayWindow.h"


/*
Injected into SpringBoard.
*/
%group SPRINGBOARD

int (*orig_BKSDisplayServicesSetScreenBlanked)(int);

/*
Prevent app from dying when the device locks
*/
%hook SBSuspendedUnderLockManager

/*
Invoked when the device is being locked while applications are running/active
*/
- (BOOL)_shouldBeBackgroundUnderLockForScene:(id)arg2 withSettings:(id)arg3
{
    BOOL shouldBackground = %orig;
    if (shouldBackground)
    {
        // This app is going to be backgrounded, If there is an active lock-prevention assertion for it, prevent the backgrounding.
        // This keeps CarPlay apps interactive when the device locks
        NSString *sceneAppBundleID = CRBundleIDForScene(arg2);
        NSArray *lockAssertions = objc_getAssociatedObject([UIApplication sharedApplication], &kPropertyKey_lockAssertionIdentifiers);
        if ([lockAssertions containsObject:sceneAppBundleID])
        {
            LOG_LIFECYCLE_EVENT;
            shouldBackground = NO;
        }
    }

    return shouldBackground;
}

%end

%hook __NSSetM

- (void)removeObject:(id)object
{
    if (object == nil) {
        // wtf
        NSLog(@"__NSSetM Attempted to remove nil object from set %@", self);
        return;
    }

    %orig;
}

%end

%hook SpringBoard

/*
When an app icon is tapped on the Carplay dashboard
*/
%new
- (void)handleCarPlayLaunchNotification:(id)notification
{
    LOG_LIFECYCLE_EVENT;
    NSString *identifier = [notification userInfo][@"identifier"];
    objcInvoke_1(self, @"launchAppOnCarplay:", identifier);
}

%new
- (void)launchAppOnCarplay:(NSString *)identifier
{
    LOG_LIFECYCLE_EVENT;
    @try
    {
        // Dismiss any apps that are already being hosted on Carplay
        id liveCarplayWindow = objcInvoke([UIApplication sharedApplication], @"liveCarplayWindow");
        if (liveCarplayWindow != nil)        {
            objcInvoke(liveCarplayWindow, @"dismiss");
        }

        // Launch the requested app
        liveCarplayWindow = [[[CRCarPlayWindow alloc] initWithBundleIdentifier:identifier] autorelease];
        objc_setAssociatedObject(self, &kPropertyKey_liveCarplayWindow, liveCarplayWindow, OBJC_ASSOCIATION_RETAIN);
    }
    @catch (NSException *exception)
    {
        NSLog(@"carplay window launch failed! %@", exception);
    }
}

/*
Invoked when SpringBoard finishes launching
*/
- (void)applicationDidFinishLaunching:(id)arg1
{
    LOG_LIFECYCLE_EVENT;
    // Setup to receive App Launch notifications from the CarPlay process
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserver:self selector:NSSelectorFromString(@"handleCarPlayLaunchNotification:") name:@"com.carplayenable" object:nil];

    // Receive notifications for Carplay connect/disconnect events. When a Carplay screen becomes unavailable while an app is being hosted on it, that app window needs to be closed
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(carplayIsConnectedChanged) name:@"CarPlayIsConnectedDidChange" object:nil];

    NSMutableArray *appIdentifiersToIgnoreLockAssertions = [[NSMutableArray alloc] init];
    objc_setAssociatedObject(self, &kPropertyKey_lockAssertionIdentifiers, appIdentifiersToIgnoreLockAssertions, OBJC_ASSOCIATION_RETAIN);

    %orig;

    NSOperationQueue *notificationQueue = [[NSOperationQueue alloc] init];
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserverForName:PREFERENCES_APP_DATA_NOTIFICATION object:kPrefsAppDataRequesting queue:notificationQueue usingBlock:^(NSNotification * _Nonnull note) {
        // The Preference pane is requesting a list of installed apps + icons. Gather the info
        id appController = objcInvoke(objc_getClass("SBApplicationController"), @"sharedInstance");
        NSMutableArray *appList = [[NSMutableArray alloc] init];
        for (id appInfo in objcInvoke(appController, @"allInstalledApplications"))
        {
            NSString *identifier = objcInvoke(appInfo, @"bundleIdentifier");
            // Skip stock apps
            if (![objcInvoke(appInfo, @"bundleType") isEqualToString:@"User"] && [identifier containsString:@"com.apple."])
            {
                continue;
            }
            // Skip native-carplay apps
            if (getIvar(appInfo, @"_carPlayDeclaration") != nil)
            {
                continue;
            }

            // Grab icon data
            UIImage *appIconImage = objcInvoke_3(objc_getClass("UIImage"), @"_applicationIconImageForBundleIdentifier:format:scale:", identifier, 0, [UIScreen mainScreen].scale);
            NSData *iconImageData = UIImagePNGRepresentation(appIconImage);

            NSDictionary *appInfoDict = @{
                @"name": objcInvoke(appInfo, @"displayName"),
                @"bundleID": identifier,
                @"iconImage": iconImageData
            };
            [appList addObject:appInfoDict];

        }
        NSDictionary *replyDict = @{@"appList": appList};
        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotification:[NSNotification notificationWithName:PREFERENCES_APP_DATA_NOTIFICATION object:kPrefsAppDataReceiving userInfo:replyDict]];
    }];

}

%new
- (id)liveCarplayWindow
{
    return objc_getAssociatedObject(self, &kPropertyKey_liveCarplayWindow);
}

/*
A Carplay connected/disconnected event
*/
%new
- (void)carplayIsConnectedChanged
{
    LOG_LIFECYCLE_EVENT;
    // If a window is being hosted, and the carplay radio disconnected, close the window
    id liveCarplayWindow = objcInvoke(self, @"liveCarplayWindow");
    if (liveCarplayWindow && !getCarplayCADisplay())
    {
        // dispatch_sync onto main from main deadlocks
        if ([NSThread isMainThread])
        {
            objcInvoke(liveCarplayWindow, @"dismiss");
        }
        else
        {
            dispatch_async(dispatch_get_main_queue(), ^(void) {
                objcInvoke(liveCarplayWindow, @"dismiss");
            });
        }
    }
}

%end

%hook SBSceneView

/*
This is invoked when transformations are applied to a Carplay Hosted window. It crashes if those transformations
happen while the device is in a faceup/facedown orientation.
*/
- (void)_updateReferenceSize:(struct CGSize)arg1 andOrientation:(long long)arg2
{
    // Scene views do not support Face-Up/Face-Down orientations - it will raise an exception if attempted.
    // If the device is in a restricted orientation, override to landscape (3). This doesn't really matter because
    // the app's content will be unconditionally forced to landscape when it becomes live.
    if (arg2 > 4)
    {
        return %orig(arg1, 3);
    }
    %orig;
}

%end

/*
Is this scene's app currently hosted on the CarPlay screen?
*/
static BOOL CRSceneIsHostedOnCarplay(id scene)
{
    NSString *sceneAppBundleID = CRBundleIDForScene(scene);
    NSArray *lockAssertions = objc_getAssociatedObject([UIApplication sharedApplication], &kPropertyKey_lockAssertionIdentifiers);
    return sceneAppBundleID && [lockAssertions containsObject:sceneAppBundleID];
}

static NSString *CRDescribeSceneGeometry(id settings)
{
    SEL frameSel = NSSelectorFromString(@"frame");
    SEL orientationSel = NSSelectorFromString(@"interfaceOrientation");
    if (![settings respondsToSelector:frameSel] || ![settings respondsToSelector:orientationSel])
    {
        return @"(no geometry)";
    }
    CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(settings, frameSel);
    long long orientation = ((long long (*)(id, SEL))objc_msgSend)(settings, orientationSel);
    return [NSString stringWithFormat:@"orientation %lld frame %@", orientation, NSStringFromCGRect(frame)];
}

// does the scene carry the CarPlay window's orientation and size? (settings properties resolve dynamically on 18.x)
static BOOL CRSceneSettingsMatchWindow(id settings, CRCarPlayWindow *window)
{
    SEL frameSel = NSSelectorFromString(@"frame");
    SEL orientationSel = NSSelectorFromString(@"interfaceOrientation");
    if (!window.appContainerView || ![settings respondsToSelector:frameSel] || ![settings respondsToSelector:orientationSel])
    {
        return YES;
    }
    CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(settings, frameSel);
    long long orientation = ((long long (*)(id, SEL))objc_msgSend)(settings, orientationSel);
    CGSize wanted = [window sceneFrame].size;
    return orientation == (long long)window.orientation && fabs(frame.size.width - wanted.width) < 0.5 && fabs(frame.size.height - wanted.height) < 0.5;
}

/*
Keep a CarPlay-hosted scene foreground, in the CarPlay window's orientation and sized to its container,
whatever the main display's layout wants
*/
static void CRForceCarplaySceneSettings(id settings)
{
    // keeps whatever orientation the CarPlay window picked (the rotate button flips it)
    id liveCarplayWindow = objcInvoke([UIApplication sharedApplication], @"liveCarplayWindow");
    CRApplyCarplaySceneSettings(settings, (CRCarPlayWindow *)liveCarplayWindow);
}

/*
18.x mostly updates scenes through block-based APIs (updateUISettingsWithBlock: and friends) that never hit
updateSettings:withTransitionContext:completion:. Wrap the caller's block so the forced settings are applied after it.
FBScene's _joinUpdate:block:completion: calls these blocks with the mutable settings first. The second register is
passed through untouched for blocks that take more, but it isn't always an object (activation passes something else),
so only the first argument is ever inspected.
*/
static id CRWrapSceneUpdateBlock(id scene, id block)
{
    if (!block || !CRSceneIsHostedOnCarplay(scene))
    {
        return block;
    }

    void *(^originalBlock)(id, void *) = block;
    return [[^void *(id settings, void *passthrough) {
        void *result = originalBlock(settings, passthrough);
        CRForceCarplaySceneSettings(settings);
        return result;
    } copy] autorelease];
}

// re-apply the CarPlay geometry next runloop; capped so a setter that stops working can't loop forever
static void CRScheduleCarplaySceneRestore(id sceneHandle)
{
    static CFAbsoluteTime windowStart;
    static int restoresInWindow;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - windowStart > 2.0)
    {
        windowStart = now;
        restoresInWindow = 0;
    }
    if (++restoresInWindow > 5)
    {
        CRLog(@"carplay scene keeps drifting, not restoring again yet");
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        id currentScene = objcInvoke(sceneHandle, @"sceneIfExists");
        id mutableSettings = [objcInvoke(objcInvoke(currentScene, @"settings"), @"mutableCopy") autorelease];
        if (currentScene && mutableSettings && CRSceneIsHostedOnCarplay(currentScene))
        {
            CRForceCarplaySceneSettings(mutableSettings);
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(currentScene, NSSelectorFromString(@"updateSettings:withTransitionContext:completion:"), mutableSettings, nil, ^{});
        }
    });
}

%hook FBScene

/*
Called when something is trying to change a scene's settings (including sending it to background/foreground).
Use this to prevent the App from going to sleep when other applications are launched on the main screen.
*/
- (void)updateSettings:(id)settings withTransitionContext:(id)arg2 completion:(id)arg3
{
    if (CRSceneIsHostedOnCarplay(self))
    {
        // the main display's layout hands over immutable settings (its phone-sized frame), so force a mutable copy
        if (![settings isKindOfClass:objc_getClass("UIMutableApplicationSceneSettings")] && [settings isKindOfClass:objc_getClass("UIApplicationSceneSettings")])
        {
            settings = [[settings mutableCopy] autorelease];
        }
        CRForceCarplaySceneSettings(settings);
    }

    %orig(settings, arg2, arg3);
}

// updateUISettingsWithBlock: -> updateSettingsWithBlock: -> here
- (void)updateSettings:(id)settingsBlock
{
    %orig(CRWrapSceneUpdateBlock(self, settingsBlock));
}

- (void)performUpdate:(id)updateBlock withCompletion:(id)completion
{
    %orig(CRWrapSceneUpdateBlock(self, updateBlock), completion);
}

%end

%hook SBAppViewController

/*
SBAppViewController asserts ("Something changed the scene's foreground status out from underneath us") if its scene
goes background while it expects it foreground. The main display's layout transactions do exactly that to a
CarPlay-hosted app, since it isn't in the phone's layout. If our forcing above missed a path, don't let that
respring SpringBoard: skip the check for the CarPlay window's controller and bring the scene back next runloop.
The same goes for the phone's frame and orientation leaking in when the app is opened on the phone.
*/
- (void)sceneHandle:(id)sceneHandle didUpdateSettingsWithDiff:(id)diff previousSettings:(id)previousSettings
{
    id liveCarplayWindow = objcInvoke([UIApplication sharedApplication], @"liveCarplayWindow");
    if (liveCarplayWindow && self == [(CRCarPlayWindow *)liveCarplayWindow appViewController])
    {
        id appScene = objcInvoke(sceneHandle, @"sceneIfExists");
        id settings = objcInvoke(appScene, @"settings");
        // settings properties are resolved dynamically on 18.x, so ask with respondsToSelector, not class_getInstanceMethod
        SEL isForegroundSel = NSSelectorFromString(@"isForeground");
        BOOL backgrounded = settings && [settings respondsToSelector:isForegroundSel] && !((BOOL (*)(id, SEL))objc_msgSend)(settings, isForegroundSel);
        BOOL drifted = settings && !CRSceneSettingsMatchWindow(settings, (CRCarPlayWindow *)liveCarplayWindow);
        if (backgrounded || drifted)
        {
            CRLog(@"carplay scene %@, restoring it", backgrounded ? @"was backgrounded" : [NSString stringWithFormat:@"drifted to %@", CRDescribeSceneGeometry(settings)]);
            CRScheduleCarplaySceneRestore(sceneHandle);
            if (backgrounded)
            {
                return;
            }
        }
    }

    %orig;
}

%end

%hook SBSwitcherController

/*
The app switcher matches the orientation of the frontmost app. When an app is on Carplay, this could be different
than the device orientation. Force the switcher to use the device's physical orientation when a Carplay-hosted app is frontmost
*/
- (void)_updateContentViewInterfaceOrientation:(long long)arg1
{
    if (objcInvoke([UIApplication sharedApplication], @"liveCarplayWindow") != nil)
    {
        LOG_LIFECYCLE_EVENT;
        // Match the device orientation instead of app orientation (face up/down aren't interface orientations)
        long long deviceOrientation = [[UIDevice currentDevice] orientation];
        if (deviceOrientation < UIDeviceOrientationPortrait || deviceOrientation > UIDeviceOrientationLandscapeRight)
        {
            return %orig;
        }
        return %orig(deviceOrientation);
    }

    return %orig;
}

%end

/*
The keyboard is its own scene, hosted by SpringBoard in SBMedusaHostedKeyboardWindow. It covers the whole phone display,
in the phone's portrait coordinates, and the keyboard process draws the keyboard in the hosted app's orientation.
Move it onto the CarPlay window, rotate it upright like the app, and scale it so it fits the app container's width
without covering more than about half of it.
*/
static NSHashTable *carplayKeyboardWindows;
// height of the keyboard, in its own orientation, from the last keyboard arbiter update
static CGFloat lastKeyboardHeight;
static char kCarplayKeyboardContainerKey;
// where the presentation view lived in the phone's keyboard window
static char kCarplayKeyboardHomeKey;

static CGFloat CRAngleForInterfaceOrientation(UIInterfaceOrientation orientation)
{
    switch (orientation)
    {
        case UIInterfaceOrientationLandscapeLeft:
            return M_PI_2;
        case UIInterfaceOrientationLandscapeRight:
            return -M_PI_2;
        case UIInterfaceOrientationPortraitUpsideDown:
            return M_PI;
        default:
            return 0;
    }
}

// returns NO if there's no CarPlay window (or nothing to host) and the keyboard should stay on the phone
static BOOL CRLayoutCarplayKeyboard(UIWindow *keyboardWindow)
{
    CRCarPlayWindow *liveCarplayWindow = objcInvoke([UIApplication sharedApplication], @"liveCarplayWindow");
    UIView *keyboardContainer = objc_getAssociatedObject(keyboardWindow, &kCarplayKeyboardContainerKey);
    UIWindow *carplayRootWindow = liveCarplayWindow.rootWindow;
    UIView *appContainerView = liveCarplayWindow.appContainerView;
    id presenter = getIvar(keyboardWindow, @"_remoteHostedKeyboardScenePresenter");
    UIView *presentationView = [presenter respondsToSelector:NSSelectorFromString(@"presentationView")] ? objcInvoke(presenter, @"presentationView") : nil;
    if (!carplayRootWindow || !appContainerView || !presentationView)
    {
        if (keyboardContainer)
        {
            // hand the presentation view back to the phone's keyboard window
            if (presentationView && presentationView.superview == keyboardContainer)
            {
                UIView *originalSuperview = objc_getAssociatedObject(keyboardWindow, &kCarplayKeyboardHomeKey);
                presentationView.transform = CGAffineTransformIdentity;
                presentationView.frame = keyboardWindow.bounds;
                [(originalSuperview.window == keyboardWindow ? originalSuperview : keyboardWindow) addSubview:presentationView];
            }
            [keyboardContainer removeFromSuperview];
            objc_setAssociatedObject(keyboardWindow, &kCarplayKeyboardContainerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return NO;
    }

    if (!carplayKeyboardWindows)
    {
        carplayKeyboardWindows = [[NSHashTable weakObjectsHashTable] retain];
    }
    [carplayKeyboardWindows addObject:keyboardWindow];

    if (!keyboardContainer)
    {
        keyboardContainer = [[[UIView alloc] initWithFrame:CGRectZero] autorelease];
        keyboardContainer.backgroundColor = [UIColor clearColor];
        keyboardContainer.clipsToBounds = YES;
        objc_setAssociatedObject(keyboardWindow, &kCarplayKeyboardContainerKey, keyboardContainer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (keyboardContainer.superview != carplayRootWindow)
    {
        [keyboardContainer removeFromSuperview];
        [carplayRootWindow addSubview:keyboardContainer];
    }
    if (presentationView.superview != keyboardContainer)
    {
        objc_setAssociatedObject(keyboardWindow, &kCarplayKeyboardHomeKey, presentationView.superview, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [presentationView removeFromSuperview];
        [keyboardContainer addSubview:presentationView];
    }

    UIInterfaceOrientation orientation = liveCarplayWindow.orientation;
    BOOL landscape = UIInterfaceOrientationIsLandscape(orientation);
    CGSize sceneSize = keyboardWindow.bounds.size;
    CGSize uprightSize = landscape ? CGSizeMake(MAX(sceneSize.width, sceneSize.height), MIN(sceneSize.width, sceneSize.height)) : CGSizeMake(MIN(sceneSize.width, sceneSize.height), MAX(sceneSize.width, sceneSize.height));
    CGFloat keyboardHeight = lastKeyboardHeight;
    if (keyboardHeight <= 0 || keyboardHeight >= uprightSize.height)
    {
        // no arbiter update yet: roughly an iPhone keyboard with its prediction bar
        keyboardHeight = uprightSize.height * (landscape ? 0.5 : 0.38);
    }

    CGRect target = [appContainerView.superview convertRect:appContainerView.frame toView:carplayRootWindow];
    CGFloat scale = CRCarplayKeyboardScale(target.size, uprightSize, keyboardHeight);
    CGFloat drawnHeight = keyboardHeight * scale;

    keyboardContainer.hidden = NO;
    keyboardContainer.frame = CGRectMake(target.origin.x, CGRectGetMaxY(target) - drawnHeight, target.size.width, drawnHeight);
    [carplayRootWindow bringSubviewToFront:keyboardContainer];

    // bottom-aligned and centered: the keyboard sits along the bottom edge of the (upright) scene
    presentationView.transform = CGAffineTransformIdentity;
    presentationView.bounds = CGRectMake(0, 0, sceneSize.width, sceneSize.height);
    presentationView.transform = CGAffineTransformScale(CGAffineTransformMakeRotation(CRAngleForInterfaceOrientation(orientation)), scale, scale);
    presentationView.center = CGPointMake(target.size.width / 2.0, drawnHeight - (uprightSize.height * scale) / 2.0);
    presentationView.hidden = NO;
    presentationView.alpha = 1.0;
    presentationView.userInteractionEnabled = YES;

    // the app reports this height to itself in its keyboard notifications, so it moves content above the keyboard.
    // it ignores repeats, and a relaunched app starts without one, so just send it every time
    NSString *bundleIdentifier = objcInvoke(liveCarplayWindow.application, @"bundleIdentifier");
    if (bundleIdentifier)
    {
        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.carplayenable.keyboard" object:bundleIdentifier userInfo:@{@"height": @(drawnHeight)}];
    }
    return YES;
}

void CRRelayoutCarplayKeyboards(void)
{
    for (UIWindow *keyboardWindow in [carplayKeyboardWindows allObjects])
    {
        CRLayoutCarplayKeyboard(keyboardWindow);
    }
}

%hook SBMedusaHostedKeyboardWindow

- (void)setHidden:(BOOL)hidden
{
    // SpringBoard hides it since the CarPlay app isn't in the phone's layout, so keep it up while hosting
    if (objcInvoke([UIApplication sharedApplication], @"liveCarplayWindow"))
    {
        %orig(NO);
        CRLayoutCarplayKeyboard((UIWindow *)self);
        return;
    }

    CRLayoutCarplayKeyboard((UIWindow *)self);
    %orig;
}

%end

/*
18.x has no SBMainDisplaySceneLayoutViewController to walk, so keep a weak list of app scene views
that have laid out at least once
*/
static NSHashTable *liveSceneViews;

static void CRRegisterSceneView(id sceneView)
{
    if (!liveSceneViews)
    {
        liveSceneViews = [[NSHashTable weakObjectsHashTable] retain];
    }
    [liveSceneViews addObject:sceneView];
}

// SBSceneView asserts ("already been invalidated") if touched after -invalidate
static BOOL CRSceneViewIsInvalidated(id sceneView)
{
    Ivar invalidatedIvar = class_getInstanceVariable([sceneView class], "_invalidated");
    if (!invalidatedIvar)
    {
        return NO;
    }
    return *(BOOL *)((uint8_t *)(__bridge void *)sceneView + ivar_getOffset(invalidatedIvar));
}

NSArray *CRSceneViewsForSceneHandle(id sceneHandle, UIWindow *excludingWindow)
{
    NSMutableArray *matches = [NSMutableArray array];
    for (UIView *sceneView in [liveSceneViews allObjects])
    {
        // views torn down with the CarPlay window lose their window first, so skip windowless and invalidated ones too
        UIWindow *window = [sceneView window];
        if (!window || window == excludingWindow || CRSceneViewIsInvalidated(sceneView) || ![objcInvoke(sceneView, @"sceneHandle") isEqual:sceneHandle])
        {
            continue;
        }
        [matches addObject:sceneView];
    }
    return matches;
}

%hook SBDeviceApplicationSceneView

/*
Is this a main-screen scene view for an application that is being hosted on the Carplay screen?
*/
%new
- (BOOL)isMainScreenCounterpartToLiveCarplayApp
{
    id liveCarplayWindow = objcInvoke([UIApplication sharedApplication], @"liveCarplayWindow");
    if (liveCarplayWindow != nil)
    {
        id liveAppViewController = [liveCarplayWindow appViewController];
        id carplaySceneHandle = objcInvoke(liveAppViewController, @"sceneHandle");
        if ([carplaySceneHandle isEqual:objcInvoke(self, @"sceneHandle")])
        {
            LOG_LIFECYCLE_EVENT;
            id carplayAppViewController = getIvar(liveAppViewController, @"_deviceAppViewController");
            id carplayAppSceneView = objcInvoke(carplayAppViewController, @"_sceneView");
            return carplayAppSceneView && [self isEqual:carplayAppSceneView] == NO;
        }
    }

    return NO;
}

/*
 * Determine if this sceneview is what is being displayed on the carplay screen
*/
%new
- (BOOL)isHostingContentOnCarplayScreen {
    id liveCarplayWindow = objcInvoke([UIApplication sharedApplication], @"liveCarplayWindow");
    if (liveCarplayWindow != nil)
    {
        id liveAppViewController = [liveCarplayWindow appViewController];
        id carplaySceneHandle = objcInvoke(liveAppViewController, @"sceneHandle");
        if ([carplaySceneHandle isEqual:objcInvoke(self, @"sceneHandle")])
        {
            id carplayAppViewController = getIvar(liveAppViewController, @"_deviceAppViewController");
            id carplayAppSceneView = objcInvoke(carplayAppViewController, @"_sceneView");
            return carplayAppSceneView && [self isEqual:carplayAppSceneView];
        }
    }

    return NO;
}

- (void)layoutSubviews
{
    %orig;
    CRRegisterSceneView(self);

    BOOL isCarplayCounterpart = objcInvokeT(self, @"isMainScreenCounterpartToLiveCarplayApp", BOOL);
    if (isCarplayCounterpart)
    {
        LOG_LIFECYCLE_EVENT;
        long long currentDisplayMode = objcInvokeT(self, @"displayMode", long long);
        BOOL isHostingAnApp = currentDisplayMode == 4;
        if (isHostingAnApp)
        {
            // Only interested in forcing the layout when this scene is in CustomContent/Placeholder mode
            return;
        }

        // The placeholder view will try to match the orientation of the application, which if running on Carplay may not match the orientation of the main screen.
        // Force the UI to match the main screens orientation. This will end up calling -layoutSubviews again
        objcInvoke(self, @"rotateToDeviceOrientation");
        UIView *backgroundView = objcInvoke(self, @"backgroundView");
        if (backgroundView == nil) {
            return;
        }

        // Draw the Carplay placeholder UI, but only if this view is being layed out in the correct orientation.
        // It is expected that this method will be called at least once while the view is in the wrong orientation
        BOOL bgIsLandscape = [backgroundView frame].size.width > [backgroundView frame].size.height;
        BOOL deviceIsLandscape = UIInterfaceOrientationIsLandscape((UIInterfaceOrientation)[[UIDevice currentDevice] orientation]);
        if (bgIsLandscape == deviceIsLandscape)
        {
            // Orientation expectation satisfied
            objcInvoke(self, @"drawCarplayPlaceholder");
        }
    }
}

- (id)homeGrabberView {

    id homeGrabberView = %orig;
    if (!homeGrabberView) {
        return homeGrabberView;
    }

    if (objcInvokeT(self, @"isHostingContentOnCarplayScreen", BOOL)) {        
        objcInvoke_3(homeGrabberView, @"setHidden:forReason:withAnimationSettings:", YES, @"CarPlay", nil);
        objcInvoke_1(homeGrabberView, @"setUserInteractionEnabled:", NO);
    }

    return homeGrabberView;
}

/*
This scene view (and its background view, which the custom ui is drawn on) rotates automatically with the app's orientation changes.
Because the app's orientation may not match the device's real orientation, this view may be layed out incorrectly for the main screen.
Walk superviews looking for the view that handles orientation changes, and force it to match the physical device orientation
*/
%new
- (void)rotateToDeviceOrientation
{
    UIView *backgroundView = objcInvoke(self, @"backgroundView");

    id orientationTransformedView = nil;
    id _candidate = [backgroundView superview];
    while (_candidate != nil)
    {
        if (_candidate && [_candidate isKindOfClass:objc_getClass("SBOrientationTransformWrapperView")])
        {
            orientationTransformedView = _candidate;
            break;
        }

        _candidate = [_candidate superview];
    }

    if (orientationTransformedView != nil)
    {
        long long deviceOrientation = [[UIDevice currentDevice] orientation];
        objcInvokeIf_1(orientationTransformedView, @"setContentOrientation:", deviceOrientation);
    }
}

/*
An app can only run on 1 screen at a time. If an App is launched on the main screen while also being hosted on
the carplay screen, the mainscreen will show a blurred background with a label.
*/
%new
- (void)drawCarplayPlaceholder
{
    LOG_LIFECYCLE_EVENT;
    NSInteger deviceOrientation = [[UIDevice currentDevice] orientation];
    // The background view may have already been drawn on. Use an associated object to determine if its already been handled for this orientation
    // If it was drawn for a different orientation, start fresh
    UIView *backgroundView = objcInvoke(self, @"backgroundView");
    if (backgroundView == nil) {
        NSLog(@"On-device app scene for a carplay-hosted app has a nil background view");
        return;
    }

    id _drawnForOrientation = objc_getAssociatedObject(backgroundView, &kPropertyKey_didDrawPlaceholder);
    NSInteger drawnForOrientation = (_drawnForOrientation) ? [_drawnForOrientation integerValue] : -1;
    if (drawnForOrientation != deviceOrientation)
    {
        // Needs to be created. If it was already made, remove the label subview
        if (drawnForOrientation > 0)
        {
            for (UIView *subview in [backgroundView subviews])
            {
                if ([subview isKindOfClass:objc_getClass("UILabel")])
                {
                    [subview removeFromSuperview];
                }
            }
        }

        // Set associated object to avoid redrawing if no orientation changes have happened
        objc_setAssociatedObject(backgroundView, &kPropertyKey_didDrawPlaceholder, @(deviceOrientation), OBJC_ASSOCIATION_RETAIN);

        // [[UIScreen mainscreen] bounds] may not be using the correct orientation. Get screen bounds for explicit orientation
        CGRect screenBounds = ((CGRect (*)(id, SEL, NSInteger))objc_msgSend)([UIScreen mainScreen], NSSelectorFromString(@"boundsForOrientation:"), deviceOrientation);

        UILabel *hostedOnCarplayLabel = [[[UILabel alloc] initWithFrame:CGRectMake(0, 300, screenBounds.size.width, 50)] autorelease];
        [hostedOnCarplayLabel setText:@"Running on CarPlay Screen"];
        [hostedOnCarplayLabel setTextAlignment:NSTextAlignmentCenter];
        [hostedOnCarplayLabel setFont:[UIFont systemFontOfSize:24 weight:UIFontWeightSemibold]];
        [hostedOnCarplayLabel setCenter:[backgroundView center]];
        [backgroundView addSubview:hostedOnCarplayLabel];
    }

    // Wallpaper style to a nice blur
    objcInvokeIf_1(backgroundView, @"setWallpaperStyle:", (long long)18);

    // Set mode to Placeholder (makes the backgroundView become visible)
    id animationFactory = objcInvoke(objc_getClass("SBApplicationSceneView"), @"defaultDisplayModeAnimationFactory");
    objcInvoke_3(self, @"setDisplayMode:animationFactory:completion:", (long long)1, animationFactory, nil);
}

/*
Display mode is being changed.
The relevant modes for this tweak are LiveContent (interactive app) and Placeholder (usually a blackscreen, but we'll pretty it up)
*/
- (void)setDisplayMode:(long long)arg1 animationFactory:(id)arg2 completion:(id)arg3
{
    BOOL isCarplayCounterpart = objcInvokeT(self, @"isMainScreenCounterpartToLiveCarplayApp", BOOL);
    BOOL requestingLiveContent = arg1 == 4;
    if (requestingLiveContent && isCarplayCounterpart)
    {
        LOG_LIFECYCLE_EVENT;
        // An app is being opened on the mainscreen while already running on the carplay screen.
        // Force the display mode to Placeholder instead of LiveContent
        %orig((long long)1, arg2, arg3);
        return;
    }

    %orig;
}

%end

%hook SBApplicationSceneHandleRequest 

+ (id)defaultSceneSpecificationForDisplayIdentity:(id)arg1 {
    LOG_LIFECYCLE_EVENT;

    id displayConfiguration = objcInvoke([UIScreen mainScreen], @"fbsDisplay");
    id identity = objcInvoke(displayConfiguration, @"identity");
    return %orig(identity);
}

%end

%hook UIScreen

%new
- (CGRect)boundsForOrientation:(UIInterfaceOrientation)orientation
{
    CGFloat width = [self bounds].size.width;
    CGFloat height = [self bounds].size.height;

    CGRect bounds = CGRectZero;
    if (UIInterfaceOrientationIsLandscape(orientation))
    {
        bounds.size = CGSizeMake(MAX(width, height), MIN(width, height));
    }
    else
    {
        bounds.size = CGSizeMake(MIN(width, height), MAX(width, height));
    }

    return bounds;
}

%end

/*
Called when the device's main screen is turning on or off
*/
int hook_BKSDisplayServicesSetScreenBlanked(int arg1)
{
    id liveCarplayWindow = objcInvoke([UIApplication sharedApplication], @"liveCarplayWindow");
    if (arg1 == 1 && liveCarplayWindow != nil)
    {
        LOG_LIFECYCLE_EVENT;
        // The device's screen is turning off while an app is hosted on the carplay display
        NSArray *lockAssertions = objc_getAssociatedObject([UIApplication sharedApplication], &kPropertyKey_lockAssertionIdentifiers);

        id sceneHandle = objcInvoke([liveCarplayWindow appViewController], @"sceneHandle");
        id appScene = objcInvoke(sceneHandle, @"sceneIfExists");
        if (appScene)
        {
            NSString *sceneAppBundleID = CRBundleIDForScene(appScene);
            if (sceneAppBundleID && [lockAssertions containsObject:sceneAppBundleID])
            {
                // Turn the screen off as originally intended
                if (orig_BKSDisplayServicesSetScreenBlanked) {
                    orig_BKSDisplayServicesSetScreenBlanked(1);
                }

                // Wait for the events to propagate through the system, then undo it (doing this too early doesn't work).
                // This does not actually turn the display on
                if (orig_BKSDisplayServicesSetScreenBlanked) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                        orig_BKSDisplayServicesSetScreenBlanked(0);
                    });
                }
                
                return 0;
            }
        }
    }

    return orig_BKSDisplayServicesSetScreenBlanked ? orig_BKSDisplayServicesSetScreenBlanked(arg1) : 0;
}

%end

%group KEYBOARD_ARBITER

%hook _UIKeyboardArbiter

// runs on the arbiter's queue every time a keyboard comes up, changes height or goes down
- (void)setLastUpdate:(id)update
{
    %orig;

    SEL positionSel = NSSelectorFromString(@"keyboardPositionWithIAV");
    if (![update respondsToSelector:positionSel])
    {
        return;
    }
    CGRect position = ((CGRect (*)(id, SEL))objc_msgSend)(update, positionSel);
    if (position.size.height <= 0)
    {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        lastKeyboardHeight = position.size.height;
        CRRelayoutCarplayKeyboards();
    });
}

%end

%end

%ctor
{
    BAIL_IF_UNSUPPORTED_IOS;

    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"])
    {
        %init(SPRINGBOARD);
        if (objc_getClass("_UIKeyboardArbiter"))
        {
            %init(KEYBOARD_ARBITER);
        }
        // Hook BKSDisplayServicesSetScreenBlanked() - necessary for allowing animations/video when the screen is off
        void *_BKSDisplayServicesSetScreenBlanked = dlsym(dlopen(NULL, 0), "BKSDisplayServicesSetScreenBlanked");
        if (_BKSDisplayServicesSetScreenBlanked)
            MSHookFunction(_BKSDisplayServicesSetScreenBlanked, (void *)hook_BKSDisplayServicesSetScreenBlanked, (void **)&orig_BKSDisplayServicesSetScreenBlanked);
    }
}