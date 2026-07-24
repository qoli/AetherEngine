import Foundation
import Testing
@testable import AetherEngine

@MainActor
@Suite("Bounded playback progress logging")
struct AetherBoundedProgressLogCadenceTests {
    @Test(
        "source output requires monotonic session-unique bytes"
    )
    func sourceBytesAreMonotonicAndCumulative() {
        var cadence = AetherBoundedProgressLogCadence(
            minimumIntervalSeconds: 15
        )
        cadence.reset(now: 100)

        let first = cadence.record(
            .sourceBytes(
                phase: .preflighting,
                generation: 2,
                attempt: 3,
                uniqueBytes: 1_024,
                progressUptime: 101,
                observedUptime: 101
            )
        )
        #expect(first.acceptedProgress)
        #expect(
            first.emission
                == AetherPlaybackProgressLogEmission(
                    phase: .preflighting,
                    generation: 2,
                    attempt: 3,
                    metric: .sourceBytes(
                        uniqueBytes: 1_024,
                        deltaBytes: 1_024,
                        wallRateBytesPerSecond: 1_024,
                        progressGapMilliseconds: 1_000,
                        lastProgressAgeMilliseconds: 0
                    )
                )
        )

        #expect(
            cadence.record(
                .sourceBytes(
                    phase: .preflighting,
                    generation: 3,
                    attempt: 4,
                    uniqueBytes: 1_024,
                    progressUptime: 102,
                    observedUptime: 102
                )
            ) == .ignored
        )
        #expect(
            cadence.record(
                .sourceBytes(
                    phase: .preflighting,
                    generation: 3,
                    attempt: 4,
                    uniqueBytes: 2_048,
                    progressUptime: 105,
                    observedUptime: 105
                )
            ) == .accepted(nil)
        )

        let next = cadence.record(
            .sourceBytes(
                phase: .buffering,
                generation: 3,
                attempt: 4,
                uniqueBytes: 8_192,
                progressUptime: 116,
                observedUptime: 116.25
            )
        )
        #expect(
            next.emission
                == AetherPlaybackProgressLogEmission(
                    phase: .buffering,
                    generation: 3,
                    attempt: 4,
                    metric: .sourceBytes(
                        uniqueBytes: 8_192,
                        deltaBytes: 7_168,
                        wallRateBytesPerSecond: 478,
                        progressGapMilliseconds: 11_000,
                        lastProgressAgeMilliseconds: 250
                    )
                )
        )
    }

    @Test(
        "phase and generation churn cannot bypass the hard interval"
    )
    func highFrequencyProgressIsHardCapped() {
        var cadence = AetherBoundedProgressLogCadence(
            minimumIntervalSeconds: 15
        )
        cadence.reset(now: 0)
        var emissionCount = 0

        for index in 1...1_000 {
            let now = Double(index) / 100
            let decision = cadence.record(
                .sourceBytes(
                    phase: index.isMultiple(of: 2)
                        ? .preflighting
                        : .buffering,
                    generation: UInt64(index),
                    attempt: index,
                    uniqueBytes: Int64(index),
                    progressUptime: now,
                    observedUptime: now
                )
            )
            if decision.emission != nil {
                emissionCount += 1
            }
        }
        #expect(emissionCount == 1)

        let afterWindow = cadence.record(
            .sourceBytes(
                phase: .buffering,
                generation: 1_001,
                attempt: 1_001,
                uniqueBytes: 1_001,
                progressUptime: 15.01,
                observedUptime: 15.01
            )
        )
        #expect(afterWindow.emission != nil)
    }

    @Test(
        "container ordinal restarts only in a newer preflight epoch"
    )
    func containerEpochFencesLateAndDuplicateEvents() {
        var cadence = AetherBoundedProgressLogCadence(
            minimumIntervalSeconds: 15
        )
        cadence.reset(now: 0)

        let first = cadence.record(
            .containerMilestone(
                phase: .preflighting,
                generation: 4,
                attempt: 1,
                preflightEpoch: 1,
                ordinal: 1,
                progressUptime: 1,
                observedUptime: 1
            )
        )
        #expect(first.acceptedProgress)
        #expect(first.emission != nil)

        #expect(
            cadence.record(
                .containerMilestone(
                    phase: .preflighting,
                    generation: 4,
                    attempt: 1,
                    preflightEpoch: 1,
                    ordinal: 1,
                    progressUptime: 2,
                    observedUptime: 2
                )
            ) == .ignored
        )
        #expect(
            cadence.record(
                .containerMilestone(
                    phase: .preflighting,
                    generation: 5,
                    attempt: 1,
                    preflightEpoch: 2,
                    ordinal: 1,
                    progressUptime: 3,
                    observedUptime: 3
                )
            ) == .accepted(nil)
        )
        #expect(
            cadence.record(
                .containerMilestone(
                    phase: .preflighting,
                    generation: 4,
                    attempt: 9,
                    preflightEpoch: 1,
                    ordinal: 9,
                    progressUptime: 4,
                    observedUptime: 4
                )
            ) == .ignored
        )

        let next = cadence.record(
            .containerMilestone(
                phase: .preflighting,
                generation: 5,
                attempt: 2,
                preflightEpoch: 2,
                ordinal: 2,
                progressUptime: 16,
                observedUptime: 16.2
            )
        )
        #expect(
            next.emission?.metric
                == .containerMilestone(
                    preflightEpoch: 2,
                    ordinal: 2,
                    deltaMilestones: 2,
                    progressGapMilliseconds: 13_000,
                    lastProgressAgeMilliseconds: 200
                )
        )
    }

    @Test(
        "presented frames reject stale sequence and backward time"
    )
    func presentedFrameGenerationFence() {
        var cadence = AetherBoundedProgressLogCadence(
            minimumIntervalSeconds: 15
        )
        cadence.reset(now: 0)

        let first = cadence.record(
            .presentedFrame(
                phase: .flowing,
                generation: 8,
                attempt: 0,
                frameGeneration: 2,
                frameSequence: 10,
                mediaTimeSeconds: 20,
                progressUptime: 5,
                observedUptime: 5
            )
        )
        #expect(first.acceptedProgress)
        #expect(
            first.emission?.metric
                == .presentedFrame(
                    frameGeneration: 2,
                    frameSequence: 10,
                    fromMediaTimeSeconds: 20,
                    toMediaTimeSeconds: 20,
                    deltaMediaTimeSeconds: 0,
                    wallRateMediaPerSecond: 0,
                    progressGapMilliseconds: 5_000,
                    lastProgressAgeMilliseconds: 0
                )
        )

        #expect(
            cadence.record(
                .presentedFrame(
                    phase: .flowing,
                    generation: 8,
                    attempt: 0,
                    frameGeneration: 2,
                    frameSequence: 10,
                    mediaTimeSeconds: 21,
                    progressUptime: 6,
                    observedUptime: 6
                )
            ) == .ignored
        )
        #expect(
            cadence.record(
                .presentedFrame(
                    phase: .flowing,
                    generation: 8,
                    attempt: 0,
                    frameGeneration: 2,
                    frameSequence: 11,
                    mediaTimeSeconds: 19,
                    progressUptime: 7,
                    observedUptime: 7
                )
            ) == .ignored
        )
        #expect(
            cadence.record(
                .presentedFrame(
                    phase: .flowing,
                    generation: 9,
                    attempt: 0,
                    frameGeneration: 3,
                    frameSequence: 11,
                    mediaTimeSeconds: 1,
                    progressUptime: 8,
                    observedUptime: 8
                )
            ) == .accepted(nil)
        )
        #expect(
            cadence.record(
                .presentedFrame(
                    phase: .flowing,
                    generation: 8,
                    attempt: 0,
                    frameGeneration: 2,
                    frameSequence: 99,
                    mediaTimeSeconds: 99,
                    progressUptime: 9,
                    observedUptime: 9
                )
            ) == .ignored
        )

        let later = cadence.record(
            .presentedFrame(
                phase: .flowing,
                generation: 9,
                attempt: 0,
                frameGeneration: 3,
                frameSequence: 12,
                mediaTimeSeconds: 9,
                progressUptime: 20,
                observedUptime: 20
            )
        )
        #expect(later.acceptedProgress)
        #expect(
            later.emission?.metric
                == .presentedFrame(
                    frameGeneration: 3,
                    frameSequence: 12,
                    fromMediaTimeSeconds: 9,
                    toMediaTimeSeconds: 9,
                    deltaMediaTimeSeconds: 0,
                    wallRateMediaPerSecond: 0,
                    progressGapMilliseconds: 12_000,
                    lastProgressAgeMilliseconds: 0
                )
        )
    }

    @Test(
        "loaded-range progress is monotonic inside its route generation"
    )
    func loadedRangeGenerationFence() {
        var cadence = AetherBoundedProgressLogCadence()
        cadence.reset(now: 0)
        #expect(
            cadence.record(
                .loadedRange(
                    phase: .buffering,
                    generation: 4,
                    attempt: 0,
                    fromSeconds: 0,
                    toSeconds: 5,
                    progressUptime: 1,
                    observedUptime: 1
                )
            ).acceptedProgress
        )
        #expect(
            cadence.record(
                .loadedRange(
                    phase: .buffering,
                    generation: 4,
                    attempt: 0,
                    fromSeconds: 0,
                    toSeconds: 4,
                    progressUptime: 2,
                    observedUptime: 2
                )
            ) == .ignored
        )
        #expect(
            cadence.record(
                .loadedRange(
                    phase: .buffering,
                    generation: 5,
                    attempt: 0,
                    fromSeconds: 0,
                    toSeconds: 1,
                    progressUptime: 3,
                    observedUptime: 3
                )
            ).acceptedProgress
        )
    }

    @Test(
        "classifier prefix and AVIO ranges share one unique-byte ledger"
    )
    func classifierPrefixAndAVIOShareOneLedger() throws {
        let ledger = AetherFetchedByteProgressLedger()
        let prefix = try #require(
            ledger.record(
                offset: 0,
                count: 65_536,
                kind: .origin
            )
        )
        #expect(prefix.totalAdvancedBytes == 65_536)
        #expect(
            ledger.record(
                offset: 0,
                count: 65_536,
                kind: .origin
            ) == nil
        )
        #expect(
            ledger.record(
                offset: 0,
                count: 4_096,
                kind: .origin
            ) == nil
        )

        var cadence = AetherBoundedProgressLogCadence(
            minimumIntervalSeconds: 0.5
        )
        cadence.reset(now: 0)
        #expect(
            cadence.record(
                .sourceBytes(
                    phase: .classifying,
                    generation: 1,
                    attempt: 1,
                    uniqueBytes:
                        prefix.totalAdvancedBytes,
                    progressUptime: 1,
                    observedUptime: 1
                )
            ).emission?.metric
                == .sourceBytes(
                    uniqueBytes: 65_536,
                    deltaBytes: 65_536,
                    wallRateBytesPerSecond: 65_536,
                    progressGapMilliseconds: 1_000,
                    lastProgressAgeMilliseconds: 0
                )
        )

        let disjoint = try #require(
            ledger.record(
                offset: 65_536,
                count: 4_096,
                kind: .origin
            )
        )
        #expect(disjoint.totalAdvancedBytes == 69_632)
        #expect(
            cadence.record(
                .sourceBytes(
                    phase: .preflighting,
                    generation: 2,
                    attempt: 1,
                    uniqueBytes:
                        disjoint.totalAdvancedBytes,
                    progressUptime: 2,
                    observedUptime: 2
                )
            ).emission?.metric
                == .sourceBytes(
                    uniqueBytes: 69_632,
                    deltaBytes: 4_096,
                    wallRateBytesPerSecond: 4_096,
                    progressGapMilliseconds: 1_000,
                    lastProgressAgeMilliseconds: 0
                )
        )
    }

    @Test(
        "classifier retry reader generations fence delayed callbacks"
    )
    func classificationReaderGenerationFence() {
        var fence = AetherClassificationProgressFence()
        #expect(fence.beginEpoch() == 1)

        let firstReader = fence.beginReader()
        #expect(fence.admits(firstReader))

        let retryReader = fence.beginReader()
        #expect(fence.admits(firstReader) == false)
        #expect(fence.admits(retryReader))

        fence.retire(firstReader)
        #expect(fence.admits(retryReader))

        fence.retire(retryReader)
        #expect(fence.admits(retryReader) == false)

        let finalReader = fence.beginReader()
        #expect(fence.admits(finalReader))

        #expect(fence.beginEpoch() == 2)
        #expect(fence.admits(retryReader) == false)
        #expect(fence.admits(finalReader) == false)

        let nextEpochReader = fence.beginReader()
        #expect(fence.admits(nextEpochReader))
        #expect(nextEpochReader.epoch == 2)
        #expect(nextEpochReader.readerGeneration == 1)

        let relay = AetherClassificationProgressRelay()
        relay.record(4)
        relay.record(2)
        relay.record(8)
        #expect(relay.snapshot == 8)
    }

    @Test(
        "route preparation ordinals are generation fenced and bounded"
    )
    func routePreparationMilestonesAreBounded() {
        var cadence = AetherBoundedProgressLogCadence(
            minimumIntervalSeconds: 15
        )
        cadence.reset(now: 0)

        let first = cadence.record(
            .routePreparationMilestone(
                phase: .preparingRoute,
                generation: 4,
                attempt: 1,
                ordinal: 1,
                progressUptime: 1,
                observedUptime: 1
            )
        )
        #expect(
            first.emission?.metric
                == .routePreparationMilestone(
                    ordinal: 1,
                    deltaMilestones: 1,
                    progressGapMilliseconds: 1_000,
                    lastProgressAgeMilliseconds: 0
                )
        )
        #expect(
            cadence.record(
                .routePreparationMilestone(
                    phase: .preparingRoute,
                    generation: 4,
                    attempt: 1,
                    ordinal: 1,
                    progressUptime: 2,
                    observedUptime: 2
                )
            ) == .ignored
        )
        #expect(
            cadence.record(
                .routePreparationMilestone(
                    phase: .preparingRoute,
                    generation: 5,
                    attempt: 2,
                    ordinal: 1,
                    progressUptime: 3,
                    observedUptime: 3
                )
            ) == .accepted(nil)
        )
        #expect(
            cadence.record(
                .routePreparationMilestone(
                    phase: .preparingRoute,
                    generation: 4,
                    attempt: 99,
                    ordinal: 99,
                    progressUptime: 4,
                    observedUptime: 4
                )
            ) == .ignored
        )

        let later = cadence.record(
            .routePreparationMilestone(
                phase: .preparingRoute,
                generation: 5,
                attempt: 2,
                ordinal: 10,
                progressUptime: 16,
                observedUptime: 16.25
            )
        )
        #expect(
            later.emission?.metric
                == .routePreparationMilestone(
                    ordinal: 10,
                    deltaMilestones: 10,
                    progressGapMilliseconds: 13_000,
                    lastProgressAgeMilliseconds: 250
                )
        )
        #expect(
            later.emission?.logFields
                .contains(
                    "progress_kind=route_preparation_milestone"
                ) == true
        )
    }

    @Test(
        "structured output is POSIX numeric and privacy safe"
    )
    func structuredFieldsAreStableAndPrivacySafe() {
        var cadence = AetherBoundedProgressLogCadence()
        cadence.reset(now: -10)
        let emission = cadence.record(
            .sourceBytes(
                phase: .preflighting,
                generation: 2,
                attempt: 3,
                uniqueBytes: 1_024,
                progressUptime: 1,
                observedUptime: 1
            )
        ).emission
        #expect(
            emission?.logFields
                == "progress_kind=source_bytes "
                    + "phase=preflighting generation=2 attempt=3 "
                    + "unique_bytes=1024 delta_bytes=1024 "
                    + "wall_rate_bps=1024 "
                    + "progress_gap_ms=1000 "
                    + "last_progress_age_ms=0"
        )
        #expect(emission?.logFields.contains("http") == false)
        #expect(emission?.logFields.contains("token") == false)
        #expect(emission?.logFields.contains("signature") == false)
        #expect(emission?.logFields.contains("header") == false)
    }
}
