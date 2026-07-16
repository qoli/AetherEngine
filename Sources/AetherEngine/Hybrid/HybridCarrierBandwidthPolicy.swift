import CoreMedia
import Foundation

/// Primary master-playlist policy for Aether's local Hybrid black-carrier transport.
///
/// `BANDWIDTH` is an AVPlayer loopback transport budget. It is deliberately not derived from the
/// upstream asset, a codec declaration or a full-asset carrier measurement. Runtime code must not
/// change this value, transcode audio, select another track or switch playback route when observed
/// carrier bandwidth differs from the budget.
public enum AetherHybridCarrierBandwidthPolicy {
    public static let loopbackTransportBudget = 2_000_000
}

public enum AetherHybridCarrierBandwidthObservationState:
    String,
    Sendable,
    Equatable
{
    case awaitingCarrierSegments
    case partial
    case complete
    case unavailable
}

/// Privacy-safe observation of bytes already emitted by the local carrier.
///
/// These values are diagnostics only. They never participate in preflight, provider construction,
/// audio route selection or runtime recovery. No URL, path, track identity or codec string is exposed.
public struct AetherHybridCarrierBandwidthTelemetry:
    Sendable,
    Equatable
{
    public let declaredTransportBudget: Int
    public let observedPeakBandwidth: Int?
    public let observedAverageBandwidth: Int?
    public let observedSegmentCount: Int
    public let audioRenditionCount: Int
    public let state:
        AetherHybridCarrierBandwidthObservationState

    init(
        observedPeakBandwidth: Int?,
        observedAverageBandwidth: Int?,
        observedSegmentCount: Int,
        audioRenditionCount: Int,
        state: AetherHybridCarrierBandwidthObservationState
    ) {
        declaredTransportBudget =
            AetherHybridCarrierBandwidthPolicy
                .loopbackTransportBudget
        self.observedPeakBandwidth =
            observedPeakBandwidth
        self.observedAverageBandwidth =
            observedAverageBandwidth
        self.observedSegmentCount =
            observedSegmentCount
        self.audioRenditionCount =
            audioRenditionCount
        self.state = state
    }

    static func awaiting(
        audioRenditionCount: Int
    ) -> Self {
        Self(
            observedPeakBandwidth: nil,
            observedAverageBandwidth: nil,
            observedSegmentCount: 0,
            audioRenditionCount:
                audioRenditionCount,
            state: .awaitingCarrierSegments
        )
    }

    static func unavailable(
        audioRenditionCount: Int
    ) -> Self {
        Self(
            observedPeakBandwidth: nil,
            observedAverageBandwidth: nil,
            observedSegmentCount: 0,
            audioRenditionCount:
                audioRenditionCount,
            state: .unavailable
        )
    }
}

struct BlackCarrierBandwidthSegmentSample:
    Sendable,
    Equatable
{
    let segmentIndex: Int
    let byteCount: Int
}

enum BlackCarrierBandwidthTelemetryCalculator {
    static func calculate(
        timeline: BlackCarrierTimeline,
        videoSamples: [BlackCarrierBandwidthSegmentSample],
        audioSamples:
            [[BlackCarrierBandwidthSegmentSample]]
    ) -> AetherHybridCarrierBandwidthTelemetry {
        let audioRenditionCount = audioSamples.count
        guard !timeline.segments.isEmpty else {
            return .unavailable(
                audioRenditionCount:
                    audioRenditionCount
            )
        }
        let validIndices = Set(
            timeline.segments.map(\.index)
        )
        guard let videoByIndex = validatedMap(
            videoSamples,
            validIndices: validIndices
        ) else {
            return .unavailable(
                audioRenditionCount:
                    audioRenditionCount
            )
        }

        if audioSamples.isEmpty {
            return calculateVideoOnly(
                timeline: timeline,
                videoByIndex: videoByIndex
            )
        }

        var observedPeak = 0
        var observedAverage = 0
        var minimumObservedCount = Int.max
        var allRenditionsComplete = true

        for rendition in audioSamples {
            guard let audioByIndex = validatedMap(
                rendition,
                validIndices: validIndices
            ) else {
                return .unavailable(
                    audioRenditionCount:
                        audioRenditionCount
                )
            }
            guard let result = calculateCombination(
                timeline: timeline,
                videoByIndex: videoByIndex,
                audioByIndex: audioByIndex,
                requiresAudio: true
            ) else {
                return .unavailable(
                    audioRenditionCount:
                        audioRenditionCount
                )
            }
            guard result.segmentCount > 0 else {
                return .awaiting(
                    audioRenditionCount:
                        audioRenditionCount
                )
            }
            observedPeak = max(
                observedPeak,
                result.peakBandwidth
            )
            observedAverage = max(
                observedAverage,
                result.averageBandwidth
            )
            minimumObservedCount = min(
                minimumObservedCount,
                result.segmentCount
            )
            allRenditionsComplete =
                allRenditionsComplete
                && result.segmentCount
                    == timeline.segments.count
        }

        return AetherHybridCarrierBandwidthTelemetry(
            observedPeakBandwidth: observedPeak,
            observedAverageBandwidth:
                observedAverage,
            observedSegmentCount:
                minimumObservedCount,
            audioRenditionCount:
                audioRenditionCount,
            state: allRenditionsComplete
                ? .complete
                : .partial
        )
    }

