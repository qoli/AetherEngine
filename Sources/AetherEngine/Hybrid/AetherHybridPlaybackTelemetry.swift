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
    case hlsPreflightRequired
    case hlsPreflightResourceGraphMissing
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
    case carrierPresentationNotConfigured
    case carrierPresentationConfigurationTooLate
    case carrierPresentationContractChanged
    case resumeIntentMissing
    case hlsPreflightGenerationInvalidated(
        AetherHLSPreflightInvalidationReason
    )
    case providerFailed
    case carrierFailed
    case presentationFailed
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
        case .hlsPreflightRequired:
            .hlsPreflightRequired
        case .hlsPreflightResourceGraphMissing:
            .hlsPreflightResourceGraphMissing
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
        case .carrierPresentationNotConfigured:
            .carrierPresentationNotConfigured
        case .carrierPresentationConfigurationTooLate:
            .carrierPresentationConfigurationTooLate
        case .carrierPresentationContractChanged:
            .carrierPresentationContractChanged
        case .resumeIntentMissing:
            .resumeIntentMissing
        case .hlsPreflightGenerationInvalidated(let reason):
            .hlsPreflightGenerationInvalidated(reason)
        case .providerFailed:
            .providerFailed
        case .carrierFailed:
            .carrierFailed
        case .presentationFailed:
            .presentationFailed
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

/// Stable terminal identity for one independent audio-analysis request.
///
/// Error descriptions remain local diagnostics because transport and decoder
/// messages can contain source details. Track and segment identities are
/// carried by the typed event fields when they are part of the admitted graph.
public enum AetherHybridAudioAnalysisTelemetryFailure:
    String,
    Sendable,
    Equatable
{
    case invalidRange
    case noActiveSession
    case liveOrDVRUnsupported
    case sourceNotSeekable
    case sourceCannotCreateIndependentReader
    case audioTrackUnavailable
    case rangeOutsideSource
    case contentProtectionUnsupported
    case hlsResourceFailure
    case hlsAudioContractChanged
    case hlsSegmentDecodeFailed
    case hlsTimestampInvalid
    case concurrentConsumer
    case cancelled
    case analysisFailed

    init(_ error: AudioAnalysisError) {
        self = switch error {
        case .invalidRange:
            .invalidRange
        case .noActiveSession:
            .noActiveSession
        case .liveOrDVRUnsupported:
            .liveOrDVRUnsupported
        case .sourceNotSeekable:
            .sourceNotSeekable
        case .sourceCannotCreateIndependentReader:
            .sourceCannotCreateIndependentReader
        case .audioTrackUnavailable:
            .audioTrackUnavailable
        case .rangeOutsideSource:
            .rangeOutsideSource
        case .contentProtectionUnsupported:
            .contentProtectionUnsupported
        case .hlsResourceFailure:
            .hlsResourceFailure
        case .hlsAudioContractChanged:
            .hlsAudioContractChanged
        case .hlsSegmentDecodeFailed:
            .hlsSegmentDecodeFailed
        case .hlsTimestampInvalid:
            .hlsTimestampInvalid
        case .concurrentConsumer:
            .concurrentConsumer
        case .cancelled:
            .cancelled
        case .analysisFailed:
            .analysisFailed
        }
    }
}

public enum AetherHybridAudioAnalysisTelemetryPhase:
    Sendable,
    Equatable
{
    case started
    case progress
    case completed
    case failed(AetherHybridAudioAnalysisTelemetryFailure)
}

