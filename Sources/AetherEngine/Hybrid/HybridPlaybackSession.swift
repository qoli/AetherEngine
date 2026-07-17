import AVFoundation
import CoreMedia
import Foundation

public enum HybridPlaybackSessionError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case videoPipelineMissing
    case renderSurfaceMissing
    case invalidSeekableVODOptions
    case sourceIndependentReaderUnavailable
    case hlsPreflightRequired
    case hlsPreflightResourceGraphMissing
    case sourceKindMismatch(expected: AetherMediaSourceKind)
    case timelineSourceMismatch(
        sourceKind: AetherMediaSourceKind,
        timelineSource: BlackCarrierTimelineSource
    )
    case preflightRequiresHybrid(
        route: PlaybackRenderRoute,
        reason: PlaybackRouteReason
    )
    case preflightContractChanged(
        route: PlaybackRenderRoute,
        reason: PlaybackRouteReason
    )
    case sourceVideoFormatDiverged(
        preflight: VideoFormat,
        decoded: VideoFormat
    )
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
    case providerFailed(reason: String)
    case carrierFailed(reason: String)
    case presentationFailed(AetherHybridPresentationError)
    case decoderFailed(reason: String)
    case readinessFailed(reason: String)
    case readinessTimedOut(seconds: Double)
    case carrierSeekDidNotLand
    case generationDiverged(
        sessionGeneration: UInt64,
        providerGeneration: UInt64
    )
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .videoPipelineMissing:
            return "Hybrid playback requires a generation-aware real-video decoder"
        case .renderSurfaceMissing:
            return "Hybrid playback did not create its engine-owned sample-buffer presentation surface"
        case .invalidSeekableVODOptions:
            return "Hybrid playback requires non-live, video-bearing, seekable VOD load options"
        case .sourceIndependentReaderUnavailable:
            return "Hybrid playback source cannot create the independent readers required by its session"
        case .hlsPreflightRequired:
            return "Hybrid HLS playback requires an opaque AetherHLSPlaybackPreflight and makeHLSVOD"
        case .hlsPreflightResourceGraphMissing:
            return "Hybrid HLS preflight did not retain its required immutable resource graph"
        case .sourceKindMismatch(let expected):
            return "Hybrid playback source does not match preflight source kind \(expected.rawValue)"
        case .timelineSourceMismatch(
            let sourceKind,
            let timelineSource
        ):
            return "Hybrid playback \(sourceKind.rawValue) source cannot use "
                + "\(String(describing: timelineSource)) carrier timing"
        case .preflightRequiresHybrid(let route, let reason):
            return "Hybrid session creation requires .hybridCarrier, received "
                + "\(route.rawValue) (\(reason.rawValue))"
        case .preflightContractChanged(let route, let reason):
            return "Hybrid session capabilities now resolve the source as "
                + "\(route.rawValue) (\(reason.rawValue))"
        case .sourceVideoFormatDiverged(let preflight, let decoded):
            return "Hybrid decoded video format \(String(describing: decoded)) diverged from "
                + "preflight \(String(describing: preflight))"
        case .invalidReadinessTimeout:
            return "Hybrid playback readiness timeout must be positive and finite"
        case .invalidSeekTarget:
            return "Hybrid playback seek target is outside the VOD timeline"
        case .invalidRate:
            return "Hybrid playback rate must be finite and non-negative"
        case .notReady:
            return "Hybrid playback session is not ready"
        case .alreadyPreparing:
            return "Hybrid playback session is already preparing"
        case .alreadyStopped:
            return "Hybrid playback session is stopped"
        case .carrierItemMissing:
            return "Hybrid carrier transport did not create an AVPlayerItem"
        case .carrierClockUnavailable:
            return "Hybrid carrier AVPlayer did not publish a valid timeline clock"
        case .carrierPresentationNotConfigured:
            return "Hybrid tvOS playback requires configureCarrierPlayerViewController before prepare"
        case .carrierPresentationConfigurationTooLate:
            return "Hybrid tvOS carrier presentation can only be configured while the session is idle"
        case .carrierPresentationContractChanged:
            return "Hybrid tvOS carrier presentation no longer matches the engine-owned AVKit/display-criteria contract"
        case .resumeIntentMissing:
            return "Hybrid seek lost its required transport resume intent"
        case .hlsPreflightGenerationInvalidated:
            return "Hybrid HLS preflight generation is no longer valid; run a new preflight before creating another session"
        case .providerFailed(let reason):
            return "Hybrid carrier provider failed: \(reason)"
        case .carrierFailed(let reason):
            return "Hybrid AVPlayer carrier failed: \(reason)"
        case .presentationFailed(let error):
            return "Hybrid sample-buffer presentation failed: \(error.localizedDescription)"
        case .decoderFailed(let reason):
            return "Hybrid real-video decoder failed: \(reason)"
        case .readinessFailed(let reason):
            return "Hybrid presentation readiness failed: \(reason)"
        case .readinessTimedOut(let seconds):
            return "Hybrid presentation was not ready within \(seconds) seconds"
        case .carrierSeekDidNotLand:
            return "Hybrid carrier AVPlayer seek did not land"
        case .generationDiverged(
            let sessionGeneration,
            let providerGeneration
        ):
            return "Hybrid generation diverged: session "
                + "\(sessionGeneration), provider \(providerGeneration)"
        case .cancelled:
            return "Hybrid playback operation was cancelled"
        }
    }
}

public enum HybridPlaybackSessionState: Sendable, Equatable {
    case idle
    case preparing(generation: UInt64, target: CMTime)
    case ready(generation: UInt64)
    case seeking(generation: UInt64, target: CMTime)
    case failed(HybridPlaybackSessionError)
    case stopped
}

public enum HybridPlaybackSeekResult: Sendable, Equatable {
    case applied(generation: UInt64, target: CMTime)
    case superseded(currentGeneration: UInt64)
}

/// Engine-owned reason for pausing independent audio-analysis origin work.
///
/// This is a scheduling signal only. It never selects another URL, track, decoder or playback route.
public enum HybridAudioAnalysisPlaybackPressure:
    String,
    Sendable,
    Equatable
{
    case none
    case carrierPreparingOrSeeking
    case carrierWaitingToPlay
    case carrierPlaybackStalled
    case carrierBufferEmpty
    case carrierForwardBufferLow
    case carrierNotLikelyToKeepUp
}

enum HybridPlaybackTelemetryTrigger:
    Sendable,
    Equatable
{
    case transportChanged
    case periodicSample(playerTimeSeconds: Double)
    case playbackPressureChanged
    case carrierReady(AetherHybridTimelineTelemetry)
    case videoFirstFrameReady(AetherHybridTimelineTelemetry)
    case playbackStarted(AetherHybridTimelineTelemetry)
    case seekRequested(AetherHybridTimelineTelemetry)
    case seekVideoReady(AetherHybridTimelineTelemetry)
    case sessionEnded(AetherHybridSessionEndReason)
    case audioAnalysis(AetherHybridAudioAnalysisTelemetry)
}

protocol HybridCarrierTransportProvider:
    BlackCarrierTransportProvider,
    Sendable
{
    var hybridVideoFormat: VideoFormat? { get }
    var hybridVideoFrameRate: Double? { get }

    func restartMedia(
        for intent: HybridSeekIntent
    ) throws -> BlackCarrierMediaFanoutRestartResult
    func prepareHybridGeneration(segmentIndex: Int) throws
    func advanceVideoDecodeDemand(to time: CMTime) throws
}

