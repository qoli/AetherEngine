import CoreMedia
import Foundation
import AVFAudio
import Libavcodec
import Libavformat
import Libavutil

/// A fresh source owned by one analysis session. URL analysis intentionally opens its own demuxer; it never
/// observes or moves the playback demuxer's cursor. A custom source must already be an independent clone.
enum AudioAnalysisInput: Sendable {
    case url(
        URL,
        httpHeaders: [String: String],
        sourceByteStore: SourceByteStore?
    )
    case reader(IOReader, formatHint: String?)
    case hlsVOD(HLSVODAudioAnalysisInput)
}

/// Thread-safe lifecycle handle for one independent analysis cursor.
///
/// `cancel()` is synchronous because it is also called during `AetherEngine.stopInternal()`. The actor gate
/// receives the terminal state asynchronously while `Demuxer.markClosed()` and `IOReader.cancel()` immediately
/// unblock any C/IO read that is currently in progress.
final class AudioAnalysisSession: @unchecked Sendable {
    let id = UUID()
    let gate = AudioAnalysisDemandGate()
    let demuxer = Demuxer()

    private let lock = NSLock()
    private var cancelled = false
    private var ownedReader: IOReader?
    private var task: Task<Void, Never>?

    func install(task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func attachOwnedReader(_ reader: IOReader) {
        lock.lock()
        ownedReader = reader
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { reader.cancel() }
    }

    func throwIfCancelled() throws {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled || Task.isCancelled { throw AudioAnalysisError.cancelled }
    }

    func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let reader = ownedReader
        let task = task
        lock.unlock()

        reader?.cancel()
        demuxer.markClosed()
        task?.cancel()
        Task { await gate.cancel() }
    }

    func closeResources() {
        demuxer.close()
        lock.lock()
        let reader = ownedReader
        ownedReader = nil
        task = nil
        lock.unlock()
        reader?.close()
    }
}

/// Independent FFmpeg reader/decoder for the public audio-analysis stream. This class deliberately has no
/// access to `AetherEngine.audioTapController`, `activeAudioTrackIndex`, or playback clocks.
enum AudioAnalysisRunner {
    /// A single compressed packet can contain several complete PCM chunks. Keeping those already-decoded chunks
    /// is necessary to avoid dropping audio, but the runner never reads another packet while the queue is nonempty.
    /// A malicious packet that exceeds this bound fails loudly instead of growing an unbounded hidden buffer.
    private static let maxPacketDerivedChunks = 32

    static func run(session: AudioAnalysisSession, input: AudioAnalysisInput,
                    request: AudioAnalysisRequest) async {
        if case .reader(let reader, _) = input {
            // Ownership is attached before the first demand wait. This does not read or open the source,
            // but guarantees cancel-before-first-next closes an already-created independent clone.
            session.attachOwnedReader(reader)
        }
        defer { session.closeResources() }
        do {
            // Opening/probing a URL reader consumes source bytes. Do not do it merely because a host created a
            // stream and then abandoned it; the first `next()` is the first unit of demand for the entire path.
            try await session.gate.waitForDemand()
            try session.throwIfCancelled()
            switch input {
            case .url(
                let url,
                let httpHeaders,
                let sourceByteStore
            ):
                try session.demuxer.open(
                    url: url,
                    extraHeaders: httpHeaders,
                    isLive: false,
                    sourceByteStore: sourceByteStore
                )
            case .reader(let reader, let formatHint):
                try session.demuxer.open(reader: reader, formatHint: formatHint, isLive: false)
            case .hlsVOD(let source):
                try await pumpHLS(
                    source: source,
                    session: session,
                    request: request,
                    hasOutstandingDemand: true
                )
                await session.gate.finish()
                return
            }
            try session.throwIfCancelled()

            guard session.demuxer.isSourceSeekable else {
                throw AudioAnalysisError.sourceNotSeekable
            }
            guard session.demuxer.audioTrackInfos().contains(where: { $0.id == request.audioTrackID }),
                  let stream = session.demuxer.stream(at: Int32(request.audioTrackID)),
                  stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO else {
                throw AudioAnalysisError.audioTrackUnavailable(request.audioTrackID)
            }
            guard session.demuxer.seek(to: request.range.lowerBound) else {
                throw AudioAnalysisError.analysisFailed(
                    "cannot seek independent reader to \(request.range.lowerBound)s"
                )
            }
            session.demuxer.discardAllStreamsExcept([Int32(request.audioTrackID)])

            let decoder = AudioTapDecoder()
            defer { decoder.close() }
            do {
                try decoder.open(stream: stream)
            } catch {
                throw AudioAnalysisError.analysisFailed("cannot open audio decoder: \(error)")
            }

            try await pump(decoder: decoder, session: session, request: request,
                           hasOutstandingDemand: true)
            await session.gate.finish()
        } catch let error as AudioAnalysisError {
            await session.gate.fail(error)
        } catch is CancellationError {
            await session.gate.fail(.cancelled)
        } catch {
            await session.gate.fail(.analysisFailed(String(describing: error)))
        }
    }

