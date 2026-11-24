#include "../common.h"

%group CARPLAY

struct SBIconImageInfo {
    struct CGSize size;
    double scale;
    double continuousCornerRadius;
};

static NSString *const kForcedAppTag = @"CarPlayEnable";

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

// Apple's apps only with a phone home screen icon (iOS registers ~150 services as apps); jailbreak apps report as "System", so the identifier decides
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

// a fake CarPlay declaration so DashBoard treats the app like a non-template (Maps-style) one
static void addCarplayDeclarationToAppInfo(id appInfo)
{
    if (!appInfo || getIvar(appInfo, @"_carPlayDeclaration") != nil)
    {
        return;
    }

    NSString *appBundleID = objcInvoke(appInfo, @"bundleIdentifier");
    NSArray *existingTags = objcInvoke(appInfo, @"tags");
    // SpringBoard is hidden and iconless, but its icon opens SpringBoard mode
    if ([appBundleID isEqualToString:kCRSpringBoardBundleID])
    {
        existingTags = nil;
    }
    else if (!shouldForceBundleIdentifier(appBundleID) || [existingTags containsObject:@"hidden"])
    {
        return;
    }

    id carplayDeclaration = [[[objc_getClass("CRCarPlayAppDeclaration") alloc] init] autorelease];
    // otherwise the template host keeps looking for a template that doesn't exist
    objcInvoke_1(carplayDeclaration, @"setSupportsTemplates:", NO);
    objcInvoke_1(carplayDeclaration, @"setSupportsMaps:", YES);
    objcInvoke_1(carplayDeclaration, @"setBundleIdentifier:", appBundleID);
    objcInvoke_1(carplayDeclaration, @"setBundlePath:", [objcInvoke(appInfo, @"bundleURL") path]);
    setIvar(appInfo, @"_carPlayDeclaration", carplayDeclaration);

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
    // DashBoard disables the dock while waiting for a scene that never comes
    if (dockController)
    {
        objcInvoke_1(dockController, @"setDockEnabled:", YES);
    }
}

static BOOL hostedAppShowing;
static BOOL springBoardModeActive;
// so our own home event isn't taken for the user's
static NSString *const kOwnHomeEventContext = @"CarPlayEnable: close native app";

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

static id workspaceBaseEntity(id state)
{
    return [state respondsToSelector:NSSelectorFromString(@"baseEntity")] ? objcInvoke(state, @"baseEntity") : nil;
}

static BOOL entityIsHomescreen(id entity)
{
    SEL isHomescreen = NSSelectorFromString(@"isHomescreenEntity");
    return [entity respondsToSelector:isHomescreen] && ((BOOL (*)(id, SEL))objc_msgSend)(entity, isHomescreen);
}

// CarPlay can run more than one dashboard (e.g. an instrument cluster)
static BOOL isMainDashboard(id dashboard)
{
    id mainDashboard = objcInvoke([UIApplication sharedApplication], @"_currentDashboard");
    return !mainDashboard || mainDashboard == dashboard;
}

static NSString *const kTrimRequester = @"CarPlayEnable";

