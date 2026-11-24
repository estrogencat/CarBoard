#include "../common.h"
#include "../CRCarplayWindow.h"
#include "../CRSpringBoardMode.h"
#include "../CRCarAppSwitcher.h"


%group SPRINGBOARD

int (*orig_BKSDisplayServicesSetScreenBlanked)(int);

%hook SBSuspendedUnderLockManager

- (BOOL)_shouldBeBackgroundUnderLockForScene:(id)arg2 withSettings:(id)arg3
{
    BOOL shouldBackground = %orig;
    if (shouldBackground)
    {
        // keeps car apps running while the phone is locked
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

static UIEdgeInsets CRKeyboardDevicePadding(UIInterfaceOrientation orientation);

static NSMutableDictionary<NSString *, NSNumber *> *padLayoutPids;

// switches the app between iPad and iPhone layout; YES if it had to be restarted first
static BOOL CRPrepareLayoutForCarplay(NSString *identifier)
{
    [[CRPreferences sharedInstance] reloadPreferences];
    // iPhone-only apps have no iPad layout
    id proxy = objcInvoke_1(objc_getClass("LSApplicationProxy"), @"applicationProxyForIdentifier:", identifier);
    NSArray *families = [proxy respondsToSelector:NSSelectorFromString(@"deviceFamily")] ? objcInvoke(proxy, @"deviceFamily") : nil;
    BOOL padLayout = [[CRPreferences sharedInstance] iPadAppLayout] && [families containsObject:@2];
    CRSetPadLayoutMarker(identifier, padLayout);

    id application = objcInvoke_1(objcInvoke(objc_getClass("SBApplicationController"), @"sharedInstance"), @"applicationWithBundleIdentifier:", identifier);
    id processState = [application respondsToSelector:NSSelectorFromString(@"processState")] ? objcInvoke(application, @"processState") : nil;
    int pid = [processState respondsToSelector:NSSelectorFromString(@"pid")] ? ((int (*)(id, SEL))objc_msgSend)(processState, NSSelectorFromString(@"pid")) : 0;
    BOOL running = [processState respondsToSelector:NSSelectorFromString(@"isRunning")] && ((BOOL (*)(id, SEL))objc_msgSend)(processState, NSSelectorFromString(@"isRunning"));
    BOOL runningAsPad = pid > 0 && [padLayoutPids[identifier] intValue] == pid;
    if (!running || pid <= 0 || padLayout == runningAsPad)
    {
        return NO;
    }
    CRLog(@"%@ is running as an %@ app, restarting it", identifier, runningAsPad ? @"iPad" : @"iPhone");
    kill(pid, SIGKILL);
    return YES;
}

static void CRLaunchAppOnCarplay(NSString *identifier, CGRect appFrame, NSSet *actions)
{
    @try
    {
        id sharedApp = [UIApplication sharedApplication];
        CRCarPlayWindow *liveCarplayWindow = objcInvoke(sharedApp, @"liveCarplayWindow");
        [[CRCarAppSwitcher sharedInstance] hideAnimated:YES];
        [[CRCarAppSwitcher sharedInstance] noteAppOpened:identifier appFrame:appFrame];
        if ([identifier isEqualToString:kCRSpringBoardBundleID])
        {
            [liveCarplayWindow dismiss];
            [[CRSpringBoardMode sharedInstance] enterWithAppFrame:appFrame];
            return;
        }
        if (liveCarplayWindow && !liveCarplayWindow.isDismissing && [[liveCarplayWindow bundleIdentifier] isEqualToString:identifier])
        {
            [liveCarplayWindow deliverActions:actions];
            return;
        }
        [liveCarplayWindow dismiss];

        void (^openWindow)(void) = ^{
            CRCarPlayWindow *window = [[[CRCarPlayWindow alloc] initWithBundleIdentifier:identifier appFrame:appFrame launchActions:actions] autorelease];
            objc_setAssociatedObject(sharedApp, &kPropertyKey_liveCarplayWindow, window, OBJC_ASSOCIATION_RETAIN);
        };
        if (CRPrepareLayoutForCarplay(identifier))
        {
            // give FrontBoard time to see the old process go
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), openWindow);
            return;
        }
        openWindow();
    }
    @catch (NSException *exception)
    {
        CRLog(@"carplay window launch failed: %@", exception);
    }
}

%hook SpringBoard

%new
- (void)handleCarPlayLaunchNotification:(id)notification
{
    LOG_LIFECYCLE_EVENT;
    NSDictionary *userInfo = [notification userInfo];
    NSString *identifier = userInfo[@"identifier"];
    NSString *appFrameString = userInfo[@"appFrame"];
    if (identifier)
    {
        CRLaunchAppOnCarplay(identifier, appFrameString ? CGRectFromString(appFrameString) : CGRectZero, nil);
    }
}

%new
- (void)handleCarPlayCloseNotification:(id)notification
{
    LOG_LIFECYCLE_EVENT;
    [objcInvoke(self, @"liveCarplayWindow") dismiss];
}

