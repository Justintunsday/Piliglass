import Foundation
import Testing
@testable import PiliHTTPTransport

private struct WireCase: Decodable {
  let id: String
  let wireValues: [String]
  let statusCode: Int?
  let mode: String
  let expectedBodyBase64: String?
  let redirectLimit: Int?
  let nativeError: String?
  let nativeTargets: [String]?
  let redirectLocations: [String]?
}

private struct WireObservation: Codable {
  let id: String
  let status: Int?
  let version: String?
  let cookieFields: [String]
  let bodyBase64: String?
  let error: String?
  let elapsedSeconds: Double
  let terminalURL: String?
  let redirectLocations: [String]
}

private final class WireTransferProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var task: Task<PiliRawHTTPOutcome, Never>?
  private var cancelled = false
  private var heads: [PiliRawHTTPHead] = []
  private var byteCount = 0
  func bind(_ task: Task<PiliRawHTTPOutcome, Never>) {
    lock.lock(); self.task = task; let cancel = cancelled; lock.unlock()
    if cancel { task.cancel() }
  }
  func cancel() {
    lock.lock(); cancelled = true; let task = task; lock.unlock()
    task?.cancel()
  }

  func recordHead(_ head: PiliRawHTTPHead) { lock.withLock { heads.append(head) } }
  func recordChunk(_ size: Int) { lock.withLock { byteCount += size } }
  var callbacks: (heads: [PiliRawHTTPHead], bytes: Int) { lock.withLock { (heads, byteCount) } }
}

@Test func rawHeaderAndIdleWire() async throws {
  let env = ProcessInfo.processInfo.environment
  guard let base = env["PILI_RAW_WIRE_BASE"], let directory = env["PILI_RAW_WIRE_OUTPUT"] else {
    Issue.record("Real loopback server and output path required; cannot pass using fixtures alone")
    return
  }
  let output = URL(fileURLWithPath: directory)
  let cases = try JSONDecoder().decode([WireCase].self, from: Data(contentsOf: output.appendingPathComponent("fixtures.json")))
  let client = try PiliRawHTTPTransport(configuration: .init(), loopbackFixture: true)
  var observations: [WireObservation] = []
  for item in cases {
    let probe = WireTransferProbe()
    var fields: [PiliRawHTTPField] = [.init(name: "Accept-Encoding", value: "br,gzip")]
    if item.redirectLimit != nil {
      fields.append(.init(name: "Cookie", value: "wire=synthetic"))
      fields.append(.init(name: "Authorization", value: "Bearer synthetic"))
    }
    let start = ContinuousClock.now
    let task = Task { [fields] in
      await client.get(URL(string: base + "/" + item.id)!, headers: fields, sameOriginRedirectLimit: item.redirectLimit,
        onHead: { head in
          probe.recordHead(head)
          if item.mode == "pending" { probe.cancel() }
        }, onChunk: { probe.recordChunk($0) })
    }
    probe.bind(task)
    if item.mode == "no-head" || item.mode == "cancel-redirect" {
      let marker = output.appendingPathComponent("seen-" + item.id).path
      for _ in 0..<500 {
        if FileManager.default.fileExists(atPath: marker) { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(FileManager.default.fileExists(atPath: marker))
      task.cancel()
    }
    let outcome = await task.value
    #expect(!outcome.failedDuringInitialConnection)
    let elapsed = start.duration(to: .now)
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    let body: Data?, error: String?
    switch outcome.body {
    case .success(let data): body = data; error = nil
    case .failure(let value): body = nil; error = value.rawValue
    }
    observations.append(.init(id: item.id, status: outcome.head?.statusCode, version: outcome.head?.version,
      cookieFields: outcome.head?.setCookieFields ?? [], bodyBase64: body?.base64EncodedString(), error: error,
      elapsedSeconds: seconds, terminalURL: outcome.head?.url.absoluteString,
      redirectLocations: outcome.head?.redirects.map(\.location) ?? []))
    let callbacks = probe.callbacks
    #expect(callbacks.heads == (outcome.head.map { [$0] } ?? []))
    if item.redirectLimit != nil {
      #expect(error == item.nativeError)
      if item.nativeError == nil {
        let targets = try #require(item.nativeTargets)
        let terminal = try #require(targets.last)
        #expect(outcome.head?.url.absoluteString == base + "/" + terminal)
        #expect(outcome.head?.statusCode == item.statusCode)
        #expect(outcome.head?.version == "1.1")
        #expect(outcome.head?.setCookieFields == item.wireValues)
        #expect(body?.base64EncodedString() == item.expectedBodyBase64)
        #expect(callbacks.bytes == body?.count)
        #expect(outcome.head?.redirects.map(\.location) == item.redirectLocations)
        #expect(outcome.head?.redirects.map { $0.url.absoluteString } == targets.dropFirst().map { base + "/" + $0 })
      } else {
        #expect(outcome.head == nil)
        #expect(body == nil)
        #expect(callbacks.bytes == 0)
      }
      continue
    }
    if item.mode == "no-head" {
      #expect(outcome.head == nil)
      #expect(error == "cancelled")
    } else {
      #expect(outcome.head?.statusCode == item.statusCode)
      #expect(outcome.head?.setCookieFields == item.wireValues)
      #expect(outcome.head?.version == "1.1")
    }
    switch item.mode {
    case "pending", "no-head":
      #expect(error == "cancelled")
      #expect(body == nil)
    case "eof": #expect(error != nil)
    case "idle-timeout": #expect(error == "receiveIdleTimeout")
    default:
      #expect(error == nil)
      if let expected = item.expectedBodyBase64 { #expect(body?.base64EncodedString() == expected) }
      if item.mode == "long-stream" { #expect(seconds > 10) }
    }
  }
  try await client.shutdown()
  let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  try encoder.encode(observations).write(to: output.appendingPathComponent("observations.json"))
}

@Test func rawInitialConnectionRefused() async throws {
  let port = try #require(ProcessInfo.processInfo.environment["PILI_RAW_REFUSED_PORT"].flatMap(Int.init))
  let client = try PiliRawHTTPTransport(configuration: .init(), loopbackFixture: true)
  for scheme in ["http", "https"] {
    let outcome = await client.get(URL(string: "\(scheme)://127.0.0.1:\(port)/fixture")!)
    #expect(outcome.head == nil)
    #expect(outcome.failedDuringInitialConnection)
    #expect(throws: PiliRawHTTPFailure.connectionRefused) { try outcome.body.get() }
  }
  try await client.shutdown()
}

@Test func rawConfigurationRejectsUnknownSemantics() async throws {
  for config in [PiliRawHTTPTransport.Configuration(connectMicroseconds: 0),
                 .init(connectMicroseconds: -1), .init(connectMicroseconds: .max),
                 .init(receiveIdleMicroseconds: -1), .init(poolIdleMicroseconds: .max)] {
    #expect(throws: PiliRawHTTPFailure.invalidConfiguration) { try PiliRawHTTPTransport(configuration: config) }
  }
  let client = try PiliRawHTTPTransport()
  let outcome = await client.get(URL(string: "http://example.invalid/")!)
  #expect(outcome.head == nil)
  #expect(throws: PiliRawHTTPFailure.invalidRequest) { try outcome.body.get() }
  let negativeLimit = await client.get(URL(string: "https://example.invalid/")!, sameOriginRedirectLimit: -1)
  #expect(throws: PiliRawHTTPFailure.invalidRequest) { try negativeLimit.body.get() }
  try await client.shutdown()
}
