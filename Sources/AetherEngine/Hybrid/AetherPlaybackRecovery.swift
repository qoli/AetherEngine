import Foundation

public enum AetherPlaybackRecoveryStage:
    String,
    Sendable,
    Equatable
{
    case classification
    case preflight
    case routeCreation
    case preparation
    case playback
    case decoder
    case presentation
    case origin
}

public enum AetherPlaybackFailureKind:
    String,
    Sendable,
    Equatable
{
    case transientTransport
    case inconclusiveEvidence
    case routeRuntimeFailure
    case decoderRuntimeFailure
    case unsupportedCapability
    case authenticationRejected
    case securityBoundary
    case malformedMedia
    case hostContractViolation
    case cancelled
    case invariantViolation
}

/// Privacy-safe failure retained by the unified playback session.
///
/// URL values, HTTP fields, cookies and arbitrary server response bodies are
/// deliberately absent. `domain` and `code` retain the machine-readable
/// origin of the first error without copying its potentially sensitive text.
public struct AetherPlaybackFailure:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    public let stage: AetherPlaybackRecoveryStage
    public let kind: AetherPlaybackFailureKind
    public let domain: String
    public let code: Int
    public let reason: String

    public init(
        stage: AetherPlaybackRecoveryStage,
        kind: AetherPlaybackFailureKind,
        domain: String,
        code: Int,
        reason: String
    ) {
        self.stage = stage
        self.kind = kind
        self.domain = domain
        self.code = code
        self.reason = reason
    }

    public var errorDescription: String? { reason }
}

public struct AetherPlaybackRecoveryBudget:
    Sendable,
    Equatable
{
    public let maximumTransportAttempts: Int
    public let maximumSameRouteRebuilds: Int
    public let maximumSoftwareDecoderTransitions: Int
    public let maximumRouteTransitions: Int
    public let maximumEpisodeDurationSeconds: TimeInterval
    public let healthyProgressResetSeconds: TimeInterval

    public init(
        maximumTransportAttempts: Int = 3,
        maximumSameRouteRebuilds: Int = 1,
        maximumSoftwareDecoderTransitions: Int = 1,
        maximumRouteTransitions: Int = 1,
        maximumEpisodeDurationSeconds: TimeInterval = 30,
        healthyProgressResetSeconds: TimeInterval = 2
    ) {
        precondition(maximumTransportAttempts > 0)
        precondition(maximumSameRouteRebuilds >= 0)
        precondition(maximumSoftwareDecoderTransitions >= 0)
        precondition(maximumRouteTransitions >= 0)
        precondition(maximumEpisodeDurationSeconds > 0)
        precondition(healthyProgressResetSeconds > 0)
        self.maximumTransportAttempts = maximumTransportAttempts
        self.maximumSameRouteRebuilds = maximumSameRouteRebuilds
        self.maximumSoftwareDecoderTransitions =
            maximumSoftwareDecoderTransitions
        self.maximumRouteTransitions = maximumRouteTransitions
        self.maximumEpisodeDurationSeconds = maximumEpisodeDurationSeconds
        self.healthyProgressResetSeconds = healthyProgressResetSeconds
    }

    public static let production = AetherPlaybackRecoveryBudget()
}

public struct AetherSystemPlaybackActivity:
    Sendable,
    Equatable
{
    public var pictureInPictureVideoIsActive: Bool
    public var airPlayVideoIsActive: Bool
    public var externalDisplayVideoIsActive: Bool

    public init(
        pictureInPictureVideoIsActive: Bool = false,
        airPlayVideoIsActive: Bool = false,
        externalDisplayVideoIsActive: Bool = false
    ) {
        self.pictureInPictureVideoIsActive =
            pictureInPictureVideoIsActive
        self.airPlayVideoIsActive = airPlayVideoIsActive
        self.externalDisplayVideoIsActive =
            externalDisplayVideoIsActive
    }

    var blocksHybridTransition: Bool {
        pictureInPictureVideoIsActive
            || airPlayVideoIsActive
            || externalDisplayVideoIsActive
    }
}

