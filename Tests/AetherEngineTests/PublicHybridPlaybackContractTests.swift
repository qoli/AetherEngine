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

    @Test("Public capabilities admit verified HDR10, HLG and Dolby Vision 8.4 but reject HDR10 Plus")
    func publicColorAdmissionMatchesDeviceEvidence() {
        let packaging = HLSVideoPackaging(
            container: .fragmentedMP4,
            sampleEntry: .hev1,
            manifestCodecs: ["hev1"],
            actualVideoCodec: .hevc,
            codecVerification: .verified,
            contentProtection: .none
        )
        let hdr10 = PlaybackPreflight.resolve(
            sourceProfile: AetherSourceProfile(
                sourceKind: .hls,
                isSeekableVOD: true,
                videoCodec: .hevc,
                videoFormat: .hdr10
            ),
            hlsPackaging: packaging,
            hybridCapabilities:
                AetherPlaybackSession.hybridCapabilities
        )
        #expect(hdr10.route == .hybridCarrier)
        #expect(hdr10.reason == .hybridHEV1SampleEntry)

        let hlg = PlaybackPreflight.resolve(
            sourceProfile: AetherSourceProfile(
                sourceKind: .hls,
                isSeekableVOD: true,
                videoCodec: .hevc,
                videoFormat: .hlg
            ),
            hlsPackaging: packaging,
            hybridCapabilities:
                AetherPlaybackSession.hybridCapabilities
        )
        #expect(hlg.route == .hybridCarrier)
        #expect(hlg.reason == .hybridHEV1SampleEntry)

        let profile84 = AetherDolbyVisionConfiguration(
            versionMajor: 1,
            versionMinor: 0,
            profile: 8,
            level: 3,
            rpuPresent: true,
            enhancementLayerPresent: false,
            baseLayerPresent: true,
            baseLayerSignalCompatibilityID: 4,
            metadataCompression: 0
        )
        let dolbyVision84 = PlaybackPreflight.resolve(
            sourceProfile: AetherSourceProfile(
                sourceKind: .hls,
                isSeekableVOD: true,
                videoCodec: .hevc,
                videoFormat: .dolbyVision,
                dolbyVisionConfiguration: profile84,
                hasVerifiedDolbyVisionProfile84BaseLayer: true
            ),
            hlsPackaging: packaging,
            hybridCapabilities:
                AetherPlaybackSession.hybridCapabilities
        )
        #expect(dolbyVision84.route == .hybridCarrier)
        #expect(dolbyVision84.reason == .hybridHEV1SampleEntry)

        let hdr10Plus = PlaybackPreflight.resolve(
            sourceProfile: AetherSourceProfile(
                sourceKind: .hls,
                isSeekableVOD: true,
                videoCodec: .hevc,
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
            videoCodec: .hevc,
            videoFormat: .sdr
        )
        let packaging = HLSVideoPackaging(
            container: .fragmentedMP4,
            sampleEntry: .hev1,
            manifestCodecs: ["hev1"],
            actualVideoCodec: .hevc,
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
        #expect(result.reason == .hybridHEV1SampleEntry)
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
