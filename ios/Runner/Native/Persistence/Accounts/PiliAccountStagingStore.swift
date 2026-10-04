import Foundation

/// One atomic vault pointer publishes a complete shadow import. Neither this
/// actor nor its vault can switch the live Dart/Hive account authority. The
/// composition owns exactly one staging actor per vault namespace.
actor PiliAccountStagingStore {
  private struct Manifest: Sendable, Codable {
    let schemaVersion: Int
    let transactionID: String
    let snapshot: PiliAccountSelectionSnapshot
    let count: Int
  }

  private let secrets: any PiliAccountSecretStore
  private let manifestKey = "staging-manifest-v1"
  private var operationInProgress = false
  var nativeWritesAllowed: Bool { false }

  init(secrets: any PiliAccountSecretStore) { self.secrets = secrets }

  func importShadow(_ input: PiliAccountStagingExport) async throws {
    try beginOperation()
    defer { operationInProgress = false }
    _ = try input.snapshot.validated()
    guard input.entries.count == input.snapshot.accounts.count,
          Set(input.entries.map { $0.credentials.identity }) == Set(input.snapshot.accounts.map(\.identity)),
          input.entries.allSatisfy({ $0.credentials.identity == $0.cookies.identity }) else {
      throw PiliAccountStorageError.invalidArchive
    }
    // Fully validate every entry before the first persistent mutation.
    for entry in input.entries {
      _ = try entry.cookies.validated()
      _ = try entry.credentials.validated()
    }
    let previous = try await manifest()
    if let previous, previous.snapshot.authorityEpoch == input.snapshot.authorityEpoch {
      guard input.snapshot.revision >= previous.snapshot.revision else { throw PiliAccountRepositoryError.staleSnapshot }
      guard input.snapshot.revision != previous.snapshot.revision || input.snapshot == previous.snapshot else {
        throw PiliAccountStorageError.invalidArchive
      }
    }
    let id = UUID().uuidString.lowercased()
    var written: [String] = []
    let cookies = PiliNativeCookieStore(secrets: secrets)
    let credentials = PiliKeychainCredentialStore(secrets: secrets)
    do {
      for (index, entry) in input.entries.enumerated() {
        try Task.checkCancellation()
        let credentialKey = key(id, index, "credentials")
        written.append(credentialKey)
        try await credentials.stage(entry.credentials, key: credentialKey)
        let cookieKey = key(id, index, "cookies")
        written.append(cookieKey)
        try await cookies.stage(entry.cookies, key: cookieKey)
      }
      try Task.checkCancellation()
      let next = Manifest(schemaVersion: 1, transactionID: id, snapshot: input.snapshot, count: input.entries.count)
      try await secrets.write(JSONEncoder().encode(next), key: manifestKey)
    } catch {
      for key in written { try? await secrets.remove(key) }
      throw error
    }
    if let previous {
      for index in 0..<previous.count {
        try? await secrets.remove(key(previous.transactionID, index, "credentials"))
        try? await secrets.remove(key(previous.transactionID, index, "cookies"))
      }
    }
  }

  func loadShadow() async throws -> PiliAccountStagingExport? {
    try beginOperation()
    defer { operationInProgress = false }
    guard let manifest = try await manifest() else { return nil }
    var entries: [PiliAccountStagingEntry] = []
    for index in 0..<manifest.count {
      guard let credentials = try await PiliKeychainCredentialStore(secrets: secrets)
        .loadStaged(key: key(manifest.transactionID, index, "credentials")),
        let cookies = try await PiliNativeCookieStore(secrets: secrets)
        .loadStaged(key: key(manifest.transactionID, index, "cookies")),
        credentials.identity == cookies.identity else { throw PiliAccountStorageError.invalidArchive }
      entries.append(PiliAccountStagingEntry(credentials: credentials, cookies: cookies))
    }
    guard Set(entries.map { $0.credentials.identity }) == Set(manifest.snapshot.accounts.map(\.identity)) else {
      throw PiliAccountStorageError.invalidArchive
    }
    return PiliAccountStagingExport(snapshot: manifest.snapshot, entries: entries)
  }

  func discardShadow() async throws {
    try beginOperation()
    defer { operationInProgress = false }
    guard let manifest = try await manifest() else { return }
    // Removing the pointer first makes an interrupted cleanup unavailable.
    try await secrets.remove(manifestKey)
    for index in 0..<manifest.count {
      try await secrets.remove(key(manifest.transactionID, index, "credentials"))
      try await secrets.remove(key(manifest.transactionID, index, "cookies"))
    }
  }

  private func manifest() async throws -> Manifest? {
    guard let data = try await secrets.read(manifestKey) else { return nil }
    guard data.count <= 1024 * 1024 else { throw PiliAccountStorageError.invalidArchive }
    let manifest = try JSONDecoder().decode(Manifest.self, from: data)
    guard manifest.schemaVersion == 1 else { throw PiliAccountStorageError.unsupportedSchema }
    guard UUID(uuidString: manifest.transactionID) != nil, (1...256).contains(manifest.count),
          manifest.count == manifest.snapshot.accounts.count else { throw PiliAccountStorageError.invalidArchive }
    _ = try manifest.snapshot.validated()
    return manifest
  }

  private func key(_ transaction: String, _ index: Int, _ component: String) -> String {
    "staging.\(transaction).\(index).\(component)"
  }

  private func beginOperation() throws {
    guard !operationInProgress else { throw PiliAccountStorageError.operationInProgress }
    operationInProgress = true
  }
}