// put CarPlay's own home screen to sleep while SpringBoard's covers it
static void updateDashboardTrim(id dashboard)
{
    static BOOL trimmed;
    static NSMutableArray *hiddenWindows;
    static UIWindow *sceneHostWindow;
    static UIColor *sceneHostBackground;

    id state = objcInvoke(objcInvoke(dashboard, @"workspace"), @"state");
    id baseEntity = workspaceBaseEntity(state);
    BOOL home = !baseEntity || entityIsHomescreen(baseEntity);
    BOOL trim = springBoardModeActive && home;

    UIViewController *rootViewController = objcInvoke(dashboard, @"rootViewController");
    UIViewController *homeViewController = nil;
    NSMutableArray *pending = rootViewController ? [NSMutableArray arrayWithObject:rootViewController] : [NSMutableArray array];
    while (pending.count && !homeViewController)
    {
        UIViewController *viewController = pending.firstObject;
        [pending removeObjectAtIndex:0];
        if ([viewController isKindOfClass:objc_getClass("DBDashboardHomeViewController")])
        {
            homeViewController = viewController;
        }
        [pending addObjectsFromArray:viewController.childViewControllers];
    }

    if (trim != trimmed)
    {
        trimmed = trim;
        id todayViewController = objcInvoke(homeViewController, @"todayViewController");
        if ([todayViewController respondsToSelector:NSSelectorFromString(@"setSceneWidgetsDisabled:forRequester:")])
        {
            objcInvoke_2(todayViewController, @"setSceneWidgetsDisabled:forRequester:", trim, kTrimRequester);
        }
        if (trim)
        {
            hiddenWindows = hiddenWindows ?: [[NSMutableArray alloc] init];
            SEL allWindows = NSSelectorFromString(@"allWindowsIncludingInternalWindows:onlyVisibleWindows:");
            NSArray *windows = [UIWindow respondsToSelector:allWindows] ? ((NSArray *(*)(id, SEL, BOOL, BOOL))objc_msgSend)([UIWindow class], allWindows, YES, NO) : [UIApplication sharedApplication].windows;
            for (UIWindow *window in windows)
            {
                NSString *name = NSStringFromClass([window class]);
                if (!window.hidden && ([name hasSuffix:@"DBWallpaperWindow"] || [name hasSuffix:@"DBWallpaperHostWindow"] || ([name isEqualToString:@"UIWindow"] && window.windowLevel < -1)))
                {
                    window.hidden = YES;
                    [hiddenWindows addObject:window];
                }
                // its black fill would cover SpringBoard's wallpaper under the sidebar
                else if ([name isEqualToString:@"UIRootSceneWindow"] && !sceneHostWindow)
                {
                    sceneHostWindow = [window retain];
                    sceneHostBackground = [window.backgroundColor retain];
                    window.backgroundColor = [UIColor clearColor];
                }
            }
        }
        else
        {
            for (UIWindow *window in hiddenWindows)
            {
                window.hidden = NO;
            }
            [hiddenWindows removeAllObjects];
            sceneHostWindow.backgroundColor = sceneHostBackground;
            [sceneHostWindow release];
            sceneHostWindow = nil;
            [sceneHostBackground release];
            sceneHostBackground = nil;
        }
    }
    static UIView *hiddenHomeView;
    UIView *homeView = trim ? homeViewController.viewIfLoaded : nil;
    if (homeView != hiddenHomeView)
    {
        hiddenHomeView.hidden = NO;
        homeView.hidden = YES;
        [hiddenHomeView release];
        hiddenHomeView = [homeView retain];
    }

    CRLog(@"dashboard trim %d", trim);
}

static void requestCarplayClose(NSString *reason)
{
    CRLog(@"closing the hosted app: %@", reason);
    hostedAppShowing = NO;
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.carplayenable.close" object:nil userInfo:nil];
}

%hook FBSApplicationLibrary

// widen DashBoard's CarPlay-only app filter so forced apps load
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

%hook DBApplicationInfo

- (BOOL)isHidden
{
    return [objcInvoke(self, @"bundleIdentifier") isEqualToString:kCRSpringBoardBundleID] ? NO : %orig;
}

%end

static id currentDBIconModel;

%hook DBIconModel

- (BOOL)isIconVisible:(id)icon
{
    currentDBIconModel = self;
    NSString *bundleID = [icon respondsToSelector:NSSelectorFromString(@"applicationBundleID")] ? objcInvoke(icon, @"applicationBundleID") : nil;
    return [bundleID isEqualToString:kCRSpringBoardBundleID] || %orig;
}

%end

%hook DBApplicationController

// the declaration has to be there before DashBoard builds the app's CarPlay policy
- (void)_loadApplicationWithInfo:(id)appInfo
{
    addCarplayDeclarationToAppInfo(appInfo);
    %orig;
}

%end

%hook DBDashboard

// every launch path ends here; forced apps go to SpringBoard instead
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
    // close a full screen native CarPlay app first. Not when already home: widgets count as foreground there and home flips the pages
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

