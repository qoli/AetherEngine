import CoreMedia
import Testing
@testable import AetherEngine

@Suite("Black carrier timeline")
struct BlackCarrierTimelineTests {
    @Test("Approved profile stays locked")
    func approvedProfile() {
        let profile = BlackCarrierProfile.approved
        #expect(profile.codecSampleEntry == "avc1")
        #expect(profile.codecString == "avc1.42C01E")
        #expect(profile.width == 640)
        #expect(profile.height == 360)
        #expect(profile.timescale == 90_000)
        #expect(profile.nominalFramesPerSecond == 1)
        #expect(profile.frameDurationTicks == 90_000)
        #expect(profile.nominalFileSegmentDurationTicks == 360_000)
    }

    @Test("File VOD uses four-second segments and an exact tail")
    func fileVODPlan() throws {
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(seconds: 10.25, preferredTimescale: 90_000)
        )

        #expect(timeline.source == .fixedFileVOD)
        #expect(timeline.duration.value == 922_500)
        #expect(timeline.segments.map(\.duration.value) == [360_000, 360_000, 202_500])
        #expect(timeline.segments.map(\.startTime.value) == [0, 360_000, 720_000])
        #expect(timeline.segments[2].samples.map(\.presentationTime.value) == [720_000, 810_000, 900_000])
        #expect(timeline.segments[2].samples.map(\.duration.value) == [90_000, 90_000, 22_500])
    }

    @Test("HLS plan mirrors every fractional upstream boundary")
    func mirroredHLSPlan() throws {
        let timeline = try BlackCarrierTimeline.mirroredHLSVOD(segmentDurations: [
            CMTime(seconds: 3.5, preferredTimescale: 90_000),
            CMTime(seconds: 6.006, preferredTimescale: 90_000),
        ])

        #expect(timeline.source == .mirroredHLSVOD)
        #expect(timeline.segments.map(\.startTime.value) == [0, 315_000])
        #expect(timeline.segments.map(\.duration.value) == [315_000, 540_540])
        #expect(timeline.duration.value == 855_540)
        #expect(timeline.segments[0].samples.map(\.duration.value) == [90_000, 90_000, 90_000, 45_000])
        #expect(timeline.segments[1].samples.first?.presentationTime.value == 315_000)
        #expect(timeline.segments[1].samples.last?.duration.value == 540)
    }

    @Test("Every segment begins at its exact boundary")
    func segmentBeginsWithSample() throws {
        let timeline = try BlackCarrierTimeline.mirroredHLSVOD(segmentDurations: [
            CMTime(value: 90_001, timescale: 90_000),
            CMTime(value: 179_999, timescale: 90_000),
            CMTime(value: 45_000, timescale: 90_000),
        ])

        for segment in timeline.segments {
            #expect(segment.samples.first?.presentationTime == segment.startTime)
            #expect(segment.samples.allSatisfy { $0.duration > .zero })
            #expect(segment.samples.allSatisfy {
                $0.duration.value <= BlackCarrierProfile.approved.frameDurationTicks
            })
        }
    }

    @Test("Invalid timelines fail explicitly")
    func invalidTimelines() {
        #expect(throws: BlackCarrierTimelineError.invalidDuration) {
            try BlackCarrierTimeline.fileVOD(duration: .zero)
        }
        #expect(throws: BlackCarrierTimelineError.invalidDuration) {
            try BlackCarrierTimeline.fileVOD(duration: .invalid)
        }
        #expect(throws: BlackCarrierTimelineError.emptyHLSSegmentPlan) {
            try BlackCarrierTimeline.mirroredHLSVOD(segmentDurations: [])
        }
        #expect(throws: BlackCarrierTimelineError.invalidHLSSegmentDuration(index: 1)) {
            try BlackCarrierTimeline.mirroredHLSVOD(segmentDurations: [
                CMTime(seconds: 4, preferredTimescale: 90_000),
                .zero,
            ])
        }
    }
}
