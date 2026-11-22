#pragma once
#include <UIKit/UIKit.h>

/*
An iPad-style grid of the apps opened on the car screen, opened by a double press of CarPlay's home button while
SpringBoard mode is up. Lives in SpringBoard
*/
@interface CRCarAppSwitcher : NSObject

+ (instancetype)sharedInstance;

// an app opened on the car, in this app area (display points)
- (void)noteAppOpened:(NSString *)bundleIdentifier appFrame:(CGRect)appFrame;
// the app's car window is about to close: keep a picture of it for its card
- (void)noteAppLeaving:(NSString *)bundleIdentifier window:(UIWindow *)window;
- (BOOL)isShowing;
- (void)show;
- (void)hideAnimated:(BOOL)animated;

@end
