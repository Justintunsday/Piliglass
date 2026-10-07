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
    var budget = try PiliOrderedCookieArchiveBudget(limits: limits)
    return try validated(budget: &budget)
  }

  /// Shared-ledger entry for one complete account capture. The caller owns the
  /// ledger across metadata, raw keys, credentials and every jar; each jar still
  /// runs all of its own duplicate, attribute and raw-key checks.
  func validated(budget: inout PiliOrderedCookieArchiveBudget) throws -> Self {
    let limits = budget.limits
    guard schemaVersion == 2 else { throw PiliOrderedCookieArchiveError.unsupportedSchema }
    // CA1 accepts the actual Dart exporter contract only. Future provenance
    // policies get their own codec version instead of asserting known history.
    guard provenance.capture == "live", provenance.legacyHiveAttributesIncomplete,
          provenance.currentBucketOrderComplete else { throw PiliOrderedCookieArchiveError.invalidArchive }
    for group in [domainBuckets, hostBuckets] {
      var outerKeys = Set<PiliCookieUTF16>()
      for bucket in group {
        guard outerKeys.insert(bucket.keyUnits).inserted else { throw PiliOrderedCookieArchiveError.duplicateKey }
        try budget.addBucket()
        try budget.count(bucket.keyUnits, maximum: limits.maximumBucketKeyUnits)
        var pathKeys = Set<PiliCookieUTF16>()
        for path in bucket.paths {
          guard pathKeys.insert(path.keyUnits).inserted else { throw PiliOrderedCookieArchiveError.duplicateKey }
          try budget.addBucket()
          try budget.count(path.keyUnits, maximum: limits.maximumBucketKeyUnits)
          var cookieKeys = Set<PiliCookieUTF16>()
          for cookie in path.cookies {
            guard cookieKeys.insert(cookie.keyUnits).inserted else { throw PiliOrderedCookieArchiveError.duplicateKey }
            try budget.addCookie()
            try budget.count(cookie.keyUnits, maximum: limits.maximumBucketKeyUnits)
            try budget.count(cookie.nameUnits, maximum: limits.maximumNameUnits)
            try budget.count(cookie.valueUnits, maximum: limits.maximumValueUnits)
            if let domain = cookie.cookieDomainUnits { try budget.count(domain, maximum: limits.maximumBucketKeyUnits) }
            if let path = cookie.cookiePathUnits { try budget.count(path, maximum: limits.maximumBucketKeyUnits) }
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

/// Cumulative ledger for one account-capture candidate. Standalone jar decode
/// creates its own; the full account envelope shares one ledger across metadata,
/// raw keys, credentials and every jar. Counts check the remaining budget before
/// adding, so no candidate silently exceeds the declared limits.
struct PiliOrderedCookieArchiveBudget {
  let limits: PiliOrderedCookieArchiveLimits
  private var buckets = 0
  private var cookies = 0
  private var units = 0

  init(limits: PiliOrderedCookieArchiveLimits) throws {
    self.limits = try limits.validated()
  }

  mutating func reserveUnits(_ count: Int) throws {
    guard count >= 0, count <= limits.maximumUTF16Units - units else {
      throw PiliOrderedCookieArchiveError.resourceLimit
    }
    units += count
  }

  mutating func countUnits(_ count: Int, maximum: Int) throws {
    guard count >= 0, count <= maximum, count <= limits.maximumUTF16Units - units else {
      throw PiliOrderedCookieArchiveError.resourceLimit
    }
    units += count
  }

  mutating func count(_ value: PiliCookieUTF16?, maximum: Int) throws {
    guard let value else { return }
    try countUnits(value.units.count, maximum: maximum)
  }

  mutating func addBuckets(_ count: Int) throws {
    guard count >= 0, count <= limits.maximumBuckets - buckets else {
      throw PiliOrderedCookieArchiveError.resourceLimit
    }
    buckets += count
  }

  mutating func addBucket() throws { try addBuckets(1) }

  mutating func addCookies(_ count: Int) throws {
    guard count >= 0, count <= limits.maximumCookies - cookies else {
      throw PiliOrderedCookieArchiveError.resourceLimit
    }
    cookies += count
  }

  mutating func addCookie() throws { try addCookies(1) }
}
