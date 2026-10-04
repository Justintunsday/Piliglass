import Foundation

/// Reasons are identifiers only; never include headers, credentials or proxy hosts.
enum PiliHTTPPolicyRejection: String, Sendable, Equatable, CaseIterable {
  case undescribedPolicy, unverifiedTransport, requestSemantics
  case protocolSelection, proxy, certificateTrust, poolLifetime
  case invalidDuration, durationOverflow, connectTimeout, receiveIdleTimeout
  case sendTimeout, transformTimeout, retry, redirect, persistence
  case compression, malformedUTF8, responseType, errorResponseBody, cookieFieldOrder
}

enum PiliHTTPPolicyDecision: Sendable, Equatable {
  case native
  case dart([PiliHTTPPolicyRejection])
}

/// Evidence belongs to a transport implementation, never a user preference.
/// No production transport has a complete verified profile yet. The fixture
/// factory is absent from the app binary and cannot open a runtime gate.
struct PiliHTTPTransportEvidence: Sendable {
  fileprivate let verified: Bool
  fileprivate let allSemantics: Bool
  static let foundationBaseline = Self(verified: false, allSemantics: false)
  static let rawCandidate = Self(verified: false, allSemantics: false)

  #if PILI_HTTP_FIXTURES
  static let syntheticComplete = Self(verified: true, allSemantics: true)
  #endif
}

struct PiliHTTPPolicyCapability: Sendable {
  func evaluate(
    _ policy: PiliPreparedHTTPPolicy,
    evidence: PiliHTTPTransportEvidence
  ) -> PiliHTTPPolicyDecision {
    var reasons: [PiliHTTPPolicyRejection] = []
    func reject(_ reason: PiliHTTPPolicyRejection) {
      if !reasons.contains(reason) { reasons.append(reason) }
    }
    if !policy.isDescribed || policy.pool == nil || policy.retry == nil {
      reject(.undescribedPolicy)
    }
    if !evidence.verified { reject(.unverifiedTransport) }
    // The current wire schema does not describe arbitrary custom interceptors,
    // transformers or validateStatus. Identity stability is not parity evidence.
    if !evidence.allSemantics { reject(.requestSemantics) }
    if let pool = policy.pool {
      if !evidence.allSemantics { reject(.protocolSelection); reject(.poolLifetime) }
      if pool.proxy != nil && !evidence.allSemantics { reject(.proxy) }
      if let proxy = pool.proxy, proxy.host.isEmpty || !(1...65535).contains(proxy.port) {
        reject(.proxy)
      }
      if (pool.http11AcceptsBadCertificate || pool.http2AcceptsBadCertificate == true)
          && !evidence.allSemantics { reject(.certificateTrust) }
      if pool.idleTimeoutMicroseconds < 0 { reject(.invalidDuration) }
      if pool.idleTimeoutMicroseconds > Int64.max / 1_000 { reject(.durationOverflow) }
      if pool.autoUncompress { reject(.compression) }
    }
    let durations: [(Int64?, PiliHTTPPolicyRejection)] = [
      (policy.connectTimeoutMicroseconds, .connectTimeout),
      (policy.receiveIdleTimeoutMicroseconds, .receiveIdleTimeout),
      (policy.sendTimeoutMicroseconds, .sendTimeout),
      (policy.transformTimeoutMicroseconds, .transformTimeout),
    ]
    for (duration, reason) in durations {
      if let duration {
        if duration < 0 { reject(.invalidDuration) }
        if duration > Int64.max / 1_000 { reject(.durationOverflow) }
      }
      // nil/zero mean disabled in Dio; a transport default is not equivalent.
      if !evidence.allSemantics { reject(reason) }
    }
    if let retry = policy.retry {
      if retry.count < 0 || (retry.delayMilliseconds ?? 0) < 0 { reject(.retry) }
      if let delay = retry.delayMilliseconds,
         delay > Int64.max / 1_000_000 { reject(.durationOverflow) }
      if !evidence.allSemantics { reject(.retry) }
    }
    if policy.followRedirects { reject(.redirect) }
    if !evidence.allSemantics { reject(.persistence); reject(.errorResponseBody) }
    if policy.responseType != "json" { reject(.responseType) }
    if policy.decoder != .manualCompressionUTF8 || !evidence.allSemantics {
      reject(.compression); reject(.malformedUTF8)
    }
    if policy.acceptEncoding != "br,gzip" { reject(.compression) }
    if !evidence.allSemantics { reject(.cookieFieldOrder) }
    return reasons.isEmpty ? .native : .dart(reasons)
  }
}
