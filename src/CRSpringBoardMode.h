#pragma once
#include <UIKit/UIKit.h>

/*
SpringBoard's home screen on the CarPlay display, standing in for CarPlay's own (DashBoard) until it's left or CarPlay
restarts. Lives in SpringBoard: a home screen of its own (icon manager + model) on its own copy of the phone's layout.
*/
// gives the frosted backgrounds in a view (and under it) a capture group apart from the phone's
void CRSeparateMaterialGroups(UIView *view);

// SpringBoard's SBHIconGridSize
typedef struct {
    unsigned short columns;
    unsigned short rows;
} CRIconGridSize;

@interface CRSpringBoardMode : NSObject

@property (nonatomic, readonly) BOOL active;
@property (nonatomic, readonly, retain) UIWindow *window;
// opens an app on CarPlay, in the given app area (display points), handing it actions (a widget's link) if any
@property (nonatomic, copy) void (^launchHandler)(NSString *bundleIdentifier, CGRect appFrame, NSSet *actions);

+ (instancetype)sharedInstance;

// appFrame: CarPlay's app area beside its sidebar (empty to guess it)
- (void)enterWithAppFrame:(CGRect)appFrame;
// hidden while one of CarPlay's own apps has the screen
- (void)setShowing:(BOOL)showing;
- (void)exit;
// builds the home screen again (its size setting changed)
- (void)rebuild;
// exit, and stay on CarPlay's own home screen after CarPlay restarts
- (void)leave;
// SpringBoard mode was on when CarPlay last stopped
- (BOOL)wasLeftOn;
// its home screen is in edit mode (icons jiggling)
- (BOOL)isEditing;
// the car home screen's dock size, for its icon model or manager (0 for anything else)
- (NSUInteger)dockIconCountForIconModelOrManager:(id)object;
// the car home screen's pages (they follow its size setting), NO for any other model
- (BOOL)rootGridColumns:(NSUInteger *)columns rows:(NSUInteger *)rows forIconModel:(id)object;
- (BOOL)isCarIconManager:(id)object;
- (BOOL)isCarRootFolder:(id)folder;
- (CGFloat)libraryListWidth;
// puts away the add-widget sheet if it's up
- (BOOL)closeAddSheet;
// the phone's icon look (light, dark, tinted) changed
- (void)updateIconStyle;
// CarPlay sent the car's own icon (its name and a PNG)
- (void)noteCarIconName:(NSString *)name imageData:(NSData *)imageData;
// leaf identifiers of the icons that are ours (CarPlay's, the car's), for the App Library
- (NSArray<NSString *> *)libraryIconIdentifiers;
- (BOOL)isCarLibrary:(id)libraryViewController;

- (void)launchWidgetRequest:(id)launch;
// CarPlay's home button while the home screen is up
- (void)homeButtonPressed;
- (void)presentSearch;
// the car's Spotlight is up (its keyboard goes on the car)
- (BOOL)isSearchShowing;
@end
