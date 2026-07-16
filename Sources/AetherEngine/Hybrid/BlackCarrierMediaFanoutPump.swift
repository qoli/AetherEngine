import CoreMedia
import Foundation
import Libavcodec
import Libavformat
import Libavutil

enum BlackCarrierMediaFanoutPumpError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case videoStreamMissing
    case invalidRenditionOrdinal(ordinal: Int)
    case invalidSegmentIndex(index: Int)
    case restartRequiresUserSeek
    case seekIntentSegmentMismatch(expected: Int, actual: Int)
    case demuxSeekFailed(segmentIndex: Int)
    case restartTimelineOffsetUnavailable(trackID: Int)
    case freshDemuxerFactoryMissing
    case analysisSourceFactoryMissing
    case freshDemuxerOpenFailed(reason: String)
    case restartSourceContractMismatch
    case restartTrackContractMismatch
    case generationSuperseded(generation: UInt64)
    case closed
    case demuxFailed(reason: String)
    case videoPacketSinkFailed(reason: String)
    case audioMuxerFailed(
        trackID: Int,
        error: BlackCarrierAudioRenditionMuxerError
    )
    case audioStoreFailed(error: BlackCarrierAudioRenditionStoreError)
    case requestedSegmentUnavailable(index: Int)

    var errorDescription: String? {
        switch self {
        case .videoStreamMissing:
            return "Black carrier media fanout video packet sink requires a real video stream"
        case .invalidRenditionOrdinal(let ordinal):
            return "Black carrier audio rendition ordinal \(ordinal) is unavailable"
        case .invalidSegmentIndex(let index):
            return "Black carrier media fanout segment \(index) is out of range"
        case .restartRequiresUserSeek:
            return "Black carrier media fanout restart requires an explicit user-seek intent"
        case .seekIntentSegmentMismatch(let expected, let actual):
            return "Black carrier seek intent segment \(actual) does not match target segment \(expected)"
        case .demuxSeekFailed(let segmentIndex):
            return "Black carrier demux could not seek to segment \(segmentIndex)"
        case .restartTimelineOffsetUnavailable(let trackID):
            return "Black carrier audio track \(trackID) has no startup timeline offset for restart"
        case .freshDemuxerFactoryMissing:
            return "Black carrier lazy restart requires a fresh-demux factory"
        case .analysisSourceFactoryMissing:
            return "Black carrier audio analysis requires the session-owned source factory"
        case .freshDemuxerOpenFailed(let reason):
            return "Black carrier fresh demux generation could not open: \(reason)"
        case .restartSourceContractMismatch:
            return "Black carrier fresh demux generation changed the admitted source contract"
        case .restartTrackContractMismatch:
            return "Black carrier fresh demux generation changed the admitted track contract"
        case .generationSuperseded(let generation):
            return "Black carrier generation \(generation) was superseded by an explicit seek"
        case .closed:
            return "Black carrier media fanout pump is closed"
        case .demuxFailed(let reason):
            return "Black carrier media fanout demux failed: \(reason)"
        case .videoPacketSinkFailed(let reason):
            return "Black carrier real-video packet sink failed: \(reason)"
        case .audioMuxerFailed(let trackID, let error):
            return "Black carrier audio track \(trackID) failed: \(error.localizedDescription)"
        case .audioStoreFailed(let error):
            return error.localizedDescription
        case .requestedSegmentUnavailable(let index):
            return "Black carrier requested segment \(index) was not produced"
        }
    }
}

enum BlackCarrierMediaFanoutRestartResult: Sendable, Equatable {
    case applied(generation: UInt64, segmentIndex: Int)
    case stale(currentGeneration: UInt64)
}

struct BlackCarrierDemuxContract: Sendable, Equatable {
    let durationMicroseconds: Int64
    let formatStartTime: Int64
    let containerBitRate: Int64

    init(demuxer: Demuxer) {
        durationMicroseconds = Int64(
            (demuxer.duration * 1_000_000).rounded()
        )
        formatStartTime = demuxer.formatStartTime
        containerBitRate = demuxer.bitRate
    }
}

/// Incremental single-demux packet fanout for carrier audio and the future real-video decoder.
///
/// `produce(throughSegment:)` advances only until every audio rendition has finalized the requested
/// segment. The same source demux loop may synchronously hand video packets to `videoPacketSink`, so
/// production does not require a second playback cursor. Calls are serialized; a future provider can
/// safely invoke them from concurrent HLS request threads.
final class BlackCarrierMediaFanoutPump: @unchecked Sendable {
    typealias FreshDemuxerFactory = @Sendable () throws -> Demuxer

    typealias VideoPacketSink = (
        _ packet: UnsafeMutablePointer<AVPacket>
    ) throws -> Void

    private final class Rendition {
        let metadata: BlackCarrierAudioRenditionMetadata
        let cache: SegmentCache
        var writer: BlackCarrierAudioRenditionMuxer.Writer

        init(
            metadata: BlackCarrierAudioRenditionMetadata,
            cache: SegmentCache,
            writer: BlackCarrierAudioRenditionMuxer.Writer
        ) {
            self.metadata = metadata
            self.cache = cache
            self.writer = writer
        }
    }

