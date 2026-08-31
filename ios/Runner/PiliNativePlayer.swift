import AVFoundation
import AVKit
import AetherEngine
import Combine
import JavaScriptCore
import SwiftUI
import UIKit

final class PiliNativeDiagnosticLog: @unchecked Sendable {
  static let shared = PiliNativeDiagnosticLog()

  private let queue = DispatchQueue(label: "piliglass.native-diagnostic-log")
  private let formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  private var lines: [String] = []
  private var isAetherCaptureInstalled = false
  private let maximumLineCount = 1600

  private init() {}

  func installAetherCapture() {
    let shouldInstall = queue.sync { () -> Bool in
      guard !isAetherCaptureInstalled else { return false }
      isAetherCaptureInstalled = true
      return true
    }
    guard shouldInstall else { return }
    let previousHandler = EngineLog.handler
    EngineLog.handler = { line in
      previousHandler?(line)
      PiliNativeDiagnosticLog.shared.append(line, source: "Aether")
    }
    append("Aether diagnostic capture installed")
  }

  func append(_ message: String, source: String = "PiliGlass") {
    queue.async { [self] in
      let timestamp = formatter.string(from: Date())
      lines.append("\(timestamp) [\(source)] \(message)")
      if lines.count > maximumLineCount {
        lines.removeFirst(lines.count - maximumLineCount)
      }
    }
  }

  func snapshot() -> String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
      ?? "unknown"
    let header = """
    PiliGlass native diagnostic log
    App: \(version) (\(build))
    System: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
    Device: \(UIDevice.current.model)
    Generated: \(ISO8601DateFormatter().string(from: Date()))
    Note: log may contain temporary signed CDN URLs.
    ----------------------------------------------------------------
    """
    let body = queue.sync { lines.joined(separator: "\n") }
    return body.isEmpty ? "\(header)\nNo diagnostic entries." : "\(header)\n\(body)"
  }

  func clear() {
    queue.sync { lines.removeAll(keepingCapacity: true) }
    append("Diagnostic log cleared")
  }
}

// Bilibili's DASH audio is a normal fragmented MP4, but AVPlayer can reject
// the signed CDN URL before decoding it. Feeding Aether a custom seekable byte
// source forces its FFmpeg + AVSampleBufferAudioRenderer path and keeps Range,
// Referer and User-Agent under our control.
private final class PiliNativeHTTPRangeReader: IOReader, @unchecked Sendable {
  private struct FetchResult {
    let data: Data
    let dataStart: Int64
    let contentLength: Int64?
    let statusCode: Int
    let responseHost: String
  }

  private let url: URL
  private let headers: [String: String]
  private let lock = NSLock()
  private let session: URLSession
  private var position: Int64 = 0
  private var contentLength: Int64?
  private var cacheStart: Int64 = 0
  private var cache = Data()
  private var activeTask: URLSessionDataTask?
  private var closed = false

  init(url: URL, headers: [String: String]) {
    self.url = url
    self.headers = headers
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 45
    configuration.waitsForConnectivity = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpMaximumConnectionsPerHost = 2
    session = URLSession(configuration: configuration)
  }

  deinit {
    close()
  }

  func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
    guard let buffer, size > 0 else { return 0 }
    let requestedCount = Int(size)

    while true {
      if let copied = copyCachedBytes(into: buffer, maximumCount: requestedCount) {
        return Int32(copied)
      }

      let offset: Int64? = locked {
        guard !closed else { return nil }
        if let contentLength, position >= contentLength { return nil }
        return position
      }
      guard let offset else { return locked { closed ? -1 : 0 } }

      do {
        let result = try fetchRange(
          start: offset,
          count: max(requestedCount, 1_024 * 1_024)
        )
        locked {
          if let length = result.contentLength { contentLength = length }
          cacheStart = result.dataStart
          cache = result.data
        }
        PiliNativeDiagnosticLog.shared.append(
          "Audio range received status=\(result.statusCode) "
            + "host=\(result.responseHost) offset=\(offset) bytes=\(result.data.count)"
        )
        if result.data.isEmpty { return 0 }
      } catch {
        PiliNativeDiagnosticLog.shared.append(
          "Audio range failed host=\(url.host ?? "unknown") offset=\(offset) "
            + "error=\(error.localizedDescription)"
        )
        return -1
      }
    }
  }

  func seek(offset: Int64, whence: Int32) -> Int64 {
    let operation = whence & ~Int32(0x20000) // Strip FFmpeg's AVSEEK_FORCE.
    if operation == 0x10000 { // AVSEEK_SIZE
      if let known = locked({ contentLength }) { return known }
      guard resolveMetadata() else { return -1 }
      return locked { contentLength ?? -1 }
    }

    var base: Int64
    switch operation {
    case 0: base = 0 // SEEK_SET
    case 1: base = locked { position } // SEEK_CUR
    case 2: // SEEK_END
      if locked({ contentLength }) == nil, !resolveMetadata() { return -1 }
      guard let length = locked({ contentLength }) else { return -1 }
      base = length
    default:
      return -1
    }

    let (target, overflow) = base.addingReportingOverflow(offset)
    guard !overflow, target >= 0 else { return -1 }
    return locked {
      guard !closed else { return -1 }
      position = min(target, contentLength ?? target)
      return position
    }
  }

  func cancel() {
    locked { activeTask }?.cancel()
  }

  func close() {
    let task: URLSessionDataTask? = locked {
      guard !closed else { return nil }
      closed = true
      cache.removeAll(keepingCapacity: false)
      let task = activeTask
      activeTask = nil
      return task
    }
    task?.cancel()
    session.invalidateAndCancel()
  }

  var discImageProbeEnabled: Bool { false }

  private func copyCachedBytes(
    into buffer: UnsafeMutablePointer<UInt8>,
    maximumCount: Int
  ) -> Int? {
    locked {
      guard !closed else { return -1 }
      let relative = position - cacheStart
      guard relative >= 0, relative < Int64(cache.count) else { return nil }
      let available = cache.count - Int(relative)
      let count = min(maximumCount, available)
      cache.copyBytes(
        to: buffer,
        from: Int(relative)..<(Int(relative) + count)
      )
      position += Int64(count)
      return count
    }
  }

  private func resolveMetadata() -> Bool {
    do {
      let result = try fetchRange(start: 0, count: 1)
      locked {
        if let length = result.contentLength { contentLength = length }
        if cache.isEmpty {
          cacheStart = result.dataStart
          cache = result.data
        }
      }
      return locked { contentLength != nil }
    } catch {
      PiliNativeDiagnosticLog.shared.append(
        "Audio metadata failed host=\(url.host ?? "unknown") error=\(error.localizedDescription)"
      )
      return false
    }
  }

  private func fetchRange(start: Int64, count: Int) throws -> FetchResult {
    let end = start + Int64(max(1, count)) - 1
    let rangeHeader = "bytes=\(start)-\(end)"
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 15
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    request.setValue(rangeHeader, forHTTPHeaderField: "Range")

    let semaphore = DispatchSemaphore(value: 0)
    let resultLock = NSLock()
    var responseData: Data?
    var response: HTTPURLResponse?
    var responseError: Error?
    let task = session.dataTask(with: request) { data, urlResponse, error in
      resultLock.lock()
      responseData = data
      response = urlResponse as? HTTPURLResponse
      responseError = error
      resultLock.unlock()
      semaphore.signal()
    }
    let canStart: Bool = locked {
      guard !closed else { return false }
      activeTask = task
      return true
    }
    guard canStart else { throw CancellationError() }
    task.resume()
    semaphore.wait()
    locked {
      if activeTask === task { activeTask = nil }
    }

    resultLock.lock()
    let data = responseData
    let http = response
    let error = responseError
    resultLock.unlock()
    if let error { throw error }
    guard let http else {
      throw NSError(
        domain: "PiliNativeHTTPRangeReader",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "CDN 未返回 HTTP 响应"]
      )
    }

    let total = Self.totalContentLength(http)
      ?? (http.statusCode == 200 && http.expectedContentLength > 0
        ? http.expectedContentLength
        : nil)
    if http.statusCode == 416 {
      return FetchResult(
        data: Data(),
        dataStart: start,
        contentLength: total,
        statusCode: http.statusCode,
        responseHost: http.url?.host ?? url.host ?? "unknown"
      )
    }
    guard (200...299).contains(http.statusCode) else {
      throw NSError(
        domain: "PiliNativeHTTPRangeReader",
        code: http.statusCode,
        userInfo: [NSLocalizedDescriptionKey: "CDN 拒绝音轨请求（HTTP \(http.statusCode)）"]
      )
    }

    return FetchResult(
      data: data ?? Data(),
      // A 200 response ignored Range and therefore starts at byte zero.
      dataStart: http.statusCode == 200 ? 0 : start,
      contentLength: total,
      statusCode: http.statusCode,
      responseHost: http.url?.host ?? url.host ?? "unknown"
    )
  }

  private static func totalContentLength(_ response: HTTPURLResponse) -> Int64? {
    guard let value = response.value(forHTTPHeaderField: "Content-Range"),
          let totalText = value.split(separator: "/").last,
          totalText != "*"
    else { return nil }
    return Int64(totalText)
  }

  private func locked<T>(_ block: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return block()
  }
}

// MARK: - Custom native playback engine

struct PiliNativePlayerSegment {
  let url: URL
  let duration: TimeInterval
  let audioURL: URL?
  let alternativeURLs: [URL]
  let alternativeAudioURLs: [URL]
  let isHDR: Bool
  let qualityValue: Int
  let codec: String

  init(
    url: URL,
    duration: TimeInterval,
    audioURL: URL? = nil,
    alternativeURLs: [URL] = [],
    alternativeAudioURLs: [URL] = [],
    isHDR: Bool = false,
    qualityValue: Int = 0,
    codec: String = ""
  ) {
    self.url = url
    self.duration = duration
    self.audioURL = audioURL
    self.alternativeURLs = alternativeURLs
    self.alternativeAudioURLs = alternativeAudioURLs
    self.isHDR = isHDR
    self.qualityValue = qualityValue
    self.codec = codec
  }

  var videoURLs: [URL] { [url] + alternativeURLs }
  var audioURLs: [URL] {
    guard let audioURL = audioURL else { return alternativeAudioURLs }
    return [audioURL] + alternativeAudioURLs
  }
}

struct PiliNativePlayerQuality: Identifiable, Equatable {
  let value: Int
  let label: String

  var id: Int { value }
}

enum PiliNativeDanmakuProfile: String, Identifiable {
  case simple
  case full
  var id: String { rawValue }

  var title: String { self == .full ? "完整播放器" : "简易播放器" }
}

struct PiliNativeDanmakuSettingsView: View {
  @ObservedObject var session: PiliNativePlayerSession
  var onClose: () -> Void

  private func binding(_ key: WritableKeyPath<PiliNativeDanmakuSettings, Double>) -> Binding<Double> {
    Binding(get: { session.danmakuSettings[keyPath: key] }, set: {
      var settings = session.danmakuSettings
      settings[keyPath: key] = $0
      session.updateDanmakuSettings(settings)
    })
  }

  private func blocked(_ type: Int) -> Binding<Bool> {
    Binding(get: { session.danmakuSettings.blockTypes.contains(type) }, set: { blocked in
      var settings = session.danmakuSettings
      if blocked { settings.blockTypes.insert(type) } else { settings.blockTypes.remove(type) }
      session.updateDanmakuSettings(settings)
    })
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Toggle("显示弹幕", isOn: $session.danmakuEnabled)
        } footer: {
          Text("只影响\(session.danmakuProfile.title)，两套显示与屏蔽设置独立保存。")
        }
        Section {
          Toggle("屏蔽顶部弹幕", isOn: blocked(5))
          Toggle("屏蔽底部弹幕", isOn: blocked(4))
          Toggle("屏蔽滚动弹幕", isOn: blocked(2))
          Toggle("彩色弹幕转白色", isOn: blocked(6))
          Toggle("屏蔽高级弹幕", isOn: blocked(7))
        } header: { Text("按类型筛选") } footer: {
          Text("彩色弹幕保留文字并转为白色，与原版一致。滚动筛选包含逆向弹幕。")
        }
        Section("智能云屏蔽") {
          Text("屏蔽等级：\(Int(session.danmakuSettings.weight))")
          Slider(value: binding(\.weight), in: 0...11, step: 1)
          Text("0 级关闭；等级越高，保留的弹幕越少。")
            .font(.caption).foregroundStyle(.secondary)
        }
        Section("屏蔽规则") {
          NavigationLink {
            PiliNativeDanmakuRulesView(session: session)
          } label: {
            Label("关键词 / 正则 / 用户（\(session.danmakuRules.count)）", systemImage: "line.3.horizontal.decrease.circle")
          }
        }
        Section("显示设置") {
          Text("显示区域：\(Int((session.danmakuSettings.area * 100).rounded()))%")
          Slider(value: binding(\.area), in: 0.25...1, step: 0.25)
          Text("不透明度：\(Int((session.danmakuSettings.opacity * 100).rounded()))%")
          Slider(value: binding(\.opacity), in: 0...1, step: 0.1)
          Text("字体大小：\(Int((session.danmakuSettings.fontScale * 100).rounded()))%")
          Slider(value: binding(\.fontScale), in: 0.5...2.5, step: 0.1)
          Text("滚动时长：\(session.danmakuSettings.duration, specifier: "%.1f") 秒")
          Slider(value: binding(\.duration), in: 1...20, step: 0.5)
        }
        if let error = session.danmakuSettingsError {
          Section {
            Text(error).foregroundStyle(.red)
            Button("重试加载") { session.loadDanmakuSettings() }
            if session.danmakuSettingsLoaded {
              Button("重试保存") { session.updateDanmakuSettings(session.danmakuSettings) }
            }
          }
        }
      }
      .disabled(!session.danmakuSettingsLoaded && session.danmakuSettingsBusy)
      .navigationTitle("\(session.danmakuProfile.title)弹幕设置")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("完成") { session.flushDanmakuSettings(); onClose() }
        }
      }
      .task { if !session.danmakuSettingsLoaded { session.loadDanmakuSettings() } }
      .onDisappear { session.flushDanmakuSettings() }
    }
  }
}

private struct PiliNativeDanmakuRulesView: View {
  @ObservedObject var session: PiliNativePlayerSession
  @State private var type = 0
  @State private var editing: PiliNativeDanmakuRule?
  @State private var deleting: PiliNativeDanmakuRule?
  @State private var showsEditor = false
  private let labels = ["关键词", "正则", "用户"]

