import Combine
import CoreImage.CIFilterBuiltins
import CoreText
import Flutter
import PhotosUI
import SwiftgramUI
import SwiftUI
import UIKit

private let piliNativeChannelName = "piliglass/native_ui"
private let piliAccent = Color(red: 0.93, green: 0.29, blue: 0.48)

private extension Notification.Name {
  static let piliPresentNativeProfile = Notification.Name("piliglass.presentNativeProfile")
}

// MARK: - Native container

private final class PiliNativeFlutterPlayerSurface {
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

/// Hosts a fully native SwiftUI root interface over the original Flutter root.
///
/// Dart remains alive underneath for login state and request services.
/// SwiftUI owns the interface while the native player owns playback,
/// controls, full-screen presentation and danmaku.
final class PiliNativeRootViewController: UIViewController {
  private let flutterViewController: FlutterViewController
  private lazy var channel = FlutterMethodChannel(
    name: piliNativeChannelName,
    binaryMessenger: flutterViewController.binaryMessenger
  )
  private lazy var flutterPlayerSurface = PiliNativeFlutterPlayerSurface(
    flutterViewController: flutterViewController
  )
  private lazy var model = PiliNativeViewModel(
    channel: channel,
    flutterPlayerSurface: flutterPlayerSurface
  )
  private var hostingController: UIHostingController<PiliNativeRootView>?
  private var isNativeRootVisible = true
  private var allowsVideoLandscape = false

  init(flutterViewController: FlutterViewController) {
    self.flutterViewController = flutterViewController
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    PiliOriginalIconFont.registerBundledFonts()
    view.backgroundColor = .systemBackground
    model.onVideoOrientationPolicyChanged = { [weak self] allowsLandscape in
      self?.updateVideoOrientationPolicy(allowsLandscape)
    }
    installFlutterSurface()
    installNativeSurface()
    installChannel()
  }

  override var childForStatusBarStyle: UIViewController? {
    isNativeRootVisible ? hostingController : flutterViewController
  }

  override var childForStatusBarHidden: UIViewController? {
    isNativeRootVisible ? hostingController : flutterViewController
  }

  override var shouldAutorotate: Bool { true }

  override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
    allowsVideoLandscape ? .landscape : .portrait
  }

  private func updateVideoOrientationPolicy(_ allowsLandscape: Bool) {
    guard allowsVideoLandscape != allowsLandscape else { return }
    allowsVideoLandscape = allowsLandscape
    if #available(iOS 16.0, *) {
      setNeedsUpdateOfSupportedInterfaceOrientations()
      hostingController?.setNeedsUpdateOfSupportedInterfaceOrientations()
      if let scene = view.window?.windowScene {
        scene.requestGeometryUpdate(
          .iOS(interfaceOrientations: allowsLandscape ? .landscape : .portrait)
        )
      }
    } else {
      UIDevice.current.setValue(
        (allowsLandscape ? UIInterfaceOrientation.landscapeRight : .portrait).rawValue,
        forKey: "orientation"
      )
      UIViewController.attemptRotationToDeviceOrientation()
    }
    if !allowsLandscape {
      PiliNativePlayerViewController.restorePortraitOrientation()
    }
  }

  private func installFlutterSurface() {
    flutterPlayerSurface.install(in: self)
  }

  private func installNativeSurface() {
    let host = UIHostingController(rootView: PiliNativeRootView(model: model))
    host.view.backgroundColor = .systemBackground
    host.view.translatesAutoresizingMaskIntoConstraints = false
    addChild(host)
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.topAnchor.constraint(equalTo: view.topAnchor),
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    host.didMove(toParent: self)
    hostingController = host
  }

  private func installChannel() {
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "configure":
        let arguments = piliDictionary(call.arguments)
        let titles = (arguments["titles"] as? [Any])?.compactMap { $0 as? String }
        let selectedIndex = piliInt(arguments["selectedIndex"])
        model.configure(titles: titles, selectedIndex: selectedIndex)
        setNativeRootVisible(true)
        model.requestSnapshot()
        result(nil)
      case "updateSnapshot":
        model.applySnapshot(piliDictionary(call.arguments))
        result(nil)
      case "setSelectedIndex":
        model.applyFlutterSelection(piliInt(call.arguments))
        result(nil)
      case "setBadge":
        let arguments = piliDictionary(call.arguments)
        model.applyBadge(
          index: piliInt(arguments["index"]) ?? -1,
          value: arguments["value"] as? String
        )
        result(nil)
      case "setChromeVisible":
        setNativeRootVisible(piliBool(call.arguments))
        if piliBool(call.arguments) {
          model.requestSnapshot()
        }
        result(nil)
      case "nativePlayerReady":
        model.originalPlayerDidBecomeReady(piliDictionary(call.arguments))
        result(nil)
      case "nativePlayerFullscreen":
        model.originalPlayerFullscreen = piliBool(call.arguments)
        setNeedsStatusBarAppearanceUpdate()
        result(nil)
      case "nativePlayerClosed":
        model.originalPlayerDidClose()
        result(nil)
      case "nativePlayerFailed":
        model.originalPlayerDidFail(piliString(call.arguments) ?? "原版播放器启动失败")
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func setNativeRootVisible(_ visible: Bool) {
    guard visible != isNativeRootVisible else { return }
    isNativeRootVisible = visible
    hostingController?.view.isHidden = !visible
    if visible {
      flutterViewController.view.isHidden = true
    } else {
      flutterPlayerSurface.restore(hidden: false)
    }
    setNeedsStatusBarAppearanceUpdate()
  }
}

// MARK: - View model and channel models

@MainActor
private final class PiliNativeViewModel: ObservableObject {
  @Published private(set) var tabTitles = ["首页", "动态", "我的"]
  @Published private(set) var selectedIndex = 0
  @Published private(set) var dynamicBadge = ""

  @Published private(set) var homeVideos: [PiliNativeVideo] = []
  @Published private(set) var homeLoading = true
  @Published private(set) var homeError: String?
  @Published private(set) var homeLoadingMore = false
  @Published private(set) var hotVideos: [PiliNativeVideo] = []
  @Published private(set) var hotLoading = false
  @Published private(set) var hotLoadingMore = false
  @Published private(set) var hotHasMore = true
  @Published private(set) var hotError: String?
  @Published private(set) var liveRooms: [PiliNativeLiveRoom] = []
  @Published private(set) var liveLoading = false
  @Published private(set) var liveLoadingMore = false
  @Published private(set) var liveHasMore = true
  @Published private(set) var liveError: String?

  @Published private(set) var dynamics: [PiliNativeDynamic] = []
  @Published private(set) var dynamicsLoading = true
  @Published private(set) var dynamicsError: String?
  @Published private(set) var dynamicsLoadingMore = false

  @Published private(set) var account = PiliNativeAccount()
  @Published var isSearchPresented = false
  @Published private(set) var searchResults: [PiliNativeVideo] = []
  @Published private(set) var searchLoading = false
  @Published private(set) var searchLoadingMore = false
  @Published private(set) var searchHasMore = false
  @Published private(set) var searchError: String?

  @Published var isVideoDetailPresented = false
  @Published private(set) var videoDetail: PiliNativeVideoDetail?
  @Published private(set) var videoDetailLoading = false
  @Published private(set) var videoDetailError: String?
  @Published private(set) var videoActionLoading = false
  @Published private(set) var videoActionMessage: String?
  @Published private(set) var relatedVideos: [PiliNativeVideo] = []
  @Published private(set) var relatedVideosLoading = false
  @Published private(set) var relatedVideosError: String?
  @Published private(set) var originalPlayerReady = false
  @Published private(set) var originalPlayerError: String?
  @Published var originalPlayerFullscreen = false

  @Published var isSettingsPresented = false
  @Published private(set) var settings: [PiliNativeSetting] = []
  @Published private(set) var settingsLoading = false
  @Published private(set) var settingsError: String?
  @Published private(set) var defaultVideoQuality = 127
  @Published private(set) var videoQualityOptions: [PiliNativeVideoQualityOption] = []

  @Published var isLibraryPresented = false
  @Published private(set) var libraryKind = ""
  @Published private(set) var libraryTitle = ""
  @Published private(set) var librarySubtitle = ""
  @Published private(set) var libraryItems: [PiliNativeLibraryItem] = []
  @Published private(set) var libraryLoading = false
  @Published private(set) var libraryLoadingMore = false
  @Published private(set) var libraryError: String?
  @Published private(set) var libraryHasMore = false

  @Published var isProfilePresented = false
  @Published private(set) var profile: PiliNativeProfile?
  @Published private(set) var profileLoading = false
  @Published private(set) var profileVideosLoading = false
  @Published private(set) var profileVideosLoadingMore = false
  @Published private(set) var profileVideosHasMore = false
  @Published private(set) var profileVideosError: String?
  @Published private(set) var profileError: String?
  @Published private(set) var profileActionLoading = false
  @Published private(set) var profileMessage: String?

  @Published var isDynamicDetailPresented = false
  @Published private(set) var selectedDynamic: PiliNativeDynamic?
  @Published private(set) var dynamicDetailLoading = false
  @Published private(set) var dynamicActionLoading = false
  @Published private(set) var dynamicMessage: String?
  @Published var isDynamicComposerPresented = false
  @Published var dynamicComposerText = ""
  @Published private(set) var dynamicComposerMode = "comment"
  @Published private(set) var dynamicComposerTitle = "发表评论"
  @Published private(set) var dynamicComposerHint = "友善地发表一条评论"
  @Published var isCommentThreadPresented = false
  @Published private(set) var commentThreadRoot: PiliNativeComment?
  @Published private(set) var commentThreadItems: [PiliNativeComment] = []
  @Published private(set) var commentThreadLoading = false
  @Published private(set) var commentThreadLoadingMore = false
  @Published private(set) var commentThreadHasMore = false
  @Published private(set) var commentThreadError: String?
  @Published private(set) var commentThreadTotal = 0

  @Published var isMessagesPresented = false
  @Published private(set) var messageKind = "sessions"
  @Published private(set) var messages: [PiliNativeMessage] = []
  @Published private(set) var messagesLoading = false
  @Published private(set) var messagesLoadingMore = false
  @Published private(set) var messagesHasMore = false
  @Published private(set) var messagesError: String?
  @Published var selectedChat: PiliNativeMessage?
  @Published private(set) var chatMessages: [PiliNativeChatMessage] = []
  @Published private(set) var chatLoading = false
  @Published private(set) var chatLoadingMore = false
  @Published private(set) var chatHasMore = false
  @Published private(set) var chatSending = false
  @Published private(set) var chatError: String?

  @Published var isLoginPresented = false
  @Published private(set) var loginQRCodeURL = ""
  @Published private(set) var loginLoading = false
  @Published private(set) var loginPolling = false
  @Published private(set) var loginMessage = "使用哔哩哔哩客户端扫码登录"
  @Published private(set) var loginExpiresIn = 0

  @Published var isDownloadsPresented = false
  @Published private(set) var downloads: [PiliNativeDownload] = []
  @Published private(set) var downloadsLoading = false
  @Published private(set) var downloadsError: String?

  @Published private(set) var comments: [PiliNativeComment] = []
  @Published private(set) var commentsLoading = false
  @Published private(set) var commentsLoadingMore = false
  @Published private(set) var commentsHasMore = false
  @Published private(set) var commentsError: String?
  @Published private(set) var commentsTotal = 0

  private let channel: FlutterMethodChannel
  let flutterPlayerSurface: PiliNativeFlutterPlayerSurface
  let nativePlayerSession = PiliNativePlayerSession()
  private var snapshotInFlight = false
  private var hotPage = 1
  private var livePage = 1
  @Published private(set) var pendingVideo: PiliNativeVideo?
  private var searchKeyword = ""
  private var searchPage = 1
  private var libraryPage = 1
  private var libraryMediaID: Int?
  private var libraryNextMax: Int?
  private var libraryNextViewAt: Int?
  private var libraryParentKind: String?
  private var libraryParentTitle: String?
  private var profileMID: Int?
  private var profileVideosPage = 1
  private var commentOID: Int?
  private var commentType = 1
  private var commentPage = 1
  private var commentOffset: String?
  private var commentThreadPage = 1
  private var commentThreadOffset: String?
  private var messageCursor: Int?
  private var messageCursorTime: Int?
  private var chatNextSeqno: Int?
  private var composerRootRpid: Int?
  private var composerParentRpid: Int?
  private var originalPlayerHeroTag = ""
  private var nativePlayerCID: Int?
  private var nativePlayerQuality: Int?
  private var nativePlaybackGeneration = UUID()
  private var nativePlayerFullscreenCancellable: AnyCancellable?
  var onVideoOrientationPolicyChanged: ((Bool) -> Void)?

