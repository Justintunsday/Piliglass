import Flutter
import Foundation

@MainActor
final class PiliFlutterMethodTransport: PiliBridgeMethodTransport {
  private let channel: FlutterMethodChannel

  init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  func invoke(
    _ method: String,
    arguments: [String: PiliBridgeValue]?,
    completion: @escaping @Sendable (
      Result<PiliBridgeValue, PiliBridgeInvocationError>
    ) -> Void
  ) {
    let codecArguments = arguments?.mapValues { $0.codecValue }
    channel.invokeMethod(
      method,
      arguments: codecArguments,
      result: Self.makeResultHandler(completion: completion)
    )
  }

  // Create the callback outside MainActor so its closure does not inherit the
  // invocation's actor isolation through Flutter's legacy block signature.
  nonisolated private static func makeResultHandler(
    completion: @escaping @Sendable (
      Result<PiliBridgeValue, PiliBridgeInvocationError>
    ) -> Void
  ) -> FlutterResult {
    { response in
      // Copy Any before invoking the Sendable completion; the invoker does
      // not require this callback to execute on a particular executor.
      completion(Self.snapshotResponse(response))
    }
  }

  nonisolated private static func snapshotResponse(
    _ response: Any?
  ) -> Result<PiliBridgeValue, PiliBridgeInvocationError> {
    if (response as AnyObject?) === FlutterMethodNotImplemented {
      return .failure(.unavailable)
    }
    if let error = response as? FlutterError {
      return .failure(.platform(code: error.code, message: error.message))
    }
    do {
      return .success(try PiliBridgeValue(codecValue: response))
    } catch {
      return .failure(.invalidValue)
    }
  }
}
