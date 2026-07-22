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

/// Closed, privacy-safe cause for an engine-owned presentation rebuild.
/// Values describe only the local AVPlayer signal; no source identity or
/// framework-provided reason text crosses the public boundary.
public enum AetherPlaybackRecoveryTrigger:
    String,
    Sendable,
    Equatable
{
    case playbackStalled
    case timeJump
    case mediaSelection
}

/// Closed operation phase attached to recovery failures and history. This is
/// diagnostic evidence only and never grants another route, source or retry.
public enum AetherPlaybackRecoveryStep:
    String,
    Sendable,
    Equatable
{
    case providerRestart
    case carrierSeek
    case providerPrepare
    case presentationReadiness
    case install
    case prepare
    case contextSeek
    case contextApply
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
    /// Optional closed machine code for the concrete failure case. It never
    /// contains a URL, response text, request field or credential.
    public let caseCode: String?
    public let recoveryTrigger: AetherPlaybackRecoveryTrigger?
    public let recoveryStep: AetherPlaybackRecoveryStep?
    public let reason: String

    public init(
        stage: AetherPlaybackRecoveryStage,
        kind: AetherPlaybackFailureKind,
        domain: String,
        code: Int,
        caseCode: String? = nil,
        recoveryTrigger: AetherPlaybackRecoveryTrigger? = nil,
        recoveryStep: AetherPlaybackRecoveryStep? = nil,
        reason: String
    ) {
        self.stage = stage
        self.kind = kind
        self.domain = domain
        self.code = code
        self.caseCode = caseCode
        self.recoveryTrigger = recoveryTrigger
        self.recoveryStep = recoveryStep
        self.reason = reason
    }

    public var errorDescription: String? { reason }
}

extension AetherPlaybackFailure {
    func recordingRecoveryDiagnostic(
        trigger: AetherPlaybackRecoveryTrigger? = nil,
        step: AetherPlaybackRecoveryStep
    ) -> AetherPlaybackFailure {
        AetherPlaybackFailure(
            stage: stage,
            kind: kind,
            domain: domain,
            code: code,
            caseCode: caseCode,
            recoveryTrigger: trigger ?? recoveryTrigger,
            recoveryStep: step,
            reason: reason
        )
    }
}

/// The single terminal outcome issued by a playback session. The first
/// evidence remains available even when the last failed recovery attempt came
/// from another stage or route.
public struct AetherPlaybackTerminalFailure:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    public let firstFailure: AetherPlaybackFailure
    public let finalFailure: AetherPlaybackFailure
    public let exhaustionReason: String

    public init(
        firstFailure: AetherPlaybackFailure,
        finalFailure: AetherPlaybackFailure,
        exhaustionReason: String
    ) {
        self.firstFailure = firstFailure
        self.finalFailure = finalFailure
        self.exhaustionReason = exhaustionReason
    }

    public var errorDescription: String? {
        finalFailure.localizedDescription
    }
}

