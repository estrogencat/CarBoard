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

// read from preferences when the window is made: sit in CarPlay's own app area (no dock) instead of a full-screen
// window with its own dock
@property (nonatomic, readonly) BOOL nativeLook;
@property (nonatomic, readonly) BOOL isDismissing;

// appFrame: CarPlay's app area beside its sidebar, in display points (empty to guess it). Only used for the native look
- (id)initWithBundleIdentifier:(NSString *)identifier appFrame:(CGRect)appFrame;
- (NSString *)bundleIdentifier;
- (void)dismiss;
// call when the app may have changed which orientations it supports
- (void)followAppSupportedOrientations;

// frame for the hosted scene, in the phone display's portrait coordinate space
- (CGRect)sceneFrame;

@end

// foreground, orientation, frame, and none of the phone's notch/home-indicator insets
void CRApplyCarplaySceneSettings(id settings, CRCarPlayWindow *window);
// main-screen (or any) scene views showing this scene handle, skipping ones inside excludingWindow
NSArray *CRSceneViewsForSceneHandle(id sceneHandle, UIWindow *excludingWindow);
// moves or rotates the keyboard to match the CarPlay window, or hands it back to the phone once that is gone
void CRRelayoutCarplayKeyboards(void);
