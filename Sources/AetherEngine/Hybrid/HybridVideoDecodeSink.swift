import CoreMedia
import CoreVideo
import Foundation
import Libavcodec
import Libavformat
import Libavutil

struct HybridVideoStreamContract: Sendable, Equatable {
    let codecID: UInt32
    let codedWidth: Int
    let codedHeight: Int
    let codecConfiguration: Data
    let videoFormat: VideoFormat
    let pixelAspectRatioNumerator: Int
    let pixelAspectRatioDenominator: Int
    let rotationDegrees: Int
    let nominalFrameDuration: CMTime
    let packetTimeBaseNumerator: Int32
    let packetTimeBaseDenominator: Int32
    let sourceStartPTS: Int64
    let sourceStartTime: CMTime
    let sourceTimestampTolerance: Int64

    init(
        demuxer: Demuxer,
        stream: UnsafeMutablePointer<AVStream>,
        sourceStartPTSOverride: Int64? = nil
    ) throws {
        let codecParameters = stream.pointee.codecpar.pointee
        codecID = codecParameters.codec_id.rawValue
        codedWidth = Int(codecParameters.width)
        codedHeight = Int(codecParameters.height)
        if let bytes = codecParameters.extradata,
           codecParameters.extradata_size > 0 {
            codecConfiguration = Data(
                bytes: bytes,
                count: Int(codecParameters.extradata_size)
            )
        } else {
            codecConfiguration = Data()
        }
        videoFormat = AetherEngine.detectVideoFormat(stream: stream)

        let parameterSAR = codecParameters.sample_aspect_ratio
        let streamSAR = stream.pointee.sample_aspect_ratio
        let resolvedSAR = parameterSAR.num > 0 && parameterSAR.den > 0
            ? parameterSAR
            : streamSAR
        pixelAspectRatioNumerator = resolvedSAR.num > 0
            ? Int(resolvedSAR.num)
            : 1
        pixelAspectRatioDenominator = resolvedSAR.den > 0
            ? Int(resolvedSAR.den)
            : 1
        rotationDegrees = try Self.rotationDegrees(stream: stream)
        packetTimeBaseNumerator = stream.pointee.time_base.num
        packetTimeBaseDenominator = stream.pointee.time_base.den
        guard packetTimeBaseNumerator > 0,
              packetTimeBaseDenominator > 0 else {
            throw HybridVideoDecodeSinkError.invalidPacketTimeBase
        }
        let resolvedSourceStartPTS =
            sourceStartPTSOverride
            ?? BlackCarrierSourceAxis.sourceStartPTS(
                demuxer: demuxer,
                streamIndex: stream.pointee.index
            )
        let sourceStartValue =
            resolvedSourceStartPTS.multipliedReportingOverflow(
                by: Int64(stream.pointee.time_base.num)
            )
        guard !sourceStartValue.overflow else {
            throw HybridVideoDecodeSinkError.timestampRebaseOverflow
        }
        sourceStartPTS = resolvedSourceStartPTS
        sourceStartTime = CMTime(
            value: sourceStartValue.partialValue,
            timescale: stream.pointee.time_base.den
        )

        let frameRate = stream.pointee.avg_frame_rate.den > 0
            && stream.pointee.avg_frame_rate.num > 0
            ? stream.pointee.avg_frame_rate
            : stream.pointee.r_frame_rate
        if frameRate.num > 0, frameRate.den > 0 {
            nominalFrameDuration = CMTime(
                value: Int64(frameRate.den),
                timescale: frameRate.num
            )
        } else {
            nominalFrameDuration = .invalid
        }
        let timeBase = AVRational(
            num: packetTimeBaseNumerator,
            den: packetTimeBaseDenominator
        )
        let nominalTicks = BlackCarrierSourceAxis.streamTicks(
            for: nominalFrameDuration,
            timeBase: timeBase
        ) ?? 0
        let doubledNominal =
            nominalTicks.multipliedReportingOverflow(by: 2)
        guard !doubledNominal.overflow else {
            throw HybridVideoDecodeSinkError.timestampRebaseOverflow
        }
        let oneTenthSecond = av_rescale_q(
            100_000,
            AVRational(num: 1, den: 1_000_000),
            timeBase
        )
        sourceTimestampTolerance = max(
            1,
            doubledNominal.partialValue,
            oneTenthSecond
        )
    }

