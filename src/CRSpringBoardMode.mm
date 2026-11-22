#include "common.h"
#include "CRSpringBoardMode.h"

void CRRelayoutCarplayKeyboards(void);

@class CRCarIconDataSource;

@interface CRSpringBoardMode () <UIGestureRecognizerDelegate>
@property (nonatomic, retain) UIWindow *window;
@property (nonatomic, retain) id iconManager;
@property (nonatomic, retain) id iconModel;
@property (nonatomic, retain) CRCarIconDataSource *dashBoardIconDataSource;
@property (nonatomic, retain) CRCarIconDataSource *carIconDataSource;
@property (nonatomic, retain) CADisplayLink *clockDisplayLink;
@property (nonatomic, retain) UIImageView *wallpaperView;
// the wallpaper again under CarPlay's sidebar, which blurs what's beneath it
@property (nonatomic, retain) UIWindow *sidebarWallpaperWindow;
@property (nonatomic, retain) UIImageView *sidebarWallpaperView;
@property (nonatomic, retain) id libraryViewController;
@property (nonatomic, retain) id todayViewController;
@property (nonatomic, retain) id searchPresenter;
@property (nonatomic, retain) id searchPresentable;
@property (nonatomic, retain) UIView *scaledView;
@property (nonatomic, retain) UIViewController *homeViewController;
@end

static id CRListContainingIcon(id rootFolder, id icon);
static BOOL CRIconIsKind(id icon, NSString *selectorName);

/*
Frosted backgrounds (the dock, folders) in one named group share a single capture of what's behind them. With the
phone's home screen and the car's both up that capture flips between the two displays and they flicker. The car's get
a group of their own
*/
void CRSeparateMaterialGroups(UIView *view)
{
    if ([view isKindOfClass:objc_getClass("MTMaterialView")] && [view respondsToSelector:NSSelectorFromString(@"setGroupNameBase:")])
    {
        // a copy: setting the new name frees the old one
        NSString *base = [[objcInvoke(view, @"groupNameBase") copy] autorelease];
        if (base.length && ![base hasPrefix:@"CarPlayEnable."])
        {
            objcInvoke_1(view, @"setGroupNameBase:", [@"CarPlayEnable." stringByAppendingString:base]);
            CRLog(@"sbmode: material group %@ -> own", base);
        }
    }
    for (UIView *subview in view.subviews)
    {
        CRSeparateMaterialGroups(subview);
    }
}

// height the home screen is laid out at before it's scaled to the car's: 4 rows of icons, page dots and the dock.
// the size setting changes it (and the rows with it)
static const CGFloat kCRHomeScreenLayoutHeight = 530;
static const CGFloat kCRIconRowHeight = 86;
static CGFloat CRHomeScreenLayoutHeight(void)
{
    return round(kCRHomeScreenLayoutHeight / [[CRPreferences sharedInstance] homeScreenScale]);
}
// room under the icon rows for the page dots and the dock (116)
static const CGFloat kCRHomeScreenTopInset = 20;
static const CGFloat kCRHomeScreenBottomInset = 166;
// the phone's dock: an icon every 95 points, room at the ends for the dock's rounded edges
static const CGFloat kCRDockIconPitch = 95;
static const CGFloat kCRDockSideInset = 30;

static NSString *const kCRDashBoardIconIdentifier = @"com.carplayenable.dashboard";
static NSString *const kCRCarIconIdentifier = @"com.carplayenable.car";
// custom icons put on the home screen once: after that, one that's gone was taken off by the user
static NSString *const kCRPlacedIconsPath = @"/var/mobile/Library/SpringBoard/CarPlayEnablePlacedIcons.plist";
// the car's icon and name, saved for when CarPlay hasn't sent them yet
static NSString *const kCRCarIconInfoPath = @"/var/mobile/Library/SpringBoard/CarPlayEnableCarIcon.plist";
static NSString *const kCROpenCarPlayUIShortcutType = @"com.carplayenable.opencarplayui";

struct CRIconImageInfo {
    CGSize size;
    double scale;
    double continuousCornerRadius;
};

/*
Icons on the car home screen that aren't phone apps: CarPlay's own (back to its home screen) and the car's (its own
screens). They come off the home screen like Apple's apps that can't be deleted, into the App Library
*/
@interface CRCarIconDataSource : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, retain) UIImage *image;
@property (nonatomic, copy) void (^launchHandler)(void);
@end

@implementation CRCarIconDataSource

- (void)dealloc
{
    [_identifier release];
    [_displayName release];
    [_image release];
    [_launchHandler release];
    [super dealloc];
}

- (NSString *)uniqueIdentifier
{
    return self.identifier;
}

- (NSString *)configurationStorageIdentifier
{
    return nil;
}

- (long long)priorityForIcon:(id)icon
{
    return 0;
}

- (NSString *)icon:(id)icon displayNameForLocation:(id)location
{
    return self.displayName;
}

// the plain image: SpringBoard makes the dark and tinted looks from it, like for any app without its own
- (id)icon:(id)icon imageWithInfo:(struct CRIconImageInfo)info
{
    return self.image;
}

- (id)icon:(id)icon imageWithInfo:(struct CRIconImageInfo)info traitCollection:(id)traitCollection options:(unsigned long long)options
{
    return self.image;
}

- (BOOL)iconAllowsLaunch:(id)icon
{
    return YES;
}

// "Remove App" then only offers taking it off the home screen (see iconManager:wantsUninstallForIcon:location:)
- (BOOL)iconSupportsUninstall:(id)icon
{
    return YES;
}

- (void)icon:(id)icon launchFromLocation:(id)location context:(id)context
{
    if (self.launchHandler)
    {
        self.launchHandler();
    }
}

@end


// the car home screen's own layout, started from a copy of the phone's
// the phone's home screen lists' (icons stay where they're put, gaps and all)
static const long long kCRFixedIconLocationBehavior = 4;

// the App Library's category pods: size and gap on the phone, the room kept at the car library's sides
static const CGFloat kCRLibraryPodSize = 169;
static const CGFloat kCRLibraryPodGap = 26;
static const CGFloat kCRLibrarySideInset = 40;

// the phone's icon column pitch and icon width (an XR's small widget is 169pt, medium 360pt)
static const CGFloat kCRPhoneColumnPitch = 95.5;
static const CGFloat kCRIconWidth = 60;
static const CGFloat kCRHomeScreenMinSideInset = 30;

static NSString *const kCRCarIconStatePath = @"/var/mobile/Library/SpringBoard/CarPlayEnableIconState.plist";
static NSString *const kCRCarDesiredIconStatePath = @"/var/mobile/Library/SpringBoard/CarPlayEnableDesiredIconState.plist";

static id CRCarIconStore(id phoneStore)
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:kCRCarIconStatePath])
    {
        NSURL *phoneURL = [phoneStore respondsToSelector:NSSelectorFromString(@"currentIconStateURL")] ? objcInvoke(phoneStore, @"currentIconStateURL") : nil;
        NSError *error = nil;
        BOOL copied = phoneURL && [fileManager copyItemAtPath:phoneURL.path toPath:kCRCarIconStatePath error:&error];
        CRLog(@"sbmode: copied the phone's layout from %@: %d %@", phoneURL.path, copied, error);
    }
    return [objcInvoke_2([objc_getClass("SBIconModelPropertyListFileStore") alloc], @"initWithIconStateURL:desiredIconStateURL:",
        [NSURL fileURLWithPath:kCRCarIconStatePath], [NSURL fileURLWithPath:kCRCarDesiredIconStatePath]) autorelease];
}

@implementation CRSpringBoardMode
{
    CGRect _appFrame;
    NSUInteger _dockIconCount;
    NSUInteger _rootColumns;
    NSUInteger _rootRows;
    CGFloat _libraryListWidth;
    // not retained: only compared against
    id _carIconModel;
    id _carIconManager;
    UIView *_dragSnapshot;
    UIView *_dragIconView;
    id _dragIcon;
    CGPoint _dragOffset;
    CFTimeInterval _dragEdgeSince;
    // held outside edit mode: becomes a drag (and edit mode) once the finger moves
    UIView *_pendingDragIconView;
    CGPoint _pendingDragStart;
    UILongPressGestureRecognizer *_editGesture;
    UITapGestureRecognizer *_endEditGesture;
    UILongPressGestureRecognizer *_dragGesture;
    UISwipeGestureRecognizer *_closeEditorSwipe;
    // a folder drop: the icon under the finger (raised once held there) and when the finger got there
    UIView *_folderTargetView;
    UIView *_folderCandidateView;
    CFTimeInterval _folderCandidateSince;
    // the spot the finger is settling on, the icon moves there once it stays
    UIView *_hoverListView;
    unsigned long long _hoverIndex;
    CFTimeInterval _hoverSince;
    // the drag came from the App Library (the icon may not be on a page yet)
    BOOL _dragFromLibrary;
}

+ (instancetype)sharedInstance
{
    static CRSpringBoardMode *sharedInstance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[CRSpringBoardMode alloc] init];
    });
    return sharedInstance;
}

static id CRCarplayDisplayConfiguration(void)
{
    for (UIScreen *screen in [UIScreen screens])
    {
        if (objcInvokeT(screen, @"_isCarScreen", BOOL))
        {
            id displayConfiguration = objcInvoke(screen, @"fbsDisplay");
            if (displayConfiguration)
            {
                return displayConfiguration;
            }
        }
    }
    return nil;
}

- (void)postState
{
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:kCRSpringBoardModeStateNotification object:nil userInfo:@{@"active": @(_active)}];
}

// whether it's on, kept over CarPlay restarts
static NSString *const kCRSpringBoardModeOnPath = @"/var/mobile/Library/SpringBoard/CarPlayEnableSpringBoardMode.plist";

static void CRRememberSpringBoardMode(BOOL on)
{
    [@{@"on": @(on)} writeToFile:kCRSpringBoardModeOnPath atomically:YES];
}

- (BOOL)wasLeftOn
{
    return [[NSDictionary dictionaryWithContentsOfFile:kCRSpringBoardModeOnPath][@"on"] boolValue];
}

- (void)leave
{
    CRRememberSpringBoardMode(NO);
    [self exit];
}

- (void)enterWithAppFrame:(CGRect)appFrame
{
    CRRememberSpringBoardMode(YES);
    _appFrame = appFrame;
    // a window from an earlier CarPlay session belongs to a display that's gone
    if (self.window && !objcInvoke(self.window, @"screen"))
    {
        [self exit];
    }
    if (!self.window)
    {
        [self buildHomeScreen];
    }
    _active = YES;
    [self setShowing:YES];
    [self postState];
}

