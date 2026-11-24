#include "../common.h"
#include "../CRCarplayWindow.h"
#include "../CRSpringBoardMode.h"
#include "../CRCarAppSwitcher.h"


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

/*
Host an app on the CarPlay screen, in CarPlay's app area (appFrame, display points; empty to guess it)
*/
static UIEdgeInsets CRKeyboardDevicePadding(UIInterfaceOrientation orientation);

// apps running as iPad apps (iPad layout setting), bundle id -> pid
static NSMutableDictionary<NSString *, NSNumber *> *padLayoutPids;

/*
Leaves the iPad layout marker for the app and restarts it if it's running in the other layout. YES if it was
stopped, to launch once it's gone
*/
static BOOL CRPrepareLayoutForCarplay(NSString *identifier)
{
    [[CRPreferences sharedInstance] reloadPreferences];
    // iPhone-only apps (Compass) have no iPad layout to switch to
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
        // tapping the app's icon again while it's up (e.g. in CarPlay's sidebar) shouldn't restart it
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

/*
When an app icon is tapped on the Carplay dashboard
*/
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

/*
CarPlay's home button, or another app (or the dashboard) taking the screen
*/
%new
- (void)handleCarPlayCloseNotification:(id)notification
{
    LOG_LIFECYCLE_EVENT;
    [objcInvoke(self, @"liveCarplayWindow") dismiss];
}

/*
Invoked when SpringBoard finishes launching
*/
- (void)applicationDidFinishLaunching:(id)arg1
{
    LOG_LIFECYCLE_EVENT;
    // Setup to receive App Launch notifications from the CarPlay process
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserver:self selector:NSSelectorFromString(@"handleCarPlayLaunchNotification:") name:@"com.carplayenable" object:nil];
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserver:self selector:NSSelectorFromString(@"handleCarPlayCloseNotification:") name:@"com.carplayenable.close" object:nil];
    // a respring takes down any app window, tell a CarPlay process that outlived us
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.carplayenable.closed" object:nil userInfo:nil];

    // Receive notifications for Carplay connect/disconnect events. When a Carplay screen becomes unavailable while an app is being hosted on it, that app window needs to be closed
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
    // CarPlay's home button: pressed twice, the car app switcher; once, away from it
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
        // The Preference pane is requesting a list of installed apps + icons. Gather the info
        id appController = objcInvoke(objc_getClass("SBApplicationController"), @"sharedInstance");
        NSMutableArray *appList = [[NSMutableArray alloc] init];
        for (id appInfo in objcInvoke(appController, @"allInstalledApplications"))
        {
            NSString *identifier = objcInvoke(appInfo, @"bundleIdentifier");
            // Apple's own apps only when they have a home screen icon, the same rule CarPlay uses to show them
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
    if (!getCarplayCADisplay())
    {
        dispatch_async(dispatch_get_main_queue(), ^(void) {
            [[CRSpringBoardMode sharedInstance] exit];
        });
    }
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

%hook SBMainWorkspace

/*
An app on the car opening a link (or another app). SpringBoard turns it down since the app isn't visible on the phone,
so the app it opens goes on the car instead, handed the link.
*/
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
// Spotlight's one scene, while the car's search shows it
static BOOL CRSceneIsCarSearch(id scene)
{
    return [objcInvoke(scene, @"identifier") isEqual:@"searchScreen"] && [[CRSpringBoardMode sharedInstance] isSearchShowing];
}

/*
The car is landscape, so its Spotlight is too (its keyboard follows the scene). The frame is in the phone display's
portrait space: a tall frame makes the landscape scene wide.
*/
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

%hook SBDeviceApplicationSceneHandle

/*
The app changed what it asks of its scene, which includes the orientations it supports (e.g. a video player that
only does landscape)
*/
- (void)_didUpdateClientSettingsWithDiff:(id)diff transitionContext:(id)transitionContext
{
    %orig;
    CRCarPlayWindow *liveCarplayWindow = objcInvoke([UIApplication sharedApplication], @"liveCarplayWindow");
    if (liveCarplayWindow && !liveCarplayWindow.isDismissing && objcInvoke(liveCarplayWindow.appViewController, @"sceneHandle") == self)
    {
        // not from inside the scene's own update
        dispatch_async(dispatch_get_main_queue(), ^{
            [liveCarplayWindow followAppSupportedOrientations];
        });
    }
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
static const NSInteger kCarSearchKeyboardBackgroundTag = 0x4b424447;
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

// the keyboard's padding on this phone (the bottom one holds the globe and dictation keys)
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

// returns NO if there's no CarPlay window (or nothing to host) and the keyboard should stay on the phone
static BOOL CRLayoutCarplayKeyboard(UIWindow *keyboardWindow)
{
    CRCarPlayWindow *liveCarplayWindow = objcInvoke([UIApplication sharedApplication], @"liveCarplayWindow");
    UIView *keyboardContainer = objc_getAssociatedObject(keyboardWindow, &kCarplayKeyboardContainerKey);
    UIWindow *carplayRootWindow = liveCarplayWindow.rootWindow;
    UIView *appContainerView = liveCarplayWindow.appContainerView;
    // no CarPlay app: the car home screen's Spotlight, across the whole car window
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

    // the car's Spotlight scene is landscape
    UIInterfaceOrientation orientation = carSearch ? UIInterfaceOrientationLandscapeRight : liveCarplayWindow.orientation;
    CGRect target = [appContainerView.superview convertRect:appContainerView.frame toView:carplayRootWindow];
    // a portrait app in the wide app area gets a landscape keyboard (the app turns it; Apple's apps don't load the hooks)
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
        // no arbiter update yet: roughly an iPhone keyboard with its prediction bar
        keyboardHeight = uprightSize.height * (landscape ? 0.5 : 0.38);
    }

    // the phone's portrait keyboard reports its height without the strip under it (globe and dictation keys)
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

    // Spotlight draws the keyboard's background itself where it thinks the keyboard is, so give the car's one its own
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
    // the car search needs a keyboard window that may never have been on the car
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

// the car is landscape, so its Spotlight (and keyboard) can be too
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

// Spotlight is one scene: landscape while it's on the car (its keyboard follows), portrait again for the phone
%hook SPUIRemoteSearchViewController

- (void)updateSceneSettingsWithBlock:(void (^)(id))block
{
    %orig(^(id settings) {
        if (block)
        {
            block(settings);
        }
        // the FBScene hooks turn it landscape for the car; portrait again for the phone
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
    // SpringBoard hides it since the CarPlay app isn't in the phone's layout, so keep it up while hosting
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

// the car home screen's landscape grid gives labels more room than SpringBoard sized its image pools for,
// and an image bigger than a pool slot asserts. drop the pool for those (4 bytes a pixel is the worst case)
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

// where the car home screen's page dots go (centre y in the folder view), just above the dock
static CGFloat carPageDotsCenterY = NAN;
// compared by identity only, never messaged
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
    // the dots are centred in a taller accessory view, move that
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

// SpringBoard puts the dots back while scrolling, keep them where the car home screen wants them
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

// the car home screen's pages hold as many icons as its grid shows, not the phone's 24
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

/*
The car home screen's App Library: ours (CarPlay's icon, the car's) first in Utilities
*/
%hook SBHLibraryViewController

// apps only: not the category pods or their small grids
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
            // Suggestions has Settings too
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

/*
The App Library's blur covers the whole screen as it fades in, over the last home page too. On the car's wide screen
that's most of a page: keep it to the library's page, sliding in with it, at full strength
*/
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

/*
The car's landscape pages would use the rotated grid, which drops free placement's gaps (and repacks the icons). The
car's grid is its own (see CRCarRootGridSize), so they lay out upright like the phone's
*/
// grid cell info option bits: 2 rotated layout, 4 gaps allowed
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

// buttons' menus (edit mode's Edit button) open in the window, at full size: open them in the scaled home screen
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

// the App Library's icons don't ask the drag manager
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
    // gaps yes, rotated no
    return CRIsCarListView((UIView *)self) ? (%orig & ~kCRGridCellInfoRotated) : %orig;
}

// laid out upright like the phone's pages (the car's grid is set up the same both ways)
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

// the car home screen's dock fits as many icons as its width allows
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

// the car's widgets open their app on the car screen, with the widget's action
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

/*
The phone's home screen hears every icon editor open and close (the notifications say nothing of whose), the car's too,
and takes over the screen for each: a second one at once aborts SpringBoard. The car's isn't its business
*/
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

// the car's frosted backgrounds get a capture group apart from the phone's (CRSeparateMaterialGroups)
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

// in the car home screen's edit mode a hold on an icon drags it (CRSpringBoardMode) instead of opening its menu
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

/*
App Library category bars style themselves with the modern bar appearance API, which UIKit refuses (throws) for
CarPlay-idiom bars. On the car screen they keep the default look
*/
%hook SBHFeatherBlurNavigationBar

- (void)_updateAppearance
{
    if (((UIView *)self).traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomCarPlay)
    {
        return;
    }
    // a bar made before it picked up the home screen's phone traits is still a CarPlay one
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

/*
System alerts (permission prompts are user notifications from tccd, locationd) go to the phone's screen. With the
setting on and an app open on the car, they're shown over that app instead
*/
static NSMutableArray *carAlertItems;
static char kCarAlertControllerKey;

static UIWindow *carAlertWindow;

// a window of its own over the app on the car, while alerts are up
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
    // laid out bigger and scaled down like the app, the car screen is short for an alert
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

// alerts cap their height by the screen's (the car's is short), the car's alert window is taller
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
    // a button tap dismisses it already
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