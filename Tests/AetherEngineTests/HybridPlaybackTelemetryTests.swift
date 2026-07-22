import CoreMedia
import Foundation
import Testing
@testable import AetherEngine

@Suite("Hybrid playback telemetry")
struct HybridPlaybackTelemetryTests {
    @MainActor
    @Test("Late subscribers receive bounded ordered history and terminal completion")
    func boundedReplayAndFinish() async throws {
        let sessionID = UUID(
            uuidString:
                "11111111-2222-3333-4444-555555555555"
        )!
        let hub = AetherHybridPlaybackTelemetryHub(
            sessionID: sessionID,
            historyLimit: 2
        )

        hub.emit(
            kind: .sessionCreated,
            snapshot: makeSnapshot(state: .idle)
        )
        hub.emit(
            kind: .stateChanged,
            snapshot: makeSnapshot(
                state: .preparing(
                    generation: 0,
                    targetSeconds: 0
                )
            )
        )
        hub.emit(
            kind: .stateChanged,
            snapshot: makeSnapshot(
                state: .ready(generation: 0)
            )
        )

        var iterator = hub.stream().makeAsyncIterator()
        hub.finish()

        let first = try #require(await iterator.next())
        let second = try #require(await iterator.next())
        #expect(await iterator.next() == nil)
        #expect(first.sessionID == sessionID)
        #expect(second.sessionID == sessionID)
        #expect(first.sequence == 2)
        #expect(second.sequence == 3)
        #expect(
            first.snapshot.state == .preparing(
                generation: 0,
                targetSeconds: 0
            )
        )
        #expect(
            second.snapshot.state == .ready(
                generation: 0
            )
        )
    }

    @Test("Carrier completion remains a generation-bound telemetry state")
    func endedStateRemainsGenerationBound() {
        #expect(
            AetherHybridPlaybackTelemetryState(
                .ended(generation: 7)
            ) == .ended(generation: 7)
        )
    }

    @MainActor
    @Test("Renderer metrics diagnostics remain visible at the public telemetry boundary")
    func rendererMetricsDiagnosticsRemainVisible() {
        let renderer = makeSnapshot(state: .ready(generation: 0))
            .renderer

        #expect(renderer.metricsSampleInFlight)
        #expect(renderer.lastMetricsRequestCarrierTimeSeconds == 3.875)
        #expect(renderer.lastMetricsCompletionCarrierTimeSeconds == 6.007)
        #expect(renderer.metricsCompletionCount == 2)
        #expect(renderer.lastMetricsCompletionHadCounters == true)
        #expect(renderer.lastRendererTotalFrameCount == 19)
        #expect(renderer.lastRendererDroppedFrameCount == 0)
        #expect(renderer.lastRendererDisplayedFrameCount == 19)
        #expect(renderer.lastRendererDisplayedFrameDelta == 9)
        #expect(renderer.lastPublishedEvidenceTimeSeconds == 5.958)
    }

    @Test("Arbitrary provider reasons collapse to a privacy-safe failure code")
    func providerFailureSanitization() {
        let sourceError = HybridPlaybackSessionError
            .providerFailed(
                HybridPlaybackFailureEvidence(
                    stage: .provider,
                    caseCode: "runtime",
                    underlyingDomain: "ProviderDomain",
                    underlyingCode: 9
                )
            )
        let state = AetherHybridPlaybackTelemetryState(
            .failed(sourceError)
        )

        #expect(state == .failed(.providerFailed))
        #expect(!String(describing: state).contains("secret"))
        #expect(
            !String(describing: state)
                .contains("signed.example")
        )
    }

    @Test("Privacy-safe HLS invalidation structure remains typed")
    func hlsInvalidationRemainsTyped() {
        let reason = AetherHLSPreflightInvalidationReason
            .credentialRejected(
                statusCode: 403,
                resource: .audioSegment(
                    renditionOrdinal: 2,
                    index: 7
                )
            )
        let state = AetherHybridPlaybackTelemetryState(
            .failed(
                .hlsPreflightGenerationInvalidated(
                    reason
                )
            )
        )

        #expect(
            state == .failed(
                .hlsPreflightGenerationInvalidated(
                    reason
                )
            )
        )
    }

    @Test("Public HLS admission failures remain distinct typed telemetry")
    func publicHLSAdmissionFailuresRemainTyped() {
        #expect(
            AetherHybridPlaybackTelemetryState(
                .failed(.hlsPreflightRequired)
            ) == .failed(.hlsPreflightRequired)
        )
        #expect(
            AetherHybridPlaybackTelemetryState(
                .failed(
                    .hlsPreflightResourceGraphMissing
                )
            ) == .failed(
                .hlsPreflightResourceGraphMissing
            )
        )
    }

    @Test("Dolby Vision source divergence remains a stable failure code")
    func dolbyVisionDivergenceRemainsTyped() {
        #expect(
            AetherHybridPlaybackTelemetryState(
                .failed(
                    .sourceDolbyVisionConfigurationDiverged
                )
            ) == .failed(
                .sourceDolbyVisionConfigurationDiverged
            )
        )
    }

    @Test("Progressive immutable-fact drift remains a stable failure code")
    func progressiveSourceFactDriftFailureCode() {
        #expect(
            AetherHybridPlaybackTelemetryFailure(
                .progressiveSourceFactsDiverged
            ) == .progressiveSourceFactsDiverged
        )
    }

    @Test("Audio-analysis failures publish stable codes without source text")
    func audioAnalysisFailureSanitization() {
        let sourceError = AudioAnalysisError
            .hlsResourceFailure(
                "https://signed.example/audio?token=secret Authorization=secret"
            )
        let failure =
            AetherHybridAudioAnalysisTelemetryFailure(
                sourceError
            )

        #expect(failure == .hlsResourceFailure)
        #expect(
            !String(describing: failure).contains("secret")
        )
        #expect(
            !String(describing: failure)
                .contains("signed.example")
        )
    }

    @MainActor
    @Test("Typed seek payload survives bounded stream delivery")
    func typedSeekPayloadDelivery() async throws {
        let hub = AetherHybridPlaybackTelemetryHub(
            historyLimit: 2
        )
        let point = AetherHybridTimelineTelemetry(
            generation: 3,
            targetSeconds: 42,
            segmentIndex: 10,
            framePresentationTimeSeconds: 41.96
        )
        hub.emit(
            kind: .seekVideoReady,
            payload: .seekVideoReady(point),
            snapshot: makeSnapshot(
                state: .ready(generation: 3)
            )
        )

        var iterator = hub.stream().makeAsyncIterator()
        let event = try #require(await iterator.next())

        #expect(event.kind == .seekVideoReady)
        #expect(event.payload == .seekVideoReady(point))
        hub.finish()
    }

    @MainActor
    private func makeSnapshot(
        state: AetherHybridPlaybackTelemetryState
    ) -> AetherHybridPlaybackTelemetrySnapshot {
        AetherHybridPlaybackTelemetrySnapshot(
            route: .hybridCarrier,
            routeReason: .hybridNonAVPlayerCodec,
            state: state,
            generation: 0,
            videoFormat: .sdr,
            realVideoFrameRate: 23.976,
            timelineDurationSeconds: 10,
            carrierTimeSeconds: 0,
            carrierRate: 0,
            carrierTimeControlStatus: .paused,
            carrierForwardBufferSeconds: nil,
            audioAnalysisPlaybackPressure: .none,
            audioAnalysisTrackIDs: [0, 1],
            selectedAudioAnalysisTrackID: 0,
            activeAudioAnalysisRequestCount: 0,
            readinessPrerollFramesRejected: 0,
            carrierBandwidth: .awaiting(
                audioRenditionCount: 2
            ),
            realVideoBitrate: .awaiting(),
            renderer: AetherHybridPresentationView.Diagnostics(
                generation: 0,
                pendingSampleBuffers: 0,
                staleGenerationDrops: 0,
                backPressureObservations: 0,
                enqueuedSampleBuffers: 0,
                hdr10PlusAttachedSampleBuffers: 0,
                firstHDR10PlusAttachmentTimeSeconds: nil,
                lastEnqueuedTimeSeconds: nil,
                metricsSampleInFlight: true,
                lastMetricsRequestCarrierTimeSeconds: 3.875,
                lastMetricsCompletionCarrierTimeSeconds: 6.007,
                metricsCompletionCount: 2,
                lastMetricsCompletionHadCounters: true,
                lastRendererTotalFrameCount: 19,
                lastRendererDroppedFrameCount: 0,
                lastRendererDisplayedFrameCount: 19,
                lastRendererDisplayedFrameDelta: 9,
                lastPublishedEvidenceTimeSeconds: 5.958,
                lastAcceptedFrameDurationSeconds: nil,
                lastAcceptedGeometry: nil,
                carrierTimebaseBound: true,
                rendererStatus: .unknown,
                styledSubtitleVisible: false,
                visibleBitmapSubtitleCount: 0,
                nativeWebVTTVisible: false,
                visibleNativeWebVTTCueCount: 0
            ),
            systemFeaturePolicy:
                AetherHybridPlaybackSession
                    .systemFeaturePolicy
        )
    }
}
