import XCTest
@testable import AetherEngine

final class PlaybackPreflightTests: XCTestCase {
    private let fullHybridCapabilities = HybridPlaybackCapabilities(
        hasDirectVideoDecoder: true,
        hasSampleBufferRenderer: true,
        supportedVideoFormats: [.sdr, .hdr10, .hdr10Plus, .hlg, .dolbyVision],
        supportedDolbyVisionProfiles: [.profile84]
    )

    private let profile84 = AetherDolbyVisionConfiguration(
        versionMajor: 1,
        versionMinor: 0,
        profile: 8,
        level: 1,
        rpuPresent: true,
        enhancementLayerPresent: false,
        baseLayerPresent: true,
        baseLayerSignalCompatibilityID: 4,
        metadataCompression: 0
    )

    private func source(
        kind: AetherMediaSourceKind = .hls,
        seekableVOD: Bool = true,
        codec: AetherVideoCodec = .hevc,
        format: VideoFormat = .sdr
    ) -> AetherSourceProfile {
        AetherSourceProfile(
            sourceKind: kind,
            isSeekableVOD: seekableVOD,
            videoCodec: codec,
            videoFormat: format
        )
    }

    private func hls(
        container: HLSVideoContainer = .fragmentedMP4,
        sampleEntry: HLSVideoSampleEntry = .hvc1,
        codec: AetherVideoCodec = .hevc,
        verification: HLSManifestCodecVerification = .verified,
        protection: HLSContentProtection = .none
    ) -> HLSVideoPackaging {
        HLSVideoPackaging(
            container: container,
            sampleEntry: sampleEntry,
            manifestCodecs: [sampleEntry.rawValue],
            actualVideoCodec: codec,
            codecVerification: verification,
            contentProtection: protection
        )
    }

