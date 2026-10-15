"""Render the production home views with offline fixtures on an iOS simulator.

Run on macOS with Xcode: python3 tool/preview_ios_home.py
This checks layout only; the regular iOS workflow builds the complete app.
"""

import json
import os
from pathlib import Path
from ios_native_sources import read_native_root
import platform
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "build" / "home-preview"
BUNDLE_ID = "dev.piliglass.homepreview"
LOCALIZATION = (ROOT / "ios/Runner/PiliNativeLocalization.swift").read_text(encoding="utf-8")


def copy_localizations(app):
    for locale in ['en', 'zh-Hans']:
        shutil.copytree(ROOT / f'ios/Runner/{locale}.lproj', app / f'{locale}.lproj', dirs_exist_ok=True)


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def bounded_probe(args, timeout=20):
    try:
        output = subprocess.check_output(args, text=True, timeout=timeout,
                                         stderr=subprocess.DEVNULL)
        return {"status": "ok", "output": output}
    except subprocess.TimeoutExpired:
        return {"status": "timeout", "output": ""}
    except (subprocess.SubprocessError, OSError) as error:
        return {"status": f"failed: {error}", "output": ""}


def bounded_lines(text, limit):
    lines = text.splitlines()
    return "\n".join(lines[-limit:])


def parse_launch_pid(output):
    if ":" in output:
        candidate = output.rsplit(":", 1)[1].strip()
        if candidate.isdigit():
            return candidate
    return ""


def accept_report(report, token, pid, report_mtime, launch_start):
    if not isinstance(report, dict):
        return False
    if report.get("modeToken") != token:
        return False
    if not pid or str(report.get("launchPID", "")) != pid:
        return False
    if report_mtime < launch_start:
        return False
    return True


