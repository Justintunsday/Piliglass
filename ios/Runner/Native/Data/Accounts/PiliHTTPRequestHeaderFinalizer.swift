import Foundation

/// Account ownership and terminal claims remain in the injected provider.
/// Delivers the response head after the caller selects when to write it back.
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
    return try await finalize(context, head: head)
  }

  func finalize(
    _ context: PiliHTTPRequestContext,
    head: PiliHTTPResponseHead
  ) async throws -> PiliHTTPRequestContextReceipt {
    let values: [String]
    let source: PiliHTTPRequestCookieSource
    switch head.cookieFields {
    case .separatedFields(let fields): values = fields; source = .separatedFields
    case .foundationCombined(let fields): values = fields; source = .foundationCombined
    case .unsupported:
      _ = try await provider.abandon(context)
      throw PiliHTTPRequestContextError.invalidResponse
    }
    // Do not check caller cancellation or interpret HTTP/API/body success here.
    // Once finish has been sent, an unknown/error ack never chooses abandon.
    return try await provider.finish(context, response: PiliHTTPRequestResponseCookies(
      url: head.url, statusCode: head.statusCode,
      cookieSource: source, setCookieValues: values, redirects: head.redirects, locationValues: head.locationValues
    ))
  }
}
