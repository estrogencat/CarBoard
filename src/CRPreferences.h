#include <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, CRDockAlignment) {
    CRDockAlignmentLeft = 0,
    CRDockAlignmentRight,
    CRDockAlignmentAuto,
};

@interface CRPreferences : NSObject

@property (nonatomic, retain) NSDictionary *cachedPreferences;

+ (instancetype)sharedInstance;

- (void)reloadPreferences;
- (void)writePreferences;
- (void)updateValue:(id)value forPreferenceKey:(NSString *)key;

- (NSArray *)excludedApplications;
- (CRDockAlignment)dockAlignment;
// apps open in CarPlay's own app area (beside its sidebar) instead of a full-screen window with a dock
- (BOOL)nativeCarplayLook;
- (BOOL)fiveColumnIconLayout;
// how big SpringBoard's home screen and apps are drawn on the car (1 = as now)
- (CGFloat)homeScreenScale;
- (CGFloat)appScale;
// apps on the car get iPad traits (regular size classes, pad idiom)
- (BOOL)iPadAppLayout;
// system alerts (permission prompts) show on the car while an app is open there
- (BOOL)alertsOnCar;
// CarPlay's sidebar: 5 recent apps instead of 3, SpringBoard always last
- (BOOL)fiveDockIcons;
- (BOOL)pinSpringBoardInDock;

@end