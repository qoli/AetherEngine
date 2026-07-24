import CoreMedia
import Testing
@testable import AetherEngine

@Suite("Progressive ProRes file-VOD segment policy")
struct AetherProgressiveProResSegmentPolicyTests {
    @Test("Exact validator-bound 25 GB ProRes evidence selects one-second segments")
    func observedOpenListSourceSelectsOneSecond() throws {
        let generation = try SourceByteStoreGeneration(
            contentLength: 25_005_843_710,
            validator: .strongETag("test-validator")
        )

        let decision =
            try AetherProgressiveProResSegmentPolicy.decide(
                sourceKind: .progressive,
                route: .hybridCarrier,
                reason: .hybridProRes,
                sourceGeneration: generation,
                durationSeconds: 387
            )

        #expect(decision.selection == .adaptiveHighBitrate)
        #expect(decision.isAdaptive)
        #expect(decision.segmentDurationTicks == 90_000)
        #expect(decision.contentLengthBytes == 25_005_843_710)
        #expect(decision.durationTicks == 34_830_000)
        #expect(
            decision.averageSourceBytesPerSecond
                == 64_614_584
        )
        #expect(
            decision.nominalSegmentBytes
                == 258_458_333
        )
        #expect(decision.segmentCount == 387)

        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: 387,
                preferredTimescale: 90_000
            ),
            segmentDurationTicks:
                decision.segmentDurationTicks
        )
        #expect(timeline.segments.count == 387)
        #expect(
            timeline.segments.allSatisfy {
                $0.duration.value == 90_000
            }
        )
    }

    @Test("Route and codec reason must both be exact")
    func exactRouteEvidenceRequired() throws {
        let generation = try validatorBoundGeneration(
            contentLength: 25_005_843_710
        )
        let decisions = [
            try AetherProgressiveProResSegmentPolicy.decide(
                sourceKind: .hls,
                route: .hybridCarrier,
                reason: .hybridProRes,
                sourceGeneration: generation,
                durationSeconds: 387
            ),
            try AetherProgressiveProResSegmentPolicy.decide(
                sourceKind: .progressive,
                route: .nativeAVPlayer,
                reason: .hybridProRes,
                sourceGeneration: generation,
                durationSeconds: 387
            ),
            try AetherProgressiveProResSegmentPolicy.decide(
                sourceKind: .progressive,
                route: .hybridCarrier,
                reason: .hybridHEVC,
                sourceGeneration: generation,
                durationSeconds: 387
            ),
        ]

        #expect(
            decisions.allSatisfy {
                $0.selection == .nominalIneligibleRoute
                    && !$0.isAdaptive
                    && $0.segmentDurationTicks == 360_000
            }
        )
    }

    @Test("Missing validator never enables adaptive segmentation")
    func validatorBindingRequired() throws {
        let unbound = try SourceByteStoreGeneration(
            contentLength: 25_005_843_710,
            validator: nil
        )

        for generation in [
            Optional<SourceByteStoreGeneration>.none,
            Optional(unbound),
        ] {
            let decision =
                try AetherProgressiveProResSegmentPolicy.decide(
                    sourceKind: .progressive,
                    route: .hybridCarrier,
                    reason: .hybridProRes,
                    sourceGeneration: generation,
                    durationSeconds: 387
                )
            #expect(
                decision.selection
                    == .nominalUnboundGeneration
            )
            #expect(decision.segmentDurationTicks == 360_000)
            #expect(decision.contentLengthBytes == nil)
        }
    }

    @Test("Unbound eligible ProRes cannot bypass the timeline capacity bound")
    func unboundGenerationStillEnforcesCapacity() throws {
        let unbound = try SourceByteStoreGeneration(
            contentLength: 25_005_843_710,
            validator: nil
        )
        let maximum = AetherProgressiveProResSegmentPolicy
            .maximumMaterializedSegmentCount

        for generation in [
            Optional<SourceByteStoreGeneration>.none,
            Optional(unbound),
        ] {
            do {
                _ = try AetherProgressiveProResSegmentPolicy
                    .decide(
                        sourceKind: .progressive,
                        route: .hybridCarrier,
                        reason: .hybridProRes,
                        sourceGeneration: generation,
                        durationSeconds:
                            Double(maximum * 4 + 1)
                    )
                Issue.record(
                    "Expected typed segment capacity failure"
                )
            } catch let error as
                    AetherProgressiveProResSegmentPolicyError {
                guard case .segmentCountExceedsCapacity =
                        error else {
                    Issue.record(
                        "Unexpected policy error: \(error)"
                    )
                    continue
                }
                let kind = AetherPlaybackSession.classify(
                    error
                )
                #expect(kind == .unsupportedCapability)
                #expect(
                    AetherPlaybackSession
                        .isPermanentFailure(kind)
                )
            }
        }
    }

    @Test("Missing or non-positive duration evidence keeps the four-second default")
    func invalidDurationKeepsNominal() throws {
        let generation = try validatorBoundGeneration(
            contentLength: 25_005_843_710
        )

        for duration in [
            0,
            -1,
            Double.infinity,
            Double.nan,
        ] {
            let decision =
                try AetherProgressiveProResSegmentPolicy.decide(
                    sourceKind: .progressive,
                    route: .hybridCarrier,
                    reason: .hybridProRes,
                    sourceGeneration: generation,
                    durationSeconds: duration
                )
            #expect(
                decision.selection
                    == .nominalInvalidDuration
            )
            #expect(decision.segmentDurationTicks == 360_000)
        }
    }

    @Test("Full-width ratio handles maximum content length without four-second fallback")
    func maximumContentLengthUsesSupportedMinimum() throws {
        let generation = try validatorBoundGeneration(
            contentLength: Int64.max
        )
        let decision =
            try AetherProgressiveProResSegmentPolicy.decide(
                sourceKind: .progressive,
                route: .hybridCarrier,
                reason: .hybridProRes,
                sourceGeneration: generation,
                durationSeconds: 387
            )

        #expect(decision.selection == .adaptiveHighBitrate)
        #expect(decision.segmentDurationTicks == 90_000)
        #expect(decision.segmentCount == 387)
        #expect(decision.contentLengthBytes == Int64.max)
        #expect(
            decision.averageSourceBytesPerSecond
                == 23_833_002_679_211_307
        )
        #expect(
            decision.nominalSegmentBytes
                == 95_332_010_716_845_228
        )
    }

    @Test("Extreme bitrate never creates a sub-frame segment")
    func extremeBitrateRespectsMinimumCadence() throws {
        let generation = try validatorBoundGeneration(
            contentLength: Int64.max
        )
        let decision =
            try AetherProgressiveProResSegmentPolicy.decide(
                sourceKind: .progressive,
                route: .hybridCarrier,
                reason: .hybridProRes,
                sourceGeneration: generation,
                durationSeconds: 1
            )

        #expect(decision.isAdaptive)
        #expect(
            decision.segmentDurationTicks
                == AetherProgressiveProResSegmentPolicy
                    .minimumSupportedSegmentDurationTicks
        )
        #expect(decision.segmentCount == 1)
    }

    @Test("Long source raises segment duration to preserve the materialization bound")
    func longDurationPreservesSegmentCountBound() throws {
        let generation = try validatorBoundGeneration(
            contentLength: Int64.max
        )
        let durationSeconds = 200_000.0
        let decision =
            try AetherProgressiveProResSegmentPolicy.decide(
                sourceKind: .progressive,
                route: .hybridCarrier,
                reason: .hybridProRes,
                sourceGeneration: generation,
                durationSeconds: durationSeconds
            )

        #expect(decision.isAdaptive)
        #expect(decision.segmentDurationTicks > 90_000)
        #expect(
            decision.segmentDurationTicks <= 360_000
        )
        #expect(
            decision.segmentCount
                == Int64(
                    AetherProgressiveProResSegmentPolicy
                        .maximumMaterializedSegmentCount
                )
        )
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: durationSeconds,
                preferredTimescale: 90_000
            ),
            segmentDurationTicks:
                decision.segmentDurationTicks
        )
        #expect(
            timeline.segments.count
                <= AetherProgressiveProResSegmentPolicy
                    .maximumMaterializedSegmentCount
        )
    }

    @Test("Unmaterializable duration fails as permanent typed capability evidence")
    func durationBeyondSegmentCapacityFailsTyped() throws {
        let generation = try validatorBoundGeneration(
            contentLength: Int64.max
        )
        let maximum = AetherProgressiveProResSegmentPolicy
            .maximumMaterializedSegmentCount
        let durationSeconds = Double(maximum * 4 + 1)

        do {
            _ = try AetherProgressiveProResSegmentPolicy
                .decide(
                    sourceKind: .progressive,
                    route: .hybridCarrier,
                    reason: .hybridProRes,
                    sourceGeneration: generation,
                    durationSeconds: durationSeconds
                )
            Issue.record("Expected typed segment capacity failure")
        } catch let error as
                AetherProgressiveProResSegmentPolicyError {
            guard case .segmentCountExceedsCapacity(
                let required,
                let reportedMaximum
            ) = error else {
                Issue.record("Unexpected policy error: \(error)")
                return
            }
            #expect(required == Int64(maximum + 1))
            #expect(reportedMaximum == maximum)
            #expect(
                AetherPlaybackSession.classify(error)
                    == .unsupportedCapability
            )
            #expect(
                AetherPlaybackSession.isPermanentFailure(
                    AetherPlaybackSession.classify(error)
                )
            )
            #expect(
                AetherPlaybackSession.failureCaseCode(error)
                    == "progressiveProRes.segmentPlanCapacityExceeded"
            )
        }
    }

    @Test("Finite duration outside 90 kHz range fails typed")
    func durationOutsideTimelineRangeFailsTyped() throws {
        let generation = try validatorBoundGeneration(
            contentLength: Int64.max
        )
        #expect(
            throws:
                AetherProgressiveProResSegmentPolicyError
                    .durationOutsideTimelineRange
        ) {
            _ = try AetherProgressiveProResSegmentPolicy
                .decide(
                    sourceKind: .progressive,
                    route: .hybridCarrier,
                    reason: .hybridProRes,
                    sourceGeneration: generation,
                    durationSeconds:
                        Double(Int64.max) / 90_000
                )
        }
    }

    @Test("Validator-bound low bitrate evidence preserves public four-second segmentation")
    func lowBitrateKeepsNominal() throws {
        let generation = try validatorBoundGeneration(
            contentLength: 500_000_000
        )
        let decision =
            try AetherProgressiveProResSegmentPolicy.decide(
                sourceKind: .progressive,
                route: .hybridCarrier,
                reason: .hybridProRes,
                sourceGeneration: generation,
                durationSeconds: 600
            )

        #expect(decision.selection == .nominalWithinTarget)
        #expect(!decision.isAdaptive)
        #expect(decision.segmentDurationTicks == 360_000)
        #expect(decision.segmentCount == 150)

        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: 10.25,
                preferredTimescale: 90_000
            )
        )
        #expect(
            timeline.segments.map(\.duration.value)
                == [360_000, 360_000, 202_500]
        )
    }

    private func validatorBoundGeneration(
        contentLength: Int64
    ) throws -> SourceByteStoreGeneration {
        try SourceByteStoreGeneration(
            contentLength: contentLength,
            validator: .lastModified("test-validator")
        )
    }
}
