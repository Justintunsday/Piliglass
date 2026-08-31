"""Exercise production menu navigation with offline data and real XCTest gestures.

Run on macOS after preview_ios_home.py. Network/player services are fixtures;
the root stack, home, search, settings, playback settings and library UI are
extracted unchanged from the production Swift file.
"""
import json
from pathlib import Path
import platform
import subprocess

import preview_ios_home as home

ROOT = home.ROOT
OUTPUT = ROOT / "build" / "navigation-preview"
BUNDLE_ID = "dev.piliglass.menupreview"

MODEL = r'''
  @Published var isLibraryPresented = false
  @Published var isLibraryDetailPresented = false
  @Published var isDownloadsPresented = false
  @Published var isProfilePresented = false
  @Published var isDynamicDetailPresented = false
  @Published var isLoginPresented = false
  @Published var isVideoDetailPresented = false
  @Published var videoTransitionSourceID: String?
  @Published var videoDismissCount = 0
  let originalPlayerFullscreen = false
  let dynamicBadge = ""
  let settingsLoading = false
  let videoQualityOptions: [PreviewQuality] = []
  let defaultVideoQuality = 80
  func setDefaultVideoQuality(_ value: Int) {}
  func loadSettings() {}
  func requestSnapshot() {}
  func handleVideoDeviceOrientation(_ orientation: UIDeviceOrientation) {}
  func closeVideoDetail() { isVideoDetailPresented = false }
  func videoDetailDidDismiss() {
    videoTransitionSourceID = nil
    videoDismissCount += 1
  }
  func presentProfile(_ id: Int) { isProfilePresented = true }
  let searchResults = [PiliNativeVideo(id: 1)]
  let searchLoading = false, searchLoadingMore = false, searchHasMore = false
  let searchError: String? = nil
  func search(_ text: String) {}
  func loadMoreSearchResults() {}
  @Published var libraryTitle = "我的收藏"
  @Published var libraryKind = "favorites"
  @Published var libraryItems = [PiliNativeLibraryItem()]
  let librarySubtitle = ""
  let libraryLoading = false, libraryLoadingMore = false, libraryHasMore = false
  let libraryError: String? = nil
  var libraryCanGoBack: Bool { libraryKind != "favorites" }
  func loadLibrary(refresh: Bool) {}
  func openLibraryItem(_ item: PiliNativeLibraryItem) {
    libraryKind = "favoriteDetail"
    libraryTitle = "测试收藏夹"
    libraryItems = []
    isLibraryDetailPresented = true
  }
  func returnToLibraryRoot() {
    isLibraryDetailPresented = false
    libraryKind = "favorites"
    libraryTitle = "我的收藏"
    libraryItems = [PiliNativeLibraryItem()]
  }
'''

STUBS = r'''
private typealias PiliNativeSetting = PreviewSetting
private struct PreviewQuality: Identifiable {
  let value: Int
  var id: Int { value }
  let label: String
}
private struct PiliNativeLibraryItem: Identifiable {
  let id = "folder-1", kind = "folder", title = "测试收藏夹", subtitle = "离线测试数据"
  let cover: String? = "0"
  let badge = "", durationText = "", progressText = "", trailingText = ""
  let viewText = "", danmakuText = ""
  let progress: CGFloat = 0
}
private extension Notification.Name {
  static let piliPresentNativeProfile = Notification.Name("piliglass.presentNativeProfile")
}
private struct PiliOriginalIcon: View {
  enum Family { case custom, material }
  let family: Family, codePoint: Int, fallback: String, size: CGFloat
  var body: some View { Image(systemName: fallback).font(.system(size: size)) }
}
private struct PiliNativeMineView: View {
  @ObservedObject var model: PiliNativeViewModel
  var body: some View {
    NavigationStack {
    List {
      Button("设置") { model.isSettingsPresented = true }
      Button("我的收藏") { model.isLibraryPresented = true }
      Button("消息") { model.isMessagesPresented = true }
      Button("离线缓存") { model.isDownloadsPresented = true }
      Button("个人主页") { model.isProfilePresented = true }
      Button("动态详情") { model.isDynamicDetailPresented = true }
      Button("扫码登录") { model.isLoginPresented = true }
    }.navigationTitle("我的").navigationBarTitleDisplayMode(.inline)
      .modifier(PiliNativePrimaryDestinations(model: model, tab: .mine))
    }
  }
}
private struct PiliNativeDynamicsView: View {
  @ObservedObject var model: PiliNativeViewModel
  var body: some View { Text("动态").navigationTitle("动态") }
}
private struct PiliNativeDanmakuPreferencesPage: View {
  let model: PiliNativeViewModel
  let profile: PiliNativeDanmakuProfile
  @Environment(\.dismiss) var dismiss
  var body: some View {
    NavigationStack {
      Text("显示与屏蔽规则").navigationTitle("\(profile.title)弹幕设置")
        .toolbar { Button("完成") { dismiss() } }
    }
  }
}
private struct PiliNativeDiagnosticLogSettingsView: View {
  var body: some View { Text("诊断").navigationTitle("诊断") }
}
private struct PiliNativeVideoDetailView: View {
  @ObservedObject var model: PiliNativeViewModel
  var body: some View {
    VStack(spacing: 20) {
      Color.black.frame(height: 240)
      Text("视频详情").accessibilityIdentifier("video-detail")
      Text("已退出 \(model.videoDismissCount) 次")
      Button("关闭视频") { model.closeVideoDetail() }
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(UIColor.systemBackground))
  }
}
@main
private struct MenuPreviewApp: App {
  @StateObject private var model = PiliNativeViewModel()
  var body: some Scene {
    WindowGroup { PiliNativeRootView(model: model).tint(piliAccent) }
  }
}
'''

