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

%ctor
{
    BAIL_IF_UNSUPPORTED_IOS;

    // Only need to inject into User Apps (+ jailbreak) apps
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundlePath containsString:@".app"] && ![bundleIdentifier containsString:@"com.apple."])
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