  var body: some View {
    List {
      Picker("规则类型", selection: $type) {
        ForEach(0..<3) { index in
          Text("\(labels[index])(\(session.danmakuRules.filter { $0.type == index }.count))").tag(index)
        }
      }.pickerStyle(.segmented)
      Section {
        let rules = session.danmakuRules.filter { $0.type == type }
        if rules.isEmpty { Text("暂无规则，点击右上角添加").foregroundStyle(.secondary) }
        ForEach(rules) { rule in
          VStack(alignment: .leading, spacing: 4) {
            Text(rule.filter).textSelection(.enabled)
            Text(rule.id < 0 ? "本地规则" : "账号规则")
              .font(.caption).foregroundStyle(.secondary)
          }
          .swipeActions {
            Button("删除", role: .destructive) { deleting = rule }
            if rule.type != 2 {
              Button("编辑") { editing = rule; showsEditor = true }.tint(.blue)
            }
          }
          .contextMenu {
            if rule.type != 2 { Button("编辑") { editing = rule; showsEditor = true } }
            Button("删除", role: .destructive) { deleting = rule }
          }
        }
      } footer: {
        Text(type == 2 ? "添加时输入用户 UID；列表展示用于匹配弹幕发送者的 CRC32 哈希。" : "关键词区分大小写；正则忽略大小写，无需输入首尾斜线。")
      }
      Section {
        Button("同步账号屏蔽规则") { session.performDanmakuSettings(["action": "sync"]) }
          .disabled(!session.danmakuAccountLoggedIn)
        Text("同步会刷新账号规则，保留本地规则。未登录时仍可管理本地规则。")
          .font(.caption).foregroundStyle(.secondary)
        if session.danmakuSettingsBusy { ProgressView() }
        if let error = session.danmakuSettingsError { Text(error).foregroundStyle(.red) }
      }
    }
    .disabled(session.danmakuSettingsBusy)
    .navigationTitle("弹幕屏蔽规则")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button { editing = nil; showsEditor = true } label: { Image(systemName: "plus") }
          .accessibilityLabel("添加屏蔽规则")
          .disabled(session.danmakuSettingsBusy)
      }
    }
    .sheet(isPresented: $showsEditor) {
      PiliNativeDanmakuRuleEditor(session: session, type: type, editing: editing)
    }
    .alert("确定删除该规则？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
      Button("取消", role: .cancel) { deleting = nil }
      if let rule = deleting {
        Button("删除", role: .destructive) {
          session.performDanmakuSettings(["action": "delete", "id": rule.id])
          deleting = nil
        }
      }
    }
  }
}

private struct PiliNativeDanmakuRuleEditor: View {
  @ObservedObject var session: PiliNativePlayerSession
  let type: Int
  let editing: PiliNativeDanmakuRule?
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""
  @State private var cloud = false
  @State private var validationError: String?

  var body: some View {
    NavigationStack {
      Form {
        TextField(type == 2 ? "用户 UID" : (type == 1 ? "正则表达式" : "关键词"), text: $text, axis: .vertical)
          .keyboardType(type == 2 ? .numberPad : .default)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
        if editing == nil {
          Toggle("保存到账号", isOn: $cloud).disabled(!session.danmakuAccountLoggedIn)
        }
        if let error = validationError ?? session.danmakuSettingsError { Text(error).foregroundStyle(.red) }
        if session.danmakuSettingsBusy { ProgressView() }
      }
      .navigationTitle(editing == nil ? "添加屏蔽规则" : "编辑屏蔽规则")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(session.danmakuSettingsBusy) }
        ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).disabled(session.danmakuSettingsBusy) }
      }
      .interactiveDismissDisabled(session.danmakuSettingsBusy)
      .onAppear {
        text = editing?.filter ?? ""
        cloud = editing.map { $0.id >= 0 } ?? session.danmakuAccountLoggedIn
        session.danmakuSettingsError = nil
      }
    }
  }

  private func save() {
    var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if type == 1, value.count > 1, value.hasPrefix("/"), value.hasSuffix("/") {
      value = String(value.dropFirst().dropLast())
    }
    guard !value.isEmpty else { validationError = "输入内容不能为空"; return }
    // Dart validates the ECMAScript pattern before persisting or calling the
    // server. ICU/NSRegularExpression would reject some valid Dart patterns.
    validationError = nil
    var args: [String: Any] = ["action": editing == nil ? "add" : "edit", "type": type, "filter": value, "cloud": cloud]
    if let editing { args["id"] = editing.id }
    session.performDanmakuSettings(args) { success in if success { dismiss() } }
  }
}

struct PiliNativeDanmakuRule: Identifiable, Equatable {
  let id: Int
  let type: Int
  let filter: String

  init?(map: [String: Any]) {
    guard let id = map["id"] as? Int, let type = map["type"] as? Int,
          (0...2).contains(type), let filter = map["filter"] as? String,
          !filter.isEmpty else { return nil }
    self.id = id
    self.type = type
    self.filter = filter
  }
}

struct PiliNativeDanmakuSettings {
  // Same identifiers as PiliPala/PiliPlus, not the former native button indices.
  var blockTypes = Set<Int>()
  var enabled = true
  var weight = 0.0
  var area = 0.5
  var opacity = 1.0
  var fontScale = 1.0
  var duration = 7.0
  let strokeWidth = 0.0

  init() {}

  init(map: [String: Any]) {
    blockTypes = Set(map["blockTypes"] as? [Int] ?? [])
    enabled = (map["enabled"] as? Bool) ?? true
    func number(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
      guard let value = map[key] as? NSNumber, value.doubleValue.isFinite else { return fallback }
      return min(max(value.doubleValue, range.lowerBound), range.upperBound)
    }
    weight = number("weight", 0, 0...11).rounded()
    area = number("area", 0.5, 0.25...1)
    opacity = number("opacity", 1, 0...1)
    fontScale = number("fontScale", 1, 0.5...2.5)
    duration = number("duration", 7, 1...20)
  }

  var arguments: [String: Any] {
    ["action": "save", "enabled": enabled, "blockTypes": blockTypes.sorted(), "weight": Int(weight),
     "area": area, "opacity": opacity, "fontScale": fontScale,
     "duration": duration, "strokeWidth": strokeWidth]
  }

  func blocks(mode: Int, weight: Int) -> Bool {
    if weight < Int(self.weight) { return true }
    switch mode {
    case 1, 2, 3, 6: return blockTypes.contains(2)
    case 4: return blockTypes.contains(4)
    case 5: return blockTypes.contains(5)
    case 7: return blockTypes.contains(7)
    default: return true // Code/BAS payloads cannot be rendered as plain text.
    }
  }
}

/// Compiled once per rules update and applied on the serial buffer queue,
/// before merging: a blocked sender must not absorb an allowed sender's text.
private struct PiliNativeDanmakuRuleFilter {
  let keywords: [String]
  let expressions: [JSValue]
  let users: Set<String>
  private let context: JSContext?

  init(_ rules: [PiliNativeDanmakuRule] = []) {
    keywords = rules.filter { $0.type == 0 }.map(\.filter)
    users = Set(rules.filter { $0.type == 2 }.map { $0.filter.lowercased() })
    let regexRules = rules.filter { $0.type == 1 }
    let runtime = regexRules.isEmpty ? nil : JSContext()
    context = runtime
    expressions = regexRules.compactMap {
      var pattern = $0.filter
      if pattern.count > 1, pattern.hasPrefix("/"), pattern.hasSuffix("/") {
        pattern = String(pattern.dropFirst().dropLast())
      }
      guard !pattern.isEmpty else { return nil }
      // Pass user input as data, never interpolate it into JavaScript source.
      runtime?.exception = nil
      let expression = runtime?.objectForKeyedSubscript("RegExp")?.construct(withArguments: [pattern, "i"])
      guard runtime?.exception == nil, let expression, !expression.isUndefined else { return nil }
      return expression
    }
  }

  func removes(_ item: PiliNativeDanmakuItem) -> Bool {
    if users.contains(item.midHash.lowercased()) { return true }
    let content = item.content
    return keywords.contains { content.contains($0) } || expressions.contains {
      $0.invokeMethod("test", withArguments: [content])?.toBool() == true
    }
  }
}

struct PiliNativeDanmakuItem: Identifiable {
  let id: String
  let progress: TimeInterval
  let mode: Int
  let fontSize: CGFloat
  let color: UIColor
  let content: String
  let weight: Int
  var midHash = ""
  var mergeCount = 1

  var displayContent: String {
    mergeCount > 1 ? "\(content)  ×\(mergeCount)" : content
  }
}

/// Confined to the session's serial worker queue. Never sort or normalize a
/// complete segment on the UI thread.
private final class PiliNativeDanmakuBuffer {
  private var rawItems: [PiliNativeDanmakuItem] = []
  private var ids = Set<String>()
  var settings = PiliNativeDanmakuSettings()
  var filter = PiliNativeDanmakuRuleFilter()
  private var rules: [PiliNativeDanmakuRule] = []

  func update(settings: PiliNativeDanmakuSettings, rules: [PiliNativeDanmakuRule]) {
    self.settings = settings
    if self.rules != rules {
      self.rules = rules
      filter = PiliNativeDanmakuRuleFilter(rules)
    }
  }

  func append(_ items: [PiliNativeDanmakuItem]) -> [PiliNativeDanmakuItem]? {
    let incoming = items.filter { ids.insert($0.id).inserted }
    guard !incoming.isEmpty else { return nil }
    rawItems.append(contentsOf: incoming)
    return rebuild()
  }

  func rebuild() -> [PiliNativeDanmakuItem] {
    let sorted = rawItems.filter {
      !settings.blocks(mode: $0.mode, weight: $0.weight) && !filter.removes($0)
    }.sorted { lhs, rhs in
      lhs.progress == rhs.progress ? lhs.weight > rhs.weight : lhs.progress < rhs.progress
    }
    var merged: [PiliNativeDanmakuItem] = []
    merged.reserveCapacity(sorted.count)
    var latestOrdinaryIndex: [String: Int] = [:]
    for var item in sorted {
      // Advanced/code payloads must retain their own timing and coordinates.
      guard (1...6).contains(item.mode) else {
        merged.append(item)
        continue
      }
      let normalized = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
      guard !normalized.isEmpty else { continue }
      let modeGroup = (4...6).contains(item.mode) ? item.mode : 1
      let key = "\(modeGroup)|\(normalized)"
      if let index = latestOrdinaryIndex[key], item.progress - merged[index].progress <= 1.5 {
        merged[index].mergeCount += max(1, item.mergeCount)
      } else {
        item.mergeCount = max(1, item.mergeCount)
        latestOrdinaryIndex[key] = merged.count
        merged.append(item)
      }
    }
    return merged
  }
}

// Native preferences intentionally do not reuse obsolete Flutter player keys.
enum PiliNativePlayerPreferences {
  static let autoplayKey = "pili.native.player.autoplay"
  static let defaultRateKey = "pili.native.player.defaultRate"
  static let doubleTapKey = "pili.native.player.doubleTapPause"
  static let holdSpeedKey = "pili.native.player.holdDoubleSpeed"
  static let lockKey = "pili.native.player.showLock"
  static let statusKey = "pili.native.player.showStatus"
  static let hideDelayKey = "pili.native.player.hideDelay"
  static let relatedKey = "pili.native.detail.showRelated"
  static let expandIntroKey = "pili.native.detail.expandIntro"

  private static func enabled(_ key: String) -> Bool {
    (UserDefaults.standard.object(forKey: key) as? Bool) ?? true
  }
  static var autoplay: Bool { enabled(autoplayKey) }
  static var doubleTapPause: Bool { enabled(doubleTapKey) }
  static var holdDoubleSpeed: Bool { enabled(holdSpeedKey) }
  static var showLock: Bool { enabled(lockKey) }
  static var showStatus: Bool { enabled(statusKey) }
  static var defaultRate: Float {
    let rate = (UserDefaults.standard.object(forKey: defaultRateKey) as? Double) ?? 1
    return [0.75, 1, 1.25, 1.5, 2].contains(rate) ? Float(rate) : 1
  }
  static var hideDelay: Double {
    let delay = (UserDefaults.standard.object(forKey: hideDelayKey) as? Double) ?? 3
    return [3, 5, 8].contains(delay) ? delay : 3
  }
}

@MainActor
final class PiliNativePlayerSession: NSObject, ObservableObject {
  @Published private(set) var isReady = false
  @Published private(set) var isPlaying = false
  @Published private(set) var isBuffering = false
  @Published private(set) var currentTime: TimeInterval = 0
  @Published private(set) var duration: TimeInterval = 0
  @Published private(set) var errorMessage: String?
  @Published private(set) var qualityLabel = "清晰度"
  @Published private(set) var qualities: [PiliNativePlayerQuality] = []
  @Published private(set) var danmakuRevision = 0
  @Published var danmakuEnabled = true {
    didSet {
      guard danmakuSettingsLoaded, danmakuSettings.enabled != danmakuEnabled else { return }
      var settings = danmakuSettings
      settings.enabled = danmakuEnabled
      updateDanmakuSettings(settings)
    }
  }
  @Published var isFullscreen = false {
    didSet {
      if isFullscreen != oldValue {
        endTemporaryDoubleSpeed()
        activateDanmakuProfile(isFullscreen ? .full : .simple)
      }
    }
  }
  @Published var fullscreenCommentsVisible = false
  @Published private(set) var playbackRate: Float = 1
  @Published private(set) var temporaryDoubleSpeedActive = false
  private var playbackRateBeforeHold: Float?
  @Published private(set) var isHDR = false
  @Published private(set) var hdrBrightnessActive = false
  @Published private(set) var videoTitle = "正在播放"
  @Published private(set) var videoLikeCount = 0
  @Published private(set) var videoReplyCount = 0
  @Published private(set) var videoFavoriteCount = 0
  @Published private(set) var videoShareCount = 0
  @Published private(set) var videoOwnerName = ""
  @Published private(set) var videoOwnerFaceURL = ""
  @Published private(set) var videoIsVertical = false
  @Published private(set) var danmakuStatusMessage: String?
  @Published private(set) var danmakuComposerRequest = 0
  @Published private(set) var danmakuSettings = PiliNativeDanmakuSettings()
  @Published private(set) var danmakuProfile: PiliNativeDanmakuProfile = .simple
  @Published private(set) var danmakuRules: [PiliNativeDanmakuRule] = []
  @Published private(set) var danmakuSettingsBusy = false
  @Published private(set) var danmakuSettingsLoaded = false
  @Published private(set) var danmakuAccountLoggedIn = false
  private var danmakuRulesOwner = "guest"
  @Published var danmakuSettingsError: String?
  private var danmakuSettingsVersion = 0
  private var danmakuSaveTask: DispatchWorkItem?
  private var danmakuConfigurationRequest = 0
  private var danmakuFilterRevision = 0

