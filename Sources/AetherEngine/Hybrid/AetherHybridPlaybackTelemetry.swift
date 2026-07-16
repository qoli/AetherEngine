import CoreMedia
import Foundation

/// Privacy-safe terminal reason for structured hybrid playback telemetry.
///
/// Associated provider, carrier, decoder and readiness strings remain in local diagnostics only because
/// they may contain source or transport details. The production telemetry contract publishes only this
/// stable failure identity.
public enum AetherHybridPlaybackTelemetryFailure:
    Sendable,
    Equatable
{
    case videoPipelineMissing
    case renderSurfaceMissing
    case invalidSeekableVODOptions
    case sourceIndependentReaderUnavailable
    case sourceKindMismatch
    case timelineSourceMismatch
    case preflightRequiresHybrid
    case preflightContractChanged
    case sourceVideoFormatDiverged
    case invalidReadinessTimeout
    case invalidSeekTarget
    case invalidRate
    case notReady
    case alreadyPreparing
    case alreadyStopped
    case carrierItemMissing
    case carrierClockUnavailable
    case resumeIntentMissing
    case hlsPreflightGenerationInvalidated(
        AetherHLSPreflightInvalidationReason
    )
    case providerFailed
    case carrierFailed
    case rendererFailed
    case decoderFailed
    case readinessFailed
    case readinessTimedOut
    case carrierSeekDidNotLand
    case generationDiverged
    case cancelled

    init(_ error: HybridPlaybackSessionError) {
        self = switch error {
        case .videoPipelineMissing:
            .videoPipelineMissing
        case .renderSurfaceMissing:
            .renderSurfaceMissing
        case .invalidSeekableVODOptions:
            .invalidSeekableVODOptions
        case .sourceIndependentReaderUnavailable:
            .sourceIndependentReaderUnavailable
        case .sourceKindMismatch:
            .sourceKindMismatch
        case .timelineSourceMismatch:
            .timelineSourceMismatch
        case .preflightRequiresHybrid:
            .preflightRequiresHybrid
        case .preflightContractChanged:
            .preflightContractChanged
        case .sourceVideoFormatDiverged:
            .sourceVideoFormatDiverged
        case .invalidReadinessTimeout:
            .invalidReadinessTimeout
        case .invalidSeekTarget:
            .invalidSeekTarget
        case .invalidRate:
            .invalidRate
        case .notReady:
            .notReady
        case .alreadyPreparing:
            .alreadyPreparing
        case .alreadyStopped:
            .alreadyStopped
        case .carrierItemMissing:
            .carrierItemMissing
        case .carrierClockUnavailable:
            .carrierClockUnavailable
        case .resumeIntentMissing:
            .resumeIntentMissing
        case .hlsPreflightGenerationInvalidated(let reason):
            .hlsPreflightGenerationInvalidated(reason)
        case .providerFailed:
            .providerFailed
        case .carrierFailed:
            .carrierFailed
        case .rendererFailed:
            .rendererFailed
        case .decoderFailed:
            .decoderFailed
        case .readinessFailed:
            .readinessFailed
        case .readinessTimedOut:
            .readinessTimedOut
        case .carrierSeekDidNotLand:
            .carrierSeekDidNotLand
        case .generationDiverged:
            .generationDiverged
        case .cancelled:
            .cancelled
        }
    }
}

/// Structured, privacy-safe mirror of the public hybrid session state.
public enum AetherHybridPlaybackTelemetryState:
    Sendable,
    Equatable
{
    case idle
    case preparing(
        generation: UInt64,
        targetSeconds: Double?
    )
    case ready(generation: UInt64)
    case seeking(
        generation: UInt64,
        targetSeconds: Double?
    )
    case failed(AetherHybridPlaybackTelemetryFailure)
    case stopped

    init(_ state: HybridPlaybackSessionState) {
        self = switch state {
        case .idle:
            .idle
        case .preparing(let generation, let target):
            .preparing(
                generation: generation,
                targetSeconds: Self.validSeconds(target)
            )
        case .ready(let generation):
            .ready(generation: generation)
        case .seeking(let generation, let target):
            .seeking(
                generation: generation,
                targetSeconds: Self.validSeconds(target)
            )
        case .failed(let error):
            .failed(
                AetherHybridPlaybackTelemetryFailure(error)
            )
        case .stopped:
            .stopped
        }
    }

    private static func validSeconds(_ time: CMTime) -> Double? {
        guard time.isValid, time.isNumeric else { return nil }
        let seconds = time.seconds
        return seconds.isFinite ? seconds : nil
    }
}

/// Why a structured snapshot was emitted.
public enum AetherHybridPlaybackTelemetryEventKind:
    String,
    Sendable,
    Equatable
{
    case sessionCreated
    case stateChanged
    case transportChanged
    case periodicSample
    case playbackPressureChanged
    case audioAnalysisChanged
}

