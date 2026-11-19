#include "../common.h"

/*
Injected into the CarPlay process (com.apple.CarPlayApp, code in DashBoard.framework)
*/
%group CARPLAY

struct SBIconImageInfo {
    struct CGSize size;
    double scale;
    double continuousCornerRadius;
};

static NSString *const kForcedAppTag = @"CarPlayEnable";

/*
Non-Apple apps that aren't excluded in preferences get forced onto the dashboard.
Stock apps are skipped because they are always glitchy. Jailbreak apps live in /Applications
and report as "System", so the identifier is what decides it.
*/
static BOOL shouldForceBundleIdentifier(NSString *bundleID)
{
    if (!bundleID || [bundleID hasPrefix:@"com.apple."])
    {
        return NO;
    }

    NSArray *userExcludedApps = [[CRPreferences sharedInstance] excludedApplications];
    return ![userExcludedApps containsObject:bundleID];
}

static BOOL isForcedAppInfo(id appInfo)
{
    return [objcInvoke(appInfo, @"tags") containsObject:kForcedAppTag];
}

/*
Give an app a fake CarPlay declaration so DashBoard treats it like a non-template (Maps-style) app.
If the app already supports CarPlay it's left alone.
*/
static void addCarplayDeclarationToAppInfo(id appInfo)
{
    if (!appInfo || getIvar(appInfo, @"_carPlayDeclaration") != nil)
    {
        return;
    }

    NSString *appBundleID = objcInvoke(appInfo, @"bundleIdentifier");
    NSArray *existingTags = objcInvoke(appInfo, @"tags");
    if (!shouldForceBundleIdentifier(appBundleID) || [existingTags containsObject:@"hidden"])
    {
        return;
    }

    id carplayDeclaration = [[[objc_getClass("CRCarPlayAppDeclaration") alloc] init] autorelease];
    // not template-driven: otherwise the template host keeps spinning up looking for a template that doesn't exist
    objcInvoke_1(carplayDeclaration, @"setSupportsTemplates:", NO);
    objcInvoke_1(carplayDeclaration, @"setSupportsMaps:", YES);
    objcInvoke_1(carplayDeclaration, @"setBundleIdentifier:", appBundleID);
    objcInvoke_1(carplayDeclaration, @"setBundlePath:", [objcInvoke(appInfo, @"bundleURL") path]);
    setIvar(appInfo, @"_carPlayDeclaration", carplayDeclaration);

    // tag it so launches can tell it was forced
    NSArray *newTags = @[kForcedAppTag];
    if (existingTags)
    {
        newTags = [newTags arrayByAddingObjectsFromArray:existingTags];
    }
    setIvar(appInfo, @"_tags", newTags);
}

static id currentDockController(void)
{
    id dashboard = objcInvoke([UIApplication sharedApplication], @"_currentDashboard");
    return objcInvoke(objcInvoke(dashboard, @"rootViewController"), @"appDockViewController");
}

/*
Put the app in the dock's recents, the same way a real launch would
*/
static void recordAppLaunch(NSString *bundleID)
{
    id appHistory = objcInvoke([UIApplication sharedApplication], @"_currentAppHistory");
    NSString *previousBundleID = nil;
    NSArray *orderedAppHistory = objcInvoke(appHistory, @"orderedAppHistory");
    if ([orderedAppHistory count] > 0)
    {
        previousBundleID = objcInvoke([orderedAppHistory firstObject], @"bundleIdentifier");
    }

    if (appHistory)
    {
        ((void (*)(id, SEL, id, id))objc_msgSend)(appHistory, NSSelectorFromString(@"_bundleIdentifierDidBecomeVisible:previousBundleIdentifier:"), bundleID, previousBundleID);
    }

    id dockController = currentDockController();
    objcInvoke(dockController, @"_refreshAppDock");
    // DashBoard disables the dock while it waits for a scene that never comes for forced apps
    if (dockController)
    {
        objcInvoke_1(dockController, @"setDockEnabled:", YES);
    }
}

/*
Ask SpringBoard to host the app on the CarPlay screen
*/
static void requestCarplayLaunch(NSString *bundleID)
{
    LOG_LIFECYCLE_EVENT;
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.carplayenable" object:nil userInfo:@{@"identifier": bundleID}];
    recordAppLaunch(bundleID);
}

%hook FBSApplicationLibrary

/*
DashBoard's library only loads CarPlay-capable apps, picked by applicationIdentityFilter.
Widen that filter so forced apps get loaded too.
*/
- (id)initWithConfiguration:(id)configuration
{
    Class infoClass = ((Class (*)(id, SEL))objc_msgSend)(configuration, NSSelectorFromString(@"applicationInfoClass"));
    if (infoClass == objc_getClass("DBApplicationInfo") && [configuration respondsToSelector:NSSelectorFromString(@"setApplicationIdentityFilter:")])
    {
        LOG_LIFECYCLE_EVENT;
        BOOL (^origFilter)(id) = [[objcInvoke(configuration, @"applicationIdentityFilter") retain] autorelease];
        BOOL (^widenedFilter)(id) = ^BOOL(id identity) {
            if (!origFilter || origFilter(identity))
            {
                return YES;
            }
            return shouldForceBundleIdentifier(objcInvoke(identity, @"bundleIdentifier"));
        };
        objcInvoke_1(configuration, @"setApplicationIdentityFilter:", widenedFilter);
    }

    return %orig;
}

