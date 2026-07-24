import Testing
import Foundation
@testable import AetherEngine

/// #93 round 3: accumulated -12889 media timeouts kill the AVPlayerItem
/// (failedToPlayToEndTime, rate 0, tcs .paused). Every recovery layer then
/// misreads the dead item as a user pause and disarms, making the session
/// terminal. These tests cover the pure decisions of the escalation path:
/// classifying generic death as recoverable across native routes, bypassing
/// the failure-induced pause guard, and progress-aware unbounded retry.
struct Issue93ItemDeathReviveTests {

    // MARK: - ItemDeathReviveGate

    @Test("hundreds of frozen item deaths remain retryable")
    func frozenPositionNeverExhausts() {
        var gate = ItemDeathReviveGate()
        var last:
            ItemDeathReviveDecision? =
                nil
        for index in 1...500 {
            last = gate.recordFailure(
                position: 354.8,
                nowUptime: Double(index)
            )
        }
        #expect(last?.attempt == 500)
        #expect(last?.backoffSeconds == 30)
        #expect(gate.attempts == 500)
    }

    @Test("playback progress resets attempt and backoff")
    func progressResets() {
        var gate = ItemDeathReviveGate()
        _ = gate.recordFailure(
            position: 100,
            nowUptime: 1
        )
        _ = gate.recordFailure(
            position: 100,
            nowUptime: 2
        )
        let freshEpisode =
            gate.recordFailure(
                position: 130,
                nowUptime: 3
            )
        #expect(freshEpisode.progressReset)
        #expect(freshEpisode.attempt == 1)
        #expect(freshEpisode.backoffSeconds == 1)
        #expect(
            freshEpisode.diagnostic?
                .checkpointSeconds == nil
        )
    }

    @Test("a user seek to a different position is a fresh episode too")
    func seekAwayResets() {
        var gate = ItemDeathReviveGate()
        _ = gate.recordFailure(
            position: 500,
            nowUptime: 1
        )
        _ = gate.recordFailure(
            position: 500,
            nowUptime: 2
        )
        // Backward jump (user scrubbed away from the dead window).
        let scrubbedAway =
            gate.recordFailure(
                position: 320,
                nowUptime: 3
            )
        #expect(scrubbedAway.progressReset)
        #expect(scrubbedAway.attempt == 1)
    }

    @Test("retry logs are bounded by liveness checkpoints")
    func retryLogsUseManualClock() {
        var gate = ItemDeathReviveGate()
        #expect(
            gate.recordFailure(
                position: 10,
                nowUptime: 1_000
            ).diagnostic != nil
        )
        #expect(
            gate.recordFailure(
                position: 10,
                nowUptime: 1_001
            ).diagnostic == nil
        )
        #expect(
            gate.recordFailure(
                position: 10,
                nowUptime: 1_015
            ).diagnostic?
                .checkpointSeconds == 15
        )
        #expect(
            gate.recordFailure(
                position: 10,
                nowUptime: 1_600
            ).diagnostic?
                .checkpointSeconds == 600
        )
    }

    // MARK: - Pause-guard bypass

    @Test("recovery guard keeps refusing a genuinely paused consumer")
    func guardRefusesPausedConsumer() {
        #expect(!AetherEngine.stalledConsumerRecoveryAllowed(
            consumerIsPaused: true, allowPausedConsumer: false))
    }

    @Test("item-death trigger may recover a consumer that LOOKS paused")
    func guardAllowsItemDeathTrigger() {
        // failedToPlayToEndTime parks tcs at .paused; that pause is the
        // failure itself, not user intent.
        #expect(AetherEngine.stalledConsumerRecoveryAllowed(
            consumerIsPaused: true, allowPausedConsumer: true))
    }

    @Test("a playing consumer is always recoverable")
    func guardAllowsPlayingConsumer() {
        #expect(AetherEngine.stalledConsumerRecoveryAllowed(
            consumerIsPaused: false, allowPausedConsumer: false))
    }

    // MARK: - Host-side failure classification

    @Test("generic loopback item death remains same-item retryable")
    func loopbackDeathRetries() {
        #expect(
            NativeAVPlayerHost
                .itemFailureDisposition(
                    errorCode: -12889
                )
                == .retrySameItem
        )
    }

    @Test("generic remote-live item death remains same-item retryable")
    func leanLiveDeathRetries() {
        #expect(
            NativeAVPlayerHost
                .itemFailureDisposition(
                    errorCode: -1001
                )
                == .retrySameItem
        )
    }

    @Test("display rejection alone is a typed capability terminal")
    func displayRejectionFailsClosed() {
        #expect(
            NativeAVPlayerHost
                .itemFailureDisposition(
                    errorCode: -11868
                )
                == .failDisplayCapability
        )
    }
}
