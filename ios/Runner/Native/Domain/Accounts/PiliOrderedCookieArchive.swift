import Foundation

/// Dart String equality compares UTF-16 units, whereas Swift String equality
/// accepts canonical equivalence. Never project these archive keys to String.
/// Unpaired surrogates and empty strings remain distinct, owned archive values.
struct PiliCookieUTF16: Sendable, Equatable, Hashable, Encodable {
  let units: [UInt16]

  init(units: [UInt16]) { self.units = units }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(units)
  }
}

enum PiliOrderedCookieArchiveError: Error, Sendable, Equatable {
  case malformedJSON, invalidArchive, unsupportedSchema, duplicateKey, resourceLimit
}

/// Shared with the Dart exporter. Limits cover both maps together, including
/// empty outer/path buckets; there is no truncation or partial publication.
struct PiliOrderedCookieArchiveLimits: Sendable, Equatable {
  var maximumEncodedBytes = 16 * 1024 * 1024
  var maximumJSONDepth = 32
  var maximumJSONNodes = 3 * 1024 * 1024
  var maximumBuckets = 8192
  var maximumCookies = 16384
  var maximumUTF16Units = 2 * 1024 * 1024
  var maximumBucketKeyUnits = 4096
  var maximumNameUnits = 1024
  var maximumValueUnits = 65536

  static let standard = Self()

  func validated() throws -> Self {
    let ceiling = Self.standard
    guard maximumEncodedBytes > 0, maximumJSONDepth > 0, maximumJSONNodes > 0,
          maximumBuckets > 0, maximumCookies > 0, maximumUTF16Units > 0,
          maximumBucketKeyUnits > 0, maximumNameUnits > 0, maximumValueUnits > 0,
          maximumEncodedBytes <= ceiling.maximumEncodedBytes,
          maximumJSONDepth <= ceiling.maximumJSONDepth, maximumJSONNodes <= ceiling.maximumJSONNodes,
          maximumBuckets <= ceiling.maximumBuckets, maximumCookies <= ceiling.maximumCookies,
          maximumUTF16Units <= ceiling.maximumUTF16Units,
          maximumBucketKeyUnits <= ceiling.maximumBucketKeyUnits,
          maximumNameUnits <= ceiling.maximumNameUnits, maximumValueUnits <= ceiling.maximumValueUnits else {
      throw PiliOrderedCookieArchiveError.resourceLimit
    }
    return self
  }
}

enum PiliOrderedCookiePriorPersistence: String, Sendable, Encodable {
  case unknown, legacyHiveReopened
}

struct PiliOrderedCookieProvenance: Sendable, Equatable, Encodable {
  let capture: String
  let priorPersistence: PiliOrderedCookiePriorPersistence
  let legacyHiveAttributesIncomplete: Bool
  let currentBucketOrderComplete: Bool
}

enum PiliOrderedCookieSameSite: String, Sendable, Encodable {
  case strict = "Strict", lax = "Lax", none = "None"
}

struct PiliOrderedCookieEntry: Sendable, Equatable, Encodable {
  /// The map key is deliberately independent of the mutable Cookie.name.
  let keyUnits: PiliCookieUTF16
  let nameUnits: PiliCookieUTF16
  let valueUnits: PiliCookieUTF16
  let cookieDomainUnits: PiliCookieUTF16?
  let cookiePathUnits: PiliCookieUTF16?
  let secure: Bool
  let httpOnly: Bool
  let sameSite: PiliOrderedCookieSameSite?
  let expiresMicroseconds: Int64?
  let maxAgeSeconds: Int64?
  let createdSeconds: Int64

  private enum CodingKeys: String, CodingKey {
    case keyUnits, nameUnits, valueUnits, cookieDomainUnits, cookiePathUnits
    case secure, httpOnly, sameSite, expiresMicroseconds, maxAgeSeconds, createdSeconds
  }

  func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(keyUnits, forKey: .keyUnits)
    try c.encode(nameUnits, forKey: .nameUnits)
    try c.encode(valueUnits, forKey: .valueUnits)
    try c.encode(secure, forKey: .secure)
    try c.encode(httpOnly, forKey: .httpOnly)
    try c.encode(createdSeconds, forKey: .createdSeconds)
    if let cookieDomainUnits { try c.encode(cookieDomainUnits, forKey: .cookieDomainUnits) }
    else { try c.encodeNil(forKey: .cookieDomainUnits) }
    if let cookiePathUnits { try c.encode(cookiePathUnits, forKey: .cookiePathUnits) }
    else { try c.encodeNil(forKey: .cookiePathUnits) }
    if let sameSite { try c.encode(sameSite, forKey: .sameSite) }
    else { try c.encodeNil(forKey: .sameSite) }
    if let expiresMicroseconds { try c.encode(expiresMicroseconds, forKey: .expiresMicroseconds) }
    else { try c.encodeNil(forKey: .expiresMicroseconds) }
    if let maxAgeSeconds { try c.encode(maxAgeSeconds, forKey: .maxAgeSeconds) }
    else { try c.encodeNil(forKey: .maxAgeSeconds) }
  }
}

