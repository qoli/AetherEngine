import Foundation
import CoreMedia
import CoreVideo
import Libavformat
import Libavcodec

/// Decoded frame callback. `hdr10PlusT35` carries HDR10+ dynamic metadata serialised to ITU-T T.35 bytes
/// (kCMSampleAttachmentKey_HDR10PlusPerFrameData format); nil for non-HDR10+ streams.
typealias DecodedFrameHandler = @Sendable (
    CVPixelBuffer,
    CMTime,
    CMTime,
    Data?
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
    case frameAllocationFailed
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
        case .frameAllocationFailed: "Software video decoder could not allocate a frame"
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
