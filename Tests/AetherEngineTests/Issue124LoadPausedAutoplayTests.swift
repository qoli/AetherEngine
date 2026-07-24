import Testing
import Foundation
import AVFoundation
@testable import AetherEngine

/// #124: `LoadOptions.autoplay` lets a host mount media paused (a synchronized-start lobby, a
/// hold-at-mount / resume prompt) instead of the engine's unconditional autostart at load
/// completion. Default true keeps every current caller byte-identical. With false, load() skips the
/// terminal `host.play()` (and, on the native VOD path, the cold-start readiness gate), leaves
/// `playIntent` false, and settles `.loading -> .paused` through the already-wired `host.$isReady`
/// waypoint.
struct Issue124LoadPausedAutoplayTests {

    @Test("autoplay defaults to true so existing callers are byte-identical")
    func defaultsToTrue() {
        #expect(LoadOptions().autoplay == true)
    }

    @Test("autoplay is settable and carried on LoadOptions")
    func settable() {
        #expect(LoadOptions(autoplay: false).autoplay == false)
        #expect(LoadOptions(autoplay: false) != LoadOptions())
    }

    @Test("load performs its terminal autostart only when autoplay is set")
    func autostartGate() {
        #expect(AetherEngine.loadPerformsAutostart(LoadOptions(autoplay: true)))
        #expect(!AetherEngine.loadPerformsAutostart(LoadOptions(autoplay: false)))
    }

    @Test("native autostart remains loading until AVPlayer really plays")
    func nativeAutostartNeedsObservedPlayback() {
        #expect(
            AetherEngine.nativeObservedPlaybackState(
                status: .paused,
                playIntent: true,
                hasPresentedFrame: false
            ) == .loading
        )
        #expect(
            AetherEngine.nativeObservedPlaybackState(
                status: .waitingToPlayAtSpecifiedRate,
                playIntent: true,
                hasPresentedFrame: false
            ) == .loading
        )
        #expect(
            AetherEngine.nativeObservedPlaybackState(
                status: .playing,
                playIntent: true,
                hasPresentedFrame: false
            ) == .playing
        )
    }

    @Test("native pause and post-frame buffering remain truthful")
    func nativePauseAndRebufferState() {
        #expect(
            AetherEngine.nativeObservedPlaybackState(
                status: .paused,
                playIntent: false,
                hasPresentedFrame: true
            ) == .paused
        )
        #expect(
            AetherEngine.nativeObservedPlaybackState(
                status: .waitingToPlayAtSpecifiedRate,
                playIntent: true,
                hasPresentedFrame: true
            ) == .playing
        )
    }
}
