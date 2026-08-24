import Combine
import CoreImage.CIFilterBuiltins
import Flutter
import SwiftUI
import UIKit

private let piliNativeChannelName = "piliglass/native_ui"
private let piliAccent = Color(red: 0.93, green: 0.29, blue: 0.48)

private extension Notification.Name {
  static let piliPresentNativeProfile = Notification.Name("piliglass.presentNativeProfile")
}

// MARK: - Native container

/// Hosts a fully native SwiftUI root interface over the original Flutter root.
///
/// Dart remains alive underneath as the request and playback engine. Every
/// non-player destination owned by this controller is rendered natively.
final class PiliNativeRootViewController: UIViewController {
  private let flutterViewController: FlutterViewController
  private lazy var channel = FlutterMethodChannel(
    name: piliNativeChannelName,
    binaryMessenger: flutterViewController.binaryMessenger
  )
  private lazy var model = PiliNativeViewModel(channel: channel)
  private var hostingController: UIHostingController<PiliNativeRootView>?
  private var isNativeRootVisible = true

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
    view.backgroundColor = .systemBackground
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

  private func installFlutterSurface() {
    addChild(flutterViewController)
    let flutterView = flutterViewController.view!
    flutterView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(flutterView)
    NSLayoutConstraint.activate([
      flutterView.topAnchor.constraint(equalTo: view.topAnchor),
      flutterView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      flutterView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      flutterView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    flutterViewController.didMove(toParent: self)
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
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func setNativeRootVisible(_ visible: Bool) {
    guard visible != isNativeRootVisible else { return }
    isNativeRootVisible = visible
    hostingController?.view.isHidden = !visible
    flutterViewController.view.isHidden = visible
    setNeedsStatusBarAppearanceUpdate()
  }
}

// MARK: - View model and channel models

private final class PiliNativeViewModel: ObservableObject {
  @Published private(set) var tabTitles = ["首页", "动态", "我的"]
  @Published private(set) var selectedIndex = 0
  @Published private(set) var dynamicBadge = ""

  @Published private(set) var homeVideos: [PiliNativeVideo] = []
  @Published private(set) var homeLoading = true
  @Published private(set) var homeError: String?
  @Published private(set) var homeLoadingMore = false

  @Published private(set) var dynamics: [PiliNativeDynamic] = []
  @Published private(set) var dynamicsLoading = true
  @Published private(set) var dynamicsError: String?
  @Published private(set) var dynamicsLoadingMore = false

  @Published private(set) var account = PiliNativeAccount()
  @Published var isSearchPresented = false
  @Published private(set) var searchResults: [PiliNativeVideo] = []
  @Published private(set) var searchLoading = false
  @Published private(set) var searchError: String?

  @Published var isVideoDetailPresented = false
  @Published private(set) var videoDetail: PiliNativeVideoDetail?
  @Published private(set) var videoDetailLoading = false
  @Published private(set) var videoDetailError: String?
  @Published private(set) var videoActionLoading = false
  @Published private(set) var videoActionMessage: String?

  @Published var isSettingsPresented = false
  @Published private(set) var settings: [PiliNativeSetting] = []
  @Published private(set) var settingsLoading = false
  @Published private(set) var settingsError: String?

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
  @Published private(set) var profileError: String?
  @Published private(set) var profileActionLoading = false
  @Published private(set) var profileMessage: String?

  @Published var isDynamicDetailPresented = false
  @Published private(set) var selectedDynamic: PiliNativeDynamic?

  @Published var isMessagesPresented = false
  @Published private(set) var messageKind = "reply"
  @Published private(set) var messages: [PiliNativeMessage] = []
  @Published private(set) var messagesLoading = false
  @Published private(set) var messagesError: String?

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
  @Published private(set) var commentsError: String?
  @Published private(set) var commentsTotal = 0

  private let channel: FlutterMethodChannel
  private var snapshotInFlight = false
  private var pendingVideo: PiliNativeVideo?
  private var libraryPage = 1
  private var libraryMediaID: Int?
  private var libraryNextMax: Int?
  private var libraryNextViewAt: Int?
  private var libraryParentKind: String?
  private var libraryParentTitle: String?
  private var profileMID: Int?
  private var commentOID: Int?
  private var commentType = 1

  init(channel: FlutterMethodChannel) {
    self.channel = channel
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

  func openVideo(_ video: PiliNativeVideo) {
    pendingVideo = video
    videoDetail = nil
    videoDetailError = nil
    videoDetailLoading = true
    videoActionLoading = false
    videoActionMessage = nil
    isVideoDetailPresented = true

    var arguments: [String: Any] = [:]
    if let bvid = video.bvid { arguments["bvid"] = bvid }
    if let aid = video.aid { arguments["aid"] = aid }
    arguments["title"] = video.title
    if let cover = video.cover { arguments["cover"] = cover }
    channel.invokeMethod("loadVideoDetail", arguments: arguments) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.videoDetailLoading = false
        if let error = response as? FlutterError {
          self.videoDetailError = error.message ?? "视频简介加载失败"
          return
        }
        let result = piliDictionary(response)
        guard result["state"] as? String == "success" else {
          self.videoDetailError = result["error"] as? String ?? "视频简介加载失败"
          return
        }
        let detail = PiliNativeVideoDetail(map: piliDictionary(result["video"]))
        self.videoDetail = detail
        if let aid = detail.aid {
          self.loadComments(oid: aid, type: 1)
        }
      }
    }
  }

  func retryVideoDetail() {
    guard let video = pendingVideo else { return }
    openVideo(video)
  }

  func playVideo(_ video: PiliNativeVideoDetail, part: Int? = nil) {
    isVideoDetailPresented = false
    var arguments: [String: Any] = ["bvid": video.bvid]
    if let aid = video.aid { arguments["aid"] = aid }
    if let part = part { arguments["part"] = part }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [channel = self.channel] in
      channel.invokeMethod("playVideo", arguments: arguments)
    }
  }

  func openVideoOwner(_ video: PiliNativeVideoDetail) {
    guard let ownerID = video.ownerID else { return }
    openVideoMember(ownerID)
  }

  func openVideoMember(_ memberID: Int) {
    isVideoDetailPresented = false
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
      arguments: ["action": action, "bvid": video.bvid]
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
        self.videoActionMessage = result["message"] as? String ?? "操作成功"
      }
    }
  }

  func copyVideoID(_ video: PiliNativeVideoDetail) {
    UIPasteboard.general.string = video.bvid
    videoActionMessage = "已复制 \(video.bvid)"
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
        let rows = result["items"] as? [Any] ?? []
        self.settings = rows.enumerated().map {
          PiliNativeSetting(map: piliDictionary($0.element), index: $0.offset)
        }
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
          let rows = result["items"] as? [Any] ?? []
          self.settings = rows.enumerated().map {
            PiliNativeSetting(map: piliDictionary($0.element), index: $0.offset)
          }
        } else {
          self.settingsError = result["error"] as? String ?? "设置保存失败"
          self.loadSettings()
        }
      }
    }
  }

  func openDynamic(_ item: PiliNativeDynamic) {
    selectedDynamic = item
    isDynamicDetailPresented = true
    if let oid = item.commentOID {
      loadComments(oid: oid, type: item.commentType ?? 17)
    } else {
      comments = []
      commentsTotal = item.comment
      commentsError = "该动态没有可用的评论编号"
    }
  }

  func openRoute(_ route: String, parameters: [String: String] = [:]) {
    switch route {
    case "/loginPage":
      presentNativeLogin()
    case "/whisper", "/myReply":
      presentMessages()
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

  func search(_ keyword: String) {
    let value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    searchLoading = true
    searchError = nil
    channel.invokeMethod(
      "searchVideos",
      arguments: ["keyword": value, "page": 1]
    ) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.searchLoading = false
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
        self.searchResults = rows.enumerated().map {
          PiliNativeVideo(map: piliDictionary($0.element), index: $0.offset)
        }
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

  func presentMessages() {
    isMessagesPresented = true
    messageKind = "reply"
    loadMessages(kind: "reply")
  }

  func loadMessages(kind: String? = nil) {
    if let kind = kind { messageKind = kind }
    messagesLoading = true
    messagesError = nil
    channel.invokeMethod(
      "loadNativeMessages",
      arguments: ["kind": messageKind]
    ) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.messagesLoading = false
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
        self.messages = rows.enumerated().map {
          PiliNativeMessage(map: piliDictionary($0.element), index: $0.offset)
        }
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

  func loadComments(oid: Int, type: Int) {
    commentOID = oid
    commentType = type
    comments = []
    commentsError = nil
    commentsTotal = 0
    commentsLoading = true
    channel.invokeMethod(
      "loadNativeComments",
      arguments: ["oid": oid, "type": type, "page": 1]
    ) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self else { return }
        guard self.commentOID == oid, self.commentType == type else { return }
        self.commentsLoading = false
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
        self.comments = rows.enumerated().map {
          PiliNativeComment(map: piliDictionary($0.element), index: $0.offset)
        }
        self.commentsTotal = piliInt(result["total"])
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
        guard let currentIndex = self.comments.firstIndex(where: { $0.id == comment.id }) else { return }
        let nowLiked = piliBool(result["liked"])
        self.comments[currentIndex].liked = nowLiked
        self.comments[currentIndex].like = max(0, self.comments[currentIndex].like + (nowLiked ? 1 : -1))
      }
    }
  }

  func openCommentMember(_ comment: PiliNativeComment) {
    guard let memberID = comment.memberID else { return }
    if isDynamicDetailPresented { isDynamicDetailPresented = false }
    if isVideoDetailPresented { isVideoDetailPresented = false }
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
  let reply: Int
  let like: Int
  let coin: Int
  let favorite: Int
  let share: Int
  let copyrightText: String
  let isVertical: Bool
  let argueMessage: String
  let collectionTitle: String
  let collectionCount: Int
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
    copyrightText = piliString(map["copyrightText"]) ?? ""
    isVertical = piliBool(map["isVertical"])
    argueMessage = piliString(map["argueMessage"]) ?? ""
    collectionTitle = piliString(map["collectionTitle"]) ?? ""
    collectionCount = piliInt(map["collectionCount"])
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
  let aid: Int?
  let bvid: String?
  let commentOID: Int?
  let commentType: Int?
  let like: Int
  let comment: Int
  let forward: Int

  init(map: [String: Any], index: Int) {
    sourceID = piliString(map["id"]) ?? "dynamic"
    id = "\(sourceID)-\(index)"
    authorID = piliOptionalInt(map["authorId"])
    author = piliString(map["author"]) ?? ""
    avatar = piliString(map["avatar"])
    time = piliString(map["time"]) ?? ""
    title = piliString(map["title"]) ?? ""
    body = piliString(map["body"]) ?? ""
    cover = piliString(map["cover"])
    aid = piliOptionalInt(map["aid"])
    bvid = piliString(map["bvid"])
    commentOID = piliOptionalInt(map["commentOid"])
    commentType = piliOptionalInt(map["commentType"])
    like = piliInt(map["like"])
    comment = piliInt(map["comment"])
    forward = piliInt(map["forward"])
  }
}

private struct PiliNativeMessage: Identifiable {
  let id: String
  let memberID: Int?
  let author: String
  let avatar: String?
  let body: String
  let context: String
  let cover: String?
  let time: String
  let badge: String

  init(map: [String: Any], index: Int) {
    id = piliString(map["id"]) ?? "message-\(index)"
    memberID = piliOptionalInt(map["memberId"])
    author = piliString(map["author"]) ?? "消息"
    avatar = piliString(map["avatar"])
    body = piliString(map["body"]) ?? ""
    context = piliString(map["context"]) ?? ""
    cover = piliString(map["cover"])
    time = piliString(map["time"]) ?? ""
    badge = piliString(map["badge"]) ?? ""
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
  let pictures: [String]

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
    pictures = (map["pictures"] as? [Any])?.compactMap { piliString($0) } ?? []
  }
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
  let videoCount: Int
  let tags: [String]
  let videos: [PiliNativeVideo]

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
            Image(systemName: symbol(for: item.element, selected: model.selectedIndex == item.offset))
            Text(tabLabel(for: item.element))
          }
          .tag(item.offset)
      }
    }
    .accentColor(piliAccent)
    .sheet(isPresented: $model.isSearchPresented) {
      PiliNativeSearchView(model: model)
    }
    .sheet(isPresented: $model.isSettingsPresented) {
      PiliNativeSettingsView(model: model)
    }
    .sheet(isPresented: $model.isLibraryPresented) {
      PiliNativeLibraryView(model: model)
    }
    .sheet(isPresented: $model.isMessagesPresented) {
      PiliNativeMessagesView(model: model)
    }
    .sheet(isPresented: $model.isDownloadsPresented) {
      PiliNativeDownloadsView(model: model)
    }
    .fullScreenCover(isPresented: $model.isVideoDetailPresented) {
      PiliNativeVideoDetailView(model: model)
    }
    .fullScreenCover(isPresented: $model.isProfilePresented) {
      PiliNativeProfileView(model: model)
    }
    .fullScreenCover(isPresented: $model.isDynamicDetailPresented) {
      PiliNativeDynamicDetailView(model: model)
    }
    .fullScreenCover(isPresented: $model.isLoginPresented) {
      PiliNativeLoginView(model: model)
    }
    .onAppear {
      model.requestSnapshot()
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

  private func symbol(for title: String, selected: Bool) -> String {
    if title.contains("动态") { return selected ? "sparkles" : "sparkles" }
    if title.contains("我") || title.contains("账号") {
      return selected ? "person.crop.circle.fill" : "person.crop.circle"
    }
    return selected ? "house.fill" : "house"
  }

  private func tabLabel(for title: String) -> String {
    if title.contains("动态") && !model.dynamicBadge.isEmpty {
      return "\(title) \(model.dynamicBadge)"
    }
    return title
  }
}

