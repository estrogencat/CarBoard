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

@end