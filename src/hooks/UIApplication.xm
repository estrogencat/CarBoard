#include "../common.h"

/*
Injected into User Applications
*/
%group APPS

static int orientationOverride = -1;
// height SpringBoard draws the keyboard at on the CarPlay screen, in window points (0 until it says)
static CGFloat carplayKeyboardHeight;
// the system's userInfo and object (its UIScreen) for the keyboard currently on screen, to re-report it when that
// height changes. Telegram only measures against its own window when the object is a screen
static NSDictionary *visibleKeyboardInfo;
static id visibleKeyboardObject;

static NSString *const kCRPatchedKeyboardInfoKey = @"CRCarplayKeyboardFrame";

static BOOL CRIsKeyboardFrameNotification(NSString *name)
{
    return [name isEqualToString:UIKeyboardWillShowNotification] || [name isEqualToString:UIKeyboardDidShowNotification] ||
        [name isEqualToString:UIKeyboardWillHideNotification] || [name isEqualToString:UIKeyboardDidHideNotification] ||
        [name isEqualToString:UIKeyboardWillChangeFrameNotification] || [name isEqualToString:UIKeyboardDidChangeFrameNotification];
}

// the system's frames are in the phone screen's portrait or landscape space; the keyboard spans that space's width
static BOOL CRKeyboardFrameIsOnScreen(CGRect frame, CGSize screenSize)
{
    CGFloat shortSide = MIN(screenSize.width, screenSize.height);
    CGFloat spaceHeight = frame.size.width > shortSide + 0.5 ? shortSide : MAX(screenSize.width, screenSize.height);
    return frame.size.height > 0 && CGRectGetMinY(frame) < spaceHeight - 0.5;
}

/*
The keyboard reports its frame on the phone's screen, and not even consistently (it can give just the bottom bar),
but the CarPlay window draws it scaled down along the bottom of the app. Report that frame instead, so the app moves
its content above what is actually drawn.
*/
static NSDictionary *CRCarplayKeyboardUserInfo(NSString *name, id object, NSDictionary *userInfo)
{
    // postNotificationName: may land in postNotification:, only patch once
    UIWindow *keyWindow = objcInvoke([UIApplication sharedApplication], @"keyWindow");
    if (!keyWindow || userInfo[kCRPatchedKeyboardInfoKey])
    {
        return userInfo;
    }

    CGSize screenSize = keyWindow.screen.bounds.size;
    BOOL landscape = UIInterfaceOrientationIsLandscape((UIInterfaceOrientation)orientationOverride);
    CGSize uprightSize = landscape ? CGSizeMake(MAX(screenSize.width, screenSize.height), MIN(screenSize.width, screenSize.height)) : CGSizeMake(MIN(screenSize.width, screenSize.height), MAX(screenSize.width, screenSize.height));
    CGSize windowSize = keyWindow.bounds.size;
    BOOL hiding = [name isEqualToString:UIKeyboardWillHideNotification] || [name isEqualToString:UIKeyboardDidHideNotification];

    NSMutableDictionary *patched = [[userInfo mutableCopy] autorelease];
    patched[kCRPatchedKeyboardInfoKey] = @YES;
    BOOL endOnScreen = NO;
    for (NSString *key in @[UIKeyboardFrameBeginUserInfoKey, UIKeyboardFrameEndUserInfoKey])
    {
        NSValue *value = userInfo[key];
        if (!value)
        {
            continue;
        }
        CGRect frame = [value CGRectValue];
        // a keyboard that's off the bottom of the phone's screen stays just below the window
        BOOL onScreen = !hiding && CRKeyboardFrameIsOnScreen(frame, screenSize);
        if ([key isEqualToString:UIKeyboardFrameEndUserInfoKey])
        {
            endOnScreen = onScreen;
        }
        CGFloat drawnHeight = carplayKeyboardHeight > 0 ? carplayKeyboardHeight : frame.size.height * CRCarplayKeyboardScale(windowSize, uprightSize, frame.size.height);
        CGRect windowRect = CGRectMake(0, onScreen ? windowSize.height - drawnHeight : windowSize.height, windowSize.width, drawnHeight);
        CGRect screenRect = [keyWindow convertRect:windowRect toCoordinateSpace:keyWindow.screen.coordinateSpace];
        patched[key] = [NSValue valueWithCGRect:screenRect];
    }

    NSDictionary *nowVisible = endOnScreen ? userInfo : nil;
    [nowVisible retain];
    [visibleKeyboardInfo release];
    visibleKeyboardInfo = nowVisible;
    id nowVisibleObject = endOnScreen ? object : nil;
    [nowVisibleObject retain];
    [visibleKeyboardObject release];
    visibleKeyboardObject = nowVisibleObject;
    return patched;
}