- (void)applicationDidFinishLaunching:(id)arg1
{
    LOG_LIFECYCLE_EVENT;
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserver:self selector:NSSelectorFromString(@"handleCarPlayLaunchNotification:") name:@"com.carplayenable" object:nil];
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserver:self selector:NSSelectorFromString(@"handleCarPlayCloseNotification:") name:@"com.carplayenable.close" object:nil];
    // a respring closes any app window, tell CarPlay
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.carplayenable.closed" object:nil userInfo:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(carplayIsConnectedChanged) name:@"CarPlayIsConnectedDidChange" object:nil];

    [CRSpringBoardMode sharedInstance].launchHandler = ^(NSString *bundleIdentifier, CGRect appFrame, NSSet *actions) {
        CRLaunchAppOnCarplay(bundleIdentifier, appFrame, actions);
    };
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserverForName:kCRSpringBoardModeShowNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        BOOL showing = [note.userInfo[@"showing"] boolValue];
        if (!showing)
        {
            [[CRCarAppSwitcher sharedInstance] hideAnimated:NO];
        }
        [[CRSpringBoardMode sharedInstance] setShowing:showing];
    }];
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserverForName:kCRSpringBoardModeRestoreNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        CRSpringBoardMode *springBoardMode = [CRSpringBoardMode sharedInstance];
        if (springBoardMode.active || ![springBoardMode wasLeftOn])
        {
            return;
        }
        NSString *appFrame = note.userInfo[@"appFrame"];
        CRLog(@"sbmode: restoring after CarPlay restart");
        CRLaunchAppOnCarplay(kCRSpringBoardBundleID, appFrame ? CGRectFromString(appFrame) : CGRectZero, nil);
    }];
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserverForName:kCRSpringBoardModeExitNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [[CRCarAppSwitcher sharedInstance] hideAnimated:NO];
        [[CRSpringBoardMode sharedInstance] exit];
    }];
    padLayoutPids = [[NSMutableDictionary alloc] init];
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserverForName:kCRCarIconInfoNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [[CRSpringBoardMode sharedInstance] noteCarIconName:note.userInfo[@"name"] imageData:note.userInfo[@"image"]];
    }];
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserverForName:kCRPadLayoutLaunchedNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        if ([note.object isKindOfClass:[NSString class]] && note.userInfo[@"pid"])
        {
            padLayoutPids[note.object] = note.userInfo[@"pid"];
            CRLog(@"%@ started as an iPad app", note.object);
        }
    }];
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserverForName:PREFERENCES_CHANGED_NOTIFICATION object:kPrefsHomeScreenScaleChanged queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [[CRSpringBoardMode sharedInstance] rebuild];
    }];
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserverForName:kCRAppSwitcherShowNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [[CRCarAppSwitcher sharedInstance] show];
    }];
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserverForName:kCRHomePressedNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        BOOL switcherWasUp = [[CRCarAppSwitcher sharedInstance] isShowing];
        [[CRCarAppSwitcher sharedInstance] hideAnimated:YES];
        BOOL sheetWasUp = [[CRSpringBoardMode sharedInstance] closeAddSheet];
        if (!switcherWasUp && !sheetWasUp && ![note.userInfo[@"appShowing"] boolValue])
        {
            [[CRSpringBoardMode sharedInstance] homeButtonPressed];
        }
    }];

    NSMutableArray *appIdentifiersToIgnoreLockAssertions = [[NSMutableArray alloc] init];
    objc_setAssociatedObject(self, &kPropertyKey_lockAssertionIdentifiers, appIdentifiersToIgnoreLockAssertions, OBJC_ASSOCIATION_RETAIN);

    %orig;

    NSOperationQueue *notificationQueue = [[NSOperationQueue alloc] init];
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserverForName:PREFERENCES_APP_DATA_NOTIFICATION object:kPrefsAppDataRequesting queue:notificationQueue usingBlock:^(NSNotification * _Nonnull note) {
        // the prefs pane asks for the installed apps and their icons
        id appController = objcInvoke(objc_getClass("SBApplicationController"), @"sharedInstance");
        NSMutableArray *appList = [[NSMutableArray alloc] init];
        for (id appInfo in objcInvoke(appController, @"allInstalledApplications"))
        {
            NSString *identifier = objcInvoke(appInfo, @"bundleIdentifier");
            // Apple's apps only with a home screen icon, like CarPlay does
            if ([identifier hasPrefix:@"com.apple."])
            {
                id record = ((id (*)(id, SEL, id, BOOL, id *))objc_msgSend)([objc_getClass("LSApplicationRecord") alloc], NSSelectorFromString(@"initWithBundleIdentifier:allowPlaceholder:error:"), identifier, NO, NULL);
                BOOL hasIcon = CRAppRecordHasHomeScreenIcon(record);
                [record release];
                if (!hasIcon)
                {
                    continue;
                }
            }
            if (getIvar(appInfo, @"_carPlayDeclaration") != nil)
            {
                continue;
            }

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

%new
- (void)carplayIsConnectedChanged
{
    LOG_LIFECYCLE_EVENT;
    if (!getCarplayCADisplay())
    {
        dispatch_async(dispatch_get_main_queue(), ^(void) {
            [[CRSpringBoardMode sharedInstance] exit];
        });
    }
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

%hook SBMainWorkspace

// a car app opening a link or another app: SpringBoard refuses since it isn't visible on the phone, so open it on the car
- (void)systemService:(id)service handleOpenApplicationRequest:(id)request withCompletion:(void (^)(id, id))completion
{
    CRCarPlayWindow *liveCarplayWindow = objcInvoke([UIApplication sharedApplication], @"liveCarplayWindow");
    id clientProcess = objcInvoke(request, @"clientProcess");
    NSString *clientID = [clientProcess respondsToSelector:NSSelectorFromString(@"bundleIdentifier")] ? objcInvoke(clientProcess, @"bundleIdentifier") : nil;
    NSString *targetID = objcInvoke(request, @"bundleIdentifier");
    if (!liveCarplayWindow || liveCarplayWindow.isDismissing || !targetID || ![clientID isEqualToString:[liveCarplayWindow bundleIdentifier]])
    {
        %orig;
        return;
    }

    id options = objcInvoke(request, @"options");
    NSURL *url = [options respondsToSelector:NSSelectorFromString(@"url")] ? objcInvoke(options, @"url") : nil;
    NSMutableSet *actions = [NSMutableSet set];
    for (id action in ([options respondsToSelector:NSSelectorFromString(@"actions")] ? objcInvoke(options, @"actions") : nil))
    {
        [actions addObject:action];
    }
    BOOL hasURLAction = NO;
    for (id action in actions)
    {
        hasURLAction |= [action isKindOfClass:objc_getClass("UIOpenURLAction")];
    }
    if (url && !hasURLAction)
    {
        [actions addObject:[[[objc_getClass("UIOpenURLAction") alloc] initWithURL:url] autorelease]];
    }
    CRLog(@"%@ opens %@ (%@) on the car", clientID, targetID, url ? url.scheme : @"no url");
    CGRect appFrame = liveCarplayWindow.rootWindow.frame;
    dispatch_async(dispatch_get_main_queue(), ^{
        CRLaunchAppOnCarplay(targetID, appFrame, actions.count ? actions : nil);
    });
    if (completion)
    {
        completion(nil, nil);
    }
}

%end

%hook SBSceneView

// crashes if the device is face up or down while the car window transforms the scene
- (void)_updateReferenceSize:(struct CGSize)arg1 andOrientation:(long long)arg2
{
    if (arg2 > 4)
    {
        return %orig(arg1, 3);
    }
    %orig;
}

%end

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

// settings properties resolve dynamically on 18.x
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

// keep a car scene foreground, in the car window's orientation and size, whatever the phone's layout wants
static void CRForceCarplaySceneSettings(id settings)
{
    id liveCarplayWindow = objcInvoke([UIApplication sharedApplication], @"liveCarplayWindow");
    CRApplyCarplaySceneSettings(settings, (CRCarPlayWindow *)liveCarplayWindow);
}

static BOOL CRSceneIsCarSearch(id scene)
{
    return [objcInvoke(scene, @"identifier") isEqual:@"searchScreen"] && [[CRSpringBoardMode sharedInstance] isSearchShowing];
}

// the car's Spotlight is landscape; the frame is in the phone's portrait space, so tall means wide
static void CRForceCarSearchSceneSettings(id settings)
{
    if ([settings respondsToSelector:NSSelectorFromString(@"setInterfaceOrientation:")])
    {
        ((void (*)(id, SEL, long long))objc_msgSend)(settings, NSSelectorFromString(@"setInterfaceOrientation:"), UIInterfaceOrientationLandscapeRight);
    }
    if ([settings respondsToSelector:NSSelectorFromString(@"setFrame:")])
    {
        CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(settings, NSSelectorFromString(@"frame"));
        if (frame.size.width > frame.size.height)
        {
            ((void (*)(id, SEL, CGRect))objc_msgSend)(settings, NSSelectorFromString(@"setFrame:"), CGRectMake(frame.origin.x, frame.origin.y, frame.size.height, frame.size.width));
        }
    }
}

/*
18.x mostly updates scenes through block APIs that never reach updateSettings:withTransitionContext:completion:,
so wrap the block and force the car settings after it. Only the first block argument (the settings) is ever touched.
*/
static id CRWrapSceneUpdateBlock(id scene, id block)
{
    if (!block)
    {
        return block;
    }
    if (CRSceneIsCarSearch(scene))
    {
        void *(^originalBlock)(id, void *) = block;
        return [[^void *(id settings, void *passthrough) {
            void *result = originalBlock(settings, passthrough);
            CRForceCarSearchSceneSettings(settings);
            return result;
        } copy] autorelease];
    }
    if (!CRSceneIsHostedOnCarplay(scene))
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

// capped so a setter that stops working can't loop forever
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

// keeps the car app foreground when other apps open on the phone
- (void)updateSettings:(id)settings withTransitionContext:(id)arg2 completion:(id)arg3
{
    if (CRSceneIsHostedOnCarplay(self))
    {
        // the phone's layout hands over immutable settings
        if (![settings isKindOfClass:objc_getClass("UIMutableApplicationSceneSettings")] && [settings isKindOfClass:objc_getClass("UIApplicationSceneSettings")])
        {
            settings = [[settings mutableCopy] autorelease];
        }
        CRForceCarplaySceneSettings(settings);
    }
    else if (CRSceneIsCarSearch(self))
    {
        if ([settings respondsToSelector:NSSelectorFromString(@"mutableCopy")] && ![settings respondsToSelector:NSSelectorFromString(@"setFrame:")])
        {
            settings = [[settings mutableCopy] autorelease];
        }
        CRForceCarSearchSceneSettings(settings);
    }

    %orig(settings, arg2, arg3);
}

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
SBAppViewController asserts if its scene goes background unexpectedly, which the phone's layout does to a car app.
Skip the check for the car window's controller and restore the scene next runloop.
*/
- (void)sceneHandle:(id)sceneHandle didUpdateSettingsWithDiff:(id)diff previousSettings:(id)previousSettings
{
    id liveCarplayWindow = objcInvoke([UIApplication sharedApplication], @"liveCarplayWindow");
    if (liveCarplayWindow && self == [(CRCarPlayWindow *)liveCarplayWindow appViewController])
    {
        id appScene = objcInvoke(sceneHandle, @"sceneIfExists");
        id settings = objcInvoke(appScene, @"settings");
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

%hook SBDeviceApplicationSceneHandle

// the app changed its supported orientations (e.g. a landscape-only video player)
- (void)_didUpdateClientSettingsWithDiff:(id)diff transitionContext:(id)transitionContext
{
    %orig;
    CRCarPlayWindow *liveCarplayWindow = objcInvoke([UIApplication sharedApplication], @"liveCarplayWindow");
    if (liveCarplayWindow && !liveCarplayWindow.isDismissing && objcInvoke(liveCarplayWindow.appViewController, @"sceneHandle") == self)
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            [liveCarplayWindow followAppSupportedOrientations];
        });
    }
}

%end

%hook SBSwitcherController

// the phone's app switcher follows the device orientation, not the car app's
- (void)_updateContentViewInterfaceOrientation:(long long)arg1
{
    if (objcInvoke([UIApplication sharedApplication], @"liveCarplayWindow") != nil)
    {
        LOG_LIFECYCLE_EVENT;
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
The keyboard is its own scene in SBMedusaHostedKeyboardWindow, covering the phone display in portrait coordinates.
Move it onto the car window, rotate it like the app, and scale it to fit the app's width and about half its height.
*/
static NSHashTable *carplayKeyboardWindows;
static CGFloat lastKeyboardHeight;
static const NSInteger kCarSearchKeyboardBackgroundTag = 0x4b424447;
static char kCarplayKeyboardContainerKey;
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

// the bottom padding holds the globe and dictation keys
static UIEdgeInsets CRKeyboardDevicePadding(UIInterfaceOrientation orientation)
{
    Class keyboardImpl = objc_getClass("UIKeyboardImpl");
    SEL paddingSel = NSSelectorFromString(@"deviceSpecificPaddingForInterfaceOrientation:inputMode:");
    if (![keyboardImpl respondsToSelector:paddingSel])
    {
        return UIEdgeInsetsZero;
    }
    id inputMode = objcInvoke(objcInvoke(objc_getClass("UIKeyboardInputModeController"), @"sharedInputModeController"), @"currentInputMode");
    return ((UIEdgeInsets (*)(id, SEL, long long, id))objc_msgSend)(keyboardImpl, paddingSel, (long long)orientation, inputMode);
}

// NO when the keyboard should stay on the phone
static BOOL CRLayoutCarplayKeyboard(UIWindow *keyboardWindow)
{
    CRCarPlayWindow *liveCarplayWindow = objcInvoke([UIApplication sharedApplication], @"liveCarplayWindow");
    UIView *keyboardContainer = objc_getAssociatedObject(keyboardWindow, &kCarplayKeyboardContainerKey);
    UIWindow *carplayRootWindow = liveCarplayWindow.rootWindow;
    UIView *appContainerView = liveCarplayWindow.appContainerView;
    CRSpringBoardMode *springBoardMode = [CRSpringBoardMode sharedInstance];
    BOOL carSearch = !liveCarplayWindow && [springBoardMode isSearchShowing];
    if (carSearch)
    {
        carplayRootWindow = springBoardMode.window;
        appContainerView = springBoardMode.window.rootViewController.view;
    }
    id presenter = getIvar(keyboardWindow, @"_remoteHostedKeyboardScenePresenter");
    UIView *presentationView = [presenter respondsToSelector:NSSelectorFromString(@"presentationView")] ? objcInvoke(presenter, @"presentationView") : nil;
    if (!carplayRootWindow || !appContainerView || !presentationView)
    {
        if (keyboardContainer)
        {
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

    UIInterfaceOrientation orientation = carSearch ? UIInterfaceOrientationLandscapeRight : liveCarplayWindow.orientation;
    CGRect target = [appContainerView.superview convertRect:appContainerView.frame toView:carplayRootWindow];
    // a portrait app in the wide app area gets a landscape keyboard (Apple's apps don't load the hooks)
    NSString *keyboardAppIdentifier = [liveCarplayWindow bundleIdentifier];
    if (!carSearch && orientation == UIInterfaceOrientationPortrait && target.size.width > target.size.height && ![keyboardAppIdentifier hasPrefix:@"com.apple."])
    {
        orientation = UIInterfaceOrientationLandscapeLeft;
    }
    BOOL landscape = UIInterfaceOrientationIsLandscape(orientation);
    CGSize sceneSize = keyboardWindow.bounds.size;
    CGSize uprightSize = landscape ? CGSizeMake(MAX(sceneSize.width, sceneSize.height), MIN(sceneSize.width, sceneSize.height)) : CGSizeMake(MIN(sceneSize.width, sceneSize.height), MAX(sceneSize.width, sceneSize.height));
    CGFloat keyboardHeight = lastKeyboardHeight;
    if (keyboardHeight <= 0 || keyboardHeight >= uprightSize.height)
    {
        keyboardHeight = uprightSize.height * (landscape ? 0.5 : 0.38);
    }

    // the portrait keyboard's reported height leaves out the globe/dictation strip
    if ((!landscape || carSearch) && lastKeyboardHeight > 0)
    {
        CGFloat bottomPadding = CRKeyboardDevicePadding(orientation).bottom;
        if (keyboardHeight + bottomPadding < uprightSize.height)
        {
            keyboardHeight += bottomPadding;
        }
    }
    CGFloat scale = CRCarplayKeyboardScale(target.size, uprightSize, keyboardHeight);
    CGFloat drawnHeight = keyboardHeight * scale;

    keyboardContainer.hidden = NO;
    keyboardContainer.frame = CGRectMake(target.origin.x, CGRectGetMaxY(target) - drawnHeight, target.size.width, drawnHeight);
    [carplayRootWindow bringSubviewToFront:keyboardContainer];

    // Spotlight draws the keyboard background where it thinks the keyboard is, so the car gets its own
    UIView *keyboardBackground = [keyboardContainer viewWithTag:kCarSearchKeyboardBackgroundTag];
    if (carSearch && !keyboardBackground)
    {
        keyboardBackground = [[[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]] autorelease];
        keyboardBackground.tag = kCarSearchKeyboardBackgroundTag;
        keyboardBackground.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [keyboardContainer insertSubview:keyboardBackground atIndex:0];
        CRSeparateMaterialGroups(keyboardBackground);
    }
    keyboardBackground.frame = keyboardContainer.bounds;
    keyboardBackground.hidden = !carSearch;

    presentationView.transform = CGAffineTransformIdentity;
    presentationView.bounds = CGRectMake(0, 0, sceneSize.width, sceneSize.height);
    presentationView.transform = CGAffineTransformScale(CGAffineTransformMakeRotation(CRAngleForInterfaceOrientation(orientation)), scale, scale);
    presentationView.center = CGPointMake(target.size.width / 2.0, drawnHeight - (uprightSize.height * scale) / 2.0);
    presentationView.hidden = NO;
    presentationView.alpha = 1.0;
    presentationView.userInteractionEnabled = YES;

    // lets the app move its content above the keyboard; sent every time since the app ignores repeats
    NSString *bundleIdentifier = carSearch ? nil : objcInvoke(liveCarplayWindow.application, @"bundleIdentifier");
    if (bundleIdentifier)
    {
        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.carplayenable.keyboard" object:bundleIdentifier userInfo:@{@"height": @(drawnHeight / (liveCarplayWindow.appScale > 0 ? liveCarplayWindow.appScale : 1.0))}];
    }
    return YES;
}

static BOOL CRKeyboardBelongsOnCar(void)
{
    return objcInvoke([UIApplication sharedApplication], @"liveCarplayWindow") || [[CRSpringBoardMode sharedInstance] isSearchShowing];
}

void CRRelayoutCarplayKeyboards(void)
{
    Class keyboardWindowClass = objc_getClass("SBMedusaHostedKeyboardWindow");
    for (UIWindow *window in [[UIApplication sharedApplication] windows])
    {
        if (keyboardWindowClass && [window isKindOfClass:keyboardWindowClass] && ![carplayKeyboardWindows containsObject:window])
        {
            if (CRLayoutCarplayKeyboard(window))
            {
                window.hidden = NO;
            }
        }
    }
    for (UIWindow *keyboardWindow in [carplayKeyboardWindows allObjects])
    {
        CRLayoutCarplayKeyboard(keyboardWindow);
    }
}

%hook SBSpotlightMultiplexingViewController

+ (unsigned long long)spotlightSupportedInterfaceOrientations
{
    unsigned long long orientations = %orig;
    if ([[CRSpringBoardMode sharedInstance] isSearchShowing])
    {
        orientations |= (1 << UIInterfaceOrientationLandscapeLeft) | (1 << UIInterfaceOrientationLandscapeRight);
    }
    return orientations;
}

%end

%hook SPUIRemoteSearchViewController

- (void)updateSceneSettingsWithBlock:(void (^)(id))block
{
    %orig(^(id settings) {
        if (block)
        {
            block(settings);
        }
        if (![[CRSpringBoardMode sharedInstance] isSearchShowing] && [settings respondsToSelector:NSSelectorFromString(@"setInterfaceOrientation:")])
        {
            ((void (*)(id, SEL, long long))objc_msgSend)(settings, NSSelectorFromString(@"setInterfaceOrientation:"), UIInterfaceOrientationPortrait);
        }
    });
}

%end

%hook SBMedusaHostedKeyboardWindow

- (void)setHidden:(BOOL)hidden
{
    // SpringBoard hides it since the car app isn't in the phone's layout
    if (CRKeyboardBelongsOnCar())
    {
        %orig(NO);
        CRLayoutCarplayKeyboard((UIWindow *)self);
        return;
    }

    CRLayoutCarplayKeyboard((UIWindow *)self);
    %orig;
}

%end

// 18.x has no SBMainDisplaySceneLayoutViewController, so track laid out scene views
static NSHashTable *liveSceneViews;

static void CRRegisterSceneView(id sceneView)
{
    if (!liveSceneViews)
    {
        liveSceneViews = [[NSHashTable weakObjectsHashTable] retain];
    }
    [liveSceneViews addObject:sceneView];
}

// SBSceneView asserts if touched after -invalidate
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
            return;
        }

        objcInvoke(self, @"rotateToDeviceOrientation");
        UIView *backgroundView = objcInvoke(self, @"backgroundView");
        if (backgroundView == nil) {
            return;
        }

        // only draw once laid out in the device orientation
        BOOL bgIsLandscape = [backgroundView frame].size.width > [backgroundView frame].size.height;
        BOOL deviceIsLandscape = UIInterfaceOrientationIsLandscape((UIInterfaceOrientation)[[UIDevice currentDevice] orientation]);
        if (bgIsLandscape == deviceIsLandscape)
        {
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

// match the device orientation, not the car app's
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

// an app open on the car shows a blurred placeholder on the phone
%new
- (void)drawCarplayPlaceholder
{
    LOG_LIFECYCLE_EVENT;
    NSInteger deviceOrientation = [[UIDevice currentDevice] orientation];
    UIView *backgroundView = objcInvoke(self, @"backgroundView");
    if (backgroundView == nil) {
        NSLog(@"On-device app scene for a carplay-hosted app has a nil background view");
        return;
    }

    id _drawnForOrientation = objc_getAssociatedObject(backgroundView, &kPropertyKey_didDrawPlaceholder);
    NSInteger drawnForOrientation = (_drawnForOrientation) ? [_drawnForOrientation integerValue] : -1;
    if (drawnForOrientation != deviceOrientation)
    {
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

        objc_setAssociatedObject(backgroundView, &kPropertyKey_didDrawPlaceholder, @(deviceOrientation), OBJC_ASSOCIATION_RETAIN);

        CGRect screenBounds = ((CGRect (*)(id, SEL, NSInteger))objc_msgSend)([UIScreen mainScreen], NSSelectorFromString(@"boundsForOrientation:"), deviceOrientation);

        UILabel *hostedOnCarplayLabel = [[[UILabel alloc] initWithFrame:CGRectMake(0, 300, screenBounds.size.width, 50)] autorelease];
        [hostedOnCarplayLabel setText:@"Running on CarPlay Screen"];
        [hostedOnCarplayLabel setTextAlignment:NSTextAlignmentCenter];
        [hostedOnCarplayLabel setFont:[UIFont systemFontOfSize:24 weight:UIFontWeightSemibold]];
        [hostedOnCarplayLabel setCenter:[backgroundView center]];
        [backgroundView addSubview:hostedOnCarplayLabel];
    }

    objcInvokeIf_1(backgroundView, @"setWallpaperStyle:", (long long)18);

    id animationFactory = objcInvoke(objc_getClass("SBApplicationSceneView"), @"defaultDisplayModeAnimationFactory");
    objcInvoke_3(self, @"setDisplayMode:animationFactory:completion:", (long long)1, animationFactory, nil);
}

- (void)setDisplayMode:(long long)arg1 animationFactory:(id)arg2 completion:(id)arg3
{
    BOOL isCarplayCounterpart = objcInvokeT(self, @"isMainScreenCounterpartToLiveCarplayApp", BOOL);
    BOOL requestingLiveContent = arg1 == 4;
    if (requestingLiveContent && isCarplayCounterpart)
    {
        LOG_LIFECYCLE_EVENT;
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

// the car grid's labels can outgrow SpringBoard's image pool slots, which asserts; skip the pool for those
static id CRPoolForImage(id pool, CGSize size, CGFloat scale)
{
    if (!pool)
    {
        return nil;
    }
    size_t width = (size_t)ceil(size.width * scale), height = (size_t)ceil(size.height * scale);
    size_t needed = ((width * 4 + 63) & ~(size_t)63) * height;
    return needed > objcInvokeT(pool, @"slotLength", size_t) ? nil : pool;
}

static CGFloat carPageDotsCenterY = NAN;
static void *carPageDotsView;

static BOOL CRIsCarPageDotsView(UIView *view)
{
    UIWindow *carWindow = [[CRSpringBoardMode sharedInstance] window];
    return carWindow && (void *)view == carPageDotsView && view.window == carWindow && !isnan(carPageDotsCenterY);
}

%hook SBFolderView

- (void)layoutSubviews
{
    %orig;
    UIWindow *carWindow = [[CRSpringBoardMode sharedInstance] window];
    if (!carWindow || ((UIView *)self).window != carWindow || ![self respondsToSelector:NSSelectorFromString(@"dockView")])
    {
        return;
    }
    UIView *pageControl = objcInvoke(self, @"pageControl");
    UIView *accessoryView = [pageControl isKindOfClass:[UIView class]] ? pageControl.superview : nil;
    UIView *dockView = objcInvoke(self, @"dockView");
    if (!accessoryView.superview || ![dockView isKindOfClass:[UIView class]] || !dockView.superview)
    {
        return;
    }
    carPageDotsView = (void *)accessoryView;
    carPageDotsCenterY = [dockView.superview convertPoint:dockView.frame.origin toView:accessoryView.superview].y - 14;
    accessoryView.center = CGPointMake(accessoryView.center.x, carPageDotsCenterY);
}

%end

// SpringBoard moves the dots back while scrolling
%hook SBFolderScrollAccessoryView

- (void)setCenter:(CGPoint)center
{
    if (CRIsCarPageDotsView((UIView *)self))
    {
        center.y = carPageDotsCenterY;
    }
    %orig(center);
}

- (void)setFrame:(CGRect)frame
{
    if (CRIsCarPageDotsView((UIView *)self))
    {
        frame.origin.y = carPageDotsCenterY - frame.size.height / 2;
    }
    %orig(frame);
}

%end

static BOOL CRCarRootGridSize(id model, Class folderClass, CRIconGridSize *size)
{
    NSUInteger columns = 0, rows = 0;
    Class rootFolderClass = objc_getClass("SBRootFolder");
    if (!rootFolderClass || ![folderClass isSubclassOfClass:rootFolderClass] || ![[CRSpringBoardMode sharedInstance] rootGridColumns:&columns rows:&rows forIconModel:model])
    {
        return NO;
    }
    size->columns = (unsigned short)columns;
    size->rows = (unsigned short)rows;
    return YES;
}

%hook SBHLibraryViewController

- (BOOL)iconViewDisplaysCloseBox:(id)iconView
{
    if (![[CRSpringBoardMode sharedInstance] isCarLibrary:self])
    {
        return %orig;
    }
    id icon = [iconView respondsToSelector:NSSelectorFromString(@"icon")] ? objcInvoke(iconView, @"icon") : nil;
    SEL isLeaf = NSSelectorFromString(@"isLeafIcon");
    SEL isWidget = NSSelectorFromString(@"isWidgetIcon");
    BOOL app = [icon respondsToSelector:isLeaf] && ((BOOL (*)(id, SEL))objc_msgSend)(icon, isLeaf) && !([icon respondsToSelector:isWidget] && ((BOOL (*)(id, SEL))objc_msgSend)(icon, isWidget));
    if (!app)
    {
        return NO;
    }
    return %orig;
}

- (void)_installCategoryMap:(id)map
{
    NSArray *ours = [[CRSpringBoardMode sharedInstance] libraryIconIdentifiers];
    if (!map || !ours.count || ![[CRSpringBoardMode sharedInstance] isCarLibrary:self])
    {
        %orig;
        return;
    }
    @try
    {
        NSDictionary *byCategory = objcInvoke(map, @"sortedApplicationIdentifiersByCategoryIdentifier");
        id utilities = nil;
        for (id category in byCategory)
        {
            NSString *name = [category respondsToSelector:NSSelectorFromString(@"localizedDisplayName")] ? objcInvoke(category, @"localizedDisplayName") : nil;
            if ([name isEqualToString:@"Utilities"])
            {
                utilities = category;
                break;
            }
        }
        id patched = [[map mutableCopy] autorelease];
        if (utilities && [patched respondsToSelector:NSSelectorFromString(@"setSortedApplicationIdentifiersByCategoryIdentifier:")])
        {
            NSMutableDictionary *patchedByCategory = [[byCategory mutableCopy] autorelease];
            NSMutableArray *identifiers = [[ours mutableCopy] autorelease];
            for (NSString *identifier in byCategory[utilities])
            {
                if (![identifiers containsObject:identifier])
                {
                    [identifiers addObject:identifier];
                }
            }
            patchedByCategory[utilities] = identifiers;
            objcInvoke_1(patched, @"setSortedApplicationIdentifiersByCategoryIdentifier:", patchedByCategory);
            map = patched;
        }
        CRLog(@"sbmode: library map %@, utilities %@", map == patched ? @"patched" : @"left alone", utilities);
    }
    @catch (NSException *exception)
    {
        CRLog(@"sbmode: library map patch failed: %@", exception);
    }
    %orig(map);
}

%end

// the App Library's blur would cover most of the wide car screen; keep it to the library's page
static void CRPinLibraryBackdrop(UIView *folderView)
{
    id manager = objcInvoke([CRSpringBoardMode sharedInstance], @"iconManager");
    if (!manager || objcInvoke(objcInvoke(manager, @"rootFolderController"), @"folderView") != folderView)
    {
        return;
    }
    UIView *backdrop = objcInvoke(folderView, @"trailingCustomBackdropView");
    UIScrollView *scrollView = objcInvoke(folderView, @"scrollView");
    if (!backdrop || backdrop.hidden || ![scrollView isKindOfClass:[UIScrollView class]])
    {
        return;
    }
    CGFloat pageOffset = ((CGFloat (*)(id, SEL))objc_msgSend)(folderView, NSSelectorFromString(@"trailingCustomViewPageScrollOffset"));
    CGRect bounds = folderView.bounds;
    CGFloat left = MIN(MAX(0, pageOffset - scrollView.contentOffset.x), bounds.size.width);
    backdrop.frame = CGRectMake(left, 0, bounds.size.width - left, bounds.size.height);
    if ([backdrop respondsToSelector:NSSelectorFromString(@"setTransitionProgress:")])
    {
        ((void (*)(id, SEL, double))objc_msgSend)(backdrop, NSSelectorFromString(@"setTransitionProgress:"), 1.0);
    }
}

// car pages lay out upright: the rotated grid drops free placement's gaps and repacks icons
static const unsigned long long kCRGridCellInfoRotated = 2;

static BOOL CRIsCarListView(UIView *listView)
{
    id model = [listView respondsToSelector:NSSelectorFromString(@"model")] ? objcInvoke(listView, @"model") : nil;
    id folder = [model respondsToSelector:NSSelectorFromString(@"folder")] ? objcInvoke(model, @"folder") : nil;
    return [[CRSpringBoardMode sharedInstance] isCarRootFolder:folder];
}

static BOOL CRIsOnCarWindow(UIView *view)
{
    UIWindow *carWindow = [CRSpringBoardMode sharedInstance].window;
    return carWindow && view.window == carWindow;
}

%hook SBIconDragManager

- (BOOL)iconViewCanBeginDrags:(UIView *)iconView
{
    return CRIsOnCarWindow(iconView) ? NO : %orig;
}

%end

// open button menus (edit mode's Edit) in the scaled home screen
%hook UIButton

- (id)_contextMenuInteraction:(id)interaction styleForMenuWithConfiguration:(id)configuration
{
    id style = %orig;
    UIView *scaledView = objcInvoke([CRSpringBoardMode sharedInstance], @"scaledView");
    if (scaledView && [(UIView *)self isDescendantOfView:scaledView] && [style respondsToSelector:NSSelectorFromString(@"setContainerView:")])
    {
        objcInvoke_1(style, @"setContainerView:", scaledView);
    }
    return style;
}

%end

%hook SBIconView

- (BOOL)canBeginDrags
{
    return CRIsOnCarWindow((UIView *)self) ? NO : %orig;
}

- (NSArray *)dragInteraction:(id)interaction itemsForBeginningSession:(id)session
{
    return CRIsOnCarWindow((UIView *)self) ? @[] : %orig;
}

%end

%hook SBIconListView

- (unsigned long long)gridCellInfoOptions
{
    return CRIsCarListView((UIView *)self) ? (%orig & ~kCRGridCellInfoRotated) : %orig;
}

- (id)initWithModel:(id)model layoutProvider:(id)layoutProvider iconLocation:(id)location orientation:(long long)orientation iconViewProvider:(id)iconViewProvider
{
    id folder = [model respondsToSelector:NSSelectorFromString(@"folder")] ? objcInvoke(model, @"folder") : nil;
    BOOL car = [[CRSpringBoardMode sharedInstance] isCarRootFolder:folder];
    return %orig(model, layoutProvider, location, car ? UIInterfaceOrientationPortrait : orientation, iconViewProvider);
}

- (void)setOrientation:(long long)orientation
{
    %orig(CRIsCarListView((UIView *)self) ? UIInterfaceOrientationPortrait : orientation);
}

%end

%hook SBRootFolderView

- (void)layoutSubviews
{
    %orig;
    CRPinLibraryBackdrop((UIView *)self);
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    %orig;
    CRPinLibraryBackdrop((UIView *)self);
}

%end

%hook SBHIconModel

- (CRIconGridSize)listGridSizeForFolderClass:(Class)folderClass
{
    CRIconGridSize size;
    return CRCarRootGridSize(self, folderClass, &size) ? size : %orig;
}

- (CRIconGridSize)listWithNonDefaultSizedIconsGridSizeForFolderClass:(Class)folderClass
{
    CRIconGridSize size;
    return CRCarRootGridSize(self, folderClass, &size) ? size : %orig;
}

- (unsigned long long)maxIconCountForDock
{
    NSUInteger count = [[CRSpringBoardMode sharedInstance] dockIconCountForIconModelOrManager:self];
    return count ?: %orig;
}

%end

%hook SBHIconManager

- (unsigned long long)gridCellInfoOptions
{
    return [[CRSpringBoardMode sharedInstance] isCarIconManager:self] ? (%orig & ~kCRGridCellInfoRotated) : %orig;
}

- (unsigned long long)gridCellInfoOptionsForOrientation:(long long)orientation
{
    return [[CRSpringBoardMode sharedInstance] isCarIconManager:self] ? (%orig & ~kCRGridCellInfoRotated) : %orig;
}

- (void)widgetHostViewController:(id)controller requestsLaunch:(id)launch
{
    CRSpringBoardMode *mode = [CRSpringBoardMode sharedInstance];
    if (![mode isCarIconManager:self])
    {
        %orig;
        return;
    }
    [mode launchWidgetRequest:launch];
}

- (unsigned long long)maxIconCountForDock
{
    NSUInteger count = [[CRSpringBoardMode sharedInstance] dockIconCountForIconModelOrManager:self];
    return count ?: %orig;
}

%end

// the phone's home screen reacts to every icon editor, the car's too, and a second one at once aborts SpringBoard
static BOOL carStyleEditorNotifying;

%hook SBHIconManager

- (void)setIconStylePickerVisible:(BOOL)visible
{
    BOOL isCar = [[CRSpringBoardMode sharedInstance] isCarIconManager:self];
    carStyleEditorNotifying = isCar;
    %orig;
    carStyleEditorNotifying = NO;
}

%end

%hook SBIconController

- (void)informIconStyleObserversOfStyleChange
{
    %orig;
    [[CRSpringBoardMode sharedInstance] updateIconStyle];
}

- (void)_styleEditorWillPresent:(NSNotification *)notification
{
    if (!carStyleEditorNotifying)
    {
        %orig;
    }
}

- (void)_styleEditorDidDismiss:(NSNotification *)notification
{
    if (!carStyleEditorNotifying)
    {
        %orig;
    }
}

%end

%hook MTMaterialView

- (void)didMoveToWindow
{
    %orig;
    UIWindow *carWindow = [[CRSpringBoardMode sharedInstance] window];
    if (carWindow && ((UIView *)self).window == carWindow)
    {
        CRSeparateMaterialGroups((UIView *)self);
    }
}

%end

%hook SBIconView

- (BOOL)allowsContextMenus
{
    CRSpringBoardMode *springBoardMode = [CRSpringBoardMode sharedInstance];
    if (springBoardMode.window && ((UIView *)self).window == springBoardMode.window && [springBoardMode isEditing])
    {
        return NO;
    }
    return %orig;
}

%end

// UIKit throws for the modern bar appearance on CarPlay-idiom bars
%hook SBHFeatherBlurNavigationBar

- (void)_updateAppearance
{
    if (((UIView *)self).traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomCarPlay)
    {
        return;
    }
    @try
    {
        %orig;
    }
    @catch (NSException *exception)
    {
        CRLog(@"library bar appearance: %@", exception.reason);
    }
}

%end

%hook UIImage

+ (id)sbf_imageFromContextWithSize:(CGSize)size scale:(CGFloat)scale type:(NSInteger)type pool:(id)pool drawing:(id)drawing
{
    return %orig(size, scale, type, CRPoolForImage(pool, size, scale), drawing);
}

+ (id)sbf_imageFromContextWithSize:(CGSize)size scale:(CGFloat)scale type:(NSInteger)type pool:(id)pool drawing:(id)drawing encapsulation:(NSInteger)encapsulation
{
    return %orig(size, scale, type, CRPoolForImage(pool, size, scale), drawing, encapsulation);
}

+ (id)sbf_imageFromBGRAContextWithSize:(CGSize)size scale:(CGFloat)scale colorSpace:(CGColorSpaceRef)colorSpace withAlpha:(BOOL)withAlpha pool:(id)pool drawing:(id)drawing encapsulation:(NSInteger)encapsulation
{
    return %orig(size, scale, colorSpace, withAlpha, CRPoolForImage(pool, size, scale), drawing, encapsulation);
}

%end

// system alerts (permission prompts) go over the car app instead of the phone, when the setting is on
static NSMutableArray *carAlertItems;
static char kCarAlertControllerKey;

static UIWindow *carAlertWindow;

static UIViewController *CRCarAlertPresenter(void)
{
    CRCarPlayWindow *liveCarplayWindow = objcInvoke([UIApplication sharedApplication], @"liveCarplayWindow");
    UIWindow *appWindow = liveCarplayWindow.rootWindow;
    if (!liveCarplayWindow || liveCarplayWindow.isDismissing || !appWindow || appWindow.hidden)
    {
        return nil;
    }
    if (!carAlertWindow || carAlertWindow.screen != appWindow.screen)
    {
        id displayConfiguration = objcInvoke(appWindow.screen, @"displayConfiguration");
        if (!displayConfiguration)
        {
            return nil;
        }
        [carAlertWindow release];
        carAlertWindow = objcInvoke_1([objc_getClass("UIRootSceneWindow") alloc], @"initWithDisplayConfiguration:", displayConfiguration);
        UIViewController *rootViewController = [[[UIViewController alloc] init] autorelease];
        rootViewController.view.backgroundColor = [UIColor clearColor];
        carAlertWindow.rootViewController = rootViewController;
    }
    CGFloat scale = liveCarplayWindow.appScale > 0 ? MIN(liveCarplayWindow.appScale, 1) : 1;
    carAlertWindow.transform = CGAffineTransformIdentity;
    carAlertWindow.frame = appWindow.frame;
    carAlertWindow.bounds = CGRectMake(0, 0, appWindow.frame.size.width / scale, appWindow.frame.size.height / scale);
    carAlertWindow.transform = CGAffineTransformMakeScale(scale, scale);
    carAlertWindow.center = CGPointMake(CGRectGetMidX(appWindow.frame), CGRectGetMidY(appWindow.frame));
    carAlertWindow.backgroundColor = [UIColor clearColor];
    carAlertWindow.windowLevel = appWindow.windowLevel + 1;
    carAlertWindow.hidden = NO;
    UIViewController *presenter = carAlertWindow.rootViewController;
    while (presenter.presentedViewController && !presenter.presentedViewController.isBeingDismissed)
    {
        presenter = presenter.presentedViewController;
    }
    return presenter;
}

static void CRHideCarAlertWindowIfDone(void)
{
    if (!carAlertItems.count)
    {
        carAlertWindow.hidden = YES;
    }
}

// alerts cap their height by the screen's, and the car's is short
%hook _UIAlertControllerPhoneTVMacView

- (void)updateConstraints
{
    %orig;
    UIWindow *window = ((UIView *)self).window;
    if (!carAlertWindow || window != carAlertWindow || ![self respondsToSelector:NSSelectorFromString(@"contentViewMaxHeightConstraint")])
    {
        return;
    }
    NSLayoutConstraint *maxHeight = objcInvoke(self, @"contentViewMaxHeightConstraint");
    CGFloat extra = window.bounds.size.height - window.screen.bounds.size.height;
    if (maxHeight && extra > 0 && maxHeight.constant + extra <= window.bounds.size.height)
    {
        maxHeight.constant += extra;
    }
}

%end

%hook SBAlertItemsController

- (void)activateAlertItem:(id)item
{
    if (![item isKindOfClass:objc_getClass("SBUserNotificationAlert")] || [carAlertItems containsObject:item])
    {
        %orig;
        return;
    }
    [[CRPreferences sharedInstance] reloadPreferences];
    UIViewController *presenter = [[CRPreferences sharedInstance] alertsOnCar] ? CRCarAlertPresenter() : nil;
    if (!presenter)
    {
        %orig;
        return;
    }
    UIViewController *alertController = nil;
    @try
    {
        objcInvoke(item, @"willActivate");
        alertController = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(item, NSSelectorFromString(@"_prepareNewAlertControllerWithLockedState:requirePasscodeForActions:"), NO, NO);
    }
    @catch (NSException *exception)
    {
        CRLog(@"car alert: couldn't make %@: %@", item, exception);
    }
    if (![alertController isKindOfClass:[UIViewController class]])
    {
        CRHideCarAlertWindowIfDone();
        %orig;
        return;
    }
    CRLog(@"car alert: %@ on the car", item);
    if (!carAlertItems)
    {
        carAlertItems = [[NSMutableArray alloc] init];
    }
    [carAlertItems addObject:item];
    objc_setAssociatedObject(item, &kCarAlertControllerKey, alertController, OBJC_ASSOCIATION_RETAIN);
    [presenter presentViewController:alertController animated:YES completion:^{
        objcInvoke(item, @"didActivate");
    }];
}

- (void)_deactivateAlertItem:(id)item reason:(int)reason animated:(BOOL)animated alertDismissCompletion:(void (^)(void))completion
{
    if (![carAlertItems containsObject:item])
    {
        %orig;
        return;
    }
    CRLog(@"car alert: %@ done (%d)", item, reason);
    [[item retain] autorelease];
    [carAlertItems removeObject:item];
    ((void (*)(id, SEL, int))objc_msgSend)(item, NSSelectorFromString(@"willDeactivateForReason:"), reason);
    UIViewController *alertController = objc_getAssociatedObject(item, &kCarAlertControllerKey);
    void (^finish)(void) = [^{
        ((void (*)(id, SEL, int))objc_msgSend)(item, NSSelectorFromString(@"didDeactivateForReason:"), reason);
        objc_setAssociatedObject(item, &kCarAlertControllerKey, nil, OBJC_ASSOCIATION_RETAIN);
        CRHideCarAlertWindowIfDone();
        if (completion)
        {
            completion();
        }
    } copy];
    if (alertController.presentingViewController && !alertController.isBeingDismissed)
    {
        [alertController.presentingViewController dismissViewControllerAnimated:animated completion:finish];
    }
    else
    {
        finish();
    }
    [finish release];
}

%end

int hook_BKSDisplayServicesSetScreenBlanked(int arg1)
{
    id liveCarplayWindow = objcInvoke([UIApplication sharedApplication], @"liveCarplayWindow");
    if (arg1 == 1 && liveCarplayWindow != nil)
    {
        LOG_LIFECYCLE_EVENT;
        NSArray *lockAssertions = objc_getAssociatedObject([UIApplication sharedApplication], &kPropertyKey_lockAssertionIdentifiers);

        id sceneHandle = objcInvoke([liveCarplayWindow appViewController], @"sceneHandle");
        id appScene = objcInvoke(sceneHandle, @"sceneIfExists");
        if (appScene)
        {
            NSString *sceneAppBundleID = CRBundleIDForScene(appScene);
            if (sceneAppBundleID && [lockAssertions containsObject:sceneAppBundleID])
            {
                if (orig_BKSDisplayServicesSetScreenBlanked) {
                    orig_BKSDisplayServicesSetScreenBlanked(1);
                }

                // undo it once the events propagate (too early doesn't work); this doesn't turn the display on
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
        // lets animations and video keep running on the car while the screen is off
        void *_BKSDisplayServicesSetScreenBlanked = dlsym(dlopen(NULL, 0), "BKSDisplayServicesSetScreenBlanked");
        if (_BKSDisplayServicesSetScreenBlanked)
            MSHookFunction(_BKSDisplayServicesSetScreenBlanked, (void *)hook_BKSDisplayServicesSetScreenBlanked, (void **)&orig_BKSDisplayServicesSetScreenBlanked);
    }
}