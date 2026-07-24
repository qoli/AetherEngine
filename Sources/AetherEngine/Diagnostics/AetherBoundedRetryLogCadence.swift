import Foundation

/// Monotonic clock seam for retry-log cadence tests. It never participates in
/// retry admission, backoff, cancellation, or playback state.
protocol AetherBoundedRetryLogClock: Sendable {
    func now() -> TimeInterval
}

struct AetherSystemBoundedRetryLogClock: AetherBoundedRetryLogClock {
    func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

/// One emitted retry-log summary. The count is intentionally cumulative for
/// the current no-progress epoch; no source URL, request field, or response
/// body is represented here.
struct AetherBoundedRetryLogEmission: Sendable, Equatable {
    let cumulativeFailureCount: Int
    let elapsedSeconds: TimeInterval
    let checkpointSeconds: TimeInterval?
}

/// Suppresses repeated production retry logs without changing recovery.
///
/// The first failure is always admitted. Later output is admitted at the
/// liveness diagnostic checkpoints (15/45/90/300 seconds in production) and
/// then at the configured repeating interval. A real-progress reset starts a
/// new diagnostic epoch while preserving the caller's retry/state semantics.
struct AetherBoundedRetryLogCadence: Equatable {
    private let checkpoints: [TimeInterval]
    private let repeatingInterval: TimeInterval
    private var epochStartedAt: TimeInterval?
    private var cumulativeFailureCount = 0
    private var nextCheckpointIndex = 0
    private var nextRepeatingCheckpoint: TimeInterval?

    init(
        policy: AetherPlaybackLivenessPolicy = .production
    ) {
        checkpoints = policy.diagnosticCheckpointsSeconds
        repeatingInterval = policy.repeatingDiagnosticIntervalSeconds
    }

    mutating func recordFailure(
        now: TimeInterval
    ) -> AetherBoundedRetryLogEmission? {
        let normalizedNow = now.isFinite ? now : 0
        cumulativeFailureCount &+= 1
        guard let epochStartedAt else {
            self.epochStartedAt = normalizedNow
            return AetherBoundedRetryLogEmission(
                cumulativeFailureCount: cumulativeFailureCount,
                elapsedSeconds: 0,
                checkpointSeconds: nil
            )
        }

        let elapsed = max(0, normalizedNow - epochStartedAt)
        var reachedCheckpoint: TimeInterval?
        while nextCheckpointIndex < checkpoints.count,
              elapsed >= checkpoints[nextCheckpointIndex] {
            reachedCheckpoint = checkpoints[nextCheckpointIndex]
            nextCheckpointIndex += 1
        }
        if nextCheckpointIndex == checkpoints.count,
           nextRepeatingCheckpoint == nil,
           let lastCheckpoint = checkpoints.last {
            nextRepeatingCheckpoint =
                lastCheckpoint + repeatingInterval
        }
        if let nextRepeatingCheckpoint,
           elapsed >= nextRepeatingCheckpoint {
            let intervalsElapsed = floor(
                (elapsed - nextRepeatingCheckpoint) / repeatingInterval
            )
            let repeatingCheckpoint = nextRepeatingCheckpoint
                + intervalsElapsed * repeatingInterval
            reachedCheckpoint = repeatingCheckpoint
            self.nextRepeatingCheckpoint = repeatingCheckpoint
                + repeatingInterval
        }
        guard let reachedCheckpoint else { return nil }
        return AetherBoundedRetryLogEmission(
            cumulativeFailureCount: cumulativeFailureCount,
            elapsedSeconds: elapsed,
            checkpointSeconds: reachedCheckpoint
        )
    }

    mutating func resetAfterProgress() {
        epochStartedAt = nil
        cumulativeFailureCount = 0
        nextCheckpointIndex = 0
        nextRepeatingCheckpoint = nil
    }
}
