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
    case resumeIntentMissing
    case hlsPreflightGenerationInvalidated(
        AetherHLSPreflightInvalidationReason
    )
    case providerFailed(reason: String)
    case carrierFailed(reason: String)
    case rendererFailed(AetherMetalRendererError)
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
            return "Hybrid playback did not create its engine-owned Metal render surface"
        case .invalidSeekableVODOptions:
            return "Hybrid playback requires non-live, video-bearing, seekable VOD load options"
        case .sourceIndependentReaderUnavailable:
            return "Hybrid playback source cannot create the independent readers required by its session"
        case .sourceKindMismatch(let expected):
            return "Hybrid playback source does not match preflight source kind \(expected.rawValue)"
        case .timelineSourceMismatch(
            let sourceKind,
            let timelineSource
        ):
            return "Hybrid playback \(sourceKind.rawValue) source cannot use "
                + "\(String(describing: timelineSource)) carrier timing"
        case .preflightRequiresHybrid(let route, let reason):
            return "Hybrid session creation requires .hybridCarrierMetal, received "
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
        case .resumeIntentMissing:
            return "Hybrid seek lost its required transport resume intent"
        case .hlsPreflightGenerationInvalidated:
            return "Hybrid HLS preflight generation is no longer valid; run a new preflight before creating another session"
        case .providerFailed(let reason):
            return "Hybrid carrier provider failed: \(reason)"
        case .carrierFailed(let reason):
            return "Hybrid AVPlayer carrier failed: \(reason)"
        case .rendererFailed(let error):
            return "Hybrid Metal renderer failed: \(error.localizedDescription)"
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
    case periodicSample
    case playbackPressureChanged
    case audioAnalysisChanged
}

protocol HybridCarrierTransportProvider:
    BlackCarrierTransportProvider,
    Sendable
{
    var hybridVideoFormat: VideoFormat? { get }

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
    func advanceMasterClock(to time: CMTime, tolerance: CMTime)
    func flush()
}

extension AetherMetalPlayerView: HybridPlaybackRenderSurface {}

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

