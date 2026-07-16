import CoreMedia
import Foundation
import Libavformat
import Libavutil

struct HLSVODAudioStreamContract: Sendable, Equatable {
    let codecID: UInt32
    let codecTag: UInt32
    let profile: Int32
    let sampleRate: Int32
    let frameSize: Int32
    let channelCount: Int32
    let channelLayoutDescription: String
    let sampleFormat: Int32
    let bitsPerCodedSample: Int32
    let bitsPerRawSample: Int32
    let blockAlign: Int32
    let timeBaseNumerator: Int32
    let timeBaseDenominator: Int32
    let codecConfiguration: Data

    init(stream: UnsafeMutablePointer<AVStream>) {
        let parameters = stream.pointee.codecpar.pointee
        codecID = parameters.codec_id.rawValue
        codecTag = parameters.codec_tag
        profile = parameters.profile
        sampleRate = parameters.sample_rate
        frameSize = parameters.frame_size
        channelCount = parameters.ch_layout.nb_channels
        var channelLayout = parameters.ch_layout
        var channelLayoutBuffer = [CChar](
            repeating: 0,
            count: 256
        )
        channelLayoutDescription =
            channelLayoutBuffer.withUnsafeMutableBufferPointer {
                buffer in
                _ = av_channel_layout_describe(
                    &channelLayout,
                    buffer.baseAddress,
                    buffer.count
                )
                return String(cString: buffer.baseAddress!)
            }
        sampleFormat = parameters.format
        bitsPerCodedSample = parameters.bits_per_coded_sample
        bitsPerRawSample = parameters.bits_per_raw_sample
        blockAlign = parameters.block_align
        timeBaseNumerator = stream.pointee.time_base.num
        timeBaseDenominator = stream.pointee.time_base.den
        if let bytes = parameters.extradata,
           parameters.extradata_size > 0 {
            codecConfiguration = Data(
                bytes: bytes,
                count: Int(parameters.extradata_size)
            )
        } else {
            codecConfiguration = Data()
        }
    }
}

enum HLSVODAudioAnalysisInputError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case metadataContractCountMismatch(
        metadata: Int,
        contracts: Int
    )
    case renditionCountMismatch(
        metadata: Int,
        renditions: Int
    )
    case duplicateTrackID(Int)
    case durationOverflow(segmentIndex: Int)

    var errorDescription: String? {
        switch self {
        case .metadataContractCountMismatch(
            let metadata,
            let contracts
        ):
            "HLS audio-analysis metadata count \(metadata) does not match contract count \(contracts)"
        case .renditionCountMismatch(
            let metadata,
            let renditions
        ):
            "HLS audio-analysis metadata count \(metadata) does not match rendition count \(renditions)"
        case .duplicateTrackID(let trackID):
            "HLS audio-analysis track ID \(trackID) is duplicated"
        case .durationOverflow(let segmentIndex):
            "HLS audio-analysis segment \(segmentIndex) exceeds the source timeline"
        }
    }
}

enum HLSVODAudioAnalysisTrackLayout: Sendable, Equatable {
    case separateRendition(ordinal: Int)
    /// Logical ordinal inside the selected variant's admitted audio-stream ordering.
    ///
    /// FFmpeg stream indices are container-local and may change between finite HLS segments. The
    /// public `sourceTrackID` remains the stable session track identifier from the admitted first
    /// segment; later segments are bound by ordinal plus the immutable codec/extradata contract.
    case muxedVideo(audioOrdinal: Int)
}

struct HLSVODAudioAnalysisSegment: Sendable, Equatable {
    let index: Int
    let resourceKey: HLSVODOriginResourceKey
    let startTime: CMTime
    let duration: CMTime
}

struct HLSVODAudioAnalysisTrack: Sendable, Equatable {
    let sourceTrackID: Int
    let layout: HLSVODAudioAnalysisTrackLayout
    let contract: HLSVODAudioStreamContract
    let initResourceKey: HLSVODOriginResourceKey?
    let segments: [HLSVODAudioAnalysisSegment]
}

/// Immutable analysis binding over the exact HLS graph admitted by preflight.
///
/// Every analysis cursor owns fresh demux/decoder state, while all cursors and playback share the
/// session-scoped origin loader. No arbitrary URL can be opened and no resource is fetched until the
/// consumer requests the first `AudioAnalysisStream` element.
struct HLSVODAudioAnalysisInput: Sendable {
    let loader: HLSVODOriginResourceLoader
    let tracks: [Int: HLSVODAudioAnalysisTrack]
    let duration: CMTime

