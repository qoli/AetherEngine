import Foundation
import AVFAudio
import Libavcodec

/// A fresh source owned by one analysis session. URL analysis intentionally opens its own demuxer; it never
/// observes or moves the playback demuxer's cursor. A custom source must already be an independent clone.
enum AudioAnalysisInput: Sendable {
    case url(URL, httpHeaders: [String: String])
    case reader(IOReader, formatHint: String?)
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
        defer { session.closeResources() }
        do {
            // Opening/probing a URL reader consumes source bytes. Do not do it merely because a host created a
            // stream and then abandoned it; the first `next()` is the first unit of demand for the entire path.
            try await session.gate.waitForDemand()
            try session.throwIfCancelled()
            switch input {
            case .url(let url, let httpHeaders):
                try session.demuxer.open(url: url, extraHeaders: httpHeaders, isLive: false)
            case .reader(let reader, let formatHint):
                session.attachOwnedReader(reader)
                try session.demuxer.open(reader: reader, formatHint: formatHint, isLive: false)
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
