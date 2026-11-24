#pragma once
#include <UIKit/UIKit.h>

void CRSeparateMaterialGroups(UIView *view);

typedef struct {
    unsigned short columns;
    unsigned short rows;
} CRIconGridSize;

@interface CRSpringBoardMode : NSObject

@property (nonatomic, readonly) BOOL active;
@property (nonatomic, readonly, retain) UIWindow *window;
@property (nonatomic, copy) void (^launchHandler)(NSString *bundleIdentifier, CGRect appFrame, NSSet *actions);

+ (instancetype)sharedInstance;

- (void)enterWithAppFrame:(CGRect)appFrame;
- (void)setShowing:(BOOL)showing;
- (void)exit;
- (void)rebuild;
- (void)leave;
- (BOOL)wasLeftOn;
- (BOOL)isEditing;
- (NSUInteger)dockIconCountForIconModelOrManager:(id)object;
- (BOOL)rootGridColumns:(NSUInteger *)columns rows:(NSUInteger *)rows forIconModel:(id)object;
- (BOOL)isCarIconManager:(id)object;
- (BOOL)isCarRootFolder:(id)folder;
- (CGFloat)libraryListWidth;
- (BOOL)closeAddSheet;
- (void)updateIconStyle;
- (void)noteCarIconName:(NSString *)name imageData:(NSData *)imageData;
- (NSArray<NSString *> *)libraryIconIdentifiers;
- (BOOL)isCarLibrary:(id)libraryViewController;

- (void)launchWidgetRequest:(id)launch;
- (void)homeButtonPressed;
- (void)presentSearch;
- (BOOL)isSearchShowing;
@end
