"""Render and exercise the production native Mine and member profile views."""
import json
import platform
from pathlib import Path
import preview_ios_navigation as navigation

ROOT = Path(__file__).resolve().parents[1]

FIXTURES = r'''
import SwiftUI
import UIKit
private let piliAccent = Color.pink
private let piliProfileAccent = Color(red: 0.12, green: 0.36, blue: 0.25)
private final class PiliImageLoader: ObservableObject {
  let image: UIImage? = nil
  init(urlString: String?) {}
}
private struct PiliRemoteImage: View {
  let urlString: String?
  var body: some View {
    ZStack {
      LinearGradient(colors: urlString == "banner" ? [.orange.opacity(0.7), .yellow.opacity(0.5)] : [.cyan.opacity(0.6), .indigo.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
      Image(systemName: urlString == "banner" ? "mountain.2" : "photo").resizable().scaledToFit().padding(20).foregroundStyle(.white.opacity(0.6))
    }
  }
}
private struct PiliOriginalLevelBadge: View {
  let level: Int
  let height: CGFloat
  var body: some View { Text("LV\(level)").font(.system(size: height, weight: .heavy)).foregroundStyle(.orange) }
}
private struct PiliNativeCommentRichText: View {
  let message: String
  let emotes: [String: PiliNativeCommentEmote]
  var textStyle: UIFont.TextStyle = .subheadline
  var body: some View { Text(message).lineSpacing(7) }
}
private struct PiliNativeSettingsView: View {
  let model: PiliNativeViewModel
  var body: some View { Text("设置内容").navigationTitle("设置").navigationBarTitleDisplayMode(.inline) }
}
private struct PiliNativeSearchView: View {
  let model: PiliNativeViewModel
  var body: some View { Text("搜索内容").navigationTitle("搜索").navigationBarTitleDisplayMode(.inline) }
}
@MainActor
private final class PiliNativeViewModel: ObservableObject {
  @Published var account = PiliNativeAccount(map: ProcessInfo.processInfo.arguments.contains("guest") ? [:] : [
    "isLogin": true, "mid": 123, "name": "原生界面预览", "face": "avatar", "level": 5,
    "money": 948.6, "currentExp": 19735, "nextExp": 28800, "vip": true,
    "following": 58, "followers": 9, "dynamics": 2, "favoriteCount": 8])
  @Published var mineFavorites: [PiliNativeLibraryItem] = []
  var mineFavoritesLoading = false
  var mineFavoritesError: String? = nil
  @Published var isSearchPresented = false
  @Published var isSettingsPresented = false
  let selectedIndex = 2
  let tabTitles = ["首页", "动态", "我的"]
  @Published var isProfilePresented = false
  @Published var profile: PiliNativeProfile?
  @Published var profileSection = 0
  @Published var profileDynamics: [PiliNativeDynamic] = []
  @Published var profileCollections: [PiliNativeLibraryItem] = []
  var profileLoading = false, profileActionLoading = false
  var profileError: String? = nil
  var profileMessage: String? = nil
  var profileSectionLoading = false, profileSectionHasMore = false
  var profileSectionError: String? = nil
  var profileVideosLoading = false, profileVideosLoadingMore = false, profileVideosHasMore = false
  var profileVideosError: String? = nil
  @Published var destination: String? = nil
  func folders() -> [PiliNativeLibraryItem] {
    (0..<8).map { PiliNativeLibraryItem(map: ["id": "folder-\($0)", "kind": "folder", "title": $0 == 0 ? "默认收藏夹" : "旅行收藏 \($0)", "cover": "cover", "trailingText": "96 个内容", "badge": "私密"], index: $0) }
  }
  func loadMineFavorites() { if account.isLogin { mineFavorites = folders() } }
  func refresh(_ section: String) {}
  func presentSettings() { isSettingsPresented = true }
  func openRoute(_ route: String) { destination = route }
  func openFavoriteFolder(_ item: PiliNativeLibraryItem) { destination = item.title }
  func presentProfile(_ mid: Int, section: Int = 0) {
    profile = PiliNativeProfile(map: ["mid": mid, "name": "原生界面预览", "face": "avatar", "topImage": "banner",
      "sign": "在日常生活中寻找片刻宁静", "location": "IP属地：中国香港", "vip": true, "isSelf": mid == 123,
      "level": 5, "followers": 9, "following": 58, "likes": 6, "videoCount": 1,
      "videos": [["id": "video", "title": "旅途中的风景", "cover": "cover", "durationText": "08:24"]]])
    selectProfileSection(section)
    isProfilePresented = true
  }
  func selectProfileSection(_ section: Int) {
    profileSection = section
    profileDynamics = section == 1 ? (0..<2).map { PiliNativeDynamic(map: ["id": "\($0)", "author": "原生界面预览", "avatar": "avatar", "time": "2025-09-20", "body": "喜欢这样的天气，只想要在繁忙的生活中找到一丝宁静。\n每个天气都有自己的特色。", "repostText": "源动态不可见", "like": 5], index: $0) } : []
    profileCollections = section == 3 ? folders() : []
  }
  func loadProfile() {}
  func loadProfileSection(refresh: Bool = false) {}
  func loadMoreProfileVideos() {}
  func reloadProfileVideos() {}
  func toggleProfileFollow() { profile?.isFollowing.toggle() }
  func openProfileVideo(_ video: PiliNativeVideo) {}
  func openProfileDynamic(_ item: PiliNativeDynamic) {}
  func openProfileCollection(_ item: PiliNativeLibraryItem) {}
  func saveProfileSign(_ sign: String, completion: @escaping (String?) -> Void) { completion(nil) }
}
@main
private struct AccountPreviewApp: App {
  @StateObject private var model = PiliNativeViewModel()
  var body: some Scene {
    WindowGroup {
      PiliNativeMineView(model: model)
        .fullScreenCover(isPresented: $model.isProfilePresented) { PiliNativeProfileView(model: model) }
        .sheet(isPresented: Binding(get: { model.destination != nil }, set: { if !$0 { model.destination = nil } })) {
          VStack { Text(model.destination ?? "").accessibilityIdentifier("destination"); Button("关闭") { model.destination = nil } }
        }
        .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("dark") ? .dark : .light)
        .task {
          if ProcessInfo.processInfo.arguments.contains("other") { model.presentProfile(456, section: 1) }
        }
    }
  }
}
'''

