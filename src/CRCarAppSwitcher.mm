#include "common.h"
#include "CRCarAppSwitcher.h"
#include "CRSpringBoardMode.h"
#include "CRCarplayWindow.h"
#include <IOSurface/IOSurfaceRef.h>

static const NSUInteger kCRMaxRecentApps = 20;
static const CGFloat kCRCardLabelHeight = 20;
static const CGFloat kCRCardLabelGap = 6;
static const CGFloat kCRCardSpacing = 18;
static const CGFloat kCRGridMargin = 20;
// the recent apps and their pictures, kept over CarPlay and SpringBoard restarts
static NSString *const kCRRecentAppsPath = @"/var/mobile/Library/SpringBoard/CarPlayEnableRecentApps.plist";
static NSString *const kCRSnapshotsDirectory = @"/var/mobile/Library/Caches/CarPlayEnableSwitcher";

static NSString *CRSnapshotPath(NSString *bundleIdentifier)
{
    return [kCRSnapshotsDirectory stringByAppendingPathComponent:[bundleIdentifier stringByAppendingPathExtension:@"jpg"]];
}

@interface CRCarAppSwitcher () <UIGestureRecognizerDelegate>
@property (nonatomic, retain) NSMutableArray *recentIdentifiers;
@property (nonatomic, retain) NSMutableDictionary *snapshots;
@property (nonatomic, retain) UIWindow *window;
@property (nonatomic, retain) UIScrollView *scrollView;
@property (nonatomic, retain) NSMutableArray *cards;
@end

@implementation CRCarAppSwitcher
{
    CGRect _lastAppFrame;
}

