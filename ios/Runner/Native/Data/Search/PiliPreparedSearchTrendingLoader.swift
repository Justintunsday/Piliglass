import Foundation
import PiliHTTPBodyCodec

/// Joins request ownership, Cookie write-back and a decoded search result.
struct PiliPreparedSearchTrendingLoader: Sendable {
  typealias MakeRawTransport = @Sendable (PiliRawHTTP11Profile) async throws -> any PiliHTTPTransferring

  private let executor: PiliPreparedHTTPRequestExecutor
  private let accounts: PiliAccountFlutterRepository
  private let maximumBodyBytes: Int

  @MainActor
  static func repository(
    bridge: any PiliBridgeMethodTransport,
    launchArguments: [String] = CommandLine.arguments,
    deviceTrial: Bool = Bundle.main.object(forInfoDictionaryKey: "PiliNativeSearchTrendingTrial") as? Bool == true,
    makeRawTransport: MakeRawTransport? = nil
  ) -> PiliFlutterSearchRepository {
    let invoker = PiliBridgeMethodInvoker(transport: bridge)
    guard deviceTrial || launchArguments.contains("--pili-native-search-trending") else {
      return PiliFlutterSearchRepository(invoker: invoker)
    }
    let recordTrial: @Sendable (String) -> Void = { status in
      guard deviceTrial else { return }
      let url = FileManager.default.temporaryDirectory.appendingPathComponent("piliglass-trending-trial.txt")
      try? status.write(to: url, atomically: true, encoding: .utf8)
    }
    recordTrial("ready")
    let usingProbe = deviceTrial && Bundle.main.object(forInfoDictionaryKey: "PiliNativeSearchTrendingAcceptance") as? Bool == true
    let probe = usingProbe ? PiliTrendingDeviceProbe(invoker: invoker, record: recordTrial) : nil
    let maximumBodyBytes = 4 * 1024 * 1024
    let pool = PiliRawHTTPClientPool(maximumBodyBytes: maximumBodyBytes)
    let loader = Self(bridge: bridge, selectTransport: { policy in
      switch PiliHTTPPolicyCapability().planRawHTTP11(policy) {
      case .unsupported(let reasons):
        recordTrial("dart: " + reasons.map(\.rawValue).joined(separator: " "))
        return .dart(reasons)
      case .candidate(let profile):
        do {
          if let makeRawTransport { return .native(try await makeRawTransport(profile)) }
          if let probe {
            return .native(try PiliRawHTTPClient(profile: profile, maximumBodyBytes: maximumBodyBytes,
                                                afterSuccessHead: { try await probe.afterHead() }))
          }
          return .native(try await pool.client(for: profile))
        } catch {
          recordTrial("dart: client")
          return .dart([.unverifiedTransport])
        }
      }
    }, maximumBodyBytes: maximumBodyBytes)
    return PiliFlutterSearchRepository(invoker: invoker, loadNativeTrending: {
      if let probe { return try await probe.run(loader) }
      recordTrial("loading")
      do {
        let result = try await loader.load()
        if case .keywords(let keywords) = result { recordTrial("native: \(keywords.count)") }
        return result
      } catch is CancellationError {
        recordTrial("cancelled")
        throw CancellationError()
      } catch {
        if case .httpStatus(let status) = error as? PiliSearchTrendingError {
          recordTrial("response: \(status)")
        } else if case .nativeTransport(let kind) = error as? PiliHTTPClientError {
          recordTrial("transport: " + kind)
        } else {
          recordTrial("error: \(type(of: error))")
        }
        throw error
      }
    })
  }

  @MainActor
  init(
    bridge: any PiliBridgeMethodTransport,
    selectTransport: @escaping PiliPreparedHTTPRequestExecutor.SelectTransport,
    maximumBodyBytes: Int
  ) {
    executor = PiliPreparedHTTPRequestExecutor(
      provider: PiliFlutterHTTPRequestContextProvider(transport: bridge),
      selectTransport: selectTransport,
      validateResponseBody: { response in
        try Self.validateBody(response, maximumBodyBytes: maximumBodyBytes)
      }
    )
    accounts = PiliAccountFlutterRepository(invoker: PiliBridgeMethodInvoker(transport: bridge))
    self.maximumBodyBytes = maximumBodyBytes
  }

