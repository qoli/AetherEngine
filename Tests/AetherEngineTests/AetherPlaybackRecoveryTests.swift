import Foundation
import Testing
@testable import AetherEngine

@Suite("Aether bounded playback recovery")
struct AetherPlaybackRecoveryTests {
    private let transient = AetherPlaybackFailure(
        stage: .preflight,
        kind: .transientTransport,
        domain: "URLError",
        code: -1001,
        reason: "Playback preflight failed (transientTransport)"
    )

    private let runtime = AetherPlaybackFailure(
        stage: .playback,
        kind: .routeRuntimeFailure,
        domain: "AVFoundationErrorDomain",
        code: -11800,
        reason: "Playback route failed"
    )

    private let decoder = AetherPlaybackFailure(
        stage: .decoder,
        kind: .decoderRuntimeFailure,
        domain: "HybridPlaybackSessionError",
        code: 0,
        reason: "Hybrid decoder failed"
    )

    @Test("Transient transport uses exactly three attempts with bounded backoff")
    func transportBudget() {
        let first = PlaybackRecoveryDecision.resolve(
            context: context(failure: transient, transportAttempt: 1)
        )
        let second = PlaybackRecoveryDecision.resolve(
            context: context(failure: transient, transportAttempt: 2)
        )
        let exhausted = PlaybackRecoveryDecision.resolve(
            context: context(failure: transient, transportAttempt: 3)
        )

        #expect(first == .retrySameOperation(afterSeconds: 1))
        #expect(second == .retrySameOperation(afterSeconds: 2))
        #expect(exhausted == .terminate)
    }

    @Test("Retry-After is honored but capped at five seconds")
    func retryAfterCap() {
        let action = PlaybackRecoveryDecision.resolve(
            context: AetherPlaybackRecoveryContext(
                failure: transient,
                activeRoute: nil,
                positivelyAdmittedAlternateRoute: nil,
                transportAttempt: 1,
                retryAfterSeconds: 30,
                sameRouteRebuildCount: 0,
                routeTransitionCount: 0,
                elapsedSeconds: 0
            )
        )
        #expect(action == .retrySameOperation(afterSeconds: 5))
    }

    @Test("Runtime recovery rebuilds once then performs one admitted transition")
    func routeBudget() {
        let rebuild = PlaybackRecoveryDecision.resolve(
            context: context(
                failure: runtime,
                activeRoute: .nativeAVPlayer,
                alternate: .hybridCarrier
            )
        )
        let transition = PlaybackRecoveryDecision.resolve(
            context: context(
                failure: runtime,
                activeRoute: .nativeAVPlayer,
                alternate: .hybridCarrier,
                sameRouteRebuildCount: 1
            )
        )
        let exhausted = PlaybackRecoveryDecision.resolve(
            context: context(
                failure: runtime,
                activeRoute: .hybridCarrier,
                alternate: .nativeAVPlayer,
                sameRouteRebuildCount: 1,
                routeTransitionCount: 1
            )
        )

        #expect(rebuild == .rebuildSameRoute)
        #expect(transition == .transition(to: .hybridCarrier))
        #expect(exhausted == .terminate)
    }

    @Test("Active system presentation prevents a Hybrid transition")
    func activeSystemFeatureBlocksHybrid() {
        let action = PlaybackRecoveryDecision.resolve(
            context: context(
                failure: runtime,
                activeRoute: .nativeAVPlayer,
                alternate: .hybridCarrier,
                sameRouteRebuildCount: 1,
                activity: AetherSystemPlaybackActivity(
                    pictureInPictureVideoIsActive: true
                )
            )
        )
        #expect(action == .terminate)
    }

    @Test("Eligible HEVC gets one software decoder transition after rebuild")
    func softwareDecoderBudget() {
        let transition = PlaybackRecoveryDecision.resolve(
            context: context(
                failure: decoder,
                activeRoute: .hybridCarrier,
                sameRouteRebuildCount: 1,
                softwareDecoderRecoveryEligible: true
            )
        )
        let exhausted = PlaybackRecoveryDecision.resolve(
            context: context(
                failure: decoder,
                activeRoute: .hybridCarrier,
                sameRouteRebuildCount: 1,
                softwareDecoderTransitionCount: 1,
                softwareDecoderRecoveryEligible: true
            )
        )

        #expect(transition == .switchToSoftwareDecoder)
        #expect(exhausted == .terminate)
    }