- (void)buildHomeScreen
{
    id displayConfiguration = CRCarplayDisplayConfiguration();
    assertGotExpectedObject(displayConfiguration, @"FBSDisplayConfiguration");

    UIWindow *window = [objcInvoke_1([objc_getClass("UIRootSceneWindow") alloc], @"initWithDisplayConfiguration:", displayConfiguration) autorelease];
    CGRect displayBounds = window.bounds;
    CGRect frame = _appFrame;
    if (CGRectIsEmpty(frame) || !CGRectContainsRect(displayBounds, frame))
    {
        frame = CGRectMake(CARPLAY_SIDEBAR_WIDTH, 0, displayBounds.size.width - CARPLAY_SIDEBAR_WIDTH, displayBounds.size.height);
    }
    window.frame = frame;
    // over CarPlay's home screen (0), under our app windows (1) and CarPlay's sidebar host, banners and Siri (5+)
    window.windowLevel = 0.5;
    window.backgroundColor = [UIColor blackColor];
    window.layer.masksToBounds = YES;

    UIViewController *rootViewController = [[[UIViewController alloc] init] autorelease];
    rootViewController.view.backgroundColor = [UIColor clearColor];
    // the car screen says CarPlay, where long press menus and bars behave differently: the home screen is a phone's
    // (on the window too, for sheets it presents like the icon editor)
    for (id traitEnvironment in @[window, rootViewController])
    {
        if ([traitEnvironment respondsToSelector:NSSelectorFromString(@"traitOverrides")])
        {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(objcInvoke(traitEnvironment, @"traitOverrides"), NSSelectorFromString(@"setUserInterfaceIdiom:"), UIUserInterfaceIdiomPhone);
        }
    }
    window.rootViewController = rootViewController;

    // laid over the whole car screen, so it lines up with the copy under the sidebar
    rootViewController.view.frame = window.bounds;
    UIImageView *wallpaperView = [[[UIImageView alloc] initWithFrame:CGRectOffset(displayBounds, -frame.origin.x, -frame.origin.y)] autorelease];
    wallpaperView.contentMode = UIViewContentModeScaleAspectFill;
    wallpaperView.clipsToBounds = YES;
    [rootViewController.view addSubview:wallpaperView];
    self.wallpaperView = wallpaperView;

    UIWindow *sidebarWallpaperWindow = [objcInvoke_1([objc_getClass("UIRootSceneWindow") alloc], @"initWithDisplayConfiguration:", displayConfiguration) autorelease];
    sidebarWallpaperWindow.frame = displayBounds;
    // under all of CarPlay's windows (its wallpaper's are -1 and 0)
    sidebarWallpaperWindow.windowLevel = -1.5;
    sidebarWallpaperWindow.userInteractionEnabled = NO;
    UIImageView *sidebarWallpaperView = [[[UIImageView alloc] initWithFrame:sidebarWallpaperWindow.bounds] autorelease];
    sidebarWallpaperView.contentMode = UIViewContentModeScaleAspectFill;
    sidebarWallpaperView.clipsToBounds = YES;
    [sidebarWallpaperWindow addSubview:sidebarWallpaperView];
    self.sidebarWallpaperWindow = sidebarWallpaperWindow;
    self.sidebarWallpaperView = sidebarWallpaperView;

    // a model of its own (an icon manager takes over its model's delegate) on its own copy of the layout
    id iconController = objcInvoke(objc_getClass("SBIconController"), @"sharedInstance");
    id phoneModel = objcInvoke(iconController, @"model");
    id store = CRCarIconStore(objcInvoke(phoneModel, @"store"));
    [[CRPreferences sharedInstance] reloadPreferences];
    CGFloat layoutHeight = CRHomeScreenLayoutHeight();
    NSUInteger rows = MAX(2, (NSUInteger)floor((layoutHeight - kCRHomeScreenTopInset - kCRHomeScreenBottomInset) / kCRIconRowHeight));
    // as many dock icons as fit across the car screen (laid out layoutHeight tall, then scaled)
    CGFloat layoutWidth = frame.size.width * layoutHeight / frame.size.height;
    // columns at the phone's pitch, so widgets (phone sized) line up with the icons around them
    NSUInteger columns = MAX(4, (NSUInteger)floor((layoutWidth - 2 * kCRHomeScreenMinSideInset - kCRIconWidth) / kCRPhoneColumnPitch) + 1);
    CGFloat sideInset = (layoutWidth - (columns - 1) * kCRPhoneColumnPitch - kCRIconWidth) / 2;
    _rootColumns = columns;
    _rootRows = rows;
    _dockIconCount = MAX(4, (NSUInteger)floor((layoutWidth - 2 * kCRDockSideInset) / kCRDockIconPitch));
    id model = [objcInvoke_2([objc_getClass("SBIconModel") alloc], @"initWithStore:applicationDataSource:", store, iconController) autorelease];
    _carIconModel = model;
    assertGotExpectedObject(model, @"SBIconModel");

    // the phone's home screen layout. SpringBoard's own provider hands out StandBy's layout in landscape
    Class providerClass = objc_getClass("SBHDefaultIconListLayoutProvider");
    unsigned long long screenType = ((unsigned long long (*)(id, SEL))objc_msgSend)(providerClass, NSSelectorFromString(@"currentDeviceScreenType"));
    id listLayoutProvider = [objcInvoke_1([providerClass alloc], @"initWithScreenType:", screenType) autorelease];
    // pages, and pages with widgets (a layout of their own). They lay out upright (rotated layouts drop free placement's
    // gaps), so both orientations get the car's grid
    UIEdgeInsets rootInsets = UIEdgeInsetsMake(kCRHomeScreenTopInset, sideInset, kCRHomeScreenBottomInset, sideInset);
    for (NSString *location in @[@"SBIconLocationRoot", @"SBIconLocationRootWithWidgets"])
    {
        id rootGrid = objcInvoke(objcInvoke_1(listLayoutProvider, @"layoutForIconLocation:", location), @"layoutConfiguration");
        objcInvoke_1(rootGrid, @"setNumberOfLandscapeColumns:", (unsigned long long)columns);
        objcInvoke_1(rootGrid, @"setNumberOfLandscapeRows:", (unsigned long long)rows);
        ((void (*)(id, SEL, UIEdgeInsets))objc_msgSend)(rootGrid, NSSelectorFromString(@"setLandscapeLayoutInsets:"), rootInsets);
        objcInvoke_1(rootGrid, @"setNumberOfPortraitColumns:", (unsigned long long)columns);
        objcInvoke_1(rootGrid, @"setNumberOfPortraitRows:", (unsigned long long)rows);
        ((void (*)(id, SEL, UIEdgeInsets))objc_msgSend)(rootGrid, NSSelectorFromString(@"setPortraitLayoutInsets:"), rootInsets);
    }
    CRLog(@"sbmode: %lu columns, side inset %.1f in %.0f", (unsigned long)columns, sideInset, layoutWidth);

    // the App Library's pods (2x2 cells each): as many across as fit the car's width
    _libraryListWidth = layoutWidth - 2 * kCRLibrarySideInset;
    NSUInteger pods = MAX(2, (NSUInteger)floor((_libraryListWidth - 64 + kCRLibraryPodGap) / (kCRLibraryPodSize + kCRLibraryPodGap)));
    id libraryGrid = objcInvoke(objcInvoke_1(listLayoutProvider, @"layoutForIconLocation:", @"SBIconLocationAppLibrary"), @"layoutConfiguration");
    objcInvoke_1(libraryGrid, @"setNumberOfPortraitColumns:", (unsigned long long)(2 * pods));
    objcInvoke_1(libraryGrid, @"setNumberOfLandscapeColumns:", (unsigned long long)(2 * pods));
    ((void (*)(id, SEL, CGSize))objc_msgSend)(libraryGrid, NSSelectorFromString(@"setListSizeForIconSpacingCalculation:"), CGSizeMake(_libraryListWidth, 896));
    CRLog(@"sbmode: library %lu pods across %.0f", (unsigned long)pods, _libraryListWidth);

    id dockGrid = objcInvoke(objcInvoke_1(listLayoutProvider, @"layoutForIconLocation:", @"SBIconLocationDock"), @"layoutConfiguration");
    objcInvoke_1(dockGrid, @"setNumberOfPortraitColumns:", (unsigned long long)_dockIconCount);
    objcInvoke_1(dockGrid, @"setNumberOfLandscapeColumns:", (unsigned long long)_dockIconCount);
    CRLog(@"sbmode: dock of %lu for a %.0f wide layout: %@", (unsigned long)_dockIconCount, layoutWidth, dockGrid);
    // icon spacing comes from the phone's dock width unless told otherwise
    CGSize spacingSize = ((CGSize (*)(id, SEL))objc_msgSend)(dockGrid, NSSelectorFromString(@"listSizeForIconSpacingCalculation"));
    ((void (*)(id, SEL, CGSize))objc_msgSend)(dockGrid, NSSelectorFromString(@"setListSizeForIconSpacingCalculation:"), CGSizeMake(layoutWidth, spacingSize.height));
    CRLog(@"sbmode: dock spacing size %@ -> %.0f wide", NSStringFromCGSize(spacingSize), layoutWidth);

    id manager = [[[objc_getClass("SBHIconManager") alloc] init] autorelease];
    _carIconManager = manager;
    objcInvoke_1(manager, @"setListLayoutProvider:", listLayoutProvider);
    objcInvoke_1(manager, @"setDelegate:", self);
    // the Edit button in edit mode: Add Widget, Customize (the icon look) and Edit Pages
    ((void (*)(id, SEL, BOOL))objc_msgSend)(manager, NSSelectorFromString(@"setShowsAddWidgetButtonWhileEditing:"), YES);
    // the phone's model is told which app tags to show and hide, copy that
    objcInvoke_2(model, @"setVisibilityOfIconsWithVisibleTags:hiddenTags:", objcInvoke(phoneModel, @"visibleIconTags"), objcInvoke(phoneModel, @"hiddenIconTags"));
    // ours aren't apps: the saved layout drops icons the model doesn't have yet
    [self registerCustomIconsInModel:model];
    ((void (*)(id, SEL))objc_msgSend)(model, NSSelectorFromString(@"reloadIcons"));
    objcInvoke_1(manager, @"setIconModel:", model);
    if (!objcInvoke(manager, @"rootFolder"))
    {
        objcInvoke_1(manager, @"setRootFolder:", objcInvoke(model, @"rootFolder"));
    }
    [self addDashBoardIconToModel:model rootFolder:objcInvoke(manager, @"rootFolder")];
    ((void (*)(id, SEL, long long))objc_msgSend)(objcInvoke(manager, @"rootFolder"), NSSelectorFromString(@"setListsFixedIconLocationBehavior:"), kCRFixedIconLocationBehavior);
    // the dock stays in order
    ((void (*)(id, SEL, long long))objc_msgSend)(objcInvoke(objcInvoke(manager, @"rootFolder"), @"dock"), NSSelectorFromString(@"setFixedIconLocationBehavior:"), 0);

    // the manager makes its own root view controller (the root folder's), like CarPlay's home screen embeds it
    UIViewController *rootFolderController = objcInvoke(manager, @"rootFolderController");
    UIViewController *homeViewController = objcInvoke(manager, @"rootViewController") ?: rootFolderController;
    CRLog(@"sbmode: model %@ root folder %@ controller %@ root %@ parent %@", model, objcInvoke(model, @"rootFolder"), rootFolderController, homeViewController, homeViewController.parentViewController);
    assertGotExpectedObject(homeViewController, @"UIViewController");
    if (!homeViewController.parentViewController)
    {
        // phone-sized icons, widgets and dock don't fit the car's height: lay out taller and scale down to fit
        CGFloat scale = frame.size.height / layoutHeight;
        UIView *scaledView = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, frame.size.width / scale, layoutHeight)] autorelease];
        scaledView.transform = CGAffineTransformMakeScale(scale, scale);
        scaledView.center = CGPointMake(frame.size.width / 2, frame.size.height / 2);
        [rootViewController.view addSubview:scaledView];
        self.scaledView = scaledView;

        UILongPressGestureRecognizer *dragGesture = [[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleIconDrag:)] autorelease];
        dragGesture.minimumPressDuration = 0.2;
        dragGesture.allowableMovement = 10;
        dragGesture.delegate = self;
        [scaledView addGestureRecognizer:dragGesture];
        _dragGesture = dragGesture;

        // the icon editor fills the car screen and its own swipe down doesn't close it here
        UISwipeGestureRecognizer *closeEditorSwipe = [[[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(handleCloseEditorSwipe:)] autorelease];
        closeEditorSwipe.direction = UISwipeGestureRecognizerDirectionDown;
        closeEditorSwipe.cancelsTouchesInView = NO;
        closeEditorSwipe.delegate = self;
        [window addGestureRecognizer:closeEditorSwipe];
        _closeEditorSwipe = closeEditorSwipe;

        // a hold on an empty spot starts edit mode, like the phone's
        UILongPressGestureRecognizer *editGesture = [[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleEditHold:)] autorelease];
        editGesture.minimumPressDuration = 0.6;
        editGesture.allowableMovement = 10;
        editGesture.delegate = self;
        [scaledView addGestureRecognizer:editGesture];
        _editGesture = editGesture;

        // and a tap on one ends it
        UITapGestureRecognizer *endEditGesture = [[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleEndEditTap:)] autorelease];
        endEditGesture.cancelsTouchesInView = NO;
        endEditGesture.delegate = self;
        [scaledView addGestureRecognizer:endEditGesture];
        _endEditGesture = endEditGesture;

        [rootViewController addChildViewController:homeViewController];
        homeViewController.view.frame = scaledView.bounds;
        homeViewController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [scaledView addSubview:homeViewController.view];
        [homeViewController didMoveToParentViewController:rootViewController];
        self.homeViewController = homeViewController;
        [self updateIconStyle];
    }

    self.window = window;
    // ones made before the window was known here (the dock's)
    dispatch_async(dispatch_get_main_queue(), ^{
        CRSeparateMaterialGroups(window);
    });
    self.iconManager = manager;
    self.iconModel = model;
    CRLog(@"sbmode: home screen on display %@ at %@", objcInvoke(displayConfiguration, @"identity"), NSStringFromCGRect(frame));
}

// the App Library past the last page, sorted the way the phone's is
- (void)addLibraryToIconManager:(id)manager iconController:(id)iconController
{
    @try
    {
        id categoryMapProvider = objcInvoke(iconController, @"libraryCategoryMapProvider");
        id library = [objcInvoke_1([objc_getClass("SBHLibraryViewController") alloc], @"initWithCategoryMapProvider:", categoryMapProvider) autorelease];
        objcInvoke_1(manager, @"configureLibraryViewController:", library);
        id phoneManager = objcInvoke(iconController, @"iconManager");
        id phoneLibrary = objcInvoke(phoneManager, @"overlayLibraryViewController") ?: objcInvoke(phoneManager, @"trailingLibraryViewController");
        objcInvoke_1(library, @"setIconModel:", self.iconModel ?: objcInvoke(manager, @"iconModel"));
        // the car's own layouts: its library is wider than the phone's (see CRLibraryListWidth)
        objcInvoke_1(library, @"setListLayoutProvider:", objcInvoke(phoneLibrary, @"listLayoutProvider") ?: objcInvoke(manager, @"listLayoutProvider"));
        objcInvoke_1(library, @"setIconViewProvider:", manager);
        objcInvoke_1(library, @"setIconViewDelegate:", manager);
        objcInvoke_1(library, @"setBadgeBehaviorProvider:", manager);
        objcInvoke_1(library, @"setPresenter:", manager);
        objcInvoke_1(library, @"setIconImageCache:", objcInvoke(manager, @"iconImageCache"));
        if (objcInvoke(phoneLibrary, @"iconLocation"))
        {
            objcInvoke_1(library, @"setIconLocation:", objcInvoke(phoneLibrary, @"iconLocation"));
        }
        ((void (*)(id, SEL, BOOL))objc_msgSend)(library, NSSelectorFromString(@"setAllowsBadging:"), YES);
        objcInvoke_1(manager, @"setTrailingCustomViewController:", library);
        self.libraryViewController = library;
        // it took the map while being made, before it was known to be the car's: again, with ours in it
        id categoryMap = objcInvoke(categoryMapProvider, @"libraryCategoryMap");
        if (categoryMap && [library respondsToSelector:NSSelectorFromString(@"_installCategoryMap:")])
        {
            objcInvoke_1(library, @"_installCategoryMap:", categoryMap);
        }
        CRLog(@"sbmode: library %@ model %@", library, objcInvoke(library, @"iconModel"));
    }
    @catch (NSException *exception)
    {
        CRLog(@"sbmode: library failed: %@", exception);
    }
}