    static func fileSamples(
        urls: [(segmentIndex: Int, url: URL)]
    ) throws -> [BlackCarrierBandwidthSegmentSample] {
        try urls.map { item in
            let values = try item.url.resourceValues(
                forKeys: [.fileSizeKey]
            )
            guard let fileSize = values.fileSize,
                  fileSize > 0 else {
                throw CocoaError(
                    .fileReadCorruptFile
                )
            }
            return BlackCarrierBandwidthSegmentSample(
                segmentIndex: item.segmentIndex,
                byteCount: fileSize
            )
        }
    }

    private static func calculateVideoOnly(
        timeline: BlackCarrierTimeline,
        videoByIndex: [Int: Int]
    ) -> AetherHybridCarrierBandwidthTelemetry {
        guard let result = calculateCombination(
            timeline: timeline,
            videoByIndex: videoByIndex,
            audioByIndex: [:],
            requiresAudio: false
        ) else {
            return .unavailable(
                audioRenditionCount: 0
            )
        }
        guard result.segmentCount > 0 else {
            return .awaiting(
                audioRenditionCount: 0
            )
        }
        return AetherHybridCarrierBandwidthTelemetry(
            observedPeakBandwidth:
                result.peakBandwidth,
            observedAverageBandwidth:
                result.averageBandwidth,
            observedSegmentCount:
                result.segmentCount,
            audioRenditionCount: 0,
            state: result.segmentCount
                == timeline.segments.count
                ? .complete
                : .partial
        )
    }

    private static func calculateCombination(
        timeline: BlackCarrierTimeline,
        videoByIndex: [Int: Int],
        audioByIndex: [Int: Int],
        requiresAudio: Bool
    ) -> (
        peakBandwidth: Int,
        averageBandwidth: Int,
        segmentCount: Int
    )? {
        var peakBandwidth = 0
        var totalBytes = 0
        var totalDuration = 0.0
        var segmentCount = 0

        for segment in timeline.segments {
            guard let videoBytes =
                    videoByIndex[segment.index] else {
                continue
            }
            let audioBytes: Int
            if let value =
                        audioByIndex[segment.index] {
                audioBytes = value
            } else if !requiresAudio {
                audioBytes = 0
            } else {
                continue
            }
            let duration = segment.duration.seconds
            guard duration.isFinite,
                  duration > 0 else {
                continue
            }
            let byteCountResult = videoBytes
                .addingReportingOverflow(audioBytes)
            guard !byteCountResult.overflow else {
                return nil
            }
            let byteCount = byteCountResult.partialValue
            peakBandwidth = max(
                peakBandwidth,
                Int(
                    ceil(
                        Double(byteCount) * 8
                            / duration
                    )
                )
            )
            let totalBytesResult = totalBytes
                .addingReportingOverflow(byteCount)
            guard !totalBytesResult.overflow else {
                return nil
            }
            totalBytes = totalBytesResult.partialValue
            totalDuration += duration
            segmentCount += 1
        }

        guard segmentCount > 0,
              totalDuration > 0 else {
            return (0, 0, 0)
        }
        return (
            max(1, peakBandwidth),
            max(
                1,
                Int(
                    ceil(
                        Double(totalBytes) * 8
                            / totalDuration
                    )
                )
            ),
            segmentCount
        )
    }

    private static func validatedMap(
        _ samples: [BlackCarrierBandwidthSegmentSample],
        validIndices: Set<Int>
    ) -> [Int: Int]? {
        var result: [Int: Int] = [:]
        result.reserveCapacity(samples.count)
        for sample in samples {
            guard sample.byteCount > 0,
                  validIndices.contains(
                      sample.segmentIndex
                  ),
                  result[sample.segmentIndex] == nil else {
                return nil
            }
            result[sample.segmentIndex] =
                sample.byteCount
        }
        return result
    }
}

protocol HybridCarrierBandwidthTelemetrySource:
    AnyObject
{
    var carrierBandwidthTelemetry:
        AetherHybridCarrierBandwidthTelemetry { get }
}