- (void)_handleHomeEvent:(id)event
{
    id context = [event respondsToSelector:NSSelectorFromString(@"context")] ? objcInvoke(event, @"context") : nil;
    // in SpringBoard mode a quick second press opens the car app switcher, so the first one waits for it
    static CFTimeInterval lastHomePress;
    static NSUInteger homePressGeneration;
    static BOOL replayingHomePress;
    if (springBoardModeActive && !replayingHomePress && ![context isEqual:kOwnHomeEventContext] && isMainDashboard(self))
    {
        id center = [objc_getClass("NSDistributedNotificationCenter") defaultCenter];
        CFTimeInterval now = CACurrentMediaTime();
        NSUInteger generation = ++homePressGeneration;
        if (now - lastHomePress < 0.4)
        {
            lastHomePress = 0;
            [center postNotificationName:kCRAppSwitcherShowNotification object:nil userInfo:nil];
            return;
        }
        lastHomePress = now;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (generation != homePressGeneration)
            {
                return;
            }
            [center postNotificationName:kCRHomePressedNotification object:nil userInfo:@{@"appShowing": @(hostedAppShowing)}];
            replayingHomePress = YES;
            objcInvoke_1(self, @"_handleHomeEvent:", event);
            replayingHomePress = NO;
        });
        return;
    }
    if (hostedAppShowing && ![context isEqual:kOwnHomeEventContext] && isMainDashboard(self))
    {
        requestCarplayClose(@"home button");
        return;
    }
    %orig;
}

// anything else taking CarPlay's app area closes ours (going home doesn't need to)
- (void)workspace:(id)workspace stateDidChangeFromState:(id)fromState toState:(id)toState
{
    %orig;
    if (!isMainDashboard(self))
    {
        return;
    }

    updateDashboardTrim(self);
    id fromEntity = workspaceBaseEntity(fromState);
    id toEntity = workspaceBaseEntity(toState);
    if (springBoardModeActive && toEntity && ![toEntity isEqual:fromEntity])
    {
        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:kCRSpringBoardModeShowNotification object:nil userInfo:@{@"showing": @(entityIsHomescreen(toEntity))}];
    }

    if (!hostedAppShowing)
    {
        return;
    }
    if (toEntity && ![toEntity isEqual:fromEntity] && !entityIsHomescreen(toEntity))
    {
        requestCarplayClose([NSString stringWithFormat:@"CarPlay switched to %@", toEntity]);
    }
}

%end

%hook SBIconListGridLayoutConfiguration

- (NSUInteger)numberOfPortraitColumns
{
    NSUInteger columns = %orig;
    if ([[CRPreferences sharedInstance] fiveColumnIconLayout])
    {
        columns = MAX(5, columns);
    }
    return columns;
}

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

// the car's knob and arrow keys can't move onto CarPlay's hidden home screen
%hook DBDashboardHomeViewController

- (BOOL)shouldUpdateFocusInContext:(UIFocusUpdateContext *)context
{
    UIView *next = [context.nextFocusedItem isKindOfClass:[UIView class]] ? (UIView *)context.nextFocusedItem : nil;
    if (springBoardModeActive && next && [next isDescendantOfView:((UIViewController *)self).view])
    {
        return NO;
    }
    return %orig;
}

- (NSArray *)preferredFocusEnvironments
{
    return springBoardModeActive ? @[] : %orig;
}

%end

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


static UIImage *CRSpringBoardIconImage(CGSize size, CGFloat scale, CGFloat cornerRadius)
{
    if (size.width <= 0 || size.height <= 0)
    {
        return nil;
    }
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = scale > 0 ? scale : [UIScreen mainScreen].scale;
    UIGraphicsImageRenderer *renderer = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] autorelease];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
        CGContextRef context = rendererContext.CGContext;
        CGRect bounds = CGRectMake(0, 0, size.width, size.height);
        if (cornerRadius > 0)
        {
            [[UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:cornerRadius] addClip];
        }
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGFloat components[] = {0.20, 0.32, 0.95, 1.0, 0.55, 0.20, 0.85, 1.0};
        CGGradientRef gradient = CGGradientCreateWithColorComponents(colorSpace, components, NULL, 2);
        CGContextDrawLinearGradient(context, gradient, CGPointZero, CGPointMake(size.width, size.height), 0);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(colorSpace);

        NSArray<UIColor *> *colors = @[
            [UIColor colorWithRed:1.00 green:0.80 blue:0.25 alpha:1], [UIColor colorWithRed:0.30 green:0.85 blue:0.45 alpha:1], [UIColor whiteColor],
            [UIColor whiteColor], [UIColor colorWithRed:1.00 green:0.40 blue:0.40 alpha:1], [UIColor colorWithRed:0.40 green:0.80 blue:1.00 alpha:1],
            [UIColor colorWithRed:1.00 green:0.60 blue:0.20 alpha:1], [UIColor whiteColor], [UIColor colorWithRed:0.95 green:0.45 blue:0.80 alpha:1],
        ];
        CGFloat inset = size.width * 0.2;
        CGFloat gap = size.width * 0.07;
        CGFloat cell = (size.width - 2 * inset - 2 * gap) / 3;
        for (NSUInteger index = 0; index < 9; index++)
        {
            CGRect tile = CGRectMake(inset + (index % 3) * (cell + gap), inset + (index / 3) * (cell + gap), cell, cell);
            [colors[index] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:tile cornerRadius:cell * 0.28] fill];
        }
    }];
}