    private static func rotationDegrees(
        stream: UnsafeMutablePointer<AVStream>
    ) throws -> Int {
        let parameters = stream.pointee.codecpar.pointee
        let count = Int(parameters.nb_coded_side_data)
        guard count > 0, let sideData = parameters.coded_side_data else {
            return 0
        }
        var matrixBytes: UnsafeMutablePointer<UInt8>?
        for index in 0..<count {
            let item = sideData[index]
            if item.type == AV_PKT_DATA_DISPLAYMATRIX,
               item.size >= MemoryLayout<Int32>.size * 9 {
                matrixBytes = item.data
                break
            }
        }
        guard let matrixBytes else { return 0 }
        let angle = -av_display_rotation_get(
            UnsafeRawPointer(matrixBytes).assumingMemoryBound(to: Int32.self)
        )
        guard angle.isFinite else {
            throw HybridVideoDecodeSinkError.invalidDisplayMatrix
        }
        let rounded = Int(angle.rounded())
        return ((rounded % 360) + 360) % 360
    }
}

enum HybridVideoDecodeSinkError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case videoStreamMissing
    case streamContractMismatch
    case decoderOpenFailed(reason: String)
    case decoderFailed(VideoDecoderError)
    case invalidDisplayMatrix
    case packetCloneFailed
    case packetTimestampMissing
    case invalidPacketTimeBase
    case restartTimestampRebaseAmbiguous(
        generation: UInt64,
        timestamp: Int64
    )
    case timestampRebaseOverflow
    case invalidTargetTime
    case invalidDecodeDemand
    case invalidQueueBounds(bytes: Int, packets: Int)
    case packetQueueOverflow(bytes: Int, packets: Int)
    case closed

    var errorDescription: String? {
        switch self {
        case .videoStreamMissing:
            return "Hybrid video decoder requires a real video stream"
        case .streamContractMismatch:
            return "Hybrid video stream changed across demux generations"
        case .decoderOpenFailed(let reason):
            return "Hybrid video decoder could not open: \(reason)"
        case .decoderFailed(let error):
            return "Hybrid video decoder failed: \(error.localizedDescription)"
        case .invalidDisplayMatrix:
            return "Hybrid video stream has an invalid display matrix"
        case .packetCloneFailed:
            return "Hybrid compressed-video packet could not be retained"
        case .packetTimestampMissing:
            return "Hybrid compressed-video packet has no decode or presentation timestamp"
        case .invalidPacketTimeBase:
            return "Hybrid video stream has an invalid packet time base"
        case .restartTimestampRebaseAmbiguous(
            let generation,
            let timestamp
        ):
            return "Hybrid video generation \(generation) reset near source timestamp \(timestamp) without byte-position evidence"
        case .timestampRebaseOverflow:
            return "Hybrid video timestamp rebase exceeded the source timeline range"
        case .invalidTargetTime:
            return "Hybrid video generation requires a finite non-negative target time"
        case .invalidDecodeDemand:
            return "Hybrid video decode demand must be finite and non-negative"
        case .invalidQueueBounds(let bytes, let packets):
            return "Hybrid compressed-video queue bounds are invalid: \(bytes) bytes / \(packets) packets"
        case .packetQueueOverflow(let bytes, let packets):
            return "Hybrid compressed-video queue exceeded its bound: \(bytes) bytes / \(packets) packets"
        case .closed:
            return "Hybrid video decoder is closed"
        }
    }
}

/// Generation-aware adapter from the shared demux packet fanout to `DecodedVideoFrame`.
///
/// It reuses AetherEngine's hardware HEVC and software codec decoders, but owns the hybrid
/// generation, frame metadata contract and typed terminal failure. Old asynchronous frames finish
/// before a generation switch and retain the old generation number.
final class HybridVideoDecodeSink: @unchecked Sendable {
    typealias FrameHandler = @Sendable (DecodedVideoFrame) -> Void
    typealias FailureHandler = @Sendable (HybridVideoDecodeSinkError) -> Void

