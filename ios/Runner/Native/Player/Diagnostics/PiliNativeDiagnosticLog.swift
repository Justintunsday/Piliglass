import Foundation
import AetherEngine
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

