import Foundation
import CoreMedia
import CoreVideo
import Libavformat
import Libavcodec
import Libavutil

/// Decoder-owned geometry for the pixel buffer delivered with a frame.
///
/// Clean-aperture coordinates use the Core Image lower-left origin. Rotation remains a stream-level
/// presentation property and is added by `HybridVideoDecodeSink` after decoding.
struct DecodedFramePresentationMetadata: Sendable, Equatable {
    let codedWidth: Int
    let codedHeight: Int
    let cleanApertureX: Int
    let cleanApertureY: Int
    let cleanApertureWidth: Int
    let cleanApertureHeight: Int
    let pixelAspectRatioNumerator: Int
    let pixelAspectRatioDenominator: Int

    init(
        codedWidth: Int,
        codedHeight: Int,
        cropTop: Int,
        cropBottom: Int,
        cropLeft: Int,
        cropRight: Int,
        pixelAspectRatioNumerator: Int,
        pixelAspectRatioDenominator: Int
    ) throws {
        guard codedWidth > 0,
              codedHeight > 0,
              cropTop >= 0,
              cropBottom >= 0,
              cropLeft >= 0,
              cropRight >= 0 else {
            throw VideoDecoderError.invalidFrameGeometry
        }
        let horizontalCrop = cropLeft
            .addingReportingOverflow(cropRight)
        let verticalCrop = cropTop
            .addingReportingOverflow(cropBottom)
        guard !horizontalCrop.overflow,
              !verticalCrop.overflow,
              horizontalCrop.partialValue < codedWidth,
              verticalCrop.partialValue < codedHeight,
              pixelAspectRatioNumerator > 0,
              pixelAspectRatioDenominator > 0 else {
            throw VideoDecoderError.invalidFrameGeometry
        }
        self.codedWidth = codedWidth
        self.codedHeight = codedHeight
        cleanApertureX = cropLeft
        // FFmpeg crop values are top/left based; Core Image uses a lower-left origin.
        cleanApertureY = cropBottom
        cleanApertureWidth = codedWidth
            - horizontalCrop.partialValue
        cleanApertureHeight = codedHeight
            - verticalCrop.partialValue
        self.pixelAspectRatioNumerator =
            pixelAspectRatioNumerator
        self.pixelAspectRatioDenominator =
            pixelAspectRatioDenominator
    }

    init(
        frame: UnsafeMutablePointer<AVFrame>,
        streamPixelAspectRatio: AVRational
    ) throws {
        let frameSAR = frame.pointee.sample_aspect_ratio
        let resolvedSAR = frameSAR.num > 0 && frameSAR.den > 0
            ? frameSAR
            : streamPixelAspectRatio
        let numerator = resolvedSAR.num > 0
            ? Int(resolvedSAR.num)
            : 1
        let denominator = resolvedSAR.den > 0
            ? Int(resolvedSAR.den)
            : 1
        guard let cropTop = Int(exactly: frame.pointee.crop_top),
              let cropBottom = Int(exactly: frame.pointee.crop_bottom),
              let cropLeft = Int(exactly: frame.pointee.crop_left),
              let cropRight = Int(exactly: frame.pointee.crop_right) else {
            throw VideoDecoderError.invalidFrameGeometry
        }
        try self.init(
            codedWidth: Int(frame.pointee.width),
            codedHeight: Int(frame.pointee.height),
            cropTop: cropTop,
            cropBottom: cropBottom,
            cropLeft: cropLeft,
            cropRight: cropRight,
            pixelAspectRatioNumerator: numerator,
            pixelAspectRatioDenominator: denominator
        )
    }

    init(stream: UnsafeMutablePointer<AVStream>) throws {
        guard let codecParameters = stream.pointee.codecpar else {
            throw VideoDecoderError.noCodecParameters
        }
        let parameters = codecParameters.pointee
        var cropTop = 0
        var cropBottom = 0
        var cropLeft = 0
        var cropRight = 0
        let sideDataCount = Int(parameters.nb_coded_side_data)
        if sideDataCount > 0,
           let sideData = parameters.coded_side_data {
            for index in 0..<sideDataCount {
                let item = sideData[index]
                guard item.type == AV_PKT_DATA_FRAME_CROPPING else {
                    continue
                }
                guard item.size >= 16,
                      let bytes = item.data else {
                    throw VideoDecoderError.invalidFrameGeometry
                }
                func readUInt32LE(_ offset: Int) -> UInt32 {
                    UInt32(bytes[offset])
                        | (UInt32(bytes[offset + 1]) << 8)
                        | (UInt32(bytes[offset + 2]) << 16)
                        | (UInt32(bytes[offset + 3]) << 24)
                }
                guard let top = Int(exactly: readUInt32LE(0)),
                      let bottom = Int(exactly: readUInt32LE(4)),
                      let left = Int(exactly: readUInt32LE(8)),
                      let right = Int(exactly: readUInt32LE(12)) else {
                    throw VideoDecoderError.invalidFrameGeometry
                }
                cropTop = top
                cropBottom = bottom
                cropLeft = left
                cropRight = right
                break
            }
        }
        let parameterSAR = parameters.sample_aspect_ratio
        let streamSAR = stream.pointee.sample_aspect_ratio
        let resolvedSAR = parameterSAR.num > 0
            && parameterSAR.den > 0
            ? parameterSAR
            : streamSAR
        try self.init(
            codedWidth: Int(parameters.width),
            codedHeight: Int(parameters.height),
            cropTop: cropTop,
            cropBottom: cropBottom,
            cropLeft: cropLeft,
            cropRight: cropRight,
            pixelAspectRatioNumerator:
                resolvedSAR.num > 0 ? Int(resolvedSAR.num) : 1,
            pixelAspectRatioDenominator:
                resolvedSAR.den > 0 ? Int(resolvedSAR.den) : 1
        )
    }
}