    func testVerifiedHVC1FMP4UsesNativeAVPlayer() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(),
            hlsPackaging: hls(),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .nativeAVPlayer)
        XCTAssertEqual(result.reason, .nativeHLSContractVerified)
    }

    func testVerifiedDVH1FMP4UsesNativeAVPlayer() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(format: .dolbyVision),
            hlsPackaging: hls(sampleEntry: .dvh1),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .nativeAVPlayer)
        XCTAssertEqual(result.reason, .nativeHLSContractVerified)
    }

    func testHEV1VODUsesHybridCarrier() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(),
            hlsPackaging: hls(sampleEntry: .hev1),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .hybridCarrier)
        XCTAssertEqual(result.reason, .hybridHEV1SampleEntry)
    }

    func testPlainHLGWithoutDolbyVisionConfigurationUsesHybridCarrier() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(format: .hlg),
            hlsPackaging: hls(sampleEntry: .hev1),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .hybridCarrier)
        XCTAssertEqual(result.reason, .hybridHEV1SampleEntry)
    }

    func testHEVCInMPEGTransportVODUsesHybridCarrier() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(),
            hlsPackaging: hls(container: .mpegTransport, sampleEntry: .notApplicable),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .hybridCarrier)
        XCTAssertEqual(result.reason, .hybridHEVCInMPEGTransport)
    }

    func testHEVCInMPEGTransportLiveFailsInsteadOfUsingAnotherRoute() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(seekableVOD: false),
            hlsPackaging: hls(container: .mpegTransport, sampleEntry: .notApplicable),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .unsupported)
        XCTAssertEqual(result.reason, .unsupportedHybridRequiresSeekableVOD)
    }

    func testMissingManifestCodecsWithVerifiedSegmentUsesHybrid() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(),
            hlsPackaging: hls(verification: .manifestMissingButSegmentVerified),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .hybridCarrier)
        XCTAssertEqual(result.reason, .hybridHLSManifestMissingCodecs)
    }

    func testManifestSegmentMismatchUsesHybridWithoutTryingNative() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(),
            hlsPackaging: hls(verification: .mismatch),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .hybridCarrier)
        XCTAssertEqual(result.reason, .hybridHLSManifestSegmentMismatch)
    }

    func testSegmentNotInspectedFailsExplicitly() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(),
            hlsPackaging: hls(verification: .segmentNotInspected),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .unsupported)
        XCTAssertEqual(result.reason, .unsupportedHLSSegmentNotInspected)
    }

    func testProtectedHVC1FMP4StaysOnNativeAVPlayer() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(),
            hlsPackaging: hls(
                verification: .protectedManifestVerified,
                protection: .fairPlay
            ),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .nativeAVPlayer)
        XCTAssertEqual(
            result.reason,
            .nativeProtectedHLSContractVerified
        )
    }

    func testProtectedH264StaysOnNativeAVPlayer() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(codec: .h264),
            hlsPackaging: hls(
                container: .mpegTransport,
                sampleEntry: .avc1,
                codec: .h264,
                verification: .protectedManifestVerified,
                protection: .sampleAES
            ),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .nativeAVPlayer)
        XCTAssertEqual(
            result.reason,
            .nativeProtectedHLSContractVerified
        )
    }

    func testAES128H264StaysOnNativeAVPlayer() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(codec: .h264),
            hlsPackaging: hls(
                container: .mpegTransport,
                sampleEntry: .avc1,
                codec: .h264,
                verification: .protectedManifestVerified,
                protection: .aes128
            ),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .nativeAVPlayer)
        XCTAssertEqual(
            result.reason,
            .nativeProtectedHLSContractVerified
        )
    }

    func testProtectedHEV1FailsInsteadOfEnteringHybrid() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(),
            hlsPackaging: hls(
                sampleEntry: .hev1,
                verification: .protectedManifestVerified,
                protection: .sampleAES
            ),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .unsupported)
        XCTAssertEqual(result.reason, .unsupportedHLSContentProtection)
    }

    func testUnknownContentProtectionFailsEvenForNativePackaging() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(),
            hlsPackaging: hls(protection: .unknown),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .unsupported)
        XCTAssertEqual(result.reason, .unsupportedHLSContentProtection)
    }

    func testClearManifestOnlyPackagingCannotClaimNative() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(),
            hlsPackaging: hls(
                verification: .protectedManifestVerified
            ),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .unsupported)
        XCTAssertEqual(result.reason, .unsupportedHLSSegmentNotInspected)
    }

    func testHybridRequiresAnExplicitRendererColorContract() {
        let noDolbyVision = HybridPlaybackCapabilities(
            hasDirectVideoDecoder: true,
            hasSampleBufferRenderer: true,
            supportedVideoFormats: [.sdr, .hdr10, .hdr10Plus, .hlg],
            supportedDolbyVisionProfiles: [.profile84]
        )
        let result = PlaybackPreflight.resolve(
            sourceProfile: AetherSourceProfile(
                sourceKind: .hls,
                isSeekableVOD: true,
                videoCodec: .hevc,
                videoFormat: .dolbyVision,
                dolbyVisionConfiguration: profile84,
                hasVerifiedDolbyVisionProfile84BaseLayer: true
            ),
            hlsPackaging: hls(sampleEntry: .hev1),
            hybridCapabilities: noDolbyVision
        )

        XCTAssertEqual(result.route, .unsupported)
        XCTAssertEqual(result.reason, .unsupportedHybridVideoFormat)
    }

    func testHybridDolbyVisionRequiresExactConfiguration() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(format: .dolbyVision),
            hlsPackaging: hls(sampleEntry: .hev1),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .unsupported)
        XCTAssertEqual(
            result.reason,
            .unsupportedDolbyVisionConfigurationMissing
        )
    }

    func testHybridDolbyVisionRejectsUnverifiedProfile() {
        let profile81 = AetherDolbyVisionConfiguration(
            versionMajor: 1,
            versionMinor: 0,
            profile: 8,
            level: 1,
            rpuPresent: true,
            enhancementLayerPresent: false,
            baseLayerPresent: true,
            baseLayerSignalCompatibilityID: 1,
            metadataCompression: 0
        )
        let result = PlaybackPreflight.resolve(
            sourceProfile: AetherSourceProfile(
                sourceKind: .hls,
                isSeekableVOD: true,
                videoCodec: .hevc,
                videoFormat: .dolbyVision,
                dolbyVisionConfiguration: profile81
            ),
            hlsPackaging: hls(sampleEntry: .hev1),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .unsupported)
        XCTAssertEqual(result.reason, .unsupportedDolbyVisionProfile)
    }

    func testHybridDolbyVisionRejectsContradictoryProfile84Flags() {
        let missingRPU = AetherDolbyVisionConfiguration(
            versionMajor: 1,
            versionMinor: 0,
            profile: 8,
            level: 1,
            rpuPresent: false,
            enhancementLayerPresent: false,
            baseLayerPresent: true,
            baseLayerSignalCompatibilityID: 4,
            metadataCompression: 0
        )
        let result = PlaybackPreflight.resolve(
            sourceProfile: AetherSourceProfile(
                sourceKind: .hls,
                isSeekableVOD: true,
                videoCodec: .hevc,
                videoFormat: .dolbyVision,
                dolbyVisionConfiguration: missingRPU,
                hasVerifiedDolbyVisionProfile84BaseLayer: true
            ),
            hlsPackaging: hls(sampleEntry: .hev1),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .unsupported)
        XCTAssertEqual(
            result.reason,
            .unsupportedDolbyVisionConfigurationMismatch
        )
    }

    func testHybridDolbyVisionProfile84CanBeAdmittedExplicitly() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: AetherSourceProfile(
                sourceKind: .hls,
                isSeekableVOD: true,
                videoCodec: .hevc,
                videoFormat: .dolbyVision,
                dolbyVisionConfiguration: profile84,
                hasVerifiedDolbyVisionProfile84BaseLayer: true
            ),
            hlsPackaging: hls(sampleEntry: .hev1),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .hybridCarrier)
        XCTAssertEqual(result.reason, .hybridHEV1SampleEntry)
    }

    func testHybridDolbyVisionRejectsContradictoryBaseLayerBeforeSession() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: AetherSourceProfile(
                sourceKind: .hls,
                isSeekableVOD: true,
                videoCodec: .hevc,
                videoFormat: .dolbyVision,
                dolbyVisionConfiguration: profile84,
                hasVerifiedDolbyVisionProfile84BaseLayer: false
            ),
            hlsPackaging: hls(sampleEntry: .hev1),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .unsupported)
        XCTAssertEqual(
            result.reason,
            .unsupportedDolbyVisionConfigurationMismatch
        )
    }

    func testNonAVPlayerProgressiveCodecUsesHybridWhenCapabilityExists() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(kind: .progressive, codec: .av1),
            hlsPackaging: nil,
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .hybridCarrier)
        XCTAssertEqual(result.reason, .hybridNonAVPlayerCodec)
    }

    func testHybridSourceKindMustBePubliclyAdmitted() {
        let progressiveOnly = HybridPlaybackCapabilities(
            hasDirectVideoDecoder: true,
            hasSampleBufferRenderer: true,
            supportedVideoFormats: [.sdr],
            supportedSourceKinds: [.progressive, .custom]
        )
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(),
            hlsPackaging: hls(sampleEntry: .hev1),
            hybridCapabilities: progressiveOnly
        )

        XCTAssertEqual(result.route, .unsupported)
        XCTAssertEqual(result.reason, .unsupportedHybridSourceKind)
    }

    func testUnknownCodecFailsInsteadOfAssumingNative() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(codec: .unknown),
            hlsPackaging: hls(codec: .unknown),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .unsupported)
        XCTAssertEqual(result.reason, .unsupportedVideoCodec)
    }
}
