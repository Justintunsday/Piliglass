import Foundation

/// Account ownership and terminal claims remain in the injected provider.
/// A body failure never discards a response head already captured by transport.
struct PiliHTTPRequestHeaderFinalizer: Sendable {
  private let provider: any PiliHTTPRequestContextProviding

  init(provider: any PiliHTTPRequestContextProviding) {
    self.provider = provider
  }

  func finalize(
    _ context: PiliHTTPRequestContext,
    outcome: PiliHTTPTransferOutcome
  ) async throws -> PiliHTTPRequestContextReceipt {
    guard let head = outcome.head else {
      return try await provider.abandon(context)
    }
    guard case .foundationCombined(let values) = head.cookieFields else {
      _ = try await provider.abandon(context)
      throw PiliHTTPRequestContextError.invalidResponse
    }
    // Do not check caller cancellation or interpret HTTP/API/body success here.
    // Once finish has been sent, an unknown/error ack never chooses abandon.
    return try await provider.finish(context, response: PiliHTTPRequestResponseCookies(
      url: head.url, statusCode: head.statusCode,
      cookieSource: .foundationCombined, setCookieValues: values
    ))
  }
}
