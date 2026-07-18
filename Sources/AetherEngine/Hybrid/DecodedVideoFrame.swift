import CoreMedia
import CoreVideo
import Foundation

/// Geometry carried with every decoded video frame.
///
/// The carrier canvas is deliberately not a geometry source. A hybrid renderer uses this contract to
/// calculate the real video's viewport, including clean aperture, pixel aspect ratio and rotation.
/// Clean-aperture coordinates use the decoded pixel buffer's lower-left origin. `rotationDegrees` is a
/// canonical clockwise quarter turn and must be exactly 0, 90, 180 or 270.
public struct DecodedVideoFrameGeometry: Sendable, Equatable {
    public struct CleanAperture: Sendable, Equatable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public let codedWidth: Int
    public let codedHeight: Int
    public let cleanAperture: CleanAperture
    public let pixelAspectRatioNumerator: Int
    public let pixelAspectRatioDenominator: Int
    public let rotationDegrees: Int

    public init(
        codedWidth: Int,
        codedHeight: Int,
        cleanAperture: CleanAperture,
        pixelAspectRatioNumerator: Int,
        pixelAspectRatioDenominator: Int,
        rotationDegrees: Int
    ) {
        self.codedWidth = codedWidth
        self.codedHeight = codedHeight
        self.cleanAperture = cleanAperture
        self.pixelAspectRatioNumerator = pixelAspectRatioNumerator
        self.pixelAspectRatioDenominator = pixelAspectRatioDenominator
        self.rotationDegrees = rotationDegrees
    }

    /// The display aspect ratio after clean-aperture, pixel-aspect and rotation processing.
    /// Invalid geometry is rejected by the renderer before this value is used.
    public var displayAspectRatio: Double {
        let apertureRatio = cleanAperture.width / cleanAperture.height
        let pixelAspectRatio = Double(pixelAspectRatioNumerator) / Double(pixelAspectRatioDenominator)
        let unrotated = apertureRatio * pixelAspectRatio
        return rotationDegrees.isMultiple(of: 180) ? unrotated : 1 / unrotated
    }
}

/// Immutable color metadata captured from the decoded pixel buffer.
///
/// The renderer must not reconstruct HDR signaling from `VideoFormat` alone. `unspecified` records an
/// attachment that was genuinely absent; it is not a BT.709 or BT.2020 default. Hybrid HDR10/HDR10+ and
/// HLG frames are accepted only when their required 10-bit pixel encoding and color attachments agree.
public struct DecodedVideoFrameColorMetadata: Sendable, Equatable {
    public enum ComponentRange: Sendable, Equatable {
        case video
        case full
    }

    public enum PixelEncoding: Sendable, Equatable {
        case bgra8
        case yCbCr420BiPlanar(bitDepth: Int, range: ComponentRange)
        case unsupported(rawValue: UInt32)
    }

    public enum ColorPrimaries: Sendable, Equatable {
        case ituR709
        case ituR2020
        case p3D65
        case unspecified
        case unrecognized(String)
    }

    public enum TransferFunction: Sendable, Equatable {
        case ituR709
        case pq
        case hlg
        case unspecified
        case unrecognized(String)
    }

    public enum YCbCrMatrix: Sendable, Equatable {
        case ituR709
        case ituR2020
        case unspecified
        case unrecognized(String)
    }

    public let pixelEncoding: PixelEncoding
    public let colorPrimaries: ColorPrimaries
    public let transferFunction: TransferFunction
    public let yCbCrMatrix: YCbCrMatrix
    /// Raw 24-byte HEVC mastering-display-colour-volume SEI payload, when present.
    public let masteringDisplayColorVolume: Data?
    /// Raw 4-byte content-light-level-information SEI payload, when present.
    public let contentLightLevelInfo: Data?
    /// Raw 8-byte ambient-viewing-environment SEI payload, when present.
    public let ambientViewingEnvironment: Data?

    private init(
        pixelEncoding: PixelEncoding,
        colorPrimaries: ColorPrimaries,
        transferFunction: TransferFunction,
        yCbCrMatrix: YCbCrMatrix,
        masteringDisplayColorVolume: Data?,
        contentLightLevelInfo: Data?,
        ambientViewingEnvironment: Data?
    ) {
        self.pixelEncoding = pixelEncoding
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.yCbCrMatrix = yCbCrMatrix
        self.masteringDisplayColorVolume = masteringDisplayColorVolume
        self.contentLightLevelInfo = contentLightLevelInfo
        self.ambientViewingEnvironment = ambientViewingEnvironment
    }