  func load() async throws -> PiliSearchTrendingResult {
    let execution = try await executor.execute(.searchTrending(limit: 10))
    try Task.checkCancellation()
    switch execution {
    case .dartFallback:
      return .useDart
    case .transferred(let transfer, let receipt, let generation, let requestedURL):
      let body: Data
      switch transfer.body {
      case .success(let bytes): body = bytes
      case .failure(.cancelled): throw CancellationError()
      case .failure(.client(let error)): throw error
      }
      guard receipt.outcome == .finished else {
        throw PiliPreparedHTTPRequestExecutionError.terminalNotConfirmed(receipt.outcome)
      }
      guard let head = transfer.head else { throw PiliHTTPClientError.invalidResponse }
      let response = PiliHTTPResponse(url: head.url, statusCode: head.statusCode, headers: head.headers, body: body)
      if (200..<300).contains(head.statusCode), !Self.isJSON(response.header(named: "content-type")) {
        throw PiliSearchTrendingError.invalidPayload
      }
      let keywords = try PiliSearchTrendingDecoder.decode(response, requestedURL: requestedURL) { body in
        try Self.decodeBody(body, encoding: response.header(named: "content-encoding"), maximumBodyBytes: maximumBodyBytes)
      }
      // The captured owner may still receive its Cookies after selection changes.
      // Only the currently selected credential generation can supply the UI.
      let selection = try await accounts.selectionSnapshot()
      try Task.checkCancellation()
      guard selection.account(for: .recommend)?.identity.generation == generation else {
        return .keywords([])
      }
      return .keywords(keywords)
    }
  }

  private static func validateBody(_ response: PiliHTTPResponse, maximumBodyBytes: Int) throws {
    let decoded: Data
    do {
      decoded = try decodeBody(response.body, encoding: response.header(named: "content-encoding"),
                               maximumBodyBytes: maximumBodyBytes)
    } catch PiliHTTPBodyDecodeFailure.malformedCompression {
      throw PiliHTTPResponseDecodingFailure(underlying: PiliHTTPBodyDecodeFailure.malformedCompression)
    }
    guard !decoded.isEmpty, isJSON(response.header(named: "content-type")) else { return }
    do {
      // JSONSerialization accepts trailing commas and can autodetect a BOM or
      // a UTF-16 buffer. Dio parses the already-decoded UTF-8 string.
      guard !decoded.starts(with: [0xEF, 0xBB, 0xBF]), !decoded.contains(0),
            !containsTrailingComma(decoded) else {
        throw PiliSearchTrendingError.invalidPayload
      }
      _ = try JSONSerialization.jsonObject(with: decoded, options: .fragmentsAllowed)
    } catch {
      throw PiliHTTPResponseDecodingFailure(underlying: error)
    }
  }

  private static let mediaTypePattern: String = {
    let token = #"[!#$%&'*+.^_\x60|~0-9A-Za-z-]+"#
    let quoted = #""(?:[^"\x00-\x1F\x7F\\]|\\.)*""#
    return #"\A[ \t]*"# + token + "/" + token + #"[ \t]*(?:;[ \t]*"# + token
      + "=(?:" + token + "|" + quoted + #")[ \t]*)*\z"#
  }()

  private static func isJSON(_ contentType: String?) -> Bool {
    guard let contentType, contentType.range(of: mediaTypePattern, options: .regularExpression) != nil,
          let name = contentType.split(separator: ";", maxSplits: 1).first else { return false }
    let mime = name.trimmingCharacters(in: .whitespaces).lowercased()
    return mime == "application/json" || mime == "text/json" || mime.hasSuffix("+json")
  }

