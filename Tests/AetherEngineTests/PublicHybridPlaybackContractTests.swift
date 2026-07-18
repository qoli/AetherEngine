import AetherEngine
import CoreMedia
import Foundation
import Testing

private final class PublicHybridEmptyReader:
    IOReader,
    @unchecked Sendable
{
    func read(
        _ buffer: UnsafeMutablePointer<UInt8>?,
        size: Int32
    ) -> Int32 {
        0
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        0
    }

    func close() {}

    func makeIndependentReader() -> IOReader? {
        PublicHybridEmptyReader()
    }
}

@Suite("Public hybrid playback contract")
struct PublicHybridPlaybackContractTests {
    @Test("Current admission is explicit about source, color and system-output limits")
    func currentCapabilitiesAndSystemFeaturePolicy() {
        let capabilities = AetherHybridPlaybackSession.capabilities

        #expect(capabilities.supportedSourceKinds == [
            .hls,
            .progressive,
            .custom,
        ])
        #expect(capabilities.supportedVideoFormats == [
            .sdr,
            .hdr10,
            .hlg,
        ])
        #expect(capabilities.supportedDolbyVisionProfiles.isEmpty)
        #expect(
            AetherHybridPlaybackSession.systemFeaturePolicy
                .availability(for: .pictureInPictureVideo)
                == .unavailable(
                    .presentationOverlayUnavailableInPictureInPicture
                )
        )
        #expect(
            AetherHybridPlaybackSession.systemFeaturePolicy
                .availability(for: .airPlayVideo)
                == .unavailable(
                    .presentationOverlayUnavailableOnAirPlayReceiver
                )
        )
        #expect(
            AetherHybridPlaybackSession.systemFeaturePolicy
                .availability(for: .externalDisplayVideo)
                == .unavailable(
                    .presentationOverlayUnavailableOnExternalDisplay
                )
        )
    }

    @Test("Public capabilities admit HDR10 and HLG but reject HDR10 Plus")
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
                AetherHybridPlaybackSession.capabilities
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
                AetherHybridPlaybackSession.capabilities
        )
        #expect(hlg.route == .hybridCarrier)
        #expect(hlg.reason == .hybridHEV1SampleEntry)

        let hdr10Plus = PlaybackPreflight.resolve(
            sourceProfile: AetherSourceProfile(
                sourceKind: .hls,
                isSeekableVOD: true,
                videoCodec: .hevc,
                videoFormat: .hdr10Plus
            ),
            hlsPackaging: packaging,
            hybridCapabilities:
                AetherHybridPlaybackSession.capabilities
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
                AetherHybridPlaybackSession.capabilities
        )

        #expect(result.route == .hybridCarrier)
        #expect(result.reason == .hybridHEV1SampleEntry)
    }

    @MainActor
    @Test("Public factory refuses a non-hybrid preflight without opening the source")
    func publicFactoryRejectsNativeRoute() async throws {
        let sourceProfile = AetherSourceProfile(
            sourceKind: .custom,
            isSeekableVOD: true,
            videoCodec: .h264,
            videoFormat: .sdr
        )
        let preflight = PlaybackPreflight.resolve(
            sourceProfile: sourceProfile,
            hlsPackaging: nil,
            hybridCapabilities:
                AetherHybridPlaybackSession.capabilities
        )
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: 1,
                preferredTimescale: 90_000
            )
        )
        let expected = HybridPlaybackSessionError
            .preflightRequiresHybrid(
                route: .nativeAVPlayer,
                reason: .nativeContainerRepackaging
            )

        await #expect(throws: expected) {
            try await AetherHybridPlaybackSession
                .makeSeekableVOD(
                    source: .custom(
                        PublicHybridEmptyReader(),
                        formatHint: "mp4"
                    ),
                    options: LoadOptions(),
                    timeline: timeline,
                    preflightResult: preflight
                )
        }
    }

    @MainActor
    @Test("Generic seekable factory requires the opaque HLS preflight factory")
    func publicSeekableFactoryRejectsHLSBypass() async throws {
        let sourceProfile = AetherSourceProfile(
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
        let preflight = PlaybackPreflight.resolve(
            sourceProfile: sourceProfile,
            hlsPackaging: packaging,
            hybridCapabilities: HybridPlaybackCapabilities(
                hasDirectVideoDecoder: true,
                hasSampleBufferRenderer: true,
                supportedVideoFormats: [.sdr]
            )
        )
        let timeline = try BlackCarrierTimeline
            .mirroredHLSVOD(segmentDurations: [
                CMTime(
                    seconds: 1,
                    preferredTimescale: 90_000
                ),
            ])
        let expected = HybridPlaybackSessionError
            .hlsPreflightRequired

        await #expect(throws: expected) {
            try await AetherHybridPlaybackSession
                .makeSeekableVOD(
                    source: .url(
                        URL(
                            string:
                                "https://example.invalid/media.m3u8"
                        )!
                    ),
                    options: LoadOptions(),
                    timeline: timeline,
                    preflightResult: preflight
                )
        }
    }
}
