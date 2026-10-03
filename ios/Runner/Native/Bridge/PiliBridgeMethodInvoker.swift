import Foundation

@MainActor
protocol PiliBridgeMethodTransport: AnyObject, Sendable {
  func invoke(
    _ method: String,
    arguments: [String: PiliBridgeValue]?,
    completion: @escaping @Sendable (
      Result<PiliBridgeValue, PiliBridgeInvocationError>
    ) -> Void
  )
}

@MainActor
protocol PiliBridgeMethodInvoking: AnyObject, Sendable {
  func invoke(
    _ method: String,
    arguments: [String: PiliBridgeValue]?
  ) async throws -> PiliBridgeValue
}

@MainActor
final class PiliBridgeMethodInvoker: PiliBridgeMethodInvoking {
  private let transport: any PiliBridgeMethodTransport

  init(transport: any PiliBridgeMethodTransport) {
    self.transport = transport
  }

  func invoke(
    _ method: String,
    arguments: [String: PiliBridgeValue]?
  ) async throws -> PiliBridgeValue {
    try Task.checkCancellation()
    let box = PiliBridgeCompletionBox()
    let result = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard box.install(continuation) else { return }
        // onCancel's actor hop may still be queued when installation runs.
        guard !Task.isCancelled else {
          box.cancel()
          return
        }
        transport.invoke(method, arguments: arguments) { result in
          Task { @MainActor in
            box.complete(result)
          }
        }
      }
    } onCancel: {
      Task { @MainActor in
        box.cancel()
      }
    }
    // Cancellation can race with a callback that already resumed the waiter.
    try Task.checkCancellation()
    return try result.get()
  }
}

@MainActor
private final class PiliBridgeCompletionBox {
  typealias InvocationResult = Result<PiliBridgeValue, Error>
  private enum State {
    case ready
    case waiting(CheckedContinuation<InvocationResult, Never>)
    case finished(InvocationResult?)
  }
  private var state: State = .ready

  func install(_ continuation: CheckedContinuation<InvocationResult, Never>) -> Bool {
    switch state {
    case .ready:
      state = .waiting(continuation)
      return true
    case .finished(let result?):
      state = .finished(nil)
      continuation.resume(returning: result)
      return false
    case .waiting, .finished(nil):
      preconditionFailure("A bridge continuation can only be installed once")
    }
  }

  func complete(_ result: Result<PiliBridgeValue, PiliBridgeInvocationError>) {
    finish(result.mapError { $0 as Error })
  }

  func cancel() {
    // This ends the Swift wait; an already sent Dart request keeps running.
    finish(.failure(CancellationError()))
  }

  private func finish(_ result: InvocationResult) {
    switch state {
    case .ready:
      // Keep an early cancellation until the continuation is installed.
      state = .finished(result)
    case .waiting(let continuation):
      // Drop the continuation before resuming or accepting another callback.
      state = .finished(nil)
      continuation.resume(returning: result)
    case .finished:
      return
    }
  }
}