struct PiliOrderedCookiePath: Sendable, Equatable, Encodable {
  let keyUnits: PiliCookieUTF16
  let cookies: [PiliOrderedCookieEntry]
}

struct PiliOrderedCookieBucket: Sendable, Equatable, Encodable {
  let keyUnits: PiliCookieUTF16
  let paths: [PiliOrderedCookiePath]
}

/// Standalone schema 2 jar only. This is neither an account identity nor an
/// authority handoff envelope. Array positions retain actual Map insertion order.
struct PiliOrderedCookieArchive: Sendable, Equatable, Encodable {
  /// dart:core DateTime's actual supported ±100,000,000-day range.
  static let maximumDateTimeMicroseconds: Int64 = 8_640_000_000_000_000_000

  let schemaVersion: Int
  let ignoreExpires: Bool
  let provenance: PiliOrderedCookieProvenance
  let domainBuckets: [PiliOrderedCookieBucket]
  let hostBuckets: [PiliOrderedCookieBucket]

  func validated(limits: PiliOrderedCookieArchiveLimits = .standard) throws -> Self {
    let limits = try limits.validated()
    guard schemaVersion == 2 else { throw PiliOrderedCookieArchiveError.unsupportedSchema }
    // CA1 accepts the actual Dart exporter contract only. Future provenance
    // policies get their own codec version instead of asserting known history.
    guard provenance.capture == "live", provenance.legacyHiveAttributesIncomplete,
          provenance.currentBucketOrderComplete else { throw PiliOrderedCookieArchiveError.invalidArchive }
    var buckets = 0, cookies = 0, units = 0
    func count(_ value: PiliCookieUTF16, maximum: Int) throws {
      guard value.units.count <= maximum, value.units.count <= limits.maximumUTF16Units - units else {
        throw PiliOrderedCookieArchiveError.resourceLimit
      }
      units += value.units.count
    }
    for group in [domainBuckets, hostBuckets] {
      var outerKeys = Set<PiliCookieUTF16>()
      for bucket in group {
        guard outerKeys.insert(bucket.keyUnits).inserted else { throw PiliOrderedCookieArchiveError.duplicateKey }
        guard buckets < limits.maximumBuckets else { throw PiliOrderedCookieArchiveError.resourceLimit }
        buckets += 1
        try count(bucket.keyUnits, maximum: limits.maximumBucketKeyUnits)
        var pathKeys = Set<PiliCookieUTF16>()
        for path in bucket.paths {
          guard pathKeys.insert(path.keyUnits).inserted else { throw PiliOrderedCookieArchiveError.duplicateKey }
          guard buckets < limits.maximumBuckets else { throw PiliOrderedCookieArchiveError.resourceLimit }
          buckets += 1
          try count(path.keyUnits, maximum: limits.maximumBucketKeyUnits)
          var cookieKeys = Set<PiliCookieUTF16>()
          for cookie in path.cookies {
            guard cookieKeys.insert(cookie.keyUnits).inserted else { throw PiliOrderedCookieArchiveError.duplicateKey }
            guard cookies < limits.maximumCookies else { throw PiliOrderedCookieArchiveError.resourceLimit }
            cookies += 1
            try count(cookie.keyUnits, maximum: limits.maximumBucketKeyUnits)
            try count(cookie.nameUnits, maximum: limits.maximumNameUnits)
            try count(cookie.valueUnits, maximum: limits.maximumValueUnits)
            if let domain = cookie.cookieDomainUnits { try count(domain, maximum: limits.maximumBucketKeyUnits) }
            if let path = cookie.cookiePathUnits { try count(path, maximum: limits.maximumBucketKeyUnits) }
            guard cookie.createdSeconds >= 0 else { throw PiliOrderedCookieArchiveError.invalidArchive }
            if let expires = cookie.expiresMicroseconds {
              guard expires >= -Self.maximumDateTimeMicroseconds,
                    expires <= Self.maximumDateTimeMicroseconds else {
                throw PiliOrderedCookieArchiveError.invalidArchive
              }
            }
          }
        }
      }
    }
    return self
  }
}
