import CoreMedia
import CoreVideo
import XCTest
@testable import AetherEngine

final class HybridFrameSchedulerTests: XCTestCase {
    private func frame(time: Double, generation: UInt64 = 7) -> DecodedVideoFrame {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                2,
                2,
                kCVPixelFormatType_32BGRA,
                nil,
                &pixelBuffer
            ),
            kCVReturnSuccess
        )
        return try! DecodedVideoFrame(
            pixelBuffer: pixelBuffer!,
            presentationTime: CMTime(seconds: time, preferredTimescale: 600),
            duration: CMTime(seconds: 1.0 / 24.0, preferredTimescale: 600),
            videoFormat: .sdr,
            geometry: .init(
                codedWidth: 2,
                codedHeight: 2,
                cleanAperture: .init(x: 0, y: 0, width: 2, height: 2),
                pixelAspectRatioNumerator: 1,
                pixelAspectRatioDenominator: 1,
                rotationDegrees: 0
            ),
            hdr10PlusT35: nil,
            generation: generation
        )
    }

    func testSelectsLatestFrameAtOrBeforeCarrierClock() {
        var scheduler = HybridFrameScheduler(maximumQueuedFrames: 4)
        scheduler.beginGeneration(7)
        _ = scheduler.enqueue(frame(time: 2.0))
        _ = scheduler.enqueue(frame(time: 1.0))
        _ = scheduler.enqueue(frame(time: 3.0))

        let selected = scheduler.selectFrame(
            for: CMTime(seconds: 2.1, preferredTimescale: 600),
            tolerance: .zero
        )

        XCTAssertEqual(try XCTUnwrap(selected).presentationTime.seconds, 2.0, accuracy: 0.0001)
        XCTAssertEqual(scheduler.queuedFrames.map { $0.presentationTime.seconds }, [3.0])
        XCTAssertEqual(scheduler.timelineDrops, 1)
    }

    func testDoesNotPresentFutureFrameBeforeCarrierClock() {
        var scheduler = HybridFrameScheduler()
        scheduler.beginGeneration(7)
        _ = scheduler.enqueue(frame(time: 2.0))

        XCTAssertNil(
            scheduler.selectFrame(
                for: CMTime(seconds: 1.9, preferredTimescale: 600),
                tolerance: .zero
            )
        )
        XCTAssertEqual(scheduler.queuedFrames.count, 1)
    }

    func testStaleGenerationNeverReachesQueue() {
        var scheduler = HybridFrameScheduler()
        scheduler.beginGeneration(8)

        XCTAssertEqual(scheduler.enqueue(frame(time: 1.0, generation: 7)), .staleGeneration)
        XCTAssertTrue(scheduler.queuedFrames.isEmpty)
        XCTAssertEqual(scheduler.staleGenerationDrops, 1)
    }

    func testQueuePressureIsObservable() {
        var scheduler = HybridFrameScheduler(maximumQueuedFrames: 2)
        scheduler.beginGeneration(7)
        _ = scheduler.enqueue(frame(time: 1.0))
        _ = scheduler.enqueue(frame(time: 2.0))

        XCTAssertEqual(scheduler.enqueue(frame(time: 3.0)), .acceptedAfterDroppingOldest(count: 1))
        XCTAssertEqual(scheduler.queuedFrames.map { $0.presentationTime.seconds }, [2.0, 3.0])
        XCTAssertEqual(scheduler.queuePressureDrops, 1)
    }
}
