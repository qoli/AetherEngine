import AVFoundation
import Combine
import CoreMedia
import Foundation

#if os(tvOS)
import AVKit
#endif

public enum AetherNativePlaybackSessionState: Sendable, Equatable {
    case idle
    case preparing
    case ready
    case playing
    case paused
    case seeking
    case ended
    case failed(AetherNativePlaybackSessionFailure)
    case stopped
}

public enum AetherNativePlaybackSessionFailure:
    String,
    Sendable,
    Equatable
{
    case assetNotPlayable
    case playerItemFailed
    case engineFailed
}

enum AetherNativePlaybackFailureCategory:
    String,
    Sendable,
    Equatable
{
    case transientTransport
    case authentication
    case security
    case decoder
    case malformed
    case routeRuntime
    case cancelled
    case invariant
}

struct AetherNativePlaybackFailureEvidence:
    Sendable,
    Equatable
{
    let category: AetherNativePlaybackFailureCategory
    let caseCode: String
    let domain: String
    let code: Int
}

enum AetherNativePlaybackSessionError:
    Error,
    Sendable,
    Equatable,
    LocalizedError
{
    case preflightRequiresNative(
        route: PlaybackRenderRoute,
        reason: PlaybackRouteReason
    )
    case assetNotPlayable
    case audioAnalysisBindingSourceMismatch
    case nativeRemuxRequiresPreparedSource
    case incompatibleRemuxOptions
    case sourceFactsDiverged
    case engineRouteContractDiverged
    case stopped
    case invalidRate
    case invalidSeekTarget
    case seekDidNotApply
    case seekTimedOut(seconds: Double)
    case startupTimedOut

    public var errorDescription: String? {
        switch self {
        case .preflightRequiresNative(let route, let reason):
            "Native playback session requires a native preflight route, found \(route.rawValue) (\(reason.rawValue))"
        case .assetNotPlayable:
            "The native playback asset is not playable"
        case .audioAnalysisBindingSourceMismatch:
            "The native audio-analysis binding does not match the playback source"
        case .nativeRemuxRequiresPreparedSource:
            "Native HLS-fMP4 remux requires the admitted prepared source"
        case .incompatibleRemuxOptions:
            "Native HLS-fMP4 remux requires a finite video VOD request"
        case .sourceFactsDiverged:
            "The prepared source facts changed before native remux"
        case .engineRouteContractDiverged:
            "The native remux pipeline did not produce the stable AVPlayer route"
        case .stopped:
            "The native playback session has stopped"
        case .invalidRate:
            "The native playback rate is invalid"
        case .invalidSeekTarget:
            "The native playback seek target is invalid"
        case .seekDidNotApply:
            "The native playback seek did not apply to the active generation"
        case .seekTimedOut(let seconds):
            "The native playback seek exceeded its \(seconds)-second recovery deadline"
        case .startupTimedOut:
            "The native playback item did not become ready within three seconds"
        }
    }
}

private enum AetherNativeBoundedSeekOutcome:
    Sendable,
    Equatable
{
    case applied
    case rejected
    case timedOut
}

/// Privacy-safe Native-session diagnostics. Source URLs, headers, decoder
/// strings and media-option display names are intentionally excluded.
public struct AetherNativePlaybackDiagnostics:
    Sendable,
    Equatable
{
    public let preflightResult: PlaybackPreflightResult
    public let state: AetherNativePlaybackSessionState
    public let audioAnalysisDurationSeconds: Double?
    public let audioAnalysisTrackIDs: [Int]
    public let selectedAudioAnalysisTrackID: Int?
    public let activeAudioAnalysisRequestCount: Int
}

/// Unstructured MainActor race used only by the unified adapter to put the
/// recovery episode's deadline around the existing engine seek. Cancelling the
/// losing task does not invent a second landing policy: engine generation/load
/// guards still own any late AVPlayer completion after route teardown.
@MainActor
private final class AetherNativeEngineSeekDeadlineRace {
    private var continuation:
        CheckedContinuation<AetherNativeBoundedSeekOutcome, Never>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func start(
        continuation: CheckedContinuation<
            AetherNativeBoundedSeekOutcome,
            Never
        >,
        engine: AetherEngine,
        targetSeconds: Double,
        timeout: TimeInterval
    ) {
        self.continuation = continuation
        operationTask = Task { @MainActor [weak self] in
            await engine.seek(to: targetSeconds)
            self?.resolve(.applied)
        }
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(timeout * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            self?.resolve(.timedOut)
        }
    }

    func cancel() {
        resolve(.timedOut)
    }

    private func resolve(
        _ outcome: AetherNativeBoundedSeekOutcome
    ) {
        guard let continuation else { return }
        self.continuation = nil
        operationTask?.cancel()
        timeoutTask?.cancel()
        operationTask = nil
        timeoutTask = nil
        continuation.resume(returning: outcome)
    }
}

