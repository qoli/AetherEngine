import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import AetherEngine

@Suite("Hybrid sample-buffer presentation")
@MainActor
struct AetherHybridPresentationViewTests {
    private enum FixtureError: Error {
        case pixelBufferCreationFailed(OSStatus)
        case carrierTimebaseMissing
        case sampleAttachmentsMissing
    }

    @Test("Display layer binds to the exact carrier item timebase and rejects rebinding")
    func exactCarrierTimebaseBinding() throws {
        let view = AetherHybridPresentationView()
        let firstItem = makeCarrierItem(path: "first")
        let firstTimebase = try requireTimebase(firstItem)

        try view.beginGeneration(0, videoFormat: .sdr)
        try view.bindCarrierClock(
            item: firstItem,
            timebase: firstTimebase
        )
        try view.validateCarrierClock(
            item: firstItem,
            timebase: firstTimebase
        )

        #expect(view.diagnostics.carrierTimebaseBound)
        #expect(
            sameObject(view.controlTimebase, firstTimebase)
        )

        let secondItem = makeCarrierItem(path: "second")
        let secondTimebase = try requireTimebase(secondItem)
        #expect(throws: AetherHybridPresentationError
            .carrierBindingChanged) {
            try view.bindCarrierClock(
                item: secondItem,
                timebase: secondTimebase
            )
        }
    }

    @Test("Old generations are discarded and a new generation flushes pending samples")
    func generationFlushAndStaleDiscard() throws {
        let view = AetherHybridPresentationView()
        try view.beginGeneration(4, videoFormat: .sdr)

        #expect(try view.enqueue(makeSDRFrame(
            timeValue: 0,
            generation: 3
        )) == .staleGeneration)
        let acceptedFrame = try makeSDRFrame(
            timeValue: 0,
            generation: 4
        )
        #expect(try view.enqueue(acceptedFrame) == .accepted)
        #expect(view.diagnostics.pendingSampleBuffers == 1)
        #expect(view.diagnostics.staleGenerationDrops == 1)
        #expect(
            view.diagnostics.lastAcceptedGeometry
                == acceptedFrame.geometry
        )
        #expect(
            view.diagnostics.lastAcceptedFrameDurationSeconds
                == acceptedFrame.duration.seconds
        )

        try view.beginGeneration(5, videoFormat: .sdr)
        #expect(view.diagnostics.generation == 5)
        #expect(view.diagnostics.pendingSampleBuffers == 0)
        #expect(view.diagnostics.lastEnqueuedTimeSeconds == nil)
        #expect(
            view.diagnostics.lastAcceptedFrameDurationSeconds == nil
        )
        #expect(view.diagnostics.lastAcceptedGeometry == nil)
    }

    @Test("Pending samples are bounded without dropping an accepted frame")
    func pendingQueueIsBoundedWithoutDrop() throws {
        let view = AetherHybridPresentationView()
        try view.beginGeneration(1, videoFormat: .sdr)

        for index in 0..<AetherHybridPresentationView
            .maximumPendingSampleBuffers {
            #expect(try view.enqueue(makeSDRFrame(
                timeValue: Int64(index),
                generation: 1
            )) == .accepted)
        }

        #expect(view.diagnostics.pendingSampleBuffers == 24)
        #expect(throws: AetherHybridPresentationError
            .pendingQueueOverflow(limit: 24)) {
            try view.enqueue(makeSDRFrame(
                timeValue: 24,
                generation: 1
            ))
        }
        #expect(view.diagnostics.pendingSampleBuffers == 24)
    }

    @Test("Regressing or duplicate PTS fails instead of being displayed immediately")
    func nonMonotonicPTSIsTerminal() throws {
        let view = AetherHybridPresentationView()
        try view.beginGeneration(2, videoFormat: .sdr)
        _ = try view.enqueue(makeSDRFrame(
            timeValue: 10,
            generation: 2
        ))
        let duplicate = makeTime(10)

        #expect(throws: AetherHybridPresentationError
            .nonMonotonicPresentationTime(
                previous: duplicate,
                current: duplicate
            )) {
            try view.enqueue(makeSDRFrame(
                timeValue: 10,
                generation: 2
            ))
        }
    }

    @Test("CMSampleBuffer preserves timing, color, static HDR and HDR10 Plus T.35")
    func sampleBufferMetadataContract() throws {
        let view = AetherHybridPresentationView()
        let hdr10Plus = Data([0xB5, 0x00, 0x3C, 0x00, 0x01])
        let mastering = Data(repeating: 0x11, count: 24)
        let lightLevel = Data(repeating: 0x22, count: 4)
        let pixelBuffer = try makePixelBuffer(
            format:
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        attachHDRColorTriplet(to: pixelBuffer)
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferMasteringDisplayColorVolumeKey,
            mastering as CFData,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferContentLightLevelInfoKey,
            lightLevel as CFData,
            .shouldPropagate
        )
        let frame = try DecodedVideoFrame(
            pixelBuffer: pixelBuffer,
            presentationTime: CMTime(value: 9_000, timescale: 90_000),
            duration: CMTime(value: 3_750, timescale: 90_000),
            videoFormat: .hdr10Plus,
            geometry: geometry(rotationDegrees: 0),
            hdr10PlusT35: hdr10Plus,
            generation: 8
        )

        let sampleBuffer = try view.makeSampleBuffer(frame)
        #expect(
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                == frame.presentationTime
        )
        #expect(
            CMSampleBufferGetDuration(sampleBuffer)
                == frame.duration
        )

        let format = try #require(
            CMSampleBufferGetFormatDescription(sampleBuffer)
        )
        let primaries = try #require(
            CMFormatDescriptionGetExtension(
                format,
                extensionKey:
                    kCMFormatDescriptionExtension_ColorPrimaries
            )
        )
        #expect(CFEqual(
            primaries,
            kCMFormatDescriptionColorPrimaries_ITU_R_2020
        ))
        let masteringExtension = try #require(
            CMFormatDescriptionGetExtension(
                format,
                extensionKey:
                    kCMFormatDescriptionExtension_MasteringDisplayColorVolume
            ) as? Data
        )
        #expect(masteringExtension == mastering)

        let attachments = try sampleAttachments(sampleBuffer)
        #expect(
            attachments[
                kCMSampleAttachmentKey_HDR10PlusPerFrameData
            ] as? Data == hdr10Plus
        )
        #expect(
            attachments[
                kCMSampleAttachmentKey_DisplayImmediately
            ] == nil
        )
    }

    private func makeCarrierItem(path: String) -> AVPlayerItem {
        AVPlayerItem(asset: AVURLAsset(
            url: URL(
                string: "https://example.invalid/\(path).m3u8"
            )!
        ))
    }

    private func requireTimebase(
        _ item: AVPlayerItem
    ) throws -> CMTimebase {
        guard let timebase = item.timebase else {
            throw FixtureError.carrierTimebaseMissing
        }
        return timebase
    }

    private func sameObject(
        _ lhs: CMTimebase?,
        _ rhs: CMTimebase
    ) -> Bool {
        guard let lhs else { return false }
        return Unmanaged.passUnretained(lhs).toOpaque()
            == Unmanaged.passUnretained(rhs).toOpaque()
    }

    private func makeSDRFrame(
        timeValue: Int64,
        generation: UInt64
    ) throws -> DecodedVideoFrame {
        try DecodedVideoFrame(
            pixelBuffer: makePixelBuffer(
                format: kCVPixelFormatType_32BGRA
            ),
            presentationTime: makeTime(timeValue),
            duration: CMTime(value: 1, timescale: 24),
            videoFormat: .sdr,
            geometry: geometry(rotationDegrees: 0),
            hdr10PlusT35: nil,
            generation: generation
        )
    }

    private func makeTime(_ value: Int64) -> CMTime {
        CMTime(value: value, timescale: 24)
    }

    private func geometry(
        rotationDegrees: Int
    ) -> DecodedVideoFrameGeometry {
        .init(
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
            rotationDegrees: rotationDegrees
        )
    }

    private func makePixelBuffer(
        format: OSType
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
            format,
            [
                kCVPixelBufferIOSurfacePropertiesKey:
                    NSDictionary(),
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess,
              let pixelBuffer else {
            throw FixtureError
                .pixelBufferCreationFailed(status)
        }
        return pixelBuffer
    }

    private func attachHDRColorTriplet(
        to pixelBuffer: CVPixelBuffer
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
            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_2020,
            .shouldPropagate
        )
    }

    private func sampleAttachments(
        _ sampleBuffer: CMSampleBuffer
    ) throws -> [CFString: Any] {
        guard let array =
                CMSampleBufferGetSampleAttachmentsArray(
                    sampleBuffer,
                    createIfNecessary: false
                ),
              CFArrayGetCount(array) == 1,
              let raw = CFArrayGetValueAtIndex(array, 0) else {
            throw FixtureError.sampleAttachmentsMissing
        }
        return unsafeBitCast(
            raw,
            to: CFDictionary.self
        ) as NSDictionary as! [CFString: Any]
    }
}