public struct AetherPlaybackRecoveryContext:
    Sendable,
    Equatable
{
    public let failure: AetherPlaybackFailure
    public let activeRoute: PlaybackRenderRoute?
    public let positivelyAdmittedAlternateRoute:
        PlaybackRenderRoute?
    public let transportAttempt: Int
    public let retryAfterSeconds: TimeInterval?
    public let sameRouteRebuildCount: Int
    public let softwareDecoderTransitionCount: Int
    public let softwareDecoderRecoveryEligible: Bool
    public let routeTransitionCount: Int
    public let elapsedSeconds: TimeInterval
    public let systemActivity: AetherSystemPlaybackActivity

    public init(
        failure: AetherPlaybackFailure,
        activeRoute: PlaybackRenderRoute?,
        positivelyAdmittedAlternateRoute:
            PlaybackRenderRoute?,
        transportAttempt: Int,
        retryAfterSeconds: TimeInterval? = nil,
        sameRouteRebuildCount: Int,
        softwareDecoderTransitionCount: Int = 0,
        softwareDecoderRecoveryEligible: Bool = false,
        routeTransitionCount: Int,
        elapsedSeconds: TimeInterval,
        systemActivity: AetherSystemPlaybackActivity = .init()
    ) {
        self.failure = failure
        self.activeRoute = activeRoute
        self.positivelyAdmittedAlternateRoute =
            positivelyAdmittedAlternateRoute
        self.transportAttempt = transportAttempt
        self.retryAfterSeconds = retryAfterSeconds
        self.sameRouteRebuildCount = sameRouteRebuildCount
        self.softwareDecoderTransitionCount =
            softwareDecoderTransitionCount
        self.softwareDecoderRecoveryEligible =
            softwareDecoderRecoveryEligible
        self.routeTransitionCount = routeTransitionCount
        self.elapsedSeconds = elapsedSeconds
        self.systemActivity = systemActivity
    }
}

public enum AetherPlaybackRecoveryAction:
    Sendable,
    Equatable
{
    case retrySameOperation(afterSeconds: TimeInterval)
    case rebuildSameRoute
    case switchToSoftwareDecoder
    case transition(to: PlaybackRenderRoute)
    case terminate
}

/// Pure bounded-recovery policy. It never discovers or substitutes a source;
/// the caller must provide an alternate route that fresh evidence has already
/// admitted for the same canonical request.
public enum PlaybackRecoveryDecision {
    public static func permitsSoftwareHEVCRecovery(
        sourceProfile: AetherSourceProfile
    ) -> Bool {
        guard sourceProfile.videoCodec == .hevc,
              sourceProfile.dolbyVisionConfiguration == nil else {
            return false
        }
        return switch sourceProfile.videoFormat {
        case .sdr, .hdr10, .hlg: true
        case .hdr10Plus, .dolbyVision: false
        }
    }

    public static func resolve(
        context: AetherPlaybackRecoveryContext,
        budget: AetherPlaybackRecoveryBudget = .production
    ) -> AetherPlaybackRecoveryAction {
        guard context.failure.kind != .cancelled,
              context.elapsedSeconds
                < budget.maximumEpisodeDurationSeconds else {
            return .terminate
        }

        switch context.failure.kind {
        case .transientTransport, .inconclusiveEvidence:
            guard context.transportAttempt
                    < budget.maximumTransportAttempts else {
                return .terminate
            }
            let delay = context.retryAfterSeconds.map {
                min(5, max(0, $0))
            } ?? (context.transportAttempt <= 1 ? 1.0 : 2.0)
            return .retrySameOperation(afterSeconds: delay)

        case .routeRuntimeFailure, .decoderRuntimeFailure:
            if context.sameRouteRebuildCount
                    < budget.maximumSameRouteRebuilds {
                return .rebuildSameRoute
            }
            if context.failure.kind == .decoderRuntimeFailure,
               context.softwareDecoderRecoveryEligible,
               context.softwareDecoderTransitionCount
                    < budget.maximumSoftwareDecoderTransitions {
                return .switchToSoftwareDecoder
            }
            guard context.routeTransitionCount
                    < budget.maximumRouteTransitions,
                  let route = context
                    .positivelyAdmittedAlternateRoute,
                  route != .unsupported,
                  route != context.activeRoute else {
                return .terminate
            }
            if route == .hybridCarrier,
               context.systemActivity.blocksHybridTransition {
                return .terminate
            }
            return .transition(to: route)

        case .unsupportedCapability,
             .authenticationRejected,
             .securityBoundary,
             .malformedMedia,
             .hostContractViolation,
             .cancelled,
             .invariantViolation:
            return .terminate
        }
    }
}

