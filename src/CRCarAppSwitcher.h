#pragma once
#include <UIKit/UIKit.h>

@interface CRCarAppSwitcher : NSObject

+ (instancetype)sharedInstance;

- (void)noteAppOpened:(NSString *)bundleIdentifier appFrame:(CGRect)appFrame;
- (void)noteAppLeaving:(NSString *)bundleIdentifier window:(UIWindow *)window;
- (BOOL)isShowing;
- (void)show;
- (void)hideAnimated:(BOOL)animated;

@end