%end

%hook DBApplicationController

/*
Called for every app DashBoard loads, at startup and on install/update. The DBApplication made from
this info computes its CarPlay policy from the declaration, so it has to be added first.
*/
- (void)_loadApplicationWithInfo:(id)appInfo
{
    addCarplayDeclarationToAppInfo(appInfo);
    %orig;
}

%end

%hook DBDashboard

/*
Every launch path (home icons, dock, Siri, URLs) ends up here with a DBApplicationLaunchInfo as the event context.
Forced apps are handed to SpringBoard instead of DashBoard's workspace.
*/
- (void)_handleOpenApplicationEvent:(id)event
{
    id launchInfo = objcInvoke(event, @"context");
    id application = [launchInfo respondsToSelector:NSSelectorFromString(@"application")] ? objcInvoke(launchInfo, @"application") : nil;
    id appInfo = application ? objcInvoke(application, @"info") : nil;
    if (!appInfo || !isForcedAppInfo(appInfo))
    {
        %orig;
        return;
    }

    LOG_LIFECYCLE_EVENT;
    requestCarplayLaunch(objcInvoke(application, @"bundleIdentifier"));

    // close any native CarPlay app that's in front
    NSDictionary *foregroundScenes = objcInvoke(self, @"identifierToForegroundAppScenesMap");
    if ([[foregroundScenes allKeys] count] > 0)
    {
        id homeButtonEvent = objcInvoke_2(objc_getClass("DBEvent"), @"eventWithType:context:", (unsigned long long)1, @"Close carplay app");
        if (homeButtonEvent)
        {
            objcInvoke_1(self, @"handleEvent:", homeButtonEvent);
        }
    }
}

%end

/*
Carplay dashboard icon appearance
*/
%hook SBIconListGridLayoutConfiguration

/*
Make the CarPlay dashboard show 5 columns of apps instead of 4
*/
- (NSUInteger)numberOfPortraitColumns
{
    NSUInteger columns = %orig;
    if ([[CRPreferences sharedInstance] fiveColumnIconLayout])
    {
        columns = MAX(5, columns);
    }
    return columns;
}

/*
Make the Carplay dashboard icons a little smaller so 5 fit comfortably
*/
- (struct SBIconImageInfo)iconImageInfoForGridSizeClass:(id)gridSizeClass
{
    struct SBIconImageInfo info = %orig;
    if ([[CRPreferences sharedInstance] fiveColumnIconLayout])
    {
        info.size = CGSizeMake(50, 50);
    }
    return info;
}

%end

/*
App icons on the Carplay dashboard.
For apps that natively support Carplay, a long press launches them in "full mode". Tapping them
still opens their normal Carplay UI
*/
%hook DBIconView

%new
- (void)handleLaunchAppInNormalMode:(UILongPressGestureRecognizer *)gesture
{
    if ([gesture state] != UIGestureRecognizerStateBegan)
    {
        return;
    }

    id icon = objcInvoke(self, @"icon");
    NSString *bundleID = [icon respondsToSelector:NSSelectorFromString(@"applicationBundleID")] ? objcInvoke(icon, @"applicationBundleID") : nil;
    if (bundleID)
    {
        requestCarplayLaunch(bundleID);
    }
}

- (id)initWithConfigurationOptions:(unsigned long long)options listLayoutProvider:(id)layoutProvider
{
    id iconView = %orig;

    UILongPressGestureRecognizer *launchGesture = [[[UILongPressGestureRecognizer alloc] initWithTarget:iconView action:NSSelectorFromString(@"handleLaunchAppInNormalMode:")] autorelease];
    [launchGesture setMinimumPressDuration:1.5];
    [iconView addGestureRecognizer:launchGesture];

    return iconView;
}

%end

%end

/*
The app list and icon layout are built once per process. Restart CarPlay (launchd brings it back)
a moment after the last preference change so toggling several apps only restarts it once.
*/
static void scheduleCarplayRestart(void)
{
    static NSTimer *restartTimer;
    [restartTimer invalidate];
    [restartTimer release];
    restartTimer = [[NSTimer scheduledTimerWithTimeInterval:2.0 repeats:NO block:^(NSTimer *timer) {
        NSLog(@"[carplayenable] restarting CarPlay to apply preference changes");
        exit(0);
    }] retain];
}

%ctor {
    BAIL_IF_UNSUPPORTED_IOS;

    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.CarPlayApp"]) {
        return;
    }

    %init(CARPLAY);

    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserverForName:PREFERENCES_CHANGED_NOTIFICATION object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        [[CRPreferences sharedInstance] reloadPreferences];
        if ([note.object isEqualToString:kPrefsAppLibraryChanged] || [note.object isEqualToString:kPrefsIconLayoutChanged])
        {
            scheduleCarplayRestart();
        }
    }];
}
