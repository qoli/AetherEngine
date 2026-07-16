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
            .progressive,
            .custom,
        ])
        #expect(capabilities.supportedVideoFormats == [.sdr])
        #expect(
            AetherHybridPlaybackSession.systemFeaturePolicy
                .availability(for: .pictureInPictureVideo)
                == .unavailable(
                    .metalOverlayUnavailableInPictureInPicture
                )
        )
        #expect(
            AetherHybridPlaybackSession.systemFeaturePolicy
                .availability(for: .airPlayVideo)
                == .unavailable(
                    .metalOverlayUnavailableOnAirPlayReceiver
                )
        )
        #expect(
            AetherHybridPlaybackSession.systemFeaturePolicy
                .availability(for: .externalDisplayVideo)
                == .unavailable(
                    .metalOverlayUnavailableOnExternalDisplay
                )
        )
    }

    @Test("Public capabilities reject HLS hybrid before session creation")
    func hlsHybridAdmissionIsTypedUnsupported() {
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

        #expect(result.route == .unsupported)
        #expect(result.reason == .unsupportedHybridSourceKind)
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
    @Test("Public factory revalidates a previously admitted HLS route")
    func publicFactoryRejectsStaleHLSAdmission() async throws {
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
                hasMetalRenderer: true,
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
            .preflightContractChanged(
                route: .unsupported,
                reason: .unsupportedHybridSourceKind
            )

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
