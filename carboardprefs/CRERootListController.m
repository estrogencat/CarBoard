#include "CRERootListController.h"
#include "../src/common.h"

@interface UIImage (CRIcons)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier format:(int)format scale:(CGFloat)scale;
@end

// a Settings-style row icon: a white symbol on a colored rounded square
static UIImage *CRRowIcon(NSString *symbolName, UIColor *color)
{
    CGSize size = CGSizeMake(29, 29);
    UIImage *symbol = [[UIImage systemImageNamed:symbolName withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium]] imageWithTintColor:[UIColor whiteColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [color setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size.width, size.height) cornerRadius:7] fill];
        CGSize symbolSize = symbol.size;
        [symbol drawInRect:CGRectMake((size.width - symbolSize.width) / 2, (size.height - symbolSize.height) / 2, symbolSize.width, symbolSize.height)];
    }];
}

// the page's header card: icon, name and what it does, like the system's own settings pages
static UITableViewCell *CRHeaderCell(void)
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    // the system's placeholder for an app without an icon, until CarBoard has one
    UIImage *icon = [UIImage _applicationIconImageForBundleIdentifier:@"com.estrogencat.carboard.noicon" format:2 scale:[UIScreen mainScreen].scale];
    UIImageView *iconView = [[UIImageView alloc] initWithImage:icon];
    iconView.contentMode = UIViewContentModeScaleAspectFit;

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"CarBoard";
    titleLabel.font = [UIFont systemFontOfSize:30 weight:UIFontWeightBold];
    titleLabel.textAlignment = NSTextAlignmentCenter;

    UILabel *descriptionLabel = [[UILabel alloc] init];
    descriptionLabel.text = @"Use any app on CarPlay, or swap CarPlay's home screen for your iPhone's, with your widgets, App Library and search.";
    descriptionLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    descriptionLabel.textAlignment = NSTextAlignmentCenter;
    descriptionLabel.numberOfLines = 0;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[iconView, titleLabel, descriptionLabel]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 6;
    [stack setCustomSpacing:12 afterView:iconView];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [iconView.widthAnchor constraintEqualToConstant:60],
        [iconView.heightAnchor constraintEqualToConstant:60],
        [stack.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:22],
        [stack.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-22],
        [stack.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-20],
    ]];
    return cell;
}

@implementation CRERootListController

- (id)initForContentSize:(CGSize)size
{
    if ((self = [super init]))
    {
        [self setTitle:@"CarBoard"];
        _rootTable = [[UITableView alloc] initWithFrame:[[self view] bounds] style:UITableViewStyleInsetGrouped];
        [_rootTable setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
        [_rootTable setDelegate:self];
        [_rootTable setDataSource:self];
        [[self view] addSubview:_rootTable];

        // the prefs process lacks the entitlements for app and icon data, so SpringBoard sends it
        NSOperationQueue *notificationQueue = [[NSOperationQueue alloc] init];
        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] addObserverForName:PREFERENCES_APP_DATA_NOTIFICATION object:kPrefsAppDataReceiving queue:notificationQueue usingBlock:^(NSNotification * _Nonnull note) {
            NSDictionary *data = [note userInfo];
            NSArray *appList = data[@"appList"];
            if (appList)
            {
                dispatch_sync(dispatch_get_main_queue(), ^(void) {
                    _appListController = [[CPAppListController alloc] initWithAppList:appList];
                });
            }
        }];

        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotification:[NSNotification notificationWithName:PREFERENCES_APP_DATA_NOTIFICATION object:kPrefsAppDataRequesting]];
    }

    return self;
}

-(void)viewDidLoad
{
    [[self view] setBackgroundColor:[UIColor systemGroupedBackgroundColor]];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 7;
}