    static func resolve(
        pixelBuffer: CVPixelBuffer,
        videoFormat: VideoFormat
    ) throws -> Self {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let pixelEncoding: PixelEncoding
        switch pixelFormat {
        case kCVPixelFormatType_32BGRA:
            pixelEncoding = .bgra8
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            pixelEncoding = .yCbCr420BiPlanar(bitDepth: 8, range: .video)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            pixelEncoding = .yCbCr420BiPlanar(bitDepth: 8, range: .full)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            pixelEncoding = .yCbCr420BiPlanar(bitDepth: 10, range: .video)
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            pixelEncoding = .yCbCr420BiPlanar(bitDepth: 10, range: .full)
        default:
            pixelEncoding = .unsupported(rawValue: pixelFormat)
        }

        let colorPrimaries = try resolveColorPrimaries(pixelBuffer)
        let transferFunction = try resolveTransferFunction(pixelBuffer)
        let yCbCrMatrix = try resolveYCbCrMatrix(pixelBuffer)
        let masteringDisplayColorVolume = try dataAttachment(
            pixelBuffer,
            key: kCVImageBufferMasteringDisplayColorVolumeKey,
            field: .masteringDisplayColorVolume,
            expectedByteCount: 24
        )
        let contentLightLevelInfo = try dataAttachment(
            pixelBuffer,
            key: kCVImageBufferContentLightLevelInfoKey,
            field: .contentLightLevelInfo,
            expectedByteCount: 4
        )
        let ambientViewingEnvironment = try dataAttachment(
            pixelBuffer,
            key: kCVImageBufferAmbientViewingEnvironmentKey,
            field: .ambientViewingEnvironment,
            expectedByteCount: 8
        )

        let metadata = Self(
            pixelEncoding: pixelEncoding,
            colorPrimaries: colorPrimaries,
            transferFunction: transferFunction,
            yCbCrMatrix: yCbCrMatrix,
            masteringDisplayColorVolume: masteringDisplayColorVolume,
            contentLightLevelInfo: contentLightLevelInfo,
            ambientViewingEnvironment: ambientViewingEnvironment
        )
        try metadata.validateStaticHDRContract(
            videoFormat: videoFormat,
            pixelFormat: pixelFormat
        )
        return metadata
    }

    private func validateStaticHDRContract(
        videoFormat: VideoFormat,
        pixelFormat: UInt32
    ) throws {
        let expectedTransfer: TransferFunction
        switch videoFormat {
        case .hdr10, .hdr10Plus:
            expectedTransfer = .pq
        case .hlg, .dolbyVision:
            expectedTransfer = .hlg
        case .sdr:
            return
        }

        guard case .yCbCr420BiPlanar(let bitDepth, _) = pixelEncoding,
              bitDepth >= 10 else {
            throw DecodedVideoFrameColorMetadataError
                .unsupportedStaticHDRPixelFormat(
                    videoFormat: videoFormat,
                    rawValue: pixelFormat
                )
        }
        try require(
            colorPrimaries,
            expected: .ituR2020,
            missingValue: .unspecified,
            field: .colorPrimaries,
            videoFormat: videoFormat
        )
        try require(
            transferFunction,
            expected: expectedTransfer,
            missingValue: .unspecified,
            field: .transferFunction,
            videoFormat: videoFormat
        )
        try require(
            yCbCrMatrix,
            expected: .ituR2020,
            missingValue: .unspecified,
            field: .yCbCrMatrix,
            videoFormat: videoFormat
        )
    }

    private func require<Value: Equatable>(
        _ actual: Value,
        expected: Value,
        missingValue: Value,
        field: DecodedVideoFrameColorMetadataError.AttachmentField,
        videoFormat: VideoFormat
    ) throws {
        if actual == missingValue {
            throw DecodedVideoFrameColorMetadataError
                .missingRequiredStaticHDRAttachment(
                    videoFormat: videoFormat,
                    field: field
                )
        }
        guard actual == expected else {
            throw DecodedVideoFrameColorMetadataError
                .mismatchedStaticHDRAttachment(
                    videoFormat: videoFormat,
                    field: field,
                    expected: String(describing: expected),
                    actual: String(describing: actual)
                )
        }
    }

    private static func resolveColorPrimaries(
        _ pixelBuffer: CVPixelBuffer
    ) throws -> ColorPrimaries {
        guard let value = try stringAttachment(
            pixelBuffer,
            key: kCVImageBufferColorPrimariesKey,
            field: .colorPrimaries
        ) else {
            return .unspecified
        }
        if CFEqual(
            value as CFString,
            kCVImageBufferColorPrimaries_ITU_R_709_2
        ) {
            return .ituR709
        }
        if CFEqual(
            value as CFString,
            kCVImageBufferColorPrimaries_ITU_R_2020
        ) {
            return .ituR2020
        }
        if CFEqual(
            value as CFString,
            kCVImageBufferColorPrimaries_P3_D65
        ) {
            return .p3D65
        }
        return .unrecognized(value)
    }

    private static func resolveTransferFunction(
        _ pixelBuffer: CVPixelBuffer
    ) throws -> TransferFunction {
        guard let value = try stringAttachment(
            pixelBuffer,
            key: kCVImageBufferTransferFunctionKey,
            field: .transferFunction
        ) else {
            return .unspecified
        }
        if CFEqual(
            value as CFString,
            kCVImageBufferTransferFunction_ITU_R_709_2
        ) {
            return .ituR709
        }
        if CFEqual(
            value as CFString,
            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        ) {
            return .pq
        }
        if CFEqual(
            value as CFString,
            kCVImageBufferTransferFunction_ITU_R_2100_HLG
        ) {
            return .hlg
        }
        return .unrecognized(value)
    }