  @Published private(set) var pictureInPicturePlayer: AVPlayer?

  let engine: AetherEngine
  private let audioEngine: AetherEngine
  var onDanmakuSegmentNeeded: ((Int) -> Void)?
  var onQualityRequested: ((Int, TimeInterval) -> Void)?
  var onDanmakuSendRequested: ((String, Int) -> Void)?
  var onVideoActionRequested: ((String) -> Void)?
  var onDanmakuSettingsRequested: (([String: Any], @escaping ([String: Any]) -> Void) -> Void)?

  private(set) var danmakuItems: [PiliNativeDanmakuItem] = []
  private let danmakuQueue = DispatchQueue(label: "dev.piliglass.danmaku", qos: .userInitiated)
  private var danmakuBuffer = PiliNativeDanmakuBuffer()
  private(set) var danmakuGeneration = UUID()
  private var segments: [PiliNativePlayerSegment] = []
  private var segmentOffsets: [TimeInterval] = []
  private var requestedDanmakuSegments = Set<Int>()
  private var engineCancellables = Set<AnyCancellable>()
  private var audioEngineCancellables = Set<AnyCancellable>()
  private var videoItemReady = false
  private var audioItemReady = true
  private var hasAudioTrack = false
  private var isCorrectingAudioTime = false
  private var lastAudioCorrectionHostTime: CFTimeInterval = 0
  private var shouldAutoplay = true
  private var pendingAudioSeek: TimeInterval?
  private var itemBuildGeneration = UUID()
  private var loadTask: Task<Void, Never>?
  private var activeSegmentIndex = 0
  private var isTryingVideoCandidates = false
  private weak var videoSurface: AetherPlayerView?

  private let requestHeaders = [
    "Accept": "*/*",
    "Accept-Encoding": "identity",
    "Referer": "https://www.bilibili.com/",
    "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
  ]

  override init() {
    PiliNativeDiagnosticLog.shared.installAetherCapture()
    do {
      engine = try AetherEngine()
      audioEngine = try AetherEngine()
    } catch {
      fatalError("AetherEngine 初始化失败：\(error.localizedDescription)")
    }
    super.init()
    engine.videoGravity = .resizeAspect
    PiliNativeDiagnosticLog.shared.append("Native player session initialised")
    installObservers()
  }

  convenience init(settingsProfile: PiliNativeDanmakuProfile) {
    self.init()
    danmakuProfile = settingsProfile
  }

  deinit {
    loadTask?.cancel()
  }

  func bindVideoSurface(_ surface: AetherPlayerView) {
    videoSurface = surface
    engine.bind(view: surface)
  }

  func unbindVideoSurface(_ surface: AetherPlayerView) {
    engine.unbind(view: surface)
    if videoSurface === surface { videoSurface = nil }
  }

  private func rebindVideoSurface() {
    guard let videoSurface else { return }
    engine.bind(view: videoSurface)
  }

  func configure(
    segments: [PiliNativePlayerSegment],
    durationMilliseconds: Int,
    quality: String,
    qualities: [PiliNativePlayerQuality],
    resumeAt: TimeInterval = 0,
    autoplay: Bool = true
  ) {
    guard !segments.isEmpty else {
      fail("没有可播放的视频地址")
      return
    }
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      // Playback can still work when another audio session owns the category.
    }