private struct PiliNativeHomeView: View {
  @ObservedObject var model: PiliNativeViewModel
  private let columns = [GridItem(.adaptive(minimum: 155), spacing: 12)]

  var body: some View {
    NavigationView {
      Group {
        if model.homeLoading && model.homeVideos.isEmpty {
          PiliNativeLoadingView(title: "正在加载推荐")
        } else if let error = model.homeError, model.homeVideos.isEmpty {
          PiliNativeErrorView(message: error) { model.refresh("home") }
        } else {
          ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
              ForEach(model.homeVideos) { video in
                PiliNativeVideoCard(video: video) {
                  model.openVideo(video)
                }
                .onAppear {
                  if video.id == model.homeVideos.last?.id {
                    model.loadMore("home")
                  }
                }
              }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            if model.homeLoadingMore {
              ProgressView().padding(.vertical, 20)
            } else {
              Color.clear.frame(height: 24)
            }
          }
          .background(Color(UIColor.systemGroupedBackground))
        }
      }
      .navigationBarTitle("PiliGlass", displayMode: .inline)
      .navigationBarItems(
        leading: Button(action: { model.isSearchPresented = true }) {
          Image(systemName: "magnifyingglass")
        }
        .accessibilityLabel("搜索"),
        trailing: HStack(spacing: 18) {
          if model.account.isLogin {
            Button(action: { model.openRoute("/whisper") }) {
              Image(systemName: "bell")
            }
            .accessibilityLabel("消息")
          }
          Button(action: { selectMine() }) {
            if let face = model.account.face {
              PiliRemoteImage(urlString: face)
                .frame(width: 28, height: 28)
                .clipShape(Circle())
            } else {
              Image(systemName: "person.crop.circle")
            }
          }
          .accessibilityLabel("我的")
          Button(action: { model.refresh("home") }) {
            Image(systemName: "arrow.clockwise")
          }
          .accessibilityLabel("刷新")
        }
      )
    }
    .navigationViewStyle(StackNavigationViewStyle())
  }

  private func selectMine() {
    if let index = model.tabTitles.firstIndex(where: { $0.contains("我") || $0.contains("账号") }) {
      model.userSelectedTab(index)
    }
  }
}

