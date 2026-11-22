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
enum PiliHTTPTransportEvidence: Sendable {
  case foundationBaseline, rawCandidate
  #if PILI_HTTP_FIXTURES
  case syntheticComplete
  #endif
}

/// Values a direct HTTP/1.1 client can represent. Constructing a profile does
/// not establish parity or allow a production request to use the client.
struct PiliRawHTTP11Profile: Sendable, Equatable {
  let poolGeneration: Int64
  let connectMicroseconds: Int64
  let receiveIdleMicroseconds: Int64?
  let poolIdleMicroseconds: Int64
  let redirectLimit: Int?
}

enum PiliRawHTTP11Preflight: Sendable, Equatable {
  case candidate(PiliRawHTTP11Profile)
  case unsupported([PiliHTTPPolicyRejection])
}

struct PiliHTTPPolicyCapability: Sendable {
  func planRawHTTP11(_ policy: PiliPreparedHTTPPolicy) -> PiliRawHTTP11Preflight {
    guard policy.version == 1, policy.isDescribed, policy.poolGeneration > 0,
          let pool = policy.pool, let retry = policy.retry else {
      return .unsupported([.undescribedPolicy])
    }
    let connect = policy.connectTimeoutMicroseconds ?? 0
    let receive = policy.receiveIdleTimeoutMicroseconds ?? 0
    let send = policy.sendTimeoutMicroseconds ?? 0
    let transform = policy.transformTimeoutMicroseconds ?? 0
    let idle = pool.idleTimeoutMicroseconds
    let durations = [connect, receive, send, transform, idle]
    let retryDelay = retry.delayMilliseconds ?? 0
    let redirectLimit = policy.followRedirects ? Int(exactly: policy.maxRedirects) : nil
    var reasons: [PiliHTTPPolicyRejection] = []
    if pool.http2Enabled || !pool.http2ALPN.isEmpty { reasons.append(.protocolSelection) }
    if pool.proxy != nil { reasons.append(.proxy) }
    if pool.http11AcceptsBadCertificate || pool.http2AcceptsBadCertificate == true {
      reasons.append(.certificateTrust)
    }
    if idle == 0 { reasons.append(.poolLifetime) }
    if durations.contains(where: { $0 < 0 }) { reasons.append(.invalidDuration) }
    let maximumRetryDelay = Int64.max / 1_000_000 / max(1, retry.count)
    if durations.contains(where: { $0 > Int64.max / 1_000 }) || retryDelay > maximumRetryDelay {
      reasons.append(.durationOverflow)
    }
    // An absent AHC connect timeout selects its default. It cannot express
    // Dio's disabled connect deadline. This slice also has no write/transform timer.
    if connect == 0 { reasons.append(.connectTimeout) }
    if send != 0 { reasons.append(.sendTimeout) }
    if transform != 0 { reasons.append(.transformTimeout) }
    if retry.count < 0 || retryDelay < 0 || retry.installed != (retry.delayMilliseconds != nil)
        || (!retry.installed && retry.count != 0) {
      reasons.append(.retry)
    }
    if policy.followRedirects, (redirectLimit ?? -1) < 0 { reasons.append(.redirect) }
    if !policy.persistentConnection { reasons.append(.persistence) }
    if !policy.receiveDataWhenStatusError { reasons.append(.errorResponseBody) }
    if policy.responseType != "json" { reasons.append(.responseType) }
    if pool.autoUncompress || policy.acceptEncoding != "br,gzip" || policy.decoder != .manualCompressionUTF8 {
      reasons.append(.compression)
    }
    if policy.decoder != .manualCompressionUTF8 { reasons.append(.malformedUTF8) }
    guard reasons.isEmpty else { return .unsupported(reasons) }
    return .candidate(PiliRawHTTP11Profile(poolGeneration: policy.poolGeneration,
      connectMicroseconds: connect, receiveIdleMicroseconds: receive == 0 ? nil : receive,
      poolIdleMicroseconds: idle, redirectLimit: redirectLimit))
  }

  func evaluate(
    _ policy: PiliPreparedHTTPPolicy,
    evidence: PiliHTTPTransportEvidence
  ) -> PiliHTTPPolicyDecision {
    let foundation: Bool
    switch evidence {
    case .rawCandidate:
      switch planRawHTTP11(policy) {
      case .candidate: return .dart([.unverifiedTransport])
      case .unsupported(let reasons): return .dart([.unverifiedTransport] + reasons)
      }
    case .foundationBaseline:
      foundation = true
    #if PILI_HTTP_FIXTURES
    case .syntheticComplete:
      foundation = false
    #endif
    }
    var reasons: [PiliHTTPPolicyRejection] = []
    func reject(_ reason: PiliHTTPPolicyRejection) {
      if !reasons.contains(reason) { reasons.append(reason) }
    }
    if !policy.isDescribed || policy.pool == nil || policy.retry == nil {
      reject(.undescribedPolicy)
    }
    if foundation { reject(.unverifiedTransport) }
    // The current wire schema does not describe arbitrary custom interceptors,
    // transformers or validateStatus. Identity stability is not parity evidence.
    if foundation { reject(.requestSemantics) }
    if let pool = policy.pool {
      if foundation { reject(.protocolSelection); reject(.poolLifetime) }
      if pool.proxy != nil && foundation { reject(.proxy) }
      if let proxy = pool.proxy, proxy.host.isEmpty || !(1...65535).contains(proxy.port) {
        reject(.proxy)
      }
      if (pool.http11AcceptsBadCertificate || pool.http2AcceptsBadCertificate == true)
          && foundation { reject(.certificateTrust) }
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
      if foundation { reject(reason) }
    }
    if let retry = policy.retry {
      if retry.count < 0 || (retry.delayMilliseconds ?? 0) < 0 { reject(.retry) }
      if let delay = retry.delayMilliseconds,
         delay > Int64.max / 1_000_000 { reject(.durationOverflow) }
      if foundation { reject(.retry) }
    }
    if policy.followRedirects && (foundation || policy.maxRedirects < 0) { reject(.redirect) }
    if foundation { reject(.persistence); reject(.errorResponseBody) }
    if policy.responseType != "json" { reject(.responseType) }
    if policy.decoder != .manualCompressionUTF8 || foundation {
      reject(.compression); reject(.malformedUTF8)
    }
    if policy.acceptEncoding != "br,gzip" { reject(.compression) }
    if foundation { reject(.cookieFieldOrder) }
    return reasons.isEmpty ? .native : .dart(reasons)
  }
}