  init(
    channel: FlutterMethodChannel,
    flutterPlayerSurface: PiliNativeFlutterPlayerSurface
  ) {
    self.channel = channel
    self.flutterPlayerSurface = flutterPlayerSurface
    nativePlayerSession.onDanmakuSegmentNeeded = { [weak self] segmentIndex in
      self?.loadNativeDanmaku(segmentIndex: segmentIndex)
    }
    nativePlayerSession.onQualityRequested = { [weak self] quality, resumeAt in
      guard let self = self, let video = self.videoDetail, let cid = self.nativePlayerCID else { return }
      self.loadNativePlayback(video: video, cid: cid, quality: quality, resumeAt: resumeAt)
    }
    nativePlayerSession.onDanmakuSendRequested = { [weak self] content, progress in
      self?.sendNativeDanmaku(content: content, progress: progress)
    }
    nativePlayerSession.onVideoActionRequested = { [weak self] action in
      guard let self else { return }
      if action == "close" {
        self.closeVideoDetail()
        return
      }
      guard let video = self.videoDetail else { return }
      if action == "comment" {
        self.nativePlayerSession.isFullscreen = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
          self?.beginDynamicComment()
        }
      } else {
        self.performVideoAction(action, video: video)
      }
    }
    nativePlayerFullscreenCancellable = nativePlayerSession.$isFullscreen
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] fullscreen in
        guard let self else { return }
        self.originalPlayerFullscreen = fullscreen
        if !fullscreen {
          self.nativePlayerSession.fullscreenCommentsVisible = false
        }
        let useLandscape = fullscreen && self.videoDetail?.isVertical != true
        self.onVideoOrientationPolicyChanged?(useLandscape)
      }
  }

  func configure(titles: [String]?, selectedIndex: Int?) {
    let validTitles = (titles ?? []).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    if !validTitles.isEmpty {
      tabTitles = validTitles
    }
    applyFlutterSelection(selectedIndex ?? 0)
  }

  func userSelectedTab(_ index: Int) {
    guard index >= 0 && index < tabTitles.count else { return }
    selectedIndex = index
    channel.invokeMethod("selectTab", arguments: index)
  }

  func applyFlutterSelection(_ index: Int) {
    guard index >= 0 && index < tabTitles.count else { return }
    selectedIndex = index
  }

  func applyBadge(index: Int, value: String?) {
    guard index >= 0 && index < tabTitles.count else { return }
    if tabTitles[index].contains("动态") {
      dynamicBadge = value ?? ""
    }
  }

  func requestSnapshot() {
    guard !snapshotInFlight else { return }
    snapshotInFlight = true
    channel.invokeMethod("requestSnapshot", arguments: nil) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.snapshotInFlight = false
        if let error = response as? FlutterError {
          self.homeError = error.message ?? "原生界面数据加载失败"
          self.homeLoading = false
          return
        }
        self.applySnapshot(piliDictionary(response))
      }
    }
  }

  func applySnapshot(_ snapshot: [String: Any]) {
    if let index = piliOptionalInt(snapshot["selectedIndex"]) {
      applyFlutterSelection(index)
    }
    if let badge = piliOptionalInt(snapshot["dynamicBadge"]) {
      dynamicBadge = badge > 0 ? (badge > 99 ? "99+" : String(badge)) : ""
    }
    applyHome(piliDictionary(snapshot["home"]))
    applyDynamics(piliDictionary(snapshot["dynamics"]))
    account = PiliNativeAccount(map: piliDictionary(snapshot["account"]))
  }

  private func applyHome(_ section: [String: Any]) {
    guard !section.isEmpty else { return }
    let state = section["state"] as? String ?? "loading"
    homeLoading = state == "loading" && homeVideos.isEmpty
    homeLoadingMore = false
    homeError = state == "error" ? section["error"] as? String ?? "首页加载失败" : nil
    if let rows = section["items"] as? [Any] {
      homeVideos = rows.enumerated().map {
        PiliNativeVideo(map: piliDictionary($0.element), index: $0.offset)
      }
    }
  }

  private func applyDynamics(_ section: [String: Any]) {
    guard !section.isEmpty else { return }
    let state = section["state"] as? String ?? "loading"
    dynamicsLoading = state == "loading" && dynamics.isEmpty
    dynamicsLoadingMore = false
    dynamicsError = state == "error" ? section["error"] as? String ?? "动态加载失败" : nil
    if let rows = section["items"] as? [Any] {
      dynamics = rows.enumerated().map {
        PiliNativeDynamic(map: piliDictionary($0.element), index: $0.offset)
      }
    }
  }

  func refresh(_ section: String) {
    switch section {
    case "home":
      homeLoading = true
      homeError = nil
    case "dynamics":
      dynamicsLoading = true
      dynamicsError = nil
    default:
      break
    }
    channel.invokeMethod("refreshSection", arguments: ["section": section]) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self else { return }
        if let error = response as? FlutterError {
          if section == "home" {
            self.homeLoading = false
            self.homeError = error.message ?? "刷新失败"
          } else if section == "dynamics" {
            self.dynamicsLoading = false
            self.dynamicsError = error.message ?? "刷新失败"
          }
          return
        }
        self.applySnapshot(piliDictionary(response))
      }
    }
  }

  func loadMore(_ section: String) {
    if section == "home" {
      guard !homeLoadingMore && !homeLoading else { return }
      homeLoadingMore = true
    } else if section == "dynamics" {
      guard !dynamicsLoadingMore && !dynamicsLoading else { return }
      dynamicsLoadingMore = true
    } else {
      return
    }
    channel.invokeMethod("loadMore", arguments: ["section": section]) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.homeLoadingMore = false
        self.dynamicsLoadingMore = false
        self.applySnapshot(piliDictionary(response))
      }
    }
  }

  func loadHomeZone(_ zone: String, refresh: Bool = false) {
    guard zone == "hot" || zone == "live" else { return }
    if zone == "hot" {
      if refresh {
        hotPage = 1
        hotHasMore = true
        hotError = nil
      } else if !hotVideos.isEmpty {
        return
      }
      guard !hotLoading && !hotLoadingMore else { return }
      hotLoading = hotVideos.isEmpty || refresh
    } else {
      if refresh {
        livePage = 1
        liveHasMore = true
        liveError = nil
      } else if !liveRooms.isEmpty {
        return
      }
      guard !liveLoading && !liveLoadingMore else { return }
      liveLoading = liveRooms.isEmpty || refresh
    }
    requestHomeZone(zone, page: 1, append: false)
  }

  func loadMoreHomeZone(_ zone: String) {
    if zone == "hot" {
      guard hotHasMore, !hotLoading, !hotLoadingMore else { return }
      hotLoadingMore = true
      requestHomeZone(zone, page: hotPage, append: true)
    } else if zone == "live" {
      guard liveHasMore, !liveLoading, !liveLoadingMore else { return }
      liveLoadingMore = true
      requestHomeZone(zone, page: livePage, append: true)
    }
  }

  private func requestHomeZone(_ zone: String, page: Int, append: Bool) {
    channel.invokeMethod(
      "loadNativeHomeZone",
      arguments: ["zone": zone, "page": page]
    ) { [weak self] response in
      DispatchQueue.main.async {
        guard let self else { return }
        if zone == "hot" {
          self.hotLoading = false
          self.hotLoadingMore = false
        } else {
          self.liveLoading = false
          self.liveLoadingMore = false
        }
        if let error = response as? FlutterError {
          if zone == "hot" {
            self.hotError = error.message ?? "热门视频加载失败"
          } else {
            self.liveError = error.message ?? "直播专区加载失败"
          }
          return
        }
        let result = piliDictionary(response)
        guard result["state"] as? String == "success" else {
          let message = result["error"] as? String ?? "专区加载失败"
          if zone == "hot" { self.hotError = message } else { self.liveError = message }
          return
        }
        let rows = result["items"] as? [Any] ?? []
        if zone == "hot" {
          let start = append ? self.hotVideos.count : 0
          let items = rows.enumerated().map {
            PiliNativeVideo(map: piliDictionary($0.element), index: start + $0.offset)
          }
          if append {
            let existing = Set(self.hotVideos.map(\.sourceID))
            self.hotVideos.append(contentsOf: items.filter { !existing.contains($0.sourceID) })
          } else {
            self.hotVideos = items
          }
          self.hotHasMore = piliBool(result["hasMore"]) && !items.isEmpty
          self.hotPage = page + 1
          self.hotError = nil
        } else {
          let start = append ? self.liveRooms.count : 0
          let items = rows.enumerated().map {
            PiliNativeLiveRoom(map: piliDictionary($0.element), index: start + $0.offset)
          }
          if append {
            let existing = Set(self.liveRooms.map(\.sourceID))
            self.liveRooms.append(contentsOf: items.filter { !existing.contains($0.sourceID) })
          } else {
            self.liveRooms = items
          }
          self.liveHasMore = piliBool(result["hasMore"]) && !items.isEmpty
          self.livePage = page + 1
          self.liveError = nil
        }
      }
    }
  }

  func openLiveRoom(_ room: PiliNativeLiveRoom) {
    openOriginalFlutterRoute("/liveRoom", parameters: ["roomId": String(room.roomID)])
  }

  func openVideo(_ video: PiliNativeVideo) {
    nativePlaybackGeneration = UUID()
    nativePlayerSession.stop()
    flutterPlayerSurface.restore(hidden: true)
    pendingVideo = video
    videoDetail = nil
    videoDetailError = nil
    videoDetailLoading = true
    videoActionLoading = false
    videoActionMessage = nil
    relatedVideos = []
    relatedVideosLoading = false
    relatedVideosError = nil
    originalPlayerReady = false
    originalPlayerError = nil
    originalPlayerFullscreen = false
    originalPlayerHeroTag = ""
    nativePlayerCID = nil
    nativePlayerQuality = nil
    nativePlayerSession.configureOverlayMetadata(title: video.title, like: 0, reply: 0, share: 0)
    isVideoDetailPresented = true
    onVideoOrientationPolicyChanged?(false)

    var arguments: [String: Any] = [:]
    if let bvid = video.bvid { arguments["bvid"] = bvid }
    if let aid = video.aid { arguments["aid"] = aid }
    arguments["title"] = video.title
    if let cover = video.cover { arguments["cover"] = cover }
    requestVideoDetail(arguments)
  }

  func retryVideoDetail() {
    guard let video = pendingVideo else { return }
    var arguments: [String: Any] = [:]
    if let bvid = video.bvid { arguments["bvid"] = bvid }
    if let aid = video.aid { arguments["aid"] = aid }
    arguments["title"] = video.title
    if let cover = video.cover { arguments["cover"] = cover }
    requestVideoDetail(arguments)
  }

  private func requestVideoDetail(_ arguments: [String: Any]) {
    videoDetailLoading = true
    videoDetailError = nil
    channel.invokeMethod("loadVideoDetail", arguments: arguments) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.videoDetailLoading = false
        if let flutterError = response as? FlutterError {
          self.videoDetailError = flutterError.message ?? "视频详情加载失败"
          return
        }
        let result = piliDictionary(response)
        guard result["state"] as? String == "success" else {
          self.videoDetailError = result["error"] as? String ?? "视频详情加载失败"
          return
        }
        let detail = PiliNativeVideoDetail(map: piliDictionary(result["video"]))
        self.videoDetail = detail
        self.nativePlayerSession.configureOverlayMetadata(
          title: detail.title,
          like: detail.like,
          reply: detail.reply,
          favorite: detail.favorite,
          share: detail.share,
          ownerName: detail.owner,
          ownerFaceURL: detail.ownerFace,
          isVertical: detail.isVertical
        )
        self.videoDetailError = nil
        self.nativePlayerCID = detail.cid ?? detail.pages.first?.cid
        if let cid = self.nativePlayerCID {
          self.loadNativePlayback(video: detail, cid: cid)
        } else {
          self.originalPlayerError = "视频没有可播放的分P"
        }
        if let aid = detail.aid {
          self.loadComments(oid: aid, type: 1)
        }
        self.loadRelatedVideos(bvid: detail.bvid)
      }
    }
  }

  private func loadRelatedVideos(bvid: String) {
    guard !bvid.isEmpty else { return }
    relatedVideosLoading = true
    relatedVideosError = nil
    channel.invokeMethod("loadRelatedVideos", arguments: ["bvid": bvid]) { [weak self] response in
      DispatchQueue.main.async {
        guard let self,
              self.videoDetail?.bvid == bvid else { return }
        self.relatedVideosLoading = false
        if let error = response as? FlutterError {
          self.relatedVideosError = error.message ?? "相关推荐加载失败"
          return
        }
        let result = piliDictionary(response)
        guard result["state"] as? String == "success" else {
          self.relatedVideosError = result["error"] as? String ?? "相关推荐加载失败"
          return
        }
        let rows = result["items"] as? [Any] ?? []
        self.relatedVideos = rows.enumerated().map {
          PiliNativeVideo(map: piliDictionary($0.element), index: $0.offset)
        }
        self.relatedVideosError = nil
      }
    }
  }

  private func loadNativePlayback(
    video: PiliNativeVideoDetail,
    cid: Int,
    quality: Int? = nil,
    resumeAt: TimeInterval = 0
  ) {
    let generation = UUID()
    nativePlaybackGeneration = generation
    originalPlayerError = nil
    originalPlayerReady = true
    nativePlayerSession.beginLoading()
    var arguments: [String: Any] = [
      "bvid": video.bvid,
      "cid": cid,
    ]
    if let quality { arguments["quality"] = quality }
    if let aid = video.aid { arguments["aid"] = aid }
    channel.invokeMethod("loadNativePlayback", arguments: arguments) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self, self.nativePlaybackGeneration == generation else { return }
        if let flutterError = response as? FlutterError {
          let message = flutterError.message ?? "播放地址获取失败"
          self.originalPlayerError = message
          self.nativePlayerSession.fail(message)
          return
        }
        let result = piliDictionary(response)
        guard result["state"] as? String == "success" else {
          let message = result["error"] as? String ?? "播放地址获取失败"
          self.originalPlayerError = message
          self.nativePlayerSession.fail(message)
          return
        }

        var segments: [PiliNativePlayerSegment] = []
        let segmentRows = result["segments"] as? [Any] ?? []
        for row in segmentRows {
          let map = piliDictionary(row)
          guard let rawURL = piliString(map["url"]), let url = URL(string: rawURL) else { continue }
          let audioURL = piliString(map["audioURL"]).flatMap(URL.init(string:))
          let videoURLs = (map["videoURLs"] as? [Any] ?? []).compactMap {
            piliString($0).flatMap(URL.init(string:))
          }
          let audioURLs = (map["audioURLs"] as? [Any] ?? []).compactMap {
            piliString($0).flatMap(URL.init(string:))
          }
          segments.append(
            PiliNativePlayerSegment(
              url: url,
              duration: Double(piliInt(map["duration"])) / 1000,
              audioURL: audioURL,
              alternativeURLs: videoURLs.filter { $0 != url },
              alternativeAudioURLs: audioURLs.filter { $0 != audioURL },
              isHDR: piliBool(map["hdr"]),
              qualityValue: piliInt(map["quality"]),
              codec: piliString(map["codec"]) ?? ""
            )
          )
        }
        if segments.isEmpty {
          let urls = result["urls"] as? [Any] ?? []
          segments = urls.compactMap { value in
            guard let rawURL = piliString(value), let url = URL(string: rawURL) else { return nil }
            return PiliNativePlayerSegment(url: url, duration: 0)
          }
        }
        guard !segments.isEmpty else {
          let message = "没有可用的原生播放地址"
          self.originalPlayerError = message
          self.nativePlayerSession.fail(message)
          return
        }

        let qualities = (result["qualities"] as? [Any] ?? []).compactMap { row -> PiliNativePlayerQuality? in
          let map = piliDictionary(row)
          guard let value = piliOptionalInt(map["value"]) else { return nil }
          return PiliNativePlayerQuality(
            value: value,
            label: piliString(map["label"]) ?? "\(value)P"
          )
        }
        self.nativePlayerCID = cid
        self.nativePlayerQuality = piliOptionalInt(result["quality"]) ?? quality
        self.originalPlayerReady = true
        self.originalPlayerError = nil
        self.nativePlayerSession.configure(
          segments: segments,
          durationMilliseconds: piliInt(result["duration"]),
          quality: piliString(result["qualityText"])
            ?? "\(piliOptionalInt(result["quality"]) ?? quality ?? 80)P",
          qualities: qualities,
          resumeAt: resumeAt
        )
        self.nativePlayerSession.prepareDanmaku()
        if resumeAt > 0 {
          self.videoActionMessage = "已切换清晰度"
        }
      }
    }
  }

  private func loadNativeDanmaku(segmentIndex: Int) {
    guard let cid = nativePlayerCID else { return }
    channel.invokeMethod(
      "loadNativeDanmaku",
      arguments: ["cid": cid, "segmentIndex": segmentIndex]
    ) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self, self.nativePlayerCID == cid else { return }
        let result = piliDictionary(response)
        guard result["state"] as? String == "success" else { return }
        let items = (result["items"] as? [Any] ?? []).compactMap { row -> PiliNativeDanmakuItem? in
          let map = piliDictionary(row)
          guard let content = piliString(map["content"]), !content.isEmpty else { return nil }
          let rgb = piliInt(map["color"])
          let color = UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
          )
          return PiliNativeDanmakuItem(
            id: piliString(map["id"]) ?? "\(segmentIndex)-\(piliInt(map["progress"]))-\(content)",
            progress: Double(piliInt(map["progress"])) / 1000,
            mode: piliInt(map["mode"]),
            fontSize: CGFloat(max(12, piliInt(map["fontSize"]))),
            color: color,
            content: content,
            weight: piliInt(map["weight"])
          )
        }
        self.nativePlayerSession.appendDanmaku(items)
      }
    }
  }

  private func sendNativeDanmaku(content: String, progress: Int) {
    guard let cid = nativePlayerCID, let video = videoDetail else {
      nativePlayerSession.reportDanmakuSendResult("弹幕参数不完整")
      return
    }
    channel.invokeMethod(
      "sendNativeDanmaku",
      arguments: [
        "cid": cid,
        "bvid": video.bvid,
        "content": content,
        "progress": progress,
      ]
    ) { [weak self] response in
      DispatchQueue.main.async {
        guard let self else { return }
        if let error = response as? FlutterError {
          self.nativePlayerSession.reportDanmakuSendResult(error.message ?? "弹幕发送失败")
          return
        }
        let result = piliDictionary(response)
        guard result["state"] as? String == "success" else {
          self.nativePlayerSession.reportDanmakuSendResult(
            result["error"] as? String ?? "弹幕发送失败"
          )
          return
        }
        self.nativePlayerSession.reportDanmakuSendResult("弹幕发送成功", sentContent: content)
      }
    }
  }

  func originalPlayerDidBecomeReady(_ arguments: [String: Any]) {
    originalPlayerHeroTag = piliString(arguments["heroTag"]) ?? ""
    originalPlayerError = nil
    originalPlayerReady = true
  }

  func originalPlayerDidClose() {
    onVideoOrientationPolicyChanged?(false)
    originalPlayerReady = false
    originalPlayerFullscreen = false
    flutterPlayerSurface.restore(hidden: true)
    if isVideoDetailPresented {
      isVideoDetailPresented = false
    }
  }

  func originalPlayerDidFail(_ message: String) {
    originalPlayerReady = false
    originalPlayerFullscreen = false
    originalPlayerError = message
    flutterPlayerSurface.restore(hidden: true)
  }

  func closeVideoDetail() {
    onVideoOrientationPolicyChanged?(false)
    nativePlaybackGeneration = UUID()
    originalPlayerReady = false
    originalPlayerFullscreen = false
    nativePlayerSession.isFullscreen = false
    nativePlayerSession.stop()
    nativePlayerCID = nil
    nativePlayerQuality = nil
    flutterPlayerSurface.restore(hidden: true)
    isVideoDetailPresented = false
    channel.invokeMethod("closeNativeVideoPlayer", arguments: nil)
  }

  func selectOriginalPlayerPart(_ part: PiliNativeVideoPart) {
    guard let cid = part.cid, let video = videoDetail else {
      videoActionMessage = "播放器尚未就绪"
      return
    }
    nativePlayerCID = cid
    videoActionMessage = "正在切换到 P\(part.index)"
    loadNativePlayback(video: video, cid: cid, quality: nativePlayerQuality)
  }

  func retryNativePlayback() {
    guard let video = videoDetail, let cid = nativePlayerCID else { return }
    originalPlayerError = nil
    loadNativePlayback(
      video: video,
      cid: cid,
      quality: nativePlayerQuality,
      resumeAt: nativePlayerSession.currentTime
    )
  }

  func exitOriginalPlayerFullscreen() {
    originalPlayerFullscreen = false
    nativePlayerSession.isFullscreen = false
    nativePlayerSession.fullscreenCommentsVisible = false
  }

  func handleVideoDeviceOrientation(_ orientation: UIDeviceOrientation) {
    guard isVideoDetailPresented,
          videoDetail != nil,
          originalPlayerReady,
          !orientation.isFlat else { return }
    if orientation.isLandscape {
      if !nativePlayerSession.isFullscreen {
        nativePlayerSession.isFullscreen = true
      }
    } else if orientation == .portrait,
              nativePlayerSession.isFullscreen {
      nativePlayerSession.isFullscreen = false
    }
  }

  func openVideoOwner(_ video: PiliNativeVideoDetail) {
    guard let ownerID = video.ownerID else { return }
    openVideoMember(ownerID)
  }

  func openVideoMember(_ memberID: Int) {
    closeVideoDetail()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
      self?.presentProfile(memberID)
    }
  }

  func performVideoAction(_ action: String, video: PiliNativeVideoDetail) {
    guard !videoActionLoading else { return }
    videoActionLoading = true
    videoActionMessage = nil
    channel.invokeMethod(
      "performVideoAction",
      arguments: [
        "action": action,
        "bvid": video.bvid,
        "heroTag": originalPlayerHeroTag,
      ]
    ) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.videoActionLoading = false
        if let error = response as? FlutterError {
          self.videoActionMessage = error.message ?? "操作失败"
          return
        }
        let result = piliDictionary(response)
        guard result["state"] as? String == "success" else {
          self.videoActionMessage = result["error"] as? String ?? "操作失败"
          return
        }
        if action == "share", let rawURL = piliString(result["shareURL"]), let url = URL(string: rawURL) {
          self.presentShareSheet(title: video.title, url: url)
        } else {
          self.applyVideoActionResult(action, result: result)
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.refreshCurrentVideoDetail()
          }
        }
        self.videoActionMessage = result["message"] as? String ?? "操作成功"
      }
    }
  }

  private func applyVideoActionResult(_ action: String, result: [String: Any]) {
    guard var current = videoDetail else { return }
    switch action {
    case "like":
      let liked = piliBool(result["liked"])
      if current.liked != liked {
        current.like = max(0, current.like + (liked ? 1 : -1))
      }
      current.liked = liked
    case "coin":
      current.coin += 1
      current.coinCount += 1
    case "favorite":
      let favorited = piliBool(result["favorite"])
      if current.favorited != favorited {
        current.favorite = max(0, current.favorite + (favorited ? 1 : -1))
      }
      current.favorited = favorited
    default:
      break
    }
    videoDetail = current
    nativePlayerSession.configureOverlayMetadata(
      title: current.title,
      like: current.like,
      reply: current.reply,
      favorite: current.favorite,
      share: current.share,
      ownerName: current.owner,
      ownerFaceURL: current.ownerFace,
      isVertical: current.isVertical
    )
  }

  func refreshCurrentVideoDetail() {
    guard let current = videoDetail else { return }
    var arguments: [String: Any] = [
      "bvid": current.bvid,
      "title": current.title,
    ]
    if let aid = current.aid { arguments["aid"] = aid }
    if let cover = current.cover { arguments["cover"] = cover }
    channel.invokeMethod("loadVideoDetail", arguments: arguments) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self,
              let active = self.videoDetail,
              active.bvid == current.bvid else { return }
        let result = piliDictionary(response)
        guard result["state"] as? String == "success" else { return }
        var refreshed = PiliNativeVideoDetail(map: piliDictionary(result["video"]))
        if !refreshed.relationLoaded {
          refreshed.liked = active.liked
          refreshed.coinCount = active.coinCount
          refreshed.favorited = active.favorited
        }
        self.videoDetail = refreshed
        self.nativePlayerSession.configureOverlayMetadata(
          title: refreshed.title,
          like: refreshed.like,
          reply: refreshed.reply,
          favorite: refreshed.favorite,
          share: refreshed.share,
          ownerName: refreshed.owner,
          ownerFaceURL: refreshed.ownerFace,
          isVertical: refreshed.isVertical
        )
      }
    }
  }

  private func presentShareSheet(title: String, url: URL) {
    let controller = UIActivityViewController(activityItems: [title, url], applicationActivities: nil)
    guard let window = UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .flatMap({ $0.windows })
      .first(where: { $0.isKeyWindow }),
      var presenter = window.rootViewController else { return }
    while let presented = presenter.presentedViewController { presenter = presented }
    if let popover = controller.popoverPresentationController {
      popover.sourceView = presenter.view
      popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 40, width: 1, height: 1)
    }
    presenter.present(controller, animated: true)
  }

  func presentSettings() {
    isSettingsPresented = true
    loadSettings()
  }

  func loadSettings() {
    settingsLoading = settings.isEmpty
    settingsError = nil
    channel.invokeMethod("loadNativeSettings", arguments: nil) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.settingsLoading = false
        if let error = response as? FlutterError {
          self.settingsError = error.message ?? "设置加载失败"
          return
        }
        let result = piliDictionary(response)
        guard result["state"] as? String == "success" else {
          self.settingsError = result["error"] as? String ?? "设置加载失败"
          return
        }
        self.applySettingsSnapshot(result)
      }
    }
  }

  func setSetting(_ key: String, value: Bool) {
    if let index = settings.firstIndex(where: { $0.key == key }) {
      settings[index].value = value
    }
    channel.invokeMethod(
      "setNativeSetting",
      arguments: ["key": key, "value": value]
    ) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self else { return }
        let result = piliDictionary(response)
        if result["state"] as? String == "success" {
          self.applySettingsSnapshot(result)
        } else {
          self.settingsError = result["error"] as? String ?? "设置保存失败"
          self.loadSettings()
        }
      }
    }
  }

  func setDefaultVideoQuality(_ value: Int) {
    guard videoQualityOptions.contains(where: { $0.value == value }) else { return }
    defaultVideoQuality = value
    channel.invokeMethod(
      "setNativeVideoQuality",
      arguments: ["value": value]
    ) { [weak self] response in
      DispatchQueue.main.async {
        guard let self else { return }
        let result = piliDictionary(response)
        if result["state"] as? String == "success" {
          self.applySettingsSnapshot(result)
        } else {
          self.settingsError = result["error"] as? String ?? "默认画质保存失败"
          self.loadSettings()
        }
      }
    }
  }

  private func applySettingsSnapshot(_ result: [String: Any]) {
    let rows = result["items"] as? [Any] ?? []
    settings = rows.enumerated().map {
      PiliNativeSetting(map: piliDictionary($0.element), index: $0.offset)
    }
    let qualityRows = result["videoQualities"] as? [Any] ?? []
    videoQualityOptions = qualityRows.enumerated().compactMap {
      PiliNativeVideoQualityOption(map: piliDictionary($0.element), index: $0.offset)
    }
    if let selected = piliOptionalInt(result["defaultVideoQuality"]),
       videoQualityOptions.contains(where: { $0.value == selected }) {
      defaultVideoQuality = selected
    }
  }

  func openDynamic(_ item: PiliNativeDynamic) {
    selectedDynamic = item
    dynamicMessage = nil
    dynamicActionLoading = false
    isDynamicDetailPresented = true
    if let oid = item.commentOID {
      loadComments(oid: oid, type: item.commentType ?? 17)
    } else {
      comments = []
      commentsTotal = item.comment
      commentsError = "该动态没有可用的评论编号"
    }
    loadDynamicDetail()
  }

  func openRoute(_ route: String, parameters: [String: String] = [:]) {
    switch route {
    case "/loginPage":
      presentNativeLogin()
    case "/whisper":
      presentMessages()
    case "/myReply":
      presentMessages(kind: "reply")
    case "/download":
      presentDownloads()
    case "/setting":
      presentSettings()
    case "/history":
      presentLibrary("history", title: "观看记录")
    case "/later":
      presentLibrary("later", title: "稍后再看")
    case "/fav", "/favDetail":
      presentLibrary("favorites", title: "我的收藏")
    case "/follow":
      presentLibrary("following", title: "关注")
    case "/fan":
      presentLibrary("followers", title: "粉丝")
    case "/subscription":
      presentLibrary("subscriptions", title: "我的订阅")
    case "/member":
      if let midString = parameters["mid"], let mid = Int(midString) {
        presentProfile(mid)
      }
    case "/memberDynamics":
      if let index = tabTitles.firstIndex(where: { $0.contains("动态") }) {
        userSelectedTab(index)
      }
    default:
      break
    }
  }

  private func openOriginalFlutterRoute(
    _ route: String,
    parameters: [String: String] = [:]
  ) {
    channel.invokeMethod(
      "openRoute",
      arguments: ["route": route, "parameters": parameters]
    )
  }

  func search(_ keyword: String) {
    let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    searchKeyword = value
    searchPage = 1
    searchResults = []
    searchHasMore = false
    searchLoading = true
    searchLoadingMore = false
    searchError = nil
    requestSearchPage(1, append: false)
  }

  func loadMoreSearchResults() {
    guard searchHasMore, !searchLoading, !searchLoadingMore,
          !searchKeyword.isEmpty else { return }
    searchLoadingMore = true
    requestSearchPage(searchPage, append: true)
  }

  private func requestSearchPage(_ page: Int, append: Bool) {
    let keyword = searchKeyword
    channel.invokeMethod(
      "searchVideos",
      arguments: ["keyword": keyword, "page": page]
    ) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self, self.searchKeyword == keyword else { return }
        self.searchLoading = false
        self.searchLoadingMore = false
        if let error = response as? FlutterError {
          self.searchError = error.message ?? "搜索失败"
          return
        }
        let result = piliDictionary(response)
        if result["state"] as? String == "error" {
          self.searchError = result["error"] as? String ?? "搜索失败"
          return
        }
        let rows = result["items"] as? [Any] ?? []
        let startIndex = append ? self.searchResults.count : 0
        let newItems = rows.enumerated().map {
          PiliNativeVideo(
            map: piliDictionary($0.element),
            index: startIndex + $0.offset
          )
        }
        if append {
          let existingSourceIDs = Set(self.searchResults.map(\.sourceID))
          self.searchResults.append(
            contentsOf: newItems.filter { !existingSourceIDs.contains($0.sourceID) }
          )
        } else {
          self.searchResults = newItems
        }
        self.searchHasMore = piliBool(result["hasMore"]) && !newItems.isEmpty
        self.searchPage = page + 1
        self.searchError = nil
      }
    }
  }

  func presentNativeLogin() {
    isLoginPresented = true
    startNativeLogin()
  }

  func startNativeLogin() {
    loginLoading = true
    loginPolling = false
    loginQRCodeURL = ""
    loginExpiresIn = 0
    loginMessage = "正在生成登录二维码"
    channel.invokeMethod("startNativeLogin", arguments: nil) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.loginLoading = false
        if let flutterError = response as? FlutterError {
          self.loginMessage = flutterError.message ?? "登录二维码获取失败"
          return
        }
        let result = piliDictionary(response)
        guard result["state"] as? String == "success" else {
          self.loginMessage = result["error"] as? String ?? "登录二维码获取失败"
          return
        }
        self.loginQRCodeURL = piliString(result["url"]) ?? ""
        self.loginExpiresIn = piliInt(result["expiresIn"])
        self.loginMessage = "使用哔哩哔哩客户端扫码并确认"
      }
    }
  }

  func pollNativeLogin() {
    guard isLoginPresented, !loginQRCodeURL.isEmpty, !loginPolling else { return }
    guard loginExpiresIn > 0 else {
      loginMessage = "二维码已过期，请刷新"
      return
    }
    loginExpiresIn = max(0, loginExpiresIn - 2)
    loginPolling = true
    channel.invokeMethod("pollNativeLogin", arguments: nil) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.loginPolling = false
        if let flutterError = response as? FlutterError {
          self.loginMessage = flutterError.message ?? "登录状态检查失败"
          return
        }
        let result = piliDictionary(response)
        switch result["state"] as? String {
        case "success":
          self.loginMessage = result["message"] as? String ?? "登录成功"
          self.isLoginPresented = false
          self.requestSnapshot()
        case "expired":
          self.loginExpiresIn = 0
          self.loginMessage = result["message"] as? String ?? "二维码已过期，请刷新"
        case "error":
          self.loginMessage = result["message"] as? String ?? "登录状态检查失败"
        default:
          self.loginMessage = result["message"] as? String ?? "等待扫码确认"
        }
      }
    }
  }

  func presentMessages(kind: String = "sessions") {
    isMessagesPresented = true
    loadMessages(kind: kind, refresh: true)
  }

  func loadMessages(kind: String? = nil, refresh: Bool = true) {
    if let kind, kind != messageKind {
      messageKind = kind
      messages = []
    }
    if refresh {
      messageCursor = nil
      messageCursorTime = nil
      messagesHasMore = false
      messagesLoading = true
      messagesLoadingMore = false
      messagesError = nil
    } else {
      guard messagesHasMore, !messagesLoading, !messagesLoadingMore else { return }
      messagesLoadingMore = true
    }
    requestMessagePage(kind: messageKind, append: !refresh)
  }

  func loadMoreMessages() {
    loadMessages(refresh: false)
  }

  private func requestMessagePage(kind: String, append: Bool) {
    var arguments: [String: Any] = ["kind": kind, "refresh": !append]
    if let messageCursor { arguments["cursor"] = messageCursor }
    if let messageCursorTime { arguments["cursorTime"] = messageCursorTime }
    channel.invokeMethod(
      "loadNativeMessages",
      arguments: arguments
    ) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self, self.messageKind == kind else { return }
        self.messagesLoading = false
        self.messagesLoadingMore = false
        if let flutterError = response as? FlutterError {
          self.messagesError = flutterError.message ?? "消息加载失败"
          return
        }
        let result = piliDictionary(response)
        guard result["state"] as? String == "success" else {
          self.messagesError = result["error"] as? String ?? "消息加载失败"
          return
        }
        let rows = result["items"] as? [Any] ?? []
        let startIndex = append ? self.messages.count : 0
        let newItems = rows.enumerated().map {
          PiliNativeMessage(
            map: piliDictionary($0.element),
            index: startIndex + $0.offset
          )
        }
        if append {
          let existingIDs = Set(self.messages.map(\.id))
          self.messages.append(
            contentsOf: newItems.filter { !existingIDs.contains($0.id) }
          )
        } else {
          self.messages = newItems
        }
        self.messagesHasMore = piliBool(result["hasMore"]) && !newItems.isEmpty
        self.messageCursor = piliOptionalInt(result["nextCursor"])
        self.messageCursorTime = piliOptionalInt(result["nextCursorTime"])
        self.messagesError = nil
      }
    }
  }

  func openMessageMember(_ message: PiliNativeMessage) {
    guard let memberID = message.memberID else { return }
    isMessagesPresented = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
      self?.presentProfile(memberID)
    }
  }

  func openMessage(_ message: PiliNativeMessage) {
    guard message.kind == "session" else {
      openMessageMember(message)
      return
    }
    guard message.talkerID != nil else {
      messagesError = "该折叠会话暂无可用的私信对象"
      return
    }
    selectedChat = message
    chatMessages = []
    chatNextSeqno = nil
    chatHasMore = false
    chatError = nil
    loadChat(refresh: true)
  }

  func closeChat() {
    selectedChat = nil
    chatMessages = []
    chatNextSeqno = nil
    chatHasMore = false
    chatError = nil
    if messageKind == "sessions" {
      loadMessages(refresh: true)
    }
  }

  func loadChat(refresh: Bool = true) {
    guard let chat = selectedChat, let talkerID = chat.talkerID else { return }
    if refresh {
      chatLoading = chatMessages.isEmpty
      chatLoadingMore = false
      chatNextSeqno = nil
      chatHasMore = false
      chatError = nil
    } else {
      guard chatHasMore, !chatLoading, !chatLoadingMore else { return }
      chatLoadingMore = true
    }
    var arguments: [String: Any] = ["talkerId": talkerID]
    if !refresh, let chatNextSeqno { arguments["endSeqno"] = chatNextSeqno }
    channel.invokeMethod("loadNativeChat", arguments: arguments) { [weak self] response in
      DispatchQueue.main.async {
        guard let self, self.selectedChat?.id == chat.id else { return }
        self.chatLoading = false
        self.chatLoadingMore = false
        if let error = response as? FlutterError {
          self.chatError = error.message ?? "聊天记录加载失败"
          return
        }
        let result = piliDictionary(response)
        guard result["state"] as? String == "success" else {
          self.chatError = result["error"] as? String ?? "聊天记录加载失败"
          return
        }
        let rows = result["items"] as? [Any] ?? []
        let emoteRows = result["emotes"] as? [Any] ?? []
        let newItems = rows.enumerated().map {
          var map = piliDictionary($0.element)
          // The gRPC response shares one emotion table across the page. Attach
          // it while adapting rows so mixed text can resolve every token.
          map["emotes"] = emoteRows
          return PiliNativeChatMessage(map: map, index: $0.offset)
        }
        if refresh {
          self.chatMessages = newItems
        } else {
          let existing = Set(self.chatMessages.map(\.id))
          self.chatMessages.append(contentsOf: newItems.filter { !existing.contains($0.id) })
        }
        self.chatHasMore = piliBool(result["hasMore"]) && !newItems.isEmpty
        self.chatNextSeqno = piliOptionalInt(result["nextSeqno"])
        self.chatError = nil
      }
    }
  }

  func sendChatMessage(_ text: String, completion: @escaping (Bool) -> Void) {
    let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty, let chat = selectedChat, let talkerID = chat.talkerID,
          !chatSending else {
      completion(false)
      return
    }
    chatSending = true
    chatError = nil
    var arguments: [String: Any] = ["talkerId": talkerID, "message": message]
    if let memberID = chat.memberID { arguments["memberId"] = memberID }
    channel.invokeMethod("sendNativeChatMessage", arguments: arguments) { [weak self] response in
      DispatchQueue.main.async {
        guard let self else { return }
        self.chatSending = false
        let result = piliDictionary(response)
        let success = result["state"] as? String == "success"
        if success {
          self.loadChat(refresh: true)
        } else {
          self.chatError = result["error"] as? String ?? "消息发送失败"
        }
        completion(success)
      }
    }
  }

  func sendChatImage(at url: URL) {
    guard let chat = selectedChat, let talkerID = chat.talkerID, !chatSending else { return }
    chatSending = true
    chatError = nil
    var arguments: [String: Any] = ["talkerId": talkerID, "path": url.path]
    if let memberID = chat.memberID { arguments["memberId"] = memberID }
    channel.invokeMethod("sendNativeChatImage", arguments: arguments) { [weak self] response in
      DispatchQueue.main.async {
        try? FileManager.default.removeItem(at: url)
        guard let self else { return }
        self.chatSending = false
        let result = piliDictionary(response)
        if result["state"] as? String == "success" {
          self.loadChat(refresh: true)
        } else {
          self.chatError = result["error"] as? String ?? "图片消息发送失败"
        }
      }
    }
  }

  func recallChatMessage(_ message: PiliNativeChatMessage) {
    guard message.isOwner, message.msgKey > 0, let chat = selectedChat,
          let talkerID = chat.talkerID, !chatSending else { return }
    chatSending = true
    var arguments: [String: Any] = ["talkerId": talkerID, "msgKey": message.msgKey]
    if let memberID = chat.memberID { arguments["memberId"] = memberID }
    channel.invokeMethod("recallNativeChatMessage", arguments: arguments) { [weak self] response in
      DispatchQueue.main.async {
        guard let self else { return }
        self.chatSending = false
        let result = piliDictionary(response)
        if result["state"] as? String == "success" {
          self.loadChat(refresh: true)
        } else {
          self.chatError = result["error"] as? String ?? "消息撤回失败"
        }
      }
    }
  }

  func presentDownloads() {
    isDownloadsPresented = true
    downloads = []
    downloadsError = nil
    downloadsLoading = true
    channel.invokeMethod("loadNativeDownloads", arguments: nil) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.downloadsLoading = false
        if let flutterError = response as? FlutterError {
          self.downloadsError = flutterError.message ?? "离线缓存读取失败"
          return
        }
        let result = piliDictionary(response)
        guard result["state"] as? String == "success" else {
          self.downloadsError = result["error"] as? String ?? "离线缓存读取失败"
          return
        }
        let rows = result["items"] as? [Any] ?? []
        self.downloads = rows.enumerated().map {
          PiliNativeDownload(map: piliDictionary($0.element), index: $0.offset)
        }
      }
    }
  }

  func openDownload(_ download: PiliNativeDownload) {
    var map: [String: Any] = [
      "id": download.id,
      "title": download.title,
      "owner": download.subtitle,
      "durationText": "",
    ]
    if let aid = download.aid { map["aid"] = aid }
    if let bvid = download.bvid { map["bvid"] = bvid }
    if let cover = download.cover { map["cover"] = cover }
    let video = PiliNativeVideo(map: map, index: 0)
    isDownloadsPresented = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
      self?.openVideo(video)
    }
  }

  func loadComments(oid: Int, type: Int, preserveExisting: Bool = false) {
    commentOID = oid
    commentType = type
    commentPage = 1
    commentOffset = nil
    commentsHasMore = false
    commentsLoadingMore = false
    if !preserveExisting { comments = [] }
    commentsError = nil
    if !preserveExisting { commentsTotal = 0 }
    commentsLoading = true
    requestCommentPage(
      oid: oid,
      type: type,
      page: 1,
      offset: nil,
      append: false
    )
  }

  func loadMoreComments() {
    guard let oid = commentOID,
          commentsHasMore,
          !commentsLoading,
          !commentsLoadingMore else { return }
    commentsLoadingMore = true
    requestCommentPage(
      oid: oid,
      type: commentType,
      page: commentPage,
      offset: commentOffset,
      append: true
    )
  }

  private func requestCommentPage(
    oid: Int,
    type: Int,
    page: Int,
    offset: String?,
    append: Bool
  ) {
    var arguments: [String: Any] = ["oid": oid, "type": type, "page": page]
    if let offset, !offset.isEmpty { arguments["offset"] = offset }
    channel.invokeMethod(
      "loadNativeComments",
      arguments: arguments
    ) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self else { return }
        guard self.commentOID == oid, self.commentType == type else { return }
        self.commentsLoading = false
        self.commentsLoadingMore = false
        if let flutterError = response as? FlutterError {
          self.commentsError = flutterError.message ?? "评论加载失败"
          return
        }
        let result = piliDictionary(response)
        guard result["state"] as? String == "success" else {
          self.commentsError = result["error"] as? String ?? "评论加载失败"
          return
        }
        let rows = result["items"] as? [Any] ?? []
        let startIndex = append ? self.comments.count : 0
        let newItems = rows.enumerated().map {
          PiliNativeComment(
            map: piliDictionary($0.element),
            index: startIndex + $0.offset
          )
        }
        if append {
          let existingIDs = Set(self.comments.map(\.id))
          self.comments.append(
            contentsOf: newItems.filter { !existingIDs.contains($0.id) }
          )
        } else {
          self.comments = newItems
        }
        self.commentsTotal = piliInt(result["total"])
        self.commentsHasMore = piliBool(result["hasMore"]) && !newItems.isEmpty
        self.commentOffset = piliString(result["nextOffset"])
        self.commentPage = page + 1
        self.commentsError = nil
      }
    }
  }

  func toggleCommentLike(_ comment: PiliNativeComment) {
    guard let oid = commentOID,
          comments.contains(where: { $0.id == comment.id }) else { return }
    channel.invokeMethod(
      "setNativeCommentLike",
      arguments: [
        "oid": oid,
        "type": commentType,
        "rpid": comment.rpid,
        "liked": comment.liked,
      ]
    ) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self else { return }
        let result = piliDictionary(response)
        guard result["state"] as? String == "success" else {
          self.commentsError = result["error"] as? String ?? "评论点赞失败"
          return
        }
        let nowLiked = piliBool(result["liked"])
        if let currentIndex = self.comments.firstIndex(where: { $0.id == comment.id }) {
          self.comments[currentIndex].liked = nowLiked
          self.comments[currentIndex].like = max(0, self.comments[currentIndex].like + (nowLiked ? 1 : -1))
          if self.commentThreadRoot?.id == comment.id {
            self.commentThreadRoot?.liked = nowLiked
            self.commentThreadRoot?.like = self.comments[currentIndex].like
          }
        }
        self.loadComments(oid: oid, type: self.commentType, preserveExisting: true)
        if self.isCommentThreadPresented { self.loadCommentThread() }
      }
    }
  }

  func openCommentMember(_ comment: PiliNativeComment) {
    guard let memberID = comment.memberID else { return }
    if isDynamicDetailPresented {
      isDynamicComposerPresented = false
      isCommentThreadPresented = false
      isDynamicDetailPresented = false
    }
    if isVideoDetailPresented {
      closeVideoDetail()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
      self?.presentProfile(memberID)
    }
  }

  func openDynamicVideo() {
    guard let item = selectedDynamic, let bvid = item.bvid else { return }
    var map: [String: Any] = [
      "id": item.sourceID,
      "bvid": bvid,
      "title": item.title.isEmpty ? item.body : item.title,
      "owner": item.author,
    ]
    if let aid = item.aid { map["aid"] = aid }
    if let cover = item.cover { map["cover"] = cover }
    isDynamicDetailPresented = false
    let video = PiliNativeVideo(map: map, index: 0)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
      self?.openVideo(video)
    }
  }

  func openDynamicMember() {
    guard let memberID = selectedDynamic?.authorID else { return }
    isDynamicDetailPresented = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
      self?.presentProfile(memberID)
    }
  }

  func loadDynamicDetail() {
    guard let sourceID = selectedDynamic?.validSourceID else {
      dynamicDetailLoading = false
      PiliNativeDiagnosticLog.shared.append(
        "Dynamic detail skipped: API did not provide a numeric dynamic ID"
      )
      return
    }
    dynamicDetailLoading = true
    channel.invokeMethod(
      "loadNativeDynamicDetail",
      arguments: ["id": sourceID]
    ) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self, self.selectedDynamic?.sourceID == sourceID else { return }
        self.dynamicDetailLoading = false
        if let flutterError = response as? FlutterError {
          self.dynamicMessage = flutterError.message ?? "动态详情加载失败"
          PiliNativeDiagnosticLog.shared.append(
            "Dynamic detail Flutter error id=\(sourceID): "
              + "\(flutterError.message ?? "unknown")"
          )
          return
        }
        let result = piliDictionary(response)
        guard result["state"] as? String == "success" else {
          self.dynamicMessage = result["error"] as? String ?? "动态详情加载失败"
          PiliNativeDiagnosticLog.shared.append(
            "Dynamic detail failed id=\(sourceID) code=\(piliString(result["code"]) ?? "none") "
              + "error=\(self.dynamicMessage ?? "unknown")"
          )
          return
        }
        let refreshed = PiliNativeDynamic(map: piliDictionary(result["dynamic"]), index: 0)
        self.selectedDynamic = refreshed
        if let oid = refreshed.commentOID,
           oid != self.commentOID || (refreshed.commentType ?? 17) != self.commentType {
          self.loadComments(oid: oid, type: refreshed.commentType ?? 17)
        }
      }
    }
  }

  func toggleDynamicLike() {
    guard let item = selectedDynamic, !dynamicActionLoading else { return }
    guard let sourceID = item.validSourceID else {
      dynamicMessage = "该动态缺少有效编号，请刷新动态列表后重试"
      return
    }
    dynamicActionLoading = true
    dynamicMessage = nil
    channel.invokeMethod(
      "setNativeDynamicLike",
      arguments: ["id": sourceID, "liked": item.liked]
    ) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.dynamicActionLoading = false
        let result = piliDictionary(response)
        guard result["state"] as? String == "success" else {
          self.dynamicMessage = result["error"] as? String ?? "动态点赞失败"
          return
        }
        let nowLiked = piliBool(result["liked"])
        self.selectedDynamic?.liked = nowLiked
        self.selectedDynamic?.like = max(0, item.like + (nowLiked ? 1 : -1))
        self.syncSelectedDynamicToList()
        self.dynamicMessage = nowLiked ? "点赞成功" : "已取消点赞"
        self.loadDynamicDetail()
      }
    }
  }

  func beginDynamicComment() {
    guard commentOID != nil else {
      dynamicMessage = "该动态暂时无法评论"
      return
    }
    composerRootRpid = nil
    composerParentRpid = nil
    dynamicMessage = nil
    dynamicComposerMode = "comment"
    dynamicComposerTitle = "发表评论"
    dynamicComposerHint = "友善地发表一条评论"
    dynamicComposerText = ""
    isDynamicComposerPresented = true
  }

  func beginDynamicRepost() {
    dynamicMessage = nil
    dynamicComposerMode = "repost"
    dynamicComposerTitle = "转发动态"
    dynamicComposerHint = "说点什么吧"
    dynamicComposerText = "转发动态"
    composerRootRpid = nil
    composerParentRpid = nil
    isDynamicComposerPresented = true
  }

  func beginCommentReply(_ comment: PiliNativeComment, root: PiliNativeComment? = nil) {
    guard commentOID != nil else {
      dynamicMessage = "该评论区暂时无法回复"
      return
    }
    let rootComment = root ?? comment
    dynamicMessage = nil
    composerRootRpid = rootComment.rpid
    composerParentRpid = comment.rpid
    dynamicComposerMode = "reply"
    dynamicComposerTitle = "回复 \(comment.author)"
    dynamicComposerHint = "回复 @\(comment.author)"
    dynamicComposerText = ""
    isDynamicComposerPresented = true
  }

  func publishDynamicComposer() {
    guard !dynamicActionLoading else { return }
    let text = dynamicComposerText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      dynamicMessage = "内容不能为空"
      return
    }
    dynamicActionLoading = true
    dynamicMessage = nil

    if dynamicComposerMode == "repost" {
      guard let sourceID = selectedDynamic?.validSourceID else {
        dynamicActionLoading = false
        dynamicMessage = "该动态缺少有效编号，请刷新动态列表后重试"
        return
      }
      channel.invokeMethod(
        "repostNativeDynamic",
        arguments: ["id": sourceID, "message": text]
      ) { [weak self] response in
        DispatchQueue.main.async {
          guard let self = self else { return }
          self.dynamicActionLoading = false
          let result = piliDictionary(response)
          guard result["state"] as? String == "success" else {
            self.dynamicMessage = result["error"] as? String ?? "动态转发失败"
            return
          }
          self.selectedDynamic?.forward += 1
          self.syncSelectedDynamicToList()
          self.dynamicMessage = result["message"] as? String ?? "转发成功"
          self.isDynamicComposerPresented = false
          self.loadDynamicDetail()
        }
      }
      return
    }

    guard let oid = commentOID else {
      dynamicActionLoading = false
      dynamicMessage = "评论参数无效"
      return
    }
    let root = composerRootRpid
    let parent = composerParentRpid
    var arguments: [String: Any] = [
      "oid": oid,
      "type": commentType,
      "message": text,
    ]
    if let root = root { arguments["root"] = root }
    if let parent = parent { arguments["parent"] = parent }
    channel.invokeMethod("publishNativeComment", arguments: arguments) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.dynamicActionLoading = false
        let result = piliDictionary(response)
        guard result["state"] as? String == "success" else {
          self.dynamicMessage = result["error"] as? String ?? "评论发布失败"
          return
        }
        self.dynamicMessage = result["message"] as? String ?? "发布成功"
        self.isDynamicComposerPresented = false
        if self.isVideoDetailPresented { self.refreshCurrentVideoDetail() }
        if self.isDynamicDetailPresented { self.loadDynamicDetail() }
        if root == nil {
          if self.isDynamicDetailPresented {
            self.selectedDynamic?.comment += 1
            self.syncSelectedDynamicToList()
          }
          self.loadComments(oid: oid, type: self.commentType)
        } else {
          self.loadComments(oid: oid, type: self.commentType)
          if self.isCommentThreadPresented {
            self.loadCommentThread()
          }
        }
      }
    }
  }

  func openCommentThread(_ comment: PiliNativeComment) {
    commentThreadRoot = comment
    commentThreadItems = []
    commentThreadError = nil
    commentThreadTotal = comment.replyCount
    commentThreadPage = 1
    commentThreadOffset = nil
    commentThreadHasMore = false
    commentThreadLoadingMore = false
    isCommentThreadPresented = true
    loadCommentThread()
  }

  func loadCommentThread() {
    guard let oid = commentOID, let root = commentThreadRoot else { return }
    commentThreadPage = 1
    commentThreadOffset = nil
    commentThreadHasMore = false
    commentThreadLoadingMore = false
    commentThreadLoading = true
    commentThreadError = nil
    requestCommentThreadPage(
      oid: oid,
      root: root,
      page: 1,
      offset: nil,
      append: false
    )
  }

  func loadMoreCommentThread() {
    guard let oid = commentOID,
          let root = commentThreadRoot,
          commentThreadHasMore,
          !commentThreadLoading,
          !commentThreadLoadingMore else { return }
    commentThreadLoadingMore = true
    requestCommentThreadPage(
      oid: oid,
      root: root,
      page: commentThreadPage,
      offset: commentThreadOffset,
      append: true
    )
  }

  private func requestCommentThreadPage(
    oid: Int,
    root: PiliNativeComment,
    page: Int,
    offset: String?,
    append: Bool
  ) {
    var arguments: [String: Any] = [
      "oid": oid,
      "type": commentType,
      "root": root.rpid,
      "page": page,
    ]
    if let offset, !offset.isEmpty { arguments["offset"] = offset }
    channel.invokeMethod(
      "loadNativeCommentReplies",
      arguments: arguments
    ) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self, self.commentThreadRoot?.rpid == root.rpid else { return }
        self.commentThreadLoading = false
        self.commentThreadLoadingMore = false
        let result = piliDictionary(response)
        guard result["state"] as? String == "success" else {
          self.commentThreadError = result["error"] as? String ?? "二级评论加载失败"
          return
        }
        let rows = result["items"] as? [Any] ?? []
        let startIndex = append ? self.commentThreadItems.count : 0
        let newItems = rows.enumerated().map {
          PiliNativeComment(
            map: piliDictionary($0.element),
            index: startIndex + $0.offset
          )
        }
        if append {
          let existingIDs = Set(self.commentThreadItems.map(\.id))
          self.commentThreadItems.append(
            contentsOf: newItems.filter { !existingIDs.contains($0.id) }
          )
        } else {
          self.commentThreadItems = newItems
        }
        self.commentThreadTotal = piliInt(result["total"])
        self.commentThreadHasMore = piliBool(result["hasMore"]) && !newItems.isEmpty
        self.commentThreadOffset = piliString(result["nextOffset"])
        self.commentThreadPage = page + 1
        self.commentThreadError = nil
      }
    }
  }

  func toggleThreadCommentLike(_ comment: PiliNativeComment) {
    guard let oid = commentOID else { return }
    channel.invokeMethod(
      "setNativeCommentLike",
      arguments: [
        "oid": oid,
        "type": commentType,
        "rpid": comment.rpid,
        "liked": comment.liked,
      ]
    ) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self else { return }
        let result = piliDictionary(response)
        guard result["state"] as? String == "success" else {
          self.commentThreadError = result["error"] as? String ?? "评论点赞失败"
          return
        }
        let nowLiked = piliBool(result["liked"])
        if let index = self.commentThreadItems.firstIndex(where: { $0.id == comment.id }) {
          self.commentThreadItems[index].liked = nowLiked
          self.commentThreadItems[index].like = max(
            0,
            self.commentThreadItems[index].like + (nowLiked ? 1 : -1)
          )
        }
        self.loadCommentThread()
        self.loadComments(oid: oid, type: self.commentType, preserveExisting: true)
      }
    }
  }

  private func syncSelectedDynamicToList() {
    guard let selected = selectedDynamic,
          let index = dynamics.firstIndex(where: { $0.sourceID == selected.sourceID }) else { return }
    dynamics[index].like = selected.like
    dynamics[index].liked = selected.liked
    dynamics[index].comment = selected.comment
    dynamics[index].forward = selected.forward
  }

  func presentLibrary(_ kind: String, title: String) {
    libraryKind = kind
    libraryTitle = title
    librarySubtitle = ""
    libraryItems = []
    libraryMediaID = nil
    libraryParentKind = nil
    libraryParentTitle = nil
    isLibraryPresented = true
    loadLibrary(refresh: true)
  }

  func loadLibrary(refresh: Bool) {
    guard !libraryKind.isEmpty else { return }
    if refresh {
      libraryPage = 1
      libraryNextMax = nil
      libraryNextViewAt = nil
      libraryLoading = true
      libraryError = nil
      libraryHasMore = false
    } else {
      guard libraryHasMore && !libraryLoading && !libraryLoadingMore else { return }
      libraryLoadingMore = true
    }

    var arguments: [String: Any] = [
      "kind": libraryKind,
      "page": libraryPage,
    ]
    if let mediaID = libraryMediaID { arguments["mediaId"] = mediaID }
    if let nextMax = libraryNextMax { arguments["max"] = nextMax }
    if let nextViewAt = libraryNextViewAt { arguments["viewAt"] = nextViewAt }

    channel.invokeMethod("loadNativeLibrary", arguments: arguments) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self else { return }
        let wasLoadingMore = self.libraryLoadingMore
        self.libraryLoading = false
        self.libraryLoadingMore = false
        if let error = response as? FlutterError {
          self.libraryError = error.message ?? "列表加载失败"
          return
        }
        let result = piliDictionary(response)
        guard result["state"] as? String == "success" else {
          self.libraryError = result["error"] as? String ?? "列表加载失败"
          return
        }
        let rows = result["items"] as? [Any] ?? []
        let newItems = rows.enumerated().map {
          PiliNativeLibraryItem(map: piliDictionary($0.element), index: $0.offset)
        }
        if wasLoadingMore {
          let existingIDs = Set(self.libraryItems.map(\.id))
          self.libraryItems.append(contentsOf: newItems.filter { !existingIDs.contains($0.id) })
        } else {
          self.libraryItems = newItems
        }
        self.libraryTitle = piliString(result["title"]) ?? self.libraryTitle
        self.librarySubtitle = piliString(result["subtitle"]) ?? ""
        self.libraryHasMore = piliBool(result["hasMore"])
        self.libraryNextMax = piliOptionalInt(result["nextMax"])
        self.libraryNextViewAt = piliOptionalInt(result["nextViewAt"])
        self.libraryError = nil
        self.libraryPage += 1
      }
    }
  }

  func openLibraryItem(_ item: PiliNativeLibraryItem) {
    if item.kind == "folder", let folderID = item.folderID {
      libraryParentKind = libraryKind
      libraryParentTitle = libraryTitle
      libraryKind = "favoriteDetail"
      libraryTitle = item.title
      librarySubtitle = item.subtitle
      libraryMediaID = folderID
      libraryItems = []
      loadLibrary(refresh: true)
      return
    }

    if item.kind == "subscription", let folderID = item.folderID {
      libraryParentKind = libraryKind
      libraryParentTitle = libraryTitle
      libraryKind = item.folderType == 11 ? "favoriteDetail" : "subscriptionDetail"
      libraryTitle = item.title
      librarySubtitle = item.subtitle
      libraryMediaID = folderID
      libraryItems = []
      loadLibrary(refresh: true)
      return
    }

    if item.kind == "member", let memberID = item.memberID {
      isLibraryPresented = false
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
        self?.presentProfile(memberID)
      }
      return
    }

    if let bvid = item.bvid, !bvid.isEmpty {
      var videoMap: [String: Any] = [
        "id": item.sourceID,
        "bvid": bvid,
        "title": item.title,
        "owner": item.subtitle,
        "viewText": item.viewText,
        "danmakuText": item.danmakuText,
        "durationText": item.durationText,
      ]
      if let aid = item.aid { videoMap["aid"] = aid }
      if let cover = item.cover { videoMap["cover"] = cover }
      let video = PiliNativeVideo(
        map: videoMap,
        index: 0
      )
      isLibraryPresented = false
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
        self?.openVideo(video)
      }
      return
    }

    openLibraryFallback(item: item)
  }

  var libraryCanGoBack: Bool {
    libraryParentKind != nil
  }

  func returnToLibraryRoot() {
    libraryKind = libraryParentKind ?? "favorites"
    libraryTitle = libraryParentTitle ?? "我的收藏"
    librarySubtitle = ""
    libraryMediaID = nil
    libraryParentKind = nil
    libraryParentTitle = nil
    libraryItems = []
    loadLibrary(refresh: true)
  }

  private func openLibraryFallback(item: PiliNativeLibraryItem) {
    libraryError = "该内容类型尚未提供原生操作"
  }

  func presentProfile(_ memberID: Int) {
    profileMID = memberID
    profile = nil
    profileError = nil
    profileMessage = nil
    profileVideosPage = 1
    profileVideosHasMore = false
    profileVideosLoading = false
    profileVideosLoadingMore = false
    profileVideosError = nil
    isProfilePresented = true
    loadProfile()
  }

  func loadProfile() {
    guard let memberID = profileMID else { return }
    profileLoading = true
    profileError = nil
    channel.invokeMethod("loadNativeProfile", arguments: ["mid": memberID]) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.profileLoading = false
        if let flutterError = response as? FlutterError {
          self.profileError = flutterError.message ?? "个人空间加载失败"
          return
        }
        let result = piliDictionary(response)
        guard result["state"] as? String == "success" else {
          self.profileError = result["error"] as? String ?? "个人空间加载失败"
          return
        }
        self.profile = PiliNativeProfile(map: piliDictionary(result["profile"]))
        self.loadProfileVideos(refresh: true)
      }
    }
  }

  func loadMoreProfileVideos() {
    loadProfileVideos(refresh: false)
  }

  func reloadProfileVideos() {
    loadProfileVideos(refresh: true)
  }

  private func loadProfileVideos(refresh: Bool) {
    guard let memberID = profileMID, profile != nil else { return }
    if refresh {
      profileVideosPage = 1
      profileVideosHasMore = false
      profileVideosLoading = true
      profileVideosLoadingMore = false
      profileVideosError = nil
    } else {
      guard profileVideosHasMore,
            !profileVideosLoading,
            !profileVideosLoadingMore else { return }
      profileVideosLoadingMore = true
    }

    let page = profileVideosPage
    channel.invokeMethod(
      "loadNativeProfileVideos",
      arguments: ["mid": memberID, "page": page]
    ) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self, self.profileMID == memberID else { return }
        self.profileVideosLoading = false
        self.profileVideosLoadingMore = false
        if let flutterError = response as? FlutterError {
          self.profileVideosError = flutterError.message ?? "用户投稿加载失败"
          return
        }
        let result = piliDictionary(response)
        guard result["state"] as? String == "success" else {
          self.profileVideosError = result["error"] as? String ?? "用户投稿加载失败"
          return
        }
        let rows = result["items"] as? [Any] ?? []
        let startIndex = page == 1 ? 0 : (self.profile?.videos.count ?? 0)
        let newItems = rows.enumerated().map {
          PiliNativeVideo(
            map: piliDictionary($0.element),
            index: startIndex + $0.offset
          )
        }
        if page == 1 {
          self.profile?.videos = newItems
        } else {
          let existingSourceIDs = Set(self.profile?.videos.map(\.sourceID) ?? [])
          self.profile?.videos.append(
            contentsOf: newItems.filter { !existingSourceIDs.contains($0.sourceID) }
          )
        }
        self.profile?.videoCount = max(
          piliInt(result["total"]),
          self.profile?.videos.count ?? 0
        )
        self.profileVideosHasMore = piliBool(result["hasMore"]) && !newItems.isEmpty
        self.profileVideosPage = page + 1
        self.profileVideosError = nil
      }
    }
  }

  func toggleProfileFollow() {
    guard let profile = profile, !profile.isSelf, !profileActionLoading else { return }
    let target = !profile.isFollowing
    profileActionLoading = true
    profileMessage = nil
    channel.invokeMethod(
      "setNativeProfileFollow",
      arguments: ["mid": profile.mid, "follow": target]
    ) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.profileActionLoading = false
        let result = piliDictionary(response)
        if result["state"] as? String == "success" {
          self.profile?.isFollowing = piliBool(result["isFollowing"])
          self.profileMessage = result["message"] as? String
        } else {
          self.profileMessage = result["error"] as? String ?? "操作失败"
        }
      }
    }
  }

  func openProfileVideo(_ video: PiliNativeVideo) {
    isProfilePresented = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
      self?.openVideo(video)
    }
  }

}

