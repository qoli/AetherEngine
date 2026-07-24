import Foundation

struct ItemDeathReviveDecision:
    Sendable,
    Equatable
{
    let attempt: Int
    let backoffSeconds: TimeInterval
    let progressReset: Bool
    let diagnostic:
        AetherBoundedRetryLogEmission?
}

/// Same-route recovery for an AVPlayerItem that died via
/// `failedToPlayToEndTime` (issue #93, round 3).
///
/// The notification is not positive structural-failure evidence. In the
/// observed case it follows accumulated -12889 media-request timeouts and
/// means only that AVPlayer's local consumer abandoned the item. Recovery
/// therefore has no count or elapsed-time terminal: it reloads the same asset,
/// backs off at 1/2/4/8/15/30 seconds, and resets after real media-time
/// progress (or an explicit seek to a different dead spot). A separately
/// proven auth, identity, corruption, capability, or cancellation terminal
/// remains owned by the surrounding playback session.
struct ItemDeathReviveGate {
    private let policy:
        AetherPlaybackLivenessPolicy
    private(set) var attempts = 0
    private var lastPosition: Double?
    private var retryLogCadence:
        AetherBoundedRetryLogCadence

    init(
        policy:
            AetherPlaybackLivenessPolicy =
                .production
    ) {
        self.policy = policy
        retryLogCadence =
            AetherBoundedRetryLogCadence(
                policy: policy
            )
    }

    /// Position deltas at or below this are the same dead spot (rendered-clock
    /// jitter), not progress.
    private let progressEpsilon: Double = 0.5

    mutating func recordFailure(
        position: Double,
        nowUptime: TimeInterval =
            ProcessInfo.processInfo.systemUptime
    ) -> ItemDeathReviveDecision {
        let progressReset =
            lastPosition.map {
                abs(position - $0)
                    > progressEpsilon
            } ?? false
        if progressReset {
            attempts = 0
            retryLogCadence
                .resetAfterProgress()
        }
        lastPosition = position
        if attempts < Int.max {
            attempts += 1
        }
        return ItemDeathReviveDecision(
            attempt: attempts,
            backoffSeconds:
                policy.retryBackoffSeconds(
                    forAttempt:
                        max(1, attempts)
                ),
            progressReset: progressReset,
            diagnostic:
                retryLogCadence
                    .recordFailure(
                        now: nowUptime
                    )
        )
    }
}

extension AetherEngine {
    /// Pure decision: may a stalled-consumer recovery (nudge / stage-2 reload) act on a consumer
    /// whose `timeControlStatus` is `.paused`? A genuine user pause must never be fought; the
    /// item-death escalation bypasses the guard because `failedToPlayToEndTime` parks the dead
    /// item at `.paused`, and that pause IS the failure, not user intent.
    nonisolated static func stalledConsumerRecoveryAllowed(
        consumerIsPaused: Bool, allowPausedConsumer: Bool
    ) -> Bool {
        !consumerIsPaused || allowPausedConsumer
    }
}
