import CoreMedia
import Foundation
import Libavcodec
import Libavformat
import Libavutil

enum HLSVODSegmentContainer: String, Sendable, Equatable {
    case fragmentedMP4
    case mpegTransport
    case selfContained
}

enum HLSVODSegmentDemuxError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case invalidPreflight
    case closed
    case videoSegmentOutOfRange(Int)
    case audioRenditionOutOfRange(Int)
    case audioSegmentOutOfRange(
        renditionOrdinal: Int,
        segmentIndex: Int
    )
    case demuxOpenFailed
    case packetReadFailed
    case unresolvedCodec(streamIndex: Int)
    case invalidTimeBase(streamIndex: Int)
    case videoStreamCount(Int)
    case videoCodecMismatch(
        expected: AetherVideoCodec,
        actual: AetherVideoCodec
    )
    case videoPacketMissing(streamIndex: Int)
    case audioRenditionContainsVideo(
        renditionOrdinal: Int
    )
    case audioStreamCount(
        renditionOrdinal: Int,
        count: Int
    )
    case audioPacketMissing(
        renditionOrdinal: Int?,
        streamIndex: Int
    )
    case audioChannelsMismatch(
        renditionOrdinal: Int,
        declared: String,
        admitted: String
    )
    case audioRouteUnsupported(
        renditionOrdinal: Int?,
        reason: String
    )

    var errorDescription: String? {
        switch self {
        case .invalidPreflight:
            "HLS VOD segment demux requires an admitted hybrid HLS preflight"
        case .closed:
            "HLS VOD segment demuxer is closed"
        case .videoSegmentOutOfRange(let index):
            "HLS VOD video segment \(index) is out of range"
        case .audioRenditionOutOfRange(let ordinal):
            "HLS VOD audio rendition \(ordinal) is out of range"
        case .audioSegmentOutOfRange(
            let ordinal,
            let index
        ):
            "HLS VOD audio rendition \(ordinal) segment \(index) is out of range"
        case .demuxOpenFailed:
            "HLS VOD segment could not open in FFmpeg"
        case .packetReadFailed:
            "HLS VOD segment packet read failed"
        case .unresolvedCodec(let streamIndex):
            "HLS VOD stream \(streamIndex) has no resolved codec"
        case .invalidTimeBase(let streamIndex):
            "HLS VOD stream \(streamIndex) has an invalid time base"
        case .videoStreamCount(let count):
            "HLS VOD selected video segment exposed \(count) video streams"
        case .videoCodecMismatch(let expected, let actual):
            "HLS VOD video codec changed from \(expected.rawValue) to \(actual.rawValue)"
        case .videoPacketMissing(let streamIndex):
            "HLS VOD video stream \(streamIndex) produced no packet"
        case .audioRenditionContainsVideo(let ordinal):
            "HLS VOD audio rendition \(ordinal) unexpectedly contains video"
        case .audioStreamCount(let ordinal, let count):
            "HLS VOD audio rendition \(ordinal) exposed \(count) audio streams"
        case .audioPacketMissing(
            let ordinal,
            let streamIndex
        ):
            if let ordinal {
                "HLS VOD audio rendition \(ordinal) stream \(streamIndex) produced no packet"
            } else {
                "HLS VOD selected video segment muxed audio stream \(streamIndex) produced no packet"
            }
        case .audioChannelsMismatch(
            let ordinal,
            let declared,
            let admitted
        ):
            "HLS VOD audio rendition \(ordinal) declared CHANNELS=\(declared) but carrier admission produced \(admitted)"
        case .audioRouteUnsupported(
            let ordinal,
            let reason
        ):
            if let ordinal {
                "HLS VOD audio rendition \(ordinal) is not carrier-compatible: \(reason)"
            } else {
                "HLS VOD selected video segment muxed audio is not carrier-compatible: \(reason)"
            }
        }
    }
}