/// Privacy-safe hybrid playback facts captured at one ordered event boundary.
///
/// This intentionally excludes source URLs, request headers, cookies, credentials and arbitrary error
/// descriptions. `route` and `routeReason` are the exact preflight decision used to create the session.
public struct AetherHybridPlaybackTelemetrySnapshot:
    Sendable,
    Equatable
{
    public let route: PlaybackRenderRoute
    public let routeReason: PlaybackRouteReason
    public let state: AetherHybridPlaybackTelemetryState
    public let generation: UInt64
    public let videoFormat: VideoFormat
    public let timelineDurationSeconds: Double
    public let carrierTimeSeconds: Double?
    public let carrierRate: Float
    public let carrierTimeControlStatus:
        HybridCarrierTimeControlStatus
    public let carrierForwardBufferSeconds: Double?
    public let audioAnalysisPlaybackPressure:
        HybridAudioAnalysisPlaybackPressure
    public let audioAnalysisTrackIDs: [Int]
    public let activeAudioAnalysisRequestCount: Int
    public let carrierBandwidth:
        AetherHybridCarrierBandwidthTelemetry
    public let renderer: AetherMetalPlayerView.Diagnostics
    public let systemFeaturePolicy:
        HybridPlaybackSystemFeaturePolicy

    init(
        route: PlaybackRenderRoute,
        routeReason: PlaybackRouteReason,
        state: AetherHybridPlaybackTelemetryState,
        generation: UInt64,
        videoFormat: VideoFormat,
        timelineDurationSeconds: Double,
        carrierTimeSeconds: Double?,
        carrierRate: Float,
        carrierTimeControlStatus:
            HybridCarrierTimeControlStatus,
        carrierForwardBufferSeconds: Double?,
        audioAnalysisPlaybackPressure:
            HybridAudioAnalysisPlaybackPressure,
        audioAnalysisTrackIDs: [Int],
        activeAudioAnalysisRequestCount: Int,
        carrierBandwidth:
            AetherHybridCarrierBandwidthTelemetry,
        renderer: AetherMetalPlayerView.Diagnostics,
        systemFeaturePolicy:
            HybridPlaybackSystemFeaturePolicy
    ) {
        self.route = route
        self.routeReason = routeReason
        self.state = state
        self.generation = generation
        self.videoFormat = videoFormat
        self.timelineDurationSeconds =
            timelineDurationSeconds
        self.carrierTimeSeconds = carrierTimeSeconds
        self.carrierRate = carrierRate
        self.carrierTimeControlStatus =
            carrierTimeControlStatus
        self.carrierForwardBufferSeconds =
            carrierForwardBufferSeconds
        self.audioAnalysisPlaybackPressure =
            audioAnalysisPlaybackPressure
        self.audioAnalysisTrackIDs = audioAnalysisTrackIDs
        self.activeAudioAnalysisRequestCount =
            activeAudioAnalysisRequestCount
        self.carrierBandwidth = carrierBandwidth
        self.renderer = renderer
        self.systemFeaturePolicy = systemFeaturePolicy
    }
}

/// One event in the bounded, session-scoped hybrid telemetry stream.
public struct AetherHybridPlaybackTelemetryEvent:
    Sendable,
    Equatable
{
    public let sessionID: UUID
    public let sequence: UInt64
    public let kind: AetherHybridPlaybackTelemetryEventKind
    public let snapshot: AetherHybridPlaybackTelemetrySnapshot

    init(
        sessionID: UUID,
        sequence: UInt64,
        kind: AetherHybridPlaybackTelemetryEventKind,
        snapshot: AetherHybridPlaybackTelemetrySnapshot
    ) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.kind = kind
        self.snapshot = snapshot
    }
}

@MainActor
final class AetherHybridPlaybackTelemetryHub {
    static let defaultHistoryLimit = 64

    let sessionID: UUID

    private let historyLimit: Int
    private var sequence: UInt64 = 0
    private var history:
        [AetherHybridPlaybackTelemetryEvent] = []
    private var continuations: [
        UUID:
            AsyncStream<
                AetherHybridPlaybackTelemetryEvent
            >.Continuation
    ] = [:]
    private var isFinished = false

    init(
        sessionID: UUID = UUID(),
        historyLimit: Int = defaultHistoryLimit
    ) {
        precondition(historyLimit > 0)
        self.sessionID = sessionID
        self.historyLimit = historyLimit
    }

    func stream()
        -> AsyncStream<AetherHybridPlaybackTelemetryEvent>
    {
        let subscriptionID = UUID()
        let pair = AsyncStream.makeStream(
            of: AetherHybridPlaybackTelemetryEvent.self,
            bufferingPolicy: .bufferingNewest(historyLimit)
        )
        for event in history {
            pair.continuation.yield(event)
        }
        guard !isFinished else {
            pair.continuation.finish()
            return pair.stream
        }
        continuations[subscriptionID] = pair.continuation
        pair.continuation.onTermination = {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.continuations.removeValue(
                    forKey: subscriptionID
                )
            }
        }
        return pair.stream
    }

    @discardableResult
    func emit(
        kind: AetherHybridPlaybackTelemetryEventKind,
        snapshot: AetherHybridPlaybackTelemetrySnapshot
    ) -> AetherHybridPlaybackTelemetryEvent? {
        guard !isFinished else { return nil }
        sequence &+= 1
        let event = AetherHybridPlaybackTelemetryEvent(
            sessionID: sessionID,
            sequence: sequence,
            kind: kind,
            snapshot: snapshot
        )
        history.append(event)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
        for continuation in continuations.values {
            continuation.yield(event)
        }
        return event
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }
}