    private static func pump(decoder: AudioTapDecoder, session: AudioAnalysisSession,
                             request: AudioAnalysisRequest,
                             hasOutstandingDemand: Bool) async throws {
        var pendingChunks: [AudioTapChunk] = []
        var inputEOF = false
        var decoderDrained = false
        var demandIsOutstanding = hasOutstandingDemand
        var expectedSourceSamplePosition = Int64(
            (request.range.lowerBound * AetherEngine.audioAnalysisFormat.sampleRate).rounded()
        )

        while true {
            // A waiting `next()` is the single unit of downstream demand. Work may read several compressed
            // packets solely to fulfil that request, but it stops immediately after producing one PCM buffer.
            if !demandIsOutstanding {
                try await session.gate.waitForDemand()
            }
            try session.throwIfCancelled()

            while true {
                let chunk: AudioTapChunk
                if !pendingChunks.isEmpty {
                    chunk = pendingChunks.removeFirst()
                } else if inputEOF {
                    guard !decoderDrained else {
                        await session.gate.finish()
                        return
                    }
                    decoderDrained = true
                    try append(decoder.drain(), to: &pendingChunks)
                    continue
                } else {
                    guard let packet = try session.demuxer.readPacket() else {
                        inputEOF = true
                        continue
                    }
                    var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
                    defer { trackedPacketFree(&packetToFree) }
                    guard packet.pointee.stream_index == request.audioTrackID else { continue }
                    try append(decoder.decode(packet: packet), to: &pendingChunks)
                    continue
                }

                switch clip(chunk: chunk, to: request.range) {
                case .skip:
                    // This is data preceding the requested boundary; continue using the already-consumed demand.
                    continue
                case .finish:
                    await session.gate.finish()
                    return
                case .emit(let pcm, let sourceSamplePosition):
                    let buffer = AudioAnalysisBuffer(
                        pcm: pcm,
                        sourceSamplePosition: sourceSamplePosition,
                        isDiscontinuous: sourceSamplePosition != expectedSourceSamplePosition
                    )
                    guard await session.gate.yield(buffer) else { return }
                    expectedSourceSamplePosition = sourceSamplePosition + Int64(pcm.frameLength)
                    demandIsOutstanding = false
                    break
                }
                break
            }
        }
    }

