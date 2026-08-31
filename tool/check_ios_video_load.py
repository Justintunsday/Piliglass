"""Exercise production danmaku and comment views with large offline fixtures.

Run after preview_ios_home.py on macOS (reuses its booted simulator). No network
or player engine is mocked into the app: the actual buffer, renderer, comment
section, rows and rich text are extracted verbatim and tested in UIKit/SwiftUI.
"""
import json
from pathlib import Path
import platform
import plistlib
import shutil
import time

from preview_ios_home import ROOT, run

OUTPUT = ROOT / "build/video-load-check"
BUNDLE_ID = "dev.piliglass.videoloadcheck"

FIXTURES = r'''
import SwiftUI
import UIKit
private let piliAccent = Color.pink
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
private final class PiliNativeViewModel: ObservableObject {
  @Published var comments = (0..<1000).map {
    PiliNativeComment(map: ["message": "大量评论布局测试 \($0) " + String(repeating: "保留评论内容、图片和回复功能。", count: 3)], index: $0)
  }
  let commentsTotal = 1000
  let commentsError: String? = nil
  let commentsLoading = false, commentsLoadingMore = false, commentsHasMore = true
  let dynamicActionLoading = false
  var loadMoreCalls = 0
  func loadMoreComments() { loadMoreCalls += 1 }
  func beginDynamicComment() {}
  func openCommentMember(_ comment: PiliNativeComment) {}
  func toggleCommentLike(_ comment: PiliNativeComment) {}
  func beginCommentReply(_ comment: PiliNativeComment) {}
  func openCommentThread(_ comment: PiliNativeComment) {}
}
private final class CountingLabel: UILabel {
  var assignments = 0
  override var attributedText: NSAttributedString? {
    didSet { assignments += 1 }
  }
}
private func item(_ id: String, _ time: Double, _ text: String, mode: Int = 1) -> PiliNativeDanmakuItem {
  PiliNativeDanmakuItem(id: id, progress: time, mode: mode, fontSize: 25,
                       color: .white, content: text, weight: 10)
}
@main
private struct LoadCheckApp: App {
  @StateObject var model = PiliNativeViewModel()
  var body: some Scene {
    WindowGroup {
      ScrollViewReader { proxy in
        ScrollView {
          // Same container structure as the production video's comments tab.
          VStack(alignment: .leading, spacing: 14) {
            Text("热门评论")
            PiliNativeCommentsSection(model: model, showsHeader: false)
          }.padding(16)
        }.task {
          await check(model: model) {
            proxy.scrollTo("comment-999", anchor: .bottom)
          }
        }
      }
    }
  }
}
@MainActor
private func check(model: PiliNativeViewModel, scrollToEnd: () -> Void) async {
  try? await Task.sleep(nanoseconds: 1_000_000_000)
  var report: [String: Any] = [:]
  var failures: [String] = []
  func expect(_ condition: Bool, _ name: String) {
    report[name] = condition
    if !condition { failures.append(name) }
  }
  func labels(_ view: UIView) -> Int {
    (view is PiliNativeMultilineLabel ? 1 : 0) + view.subviews.reduce(0) { $0 + labels($1) }
  }
  let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    .flatMap(\.windows).first { $0.isKeyWindow }!
  let visibleLabels = labels(window)
  report["commentCount"] = model.comments.count
  report["initialCommentLabels"] = visibleLabels
  expect(visibleLabels > 0 && visibleLabels < 100, "commentsAreLazy")
  expect(model.loadMoreCalls == 0, "noOffscreenPagination")
  scrollToEnd()
  try? await Task.sleep(nanoseconds: 1_000_000_000)
  expect(model.loadMoreCalls > 0, "paginationStillWorksAtEnd")

  let label = CountingLabel()
  let rich = PiliNativeCommentRichText(message: "原始评论 [表情]", emotes: [:])
  let coordinator = rich.makeCoordinator()
  for _ in 0..<1000 { coordinator.render(in: label) }
  expect(label.assignments == 1, "unchangedTextRenderedOnce")
  coordinator.parent = PiliNativeCommentRichText(message: "更新后的评论", emotes: [:])
  coordinator.render(in: label)
  expect(label.assignments == 2 && label.attributedText?.string == "更新后的评论", "changedTextStillUpdates")
  coordinator.render(in: label, force: true)
  expect(label.assignments == 3, "imageCompletionCanRefreshText")

  // Queue confinement matches production; a full segment is never sorted on main.
  let timeline: [PiliNativeDanmakuItem] = await withCheckedContinuation { continuation in
    DispatchQueue.global(qos: .userInitiated).async {
      let buffer = PiliNativeDanmakuBuffer()
      let input = (0..<100_000).reversed().map {
        item("\($0)", Double($0 / 1000) * 0.1, "高密度弹幕 \($0)")
      }
      continuation.resume(returning: buffer.append(input)!)
    }
  }
  report["danmakuCount"] = timeline.count
  expect(timeline.count == 100_000, "timelineRetainsAllItems")
  expect(zip(timeline, timeline.dropFirst()).allSatisfy { pair in pair.0.progress <= pair.1.progress }, "timelineIsSorted")
  let buffer = PiliNativeDanmakuBuffer()
  let merged = buffer.append([
    item("a", 1, "重复  弹幕"), item("a", 1, "重复  弹幕"),
    item("b", 2, "重复 弹幕"), item("c", 4, "重复 弹幕"),
    item("d", 1, "重复 弹幕", mode: 7), item("e", 1, "重复 弹幕", mode: 7)
  ])!
  expect(merged.count == 4 && merged.first { $0.id == "a" }?.mergeCount == 2, "dedupAndTimedMerge")
  expect(buffer.append([item("a", 1, "重复  弹幕")]) == nil, "duplicateSegmentIsNoOp")

  let overlay = PiliNativeDanmakuView(frame: CGRect(x: 0, y: 0, width: 390, height: 220))
  window.addSubview(overlay)
  var maximum = 0
  let started = CACurrentMediaTime()
  for tick in 0..<100 {
    overlay.render(time: Double(tick) * 0.1, items: timeline, revision: 1)
    maximum = max(maximum, overlay.subviews.count)
  }
  report["burstRenderMilliseconds"] = (CACurrentMediaTime() - started) * 1000
  report["maximumActiveDanmaku"] = maximum
  expect(maximum > 0 && maximum <= 60, "burstRenderingIsBounded")
  overlay.clear()
  let short = [item("one", 0.1, "正在显示"), item("two", 2.1, "之后显示")]
  overlay.render(time: 0, items: short, revision: 2)
  overlay.render(time: 0.1, items: short, revision: 2)
  let first = overlay.subviews.first
  overlay.render(time: 0.1, items: short + [item("three", 10, "预加载")], revision: 3)
  expect(first != nil && overlay.subviews.first === first, "prefetchPreservesAnimations")
  overlay.render(time: 2, items: short, revision: 3)
  expect(overlay.subviews.isEmpty, "seekClearsStaleAnimations")
  overlay.render(time: 2.1, items: short, revision: 3)
  expect(overlay.subviews.count == 1, "seekResumesAtNewPosition")
  overlay.render(time: 0, items: short, revision: 3)
  overlay.render(time: 0.1, items: short, revision: 3)
  expect(overlay.subviews.count == 1, "backwardSeekReplaysTimeline")
  overlay.removeFromSuperview()
  report["failures"] = failures
  let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
  let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
  try! data.write(to: documents.appendingPathComponent("report.json"))
}
'''


