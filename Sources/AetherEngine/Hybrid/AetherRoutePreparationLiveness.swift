import Foundation

/// Privacy-safe semantic work performed while an admitted route is preparing.
///
/// The enum intentionally carries no source identity, byte offset, packet
/// payload, codec-private data, request headers, or error description.
enum AetherRoutePreparationProgressKind:
    String,
    Sendable,
    Equatable
{
    /// A packet was durably returned by the admitted Demuxer and can be
    /// consumed by the exact Hybrid generation.
    case demuxPacket
}

struct AetherRoutePreparationProgressSnapshot:
    Sendable,
    Equatable
{
    let ordinal: UInt64
    let lastProgressUptimeSeconds: TimeInterval?
}

/// Constant-memory, monotonic handoff from the provider worker to the outer
/// playback liveness owner.
final class AetherRoutePreparationProgressLedger:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var ordinal: UInt64 = 0
    private var lastProgressUptimeSeconds: TimeInterval?

    @discardableResult
    func record(
        _ kind: AetherRoutePreparationProgressKind,
        at uptime: TimeInterval =
            ProcessInfo.processInfo.systemUptime
    ) -> AetherRoutePreparationProgressSnapshot {
        _ = kind
        lock.lock()
        if ordinal < UInt64.max {
            ordinal += 1
        }
        if uptime.isFinite, uptime >= 0 {
            lastProgressUptimeSeconds = max(
                lastProgressUptimeSeconds ?? 0,
                uptime
            )
        }
        let snapshot = snapshotLocked()
        lock.unlock()
        return snapshot
    }

    var snapshot: AetherRoutePreparationProgressSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotLocked()
    }

    private func snapshotLocked()
        -> AetherRoutePreparationProgressSnapshot
    {
        AetherRoutePreparationProgressSnapshot(
            ordinal: ordinal,
            lastProgressUptimeSeconds:
                lastProgressUptimeSeconds
        )
    }
}

struct AetherRoutePreparationProgressEvidence:
    Sendable,
    Equatable
{
    let uniqueBytes: Int64
    let semanticOrdinal: UInt64
    let semanticProgressUptimeSeconds: TimeInterval?

    func advances(
        beyond previous: Self
    ) -> Bool {
        uniqueBytes > previous.uniqueBytes
            || semanticOrdinal > previous.semanticOrdinal
    }
}

protocol AetherRoutePreparationLivenessClock:
    Sendable
{
    func now() async -> TimeInterval
    func sleep(for seconds: TimeInterval) async throws
}

struct AetherSystemRoutePreparationLivenessClock:
    AetherRoutePreparationLivenessClock
{
    func now() async -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    func sleep(for seconds: TimeInterval) async throws {
        guard seconds > 0 else {
            await Task.yield()
            return
        }
        try await Task.sleep(
            nanoseconds: UInt64(seconds * 1_000_000_000)
        )
    }
}

struct AetherRoutePreparationNoProgress:
    Error,
    Sendable,
    Equatable
{
    let attempt: Int
    let windowSeconds: TimeInterval
    let evidence: AetherRoutePreparationProgressEvidence
}