    let renditionMetadata: [BlackCarrierAudioRenditionMetadata]
    let renditionDescriptors: [BlackCarrierAudioRenditionDescriptor]
    let sourceContract: BlackCarrierDemuxContract

    private var demuxer: Demuxer
    private let freshDemuxerFactory: FreshDemuxerFactory?
    private var sourceFactory: BlackCarrierDemuxSourceFactory?
    private let timeline: BlackCarrierTimeline
    private let bridgeMode: AudioBridgeMode
    private var videoStreamIndex: Int32
    private let videoPacketSink: VideoPacketSink?
    private let hybridVideoDecodeSink: HybridVideoDecodeSink?
    private let videoTimeBaseNumerator: Int32
    private let videoTimeBaseDenominator: Int32
    private let nominalVideoFrameDuration: CMTime
    private let videoSourceStartPTS: Int64
    private let renditions: [Rendition]
    private var renditionsByStream: [
        Int32: Rendition
    ]
    private let lock = NSLock()
    private let restartLock = NSLock()
    private let generationLock = NSLock()
    private let demuxerReferenceLock = NSLock()

    private var summaries: [
        Int: BlackCarrierAudioRenditionSummary
    ] = [:]
    private var terminalError: BlackCarrierMediaFanoutPumpError?
    private var isFinished = false
    private var isClosed = false
    private var generationStartSegmentIndex: Int
    private var currentGeneration: UInt64
    private var requestedRestartGeneration: UInt64?
    private var interruptibleDemuxer: Demuxer
    private var ownsActiveDemuxer = false
    private var videoProductionEnd: CMTime = .invalid

    init(
        demuxer: Demuxer,
        timeline: BlackCarrierTimeline,
        bridgeMode: AudioBridgeMode = .surroundCompat,
        videoStreamIndex: Int32? = nil,
        videoPacketSink: VideoPacketSink? = nil,
        hybridVideoDecodeSink: HybridVideoDecodeSink? = nil,
        initialGeneration: UInt64 = 0,
        freshDemuxerFactory: FreshDemuxerFactory? = nil,
        ownsInitialDemuxer: Bool = false,
        sourceFactory: BlackCarrierDemuxSourceFactory? = nil
    ) throws {
        guard let firstSegmentIndex = timeline.segments.first?.index else {
            throw BlackCarrierMediaFanoutPumpError
                .invalidSegmentIndex(index: 0)
        }
        guard videoPacketSink == nil || hybridVideoDecodeSink == nil else {
            throw BlackCarrierMediaFanoutPumpError.videoPacketSinkFailed(
                reason: "Multiple real-video packet sinks were supplied"
            )
        }
        let resolvedVideoPacketSink: VideoPacketSink? = videoPacketSink
            ?? hybridVideoDecodeSink.map { sink in
                { packet in try sink.consume(packet) }
            }
        let resolvedVideoStreamIndex = videoStreamIndex
            ?? demuxer.videoStreamIndex
        guard resolvedVideoPacketSink == nil || resolvedVideoStreamIndex >= 0 else {
            throw BlackCarrierMediaFanoutPumpError.videoStreamMissing
        }
        if let hybridVideoDecodeSink {
            guard let stream = demuxer.stream(
                at: resolvedVideoStreamIndex
            ) else {
                throw BlackCarrierMediaFanoutPumpError.videoStreamMissing
            }
            do {
                guard try hybridVideoDecodeSink.validate(
                    demuxer: demuxer,
                    stream: stream
                ) else {
                    throw HybridVideoDecodeSinkError.streamContractMismatch
                }
            } catch {
                throw BlackCarrierMediaFanoutPumpError.videoPacketSinkFailed(
                    reason: String(describing: error)
                )
            }
        }
        let videoStream = resolvedVideoPacketSink == nil
            ? nil
            : demuxer.stream(at: resolvedVideoStreamIndex)
        if resolvedVideoPacketSink != nil, videoStream == nil {
            throw BlackCarrierMediaFanoutPumpError.videoStreamMissing
        }
        let tracks = demuxer.audioTrackInfos()
        let metadata = BlackCarrierCompositeProvider.renditionMetadata(
            for: tracks
        )
        var prepared: [Rendition] = []
        do {
            for (track, renditionMetadata) in zip(tracks, metadata) {
                let cache = SegmentCache(
                    forwardWindow: max(1, timeline.segments.count),
                    backwardWindow: max(1, timeline.segments.count)
                )
                do {
                    let streamIndex = Int32(track.id)
                    let writer = try Self.makeWriter(
                        demuxer: demuxer,
                        streamIndex: streamIndex,
                        metadata: renditionMetadata,
                        cache: cache,
                        timeline: timeline,
                        bridgeMode: bridgeMode,
                        startingSegmentIndex: firstSegmentIndex,
                        preserveEncoderPriming: true
                    )
                    prepared.append(Rendition(
                        metadata: renditionMetadata,
                        cache: cache,
                        writer: writer
                    ))
                } catch {
                    cache.close()
                    throw error
                }
            }
        } catch let error as BlackCarrierAudioRenditionMuxerError {
            prepared.forEach { $0.cache.close() }
            let trackID = prepared.count < tracks.count
                ? tracks[prepared.count].id
                : -1
            throw BlackCarrierMediaFanoutPumpError.audioMuxerFailed(
                trackID: trackID,
                error: error
            )
        } catch let error as BlackCarrierAudioRenditionStoreError {
            prepared.forEach { $0.cache.close() }
            throw BlackCarrierMediaFanoutPumpError.audioStoreFailed(
                error: error
            )
        } catch {
            prepared.forEach { $0.cache.close() }
            throw BlackCarrierMediaFanoutPumpError.demuxFailed(
                reason: String(describing: error)
            )
        }

        self.demuxer = demuxer
        self.freshDemuxerFactory = freshDemuxerFactory
        self.sourceFactory = sourceFactory
        self.timeline = timeline
        self.bridgeMode = bridgeMode
        self.videoStreamIndex = resolvedVideoPacketSink == nil
            ? -1
            : resolvedVideoStreamIndex
        self.videoPacketSink = resolvedVideoPacketSink
        self.hybridVideoDecodeSink = hybridVideoDecodeSink
        videoTimeBaseNumerator = videoStream?.pointee.time_base.num ?? 0
        videoTimeBaseDenominator = videoStream?.pointee.time_base.den ?? 0
        nominalVideoFrameDuration = videoStream.map {
            Self.nominalFrameDuration(stream: $0)
        } ?? .invalid
        videoSourceStartPTS = resolvedVideoPacketSink == nil
            ? 0
            : BlackCarrierSourceAxis.sourceStartPTS(
                demuxer: demuxer,
                streamIndex: resolvedVideoStreamIndex
            )
        sourceContract = BlackCarrierDemuxContract(demuxer: demuxer)
        renditionMetadata = metadata
        renditions = prepared
        renditionDescriptors = prepared.map(\.writer.descriptor)
        generationStartSegmentIndex = firstSegmentIndex
        currentGeneration = initialGeneration
        interruptibleDemuxer = demuxer
        ownsActiveDemuxer = ownsInitialDemuxer
        renditionsByStream = Dictionary(
            uniqueKeysWithValues: prepared.map {
                ($0.writer.sourceStreamIndex, $0)
            }
        )

        var keep = Set(renditionsByStream.keys)
        if self.videoStreamIndex >= 0 {
            keep.insert(self.videoStreamIndex)
        }
        demuxer.discardAllStreamsExcept(keep)
    }

