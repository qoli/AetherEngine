import Foundation
import CoreMedia
import CoreVideo
import Libavformat
import Libavcodec
import Libavutil
import Libswscale

enum SoftwareVideoDecoderThreadingMode: Sendable {
    case throughput
    case boundedLatency
}

/// libavcodec software video decoder for codecs without VideoToolbox support (e.g. AV1/dav1d on Apple TV).
/// Uses sws_scale (SIMD/NEON-optimized) for YUV→NV12/P010 conversion; required to hit 24fps at 1080p for AV1.
final class SoftwareVideoDecoder: VideoDecodingPipeline, @unchecked Sendable {

    static func boundedLatencyThreadCount(
        activeProcessorCount: Int
    ) -> Int {
        max(1, min(16, activeProcessorCount))
    }

    static func uses10BitOutput(
        bitsPerRawSample: Int32,
        colorTransfer: AVColorTransferCharacteristic
    ) -> Bool {
        bitsPerRawSample > 8
            || ColorAttachments.isHDRTransfer(colorTransfer)
    }

    static func conversionPixelFormat(
        uses10BitOutput: Bool
    ) -> AVPixelFormat {
        uses10BitOutput ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12
    }

    static func coreVideoPixelFormat(
        uses10BitOutput: Bool
    ) -> OSType {
        uses10BitOutput
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    private let threadingMode: SoftwareVideoDecoderThreadingMode
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    // FFmpeg 8.x exposes SwsContext as a real struct (7.x was OpaquePointer); pointer type must match or call sites miscompile.
    private var swsContext: UnsafeMutablePointer<SwsContext>?
    private var timeBase: AVRational = AVRational(num: 1, den: 90000)
    var onFrame: DecodedFrameHandler?
    var onFailure: VideoDecoderFailureHandler?

    /// Fires once (demux thread) on first HDR10+ side data; engine flips videoFormat to .hdr10Plus.
    private var seenHDR10Plus = false
    var onFirstHDR10PlusDetected: (@Sendable () -> Void)?

    /// True when the source is >8-bit (HDR10, AV1 HDR).
    private var use10Bit = false

    /// Container-declared SAR for frames that do not repeat the static stream value (NTSC 720x480, PAL
    /// 720x576, widescreen DVDs). Frame-level SAR has explicit precedence when present.
    private var streamSAR = AVRational(num: 1, den: 1)

    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    /// Skip pre-seek frames; decoded for reference but not converted.
    /// Guarded by `skipLock` not `lock`: emit() runs with `lock` held, so a same-lock accessor would deadlock.
    /// CMTime is multi-word: old unsynchronized access was a torn-read candidate.
    var skipUntilPTS: CMTime? {
        get { skipLock.lock(); defer { skipLock.unlock() }; return _skipUntilPTS }
        set { skipLock.lock(); _skipUntilPTS = newValue; skipLock.unlock() }
    }
    private var _skipUntilPTS: CMTime?
    private let skipLock = NSLock()

    /// Clear the skip threshold only if it is still the one we acted on.
    private func clearSkip(ifStillAt threshold: CMTime) {
        skipLock.lock()
        if let current = _skipUntilPTS, CMTimeCompare(current, threshold) == 0 {
            _skipUntilPTS = nil
        }
        skipLock.unlock()
    }

    /// Protects codecContext across the demux thread (decode) and main thread (close/flush).
    private let lock = NSLock()

    /// Deinterlacer for interlaced MPEG-2/VC-1/MPEG-4 (DVD rips, SD broadcast); see DeinterlaceFilter class doc.
    /// Engaged lazily on first interlaced frame; every subsequent frame routes through it. Guarded by `lock`.
    private let deinterlacer = DeinterlaceFilter()

    init(
        threadingMode: SoftwareVideoDecoderThreadingMode = .throughput
    ) {
        self.threadingMode = threadingMode
    }

    func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws {
        self.onFrame = onFrame

        guard let codecpar = stream.pointee.codecpar else {
            throw VideoDecoderError.noCodecParameters
        }

        timeBase = stream.pointee.time_base

        // Preserve the container SAR; frames usually repeat it from the MPEG-2 sequence header.
        streamSAR = codecpar.pointee.sample_aspect_ratio

        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            throw VideoDecoderError.unsupportedCodec(id: codecpar.pointee.codec_id.rawValue)
        }

        guard let ctx = avcodec_alloc_context3(codec) else {
            throw VideoDecoderError.sessionCreationFailed(status: -1)
        }
        codecContext = ctx

        guard avcodec_parameters_to_context(ctx, codecpar) >= 0 else {
            throw VideoDecoderError.noCodecParameters
        }

        // Reject VideoToolbox pixel format to force pure software decode (some decoders ignore this).
        ctx.pointee.get_format = { _, fmts in
            guard let fmts = fmts else { return AV_PIX_FMT_NONE }
            var i = 0
            while fmts[i] != AV_PIX_FMT_NONE {
                if fmts[i] != AV_PIX_FMT_VIDEOTOOLBOX {
                    return fmts[i]
                }
                i += 1
            }
            return AV_PIX_FMT_YUV420P
        }

        let activeProcessorCount =
            ProcessInfo.processInfo.activeProcessorCount
        switch threadingMode {
        case .throughput:
            ctx.pointee.thread_count = Int32(activeProcessorCount)
            ctx.pointee.thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE
        case .boundedLatency:
            // FF_THREAD_FRAME buffers one future frame per thread. The hybrid
            // route is clock-demand-driven and intentionally does not decode an
            // unbounded future window, so only within-frame parallelism is valid.
            ctx.pointee.thread_count = Int32(
                Self.boundedLatencyThreadCount(
                    activeProcessorCount: activeProcessorCount
                )
            )
            ctx.pointee.thread_type = FF_THREAD_SLICE
        }

        // Belt-and-suspenders hwaccel=none: some decoders ignore get_format.
        var opts: OpaquePointer?
        av_dict_set(&opts, "hwaccel", "none", 0)

        guard avcodec_open2(ctx, codec, &opts) >= 0 else {
            av_dict_free(&opts)
            throw VideoDecoderError.sessionCreationFailed(status: -2)
        }
        av_dict_free(&opts)

        let bitsPerSample = codecpar.pointee.bits_per_raw_sample
        let isHDRTransfer = ColorAttachments.isHDRTransfer(codecpar.pointee.color_trc)
        use10Bit = Self.uses10BitOutput(
            bitsPerRawSample: bitsPerSample,
            colorTransfer: codecpar.pointee.color_trc
        )

        // Release-visible log (no #if DEBUG): needed for TestFlight users and DrHurt #4 black-screen reports.
        EngineLog.emit(
            "[SWDecoder] Opened: \(codecpar.pointee.width)x\(codecpar.pointee.height), "
                + "codec=\(String(cString: codec.pointee.name)), "
                + "threads=\(ctx.pointee.thread_count), "
                + "requestedThreadType=\(ctx.pointee.thread_type), "
                + "activeThreadType=\(ctx.pointee.active_thread_type), "
                + "\(use10Bit ? "10-bit" : "8-bit")",
            category: .swPlayback
        )
    }