    @Test("Software recovery permits only HEVC SDR HDR10 and HLG")
    func softwareDecoderFormatBoundary() {
        for format in [VideoFormat.sdr, .hdr10, .hlg] {
            #expect(
                PlaybackRecoveryDecision.permitsSoftwareHEVCRecovery(
                    sourceProfile: AetherSourceProfile(
                        sourceKind: .progressive,
                        isSeekableVOD: true,
                        videoCodec: .hevc,
                        videoFormat: format
                    )
                )
            )
        }
        for format in [VideoFormat.hdr10Plus, .dolbyVision] {
            #expect(
                !PlaybackRecoveryDecision.permitsSoftwareHEVCRecovery(
                    sourceProfile: AetherSourceProfile(
                        sourceKind: .progressive,
                        isSeekableVOD: true,
                        videoCodec: .hevc,
                        videoFormat: format
                    )
                )
            )
        }
        #expect(
            !PlaybackRecoveryDecision.permitsSoftwareHEVCRecovery(
                sourceProfile: AetherSourceProfile(
                    sourceKind: .progressive,
                    isSeekableVOD: true,
                    videoCodec: .h264,
                    videoFormat: .sdr
                )
            )
        )
    }

    @Test("Episode reset retains original failure and terminal is claimed once")
    func coordinatorResetAndTerminalDeduplication() {
        var coordinator = PlaybackRecoveryCoordinator(now: 10)
        coordinator.begin(with: transient, now: 10)
        coordinator.recordAttempt(.retrySameOperation(afterSeconds: 1))
        coordinator.recordAttempt(.rebuildSameRoute)
        let originalEpisode = coordinator.episodeID

        coordinator.resetEpisode(now: 20)

        #expect(coordinator.episodeID != originalEpisode)
        #expect(coordinator.attemptCount == 0)
        #expect(coordinator.sameRouteRebuildCount == 0)
        #expect(coordinator.episodeFirstFailure == nil)
        #expect(coordinator.sessionFirstFailure == transient)
        let firstClaim = coordinator.claimTerminalOutcome()
        let duplicateClaim = coordinator.claimTerminalOutcome()
        #expect(firstClaim)
        #expect(!duplicateClaim)
    }

    @Test("Security and authentication failures are always terminal")
    func permanentFailures() {
        for kind in [
            AetherPlaybackFailureKind.unsupportedCapability,
            AetherPlaybackFailureKind.authenticationRejected,
            .securityBoundary,
            .malformedMedia,
            .hostContractViolation,
            .cancelled,
            .invariantViolation,
        ] {
            let failure = AetherPlaybackFailure(
                stage: .origin,
                kind: kind,
                domain: "test",
                code: 1,
                reason: kind.rawValue
            )
            #expect(
                PlaybackRecoveryDecision.resolve(
                    context: context(failure: failure)
                ) == .terminate
            )
        }
    }

    @Test("Native failure can use Hybrid only with positive same-source evidence")
    func alternateRouteAdmission() {
        let profile = AetherSourceProfile(
            sourceKind: .progressive,
            isSeekableVOD: true,
            videoCodec: .h264,
            videoFormat: .hdr10
        )
        let result = PlaybackPreflight.resolveRecoveryAlternate(
            sourceProfile: profile,
            hlsPackaging: nil,
            excluding: .nativeAVPlayer,
            hybridCapabilities:
                AetherHybridPlaybackSession.capabilities
        )
        #expect(result?.route == .hybridCarrier)
        #expect(result?.reason == .hybridRecoveryAfterNativeFailure)

        let unknown = AetherSourceProfile(
            sourceKind: .unclassifiedURL,
            isSeekableVOD: true,
            videoCodec: .unknown,
            videoFormat: .sdr
        )
        #expect(
            PlaybackPreflight.resolveRecoveryAlternate(
                sourceProfile: unknown,
                hlsPackaging: nil,
                excluding: .nativeAVPlayer,
                hybridCapabilities:
                    AetherHybridPlaybackSession.capabilities
            ) == nil
        )
    }

    @MainActor
    @Test("Factory returns one stable player before route preparation")
    func stableFactoryBoundary() throws {
        let session = try AetherPlaybackSessionFactory
            .makeSeekableURLVOD(
                url: URL(fileURLWithPath: "/not-opened.mp4")
            )
        let player = session.avPlayer
        #expect(session.state == .idle)
        #expect(session.activeRoute == nil)
        #expect(session.avPlayer === player)
        session.stop()
        #expect(session.state == .stopped)
    }

    private func context(
        failure: AetherPlaybackFailure,
        activeRoute: PlaybackRenderRoute? = nil,
        alternate: PlaybackRenderRoute? = nil,
        transportAttempt: Int = 1,
        sameRouteRebuildCount: Int = 0,
        softwareDecoderTransitionCount: Int = 0,
        softwareDecoderRecoveryEligible: Bool = false,
        routeTransitionCount: Int = 0,
        activity: AetherSystemPlaybackActivity = .init()
    ) -> AetherPlaybackRecoveryContext {
        AetherPlaybackRecoveryContext(
            failure: failure,
            activeRoute: activeRoute,
            positivelyAdmittedAlternateRoute: alternate,
            transportAttempt: transportAttempt,
            sameRouteRebuildCount: sameRouteRebuildCount,
            softwareDecoderTransitionCount:
                softwareDecoderTransitionCount,
            softwareDecoderRecoveryEligible:
                softwareDecoderRecoveryEligible,
            routeTransitionCount: routeTransitionCount,
            elapsedSeconds: 0,
            systemActivity: activity
        )
    }
}
