import Foundation

/// Exact request value pinned across every progressive preflight attempt.
///
/// Retry policy never accepts a replacement URL, header set, liveness mode or
/// probe budget. The value is internal so hosts cannot steer recovery.
struct AetherProgressivePreflightRequest: Sendable, Equatable {
    let url: URL
    let options: LoadOptions
}

/// Unbounded same-source retry schedule for a progressive URL that stops
/// advancing bytes. Values clamp to their final entry; there is deliberately
/// no total elapsed-time ceiling or maximum attempt count.
struct AetherProgressivePreflightRetryPolicy: Sendable, Equatable {
    let inactivitySeconds: [TimeInterval]
    let backoffSeconds: [TimeInterval]
    let cancellationResponseSeconds: TimeInterval

    init(
        inactivitySeconds: [TimeInterval],
        backoffSeconds: [TimeInterval],
        cancellationResponseSeconds: TimeInterval = 2
    ) {
        precondition(
            !inactivitySeconds.isEmpty
                && inactivitySeconds.allSatisfy {
                    $0.isFinite && $0 > 0
                }
        )
        precondition(
            !backoffSeconds.isEmpty
                && backoffSeconds.allSatisfy {
                    $0.isFinite && $0 >= 0
                }
        )
        precondition(
            cancellationResponseSeconds.isFinite
                && cancellationResponseSeconds > 0
        )
        self.inactivitySeconds = inactivitySeconds
        self.backoffSeconds = backoffSeconds
        self.cancellationResponseSeconds =
            cancellationResponseSeconds
    }

    func inactivityTimeout(attempt: Int) -> TimeInterval {
        inactivitySeconds[
            min(max(0, attempt - 1), inactivitySeconds.count - 1)
        ]
    }

    func backoff(afterAttempt attempt: Int) -> TimeInterval {
        backoffSeconds[
            min(max(0, attempt - 1), backoffSeconds.count - 1)
        ]
    }

    static let production = AetherProgressivePreflightRetryPolicy(
        inactivitySeconds: [35, 60, 120, 300],
        backoffSeconds: [1, 2, 4, 8, 15, 30],
        cancellationResponseSeconds: 2
    )
}

enum AetherProgressivePreflightState:
    String,
    Sendable,
    Equatable
{
    case idle
    case probing
    case backingOff
    case prepared
    case cancelled
    case failed
}

/// Durable privacy-safe liveness snapshot shared by preflight and the exact
/// retained first-generation demuxer. `lastProgressUptime` advances only when
/// either origin bytes or validated session-store bytes advance.
struct AetherProgressivePreflightLivenessSnapshot:
    Sendable,
    Equatable
{
    let state: AetherProgressivePreflightState
    let attempt: Int?
    let originBytesFetched: Int64
    let sourceStoreBytesReused: Int64
    let lastProgressUptime: TimeInterval?

    var totalAdvancedBytes: Int64 {
        originBytesFetched &+ sourceStoreBytesReused
    }
}

/// Thread-safe liveness handle returned with the prepared source.
///
/// The successful Demuxer retains the progress relay, so snapshots continue to
/// advance after preflight returns and after Hybrid consumes that exact
/// Demuxer. Closing/discarding the Demuxer naturally ends further callbacks.
final class AetherProgressivePreflightLiveness:
    @unchecked Sendable
{
    private struct State {
        var lifecycle: AetherProgressivePreflightState = .idle
        var attempt: Int?
        var totalOriginBytes: Int64 = 0
        var totalStoreBytes: Int64 = 0
        var lastProgressUptime: TimeInterval?
    }

    private let lock = NSLock()
    private var state = State()

    var snapshot: AetherProgressivePreflightLivenessSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotLocked()
    }

    fileprivate func beginAttempt(_ attempt: Int) {
        lock.lock()
        state.lifecycle = .probing
        state.attempt = attempt
        lock.unlock()
    }

    @discardableResult
    fileprivate func record(
        attempt: Int,
        progress: AetherFetchedByteProgress
    ) -> AetherProgressivePreflightLivenessSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard state.attempt == attempt,
              state.lifecycle == .probing
                || state.lifecycle == .prepared else {
            return nil
        }
        let nextOrigin = max(
            state.totalOriginBytes,
            progress.originBytesFetched
        )
        let nextStore = max(
            state.totalStoreBytes,
            progress.sourceStoreBytesReused
        )
        let originDelta = nextOrigin - state.totalOriginBytes
        let storeDelta = nextStore - state.totalStoreBytes
        guard originDelta > 0 || storeDelta > 0 else {
            return nil
        }
        state.totalOriginBytes = nextOrigin
        state.totalStoreBytes = nextStore
        state.lastProgressUptime =
            ProcessInfo.processInfo.systemUptime
        return snapshotLocked()
    }

    @discardableResult
    fileprivate func recordProbeMilestone(
        attempt: Int
    ) -> AetherProgressivePreflightLivenessSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard state.attempt == attempt,
              state.lifecycle == .probing
                || state.lifecycle == .prepared else {
            return nil
        }
        state.lastProgressUptime =
            ProcessInfo.processInfo.systemUptime
        return snapshotLocked()
    }

    fileprivate func markBackingOff(attempt: Int) {
        lock.lock()
        if state.attempt == attempt {
            state.lifecycle = .backingOff
            state.attempt = nil
        }
        lock.unlock()
    }

    fileprivate func markPrepared(attempt: Int) {
        lock.lock()
        if state.attempt == attempt {
            state.lifecycle = .prepared
        }
        lock.unlock()
    }

    fileprivate func markCancelled() {
        lock.lock()
        state.lifecycle = .cancelled
        state.attempt = nil
        lock.unlock()
    }

    fileprivate func markFailed() {
        lock.lock()
        state.lifecycle = .failed
        state.attempt = nil
        lock.unlock()
    }

    private func snapshotLocked()
        -> AetherProgressivePreflightLivenessSnapshot
    {
        AetherProgressivePreflightLivenessSnapshot(
            state: state.lifecycle,
            attempt: state.attempt,
            originBytesFetched: state.totalOriginBytes,
            sourceStoreBytesReused: state.totalStoreBytes,
            lastProgressUptime: state.lastProgressUptime
        )
    }
}

