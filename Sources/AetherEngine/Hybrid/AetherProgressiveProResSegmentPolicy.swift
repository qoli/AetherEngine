import CoreMedia
import Foundation

enum AetherProgressiveProResSegmentPolicyError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case durationOutsideTimelineRange
    case segmentCountExceedsCapacity(
        required: Int64,
        maximum: Int
    )

    var errorDescription: String? {
        switch self {
        case .durationOutsideTimelineRange:
            return "Progressive ProRes duration exceeds the carrier timeline range"
        case .segmentCountExceedsCapacity(
            let required,
            let maximum
        ):
            return "Progressive ProRes carrier plan requires \(required) segments; capacity is \(maximum)"
        }
    }
}

/// Chooses a shorter file-VOD carrier segment only from exact, validator-bound
/// progressive ProRes evidence.
///
/// The public `BlackCarrierTimeline.fileVOD(duration:)` contract remains four
/// seconds. This policy is an internal admission refinement for the one route
/// where a four-second compressed-video burst can exceed the Hybrid bootstrap
/// queue while the shared demux pass is still completing PCM segment zero.
struct AetherProgressiveProResSegmentPolicy {
    enum Selection: String, Sendable, Equatable {
        case nominalIneligibleRoute
        case nominalUnboundGeneration
        case nominalInvalidDuration
        case nominalWithinTarget
        case adaptiveHighBitrate
    }

    struct Decision: Sendable, Equatable {
        let selection: Selection
        let segmentDurationTicks: CMTimeValue
        let contentLengthBytes: Int64?
        let durationTicks: CMTimeValue?
        let averageSourceBytesPerSecond: Int64?
        let nominalSegmentBytes: Int64?
        let segmentCount: Int64?

        var isAdaptive: Bool {
            selection == .adaptiveHighBitrate
        }
    }

    /// Keep one adaptive segment below the in-memory compressed-video queue
    /// with headroom for packet metadata and concurrently retained frames.
    static let targetCompressedBytesPerSegment: Int64 =
        64 * 1_024 * 1_024

    /// One carrier frame is the smallest supported file-VOD segment. Going
    /// below this cadence creates fractional-frame segment explosions while
    /// providing no additional carrier readiness signal.
    static let minimumSupportedSegmentDurationTicks: CMTimeValue =
        BlackCarrierProfile.approved.frameDurationTicks

    /// High-bitrate ProRes normally uses one carrier frame per segment. A
    /// longer segment is selected only when needed to keep the materialized
    /// timeline within the explicit count bound below.
    static let maximumAdaptiveSegmentDurationTicks: CMTimeValue =
        BlackCarrierProfile.approved.frameDurationTicks

    /// `BlackCarrierTimeline` and the local HLS playlist materialize one entry
    /// per segment. Keep that work bounded independently of source duration.
    /// At the minimum one-second cadence this permits a full 24-hour source.
    static let maximumMaterializedSegmentCount = 86_400

