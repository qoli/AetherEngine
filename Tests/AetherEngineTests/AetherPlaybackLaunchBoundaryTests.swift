import AVFoundation
import Foundation
import Testing
@testable import AetherEngine

private func launchNativePreflight(
    sourceKind: AetherMediaSourceKind,
    videoStreamPresence: AetherVideoStreamPresence,
    videoCodec: AetherVideoCodec,
    sourceContainer: AetherSourceContainer = .unknown,
    hlsPackaging: HLSVideoPackaging? = nil,
    reason: PlaybackRouteReason
) -> PlaybackPreflightResult {
    PlaybackPreflightResult(
        sourceProfile: AetherSourceProfile(
            sourceKind: sourceKind,
            isSeekableVOD: sourceKind != .unclassifiedURL,
            videoStreamPresence: videoStreamPresence,
            videoCodec: videoCodec,
            sourceContainer: sourceContainer,
            videoFormat: .sdr
        ),
        hlsPackaging: hlsPackaging,
        route: .nativeAVPlayer,
        reason: reason
    )
}

private let launchDirectProgressive = launchNativePreflight(
    sourceKind: .progressive,
    videoStreamPresence: .provenPresent,
    videoCodec: .h264,
    sourceContainer: .isoBaseMedia,
    reason: .nativeProvisionalURL
)

private let launchNativeRemux = launchNativePreflight(
    sourceKind: .progressive,
    videoStreamPresence: .provenPresent,
    videoCodec: .h264,
    sourceContainer: .matroska,
    reason: .nativeHLSFMP4Remux
)

private let launchVerifiedNativeHLS = launchNativePreflight(
    sourceKind: .hls,
    videoStreamPresence: .provenPresent,
    videoCodec: .h264,
    hlsPackaging: HLSVideoPackaging(
        container: .fragmentedMP4,
        sampleEntry: .avc1,
        manifestCodecs: ["avc1.640028"],
        actualVideoCodec: .h264,
        codecVerification: .verified,
        contentProtection: .none
    ),
    reason: .nativeHLSContractVerified
)

private func launchH264HLS(
    container: HLSVideoContainer,
    verification: HLSManifestCodecVerification,
    protection: HLSContentProtection = .none,
    reason: PlaybackRouteReason = .nativeHLSContractVerified
) -> PlaybackPreflightResult {
    launchNativePreflight(
        sourceKind: .hls,
        videoStreamPresence: .provenPresent,
        videoCodec: .h264,
        hlsPackaging: HLSVideoPackaging(
            container: container,
            sampleEntry: container == .fragmentedMP4
                ? .avc1
                : .notApplicable,
            manifestCodecs: ["avc1.640028"],
            actualVideoCodec: .h264,
            codecVerification: verification,
            contentProtection: protection
        ),
        reason: reason
    )
}

