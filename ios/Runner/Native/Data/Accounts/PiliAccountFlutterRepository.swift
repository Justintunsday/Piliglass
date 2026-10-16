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

  /// Read-only fetch of the legacy Dart staging export (tracker identities plus
  /// credential/cookie payload). This is NOT the schema-3 envelope bridge: no
  /// durable identity is carried or verified here, and nothing may be imported
  /// or authorized before the Block3 freeze/drain composition exists.
  func stagingExport() async throws -> PiliAccountStagingExport {
    try Task.checkCancellation()
    let value = try await invoker.invoke("exportNativeAccountStaging", arguments: nil)
    try Task.checkCancellation()
    if case .dictionary(let fields) = value, fields["state"] == .string("error") {
      guard Set(fields.keys) == ["state", "code", "nativeWritesAllowed"],
            fields["nativeWritesAllowed"] == .bool(false), case .string(let code) = fields["code"], !code.isEmpty else {
        throw PiliAccountRepositoryError.invalidSnapshot
      }
      throw PiliAccountRepositoryError.serviceFailure(code)
    }
    return try PiliAccountStagingBridgeCodec.decode(value)
  }
}