private struct PiliNativeVideoCard: View {
  let video: PiliNativeVideo
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 7) {
        ZStack(alignment: .bottomTrailing) {
          PiliRemoteImage(urlString: video.cover)
            .aspectRatio(16 / 9, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .clipped()
            .background(Color(UIColor.tertiarySystemFill))
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
        .cornerRadius(9)

        Text(video.title)
          .font(.subheadline)
          .fontWeight(.medium)
          .foregroundColor(.primary)
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)

        HStack(spacing: 4) {
          Image(systemName: "person")
          Text(video.owner)
            .lineLimit(1)
          Spacer(minLength: 4)
          if !video.viewText.isEmpty {
            Image(systemName: "play.rectangle")
            Text(video.viewText)
          }
        }
        .font(.caption2)
        .foregroundColor(.secondary)
      }
    }
    .buttonStyle(PlainButtonStyle())
    .accessibilityLabel("\(video.title)，\(video.owner)")
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
        }
      }
      .navigationBarTitle("动态", displayMode: .inline)
      .navigationBarItems(
        leading: Button(action: { model.isSearchPresented = true }) {
          Image(systemName: "magnifyingglass")
        },
        trailing: Button(action: { model.refresh("dynamics") }) {
          Image(systemName: "arrow.clockwise")
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
          if let cover = item.cover {
            PiliRemoteImage(urlString: cover)
              .aspectRatio(16 / 9, contentMode: .fill)
              .frame(maxWidth: .infinity)
              .frame(maxHeight: 190)
              .clipped()
              .cornerRadius(9)
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

private struct PiliNativeStat: View {
  let icon: String
  let count: Int

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: icon)
      Text(count > 0 ? String(count) : "")
    }
    .font(.caption)
    .foregroundColor(.secondary)
  }
}

private struct PiliNativeMineView: View {
  @ObservedObject var model: PiliNativeViewModel

