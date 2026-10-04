import Foundation

enum PiliBridgeLeaseFinalizationError: Error, Sendable, Equatable {
  case timeout
}

/// One terminal dispatch. Contains no feature snapshot or account headers.
@MainActor
final class PiliBridgeLeaseFinalizer {
  let requestID: String
  private let transport: any PiliBridgeMethodTransport
  private let timeoutNanoseconds: UInt64
  private var claimed = false

  init(
    transport: any PiliBridgeMethodTransport,
    requestID: String,
    timeoutNanoseconds: UInt64
  ) {
    precondition(timeoutNanoseconds > 0)
    self.transport = transport
    self.requestID = requestID
    self.timeoutNanoseconds = timeoutNanoseconds
  }

  func start(
    _ method: String,
    arguments: [String: PiliBridgeValue]
  ) -> Task<PiliBridgeValue, Error>? {
    guard !claimed else { return nil }
    claimed = true
    let transport = self.transport
    let timeout = timeoutNanoseconds
    // An unstructured task starts with its own cancellation state. Do not
    // propagate the caller's cancellation into this terminal side effect.
    return Task { @MainActor in
      try await Self.awaitReply(transport, method: method, arguments: arguments, timeout: timeout)
    }
  }

  private static func awaitReply(
    _ transport: any PiliBridgeMethodTransport,
    method: String,
    arguments: [String: PiliBridgeValue],
    timeout: UInt64
  ) async throws -> PiliBridgeValue {
    try await withCheckedThrowingContinuation { continuation in
      let acknowledgement = PiliBridgeLeaseAcknowledgement(continuation)
      acknowledgement.armTimeout(timeout)
      transport.invoke(method, arguments: arguments, completion: resultHandler(acknowledgement))
    }
  }

  // This callback may run on any thread; only owned Sendable values cross over.
  nonisolated private static func resultHandler(
    _ acknowledgement: PiliBridgeLeaseAcknowledgement
  ) -> @Sendable (Result<PiliBridgeValue, PiliBridgeInvocationError>) -> Void {
    { result in
      Task { @MainActor in
        acknowledgement.complete(result.mapError { $0 as Error })
      }
    }
  }
}

@MainActor
private final class PiliBridgeLeaseAcknowledgement {
  private var continuation: CheckedContinuation<PiliBridgeValue, Error>?
  private var timeoutTask: Task<Void, Never>?

  init(_ continuation: CheckedContinuation<PiliBridgeValue, Error>) {
    self.continuation = continuation
  }

  func armTimeout(_ nanoseconds: UInt64) {
    // Hold the box until the deadline even if a transport drops its callback.
    // complete() breaks this bounded ownership before resuming the waiter.
    timeoutTask = Task { @MainActor in
      do { try await Task.sleep(nanoseconds: nanoseconds) }
      catch { return }
      complete(.failure(PiliBridgeLeaseFinalizationError.timeout))
    }
  }

  func complete(_ result: Result<PiliBridgeValue, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    let timeout = timeoutTask
    timeoutTask = nil
    timeout?.cancel()
    continuation.resume(with: result)
  }
}
