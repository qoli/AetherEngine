import Foundation

/// Clock seam for playback-liveness diagnostics.
///
/// Sleeping here never authorizes a state transition. The scheduler below
/// only emits observation checkpoints; playback state remains owned by
/// `AetherPlaybackSession`.
protocol AetherLivenessDiagnosticClock: Sendable {
    func sleep(for seconds: TimeInterval) async throws
}

struct AetherSystemLivenessDiagnosticClock:
    AetherLivenessDiagnosticClock
{
    func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(
            nanoseconds: UInt64(seconds * 1_000_000_000)
        )
    }
}

struct AetherLivenessDiagnosticScheduler: Sendable {
    let policy: AetherPlaybackLivenessPolicy
    let clock: any AetherLivenessDiagnosticClock

    init(
        policy: AetherPlaybackLivenessPolicy,
        clock: any AetherLivenessDiagnosticClock =
            AetherSystemLivenessDiagnosticClock()
    ) {
        self.policy = policy
        self.clock = clock
    }

    @MainActor
    func run(
        while shouldContinue: () -> Bool,
        onCheckpoint: (TimeInterval) -> Void
    ) async {
        var previous: TimeInterval = 0
        for checkpoint in policy.diagnosticCheckpointsSeconds {
            do {
                try await clock.sleep(
                    for: checkpoint - previous
                )
            } catch {
                return
            }
            guard shouldContinue() else { return }
            onCheckpoint(checkpoint)
            previous = checkpoint
        }

        var elapsed = previous
        while !Task.isCancelled {
            do {
                try await clock.sleep(
                    for: policy
                        .repeatingDiagnosticIntervalSeconds
                )
            } catch {
                return
            }
            guard shouldContinue() else { return }
            elapsed += policy
                .repeatingDiagnosticIntervalSeconds
            onCheckpoint(elapsed)
        }
    }
}
