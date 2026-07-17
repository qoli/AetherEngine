import Foundation
import Testing
@testable import AetherEngine

@Suite("Aether playback launch boundary")
struct AetherPlaybackLaunchBoundaryTests {
    @Test("HLS classification is based on bytes, including BOM and whitespace")
    func hlsSignatureClassification() throws {
        let prefix = Data(
            [0xEF, 0xBB, 0xBF]
                + Array(" \n\t#EXTM3U\n#EXT-X-VERSION:7".utf8)
        )

        #expect(
            try AetherURLPlaybackSourceClassifier
                .classify(prefix: prefix) == .hls
        )
    }

    @Test("A misleading m3u8 path cannot override progressive bytes")
    func suffixDoesNotControlClassification() throws {
        let progressivePrefix = Data([
            0x00, 0x00, 0x00, 0x18,
            0x66, 0x74, 0x79, 0x70,
            0x69, 0x73, 0x6F, 0x6D,
        ])

        #expect(
            try AetherURLPlaybackSourceClassifier
                .classify(prefix: progressivePrefix)
                == .progressive
        )
    }

    @Test("Empty classification evidence fails instead of choosing a route")
    func emptyPrefixFails() {
        #expect(throws:
            AetherURLPlaybackSourceClassificationError
                .emptyResource
        ) {
            try AetherURLPlaybackSourceClassifier
                .classify(prefix: Data())
        }
    }

    @Test("Local file classification reads only source bytes")
    func localFileClassification() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("not-a-manifest.mp4")
        try Data("#EXTM3U\n#EXT-X-ENDLIST\n".utf8).write(to: url)

        #expect(
            try await AetherURLPlaybackSourceClassifier
                .classify(url: url) == .hls
        )
    }

    @MainActor
    @Test("Native session factory rejects a Hybrid route before asset creation")
    func nativeSessionRejectsHybridPreflight() throws {
        let profile = AetherSourceProfile(
            sourceKind: .progressive,
            isSeekableVOD: true,
            videoCodec: .vp9,
            videoFormat: .sdr
        )
        let preflight = PlaybackPreflight.resolve(
            sourceProfile: profile,
            hlsPackaging: nil,
            hybridCapabilities:
                AetherHybridPlaybackSession.capabilities
        )
        let expected = AetherNativePlaybackSessionError
            .preflightRequiresNative(
                route: preflight.route,
                reason: preflight.reason
            )

        #expect(throws: expected) {
            try AetherNativePlaybackSession.make(
                url: URL(fileURLWithPath: "/not-opened.mp4"),
                preflightResult: preflight
            )
        }
    }

    @MainActor
    @Test("A native session exclusively owns and tears down its player item")
    func nativeSessionOwnership() throws {
        let profile = AetherSourceProfile(
            sourceKind: .progressive,
            isSeekableVOD: true,
            videoCodec: .h264,
            videoFormat: .sdr
        )
        let preflight = PlaybackPreflight.resolve(
            sourceProfile: profile,
            hlsPackaging: nil,
            hybridCapabilities:
                AetherHybridPlaybackSession.capabilities
        )
        let session = try AetherNativePlaybackSession.make(
            url: URL(fileURLWithPath: "/not-opened.mp4"),
            preflightResult: preflight
        )

        #expect(session.avPlayer.currentItem === session.avPlayerItem)
        session.stop()
        session.stop()
        #expect(session.avPlayer.currentItem == nil)
        #expect(session.state == .stopped)
        #expect(throws: AetherNativePlaybackSessionError.stopped) {
            try session.play()
        }
    }
}