private struct PiliNativeVideo: Identifiable {
  let id: String
  let sourceID: String
  let aid: Int?
  let bvid: String?
  let title: String
  let cover: String?
  let owner: String
  let viewText: String
  let danmakuText: String
  let durationText: String
  let pubdateText: String

  init(map: [String: Any], index: Int) {
    sourceID = piliString(map["id"]) ?? "video"
    id = "\(sourceID)-\(index)"
    aid = piliOptionalInt(map["aid"])
    bvid = piliString(map["bvid"])
    title = piliString(map["title"]) ?? "未命名视频"
    cover = piliString(map["cover"])
    owner = piliString(map["owner"]) ?? ""
    viewText = piliString(map["viewText"]) ?? ""
    danmakuText = piliString(map["danmakuText"]) ?? ""
    durationText = piliString(map["durationText"]) ?? ""
    pubdateText = piliString(map["pubdateText"]) ?? ""
  }
}

private struct PiliNativeLiveRoom: Identifiable {
  let id: String
  let sourceID: String
  let roomID: Int
  let title: String
  let cover: String?
  let owner: String
  let ownerFace: String?
  let area: String
  let viewText: String

  init(map: [String: Any], index: Int) {
    sourceID = piliString(map["id"]) ?? "live-\(index)"
    id = "\(sourceID)-\(index)"
    roomID = piliInt(map["roomId"])
    title = piliString(map["title"]) ?? "直播间"
    cover = piliString(map["cover"])
    owner = piliString(map["owner"]) ?? "主播"
    ownerFace = piliString(map["ownerFace"])
    area = piliString(map["area"]) ?? "直播"
    viewText = piliString(map["viewText"]) ?? ""
  }
}

private struct PiliNativeVideoPart: Identifiable {
  let id: String
  let index: Int
  let cid: Int?
  let title: String
  let durationText: String
  let cover: String?

  init(map: [String: Any], fallbackIndex: Int) {
    index = piliOptionalInt(map["index"]) ?? fallbackIndex + 1
    cid = piliOptionalInt(map["cid"])
    id = "\(cid ?? index)-\(index)"
    title = piliString(map["title"]) ?? "P\(index)"
    durationText = piliString(map["durationText"]) ?? ""
    cover = piliString(map["cover"])
  }
}

private struct PiliNativeVideoTag: Identifiable {
  let id: String
  let name: String
  let type: String

  init(map: [String: Any], index: Int) {
    name = piliString(map["name"]) ?? "标签"
    type = piliString(map["type"]) ?? ""
    id = "\(piliOptionalInt(map["id"]) ?? index)-\(name)"
  }
}

private struct PiliNativeVideoStaff: Identifiable {
  let id: String
  let memberID: Int?
  let name: String
  let title: String
  let face: String?

  init(map: [String: Any], index: Int) {
    memberID = piliOptionalInt(map["id"])
    name = piliString(map["name"]) ?? "创作成员"
    title = piliString(map["title"]) ?? ""
    face = piliString(map["face"])
    id = "\(memberID ?? index)-\(name)"
  }
}

private struct PiliNativeVideoDetail {
  let aid: Int?
  let bvid: String
  let cid: Int?
  let title: String
  let cover: String?
  let durationText: String
  let owner: String
  let ownerID: Int?
  let ownerFace: String?
  let description: String
  let pubdateText: String
  let viewText: String
  let danmakuText: String
  var reply: Int
  var like: Int
  var coin: Int
  var favorite: Int
  let share: Int
  var liked: Bool
  var coinCount: Int
  var favorited: Bool
  let relationLoaded: Bool
  let copyrightText: String
  let isVertical: Bool
  let argueMessage: String
  let collectionTitle: String
  let collectionID: Int?
  let collectionCount: Int
  let collectionItems: [PiliNativeVideo]
  let tags: [PiliNativeVideoTag]
  let staff: [PiliNativeVideoStaff]
  let pages: [PiliNativeVideoPart]

  init(map: [String: Any]) {
    aid = piliOptionalInt(map["aid"])
    bvid = piliString(map["bvid"]) ?? ""
    cid = piliOptionalInt(map["cid"])
    title = piliString(map["title"]) ?? "未命名视频"
    cover = piliString(map["cover"])
    durationText = piliString(map["durationText"]) ?? ""
    owner = piliString(map["owner"]) ?? ""
    ownerID = piliOptionalInt(map["ownerId"])
    ownerFace = piliString(map["ownerFace"])
    description = piliString(map["description"]) ?? ""
    pubdateText = piliString(map["pubdateText"]) ?? ""
    viewText = piliString(map["viewText"]) ?? ""
    danmakuText = piliString(map["danmakuText"]) ?? ""
    reply = piliInt(map["reply"])
    like = piliInt(map["like"])
    coin = piliInt(map["coin"])
    favorite = piliInt(map["favorite"])
    share = piliInt(map["share"])
    liked = piliBool(map["liked"])
    coinCount = piliInt(map["coinCount"])
    favorited = piliBool(map["favorited"])
    relationLoaded = piliBool(map["relationLoaded"])
    copyrightText = piliString(map["copyrightText"]) ?? ""
    isVertical = piliBool(map["isVertical"])
    argueMessage = piliString(map["argueMessage"]) ?? ""
    collectionTitle = piliString(map["collectionTitle"]) ?? ""
    collectionID = piliOptionalInt(map["collectionId"])
    collectionCount = piliInt(map["collectionCount"])
    let collectionRows = map["collectionItems"] as? [Any] ?? []
    collectionItems = collectionRows.enumerated().map {
      PiliNativeVideo(map: piliDictionary($0.element), index: $0.offset)
    }
    let tagRows = map["tags"] as? [Any] ?? []
    tags = tagRows.enumerated().map {
      PiliNativeVideoTag(map: piliDictionary($0.element), index: $0.offset)
    }
    let staffRows = map["staff"] as? [Any] ?? []
    staff = staffRows.enumerated().map {
      PiliNativeVideoStaff(map: piliDictionary($0.element), index: $0.offset)
    }
    let rows = map["pages"] as? [Any] ?? []
    pages = rows.enumerated().map {
      PiliNativeVideoPart(map: piliDictionary($0.element), fallbackIndex: $0.offset)
    }
  }
}

private struct PiliNativeVideoQualityOption: Identifiable {
  let value: Int
  let label: String
  let shortLabel: String

  var id: Int { value }

  init?(map: [String: Any], index: Int) {
    guard let value = piliOptionalInt(map["value"]) else { return nil }
    self.value = value
    label = piliString(map["label"]) ?? "画质 \(index + 1)"
    shortLabel = piliString(map["shortLabel"]) ?? label
  }
}

private struct PiliNativeSetting: Identifiable {
  let id: String
  let key: String
  let title: String
  let subtitle: String
  let group: String
  let icon: String
  var value: Bool
  let needsRestart: Bool

  init(map: [String: Any], index: Int) {
    key = piliString(map["key"]) ?? "setting-\(index)"
    id = key
    title = piliString(map["title"]) ?? key
    subtitle = piliString(map["subtitle"]) ?? ""
    group = piliString(map["group"]) ?? "其他"
    icon = piliString(map["icon"]) ?? "gearshape"
    value = piliBool(map["value"])
    needsRestart = piliBool(map["needsRestart"])
  }
}

private struct PiliNativeLibraryItem: Identifiable {
  let id: String
  let sourceID: String
  let kind: String
  let title: String
  let subtitle: String
  let cover: String?
  let aid: Int?
  let bvid: String?
  let folderID: Int?
  let folderType: Int?
  let memberID: Int?
  let durationText: String
  let progressText: String
  let progress: Double
  let badge: String
  let trailingText: String
  let viewText: String
  let danmakuText: String
  let fallbackRoute: String
  let fallbackParameters: [String: String]

  init(map: [String: Any], index: Int) {
    sourceID = piliString(map["id"]) ?? "library-\(index)"
    id = sourceID
    kind = piliString(map["kind"]) ?? "video"
    title = piliString(map["title"]) ?? "未命名内容"
    subtitle = piliString(map["subtitle"]) ?? ""
    cover = piliString(map["cover"])
    aid = piliOptionalInt(map["aid"])
    bvid = piliString(map["bvid"])
    folderID = piliOptionalInt(map["folderId"])
    folderType = piliOptionalInt(map["folderType"])
    memberID = piliOptionalInt(map["memberId"])
    durationText = piliString(map["durationText"]) ?? ""
    progressText = piliString(map["progressText"]) ?? ""
    progress = min(max(piliDouble(map["progress"]), 0), 1)
    badge = piliString(map["badge"]) ?? ""
    trailingText = piliString(map["trailingText"]) ?? ""
    viewText = piliString(map["viewText"]) ?? ""
    danmakuText = piliString(map["danmakuText"]) ?? ""
    fallbackRoute = piliString(map["fallbackRoute"]) ?? ""
    let rawParameters = piliDictionary(map["fallbackParameters"])
    fallbackParameters = rawParameters.reduce(into: [String: String]()) { result, pair in
      if let value = piliString(pair.value) { result[pair.key] = value }
    }
  }
}

private struct PiliNativeDynamic: Identifiable {
  let id: String
  let sourceID: String
  let authorID: Int?
  let author: String
  let avatar: String?
  let time: String
  let title: String
  let body: String
  let cover: String?
  let coverWidth: CGFloat
  let coverHeight: CGFloat
  let pictures: [PiliNativeCommentPicture]
  let aid: Int?
  let bvid: String?
  let commentOID: Int?
  let commentType: Int?
  var like: Int
  var liked: Bool
  var comment: Int
  var forward: Int

  init(map: [String: Any], index: Int) {
    sourceID = piliString(map["id"]) ?? ""
    id = sourceID.isEmpty ? "dynamic-\(index)" : "\(sourceID)-\(index)"
    authorID = piliOptionalInt(map["authorId"])
    author = piliString(map["author"]) ?? ""
    avatar = piliString(map["avatar"])
    time = piliString(map["time"]) ?? ""
    title = piliString(map["title"]) ?? ""
    body = piliString(map["body"]) ?? ""
    cover = piliString(map["cover"])
    coverWidth = CGFloat(max(0, piliDouble(map["coverWidth"])))
    coverHeight = CGFloat(max(0, piliDouble(map["coverHeight"])))
    var mappedPictures = (map["pictures"] as? [Any])?.compactMap {
      PiliNativeCommentPicture(value: $0)
    } ?? []
    if mappedPictures.isEmpty, let cover {
      mappedPictures = [
        PiliNativeCommentPicture(
          url: cover,
          width: coverWidth,
          height: coverHeight
        ),
      ]
    }
    pictures = mappedPictures
    aid = piliOptionalInt(map["aid"])
    bvid = piliString(map["bvid"])
    commentOID = piliOptionalInt(map["commentOid"])
    commentType = piliOptionalInt(map["commentType"])
    like = piliInt(map["like"])
    liked = piliBool(map["liked"])
    comment = piliInt(map["comment"])
    forward = piliInt(map["forward"])
  }

  var validSourceID: String? {
    guard !sourceID.isEmpty,
          sourceID.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) else {
      return nil
    }
    return sourceID
  }
}

private struct PiliNativeMessage: Identifiable {
  let id: String
  let kind: String
  let talkerID: Int?
  let memberID: Int?
  let author: String
  let avatar: String?
  let body: String
  let context: String
  let cover: String?
  let time: String
  let badge: String
  let unreadCount: Int
  let hasUnread: Bool
  let isMuted: Bool
  let isPinned: Bool
  let isLive: Bool