    func decode(packet: UnsafeMutablePointer<AVPacket>) {
        lock.lock()
        guard let ctx = codecContext else { lock.unlock(); return }

        let sendRet = avcodec_send_packet(ctx, packet)
        guard sendRet >= 0 else {
            let failure = onFailure
            lock.unlock()
            failure?(.softwareSendPacketFailed(code: sendRet))
            return
        }

        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        guard let f = frame else {
            let failure = onFailure
            lock.unlock()
            failure?(.frameAllocationFailed)
            return
        }
        lock.unlock()

        var filtered: UnsafeMutablePointer<AVFrame>? = nil

        while true {
            lock.lock()
            guard codecContext != nil else { lock.unlock(); break }
            let ret = avcodec_receive_frame(ctx, f)
            guard ret >= 0 else {
                let failure = ret == FFmpegErr.eagain || ret == FFmpegErr.eof
                    ? nil
                    : onFailure
                lock.unlock()
                failure?(.softwareReceiveFrameFailed(code: ret))
                break
            }

            let isInterlaced = (f.pointee.flags & (1 << 3)) != 0  // AV_FRAME_FLAG_INTERLACED
            if isInterlaced || deinterlacer.isActive {
                if deinterlacer.ensureGraph(frame: f, timeBase: timeBase),
                   deinterlacer.push(f) >= 0 {
                    if filtered == nil { filtered = av_frame_alloc() }
                    if let out = filtered {
                        while deinterlacer.pull(into: out) >= 0 {  // filter holds one frame lookahead; push can yield EAGAIN
                            emit(out)
                            av_frame_unref(out)
                        }
                    }
                    lock.unlock()
                    continue
                }
                // No deinterlacer in linked build or graph failure: fall through and render as-is (combing, but playing).
            }
            // emit() must stay under `lock`: close() frees swsContext/pixelBufferPool under the same lock;
            // emitting unlocked raced a stop() into a use-after-free of the sws context.
            emit(f)
            lock.unlock()
        }

        av_frame_free(&frame)
        if filtered != nil { av_frame_free(&filtered) }
    }