/// Aether-owned AVPlayer lifecycle for a preflight-admitted `.nativeAVPlayer` route.
///
/// The host may mount `avPlayer` in AVPlayerViewController and observe `state`, but it does not create or
/// replace the asset, player item or player. Failure evidence returns to the unified recovery
/// coordinator; the host never chooses a replacement route or legacy player.
@MainActor
final class AetherNativePlaybackSession: ObservableObject {
    public let preflightResult: PlaybackPreflightResult
    public let avPlayer: AVPlayer
    public private(set) var avPlayerItem: AVPlayerItem

    @Published public private(set) var state:
        AetherNativePlaybackSessionState = .idle
    /// Stable Aether track identity corresponding to AVKit's current audible
    /// selection. `nil` means the option-to-source mapping is not proven.
    @Published public private(set) var selectedAudioAnalysisTrackID:
        Int?
    private(set) var lastFailureEvidence:
        AetherNativePlaybackFailureEvidence?

    public var audioAnalysisTrackIDs: [Int] {
        audioAnalysisBinding.publicTrackIDs
    }

    var audioTracks: [TrackInfo] {
        engine?.audioTracks
            ?? audioAnalysisBinding.tracks.compactMap { track in
                track.sourceTrack.map {
                    TrackInfo(
                        id: track.publicTrackID,
                        name: $0.name,
                        codec: $0.codec,
                        language: $0.language,
                        channels: $0.channels,
                        bitrate: $0.bitrate,
                        isDefault: $0.isDefault,
                        isCommentary: $0.isCommentary,
                        isAtmos: $0.isAtmos
                    )
                }
            }
    }

    var subtitleTracks: [TrackInfo] {
        engine?.subtitleTracks ?? directSubtitleTracks
    }

    var selectedAudioTrackID: Int? {
        engine?.activeAudioTrackIndex
            ?? selectedAudioAnalysisTrackID
    }

    var selectedSubtitleTrackID: Int? {
        engine?.activeSubtitleTrackIndex
            ?? directSelectedSubtitleTrackID
    }

    public var audioAnalysisDurationSeconds: Double? {
        audioAnalysisBinding.durationSeconds
    }

    public var activeAudioAnalysisRequestCount: Int {
        audioAnalysisSessions.count
    }

    public var diagnostics: AetherNativePlaybackDiagnostics {
        AetherNativePlaybackDiagnostics(
            preflightResult: preflightResult,
            state: state,
            audioAnalysisDurationSeconds:
                audioAnalysisDurationSeconds,
            audioAnalysisTrackIDs: audioAnalysisTrackIDs,
            selectedAudioAnalysisTrackID:
                selectedAudioAnalysisTrackID,
            activeAudioAnalysisRequestCount:
                activeAudioAnalysisRequestCount
        )
    }

    private var itemStatusObservation: NSKeyValueObservation?
    private var currentItemObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failedToEndObserver: NSObjectProtocol?
    private var mediaSelectionObserver: NSObjectProtocol?
    private var playbackStalledObserver: NSObjectProtocol?
    private var progressObserver: Any?
    private var directStallRecoveryTask: Task<Void, Never>?
    private var directItemDeathConfirmationTask: Task<Void, Never>?
    private var directFailedToEndConfirmationTask: Task<Void, Never>?
    private var directItemReviveGate = ItemDeathReviveGate(
        maxAttempts: 3
    )
    private var lastObservedPlayerTime: CMTime = .zero
    private var directSubtitleTracks: [TrackInfo] = []
    private var directSelectedSubtitleTrackID: Int?
    private var directPlayIntent = false
    private var directRateIntent: Float = 1
    private var directExplicitAudioTrackID: Int?
    private var seekRequestSequence: UInt64 = 0
    private var activeEngineSeekDeadlineRace:
        AetherNativeEngineSeekDeadlineRace?
    private var audioAnalysisSelectionResolutionTask:
        Task<Void, Never>?
    private var audioAnalysisSessions: [
        UUID: AudioAnalysisSession
    ] = [:]
    private let audioAnalysisBinding:
        AetherNativeAudioAnalysisBinding
    private let audioAnalysisTelemetryHub =
        AetherAudioAnalysisTelemetryHub()
    private let engine: AetherEngine?
    private var engineCancellables = Set<AnyCancellable>()
    private var isStopped = false

    private init(
        preflightResult: PlaybackPreflightResult,
        avPlayerItem: AVPlayerItem,
        avPlayer: AVPlayer,
        audioAnalysisBinding:
            AetherNativeAudioAnalysisBinding,
        engine: AetherEngine? = nil
    ) {
        self.preflightResult = preflightResult
        self.audioAnalysisBinding = audioAnalysisBinding
        self.avPlayerItem = avPlayerItem
        self.avPlayer = avPlayer
        self.engine = engine
        if avPlayer.currentItem !== avPlayerItem {
            avPlayer.replaceCurrentItem(with: avPlayerItem)
        }
        avPlayer.actionAtItemEnd = .pause
        avPlayer.preventsDisplaySleepDuringVideoPlayback = true
        avPlayer.automaticallyWaitsToMinimizeStalling = true
        if let engine {
            installEngineObservers(engine)
        } else {
            installDirectObservers()
        }
    }

