import XCTest
import AVFAudio
@testable import AetherEngine

/// #95: controller lifecycle around the tap's AsyncStream. Reader factory is injected
/// (startReader), so no media or session is involved; full engine wiring is exercised by
/// `aetherctl audiotap`.
@MainActor
final class AudioTapControllerTests: XCTestCase {

    private func makeBuffer(sourceTime: Double = 1.0) -> AudioTapBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: AetherEngine.audioTapFormat, frameCapacity: 480)!
        b.frameLength = 480
        return AudioTapBuffer(buffer: b, sourceTime: sourceTime, discontinuity: false)
    }

    func testYieldReachesConsumerAndTeardownFinishes() async {
        let controller = AudioTapController()
        let stream = controller.makeStream(startReader: { onStop in onStop {} })
        let yield = controller.makeYield()!
        yield(makeBuffer())
        controller.teardown()

        var received: [AudioTapBuffer] = []
        for await buf in stream { received.append(buf) }   // ends because teardown finished it
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].sourceTime, 1.0, accuracy: 0.001)
    }

    func testTeardownStopsReaderAndYieldGoesDead() {
        let controller = AudioTapController()
        var stopped = false
        _ = controller.makeStream(startReader: { onStop in onStop { stopped = true } })
        XCTAssertTrue(controller.hasDeliverySource)
        let yield = controller.makeYield()!
        controller.teardown()
        XCTAssertTrue(stopped)
        yield(makeBuffer())   // must be a harmless no-op after teardown
        XCTAssertNil(controller.makeYield())
    }

    func testNoDeliverySourceWhenStartReaderRegistersNothing() {
        let controller = AudioTapController()
        _ = controller.makeStream(startReader: { _ in })
        XCTAssertFalse(controller.hasDeliverySource)
    }

    func testLosslessDeliveryKeepsWholeBurstBeforeConsumerRuns() async {
        let burstCount = 512
        let controller = AudioTapController()
        let stream = controller.makeStream(lossless: true, startReader: { onStop in onStop {} })
        let yield = controller.makeYield()!
        for index in 0..<burstCount { yield(makeBuffer(sourceTime: Double(index) / 100)) }
        controller.teardown()
        var times: [Double] = []
        for await buffer in stream { times.append(buffer.sourceTime) }
        XCTAssertEqual(times.count, burstCount)
        for (index, time) in times.enumerated() {
            XCTAssertEqual(time, Double(index) / 100, accuracy: 0.00001)
        }
        XCTAssertNil(controller.makeYield())
    }

    func testDefaultDeliveryRetainsExistingNewest64Policy() async {
        let controller = AudioTapController()
        let stream = controller.makeStream(startReader: { onStop in onStop {} })
        let yield = controller.makeYield()!
        for index in 0..<200 { yield(makeBuffer(sourceTime: Double(index) / 100)) }
        controller.teardown()
        var received = 0
        for await _ in stream { received += 1 }
        XCTAssertEqual(received, 64)
    }
}