  private let actions: [(String, String, String, Bool)] = [
    ("离线缓存", "arrow.down.circle", "/download", false),
    ("观看记录", "clock.arrow.circlepath", "/history", true),
    ("我的收藏", "star", "/fav", true),
    ("稍后再看", "clock", "/later", true),
    ("我的订阅", "rectangle.stack", "/subscription", true),
    ("消息中心", "bell", "/whisper", true),
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
                    Text("LV\(model.account.level)")
                      .font(.caption2)
                      .foregroundColor(.white)
                      .padding(.horizontal, 5)
                      .padding(.vertical, 2)
                      .background(piliAccent)
                      .cornerRadius(4)
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
            Button(action: { openService(item.2, protected: item.3) }) {
              HStack(spacing: 14) {
                Image(systemName: item.1)
                  .frame(width: 24)
                  .foregroundColor(piliAccent)
                Text(item.0).foregroundColor(.primary)
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
      .navigationBarTitle("我的", displayMode: .inline)
      .navigationBarItems(
        leading: Button(action: { model.isSearchPresented = true }) {
          Image(systemName: "magnifyingglass")
        },
        trailing: Button(action: { model.refresh("mine") }) {
          Image(systemName: "arrow.clockwise")
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
  private let columns = [GridItem(.adaptive(minimum: 155), spacing: 12)]

  var body: some View {
    NavigationView {
      Group {
        if model.profileLoading && model.profile == nil {
          PiliNativeLoadingView(title: "正在加载个人空间")
        } else if let error = model.profileError, model.profile == nil {
          PiliNativeErrorView(message: error, retry: model.loadProfile)
        } else if let profile = model.profile {
          ScrollView {
            VStack(alignment: .leading, spacing: 0) {
              profileHeader(profile)
              profileInformation(profile)
              profileVideos(profile)
            }
          }
          .background(Color(UIColor.systemGroupedBackground))
        } else {
          PiliNativeErrorView(message: "暂无个人资料", retry: model.loadProfile)
        }
      }
      .navigationBarTitle(model.profile?.name ?? "个人空间", displayMode: .inline)
      .navigationBarItems(
        leading: Button("关闭") { presentationMode.wrappedValue.dismiss() },
        trailing: Menu {
          Button(action: model.loadProfile) {
            Label("刷新", systemImage: "arrow.clockwise")
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
      )
    }
    .navigationViewStyle(StackNavigationViewStyle())
  }

  private func profileHeader(_ profile: PiliNativeProfile) -> some View {
    ZStack(alignment: .bottomLeading) {
      PiliRemoteImage(urlString: profile.topImage)
        .aspectRatio(3 / 1, contentMode: .fill)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 126, maxHeight: 170)
        .clipped()
        .overlay(
          LinearGradient(
            colors: [.clear, .black.opacity(0.28)],
            startPoint: .top,
            endPoint: .bottom
          )
        )
      PiliRemoteImage(urlString: profile.face)
        .frame(width: 78, height: 78)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color(UIColor.systemBackground), lineWidth: 4))
        .padding(.leading, 16)
        .offset(y: 33)
    }
    .padding(.bottom, 38)
  }

  private func profileInformation(_ profile: PiliNativeProfile) -> some View {
    VStack(alignment: .leading, spacing: 13) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 7) {
            Text(profile.name)
              .font(.title3)
              .fontWeight(.bold)
              .foregroundColor(profile.vip ? piliAccent : .primary)
            Text("LV\(profile.level)")
              .font(.caption2)
              .foregroundColor(.white)
              .padding(.horizontal, 5)
              .padding(.vertical, 2)
              .background(piliAccent)
              .cornerRadius(4)
          }
          Text("UID \(profile.mid)")
            .font(.caption)
            .foregroundColor(.secondary)
        }
        Spacer()
        if profile.isSelf {
          Button("刷新资料", action: model.loadProfile)
            .buttonStyle(.bordered)
        } else {
          Button(
            profile.isFollowing ? "已关注" : "关注",
            action: model.toggleProfileFollow
          )
          .buttonStyle(.borderedProminent)
          .tint(profile.isFollowing ? Color.secondary : piliAccent)
          .disabled(model.profileActionLoading)
        }
      }

      HStack {
        PiliNativeAccountStat(value: profile.following, title: "关注", action: {})
        Spacer()
        PiliNativeAccountStat(value: profile.followers, title: "粉丝", action: {})
        Spacer()
        PiliNativeAccountStat(value: profile.likes, title: "获赞", action: {})
      }
      .padding(.horizontal, 18)

      if let message = model.profileMessage {
        Text(message)
          .font(.caption)
          .foregroundColor(.secondary)
      }

      if !profile.official.isEmpty {
        Label(profile.official, systemImage: "checkmark.seal.fill")
          .font(.caption)
          .foregroundColor(piliAccent)
      }

      Text(profile.sign.isEmpty ? "这个人很神秘，什么都没有写" : profile.sign)
        .font(.subheadline)
        .foregroundColor(.secondary)
        .textSelection(.enabled)

      if !profile.tags.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(profile.tags, id: \.self) { tag in
              Text(tag)
                .font(.caption)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(Capsule())
            }
          }
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 16)
    .background(Color(UIColor.systemBackground))
  }

  private func profileVideos(_ profile: PiliNativeProfile) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("投稿视频")
          .font(.headline)
        Text("\(profile.videoCount)")
          .font(.caption)
          .foregroundColor(.secondary)
        Spacer()
        Button("刷新", action: model.loadProfile)
          .font(.caption)
      }

      if profile.videos.isEmpty {
        Text("暂无公开视频")
          .font(.subheadline)
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity, minHeight: 90)
      } else {
        LazyVGrid(columns: columns, spacing: 14) {
          ForEach(profile.videos) { video in
            PiliNativeVideoCard(video: video) {
              model.openProfileVideo(video)
            }
          }
        }
      }
    }
    .padding(14)
    .padding(.bottom, 24)
  }
}

// MARK: - Native video introduction

private struct PiliNativeVideoDetailView: View {
  @ObservedObject var model: PiliNativeViewModel
  @Environment(\.presentationMode) private var presentationMode
  @State private var selectedPart = 1
  @State private var descriptionExpanded = false

  var body: some View {
    NavigationView {
      Group {
        if model.videoDetailLoading && model.videoDetail == nil {
          PiliNativeLoadingView(title: "正在加载视频简介")
        } else if let error = model.videoDetailError, model.videoDetail == nil {
          PiliNativeErrorView(message: error, retry: model.retryVideoDetail)
        } else if let video = model.videoDetail {
          ScrollView {
            VStack(alignment: .leading, spacing: 0) {
              videoHeader(video)
              videoInformation(video)
            }
          }
          .background(Color(UIColor.systemGroupedBackground))
        } else {
          PiliNativeErrorView(message: "没有可显示的视频信息", retry: model.retryVideoDetail)
        }
      }
      .navigationBarTitle("视频详情", displayMode: .inline)
      .navigationBarItems(
        leading: Button("关闭") {
          model.isVideoDetailPresented = false
          presentationMode.wrappedValue.dismiss()
        }
      )
    }
    .navigationViewStyle(StackNavigationViewStyle())
  }