TESTS = r'''
import XCTest

final class MenuNavigationTests: XCTestCase {
  let app = XCUIApplication()

  override func setUpWithError() throws {
    continueAfterFailure = false
    app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
    app.launch()
  }

  func screenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func edgeBack() {
    let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.45))
    let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.45))
    start.press(forDuration: 0.05, thenDragTo: end)
  }

  func assertPage(_ title: String) {
    XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 8))
    XCTAssertFalse(app.tabBars.firstMatch.isHittable, "Menus must cover the tab bar")
    XCTAssertFalse(app.buttons["关闭"].exists, "Use the native back button")
    XCTAssertEqual(app.sheets.count, 0, "Menus must push, not present a sheet")
  }

  func openMine() {
    let tab = app.tabBars.buttons["我的"]
    XCTAssertTrue(tab.waitForExistence(timeout: 8))
    tab.tap()
  }

  func testSearchButtonAndInteractiveBack() {
    let search = app.navigationBars.buttons["搜索"]
    XCTAssertTrue(search.waitForExistence(timeout: 8))
    XCTAssertGreaterThan(search.frame.width, app.frame.width * 0.45)
    XCTAssertFalse(app.navigationBars.staticTexts["PiliGlass"].exists)
    search.tap()
    assertPage("搜索")
    screenshot("search-pushed")
    edgeBack()
    XCTAssertTrue(search.waitForExistence(timeout: 8))
    XCTAssertTrue(app.tabBars.firstMatch.isHittable)
    search.tap()
    assertPage("搜索")
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(search.waitForExistence(timeout: 8))
    screenshot("home-after-search-back")
  }

  func testSettingsNestedPageAndBack() {
    openMine()
    app.buttons["设置"].tap()
    assertPage("设置")
    app.buttons["播放源设置"].tap()
    assertPage("播放源设置")
    screenshot("nested-playback-settings")
    edgeBack()
    XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 8))
    edgeBack()
    XCTAssertTrue(app.tabBars.buttons["我的"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.tabBars.firstMatch.isHittable)
    app.buttons["设置"].tap()
    assertPage("设置")
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(app.tabBars.firstMatch.isHittable)
  }

  func testCurrentSettingsAndPersistentGestures() {
    openMine()
    app.buttons["设置"].tap()
    assertPage("设置")
    XCTAssertFalse(app.staticTexts["原版设置分类"].exists)
    XCTAssertFalse(app.staticTexts["WebDAV 设置"].exists)
    screenshot("current-client-settings")
    app.buttons.containing(.staticText, identifier: "播放器设置").firstMatch.tap()
    assertPage("播放器设置")
    let gesture = app.switches["双击暂停或继续"]
    XCTAssertTrue(gesture.waitForExistence(timeout: 8))
    let initial = gesture.value as? String
    gesture.tap()
    let updated = gesture.value as? String
    XCTAssertNotEqual(initial, updated)
    XCTAssertFalse(app.switches["双击快退/快进"].exists)
    screenshot("native-player-preferences")
    edgeBack()
    app.buttons.containing(.staticText, identifier: "播放器设置").firstMatch.tap()
    XCTAssertTrue(gesture.waitForExistence(timeout: 8))
    XCTAssertEqual(gesture.value as? String, updated)
    gesture.tap()
  }

  func testSeparateDanmakuSettingsEntries() {
    openMine()
    app.buttons["设置"].tap()
    for title in ["简易播放器弹幕设置", "完整播放器弹幕设置"] {
      let entry = app.buttons.containing(.staticText, identifier: title).firstMatch
      if !entry.isHittable { app.swipeUp() }
      XCTAssertTrue(entry.waitForExistence(timeout: 8))
      entry.tap()
      XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 8))
      app.buttons["完成"].tap()
      XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 8))
    }
  }

  func testLibraryKeepsRestoredCloseAndFolderBack() {
    openMine()
    app.buttons["我的收藏"].tap()
    XCTAssertTrue(app.navigationBars["我的收藏"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.navigationBars.buttons["关闭"].exists)
    app.buttons.containing(.staticText, identifier: "测试收藏夹").firstMatch.tap()
    XCTAssertTrue(app.navigationBars["测试收藏夹"].waitForExistence(timeout: 8))
    screenshot("restored-favorite-folder")
    app.navigationBars.buttons["返回"].tap()
    XCTAssertTrue(app.navigationBars["我的收藏"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["测试收藏夹"].exists)
    app.navigationBars.buttons["关闭"].tap()
    XCTAssertTrue(app.tabBars.firstMatch.isHittable)
  }

  func testHomeButtonsSurviveTabSwitches() {
    openMine()
    app.tabBars.buttons["首页"].tap()
    XCTAssertTrue(app.navigationBars.buttons["搜索"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.navigationBars.buttons["消息"].exists)
    XCTAssertTrue(app.navigationBars.buttons["我的"].exists)
    screenshot("home-toolbar-after-tab-switch")
  }

  func testVideoZoomCloseAndReopen() {
    let card = app.buttons.containing(.staticText, identifier: "城市漫游：发现身边的美好").firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 8))
    card.tap()
    XCTAssertTrue(app.staticTexts["video-detail"].waitForExistence(timeout: 8))
    screenshot("video-zoom-open")
    app.buttons["关闭视频"].tap()
    XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 8))
    card.tap()
    XCTAssertTrue(app.staticTexts["video-detail"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["已退出 1 次"].exists)
    edgeBack()
    XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 8))
    card.tap()
    XCTAssertTrue(app.staticTexts["video-detail"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["已退出 2 次"].exists)
  }

  func testVideoZoomCancelledGestureAndSearchReturn() {
    app.navigationBars.buttons["搜索"].tap()
    let card = app.buttons.containing(.staticText, identifier: "山海之间，记录旅途的风景").firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 8))
    card.tap()
    XCTAssertTrue(app.staticTexts["video-detail"].waitForExistence(timeout: 8))
    // A short, slow drag should cancel without releasing playback resources.
    let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
    let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
    start.press(forDuration: 0.05, thenDragTo: middle,
                withVelocity: .slow, thenHoldForDuration: 0.5)
    XCTAssertTrue(app.staticTexts["video-detail"].exists)
    XCTAssertTrue(app.staticTexts["已退出 0 次"].exists)
    screenshot("video-zoom-cancelled-back")
    edgeBack()
    // A completed dismissal must preserve the search stack and result card.
    XCTAssertTrue(app.navigationBars["搜索"].waitForExistence(timeout: 8))
    XCTAssertTrue(card.isHittable)
    XCTAssertFalse(app.tabBars.firstMatch.isHittable)
    card.tap()
    XCTAssertTrue(app.staticTexts["video-detail"].waitForExistence(timeout: 8))
    app.buttons["关闭视频"].tap()
    XCTAssertTrue(app.navigationBars["搜索"].waitForExistence(timeout: 8))
    screenshot("search-after-video-zoom-back")
  }
}
'''


