import Foundation
import PiliHTTPBodyCodec

/// Joins request ownership, Cookie write-back and a decoded search result.
/// The composition supplies the transport and its evidence for this endpoint.
struct PiliPreparedSearchTrendingLoader: Sendable {
  private let executor: PiliPreparedHTTPRequestExecutor
  private let accounts: PiliAccountFlutterRepository
  private let maximumBodyBytes: Int

  @MainActor
  init(
    bridge: any PiliBridgeMethodTransport,
    transport: any PiliHTTPTransferring,
    evidence: PiliHTTPTransportEvidence,
    maximumBodyBytes: Int
  ) {
    executor = PiliPreparedHTTPRequestExecutor(
      provider: PiliFlutterHTTPRequestContextProvider(transport: bridge),
      transport: transport,
      evidence: evidence,
      validateResponseBody: { response in
        let decoded = try Self.decodeBody(response.body, encoding: response.header(named: "content-encoding"),
                                          maximumBodyBytes: maximumBodyBytes)
        let contentType = response.header(named: "content-type")?.split(separator: ";", maxSplits: 1).first
        let mime = contentType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !decoded.isEmpty, let mime, mime == "application/json" || mime == "text/json" || mime.hasSuffix("+json") {
          _ = try JSONSerialization.jsonObject(with: decoded, options: .fragmentsAllowed)
        }
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

  private static func decodeBody(_ body: Data, encoding: String?, maximumBodyBytes: Int) throws -> Data {
    let headers = encoding.map { ["content-encoding": [$0]] } ?? [:]
    let bytes = try PiliHTTPBodyDecoder.decode(body: body, headers: headers, maximumOutputBytes: maximumBodyBytes)
    return Data(PiliHTTPBodyDecoder.utf8AllowMalformed(bytes).utf8)
  }
}