  private func videoHeader(_ video: PiliNativeVideoDetail) -> some View {
    let currentPart = video.pages.first(where: { $0.index == selectedPart })
    return ZStack {
      Color.black
      PiliRemoteImage(urlString: currentPart?.cover ?? video.cover)
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)

      Button(action: { model.playVideo(video, part: selectedPart) }) {
        ZStack {
          Circle()
            .fill(Color.black.opacity(0.58))
            .frame(width: 68, height: 68)
          Image(systemName: "play.fill")
            .font(.system(size: 28, weight: .semibold))
            .foregroundColor(.white)
            .offset(x: 2)
        }
      }
      .accessibilityLabel("播放视频")

      if !(currentPart?.durationText ?? video.durationText).isEmpty {
        VStack {
          Spacer()
          HStack {
            Spacer()
            Text(currentPart?.durationText ?? video.durationText)
              .font(.caption)
              .foregroundColor(.white)
              .padding(.horizontal, 7)
              .padding(.vertical, 4)
              .background(Color.black.opacity(0.68))
              .cornerRadius(5)
              .padding(10)
          }
        }
      }
    }
    .aspectRatio(16 / 9, contentMode: .fit)
  }

  private func videoInformation(_ video: PiliNativeVideoDetail) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(video.title)
        .font(.title3)
        .fontWeight(.semibold)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 8) {
        if !video.copyrightText.isEmpty {
          Label(video.copyrightText, systemImage: "checkmark.seal")
        }
        if video.isVertical {
          Label("竖屏", systemImage: "rectangle.portrait")
        }
        if video.pages.count > 1 {
          Label("\(video.pages.count)P", systemImage: "list.number")
        }
      }
      .font(.caption)
      .foregroundColor(piliAccent)

      HStack(spacing: 12) {
        if !video.viewText.isEmpty {
          Label("\(video.viewText) 播放", systemImage: "play.rectangle")
        }
        if !video.danmakuText.isEmpty {
          Label("\(video.danmakuText) 弹幕", systemImage: "text.bubble")
        }
        Spacer(minLength: 0)
      }
      .font(.caption)
      .foregroundColor(.secondary)

      if !video.pubdateText.isEmpty || !video.bvid.isEmpty {
        Text([video.pubdateText, video.bvid].filter { !$0.isEmpty }.joined(separator: "  "))
          .font(.caption)
          .foregroundColor(.secondary)
      }

      if !video.argueMessage.isEmpty {
        Label(video.argueMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.subheadline)
          .foregroundColor(.orange)
          .padding(11)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Color.orange.opacity(0.12))
          .cornerRadius(10)
      }

      Button(action: { model.openVideoOwner(video) }) {
        HStack(spacing: 11) {
          PiliRemoteImage(urlString: video.ownerFace)
            .frame(width: 42, height: 42)
            .clipShape(Circle())
          VStack(alignment: .leading, spacing: 3) {
            Text(video.owner.isEmpty ? "UP 主" : video.owner)
              .font(.subheadline)
              .fontWeight(.semibold)
              .foregroundColor(.primary)
            Text("查看主页")
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

      if !video.staff.isEmpty {
        VStack(alignment: .leading, spacing: 9) {
          Text("联合创作")
            .font(.headline)
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
              ForEach(video.staff) { member in
                Button(action: {
                  if let memberID = member.memberID {
                    model.openVideoMember(memberID)
                  }
                }) {
                  HStack(spacing: 8) {
                    PiliRemoteImage(urlString: member.face)
                      .frame(width: 34, height: 34)
                      .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                      Text(member.name)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                      if !member.title.isEmpty {
                        Text(member.title)
                          .font(.caption2)
                          .foregroundColor(.secondary)
                      }
                    }
                  }
                  .padding(.horizontal, 10)
                  .padding(.vertical, 7)
                  .background(Color(UIColor.secondarySystemGroupedBackground))
                  .cornerRadius(10)
                }
                .buttonStyle(PlainButtonStyle())
              }
            }
          }
        }
      }

      HStack(spacing: 0) {
        PiliNativeVideoMetric(icon: "hand.thumbsup", value: video.like, title: "点赞")
        PiliNativeVideoMetric(icon: "dollarsign.circle", value: video.coin, title: "投币")
        PiliNativeVideoMetric(icon: "star", value: video.favorite, title: "收藏")
        PiliNativeVideoMetric(icon: "bubble.left", value: video.reply, title: "评论")
        PiliNativeVideoMetric(icon: "square.and.arrow.up", value: video.share, title: "分享")
      }
      .padding(.vertical, 4)

      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 2),
        spacing: 9
      ) {
        PiliNativeVideoActionButton(
          title: "一键三连",
          icon: "hand.thumbsup.fill",
          action: { model.performVideoAction("triple", video: video) }
        )
        PiliNativeVideoActionButton(
          title: "稍后再看",
          icon: "clock.badge.plus",
          action: { model.performVideoAction("later", video: video) }
        )
        PiliNativeVideoActionButton(
          title: "复制 BV 号",
          icon: "doc.on.doc",
          action: { model.copyVideoID(video) }
        )
        PiliNativeVideoActionButton(
          title: "完整详情",
          icon: "arrow.up.right.square",
          action: { model.playVideo(video, part: selectedPart) }
        )
      }
      .disabled(model.videoActionLoading)

      if model.videoActionLoading {
        HStack(spacing: 8) {
          ProgressView()
          Text("正在处理…")
        }
        .font(.caption)
        .foregroundColor(.secondary)
      } else if let message = model.videoActionMessage {
        Text(message)
          .font(.caption)
          .foregroundColor(message.contains("失败") || message.contains("登录") ? .red : piliAccent)
      }

      Divider()

      if !video.description.isEmpty {
        VStack(alignment: .leading, spacing: 7) {
          HStack {
            Text("简介").font(.headline)
            Spacer()
            Button(descriptionExpanded ? "收起" : "展开") {
              descriptionExpanded.toggle()
            }
            .font(.caption)
            .foregroundColor(piliAccent)
          }
          Text(video.description)
            .font(.subheadline)
            .foregroundColor(.secondary)
            .lineLimit(descriptionExpanded ? nil : 4)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      if video.pages.count > 1 {
        Divider()
        Text("分集与分 P")
          .font(.headline)
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 9) {
            ForEach(video.pages) { part in
              Button(action: { selectedPart = part.index }) {
                VStack(alignment: .leading, spacing: 4) {
                  Text("P\(part.index)  \(part.title)")
                    .font(.subheadline)
                    .lineLimit(1)
                  if !part.durationText.isEmpty {
                    Text(part.durationText).font(.caption2)
                  }
                }
                .foregroundColor(selectedPart == part.index ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(width: 176, alignment: .leading)
                .background(selectedPart == part.index ? piliAccent : Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(9)
              }
              .buttonStyle(PlainButtonStyle())
            }
          }
        }
      }

      if !video.collectionTitle.isEmpty {
        Divider()
        HStack(spacing: 11) {
          Image(systemName: "rectangle.stack.fill")
            .font(.title2)
            .foregroundColor(piliAccent)
          VStack(alignment: .leading, spacing: 3) {
            Text(video.collectionTitle)
              .font(.headline)
            if video.collectionCount > 0 {
              Text("合集共 \(video.collectionCount) 个视频")
                .font(.caption)
                .foregroundColor(.secondary)
            }
          }
          Spacer()
        }
        .padding(12)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(11)
      }

      if !video.tags.isEmpty {
        Divider()
        Text("标签")
          .font(.headline)
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(video.tags) { tag in
              Text("# \(tag.name)")
                .font(.subheadline)
                .foregroundColor(piliAccent)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(piliAccent.opacity(0.1))
                .cornerRadius(16)
            }
          }
        }
      }

      Divider()
      PiliNativeCommentsSection(model: model)

      Button(action: { model.playVideo(video, part: selectedPart) }) {
        Label("使用完整播放器播放", systemImage: "play.fill")
          .font(.headline)
          .foregroundColor(.white)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 13)
          .background(piliAccent)
          .cornerRadius(11)
      }
      .buttonStyle(PlainButtonStyle())

    }
    .padding(16)
    .background(Color(UIColor.systemBackground))
  }
}

private struct PiliNativeVideoMetric: View {
  let icon: String
  let value: Int
  let title: String