  private static func containsTrailingComma(_ body: Data) -> Bool {
    var inString = false, escaped = false, afterComma = false
    for byte in body {
      if inString {
        if escaped { escaped = false }
        else if byte == 0x5C { escaped = true }
        else if byte == 0x22 { inString = false }
      } else {
        switch byte {
        case 0x09, 0x0A, 0x0D, 0x20: continue
        case 0x5D, 0x7D:
          if afterComma { return true }
        default: break
        }
        inString = byte == 0x22
        afterComma = byte == 0x2C
      }
    }
    return false
  }

  private static func decodeBody(_ body: Data, encoding: String?, maximumBodyBytes: Int) throws -> Data {
    let headers = encoding.map { ["content-encoding": [$0]] } ?? [:]
    let bytes = try PiliHTTPBodyDecoder.decode(body: body, headers: headers, maximumOutputBytes: maximumBodyBytes)
    return Data(PiliHTTPBodyDecoder.utf8AllowMalformed(bytes).utf8)
  }
}

/// Used in the device acceptance branch with a separate bundle marker.
@MainActor
private final class PiliTrendingDeviceProbe {
  private enum Phase: String, CaseIterable { case split, switchAccount = "switch", revoke }
  private enum Failure: Error { case busy, arming, checkpoint, receipt, result }

  private let invoker: PiliBridgeMethodInvoker
  private let record: @Sendable (String) -> Void
  private var running = false

  init(invoker: PiliBridgeMethodInvoker, record: @escaping @Sendable (String) -> Void) {
    self.invoker = invoker
    self.record = record
  }

  func afterHead() async throws {
    let response = try await command("head")
    guard response == .string("checkpoint") || response == .string("idle") else { throw Failure.checkpoint }
  }

  func run(_ loader: PiliPreparedSearchTrendingLoader) async throws -> PiliSearchTrendingResult {
    guard !running else { throw Failure.busy }
    running = true
    defer { running = false }
    var splitCount = 0
    for phase in Phase.allCases {
      record("probe: \(phase.rawValue) arming")
      let armed = try await Task { @MainActor in try await self.command(phase.rawValue) }.value
      guard armed == .string("armed") else { throw Failure.arming }
      let result: Result<PiliSearchTrendingResult, Error>
      do { result = .success(try await loader.load()) }
      catch { result = .failure(error) }
      // Restore the role even if leaving the search view cancelled its task.
      let receipt = try await Task { @MainActor in try await self.command("end") }.value
      let revoked = phase == .revoke
      let expected: PiliBridgeValue = .dictionary([
        "receipt": .string(revoked ? "revoked" : "finished"),
        "cookiesSaved": .bool(!revoked), "cookieCount": .integer(revoked ? 0 : 1),
        "heads": .integer(1), "writeBacks": .integer(revoked ? 0 : 1),
        "guestOnly": .bool(true), "leaseReleased": .bool(true), "accountRestored": .bool(true),
      ])
      guard receipt == expected else {
        record("probe: \(phase.rawValue) unexpected receipt \(receipt)")
        throw Failure.receipt
      }
      switch (phase, result) {
      case (.split, .success(.keywords(let words))) where !words.isEmpty:
        splitCount = words.count
      case (.switchAccount, .success(.keywords(let words))) where words.isEmpty:
        break
      case (.revoke, .failure(let error))
        where (error as? PiliPreparedHTTPRequestExecutionError) == .terminalNotConfirmed(.revoked):
        break
      default:
        record("probe: \(phase.rawValue) unexpected search result")
        throw Failure.result
      }
    }
    let restored = try await loader.load()
    guard case .keywords(let words) = restored, !words.isEmpty else { throw Failure.result }
    record("probe: passed split=\(splitCount) switched=0 revokedWrites=0 restored=\(words.count)")
    return restored
  }

  private func command(_ phase: String) async throws -> PiliBridgeValue {
    try await invoker.invoke("nativeTrendingDeviceProbe", arguments: ["phase": .string(phase)])
  }
}