    /// Convert + deliver one decoded (or deinterlaced) frame: skip threshold, sws_scale, HDR10+ side data, onFrame.
    /// Shared by the direct and deinterlaced paths.
    private func emit(_ f: UnsafeMutablePointer<AVFrame>) {
        if let threshold = skipUntilPTS, f.pointee.pts != Int64.min {
            let framePTS = CMTimeMake(
                value: f.pointee.pts * Int64(timeBase.num),
                timescale: Int32(timeBase.den)
            )
            if CMTimeCompare(framePTS, threshold) < 0 {
                return
            }
            // Compare-and-clear: a concurrent seek can install a new threshold; blindly nil-ing would discard it.
            clearSkip(ifStillAt: threshold)
        }

        let framePresentationMetadata:
            DecodedFramePresentationMetadata
        do {
            framePresentationMetadata = try
                DecodedFramePresentationMetadata(
                    frame: f,
                    streamPixelAspectRatio: streamSAR
                )
        } catch {
            onFailure?(.invalidFrameGeometry)
            return
        }

        guard let pixelBuffer = convertFrameToPixelBuffer(f) else {
            onFailure?(.pixelBufferConversionFailed)
            return
        }

        let pts = f.pointee.pts
        let cmPTS: CMTime
        if pts != Int64.min {
            cmPTS = CMTimeMake(
                value: pts * Int64(timeBase.num),
                timescale: Int32(timeBase.den)
            )
        } else {
            cmPTS = .invalid
        }

        // HDR10+: read dynamic metadata from post-decode AVFrame side data (T.35 SEI bytes).
        // Can't reuse the VT path's packet-side stash; this decoder owns its own packet flow.
        let hdr10PlusData: Data?
        do {
            hdr10PlusData = try HDR10PlusMetadataSerializer
                .fromFrame(f)
        } catch {
            onFailure?(.dynamicHDR10PlusSerializationFailed)
            return
        }
        if hdr10PlusData != nil, !seenHDR10Plus {
            seenHDR10Plus = true
            onFirstHDR10PlusDetected?()
        }

        let duration = f.pointee.duration > 0
            ? CMTimeMake(
                value: f.pointee.duration * Int64(timeBase.num),
                timescale: Int32(timeBase.den)
            )
            : .invalid
        onFrame?(
            pixelBuffer,
            cmPTS,
            duration,
            hdr10PlusData,
            framePresentationMetadata
        )
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        // Deinterlacer temporal references are stale across seeks; drop the graph (lazily rebuilt on next interlaced frame).
        deinterlacer.teardown()
        guard let ctx = codecContext else { return }
        avcodec_flush_buffers(ctx)
    }

    func synchronize() {
        // Software decode and frame delivery are synchronous in decode(packet:).
    }

    func finish() {
        lock.lock()
        guard let ctx = codecContext else {
            lock.unlock()
            return
        }
        let sendResult = avcodec_send_packet(ctx, nil)
        guard sendResult >= 0 else {
            let failure = onFailure
            lock.unlock()
            failure?(.softwareSendPacketFailed(code: sendResult))
            return
        }
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        guard frame != nil else {
            let failure = onFailure
            lock.unlock()
            failure?(.frameAllocationFailed)
            return
        }
        while true {
            let receiveResult = avcodec_receive_frame(ctx, frame)
            if receiveResult == FFmpegErr.eagain
                || receiveResult == FFmpegErr.eof {
                break
            }
            guard receiveResult >= 0 else {
                let failure = onFailure
                lock.unlock()
                av_frame_free(&frame)
                failure?(.softwareReceiveFrameFailed(code: receiveResult))
                return
            }
            emit(frame!)
            av_frame_unref(frame!)
        }
        av_frame_free(&frame)
        lock.unlock()
    }

    func close() {
        lock.lock()
        deinterlacer.teardown()
        if codecContext != nil {
            avcodec_free_context(&codecContext)
        }
        codecContext = nil
        if swsContext != nil {
            sws_freeContext(swsContext)
            swsContext = nil
        }
        pixelBufferPool = nil
        poolWidth = 0
        poolHeight = 0
        // Nil onFrame inside the lock: emit() reads it under the same lock; unsynchronized write is a data race.
        onFrame = nil
        onFailure = nil
        lock.unlock()
    }

    deinit {
        close()
    }

    // MARK: - AVFrame → CVPixelBuffer (sws_scale)

    private func convertFrameToPixelBuffer(_ frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)
        guard width > 0, height > 0 else { return nil }

        let srcFmt = AVPixelFormat(rawValue: frame.pointee.format)

