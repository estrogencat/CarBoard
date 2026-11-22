#include "common.h"

@implementation CRPreferences

+ (instancetype)sharedInstance
{
    static CRPreferences *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[CRPreferences alloc] init];
    });
    return sharedInstance;
}

- (id)init
{
    if ((self = [super init]))
    {
        [self reloadPreferences];
    }

    return self;
}

- (void)reloadPreferences
{
    if ([[NSFileManager defaultManager] fileExistsAtPath:PREFERENCES_PLIST_PATH])
    {
        _cachedPreferences = [[NSDictionary alloc] initWithContentsOfFile:PREFERENCES_PLIST_PATH];
    }
    else {
        _cachedPreferences = @{};
    }
}

- (void)writePreferences
{
    [_cachedPreferences writeToFile:PREFERENCES_PLIST_PATH atomically:NO];
}

- (void)updateValue:(id)value forPreferenceKey:(NSString *)key
{
    NSMutableDictionary *copy = [_cachedPreferences mutableCopy];
    copy[key] = value;
    _cachedPreferences = copy;
    [self writePreferences];
}

- (NSArray *)excludedApplications
{
    if (_cachedPreferences && [_cachedPreferences valueForKey:@"excludedApps"])
    {
        return [_cachedPreferences valueForKey:@"excludedApps"];
    }

    return @[@"com.netflix.Netflix", @"com.hulu.plus", @"com.amazon.aiv.AIVApp"];
}

- (CRDockAlignment)dockAlignment
{
    if (_cachedPreferences && [_cachedPreferences valueForKey:@"dockAlignment"])
    {
        return (CRDockAlignment)[[_cachedPreferences valueForKey:@"dockAlignment"] intValue];
    }

    return CRDockAlignmentAuto;
}

- (BOOL)nativeCarplayLook
{
    if (_cachedPreferences && [_cachedPreferences valueForKey:@"nativeCarplayLook"])
    {
        return [[_cachedPreferences valueForKey:@"nativeCarplayLook"] boolValue];
    }

    return YES;
}

- (BOOL)fiveColumnIconLayout
{
    if (_cachedPreferences && [_cachedPreferences valueForKey:@"fiveColumnIconLayout"])
    {
        return [[_cachedPreferences valueForKey:@"fiveColumnIconLayout"] boolValue];
    }

    return YES;
}

static CGFloat CRClampedScale(id value)
{
    CGFloat scale = value ? [value doubleValue] : 1.0;
    return (scale >= 0.5 && scale <= 1.5) ? scale : 1.0;
}

- (CGFloat)homeScreenScale
{
    return CRClampedScale([_cachedPreferences valueForKey:@"homeScreenScale"]);
}

- (CGFloat)appScale
{
    return CRClampedScale([_cachedPreferences valueForKey:@"appScale"]);
}

- (BOOL)fiveDockIcons
{
    id value = [_cachedPreferences valueForKey:@"fiveDockIcons"];
    return value ? [value boolValue] : YES;
}

- (BOOL)pinSpringBoardInDock
{
    return [[_cachedPreferences valueForKey:@"pinSpringBoardInDock"] boolValue];
}

- (BOOL)alertsOnCar
{
    return [[_cachedPreferences valueForKey:@"alertsOnCar"] boolValue];
}

- (BOOL)iPadAppLayout
{
    return [[_cachedPreferences valueForKey:@"iPadAppLayout"] boolValue];
}

@end