/// Bounded policy for Aether-owned recovery of one canonical playback request.
///
/// Production allows 15 seconds for the complete initial preparation window
/// and 30 seconds for a later recovery episode. Session operations are clamped
/// to the applicable remaining window. Expiry is reported through failure
/// domain `AetherPlaybackOperationDeadline` and case code
/// `operation.deadlineExceeded`; it is never permission to substitute another
/// source, media identity, credential scope, DRM meaning, or server URL.
public struct AetherPlaybackRecoveryBudget:
    Sendable,
    Equatable
{
    public let maximumTransportAttempts: Int
    public let maximumSameRouteRebuilds: Int
    public let maximumSoftwareDecoderTransitions: Int
    public let maximumRouteTransitions: Int
    /// Wall-clock limit shared by canonical resolution and route preparation.
    public let initialPreparationSettleSeconds: TimeInterval
    /// Wall-clock limit shared by every action in one recovery episode.
    public let maximumEpisodeDurationSeconds: TimeInterval
    /// Time allowed for a positive transport intent to demonstrate real
    /// media-time progress before Aether begins one recovery episode.
    public let startupProgressObservationSeconds: TimeInterval
    /// MainActor publication allowance after the recovery episode closes.
    /// This is not an additional retry or observation budget.
    public let startupTerminalPublicationHeadroomSeconds: TimeInterval
    public let healthyProgressResetSeconds: TimeInterval

    /// Maximum time from a startup transport command to Aether's typed
    /// progress or terminal outcome. Hosts may add only their own polling
    /// granularity; they must not pre-empt this engine-owned window.
    public var maximumStartupOutcomeSeconds: TimeInterval {
        startupProgressObservationSeconds
            + maximumEpisodeDurationSeconds
            + startupTerminalPublicationHeadroomSeconds
    }

    /// The context restore is part of the already-open recovery episode, not
    /// a fresh preparation operation. It may use the episode's actual
    /// remaining time while preserving the terminal publication allowance.
    /// Returning nil means no operation may start without stealing headroom.
    func recoveryContextRestoreTimeout(
        episodeRemainingSeconds: TimeInterval
    ) -> TimeInterval? {
        guard episodeRemainingSeconds.isFinite else { return nil }
        let timeout = episodeRemainingSeconds
            - startupTerminalPublicationHeadroomSeconds
        return timeout > 0 ? timeout : nil
    }

    public init(
        maximumTransportAttempts: Int = 3,
        maximumSameRouteRebuilds: Int = 1,
        maximumSoftwareDecoderTransitions: Int = 1,
        maximumRouteTransitions: Int = 1,
        initialPreparationSettleSeconds: TimeInterval = 15,
        maximumEpisodeDurationSeconds: TimeInterval = 30,
        startupProgressObservationSeconds: TimeInterval = 30,
        startupTerminalPublicationHeadroomSeconds: TimeInterval = 0.25,
        healthyProgressResetSeconds: TimeInterval = 2
    ) {
        precondition(maximumTransportAttempts > 0)
        precondition(maximumSameRouteRebuilds >= 0)
        precondition(maximumSoftwareDecoderTransitions >= 0)
        precondition(maximumRouteTransitions >= 0)
        precondition(initialPreparationSettleSeconds > 0)
        precondition(maximumEpisodeDurationSeconds > 0)
        precondition(
            startupProgressObservationSeconds.isFinite
                && startupProgressObservationSeconds > 0
        )
        precondition(
            startupTerminalPublicationHeadroomSeconds.isFinite
                && startupTerminalPublicationHeadroomSeconds >= 0
        )
        precondition(healthyProgressResetSeconds > 0)
        self.maximumTransportAttempts = maximumTransportAttempts
        self.maximumSameRouteRebuilds = maximumSameRouteRebuilds
        self.maximumSoftwareDecoderTransitions =
            maximumSoftwareDecoderTransitions
        self.maximumRouteTransitions = maximumRouteTransitions
        self.initialPreparationSettleSeconds =
            initialPreparationSettleSeconds
        self.maximumEpisodeDurationSeconds = maximumEpisodeDurationSeconds
        self.startupProgressObservationSeconds =
            startupProgressObservationSeconds
        self.startupTerminalPublicationHeadroomSeconds =
            startupTerminalPublicationHeadroomSeconds
        self.healthyProgressResetSeconds = healthyProgressResetSeconds
    }

    /// The production same-request recovery policy: 15-second preparation,
    /// 30-second recovery episodes, and two seconds of healthy progress before
    /// an episode budget may reset.
    public static let production = AetherPlaybackRecoveryBudget()
}

/// One recovery-episode transport failure budget shared by classification,
/// preflight and graph-bound origin requests. Successful requests do not
/// consume it; the third retryable failure closes the budget until explicit
/// Seek/load or two seconds of healthy playback resets the episode.
final class PlaybackTransportRetryBudget:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let maximumFailureAttempts: Int
    private var failureAttempts = 0

    init(maximumFailureAttempts: Int) {
        precondition(maximumFailureAttempts > 0)
        self.maximumFailureAttempts = maximumFailureAttempts
    }

    var isExhausted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failureAttempts >= maximumFailureAttempts
    }

    @discardableResult
    func recordRetryableFailure() -> Int {
        lock.lock()
        defer { lock.unlock() }
        if failureAttempts < maximumFailureAttempts {
            failureAttempts += 1
        }
        return failureAttempts
    }

    var currentFailureAttempt: Int {
        lock.lock()
        defer { lock.unlock() }
        return failureAttempts
    }

    func reset() {
        lock.lock()
        failureAttempts = 0
        lock.unlock()
    }
}

struct PlaybackRecoveryDeadline: Sendable, Equatable {
    let startedAt: TimeInterval
    let durationSeconds: TimeInterval

    init(startedAt: TimeInterval, durationSeconds: TimeInterval) {
        precondition(startedAt.isFinite)
        precondition(durationSeconds.isFinite && durationSeconds > 0)
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
    }

    func remainingSeconds(now: TimeInterval) -> TimeInterval {
        max(0, startedAt + durationSeconds - now)
    }

    func isExpired(now: TimeInterval) -> Bool {
        remainingSeconds(now: now) <= 0
    }
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
    /// Startup transport recovery may rebuild the exact admitted route once,
    /// but it must never reinterpret a parked/no-progress player as evidence
    /// for another route. The original failure remains authoritative even if
    /// the rebuild later fails with a different preparation error.
    public static func requiresSameRouteTransportRecovery(
        failure: AetherPlaybackFailure
    ) -> Bool {
        failure.stage == .playback
            && failure.kind == .routeRuntimeFailure
            && (failure.caseCode == "transportIntentNotApplied"
                || failure.caseCode == "startupNoProgress")
    }

    public static func permitsRouteTransition(
        afterInitialFailure failure: AetherPlaybackFailure
    ) -> Bool {
        !requiresSameRouteTransportRecovery(failure: failure)
    }