    self.segments = segments
    self.qualityLabel = quality
    self.qualities = qualities
    isHDR = segments.contains(where: { $0.isHDR })
    hdrBrightnessActive = false
    shouldAutoplay = autoplay
    errorMessage = nil
    isReady = false
    isBuffering = true
    segmentOffsets = []
    var offset: TimeInterval = 0
    for segment in segments {
      segmentOffsets.append(offset)
      offset += max(0, segment.duration)
    }
    let declaredDuration = Double(durationMilliseconds) / 1000
    duration = declaredDuration > 0 ? declaredDuration : offset
    PiliNativeDiagnosticLog.shared.append(
      "Playback configure quality=\(quality) segments=\(segments.count) "
        + "durationMs=\(durationMilliseconds) autoplay=\(autoplay)"
    )
    for (index, segment) in segments.enumerated() {
      let videoHosts = Set(segment.videoURLs.compactMap(\.host)).sorted().joined(separator: ",")
      let audioHosts = Set(segment.audioURLs.compactMap(\.host)).sorted().joined(separator: ",")
      PiliNativeDiagnosticLog.shared.append(
        "Segment[\(index)] qn=\(segment.qualityValue) codec=\(segment.codec) "
          + "hdr=\(segment.isHDR) videoCandidates=\(segment.videoURLs.count) "
          + "videoHosts=\(videoHosts.isEmpty ? "none" : videoHosts) "
          + "audioCandidates=\(segment.audioURLs.count) "
          + "audioHosts=\(audioHosts.isEmpty ? "none" : audioHosts)"
      )
    }
    loadSegment(at: max(0, resumeAt), autoplay: autoplay)
  }

  func prepareDanmaku() {
    loadDanmakuSettings()
    requestedDanmakuSegments.removeAll()
    danmakuGeneration = UUID()
    danmakuBuffer = PiliNativeDanmakuBuffer()
    danmakuItems.removeAll()
    danmakuRevision += 1
    requestDanmaku(near: currentTime)
  }

  func configureOverlayMetadata(
    title: String,
    like: Int,
    reply: Int,
    favorite: Int = 0,
    share: Int,
    ownerName: String = "",
    ownerFaceURL: String? = nil,
    isVertical: Bool = false
  ) {
    videoTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "正在播放"
      : title
    videoLikeCount = max(0, like)
    videoReplyCount = max(0, reply)
    videoFavoriteCount = max(0, favorite)
    videoShareCount = max(0, share)
    videoOwnerName = ownerName
    videoOwnerFaceURL = ownerFaceURL ?? ""
    videoIsVertical = isVertical
  }

  func requestVideoAction(_ action: String) {
    onVideoActionRequested?(action)
  }

  func toggleFullscreenComments() {
    fullscreenCommentsVisible.toggle()
  }

  func requestDanmakuSend(_ content: String) {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    danmakuStatusMessage = "正在发送弹幕…"
    onDanmakuSendRequested?(trimmed, Int(max(0, currentTime) * 1000))
  }

  func requestDanmakuComposer() {
    danmakuComposerRequest += 1
  }

  func reportDanmakuSendResult(_ message: String, sentContent: String? = nil) {
    if let sentContent, !sentContent.isEmpty {
      appendDanmaku([
        PiliNativeDanmakuItem(
          id: "local-\(UUID().uuidString)",
          progress: currentTime + 0.25,
          mode: 1,
          fontSize: 25,
          color: .white,
          content: sentContent,
          weight: Int.max
        )
      ])
    }
    danmakuStatusMessage = message
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      guard self?.danmakuStatusMessage == message else { return }
      self?.danmakuStatusMessage = nil
    }
  }

  func appendDanmaku(_ items: [PiliNativeDanmakuItem]) {
    guard !items.isEmpty else { return }
    let buffer = danmakuBuffer
    let generation = danmakuGeneration
    let filterRevision = danmakuFilterRevision
    let settings = danmakuSettings
    let rules = danmakuRules
    danmakuQueue.async { [weak self] in
      buffer.update(settings: settings, rules: rules)
      guard let merged = buffer.append(items) else { return }
      DispatchQueue.main.async {
        guard let self, self.danmakuGeneration == generation,
              self.danmakuFilterRevision == filterRevision else { return }
        self.danmakuItems = merged
        self.danmakuRevision += 1
      }
    }
  }

  func loadDanmakuSettings() {
    performDanmakuSettings(["action": "load"])
  }

  private func activateDanmakuProfile(_ profile: PiliNativeDanmakuProfile) {
    guard profile != danmakuProfile else { return }
    // Flush with the old profile before selecting the new one. The request
    // generation below prevents late loads from overwriting the active mode.
    flushDanmakuSettings()
    danmakuSettingsVersion += 1
    danmakuProfile = profile
    danmakuSettingsLoaded = false
    danmakuRules = []
    rebuildDanmaku()
    loadDanmakuSettings()
  }

  func resetDanmakuAccount() {
    danmakuSettingsLoaded = false
    danmakuRules = []
    danmakuAccountLoggedIn = false
    rebuildDanmaku()
    loadDanmakuSettings()
  }

  func performDanmakuSettings(_ arguments: [String: Any], completion: ((Bool) -> Void)? = nil) {
    guard let request = onDanmakuSettingsRequested else { completion?(false); return }
    // Queue a pending save before a load/sync can read an older snapshot.
    flushDanmakuSettings()
    danmakuConfigurationRequest += 1
    let requestID = danmakuConfigurationRequest
    let version = danmakuSettingsVersion
    danmakuSettingsBusy = true
    danmakuSettingsError = nil
    var requestArguments = arguments
    requestArguments["owner"] = danmakuRulesOwner
    requestArguments["profile"] = danmakuProfile.rawValue
    request(requestArguments) { [weak self] result in
      guard let self, requestID == self.danmakuConfigurationRequest else { return }
      self.danmakuSettingsBusy = false
      guard result["state"] as? String == "success" else {
        self.danmakuSettingsError = result["error"] as? String ?? "弹幕设置操作失败，请重试"
        completion?(false)
        return
      }
      self.danmakuAccountLoggedIn = (result["loggedIn"] as? Bool) ?? false
      self.danmakuRulesOwner = result["owner"] as? String ?? "guest"
      if version == self.danmakuSettingsVersion {
        self.danmakuSettings = PiliNativeDanmakuSettings(map: result)
        self.danmakuEnabled = self.danmakuSettings.enabled
      }
      self.danmakuSettingsLoaded = true
      self.danmakuRules = (result["rules"] as? [[String: Any]] ?? []).compactMap { PiliNativeDanmakuRule(map: $0) }
      self.danmakuSettingsError = result["warning"] as? String
      self.rebuildDanmaku()
      completion?(true)
    }
  }

  func updateDanmakuSettings(_ settings: PiliNativeDanmakuSettings) {
    guard danmakuSettingsLoaded else { return }
    danmakuSettingsVersion += 1
    danmakuSettings = settings
    rebuildDanmaku()
    danmakuSaveTask?.cancel()
    let version = danmakuSettingsVersion
    var arguments = settings.arguments
    arguments["profile"] = danmakuProfile.rawValue
    let task = DispatchWorkItem { [weak self] in
      self?.danmakuSaveTask = nil
      self?.onDanmakuSettingsRequested?(arguments) { [weak self] result in
        guard let self, version == self.danmakuSettingsVersion else { return }
        self.danmakuSettingsError = result["state"] as? String == "success"
          ? nil : (result["error"] as? String ?? "弹幕设置保存失败，请重试")
      }
    }
    danmakuSaveTask = task
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: task)
  }

  func flushDanmakuSettings() {
    guard let task = danmakuSaveTask else { return }
    danmakuSaveTask = nil
    task.perform()
    task.cancel()
  }

  private func rebuildDanmaku() {
    danmakuFilterRevision += 1
    let filterRevision = danmakuFilterRevision
    // Do not display an old cached match while the worker refilters it.
    danmakuItems = []
    danmakuRevision += 1
    let buffer = danmakuBuffer
    let generation = danmakuGeneration
    let settings = danmakuSettings
    let rules = danmakuRules
    danmakuQueue.async { [weak self] in
      buffer.update(settings: settings, rules: rules)
      let items = buffer.rebuild()
      DispatchQueue.main.async {
        guard let self, self.danmakuGeneration == generation,
              self.danmakuFilterRevision == filterRevision else { return }
        self.danmakuItems = items
        self.danmakuRevision += 1
      }
    }
  }

  func togglePlayback() {
    if isPlaying {
      pausePlayback()
    } else {
      startPlayback()
    }
  }

  func beginLoading() {
    pausePlayback()
    isReady = false
    isBuffering = true
    errorMessage = nil
    hdrBrightnessActive = false
  }

  func pausePlayback() {
    endTemporaryDoubleSpeed()
    engine.pause()
    audioEngine.pause()
  }

  func seek(to target: TimeInterval, autoplay: Bool? = nil) {
    let bounded = min(max(0, target), max(duration, 0))
    let targetIndex = index(for: bounded)
    let shouldResume = autoplay ?? isPlaying
    if targetIndex != activeSegmentIndex || !isReady {
      loadSegment(at: bounded, autoplay: shouldResume)
      return
    }
    let localTime = max(0, bounded - segmentOffsets[targetIndex])
    pausePlayback()
    isBuffering = true
    let generation = UUID()
    itemBuildGeneration = generation
    Task { [weak self] in
      guard let self else { return }
      await self.engine.seek(to: localTime)
      await self.seekAudio(to: localTime)
      guard self.itemBuildGeneration == generation else { return }
      self.currentTime = bounded
      self.isBuffering = false
      if shouldResume { self.startPlayback() }
    }
  }

  func skip(by interval: TimeInterval) {
    seek(to: currentTime + interval)
  }

  func cyclePlaybackRate() {
    endTemporaryDoubleSpeed()
    let values: [Float] = [1, 1.25, 1.5, 2, 0.75]
    let current = values.firstIndex(where: { abs($0 - playbackRate) < 0.01 }) ?? 0
    setPlaybackRate(values[(current + 1) % values.count])
  }

  func applyDefaultPlaybackRate() {
    endTemporaryDoubleSpeed()
    setPlaybackRate(PiliNativePlayerPreferences.defaultRate)
  }

  private func setPlaybackRate(_ rate: Float) {
    playbackRate = rate
    // Changing speed while paused must not restart either playback engine.
    if isPlaying {
      engine.setRate(rate)
      if hasAudioTrack { audioEngine.setRate(rate) }
    }
  }

  func beginTemporaryDoubleSpeed() {
    guard isReady, isPlaying, playbackRateBeforeHold == nil else { return }
    playbackRateBeforeHold = playbackRate
    temporaryDoubleSpeedActive = true
    setPlaybackRate(2)
  }

  func endTemporaryDoubleSpeed() {
    guard let previousRate = playbackRateBeforeHold else { return }
    playbackRateBeforeHold = nil
    temporaryDoubleSpeedActive = false
    setPlaybackRate(previousRate)
  }

  func selectQuality(_ value: Int) {
    guard qualities.contains(where: { $0.value == value }) else { return }
    onQualityRequested?(value, currentTime)
  }

  func stop() {
    loadTask?.cancel()
    loadTask = nil
    pausePlayback()
    engine.stop()
    hasAudioTrack = false
    audioEngine.stop()
    segments.removeAll()
    segmentOffsets.removeAll()
    requestedDanmakuSegments.removeAll()
    danmakuGeneration = UUID()
    danmakuBuffer = PiliNativeDanmakuBuffer()
    danmakuItems.removeAll()
    danmakuRevision += 1
    isReady = false
    isPlaying = false
    isBuffering = false
    currentTime = 0
    duration = 0
    errorMessage = nil
    isHDR = false
    hdrBrightnessActive = false
    pictureInPicturePlayer = nil
    isTryingVideoCandidates = false
    fullscreenCommentsVisible = false
  }

  func fail(_ message: String) {
    PiliNativeDiagnosticLog.shared.append("Playback failed: \(message)")
    pausePlayback()
    isReady = false
    isBuffering = false
    isPlaying = false
    errorMessage = message
    hdrBrightnessActive = false
  }

  private func installObservers() {
    engine.$state
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        PiliNativeDiagnosticLog.shared.append("Engine state=\(String(describing: state))")
        self?.handleEngineState(state)
      }
      .store(in: &engineCancellables)
    engine.$isBuffering
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] buffering in
        guard let self else { return }
        PiliNativeDiagnosticLog.shared.append("Engine buffering=\(buffering)")
        self.isBuffering = buffering || self.engine.state == .loading
        if buffering {
          self.audioEngine.pause()
        } else {
          self.resumeAudioIfPossible()
        }
      }
      .store(in: &engineCancellables)
    audioEngine.$state
      .receive(on: DispatchQueue.main)
      .sink { [weak self] state in
        PiliNativeDiagnosticLog.shared.append(
          "Audio engine state=\(String(describing: state))"
        )
        guard let self else { return }
        if case .error(let message) = state,
           self.hasAudioTrack,
           !self.isTryingVideoCandidates {
          self.fail("音轨播放失败：\(message)")
        }
      }
      .store(in: &audioEngineCancellables)
    audioEngine.$isBuffering
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] buffering in
        PiliNativeDiagnosticLog.shared.append("Audio engine buffering=\(buffering)")
        if !buffering { self?.resumeAudioIfPossible() }
      }
      .store(in: &audioEngineCancellables)
    engine.clock.$currentTime
      .receive(on: DispatchQueue.main)
      .sink { [weak self] time in self?.updatePlaybackTime(localTime: time) }
      .store(in: &engineCancellables)
    engine.$videoFormat
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] format in
        guard let self else { return }
        PiliNativeDiagnosticLog.shared.append("Video format=\(String(describing: format))")
        let nativeHDR = format != .sdr
        self.isHDR = nativeHDR || self.segments.contains(where: { $0.isHDR })
        self.hdrBrightnessActive = nativeHDR && self.isReady
      }
      .store(in: &engineCancellables)
    engine.$currentAVPlayer
      .receive(on: DispatchQueue.main)
      .sink { [weak self] player in self?.pictureInPicturePlayer = player }
      .store(in: &engineCancellables)
    engine.$hasFirstFrameReadyForDisplay
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] ready in
        guard ready else { return }
        // Re-attach the active renderer after its first real frame arrives. This
        // also repairs a surface that SwiftUI mounted before Aether created the
        // session's AVPlayerLayer/AVSampleBufferDisplayLayer.
        self?.rebindVideoSurface()
      }
      .store(in: &engineCancellables)
  }

  private func handleEngineState(_ state: PlaybackState) {
    switch state {
    case .idle:
      isPlaying = false
    case .loading:
      isPlaying = false
      isBuffering = true
    case .playing:
      isPlaying = true
      isBuffering = false
      resumeAudioIfPossible()
    case .paused:
      isPlaying = false
      audioEngine.pause()
    case .seeking:
      isBuffering = true
      audioEngine.pause()
    case .ended:
      isPlaying = false
      audioEngine.pause()
      let next = activeSegmentIndex + 1
      if next < segments.count {
        loadSegment(index: next, localTime: 0, autoplay: shouldAutoplay)
      }
    case .error(let message):
      if !isTryingVideoCandidates { fail(message) }
    }
  }

  private func loadSegment(at globalTime: TimeInterval, autoplay: Bool) {
    guard !segments.isEmpty else { return }
    let segmentIndex = index(for: globalTime)
    let localTime = max(0, globalTime - segmentOffsets[segmentIndex])
    loadSegment(index: segmentIndex, localTime: localTime, autoplay: autoplay)
  }

  private func loadSegment(index segmentIndex: Int, localTime: TimeInterval, autoplay: Bool) {
    guard segments.indices.contains(segmentIndex) else { return }
    loadTask?.cancel()
    pausePlayback()
    hasAudioTrack = false
    audioEngine.stop()
    isCorrectingAudioTime = false
    lastAudioCorrectionHostTime = 0
    videoItemReady = false
    audioItemReady = true
    pendingAudioSeek = localTime
    shouldAutoplay = autoplay
    activeSegmentIndex = segmentIndex
    isBuffering = true
    isReady = false
    errorMessage = nil
    hdrBrightnessActive = false
    let generation = UUID()
    itemBuildGeneration = generation
    let segment = segments[segmentIndex]
    loadTask = Task { [weak self] in
      guard let self else { return }
      await self.performLoad(
        segment: segment,
        localTime: localTime,
        generation: generation
      )
    }
  }

  private func performLoad(
    segment: PiliNativePlayerSegment,
    localTime: TimeInterval,
    generation: UUID
  ) async {
    var videoLoaded = false
    do {
      // The decoders are independent: prepare DASH audio while the video
      // decoder opens, then join before starting the synchronized clock.
      async let audioLoad: Void = loadAudioTrack(for: segment, localTime: localTime)
      var lastError: Error = PiliNativePlayerBuildError.noPlayableCandidate
      isTryingVideoCandidates = true
      defer { isTryingVideoCandidates = false }
      var loaded = false
      for (candidateIndex, url) in segment.videoURLs.enumerated() {
        guard !Task.isCancelled, itemBuildGeneration == generation else { return }
        do {
          PiliNativeDiagnosticLog.shared.append(
            "Opening video candidate=\(candidateIndex + 1)/\(segment.videoURLs.count) "
              + "host=\(url.host ?? "unknown") codec=\(segment.codec) qn=\(segment.qualityValue)"
          )
          engine.stop(resetDisplayCriteria: false)
          let options = LoadOptions(
            httpHeaders: requestHeaders,
            maxConcurrentSourceRequests: segment.qualityValue >= 120 ? 6 : 4,
            declaredDurationSeconds: segment.duration > 0 ? segment.duration : nil,
            forwardBufferSegments: segment.qualityValue >= 120 ? 12 : 8,
            autoplay: false
          )
          try await engine.load(url: url, startPosition: localTime, options: options)
          PiliNativeDiagnosticLog.shared.append(
            "Video candidate opened host=\(url.host ?? "unknown")"
          )
          rebindVideoSurface()
          loaded = true
          break
        } catch {
          PiliNativeDiagnosticLog.shared.append(
            "Video candidate failed host=\(url.host ?? "unknown") "
              + "error=\(error.localizedDescription)"
          )
          lastError = error
        }
      }
      isTryingVideoCandidates = false
      guard loaded else { throw lastError }
      videoLoaded = true
      guard !Task.isCancelled, itemBuildGeneration == generation else { return }

      // Open the separate DASH audio representation through Aether's dedicated
      // audio-only decoder and our seekable HTTP reader. This keeps the entire
      // audio path away from AVPlayer's rejected remote-asset probe.
      try await audioLoad
      guard !Task.isCancelled, itemBuildGeneration == generation else { return }

      videoItemReady = true
      audioItemReady = true
      finishPreparingIfReady()
    } catch {
      guard !Task.isCancelled, itemBuildGeneration == generation else { return }
      if videoLoaded {
        fail("音轨载入失败：\(error.localizedDescription)")
      } else {
        fail("Aether 视频轨道载入失败：\(error.localizedDescription)")
      }
    }
  }

  private func loadAudioTrack(
    for segment: PiliNativePlayerSegment,
    localTime: TimeInterval
  ) async throws {
    guard !segment.audioURLs.isEmpty else {
      hasAudioTrack = false
      PiliNativeDiagnosticLog.shared.append("No separate audio track in playback response")
      return
    }

    var lastError: Error = PiliNativePlayerBuildError.noPlayableCandidate
    hasAudioTrack = false
    for (candidateIndex, url) in segment.audioURLs.enumerated() {
      guard !Task.isCancelled else { throw CancellationError() }
      do {
        PiliNativeDiagnosticLog.shared.append(
          "Opening Aether audio candidate=\(candidateIndex + 1)/\(segment.audioURLs.count) "
            + "host=\(url.host ?? "unknown")"
        )
        audioEngine.stop(resetDisplayCriteria: false)
        let reader = PiliNativeHTTPRangeReader(url: url, headers: requestHeaders)
        let options = LoadOptions(
          suppressDisplayCriteria: true,
          audioOnly: true,
          declaredDurationSeconds: segment.duration > 0 ? segment.duration : nil,
          autoplay: false
        )
        try await audioEngine.load(
          source: .custom(reader, formatHint: "mp4"),
          startPosition: localTime,
          options: options
        )
        guard !Task.isCancelled else { throw CancellationError() }
        hasAudioTrack = true
        PiliNativeDiagnosticLog.shared.append(
          "Aether audio candidate opened host=\(url.host ?? "unknown") "
            + "backend=\(audioEngine.playbackBackend.rawValue) "
            + "decoder=\(audioEngine.activeAudioDecoder ?? "unknown")"
        )
        return
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        PiliNativeDiagnosticLog.shared.append(
          "Aether audio candidate failed host=\(url.host ?? "unknown") "
            + "error=\(error.localizedDescription)"
        )
        lastError = error
      }
    }
    throw lastError
  }

  private func finishPreparingIfReady() {
    guard videoItemReady, audioItemReady, let localTime = pendingAudioSeek else { return }
    pendingAudioSeek = nil
    Task { [weak self] in
      guard let self else { return }
      await self.seekAudio(to: localTime)
      self.isReady = true
      self.isBuffering = false
      self.errorMessage = nil
      self.hdrBrightnessActive = self.engine.videoFormat != .sdr
      if self.shouldAutoplay { self.startPlayback() }
    }
  }

  private func startPlayback() {
    PiliNativeDiagnosticLog.shared.append("Playback start requested rate=\(playbackRate)")
    engine.setRate(playbackRate)
    engine.play()
    // Audio starts from the engine's actual non-buffering transition. Starting
    // it here made it run ahead while AVPlayer was still evaluating the first
    // video buffer, followed by an audible corrective seek.
  }

  private func resumeAudioIfPossible() {
    guard isReady,
          engine.state == .playing,
          !engine.isBuffering,
          hasAudioTrack,
          audioEngine.state == .paused || audioEngine.state == .playing else { return }
    audioEngine.setRate(playbackRate)
    audioEngine.play()
    PiliNativeDiagnosticLog.shared.append("Audio resumed rate=\(playbackRate)")
  }

  private func updatePlaybackTime(localTime local: TimeInterval) {
    guard isReady, segments.indices.contains(activeSegmentIndex), local.isFinite else { return }
    synchronizeAudio(to: local)
    currentTime = min(max(0, segmentOffsets[activeSegmentIndex] + local), max(duration, 0))
    requestDanmaku(near: currentTime)
  }

  private func synchronizeAudio(to videoTime: TimeInterval) {
    guard !isCorrectingAudioTime,
          isPlaying,
          hasAudioTrack,
          audioEngine.state == .playing else { return }
    let audioTime = audioEngine.currentTime
    let drift = audioTime - videoTime
    let hostTime = CACurrentMediaTime()
    // Small AVPlayer clock differences (especially on Bluetooth routes) are
    // normal. Hard-seeking for every 220 ms discrepancy repeatedly discarded
    // the audio buffer and was heard as stutter. Correct only gross, sustained
    // drift and throttle corrections so the new buffer has time to settle.
    guard audioTime.isFinite,
          abs(drift) > 0.85,
          hostTime - lastAudioCorrectionHostTime > 3 else { return }
    isCorrectingAudioTime = true
    lastAudioCorrectionHostTime = hostTime
    PiliNativeDiagnosticLog.shared.append(
      String(format: "Audio sync correction drift=%+.3fs video=%.3f audio=%.3f", drift, videoTime, audioTime)
    )
    audioEngine.pause()
    Task { [weak self] in
      guard let self else { return }
      await self.audioEngine.seek(to: videoTime)
      self.isCorrectingAudioTime = false
      self.resumeAudioIfPossible()
    }
  }

  private func seekAudio(to time: TimeInterval) async {
    guard hasAudioTrack else { return }
    await audioEngine.seek(to: max(0, time))
  }

  private func requestDanmaku(near time: TimeInterval) {
    let segmentLength: TimeInterval = 6 * 60
    let index = max(0, Int(time / segmentLength))
    requestDanmakuSegment(index)
    if time.truncatingRemainder(dividingBy: segmentLength) > segmentLength - 30 {
      requestDanmakuSegment(index + 1)
    }
  }

  private func requestDanmakuSegment(_ index: Int) {
    guard !requestedDanmakuSegments.contains(index) else { return }
    requestedDanmakuSegments.insert(index)
    onDanmakuSegmentNeeded?(index)
  }

  private func index(for globalTime: TimeInterval) -> Int {
    guard segments.count > 1 else { return 0 }
    for index in segmentOffsets.indices.reversed() where globalTime >= segmentOffsets[index] {
      return index
    }
    return 0
  }

}

private enum PiliNativePlayerBuildError: LocalizedError {
  case missingDashTrack
  case noPlayableCandidate

  var errorDescription: String? {
    switch self {
    case .missingDashTrack: return "视频或音频轨不存在"
    case .noPlayableCandidate: return "所有原始及备用 CDN 均无法打开"
    }
  }
}

// MARK: - UIKit video surface and customizable controls

private final class PiliNativeDanmakuView: UIView {
  private var cursor = 0
  private var lastTime: TimeInterval = -1
  private var lastRevision = -1
  private var scrollingLane = 0
  private var topLane = 0
  private var bottomLane = 0
  private var displayAreaFraction: CGFloat = 0.75
  private var opacityMultiplier: CGFloat = 1
  private var settings = PiliNativeDanmakuSettings()