// the widget page before the first page, like the phone's
- (void)addTodayViewToIconManager:(id)manager
{
    @try
    {
        id rootFolder = objcInvoke(manager, @"rootFolder") ?: objcInvoke(self.iconModel, @"rootFolder");
        id today = [((id (*)(id, SEL, id, id, long long))objc_msgSend)([objc_getClass("SBHTodayViewController") alloc], NSSelectorFromString(@"initWithListLayoutProvider:iconViewProvider:location:"), objcInvoke(manager, @"listLayoutProvider"), manager, 0) autorelease];
        objcInvoke_1(today, @"setIconManager:", manager);
        objcInvoke_1(today, @"setRootFolder:", rootFolder);
        self.todayViewController = today;
        CRLog(@"sbmode: today view %@ location %@ list %@", today, objcInvoke(today, @"iconLocation"), objcInvoke(rootFolder, @"favoriteTodayList"));
    }
    @catch (NSException *exception)
    {
        CRLog(@"sbmode: today view failed: %@", exception);
    }
}

/*
Spotlight (pull down, or the Search pill under the icons). Spotlight is one scene shared by every place that shows it
on the phone; the car's own presentable draws it on the car while the scene stays on the phone's display (UIKit gives
a scene on a CarPlay screen no keyboard)
*/
- (void)addSearchToConfiguration:(id)configuration
{
    @try
    {
        if (!self.searchPresenter)
        {
            id iconController = objcInvoke(objc_getClass("SBIconController"), @"sharedInstance");
            // its own wrapper around the one Spotlight view
            id multiplexer = [objcInvoke_1([objc_getClass("SBHomeScreenSpotlightViewController") alloc], @"initWithDelegate:", iconController) autorelease];
            id presentable = [objcInvoke_1([objc_getClass("SBSpotlightPresentableViewController") alloc], @"initWithSpotlightMultiplexingViewController:", multiplexer) autorelease];
            objcInvoke_1(presentable, @"setDelegate:", iconController);
            id settings = objcInvoke(objcInvoke(iconController, @"searchPresenter"), @"pullToSearchSettings");
            id presenter = [objcInvoke_2([objc_getClass("SBSearchPresenter") alloc], @"initWithSettings:identifier:", settings, @"CarPlayEnable") autorelease];
            objcInvoke_1(presenter, @"setPresentables:", @[presentable]);
            objcInvoke_1(presenter, @"setSearchPresenterDelegate:", self);
            self.searchPresentable = presentable;
            self.searchPresenter = presenter;
            CRLog(@"sbmode: search presenter %@ presentable %@", presenter, presentable);
        }
        objcInvoke_1(configuration, @"setSearchPresenter:", self.searchPresenter);
        objcInvoke_1(configuration, @"setSearchPresentableViewController:", self.searchPresentable);
        UIView *pill = objcInvoke(objc_getClass("SBHSearchPillView"), @"searchPillViewWithSystemDefaultBackground");
        UITapGestureRecognizer *pillTap = [[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(presentSearch)] autorelease];
        [pill addGestureRecognizer:pillTap];
        objcInvoke_1(configuration, @"setScrollAccessoryAuxiliaryView:", pill);
    }
    @catch (NSException *exception)
    {
        CRLog(@"sbmode: search failed: %@", exception);
    }
}

- (void)presentSearch
{
    ((void (*)(id, SEL, BOOL))objc_msgSend)(self.searchPresenter, NSSelectorFromString(@"presentSearchAnimated:"), YES);
}

// what the phone's presenter delegate (SBIconController) does for its own: show the search view and hand it Spotlight
- (void)activateCarSearch:(BOOL)active
{
    UIViewController *presentable = self.searchPresentable;
    UIViewController *multiplexer = objcInvoke(presentable, @"spotlightMultiplexingViewController");
    if (!presentable || ((BOOL (*)(id, SEL))objc_msgSend)(multiplexer, NSSelectorFromString(@"isActiveDelegate")) == active)
    {
        return;
    }
    CRLog(@"sbmode: search %@", active ? @"on" : @"off");
    if (active)
    {
        presentable.view.hidden = NO;
    }
    ((void (*)(id, SEL, BOOL))objc_msgSend)(multiplexer, NSSelectorFromString(@"setActiveDelegate:"), active);
    [multiplexer beginAppearanceTransition:active animated:NO];
    [multiplexer endAppearanceTransition];
    // the scene settings hook turns Spotlight landscape on the car, portrait back on the phone
    id remoteSearch = objcInvoke(objc_getClass("SBSpotlightMultiplexingViewController"), @"sharedRemoteSearchViewController");
    if ([remoteSearch respondsToSelector:NSSelectorFromString(@"updateSceneSettingsWithBlock:")])
    {
        objcInvoke_1(remoteSearch, @"updateSceneSettingsWithBlock:", ^(id settings) {});
    }
    if (!active)
    {
        presentable.view.hidden = YES;
    }
    CRRelayoutCarplayKeyboards();
}

- (BOOL)isSearchShowing
{
    if (!_active || !self.window || self.window.hidden || !self.searchPresentable)
    {
        return NO;
    }
    id multiplexer = objcInvoke(self.searchPresentable, @"spotlightMultiplexingViewController");
    return ((BOOL (*)(id, SEL))objc_msgSend)(multiplexer, NSSelectorFromString(@"isActiveDelegate"));
}


- (void)searchPresenterWillPresentSearch:(id)presenter animated:(BOOL)animated
{
    [self activateCarSearch:YES];
}

- (void)searchPresenterDidPresentSearch:(id)presenter
{
    [self activateCarSearch:YES];
}

- (void)searchPresenterDidDismissSearch:(id)presenter
{
    [self activateCarSearch:NO];
}

- (BOOL)dismissSearch
{
    if (!self.searchPresenter || !((BOOL (*)(id, SEL))objc_msgSend)(self.searchPresenter, NSSelectorFromString(@"isPresenting")))
    {
        return NO;
    }
    ((void (*)(id, SEL, BOOL, id))objc_msgSend)(self.iconManager, NSSelectorFromString(@"dismissSpotlightAnimated:completionHandler:"), YES, nil);
    return YES;
}

- (BOOL)searchPresenterCanPresent:(id)presenter
{
    return _active && self.window && !self.window.hidden && ![self isEditing];
}

- (NSArray *)searchPresentablesForPresenter:(id)presenter
{
    return self.searchPresentable ? @[self.searchPresentable] : @[];
}

- (CGFloat)searchTopOffsetForSearchPresenter:(id)presenter
{
    return 0;
}

// the home button on the home screen: to the widget page, and back
- (void)homeButtonPressed
{
    if (!_active || !self.window || self.window.hidden || !self.todayViewController)
    {
        return;
    }
    id rootFolderController = objcInvoke(self.iconManager, @"rootFolderController");
    if ([self isEditing] || [self dismissSearch])
    {
        return;
    }
    BOOL onToday = ((BOOL (*)(id, SEL))objc_msgSend)(rootFolderController, NSSelectorFromString(@"isLeadingCustomViewVisibleOrTransitionDestination"));
    long long page = onToday
        ? ((long long (*)(id, SEL))objc_msgSend)(rootFolderController, NSSelectorFromString(@"firstIconPageIndex"))
        : ((long long (*)(id, SEL))objc_msgSend)(rootFolderController, NSSelectorFromString(@"leadingCustomViewPageIndex"));
    ((BOOL (*)(id, SEL, long long, BOOL))objc_msgSend)(rootFolderController, NSSelectorFromString(@"setCurrentPageIndex:animated:"), page, YES);
}

- (void)registerCustomIconsInModel:(id)model
{
    [self makeDashBoardIconDataSource];
    NSDictionary *carIconInfo = [NSDictionary dictionaryWithContentsOfFile:kCRCarIconInfoPath];
    if (carIconInfo)
    {
        [self makeCarIconDataSourceWithName:carIconInfo[@"name"] imageData:carIconInfo[@"image"]];
    }
    for (CRCarIconDataSource *dataSource in @[self.dashBoardIconDataSource ?: [NSNull null], self.carIconDataSource ?: [NSNull null]])
    {
        if ((id)dataSource == [NSNull null] || objcInvoke_1(model, @"leafIconForIdentifier:", dataSource.identifier))
        {
            continue;
        }
        NSString *bundleID = dataSource == self.dashBoardIconDataSource ? kCRDashBoardBundleID : nil;
        id icon = [objcInvoke_2([objc_getClass("SBLeafIcon") alloc], @"initWithLeafIdentifier:applicationBundleID:", dataSource.identifier, bundleID) autorelease];
        objcInvoke_1(icon, @"addIconDataSource:", dataSource);
        objcInvoke_1(model, @"addIcon:", icon);
    }
}

- (void)makeCarIconDataSourceWithName:(NSString *)name imageData:(NSData *)imageData
{
    UIImage *image = imageData.length ? [UIImage imageWithData:imageData scale:[UIScreen mainScreen].scale] : nil;
    if (!name.length || !image)
    {
        return;
    }
    if (!self.carIconDataSource)
    {
        CRCarIconDataSource *dataSource = [[[CRCarIconDataSource alloc] init] autorelease];
        dataSource.identifier = kCRCarIconIdentifier;
        dataSource.launchHandler = ^{
            [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:kCRCarIconLaunchNotification object:nil userInfo:nil];
        };
        self.carIconDataSource = dataSource;
    }
    self.carIconDataSource.displayName = name;
    self.carIconDataSource.image = image;
}

// CarPlay's own app in the dock (or on the last page if the dock is full), the way back to CarPlay's home screen
- (void)addDashBoardIconToModel:(id)model rootFolder:(id)rootFolder
{
    [self makeDashBoardIconDataSource];
    [self addCustomIcon:self.dashBoardIconDataSource bundleID:kCRDashBoardBundleID toModel:model rootFolder:rootFolder preferDock:YES];
    if (self.carIconDataSource)
    {
        [self addCustomIcon:self.carIconDataSource bundleID:nil toModel:model rootFolder:rootFolder preferDock:NO];
    }
    [self saveCustomIconPositions];
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:kCRCarIconRequestNotification object:nil userInfo:nil];
}

- (void)makeDashBoardIconDataSource
{
    if (!self.dashBoardIconDataSource)
    {
        CRCarIconDataSource *dataSource = [[[CRCarIconDataSource alloc] init] autorelease];
        dataSource.identifier = kCRDashBoardIconIdentifier;
        dataSource.displayName = @"CarPlay";
        dataSource.image = ((id (*)(id, SEL, id, int, CGFloat))objc_msgSend)([UIImage class], NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:"), kCRDashBoardBundleID, 2, [UIScreen mainScreen].scale);
        dataSource.launchHandler = ^{
            [[CRSpringBoardMode sharedInstance] leave];
        };
        self.dashBoardIconDataSource = dataSource;
    }
}

// where each of ours sits (list -1 is the dock), or that the user took it off the home screen
static NSMutableDictionary *CRCustomIconPositions(void)
{
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:kCRPlacedIconsPath];
    return [saved isKindOfClass:[NSDictionary class]] ? [[saved mutableCopy] autorelease] : [NSMutableDictionary dictionary];
}

- (NSArray<CRCarIconDataSource *> *)customIconDataSources
{
    NSMutableArray *dataSources = [NSMutableArray array];
    if (self.dashBoardIconDataSource)
    {
        [dataSources addObject:self.dashBoardIconDataSource];
    }
    if (self.carIconDataSource)
    {
        [dataSources addObject:self.carIconDataSource];
    }
    return dataSources;
}

/*
SpringBoard's saved layout drops icons that aren't apps when it loads, so ours keep their own: saved after they're
placed or dragged, put back when the home screen is built
*/
- (void)saveCustomIconPositions
{
    id rootFolder = objcInvoke(self.iconManager, @"rootFolder");
    if (!rootFolder || !self.iconModel)
    {
        return;
    }
    NSMutableDictionary *positions = CRCustomIconPositions();
    id dock = objcInvoke(rootFolder, @"dock");
    for (CRCarIconDataSource *dataSource in [self customIconDataSources])
    {
        id icon = objcInvoke_1(self.iconModel, @"leafIconForIdentifier:", dataSource.identifier);
        if (!icon)
        {
            continue;
        }
        NSUInteger dockIndex = [objcInvoke(dock, @"icons") indexOfObject:icon];
        if (dockIndex != NSNotFound)
        {
            positions[dataSource.identifier] = @{@"list": @(-1), @"index": @(dockIndex)};
            continue;
        }
        NSUInteger listIndex = ((NSUInteger (*)(id, SEL, id))objc_msgSend)(rootFolder, NSSelectorFromString(@"indexOfListContainingIcon:"), icon);
        if (listIndex != NSNotFound)
        {
            id list = objcInvoke_1(rootFolder, @"listAtIndex:", listIndex);
            positions[dataSource.identifier] = @{@"list": @(listIndex), @"index": @([objcInvoke(list, @"icons") indexOfObject:icon])};
        }
    }
    [positions writeToFile:kCRPlacedIconsPath atomically:YES];
}