def production_swift():
    source = (ROOT / "ios/Runner/PiliNativeRootViewController.swift").read_text(encoding='utf-8')
    player = (ROOT / "ios/Runner/PiliNativePlayer.swift").read_text(encoding='utf-8')
    preferences = player[player.index('enum PiliNativePlayerPreferences {'):
                         player.index('@MainActor\nfinal class PiliNativePlayerSession')]
    profiles = player[player.index('enum PiliNativeDanmakuProfile:'):player.index('struct PiliNativeDanmakuSettingsView:')]

    def section(start, end):
        a = source.index(start)
        return source[a:source.index(end, a)]

    fixtures = home.FIXTURES.replace(
        'private final class PiliNativeViewModel: ObservableObject {',
        'private final class PiliNativeViewModel: ObservableObject {\n' + MODEL,
    ).replace(
        'func openVideo(_ video: PiliNativeVideo, sourceID: String? = nil) {}',
        '''func openVideo(_ video: PiliNativeVideo, sourceID: String? = nil) {
    videoTransitionSourceID = sourceID
    isVideoDetailPresented = true
  }''',
    ).replace(
        'private struct PreviewSetting {',
        '''private struct PreviewSetting: Identifiable {
  var id: String { key }
  let title = "音频 CDN", subtitle = "", group = "音视频与画质", icon = "speaker.wave.2"
  let needsRestart = false''',
    )
    stubs = STUBS
    for name, title in [('Messages', '消息'), ('Downloads', '离线缓存'),
                        ('Profile', '个人主页'), ('DynamicDetail', '动态详情'),
                        ('Login', '扫码登录')]:
        stubs += f'''\nprivate struct PiliNative{name}View: View {{
  @ObservedObject var model: PiliNativeViewModel
  var body: some View {{ Text("{title}").navigationTitle("{title}").navigationBarTitleDisplayMode(.inline) }}
}}\n'''
    return fixtures + preferences + profiles + section('private struct PiliEdgeSwipeBackModifier:',
                              'private struct PiliNativeDynamicsView:') + section(
        'private struct PiliNativeLibraryView:', '// MARK: - Native settings') + section(
        'private struct PiliNativeSettingsView:', 'private struct PiliNativeDanmakuPreferencesPage:') + section(
        'private struct PiliNativePlaybackSourceSettingsView:', 'private struct PiliNativeDiagnosticLogSettingsView:') + section(
        'private struct PiliNativeAboutSettingsView:', '// MARK: - Native search') + section(
        'private struct PiliNativePlaybackSourceOption:', 'private struct PiliNativeSetting:') + section(
        'private struct PiliNativeSearchView:', '// MARK: - Shared native views') + stubs