    static func decide(
        sourceKind: AetherMediaSourceKind,
        route: PlaybackRenderRoute,
        reason: PlaybackRouteReason,
        sourceGeneration: SourceByteStoreGeneration?,
        durationSeconds: Double
    ) throws -> Decision {
        let nominalTicks =
            BlackCarrierProfile.approved
                .nominalFileSegmentDurationTicks

        guard sourceKind == .progressive,
              route == .hybridCarrier,
              reason == .hybridProRes else {
            return nominal(
                selection: .nominalIneligibleRoute
            )
        }
        let durationEvidence = exactDurationTicks(
            durationSeconds
        )
        guard durationEvidence != .outsideTimelineRange else {
            throw AetherProgressiveProResSegmentPolicyError
                .durationOutsideTimelineRange
        }
        guard case .ticks(let durationTicks) =
                durationEvidence else {
            return nominal(
                selection: .nominalInvalidDuration
            )
        }

        let nominalSegmentCount = roundedUpQuotient(
            durationTicks,
            nominalTicks
        )
        guard nominalSegmentCount
                <= Int64(maximumMaterializedSegmentCount) else {
            throw AetherProgressiveProResSegmentPolicyError
                .segmentCountExceedsCapacity(
                    required: nominalSegmentCount,
                    maximum:
                        maximumMaterializedSegmentCount
                )
        }
        guard let sourceGeneration,
              sourceGeneration.validator != nil else {
            return nominal(
                selection: .nominalUnboundGeneration
            )
        }

        let nominalByteDurationProduct =
            sourceGeneration.contentLength
                .multipliedFullWidth(by: nominalTicks)
        let targetDurationProduct =
            targetCompressedBytesPerSegment
                .multipliedFullWidth(by: durationTicks)
        let bytesPerSecondProduct =
            sourceGeneration.contentLength
                .multipliedFullWidth(
                    by: Int64(
                        BlackCarrierProfile.approved.timescale
                    )
                )
        let nominalSegmentBytes =
            roundedUpWideQuotientIfRepresentable(
                nominalByteDurationProduct,
                dividedBy: durationTicks
            )
        let averageSourceBytesPerSecond =
            roundedUpWideQuotientIfRepresentable(
                bytesPerSecondProduct,
                dividedBy: durationTicks
            )

        guard isGreater(
            nominalByteDurationProduct,
            than: targetDurationProduct
        ) else {
            return Decision(
                selection: .nominalWithinTarget,
                segmentDurationTicks: nominalTicks,
                contentLengthBytes:
                    sourceGeneration.contentLength,
                durationTicks: durationTicks,
                averageSourceBytesPerSecond:
                    averageSourceBytesPerSecond,
                nominalSegmentBytes:
                    nominalSegmentBytes,
                segmentCount: nominalSegmentCount
            )
        }

        // The wide ratio is safe even when either 64-bit multiplication would
        // overflow. The high-bitrate guard above proves this quotient is below
        // `nominalTicks`, so `dividingFullWidth` cannot overflow its result.
        let derivedTicks = sourceGeneration.contentLength
            .dividingFullWidth(targetDurationProduct)
            .quotient
        let targetBoundedTicks = min(
            derivedTicks,
            maximumAdaptiveSegmentDurationTicks
        )
        let countBoundedTicks = roundedUpQuotient(
            durationTicks,
            Int64(maximumMaterializedSegmentCount)
        )
        let selectedTicks = max(
            minimumSupportedSegmentDurationTicks,
            max(targetBoundedTicks, countBoundedTicks)
        )
        let selectedSegmentCount = roundedUpQuotient(
            durationTicks,
            selectedTicks
        )
        guard selectedTicks <= nominalTicks,
              selectedSegmentCount
                <= Int64(maximumMaterializedSegmentCount) else {
            throw AetherProgressiveProResSegmentPolicyError
                .segmentCountExceedsCapacity(
                    required: selectedSegmentCount,
                    maximum:
                        maximumMaterializedSegmentCount
                )
        }

        return Decision(
            selection: .adaptiveHighBitrate,
            segmentDurationTicks: selectedTicks,
            contentLengthBytes:
                sourceGeneration.contentLength,
            durationTicks: durationTicks,
            averageSourceBytesPerSecond:
                averageSourceBytesPerSecond,
            nominalSegmentBytes: nominalSegmentBytes,
            segmentCount: selectedSegmentCount
        )
    }

    private static func nominal(
        selection: Selection
    ) -> Decision {
        Decision(
            selection: selection,
            segmentDurationTicks:
                BlackCarrierProfile.approved
                    .nominalFileSegmentDurationTicks,
            contentLengthBytes: nil,
            durationTicks: nil,
            averageSourceBytesPerSecond: nil,
            nominalSegmentBytes: nil,
            segmentCount: nil
        )
    }

    private enum DurationEvidence: Equatable {
        case invalid
        case outsideTimelineRange
        case ticks(Int64)
    }

    private static func exactDurationTicks(
        _ durationSeconds: Double
    ) -> DurationEvidence {
        guard durationSeconds.isFinite,
              durationSeconds > 0 else {
            return .invalid
        }
        let scaled = durationSeconds
            * Double(BlackCarrierProfile.approved.timescale)
        guard scaled.isFinite,
              scaled < Double(Int64.max) else {
            return .outsideTimelineRange
        }
        guard scaled >= 1 else {
            return .outsideTimelineRange
        }
        let ticks = Int64(scaled.rounded())
        return ticks > 0
            ? .ticks(ticks)
            : .outsideTimelineRange
    }

    private static func roundedUpQuotient(
        _ numerator: Int64,
        _ denominator: Int64
    ) -> Int64 {
        let quotient = numerator / denominator
        return numerator % denominator == 0
            ? quotient
            : quotient + 1
    }

    private typealias WideProduct = (
        high: Int64,
        low: UInt64
    )

    private static func isGreater(
        _ lhs: WideProduct,
        than rhs: WideProduct
    ) -> Bool {
        if lhs.high != rhs.high {
            return lhs.high > rhs.high
        }
        return lhs.low > rhs.low
    }

    private static func roundedUpWideQuotientIfRepresentable(
        _ numerator: WideProduct,
        dividedBy denominator: Int64
    ) -> Int64? {
        let maximumRepresentableProduct =
            Int64.max.multipliedFullWidth(by: denominator)
        guard !isGreater(
            numerator,
            than: maximumRepresentableProduct
        ) else {
            return nil
        }
        let division = denominator.dividingFullWidth(
            numerator
        )
        if division.remainder == 0 {
            return division.quotient
        }
        guard division.quotient < Int64.max else {
            return nil
        }
        return division.quotient + 1
    }
}
