import Foundation

/// One delegate-based transfer on an owner's shared session. Foundation calls
/// delegates and cancellation from different threads; every mutable field is
/// private to State and accessed under lock. No external call runs while locked.
final class PiliURLSessionHTTPTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private struct State {
    var started = false
    var closed = false
    var cancelRequested = false
    var request: URLRequest?
    var task: URLSessionDataTask?
    var continuation: CheckedContinuation<PiliHTTPTransferOutcome, Never>?
    var head: PiliHTTPResponseHead?
    var body = Data()
    var failure: PiliHTTPTransferFailure?
    var onHead: (@Sendable (PiliHTTPResponseHead) -> Void)?
  }

  private struct Completion {
    let continuation: CheckedContinuation<PiliHTTPTransferOutcome, Never>
    let outcome: PiliHTTPTransferOutcome
  }

  private let session: URLSession
  private let makeTask: @Sendable (URLSession, URLRequest) -> URLSessionDataTask
  private let lock = NSLock()
  private var state: State

  init(
    session: URLSession,
    request: URLRequest,
    makeTask: @escaping @Sendable (URLSession, URLRequest) -> URLSessionDataTask = {
      session, request in session.dataTask(with: request)
    },
    onHead: @escaping @Sendable (PiliHTTPResponseHead) -> Void = { _ in }
  ) {
    self.session = session
    self.makeTask = makeTask
    state = State(request: request, onHead: onHead)
    super.init()
  }

  func run() async -> PiliHTTPTransferOutcome {
    let firstRun = locked { state in
      guard !state.started else { return false }
      state.started = true
      return true
    }
    guard firstRun else { return PiliHTTPTransferOutcome(head: nil, body: .failure(.client(.invalidRequest))) }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in install(continuation) }
    } onCancel: {
      self.cancel()
    }
  }

  func cancel() {
    let task = locked { state -> URLSessionDataTask? in
      guard !state.closed else { return nil }
      state.cancelRequested = true
      return state.task
    }
    // A running task settles through didComplete, which still has its head.
    // Cancellation before installation is remembered for the installing path.
    task?.cancel()
  }

  private func install(_ continuation: CheckedContinuation<PiliHTTPTransferOutcome, Never>) {
    var completion: Completion?
    let request = locked { state -> URLRequest? in
      state.continuation = continuation
      if state.cancelRequested {
        completion = close(&state, body: .failure(.cancelled))
        return nil
      }
      let request = state.request
      state.request = nil
      return request
    }
    if let completion { completion.continuation.resume(returning: completion.outcome); return }
    guard let request else { return }
    // No completion-handler API: the per-task DataDelegate receives the head
    // and body. Install both delegate and waiting state before resume().
    // The factory creates a suspended task outside the lock. Cancellation in
    // this window closes locally and never resumes that task. After installation,
    // resume/cancel may race; Foundation's completion settles that cancellation.
    let task = makeTask(session, request)
    task.delegate = self
    let shouldStart = locked { state in
      if state.cancelRequested {
        completion = close(&state, body: .failure(.cancelled))
        return false
      }
      state.task = task
      return true
    }
    if shouldStart {
      task.resume()
    } else {
      task.cancel()
      if let completion { completion.continuation.resume(returning: completion.outcome) }
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    receiveHead(response, task: dataTask)
    let allow = locked { state in
      !state.closed && state.task === dataTask && !state.cancelRequested && state.failure == nil
    }
    completionHandler(allow ? .allow : .cancel)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    locked { state in
      guard !state.closed, state.task === dataTask, state.failure == nil else { return }
      state.body.append(data)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let nativeError = error.map { $0 as NSError }
    let transportCode = nativeError?.domain == NSURLErrorDomain ? nativeError?.code : nil
    let completion = locked { state -> Completion? in
      guard !state.closed, state.task === task else { return nil }
      let failure: PiliHTTPTransferFailure?
      if let stored = state.failure { failure = stored }
      else if state.cancelRequested || transportCode == URLError.cancelled.rawValue { failure = .cancelled }
      else if let nativeError { failure = .client(.transport(code: nativeError.code)) }
      else if state.head == nil { failure = .client(.invalidResponse) }
      else { failure = nil }
      let body: Result<Data, PiliHTTPTransferFailure>
      if let failure { body = .failure(failure) }
      else { body = .success(state.body) }
      return close(&state, body: body, transportErrorCode: transportCode)
    }
    if let completion { completion.continuation.resume(returning: completion.outcome) }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    // The redirect callback itself already delivered a response head. A later
    // 302 data response must not publish that head or finish the lease twice.
    receiveHead(response, task: task)
    completionHandler(nil)
  }

  private func receiveHead(_ response: URLResponse, task: URLSessionTask) {
    guard let response = response as? HTTPURLResponse, let url = response.url,
          (100...599).contains(response.statusCode) else {
      locked { state in
        if !state.closed && state.task === task { state.failure = .client(.invalidResponse) }
      }
      return
    }
    let head = Self.head(response, url: url)
    let callback = locked { state -> (@Sendable (PiliHTTPResponseHead) -> Void)? in
      guard !state.closed, state.task === task, state.head == nil else { return nil }
      state.head = head
      let callback = state.onHead
      state.onHead = nil
      return callback
    }
    callback?(head)
  }

  // Internal pure factory also permits explicit raw-value representation tests.
  // URLSession may copy/normalize synthetic HTTPURLResponse subclasses first.
  static func head(_ response: HTTPURLResponse, url: URL) -> PiliHTTPResponseHead {
    var headers: [String: String] = [:]
    var cookies: [String] = []
    var cookieFields = 0
    var unsupported = false
    for (key, raw) in response.allHeaderFields {
      guard let name = key as? String else { continue }
      if let value = raw as? String { headers[name] = value }
      guard name.caseInsensitiveCompare("Set-Cookie") == .orderedSame else { continue }
      cookieFields += 1
      if let value = raw as? String { cookies = [value] }
      else if let values = raw as? [String] { cookies = values }
      else { unsupported = true }
    }
    // Dictionary iteration gives no ordering contract for duplicate-case keys.
    let representation: PiliHTTPResponseCookieFields = unsupported || cookieFields > 1
      ? .unsupported : .foundationCombined(cookies)
    return PiliHTTPResponseHead(url: url, statusCode: response.statusCode,
                                headers: headers, cookieFields: representation)
  }

  private func close(
    _ state: inout State,
    body: Result<Data, PiliHTTPTransferFailure>,
    transportErrorCode: Int? = nil
  ) -> Completion? {
    guard !state.closed, let continuation = state.continuation else { return nil }
    let outcome = PiliHTTPTransferOutcome(head: state.head, body: body, transportErrorCode: transportErrorCode)
    state.closed = true
    state.task = nil
    state.continuation = nil
    state.request = nil
    state.onHead = nil
    state.head = nil
    state.body = Data()
    state.failure = nil
    return Completion(continuation: continuation, outcome: outcome)
  }

  private func locked<Value>(_ operation: (inout State) -> Value) -> Value {
    lock.lock()
    defer { lock.unlock() }
    return operation(&state)
  }
}