    private final class CallbackBox: @unchecked Sendable {
        weak var sink: HybridVideoDecodeSink?
    }

    private struct QueuedPacket {
        let packet: UnsafeMutablePointer<AVPacket>
        let decodeTime: CMTime
        let byteCount: Int
    }

    let streamContract: HybridVideoStreamContract

    private let decoder: any VideoDecodingPipeline
    private let frameHandler: FrameHandler
    private let failureHandler: FailureHandler?
    private let callbackBox = CallbackBox()
    private let lock = NSLock()
    private let operationLock = NSLock()
    private let maximumQueuedBytes: Int
    private let maximumQueuedPackets: Int

    private var generation: UInt64
    private var targetTime: CMTime
    private var targetFrameReady = false
    private var terminalError: HybridVideoDecodeSinkError?
    private var isClosed = false
    private var clockDecodeDemand: CMTime
    private var readinessDecodeLimit: CMTime
    private var queuedPackets: [QueuedPacket] = []
    private var queuedBytes = 0
    private var sourceEnded = false
    private var didFinishDecoder = false
    private var sourceOriginPacketPosition: Int64?
    private var acceptsSourceOriginPacketPosition = true
    private var generationTimestampRebase: Int64? = 0
    private var restartDecodeAnchorPTS: Int64?
    private var restartBeyondSourceOrigin = false

    init(
        demuxer: Demuxer,
        initialGeneration: UInt64,
        initialTargetTime: CMTime = .zero,
        sourceStartPTSOverride: Int64? = nil,
        maximumQueuedBytes: Int = 96 * 1_024 * 1_024,
        maximumQueuedPackets: Int = 8_192,
        onFrame: @escaping FrameHandler,
        onFailure: FailureHandler? = nil
    ) throws {
        guard Self.isValidTimelineTime(initialTargetTime) else {
            throw HybridVideoDecodeSinkError.invalidTargetTime
        }
        guard maximumQueuedBytes > 0, maximumQueuedPackets > 0 else {
            throw HybridVideoDecodeSinkError.invalidQueueBounds(
                bytes: maximumQueuedBytes,
                packets: maximumQueuedPackets
            )
        }
        let videoStreamIndex = demuxer.videoStreamIndex
        guard videoStreamIndex >= 0,
              let stream = demuxer.stream(at: videoStreamIndex),
              let codecParameters = stream.pointee.codecpar else {
            throw HybridVideoDecodeSinkError.videoStreamMissing
        }
        streamContract = try HybridVideoStreamContract(
            demuxer: demuxer,
            stream: stream,
            sourceStartPTSOverride:
                sourceStartPTSOverride
        )
        generation = initialGeneration
        targetTime = initialTargetTime
        clockDecodeDemand = CMTimeAdd(
            initialTargetTime,
            CMTime(seconds: 0.25, preferredTimescale: 600)
        )
        readinessDecodeLimit = CMTimeAdd(
            initialTargetTime,
            CMTime(seconds: 4, preferredTimescale: 600)
        )
        self.maximumQueuedBytes = maximumQueuedBytes
        self.maximumQueuedPackets = maximumQueuedPackets
        frameHandler = onFrame
        failureHandler = onFailure
        decoder = codecParameters.pointee.codec_id == AV_CODEC_ID_HEVC
            ? HardwareVideoDecoder()
            : SoftwareVideoDecoder(threadingMode: .boundedLatency)

        callbackBox.sink = self
        do {
            try decoder.open(stream: stream) {
                [weak callbackBox] pixelBuffer,
                presentationTime,
                duration,
                hdr10PlusT35 in
                callbackBox?.sink?.receiveFrame(
                    pixelBuffer: pixelBuffer,
                    presentationTime: presentationTime,
                    duration: duration,
                    hdr10PlusT35: hdr10PlusT35
                )
            }
        } catch {
            decoder.close()
            throw HybridVideoDecodeSinkError.decoderOpenFailed(
                reason: String(describing: error)
            )
        }
        decoder.onFailure = { [weak callbackBox] error in
            callbackBox?.sink?.recordFailure(.decoderFailed(error))
        }
    }

