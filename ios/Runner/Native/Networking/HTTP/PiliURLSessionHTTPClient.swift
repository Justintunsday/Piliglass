import Foundation

final class PiliURLSessionHTTPClient: PiliHTTPClient {
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
    session = URLSession(configuration: isolated)
  }

  deinit {
    session.invalidateAndCancel()
  }

  func send(_ request: URLRequest) async throws -> PiliHTTPResponse {
    try Task.checkCancellation()
    guard let url = request.url, url.scheme?.lowercased() == "https",
          url.host != nil, url.user == nil, url.password == nil else {
      throw PiliHTTPClientError.invalidRequest
    }
    var isolatedRequest = request
    isolatedRequest.httpShouldHandleCookies = false
    isolatedRequest.cachePolicy = .reloadIgnoringLocalCacheData
    do {
      let (body, response) = try await session.data(
        for: isolatedRequest, delegate: PiliHTTPRedirectDelegate()
      )
      try Task.checkCancellation()
      guard let response = response as? HTTPURLResponse, let finalURL = response.url else {
        throw PiliHTTPClientError.invalidResponse
      }
      var headers: [String: String] = [:]
      for (key, value) in response.allHeaderFields {
        if let key = key as? String, let value = value as? String {
          headers[key] = value
        }
      }
      // Keep Foundation's header values intact, including combined Set-Cookie.
      // Cookie parsing and ownership belong to the account context layer.
      return PiliHTTPResponse(url: finalURL, statusCode: response.statusCode,
                              headers: headers, body: body)
    } catch let error as URLError {
      if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
      throw PiliHTTPClientError.transport(code: error.code.rawValue)
    } catch {
      try Task.checkCancellation()
      throw error
    }
  }
}

// Stateless per-task delegate: do not forward account headers to a redirect.
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
