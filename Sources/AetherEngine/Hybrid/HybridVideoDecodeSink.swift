import CoreMedia
import CoreVideo
import Foundation
import Libavcodec
import Libavformat
import Libavutil

enum HybridVideoStreamContractMatch: Sendable, Equatable {
    case exact
    /// A sequential MPEG-TS segment identified H.264 but did not repeat the
    /// SPS/PPS that established the long-lived decoder contract.
    case reusesEstablishedH264CodecParameters
    case mismatch
}

struct HybridVideoStreamContract: Sendable, Equatable {
    static let maximumPresentationReorderDepth = 16

    let codecID: UInt32
    let codedWidth: Int
    let codedHeight: Int
    let codecConfiguration: Data
    let videoFormat: VideoFormat
    let dolbyVisionConfiguration:
        AetherDolbyVisionConfiguration?
    let pixelAspectRatioNumerator: Int
    let pixelAspectRatioDenominator: Int
    let rotationDegrees: Int
    let nominalFrameDuration: CMTime
    let displayFrameRate: Double?
    /// Source-declared decoded-frame delay (`AVCodecParameters.video_delay`).
    /// Hybrid retains exactly this many callback frames before emitting the
    /// lowest real PTS; it does not invent a fixed sorting window.
    let presentationReorderDepth: Int
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
        dolbyVisionConfiguration =
            AetherEngine.dolbyVisionConfiguration(stream: stream)
        presentationReorderDepth = Int(codecParameters.video_delay)
        guard presentationReorderDepth >= 0,
              presentationReorderDepth
                <= Self.maximumPresentationReorderDepth else {
            throw HybridVideoDecodeSinkError
                .invalidPresentationReorderDepth(
                    presentationReorderDepth
                )
        }

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
            displayFrameRate = FrameRateSnap.snap(
                Double(frameRate.num)
                    / Double(frameRate.den)
            )
        } else {
            nominalFrameDuration = .invalid
            displayFrameRate = nil
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

    func match(
        _ candidate: HybridVideoStreamContract,
        allowsOmittedH264ParameterSets: Bool
    ) -> HybridVideoStreamContractMatch {
        if candidate == self {
            return .exact
        }
        guard allowsOmittedH264ParameterSets,
              codecID == AV_CODEC_ID_H264.rawValue,
              candidate.codecID == codecID,
              codedWidth > 0,
              codedHeight > 0,
              !codecConfiguration.isEmpty,
              candidate.codedWidth == 0,
              candidate.codedHeight == 0,
              candidate.codecConfiguration.isEmpty,
              candidate.packetTimeBaseNumerator
                == packetTimeBaseNumerator,
              candidate.packetTimeBaseDenominator
                == packetTimeBaseDenominator,
              candidate.sourceStartPTS
                == sourceStartPTS,
              candidate.sourceStartTime
                == sourceStartTime else {
            return .mismatch
        }
        return .reusesEstablishedH264CodecParameters
    }

    var diagnosticSummary: String {
        let framesPerSecond = displayFrameRate.map {
            String($0)
        } ?? "none"
        return [
            "codecID=\(codecID)",
            "size=\(codedWidth)x\(codedHeight)",
            "configBytes=\(codecConfiguration.count)",
            "format=\(String(describing: videoFormat))",
            "sar=\(pixelAspectRatioNumerator):\(pixelAspectRatioDenominator)",
            "rotation=\(rotationDegrees)",
            "frameDuration=\(nominalFrameDuration.value)/\(nominalFrameDuration.timescale)",
            "fps=\(framesPerSecond)",
            "reorderDepth=\(presentationReorderDepth)",
            "timeBase=\(packetTimeBaseNumerator)/\(packetTimeBaseDenominator)",
        ].joined(separator: " ")
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
    case softwareRecoveryRequiresHEVC
    case softwareRecoveryForbiddenForDolbyVision
    case invalidDecodedFrameColorMetadata(
        DecodedVideoFrameColorMetadataError
    )
    case decodedFrameConstructionFailed(reason: String)
    case invalidDecodedFrameGeometry
    case decodedFrameDimensionsDiverged(
        pixelWidth: Int,
        pixelHeight: Int,
        metadataWidth: Int,
        metadataHeight: Int
    )
    case invalidDisplayMatrix
    case packetCloneFailed
    case packetTimestampMissing
    case invalidPacketTimeBase
    case invalidPresentationReorderDepth(Int)
    case restartTimestampRebaseAmbiguous(
        generation: UInt64,
        timestamp: Int64
    )
    case timestampRebaseOverflow
    case invalidTargetTime
    case invalidDecodeDemand
    case invalidQueueBounds(bytes: Int, packets: Int)
    case packetQueueOverflow(bytes: Int, packets: Int)
    case packetSpoolCapacityExceeded(bytes: Int, packets: Int)
    case packetSpoolCreateFailed
    case packetSpoolWriteFailed
    case packetSpoolReadFailed
    case packetSpoolCleanupFailed
    case packetSpoolRecordCorrupt
    case packetSideDataElementLimitExceeded(elements: Int, limit: Int)
    case packetSpoolUnsupportedOpaqueMetadata
    case closed

    var isPixelBufferConversionCapabilityFailure: Bool {
        guard case .decoderFailed(
            .pixelBufferConversionFailed
        ) = self else {
            return false
        }
        return true
    }

    var isLocalQueueInvariantFailure: Bool {
        switch self {
        case .packetQueueOverflow,
             .packetSpoolCapacityExceeded,
             .packetSpoolCreateFailed,
             .packetSpoolWriteFailed,
             .packetSpoolReadFailed,
             .packetSpoolCleanupFailed,
             .packetSpoolRecordCorrupt,
             .packetSideDataElementLimitExceeded,
             .packetSpoolUnsupportedOpaqueMetadata:
            return true
        default:
            return false
        }
    }

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
        case .softwareRecoveryRequiresHEVC:
            return "Software decoder recovery is restricted to HEVC"
        case .softwareRecoveryForbiddenForDolbyVision:
            return "Dolby Vision recovery requires the hardware decoder contract"
        case .invalidDecodedFrameColorMetadata(let error):
            return "Hybrid decoded frame color metadata is invalid: \(error.localizedDescription)"
        case .decodedFrameConstructionFailed(let reason):
            return "Hybrid decoded frame construction failed: \(reason)"
        case .invalidDecodedFrameGeometry:
            return "Hybrid decoded frame has invalid presentation geometry"
        case .decodedFrameDimensionsDiverged(
            let pixelWidth,
            let pixelHeight,
            let metadataWidth,
            let metadataHeight
        ):
            return "Hybrid decoded pixel buffer \(pixelWidth)x\(pixelHeight) does not match geometry metadata \(metadataWidth)x\(metadataHeight)"
        case .invalidDisplayMatrix:
            return "Hybrid video stream has an invalid display matrix"
        case .packetCloneFailed:
            return "Hybrid compressed-video packet could not be retained"
        case .packetTimestampMissing:
            return "Hybrid compressed-video packet has no decode or presentation timestamp"
        case .invalidPacketTimeBase:
            return "Hybrid video stream has an invalid packet time base"
        case .invalidPresentationReorderDepth(let depth):
            return "Hybrid video stream declares unsupported presentation reorder depth \(depth)"
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
        case .packetSpoolCapacityExceeded(let bytes, let packets):
            return "Hybrid compressed-video disk backlog exceeded its local bound: \(bytes) bytes / \(packets) packets"
        case .packetSpoolCreateFailed:
            return "Hybrid compressed-video disk backlog could not create private scratch storage"
        case .packetSpoolWriteFailed:
            return "Hybrid compressed-video disk backlog could not persist a packet"
        case .packetSpoolReadFailed:
            return "Hybrid compressed-video disk backlog could not restore a packet"
        case .packetSpoolCleanupFailed:
            return "Hybrid compressed-video disk backlog could not retire packet storage losslessly"
        case .packetSpoolRecordCorrupt:
            return "Hybrid compressed-video disk backlog encountered an invalid packet record"
        case .packetSideDataElementLimitExceeded(
            let elements,
            let limit
        ):
            return "Hybrid compressed-video packet has \(elements) side-data elements, exceeding the lossless backlog limit of \(limit)"
        case .packetSpoolUnsupportedOpaqueMetadata:
            return "Hybrid compressed-video packet contains opaque metadata that cannot be persisted losslessly"
        case .closed:
            return "Hybrid video decoder is closed"
        }
    }
}

