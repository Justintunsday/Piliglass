import Foundation

enum PiliNativeCookieSelector {
  /// Matches pinned CookieJar/getCookies quirks only within a proved small-sort
  /// bound. A larger jar keeps Dart fallback instead of guessing tie ordering.
  static func compatibilityHeader(archive: PiliAccountCookieArchive, url: URL, nowMicroseconds: Int64) throws -> String {
    let archive = try archive.validated()
    guard archive.cookies.count <= 32 else { throw PiliNativeCookieError.unsupportedOrdering }
    guard let host = url.host else { throw PiliNativeCookieError.invalidField }
    guard [host, url.path].allSatisfy({ $0.utf16.allSatisfy({ $0 < 128 }) }),
          archive.cookies.allSatisfy({ [$0.domain, $0.path].allSatisfy({ $0.utf16.allSatisfy({ $0 < 128 }) }) }) else {
      throw PiliNativeCookieError.unsupportedRepresentation
    }
    func pathMatches(_ path: String) -> Bool {
      let requested = url.path.lowercased(), path = path.lowercased()
      if path == "/" || requested == path { return true }
      guard requested.hasPrefix(path) else { return false }
      return path.hasSuffix("/") || requested.dropFirst(path.count).hasPrefix("/")
    }
    func unexpired(_ cookie: PiliAccountCookieRecord) -> Bool {
      if archive.ignoreExpires { return true }
      if let maxAge = cookie.maxAgeSeconds {
        if maxAge < 1 || nowMicroseconds / 1_000_000 - cookie.createdSeconds >= maxAge { return false }
      }
      if let expires = cookie.expiresMicroseconds, expires <= nowMicroseconds { return false }
      return true
    }
    let selected = archive.cookies.filter { cookie in
      let domainMatches = cookie.hostOnly ? host == cookie.domain :
        host == cookie.domain || host.hasSuffix("." + cookie.domain)
      // Preserve and expose the old secure/expiry OR contract. This pure method
      // cannot authorize a request; production transport policy gates separately.
      return domainMatches && pathMatches(cookie.path) &&
        ((cookie.secure && url.scheme == "https") || unexpired(cookie))
    }
    // The jar visits host-only cookies first and orders their bucket paths by
    // length. Domain cookies follow insertion order. The final header then sorts
    // by the *Cookie.path* attribute, including null-before-non-null semantics.
    let loaded = selected.sorted { a, b in
      if a.hostOnly != b.hostOnly { return a.hostOnly }
      if a.hostOnly && a.path.utf16.count != b.path.utf16.count { return a.path.utf16.count > b.path.utf16.count }
      return a.sequence < b.sequence
    }
    let header = loaded.enumerated().sorted { a, b in
      switch (a.element.cookiePath, b.element.cookiePath) {
      case (nil, nil): return a.offset < b.offset
      case (nil, _): return true
      case (_, nil): return false
      case (.some(let x), .some(let y)):
        return x.utf16.count == y.utf16.count ? a.offset < b.offset : x.utf16.count > y.utf16.count
      }
    }.map { "\($0.element.name)=\($0.element.value)" }
    return header.joined(separator: "; ")
  }
}
