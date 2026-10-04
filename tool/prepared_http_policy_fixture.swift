import Foundation

// Synthetic value shapes only. The full Runner job also consumes policy
// contexts exported by the actual Dart bridge and installed Request adapters.
enum PreparedHTTPPolicyFixture {
  static let unknown: PiliBridgeValue = .dictionary([
    "version": .integer(1), "poolGeneration": .integer(0), "clientMode": .string("main"),
    "pool": .null, "retry": .null, "connectTimeoutMicroseconds": .null,
    "receiveIdleTimeoutMicroseconds": .null, "sendTimeoutMicroseconds": .null,
    "transformTimeoutMicroseconds": .null, "receiveDataWhenStatusError": .bool(true),
    "persistentConnection": .bool(true), "followRedirects": .bool(false), "maxRedirects": .integer(5),
    "acceptEncoding": .null, "responseType": .string("json"), "decoder": .string("unknown"),
    "issues": .array([.string("poolNotInstalled"), .string("retryNotDescribed"), .string("decoderChanged")])
  ])
}
