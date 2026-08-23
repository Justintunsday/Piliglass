#import "PiliNativeContainerViewController.h"

static NSString *const PiliNativeUIChannelName = @"piliglass/native_ui";

@interface PiliNativeContainerViewController () <UITabBarDelegate>

@property(nonatomic, strong) FlutterViewController *flutterViewController;
@property(nonatomic, strong) FlutterMethodChannel *channel;
@property(nonatomic, strong) UINavigationBar *navigationBar;
@property(nonatomic, strong) UINavigationItem *navigationItem;
@property(nonatomic, strong) UITabBar *tabBar;
@property(nonatomic, strong) NSLayoutConstraint *tabBarHeightConstraint;
@property(nonatomic, strong) NSLayoutConstraint *flutterTopConstraint;
@property(nonatomic, strong) NSLayoutConstraint *flutterBottomConstraint;
@property(nonatomic, strong) NSLayoutConstraint *fullscreenTopConstraint;
@property(nonatomic, strong) NSLayoutConstraint *fullscreenBottomConstraint;
@property(nonatomic, copy) NSArray<NSString *> *tabTitles;

@end

@implementation PiliNativeContainerViewController

- (instancetype)initWithFlutterViewController:
    (FlutterViewController *)flutterViewController {
  self = [super initWithNibName:nil bundle:nil];
  if (self) {
    _flutterViewController = flutterViewController;
    _tabTitles = @[ @"首页", @"动态", @"我的" ];
  }
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.systemBackgroundColor;

  [self installNativeNavigationBar];
  [self installFlutterSurface];
  [self installNativeTabBar];
  [self installChannel];
  [self applyNativeAppearance];
  [self rebuildTabItemsWithTitles:self.tabTitles selectedIndex:0];
  [self updateNavigationForIndex:0];
}

- (void)viewSafeAreaInsetsDidChange {
  [super viewSafeAreaInsetsDidChange];
  self.tabBarHeightConstraint.constant = 49.0 + self.view.safeAreaInsets.bottom;
}

- (UIViewController *)childViewControllerForStatusBarStyle {
  return self.flutterViewController;
}

- (UIViewController *)childViewControllerForStatusBarHidden {
  return self.flutterViewController;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
  [super traitCollectionDidChange:previousTraitCollection];
  [self applyNativeAppearance];
}