+ (instancetype)sharedInstance
{
    static CRCarAppSwitcher *sharedInstance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[CRCarAppSwitcher alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init
{
    if ((self = [super init]))
    {
        _recentIdentifiers = [[NSMutableArray alloc] init];
        _snapshots = [[NSMutableDictionary alloc] init];
        _cards = [[NSMutableArray alloc] init];
        NSArray *saved = [NSArray arrayWithContentsOfFile:kCRRecentAppsPath];
        for (id bundleIdentifier in saved)
        {
            if (![bundleIdentifier isKindOfClass:[NSString class]] || [_recentIdentifiers containsObject:bundleIdentifier])
            {
                continue;
            }
            [_recentIdentifiers addObject:bundleIdentifier];
            UIImage *snapshot = [UIImage imageWithContentsOfFile:CRSnapshotPath(bundleIdentifier)];
            if (snapshot)
            {
                // saved at the screen's scale
                _snapshots[bundleIdentifier] = [UIImage imageWithCGImage:snapshot.CGImage scale:[self carScreenScale] orientation:UIImageOrientationUp];
            }
        }
    }
    return self;
}

- (CGFloat)carScreenScale
{
    for (UIScreen *screen in [UIScreen screens])
    {
        if (objcInvokeT(screen, @"_isCarScreen", BOOL))
        {
            return screen.scale;
        }
    }
    return 1;
}

- (void)saveRecents
{
    [self.recentIdentifiers writeToFile:kCRRecentAppsPath atomically:YES];
}

- (void)forgetApp:(NSString *)bundleIdentifier
{
    // often the recents' own entry, which removing it frees
    bundleIdentifier = [[bundleIdentifier retain] autorelease];
    [self.recentIdentifiers removeObject:bundleIdentifier];
    [self.snapshots removeObjectForKey:bundleIdentifier];
    [[NSFileManager defaultManager] removeItemAtPath:CRSnapshotPath(bundleIdentifier) error:nil];
}

- (void)noteAppOpened:(NSString *)bundleIdentifier appFrame:(CGRect)appFrame
{
    if (!bundleIdentifier || [bundleIdentifier isEqualToString:kCRSpringBoardBundleID])
    {
        return;
    }
    if (!CGRectIsEmpty(appFrame))
    {
        _lastAppFrame = appFrame;
    }
    [self.recentIdentifiers removeObject:bundleIdentifier];
    [self.recentIdentifiers insertObject:bundleIdentifier atIndex:0];
    while (self.recentIdentifiers.count > kCRMaxRecentApps)
    {
        [self forgetApp:self.recentIdentifiers.lastObject];
    }
    [self saveRecents];
}

extern "C" void CARenderServerRenderDisplay(kern_return_t port, CFStringRef displayName, IOSurfaceRef surface, int x, int y);
extern "C" CGImageRef UICreateCGImageFromIOSurface(IOSurfaceRef surface);

// what's on the car screen in rect (display points), other processes' content included
static UIImage *CRSnapshotScreen(UIScreen *screen, CGRect rect)
{
    NSString *displayName = objcInvoke(getCarplayCADisplay(), @"name");
    if (!screen || !displayName)
    {
        return nil;
    }
    CGFloat scale = screen.scale;
    int width = (int)round(screen.bounds.size.width * scale);
    int height = (int)round(screen.bounds.size.height * scale);
    NSDictionary *properties = @{
        (id)kIOSurfaceWidth: @(width),
        (id)kIOSurfaceHeight: @(height),
        (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfaceBytesPerRow: @(width * 4),
        (id)kIOSurfacePixelFormat: @((unsigned int)'BGRA'),
    };
    IOSurfaceRef surface = IOSurfaceCreate((CFDictionaryRef)properties);
    if (!surface)
    {
        return nil;
    }
    CARenderServerRenderDisplay(0, (CFStringRef)displayName, surface, 0, 0);
    CGImageRef full = UICreateCGImageFromIOSurface(surface);
    CFRelease(surface);
    if (!full)
    {
        return nil;
    }
    CGImageRef cropped = CGImageCreateWithImageInRect(full, CGRectMake(rect.origin.x * scale, rect.origin.y * scale, rect.size.width * scale, rect.size.height * scale));
    CGImageRelease(full);
    UIImage *image = cropped ? [UIImage imageWithCGImage:cropped scale:scale orientation:UIImageOrientationUp] : nil;
    CGImageRelease(cropped);
    return image;
}

- (void)noteAppLeaving:(NSString *)bundleIdentifier window:(UIWindow *)window
{
    if (!bundleIdentifier || !window || window.hidden)
    {
        return;
    }
    UIImage *image = CRSnapshotScreen(window.screen, window.frame);
    CRLog(@"switcher: snapshot of %@ %@", bundleIdentifier, image ? NSStringFromCGSize(image.size) : @"failed");
    if (image)
    {
        self.snapshots[bundleIdentifier] = image;
        NSData *data = UIImageJPEGRepresentation(image, 0.8);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [[NSFileManager defaultManager] createDirectoryAtPath:kCRSnapshotsDirectory withIntermediateDirectories:YES attributes:nil error:nil];
            [data writeToFile:CRSnapshotPath(bundleIdentifier) atomically:YES];
        });
    }
}

- (BOOL)isShowing
{
    return self.window && !self.window.hidden;
}

#pragma mark - Showing

- (void)show
{
    CRSpringBoardMode *springBoardMode = [CRSpringBoardMode sharedInstance];
    UIWindow *homeWindow = springBoardMode.window;
    if ([self isShowing] || !springBoardMode.active || !homeWindow)
    {
        return;
    }
    id displayConfiguration = objcInvoke(homeWindow, @"displayConfiguration");
    if (!displayConfiguration)
    {
        return;
    }

    // the app still open behind gets a fresh picture
    CRCarPlayWindow *liveCarplayWindow = objcInvoke([UIApplication sharedApplication], @"liveCarplayWindow");
    if (liveCarplayWindow && !liveCarplayWindow.isDismissing)
    {
        [self noteAppLeaving:[liveCarplayWindow bundleIdentifier] window:liveCarplayWindow.rootWindow];
    }

    CGRect frame = homeWindow.frame;
    UIWindow *window = [objcInvoke_1([objc_getClass("UIRootSceneWindow") alloc], @"initWithDisplayConfiguration:", displayConfiguration) autorelease];
    window.frame = frame;
    // over our app windows (1), under CarPlay's banners (7)
    window.windowLevel = 2;
    window.backgroundColor = [UIColor blackColor];
    window.layer.masksToBounds = YES;
    UIViewController *rootViewController = [[[UIViewController alloc] init] autorelease];
    window.rootViewController = rootViewController;
    UIView *root = rootViewController.view;
    root.frame = window.bounds;

    // what's behind, blurred
    UIImageView *backdrop = [[[UIImageView alloc] initWithFrame:root.bounds] autorelease];
    backdrop.image = CRSnapshotScreen(homeWindow.screen, frame);
    [root addSubview:backdrop];
    UIVisualEffectView *blur = [[[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]] autorelease];
    blur.frame = root.bounds;
    [root addSubview:blur];

    UIScrollView *scrollView = [[[UIScrollView alloc] initWithFrame:root.bounds] autorelease];
    scrollView.showsHorizontalScrollIndicator = NO;
    scrollView.alwaysBounceHorizontal = YES;
    [root addSubview:scrollView];
    self.scrollView = scrollView;

    UITapGestureRecognizer *backgroundTap = [[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleBackgroundTap:)] autorelease];
    backgroundTap.delegate = self;
    [scrollView addGestureRecognizer:backgroundTap];

    // apps deleted since
    id applicationController = objcInvoke(objc_getClass("SBApplicationController"), @"sharedInstance");
    for (NSString *bundleIdentifier in [[self.recentIdentifiers copy] autorelease])
    {
        if (!objcInvoke_1(applicationController, @"applicationWithBundleIdentifier:", bundleIdentifier))
        {
            [self forgetApp:bundleIdentifier];
        }
    }
    [self saveRecents];

    if (self.recentIdentifiers.count == 0)
    {
        UILabel *empty = [[[UILabel alloc] initWithFrame:root.bounds] autorelease];
        empty.text = @"No Recent Apps";
        empty.textColor = [UIColor colorWithWhite:1 alpha:0.6];
        empty.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        empty.textAlignment = NSTextAlignmentCenter;
        [scrollView addSubview:empty];
    }

    [self.cards removeAllObjects];
    for (NSString *bundleIdentifier in self.recentIdentifiers)
    {
        UIView *card = [self cardForBundleIdentifier:bundleIdentifier];
        [scrollView addSubview:card];
        [self.cards addObject:card];
    }
    [self layoutCardsAnimated:NO];

    self.window = window;
    window.hidden = NO;
    root.alpha = 0;
    scrollView.transform = CGAffineTransformMakeScale(1.08, 1.08);
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        root.alpha = 1;
        scrollView.transform = CGAffineTransformIdentity;
    } completion:nil];
    CRLog(@"switcher: showing %lu apps", (unsigned long)self.recentIdentifiers.count);
}