  init(map: [String: Any], index: Int) {
    id = piliString(map["id"]) ?? "message-\(index)"
    kind = piliString(map["kind"]) ?? "system"
    talkerID = piliOptionalInt(map["talkerId"])
    memberID = piliOptionalInt(map["memberId"])
    author = piliString(map["author"]) ?? "消息"
    avatar = piliString(map["avatar"])
    body = piliString(map["body"]) ?? ""
    context = piliString(map["context"]) ?? ""
    cover = piliString(map["cover"])
    time = piliString(map["time"]) ?? ""
    badge = piliString(map["badge"]) ?? ""
    unreadCount = piliOptionalInt(map["unreadCount"]) ?? 0
    hasUnread = piliBool(map["hasUnread"])
    isMuted = piliBool(map["isMuted"])
    isPinned = piliBool(map["isPinned"])
    isLive = piliBool(map["isLive"])
  }
}

private struct PiliNativeChatMessage: Identifiable {
  let id: String
  let msgKey: Int
  let sequence: Int
  let type: Int
  let isOwner: Bool
  let text: String
  let image: String?
  let cover: String?
  let title: String?
  let time: String
  let imageWidth: Double?
  let imageHeight: Double?
  let emote: String?
  let emotes: [String: PiliNativeCommentEmote]
  let isSystem: Bool
  let isRecalled: Bool
  let isAutoReply: Bool

  init(map: [String: Any], index: Int) {
    id = piliString(map["id"]) ?? "chat-\(index)"
    msgKey = piliInt(map["msgKey"])
    sequence = piliInt(map["sequence"])
    type = piliInt(map["type"])
    isOwner = piliBool(map["isOwner"])
    text = piliString(map["text"]) ?? ""
    image = piliString(map["image"])
    cover = piliString(map["cover"])
    title = piliString(map["title"])
    time = piliString(map["time"]) ?? ""
    imageWidth = piliOptionalDouble(map["imageWidth"])
    imageHeight = piliOptionalDouble(map["imageHeight"])
    emote = piliString(map["emote"])
    let emoteRows = map["emotes"] as? [Any] ?? []
    var parsedEmotes: [String: PiliNativeCommentEmote] = [:]
    for row in emoteRows {
      let value = piliDictionary(row)
      guard
        let text = piliString(value["text"]),
        let url = piliString(value["url"])
      else { continue }
      parsedEmotes[text] = PiliNativeCommentEmote(
        text: text,
        url: url,
        size: min(max(piliInt(value["size"]), 1), 2)
      )
    }
    emotes = parsedEmotes
    isSystem = piliBool(map["isSystem"])
    isRecalled = piliBool(map["isRecalled"])
    isAutoReply = piliBool(map["isAutoReply"])
  }
}

private struct PiliNativeComment: Identifiable {
  let id: String
  let rpid: Int
  let memberID: Int?
  let author: String
  let avatar: String?
  let message: String
  let time: String
  let location: String
  var like: Int
  var liked: Bool
  let replyCount: Int
  let level: Int
  let pictures: [PiliNativeCommentPicture]
  let emotes: [String: PiliNativeCommentEmote]

  init(map: [String: Any], index: Int) {
    id = piliString(map["id"]) ?? "comment-\(index)"
    rpid = piliInt(map["rpid"])
    memberID = piliOptionalInt(map["memberId"])
    author = piliString(map["author"]) ?? "用户"
    avatar = piliString(map["avatar"])
    message = piliString(map["message"]) ?? ""
    time = piliString(map["time"]) ?? ""
    location = piliString(map["location"]) ?? ""
    like = piliInt(map["like"])
    liked = piliBool(map["liked"])
    replyCount = piliInt(map["replyCount"])
    level = piliInt(map["level"])
    pictures = (map["pictures"] as? [Any])?.compactMap {
      PiliNativeCommentPicture(value: $0)
    } ?? []
    let emoteRows = map["emotes"] as? [Any] ?? []
    let emotePairs: [(String, PiliNativeCommentEmote)] = emoteRows.compactMap {
      row -> (String, PiliNativeCommentEmote)? in
      let value = piliDictionary(row)
      guard
        let text = piliString(value["text"]),
        let url = piliString(value["url"])
      else { return nil }
      return (
        text,
        PiliNativeCommentEmote(
          text: text,
          url: url,
          size: min(max(piliInt(value["size"]), 1), 2)
        )
      )
    }
    emotes = Dictionary(uniqueKeysWithValues: emotePairs)
  }
}

private struct PiliNativeCommentPicture: Hashable {
  let url: String
  let width: CGFloat
  let height: CGFloat

  init(url: String, width: CGFloat, height: CGFloat) {
    self.url = url
    self.width = max(width, 0)
    self.height = max(height, 0)
  }

  init?(value: Any) {
    if let url = piliString(value) {
      self.url = url
      width = 0
      height = 0
      return
    }
    let map = piliDictionary(value)
    guard let url = piliString(map["url"]) else { return nil }
    self.url = url
    width = CGFloat(max(piliDouble(map["width"]), 0))
    height = CGFloat(max(piliDouble(map["height"]), 0))
  }
}

private struct PiliNativeCommentEmote: Hashable {
  let text: String
  let url: String
  let size: Int
}

private struct PiliNativeDownload: Identifiable {
  let id: String
  let aid: Int?
  let bvid: String?
  let title: String
  let subtitle: String
  let cover: String?
  let progress: Double
  let progressText: String
  let badge: String

  init(map: [String: Any], index: Int) {
    id = piliString(map["id"]) ?? "download-\(index)"
    aid = piliOptionalInt(map["aid"])
    bvid = piliString(map["bvid"])
    title = piliString(map["title"]) ?? "离线视频"
    subtitle = piliString(map["subtitle"]) ?? ""
    cover = piliString(map["cover"])
    progress = min(max(piliDouble(map["progress"]), 0), 1)
    progressText = piliString(map["progressText"]) ?? ""
    badge = piliString(map["badge"]) ?? ""
  }
}

private struct PiliNativeAccount {
  let isLogin: Bool
  let mid: Int?
  let name: String
  let face: String?
  let level: Int
  let money: Double
  let following: Int
  let followers: Int
  let dynamics: Int
  let favoriteCount: Int

  init(map: [String: Any] = [:]) {
    isLogin = piliBool(map["isLogin"])
    mid = piliOptionalInt(map["mid"])
    name = piliString(map["name"]) ?? "点击登录"
    face = piliString(map["face"]) ?? piliString(map["avatarFallback"])
    level = piliInt(map["level"])
    money = piliDouble(map["money"])
    following = piliInt(map["following"])
    followers = piliInt(map["followers"])
    dynamics = piliInt(map["dynamics"])
    favoriteCount = piliInt(map["favoriteCount"])
  }
}

private struct PiliNativeProfile {
  let mid: Int
  let name: String
  let face: String?
  let topImage: String?
  let sign: String
  let level: Int
  let followers: Int
  let following: Int
  let likes: Int
  let official: String
  let vip: Bool
  let isSelf: Bool
  var isFollowing: Bool
  var videoCount: Int
  let tags: [String]
  var videos: [PiliNativeVideo]

  init(map: [String: Any]) {
    mid = piliInt(map["mid"])
    name = piliString(map["name"]) ?? "用户"
    face = piliString(map["face"])
    topImage = piliString(map["topImage"])
    sign = piliString(map["sign"]) ?? ""
    level = piliInt(map["level"])
    followers = piliInt(map["followers"])
    following = piliInt(map["following"])
    likes = piliInt(map["likes"])
    official = piliString(map["official"]) ?? ""
    vip = piliBool(map["vip"])
    isSelf = piliBool(map["isSelf"])
    isFollowing = piliBool(map["isFollowing"])
    videoCount = piliInt(map["videoCount"])
    tags = (map["tags"] as? [Any])?.compactMap { piliString($0) } ?? []
    let rows = map["videos"] as? [Any] ?? []
    videos = rows.enumerated().map {
      PiliNativeVideo(map: piliDictionary($0.element), index: $0.offset)
    }
  }
}

// MARK: - Native navigation gestures

private struct PiliEdgeSwipeBackModifier: ViewModifier {
  let action: () -> Void

  func body(content: Content) -> some View {
    content
      .contentShape(Rectangle())
      .simultaneousGesture(
        DragGesture(minimumDistance: 18, coordinateSpace: .global)
          .onEnded { value in
            let horizontalDistance = value.translation.width
            let verticalDistance = abs(value.translation.height)
            guard value.startLocation.x <= 30,
                  horizontalDistance >= 86,
                  horizontalDistance > verticalDistance * 1.35 else { return }
            action()
          }
      )
  }
}

private extension View {
  func piliEdgeSwipeBack(_ action: @escaping () -> Void) -> some View {
    modifier(PiliEdgeSwipeBackModifier(action: action))
  }
}

// MARK: - Root tabs

private struct PiliNativeRootView: View {
  @ObservedObject var model: PiliNativeViewModel

  private var selection: Binding<Int> {
    Binding(
      get: { model.selectedIndex },
      set: { model.userSelectedTab($0) }
    )
  }

  var body: some View {
    TabView(selection: selection) {
      ForEach(Array(model.tabTitles.enumerated()), id: \.offset) { item in
        content(for: item.element)
          .tabItem {
            tabIcon(for: item.element, selected: model.selectedIndex == item.offset)
            Text(tabLabel(for: item.element))
          }
          .tag(item.offset)
      }
    }
    .accentColor(piliAccent)
    .sheet(isPresented: $model.isSearchPresented) {
      PiliNativeSearchView(model: model)
        .piliEdgeSwipeBack { model.isSearchPresented = false }
    }
    .sheet(isPresented: $model.isSettingsPresented) {
      PiliNativeSettingsView(model: model)
        .piliEdgeSwipeBack { model.isSettingsPresented = false }
    }
    .sheet(isPresented: $model.isLibraryPresented) {
      PiliNativeLibraryView(model: model)
        .piliEdgeSwipeBack { model.isLibraryPresented = false }
    }
    .sheet(isPresented: $model.isMessagesPresented) {
      PiliNativeMessagesView(model: model)
        .piliEdgeSwipeBack { model.isMessagesPresented = false }
    }
    .sheet(isPresented: $model.isDownloadsPresented) {
      PiliNativeDownloadsView(model: model)
        .piliEdgeSwipeBack { model.isDownloadsPresented = false }
    }
    .fullScreenCover(isPresented: $model.isVideoDetailPresented) {
      PiliNativeVideoDetailView(model: model)
        .piliEdgeSwipeBack { model.closeVideoDetail() }
    }
    .fullScreenCover(isPresented: $model.isProfilePresented) {
      PiliNativeProfileView(model: model)
        .piliEdgeSwipeBack { model.isProfilePresented = false }
    }
    .fullScreenCover(isPresented: $model.isDynamicDetailPresented) {
      PiliNativeDynamicDetailView(model: model)
        .piliEdgeSwipeBack { model.isDynamicDetailPresented = false }
    }
    .fullScreenCover(isPresented: $model.isLoginPresented) {
      PiliNativeLoginView(model: model)
        .piliEdgeSwipeBack { model.isLoginPresented = false }
    }
    .onAppear {
      UIDevice.current.beginGeneratingDeviceOrientationNotifications()
      model.requestSnapshot()
    }
    .onDisappear {
      UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }
    .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
      model.handleVideoDeviceOrientation(UIDevice.current.orientation)
    }
    .onReceive(NotificationCenter.default.publisher(for: .piliPresentNativeProfile)) { note in
      if let memberID = note.object as? Int {
        model.presentProfile(memberID)
      }
    }
  }

  private func content(for title: String) -> AnyView {
    if title.contains("动态") {
      return AnyView(PiliNativeDynamicsView(model: model))
    }
    if title.contains("我") || title.contains("账号") {
      return AnyView(PiliNativeMineView(model: model))
    }
    return AnyView(PiliNativeHomeView(model: model))
  }

  @ViewBuilder
  private func tabIcon(for title: String, selected: Bool) -> some View {
    if title.contains("动态") {
      PiliOriginalIcon(
        family: .custom,
        codePoint: selected ? 0xe80a : 0xe80b,
        fallback: "sparkles",
        size: 21
      )
    } else if title.contains("我") || title.contains("账号") {
      PiliOriginalIcon(
        family: .material,
        codePoint: selected ? 0xe491 : 0xe497,
        fallback: selected ? "person.fill" : "person",
        size: 22
      )
    } else {
      PiliOriginalIcon(
        family: .material,
        codePoint: selected ? 0xe318 : 0xf107,
        fallback: selected ? "house.fill" : "house",
        size: 22
      )
    }
  }

  private func tabLabel(for title: String) -> String {
    if title.contains("动态") && !model.dynamicBadge.isEmpty {
      return "\(title) \(model.dynamicBadge)"
    }
    return title
  }
}

private enum PiliNativeHomeZone: Int, CaseIterable, Identifiable {
  case live
  case recommend
  case hot

  var id: Int { rawValue }
  var title: String {
    switch self {
    case .live: return "直播"
    case .recommend: return "推荐"
    case .hot: return "热门"
    }
  }
  var key: String {
    switch self {
    case .live: return "live"
    case .recommend: return "recommend"
    case .hot: return "hot"
    }
  }
}

private struct PiliNativeHomeView: View {
  @ObservedObject var model: PiliNativeViewModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var selectedZone = PiliNativeHomeZone.recommend
  private let columns = [
    GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top),
    GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top),
  ]

  var body: some View {
    NavigationStack {
      GeometryReader { geometry in
        // Capture the bar insets before expanding the pager. The scroll views
        // draw behind the system glass; only their content needs these insets.
        TabView(selection: $selectedZone) {
          livePage(contentInsets: geometry.safeAreaInsets)
            .tag(PiliNativeHomeZone.live)
          recommendPage(contentInsets: geometry.safeAreaInsets)
            .tag(PiliNativeHomeZone.recommend)
          hotPage(contentInsets: geometry.safeAreaInsets)
            .tag(PiliNativeHomeZone.hot)
        }
        .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
        .ignoresSafeArea(.container, edges: .vertical)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selectedZone)
      }
      .background(Color(UIColor.systemBackground))
      .navigationTitle("PiliGlass")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button(action: { model.isSearchPresented = true }) {
            Label("搜索", systemImage: "magnifyingglass")
          }
          .tint(.primary)
        }
        ToolbarItem(placement: .principal) {
          zoneSelector
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
          if model.account.isLogin {
            Button(action: { model.isMessagesPresented = true }) {
              Label("消息", systemImage: "bell")
            }
            .tint(.primary)
          }
          Button(action: selectMine) {
            if let face = model.account.face {
              PiliRemoteImage(urlString: face)
                .frame(width: 28, height: 28)
                .clipShape(Circle())
            } else {
              Image(systemName: "person.crop.circle")
            }
          }
          .tint(.primary)
          .accessibilityLabel("我的")
        }
      }
    }
    .onChange(of: selectedZone) { zone in
      model.loadHomeZone(zone.key)
    }
  }

  private var zoneSelector: some View {
    Picker("首页分区", selection: $selectedZone) {
      ForEach(PiliNativeHomeZone.allCases) { zone in
        Text(zone.title).tag(zone)
      }
    }
    .pickerStyle(.segmented)
    .frame(minWidth: 144, idealWidth: 190, maxWidth: 240)
  }

  private func feed<Content: View>(
    contentInsets: EdgeInsets,
    @ViewBuilder content: () -> Content
  ) -> some View {
    ScrollView {
      VStack(spacing: 0) {
        content()
      }
      .padding(.horizontal, 12)
      .padding(.top, contentInsets.top + 12)
      .padding(.bottom, contentInsets.bottom + 24)
    }
  }

  @ViewBuilder private func recommendPage(contentInsets: EdgeInsets) -> some View {
    if model.homeLoading && model.homeVideos.isEmpty {
      PiliNativeLoadingView(title: "正在加载推荐")
        .padding(contentInsets)
    } else if let error = model.homeError, model.homeVideos.isEmpty {
      PiliNativeErrorView(message: error) { model.refresh("home") }
        .padding(contentInsets)
    } else {
      feed(contentInsets: contentInsets) {
        LazyVGrid(columns: columns, spacing: 14) {
          ForEach(model.homeVideos) { video in
            PiliNativeVideoCard(video: video) { model.openVideo(video) }
              .onAppear {
                if video.id == model.homeVideos.last?.id { model.loadMore("home") }
              }
          }
        }
        if model.homeLoadingMore { ProgressView().padding(.vertical, 20) }
      }
      .refreshable { model.refresh("home") }
    }
  }

  @ViewBuilder private func livePage(contentInsets: EdgeInsets) -> some View {
    if model.liveLoading && model.liveRooms.isEmpty {
      PiliNativeLoadingView(title: "正在加载直播")
        .padding(contentInsets)
    } else if let error = model.liveError, model.liveRooms.isEmpty {
      PiliNativeErrorView(message: error) { model.loadHomeZone("live", refresh: true) }
        .padding(contentInsets)
    } else {
      feed(contentInsets: contentInsets) {
        LazyVGrid(columns: columns, spacing: 14) {
          ForEach(model.liveRooms) { room in
            PiliNativeLiveRoomCard(room: room) { model.openLiveRoom(room) }
              .onAppear {
                if room.id == model.liveRooms.last?.id { model.loadMoreHomeZone("live") }
              }
          }
        }
        if model.liveLoadingMore { ProgressView().padding(.vertical, 20) }
      }
      .refreshable { model.loadHomeZone("live", refresh: true) }
      .onAppear { model.loadHomeZone("live") }
    }
  }

  @ViewBuilder private func hotPage(contentInsets: EdgeInsets) -> some View {
    if model.hotLoading && model.hotVideos.isEmpty {
      PiliNativeLoadingView(title: "正在加载热门")
        .padding(contentInsets)
    } else if let error = model.hotError, model.hotVideos.isEmpty {
      PiliNativeErrorView(message: error) { model.loadHomeZone("hot", refresh: true) }
        .padding(contentInsets)
    } else {
      feed(contentInsets: contentInsets) {
        LazyVGrid(columns: columns, spacing: 14) {
          ForEach(model.hotVideos) { video in
            PiliNativeVideoCard(video: video) { model.openVideo(video) }
              .onAppear {
                if video.id == model.hotVideos.last?.id { model.loadMoreHomeZone("hot") }
              }
          }
        }
        if model.hotLoadingMore { ProgressView().padding(.vertical, 20) }
      }
      .refreshable { model.loadHomeZone("hot", refresh: true) }
      .onAppear { model.loadHomeZone("hot") }
    }
  }

  private func selectMine() {
    if let index = model.tabTitles.firstIndex(where: { $0.contains("我") || $0.contains("账号") }) {
      model.userSelectedTab(index)
    }
  }
}

private struct PiliNativeHomeCover: View {
  let urlString: String?

  var body: some View {
    Color(UIColor.tertiarySystemFill)
      .aspectRatio(16 / 9, contentMode: .fit)
      .overlay {
        PiliRemoteImage(urlString: urlString)
          .scaledToFill()
      }
      .clipped()
  }
}

private struct PiliNativeVideoCard: View {
  let video: PiliNativeVideo
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 7) {
        ZStack(alignment: .bottomTrailing) {
          PiliNativeHomeCover(urlString: video.cover)

          if !video.durationText.isEmpty {
            Text(video.durationText)
              .font(.caption2)
              .foregroundColor(.white)
              .padding(.horizontal, 5)
              .padding(.vertical, 3)
              .background(Color.black.opacity(0.68))
              .cornerRadius(4)
              .padding(5)
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

        Text(video.title)
          .font(.subheadline)
          .fontWeight(.medium)
          .foregroundColor(.primary)
          .lineLimit(2, reservesSpace: true)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)

        HStack(spacing: 4) {
          Image(systemName: "person")
          Text(video.owner)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.caption)
        .foregroundColor(.secondary)

        HStack(spacing: 4) {
          if !video.viewText.isEmpty {
            Image(systemName: "play.rectangle")
            Text(video.viewText).lineLimit(1)
          }
          if !video.danmakuText.isEmpty {
            Image(systemName: "text.bubble")
            Text(video.danmakuText).lineLimit(1)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.caption2)
        .foregroundColor(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .clipped()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .buttonStyle(PlainButtonStyle())
    .accessibilityLabel("\(video.title)，\(video.owner)")
  }
}

private struct PiliNativeLiveRoomCard: View {
  let room: PiliNativeLiveRoom
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 7) {
        ZStack(alignment: .bottom) {
          PiliNativeHomeCover(urlString: room.cover)
          LinearGradient(
            colors: [.clear, Color.black.opacity(0.62)],
            startPoint: .top,
            endPoint: .bottom
          )
          .frame(height: 44)
          .frame(maxWidth: .infinity, alignment: .bottom)
          HStack(spacing: 6) {
            Text("直播")
              .fontWeight(.semibold)
              .foregroundColor(piliAccent)
              .padding(.horizontal, 5)
              .padding(.vertical, 2)
              .background(Color.white.opacity(0.94))
              .clipShape(Capsule())
            Text(room.area).lineLimit(1)
            Spacer(minLength: 2)
            if !room.viewText.isEmpty {
              Label(room.viewText, systemImage: "person.fill")
            }
          }
          .font(.system(size: 10, weight: .medium))
          .foregroundColor(.white)
          .padding(.horizontal, 7)
          .padding(.bottom, 6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

        Text(room.title)
          .font(.subheadline)
          .fontWeight(.medium)
          .foregroundColor(.primary)
          .lineLimit(2, reservesSpace: true)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)

        HStack(spacing: 7) {
          Text(room.owner).lineLimit(1)
          Spacer(minLength: 2)
          if !room.viewText.isEmpty {
            Label(room.viewText, systemImage: "person.circle")
          }
        }
        .font(.caption)
        .foregroundColor(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(PlainButtonStyle())
    .accessibilityLabel("直播，\(room.title)，\(room.owner)")
  }
}

private struct PiliNativeDynamicsView: View {
  @ObservedObject var model: PiliNativeViewModel

  var body: some View {
    NavigationView {
      Group {
        if !model.account.isLogin {
          PiliNativeLoggedOutView(
            title: "登录后查看关注动态",
            action: { model.openRoute("/loginPage") }
          )
        } else if model.dynamicsLoading && model.dynamics.isEmpty {
          PiliNativeLoadingView(title: "正在加载动态")
        } else if let error = model.dynamicsError, model.dynamics.isEmpty {
          PiliNativeErrorView(message: error) { model.refresh("dynamics") }
        } else {
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(model.dynamics) { item in
                PiliNativeDynamicRow(item: item) {
                  model.openDynamic(item)
                }
                .onAppear {
                  if item.id == model.dynamics.last?.id {
                    model.loadMore("dynamics")
                  }
                }
                Divider().padding(.leading, 64)
              }
              if model.dynamicsLoadingMore {
                ProgressView().padding(.vertical, 20)
              }
            }
          }
          .background(Color(UIColor.systemBackground))
          .refreshable { model.refresh("dynamics") }
        }
      }
      .navigationBarTitle("动态", displayMode: .inline)
      .navigationBarItems(
        leading: Button(action: { model.isSearchPresented = true }) {
          Image(systemName: "magnifyingglass")
        }
      )
    }
    .navigationViewStyle(StackNavigationViewStyle())
  }
}

private struct PiliNativeDynamicRow: View {
  let item: PiliNativeDynamic
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 12) {
        PiliRemoteImage(urlString: item.avatar)
          .frame(width: 42, height: 42)
          .clipShape(Circle())
          .overlay(Circle().stroke(Color(UIColor.separator).opacity(0.2)))

        VStack(alignment: .leading, spacing: 7) {
          HStack {
            Text(item.author.isEmpty ? "动态" : item.author)
              .font(.subheadline)
              .fontWeight(.semibold)
              .foregroundColor(.primary)
            Spacer()
            Text(item.time)
              .font(.caption)
              .foregroundColor(.secondary)
          }
          if !item.title.isEmpty {
            Text(item.title)
              .font(.subheadline)
              .fontWeight(.semibold)
              .foregroundColor(.primary)
              .lineLimit(2)
          }
          if !item.body.isEmpty {
            Text(item.body)
              .font(.subheadline)
              .foregroundColor(.primary)
              .lineLimit(4)
          }
          if !item.pictures.isEmpty {
            PiliNativeDynamicPicturesView(
              pictures: item.pictures,
              maxWidth: min(UIScreen.main.bounds.width - 96, 520),
              singleMaxHeight: 260
            )
          }
          HStack(spacing: 22) {
            PiliNativeStat(icon: "arrowshape.turn.up.right", count: item.forward)
            PiliNativeStat(icon: "bubble.left", count: item.comment)
            PiliNativeStat(icon: "hand.thumbsup", count: item.like)
          }
          .padding(.top, 2)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .contentShape(Rectangle())
    }
    .buttonStyle(PlainButtonStyle())
  }
}

private struct PiliNativeDynamicPictureView: View {
  let sourceWidth: CGFloat
  let sourceHeight: CGFloat
  let maxWidth: CGFloat
  let maxHeight: CGFloat
  let cornerRadius: CGFloat
  @StateObject private var loader: PiliImageLoader

  init(
    urlString: String,
    sourceWidth: CGFloat,
    sourceHeight: CGFloat,
    maxWidth: CGFloat,
    maxHeight: CGFloat,
    cornerRadius: CGFloat = 9
  ) {
    self.sourceWidth = sourceWidth
    self.sourceHeight = sourceHeight
    self.maxWidth = maxWidth
    self.maxHeight = maxHeight
    self.cornerRadius = cornerRadius
    _loader = StateObject(wrappedValue: PiliImageLoader(urlString: urlString))
  }

  private var displaySize: CGSize {
    let sourceSize: CGSize
    if sourceWidth > 0, sourceHeight > 0 {
      sourceSize = CGSize(width: sourceWidth, height: sourceHeight)
    } else if let image = loader.image, image.size.width > 0, image.size.height > 0 {
      sourceSize = image.size
    } else {
      return CGSize(width: min(160, maxWidth), height: min(120, maxHeight))
    }

    let scale = min(min(maxWidth / sourceSize.width, maxHeight / sourceSize.height), 1)
    return CGSize(
      width: max(sourceSize.width * scale, 1),
      height: max(sourceSize.height * scale, 1)
    )
  }

  var body: some View {
    Group {
      if let image = loader.image {
        Image(uiImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
      } else {
        ZStack {
          Color(UIColor.tertiarySystemFill)
          Image(systemName: "photo")
            .foregroundColor(Color(UIColor.tertiaryLabel))
        }
      }
    }
    .frame(width: displaySize.width, height: displaySize.height)
    .background(Color(UIColor.tertiarySystemFill))
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
  }
}

private struct PiliNativeDynamicPicturesView: View {
  let pictures: [PiliNativeCommentPicture]
  let maxWidth: CGFloat
  let singleMaxHeight: CGFloat

  private var columnCount: Int {
    pictures.count > 4 ? 3 : 2
  }

  var body: some View {
    if let picture = pictures.first, pictures.count == 1 {
      PiliNativeDynamicPictureView(
        urlString: picture.url,
        sourceWidth: picture.width,
        sourceHeight: picture.height,
        maxWidth: maxWidth,
        maxHeight: singleMaxHeight
      )
    } else {
      let spacing: CGFloat = 7
      let cellWidth = max(1, (maxWidth - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount))
      LazyVGrid(
        columns: Array(
          repeating: GridItem(.flexible(minimum: 1, maximum: cellWidth), spacing: spacing, alignment: .topLeading),
          count: columnCount
        ),
        alignment: .leading,
        spacing: spacing
      ) {
        ForEach(pictures, id: \.self) { picture in
          PiliNativeDynamicPictureView(
            urlString: picture.url,
            sourceWidth: picture.width,
            sourceHeight: picture.height,
            maxWidth: cellWidth,
            maxHeight: cellWidth * 1.35,
            cornerRadius: 8
          )
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .frame(maxWidth: maxWidth, alignment: .leading)
    }
  }
}

private struct PiliNativeStat: View {
  let icon: String
  let count: Int
  var color: Color = .secondary

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: icon)
      Text(count > 0 ? String(count) : "")
    }
    .font(.caption)
    .foregroundColor(color)
  }
}

private struct PiliNativeMineAction {
  let title: String
  let codePoint: Int
  let fallback: String
  let route: String
  let protected: Bool
}

private struct PiliNativeMineView: View {
  @ObservedObject var model: PiliNativeViewModel

  private let actions = [
    PiliNativeMineAction(title: "离线缓存", codePoint: 0xe806, fallback: "arrow.down.circle", route: "/download", protected: false),
    PiliNativeMineAction(title: "观看记录", codePoint: 0xe807, fallback: "clock.arrow.circlepath", route: "/history", protected: true),
    PiliNativeMineAction(title: "我的收藏", codePoint: 0xe81a, fallback: "star", route: "/fav", protected: true),
    PiliNativeMineAction(title: "稍后再看", codePoint: 0xe820, fallback: "clock", route: "/later", protected: true),
    PiliNativeMineAction(title: "我的订阅", codePoint: 0xe81c, fallback: "rectangle.stack", route: "/subscription", protected: true),
    PiliNativeMineAction(title: "消息中心", codePoint: 0xe802, fallback: "bell", route: "/whisper", protected: true),
  ]

