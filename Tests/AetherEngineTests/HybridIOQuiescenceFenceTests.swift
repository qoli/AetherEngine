import CoreMedia
import Foundation
import Testing
@testable import AetherEngine

private actor HybridIOQuiescenceGate {
    private var continuation:
        CheckedContinuation<Void, Never>?
    private var entered = false

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }

    var isEntered: Bool { entered }
}

private final class HybridFenceProvider:
    HybridCarrierTransportProvider,
    @unchecked Sendable
{
    private let gate: HybridIOQuiescenceGate
    private let lock = NSLock()
    private var closed = false
    private var waitStarted = false
    private var waitFinished = false

    init(gate: HybridIOQuiescenceGate) {
        self.gate = gate
    }

    var hybridVideoFormat: VideoFormat? { .sdr }
    var hybridDolbyVisionConfiguration:
        AetherDolbyVisionConfiguration? { nil }
    var hybridVideoFrameRate: Double? { 24 }

    func sourceTrackID(forAudioOrdinal ordinal: Int) -> Int? {
        nil
    }

    func restartMedia(
        for intent: HybridSeekIntent
    ) throws -> BlackCarrierMediaFanoutRestartResult {
        .stale(currentGeneration: 0)
    }

    func prepareHybridGeneration(segmentIndex: Int) throws {}
    func advanceVideoDecodeDemand(to time: CMTime) throws {}

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    func closeAndWaitForIOQuiescence() async {
        close()
        markWaitStarted()
        await gate.wait()
        markWaitFinished()
    }

    private func markWaitStarted() {
        lock.lock()
        waitStarted = true
        lock.unlock()
    }

    private func markWaitFinished() {
        lock.lock()
        waitFinished = true
        lock.unlock()
    }

    var snapshot: (closed: Bool, started: Bool, finished: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (closed, waitStarted, waitFinished)
    }

    func initSegment() -> Data? { nil }
    func mediaSegment(at index: Int) -> Data? { nil }
    var segmentCount: Int { 1 }
    func segmentDuration(at index: Int) -> Double { 1 }
    var playlistType: HLSPlaylistType { .vod }
}

@Suite("Hybrid I/O quiescence release fence", .serialized)
struct HybridIOQuiescenceFenceTests {
    @Test("Provider coordinator does not admit a successor before ioStopped")
    func coordinatorAwaitsProviderReleaseFence() async {
        let gate = HybridIOQuiescenceGate()
        let provider = HybridFenceProvider(gate: gate)
        let coordinator = HybridPlaybackProviderCoordinator(
            provider: provider
        )
        let successorAdmitted = LockedFlag()

        let close = Task {
            await coordinator.closeAndWaitForIOQuiescence()
            successorAdmitted.set()
        }
        for _ in 0..<100 where !provider.snapshot.started {
            await Task.yield()
        }

        #expect(provider.snapshot.closed)
        #expect(provider.snapshot.started)
        #expect(!provider.snapshot.finished)
        #expect(!successorAdmitted.value)

        await gate.release()
        await close.value
        #expect(provider.snapshot.finished)
        #expect(successorAdmitted.value)
    }

    @MainActor
    @Test("Outer stop publishes cancelled only after the route release fence")
    func outerStopAwaitsRouteReleaseFence() async {
        let gate = HybridIOQuiescenceGate()
        let session = AetherPlaybackSession(
            url: URL(
                fileURLWithPath:
                    "/tmp/aether-io-quiescence-fence"
            ),
            options: LoadOptions(),
            variantSelection: .highestBandwidth
        )
        session.installRouteIOQuiescenceTestHarness {
            await gate.wait()
        }

        session.stop()
        for _ in 0..<100 where !(await gate.isEntered) {
            await Task.yield()
        }

        #expect(session.livenessSnapshot.phase == .cancelling)
        #expect(session.state != .stopped)
        #expect(session.terminalFailure == nil)

        await gate.release()
        await session.waitForStopIOQuiescence()
        #expect(session.livenessSnapshot.phase == .cancelled)
        #expect(session.state == .stopped)
        #expect(session.terminalFailure == nil)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
