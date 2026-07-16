import CoreMedia
import Foundation

enum HybridSeekIntent: Sendable, Equatable {
    case advance(
        segmentIndex: Int,
        generation: UInt64
    )
    case prefetch(
        segmentIndex: Int,
        generation: UInt64
    )
    case userSeek(
        target: CMTime,
        segmentIndex: Int,
        generation: UInt64
    )
}

enum HybridSeekIntentClassifierError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case invalidSegmentIndex(index: Int)
    case invalidPlayhead
    case invalidSeekTarget
    case generationOverflow

    var errorDescription: String? {
        switch self {
        case .invalidSegmentIndex(let index):
            return "Hybrid carrier segment request \(index) is out of range"
        case .invalidPlayhead:
            return "Hybrid carrier segment classification requires a valid VOD playhead"
        case .invalidSeekTarget:
            return "Hybrid carrier seek requires a valid VOD target"
        case .generationOverflow:
            return "Hybrid carrier seek generation overflowed"
        }
    }
}

/// Sole classifier for hybrid carrier transport demand and user seek generations.
///
/// HLS request order is not a seek signal. Even a far-ahead segment request remains a prefetch in
/// the current generation. Only an explicit host seek callback or a player-clock observer that has
/// already identified a time jump may call a `register...Seek` entry point and create a generation.
struct HybridSeekIntentClassifier: Sendable {
    let timeline: BlackCarrierTimeline
    private(set) var generation: UInt64

    init(
        timeline: BlackCarrierTimeline,
        initialGeneration: UInt64 = 0
    ) {
        self.timeline = timeline
        generation = initialGeneration
    }

    func classifySegmentRequest(
        index: Int,
        playhead: CMTime
    ) throws -> HybridSeekIntent {
        guard timeline.segments.indices.contains(index) else {
            throw HybridSeekIntentClassifierError
                .invalidSegmentIndex(index: index)
        }
        guard let playheadSegment = timeline.segmentIndex(
            containing: playhead
        ) else {
            throw HybridSeekIntentClassifierError.invalidPlayhead
        }
        if index <= playheadSegment {
            return .advance(
                segmentIndex: index,
                generation: generation
            )
        }
        return .prefetch(
            segmentIndex: index,
            generation: generation
        )
    }

    mutating func registerExplicitHostSeek(
        to target: CMTime
    ) throws -> HybridSeekIntent {
        try registerUserSeek(to: target)
    }

    mutating func registerPlayerTimeJump(
        to target: CMTime
    ) throws -> HybridSeekIntent {
        try registerUserSeek(to: target)
    }

    private mutating func registerUserSeek(
        to target: CMTime
    ) throws -> HybridSeekIntent {
        guard let segmentIndex = timeline.segmentIndex(
            containing: target
        ) else {
            throw HybridSeekIntentClassifierError.invalidSeekTarget
        }
        guard generation < UInt64.max else {
            throw HybridSeekIntentClassifierError.generationOverflow
        }
        generation += 1
        return .userSeek(
            target: target,
            segmentIndex: segmentIndex,
            generation: generation
        )
    }
}

extension BlackCarrierTimeline {
    func segmentIndex(containing time: CMTime) -> Int? {
        guard time.isValid,
              time.isNumeric,
              time >= .zero,
              time <= duration,
              let lastIndex = segments.indices.last else {
            return nil
        }
        if time == duration {
            return lastIndex
        }
        let converted = CMTimeConvertScale(
            time,
            timescale: BlackCarrierProfile.approved.timescale,
            method: .roundTowardZero
        )
        guard converted.isValid,
              converted.isNumeric,
              converted.value >= 0 else {
            return nil
        }
        return segments.firstIndex { segment in
            let start = segment.startTime.value
            let end = start + segment.duration.value
            return converted.value >= start && converted.value < end
        }
    }
}