%hook UIApplication

/*
When the app is launched
*/
- (id)init
{
    id _self = %orig;
    // Register for "orientation change" notifications
    NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserver:_self selector:NSSelectorFromString(@"handleRotationRequest:") name:@"com.carplayenable.orientation" object:bundleIdentifier];
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserver:_self selector:NSSelectorFromString(@"handleCarplayKeyboardHeight:") name:@"com.carplayenable.keyboard" object:bundleIdentifier];
    return _self;
}

/*
When Carplay window is requesting the app to rotate
*/
%new
- (void)handleRotationRequest:(id)notification
{
    LOG_LIFECYCLE_EVENT;
    orientationOverride = [objcInvoke(notification, @"userInfo")[@"orientation"] intValue];

    int orientationToRequest = orientationOverride;
    if (orientationToRequest == -1)
    {
        carplayKeyboardHeight = 0;
        orientationToRequest = [[UIDevice currentDevice] orientation];
        // 0 = unknown, 5/6 = face up/down: not interface orientations
        orientationToRequest = (orientationToRequest < 1 || orientationToRequest > 4) ? 1 : orientationToRequest;
    }

    // might not be created yet...
    UIWindow *keyWindow = objcInvoke([UIApplication sharedApplication], @"keyWindow");
    if (keyWindow)
    {
        ((void (*)(id, SEL, long long, double, BOOL))objc_msgSend)(keyWindow, NSSelectorFromString(@"_setRotatableViewOrientation:duration:force:"), orientationToRequest, 0.0, YES);
    }
}

/*
SpringBoard drew the keyboard at a new height. Usually that arrives after the system's own keyboard notifications,
so tell the app again about the keyboard that is up
*/
%new
- (void)handleCarplayKeyboardHeight:(id)notification
{
    CGFloat height = [objcInvoke(notification, @"userInfo")[@"height"] doubleValue];
    if (height <= 0 || fabs(height - carplayKeyboardHeight) < 0.5)
    {
        return;
    }
    carplayKeyboardHeight = height;

    NSDictionary *keyboardInfo = [[visibleKeyboardInfo retain] autorelease];
    id keyboardObject = [[visibleKeyboardObject retain] autorelease];
    if (orientationOverride > 0 && keyboardInfo)
    {
        [[NSNotificationCenter defaultCenter] postNotificationName:UIKeyboardWillChangeFrameNotification object:keyboardObject userInfo:keyboardInfo];
        [[NSNotificationCenter defaultCenter] postNotificationName:UIKeyboardDidChangeFrameNotification object:keyboardObject userInfo:keyboardInfo];
    }
}

%end

%hook NSNotificationCenter

- (void)postNotificationName:(NSNotificationName)name object:(id)object userInfo:(NSDictionary *)userInfo
{
    if (orientationOverride > 0 && userInfo && CRIsKeyboardFrameNotification(name))
    {
        userInfo = CRCarplayKeyboardUserInfo(name, object, userInfo);
    }
    %orig(name, object, userInfo);
}

- (void)postNotification:(NSNotification *)notification
{
    if (orientationOverride > 0 && notification.userInfo && CRIsKeyboardFrameNotification(notification.name))
    {
        notification = [NSNotification notificationWithName:notification.name object:notification.object userInfo:CRCarplayKeyboardUserInfo(notification.name, notification.object, notification.userInfo)];
    }
    %orig(notification);
}