- (void)addCustomIcon:(CRCarIconDataSource *)dataSource bundleID:(NSString *)bundleID toModel:(id)model rootFolder:(id)rootFolder preferDock:(BOOL)preferDock
{
    id icon = objcInvoke_1(model, @"leafIconForIdentifier:", dataSource.identifier);
    BOOL onHomeScreen = icon && objcInvoke_1(rootFolder, @"indexPathForIcon:", icon);
    if (!icon)
    {
        icon = [objcInvoke_2([objc_getClass("SBLeafIcon") alloc], @"initWithLeafIdentifier:applicationBundleID:", dataSource.identifier, bundleID) autorelease];
        objcInvoke_1(model, @"addIcon:", icon);
    }
    objcInvoke_1(icon, @"removeIconDataSourcesOfClass:", [CRCarIconDataSource class]);
    objcInvoke_1(icon, @"addIconDataSource:", dataSource);
    if (onHomeScreen)
    {
        return;
    }

    NSDictionary *position = CRCustomIconPositions()[dataSource.identifier];
    if ([position[@"removed"] boolValue])
    {
        CRLog(@"sbmode: %@ icon in the App Library only", dataSource.displayName);
        return;
    }
    id dock = objcInvoke(rootFolder, @"dock");
    id list = nil;
    if (position)
    {
        long long listIndex = [position[@"list"] longLongValue];
        NSUInteger listCount = ((NSUInteger (*)(id, SEL))objc_msgSend)(rootFolder, NSSelectorFromString(@"listCount"));
        list = listIndex < 0 ? dock : (listIndex < (long long)listCount ? objcInvoke_1(rootFolder, @"listAtIndex:", (NSUInteger)listIndex) : nil);
    }
    else if (preferDock)
    {
        list = dock;
    }
    if (list && !((BOOL (*)(id, SEL))objc_msgSend)(list, NSSelectorFromString(@"isFull")))
    {
        NSUInteger count = [objcInvoke(list, @"icons") count];
        NSUInteger index = position ? MIN((NSUInteger)[position[@"index"] unsignedLongLongValue], count) : count;
        ((id (*)(id, SEL, id, NSUInteger, unsigned long long))objc_msgSend)(list, NSSelectorFromString(@"insertIcon:atIndex:options:"), icon, index, 0);
    }
    else
    {
        objcInvoke_1(rootFolder, @"addIcon:", icon);
    }
    CRLog(@"sbmode: put the %@ icon %@", dataSource.displayName, position ? [NSString stringWithFormat:@"back at %@", position] : @"on the home screen");
}

- (void)updateCarIconWithName:(NSString *)name imageData:(NSData *)imageData
{
    [self makeCarIconDataSourceWithName:name imageData:imageData];
    if (!self.carIconDataSource)
    {
        return;
    }
    if (self.iconModel)
    {
        [self addCustomIcon:self.carIconDataSource bundleID:nil toModel:self.iconModel rootFolder:objcInvoke(self.iconManager, @"rootFolder") preferDock:NO];
        id icon = objcInvoke_1(self.iconModel, @"leafIconForIdentifier:", kCRCarIconIdentifier);
        objcInvoke(icon, @"reloadIconImage");
        [self saveCustomIconPositions];
    }
}

- (void)noteCarIconName:(NSString *)name imageData:(NSData *)imageData
{
    if (!name.length || !imageData.length)
    {
        return;
    }
    [@{@"name": name, @"image": imageData} writeToFile:kCRCarIconInfoPath atomically:YES];
    if (_active)
    {
        [self updateCarIconWithName:name imageData:imageData];
    }
}

- (NSArray<NSString *> *)libraryIconIdentifiers
{
    NSMutableArray *identifiers = [NSMutableArray arrayWithObject:kCRDashBoardIconIdentifier];
    if (self.carIconDataSource || [[NSFileManager defaultManager] fileExistsAtPath:kCRCarIconInfoPath])
    {
        [identifiers addObject:kCRCarIconIdentifier];
    }
    return identifiers;
}

- (BOOL)isCarLibrary:(id)libraryViewController
{
    return libraryViewController && libraryViewController == self.libraryViewController;
}

- (BOOL)isCustomIcon:(id)icon
{
    NSString *identifier = [icon respondsToSelector:NSSelectorFromString(@"leafIdentifier")] ? objcInvoke(icon, @"leafIdentifier") : nil;
    return [identifier isEqualToString:kCRDashBoardIconIdentifier] || [identifier isEqualToString:kCRCarIconIdentifier];
}

// "Remove App": ours only come off the home screen (into the App Library); apps get the phone's choices
// folders and widgets: iOS asks on the phone's screen, so ask on the car's
- (void)confirmRemovalOfContainerIcon:(id)icon
{
    BOOL folder = [icon respondsToSelector:NSSelectorFromString(@"isFolderIcon")] && ((BOOL (*)(id, SEL))objc_msgSend)(icon, NSSelectorFromString(@"isFolderIcon"));
    NSString *title = folder ? [NSString stringWithFormat:@"Remove \u201c%@\u201d?", objcInvoke(icon, @"displayName") ?: @"Folder"] : @"Remove Widget?";
    NSString *message = folder ? @"Its apps will stay in your App Library." : @"Removing this widget will not delete any apps or data.";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:folder ? @"Remove Folder" : @"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        id list = CRListContainingIcon(objcInvoke(self.iconManager, @"rootFolder"), icon);
        if (list)
        {
            objcInvoke_1(list, @"removeIcon:", icon);
            ((void (*)(id, SEL))objc_msgSend)(self.iconModel, NSSelectorFromString(@"saveIconStateIfNeeded"));
        }
        CRLog(@"sbmode: removed %@ (list %@)", icon, list ? @"found" : @"none");
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *presenter = self.window.rootViewController;
    while (presenter.presentedViewController)
    {
        presenter = presenter.presentedViewController;
    }
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)iconManager:(id)manager wantsUninstallForIcon:(id)icon location:(id)location
{
    CRLog(@"sbmode: uninstall %@", icon);
    BOOL folder = [icon respondsToSelector:NSSelectorFromString(@"isFolderIcon")] && ((BOOL (*)(id, SEL))objc_msgSend)(icon, NSSelectorFromString(@"isFolderIcon"));
    BOOL widget = [icon respondsToSelector:NSSelectorFromString(@"isWidgetIcon")] && ((BOOL (*)(id, SEL))objc_msgSend)(icon, NSSelectorFromString(@"isWidgetIcon"));
    if (folder || widget)
    {
        [self confirmRemovalOfContainerIcon:icon];
        return;
    }
    if (![self isCustomIcon:icon])
    {
        id iconController = objcInvoke(objc_getClass("SBIconController"), @"sharedInstance");
        if ([iconController respondsToSelector:_cmd])
        {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(iconController, _cmd, manager, icon, location);
        }
        return;
    }
    NSString *name = objcInvoke(icon, @"displayName") ?: @"";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Remove \u201c%@\u201d?", name] message:@"It will stay in your App Library." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Remove from Home Screen" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        id list = CRListContainingIcon(objcInvoke(self.iconManager, @"rootFolder"), icon);
        if (list)
        {
            objcInvoke_1(list, @"removeIcon:", icon);
            ((void (*)(id, SEL))objc_msgSend)(self.iconModel, NSSelectorFromString(@"saveIconStateIfNeeded"));
        }
        NSMutableDictionary *positions = CRCustomIconPositions();
        positions[objcInvoke(icon, @"leafIdentifier")] = @{@"removed": @YES};
        [positions writeToFile:kCRPlacedIconsPath atomically:YES];
        CRLog(@"sbmode: took %@ off the home screen (list %@)", name, list ? @"found" : @"none");
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *presenter = self.window.rootViewController;
    while (presenter.presentedViewController)
    {
        presenter = presenter.presentedViewController;
    }
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)setShowing:(BOOL)showing
{
    if (!self.window)
    {
        return;
    }
    self.window.hidden = !(showing && _active);
    self.sidebarWallpaperWindow.hidden = self.window.hidden;
    [self setClockTicking:!self.window.hidden];
    if (!self.window.hidden)
    {
        [self updateWallpaper];
    }
}

/*
The phone's home screen wallpaper is a poster drawn by PosterBoard. SpringBoard keeps a still snapshot of it, use that
*/
static UIImage *CRPosterSnapshotInViewController(UIViewController *viewController, NSInteger variant)
{
    if ([viewController isKindOfClass:objc_getClass("PBUIPosterVariantViewController")] && objcInvokeT(viewController, @"variant", NSInteger) == variant)
    {
        id snapshot = objcInvoke(viewController, @"snapshot");
        if ([snapshot isKindOfClass:[UIImage class]])
        {
            return snapshot;
        }
    }
    for (UIViewController *child in viewController.childViewControllers)
    {
        UIImage *snapshot = CRPosterSnapshotInViewController(child, variant);
        if (snapshot)
        {
            return snapshot;
        }
    }
    return nil;
}

- (void)updateWallpaper
{
    // variant 1 is the home screen, 0 the lock screen
    id presenter = objcInvoke(objcInvoke(objc_getClass("SBWallpaperController"), @"sharedInstance"), @"presenter");
    UIImage *image = nil;
    if ([presenter isKindOfClass:[UIViewController class]])
    {
        image = CRPosterSnapshotInViewController(presenter, 1) ?: CRPosterSnapshotInViewController(presenter, 0);
    }
    CRLog(@"sbmode: wallpaper %@ from %@", image ? NSStringFromCGSize(image.size) : @"none", NSStringFromClass([presenter class]));
    if (image)
    {
        self.wallpaperView.image = image;
        self.sidebarWallpaperView.image = image;
    }
}