def production_swift():
    root = (ROOT / "ios/Runner/PiliNativeRootViewController.swift").read_text(encoding="utf-8")
    player = (ROOT / "ios/Runner/PiliNativePlayer.swift").read_text(encoding="utf-8")

    def section(source, start, end):
        a = source.index(start)
        return source[a:source.index(end, a)]

    return FIXTURES + section(player, "struct PiliNativeDanmakuItem:", "@MainActor\nfinal class PiliNativePlayerSession") + section(
        player, "private final class PiliNativeDanmakuView:", "private final class PiliNativePlayerGradientView:") + section(
        root, "private struct PiliNativeComment:", "private struct PiliNativeDownload:") + section(
        root, "private struct PiliNativeCommentsSection:", "private struct PiliNativeDynamicComposerView:") + section(
        root, "private final class PiliNativeMultilineLabel:", "// MARK: - Native messages") + section(
        root, "private func piliDictionary(", "private func piliCompactNumber(")


def main():
    if platform.system() != "Darwin":
        raise SystemExit("Video load checks require macOS and Xcode.")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    swift = OUTPUT / "LoadCheck.swift"
    swift.write_text(production_swift(), encoding="utf-8")
    app = OUTPUT / "LoadCheck.app"
    app.mkdir(exist_ok=True)
    with (app / "Info.plist").open("wb") as stream:
        plistlib.dump(dict(CFBundleIdentifier=BUNDLE_ID, CFBundleExecutable="LoadCheck",
            CFBundleName="Video Load Check", CFBundlePackageType="APPL", CFBundleVersion="1",
            CFBundleShortVersionString="1.0", MinimumOSVersion="16.0", UIDeviceFamily=[1, 2], UILaunchScreen={}), stream)
    sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path")
    arch = "arm64" if platform.machine() == "arm64" else "x86_64"
    run("xcrun", "swiftc", "-O", "-sdk", sdk, "-target", f"{arch}-apple-ios16.0-simulator",
        "-parse-as-library", str(swift), "-o", str(app / "LoadCheck"))
    run("codesign", "--force", "--sign", "-", str(app))
    devices = json.loads(run("xcrun", "simctl", "list", "devices", "available", "-j"))["devices"]
    device = next(d for group in devices.values() for d in group if d["state"] == "Booted" and "iPhone" in d["name"])
    udid = device["udid"]
    run("xcrun", "simctl", "install", udid, str(app))
    container = Path(run("xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data"))
    report_file = container / "Documents/report.json"
    report_file.unlink(missing_ok=True)
    run("xcrun", "simctl", "launch", udid, BUNDLE_ID)
    for _ in range(60):
        if report_file.exists():
            break
        time.sleep(1)
    report = json.loads(report_file.read_text())
    shutil.copy2(report_file, OUTPUT / "report.json")
    print(json.dumps(report, indent=2), flush=True)
    run("xcrun", "simctl", "io", udid, "screenshot", str(OUTPUT / "comments-at-end.png"))
    if report["failures"]:
        raise SystemExit("Video load checks failed: " + ", ".join(report["failures"]))


if __name__ == "__main__":
    main()