- (void)hideAnimated:(BOOL)animated
{
    UIWindow *window = [[self.window retain] autorelease];
    if (!window)
    {
        return;
    }
    self.window = nil;
    self.scrollView = nil;
    [self.cards removeAllObjects];
    if (!animated)
    {
        window.hidden = YES;
        return;
    }
    [UIView animateWithDuration:0.2 animations:^{
        window.rootViewController.view.alpha = 0;
    } completion:^(BOOL finished) {
        window.hidden = YES;
    }];
}

#pragma mark - Cards

- (CGSize)cardSize
{
    CGSize bounds = self.scrollView.bounds.size;
    // two rows of cards shaped like the app area, each under its icon and name
    CGFloat height = floor((bounds.height - 2 * kCRGridMargin - kCRCardSpacing - 2 * (kCRCardLabelHeight + kCRCardLabelGap)) / 2);
    CGFloat width = floor(height * bounds.width / MAX(bounds.height, 1));
    return CGSizeMake(width, height);
}

- (UIView *)cardForBundleIdentifier:(NSString *)bundleIdentifier
{
    CGSize size = [self cardSize];
    UIView *card = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, size.width, size.height + kCRCardLabelHeight + kCRCardLabelGap)] autorelease];
    card.accessibilityIdentifier = bundleIdentifier;

    UIImage *icon = ((id (*)(id, SEL, id, int, CGFloat))objc_msgSend)([UIImage class], NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:"), bundleIdentifier, 0, [UIScreen mainScreen].scale);
    UIImageView *iconView = [[[UIImageView alloc] initWithImage:icon] autorelease];
    iconView.frame = CGRectMake(0, 0, kCRCardLabelHeight, kCRCardLabelHeight);
    [card addSubview:iconView];

    id application = objcInvoke_1(objcInvoke(objc_getClass("SBApplicationController"), @"sharedInstance"), @"applicationWithBundleIdentifier:", bundleIdentifier);
    UILabel *name = [[[UILabel alloc] initWithFrame:CGRectMake(kCRCardLabelHeight + 6, 0, size.width - kCRCardLabelHeight - 6, kCRCardLabelHeight)] autorelease];
    name.text = objcInvoke(application, @"displayName") ?: bundleIdentifier;
    name.textColor = [UIColor whiteColor];
    name.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [card addSubview:name];

    UIView *preview = [[[UIView alloc] initWithFrame:CGRectMake(0, kCRCardLabelHeight + kCRCardLabelGap, size.width, size.height)] autorelease];
    preview.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1];
    preview.layer.cornerRadius = 12;
    preview.layer.cornerCurve = kCACornerCurveContinuous;
    preview.clipsToBounds = YES;
    UIImage *snapshot = self.snapshots[bundleIdentifier];
    UIImageView *previewImage = [[[UIImageView alloc] initWithFrame:preview.bounds] autorelease];
    previewImage.image = snapshot ?: icon;
    previewImage.contentMode = snapshot ? UIViewContentModeScaleAspectFill : UIViewContentModeCenter;
    [preview addSubview:previewImage];
    [card addSubview:preview];

    [card addGestureRecognizer:[[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleCardTap:)] autorelease]];
    UIPanGestureRecognizer *pan = [[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleCardPan:)] autorelease];
    pan.delegate = self;
    [card addGestureRecognizer:pan];
    return card;
}