enum AetherProgressivePreflightRetryReason:
    String,
    Sendable,
    Equatable
{
    case inactivity
    case zeroProgressFailure
    case transientFailure
}

enum AetherProgressivePreflightFailureDisposition:
    Sendable,
    Equatable
{
    case retry
    case permanent
    case cancelled
}

/// Fail-open classifier for launch retries: only explicit identity,
/// capability, security or malformed-media evidence is terminal. Unknown
/// errors remain retryable because they may be transport-shaped.
enum AetherProgressivePreflightFailureClassifier {
    static func classify(
        _ error: Error,
        hasCompleteValidatedSourceEvidence:
            Bool = false
    ) -> AetherProgressivePreflightFailureDisposition {
        if error is CancellationError {
            return .cancelled
        }
        if let demux = error as? DemuxerError {
            switch demux.ffmpegCode {
            case FFmpegErr.invalidData:
                // INVALIDDATA can be emitted for a truncated weak-network
                // response. It is malformed-media evidence only after the
                // exact validator-bound source is complete.
                return hasCompleteValidatedSourceEvidence
                    ? .permanent
                    : .retry
            default:
                // Open-time EOF may be a truncated weak-network response.
                // Without complete-file evidence it is not proof that the
                // canonical media itself is malformed.
                return .retry
            }
        }
        if let avio = error as? AVIOReaderError {
            switch avio {
            case .allocationFailed:
                return .permanent
            case .noResponse, .requestTimeout,
                 .sourceByteStoreValidationFailed:
                // Conditional store validation currently redacts its typed
                // transport cause into a reason string. It therefore cannot
                // prove a permanent source mismatch.
                return .retry
            case .httpStatus(let statusCode):
                return statusCode == 401
                        || statusCode == 403
                        || statusCode == 404
                        || statusCode == 410
                    ? .permanent
                    : .retry
            case .sourceByteStore(let store):
                return classify(store)
            }
        }
        if let store = error as? SourceByteStoreError {
            return classify(store)
        }
        if error is AetherPreparedURLSourceError {
            return .permanent
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .badURL, .unsupportedURL,
                 .appTransportSecurityRequiresSecureConnection,
                 .serverCertificateHasBadDate,
                 .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid,
                 .clientCertificateRejected,
                 .clientCertificateRequired:
                return .permanent
            case .cancelled:
                return .cancelled
            default:
                return .retry
            }
        }
        return .retry
    }

    private static func classify(
        _ error: SourceByteStoreError
    ) -> AetherProgressivePreflightFailureDisposition {
        switch error {
        case .cancelled:
            return .cancelled
        case .rangeFetchFailed, .rangeFetchRateLimited:
            return .retry
        case .invalidCapacity, .invalidGeneration,
             .generationMismatch, .unsupportedContentEncoding,
             .invalidRange, .closed, .directoryCreationFailed,
             .blockOpenFailed, .blockReadFailed,
             .blockWriteFailed:
            return .permanent
        }
    }
}