%end

/*
A portrait app shown in CarPlay's wide app area still gets the phone's portrait keyboard. Turn just the keyboard's
window landscape there; SpringBoard rotates it upright on the car like a landscape app's
*/
static long long CRKeyboardOrientation(long long orientation)
{
    if (orientationOverride != UIInterfaceOrientationPortrait)
    {
        return orientation;
    }
    UIWindow *keyWindow = objcInvoke([UIApplication sharedApplication], @"keyWindow");
    CGSize size = keyWindow.bounds.size;
    return size.width > size.height ? (long long)UIInterfaceOrientationLandscapeLeft : orientation;
}

static CGPoint *CRTouchPointIvar(UITouch *touch, const char *name)
{
    Ivar ivar = class_getInstanceVariable([UITouch class], name);
    return ivar ? (CGPoint *)((uint8_t *)(__bridge void *)touch + ivar_getOffset(ivar)) : NULL;
}

%hook UIRemoteKeyboardWindow

/*
A touch on the app's own scene is tried on the keyboard first, in the app's coordinates. On the car the two scenes are
scaled and placed apart, so that lands on keys that aren't there: only touches the window server gave the keyboard's
scene count.
*/
- (id)_hitTest:(CGPoint)point withEvent:(id)event windowServerHitTestWindow:(UIWindow *)serverWindow
{
    UIWindow *window = (UIWindow *)self;
    BOOL otherScene = serverWindow && serverWindow.windowScene && window.windowScene && serverWindow.windowScene != window.windowScene;
    return otherScene ? nil : %orig;
}

/*
A new touch on a turned keyboard is stored clamped to the portrait screen's width, so its right half can't be tapped
(moves aren't clamped). The hit test just before sees the real point: remember it, and put it back on the touch
*/
static CGPoint lastKeyboardHitPoint;
static CFTimeInterval lastKeyboardHitTime;

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    if (CRKeyboardOrientation(UIInterfaceOrientationPortrait) != UIInterfaceOrientationPortrait && point.x > MIN(((UIWindow *)self).bounds.size.width, ((UIWindow *)self).bounds.size.height))
    {
        lastKeyboardHitPoint = point;
        lastKeyboardHitTime = CACurrentMediaTime();
    }
    return %orig;
}

- (void)sendEvent:(UIEvent *)event
{
    UIWindow *window = (UIWindow *)self;
    CGFloat clampEdge = MIN(window.bounds.size.width, window.bounds.size.height);
    if (event.type == UIEventTypeTouches && CACurrentMediaTime() - lastKeyboardHitTime < 0.2)
    {
        for (UITouch *touch in [event allTouches])
        {
            CGPoint *location = CRTouchPointIvar(touch, "_locationInWindow");
            if (touch.phase != UITouchPhaseBegan || !location || fabs(location->x - (clampEdge - 0.5)) > 0.6 || fabs(location->y - lastKeyboardHitPoint.y) > 2)
            {
                continue;
            }
            static const char *const names[] = {"_locationInWindow", "_previousLocationInWindow", "_preciseLocationInWindow", "_precisePreviousLocationInWindow"};
            for (const char *name : names)
            {
                CGPoint *stored = CRTouchPointIvar(touch, name);
                if (stored)
                {
                    *stored = lastKeyboardHitPoint;
                }
            }
            lastKeyboardHitTime = 0;
        }
    }
    %orig;
}

- (long long)interfaceOrientation
{
    return CRKeyboardOrientation(%orig);
}

- (void)updateForOrientation:(long long)orientation
{
    %orig(CRKeyboardOrientation(orientation));
}

- (void)updateForOrientation:(long long)orientation forceResetTransform:(BOOL)reset
{
    %orig(CRKeyboardOrientation(orientation), reset);
}

- (void)applicationWindow:(id)window didRotateWithOrientation:(long long)orientation duration:(double)duration
{
    %orig(window, CRKeyboardOrientation(orientation), duration);
}

