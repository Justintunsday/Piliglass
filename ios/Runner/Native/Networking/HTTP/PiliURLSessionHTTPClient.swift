import Foundation

final class PiliURLSessionHTTPClient: PiliHTTPClient, PiliHTTPTransferring {
  private let session: URLSession

  init(configuration: URLSessionConfiguration = .ephemeral) {
    // URLSession copies configuration at initialization. Copy here as well so
    // enforcing account isolation does not mutate the caller's configuration.
    let isolated = configuration.copy() as! URLSessionConfiguration
    isolated.httpCookieStorage = nil
    isolated.httpShouldSetCookies = false
    isolated.httpCookieAcceptPolicy = .never
    isolated.urlCredentialStorage = nil
    isolated.urlCache = nil
    isolated.requestCachePolicy = .reloadIgnoringLocalCacheData
    isolated.timeoutIntervalForRequest = 10
    isolated.timeoutIntervalForResource = 10
    session = URLSession(configuration: isolated, delegate: PiliHTTPRedirectDelegate(), delegateQueue: nil)
  }

  deinit {
    session.invalidateAndCancel()
  }

  func send(_ request: URLRequest) async throws -> PiliHTTPResponse {
    try Task.checkCancellation()
    let outcome = await transfer(request)
    // Preserve the legacy body-only API's cancellation behavior. Lease owners
    // use transfer(), whose result retains headers even when the body fails.
    try Task.checkCancellation()
    switch outcome.body {
    case .success(let body):
      guard let head = outcome.head else { throw PiliHTTPClientError.invalidResponse }
      return PiliHTTPResponse(url: head.url, statusCode: head.statusCode, headers: head.headers, body: body)
    case .failure(.cancelled): throw CancellationError()
    case .failure(.client(let error)): throw error
    }
  }

  func transfer(
    _ request: URLRequest,
    onHead: @escaping @Sendable (PiliHTTPResponseHead) -> Void = { _ in }
  ) async -> PiliHTTPTransferOutcome {
    if Task.isCancelled { return PiliHTTPTransferOutcome(head: nil, body: .failure(.cancelled)) }
    guard let url = request.url, url.scheme?.lowercased() == "https",
          url.host != nil, url.user == nil, url.password == nil else {
      return PiliHTTPTransferOutcome(head: nil, body: .failure(.client(.invalidRequest)))
    }
    var isolatedRequest = request
    isolatedRequest.httpShouldHandleCookies = false
    isolatedRequest.cachePolicy = .reloadIgnoringLocalCacheData
    let transfer = PiliURLSessionHTTPTransfer(session: session, request: isolatedRequest, onHead: onHead)
    return await transfer.run()
  }
}

// Stateless session fallback: do not forward account headers to a redirect.
final class PiliHTTPRedirectDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