/// Privacy-safe lifecycle telemetry. It intentionally carries no URL, offset,
/// headers, error text or credential-bearing description.
enum AetherProgressivePreflightEvent: Sendable, Equatable {
    case attemptStarted(
        attempt: Int,
        inactivitySeconds: TimeInterval
    )
    case byteProgress(
        attempt: Int,
        snapshot: AetherProgressivePreflightLivenessSnapshot
    )
    case probeMilestone(
        attempt: Int,
        ordinal: UInt64,
        snapshot: AetherProgressivePreflightLivenessSnapshot
    )
    case cancellationRequested(attempt: Int?)
    case cancellationUnresponsive(
        attempt: Int,
        waitedSeconds: TimeInterval
    )
    case ioStopped(attempt: Int)
    case lateResultDiscarded(attempt: Int)
    case retryScheduled(
        afterAttempt: Int,
        nextAttempt: Int,
        backoffSeconds: TimeInterval,
        reason: AetherProgressivePreflightRetryReason
    )
    case prepared(
        attempt: Int,
        snapshot: AetherProgressivePreflightLivenessSnapshot
    )
    case cancelled
    case permanentFailure(
        attempt: Int,
        snapshot: AetherProgressivePreflightLivenessSnapshot
    )
}

enum AetherProgressivePreflightError:
    Error,
    Sendable,
    Equatable
{
    case alreadyStarted
}

protocol AetherProgressivePreflightAttempt:
    AnyObject,
    Sendable
{
    func run() throws -> AetherPreparedURLSource
    func requestCancellation()
}

typealias AetherProgressivePreflightAttemptFactory =
    @Sendable (
        AetherProgressivePreflightRequest,
        SourceByteStore?,
        AetherFetchedByteProgressLedger,
        AetherProgressivePreflightLiveness,
        @escaping @Sendable (AetherFetchedByteProgress) -> Void,
        @escaping @Sendable () -> Void
    ) -> any AetherProgressivePreflightAttempt

struct AetherProgressivePreflightDependencies: Sendable {
    let makeAttempt: AetherProgressivePreflightAttemptFactory
    let sleep: @Sendable (TimeInterval) async throws -> Void

    static let production = AetherProgressivePreflightDependencies(
        makeAttempt: {
            request,
            sourceByteStore,
            fetchedByteProgressLedger,
            liveness,
            onProgress,
            onProbeMilestone in
            AetherProgressiveURLPreflightAttempt(
                request: request,
                sourceByteStore: sourceByteStore,
                fetchedByteProgressLedger:
                    fetchedByteProgressLedger,
                liveness: liveness,
                onProgress: onProgress,
                onProbeMilestone:
                    onProbeMilestone
            )
        },
        sleep: { seconds in
            try await Task.sleep(
                nanoseconds:
                    UInt64(seconds * 1_000_000_000)
            )
        }
    )
}

private final class AetherProgressiveURLPreflightAttempt:
    AetherProgressivePreflightAttempt,
    @unchecked Sendable
{
    private let request: AetherProgressivePreflightRequest
    private let sourceByteStore: SourceByteStore?
    private let liveness:
        AetherProgressivePreflightLiveness
    private let fetchedByteProgressLedger:
        AetherFetchedByteProgressLedger
    private let onProgress:
        @Sendable (AetherFetchedByteProgress) -> Void
    private let onProbeMilestone:
        @Sendable () -> Void
    private let demuxer = Demuxer()
    private let cancellationLock = NSLock()
    private var cancellationRequested = false

    init(
        request: AetherProgressivePreflightRequest,
        sourceByteStore: SourceByteStore?,
        fetchedByteProgressLedger:
            AetherFetchedByteProgressLedger,
        liveness: AetherProgressivePreflightLiveness,
        onProgress:
            @escaping @Sendable (AetherFetchedByteProgress) -> Void,
        onProbeMilestone:
            @escaping @Sendable () -> Void
    ) {
        self.request = request
        self.sourceByteStore = sourceByteStore
        self.liveness = liveness
        self.fetchedByteProgressLedger =
            fetchedByteProgressLedger
        self.onProgress = onProgress
        self.onProbeMilestone =
            onProbeMilestone
        demuxer.fetchedByteProgressLedger =
            fetchedByteProgressLedger
        demuxer.onFetchedByteProgress = onProgress
        demuxer.onProbeMilestone =
            onProbeMilestone
        demuxer.openCancellationRequested = {
            [weak self] in
            self?.isCancellationRequested ?? true
        }
    }

    func run() throws -> AetherPreparedURLSource {
        do {
            try Task.checkCancellation()
            guard !isCancellationRequested else {
                throw CancellationError()
            }
            let prepared = try AetherEngine.prepareURLSource(
                url: request.url,
                options: request.options,
                demuxer: demuxer,
                sourceByteStore: sourceByteStore,
                progressiveLiveness: liveness,
                fetchedByteProgressLedger:
                    fetchedByteProgressLedger,
                onFetchedByteProgress: onProgress,
                onProbeMilestone:
                    onProbeMilestone
            )
            guard !isCancellationRequested,
                  !Task.isCancelled else {
                prepared
                    .discardAndWaitForIOQuiescence()
                throw CancellationError()
            }
            demuxer.openCancellationRequested = nil
            return prepared
        } catch {
            // `close()` makes cancellation requests, while this barrier proves
            // every attempt-owned URLSession task delivered its terminal
            // callback before the worker can retire.
            demuxer.waitForIOQuiescence()
            throw error
        }
    }

    func requestCancellation() {
        cancellationLock.lock()
        cancellationRequested = true
        cancellationLock.unlock()
        demuxer.markClosed()
    }

    private var isCancellationRequested: Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return cancellationRequested
    }
}