    private static func resolveYCbCrMatrix(
        _ pixelBuffer: CVPixelBuffer
    ) throws -> YCbCrMatrix {
        guard let value = try stringAttachment(
            pixelBuffer,
            key: kCVImageBufferYCbCrMatrixKey,
            field: .yCbCrMatrix
        ) else {
            return .unspecified
        }
        if CFEqual(
            value as CFString,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2
        ) {
            return .ituR709
        }
        if CFEqual(
            value as CFString,
            kCVImageBufferYCbCrMatrix_ITU_R_2020
        ) {
            return .ituR2020
        }
        return .unrecognized(value)
    }

    private static func stringAttachment(
        _ pixelBuffer: CVPixelBuffer,
        key: CFString,
        field: DecodedVideoFrameColorMetadataError.AttachmentField
    ) throws -> String? {
        guard let rawValue = CVBufferCopyAttachment(
            pixelBuffer,
            key,
            nil
        ) else {
            return nil
        }
        guard let value = rawValue as? String else {
            throw DecodedVideoFrameColorMetadataError
                .invalidAttachmentType(field: field)
        }
        return value
    }

    private static func dataAttachment(
        _ pixelBuffer: CVPixelBuffer,
        key: CFString,
        field: DecodedVideoFrameColorMetadataError.AttachmentField,
        expectedByteCount: Int
    ) throws -> Data? {
        guard let rawValue = CVBufferCopyAttachment(
            pixelBuffer,
            key,
            nil
        ) else {
            return nil
        }
        guard let value = rawValue as? Data else {
            throw DecodedVideoFrameColorMetadataError
                .invalidAttachmentType(field: field)
        }
        guard value.count == expectedByteCount else {
            throw DecodedVideoFrameColorMetadataError
                .invalidAttachmentSize(
                    field: field,
                    expectedByteCount: expectedByteCount,
                    actualByteCount: value.count
                )
        }
        return value
    }
}

public enum DecodedVideoFrameColorMetadataError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    public enum AttachmentField: String, Sendable, Equatable {
        case colorPrimaries
        case transferFunction
        case yCbCrMatrix
        case masteringDisplayColorVolume
        case contentLightLevelInfo
        case ambientViewingEnvironment
    }

    case invalidAttachmentType(field: AttachmentField)
    case invalidAttachmentSize(
        field: AttachmentField,
        expectedByteCount: Int,
        actualByteCount: Int
    )
    case unsupportedStaticHDRPixelFormat(
        videoFormat: VideoFormat,
        rawValue: UInt32
    )
    case missingRequiredStaticHDRAttachment(
        videoFormat: VideoFormat,
        field: AttachmentField
    )
    case mismatchedStaticHDRAttachment(
        videoFormat: VideoFormat,
        field: AttachmentField,
        expected: String,
        actual: String
    )

    public var errorDescription: String? {
        switch self {
        case .invalidAttachmentType(let field):
            return "Decoded video frame has an invalid \(field.rawValue) attachment type"
        case .invalidAttachmentSize(
            let field,
            let expectedByteCount,
            let actualByteCount
        ):
            return "Decoded video frame \(field.rawValue) attachment must be \(expectedByteCount) bytes, got \(actualByteCount)"
        case .unsupportedStaticHDRPixelFormat(
            let videoFormat,
            let rawValue
        ):
            return "Decoded \(String(describing: videoFormat)) frame requires a verified 10-bit bi-planar pixel format, got \(rawValue)"
        case .missingRequiredStaticHDRAttachment(
            let videoFormat,
            let field
        ):
            return "Decoded \(String(describing: videoFormat)) frame is missing required \(field.rawValue) metadata"
        case .mismatchedStaticHDRAttachment(
            let videoFormat,
            let field,
            let expected,
            let actual
        ):
            return "Decoded \(String(describing: videoFormat)) frame requires \(field.rawValue)=\(expected), got \(actual)"
        }
    }
}

/// A decoded video frame owned by AetherEngine.
///
/// `pixelBuffer`, source timing, color format and geometry form a single ownership unit. Hosts must not
/// reconstruct timing or color policy through decoder side channels. The class is `@unchecked Sendable`
/// because CoreVideo buffers are reference-counted objects; callers must treat the instance as immutable.
public final class DecodedVideoFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let presentationTime: CMTime
    public let duration: CMTime
    public let videoFormat: VideoFormat
    public let colorMetadata: DecodedVideoFrameColorMetadata
    public let geometry: DecodedVideoFrameGeometry
    public let hdr10PlusT35: Data?
    public let generation: UInt64

    public init(
        pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        duration: CMTime,
        videoFormat: VideoFormat,
        geometry: DecodedVideoFrameGeometry,
        hdr10PlusT35: Data?,
        generation: UInt64
    ) throws {
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
        self.duration = duration
        self.videoFormat = videoFormat
        colorMetadata = try DecodedVideoFrameColorMetadata.resolve(
            pixelBuffer: pixelBuffer,
            videoFormat: videoFormat
        )
        self.geometry = geometry
        self.hdr10PlusT35 = hdr10PlusT35
        self.generation = generation
    }
}
