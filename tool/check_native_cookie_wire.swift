import Foundation
import Darwin

private struct WireFailure: Error { let message: String }

private struct WireFixture: Decodable {
  let id: String
  var wireValues: [String]
  let statusCode: Int
  let expectedBodyBytes: Int
  let cancelAfterHeaders: Bool
}

private struct WireObservation: Encodable {
  let id: String
  let wireValues: [String]
  let foundationValues: [String]
  let foundationValueType: String
  let foundationLookupValue: String?
  let statusCode: Int
  let finalURL: String?
  let receivedBodyBytes: Int
  let wireValueOrderPreserved: Bool
}

private struct CancellationObservation: Encodable {
  var events: [String] = []
  var errorCode = 0
  var receivedBodyBytes = 0
}

private struct RedirectObservation: Encodable {
  var statusCode = 0
  var followed = false
  var delegateCallbacks = 0
}

private struct WireReport: Encodable {
  var status = "failed"
  var checks = 0
  let os = ProcessInfo.processInfo.operatingSystemVersionString
  let scope = "Darwin HTTP/1.1 representation observation; not production native Cookie compatibility"
  var observations: [WireObservation] = []
  var cancellation = CancellationObservation()
  var redirect = RedirectObservation()
  var ambiguousRepresentationsEqual = false
  var reason: String?
}

private struct TransferSnapshot {
  var response: HTTPURLResponse?
  var foundationValues: [String] = []
  var foundationValueType = "missing"
  var unsupportedValue = false
  var events = ["started"]
  var bodyBytes = 0
  var error: NSError?
  var completionCount = 0
  var redirectCallbacks = 0
}

// Foundation calls delegates off the main thread. All mutable fixture state is
// private and lock-protected; unchecked conformance is confined to this probe.
private final class WireDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private let completed = DispatchSemaphore(value: 0)
  private let cancelAfterHeaders: Bool
  private let redirectDelegate = PiliHTTPRedirectDelegate()
  private var state = TransferSnapshot()

  init(cancelAfterHeaders: Bool) { self.cancelAfterHeaders = cancelAfterHeaders }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    lock.lock()
    state.events.append("headersReceived")
    state.response = response as? HTTPURLResponse
    var types: [String] = []
    if let response = state.response {
      for (key, value) in response.allHeaderFields {
        guard let name = key as? String,
              name.caseInsensitiveCompare("Set-Cookie") == .orderedSame else { continue }
        types.append(String(reflecting: type(of: value)))
        if let string = value as? String {
          state.foundationValues.append(string)
        } else if let strings = value as? [String] {
          state.foundationValues.append(contentsOf: strings)
        } else {
          state.unsupportedValue = true
        }
      }
    }
    if !types.isEmpty { state.foundationValueType = types.joined(separator: ", ") }
    state.events.append("headersCaptured")
    lock.unlock()
    completionHandler(.allow)
    if cancelAfterHeaders {
      lock.lock(); state.events.append("cancelIssued"); lock.unlock()
      dataTask.cancel()
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock(); defer { lock.unlock() }
    state.events.append("bodyReceived")
    state.bodyBytes += data.count
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    state.events.append("completed")
    state.error = error.map { $0 as NSError }
    state.completionCount += 1
    lock.unlock()
    completed.signal()
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    lock.lock(); state.redirectCallbacks += 1; lock.unlock()
    // Exercise the actual production decision on a real CFNetwork redirect.
    redirectDelegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                newRequest: request, completionHandler: completionHandler)
  }

  func wait() throws -> TransferSnapshot {
    guard completed.wait(timeout: .now() + 8) == .success else {
      throw WireFailure(message: "Timed out waiting for URLSession completion")
    }
    lock.lock(); defer { lock.unlock() }
    return state
  }
}

@main
private struct NativeCookieWireChecks {
  static func expect(_ condition: Bool, _ message: String, report: inout WireReport) throws {
    guard condition else { throw WireFailure(message: message) }
    report.checks += 1
  }

  static func loopback(_ url: URL, port: Int) -> Bool {
    url.scheme == "http" && url.host == "127.0.0.1" && url.port == port &&
      url.user == nil && url.password == nil && url.fragment == nil
  }