static BOOL CRIsSpringBoardIcon(id icon)
{
    return [icon respondsToSelector:NSSelectorFromString(@"applicationBundleID")] && [objcInvoke(icon, @"applicationBundleID") isEqualToString:kCRSpringBoardBundleID];
}

%hook SBLeafIcon

- (id)iconImageWithInfo:(struct SBIconImageInfo)info traitCollection:(id)traitCollection options:(unsigned long long)options
{
    return CRIsSpringBoardIcon(self) ? CRSpringBoardIconImage(info.size, info.scale, info.continuousCornerRadius) : %orig;
}

- (id)makeIconImageWithInfo:(struct SBIconImageInfo)info traitCollection:(id)traitCollection options:(unsigned long long)options
{
    return CRIsSpringBoardIcon(self) ? CRSpringBoardIconImage(info.size, info.scale, info.continuousCornerRadius) : %orig;
}

- (id)iconImageWithInfo:(struct SBIconImageInfo)info
{
    return CRIsSpringBoardIcon(self) ? CRSpringBoardIconImage(info.size, info.scale, info.continuousCornerRadius) : %orig;
}

- (id)generateIconImageWithInfo:(struct SBIconImageInfo)info
{
    return CRIsSpringBoardIcon(self) ? CRSpringBoardIconImage(info.size, info.scale, info.continuousCornerRadius) : %orig;
}

- (id)unmaskedIconImageWithInfo:(struct SBIconImageInfo)info
{
    return CRIsSpringBoardIcon(self) ? CRSpringBoardIconImage(info.size, info.scale, 0) : %orig;
}

- (BOOL)canMakeIconLayerQuicklyWithInfo:(struct SBIconImageInfo)info traitCollection:(id)traitCollection options:(unsigned long long)options
{
    return CRIsSpringBoardIcon(self) ? NO : %orig;
}

- (id)makeIconLayerWithInfo:(struct SBIconImageInfo)info traitCollection:(id)traitCollection options:(unsigned long long)options
{
    if (!CRIsSpringBoardIcon(self))
    {
        return %orig;
    }
    CALayer *layer = [CALayer layer];
    layer.frame = CGRectMake(0, 0, info.size.width, info.size.height);
    layer.contents = (id)CRSpringBoardIconImage(info.size, info.scale, info.continuousCornerRadius).CGImage;
    layer.contentsScale = info.scale;
    return layer;
}

%end

// the sidebar's dock: two more recent apps, and optionally SpringBoard pinned at the bottom
static char kExtraDockButtonsKey;

// the container is sized for three buttons and has to take the extra ones' touches
%subclass CRDockContainerView : UIView

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event
{
    if (%orig)
    {
        return YES;
    }
    for (UIView *subview in ((UIView *)self).subviews)
    {
        if (!subview.hidden && [subview pointInside:[(UIView *)self convertPoint:point toView:subview] withEvent:event])
        {
            return YES;
        }
    }
    return NO;
}

%end
static const NSUInteger kExtraDockButtonCount = 2;

static NSString *CRDockButtonBundleID(id button)
{
    return [button respondsToSelector:NSSelectorFromString(@"bundleIdentifier")] ? objcInvoke(button, @"bundleIdentifier") : nil;
}

static void CRSetDockButtonBundleID(id button, NSString *bundleID)
{
    ((void (*)(id, SEL, id, BOOL))objc_msgSend)(button, NSSelectorFromString(@"setBundleIdentifier:animated:"), bundleID, NO);
    ((UIView *)button).hidden = bundleID.length == 0;
}

static void CRUpdateDockActiveStates(id controller)
{
    NSString *active = objcInvoke(controller, @"activeBundleIdentifier");
    for (id button in objc_getAssociatedObject(controller, &kExtraDockButtonsKey))
    {
        NSString *bundleID = CRDockButtonBundleID(button);
        ((void (*)(id, SEL, BOOL))objc_msgSend)(button, NSSelectorFromString(@"setActive:"), bundleID && [bundleID isEqualToString:active]);
    }
}