    public static func make(
        url: URL,
        options: LoadOptions = .init(),
        preflightResult: PlaybackPreflightResult
    ) throws -> AetherNativePlaybackSession {
        try make(
            url: url,
            options: options,
            preflightResult: preflightResult,
            audioAnalysisBinding: .unavailable(
                sourceURL: url,
                httpHeaders: options.httpHeaders,
                error: .analysisFailed(
                    "native session requires factory-bound audio analysis"
                )
            )
        )
    }

    static func make(
        url: URL,
        options: LoadOptions = .init(),
        preflightResult: PlaybackPreflightResult,
        audioAnalysisBinding:
            AetherNativeAudioAnalysisBinding,
        avPlayer: AVPlayer = AVPlayer()
    ) throws -> AetherNativePlaybackSession {
        guard preflightResult.route == .nativeAVPlayer else {
            throw AetherNativePlaybackSessionError
                .preflightRequiresNative(
                    route: preflightResult.route,
                    reason: preflightResult.reason
                )
        }
        guard audioAnalysisBinding.sourceURL == url,
              audioAnalysisBinding.httpHeaders
                == options.httpHeaders else {
            throw AetherNativePlaybackSessionError
                .audioAnalysisBindingSourceMismatch
        }
        guard preflightResult.reason != .nativeHLSFMP4Remux else {
            throw AetherNativePlaybackSessionError
                .nativeRemuxRequiresPreparedSource
        }
        var assetOptions: [String: Any] = [:]
        if !options.httpHeaders.isEmpty {
            assetOptions["AVURLAssetHTTPHeaderFieldsKey"] =
                options.httpHeaders
        }
        return AetherNativePlaybackSession(
            preflightResult: preflightResult,
            avPlayerItem: AVPlayerItem(
                asset: AVURLAsset(url: url, options: assetOptions)
            ),
            avPlayer: avPlayer,
            audioAnalysisBinding: audioAnalysisBinding
        )
    }

    static func makeRemuxed(
        preparedSource: AetherPreparedURLSource,
        options: LoadOptions,
        preflightResult: PlaybackPreflightResult,
        audioAnalysisBinding: AetherNativeAudioAnalysisBinding,
        avPlayer: AVPlayer
    ) async throws -> AetherNativePlaybackSession {
        guard preflightResult.route == .nativeAVPlayer,
              preflightResult.reason == .nativeHLSFMP4Remux else {
            throw AetherNativePlaybackSessionError
                .preflightRequiresNative(
                    route: preflightResult.route,
                    reason: preflightResult.reason
                )
        }
        guard audioAnalysisBinding.sourceURL
                == preparedSource.url,
              audioAnalysisBinding.httpHeaders
                == options.httpHeaders else {
            throw AetherNativePlaybackSessionError
                .audioAnalysisBindingSourceMismatch
        }
        guard !options.nativeRemoteHLS,
              !options.audioOnly,
              !options.isLive else {
            throw AetherNativePlaybackSessionError
                .incompatibleRemuxOptions
        }

        let engine = try AetherEngine(nativeAVPlayer: avPlayer)
        var engineOptions = options
        engineOptions.autoplay = false
        do {
            guard let loadedProbe = try await engine.load(
                preparedURLSource: preparedSource,
                options: engineOptions
            ) else {
                engine.stop()
                throw AetherNativePlaybackSessionError
                    .sourceFactsDiverged
            }
            let loadedProfile = AetherSourceProfile(
                probe: loadedProbe,
                sourceKind: .progressive,
                isSeekableVOD:
                    loadedProbe.durationSeconds.isFinite
                    && loadedProbe.durationSeconds > 0
                    && !loadedProbe.isLive
            )
            guard loadedProfile == preflightResult.sourceProfile else {
                engine.stop()
                throw AetherNativePlaybackSessionError
                    .sourceFactsDiverged
            }
            guard engine.currentAVPlayer === avPlayer,
                  let item = avPlayer.currentItem else {
                engine.stop()
                throw AetherNativePlaybackSessionError
                    .engineRouteContractDiverged
            }
            return AetherNativePlaybackSession(
                preflightResult: preflightResult,
                avPlayerItem: item,
                avPlayer: avPlayer,
                audioAnalysisBinding: audioAnalysisBinding,
                engine: engine
            )
        } catch {
            engine.stop()
            throw error
        }
    }

