import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AetherEngine

@MainActor
private final class FakeNativePresentedFrameOutput:
    AetherNativePresentedFrameOutput
{
    private weak var item: AVPlayerItem?
    var nextPresentedTime: CMTime?
    private(set) var pollCount = 0

    func bind(to item: AVPlayerItem) {
        self.item = item
    }

    func unbind() {
        item = nil
    }

    func copyPresentedFrameTime(
        for item: AVPlayerItem,
        hostTimeSeconds: TimeInterval
    ) -> CMTime? {
        guard self.item === item else { return nil }
        pollCount += 1
        defer { nextPresentedTime = nil }
        return nextPresentedTime
    }
}

private func makeRouteVideoSnapshot(
    status: AetherVideoOutputStatus,
    sequence: UInt64,
    generation: UInt64,
    route: PlaybackRenderRoute,
    mediaTime: Double? = nil
) -> AetherVideoOutputSnapshot {
    AetherVideoOutputSnapshot(
        videoExpected: true,
        outputStatus: status,
        frameSequence: sequence,
        frameGeneration: generation,
        lastPresentedFrameMediaTimeSeconds: mediaTime,
        observedAtUptimeSeconds: mediaTime.map { 1_000 + $0 },
        activeRoute: route,
        canonicalCodec: route == .nativeAVPlayer
            ? .hevc
            : .vp9
    )
}

private func nativeTrackPreflight(
    sourceKind: AetherMediaSourceKind = .progressive,
    videoStreamPresence: AetherVideoStreamPresence,
    videoCodec: AetherVideoCodec,
    sourceContainer: AetherSourceContainer = .matroska,
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
        hlsPackaging: nil,
        route: .nativeAVPlayer,
        reason: reason
    )
}

