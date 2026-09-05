"""Test the production UIKit player controls with offline engine fixtures.

Uses the real controller, gesture recognizers, slider and speed state methods;
only media decoding/network/danmaku services are replaced. Run after home preview
on macOS. Screenshots and XCTest results go to build/player-controls-preview.
"""
import json
from pathlib import Path
import platform
import preview_ios_navigation as navigation

ROOT = Path(__file__).resolve().parents[1]

FIXTURES = r'''
import AVFoundation
import AVKit
import Combine
import SwiftUI
import UIKit

final class PreviewEngine {
  var nativePlayerLayer: AVPlayerLayer? { nil }
  var rates: [Float] = []
  func setRate(_ rate: Float) { rates.append(rate) }
}
final class AetherPlayerView: UIView {
  override class var layerClass: AnyClass { CAGradientLayer.self }
  override init(frame: CGRect) {
    super.init(frame: frame)
    let gradient = layer as! CAGradientLayer
    gradient.colors = [UIColor(red: 0.12, green: 0.2, blue: 0.3, alpha: 1).cgColor,
                       UIColor(red: 0.38, green: 0.25, blue: 0.19, alpha: 1).cgColor]
    gradient.startPoint = CGPoint(x: 0, y: 0)
    gradient.endPoint = CGPoint(x: 1, y: 1)
  }
  required init?(coder: NSCoder) { fatalError() }
}
struct PiliNativePlayerQuality { let value: Int; let label: String }
struct PiliNativeSubtitleOption: Identifiable, Equatable {
  let id: String
  let label: String
}
final class PiliNativeDanmakuView: UIView {
  func applySettings(_ settings: Int) {}
  func clear() {}
  func render(time: Double, items: [Int], revision: Int) {}
}
struct PiliNativeDanmakuSettingsView: View {
  let session: PiliNativePlayerSession
  let close: () -> Void
  var body: some View { Button("关闭设置", action: close) }
}
@MainActor
final class PiliNativePlayerSession: ObservableObject {
  @Published var isReady = true
  @Published var isPlaying = true
  @Published var isBuffering = false
  @Published var errorMessage: String?
  @Published var duration: Double = 194
  @Published var currentTime: Double = 61
  @Published var danmakuEnabled = true
  @Published var danmakuRevision = 0
  @Published var danmakuSettings = 0
  @Published var danmakuRules: [Int] = []
  let danmakuItems: [Int] = []
  let danmakuSettingsLoaded = true
  @Published var qualityLabel = "720P"
  @Published var qualities = [PiliNativePlayerQuality(value: 64, label: "720P")]
  @Published var subtitleOptions = [PiliNativeSubtitleOption(id: "zh-CN", label: "中文")]
  @Published var selectedSubtitleID: String?
  @Published var playbackRate: Float = 1.5
  @Published var temporaryDoubleSpeedActive = false
  private var playbackRateBeforeHold: Float?
  @Published var pictureInPicturePlayer: AVPlayer?
  @Published var videoTitle = "山海之间，记录旅途的风景"
  @Published var videoLikeCount = 2820
  @Published var videoReplyCount = 15
  @Published var videoFavoriteCount = 10
  @Published var videoShareCount = 32
  @Published var videoOwnerName = "PiliGlass 播放器预览"
  @Published var videoOwnerFaceURL = ""
  @Published var danmakuStatusMessage: String?
  @Published var danmakuComposerRequest = 0
  @Published var isFullscreen = true
  let videoIsVertical = false
  let engine = PreviewEngine()
  let audioEngine = PreviewEngine()
  let hasAudioTrack = true
  func bindVideoSurface(_ view: UIView) {}
  func unbindVideoSurface(_ view: UIView) {}
  func pausePlayback() { endTemporaryDoubleSpeed(); isPlaying = false }
  func togglePlayback() { isPlaying ? pausePlayback() : (isPlaying = true) }
  func seek(to time: Double, autoplay: Bool?) {
    currentTime = time
    isPlaying = autoplay ?? isPlaying
  }
  func selectQuality(_ value: Int) {}
  func selectSubtitle(_ id: String?) { selectedSubtitleID = id }
  func requestVideoAction(_ action: String) {}
  func requestDanmakuSend(_ content: String) {}
  func toggleFullscreenComments() {}
  func updateNowPlayingInfo(force: Bool = false) {}
  // PRODUCTION_SPEED_METHODS
}
@main
final class PlayerPreviewApp: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  let session = PiliNativePlayerSession()
  let probe = UILabel()
  var observation: AnyCancellable?
  var embedded: Bool { ProcessInfo.processInfo.arguments.contains("embedded") }

  func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    let controller = PiliNativePlayerViewController(session: session, fullscreen: !embedded)
    // Use the UIKit controller as the window root so its supported orientations
    // apply directly, without a SwiftUI preview host retaining a portrait frame.
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = controller
    self.window = window
    window.makeKeyAndVisible()
    probe.translatesAutoresizingMaskIntoConstraints = false
    probe.font = .systemFont(ofSize: 8)
    probe.textColor = .white.withAlphaComponent(0.3)
    probe.accessibilityIdentifier = "playback-state"
    probe.isUserInteractionEnabled = false
    controller.view.addSubview(probe)
    NSLayoutConstraint.activate([
      probe.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
      probe.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor),
    ])
    observation = session.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
      self?.updateProbe()
    }
    updateProbe()
    return true
  }

  func application(_ application: UIApplication,
                   supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
    embedded ? .portrait : .landscape
  }

  func updateProbe() {
    probe.text = "playing=\(session.isPlaying);rate=\(session.playbackRate);time=\(Int(session.currentTime));rates=\(session.engine.rates)"
  }
}
'''