// section 0 is the header card, the settings follow
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0)
    {
        return 1;
    }
    switch (section - 1)
    {
        case 0:
            return 1;
        case 1:
            return 1;
        case 2:
            return 3;
        case 3:
            return 1;
        case 4:
            return 3;
        case 5:
            return 3;
        default:
            break;
    }
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == 0)
    {
        return CRHeaderCell();
    }
    indexPath = [NSIndexPath indexPathForRow:indexPath.row inSection:indexPath.section - 1];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"com.estrogencat.carboard.cell"];
    if (cell == nil)
    {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"com.estrogencat.carboard.cell"];
    }

    if (indexPath.section == 0)
    {
        if (indexPath.row == 0)
        {
            [[cell textLabel] setText:@"Add/Remove Apps"];
            cell.imageView.image = CRRowIcon(@"square.grid.2x2.fill", [UIColor systemBlueColor]);
            [cell setAccessoryView:nil];
            [cell setAccessoryType:UITableViewCellAccessoryDisclosureIndicator];
        }
    }
    else if (indexPath.section == 1)
    {
        [[cell textLabel] setText:@"Native CarPlay Look"];
        cell.imageView.image = CRRowIcon(@"car.fill", [UIColor systemGreenColor]);
        UISwitch *cellSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
        [cellSwitch setOn:[[CRPreferences sharedInstance] nativeCarplayLook] animated:NO];
        [cellSwitch addTarget:self action:@selector(nativeLookSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        [cell setAccessoryView:cellSwitch];
        [cell setAccessoryType:UITableViewCellAccessoryNone];
    }
    else if (indexPath.section == 2 && indexPath.row == 0)
    {
        [[cell textLabel] setText:@"Size %"];
        cell.imageView.image = CRRowIcon(@"arrow.up.left.and.arrow.down.right", [UIColor systemGrayColor]);
        [cell setAccessoryView:[self scaleControlForKey:@"appScale" value:[[CRPreferences sharedInstance] appScale]]];
        [cell setAccessoryType:UITableViewCellAccessoryNone];
    }
    else if (indexPath.section == 2)
    {
        BOOL promptsRow = indexPath.row == 2;
        [[cell textLabel] setText:promptsRow ? @"Permission Prompts on Car" : @"iPad Layout"];
        cell.imageView.image = promptsRow ? CRRowIcon(@"exclamationmark.bubble.fill", [UIColor systemOrangeColor]) : CRRowIcon(@"ipad.landscape", [UIColor systemIndigoColor]);
        UISwitch *cellSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
        [cellSwitch setOn:promptsRow ? [[CRPreferences sharedInstance] alertsOnCar] : [[CRPreferences sharedInstance] iPadAppLayout] animated:NO];
        [cellSwitch addTarget:self action:promptsRow ? @selector(alertsOnCarSwitchChanged:) : @selector(iPadLayoutSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        [cell setAccessoryView:cellSwitch];
        [cell setAccessoryType:UITableViewCellAccessoryNone];
    }
    else if (indexPath.section == 3)
    {
        [[cell textLabel] setText:@"Size %"];
        cell.imageView.image = CRRowIcon(@"apps.iphone", [UIColor systemPinkColor]);
        [cell setAccessoryView:[self scaleControlForKey:@"homeScreenScale" value:[[CRPreferences sharedInstance] homeScreenScale]]];
        [cell setAccessoryType:UITableViewCellAccessoryNone];
    }
    else if (indexPath.section == 4)
    {
        cell.imageView.image = nil;
        [cell setAccessoryView:nil];
        if (indexPath.row == 0)
        {
            [[cell textLabel] setText:@"Left"];
        }
        else if (indexPath.row == 1)
        {
            [[cell textLabel] setText:@"Right"];
        }
        else if (indexPath.row == 2)
        {
            [[cell textLabel] setText:@"Auto"];
            
        }

        if (indexPath.row == [[CRPreferences sharedInstance] dockAlignment])
        {
            [cell setAccessoryType:UITableViewCellAccessoryCheckmark];
        }
        else
        {
            [cell setAccessoryType:UITableViewCellAccessoryNone];
        }
    }
    else if (indexPath.section == 5)
    {
        if (indexPath.row == 0)
        {
            [[cell textLabel] setText:@"5 Columns"];
            cell.imageView.image = CRRowIcon(@"square.grid.3x3.fill", [UIColor systemTealColor]);
            UISwitch *cellSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
            [cellSwitch setOn:[[CRPreferences sharedInstance] fiveColumnIconLayout] animated:NO];
            [cellSwitch addTarget:self action:@selector(iconLayoutSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            [cell setAccessoryView:cellSwitch];
            [cell setAccessoryType:UITableViewCellAccessoryNone];
        }
        else
        {
            BOOL pinRow = indexPath.row == 2;
            [[cell textLabel] setText:pinRow ? @"SpringBoard at Bottom of Sidebar" : @"5 Apps in Sidebar"];
            cell.imageView.image = pinRow ? CRRowIcon(@"pin.fill", [UIColor systemRedColor]) : CRRowIcon(@"sidebar.left", [UIColor systemPurpleColor]);
            UISwitch *cellSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
            [cellSwitch setOn:pinRow ? [[CRPreferences sharedInstance] pinSpringBoardInDock] : [[CRPreferences sharedInstance] fiveDockIcons] animated:NO];
            cellSwitch.tag = indexPath.row;
            [cellSwitch addTarget:self action:@selector(dockSwitchChanged:) forControlEvents:UIControlEventValueChanged];
            [cell setAccessoryView:cellSwitch];
            [cell setAccessoryType:UITableViewCellAccessoryNone];
        }
    }
    
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section - 1)
    {
        case 0:
            return @"CarPlay Dashboard";
        case 1:
            return @"App Window";
        case 2:
            return @"Apps";
        case 3:
            return @"SpringBoard Home Screen";
        case 4:
            return @"Dock Alignment";
        case 5:
            return @"Carplay Icons";
        default:
            break;
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == tableView.numberOfSections - 1)
    {
        return @"By estrogencat, built on carplay-cast by Ethan Arbuckle";
    }
    section -= 1;
    if (section == 1)
    {
        return @"On: apps open next to CarPlay's own sidebar and close with its home button, like built-in CarPlay apps. Off: apps open full screen with their own dock (home, fullscreen and rotate buttons). Applies the next time an app opens.";
    }
    if (section == 2)
    {
        return @"Size: smaller fits more on the car screen, larger is easier to read. iPad Layout: apps start as iPad apps on the car (sidebars, split views); one already open restarts. Most apps only switch at 70 or below, where the car screen is wide enough. Not for iPhone-only apps. Both apply the next time an app opens. Permission Prompts on Car: while an app is open on the car, its permission prompts and other system alerts show there instead of on the phone.";
    }
    if (section == 3)
    {
        return @"Smaller fits more rows of icons.";
    }
    if (section == 4)
    {
        return @"Only used when Native CarPlay Look is off.";
    }
    return nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    switch (indexPath.section - 1)
    {
        case 0:
        {
            if (!_appListController)
            {
                break;
            }
            [[self navigationController] pushViewController:_appListController animated:YES];
            break;
        }
        case 4:
        {
            [[CRPreferences sharedInstance] updateValue:@(indexPath.row) forPreferenceKey:@"dockAlignment"];
            [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotification:[NSNotification notificationWithName:PREFERENCES_CHANGED_NOTIFICATION object:kPrefsDockAlignmentChanged]];
            break;
        }
        default:
            break;
    }

    [_rootTable reloadData];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (void)nativeLookSwitchChanged:(UISwitch *)sender
{
    [[CRPreferences sharedInstance] updateValue:@(sender.isOn) forPreferenceKey:@"nativeCarplayLook"];
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotification:[NSNotification notificationWithName:PREFERENCES_CHANGED_NOTIFICATION object:kPrefsNativeLookChanged]];
}

static NSArray<NSNumber *> *CRScaleSteps(void)
{
    return @[@0.6, @0.7, @0.8, @0.9, @1.0, @1.1, @1.2];
}

- (UISegmentedControl *)scaleControlForKey:(NSString *)key value:(CGFloat)value
{
    NSMutableArray *titles = [NSMutableArray array];
    NSInteger selected = 4;
    for (NSNumber *step in CRScaleSteps())
    {
        if (fabs(step.doubleValue - value) < 0.01)
        {
            selected = titles.count;
        }
        [titles addObject:[NSString stringWithFormat:@"%.0f", step.doubleValue * 100]];
    }
    UISegmentedControl *control = [[UISegmentedControl alloc] initWithItems:titles];
    control.selectedSegmentIndex = selected;
    control.accessibilityIdentifier = key;
    [control addTarget:self action:@selector(scaleControlChanged:) forControlEvents:UIControlEventValueChanged];
    [control sizeToFit];
    return control;
}

- (void)scaleControlChanged:(UISegmentedControl *)sender
{
    NSString *key = sender.accessibilityIdentifier;
    [[CRPreferences sharedInstance] updateValue:CRScaleSteps()[sender.selectedSegmentIndex] forPreferenceKey:key];
    if ([key isEqualToString:@"homeScreenScale"])
    {
        [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotification:[NSNotification notificationWithName:PREFERENCES_CHANGED_NOTIFICATION object:kPrefsHomeScreenScaleChanged]];
    }
}

- (void)iPadLayoutSwitchChanged:(UISwitch *)sender
{
    [[CRPreferences sharedInstance] updateValue:@(sender.isOn) forPreferenceKey:@"iPadAppLayout"];
}

- (void)alertsOnCarSwitchChanged:(UISwitch *)sender
{
    [[CRPreferences sharedInstance] updateValue:@(sender.isOn) forPreferenceKey:@"alertsOnCar"];
}

- (void)dockSwitchChanged:(UISwitch *)sender
{
    [[CRPreferences sharedInstance] updateValue:@(sender.isOn) forPreferenceKey:sender.tag == 2 ? @"pinSpringBoardInDock" : @"fiveDockIcons"];
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotification:[NSNotification notificationWithName:PREFERENCES_CHANGED_NOTIFICATION object:kPrefsDockChanged]];
}

- (void)iconLayoutSwitchChanged:(UISwitch *)sender
{
    [[CRPreferences sharedInstance] updateValue:@(sender.isOn) forPreferenceKey:@"fiveColumnIconLayout"];
    [[objc_getClass("NSDistributedNotificationCenter") defaultCenter] postNotification:[NSNotification notificationWithName:PREFERENCES_CHANGED_NOTIFICATION object:kPrefsIconLayoutChanged]];
}

@end