    static func makeSeekableVOD(
        source: MediaSource,
        options: LoadOptions,
        timeline: BlackCarrierTimeline,
        bridgeMode: AudioBridgeMode = .surroundCompat,
        videoPacketSink: VideoPacketSink? = nil,
        decodedFrameHandler: HybridVideoDecodeSink.FrameHandler? = nil,
        videoFailureHandler: HybridVideoDecodeSink.FailureHandler? = nil,
        initialGeneration: UInt64 = 0,
        selectTitleID: Int? = nil
    ) throws -> BlackCarrierMediaFanoutPump {
        let sourceFactory = try BlackCarrierDemuxSourceFactory.adopting(
            source: source,
            options: options,
            selectTitleID: selectTitleID
        )
        return try makeSeekableVOD(
            sourceFactory: sourceFactory,
            ownsSourceFactory: true,
            timeline: timeline,
            bridgeMode: bridgeMode,
            videoPacketSink: videoPacketSink,
            decodedFrameHandler: decodedFrameHandler,
            videoFailureHandler: videoFailureHandler,
            initialGeneration: initialGeneration
        )
    }

    static func makeSeekableVOD(
        sourceFactory: BlackCarrierDemuxSourceFactory,
        ownsSourceFactory: Bool,
        timeline: BlackCarrierTimeline,
        bridgeMode: AudioBridgeMode = .surroundCompat,
        videoPacketSink: VideoPacketSink? = nil,
        decodedFrameHandler: HybridVideoDecodeSink.FrameHandler? = nil,
        videoFailureHandler: HybridVideoDecodeSink.FailureHandler? = nil,
        initialGeneration: UInt64 = 0
    ) throws -> BlackCarrierMediaFanoutPump {
        do {
            let demuxer = try sourceFactory.openDemuxer()
            let decodeSink = try decodedFrameHandler.map { handler in
                try HybridVideoDecodeSink(
                    demuxer: demuxer,
                    initialGeneration: initialGeneration,
                    onFrame: handler,
                    onFailure: videoFailureHandler
                )
            }
            do {
                return try BlackCarrierMediaFanoutPump(
                    demuxer: demuxer,
                    timeline: timeline,
                    bridgeMode: bridgeMode,
                    videoStreamIndex: demuxer.videoStreamIndex,
                    videoPacketSink: videoPacketSink,
                    hybridVideoDecodeSink: decodeSink,
                    initialGeneration: initialGeneration,
                    freshDemuxerFactory: {
                        try sourceFactory.openDemuxer()
                    },
                    ownsInitialDemuxer: true,
                    sourceFactory: ownsSourceFactory ? sourceFactory : nil
                )
            } catch {
                decodeSink?.close()
                demuxer.close()
                throw error
            }
        } catch {
            if ownsSourceFactory {
                sourceFactory.close()
            }
            throw error
        }
    }

    deinit {
        close()
    }