- (void)layoutCardsAnimated:(BOOL)animated
{
    CGSize size = [self cardSize];
    CGFloat cardHeight = size.height + kCRCardLabelHeight + kCRCardLabelGap;
    NSUInteger columns = (self.cards.count + 1) / 2;
    CGFloat contentWidth = 2 * kCRGridMargin + columns * size.width + (columns ? columns - 1 : 0) * kCRCardSpacing;
    CGFloat boundsWidth = self.scrollView.bounds.size.width;
    // few enough to fit: centred, like the iPad's
    CGFloat originX = contentWidth < boundsWidth ? (boundsWidth - contentWidth) / 2 + kCRGridMargin : kCRGridMargin;
    void (^layout)(void) = ^{
        [self.cards enumerateObjectsUsingBlock:^(UIView *card, NSUInteger index, BOOL *stop) {
            NSUInteger column = index / 2;
            NSUInteger row = index % 2;
            card.frame = CGRectMake(originX + column * (size.width + kCRCardSpacing), kCRGridMargin + row * (cardHeight + kCRCardSpacing), size.width, cardHeight);
        }];
        self.scrollView.contentSize = CGSizeMake(MAX(contentWidth, boundsWidth), self.scrollView.bounds.size.height);
    };
    if (animated)
    {
        [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:0 animations:layout completion:nil];
    }
    else
    {
        layout();
    }
}

