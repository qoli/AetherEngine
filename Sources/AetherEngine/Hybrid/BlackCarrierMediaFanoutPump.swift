import CoreMedia
import Foundation
import Libavcodec
import Libavutil

enum BlackCarrierMediaFanoutPumpError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case audioTracksMissing
    case videoStreamMissing
    case invalidRenditionOrdinal(ordinal: Int)
    case invalidSegmentIndex(index: Int)
    case restartRequiresUserSeek
    case seekIntentSegmentMismatch(expected: Int, actual: Int)
    case demuxSeekFailed(segmentIndex: Int)
    case restartTimelineOffsetUnavailable(trackID: Int)
    case freshDemuxerFactoryMissing
    case freshDemuxerOpenFailed(reason: String)
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
        case .audioTracksMissing:
            return "Black carrier media fanout requires at least one real audio track"
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
        case .freshDemuxerOpenFailed(let reason):
            return "Black carrier fresh demux generation could not open: \(reason)"
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

    private var demuxer: Demuxer
    private let freshDemuxerFactory: FreshDemuxerFactory?
    private let timeline: BlackCarrierTimeline
    private let bridgeMode: AudioBridgeMode
    private var videoStreamIndex: Int32
    private let videoPacketSink: VideoPacketSink?
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

    init(
        demuxer: Demuxer,
        timeline: BlackCarrierTimeline,
        bridgeMode: AudioBridgeMode = .surroundCompat,
        videoStreamIndex: Int32? = nil,
        videoPacketSink: VideoPacketSink? = nil,
        initialGeneration: UInt64 = 0,
        freshDemuxerFactory: FreshDemuxerFactory? = nil
    ) throws {
        guard let firstSegmentIndex = timeline.segments.first?.index else {
            throw BlackCarrierMediaFanoutPumpError
                .invalidSegmentIndex(index: 0)
        }
        let resolvedVideoStreamIndex = videoStreamIndex
            ?? demuxer.videoStreamIndex
        guard videoPacketSink == nil || resolvedVideoStreamIndex >= 0 else {
            throw BlackCarrierMediaFanoutPumpError.videoStreamMissing
        }
        let tracks = demuxer.audioTrackInfos()
        guard !tracks.isEmpty else {
            throw BlackCarrierMediaFanoutPumpError.audioTracksMissing
        }
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
        self.timeline = timeline
        self.bridgeMode = bridgeMode
        self.videoStreamIndex = videoPacketSink == nil
            ? -1
            : resolvedVideoStreamIndex
        self.videoPacketSink = videoPacketSink
        renditionMetadata = metadata
        renditions = prepared
        renditionDescriptors = prepared.map(\.writer.descriptor)
        generationStartSegmentIndex = firstSegmentIndex
        currentGeneration = initialGeneration
        interruptibleDemuxer = demuxer
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
                    } catch {
                        throw BlackCarrierMediaFanoutPumpError
                            .videoPacketSinkFailed(
                                reason: String(describing: error)
                            )
                    }
                }
            }
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
            lock.unlock()
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

    func close() {
        demuxerReferenceLock.lock()
        let activeDemuxer = interruptibleDemuxer
        demuxerReferenceLock.unlock()
        activeDemuxer.markClosed()

        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        let caches = renditions.map(\.cache)
        let demuxerToClose = ownsActiveDemuxer ? demuxer : nil
        ownsActiveDemuxer = false
        clearRequestedRestart()
        lock.unlock()
        caches.forEach { $0.close() }
        demuxerToClose?.close()
    }

    private func finishWriters() throws {
        guard !isFinished else { return }
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
        renditions.allSatisfy {
            $0.writer.highestFinalizedSegmentIndex >= index
                && $0.cache.peekURL(index: index) != nil
        }
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

    private static func sourceStartPTS(
        demuxer: Demuxer,
        streamIndex: Int32
    ) -> Int64 {
        guard let stream = demuxer.stream(at: streamIndex) else { return 0 }
        let formatStart = demuxer.formatStartTime
        if formatStart != Int64.min {
            return av_rescale_q(
                formatStart,
                AVRational(num: 1, den: AV_TIME_BASE),
                stream.pointee.time_base
            )
        }
        let videoStreamIndex = demuxer.videoStreamIndex
        if videoStreamIndex >= 0,
           let videoStream = demuxer.stream(at: videoStreamIndex),
           videoStream.pointee.start_time != Int64.min {
            return av_rescale_q(
                videoStream.pointee.start_time,
                videoStream.pointee.time_base,
                stream.pointee.time_base
            )
        }
        return stream.pointee.start_time == Int64.min
            ? 0
            : stream.pointee.start_time
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
            sourceStartPTS: sourceStartPTS(
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
}