    var finished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isFinished
    }

    var generation: UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        return currentGeneration
    }

    var supportsFreshDemuxRestart: Bool {
        freshDemuxerFactory != nil
    }

    var hybridVideoFormat: VideoFormat? {
        hybridVideoDecodeSink?.streamContract.videoFormat
    }

    func restart(
        for intent: HybridSeekIntent
    ) throws -> BlackCarrierMediaFanoutRestartResult {
        guard case .userSeek(
            let target,
            let requestedSegmentIndex,
            let requestedGeneration
        ) = intent else {
            throw BlackCarrierMediaFanoutPumpError.restartRequiresUserSeek
        }

        restartLock.lock()
        defer { restartLock.unlock() }

        generationLock.lock()
        guard requestedGeneration > currentGeneration else {
            let result = BlackCarrierMediaFanoutRestartResult.stale(
                currentGeneration: currentGeneration
            )
            generationLock.unlock()
            return result
        }
        requestedRestartGeneration = requestedGeneration
        generationLock.unlock()

        demuxerReferenceLock.lock()
        let retiringDemuxer = interruptibleDemuxer
        demuxerReferenceLock.unlock()
        retiringDemuxer.markClosed()

        lock.lock()
        var freshDemuxerToClose: Demuxer?
        var retiredDemuxerToClose: Demuxer?
        defer {
            lock.unlock()
            freshDemuxerToClose?.close()
            retiredDemuxerToClose?.close()
        }

        guard !isClosed else {
            clearRequestedRestart()
            throw BlackCarrierMediaFanoutPumpError.closed
        }
        if let terminalError {
            clearRequestedRestart()
            throw terminalError
        }
        guard let freshDemuxerFactory else {
            let error = BlackCarrierMediaFanoutPumpError
                .freshDemuxerFactoryMissing
            failWhileLocked(error)
            throw error
        }
        guard let expectedSegmentIndex = timeline.segmentIndex(
            containing: target
        ) else {
            let error = BlackCarrierMediaFanoutPumpError
                .invalidSegmentIndex(index: requestedSegmentIndex)
            failWhileLocked(error)
            throw error
        }
        guard requestedSegmentIndex == expectedSegmentIndex else {
            let error = BlackCarrierMediaFanoutPumpError
                .seekIntentSegmentMismatch(
                    expected: expectedSegmentIndex,
                    actual: requestedSegmentIndex
                )
            failWhileLocked(error)
            throw error
        }

        do {
            let timelineOffsets = try renditions.map { rendition in
                guard let offset =
                        rendition.writer.presentationTimelineOffset else {
                    throw BlackCarrierMediaFanoutPumpError
                        .restartTimelineOffsetUnavailable(
                            trackID: rendition.metadata.sourceTrackID
                        )
                }
                return offset
            }
            let freshDemuxer: Demuxer
            do {
                freshDemuxer = try freshDemuxerFactory()
            } catch {
                throw BlackCarrierMediaFanoutPumpError
                    .freshDemuxerOpenFailed(
                        reason: String(describing: error)
                    )
            }
            freshDemuxerToClose = freshDemuxer
            guard freshDemuxer !== retiringDemuxer else {
                throw BlackCarrierMediaFanoutPumpError
                    .restartTrackContractMismatch
            }
            guard BlackCarrierDemuxContract(demuxer: freshDemuxer)
                    == sourceContract else {
                throw BlackCarrierMediaFanoutPumpError
                    .restartSourceContractMismatch
            }

            let freshTracks = freshDemuxer.audioTrackInfos()
            let freshMetadata =
                BlackCarrierCompositeProvider.renditionMetadata(
                    for: freshTracks
                )
            guard freshMetadata == renditionMetadata else {
                throw BlackCarrierMediaFanoutPumpError
                    .restartTrackContractMismatch
            }
            let freshVideoStreamIndex: Int32
            if videoPacketSink == nil {
                freshVideoStreamIndex = -1
            } else {
                freshVideoStreamIndex = freshDemuxer.videoStreamIndex
                guard freshVideoStreamIndex >= 0 else {
                    throw BlackCarrierMediaFanoutPumpError.videoStreamMissing
                }
            }

            let segment = timeline.segments[expectedSegmentIndex]
            let videoDecodeRestartAnchor =
                Self.videoDecodeRestartAnchor(
                    demuxer: freshDemuxer,
                    streamIndex: freshVideoStreamIndex,
                    targetTime: segment.startTime
                )
            guard freshDemuxer.seek(
                to: CMTimeGetSeconds(segment.startTime)
            ) else {
                throw BlackCarrierMediaFanoutPumpError
                    .demuxSeekFailed(segmentIndex: expectedSegmentIndex)
            }
            let replacementWriters = try zip(
                zip(renditions, freshTracks),
                timelineOffsets
            ).map { pair, timelineOffset in
                let rendition = pair.0
                let freshTrack = pair.1
                return try Self.makeWriter(
                    demuxer: freshDemuxer,
                    streamIndex: Int32(freshTrack.id),
                    metadata: rendition.metadata,
                    cache: rendition.cache,
                    timeline: timeline,
                    bridgeMode: bridgeMode,
                    startingSegmentIndex: expectedSegmentIndex,
                    preserveEncoderPriming: false,
                    presentationTimelineOffset: timelineOffset,
                    decodeTimestampOffset: timelineOffset,
                    restartTimestampRebaseEnabled: true
                )
            }
            let freshDescriptors = replacementWriters.map(\.descriptor)
            guard freshDescriptors == renditionDescriptors else {
                throw BlackCarrierMediaFanoutPumpError
                    .restartTrackContractMismatch
            }
            if let hybridVideoDecodeSink {
                guard let freshVideoStream = freshDemuxer.stream(
                    at: freshVideoStreamIndex
                ) else {
                    throw BlackCarrierMediaFanoutPumpError.videoStreamMissing
                }
                do {
                    try hybridVideoDecodeSink.beginGeneration(
                        requestedGeneration,
                        targetTime: target,
                        restartDecodeAnchorTime:
                            videoDecodeRestartAnchor,
                        demuxer: freshDemuxer,
                        stream: freshVideoStream
                    )
                } catch {
                    throw BlackCarrierMediaFanoutPumpError
                        .videoPacketSinkFailed(
                            reason: String(describing: error)
                        )
                }
            }
            for (rendition, replacement) in zip(
                renditions,
                replacementWriters
            ) {
                rendition.writer = replacement
            }
            var keep = Set(replacementWriters.map(\.sourceStreamIndex))
            if freshVideoStreamIndex >= 0 {
                keep.insert(freshVideoStreamIndex)
            }
            freshDemuxer.discardAllStreamsExcept(keep)
            renditionsByStream = Dictionary(
                uniqueKeysWithValues: renditions.map {
                    ($0.writer.sourceStreamIndex, $0)
                }
            )
            videoStreamIndex = freshVideoStreamIndex
            summaries.removeAll(keepingCapacity: true)
            isFinished = false
            videoProductionEnd = .invalid
            generationStartSegmentIndex = expectedSegmentIndex
            retiredDemuxerToClose = demuxer
            demuxer = freshDemuxer
            ownsActiveDemuxer = true
            demuxerReferenceLock.lock()
            interruptibleDemuxer = freshDemuxer
            demuxerReferenceLock.unlock()
            freshDemuxerToClose = nil
            generationLock.lock()
            currentGeneration = requestedGeneration
            requestedRestartGeneration = nil
            generationLock.unlock()
            return .applied(
                generation: requestedGeneration,
                segmentIndex: expectedSegmentIndex
            )
        } catch let error as BlackCarrierMediaFanoutPumpError {
            failWhileLocked(error)
            throw error
        } catch let error as BlackCarrierAudioRenditionMuxerError {
            let trackID = renditions.first?.metadata.sourceTrackID ?? -1
            let typed = BlackCarrierMediaFanoutPumpError.audioMuxerFailed(
                trackID: trackID,
                error: error
            )
            failWhileLocked(typed)
            throw typed
        } catch let error as BlackCarrierAudioRenditionStoreError {
            let typed = BlackCarrierMediaFanoutPumpError.audioStoreFailed(
                error: error
            )
            failWhileLocked(typed)
            throw typed
        } catch {
            let typed = BlackCarrierMediaFanoutPumpError.demuxFailed(
                reason: String(describing: error)
            )
            failWhileLocked(typed)
            throw typed
        }
    }

    func produce(throughSegment index: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        let operationGeneration = generationSnapshot()

        guard !isClosed else {
            throw BlackCarrierMediaFanoutPumpError.closed
        }
        if let terminalError {
            throw terminalError
        }
        if let videoError = hybridVideoDecodeSink?.failure {
            let typed = BlackCarrierMediaFanoutPumpError
                .videoPacketSinkFailed(
                    reason: videoError.localizedDescription
                )
            fail(typed)
            throw typed
        }
        guard timeline.segments.indices.contains(index) else {
            throw BlackCarrierMediaFanoutPumpError.invalidSegmentIndex(
                index: index
            )
        }
        if index < generationStartSegmentIndex {
            guard cachedSegmentExists(index) else {
                throw BlackCarrierMediaFanoutPumpError
                    .requestedSegmentUnavailable(index: index)
            }
            return
        }
        if hasSegment(index) {
            return
        }

        do {
            while !hasSegment(index), !isFinished {
                try throwIfVideoDecoderFailed()
                guard let packet = try demuxer.readPacket() else {
                    if isGenerationSuperseded(operationGeneration) {
                        throw BlackCarrierMediaFanoutPumpError
                            .generationSuperseded(
                                generation: operationGeneration
                            )
                    }
                    try finishWriters()
                    break
                }
                var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
                defer { trackedPacketFree(&packetToFree) }

                if let rendition = renditionsByStream[
                    packet.pointee.stream_index
                ] {
                    do {
                        try rendition.writer.consume(packet)
                    } catch let error as BlackCarrierAudioRenditionMuxerError {
                        throw BlackCarrierMediaFanoutPumpError.audioMuxerFailed(
                            trackID: rendition.metadata.sourceTrackID,
                            error: error
                        )
                    } catch let error as BlackCarrierAudioRenditionStoreError {
                        throw BlackCarrierMediaFanoutPumpError.audioStoreFailed(
                            error: error
                        )
                    }
                } else if packet.pointee.stream_index == videoStreamIndex,
                          let videoPacketSink {
                    do {
                        try videoPacketSink(packet)
                        updateVideoProductionEnd(packet)
                    } catch {
                        throw BlackCarrierMediaFanoutPumpError
                            .videoPacketSinkFailed(
                                reason: String(describing: error)
                            )
                    }
                }
            }
            try throwIfVideoDecoderFailed()
            guard hasSegment(index) else {
                throw BlackCarrierMediaFanoutPumpError
                    .requestedSegmentUnavailable(index: index)
            }
        } catch let error as BlackCarrierMediaFanoutPumpError {
            if isGenerationSuperseded(operationGeneration) {
                throw BlackCarrierMediaFanoutPumpError
                    .generationSuperseded(
                        generation: operationGeneration
                    )
            }
            fail(error)
            throw error
        } catch {
            if isGenerationSuperseded(operationGeneration) {
                throw BlackCarrierMediaFanoutPumpError
                    .generationSuperseded(
                        generation: operationGeneration
                    )
            }
            let typed = BlackCarrierMediaFanoutPumpError.demuxFailed(
                reason: String(describing: error)
            )
            fail(typed)
            throw typed
        }
    }

    func initSegment(ordinal: Int) throws -> Data? {
        guard renditionMetadata.indices.contains(ordinal) else {
            throw BlackCarrierMediaFanoutPumpError.invalidRenditionOrdinal(
                ordinal: ordinal
            )
        }
        if let cached = peekInitSegment(ordinal: ordinal) {
            return cached
        }
        try produce(throughSegment: 0)
        lock.lock()
        defer { lock.unlock() }
        return rendition(at: ordinal)?.cache.fetchInit(timeout: 0)
    }

    func mediaSegmentURL(
        ordinal: Int,
        index: Int
    ) throws -> URL? {
        guard renditionMetadata.indices.contains(ordinal) else {
            throw BlackCarrierMediaFanoutPumpError.invalidRenditionOrdinal(
                ordinal: ordinal
            )
        }
        try produce(throughSegment: index)
        lock.lock()
        defer { lock.unlock() }
        return rendition(at: ordinal)?.cache.peekURL(index: index)
    }

    func mediaSegment(
        ordinal: Int,
        index: Int
    ) throws -> Data? {
        guard renditionMetadata.indices.contains(ordinal) else {
            throw BlackCarrierMediaFanoutPumpError.invalidRenditionOrdinal(
                ordinal: ordinal
            )
        }
        try produce(throughSegment: index)
        lock.lock()
        defer { lock.unlock() }
        return rendition(at: ordinal)?.cache.peek(index: index)
    }

    func summary(
        ordinal: Int
    ) -> BlackCarrierAudioRenditionSummary? {
        lock.lock()
        defer { lock.unlock() }
        return summaries[ordinal]
    }

    func observedAudioBandwidthSegmentSamples()
        -> [[BlackCarrierBandwidthSegmentSample]]
    {
        lock.lock()
        defer { lock.unlock() }
        return renditions.map {
            $0.writer.observedBandwidthSegmentSamples
        }
    }

    func carrierBandwidthTelemetry(
        videoSamples:
            [BlackCarrierBandwidthSegmentSample]
    ) -> AetherHybridCarrierBandwidthTelemetry {
        lock.lock()
        defer { lock.unlock() }
        return BlackCarrierBandwidthTelemetryCalculator
            .calculate(
                timeline: timeline,
                videoSamples: videoSamples,
                audioSamples: renditions.map {
                    $0.writer
                        .observedBandwidthSegmentSamples
                }
            )
    }

    func advanceVideoDecodeDemand(to time: CMTime) throws {
        guard let hybridVideoDecodeSink else { return }
        do {
            try hybridVideoDecodeSink.advanceDecodeDemand(to: time)
        } catch {
            let typed = BlackCarrierMediaFanoutPumpError
                .videoPacketSinkFailed(
                    reason: String(describing: error)
                )
            failAfterUnlock(typed)
            throw typed
        }
    }

    func finishStores() throws -> [BlackCarrierAudioRenditionStore] {
        guard let lastIndex = timeline.segments.indices.last else {
            throw BlackCarrierMediaFanoutPumpError.invalidSegmentIndex(
                index: 0
            )
        }
        try produce(throughSegment: lastIndex)

        lock.lock()
        guard !isClosed else {
            lock.unlock()
            throw BlackCarrierMediaFanoutPumpError.closed
        }
        do {
            let stores = try renditions.map { rendition in
                guard let summary = summaries[
                    rendition.metadata.ordinal
                ] else {
                    throw BlackCarrierMediaFanoutPumpError
                        .requestedSegmentUnavailable(index: lastIndex)
                }
                return try BlackCarrierAudioRenditionStore(
                    metadata: rendition.metadata,
                    summary: summary,
                    cache: rendition.cache,
                    timeline: timeline
                )
            }
            isClosed = true
            let demuxerToClose = ownsActiveDemuxer ? demuxer : nil
            ownsActiveDemuxer = false
            let sourceFactoryToClose = sourceFactory
            sourceFactory = nil
            lock.unlock()
            demuxerToClose?.close()
            hybridVideoDecodeSink?.close()
            sourceFactoryToClose?.close()
            return stores
        } catch let error as BlackCarrierMediaFanoutPumpError {
            lock.unlock()
            failAfterUnlock(error)
            throw error
        } catch let error as BlackCarrierAudioRenditionStoreError {
            let typed = BlackCarrierMediaFanoutPumpError.audioStoreFailed(
                error: error
            )
            lock.unlock()
            failAfterUnlock(typed)
            throw typed
        } catch {
            let typed = BlackCarrierMediaFanoutPumpError.demuxFailed(
                reason: String(describing: error)
            )
            lock.unlock()
            failAfterUnlock(typed)
            throw typed
        }
    }

    func peekInitSegment(ordinal: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return rendition(at: ordinal)?.cache.fetchInit(timeout: 0)
    }

    func peekMediaSegmentURL(
        ordinal: Int,
        index: Int
    ) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return rendition(at: ordinal)?.cache.peekURL(index: index)
    }

    func makeAudioAnalysisInput() throws -> AudioAnalysisInput {
        let factory: BlackCarrierDemuxSourceFactory
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            throw BlackCarrierMediaFanoutPumpError.closed
        }
        guard let sourceFactory else {
            lock.unlock()
            throw BlackCarrierMediaFanoutPumpError
                .analysisSourceFactoryMissing
        }
        factory = sourceFactory
        lock.unlock()
        return try factory.makeAudioAnalysisInput()
    }

    func close() {
        demuxerReferenceLock.lock()
        let activeDemuxer = interruptibleDemuxer
        demuxerReferenceLock.unlock()
        activeDemuxer.markClosed()

        lock.lock()
        let caches: [SegmentCache]
        if isClosed {
            caches = []
        } else {
            isClosed = true
            caches = renditions.map(\.cache)
        }
        let demuxerToClose = ownsActiveDemuxer ? demuxer : nil
        ownsActiveDemuxer = false
        let sourceFactoryToClose = sourceFactory
        sourceFactory = nil
        clearRequestedRestart()
        lock.unlock()
        caches.forEach { $0.close() }
        demuxerToClose?.close()
        hybridVideoDecodeSink?.close()
        sourceFactoryToClose?.close()
    }

    private func finishWriters() throws {
        guard !isFinished else { return }
        if let hybridVideoDecodeSink {
            do {
                try hybridVideoDecodeSink.markEndOfStream()
            } catch {
                throw BlackCarrierMediaFanoutPumpError.videoPacketSinkFailed(
                    reason: String(describing: error)
                )
            }
        }
        for rendition in renditions {
            do {
                summaries[rendition.metadata.ordinal] =
                    try rendition.writer.finish()
            } catch let error as BlackCarrierAudioRenditionMuxerError {
                throw BlackCarrierMediaFanoutPumpError.audioMuxerFailed(
                    trackID: rendition.metadata.sourceTrackID,
                    error: error
                )
            } catch let error as BlackCarrierAudioRenditionStoreError {
                throw BlackCarrierMediaFanoutPumpError.audioStoreFailed(
                    error: error
                )
            }
        }
        isFinished = true
    }

    private func hasSegment(_ index: Int) -> Bool {
        let audioReady = renditions.allSatisfy {
            $0.writer.highestFinalizedSegmentIndex >= index
                && $0.cache.peekURL(index: index) != nil
        }
        guard audioReady else { return false }
        guard videoSourceCoversSegment(index) else { return false }
        return hybridVideoDecodeSink?.isTargetFrameReady ?? true
    }

    private func videoSourceCoversSegment(_ index: Int) -> Bool {
        guard videoPacketSink != nil else { return true }
        guard timeline.segments.indices.contains(index) else { return false }
        if isFinished {
            return true
        }
        guard videoProductionEnd.isValid,
              videoProductionEnd.isNumeric else {
            return false
        }
        let segment = timeline.segments[index]
        let segmentEnd = CMTimeAdd(
            segment.startTime,
            segment.duration
        )
        return CMTimeCompare(videoProductionEnd, segmentEnd) >= 0
    }

    private func updateVideoProductionEnd(
        _ packet: UnsafeMutablePointer<AVPacket>
    ) {
        guard videoTimeBaseNumerator > 0,
              videoTimeBaseDenominator > 0 else {
            return
        }
        let timestamp = packet.pointee.pts != Int64.min
            ? packet.pointee.pts
            : packet.pointee.dts
        guard timestamp != Int64.min else { return }
        let start = BlackCarrierSourceAxis.timelineTime(
            timestamp: timestamp,
            sourceStartPTS: videoSourceStartPTS,
            timeBase: AVRational(
                num: videoTimeBaseNumerator,
                den: videoTimeBaseDenominator
            )
        )
        let duration = packet.pointee.duration > 0
            ? CMTime(
                value: packet.pointee.duration
                    * Int64(videoTimeBaseNumerator),
                timescale: videoTimeBaseDenominator
            )
            : nominalVideoFrameDuration
        let end = duration.isValid
            && duration.isNumeric
            && CMTimeCompare(duration, .zero) > 0
            ? CMTimeAdd(start, duration)
            : start
        if !videoProductionEnd.isValid
            || !videoProductionEnd.isNumeric
            || CMTimeCompare(end, videoProductionEnd) > 0 {
            videoProductionEnd = end
        }
    }

    private func throwIfVideoDecoderFailed() throws {
        guard let error = hybridVideoDecodeSink?.failure else {
            return
        }
        throw BlackCarrierMediaFanoutPumpError.videoPacketSinkFailed(
            reason: error.localizedDescription
        )
    }

    private func cachedSegmentExists(_ index: Int) -> Bool {
        renditions.allSatisfy {
            $0.cache.peekURL(index: index) != nil
        }
    }

    private func rendition(at ordinal: Int) -> Rendition? {
        guard renditions.indices.contains(ordinal) else { return nil }
        return renditions[ordinal]
    }

    private func fail(_ error: BlackCarrierMediaFanoutPumpError) {
        terminalError = error
        renditions.forEach { $0.cache.close() }
    }

    private func failWhileLocked(
        _ error: BlackCarrierMediaFanoutPumpError
    ) {
        terminalError = error
        isClosed = true
        clearRequestedRestart()
        renditions.forEach { $0.cache.close() }
    }

    private func failAfterUnlock(
        _ error: BlackCarrierMediaFanoutPumpError
    ) {
        lock.lock()
        terminalError = error
        isClosed = true
        let caches = renditions.map(\.cache)
        lock.unlock()
        caches.forEach { $0.close() }
    }

    private func generationSnapshot() -> UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        return currentGeneration
    }

    private func isGenerationSuperseded(
        _ generation: UInt64
    ) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        if let requestedRestartGeneration {
            return requestedRestartGeneration > generation
        }
        return currentGeneration > generation
    }

    private func clearRequestedRestart() {
        generationLock.lock()
        requestedRestartGeneration = nil
        generationLock.unlock()
    }

    private static func makeWriter(
        demuxer: Demuxer,
        streamIndex: Int32,
        metadata: BlackCarrierAudioRenditionMetadata,
        cache: SegmentCache,
        timeline: BlackCarrierTimeline,
        bridgeMode: AudioBridgeMode,
        startingSegmentIndex: Int,
        preserveEncoderPriming: Bool,
        presentationTimelineOffset: Int64? = nil,
        decodeTimestampOffset: Int64 = 0,
        restartTimestampRebaseEnabled: Bool = false
    ) throws -> BlackCarrierAudioRenditionMuxer.Writer {
        try BlackCarrierAudioRenditionMuxer.makeWriter(
            demuxer: demuxer,
            audioStreamIndex: streamIndex,
            sourceStartPTS: BlackCarrierSourceAxis.sourceStartPTS(
                demuxer: demuxer,
                streamIndex: streamIndex
            ),
            timeline: timeline,
            bridgeMode: bridgeMode,
            startingSegmentIndex: startingSegmentIndex,
            preserveEncoderPriming: preserveEncoderPriming,
            presentationTimelineOffset: presentationTimelineOffset,
            decodeTimestampOffset: decodeTimestampOffset,
            restartTimestampRebaseEnabled:
                restartTimestampRebaseEnabled,
            sessionDirectory: cache.sessionDir,
            onInit: {
                if cache.fetchInit(timeout: 0) == nil {
                    cache.setInit($0)
                }
            },
            onSegment: { timing, stagingPath, bytesWritten in
                cache.adopt(
                    index: timing.index,
                    stagingPath: stagingPath,
                    byteCount: bytesWritten
                )
                guard cache.peekURL(index: timing.index) != nil else {
                    throw BlackCarrierAudioRenditionStoreError
                        .segmentStoreFailed(
                            trackID: metadata.sourceTrackID,
                            index: timing.index
                        )
                }
            }
        )
    }

    private static func nominalFrameDuration(
        stream: UnsafeMutablePointer<AVStream>
    ) -> CMTime {
        let frameRate = stream.pointee.avg_frame_rate.den > 0
            && stream.pointee.avg_frame_rate.num > 0
            ? stream.pointee.avg_frame_rate
            : stream.pointee.r_frame_rate
        guard frameRate.num > 0, frameRate.den > 0 else {
            return .invalid
        }
        return CMTime(
            value: Int64(frameRate.den),
            timescale: frameRate.num
        )
    }

    private static func videoDecodeRestartAnchor(
        demuxer: Demuxer,
        streamIndex: Int32,
        targetTime: CMTime
    ) -> CMTime? {
        guard streamIndex >= 0,
              let stream = demuxer.stream(at: streamIndex) else {
            return nil
        }
        let sourceStartPTS =
            BlackCarrierSourceAxis.sourceStartPTS(
                demuxer: demuxer,
                streamIndex: streamIndex
            )
        let timeBase = stream.pointee.time_base
        return demuxer.indexedKeyframes(
            streamIndex: streamIndex
        )
        .lazy
        .map {
            BlackCarrierSourceAxis.timelineTime(
                timestamp: $0,
                sourceStartPTS: sourceStartPTS,
                timeBase: timeBase
            )
        }
        .filter {
            $0.isValid
                && $0.isNumeric
                && CMTimeCompare($0, .zero) >= 0
                && CMTimeCompare($0, targetTime) <= 0
        }
        .max(by: {
            CMTimeCompare($0, $1) < 0
        })
    }
}
