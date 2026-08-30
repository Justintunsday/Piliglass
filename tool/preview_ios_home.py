"""Render the production home views with offline fixtures on an iOS simulator.

Run on macOS with Xcode: python3 tool/preview_ios_home.py
This checks layout only; the regular iOS workflow builds the complete app.
"""

import json
from pathlib import Path
import platform
import plistlib
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "build" / "home-preview"
BUNDLE_ID = "dev.piliglass.homepreview"


def run(*args):
    return subprocess.check_output(args, text=True).strip()


FIXTURES = r'''
import SwiftUI
import UIKit

private let piliAccent = Color(red: 0.93, green: 0.29, blue: 0.48)
private struct PiliNativeVideo: Identifiable {
  let id: Int
  var cover: String? { String(id) }
  var title: String { ["城市漫游：发现身边的美好", "山海之间，记录旅途的风景", "和你分享今天的新发现"][id % 3] }
  let owner = "PiliGlass 布局预览"
  let viewText = "12.8万"
  let danmakuText = "256"
  let durationText = "08:24"
}
private struct PiliNativeLiveRoom: Identifiable {
  let id: Int
  var cover: String? { String(id) }
  let title = "一起看看今天的风景"
  let owner = "直播预览"
  let area = "生活"
  let viewText = "1.2万"
}
private struct PreviewAccount {
  let isLogin = true
  let face: String? = "0"
}
private final class PiliNativeViewModel: ObservableObject {
  let playbackSource = "auto"
  let automaticPlaybackSource: String? = "ali"
  let playbackSources = [
    PiliNativePlaybackSourceOption(value: "auto", label: "自动（选择延迟最低的线路）", latencyMS: nil, latencyState: "untested"),
    PiliNativePlaybackSourceOption(value: "baseUrl", label: "基础URL（不推荐）", latencyMS: 240, latencyState: "ok"),
    PiliNativePlaybackSourceOption(value: "backupUrl", label: "备用URL", latencyMS: 130, latencyState: "ok"),
    PiliNativePlaybackSourceOption(value: "ali", label: "ali（阿里云）", latencyMS: 42, latencyState: "ok"),
    PiliNativePlaybackSourceOption(value: "cos", label: "cos（腾讯云）", latencyMS: 66, latencyState: "ok"),
    PiliNativePlaybackSourceOption(value: "hw", label: "hw（华为云，融合CDN）", latencyMS: nil, latencyState: "timeout"),
    PiliNativePlaybackSourceOption(value: "akamai", label: "akamai（Akamai海外）", latencyMS: nil, latencyState: "unavailable"),
  ]
  let playbackSourceSaving = false, playbackLatencyTesting = false
  let playbackLatencyError: String? = nil
  let playbackSourceError: String? = nil
  let playbackSourceMessage: String? = nil
  let settingsError: String? = nil
  let liveCDN = ""
  let settings = [PreviewSetting(key: "disableAudioCDN", value: false)]
  func setPlaybackSource(_ value: String) {}
  func testPlaybackSources(force: Bool = false) {}
  func setLiveCDN(_ value: String) {}
  func setSetting(_ key: String, value: Bool) {}
  @Published var selectedIndex = 0
  @Published var isSearchPresented = false
  @Published var isMessagesPresented = false
  let account = PreviewAccount()
  let tabTitles = ["首页", "动态", "我的"]
  let homeVideos = (0..<30).map { PiliNativeVideo(id: $0) }
  let hotVideos = (30..<60).map { PiliNativeVideo(id: $0) }
  let liveRooms = (0..<30).map { PiliNativeLiveRoom(id: $0) }
  let homeLoading = false, hotLoading = false, liveLoading = false
  let homeLoadingMore = false, hotLoadingMore = false, liveLoadingMore = false
  let homeError: String? = nil
  let hotError: String? = nil
  let liveError: String? = nil
  func userSelectedTab(_ index: Int) { selectedIndex = index }
  func loadHomeZone(_ zone: String, refresh: Bool = false) {}
  func loadMoreHomeZone(_ zone: String) {}
  func refresh(_ section: String) {}
  func loadMore(_ section: String) {}
  func openVideo(_ video: PiliNativeVideo) {}
  func openLiveRoom(_ room: PiliNativeLiveRoom) {}
}
private struct PiliRemoteImage: View {
  let urlString: String?
  var body: some View {
    let colors: [UIColor] = [.systemTeal, .systemOrange, .systemIndigo, .systemPink]
    let index = Int(urlString ?? "0") ?? 0
    let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 360)).image { context in
      colors[index % colors.count].setFill()
      context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
      UIColor.white.withAlphaComponent(0.25).setFill()
      context.cgContext.fillEllipse(in: CGRect(x: 270, y: -100, width: 460, height: 460))
      UIColor.white.withAlphaComponent(0.3).setFill()
      context.fill(CGRect(x: 0, y: 230, width: 640, height: 130))
    }
    Image(uiImage: image).resizable()
  }
}
private struct PreviewSetting {
  let key: String
  let value: Bool
}
private struct PiliNativeLoadingView: View {
  let title: String
  var body: some View { ProgressView(title) }
}
private struct PiliNativeErrorView: View {
  let message: String
  let retry: () -> Void
  var body: some View { Button(message, action: retry) }
}
'''

