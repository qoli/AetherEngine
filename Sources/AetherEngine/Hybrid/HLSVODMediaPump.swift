import CoreMedia
import Foundation
import Libavcodec
import Libavformat
import Libavutil

enum HLSVODMediaPumpError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case invalidPreflight
    case closed
    case cancelled
    case targetSegmentOutOfRange(Int)
    case origin(HLSVODOriginResourceError)
    case demuxOpenFailed
    case packetReadFailed
    case videoStreamCount(segmentIndex: Int, count: Int)
    case videoContractChanged(segmentIndex: Int)
    case videoPacketMissing(segmentIndex: Int)
    case audioRenditionContainsVideo(
        renditionOrdinal: Int,
        inputSegmentIndex: Int
    )
    case audioStreamCount(
        renditionOrdinal: Int,
        inputSegmentIndex: Int,
        count: Int
    )
    case audioContractChanged(
        renditionOrdinal: Int,
        inputSegmentIndex: Int
    )
    case audioPacketMissing(
        renditionOrdinal: Int,
        inputSegmentIndex: Int
    )
    case muxedAudioStreamCount(
        segmentIndex: Int,
        expected: Int,
        actual: Int
    )
    case muxedAudioContractChanged(
        ordinal: Int,
        segmentIndex: Int
    )
    case muxedAudioPacketMissing(
        ordinal: Int,
        segmentIndex: Int
    )
    case timestampMissing(
        streamIndex: Int,
        segmentIndex: Int
    )
    case timestampOverflow(
        streamIndex: Int,
        segmentIndex: Int
    )
    case videoSinkFailed(reason: String)
    case audioMuxerFailed(
        renditionOrdinal: Int,
        error: BlackCarrierAudioRenditionMuxerError
    )
    case audioStoreFailed(
        renditionOrdinal: Int,
        error: BlackCarrierAudioRenditionStoreError
    )
    case requestedSegmentUnavailable(Int)
    case unexpected(reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidPreflight:
            "HLS VOD media pump requires an admitted hybrid resource graph"
        case .closed:
            "HLS VOD media pump is closed"
        case .cancelled:
            "HLS VOD media pump was cancelled"
        case .targetSegmentOutOfRange(let index):
            "HLS VOD media pump target segment \(index) is out of range"
        case .origin(let error):
            error.localizedDescription
        case .demuxOpenFailed:
            "HLS VOD media pump could not open a graph-bound segment"
        case .packetReadFailed:
            "HLS VOD media pump packet read failed"
        case .videoStreamCount(let index, let count):
            "HLS VOD video segment \(index) exposed \(count) video streams"
        case .videoContractChanged(let index):
            "HLS VOD video stream contract changed in segment \(index)"
        case .videoPacketMissing(let index):
            "HLS VOD video segment \(index) produced no video packet"
        case .audioRenditionContainsVideo(let ordinal, let index):
            "HLS VOD audio rendition \(ordinal) segment \(index) unexpectedly contains video"
        case .audioStreamCount(let ordinal, let index, let count):
            "HLS VOD audio rendition \(ordinal) segment \(index) exposed \(count) audio streams"
        case .audioContractChanged(let ordinal, let index):
            "HLS VOD audio rendition \(ordinal) contract changed in segment \(index)"
        case .audioPacketMissing(let ordinal, let index):
            "HLS VOD audio rendition \(ordinal) segment \(index) produced no audio packet"
        case .muxedAudioStreamCount(let index, let expected, let actual):
            "HLS VOD video segment \(index) exposed \(actual) muxed audio streams; expected \(expected)"
        case .muxedAudioContractChanged(let ordinal, let index):
            "HLS VOD muxed audio rendition \(ordinal) contract changed in video segment \(index)"
        case .muxedAudioPacketMissing(let ordinal, let index):
            "HLS VOD muxed audio rendition \(ordinal) produced no packet in video segment \(index)"
        case .timestampMissing(let streamIndex, let segmentIndex):
            "HLS VOD stream \(streamIndex) segment \(segmentIndex) has no packet timestamp"
        case .timestampOverflow(let streamIndex, let segmentIndex):
            "HLS VOD stream \(streamIndex) segment \(segmentIndex) timestamp exceeded the source axis"
        case .videoSinkFailed(let reason):
            "HLS VOD real-video packet sink failed: \(reason)"
        case .audioMuxerFailed(let ordinal, let error):
            "HLS VOD audio rendition \(ordinal) failed: \(error.localizedDescription)"
        case .audioStoreFailed(let ordinal, let error):
            "HLS VOD audio rendition \(ordinal) storage failed: \(error.localizedDescription)"
        case .requestedSegmentUnavailable(let index):
            "HLS VOD carrier segment \(index) was not produced"
        case .unexpected(let reason):
            "HLS VOD media pump failed unexpectedly: \(reason)"
        }
    }
}

struct HLSVODMediaPumpSnapshot: Sendable, Equatable {
    let nextVideoInputSegmentIndex: Int
    let nextAudioInputSegmentIndices: [Int]
    let highestProducedVideoSegmentIndex: Int
    let highestFinalizedAudioSegmentIndices: [Int]
    let videoPacketCount: Int
    let audioPacketCounts: [Int]
    let isClosed: Bool
}

