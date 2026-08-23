#import <Flutter/Flutter.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Native iOS chrome around the existing Flutter feature surface.
///
/// A single FlutterViewController is retained so every existing plugin,
/// MethodChannel, account service, and player keeps the same engine lifecycle.
@interface PiliNativeContainerViewController : UIViewController

- (instancetype)initWithFlutterViewController:
    (FlutterViewController *)flutterViewController NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithNibName:(nullable NSString *)nibNameOrNil
                          bundle:(nullable NSBundle *)nibBundleOrNil
    NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
