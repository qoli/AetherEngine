import CoreGraphics
import Foundation

/// Engine-owned scaling policy for real video drawn over the fixed black carrier canvas.
public enum AetherHybridVideoGravity: String, Sendable, Equatable {
    case resizeAspect
    case resizeAspectFill
}

/// Pure presentation geometry used by the Metal renderer.
///
/// The transform is intentionally split into deterministic stages so clean aperture, sample aspect ratio,
/// rotation and viewport scaling can be verified without a drawable or a Metal device.
struct HybridVideoPresentationLayout: Equatable {
    let sourceCrop: CGRect
    let pixelAspectRatio: CGFloat
    let rotationDegrees: Int
    let rotatedDisplaySize: CGSize
    let targetRect: CGRect
    let uniformScale: CGFloat

    init?(
        geometry: DecodedVideoFrameGeometry,
        drawableSize: CGSize,
        gravity: AetherHybridVideoGravity
    ) throws {
        try Self.validate(geometry: geometry)
        guard drawableSize.width.isFinite,
              drawableSize.height.isFinite,
              drawableSize.width > 0,
              drawableSize.height > 0 else {
            return nil
        }

        sourceCrop = CGRect(
            x: geometry.cleanAperture.x,
            y: geometry.cleanAperture.y,
            width: geometry.cleanAperture.width,
            height: geometry.cleanAperture.height
        )
        pixelAspectRatio = CGFloat(
            Double(geometry.pixelAspectRatioNumerator)
                / Double(geometry.pixelAspectRatioDenominator)
        )
        rotationDegrees = geometry.rotationDegrees

        let unrotatedDisplaySize = CGSize(
            width: sourceCrop.width * pixelAspectRatio,
            height: sourceCrop.height
        )
        switch rotationDegrees {
        case 0, 180:
            rotatedDisplaySize = unrotatedDisplaySize
        case 90, 270:
            rotatedDisplaySize = CGSize(
                width: unrotatedDisplaySize.height,
                height: unrotatedDisplaySize.width
            )
        default:
            throw AetherMetalRendererError
                .unsupportedRotation(rotationDegrees)
        }

        let horizontalScale = drawableSize.width
            / rotatedDisplaySize.width
        let verticalScale = drawableSize.height
            / rotatedDisplaySize.height
        switch gravity {
        case .resizeAspect:
            uniformScale = min(horizontalScale, verticalScale)
        case .resizeAspectFill:
            uniformScale = max(horizontalScale, verticalScale)
        }
        let targetSize = CGSize(
            width: rotatedDisplaySize.width * uniformScale,
            height: rotatedDisplaySize.height * uniformScale
        )
        targetRect = CGRect(
            x: (drawableSize.width - targetSize.width) / 2,
            y: (drawableSize.height - targetSize.height) / 2,
            width: targetSize.width,
            height: targetSize.height
        )
    }

    /// Maps the sample-aspect-corrected clean aperture at the origin to the requested clockwise quarter turn.
    var rotationTransform: CGAffineTransform {
        let width = sourceCrop.width * pixelAspectRatio
        let height = sourceCrop.height
        return switch rotationDegrees {
        case 0:
            .identity
        case 90:
            CGAffineTransform(
                a: 0,
                b: -1,
                c: 1,
                d: 0,
                tx: 0,
                ty: width
            )
        case 180:
            CGAffineTransform(
                a: -1,
                b: 0,
                c: 0,
                d: -1,
                tx: width,
                ty: height
            )
        case 270:
            CGAffineTransform(
                a: 0,
                b: 1,
                c: -1,
                d: 0,
                tx: height,
                ty: 0
            )
        default:
            preconditionFailure(
                "Hybrid rotation must be a verified quarter turn"
            )
        }
    }

    static func validate(
        geometry: DecodedVideoFrameGeometry
    ) throws {
        guard geometry.codedWidth > 0,
              geometry.codedHeight > 0,
              geometry.cleanAperture.x.isFinite,
              geometry.cleanAperture.y.isFinite,
              geometry.cleanAperture.width.isFinite,
              geometry.cleanAperture.height.isFinite,
              geometry.cleanAperture.width > 0,
              geometry.cleanAperture.height > 0,
              geometry.cleanAperture.x >= 0,
              geometry.cleanAperture.y >= 0,
              geometry.cleanAperture.x
                + geometry.cleanAperture.width
                <= Double(geometry.codedWidth),
              geometry.cleanAperture.y
                + geometry.cleanAperture.height
                <= Double(geometry.codedHeight),
              geometry.pixelAspectRatioNumerator > 0,
              geometry.pixelAspectRatioDenominator > 0,
              geometry.displayAspectRatio.isFinite,
              geometry.displayAspectRatio > 0 else {
            throw AetherMetalRendererError.invalidGeometry
        }
        guard [0, 90, 180, 270].contains(
            geometry.rotationDegrees
        ) else {
            throw AetherMetalRendererError
                .unsupportedRotation(
                    geometry.rotationDegrees
                )
        }
    }
}