APP = r'''
@main
private struct HomePreviewApp: App {
  @StateObject private var model = PiliNativeViewModel()
  var body: some Scene {
    WindowGroup {
      Group {
      if ProcessInfo.processInfo.arguments.contains("--settings") {
        NavigationStack { PiliNativePlaybackSourceSettingsView(model: model) }
      } else {
      TabView(selection: $model.selectedIndex) {
        PiliNativeHomeView(model: model)
          .tabItem { Label("首页", systemImage: "house.fill") }.tag(0)
        Text("动态").tabItem { Label("动态", systemImage: "sparkles") }.tag(1)
        Text("我的").tabItem { Label("我的", systemImage: "person.fill") }.tag(2)
      }
      }
      }
      .tint(piliAccent)
      .environment(\.dynamicTypeSize, ProcessInfo.processInfo.arguments.contains("--large-text") ? .accessibility1 : .large)
      .task {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        inspectLayout()
      }
    }
  }
}

@MainActor
private func inspectLayout() {
  guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
        let window = scene.windows.first(where: { $0.isKeyWindow }) else { return }
  func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap { descendants($0) }
  }
  let views = descendants(window)
  if ProcessInfo.processInfo.arguments.contains("--settings") {
    let report = ["fixture": "Playback settings with simulated latency results"]
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    if let data = try? JSONSerialization.data(withJSONObject: report) {
      try? data.write(to: documents.appendingPathComponent("layout.json"))
    }
    return
  }
  let scrolls = views.compactMap { $0 as? UIScrollView }.filter {
    let frame = $0.convert($0.bounds, to: window)
    return $0.contentSize.height > $0.bounds.height + 100 &&
      frame.intersection(window.bounds).width > window.bounds.width * 0.8
  }
  guard let scroll = scrolls.first,
        let tabBar = views.compactMap({ $0 as? UITabBar }).first else { return }
  let scrollFrame = scroll.convert(scroll.bounds, to: window)
  let barFrame = tabBar.convert(tabBar.bounds, to: window)
  let bottom = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
  let offset = ProcessInfo.processInfo.arguments.contains("--bottom") ? bottom : min(280, bottom)
  scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
  let report: [String: Any] = [
    "scrollFrame": NSCoder.string(for: scrollFrame),
    "tabBarFrame": NSCoder.string(for: barFrame),
    "contentSize": NSCoder.string(for: scroll.contentSize),
    "bottomScrollOffset": bottom,
    "drawsBehindTabBar": scrollFrame.maxY >= barFrame.maxY - 1,
    "scrollOffset": offset,
  ]
  let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
  if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
    try? data.write(to: documents.appendingPathComponent("layout.json"))
  }
}
'''