/// Incremental packet pump for the exact HLS VOD resources admitted by preflight.
///
/// Each upstream segment is opened in a fresh finite in-memory FFmpeg demuxer. Packet timestamps are
/// normalized from that segment's local origin onto the immutable 90 kHz graph timeline before they
/// enter the real-video sink or long-lived carrier-audio writer. FFmpeg never receives a URL and cannot
/// reopen the master playlist, choose a different variant or perform network I/O.
///
/// This remains an engine-private source pump. Public HLS session admission stays disabled until a
/// transport provider, seek-generation replacement, analysis reader and exact master-bandwidth admission
/// own this pump. Audio production may read one upstream segment ahead because an audio access unit from
/// the next carrier interval is the evidence that lets the long-lived fMP4 writer finalize the requested
/// fragment; the following carrier fragment is not finalized until a later demand.
actor HLSVODMediaPump {
    typealias VideoPacketSink =
        BlackCarrierMediaFanoutPump.VideoPacketSink

    let renditionMetadata: [BlackCarrierAudioRenditionMetadata]
    let renditionDescriptors: [BlackCarrierAudioRenditionDescriptor]

    private let graph: HLSVODResourceGraph
    private let loader: HLSVODOriginResourceLoader
    private let worker: Worker
    private let videoInitData: Data?
    private let audioInitData: [Data?]

    private var nextVideoInputSegmentIndex = 0
    private var nextAudioInputSegmentIndices: [Int]
    private var terminalError: HLSVODMediaPumpError?
    private var isClosed = false
    private var productionInProgress = false
    private var productionWaiters: [
        CheckedContinuation<Void, Never>
    ] = []

    static func make(
        preflight: AetherHLSPlaybackPreflight,
        bridgeMode: AudioBridgeMode = .surroundCompat,
        videoPacketSink: VideoPacketSink? = nil,
        decodedFrameHandler:
            HybridVideoDecodeSink.FrameHandler? = nil,
        videoFailureHandler:
            HybridVideoDecodeSink.FailureHandler? = nil,
        initialGeneration: UInt64 = 0,
        maximumResourceBytes: Int =
            HLSVODOriginResourceLoader.defaultMaximumResourceBytes,
        capacityBytes: Int64 =
            HLSVODOriginResourceLoader.defaultCapacityBytes,
        baseDirectory: URL =
            FileManager.default.temporaryDirectory,
        fetchOverride:
            HLSVODOriginResourceLoader.Fetch? = nil
    ) async throws -> HLSVODMediaPump {
        guard preflight.result.route == .hybridCarrierMetal,
              preflight.result.sourceProfile.sourceKind == .hls,
              let graph = preflight.resourceGraph else {
            throw HLSVODMediaPumpError.invalidPreflight
        }
        guard videoPacketSink == nil
                || decodedFrameHandler == nil else {
            throw HLSVODMediaPumpError.videoSinkFailed(
                reason:
                    "Multiple real-video packet sinks were supplied"
            )
        }
        let loader: HLSVODOriginResourceLoader
        do {
            loader = try HLSVODOriginResourceLoader(
                graph: graph,
                httpHeaders: preflight.httpHeaders,
                maximumResourceBytes: maximumResourceBytes,
                capacityBytes: capacityBytes,
                baseDirectory: baseDirectory,
                fetchOverride: fetchOverride
            )
        } catch let error as HLSVODOriginResourceError {
            throw HLSVODMediaPumpError.origin(error)
        }

        do {
            let videoInitData: Data?
            if graph.initSegmentURL != nil {
                videoInitData = try await loader.payload(
                    for: .videoInit
                ).data
            } else {
                videoInitData = nil
            }
            let firstVideoSegment = try await loader.payload(
                for: .videoSegment(index: 0)
            ).data

            var audioInitData: [Data?] = []
            var firstAudioSegments: [Data] = []
            audioInitData.reserveCapacity(
                graph.audioRenditions.count
            )
            firstAudioSegments.reserveCapacity(
                graph.audioRenditions.count
            )
            for rendition in graph.audioRenditions {
                if rendition.initSegmentURL != nil {
                    audioInitData.append(
                        try await loader.payload(
                            for: .audioInit(
                                renditionOrdinal:
                                    rendition.ordinal
                            )
                        ).data
                    )
                } else {
                    audioInitData.append(nil)
                }
                firstAudioSegments.append(
                    try await loader.payload(
                        for: .audioSegment(
                            renditionOrdinal:
                                rendition.ordinal,
                            index: 0
                        )
                    ).data
                )
            }

            let worker = try Worker(
                graph: graph,
                bridgeMode: bridgeMode,
                videoInitData: videoInitData,
                firstVideoSegmentData:
                    firstVideoSegment,
                audioInitData: audioInitData,
                firstAudioSegmentData:
                    firstAudioSegments,
                videoPacketSink: videoPacketSink,
                decodedFrameHandler:
                    decodedFrameHandler,
                videoFailureHandler:
                    videoFailureHandler,
                initialGeneration: initialGeneration
            )
            return HLSVODMediaPump(
                graph: graph,
                loader: loader,
                worker: worker,
                videoInitData: videoInitData,
                audioInitData: audioInitData
            )
        } catch {
            do {
                try await loader.close()
            } catch {
                EngineLog.emit(
                    "[HLSVODMediaPump] setup cleanup failed: "
                        + String(describing: error),
                    category: .session
                )
            }
            throw Self.typed(error)
        }
    }

    private init(
        graph: HLSVODResourceGraph,
        loader: HLSVODOriginResourceLoader,
        worker: Worker,
        videoInitData: Data?,
        audioInitData: [Data?]
    ) {
        self.graph = graph
        self.loader = loader
        self.worker = worker
        self.videoInitData = videoInitData
        self.audioInitData = audioInitData
        renditionMetadata = worker.renditionMetadata
        renditionDescriptors = worker.renditionDescriptors
        nextAudioInputSegmentIndices = Array(
            repeating: 0,
            count: graph.audioRenditions.count
        )
    }

    func produce(throughSegment target: Int) async throws {
        guard graph.segments.indices.contains(target) else {
            throw HLSVODMediaPumpError
                .targetSegmentOutOfRange(target)
        }

        while true {
            try requireAvailable()
            if worker.hasProduced(segment: target) {
                return
            }
            if productionInProgress {
                try await waitForProduction()
                continue
            }

            productionInProgress = true
            Task {
                await performProduction(
                    throughSegment: target
                )
            }
            try await waitForProduction()
        }
    }

    func audioInitSegment(
        renditionOrdinal: Int
    ) async throws -> Data? {
        guard renditionMetadata.indices
            .contains(renditionOrdinal) else {
            return nil
        }
        try await produce(throughSegment: 0)
        return worker.audioInitSegment(
            renditionOrdinal: renditionOrdinal
        )
    }

    func audioMediaSegmentURL(
        renditionOrdinal: Int,
        segmentIndex: Int
    ) async throws -> URL? {
        guard renditionMetadata.indices
            .contains(renditionOrdinal),
              graph.segments.indices
                .contains(segmentIndex) else {
            return nil
        }
        try await produce(
            throughSegment: segmentIndex
        )
        return worker.audioMediaSegmentURL(
            renditionOrdinal: renditionOrdinal,
            segmentIndex: segmentIndex
        )
    }

    func audioMediaSegment(
        renditionOrdinal: Int,
        segmentIndex: Int
    ) async throws -> Data? {
        guard renditionMetadata.indices
            .contains(renditionOrdinal),
              graph.segments.indices
                .contains(segmentIndex) else {
            return nil
        }
        try await produce(
            throughSegment: segmentIndex
        )
        return worker.audioMediaSegment(
            renditionOrdinal: renditionOrdinal,
            segmentIndex: segmentIndex
        )
    }

    func finishProduction() async throws
        -> [BlackCarrierAudioRenditionSummary]
    {
        guard let last =
                graph.segments.indices.last else {
            throw HLSVODMediaPumpError
                .targetSegmentOutOfRange(0)
        }
        try await produce(throughSegment: last)
        guard let summaries =
                worker.audioSummaries() else {
            throw HLSVODMediaPumpError
                .requestedSegmentUnavailable(last)
        }
        return summaries
    }

    func advanceVideoDecodeDemand(
        to time: CMTime
    ) throws {
        try requireAvailable()
        do {
            try worker.advanceVideoDecodeDemand(to: time)
        } catch {
            let typed = HLSVODMediaPumpError
                .videoSinkFailed(
                    reason: String(describing: error)
                )
            terminalError = typed
            worker.close()
            throw typed
        }
    }

    var hybridVideoFormat: VideoFormat? {
        worker.hybridVideoFormat
    }

    var isTargetFrameReady: Bool {
        worker.isTargetFrameReady
    }

    func snapshot() -> HLSVODMediaPumpSnapshot {
        let workerSnapshot = worker.snapshot()
        return HLSVODMediaPumpSnapshot(
            nextVideoInputSegmentIndex:
                nextVideoInputSegmentIndex,
            nextAudioInputSegmentIndices:
                nextAudioInputSegmentIndices,
            highestProducedVideoSegmentIndex:
                workerSnapshot
                    .highestProducedVideoSegmentIndex,
            highestFinalizedAudioSegmentIndices:
                workerSnapshot
                    .highestFinalizedAudioSegmentIndices,
            videoPacketCount:
                workerSnapshot.videoPacketCount,
            audioPacketCounts:
                workerSnapshot.audioPacketCounts,
            isClosed: isClosed
        )
    }

    func close() async throws {
        guard !isClosed else { return }
        isClosed = true
        worker.close()
        resumeProductionWaiters()
        do {
            try await loader.close()
        } catch let error as HLSVODOriginResourceError {
            throw HLSVODMediaPumpError.origin(error)
        }
    }

    private func runProduction(
        throughSegment target: Int
    ) async throws {
        while nextVideoInputSegmentIndex
                < graph.segments.count,
              nextVideoInputSegmentIndex <= target
                || worker.muxedAudioNeedsInput(
                    throughSegment: target
                ) {
            try requireAvailable()
            let index = nextVideoInputSegmentIndex
            let data = try await loader.payload(
                for: .videoSegment(index: index)
            ).data
            try requireAvailable()
            try worker.consumeVideoSegment(
                index: index,
                initData: videoInitData,
                segmentData: data
            )
            nextVideoInputSegmentIndex += 1
        }
        if nextVideoInputSegmentIndex
                == graph.segments.count,
           target == graph.segments.count - 1 {
            try worker.finishVideoInput()
        }

        for rendition in graph.audioRenditions {
            let ordinal = rendition.ordinal
            while nextAudioInputSegmentIndices[ordinal]
                    < rendition.segments.count,
                  worker.audioNeedsInput(
                    renditionOrdinal: ordinal,
                    throughSegment: target
                  ) {
                try requireAvailable()
                let index =
                    nextAudioInputSegmentIndices[ordinal]
                let data = try await loader.payload(
                    for: .audioSegment(
                        renditionOrdinal: ordinal,
                        index: index
                    )
                ).data
                try requireAvailable()
                try worker.consumeAudioSegment(
                    renditionOrdinal: ordinal,
                    inputSegmentIndex: index,
                    initData: audioInitData[ordinal],
                    segmentData: data
                )
                nextAudioInputSegmentIndices[ordinal]
                    += 1
            }
            if nextAudioInputSegmentIndices[ordinal]
                    == rendition.segments.count,
               target == graph.segments.count - 1 {
                try worker.finishAudioInput(
                    renditionOrdinal: ordinal
                )
            }
        }

        guard worker.hasProduced(segment: target) else {
            throw HLSVODMediaPumpError
                .requestedSegmentUnavailable(target)
        }
    }

    private func requireAvailable() throws {
        if let terminalError {
            throw terminalError
        }
        guard !isClosed else {
            throw HLSVODMediaPumpError.closed
        }
    }

    private func performProduction(
        throughSegment target: Int
    ) async {
        do {
            try await runProduction(
                throughSegment: target
            )
        } catch {
            let typed = Self.typed(error)
            if !isClosed {
                terminalError = typed
            }
            worker.close()
            do {
                try await loader.close()
            } catch {
                EngineLog.emit(
                    "[HLSVODMediaPump] failure cleanup failed: "
                        + String(describing: error),
                    category: .session
                )
            }
        }
        productionInProgress = false
        resumeProductionWaiters()
    }

    private func waitForProduction() async throws {
        do {
            try Task.checkCancellation()
        } catch {
            throw HLSVODMediaPumpError.cancelled
        }
        await withCheckedContinuation {
            continuation in
            productionWaiters.append(continuation)
        }
        do {
            try Task.checkCancellation()
        } catch {
            throw HLSVODMediaPumpError.cancelled
        }
    }

    private func resumeProductionWaiters() {
        let waiters = productionWaiters
        productionWaiters.removeAll(
            keepingCapacity: true
        )
        waiters.forEach { $0.resume() }
    }

    nonisolated private static func typed(
        _ error: Error
    ) -> HLSVODMediaPumpError {
        if let typed = error as? HLSVODMediaPumpError {
            return typed
        }
        if let origin =
                error as? HLSVODOriginResourceError {
            return .origin(origin)
        }
        if error is CancellationError {
            return .cancelled
        }
        return .unexpected(
            reason: String(describing: error)
        )
    }
}