        let dstFmt = Self.conversionPixelFormat(
            uses10BitOutput: use10Bit
        )

        swsContext = sws_getCachedContext(
            swsContext,
            Int32(width), Int32(height), srcFmt,
            Int32(width), Int32(height), dstFmt,
            // FFmpeg 8 turned the SWS_* constants into a typed `SwsFlags`
            // enum; the C signature still wants a plain int, so unwrap.
            Int32(SWS_BILINEAR.rawValue), nil, nil, nil
        )
        guard swsContext != nil else { return nil }

        let cvPixelFormat = Self.coreVideoPixelFormat(
            uses10BitOutput: use10Bit
        )

        if pixelBufferPool == nil || poolWidth != width || poolHeight != height {
            pixelBufferPool = nil
            let poolAttrs: NSDictionary = [kCVPixelBufferPoolMinimumBufferCountKey: 6]
            let pbAttrs: NSDictionary = [
                kCVPixelBufferPixelFormatTypeKey: cvPixelFormat,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs, pbAttrs, &pixelBufferPool)
            poolWidth = width
            poolHeight = height
        }

        var pixelBuffer: CVPixelBuffer?
        guard let pool = pixelBufferPool else { return nil }
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        attachColorSpace(from: frame, to: pb)
        attachPixelAspectRatio(from: frame, to: pb)

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        let yPlane = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!
            .assumingMemoryBound(to: UInt8.self)
        let cbcrPlane = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!
            .assumingMemoryBound(to: UInt8.self)

        var dstData: (UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?,
                      UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?)
        dstData.0 = yPlane
        dstData.1 = cbcrPlane
        dstData.2 = nil
        dstData.3 = nil

        var dstLinesize: (Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32) = (0, 0, 0, 0, 0, 0, 0, 0)
        dstLinesize.0 = Int32(CVPixelBufferGetBytesPerRowOfPlane(pb, 0))
        dstLinesize.1 = Int32(CVPixelBufferGetBytesPerRowOfPlane(pb, 1))

        withUnsafePointer(to: &frame.pointee.data) { srcDataPtr in
            withUnsafePointer(to: &frame.pointee.linesize) { srcLinesizePtr in
                withUnsafeMutablePointer(to: &dstData) { dstPtr in
                    withUnsafeMutablePointer(to: &dstLinesize) { dstLsPtr in
                        let srcSlice = UnsafeRawPointer(srcDataPtr)
                            .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
                        let srcLs = UnsafeRawPointer(srcLinesizePtr)
                            .assumingMemoryBound(to: Int32.self)
                        let dstSlice = UnsafeMutableRawPointer(dstPtr)
                            .assumingMemoryBound(to: UnsafeMutablePointer<UInt8>?.self)
                        let dstLs = UnsafeMutableRawPointer(dstLsPtr)
                            .assumingMemoryBound(to: Int32.self)

                        sws_scale(
                            swsContext,
                            srcSlice, srcLs,
                            0, Int32(height),
                            dstSlice, dstLs
                        )
                    }
                }
            }
        }

        return pb
    }

    // MARK: - Color Space Metadata

    /// Map FFmpeg color metadata to CVPixelBuffer attachments for correct HDR10 rendering (BT.2020 + PQ).
    private func attachColorSpace(from frame: UnsafeMutablePointer<AVFrame>, to pb: CVPixelBuffer) {
        let primaries = ColorAttachments.primaries(frame.pointee.color_primaries)
        let transfer = ColorAttachments.transfer(frame.pointee.color_trc)
        let matrix = ColorAttachments.matrix(frame.pointee.colorspace)

        if let primaries {
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        }
        if let transfer {
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
        }
        if let matrix {
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        }
    }

    // MARK: - Pixel Aspect Ratio (anamorphic SD)

    /// Attach SAR as kCVImageBufferPixelAspectRatioKey for anamorphic content.
    /// Prefers frame's own SAR, falls back to streamSAR; skips attachment for square pixels (0:0 or 1:1).
    private func attachPixelAspectRatio(from frame: UnsafeMutablePointer<AVFrame>, to pb: CVPixelBuffer) {
        var sar = frame.pointee.sample_aspect_ratio
        if sar.num <= 0 || sar.den <= 0 {
            sar = streamSAR
        }
        guard sar.num > 0, sar.den > 0, sar.num != sar.den else { return }

        let aspect: NSDictionary = [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey: Int(sar.num),
            kCVImageBufferPixelAspectRatioVerticalSpacingKey: Int(sar.den),
        ]
        CVBufferSetAttachment(pb, kCVImageBufferPixelAspectRatioKey, aspect, .shouldPropagate)
    }
}
