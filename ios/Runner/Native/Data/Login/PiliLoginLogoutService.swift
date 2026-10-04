import Foundation

struct PiliLoginLogoutTarget: Sendable { let owner: PiliLoginAccountOwner; let csrf: String }
struct PiliLoginLogoutReceipt: Sendable, Equatable {
  let removed: [PiliLoginAccountOwner]
  let retained: [PiliLoginAccountOwner]
}

struct PiliLoginLogoutService: Sendable {
  let repository: any PiliLoginRepository
  let authority: any PiliLoginAccountAuthority

  func logout(_ targets: [PiliLoginLogoutTarget], remote: Bool) async throws -> PiliLoginLogoutReceipt {
    guard Set(targets.map(\.owner)).count == targets.count else { throw PiliLoginError.invalidInput }
    try Task.checkCancellation()
    let successful: Set<PiliLoginAccountOwner>
    if remote {
      successful = await withTaskGroup(of: PiliLoginAccountOwner?.self) { group in
        for target in targets {
          group.addTask {
            do {
              let result = try await repository.perform(.logout(owner: target.owner, csrf: target.csrf))
              return result == .loggedOut ? target.owner : nil
            } catch { return nil }
          }
        }
        var values = Set<PiliLoginAccountOwner>()
        for await result in group { if let result { values.insert(result) } }
        return values
      }
    } else { successful = Set(targets.map(\.owner)) }
    let removed = targets.map(\.owner).filter { successful.contains($0) }
    // A remote failure leaves local credentials untouched, including batch logout.
    if !removed.isEmpty { try await authority.delete(removed) }
    return .init(removed: removed, retained: targets.map(\.owner).filter { !successful.contains($0) })
  }
}