  var body: some View {
    NavigationView {
      List {
        Section {
          Button(action: openAccount) {
            HStack(spacing: 14) {
              PiliRemoteImage(urlString: model.account.face)
                .frame(width: 64, height: 64)
                .clipShape(Circle())
              VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                  Text(model.account.name)
                    .font(.headline)
                    .foregroundColor(.primary)
                  if model.account.isLogin {
                    PiliOriginalLevelBadge(level: model.account.level, height: 13)
                  }
                }
                Text(
                  model.account.isLogin
                    ? String(format: "硬币 %.1f", model.account.money)
                    : "登录后同步收藏、历史与动态"
                )
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
              Spacer()
              Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(Color(UIColor.tertiaryLabel))
            }
            .padding(.vertical, 8)
          }
          .buttonStyle(PlainButtonStyle())

          HStack {
            PiliNativeAccountStat(value: model.account.dynamics, title: "动态") {
              openProtected("/memberDynamics")
            }
            Spacer()
            PiliNativeAccountStat(value: model.account.following, title: "关注") {
              openService("/follow", protected: true)
            }
            Spacer()
            PiliNativeAccountStat(value: model.account.followers, title: "粉丝") {
              openService("/fan", protected: true)
            }
          }
          .padding(.horizontal, 18)
          .padding(.vertical, 8)
        }

        Section(header: Text("我的服务")) {
          ForEach(actions.indices, id: \.self) { index in
            let item = actions[index]
            Button(action: { openService(item.route, protected: item.protected) }) {
              HStack(spacing: 14) {
                PiliOriginalIcon(
                  family: .custom,
                  codePoint: item.codePoint,
                  fallback: item.fallback,
                  size: 20
                )
                  .frame(width: 24)
                  .foregroundColor(piliAccent)
                Text(item.title).foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                  .font(.caption)
                  .foregroundColor(Color(UIColor.tertiaryLabel))
              }
            }
          }
        }

        Section {
          Button(action: { model.presentSettings() }) {
            Label("设置", systemImage: "gearshape")
              .foregroundColor(.primary)
          }
          Button(action: { model.openRoute("/loginPage") }) {
            Label(model.account.isLogin ? "切换账号" : "登录", systemImage: "person.crop.circle.badge.arrow.forward")
              .foregroundColor(.primary)
          }
        }
      }
      .listStyle(InsetGroupedListStyle())
      .refreshable { model.refresh("mine") }
      .navigationBarTitle("我的", displayMode: .inline)
      .navigationBarItems(
        leading: Button(action: { model.isSearchPresented = true }) {
          Image(systemName: "magnifyingglass")
        }
      )
    }
    .navigationViewStyle(StackNavigationViewStyle())
  }

  private func openAccount() {
    if model.account.isLogin, let mid = model.account.mid {
      model.presentProfile(mid)
    } else {
      model.openRoute("/loginPage")
    }
  }

  private func openProtected(_ route: String) {
    guard model.account.isLogin else {
      model.openRoute("/loginPage")
      return
    }
    var parameters: [String: String] = [:]
    if let mid = model.account.mid {
      parameters["mid"] = String(mid)
    }
    model.openRoute(route, parameters: parameters)
  }

  private func openService(_ route: String, protected: Bool) {
    if protected && !model.account.isLogin {
      model.openRoute("/loginPage")
      return
    }
    switch route {
    case "/history":
      model.presentLibrary("history", title: "观看记录")
    case "/later":
      model.presentLibrary("later", title: "稍后再看")
    case "/fav":
      model.presentLibrary("favorites", title: "我的收藏")
    case "/follow":
      model.presentLibrary("following", title: "关注")
    case "/fan":
      model.presentLibrary("followers", title: "粉丝")
    case "/subscription":
      model.presentLibrary("subscriptions", title: "我的订阅")
    default:
      if protected {
        openProtected(route)
      } else {
        model.openRoute(route)
      }
    }
  }
}

private struct PiliNativeAccountStat: View {
  let value: Int
  let title: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 4) {
        Text(String(value)).font(.headline).foregroundColor(.primary)
        Text(title).font(.caption).foregroundColor(.secondary)
      }
      .frame(minWidth: 60)
    }
    .buttonStyle(PlainButtonStyle())
  }
}

// MARK: - Native member profile

private struct PiliNativeProfileView: View {
  @ObservedObject var model: PiliNativeViewModel
  @Environment(\.presentationMode) private var presentationMode
  @State private var selectedSection = 0
  private let columns = [
    GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top),
    GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top),
  ]

  var body: some View {
    NavigationView {
      Group {
        if model.profileLoading && model.profile == nil {
          PiliNativeLoadingView(title: "正在加载个人空间")
        } else if let error = model.profileError, model.profile == nil {
          PiliNativeErrorView(message: error, retry: model.loadProfile)
        } else if let profile = model.profile {
          ScrollView {
            VStack(spacing: 0) {
              profileHero(profile)
              profileIdentityCard(profile)
              profileSectionPicker
              profileContent(profile)
            }
            .padding(.bottom, 32)
          }
          .background(Color(UIColor.systemGroupedBackground))
          .refreshable { model.loadProfile() }
        } else {
          PiliNativeErrorView(message: "暂无个人资料", retry: model.loadProfile)
        }
      }
      .navigationBarTitle("个人主页", displayMode: .inline)
      .navigationBarItems(
        leading: Button("关闭") {
          model.isProfilePresented = false
          presentationMode.wrappedValue.dismiss()
        }
      )
    }
    .navigationViewStyle(StackNavigationViewStyle())
  }

  private func profileHero(_ profile: PiliNativeProfile) -> some View {
    ZStack(alignment: .bottom) {
      PiliRemoteImage(urlString: profile.topImage)
        .aspectRatio(16 / 8.5, contentMode: .fill)
        .frame(maxWidth: .infinity)
        .frame(height: 210)
        .clipped()
        .overlay(
          LinearGradient(
            colors: [.black.opacity(0.03), .black.opacity(0.58)],
            startPoint: .top,
            endPoint: .bottom
          )
        )

      HStack {
        Label(profile.vip ? "大会员" : "PiliGlass 用户", systemImage: profile.vip ? "crown.fill" : "person.fill")
          .font(.system(size: 12, weight: .semibold))
          .foregroundColor(.white)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(Color.black.opacity(0.38))
          .clipShape(Capsule())
        Spacer()
        Text("UID " + String(profile.mid))
          .font(.caption)
          .foregroundColor(.white.opacity(0.9))
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 58)
    }
  }

  private func profileIdentityCard(_ profile: PiliNativeProfile) -> some View {
    ZStack(alignment: .top) {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .fill(Color(UIColor.systemBackground))
        .padding(.top, 48)
        .shadow(color: .black.opacity(0.07), radius: 18, y: 7)

      VStack(spacing: 13) {
        // Reserve the avatar's full height inside the card's layout bounds.
        // This keeps it visible when the container overlaps the cover image.
        Color.clear.frame(height: 96)

        HStack(spacing: 7) {
          Text(profile.name)
            .font(.title2)
            .fontWeight(.bold)
            .foregroundColor(profile.vip ? piliAccent : .primary)
          PiliOriginalLevelBadge(level: profile.level, height: 14)
        }

        if !profile.official.isEmpty {
          Label(profile.official, systemImage: "checkmark.seal.fill")
            .font(.caption)
            .foregroundColor(piliAccent)
        }

        HStack(spacing: 0) {
          profileStat(profile.following, "关注")
          Divider().frame(height: 34)
          profileStat(profile.followers, "粉丝")
          Divider().frame(height: 34)
          profileStat(profile.likes, "获赞")
        }
        .padding(.vertical, 4)

        if !profile.isSelf {
          Button(action: model.toggleProfileFollow) {
            Label(
              profile.isFollowing ? "已关注" : "关注",
              systemImage: profile.isFollowing ? "checkmark" : "plus"
            )
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(profile.isFollowing ? .primary : .white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(profile.isFollowing ? Color(UIColor.secondarySystemGroupedBackground) : piliAccent)
            .cornerRadius(12)
          }
          .buttonStyle(PlainButtonStyle())
          .disabled(model.profileActionLoading)
        }

        if let message = model.profileMessage {
          Text(message)
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 16)

      PiliRemoteImage(urlString: profile.face)
        .frame(width: 96, height: 96)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color(UIColor.systemBackground), lineWidth: 5))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .zIndex(1)
    }
    .padding(.horizontal, 14)
    .offset(y: -48)
    .padding(.bottom, -38)
  }

  private func profileStat(_ value: Int, _ title: String) -> some View {
    VStack(spacing: 4) {
      Text(piliCompactNumber(value))
        .font(.headline)
        .fontWeight(.bold)
      Text(title)
        .font(.caption)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity)
  }

  private var profileSectionPicker: some View {
    Picker("主页内容", selection: $selectedSection) {
      Text("主页").tag(0)
      Text("视频").tag(1)
      Text("资料").tag(2)
    }
    .pickerStyle(SegmentedPickerStyle())
    .padding(5)
    .background(Color(UIColor.systemBackground))
    .cornerRadius(12)
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  @ViewBuilder
  private func profileContent(_ profile: PiliNativeProfile) -> some View {
    if selectedSection == 0 {
      VStack(spacing: 12) {
        profileAboutCard(profile)
        profileVideoGrid(profile, limit: 4, title: "最新投稿")
      }
    } else if selectedSection == 1 {
      profileVideoGrid(profile, limit: nil, title: "全部投稿 · \(profile.videoCount)")
    } else {
      profileDetailsCard(profile)
    }
  }

  private func profileAboutCard(_ profile: PiliNativeProfile) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("个人简介", systemImage: "quote.bubble")
        .font(.headline)
      Text(profile.sign.isEmpty ? "这个人很神秘，什么都没有写。" : profile.sign)
        .font(.subheadline)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)

      if !profile.tags.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(profile.tags, id: \.self) { tag in
              Text(tag)
                .font(.caption)
                .foregroundColor(piliAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(piliAccent.opacity(0.09))
                .clipShape(Capsule())
            }
          }
        }
      }
    }
    .padding(16)
    .background(Color(UIColor.systemBackground))
    .cornerRadius(16)
    .padding(.horizontal, 14)
  }

  private func profileVideoGrid(_ profile: PiliNativeProfile, limit: Int?, title: String) -> some View {
    VStack(alignment: .leading, spacing: 13) {
      HStack {
        Label(title, systemImage: "play.rectangle")
          .font(.headline)
        Spacer()
        if selectedSection == 0 && profile.videos.count > 4 {
          Button("查看全部") { selectedSection = 1 }
            .font(.caption)
            .foregroundColor(piliAccent)
        }
      }
      if profile.videos.isEmpty && model.profileVideosLoading {
        ProgressView("正在加载用户投稿")
          .font(.caption)
          .frame(maxWidth: .infinity, minHeight: 150)
      } else if profile.videos.isEmpty {
        PiliNativeEmptyView(
          icon: "video.slash",
          title: "暂无公开视频",
          subtitle: model.profileVideosError ?? "该用户还没有发布视频"
        )
        .frame(height: 150)
      } else {
        LazyVGrid(columns: columns, spacing: 14) {
          ForEach(Array(profile.videos.prefix(limit ?? profile.videos.count))) { video in
            PiliNativeProfileVideoCard(video: video) {
              model.openProfileVideo(video)
            }
            .onAppear {
              if limit == nil, video.id == profile.videos.last?.id {
                model.loadMoreProfileVideos()
              }
            }
          }
        }

        if limit == nil {
          if let error = model.profileVideosError {
            VStack(spacing: 8) {
              Text(error)
                .font(.caption)
                .foregroundColor(.secondary)
              Button("重试加载", action: model.reloadProfileVideos)
                .font(.caption)
                .foregroundColor(piliAccent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
          } else if model.profileVideosLoading || model.profileVideosLoadingMore {
            ProgressView("正在加载更多视频")
              .font(.caption)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 10)
          } else if model.profileVideosHasMore {
            Button("加载更多视频", action: model.loadMoreProfileVideos)
              .font(.caption)
              .foregroundColor(piliAccent)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 10)
          }
        }
      }
    }
    .padding(16)
    .background(Color(UIColor.systemBackground))
    .cornerRadius(16)
    .padding(.horizontal, 14)
  }

  private func profileDetailsCard(_ profile: PiliNativeProfile) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      profileDetailRow("UID", String(profile.mid), "number")
      Divider().padding(.leading, 38)
      profileLevelDetailRow(profile.level)
      Divider().padding(.leading, 38)
      profileDetailRow("会员", profile.vip ? "大会员" : "普通用户", "crown")
      if !profile.official.isEmpty {
        Divider().padding(.leading, 38)
        profileDetailRow("认证", profile.official, "checkmark.seal")
      }
      Divider().padding(.leading, 38)
      profileDetailRow("投稿", "\(profile.videoCount) 个视频", "play.rectangle")
    }
    .padding(16)
    .background(Color(UIColor.systemBackground))
    .cornerRadius(16)
    .padding(.horizontal, 14)
  }

  private func profileDetailRow(_ title: String, _ value: String, _ icon: String) -> some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .foregroundColor(piliAccent)
        .frame(width: 26)
      Text(title)
        .foregroundColor(.secondary)
      Spacer()
      Text(value)
        .multilineTextAlignment(.trailing)
    }
    .font(.subheadline)
    .padding(.vertical, 11)
  }

  private func profileLevelDetailRow(_ level: Int) -> some View {
    HStack(spacing: 12) {
      Image(systemName: "chart.bar.fill")
        .foregroundColor(piliAccent)
        .frame(width: 26)
      Text("等级")
        .foregroundColor(.secondary)
      Spacer()
      PiliOriginalLevelBadge(level: level, height: 13)
    }
    .font(.subheadline)
    .padding(.vertical, 11)
  }
}

private struct PiliNativeProfileVideoCard: View {
  let video: PiliNativeVideo
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 8) {
        ZStack(alignment: .bottomTrailing) {
          PiliRemoteImage(urlString: video.cover)
            .aspectRatio(16 / 9, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .clipped()
          if !video.durationText.isEmpty {
            Text(video.durationText)
              .font(.caption2)
              .foregroundColor(.white)
              .padding(.horizontal, 6)
              .padding(.vertical, 3)
              .background(Color.black.opacity(0.68))
              .cornerRadius(5)
              .padding(6)
          }
        }
        .cornerRadius(11)

        Text(video.title)
          .font(.subheadline)
          .fontWeight(.medium)
          .foregroundColor(.primary)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
          .frame(height: 40, alignment: .topLeading)
          .frame(maxWidth: .infinity, alignment: .leading)

        HStack(spacing: 5) {
          if !video.viewText.isEmpty {
            Label(video.viewText, systemImage: "play.fill")
          }
          if !video.danmakuText.isEmpty {
            Label(video.danmakuText, systemImage: "text.bubble")
          }
        }
        .font(.caption2)
        .foregroundColor(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .clipped()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .buttonStyle(PlainButtonStyle())
  }
}

// MARK: - Native video introduction

private enum PiliNativeVideoDetailTab: String, CaseIterable, Identifiable {
  case introduction = "简介"
  case comments = "评论"

  var id: String { rawValue }
}

private struct PiliNativeVideoDetailView: View {
  @ObservedObject var model: PiliNativeViewModel
  @Environment(\.presentationMode) private var presentationMode
  @State private var selectedPart = 1
  @State private var descriptionExpanded = false
  @State private var selectedTab = PiliNativeVideoDetailTab.introduction
  @State private var isCollectionPresented = false

  var body: some View {
    NavigationView {
      ZStack {
        Color.black.ignoresSafeArea()
        VStack(spacing: 0) {
          playerHeader(model.videoDetail)
          Group {
            if model.videoDetailLoading && model.videoDetail == nil {
              PiliNativeLoadingView(title: "正在加载视频详情")
            } else if let error = model.videoDetailError, model.videoDetail == nil {
              PiliNativeErrorView(message: error, retry: model.retryVideoDetail)
            } else if let video = model.videoDetail {
              VStack(spacing: 0) {
                nativeVideoTabBar
                if selectedTab == .introduction {
                  nativeIntroductionPage(video)
                } else {
                  nativeCommentsPage
                }
              }
              .onChange(of: video.bvid) { _ in
                selectedPart = 1
                selectedTab = .introduction
                descriptionExpanded = false
              }
            } else {
              PiliNativeErrorView(message: "没有可显示的视频信息", retry: model.retryVideoDetail)
            }
          }
          .background(Color(UIColor.systemBackground))
        }
      }
      .navigationBarHidden(true)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if selectedTab == .comments && model.videoDetail != nil {
          nativeCommentComposerBar
        }
      }
    }
    .navigationViewStyle(StackNavigationViewStyle())
    .onAppear {
      model.handleVideoDeviceOrientation(UIDevice.current.orientation)
    }
    .onChange(of: model.originalPlayerReady) { ready in
      if ready {
        model.handleVideoDeviceOrientation(UIDevice.current.orientation)
      }
    }
    .sheet(isPresented: $model.isDynamicComposerPresented) {
      PiliNativeDynamicComposerView(model: model)
        .piliEdgeSwipeBack { model.isDynamicComposerPresented = false }
    }
    .sheet(isPresented: $isCollectionPresented) {
      if let video = model.videoDetail {
        PiliNativeVideoCollectionView(video: video, model: model)
          .piliEdgeSwipeBack { isCollectionPresented = false }
      }
    }
    .fullScreenCover(isPresented: $model.isCommentThreadPresented) {
      PiliNativeCommentThreadView(model: model)
        .piliEdgeSwipeBack { model.isCommentThreadPresented = false }
    }
    .overlay {
      if model.originalPlayerFullscreen {
        PiliNativeOriginalPlayerFullscreenView(model: model)
          .transition(.opacity)
          .zIndex(100)
      }
    }
    .animation(.easeOut(duration: 0.2), value: model.originalPlayerFullscreen)
  }

  private func close() {
    model.closeVideoDetail()
    presentationMode.wrappedValue.dismiss()
  }

  private func playerHeader(_ video: PiliNativeVideoDetail?) -> some View {
    let currentPart = video?.pages.first(where: { $0.index == selectedPart })
    let cover = currentPart?.cover ?? video?.cover ?? model.pendingVideo?.cover
    return ZStack {
      Color.black
      PiliRemoteImage(urlString: cover)
        .aspectRatio(16 / 9, contentMode: .fill)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(Color.black.opacity(0.32))

      if model.originalPlayerReady && !model.originalPlayerFullscreen {
        PiliNativePlayerView(session: model.nativePlayerSession)
      }

      if !model.originalPlayerReady && model.originalPlayerError == nil {
        VStack(spacing: 10) {
          ProgressView().tint(.white)
          Text("正在加载视频首帧")
            .font(.caption)
            .foregroundColor(.white)
        }
      }

      if let error = model.originalPlayerError {
        HStack(spacing: 10) {
          Text(error)
            .font(.caption)
            .foregroundColor(.white)
          Spacer(minLength: 0)
          Button("重试", action: model.retryNativePlayback)
            .font(.caption)
            .foregroundColor(piliAccent)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.72))
        .frame(maxHeight: .infinity, alignment: .bottom)
      }

      if !model.originalPlayerReady {
        VStack {
          HStack {
            Button(action: close) {
              Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(Color.black.opacity(0.55))
                .clipShape(Circle())
            }
            .buttonStyle(PlainButtonStyle())
            Spacer()
          }
          Spacer()
        }
        .padding(12)
      }
    }
    .aspectRatio(16 / 9, contentMode: .fit)
  }

  private var nativeVideoTabBar: some View {
    HStack(spacing: 0) {
      ForEach(PiliNativeVideoDetailTab.allCases) { tab in
        Button(action: {
          withAnimation(.easeInOut(duration: 0.18)) { selectedTab = tab }
        }) {
          VStack(spacing: 10) {
            HStack(spacing: 4) {
              Text(tab.rawValue)
              if tab == .comments && model.commentsTotal > 0 {
                Text(piliCompactNumber(model.commentsTotal))
                  .font(.caption2)
              }
            }
            .font(.system(size: 16, weight: selectedTab == tab ? .semibold : .regular))
            .foregroundColor(selectedTab == tab ? piliAccent : .primary)
            Capsule()
              .fill(selectedTab == tab ? piliAccent : Color.clear)
              .frame(width: 38, height: 3)
          }
          .frame(width: 76, height: 54)
        }
        .buttonStyle(PlainButtonStyle())
      }
      Spacer(minLength: 4)
      PiliNativePortraitDanmakuBar(session: model.nativePlayerSession)
    }
    .padding(.horizontal, 10)
    .frame(height: 58)
    .background(Color(UIColor.systemBackground))
    .overlay(Divider(), alignment: .bottom)
  }

  private func nativeIntroductionPage(_ video: PiliNativeVideoDetail) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        nativeOwnerRow(video)
        nativeSectionDivider
        nativeTitleAndStats(video)
        nativeActionRow(video)
        if let message = model.videoActionMessage {
          Text(message)
            .font(.caption)
            .foregroundColor(message.contains("失败") || message.contains("登录") ? .red : piliAccent)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, 10)
        }
        if !video.argueMessage.isEmpty {
          warningCard(video)
          nativeSectionDivider
        }
        if video.pages.count > 1 {
          nativePartsSection(video)
          nativeSectionDivider
        }
        if !video.collectionTitle.isEmpty {
          nativeCollectionRow(video)
          nativeSectionDivider
        }
        if !video.staff.isEmpty {
          nativeStaffSection(video)
          nativeSectionDivider
        }
        if !video.tags.isEmpty {
          nativeTagsSection(video)
          nativeSectionDivider
        }
        nativeRelatedSection
      }
      .padding(.bottom, 34)
    }
    .background(Color(UIColor.systemBackground))
  }

  private func nativeOwnerRow(_ video: PiliNativeVideoDetail) -> some View {
    Button(action: { model.openVideoOwner(video) }) {
      HStack(spacing: 12) {
        PiliRemoteImage(urlString: video.ownerFace)
          .frame(width: 44, height: 44)
          .clipShape(Circle())
        VStack(alignment: .leading, spacing: 3) {
          Text(video.owner.isEmpty ? "UP 主" : video.owner)
            .font(.headline)
            .foregroundColor(.primary)
          Text([video.copyrightText, video.bvid].filter { !$0.isEmpty }.joined(separator: " · "))
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
        Spacer()
        if video.ownerID != nil {
          Text("主页")
            .font(.subheadline.weight(.semibold))
            .foregroundColor(piliAccent)
            .padding(.horizontal, 17)
            .padding(.vertical, 8)
            .overlay(Capsule().stroke(piliAccent, lineWidth: 1))
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 14)
    }
    .buttonStyle(PlainButtonStyle())
    .disabled(video.ownerID == nil)
  }

  private func nativeTitleAndStats(_ video: PiliNativeVideoDetail) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Button(action: toggleDescription) {
        HStack(alignment: .top, spacing: 9) {
          Text(video.title)
            .font(.title3.weight(.semibold))
            .foregroundColor(.primary)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Image(systemName: descriptionExpanded ? "chevron.up" : "chevron.down")
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
            .padding(.top, 5)
        }
      }
      .buttonStyle(PlainButtonStyle())

      HStack(spacing: 12) {
        if !video.viewText.isEmpty { Label(video.viewText, systemImage: "play.rectangle") }
        if !video.danmakuText.isEmpty { Label(video.danmakuText, systemImage: "text.bubble") }
        if !video.pubdateText.isEmpty { Text(video.pubdateText) }
      }
      .font(.caption)
      .foregroundColor(.secondary)

      if !video.description.isEmpty {
        Text(video.description)
          .font(.subheadline)
          .foregroundColor(.secondary)
          .lineLimit(descriptionExpanded ? nil : 2)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 15)
  }

  private func nativeActionRow(_ video: PiliNativeVideoDetail) -> some View {
    VStack(spacing: 8) {
      HStack(spacing: 0) {
        Button(action: { model.performVideoAction("like", video: video) }) {
          PiliNativeVideoMetric(
            icon: video.liked ? "hand.thumbsup.fill" : "hand.thumbsup",
            value: video.like,
            title: "点赞",
            color: video.liked ? piliAccent : .secondary
          )
        }
        Button(action: { model.performVideoAction("coin", video: video) }) {
          PiliNativeVideoMetric(
            icon: video.coinCount > 0 ? "circle.hexagongrid.fill" : "circle.hexagongrid",
            value: video.coin,
            title: "投币",
            color: video.coinCount > 0 ? piliAccent : .secondary
          )
        }
        Button(action: { model.performVideoAction("favorite", video: video) }) {
          PiliNativeVideoMetric(
            icon: video.favorited ? "star.fill" : "star",
            value: video.favorite,
            title: "收藏",
            color: video.favorited ? piliAccent : .secondary
          )
        }
        Button(action: { selectedTab = .comments }) {
          PiliNativeVideoMetric(icon: "bubble.left", value: video.reply, title: "评论")
        }
        Button(action: { model.performVideoAction("share", video: video) }) {
          PiliNativeVideoMetric(icon: "square.and.arrow.up", value: video.share, title: "分享")
        }
      }
      .buttonStyle(PlainButtonStyle())
      .disabled(model.videoActionLoading)
      if model.videoActionLoading {
        ProgressView().frame(maxWidth: .infinity)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 17)
  }

  private func nativePartsSection(_ video: PiliNativeVideoDetail) -> some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack {
        Text("选集")
          .font(.headline)
        Spacer()
        Text("共 (video.pages.count) 个视频")
          .font(.caption)
          .foregroundColor(.secondary)
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 9) {
          ForEach(video.pages) { part in
            Button(action: {
              selectedPart = part.index
              model.selectOriginalPlayerPart(part)
            }) {
              VStack(alignment: .leading, spacing: 5) {
                Text("P\(part.index) · \(part.title)")
                  .font(.subheadline)
                  .fontWeight(selectedPart == part.index ? .semibold : .regular)
                  .lineLimit(2)
                Text(part.durationText)
                  .font(.caption2)
                  .opacity(part.durationText.isEmpty ? 0 : 1)
              }
              .foregroundColor(selectedPart == part.index ? piliAccent : .primary)
              .padding(11)
              .frame(width: 178, height: 72, alignment: .leading)
              .background(
                selectedPart == part.index
                  ? piliAccent.opacity(0.1)
                  : Color(UIColor.secondarySystemBackground)
              )
              .overlay(
                RoundedRectangle(cornerRadius: 11)
                  .stroke(selectedPart == part.index ? piliAccent : Color.clear, lineWidth: 1)
              )
              .cornerRadius(11)
            }
            .buttonStyle(PlainButtonStyle())
          }
        }
      }
    }
    .padding(16)
  }

  private func nativeCollectionRow(_ video: PiliNativeVideoDetail) -> some View {
    Button(action: { isCollectionPresented = true }) {
      HStack(spacing: 13) {
        Image(systemName: "rectangle.stack.fill")
          .font(.title2)
          .foregroundColor(piliAccent)
          .frame(width: 48, height: 48)
          .background(piliAccent.opacity(0.1))
          .cornerRadius(12)
        VStack(alignment: .leading, spacing: 4) {
          Text(video.collectionTitle)
            .font(.headline)
            .foregroundColor(.primary)
          Text("合集共 \(video.collectionCount) 个视频")
            .font(.caption)
            .foregroundColor(.secondary)
        }
        Spacer()
        Image(systemName: "chevron.right")
          .font(.caption)
          .foregroundColor(.secondary)
      }
      .contentShape(Rectangle())
      .padding(16)
    }
    .buttonStyle(PlainButtonStyle())
    .disabled(video.collectionItems.isEmpty)
  }

  private func nativeStaffSection(_ video: PiliNativeVideoDetail) -> some View {
    VStack(alignment: .leading, spacing: 11) {
      Text("联合创作").font(.headline)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
          ForEach(video.staff) { member in
            Button(action: {
              if let memberID = member.memberID { model.openVideoMember(memberID) }
            }) {
              HStack(spacing: 9) {
                PiliRemoteImage(urlString: member.face)
                  .frame(width: 40, height: 40)
                  .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                  Text(member.name).font(.subheadline).foregroundColor(.primary)
                  Text(member.title).font(.caption2).foregroundColor(.secondary)
                }
              }
              .padding(10)
              .background(Color(UIColor.secondarySystemBackground))
              .cornerRadius(12)
            }
            .buttonStyle(PlainButtonStyle())
          }
        }
      }
    }
    .padding(16)
  }

  private func nativeTagsSection(_ video: PiliNativeVideoDetail) -> some View {
    VStack(alignment: .leading, spacing: 11) {
      Text("标签").font(.headline)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(video.tags) { tag in
            Text("# \(tag.name)")
              .font(.subheadline)
              .foregroundColor(piliAccent)
              .padding(.horizontal, 12)
              .padding(.vertical, 7)
              .background(piliAccent.opacity(0.09))
              .clipShape(Capsule())
          }
        }
      }
    }
    .padding(16)
  }

  private var nativeRelatedSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("相关推荐")
        .font(.headline)
      if model.relatedVideosLoading && model.relatedVideos.isEmpty {
        ProgressView("正在加载相关推荐")
          .font(.caption)
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity, minHeight: 90)
      } else if model.relatedVideos.isEmpty {
        if let error = model.relatedVideosError {
          Text(error)
            .font(.subheadline)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, minHeight: 70)
        }
      } else {
        ForEach(Array(model.relatedVideos.prefix(16))) { video in
          nativeRelatedVideoRow(video)
          if video.id != model.relatedVideos.prefix(16).last?.id {
            Divider().padding(.leading, 144)
          }
        }
      }
    }
    .padding(16)
  }

  private func nativeRelatedVideoRow(_ video: PiliNativeVideo) -> some View {
    Button(action: {
      selectedPart = 1
      selectedTab = .introduction
      descriptionExpanded = false
      model.openVideo(video)
    }) {
      HStack(alignment: .top, spacing: 12) {
        ZStack(alignment: .bottomTrailing) {
          PiliRemoteImage(urlString: video.cover)
            .aspectRatio(16 / 9, contentMode: .fill)
            .frame(width: 132, height: 74)
            .clipped()
          if !video.durationText.isEmpty {
            Text(video.durationText)
              .font(.caption2)
              .foregroundColor(.white)
              .padding(.horizontal, 5)
              .padding(.vertical, 2)
              .background(Color.black.opacity(0.7))
              .cornerRadius(4)
              .padding(5)
          }
        }
        .cornerRadius(8)

        VStack(alignment: .leading, spacing: 5) {
          Text(video.title)
            .font(.subheadline.weight(.medium))
            .foregroundColor(.primary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
          Spacer(minLength: 0)
          Text(video.owner)
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
          HStack(spacing: 9) {
            if !video.viewText.isEmpty { Label(video.viewText, systemImage: "play.rectangle") }
            if !video.danmakuText.isEmpty { Label(video.danmakuText, systemImage: "text.bubble") }
          }
          .font(.caption2)
          .foregroundColor(.secondary)
        }
        .frame(height: 74, alignment: .top)
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(PlainButtonStyle())
  }

  private var nativeCommentsPage: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 14) {
        HStack {
          Text("热门评论")
            .font(.headline)
          if model.commentsTotal > 0 {
            Text(piliCompactNumber(model.commentsTotal))
              .font(.caption)
              .foregroundColor(.secondary)
          }
          Spacer()
          Label("按热度", systemImage: "line.3.horizontal.decrease")
            .font(.caption)
            .foregroundColor(.secondary)
        }
        PiliNativeCommentsSection(model: model, showsHeader: false)
      }
      .padding(.horizontal, 16)
      .padding(.top, 14)
      .padding(.bottom, 30)
    }
    .background(Color(UIColor.systemBackground))
  }

  private var nativeCommentComposerBar: some View {
    HStack(spacing: 12) {
      Button(action: model.beginDynamicComment) {
        Text("与其赞同别人的话语，不如自己畅所欲言。")
          .font(.subheadline)
          .foregroundColor(.secondary)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16)
          .frame(height: 42)
          .background(Color(UIColor.secondarySystemBackground))
          .clipShape(Capsule())
      }
      .buttonStyle(PlainButtonStyle())
      Button(action: model.beginDynamicComment) {
        Image(systemName: "face.smiling")
          .font(.title2)
          .foregroundColor(.secondary)
      }
      .buttonStyle(PlainButtonStyle())
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(Color(UIColor.systemBackground))
    .overlay(Divider(), alignment: .top)
  }

  private var nativeSectionDivider: some View {
    Rectangle()
      .fill(Color(UIColor.secondarySystemBackground))
      .frame(height: 8)
      .overlay(Divider(), alignment: .top)
  }

  private func summaryCard(_ video: PiliNativeVideoDetail) -> some View {
    VStack(alignment: .leading, spacing: 15) {
      Text(video.title)
        .font(.title3)
        .fontWeight(.bold)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 12) {
        if !video.viewText.isEmpty {
          Label(video.viewText, systemImage: "play.rectangle")
        }
        if !video.danmakuText.isEmpty {
          Label(video.danmakuText, systemImage: "text.bubble")
        }
        if !video.pubdateText.isEmpty { Text(video.pubdateText) }
      }
      .font(.caption)
      .foregroundColor(.secondary)

      Button(action: { model.openVideoOwner(video) }) {
        HStack(spacing: 12) {
          PiliRemoteImage(urlString: video.ownerFace)
            .frame(width: 48, height: 48)
            .clipShape(Circle())
            .overlay(Circle().stroke(piliAccent.opacity(0.25), lineWidth: 2))
          VStack(alignment: .leading, spacing: 3) {
            Text(video.owner.isEmpty ? "UP 主" : video.owner)
              .font(.headline)
              .foregroundColor(.primary)
            Text([video.copyrightText, video.bvid].filter { !$0.isEmpty }.joined(separator: " · "))
              .font(.caption)
              .foregroundColor(.secondary)
          }
          Spacer()
          Image(systemName: "chevron.right")
            .font(.caption)
            .foregroundColor(Color(UIColor.tertiaryLabel))
        }
      }
      .buttonStyle(PlainButtonStyle())
      .disabled(video.ownerID == nil)

      HStack(spacing: 0) {
        Button(action: { model.performVideoAction("like", video: video) }) {
          PiliNativeVideoMetric(
            icon: video.liked ? "hand.thumbsup.fill" : "hand.thumbsup",
            value: video.like,
            title: "点赞",
            color: video.liked ? piliAccent : .secondary
          )
        }
        Button(action: { model.performVideoAction("coin", video: video) }) {
          PiliNativeVideoMetric(
            icon: video.coinCount > 0 ? "circle.hexagongrid.fill" : "circle.hexagongrid",
            value: video.coin,
            title: "投币",
            color: video.coinCount > 0 ? piliAccent : .secondary
          )
        }
        Button(action: { model.performVideoAction("favorite", video: video) }) {
          PiliNativeVideoMetric(
            icon: video.favorited ? "star.fill" : "star",
            value: video.favorite,
            title: "收藏",
            color: video.favorited ? piliAccent : .secondary
          )
        }
        Button(action: model.beginDynamicComment) {
          PiliNativeVideoMetric(icon: "bubble.left", value: video.reply, title: "评论")
        }
        Button(action: { model.performVideoAction("share", video: video) }) {
          PiliNativeVideoMetric(icon: "square.and.arrow.up", value: video.share, title: "分享")
        }
      }
      .buttonStyle(PlainButtonStyle())
      .disabled(model.videoActionLoading)

      if model.videoActionLoading {
        ProgressView().frame(maxWidth: .infinity)
      } else if let message = model.videoActionMessage {
        Text(message)
          .font(.caption)
          .foregroundColor(message.contains("失败") || message.contains("登录") ? .red : piliAccent)
          .frame(maxWidth: .infinity, alignment: .center)
      }
    }
    .padding(16)
    .background(Color(UIColor.systemBackground))
    .cornerRadius(16)
    .padding(.horizontal, 12)
  }

  private func warningCard(_ video: PiliNativeVideoDetail) -> some View {
    Label(video.argueMessage, systemImage: "exclamationmark.triangle.fill")
      .font(.subheadline)
      .foregroundColor(.orange)
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.orange.opacity(0.11))
      .cornerRadius(14)
      .padding(.horizontal, 12)
  }

  private func descriptionCard(_ video: PiliNativeVideoDetail) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("简介", systemImage: "text.alignleft")
        .font(.headline)

      Group {
        if descriptionExpanded {
          Text(video.description)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Text(video.description)
            .lineLimit(5)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .font(.subheadline)
      .foregroundColor(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .id(descriptionExpanded)

      Button(action: toggleDescription) {
        HStack(spacing: 5) {
          Text(descriptionExpanded ? "收起简介" : "展开完整简介")
          Image(systemName: descriptionExpanded ? "chevron.up" : "chevron.down")
          Spacer(minLength: 0)
        }
        .font(.subheadline)
        .foregroundColor(piliAccent)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(PlainButtonStyle())
    }
    .padding(16)
    .background(Color(UIColor.systemBackground))
    .cornerRadius(16)
    .padding(.horizontal, 12)
  }

  private func toggleDescription() {
    withAnimation(.easeInOut(duration: 0.2)) {
      descriptionExpanded.toggle()
    }
  }

  private func partsCard(_ video: PiliNativeVideoDetail) -> some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack {
        Label("选集", systemImage: "list.number")
          .font(.headline)
        Spacer()
        Text("\(video.pages.count) 个视频")
          .font(.caption)
          .foregroundColor(.secondary)
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 9) {
          ForEach(video.pages) { part in
            Button(action: {
              selectedPart = part.index
              model.selectOriginalPlayerPart(part)
            }) {
              VStack(alignment: .leading, spacing: 5) {
                Text("P\(part.index) · \(part.title)")
                  .font(.subheadline)
                  .fontWeight(selectedPart == part.index ? .semibold : .regular)
                  .lineLimit(2)
                Text(part.durationText)
                  .font(.caption2)
                  .opacity(part.durationText.isEmpty ? 0 : 1)
              }
              .foregroundColor(selectedPart == part.index ? .white : .primary)
              .padding(11)
              .frame(width: 178, height: 72, alignment: .leading)
              .background(selectedPart == part.index ? piliAccent : Color(UIColor.secondarySystemGroupedBackground))
              .cornerRadius(11)
            }
            .buttonStyle(PlainButtonStyle())
          }
        }
      }
    }
    .padding(16)
    .background(Color(UIColor.systemBackground))
    .cornerRadius(16)
    .padding(.horizontal, 12)
  }

  private func collectionCard(_ video: PiliNativeVideoDetail) -> some View {
    HStack(spacing: 13) {
      Image(systemName: "rectangle.stack.fill")
        .font(.title2)
        .foregroundColor(piliAccent)
        .frame(width: 48, height: 48)
        .background(piliAccent.opacity(0.1))
        .cornerRadius(12)
      VStack(alignment: .leading, spacing: 4) {
        Text(video.collectionTitle).font(.headline)
        Text("合集共 \(video.collectionCount) 个视频")
          .font(.caption)
          .foregroundColor(.secondary)
      }
      Spacer()
    }
    .padding(16)
    .background(Color(UIColor.systemBackground))
    .cornerRadius(16)
    .padding(.horizontal, 12)
  }

  private func staffCard(_ video: PiliNativeVideoDetail) -> some View {
    VStack(alignment: .leading, spacing: 11) {
      Text("联合创作").font(.headline)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
          ForEach(video.staff) { member in
            Button(action: {
              if let memberID = member.memberID { model.openVideoMember(memberID) }
            }) {
              HStack(spacing: 9) {
                PiliRemoteImage(urlString: member.face)
                  .frame(width: 40, height: 40)
                  .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                  Text(member.name).font(.subheadline).foregroundColor(.primary)
                  Text(member.title).font(.caption2).foregroundColor(.secondary)
                }
              }
              .padding(10)
              .background(Color(UIColor.secondarySystemGroupedBackground))
              .cornerRadius(12)
            }
            .buttonStyle(PlainButtonStyle())
          }
        }
      }
    }
    .padding(16)
    .background(Color(UIColor.systemBackground))
    .cornerRadius(16)
    .padding(.horizontal, 12)
  }

  private func tagsCard(_ video: PiliNativeVideoDetail) -> some View {
    VStack(alignment: .leading, spacing: 11) {
      Text("标签").font(.headline)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(video.tags) { tag in
            Text("# \(tag.name)")
              .font(.subheadline)
              .foregroundColor(piliAccent)
              .padding(.horizontal, 12)
              .padding(.vertical, 7)
              .background(piliAccent.opacity(0.09))
              .clipShape(Capsule())
          }
        }
      }
    }
    .padding(16)
    .background(Color(UIColor.systemBackground))
    .cornerRadius(16)
    .padding(.horizontal, 12)
  }

  private var commentsCard: some View {
    PiliNativeCommentsSection(model: model)
      .padding(16)
      .background(Color(UIColor.systemBackground))
      .cornerRadius(16)
      .padding(.horizontal, 12)
  }
}