  private struct AdvancedPayload {
    let x: CGFloat
    let y: CGFloat
    let endX: CGFloat
    let endY: CGFloat
    let startAlpha: CGFloat
    let endAlpha: CGFloat
    let duration: TimeInterval
    let translationDuration: TimeInterval
    let translationDelay: TimeInterval
    let text: String
    let rotationZ: CGFloat
    let rotationY: CGFloat
    let easeIn: Bool
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    clipsToBounds = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  func render(time: TimeInterval, items: [PiliNativeDanmakuItem], revision: Int) {
    if items.isEmpty {
      if !subviews.isEmpty { clear() }
      cursor = 0
      lastTime = time
      lastRevision = revision
      return
    }
    if lastTime < 0 || time < lastTime || time - lastTime > 1.2 {
      reset(at: time, items: items, revision: revision)
    } else if revision != lastRevision {
      // A prefetched segment must not clear animations already on screen.
      cursor = items.partitioningIndex { $0.progress > lastTime + 0.08 }
      lastRevision = revision
    }
    let earliest = max(lastTime, time - 0.25)
    let end = items.partitioningIndex { $0.progress > time + 0.08 }
    // Bound both scanning and UILabel/animation allocation during a burst.
    // Keep the full timeline for seeking, but never queue late animations.
    let start = max(cursor, items.partitioningIndex { $0.progress >= earliest })
    let capacity = max(0, min(8, 60 - subviews.count))
    var displayed = 0
    if start < end, capacity > 0 {
      for index in start..<min(end, start + 160) {
        let item = items[index]
        if shouldBlock(item) { continue }
        display(item)
        displayed += 1
        if displayed >= capacity { break }
      }
    }
    cursor = end
    lastTime = time
  }

  func clear() {
    subviews.forEach { $0.removeFromSuperview() }
    cursor = 0
    lastTime = -1
    lastRevision = -1
  }

  func applySettings(_ settings: PiliNativeDanmakuSettings) {
    self.settings = settings
    displayAreaFraction = CGFloat(settings.area)
    opacityMultiplier = CGFloat(settings.opacity)
    clear()
  }

  private func reset(at time: TimeInterval, items: [PiliNativeDanmakuItem], revision: Int) {
    subviews.forEach { $0.removeFromSuperview() }
    cursor = items.partitioningIndex { $0.progress > time + 0.08 }
    lastTime = time
    lastRevision = revision
    scrollingLane = 0
    topLane = 0
    bottomLane = 0
  }

  private func display(_ item: PiliNativeDanmakuItem) {
    guard bounds.width > 0, bounds.height > 0 else { return }
    if shouldBlock(item) { return }
    if item.mode >= 7 {
      displayAdvanced(item)
      return
    }
    let label = UILabel()
    label.numberOfLines = 1
    let shadow = NSShadow()
    shadow.shadowColor = UIColor.black.withAlphaComponent(0.95)
    shadow.shadowOffset = .zero
    shadow.shadowBlurRadius = 2
    label.attributedText = NSAttributedString(
      string: item.displayContent,
      attributes: [
        .font: UIFont.systemFont(ofSize: 15 * CGFloat(settings.fontScale), weight: .semibold),
        .foregroundColor: settings.blockTypes.contains(6) ? UIColor.white : item.color,
        .strokeColor: UIColor.black,
        .strokeWidth: -settings.strokeWidth,
        .shadow: shadow,
      ]
    )
    label.sizeToFit()
    label.alpha = 0.96 * opacityMultiplier
    addSubview(label)

    let laneHeight = max(25, label.bounds.height + 5)
    let visibleHeight = max(laneHeight, bounds.height * displayAreaFraction)
    let laneCount = max(1, Int((visibleHeight - 12) / laneHeight))
    switch item.mode {
    case 4:
      let lane = bottomLane % max(1, min(laneCount, 3))
      bottomLane += 1
      label.center = CGPoint(
        x: bounds.midX,
        y: visibleHeight - CGFloat(lane) * laneHeight - laneHeight / 2
      )
      fade(label)
    case 5:
      let lane = topLane % max(1, min(laneCount, 3))
      topLane += 1
      label.center = CGPoint(x: bounds.midX, y: 12 + CGFloat(lane) * laneHeight + laneHeight / 2)
      fade(label)
    default:
      let lane = scrollingLane % laneCount
      scrollingLane += 1
      let reverse = item.mode == 6
      label.frame.origin = CGPoint(x: reverse ? -label.bounds.width - 12 : bounds.width + 12, y: 10 + CGFloat(lane) * laneHeight)
      let distance = bounds.width + label.bounds.width + 24
      let duration = settings.duration
      UIView.animate(
        withDuration: duration,
        delay: 0,
        options: [.curveLinear, .allowUserInteraction]
      ) {
        label.transform = CGAffineTransform(translationX: reverse ? distance : -distance, y: 0)
      } completion: { _ in
        label.removeFromSuperview()
      }
    }
  }

  private func displayAdvanced(_ item: PiliNativeDanmakuItem) {
    let payload = parseAdvancedPayload(item.content)
    let text = (payload?.text ?? item.content)
      .replacingOccurrences(of: "/n", with: "\n")
      .replacingOccurrences(of: "\\n", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    let label = UILabel()
    label.numberOfLines = 0
    label.textAlignment = .center
    let shadow = NSShadow()
    shadow.shadowColor = UIColor.black.withAlphaComponent(0.92)
    shadow.shadowOffset = .zero
    shadow.shadowBlurRadius = 2
    label.attributedText = NSAttributedString(
      string: text,
      attributes: [
        .font: UIFont.systemFont(ofSize: max(12, item.fontSize * CGFloat(settings.fontScale)), weight: .semibold),
        .foregroundColor: settings.blockTypes.contains(6) ? UIColor.white : item.color,
        .strokeColor: UIColor.black,
        .strokeWidth: -settings.strokeWidth,
        .shadow: shadow,
      ]
    )
    let maximumSize = CGSize(width: max(80, bounds.width * 0.82), height: max(50, bounds.height * 0.6))
    let fitted = label.sizeThatFits(maximumSize)
    label.bounds.size = CGSize(
      width: min(maximumSize.width, max(1, fitted.width)),
      height: min(maximumSize.height, max(1, fitted.height))
    )

    func center(x: CGFloat, y: CGFloat) -> CGPoint {
      let absoluteX = x * bounds.width
      let absoluteY = y * bounds.height
      return CGPoint(
        x: min(max(label.bounds.width / 2, absoluteX), bounds.width - label.bounds.width / 2),
        y: min(max(label.bounds.height / 2, absoluteY), bounds.height - label.bounds.height / 2)
      )
    }
    label.center = center(x: payload?.x ?? 0.5, y: payload?.y ?? 0.5)
    label.alpha = (payload?.startAlpha ?? 0.96) * opacityMultiplier
    var transform = CATransform3DIdentity
    transform.m34 = -1 / 500
    transform = CATransform3DRotate(transform, (payload?.rotationY ?? 0) * .pi / 180, 0, 1, 0)
    transform = CATransform3DRotate(transform, (payload?.rotationZ ?? 0) * .pi / 180, 0, 0, 1)
    label.layer.transform = transform
    addSubview(label)

    UIView.animate(
      withDuration: payload?.duration ?? 4.5,
      delay: 0,
      options: [.curveLinear, .allowUserInteraction]
    ) {
      label.alpha = (payload?.endAlpha ?? 0.96) * self.opacityMultiplier
    }
    if let payload, payload.x != payload.endX || payload.y != payload.endY {
      UIView.animate(
        withDuration: payload.translationDuration,
        delay: payload.translationDelay,
        options: [payload.easeIn ? .curveEaseIn : .curveLinear, .allowUserInteraction]
      ) {
        label.center = center(x: payload.endX, y: payload.endY)
      }
    }
    let lifetime = max(
      payload?.duration ?? 4.5,
      (payload?.translationDelay ?? 0) + (payload?.translationDuration ?? 0)
    )
    DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) {
      label.removeFromSuperview()
    }
  }

  private func parseAdvancedPayload(_ content: String) -> AdvancedPayload? {
    let normalizedContent = content.replacingOccurrences(of: "\n", with: "\\n")
    guard let data = normalizedContent.data(using: .utf8),
          let values = try? JSONSerialization.jsonObject(with: data) as? [Any],
          values.count >= 5 else { return nil }
    func number(_ index: Int, fallback: Double) -> Double {
      guard values.indices.contains(index) else { return fallback }
      if let value = values[index] as? NSNumber { return value.doubleValue }
      let raw = String(describing: values[index]).replacingOccurrences(of: "%", with: "")
      return Double(raw) ?? fallback
    }
    func relativePair(_ startIndex: Int, _ endIndex: Int, reference: Double) -> (CGFloat, CGFloat) {
      func relative(_ index: Int, fallback: Double) -> Double {
        guard values.indices.contains(index) else { return fallback }
        let rawValue = values[index]
        let parsed = number(index, fallback: fallback)
        if parsed > 1 || (rawValue is String && !String(describing: rawValue).contains(".")) {
          return parsed / reference
        }
        return parsed
      }
      let start = relative(startIndex, fallback: 0)
      let end = values.indices.contains(endIndex)
        ? relative(endIndex, fallback: start)
        : start
      return (CGFloat(start), CGFloat(end))
    }
    let alphaParts = String(describing: values[2]).split(separator: "-")
    let startAlpha = Double(alphaParts.first ?? "1") ?? 1
    let endAlpha = Double(alphaParts.dropFirst().first ?? alphaParts.first ?? "1") ?? startAlpha
    var duration = number(3, fallback: 4.5)
    if duration <= 0 { duration = 4.5 }
    let (startX, endX) = relativePair(0, 7, reference: 1920)
    let (startY, endY) = relativePair(1, 8, reference: 1080)
    let translationMilliseconds = number(9, fallback: duration * 1000)
    let delayMilliseconds = number(10, fallback: 0)
    return AdvancedPayload(
      x: startX,
      y: startY,
      endX: endX,
      endY: endY,
      startAlpha: CGFloat(min(max(startAlpha, 0), 1)),
      endAlpha: CGFloat(min(max(endAlpha, 0), 1)),
      duration: min(max(duration, 0.1), 30),
      translationDuration: min(max(translationMilliseconds / 1000, 0.01), 30),
      translationDelay: min(max(delayMilliseconds / 1000, 0), 30),
      text: String(describing: values[4]),
      rotationZ: CGFloat(number(5, fallback: 0)),
      rotationY: CGFloat(number(6, fallback: 0)),
      easeIn: Int(number(13, fallback: 0)) == 1
    )
  }

  private func shouldBlock(_ item: PiliNativeDanmakuItem) -> Bool {
    settings.blocks(mode: item.mode, weight: item.weight)
  }

  private func fade(_ label: UILabel) {
    UIView.animate(
      withDuration: 0.25,
      delay: 3.6,
      options: [.curveEaseOut, .allowUserInteraction]
    ) {
      label.alpha = 0
    } completion: { _ in
      label.removeFromSuperview()
    }
  }
}

private extension Array {
  func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
    var low = 0
    var high = count
    while low < high {
      let middle = (low + high) / 2
      if predicate(self[middle]) { high = middle } else { low = middle + 1 }
    }
    return low
  }
}

private final class PiliNativePlayerGradientView: UIView {
  override class var layerClass: AnyClass { CAGradientLayer.self }

  func configure(colors: [UIColor], start: CGPoint, end: CGPoint) {
    guard let gradient = layer as? CAGradientLayer else { return }
    gradient.colors = colors.map(\.cgColor)
    gradient.startPoint = start
    gradient.endPoint = end
  }
}

final class PiliNativePlayerViewController: UIViewController, UIGestureRecognizerDelegate {
  private let session: PiliNativePlayerSession
  private let fullscreenPresentation: Bool
  private let canvas = AetherPlayerView()
  private let danmakuView = PiliNativeDanmakuView()
  private let controls = UIView()
  private let embeddedTopShade = PiliNativePlayerGradientView()
  private let embeddedBottomShade = PiliNativePlayerGradientView()
  private let topBar = UIStackView()
  private let bottomBar = UIStackView()
  private let topChrome = PiliNativePlayerGradientView()
  private let bottomChrome = PiliNativePlayerGradientView()
  private let playButton = UIButton(type: .system)
  private let danmakuButton = UIButton(type: .system)
  private let danmakuSettingsButton = UIButton(type: .system)
  private let danmakuInputButton = UIButton(type: .system)
  private let qualityButton = UIButton(type: .system)
  private let speedButton = UIButton(type: .system)
  private let fullscreenButton = UIButton(type: .system)
  private let pipButton = UIButton(type: .system)
  private let backButton = UIButton(type: .system)
  private let lockButton = UIButton(type: .system)
  private let titleLabel = UILabel()
  private let ownerLabel = UILabel()
  private let ownerImageView = UIImageView()
  private let likeLabel = UILabel()
  private let replyLabel = UILabel()
  private let favoriteLabel = UILabel()
  private let shareLabel = UILabel()
  private let menuButton = UIButton(type: .system)
  private let systemTimeLabel = UILabel()
  private let batteryLabel = UILabel()
  private let statusStack = UIStackView()
  private let fullTimeLabel = UILabel()
  private let currentLabel = UILabel()
  private let durationLabel = UILabel()
  private let slider = UISlider()
  private let spinner = UIActivityIndicatorView(style: .large)
  private let errorLabel = UILabel()
  private let toastLabel = UILabel()
  private let speedHoldLabel = UILabel()
  private let danmakuSettingsPanel = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
  private var pictureInPictureController: AVPictureInPictureController?
  private var cancellables = Set<AnyCancellable>()
  private var controlsHideTask: DispatchWorkItem?
  private var statusTimer: Timer?
  private var ownerImageTask: URLSessionDataTask?
  private var wasPlayingBeforeScrub = false
  private var isScrubbing = false
  private var controlsLocked = false
  private var settingsPanelVisible = false
  private var videoSurfaceRevealed = false
  private var surfaceRevealTask: DispatchWorkItem?

  init(session: PiliNativePlayerSession, fullscreen: Bool) {
    self.session = session
    fullscreenPresentation = fullscreen
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
    guard fullscreenPresentation else { return .portrait }
    return session.videoIsVertical ? .portrait : .landscape
  }

  override var prefersStatusBarHidden: Bool { fullscreenPresentation }
  override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

