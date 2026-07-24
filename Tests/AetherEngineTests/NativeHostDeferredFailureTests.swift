import AVFoundation
import Foundation
import Testing
@testable import AetherEngine

/// Covers the shared deferred-failure resolution used before an exact-contract
/// same-item recovery. Elapsed time can confirm that recovery is still needed,
/// but cannot turn generic AVPlayer trouble into a terminal.
///
/// Both `item.status == .failed` and (new) `failedToPlayToEndTime` on the lean remote-HLS live
/// path feed this decision. The reported bug (Reddit, live IPTV m3u8): segments started 404ing
/// after the initial buffer, AVPlayer fired `failedToPlayToEndTime` and parked at rate 0 with the
/// clock frozen, but `item.status` stayed `readyToPlay`. This decision is the
/// gate that must request same-item recovery for that case.
///
/// The notification -> handler WIRING needs a real stalling stream and is device/path-verified, not
/// unit-tested here (the whole NativeAVPlayerHost is AVPlayer-bound). This locks the recovery contract
/// the wiring depends on, so the change cannot start false-positiving on streams that recover.
@Suite("NativeAVPlayerHost deferred-failure resolution")
struct NativeHostDeferredFailureTests {

    @MainActor
    @Test("A late host teardown preserves a successor player item")
    func teardownPreservesSuccessorItem() {
        let player = AVPlayer()
        let host = NativeAVPlayerHost(avPlayer: player)
        host.load(
            url: URL(fileURLWithPath: "/not-opened.mp4"),
            startPosition: nil
        )
        let successor = AVPlayerItem(asset: AVMutableComposition())
        player.replaceCurrentItem(with: successor)

        host.tearDown()

        #expect(player.currentItem === successor)
        player.replaceCurrentItem(with: nil)
    }

    @MainActor
    @Test("Repeated recovery reloads preserve the exact native load contract")
    func recoveryReloadPreservesExactContract() {
        let player = AVPlayer()
        let host =
            NativeAVPlayerHost(
                avPlayer: player
            )
        let url = URL(
            fileURLWithPath:
                "/not-opened-contract.mov"
        )
        let headers = [
            "Authorization": "Bearer test",
            "Referer": "https://catalog.test/item",
        ]
        host.load(
            url: url,
            startPosition: 3,
            perFrameHDR: false,
            skipInitialSeek: true,
            forwardBufferDuration: 0,
            surfaceEndFailures: true,
            httpHeaders: headers
        )

        #expect(
            host.reloadCurrentItemInPlace(
                at: 17
            )
        )
        #expect(
            host.activeLoadContract
                == NativeAVPlayerHost
                    .LoadContract(
                        url: url,
                        startPosition: 17,
                        perFrameHDR: false,
                        skipInitialSeek: true,
                        forwardBufferDuration: 0,
                        surfaceEndFailures: true,
                        httpHeaders: headers
                    )
        )
        #expect(
            host.reloadCurrentItemInPlace(
                at: 29
            )
        )
        #expect(
            host.activeLoadContract?
                .startPosition == 29
        )
        #expect(
            host.activeLoadContract?
                .httpHeaders == headers
        )

        host.tearDown()
        #expect(
            host.activeLoadContract == nil
        )
    }

    @Test("Requests recovery when the player stopped and the clock stayed frozen")
    func recoversWhenStoppedAndFrozen() {
        #expect(NativeAVPlayerHost.shouldSurfaceDeferredFailure(
            isPlaying: false, clockAtFailure: 30.0, clockNow: 30.0))
    }

    @Test("Clears when the player resumed playing (self-healing transient)")
    func clearsWhenPlaying() {
        #expect(!NativeAVPlayerHost.shouldSurfaceDeferredFailure(
            isPlaying: true, clockAtFailure: 30.0, clockNow: 30.0))
    }

    @Test("Clears when the clock advanced past the threshold (playback recovered)")
    func clearsWhenClockAdvanced() {
        #expect(!NativeAVPlayerHost.shouldSurfaceDeferredFailure(
            isPlaying: false, clockAtFailure: 30.0, clockNow: 31.0))
    }

    @Test("Requests recovery when clock creep is not real progress")
    func recoversWhenSubThresholdCreep() {
        #expect(NativeAVPlayerHost.shouldSurfaceDeferredFailure(
            isPlaying: false, clockAtFailure: 30.0, clockNow: 30.4))
    }
}