extension BlackCarrierLazyCompositeProvider:
    HybridCarrierTransportProvider
{}

protocol HybridPlaybackTerminalErrorSource:
    Sendable
{
    var terminalHybridPlaybackError:
        HybridPlaybackSessionError? { get }
    func setTerminalHybridPlaybackErrorHandler(
        _ handler:
            (@Sendable (
                HybridPlaybackSessionError
            ) -> Void)?
    )
}

protocol HybridAudioAnalysisSource: Sendable {
    var audioAnalysisTrackIDs: [Int] { get }
    func makeAudioAnalysisInput() throws -> AudioAnalysisInput
}

protocol HybridAudioAnalysisPlaybackPressureSink: Sendable {
    func setAudioAnalysisPlaybackPressure(
        _ pressure: HybridAudioAnalysisPlaybackPressure
    ) async
}

extension BlackCarrierLazyCompositeProvider:
    HybridAudioAnalysisSource
{}

@MainActor
protocol HybridCarrierPlayerTransport: AnyObject {
    var avPlayer: AVPlayer { get }

    func startPrepared() throws
    func prepare(timeout: TimeInterval) async throws
    func seek(to time: CMTime) async -> Bool
    func stop()
}

extension BlackCarrierAVPlayerSession: HybridCarrierPlayerTransport {}

@MainActor
protocol HybridPlaybackRenderSurface: AnyObject {
    func beginGeneration(
        _ generation: UInt64,
        videoFormat: VideoFormat
    ) throws
    func enqueue(
        _ frame: DecodedVideoFrame
    ) throws -> HybridFrameEnqueueOutcome
    func bindCarrierClock(
        item: AVPlayerItem,
        timebase: CMTimebase
    ) throws
    func validateCarrierClock(
        item: AVPlayerItem,
        timebase: CMTimebase
    ) throws
    func flush(removingDisplayedImage: Bool)
    func invalidate()
}

extension AetherHybridPresentationView: HybridPlaybackRenderSurface {}

actor HybridPlaybackProviderCoordinator {
    private let provider: any HybridCarrierTransportProvider
    private let analysisPlaybackPressureSink:
        (any HybridAudioAnalysisPlaybackPressureSink)?
    private let terminalErrorSource:
        (any HybridPlaybackTerminalErrorSource)?
    private var analysisPlaybackPressureSequence: UInt64 = 0

    init(provider: any HybridCarrierTransportProvider) {
        self.provider = provider
        analysisPlaybackPressureSink =
            provider as? any HybridAudioAnalysisPlaybackPressureSink
        terminalErrorSource =
            provider as? any HybridPlaybackTerminalErrorSource
    }

    func prepareInitialGeneration() throws {
        try provider.prepareForTransportStart()
    }

    func restart(
        for intent: HybridSeekIntent
    ) throws -> BlackCarrierMediaFanoutRestartResult {
        try provider.restartMedia(for: intent)
    }

    func prepareGeneration(segmentIndex: Int) throws {
        try provider.prepareHybridGeneration(segmentIndex: segmentIndex)
    }

    func advanceDecodeDemand(to time: CMTime) throws {
        try provider.advanceVideoDecodeDemand(to: time)
    }

    func terminalHybridPlaybackError()
        -> HybridPlaybackSessionError?
    {
        terminalErrorSource?
            .terminalHybridPlaybackError
    }

    func setAudioAnalysisPlaybackPressure(
        _ pressure: HybridAudioAnalysisPlaybackPressure,
        sequence: UInt64
    ) async {
        guard sequence >= analysisPlaybackPressureSequence else {
            return
        }
        analysisPlaybackPressureSequence = sequence
        await analysisPlaybackPressureSink?
            .setAudioAnalysisPlaybackPressure(pressure)
    }
}

final class HybridPlaybackFrameRelay: @unchecked Sendable {
    private let lock = NSLock()
    private weak var session: HybridPlaybackSession?

    func attach(_ session: HybridPlaybackSession) {
        lock.lock()
        self.session = session
        lock.unlock()
    }

    func detach() {
        lock.lock()
        session = nil
        lock.unlock()
    }

    func emit(_ frame: DecodedVideoFrame) {
        lock.lock()
        let session = session
        lock.unlock()
        guard let session else { return }
        Task { @MainActor [weak session] in
            session?.receiveDecodedFrame(frame)
        }
    }

    func fail(_ error: HybridVideoDecodeSinkError) {
        lock.lock()
        let session = session
        lock.unlock()
        guard let session else { return }
        Task { @MainActor [weak session] in
            session?.receiveDecoderFailure(error)
        }
    }
}

/// Engine-owned composition of AVPlayer carrier transport, real-video decode demand and sample-buffer timing.
///
/// The carrier AVPlayer is the only clock. FFmpeg work stays behind
/// `HybridPlaybackProviderCoordinator`; MainActor owns only AVPlayer state, generation readiness and
/// the render surface. Syncnext integration is intentionally deferred until this type and the remaining
/// color/display gates become a verified public cutover surface.
@MainActor
final class HybridPlaybackSession {
    private struct ResumeIntent {
        let wasPlaying: Bool
        let rate: Float
    }

    private static let clockInterval = CMTime(
        value: 1,
        timescale: 60
    )
    private static let decodeLookahead = CMTime(
        seconds: 0.25,
        preferredTimescale: 600
    )
    static let analysisForwardBufferPressureThresholdSeconds = 2.0
    nonisolated static let telemetrySampleIntervalSeconds = 1.0
    nonisolated private static let observedJumpThresholdSeconds = 0.5

    let avPlayer: AVPlayer
    private(set) var state: HybridPlaybackSessionState = .idle {
        didSet {
            stateDidChange?(state)
            reevaluateAudioAnalysisPlaybackPressure()
        }
    }

    var presentationView: AetherHybridPresentationView? {
        renderSurface as? AetherHybridPresentationView
    }

    private let transport: any HybridCarrierPlayerTransport
    private let renderSurface: any HybridPlaybackRenderSurface
    private let coordinator: HybridPlaybackProviderCoordinator
    private let timeline: BlackCarrierTimeline
    private let videoFormat: VideoFormat
    private let videoFrameRate: Double?
    private let displayCriteriaController =
        DisplayCriteriaController()
    private let relay: HybridPlaybackFrameRelay
    private let audioAnalysisSource:
        (any HybridAudioAnalysisSource)?
    private let carrierBandwidthTelemetrySource:
        (any HybridCarrierBandwidthTelemetrySource)?
    private let subtitleController:
        HybridSubtitleSessionController?

    private var classifier: HybridSeekIntentClassifier
    private var readinessGate = HybridPresentationReadinessGate()
    private var periodicTimeObserver: Any?
    private var playerObservations: [NSKeyValueObservation] = []
    private var notificationObservers: [NSObjectProtocol] = []
    private var lastObservedPlayerTime: CMTime?
    private var managedSeekGeneration: UInt64?
    private var managedTimeJumpSuppressionTarget: CMTime?
    private var managedTimeJumpSuppressionDeadline: TimeInterval?
    private var externalJumpTask: Task<Void, Never>?
    private var pendingResumeIntent: ResumeIntent?
    private(set) var audioAnalysisPlaybackPressure:
        HybridAudioAnalysisPlaybackPressure = .none
    private(set) var carrierForwardBufferSeconds: Double?
    private var playbackStallLatched = false
    private var analysisPlaybackPressureSequence: UInt64 = 0
    private var lastTelemetryClockSampleSeconds: Double?
    private var lastCarrierReadyTelemetryGeneration: UInt64?
    private var lastVideoReadyTelemetryGeneration: UInt64?
    private var didEmitPlaybackCompletedTelemetry = false
    private(set) var readinessPrerollFramesRejected: UInt64 = 0