- (void)_setRotatableClient:(id)client toOrientation:(long long)orientation updateStatusBar:(BOOL)updateStatusBar duration:(double)duration force:(BOOL)force isRotating:(BOOL)isRotating
{
    %orig(client, CRKeyboardOrientation(orientation), updateStatusBar, duration, force, isRotating);
}

%end





%hook UIKeyboardSceneDelegate

+ (long long)interfaceOrientation
{
    return CRKeyboardOrientation(%orig);
}

+ (void)setInterfaceOrientation:(long long)orientation
{
    %orig(CRKeyboardOrientation(orientation));
}

%end

/*
Called when a window intends to rotate to a new orientation. Used to force landscape/portrait
*/
%hook UIWindow

- (void)_setRotatableViewOrientation:(long long)orientation duration:(double)duration force:(BOOL)force
{
    if (orientationOverride > 0)
    {
        LOG_LIFECYCLE_EVENT;
        return %orig((long long)orientationOverride, duration, force);
    }
    %orig;
}

%end

%end

/*
While the app is on CarPlay the render server keeps reporting its video layers as not visible (its scene belongs to
the phone's display), and the video renderer stops drawing frames. Keep them visible while hosted.
*/
%group VIDEO_SAMPLE_BUFFER

%hook AVSampleBufferDisplayLayer

- (void)layerDidBecomeVisible:(BOOL)visible
{
    %orig(visible || orientationOverride > 0);
}

%end

%end

// AVPlayerLayer draws through this one
%group VIDEO_PLAYER

%hook FigVideoLayer

- (void)layerDidBecomeVisible:(BOOL)visible
{
    %orig(visible || orientationOverride > 0);
}

%end

%end

/*
iPad layout setting: SpringBoard leaves a marker in the app's tmp folder when it opens the app on the car. The app
then starts as an iPad app (sidebars, split views). Its scenes get iPad traits, but not the keyboard's, which stays
the phone keyboard the car layout is built for
*/
%group PAD

// the app's own code asks from its bundle; the system's (the keyboard among it) from /System or /usr
// Apple's apps keep most of their code in system frameworks (UIKit included): there only the keyboard counts as the system
static BOOL isAppleApp;

static BOOL CRCallerIsSystem(void *returnAddress)
{
    Dl_info info;
    if (!dladdr(returnAddress, &info) || !info.dli_fname)
    {
        return YES;
    }
    const char *path = info.dli_fname;
    if (strncmp(path, "/usr/", 5) == 0)
    {
        return YES;
    }
    if (strncmp(path, "/System/", 8) != 0)
    {
        return NO;
    }
    return !isAppleApp || strstr(path, "TextInput") || strstr(path, "Keyboard");
}

%hook UIDevice

// iPad to the app, so it picks its iPad layout; the system keeps the phone's (its keyboard is the one the car shows)
- (UIUserInterfaceIdiom)userInterfaceIdiom
{
    return CRCallerIsSystem(__builtin_return_address(0)) ? %orig : UIUserInterfaceIdiomPad;
}

- (NSString *)model
{
    return @"iPad";
}

- (NSString *)localizedModel
{
    return @"iPad";
}

%end

// the iPad's orientations (UIKit and many apps answer with the iPhone's, often portrait-only)
%hook UIApplication

- (UIInterfaceOrientationMask)supportedInterfaceOrientationsForWindow:(UIWindow *)window
{
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSArray *names = info[@"UISupportedInterfaceOrientations~ipad"];
    if (![names isKindOfClass:[NSArray class]] || !names.count)
    {
        // an iPad app that can share the screen turns every way there
        NSArray *families = info[@"UIDeviceFamily"];
        BOOL iPadApp = [families isKindOfClass:[NSArray class]] && [families containsObject:@2];
        return iPadApp && ![info[@"UIRequiresFullScreen"] boolValue] ? UIInterfaceOrientationMaskAll : %orig;
    }
    NSDictionary *masks = @{
        @"UIInterfaceOrientationPortrait": @(UIInterfaceOrientationMaskPortrait),
        @"UIInterfaceOrientationPortraitUpsideDown": @(UIInterfaceOrientationMaskPortraitUpsideDown),
        @"UIInterfaceOrientationLandscapeLeft": @(UIInterfaceOrientationMaskLandscapeLeft),
        @"UIInterfaceOrientationLandscapeRight": @(UIInterfaceOrientationMaskLandscapeRight),
    };
    UIInterfaceOrientationMask mask = 0;
    for (NSString *name in names)
    {
        mask |= [masks[name] unsignedIntegerValue];
    }
    return mask ?: %orig;
}