/*
The Clock icon's hands tick on a display link of the phone's screen, which stops while that screen is off. Tick them
from the car's screen too
*/
- (void)setClockTicking:(BOOL)ticking
{
    if (ticking == (self.clockDisplayLink != nil))
    {
        return;
    }
    if (!ticking)
    {
        [self.clockDisplayLink invalidate];
        self.clockDisplayLink = nil;
        return;
    }

    Class clockClass = objc_getClass("SBHClockApplicationIconImageView");
    SEL timerFired = NSSelectorFromString(@"_timerFired:");
    UIScreen *carScreen = self.window.screen;
    if (!carScreen || ![clockClass respondsToSelector:timerFired])
    {
        return;
    }
    CADisplayLink *displayLink = [carScreen displayLinkWithTarget:clockClass selector:timerFired];
    displayLink.preferredFramesPerSecond = 4;
    [displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    self.clockDisplayLink = displayLink;
}

- (void)rebuild
{
    if (!_active || !self.window)
    {
        return;
    }
    CGRect appFrame = _appFrame;
    [self exit];
    [self enterWithAppFrame:appFrame];
}

- (void)exit
{
    BOOL wasActive = _active;
    _active = NO;
    [self setClockTicking:NO];
    if (self.window)
    {
        self.window.hidden = YES;
        objcInvoke_1(self.iconManager, @"setDelegate:", nil);
        self.window = nil;
        self.wallpaperView = nil;
        self.sidebarWallpaperWindow.hidden = YES;
        self.sidebarWallpaperWindow = nil;
        self.sidebarWallpaperView = nil;
        self.libraryViewController = nil;
        self.todayViewController = nil;
        self.searchPresenter = nil;
        self.searchPresentable = nil;
        self.scaledView = nil;
        self.homeViewController = nil;
        self.iconManager = nil;
        self.iconModel = nil;
        _carIconModel = nil;
        _carIconManager = nil;
    }
    if (wasActive)
    {
        [self postState];
    }
}

/*
The icon look (light, dark, tinted) reaches icons as traits the phone's home screen gets from SpringBoard. Give the
car's the same, with the phone idiom
*/
- (void)updateIconStyle
{
    UIViewController *homeViewController = self.homeViewController;
    if (!homeViewController.parentViewController)
    {
        return;
    }
    id configuration = nil;
    NSMutableArray *traits = [NSMutableArray arrayWithObject:[UITraitCollection traitCollectionWithUserInterfaceIdiom:UIUserInterfaceIdiomPhone]];
    @try
    {
        configuration = objcInvoke(objcInvoke(objc_getClass("SBIconController"), @"sharedInstance"), @"currentIconImageStyleConfiguration");
        if (configuration && [UITraitCollection respondsToSelector:NSSelectorFromString(@"sbh_traitCollectionWithIconImageStyleConfiguration:")])
        {
            id styleTraitCollection = objcInvoke_1([UITraitCollection class], @"sbh_traitCollectionWithIconImageStyleConfiguration:", configuration);
            if (styleTraitCollection)
            {
                [traits addObject:styleTraitCollection];
            }
        }
    }
    @catch (NSException *exception)
    {
        CRLog(@"sbmode: icon style failed: %@", exception);
    }
    [homeViewController.parentViewController setOverrideTraitCollection:[UITraitCollection traitCollectionWithTraitsFromCollections:traits] forChildViewController:homeViewController];
    // redraw the visible icons for the look, like the icon editor's preview does: icons with no looks of their own
    // (CarPlay's) only get SpringBoard's made-up dark and tinted ones that way
    SEL recache = NSSelectorFromString(@"recacheVisibleIconImageDataForRootIconsInBackgroundWithImageAppearance:cacheOptions:");
    if (configuration && [configuration respondsToSelector:NSSelectorFromString(@"iconImageAppearanceWithUserInterfaceStyle:")] && [_carIconManager respondsToSelector:recache])
    {
        UIUserInterfaceStyle interfaceStyle = homeViewController.traitCollection.userInterfaceStyle;
        id appearance = ((id (*)(id, SEL, long long))objc_msgSend)(configuration, NSSelectorFromString(@"iconImageAppearanceWithUserInterfaceStyle:"), interfaceStyle);
        ((void (*)(id, SEL, id, unsigned long long))objc_msgSend)(_carIconManager, recache, appearance, 0);
    }
    CRLog(@"sbmode: icon style %@", configuration);
}

- (BOOL)isCarIconManager:(id)object
{
    return object && object == _carIconManager;
}

// set up before the icon manager (and its views) are
- (CGFloat)libraryListWidth
{
    return _libraryListWidth;
}

- (BOOL)isCarRootFolder:(id)folder
{
    return folder && _carIconModel && folder == objcInvoke(_carIconModel, @"rootFolder");
}

- (BOOL)rootGridColumns:(NSUInteger *)columns rows:(NSUInteger *)rows forIconModel:(id)object
{
    if (!object || object != _carIconModel || !_rootColumns)
    {
        return NO;
    }
    *columns = _rootColumns;
    *rows = _rootRows;
    return YES;
}

- (NSUInteger)dockIconCountForIconModelOrManager:(id)object
{
    return object && (object == _carIconModel || object == _carIconManager) ? _dockIconCount : 0;
}

#pragma mark - CRIconDrag

/*
Moving icons in edit mode, done here instead of with system drag and drop: hold an icon, drag it over a page or the
dock (hold it at a side edge to flip pages) and let go
*/
- (BOOL)isEditing
{
    return self.iconManager && ((BOOL (*)(id, SEL))objc_msgSend)(self.iconManager, NSSelectorFromString(@"isEditing"));
}

// the lists an icon can be dragged from or dropped on: the dock first (it overlaps the page), then the current page
- (NSArray *)dragListViews
{
    NSMutableArray *listViews = [NSMutableArray array];
    UIView *folderListView = [self openFolderListView];
    if (folderListView)
    {
        [listViews addObject:folderListView];
        return listViews;
    }
    id rootFolderController = objcInvoke(self.iconManager, @"rootFolderController");
    UIView *dockListView = objcInvoke(rootFolderController, @"dockListView");
    UIView *pageListView = objcInvoke(rootFolderController, @"currentIconListView");
    if (dockListView.window)
    {
        [listViews addObject:dockListView];
    }
    if (pageListView.window)
    {
        [listViews addObject:pageListView];
    }
    return listViews;
}

- (UIView *)openFolderListView
{
    if (!((BOOL (*)(id, SEL))objc_msgSend)(self.iconManager, NSSelectorFromString(@"hasOpenFolder")))
    {
        return nil;
    }
    UIView *listView = objcInvoke(objcInvoke(self.iconManager, @"openedFolderController"), @"currentIconListView");
    return listView.window ? listView : nil;
}

- (BOOL)isShowingLibrary
{
    return ((BOOL (*)(id, SEL))objc_msgSend)(self.iconManager, NSSelectorFromString(@"isShowingOrTransitioningToTrailingCustomView"));
}

// an App Library icon under a point
- (UIView *)libraryIconViewAtPoint:(CGPoint)point
{
    UIView *libraryView = [(UIViewController *)self.libraryViewController view];
    if (!libraryView.window || ![self isShowingLibrary])
    {
        return nil;
    }
    UIView *hitView = [libraryView hitTest:[libraryView convertPoint:point fromView:self.scaledView] withEvent:nil];
    for (UIView *view = hitView; view && view != libraryView; view = view.superview)
    {
        if ([view isKindOfClass:objc_getClass("SBIconView")])
        {
            id icon = objcInvoke(view, @"icon");
            // apps only: not the category folders' mini grids
            return [icon respondsToSelector:NSSelectorFromString(@"applicationBundleID")] && [objcInvoke(icon, @"applicationBundleID") length] ? view : nil;
        }
    }
    return nil;
}

// what a drag starting at a point would carry
- (UIView *)dragSourceIconViewAtPoint:(CGPoint)point
{
    if ([self isShowingLibrary])
    {
        return [self libraryIconViewAtPoint:point];
    }
    return [self iconViewAtPoint:point inListView:[self dragListViewAtPoint:point]];
}

- (UIView *)dragListViewAtPoint:(CGPoint)point
{
    for (UIView *listView in [self dragListViews])
    {
        if (CGRectContainsPoint(listView.bounds, [listView convertPoint:point fromView:self.scaledView]))
        {
            return listView;
        }
    }
    return nil;
}

- (UIView *)iconViewAtPoint:(CGPoint)point inListView:(UIView *)listView
{
    if (!listView)
    {
        return nil;
    }
    unsigned long long index = 0;
    CGPoint listPoint = [listView convertPoint:point fromView:self.scaledView];
    id icon = ((id (*)(id, SEL, CGPoint, unsigned long long *))objc_msgSend)(listView, NSSelectorFromString(@"iconAtPoint:index:"), listPoint, &index);
    UIView *iconView = icon ? objcInvoke_1(listView, @"iconViewForIcon:", icon) : nil;
    return iconView && CGRectContainsPoint(iconView.bounds, [iconView convertPoint:point fromView:self.scaledView]) ? iconView : nil;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer
{
    if (gestureRecognizer != _dragGesture && ((BOOL (*)(id, SEL))objc_msgSend)(self.iconManager, NSSelectorFromString(@"hasOpenFolder")))
    {
        return NO;
    }
    if (gestureRecognizer == _closeEditorSwipe)
    {
        return ((BOOL (*)(id, SEL))objc_msgSend)(self.iconManager, NSSelectorFromString(@"isIconStylePickerVisible")) || [self addSheetIsPresented];
    }
    CGPoint point = [gestureRecognizer locationInView:self.scaledView];
    if (gestureRecognizer == _endEditGesture)
    {
        // not on an icon (or its delete button) or a button like Done
        UIView *hitView = [self.scaledView hitTest:point withEvent:nil];
        for (UIView *view = hitView; view && view != self.scaledView; view = view.superview)
        {
            if ([view isKindOfClass:objc_getClass("SBIconView")] || [view isKindOfClass:[UIControl class]])
            {
                return NO;
            }
        }
        return [self isEditing];
    }
    if (gestureRecognizer == _editGesture)
    {
        return ![self isEditing] && ![self isShowingLibrary] && ![self iconViewAtPoint:point inListView:[self dragListViewAtPoint:point]];
    }
    UIView *iconView = [self dragSourceIconViewAtPoint:point];
    return iconView != nil;
}

// in edit mode a hold on an icon is a drag: page swipes, the icon's menu and its own lift wait until it can't be one
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer
{
    return gestureRecognizer == _dragGesture && [self isEditing] && ([otherGestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]] || [otherGestureRecognizer isKindOfClass:[UILongPressGestureRecognizer class]]);
}

// outside edit mode the icon's menu opens as usual, the drag only watches for the finger moving off
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer
{
    if (gestureRecognizer == _closeEditorSwipe)
    {
        return YES;
    }
    return gestureRecognizer != _editGesture && ![self isEditing];
}

- (BOOL)addSheetIsPresented
{
    UIViewController *sheet = objcInvoke(objcInvoke(self.iconManager, @"rootFolderController"), @"addSheetViewController");
    return sheet.presentingViewController != nil;
}

- (BOOL)closeAddSheet
{
    if (![self addSheetIsPresented])
    {
        return NO;
    }
    id rootFolderController = objcInvoke(self.iconManager, @"rootFolderController");
    return ((BOOL (*)(id, SEL, BOOL))objc_msgSend)(rootFolderController, NSSelectorFromString(@"dismissWidgetAddSheetIfPresentedAndClearAnimated:"), YES);
}

- (void)handleCloseEditorSwipe:(UISwipeGestureRecognizer *)gesture
{
    if ([self closeAddSheet])
    {
        CRLog(@"sbmode: closed the add widget sheet");
        return;
    }
    id picker = objcInvoke(self.iconManager, @"currentStylePickerViewController");
    CRLog(@"sbmode: closing the icon editor %@", picker);
    if (picker)
    {
        objcInvoke_1(self.iconManager, @"stylePickerViewControllerDidFinish:", picker);
        // finishing saves the look but leaves the editor up here: put it away like a swipe on its sheet would
        UIViewController *sheet = [(UIViewController *)picker navigationController] ?: picker;
        id manager = self.iconManager;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            CRLog(@"sbmode: icon editor still presented %d visible %d", sheet.presentingViewController != nil, ((BOOL (*)(id, SEL))objc_msgSend)(manager, NSSelectorFromString(@"isIconStylePickerVisible")));
            void (^cleanUp)(void) = ^{
                ((void (*)(id, SEL, BOOL))objc_msgSend)(manager, NSSelectorFromString(@"setIconStylePickerVisible:"), NO);
                if (objcInvoke(manager, @"currentStylePickerViewController") == picker)
                {
                    objcInvoke_1(manager, @"setCurrentStylePickerViewController:", nil);
                }
            };
            if (sheet.presentingViewController)
            {
                [sheet.presentingViewController dismissViewControllerAnimated:YES completion:cleanUp];
            }
            else
            {
                cleanUp();
            }
        });
    }
}

- (void)handleEndEditTap:(UITapGestureRecognizer *)gesture
{
    if (gesture.state == UIGestureRecognizerStateEnded && [self isEditing] && !_dragIcon)
    {
        objcInvoke_1(self.iconManager, @"setEditing:", NO);
    }
}

- (void)handleEditHold:(UILongPressGestureRecognizer *)gesture
{
    if (gesture.state == UIGestureRecognizerStateBegan && ![self isEditing])
    {
        objcInvoke_1(self.iconManager, @"setEditing:", YES);
    }
}

/*
What follows the finger: an icon view of its own, so its label shadow, folder backdrop and delete button draw like the
real one's (a snapshot crops to the icon and loses them). A snapshot if one can't be had
*/
- (UIView *)dragViewForIconView:(UIView *)iconView
{
    UIView *dragView = nil;
    @try
    {
        Class iconViewClass = [self isShowingLibrary] ? objc_getClass("SBIconView") : [iconView class];
        dragView = objcInvoke_1(self.iconManager, @"dequeueReusableIconViewOfClass:", iconViewClass);
        if (dragView)
        {
            objcInvoke_1(dragView, @"setListLayoutProvider:", objcInvoke(iconView, @"listLayoutProvider"));
            struct CRIconImageInfo imageInfo = ((struct CRIconImageInfo (*)(id, SEL))objc_msgSend)(iconView, NSSelectorFromString(@"iconImageInfo"));
            ((void (*)(id, SEL, struct CRIconImageInfo))objc_msgSend)(dragView, NSSelectorFromString(@"setIconImageInfo:"), imageInfo);
            objcInvoke_1(dragView, @"setLocation:", objcInvoke(iconView, @"location"));
            objcInvoke_1(dragView, @"setLegibilitySettings:", objcInvoke(iconView, @"legibilitySettings"));
            objcInvoke_1(dragView, @"setIcon:", objcInvoke(iconView, @"icon"));
            ((void (*)(id, SEL, BOOL))objc_msgSend)(dragView, NSSelectorFromString(@"setEditing:"), YES);
            ((void (*)(id, SEL, BOOL))objc_msgSend)(dragView, NSSelectorFromString(@"setAllowsEditingAnimation:"), NO);
            dragView.alpha = 1;
            dragView.hidden = NO;
            dragView.transform = CGAffineTransformIdentity;
        }
    }
    @catch (NSException *exception)
    {
        CRLog(@"sbmode: drag view failed: %@", exception);
        dragView = nil;
    }
    return dragView ?: [iconView snapshotViewAfterScreenUpdates:NO];
}

- (void)liftIconView:(UIView *)iconView atPoint:(CGPoint)point
{
    id icon = objcInvoke(iconView, @"icon");
    UIView *snapshot = [self dragViewForIconView:iconView];
    snapshot.bounds = iconView.bounds;
    CGPoint center = [iconView convertPoint:CGPointMake(CGRectGetMidX(iconView.bounds), CGRectGetMidY(iconView.bounds)) toView:self.scaledView];
    snapshot.center = center;
    snapshot.userInteractionEnabled = NO;
    // on top in the home screen's view (it fills scaledView, open folders and the library are inside it), where icons
    // get the phone's icon look
    [self.homeViewController.view ?: self.scaledView addSubview:snapshot];
    _dragFromLibrary = [self isShowingLibrary];
    if (_dragFromLibrary)
    {
        // back to the last page to drop it on
        id rootFolderController = objcInvoke(self.iconManager, @"rootFolderController");
        long long lastPage = ((long long (*)(id, SEL))objc_msgSend)(rootFolderController, NSSelectorFromString(@"lastIconPageIndex"));
        ((BOOL (*)(id, SEL, long long, BOOL))objc_msgSend)(rootFolderController, NSSelectorFromString(@"setCurrentPageIndex:animated:"), lastPage, YES);
    }
    _dragSnapshot = [snapshot retain];
    _dragIcon = [icon retain];
    _dragOffset = CGPointMake(snapshot.center.x - point.x, snapshot.center.y - point.y);
    _dragEdgeSince = 0;
    // a library icon stays in the library; one on a page hides while it's carried (from the library too, once a move
    // finds its view)
    if (!_dragFromLibrary)
    {
        _dragIconView = [iconView retain];
        iconView.alpha = 0;
    }
    [UIView animateWithDuration:0.15 animations:^{
        snapshot.transform = CGAffineTransformMakeScale(1.15, 1.15);
        snapshot.alpha = 0.9;
    }];
    [[[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] autorelease] impactOccurred];
    CRLog(@"sbmode: dragging %@", _dragIcon);
}