    private var latestDecodeDemand: CMTime?
    private var decodeDemandWorker: Task<Void, Never>?
    private var decodeDemandWorkerID: UInt64 = 0
    private var decodeDemandSuspended = false
    private var audioAnalysisSessions: [
        UUID: AudioAnalysisSession
    ] = [:]
    var stateDidChange:
        (@MainActor @Sendable (HybridPlaybackSessionState) -> Void)?
    var telemetryDidChange:
        (@MainActor @Sendable (HybridPlaybackTelemetryTrigger) -> Void)?
    var subtitleTracksDidChange:
        (@MainActor @Sendable (
            [AetherHybridOverlaySubtitleTrack],
            Int?
        ) -> Void)?
    var runtimePresentationValidation:
        (@MainActor () throws -> Void) = {}

    var sourceVideoFormat: VideoFormat {
        videoFormat
    }

    var sourceVideoFrameRate: Double? {
        videoFrameRate
    }

    var audioAnalysisTrackIDs: [Int] {
        audioAnalysisSource?.audioAnalysisTrackIDs ?? []
    }

    func audioAnalysisAvailability(
        for audioTrackID: Int
    ) -> AudioAnalysisTrackAvailability {
        switch state {
        case .failed, .stopped:
            return .unavailable(.noActiveSession)
        case .idle, .preparing, .ready, .seeking:
            break
        }
        guard let audioAnalysisSource else {
            return .unavailable(
                .analysisFailed(
                    "hybrid session has no independent analysis source"
                )
            )
        }
        guard audioAnalysisSource.audioAnalysisTrackIDs
                .contains(audioTrackID) else {
            return .unavailable(
                .audioTrackUnavailable(audioTrackID)
            )
        }
        return .available
    }

    var activeAudioAnalysisRequestCount: Int {
        audioAnalysisSessions.count
    }

    var overlaySubtitleTracks:
        [AetherHybridOverlaySubtitleTrack]
    {
        subtitleController?.tracks ?? []
    }

    var activeOverlaySubtitleTrackID: Int? {
        subtitleController?.selectedTrackID
    }

    var carrierBandwidthTelemetry:
        AetherHybridCarrierBandwidthTelemetry
    {
        carrierBandwidthTelemetrySource?
            .carrierBandwidthTelemetry
            ?? .unavailable(
                audioRenditionCount:
                    audioAnalysisTrackIDs.count
            )
    }

    var generation: UInt64 {
        classifier.generation
    }

    init(
        provider: any HybridCarrierTransportProvider,
        transport: any HybridCarrierPlayerTransport,
        renderSurface: any HybridPlaybackRenderSurface,
        timeline: BlackCarrierTimeline,
        initialGeneration: UInt64 = 0,
        relay: HybridPlaybackFrameRelay
    ) throws {
        guard let videoFormat = provider.hybridVideoFormat else {
            provider.close()
            throw HybridPlaybackSessionError.videoPipelineMissing
        }
        self.transport = transport
        self.renderSurface = renderSurface
        coordinator = HybridPlaybackProviderCoordinator(provider: provider)
        self.timeline = timeline
        self.videoFormat = videoFormat
        videoFrameRate = provider.hybridVideoFrameRate
        self.relay = relay
        audioAnalysisSource =
            provider as? any HybridAudioAnalysisSource
        carrierBandwidthTelemetrySource =
            provider as?
                any HybridCarrierBandwidthTelemetrySource
        if let source = provider as?
                any HybridOverlaySubtitleSource,
           let view = renderSurface as?
                AetherHybridPresentationView,
           !source.hybridSubtitleContracts.isEmpty {
            subtitleController = HybridSubtitleSessionController(
                source: source,
                presentationView: view
            )
        } else {
            subtitleController = nil
        }
        classifier = HybridSeekIntentClassifier(
            timeline: timeline,
            initialGeneration: initialGeneration
        )
        avPlayer = transport.avPlayer
        relay.attach(self)
        subtitleController?.tracksDidChange = {
            [weak self] tracks, selectedTrackID in
            self?.subtitleTracksDidChange?(
                tracks,
                selectedTrackID
            )
        }
        if let terminalErrorSource =
                provider as?
                any HybridPlaybackTerminalErrorSource {
            terminalErrorSource
                .setTerminalHybridPlaybackErrorHandler {
                    [weak self] error in
                    Task { @MainActor [weak self] in
                        self?.terminate(with: error)
                    }
                }
        }
    }

    static func makeSeekableVOD(
        source: MediaSource,
        options: LoadOptions,
        timeline: BlackCarrierTimeline,
        initialGeneration: UInt64 = 0,
        selectTitleID: Int? = nil
    ) async throws -> HybridPlaybackSession {
        let relay = HybridPlaybackFrameRelay()
        let provider = try await Task.detached {
            let videoProvider = try BlackCarrierVideoProvider(
                timeline: timeline
            )
            return try BlackCarrierLazyCompositeProvider
                .buildSeekableVOD(
                    videoProvider: videoProvider,
                    source: source,
                    options: options,
                    timeline: timeline,
                    bridgeMode: options.audioBridgeMode,
                    decodedFrameHandler: { relay.emit($0) },
                    videoFailureHandler: { relay.fail($0) },
                    initialGeneration: initialGeneration,
                    selectTitleID: selectTitleID
                )
        }.value

        do {
            let renderView = AetherHybridPresentationView()
            let transport = BlackCarrierAVPlayerSession(
                provider: provider
            )
            return try HybridPlaybackSession(
                provider: provider,
                transport: transport,
                renderSurface: renderView,
                timeline: timeline,
                initialGeneration: initialGeneration,
                relay: relay
            )
        } catch {
            provider.close()
            relay.detach()
            throw error
        }
    }

    static func makeHLSVOD(
        preflight: AetherHLSPlaybackPreflight,
        bridgeMode: AudioBridgeMode = .surroundCompat,
        initialGeneration: UInt64 = 0,
        fetchOverride:
            HLSVODOriginResourceLoader.Fetch? = nil
    ) async throws -> HybridPlaybackSession {
        guard preflight.result.route
                == .hybridCarrier else {
            throw HybridPlaybackSessionError
                .preflightRequiresHybrid(
                    route: preflight.result.route,
                    reason: preflight.result.reason
                )
        }
        guard preflight.resourceGraph != nil else {
            throw HybridPlaybackSessionError
                .hlsPreflightResourceGraphMissing
        }

        let relay = HybridPlaybackFrameRelay()
        let provider: HLSVODCarrierProvider
        do {
            provider = try await HLSVODCarrierProvider.make(
                preflight: preflight,
                bridgeMode: bridgeMode,
                decodedFrameHandler: {
                    relay.emit($0)
                },
                videoFailureHandler: {
                    relay.fail($0)
                },
                initialGeneration:
                    initialGeneration,
                fetchOverride: fetchOverride
            )
        } catch {
            relay.detach()
            if let typed =
                    HLSVODCarrierProvider
                        .hybridPlaybackSessionError(
                            from: error
                        ) {
                throw typed
            }
            throw error
        }

        do {
            let renderView = AetherHybridPresentationView()
            let transport = BlackCarrierAVPlayerSession(
                provider: provider
            )
            return try HybridPlaybackSession(
                provider: provider,
                transport: transport,
                renderSurface: renderView,
                timeline:
                    try requireHLSHybridTimeline(
                        preflight
                    ),
                initialGeneration: initialGeneration,
                relay: relay
            )
        } catch {
            provider.close()
            relay.detach()
            throw error
        }
    }

