import Flutter
import UIKit

final class PiliNativePlayerControlsFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    let parameters = args as? [String: Any] ?? [:]
    return PiliNativePlayerControlPlatformView(
      frame: frame,
      messenger: messenger,
      parameters: parameters
    )
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

private final class PiliNativePlayerControlPlatformView: NSObject, FlutterPlatformView {
  private enum Kind: String {
    case header
    case bottom
  }

  private let rootView: UIView
  private let channel: FlutterMethodChannel
  private let kind: Kind

  private let backButton = UIButton(type: .system)
  private let homeButton = UIButton(type: .system)
  private let titleLabel = UILabel()
  private let settingsButton = UIButton(type: .system)
  private let danmakuButton = UIButton(type: .system)

  private let playContainer = UIView()
  private let playButton = UIButton(type: .system)
  private let bufferingIndicator = UIActivityIndicatorView(style: .medium)
  private let timeLabel = UILabel()
  private let slider = UISlider()
  private let fullscreenButton = UIButton(type: .system)

  init(
    frame: CGRect,
    messenger: FlutterBinaryMessenger,
    parameters: [String: Any]
  ) {
    rootView = UIView(frame: frame)
    let channelName = parameters["channel"] as? String
      ?? "piliglass/native_player_controls/unavailable"
    channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    kind = Kind(rawValue: parameters["kind"] as? String ?? "bottom") ?? .bottom
    super.init()

    configureRootView()
    if kind == .header {
      configureHeader()
    } else {
      configureBottom()
    }
    configureChannel()
  }

  deinit {
    channel.setMethodCallHandler(nil)
  }

  func view() -> UIView {
    rootView
  }

  private func configureRootView() {
    rootView.backgroundColor = .clear
    rootView.isOpaque = false

    let blurView = UIVisualEffectView(
      effect: UIBlurEffect(style: .systemUltraThinMaterialDark)
    )
    blurView.alpha = 0.72
    blurView.isUserInteractionEnabled = false
    blurView.translatesAutoresizingMaskIntoConstraints = false
    rootView.addSubview(blurView)
    NSLayoutConstraint.activate([
      blurView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
      blurView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
      blurView.topAnchor.constraint(equalTo: rootView.topAnchor),
      blurView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
    ])
  }

