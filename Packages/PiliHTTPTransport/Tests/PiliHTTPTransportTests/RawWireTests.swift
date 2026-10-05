import Foundation
import Testing
@testable import PiliHTTPTransport

private struct WireCase: Decodable {
  let id: String
  let wireValues: [String]
  let statusCode: Int
  let mode: String
  let expectedBodyBase64: String?
}

private struct WireObservation: Codable {
  let id: String
  let status: Int?
  let version: String?
  let cookieFields: [String]
  let bodyBase64: String?
  let error: String?
  let elapsedSeconds: Double
}

private final class CancellationHandle: @unchecked Sendable {
  private let lock = NSLock()
  private var task: Task<PiliRawHTTPOutcome, Never>?
  private var cancelled = false
  func bind(_ task: Task<PiliRawHTTPOutcome, Never>) {
    lock.lock(); self.task = task; let cancel = cancelled; lock.unlock()
    if cancel { task.cancel() }
  }
  func cancel() {
    lock.lock(); cancelled = true; let task = task; lock.unlock()
    task?.cancel()
  }
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
    let cancellation = CancellationHandle()
    let start = ContinuousClock.now
    let task = Task {
      await client.get(URL(string: base + "/" + item.id)!, headers: [.init(name: "Accept-Encoding", value: "br,gzip")],
        onHead: { _ in if item.mode == "pending" { cancellation.cancel() } })
    }
    cancellation.bind(task)
    if item.mode == "no-head" {
      // Cancellation only after the actual server records request arrival.
      for _ in 0..<500 {
        if FileManager.default.fileExists(atPath: output.appendingPathComponent("seen-" + item.id).path) { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      task.cancel()
    }
    let outcome = await task.value
    let elapsed = start.duration(to: .now)
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    let body: Data?, error: String?
    switch outcome.body {
    case .success(let data): body = data; error = nil
    case .failure(let value): body = nil; error = value.rawValue
    }
    observations.append(.init(id: item.id, status: outcome.head?.statusCode, version: outcome.head?.version,
      cookieFields: outcome.head?.setCookieFields ?? [], bodyBase64: body?.base64EncodedString(), error: error,
      elapsedSeconds: seconds))
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
  try await client.shutdown()
}
