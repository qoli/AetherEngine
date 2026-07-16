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

    @Test("Arbitrary provider reasons collapse to a privacy-safe failure code")
    func providerFailureSanitization() {
        let sourceError = HybridPlaybackSessionError
            .providerFailed(
                reason:
                    "https://signed.example/video?token=secret Authorization=secret"
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

    @MainActor
    private func makeSnapshot(
        state: AetherHybridPlaybackTelemetryState
    ) -> AetherHybridPlaybackTelemetrySnapshot {
        AetherHybridPlaybackTelemetrySnapshot(
            route: .hybridCarrierMetal,
            routeReason: .hybridNonAVPlayerCodec,
            state: state,
            generation: 0,
            videoFormat: .sdr,
            timelineDurationSeconds: 10,
            carrierTimeSeconds: 0,
            carrierRate: 0,
            carrierTimeControlStatus: .paused,
            carrierForwardBufferSeconds: nil,
            audioAnalysisPlaybackPressure: .none,
            audioAnalysisTrackIDs: [0, 1],
            activeAudioAnalysisRequestCount: 0,
            renderer: AetherMetalPlayerView.Diagnostics(
                generation: 0,
                queuedFrames: 0,
                staleGenerationDrops: 0,
                queuePressureDrops: 0,
                timelineDrops: 0,
                lastPresentedTimeSeconds: nil
            ),
            systemFeaturePolicy:
                AetherHybridPlaybackSession
                    .systemFeaturePolicy
        )
    }
}