- (void)handleCardTap:(UITapGestureRecognizer *)gesture
{
    NSString *bundleIdentifier = gesture.view.accessibilityIdentifier;
    CRSpringBoardMode *springBoardMode = [CRSpringBoardMode sharedInstance];
    CGRect appFrame = CGRectIsEmpty(_lastAppFrame) ? springBoardMode.window.frame : _lastAppFrame;
    CRLog(@"switcher: opening %@", bundleIdentifier);
    [self hideAnimated:YES];
    if (bundleIdentifier && springBoardMode.launchHandler)
    {
        springBoardMode.launchHandler(bundleIdentifier, appFrame, nil);
    }
}

// swipe a card up to quit its app
- (void)handleCardPan:(UIPanGestureRecognizer *)gesture
{
    UIView *card = gesture.view;
    CGFloat lift = MIN(0, [gesture translationInView:card.superview].y);
    switch (gesture.state)
    {
        case UIGestureRecognizerStateChanged:
            card.transform = CGAffineTransformMakeTranslation(0, lift);
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        {
            BOOL quit = gesture.state == UIGestureRecognizerStateEnded && (lift < -card.bounds.size.height / 3 || [gesture velocityInView:card.superview].y < -600);
            if (!quit)
            {
                [UIView animateWithDuration:0.25 animations:^{
                    card.transform = CGAffineTransformIdentity;
                }];
                break;
            }
            NSString *bundleIdentifier = card.accessibilityIdentifier;
            [UIView animateWithDuration:0.2 animations:^{
                card.transform = CGAffineTransformMakeTranslation(0, -(card.frame.origin.y + card.bounds.size.height + 40));
            } completion:^(BOOL finished) {
                [card removeFromSuperview];
            }];
            [self.cards removeObject:card];
            [self forgetApp:bundleIdentifier];
            [self saveRecents];
            [self layoutCardsAnimated:YES];
            [self quitApp:bundleIdentifier];
            if (self.cards.count == 0)
            {
                [self hideAnimated:YES];
            }
            break;
        }
        default:
            break;
    }
}

- (void)quitApp:(NSString *)bundleIdentifier
{
    id liveCarplayWindow = objcInvoke([UIApplication sharedApplication], @"liveCarplayWindow");
    if ([objcInvoke(liveCarplayWindow, @"bundleIdentifier") isEqualToString:bundleIdentifier])
    {
        objcInvoke(liveCarplayWindow, @"dismiss");
    }
    id systemService = objcInvoke(objc_getClass("FBSSystemService"), @"sharedService");
    SEL terminate = NSSelectorFromString(@"terminateApplication:forReason:andReport:withDescription:");
    if ([systemService respondsToSelector:terminate])
    {
        // 1: the user asked
        ((void (*)(id, SEL, id, long long, BOOL, id))objc_msgSend)(systemService, terminate, bundleIdentifier, 1, NO, @"CarPlayEnable app switcher");
    }
    CRLog(@"switcher: quit %@", bundleIdentifier);
}

- (void)handleBackgroundTap:(UITapGestureRecognizer *)gesture
{
    [self hideAnimated:YES];
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture
{
    if ([gesture isKindOfClass:[UIPanGestureRecognizer class]])
    {
        // up, not across (the grid scrolls across)
        CGPoint velocity = [(UIPanGestureRecognizer *)gesture velocityInView:gesture.view];
        return velocity.y < 0 && fabs(velocity.y) > fabs(velocity.x);
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch
{
    // the background tap only takes taps off the cards
    if (gesture.view == self.scrollView && [gesture isKindOfClass:[UITapGestureRecognizer class]])
    {
        for (UIView *card in self.cards)
        {
            if ([touch.view isDescendantOfView:card])
            {
                return NO;
            }
        }
    }
    return YES;
}

@end