TESTS = r'''
import XCTest
final class AccountPageTests: XCTestCase {
  let app = XCUIApplication()
  override func setUpWithError() throws { continueAfterFailure = false }
  func launch(_ mode: String = "self") { app.launchArguments = [mode]; app.launch() }
  func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
  }
  func testMineLayoutAndFavorites() {
    launch()
    let folder = app.buttons["favorite-folder-0"]
    XCTAssertTrue(folder.waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["设置"].exists)
    XCTAssertTrue(app.staticTexts["硬币 948.6"].exists)
    XCTAssertTrue(app.staticTexts["经验 19735/28800"].exists)
    capture("mine-reference-layout")
    folder.tap()
    XCTAssertTrue(app.staticTexts["destination"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["destination"].label, "默认收藏夹")
    app.buttons["关闭"].tap()
    app.buttons["设置"].tap()
    XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.navigationBars.buttons.firstMatch.exists)
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(app.buttons["favorite-folder-0"].waitForExistence(timeout: 5))
  }
  func testOwnDynamicTabAndEditor() {
    launch()
    let dynamic = app.buttons.containing(.staticText, identifier: "动态").firstMatch
    XCTAssertTrue(dynamic.waitForExistence(timeout: 10))
    dynamic.tap()
    XCTAssertTrue(app.buttons["profile-tab-1"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["profile-tab-1"].isSelected)
    XCTAssertTrue(app.staticTexts["源动态不可见"].firstMatch.exists)
    capture("profile-dynamic-reference-layout")
    app.buttons["编辑资料"].tap()
    XCTAssertTrue(app.textViews["个性签名"].waitForExistence(timeout: 5))
    app.buttons["取消"].tap()
    app.buttons["profile-tab-3"].tap()
    XCTAssertTrue(app.buttons["favorite-folder-0"].waitForExistence(timeout: 5))
    app.buttons["profile-tab-4"].tap()
    XCTAssertTrue(app.staticTexts["暂无追番"].waitForExistence(timeout: 5))
    app.buttons["profile-tab-2"].tap()
    XCTAssertTrue(app.staticTexts["旅途中的风景"].waitForExistence(timeout: 5))
  }
  func testGuestDoesNotShowAccountData() {
    launch("guest")
    XCTAssertTrue(app.buttons["mine-account"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["favorite-folder-0"].exists)
    app.buttons["mine-account"].tap()
    XCTAssertTrue(app.staticTexts["destination"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["destination"].label, "/loginPage")
  }
  func testOtherProfileCannotEdit() {
    launch("other")
    XCTAssertTrue(app.buttons["+ 关注"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["编辑资料"].exists)
    app.buttons["+ 关注"].tap()
    XCTAssertTrue(app.buttons["已关注"].waitForExistence(timeout: 5))
    capture("other-profile-follow")
  }
  func testDarkMine() {
    launch("dark")
    XCTAssertTrue(app.buttons["favorite-folder-0"].waitForExistence(timeout: 10))
    capture("mine-dark")
  }
}
'''


def production_swift():
    source = (ROOT / 'ios/Runner/PiliNativeRootViewController.swift').read_text(encoding='utf-8')
    def section(start, end):
        return source[source.index(start):source.index(end, source.index(start))]
    return FIXTURES + section('private struct PiliNativePrimaryDestinations:', '// MARK: - Root tabs') + section('private struct PiliNativeVideo:', 'private struct PiliNativeVideoPart:') + section(
        'private struct PiliNativeLibraryItem:', 'private struct PiliNativeMessage:') + section(
        'private struct PiliNativeComment:', 'private struct PiliNativeDownload:') + section(
        'private struct PiliNativeAccount {', '// MARK: - Native navigation gestures') + section(
        'private struct PiliNativeDynamicRow:', '// MARK: - Native video introduction') + section(
        '// MARK: - Shared image preview', '// MARK: - Native messages') + section(
        '// MARK: - Shared native views', '// MARK: - Original PiliPlus badges and icons') + source[source.index('private func piliDictionary('):]


if __name__ == '__main__':
    if platform.system() != 'Darwin':
        raise SystemExit('Account page UI tests require macOS and Xcode.')
    devices = json.loads(navigation.home.run('xcrun', 'simctl', 'list', 'devices', 'available', '-j'))['devices']
    phones = [d for runtime in devices.values() for d in runtime if 'iPhone' in d['name']]
    device = next((d for d in phones if d['state'] == 'Booted'), phones[0])
    if device['state'] != 'Booted': navigation.home.run('xcrun', 'simctl', 'boot', device['udid'])
    navigation.home.run('xcrun', 'simctl', 'bootstatus', device['udid'], '-b')
    navigation.OUTPUT = ROOT / 'build/account-pages-preview'
    navigation.BUNDLE_ID = 'dev.piliglass.accountpreview'
    navigation.production_swift = production_swift
    navigation.TESTS = TESTS
    navigation.main()