    private static func pumpHLS(
        source: HLSVODAudioAnalysisInput,
        session: AudioAnalysisSession,
        request: AudioAnalysisRequest,
        hasOutstandingDemand: Bool
    ) async throws {
        let (track, segments) = try source.track(
            for: request
        )
        var initData: Data?
        var didLoadInit = false
        var segmentCursor = 0
        var segmentDecoder: HLSAudioSegmentDecoder?
        let decoder = AudioTapDecoder()
        defer { decoder.close() }
        var decoderOpened = false
        var decoderDrained = false
        var drainedChunks: [AudioTapChunk] = []
        var demandIsOutstanding = hasOutstandingDemand
        var expectedSourceSamplePosition = Int64(
            (
                request.range.lowerBound
                    * AetherEngine.audioAnalysisFormat.sampleRate
            ).rounded()
        )

        while true {
            if !demandIsOutstanding {
                try await session.gate.waitForDemand()
            }
            try session.throwIfCancelled()

            while true {
                let chunk: AudioTapChunk
                if !drainedChunks.isEmpty {
                    chunk = drainedChunks.removeFirst()
                } else {
                    if segmentDecoder == nil {
                        guard segments.indices.contains(segmentCursor) else {
                            guard !decoderDrained else {
                                await session.gate.finish()
                                return
                            }
                            decoderDrained = true
                            try append(
                                decoder.drain(),
                                to: &drainedChunks
                            )
                            guard !drainedChunks.isEmpty else {
                                throw AudioAnalysisError
                                    .hlsSegmentDecodeFailed(
                                        audioTrackID:
                                            request.audioTrackID,
                                        segmentIndex:
                                            segments.last?.index
                                            ?? 0
                                    )
                            }
                            continue
                        }
                        if !didLoadInit {
                            didLoadInit = true
                            if let key = track.initResourceKey {
                                initData = try await hlsPayload(
                                    source: source,
                                    key: key
                                )
                            }
                        }
                        let segment = segments[segmentCursor]
                        let segmentData = try await hlsPayload(
                            source: source,
                            key: segment.resourceKey
                        )
                        try session.throwIfCancelled()
                        segmentDecoder =
                            try HLSAudioSegmentDecoder(
                                track: track,
                                segment: segment,
                                initData: initData,
                                segmentData: segmentData,
                                decoder: decoder,
                                openDecoder:
                                    !decoderOpened
                            )
                        decoderOpened = true
                    }

                    guard let activeDecoder = segmentDecoder else {
                        throw AudioAnalysisError
                            .hlsSegmentDecodeFailed(
                                audioTrackID:
                                    request.audioTrackID,
                                segmentIndex:
                                    segments[segmentCursor].index
                            )
                    }
                    guard let nextChunk =
                            try activeDecoder.nextChunk() else {
                        segmentDecoder = nil
                        segmentCursor += 1
                        continue
                    }
                    chunk = nextChunk
                }

                switch clip(
                    chunk: chunk,
                    to: request.range
                ) {
                case .skip:
                    continue
                case .finish:
                    await session.gate.finish()
                    return
                case .emit(
                    let pcm,
                    let sourceSamplePosition
                ):
                    let buffer = AudioAnalysisBuffer(
                        pcm: pcm,
                        sourceSamplePosition:
                            sourceSamplePosition,
                        isDiscontinuous:
                            sourceSamplePosition
                            != expectedSourceSamplePosition
                    )
                    guard await session.gate.yield(buffer) else {
                        return
                    }
                    expectedSourceSamplePosition =
                        sourceSamplePosition
                        + Int64(pcm.frameLength)
                    demandIsOutstanding = false
                }
                break
            }
        }
    }

    private static func hlsPayload(
        source: HLSVODAudioAnalysisInput,
        key: HLSVODOriginResourceKey
    ) async throws -> Data {
        do {
            return try await source.loader.payload(
                for: key,
                purpose: .analysis
            ).data
        } catch is CancellationError {
            throw AudioAnalysisError.cancelled
        } catch let error as HLSVODOriginResourceError {
            throw AudioAnalysisError.hlsResourceFailure(
                error.localizedDescription
            )
        } catch {
            throw AudioAnalysisError.hlsResourceFailure(
                String(describing: error)
            )
        }
    }

    private final class HLSAudioSegmentDecoder {
        private let track: HLSVODAudioAnalysisTrack
        private let segment: HLSVODAudioAnalysisSegment
        private let demuxer = Demuxer()
        private let decoder: AudioTapDecoder
        private let streamIndex: Int32
        private var pendingChunks: [AudioTapChunk] = []
        private var inputEOF = false
        private var selectedPacketCount = 0

