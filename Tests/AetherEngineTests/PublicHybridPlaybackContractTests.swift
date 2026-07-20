import AetherEngine
import Foundation
import Testing

@Suite("Public hybrid playback contract")
struct PublicHybridPlaybackContractTests {
    @Test("Current admission is explicit about source, color and system-output limits")
    func currentCapabilitiesAndSystemFeaturePolicy() {
        let capabilities = AetherPlaybackSession.hybridCapabilities

        #expect(capabilities.supportedSourceKinds == [
            .hls,
            .progressive,
            .custom,
        ])
        #expect(capabilities.supportedVideoFormats == [
            .sdr,
            .hdr10,
            .hlg,
            .dolbyVision,
        ])
        #expect(
            capabilities.supportedDolbyVisionProfiles == [.profile84]
        )
        #expect(
            AetherPlaybackSession.hybridSystemFeaturePolicy
                .availability(for: .pictureInPictureVideo)
                == .unavailable(
                    .presentationOverlayUnavailableInPictureInPicture
                )
        )
        #expect(
            AetherPlaybackSession.hybridSystemFeaturePolicy
                .availability(for: .airPlayVideo)
                == .unavailable(
                    .presentationOverlayUnavailableOnAirPlayReceiver
                )
        )
        #expect(
            AetherPlaybackSession.hybridSystemFeaturePolicy
                .availability(for: .externalDisplayVideo)
                == .unavailable(
                    .presentationOverlayUnavailableOnExternalDisplay
                )
        )
    }

    @Test("Public Hybrid color capabilities apply only to genuine non-AVPlayer codecs")
    func publicColorAdmissionMatchesDeviceEvidence() {
        let packaging = HLSVideoPackaging(
            container: .fragmentedMP4,
            sampleEntry: .unknown,
            manifestCodecs: ["vp09.00.10.08"],
            actualVideoCodec: .vp9,
            codecVerification: .verified,
            contentProtection: .none
        )
        let hdr10 = PlaybackPreflight.resolve(
            sourceProfile: AetherSourceProfile(
                sourceKind: .hls,
                isSeekableVOD: true,
                videoCodec: .vp9,
                videoFormat: .hdr10
            ),
            hlsPackaging: packaging,
            hybridCapabilities:
                AetherPlaybackSession.hybridCapabilities
        )
        #expect(hdr10.route == .hybridCarrier)
        #expect(hdr10.reason == .hybridNonAVPlayerCodec)

        let hlg = PlaybackPreflight.resolve(
            sourceProfile: AetherSourceProfile(
                sourceKind: .hls,
                isSeekableVOD: true,
                videoCodec: .vp9,
                videoFormat: .hlg
            ),
            hlsPackaging: packaging,
            hybridCapabilities:
                AetherPlaybackSession.hybridCapabilities
        )
        #expect(hlg.route == .hybridCarrier)
        #expect(hlg.reason == .hybridNonAVPlayerCodec)

        let hdr10Plus = PlaybackPreflight.resolve(
            sourceProfile: AetherSourceProfile(
                sourceKind: .hls,
                isSeekableVOD: true,
                videoCodec: .vp9,
                videoFormat: .hdr10Plus
            ),
            hlsPackaging: packaging,
            hybridCapabilities:
                AetherPlaybackSession.hybridCapabilities
        )
        #expect(hdr10Plus.route == .unsupported)
        #expect(hdr10Plus.reason == .unsupportedHybridVideoFormat)
    }

    @Test("Public capabilities admit graph-bound SDR HLS hybrid")
    func hlsHybridAdmissionIsPublic() {
        let source = AetherSourceProfile(
            sourceKind: .hls,
            isSeekableVOD: true,
            videoCodec: .vp9,
            videoFormat: .sdr
        )
        let packaging = HLSVideoPackaging(
            container: .fragmentedMP4,
            sampleEntry: .unknown,
            manifestCodecs: ["vp09.00.10.08"],
            actualVideoCodec: .vp9,
            codecVerification: .verified,
            contentProtection: .none
        )
        let result = PlaybackPreflight.resolve(
            sourceProfile: source,
            hlsPackaging: packaging,
            hybridCapabilities:
                AetherPlaybackSession.hybridCapabilities
        )

        #expect(result.route == .hybridCarrier)
        #expect(result.reason == .hybridNonAVPlayerCodec)
    }

    @MainActor
    @Test("Public factory returns one unresolved session without opening the source")
    func publicFactoryReturnsUnifiedSession() throws {
        let session = try AetherPlaybackSessionFactory
            .makeSeekableURLVOD(
                url: URL(
                    string: "https://example.invalid/media.m3u8"
                )!
            )

        #expect(session.state == .idle)
        #expect(session.activeRoute == nil)
        #expect(session.currentItem == nil)
        #expect(session.avPlayer.currentItem == nil)
    }

    @MainActor
    @Test("Public URL factory rejects a non-media URL scheme")
    func publicFactoryRejectsNonMediaScheme() {
        #expect(
            throws: AetherPlaybackSessionFactoryError
                .invalidURLSourceKind
        ) {
            try AetherPlaybackSessionFactory.makeSeekableURLVOD(
                url: URL(string: "ftp://example.invalid/media.mp4")!
            )
        }
    }
}