  static func transfer(_ url: URL, fixture: WireFixture) throws -> TransferSnapshot {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 6
    configuration.timeoutIntervalForResource = 6
    let delegate = WireDelegate(cancelAfterHeaders: fixture.cancelAfterHeaders)
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url)
    request.httpShouldHandleCookies = false
    request.setValue("fixture_request=one", forHTTPHeaderField: "Cookie")
    session.dataTask(with: request).resume()
    return try delegate.wait()
  }

  static func preservedOrder(_ wire: [String], in values: [String]) -> Bool {
    let combined = values.joined(separator: "\n")
    var cursor = combined.startIndex
    for value in wire {
      guard let range = combined.range(of: value, range: cursor..<combined.endIndex) else { return false }
      cursor = range.upperBound
    }
    return true
  }

  static func main() {
    let arguments = CommandLine.arguments
    guard arguments.count == 4 else {
      print("Usage: check-native-cookie-wire LOOPBACK_URL FIXTURES_JSON REPORT_JSON")
      exit(2)
    }
    var report = WireReport()
    do {
      guard let baseURL = URL(string: arguments[1]), let port = baseURL.port,
            (1...65535).contains(port), loopback(baseURL, port: port),
            baseURL.path == "/", baseURL.query == nil else {
        throw WireFailure(message: "Observer permits only the supplied HTTP IPv4 loopback endpoint")
      }
      let fixtures = try JSONDecoder().decode([WireFixture].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
      for var fixture in fixtures {
        guard !fixture.id.isEmpty, fixture.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-") }) else {
          throw WireFailure(message: "Invalid fixture ID")
        }
        var url = baseURL.appendingPathComponent(fixture.id)
        if fixture.id == "ambiguous-literal",
           let separated = report.observations.first(where: { $0.id == "ambiguous-separated" }),
           separated.foundationValues.count == 1 {
          let literal = separated.foundationValues[0]
          if ["a=1; Path=/x,b=2", "a=1; Path=/x, b=2"].contains(literal) {
            fixture.wireValues = [literal]
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "value", value: literal)]
            url = components.url!
          }
        }
        guard loopback(url, port: port) else { throw WireFailure(message: "Fixture escaped loopback endpoint") }
        let snapshot = try transfer(url, fixture: fixture)
        guard let response = snapshot.response else { throw WireFailure(message: "Missing HTTP response: " + fixture.id) }
        report.observations.append(WireObservation(
          id: fixture.id, wireValues: fixture.wireValues, foundationValues: snapshot.foundationValues,
          foundationValueType: snapshot.foundationValueType,
          foundationLookupValue: response.value(forHTTPHeaderField: "Set-Cookie"),
          statusCode: response.statusCode, finalURL: response.url?.absoluteString,
          receivedBodyBytes: snapshot.bodyBytes,
          wireValueOrderPreserved: preservedOrder(fixture.wireValues, in: snapshot.foundationValues)
        ))
        try expect(response.statusCode == fixture.statusCode, "Unexpected HTTP status: " + fixture.id, report: &report)
        try expect(!snapshot.foundationValues.isEmpty && !snapshot.unsupportedValue,
                   "Missing or unsupported Foundation cookie representation: " + fixture.id, report: &report)
        try expect(snapshot.completionCount == 1, "Multiple task completions: " + fixture.id, report: &report)
        try expect(snapshot.bodyBytes == fixture.expectedBodyBytes, "Unexpected body byte count: " + fixture.id, report: &report)
        if fixture.cancelAfterHeaders {
          report.cancellation = CancellationObservation(events: snapshot.events, errorCode: snapshot.error?.code ?? 0,
                                                         receivedBodyBytes: snapshot.bodyBytes)
          try expect(snapshot.events == ["started", "headersReceived", "headersCaptured", "cancelIssued", "completed"],
                     "Headers were not retained before incomplete-body cancellation", report: &report)
          try expect(snapshot.error?.domain == NSURLErrorDomain && snapshot.error?.code == URLError.cancelled.rawValue,
                     "Expected URLSession cancellation error", report: &report)
        } else {
          try expect(snapshot.error == nil, "Unexpected transfer error: " + fixture.id, report: &report)
        }
        if fixture.id == "redirect" {
          report.redirect = RedirectObservation(statusCode: response.statusCode, followed: response.url != url,
                                               delegateCallbacks: snapshot.redirectCallbacks)
          try expect(snapshot.redirectCallbacks == 1 && response.url == url,
                     "Production redirect delegate did not retain the original 302", report: &report)
        }
      }
      if let separated = report.observations.first(where: { $0.id == "ambiguous-separated" }),
         let literal = report.observations.first(where: { $0.id == "ambiguous-literal" }) {
        report.ambiguousRepresentationsEqual = separated.foundationValues == literal.foundationValues
      }
      report.status = "passed"
    } catch {
      report.reason = (error as? WireFailure)?.message ?? String(describing: error)
    }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(report).write(to: URL(fileURLWithPath: arguments[3]), options: .atomic)
    } catch {
      print("Unable to write wire observation report: \(error)")
      exit(1)
    }
    print("\(report.checks) Darwin Cookie wire observation checks \(report.status)")
    if let reason = report.reason { print(reason) }
    exit(report.status == "passed" ? 0 : 1)
  }
}
