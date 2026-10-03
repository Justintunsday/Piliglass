import Flutter
import UIKit

final class PiliNativeFlutterPlayerSurface {
  private let flutterViewController: FlutterViewController
  private weak var homeController: UIViewController?
  private var homeConstraints: [NSLayoutConstraint] = []

  init(flutterViewController: FlutterViewController) {
    self.flutterViewController = flutterViewController
  }

  func install(in homeController: UIViewController) {
    self.homeController = homeController
    let flutterView = flutterViewController.view!
    flutterView.translatesAutoresizingMaskIntoConstraints = false
    homeController.addChild(flutterViewController)
    homeController.view.addSubview(flutterView)
    homeConstraints = [
      flutterView.topAnchor.constraint(equalTo: homeController.view.topAnchor),
      flutterView.leadingAnchor.constraint(equalTo: homeController.view.leadingAnchor),
      flutterView.trailingAnchor.constraint(equalTo: homeController.view.trailingAnchor),
      flutterView.bottomAnchor.constraint(equalTo: homeController.view.bottomAnchor),
    ]
    NSLayoutConstraint.activate(homeConstraints)
    flutterViewController.didMove(toParent: homeController)
  }

  func restore(hidden: Bool) {
    if let homeController, flutterViewController.parent !== homeController {
      NSLayoutConstraint.deactivate(homeConstraints)
      homeConstraints = []
      detachFlutterController()
      homeController.addChild(flutterViewController)
      let flutterView = flutterViewController.view!
      flutterView.translatesAutoresizingMaskIntoConstraints = false
      homeController.view.insertSubview(flutterView, at: 0)
      NSLayoutConstraint.activate(homeConstraints)
      flutterViewController.didMove(toParent: homeController)
    }
    flutterViewController.view.isHidden = hidden
  }

  private func detachFlutterController() {
    guard flutterViewController.parent != nil else {
      flutterViewController.view.removeFromSuperview()
      return
    }
    flutterViewController.willMove(toParent: nil)
    flutterViewController.view.removeFromSuperview()
    flutterViewController.removeFromParent()
  }
}