struct HLSVODAudioStreamAdmission: Sendable, Equatable {
    let track: TrackInfo
    let carrierDescriptor: BlackCarrierAudioRenditionDescriptor
    let packetCount: Int
}

struct HLSVODVideoSegmentAdmission: Sendable, Equatable {
    let segmentIndex: Int
    let mediaSequence: Int
    let duration: CMTime
    let container: HLSVODSegmentContainer
    let videoStreamIndex: Int
    let videoCodec: AetherVideoCodec
    let videoPacketCount: Int
    let muxedAudioStreams: [HLSVODAudioStreamAdmission]
}

struct HLSVODAudioSegmentAdmission: Sendable, Equatable {
    let renditionOrdinal: Int
    let segmentIndex: Int
    let mediaSequence: Int
    let duration: CMTime
    let container: HLSVODSegmentContainer
    let manifestName: String
    let manifestLanguage: String?
    let isDefault: Bool
    let isAutoselect: Bool
    let manifestChannels: String?
    let stream: HLSVODAudioStreamAdmission
}

/// Opens only graph-bound HLS VOD segment bytes in fresh, finite FFmpeg demux contexts.
///
/// This is an admission/probe boundary, not the playback pump. Every separate audio rendition is checked
/// against the exact `BlackCarrierAudioRenditionMuxer` stream-copy/bridge route rather than a codec-name
/// allowlist. Segment bytes remain owned by `HLSVODOriginResourceLoader`; FFmpeg receives an independent
/// in-memory reader and cannot reopen the master playlist, select another variant or perform network I/O.
actor HLSVODSegmentDemuxer {
    private let preflight: AetherHLSPlaybackPreflight
    private let graph: HLSVODResourceGraph
    private let loader: HLSVODOriginResourceLoader
    private let bridgeMode: AudioBridgeMode
    private var isClosed = false

    init(
        preflight: AetherHLSPlaybackPreflight,
        bridgeMode: AudioBridgeMode = .surroundCompat,
        maximumResourceBytes: Int =
            HLSVODOriginResourceLoader.defaultMaximumResourceBytes,
        capacityBytes: Int64 =
            HLSVODOriginResourceLoader.defaultCapacityBytes,
        baseDirectory: URL =
            FileManager.default.temporaryDirectory,
        fetchOverride:
            HLSVODOriginResourceLoader.Fetch? = nil
    ) throws {
        guard preflight.result.route == .hybridCarrierMetal,
              preflight.result.sourceProfile.sourceKind == .hls,
              let graph = preflight.resourceGraph else {
            throw HLSVODSegmentDemuxError.invalidPreflight
        }
        self.preflight = preflight
        self.graph = graph
        self.bridgeMode = bridgeMode
        loader = try HLSVODOriginResourceLoader(
            graph: graph,
            httpHeaders: preflight.httpHeaders,
            maximumResourceBytes: maximumResourceBytes,
            capacityBytes: capacityBytes,
            baseDirectory: baseDirectory,
            fetchOverride: fetchOverride
        )
    }

    func inspectVideoSegment(
        at index: Int
    ) async throws -> HLSVODVideoSegmentAdmission {
        try requireOpen()
        guard graph.segments.indices.contains(index) else {
            throw HLSVODSegmentDemuxError
                .videoSegmentOutOfRange(index)
        }
        let initData: Data?
        if graph.initSegmentURL != nil {
            initData = try await loader.payload(
                for: .videoInit
            ).data
        } else {
            initData = nil
        }
        let segmentData = try await loader.payload(
            for: .videoSegment(index: index)
        ).data
        try requireOpen()
        try Task.checkCancellation()
        let resource = graph.segments[index]
        let expectedCodec =
            preflight.result.sourceProfile.videoCodec
        let bridgeMode = self.bridgeMode
        let admission = try await Task.detached(
            priority: .userInitiated
        ) {
            try Self.inspectVideo(
                initData: initData,
                segmentData: segmentData,
                segmentIndex: index,
                resource: resource,
                expectedCodec: expectedCodec,
                bridgeMode: bridgeMode
            )
        }.value
        try requireOpen()
        try Task.checkCancellation()
        return admission
    }

    func inspectAudioSegment(
        renditionOrdinal: Int,
        segmentIndex: Int
    ) async throws -> HLSVODAudioSegmentAdmission {
        try requireOpen()
        guard graph.audioRenditions.indices
            .contains(renditionOrdinal) else {
            throw HLSVODSegmentDemuxError
                .audioRenditionOutOfRange(
                    renditionOrdinal
                )
        }
        let rendition =
            graph.audioRenditions[renditionOrdinal]
        guard rendition.segments.indices
            .contains(segmentIndex) else {
            throw HLSVODSegmentDemuxError
                .audioSegmentOutOfRange(
                    renditionOrdinal:
                        renditionOrdinal,
                    segmentIndex: segmentIndex
                )
        }
        let initData: Data?
        if rendition.initSegmentURL != nil {
            initData = try await loader.payload(
                for: .audioInit(
                    renditionOrdinal:
                        renditionOrdinal
                )
            ).data
        } else {
            initData = nil
        }
        let segmentData = try await loader.payload(
            for: .audioSegment(
                renditionOrdinal: renditionOrdinal,
                index: segmentIndex
            )
        ).data
        try requireOpen()
        try Task.checkCancellation()
        let bridgeMode = self.bridgeMode
        let admission = try await Task.detached(
            priority: .userInitiated
        ) {
            try Self.inspectAudio(
                initData: initData,
                segmentData: segmentData,
                rendition: rendition,
                segmentIndex: segmentIndex,
                bridgeMode: bridgeMode
            )
        }.value
        try requireOpen()
        try Task.checkCancellation()
        return admission
    }

    func close() async throws {
        if isClosed { return }
        isClosed = true
        try await loader.close()
    }

    private func requireOpen() throws {
        guard !isClosed else {
            throw HLSVODSegmentDemuxError.closed
        }
    }

    nonisolated private static func inspectVideo(
        initData: Data?,
        segmentData: Data,
        segmentIndex: Int,
        resource: HLSVODSegmentResource,
        expectedCodec: AetherVideoCodec,
        bridgeMode: AudioBridgeMode
    ) throws -> HLSVODVideoSegmentAdmission {
        let container: HLSVODSegmentContainer
        let data: Data
        let formatHint: String
        if let initData {
            container = .fragmentedMP4
            data = initData + segmentData
            formatHint = "mp4"
        } else {
            container = .mpegTransport
            data = segmentData
            formatHint = "mpegts"
        }
        let demuxer = try openDemuxer(
            data: data,
            formatHint: formatHint
        )
        defer { demuxer.close() }
        let videoStreams = try streamIndices(
            demuxer: demuxer,
            mediaType: AVMEDIA_TYPE_VIDEO
        )
        guard videoStreams.count == 1 else {
            throw HLSVODSegmentDemuxError
                .videoStreamCount(videoStreams.count)
        }
        let videoIndex = videoStreams[0]
        let actualCodec = try videoCodec(
            demuxer: demuxer,
            streamIndex: videoIndex
        )
        guard actualCodec == expectedCodec else {
            throw HLSVODSegmentDemuxError
                .videoCodecMismatch(
                    expected: expectedCodec,
                    actual: actualCodec
                )
        }
        let audioAdmissions = try audioAdmissions(
            demuxer: demuxer,
            bridgeMode: bridgeMode,
            renditionOrdinal: nil
        )
        let packetCounts = try readPacketCounts(
            demuxer: demuxer
        )
        let videoPacketCount =
            packetCounts[videoIndex] ?? 0
        guard videoPacketCount > 0 else {
            throw HLSVODSegmentDemuxError
                .videoPacketMissing(
                    streamIndex: Int(videoIndex)
                )
        }
        let muxedAudioStreams = try audioAdmissions.map {
            admission in
            let packetCount =
                packetCounts[
                    Int32(admission.track.id)
                ] ?? 0
            guard packetCount > 0 else {
                throw HLSVODSegmentDemuxError
                    .audioPacketMissing(
                        renditionOrdinal: nil,
                        streamIndex: admission.track.id
                    )
            }
            return HLSVODAudioStreamAdmission(
                track: admission.track,
                carrierDescriptor:
                    admission.carrierDescriptor,
                packetCount: packetCount
            )
        }
        return HLSVODVideoSegmentAdmission(
            segmentIndex: segmentIndex,
            mediaSequence: resource.mediaSequence,
            duration: resource.duration,
            container: container,
            videoStreamIndex: Int(videoIndex),
            videoCodec: actualCodec,
            videoPacketCount: videoPacketCount,
            muxedAudioStreams: muxedAudioStreams
        )
    }

    nonisolated private static func inspectAudio(
        initData: Data?,
        segmentData: Data,
        rendition: HLSVODAudioRenditionResource,
        segmentIndex: Int,
        bridgeMode: AudioBridgeMode
    ) throws -> HLSVODAudioSegmentAdmission {
        let container: HLSVODSegmentContainer
        let data: Data
        let formatHint: String?
        if let initData {
            container = .fragmentedMP4
            data = initData + segmentData
            formatHint = "mp4"
        } else {
            data = segmentData
            if LiveSegmentFormat.classify(segmentData)
                == .mpegts {
                container = .mpegTransport
                formatHint = "mpegts"
            } else {
                container = .selfContained
                formatHint = nil
            }
        }
        let demuxer = try openDemuxer(
            data: data,
            formatHint: formatHint
        )
        defer { demuxer.close() }
        let videoStreams = try streamIndices(
            demuxer: demuxer,
            mediaType: AVMEDIA_TYPE_VIDEO
        )
        guard videoStreams.isEmpty else {
            throw HLSVODSegmentDemuxError
                .audioRenditionContainsVideo(
                    renditionOrdinal: rendition.ordinal
                )
        }
        let admissions = try audioAdmissions(
            demuxer: demuxer,
            bridgeMode: bridgeMode,
            renditionOrdinal: rendition.ordinal
        )
        guard admissions.count == 1 else {
            throw HLSVODSegmentDemuxError
                .audioStreamCount(
                    renditionOrdinal: rendition.ordinal,
                    count: admissions.count
                )
        }
        let admitted = admissions[0]
        if let declared = rendition.channels,
           declared != admitted.carrierDescriptor
            .channelsAttribute {
            throw HLSVODSegmentDemuxError
                .audioChannelsMismatch(
                    renditionOrdinal: rendition.ordinal,
                    declared: declared,
                    admitted:
                        admitted.carrierDescriptor
                            .channelsAttribute
                )
        }
        let packetCounts = try readPacketCounts(
            demuxer: demuxer
        )
        let packetCount =
            packetCounts[Int32(admitted.track.id)] ?? 0
        guard packetCount > 0 else {
            throw HLSVODSegmentDemuxError
                .audioPacketMissing(
                    renditionOrdinal: rendition.ordinal,
                    streamIndex: admitted.track.id
                )
        }
        let resource = rendition.segments[segmentIndex]
        return HLSVODAudioSegmentAdmission(
            renditionOrdinal: rendition.ordinal,
            segmentIndex: segmentIndex,
            mediaSequence: resource.mediaSequence,
            duration: resource.duration,
            container: container,
            manifestName: rendition.name,
            manifestLanguage: rendition.language,
            isDefault: rendition.isDefault,
            isAutoselect: rendition.isAutoselect,
            manifestChannels: rendition.channels,
            stream: HLSVODAudioStreamAdmission(
                track: admitted.track,
                carrierDescriptor:
                    admitted.carrierDescriptor,
                packetCount: packetCount
            )
        )
    }

    nonisolated private static func openDemuxer(
        data: Data,
        formatHint: String?
    ) throws -> Demuxer {
        let demuxer = Demuxer()
        do {
            try demuxer.open(
                reader: DataIOReader(data: data),
                formatHint: formatHint
            )
            return demuxer
        } catch {
            demuxer.close()
            throw HLSVODSegmentDemuxError
                .demuxOpenFailed
        }
    }

    private struct PendingAudioAdmission {
        let track: TrackInfo
        let carrierDescriptor:
            BlackCarrierAudioRenditionDescriptor
    }

    nonisolated private static func audioAdmissions(
        demuxer: Demuxer,
        bridgeMode: AudioBridgeMode,
        renditionOrdinal: Int?
    ) throws -> [PendingAudioAdmission] {
        let audioStreams = try streamIndices(
            demuxer: demuxer,
            mediaType: AVMEDIA_TYPE_AUDIO
        )
        let tracks = Dictionary(
            uniqueKeysWithValues:
                demuxer.audioTrackInfos().map {
                    (Int32($0.id), $0)
                }
        )
        return try audioStreams.map { streamIndex in
            guard let track = tracks[streamIndex] else {
                throw HLSVODSegmentDemuxError
                    .unresolvedCodec(
                        streamIndex: Int(streamIndex)
                    )
            }
            do {
                return PendingAudioAdmission(
                    track: track,
                    carrierDescriptor:
                        try BlackCarrierAudioRenditionMuxer
                            .admissionDescriptor(
                                demuxer: demuxer,
                                audioStreamIndex:
                                    Int32(track.id),
                                bridgeMode: bridgeMode
                            )
                )
            } catch {
                throw HLSVODSegmentDemuxError
                    .audioRouteUnsupported(
                        renditionOrdinal:
                            renditionOrdinal,
                        reason:
                            String(describing: error)
                    )
            }
        }
    }

    nonisolated private static func streamIndices(
        demuxer: Demuxer,
        mediaType: AVMediaType
    ) throws -> [Int32] {
        var indices: [Int32] = []
        for index in 0..<demuxer.streamCount {
            guard let stream = demuxer.stream(
                at: Int32(index)
            ) else {
                continue
            }
            let codecParameters =
                stream.pointee.codecpar!
            guard codecParameters.pointee.codec_type
                == mediaType else {
                continue
            }
            guard codecParameters.pointee.codec_id
                != AV_CODEC_ID_NONE else {
                throw HLSVODSegmentDemuxError
                    .unresolvedCodec(streamIndex: index)
            }
            let timeBase = stream.pointee.time_base
            guard timeBase.num > 0, timeBase.den > 0 else {
                throw HLSVODSegmentDemuxError
                    .invalidTimeBase(streamIndex: index)
            }
            indices.append(Int32(index))
        }
        return indices
    }

    nonisolated private static func videoCodec(
        demuxer: Demuxer,
        streamIndex: Int32
    ) throws -> AetherVideoCodec {
        guard let stream = demuxer.stream(
            at: streamIndex
        ),
              let name = avcodec_get_name(
                  stream.pointee.codecpar.pointee.codec_id
              ) else {
            throw HLSVODSegmentDemuxError
                .unresolvedCodec(
                    streamIndex: Int(streamIndex)
                )
        }
        let codec = AetherVideoCodec(
            codecName: String(cString: name)
        )
        guard codec != .unknown else {
            throw HLSVODSegmentDemuxError
                .unresolvedCodec(
                    streamIndex: Int(streamIndex)
                )
        }
        return codec
    }

    nonisolated private static func readPacketCounts(
        demuxer: Demuxer
    ) throws -> [Int32: Int] {
        var counts: [Int32: Int] = [:]
        do {
            while let packet = try demuxer.readPacket() {
                var packetToFree:
                    UnsafeMutablePointer<AVPacket>? = packet
                defer {
                    trackedPacketFree(&packetToFree)
                }
                counts[packet.pointee.stream_index, default: 0]
                    += 1
            }
        } catch {
            throw HLSVODSegmentDemuxError
                .packetReadFailed
        }
        return counts
    }
}
