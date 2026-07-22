import CoreMedia
import Testing
@testable import AetherEngine

@Suite("Hybrid decoded-frame presentation order")
struct HybridFramePresentationOrderTests {
    @Test("HEVC B-frames retain every source PTS in display order")
    func hevcBFramesRetainSourceDisplayOrder() {
        var order = HybridFramePresentationOrder<Double>(
            reorderDepth: 2
        )
        // Exact decode-order head from bbb-hevc-720p-10s.mp4. The old direct
        // callback path admitted 0.1667 and then failed when 0.1 arrived.
        let decodeOrder = [
            0.0,
            5.0 / 30.0,
            3.0 / 30.0,
            1.0 / 30.0,
            2.0 / 30.0,
            4.0 / 30.0,
        ]

        var emitted: [Double] = []
        for pts in decodeOrder {
            emitted += order.insert(
                pts,
                presentationTime: CMTime(
                    seconds: pts,
                    preferredTimescale: 90_000
                )
            )
        }
        emitted += order.drain()

        #expect(emitted == decodeOrder.sorted())
        #expect(emitted.count == decodeOrder.count)
    }

    @Test("A regression outside the declared window is not hidden")
    func regressionOutsideWindowRemainsObservable() {
        var order = HybridFramePresentationOrder<Double>(
            reorderDepth: 1
        )
        var emitted: [Double] = []
        for pts in [0.0, 3.0, 2.0, 1.0] {
            emitted += order.insert(
                pts,
                presentationTime: CMTime(
                    seconds: pts,
                    preferredTimescale: 600
                )
            )
        }
        emitted += order.drain()

        #expect(emitted == [0.0, 2.0, 1.0, 3.0])
    }

    @Test("Readiness cannot observe a frame retained for source reorder delay")
    func retainedFrameIsNotEmittedEarly() {
        var order = HybridFramePresentationOrder<Double>(
            reorderDepth: 2
        )

        #expect(order.insert(
            0.0,
            presentationTime: .zero
        ).isEmpty)
        #expect(order.insert(
            5.0 / 30.0,
            presentationTime: CMTime(
                value: 5,
                timescale: 30
            )
        ).isEmpty)
        #expect(order.insert(
            3.0 / 30.0,
            presentationTime: CMTime(
                value: 3,
                timescale: 30
            )
        ) == [0.0])
    }
}
