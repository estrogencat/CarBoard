#include "../common.h"

/*
Injected into User Applications
*/
%group APPS

static int orientationOverride = -1;

%hook UIApplication

/*
When the app is launched
*/
- (id)init
{
    id _self = %orig;
    // Register for "orientation change" notifications
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserver:_self selector:NSSelectorFromString(@"handleRotationRequest:") name:@"com.carplayenable.orientation" object:[[NSBundle mainBundle] bundleIdentifier]];
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

%ctor
{
    BAIL_IF_UNSUPPORTED_IOS;

    // Only need to inject into User Apps (+ jailbreak) apps
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundlePath containsString:@".app"] && ![bundleIdentifier containsString:@"com.apple."])
    {
        %init(APPS);
    }
}