        init(
            track: HLSVODAudioAnalysisTrack,
            segment: HLSVODAudioAnalysisSegment,
            initData: Data?,
            segmentData: Data,
            decoder: AudioTapDecoder,
            openDecoder: Bool
        ) throws {
            self.track = track
            self.segment = segment
            self.decoder = decoder

            var data = Data(
                capacity:
                    (initData?.count ?? 0)
                    + segmentData.count
            )
            if let initData {
                data.append(initData)
            }
            data.append(segmentData)

            let formatHint: String?
            if initData != nil {
                formatHint = "mp4"
            } else if LiveSegmentFormat.classify(
                segmentData
            ) == .mpegts {
                formatHint = "mpegts"
            } else {
                formatHint = nil
            }
            do {
                try demuxer.open(
                    reader: DataIOReader(data: data),
                    formatHint: formatHint,
                    isLive: false
                )
            } catch {
                throw AudioAnalysisError
                    .hlsSegmentDecodeFailed(
                        audioTrackID:
                            track.sourceTrackID,
                        segmentIndex:
                            segment.index
                    )
            }

            let audioStreams = Self.streamIndices(
                demuxer: demuxer,
                mediaType: AVMEDIA_TYPE_AUDIO
            )
            switch track.layout {
            case .separateRendition:
                let videoStreams = Self.streamIndices(
                    demuxer: demuxer,
                    mediaType: AVMEDIA_TYPE_VIDEO
                )
                guard videoStreams.isEmpty,
                      audioStreams.count == 1 else {
                    throw AudioAnalysisError
                        .hlsAudioContractChanged(
                            audioTrackID:
                                track.sourceTrackID,
                            segmentIndex:
                                segment.index
                        )
                }
                streamIndex = audioStreams[0]
            case .muxedVideo(let audioOrdinal):
                guard audioStreams.indices.contains(
                    audioOrdinal
                ) else {
                    throw AudioAnalysisError
                        .hlsAudioContractChanged(
                            audioTrackID:
                                track.sourceTrackID,
                            segmentIndex:
                                segment.index
                        )
                }
                streamIndex = audioStreams[audioOrdinal]
            }

            guard let stream = demuxer.stream(
                at: streamIndex
            ),
                  HLSVODAudioStreamContract(
                    stream: stream
                  ) == track.contract else {
                throw AudioAnalysisError
                    .hlsAudioContractChanged(
                        audioTrackID:
                            track.sourceTrackID,
                        segmentIndex:
                            segment.index
                    )
            }
            if openDecoder {
                do {
                    try decoder.open(stream: stream)
                } catch {
                    throw AudioAnalysisError
                        .hlsSegmentDecodeFailed(
                            audioTrackID:
                                track.sourceTrackID,
                            segmentIndex:
                                segment.index
                        )
                }
            }
        }

        deinit {
            demuxer.close()
        }

        func nextChunk() throws -> AudioTapChunk? {
            if !pendingChunks.isEmpty {
                return pendingChunks.removeFirst()
            }

            while true {
                if inputEOF {
                    guard selectedPacketCount > 0 else {
                        throw AudioAnalysisError
                            .hlsSegmentDecodeFailed(
                                audioTrackID:
                                    track.sourceTrackID,
                                segmentIndex:
                                    segment.index
                            )
                    }
                    return nil
                }

                let packet: UnsafeMutablePointer<AVPacket>?
                do {
                    packet = try demuxer.readPacket()
                } catch {
                    throw AudioAnalysisError
                        .hlsSegmentDecodeFailed(
                            audioTrackID:
                                track.sourceTrackID,
                            segmentIndex:
                                segment.index
                        )
                }
                guard let packet else {
                    inputEOF = true
                    continue
                }
                var packetToFree:
                    UnsafeMutablePointer<AVPacket>? = packet
                defer {
                    trackedPacketFree(&packetToFree)
                }
                guard packet.pointee.stream_index
                    == streamIndex else {
                    continue
                }
                try normalize(packet)
                selectedPacketCount += 1
                try append(
                    decoder.decode(packet: packet)
                )
                if !pendingChunks.isEmpty {
                    return pendingChunks.removeFirst()
                }
            }
        }

        private func append(
            _ chunks: [AudioTapChunk]
        ) throws {
            guard pendingChunks.count + chunks.count
                    <= AudioAnalysisRunner
                        .maxPacketDerivedChunks else {
                throw AudioAnalysisError.analysisFailed(
                    "one HLS decoder operation produced more than \(AudioAnalysisRunner.maxPacketDerivedChunks) audio buffers"
                )
            }
            pendingChunks.append(contentsOf: chunks)
        }

