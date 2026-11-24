#include "../common.h"

@interface PSListController : UIViewController
- (id)specifierForID:(NSString *)identifier;
- (long long)indexOfSpecifier:(id)specifier;
- (void)removeSpecifier:(id)specifier animated:(BOOL)animated;
- (void)insertSpecifier:(id)specifier afterSpecifier:(id)afterSpecifier animated:(BOOL)animated;
@end

@interface PSSpecifier : NSObject
- (id)propertyForKey:(NSString *)key;
- (void)setProperty:(id)value forKey:(NSString *)key;
@end

@interface UIImage (CRIcons)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier format:(int)format scale:(CGFloat)scale;
@end

/*
iOS 18's main Settings page is SwiftUI with nothing to hook, so PreferenceLoader puts tweaks at the bottom of General.
Move CarBoard up under General's CarPlay row; if either row isn't found it stays where PreferenceLoader put it.
*/
%group PREFERENCES

%hook PSListController

- (void)viewWillAppear:(BOOL)animated
{
    %orig;
    Class generalClass = objc_getClass("PSGGeneralController");
    if (!generalClass || ![self isKindOfClass:generalClass])
    {
        return;
    }
    @try
    {
        PSSpecifier *carBoard = [self specifierForID:@"CarBoard"];
        id carPlay = [self specifierForID:@"CARPLAY"];
        if (!carBoard || !carPlay || [self indexOfSpecifier:carBoard] == [self indexOfSpecifier:carPlay] + 1)
        {
            return;
        }
        // the system's no-icon placeholder until CarBoard has an icon
        if (![carBoard propertyForKey:@"iconImage"])
        {
            UIImage *icon = [UIImage _applicationIconImageForBundleIdentifier:@"com.estrogencat.carboard.noicon" format:0 scale:[UIScreen mainScreen].scale];
            if (icon)
            {
                [carBoard setProperty:icon forKey:@"iconImage"];
            }
        }
        [self removeSpecifier:carBoard animated:NO];
        [self insertSpecifier:carBoard afterSpecifier:carPlay animated:NO];
    }
    @catch (NSException *exception)
    {
        CRLog(@"settings: couldn't move the CarBoard row: %@", exception);
    }
}

%end

%end

%ctor
{
    BAIL_IF_UNSUPPORTED_IOS;

    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.Preferences"])
    {
        %init(PREFERENCES);
    }
}