- (void)handleIconDrag:(UILongPressGestureRecognizer *)gesture
{
    CGPoint point = [gesture locationInView:self.scaledView];
    switch (gesture.state)
    {
        case UIGestureRecognizerStateBegan:
        {
            UIView *iconView = [self dragSourceIconViewAtPoint:point];
            if (!objcInvoke(iconView, @"icon"))
            {
                gesture.enabled = NO;
                gesture.enabled = YES;
                return;
            }
            if ([self isEditing])
            {
                [self liftIconView:iconView atPoint:point];
            }
            else
            {
                [_pendingDragIconView release];
                _pendingDragIconView = [iconView retain];
                _pendingDragStart = point;
            }
            break;
        }
        case UIGestureRecognizerStateChanged:
        {
            // moved off an icon whose menu is up: drop the menu, start edit mode and carry the icon
            if (_pendingDragIconView && hypot(point.x - _pendingDragStart.x, point.y - _pendingDragStart.y) > 15)
            {
                UIView *iconView = [_pendingDragIconView autorelease];
                _pendingDragIconView = nil;
                if ([iconView respondsToSelector:NSSelectorFromString(@"dismissContextMenuWithCompletion:")])
                {
                    objcInvoke_1(iconView, @"dismissContextMenuWithCompletion:", nil);
                }
                objcInvoke_1(self.iconManager, @"setEditing:", YES);
                [self liftIconView:iconView atPoint:point];
            }
            if (_dragIcon)
            {
                UIView *folderListView = [self openFolderListView];
                if (folderListView && !CGRectContainsPoint(CGRectInset([folderListView convertRect:folderListView.bounds toView:self.scaledView], -30, -30), point))
                {
                    CRLog(@"sbmode: dragged out of the folder");
                    ((void (*)(id, SEL, BOOL, id))objc_msgSend)(self.iconManager, NSSelectorFromString(@"closeFolderAnimated:withCompletion:"), YES, nil);
                }
                _dragSnapshot.center = CGPointMake(point.x + _dragOffset.x, point.y + _dragOffset.y);
                [self flipPageIfHeldAtEdge:point];
                [self hoverDraggedIconAtPoint:point];
            }
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
        {
            [_pendingDragIconView release];
            _pendingDragIconView = nil;
            if (_dragIcon)
            {
                [self dropDraggedIconAtPoint:point cancelled:gesture.state != UIGestureRecognizerStateEnded];
                [self saveCustomIconPositions];
            }
            break;
        }
        default:
            break;
    }
}

// held within reach of a side edge for a moment: the page before or after
- (void)flipPageIfHeldAtEdge:(CGPoint)point
{
    id rootFolderController = objcInvoke(self.iconManager, @"rootFolderController");
    CGFloat width = self.scaledView.bounds.size.width;
    BOOL overDock = [self dragListViewAtPoint:point] == objcInvoke(rootFolderController, @"dockListView");
    int direction = overDock ? 0 : point.x < 60 ? -1 : point.x > width - 60 ? 1 : 0;
    if (!direction)
    {
        _dragEdgeSince = 0;
        return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    if (!_dragEdgeSince)
    {
        _dragEdgeSince = now;
        return;
    }
    if (now - _dragEdgeSince < 0.6)
    {
        return;
    }
    _dragEdgeSince = now;
    long long page = ((long long (*)(id, SEL))objc_msgSend)(rootFolderController, NSSelectorFromString(@"currentPageIndex")) + direction;
    long long firstPage = ((long long (*)(id, SEL))objc_msgSend)(rootFolderController, NSSelectorFromString(@"firstIconPageIndex"));
    long long lastPage = ((long long (*)(id, SEL))objc_msgSend)(rootFolderController, NSSelectorFromString(@"lastIconPageIndex"));
    if (page >= firstPage && page <= lastPage)
    {
        ((BOOL (*)(id, SEL, long long, BOOL))objc_msgSend)(rootFolderController, NSSelectorFromString(@"setCurrentPageIndex:animated:"), page, YES);
    }
}

typedef struct
{
    long long column;
    long long row;
} CRIconCoordinate;

// the page or dock list holding an icon
static id CRListContainingIcon(id rootFolder, id icon)
{
    id dock = objcInvoke(rootFolder, @"dock");
    if ([objcInvoke(dock, @"icons") containsObject:icon])
    {
        return dock;
    }
    for (id list in objcInvoke(rootFolder, @"lists"))
    {
        if ([objcInvoke(list, @"icons") containsObject:icon])
        {
            return list;
        }
    }
    // inside a folder on a page or in the dock
    NSMutableArray *lists = [NSMutableArray arrayWithArray:objcInvoke(rootFolder, @"lists") ?: @[]];
    if (dock)
    {
        [lists addObject:dock];
    }
    for (id list in lists)
    {
        for (id child in objcInvoke(list, @"icons"))
        {
            if (!CRIconIsKind(child, @"isFolderIcon"))
            {
                continue;
            }
            for (id folderList in objcInvoke(objcInvoke(child, @"folder"), @"lists"))
            {
                if ([objcInvoke(folderList, @"icons") containsObject:icon])
                {
                    return folderList;
                }
            }
        }
    }
    return nil;
}

// home screen pages place icons by grid cell (gaps allowed); the dock goes by order
static unsigned long long CRGridOptions(UIView *listView)
{
    return ((unsigned long long (*)(id, SEL))objc_msgSend)(listView, NSSelectorFromString(@"gridCellInfoOptions"));
}

static BOOL CRListUsesGridCells(id list)
{
    SEL allows = NSSelectorFromString(@"allowsFixedIconLocations");
    return [list respondsToSelector:allows] && ((BOOL (*)(id, SEL))objc_msgSend)(list, allows);
}

static BOOL CRIconIsKind(id icon, NSString *selectorName)
{
    SEL selector = NSSelectorFromString(selectorName);
    return [icon respondsToSelector:selector] && ((BOOL (*)(id, SEL))objc_msgSend)(icon, selector);
}

// an app (not a folder or widget) dragged over an app or folder makes or fills a folder
static BOOL CRCanMakeFolder(id draggedIcon, id targetIcon)
{
    if (!targetIcon || targetIcon == draggedIcon || CRIconIsKind(draggedIcon, @"isFolderIcon") || CRIconIsKind(draggedIcon, @"isWidgetIcon") || CRIconIsKind(targetIcon, @"isWidgetIcon"))
    {
        return NO;
    }
    if (CRIconIsKind(targetIcon, @"isFolderIcon"))
    {
        return !((BOOL (*)(id, SEL))objc_msgSend)(objcInvoke(targetIcon, @"folder"), NSSelectorFromString(@"isFull"));
    }
    return [objcInvoke(targetIcon, @"applicationBundleID") length] > 0 && ![objcInvoke(targetIcon, @"applicationBundleID") isEqualToString:kCRDashBoardBundleID];
}

// a widget dropped on a widget of its size makes or adds to a stack
static BOOL CRCanStackWidget(id draggedIcon, id targetIcon)
{
    if (!targetIcon || targetIcon == draggedIcon || !CRIconIsKind(draggedIcon, @"isWidgetIcon") || !CRIconIsKind(targetIcon, @"isWidgetIcon"))
    {
        return NO;
    }
    SEL sizeClass = NSSelectorFromString(@"gridSizeClass");
    id draggedSize = [draggedIcon respondsToSelector:sizeClass] ? objcInvoke(draggedIcon, @"gridSizeClass") : nil;
    id targetSize = [targetIcon respondsToSelector:sizeClass] ? objcInvoke(targetIcon, @"gridSizeClass") : nil;
    return draggedSize && [draggedSize isEqual:targetSize] && [targetIcon respondsToSelector:NSSelectorFromString(@"addDataSourcesFromWidgetIcons:")];
}

- (void)setFolderTargetView:(UIView *)targetView
{
    if (targetView == _folderTargetView)
    {
        return;
    }
    UIView *previous = _folderTargetView;
    [UIView animateWithDuration:0.2 animations:^{
        previous.transform = CGAffineTransformIdentity;
        CGFloat grow = CRIconIsKind(objcInvoke(targetView, @"icon"), @"isWidgetIcon") ? 1.06 : 1.2;
        targetView.transform = CGAffineTransformMakeScale(grow, grow);
    }];
    [_folderTargetView release];
    _folderTargetView = [targetView retain];
}

// where the dragged icon would go at a point: a list and an index in it
- (BOOL)insertionAtPoint:(CGPoint)point listView:(UIView **)listViewOut index:(unsigned long long *)indexOut
{
    UIView *listView = [self dragListViewAtPoint:point];
    id list = objcInvoke(listView, @"model");
    if (!list)
    {
        return NO;
    }
    CGPoint listPoint = [listView convertPoint:point fromView:self.scaledView];
    if (CRListUsesGridCells(list))
    {
        // the cell under the dragged icon's top left icon spot (a widget's first cell, an app's only one)
        CGRect frame = [listView convertRect:_dragSnapshot.frame fromView:_dragSnapshot.superview];
        CGPoint cellPoint = CGPointMake(CGRectGetMinX(frame) + kCRIconWidth / 2 + 4, CGRectGetMinY(frame) + kCRIconWidth / 2 + 4);
        CRIconCoordinate cell = ((CRIconCoordinate (*)(id, SEL, CGPoint))objc_msgSend)(listView, NSSelectorFromString(@"coordinateAtPoint:"), cellPoint);
        *indexOut = ((unsigned long long (*)(id, SEL, CRIconCoordinate, unsigned long long))objc_msgSend)(list, NSSelectorFromString(@"gridCellIndexForCoordinate:gridCellInfoOptions:"), cell, CRGridOptions(listView));
        *listViewOut = listView;
        return *indexOut != NSNotFound;
    }
    CRIconCoordinate coordinate = ((CRIconCoordinate (*)(id, SEL, CGPoint))objc_msgSend)(listView, NSSelectorFromString(@"coordinateAtPoint:"), listPoint);
    unsigned long long index = ((unsigned long long (*)(id, SEL, id, CRIconCoordinate))objc_msgSend)(listView, NSSelectorFromString(@"bestIndexForInsertingIcon:atCoordinate:"), _dragIcon, coordinate);
    unsigned long long count = [objcInvoke(list, @"icons") count];
    BOOL inList = [objcInvoke(list, @"icons") containsObject:_dragIcon];
    *indexOut = MIN(index, inList ? count - 1 : count);
    *listViewOut = listView;
    return YES;
}

// moves the dragged icon to a list and index, the icons around it sliding aside
- (BOOL)moveDraggedIconToListView:(UIView *)targetListView index:(unsigned long long)index
{
    id rootFolder = objcInvoke(self.iconManager, @"rootFolder");
    id targetList = objcInvoke(targetListView, @"model");
    id sourceList = CRListContainingIcon(rootFolder, _dragIcon);
    if (!targetList || (!sourceList && !_dragFromLibrary))
    {
        return NO;
    }
    if (CRListUsesGridCells(targetList))
    {
        return [self moveDraggedIconToGridCell:index ofListView:targetListView fromList:sourceList];
    }
    if (!sourceList)
    {
        return NO;
    }
    NSUInteger sourceIndex = [objcInvoke(sourceList, @"icons") indexOfObject:_dragIcon];
    if (targetList == sourceList && sourceIndex == index)
    {
        return NO;
    }
    if (targetList != sourceList && ((BOOL (*)(id, SEL))objc_msgSend)(targetList, NSSelectorFromString(@"isFull")))
    {
        return NO;
    }

    BOOL moved = NO;
    @try
    {
        objcInvoke_1(sourceList, @"removeIcon:", _dragIcon);
        index = MIN(index, (unsigned long long)[objcInvoke(targetList, @"icons") count]);
        ((id (*)(id, SEL, id, unsigned long long, unsigned long long))objc_msgSend)(targetList, NSSelectorFromString(@"insertIcon:atIndex:options:"), _dragIcon, index, 0);
        moved = [objcInvoke(targetList, @"icons") containsObject:_dragIcon];
    }
    @catch (NSException *exception)
    {
        CRLog(@"sbmode: move failed: %@", exception);
    }
    if (!moved && !CRListContainingIcon(rootFolder, _dragIcon))
    {
        ((id (*)(id, SEL, id, unsigned long long, unsigned long long))objc_msgSend)(sourceList, NSSelectorFromString(@"insertIcon:atIndex:options:"), _dragIcon, MIN((unsigned long long)sourceIndex, (unsigned long long)[objcInvoke(sourceList, @"icons") count]), 0);
    }

    // the icon's view (a new one if it changed lists) stays hidden under the finger
    // SpringBoard's own slide (animation type 1, the default one)
    for (UIView *listView in [self dragListViews])
    {
        ((void (*)(id, SEL, long long, unsigned long long))objc_msgSend)(listView, NSSelectorFromString(@"layoutIconsIfNeededWithAnimationType:options:"), 1, 0);
    }
    UIView *iconView = objcInvoke_1(targetListView, @"iconViewForIcon:", _dragIcon);
    if (iconView && iconView != _dragIconView)
    {
        _dragIconView.alpha = 1;
        [_dragIconView release];
        _dragIconView = [iconView retain];
    }
    _dragIconView.alpha = 0;
    return moved;
}

- (void)relayoutDragListsKeepingDragIconHidden:(UIView *)targetListView
{
    for (UIView *listView in [self dragListViews])
    {
        objcInvoke(listView, @"setIconsNeedLayout");
        ((void (*)(id, SEL, long long, unsigned long long))objc_msgSend)(listView, NSSelectorFromString(@"layoutIconsIfNeededWithAnimationType:options:"), 1, 0);
    }
    UIView *iconView = objcInvoke_1(targetListView, @"iconViewForIcon:", _dragIcon);
    if (iconView && iconView != _dragIconView)
    {
        _dragIconView.alpha = 1;
        [_dragIconView release];
        _dragIconView = [iconView retain];
    }
    _dragIconView.alpha = 0;
}

// to a grid cell: an empty one keeps it there, a taken one pushes the icons there along
- (BOOL)moveDraggedIconToGridCell:(unsigned long long)cell ofListView:(UIView *)targetListView fromList:(id)sourceList
{
    id targetList = objcInvoke(targetListView, @"model");
    unsigned long long options = CRGridOptions(targetListView);
    SEL cellOfIcon = NSSelectorFromString(@"gridCellIndexForIcon:gridCellInfoOptions:");
    if (targetList == sourceList && ((unsigned long long (*)(id, SEL, id, unsigned long long))objc_msgSend)(targetList, cellOfIcon, _dragIcon, options) == cell)
    {
        return NO;
    }
    id occupant = ((id (*)(id, SEL, unsigned long long, unsigned long long))objc_msgSend)(targetList, NSSelectorFromString(@"iconAtGridCellIndex:gridCellInfoOptions:"), cell, options);
    BOOL moved = NO;
    @try
    {
        if (targetList != sourceList)
        {
            if (((BOOL (*)(id, SEL))objc_msgSend)(targetList, NSSelectorFromString(@"isFull")))
            {
                return NO;
            }
            if (sourceList)
            {
                objcInvoke_1(sourceList, @"removeIcon:", _dragIcon);
            }
            ((id (*)(id, SEL, id, unsigned long long, unsigned long long, unsigned long long))objc_msgSend)(targetList, NSSelectorFromString(@"insertIcon:atGridCellIndex:gridCellInfoOptions:mutationOptions:"), _dragIcon, cell, options, 0);
        }
        if (!occupant || occupant == _dragIcon)
        {
            ((void (*)(id, SEL, unsigned long long, id, unsigned long long))objc_msgSend)(targetList, NSSelectorFromString(@"setFixedLocation:forIcon:options:"), cell, _dragIcon, options);
        }
        ((id (*)(id, SEL, id, unsigned long long, unsigned long long, unsigned long long))objc_msgSend)(targetList, NSSelectorFromString(@"moveContainedIcon:toGridCellIndex:gridCellInfoOptions:mutationOptions:"), _dragIcon, cell, options, 0);
        moved = [objcInvoke(targetList, @"icons") containsObject:_dragIcon];
        CRLog(@"sbmode: to cell %llu (%@): now %llu", cell, occupant ? objcInvoke(occupant, @"displayName") : @"empty", ((unsigned long long (*)(id, SEL, id, unsigned long long))objc_msgSend)(targetList, cellOfIcon, _dragIcon, options));
    }
    @catch (NSException *exception)
    {
        CRLog(@"sbmode: cell move failed: %@", exception);
    }
    if (!moved && sourceList && !CRListContainingIcon(objcInvoke(self.iconManager, @"rootFolder"), _dragIcon))
    {
        objcInvoke_1(sourceList, @"addIcon:", _dragIcon);
    }
    [self relayoutDragListsKeepingDragIconHidden:targetListView];
    return moved;
}

// while dragging: over the middle of an app or folder for a moment it's a folder drop, elsewhere the icon makes room
- (void)hoverDraggedIconAtPoint:(CGPoint)point
{
    CFTimeInterval now = CACurrentMediaTime();
    // a raised folder target stays one until the finger leaves it
    if (_folderTargetView && CGRectContainsPoint(_folderTargetView.bounds, [_folderTargetView convertPoint:point fromView:self.scaledView]))
    {
        return;
    }
    UIView *listView = [self dragListViewAtPoint:point];
    UIView *targetView = [self iconViewAtPoint:point inListView:listView];
    id targetIcon = objcInvoke(targetView, @"icon");
    BOOL overOtherIcon = targetView && targetIcon != _dragIcon;
    BOOL overMiddle = NO;
    if (overOtherIcon && (CRCanMakeFolder(_dragIcon, targetIcon) || CRCanStackWidget(_dragIcon, targetIcon)))
    {
        CGRect middle = CGRectInset(targetView.bounds, targetView.bounds.size.width * 0.15, targetView.bounds.size.height * 0.15);
        overMiddle = CGRectContainsPoint(middle, [targetView convertPoint:point fromView:self.scaledView]);
    }
    if (overMiddle)
    {
        if (targetView != _folderCandidateView)
        {
            [_folderCandidateView release];
            _folderCandidateView = [targetView retain];
            _folderCandidateSince = now;
        }
        else if (now - _folderCandidateSince > 0.35)
        {
            [self setFolderTargetView:targetView];
        }
        return;
    }
    [_folderCandidateView release];
    _folderCandidateView = nil;
    [self setFolderTargetView:nil];

    UIView *insertionListView = nil;
    unsigned long long index = 0;
    if (![self insertionAtPoint:point listView:&insertionListView index:&index])
    {
        return;
    }
    // settle on a spot briefly before shuffling icons around
    if (insertionListView != _hoverListView || index != _hoverIndex)
    {
        _hoverListView = insertionListView;
        _hoverIndex = index;
        _hoverSince = now;
        return;
    }
    // over another icon's edge it takes a longer pause to push it aside, so passing over on the way to a folder doesn't
    if (_hoverSince && now - _hoverSince > (overOtherIcon ? 0.4 : 0.12))
    {
        _hoverSince = 0;
        [self moveDraggedIconToListView:insertionListView index:index];
    }
}

- (UIView *)folderFromDraggedIconOnto:(UIView *)targetView
{
    id icon = _dragIcon;
    id targetIcon = objcInvoke(targetView, @"icon");
    id rootFolder = objcInvoke(self.iconManager, @"rootFolder");
    id sourceList = CRListContainingIcon(rootFolder, icon);
    id targetList = CRListContainingIcon(rootFolder, targetIcon);
    CRLog(@"sbmode: folder drop of %@ onto %@ (lists %@ %@)", objcInvoke(icon, @"displayName"), objcInvoke(targetIcon, @"displayName"), sourceList ? @"found" : @"none", targetList ? @"found" : @"none");
    if (!sourceList || !targetList)
    {
        return nil;
    }
    @try
    {
        if (CRCanStackWidget(icon, targetIcon))
        {
            objcInvoke_1(sourceList, @"removeIcon:", icon);
            objcInvoke_1(targetIcon, @"addDataSourcesFromWidgetIcons:", @[icon]);
            ((void (*)(id, SEL))objc_msgSend)(self.iconModel, NSSelectorFromString(@"saveIconStateIfNeeded"));
            CRLog(@"sbmode: stacked %@ onto %@ (%lu widgets)", icon, targetIcon, (unsigned long)[objcInvoke(targetIcon, @"widgets") count]);
            return targetView;
        }
        if (CRIconIsKind(targetIcon, @"isFolderIcon"))
        {
            objcInvoke_1(sourceList, @"removeIcon:", icon);
            objcInvoke_1(objcInvoke(targetIcon, @"folder"), @"addIcon:", icon);
            CRLog(@"sbmode: added %@ to folder %@", objcInvoke(icon, @"displayName"), objcInvoke(targetIcon, @"displayName"));
            return targetView;
        }
        id iconController = objcInvoke(objc_getClass("SBIconController"), @"sharedInstance");
        NSString *name = [iconController respondsToSelector:NSSelectorFromString(@"folderNameForDisplayID:")] ? objcInvoke_1(iconController, @"folderNameForDisplayID:", objcInvoke(targetIcon, @"applicationBundleID")) : nil;
        if (!name.length)
        {
            name = objcInvoke(self.iconManager, @"localizedDefaultFolderName") ?: @"Folder";
        }
        id folder = objcInvoke_1(self.iconModel, @"makeFolderWithDisplayName:", name);
        id folderIcon = objcInvoke(folder, @"icon");
        if (!folderIcon && folder)
        {
            folderIcon = [objcInvoke_1([objc_getClass("SBFolderIcon") alloc], @"initWithFolder:", folder) autorelease];
        }
        CRLog(@"sbmode: new folder %@ icon %@", folder, folderIcon);
        if (!folderIcon)
        {
            return nil;
        }
        objcInvoke_1(sourceList, @"removeIcon:", icon);
        ((id (*)(id, SEL, id, id, unsigned long long))objc_msgSend)(targetList, NSSelectorFromString(@"replaceIcon:withIcon:options:"), targetIcon, folderIcon, 0);
        objcInvoke_1(folder, @"addIcon:", targetIcon);
        objcInvoke_1(folder, @"addIcon:", icon);
        objcInvoke_1(self.iconModel, @"addIcon:", folderIcon);
        CRLog(@"sbmode: made folder %@ of %@ and %@", name, objcInvoke(targetIcon, @"displayName"), objcInvoke(icon, @"displayName"));
        [self.scaledView layoutIfNeeded];
        for (UIView *listView in [self dragListViews])
        {
            UIView *folderView = objcInvoke_1(listView, @"iconViewForIcon:", folderIcon);
            if (folderView.window)
            {
                return folderView;
            }
        }
    }
    @catch (NSException *exception)
    {
        CRLog(@"sbmode: folder failed: %@", exception);
        if (!CRListContainingIcon(rootFolder, icon) && ![objcInvoke(objcInvoke(targetIcon, @"folder"), @"icons") containsObject:icon])
        {
            objcInvoke_1(sourceList, @"addIcon:", icon);
        }
    }
    return nil;
}

- (void)dropDraggedIconAtPoint:(CGPoint)point cancelled:(BOOL)cancelled
{
    id icon = _dragIcon;
    UIView *landingView = nil;
    BOOL changed = YES;
    CRLog(@"sbmode: drop %@ folder target %@", cancelled ? @"cancelled" : @"ended", objcInvoke(objcInvoke(_folderTargetView, @"icon"), @"displayName"));
    if (!cancelled && _folderTargetView)
    {
        landingView = [self folderFromDraggedIconOnto:_folderTargetView];
    }
    else if (!cancelled)
    {
        UIView *listView = nil;
        unsigned long long index = 0;
        if ([self insertionAtPoint:point listView:&listView index:&index])
        {
            [self moveDraggedIconToListView:listView index:index];
        }
    }
    [self setFolderTargetView:nil];
    [_folderCandidateView release];
    _folderCandidateView = nil;
    _hoverListView = nil;

    UIView *snapshot = _dragSnapshot;
    UIView *iconView = _dragIconView;
    [self.scaledView layoutIfNeeded];
    // fly to where the icon ended up
    if (!landingView)
    {
        for (UIView *listView in [self dragListViews])
        {
            UIView *candidate = objcInvoke_1(listView, @"iconViewForIcon:", icon);
            if (candidate.window)
            {
                landingView = candidate;
                break;
            }
        }
    }
    landingView = landingView ?: (iconView.window ? iconView : nil);
    BOOL intoFolder = landingView && objcInvoke(landingView, @"icon") != icon;
    if (!intoFolder)
    {
        landingView.alpha = 0;
    }
    [UIView animateWithDuration:0.2 animations:^{
        snapshot.transform = intoFolder ? CGAffineTransformMakeScale(0.3, 0.3) : CGAffineTransformIdentity;
        if (landingView)
        {
            snapshot.alpha = intoFolder ? 0 : 1;
            snapshot.center = [landingView convertPoint:CGPointMake(CGRectGetMidX(landingView.bounds), CGRectGetMidY(landingView.bounds)) toView:self.scaledView];
        }
        else
        {
            snapshot.alpha = 0;
        }
    } completion:^(BOOL finished) {
        landingView.alpha = 1;
        iconView.alpha = 1;
        [snapshot removeFromSuperview];
        if ([snapshot isKindOfClass:objc_getClass("SBIconView")])
        {
            objcInvoke_1(self.iconManager, @"recycleIconView:", snapshot);
        }
    }];

    [_dragSnapshot release];
    _dragSnapshot = nil;
    [_dragIconView release];
    _dragIconView = nil;
    [_dragIcon release];
    _dragIcon = nil;
    _dragFromLibrary = NO;
    if (changed)
    {
        ((void (*)(id, SEL))objc_msgSend)(self.iconModel, NSSelectorFromString(@"saveIconStateIfNeeded"));
    }
}

#pragma mark - SBHIconManagerDelegate

- (long long)interfaceOrientationForIconManager:(id)manager
{
    return UIInterfaceOrientationLandscapeRight;
}

- (unsigned long long)possibleInterfaceOrientationsForIconManager:(id)manager
{
    return UIInterfaceOrientationMaskLandscape;
}

// the car screen is landscape: lay pages out 6 wide
- (BOOL)listsAllowRotatedLayoutForIconManager:(id)manager
{
    return YES;
}

- (void)iconManager:(id)manager willUseRootFolderControllerConfiguration:(id)configuration
{
    objcInvoke_1(configuration, @"setOrientation:", (long long)UIInterfaceOrientationLandscapeRight);
    objcInvoke_1(configuration, @"setAllowedOrientations:", (unsigned long long)UIInterfaceOrientationMaskLandscape);
    // the phone only shows the Edit button (add widgets, customize, edit pages) in portrait
    objcInvoke_1(configuration, @"setShowsAddWidgetButtonWhileEditingAllowedOrientations:", (unsigned long long)UIInterfaceOrientationMaskAll);
    // the root folder only takes its trailing page (the App Library) when it's made
    if (!self.libraryViewController)
    {
        [self addLibraryToIconManager:manager iconController:objcInvoke(objc_getClass("SBIconController"), @"sharedInstance")];
    }
    if (self.libraryViewController)
    {
        objcInvoke_1(configuration, @"setTrailingCustomViewController:", self.libraryViewController);
    }
    if (!self.todayViewController)
    {
        [self addTodayViewToIconManager:manager];
    }
    if (self.todayViewController)
    {
        objcInvoke_1(configuration, @"setLeadingCustomViewController:", self.todayViewController);
    }
    [self addSearchToConfiguration:configuration];
}

- (unsigned long long)allowedInterfaceOrientationsForIconManager:(id)manager
{
    return UIInterfaceOrientationMaskLandscape;
}

- (NSArray *)libraryViewControllersForIconManager:(id)manager
{
    return self.libraryViewController ? @[self.libraryViewController] : @[];
}

- (BOOL)iconManagerCanSaveIconState:(id)manager
{
    return YES;
}

// system drags never get past the lift on the car screen (its drag service only follows the phone's), see CRIconDrag
- (BOOL)iconManagerCanBeginIconDrags:(id)manager
{
    return NO;
}

- (BOOL)iconManager:(id)manager canBeginDragForIconView:(id)iconView
{
    return NO;
}

- (BOOL)isEditingAllowedForIconManager:(id)manager
{
    return YES;
}

- (BOOL)iconManager:(id)manager isEditingAllowedForIconView:(id)iconView
{
    return YES;
}

- (BOOL)iconManager:(id)manager allowsBadgingForIcon:(id)icon
{
    return YES;
}

// widgets keep showing while the phone is locked, like CarPlay's own and StandBy's
- (BOOL)iconManagerWidgetsCanAppearInSecureEnvironment:(id)manager
{
    return YES;
}

// the icon look is the phone's (it's one setting for both), so Customize edits the phone's
/*
The add-widget sheet is presented over the whole window, outside the scaled home screen. Lay it out phone-wide and as
tall as the home screen's space, then scale it down the same way: a card in the middle of the car screen
*/
- (void)iconManager:(id)manager prepareAddSheetViewController:(UIViewController *)sheet
{
    // landscape makes it compact height, which shrinks its search field into a corner of a tall header
    if ([sheet respondsToSelector:NSSelectorFromString(@"traitOverrides")])
    {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(objcInvoke(sheet, @"traitOverrides"), NSSelectorFromString(@"setVerticalSizeClass:"), UIUserInterfaceSizeClassRegular);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self scalePresentedSheet:sheet];
    });
}