    /// Positive runtime HEVC evidence invalidates Native itself, not merely
    /// the current item generation. The coordinator must never rebuild the
    /// same Native route after this closed case code; it may only enter a
    /// freshly admitted same-source Hybrid route or terminate.
    public static func requiresImmediateNativeExit(
        failure: AetherPlaybackFailure,
        activeRoute: PlaybackRenderRoute?
    ) -> Bool {
        activeRoute == .nativeAVPlayer
            && failure.caseCode
                == "native.observedHEVCRequiresHybrid"
    }

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
            if requiresImmediateNativeExit(
                failure: context.failure,
                activeRoute: context.activeRoute
            ) {
                guard context.routeTransitionCount
                        < budget.maximumRouteTransitions,
                      context.positivelyAdmittedAlternateRoute
                        == .hybridCarrier,
                      !context.systemActivity
                        .blocksHybridTransition else {
                    return .terminate
                }
                return .transition(to: .hybridCarrier)
            }
            if context.sameRouteRebuildCount
                    < budget.maximumSameRouteRebuilds {
                return .rebuildSameRoute
            }
            if requiresSameRouteTransportRecovery(
                failure: context.failure
            ) {
                return .terminate
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

/// Pure classification of typed Hybrid evidence. Keeping this outside the
/// route session prevents resource pressure, media corruption and host
/// binding drift from collapsing into one generic runtime failure.
enum PlaybackFailureEvidenceDecision {
    static func kind(
        for error: AetherHybridPresentationError
    ) -> AetherPlaybackFailureKind {
        switch error {
        case .invalidPresentationTime, .invalidFrameDuration,
             .invalidGeometry, .unsupportedRotation,
             .nonMonotonicPresentationTime:
            .malformedMedia
        case .frameFormatDiverged:
            .routeRuntimeFailure
        case .unsupportedVideoFormat:
            .unsupportedCapability
        case .carrierBindingChanged,
             .displayLayerTimebaseChanged:
            .hostContractViolation
        case .pixelBufferNotIOSurfaceBacked:
            .decoderRuntimeFailure
        case .pendingQueueOverflow, .carrierTimebaseUnavailable,
             .rendererStalled, .rendererFailed,
             .formatDescriptionCreationFailed,
             .sampleBufferCreationFailed,
             .sampleAttachmentCreationFailed:
            .routeRuntimeFailure
        }
    }

    static func hlsGraphFailureCode(
        _ reason: AetherHLSPreflightInvalidationReason
    ) -> String {
        switch reason {
        case .resourceUnavailable(
            let statusCode,
            let resource
        ) where statusCode == 404 || statusCode == 410:
            switch resource {
            case .videoInit, .videoSegment:
                return "hybrid.origin.selectedVariantUnavailable"
            case .audioInit, .audioSegment, .subtitleSegment:
                return "hybrid.hls.graph.resourceUnavailable"
            }
        case .resourceUnavailable:
            return "hybrid.hls.graph.resourceUnavailable"
        case .contentChanged:
            return "hybrid.hls.graph.contentChanged"
        case .credentialRejected:
            return "hybrid.hls.graph.credentialRejected"
        case .effectiveOriginChanged:
            return "hybrid.hls.graph.effectiveOriginChanged"
        case .credentialScopeChanged:
            return "hybrid.hls.graph.credentialScopeChanged"
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
    case merged
}

/// Pure operation ordering used by the MainActor session. Route generations
/// may finish out of order, but only the newest user Seek is allowed to commit
/// position or failure state.
struct PlaybackOperationCoordinator: Sendable, Equatable {
    private(set) var latestSeekSequence: UInt64 = 0

    mutating func beginSeek() -> UInt64 {
        latestSeekSequence &+= 1
        return latestSeekSequence
    }

    func isCurrentSeek(_ sequence: UInt64) -> Bool {
        sequence == latestSeekSequence
    }
}

struct PlaybackRouteTransactionCoordinator: Sendable, Equatable {
    private(set) var latestSequence: UInt64 = 0
    private(set) var activeSequence: UInt64?

    mutating func begin() -> UInt64 {
        latestSequence &+= 1
        activeSequence = latestSequence
        return latestSequence
    }

    func isActive(_ sequence: UInt64) -> Bool {
        activeSequence == sequence
    }

    mutating func invalidate() {
        activeSequence = nil
    }
}

/// Generation/user-action scoped proof that playback has made real monotonic
/// progress. Timeline jumps while seeking never count toward the healthy
/// progress reset budget; the first eligible clock sample anchors the epoch.
struct PlaybackProgressEpoch: Sendable, Equatable {
    private(set) var sequence: UInt64 = 0
    private(set) var baselineSeconds: Double?

    mutating func begin() {
        sequence &+= 1
        baselineSeconds = nil
    }

    mutating func observe(
        seconds: Double,
        eligible: Bool,
        requiredProgressSeconds: TimeInterval
    ) -> Bool {
        guard seconds.isFinite,
              eligible,
              requiredProgressSeconds.isFinite,
              requiredProgressSeconds > 0 else {
            return false
        }
        guard let baselineSeconds else {
            self.baselineSeconds = seconds
            return false
        }
        let progress = seconds - baselineSeconds
        guard progress >= 0 else {
            self.baselineSeconds = seconds
            return false
        }
        guard progress >= requiredProgressSeconds else {
            return false
        }
        self.baselineSeconds = seconds
        return true
    }
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