/// Progress-aware route-preparation supervisor.
///
/// Elapsed time alone is never terminal. The supervisor asks for cooperative
/// same-source recovery only when both unique source bytes and semantic route
/// work remain fixed for the current no-progress window. Any accepted progress
/// resets the window to the first policy window; the outer session resets its
/// retry/backoff ledger from the same callback.
struct AetherRoutePreparationLivenessSupervisor:
    Sendable
{
    let policy: AetherPlaybackLivenessPolicy
    let clock: any AetherRoutePreparationLivenessClock
    let pollIntervalSeconds: TimeInterval
    let recoveryOwnerGraceSeconds: TimeInterval

    init(
        policy: AetherPlaybackLivenessPolicy,
        clock: any AetherRoutePreparationLivenessClock =
            AetherSystemRoutePreparationLivenessClock(),
        pollIntervalSeconds: TimeInterval = 0.25,
        recoveryOwnerGraceSeconds: TimeInterval = 2
    ) {
        precondition(
            pollIntervalSeconds.isFinite
                && pollIntervalSeconds > 0
        )
        precondition(
            recoveryOwnerGraceSeconds.isFinite
                && recoveryOwnerGraceSeconds > 0
        )
        self.policy = policy
        self.clock = clock
        self.pollIntervalSeconds = pollIntervalSeconds
        self.recoveryOwnerGraceSeconds =
            recoveryOwnerGraceSeconds
    }

    @MainActor
    func waitForNoProgress(
        attempt: Int,
        evidence:
            @escaping @MainActor @Sendable ()
                -> AetherRoutePreparationProgressEvidence,
        recoveryOwnerPhase:
            @escaping @MainActor @Sendable ()
                -> AetherPlaybackLivenessPhase? = {
                nil
            },
        onProgress:
            @escaping @MainActor @Sendable (
                AetherRoutePreparationProgressEvidence
            ) -> Void = { _ in }
    ) async throws -> AetherRoutePreparationNoProgress {
        precondition(attempt > 0)
        var effectiveAttempt = attempt
        var previous = evidence()
        var window = policy.noProgressWindowSeconds(
            forAttempt: attempt
        )
        var deadline = await clock.now() + window
        var recoveryOwnerGraceDeadline:
            TimeInterval?

        while true {
            try Task.checkCancellation()
            let current = evidence()
            if current.advances(beyond: previous) {
                previous = current
                onProgress(current)
                effectiveAttempt = 1
                window = policy.noProgressWindowSeconds(
                    forAttempt: 1
                )
                deadline = await clock.now() + window
                recoveryOwnerGraceDeadline = nil
            }
            let now = await clock.now()
            if now < deadline {
                try await clock.sleep(
                    for: min(
                        pollIntervalSeconds,
                        deadline - now
                    )
                )
                continue
            }

            if recoveryOwnerPhase() == .preparingRoute {
                // The inner carrier owns the exact readiness timer. Give it a
                // short handoff window to publish `.retryScheduled`, avoiding
                // two owners firing at the same instant. This event is not
                // progress and does not reset the source deadline. A wedged
                // inner attempt can suppress source recovery only for this
                // bounded grace.
                let graceDeadline =
                    recoveryOwnerGraceDeadline
                        ?? (now + recoveryOwnerGraceSeconds)
                recoveryOwnerGraceDeadline =
                    graceDeadline
                if now < graceDeadline {
                    try await clock.sleep(
                        for: min(
                            pollIntervalSeconds,
                            graceDeadline - now
                        )
                    )
                    continue
                }
            }

            // Close the timer/callback race by re-reading evidence at the
            // decision point. A packet or byte observed before this read owns
            // the next liveness window even if its notification was delayed.
            let decisionEvidence = evidence()
            if decisionEvidence.advances(beyond: previous) {
                previous = decisionEvidence
                onProgress(decisionEvidence)
                effectiveAttempt = 1
                window = policy.noProgressWindowSeconds(
                    forAttempt: 1
                )
                deadline = await clock.now() + window
                continue
            }

            return AetherRoutePreparationNoProgress(
                attempt: effectiveAttempt,
                windowSeconds: window,
                evidence: decisionEvidence
            )
        }
    }
}

enum AetherRoutePreparationRetryEvent:
    Sendable,
    Equatable
{
    case attemptStarted(attempt: Int)
    case retryScheduled(
        completedAttempt: Int,
        nextAttempt: Int,
        nextRetryUptimeSeconds: TimeInterval
    )
    case completed
}

/// Pure projection used by the outer public liveness snapshot. Inner
/// black-carrier retry remains locally owned, while its attempt and next retry
/// are observable without exposing the loopback URL or AVFoundation errors.
struct AetherRoutePreparationRetryProjection:
    Sendable,
    Equatable
{
    private(set) var phase: AetherPlaybackLivenessPhase?
    private(set) var attempt: Int?
    private(set) var nextRetryUptimeSeconds: TimeInterval?

    mutating func apply(
        _ event: AetherRoutePreparationRetryEvent
    ) {
        switch event {
        case .attemptStarted(let attempt):
            precondition(attempt > 0)
            phase = .preparingRoute
            self.attempt = attempt
            nextRetryUptimeSeconds = nil
        case .retryScheduled(
            _,
            let nextAttempt,
            let nextRetryUptimeSeconds
        ):
            precondition(nextAttempt > 0)
            phase = .retryScheduled
            attempt = nextAttempt
            self.nextRetryUptimeSeconds =
                nextRetryUptimeSeconds
        case .completed:
            reset()
        }
    }

    mutating func reset() {
        phase = nil
        attempt = nil
        nextRetryUptimeSeconds = nil
    }
}