static void CRRelayoutViews(UIView *view)
{
    if (!view)
    {
        return;
    }
    if ([view isKindOfClass:[UICollectionView class]])
    {
        [((UICollectionView *)view).collectionViewLayout invalidateLayout];
    }
    [view invalidateIntrinsicContentSize];
    [view setNeedsLayout];
    for (UIView *subview in view.subviews)
    {
        CRRelayoutViews(subview);
    }
    if (!view.superview || ![view.superview isKindOfClass:[UIView class]])
    {
        return;
    }
    [view layoutIfNeeded];
}

- (void)scalePresentedSheet:(UIViewController *)sheet
{
    CRLog(@"sbmode: add sheet style %ld presentation %@ size classes %ld/%ld", (long)sheet.modalPresentationStyle, sheet.presentationController, (long)self.window.traitCollection.horizontalSizeClass, (long)self.window.traitCollection.verticalSizeClass);
    UIView *container = sheet.presentationController.containerView;
    UIWindow *window = self.window;
    if (!container || container.superview != window)
    {
        CRLog(@"sbmode: add sheet not scaled, container %@ in %@", container, container.superview);
        return;
    }
    CGFloat layoutHeight = CRHomeScreenLayoutHeight();
    CGFloat scale = window.bounds.size.height / layoutHeight;
    container.transform = CGAffineTransformIdentity;
    // a phone's width: wider, it switches to a layout whose header fills half the sheet
    container.bounds = CGRectMake(0, 0, MIN(window.bounds.size.width / scale, [UIScreen mainScreen].bounds.size.width), layoutHeight);
    container.center = CGPointMake(CGRectGetMidX(window.bounds), CGRectGetMidY(window.bounds));
    container.transform = CGAffineTransformMakeScale(scale, scale);
    [container setNeedsLayout];
    [container layoutIfNeeded];
    UIEdgeInsets safeArea = sheet.view.safeAreaInsets;
    CRLog(@"sbmode: add sheet scaled %.2f, sheet %@, safe area %@ (window %@, additional %@)", scale, NSStringFromCGRect(sheet.view.frame), NSStringFromUIEdgeInsets(safeArea), NSStringFromUIEdgeInsets(window.safeAreaInsets), NSStringFromUIEdgeInsets(sheet.additionalSafeAreaInsets));
    // no notch to keep clear of on the car
    if (safeArea.top > 0)
    {
        UIEdgeInsets additional = sheet.additionalSafeAreaInsets;
        additional.top -= safeArea.top;
        sheet.additionalSafeAreaInsets = additional;
    }
    // parts sized before the resize (the search bar) keep their old size until the sheet works them out again, which it
    // otherwise only does when the search field gains or loses focus
    void (^refit)(void) = ^{
        for (NSString *name in @[@"_updateSearchBarContentInsets", @"_updateHorizontalSpacing", @"_updateCollectionViewInsets", @"_layoutSearchBarGradientMaskLayers"])
        {
            if ([sheet respondsToSelector:NSSelectorFromString(name)])
            {
                objcInvoke(sheet, name);
            }
        }
        CRRelayoutViews(sheet.viewIfLoaded);
    };
    refit();
    // again once the open animation is done, and the search bar with it
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        refit();
        UISearchBar *searchBar = nil;
        NSMutableArray *pending = sheet.viewIfLoaded ? [NSMutableArray arrayWithObject:sheet.viewIfLoaded] : [NSMutableArray array];
        while (pending.count && !searchBar)
        {
            UIView *view = pending.firstObject;
            [pending removeObjectAtIndex:0];
            if ([view isKindOfClass:[UISearchBar class]])
            {
                searchBar = (UISearchBar *)view;
            }
            [pending addObjectsFromArray:view.subviews];
        }
        // it stretches with its container from the width it was made at, which was worked out from the car screen
        if (searchBar.superview && searchBar.frame.size.width != searchBar.superview.bounds.size.width)
        {
            CGRect frame = searchBar.frame;
            frame.size.width = searchBar.superview.bounds.size.width;
            searchBar.frame = frame;
            CRRelayoutViews(searchBar);
        }
    });
}

