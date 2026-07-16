import CoreMedia
import Testing
@testable import AetherEngine

@Suite("Hybrid carrier bandwidth policy")
struct HybridCarrierBandwidthPolicyTests {
    @Test("Fixed loopback budget remains primary when observed carrier exceeds it")
    func fixedBudgetDoesNotFollowObservedCarrier() throws {
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: 8,
                preferredTimescale: 90_000
            )
        )
        let telemetry = BlackCarrierBandwidthTelemetryCalculator
            .calculate(
                timeline: timeline,
                videoSamples: [
                    .init(segmentIndex: 0, byteCount: 100_000),
                    .init(segmentIndex: 1, byteCount: 100_000),
                ],
                audioSamples: [
                    [
                        .init(segmentIndex: 0, byteCount: 400_000),
                        .init(segmentIndex: 1, byteCount: 900_000),
                    ],
                    [
                        .init(segmentIndex: 0, byteCount: 1_400_000),
                        .init(segmentIndex: 1, byteCount: 2_900_000),
                    ],
                ]
            )

        #expect(
            telemetry.declaredTransportBudget
                == AetherHybridCarrierBandwidthPolicy
                    .loopbackTransportBudget
        )
        #expect(telemetry.declaredTransportBudget == 2_000_000)
        #expect(telemetry.observedPeakBandwidth == 6_000_000)
        #expect(telemetry.observedAverageBandwidth == 4_500_000)
        #expect(telemetry.observedSegmentCount == 2)
        #expect(telemetry.audioRenditionCount == 2)
        #expect(telemetry.state == .complete)
    }

    @Test("Telemetry reports partial and awaiting states without inventing evidence")
    func partialAndAwaitingStates() throws {
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: 8,
                preferredTimescale: 90_000
            )
        )
        let partial = BlackCarrierBandwidthTelemetryCalculator
            .calculate(
                timeline: timeline,
                videoSamples: [
                    .init(segmentIndex: 0, byteCount: 100_000),
                ],
                audioSamples: [
                    [
                        .init(segmentIndex: 0, byteCount: 400_000),
                    ],
                ]
            )
        #expect(partial.state == .partial)
        #expect(partial.observedSegmentCount == 1)
        #expect(partial.observedPeakBandwidth == 1_000_000)
        #expect(partial.observedAverageBandwidth == 1_000_000)

        let awaiting = BlackCarrierBandwidthTelemetryCalculator
            .calculate(
                timeline: timeline,
                videoSamples: [
                    .init(segmentIndex: 0, byteCount: 100_000),
                ],
                audioSamples: [[]]
            )
        #expect(awaiting.state == .awaitingCarrierSegments)
        #expect(awaiting.observedPeakBandwidth == nil)
        #expect(awaiting.observedAverageBandwidth == nil)
        #expect(awaiting.observedSegmentCount == 0)
    }

    @Test("Invalid carrier samples fail telemetry explicitly")
    func invalidSamplesAreUnavailable() throws {
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: 8,
                preferredTimescale: 90_000
            )
        )
        let duplicate = BlackCarrierBandwidthTelemetryCalculator
            .calculate(
                timeline: timeline,
                videoSamples: [
                    .init(segmentIndex: 0, byteCount: 1),
                    .init(segmentIndex: 0, byteCount: 2),
                ],
                audioSamples: []
            )
        #expect(duplicate.state == .unavailable)
        #expect(duplicate.observedPeakBandwidth == nil)

        let unknownIndex = BlackCarrierBandwidthTelemetryCalculator
            .calculate(
                timeline: timeline,
                videoSamples: [
                    .init(segmentIndex: 99, byteCount: 1),
                ],
                audioSamples: []
            )
        #expect(unknownIndex.state == .unavailable)

        let overflow = BlackCarrierBandwidthTelemetryCalculator
            .calculate(
                timeline: timeline,
                videoSamples: [
                    .init(segmentIndex: 0, byteCount: Int.max),
                ],
                audioSamples: [
                    [
                        .init(segmentIndex: 0, byteCount: 1),
                    ],
                ]
            )
        #expect(overflow.state == .unavailable)
        #expect(overflow.observedAverageBandwidth == nil)
    }
}