private extension HLSVODMediaPump {
    struct WorkerSnapshot {
        let highestProducedVideoSegmentIndex: Int
        let highestFinalizedAudioSegmentIndices:
            [Int]
        let videoPacketCount: Int
        let audioPacketCounts: [Int]
    }

    struct AudioStreamContract: Equatable {
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
            let parameters =
                stream.pointee.codecpar.pointee
            codecID = parameters.codec_id.rawValue
            codecTag = parameters.codec_tag
            profile = parameters.profile
            sampleRate = parameters.sample_rate
            frameSize = parameters.frame_size
            channelCount =
                parameters.ch_layout.nb_channels
            var channelLayout =
                parameters.ch_layout
            var channelLayoutBuffer = [
                CChar
            ](
                repeating: 0,
                count: 256
            )
            channelLayoutDescription =
                channelLayoutBuffer
                    .withUnsafeMutableBufferPointer {
                        buffer in
                        _ = av_channel_layout_describe(
                            &channelLayout,
                            buffer.baseAddress,
                            buffer.count
                        )
                        return String(
                            cString:
                                buffer.baseAddress!
                        )
                    }
            sampleFormat = parameters.format
            bitsPerCodedSample =
                parameters.bits_per_coded_sample
            bitsPerRawSample =
                parameters.bits_per_raw_sample
            blockAlign = parameters.block_align
            timeBaseNumerator =
                stream.pointee.time_base.num
            timeBaseDenominator =
                stream.pointee.time_base.den
            if let bytes = parameters.extradata,
               parameters.extradata_size > 0 {
                codecConfiguration = Data(
                    bytes: bytes,
                    count:
                        Int(parameters.extradata_size)
                )
            } else {
                codecConfiguration = Data()
            }
        }
    }

    final class AudioRendition {
        let metadata: BlackCarrierAudioRenditionMetadata
        let descriptor:
            BlackCarrierAudioRenditionDescriptor
        let contract: AudioStreamContract
        let cache: SegmentCache
        let writer:
            BlackCarrierAudioRenditionMuxer.Writer
        var summary:
            BlackCarrierAudioRenditionSummary?
        var packetCount = 0

        init(
            metadata: BlackCarrierAudioRenditionMetadata,
            descriptor:
                BlackCarrierAudioRenditionDescriptor,
            contract: AudioStreamContract,
            cache: SegmentCache,
            writer:
                BlackCarrierAudioRenditionMuxer.Writer
        ) {
            self.metadata = metadata
            self.descriptor = descriptor
            self.contract = contract
            self.cache = cache
            self.writer = writer
        }
    }

    final class Worker: @unchecked Sendable {
        let renditionMetadata:
            [BlackCarrierAudioRenditionMetadata]
        let renditionDescriptors:
            [BlackCarrierAudioRenditionDescriptor]

        private let graph: HLSVODResourceGraph
        private let bridgeMode: AudioBridgeMode
        private let videoContract:
            HybridVideoStreamContract
        private let videoStreamIndex: Int32
        private let videoPacketSink: VideoPacketSink?
        private let videoDecodeSink:
            HybridVideoDecodeSink?
        private let audioRenditions: [AudioRendition]
        private let usesSeparateAudio: Bool

        private var highestProducedVideoSegmentIndex =
            -1
        private var videoPacketCount = 0
        private var videoInputFinished = false
        private var isClosed = false

        init(
            graph: HLSVODResourceGraph,
            bridgeMode: AudioBridgeMode,
            videoInitData: Data?,
            firstVideoSegmentData: Data,
            audioInitData: [Data?],
            firstAudioSegmentData: [Data],
            videoPacketSink: VideoPacketSink?,
            decodedFrameHandler:
                HybridVideoDecodeSink.FrameHandler?,
            videoFailureHandler:
                HybridVideoDecodeSink.FailureHandler?,
            initialGeneration: UInt64
        ) throws {
            self.graph = graph
            self.bridgeMode = bridgeMode
            usesSeparateAudio =
                !graph.audioRenditions.isEmpty

            let videoDemuxer = try Self.openVideoDemuxer(
                initData: videoInitData,
                segmentData: firstVideoSegmentData
            )
            defer { videoDemuxer.close() }
            let videoStreams = try Self.streamIndices(
                demuxer: videoDemuxer,
                mediaType: AVMEDIA_TYPE_VIDEO
            )
            guard videoStreams.count == 1 else {
                throw HLSVODMediaPumpError
                    .videoStreamCount(
                        segmentIndex: 0,
                        count: videoStreams.count
                    )
            }
            videoStreamIndex = videoStreams[0]
            guard let videoStream = videoDemuxer.stream(
                at: videoStreamIndex
            ) else {
                throw HLSVODMediaPumpError
                    .videoStreamCount(
                        segmentIndex: 0,
                        count: 0
                    )
            }
            videoContract =
                try HybridVideoStreamContract(
                    demuxer: videoDemuxer,
                    stream: videoStream,
                    sourceStartPTSOverride: 0
                )
            self.videoPacketSink = videoPacketSink
            if let decodedFrameHandler {
                videoDecodeSink =
                    try HybridVideoDecodeSink(
                        demuxer: videoDemuxer,
                        initialGeneration:
                            initialGeneration,
                        sourceStartPTSOverride: 0,
                        onFrame: decodedFrameHandler,
                        onFailure:
                            videoFailureHandler
                    )
            } else {
                videoDecodeSink = nil
            }

            if usesSeparateAudio {
                guard audioInitData.count
                        == graph.audioRenditions.count,
                      firstAudioSegmentData.count
                        == graph.audioRenditions.count else {
                    throw HLSVODMediaPumpError
                        .invalidPreflight
                }
                var prepared: [AudioRendition] = []
                do {
                    for rendition in
                            graph.audioRenditions {
                        let ordinal = rendition.ordinal
                        let demuxer =
                            try Self.openAudioDemuxer(
                                initData:
                                    audioInitData[ordinal],
                                segmentData:
                                    firstAudioSegmentData[
                                        ordinal
                                    ]
                            )
                        defer { demuxer.close() }
                        let videoStreams =
                            try Self.streamIndices(
                                demuxer: demuxer,
                                mediaType:
                                    AVMEDIA_TYPE_VIDEO
                            )
                        guard videoStreams.isEmpty else {
                            throw HLSVODMediaPumpError
                                .audioRenditionContainsVideo(
                                    renditionOrdinal:
                                        ordinal,
                                    inputSegmentIndex: 0
                                )
                        }
                        let audioStreams =
                            try Self.streamIndices(
                                demuxer: demuxer,
                                mediaType:
                                    AVMEDIA_TYPE_AUDIO
                            )
                        guard audioStreams.count == 1,
                              let stream =
                                demuxer.stream(
                                    at: audioStreams[0]
                                ) else {
                            throw HLSVODMediaPumpError
                                .audioStreamCount(
                                    renditionOrdinal:
                                        ordinal,
                                    inputSegmentIndex: 0,
                                    count:
                                        audioStreams.count
                                )
                        }
                        prepared.append(
                            try Self.makeRendition(
                                graph: graph,
                                metadata:
                                    BlackCarrierAudioRenditionMetadata(
                                        ordinal: ordinal,
                                        sourceTrackID:
                                            ordinal,
                                        language:
                                            rendition.language,
                                        name:
                                            rendition.name,
                                        isDefault:
                                            rendition.isDefault,
                                        isAutoselect:
                                            rendition.isAutoselect
                                    ),
                                demuxer: demuxer,
                                stream: stream,
                                streamIndex:
                                    audioStreams[0],
                                bridgeMode:
                                    bridgeMode,
                                declaredChannels:
                                    rendition.channels
                            )
                        )
                    }
                } catch {
                    prepared.forEach {
                        $0.cache.close()
                    }
                    videoDecodeSink?.close()
                    throw error
                }
                audioRenditions = prepared
            } else {
                let audioTracks =
                    videoDemuxer.audioTrackInfos()
                let metadata =
                    BlackCarrierCompositeProvider
                        .renditionMetadata(
                            for: audioTracks
                        )
                var prepared: [AudioRendition] = []
                do {
                    for (track, metadata) in zip(
                        audioTracks,
                        metadata
                    ) {
                        guard let stream =
                                videoDemuxer.stream(
                                    at: Int32(track.id)
                                ) else {
                            throw HLSVODMediaPumpError
                                .muxedAudioStreamCount(
                                    segmentIndex: 0,
                                    expected:
                                        audioTracks.count,
                                    actual:
                                        prepared.count
                                )
                        }
                        prepared.append(
                            try Self.makeRendition(
                                graph: graph,
                                metadata: metadata,
                                demuxer: videoDemuxer,
                                stream: stream,
                                streamIndex:
                                    Int32(track.id),
                                bridgeMode:
                                    bridgeMode,
                                declaredChannels: nil
                            )
                        )
                    }
                } catch {
                    prepared.forEach {
                        $0.cache.close()
                    }
                    videoDecodeSink?.close()
                    throw error
                }
                audioRenditions = prepared
            }
            renditionMetadata =
                audioRenditions.map(\.metadata)
            renditionDescriptors =
                audioRenditions.map(\.descriptor)
        }

        deinit {
            close()
        }

        var hybridVideoFormat: VideoFormat? {
            videoDecodeSink?
                .streamContract.videoFormat
        }

        var isTargetFrameReady: Bool {
            videoDecodeSink?.isTargetFrameReady
                ?? true
        }

        func consumeVideoSegment(
            index: Int,
            initData: Data?,
            segmentData: Data
        ) throws {
            try requireOpen()
            let demuxer = try Self.openVideoDemuxer(
                initData: initData,
                segmentData: segmentData
            )
            defer { demuxer.close() }
            let videoStreams = try Self.streamIndices(
                demuxer: demuxer,
                mediaType: AVMEDIA_TYPE_VIDEO
            )
            guard videoStreams.count == 1 else {
                throw HLSVODMediaPumpError
                    .videoStreamCount(
                        segmentIndex: index,
                        count: videoStreams.count
                    )
            }
            let actualVideoIndex = videoStreams[0]
            guard let actualVideoStream =
                    demuxer.stream(
                        at: actualVideoIndex
                    ),
                  try HybridVideoStreamContract(
                    demuxer: demuxer,
                    stream: actualVideoStream,
                    sourceStartPTSOverride: 0
                  ) == videoContract else {
                throw HLSVODMediaPumpError
                    .videoContractChanged(
                        segmentIndex: index
                    )
            }

            let actualAudioStreams =
                try Self.streamIndices(
                    demuxer: demuxer,
                    mediaType: AVMEDIA_TYPE_AUDIO
                )
            var muxedByStream: [
                Int32: AudioRendition
            ] = [:]
            if !usesSeparateAudio {
                guard actualAudioStreams.count
                        == audioRenditions.count else {
                    throw HLSVODMediaPumpError
                        .muxedAudioStreamCount(
                            segmentIndex: index,
                            expected:
                                audioRenditions.count,
                            actual:
                                actualAudioStreams.count
                        )
                }
                let actualMetadata =
                    BlackCarrierCompositeProvider
                        .renditionMetadata(
                            for:
                                demuxer.audioTrackInfos()
                        )
                guard actualMetadata
                        == renditionMetadata else {
                    let mismatch =
                        zip(
                            actualMetadata,
                            renditionMetadata
                        )
                        .enumerated()
                        .first {
                            $0.element.0
                                != $0.element.1
                        }?
                        .offset
                        ?? min(
                            actualMetadata.count,
                            renditionMetadata.count
                        )
                    throw HLSVODMediaPumpError
                        .muxedAudioContractChanged(
                            ordinal: mismatch,
                            segmentIndex: index
                        )
                }
                for (ordinal, streamIndex) in
                        actualAudioStreams.enumerated() {
                    guard let stream =
                            demuxer.stream(
                                at: streamIndex
                            ),
                          AudioStreamContract(
                            stream: stream
                          ) == audioRenditions[
                            ordinal
                          ].contract else {
                        throw HLSVODMediaPumpError
                            .muxedAudioContractChanged(
                                ordinal: ordinal,
                                segmentIndex: index
                            )
                    }
                    muxedByStream[streamIndex] =
                        audioRenditions[ordinal]
                }
            }

            var videoPackets = 0
            var audioPackets = Array(
                repeating: 0,
                count: audioRenditions.count
            )
            do {
                while let packet =
                        try demuxer.readPacket() {
                    var packetToFree:
                        UnsafeMutablePointer<AVPacket>? =
                            packet
                    defer {
                        trackedPacketFree(
                            &packetToFree
                        )
                    }
                    let streamIndex =
                        packet.pointee.stream_index
                    if streamIndex
                            == actualVideoIndex {
                        try Self.normalize(
                            packet: packet,
                            demuxer: demuxer,
                            streamIndex:
                                actualVideoIndex,
                            outputStreamIndex:
                                videoStreamIndex,
                            segmentStart:
                                graph.timeline.segments[
                                    index
                                ].startTime,
                            segmentIndex: index
                        )
                        do {
                            if let videoPacketSink {
                                try videoPacketSink(
                                    packet
                                )
                            }
                            if let videoDecodeSink {
                                try videoDecodeSink
                                    .consume(packet)
                            }
                        } catch {
                            throw HLSVODMediaPumpError
                                .videoSinkFailed(
                                    reason:
                                        String(
                                            describing:
                                                error
                                        )
                                )
                        }
                        videoPackets += 1
                    } else if let rendition =
                                muxedByStream[
                                    streamIndex
                                ] {
                        let ordinal =
                            rendition.metadata.ordinal
                        try Self.normalize(
                            packet: packet,
                            demuxer: demuxer,
                            streamIndex:
                                streamIndex,
                            outputStreamIndex:
                                rendition.writer
                                    .sourceStreamIndex,
                            segmentStart:
                                graph.timeline.segments[
                                    index
                                ].startTime,
                            segmentIndex: index
                        )
                        try Self.consume(
                            packet: packet,
                            rendition: rendition
                        )
                        audioPackets[ordinal] += 1
                    }
                }
            } catch let error
                    as HLSVODMediaPumpError {
                throw error
            } catch {
                throw HLSVODMediaPumpError
                    .packetReadFailed
            }
            guard videoPackets > 0 else {
                throw HLSVODMediaPumpError
                    .videoPacketMissing(
                        segmentIndex: index
                    )
            }
            if !usesSeparateAudio {
                for ordinal in audioRenditions.indices
                where audioPackets[ordinal] == 0 {
                    throw HLSVODMediaPumpError
                        .muxedAudioPacketMissing(
                            ordinal: ordinal,
                            segmentIndex: index
                        )
                }
            }
            highestProducedVideoSegmentIndex =
                max(
                    highestProducedVideoSegmentIndex,
                    index
                )
            videoPacketCount += videoPackets
        }

        func consumeAudioSegment(
            renditionOrdinal: Int,
            inputSegmentIndex: Int,
            initData: Data?,
            segmentData: Data
        ) throws {
            try requireOpen()
            guard audioRenditions.indices
                .contains(renditionOrdinal),
                  graph.audioRenditions.indices
                    .contains(renditionOrdinal) else {
                throw HLSVODMediaPumpError
                    .invalidPreflight
            }
            let demuxer = try Self.openAudioDemuxer(
                initData: initData,
                segmentData: segmentData
            )
            defer { demuxer.close() }
            let videoStreams = try Self.streamIndices(
                demuxer: demuxer,
                mediaType: AVMEDIA_TYPE_VIDEO
            )
            guard videoStreams.isEmpty else {
                throw HLSVODMediaPumpError
                    .audioRenditionContainsVideo(
                        renditionOrdinal:
                            renditionOrdinal,
                        inputSegmentIndex:
                            inputSegmentIndex
                    )
            }
            let audioStreams = try Self.streamIndices(
                demuxer: demuxer,
                mediaType: AVMEDIA_TYPE_AUDIO
            )
            guard audioStreams.count == 1,
                  let stream = demuxer.stream(
                    at: audioStreams[0]
                  ) else {
                throw HLSVODMediaPumpError
                    .audioStreamCount(
                        renditionOrdinal:
                            renditionOrdinal,
                        inputSegmentIndex:
                            inputSegmentIndex,
                        count: audioStreams.count
                    )
            }
            let rendition =
                audioRenditions[renditionOrdinal]
            guard AudioStreamContract(stream: stream)
                    == rendition.contract else {
                throw HLSVODMediaPumpError
                    .audioContractChanged(
                        renditionOrdinal:
                            renditionOrdinal,
                        inputSegmentIndex:
                            inputSegmentIndex
                    )
            }
            let segmentStart = try Self.startTime(
                segments:
                    graph.audioRenditions[
                        renditionOrdinal
                    ].segments,
                index: inputSegmentIndex
            )
            var packetCount = 0
            do {
                while let packet =
                        try demuxer.readPacket() {
                    var packetToFree:
                        UnsafeMutablePointer<AVPacket>? =
                            packet
                    defer {
                        trackedPacketFree(
                            &packetToFree
                        )
                    }
                    guard packet.pointee.stream_index
                        == audioStreams[0] else {
                        continue
                    }
                    try Self.normalize(
                        packet: packet,
                        demuxer: demuxer,
                        streamIndex: audioStreams[0],
                        outputStreamIndex:
                            rendition.writer
                                .sourceStreamIndex,
                        segmentStart: segmentStart,
                        segmentIndex:
                            inputSegmentIndex
                    )
                    try Self.consume(
                        packet: packet,
                        rendition: rendition
                    )
                    packetCount += 1
                }
            } catch let error
                    as HLSVODMediaPumpError {
                throw error
            } catch {
                throw HLSVODMediaPumpError
                    .packetReadFailed
            }
            guard packetCount > 0 else {
                throw HLSVODMediaPumpError
                    .audioPacketMissing(
                        renditionOrdinal:
                            renditionOrdinal,
                        inputSegmentIndex:
                            inputSegmentIndex
                    )
            }
        }

        func finishVideoInput() throws {
            guard !videoInputFinished else { return }
            videoInputFinished = true
            if let videoDecodeSink {
                do {
                    try videoDecodeSink
                        .markEndOfStream()
                } catch {
                    throw HLSVODMediaPumpError
                        .videoSinkFailed(
                            reason:
                                String(
                                    describing: error
                                )
                        )
                }
            }
            if !usesSeparateAudio {
                for rendition in audioRenditions {
                    try finish(rendition)
                }
            }
        }

        func finishAudioInput(
            renditionOrdinal: Int
        ) throws {
            guard usesSeparateAudio,
                  audioRenditions.indices
                    .contains(renditionOrdinal) else {
                return
            }
            try finish(
                audioRenditions[renditionOrdinal]
            )
        }

        func hasProduced(segment index: Int) -> Bool {
            guard highestProducedVideoSegmentIndex
                    >= index else {
                return false
            }
            return audioRenditions.allSatisfy {
                $0.writer
                    .highestFinalizedSegmentIndex
                    >= index
                    && $0.cache.peekURL(
                        index: index
                    ) != nil
            }
        }

        func muxedAudioNeedsInput(
            throughSegment index: Int
        ) -> Bool {
            guard !usesSeparateAudio else {
                return false
            }
            return audioRenditions.contains {
                $0.writer
                    .highestFinalizedSegmentIndex
                    < index
            }
        }

        func audioNeedsInput(
            renditionOrdinal: Int,
            throughSegment index: Int
        ) -> Bool {
            guard usesSeparateAudio,
                  audioRenditions.indices
                    .contains(renditionOrdinal) else {
                return false
            }
            return audioRenditions[
                renditionOrdinal
            ].writer.highestFinalizedSegmentIndex
                < index
        }

        func audioInitSegment(
            renditionOrdinal: Int
        ) -> Data? {
            guard audioRenditions.indices
                .contains(renditionOrdinal) else {
                return nil
            }
            return audioRenditions[
                renditionOrdinal
            ].cache.fetchInit(timeout: 0)
        }

        func audioMediaSegmentURL(
            renditionOrdinal: Int,
            segmentIndex: Int
        ) -> URL? {
            guard audioRenditions.indices
                .contains(renditionOrdinal) else {
                return nil
            }
            return audioRenditions[
                renditionOrdinal
            ].cache.peekURL(index: segmentIndex)
        }

        func audioMediaSegment(
            renditionOrdinal: Int,
            segmentIndex: Int
        ) -> Data? {
            guard audioRenditions.indices
                .contains(renditionOrdinal) else {
                return nil
            }
            return audioRenditions[
                renditionOrdinal
            ].cache.peek(index: segmentIndex)
        }

        func audioSummaries()
            -> [BlackCarrierAudioRenditionSummary]?
        {
            let summaries =
                audioRenditions.compactMap(\.summary)
            guard summaries.count
                    == audioRenditions.count else {
                return nil
            }
            return summaries
        }

        func advanceVideoDecodeDemand(
            to time: CMTime
        ) throws {
            try videoDecodeSink?
                .advanceDecodeDemand(to: time)
        }

        func snapshot() -> WorkerSnapshot {
            WorkerSnapshot(
                highestProducedVideoSegmentIndex:
                    highestProducedVideoSegmentIndex,
                highestFinalizedAudioSegmentIndices:
                    audioRenditions.map {
                        $0.writer
                            .highestFinalizedSegmentIndex
                    },
                videoPacketCount:
                    videoPacketCount,
                audioPacketCounts:
                    audioRenditions.map(
                        \.packetCount
                    )
            )
        }

        func close() {
            guard !isClosed else { return }
            isClosed = true
            audioRenditions.forEach {
                $0.cache.close()
            }
            videoDecodeSink?.close()
        }

        private func requireOpen() throws {
            guard !isClosed else {
                throw HLSVODMediaPumpError.closed
            }
        }

        private func finish(
            _ rendition: AudioRendition
        ) throws {
            guard rendition.summary == nil else {
                return
            }
            do {
                rendition.summary =
                    try rendition.writer.finish()
            } catch let error
                    as BlackCarrierAudioRenditionMuxerError {
                throw HLSVODMediaPumpError
                    .audioMuxerFailed(
                        renditionOrdinal:
                            rendition.metadata.ordinal,
                        error: error
                    )
            } catch let error
                    as BlackCarrierAudioRenditionStoreError {
                throw HLSVODMediaPumpError
                    .audioStoreFailed(
                        renditionOrdinal:
                            rendition.metadata.ordinal,
                        error: error
                    )
            }
        }

        private static func consume(
            packet: UnsafeMutablePointer<AVPacket>,
            rendition: AudioRendition
        ) throws {
            do {
                try rendition.writer.consume(packet)
                rendition.packetCount += 1
            } catch let error
                    as BlackCarrierAudioRenditionMuxerError {
                throw HLSVODMediaPumpError
                    .audioMuxerFailed(
                        renditionOrdinal:
                            rendition.metadata.ordinal,
                        error: error
                    )
            } catch let error
                    as BlackCarrierAudioRenditionStoreError {
                throw HLSVODMediaPumpError
                    .audioStoreFailed(
                        renditionOrdinal:
                            rendition.metadata.ordinal,
                        error: error
                    )
            }
        }

        private static func makeRendition(
            graph: HLSVODResourceGraph,
            metadata: BlackCarrierAudioRenditionMetadata,
            demuxer: Demuxer,
            stream: UnsafeMutablePointer<AVStream>,
            streamIndex: Int32,
            bridgeMode: AudioBridgeMode,
            declaredChannels: String?
        ) throws -> AudioRendition {
            let descriptor =
                try BlackCarrierAudioRenditionMuxer
                    .admissionDescriptor(
                        demuxer: demuxer,
                        audioStreamIndex:
                            streamIndex,
                        bridgeMode: bridgeMode
                    )
            if let declaredChannels,
               declaredChannels
                != descriptor.channelsAttribute {
                throw HLSVODMediaPumpError
                    .audioContractChanged(
                        renditionOrdinal:
                            metadata.ordinal,
                        inputSegmentIndex: 0
                    )
            }
            let cache = SegmentCache(
                forwardWindow:
                    max(1, graph.segments.count),
                backwardWindow:
                    max(1, graph.segments.count)
            )
            do {
                let writer =
                    try BlackCarrierAudioRenditionMuxer
                        .makeWriter(
                            demuxer: demuxer,
                            audioStreamIndex:
                                streamIndex,
                            sourceStartPTS: 0,
                            timeline: graph.timeline,
                            bridgeMode: bridgeMode,
                            sessionDirectory:
                                cache.sessionDir,
                            onInit: {
                                if cache.fetchInit(
                                    timeout: 0
                                ) == nil {
                                    cache.setInit($0)
                                }
                            },
                            onSegment: {
                                timing,
                                stagingPath,
                                bytesWritten in
                                cache.adopt(
                                    index: timing.index,
                                    stagingPath:
                                        stagingPath,
                                    byteCount:
                                        bytesWritten
                                )
                                guard cache.peekURL(
                                    index: timing.index
                                ) != nil else {
                                    throw BlackCarrierAudioRenditionStoreError
                                        .segmentStoreFailed(
                                            trackID:
                                                metadata
                                                    .sourceTrackID,
                                            index:
                                                timing.index
                                        )
                                }
                            }
                        )
                guard writer.descriptor
                        == descriptor else {
                    cache.close()
                    throw HLSVODMediaPumpError
                        .audioContractChanged(
                            renditionOrdinal:
                                metadata.ordinal,
                            inputSegmentIndex: 0
                        )
                }
                return AudioRendition(
                    metadata: metadata,
                    descriptor: descriptor,
                    contract:
                        AudioStreamContract(
                            stream: stream
                        ),
                    cache: cache,
                    writer: writer
                )
            } catch {
                cache.close()
                throw error
            }
        }

        private static func openVideoDemuxer(
            initData: Data?,
            segmentData: Data
        ) throws -> Demuxer {
            let data: Data
            let formatHint: String
            if let initData {
                data = initData + segmentData
                formatHint = "mp4"
            } else {
                data = segmentData
                formatHint = "mpegts"
            }
            return try openDemuxer(
                data: data,
                formatHint: formatHint
            )
        }

        private static func openAudioDemuxer(
            initData: Data?,
            segmentData: Data
        ) throws -> Demuxer {
            let data: Data
            let formatHint: String?
            if let initData {
                data = initData + segmentData
                formatHint = "mp4"
            } else {
                data = segmentData
                formatHint =
                    LiveSegmentFormat.classify(
                        segmentData
                    ) == .mpegts
                    ? "mpegts"
                    : nil
            }
            return try openDemuxer(
                data: data,
                formatHint: formatHint
            )
        }

        private static func openDemuxer(
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
                throw HLSVODMediaPumpError
                    .demuxOpenFailed
            }
        }

        private static func streamIndices(
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
                let parameters =
                    stream.pointee.codecpar!
                guard parameters.pointee.codec_type
                    == mediaType else {
                    continue
                }
                guard parameters.pointee.codec_id
                        != AV_CODEC_ID_NONE,
                      stream.pointee.time_base.num > 0,
                      stream.pointee.time_base.den
                        > 0 else {
                    throw HLSVODMediaPumpError
                        .demuxOpenFailed
                }
                indices.append(Int32(index))
            }
            return indices
        }

        private static func normalize(
            packet: UnsafeMutablePointer<AVPacket>,
            demuxer: Demuxer,
            streamIndex: Int32,
            outputStreamIndex: Int32,
            segmentStart: CMTime,
            segmentIndex: Int
        ) throws {
            guard let stream = demuxer.stream(
                at: streamIndex
            ) else {
                throw HLSVODMediaPumpError
                    .demuxOpenFailed
            }
            let localStart =
                BlackCarrierSourceAxis.sourceStartPTS(
                    demuxer: demuxer,
                    streamIndex: streamIndex
                )
            guard let globalStart =
                    BlackCarrierSourceAxis.streamTicks(
                        for: segmentStart,
                        timeBase:
                            stream.pointee.time_base
                    ) else {
                throw HLSVODMediaPumpError
                    .timestampOverflow(
                        streamIndex:
                            Int(streamIndex),
                        segmentIndex:
                            segmentIndex
                    )
            }
            if packet.pointee.pts == Int64.min,
               packet.pointee.dts == Int64.min {
                throw HLSVODMediaPumpError
                    .timestampMissing(
                        streamIndex:
                            Int(streamIndex),
                        segmentIndex:
                            segmentIndex
                    )
            }
            if packet.pointee.pts != Int64.min {
                packet.pointee.pts = try normalized(
                    packet.pointee.pts,
                    localStart: localStart,
                    globalStart: globalStart,
                    streamIndex: streamIndex,
                    segmentIndex: segmentIndex
                )
            }
            if packet.pointee.dts != Int64.min {
                packet.pointee.dts = try normalized(
                    packet.pointee.dts,
                    localStart: localStart,
                    globalStart: globalStart,
                    streamIndex: streamIndex,
                    segmentIndex: segmentIndex
                )
            }
            packet.pointee.stream_index =
                outputStreamIndex
            packet.pointee.pos = -1
        }

        private static func normalized(
            _ timestamp: Int64,
            localStart: Int64,
            globalStart: Int64,
            streamIndex: Int32,
            segmentIndex: Int
        ) throws -> Int64 {
            let local = timestamp
                .subtractingReportingOverflow(
                    localStart
                )
            let global = local.partialValue
                .addingReportingOverflow(globalStart)
            guard !local.overflow, !global.overflow else {
                throw HLSVODMediaPumpError
                    .timestampOverflow(
                        streamIndex:
                            Int(streamIndex),
                        segmentIndex:
                            segmentIndex
                    )
            }
            return global.partialValue
        }

        private static func startTime(
            segments: [HLSVODSegmentResource],
            index: Int
        ) throws -> CMTime {
            guard segments.indices.contains(index) else {
                throw HLSVODMediaPumpError
                    .targetSegmentOutOfRange(index)
            }
            var ticks: CMTimeValue = 0
            for segment in segments.prefix(index) {
                let addition =
                    ticks.addingReportingOverflow(
                        segment.duration.value
                    )
                guard !addition.overflow else {
                    throw HLSVODMediaPumpError
                        .timestampOverflow(
                            streamIndex: 0,
                            segmentIndex: index
                        )
                }
                ticks = addition.partialValue
            }
            return CMTime(
                value: ticks,
                timescale:
                    BlackCarrierProfile.approved
                        .timescale
            )
        }
    }
}