private struct PiliNativeVideoCollectionView: View {
  let video: PiliNativeVideoDetail
  @ObservedObject var model: PiliNativeViewModel
  @Environment(\.presentationMode) private var presentationMode

  var body: some View {
    NavigationView {
      List {
        Section(
          header: Text("共 \(video.collectionItems.count) 个视频"),
          footer: Text("选择后会继续使用当前原生播放器播放该合集视频。")
        ) {
          ForEach(video.collectionItems) { item in
            Button(action: { select(item) }) {
              HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                  PiliRemoteImage(urlString: item.cover)
                    .aspectRatio(16 / 9, contentMode: .fill)
                    .frame(width: 120, height: 68)
                    .clipped()
                  if !item.durationText.isEmpty {
                    Text(item.durationText)
                      .font(.caption2)
                      .foregroundColor(.white)
                      .padding(.horizontal, 5)
                      .padding(.vertical, 2)
                      .background(Color.black.opacity(0.72))
                      .cornerRadius(4)
                      .padding(4)
                  }
                }
                .cornerRadius(8)
                VStack(alignment: .leading, spacing: 6) {
                  Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                  HStack(spacing: 8) {
                    if item.bvid == video.bvid {
                      Label("正在播放", systemImage: "waveform")
                        .foregroundColor(piliAccent)
                    } else if !item.viewText.isEmpty {
                      Label(item.viewText, systemImage: "play.rectangle")
                        .foregroundColor(.secondary)
                    }
                  }
                  .font(.caption)
                }
                Spacer(minLength: 0)
              }
              .contentShape(Rectangle())
              .padding(.vertical, 4)
            }
            .buttonStyle(PlainButtonStyle())
          }
        }
      }
      .listStyle(InsetGroupedListStyle())
      .navigationBarTitle(video.collectionTitle, displayMode: .inline)
      .navigationBarItems(
        leading: Button("关闭") { presentationMode.wrappedValue.dismiss() }
      )
    }
    .navigationViewStyle(StackNavigationViewStyle())
  }

  private func select(_ item: PiliNativeVideo) {
    guard item.bvid != video.bvid else {
      presentationMode.wrappedValue.dismiss()
      return
    }
    presentationMode.wrappedValue.dismiss()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      model.openVideo(item)
    }
  }
}

private struct PiliNativePortraitDanmakuBar: View {
  @ObservedObject var session: PiliNativePlayerSession

  var body: some View {
    HStack(spacing: 0) {
      Button(action: session.requestDanmakuComposer) {
        Text("点我发弹幕")
          .font(.caption)
          .foregroundColor(.secondary)
          .lineLimit(1)
          .padding(.leading, 13)
          .padding(.trailing, 9)
          .frame(height: 36)
      }
      .buttonStyle(PlainButtonStyle())
      Divider().frame(height: 20)
      Button(action: { session.danmakuEnabled.toggle() }) {
        ZStack(alignment: .bottomTrailing) {
          Text("弹")
            .font(.system(size: 15, weight: .bold))
            .foregroundColor(session.danmakuEnabled ? .primary : .secondary)
            .frame(width: 36, height: 36)
          Image(systemName: session.danmakuEnabled ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(session.danmakuEnabled ? piliAccent : .secondary)
            .background(Color(UIColor.systemBackground).clipShape(Circle()))
            .offset(x: -1, y: -3)
        }
      }
      .buttonStyle(PlainButtonStyle())
    }
    .background(Color(UIColor.secondarySystemBackground))
    .clipShape(Capsule())
  }
}

private struct PiliNativeOriginalPlayerFullscreenView: View {
  @ObservedObject var model: PiliNativeViewModel
  @ObservedObject private var session: PiliNativePlayerSession

  init(model: PiliNativeViewModel) {
    self.model = model
    _session = ObservedObject(wrappedValue: model.nativePlayerSession)
  }

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .trailing) {
        Color.black
        PiliRemoteImage(urlString: model.videoDetail?.cover ?? model.pendingVideo?.cover)
          .aspectRatio(contentMode: .fit)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        PiliNativePlayerView(session: session, fullscreen: true)

        if session.fullscreenCommentsVisible {
          Color.black.opacity(0.16)
            .contentShape(Rectangle())
            .onTapGesture { session.fullscreenCommentsVisible = false }
            .transition(.opacity)
          fullscreenCommentsOverlay(in: proxy)
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .background(Color.black)
    .ignoresSafeArea()
    .animation(.easeInOut(duration: 0.24), value: session.fullscreenCommentsVisible)
    .onDisappear { session.fullscreenCommentsVisible = false }
  }

  @ViewBuilder
  private func fullscreenCommentsOverlay(in proxy: GeometryProxy) -> some View {
    if proxy.size.width > proxy.size.height {
      HStack(spacing: 0) {
        Spacer(minLength: 0)
        PiliNativeFullscreenCommentsDrawer(
          model: model,
          close: { session.fullscreenCommentsVisible = false }
        )
        .frame(width: min(420, max(260, proxy.size.width * 0.30)))
        .padding(.trailing, proxy.safeAreaInsets.trailing)
        .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    } else {
      VStack(spacing: 0) {
        Spacer(minLength: 0)
        PiliNativeFullscreenCommentsDrawer(
          model: model,
          close: { session.fullscreenCommentsVisible = false }
        )
        .frame(height: min(440, proxy.size.height * 0.46))
        .padding(.bottom, proxy.safeAreaInsets.bottom)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
  }
}

private struct PiliNativeFullscreenCommentsDrawer: View {
  @ObservedObject var model: PiliNativeViewModel
  let close: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Text("评论")
          .font(.headline)
        if model.commentsTotal > 0 {
          Text(String(model.commentsTotal))
            .font(.caption)
            .foregroundColor(.secondary)
        }
        Spacer(minLength: 0)
        Button(action: model.beginDynamicComment) {
          Image(systemName: "square.and.pencil")
        }
        .accessibilityLabel("写评论")
        Button(action: close) {
          Image(systemName: "xmark.circle.fill")
            .font(.title3)
        }
        .accessibilityLabel("收起评论")
      }
      .foregroundColor(.primary)
      .padding(.horizontal, 16)
      .frame(height: 52)
      Divider()

      ScrollView {
        PiliNativeCommentsSection(model: model, showsHeader: false)
          .padding(.horizontal, 14)
          .padding(.vertical, 12)
      }
    }
    .background(Color(UIColor.systemBackground).opacity(0.97))
    .clipShape(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
    )
    .shadow(color: Color.black.opacity(0.28), radius: 18, x: -5, y: 0)
  }
}

private struct PiliNativeVideoMetric: View {
  let icon: String
  let value: Int
  let title: String
  var color: Color = .secondary

  var body: some View {
    VStack(spacing: 5) {
      Image(systemName: icon).font(.title3)
      Text(value > 0 ? piliCompactNumber(value) : title)
        .font(.caption)
        .lineLimit(1)
    }
    .foregroundColor(color)
    .frame(maxWidth: .infinity)
  }
}

// MARK: - Native dynamic detail and comments

private struct PiliNativeDynamicDetailView: View {
  @ObservedObject var model: PiliNativeViewModel
  @Environment(\.presentationMode) private var presentationMode

  var body: some View {
    NavigationView {
      Group {
        if let item = model.selectedDynamic {
          ScrollView {
            VStack(alignment: .leading, spacing: 16) {
              Button(action: model.openDynamicMember) {
                HStack(spacing: 11) {
                  PiliRemoteImage(urlString: item.avatar)
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
                  VStack(alignment: .leading, spacing: 3) {
                    Text(item.author.isEmpty ? "动态" : item.author)
                      .font(.headline)
                      .foregroundColor(.primary)
                    Text(item.time)
                      .font(.caption)
                      .foregroundColor(.secondary)
                  }
                  Spacer()
                  if item.authorID != nil {
                    Image(systemName: "chevron.right")
                      .font(.caption)
                      .foregroundColor(Color(UIColor.tertiaryLabel))
                  }
                }
              }
              .buttonStyle(PlainButtonStyle())
              .disabled(item.authorID == nil)

              if !item.title.isEmpty {
                Text(item.title)
                  .font(.title3)
                  .fontWeight(.semibold)
              }
              if !item.body.isEmpty {
                Text(item.body)
                  .font(.body)
                  .fixedSize(horizontal: false, vertical: true)
                  .textSelection(.enabled)
              }
              if !item.pictures.isEmpty {
                PiliNativeDynamicPicturesView(
                  pictures: item.pictures,
                  maxWidth: min(UIScreen.main.bounds.width - 32, 600),
                  singleMaxHeight: 520
                )
              }

              if item.bvid != nil {
                Button(action: model.openDynamicVideo) {
                  Label("查看视频", systemImage: "play.rectangle.fill")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(piliAccent)
                    .cornerRadius(11)
                }
                .buttonStyle(PlainButtonStyle())
              }

              HStack(spacing: 0) {
                Button(action: model.beginDynamicRepost) {
                  PiliNativeStat(icon: "arrowshape.turn.up.right", count: item.forward)
                    .frame(maxWidth: .infinity)
                }
                Button(action: model.beginDynamicComment) {
                  PiliNativeStat(icon: "bubble.left", count: item.comment)
                    .frame(maxWidth: .infinity)
                }
                Button(action: model.toggleDynamicLike) {
                  PiliNativeStat(
                    icon: item.liked ? "hand.thumbsup.fill" : "hand.thumbsup",
                    count: item.like,
                    color: item.liked ? piliAccent : .secondary
                  )
                  .frame(maxWidth: .infinity)
                }
              }
              .buttonStyle(PlainButtonStyle())
              .disabled(model.dynamicActionLoading)
              .padding(.horizontal, 22)
              .padding(.vertical, 12)
              .background(Color(UIColor.secondarySystemGroupedBackground))
              .cornerRadius(11)

              if model.dynamicDetailLoading {
                ProgressView("正在加载完整动态")
                  .font(.caption)
                  .frame(maxWidth: .infinity, alignment: .center)
              } else if let message = model.dynamicMessage {
                Text(message)
                  .font(.caption)
                  .foregroundColor(.secondary)
                  .frame(maxWidth: .infinity, alignment: .center)
              }

              Divider()
              PiliNativeCommentsSection(model: model)
            }
            .padding(16)
          }
          .background(Color(UIColor.systemGroupedBackground))
        } else {
          PiliNativeErrorView(message: "动态内容不可用", retry: {})
        }
      }
      .navigationBarTitle("动态详情", displayMode: .inline)
      .navigationBarItems(
        leading: Button("关闭") {
          model.isDynamicDetailPresented = false
          presentationMode.wrappedValue.dismiss()
        }
      )
    }
    .navigationViewStyle(StackNavigationViewStyle())
    .sheet(isPresented: $model.isDynamicComposerPresented) {
      PiliNativeDynamicComposerView(model: model)
        .piliEdgeSwipeBack { model.isDynamicComposerPresented = false }
    }
    .fullScreenCover(isPresented: $model.isCommentThreadPresented) {
      PiliNativeCommentThreadView(model: model)
        .piliEdgeSwipeBack { model.isCommentThreadPresented = false }
    }
  }
}

private struct PiliNativeCommentsSection: View {
  @ObservedObject var model: PiliNativeViewModel
  var showsHeader = true

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      if showsHeader {
        HStack {
          Text("评论")
            .font(.headline)
          if model.commentsTotal > 0 {
            Text(String(model.commentsTotal))
              .font(.caption)
              .foregroundColor(.secondary)
          }
          Spacer()
          Button(action: model.beginDynamicComment) {
            Label("写评论", systemImage: "square.and.pencil")
              .font(.caption)
          }
          .disabled(model.dynamicActionLoading)
        }
      }

      if let error = model.commentsError, !model.comments.isEmpty {
        Text(error)
          .font(.caption)
          .foregroundColor(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      if model.commentsLoading && model.comments.isEmpty {
        HStack(spacing: 9) {
          ProgressView()
          Text("正在加载评论")
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, minHeight: 70)
      } else if let error = model.commentsError, model.comments.isEmpty {
        Text(error)
          .font(.subheadline)
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity, minHeight: 70)
      } else if model.comments.isEmpty {
        Text("暂时没有评论")
          .font(.subheadline)
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity, minHeight: 70)
      } else {
        ForEach(model.comments) { comment in
          PiliNativeCommentRow(
            comment: comment,
            openMember: { model.openCommentMember(comment) },
            toggleLike: { model.toggleCommentLike(comment) },
            reply: { model.beginCommentReply(comment) },
            openReplies: { model.openCommentThread(comment) }
          )
          .onAppear {
            if comment.id == model.comments.last?.id {
              model.loadMoreComments()
            }
          }
          if comment.id != model.comments.last?.id {
            Divider().padding(.leading, 50)
          }
        }

        if model.commentsLoadingMore {
          ProgressView("正在加载更多评论")
            .font(.caption)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else if model.commentsHasMore {
          Button("加载更多评论", action: model.loadMoreComments)
            .font(.caption)
            .foregroundColor(piliAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
      }
    }
  }
}

private struct PiliNativeDynamicComposerView: View {
  @ObservedObject var model: PiliNativeViewModel
  @Environment(\.presentationMode) private var presentationMode

  var body: some View {
    NavigationView {
      VStack(alignment: .leading, spacing: 12) {
        Text(model.dynamicComposerHint)
          .font(.subheadline)
          .foregroundColor(.secondary)
        TextEditor(text: $model.dynamicComposerText)
          .font(.body)
          .padding(8)
          .background(Color(UIColor.secondarySystemGroupedBackground))
          .cornerRadius(10)
          .frame(minHeight: 180)
        HStack {
          Text("\(model.dynamicComposerText.count)/1000")
            .font(.caption)
            .foregroundColor(model.dynamicComposerText.count > 1000 ? .red : .secondary)
          Spacer()
          if model.dynamicActionLoading {
            ProgressView()
          }
        }
        if let message = model.dynamicMessage {
          Text(message)
            .font(.caption)
            .foregroundColor(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        Spacer()
      }
      .padding(16)
      .background(Color(UIColor.systemBackground))
      .navigationBarTitle(model.dynamicComposerTitle, displayMode: .inline)
      .navigationBarItems(
        leading: Button("取消") {
          model.isDynamicComposerPresented = false
          presentationMode.wrappedValue.dismiss()
        },
        trailing: Button(model.dynamicComposerMode == "repost" ? "转发" : "发布") {
          model.publishDynamicComposer()
        }
        .disabled(
          model.dynamicActionLoading ||
          model.dynamicComposerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
          model.dynamicComposerText.count > 1000
        )
      )
    }
    .navigationViewStyle(StackNavigationViewStyle())
  }
}

private struct PiliNativeCommentThreadView: View {
  @ObservedObject var model: PiliNativeViewModel
  @Environment(\.presentationMode) private var presentationMode

  var body: some View {
    NavigationView {
      Group {
        if let root = model.commentThreadRoot {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
              PiliNativeCommentRow(
                comment: root,
                openMember: { model.openCommentMember(root) },
                toggleLike: { model.toggleCommentLike(root) },
                reply: { model.beginCommentReply(root) }
              )
              .padding(.horizontal, 14)
              Divider()
              if let error = model.commentThreadError,
                 !model.commentThreadItems.isEmpty {
                Text(error)
                  .font(.caption)
                  .foregroundColor(.red)
                  .padding(.horizontal, 14)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              if model.commentThreadLoading && model.commentThreadItems.isEmpty {
                ProgressView("正在加载回复")
                  .frame(maxWidth: .infinity, minHeight: 120)
              } else if let error = model.commentThreadError,
                        model.commentThreadItems.isEmpty {
                VStack(spacing: 10) {
                  Text(error).foregroundColor(.secondary)
                  Button("重试", action: model.loadCommentThread)
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, minHeight: 120)
              } else if model.commentThreadItems.isEmpty {
                Text("暂时没有二级评论")
                  .font(.subheadline)
                  .foregroundColor(.secondary)
                  .frame(maxWidth: .infinity, minHeight: 120)
              } else {
                ForEach(model.commentThreadItems) { comment in
                  PiliNativeCommentRow(
                    comment: comment,
                    openMember: { model.openCommentMember(comment) },
                    toggleLike: { model.toggleThreadCommentLike(comment) },
                    reply: { model.beginCommentReply(comment, root: root) }
                  )
                  .padding(.horizontal, 14)
                  .onAppear {
                    if comment.id == model.commentThreadItems.last?.id {
                      model.loadMoreCommentThread()
                    }
                  }
                  if comment.id != model.commentThreadItems.last?.id {
                    Divider().padding(.leading, 64)
                  }
                }

                if model.commentThreadLoadingMore {
                  ProgressView("正在加载更多回复")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                } else if model.commentThreadHasMore {
                  Button("加载更多回复", action: model.loadMoreCommentThread)
                    .font(.caption)
                    .foregroundColor(piliAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
              }
            }
            .padding(.vertical, 12)
          }
          .background(Color(UIColor.systemBackground))
        } else {
          PiliNativeErrorView(message: "评论详情不可用", retry: {})
        }
      }
      .navigationBarTitle(
        model.commentThreadTotal > 0 ? "\(model.commentThreadTotal) 条回复" : "评论详情",
        displayMode: .inline
      )
      .navigationBarItems(
        leading: Button("关闭") {
          model.isCommentThreadPresented = false
          presentationMode.wrappedValue.dismiss()
        },
        trailing: Button("回复") {
          if let root = model.commentThreadRoot {
            model.beginCommentReply(root)
          }
        }
      )
    }
    .navigationViewStyle(StackNavigationViewStyle())
    .sheet(isPresented: $model.isDynamicComposerPresented) {
      PiliNativeDynamicComposerView(model: model)
        .piliEdgeSwipeBack { model.isDynamicComposerPresented = false }
    }
  }
}

/// Mirrors PiliPlus' original comment renderer: bracketed tokens are matched
/// against Content.emotes and replaced with an inline image at size * 20pt.
private final class PiliNativeMultilineLabel: UILabel {
  override func layoutSubviews() {
    super.layoutSubviews()
    let availableWidth = bounds.width
    if availableWidth > 0 && abs(preferredMaxLayoutWidth - availableWidth) > 0.5 {
      preferredMaxLayoutWidth = availableWidth
      invalidateIntrinsicContentSize()
    }
  }

  override var intrinsicContentSize: CGSize {
    guard preferredMaxLayoutWidth > 0 else { return super.intrinsicContentSize }
    return sizeThatFits(
      CGSize(width: preferredMaxLayoutWidth, height: CGFloat.greatestFiniteMagnitude)
    )
  }
}

private struct PiliNativeCommentRichText: UIViewRepresentable {
  let message: String
  let emotes: [String: PiliNativeCommentEmote]
  let textStyle: UIFont.TextStyle
  let textColor: UIColor

  private static let imageCache = NSCache<NSURL, UIImage>()

  init(
    message: String,
    emotes: [String: PiliNativeCommentEmote],
    textStyle: UIFont.TextStyle = .subheadline,
    textColor: UIColor = .label
  ) {
    self.message = message
    self.emotes = emotes
    self.textStyle = textStyle
    self.textColor = textColor
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeUIView(context: Context) -> UILabel {
    let label = PiliNativeMultilineLabel()
    label.backgroundColor = .clear
    label.numberOfLines = 0
    label.lineBreakMode = .byWordWrapping
    label.adjustsFontForContentSizeCategory = true
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    context.coordinator.label = label
    return label
  }

  func updateUIView(_ label: UILabel, context: Context) {
    context.coordinator.parent = self
    context.coordinator.render(in: label)
  }

  final class Coordinator {
    var parent: PiliNativeCommentRichText
    weak var label: UILabel?
    private var requestedURLs = Set<String>()

    init(parent: PiliNativeCommentRichText) {
      self.parent = parent
    }

    func render(in label: UILabel) {
      let font = UIFont.preferredFont(forTextStyle: parent.textStyle)
      let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: parent.textColor,
      ]
      let output = NSMutableAttributedString(string: "")
      let source = parent.message as NSString
      let keys = parent.emotes.keys.sorted { $0.count > $1.count }
      guard !keys.isEmpty else {
        label.attributedText = NSAttributedString(
          string: parent.message,
          attributes: attributes
        )
        label.accessibilityLabel = parent.message
        return
      }

      let pattern = keys
        .map { NSRegularExpression.escapedPattern(for: $0) }
        .joined(separator: "|")
      guard let regex = try? NSRegularExpression(pattern: pattern) else {
        label.attributedText = NSAttributedString(
          string: parent.message,
          attributes: attributes
        )
        return
      }

      var cursor = 0
      for match in regex.matches(
        in: parent.message,
        range: NSRange(location: 0, length: source.length)
      ) {
        if match.range.location > cursor {
          output.append(
            NSAttributedString(
              string: source.substring(
                with: NSRange(
                  location: cursor,
                  length: match.range.location - cursor
                )
              ),
              attributes: attributes
            )
          )
        }

        let token = source.substring(with: match.range)
        if let emote = parent.emotes[token] {
          output.append(attachment(for: emote, font: font))
          requestImageIfNeeded(emote)
        } else {
          output.append(NSAttributedString(string: token, attributes: attributes))
        }
        cursor = NSMaxRange(match.range)
      }

      if cursor < source.length {
        output.append(
          NSAttributedString(
            string: source.substring(from: cursor),
            attributes: attributes
          )
        )
      }
      label.attributedText = output
      label.accessibilityLabel = parent.message
    }

    private func attachment(
      for emote: PiliNativeCommentEmote,
      font: UIFont
    ) -> NSAttributedString {
      let pointSize = CGFloat(emote.size) * 20
      let attachment = NSTextAttachment()
      if let url = URL(string: emote.url),
         let cached = PiliNativeCommentRichText.imageCache.object(forKey: url as NSURL) {
        attachment.image = cached
      } else {
        attachment.image = UIImage(systemName: "face.smiling")?.withTintColor(
          .tertiaryLabel,
          renderingMode: .alwaysOriginal
        )
      }
      attachment.bounds = CGRect(
        x: 0,
        y: font.descender / 2,
        width: pointSize,
        height: pointSize
      )
      return NSAttributedString(attachment: attachment)
    }

    private func requestImageIfNeeded(_ emote: PiliNativeCommentEmote) {
      guard
        let url = URL(string: emote.url),
        PiliNativeCommentRichText.imageCache.object(forKey: url as NSURL) == nil,
        requestedURLs.insert(emote.url).inserted
      else { return }

      URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
        guard let self = self else { return }
        guard let data = data, let image = UIImage(data: data) else {
          DispatchQueue.main.async { self.requestedURLs.remove(emote.url) }
          return
        }
        PiliNativeCommentRichText.imageCache.setObject(image, forKey: url as NSURL)
        DispatchQueue.main.async {
          guard let label = self.label else { return }
          self.render(in: label)
          label.invalidateIntrinsicContentSize()
        }
      }.resume()
    }
  }
}

private struct PiliNativeCommentRow: View {
  let comment: PiliNativeComment
  let openMember: () -> Void
  let toggleLike: () -> Void
  let reply: () -> Void
  let openReplies: () -> Void

  init(
    comment: PiliNativeComment,
    openMember: @escaping () -> Void,
    toggleLike: @escaping () -> Void,
    reply: @escaping () -> Void = {},
    openReplies: @escaping () -> Void = {}
  ) {
    self.comment = comment
    self.openMember = openMember
    self.toggleLike = toggleLike
    self.reply = reply
    self.openReplies = openReplies
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Button(action: openMember) {
        PiliRemoteImage(urlString: comment.avatar)
          .frame(width: 40, height: 40)
          .clipShape(Circle())
      }
      .buttonStyle(PlainButtonStyle())
      .disabled(comment.memberID == nil)

      VStack(alignment: .leading, spacing: 7) {
        HStack(spacing: 7) {
          Text(comment.author)
            .font(.subheadline)
            .fontWeight(.semibold)
          if comment.level > 0 {
            PiliOriginalLevelBadge(level: comment.level, height: 11)
          }
          Spacer()
          Button(action: toggleLike) {
            Label(comment.like > 0 ? String(comment.like) : "", systemImage: comment.liked ? "hand.thumbsup.fill" : "hand.thumbsup")
              .font(.caption)
              .foregroundColor(comment.liked ? piliAccent : .secondary)
          }
          .buttonStyle(PlainButtonStyle())
        }

        PiliNativeCommentRichText(
          message: comment.message,
          emotes: comment.emotes
        )
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)

        if !comment.pictures.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
              ForEach(comment.pictures, id: \.self) { picture in
                PiliNativeCommentPictureView(picture: picture)
              }
            }
          }
        }

