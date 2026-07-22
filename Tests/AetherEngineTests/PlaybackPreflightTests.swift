import XCTest
@testable import AetherEngine

final class PlaybackPreflightTests: XCTestCase {
    private let fullHybridCapabilities = HybridPlaybackCapabilities(
        hasDirectVideoDecoder: true,
        hasSampleBufferRenderer: true,
        hasAudioBridgeCarrier: true,
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
        hasVideo: Bool = true,
        codec: AetherVideoCodec = .hevc,
        audioCodecs: Set<AetherAudioCodec> = [],
        container: AetherSourceContainer = .unknown,
        scanType: AetherVideoScanType = .unknown,
        format: VideoFormat = .sdr
    ) -> AetherSourceProfile {
        AetherSourceProfile(
            sourceKind: kind,
            isSeekableVOD: seekableVOD,
            hasVideoStream: hasVideo,
            videoCodec: codec,
            audioCodecs: audioCodecs,
            sourceContainer: container,
            videoScanType: scanType,
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

    func testVerifiedHVC1FMP4UsesHybrid() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(),
            hlsPackaging: hls(),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .hybridCarrier)
        XCTAssertEqual(result.reason, .hybridHEVC)
    }

    func testDVH1WithoutVerifiedDolbyVisionFactsIsUnsupported() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(format: .dolbyVision),
            hlsPackaging: hls(sampleEntry: .dvh1),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .unsupported)
        XCTAssertEqual(
            result.reason,
            .unsupportedDolbyVisionConfigurationMissing
        )
    }

    func testHEV1VODUsesHybrid() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(),
            hlsPackaging: hls(sampleEntry: .hev1),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .hybridCarrier)
        XCTAssertEqual(result.reason, .hybridHEV1SampleEntry)
    }

    func testPlainHLGHEV1UsesHybrid() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(format: .hlg),
            hlsPackaging: hls(sampleEntry: .hev1),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .hybridCarrier)
        XCTAssertEqual(result.reason, .hybridHEV1SampleEntry)
    }

    func testHEVCInMPEGTransportUsesHybrid() {
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
        XCTAssertEqual(
            result.reason,
            .unsupportedHybridRequiresSeekableVOD
        )
    }

    func testMissingManifestCodecsWithVerifiedHEVCSegmentUsesHybrid() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(),
            hlsPackaging: hls(verification: .manifestMissingButSegmentVerified),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .hybridCarrier)
        XCTAssertEqual(
            result.reason,
            .hybridHLSManifestMissingCodecs
        )
    }

    func testManifestSegmentMismatchIsTypedUnsupportedForHEVC() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(),
            hlsPackaging: hls(verification: .mismatch),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .unsupported)
        XCTAssertEqual(result.reason, .unsupportedHLSVideoPackaging)
    }

    func testMissingManifestCodecsWithVerifiedH264TSSegmentUsesDirectNative() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(codec: .h264),
            hlsPackaging: hls(
                container: .mpegTransport,
                sampleEntry: .avc1,
                codec: .h264,
                verification: .manifestMissingButSegmentVerified
            ),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .nativeAVPlayer)
        XCTAssertEqual(result.reason, .nativeHLSContractVerified)
    }

    func testInterlacedH264HLSSegmentUsesHybridDeinterlacingPath() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(
                codec: .h264,
                scanType: .interlaced
            ),
            hlsPackaging: hls(
                container: .mpegTransport,
                sampleEntry: .avc1,
                codec: .h264,
                verification: .verified
            ),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .hybridCarrier)
        XCTAssertEqual(result.reason, .hybridInterlacedH264)
    }

    func testManifestMismatchUsesVerifiedH264FMP4SegmentForDirectNative() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(codec: .h264),
            hlsPackaging: hls(
                container: .fragmentedMP4,
                sampleEntry: .avc1,
                codec: .h264,
                verification: .mismatch
            ),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .nativeAVPlayer)
        XCTAssertEqual(result.reason, .nativeHLSContractVerified)
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

    func testProtectedHVC1FMP4IsTypedUnsupported() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(),
            hlsPackaging: hls(
                verification: .protectedManifestVerified,
                protection: .fairPlay
            ),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .unsupported)
        XCTAssertEqual(
            result.reason,
            .unsupportedHLSContentProtection
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

    func testPositiveInterlacedH264ProtectedHLSIsUnsupported() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(
                codec: .h264,
                scanType: .interlaced
            ),
            hlsPackaging: hls(
                container: .mpegTransport,
                sampleEntry: .avc1,
                codec: .h264,
                verification: .protectedManifestVerified,
                protection: .sampleAES
            ),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .unsupported)
        XCTAssertEqual(result.reason, .unsupportedHLSContentProtection)
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

    func testNativeCodecPackagingDoesNotEnterHybridForRendererCapabilities() {
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

    func testValidDolbyVisionHEV1UsesHybrid() {
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

    func testMatroskaHEVCUsesHybrid() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(
                kind: .progressive,
                codec: .hevc,
                container: .matroska
            ),
            hlsPackaging: nil,
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .hybridCarrier)
        XCTAssertEqual(result.reason, .hybridHEVC)
    }

    func testHEVCHybridNeverRecoversBackToNative() {
        let profile = source(
            kind: .progressive,
            codec: .hevc,
            container: .matroska
        )

        XCTAssertNil(
            PlaybackPreflight.resolveRecoveryAlternate(
                sourceProfile: profile,
                hlsPackaging: nil,
                excluding: .hybridCarrier,
                hybridCapabilities: fullHybridCapabilities
            )
        )
        XCTAssertNil(
            PlaybackPreflight.resolveRecoveryAlternate(
                sourceProfile: profile,
                hlsPackaging: nil,
                excluding: .nativeAVPlayer,
                hybridCapabilities: fullHybridCapabilities
            )
        )
    }

    func testMatroskaH264UsesNativeHLSFMP4Remux() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(
                kind: .progressive,
                codec: .h264,
                container: .matroska
            ),
            hlsPackaging: nil,
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .nativeAVPlayer)
        XCTAssertEqual(result.reason, .nativeHLSFMP4Remux)
    }

    func testFlashVideoH264UsesNativeHLSFMP4Remux() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(
                kind: .progressive,
                codec: .h264,
                container: .flashVideo,
                scanType: .progressive
            ),
            hlsPackaging: nil,
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .nativeAVPlayer)
        XCTAssertEqual(result.reason, .nativeHLSFMP4Remux)
    }

    func testFlashVideoHEVCStillUsesHybrid() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(
                kind: .progressive,
                codec: .hevc,
                container: .flashVideo,
                scanType: .progressive
            ),
            hlsPackaging: nil,
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .hybridCarrier)
        XCTAssertEqual(result.reason, .hybridHEVC)
    }

    func testInterlacedProgressiveH264UsesHybridDeinterlacingPath() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(
                kind: .progressive,
                codec: .h264,
                container: .matroska,
                scanType: .interlaced
            ),
            hlsPackaging: nil,
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .hybridCarrier)
        XCTAssertEqual(result.reason, .hybridInterlacedH264)
    }

    func testUnknownProgressiveHEVCContainerStillUsesHybridDecoder() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(
                kind: .progressive,
                codec: .hevc,
                container: .unknown
            ),
            hlsPackaging: nil,
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .hybridCarrier)
        XCTAssertEqual(result.reason, .hybridHEVC)
    }

    func testHEVCHybridRequiresHLSInSourceAdmission() {
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

    func testUnclassifiedURLOnlyAdmitsInconclusiveFacts() {
        let inconclusive = AetherSourceProfile(
            sourceKind: .unclassifiedURL,
            isSeekableVOD: true,
            videoStreamPresence: .unknown,
            videoCodec: .unknown,
            videoFormat: .sdr
        )
        let positiveHEVC = source(
            kind: .unclassifiedURL,
            codec: .hevc
        )
        let positiveInterlacedH264 = source(
            kind: .unclassifiedURL,
            codec: .h264,
            scanType: .interlaced
        )
        let positiveHDRFormat = AetherSourceProfile(
            sourceKind: .unclassifiedURL,
            isSeekableVOD: true,
            videoStreamPresence: .unknown,
            videoCodec: .unknown,
            videoFormat: .hdr10
        )

        XCTAssertEqual(
            PlaybackPreflight.resolve(
                sourceProfile: inconclusive,
                hlsPackaging: nil,
                hybridCapabilities: fullHybridCapabilities
            ).route,
            .nativeAVPlayer
        )
        for forged in [
            positiveHEVC,
            positiveInterlacedH264,
            positiveHDRFormat,
        ] {
            let result = PlaybackPreflight.resolve(
                sourceProfile: forged,
                hlsPackaging: nil,
                hybridCapabilities: fullHybridCapabilities
            )
            XCTAssertEqual(result.route, .unsupported)
            XCTAssertEqual(
                result.reason,
                .unsupportedProvisionalURLFactsResolved
            )
        }
        let packaged = PlaybackPreflight.resolve(
            sourceProfile: inconclusive,
            hlsPackaging: hls(
                container: .mpegTransport,
                sampleEntry: .avc1,
                codec: .h264
            ),
            hybridCapabilities: fullHybridCapabilities
        )
        XCTAssertEqual(packaged.route, .unsupported)
        XCTAssertEqual(
            packaged.reason,
            .unsupportedProvisionalURLFactsResolved
        )
        XCTAssertNotNil(packaged.hlsPackaging)
    }

    func testProbeConfirmedProgressiveAudioOnlyUsesNative() {
        let probe = SourceProbe(
            url: URL(string: "https://example.invalid/audio.aac")!,
            durationSeconds: 7.75,
            videoFormat: .sdr,
            videoCodecID: 0,
            videoCodecName: nil,
            sourceContainer: .other,
            videoWidth: 0,
            videoHeight: 0,
            videoFrameRate: nil,
            isDolbyVision: false,
            audioTracks: [],
            subtitleTracks: [],
            isSourceSeekable: true,
            isLive: false,
            videoStreamPresence: .provenAbsent
        )
        let profile = AetherSourceProfile(
            probe: probe,
            sourceKind: .progressive,
            isSeekableVOD: probe.isFiniteSeekableVOD
        )
        let result = PlaybackPreflight.resolve(
            sourceProfile: profile,
            hlsPackaging: nil,
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(
            probe.videoStreamPresence,
            .provenAbsent
        )
        XCTAssertEqual(
            profile.videoStreamPresence,
            .provenAbsent
        )
        XCTAssertFalse(profile.hasVideoStream)
        XCTAssertEqual(result.route, .nativeAVPlayer)
        XCTAssertEqual(result.reason, .nativeAudioOnly)
    }

    func testProbeConfirmedVorbisAudioOnlyUsesHybridAudioBridge() {
        let probe = SourceProbe(
            url: URL(string: "https://example.invalid/audio.ogg")!,
            durationSeconds: 6,
            videoFormat: .sdr,
            videoCodecID: 0,
            videoCodecName: nil,
            sourceContainer: .other,
            videoWidth: 0,
            videoHeight: 0,
            videoFrameRate: nil,
            isDolbyVision: false,
            audioTracks: [
                TrackInfo(
                    id: 0,
                    name: "Vorbis",
                    codec: "vorbis",
                    language: nil,
                    isDefault: true
                ),
            ],
            subtitleTracks: [],
            isSourceSeekable: true,
            isLive: false,
            videoStreamPresence: .provenAbsent
        )
        let profile = AetherSourceProfile(
            probe: probe,
            sourceKind: .progressive,
            isSeekableVOD: probe.isFiniteSeekableVOD
        )
        let result = PlaybackPreflight.resolve(
            sourceProfile: profile,
            hlsPackaging: nil,
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(profile.audioCodecs, [.vorbis])
        XCTAssertEqual(result.route, .hybridCarrier)
        XCTAssertEqual(result.reason, .hybridAudioBridge)
    }

    func testVorbisAudioOnlyWithoutCarrierCapabilityIsTypedUnsupported() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(
                kind: .progressive,
                hasVideo: false,
                codec: .unknown,
                audioCodecs: [.vorbis],
                container: .other
            ),
            hlsPackaging: nil,
            hybridCapabilities: HybridPlaybackCapabilities(
                hasDirectVideoDecoder: true,
                hasSampleBufferRenderer: true,
                hasAudioBridgeCarrier: false,
                supportedVideoFormats: [.sdr]
            )
        )

        XCTAssertEqual(result.route, .unsupported)
        XCTAssertEqual(
            result.reason,
            .unsupportedHybridAudioBridgeUnavailable
        )
    }

    func testMissingStreamInventoryDoesNotBecomeAudioOnly() {
        let probe = SourceProbe(
            url: URL(string: "https://example.invalid/unknown.bin")!,
            durationSeconds: 1_200,
            videoFormat: .sdr,
            videoCodecID: 0,
            videoCodecName: nil,
            sourceContainer: .other,
            videoWidth: 0,
            videoHeight: 0,
            videoFrameRate: nil,
            isDolbyVision: false,
            audioTracks: [],
            subtitleTracks: [],
            isSourceSeekable: true,
            isLive: false
        )
        let profile = AetherSourceProfile(
            probe: probe,
            sourceKind: .progressive,
            isSeekableVOD: probe.isFiniteSeekableVOD
        )
        let result = PlaybackPreflight.resolve(
            sourceProfile: profile,
            hlsPackaging: nil,
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(probe.videoStreamPresence, .unknown)
        XCTAssertEqual(profile.videoStreamPresence, .unknown)
        XCTAssertFalse(profile.hasVideoStream)
        XCTAssertEqual(result.route, .unsupported)
        XCTAssertEqual(
            result.reason,
            .unsupportedVideoStreamPresenceInconclusive
        )
    }

    func testDemuxConfirmedUnknownVideoCannotBecomeAudioOnly() {
        let probe = SourceProbe(
            url: URL(string: "https://example.invalid/unknown-video.bin")!,
            durationSeconds: 1_200,
            videoFormat: .sdr,
            videoCodecID: 0,
            videoCodecName: nil,
            sourceContainer: .other,
            videoWidth: 0,
            videoHeight: 0,
            videoFrameRate: nil,
            isDolbyVision: false,
            audioTracks: [],
            subtitleTracks: [],
            isSourceSeekable: true,
            isLive: false,
            videoStreamPresence: .provenPresent
        )
        let profile = AetherSourceProfile(
            probe: probe,
            sourceKind: .progressive,
            isSeekableVOD: probe.isFiniteSeekableVOD
        )
        let result = PlaybackPreflight.resolve(
            sourceProfile: profile,
            hlsPackaging: nil,
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertTrue(probe.hasVideoStream)
        XCTAssertTrue(profile.hasVideoStream)
        XCTAssertEqual(result.route, .unsupported)
        XCTAssertEqual(result.reason, .unsupportedVideoCodec)
    }

    func testPositiveHEVCCannotBeMaskedByFalseVideoFlag() {
        let profile = source(
            kind: .progressive,
            hasVideo: false,
            codec: .hevc,
            container: .isoBaseMedia
        )
        let result = PlaybackPreflight.resolve(
            sourceProfile: profile,
            hlsPackaging: nil,
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertTrue(profile.hasVideoStream)
        XCTAssertEqual(result.route, .hybridCarrier)
        XCTAssertEqual(result.reason, .hybridHEVC)
    }
}