/// Decoded frame callback. `hdr10PlusT35` carries HDR10+ dynamic metadata serialised to ITU-T T.35 bytes
/// (kCMSampleAttachmentKey_HDR10PlusPerFrameData format); nil for non-HDR10+ streams.
typealias DecodedFrameHandler = @Sendable (
    CVPixelBuffer,
    CMTime,
    CMTime,
    Data?,
    DecodedFramePresentationMetadata
) -> Void
typealias VideoDecoderFailureHandler = @Sendable (VideoDecoderError) -> Void

/// Common video decoder protocol. SoftwareVideoDecoder (libavcodec, AV1/VP9) and
/// HardwareVideoDecoder (VTDecompressionSession, HEVC) both conform; the host swaps per codec without rewiring the demux loop.
// Sendable: both conformers (SoftwareVideoDecoder, HardwareVideoDecoder) are @unchecked Sendable
// (internally lock-guarded), so `any VideoDecodingPipeline` is safe to capture in @Sendable closures.
protocol VideoDecodingPipeline: AnyObject, Sendable {
    var onFrame: DecodedFrameHandler? { get set }
    var onFailure: VideoDecoderFailureHandler? { get set }
    var onFirstHDR10PlusDetected: (@Sendable () -> Void)? { get set }
    var skipUntilPTS: CMTime? { get set }

    func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws
    func decode(packet: UnsafeMutablePointer<AVPacket>)
    func synchronize()
    func finish()
    func flush()
    func close()
}

enum VideoDecoderError: Error, LocalizedError, Sendable, Equatable {
    case noCodecParameters
    case unsupportedCodec(id: UInt32)
    case noExtradata
    case formatDescriptionFailed(status: OSStatus)
    case sessionCreationFailed(status: OSStatus)
    case packetDataMissing
    case blockBufferCreationFailed(status: OSStatus)
    case sampleBufferCreationFailed(status: OSStatus)
    case decodeFrameFailed(status: OSStatus)
    case asynchronousDecodeFailed(status: OSStatus)
    case asynchronousFrameMissing
    case dynamicHDR10PlusSerializationFailed
    case frameAllocationFailed
    case invalidFrameGeometry
    case softwareSendPacketFailed(code: Int32)
    case softwareReceiveFrameFailed(code: Int32)
    case pixelBufferConversionFailed

    var errorDescription: String? {
        switch self {
        case .noCodecParameters: "No codec parameters"
        case .unsupportedCodec(let id): "Unsupported video codec (id: \(id))"
        case .noExtradata: "Missing codec extradata"
        case .formatDescriptionFailed(let s): "Format description failed (\(s))"
        case .sessionCreationFailed(let s): "Decoder session failed (\(s))"
        case .packetDataMissing: "Compressed video packet has no payload"
        case .blockBufferCreationFailed(let s): "Video block buffer creation failed (\(s))"
        case .sampleBufferCreationFailed(let s): "Video sample buffer creation failed (\(s))"
        case .decodeFrameFailed(let s): "VideoToolbox decode submission failed (\(s))"
        case .asynchronousDecodeFailed(let s): "VideoToolbox asynchronous decode failed (\(s))"
        case .asynchronousFrameMissing: "VideoToolbox completed decode without an image buffer"
        case .dynamicHDR10PlusSerializationFailed:
            "HDR10+ dynamic metadata could not be serialized for presentation"
        case .frameAllocationFailed: "Software video decoder could not allocate a frame"
        case .invalidFrameGeometry: "Decoded video frame geometry is invalid"
        case .softwareSendPacketFailed(let c): "Software video decoder rejected packet (\(c))"
        case .softwareReceiveFrameFailed(let c): "Software video decoder failed receiving frame (\(c))"
        case .pixelBufferConversionFailed: "Software video frame could not be converted to a pixel buffer"
        }
    }
}

/// FFmpeg-to-CoreVideo color metadata mapping shared by SW and HW decoders (single source of truth for primaries/transfer/matrix).
enum ColorAttachments {
    static func primaries(_ v: AVColorPrimaries) -> CFString? {
        switch v {
        case AVCOL_PRI_BT709:    kCVImageBufferColorPrimaries_ITU_R_709_2
        case AVCOL_PRI_BT2020:   kCVImageBufferColorPrimaries_ITU_R_2020
        case AVCOL_PRI_SMPTE432: kCVImageBufferColorPrimaries_P3_D65
        default:                 nil
        }
    }

    static func transfer(_ v: AVColorTransferCharacteristic) -> CFString? {
        switch v {
        case AVCOL_TRC_BT709:        kCVImageBufferTransferFunction_ITU_R_709_2
        case AVCOL_TRC_SMPTE2084:    kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case AVCOL_TRC_ARIB_STD_B67: kCVImageBufferTransferFunction_ITU_R_2100_HLG
        default:                     nil
        }
    }

    static func matrix(_ v: AVColorSpace) -> CFString? {
        switch v {
        case AVCOL_SPC_BT709:                       kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL: kCVImageBufferYCbCrMatrix_ITU_R_2020
        default:                                    nil
        }
    }

    /// PQ (ST 2084) or HLG transfer means the stream is HDR.
    static func isHDRTransfer(_ trc: AVColorTransferCharacteristic) -> Bool {
        trc == AVCOL_TRC_SMPTE2084 || trc == AVCOL_TRC_ARIB_STD_B67
    }
}