  var body: some View {
    VStack(spacing: 5) {
      Image(systemName: icon).font(.title3)
      Text(value > 0 ? piliCompactNumber(value) : title)
        .font(.caption)
        .lineLimit(1)
    }
    .foregroundColor(.secondary)
    .frame(maxWidth: .infinity)
  }
}

private struct PiliNativeVideoActionButton: View {
  let title: String
  let icon: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: icon)
        .font(.subheadline)
        .foregroundColor(.primary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(10)
    }
    .buttonStyle(PlainButtonStyle())
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
              if let cover = item.cover {
                PiliRemoteImage(urlString: cover)
                  .aspectRatio(16 / 9, contentMode: .fill)
                  .frame(maxWidth: .infinity)
                  .clipped()
                  .cornerRadius(12)
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

              HStack {
                PiliNativeStat(icon: "arrowshape.turn.up.right", count: item.forward)
                Spacer()
                PiliNativeStat(icon: "bubble.left", count: item.comment)
                Spacer()
                PiliNativeStat(icon: "hand.thumbsup", count: item.like)
              }
              .padding(.horizontal, 22)
              .padding(.vertical, 12)
              .background(Color(UIColor.secondarySystemGroupedBackground))
              .cornerRadius(11)

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
  }
}

private struct PiliNativeCommentsSection: View {
  @ObservedObject var model: PiliNativeViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      HStack {
        Text("评论")
          .font(.headline)
        if model.commentsTotal > 0 {
          Text(String(model.commentsTotal))
            .font(.caption)
            .foregroundColor(.secondary)
        }
        Spacer()
      }

      if model.commentsLoading {
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
            toggleLike: { model.toggleCommentLike(comment) }
          )
          if comment.id != model.comments.last?.id {
            Divider().padding(.leading, 50)
          }
        }
      }
    }
  }
}

private struct PiliNativeCommentRow: View {
  let comment: PiliNativeComment
  let openMember: () -> Void
  let toggleLike: () -> Void

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
            Text("LV\(comment.level)")
              .font(.caption2)
              .foregroundColor(piliAccent)
          }
          Spacer()
          Button(action: toggleLike) {
            Label(comment.like > 0 ? String(comment.like) : "", systemImage: comment.liked ? "hand.thumbsup.fill" : "hand.thumbsup")
              .font(.caption)
              .foregroundColor(comment.liked ? piliAccent : .secondary)
          }
          .buttonStyle(PlainButtonStyle())
        }

        Text(comment.message)
          .font(.subheadline)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)

        if !comment.pictures.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
              ForEach(comment.pictures, id: \.self) { picture in
                PiliRemoteImage(urlString: picture)
                  .frame(width: 108, height: 108)
                  .clipped()
                  .cornerRadius(8)
              }
            }
          }
        }

        HStack(spacing: 8) {
          Text(comment.time)
          if !comment.location.isEmpty { Text(comment.location) }
          if comment.replyCount > 0 { Text("\(comment.replyCount) 条回复") }
        }
        .font(.caption2)
        .foregroundColor(.secondary)
      }
    }
    .padding(.vertical, 4)
  }
}

// MARK: - Native messages

private struct PiliNativeMessagesView: View {
  @ObservedObject var model: PiliNativeViewModel
  @Environment(\.presentationMode) private var presentationMode
  private let kinds = [
    ("reply", "回复"),
    ("at", "@我"),
    ("like", "点赞"),
    ("system", "系统"),
  ]

  private var selection: Binding<String> {
    Binding(
      get: { model.messageKind },
      set: { model.loadMessages(kind: $0) }
    )
  }

  var body: some View {
    NavigationView {
      VStack(spacing: 0) {
        Picker("消息类型", selection: selection) {
          ForEach(kinds, id: \.0) { kind in
            Text(kind.1).tag(kind.0)
          }
        }
        .pickerStyle(SegmentedPickerStyle())
        .padding(12)

        Divider()

        Group {
          if model.messagesLoading && model.messages.isEmpty {
            PiliNativeLoadingView(title: "正在加载消息")
          } else if let error = model.messagesError, model.messages.isEmpty {
            PiliNativeErrorView(message: error) { model.loadMessages() }
          } else if model.messages.isEmpty {
            PiliNativeEmptyView(icon: "bell.slash", title: "暂无消息", subtitle: "新的互动消息会显示在这里")
          } else {
            List(model.messages) { message in
              Button(action: { model.openMessageMember(message) }) {
                PiliNativeMessageRow(message: message)
              }
              .buttonStyle(PlainButtonStyle())
              .disabled(message.memberID == nil)
            }
            .listStyle(PlainListStyle())
          }
        }
      }
      .navigationBarTitle("消息中心", displayMode: .inline)
      .navigationBarItems(
        leading: Button("关闭") { presentationMode.wrappedValue.dismiss() },
        trailing: Button(action: { model.loadMessages() }) {
          Image(systemName: "arrow.clockwise")
        }
      )
    }
    .navigationViewStyle(StackNavigationViewStyle())
  }
}

private struct PiliNativeMessageRow: View {
  let message: PiliNativeMessage

  var body: some View {
    HStack(alignment: .top, spacing: 11) {
      PiliRemoteImage(urlString: message.avatar)
        .frame(width: 44, height: 44)
        .clipShape(Circle())
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(message.author.isEmpty ? "消息" : message.author)
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundColor(.primary)
          Spacer()
          Text(message.time)
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        Text(message.body)
          .font(.subheadline)
          .foregroundColor(.primary)
          .lineLimit(4)
        if !message.context.isEmpty {
          Text(message.context)
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(2)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(7)
        }
        if !message.badge.isEmpty {
          Text(message.badge)
            .font(.caption2)
            .foregroundColor(piliAccent)
        }
      }
      if let cover = message.cover {
        PiliRemoteImage(urlString: cover)
          .frame(width: 58, height: 58)
          .clipped()
          .cornerRadius(7)
      }
    }
    .padding(.vertical, 5)
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
          PiliNativeEmptyView(icon: "arrow.down.circle", title: "暂无离线缓存", subtitle: "已缓存和正在缓存的视频会显示在这里")
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
        }
      }
      .navigationBarTitle("离线缓存", displayMode: .inline)
      .navigationBarItems(
        leading: Button("关闭") { presentationMode.wrappedValue.dismiss() },
        trailing: Button(action: model.presentDownloads) {
          Image(systemName: "arrow.clockwise")
        }
      )
    }
    .navigationViewStyle(StackNavigationViewStyle())
  }
}

// MARK: - Native inline video introduction

final class PiliNativeVideoIntroFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    PiliNativeVideoIntroPlatformView(
      frame: frame,
      arguments: piliDictionary(args),
      messenger: messenger
    )
  }
}