        private func normalize(
            _ packet: UnsafeMutablePointer<AVPacket>
        ) throws {
            guard let stream = demuxer.stream(
                at: streamIndex
            ) else {
                throw timestampError()
            }
            let localStart =
                BlackCarrierSourceAxis.sourceStartPTS(
                    demuxer: demuxer,
                    streamIndex: streamIndex
                )
            guard let globalStart =
                    BlackCarrierSourceAxis.streamTicks(
                        for: segment.startTime,
                        timeBase:
                            stream.pointee.time_base
                    ),
                  packet.pointee.pts != Int64.min
                    || packet.pointee.dts != Int64.min else {
                throw timestampError()
            }
            if packet.pointee.pts != Int64.min {
                packet.pointee.pts = try normalized(
                    packet.pointee.pts,
                    localStart: localStart,
                    globalStart: globalStart
                )
            }
            if packet.pointee.dts != Int64.min {
                packet.pointee.dts = try normalized(
                    packet.pointee.dts,
                    localStart: localStart,
                    globalStart: globalStart
                )
            }
            packet.pointee.pos = -1
        }

        private func normalized(
            _ timestamp: Int64,
            localStart: Int64,
            globalStart: Int64
        ) throws -> Int64 {
            let local =
                timestamp.subtractingReportingOverflow(
                    localStart
                )
            let global =
                local.partialValue.addingReportingOverflow(
                    globalStart
                )
            guard !local.overflow, !global.overflow else {
                throw timestampError()
            }
            return global.partialValue
        }

        private func timestampError()
            -> AudioAnalysisError
        {
            .hlsTimestampInvalid(
                audioTrackID: track.sourceTrackID,
                segmentIndex: segment.index
            )
        }

        private static func streamIndices(
            demuxer: Demuxer,
            mediaType: AVMediaType
        ) -> [Int32] {
            var indices: [Int32] = []
            for index in 0..<demuxer.streamCount {
                guard let stream = demuxer.stream(
                    at: Int32(index)
                ),
                      let parameters =
                        stream.pointee.codecpar,
                      parameters.pointee.codec_type
                        == mediaType else {
                    continue
                }
                indices.append(Int32(index))
            }
            return indices
        }
    }

    private static func append(_ chunks: [AudioTapChunk], to pending: inout [AudioTapChunk]) throws {
        guard pending.count + chunks.count <= maxPacketDerivedChunks else {
            throw AudioAnalysisError.analysisFailed(
                "one decoder operation produced more than \(maxPacketDerivedChunks) audio buffers"
            )
        }
        pending.append(contentsOf: chunks)
    }

    private enum ClipResult {
        case skip
        case finish
        case emit(AVAudioPCMBuffer, Int64)
    }

    /// Remove samples outside the requested source-time interval. The output position is computed on the fixed
    /// 48 kHz axis after frame-boundary rounding, rather than borrowing AVPlayer's (possibly shifted) time.
    private static func clip(chunk: AudioTapChunk, to range: Range<Double>) -> ClipResult {
        let frameCount = Int(chunk.buffer.frameLength)
        guard frameCount > 0 else { return .skip }
        let sampleRate = AetherEngine.audioAnalysisFormat.sampleRate
        let chunkStart = chunk.ptsSeconds
        let chunkEnd = chunkStart + Double(frameCount) / sampleRate
        if chunkEnd <= range.lowerBound { return .skip }
        if chunkStart >= range.upperBound { return .finish }

        let startFrame = max(0, Int(ceil((range.lowerBound - chunkStart) * sampleRate)))
        let endFrame = min(frameCount, Int(floor((range.upperBound - chunkStart) * sampleRate)))
        guard endFrame > startFrame else { return .skip }
        guard let pcm = AVAudioPCMBuffer(
            pcmFormat: AetherEngine.audioAnalysisFormat,
            frameCapacity: AVAudioFrameCount(endFrame - startFrame)
        ), let source = chunk.buffer.floatChannelData?[0], let target = pcm.floatChannelData?[0] else {
            return .skip
        }
        pcm.frameLength = AVAudioFrameCount(endFrame - startFrame)
        target.update(from: source.advanced(by: startFrame), count: endFrame - startFrame)

        let position = Int64((chunkStart * sampleRate).rounded()) + Int64(startFrame)
        return .emit(pcm, position)
    }
}
