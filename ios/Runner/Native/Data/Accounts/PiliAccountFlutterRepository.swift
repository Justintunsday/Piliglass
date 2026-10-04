import Foundation

@MainActor
final class PiliAccountFlutterRepository: PiliAccountRepository {
  private let invoker: any PiliBridgeMethodInvoking
  init(invoker: any PiliBridgeMethodInvoking) { self.invoker = invoker }

  func selectionSnapshot() async throws -> PiliAccountSelectionSnapshot {
    try Task.checkCancellation()
    let value = try await invoker.invoke("loadNativeAccountSelection", arguments: nil)
    try Task.checkCancellation()
    if case .dictionary(let fields) = value, fields["state"] == .string("error") {
      guard Set(fields.keys) == ["state", "code", "nativeWritesAllowed"],
            fields["nativeWritesAllowed"] == .bool(false), case .string(let code) = fields["code"], !code.isEmpty else {
        throw PiliAccountRepositoryError.invalidSnapshot
      }
      throw PiliAccountRepositoryError.serviceFailure(code)
    }
    return try PiliAccountSnapshotBridgeCodec.decode(value)
  }
}
