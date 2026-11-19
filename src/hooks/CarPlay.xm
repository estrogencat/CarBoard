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

// Apple apps found to have a home screen icon (filled by the library's identity filter, which may run off the main thread)
static NSMutableSet *appleAppsWithIcons;

static void noteAppleAppIdentity(id identity)
{
    NSString *bundleID = objcInvoke(identity, @"bundleIdentifier");
    if (![bundleID hasPrefix:@"com.apple."])
    {
        return;
    }
    SEL findRecord = NSSelectorFromString(@"findApplicationRecordWithError:");
    id record = [identity respondsToSelector:findRecord] ? ((id (*)(id, SEL, id *))objc_msgSend)(identity, findRecord, NULL) : nil;
    BOOL hasIcon = CRAppRecordHasHomeScreenIcon(record);
    @synchronized (appleAppsWithIcons)
    {
        if (hasIcon)
        {
            [appleAppsWithIcons addObject:bundleID];
        }
        else
        {
            [appleAppsWithIcons removeObject:bundleID];
        }
    }
}

/*
Apps that aren't excluded in preferences get forced onto the dashboard. Apple's own only when they have an icon on the
phone's home screen: iOS registers ~150 background services as apps too. Jailbreak and TrollStore apps report as
"System", so the identifier (and the icon check) decides it, not the app type.
*/
static BOOL shouldForceBundleIdentifier(NSString *bundleID)
{
    if (!bundleID)
    {
        return NO;
    }
    if ([bundleID hasPrefix:@"com.apple."])
    {
        @synchronized (appleAppsWithIcons)
        {
            if (![appleAppsWithIcons containsObject:bundleID])
            {
                return NO;
            }
        }
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

// whether SpringBoard has one of our app windows up (it says when one opens or closes)
static BOOL hostedAppShowing;
// context of the home event we send to close a native app, so it isn't taken for the user's
static NSString *const kOwnHomeEventContext = @"CarPlayEnable: close native app";

/*
Where CarPlay puts its own apps: its main window minus the sidebar (left, right or bottom depending on the car)
*/
static CGRect carplayAppFrame(void)
{
    id dashboard = objcInvoke([UIApplication sharedApplication], @"_currentDashboard");
    id layoutEngine = objcInvoke(dashboard, @"layoutEngine");
    if (![layoutEngine respondsToSelector:NSSelectorFromString(@"mainWindowFrame")] || ![layoutEngine respondsToSelector:NSSelectorFromString(@"statusBarInsets")])
    {
        return CGRectZero;
    }
    CGRect mainWindowFrame = ((CGRect (*)(id, SEL))objc_msgSend)(layoutEngine, NSSelectorFromString(@"mainWindowFrame"));
    UIEdgeInsets statusBarInsets = ((UIEdgeInsets (*)(id, SEL))objc_msgSend)(layoutEngine, NSSelectorFromString(@"statusBarInsets"));
    return UIEdgeInsetsInsetRect(mainWindowFrame, statusBarInsets);
}

/*
Ask SpringBoard to host the app on the CarPlay screen
*/
static void requestCarplayLaunch(NSString *bundleID)
{
    LOG_LIFECYCLE_EVENT;
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:bundleID forKey:@"identifier"];
    CGRect appFrame = carplayAppFrame();
    if (!CGRectIsEmpty(appFrame))
    {
        userInfo[@"appFrame"] = NSStringFromCGRect(appFrame);
    }
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.carplayenable" object:nil userInfo:userInfo];
    recordAppLaunch(bundleID);
}

// what fills CarPlay's app area in a workspace state: its home screen, an app, Siri, an OEM screen...
static id workspaceBaseEntity(id state)
{
    return [state respondsToSelector:NSSelectorFromString(@"baseEntity")] ? objcInvoke(state, @"baseEntity") : nil;
}

static BOOL entityIsHomescreen(id entity)
{
    SEL isHomescreen = NSSelectorFromString(@"isHomescreenEntity");
    return [entity respondsToSelector:isHomescreen] && ((BOOL (*)(id, SEL))objc_msgSend)(entity, isHomescreen);
}

// CarPlay can run more than one dashboard (e.g. an instrument cluster); only the main screen's drives our window
static BOOL isMainDashboard(id dashboard)
{
    id mainDashboard = objcInvoke([UIApplication sharedApplication], @"_currentDashboard");
    return !mainDashboard || mainDashboard == dashboard;
}

static void requestCarplayClose(NSString *reason)
{
    CRLog(@"closing the hosted app: %@", reason);
    hostedAppShowing = NO;
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.carplayenable.close" object:nil userInfo:nil];
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
            noteAppleAppIdentity(identity);
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
    // close a native CarPlay app that fills the screen, so ours sits over CarPlay's home screen. Not when CarPlay is
    // already home: its dashboard widgets count as foreground scenes, and home there flips dashboard and app grid
    id baseEntity = workspaceBaseEntity(objcInvoke(objcInvoke(self, @"workspace"), @"state"));
    if (baseEntity && !entityIsHomescreen(baseEntity))
    {
        id homeButtonEvent = objcInvoke_2(objc_getClass("DBEvent"), @"eventWithType:context:", (unsigned long long)1, kOwnHomeEventContext);
        if (homeButtonEvent)
        {
            objcInvoke_1(self, @"handleEvent:", homeButtonEvent);
        }
    }

    requestCarplayLaunch(objcInvoke(application, @"bundleIdentifier"));
}

/*
CarPlay's home button (the sidebar's, or the car's own). While one of our apps is up it closes that app and leaves
CarPlay on whichever home page it was showing, like it does for its own apps.
*/
- (void)_handleHomeEvent:(id)event
{
    id context = [event respondsToSelector:NSSelectorFromString(@"context")] ? objcInvoke(event, @"context") : nil;
    if (hostedAppShowing && ![context isEqual:kOwnHomeEventContext] && isMainDashboard(self))
    {
        requestCarplayClose(@"home button");
        return;
    }
    %orig;
}

/*
Every switch of what fills CarPlay's app area: another app (sidebar, home screen, dashboard widget, call, alert, Siri
opening something) closes ours. Going home doesn't need to, ours already sits over the home screen.
*/
- (void)workspace:(id)workspace stateDidChangeFromState:(id)fromState toState:(id)toState
{
    %orig;
    if (!hostedAppShowing || !isMainDashboard(self))
    {
        return;
    }

    id fromEntity = workspaceBaseEntity(fromState);
    id toEntity = workspaceBaseEntity(toState);
    if (toEntity && ![toEntity isEqual:fromEntity] && !entityIsHomescreen(toEntity))
    {
        requestCarplayClose([NSString stringWithFormat:@"CarPlay switched to %@", toEntity]);
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

    appleAppsWithIcons = [[NSMutableSet alloc] init];
    %init(CARPLAY);

    // SpringBoard says when it opens or closes one of our app windows, whatever asked for it
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserverForName:@"com.carplayenable.opened" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        hostedAppShowing = YES;
    }];
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserverForName:@"com.carplayenable.closed" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        hostedAppShowing = NO;
    }];
    // a window left over from before this process started (CarPlay restarted) would never be closed by its home button
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.carplayenable.close" object:nil userInfo:nil];

    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserverForName:PREFERENCES_CHANGED_NOTIFICATION object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        [[CRPreferences sharedInstance] reloadPreferences];
        if ([note.object isEqualToString:kPrefsAppLibraryChanged] || [note.object isEqualToString:kPrefsIconLayoutChanged])
        {
            scheduleCarplayRestart();
        }
    }];
}