        HStack(spacing: 8) {
          Text(comment.time)
          if !comment.location.isEmpty { Text(comment.location) }
          Button("回复", action: reply)
            .buttonStyle(PlainButtonStyle())
          if comment.replyCount > 0 {
            Button("\(comment.replyCount) 条回复", action: openReplies)
              .buttonStyle(PlainButtonStyle())
              .foregroundColor(piliAccent)
          }
        }
        .font(.caption2)
        .foregroundColor(.secondary)
      }
    }
    .padding(.vertical, 4)
  }
}

private struct PiliNativeCommentPictureView: View {
  let picture: PiliNativeCommentPicture
  @StateObject private var loader: PiliImageLoader

  init(picture: PiliNativeCommentPicture) {
    self.picture = picture
    _loader = StateObject(wrappedValue: PiliImageLoader(urlString: picture.url))
  }

  private var displaySize: CGSize {
    let sourceSize: CGSize
    if picture.width > 0, picture.height > 0 {
      sourceSize = CGSize(width: picture.width, height: picture.height)
    } else if let image = loader.image, image.size.width > 0, image.size.height > 0 {
      sourceSize = image.size
    } else {
      return CGSize(width: 140, height: 140)
    }

    let scale = min(min(220 / sourceSize.width, 180 / sourceSize.height), 1)
    return CGSize(
      width: max(sourceSize.width * scale, 1),
      height: max(sourceSize.height * scale, 1)
    )
  }

  var body: some View {
    Group {
      if let image = loader.image {
        Image(uiImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
      } else {
        ZStack {
          Color(UIColor.tertiarySystemFill)
          Image(systemName: "photo")
            .foregroundColor(Color(UIColor.tertiaryLabel))
        }
      }
    }
    .frame(width: displaySize.width, height: displaySize.height)
    .background(Color(UIColor.tertiarySystemFill))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

// MARK: - Native messages

private struct PiliNativeMessagesView: View {
  @ObservedObject var model: PiliNativeViewModel
  @Environment(\.presentationMode) private var presentationMode
  @State private var searchText = ""

  private let kinds: [(id: String, title: String)] = [
    ("sessions", "私信"),
    ("reply", "回复"),
    ("at", "@我"),
    ("like", "点赞"),
    ("system", "系统"),
  ]

  private var filteredMessages: [PiliNativeMessage] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return model.messages }
    return model.messages.filter { message in
      [message.author, message.body, message.context, message.badge]
        .contains { $0.localizedCaseInsensitiveContains(query) }
    }
  }

  var body: some View {
    NavigationView {
      VStack(spacing: 0) {
        folderBar
        Divider()
        messageContent
      }
      .background(Color(UIColor.systemBackground))
      .navigationBarTitle("消息", displayMode: .large)
      .navigationBarItems(
        leading: Button("关闭") { presentationMode.wrappedValue.dismiss() }
      )
      .searchable(
        text: $searchText,
        placement: .navigationBarDrawer(displayMode: .always),
        prompt: "搜索消息"
      )
    }
    .navigationViewStyle(StackNavigationViewStyle())
    .fullScreenCover(item: $model.selectedChat) { chat in
      PiliNativeChatView(model: model, chat: chat)
        .piliEdgeSwipeBack { model.selectedChat = nil }
    }
  }

  private var folderBar: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 4) {
        ForEach(kinds, id: \.id) { kind in
          Button {
            guard kind.id != model.messageKind else { return }
            searchText = ""
            model.loadMessages(kind: kind.id, refresh: true)
          } label: {
            VStack(spacing: 8) {
              Text(kind.title)
                .font(.system(size: 14, weight: model.messageKind == kind.id ? .semibold : .regular))
                .foregroundColor(model.messageKind == kind.id ? piliAccent : .secondary)
                .padding(.horizontal, 12)
              Capsule()
                .fill(model.messageKind == kind.id ? piliAccent : Color.clear)
                .frame(height: 3)
            }
            .padding(.top, 8)
          }
          .buttonStyle(PlainButtonStyle())
          .accessibilityLabel("\(kind.title)消息")
          .accessibilityValue(model.messageKind == kind.id ? "已选中" : "")
        }
      }
      .padding(.horizontal, 8)
    }
    .background(Color(UIColor.systemBackground))
  }

  @ViewBuilder
  private var messageContent: some View {
    if model.messagesLoading && model.messages.isEmpty {
      PiliNativeLoadingView(title: "正在加载消息")
    } else if let error = model.messagesError, model.messages.isEmpty {
      PiliNativeErrorView(message: error) {
        model.loadMessages(refresh: true)
      }
    } else if filteredMessages.isEmpty {
      ScrollView {
        PiliNativeEmptyView(
          icon: searchText.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass",
          title: searchText.isEmpty
            ? (model.messageKind == "sessions" ? "暂无私信" : "暂无消息")
            : "没有找到消息",
          subtitle: searchText.isEmpty
            ? (model.messageKind == "sessions" ? "新的会话会显示在这里" : "新的互动消息会显示在这里")
            : "试试其他关键词"
        )
        .frame(maxWidth: .infinity, minHeight: 420)
      }
      .refreshable { model.loadMessages(refresh: true) }
    } else {
      ScrollView {
        LazyVStack(spacing: 0) {
          if let error = model.messagesError {
            HStack(spacing: 8) {
              Image(systemName: "exclamationmark.circle")
              Text(error).lineLimit(2)
              Spacer(minLength: 0)
              Button("重试") { model.loadMoreMessages() }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color(UIColor.secondarySystemBackground))
          }

          ForEach(filteredMessages) { message in
            Button {
              model.openMessage(message)
            } label: {
              PiliNativeMessageRow(message: message)
            }
            .buttonStyle(PlainButtonStyle())
            .contextMenu {
              if message.memberID != nil {
                Button {
                  model.openMessageMember(message)
                } label: {
                  Label("查看用户", systemImage: "person.crop.circle")
                }
              }
            }
            .onAppear {
              if searchText.isEmpty, message.id == model.messages.last?.id {
                model.loadMoreMessages()
              }
            }

            if message.id != filteredMessages.last?.id {
              Divider().padding(.leading, 82)
            }
          }

          if model.messagesLoadingMore {
            ProgressView("正在加载更多消息")
              .font(.caption)
              .padding(.vertical, 18)
          } else if model.messagesHasMore {
            Button("加载更多消息", action: model.loadMoreMessages)
              .font(.caption)
              .foregroundColor(piliAccent)
              .padding(.vertical, 18)
          }
        }
      }
      .refreshable { model.loadMessages(refresh: true) }
    }
  }
}

private struct PiliNativeMessageRow: View {
  let message: PiliNativeMessage

  private var accent: Color {
    switch message.kind {
    case "session": return piliAccent
    case "reply": return .blue
    case "at": return .orange
    case "like": return piliAccent
    default: return .purple
    }
  }

  private var fallbackIcon: String {
    switch message.kind {
    case "session": return "person.crop.circle.fill"
    case "reply": return "bubble.left.fill"
    case "at": return "at"
    case "like": return "hand.thumbsup.fill"
    default: return "bell.fill"
    }
  }

  var body: some View {
    SGChatListRow(
      title: message.author.isEmpty ? "消息" : message.author,
      subtitle: message.body,
      context: message.context,
      time: message.time,
      isPinned: message.isPinned,
      titleBadge: message.isLive ? "直播中" : "",
      accentColor: piliAccent
    ) {
      avatar
    } accessory: {
      accessory
    }
  }

  @ViewBuilder
  private var accessory: some View {
    if message.kind == "session", message.isMuted {
      Image(systemName: "speaker.slash.fill")
        .font(.caption)
        .foregroundColor(Color(UIColor.tertiaryLabel))
    } else if message.kind == "session", message.hasUnread {
      Text(message.unreadCount > 0 ? "\(min(message.unreadCount, 99))" : "")
        .font(.system(size: 11, weight: .bold))
        .foregroundColor(.white)
        .frame(minWidth: 20, minHeight: 20)
        .padding(.horizontal, message.unreadCount > 9 ? 3 : 0)
        .background(piliAccent)
        .clipShape(Capsule())
    } else if let cover = message.cover {
      PiliRemoteImage(urlString: cover)
        .frame(width: 42, height: 42)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    } else if !message.badge.isEmpty {
      Text(message.badge)
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.white)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(accent)
        .clipShape(Capsule())
    }
  }

  private var avatar: some View {
    ZStack {
      Circle().fill(accent.opacity(0.14))
      if let avatar = message.avatar {
        PiliRemoteImage(urlString: avatar)
          .frame(width: SGMessageMetrics.chatListAvatarDiameter, height: SGMessageMetrics.chatListAvatarDiameter)
          .clipShape(Circle())
      } else {
        Image(systemName: fallbackIcon)
          .font(.system(size: 22, weight: .semibold))
          .foregroundColor(accent)
      }
    }
    .frame(width: SGMessageMetrics.chatListAvatarDiameter, height: SGMessageMetrics.chatListAvatarDiameter)
  }
}

private struct PiliNativeChatView: View {
  @ObservedObject var model: PiliNativeViewModel
  let chat: PiliNativeMessage
  @State private var draft = ""
  @State private var showEmotes = false
  @State private var showPhotoPicker = false
  @State private var hasScrolledInitially = false
  @State private var scrollAfterUpdate = false

  private let preferredQuickEmoteTokens = [
    "[doge]", "[笑哭]", "[喜欢]", "[打call]", "[妙啊]", "[大哭]", "[鼓掌]", "[给心心]",
  ]

  private var quickEmotes: [SGQuickEmote] {
    var available: [String: PiliNativeCommentEmote] = [:]
    for message in model.chatMessages {
      for (token, emote) in message.emotes where available[token] == nil {
        available[token] = emote
      }
    }

    var tokens = preferredQuickEmoteTokens
    tokens.append(
      contentsOf: available.keys
        .filter { !preferredQuickEmoteTokens.contains($0) }
        .sorted()
        .prefix(24)
    )
    return tokens.map { token in
      SGQuickEmote(token: token, url: available[token].flatMap { URL(string: $0.url) })
    }
  }

  private var orderedMessages: [PiliNativeChatMessage] {
    Array(model.chatMessages.reversed())
  }

  var body: some View {
    NavigationView {
      chatContent
        .background(Color(UIColor.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .navigationBarLeading) {
            Button {
              model.closeChat()
            } label: {
              Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
            }
          }
          ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
              PiliRemoteImage(urlString: chat.avatar)
                .frame(width: 32, height: 32)
                .clipShape(Circle())
              VStack(alignment: .leading, spacing: 1) {
                Text(chat.author)
                  .font(.subheadline.weight(.semibold))
                  .lineLimit(1)
                Text(chat.isLive ? "直播中" : "私信")
                  .font(.caption2)
                  .foregroundColor(chat.isLive ? piliAccent : .secondary)
              }
            }
          }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
          composer
        }
    }
    .navigationViewStyle(StackNavigationViewStyle())
    .sheet(isPresented: $showPhotoPicker) {
      PiliNativeChatPhotoPicker(isPresented: $showPhotoPicker) { url in
        model.sendChatImage(at: url)
        scrollAfterUpdate = true
      }
      .piliEdgeSwipeBack { showPhotoPicker = false }
    }
  }

  @ViewBuilder
  private var chatContent: some View {
    if model.chatLoading && model.chatMessages.isEmpty {
      PiliNativeLoadingView(title: "正在加载聊天记录")
    } else if let error = model.chatError, model.chatMessages.isEmpty {
      PiliNativeErrorView(message: error) { model.loadChat(refresh: true) }
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 10) {
            if model.chatLoadingMore {
              ProgressView("正在加载更早消息")
                .font(.caption)
                .padding(.vertical, 12)
            } else if model.chatHasMore {
              Button("加载更早消息") { model.loadChat(refresh: false) }
                .font(.caption)
                .foregroundColor(piliAccent)
                .padding(.vertical, 12)
            }

            if let error = model.chatError {
              Label(error, systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if orderedMessages.isEmpty {
              PiliNativeEmptyView(
                icon: "bubble.left.and.bubble.right",
                title: "还没有聊天记录",
                subtitle: "发一条消息开始聊天"
              )
              .frame(maxWidth: .infinity, minHeight: 420)
            } else {
              ForEach(orderedMessages) { message in
                PiliNativeChatBubble(message: message) {
                  model.recallChatMessage(message)
                }
                .id(message.id)
                .onAppear {
                  if message.id == model.chatMessages.last?.id {
                    model.loadChat(refresh: false)
                  }
                }
              }
            }
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
        }
        .refreshable { model.loadChat(refresh: true) }
        .onChange(of: model.chatMessages.count) { _ in
          guard let newest = model.chatMessages.first else { return }
          if !hasScrolledInitially || scrollAfterUpdate {
            hasScrolledInitially = true
            scrollAfterUpdate = false
            DispatchQueue.main.async {
              withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(newest.id, anchor: .bottom)
              }
            }
          }
        }
      }
    }
  }

  private var composer: some View {
    SGChatInputPanel(
      text: $draft,
      showsEmotes: $showEmotes,
      isSending: model.chatSending,
      accentColor: piliAccent,
      quickEmotes: quickEmotes,
      onPhoto: {
          showPhotoPicker = true
      },
      onSend: sendDraft
    )
  }

  private func sendDraft() {
    let value = draft
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    model.sendChatMessage(value) { success in
      if success {
        draft = ""
        scrollAfterUpdate = true
      }
    }
  }
}

private struct PiliNativeChatBubble: View {
  let message: PiliNativeChatMessage
  let onRecall: () -> Void

  private var imageSize: CGSize {
    let width = max(message.imageWidth ?? 220, 1)
    let height = max(message.imageHeight ?? 150, 1)
    let displayWidth = min(width, 230)
    return CGSize(width: displayWidth, height: min(max(displayWidth * height / width, 80), 320))
  }

  var body: some View {
    if message.isSystem {
      VStack(spacing: 6) {
        if !message.time.isEmpty { Text(message.time).font(.caption2).foregroundColor(.secondary) }
        VStack(alignment: .leading, spacing: 8) {
          if let cover = message.cover {
            PiliRemoteImage(urlString: cover)
              .frame(maxWidth: 300, minHeight: 120, maxHeight: 180)
              .clipped()
              .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          }
          if let title = message.title { Text(title).font(.headline) }
          if !message.text.isEmpty { Text(message.text).font(.subheadline) }
        }
        .padding(12)
        .frame(maxWidth: 360, alignment: .leading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      }
      .frame(maxWidth: .infinity)
    } else {
      VStack(alignment: message.isOwner ? .trailing : .leading, spacing: 4) {
        if !message.time.isEmpty {
          Text(message.time)
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        HStack {
          if message.isOwner { Spacer(minLength: 55) }
          bubbleContent
          if !message.isOwner { Spacer(minLength: 55) }
        }
      }
      .frame(maxWidth: .infinity, alignment: message.isOwner ? .trailing : .leading)
      .contextMenu {
        if message.isOwner && message.msgKey > 0 && !message.isRecalled {
          Button(role: .destructive, action: onRecall) {
            Label("撤回", systemImage: "arrow.uturn.backward")
          }
        }
      }
    }
  }

  @ViewBuilder
  private var bubbleContent: some View {
    if let emote = message.emote {
      PiliRemoteImage(urlString: emote)
        .frame(width: 96, height: 96)
    } else {
      SGMessageBubble(
        isOutgoing: message.isOwner,
        backgroundColor: message.isOwner ? piliAccent : Color(UIColor.secondarySystemBackground)
      ) {
        VStack(alignment: message.isOwner ? .trailing : .leading, spacing: 6) {
          if let image = message.image {
            PiliRemoteImage(urlString: image)
              .frame(width: imageSize.width, height: imageSize.height)
              .clipped()
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          } else if message.emotes.isEmpty || message.isRecalled {
            Text(message.isRecalled ? "已撤回" : message.text)
              .font(.body)
              .foregroundColor(message.isOwner ? .white : .primary)
              .textSelection(.enabled)
          } else {
            PiliNativeCommentRichText(
              message: message.text,
              emotes: message.emotes,
              textStyle: .body,
              textColor: message.isOwner ? .white : .label
            )
            .fixedSize(horizontal: false, vertical: true)
          }
          if message.isAutoReply {
            Text("自动回复")
              .font(.caption2)
              .foregroundColor(message.isOwner ? .white.opacity(0.72) : .secondary)
          }
        }
        .padding(message.image == nil ? 11 : 6)
      }
    }
  }
}

private struct PiliNativeChatPhotoPicker: UIViewControllerRepresentable {
  @Binding var isPresented: Bool
  let onPicked: (URL) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  func makeUIViewController(context: Context) -> PHPickerViewController {
    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.selectionLimit = 1
    configuration.filter = .images
    let controller = PHPickerViewController(configuration: configuration)
    controller.delegate = context.coordinator
    return controller
  }

  func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

  final class Coordinator: NSObject, PHPickerViewControllerDelegate {
    var parent: PiliNativeChatPhotoPicker

    init(parent: PiliNativeChatPhotoPicker) { self.parent = parent }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
      guard let provider = results.first?.itemProvider,
            provider.canLoadObject(ofClass: UIImage.self) else {
        parent.isPresented = false
        return
      }
      provider.loadObject(ofClass: UIImage.self) { object, _ in
        guard let image = object as? UIImage,
              let data = image.jpegData(compressionQuality: 0.92) else {
          DispatchQueue.main.async { self.parent.isPresented = false }
          return
        }
        let url = FileManager.default.temporaryDirectory
          .appendingPathComponent("piliglass-chat-\(UUID().uuidString).jpg")
        do {
          try data.write(to: url, options: .atomic)
          DispatchQueue.main.async {
            self.parent.isPresented = false
            self.parent.onPicked(url)
          }
        } catch {
          DispatchQueue.main.async { self.parent.isPresented = false }
        }
      }
    }
  }
}

// MARK: - Native QR login

private struct PiliNativeLoginView: View {
  @ObservedObject var model: PiliNativeViewModel
  @Environment(\.presentationMode) private var presentationMode
  private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

  var body: some View {
    NavigationView {
      VStack(spacing: 22) {
        Spacer()
        Image(systemName: "person.crop.circle.badge.checkmark")
          .font(.system(size: 44))
          .foregroundColor(piliAccent)

        Text("登录哔哩哔哩")
          .font(.title2)
          .fontWeight(.bold)

        Group {
          if model.loginLoading {
            ProgressView()
              .frame(width: 230, height: 230)
          } else if !model.loginQRCodeURL.isEmpty && model.loginExpiresIn > 0 {
            PiliQRCodeView(text: model.loginQRCodeURL)
              .frame(width: 230, height: 230)
              .padding(12)
              .background(Color.white)
              .cornerRadius(16)
              .shadow(color: .black.opacity(0.08), radius: 12)
          } else {
            Button(action: model.startNativeLogin) {
              VStack(spacing: 10) {
                Image(systemName: "qrcode")
                  .font(.system(size: 70))
                Text("刷新二维码")
              }
              .frame(width: 230, height: 230)
              .background(Color(UIColor.secondarySystemGroupedBackground))
              .cornerRadius(16)
            }
            .buttonStyle(PlainButtonStyle())
          }
        }

        Text(model.loginMessage)
          .font(.subheadline)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)

        if model.loginExpiresIn > 0 {
          Text("有效期剩余 \(model.loginExpiresIn) 秒")
            .font(.caption)
            .foregroundColor(.secondary)
        }

        Button(action: model.startNativeLogin) {
          Label("刷新二维码", systemImage: "arrow.clockwise")
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(piliAccent)
        .padding(.horizontal, 36)
        .disabled(model.loginLoading)

        Spacer()
      }
      .padding()
      .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
      .navigationBarTitle("扫码登录", displayMode: .inline)
      .navigationBarItems(
        leading: Button("关闭") {
          model.isLoginPresented = false
          presentationMode.wrappedValue.dismiss()
        }
      )
    }
    .navigationViewStyle(StackNavigationViewStyle())
    .onReceive(timer) { _ in model.pollNativeLogin() }
  }
}

private struct PiliQRCodeView: View {
  let text: String

  var body: some View {
    if let image = makeQRCode(text) {
      Image(uiImage: image)
        .interpolation(.none)
        .resizable()
        .scaledToFit()
    } else {
      Image(systemName: "qrcode")
        .resizable()
        .scaledToFit()
        .foregroundColor(.black)
    }
  }

  private func makeQRCode(_ value: String) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(value.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
          let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
    return UIImage(cgImage: cgImage)
  }
}

// MARK: - Native downloads

private struct PiliNativeDownloadsView: View {
  @ObservedObject var model: PiliNativeViewModel
  @Environment(\.presentationMode) private var presentationMode

  var body: some View {
    NavigationView {
      Group {
        if model.downloadsLoading && model.downloads.isEmpty {
          PiliNativeLoadingView(title: "正在读取离线缓存")
        } else if let error = model.downloadsError, model.downloads.isEmpty {
          PiliNativeErrorView(message: error, retry: model.presentDownloads)
        } else if model.downloads.isEmpty {
          ScrollView {
            PiliNativeEmptyView(icon: "arrow.down.circle", title: "暂无离线缓存", subtitle: "已缓存和正在缓存的视频会显示在这里")
              .frame(maxWidth: .infinity, minHeight: 520)
          }
          .refreshable { model.presentDownloads() }
        } else {
          List(model.downloads) { item in
            Button(action: { model.openDownload(item) }) {
              HStack(spacing: 11) {
                PiliRemoteImage(urlString: item.cover)
                  .frame(width: 116, height: 66)
                  .clipped()
                  .cornerRadius(8)
                VStack(alignment: .leading, spacing: 6) {
                  Text(item.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                  if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                      .font(.caption)
                      .foregroundColor(.secondary)
                      .lineLimit(1)
                  }
                  ProgressView(value: item.progress)
                    .tint(piliAccent)
                  HStack {
                    Text(item.progressText)
                    Spacer()
                    Text(item.badge)
                  }
                  .font(.caption2)
                  .foregroundColor(.secondary)
                }
              }
              .padding(.vertical, 5)
            }
            .buttonStyle(PlainButtonStyle())
          }
          .listStyle(PlainListStyle())
          .refreshable { model.presentDownloads() }
        }
      }
      .navigationBarTitle("离线缓存", displayMode: .inline)
      .navigationBarItems(
        leading: Button("关闭") { presentationMode.wrappedValue.dismiss() }
      )
    }
    .navigationViewStyle(StackNavigationViewStyle())
  }
}

// MARK: - Native account libraries

private struct PiliNativeLibraryView: View {
  @ObservedObject var model: PiliNativeViewModel
  @Environment(\.presentationMode) private var presentationMode

  var body: some View {
    NavigationView {
      Group {
        if model.libraryLoading && model.libraryItems.isEmpty {
          PiliNativeLoadingView(title: "正在加载\(model.libraryTitle)")
        } else if let error = model.libraryError, model.libraryItems.isEmpty {
          PiliNativeErrorView(message: error) { model.loadLibrary(refresh: true) }
        } else if model.libraryItems.isEmpty {
          ScrollView {
            VStack(spacing: 12) {
              Image(systemName: emptySymbol)
                .font(.system(size: 38))
                .foregroundColor(.secondary)
              Text("这里还没有内容")
                .font(.headline)
              Text("下拉即可刷新内容。")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 30)
            .frame(maxWidth: .infinity, minHeight: 520)
          }
          .background(Color(UIColor.systemGroupedBackground))
          .refreshable { model.loadLibrary(refresh: true) }
        } else {
          ScrollView {
            LazyVStack(spacing: 0) {
              if !model.librarySubtitle.isEmpty {
                Text(model.librarySubtitle)
                  .font(.subheadline)
                  .foregroundColor(.secondary)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.horizontal, 14)
                  .padding(.vertical, 10)
              }

              ForEach(model.libraryItems) { item in
                PiliNativeLibraryRow(item: item) {
                  model.openLibraryItem(item)
                }
                .onAppear {
                  if item.id == model.libraryItems.last?.id {
                    model.loadLibrary(refresh: false)
                  }
                }
                Divider().padding(.leading, 154)
              }

              if model.libraryLoadingMore {
                ProgressView().padding(.vertical, 20)
              } else if !model.libraryHasMore {
                Text("没有更多了")
                  .font(.caption)
                  .foregroundColor(.secondary)
                  .padding(.vertical, 18)
              }
            }
          }
          .background(Color(UIColor.systemBackground))
          .refreshable { model.loadLibrary(refresh: true) }
        }
      }
      .navigationBarTitle(model.libraryTitle, displayMode: .inline)
      .navigationBarItems(
        leading: leadingButton
      )
    }
    .navigationViewStyle(StackNavigationViewStyle())
  }

