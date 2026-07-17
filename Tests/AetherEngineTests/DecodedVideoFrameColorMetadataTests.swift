import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import AetherEngine

@Suite("Decoded hybrid frame color metadata")
struct DecodedVideoFrameColorMetadataTests {
    private enum FixtureError: Error {
        case pixelBufferCreationFailed(OSStatus)
    }

    @Test("HDR10 captures exact 10-bit signaling and static payloads")
    func capturesHDR10Contract() throws {
        let pixelBuffer = try makePixelBuffer(
            format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        attachHDRColorTriplet(
            to: pixelBuffer,
            transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        )
        let mastering = Data(repeating: 0x11, count: 24)
        let lightLevel = Data(repeating: 0x22, count: 4)
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferMasteringDisplayColorVolumeKey,
            mastering as CFData,
            .shouldNotPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferContentLightLevelInfoKey,
            lightLevel as CFData,
            .shouldNotPropagate
        )

        let metadata = try DecodedVideoFrameColorMetadata.resolve(
            pixelBuffer: pixelBuffer,
            videoFormat: .hdr10
        )

        #expect(metadata.pixelEncoding == .yCbCr420BiPlanar(
            bitDepth: 10,
            range: .video
        ))
        #expect(metadata.colorPrimaries == .ituR2020)
        #expect(metadata.transferFunction == .pq)
        #expect(metadata.yCbCrMatrix == .ituR2020)
        #expect(metadata.masteringDisplayColorVolume == mastering)
        #expect(metadata.contentLightLevelInfo == lightLevel)
        #expect(metadata.ambientViewingEnvironment == nil)
    }

    @Test("HLG captures exact 10-bit signaling and ambient payload")
    func capturesHLGContract() throws {
        let pixelBuffer = try makePixelBuffer(
            format: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        )
        attachHDRColorTriplet(
            to: pixelBuffer,
            transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG
        )
        let ambient = Data(repeating: 0x33, count: 8)
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferAmbientViewingEnvironmentKey,
            ambient as CFData,
            .shouldNotPropagate
        )

        let metadata = try DecodedVideoFrameColorMetadata.resolve(
            pixelBuffer: pixelBuffer,
            videoFormat: .hlg
        )

        #expect(metadata.pixelEncoding == .yCbCr420BiPlanar(
            bitDepth: 10,
            range: .full
        ))
        #expect(metadata.colorPrimaries == .ituR2020)
        #expect(metadata.transferFunction == .hlg)
        #expect(metadata.yCbCrMatrix == .ituR2020)
        #expect(metadata.ambientViewingEnvironment == ambient)
    }

    @Test("HDR10 Plus uses the same validated PQ base-layer contract")
    func validatesHDR10PlusBaseLayer() throws {
        let pixelBuffer = try makePixelBuffer(
            format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        attachHDRColorTriplet(
            to: pixelBuffer,
            transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        )

        let metadata = try DecodedVideoFrameColorMetadata.resolve(
            pixelBuffer: pixelBuffer,
            videoFormat: .hdr10Plus
        )

        #expect(metadata.transferFunction == .pq)
        #expect(metadata.colorPrimaries == .ituR2020)
        #expect(metadata.yCbCrMatrix == .ituR2020)
    }

    @Test("Absent SDR attachments remain explicitly unspecified")
    func preservesAbsentSDRAttachments() throws {
        let pixelBuffer = try makePixelBuffer(
            format: kCVPixelFormatType_32BGRA
        )

        let metadata = try DecodedVideoFrameColorMetadata.resolve(
            pixelBuffer: pixelBuffer,
            videoFormat: .sdr
        )

        #expect(metadata.pixelEncoding == .bgra8)
        #expect(metadata.colorPrimaries == .unspecified)
        #expect(metadata.transferFunction == .unspecified)
        #expect(metadata.yCbCrMatrix == .unspecified)
    }

    @Test("HDR without a required attachment fails instead of guessing")
    func missingRequiredAttachmentFails() throws {
        let pixelBuffer = try makePixelBuffer(
            format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_2020,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_2020,
            .shouldPropagate
        )

        #expect(throws: DecodedVideoFrameColorMetadataError
            .missingRequiredStaticHDRAttachment(
                videoFormat: .hdr10,
                field: .transferFunction
            )) {
            try DecodedVideoFrameColorMetadata.resolve(
                pixelBuffer: pixelBuffer,
                videoFormat: .hdr10
            )
        }
    }

    @Test("Contradictory HDR transfer fails instead of relabeling the frame")
    func mismatchedTransferFails() throws {
        let pixelBuffer = try makePixelBuffer(
            format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        attachHDRColorTriplet(
            to: pixelBuffer,
            transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG
        )

        #expect(throws: DecodedVideoFrameColorMetadataError
            .mismatchedStaticHDRAttachment(
                videoFormat: .hdr10,
                field: .transferFunction,
                expected: "pq",
                actual: "hlg"
            )) {
            try DecodedVideoFrameColorMetadata.resolve(
                pixelBuffer: pixelBuffer,
                videoFormat: .hdr10
            )
        }
    }

    @Test("Eight-bit HDR buffers fail before reaching presentation")
    func eightBitHDRFails() throws {
        let pixelBuffer = try makePixelBuffer(
            format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        attachHDRColorTriplet(
            to: pixelBuffer,
            transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG
        )

        #expect(throws: DecodedVideoFrameColorMetadataError
            .unsupportedStaticHDRPixelFormat(
                videoFormat: .hlg,
                rawValue: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            )) {
            try DecodedVideoFrameColorMetadata.resolve(
                pixelBuffer: pixelBuffer,
                videoFormat: .hlg
            )
        }
    }

    @Test("Malformed static HDR payload length fails explicitly")
    func malformedStaticPayloadFails() throws {
        let pixelBuffer = try makePixelBuffer(
            format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        attachHDRColorTriplet(
            to: pixelBuffer,
            transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferMasteringDisplayColorVolumeKey,
            Data(repeating: 0, count: 23) as CFData,
            .shouldNotPropagate
        )

        #expect(throws: DecodedVideoFrameColorMetadataError
            .invalidAttachmentSize(
                field: .masteringDisplayColorVolume,
                expectedByteCount: 24,
                actualByteCount: 23
            )) {
            try DecodedVideoFrameColorMetadata.resolve(
                pixelBuffer: pixelBuffer,
                videoFormat: .hdr10
            )
        }
    }

    @Test("Static HDR payload with the wrong CF type fails explicitly")
    func malformedStaticPayloadTypeFails() throws {
        let pixelBuffer = try makePixelBuffer(
            format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        attachHDRColorTriplet(
            to: pixelBuffer,
            transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferContentLightLevelInfoKey,
            "not-data" as CFString,
            .shouldNotPropagate
        )

        #expect(throws: DecodedVideoFrameColorMetadataError
            .invalidAttachmentType(field: .contentLightLevelInfo)) {
            try DecodedVideoFrameColorMetadata.resolve(
                pixelBuffer: pixelBuffer,
                videoFormat: .hdr10
            )
        }
    }

    @Test("Decoded frame snapshots color metadata before attachments mutate")
    func frameOwnsImmutableColorSnapshot() throws {
        let pixelBuffer = try makePixelBuffer(
            format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        attachHDRColorTriplet(
            to: pixelBuffer,
            transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        )
        let frame = try DecodedVideoFrame(
            pixelBuffer: pixelBuffer,
            presentationTime: .zero,
            duration: CMTime(value: 1, timescale: 24),
            videoFormat: .hdr10,
            geometry: .init(
                codedWidth: 64,
                codedHeight: 64,
                cleanAperture: .init(
                    x: 0,
                    y: 0,
                    width: 64,
                    height: 64
                ),
                pixelAspectRatioNumerator: 1,
                pixelAspectRatioDenominator: 1,
                rotationDegrees: 0
            ),
            hdr10PlusT35: nil,
            generation: 1
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_2100_HLG,
            .shouldPropagate
        )

        #expect(frame.colorMetadata.transferFunction == .pq)
    }

    private func makePixelBuffer(format: OSType) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
            format,
            [
                kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw FixtureError.pixelBufferCreationFailed(status)
        }
        return pixelBuffer
    }

    private func attachHDRColorTriplet(
        to pixelBuffer: CVPixelBuffer,
        transfer: CFString
    ) {
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_2020,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            transfer,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_2020,
            .shouldPropagate
        )
    }
}