def main():
    if platform.system() != "Darwin":
        raise SystemExit("The home preview requires macOS and Xcode.")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    source = (ROOT / "ios/Runner/PiliNativeRootViewController.swift").read_text()
    start = source.index("private enum PiliNativeHomeZone:")
    end = source.index("private struct PiliNativeDynamicsView:", start)
    swift = OUTPUT / "HomePreview.swift"
    option_start = source.index("private struct PiliNativePlaybackSourceOption:")
    option_end = source.index("private struct PiliNativeSetting:", option_start)
    settings_start = source.index("private struct PiliNativePlaybackSourceSettingsView:")
    settings_end = source.index("private struct PiliNativeDiagnosticLogSettingsView:", settings_start)
    swift.write_text(FIXTURES + source[start:end] + source[option_start:option_end]
                     + source[settings_start:settings_end] + APP)
    app = OUTPUT / "HomePreview.app"
    app.mkdir(exist_ok=True)
    info = {
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleExecutable": "HomePreview",
        "CFBundleName": "Home Preview",
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1",
        "CFBundleShortVersionString": "1.0",
        "MinimumOSVersion": "16.0",
        "UIDeviceFamily": [1, 2],
        "UILaunchScreen": {},
    }
    with (app / "Info.plist").open("wb") as stream:
        plistlib.dump(info, stream)
    sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path")
    arch = "arm64" if platform.machine() == "arm64" else "x86_64"
    run("xcrun", "swiftc", "-sdk", sdk, "-target", f"{arch}-apple-ios16.0-simulator",
        "-parse-as-library", str(swift), "-o", str(app / "HomePreview"))
    run("codesign", "--force", "--sign", "-", str(app))
    runtimes = json.loads(run("xcrun", "simctl", "list", "runtimes", "-j"))["runtimes"]
    runtime = next(r for r in reversed(runtimes) if r["isAvailable"] and "iOS" in r["name"])
    devices = json.loads(run("xcrun", "simctl", "list", "devices", "available", "-j"))["devices"]
    device = next(d for d in devices[runtime["identifier"]] if "iPhone" in d["name"])
    udid = device["udid"]
    if device["state"] != "Booted":
        run("xcrun", "simctl", "boot", udid)
    run("xcrun", "simctl", "bootstatus", udid, "-b")
    run("xcrun", "simctl", "install", udid, str(app))
    data_dir = Path(run("xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data"))
    report_file = data_dir / "Documents" / "layout.json"
    for name, appearance, args in [
        ("light", "light", []),
        ("dark", "dark", []),
        ("large-text", "light", ["--large-text"]),
        ("last-row", "light", ["--bottom"]),
        ("settings-light", "light", ["--settings"]),
        ("settings-dark", "dark", ["--settings"]),
        ("settings-large-text", "light", ["--settings", "--large-text"]),
    ]:
        subprocess.run(["xcrun", "simctl", "terminate", udid, BUNDLE_ID], capture_output=True)
        report_file.unlink(missing_ok=True)
        run("xcrun", "simctl", "ui", udid, "appearance", appearance)
        run("xcrun", "simctl", "launch", udid, BUNDLE_ID, *args)
        for _ in range(30):
            if report_file.exists():
                break
            time.sleep(1)
        if not report_file.exists():
            raise RuntimeError(f"No layout report for {name}")
        report = json.loads(report_file.read_text())
        report.update(device=device["name"], runtime=runtime["name"])
        (OUTPUT / f"{name}.json").write_text(json.dumps(report, indent=2))
        time.sleep(1)
        run("xcrun", "simctl", "io", udid, "screenshot", str(OUTPUT / f"{name}.png"))
        print(f"{name}: {json.dumps(report)}", flush=True)
        if "drawsBehindTabBar" in report and not report["drawsBehindTabBar"]:
            raise RuntimeError(f"{name}: the feed is clipped above the tab bar")


if __name__ == "__main__":
    main()
