import CoreMedia
import CoreVideo
import Foundation

/// Geometry carried with every decoded video frame.
///
/// The carrier canvas is deliberately not a geometry source. A hybrid renderer uses this contract to
/// calculate the real video's viewport, including clean aperture, pixel aspect ratio and rotation.
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
    ) {
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
        self.duration = duration
        self.videoFormat = videoFormat
        self.geometry = geometry
        self.hdr10PlusT35 = hdr10PlusT35
        self.generation = generation
    }
}

public enum AetherMetalRendererError: Error, LocalizedError, Sendable, Equatable {
    case metalDeviceUnavailable
    case invalidPresentationTime
    case invalidGeometry
    case unsupportedRotation(Int)
    case unsupportedVideoFormat(VideoFormat)

    public var errorDescription: String? {
        switch self {
        case .metalDeviceUnavailable:
            return "Aether Metal renderer requires a Metal device"
        case .invalidPresentationTime:
            return "Decoded video frame has no valid presentation timestamp"
        case .invalidGeometry:
            return "Decoded video frame geometry is invalid"
        case .unsupportedRotation(let degrees):
            return "Aether Metal renderer does not have a verified rotation pipeline for \(degrees) degrees"
        case .unsupportedVideoFormat(let format):
            return "Aether Metal renderer does not have a verified color pipeline for \(String(describing: format))"
        }
    }
}
