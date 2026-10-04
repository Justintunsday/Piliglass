import Foundation

struct PiliNativeLoginRepository: PiliLoginRepository {
  let transport: any PiliLoginHTTPExecuting
  let environment: @Sendable () async throws -> PiliLoginEnvironment

  func perform(_ operation: PiliLoginOperation) async throws -> PiliLoginResult {
    try Task.checkCancellation()
    let request = try PiliLoginRequestBuilder.build(operation, environment: await environment())
    let body = try await transport.execute(request)
    try Task.checkCancellation()
    return try PiliLoginResponseDecoder.decode(body, operation: operation)
  }
}