static char kDockLongPressKey;

static void CRAddDockLongPress(id controller, UIView *button)
{
    if (!button || objc_getAssociatedObject(button, &kDockLongPressKey))
    {
        return;
    }
    UILongPressGestureRecognizer *hold = [[[UILongPressGestureRecognizer alloc] initWithTarget:controller action:NSSelectorFromString(@"cr_dockButtonHeld:")] autorelease];
    hold.minimumPressDuration = 0.5;
    [button addGestureRecognizer:hold];
    objc_setAssociatedObject(button, &kDockLongPressKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void CRUpdateExtraDockButtons(id controller)
{
    @try
    {
        CRPreferences *preferences = [CRPreferences sharedInstance];
        BOOL fiveIcons = [preferences fiveDockIcons];
        BOOL pinSpringBoard = [preferences pinSpringBoardInDock];
        UIStackView *stack = objcInvoke(controller, @"dockItemStackView");
        id otherButton = objcInvoke(controller, @"otherAppButton");
        if (![stack isKindOfClass:[UIStackView class]] || !otherButton)
        {
            return;
        }

        NSMutableArray *extraButtons = objc_getAssociatedObject(controller, &kExtraDockButtonsKey);
        if (!extraButtons && fiveIcons)
        {
            extraButtons = [NSMutableArray array];
            NSUInteger insertIndex = [stack.arrangedSubviews indexOfObject:otherButton];
            for (NSUInteger index = 0; index < kExtraDockButtonCount; index++)
            {
                id button = [objcInvoke_1([objc_getClass("DBAppDockButton") alloc], @"initWithIconProvider:", objcInvoke(controller, @"iconProvider")) autorelease];
                [button addTarget:controller action:NSSelectorFromString(@"_dockButtonPressed:") forControlEvents:UIControlEventPrimaryActionTriggered];
                ((UIView *)button).translatesAutoresizingMaskIntoConstraints = NO;
                if (insertIndex != NSNotFound)
                {
                    [stack insertArrangedSubview:button atIndex:insertIndex + 1 + index];
                }
                else
                {
                    [stack addArrangedSubview:button];
                }
                NSArray *constraints = objcInvoke_1(controller, @"_buttonSizeConstraintsForButton:", button);
                if ([constraints isKindOfClass:[NSArray class]])
                {
                    [NSLayoutConstraint activateConstraints:constraints];
                }
                [extraButtons addObject:button];
            }
            objc_setAssociatedObject(controller, &kExtraDockButtonsKey, extraButtons, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            UIView *container = stack.superview;
            Class containerClass = objc_getClass("CRDockContainerView");
            if (container && containerClass && [container class] == [UIView class])
            {
                object_setClass(container, containerClass);
            }
        }
        for (id button in extraButtons)
        {
            ((UIView *)button).hidden = !fiveIcons;
        }

        NSMutableSet *shown = [NSMutableSet set];
        for (NSString *name in @[@"navigationAppButton", @"audioAppButton"])
        {
            id button = objcInvoke(controller, name);
            NSString *bundleID = CRDockButtonBundleID(button);
            if (bundleID && !((UIView *)button).hidden)
            {
                [shown addObject:bundleID];
            }
        }
        id appHistory = objcInvoke(controller, @"appHistory");
        SEL validForDock = NSSelectorFromString(@"isBundleIdentifierValidForDock:");
        NSMutableArray *candidates = [NSMutableArray array];
        for (id entry in objcInvoke(appHistory, @"orderedAppHistory"))
        {
            NSString *bundleID = [entry respondsToSelector:NSSelectorFromString(@"bundleIdentifier")] ? objcInvoke(entry, @"bundleIdentifier") : ([entry isKindOfClass:[NSString class]] ? entry : nil);
            BOOL isSpringBoard = [bundleID isEqualToString:kCRSpringBoardBundleID];
            if (!bundleID || [shown containsObject:bundleID] || [candidates containsObject:bundleID] || (pinSpringBoard && isSpringBoard))
            {
                continue;
            }
            if (!isSpringBoard && [appHistory respondsToSelector:validForDock] && !((BOOL (*)(id, SEL, id))objc_msgSend)(appHistory, validForDock, bundleID))
            {
                continue;
            }
            [candidates addObject:bundleID];
        }

        for (NSString *name in @[@"navigationAppButton", @"audioAppButton", @"otherAppButton"])
        {
            CRAddDockLongPress(controller, objcInvoke(controller, name));
        }
        for (id button in extraButtons)
        {
            CRAddDockLongPress(controller, button);
        }

        NSMutableArray *slots = [NSMutableArray arrayWithObject:otherButton];
        if (fiveIcons)
        {
            [slots addObjectsFromArray:extraButtons];
        }
        for (NSUInteger index = 0; index < slots.count; index++)
        {
            NSString *bundleID = nil;
            if (pinSpringBoard && index == slots.count - 1)
            {
                bundleID = kCRSpringBoardBundleID;
            }
            else if (candidates.count)
            {
                bundleID = candidates.firstObject;
                [candidates removeObjectAtIndex:0];
            }
            CRSetDockButtonBundleID(slots[index], bundleID);
        }
        CRUpdateDockActiveStates(controller);
    }
    @catch (NSException *exception)
    {
        CRLog(@"dock: extra buttons failed: %@", exception);
    }
}

static void CRSendCarIconInfo(void)
{
    @try
    {
        id model = currentDBIconModel;
        id leafIcons = [model respondsToSelector:NSSelectorFromString(@"leafIcons")] ? objcInvoke(model, @"leafIcons") : nil;
        id carIcon = nil;
        for (id icon in leafIcons)
        {
            if ([icon isKindOfClass:objc_getClass("DBOEMIcon")])
            {
                carIcon = icon;
                break;
            }
        }
        if (!carIcon)
        {
            CRLog(@"caricon: no car icon (model %@)", model);
            return;
        }
        NSString *name = [model respondsToSelector:NSSelectorFromString(@"OEMIconLabel")] ? objcInvoke(model, @"OEMIconLabel") : nil;
        if (!name.length)
        {
            name = objcInvoke(carIcon, @"displayName");
        }
        struct SBIconImageInfo info = {CGSizeMake(60, 60), [UIScreen mainScreen].scale, 13.5};
        UIImage *image = ((id (*)(id, SEL, struct SBIconImageInfo))objc_msgSend)(carIcon, NSSelectorFromString(@"unmaskedIconImageWithInfo:"), info);
        if (!image)
        {
            image = ((id (*)(id, SEL, struct SBIconImageInfo))objc_msgSend)(carIcon, NSSelectorFromString(@"generateIconImageWithInfo:"), info);
        }
        NSData *imageData = [image isKindOfClass:[UIImage class]] ? UIImagePNGRepresentation(image) : nil;
        CRLog(@"caricon: %@ image %@", name, image ? NSStringFromCGSize(image.size) : @"none");
        if (name.length && imageData.length)
        {
            [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:kCRCarIconInfoNotification object:nil userInfo:@{@"name": name, @"image": imageData}];
        }
    }
    @catch (NSException *exception)
    {
        CRLog(@"caricon: failed: %@", exception);
    }
}

%hook DBAppDockViewController

%new
- (void)cr_dockButtonHeld:(UILongPressGestureRecognizer *)hold
{
    if (hold.state != UIGestureRecognizerStateBegan)
    {
        return;
    }
    NSString *bundleID = CRDockButtonBundleID(hold.view);
    CRLog(@"dock: held %@", bundleID);
    if (bundleID.length && ![bundleID isEqualToString:kCRSpringBoardBundleID])
    {
        // the press under the hold would open the CarPlay app as well
        if ([hold.view isKindOfClass:[UIControl class]])
        {
            [(UIControl *)hold.view cancelTrackingWithEvent:nil];
        }
        requestCarplayLaunch(bundleID);
    }
}

- (void)_refreshAppDock
{
    %orig;
    CRUpdateExtraDockButtons(self);
}

- (void)setActiveBundleIdentifier:(NSString *)bundleIdentifier animated:(BOOL)animated
{
    %orig;
    CRUpdateExtraDockButtons(self);
}

- (void)viewWillLayoutSubviews
{
    %orig;
    if (!objc_getAssociatedObject(self, &kExtraDockButtonsKey))
    {
        CRUpdateExtraDockButtons(self);
    }
}

- (void)_updateNavigationBundleIdentifier:(BOOL)animated
{
    %orig;
    CRUpdateExtraDockButtons(self);
}

- (void)_updateNowPlayingBundleIdentifier:(BOOL)animated
{
    %orig;
    CRUpdateExtraDockButtons(self);
}

- (void)_updateAppDockButtonForBundleIdentifier:(NSString *)bundleIdentifier animated:(BOOL)animated
{
    %orig;
    CRUpdateExtraDockButtons(self);
}

%end

%end

// the app list is built once per process, so restart CarPlay once after a burst of preference changes
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

    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserverForName:@"com.carplayenable.opened" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        hostedAppShowing = YES;
        updateDashboardTrim(objcInvoke([UIApplication sharedApplication], @"_currentDashboard"));
    }];
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserverForName:@"com.carplayenable.closed" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        hostedAppShowing = NO;
        updateDashboardTrim(objcInvoke([UIApplication sharedApplication], @"_currentDashboard"));
    }];
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserverForName:kCRSpringBoardModeStateNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        springBoardModeActive = [note.userInfo[@"active"] boolValue];
        id dashboard = objcInvoke([UIApplication sharedApplication], @"_currentDashboard");
        updateDashboardTrim(dashboard);
        UIViewController *rootViewController = dashboard ? objcInvoke(dashboard, @"rootViewController") : nil;
        [rootViewController setNeedsFocusUpdate];
        [rootViewController updateFocusIfNeeded];
    }];
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserverForName:kCRSpringBoardModeOpenNativeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        id application = objcInvoke_1(objcInvoke(objc_getClass("DBApplicationController"), @"sharedInstance"), @"applicationWithBundleIdentifier:", note.userInfo[@"identifier"]);
        id dashboard = objcInvoke([UIApplication sharedApplication], @"_currentDashboard");
        CRLog(@"opening the CarPlay UI of %@ (%@)", note.userInfo[@"identifier"], application);
        if (!application || !dashboard)
        {
            return;
        }
        id settings = [[[objc_getClass("DBActivationSettings") alloc] init] autorelease];
        objcInvoke_1(settings, @"setLaunchSource:", (unsigned long long)3);
        id launchInfo = objcInvoke_2(objc_getClass("DBApplicationLaunchInfo"), @"launchInfoForApplication:withActivationSettings:", application, settings);
        id event = objcInvoke_2(objc_getClass("DBEvent"), @"eventWithType:context:", (unsigned long long)4, launchInfo);
        objcInvoke_1(dashboard, @"handleEvent:", event);
    }];
    // a window from before a CarPlay restart would never close
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:@"com.carplayenable.close" object:nil userInfo:nil];
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:kCRSpringBoardModeExitNotification object:nil userInfo:nil];
    __block int restoreTries = 0;
    __block void (^restoreSpringBoardMode)(void) = [^{
        CGRect appFrame = carplayAppFrame();
        if (CGRectIsEmpty(appFrame) && ++restoreTries < 20)
        {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), restoreSpringBoardMode);
            return;
        }
        NSDictionary *userInfo = CGRectIsEmpty(appFrame) ? nil : @{@"appFrame": NSStringFromCGRect(appFrame)};
        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:kCRSpringBoardModeRestoreNotification object:nil userInfo:userInfo];
    } copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), restoreSpringBoardMode);

    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserverForName:kCRCarIconRequestNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        CRSendCarIconInfo();
    }];
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserverForName:kCRCarIconLaunchNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        id dashboard = objcInvoke([UIApplication sharedApplication], @"_currentDashboard");
        id session = objcInvoke(objcInvoke(dashboard, @"environmentConfiguration"), @"session");
        CRLog(@"caricon: opening the car's own screens (session %@)", session);
        if ([session respondsToSelector:NSSelectorFromString(@"requestCarUI")])
        {
            objcInvoke(session, @"requestCarUI");
        }
    }];

    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserverForName:PREFERENCES_CHANGED_NOTIFICATION object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        [[CRPreferences sharedInstance] reloadPreferences];
        if ([note.object isEqualToString:kPrefsAppLibraryChanged] || [note.object isEqualToString:kPrefsIconLayoutChanged])
        {
            scheduleCarplayRestart();
        }
        if ([note.object isEqualToString:kPrefsDockChanged])
        {
            objcInvoke(currentDockController(), @"_refreshAppDock");
        }
    }];
}