@Suite("Aether playback launch boundary")
struct AetherPlaybackLaunchBoundaryTests {
    @Test("Native readiness keeps a slow item inside its bounded startup window")
    func nativeReadinessAllowsSlowItem() {
        let gate = AetherNativeItemReadinessGate()

        #expect(
            gate.decide(status: .unknown, elapsed: 3)
                == .wait
        )
        #expect(
            gate.decide(status: .unknown, elapsed: 14.999)
                == .wait
        )
        #expect(
            gate.decide(status: .readyToPlay, elapsed: 14.999)
                == .ready
        )
    }

    @Test("Native readiness remains bounded and preserves explicit item failure")
    func nativeReadinessTimesOutOrFails() {
        let gate = AetherNativeItemReadinessGate()

        #expect(
            gate.decide(status: .unknown, elapsed: 15)
                == .timedOut
        )
        #expect(
            gate.decide(status: .failed, elapsed: 0)
                == .failed
        )
    }

    @Test("Direct Native keeps isPlayable as a hard gate")
    func directNativePlayabilityGate() {
        #expect(
            AetherNativeAssetPlayabilityPolicy.decide(
                ownership: .directAsset,
                preflightResult: launchDirectProgressive,
                observation: .reportedPlayable
            ) == .proceed
        )
        #expect(
            AetherNativeAssetPlayabilityPolicy.decide(
                ownership: .directAsset,
                preflightResult: launchDirectProgressive,
                observation: .reportedNotPlayable
            ) == .fail
        )
        #expect(
            AetherNativeAssetPlayabilityPolicy.decide(
                ownership: .directAsset,
                preflightResult: launchDirectProgressive,
                observation: .loadFailed
            ) == .fail
        )
    }

    @Test("Aether-owned Native remux treats isPlayable as advisory")
    func nativeRemuxPlayabilityAdvisory() {
        #expect(
            AetherNativeAssetPlayabilityPolicy.decide(
                ownership: .aetherOwnedHLSFMP4Remux,
                preflightResult: launchNativeRemux,
                observation: .reportedPlayable
            ) == .proceed
        )
        #expect(
            AetherNativeAssetPlayabilityPolicy.decide(
                ownership: .aetherOwnedHLSFMP4Remux,
                preflightResult: launchNativeRemux,
                observation: .reportedNotPlayable
            ) == .proceedWithAdvisory
        )
        #expect(
            AetherNativeAssetPlayabilityPolicy.decide(
                ownership: .aetherOwnedHLSFMP4Remux,
                preflightResult: launchNativeRemux,
                observation: .loadFailed
            ) == .proceedWithAdvisory
        )
    }

    @Test("Verified clear H.264 Native HLS treats early AVAsset metadata as advisory")
    func verifiedNativeHLSAssetMetadataAdvisory() {
        #expect(
            AetherNativeEarlyAssetAdvisoryContract.directOwnership(
                for: launchVerifiedNativeHLS
            ) == .verifiedNativeHLS
        )
        #expect(
            AetherNativeAssetPlayabilityPolicy.decide(
                ownership: .verifiedNativeHLS,
                preflightResult: launchVerifiedNativeHLS,
                observation: .reportedNotPlayable
            ) == .proceedWithAdvisory
        )
        #expect(
            AetherNativeAssetPlayabilityPolicy.decide(
                ownership: .verifiedNativeHLS,
                preflightResult: launchVerifiedNativeHLS,
                observation: .loadFailed
            ) == .proceedWithAdvisory
        )
        #expect(
            AetherNativeVideoTrackPreparationPolicy.decide(
                ownership: .verifiedNativeHLS,
                preflightResult: launchVerifiedNativeHLS,
                inspection: .expectedVideoMissing(.h264)
            ) == .proceedWithAdvisory
        )
    }

    @Test("Verified Native HLS ownership requires clear positive segment packaging")
    func verifiedNativeHLSOwnershipEvidenceBoundary() {
        for result in [
            launchH264HLS(
                container: .fragmentedMP4,
                verification: .verified
            ),
            launchH264HLS(
                container: .mpegTransport,
                verification: .manifestMissingButSegmentVerified
            ),
            launchH264HLS(
                container: .fragmentedMP4,
                verification: .mismatch
            ),
        ] {
            #expect(
                AetherNativeEarlyAssetAdvisoryContract.directOwnership(
                    for: result
                ) == .verifiedNativeHLS
            )
        }

        let protectedManifestOnly = launchH264HLS(
            container: .fragmentedMP4,
            verification: .protectedManifestVerified,
            protection: .fairPlay,
            reason: .nativeProtectedHLSContractVerified
        )
        let uninspected = launchH264HLS(
            container: .fragmentedMP4,
            verification: .segmentNotInspected
        )
        let unknownPackaging = launchH264HLS(
            container: .unknown,
            verification: .verified
        )

        for result in [
            protectedManifestOnly,
            uninspected,
            unknownPackaging,
            launchDirectProgressive,
        ] {
            #expect(
                AetherNativeEarlyAssetAdvisoryContract.directOwnership(
                    for: result
                ) == .directAsset
            )
        }
    }

    @Test("Verified-HLS ownership token is fail-closed for unknown and HEVC facts")
    func verifiedNativeHLSTokenCannotBroadenRoute() {
        let provisional = launchNativePreflight(
            sourceKind: .unclassifiedURL,
            videoStreamPresence: .unknown,
            videoCodec: .unknown,
            reason: .nativeProvisionalURL
        )
        let invalidHEVC = launchNativePreflight(
            sourceKind: .hls,
            videoStreamPresence: .provenPresent,
            videoCodec: .hevc,
            hlsPackaging: HLSVideoPackaging(
                container: .fragmentedMP4,
                sampleEntry: .hvc1,
                manifestCodecs: ["hvc1.2.4.L153.B0"],
                actualVideoCodec: .hevc,
                codecVerification: .verified,
                contentProtection: .none
            ),
            reason: .nativeHLSContractVerified
        )

        for result in [provisional, invalidHEVC] {
            #expect(
                !AetherNativeEarlyAssetAdvisoryContract.permits(
                    ownership: .verifiedNativeHLS,
                    preflightResult: result
                )
            )
            #expect(
                AetherNativeAssetPlayabilityPolicy.decide(
                    ownership: .verifiedNativeHLS,
                    preflightResult: result,
                    observation: .reportedNotPlayable
                ) == .fail
            )
        }
        #expect(
            AetherNativeVideoTrackPreparationPolicy.decide(
                ownership: .verifiedNativeHLS,
                preflightResult: invalidHEVC,
                inspection: .expectedVideoMissing(.hevc)
            ) == .fail(.observedHEVCRequiresHybrid)
        )
    }

    @Test("Native false playable result remains an Aether route failure")
    func nativeReportedNotPlayableEvidence() {
        let evidence = AetherNativePlaybackSession
            .assetReportedNotPlayableEvidence
        let failure = AetherPlaybackSession.nativeFailure(
            stage: .preparation,
            evidence: evidence
        )

        #expect(evidence.category == .routeRuntime)
        #expect(evidence.domain == "AVFoundation")
        #expect(evidence.code == 0)
        #expect(failure.stage == .preparation)
        #expect(failure.kind == .routeRuntimeFailure)
        #expect(
            failure.caseCode
                == "native.assetReportedNotPlayable"
        )
    }

    @Test("Native playable load failure preserves underlying transport evidence")
    func nativePlayableLoadFailureEvidence() {
        let underlying = URLError(.timedOut)
        let evidence = AetherNativePlaybackSession.failureEvidence(
            error: underlying,
            caseCode: "assetPlayableLoadFailed"
        )
        let failure = AetherPlaybackSession.nativeFailure(
            stage: .preparation,
            evidence: evidence
        )

        #expect(evidence.category == .transientTransport)
        #expect(evidence.domain == NSURLErrorDomain)
        #expect(evidence.code == URLError.timedOut.rawValue)
        #expect(failure.stage == .preparation)
        #expect(failure.kind == .transientTransport)
        #expect(failure.domain == NSURLErrorDomain)
        #expect(failure.code == URLError.timedOut.rawValue)
        #expect(
            failure.caseCode
                == "native.assetPlayableLoadFailed"
        )
    }

    @Test("Installed route preparation cannot be reported as preflight")
    func installedRoutePreparationStage() {
        #expect(
            AetherPlaybackSession.initialPreparationFailureStage(
                hasInstalledRoute: false
            ) == .preflight
        )
        #expect(
            AetherPlaybackSession.initialPreparationFailureStage(
                hasInstalledRoute: true
            ) == .preparation
        )
    }

    private func makeWAV(
        sampleRate: Int = 48_000,
        channels: Int = 1,
        seconds: Double = 2
    ) -> Data {
        let frames = Int(Double(sampleRate) * seconds)
        var pcm = Data(capacity: frames * channels * 2)
        for frame in 0 ..< frames {
            let value = Int16(
                9_000 * sin(
                    2 * .pi * 440 * Double(frame)
                        / Double(sampleRate)
                )
            )
            for _ in 0 ..< channels {
                withUnsafeBytes(of: value.littleEndian) {
                    pcm.append(contentsOf: $0)
                }
            }
        }
        var data = Data()
        func append(_ value: String) {
            data.append(value.data(using: .ascii)!)
        }
        func append(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        func append(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        append("RIFF")
        append(UInt32(36 + pcm.count))
        append("WAVE")
        append("fmt ")
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(channels))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * channels * 2))
        append(UInt16(channels * 2))
        append(UInt16(16))
        append("data")
        append(UInt32(pcm.count))
        data.append(pcm)
        return data
    }

    private func nativePreflight() -> PlaybackPreflightResult {
        PlaybackPreflight.resolve(
            sourceProfile: AetherSourceProfile(
                sourceKind: .unclassifiedURL,
                isSeekableVOD: true,
                videoStreamPresence: .unknown,
                videoCodec: .unknown,
                videoFormat: .sdr
            ),
            hlsPackaging: nil,
            hybridCapabilities:
                AetherHybridPlaybackSession.capabilities
        )
    }

    private func temporaryWAV() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("source.wav")
        try makeWAV().write(to: url)
        return url
    }

    private func blackCarrierSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
            .appendingPathComponent("AetherEngine")
            .appendingPathComponent("Resources")
            .appendingPathComponent("black-carrier-idr.mp4")
    }

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

    @Test("ISO-BMFF HEVC requires a progressive probe before Hybrid admission")
    func isoBaseMediaHEVCDoesNotTakeProvisionalNativeShortcut() throws {
        let prefix = Data([
            0x00, 0x00, 0x00, 0x18,
            0x66, 0x74, 0x79, 0x70,
            0x69, 0x73, 0x6F, 0x6D,
        ])

        let signature = try AetherURLPlaybackSourceClassifier
            .inspect(prefix: prefix)
        #expect(signature == .isoBaseMedia)
        #expect(
            signature.canonicalResolutionStep == .probeProgressive
        )
        #expect(
            try AetherURLPlaybackSourceClassifier.classify(prefix: prefix)
                == .progressive
        )
        let preflight = PlaybackPreflight.resolve(
            sourceProfile: AetherSourceProfile(
                sourceKind: .progressive,
                isSeekableVOD: true,
                videoCodec: .hevc,
                sourceContainer: .isoBaseMedia,
                videoFormat: .sdr
            ),
            hlsPackaging: nil,
            hybridCapabilities:
                AetherHybridPlaybackSession.capabilities
        )
        #expect(preflight.route == .hybridCarrier)
        #expect(preflight.reason == .hybridHEVC)
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

    @Test("HTML and complete JSON resolver payloads fail before progressive demux")
    func nonMediaPayloadClassification() throws {
        #expect(throws:
            AetherURLPlaybackSourceClassificationError
                .nonMediaPayload(.html)
        ) {
            try AetherURLPlaybackSourceClassifier.classify(
                prefix: Data(
                    " \n<!DOCTYPE html><html><script>var media = 'x'</script></html>"
                        .utf8
                )
            )
        }
        #expect(throws:
            AetherURLPlaybackSourceClassificationError
                .nonMediaPayload(.json)
        ) {
            try AetherURLPlaybackSourceClassifier.classify(
                prefix: Data("{\"url\":\"redacted\"}".utf8)
            )
        }

        // An incomplete text-like prefix remains probeable; classification
        // does not guess from a leading bracket alone.
        #expect(
            try AetherURLPlaybackSourceClassifier.classify(
                prefix: Data("[Script Info]".utf8)
            ) == .progressive
        )
    }

    @Test("Demux failure preserves FFmpeg code and only typed evidence changes ownership")
    func demuxFailureClassification() {
        let malformed = DemuxerError.openFailed(
            code: FFmpegErr.invalidData
        )
        #expect(malformed.ffmpegCode == FFmpegErr.invalidData)
        #expect(
            AetherPlaybackSession.classify(malformed)
                == .malformedMedia
        )
        #expect(
            AetherPlaybackSession.failureCaseCode(malformed)
                == "demux.openFailed"
        )

        let transport = DemuxerError.openFailed(code: -5)
        #expect(transport.ffmpegCode == -5)
        #expect(
            AetherPlaybackSession.classify(transport)
                == .transientTransport
        )

        let ambiguous = DemuxerError.streamInfoFailed(code: -1)
        #expect(ambiguous.ffmpegCode == -1)
        #expect(
            AetherPlaybackSession.classify(ambiguous)
                == .routeRuntimeFailure
        )
        #expect(
            AetherPlaybackSession.failureCaseCode(ambiguous)
                == "demux.streamInfoFailed"
        )
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
    @Test("A progressive remux admission cannot use the direct AVURLAsset factory")
    func remuxAdmissionRejectsDirectNativeFactory() throws {
        let preflight = PlaybackPreflight.resolve(
            sourceProfile: AetherSourceProfile(
                sourceKind: .progressive,
                isSeekableVOD: true,
                videoCodec: .h264,
                sourceContainer: .matroska,
                videoFormat: .sdr
            ),
            hlsPackaging: nil,
            hybridCapabilities:
                AetherHybridPlaybackSession.capabilities
        )

        #expect(
            throws: AetherNativePlaybackSessionError
                .nativeRemuxRequiresPreparedSource
        ) {
            try AetherNativePlaybackSession.make(
                url: URL(fileURLWithPath: "/not-opened.mkv"),
                preflightResult: preflight
            )
        }
    }

    @Test("Prepared progressive facts are bound to the canonical request")
    func preparedSourceRejectsRequestSubstitution() throws {
        let prepared = try AetherEngine.prepareURLSource(
            url: blackCarrierSourceURL()
        )
        defer { prepared.discard() }
        let substitutedURL = blackCarrierSourceURL()
            .deletingLastPathComponent()
            .appendingPathComponent("different.mp4")

        #expect(
            throws: AetherPreparedURLSourceError.identityMismatch
        ) {
            _ = try prepared.consume(
                url: substitutedURL,
                options: .init()
            )
        }
    }

    @Test("Hybrid source factory consumes the exact progressive preflight demuxer once")
    func hybridFactoryConsumesPreparedSource() throws {
        let url = blackCarrierSourceURL()
        let prepared = try AetherEngine.prepareURLSource(url: url)
        #expect(
            prepared.probe.videoStreamPresence
                == .provenPresent
        )
        let expectedContainer = prepared.probe.sourceContainer
        let factory = try BlackCarrierDemuxSourceFactory.adopting(
            preparedURLSource: prepared,
            url: url,
            options: .init()
        )
        defer { factory.close() }
        let demuxer = try factory.openDemuxer()
        defer { demuxer.close() }

        #expect(demuxer.hasAnyVideoStreamByType)
        #expect(demuxer.sourceContainer == expectedContainer)
        #expect(throws: AetherPreparedURLSourceError.alreadyConsumed) {
            _ = try prepared.consume(url: url, options: .init())
        }
    }

    @Test("A consumed Hybrid owner is replaced by a fresh recovery owner")
    func freshRecoveryOwnerCanBuildAfterInitialConsumption() throws {
        let url = blackCarrierSourceURL()
        let initial = try AetherEngine.prepareURLSource(url: url)
        let initialFactory = try BlackCarrierDemuxSourceFactory.adopting(
            preparedURLSource: initial,
            url: url,
            options: .init()
        )
        let initialDemuxer = try initialFactory.openDemuxer()
        initialDemuxer.close()
        initialFactory.close()
        #expect(throws: AetherPreparedURLSourceError.alreadyConsumed) {
            _ = try initial.consume(url: url, options: .init())
        }

        let recovery = try AetherEngine.prepareURLSource(url: url)
        let recoveryFactory = try BlackCarrierDemuxSourceFactory.adopting(
            preparedURLSource: recovery,
            url: url,
            options: .init()
        )
        defer { recoveryFactory.close() }
        let recoveryDemuxer = try recoveryFactory.openDemuxer()
        defer { recoveryDemuxer.close() }
        #expect(
            recoveryDemuxer.sourceContainer
                == initial.probe.sourceContainer
        )
    }

    @MainActor
    @Test("A native session exclusively owns and tears down its player item")
    func nativeSessionOwnership() throws {
        let session = try AetherNativePlaybackSession.make(
            url: URL(fileURLWithPath: "/not-opened.mp4"),
            preflightResult: nativePreflight()
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

    @MainActor
    @Test("Native route implementation retains the unified player identity")
    func nativeRouteUsesInjectedPlayer() throws {
        let stablePlayer = AVPlayer()
        let session = try AetherNativePlaybackSession.make(
            url: URL(fileURLWithPath: "/not-opened.mp4"),
            preflightResult: nativePreflight(),
            audioAnalysisBinding: .unavailable(
                sourceURL: URL(
                    fileURLWithPath: "/not-opened.mp4"
                ),
                httpHeaders: [:],
                error: .analysisFailed("not prepared")
            ),
            avPlayer: stablePlayer
        )

        #expect(session.avPlayer === stablePlayer)
        #expect(stablePlayer.currentItem === session.avPlayerItem)
        session.stop()
        #expect(stablePlayer.currentItem == nil)
    }

    @MainActor
    @Test("A late native session stop preserves a successor player item")
    func nativeRouteStopPreservesSuccessorItem() throws {
        let stablePlayer = AVPlayer()
        let session = try AetherNativePlaybackSession.make(
            url: URL(fileURLWithPath: "/not-opened.mp4"),
            preflightResult: nativePreflight(),
            audioAnalysisBinding: .unavailable(
                sourceURL: URL(
                    fileURLWithPath: "/not-opened.mp4"
                ),
                httpHeaders: [:],
                error: .analysisFailed("not prepared")
            ),
            avPlayer: stablePlayer
        )
        let successor = AVPlayerItem(asset: AVMutableComposition())
        stablePlayer.replaceCurrentItem(with: successor)

        session.stop()

        #expect(stablePlayer.currentItem === successor)
        stablePlayer.replaceCurrentItem(with: nil)
    }

    @Test("ISO-BMFF H264 is probed before Native remux admission")
    func progressiveNativeUsesContainerAppropriateExecution() async throws {
        let originURL = blackCarrierSourceURL()
        let signature = try await AetherURLPlaybackSourceClassifier
            .inspect(url: originURL)
        #expect(signature == .isoBaseMedia)
        #expect(
            signature.canonicalResolutionStep == .probeProgressive
        )
        let prepared = try AetherEngine.prepareURLSource(
            url: originURL
        )
        defer { prepared.discard() }
        let probe = prepared.probe
        let result = PlaybackPreflight.resolve(
            sourceProfile: AetherSourceProfile(
                probe: probe,
                sourceKind: .progressive,
                isSeekableVOD: probe.isFiniteSeekableVOD
            ),
            hlsPackaging: nil,
            hybridCapabilities:
                AetherHybridPlaybackSession.capabilities
        )

        #expect(result.route == .nativeAVPlayer)
        #expect(
            result.reason == .nativeHLSFMP4Remux
        )
        #expect(
            result.sourceProfile
                .sourceContainer == .isoBaseMedia
        )
    }

    @Test("Finite forward-only HEVC is not admitted as seekable Hybrid VOD")
    func forwardOnlyHEVCFailsSeekableVODAdmission() {
        let probe = SourceProbe(
            url: URL(string: "https://example.com/video.mp4")!,
            durationSeconds: 1_800,
            videoFormat: .sdr,
            videoCodecID: 0,
            videoCodecName: "hevc",
            sourceContainer: .isoBaseMedia,
            videoWidth: 1_920,
            videoHeight: 1_080,
            videoFrameRate: 24,
            isDolbyVision: false,
            audioTracks: [],
            subtitleTracks: [],
            isSourceSeekable: false,
            isLive: false
        )
        #expect(!probe.isFiniteSeekableVOD)

        let result = PlaybackPreflight.resolve(
            sourceProfile: AetherSourceProfile(
                probe: probe,
                sourceKind: .progressive,
                isSeekableVOD: probe.isFiniteSeekableVOD
            ),
            hlsPackaging: nil,
            hybridCapabilities:
                AetherHybridPlaybackSession.capabilities
        )
        #expect(result.route == .unsupported)
        #expect(
            result.reason
                == .unsupportedHybridRequiresSeekableVOD
        )
    }

    @Test("Hybrid commit rejects HEVC to H264 progressive source-fact drift")
    func progressiveHEVCCodecDriftFailsContract() {
        func probe(codec: String) -> SourceProbe {
            SourceProbe(
                url: URL(
                    string: "https://example.com/video.mp4"
                )!,
                durationSeconds: 1_800,
                videoFormat: .sdr,
                videoCodecID: 0,
                videoCodecName: codec,
                sourceContainer: .isoBaseMedia,
                videoWidth: 1_920,
                videoHeight: 1_080,
                videoFrameRate: 24,
                isDolbyVision: false,
                audioTracks: [],
                subtitleTracks: [],
                isSourceSeekable: true,
                isLive: false
            )
        }

        let admittedProbe = probe(codec: "hevc")
        let admittedProfile = AetherSourceProfile(
            probe: admittedProbe,
            sourceKind: .progressive,
            isSeekableVOD: admittedProbe.isFiniteSeekableVOD
        )
        #expect(
            AetherProgressiveSourceFacts(probe: admittedProbe)
                .matches(
                    preflightProfile: admittedProfile,
                    timelineDurationSeconds: 1_800
                )
        )
        #expect(
            !AetherProgressiveSourceFacts(probe: probe(codec: "h264"))
                .matches(
                    preflightProfile: admittedProfile,
                    timelineDurationSeconds: 1_800
                )
        )
    }

    @Test("Hybrid commit rejects progressive scan-type drift")
    func progressiveScanTypeDriftFailsContract() {
        func probe(scanType: AetherVideoScanType) -> SourceProbe {
            SourceProbe(
                url: URL(
                    string: "https://example.com/interlaced.mkv"
                )!,
                durationSeconds: 1_800,
                videoFormat: .sdr,
                videoCodecID: 0,
                videoCodecName: "h264",
                sourceContainer: .matroska,
                videoWidth: 1_920,
                videoHeight: 1_080,
                videoFrameRate: 25,
                videoScanType: scanType,
                isDolbyVision: false,
                audioTracks: [],
                subtitleTracks: [],
                isSourceSeekable: true,
                isLive: false
            )
        }

        let admittedProbe = probe(scanType: .interlaced)
        let admittedProfile = AetherSourceProfile(
            probe: admittedProbe,
            sourceKind: .progressive,
            isSeekableVOD: true
        )
        #expect(
            AetherProgressiveSourceFacts(probe: admittedProbe)
                .matches(
                    preflightProfile: admittedProfile,
                    timelineDurationSeconds: 1_800
                )
        )
        #expect(
            !AetherProgressiveSourceFacts(
                probe: probe(scanType: .progressive)
            ).matches(
                preflightProfile: admittedProfile,
                timelineDurationSeconds: 1_800
            )
        )
    }

    @MainActor
    @Test("Exact Hybrid generation rejects a forged HEVC preflight over H264 bytes")
    func exactHybridGenerationRejectsCodecDrift() async throws {
        let url = blackCarrierSourceURL()
        let prepared = try AetherEngine.prepareURLSource(url: url)
        defer { prepared.discard() }
        let probe = prepared.probe
        let forgedHEVC = PlaybackPreflight.resolve(
            sourceProfile: AetherSourceProfile(
                sourceKind: .progressive,
                isSeekableVOD: probe.isFiniteSeekableVOD,
                videoCodec: .hevc,
                sourceContainer: probe.sourceContainer,
                videoFormat: probe.videoFormat,
                dolbyVisionConfiguration:
                    probe.dolbyVisionConfiguration,
                hasVerifiedDolbyVisionProfile84BaseLayer:
                    probe
                        .hasVerifiedDolbyVisionProfile84BaseLayer
            ),
            hlsPackaging: nil,
            hybridCapabilities:
                AetherHybridPlaybackSession.capabilities
        )
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: probe.durationSeconds,
                preferredTimescale: 90_000
            )
        )

        await #expect(
            throws: HybridPlaybackSessionError
                .progressiveSourceFactsDiverged
        ) {
            _ = try await AetherHybridPlaybackSession
                .makeSeekableVOD(
                    source: .url(url),
                    preparedURLSource: prepared,
                    options: .init(),
                    timeline: timeline,
                    preflightResult: forgedHEVC,
                    avPlayer: AVPlayer()
                )
        }
    }

    @Test("Outer ended seek restores rate or remains truthfully paused")
    func outerEndedSeekTransportIntent() {
        #expect(
            AetherPlaybackSession.stateAfterAppliedSeek(
                desiredPlaying: true,
                desiredRate: 1.5,
                carrierRate: 1.5,
                carrierTimeControlStatus: .playing
            ) == .playing
        )
        #expect(
            AetherPlaybackSession.stateAfterAppliedSeek(
                desiredPlaying: false,
                desiredRate: 1.5,
                carrierRate: 0,
                carrierTimeControlStatus: .paused
            ) == .paused
        )
    }

    @MainActor
    @Test("Native session supplies independent source-time PCM without moving AVPlayer")
    func nativeIndependentAudioAnalysis() async throws {
        let url = try temporaryWAV()
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent()
            )
        }
        let probe = try AetherEngine.probe(url: url)
        let binding = AetherNativeAudioAnalysisBinding.progressive(
            sourceURL: url,
            httpHeaders: [:],
            probe: probe
        )
        let session = try AetherNativePlaybackSession.make(
            url: url,
            preflightResult: nativePreflight(),
            audioAnalysisBinding: binding
        )
        guard let trackID = binding.publicTrackIDs.first else {
            Issue.record("WAV probe did not expose an audio track")
            return
        }
        session.handleMediaSelectionChange(
            selectedAudioOptionIndex: 0
        )
        #expect(session.selectedAudioAnalysisTrackID == trackID)
        #expect(
            session.audioAnalysisAvailability(for: trackID)
                == .available
        )

        let request = try AudioAnalysisRequest(
            audioTrackID: trackID,
            range: 0 ..< 0.5
        )
        let stream = try session.audioAnalysisStream(
            request: request
        )
        var iterator = stream.makeAsyncIterator()
        var bufferCount = 0
        var previousEnd: Int64?
        while let buffer = try await iterator.next() {
            #expect(buffer.pcm.format.sampleRate == 48_000)
            #expect(buffer.pcm.format.channelCount == 1)
            #expect(!buffer.isDiscontinuous)
            if let previousEnd {
                #expect(
                    buffer.sourceSamplePosition == previousEnd
                )
            }
            previousEnd = buffer.sourceSamplePosition
                + Int64(buffer.pcm.frameLength)
            bufferCount += 1
        }
        #expect(bufferCount > 0)
        #expect(session.avPlayer.currentTime() == .zero)
        for _ in 0 ..< 100
        where session.activeAudioAnalysisRequestCount != 0 {
            await Task.yield()
        }
        #expect(session.activeAudioAnalysisRequestCount == 0)
        session.stop()
    }

    @MainActor
    @Test("Native Seek restores user intent instead of transient AVPlayer rate")
    func nativeSeekUsesSessionIntent() async throws {
        let url = try temporaryWAV()
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent()
            )
        }
        let probe = try AetherEngine.probe(url: url)
        #expect(
            probe.videoStreamPresence == .provenAbsent
        )
        let audioOnlyPreflight = PlaybackPreflight.resolve(
            sourceProfile: AetherSourceProfile(
                probe: probe,
                sourceKind: .progressive,
                isSeekableVOD: probe.isFiniteSeekableVOD
            ),
            hlsPackaging: nil,
            hybridCapabilities:
                AetherHybridPlaybackSession.capabilities
        )
        #expect(audioOnlyPreflight.reason == .nativeAudioOnly)
        let session = try AetherNativePlaybackSession.make(
            url: url,
            preflightResult: audioOnlyPreflight
        )
        try await session.prepare()
        try session.play()

        // AVPlayer reports rate zero while buffering and while a Seek lands;
        // that transport fact must not overwrite the user's play intent.
        session.avPlayer.pause()
        await Task.yield()
        let playingSeek = try await session.seek(
            to: CMTime(
                seconds: 0.5,
                preferredTimescale: 600
            )
        )
        #expect(playingSeek == .applied)
        #expect(session.state == .playing)
        #expect(session.avPlayer.rate > 0)

        try session.pause()
        let pausedSeek = try await session.seek(
            to: CMTime(
                seconds: 1,
                preferredTimescale: 600
            )
        )
        #expect(pausedSeek == .applied)
        #expect(session.state == .paused)
        #expect(session.avPlayer.rate == 0)
        session.stop()
    }

    @MainActor
    @Test("Native audio selection cancels the old cursor before publishing replacement identity")
    func nativeSelectionCancelsOldAnalysisCursor() async throws {
        let url = try temporaryWAV()
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent()
            )
        }
        let probe = try AetherEngine.probe(url: url)
        guard let sourceTrack = probe.audioTracks.first else {
            Issue.record("WAV probe did not expose an audio track")
            return
        }
        let binding = AetherNativeAudioAnalysisBinding(
            sourceURL: url,
            httpHeaders: [:],
            durationSeconds: probe.durationSeconds,
            tracks: [
                .init(
                    publicTrackID: 11,
                    sourceTrack: sourceTrack,
                    availability: .available
                ),
                .init(
                    publicTrackID: 22,
                    sourceTrack: sourceTrack,
                    availability: .available
                ),
            ],
            optionTrackIDs: [11, 22],
            allTracksUnavailable: nil
        )
        let session = try AetherNativePlaybackSession.make(
            url: url,
            preflightResult: nativePreflight(),
            audioAnalysisBinding: binding
        )
        session.handleMediaSelectionChange(
            selectedAudioOptionIndex: 0
        )
        let stream = try session.audioAnalysisStream(
            request: try AudioAnalysisRequest(
                audioTrackID: 11,
                range: 0 ..< 1
            )
        )

        session.handleMediaSelectionChange(
            selectedAudioOptionIndex: 1
        )
        #expect(session.selectedAudioAnalysisTrackID == 22)
        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("cancelled old cursor produced a buffer")
        } catch let error as AudioAnalysisError {
            #expect(error == .cancelled)
        }
        session.stop()
    }

    @Test("Native HLS binding rejects a rendition language mismatch")
    func nativeHLSBindingRejectsTrackContractMismatch() {
        let source = AetherSourceProfile(
            sourceKind: .hls,
            isSeekableVOD: true,
            videoCodec: .h264,
            videoFormat: .sdr
        )
        let packaging = HLSVideoPackaging(
            container: .fragmentedMP4,
            sampleEntry: .avc1,
            manifestCodecs: ["avc1.640028"],
            actualVideoCodec: .h264,
            codecVerification: .verified,
            contentProtection: .none
        )
        let result = PlaybackPreflight.resolve(
            sourceProfile: source,
            hlsPackaging: packaging,
            hybridCapabilities:
                AetherHybridPlaybackSession.capabilities
        )
        let policy = AetherHLSAudioRenditionAnalysisPolicy(
            audioTrackID: 0,
            name: "English",
            language: "en",
            isDefault: true,
            availability: .requiresPlaybackSessionBinding
        )
        let preflight = AetherHLSPlaybackPreflight(
            result: result,
            resourceGraph: nil,
            httpHeaders: [:],
            audioAnalysisPolicy:
                .selectedAlternateAudioRenditions([policy])
        )
        let url = URL(string: "https://example.com/master.m3u8")!
        let probe = SourceProbe(
            url: url,
            durationSeconds: 60,
            videoFormat: .sdr,
            videoCodecID: 0,
            videoCodecName: "h264",
            videoWidth: 1920,
            videoHeight: 1080,
            videoFrameRate: 24,
            isDolbyVision: false,
            audioTracks: [
                TrackInfo(
                    id: 4,
                    name: "Spanish",
                    codec: "aac",
                    language: "es",
                    isDefault: true
                )
            ],
            subtitleTracks: []
        )
        let binding = AetherNativeAudioAnalysisBinding.hls(
            sourceURL: url,
            httpHeaders: [:],
            preflight: preflight,
            probe: probe
        )

        #expect(
            binding.availability(for: 0)
                == .unavailable(
                    .sourceTrackContractChanged(audioTrackID: 0)
                )
        )
        #expect(binding.optionTrackIDs == [0])
    }
}
