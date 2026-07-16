import CoreMedia
import CoreVideo
import Testing
@testable import AetherEngine

@Suite("Hybrid presentation readiness gate")
struct HybridPresentationReadinessGateTests {
    @Test("Carrier and target frame are both required regardless of arrival order")
    func requiresBothSignals() throws {
        var carrierFirst = HybridPresentationReadinessGate()
        try carrierFirst.beginGeneration(
            7,
            targetTime: time(10)
        )
        #expect(carrierFirst.markCarrierReady(
            generation: 7
        ) == .acceptedWaiting)
        #expect(carrierFirst.state == .waiting(
            generation: 7,
            carrierReady: true,
            decodedFrameReady: false
        ))
        #expect(carrierFirst.considerDecodedFrame(
            frame(time: 10, generation: 7)
        ) == .becameReady)

        var frameFirst = HybridPresentationReadinessGate()
        try frameFirst.beginGeneration(
            8,
            targetTime: time(20)
        )
        #expect(frameFirst.considerDecodedFrame(
            frame(time: 20, generation: 8)
        ) == .acceptedWaiting)
        #expect(frameFirst.markCarrierReady(
            generation: 8
        ) == .becameReady)
    }

    @Test("Stale generation signals never unlock a newer presentation")
    func rejectsStaleGeneration() throws {
        var gate = HybridPresentationReadinessGate()
        try gate.beginGeneration(
            9,
            targetTime: time(30)
        )

        #expect(gate.markCarrierReady(
            generation: 8
        ) == .staleGeneration)
        #expect(gate.considerDecodedFrame(
            frame(time: 30, generation: 8)
        ) == .staleGeneration)
        #expect(gate.state == .waiting(
            generation: 9,
            carrierReady: false,
            decodedFrameReady: false
        ))
    }

    @Test("Pre-roll frame must intersect the target window before it can unlock")
    func rejectsEarlyPreroll() throws {
        var gate = HybridPresentationReadinessGate()
        try gate.beginGeneration(
            10,
            targetTime: time(100),
            toleranceBefore: time(0.1),
            toleranceAfter: time(0.25),
            carrierAlreadyReady: true
        )

        #expect(gate.considerDecodedFrame(
            frame(time: 99, duration: 0.04, generation: 10)
        ) == .frameOutsideTargetWindow)
        #expect(gate.considerDecodedFrame(
            frame(time: 99.88, duration: 0.04, generation: 10)
        ) == .becameReady)
        #expect(gate.state == .ready(
            generation: 10,
            framePresentationTime: time(99.88)
        ))
    }

    @Test("A new generation resets readiness and terminal failures are explicit")
    func generationResetAndFailure() throws {
        var gate = HybridPresentationReadinessGate()
        try gate.beginGeneration(
            11,
            targetTime: time(0),
            carrierAlreadyReady: true
        )
        #expect(gate.considerDecodedFrame(
            frame(time: 0, generation: 11)
        ) == .becameReady)

        try gate.beginGeneration(
            12,
            targetTime: time(50)
        )
        #expect(gate.state == .waiting(
            generation: 12,
            carrierReady: false,
            decodedFrameReady: false
        ))
        #expect(gate.failDecoder(
            generation: 12,
            reason: "fixture decode failed"
        ) == .terminalFailure)
        #expect(gate.state == .failed(
            generation: 12,
            error: .decoderFailed(reason: "fixture decode failed")
        ))
        #expect(gate.markCarrierReady(
            generation: 12
        ) == .terminalFailure)
    }

    @Test("Invalid target and tolerance fail before a generation starts")
    func invalidInputs() {
        var gate = HybridPresentationReadinessGate()
        #expect(throws: HybridPresentationReadinessError.invalidTargetTime) {
            try gate.beginGeneration(
                1,
                targetTime: .invalid
            )
        }
        #expect(throws: HybridPresentationReadinessError.invalidTolerance) {
            try gate.beginGeneration(
                1,
                targetTime: .zero,
                toleranceBefore: CMTime(
                    seconds: -0.1,
                    preferredTimescale: 600
                )
            )
        }
        #expect(gate.state == .idle)
    }

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 60_000)
    }

    private func frame(
        time seconds: Double,
        duration: Double = 1.0 / 24.0,
        generation: UInt64
    ) -> DecodedVideoFrame {
        var pixelBuffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(
            kCFAllocatorDefault,
            2,
            2,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        ) == kCVReturnSuccess)
        return DecodedVideoFrame(
            pixelBuffer: pixelBuffer!,
            presentationTime: time(seconds),
            duration: time(duration),
            videoFormat: .sdr,
            geometry: .init(
                codedWidth: 2,
                codedHeight: 2,
                cleanAperture: .init(
                    x: 0,
                    y: 0,
                    width: 2,
                    height: 2
                ),
                pixelAspectRatioNumerator: 1,
                pixelAspectRatioDenominator: 1,
                rotationDegrees: 0
            ),
            hdr10PlusT35: nil,
            generation: generation
        )
    }
}