    init(
        graph: HLSVODResourceGraph,
        loader: HLSVODOriginResourceLoader,
        metadata: [BlackCarrierAudioRenditionMetadata],
        contracts: [HLSVODAudioStreamContract]
    ) throws {
        guard metadata.count == contracts.count else {
            throw HLSVODAudioAnalysisInputError
                .metadataContractCountMismatch(
                    metadata: metadata.count,
                    contracts: contracts.count
                )
        }

        let usesSeparateAudio = !graph.audioRenditions.isEmpty
        if usesSeparateAudio {
            guard metadata.count == graph.audioRenditions.count else {
                throw HLSVODAudioAnalysisInputError
                    .renditionCountMismatch(
                        metadata: metadata.count,
                        renditions: graph.audioRenditions.count
                    )
            }
        }

        var resolved: [Int: HLSVODAudioAnalysisTrack] = [:]
        for (ordinal, item) in metadata.enumerated() {
            guard resolved[item.sourceTrackID] == nil else {
                throw HLSVODAudioAnalysisInputError
                    .duplicateTrackID(item.sourceTrackID)
            }

            let layout: HLSVODAudioAnalysisTrackLayout
            let initResourceKey: HLSVODOriginResourceKey?
            let resources: [HLSVODSegmentResource]
            let resourceKey: (Int) -> HLSVODOriginResourceKey
            if usesSeparateAudio {
                let rendition = graph.audioRenditions[ordinal]
                layout = .separateRendition(
                    ordinal: rendition.ordinal
                )
                initResourceKey = rendition.initSegmentURL == nil
                    ? nil
                    : .audioInit(renditionOrdinal: rendition.ordinal)
                resources = rendition.segments
                resourceKey = {
                    .audioSegment(
                        renditionOrdinal: rendition.ordinal,
                        index: $0
                    )
                }
            } else {
                layout = .muxedVideo(
                    audioOrdinal: ordinal
                )
                initResourceKey = graph.initSegmentURL == nil
                    ? nil
                    : .videoInit
                resources = graph.segments
                resourceKey = { .videoSegment(index: $0) }
            }

            resolved[item.sourceTrackID] =
                HLSVODAudioAnalysisTrack(
                    sourceTrackID: item.sourceTrackID,
                    layout: layout,
                    contract: contracts[ordinal],
                    initResourceKey: initResourceKey,
                    segments: try Self.segments(
                        resources,
                        resourceKey: resourceKey
                    )
                )
        }

        self.loader = loader
        tracks = resolved
        duration = graph.timeline.duration
    }

    func track(
        for request: AudioAnalysisRequest
    ) throws -> (
        HLSVODAudioAnalysisTrack,
        [HLSVODAudioAnalysisSegment]
    ) {
        guard let track = tracks[request.audioTrackID] else {
            throw AudioAnalysisError.audioTrackUnavailable(
                request.audioTrackID
            )
        }
        let sourceDuration = duration.seconds
        guard sourceDuration.isFinite,
              request.range.lowerBound < sourceDuration,
              request.range.upperBound <= sourceDuration else {
            throw AudioAnalysisError.rangeOutsideSource
        }
        let selected = track.segments.filter { segment in
            let start = segment.startTime.seconds
            let end = start + segment.duration.seconds
            return end > request.range.lowerBound
                && start < request.range.upperBound
        }
        guard !selected.isEmpty else {
            throw AudioAnalysisError.rangeOutsideSource
        }
        return (track, selected)
    }

    func loaderSnapshot() async
        -> HLSVODOriginResourceLoaderSnapshot
    {
        await loader.snapshot
    }

    private static func segments(
        _ resources: [HLSVODSegmentResource],
        resourceKey: (Int) -> HLSVODOriginResourceKey
    ) throws -> [HLSVODAudioAnalysisSegment] {
        var startValue: CMTimeValue = 0
        return try resources.map { resource in
            let segment = HLSVODAudioAnalysisSegment(
                index: resource.index,
                resourceKey: resourceKey(resource.index),
                startTime: CMTime(
                    value: startValue,
                    timescale:
                        BlackCarrierProfile.approved.timescale
                ),
                duration: resource.duration
            )
            let addition = startValue.addingReportingOverflow(
                resource.duration.value
            )
            guard !addition.overflow else {
                throw HLSVODAudioAnalysisInputError
                    .durationOverflow(
                        segmentIndex: resource.index
                    )
            }
            startValue = addition.partialValue
            return segment
        }
    }
}
