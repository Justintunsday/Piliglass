import Foundation
import Security

protocol PiliAccountSecretStore: Sendable {
  func read(_ key: String) async throws -> Data?
  func write(_ data: Data, key: String) async throws
  func remove(_ key: String) async throws
}

enum PiliAccountStorageError: Error, Sendable, Equatable {
  case keychain(Int32), invalidArchive, unsupportedSchema, writesNotAllowed, operationInProgress
}

/// Dedicated staging service; never shares an account with the production Hive authority.
actor PiliAccountKeychainSecretStore: PiliAccountSecretStore {
  private let service: String

  init(stagingNamespace: UUID) {
    service = "com.piliglass.native-account-staging.\(stagingNamespace.uuidString.lowercased())"
  }

  func read(_ key: String) throws -> Data? {
    var query = base(key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var value: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &value)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw PiliAccountStorageError.keychain(status) }
    guard let data = value as? Data else { throw PiliAccountStorageError.invalidArchive }
    return data
  }

  func write(_ data: Data, key: String) throws {
    let query = base(key)
    let update = [kSecValueData as String: data]
    var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var insertion = query
      insertion[kSecValueData as String] = data
      #if os(iOS)
      insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      #endif
      status = SecItemAdd(insertion as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw PiliAccountStorageError.keychain(status) }
  }

  func remove(_ key: String) throws {
    let status = SecItemDelete(base(key) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw PiliAccountStorageError.keychain(status)
    }
  }

  private func base(_ key: String) -> [String: Any] {
    var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: key, kSecAttrSynchronizable as String: false]
    #if os(iOS)
    query[kSecUseDataProtectionKeychain as String] = true
    #endif
    return query
  }
}

struct PiliAccountCredentialRecord: Sendable, Equatable, Codable {
  let identity: PiliAccountIdentity
  let accessKey: String?
  let refreshToken: String?

  func validated() throws -> Self {
    guard identity.ownerToken.utf8.count == 36, UUID(uuidString: identity.ownerToken) != nil,
          identity.generation > 0, (accessKey?.utf8.count ?? 0) <= 65536,
          (refreshToken?.utf8.count ?? 0) <= 65536 else { throw PiliAccountStorageError.invalidArchive }
    return self
  }
}

struct PiliAccountCookieRecord: Sendable, Equatable, Codable {
  let name: String
  let value: String
  /// Jar bucket keys are retained separately from optional Cookie attributes.
  let domain: String
  let path: String
  let hostOnly: Bool
  let cookieDomain: String?
  let cookiePath: String?
  let secure: Bool
  let httpOnly: Bool
  let sameSite: String?
  let expiresMicroseconds: Int64?
  let maxAgeSeconds: Int64?
  let createdSeconds: Int64
  let sequence: Int
}

struct PiliAccountCookieArchive: Sendable, Equatable, Codable {
  let schemaVersion: Int
  let identity: PiliAccountIdentity
  let ignoreExpires: Bool
  let legacyHiveAttributesIncomplete: Bool
  let cookies: [PiliAccountCookieRecord]

  func validated() throws -> Self {
    guard schemaVersion == 1 else { throw PiliAccountStorageError.unsupportedSchema }
    guard cookies.count <= 4096, identity.generation > 0, UUID(uuidString: identity.ownerToken) != nil,
          cookies.enumerated().allSatisfy({ index, cookie in
            !cookie.name.isEmpty && cookie.name.utf8.count <= 1024 && cookie.value.utf8.count <= 65536 &&
            !cookie.domain.isEmpty && cookie.domain.utf8.count <= 1024 && cookie.path.utf8.count <= 4096 &&
            cookie.sequence == index && cookie.createdSeconds >= 0 &&
            (cookie.sameSite == nil || ["Strict", "Lax", "None"].contains(cookie.sameSite!)) &&
            [cookie.name, cookie.value, cookie.domain, cookie.path].allSatisfy({
              !$0.contains("\r") && !$0.contains("\n") && !$0.contains("\u{0}")
            })
          }) else { throw PiliAccountStorageError.invalidArchive }
    // Dart map keys distinguish canonically equivalent Unicode code units.
    // Swift String hashing does not, so compare owned UTF-16 sequences here.
    let keys: [[[UInt16]]] = cookies.map {
      [[$0.hostOnly ? 1 : 0], Array($0.domain.utf16), Array($0.path.utf16), Array($0.name.utf16)]
    }
    guard Set(keys).count == keys.count else { throw PiliAccountStorageError.invalidArchive }
    return self
  }
}

/// Cookies contain credentials too, so the full archive is stored in the same secure vault.
struct PiliNativeCookieStore: Sendable {
  let secrets: any PiliAccountSecretStore

  func stage(_ archive: PiliAccountCookieArchive, key: String) async throws {
    let validated = try archive.validated()
    try await secrets.write(JSONEncoder().encode(validated), key: key)
  }

  func loadStaged(key: String) async throws -> PiliAccountCookieArchive? {
    guard let data = try await secrets.read(key) else { return nil }
    guard data.count <= 32 * 1024 * 1024 else { throw PiliAccountStorageError.invalidArchive }
    return try JSONDecoder().decode(PiliAccountCookieArchive.self, from: data).validated()
  }
}

struct PiliKeychainCredentialStore: Sendable {
  let secrets: any PiliAccountSecretStore
  func stage(_ credentials: PiliAccountCredentialRecord, key: String) async throws {
    let validated = try credentials.validated()
    try await secrets.write(JSONEncoder().encode(validated), key: key)
  }
  func loadStaged(key: String) async throws -> PiliAccountCredentialRecord? {
    guard let data = try await secrets.read(key) else { return nil }
    guard data.count <= 1024 * 1024 else { throw PiliAccountStorageError.invalidArchive }
    return try JSONDecoder().decode(PiliAccountCredentialRecord.self, from: data).validated()
  }
}