    private static func requireHLSHybridTimeline(
        _ preflight: AetherHLSPlaybackPreflight
    ) throws -> BlackCarrierTimeline {
        guard let timeline =
                preflight.hybridTimeline else {
            throw HybridPlaybackSessionError
                .providerFailed(
                    reason:
                        "HLS preflight did not retain a hybrid timeline"
                )
        }
        return timeline
    }

    func prepare(
        timeout: TimeInterval = 15,
        presentationValidation:
            @MainActor () throws -> Void = {}
    ) async throws {
        guard timeout.isFinite, timeout > 0 else {
            throw HybridPlaybackSessionError.invalidReadinessTimeout
        }
        switch state {
        case .idle:
            break
        case .preparing:
            throw HybridPlaybackSessionError.alreadyPreparing
        case .stopped:
            throw HybridPlaybackSessionError.alreadyStopped
        case .ready:
            return
        case .seeking:
            throw HybridPlaybackSessionError.alreadyPreparing
        case .failed(let error):
            throw error
        }

        let generation = classifier.generation
        let target = CMTime.zero
        guard let startupSegmentIndex =
                timeline.segmentIndex(containing: target) else {
            throw HybridPlaybackSessionError.invalidSeekTarget
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        state = .preparing(generation: generation, target: target)

        do {
            try presentationValidation()
            if let videoFrameRate {
                let criteriaResult =
                    displayCriteriaController.apply(
                    format: videoFormat,
                    frameRate: videoFrameRate,
                    codecTag: nil,
                    omitColorExtensions: false
                )
                if criteriaResult.didApply {
                    await displayCriteriaController
                        .waitForSwitch()
                }
            } else {
                EngineLog.emit(
                    "[HybridPlaybackSession] display criteria skipped: real-video refresh rate unavailable",
                    category: .session
                )
            }
            try ensureActiveGeneration(generation)
            try presentationValidation()
            try renderSurface.beginGeneration(
                generation,
                videoFormat: videoFormat
            )
            try readinessGate.beginGeneration(
                generation,
                targetTime: target
            )
            try await coordinator.prepareInitialGeneration()
            try ensureActiveGeneration(generation)
            try presentationValidation()
            try transport.startPrepared()
            try bindCarrierClock()
            installClockObservers()
            try await transport.prepare(
                timeout: try remainingTime(
                    until: deadline,
                    originalTimeout: timeout
                )
            )
            try ensureActiveGeneration(generation)
            try validateCarrierClock()
            _ = readinessGate.markCarrierReady(
                generation: generation
            )
            publishCarrierReadyTelemetry(
                generation: generation,
                target: target,
                segmentIndex: startupSegmentIndex
            )
            try await waitForPresentationReadiness(
                generation: generation,
                deadline: deadline,
                originalTimeout: timeout
            )
            let initialTime = avPlayer.currentTime()
            guard Self.isValidTimelineTime(initialTime) else {
                throw HybridPlaybackSessionError
                    .carrierClockUnavailable
            }
            try processClockTick(initialTime)
            state = .ready(generation: generation)
            telemetryDidChange?(
                .playbackStarted(
                    AetherHybridTimelineTelemetry(
                        generation: generation,
                        targetSeconds: target.seconds,
                        segmentIndex: startupSegmentIndex,
                        framePresentationTimeSeconds:
                            readyFramePresentationTimeSeconds(
                                generation: generation
                            )
                    )
                )
            )
            EngineLog.emit(
                "[HybridPlaybackSession] ready generation=\(generation)",
                category: .session
            )
        } catch {
            let typed = await mapPreparationError(error)
            terminate(with: typed)
            throw typed
        }
    }

    func play() throws {
        guard case .ready = state else {
            throw currentAvailabilityError()
        }
        try validateCarrierClock()
        avPlayer.play()
        telemetryDidChange?(.transportChanged)
        reevaluateAudioAnalysisPlaybackPressure()
    }

    func pause() throws {
        switch state {
        case .ready:
            try validateCarrierClock()
            avPlayer.pause()
        case .seeking:
            guard let pendingResumeIntent else {
                let error = HybridPlaybackSessionError
                    .resumeIntentMissing
                terminate(with: error)
                throw error
            }
            self.pendingResumeIntent = ResumeIntent(
                wasPlaying: false,
                rate: pendingResumeIntent.rate
            )
            avPlayer.pause()
        default:
            throw currentAvailabilityError()
        }
        telemetryDidChange?(.transportChanged)
        reevaluateAudioAnalysisPlaybackPressure()
    }

    func setRate(_ rate: Float) throws {
        guard rate.isFinite, rate >= 0 else {
            throw HybridPlaybackSessionError.invalidRate
        }
        guard case .ready = state else {
            throw currentAvailabilityError()
        }
        try validateCarrierClock()
        avPlayer.rate = rate
        telemetryDidChange?(.transportChanged)
        reevaluateAudioAnalysisPlaybackPressure()
    }

    func seek(
        to target: CMTime,
        timeout: TimeInterval = 15
    ) async throws -> HybridPlaybackSeekResult {
        try await performSeek(
            to: target,
            issueCarrierSeek: true,
            timeout: timeout
        )
    }

    func audioAnalysisStream(
        request: AudioAnalysisRequest
    ) throws -> AudioAnalysisStream {
        switch audioAnalysisAvailability(
            for: request.audioTrackID
        ) {
        case .available:
            break
        case .unavailable(let error):
            throw error
        }
        guard let audioAnalysisSource else {
            throw AudioAnalysisError.analysisFailed(
                "available analysis track requires an analysis source"
            )
        }
        let input: AudioAnalysisInput
        do {
            input = try audioAnalysisSource.makeAudioAnalysisInput()
        } catch BlackCarrierDemuxSourceFactoryError
                    .independentReaderUnavailable {
            throw AudioAnalysisError
                .sourceCannotCreateIndependentReader
        } catch {
            throw AudioAnalysisError.analysisFailed(
                String(describing: error)
            )
        }

        let session = AudioAnalysisSession(
            request: request
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleAudioAnalysisTelemetry(event)
            }
        }
        let stream = AudioAnalysisStream(
            gate: session.gate,
            cancel: { session.cancel() }
        )
        audioAnalysisSessions[session.id] = session
        session.setPlaybackPressureForTelemetry(
            audioAnalysisPlaybackPressure
        )
        session.emitTelemetryStarted()
        let sessionID = session.id
        let task = Task.detached(priority: .utility) {
            [weak self] in
            await AudioAnalysisRunner.run(
                session: session,
                input: input,
                request: request
            )
            await self?.removeAudioAnalysisSession(
                id: sessionID
            )
        }
        session.install(task: task)
        return stream
    }

    func cancelAudioAnalysisStreams() {
        let sessions = Array(audioAnalysisSessions.values)
        audioAnalysisSessions.removeAll()
        for session in sessions {
            session.cancel()
        }
    }

    func selectOverlaySubtitleTrack(_ trackID: Int?) throws {
        guard let subtitleController else {
            if let trackID {
                throw AetherHybridSubtitleSelectionError
                    .unknownTrack(trackID)
            }
            return
        }
        try subtitleController.select(trackID: trackID)
    }