private final class PiliNativeVideoIntroPlatformView: NSObject, FlutterPlatformView {
  private let hostingController: UIHostingController<PiliNativeInlineVideoIntroView>

  init(frame: CGRect, arguments: [String: Any], messenger: FlutterBinaryMessenger) {
    let model = PiliNativeInlineVideoIntroModel(arguments: arguments, messenger: messenger)
    hostingController = UIHostingController(
      rootView: PiliNativeInlineVideoIntroView(model: model)
    )
    super.init()
    hostingController.view.frame = frame
    hostingController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    hostingController.view.backgroundColor = .systemBackground
  }

  func view() -> UIView {
    hostingController.view
  }
}

private final class PiliNativeInlineVideoIntroModel: ObservableObject {
  @Published private(set) var detail: PiliNativeVideoDetail?
  @Published private(set) var loading = true
  @Published private(set) var error: String?
  @Published private(set) var actionLoading = false
  @Published private(set) var message: String?
  @Published private(set) var currentCID: Int?
  @Published private(set) var comments: [PiliNativeComment] = []
  @Published private(set) var commentsLoading = false
  @Published private(set) var commentsError: String?
  @Published private(set) var commentsTotal = 0

  private let channel: FlutterMethodChannel
  private let bvid: String
  private let aid: Int?
  private let heroTag: String
  private let fallbackTitle: String
  private let fallbackCover: String?
  private var hasLoaded = false

  init(arguments: [String: Any], messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: piliNativeChannelName, binaryMessenger: messenger)
    bvid = piliString(arguments["bvid"]) ?? ""
    aid = piliOptionalInt(arguments["aid"])
    heroTag = piliString(arguments["heroTag"]) ?? ""
    fallbackTitle = piliString(arguments["title"]) ?? ""
    fallbackCover = piliString(arguments["cover"])
    currentCID = piliOptionalInt(arguments["cid"])
  }

  func load() {
    guard !hasLoaded else { return }
    hasLoaded = true
    loading = true
    var arguments: [String: Any] = ["bvid": bvid, "title": fallbackTitle]
    if let aid = aid { arguments["aid"] = aid }
    if let fallbackCover = fallbackCover { arguments["cover"] = fallbackCover }
    channel.invokeMethod("loadVideoDetail", arguments: arguments) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.loading = false
        if let flutterError = response as? FlutterError {
          self.error = flutterError.message ?? "视频简介加载失败"
          return
        }
        let result = piliDictionary(response)
        guard result["state"] as? String == "success" else {
          self.error = result["error"] as? String ?? "视频简介加载失败"
          return
        }
        self.detail = PiliNativeVideoDetail(map: piliDictionary(result["video"]))
        if self.currentCID == nil { self.currentCID = self.detail?.cid }
        self.error = nil
        if let aid = self.detail?.aid {
          self.loadComments(oid: aid)
        }
      }
    }
  }

  func retry() {
    hasLoaded = false
    error = nil
    load()
  }

  func perform(_ action: String) {
    guard let detail = detail, !actionLoading else { return }
    actionLoading = true
    message = nil
    channel.invokeMethod(
      "performVideoAction",
      arguments: ["action": action, "bvid": detail.bvid]
    ) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.actionLoading = false
        if let flutterError = response as? FlutterError {
          self.message = flutterError.message ?? "操作失败"
          return
        }
        let result = piliDictionary(response)
        self.message = result["state"] as? String == "success"
          ? result["message"] as? String ?? "操作成功"
          : result["error"] as? String ?? "操作失败"
      }
    }
  }

  func openMember(_ memberID: Int?) {
    guard let memberID = memberID else { return }
    NotificationCenter.default.post(name: .piliPresentNativeProfile, object: memberID)
  }

  func selectPart(_ part: PiliNativeVideoPart) {
    guard let cid = part.cid, cid != currentCID else { return }
    let previousCID = currentCID
    currentCID = cid
    message = "正在切换到 P\(part.index)"
    channel.invokeMethod(
      "changeNativeVideoPart",
      arguments: ["heroTag": heroTag, "cid": cid]
    ) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self else { return }
        let result = piliDictionary(response)
        if result["state"] as? String == "success" {
          self.message = "已切换到 P\(part.index)"
        } else {
          self.currentCID = previousCID
          self.message = result["error"] as? String ?? "切换分P失败"
        }
      }
    }
  }

  func copyVideoID() {
    guard let detail = detail else { return }
    UIPasteboard.general.string = detail.bvid
    message = "已复制 \(detail.bvid)"
  }

  private func loadComments(oid: Int) {
    commentsLoading = true
    commentsError = nil
    channel.invokeMethod(
      "loadNativeComments",
      arguments: ["oid": oid, "type": 1, "page": 1]
    ) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.commentsLoading = false
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
        self.comments = rows.enumerated().map {
          PiliNativeComment(map: piliDictionary($0.element), index: $0.offset)
        }
        self.commentsTotal = piliInt(result["total"])
      }
    }
  }

  func toggleCommentLike(_ comment: PiliNativeComment) {
    guard let aid = detail?.aid else { return }
    channel.invokeMethod(
      "setNativeCommentLike",
      arguments: [
        "oid": aid,
        "type": 1,
        "rpid": comment.rpid,
        "liked": comment.liked,
      ]
    ) { [weak self] response in
      DispatchQueue.main.async {
        guard let self = self,
              let index = self.comments.firstIndex(where: { $0.id == comment.id }) else { return }
        let result = piliDictionary(response)
        guard result["state"] as? String == "success" else {
          self.commentsError = result["error"] as? String ?? "评论点赞失败"
          return
        }
        let nowLiked = piliBool(result["liked"])
        self.comments[index].liked = nowLiked
        self.comments[index].like = max(0, self.comments[index].like + (nowLiked ? 1 : -1))
      }
    }
  }
}

private struct PiliNativeInlineVideoIntroView: View {
  @ObservedObject var model: PiliNativeInlineVideoIntroModel

