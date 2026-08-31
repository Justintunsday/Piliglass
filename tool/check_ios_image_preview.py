"""Exercise production comment/dynamic image galleries with offline HTTP fixtures."""
import json
from pathlib import Path
import platform
import preview_ios_navigation as navigation

ROOT = Path(__file__).resolve().parents[1]

FIXTURES = r'''
import SwiftUI
import UIKit
private let piliAccent = Color.pink
private final class ImageProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "image-preview.invalid"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let path = request.url!.path
    let failed = path == "/failure"
    let size = path == "/long" ? CGSize(width: 180, height: 1600) : CGSize(width: 360, height: 480)
    let image = UIGraphicsImageRenderer(size: size).image { context in
      UIColor.systemTeal.setFill()
      context.fill(CGRect(origin: .zero, size: size))
      for y in stride(from: 0, to: Int(size.height), by: 100) {
        UIColor.systemOrange.setFill()
        context.fill(CGRect(x: 10, y: CGFloat(y), width: 80, height: 40))
      }
    }
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: failed ? 503 : 200,
      httpVersion: nil, headerFields: ["Content-Type": "image/jpeg"])!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: failed ? Data() : image.jpegData(compressionQuality: 0.9)!)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
private final class PiliImageLoader: ObservableObject {
  let image: UIImage? = nil
  init(urlString: String?) {}
}
private struct PiliRemoteImage: View {
  let urlString: String?
  var body: some View { Color.gray }
}
private struct PiliOriginalLevelBadge: View {
  let level: Int
  let height: CGFloat
  var body: some View { Text("LV\(level)") }
}
private struct PiliNativeCommentRichText: View {
  let message: String
  let emotes: [String: PiliNativeCommentEmote]
  var body: some View { Text(message) }
}
@main
private struct ImagePreviewApp: App {
  init() { URLProtocol.registerClass(ImageProtocol.self) }
  var body: some Scene { WindowGroup { GalleryFixture() } }
}
private struct GalleryFixture: View {
  @State private var detailOpens = 0
  private var mode: String { ProcessInfo.processInfo.arguments.last ?? "comments" }
  private var pictures: [[String: Any]] {
    let paths = mode == "failure" ? ["failure"] : ["first", "long", "third"]
    return paths.map { ["url": "https://image-preview.invalid/\($0)", "width": 100, "height": 160] }
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("图片预览测试")
        Text("detail-opens=\(detailOpens)").accessibilityIdentifier("detail-opens")
        if mode == "comments" {
          PiliNativeCommentRow(comment: PiliNativeComment(map: ["message": "评论配图", "pictures": pictures], index: 0),
            openMember: {}, toggleLike: {})
        } else {
          PiliNativeDynamicRow(item: PiliNativeDynamic(map: ["author": "动态作者", "body": "动态配图", "pictures": pictures], index: 0)) {
            detailOpens += 1
          }
        }
      }.padding(16)
    }
  }
}
'''

TESTS = r'''
import XCTest
final class ImagePreviewTests: XCTestCase {
  let app = XCUIApplication()
  var index: XCUIElement { app.staticTexts["image-preview-index"] }
  var image: XCUIElement { app.images["预览大图"].firstMatch }
  override func setUpWithError() throws { continueAfterFailure = false }
  func launch(_ mode: String) {
    XCUIDevice.shared.orientation = .portrait
    app.launchArguments = [mode]
    app.launch()
    XCTAssertTrue(app.buttons["预览图片 1"].waitForExistence(timeout: 10))
  }
  func assertValue(_ element: XCUIElement, _ key: String, _ value: String) {
    expectation(for: NSPredicate(format: "%K == %@", key, value), evaluatedWith: element)
    waitForExpectations(timeout: 6)
  }
  func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  func exerciseGallery() {
    app.buttons["预览图片 2"].tap()
    XCTAssertTrue(index.waitForExistence(timeout: 5))
    assertValue(index, "label", "2 / 3")
    XCTAssertTrue(image.waitForExistence(timeout: 10))
    assertValue(image, "value", "1.0 倍")
    image.doubleTap()
    expectation(for: NSPredicate(format: "value != %@", "1.0 倍"), evaluatedWith: image)
    waitForExpectations(timeout: 5)
    capture("long-image-zoomed")
    image.doubleTap()
    assertValue(image, "value", "1.0 倍")
    // The pager must receive swipes while the nested zoom scroll view is fitted.
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).press(forDuration: 0.05,
      thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)))
    assertValue(index, "label", "3 / 3")
    app.buttons["上一张图片"].tap()
    assertValue(index, "label", "2 / 3")
    app.buttons["关闭图片预览"].tap()
    XCTAssertTrue(app.buttons["预览图片 2"].waitForExistence(timeout: 5))
  }
  func testCommentGallery() {
    launch("comments")
    exerciseGallery()
  }
  func testDynamicGalleryDoesNotOpenDetail() {
    launch("dynamic")
    exerciseGallery()
    assertValue(app.staticTexts["detail-opens"], "label", "detail-opens=0")
    app.buttons.containing(.staticText, identifier: "动态配图").firstMatch.tap()
    assertValue(app.staticTexts["detail-opens"], "label", "detail-opens=1")
  }
  func testFailedSingleImageCanRetryAndClose() {
    launch("failure")
    app.buttons["预览图片 1"].tap()
    let retry = app.buttons["重新加载图片"]
    XCTAssertTrue(retry.waitForExistence(timeout: 10))
    retry.tap()
    XCTAssertTrue(retry.waitForExistence(timeout: 10))
    assertValue(index, "label", "1 / 1")
    capture("image-load-failure")
    app.buttons["关闭图片预览"].tap()
    XCTAssertTrue(app.buttons["预览图片 1"].waitForExistence(timeout: 5))
  }
}
'''


def production_swift():
    source = (ROOT / 'ios/Runner/PiliNativeRootViewController.swift').read_text(encoding='utf-8')
    def section(start, end):
        return source[source.index(start):source.index(end, source.index(start))]
    return FIXTURES + section('private struct PiliNativeDynamic:', 'private struct PiliNativeMessage:') + section(
        'private struct PiliNativeComment:', 'private struct PiliNativeDownload:') + section(
        'private struct PiliNativeDynamicRow:', 'private struct PiliNativeAvatar:') + section(
        'private struct PiliNativeCommentRow:', '// MARK: - Native messages') + section(
        'private func piliDictionary(', 'private func piliCompactNumber(')


if __name__ == '__main__':
    if platform.system() != 'Darwin':
        raise SystemExit('Image preview UI tests require macOS and Xcode.')
    devices = json.loads(navigation.home.run('xcrun', 'simctl', 'list', 'devices', 'available', '-j'))['devices']
    phones = [d for runtime in devices.values() for d in runtime if 'iPhone' in d['name']]
    device = next((d for d in phones if d['state'] == 'Booted'), phones[0])
    if device['state'] != 'Booted':
        navigation.home.run('xcrun', 'simctl', 'boot', device['udid'])
    navigation.home.run('xcrun', 'simctl', 'bootstatus', device['udid'], '-b')
    navigation.OUTPUT = ROOT / 'build/image-preview-check'
    navigation.BUNDLE_ID = 'dev.piliglass.imagepreview'
    navigation.production_swift = production_swift
    navigation.TESTS = TESTS
    navigation.main()