private final class AetherProgressivePreflightControl:
    @unchecked Sendable
{
    private struct ActiveAttempt {
        let number: Int
        let value: any AetherProgressivePreflightAttempt
        let notifyOwnerCancellation: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var isCancelled = false
    private var activeAttempt: ActiveAttempt?
    private var backoffTask: Task<Void, Error>?

    func install(
        attempt: any AetherProgressivePreflightAttempt,
        number: Int,
        notifyOwnerCancellation:
            @escaping @Sendable () -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled, activeAttempt == nil else {
            return false
        }
        activeAttempt = ActiveAttempt(
            number: number,
            value: attempt,
            notifyOwnerCancellation:
                notifyOwnerCancellation
        )
        return true
    }

    func requestCancellation() -> (
        isFirst: Bool,
        attempt: Int?
    ) {
        lock.lock()
        let isFirst = !isCancelled
        isCancelled = true
        let active = activeAttempt
        let backoff = backoffTask
        lock.unlock()
        active?.value.requestCancellation()
        active?.notifyOwnerCancellation()
        backoff?.cancel()
        return (isFirst, active?.number)
    }

    func cancelAttemptForRetry(number: Int) {
        lock.lock()
        let active = activeAttempt?.number == number
            ? activeAttempt?.value
            : nil
        lock.unlock()
        active?.requestCancellation()
    }

    func retireAttempt(number: Int) {
        lock.lock()
        if activeAttempt?.number == number {
            activeAttempt = nil
        }
        lock.unlock()
    }

    /// Linearization point between cancellation ownership and prepared-source
    /// transfer. Cancellation that wins this lock still owns `markClosed`;
    /// preparation that wins atomically retires the attempt for its caller.
    func commitPreparedAttempt(number: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled,
              activeAttempt?.number == number else {
            return false
        }
        activeAttempt = nil
        return true
    }

    func installBackoff(_ task: Task<Void, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return false }
        backoffTask = task
        return true
    }

    func retireBackoff() {
        lock.lock()
        backoffTask = nil
        lock.unlock()
    }

    var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }
}

private struct AetherProgressivePreflightWorkerResult:
    @unchecked Sendable
{
    let result: Result<AetherPreparedURLSource, Error>
}

private enum AetherProgressivePreflightAttemptSignal:
    @unchecked Sendable
{
    case progress(AetherFetchedByteProgress)
    case probeMilestone(UInt64)
    case inactivity(
        generation: UInt64,
        latestProgress: AetherFetchedByteProgress
    )
    case ownerCancellation
    case completed
}

private final class AetherProgressivePreflightProgressRelay:
    @unchecked Sendable
{
    private let attempt: Int
    private let liveness: AetherProgressivePreflightLiveness
    private let signal:
        AsyncStream<
            AetherProgressivePreflightAttemptSignal
        >.Continuation
    private let telemetry:
        AsyncStream<
            AetherProgressivePreflightEvent
        >.Continuation
    private let lock = NSLock()
    private var latest = AetherFetchedByteProgress(
        originBytesFetched: 0,
        sourceStoreBytesReused: 0
    )
    private var probeMilestoneGeneration:
        UInt64 = 0

    init(
        attempt: Int,
        liveness: AetherProgressivePreflightLiveness,
        signal:
            AsyncStream<
                AetherProgressivePreflightAttemptSignal
            >.Continuation,
        telemetry:
            AsyncStream<
                AetherProgressivePreflightEvent
            >.Continuation
    ) {
        self.attempt = attempt
        self.liveness = liveness
        self.signal = signal
        self.telemetry = telemetry
    }

    func receive(_ progress: AetherFetchedByteProgress) {
        lock.lock()
        let next = AetherFetchedByteProgress(
            originBytesFetched: max(
                latest.originBytesFetched,
                progress.originBytesFetched
            ),
            sourceStoreBytesReused: max(
                latest.sourceStoreBytesReused,
                progress.sourceStoreBytesReused
            )
        )
        guard next != latest else {
            lock.unlock()
            return
        }
        latest = next
        lock.unlock()
        if let snapshot = liveness.record(
            attempt: attempt,
            progress: next
        ) {
            telemetry.yield(
                .byteProgress(
                    attempt: attempt,
                    snapshot: snapshot
                )
            )
        }
        signal.yield(.progress(next))
    }

    func receiveProbeMilestone() {
        lock.lock()
        probeMilestoneGeneration &+= 1
        let generation = probeMilestoneGeneration
        lock.unlock()
        signal.yield(
            .probeMilestone(generation)
        )
    }

    var snapshot: AetherFetchedByteProgress {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    var latestProbeMilestoneGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return probeMilestoneGeneration
    }
}

