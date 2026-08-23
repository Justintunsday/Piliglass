import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(
      scene,
      willConnectTo: session,
      options: connectionOptions
    )

    guard
      let flutterViewController = window?.rootViewController as? FlutterViewController
    else {
      return
    }

    window?.rootViewController = PiliNativeRootViewController(
      flutterViewController: flutterViewController
    )
    window?.makeKeyAndVisible()
  }

  @available(iOS 26.0, *)
  override func preferredWindowingControlStyle(
    for windowScene: UIWindowScene
  ) -> UIWindowScene.WindowingControlStyle {
    return .minimal
  }
}
