import XCTest
@testable import AetherEngine

final class PlaybackPreflightTests: XCTestCase {
    private let fullHybridCapabilities = HybridPlaybackCapabilities(
        hasDirectVideoDecoder: true,
        hasMetalRenderer: true,
        supportedVideoFormats: [.sdr, .hdr10, .hdr10Plus, .hlg, .dolbyVision]
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

    func testHEV1VODUsesHybridCarrierMetal() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(),
            hlsPackaging: hls(sampleEntry: .hev1),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .hybridCarrierMetal)
        XCTAssertEqual(result.reason, .hybridHEV1SampleEntry)
    }

    func testHEVCInMPEGTransportVODUsesHybridCarrierMetal() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(),
            hlsPackaging: hls(container: .mpegTransport, sampleEntry: .notApplicable),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .hybridCarrierMetal)
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

        XCTAssertEqual(result.route, .hybridCarrierMetal)
        XCTAssertEqual(result.reason, .hybridHLSManifestMissingCodecs)
    }

    func testManifestSegmentMismatchUsesHybridWithoutTryingNative() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(),
            hlsPackaging: hls(verification: .mismatch),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .hybridCarrierMetal)
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

    func testProtectedHLSFailsExplicitly() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(),
            hlsPackaging: hls(protection: .sampleAES),
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .unsupported)
        XCTAssertEqual(result.reason, .unsupportedHLSContentProtection)
    }

    func testHybridRequiresAnExplicitRendererColorContract() {
        let noDolbyVision = HybridPlaybackCapabilities(
            hasDirectVideoDecoder: true,
            hasMetalRenderer: true,
            supportedVideoFormats: [.sdr, .hdr10, .hdr10Plus, .hlg]
        )
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(format: .dolbyVision),
            hlsPackaging: hls(sampleEntry: .hev1),
            hybridCapabilities: noDolbyVision
        )

        XCTAssertEqual(result.route, .unsupported)
        XCTAssertEqual(result.reason, .unsupportedHybridVideoFormat)
    }

    func testNonAVPlayerProgressiveCodecUsesHybridWhenCapabilityExists() {
        let result = PlaybackPreflight.resolve(
            sourceProfile: source(kind: .progressive, codec: .av1),
            hlsPackaging: nil,
            hybridCapabilities: fullHybridCapabilities
        )

        XCTAssertEqual(result.route, .hybridCarrierMetal)
        XCTAssertEqual(result.reason, .hybridNonAVPlayerCodec)
    }

    func testHybridSourceKindMustBePubliclyAdmitted() {
        let progressiveOnly = HybridPlaybackCapabilities(
            hasDirectVideoDecoder: true,
            hasMetalRenderer: true,
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