private enum AetherProgressivePreflightAttemptOutcome {
    case prepared(AetherPreparedURLSource)
    case retry(
        AetherProgressivePreflightRetryReason,
        madeEffectiveProgress: Bool
    )
    case failed(Error)
    case cancelled
}

/// Deep module that owns progressive URL probing, progress-aware retry and
/// cancellation handshakes.
///
/// It never changes the canonical request and never emits a total-time
/// terminal. A zero-progress attempt is retired, awaited to quiescence, then
/// retried against the same request after the configured backoff until caller
/// or system cancellation.
actor AetherProgressivePreflight {
    nonisolated let events:
        AsyncStream<AetherProgressivePreflightEvent>

    private let request: AetherProgressivePreflightRequest
    private let retryPolicy: AetherProgressivePreflightRetryPolicy
    private let dependencies: AetherProgressivePreflightDependencies
    private let control = AetherProgressivePreflightControl()
    private let liveness =
        AetherProgressivePreflightLiveness()
    private let fetchedByteProgressLedger:
        AetherFetchedByteProgressLedger
    private let eventContinuation:
        AsyncStream<
            AetherProgressivePreflightEvent
        >.Continuation
    private var sourceByteStore: SourceByteStore?
    private var didStart = false
    private var didTransferPreparedSource = false
    /// Probe callbacks are emitted from fixed, ordered stages inside one
    /// Demuxer open. A retry that reaches a stage already observed by an
    /// earlier generation is not new container progress.
    private var highestProbeMilestoneGeneration: UInt64 = 0

    init(
        url: URL,
        options: LoadOptions = .init(),
        retryPolicy:
            AetherProgressivePreflightRetryPolicy = .production,
        fetchedByteProgressLedger:
            AetherFetchedByteProgressLedger =
                AetherFetchedByteProgressLedger()
    ) throws {
        let pair = AsyncStream.makeStream(
            of: AetherProgressivePreflightEvent.self,
            bufferingPolicy: .bufferingNewest(256)
        )
        events = pair.stream
        eventContinuation = pair.continuation
        request = AetherProgressivePreflightRequest(
            url: url,
            options: options
        )
        self.retryPolicy = retryPolicy
        self.fetchedByteProgressLedger =
            fetchedByteProgressLedger
        dependencies = .production
        if url.scheme?.lowercased() == "http"
            || url.scheme?.lowercased() == "https" {
            sourceByteStore = try SourceByteStore()
        } else {
            sourceByteStore = nil
        }
    }

    init(
        request: AetherProgressivePreflightRequest,
        retryPolicy: AetherProgressivePreflightRetryPolicy,
        sourceByteStore: SourceByteStore?,
        dependencies: AetherProgressivePreflightDependencies,
        fetchedByteProgressLedger:
            AetherFetchedByteProgressLedger =
                AetherFetchedByteProgressLedger()
    ) {
        let pair = AsyncStream.makeStream(
            of: AetherProgressivePreflightEvent.self,
            bufferingPolicy: .bufferingNewest(256)
        )
        events = pair.stream
        eventContinuation = pair.continuation
        self.request = request
        self.retryPolicy = retryPolicy
        self.sourceByteStore = sourceByteStore
        self.dependencies = dependencies
        self.fetchedByteProgressLedger =
            fetchedByteProgressLedger
    }

    deinit {
        if !didTransferPreparedSource {
            _ = control.requestCancellation()
            sourceByteStore?.close()
        }
        eventContinuation.finish()
    }

    nonisolated func requestCancellation() {
        let request = control.requestCancellation()
        if request.isFirst {
            eventContinuation.yield(
                .cancellationRequested(
                    attempt: request.attempt
                )
            )
            EngineLog.emit(
                "[AetherProgressivePreflight] cancellation requested "
                    + "attempt=\(request.attempt ?? 0)",
                category: .session
            )
        }
    }

    func prepare() async throws -> AetherPreparedURLSource {
        guard !didStart else {
            throw AetherProgressivePreflightError.alreadyStarted
        }
        didStart = true
        do {
            let prepared = try await withTaskCancellationHandler {
                try await runAttempts()
            } onCancel: {
                requestCancellation()
            }
            didTransferPreparedSource = true
            sourceByteStore = nil
            return prepared
        } catch is CancellationError {
            liveness.markCancelled()
            sourceByteStore?.close()
            sourceByteStore = nil
            eventContinuation.yield(.cancelled)
            eventContinuation.finish()
            throw CancellationError()
        } catch {
            liveness.markFailed()
            sourceByteStore?.close()
            sourceByteStore = nil
            eventContinuation.finish()
            throw error
        }
    }

    private func runAttempts() async throws
        -> AetherPreparedURLSource
    {
        var attemptNumber = 1
        var consecutiveZeroProgressAttempts = 0
        var retryLogCadence =
            AetherBoundedRetryLogCadence()
        var firstRetryReason:
            AetherProgressivePreflightRetryReason?
        while true {
            try checkCancellation()
            let policyAttempt =
                consecutiveZeroProgressAttempts + 1
            let inactivity = retryPolicy.inactivityTimeout(
                attempt: policyAttempt
            )
            liveness.beginAttempt(attemptNumber)
            eventContinuation.yield(
                .attemptStarted(
                    attempt: attemptNumber,
                    inactivitySeconds: inactivity
                )
            )
            if attemptNumber == 1 {
                EngineLog.emit(
                    "[AetherProgressivePreflight] attempt started "
                        + "attempt=1 "
                        + "inactivity=\(Int(inactivity))s",
                    category: .session
                )
            }

            let outcome = await runAttempt(
                number: attemptNumber,
                inactivitySeconds: inactivity
            )
            switch outcome {
            case .prepared(let prepared):
                if Task.isCancelled {
                    requestCancellation()
                }
                guard control.commitPreparedAttempt(
                    number: attemptNumber
                ) else {
                    prepared
                        .discardAndWaitForIOQuiescence()
                    control.retireAttempt(
                        number: attemptNumber
                    )
                    eventContinuation.yield(
                        .ioStopped(
                            attempt: attemptNumber
                        )
                    )
                    throw CancellationError()
                }
                liveness.markPrepared(
                    attempt: attemptNumber
                )
                let snapshot = liveness.snapshot
                eventContinuation.yield(
                    .prepared(
                        attempt: attemptNumber,
                        snapshot: snapshot
                    )
                )
                EngineLog.emit(
                    "[AetherProgressivePreflight] prepared "
                        + "attempt=\(attemptNumber) "
                        + "originBytes=\(snapshot.originBytesFetched) "
                        + "storeBytes=\(snapshot.sourceStoreBytesReused)",
                    category: .session
                )
                return prepared

            case .retry(
                let reason,
                let madeEffectiveProgress
            ):
                try checkCancellation()
                liveness.markBackingOff(
                    attempt: attemptNumber
                )
                if madeEffectiveProgress {
                    consecutiveZeroProgressAttempts = 0
                    retryLogCadence.resetAfterProgress()
                    firstRetryReason = nil
                } else {
                    consecutiveZeroProgressAttempts &+= 1
                }
                let backoff = retryPolicy.backoff(
                    afterAttempt:
                        max(
                            1,
                            consecutiveZeroProgressAttempts
                        )
                )
                eventContinuation.yield(
                    .retryScheduled(
                        afterAttempt: attemptNumber,
                        nextAttempt: attemptNumber + 1,
                        backoffSeconds: backoff,
                        reason: reason
                    )
                )
                if firstRetryReason == nil {
                    firstRetryReason = reason
                }
                if let emission =
                        retryLogCadence.recordFailure(
                            now: ProcessInfo.processInfo
                                .systemUptime
                        ) {
                    let checkpoint =
                        emission.checkpointSeconds.map {
                            String(Int($0))
                        } ?? "first"
                    EngineLog.emit(
                        "[AetherProgressivePreflight] retry "
                            + "checkpoint=\(checkpoint) "
                            + "elapsed=\(Int(emission.elapsedSeconds)) "
                            + "firstFailure="
                            + "\(firstRetryReason?.rawValue ?? reason.rawValue) "
                            + "cumulative="
                            + "\(emission.cumulativeFailureCount) "
                            + "currentFailure=\(reason.rawValue) "
                            + "afterAttempt=\(attemptNumber) "
                            + "nextAttempt=\(attemptNumber + 1) "
                            + "backoff=\(Int(backoff))s",
                        category: .session
                    )
                }
                try await sleepBackoff(backoff)
                attemptNumber &+= 1

            case .failed(let error):
                liveness.markFailed()
                eventContinuation.yield(
                    .permanentFailure(
                        attempt: attemptNumber,
                        snapshot: liveness.snapshot
                    )
                )
                throw error

            case .cancelled:
                throw CancellationError()
            }
        }
    }

    private func runAttempt(
        number: Int,
        inactivitySeconds: TimeInterval
    ) async -> AetherProgressivePreflightAttemptOutcome {
        let signalPair = AsyncStream.makeStream(
            of: AetherProgressivePreflightAttemptSignal.self,
            bufferingPolicy: .bufferingNewest(32)
        )
        let relay = AetherProgressivePreflightProgressRelay(
            attempt: number,
            liveness: liveness,
            signal: signalPair.continuation,
            telemetry: eventContinuation
        )
        let attempt = dependencies.makeAttempt(
            request,
            sourceByteStore,
            fetchedByteProgressLedger,
            liveness,
            relay.receive,
            relay.receiveProbeMilestone
        )
        guard control.install(
            attempt: attempt,
            number: number,
            notifyOwnerCancellation: {
                signalPair.continuation.yield(
                    .ownerCancellation
                )
            }
        ) else {
            attempt.requestCancellation()
            signalPair.continuation.finish()
            return .cancelled
        }

        let worker = Task.detached(
            priority: .userInitiated
        ) {
            let result: Result<AetherPreparedURLSource, Error>
            do {
                result = .success(try attempt.run())
            } catch {
                result = .failure(error)
            }
            let boxed = AetherProgressivePreflightWorkerResult(
                result: result
            )
            signalPair.continuation.yield(.completed)
            signalPair.continuation.finish()
            return boxed
        }

        var timerGeneration: UInt64 = 1
        var currentInactivitySeconds = inactivitySeconds
        var timer = makeInactivityTimer(
            seconds: currentInactivitySeconds,
            generation: timerGeneration,
            relay: relay,
            continuation: signalPair.continuation
        )
        var processed = AetherFetchedByteProgress(
            originBytesFetched: 0,
            sourceStoreBytesReused: 0
        )
        var madeEffectiveProgress = false

        for await signal in signalPair.stream {
            switch signal {
            case .progress(let latest):
                guard latest.totalAdvancedBytes
                        > processed.totalAdvancedBytes else {
                    continue
                }
                processed = latest
                madeEffectiveProgress = true
                currentInactivitySeconds =
                    retryPolicy.inactivityTimeout(attempt: 1)
                timer.cancel()
                timerGeneration &+= 1
                timer = makeInactivityTimer(
                    seconds: currentInactivitySeconds,
                    generation: timerGeneration,
                    relay: relay,
                    continuation: signalPair.continuation
                )

            case .probeMilestone(let generation):
                guard generation
                        > highestProbeMilestoneGeneration else {
                    continue
                }
                highestProbeMilestoneGeneration = generation
                madeEffectiveProgress = true
                if let snapshot =
                        liveness.recordProbeMilestone(
                            attempt: number
                        ) {
                    eventContinuation.yield(
                        .probeMilestone(
                            attempt: number,
                            ordinal: generation,
                            snapshot: snapshot
                        )
                    )
                }
                currentInactivitySeconds =
                    retryPolicy.inactivityTimeout(attempt: 1)
                timer.cancel()
                timerGeneration &+= 1
                timer = makeInactivityTimer(
                    seconds: currentInactivitySeconds,
                    generation: timerGeneration,
                    relay: relay,
                    continuation: signalPair.continuation
                )

            case .inactivity(
                let generation,
                _
            ):
                guard generation == timerGeneration else {
                    continue
                }
                // Re-read at handling time. A byte callback can race the
                // timer's queued signal; progress that arrived before this
                // decision must reset the window rather than lose to queue
                // ordering.
                let current = relay.snapshot
                let currentProbeMilestoneGeneration =
                    relay
                        .latestProbeMilestoneGeneration
                if current.totalAdvancedBytes
                        > processed.totalAdvancedBytes
                    || currentProbeMilestoneGeneration
                        > highestProbeMilestoneGeneration {
                    processed = current
                    if currentProbeMilestoneGeneration
                            > highestProbeMilestoneGeneration {
                        highestProbeMilestoneGeneration =
                            currentProbeMilestoneGeneration
                        if let snapshot =
                                liveness.recordProbeMilestone(
                                    attempt: number
                                ) {
                            eventContinuation.yield(
                                .probeMilestone(
                                    attempt: number,
                                    ordinal:
                                        currentProbeMilestoneGeneration,
                                    snapshot: snapshot
                                )
                            )
                        }
                    }
                    madeEffectiveProgress = true
                    currentInactivitySeconds =
                        retryPolicy.inactivityTimeout(attempt: 1)
                    timer.cancel()
                    timerGeneration &+= 1
                    timer = makeInactivityTimer(
                        seconds: currentInactivitySeconds,
                        generation: timerGeneration,
                        relay: relay,
                        continuation: signalPair.continuation
                    )
                    continue
                }
                timer.cancel()
                worker.cancel()
                control.cancelAttemptForRetry(
                    number: number
                )
                let late = await awaitCancelledWorker(
                    worker,
                    attempt: number
                )
                control.retireAttempt(number: number)
                if case .success(let prepared) = late.result {
                    prepared
                        .discardAndWaitForIOQuiescence()
                    eventContinuation.yield(
                        .lateResultDiscarded(
                            attempt: number
                        )
                    )
                }
                eventContinuation.yield(
                    .ioStopped(attempt: number)
                )
                if control.cancelled || Task.isCancelled {
                    return .cancelled
                }
                return .retry(
                    .inactivity,
                    madeEffectiveProgress:
                        madeEffectiveProgress
                )

            case .ownerCancellation:
                timer.cancel()
                worker.cancel()
                control.cancelAttemptForRetry(
                    number: number
                )
                let cancelled = await awaitCancelledWorker(
                    worker,
                    attempt: number
                )
                control.retireAttempt(number: number)
                if case .success(let prepared) =
                    cancelled.result {
                    prepared
                        .discardAndWaitForIOQuiescence()
                    eventContinuation.yield(
                        .lateResultDiscarded(
                            attempt: number
                        )
                    )
                }
                eventContinuation.yield(
                    .ioStopped(attempt: number)
                )
                return .cancelled

            case .completed:
                timer.cancel()
                let completed = await worker.value
                if control.cancelled || Task.isCancelled {
                    control.retireAttempt(
                        number: number
                    )
                    if case .success(let prepared) =
                        completed.result {
                        prepared
                            .discardAndWaitForIOQuiescence()
                    }
                    eventContinuation.yield(
                        .ioStopped(attempt: number)
                    )
                    return .cancelled
                }
                switch completed.result {
                case .success(let prepared):
                    // Keep the completed attempt installed until
                    // `commitPreparedAttempt` atomically transfers ownership
                    // against a racing cancellation.
                    return .prepared(prepared)
                case .failure(let error):
                    control.retireAttempt(
                        number: number
                    )
                    eventContinuation.yield(
                        .ioStopped(attempt: number)
                    )
                    switch AetherProgressivePreflightFailureClassifier
                        .classify(
                            error,
                            hasCompleteValidatedSourceEvidence:
                                sourceByteStore?
                                    .validationCandidate?
                                    .isComplete
                                    == true
                        ) {
                    case .cancelled:
                        return control.cancelled
                            || Task.isCancelled
                            ? .cancelled
                            : .retry(
                                madeEffectiveProgress
                                    ? .transientFailure
                                    : .zeroProgressFailure,
                                madeEffectiveProgress:
                                    madeEffectiveProgress
                            )
                    case .retry:
                        return .retry(
                            madeEffectiveProgress
                                ? .transientFailure
                                : .zeroProgressFailure,
                            madeEffectiveProgress:
                                madeEffectiveProgress
                        )
                    case .permanent:
                        return .failed(error)
                    }
                }
            }
        }

        timer.cancel()
        worker.cancel()
        control.cancelAttemptForRetry(number: number)
        let late = await awaitCancelledWorker(
            worker,
            attempt: number
        )
        control.retireAttempt(number: number)
        if case .success(let prepared) = late.result {
            prepared
                .discardAndWaitForIOQuiescence()
            eventContinuation.yield(
                .lateResultDiscarded(attempt: number)
            )
        }
        eventContinuation.yield(
            .ioStopped(attempt: number)
        )
        return .cancelled
    }

    /// Cancellation is diagnostic-bounded but teardown is not bypassed. If
    /// the worker misses the two-second acknowledgement window we emit a
    /// privacy-safe event, keep the generation isolated, and continue waiting
    /// for real I/O quiescence before any successor may exist.
    private func awaitCancelledWorker(
        _ worker:
            Task<AetherProgressivePreflightWorkerResult, Never>,
        attempt: Int
    ) async -> AetherProgressivePreflightWorkerResult {
        let sleep = dependencies.sleep
        let responseSeconds =
            retryPolicy.cancellationResponseSeconds
        let telemetry = eventContinuation
        let watchdog = Task {
            do {
                try await sleep(responseSeconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            telemetry.yield(
                .cancellationUnresponsive(
                    attempt: attempt,
                    waitedSeconds: responseSeconds
                )
            )
            EngineLog.emit(
                "[AetherProgressivePreflight] cancellation "
                    + "unresponsive attempt=\(attempt) "
                    + "waited=\(Int(responseSeconds))s",
                category: .session
            )
        }
        let result = await worker.value
        watchdog.cancel()
        return result
    }

    private func makeInactivityTimer(
        seconds: TimeInterval,
        generation: UInt64,
        relay: AetherProgressivePreflightProgressRelay,
        continuation:
            AsyncStream<
                AetherProgressivePreflightAttemptSignal
            >.Continuation
    ) -> Task<Void, Never> {
        let sleep = dependencies.sleep
        return Task {
            do {
                try await sleep(seconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            continuation.yield(
                .inactivity(
                    generation: generation,
                    latestProgress: relay.snapshot
                )
            )
        }
    }

    private func sleepBackoff(
        _ seconds: TimeInterval
    ) async throws {
        let sleep = dependencies.sleep
        let task = Task {
            try await sleep(seconds)
        }
        guard control.installBackoff(task) else {
            task.cancel()
            throw CancellationError()
        }
        defer { control.retireBackoff() }
        try await task.value
        try checkCancellation()
    }

    private func checkCancellation(
        discarding prepared:
            AetherPreparedURLSource? = nil
    ) throws {
        guard !control.cancelled,
              !Task.isCancelled else {
            prepared?
                .discardAndWaitForIOQuiescence()
            throw CancellationError()
        }
    }
}