/// Single-owner race between route preparation and semantic inactivity.
///
/// Once inactivity wins, operation completion is fenced until cooperative
/// stop and I/O quiescence finish. The caller therefore cannot start a
/// successor generation while the retiring route still owns a reader.
@MainActor
final class AetherRoutePreparationLivenessRace {
    private enum State {
        case idle
        case pending
        case stoppingForNoProgress
        case resolved
    }

    private var state: State = .idle
    private var continuation:
        CheckedContinuation<Void, Error>?
    private var operationTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var cancellationRequested = false

    func run(
        operation:
            @escaping @MainActor @Sendable () async throws -> Void,
        monitor:
            @escaping @MainActor @Sendable () async throws
                -> AetherRoutePreparationNoProgress,
        stopAndWaitForIOQuiescence:
            @escaping @MainActor @Sendable (
                AetherRoutePreparationNoProgress
            ) async -> Void
    ) async throws {
        precondition(state == .idle)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                continuation in
                start(
                    continuation: continuation,
                    operation: operation,
                    monitor: monitor,
                    stopAndWaitForIOQuiescence:
                        stopAndWaitForIOQuiescence
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    private func start(
        continuation:
            CheckedContinuation<Void, Error>,
        operation:
            @escaping @MainActor @Sendable () async throws -> Void,
        monitor:
            @escaping @MainActor @Sendable () async throws
                -> AetherRoutePreparationNoProgress,
        stopAndWaitForIOQuiescence:
            @escaping @MainActor @Sendable (
                AetherRoutePreparationNoProgress
            ) async -> Void
    ) {
        self.continuation = continuation
        state = .pending
        operationTask = Task { @MainActor [weak self] in
            let result: Result<Void, Error>
            do {
                try await operation()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            self?.operationFinished(result)
        }
        monitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let noProgress = try await monitor()
                await self.inactivityWon(
                    noProgress,
                    stopAndWaitForIOQuiescence:
                        stopAndWaitForIOQuiescence
                )
            } catch {
                self.monitorFinished(error)
            }
        }
    }

    private func operationFinished(
        _ result: Result<Void, Error>
    ) {
        guard state == .pending else { return }
        monitorTask?.cancel()
        resolve(result)
    }

    private func monitorFinished(_ error: Error) {
        guard state == .pending else { return }
        operationTask?.cancel()
        resolve(.failure(error))
    }

    private func inactivityWon(
        _ noProgress:
            AetherRoutePreparationNoProgress,
        stopAndWaitForIOQuiescence:
            @MainActor @Sendable (
                AetherRoutePreparationNoProgress
            ) async -> Void
    ) async {
        guard state == .pending else { return }
        state = .stoppingForNoProgress
        operationTask?.cancel()
        await stopAndWaitForIOQuiescence(noProgress)
        await operationTask?.value
        guard state == .stoppingForNoProgress else {
            return
        }
        resolve(
            .failure(
                cancellationRequested
                    ? CancellationError()
                    : noProgress
            )
        )
    }

    private func cancel() {
        switch state {
        case .idle, .resolved:
            return
        case .pending:
            operationTask?.cancel()
            monitorTask?.cancel()
            resolve(.failure(CancellationError()))
        case .stoppingForNoProgress:
            cancellationRequested = true
            operationTask?.cancel()
        }
    }

    private func resolve(
        _ result: Result<Void, Error>
    ) {
        guard let continuation else { return }
        self.continuation = nil
        state = .resolved
        operationTask = nil
        monitorTask = nil
        continuation.resume(with: result)
    }
}
