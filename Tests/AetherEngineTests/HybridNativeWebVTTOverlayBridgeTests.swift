import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AetherEngine

@Suite("Hybrid native WebVTT presentation bridge")
@MainActor
struct HybridNativeWebVTTOverlayBridgeTests {
    @Test("AVKit legible callbacks exclusively own the Aether text overlay")
    func nativeCueOwnership() throws {
        let view = AetherHybridPresentationView(
            frame: CGRect(
                x: 0,
                y: 0,
                width: 1920,
                height: 1080
            )
        )
        #if canImport(UIKit)
        view.layoutIfNeeded()
        #elseif canImport(AppKit)
        view.layoutSubtreeIfNeeded()
        #endif
        let bridge = HybridNativeWebVTTOverlayBridge(
            presentationView: view,
            expectedRenditionCount: 1
        )
        let item = AVPlayerItem(
            url: URL(
                fileURLWithPath:
                    "/tmp/aether-native-webvtt-bridge.m3u8"
            )
        )
        try bridge.attach(to: item)
        var activationCount = 0
        bridge.nativeSelectionDidActivate = {
            activationCount += 1
        }

        bridge.receive(
            [NSAttributedString(string: "Native cue")],
            nativeSampleCount: 0,
            itemTime: CMTime(
                seconds: 0.25,
                preferredTimescale: 600
            )
        )

        #expect(bridge.isAttached)
        #expect(activationCount == 1)
        #expect(view.diagnostics.nativeWebVTTVisible)

        bridge.setOverlaySubtitleActive(true)
        bridge.receive(
            [NSAttributedString(string: "Suppressed cue")],
            nativeSampleCount: 0,
            itemTime: CMTime(
                seconds: 1,
                preferredTimescale: 600
            )
        )

        #expect(!view.diagnostics.nativeWebVTTVisible)
        #expect(activationCount == 1)

        bridge.setOverlaySubtitleActive(false)
        bridge.receive(
            [],
            nativeSampleCount: 0,
            itemTime: CMTime(
                seconds: 2,
                preferredTimescale: 600
            )
        )
        #expect(!view.diagnostics.nativeWebVTTVisible)

        bridge.detach()
        #expect(!bridge.isAttached)
    }

    @Test("Binding the bridge to another carrier item fails explicitly")
    func carrierItemRebindingFails() throws {
        let bridge = HybridNativeWebVTTOverlayBridge(
            presentationView: AetherHybridPresentationView(),
            expectedRenditionCount: 1
        )
        let first = AVPlayerItem(
            url: URL(fileURLWithPath: "/tmp/first.m3u8")
        )
        let second = AVPlayerItem(
            url: URL(fileURLWithPath: "/tmp/second.m3u8")
        )
        try bridge.attach(to: first)

        #expect(throws: AetherHybridPresentationError
            .carrierBindingChanged) {
            try bridge.attach(to: second)
        }
        bridge.detach()
    }
}