/// Mutable episode accounting separated from route construction. The host
/// session supplies the monotonic clock so reset and terminal de-duplication
/// remain deterministic in tests.
public struct PlaybackRecoveryCoordinator: Sendable, Equatable {
    public private(set) var episodeID: UUID
    public private(set) var episodeStartedAt: TimeInterval
    public private(set) var attemptCount: Int
    public private(set) var sameRouteRebuildCount: Int
    public private(set) var softwareDecoderTransitionCount: Int
    public private(set) var routeTransitionCount: Int
    public private(set) var sessionFirstFailure: AetherPlaybackFailure?
    public private(set) var episodeFirstFailure: AetherPlaybackFailure?
    public private(set) var terminalOutcomeWasIssued: Bool

    public init(now: TimeInterval = 0) {
        episodeID = UUID()
        episodeStartedAt = now
        attemptCount = 0
        sameRouteRebuildCount = 0
        softwareDecoderTransitionCount = 0
        routeTransitionCount = 0
        sessionFirstFailure = nil
        episodeFirstFailure = nil
        terminalOutcomeWasIssued = false
    }

    public mutating func begin(
        with failure: AetherPlaybackFailure,
        now: TimeInterval
    ) {
        sessionFirstFailure = sessionFirstFailure ?? failure
        guard episodeFirstFailure == nil else { return }
        episodeFirstFailure = failure
        episodeStartedAt = now
    }

    public mutating func recordAttempt(
        _ action: AetherPlaybackRecoveryAction
    ) {
        attemptCount += 1
        switch action {
        case .rebuildSameRoute:
            sameRouteRebuildCount += 1
        case .switchToSoftwareDecoder:
            softwareDecoderTransitionCount += 1
        case .transition:
            routeTransitionCount += 1
        case .retrySameOperation, .terminate:
            break
        }
    }

    public mutating func resetEpisode(now: TimeInterval) {
        episodeID = UUID()
        episodeStartedAt = now
        attemptCount = 0
        sameRouteRebuildCount = 0
        softwareDecoderTransitionCount = 0
        routeTransitionCount = 0
        episodeFirstFailure = nil
    }

    public func elapsedSeconds(now: TimeInterval) -> TimeInterval {
        max(0, now - episodeStartedAt)
    }

    public mutating func claimTerminalOutcome() -> Bool {
        guard !terminalOutcomeWasIssued else { return false }
        terminalOutcomeWasIssued = true
        return true
    }
}

public enum AetherPlaybackRecoveryOutcome:
    String,
    Sendable,
    Equatable
{
    case scheduled
    case succeeded
    case failed
    case exhausted
}

public struct AetherPlaybackCapabilityDelta:
    Sendable,
    Equatable
{
    public let before: AetherPlaybackCapabilities
    public let after: AetherPlaybackCapabilities

    public init(
        before: AetherPlaybackCapabilities,
        after: AetherPlaybackCapabilities
    ) {
        self.before = before
        self.after = after
    }
}

public struct AetherPlaybackRecoveryEvent:
    Sendable,
    Equatable
{
    public let sequence: UInt64
    public let episodeID: UUID
    public let attempt: Int
    public let fromRoute: PlaybackRenderRoute?
    public let toRoute: PlaybackRenderRoute?
    public let failure: AetherPlaybackFailure
    public let action: AetherPlaybackRecoveryAction
    public let outcome: AetherPlaybackRecoveryOutcome
    public let capabilityDelta: AetherPlaybackCapabilityDelta?

    public init(
        sequence: UInt64,
        episodeID: UUID,
        attempt: Int,
        fromRoute: PlaybackRenderRoute?,
        toRoute: PlaybackRenderRoute?,
        failure: AetherPlaybackFailure,
        action: AetherPlaybackRecoveryAction,
        outcome: AetherPlaybackRecoveryOutcome,
        capabilityDelta: AetherPlaybackCapabilityDelta? = nil
    ) {
        self.sequence = sequence
        self.episodeID = episodeID
        self.attempt = attempt
        self.fromRoute = fromRoute
        self.toRoute = toRoute
        self.failure = failure
        self.action = action
        self.outcome = outcome
        self.capabilityDelta = capabilityDelta
    }
}