- (void)installNativeNavigationBar {
  self.navigationBar = [[UINavigationBar alloc] initWithFrame:CGRectZero];
  self.navigationBar.translatesAutoresizingMaskIntoConstraints = NO;
  self.navigationItem = [[UINavigationItem alloc] initWithTitle:@"PiliGlass"];
  [self.navigationBar setItems:@[ self.navigationItem ] animated:NO];
  [self.view addSubview:self.navigationBar];

  [NSLayoutConstraint activateConstraints:@[
    [self.navigationBar.topAnchor
        constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
    [self.navigationBar.leadingAnchor
        constraintEqualToAnchor:self.view.leadingAnchor],
    [self.navigationBar.trailingAnchor
        constraintEqualToAnchor:self.view.trailingAnchor],
    [self.navigationBar.heightAnchor constraintEqualToConstant:44.0],
  ]];
}

- (void)installFlutterSurface {
  [self addChildViewController:self.flutterViewController];
  UIView *flutterView = self.flutterViewController.view;
  flutterView.translatesAutoresizingMaskIntoConstraints = NO;
  flutterView.backgroundColor = UIColor.clearColor;
  [self.view addSubview:flutterView];
  [self.flutterViewController didMoveToParentViewController:self];
}

- (void)installNativeTabBar {
  self.tabBar = [[UITabBar alloc] initWithFrame:CGRectZero];
  self.tabBar.translatesAutoresizingMaskIntoConstraints = NO;
  self.tabBar.delegate = self;
  [self.view addSubview:self.tabBar];

  self.tabBarHeightConstraint =
      [self.tabBar.heightAnchor constraintEqualToConstant:49.0];
  UIView *flutterView = self.flutterViewController.view;
  self.flutterTopConstraint = [flutterView.topAnchor
      constraintEqualToAnchor:self.navigationBar.bottomAnchor];
  self.flutterBottomConstraint =
      [flutterView.bottomAnchor constraintEqualToAnchor:self.tabBar.topAnchor];
  self.fullscreenTopConstraint =
      [flutterView.topAnchor constraintEqualToAnchor:self.view.topAnchor];
  self.fullscreenBottomConstraint =
      [flutterView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor];
  [NSLayoutConstraint activateConstraints:@[
    self.flutterTopConstraint,
    [flutterView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [flutterView.trailingAnchor
        constraintEqualToAnchor:self.view.trailingAnchor],
    self.flutterBottomConstraint,
    [self.tabBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [self.tabBar.trailingAnchor
        constraintEqualToAnchor:self.view.trailingAnchor],
    [self.tabBar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    self.tabBarHeightConstraint,
  ]];
}

- (void)installChannel {
  self.channel = [FlutterMethodChannel
      methodChannelWithName:PiliNativeUIChannelName
            binaryMessenger:self.flutterViewController.binaryMessenger];

  __weak typeof(self) weakSelf = self;
  [self.channel setMethodCallHandler:^(FlutterMethodCall *call,
                                       FlutterResult result) {
    __strong typeof(weakSelf) self = weakSelf;
    if (!self) {
      result(FlutterMethodNotImplemented);
      return;
    }

    if ([call.method isEqualToString:@"configure"]) {
      NSDictionary *arguments = [call.arguments isKindOfClass:NSDictionary.class]
                                    ? call.arguments
                                    : @{};
      NSArray *titles = [arguments[@"titles"] isKindOfClass:NSArray.class]
                            ? arguments[@"titles"]
                            : self.tabTitles;
      NSInteger selectedIndex = [arguments[@"selectedIndex"] integerValue];
      [self rebuildTabItemsWithTitles:titles selectedIndex:selectedIndex];
      result(nil);
      return;
    }

    if ([call.method isEqualToString:@"setSelectedIndex"]) {
      NSInteger index = [call.arguments integerValue];
      [self selectTabAtIndex:index notifyFlutter:NO];
      result(nil);
      return;
    }

    if ([call.method isEqualToString:@"setBadge"]) {
      NSDictionary *arguments = [call.arguments isKindOfClass:NSDictionary.class]
                                    ? call.arguments
                                    : @{};
      NSInteger index = [arguments[@"index"] integerValue];
      NSString *value = [arguments[@"value"] isKindOfClass:NSString.class]
                            ? arguments[@"value"]
                            : nil;
      if (index >= 0 && index < self.tabBar.items.count) {
        self.tabBar.items[index].badgeValue = value.length > 0 ? value : nil;
      }
      result(nil);
      return;
    }

    if ([call.method isEqualToString:@"setChromeVisible"]) {
      [self setNativeChromeVisible:[call.arguments boolValue]];
      result(nil);
      return;
    }

    result(FlutterMethodNotImplemented);
  }];
}

- (void)setNativeChromeVisible:(BOOL)visible {
  if (visible == !self.navigationBar.hidden) {
    return;
  }

  if (visible) {
    [NSLayoutConstraint deactivateConstraints:@[
      self.fullscreenTopConstraint,
      self.fullscreenBottomConstraint,
    ]];
    self.navigationBar.hidden = NO;
    self.tabBar.hidden = NO;
    [NSLayoutConstraint activateConstraints:@[
      self.flutterTopConstraint,
      self.flutterBottomConstraint,
    ]];
  } else {
    [NSLayoutConstraint deactivateConstraints:@[
      self.flutterTopConstraint,
      self.flutterBottomConstraint,
    ]];
    self.navigationBar.hidden = YES;
    self.tabBar.hidden = YES;
    [NSLayoutConstraint activateConstraints:@[
      self.fullscreenTopConstraint,
      self.fullscreenBottomConstraint,
    ]];
  }
  [self.view setNeedsLayout];
  [self.view layoutIfNeeded];
}

- (void)applyNativeAppearance {
  UITabBarAppearance *tabAppearance = [[UITabBarAppearance alloc] init];
  [tabAppearance configureWithDefaultBackground];
  self.tabBar.standardAppearance = tabAppearance;

  UINavigationBarAppearance *navAppearance =
      [[UINavigationBarAppearance alloc] init];
  [navAppearance configureWithDefaultBackground];
  self.navigationBar.standardAppearance = navAppearance;
  self.navigationBar.compactAppearance = navAppearance;

  if (@available(iOS 15.0, *)) {
    self.tabBar.scrollEdgeAppearance = tabAppearance;
    self.navigationBar.scrollEdgeAppearance = navAppearance;
    self.navigationBar.compactScrollEdgeAppearance = navAppearance;
  }
}

- (void)rebuildTabItemsWithTitles:(NSArray *)titles
                    selectedIndex:(NSInteger)selectedIndex {
  NSMutableArray<NSString *> *validTitles = [NSMutableArray array];
  for (id value in titles) {
    if ([value isKindOfClass:NSString.class]) {
      [validTitles addObject:value];
    }
  }
  if (validTitles.count == 0) {
    [validTitles addObjectsFromArray:@[ @"首页", @"动态", @"我的" ]];
  }
  self.tabTitles = validTitles;

  NSMutableArray<UITabBarItem *> *items = [NSMutableArray array];
  [validTitles enumerateObjectsUsingBlock:^(NSString *title, NSUInteger index,
                                             BOOL *stop) {
    NSString *symbol = [self symbolForTitle:title selected:NO];
    NSString *selectedSymbol = [self symbolForTitle:title selected:YES];
    UITabBarItem *item = [[UITabBarItem alloc]
        initWithTitle:title
                image:[UIImage systemImageNamed:symbol]
        selectedImage:[UIImage systemImageNamed:selectedSymbol]];
    item.tag = index;
    [items addObject:item];
  }];
  [self.tabBar setItems:items animated:NO];
  [self selectTabAtIndex:selectedIndex notifyFlutter:NO];
}

- (NSString *)symbolForTitle:(NSString *)title selected:(BOOL)selected {
  if ([title containsString:@"动态"]) {
    return selected ? @"sparkles" : @"sparkles";
  }
  if ([title containsString:@"我"] || [title containsString:@"账号"]) {
    return selected ? @"person.crop.circle.fill" : @"person.crop.circle";
  }
  return selected ? @"house.fill" : @"house";
}

- (void)selectTabAtIndex:(NSInteger)index notifyFlutter:(BOOL)notifyFlutter {
  if (index < 0 || index >= self.tabBar.items.count) {
    return;
  }
  self.tabBar.selectedItem = self.tabBar.items[index];
  [self updateNavigationForIndex:index];
  if (notifyFlutter) {
    [self.channel invokeMethod:@"selectTab" arguments:@(index)];
  }
}

- (void)updateNavigationForIndex:(NSInteger)index {
  NSString *title = index >= 0 && index < self.tabTitles.count
                        ? self.tabTitles[index]
                        : @"PiliGlass";
  self.navigationItem.title = index == 0 ? @"PiliGlass" : title;

  UIBarButtonItem *search = [[UIBarButtonItem alloc]
      initWithImage:[UIImage systemImageNamed:@"magnifyingglass"]
              style:UIBarButtonItemStylePlain
             target:self
             action:@selector(openSearch)];
  self.navigationItem.leftBarButtonItem = index == 0 ? search : nil;

  NSInteger accountIndex = [self indexOfAccountTab];
  UIBarButtonItem *account = [[UIBarButtonItem alloc]
      initWithImage:[UIImage systemImageNamed:@"person.crop.circle"]
              style:UIBarButtonItemStylePlain
             target:self
             action:@selector(openAccount)];
  self.navigationItem.rightBarButtonItem =
      index == accountIndex ? nil : account;
}

- (NSInteger)indexOfAccountTab {
  for (NSUInteger index = 0; index < self.tabTitles.count; index++) {
    NSString *title = self.tabTitles[index];
    if ([title containsString:@"我"] || [title containsString:@"账号"]) {
      return index;
    }
  }
  return MAX((NSInteger)self.tabTitles.count - 1, 0);
}

- (void)openSearch {
  [self.channel invokeMethod:@"openSearch" arguments:nil];
}

- (void)openAccount {
  NSInteger index = [self indexOfAccountTab];
  [self selectTabAtIndex:index notifyFlutter:YES];
}

#pragma mark - UITabBarDelegate

- (void)tabBar:(UITabBar *)tabBar didSelectItem:(UITabBarItem *)item {
  [self selectTabAtIndex:item.tag notifyFlutter:YES];
}

@end