enum HybridVideoDecoderPreference: Sendable, Equatable {
    case automatic
    case softwareHEVCRecovery
}

private final class HybridVideoBacklogCancellationGate:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var cancellationRequested = false

    var isCancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        lock.unlock()
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

    let streamContract: HybridVideoStreamContract

    private let decoder: any VideoDecodingPipeline
    private let frameHandler: FrameHandler
    private let failureHandler: FailureHandler?
    private let callbackBox = CallbackBox()
    private let lock = NSLock()
    private let operationLock = NSLock()
    private let presentationOrderLock = NSLock()
    private let backlogCancellationGate:
        HybridVideoBacklogCancellationGate
    private let compressedBacklog:
        HybridCompressedVideoBacklog

    private var generation: UInt64
    private var targetTime: CMTime
    private var targetFrameReady = false
    private var terminalError: HybridVideoDecodeSinkError?
    private var isClosed = false
    private var clockDecodeDemand: CMTime
    private var readinessDecodeLimit: CMTime
    private var sourceEnded = false
    private var didFinishDecoder = false
    private var sourceOriginPacketPosition: Int64?
    private var acceptsSourceOriginPacketPosition = true
    private var generationTimestampRebase: Int64? = 0
    private var restartDecodeAnchorPTS: Int64?
    private var restartBeyondSourceOrigin = false
    private var realVideoBitrateAccumulator =
        HybridRealVideoBitrateAccumulator()
    private var presentationOrder:
        HybridFramePresentationOrder<DecodedVideoFrame>
    private var presentationReadyFrames: [DecodedVideoFrame] = []
    private var presentationDrainIsActive = false
    private var didLogBacklogSpill = false

    init(
        demuxer: Demuxer,
        initialGeneration: UInt64,
        initialTargetTime: CMTime = .zero,
        sourceStartPTSOverride: Int64? = nil,
        maximumQueuedBytes: Int = 96 * 1_024 * 1_024,
        maximumQueuedPackets: Int = 8_192,
        maximumSpoolContentBytes: Int = 256 * 1_024 * 1_024,
        backlogScratchRoot: URL? = nil,
        backlogIOChunkDidComplete: (() -> Void)? = nil,
        decoderPreference: HybridVideoDecoderPreference = .automatic,
        onFrame: @escaping FrameHandler,
        onFailure: FailureHandler? = nil
    ) throws {
        guard Self.isValidTimelineTime(initialTargetTime) else {
            throw HybridVideoDecodeSinkError.invalidTargetTime
        }
        guard maximumQueuedBytes > 0,
              maximumQueuedPackets > 0,
              maximumSpoolContentBytes > 0 else {
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
        presentationOrder = HybridFramePresentationOrder(
            reorderDepth:
                streamContract.presentationReorderDepth
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
        let cancellationGate =
            HybridVideoBacklogCancellationGate()
        backlogCancellationGate = cancellationGate
        do {
            compressedBacklog = try HybridCompressedVideoBacklog(
                configuration:
                    HybridCompressedVideoBacklogConfiguration(
                        residentByteLimit: maximumQueuedBytes,
                        packetLimit: maximumQueuedPackets,
                        spoolContentByteLimit:
                            maximumSpoolContentBytes
                    ),
                scratchRoot: backlogScratchRoot,
                shouldCancelIO: {
                    cancellationGate
                        .isCancellationRequested
                },
                ioChunkDidComplete:
                    backlogIOChunkDidComplete
            )
        } catch {
            throw HybridVideoDecodeSinkError.invalidQueueBounds(
                bytes: maximumQueuedBytes,
                packets: maximumQueuedPackets
            )
        }
        frameHandler = onFrame
        failureHandler = onFailure
        switch decoderPreference {
        case .automatic:
            decoder = codecParameters.pointee.codec_id == AV_CODEC_ID_HEVC
                ? HardwareVideoDecoder()
                : SoftwareVideoDecoder(threadingMode: .boundedLatency)
        case .softwareHEVCRecovery:
            guard codecParameters.pointee.codec_id == AV_CODEC_ID_HEVC else {
                throw HybridVideoDecodeSinkError.softwareRecoveryRequiresHEVC
            }
            guard streamContract.videoFormat != .dolbyVision,
                  streamContract.dolbyVisionConfiguration == nil else {
                throw HybridVideoDecodeSinkError
                    .softwareRecoveryForbiddenForDolbyVision
            }
            decoder = SoftwareVideoDecoder(threadingMode: .boundedLatency)
        }

        callbackBox.sink = self
        do {
            try decoder.open(stream: stream) {
                [weak callbackBox] pixelBuffer,
                presentationTime,
                duration,
                hdr10PlusT35,
                presentationMetadata in
                callbackBox?.sink?.receiveFrame(
                    pixelBuffer: pixelBuffer,
                    presentationTime: presentationTime,
                    duration: duration,
                    hdr10PlusT35: hdr10PlusT35,
                    presentationMetadata:
                        presentationMetadata
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

    var compressedBacklogSnapshot:
        HybridCompressedVideoBacklogSnapshot
    {
        operationLock.lock()
        defer { operationLock.unlock() }
        return compressedBacklog.snapshot
    }

    var backlogCancellationRequestedForTesting: Bool {
        backlogCancellationGate.isCancellationRequested
    }

    var realVideoBitrateTelemetry:
        AetherHybridRealVideoBitrateTelemetry
    {
        operationLock.lock()
        defer { operationLock.unlock() }
        return realVideoBitrateAccumulator.snapshot()
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
        realVideoBitrateAccumulator.record(
            byteCount: Int(packet.pointee.size),
            durationTicks: packet.pointee.duration,
            timeBaseNumerator:
                streamContract.packetTimeBaseNumerator,
            timeBaseDenominator:
                streamContract.packetTimeBaseDenominator
        )
        if compressedBacklog.isEmpty,
           shouldDecode(decodeTime: decodeTime) {
            try decodePacketLocked(packet, decodeTime: decodeTime)
            return
        }
        let priorSnapshot = compressedBacklog.snapshot
        do {
            try compressedBacklog.append(
                packet: packet,
                decodeTime: decodeTime
            )
        } catch {
            let typed = Self.mapBacklogError(error)
            if !Self.isBacklogCancellation(error) {
                recordFailure(typed)
            }
            throw typed
        }
        let backlogSnapshot = compressedBacklog.snapshot
        if !didLogBacklogSpill,
           priorSnapshot.totalSpooledPackets == 0,
           backlogSnapshot.totalSpooledPackets > 0 {
            didLogBacklogSpill = true
            EngineLog.emit(
                "[HybridVideoDecodeSink] compressed backlog spill started "
                    + "resident_content_bytes=\(backlogSnapshot.residentContentBytes) "
                    + "resident_packets=\(backlogSnapshot.residentPackets) "
                    + "queued_content_bytes=\(backlogSnapshot.queuedContentBytes) "
                    + "queued_payload_bytes=\(backlogSnapshot.queuedPayloadBytes) "
                    + "queued_packets=\(backlogSnapshot.queuedPackets)",
                category: .session
            )
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
        stream: UnsafeMutablePointer<AVStream>,
        sourceStartPTSOverride: Int64? = nil,
        packetsAreNormalizedToSourceAxis: Bool = false
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
            stream: stream,
            sourceStartPTSOverride:
                sourceStartPTSOverride
        ) else {
            let error = HybridVideoDecodeSinkError.streamContractMismatch
            recordFailure(error)
            throw error
        }
        try throwIfUnavailable()
        try clearQueuedPacketsLocked()
        decoder.flush()
        try throwIfUnavailable()
        discardPendingPresentationFrames()
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
        if packetsAreNormalizedToSourceAxis {
            restartDecodeAnchorPTS = nil
            restartBeyondSourceOrigin = false
            generationTimestampRebase = 0
            acceptsSourceOriginPacketPosition = false
        } else {
            let timeBase = AVRational(
                num:
                    streamContract
                        .packetTimeBaseNumerator,
                den:
                    streamContract
                        .packetTimeBaseDenominator
            )
            if let restartDecodeAnchorTime {
                guard let anchorTicks =
                        BlackCarrierSourceAxis.streamTicks(
                            for:
                                restartDecodeAnchorTime,
                            timeBase: timeBase
                        ) else {
                    let error =
                        HybridVideoDecodeSinkError
                            .invalidTargetTime
                    recordFailure(error)
                    throw error
                }
                restartDecodeAnchorPTS = anchorTicks
            } else {
                restartDecodeAnchorPTS = nil
            }
            restartBeyondSourceOrigin =
                CMTimeCompare(
                    targetTime,
                    .zero
                ) > 0
            generationTimestampRebase = nil
            acceptsSourceOriginPacketPosition =
                false
        }
        sourceEnded = false
        didFinishDecoder = false
        didLogBacklogSpill = false
        realVideoBitrateAccumulator.reset()
    }

    func markEndOfStream() throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        try throwIfUnavailable()
        sourceEnded = true
        realVideoBitrateAccumulator.markComplete()
        decoder.synchronize()
        try throwIfUnavailable()
        try finishDecoderIfReadyLocked()
    }

    func finish() throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        try throwIfUnavailable()
        while !compressedBacklog.isEmpty {
            try decodeFirstQueuedPacketLocked()
        }
        sourceEnded = true
        realVideoBitrateAccumulator.markComplete()
        try finishDecoderIfReadyLocked()
        try throwIfUnavailable()
    }

    func close() {
        backlogCancellationGate.cancel()
        operationLock.lock()
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            operationLock.unlock()
            return
        }
        isClosed = true
        lock.unlock()
        let backlogSnapshot = compressedBacklog.snapshot
        if let cleanupError = compressedBacklog.close() {
            EngineLog.emit(
                "[HybridVideoDecodeSink] compressed backlog cleanup failed "
                    + "retained_spool_content_bytes=\(backlogSnapshot.spooledContentBytes) "
                    + "retained_spool_packets=\(backlogSnapshot.spooledPackets) "
                    + "error=\(String(describing: cleanupError))",
                category: .session
            )
        }
        logBacklogRetirement(backlogSnapshot)
        decoder.close()
        discardPendingPresentationFrames()
        operationLock.unlock()
    }

    private func receiveFrame(
        pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        duration: CMTime,
        hdr10PlusT35: Data?,
        presentationMetadata:
            DecodedFramePresentationMetadata
    ) {
        lock.lock()
        guard !isClosed, terminalError == nil else {
            lock.unlock()
            return
        }
        let frameGeneration = generation
        lock.unlock()

        let geometry: DecodedVideoFrameGeometry
        do {
            geometry = try Self.resolveFrameGeometry(
                pixelBufferWidth:
                    CVPixelBufferGetWidth(pixelBuffer),
                pixelBufferHeight:
                    CVPixelBufferGetHeight(pixelBuffer),
                metadata: presentationMetadata,
                rotationDegrees:
                    streamContract.rotationDegrees
            )
        } catch let error as HybridVideoDecodeSinkError {
            recordFailure(error)
            return
        } catch {
            recordFailure(.invalidDecodedFrameGeometry)
            return
        }
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
        let frame: DecodedVideoFrame
        do {
            frame = try DecodedVideoFrame(
                pixelBuffer: pixelBuffer,
                presentationTime: normalizedPresentationTime,
                duration: resolvedDuration,
                videoFormat: videoFormat,
                geometry: geometry,
                hdr10PlusT35: hdr10PlusT35,
                generation: frameGeneration
            )
        } catch let error as DecodedVideoFrameColorMetadataError {
            recordFailure(.invalidDecodedFrameColorMetadata(error))
            return
        } catch {
            recordFailure(.decodedFrameConstructionFailed(
                reason: String(describing: error)
            ))
            return
        }
        emitInPresentationOrder(frame)
    }

    /// Accept exactly the two decoder contracts observed on Apple platforms: a coded-size pixel buffer with
    /// an explicit clean aperture, or a decoder-cropped pixel buffer whose dimensions equal that aperture.
    /// Any other size relationship is ambiguous and must fail instead of scaling guessed coordinates.
    static func resolveFrameGeometry(
        pixelBufferWidth: Int,
        pixelBufferHeight: Int,
        metadata: DecodedFramePresentationMetadata,
        rotationDegrees: Int
    ) throws -> DecodedVideoFrameGeometry {
        guard pixelBufferWidth > 0,
              pixelBufferHeight > 0 else {
            throw HybridVideoDecodeSinkError
                .invalidDecodedFrameGeometry
        }
        let cleanAperture:
            DecodedVideoFrameGeometry.CleanAperture
        if pixelBufferWidth == metadata.codedWidth,
           pixelBufferHeight == metadata.codedHeight {
            cleanAperture = .init(
                x: Double(metadata.cleanApertureX),
                y: Double(metadata.cleanApertureY),
                width: Double(metadata.cleanApertureWidth),
                height: Double(metadata.cleanApertureHeight)
            )
        } else if pixelBufferWidth
                    == metadata.cleanApertureWidth,
                  pixelBufferHeight
                    == metadata.cleanApertureHeight {
            cleanAperture = .init(
                x: 0,
                y: 0,
                width: Double(pixelBufferWidth),
                height: Double(pixelBufferHeight)
            )
        } else {
            throw HybridVideoDecodeSinkError
                .decodedFrameDimensionsDiverged(
                    pixelWidth: pixelBufferWidth,
                    pixelHeight: pixelBufferHeight,
                    metadataWidth: metadata.codedWidth,
                    metadataHeight: metadata.codedHeight
                )
        }
        return DecodedVideoFrameGeometry(
            codedWidth: pixelBufferWidth,
            codedHeight: pixelBufferHeight,
            cleanAperture: cleanAperture,
            pixelAspectRatioNumerator:
                metadata.pixelAspectRatioNumerator,
            pixelAspectRatioDenominator:
                metadata.pixelAspectRatioDenominator,
            rotationDegrees: rotationDegrees
        )
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
        while let decodeTime = compressedBacklog.firstDecodeTime(),
              shouldDecode(decodeTime: decodeTime) {
            try decodeFirstQueuedPacketLocked()
        }
    }

    private func decodeFirstQueuedPacketLocked() throws {
        let queued:
            HybridCompressedVideoBacklog.DequeuedPacket
        do {
            guard let packet = try compressedBacklog.popFirst() else {
                return
            }
            queued = packet
        } catch {
            let typed = Self.mapBacklogError(error)
            if !Self.isBacklogCancellation(error) {
                recordFailure(typed)
            }
            throw typed
        }
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
        guard sourceEnded,
              compressedBacklog.isEmpty,
              !didFinishDecoder else {
            return
        }
        didFinishDecoder = true
        decoder.finish()
        try throwIfUnavailable()
        drainPendingPresentationFrames()
    }

    private func emitInPresentationOrder(_ frame: DecodedVideoFrame) {
        presentationOrderLock.lock()
        presentationReadyFrames.append(contentsOf:
            presentationOrder.insert(
                frame,
                presentationTime: frame.presentationTime
            )
        )
        let shouldDrain = claimPresentationDrainLocked()
        presentationOrderLock.unlock()
        if shouldDrain {
            drainPresentationReadyFrames()
        }
    }

    private func drainPendingPresentationFrames() {
        presentationOrderLock.lock()
        presentationReadyFrames.append(contentsOf:
            presentationOrder.drain()
        )
        let shouldDrain = claimPresentationDrainLocked()
        presentationOrderLock.unlock()
        if shouldDrain {
            drainPresentationReadyFrames()
        }
    }

    private func discardPendingPresentationFrames() {
        presentationOrderLock.lock()
        presentationOrder.discard()
        presentationReadyFrames.removeAll(keepingCapacity: true)
        presentationOrderLock.unlock()
    }

    private func claimPresentationDrainLocked() -> Bool {
        guard !presentationDrainIsActive,
              !presentationReadyFrames.isEmpty else {
            return false
        }
        presentationDrainIsActive = true
        return true
    }

    /// VideoToolbox callbacks may arrive concurrently. Only the caller that
    /// claims this drain may invoke the downstream handler; later callbacks
    /// append to the same queue. This preserves the ordering decision through
    /// the relay boundary without holding a lock while backpressure waits.
    private func drainPresentationReadyFrames() {
        while true {
            presentationOrderLock.lock()
            guard !presentationReadyFrames.isEmpty else {
                presentationDrainIsActive = false
                presentationOrderLock.unlock()
                return
            }
            let frame = presentationReadyFrames.removeFirst()
            presentationOrderLock.unlock()
            deliverPresentationFrame(frame)
        }
    }

    private func deliverPresentationFrame(_ frame: DecodedVideoFrame) {
        lock.lock()
        let activeFrameGeneration = generation
        let activeTarget = targetTime
        lock.unlock()
        if frame.generation == activeFrameGeneration,
           HybridPresentationReadinessGate.frameIntersectsTargetWindow(
               frame: frame,
               targetTime: activeTarget,
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
            if generation == activeFrameGeneration,
               targetTime == activeTarget {
                targetFrameReady = true
            }
            lock.unlock()
        }
        frameHandler(frame)
    }

    private func clearQueuedPacketsLocked() throws {
        let snapshot = compressedBacklog.snapshot
        do {
            try compressedBacklog.resetForGeneration()
        } catch {
            let typed = Self.mapBacklogError(error)
            recordFailure(typed)
            throw typed
        }
        logBacklogRetirement(snapshot)
    }

    private func logBacklogRetirement(
        _ snapshot: HybridCompressedVideoBacklogSnapshot
    ) {
        if snapshot.totalSpooledPackets > 0 {
            EngineLog.emit(
                "[HybridVideoDecodeSink] compressed backlog retired "
                    + "max_resident_content_bytes=\(snapshot.maximumResidentContentBytes) "
                    + "max_resident_packets=\(snapshot.maximumResidentPackets) "
                    + "max_spooled_content_bytes=\(snapshot.maximumSpooledContentBytes) "
                    + "spooled_packets=\(snapshot.totalSpooledPackets)",
                category: .session
            )
        }
    }

    private static func mapBacklogError(
        _ error: Error
    ) -> HybridVideoDecodeSinkError {
        guard let backlogError =
                error as? HybridCompressedVideoBacklogError else {
            return .packetSpoolRecordCorrupt
        }
        switch backlogError {
        case .invalidConfiguration:
            return .invalidQueueBounds(bytes: 0, packets: 0)
        case .packetCloneFailed:
            return .packetCloneFailed
        case .packetLimitExceeded(let bytes, let packets):
            return .packetQueueOverflow(
                bytes: bytes,
                packets: packets
            )
        case .spoolCapacityExceeded(let bytes, let packets):
            return .packetSpoolCapacityExceeded(
                bytes: bytes,
                packets: packets
            )
        case .spoolCreateFailed:
            return .packetSpoolCreateFailed
        case .spoolWriteFailed:
            return .packetSpoolWriteFailed
        case .spoolReadFailed:
            return .packetSpoolReadFailed
        case .spoolCleanupFailed:
            return .packetSpoolCleanupFailed
        case .spoolRecordCorrupt:
            return .packetSpoolRecordCorrupt
        case .sideDataElementLimitExceeded(
            let elements,
            let limit
        ):
            return .packetSideDataElementLimitExceeded(
                elements: elements,
                limit: limit
            )
        case .unsupportedOpaquePacketMetadata:
            return .packetSpoolUnsupportedOpaqueMetadata
        case .cancelled:
            return .closed
        case .closed:
            return .closed
        }
    }

    private static func isBacklogCancellation(
        _ error: Error
    ) -> Bool {
        error as? HybridCompressedVideoBacklogError
            == .cancelled
    }

    private static func isValidTimelineTime(_ time: CMTime) -> Bool {
        time.isValid
            && time.isNumeric
            && CMTimeCompare(time, .zero) >= 0
    }
}