- (id)iconStylePickerConfigurationForIconManager:(id)manager
{
    id iconController = objcInvoke(objc_getClass("SBIconController"), @"sharedInstance");
    return [iconController respondsToSelector:_cmd] ? objcInvoke_1(iconController, @"iconStylePickerConfigurationForIconManager:", manager) : nil;
}

// the look picked in the car's icon editor, saved as the phone's (SpringBoard calls this without checking for it)
- (void)updateStyleConfiguration:(id)configuration forIconManager:(id)manager
{
    id iconController = objcInvoke(objc_getClass("SBIconController"), @"sharedInstance");
    if ([iconController respondsToSelector:_cmd])
    {
        objcInvoke_2(iconController, @"updateStyleConfiguration:forIconManager:", configuration, manager);
    }
}

// folder names, from the phone's
- (NSString *)iconManager:(id)manager localizedFolderNameForDefaultDisplayName:(NSString *)name
{
    return objcInvoke_2(objcInvoke(objc_getClass("SBIconController"), @"sharedInstance"), @"iconManager:localizedFolderNameForDefaultDisplayName:", manager, name);
}

- (NSString *)localizedDefaultFolderNameForIconManager:(id)manager
{
    return objcInvoke_1(objcInvoke(objc_getClass("SBIconController"), @"sharedInstance"), @"localizedDefaultFolderNameForIconManager:", manager);
}

static NSString *CRBundleIDForIconView(id iconView)
{
    id icon = objcInvoke(iconView, @"icon");
    return [icon respondsToSelector:NSSelectorFromString(@"applicationBundleID")] ? objcInvoke(icon, @"applicationBundleID") : nil;
}

// apps with a CarPlay UI of their own carry a CarPlay declaration
static BOOL CRAppHasCarPlayUI(NSString *bundleID)
{
    if (!bundleID || [bundleID isEqualToString:kCRDashBoardBundleID])
    {
        return NO;
    }
    id app = objcInvoke_1(objcInvoke(objc_getClass("SBApplicationController"), @"sharedInstance"), @"applicationWithBundleIdentifier:", bundleID);
    return app && objcInvoke(objcInvoke(app, @"info"), @"carPlayDeclaration") != nil;
}

// long press menus: the phone's app shortcuts, plus opening the app's CarPlay UI when it has one
- (id)iconManager:(id)manager applicationShortcutItemsForIconView:(id)iconView
{
    NSArray *items = objcInvoke_2(objcInvoke(objc_getClass("SBIconController"), @"sharedInstance"), @"iconManager:applicationShortcutItemsForIconView:", manager, iconView);
    NSString *bundleID = CRBundleIDForIconView(iconView);
    if (!CRAppHasCarPlayUI(bundleID))
    {
        return items;
    }
    id item = [[[objc_getClass("SBSApplicationShortcutItem") alloc] init] autorelease];
    objcInvoke_1(item, @"setType:", kCROpenCarPlayUIShortcutType);
    objcInvoke_1(item, @"setLocalizedTitle:", @"Open CarPlay App");
    objcInvoke_1(item, @"setBundleIdentifierToLaunch:", bundleID);
    Class iconClass = objc_getClass("SBSApplicationShortcutSystemPrivateIcon");
    if ([iconClass instancesRespondToSelector:NSSelectorFromString(@"initWithSystemImageName:")])
    {
        objcInvoke_1(item, @"setIcon:", [objcInvoke_1([iconClass alloc], @"initWithSystemImageName:", @"car") autorelease]);
    }
    return [@[item] arrayByAddingObjectsFromArray:items ?: @[]];
}

// in the scaled home screen, so the menu lines up with (and is sized like) its icon
- (UIView *)iconManager:(id)manager containerViewForPresentingContextMenuForIconView:(id)iconView
{
    return self.scaledView ?: self.window.rootViewController.view;
}

#pragma mark - widget taps

// a widget's tap opens its app (or the app for its link) on the car screen, handed the widget's action
- (void)launchWidgetApp:(NSString *)bundleID action:(id)action
{
    CRLog(@"sbmode: widget launch %@ action %@", bundleID, action);
    if (bundleID && self.launchHandler)
    {
        self.launchHandler(bundleID, self.window.frame, action ? [NSSet setWithObject:action] : nil);
    }
}

// a CHUISWidgetLaunchRequest: the widget's app and its action (a user activity or a link)
- (void)launchWidgetRequest:(id)launch
{
    NSString *bundleID = [launch respondsToSelector:NSSelectorFromString(@"effectiveContainerBundleIdentifier")] ? objcInvoke(launch, @"effectiveContainerBundleIdentifier") : nil;
    id action = [launch respondsToSelector:NSSelectorFromString(@"launchAction")] ? objcInvoke(launch, @"launchAction") : nil;
    NSURL *url = [launch respondsToSelector:NSSelectorFromString(@"url")] ? objcInvoke(launch, @"url") : nil;
    if (!action && url)
    {
        [self iconManager:nil wantsLaunchForWidgetURL:url];
        return;
    }
    [self launchWidgetApp:bundleID action:action];
}

- (void)iconManager:(id)manager widgetWantsLaunchForBundleIdentifier:(NSString *)bundleID withAction:(id)action
{
    [self launchWidgetApp:bundleID action:action];
}

- (void)iconManager:(id)manager iconView:(id)iconView widgetWantsLaunchForBundleIdentifier:(NSString *)bundleID withAction:(id)action
{
    [self launchWidgetApp:bundleID action:action];
}

- (void)iconManager:(id)manager wantsLaunchForWidgetURL:(NSURL *)url
{
    NSString *bundleID = [self iconManager:manager bundleIdentifierToLaunchForWidgetURL:url];
    if (!bundleID)
    {
        id workspace = objcInvoke(objc_getClass("LSApplicationWorkspace"), @"defaultWorkspace");
        bundleID = objcInvoke([objcInvoke_1(workspace, @"applicationsAvailableForOpeningURL:", url) firstObject], @"bundleIdentifier");
    }
    id action = url ? [[[objc_getClass("UIOpenURLAction") alloc] initWithURL:url] autorelease] : nil;
    [self launchWidgetApp:bundleID action:action];
}

- (NSString *)iconManager:(id)manager bundleIdentifierToLaunchForWidgetURL:(NSURL *)url
{
    id iconController = objcInvoke(objc_getClass("SBIconController"), @"sharedInstance");
    return [iconController respondsToSelector:_cmd] ? objcInvoke_2(iconController, @"iconManager:bundleIdentifierToLaunchForWidgetURL:", manager, url) : nil;
}

// iOS 18's free placement: icons keep the cell they're dropped in
- (long long)iconManagerListsFixedIconLocationBehavior:(id)manager
{
    return kCRFixedIconLocationBehavior;
}

- (BOOL)iconManagerAppliesListsFixedIconLocationBehaviorOnlyToNewLists:(id)manager
{
    return NO;
}

- (BOOL)iconManager:(id)manager isIconVisibleForBundleIdentifier:(NSString *)bundleID
{
    id iconController = objcInvoke(objc_getClass("SBIconController"), @"sharedInstance");
    return [iconController respondsToSelector:_cmd] ? ((BOOL (*)(id, SEL, id, id))objc_msgSend)(iconController, _cmd, manager, bundleID) : YES;
}

// opens the app on the car screen, then hands it the shortcut
- (BOOL)iconManager:(id)manager shouldActivateApplicationShortcutItem:(id)item atIndex:(unsigned long long)index forIconView:(id)iconView
{
    NSString *bundleID = CRBundleIDForIconView(iconView);
    CRLog(@"sbmode: shortcut %@ for %@", item, bundleID);
    if ([objcInvoke(item, @"type") isEqualToString:kCROpenCarPlayUIShortcutType])
    {
        // CarPlay opens it, which hides this home screen until CarPlay goes home again
        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotificationName:kCRSpringBoardModeOpenNativeNotification object:nil userInfo:@{@"identifier": bundleID}];
        return NO;
    }
    if (bundleID && self.launchHandler)
    {
        self.launchHandler(bundleID, self.window.frame, nil);
    }
    id iconController = objcInvoke(objc_getClass("SBIconController"), @"sharedInstance");
    return ((BOOL (*)(id, SEL, id, id, unsigned long long, id))objc_msgSend)(iconController, _cmd, manager, item, index, iconView);
}

- (void)iconManager:(id)manager launchIconForIconView:(id)iconView
{
    id icon = objcInvoke(iconView, @"icon");
    NSString *bundleID = [icon respondsToSelector:NSSelectorFromString(@"applicationBundleID")] ? objcInvoke(icon, @"applicationBundleID") : nil;
    CRLog(@"sbmode: launch %@ (%@)", bundleID, icon);
    if (!bundleID && [icon respondsToSelector:NSSelectorFromString(@"activeWidget")])
    {
        bundleID = objcInvoke(objcInvoke(icon, @"activeWidget"), @"containerBundleIdentifier");
    }
    NSString *leafIdentifier = [icon respondsToSelector:NSSelectorFromString(@"leafIdentifier")] ? objcInvoke(icon, @"leafIdentifier") : nil;
    if ([leafIdentifier isEqualToString:kCRCarIconIdentifier])
    {
        self.carIconDataSource.launchHandler();
        return;
    }
    if ([bundleID isEqualToString:kCRDashBoardBundleID])
    {
        [self leave];
        return;
    }
    if (bundleID && self.launchHandler)
    {
        self.launchHandler(bundleID, self.window.frame, nil);
    }
}

@end