/// Privacy-safe lifecycle snapshot for one independent analysis cursor.
///
/// Byte counters describe only this analysis request. `sourceCacheHitBytes`
/// includes validated immutable-byte reuse and admitted HLS payload reuse;
/// `sourceFetchedBytes` includes origin bytes fetched by this request. Neither
/// counter is used to select a route, track, decoder or recovery action.
public struct AetherHybridAudioAnalysisTelemetry:
    Sendable,
    Equatable
{
    public let analysisID: UUID
    public let audioTrackID: Int
    public let rangeStartSeconds: Double
    public let rangeEndSeconds: Double
    public let phase: AetherHybridAudioAnalysisTelemetryPhase
    public let decodedUntilSeconds: Double?
    public let bufferedFrames: Int64
    public let sourceCacheHitBytes: Int64
    public let sourceFetchedBytes: Int64
    public let pausedForPlaybackCount: Int
    public let pausedForPlaybackDurationSeconds: Double

    init(
        analysisID: UUID,
        audioTrackID: Int,
        rangeStartSeconds: Double,
        rangeEndSeconds: Double,
        phase: AetherHybridAudioAnalysisTelemetryPhase,
        decodedUntilSeconds: Double?,
        bufferedFrames: Int64,
        sourceCacheHitBytes: Int64,
        sourceFetchedBytes: Int64,
        pausedForPlaybackCount: Int,
        pausedForPlaybackDurationSeconds: Double
    ) {
        self.analysisID = analysisID
        self.audioTrackID = audioTrackID
        self.rangeStartSeconds = rangeStartSeconds
        self.rangeEndSeconds = rangeEndSeconds
        self.phase = phase
        self.decodedUntilSeconds = decodedUntilSeconds
        self.bufferedFrames = bufferedFrames
        self.sourceCacheHitBytes = sourceCacheHitBytes
        self.sourceFetchedBytes = sourceFetchedBytes
        self.pausedForPlaybackCount = pausedForPlaybackCount
        self.pausedForPlaybackDurationSeconds =
            pausedForPlaybackDurationSeconds
    }
}

/// Generation-bound timeline point for carrier, decoded-frame and seek events.
public struct AetherHybridTimelineTelemetry:
    Sendable,
    Equatable
{
    public let generation: UInt64
    public let targetSeconds: Double
    public let segmentIndex: Int
    public let framePresentationTimeSeconds: Double?

    init(
        generation: UInt64,
        targetSeconds: Double,
        segmentIndex: Int,
        framePresentationTimeSeconds: Double? = nil
    ) {
        self.generation = generation
        self.targetSeconds = targetSeconds
        self.segmentIndex = segmentIndex
        self.framePresentationTimeSeconds =
            framePresentationTimeSeconds
    }
}

/// Periodic sample of the only master clock against the latest real-video
/// sample accepted by `AVSampleBufferDisplayLayer`. This reports enqueue lead,
/// not display latency or presented-frame A/V drift.
public struct AetherHybridSampleBufferQueueTelemetry:
    Sendable,
    Equatable
{
    public let playerTimeSeconds: Double
    public let lastEnqueuedTimeSeconds: Double?
    public let enqueueLeadMilliseconds: Double?
    public let pendingSampleBuffers: Int

    init(
        playerTimeSeconds: Double,
        lastEnqueuedTimeSeconds: Double?,
        enqueueLeadMilliseconds: Double?,
        pendingSampleBuffers: Int
    ) {
        self.playerTimeSeconds = playerTimeSeconds
        self.lastEnqueuedTimeSeconds =
            lastEnqueuedTimeSeconds
        self.enqueueLeadMilliseconds =
            enqueueLeadMilliseconds
        self.pendingSampleBuffers = pendingSampleBuffers
    }
}

public struct AetherHybridBufferTelemetry:
    Sendable,
    Equatable
{
    public let pressure: HybridAudioAnalysisPlaybackPressure
    public let carrierForwardBufferSeconds: Double?
    public let carrierTimeControlStatus:
        HybridCarrierTimeControlStatus
    public let carrierRate: Float

    init(
        pressure: HybridAudioAnalysisPlaybackPressure,
        carrierForwardBufferSeconds: Double?,
        carrierTimeControlStatus:
            HybridCarrierTimeControlStatus,
        carrierRate: Float
    ) {
        self.pressure = pressure
        self.carrierForwardBufferSeconds =
            carrierForwardBufferSeconds
        self.carrierTimeControlStatus =
            carrierTimeControlStatus
        self.carrierRate = carrierRate
    }
}

