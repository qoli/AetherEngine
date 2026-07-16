import Foundation

/// One-consumer, one-buffer demand rendezvous. The producer must call `waitForDemand()` before it reads or
/// decodes the next unit; `yield(_:)` then resumes exactly that waiting `next()` call. There is no hidden
/// buffer and therefore no sample drop / catch-up path.
actor AudioAnalysisDemandGate {
    private enum State {
        case active
        case finished
        case failed(AudioAnalysisError)
    }

    private var state: State = .active
    /// Bound on the first `next()` call. `AsyncSequence` permits callers to manufacture multiple
    /// iterators, but analysis has one cursor and therefore cannot serve a second consumer without
    /// either duplicating PCM or stealing buffers from the first.
    private var boundConsumerID: UUID?
    private var consumerWaiter: CheckedContinuation<AudioAnalysisBuffer?, Error>?
    private var producerWaiter: CheckedContinuation<Void, Error>?

    func waitForDemand() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await self.waitForDemandUncancelled()
        }, onCancel: {
            Task { await self.cancel() }
        })
    }

    private func waitForDemandUncancelled() async throws {
        try assertActive()
        if consumerWaiter != nil { return }
        try await withCheckedThrowingContinuation { continuation in
            producerWaiter = continuation
        }
        try assertActive()
    }

    func next(consumerID: UUID) async throws -> AudioAnalysisBuffer? {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await self.nextUncancelled(consumerID: consumerID)
        }, onCancel: {
            Task { await self.cancel() }
        })
    }

    private func nextUncancelled(consumerID: UUID) async throws -> AudioAnalysisBuffer? {
        switch state {
        case .finished: return nil
        case .failed(let error): throw error
        case .active: break
        }
        if let boundConsumerID, boundConsumerID != consumerID {
            throw AudioAnalysisError.concurrentConsumer
        }
        boundConsumerID = consumerID
        guard consumerWaiter == nil else { throw AudioAnalysisError.concurrentConsumer }
        if let producerWaiter {
            self.producerWaiter = nil
            producerWaiter.resume()
        }
        return try await withCheckedThrowingContinuation { continuation in
            consumerWaiter = continuation
        }
    }

    /// Delivers only to a consumer that previously expressed demand. Returning false means the stream was
    /// terminated while the producer was decoding and no further read/decode work may occur.
    func yield(_ buffer: AudioAnalysisBuffer) -> Bool {
        guard case .active = state, let consumerWaiter else { return false }
        self.consumerWaiter = nil
        consumerWaiter.resume(returning: buffer)
        return true
    }

    func finish() {
        guard case .active = state else { return }
        state = .finished
        if let consumerWaiter {
            self.consumerWaiter = nil
            consumerWaiter.resume(returning: nil)
        }
        if let producerWaiter {
            self.producerWaiter = nil
            producerWaiter.resume(throwing: AudioAnalysisError.cancelled)
        }
    }

    func fail(_ error: AudioAnalysisError) {
        guard case .active = state else { return }
        state = .failed(error)
        if let consumerWaiter {
            self.consumerWaiter = nil
            consumerWaiter.resume(throwing: error)
        }
        if let producerWaiter {
            self.producerWaiter = nil
            producerWaiter.resume(throwing: error)
        }
    }

    func cancel() { fail(.cancelled) }

    private func assertActive() throws {
        switch state {
        case .active: return
        case .finished: throw AudioAnalysisError.cancelled
        case .failed(let error): throw error
        }
    }
}

/// Public custom `AsyncSequence` used instead of `AsyncThrowingStream`: its iterator calls into the demand
/// rendezvous before each producer read/decode, making back-pressure part of the media correctness contract.
public final class AudioAnalysisStream: AsyncSequence, @unchecked Sendable {
    public typealias Element = AudioAnalysisBuffer

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let gate: AudioAnalysisDemandGate
        private let cancel: @Sendable () -> Void
        private let consumerID: UUID

        fileprivate init(gate: AudioAnalysisDemandGate, cancel: @escaping @Sendable () -> Void,
                         consumerID: UUID) {
            self.gate = gate
            self.cancel = cancel
            self.consumerID = consumerID
        }

        public mutating func next() async throws -> AudioAnalysisBuffer? {
            do {
                return try await gate.next(consumerID: consumerID)
            } catch is CancellationError {
                cancel()
                throw AudioAnalysisError.cancelled
            } catch {
                if Task.isCancelled { cancel() }
                throw error
            }
        }
    }

    private let gate: AudioAnalysisDemandGate
    private let cancelImpl: @Sendable () -> Void

    init(gate: AudioAnalysisDemandGate, cancel: @escaping @Sendable () -> Void) {
        self.gate = gate
        self.cancelImpl = cancel
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(gate: gate, cancel: cancelImpl, consumerID: UUID())
    }

    /// Explicit cancellation is required when the caller abandons the stream without cancelling its task.
    public func cancel() { cancelImpl() }
}
