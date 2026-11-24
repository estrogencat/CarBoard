#include "CRERootListController.h"
#include "../src/common.h"

@implementation CRERootListController

- (id)initForContentSize:(CGSize)size
{
    if ((self = [super init]))
    {
        [self setTitle:@"CarPlayEnable Preferences"];
        _rootTable = [[UITableView alloc] initWithFrame:[[self view] bounds] style:UITableViewStyleGrouped];
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
    return 6;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section)
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
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"com.carplay.rootcell"];
    if (cell == nil)
    {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"com.carplay.rootcell"];
    }

    if (indexPath.section == 0)
    {
        if (indexPath.row == 0)
        {
            [[cell textLabel] setText:@"Add/Remove Apps"];
            [cell setAccessoryView:nil];
            [cell setAccessoryType:UITableViewCellAccessoryDisclosureIndicator];
        }
    }
    else if (indexPath.section == 1)
    {
        [[cell textLabel] setText:@"Native CarPlay Look"];
        UISwitch *cellSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
        [cellSwitch setOn:[[CRPreferences sharedInstance] nativeCarplayLook] animated:NO];
        [cellSwitch addTarget:self action:@selector(nativeLookSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        [cell setAccessoryView:cellSwitch];
        [cell setAccessoryType:UITableViewCellAccessoryNone];
    }
    else if (indexPath.section == 2 && indexPath.row == 0)
    {
        [[cell textLabel] setText:@"Size %"];
        [cell setAccessoryView:[self scaleControlForKey:@"appScale" value:[[CRPreferences sharedInstance] appScale]]];
        [cell setAccessoryType:UITableViewCellAccessoryNone];
    }
    else if (indexPath.section == 2)
    {
        BOOL promptsRow = indexPath.row == 2;
        [[cell textLabel] setText:promptsRow ? @"Permission Prompts on Car" : @"iPad Layout"];
        UISwitch *cellSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
        [cellSwitch setOn:promptsRow ? [[CRPreferences sharedInstance] alertsOnCar] : [[CRPreferences sharedInstance] iPadAppLayout] animated:NO];
        [cellSwitch addTarget:self action:promptsRow ? @selector(alertsOnCarSwitchChanged:) : @selector(iPadLayoutSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        [cell setAccessoryView:cellSwitch];
        [cell setAccessoryType:UITableViewCellAccessoryNone];
    }
    else if (indexPath.section == 3)
    {
        [[cell textLabel] setText:@"Size %"];
        [cell setAccessoryView:[self scaleControlForKey:@"homeScreenScale" value:[[CRPreferences sharedInstance] homeScreenScale]]];
        [cell setAccessoryType:UITableViewCellAccessoryNone];
    }
    else if (indexPath.section == 4)
    {
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
    switch (section)
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
    return @"";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
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
    if (section == tableView.numberOfSections - 1)
    {
        return @"Created by Ethan Arbuckle";
    }
    return @"";
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    switch (indexPath.section)
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