public enum AetherHybridSessionEndReason:
    String,
    Sendable,
    Equatable
{
    case playbackCompleted
    case stoppedByHost
}

/// Event-specific facts. The complete session snapshot remains attached to
/// every event; this payload prevents consumers from parsing state changes or
/// human-readable logs to infer lifecycle meaning.
public enum AetherHybridPlaybackTelemetryPayload:
    Sendable,
    Equatable
{
    case none
    case carrierReady(AetherHybridTimelineTelemetry)
    case videoFirstFrameReady(AetherHybridTimelineTelemetry)
    case playbackStarted(AetherHybridTimelineTelemetry)
    case seekRequested(AetherHybridTimelineTelemetry)
    case seekVideoReady(AetherHybridTimelineTelemetry)
    case sampleBufferQueueSample(
        AetherHybridSampleBufferQueueTelemetry
    )
    case bufferStateChanged(AetherHybridBufferTelemetry)
    case sessionEnded(AetherHybridSessionEndReason)
    case sessionFailed(AetherHybridPlaybackTelemetryFailure)
    case audioAnalysis(AetherHybridAudioAnalysisTelemetry)
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
    case carrierReady
    case videoFirstFrameReady
    case playbackStarted
    case seekRequested
    case seekVideoReady
    case sampleBufferQueueSample
    case bufferStateChanged
    case sessionEnded
    case sessionFailed
    case audioAnalysisStarted
    case audioAnalysisProgress
    case audioAnalysisCompleted
    case audioAnalysisFailed
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
    public let realVideoFrameRate: Double?
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
    /// Decoder pre-roll rejected before renderer admission in the current generation.
    public let readinessPrerollFramesRejected: UInt64
    public let carrierBandwidth:
        AetherHybridCarrierBandwidthTelemetry
    public let renderer: AetherHybridPresentationView.Diagnostics
    public let systemFeaturePolicy:
        HybridPlaybackSystemFeaturePolicy

    init(
        route: PlaybackRenderRoute,
        routeReason: PlaybackRouteReason,
        state: AetherHybridPlaybackTelemetryState,
        generation: UInt64,
        videoFormat: VideoFormat,
        realVideoFrameRate: Double?,
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
        readinessPrerollFramesRejected: UInt64,
        carrierBandwidth:
            AetherHybridCarrierBandwidthTelemetry,
        renderer: AetherHybridPresentationView.Diagnostics,
        systemFeaturePolicy:
            HybridPlaybackSystemFeaturePolicy
    ) {
        self.route = route
        self.routeReason = routeReason
        self.state = state
        self.generation = generation
        self.videoFormat = videoFormat
        self.realVideoFrameRate = realVideoFrameRate
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
        self.readinessPrerollFramesRejected =
            readinessPrerollFramesRejected
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
    public let payload: AetherHybridPlaybackTelemetryPayload
    public let snapshot: AetherHybridPlaybackTelemetrySnapshot

    init(
        sessionID: UUID,
        sequence: UInt64,
        kind: AetherHybridPlaybackTelemetryEventKind,
        payload: AetherHybridPlaybackTelemetryPayload,
        snapshot: AetherHybridPlaybackTelemetrySnapshot
    ) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.kind = kind
        self.payload = payload
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
        payload: AetherHybridPlaybackTelemetryPayload = .none,
        snapshot: AetherHybridPlaybackTelemetrySnapshot
    ) -> AetherHybridPlaybackTelemetryEvent? {
        guard !isFinished else { return nil }
        sequence &+= 1
        let event = AetherHybridPlaybackTelemetryEvent(
            sessionID: sessionID,
            sequence: sequence,
            kind: kind,
            payload: payload,
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
