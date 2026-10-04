import Foundation

enum PiliAccountPurpose: String, CaseIterable, Sendable, Codable, Hashable {
  case main, heartbeat, recommend, video
}

/// MID is public profile data; only this identity identifies credential ownership.
struct PiliAccountIdentity: Sendable, Equatable, Hashable, Codable {
  let ownerToken: String
  let generation: Int64
}

struct PiliAccountDescriptor: Sendable, Equatable, Codable {
  let identity: PiliAccountIdentity
  let mid: Int64
  let isLogin: Bool
  let activated: Bool
  let hasAccessKey: Bool
  let hasRefreshToken: Bool
  let persistedPurposes: Set<PiliAccountPurpose>
}

struct PiliAccountSelection: Sendable, Equatable, Codable {
  let purpose: PiliAccountPurpose
  let identity: PiliAccountIdentity
  /// True when the effective slot differs from its persisted Hive assignment.
  let temporary: Bool
}

struct PiliAccountSelectionSnapshot: Sendable, Equatable, Codable {
  let authorityEpoch: String
  let revision: Int64
  let accounts: [PiliAccountDescriptor]
  let selections: [PiliAccountSelection]
  let history: PiliAccountIdentity
  var nativeWritesAllowed: Bool { false }

  func account(for purpose: PiliAccountPurpose) -> PiliAccountDescriptor? {
    guard let identity = selections.first(where: { $0.purpose == purpose })?.identity else { return nil }
    return accounts.first(where: { $0.identity == identity })
  }

  func validated() throws -> Self {
    guard authorityEpoch.utf8.count == 36, UUID(uuidString: authorityEpoch) != nil, revision >= 0,
          !accounts.isEmpty, accounts.count <= 256, selections.count == 4,
          Set(selections.map(\.purpose)) == Set(PiliAccountPurpose.allCases),
          Set(accounts.map(\.identity)).count == accounts.count,
          Set(accounts.map { $0.identity.ownerToken }).count == accounts.count,
          accounts.filter({ !$0.isLogin }).count == 1 else { throw PiliAccountRepositoryError.invalidSnapshot }
    var mids = Set<Int64>()
    for account in accounts {
      guard account.identity.ownerToken.utf8.count == 36, UUID(uuidString: account.identity.ownerToken) != nil,
            account.identity.generation > 0,
            account.mid >= 0, account.isLogin == (account.mid > 0),
            mids.insert(account.mid).inserted,
            account.isLogin || (!account.hasAccessKey && !account.hasRefreshToken && account.persistedPurposes.isEmpty) else {
        throw PiliAccountRepositoryError.invalidSnapshot
      }
    }
    for selection in selections {
      guard accounts.contains(where: { $0.identity == selection.identity }) else {
        throw PiliAccountRepositoryError.invalidSnapshot
      }
    }
    guard let heartbeat = account(for: .heartbeat), let main = account(for: .main),
          history == (heartbeat.isLogin ? heartbeat.identity : main.identity) else {
      throw PiliAccountRepositoryError.invalidSnapshot
    }
    return self
  }
}

protocol PiliAccountRepository: Sendable {
  func selectionSnapshot() async throws -> PiliAccountSelectionSnapshot
}

enum PiliAccountRepositoryError: Error, Sendable, Equatable {
  case unavailable, invalidSnapshot, staleSnapshot, epochMismatch
  case serviceFailure(String)
}

/// The composition owns epoch transitions. An out-of-order callback cannot reset this actor.
actor PiliAccountSession {
  private var authorityEpoch: String
  private var snapshot: PiliAccountSelectionSnapshot?

  init(authorityEpoch: String) { self.authorityEpoch = authorityEpoch }

  func install(_ candidate: PiliAccountSelectionSnapshot) throws {
    let validated = try candidate.validated()
    guard validated.authorityEpoch == authorityEpoch else { throw PiliAccountRepositoryError.epochMismatch }
    if let snapshot {
      guard validated.revision >= snapshot.revision else { throw PiliAccountRepositoryError.staleSnapshot }
      guard validated.revision != snapshot.revision || validated == snapshot else {
        throw PiliAccountRepositoryError.invalidSnapshot
      }
    }
    snapshot = validated
  }

  func current() -> PiliAccountSelectionSnapshot? { snapshot }

  func resetAuthority(to epoch: String) throws {
    guard epoch.utf8.count == 36, UUID(uuidString: epoch) != nil else { throw PiliAccountRepositoryError.invalidSnapshot }
    authorityEpoch = epoch
    snapshot = nil
  }
}
