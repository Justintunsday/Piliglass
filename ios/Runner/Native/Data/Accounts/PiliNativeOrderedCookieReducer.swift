import Foundation

enum PiliOrderedCookieMutationError: Error, Sendable, Equatable {
  case invalidClock, unsupportedLocation, unsupportedField, batchResourceLimit
}

/// Values already normalized by Dart Uri. This is a compatibility input, not a
/// URL parser or permission to issue a request. Unicode/percent URI semantics
/// remain outside the accepted transport boundary.
struct PiliOrderedCookieResponseLocation: Sendable, Equatable {
  let host: String
  let path: String

  fileprivate func validated() throws -> Self {
    guard [host, path].allSatisfy({ value in
      value.utf16.count <= PiliOrderedCookieArchiveLimits.standard.maximumBucketKeyUnits &&
        value.utf16.allSatisfy { $0 < 128 && $0 >= 32 && $0 != 37 }
    }) else { throw PiliOrderedCookieMutationError.unsupportedLocation }
    return self
  }
}

/// Uninstalled, pure CookieJar 4.0.9 state transition candidate. Owned arrays
/// preserve Dart map key equality and insertion order, including empty maps.
/// No account identity, persistence, authority switch, or network access exists.
struct PiliNativeOrderedCookieReducer: Sendable {
  var limits: PiliOrderedCookieArchiveLimits = .standard

  func save(_ jar: PiliOrderedCookieArchive, fields: [String],
    representation: PiliNativeCookieFieldRepresentation,
    location: PiliOrderedCookieResponseLocation, nowMicroseconds: Int64
  ) throws -> PiliOrderedCookieArchive {
    let limits = try limits.validated()
    _ = try PiliOrderedCookieArchiveCodec(limits: limits).encode(jar)
    let location = try location.validated()
    guard nowMicroseconds >= 0,
          nowMicroseconds <= PiliOrderedCookieArchive.maximumDateTimeMicroseconds else {
      throw PiliOrderedCookieMutationError.invalidClock
    }
    guard fields.count <= 4096 else { throw PiliOrderedCookieMutationError.batchResourceLimit }
    var remaining = limits.maximumEncodedBytes
    for field in fields {
      // Existing parser has proved ASCII Cookie/path behavior; do not widen it
      // just because the archive can represent arbitrary UTF16 map seeds.
      guard field.utf16.allSatisfy({ $0 < 128 }) else {
        throw PiliOrderedCookieMutationError.unsupportedField
      }
      guard field.utf8.count <= remaining else {
        throw PiliOrderedCookieMutationError.batchResourceLimit
      }
      remaining -= field.utf8.count
    }
    let created = nowMicroseconds / 1_000_000
    // Parser location-derived bucket fields are intentionally unused here.
    // Parsing Cookie attributes does not depend on the response location; the
    // explicit Dart context below also supports Dart Uri's empty host case.
    let parserLocation = URL(string: "https://cookie-parser.invalid/")!
    let parsed = try PiliNativeCookieParser.parseFields(fields, representation: representation,
      responseURL: parserLocation, createdSeconds: created)
    var domains = jar.domainBuckets, hosts = jar.hostBuckets
    for cookie in parsed {
      let domain = cookie.cookieDomain.map { value in
        value.hasPrefix(".") ? String(value.dropFirst()) : value
      }
      let bucketHost = domain ?? location.host
      let bucketPath: String
      if let path = cookie.cookiePath { bucketPath = path }
      else if domain != nil { bucketPath = "/" }
      else if location.path.isEmpty { bucketPath = "/" }
      else {
        bucketPath = location.path.split(separator: "/", omittingEmptySubsequences: false)
          .dropLast().joined(separator: "/")
      }
      let entry = PiliOrderedCookieEntry(keyUnits: units(cookie.name), nameUnits: units(cookie.name),
        valueUnits: units(cookie.value), cookieDomainUnits: cookie.cookieDomain.map(units),
        cookiePathUnits: cookie.cookiePath.map(units), secure: cookie.secure, httpOnly: cookie.httpOnly,
        sameSite: cookie.sameSite.flatMap(PiliOrderedCookieSameSite.init(rawValue:)),
        expiresMicroseconds: cookie.expiresMicroseconds, maxAgeSeconds: cookie.maxAgeSeconds,
        createdSeconds: created)
      let expired = !jar.ignoreExpires && isExpired(entry, nowMicroseconds: nowMicroseconds)
      if domain != nil { apply(entry, host: units(bucketHost), path: units(bucketPath), expired: expired, to: &domains) }
      else { apply(entry, host: units(bucketHost), path: units(bucketPath), expired: expired, to: &hosts) }
    }
    return try checked(jar, domains: domains, hosts: hosts)
  }

