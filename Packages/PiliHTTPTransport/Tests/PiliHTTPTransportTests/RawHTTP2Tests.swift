import Foundation
import Testing
@testable import PiliHTTPTransport

private struct TLSWireCase: Decodable {
  let id: String
  let status: Int
  let fields: [String]
  let bodyBase64: String
  let mode: String
}
private struct TLSWireObservation: Codable {
  let id: String
  let protocolMode: String
  let status: Int?
  let version: String?
  let fields: [String]
  let bodyBase64: String?
  let failure: String?
}
private final class TLSCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var task: Task<PiliRawHTTPOutcome, Never>?
  private var cancelled = false
  func bind(_ value: Task<PiliRawHTTPOutcome, Never>) {
    lock.lock(); task = value; let pending = cancelled; lock.unlock()
    if pending { value.cancel() }
  }
  func cancel() { lock.lock(); cancelled = true; let value = task; lock.unlock(); value?.cancel() }
}

/// Environment isolation lets the H1 suite run independently. The Python H2
/// driver must explicitly run this test and validate the server's actual ALPN.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PILI_RAW_TLS_BASE"] != nil))
func rawTLSAndHTTP2Probe() async throws {
  let env = ProcessInfo.processInfo.environment
  let base = try #require(env["PILI_RAW_TLS_BASE"])
  let h1Base = try #require(env["PILI_RAW_TLS_H1_BASE"])
  let badNameBase = try #require(env["PILI_RAW_TLS_BAD_NAME_BASE"])
  let directory = URL(fileURLWithPath: try #require(env["PILI_RAW_TLS_OUTPUT"]))
  let trustFile = try #require(env["PILI_RAW_TLS_TRUST_ROOT"])
  let cases = try JSONDecoder().decode([TLSWireCase].self, from: Data(contentsOf: directory.appendingPathComponent("fixtures.json")))
  var observations: [TLSWireObservation] = []
  for protocolMode in [PiliRawHTTPTransport.Configuration.ProtocolMode.automatic, .http11] {
    let label = protocolMode == .automatic ? "automatic" : "http11"
    let client = try PiliRawHTTPTransport(configuration: .init(protocolMode: protocolMode),
                                          loopbackFixture: true, fixtureTrustRootsFile: trustFile)
    for item in cases {
      let cancel = TLSCancellation()
      let task = Task {
        await client.get(URL(string: base + "/" + label + "/" + item.id)!,
          headers: [.init(name: "Accept-Encoding", value: "br,gzip"), .init(name: "X-Fixture", value: label)],
          onHead: { _ in if item.mode == "cancel" { cancel.cancel() } })
      }
      cancel.bind(task)
      let outcome = await task.value
      let body: Data?, failure: String?
      switch outcome.body {
      case .success(let data): body = data; failure = nil
      case .failure(let error): body = nil; failure = error.rawValue
      }
      observations.append(.init(id: item.id, protocolMode: label, status: outcome.head?.statusCode,
        version: outcome.head?.version, fields: outcome.head?.setCookieFields ?? [],
        bodyBase64: body?.base64EncodedString(), failure: failure))
      #expect(outcome.head?.statusCode == item.status)
      #expect(outcome.head?.version == (protocolMode == .automatic ? "2.0" : "1.1"))
      #expect(outcome.head?.setCookieFields == item.fields)
      if item.mode == "cancel" { #expect(failure == "cancelled") }
      else { #expect(failure == nil); #expect(body?.base64EncodedString() == item.bodyBase64) }
    }
    // A trusted root must still enforce hostname verification; never use
    // certificateVerification=.none even for loopback fixtures.
    let badName = await client.get(URL(string: badNameBase + "/" + label + "/wrong-name")!)
    #expect(badName.head == nil)
    #expect(throws: PiliRawHTTPFailure.transport) { try badName.body.get() }
    observations.append(.init(id: "hostname-rejected", protocolMode: label, status: nil,
      version: nil, fields: [], bodyBase64: nil, failure: failureName(badName)))
    try await client.shutdown()
    // Public construction keeps system trust. Our synthetic root is not trusted.
    let publicClient = try PiliRawHTTPTransport(configuration: .init(protocolMode: protocolMode))
    let rejected = await publicClient.get(URL(string: base + "/" + label + "/untrusted")!)
    #expect(rejected.head == nil)
    #expect(throws: PiliRawHTTPFailure.transport) { try rejected.body.get() }
    observations.append(.init(id: "trust-rejected", protocolMode: label, status: nil,
      version: nil, fields: [], bodyBase64: nil, failure: failureName(rejected)))
    try await publicClient.shutdown()
  }
  // The automatic client really falls back when TLS advertises only HTTP/1.1.
  let fallback = try PiliRawHTTPTransport(configuration: .init(protocolMode: .automatic),
                                         loopbackFixture: true, fixtureTrustRootsFile: trustFile)
  let h1 = await fallback.get(URL(string: h1Base + "/fallback/single")!)
  #expect(h1.head?.version == "1.1")
  #expect(h1.head?.setCookieFields == cases.first!.fields)
  #expect(try h1.body.get() == Data(base64Encoded: cases.first!.bodyBase64))
  observations.append(.init(id: "automatic-h1-fallback", protocolMode: "automatic", status: h1.head?.statusCode,
    version: h1.head?.version, fields: h1.head?.setCookieFields ?? [],
    bodyBase64: try? h1.body.get().base64EncodedString(), failure: failureName(h1)))
  try await fallback.shutdown()
  let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  try encoder.encode(observations).write(to: directory.appendingPathComponent("observations.json"))
}

private func failureName(_ outcome: PiliRawHTTPOutcome) -> String? {
  if case .failure(let error) = outcome.body { return error.rawValue }; return nil
}
