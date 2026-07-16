import CoreGraphics
import Libavutil
import Testing
@testable import AetherEngine

@Suite("Hybrid video presentation geometry")
struct HybridVideoPresentationLayoutTests {
    @Test("Aspect fit and fill use real-video geometry, not the carrier canvas")
    func aspectFitAndFill() throws {
        let geometry = makeGeometry(
            width: 1_920,
            height: 1_080
        )
        let fit = try #require(
            try HybridVideoPresentationLayout(
                geometry: geometry,
                drawableSize: CGSize(width: 800, height: 600),
                gravity: .resizeAspect
            )
        )
        #expect(approximatelyEqual(fit.targetRect.minX, 0))
        #expect(approximatelyEqual(fit.targetRect.minY, 75))
        #expect(approximatelyEqual(fit.targetRect.width, 800))
        #expect(approximatelyEqual(fit.targetRect.height, 450))

        let fill = try #require(
            try HybridVideoPresentationLayout(
                geometry: geometry,
                drawableSize: CGSize(width: 800, height: 600),
                gravity: .resizeAspectFill
            )
        )
        #expect(approximatelyEqual(fill.targetRect.minX, -133.333_333))
        #expect(approximatelyEqual(fill.targetRect.minY, 0))
        #expect(approximatelyEqual(fill.targetRect.width, 1_066.666_667))
        #expect(approximatelyEqual(fill.targetRect.height, 600))
    }

    @Test("Anamorphic sample aspect ratio controls the display viewport")
    func anamorphicSampleAspectRatio() throws {
        let geometry = makeGeometry(
            width: 720,
            height: 480,
            sarNumerator: 32,
            sarDenominator: 27
        )
        let layout = try #require(
            try HybridVideoPresentationLayout(
                geometry: geometry,
                drawableSize: CGSize(width: 1_920, height: 1_080),
                gravity: .resizeAspect
            )
        )

        #expect(approximatelyEqual(layout.targetRect.minX, 0))
        #expect(approximatelyEqual(layout.targetRect.minY, 0))
        #expect(approximatelyEqual(layout.targetRect.width, 1_920))
        #expect(approximatelyEqual(layout.targetRect.height, 1_080))
        let expectedPixelAspectRatio: CGFloat = 32.0 / 27.0
        #expect(approximatelyEqual(
            layout.pixelAspectRatio,
            expectedPixelAspectRatio
        ))
    }

    @Test("Clockwise quarter turns map the clean aperture into the rotated viewport")
    func clockwiseQuarterTurn() throws {
        let geometry = makeGeometry(
            width: 1_920,
            height: 1_088,
            cleanAperture: .init(
                x: 0,
                y: 4,
                width: 1_920,
                height: 1_080
            ),
            rotationDegrees: 90
        )
        let layout = try #require(
            try HybridVideoPresentationLayout(
                geometry: geometry,
                drawableSize: CGSize(width: 1_080, height: 1_920),
                gravity: .resizeAspect
            )
        )

        #expect(layout.rotatedDisplaySize == CGSize(
            width: 1_080,
            height: 1_920
        ))
        #expect(layout.targetRect == CGRect(
            x: 0,
            y: 0,
            width: 1_080,
            height: 1_920
        ))
        let mappedCorners = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1_920, y: 0),
            CGPoint(x: 0, y: 1_080),
            CGPoint(x: 1_920, y: 1_080),
        ].map { $0.applying(layout.rotationTransform) }
        let bounds = mappedCorners.reduce(CGRect.null) {
            $0.union(CGRect(origin: $1, size: .zero))
        }
        #expect(approximatelyEqual(bounds.minX, 0))
        #expect(approximatelyEqual(bounds.minY, 0))
        #expect(approximatelyEqual(bounds.maxX, 1_080))
        #expect(approximatelyEqual(bounds.maxY, 1_920))
    }

    @Test("Every canonical rotation keeps the transformed image in a positive-origin rectangle")
    func everyCanonicalRotation() throws {
        for rotation in [0, 90, 180, 270] {
            let geometry = makeGeometry(
                width: 320,
                height: 180,
                rotationDegrees: rotation
            )
            let expectedSize = rotation == 90 || rotation == 270
                ? CGSize(width: 180, height: 320)
                : CGSize(width: 320, height: 180)
            let layout = try #require(
                try HybridVideoPresentationLayout(
                    geometry: geometry,
                    drawableSize: expectedSize,
                    gravity: .resizeAspect
                )
            )
            let mappedCorners = [
                CGPoint(x: 0, y: 0),
                CGPoint(x: 320, y: 0),
                CGPoint(x: 0, y: 180),
                CGPoint(x: 320, y: 180),
            ].map { $0.applying(layout.rotationTransform) }
            let bounds = mappedCorners.reduce(CGRect.null) {
                $0.union(CGRect(origin: $1, size: .zero))
            }
            #expect(approximatelyEqual(bounds.minX, 0))
            #expect(approximatelyEqual(bounds.minY, 0))
            #expect(approximatelyEqual(
                bounds.width,
                expectedSize.width
            ))
            #expect(approximatelyEqual(
                bounds.height,
                expectedSize.height
            ))
        }
    }

    @Test("Malformed crop and non-quarter rotation fail explicitly")
    func malformedGeometryFails() {
        let invalidCrop = makeGeometry(
            width: 100,
            height: 100,
            cleanAperture: .init(
                x: 10,
                y: 0,
                width: 100,
                height: 100
            )
        )
        #expect(throws: AetherMetalRendererError.invalidGeometry) {
            _ = try HybridVideoPresentationLayout(
                geometry: invalidCrop,
                drawableSize: CGSize(width: 100, height: 100),
                gravity: .resizeAspect
            )
        }

        let invalidRotation = makeGeometry(
            width: 100,
            height: 100,
            rotationDegrees: 45
        )
        #expect(throws: AetherMetalRendererError.unsupportedRotation(45)) {
            _ = try HybridVideoPresentationLayout(
                geometry: invalidRotation,
                drawableSize: CGSize(width: 100, height: 100),
                gravity: .resizeAspect
            )
        }
    }

    @Test("Software decoder metadata preserves crop and frame SAR")
    func decoderMetadataPreservesCropAndSAR() throws {
        let frame = try #require(av_frame_alloc())
        defer {
            var frameToFree: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&frameToFree)
        }
        frame.pointee.width = 720
        frame.pointee.height = 486
        frame.pointee.crop_top = 2
        frame.pointee.crop_bottom = 4
        frame.pointee.crop_left = 8
        frame.pointee.crop_right = 12
        frame.pointee.sample_aspect_ratio = AVRational(
            num: 32,
            den: 27
        )

        let metadata = try DecodedFramePresentationMetadata(
            frame: frame,
            streamPixelAspectRatio: AVRational(num: 1, den: 1)
        )
        #expect(metadata.codedWidth == 720)
        #expect(metadata.codedHeight == 486)
        #expect(metadata.cleanApertureX == 8)
        #expect(metadata.cleanApertureY == 4)
        #expect(metadata.cleanApertureWidth == 700)
        #expect(metadata.cleanApertureHeight == 480)
        #expect(metadata.pixelAspectRatioNumerator == 32)
        #expect(metadata.pixelAspectRatioDenominator == 27)
    }

    @Test("Decoder output accepts exact coded or exact cropped dimensions and rejects guesses")
    func decoderDimensionContract() throws {
        let metadata = try DecodedFramePresentationMetadata(
            codedWidth: 1_920,
            codedHeight: 1_088,
            cropTop: 4,
            cropBottom: 4,
            cropLeft: 0,
            cropRight: 0,
            pixelAspectRatioNumerator: 1,
            pixelAspectRatioDenominator: 1
        )
        let coded = try HybridVideoDecodeSink.resolveFrameGeometry(
            pixelBufferWidth: 1_920,
            pixelBufferHeight: 1_088,
            metadata: metadata,
            rotationDegrees: 0
        )
        #expect(coded.cleanAperture == .init(
            x: 0,
            y: 4,
            width: 1_920,
            height: 1_080
        ))

        let decoderCropped = try HybridVideoDecodeSink
            .resolveFrameGeometry(
                pixelBufferWidth: 1_920,
                pixelBufferHeight: 1_080,
                metadata: metadata,
                rotationDegrees: 90
            )
        #expect(decoderCropped.codedHeight == 1_080)
        #expect(decoderCropped.cleanAperture == .init(
            x: 0,
            y: 0,
            width: 1_920,
            height: 1_080
        ))
        #expect(decoderCropped.rotationDegrees == 90)

        let expected = HybridVideoDecodeSinkError
            .decodedFrameDimensionsDiverged(
                pixelWidth: 1_280,
                pixelHeight: 720,
                metadataWidth: 1_920,
                metadataHeight: 1_088
            )
        #expect(throws: expected) {
            _ = try HybridVideoDecodeSink.resolveFrameGeometry(
                pixelBufferWidth: 1_280,
                pixelBufferHeight: 720,
                metadata: metadata,
                rotationDegrees: 0
            )
        }
    }

    private func makeGeometry(
        width: Int,
        height: Int,
        cleanAperture:
            DecodedVideoFrameGeometry.CleanAperture? = nil,
        sarNumerator: Int = 1,
        sarDenominator: Int = 1,
        rotationDegrees: Int = 0
    ) -> DecodedVideoFrameGeometry {
        DecodedVideoFrameGeometry(
            codedWidth: width,
            codedHeight: height,
            cleanAperture: cleanAperture ?? .init(
                x: 0,
                y: 0,
                width: Double(width),
                height: Double(height)
            ),
            pixelAspectRatioNumerator: sarNumerator,
            pixelAspectRatioDenominator: sarDenominator,
            rotationDegrees: rotationDegrees
        )
    }

    private func approximatelyEqual(
        _ lhs: CGFloat,
        _ rhs: CGFloat,
        tolerance: CGFloat = 0.000_01
    ) -> Bool {
        abs(lhs - rhs) <= tolerance
    }
}
