import Flutter
import SwiftUI
import UIKit

private let piliNativeChannelName = "piliglass/native_ui"
private let piliAccent = Color(red: 0.93, green: 0.29, blue: 0.48)

// MARK: - Native container

/// Hosts a fully native SwiftUI root interface over the original Flutter root.
///
/// Flutter remains alive underneath on the same engine. When a feature route
/// such as login, video detail, or the player is opened, Dart asks this
/// controller to reveal Flutter. Returning to `/` reveals the native root again.
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

  private let channel: FlutterMethodChannel
  private var snapshotInFlight = false
  private var pendingVideo: PiliNativeVideo?

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
        self.videoDetail = PiliNativeVideoDetail(map: piliDictionary(result["video"]))
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
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [channel = self.channel] in
      channel.invokeMethod(
        "openRoute",
        arguments: ["route": "/member", "parameters": ["mid": String(memberID)]]
      )
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

  func openSettingsSection(_ section: String) {
    isSettingsPresented = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [channel = self.channel] in
      channel.invokeMethod("openSettingsSection", arguments: ["section": section])
    }
  }

  func openDynamic(_ item: PiliNativeDynamic) {
    channel.invokeMethod("openDynamic", arguments: ["id": item.sourceID])
  }

  func openRoute(_ route: String, parameters: [String: String] = [:]) {
    channel.invokeMethod(
      "openRoute",
      arguments: ["route": route, "parameters": parameters]
    )
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

private struct PiliNativeDynamic: Identifiable {
  let id: String
  let sourceID: String
  let author: String
  let avatar: String?
  let time: String
  let title: String
  let body: String
  let cover: String?
  let like: Int
  let comment: Int
  let forward: Int

  init(map: [String: Any], index: Int) {
    sourceID = piliString(map["id"]) ?? "dynamic"
    id = "\(sourceID)-\(index)"
    author = piliString(map["author"]) ?? ""
    avatar = piliString(map["avatar"])
    time = piliString(map["time"]) ?? ""
    title = piliString(map["title"]) ?? ""
    body = piliString(map["body"]) ?? ""
    cover = piliString(map["cover"])
    like = piliInt(map["like"])
    comment = piliInt(map["comment"])
    forward = piliInt(map["forward"])
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
    .fullScreenCover(isPresented: $model.isVideoDetailPresented) {
      PiliNativeVideoDetailView(model: model)
    }
    .onAppear {
      model.requestSnapshot()
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
              openProtected("/follow")
            }
            Spacer()
            PiliNativeAccountStat(value: model.account.followers, title: "粉丝") {
              openProtected("/fan")
            }
          }
          .padding(.horizontal, 18)
          .padding(.vertical, 8)
        }

        Section(header: Text("我的服务")) {
          ForEach(actions.indices, id: \.self) { index in
            let item = actions[index]
            Button(action: { item.3 ? openProtected(item.2) : model.openRoute(item.2) }) {
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
      model.openRoute("/member", parameters: ["mid": String(mid)])
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

      Text("播放器继续使用原有 Flutter 播放内核，以保留 DASH 音视频合流、弹幕、清晰度切换、播放进度与登录画质。")
        .font(.caption2)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
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
              footer: Text("这些开关直接读写原项目的同一份设置数据，Flutter 功能页会继续使用修改后的值。")
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
                  Button(action: { model.openSettingsSection(item.0) }) {
                    HStack(spacing: 13) {
                      Image(systemName: item.2)
                        .frame(width: 24)
                        .foregroundColor(piliAccent)
                      Text(item.1).foregroundColor(.primary)
                      Spacer()
                      Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(Color(UIColor.tertiaryLabel))
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
