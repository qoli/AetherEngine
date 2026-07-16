import CoreMedia
import Testing
@testable import AetherEngine

@Suite("Hybrid seek-intent classification")
struct HybridSeekIntentTests {
    @Test("Segment request distance never creates a seek generation")
    func segmentRequestsDoNotInferSeek() throws {
        let timeline = try makeTimeline()
        let classifier = HybridSeekIntentClassifier(
            timeline: timeline,
            initialGeneration: 41
        )

        #expect(try classifier.classifySegmentRequest(
            index: 0,
            playhead: seconds(0.25)
        ) == .advance(segmentIndex: 0, generation: 41))
        #expect(try classifier.classifySegmentRequest(
            index: 2,
            playhead: seconds(0.25)
        ) == .prefetch(segmentIndex: 2, generation: 41))
        #expect(try classifier.classifySegmentRequest(
            index: 0,
            playhead: seconds(8.25)
        ) == .advance(segmentIndex: 0, generation: 41))
        #expect(classifier.generation == 41)
    }

    @Test("Only explicit host seek or an observed player-time jump advances generation")
    func userSeekSourcesAdvanceGeneration() throws {
        let timeline = try makeTimeline()
        var classifier = HybridSeekIntentClassifier(
            timeline: timeline,
            initialGeneration: 7
        )

        #expect(try classifier.registerExplicitHostSeek(
            to: seconds(8.25)
        ) == .userSeek(
            target: seconds(8.25),
            segmentIndex: 2,
            generation: 8
        ))
        #expect(try classifier.registerPlayerTimeJump(
            to: timeline.duration
        ) == .userSeek(
            target: timeline.duration,
            segmentIndex: 3,
            generation: 9
        ))
        #expect(classifier.generation == 9)
    }

    @Test("Invalid demand and generation overflow are typed")
    func invalidInput() throws {
        let timeline = try makeTimeline()
        var classifier = HybridSeekIntentClassifier(
            timeline: timeline,
            initialGeneration: UInt64.max
        )

        #expect(throws: HybridSeekIntentClassifierError
            .invalidSegmentIndex(index: 4)) {
            try classifier.classifySegmentRequest(
                index: 4,
                playhead: .zero
            )
        }
        #expect(throws: HybridSeekIntentClassifierError.invalidPlayhead) {
            try classifier.classifySegmentRequest(
                index: 0,
                playhead: seconds(-1)
            )
        }
        #expect(throws: HybridSeekIntentClassifierError.invalidSeekTarget) {
            try classifier.registerExplicitHostSeek(
                to: seconds(13)
            )
        }
        #expect(throws: HybridSeekIntentClassifierError.generationOverflow) {
            try classifier.registerPlayerTimeJump(
                to: seconds(1)
            )
        }
    }

    private func makeTimeline() throws -> BlackCarrierTimeline {
        try BlackCarrierTimeline.fileVOD(
            duration: seconds(12.25)
        )
    }

    private func seconds(_ value: Double) -> CMTime {
        CMTime(
            seconds: value,
            preferredTimescale: BlackCarrierProfile.approved.timescale
        )
    }
}
