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
        }
    }
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

/// Aether-owned AVPlayer lifecycle for a preflight-admitted `.nativeAVPlayer` route.
///
/// The host may mount `avPlayer` in AVPlayerViewController and observe `state`, but it does not create or
/// replace the asset, player item or player. Terminal item failure remains on this session and never
/// selects the Hybrid or legacy route.
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

    public var audioAnalysisTrackIDs: [Int] {
        audioAnalysisBinding.publicTrackIDs
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
    private var mediaSelectionObserver: NSObjectProtocol?
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
            }
            if avPlayerItem.status == .readyToPlay {
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
            avPlayer.play()
        }
        state = .playing
    }

    public func pause() throws {
        try requireActive()
        if let engine {
            engine.pause()
        } else {
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
                avPlayer.pause()
            }
            state = .paused
        } else {
            if let engine {
                engine.setRate(rate)
            } else {
                avPlayer.rate = rate
            }
            state = .playing
        }
    }

    public func seek(to target: CMTime) async throws {
        try requireActive()
        guard target.isValid,
              target.isNumeric,
              target.seconds.isFinite,
              target.seconds >= 0 else {
            throw AetherNativePlaybackSessionError.invalidSeekTarget
        }
        let shouldResume = avPlayer.rate > 0
        state = .seeking
        let finished: Bool
        if let engine {
            await engine.seek(to: target.seconds)
            finished = true
        } else {
            finished = await withCheckedContinuation {
                (continuation: CheckedContinuation<Bool, Never>) in
                avPlayer.seek(
                    to: target,
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                ) { finished in
                    continuation.resume(returning: finished)
                }
            }
        }
        try requireActive()
        guard finished else {
            throw AetherNativePlaybackSessionError.invalidSeekTarget
        }
        state = shouldResume ? .playing : .paused
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
        itemStatusObservation = avPlayerItem.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, !self.isStopped else { return }
                switch item.status {
                case .readyToPlay:
                    if self.state == .idle
                        || self.state == .preparing {
                        self.state = .ready
                    }
                    self.handleMediaSelectionChange()
                case .failed:
                    self.state = .failed(.playerItemFailed)
                case .unknown:
                    break
                @unknown default:
                    self.state = .failed(.playerItemFailed)
                }
            }
        }
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
                    if self.state == .playing {
                        self.state = .paused
                    }
                case .waitingToPlayAtSpecifiedRate:
                    break
                @unknown default:
                    break
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