    deinit {
        close()
    }

    var failure: HybridVideoDecodeSinkError? {
        lock.lock()
        defer { lock.unlock() }
        return terminalError
    }

    var isTargetFrameReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return targetFrameReady
    }

    func validate(
        demuxer: Demuxer,
        stream: UnsafeMutablePointer<AVStream>,
        sourceStartPTSOverride: Int64? = nil
    ) throws -> Bool {
        try HybridVideoStreamContract(
            demuxer: demuxer,
            stream: stream,
            sourceStartPTSOverride:
                sourceStartPTSOverride
        ) == streamContract
    }

    func consume(
        _ packet: UnsafeMutablePointer<AVPacket>
    ) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        try throwIfUnavailable()
        try applyGenerationTimestampRebaseIfNeeded(packet)
        let decodeTime = packetDecodeTime(packet)
        guard decodeTime.isValid, decodeTime.isNumeric else {
            let error = HybridVideoDecodeSinkError.packetTimestampMissing
            recordFailure(error)
            throw error
        }
        if queuedPackets.isEmpty,
           shouldDecode(decodeTime: decodeTime) {
            try decodePacketLocked(packet, decodeTime: decodeTime)
            return
        }
        guard let copy = av_packet_clone(packet) else {
            let error = HybridVideoDecodeSinkError.packetCloneFailed
            recordFailure(error)
            throw error
        }
        let byteCount = max(0, Int(copy.pointee.size))
        queuedPackets.append(QueuedPacket(
            packet: copy,
            decodeTime: decodeTime,
            byteCount: byteCount
        ))
        queuedBytes += byteCount
        guard queuedBytes <= maximumQueuedBytes,
              queuedPackets.count <= maximumQueuedPackets else {
            let error = HybridVideoDecodeSinkError.packetQueueOverflow(
                bytes: queuedBytes,
                packets: queuedPackets.count
            )
            recordFailure(error)
            throw error
        }
        try drainQueuedPacketsLocked()
    }

    func advanceDecodeDemand(to time: CMTime) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        try throwIfUnavailable()
        guard Self.isValidTimelineTime(time) else {
            let error = HybridVideoDecodeSinkError.invalidDecodeDemand
            recordFailure(error)
            throw error
        }
        if CMTimeCompare(time, clockDecodeDemand) > 0 {
            clockDecodeDemand = time
        }
        try drainQueuedPacketsLocked()
        try finishDecoderIfReadyLocked()
    }

    func beginGeneration(
        _ generation: UInt64,
        targetTime: CMTime,
        restartDecodeAnchorTime: CMTime?,
        demuxer: Demuxer,
        stream: UnsafeMutablePointer<AVStream>
    ) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard Self.isValidTimelineTime(targetTime) else {
            let error = HybridVideoDecodeSinkError.invalidTargetTime
            recordFailure(error)
            throw error
        }
        if let restartDecodeAnchorTime {
            guard Self.isValidTimelineTime(restartDecodeAnchorTime),
                  CMTimeCompare(
                    restartDecodeAnchorTime,
                    targetTime
                  ) <= 0 else {
                let error = HybridVideoDecodeSinkError.invalidTargetTime
                recordFailure(error)
                throw error
            }
        }
        guard try validate(
            demuxer: demuxer,
            stream: stream
        ) else {
            let error = HybridVideoDecodeSinkError.streamContractMismatch
            recordFailure(error)
            throw error
        }
        try throwIfUnavailable()
        clearQueuedPacketsLocked()
        decoder.flush()
        try throwIfUnavailable()
        // The hybrid scheduler and presentation gate own seek pre-roll. A frame
        // whose PTS precedes the target may still cover the target by duration;
        // decoder-level PTS skipping would incorrectly discard that frame.
        decoder.skipUntilPTS = nil
        lock.lock()
        self.generation = generation
        self.targetTime = targetTime
        targetFrameReady = false
        lock.unlock()
        clockDecodeDemand = CMTimeAdd(
            targetTime,
            CMTime(seconds: 0.25, preferredTimescale: 600)
        )
        readinessDecodeLimit = CMTimeAdd(
            targetTime,
            CMTime(seconds: 4, preferredTimescale: 600)
        )
        let timeBase = AVRational(
            num: streamContract.packetTimeBaseNumerator,
            den: streamContract.packetTimeBaseDenominator
        )
        if let restartDecodeAnchorTime {
            guard let anchorTicks =
                    BlackCarrierSourceAxis.streamTicks(
                        for: restartDecodeAnchorTime,
                        timeBase: timeBase
                    ) else {
                let error = HybridVideoDecodeSinkError
                    .invalidTargetTime
                recordFailure(error)
                throw error
            }
            restartDecodeAnchorPTS = anchorTicks
        } else {
            restartDecodeAnchorPTS = nil
        }
        restartBeyondSourceOrigin =
            CMTimeCompare(targetTime, .zero) > 0
        generationTimestampRebase = nil
        acceptsSourceOriginPacketPosition = false
        sourceEnded = false
        didFinishDecoder = false
    }

    func markEndOfStream() throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        try throwIfUnavailable()
        sourceEnded = true
        decoder.synchronize()
        try throwIfUnavailable()
        try finishDecoderIfReadyLocked()
    }

    func finish() throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        try throwIfUnavailable()
        while !queuedPackets.isEmpty {
            try decodeFirstQueuedPacketLocked()
        }
        sourceEnded = true
        try finishDecoderIfReadyLocked()
        try throwIfUnavailable()
    }

    func close() {
        operationLock.lock()
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            operationLock.unlock()
            return
        }
        isClosed = true
        lock.unlock()
        clearQueuedPacketsLocked()
        decoder.close()
        operationLock.unlock()
    }

    private func receiveFrame(
        pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        duration: CMTime,
        hdr10PlusT35: Data?
    ) {
        lock.lock()
        guard !isClosed, terminalError == nil else {
            lock.unlock()
            return
        }
        let frameGeneration = generation
        let target = targetTime
        lock.unlock()

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let resolvedDuration = duration.isValid
            && duration.isNumeric
            && CMTimeCompare(duration, .zero) > 0
            ? duration
            : streamContract.nominalFrameDuration
        let videoFormat = hdr10PlusT35 != nil
            && streamContract.videoFormat == .hdr10
            ? VideoFormat.hdr10Plus
            : streamContract.videoFormat
        let normalizedPresentationTime = CMTimeSubtract(
            presentationTime,
            streamContract.sourceStartTime
        )
        guard normalizedPresentationTime.isValid,
              normalizedPresentationTime.isNumeric else {
            recordFailure(.packetTimestampMissing)
            return
        }
        let frame = DecodedVideoFrame(
            pixelBuffer: pixelBuffer,
            presentationTime: normalizedPresentationTime,
            duration: resolvedDuration,
            videoFormat: videoFormat,
            geometry: DecodedVideoFrameGeometry(
                codedWidth: width,
                codedHeight: height,
                cleanAperture: .init(
                    x: 0,
                    y: 0,
                    width: Double(width),
                    height: Double(height)
                ),
                pixelAspectRatioNumerator:
                    streamContract.pixelAspectRatioNumerator,
                pixelAspectRatioDenominator:
                    streamContract.pixelAspectRatioDenominator,
                rotationDegrees: streamContract.rotationDegrees
            ),
            hdr10PlusT35: hdr10PlusT35,
            generation: frameGeneration
        )
        if HybridPresentationReadinessGate.frameIntersectsTargetWindow(
            frame: frame,
            targetTime: target,
            toleranceBefore: CMTime(
                seconds: 0.1,
                preferredTimescale: 600
            ),
            toleranceAfter: CMTime(
                seconds: 0.25,
                preferredTimescale: 600
            )
        ) {
            lock.lock()
            if generation == frameGeneration {
                targetFrameReady = true
            }
            lock.unlock()
        }
        frameHandler(frame)
    }

    private func recordFailure(_ error: HybridVideoDecodeSinkError) {
        lock.lock()
        let isFirst: Bool
        if terminalError == nil, !isClosed {
            terminalError = error
            isFirst = true
        } else {
            isFirst = false
        }
        lock.unlock()
        if isFirst {
            failureHandler?(error)
            EngineLog.emit(
                "[HybridVideoDecodeSink] terminal error: "
                    + error.localizedDescription,
                category: .session
            )
        }
    }

    private func throwIfUnavailable() throws {
        lock.lock()
        let error = terminalError
        let closed = isClosed
        lock.unlock()
        if let error {
            throw error
        }
        if closed {
            throw HybridVideoDecodeSinkError.closed
        }
    }

    private func packetDecodeTime(
        _ packet: UnsafeMutablePointer<AVPacket>
    ) -> CMTime {
        let timestamp = packet.pointee.dts != Int64.min
            ? packet.pointee.dts
            : packet.pointee.pts
        guard timestamp != Int64.min,
              streamContract.packetTimeBaseNumerator > 0,
              streamContract.packetTimeBaseDenominator > 0 else {
            return .invalid
        }
        return BlackCarrierSourceAxis.timelineTime(
            timestamp: timestamp,
            sourceStartPTS: streamContract.sourceStartPTS,
            timeBase: AVRational(
                num: streamContract.packetTimeBaseNumerator,
                den: streamContract.packetTimeBaseDenominator
            )
        )
    }

    private func applyGenerationTimestampRebaseIfNeeded(
        _ packet: UnsafeMutablePointer<AVPacket>
    ) throws {
        if sourceOriginPacketPosition == nil,
           acceptsSourceOriginPacketPosition,
           packet.pointee.pos >= 0 {
            sourceOriginPacketPosition = packet.pointee.pos
        }
        if let generationTimestampRebase {
            try applyTimestampRebase(
                generationTimestampRebase,
                to: packet
            )
            return
        }
        let timestamp = packet.pointee.pts != Int64.min
            ? packet.pointee.pts
            : packet.pointee.dts
        guard timestamp != Int64.min else {
            let error = HybridVideoDecodeSinkError
                .packetTimestampMissing
            recordFailure(error)
            throw error
        }
        let originDelta = timestamp.subtractingReportingOverflow(
            streamContract.sourceStartPTS
        )
        guard !originDelta.overflow,
              originDelta.partialValue != Int64.min else {
            let error = HybridVideoDecodeSinkError
                .timestampRebaseOverflow
            recordFailure(error)
            throw error
        }
        let tolerance = streamContract.sourceTimestampTolerance
        let isNearSourceOrigin =
            abs(originDelta.partialValue) <= tolerance
        let shouldInspectReset =
            restartBeyondSourceOrigin && isNearSourceOrigin
        let rebase: Int64
        if shouldInspectReset {
            guard let sourceOriginPacketPosition,
                  packet.pointee.pos >= 0 else {
                let error = HybridVideoDecodeSinkError
                    .restartTimestampRebaseAmbiguous(
                        generation: generation,
                        timestamp: timestamp
                    )
                recordFailure(error)
                throw error
            }
            if packet.pointee.pos == sourceOriginPacketPosition {
                rebase = 0
            } else {
                guard let restartDecodeAnchorPTS else {
                    let error = HybridVideoDecodeSinkError
                        .restartTimestampRebaseAmbiguous(
                            generation: generation,
                            timestamp: timestamp
                        )
                    recordFailure(error)
                    throw error
                }
                let expected = streamContract.sourceStartPTS
                    .addingReportingOverflow(
                        restartDecodeAnchorPTS
                    )
                let delta = expected.partialValue
                    .subtractingReportingOverflow(timestamp)
                guard !expected.overflow, !delta.overflow else {
                    let error = HybridVideoDecodeSinkError
                        .timestampRebaseOverflow
                    recordFailure(error)
                    throw error
                }
                rebase = delta.partialValue
            }
        } else {
            rebase = 0
        }
        generationTimestampRebase = rebase
        try applyTimestampRebase(rebase, to: packet)
        if rebase != 0 {
            EngineLog.emit(
                "[HybridVideoDecodeSink] restart timestamp rebase "
                    + "generation=\(generation) raw=\(timestamp) "
                    + "anchor=\(restartDecodeAnchorPTS ?? 0) "
                    + "delta=\(rebase)",
                category: .session
            )
        }
    }

    private func applyTimestampRebase(
        _ rebase: Int64,
        to packet: UnsafeMutablePointer<AVPacket>
    ) throws {
        guard rebase != 0 else { return }
        if packet.pointee.pts != Int64.min {
            let value = packet.pointee.pts.addingReportingOverflow(
                rebase
            )
            guard !value.overflow else {
                let error = HybridVideoDecodeSinkError
                    .timestampRebaseOverflow
                recordFailure(error)
                throw error
            }
            packet.pointee.pts = value.partialValue
        }
        if packet.pointee.dts != Int64.min {
            let value = packet.pointee.dts.addingReportingOverflow(
                rebase
            )
            guard !value.overflow else {
                let error = HybridVideoDecodeSinkError
                    .timestampRebaseOverflow
                recordFailure(error)
                throw error
            }
            packet.pointee.dts = value.partialValue
        }
    }

    private func shouldDecode(decodeTime: CMTime) -> Bool {
        guard decodeTime.isValid, decodeTime.isNumeric else { return true }
        lock.lock()
        let demand = targetFrameReady
            ? clockDecodeDemand
            : readinessDecodeLimit
        lock.unlock()
        return CMTimeCompare(decodeTime, demand) <= 0
    }

    private func drainQueuedPacketsLocked() throws {
        while let first = queuedPackets.first,
              shouldDecode(decodeTime: first.decodeTime) {
            try decodeFirstQueuedPacketLocked()
        }
    }

    private func decodeFirstQueuedPacketLocked() throws {
        let queued = queuedPackets.removeFirst()
        queuedBytes -= queued.byteCount
        var packetToFree: UnsafeMutablePointer<AVPacket>? = queued.packet
        defer { trackedPacketFree(&packetToFree) }
        try decodePacketLocked(
            queued.packet,
            decodeTime: queued.decodeTime
        )
    }

    private func decodePacketLocked(
        _ packet: UnsafeMutablePointer<AVPacket>,
        decodeTime: CMTime
    ) throws {
        decoder.decode(packet: packet)
        if shouldSynchronizeForTargetReadiness(decodeTime: decodeTime) {
            decoder.synchronize()
        }
        try throwIfUnavailable()
    }

    private func shouldSynchronizeForTargetReadiness(
        decodeTime: CMTime
    ) -> Bool {
        lock.lock()
        let ready = targetFrameReady
        let target = targetTime
        lock.unlock()
        guard !ready else { return false }
        guard decodeTime.isValid, decodeTime.isNumeric else {
            return true
        }
        let nominalDuration = streamContract.nominalFrameDuration.isValid
            && streamContract.nominalFrameDuration.isNumeric
            && CMTimeCompare(
                streamContract.nominalFrameDuration,
                .zero
            ) > 0
            ? streamContract.nominalFrameDuration
            : .zero
        let readinessLead = CMTimeAdd(
            nominalDuration,
            CMTime(seconds: 0.1, preferredTimescale: 600)
        )
        return CMTimeCompare(
            decodeTime,
            CMTimeSubtract(target, readinessLead)
        ) >= 0
    }

    private func finishDecoderIfReadyLocked() throws {
        guard sourceEnded, queuedPackets.isEmpty, !didFinishDecoder else {
            return
        }
        didFinishDecoder = true
        decoder.finish()
        try throwIfUnavailable()
    }

    private func clearQueuedPacketsLocked() {
        for queued in queuedPackets {
            var packetToFree: UnsafeMutablePointer<AVPacket>? = queued.packet
            trackedPacketFree(&packetToFree)
        }
        queuedPackets.removeAll(keepingCapacity: true)
        queuedBytes = 0
    }

    private static func isValidTimelineTime(_ time: CMTime) -> Bool {
        time.isValid
            && time.isNumeric
            && CMTimeCompare(time, .zero) >= 0
    }
}