  private var leadingButton: some View {
    Group {
      if model.libraryCanGoBack {
        Button(action: model.returnToLibraryRoot) {
          Label("返回", systemImage: "chevron.left")
        }
      } else {
        Button("关闭") { presentationMode.wrappedValue.dismiss() }
      }
    }
  }

  private var emptySymbol: String {
    switch model.libraryKind {
    case "history": return "clock.arrow.circlepath"
    case "later": return "clock"
    case "following", "followers": return "person.2"
    case "subscriptions", "subscriptionDetail": return "rectangle.stack"
    default: return "star"
    }
  }
}

private struct PiliNativeLibraryRow: View {
  let item: PiliNativeLibraryItem
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Group {
        if item.kind == "member" {
          memberContent
        } else {
          mediaContent
        }
      }
    }
    .buttonStyle(PlainButtonStyle())
  }

  private var memberContent: some View {
    HStack(spacing: 13) {
      PiliRemoteImage(urlString: item.cover)
        .frame(width: 52, height: 52)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color(UIColor.separator).opacity(0.18)))
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 6) {
          Text(item.title)
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundColor(.primary)
          if !item.badge.isEmpty {
            Image(systemName: "checkmark.seal.fill")
              .font(.caption)
              .foregroundColor(piliAccent)
          }
        }
        Text(item.subtitle.isEmpty ? "这个人很神秘，什么都没有写" : item.subtitle)
          .font(.caption)
          .foregroundColor(.secondary)
          .lineLimit(2)
      }
      Spacer(minLength: 0)
      Image(systemName: "chevron.right")
        .font(.caption)
        .foregroundColor(Color(UIColor.tertiaryLabel))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .contentShape(Rectangle())
  }

  private var mediaContent: some View {
    HStack(alignment: .top, spacing: 12) {
      ZStack(alignment: .bottomLeading) {
        PiliRemoteImage(urlString: item.cover)
          .frame(width: 128, height: 72)
          .clipped()
          .cornerRadius(8)

        if item.progress > 0 {
          GeometryReader { proxy in
            VStack {
              Spacer()
              Rectangle()
                .fill(piliAccent)
                .frame(width: proxy.size.width * item.progress, height: 3)
            }
          }
          .frame(width: 128, height: 72)
          .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        if !item.durationText.isEmpty {
          Text(item.durationText)
            .font(.caption2)
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.68))
            .cornerRadius(4)
            .padding(5)
        }
      }

      VStack(alignment: .leading, spacing: 5) {
        HStack(alignment: .top, spacing: 5) {
          Text(item.title)
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundColor(.primary)
            .lineLimit(2)
          Spacer(minLength: 0)
          if item.kind == "folder" || item.kind == "subscription" {
            Image(systemName: "chevron.right")
              .font(.caption)
              .foregroundColor(Color(UIColor.tertiaryLabel))
          }
        }

        if !item.subtitle.isEmpty {
          Text(item.subtitle)
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
        }

        HStack(spacing: 8) {
          if !item.progressText.isEmpty {
            Text(item.progressText).foregroundColor(piliAccent)
          } else if !item.trailingText.isEmpty {
            Text(item.trailingText)
          } else {
            if !item.viewText.isEmpty {
              Label(item.viewText, systemImage: "play.rectangle")
            }
            if !item.danmakuText.isEmpty {
              Label(item.danmakuText, systemImage: "text.bubble")
            }
          }
          Spacer(minLength: 0)
          if !item.badge.isEmpty {
            Text(item.badge).foregroundColor(piliAccent)
          }
        }
        .font(.caption2)
        .foregroundColor(.secondary)
      }
      .frame(minHeight: 72, alignment: .top)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .contentShape(Rectangle())
  }
}

// MARK: - Native settings

private struct PiliNativeSettingsView: View {
  @ObservedObject var model: PiliNativeViewModel
  @Environment(\.presentationMode) private var presentationMode
  @State private var searchText = ""

  private let groups = [
    "音视频与画质",
    "播放与弹幕",
    "视频详情",
    "推荐与搜索",
    "外观与界面",
    "通用功能",
  ]
  private let advanced: [(String, String, String, String)] = [
    ("privacy", "隐私设置", "hand.raised", "黑名单与账号隐私"),
    ("recommend", "推荐流设置", "sparkles", "推荐来源、刷新保留与过滤器"),
    ("video", "音视频设置", "film", "画质、音质、解码、缓冲与 CDN"),
    ("player", "播放器设置", "play.rectangle", "全屏、手势、弹幕、字幕与进度条"),
    ("style", "外观设置", "paintbrush", "布局、主题、字号、图片与帧率"),
    ("extra", "其它设置", "ellipsis.circle", "评论、动态、代理、搜索与更新"),
    ("webdav", "WebDAV 设置", "externaldrive", "配置同步与备份"),
    ("about", "关于", "info.circle", "版本、项目与界面架构"),
  ]

  var body: some View {
    NavigationView {
      Group {
        if model.settingsLoading && model.settings.isEmpty {
          PiliNativeLoadingView(title: "正在加载设置")
        } else if let error = model.settingsError, model.settings.isEmpty {
          PiliNativeErrorView(message: error, retry: model.loadSettings)
        } else {
          Form {
            if let error = model.settingsError {
              Section {
                Text(error).font(.caption).foregroundColor(.red)
              }
            }

            Section(
              footer: Text("这些开关直接读写原项目的同一份设置数据，播放和请求内核会继续使用修改后的值。")
            ) {
              HStack(spacing: 12) {
                Image(systemName: "iphone.gen3")
                  .font(.title2)
                  .foregroundColor(piliAccent)
                VStack(alignment: .leading, spacing: 3) {
                  Text("iOS 原生设置")
                    .font(.headline)
                  Text("已原生化 \(model.settings.count) 个常用开关")
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
              }
              .padding(.vertical, 4)
            }

            if !model.videoQualityOptions.isEmpty {
              Section(
                header: Text("视频默认值"),
                footer: Text("进入视频时会优先请求该分辨率；账号或视频不支持时由原版接口自动回退到可用画质。")
              ) {
                Picker(
                  selection: Binding(
                    get: { model.defaultVideoQuality },
                    set: { model.setDefaultVideoQuality($0) }
                  ),
                  label: Label("默认视频分辨率", systemImage: "rectangle.badge.hd")
                ) {
                  ForEach(model.videoQualityOptions) { quality in
                    Text(quality.label).tag(quality.value)
                  }
                }
                .pickerStyle(MenuPickerStyle())
              }
            }

            Section(
              header: Text("诊断"),
              footer: Text("播放诊断日志已从播放器控制层移到这里，避免遮挡视频操作。")
            ) {
              NavigationLink(destination: PiliNativeDiagnosticLogSettingsView()) {
                Label("播放器诊断日志", systemImage: "doc.text.magnifyingglass")
              }
            }

            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              Section(
                header: Text("原版设置分类"),
                footer: Text("入口顺序与原版项目保持一致；进入分类后仍直接修改原项目设置存储。")
              ) {
                ForEach(advanced.indices, id: \.self) { index in
                  let item = advanced[index]
                  NavigationLink(
                    destination: PiliNativeSettingsSectionView(
                      section: item.0,
                      title: item.1,
                      model: model
                    )
                  ) {
                    HStack(spacing: 13) {
                      Image(systemName: item.2)
                        .frame(width: 24)
                        .foregroundColor(piliAccent)
                      VStack(alignment: .leading, spacing: 3) {
                        Text(item.1).foregroundColor(.primary)
                        Text(item.3)
                          .font(.caption)
                          .foregroundColor(.secondary)
                      }
                      Spacer()
                    }
                    .padding(.vertical, 2)
                  }
                }
              }
            }

            ForEach(groups, id: \.self) { group in
              if !settings(in: group).isEmpty {
                Section(header: Text(group)) {
                  ForEach(settings(in: group)) { item in
                  Toggle(isOn: binding(for: item)) {
                    HStack(alignment: .top, spacing: 11) {
                      Image(systemName: item.icon)
                        .frame(width: 22)
                        .foregroundColor(piliAccent)
                      VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                          Text(item.title)
                          if item.needsRestart {
                            Text("重启生效")
                              .font(.caption2)
                              .foregroundColor(piliAccent)
                          }
                        }
                        if !item.subtitle.isEmpty {
                          Text(item.subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                      }
                    }
                  }
                  .toggleStyle(SwitchToggleStyle(tint: piliAccent))
                }
              }
            }
            }

          }
          .refreshable { model.loadSettings() }
        }
      }
      .navigationBarTitle("设置", displayMode: .inline)
      .navigationBarItems(
        leading: Button("关闭") { presentationMode.wrappedValue.dismiss() }
      )
      .searchable(text: $searchText, prompt: "搜索设置")
    }
    .navigationViewStyle(StackNavigationViewStyle())
    .onAppear(perform: model.loadSettings)
  }

  private func settings(in group: String) -> [PiliNativeSetting] {
    let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return model.settings.filter { item in
      guard item.group == group else { return false }
      return keyword.isEmpty || item.title.localizedCaseInsensitiveContains(keyword)
        || item.subtitle.localizedCaseInsensitiveContains(keyword)
    }
  }

  private func binding(for item: PiliNativeSetting) -> Binding<Bool> {
    Binding(
      get: {
        model.settings.first(where: { $0.key == item.key })?.value ?? item.value
      },
      set: { model.setSetting(item.key, value: $0) }
    )
  }
}

private struct PiliNativeDiagnosticLogSettingsView: View {
  @State private var logText = ""
  @State private var copied = false

  var body: some View {
    ScrollView {
      Text(logText.isEmpty ? "暂时没有播放器日志" : logText)
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(.primary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }
    .background(Color(UIColor.secondarySystemBackground))
    .navigationBarTitle("播放器诊断日志", displayMode: .inline)
    .toolbar {
      ToolbarItemGroup(placement: .navigationBarTrailing) {
        Button(action: refresh) {
          Image(systemName: "arrow.clockwise")
        }
        Button(action: copyLog) {
          Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        ShareLink(item: logText) {
          Image(systemName: "square.and.arrow.up")
        }
      }
    }
    .onAppear(perform: refresh)
  }

  private func refresh() {
    logText = PiliNativeDiagnosticLog.shared.snapshot()
  }

  private func copyLog() {
    UIPasteboard.general.string = logText
    copied = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
      copied = false
    }
  }
}

private struct PiliNativeSettingsSectionView: View {
  let section: String
  let title: String
  @ObservedObject var model: PiliNativeViewModel
  @State private var webDAVServer = ""
  @State private var webDAVUser = ""
  @State private var webDAVPassword = ""
  @State private var webDAVMessage = ""

  private var group: String? {
    switch section {
    case "recommend": return "推荐与搜索"
    case "video": return "音视频与画质"
    case "player": return "播放与弹幕"
    case "style": return "外观与界面"
    case "extra": return "通用功能"
    default: return nil
    }
  }

  var body: some View {
    Form {
      if let group = group {
        Section(
          header: Text(group),
          footer: Text("修改会直接写入原项目设置存储。")
        ) {
          ForEach(model.settings.filter { $0.group == group }) { item in
            Toggle(isOn: binding(for: item)) {
              VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                if !item.subtitle.isEmpty {
                  Text(item.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
              }
            }
            .toggleStyle(SwitchToggleStyle(tint: piliAccent))
          }
        }
      } else if section == "webdav" {
        Section(header: Text("服务器")) {
          TextField("https://example.com/dav", text: $webDAVServer)
            .textContentType(.URL)
            .autocapitalization(.none)
          TextField("用户名", text: $webDAVUser)
            .textContentType(.username)
            .autocapitalization(.none)
          SecureField("密码", text: $webDAVPassword)
            .textContentType(.password)
          Button("保存本机配置") {
            webDAVMessage = "原生配置已暂存；同步功能将在后续版本接入"
          }
          if !webDAVMessage.isEmpty {
            Text(webDAVMessage)
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }
      } else if section == "about" {
        Section {
          HStack(spacing: 14) {
            Image(systemName: "play.tv.fill")
              .font(.system(size: 38))
              .foregroundColor(piliAccent)
            VStack(alignment: .leading, spacing: 4) {
              Text("PiliGlass")
                .font(.headline)
              Text("iOS Native Frontend")
                .font(.caption)
                .foregroundColor(.secondary)
            }
          }
          .padding(.vertical, 8)
        }
        Section(header: Text("界面架构")) {
          Label("SwiftUI 原生导航与列表", systemImage: "swift")
          Label("Flutter 保留登录与网络协议", systemImage: "network")
          Label("UIKit 自定义播放器与弹幕层", systemImage: "rectangle.on.rectangle")
        }
      } else {
        Section(header: Text("隐私与账号")) {
          Label("登录凭据保存在应用沙盒", systemImage: "lock.shield")
          Label("请求继续使用原项目 CSRF 签名", systemImage: "checkmark.shield")
          Label("原生页面不接触明文 Cookie", systemImage: "eye.slash")
        }
      }
    }
    .navigationBarTitle(title, displayMode: .inline)
  }

  private func binding(for item: PiliNativeSetting) -> Binding<Bool> {
    Binding(
      get: { model.settings.first(where: { $0.key == item.key })?.value ?? item.value },
      set: { model.setSetting(item.key, value: $0) }
    )
  }
}

// MARK: - Native search

private struct PiliNativeSearchView: View {
  @ObservedObject var model: PiliNativeViewModel
  @Environment(\.presentationMode) private var presentationMode
  @State private var keyword = ""

  var body: some View {
    NavigationView {
      VStack(spacing: 0) {
        HStack(spacing: 10) {
          Image(systemName: "magnifyingglass").foregroundColor(.secondary)
          TextField("搜索视频", text: $keyword, onCommit: submit)
            .textFieldStyle(PlainTextFieldStyle())
            .autocapitalization(.none)
            .disableAutocorrection(true)
          if !keyword.isEmpty {
            Button(action: { keyword = "" }) {
              Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
            }
          }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(10)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

        Divider()

        if model.searchLoading && model.searchResults.isEmpty {
          PiliNativeLoadingView(title: "正在搜索")
        } else if let error = model.searchError, model.searchResults.isEmpty {
          PiliNativeErrorView(message: error, retry: submit)
        } else if model.searchResults.isEmpty {
          VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
              .font(.system(size: 34))
              .foregroundColor(.secondary)
            Text("输入关键词搜索视频")
              .font(.subheadline)
              .foregroundColor(.secondary)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(model.searchResults) { video in
                Button(action: {
                  presentationMode.wrappedValue.dismiss()
                  model.openVideo(video)
                }) {
                  HStack(alignment: .top, spacing: 12) {
                    PiliRemoteImage(urlString: video.cover)
                      .frame(width: 128, height: 72)
                      .clipped()
                      .cornerRadius(8)
                    VStack(alignment: .leading, spacing: 6) {
                      Text(video.title)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                      Text(video.owner)
                        .font(.caption)
                        .foregroundColor(.secondary)
                      if !video.viewText.isEmpty {
                        Text("\(video.viewText) 播放")
                          .font(.caption2)
                          .foregroundColor(.secondary)
                      }
                    }
                    Spacer(minLength: 0)
                  }
                  .padding(.horizontal, 14)
                  .padding(.vertical, 10)
                  .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .onAppear {
                  if video.id == model.searchResults.last?.id {
                    model.loadMoreSearchResults()
                  }
                }
                Divider().padding(.leading, 154)
              }

              if model.searchLoadingMore {
                ProgressView("正在加载更多视频")
                  .font(.caption)
                  .padding(.vertical, 18)
              } else if let error = model.searchError {
                VStack(spacing: 8) {
                  Text(error)
                    .font(.caption)
                    .foregroundColor(.secondary)
                  Button("重试加载", action: model.loadMoreSearchResults)
                    .font(.caption)
                    .foregroundColor(piliAccent)
                }
                .padding(.vertical, 14)
              } else if model.searchHasMore {
                Button("加载更多视频", action: model.loadMoreSearchResults)
                  .font(.caption)
                  .foregroundColor(piliAccent)
                  .padding(.vertical, 18)
              }
            }
          }
        }
      }
      .navigationBarTitle("搜索", displayMode: .inline)
      .navigationBarItems(
        leading: Button("关闭") { presentationMode.wrappedValue.dismiss() },
        trailing: Button("搜索", action: submit).disabled(keyword.trimmingCharacters(in: .whitespaces).isEmpty)
      )
    }
    .navigationViewStyle(StackNavigationViewStyle())
  }

  private func submit() {
    model.search(keyword)
  }
}

// MARK: - Shared native views

private struct PiliNativeLoadingView: View {
  let title: String

  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text(title).font(.subheadline).foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct PiliNativeErrorView: View {
  let message: String
  let retry: () -> Void

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 32))
        .foregroundColor(.secondary)
      Text(message)
        .font(.subheadline)
        .multilineTextAlignment(.center)
        .foregroundColor(.secondary)
        .padding(.horizontal, 28)
      Button("重试", action: retry)
        .foregroundColor(piliAccent)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct PiliNativeEmptyView: View {
  let icon: String
  let title: String
  let subtitle: String

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 36))
        .foregroundColor(.secondary)
      Text(title)
        .font(.headline)
      Text(subtitle)
        .font(.subheadline)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct PiliNativeLoggedOutView: View {
  let title: String
  let action: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "person.crop.circle.badge.exclamationmark")
        .font(.system(size: 44))
        .foregroundColor(.secondary)
      Text(title).font(.headline)
      Button("登录", action: action)
        .foregroundColor(.white)
        .padding(.horizontal, 28)
        .padding(.vertical, 9)
        .background(piliAccent)
        .cornerRadius(9)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

// MARK: - Original PiliPlus badges and icons

private enum PiliOriginalIconFamily {
  case material
  case custom

  var name: String {
    switch self {
    case .material: return "MaterialIcons"
    case .custom: return "custom_icon"
    }
  }
}

private enum PiliOriginalIconFont {
  private static let registration: Void = {
    register(asset: "fonts/MaterialIcons-Regular.otf")
    register(asset: "assets/fonts/custom_icon.ttf")
  }()

  static func registerBundledFonts() {
    _ = registration
  }

  private static func register(asset: String) {
    let key = FlutterDartProject.lookupKey(forAsset: asset)
    var candidates = [
      Bundle.main.bundleURL.appendingPathComponent(key),
      Bundle.main.bundleURL.appendingPathComponent("Frameworks/App.framework/\(key)"),
      Bundle.main.bundleURL.appendingPathComponent("Frameworks/App.framework/flutter_assets/\(asset)"),
    ]
    if let path = Bundle.main.path(forResource: key, ofType: nil) {
      candidates.insert(URL(fileURLWithPath: path), at: 0)
    }
    guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
      return
    }
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
  }

  static func image(
    family: PiliOriginalIconFamily,
    codePoint: Int,
    size: CGFloat
  ) -> UIImage? {
    guard
      let scalar = UnicodeScalar(codePoint),
      let font = UIFont(name: family.name, size: size)
    else { return nil }

    let value = String(scalar) as NSString
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: UIColor.black,
    ]
    let bounds = value.boundingRect(
      with: CGSize(width: size * 2, height: size * 2),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: attributes,
      context: nil
    )
    let canvasSize = CGSize(
      width: max(ceil(bounds.width), size),
      height: max(ceil(bounds.height), size)
    )
    let renderer = UIGraphicsImageRenderer(size: canvasSize)
    let image = renderer.image { _ in
      value.draw(
        at: CGPoint(
          x: (canvasSize.width - bounds.width) / 2 - bounds.minX,
          y: (canvasSize.height - bounds.height) / 2 - bounds.minY
        ),
        withAttributes: attributes
      )
    }
    return image.withRenderingMode(.alwaysTemplate)
  }
}

private struct PiliOriginalIcon: View {
  let family: PiliOriginalIconFamily
  let codePoint: Int
  let fallback: String
  let size: CGFloat

  var body: some View {
    Group {
      if let image = PiliOriginalIconFont.image(
        family: family,
        codePoint: codePoint,
        size: size
      ) {
        Image(uiImage: image)
          .renderingMode(.template)
          .resizable()
          .aspectRatio(contentMode: .fit)
      } else {
        Image(systemName: fallback)
          .resizable()
          .aspectRatio(contentMode: .fit)
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

private enum PiliBundledImage {
  private static var cache: [String: UIImage] = [:]

  static func image(asset: String) -> UIImage? {
    if let cached = cache[asset] { return cached }
    let key = FlutterDartProject.lookupKey(forAsset: asset)
    var candidates = [
      Bundle.main.bundleURL.appendingPathComponent(key),
      Bundle.main.bundleURL.appendingPathComponent("Frameworks/App.framework/\(key)"),
      Bundle.main.bundleURL.appendingPathComponent("Frameworks/App.framework/flutter_assets/\(asset)"),
    ]
    if let path = Bundle.main.path(forResource: key, ofType: nil) {
      candidates.insert(URL(fileURLWithPath: path), at: 0)
    }
    guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
          let image = UIImage(contentsOfFile: url.path)?.withRenderingMode(.alwaysOriginal)
    else { return nil }
    cache[asset] = image
    return image
  }
}

private struct PiliOriginalLevelBadge: View {
  let level: Int
  var height: CGFloat = 11

  var body: some View {
    Group {
      if let image = bundledImage {
        Image(uiImage: image)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
      } else {
        Text("LV\(normalizedLevel)")
          .font(.system(size: height * 0.72, weight: .bold, design: .rounded))
          .foregroundColor(.white)
          .padding(.horizontal, 2)
          .background(Color.gray)
          .cornerRadius(2)
      }
    }
    .frame(width: height * 2, height: height)
    .accessibilityLabel(Text("\(normalizedLevel)级"))
  }

  private var normalizedLevel: Int { min(max(level, 0), 6) }

  private var bundledImage: UIImage? {
    PiliBundledImage.image(asset: "assets/images/lv/lv\(normalizedLevel).png")
  }

  private var levelColor: Color {
    switch level {
    case 0, 1: return Color(red: 0.753, green: 0.753, blue: 0.753)
    case 2: return Color(red: 0.545, green: 0.824, blue: 0.608)
    case 3: return Color(red: 0.482, green: 0.804, blue: 0.937)
    case 4: return Color(red: 0.996, green: 0.733, blue: 0.545)
    case 5: return Color(red: 0.933, green: 0.404, blue: 0.165)
    default: return Color(red: 0.941, green: 0.298, blue: 0.286)
    }
  }

  private func levelBackgroundPath() -> Path {
    var path = Path()
    path.addPath(
      roundedPath(
        CGRect(x: 0, y: 48, width: 930, height: 418),
        corners: [.topLeft, .bottomLeft, .bottomRight],
        radius: 27
      )
    )
    path.addPath(
      roundedPath(
        CGRect(x: 576, y: 0, width: 354, height: 49),
        corners: [.topLeft, .topRight],
        radius: 27
      )
    )
    return path
  }

  private func levelForegroundPath() -> Path {
    var path = Path()
    let radius: CGFloat = 20

    // Original PiliPlus "LV" outline.
    path.addPath(roundedPath(CGRect(x: 56, y: 106, width: 67, height: 309), corners: [.topLeft, .topRight, .bottomLeft], radius: radius))
    path.addPath(roundedPath(CGRect(x: 122, y: 347, width: 134, height: 68), corners: [.topRight, .bottomRight], radius: radius))
    path.addPath(roundedPath(CGRect(x: 296, y: 106, width: 67, height: 177), corners: [.topLeft, .topRight], radius: radius))
    path.addPath(roundedPath(CGRect(x: 476, y: 106, width: 67, height: 177), corners: [.topLeft, .topRight], radius: radius))
    var vee = Path()
    vee.move(to: CGPoint(x: 296, y: 282))
    vee.addLine(to: CGPoint(x: 296, y: 292))
    vee.addQuadCurve(to: CGPoint(x: 300, y: 313), control: CGPoint(x: 296, y: 305))
    vee.addLine(to: CGPoint(x: 395, y: 408))
    vee.addQuadCurve(to: CGPoint(x: 444, y: 408), control: CGPoint(x: 420, y: 432))
    vee.addLine(to: CGPoint(x: 539, y: 313))
    vee.addQuadCurve(to: CGPoint(x: 543, y: 292), control: CGPoint(x: 543, y: 305))
    vee.addLine(to: CGPoint(x: 543, y: 282))
    vee.addLine(to: CGPoint(x: 476, y: 282))
    vee.addLine(to: CGPoint(x: 419.5, y: 340))
    vee.addLine(to: CGPoint(x: 363, y: 282))
    vee.closeSubpath()
    path.addPath(vee)

    addDigit(to: &path, digit: level)
    return path
  }

  private func addDigit(to path: inout Path, digit: Int) {
    if digit == 1 {
      path.addPath(roundedPath(CGRect(x: 673, y: 347, width: 160, height: 68), radius: 20))
      path.addPath(roundedPath(CGRect(x: 673, y: 55, width: 114, height: 68), radius: 20))
      path.addRect(CGRect(x: 719, y: 123, width: 68, height: 224))
      return
    }

    let bits: Int
    switch digit {
    case 0: bits = 0x7E
    case 2: bits = 0x6D
    case 3: bits = 0x79
    case 4: bits = 0x33
    case 5: bits = 0x5B
    case 6: bits = 0x5F
    case 7: bits = 0x70
    case 8: bits = 0x7F
    case 9: bits = 0x7B
    default: bits = 0x4F
    }
    if bits & 0x40 != 0 { path.addPath(roundedPath(CGRect(x: 629, y: 55, width: 248, height: 68), radius: 20)) }
    if bits & 0x20 != 0 { path.addPath(roundedPath(CGRect(x: 629, y: 55, width: 68, height: 214), radius: 20)) }
    if bits & 0x10 != 0 { path.addPath(roundedPath(CGRect(x: 810, y: 55, width: 67, height: 214), radius: 20)) }
    if bits & 0x08 != 0 { path.addPath(roundedPath(CGRect(x: 629, y: 347, width: 248, height: 68), radius: 20)) }
    if bits & 0x04 != 0 { path.addPath(roundedPath(CGRect(x: 629, y: 201, width: 68, height: 214), radius: 20)) }
    if bits & 0x02 != 0 { path.addPath(roundedPath(CGRect(x: 810, y: 201, width: 67, height: 214), radius: 20)) }
    if bits & 0x01 != 0 { path.addPath(roundedPath(CGRect(x: 629, y: 201, width: 248, height: 68), radius: 20)) }
  }

  private func roundedPath(
    _ rect: CGRect,
    corners: UIRectCorner = .allCorners,
    radius: CGFloat
  ) -> Path {
    Path(
      UIBezierPath(
        roundedRect: rect,
        byRoundingCorners: corners,
        cornerRadii: CGSize(width: radius, height: radius)
      ).cgPath
    )
  }
}

private final class PiliImageLoader: ObservableObject {
  private static let cache = NSCache<NSURL, UIImage>()
  @Published var image: UIImage?
  private var task: URLSessionDataTask?

  init(urlString: String?) {
    guard let value = urlString, let url = URL(string: value) else { return }
    if let cached = Self.cache.object(forKey: url as NSURL) {
      image = cached
      return
    }
    task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let data = data, let loaded = UIImage(data: data) else { return }
      Self.cache.setObject(loaded, forKey: url as NSURL)
      DispatchQueue.main.async {
        self?.image = loaded
      }
    }
    task?.resume()
  }

  deinit {
    task?.cancel()
  }
}

private struct PiliRemoteImage: View {
  @StateObject private var loader: PiliImageLoader

  init(urlString: String?) {
    _loader = StateObject(wrappedValue: PiliImageLoader(urlString: urlString))
  }

  var body: some View {
    Group {
      if let image = loader.image {
        Image(uiImage: image).resizable()
      } else {
        ZStack {
          Color(UIColor.tertiarySystemFill)
          Image(systemName: "photo")
            .foregroundColor(Color(UIColor.tertiaryLabel))
        }
      }
    }
  }
}

// MARK: - Flutter codec helpers

private func piliDictionary(_ value: Any?) -> [String: Any] {
  if let dictionary = value as? [String: Any] { return dictionary }
  guard let dictionary = value as? NSDictionary else { return [:] }
  var result: [String: Any] = [:]
  dictionary.forEach { key, value in
    if let key = key as? String { result[key] = value }
  }
  return result
}

private func piliString(_ value: Any?) -> String? {
  if value is NSNull || value == nil { return nil }
  if let value = value as? String, !value.isEmpty { return value }
  return nil
}

private func piliOptionalInt(_ value: Any?) -> Int? {
  if value is NSNull || value == nil { return nil }
  if let value = value as? NSNumber { return value.intValue }
  if let value = value as? String { return Int(value) }
  return nil
}

private func piliInt(_ value: Any?) -> Int {
  piliOptionalInt(value) ?? 0
}

private func piliDouble(_ value: Any?) -> Double {
  if let value = value as? NSNumber { return value.doubleValue }
  if let value = value as? String { return Double(value) ?? 0 }
  return 0
}

private func piliOptionalDouble(_ value: Any?) -> Double? {
  if value is NSNull || value == nil { return nil }
  if let value = value as? NSNumber { return value.doubleValue }
  if let value = value as? String { return Double(value) }
  return nil
}

private func piliBool(_ value: Any?) -> Bool {
  if let value = value as? Bool { return value }
  if let value = value as? NSNumber { return value.boolValue }
  if let value = value as? String { return value == "true" || value == "1" }
  return false
}

private func piliCompactNumber(_ value: Int) -> String {
  if value >= 100_000_000 {
    return String(format: "%.1f亿", Double(value) / 100_000_000)
  }
  if value >= 10_000 {
    return String(format: "%.1f万", Double(value) / 10_000)
  }
  return String(value)
}
