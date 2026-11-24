#include <Foundation/Foundation.h>
#include <UIKit/UIKit.h>
#include <objc/message.h>
#include <dlfcn.h>
#include "CRPreferences.h"
#include <substrate.h>

#define MIN_SUPPORTED_IOS_MAJOR 18
#define MAX_SUPPORTED_IOS_MAJOR 18

#define BAIL_IF_UNSUPPORTED_IOS { \
    NSInteger majorVersion = [NSProcessInfo processInfo].operatingSystemVersion.majorVersion; \
    if (majorVersion < MIN_SUPPORTED_IOS_MAJOR || majorVersion > MAX_SUPPORTED_IOS_MAJOR) { \
        NSLog(@"Unsupported iOS version: %ld.x (supported: %d.x-%d.x)", (long)majorVersion, MIN_SUPPORTED_IOS_MAJOR, MAX_SUPPORTED_IOS_MAJOR); \
        return; \
    } \
}

#define LOG_LIFECYCLE_EVENT { \
    NSString *func = [NSString stringWithFormat:@"%s", __func__]; \
    if ([func containsString:@"_method$"]) \
    { \
        NSArray *components = [func componentsSeparatedByString:@"$"]; \
        NSString *className = components[2]; \
        NSMutableArray *methodComponents = [NSMutableArray array]; \
        for (NSUInteger i = 3; i < components.count; i++) { \
            [methodComponents addObject:components[i]]; \
            if (i < components.count - 1) { \
                [methodComponents addObject:@":"]; \
            } \
        } \
        NSString *formattedMethod = [methodComponents componentsJoinedByString:@""]; \
        func = [NSString stringWithFormat:@"[%@ %@]", className, formattedMethod]; \
    } \
    NSLog(@"[carplayenable] %@", func); \
}

#define getIvar(object, ivar) [object valueForKey:ivar]
#define setIvar(object, ivar, value) [object setValue:value forKey:ivar]

#define CR_LOG_PATH "/var/mobile/Library/Logs/carplayenable.log"
__unused static void CRLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[carplayenable] %@", message);

    static dispatch_queue_t logQueue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logQueue = dispatch_queue_create("carplayenable.log", DISPATCH_QUEUE_SERIAL);
    });
    NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n", [NSDate date], [[NSProcessInfo processInfo] processName], message];
#if !__has_feature(objc_arc)
    [message release];
#endif
    dispatch_async(logQueue, ^{
        FILE *logFile = fopen(CR_LOG_PATH, "a");
        if (logFile) {
            fputs([line UTF8String], logFile);
            fclose(logFile);
        }
    });
}

__unused static void LogSelectorError(id object, SEL selector) {
    CRLog(@"error: %@ does not respond to selector %@", object ? NSStringFromClass([object class]) : @"nil", NSStringFromSelector(selector));
}

#define objcInvokeT(_obj, s, t)                                                       \
({                                                                                \
    SEL         _sel = NSSelectorFromString(s);                                   \
    Method      _m   = _obj ? class_getInstanceMethod(object_getClass(_obj), _sel) : NULL; \
    _m ? ((t (*)(id, SEL))objc_msgSend)(_obj, _sel) : (LogSelectorError(_obj, _sel), (t)0); \
})

#define objcInvoke(a, b) objcInvokeT(a, b, id)
#define objcInvoke_1(a, b, c) ((id (*)(id, SEL, typeof(c)))objc_msgSend)(a, NSSelectorFromString(b), c)
#define objcInvoke_2(a, b, c, d) ((id (*)(id, SEL, typeof(c), typeof(d)))objc_msgSend)(a, NSSelectorFromString(b), c, d)
#define objcInvoke_3(a, b, c, d, e) ((id (*)(id, SEL, typeof(c), typeof(d), typeof(e)))objc_msgSend)(a, NSSelectorFromString(b), c, d, e)

#define objcInvokeIf_1(a, b, c) do { SEL _s = NSSelectorFromString(b); if ([(a) respondsToSelector:_s]) ((void (*)(id, SEL, typeof(c)))objc_msgSend)(a, _s, c); else LogSelectorError(a, _s); } while (0)

// 18.x dropped -client
static inline NSString *CRBundleIDForScene(id scene) {
    if (!scene) return nil;
    if ([scene respondsToSelector:NSSelectorFromString(@"clientProcess")]) {
        NSString *bid = [[scene valueForKey:@"clientProcess"] valueForKey:@"bundleIdentifier"];
        if (bid) return bid;
    }
    id handle = [scene respondsToSelector:NSSelectorFromString(@"clientHandle")] ? [scene valueForKey:@"clientHandle"] : nil;
    return [handle valueForKey:@"bundleIdentifier"];
}