  var body: some View {
    Group {
      if model.loading && model.detail == nil {
        PiliNativeLoadingView(title: "正在加载视频简介")
      } else if let error = model.error, model.detail == nil {
        PiliNativeErrorView(message: error, retry: model.retry)
      } else if let video = model.detail {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 14) {
            ownerRow(video)

            Text(video.title)
              .font(.title3)
              .fontWeight(.semibold)
              .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
              Label(video.viewText, systemImage: "play.rectangle")
              Label(video.danmakuText, systemImage: "text.bubble")
              if !video.pubdateText.isEmpty { Text(video.pubdateText) }
            }
            .font(.caption)
            .foregroundColor(.secondary)

            if !video.argueMessage.isEmpty {
              Label(video.argueMessage, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundColor(.orange)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(9)
            }

            metrics(video)
            actions(video)

            if let message = model.message {
              Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            }

            if !video.description.isEmpty {
              VStack(alignment: .leading, spacing: 7) {
                Text("简介").font(.headline)
                Text(video.description)
                  .font(.subheadline)
                  .foregroundColor(.secondary)
                  .textSelection(.enabled)
              }
            }

            if !video.tags.isEmpty {
              ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                  ForEach(video.tags) { tag in
                    Text(tag.name)
                      .font(.caption)
                      .padding(.horizontal, 10)
                      .padding(.vertical, 6)
                      .background(Color(UIColor.secondarySystemBackground))
                      .clipShape(Capsule())
                  }
                }
              }
            }

            if video.pages.count > 1 {
              parts(video)
            }

            Divider()
            inlineComments
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 12)
          .padding(.bottom, 24)
        }
        .background(Color(UIColor.systemBackground))
      } else {
        PiliNativeErrorView(message: "暂无视频简介", retry: model.retry)
      }
    }
    .onAppear(perform: model.load)
  }

  private func ownerRow(_ video: PiliNativeVideoDetail) -> some View {
    Button(action: { model.openMember(video.ownerID) }) {
      HStack(spacing: 11) {
        PiliRemoteImage(urlString: video.ownerFace)
          .frame(width: 44, height: 44)
          .clipShape(Circle())
        VStack(alignment: .leading, spacing: 3) {
          Text(video.owner.isEmpty ? "UP 主" : video.owner)
            .font(.headline)
            .foregroundColor(.primary)
          Text(video.copyrightText)
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
  }

  private func metrics(_ video: PiliNativeVideoDetail) -> some View {
    HStack {
      PiliNativeVideoMetric(icon: "hand.thumbsup", value: video.like, title: "点赞")
      Spacer()
      PiliNativeVideoMetric(icon: "circle.hexagongrid", value: video.coin, title: "投币")
      Spacer()
      PiliNativeVideoMetric(icon: "star", value: video.favorite, title: "收藏")
      Spacer()
      PiliNativeVideoMetric(icon: "bubble.left", value: video.reply, title: "评论")
    }
    .padding(.vertical, 4)
  }

  private func actions(_ video: PiliNativeVideoDetail) -> some View {
    HStack(spacing: 10) {
      Button(action: { model.perform("triple") }) {
        Label("一键三连", systemImage: "hand.thumbsup.fill")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .tint(piliAccent)

      Button(action: { model.perform("later") }) {
        Label("稍后再看", systemImage: "clock")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)

      Button(action: model.copyVideoID) {
        Image(systemName: "doc.on.doc")
      }
      .buttonStyle(.bordered)
    }
    .disabled(model.actionLoading)
  }

  private var inlineComments: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("评论").font(.headline)
        if model.commentsTotal > 0 {
          Text(String(model.commentsTotal))
            .font(.caption)
            .foregroundColor(.secondary)
        }
        Spacer()
      }
      if model.commentsLoading {
        HStack(spacing: 8) {
          ProgressView()
          Text("正在加载评论")
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, minHeight: 64)
      } else if let error = model.commentsError, model.comments.isEmpty {
        Text(error)
          .font(.subheadline)
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity, minHeight: 64)
      } else if model.comments.isEmpty {
        Text("暂时没有评论")
          .font(.subheadline)
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity, minHeight: 64)
      } else {
        ForEach(model.comments) { comment in
          PiliNativeCommentRow(
            comment: comment,
            openMember: { model.openMember(comment.memberID) },
            toggleLike: { model.toggleCommentLike(comment) }
          )
          if comment.id != model.comments.last?.id {
            Divider().padding(.leading, 50)
          }
        }
      }
    }
  }

  private func parts(_ video: PiliNativeVideoDetail) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Text("视频选集 · \(video.pages.count)")
        .font(.headline)
      ForEach(video.pages) { part in
        Button(action: { model.selectPart(part) }) {
          HStack(spacing: 9) {
            Image(systemName: model.currentCID == part.cid ? "play.circle.fill" : "play.circle")
              .foregroundColor(model.currentCID == part.cid ? piliAccent : .secondary)
            Text("P\(part.index)  \(part.title)")
              .font(.subheadline)
              .foregroundColor(.primary)
              .lineLimit(2)
            Spacer()
            Text(part.durationText)
              .font(.caption)
              .foregroundColor(.secondary)
          }
          .padding(10)
          .background(Color(UIColor.secondarySystemBackground))
          .cornerRadius(9)
        }
        .buttonStyle(PlainButtonStyle())
      }
    }
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
          VStack(spacing: 12) {
            Image(systemName: emptySymbol)
              .font(.system(size: 38))
              .foregroundColor(.secondary)
            Text("这里还没有内容")
              .font(.headline)
            Text("可以下拉刷新，或使用右上角菜单打开完整功能。")
              .font(.caption)
              .foregroundColor(.secondary)
              .multilineTextAlignment(.center)
          }
          .padding(.horizontal, 30)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color(UIColor.systemGroupedBackground))
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
        leading: leadingButton,
        trailing: Menu {
          Button(action: { model.loadLibrary(refresh: true) }) {
            Label("刷新", systemImage: "arrow.clockwise")
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
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
    "播放与弹幕",
    "视频详情",
    "推荐与搜索",
    "外观与界面",
    "通用功能",
  ]
  private let advanced: [(String, String, String)] = [
    ("privacy", "隐私设置", "hand.raised"),
    ("recommend", "推荐流高级设置", "sparkles"),
    ("video", "音视频与画质", "film"),
    ("player", "播放器高级设置", "play.rectangle"),
    ("style", "外观设置", "paintbrush"),
    ("extra", "其他设置", "ellipsis.circle"),
    ("webdav", "WebDAV", "externaldrive"),
    ("about", "关于", "info.circle"),
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

            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              Section(
                header: Text("高级参数"),
                footer: Text("画质、解码器、字体尺寸等非布尔参数继续调用原设置组件，避免类型转换造成配置失效。")
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
                      Text(item.1).foregroundColor(.primary)
                      Spacer()
                    }
                  }
                }
              }
            }
          }
        }
      }
      .navigationBarTitle("设置", displayMode: .inline)
      .navigationBarItems(
        leading: Button("关闭") { presentationMode.wrappedValue.dismiss() },
        trailing: Button(action: model.loadSettings) {
          Image(systemName: "arrow.clockwise")
        }
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
    case "video": return "视频详情"
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
          Label("Flutter 保留网络与播放内核", systemImage: "network")
          Label("UIKit 承载原生播放器简介", systemImage: "rectangle.on.rectangle")
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

        if model.searchLoading {
          PiliNativeLoadingView(title: "正在搜索")
        } else if let error = model.searchError {
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
                Divider().padding(.leading, 154)
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
