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

/// Incremental single-demux packet fanout for carrier audio and the future real-video decoder.
///
/// `produce(throughSegment:)` advances only until every audio rendition has finalized the requested
/// segment. The same source demux loop may synchronously hand video packets to `videoPacketSink`, so
/// production does not require a second playback cursor. Calls are serialized; a future provider can
/// safely invoke them from concurrent HLS request threads.
final class BlackCarrierMediaFanoutPump: @unchecked Sendable {
    typealias VideoPacketSink = (
        _ packet: UnsafeMutablePointer<AVPacket>
    ) throws -> Void

    private struct Rendition {
        let metadata: BlackCarrierAudioRenditionMetadata
        let cache: SegmentCache
        let writer: BlackCarrierAudioRenditionMuxer.Writer
    }

    let renditionMetadata: [BlackCarrierAudioRenditionMetadata]
    let renditionDescriptors: [BlackCarrierAudioRenditionDescriptor]

    private let demuxer: Demuxer
    private let timeline: BlackCarrierTimeline
    private let videoStreamIndex: Int32
    private let videoPacketSink: VideoPacketSink?
    private let renditions: [Rendition]
    private let renditionsByStream: [
        Int32: Rendition
    ]
    private let lock = NSLock()

    private var summaries: [
        Int: BlackCarrierAudioRenditionSummary
    ] = [:]
    private var terminalError: BlackCarrierMediaFanoutPumpError?
    private var isFinished = false
    private var isClosed = false

    init(
        demuxer: Demuxer,
        timeline: BlackCarrierTimeline,
        bridgeMode: AudioBridgeMode = .surroundCompat,
        videoStreamIndex: Int32? = nil,
        videoPacketSink: VideoPacketSink? = nil
    ) throws {
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
                    let writer = try BlackCarrierAudioRenditionMuxer.makeWriter(
                        demuxer: demuxer,
                        audioStreamIndex: streamIndex,
                        sourceStartPTS: Self.sourceStartPTS(
                            demuxer: demuxer,
                            streamIndex: streamIndex
                        ),
                        timeline: timeline,
                        bridgeMode: bridgeMode,
                        sessionDirectory: cache.sessionDir,
                        onInit: { cache.setInit($0) },
                        onSegment: { timing, stagingPath, bytesWritten in
                            cache.adopt(
                                index: timing.index,
                                stagingPath: stagingPath,
                                byteCount: bytesWritten
                            )
                            guard cache.peekURL(index: timing.index) != nil else {
                                throw BlackCarrierAudioRenditionStoreError
                                    .segmentStoreFailed(
                                        trackID:
                                            renditionMetadata.sourceTrackID,
                                        index: timing.index
                                    )
                            }
                        }
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
        self.timeline = timeline
        self.videoStreamIndex = videoPacketSink == nil
            ? -1
            : resolvedVideoStreamIndex
        self.videoPacketSink = videoPacketSink
        renditionMetadata = metadata
        renditions = prepared
        renditionDescriptors = prepared.map(\.writer.descriptor)
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

    func produce(throughSegment index: Int) throws {
        lock.lock()
        defer { lock.unlock() }

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
        if hasSegment(index) {
            return
        }

        do {
            while !hasSegment(index), !isFinished {
                guard let packet = try demuxer.readPacket() else {
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
            fail(error)
            throw error
        } catch {
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
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        let caches = renditions.map(\.cache)
        lock.unlock()
        caches.forEach { $0.close() }
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
}