  override func viewDidLoad() {
    super.viewDidLoad()
    buildInterface()
    canvas.backgroundColor = .clear
    canvas.layer.opacity = 0
    bindSession()
    session.bindVideoSurface(canvas)
    NotificationCenter.default.addObserver(
      self, selector: #selector(endSpeedHold),
      name: UIApplication.willResignActiveNotification, object: nil
    )
    if fullscreenPresentation { startSystemStatusUpdates() }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    session.bindVideoSurface(canvas)
    if fullscreenPresentation {
      requestOrientation(session.videoIsVertical ? .portrait : .landscape)
    }
    if fullscreenPresentation, statusTimer == nil { startSystemStatusUpdates() }
    scheduleControlsHide()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // Aether owns a polymorphic CALayer. Rebinding is idempotent and keeps the
    // active layer attached when SwiftUI changes the embedded/fullscreen host.
    session.bindVideoSurface(canvas)
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    endSpeedHold()
    controlsHideTask?.cancel()
    surfaceRevealTask?.cancel()
    statusTimer?.invalidate()
    statusTimer = nil
  }

  func detachVideoSurface() {
    endSpeedHold()
    surfaceRevealTask?.cancel()
    session.unbindVideoSurface(canvas)
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    var touchedAncestor = touch.view
    while let ancestor = touchedAncestor, ancestor !== controls {
      if ancestor is UIControl { return false }
      touchedAncestor = ancestor.superview
    }
    if let touchedView = touch.view, touchedView.isDescendant(of: danmakuSettingsPanel) { return false }
    return true
  }

  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    if gestureRecognizer is UILongPressGestureRecognizer {
      return PiliNativePlayerPreferences.holdDoubleSpeed
        && session.isReady && session.isPlaying && !controlsLocked
        && !settingsPanelVisible && !isScrubbing
    }
    return true
  }

  private func buildInterface() {
    view.backgroundColor = .black
    [canvas, danmakuView, controls, spinner, errorLabel].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview($0)
    }
    NSLayoutConstraint.activate([
      canvas.topAnchor.constraint(equalTo: view.topAnchor),
      canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      danmakuView.topAnchor.constraint(equalTo: view.topAnchor),
      danmakuView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      danmakuView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      danmakuView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      controls.topAnchor.constraint(equalTo: view.topAnchor),
      controls.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      controls.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      controls.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      errorLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
      errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
      errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])

    let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
    tap.cancelsTouchesInView = false
    tap.delegate = self
    controls.addGestureRecognizer(tap)
    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapPlayback(_:)))
    doubleTap.numberOfTapsRequired = 2
    doubleTap.cancelsTouchesInView = false
    doubleTap.delegate = self
    controls.addGestureRecognizer(doubleTap)
    tap.require(toFail: doubleTap)

    let hold = UILongPressGestureRecognizer(target: self, action: #selector(holdDoubleSpeed(_:)))
    hold.minimumPressDuration = 0.35
    hold.allowableMovement = 30
    hold.delegate = self
    controls.addGestureRecognizer(hold)
    tap.require(toFail: hold)
    doubleTap.require(toFail: hold)

    configureButton(playButton, image: "play.fill", action: #selector(togglePlayback))
    configureButton(fullscreenButton, image: fullscreenPresentation ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", action: #selector(toggleFullscreen))
    configureButton(pipButton, image: "pip.enter", action: #selector(togglePictureInPicture))
    pipButton.isHidden = true
    configureButton(backButton, image: "chevron.left", action: #selector(exitFullscreen))
    configureButton(lockButton, image: "lock.open.fill", action: #selector(toggleScreenLock))
    configureButton(danmakuSettingsButton, image: "slider.horizontal.3", action: #selector(toggleDanmakuSettings))
    configureTextButton(danmakuButton, title: "弹幕", action: #selector(toggleDanmaku))
    configureTextButton(qualityButton, title: "清晰度", action: nil)
    configureTextButton(speedButton, title: "1.0x", action: #selector(changeSpeed))
    configureTextButton(
      danmakuInputButton,
      title: "发个友善的弹幕见证当下",
      action: #selector(showDanmakuComposer)
    )

    currentLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    durationLabel.font = currentLabel.font
    currentLabel.textColor = .white
    durationLabel.textColor = .white
    currentLabel.text = "00:00"
    durationLabel.text = "00:00"
    fullTimeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    fullTimeLabel.textColor = .white
    fullTimeLabel.text = "00:00/00:00"
    slider.minimumTrackTintColor = UIColor(red: 0.93, green: 0.29, blue: 0.48, alpha: 1)
    slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.38)
    slider.addTarget(self, action: #selector(scrubStarted), for: .touchDown)
    slider.addTarget(self, action: #selector(scrubChanged), for: .valueChanged)
    slider.addTarget(self, action: #selector(scrubEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    slider.accessibilityLabel = "播放进度"
    playButton.accessibilityLabel = "暂停或播放"
    backButton.accessibilityLabel = "退出播放器"
    lockButton.accessibilityLabel = "锁定播放器"
    danmakuSettingsButton.accessibilityLabel = "弹幕设置"

    if fullscreenPresentation {
      buildFullscreenControls()
    } else {
      buildEmbeddedControls()
    }

    errorLabel.textColor = .white
    errorLabel.font = .systemFont(ofSize: 13, weight: .medium)
    errorLabel.textAlignment = .center
    errorLabel.numberOfLines = 3
    errorLabel.isHidden = true
    spinner.color = .white
    spinner.hidesWhenStopped = true

    toastLabel.translatesAutoresizingMaskIntoConstraints = false
    toastLabel.textColor = .white
    toastLabel.backgroundColor = UIColor.black.withAlphaComponent(0.72)
    toastLabel.font = .systemFont(ofSize: 13, weight: .medium)
    toastLabel.textAlignment = .center
    toastLabel.layer.cornerRadius = 9
    toastLabel.clipsToBounds = true
    toastLabel.isHidden = true
    view.addSubview(toastLabel)
    NSLayoutConstraint.activate([
      toastLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      toastLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 54),
      toastLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
      toastLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.7),
    ])
    speedHoldLabel.translatesAutoresizingMaskIntoConstraints = false
    speedHoldLabel.text = "  ▶▶  2× 倍速播放中  "
    speedHoldLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    speedHoldLabel.textColor = .white
    speedHoldLabel.backgroundColor = UIColor.black.withAlphaComponent(0.65)
    speedHoldLabel.textAlignment = .center
    speedHoldLabel.layer.cornerRadius = 18
    speedHoldLabel.clipsToBounds = true
    speedHoldLabel.isHidden = true
    view.addSubview(speedHoldLabel)
    NSLayoutConstraint.activate([
      speedHoldLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      speedHoldLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
      speedHoldLabel.heightAnchor.constraint(equalToConstant: 36),
    ])
  }

  private func buildEmbeddedControls() {
    embeddedTopShade.translatesAutoresizingMaskIntoConstraints = false
    embeddedBottomShade.translatesAutoresizingMaskIntoConstraints = false
    embeddedTopShade.configure(
      colors: [UIColor.black.withAlphaComponent(0.58), UIColor.clear],
      start: CGPoint(x: 0.5, y: 0),
      end: CGPoint(x: 0.5, y: 1)
    )
    embeddedBottomShade.configure(
      colors: [UIColor.clear, UIColor.black.withAlphaComponent(0.72)],
      start: CGPoint(x: 0.5, y: 0),
      end: CGPoint(x: 0.5, y: 1)
    )
    controls.addSubview(embeddedTopShade)
    controls.addSubview(embeddedBottomShade)
    NSLayoutConstraint.activate([
      embeddedTopShade.topAnchor.constraint(equalTo: controls.topAnchor),
      embeddedTopShade.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
      embeddedTopShade.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
      embeddedTopShade.heightAnchor.constraint(equalToConstant: 76),
      embeddedBottomShade.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
      embeddedBottomShade.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
      embeddedBottomShade.bottomAnchor.constraint(equalTo: controls.bottomAnchor),
      embeddedBottomShade.heightAnchor.constraint(equalToConstant: 88),
    ])

    configureButton(menuButton, image: "ellipsis", action: #selector(showEmbeddedMoreMenu))
    menuButton.transform = CGAffineTransform(rotationAngle: .pi / 2)
    backButton.setPreferredSymbolConfiguration(
      UIImage.SymbolConfiguration(pointSize: 25, weight: .medium),
      forImageIn: .normal
    )
    pipButton.setPreferredSymbolConfiguration(
      UIImage.SymbolConfiguration(pointSize: 23, weight: .regular),
      forImageIn: .normal
    )
    menuButton.setPreferredSymbolConfiguration(
      UIImage.SymbolConfiguration(pointSize: 21, weight: .bold),
      forImageIn: .normal
    )

    topBar.axis = .horizontal
    topBar.alignment = .center
    topBar.spacing = 10
    topBar.addArrangedSubview(backButton)
    topBar.addArrangedSubview(UIView())
    topBar.addArrangedSubview(menuButton)

    bottomBar.axis = .horizontal
    bottomBar.alignment = .center
    bottomBar.spacing = 10
    playButton.setPreferredSymbolConfiguration(
      UIImage.SymbolConfiguration(pointSize: 27, weight: .bold),
      forImageIn: .normal
    )
    fullscreenButton.setPreferredSymbolConfiguration(
      UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold),
      forImageIn: .normal
    )
    fullTimeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
    fullTimeLabel.setContentHuggingPriority(.required, for: .horizontal)
    bottomBar.addArrangedSubview(playButton)
    bottomBar.addArrangedSubview(slider)
    bottomBar.addArrangedSubview(fullTimeLabel)
    bottomBar.addArrangedSubview(fullscreenButton)

    [topBar, bottomBar].forEach {
      $0.translatesAutoresizingMaskIntoConstraints = false
    }
    embeddedTopShade.addSubview(topBar)
    embeddedBottomShade.addSubview(bottomBar)
    NSLayoutConstraint.activate([
      topBar.topAnchor.constraint(equalTo: embeddedTopShade.safeAreaLayoutGuide.topAnchor, constant: 8),
      topBar.leadingAnchor.constraint(equalTo: embeddedTopShade.leadingAnchor, constant: 12),
      topBar.trailingAnchor.constraint(equalTo: embeddedTopShade.trailingAnchor, constant: -12),
      topBar.heightAnchor.constraint(equalToConstant: 42),
      bottomBar.leadingAnchor.constraint(equalTo: embeddedBottomShade.leadingAnchor, constant: 12),
      bottomBar.trailingAnchor.constraint(equalTo: embeddedBottomShade.trailingAnchor, constant: -12),
      bottomBar.bottomAnchor.constraint(equalTo: embeddedBottomShade.safeAreaLayoutGuide.bottomAnchor, constant: -8),
      bottomBar.heightAnchor.constraint(equalToConstant: 46),
      slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 70),
    ])
  }

  private func buildFullscreenControls() {
    topChrome.translatesAutoresizingMaskIntoConstraints = false
    bottomChrome.translatesAutoresizingMaskIntoConstraints = false
    topChrome.configure(
      colors: [UIColor.black.withAlphaComponent(0.65), UIColor.clear],
      start: CGPoint(x: 0.5, y: 0), end: CGPoint(x: 0.5, y: 1)
    )
    bottomChrome.configure(
      colors: [UIColor.clear, UIColor.black.withAlphaComponent(0.7)],
      start: CGPoint(x: 0.5, y: 0), end: CGPoint(x: 0.5, y: 1)
    )
    controls.addSubview(topChrome)
    controls.addSubview(bottomChrome)
    NSLayoutConstraint.activate([
      topChrome.topAnchor.constraint(equalTo: controls.topAnchor),
      topChrome.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
      topChrome.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
      topChrome.bottomAnchor.constraint(equalTo: controls.safeAreaLayoutGuide.topAnchor, constant: 140),
      bottomChrome.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
      bottomChrome.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
      bottomChrome.bottomAnchor.constraint(equalTo: controls.bottomAnchor),
      bottomChrome.topAnchor.constraint(equalTo: controls.safeAreaLayoutGuide.bottomAnchor, constant: -120),
    ])

    titleLabel.font = .systemFont(ofSize: 19, weight: .semibold)
    titleLabel.textColor = .white
    titleLabel.numberOfLines = 1
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.text = session.videoTitle
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let metricStack = UIStackView(arrangedSubviews: [
      metricView(icon: "hand.thumbsup", label: likeLabel, action: #selector(requestLike)),
      metricView(icon: "arrowshape.turn.up.right", label: shareLabel, action: #selector(requestShare)),
    ])
    metricStack.axis = .horizontal
    metricStack.alignment = .center
    metricStack.spacing = 18
    metricStack.setContentCompressionResistancePriority(.required, for: .horizontal)

    configureButton(menuButton, image: "ellipsis", action: #selector(showMoreMenu))
    menuButton.transform = CGAffineTransform(rotationAngle: .pi / 2)

    let wifiView = UIImageView(image: UIImage(systemName: "wifi"))
    wifiView.tintColor = .white
    wifiView.contentMode = .scaleAspectFit
    wifiView.widthAnchor.constraint(equalToConstant: 18).isActive = true
    [systemTimeLabel, batteryLabel].forEach {
      $0.textColor = .white
      $0.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    }
    statusStack.addArrangedSubview(wifiView)
    statusStack.addArrangedSubview(batteryLabel)
    statusStack.axis = .horizontal
    statusStack.alignment = .center
    statusStack.spacing = 7
    systemTimeLabel.textAlignment = .center

    ownerImageView.translatesAutoresizingMaskIntoConstraints = false
    ownerImageView.contentMode = .scaleAspectFill
    ownerImageView.clipsToBounds = true
    ownerImageView.layer.cornerRadius = 15
    ownerImageView.backgroundColor = UIColor.white.withAlphaComponent(0.14)
    ownerImageView.widthAnchor.constraint(equalToConstant: 30).isActive = true
    ownerImageView.heightAnchor.constraint(equalToConstant: 30).isActive = true
    ownerLabel.text = session.videoOwnerName
    ownerLabel.textColor = .white
    ownerLabel.font = .systemFont(ofSize: 14, weight: .medium)
    ownerLabel.lineBreakMode = .byTruncatingTail
    let ownerStack = UIStackView(arrangedSubviews: [ownerImageView, ownerLabel])
    ownerStack.axis = .horizontal
    ownerStack.alignment = .center
    ownerStack.spacing = 8

    topBar.axis = .horizontal
    topBar.alignment = .center
    topBar.spacing = 10
    topBar.addArrangedSubview(backButton)
    topBar.addArrangedSubview(titleLabel)
    topBar.addArrangedSubview(metricStack)
    topBar.addArrangedSubview(menuButton)
    topBar.translatesAutoresizingMaskIntoConstraints = false
    systemTimeLabel.translatesAutoresizingMaskIntoConstraints = false
    statusStack.translatesAutoresizingMaskIntoConstraints = false
    ownerStack.translatesAutoresizingMaskIntoConstraints = false
    topChrome.addSubview(topBar)
    topChrome.addSubview(systemTimeLabel)
    topChrome.addSubview(statusStack)
    topChrome.addSubview(ownerStack)
    NSLayoutConstraint.activate([
      systemTimeLabel.topAnchor.constraint(equalTo: controls.safeAreaLayoutGuide.topAnchor, constant: 2),
      systemTimeLabel.centerXAnchor.constraint(equalTo: topChrome.centerXAnchor),
      statusStack.centerYAnchor.constraint(equalTo: systemTimeLabel.centerYAnchor),
      statusStack.trailingAnchor.constraint(equalTo: controls.safeAreaLayoutGuide.trailingAnchor, constant: -10),
      topBar.leadingAnchor.constraint(equalTo: controls.safeAreaLayoutGuide.leadingAnchor, constant: 8),
      topBar.trailingAnchor.constraint(equalTo: controls.safeAreaLayoutGuide.trailingAnchor, constant: -10),
      topBar.topAnchor.constraint(equalTo: systemTimeLabel.bottomAnchor, constant: 3),
      topBar.heightAnchor.constraint(equalToConstant: 38),
      ownerStack.leadingAnchor.constraint(equalTo: controls.safeAreaLayoutGuide.leadingAnchor, constant: 12),
      ownerStack.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 12),
      ownerStack.trailingAnchor.constraint(lessThanOrEqualTo: topChrome.trailingAnchor, constant: -16),
      ownerStack.bottomAnchor.constraint(lessThanOrEqualTo: topChrome.bottomAnchor, constant: -6),
    ])

    fullTimeLabel.textAlignment = .left
    fullTimeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
    [playButton, backButton, lockButton, danmakuSettingsButton].forEach {
      $0.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 24, weight: .regular), forImageIn: .normal)
    }

    danmakuButton.setImage(UIImage(systemName: "text.bubble.fill"), for: .normal)
    danmakuButton.tintColor = .white
    danmakuButton.setTitle(nil, for: .normal)
    danmakuButton.accessibilityLabel = "弹幕开关"
    danmakuButton.backgroundColor = .clear
    danmakuButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 23), forImageIn: .normal)
    [speedButton, qualityButton].forEach {
      $0.backgroundColor = .clear
      $0.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
      $0.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    danmakuInputButton.contentHorizontalAlignment = .left
    danmakuInputButton.setTitleColor(UIColor.darkGray, for: .normal)
    danmakuInputButton.backgroundColor = UIColor.white.withAlphaComponent(0.88)
    danmakuInputButton.layer.cornerRadius = 20
    danmakuInputButton.titleLabel?.font = .systemFont(ofSize: 14)
    danmakuInputButton.titleLabel?.lineBreakMode = .byTruncatingTail
    danmakuInputButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
    danmakuInputButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
    danmakuInputButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let danmakuInputWidth = danmakuInputButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
    danmakuInputWidth.priority = .defaultHigh
    danmakuInputWidth.isActive = true
    danmakuInputButton.heightAnchor.constraint(equalToConstant: 40).isActive = true

    let actionRow = UIStackView(arrangedSubviews: [
      playButton,
      danmakuButton,
      danmakuSettingsButton,
      danmakuInputButton,
      speedButton,
      qualityButton,
    ])
    actionRow.axis = .horizontal
    actionRow.alignment = .center
    actionRow.spacing = 14

    bottomBar.axis = .vertical
    bottomBar.alignment = .fill
    bottomBar.spacing = 6
    bottomBar.addArrangedSubview(fullTimeLabel)
    bottomBar.addArrangedSubview(slider)
    bottomBar.addArrangedSubview(actionRow)
    bottomBar.translatesAutoresizingMaskIntoConstraints = false
    bottomChrome.addSubview(bottomBar)
    NSLayoutConstraint.activate([
      bottomBar.leadingAnchor.constraint(equalTo: controls.safeAreaLayoutGuide.leadingAnchor, constant: 14),
      bottomBar.trailingAnchor.constraint(equalTo: controls.safeAreaLayoutGuide.trailingAnchor, constant: -14),
      bottomBar.topAnchor.constraint(greaterThanOrEqualTo: bottomChrome.topAnchor, constant: 9),
      bottomBar.bottomAnchor.constraint(equalTo: controls.safeAreaLayoutGuide.bottomAnchor, constant: -8),
      slider.heightAnchor.constraint(equalToConstant: 30),
    ])

    lockButton.translatesAutoresizingMaskIntoConstraints = false
    lockButton.backgroundColor = UIColor.black.withAlphaComponent(0.2)
    lockButton.layer.cornerRadius = 16
    view.addSubview(lockButton)
    NSLayoutConstraint.activate([
      lockButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
      lockButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])

    buildDanmakuSettingsPanel()
  }

  private func metricView(icon: String, label: UILabel, action: Selector) -> UIView {
    let button = UIButton(type: .system)
    button.tintColor = .white
    button.setImage(UIImage(systemName: icon), for: .normal)
    button.widthAnchor.constraint(equalToConstant: 24).isActive = true
    button.heightAnchor.constraint(equalToConstant: 30).isActive = true
    button.addTarget(self, action: action, for: .touchUpInside)
    label.textColor = .white
    label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    label.text = "0"
    let stack = UIStackView(arrangedSubviews: [button, label])
    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = 4
    return stack
  }

  private func buildDanmakuSettingsPanel() {
    danmakuSettingsPanel.translatesAutoresizingMaskIntoConstraints = false
    danmakuSettingsPanel.isHidden = true
    danmakuSettingsPanel.layer.cornerRadius = 18
    danmakuSettingsPanel.clipsToBounds = true
    view.addSubview(danmakuSettingsPanel)
    NSLayoutConstraint.activate([
      danmakuSettingsPanel.topAnchor.constraint(equalTo: view.topAnchor),
      danmakuSettingsPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      danmakuSettingsPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      danmakuSettingsPanel.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: fullscreenPresentation ? 0.5 : 1),
    ])
    let hosting = UIHostingController(rootView: PiliNativeDanmakuSettingsView(session: session) { [weak self] in
      self?.setDanmakuSettingsVisible(false, animated: true)
    })
    addChild(hosting)
    hosting.view.backgroundColor = .clear
    hosting.view.translatesAutoresizingMaskIntoConstraints = false
    danmakuSettingsPanel.contentView.addSubview(hosting.view)
    NSLayoutConstraint.activate([
      hosting.view.topAnchor.constraint(equalTo: danmakuSettingsPanel.contentView.topAnchor),
      hosting.view.leadingAnchor.constraint(equalTo: danmakuSettingsPanel.contentView.leadingAnchor),
      hosting.view.trailingAnchor.constraint(equalTo: danmakuSettingsPanel.contentView.trailingAnchor),
      hosting.view.bottomAnchor.constraint(equalTo: danmakuSettingsPanel.contentView.bottomAnchor),
    ])
    hosting.didMove(toParent: self)
  }

  private func bindSession() {
    applyControlPreferences()
    NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.applyControlPreferences() }
      .store(in: &cancellables)
    session.$danmakuSettings.receive(on: DispatchQueue.main).sink { [weak self] settings in
      self?.danmakuView.applySettings(settings)
    }.store(in: &cancellables)
    session.$danmakuRules.receive(on: DispatchQueue.main).sink { [weak self] _ in
      self?.danmakuView.clear()
    }.store(in: &cancellables)
    session.$isReady.receive(on: DispatchQueue.main).sink { [weak self] ready in
      guard ready else { return }
      self?.revealVideoSurfaceAfterPreRender()
    }.store(in: &cancellables)
    session.$isPlaying.receive(on: DispatchQueue.main).sink { [weak self] playing in
      self?.playButton.setImage(UIImage(systemName: playing ? "pause.fill" : "play.fill"), for: .normal)
      if !playing {
        self?.endSpeedHold()
        self?.controlsHideTask?.cancel()
        if self?.controlsLocked == false {
          self?.chromeViews.forEach { $0.alpha = 1 }
        }
      }
    }.store(in: &cancellables)
    session.$temporaryDoubleSpeedActive.receive(on: DispatchQueue.main).sink { [weak self] active in
      self?.speedHoldLabel.isHidden = !active
    }.store(in: &cancellables)
    session.$isBuffering.receive(on: DispatchQueue.main).sink { [weak self] buffering in
      buffering ? self?.spinner.startAnimating() : self?.spinner.stopAnimating()
    }.store(in: &cancellables)
    session.$errorMessage.receive(on: DispatchQueue.main).sink { [weak self] message in
      self?.errorLabel.text = message
      self?.errorLabel.isHidden = message == nil
    }.store(in: &cancellables)
    session.$duration.receive(on: DispatchQueue.main).sink { [weak self] duration in
      self?.durationLabel.text = Self.formatTime(duration)
      self?.slider.maximumValue = Float(max(duration, 1))
      self?.refreshFullscreenTimeLabel()
    }.store(in: &cancellables)
    session.$currentTime.receive(on: DispatchQueue.main).sink { [weak self] time in
      guard let self = self else { return }
      if !self.isScrubbing {
        self.currentLabel.text = Self.formatTime(time)
        self.slider.value = Float(time)
        self.refreshFullscreenTimeLabel()
      }
      if self.session.danmakuEnabled && self.session.danmakuSettingsLoaded {
        self.danmakuView.render(
          time: time,
          items: self.session.danmakuItems,
          revision: self.session.danmakuRevision
        )
      }
    }.store(in: &cancellables)
    session.$danmakuRevision.receive(on: DispatchQueue.main).sink { [weak self] _ in
      guard let self = self, self.session.danmakuEnabled, self.session.danmakuSettingsLoaded else { return }
      self.danmakuView.render(
        time: self.session.currentTime,
        items: self.session.danmakuItems,
        revision: self.session.danmakuRevision
      )
    }.store(in: &cancellables)
    session.$danmakuEnabled.receive(on: DispatchQueue.main).sink { [weak self] enabled in
      guard let self else { return }
      self.danmakuButton.setTitle(
        self.fullscreenPresentation ? nil : (enabled ? "弹幕开" : "弹幕关"),
        for: .normal
      )
      self.danmakuButton.setImage(
        UIImage(systemName: enabled ? "text.bubble.fill" : "text.bubble"),
        for: .normal
      )
      self.danmakuButton.alpha = enabled ? 1 : 0.66
      if !enabled { self.danmakuView.clear() }
    }.store(in: &cancellables)
    session.$qualityLabel.receive(on: DispatchQueue.main).sink { [weak self] label in
      self?.qualityButton.setTitle(label, for: .normal)
    }.store(in: &cancellables)
    session.$qualities.receive(on: DispatchQueue.main).sink { [weak self] qualities in
      self?.updateQualityMenu(qualities)
    }.store(in: &cancellables)
    session.$playbackRate.receive(on: DispatchQueue.main).sink { [weak self] rate in
      self?.speedButton.setTitle(rate == 1 ? "倍速" : "\(rate)×", for: .normal)
    }.store(in: &cancellables)
    session.$pictureInPicturePlayer.receive(on: DispatchQueue.main).sink { [weak self] player in
      self?.configurePictureInPicture(player: player)
    }.store(in: &cancellables)
    session.$videoTitle.receive(on: DispatchQueue.main).sink { [weak self] title in
      self?.titleLabel.text = title
    }.store(in: &cancellables)
    session.$videoLikeCount.receive(on: DispatchQueue.main).sink { [weak self] value in
      self?.likeLabel.text = Self.formatMetric(value)
    }.store(in: &cancellables)
    session.$videoReplyCount.receive(on: DispatchQueue.main).sink { [weak self] value in
      self?.replyLabel.text = Self.formatMetric(value)
    }.store(in: &cancellables)
    session.$videoFavoriteCount.receive(on: DispatchQueue.main).sink { [weak self] value in
      self?.favoriteLabel.text = Self.formatMetric(value)
    }.store(in: &cancellables)
    session.$videoShareCount.receive(on: DispatchQueue.main).sink { [weak self] value in
      self?.shareLabel.text = Self.formatMetric(value)
    }.store(in: &cancellables)
    session.$videoOwnerName.receive(on: DispatchQueue.main).sink { [weak self] name in
      self?.ownerLabel.text = name
    }.store(in: &cancellables)
    session.$videoOwnerFaceURL.receive(on: DispatchQueue.main).sink { [weak self] url in
      self?.loadOwnerImage(url)
    }.store(in: &cancellables)
    session.$danmakuStatusMessage.receive(on: DispatchQueue.main).sink { [weak self] message in
      self?.toastLabel.text = message.map { "  \($0)  " }
      self?.toastLabel.isHidden = message == nil
    }.store(in: &cancellables)
    session.$danmakuComposerRequest
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        guard let self,
              self.presentedViewController == nil,
              self.viewIfLoaded?.window != nil else { return }
        self.showDanmakuComposer()
      }
      .store(in: &cancellables)
  }

  private func loadOwnerImage(_ rawURL: String) {
    ownerImageTask?.cancel()
    ownerImageView.image = UIImage(systemName: "person.crop.circle.fill")
    ownerImageView.tintColor = UIColor.white.withAlphaComponent(0.75)
    guard let url = URL(string: rawURL), !rawURL.isEmpty else { return }
    ownerImageTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let data, let image = UIImage(data: data) else { return }
      DispatchQueue.main.async {
        guard self?.session.videoOwnerFaceURL == rawURL else { return }
        self?.ownerImageView.image = image
      }
    }
    ownerImageTask?.resume()
  }

  private func configurePictureInPicture(player: AVPlayer?) {
    pictureInPictureController?.stopPictureInPicture()
    pictureInPictureController = nil
    guard AVPictureInPictureController.isPictureInPictureSupported(),
          player != nil,
          let layer = session.engine.nativePlayerLayer else {
      pipButton.isHidden = true
      return
    }
    // Reuse Aether's visible player layer. Creating a second hidden
    // AVPlayerLayer for the same AVPlayer can leave the visible surface without
    // a video output while audio continues normally.
    pictureInPictureController = AVPictureInPictureController(playerLayer: layer)
    pipButton.isHidden = false
  }

  private func updateQualityMenu(_ qualities: [PiliNativePlayerQuality]) {
    qualityButton.menu = UIMenu(children: qualities.map { quality in
      UIAction(title: quality.label) { [weak self] _ in
        self?.session.selectQuality(quality.value)
      }
    })
    qualityButton.showsMenuAsPrimaryAction = !qualities.isEmpty
  }

  private func configureButton(_ button: UIButton, image: String, action: Selector) {
    button.tintColor = .white
    button.setImage(UIImage(systemName: image), for: .normal)
    button.widthAnchor.constraint(equalToConstant: 32).isActive = true
    button.heightAnchor.constraint(equalToConstant: 32).isActive = true
    button.addTarget(self, action: action, for: .touchUpInside)
  }

  private func configureTextButton(_ button: UIButton, title: String, action: Selector?) {
    button.setTitle(title, for: .normal)
    button.setTitleColor(.white, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
    button.backgroundColor = UIColor.black.withAlphaComponent(0.42)
    button.layer.cornerRadius = 7
    button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
    if let action = action { button.addTarget(self, action: action, for: .touchUpInside) }
  }

  @objc private func togglePlayback() { session.togglePlayback(); scheduleControlsHide() }
  @objc private func toggleDanmaku() { session.danmakuEnabled.toggle(); scheduleControlsHide() }
  @objc private func changeSpeed() { session.cyclePlaybackRate(); scheduleControlsHide() }
  @objc private func toggleFullscreen() { session.isFullscreen.toggle() }
  @objc private func exitFullscreen() {
    if fullscreenPresentation {
      session.isFullscreen = false
    } else {
      session.requestVideoAction("close")
    }
  }

  @objc private func toggleScreenLock() {
    endSpeedHold()
    controlsLocked.toggle()
    controlsHideTask?.cancel()
    if controlsLocked { setDanmakuSettingsVisible(false, animated: false) }
    lockButton.setImage(
      UIImage(systemName: controlsLocked ? "lock.fill" : "lock.open.fill"),
      for: .normal
    )
    UIView.animate(withDuration: 0.2) {
      self.chromeViews.forEach { $0.alpha = self.controlsLocked ? 0 : 1 }
      self.lockButton.backgroundColor = self.controlsLocked
        ? UIColor(red: 0.93, green: 0.29, blue: 0.48, alpha: 0.82)
        : UIColor.black.withAlphaComponent(0.52)
    }
    if !controlsLocked { scheduleControlsHide() }
  }

  @objc private func toggleDanmakuSettings() {
    guard !controlsLocked else { return }
    controlsHideTask?.cancel()
    setDanmakuSettingsVisible(!settingsPanelVisible, animated: true)
  }

  @objc private func showDanmakuComposer() {
    controlsHideTask?.cancel()
    let alert = UIAlertController(title: "发送弹幕", message: nil, preferredStyle: .alert)
    alert.addTextField { field in
      field.placeholder = "发个友善的弹幕见证当下"
      field.clearButtonMode = .whileEditing
      field.returnKeyType = .send
    }
    alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
      self?.scheduleControlsHide()
    })
    alert.addAction(UIAlertAction(title: "发送", style: .default) { [weak self, weak alert] _ in
      guard let self,
            let raw = alert?.textFields?.first?.text,
            !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
      self.session.requestDanmakuSend(String(raw.prefix(100)))
      self.scheduleControlsHide()
    })
    present(alert, animated: true)
  }

  @objc private func requestLike() { session.requestVideoAction("like") }
  @objc private func requestComment() {
    if fullscreenPresentation {
      session.toggleFullscreenComments()
      scheduleControlsHide()
    } else {
      session.requestVideoAction("comment")
    }
  }
  @objc private func requestFavorite() { session.requestVideoAction("favorite") }
  @objc private func requestShare() { session.requestVideoAction("share") }

  @objc private func showMoreMenu() {
    controlsHideTask?.cancel()
    let menu = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
    menu.addAction(UIAlertAction(title: "评论", style: .default) { [weak self] _ in
      self?.requestComment()
    })
    menu.addAction(UIAlertAction(title: "收藏", style: .default) { [weak self] _ in
      self?.requestFavorite()
    })
    if pictureInPictureController != nil {
      menu.addAction(UIAlertAction(title: "画中画", style: .default) { [weak self] _ in
        self?.togglePictureInPicture()
      })
    }
    menu.addAction(UIAlertAction(title: "弹幕设置", style: .default) { [weak self] _ in
      self?.setDanmakuSettingsVisible(true, animated: true)
    })
    menu.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
      self?.scheduleControlsHide()
    })
    if let popover = menu.popoverPresentationController {
      popover.sourceView = menuButton
      popover.sourceRect = menuButton.bounds
    }
    present(menu, animated: true)
  }

  @objc private func showEmbeddedMoreMenu() {
    controlsHideTask?.cancel()
    let menu = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
    if pictureInPictureController != nil {
      menu.addAction(UIAlertAction(title: "画中画", style: .default) { [weak self] _ in
        self?.togglePictureInPicture()
      })
    }
    menu.addAction(
      UIAlertAction(
        title: session.danmakuEnabled ? "关闭弹幕" : "打开弹幕",
        style: .default
      ) { [weak self] _ in
        self?.session.danmakuEnabled.toggle()
        self?.scheduleControlsHide()
      }
    )
    for quality in session.qualities {
      menu.addAction(
        UIAlertAction(
          title: quality.label == session.qualityLabel ? "✓ \(quality.label)" : quality.label,
          style: .default
        ) { [weak self] _ in
          self?.session.selectQuality(quality.value)
          self?.scheduleControlsHide()
        }
      )
    }
    menu.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
      self?.scheduleControlsHide()
    })
    if let popover = menu.popoverPresentationController {
      popover.sourceView = menuButton
      popover.sourceRect = menuButton.bounds
    }
    present(menu, animated: true)
  }

  @objc private func togglePictureInPicture() {
    guard let controller = pictureInPictureController else { return }
    controller.isPictureInPictureActive ? controller.stopPictureInPicture() : controller.startPictureInPicture()
  }

  @objc private func toggleControls() {
    guard !controlsLocked else { return }
    controlsHideTask?.cancel()
    if settingsPanelVisible {
      setDanmakuSettingsVisible(false, animated: true)
      scheduleControlsHide()
      return
    }
    let shouldShow = (chromeViews.first?.alpha ?? 0) < 0.1
    UIView.animate(withDuration: 0.18) {
      self.chromeViews.forEach { $0.alpha = shouldShow ? 1 : 0 }
    }
    if shouldShow { scheduleControlsHide() }
  }

  @objc private func doubleTapPlayback(_ gesture: UITapGestureRecognizer) {
    guard PiliNativePlayerPreferences.doubleTapPause,
          gesture.state == .ended, !controlsLocked, !settingsPanelVisible, !isScrubbing else { return }
    togglePlayback()
  }

  @objc private func holdDoubleSpeed(_ gesture: UILongPressGestureRecognizer) {
    switch gesture.state {
    case .began:
      guard PiliNativePlayerPreferences.holdDoubleSpeed,
            !controlsLocked, !settingsPanelVisible, !isScrubbing else { return }
      controlsHideTask?.cancel()
      session.beginTemporaryDoubleSpeed()
    case .ended, .cancelled, .failed:
      endSpeedHold()
    default:
      break
    }
  }

  @objc private func endSpeedHold() {
    session.endTemporaryDoubleSpeed()
    scheduleControlsHide()
  }

  @objc private func scrubStarted() {
    isScrubbing = true
    wasPlayingBeforeScrub = session.isPlaying
    session.pausePlayback()
    controlsHideTask?.cancel()
  }

  @objc private func scrubChanged() {
    currentLabel.text = Self.formatTime(Double(slider.value))
    fullTimeLabel.text = "\(Self.formatTime(Double(slider.value)))/\(Self.formatTime(session.duration))"
  }

  @objc private func scrubEnded() {
    isScrubbing = false
    session.seek(to: Double(slider.value), autoplay: wasPlayingBeforeScrub)
    scheduleControlsHide()
  }

  private func scheduleControlsHide() {
    controlsHideTask?.cancel()
    guard session.isPlaying, !controlsLocked, !settingsPanelVisible,
          !session.temporaryDoubleSpeedActive else { return }
    let task = DispatchWorkItem { [weak self] in
      UIView.animate(withDuration: 0.2) {
        self?.chromeViews.forEach { $0.alpha = 0 }
      }
    }
    controlsHideTask = task
    DispatchQueue.main.asyncAfter(deadline: .now() + PiliNativePlayerPreferences.hideDelay, execute: task)
  }

  private func applyControlPreferences() {
    if !PiliNativePlayerPreferences.holdDoubleSpeed { session.endTemporaryDoubleSpeed() }
    if !PiliNativePlayerPreferences.showLock && controlsLocked { toggleScreenLock() }
    lockButton.isHidden = !PiliNativePlayerPreferences.showLock
    systemTimeLabel.isHidden = !PiliNativePlayerPreferences.showStatus
    statusStack.isHidden = !PiliNativePlayerPreferences.showStatus
    scheduleControlsHide()
  }

  private func showControllerToast(_ message: String) {
    toastLabel.layer.removeAllAnimations()
    toastLabel.text = "  \(message)  "
    toastLabel.alpha = 1
    toastLabel.isHidden = false
    UIView.animate(
      withDuration: 0.2,
      delay: 1.35,
      options: [.curveEaseOut, .allowUserInteraction]
    ) { [weak self] in
      self?.toastLabel.alpha = 0
    } completion: { [weak self] _ in
      self?.toastLabel.isHidden = true
      self?.toastLabel.alpha = 1
    }
  }

  private func revealVideoSurfaceAfterPreRender() {
    guard !videoSurfaceRevealed else { return }
    surfaceRevealTask?.cancel()
    let task = DispatchWorkItem { [weak self] in
      guard let self, !self.videoSurfaceRevealed else { return }
      self.videoSurfaceRevealed = true
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 0
      fade.toValue = 1
      fade.duration = 0.24
      fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      self.canvas.layer.opacity = 1
      CATransaction.commit()
      self.canvas.layer.add(fade, forKey: "piliglass.first-frame-fade")
    }
    surfaceRevealTask = task
    // Give Aether two display frames to attach its active rendering layer. The
    // SwiftUI host keeps the cover visible underneath during this pre-render.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: task)
  }

  private var chromeViews: [UIView] {
    fullscreenPresentation ? [topChrome, bottomChrome] : [embeddedTopShade, embeddedBottomShade]
  }

  private func setDanmakuSettingsVisible(_ visible: Bool, animated: Bool) {
    if visible { endSpeedHold() }
    settingsPanelVisible = visible
    if visible {
      danmakuSettingsPanel.isHidden = false
      view.bringSubviewToFront(danmakuSettingsPanel)
      view.bringSubviewToFront(toastLabel)
      view.layoutIfNeeded()
      danmakuSettingsPanel.transform = CGAffineTransform(
        translationX: max(danmakuSettingsPanel.bounds.width, view.bounds.width * 0.5),
        y: 0
      )
      danmakuSettingsPanel.alpha = 0
      lockButton.alpha = 0
      let animations = {
        self.danmakuSettingsPanel.transform = .identity
        self.danmakuSettingsPanel.alpha = 1
      }
      if animated {
        UIView.animate(withDuration: 0.24, animations: animations)
      } else {
        animations()
      }
    } else {
      let animations = {
        self.danmakuSettingsPanel.transform = CGAffineTransform(
          translationX: max(self.danmakuSettingsPanel.bounds.width, self.view.bounds.width * 0.5),
          y: 0
        )
        self.danmakuSettingsPanel.alpha = 0
      }
      let completion: (Bool) -> Void = { _ in
        self.danmakuSettingsPanel.isHidden = true
        self.danmakuSettingsPanel.transform = .identity
        self.lockButton.alpha = 1
      }
      if animated {
        UIView.animate(withDuration: 0.2, animations: animations, completion: completion)
      } else {
        animations()
        completion(true)
      }
    }
  }

  private func refreshFullscreenTimeLabel() {
    fullTimeLabel.text = "\(Self.formatTime(session.currentTime))/\(Self.formatTime(session.duration))"
  }

  private func startSystemStatusUpdates() {
    UIDevice.current.isBatteryMonitoringEnabled = true
    updateSystemStatus()
    statusTimer?.invalidate()
    statusTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
      self?.updateSystemStatus()
    }
  }

  private func updateSystemStatus() {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    systemTimeLabel.text = formatter.string(from: Date())
    let batteryLevel = UIDevice.current.batteryLevel
    batteryLabel.text = batteryLevel >= 0 ? "\(Int((batteryLevel * 100).rounded()))%" : "--%"
  }

  private func requestOrientation(_ orientations: UIInterfaceOrientationMask) {
    if #available(iOS 16.0, *), let scene = view.window?.windowScene {
      scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations))
      setNeedsUpdateOfSupportedInterfaceOrientations()
    } else {
      let target: UIInterfaceOrientation = orientations == .portrait ? .portrait : .landscapeRight
      UIDevice.current.setValue(target.rawValue, forKey: "orientation")
      UIViewController.attemptRotationToDeviceOrientation()
    }
  }

  static func restorePortraitOrientation() {
    if #available(iOS 16.0, *),
       let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
      scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
    } else {
      UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
      UIViewController.attemptRotationToDeviceOrientation()
    }
  }

  private static func formatTime(_ value: TimeInterval) -> String {
    guard value.isFinite, value >= 0 else { return "00:00" }
    let seconds = Int(value.rounded(.down))
    if seconds >= 3600 {
      return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
  }

  private static func formatMetric(_ value: Int) -> String {
    if value >= 100_000_000 {
      return String(format: "%.1f亿", Double(value) / 100_000_000)
        .replacingOccurrences(of: ".0亿", with: "亿")
    }
    if value >= 10_000 {
      return String(format: "%.1f万", Double(value) / 10_000)
        .replacingOccurrences(of: ".0万", with: "万")
    }
    return String(value)
  }
}

struct PiliNativePlayerView: UIViewControllerRepresentable {
  let session: PiliNativePlayerSession
  var fullscreen = false

  func makeUIViewController(context: Context) -> PiliNativePlayerViewController {
    PiliNativePlayerViewController(session: session, fullscreen: fullscreen)
  }

  func updateUIViewController(_ uiViewController: PiliNativePlayerViewController, context: Context) {}

  static func dismantleUIViewController(
    _ uiViewController: PiliNativePlayerViewController,
    coordinator: Void
  ) {
    uiViewController.detachVideoSurface()
    uiViewController.view.layer.removeAllAnimations()
  }
}
