#include "../common.h"

%group APPS

static int orientationOverride = -1;
static CGFloat carplayKeyboardHeight;
// re-reported when the car keyboard's height changes; Telegram needs the object to be a screen
static NSDictionary *visibleKeyboardInfo;
static id visibleKeyboardObject;

static NSString *const kCRPatchedKeyboardInfoKey = @"CRCarplayKeyboardFrame";

static BOOL CRIsKeyboardFrameNotification(NSString *name)
{
    return [name isEqualToString:UIKeyboardWillShowNotification] || [name isEqualToString:UIKeyboardDidShowNotification] ||
        [name isEqualToString:UIKeyboardWillHideNotification] || [name isEqualToString:UIKeyboardDidHideNotification] ||
        [name isEqualToString:UIKeyboardWillChangeFrameNotification] || [name isEqualToString:UIKeyboardDidChangeFrameNotification];
}

static BOOL CRKeyboardFrameIsOnScreen(CGRect frame, CGSize screenSize)
{
    CGFloat shortSide = MIN(screenSize.width, screenSize.height);
    CGFloat spaceHeight = frame.size.width > shortSide + 0.5 ? shortSide : MAX(screenSize.width, screenSize.height);
    return frame.size.height > 0 && CGRectGetMinY(frame) < spaceHeight - 0.5;
}

// report the keyboard frame as drawn on the car, so the app moves its content above it
static NSDictionary *CRCarplayKeyboardUserInfo(NSString *name, id object, NSDictionary *userInfo)
{
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

- (id)init
{
    id _self = %orig;
    NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserver:_self selector:NSSelectorFromString(@"handleRotationRequest:") name:@"com.carplayenable.orientation" object:bundleIdentifier];
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserver:_self selector:NSSelectorFromString(@"handleCarplayKeyboardHeight:") name:@"com.carplayenable.keyboard" object:bundleIdentifier];
    return _self;
}

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
        orientationToRequest = (orientationToRequest < 1 || orientationToRequest > 4) ? 1 : orientationToRequest;
    }

    UIWindow *keyWindow = objcInvoke([UIApplication sharedApplication], @"keyWindow");
    if (keyWindow)
    {
        ((void (*)(id, SEL, long long, double, BOOL))objc_msgSend)(keyWindow, NSSelectorFromString(@"_setRotatableViewOrientation:duration:force:"), orientationToRequest, 0.0, YES);
    }
}

// the car keyboard's height usually arrives after the system's notifications, so tell the app again
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

// a portrait app in CarPlay's wide app area gets a landscape keyboard
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

// app touches are tried on the keyboard first in the app's coordinates, which don't match on the car: only take the keyboard scene's own
- (id)_hitTest:(CGPoint)point withEvent:(id)event windowServerHitTestWindow:(UIWindow *)serverWindow
{
    UIWindow *window = (UIWindow *)self;
    BOOL otherScene = serverWindow && serverWindow.windowScene && window.windowScene && serverWindow.windowScene != window.windowScene;
    return otherScene ? nil : %orig;
}

// a new touch on a turned keyboard is clamped to the portrait width; put the real point back from the hit test
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

// the render server reports a car app's video layers as not visible, which stops video frames
%group VIDEO_SAMPLE_BUFFER

%hook AVSampleBufferDisplayLayer

- (void)layerDidBecomeVisible:(BOOL)visible
{
    %orig(visible || orientationOverride > 0);
}

%end

%end

%group VIDEO_PLAYER

%hook FigVideoLayer

- (void)layerDidBecomeVisible:(BOOL)visible
{
    %orig(visible || orientationOverride > 0);
}

%end

%end

// iPad layout: a marker from SpringBoard starts the app as an iPad app, while the keyboard stays the phone's
%group PAD

// the app's own code gets iPad, the system (the keyboard) the phone; for Apple's apps only the keyboard counts as the system
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

// UIKit and many apps answer with the iPhone's, often portrait-only
%hook UIApplication

- (UIInterfaceOrientationMask)supportedInterfaceOrientationsForWindow:(UIWindow *)window
{
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSArray *names = info[@"UISupportedInterfaceOrientations~ipad"];
    if (![names isKindOfClass:[NSArray class]] || !names.count)
    {
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


// the car window is narrower than a landscape iPad, so tile split views side by side once
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

    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    if (![bundlePath containsString:@".app"] || [bundleIdentifier isEqualToString:kCRSpringBoardBundleID] || [bundleIdentifier isEqualToString:kCRDashBoardBundleID])
    {
        return;
    }
    NSString *padMarker = [NSTemporaryDirectory() stringByAppendingPathComponent:kCRPadLayoutMarkerName];
    if ([[NSFileManager defaultManager] fileExistsAtPath:padMarker])
    {
        isAppleApp = [bundleIdentifier hasPrefix:@"com.apple."];
        %init(PAD);
        // only for this launch, so a respring can't leave the phone with an iPad app
        [[NSFileManager defaultManager] removeItemAtPath:padMarker error:nil];
        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:kCRPadLayoutLaunchedNotification object:bundleIdentifier userInfo:@{@"pid": @(getpid())}];
    }
    if (![bundleIdentifier containsString:@"com.apple."])
    {
        %init(APPS);
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