TESTS = r'''
import XCTest
final class PlayerControlsTests: XCTestCase {
  let app = XCUIApplication()
  var state: XCUIElement { app.staticTexts["playback-state"] }
  override func setUpWithError() throws {
    continueAfterFailure = false
  }
  func launch(embedded: Bool = false) {
    XCUIDevice.shared.orientation = embedded ? .portrait : .landscapeLeft
    app.launchArguments = embedded ? ["embedded"] : []
    app.launch()
    XCTAssertTrue(state.waitForExistence(timeout: 10))
    if !embedded {
      let landscape = NSPredicate { _, _ in self.app.frame.width > self.app.frame.height }
      expectation(for: landscape, evaluatedWith: app)
      waitForExpectations(timeout: 10)
      XCTAssertTrue(app.buttons["720P"].waitForExistence(timeout: 8))
    }
  }
  func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  func exerciseGestures() {
    // Tap either half of the video: neither gesture may seek by ten seconds.
    let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.5))
    let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
    left.doubleTap()
    XCTAssertTrue(state.label.contains("playing=false"))
    XCTAssertTrue(state.label.contains("time=61"))
    right.doubleTap()
    XCTAssertTrue(state.label.contains("playing=true"))
    XCTAssertTrue(state.label.contains("time=61"))
    right.press(forDuration: 0.8)
    XCTAssertTrue(state.label.contains("rates=[2.0, 1.5]"), state.label)
    XCTAssertTrue(state.label.contains("rate=1.5"))
    XCTAssertTrue(state.label.contains("playing=true"))
    left.doubleTap()
    right.press(forDuration: 0.8)
    XCTAssertTrue(state.label.contains("playing=false"))
    XCTAssertTrue(state.label.contains("rates=[2.0, 1.5]"), "A paused video must not boost")
    let slider = app.sliders["播放进度"]
    // A rejected long press on a paused video may toggle the chrome as a
    // single tap. Resume then pause to explicitly reveal it before scrubbing.
    left.doubleTap()
    left.doubleTap()
    XCTAssertTrue(state.label.contains("playing=false"))
    XCTAssertTrue(slider.waitForExistence(timeout: 8), "Keep the native accessible UISlider")
    slider.adjust(toNormalizedSliderPosition: 0.75)
    XCTAssertTrue(state.label.contains("playing=false"), "Scrubbing must preserve pause")
  }
  func testLandscapeLayoutAndGestures() {
    launch()
    screenshot("landscape-native-player")
    exerciseGestures()
    app.buttons["锁定播放器"].tap()
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).doubleTap()
    XCTAssertTrue(state.label.contains("playing=false"))
    screenshot("landscape-player-locked")
  }
  func testEmbeddedGestures() {
    launch(embedded: true)
    exerciseGestures()
    screenshot("embedded-player-controls")
  }
}
'''


def production_swift():
    source = (ROOT / 'ios/Runner/PiliNativePlayer.swift').read_text(encoding='utf-8')
    speed = source[source.index('  func cyclePlaybackRate() {'):source.index('  func selectQuality(')]
    controls = source[source.index('private final class PiliNativePlayerGradientView:'):
                      source.index('struct PiliNativePlayerView:')]
    preferences = source[source.index('enum PiliNativePlaybackEndMode:'):
                         source.index('@MainActor\nfinal class PiliNativePlayerSession')]
    return FIXTURES.replace('// PRODUCTION_SPEED_METHODS', speed) + preferences + controls


if __name__ == '__main__':
    if platform.system() != 'Darwin':
        raise SystemExit('Player control UI tests require macOS and Xcode.')
    devices = json.loads(navigation.home.run('xcrun', 'simctl', 'list', 'devices', 'available', '-j'))['devices']
    phones = [device for runtime in devices.values() for device in runtime if 'iPhone' in device['name']]
    device = next((phone for phone in phones if phone['state'] == 'Booted'), phones[0])
    if device['state'] != 'Booted':
        navigation.home.run('xcrun', 'simctl', 'boot', device['udid'])
    navigation.home.run('xcrun', 'simctl', 'bootstatus', device['udid'], '-b')
    navigation.OUTPUT = ROOT / 'build/player-controls-preview'
    navigation.BUNDLE_ID = 'dev.piliglass.playerpreview'
    navigation.production_swift = production_swift
    navigation.TESTS = TESTS
    navigation.main()