%end


/*
The car window is narrower than an iPad in landscape (992 vs 1133 points at 60%), so split views left to choose for
themselves overlay their list and open on the detail alone. Side by side, once, as a wider iPad would
*/
static char kCRSplitViewTiledKey;

%hook UISplitViewController

- (void)viewWillAppear:(BOOL)animated
{
    %orig;
    UISplitViewController *controller = (UISplitViewController *)self;
    if (objc_getAssociatedObject(controller, &kCRSplitViewTiledKey) || controller.view.bounds.size.width < 700)
    {
        return;
    }
    objc_setAssociatedObject(controller, &kCRSplitViewTiledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (controller.preferredSplitBehavior == UISplitViewControllerSplitBehaviorAutomatic)
    {
        controller.preferredSplitBehavior = UISplitViewControllerSplitBehaviorTile;
    }
    if (controller.preferredDisplayMode == UISplitViewControllerDisplayModeAutomatic)
    {
        controller.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
    }
}

%end

%hook UIWindowScene

- (id)initWithSession:(id)session connectionOptions:(id)connectionOptions
{
    id scene = %orig;
    Class keyboardSceneClass = objc_getClass("_UIKeyboardWindowScene");
    SEL traitOverridesSelector = NSSelectorFromString(@"traitOverrides");
    if (scene && !(keyboardSceneClass && [scene isKindOfClass:keyboardSceneClass]) && [scene respondsToSelector:traitOverridesSelector])
    {
        id overrides = ((id (*)(id, SEL))objc_msgSend)(scene, traitOverridesSelector);
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(overrides, NSSelectorFromString(@"setUserInterfaceIdiom:"), UIUserInterfaceIdiomPad);
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(overrides, NSSelectorFromString(@"setHorizontalSizeClass:"), UIUserInterfaceSizeClassRegular);
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(overrides, NSSelectorFromString(@"setVerticalSizeClass:"), UIUserInterfaceSizeClassRegular);
    }
    return scene;
}

%end

%end

%ctor
{
    BAIL_IF_UNSUPPORTED_IOS;

    // Only need to inject into User Apps (+ jailbreak) apps
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    if (![bundlePath containsString:@".app"] || [bundleIdentifier isEqualToString:kCRSpringBoardBundleID] || [bundleIdentifier isEqualToString:kCRDashBoardBundleID])
    {
        return;
    }
    // Apple's apps too (any with a data container, where SpringBoard leaves the marker)
    NSString *padMarker = [NSTemporaryDirectory() stringByAppendingPathComponent:kCRPadLayoutMarkerName];
    if ([[NSFileManager defaultManager] fileExistsAtPath:padMarker])
    {
        isAppleApp = [bundleIdentifier hasPrefix:@"com.apple."];
        %init(PAD);
        // only for this launch: a respring on the car can't leave the phone with an iPad app
        [[NSFileManager defaultManager] removeItemAtPath:padMarker error:nil];
        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:kCRPadLayoutLaunchedNotification object:bundleIdentifier userInfo:@{@"pid": @(getpid())}];
    }
    if (![bundleIdentifier containsString:@"com.apple."])
    {
        %init(APPS);
        // not every app loads AVFoundation
        if (objc_getClass("AVSampleBufferDisplayLayer"))
        {
            %init(VIDEO_SAMPLE_BUFFER);
        }
        if (objc_getClass("FigVideoLayer"))
        {
            %init(VIDEO_PLAYER);
        }
    }
}