/// Engine-owned composition of AVPlayer carrier transport, real-video decode demand and Metal timing.
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
    private static let presentationTolerance = CMTime(
        value: 1,
        timescale: 120
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

    var metalPlayerView: AetherMetalPlayerView? {
        renderSurface as? AetherMetalPlayerView
    }

    private let transport: any HybridCarrierPlayerTransport
    private let renderSurface: any HybridPlaybackRenderSurface
    private let coordinator: HybridPlaybackProviderCoordinator
    private let timeline: BlackCarrierTimeline
    private let videoFormat: VideoFormat
    private let relay: HybridPlaybackFrameRelay
    private let audioAnalysisSource:
        (any HybridAudioAnalysisSource)?

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

    var sourceVideoFormat: VideoFormat {
        videoFormat
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
        self.relay = relay
        audioAnalysisSource =
            provider as? any HybridAudioAnalysisSource
        classifier = HybridSeekIntentClassifier(
            timeline: timeline,
            initialGeneration: initialGeneration
        )
        avPlayer = transport.avPlayer
        relay.attach(self)
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
            let renderView = try AetherMetalPlayerView()
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
        bandwidthAdmissions:
            [BlackCarrierAudioBandwidthAdmission],
        bridgeMode: AudioBridgeMode = .surroundCompat,
        initialGeneration: UInt64 = 0,
        fetchOverride:
            HLSVODOriginResourceLoader.Fetch? = nil
    ) async throws -> HybridPlaybackSession {
        guard preflight.result.route
                == .hybridCarrierMetal,
              preflight.resourceGraph != nil else {
            throw HybridPlaybackSessionError
                .preflightRequiresHybrid(
                    route: preflight.result.route,
                    reason: preflight.result.reason
                )
        }

        let relay = HybridPlaybackFrameRelay()
        let provider: HLSVODCarrierProvider
        do {
            provider = try await HLSVODCarrierProvider.make(
                preflight: preflight,
                bandwidthAdmissions:
                    bandwidthAdmissions,
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
            let renderView = try AetherMetalPlayerView()
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

    func prepare(timeout: TimeInterval = 15) async throws {
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
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        state = .preparing(generation: generation, target: target)

        do {
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
            try transport.startPrepared()
            guard avPlayer.currentItem != nil else {
                throw HybridPlaybackSessionError.carrierItemMissing
            }
            installClockObservers()
            try await transport.prepare(
                timeout: try remainingTime(
                    until: deadline,
                    originalTimeout: timeout
                )
            )
            try ensureActiveGeneration(generation)
            _ = readinessGate.markCarrierReady(
                generation: generation
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
            state = .ready(generation: generation)
            handleClockTick(initialTime)
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
        avPlayer.play()
        telemetryDidChange?(.transportChanged)
        reevaluateAudioAnalysisPlaybackPressure()
    }

    func pause() throws {
        switch state {
        case .ready:
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

        let session = AudioAnalysisSession()
        let stream = AudioAnalysisStream(
            gate: session.gate,
            cancel: { session.cancel() }
        )
        audioAnalysisSessions[session.id] = session
        telemetryDidChange?(.audioAnalysisChanged)
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
        let hadSessions = !audioAnalysisSessions.isEmpty
        let sessions = Array(audioAnalysisSessions.values)
        audioAnalysisSessions.removeAll()
        for session in sessions {
            session.cancel()
        }
        if hadSessions {
            telemetryDidChange?(.audioAnalysisChanged)
        }
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
        relay.detach()
        avPlayer.pause()
        renderSurface.flush()
        transport.stop()
        EngineLog.emit(
            "[HybridPlaybackSession] stopped",
            category: .session
        )
    }

    private func removeAudioAnalysisSession(id: UUID) {
        guard audioAnalysisSessions.removeValue(
            forKey: id
        ) != nil else {
            return
        }
        telemetryDidChange?(.audioAnalysisChanged)
    }

    func receiveDecodedFrame(_ frame: DecodedVideoFrame) {
        switch state {
        case .failed, .stopped:
            return
        case .idle, .preparing, .ready, .seeking:
            break
        }
        do {
            _ = try renderSurface.enqueue(frame)
        } catch let error as AetherMetalRendererError {
            terminate(with: .rendererFailed(error))
            return
        } catch {
            terminate(with: .readinessFailed(
                reason: String(describing: error)
            ))
            return
        }
        _ = readinessGate.considerDecodedFrame(frame)
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
        guard Self.isValidTimelineTime(time) else { return }
        switch state {
        case .preparing, .ready, .seeking:
            break
        case .idle, .failed, .stopped:
            return
        }
        lastObservedPlayerTime = time
        reevaluateAudioAnalysisPlaybackPressure()
        renderSurface.advanceMasterClock(
            to: time,
            tolerance: Self.presentationTolerance
        )
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

        do {
            try renderSurface.beginGeneration(
                generation,
                videoFormat: videoFormat
            )
            try readinessGate.beginGeneration(
                generation,
                targetTime: target,
                carrierAlreadyReady: !issueCarrierSeek
            )
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
                _ = readinessGate.markCarrierReady(
                    generation: generation
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
            handleClockTick(landedTime)
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
                        guard let self else { return }
                        self.playbackStallLatched = true
                        self.reevaluateAudioAnalysisPlaybackPressure(
                            allowClearingStall: false
                        )
                    }
                }
            notificationObservers.append(stalledObserver)
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
        telemetryDidChange?(.periodicSample)
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
        relay.detach()
        avPlayer.pause()
        renderSurface.flush()
        transport.stop()
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
        if let renderer = error as? AetherMetalRendererError {
            return .rendererFailed(renderer)
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
        if let renderer = error as? AetherMetalRendererError {
            return .rendererFailed(renderer)
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