def write_project():
    """Write a minimal app + UI-test Xcode project without external generators."""
    objects = {}

    def obj(isa, **values):
        key = f'{len(objects)+1:024X}'
        objects[key] = dict(isa=isa, **values)
        return key

    main = obj('PBXFileReference', lastKnownFileType='sourcecode.swift', path='Main.swift', sourceTree='<group>')
    tests = obj('PBXFileReference', lastKnownFileType='sourcecode.swift', path='NavigationTests.swift', sourceTree='<group>')
    app_product = obj('PBXFileReference', explicitFileType='wrapper.application', path='MenuPreview.app', sourceTree='BUILT_PRODUCTS_DIR')
    test_product = obj('PBXFileReference', explicitFileType='wrapper.cfbundle', path='MenuNavigationTests.xctest', sourceTree='BUILT_PRODUCTS_DIR')
    products = obj('PBXGroup', name='Products', children=[app_product, test_product], sourceTree='<group>')
    group = obj('PBXGroup', children=[main, tests, products], sourceTree='<group>')

    def configurations(settings):
        configs = [obj('XCBuildConfiguration', name=name, buildSettings=settings) for name in ['Debug','Release']]
        return obj('XCConfigurationList', buildConfigurations=configs, defaultConfigurationIsVisible=0, defaultConfigurationName='Debug')

    common = dict(SWIFT_VERSION='5.0', IPHONEOS_DEPLOYMENT_TARGET='16.0', SDKROOT='iphoneos',
                  TARGETED_DEVICE_FAMILY='1,2', CODE_SIGNING_ALLOWED='NO', GENERATE_INFOPLIST_FILE='YES')
    app_config = configurations(dict(common, PRODUCT_BUNDLE_IDENTIFIER=BUNDLE_ID, PRODUCT_NAME='MenuPreview',
                                    INFOPLIST_KEY_UILaunchScreen_Generation='YES'))
    test_config = configurations(dict(common, PRODUCT_BUNDLE_IDENTIFIER=BUNDLE_ID+'.tests',
                                     PRODUCT_NAME='MenuNavigationTests', TEST_TARGET_NAME='MenuPreview'))
    project_config = configurations(dict(CLANG_ENABLE_MODULES='YES', SWIFT_OPTIMIZATION_LEVEL='-Onone'))

    def sources(file):
        build_file = obj('PBXBuildFile', fileRef=file)
        return obj('PBXSourcesBuildPhase', buildActionMask=2147483647, files=[build_file], runOnlyForDeploymentPostprocessing=0)

    app_target = obj('PBXNativeTarget', name='MenuPreview', productName='MenuPreview',
                     productReference=app_product, productType='com.apple.product-type.application',
                     buildConfigurationList=app_config, buildPhases=[sources(main)], buildRules=[], dependencies=[])
    test_target = obj('PBXNativeTarget', name='MenuNavigationTests', productName='MenuNavigationTests',
                      productReference=test_product, productType='com.apple.product-type.bundle.ui-testing',
                      buildConfigurationList=test_config, buildPhases=[sources(tests)], buildRules=[], dependencies=[])
    project = obj('PBXProject', attributes=dict(LastUpgradeCheck='2600', TargetAttributes={test_target: dict(TestTargetID=app_target)}),
                  buildConfigurationList=project_config, compatibilityVersion='Xcode 14.0', developmentRegion='en',
                  hasScannedForEncodings=0, knownRegions=['en','Base'], mainGroup=group, productRefGroup=products,
                  projectDirPath='', projectRoot='', targets=[app_target,test_target])
    proxy = obj('PBXContainerItemProxy', containerPortal=project, proxyType=1, remoteGlobalIDString=app_target, remoteInfo='MenuPreview')
    dependency = obj('PBXTargetDependency', target=app_target, targetProxy=proxy)
    objects[test_target]['dependencies'] = [dependency]

    def plist(value):
        if isinstance(value, dict):
            return '{\n' + '\n'.join(f'{json.dumps(k)} = {plist(v)};' for k,v in value.items()) + '\n}'
        if isinstance(value, list):
            return '(' + ','.join(plist(v) for v in value) + ')'
        return json.dumps(value)

    project_dir = OUTPUT / 'MenuPreview.xcodeproj'
    project_dir.mkdir(exist_ok=True)
    (project_dir / 'project.pbxproj').write_text('// !$*UTF8*$!\n'+plist(dict(archiveVersion=1, classes={}, objectVersion=56, objects=objects, rootObject=project)))
    schemes = project_dir / 'xcshareddata/xcschemes'
    schemes.mkdir(parents=True, exist_ok=True)

    def reference(target, name, product):
        return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:MenuPreview.xcodeproj"/>'

    app_ref = reference(app_target,'MenuPreview','MenuPreview.app')
    test_ref = reference(test_target,'MenuNavigationTests','MenuNavigationTests.xctest')
    (schemes / 'MenuPreview.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction parallelizeBuildables="NO" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{app_ref}</BuildActionEntry>
<BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{test_ref}</BuildActionEntry>
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{test_ref}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></LaunchAction>
</Scheme>''')
    return project_dir


def main():
    if platform.system() != 'Darwin':
        raise SystemExit('Navigation UI tests require macOS and Xcode.')
    OUTPUT.mkdir(parents=True, exist_ok=True)
    (OUTPUT / 'Main.swift').write_text(production_swift(), encoding='utf-8')
    (OUTPUT / 'NavigationTests.swift').write_text(TESTS, encoding='utf-8')
    project = write_project()
    devices = json.loads(home.run('xcrun','simctl','list','devices','available','-j'))['devices']
    device = next(d for values in devices.values() for d in values if d['state']=='Booted' and 'iPhone' in d['name'])
    home.run('xcrun','simctl','ui',device['udid'],'appearance','light')
    result = OUTPUT / 'MenuNavigation.xcresult'
    with (OUTPUT / 'xcodebuild.log').open('w') as log:
        completed = subprocess.run(['xcodebuild','test','-project',str(project),'-scheme','MenuPreview',
            '-destination',f"platform=iOS Simulator,id={device['udid']}",'-parallel-testing-enabled','NO',
            '-resultBundlePath',str(result),'-derivedDataPath',str(OUTPUT/'DerivedData')],stdout=log,stderr=subprocess.STDOUT)
    print((OUTPUT / 'xcodebuild.log').read_text()[-16000:], flush=True)
    if result.exists():
        subprocess.run(['xcrun','xcresulttool','export','attachments','--path',str(result),
                        '--output-path',str(OUTPUT/'attachments')],check=False)
    if completed.returncode:
        raise SystemExit(completed.returncode)


if __name__ == '__main__':
    main()
