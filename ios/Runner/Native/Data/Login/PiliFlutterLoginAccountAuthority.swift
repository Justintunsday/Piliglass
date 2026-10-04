import Foundation

struct PiliFlutterLoginAccountAuthority: PiliLoginAccountAuthority {
  let bridge: any PiliBridgeMethodInvoking

  func install(_ credentials: PiliLoginCredentials, method: PiliLoginMethod,
               selection: PiliLoginInstallSelection) async throws -> PiliLoginInstallReceipt {
    let purposes: PiliBridgeValue
    switch selection {
    case .preserveExisting: purposes = .null
    case .assign(let values): purposes = .array(values.map(\.rawValue).sorted().map(PiliBridgeValue.string))
    }
    let value = try await bridge.invoke("installNativeLoginCredentials", arguments: [
      "operationID": .string(UUID().uuidString), "method": .string(method.rawValue), "purposes": purposes,
      "credentials": .dictionary([
        "mid": .integer(credentials.mid), "accessToken": credentials.accessToken.map(PiliBridgeValue.string) ?? .null,
        "refreshToken": credentials.refreshToken.map(PiliBridgeValue.string) ?? .null,
        "cookies": .array(credentials.cookies.map { cookie in .dictionary([
          "name": .string(cookie.name), "value": .string(cookie.value), "domain": .string(cookie.domain),
          "path": .string(cookie.path), "expiresEpochSeconds": cookie.expiresEpochSeconds.map(PiliBridgeValue.integer) ?? .null,
          "secure": .bool(cookie.secure), "httpOnly": .bool(cookie.httpOnly)
        ]) })
      ])
    ])
    guard case .dictionary(let receipt) = value, receipt["state"] == .string("installed"),
          receipt["nativeAuthorityEnabled"] == .bool(false),
          case .bool(let needsSelection)? = receipt["needsPurposeSelection"],
          case .dictionary(let owner)? = receipt["owner"] else { throw PiliLoginError.invalidResponse }
    return .init(owner: try Self.owner(owner), needsPurposeSelection: needsSelection)
  }

  func delete(_ owners: [PiliLoginAccountOwner]) async throws {
    let value = try await bridge.invoke("deleteNativeLoginAccounts", arguments: [
      "operationID": .string(UUID().uuidString), "owners": .array(owners.map { owner in .dictionary([
        "authorityEpoch": .string(owner.authorityEpoch), "ownerToken": .string(owner.identity.ownerToken),
        "generation": .integer(owner.identity.generation)
      ]) })
    ])
    guard case .dictionary(let receipt) = value, receipt["state"] == .string("deleted"),
          receipt["count"] == .integer(Int64(owners.count)), receipt["nativeAuthorityEnabled"] == .bool(false) else {
      throw PiliLoginError.invalidResponse
    }
  }

  private static func owner(_ value: [String: PiliBridgeValue]) throws -> PiliLoginAccountOwner {
    guard case .string(let epoch)? = value["authorityEpoch"], UUID(uuidString: epoch) != nil,
          case .string(let token)? = value["ownerToken"], UUID(uuidString: token) != nil,
          case .integer(let generation)? = value["generation"], generation > 0 else { throw PiliLoginError.invalidResponse }
    return .init(authorityEpoch: epoch, identity: .init(ownerToken: token, generation: generation))
  }
}
