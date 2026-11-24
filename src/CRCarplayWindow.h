#include <UIKit/UIKit.h>

id getCarplayCADisplay(void);

@interface CRCarPlayWindow : NSObject

@property (nonatomic, retain) UIWindow *rootWindow;
@property (nonatomic, retain) UIView *dockView;
@property (nonatomic, retain) UIView *appContainerView;
@property (nonatomic, retain) UIImageView *launchImageView;
@property (nonatomic, retain) UIView *fullscreenTransparentOverlay;
@property (nonatomic, retain) id appViewController;
@property (nonatomic, retain) id sceneMonitor;
@property (nonatomic, retain) id application;
@property (nonatomic, retain) id sessionStatus;
@property (nonatomic, retain) NSMutableArray *observers;
@property (nonatomic, retain) UITapGestureRecognizer *screenTapRecognizer;

@property (nonatomic) UIInterfaceOrientation orientation;
@property (nonatomic) BOOL isFullscreen;
@property (nonatomic) BOOL shouldGenerateSnapshot;
@property (nonatomic) BOOL drawOnMainScreen;

@property (nonatomic, readonly) BOOL nativeLook;
@property (nonatomic, readonly) BOOL isDismissing;
@property (nonatomic, readonly) CGFloat appScale;

- (id)initWithBundleIdentifier:(NSString *)identifier appFrame:(CGRect)appFrame;
- (id)initWithBundleIdentifier:(NSString *)identifier appFrame:(CGRect)appFrame launchActions:(NSSet *)launchActions;
- (void)deliverActions:(NSSet *)actions;
- (NSString *)bundleIdentifier;
- (void)dismiss;
- (void)followAppSupportedOrientations;

- (CGRect)sceneFrame;

@end

void CRApplyCarplaySceneSettings(id settings, CRCarPlayWindow *window);
NSArray *CRSceneViewsForSceneHandle(id sceneHandle, UIWindow *excludingWindow);
void CRRelayoutCarplayKeyboards(void);

void CRSetPadLayoutMarker(NSString *bundleIdentifier, BOOL padLayout);