def accept_current_report(report_file, token, pid, launch_start):
    try:
        if not report_file.exists():
            return None
        report_mtime = report_file.stat().st_mtime
        report = json.loads(report_file.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    if not accept_report(report, token, pid, report_mtime, launch_start):
        return None
    return report


_STREAMS_SUPPORTED = None


def launch_streams_supported():
    global _STREAMS_SUPPORTED
    if _STREAMS_SUPPORTED is None:
        try:
            help_text = subprocess.check_output(
                ["xcrun", "simctl", "help", "launch"], text=True, timeout=20,
                stderr=subprocess.STDOUT)
        except (subprocess.SubprocessError, OSError):
            help_text = ""
        _STREAMS_SUPPORTED = "--stdout" in help_text and "--stderr" in help_text
    return _STREAMS_SUPPORTED


def selftest_report_acceptance():
    now = time.time()
    owned = {"modeToken": "token-a", "launchPID": "4242"}
    cases = [
        ("owned current report", owned, "token-a", "4242", now - 1, now - 2, True),
        ("stale report before launch", owned, "token-a", "4242", now - 5, now - 2, False),
        ("mismatched generation token", owned, "token-b", "4242", now - 1, now - 2, False),
        ("mismatched pid", owned, "token-a", "9999", now - 1, now - 2, False),
        ("missing token", {"launchPID": "4242"}, "token-a", "4242", now - 1, now - 2, False),
        ("missing pid", {"modeToken": "token-a"}, "token-a", "4242", now - 1, now - 2, False),
        ("not a report", [], "token-a", "4242", now - 1, now - 2, False),
    ]
    for label, report, token, pid, mtime, start, expected in cases:
        if accept_report(report, token, pid, mtime, start) != expected:
            raise RuntimeError(f"report acceptance self-test failed: {label}")


def selftest_report_files():
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "layout.json"
        path.write_text(json.dumps({"modeToken": "token-a", "launchPID": "4242"}))
        launch_start = time.time()
        stale = launch_start - 30
        os.utime(path, (stale, stale))
        if accept_current_report(path, "token-a", "4242", launch_start) is not None:
            raise RuntimeError("report acceptance self-test failed: stale file accepted")
        current = time.time()
        os.utime(path, (current, current))
        accepted = accept_current_report(path, "token-a", "4242", launch_start)
        if not accepted or accepted.get("modeToken") != "token-a":
            raise RuntimeError("report acceptance self-test failed: owned report rejected")
        path.write_text(json.dumps({"modeToken": "token-b", "launchPID": "4242"}))
        os.utime(path, (current, current))
        if accept_current_report(path, "token-a", "4242", launch_start) is not None:
            raise RuntimeError("report acceptance self-test failed: mismatched token accepted")


def write_failure_evidence(name, base, udid, diagnostics_file, stdout_file, stderr_file):
    evidence = dict(base)
    if diagnostics_file.exists():
        evidence["diagnostics"] = bounded_lines(
            diagnostics_file.read_text(errors="replace"), 400)
    for label, path in (("stdout", stdout_file), ("stderr", stderr_file)):
        if path.exists():
            evidence[f"{label}Tail"] = bounded_lines(path.read_text(errors="replace"), 200)
    post_probe = bounded_probe(["xcrun", "simctl", "spawn", udid, "launchctl", "list"])
    evidence["postFailureProbe"] = {
        "status": post_probe["status"],
        "instances": [line for line in post_probe["output"].splitlines()
                      if BUNDLE_ID in line or "HomePreview" in line],
    }
    try:
        app_log = subprocess.check_output(
            ["xcrun", "simctl", "spawn", udid, "log", "show", "--last", "2m",
             "--style", "compact", "--predicate", 'process == "HomePreview"'],
            text=True, timeout=90, stderr=subprocess.DEVNULL)
        evidence["appLogTail"] = bounded_lines(app_log, 200)
    except (subprocess.SubprocessError, OSError) as error:
        evidence["appLogError"] = str(error)
    crash_reports = sorted(
        Path.home().glob("Library/Logs/DiagnosticReports/HomePreview*"))
    if crash_reports:
        evidence["crashReportNames"] = [path.name for path in crash_reports[-3:]]
        try:
            evidence["crashLogTail"] = bounded_lines(
                crash_reports[-1].read_text(errors="replace"), 100)
        except OSError as error:
            evidence["crashReadError"] = str(error)
    (OUTPUT / f"{name}-failure.json").write_text(json.dumps(evidence, indent=2))
    return evidence


FIXTURES = r'''
import SwiftUI
import UIKit

private let piliAccent = Color(red: 251.0 / 255, green: 114.0 / 255, blue: 153.0 / 255)
private struct PiliNativeVideo: Identifiable {
  let id: Int
  var cover: String? { String(id) }
  var title: String { ["城市漫游：发现身边的美好", "山海之间，记录旅途的风景", "和你分享今天的新发现"][id % 3] }
  let owner = "PiliGlass 布局预览"
  let viewText = "12.8万"
  let danmakuText = "256"
  let durationText = "08:24"
}
private struct PreviewAccount {
  let isLogin = true
  let face: String? = "0"
}
private final class PiliNativeViewModel: ObservableObject {
  var searchModel: PiliNativeViewModel { self }
  let playbackSource = "auto"
  let automaticPlaybackSource: String? = "ali"
  let playbackSources = [
    PiliNativePlaybackSourceOption(value: "auto", label: "自动（选择下载最快的线路）", speedText: "", latencyState: "untested"),
    PiliNativePlaybackSourceOption(value: "baseUrl", label: "基础URL（不推荐）", speedText: "1.2 MB/s", latencyState: "ok"),
    PiliNativePlaybackSourceOption(value: "backupUrl", label: "备用URL", speedText: "2.8 MB/s", latencyState: "ok"),
    PiliNativePlaybackSourceOption(value: "ali", label: "ali（阿里云）", speedText: "8.6 MB/s", latencyState: "ok"),
    PiliNativePlaybackSourceOption(value: "cos", label: "cos（腾讯云）", speedText: "6.4 MB/s", latencyState: "ok"),
    PiliNativePlaybackSourceOption(value: "hw", label: "hw（华为云，融合CDN）", speedText: "", latencyState: "timeout"),
    PiliNativePlaybackSourceOption(value: "akamai", label: "akamai（Akamai海外）", speedText: "", latencyState: "unavailable"),
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
  @Published var isSettingsPresented = false
  @Published var isMessagesPresented = false
  let account = PreviewAccount()
  let tabTitles = ["首页", "动态", "我的"]
  let homeVideos = (0..<30).map { PiliNativeVideo(id: $0) }
  let homeLoading = false
  let homeLoadingMore = false
  let homeError: String? = nil
  func userSelectedTab(_ index: Int) { selectedIndex = index }
  func refresh(_ section: String) {}
  func loadMore(_ section: String) {}
  func prewarmHomeFirstVideoIfNeeded(_ video: PiliNativeVideo) {}
  func openVideo(_ video: PiliNativeVideo, sourceID: String? = nil) {}
  func openRoute(_ route: String) {}
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
private var previewModeToken: String {
  let arguments = ProcessInfo.processInfo.arguments
  guard let index = arguments.firstIndex(of: "--token"), index + 1 < arguments.count else {
    return ""
  }
  return arguments[index + 1]
}

private func diagnosticsTrace(_ event: String) {
  let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
  let url = documents.appendingPathComponent("layout-diagnostics.jsonl")
  let line = String(format: "%.3f pid=%d %@\n", Date().timeIntervalSince1970,
                    ProcessInfo.processInfo.processIdentifier, event)
  guard let data = line.data(using: .utf8) else { return }
  if let handle = try? FileHandle(forWritingTo: url) {
    handle.seekToEndOfFile()
    handle.write(data)
    try? handle.close()
  } else {
    try? data.write(to: url)
  }
}

@main
private struct HomePreviewApp: App {
  @StateObject private var model = PiliNativeViewModel()
  init() {
    diagnosticsTrace("app-init token=\(previewModeToken) args=\(ProcessInfo.processInfo.arguments.dropFirst().joined(separator: ","))")
  }
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
        // The offline fixture can need longer than one fixed delay on a slow
        // simulator relaunch; a bounded retry keeps the inspection
        // deterministic inside the harness's unchanged per-mode report window
        // instead of silently producing no report at all.
        diagnosticsTrace("task-start")
        for attempt in 0..<8 {
          try? await Task.sleep(nanoseconds: 3_000_000_000)
          if Task.isCancelled {
            diagnosticsTrace("task-cancelled")
            return
          }
          diagnosticsTrace("inspect-attempt \(attempt)")
          if await inspectLayout() {
            diagnosticsTrace("inspect-success \(attempt)")
            return
          }
        }
        diagnosticsTrace("inspect-exhausted")
      }
    }
  }
}

@MainActor
private func inspectLayout() async -> Bool {
  if Task.isCancelled {
    diagnosticsTrace("cancelled-before-inspect")
    return false
  }
  guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
        let window = scene.windows.first(where: { $0.isKeyWindow }) else {
    diagnosticsTrace("window-missing")
    return false
  }
  func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap { descendants($0) }
  }
  let views = descendants(window)
  if ProcessInfo.processInfo.arguments.contains("--settings") {
    let report: [String: Any] = [
      "fixture": "Playback settings with simulated latency results",
      "modeToken": previewModeToken,
      "launchPID": String(ProcessInfo.processInfo.processIdentifier),
    ]
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    diagnosticsTrace("settings-encode-attempt")
    do {
      let data = try JSONSerialization.data(withJSONObject: report)
      try data.write(to: documents.appendingPathComponent("layout.json"))
      diagnosticsTrace("settings-write-ok")
      return true
    } catch {
      diagnosticsTrace("settings-write-fail \(error)")
      return false
    }
  }
  let scrolls = views.compactMap { $0 as? UIScrollView }.filter {
    let frame = $0.convert($0.bounds, to: window)
    return $0.contentSize.height > $0.bounds.height + 100 &&
      frame.intersection(window.bounds).width > window.bounds.width * 0.8
  }
  diagnosticsTrace("hierarchy scrolls=\(scrolls.count)")
  guard let scroll = scrolls.first,
        let tabBar = views.compactMap({ $0 as? UITabBar }).first else {
    diagnosticsTrace("hierarchy-missing")
    return false
  }
  let scrollFrame = scroll.convert(scroll.bounds, to: window)
  let barFrame = tabBar.convert(tabBar.bounds, to: window)
  let navigationBar = views.compactMap { $0 as? UINavigationBar }.first {
    !$0.isHidden && $0.alpha > 0 && $0.bounds.height > 20
  }
  let top = -scroll.adjustedContentInset.top
  let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
  let arguments = ProcessInfo.processInfo.arguments
  let offset: CGFloat
  if arguments.contains("--bottom") {
    offset = bottom
  } else if arguments.contains("--pull-top") {
    offset = top - 72
  } else if arguments.contains("--top") || arguments.contains("--return-top") {
    offset = top
  } else {
    offset = min(280, bottom)
  }
  diagnosticsTrace("pre-scroll current=\(scroll.contentOffset.y) top=\(top) bottom=\(bottom) content=\(scroll.contentSize.height)")
  if arguments.contains("--return-top") {
    scroll.setContentOffset(CGPoint(x: 0, y: min(280, bottom)), animated: false)
    try? await Task.sleep(nanoseconds: 450_000_000)
    if Task.isCancelled {
      diagnosticsTrace("cancelled-after-return-top")
      return false
    }
  }
  scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
  try? await Task.sleep(nanoseconds: 450_000_000)
  if Task.isCancelled {
    diagnosticsTrace("cancelled-after-scroll")
    return false
  }
  diagnosticsTrace("post-scroll actual=\(scroll.contentOffset.y) intended=\(offset) bottom=\(bottom)")
  let report: [String: Any] = [
    "scrollFrame": NSCoder.string(for: scrollFrame),
    "hasNavigationBar": navigationBar != nil,
    "tabBarFrame": NSCoder.string(for: barFrame),
    "contentSize": NSCoder.string(for: scroll.contentSize),
    "topScrollOffset": top,
    "bottomScrollOffset": bottom,
    "drawsBehindTabBar": scrollFrame.maxY >= barFrame.maxY - 1,
    "scrollOffset": offset,
    "modeToken": previewModeToken,
    "launchPID": String(ProcessInfo.processInfo.processIdentifier),
  ]
  let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
  diagnosticsTrace("encode-attempt")
  do {
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: documents.appendingPathComponent("layout.json"))
    diagnosticsTrace("write-ok bytes=\(data.count)")
    return true
  } catch {
    diagnosticsTrace("write-fail \(error)")
    return false
  }
}
'''


def main():
    if platform.system() != "Darwin":
        raise SystemExit("The home preview requires macOS and Xcode.")
    selftest_report_acceptance()
    selftest_report_files()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    source = read_native_root()
    design_start = source.index("private enum PiliNativeDesign")
    design_end = source.index("private extension Notification.Name", design_start)
    start = source.index("private struct PiliNativeHomeView:")
    end = source.index("private struct PiliNativeDynamicsView:", start)
    swift = OUTPUT / "HomePreview.swift"
    option_start = source.index("private struct PiliNativePlaybackSourceOption:")
    option_end = source.index("private struct PiliNativeSetting:", option_start)
    settings_start = source.index("private struct PiliNativePlaybackSourceSettingsView:")
    settings_end = source.index("private struct PiliNativeDiagnosticLogSettingsView:", settings_start)
    navigation_start = source.index("private struct PiliNativePrimaryDestinations:")
    navigation_end = source.index("// MARK: - Root tabs", navigation_start)
    transition_start = source.index("// MARK: - Video transition sources")
    transition_end = source.index("// MARK: - Video presentation transition", transition_start)
    placeholders = '''
private struct PiliNativeSearchView: View {
  @ObservedObject var model: PiliNativeViewModel
  var body: some View { Text("搜索") }
}
private struct PiliNativeSettingsView: View {
  @ObservedObject var model: PiliNativeViewModel
  var body: some View { Text("设置") }
}
'''
    swift.write_text(LOCALIZATION + "\n" + FIXTURES + source[design_start:design_end]
                     + source[transition_start:transition_end]
                     + source[navigation_start:navigation_end] + placeholders
                     + source[start:end] + source[option_start:option_end]
                     + source[settings_start:settings_end] + APP)
    app = OUTPUT / "HomePreview.app"
    app.mkdir(exist_ok=True)
    copy_localizations(app)
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
    diagnostics_file = data_dir / "Documents" / "layout-diagnostics.jsonl"
    launch_trace = []
    streams_supported = launch_streams_supported()
    for name, appearance, args in [
        ("light", "light", []),
        ("dark", "dark", []),
        ("large-text", "light", ["--large-text"]),
        ("last-row", "light", ["--bottom"]),
        ("initial-top", "light", ["--top"]),
        ("returned-top", "light", ["--return-top"]),
        ("returned-top-dark", "dark", ["--return-top"]),
        ("pull-top", "light", ["--pull-top"]),
        ("settings-light", "light", ["--settings"]),
        ("settings-dark", "dark", ["--settings"]),
        ("settings-large-text", "light", ["--settings", "--large-text"]),
    ]:
        subprocess.run(["xcrun", "simctl", "terminate", udid, BUNDLE_ID], capture_output=True)
        report_file.unlink(missing_ok=True)
        diagnostics_file.unlink(missing_ok=True)
        run("xcrun", "simctl", "ui", udid, "appearance", appearance)
        token = uuid.uuid4().hex
        stdout_file = OUTPUT / f"{name}-stdout.txt"
        stderr_file = OUTPUT / f"{name}-stderr.txt"
        stdout_file.unlink(missing_ok=True)
        stderr_file.unlink(missing_ok=True)
        pre_probe = bounded_probe(["xcrun", "simctl", "spawn", udid, "launchctl", "list"])
        pre_launch_instances = [line for line in pre_probe["output"].splitlines()
                                if BUNDLE_ID in line or "HomePreview" in line]
        launch_command = ["xcrun", "simctl", "launch"]
        if streams_supported:
            launch_command += [f"--stdout={stdout_file}", f"--stderr={stderr_file}"]
        launch_command += [udid, BUNDLE_ID, "-AppleLanguages", "(zh-Hans)",
                           "-AppleLocale", "zh_CN", "--token", token, *args]
        launch_start = time.time()
        try:
            completed = subprocess.run(launch_command, capture_output=True, text=True, check=True)
            launch_output = completed.stdout.strip()
        except subprocess.CalledProcessError as error:
            # Bounded diagnostics first, then preserve the hard launch failure:
            # a failed launch must never fall through to the acceptance path.
            trace_entry = {
                "mode": name,
                "appearance": appearance,
                "arguments": args,
                "container": str(data_dir),
                "token": token,
                "streamsSupported": streams_supported,
                "preLaunchProbe": {"status": pre_probe["status"],
                                   "instances": pre_launch_instances},
                "launchFailed": True,
                "launchOutput": error.stdout or "",
                "launchError": str(error),
                "launchStderrTail": bounded_lines(error.stderr or "", 100),
            }
            launch_trace.append(trace_entry)
            (OUTPUT / "launch-trace.json").write_text(json.dumps(launch_trace, indent=2))
            write_failure_evidence(name, trace_entry, udid, diagnostics_file,
                                   stdout_file, stderr_file)
            raise
        launched_pid = parse_launch_pid(launch_output)
        accepted_report = None
        for _ in range(30):
            accepted_report = accept_current_report(report_file, token, launched_pid, launch_start)
            if accepted_report is not None:
                break
            time.sleep(1)
        trace_entry = {
            "mode": name,
            "appearance": appearance,
            "arguments": args,
            "container": str(data_dir),
            "token": token,
            "streamsSupported": streams_supported,
            "preLaunchProbe": {"status": pre_probe["status"],
                               "instances": pre_launch_instances},
            "launchOutput": launch_output,
            "launchedPID": launched_pid,
            "accepted": accepted_report is not None,
            "reportDelaySeconds": round(time.time() - launch_start, 1)
              if accepted_report is not None else None,
            "diagnosticsPresent": diagnostics_file.exists(),
        }
        launch_trace.append(trace_entry)
        (OUTPUT / "launch-trace.json").write_text(json.dumps(launch_trace, indent=2))
        if accepted_report is None:
            # Only an owned, fresh, correctly bound report passes: a stale or
            # mismatched file (or mere existence) is never accepted.
            write_failure_evidence(name, trace_entry, udid, diagnostics_file,
                                   stdout_file, stderr_file)
            raise RuntimeError(f"No layout report for {name}")
        report = accepted_report
        report.update(device=device["name"], runtime=runtime["name"])
        (OUTPUT / f"{name}.json").write_text(json.dumps(report, indent=2))
        time.sleep(1)
        run("xcrun", "simctl", "io", udid, "screenshot", str(OUTPUT / f"{name}.png"))
        print(f"{name}: {json.dumps(report)}", flush=True)
        if "drawsBehindTabBar" in report and not report["drawsBehindTabBar"]:
            raise RuntimeError(f"{name}: the feed is clipped above the tab bar")
        if report.get("hasNavigationBar") is False:
            raise RuntimeError(f"{name}: the home navigation bar is missing")


if __name__ == "__main__":
    main()
