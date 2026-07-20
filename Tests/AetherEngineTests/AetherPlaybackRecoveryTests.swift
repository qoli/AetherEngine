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

    @Test("Classification preflight and origin share one failure budget")
    func sharedTransportBudget() {
        let budget = PlaybackTransportRetryBudget(
            maximumFailureAttempts: 3
        )
        #expect(!budget.isExhausted)
        #expect(budget.recordRetryableFailure() == 1)
        #expect(budget.recordRetryableFailure() == 2)
        #expect(budget.recordRetryableFailure() == 3)
        #expect(budget.isExhausted)
        #expect(budget.recordRetryableFailure() == 3)
        budget.reset()
        #expect(budget.currentFailureAttempt == 0)
        #expect(!budget.isExhausted)
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

    @Test("Presentation evidence separates media, host, decoder and resource failures")
    func presentationEvidenceMatrix() {
        #expect(
            PlaybackFailureEvidenceDecision.kind(
                for: .invalidPresentationTime
            ) == .malformedMedia
        )
        #expect(
            PlaybackFailureEvidenceDecision.kind(
                for: .frameFormatDiverged(
                    expected: .sdr,
                    actual: .hdr10
                )
            ) == .routeRuntimeFailure
        )
        #expect(
            PlaybackFailureEvidenceDecision.kind(
                for: .displayLayerTimebaseChanged
            ) == .hostContractViolation
        )
        #expect(
            PlaybackFailureEvidenceDecision.kind(
                for: .pixelBufferNotIOSurfaceBacked
            ) == .decoderRuntimeFailure
        )
        #expect(
            PlaybackFailureEvidenceDecision.kind(
                for: .rendererStalled(
                    durationSeconds: 6,
                    queueDepth: 24
                )
            ) == .routeRuntimeFailure
        )
    }

    @Test("Only the unavailable selected video variant admits one lower variant")
    func selectedVariantEvidenceMatrix() {
        #expect(
            PlaybackFailureEvidenceDecision.hlsGraphFailureCode(
                .resourceUnavailable(
                    statusCode: 404,
                    resource: .videoSegment(index: 3)
                )
            ) == "hybrid.origin.selectedVariantUnavailable"
        )
        #expect(
            PlaybackFailureEvidenceDecision.hlsGraphFailureCode(
                .resourceUnavailable(
                    statusCode: 410,
                    resource: .videoInit
                )
            ) == "hybrid.origin.selectedVariantUnavailable"
        )
        #expect(
            PlaybackFailureEvidenceDecision.hlsGraphFailureCode(
                .resourceUnavailable(
                    statusCode: 404,
                    resource: .audioSegment(
                        renditionOrdinal: 0,
                        index: 3
                    )
                )
            ) == "hybrid.hls.graph.resourceUnavailable"
        )
        #expect(
            PlaybackFailureEvidenceDecision.hlsGraphFailureCode(
                .credentialRejected(
                    statusCode: 403,
                    resource: .videoSegment(index: 3)
                )
            ) == "hybrid.hls.graph.credentialRejected"
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

    @Test("A newer Seek supersedes every older operation token")
    func seekSupersession() {
        var operations = PlaybackOperationCoordinator()
        let first = operations.beginSeek()
        #expect(operations.isCurrentSeek(first))
        let second = operations.beginSeek()
        #expect(!operations.isCurrentSeek(first))
        #expect(operations.isCurrentSeek(second))
    }

    @Test("Same-route candidates commit only through the active transaction")
    func routeTransactionIdentity() {
        var transactions = PlaybackRouteTransactionCoordinator()
        let first = transactions.begin()
        let second = transactions.begin()
        #expect(!transactions.isActive(first))
        #expect(transactions.isActive(second))
        transactions.invalidate()
        #expect(!transactions.isActive(second))
    }

    @Test("Seek jumps never count as healthy playback progress")
    func seekProgressEpoch() {
        var progress = PlaybackProgressEpoch()
        progress.begin()
        let initialAnchor = progress.observe(
            seconds: 10,
            eligible: true,
            requiredProgressSeconds: 2
        )
        let initialProgress = progress.observe(
            seconds: 12,
            eligible: true,
            requiredProgressSeconds: 2
        )
        #expect(!initialAnchor)
        #expect(initialProgress)

        progress.begin()
        let ineligibleSeekJump = progress.observe(
            seconds: 120,
            eligible: false,
            requiredProgressSeconds: 2
        )
        let seekLandingAnchor = progress.observe(
            seconds: 120,
            eligible: true,
            requiredProgressSeconds: 2
        )
        let shortPostSeekProgress = progress.observe(
            seconds: 121.9,
            eligible: true,
            requiredProgressSeconds: 2
        )
        let healthyPostSeekProgress = progress.observe(
            seconds: 122,
            eligible: true,
            requiredProgressSeconds: 2
        )
        #expect(!ineligibleSeekJump)
        #expect(!seekLandingAnchor)
        #expect(!shortPostSeekProgress)
        #expect(healthyPostSeekProgress)

        progress.begin()
        let backwardSeekAnchor = progress.observe(
            seconds: 20,
            eligible: true,
            requiredProgressSeconds: 2
        )
        let backwardClockMove = progress.observe(
            seconds: 19,
            eligible: true,
            requiredProgressSeconds: 2
        )
        let recoveredMonotonicProgress = progress.observe(
            seconds: 21,
            eligible: true,
            requiredProgressSeconds: 2
        )
        #expect(!backwardSeekAnchor)
        #expect(!backwardClockMove)
        #expect(recoveredMonotonicProgress)
    }

    @Test("Terminal report preserves distinct first and final evidence")
    func terminalFailureEvidence() {
        let terminal = AetherPlaybackTerminalFailure(
            firstFailure: transient,
            finalFailure: decoder,
            exhaustionReason: "decoder recovery exhausted"
        )
        #expect(terminal.firstFailure == transient)
        #expect(terminal.finalFailure == decoder)
        #expect(
            terminal.exhaustionReason
                == "decoder recovery exhausted"
        )
    }

    @Test("A recovery episode expires at thirty seconds")
    func episodeTimeBudget() {
        let action = PlaybackRecoveryDecision.resolve(
            context: AetherPlaybackRecoveryContext(
                failure: runtime,
                activeRoute: .hybridCarrier,
                positivelyAdmittedAlternateRoute:
                    .nativeAVPlayer,
                transportAttempt: 1,
                sameRouteRebuildCount: 0,
                routeTransitionCount: 0,
                elapsedSeconds: 30
            )
        )
        #expect(action == .terminate)
    }

    @Test("Recovery deadline distinguishes the final live instant from expiry")
    func recoveryDeadlineBoundary() {
        let deadline = PlaybackRecoveryDeadline(
            startedAt: 100,
            durationSeconds: 30
        )
        #expect(!deadline.isExpired(now: 129.9))
        #expect(deadline.remainingSeconds(now: 129.9) > 0)
        #expect(deadline.isExpired(now: 130.1))
        #expect(deadline.remainingSeconds(now: 130.1) == 0)
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

    @Test("Native routes never reinterpret native-codec or impossible route facts as Hybrid")
    func alternateRouteAdmission() {
        let nativeRemuxProfile = AetherSourceProfile(
            sourceKind: .progressive,
            isSeekableVOD: true,
            videoCodec: .h264,
            sourceContainer: .matroska,
            videoFormat: .hdr10
        )
        #expect(
            PlaybackPreflight.resolveRecoveryAlternate(
                sourceProfile: nativeRemuxProfile,
                hlsPackaging: nil,
                excluding: .nativeAVPlayer,
                hybridCapabilities:
                    AetherHybridPlaybackSession.capabilities
            ) == nil
        )

        let genuineHybridProfile = AetherSourceProfile(
            sourceKind: .progressive,
            isSeekableVOD: true,
            videoCodec: .av1,
            sourceContainer: .matroska,
            videoFormat: .sdr
        )
        #expect(
            PlaybackPreflight.resolveRecoveryAlternate(
                sourceProfile: genuineHybridProfile,
                hlsPackaging: nil,
                excluding: .nativeAVPlayer,
                hybridCapabilities:
                    AetherHybridPlaybackSession.capabilities
            ) == nil
        )

        let unverifiedContainer = AetherSourceProfile(
            sourceKind: .progressive,
            isSeekableVOD: true,
            videoCodec: .h264,
            sourceContainer: .unknown,
            videoFormat: .hdr10
        )
        #expect(
            PlaybackPreflight.resolveRecoveryAlternate(
                sourceProfile: unverifiedContainer,
                hlsPackaging: nil,
                excluding: .nativeAVPlayer,
                hybridCapabilities:
                    AetherHybridPlaybackSession.capabilities
            ) == nil
        )

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
        #expect(
            session.capabilities.systemFeaturePolicy
                .pictureInPictureVideo != .available
        )
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