    func stop() {
        guard state != .stopped else { return }
        state = .stopped
        teardownObservers()
        cancelDecodeDemandWorker()
        externalJumpTask?.cancel()
        externalJumpTask = nil
        managedSeekGeneration = nil
        managedTimeJumpSuppressionTarget = nil
        managedTimeJumpSuppressionDeadline = nil
        pendingResumeIntent = nil
        cancelAudioAnalysisStreams()
        subtitleController?.stop()
        relay.detach()
        avPlayer.pause()
        renderSurface.invalidate()
        transport.stop()
        displayCriteriaController.reset()
        EngineLog.emit(
            "[HybridPlaybackSession] stopped",
            category: .session
        )
    }

    private func removeAudioAnalysisSession(id: UUID) {
        audioAnalysisSessions.removeValue(forKey: id)
    }

    private func handleAudioAnalysisTelemetry(
        _ event: AetherHybridAudioAnalysisTelemetry
    ) {
        switch event.phase {
        case .completed, .failed:
            audioAnalysisSessions.removeValue(
                forKey: event.analysisID
            )
        case .started, .progress:
            break
        }
        telemetryDidChange?(.audioAnalysis(event))
    }

    func receiveDecodedFrame(_ frame: DecodedVideoFrame) {
        switch state {
        case .failed, .stopped:
            return
        case .idle, .preparing, .ready, .seeking:
            break
        }
        let outcome = readinessGate.considerDecodedFrame(frame)
        switch outcome {
        case .staleGeneration, .terminalFailure:
            return
        case .frameOutsideTargetWindow:
            readinessPrerollFramesRejected += 1
            return
        case .acceptedWaiting, .becameReady, .alreadyReady:
            break
        }
        do {
            _ = try renderSurface.enqueue(frame)
        } catch let error as AetherHybridPresentationError {
            terminate(with: .presentationFailed(error))
            return
        } catch {
            terminate(with: .readinessFailed(
                reason: String(describing: error)
            ))
            return
        }
        guard outcome == .acceptedWaiting
                || outcome == .becameReady else {
            return
        }
        publishVideoReadyTelemetryIfNeeded(frame)
    }

    func receiveDecoderFailure(
        _ error: HybridVideoDecodeSinkError
    ) {
        let generation = classifier.generation
        _ = readinessGate.failDecoder(
            generation: generation,
            reason: error.localizedDescription
        )
        terminate(with: .decoderFailed(
            reason: error.localizedDescription
        ))
    }

    func handleClockTick(_ time: CMTime) {
        switch state {
        case .preparing, .ready, .seeking:
            break
        case .idle, .failed, .stopped:
            return
        }
        do {
            try processClockTick(time)
        } catch let error as HybridPlaybackSessionError {
            terminate(with: error)
        } catch {
            terminate(with: .readinessFailed(
                reason: String(describing: error)
            ))
        }
    }

    private func processClockTick(_ time: CMTime) throws {
        guard Self.isValidTimelineTime(time) else {
            throw HybridPlaybackSessionError
                .carrierClockUnavailable
        }
        try validateCarrierClock()
        lastObservedPlayerTime = time
        subtitleController?.update(
            playheadSeconds: time.seconds
        )
        reevaluateAudioAnalysisPlaybackPressure()
        let requested = CMTimeMinimum(
            timeline.duration,
            CMTimeAdd(time, Self.decodeLookahead)
        )
        submitDecodeDemand(requested)
        publishPeriodicTelemetryIfNeeded(time)
    }

    private func performSeek(
        to target: CMTime,
        issueCarrierSeek: Bool,
        timeout: TimeInterval
    ) async throws -> HybridPlaybackSeekResult {
        guard timeout.isFinite, timeout > 0 else {
            throw HybridPlaybackSessionError.invalidReadinessTimeout
        }
        guard timeline.segmentIndex(containing: target) != nil else {
            throw HybridPlaybackSessionError.invalidSeekTarget
        }
        switch state {
        case .ready, .seeking:
            break
        case .stopped:
            throw HybridPlaybackSessionError.alreadyStopped
        case .failed(let error):
            throw error
        case .idle, .preparing:
            throw HybridPlaybackSessionError.notReady
        }
        try validateCarrierClock()

        let intent = try issueCarrierSeek
            ? classifier.registerExplicitHostSeek(to: target)
            : classifier.registerPlayerTimeJump(to: target)
        guard case .userSeek(
            _,
            let segmentIndex,
            let generation
        ) = intent else {
            throw HybridPlaybackSessionError.invalidSeekTarget
        }
        readinessPrerollFramesRejected = 0

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let resumeIntent: ResumeIntent
        if let pendingResumeIntent {
            resumeIntent = pendingResumeIntent
        } else {
            resumeIntent = try captureResumeIntent()
        }
        pendingResumeIntent = resumeIntent
        managedSeekGeneration = generation
        decodeDemandSuspended = true
        cancelDecodeDemandWorker()
        avPlayer.pause()
        state = .seeking(generation: generation, target: target)
        telemetryDidChange?(
            .seekRequested(
                AetherHybridTimelineTelemetry(
                    generation: generation,
                    targetSeconds: target.seconds,
                    segmentIndex: segmentIndex
                )
            )
        )

        do {
            try renderSurface.beginGeneration(
                generation,
                videoFormat: videoFormat
            )
            subtitleController?.resetForGeneration()
            try readinessGate.beginGeneration(
                generation,
                targetTime: target,
                carrierAlreadyReady: !issueCarrierSeek
            )
            if !issueCarrierSeek {
                publishCarrierReadyTelemetry(
                    generation: generation,
                    target: target,
                    segmentIndex: segmentIndex
                )
            }
            let restart = try await coordinator.restart(for: intent)
            switch restart {
            case .applied:
                break
            case .stale(let currentGeneration):
                guard classifier.generation != generation else {
                    throw HybridPlaybackSessionError
                        .generationDiverged(
                            sessionGeneration: generation,
                            providerGeneration: currentGeneration
                        )
                }
                return supersededResult(
                    currentGeneration: currentGeneration
                )
            }
            guard generation == classifier.generation else {
                return supersededResult(
                    currentGeneration: classifier.generation
                )
            }

            try await coordinator.prepareGeneration(
                segmentIndex: segmentIndex
            )
            guard generation == classifier.generation else {
                return supersededResult(
                    currentGeneration: classifier.generation
                )
            }

            if issueCarrierSeek {
                managedTimeJumpSuppressionTarget = target
                managedTimeJumpSuppressionDeadline =
                    ProcessInfo.processInfo.systemUptime + 2
                let landed = await transport.seek(to: target)
                guard generation == classifier.generation else {
                    return supersededResult(
                        currentGeneration: classifier.generation
                    )
                }
                guard landed else {
                    throw HybridPlaybackSessionError
                        .carrierSeekDidNotLand
                }
                try validateCarrierClock()
                _ = readinessGate.markCarrierReady(
                    generation: generation
                )
                publishCarrierReadyTelemetry(
                    generation: generation,
                    target: target,
                    segmentIndex: segmentIndex
                )
            }

            try await waitForPresentationReadiness(
                generation: generation,
                deadline: deadline,
                originalTimeout: timeout
            )
            guard generation == classifier.generation else {
                return supersededResult(
                    currentGeneration: classifier.generation
                )
            }
            managedSeekGeneration = nil
            decodeDemandSuspended = false
            pendingResumeIntent = nil
            let landedTime = avPlayer.currentTime()
            guard Self.isValidTimelineTime(landedTime) else {
                throw HybridPlaybackSessionError
                    .carrierClockUnavailable
            }
            try processClockTick(landedTime)
            restoreResumeIntent(resumeIntent)
            state = .ready(generation: generation)
            EngineLog.emit(
                "[HybridPlaybackSession] seek ready generation=\(generation) "
                    + "target=\(target.seconds)",
                category: .session
            )
            return .applied(generation: generation, target: target)
        } catch {
            if generation != classifier.generation {
                return supersededResult(
                    currentGeneration: classifier.generation
                )
            }
            let typed = await mapSeekError(error)
            terminate(with: typed)
            throw typed
        }
    }

