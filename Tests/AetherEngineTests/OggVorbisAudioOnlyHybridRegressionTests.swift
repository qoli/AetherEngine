import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AetherEngine

private let oggVorbisFixtureURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("PlayerTestVideos")
    .appendingPathComponent("02-progressive")
    .appendingPathComponent("ogg-vorbis.ogg")

private let oggVorbisFixtureExists = FileManager.default.fileExists(
    atPath: oggVorbisFixtureURL.path
)

@Suite("Ogg/Vorbis audio-only Hybrid regression", .serialized)
struct OggVorbisAudioOnlyHybridRegressionTests {
    @Test("Acceptance catalog pins Ogg/Vorbis to audio-only Hybrid")
    func acceptanceCatalogRoute() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Acceptance")
            .appendingPathComponent("player_test_videos.catalog.json")
        let payload = try #require(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: catalogURL)
            ) as? [String: Any]
        )
        let fixtures = try #require(
            payload["fixtures"] as? [[String: Any]]
        )
        let fixture = try #require(
            fixtures.first {
                $0["case_id"] as? String
                    == "format-progressive-ogg-vorbis"
            }
        )
        let expectedMedia = try #require(
            fixture["expected_media"] as? [String: Any]
        )

        #expect(fixture["expected_route"] as? String == "hybridCarrier")
        #expect((expectedMedia["video_codecs"] as? [String]) == [])
        #expect(
            expectedMedia["audio_codecs"] as? [String]
                == ["vorbis"]
        )
    }

    @Test(
        "Exact Ogg fixture reaches AudioBridge carrier segments and one AVPlayer clock",
        .enabled(
            if: oggVorbisFixtureExists,
            "PlayerTestVideos Ogg/Vorbis fixture is unavailable"
        ),
        .timeLimit(.minutes(1))
    )
    @MainActor
    func exactFixtureBuildsAudioOnlyHybridSession() async throws {
        let sourceData = try Data(
            contentsOf: oggVorbisFixtureURL,
            options: .mappedIfSafe
        )
        #expect(
            BlackCarrierEncodedSample.sha256Hex(sourceData)
                == "5d6d3fbf19d7229ff3afc8b9736bc6052e8a4e8215c8738c561d3de5d7a4e329"
        )

        let demuxer = Demuxer()
        try demuxer.open(url: oggVorbisFixtureURL)
        let probe = AetherEngine.makeSourceProbe(
            demuxer: demuxer,
            displayURL: oggVorbisFixtureURL
        )
        demuxer.close()

        let profile = AetherSourceProfile(
            probe: probe,
            sourceKind: .progressive,
            isSeekableVOD: probe.isFiniteSeekableVOD
        )
        let preflight = PlaybackPreflight.resolve(
            sourceProfile: profile,
            hlsPackaging: nil,
            hybridCapabilities: AetherHybridPlaybackSession.capabilities
        )
        #expect(profile.videoStreamPresence == .provenAbsent)
        #expect(profile.audioCodecs == [.vorbis])
        #expect(preflight.route == .hybridCarrier)
        #expect(preflight.reason == .hybridAudioBridge)

        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: probe.durationSeconds,
                preferredTimescale: BlackCarrierProfile.approved.timescale
            )
        )
        let provider = try BlackCarrierLazyCompositeProvider
            .buildSeekableVOD(
                videoProvider: try BlackCarrierVideoProvider(
                    timeline: timeline
                ),
                source: .url(oggVorbisFixtureURL),
                options: LoadOptions(),
                timeline: timeline,
                decodedFrameHandler: nil
            )
        #expect(provider.hybridVideoFormat == nil)
        #expect(provider.alternateAudioRenditions.count == 1)
        #expect(provider.masterCodecs?.contains("ec-3") == true)
        try provider.prepareForTransportStart()
        #expect(try #require(provider.initSegment()).isEmpty == false)
        #expect(try #require(provider.mediaSegment(at: 0)).isEmpty == false)
        #expect(
            try #require(
                provider.alternateAudioInitSegment(ordinal: 0)
            ).isEmpty == false
        )
        #expect(
            try #require(
                provider.alternateAudioMediaSegment(
                    ordinal: 0,
                    index: 0
                )
            ).isEmpty == false
        )
        provider.close()

        let session = try AetherPlaybackSessionFactory
            .makeSeekableURLVOD(url: oggVorbisFixtureURL)
        let avPlayer = session.avPlayer
        defer { session.stop() }

        try await session.prepare()
        let carrierItem = try #require(avPlayer.currentItem)
        #expect(session.avPlayer === avPlayer)
        #expect(session.state == .ready)
        #expect(session.activeRoute == .hybridCarrier)
        #expect(session.preflightResult?.reason == .hybridAudioBridge)
        #expect(session.videoOutputSnapshot.videoExpected == false)
        #expect(session.videoOutputSnapshot.outputStatus == .notExpected)
        #expect(session.videoOutputSnapshot.canonicalCodec == .none)
        #expect(session.videoOutputSnapshot.activeRoute == .hybridCarrier)
        let waitedSnapshot = await session.waitForVideoFrame(
            after: session.videoOutputSnapshot.frameSequence,
            timeout: 0.25
        )
        #expect(waitedSnapshot.outputStatus == .notExpected)
        #expect(waitedSnapshot.videoExpected == false)
        #expect(waitedSnapshot.canonicalCodec == .none)

        let target = CMTime(
            seconds: 3.6,
            preferredTimescale: 600
        )
        #expect(try await session.seek(to: target) == .applied)
        #expect(session.state == .paused)
        #expect(avPlayer.currentItem === carrierItem)
        #expect(session.videoOutputSnapshot.videoExpected == false)
        #expect(session.videoOutputSnapshot.outputStatus == .notExpected)
        #expect(session.videoOutputSnapshot.canonicalCodec == .none)
    }
}