// a real home screen app, not one of the ~150 background services iOS also registers as apps
static inline BOOL CRAppRecordHasHomeScreenIcon(id record)
{
    if (!record)
    {
        return NO;
    }
    for (NSString *getterName in @[@"isLaunchProhibited", @"isLaunchDisabled", @"isPlaceholder", @"isWebApp", @"isWebAppPlaceholder"])
    {
        SEL getter = NSSelectorFromString(getterName);
        if ([record respondsToSelector:getter] && ((BOOL (*)(id, SEL))objc_msgSend)(record, getter))
        {
            return NO;
        }
    }
    if ([record respondsToSelector:NSSelectorFromString(@"appClipMetadata")] && ((id (*)(id, SEL))objc_msgSend)(record, NSSelectorFromString(@"appClipMetadata")))
    {
        return NO;
    }

    NSArray *tags = [record respondsToSelector:NSSelectorFromString(@"appTags")] ? ((id (*)(id, SEL))objc_msgSend)(record, NSSelectorFromString(@"appTags")) : nil;
    NSDictionary *icons = [record respondsToSelector:NSSelectorFromString(@"iconDictionary")] ? ((id (*)(id, SEL))objc_msgSend)(record, NSSelectorFromString(@"iconDictionary")) : nil;
    if ([tags containsObject:@"hidden"] || [icons count] == 0)
    {
        return NO;
    }

    id infoDictionary = [record respondsToSelector:NSSelectorFromString(@"infoDictionary")] ? ((id (*)(id, SEL))objc_msgSend)(record, NSSelectorFromString(@"infoDictionary")) : nil;
    SEL objectForKeyOfClass = NSSelectorFromString(@"objectForKey:ofClass:");
    if ([infoDictionary respondsToSelector:objectForKeyOfClass])
    {
        NSNumber *defaultVisible = ((id (*)(id, SEL, id, Class))objc_msgSend)(infoDictionary, objectForKeyOfClass, @"SBIconVisibilityDefaultVisible", [NSNumber class]);
        if (defaultVisible && ![defaultVisible boolValue])
        {
            return NO;
        }
    }
    return YES;
}

#define assertGotExpectedObject(obj, type) if (!obj || ![obj isKindOfClass:NSClassFromString(type)]) [NSException raise:@"UnexpectedObjectException" format:@"Expected %@ but got %@", type, obj]

#define kPropertyKey_liveCarplayWindow *NSSelectorFromString(@"liveCarplayWindow")
#define kPropertyKey_lockAssertionIdentifiers *NSSelectorFromString(@"lockAssertions")
static char *kPropertyKey_didDrawPlaceholder;

// the prefs pane runs as mobile and cannot write to /var/jb/Library/Preferences
#define PREFERENCES_PLIST_PATH @"/var/mobile/Library/Preferences/com.carplayenable.preferences.plist"
#define PREFERENCES_CHANGED_NOTIFICATION @"com.carplay.preferences.changed"
#define PREFERENCES_APP_DATA_NOTIFICATION @"com.carplay.prefs.app_data"
#define kPrefsAppDataRequesting @"Requesting"
#define kPrefsAppDataReceiving @"Receiving"
#define kPrefsAppLibraryChanged @"appLibrary"
#define kPrefsDockAlignmentChanged @"dockAlignment"
#define kPrefsIconLayoutChanged @"iconLayout"
#define kPrefsNativeLookChanged @"nativeLook"
#define kPrefsHomeScreenScaleChanged @"homeScreenScale"
#define kPrefsDockChanged @"dock"

#define CARPLAY_DOCK_WIDTH 40
#define CARPLAY_SIDEBAR_WIDTH 45

#define kCRSpringBoardBundleID @"com.apple.springboard"
#define kCRDashBoardBundleID @"com.apple.CarPlayApp"
#define kCRSpringBoardModeStateNotification @"com.carplayenable.sbmode.state"
#define kCRSpringBoardModeShowNotification @"com.carplayenable.sbmode.show"
#define kCRSpringBoardModeExitNotification @"com.carplayenable.sbmode.exit"
#define kCRSpringBoardModeOpenNativeNotification @"com.carplayenable.sbmode.opennative"
#define kCRAppSwitcherShowNotification @"com.carplayenable.sbmode.switcher.show"
#define kCRHomePressedNotification @"com.carplayenable.sbmode.home"
#define kCRSpringBoardModeRestoreNotification @"com.carplayenable.sbmode.restore"
#define kCRCarIconRequestNotification @"com.carplayenable.caricon.request"
#define kCRCarIconInfoNotification @"com.carplayenable.caricon.info"
#define kCRCarIconLaunchNotification @"com.carplayenable.caricon.launch"
#define kCRPadLayoutMarkerName @"com.carplayenable.padlayout"
#define kCRPadLayoutLaunchedNotification @"com.carplayenable.padlayout.launched"

// the car keyboard's scale: the app container's width, at most about half its height
static inline CGFloat CRCarplayKeyboardScale(CGSize containerSize, CGSize uprightScreenSize, CGFloat keyboardHeight)
{
    CGFloat scale = containerSize.width / uprightScreenSize.width;
    CGFloat maxHeight = containerSize.height * 0.55;
    if (keyboardHeight * scale > maxHeight)
    {
        scale = maxHeight / keyboardHeight;
    }
    return scale;
}

extern int (*orig_BKSDisplayServicesSetScreenBlanked)(int);