  private func configureHeader() {
    configureIconButton(
      backButton,
      symbol: "chevron.backward",
      accessibilityLabel: "返回",
      action: #selector(backPressed)
    )
    configureIconButton(
      homeButton,
      symbol: "house",
      accessibilityLabel: "返回主页",
      action: #selector(homePressed)
    )
    configureIconButton(
      danmakuButton,
      symbol: "text.bubble.fill",
      accessibilityLabel: "切换弹幕",
      action: #selector(danmakuPressed)
    )
    configureIconButton(
      settingsButton,
      symbol: "ellipsis.circle",
      accessibilityLabel: "更多设置",
      action: #selector(settingsPressed)
    )

    titleLabel.textColor = .white
    titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.numberOfLines = 1
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let stack = UIStackView(arrangedSubviews: [
      backButton,
      homeButton,
      titleLabel,
      danmakuButton,
      settingsButton,
    ])
    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = 5
    stack.translatesAutoresizingMaskIntoConstraints = false
    rootView.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 8),
      stack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -8),
      stack.topAnchor.constraint(greaterThanOrEqualTo: rootView.topAnchor, constant: 4),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: rootView.bottomAnchor, constant: -4),
      stack.centerYAnchor.constraint(equalTo: rootView.centerYAnchor),
    ])
  }

  private func configureBottom() {
    playContainer.translatesAutoresizingMaskIntoConstraints = false
    playContainer.widthAnchor.constraint(equalToConstant: 38).isActive = true
    playContainer.heightAnchor.constraint(equalToConstant: 36).isActive = true

    configureIconButton(
      playButton,
      symbol: "pause.fill",
      accessibilityLabel: "暂停",
      action: #selector(playPressed)
    )
    playButton.translatesAutoresizingMaskIntoConstraints = false
    playContainer.addSubview(playButton)

    bufferingIndicator.color = .white
    bufferingIndicator.hidesWhenStopped = true
    bufferingIndicator.translatesAutoresizingMaskIntoConstraints = false
    playContainer.addSubview(bufferingIndicator)

    NSLayoutConstraint.activate([
      playButton.leadingAnchor.constraint(equalTo: playContainer.leadingAnchor),
      playButton.trailingAnchor.constraint(equalTo: playContainer.trailingAnchor),
      playButton.topAnchor.constraint(equalTo: playContainer.topAnchor),
      playButton.bottomAnchor.constraint(equalTo: playContainer.bottomAnchor),
      bufferingIndicator.centerXAnchor.constraint(equalTo: playContainer.centerXAnchor),
      bufferingIndicator.centerYAnchor.constraint(equalTo: playContainer.centerYAnchor),
    ])

    timeLabel.text = "00:00 / 00:00"
    timeLabel.textColor = .white
    timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    timeLabel.textAlignment = .center
    timeLabel.setContentHuggingPriority(.required, for: .horizontal)

    slider.minimumValue = 0
    slider.maximumValue = 1
    slider.minimumTrackTintColor = .systemPink
    slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.32)
    slider.thumbTintColor = .white
    slider.isContinuous = true
    slider.accessibilityLabel = "播放进度"
    slider.addTarget(self, action: #selector(seekBegan), for: .touchDown)
    slider.addTarget(self, action: #selector(seekChanged), for: .valueChanged)
    slider.addTarget(
      self,
      action: #selector(seekEnded),
      for: [.touchUpInside, .touchUpOutside, .touchCancel]
    )
    slider.setContentHuggingPriority(.defaultLow, for: .horizontal)

    configureIconButton(
      danmakuButton,
      symbol: "text.bubble.fill",
      accessibilityLabel: "切换弹幕",
      action: #selector(danmakuPressed)
    )
    configureIconButton(
      fullscreenButton,
      symbol: "arrow.up.left.and.arrow.down.right",
      accessibilityLabel: "进入全屏",
      action: #selector(fullscreenPressed)
    )

    let stack = UIStackView(arrangedSubviews: [
      playContainer,
      timeLabel,
      slider,
      danmakuButton,
      fullscreenButton,
    ])
    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = 6
    stack.translatesAutoresizingMaskIntoConstraints = false
    rootView.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 8),
      stack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -8),
      stack.topAnchor.constraint(greaterThanOrEqualTo: rootView.topAnchor, constant: 4),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: rootView.bottomAnchor, constant: -8),
      stack.centerYAnchor.constraint(equalTo: rootView.centerYAnchor),
      slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 42),
    ])
  }

  private func configureIconButton(
    _ button: UIButton,
    symbol: String,
    accessibilityLabel: String,
    action: Selector
  ) {
    button.tintColor = .white
    button.setImage(UIImage(systemName: symbol), for: .normal)
    button.accessibilityLabel = accessibilityLabel
    button.addTarget(self, action: action, for: .primaryActionTriggered)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.widthAnchor.constraint(equalToConstant: 36).isActive = true
    button.heightAnchor.constraint(equalToConstant: 36).isActive = true
  }

  private func configureChannel() {
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "updateState",
            let state = call.arguments as? [String: Any]
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.apply(state: state)
      result(nil)
    }

    DispatchQueue.main.async { [weak self] in
      self?.channel.invokeMethod("ready", arguments: nil)
    }
  }

  private func apply(state: [String: Any]) {
    let playing = boolean(state["isPlaying"])
    let buffering = boolean(state["isBuffering"])
    let fullscreen = boolean(state["isFullscreen"])
    let danmakuEnabled = boolean(state["danmakuEnabled"])
    let position = number(state["position"])
    let duration = max(number(state["duration"]), 0)

    titleLabel.text = state["title"] as? String ?? ""
    updateDanmakuButton(enabled: danmakuEnabled)

    let playSymbol = playing ? "pause.fill" : "play.fill"
    playButton.setImage(UIImage(systemName: playSymbol), for: .normal)
    playButton.accessibilityLabel = playing ? "暂停" : "播放"

    if buffering {
      bufferingIndicator.startAnimating()
      playButton.alpha = 0.2
    } else {
      bufferingIndicator.stopAnimating()
      playButton.alpha = 1
    }

    if !slider.isTracking {
      slider.maximumValue = Float(max(duration, 1))
      slider.value = Float(min(max(position, 0), max(duration, 1)))
    }
    timeLabel.text = "\(format(seconds: position)) / \(format(seconds: duration))"

    let fullscreenSymbol = fullscreen
      ? "arrow.down.right.and.arrow.up.left"
      : "arrow.up.left.and.arrow.down.right"
    fullscreenButton.setImage(UIImage(systemName: fullscreenSymbol), for: .normal)
    fullscreenButton.accessibilityLabel = fullscreen ? "退出全屏" : "进入全屏"
  }

  private func updateDanmakuButton(enabled: Bool) {
    let symbol = enabled ? "text.bubble.fill" : "text.bubble"
    danmakuButton.setImage(UIImage(systemName: symbol), for: .normal)
    danmakuButton.tintColor = enabled ? .white : UIColor.white.withAlphaComponent(0.48)
    danmakuButton.accessibilityLabel = enabled ? "关闭弹幕" : "开启弹幕"
  }

  private func sendAction(_ name: String, value: Any? = nil) {
    var arguments: [String: Any] = ["name": name]
    if let value {
      arguments["value"] = value
    }
    channel.invokeMethod("action", arguments: arguments)
  }

  @objc private func backPressed() { sendAction("back") }
  @objc private func homePressed() { sendAction("home") }
  @objc private func settingsPressed() { sendAction("settings") }
  @objc private func playPressed() { sendAction("togglePlay") }
  @objc private func fullscreenPressed() { sendAction("toggleFullscreen") }
  @objc private func danmakuPressed() { sendAction("toggleDanmaku") }
  @objc private func seekBegan() { sendAction("beginSeek") }

  @objc private func seekChanged() {
    timeLabel.text = "\(format(seconds: Int(slider.value))) / \(format(seconds: Int(slider.maximumValue)))"
  }

  @objc private func seekEnded() {
    sendAction("seek", value: Int(slider.value.rounded()))
  }

  private func boolean(_ value: Any?) -> Bool {
    (value as? NSNumber)?.boolValue ?? false
  }

  private func number(_ value: Any?) -> Int {
    (value as? NSNumber)?.intValue ?? 0
  }

  private func format(seconds: Int) -> String {
    let safeSeconds = max(seconds, 0)
    let hours = safeSeconds / 3600
    let minutes = (safeSeconds % 3600) / 60
    let remainder = safeSeconds % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, remainder)
    }
    return String(format: "%02d:%02d", minutes, remainder)
  }
}