  func delete(_ jar: PiliOrderedCookieArchive, host: String,
    withDomainSharedCookie: Bool = false
  ) throws -> PiliOrderedCookieArchive {
    _ = try PiliOrderedCookieResponseLocation(host: host, path: "").validated()
    _ = try PiliOrderedCookieArchiveCodec(limits: limits).encode(jar)
    let key = units(host)
    let hosts = jar.hostBuckets.filter { $0.keyUnits != key }
    let domains = withDomainSharedCookie ? jar.domainBuckets.filter {
      !domainMatches(host: key.units, domain: $0.keyUnits.units)
    } : jar.domainBuckets
    return try checked(jar, domains: domains, hosts: hosts)
  }

  func deleteAll(_ jar: PiliOrderedCookieArchive) throws -> PiliOrderedCookieArchive {
    _ = try PiliOrderedCookieArchiveCodec(limits: limits).encode(jar)
    return try checked(jar, domains: [], hosts: [])
  }

  private func units(_ value: String) -> PiliCookieUTF16 { .init(units: Array(value.utf16)) }

  private func checked(_ jar: PiliOrderedCookieArchive, domains: [PiliOrderedCookieBucket],
    hosts: [PiliOrderedCookieBucket]
  ) throws -> PiliOrderedCookieArchive {
    let candidate = PiliOrderedCookieArchive(schemaVersion: jar.schemaVersion,
      ignoreExpires: jar.ignoreExpires, provenance: jar.provenance,
      domainBuckets: domains, hostBuckets: hosts)
    // Includes complete encoded byte/depth/node limits, not only entry counts.
    _ = try PiliOrderedCookieArchiveCodec(limits: limits).encode(candidate)
    return candidate
  }

  private func isExpired(_ entry: PiliOrderedCookieEntry, nowMicroseconds: Int64) -> Bool {
    if let age = entry.maxAgeSeconds {
      // Both nonnegative timestamps fit Int64; their difference cannot overflow.
      if age < 1 || nowMicroseconds / 1_000_000 - entry.createdSeconds >= age { return true }
    }
    return entry.expiresMicroseconds.map { $0 <= nowMicroseconds } ?? false
  }

  private func domainMatches(host: [UInt16], domain: [UInt16]) -> Bool {
    if host == domain { return true }
    guard host.count > domain.count, host.suffix(domain.count).elementsEqual(domain) else { return false }
    return host[host.count - domain.count - 1] == 46
  }

  private func apply(_ entry: PiliOrderedCookieEntry, host: PiliCookieUTF16,
    path: PiliCookieUTF16, expired: Bool, to buckets: inout [PiliOrderedCookieBucket]
  ) {
    let outerIndex = buckets.firstIndex { $0.keyUnits == host } ?? buckets.count
    var paths = outerIndex == buckets.count ? [] : buckets[outerIndex].paths
    let pathIndex = paths.firstIndex { $0.keyUnits == path } ?? paths.count
    var cookies = pathIndex == paths.count ? [] : paths[pathIndex].cookies
    if let index = cookies.firstIndex(where: { $0.keyUnits == entry.keyUnits }) {
      if expired { cookies.remove(at: index) } else { cookies[index] = entry }
    } else if !expired { cookies.append(entry) }
    let nextPath = PiliOrderedCookiePath(keyUnits: path, cookies: cookies)
    if pathIndex == paths.count { paths.append(nextPath) } else { paths[pathIndex] = nextPath }
    let nextBucket = PiliOrderedCookieBucket(keyUnits: host, paths: paths)
    if outerIndex == buckets.count { buckets.append(nextBucket) } else { buckets[outerIndex] = nextBucket }
  }
}