@Suite("Video output evidence")
struct VideoOutputEvidenceTests {
    @Test("Source-positive video cannot become audio-only when Native tracks are empty")
    func positiveVideoTrackAbsenceFailsClosed() {
        #expect(
            AetherNativeVideoTrackInspectionResult.resolve(
                sourceHasVideo: true,
                sourceCodec: .hevc,
                observedTrackCodec: nil
            ) == .expectedVideoMissing(.hevc)
        )
        #expect(
            AetherNativeVideoTrackInspectionResult.resolve(
                sourceHasVideo: true,
                sourceCodec: .h264,
                observedTrackCodec: nil
            ) == .expectedVideoMissing(.h264)
        )
        #expect(
            AetherNativeVideoTrackInspectionResult.resolve(
                sourceHasVideo: true,
                sourceCodec: .unknown,
                observedTrackCodec: nil
            ) == .expectedVideoMissing(.unknown)
        )
        #expect(
            AetherNativeVideoTrackInspectionResult.resolve(
                sourceHasVideo: false,
                sourceCodec: .unknown,
                observedTrackCodec: nil
            ) == .observedNoVideo
        )
        #expect(
            AetherNativeVideoTrackInspectionResult.resolve(
                sourceHasVideo: true,
                sourceCodec: .unknown,
                observedTrackCodec: .hevc
            ) == .nativeRouteRejectedHEVC
        )
        #expect(
            AetherNativeVideoTrackInspectionResult.resolve(
                sourceHasVideo: true,
                sourceCodec: .unknown,
                observedTrackCodec: .h264
            ) == .observedVideo(.h264)
        )
        #expect(
            AetherNativeVideoTrackInspectionResult.resolve(
                sourceHasVideo: false,
                sourceCodec: .hevc,
                observedTrackCodec: nil
            ) == .expectedVideoMissing(.hevc)
        )
        #expect(
            AetherNativeVideoTrackInspectionResult.resolve(
                sourceHasVideo: false,
                sourceCodec: .unknown,
                observedTrackCodec: .h264
            ) == .unexpectedVideo(.h264)
        )
        #expect(
            AetherNativeVideoTrackInspectionResult.resolve(
                sourceHasVideo: false,
                sourceCodec: .unknown,
                observedTrackCodec: .unknown
            ) == .unexpectedVideo(.unknown)
        )
    }

    @Test("Provisional Native rejects observed HEVC before ready")
    func provisionalNativeObservedHEVCRequiresHybrid() {
        let provisional = nativeTrackPreflight(
            sourceKind: .unclassifiedURL,
            videoStreamPresence: .unknown,
            videoCodec: .unknown,
            sourceContainer: .unknown,
            reason: .nativeProvisionalURL
        )
        let inspection = AetherNativeVideoTrackInspectionResult
            .resolve(
                sourceHasVideo: true,
                sourceCodec: .unknown,
                observedTrackCodec: .hevc
            )
        #expect(inspection == .nativeRouteRejectedHEVC)
        #expect(
            AetherNativeVideoTrackPreparationPolicy.decide(
                ownership: .directAsset,
                preflightResult: provisional,
                inspection: inspection
            ) == .fail(.observedHEVCRequiresHybrid)
        )
        #expect(
            AetherNativeVideoTrackPreparationPolicy.decide(
                ownership: .directAsset,
                preflightResult: provisional,
                inspection: .observedVideo(.h264)
            ) == .proceed
        )
        #expect(
            AetherNativeVideoTrackPreparationPolicy.decide(
                ownership: .directAsset,
                preflightResult: provisional,
                inspection: .observedNoVideo
            ) == .fail(.videoTrackInspectionInconclusive)
        )
        #expect(
            AetherNativeVideoTrackPreparationPolicy.decide(
                ownership: .directAsset,
                preflightResult: provisional,
                inspection: .unexpectedVideo(.h264)
            ) == .fail(.unexpectedVideoTrack(codec: .h264))
        )
        #expect(
            AetherNativeVideoTrackInspectionResult.resolve(
                sourceHasVideo: false,
                sourceCodec: .unknown,
                observedTrackCodec: .hevc
            ) == .unexpectedVideo(.hevc)
        )
        #expect(
            AetherNativeVideoTrackPreparationPolicy.decide(
                ownership: .directAsset,
                preflightResult: provisional,
                inspection: .unexpectedVideo(.hevc)
            ) == .fail(.observedHEVCRequiresHybrid)
        )
    }

    @MainActor
    @Test("Late Native item HEVC inspection exits through typed Aether boundary")
    func lateNativeItemHEVCInspectionExitsNative() throws {
        let provisional = nativeTrackPreflight(
            sourceKind: .unclassifiedURL,
            videoStreamPresence: .unknown,
            videoCodec: .unknown,
            sourceContainer: .unknown,
            reason: .nativeProvisionalURL
        )
        let session = try AetherNativePlaybackSession.make(
            url: URL(
                string: "https://example.invalid/runtime-item.m3u8"
            )!,
            preflightResult: provisional
        )
        #expect(session.avPlayer.currentItem != nil)

        session.handleRuntimeVideoTrackInspection(
            .nativeRouteRejectedHEVC
        )

        #expect(
            session.state == .failed(.playerItemFailed)
        )
        #expect(session.avPlayer.currentItem == nil)
        let evidence = try #require(
            session.lastFailureEvidence
        )
        #expect(
            evidence.caseCode
                == "observedHEVCRequiresHybrid"
        )
        let failure = AetherPlaybackSession.nativeRuntimeFailure(
            fallback: .playerItemFailed,
            evidence: evidence
        )
        #expect(
            failure.caseCode
                == "native.observedHEVCRequiresHybrid"
        )
        #expect(
            PlaybackRecoveryDecision
                .requiresImmediateNativeExit(
                    failure: failure,
                    activeRoute: .nativeAVPlayer
                )
        )
    }

    @Test("Only exact prepared-source H.264 remux defers empty asset tracks")
    func nativeRemuxEmptyAssetTracksAreAdvisory() {
        let remux = nativeTrackPreflight(
            videoStreamPresence: .provenPresent,
            videoCodec: .h264,
            reason: .nativeHLSFMP4Remux
        )

        #expect(
            AetherNativeVideoTrackPreparationPolicy.decide(
                ownership: .aetherOwnedHLSFMP4Remux,
                preflightResult: remux,
                inspection: .expectedVideoMissing(.h264)
            ) == .proceedWithAdvisory
        )
        #expect(
            AetherNativeVideoTrackPreparationPolicy.decide(
                ownership: .directAsset,
                preflightResult: remux,
                inspection: .expectedVideoMissing(.h264)
            ) == .fail(.expectedVideoTrackMissing(codec: .h264))
        )
    }

    @Test("Remux ownership cannot excuse provisional or non-remux track absence")
    func nativeRemuxEmptyTrackAdvisoryRequiresExactFacts() {
        let provisional = nativeTrackPreflight(
            sourceKind: .unclassifiedURL,
            videoStreamPresence: .unknown,
            videoCodec: .unknown,
            sourceContainer: .unknown,
            reason: .nativeProvisionalURL
        )
        let directHLS = nativeTrackPreflight(
            sourceKind: .hls,
            videoStreamPresence: .provenPresent,
            videoCodec: .h264,
            sourceContainer: .mpegTransport,
            reason: .nativeHLSContractVerified
        )

        #expect(
            AetherNativeVideoTrackPreparationPolicy.decide(
                ownership: .aetherOwnedHLSFMP4Remux,
                preflightResult: provisional,
                inspection: .observedNoVideo
            ) == .fail(.videoTrackInspectionInconclusive)
        )
        #expect(
            AetherNativeVideoTrackPreparationPolicy.decide(
                ownership: .aetherOwnedHLSFMP4Remux,
                preflightResult: directHLS,
                inspection: .expectedVideoMissing(.h264)
            ) == .fail(.expectedVideoTrackMissing(codec: .h264))
        )
        #expect(
            AetherNativeVideoTrackPreparationPolicy.decide(
                ownership: .aetherOwnedHLSFMP4Remux,
                preflightResult: directHLS,
                inspection: .inconclusive
            ) == .fail(.videoTrackInspectionInconclusive)
        )
    }

    @Test("HEVC track facts can never receive the Native remux advisory")
    func nativeRemuxHEVCTracksFailClosed() {
        let invalidNativeHEVC = nativeTrackPreflight(
            videoStreamPresence: .provenPresent,
            videoCodec: .hevc,
            reason: .nativeHLSFMP4Remux
        )

        for inspection in [
            AetherNativeVideoTrackInspectionResult
                .expectedVideoMissing(.hevc),
            .observedVideo(.hevc),
            .nativeRouteRejectedHEVC,
        ] {
            #expect(
                AetherNativeVideoTrackPreparationPolicy.decide(
                    ownership: .aetherOwnedHLSFMP4Remux,
                    preflightResult: invalidNativeHEVC,
                    inspection: inspection
                ) == .fail(.observedHEVCRequiresHybrid)
            )
        }
    }

    @Test("Proven audio-only Native may accept an empty video-track result")
    func nativeAudioOnlyEmptyVideoTracksProceed() {
        let audioOnly = nativeTrackPreflight(
            videoStreamPresence: .provenAbsent,
            videoCodec: .unknown,
            reason: .nativeAudioOnly
        )

        #expect(
            AetherNativeVideoTrackPreparationPolicy.decide(
                ownership: .directAsset,
                preflightResult: audioOnly,
                inspection: .observedNoVideo
            ) == .proceed
        )
    }

    @MainActor
    @Test("HEVC clock progress without a video-output frame stays missing")
    func nativeHEVCClockProgressWithoutFrame() {
        let output = FakeNativePresentedFrameOutput()
        let monitor = AetherNativeVideoOutputMonitor(
            output: output
        )
        let item = AVPlayerItem(
            url: URL(
                string: "https://example.invalid/hevc.mp4"
            )!
        )
        monitor.bind(to: item)
        monitor.observeVideoTrack(codec: .hevc)

        for second in [1.0, 2.0, 3.0, 4.0] {
            let snapshot = monitor.poll(
                playerTime: CMTime(
                    seconds: second,
                    preferredTimescale: 600
                ),
                hostTimeSeconds: second
            )
            #expect(snapshot.videoExpected)
            #expect(snapshot.outputStatus == .missing)
            #expect(snapshot.frameSequence == 0)
            #expect(snapshot.canonicalCodec == .hevc)
        }
        #expect(output.pollCount == 4)

        output.nextPresentedTime = CMTime(
            seconds: 4,
            preferredTimescale: 600
        )
        let presented = monitor.poll(
            playerTime: CMTime(
                seconds: 4,
                preferredTimescale: 600
            ),
            hostTimeSeconds: 4
        )
        #expect(presented.outputStatus == .presented)
        #expect(presented.frameSequence == 1)
        #expect(
            presented.lastPresentedFrameMediaTimeSeconds == 4
        )

        monitor.beginSeekGeneration()
        output.nextPresentedTime = CMTime(
            seconds: 4,
            preferredTimescale: 600
        )
        let afterSeek = monitor.poll(
            playerTime: CMTime(
                seconds: 300,
                preferredTimescale: 600
            ),
            hostTimeSeconds: 5
        )
        #expect(afterSeek.outputStatus == .missing)
        #expect(afterSeek.frameSequence == 1)
        #expect(
            afterSeek.frameGeneration
                == presented.frameGeneration + 1
        )

        output.nextPresentedTime = CMTime(
            seconds: 300,
            preferredTimescale: 600
        )
        let postSeekFrame = monitor.poll(
            playerTime: CMTime(
                seconds: 300,
                preferredTimescale: 600
            ),
            hostTimeSeconds: 6
        )
        #expect(postSeekFrame.outputStatus == .presented)
        #expect(postSeekFrame.frameSequence == 2)
    }

    @MainActor
    @Test("Observed audio-only item is explicit and never polls pixels")
    func nativeAudioOnlyObservation() {
        let output = FakeNativePresentedFrameOutput()
        let monitor = AetherNativeVideoOutputMonitor(
            output: output
        )
        monitor.bind(to: AVPlayerItem(
            url: URL(
                string: "https://example.invalid/audio.m4a"
            )!
        ))
        monitor.observeNoVideoTrack()
        let snapshot = monitor.poll(
            playerTime: CMTime(
                seconds: 12,
                preferredTimescale: 600
            ),
            hostTimeSeconds: 12
        )
        #expect(!snapshot.videoExpected)
        #expect(snapshot.outputStatus == .notExpected)
        #expect(snapshot.canonicalCodec == .none)
        #expect(output.pollCount == 0)
    }

    @MainActor
    @Test("Native frame output is sampled only on explicit evidence demand")
    func nativeOutputIsDemandPolled() {
        let output = FakeNativePresentedFrameOutput()
        let monitor = AetherNativeVideoOutputMonitor(
            output: output
        )
        let item = AVPlayerItem(
            url: URL(
                string: "https://example.invalid/video.mp4"
            )!
        )
        monitor.bind(to: item)
        monitor.observeVideoTrack(codec: .h264)
        output.nextPresentedTime = CMTime(
            seconds: 5,
            preferredTimescale: 600
        )

        #expect(monitor.snapshot.outputStatus == .missing)
        #expect(output.pollCount == 0)

        let demanded = monitor.poll(
            playerTime: CMTime(
                seconds: 5,
                preferredTimescale: 600
            ),
            hostTimeSeconds: 5
        )
        #expect(demanded.outputStatus == .presented)
        #expect(demanded.frameSequence == 1)
        #expect(output.pollCount == 1)
    }

    @MainActor
    @Test("Hybrid enqueue is not evidence; displayed metrics are")
    func hybridDisplayedMetricsEvidence() throws {
        let reducer = AetherHybridDisplayedFrameEvidenceReducer()
        reducer.beginGeneration(7)
        reducer.recordEnqueued(
            presentationTime: CMTime(
                seconds: 10,
                preferredTimescale: 600
            ),
            generation: 7
        )
        reducer.recordEnqueued(
            presentationTime: CMTime(
                seconds: 11,
                preferredTimescale: 600
            ),
            generation: 7
        )

        // The first metrics read establishes a generation-local baseline. It
        // cannot retroactively credit already-enqueued frames.
        #expect(reducer.observeMetrics(
            .init(total: 20, dropped: 2),
            carrierTime: CMTime(
                seconds: 11,
                preferredTimescale: 600
            ),
            now: 100
        ) == nil)
        #expect(reducer.observeMetrics(
            .init(total: 21, dropped: 2),
            carrierTime: CMTime(
                seconds: 11,
                preferredTimescale: 600
            ),
            now: 101
        ) == AetherHybridPresentedFrameEvidence(
            generation: 7,
            mediaTimeSeconds: 11,
            observedAtUptimeSeconds: 101
        ))

        // A new total that is entirely dropped is not displayed evidence.
        #expect(reducer.observeMetrics(
            .init(total: 22, dropped: 3),
            carrierTime: CMTime(
                seconds: 12,
                preferredTimescale: 600
            ),
            now: 102
        ) == nil)
    }

    @MainActor
    @Test("Late batched Hybrid metrics use completion carrier time")
    func lateBatchedHybridMetricsUseCompletionCarrierTime() {
        let reducer = AetherHybridDisplayedFrameEvidenceReducer()
        reducer.beginGeneration(12)
        for seconds in [3.875, 4.0, 4.5, 5.0, 5.958] {
            reducer.recordEnqueued(
                presentationTime: CMTime(
                    seconds: seconds,
                    preferredTimescale: 600
                ),
                generation: 12
            )
        }

        // Establish the generation-local baseline while the carrier is at the
        // time where the async metrics request begins.
        #expect(reducer.observeMetrics(
            .init(total: 10, dropped: 0),
            requestCarrierTime: CMTime(
                seconds: 3.875,
                preferredTimescale: 600
            ),
            completionCarrierTime: CMTime(
                seconds: 3.875,
                preferredTimescale: 600
            ),
            now: 100
        ) == nil)

        // The next async read completes near EOS with a batch of nine newly
        // displayed frames. The evidence must map to the latest PTS visible at
        // completion, not to the stale request-start carrier position.
        #expect(reducer.observeMetrics(
            .init(total: 19, dropped: 0),
            requestCarrierTime: CMTime(
                seconds: 3.875,
                preferredTimescale: 600
            ),
            completionCarrierTime: CMTime(
                seconds: 6.007,
                preferredTimescale: 600
            ),
            now: 101
        ) == AetherHybridPresentedFrameEvidence(
            generation: 12,
            mediaTimeSeconds: CMTime(
                seconds: 5.958,
                preferredTimescale: 600
            ).seconds,
            observedAtUptimeSeconds: 101
        ))
    }

    @MainActor
    @Test("Hybrid displayed pixel buffer evidence is generation-bound")
    func hybridDisplayedPixelEvidence() {
        let reducer = AetherHybridDisplayedFrameEvidenceReducer()
        reducer.beginGeneration(8)
        reducer.recordEnqueued(
            presentationTime: CMTime(
                seconds: 30,
                preferredTimescale: 600
            ),
            generation: 7
        )
        #expect(reducer.observeDisplayedPixelBuffer(
            carrierTime: CMTime(
                seconds: 30,
                preferredTimescale: 600
            ),
            now: 200
        ) == nil)

        reducer.recordEnqueued(
            presentationTime: CMTime(
                seconds: 30,
                preferredTimescale: 600
            ),
            generation: 8
        )
        #expect(reducer.observeDisplayedPixelBuffer(
            carrierTime: CMTime(
                seconds: 30,
                preferredTimescale: 600
            ),
            now: 201
        ) == AetherHybridPresentedFrameEvidence(
            generation: 8,
            mediaTimeSeconds: 30,
            observedAtUptimeSeconds: 201
        ))
        // Re-reading the same paused displayed buffer does not advance the
        // evidence sequence.
        #expect(reducer.observeDisplayedPixelBuffer(
            carrierTime: CMTime(
                seconds: 30,
                preferredTimescale: 600
            ),
            now: 202
        ) == nil)
    }

    @Test("Canonical codec spellings match the acceptance wire")
    func canonicalCodecWireSpellings() {
        #expect(
            AetherVideoCodec.mpeg4Part2
                .canonicalVideoOutputCodec.rawValue == "mpeg4"
        )
        #expect(AetherCanonicalVideoCodec.none.rawValue == "none")
        #expect(AetherCanonicalVideoCodec.hevc.rawValue == "hevc")
    }

    @Test("A stale metrics completion cannot retire the newer sample")
    func staleMetricsCompletionCannotRetireNewSample() throws {
        var gate = AetherHybridMetricsSamplingGate()
        let oldCandidate = gate.beginSample()
        let oldToken = try #require(oldCandidate)
        gate.invalidate()
        let newCandidate = gate.beginSample()
        let newToken = try #require(newCandidate)

        let staleCompleted = gate.complete(oldToken)
        #expect(!staleCompleted)
        #expect(gate.hasActiveSample)
        #expect(gate.activeToken == newToken)
        let currentCompleted = gate.complete(newToken)
        #expect(currentCompleted)
        #expect(!gate.hasActiveSample)
    }

    @Test("Hybrid renderer metrics diagnostics expose progress and counter resets without evidence")
    func hybridRendererMetricsDiagnostics() {
        var diagnostics =
            AetherHybridRendererMetricsDiagnosticsReducer()
        diagnostics.beginGeneration(12)
        diagnostics.recordRequest(
            carrierTime: CMTime(
                seconds: 3.875,
                preferredTimescale: 600
            )
        )
        diagnostics.recordCompletion(
            carrierTime: CMTime(
                seconds: 6.007,
                preferredTimescale: 600
            ),
            counters: .init(total: 19, dropped: 0)
        )

        #expect(diagnostics.lastRequestCarrierTimeSeconds == 3.875)
        #expect(
            abs(
                (diagnostics.lastCompletionCarrierTimeSeconds ?? 0)
                    - 6.007
            ) < 0.001
        )
        #expect(diagnostics.lastTotalFrameCount == 19)
        #expect(diagnostics.completionCount == 1)
        #expect(diagnostics.lastCompletionHadCounters == true)
        #expect(diagnostics.lastDroppedFrameCount == 0)
        #expect(diagnostics.lastDisplayedFrameCount == 19)
        #expect(diagnostics.lastDisplayedFrameDelta == nil)
        #expect(diagnostics.lastPublishedEvidenceTimeSeconds == nil)

        diagnostics.recordCompletion(
            carrierTime: CMTime(
                seconds: 6.1,
                preferredTimescale: 600
            ),
            counters: .init(total: 22, dropped: 2)
        )
        #expect(diagnostics.lastDisplayedFrameCount == 20)
        #expect(diagnostics.lastDisplayedFrameDelta == 1)
        #expect(diagnostics.completionCount == 2)

        diagnostics.recordCompletion(
            carrierTime: CMTime(
                seconds: 6.2,
                preferredTimescale: 600
            ),
            counters: .init(total: 1, dropped: 0)
        )
        #expect(diagnostics.lastDisplayedFrameCount == 1)
        #expect(diagnostics.lastDisplayedFrameDelta == -19)
        #expect(diagnostics.lastPublishedEvidenceTimeSeconds == nil)

        diagnostics.recordCompletion(
            carrierTime: CMTime(
                seconds: 6.3,
                preferredTimescale: 600
            ),
            counters: nil
        )
        #expect(diagnostics.completionCount == 4)
        #expect(diagnostics.lastCompletionHadCounters == false)
        #expect(diagnostics.lastDisplayedFrameDelta == nil)
        #expect(diagnostics.lastDisplayedFrameCount == 1)
    }

    @Test("Hybrid renderer metrics diagnostics are generation-bound and sanitize invalid time")
    func hybridRendererMetricsDiagnosticsGenerationBoundary() {
        var diagnostics =
            AetherHybridRendererMetricsDiagnosticsReducer()
        diagnostics.beginGeneration(4)
        diagnostics.recordRequest(carrierTime: .invalid)
        diagnostics.recordCompletion(
            carrierTime: .invalid,
            counters: .init(total: 5, dropped: 1)
        )
        diagnostics.recordPublishedEvidence(
            .init(
                generation: 3,
                mediaTimeSeconds: 2,
                observedAtUptimeSeconds: 10
            )
        )

        #expect(diagnostics.lastRequestCarrierTimeSeconds == nil)
        #expect(diagnostics.lastCompletionCarrierTimeSeconds == nil)
        #expect(diagnostics.lastPublishedEvidenceTimeSeconds == nil)

        diagnostics.recordPublishedEvidence(
            .init(
                generation: 4,
                mediaTimeSeconds: 3.875,
                observedAtUptimeSeconds: 11
            )
        )
        #expect(diagnostics.lastPublishedEvidenceTimeSeconds == 3.875)

        diagnostics.beginGeneration(5)
        #expect(diagnostics.completionCount == 0)
        #expect(diagnostics.lastCompletionHadCounters == nil)
        #expect(diagnostics.lastTotalFrameCount == nil)
        #expect(diagnostics.lastDisplayedFrameDelta == nil)
        #expect(diagnostics.lastPublishedEvidenceTimeSeconds == nil)
    }

    @Test("Outer frame sequence survives rebuild and rejects stale routes")
    func outerSequenceReducer() throws {
        var reducer = AetherSessionVideoOutputReducer()
        let nativeToken = reducer.beginBinding(
            makeRouteVideoSnapshot(
                status: .missing,
                sequence: 0,
                generation: 1,
                route: .nativeAVPlayer
            )
        )
        let firstNativeCandidate = reducer.apply(
            makeRouteVideoSnapshot(
                status: .presented,
                sequence: 1,
                generation: 1,
                route: .nativeAVPlayer,
                mediaTime: 10
            ),
            bindingToken: nativeToken
        )
        let firstNative = try #require(firstNativeCandidate)
        #expect(firstNative.frameSequence == 1)

        let rebuiltMissingCandidate = reducer.apply(
            makeRouteVideoSnapshot(
                status: .missing,
                sequence: 1,
                generation: 2,
                route: .nativeAVPlayer
            ),
            bindingToken: nativeToken
        )
        let rebuiltMissing = try #require(
            rebuiltMissingCandidate
        )
        #expect(rebuiltMissing.frameSequence == 1)
        #expect(
            rebuiltMissing.frameGeneration
                > firstNative.frameGeneration
        )

        let rebuiltFrameCandidate = reducer.apply(
            makeRouteVideoSnapshot(
                status: .presented,
                sequence: 2,
                generation: 2,
                route: .nativeAVPlayer,
                mediaTime: 20
            ),
            bindingToken: nativeToken
        )
        let rebuiltFrame = try #require(rebuiltFrameCandidate)
        #expect(rebuiltFrame.frameSequence == 2)

        let betweenRoutes = reducer.invalidate()
        #expect(betweenRoutes.frameSequence == 2)
        let hybridToken = reducer.beginBinding(
            makeRouteVideoSnapshot(
                status: .missing,
                sequence: 0,
                generation: 0,
                route: .hybridCarrier
            )
        )
        #expect(reducer.snapshot.frameSequence == 2)
        #expect(reducer.snapshot.activeRoute == .hybridCarrier)

        let staleResult = reducer.apply(
            makeRouteVideoSnapshot(
                status: .presented,
                sequence: 3,
                generation: 2,
                route: .nativeAVPlayer,
                mediaTime: 30
            ),
            bindingToken: nativeToken
        )
        #expect(staleResult == nil)
        #expect(reducer.snapshot.frameSequence == 2)
        #expect(reducer.snapshot.activeRoute == .hybridCarrier)
        #expect(reducer.snapshot.outputStatus == .missing)

        let hybridFrameCandidate = reducer.apply(
            makeRouteVideoSnapshot(
                status: .presented,
                sequence: 1,
                generation: 0,
                route: .hybridCarrier,
                mediaTime: 31
            ),
            bindingToken: hybridToken
        )
        let hybridFrame = try #require(hybridFrameCandidate)
        #expect(hybridFrame.frameSequence == 3)
        let duplicateCandidate = reducer.apply(
            makeRouteVideoSnapshot(
                status: .presented,
                sequence: 1,
                generation: 0,
                route: .hybridCarrier,
                mediaTime: 31
            ),
            bindingToken: hybridToken
        )
        let duplicate = try #require(duplicateCandidate)
        #expect(duplicate.frameSequence == 3)
    }
}
