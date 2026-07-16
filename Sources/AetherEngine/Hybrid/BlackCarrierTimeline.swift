import CoreMedia
import Foundation

/// Locked video profile for the AVKit black carrier.
///
/// The encoded sample payload is supplied separately. This type owns the public timing and
/// signaling contract so muxing code cannot silently select a different canvas, cadence, or
/// codec profile.
public struct BlackCarrierProfile: Sendable, Equatable {
    public static let approved = BlackCarrierProfile(
        codecSampleEntry: "avc1",
        codecString: "avc1.42C01E",
        width: 640,
        height: 360,
        timescale: 90_000,
        nominalFramesPerSecond: 1,
        nominalFileSegmentDurationTicks: 360_000
    )

    public let codecSampleEntry: String
    public let codecString: String
    public let width: Int
    public let height: Int
    public let timescale: CMTimeScale
    public let nominalFramesPerSecond: Int
    public let nominalFileSegmentDurationTicks: CMTimeValue

    private init(
        codecSampleEntry: String,
        codecString: String,
        width: Int,
        height: Int,
        timescale: CMTimeScale,
        nominalFramesPerSecond: Int,
        nominalFileSegmentDurationTicks: CMTimeValue
    ) {
        self.codecSampleEntry = codecSampleEntry
        self.codecString = codecString
        self.width = width
        self.height = height
        self.timescale = timescale
        self.nominalFramesPerSecond = nominalFramesPerSecond
        self.nominalFileSegmentDurationTicks = nominalFileSegmentDurationTicks
    }

    public var frameDurationTicks: CMTimeValue {
        CMTimeValue(timescale) / CMTimeValue(nominalFramesPerSecond)
    }
}

public enum BlackCarrierTimelineError: Error, LocalizedError, Sendable, Equatable {
    case invalidDuration
    case emptyHLSSegmentPlan
    case invalidHLSSegmentDuration(index: Int)
    case timelineOverflow

    public var errorDescription: String? {
        switch self {
        case .invalidDuration:
            return "Black carrier requires a positive, finite VOD duration"
        case .emptyHLSSegmentPlan:
            return "Black carrier HLS mirroring requires at least one upstream segment"
        case .invalidHLSSegmentDuration(let index):
            return "Black carrier upstream segment \(index) has an invalid duration"
        case .timelineOverflow:
            return "Black carrier timeline exceeds the supported 90 kHz time range"
        }
    }
}

public enum BlackCarrierTimelineSource: Sendable, Equatable {
    case fixedFileVOD
    case mirroredHLSVOD
}

public struct BlackCarrierSampleTiming: Sendable, Equatable {
    public let presentationTime: CMTime
    public let duration: CMTime

    init(presentationTimeTicks: CMTimeValue, durationTicks: CMTimeValue, timescale: CMTimeScale) {
        presentationTime = CMTime(value: presentationTimeTicks, timescale: timescale)
        duration = CMTime(value: durationTicks, timescale: timescale)
    }
}

public struct BlackCarrierSegmentTiming: Sendable, Equatable {
    public let index: Int
    public let startTime: CMTime
    public let duration: CMTime
    public let samples: [BlackCarrierSampleTiming]

    init(
        index: Int,
        startTimeTicks: CMTimeValue,
        durationTicks: CMTimeValue,
        samples: [BlackCarrierSampleTiming],
        timescale: CMTimeScale
    ) {
        self.index = index
        startTime = CMTime(value: startTimeTicks, timescale: timescale)
        duration = CMTime(value: durationTicks, timescale: timescale)
        self.samples = samples
    }
}

/// Exact segment/sample timeline for the pre-encoded black IDR payload.
///
/// Every segment starts with an IDR sample at its own boundary. Samples are nominally one
/// second long; the final sample of a segment is clipped to the exact segment remainder.
/// This is required both for an exact VOD end point and for mirroring fractional upstream
/// HLS boundaries.
public struct BlackCarrierTimeline: Sendable, Equatable {
    public let source: BlackCarrierTimelineSource
    public let duration: CMTime
    public let segments: [BlackCarrierSegmentTiming]

    public static func fileVOD(duration: CMTime) throws -> BlackCarrierTimeline {
        let profile = BlackCarrierProfile.approved
        let durationTicks = try validatedTicks(duration, error: .invalidDuration)
        var segmentDurations: [CMTimeValue] = []
        var remaining = durationTicks
        while remaining > 0 {
            let segmentDuration = min(profile.nominalFileSegmentDurationTicks, remaining)
            segmentDurations.append(segmentDuration)
            remaining -= segmentDuration
        }
        return try make(source: .fixedFileVOD, segmentDurationTicks: segmentDurations)
    }

    public static func mirroredHLSVOD(segmentDurations: [CMTime]) throws -> BlackCarrierTimeline {
        guard !segmentDurations.isEmpty else {
            throw BlackCarrierTimelineError.emptyHLSSegmentPlan
        }
        let ticks = try segmentDurations.enumerated().map { index, duration in
            try validatedTicks(duration, error: .invalidHLSSegmentDuration(index: index))
        }
        return try make(source: .mirroredHLSVOD, segmentDurationTicks: ticks)
    }

    private static func validatedTicks(
        _ duration: CMTime,
        error: BlackCarrierTimelineError
    ) throws -> CMTimeValue {
        guard duration.isValid,
              duration.isNumeric,
              duration > .zero else {
            throw error
        }
        let converted = CMTimeConvertScale(
            duration,
            timescale: BlackCarrierProfile.approved.timescale,
            method: .roundHalfAwayFromZero
        )
        guard converted.isValid,
              converted.isNumeric,
              converted.value > 0 else {
            throw error
        }
        return converted.value
    }

    private static func make(
        source: BlackCarrierTimelineSource,
        segmentDurationTicks: [CMTimeValue]
    ) throws -> BlackCarrierTimeline {
        let profile = BlackCarrierProfile.approved
        var startTicks: CMTimeValue = 0
        var segments: [BlackCarrierSegmentTiming] = []
        segments.reserveCapacity(segmentDurationTicks.count)

        for (index, segmentTicks) in segmentDurationTicks.enumerated() {
            var samples: [BlackCarrierSampleTiming] = []
            var localTicks: CMTimeValue = 0
            while localTicks < segmentTicks {
                let sampleTicks = min(profile.frameDurationTicks, segmentTicks - localTicks)
                let (presentationTicks, presentationOverflow) = startTicks.addingReportingOverflow(localTicks)
                guard !presentationOverflow else {
                    throw BlackCarrierTimelineError.timelineOverflow
                }
                samples.append(
                    BlackCarrierSampleTiming(
                        presentationTimeTicks: presentationTicks,
                        durationTicks: sampleTicks,
                        timescale: profile.timescale
                    )
                )
                localTicks += sampleTicks
            }

            segments.append(
                BlackCarrierSegmentTiming(
                    index: index,
                    startTimeTicks: startTicks,
                    durationTicks: segmentTicks,
                    samples: samples,
                    timescale: profile.timescale
                )
            )
            let (nextStart, overflow) = startTicks.addingReportingOverflow(segmentTicks)
            guard !overflow else {
                throw BlackCarrierTimelineError.timelineOverflow
            }
            startTicks = nextStart
        }

        return BlackCarrierTimeline(
            source: source,
            duration: CMTime(value: startTicks, timescale: profile.timescale),
            segments: segments
        )
    }
}
