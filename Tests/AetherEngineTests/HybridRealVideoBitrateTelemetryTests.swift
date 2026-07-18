import Testing
@testable import AetherEngine

@Suite("Hybrid real-video bitrate telemetry")
struct HybridRealVideoBitrateTelemetryTests {
    @Test("Compressed bytes and exact packet duration produce bits per second")
    func calculatesAverageFromObservedPackets() {
        var accumulator =
            HybridRealVideoBitrateAccumulator()

        accumulator.record(
            byteCount: 1_000,
            durationTicks: 40,
            timeBaseNumerator: 1,
            timeBaseDenominator: 1_000
        )
        accumulator.record(
            byteCount: 1_000,
            durationTicks: 40,
            timeBaseNumerator: 1,
            timeBaseDenominator: 1_000
        )

        let partial = accumulator.snapshot()
        #expect(partial.state == .partial)
        #expect(partial.observedAverageBitrate == 200_000)
        #expect(partial.observedCompressedByteCount == 2_000)
        #expect(partial.observedPacketCount == 2)
        #expect(
            abs(
                (partial.observedSourceDurationSeconds ?? 0)
                    - 0.08
            ) < 0.000_001
        )

        accumulator.markComplete()
        let complete = accumulator.snapshot()
        #expect(complete.state == .complete)
        #expect(complete.observedAverageBitrate == 200_000)
    }

    @Test("Generation reset discards all previous compressed-byte evidence")
    func resetStartsAwaitingAgain() {
        var accumulator =
            HybridRealVideoBitrateAccumulator()
        accumulator.record(
            byteCount: 1_000,
            durationTicks: 1,
            timeBaseNumerator: 1,
            timeBaseDenominator: 25
        )
        accumulator.markComplete()

        accumulator.reset()
        let telemetry = accumulator.snapshot()
        #expect(telemetry.state == .awaitingCompressedPackets)
        #expect(telemetry.observedAverageBitrate == nil)
        #expect(telemetry.observedCompressedByteCount == 0)
        #expect(telemetry.observedPacketCount == 0)
    }

    @Test("Missing packet duration is unavailable without an estimate")
    func missingTimingDoesNotFallback() {
        var accumulator =
            HybridRealVideoBitrateAccumulator()
        accumulator.record(
            byteCount: 1_000,
            durationTicks: 0,
            timeBaseNumerator: 1,
            timeBaseDenominator: 25
        )

        let telemetry = accumulator.snapshot()
        #expect(telemetry.state == .unavailable)
        #expect(telemetry.observedAverageBitrate == nil)
    }

    @Test("Invalid time base and numeric overflow are unavailable")
    func invalidEvidenceDoesNotProduceBitrate() {
        var invalidTimeBase =
            HybridRealVideoBitrateAccumulator()
        invalidTimeBase.record(
            byteCount: 1_000,
            durationTicks: 1,
            timeBaseNumerator: 0,
            timeBaseDenominator: 25
        )
        #expect(
            invalidTimeBase.snapshot().state
                == .unavailable
        )
        #expect(
            invalidTimeBase.snapshot()
                .observedAverageBitrate == nil
        )

        var overflow =
            HybridRealVideoBitrateAccumulator()
        overflow.record(
            byteCount: Int.max,
            durationTicks: 1,
            timeBaseNumerator: 1,
            timeBaseDenominator: 1
        )
        #expect(overflow.snapshot().state == .unavailable)
        #expect(
            overflow.snapshot().observedAverageBitrate
                == nil
        )
    }

    @Test("Completed stream without packets is unavailable")
    func emptyCompletedStreamIsUnavailable() {
        var accumulator =
            HybridRealVideoBitrateAccumulator()
        accumulator.markComplete()

        let telemetry = accumulator.snapshot()
        #expect(telemetry.state == .unavailable)
        #expect(telemetry.observedAverageBitrate == nil)
    }
}