    /// Bounded asset validation before the host issues play. AVPlayerItem readiness remains observable
    /// through `state` and is not treated as permission to change route.
    public func prepare() async throws {
        try requireActive()
        state = .preparing
        do {
            let playable = try await avPlayerItem.asset.load(.isPlayable)
            guard playable else {
                state = .failed(.assetNotPlayable)
                throw AetherNativePlaybackSessionError.assetNotPlayable
            }
            if let engine {
                if case .error = engine.state {
                    throw AetherNativePlaybackSessionError
                        .engineRouteContractDiverged
                }
                applySelectedAudioAnalysisTrackID(
                    engine.activeAudioTrackIndex
                )
            } else {
                await refreshSelectedAudioAnalysisTrackIDFromPlayer()
                await refreshDirectSubtitleSelectionFromPlayer()
            }
            if avPlayerItem.status == .readyToPlay {
                state = .ready
            } else {
                let deadline = ProcessInfo.processInfo.systemUptime + 3
                while avPlayerItem.status == .unknown,
                      ProcessInfo.processInfo.systemUptime < deadline {
                    try await Task.sleep(nanoseconds: 50_000_000)
                    try requireActive()
                }
                guard avPlayerItem.status == .readyToPlay else {
                    state = .failed(.playerItemFailed)
                    throw AetherNativePlaybackSessionError
                        .startupTimedOut
                }
                state = .ready
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AetherNativePlaybackSessionError {
            throw error
        } catch {
            state = .failed(.assetNotPlayable)
            throw AetherNativePlaybackSessionError.assetNotPlayable
        }
    }

    public func play() throws {
        try requireActive()
        if let engine {
            engine.play()
        } else {
            directPlayIntent = true
            avPlayer.play()
        }
        state = .playing
    }

    public func pause() throws {
        try requireActive()
        if let engine {
            engine.pause()
        } else {
            directPlayIntent = false
            avPlayer.pause()
        }
        state = .paused
    }

    public func setRate(_ rate: Float) throws {
        try requireActive()
        guard rate.isFinite, rate >= 0 else {
            throw AetherNativePlaybackSessionError.invalidRate
        }
        if rate == 0 {
            if let engine {
                engine.pause()
            } else {
                directPlayIntent = false
                avPlayer.pause()
            }
            state = .paused
        } else {
            if let engine {
                engine.setRate(rate)
            } else {
                directPlayIntent = true
                directRateIntent = rate
                avPlayer.rate = rate
            }
            state = .playing
        }
    }

    func seek(
        to target: CMTime,
        timeout: TimeInterval = 30
    ) async throws -> AetherPlaybackSeekResult {
        try requireActive()
        guard target.isValid,
              target.isNumeric,
              target.seconds.isFinite,
              target.seconds >= 0,
              timeout.isFinite,
              timeout > 0 else {
            throw AetherNativePlaybackSessionError.invalidSeekTarget
        }
        seekRequestSequence &+= 1
        let requestSequence = seekRequestSequence
        activeEngineSeekDeadlineRace?.cancel()
        activeEngineSeekDeadlineRace = nil
        let engineShouldResume = engine != nil && state == .playing
        state = .seeking
        if let engine {
            let deadline = ProcessInfo.processInfo.systemUptime
                + timeout
            let seekRace = AetherNativeEngineSeekDeadlineRace()
            activeEngineSeekDeadlineRace = seekRace
            let engineSeekOutcome = await withCheckedContinuation {
                continuation in
                seekRace.start(
                    continuation: continuation,
                    engine: engine,
                    targetSeconds: target.seconds,
                    timeout: timeout
                )
            }
            if activeEngineSeekDeadlineRace === seekRace {
                activeEngineSeekDeadlineRace = nil
            }
            try requireActive()
            guard requestSequence == seekRequestSequence else {
                return .superseded
            }
            switch engineSeekOutcome {
            case .applied:
                break
            case .timedOut:
                throw AetherNativePlaybackSessionError
                    .seekTimedOut(seconds: timeout)
            case .rejected:
                throw AetherNativePlaybackSessionError.seekDidNotApply
            }
            while true {
                try requireActive()
                guard requestSequence == seekRequestSequence else {
                    return .superseded
                }
                switch engine.state {
                case .error, .idle, .ended:
                    throw AetherNativePlaybackSessionError
                        .seekDidNotApply
                case .loading, .playing, .paused, .seeking:
                    break
                }
                let physicallyLanded = !engine.isSeeking
                    && engine.pendingRecoverySeekClockTarget == nil
                if physicallyLanded {
                    state = engineShouldResume
                        ? .playing
                        : .paused
                    return .applied
                }
                guard ProcessInfo.processInfo.systemUptime
                        < deadline else {
                    throw AetherNativePlaybackSessionError
                        .seekTimedOut(seconds: timeout)
                }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
        } else {
            avPlayer.currentItem?.cancelPendingSeeks()
            let outcome = await boundedDirectSeek(
                to: target,
                timeout: timeout
            )
            try requireActive()
            guard requestSequence == seekRequestSequence else {
                return .superseded
            }
            switch outcome {
            case .applied:
                break
            case .rejected:
                throw AetherNativePlaybackSessionError.seekDidNotApply
            case .timedOut:
                throw AetherNativePlaybackSessionError
                    .seekTimedOut(seconds: timeout)
            }
            if directPlayIntent {
                avPlayer.rate = directRateIntent
                state = .playing
            } else {
                avPlayer.pause()
                state = .paused
            }
            return .applied
        }
    }

    private func boundedDirectSeek(
        to target: CMTime,
        timeout: TimeInterval
    ) async -> AetherNativeBoundedSeekOutcome {
        let resumeGuard = SeekResumeGuard()
        return await withCheckedContinuation {
            (continuation: CheckedContinuation<
                AetherNativeBoundedSeekOutcome,
                Never
            >) in
            Task { @MainActor in
                try? await Task.sleep(
                    nanoseconds: UInt64(
                        timeout * 1_000_000_000
                    )
                )
                guard resumeGuard.claim() else { return }
                continuation.resume(returning: .timedOut)
            }
            avPlayer.seek(
                to: target,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { finished in
                Task { @MainActor in
                    guard resumeGuard.claim() else { return }
                    continuation.resume(
                        returning: finished
                            ? .applied
                            : .rejected
                    )
                }
            }
        }
    }

    func selectAudioTrack(_ trackID: Int) async throws {
        try requireActive()
        if let engine {
            guard engine.audioTracks.contains(where: {
                $0.id == trackID
            }) else {
                throw AetherNativePlaybackSessionError
                    .sourceFactsDiverged
            }
            engine.selectAudioTrack(index: trackID)
            for _ in 0..<300 {
                try requireActive()
                if engine.activeAudioTrackIndex == trackID {
                    directExplicitAudioTrackID = trackID
                    return
                }
                if case .error = engine.state {
                    throw AetherNativePlaybackSessionError.engineRouteContractDiverged
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw AetherNativePlaybackSessionError
                .engineRouteContractDiverged
        }
        guard let optionIndex = audioAnalysisBinding.optionTrackIDs
                .firstIndex(of: trackID),
              let group = try await avPlayerItem.asset
                .loadMediaSelectionGroup(for: .audible),
              group.options.indices.contains(optionIndex) else {
            throw AetherNativePlaybackSessionError
                .sourceFactsDiverged
        }
        avPlayerItem.select(
            group.options[optionIndex],
            in: group
        )
        for _ in 0..<100 {
            await refreshSelectedAudioAnalysisTrackIDFromPlayer()
            if selectedAudioAnalysisTrackID == trackID {
                directExplicitAudioTrackID = trackID
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw AetherNativePlaybackSessionError
            .engineRouteContractDiverged
    }

    func selectSubtitleTrack(_ trackID: Int?) async throws {
        try requireActive()
        if let engine {
            guard let trackID else {
                engine.clearSubtitle()
                return
            }
            guard engine.subtitleTracks.contains(where: {
                $0.id == trackID
            }) else {
                throw AetherNativePlaybackSessionError
                    .sourceFactsDiverged
            }
            engine.selectSubtitleTrack(index: trackID)
            return
        }
        guard let group = try await avPlayerItem.asset
                .loadMediaSelectionGroup(for: .legible) else {
            if trackID == nil { return }
            throw AetherNativePlaybackSessionError
                .sourceFactsDiverged
        }
        if let trackID {
            guard group.options.indices.contains(trackID) else {
                throw AetherNativePlaybackSessionError
                    .sourceFactsDiverged
            }
            avPlayerItem.select(group.options[trackID], in: group)
        } else {
            avPlayerItem.select(nil, in: group)
        }
        await refreshDirectSubtitleSelectionFromPlayer()
    }

    #if os(tvOS)
    public func configurePlayerViewController(
        _ controller: AVPlayerViewController
    ) throws {
        try requireActive()
        controller.player = avPlayer
        controller.appliesPreferredDisplayCriteriaAutomatically = true
    }
    #endif

    /// Bounded, privacy-safe lifecycle telemetry for Native independent audio
    /// analysis. Playback state and source identity never enter this stream.
    public func audioAnalysisTelemetryEvents()
        -> AsyncStream<AetherAudioAnalysisTelemetry>
    {
        audioAnalysisTelemetryHub.stream()
    }

    public func audioAnalysisAvailability(
        for audioTrackID: Int
    ) -> AudioAnalysisTrackAvailability {
        switch state {
        case .failed, .stopped:
            return .unavailable(.noActiveSession)
        case .idle, .preparing, .ready, .playing, .paused,
             .seeking, .ended:
            break
        }
        return audioAnalysisBinding.availability(
            for: audioTrackID
        )
    }

    public func audioAnalysisStream(
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
        if let duration = audioAnalysisDurationSeconds,
           request.range.upperBound > duration {
            throw AudioAnalysisError.rangeOutsideSource
        }
        let input = try audioAnalysisBinding.input(
            for: request.audioTrackID
        )
        let session = AudioAnalysisSession(
            request: request
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.audioAnalysisTelemetryHub.emit(event)
            }
        }
        let stream = AudioAnalysisStream(
            gate: session.gate,
            cancel: { session.cancel() }
        )
        audioAnalysisSessions[session.id] = session
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

    public func cancelAudioAnalysisStreams() {
        let sessions = Array(audioAnalysisSessions.values)
        audioAnalysisSessions.removeAll()
        for session in sessions {
            session.cancel()
        }
    }

    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        seekRequestSequence &+= 1
        activeEngineSeekDeadlineRace?.cancel()
        activeEngineSeekDeadlineRace = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        currentItemObservation?.invalidate()
        currentItemObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        audioAnalysisSelectionResolutionTask?.cancel()
        audioAnalysisSelectionResolutionTask = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let mediaSelectionObserver {
            NotificationCenter.default.removeObserver(
                mediaSelectionObserver
            )
            self.mediaSelectionObserver = nil
        }
        if let playbackStalledObserver {
            NotificationCenter.default.removeObserver(
                playbackStalledObserver
            )
            self.playbackStalledObserver = nil
        }
        if let progressObserver {
            avPlayer.removeTimeObserver(progressObserver)
            self.progressObserver = nil
        }
        directStallRecoveryTask?.cancel()
        directStallRecoveryTask = nil
        directItemDeathConfirmationTask?.cancel()
        directItemDeathConfirmationTask = nil
        cancelAudioAnalysisStreams()
        audioAnalysisTelemetryHub.finish()
        engineCancellables.removeAll()
        if let engine {
            engine.stop()
        } else {
            avPlayer.pause()
            avPlayer.replaceCurrentItem(with: nil)
        }
        state = .stopped
    }

    private func installDirectObservers() {
        installDirectItemObservers()
        timeControlObservation = avPlayer.observe(
            \.timeControlStatus,
            options: [.new]
        ) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, !self.isStopped else { return }
                switch player.timeControlStatus {
                case .playing:
                    self.state = .playing
                case .paused:
                    if !self.directPlayIntent,
                       self.state == .playing {
                        self.state = .paused
                    }
                case .waitingToPlayAtSpecifiedRate:
                    break
                @unknown default:
                    break
                }
            }
        }
        progressObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(
                seconds: 0.5,
                preferredTimescale: 600
            ),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard time.isValid,
                      time.isNumeric,
                      time.seconds.isFinite else { return }
                self?.lastObservedPlayerTime = time
            }
        }
    }

    private func installDirectItemObservers() {
        itemStatusObservation = avPlayerItem.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, !self.isStopped else { return }
                switch item.status {
                case .readyToPlay:
                    self.directItemDeathConfirmationTask?.cancel()
                    self.directItemDeathConfirmationTask = nil
                    if self.state == .idle
                        || self.state == .preparing {
                        self.state = .ready
                    }
                    self.handleMediaSelectionChange()
                case .failed:
                    self.lastFailureEvidence = Self.failureEvidence(
                        error: item.error,
                        caseCode: "itemStatusFailed"
                    )
                    self.handleDirectItemDeath()
                case .unknown:
                    break
                @unknown default:
                    self.state = .failed(.playerItemFailed)
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: avPlayerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isStopped else { return }
                self.state = .ended
            }
        }
        failedToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: avPlayerItem,
            queue: .main
        ) { [weak self, weak item = avPlayerItem] _ in
            MainActor.assumeIsolated {
                guard let self, let item, !self.isStopped else {
                    return
                }
                self.handleDirectFailedToEnd(
                    item: item,
                    error: item.error
                )
            }
        }
        mediaSelectionObserver = NotificationCenter.default
            .addObserver(
                forName: AVPlayerItem
                    .mediaSelectionDidChangeNotification,
                object: avPlayerItem,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleMediaSelectionChange()
                }
            }
        playbackStalledObserver = NotificationCenter.default
            .addObserver(
                forName: AVPlayerItem.playbackStalledNotification,
                object: avPlayerItem,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleDirectPlaybackStall()
                }
            }
    }

    private func removeDirectItemObservers() {
        directFailedToEndConfirmationTask?.cancel()
        directFailedToEndConfirmationTask = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let failedToEndObserver {
            NotificationCenter.default.removeObserver(
                failedToEndObserver
            )
            self.failedToEndObserver = nil
        }
        if let mediaSelectionObserver {
            NotificationCenter.default.removeObserver(
                mediaSelectionObserver
            )
            self.mediaSelectionObserver = nil
        }
        if let playbackStalledObserver {
            NotificationCenter.default.removeObserver(
                playbackStalledObserver
            )
            self.playbackStalledObserver = nil
        }
    }

    private func handleDirectItemDeath() {
        guard engine == nil,
              directItemDeathConfirmationTask == nil,
              !isStopped else { return }
        let failedItem = avPlayerItem
        directItemDeathConfirmationTask = Task {
            @MainActor [weak self, weak failedItem] in
            guard let self, let failedItem else { return }
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            } catch {
                self.directItemDeathConfirmationTask = nil
                return
            }
            guard !self.isStopped,
                  self.avPlayerItem === failedItem,
                  failedItem.status == .failed else {
                self.directItemDeathConfirmationTask = nil
                return
            }
            let observed = self.lastObservedPlayerTime.seconds
            let frozenPosition = observed.isFinite ? observed : 0
            guard self.directItemReviveGate.admit(
                position: frozenPosition
            ) else {
                self.directItemDeathConfirmationTask = nil
                self.state = .failed(.playerItemFailed)
                return
            }
            let attempt = self.directItemReviveGate.attempts
            self.directItemDeathConfirmationTask = nil
            EngineLog.emit(
                "[AetherNativePlaybackSession] direct item revive "
                    + "attempt=\(attempt) position="
                    + String(format: "%.3f", frozenPosition),
                category: .session
            )
            await self.reviveDirectItem(
                failedItem,
                at: CMTime(
                    seconds: frozenPosition,
                    preferredTimescale: 600
                )
            )
        }
    }

    private func handleDirectFailedToEnd(
        item: AVPlayerItem,
        error: Error?
    ) {
        guard engine == nil,
              avPlayerItem === item,
              !isStopped else { return }
        directFailedToEndConfirmationTask?.cancel()
        let frozenTime = lastObservedPlayerTime
        let nsError = error as NSError?
        lastFailureEvidence = Self.failureEvidence(
            error: error,
            caseCode: "failedToPlayToEnd"
        )
        EngineLog.emit(
            "[AetherNativePlaybackSession] failed-to-end evidence "
                + "domain=\(nsError?.domain ?? "AVFoundation") "
                + "code=\(nsError?.code ?? -1)",
            category: .session
        )
        directFailedToEndConfirmationTask = Task {
            @MainActor [weak self, weak item] in
            guard let self, let item else { return }
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            } catch {
                return
            }
            guard !self.isStopped,
                  self.avPlayerItem === item,
                  !Self.madeProgress(
                    from: frozenTime,
                    to: self.lastObservedPlayerTime
                  ) else {
                self.directFailedToEndConfirmationTask = nil
                return
            }
            self.directFailedToEndConfirmationTask = nil
            self.state = .failed(.playerItemFailed)
        }
    }

    private static func failureEvidence(
        error: Error?,
        caseCode: String
    ) -> AetherNativePlaybackFailureEvidence {
        var current = error as NSError?
        var selected = current
        var category = AetherNativePlaybackFailureCategory
            .routeRuntime
        for _ in 0..<6 {
            guard let evidenceError = current else { break }
            selected = evidenceError
            if let response = evidenceError.userInfo.values
                .compactMap({ $0 as? HTTPURLResponse })
                .first {
                selected = NSError(
                    domain: "HTTP",
                    code: response.statusCode
                )
                category = if response.statusCode == 401
                    || response.statusCode == 403 {
                    .authentication
                } else if response.statusCode == 408
                    || response.statusCode == 425
                    || response.statusCode == 429
                    || response.statusCode >= 500 {
                    .transientTransport
                } else {
                    .routeRuntime
                }
                break
            }
            if evidenceError.domain == NSURLErrorDomain {
                let code = URLError.Code(
                    rawValue: evidenceError.code
                )
                category = switch HLSVODOriginResourceLoader
                    .transportDisposition(for: code) {
                case .transient: .transientTransport
                case .cancelled: .cancelled
                case .security: .security
                case .invariant: .invariant
                }
                break
            }
            current = evidenceError.userInfo[NSUnderlyingErrorKey]
                as? NSError
        }
        return AetherNativePlaybackFailureEvidence(
            category: category,
            caseCode: caseCode,
            domain: selected?.domain ?? "AVFoundation",
            code: selected?.code ?? -1
        )
    }

    private func reviveDirectItem(
        _ failedItem: AVPlayerItem,
        at position: CMTime
    ) async {
        guard !isStopped,
              avPlayerItem === failedItem else { return }
        let selectedAudio = directExplicitAudioTrackID
        let selectedSubtitle = directSelectedSubtitleTrackID
        removeDirectItemObservers()
        let freshItem = AVPlayerItem(asset: failedItem.asset)
        avPlayerItem = freshItem
        avPlayer.replaceCurrentItem(with: freshItem)
        installDirectItemObservers()
        state = .preparing

        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while freshItem.status == .unknown,
              ProcessInfo.processInfo.systemUptime < deadline,
              !isStopped {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard !isStopped else { return }
        guard freshItem.status == .readyToPlay else {
            if freshItem.status == .failed {
                handleDirectItemDeath()
            } else {
                state = .failed(.playerItemFailed)
            }
            return
        }
        if let selectedAudio {
            do {
                try await selectAudioTrack(selectedAudio)
            } catch {
                state = .failed(.playerItemFailed)
                return
            }
        }
        if let selectedSubtitle {
            try? await selectSubtitleTrack(selectedSubtitle)
        }
        let landed = await withCheckedContinuation {
            (continuation: CheckedContinuation<Bool, Never>) in
            avPlayer.seek(
                to: position,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { finished in
                continuation.resume(returning: finished)
            }
        }
        guard landed else {
            state = .failed(.playerItemFailed)
            return
        }
        if directPlayIntent {
            avPlayer.rate = directRateIntent
            state = .playing
        } else {
            avPlayer.pause()
            state = .paused
        }
    }

    private func handleDirectPlaybackStall() {
        guard engine == nil,
              directStallRecoveryTask == nil,
              !isStopped else { return }
        let frozenTime = lastObservedPlayerTime
        directStallRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.directStallRecoveryTask = nil }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled, !self.isStopped,
                  !Self.madeProgress(
                    from: frozenTime,
                    to: self.lastObservedPlayerTime
                  ) else { return }
            let shouldPlay = self.directPlayIntent
            if shouldPlay {
                self.avPlayer.play()
            }
            let nudgeTime = self.lastObservedPlayerTime
            EngineLog.emit(
                "[AetherNativePlaybackSession] direct stall nudge",
                category: .session
            )
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled, !self.isStopped,
                  !Self.madeProgress(
                    from: nudgeTime,
                    to: self.lastObservedPlayerTime
                  ) else { return }
            self.state = .failed(.playerItemFailed)
        }
    }

    private static func madeProgress(
        from oldTime: CMTime,
        to newTime: CMTime
    ) -> Bool {
        guard oldTime.isNumeric,
              newTime.isNumeric else { return false }
        return CMTimeSubtract(newTime, oldTime).seconds > 0.1
    }

    private func installEngineObservers(_ engine: AetherEngine) {
        currentItemObservation = avPlayer.observe(
            \.currentItem,
            options: [.new]
        ) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, !self.isStopped,
                      let item = player.currentItem else { return }
                self.avPlayerItem = item
            }
        }
        engine.$state
            .sink { [weak self] engineState in
                guard let self, !self.isStopped else { return }
                switch engineState {
                case .idle:
                    break
                case .loading:
                    if self.state == .idle {
                        self.state = .preparing
                    }
                case .playing:
                    self.state = .playing
                case .paused:
                    if self.state != .seeking {
                        self.state = .paused
                    }
                case .seeking:
                    self.state = .seeking
                case .ended:
                    self.state = .ended
                case .error:
                    self.state = .failed(.engineFailed)
                }
            }
            .store(in: &engineCancellables)
        engine.$activeAudioTrackIndex
            .removeDuplicates()
            .sink { [weak self] trackID in
                self?.applySelectedAudioAnalysisTrackID(trackID)
            }
            .store(in: &engineCancellables)
    }

    private func handleMediaSelectionChange() {
        audioAnalysisSelectionResolutionTask?.cancel()
        audioAnalysisSelectionResolutionTask = Task {
            @MainActor [weak self] in
            guard let self else { return }
            await refreshSelectedAudioAnalysisTrackIDFromPlayer()
            await refreshDirectSubtitleSelectionFromPlayer()
            audioAnalysisSelectionResolutionTask = nil
        }
    }

    /// Deterministic internal seam for source-level selection/cancellation
    /// tests. Production selection is always read from the AVPlayer item.
    func handleMediaSelectionChange(
        selectedAudioOptionIndex: Int?
    ) {
        let trackID = selectedAudioOptionIndex.flatMap {
            index -> Int? in
            guard audioAnalysisBinding.optionTrackIDs.indices
                    .contains(index) else {
                return nil
            }
            return audioAnalysisBinding.optionTrackIDs[index]
        }
        applySelectedAudioAnalysisTrackID(trackID)
    }

    private func refreshSelectedAudioAnalysisTrackIDFromPlayer()
        async
    {
        guard !Task.isCancelled, !isStopped else { return }
        do {
            guard let group = try await avPlayerItem.asset
                    .loadMediaSelectionGroup(for: .audible) else {
                applySelectedAudioAnalysisTrackID(
                    audioAnalysisBinding.optionTrackIDs.count == 1
                        ? audioAnalysisBinding.optionTrackIDs[0]
                        : nil
                )
                return
            }
            guard group.options.count
                    == audioAnalysisBinding.optionTrackIDs.count,
                  let selected = avPlayerItem.currentMediaSelection
                    .selectedMediaOption(in: group),
                  let selectedIndex = group.options.firstIndex(
                    where: { $0.isEqual(selected) }
                  ),
                  !Task.isCancelled,
                  !isStopped else {
                applySelectedAudioAnalysisTrackID(nil)
                return
            }
            applySelectedAudioAnalysisTrackID(
                audioAnalysisBinding.optionTrackIDs[
                    selectedIndex
                ]
            )
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, !isStopped else { return }
            applySelectedAudioAnalysisTrackID(nil)
        }
    }

    private func refreshDirectSubtitleSelectionFromPlayer()
        async
    {
        guard engine == nil,
              !Task.isCancelled,
              !isStopped else { return }
        do {
            guard let group = try await avPlayerItem.asset
                    .loadMediaSelectionGroup(for: .legible) else {
                directSubtitleTracks = []
                directSelectedSubtitleTrackID = nil
                return
            }
            directSubtitleTracks = group.options.enumerated().map {
                index,
                option in
                TrackInfo(
                    id: index,
                    name: option.displayName,
                    codec: "native",
                    language: option.locale?.identifier,
                    isDefault: false,
                    isForced: option.hasMediaCharacteristic(
                        .containsOnlyForcedSubtitles
                    )
                )
            }
            let selected = avPlayerItem.currentMediaSelection
                .selectedMediaOption(in: group)
            directSelectedSubtitleTrackID = selected.flatMap {
                selected in
                group.options.firstIndex(where: {
                    $0.isEqual(selected)
                })
            }
        } catch {
            directSubtitleTracks = []
            directSelectedSubtitleTrackID = nil
        }
    }

    private func applySelectedAudioAnalysisTrackID(
        _ trackID: Int?
    ) {
        guard trackID != selectedAudioAnalysisTrackID else {
            return
        }
        // A request pins one source track. Cancellation must be observable by
        // the old consumer before the replacement identity is published.
        cancelAudioAnalysisStreams()
        selectedAudioAnalysisTrackID = trackID
    }

    private func removeAudioAnalysisSession(id: UUID) {
        audioAnalysisSessions.removeValue(forKey: id)
    }

    private func requireActive() throws {
        guard !isStopped else {
            throw AetherNativePlaybackSessionError.stopped
        }
    }
}