    private func installClockObservers() {
        teardownObservers()
        periodicTimeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: Self.clockInterval,
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.handleClockTick(time)
            }
        }
        if let item = avPlayer.currentItem {
            let observer = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.timeJumpedNotification,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleObservedPlayerTimeJump()
                }
            }
            notificationObservers.append(observer)

            playerObservations.append(
                item.observe(
                    \.isPlaybackBufferEmpty,
                    options: [.initial, .new]
                ) { [weak self] _, _ in
                    Task { @MainActor [weak self] in
                        self?.reevaluateAudioAnalysisPlaybackPressure()
                    }
                }
            )
            playerObservations.append(
                item.observe(
                    \.isPlaybackLikelyToKeepUp,
                    options: [.initial, .new]
                ) { [weak self] _, _ in
                    Task { @MainActor [weak self] in
                        self?.reevaluateAudioAnalysisPlaybackPressure()
                    }
                }
            )
            playerObservations.append(
                item.observe(
                    \.loadedTimeRanges,
                    options: [.initial, .new]
                ) { [weak self] _, _ in
                    Task { @MainActor [weak self] in
                        self?.reevaluateAudioAnalysisPlaybackPressure()
                    }
                }
            )
            let stalledObserver =
                NotificationCenter.default.addObserver(
                    forName:
                        AVPlayerItem.playbackStalledNotification,
                    object: item,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.handleCarrierStall()
                    }
                }
            notificationObservers.append(stalledObserver)
            let endedObserver =
                NotificationCenter.default.addObserver(
                    forName:
                        AVPlayerItem.didPlayToEndTimeNotification,
                    object: item,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self,
                              !self
                                .didEmitPlaybackCompletedTelemetry else {
                            return
                        }
                        self.didEmitPlaybackCompletedTelemetry = true
                        self.telemetryDidChange?(
                            .sessionEnded(
                                .playbackCompleted
                            )
                        )
                    }
                }
            notificationObservers.append(endedObserver)
            let mediaSelectionObserver =
                NotificationCenter.default.addObserver(
                    forName:
                        AVPlayerItem
                            .mediaSelectionDidChangeNotification,
                    object: item,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?
                            .handleCarrierMediaSelectionChange()
                    }
                }
            notificationObservers.append(
                mediaSelectionObserver
            )
        }
        playerObservations.append(
            avPlayer.observe(
                \.timeControlStatus,
                options: [.initial, .new]
            ) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.reevaluateAudioAnalysisPlaybackPressure()
                }
            }
        )
        reevaluateAudioAnalysisPlaybackPressure()
    }

    private func handleObservedPlayerTimeJump() {
        let target = avPlayer.currentTime()
        if let suppressedTarget = managedTimeJumpSuppressionTarget,
           let suppressionDeadline =
                managedTimeJumpSuppressionDeadline {
            let now = ProcessInfo.processInfo.systemUptime
            if Self.shouldSuppressObservedTimeJump(
                observed: target,
                managedTarget: suppressedTarget,
                suppressionDeadline: suppressionDeadline,
                now: now
            ) {
                managedTimeJumpSuppressionTarget = nil
                managedTimeJumpSuppressionDeadline = nil
                return
            }
            if now > suppressionDeadline {
                managedTimeJumpSuppressionTarget = nil
                managedTimeJumpSuppressionDeadline = nil
            }
        }
        guard managedSeekGeneration == nil,
              case .ready = state else {
            return
        }
        guard Self.isValidTimelineTime(target),
              let previous = lastObservedPlayerTime,
              Self.isValidTimelineTime(previous),
              abs(target.seconds - previous.seconds)
                >= Self.observedJumpThresholdSeconds else {
            return
        }
        externalJumpTask?.cancel()
        externalJumpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.externalJumpTask = nil }
            do {
                _ = try await self.performSeek(
                    to: target,
                    issueCarrierSeek: false,
                    timeout: 15
                )
            } catch let error as HybridPlaybackSessionError {
                if error != .cancelled {
                    self.terminate(with: error)
                }
            } catch {
                self.terminate(with: .providerFailed(
                    reason: String(describing: error)
                ))
            }
        }
    }

    func handleCarrierStall() {
        playbackStallLatched = true
        reevaluateAudioAnalysisPlaybackPressure(
            allowClearingStall: false
        )
        rebuildPresentationAtCarrierTime()
    }

    func handleCarrierMediaSelectionChange() {
        rebuildPresentationAtCarrierTime()
    }

    private func rebuildPresentationAtCarrierTime() {
        guard externalJumpTask == nil,
              managedSeekGeneration == nil,
              case .ready = state else {
            return
        }
        let target = avPlayer.currentTime()
        guard Self.isValidTimelineTime(target) else {
            terminate(with: .carrierClockUnavailable)
            return
        }
        externalJumpTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.externalJumpTask = nil }
            do {
                _ = try await self.performSeek(
                    to: target,
                    issueCarrierSeek: false,
                    timeout: 15
                )
            } catch let error as HybridPlaybackSessionError {
                if error != .cancelled {
                    self.terminate(with: error)
                }
            } catch {
                self.terminate(with: .providerFailed(
                    reason: String(describing: error)
                ))
            }
        }
    }

    func applyAudioAnalysisPlaybackPressure(
        _ pressure: HybridAudioAnalysisPlaybackPressure,
        forwardBufferSeconds: Double?
    ) {
        carrierForwardBufferSeconds = forwardBufferSeconds
        guard pressure != audioAnalysisPlaybackPressure else {
            return
        }
        audioAnalysisPlaybackPressure = pressure
        analysisPlaybackPressureSequence &+= 1
        telemetryDidChange?(.playbackPressureChanged)
        for session in audioAnalysisSessions.values {
            session.setPlaybackPressureForTelemetry(pressure)
        }
        let sequence = analysisPlaybackPressureSequence
        let coordinator = coordinator
        Task {
            await coordinator.setAudioAnalysisPlaybackPressure(
                pressure,
                sequence: sequence
            )
        }
        EngineLog.emit(
            "[HybridPlaybackSession] audio-analysis playback pressure=\(pressure.rawValue) "
                + "forwardBufferSeconds="
                + (
                    forwardBufferSeconds.map {
                        String(format: "%.3f", $0)
                    } ?? "unknown"
                ),
            category: .session
        )
    }

    private func reevaluateAudioAnalysisPlaybackPressure(
        allowClearingStall: Bool = true
    ) {
        let item = avPlayer.currentItem
        let forwardBufferSeconds = Self.forwardBufferSeconds(
            player: avPlayer,
            item: item
        )
        let recoveredForwardBuffer: Bool
        if let forwardBufferSeconds {
            recoveredForwardBuffer =
                forwardBufferSeconds
                >= Self
                    .analysisForwardBufferPressureThresholdSeconds
        } else {
            recoveredForwardBuffer = true
        }
        if allowClearingStall,
           avPlayer.timeControlStatus == .playing,
           item?.isPlaybackLikelyToKeepUp == true,
           item?.isPlaybackBufferEmpty == false,
           recoveredForwardBuffer {
            playbackStallLatched = false
        }
        let isPlaybackBufferEmpty: Bool
        let isPlaybackLikelyToKeepUp: Bool
        if let item {
            isPlaybackBufferEmpty =
                item.isPlaybackBufferEmpty
            isPlaybackLikelyToKeepUp =
                item.isPlaybackLikelyToKeepUp
        } else {
            isPlaybackBufferEmpty = true
            isPlaybackLikelyToKeepUp = false
        }
        let pressure = Self.resolveAudioAnalysisPlaybackPressure(
            state: state,
            timeControlStatus: avPlayer.timeControlStatus,
            rate: avPlayer.rate,
            playbackStalled: playbackStallLatched,
            isPlaybackBufferEmpty:
                isPlaybackBufferEmpty,
            isPlaybackLikelyToKeepUp:
                isPlaybackLikelyToKeepUp,
            forwardBufferSeconds: forwardBufferSeconds
        )
        applyAudioAnalysisPlaybackPressure(
            pressure,
            forwardBufferSeconds: forwardBufferSeconds
        )
    }

    private func publishCarrierReadyTelemetry(
        generation: UInt64,
        target: CMTime,
        segmentIndex: Int
    ) {
        guard lastCarrierReadyTelemetryGeneration
                != generation else {
            return
        }
        lastCarrierReadyTelemetryGeneration = generation
        telemetryDidChange?(
            .carrierReady(
                AetherHybridTimelineTelemetry(
                    generation: generation,
                    targetSeconds: target.seconds,
                    segmentIndex: segmentIndex
                )
            )
        )
    }

    private func publishVideoReadyTelemetryIfNeeded(
        _ frame: DecodedVideoFrame
    ) {
        guard lastVideoReadyTelemetryGeneration
                != frame.generation else {
            return
        }
        let target: CMTime
        let isSeek: Bool
        switch state {
        case .preparing(let generation, let candidate)
            where generation == frame.generation:
            target = candidate
            isSeek = false
        case .seeking(let generation, let candidate)
            where generation == frame.generation:
            target = candidate
            isSeek = true
        default:
            return
        }
        guard Self.isValidTimelineTime(target),
              let segmentIndex =
                timeline.segmentIndex(containing: target) else {
            terminate(with: .invalidSeekTarget)
            return
        }
        lastVideoReadyTelemetryGeneration = frame.generation
        let point = AetherHybridTimelineTelemetry(
            generation: frame.generation,
            targetSeconds: target.seconds,
            segmentIndex: segmentIndex,
            framePresentationTimeSeconds:
                frame.presentationTime.seconds
        )
        telemetryDidChange?(.videoFirstFrameReady(point))
        if isSeek {
            telemetryDidChange?(.seekVideoReady(point))
        }
    }

    private func readyFramePresentationTimeSeconds(
        generation: UInt64
    ) -> Double? {
        guard case .ready(
            let readyGeneration,
            let framePresentationTime
        ) = readinessGate.state,
              readyGeneration == generation,
              Self.isValidTimelineTime(
                framePresentationTime
              ) else {
            return nil
        }
        return framePresentationTime.seconds
    }

    private func publishPeriodicTelemetryIfNeeded(
        _ time: CMTime
    ) {
        guard Self.isValidTimelineTime(time) else { return }
        let seconds = time.seconds
        if let last = lastTelemetryClockSampleSeconds,
           seconds >= last,
           seconds - last
                < Self.telemetrySampleIntervalSeconds {
            return
        }
        lastTelemetryClockSampleSeconds = seconds
        telemetryDidChange?(
            .periodicSample(
                playerTimeSeconds: seconds
            )
        )
    }

    static func resolveAudioAnalysisPlaybackPressure(
        state: HybridPlaybackSessionState,
        timeControlStatus: AVPlayer.TimeControlStatus,
        rate: Float,
        playbackStalled: Bool,
        isPlaybackBufferEmpty: Bool,
        isPlaybackLikelyToKeepUp: Bool,
        forwardBufferSeconds: Double?
    ) -> HybridAudioAnalysisPlaybackPressure {
        switch state {
        case .preparing, .seeking:
            return .carrierPreparingOrSeeking
        case .idle, .failed, .stopped:
            return .none
        case .ready:
            break
        }

        let hasPlaybackIntent =
            timeControlStatus != .paused || rate > 0
        guard hasPlaybackIntent else {
            return .none
        }
        if playbackStalled {
            return .carrierPlaybackStalled
        }
        if timeControlStatus == .waitingToPlayAtSpecifiedRate {
            return .carrierWaitingToPlay
        }
        if isPlaybackBufferEmpty {
            return .carrierBufferEmpty
        }
        if let forwardBufferSeconds,
           forwardBufferSeconds
                < analysisForwardBufferPressureThresholdSeconds {
            return .carrierForwardBufferLow
        }
        if !isPlaybackLikelyToKeepUp {
            return .carrierNotLikelyToKeepUp
        }
        return .none
    }

    static func forwardBufferSeconds(
        player: AVPlayer,
        item: AVPlayerItem?
    ) -> Double? {
        guard let item else { return nil }
        return forwardBufferSeconds(
            currentTime: player.currentTime(),
            loadedTimeRanges:
                item.loadedTimeRanges.map(\.timeRangeValue)
        )
    }

    nonisolated static func forwardBufferSeconds(
        currentTime: CMTime,
        loadedTimeRanges: [CMTimeRange]
    ) -> Double? {
        let current = currentTime.seconds
        guard current.isFinite else { return nil }
        let ranges = loadedTimeRanges
            .sorted {
                $0.start.seconds < $1.start.seconds
            }
        var continuousEnd: Double?
        for range in ranges {
            let start = range.start.seconds
            let end = CMTimeRangeGetEnd(range).seconds
            guard start.isFinite,
                  end.isFinite,
                  end >= start else {
                continue
            }
            if let existingEnd = continuousEnd {
                guard start <= existingEnd else {
                    break
                }
                continuousEnd = max(existingEnd, end)
                continue
            }
            guard current >= start else {
                return 0
            }
            if current <= end {
                continuousEnd = end
            }
        }
        if let continuousEnd {
            return max(0, continuousEnd - current)
        }
        return ranges.isEmpty ? nil : 0
    }

    private func teardownObservers() {
        if let periodicTimeObserver {
            avPlayer.removeTimeObserver(periodicTimeObserver)
            self.periodicTimeObserver = nil
        }
        for observation in playerObservations {
            observation.invalidate()
        }
        playerObservations.removeAll()
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }

    private func submitDecodeDemand(_ demand: CMTime) {
        guard !decodeDemandSuspended,
              Self.isValidTimelineTime(demand) else {
            return
        }
        if let current = latestDecodeDemand,
           CMTimeCompare(current, demand) >= 0 {
            return
        }
        latestDecodeDemand = demand
        guard decodeDemandWorker == nil else { return }

        decodeDemandWorkerID &+= 1
        let workerID = decodeDemandWorkerID
        decodeDemandWorker = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let demand = self.takeLatestDecodeDemand()
                else {
                    break
                }
                do {
                    try await self.coordinator.advanceDecodeDemand(
                        to: demand
                    )
                } catch {
                    if !Task.isCancelled {
                        self.terminate(
                            with: await self
                                .mapProviderError(error)
                        )
                    }
                    break
                }
            }
            if self.decodeDemandWorkerID == workerID {
                self.decodeDemandWorker = nil
            }
        }
    }

    private func takeLatestDecodeDemand() -> CMTime? {
        defer { latestDecodeDemand = nil }
        return latestDecodeDemand
    }

    private func cancelDecodeDemandWorker() {
        decodeDemandWorkerID &+= 1
        decodeDemandWorker?.cancel()
        decodeDemandWorker = nil
        latestDecodeDemand = nil
    }

    private func waitForPresentationReadiness(
        generation: UInt64,
        deadline: TimeInterval,
        originalTimeout: TimeInterval
    ) async throws {
        while ProcessInfo.processInfo.systemUptime < deadline {
            try ensureActiveGeneration(generation)
            switch readinessGate.state {
            case .ready(let readyGeneration, _)
                where readyGeneration == generation:
                return
            case .failed(let failedGeneration, let error)
                where failedGeneration == generation:
                throw HybridPlaybackSessionError.readinessFailed(
                    reason: error.localizedDescription
                )
            default:
                break
            }
            if Task.isCancelled {
                throw HybridPlaybackSessionError.cancelled
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw HybridPlaybackSessionError.readinessTimedOut(
            seconds: originalTimeout
        )
    }

    private func remainingTime(
        until deadline: TimeInterval,
        originalTimeout: TimeInterval
    ) throws -> TimeInterval {
        let remaining =
            deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else {
            throw HybridPlaybackSessionError.readinessTimedOut(
                seconds: originalTimeout
            )
        }
        return remaining
    }

    private func ensureActiveGeneration(
        _ generation: UInt64
    ) throws {
        if Task.isCancelled {
            throw HybridPlaybackSessionError.cancelled
        }
        guard generation == classifier.generation else {
            throw BlackCarrierMediaFanoutPumpError
                .generationSuperseded(generation: generation)
        }
        if case .failed(let error) = state {
            throw error
        }
        if state == .stopped {
            throw HybridPlaybackSessionError.alreadyStopped
        }
    }

    private func captureResumeIntent() throws -> ResumeIntent {
        let wasPlaying =
            avPlayer.timeControlStatus != .paused
                || avPlayer.rate != 0
        let rate = avPlayer.rate > 0
            ? avPlayer.rate
            : avPlayer.defaultRate
        guard rate.isFinite, rate > 0 else {
            throw HybridPlaybackSessionError.invalidRate
        }
        return ResumeIntent(wasPlaying: wasPlaying, rate: rate)
    }

    private func restoreResumeIntent(_ intent: ResumeIntent) {
        guard intent.wasPlaying else { return }
        avPlayer.play()
        if intent.rate != 1 {
            avPlayer.rate = intent.rate
        }
    }

    private func supersededResult(
        currentGeneration: UInt64
    ) -> HybridPlaybackSeekResult {
        if managedSeekGeneration != classifier.generation {
            managedSeekGeneration = nil
        }
        return .superseded(currentGeneration: currentGeneration)
    }

    private func bindCarrierClock() throws {
        guard let item = avPlayer.currentItem else {
            throw HybridPlaybackSessionError.carrierItemMissing
        }
        guard let timebase = item.timebase else {
            throw HybridPlaybackSessionError.presentationFailed(
                .carrierTimebaseUnavailable
            )
        }
        do {
            try renderSurface.bindCarrierClock(
                item: item,
                timebase: timebase
            )
        } catch let error as AetherHybridPresentationError {
            throw HybridPlaybackSessionError
                .presentationFailed(error)
        }
    }

    private func validateCarrierClock() throws {
        try runtimePresentationValidation()
        guard let item = avPlayer.currentItem else {
            throw HybridPlaybackSessionError.carrierItemMissing
        }
        guard let timebase = item.timebase else {
            throw HybridPlaybackSessionError.presentationFailed(
                .carrierTimebaseUnavailable
            )
        }
        do {
            try renderSurface.validateCarrierClock(
                item: item,
                timebase: timebase
            )
        } catch let error as AetherHybridPresentationError {
            throw HybridPlaybackSessionError
                .presentationFailed(error)
        }
    }

    private func terminate(
        with error: HybridPlaybackSessionError
    ) {
        switch state {
        case .failed, .stopped:
            return
        default:
            break
        }
        state = .failed(error)
        teardownObservers()
        cancelDecodeDemandWorker()
        externalJumpTask?.cancel()
        externalJumpTask = nil
        managedSeekGeneration = nil
        managedTimeJumpSuppressionTarget = nil
        managedTimeJumpSuppressionDeadline = nil
        pendingResumeIntent = nil
        decodeDemandSuspended = true
        cancelAudioAnalysisStreams()
        subtitleController?.stop()
        relay.detach()
        avPlayer.pause()
        renderSurface.invalidate()
        transport.stop()
        displayCriteriaController.reset()
        EngineLog.emit(
            "[HybridPlaybackSession] terminal error: "
                + error.localizedDescription,
            category: .session
        )
    }

    private func currentAvailabilityError()
        -> HybridPlaybackSessionError
    {
        switch state {
        case .failed(let error):
            return error
        case .stopped:
            return .alreadyStopped
        default:
            return .notReady
        }
    }

    private func mapPreparationError(
        _ error: Error
    ) async -> HybridPlaybackSessionError {
        if let typed = error as? HybridPlaybackSessionError {
            return typed
        }
        if let typed =
                HLSVODCarrierProvider
                    .hybridPlaybackSessionError(
                        from: error
                    ) {
            return typed
        }
        if let typed = await coordinator
            .terminalHybridPlaybackError() {
            return typed
        }
        if let presentation =
                error as? AetherHybridPresentationError {
            return .presentationFailed(presentation)
        }
        if error is BlackCarrierAVPlayerSessionError {
            return .carrierFailed(reason: String(describing: error))
        }
        return .providerFailed(reason: String(describing: error))
    }

    private func mapSeekError(
        _ error: Error
    ) async -> HybridPlaybackSessionError {
        if let typed = error as? HybridPlaybackSessionError {
            return typed
        }
        if let typed =
                HLSVODCarrierProvider
                    .hybridPlaybackSessionError(
                        from: error
                    ) {
            return typed
        }
        if let typed = await coordinator
            .terminalHybridPlaybackError() {
            return typed
        }
        if let presentation =
                error as? AetherHybridPresentationError {
            return .presentationFailed(presentation)
        }
        return .providerFailed(reason: String(describing: error))
    }

    private func mapProviderError(
        _ error: Error
    ) async -> HybridPlaybackSessionError {
        if let typed = error as? HybridPlaybackSessionError {
            return typed
        }
        if let typed =
                HLSVODCarrierProvider
                    .hybridPlaybackSessionError(
                        from: error
                    ) {
            return typed
        }
        if let typed = await coordinator
            .terminalHybridPlaybackError() {
            return typed
        }
        return .providerFailed(
            reason: String(describing: error)
        )
    }

    nonisolated private static func isValidTimelineTime(
        _ time: CMTime
    ) -> Bool {
        time.isValid
            && time.isNumeric
            && CMTimeCompare(time, .zero) >= 0
    }

    nonisolated static func shouldSuppressObservedTimeJump(
        observed: CMTime,
        managedTarget: CMTime,
        suppressionDeadline: TimeInterval,
        now: TimeInterval
    ) -> Bool {
        now <= suppressionDeadline
            && isValidTimelineTime(observed)
            && isValidTimelineTime(managedTarget)
            && abs(observed.seconds - managedTarget.seconds)
                < observedJumpThresholdSeconds
    }
}
