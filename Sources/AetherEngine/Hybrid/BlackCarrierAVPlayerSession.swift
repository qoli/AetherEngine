import AVFoundation
import Foundation

enum BlackCarrierAVPlayerSessionError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case alreadyStarted
    case alreadyStopped
    case notStarted
    case preparationInProgress
    case providerPreparationFailed(reason: String)
    case serverStartFailed(reason: String)
    case playlistURLUnavailable
    case assetLoadFailed(reason: String)
    case assetNotPlayable
    case itemFailed(reason: String)
    case readinessTimedOut(seconds: Double)
    case preparationCancelled

    var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            return "Black carrier AVPlayer session is already started"
        case .alreadyStopped:
            return "Black carrier AVPlayer session is already stopped"
        case .notStarted:
            return "Black carrier AVPlayer session has not started"
        case .preparationInProgress:
            return "Black carrier AVPlayer session preparation is already in progress"
        case .providerPreparationFailed(let reason):
            return "Black carrier provider startup preparation failed: \(reason)"
        case .serverStartFailed(let reason):
            return "Black carrier HLS server could not start: \(reason)"
        case .playlistURLUnavailable:
            return "Black carrier HLS server did not publish a playlist URL"
        case .assetLoadFailed(let reason):
            return "Black carrier asset could not be loaded: \(reason)"
        case .assetNotPlayable:
            return "Black carrier asset is not playable"
        case .itemFailed(let reason):
            return "Black carrier AVPlayer item failed: \(reason)"
        case .readinessTimedOut(let seconds):
            return "Black carrier AVPlayer item was not ready within \(seconds) seconds"
        case .preparationCancelled:
            return "Black carrier AVPlayer session preparation was cancelled"
        }
    }
}

enum BlackCarrierTransportState: Sendable, Equatable {
    case idle
    case started
    case preparing
    case ready
    case failed(BlackCarrierAVPlayerSessionError)
    case stopped
}

enum BlackCarrierReadinessObservationResult:
    Sendable,
    Equatable
{
    case ready
    case noProgress
}

/// AVPlayer transport surface for a prebuilt black-video / real-audio carrier.
///
/// This type deliberately does not play, seek, render real video, or own hybrid first-frame
/// readiness policy. It only proves the carrier transport reached `readyToPlay`. The eventual
/// HybridPlaybackSession composes it with the decoder, sample-buffer presentation, and AVPlayer clock,
/// and generation gates. Call `stop()` before releasing the session.
@MainActor
final class BlackCarrierAVPlayerSession {
    private enum Lifecycle {
        case idle
        case started
        case stopped
    }

    let avPlayer: AVPlayer
    private(set) var playlistURL: URL?
    private(set) var transportState: BlackCarrierTransportState = .idle

    private let provider: any BlackCarrierTransportProvider
    private let server: HLSLocalServer
    private var lifecycle: Lifecycle = .idle
    private var statusObservation: NSKeyValueObservation?
    private var readinessContinuation:
        CheckedContinuation<
            BlackCarrierReadinessObservationResult,
            Error
        >?
    private weak var readinessObservedItem:
        AVPlayerItem?
    private var readinessRetryGate:
        ItemDeathReviveGate
    private let livenessPolicy:
        AetherPlaybackLivenessPolicy
    private let readinessAttemptOverride:
        (@MainActor @Sendable (
            AVPlayerItem,
            TimeInterval
        ) async throws
            -> BlackCarrierReadinessObservationResult)?
    private var installedItem: AVPlayerItem?
    private var routePreparationRetryEventHandler:
        (@MainActor @Sendable (
            AetherRoutePreparationRetryEvent
        ) -> Void)?
    private var previousAllowsExternalPlayback: Bool?
    #if os(iOS) || os(tvOS)
    private var previousUsesExternalPlaybackWhileExternalScreenIsActive:
        Bool?
    #endif

    init(
        provider: any BlackCarrierTransportProvider,
        avPlayer: AVPlayer = AVPlayer(),
        livenessPolicy:
            AetherPlaybackLivenessPolicy =
                .production,
        readinessAttemptOverride:
            (@MainActor @Sendable (
                AVPlayerItem,
                TimeInterval
            ) async throws
                -> BlackCarrierReadinessObservationResult)?
                = nil
    ) {
        self.provider = provider
        server = HLSLocalServer(provider: provider)
        self.avPlayer = avPlayer
        self.livenessPolicy = livenessPolicy
        readinessRetryGate =
            ItemDeathReviveGate(
                policy: livenessPolicy
            )
        self.readinessAttemptOverride =
            readinessAttemptOverride
    }

    func start() throws {
        try start(prepareProvider: true)
    }

    func startPrepared() throws {
        try start(prepareProvider: false)
    }

    private func start(prepareProvider: Bool) throws {
        switch lifecycle {
        case .idle:
            break
        case .started:
            throw BlackCarrierAVPlayerSessionError.alreadyStarted
        case .stopped:
            throw BlackCarrierAVPlayerSessionError.alreadyStopped
        }
        configurePlayerForCarrier()

        if prepareProvider {
            do {
                try provider.prepareForTransportStart()
            } catch {
                failAndClose()
                throw BlackCarrierAVPlayerSessionError.providerPreparationFailed(
                    reason: String(describing: error)
                )
            }
        }

        do {
            try server.start()
        } catch {
            failAndClose()
            throw BlackCarrierAVPlayerSessionError.serverStartFailed(
                reason: String(describing: error)
            )
        }
        guard let playlistURL = server.playlistURL else {
            failAndClose()
            throw BlackCarrierAVPlayerSessionError.playlistURLUnavailable
        }

        let item = makeCarrierItem(
            playlistURL: playlistURL
        )
        installedItem = item
        avPlayer.replaceCurrentItem(with: item)

        self.playlistURL = playlistURL
        readinessRetryGate =
            ItemDeathReviveGate(
                policy: livenessPolicy
            )
        lifecycle = .started
        transportState = .started
    }

    func seek(
        to time: CMTime,
        timeout: TimeInterval
    ) async -> Bool {
        guard timeout.isFinite, timeout > 0 else { return false }
        let resumeGuard = SeekResumeGuard()
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(
                            timeout * 1_000_000_000
                        )
                    )
                } catch {
                    return
                }
                guard resumeGuard.claim() else { return }
                continuation.resume(returning: false)
            }
            avPlayer.seek(
                to: time,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { finished in
                Task { @MainActor in
                    guard resumeGuard.claim() else { return }
                    continuation.resume(returning: finished)
                }
            }
        }
    }

    /// Resolves only the AVPlayer carrier transport boundary.
    ///
    /// A `.ready` result means the loopback asset is playable and the item reached
    /// `AVPlayerItem.Status.readyToPlay`. Hybrid playback must still wait for its target
    /// generation's decoded real-video frame before allowing audible playback.
    func prepare(timeout: TimeInterval = 15) async throws {
        switch lifecycle {
        case .idle:
            throw BlackCarrierAVPlayerSessionError.notStarted
        case .stopped:
            throw BlackCarrierAVPlayerSessionError.alreadyStopped
        case .started:
            break
        }
        switch transportState {
        case .ready:
            return
        case .preparing:
            throw BlackCarrierAVPlayerSessionError.preparationInProgress
        case .failed(let error):
            throw error
        case .idle, .started:
            break
        case .stopped:
            throw BlackCarrierAVPlayerSessionError.alreadyStopped
        }
        guard timeout.isFinite, timeout > 0 else {
            let error = BlackCarrierAVPlayerSessionError.readinessTimedOut(
                seconds: timeout
            )
            transportState = .failed(error)
            throw error
        }
        guard var item = avPlayer.currentItem else {
            let error = BlackCarrierAVPlayerSessionError.notStarted
            transportState = .failed(error)
            throw error
        }

        transportState = .preparing
        let readinessTask = Task { @MainActor [weak self] in
            guard let self else {
                throw BlackCarrierAVPlayerSessionError.preparationCancelled
            }
            while true {
                let nextAttempt =
                    self.readinessRetryGate.attempts
                        == Int.max
                    ? Int.max
                    : self.readinessRetryGate.attempts
                        + 1
                self.routePreparationRetryEventHandler?(
                    .attemptStarted(
                        attempt: nextAttempt
                    )
                )
                let noProgressWindow =
                    self.livenessPolicy
                        .noProgressWindowSeconds(
                            forAttempt: nextAttempt
                        )
                let retryReason: String
                let decision: ItemDeathReviveDecision
                do {
                    let result =
                        try await self
                            .loadAndAwaitReady(
                                item: item,
                                noProgressWindow:
                                    noProgressWindow
                            )
                    switch result {
                    case .ready:
                        self.routePreparationRetryEventHandler?(
                            .completed
                        )
                        return
                    case .noProgress:
                        retryReason =
                            "zeroProgressWindowElapsed"
                        decision =
                            self.readinessRetryGate
                                .recordFailure(
                                    position: 0
                                )
                    }
                } catch let error
                        as BlackCarrierAVPlayerSessionError {
                    guard Self
                            .isTransientReadinessFailure(
                                error
                            ) else {
                        throw error
                    }
                    retryReason =
                        "transientItemFailure"
                    decision =
                        self.readinessRetryGate
                            .recordFailure(position: 0)
                }
                if let diagnostic =
                        decision.diagnostic {
                    EngineLog.emit(
                        "[BlackCarrierAVPlayerSession] "
                            + "local carrier readiness "
                            + "remains pending reason="
                            + retryReason
                            + " attempt="
                            + "\(decision.attempt) "
                            + "failures="
                            + "\(diagnostic.cumulativeFailureCount) "
                            + "elapsed="
                            + "\(Int(diagnostic.elapsedSeconds))s "
                            + "window="
                            + "\(Int(noProgressWindow))s "
                            + "backoff="
                            + "\(Int(decision.backoffSeconds))s"
                            + (diagnostic
                                .checkpointSeconds
                                .map {
                                    " checkpoint=\(Int($0))s"
                                } ?? " firstFailure"),
                        category: .session
                    )
                }
                let nextRetryUptime =
                    ProcessInfo.processInfo.systemUptime
                    + decision.backoffSeconds
                self.routePreparationRetryEventHandler?(
                    .retryScheduled(
                        completedAttempt:
                            decision.attempt,
                        nextAttempt:
                            decision.attempt == Int.max
                                ? Int.max
                                : decision.attempt + 1,
                        nextRetryUptimeSeconds:
                            nextRetryUptime
                    )
                )
                try await Task.sleep(
                    nanoseconds:
                        UInt64(
                            decision
                                .backoffSeconds
                                * 1_000_000_000
                        )
                )
                try Task.checkCancellation()
                guard self.lifecycle == .started,
                      let playlistURL =
                        self.playlistURL,
                      self.avPlayer.currentItem
                        === item else {
                    throw BlackCarrierAVPlayerSessionError
                        .preparationCancelled
                }
                let replacement =
                    self.makeCarrierItem(
                        playlistURL:
                            playlistURL
                    )
                self.installedItem =
                    replacement
                self.avPlayer
                    .replaceCurrentItem(
                        with: replacement
                    )
                item = replacement
            }
        }
        defer {
            readinessTask.cancel()
        }
        do {
            try await withTaskCancellationHandler {
                try await readinessTask.value
            } onCancel: {
                readinessTask.cancel()
            }
            transportState = .ready
            EngineLog.emit(
                "[BlackCarrierAVPlayerSession] transport ready",
                category: .session
            )
        } catch let error as BlackCarrierAVPlayerSessionError {
            cancelPendingReadiness(with: error)
            recordPreparationFailure(error)
            throw error
        } catch is CancellationError {
            let error =
                BlackCarrierAVPlayerSessionError.preparationCancelled
            cancelPendingReadiness(with: error)
            recordPreparationFailure(error)
            throw error
        } catch {
            let typed = BlackCarrierAVPlayerSessionError.assetLoadFailed(
                reason: String(describing: error)
            )
            cancelPendingReadiness(with: typed)
            recordPreparationFailure(typed)
            throw typed
        }
    }

    func stop() {
        guard lifecycle != .stopped else { return }
        routePreparationRetryEventHandler?(.completed)
        cancelPendingReadiness(with: .preparationCancelled)
        let mayRestorePlayerConfiguration = avPlayer.currentItem == nil
            || avPlayer.currentItem === installedItem
        if let installedItem,
           avPlayer.currentItem === installedItem {
            avPlayer.pause()
            avPlayer.replaceCurrentItem(with: nil)
        }
        restorePlayerConfiguration(
            ifOwned: mayRestorePlayerConfiguration
        )
        installedItem = nil
        server.stop()
        provider.close()
        playlistURL = nil
        lifecycle = .stopped
        transportState = .stopped
    }

    func setRoutePreparationRetryEventHandler(
        _ handler:
            (@MainActor @Sendable (
                AetherRoutePreparationRetryEvent
            ) -> Void)?
    ) {
        routePreparationRetryEventHandler = handler
    }

    private func failAndClose() {
        cancelPendingReadiness(with: .preparationCancelled)
        restorePlayerConfiguration(ifOwned: true)
        server.stop()
        provider.close()
        installedItem = nil
        playlistURL = nil
        lifecycle = .stopped
        transportState = .stopped
    }

    private func configurePlayerForCarrier() {
        guard previousAllowsExternalPlayback == nil else { return }
        previousAllowsExternalPlayback = avPlayer.allowsExternalPlayback
        avPlayer.allowsExternalPlayback = false
        #if os(iOS) || os(tvOS)
        previousUsesExternalPlaybackWhileExternalScreenIsActive =
            avPlayer.usesExternalPlaybackWhileExternalScreenIsActive
        avPlayer.usesExternalPlaybackWhileExternalScreenIsActive = false
        #endif
    }

    private func makeCarrierItem(
        playlistURL: URL
    ) -> AVPlayerItem {
        let asset = AVURLAsset(url: playlistURL)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = Double(
            BlackCarrierProfile.approved
                .nominalFileSegmentDurationTicks
        ) / Double(
            BlackCarrierProfile.approved.timescale
        )
        item.appliesPerFrameHDRDisplayMetadata =
            false
        item.canUseNetworkResourcesForLiveStreamingWhilePaused =
            false
        return item
    }

    private func restorePlayerConfiguration(ifOwned: Bool) {
        guard ifOwned,
              let previousAllowsExternalPlayback else { return }
        avPlayer.allowsExternalPlayback = previousAllowsExternalPlayback
        self.previousAllowsExternalPlayback = nil
        #if os(iOS) || os(tvOS)
        if let previous =
                previousUsesExternalPlaybackWhileExternalScreenIsActive {
            avPlayer.usesExternalPlaybackWhileExternalScreenIsActive =
                previous
        }
        previousUsesExternalPlaybackWhileExternalScreenIsActive = nil
        #endif
    }

    private func loadAndAwaitReady(
        item: AVPlayerItem,
        noProgressWindow: TimeInterval
    ) async throws
        -> BlackCarrierReadinessObservationResult
    {
        if let readinessAttemptOverride {
            return try await readinessAttemptOverride(
                item,
                noProgressWindow
            )
        }
        let playable: Bool
        do {
            playable = try await item.asset.load(.isPlayable)
        } catch {
            throw BlackCarrierAVPlayerSessionError.assetLoadFailed(
                reason: String(describing: error)
            )
        }
        guard playable else {
            throw BlackCarrierAVPlayerSessionError.assetNotPlayable
        }
        EngineLog.emit(
            "[BlackCarrierAVPlayerSession] asset playable; awaiting item status",
            category: .session
        )
        return try await awaitReadyStatus(
            item: item,
            noProgressWindow: noProgressWindow
        )
    }

    nonisolated static func
        isTransientReadinessFailure(
            _ error:
                BlackCarrierAVPlayerSessionError
        ) -> Bool {
        switch error {
        case .assetLoadFailed, .itemFailed:
            return true
        case .notStarted, .alreadyStarted,
             .alreadyStopped, .providerPreparationFailed,
             .serverStartFailed, .playlistURLUnavailable,
             .assetNotPlayable, .preparationInProgress,
             .readinessTimedOut, .preparationCancelled:
            return false
        }
    }

    private func awaitReadyStatus(
        item: AVPlayerItem,
        noProgressWindow: TimeInterval
    ) async throws
        -> BlackCarrierReadinessObservationResult
    {
        let noProgressTask = Task {
            @MainActor [weak self, weak item] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(
                        noProgressWindow
                            * 1_000_000_000
                    )
                )
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let item else {
                return
            }
            self?
                .completePendingReadinessWithoutProgress(
                    for: item
                )
        }
        defer {
            noProgressTask.cancel()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                readinessContinuation = continuation
                readinessObservedItem = item
                statusObservation = item.observe(
                    \.status,
                    options: [.initial, .new]
                ) { [weak self, weak item] _, _ in
                    guard let item else { return }
                    let status = item.status
                    let reason = item.error?.localizedDescription
                        ?? "AVPlayerItem failed without an error description"
                    Task { @MainActor [weak self] in
                        switch status {
                        case .readyToPlay:
                            self?.completePendingReadiness(
                                for: item
                            )
                        case .failed:
                            self?.cancelPendingReadiness(
                                for: item,
                                with: .itemFailed(reason: reason)
                            )
                        case .unknown:
                            break
                        @unknown default:
                            break
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingReadiness(with: .preparationCancelled)
            }
        }
    }

    private func completePendingReadiness(
        for item: AVPlayerItem
    ) {
        guard readinessObservedItem === item else {
            return
        }
        let continuation = readinessContinuation
        readinessContinuation = nil
        readinessObservedItem = nil
        statusObservation?.invalidate()
        statusObservation = nil
        continuation?.resume(returning: .ready)
    }

    private func completePendingReadinessWithoutProgress(
        for item: AVPlayerItem
    ) {
        guard readinessObservedItem === item else {
            return
        }
        let continuation = readinessContinuation
        readinessContinuation = nil
        readinessObservedItem = nil
        statusObservation?.invalidate()
        statusObservation = nil
        continuation?.resume(returning: .noProgress)
    }

    private func cancelPendingReadiness(
        with error: BlackCarrierAVPlayerSessionError
    ) {
        let continuation = readinessContinuation
        readinessContinuation = nil
        readinessObservedItem = nil
        statusObservation?.invalidate()
        statusObservation = nil
        continuation?.resume(throwing: error)
    }

    private func cancelPendingReadiness(
        for item: AVPlayerItem,
        with error: BlackCarrierAVPlayerSessionError
    ) {
        guard readinessObservedItem === item else {
            return
        }
        cancelPendingReadiness(with: error)
    }

    private func recordPreparationFailure(
        _ error: BlackCarrierAVPlayerSessionError
    ) {
        routePreparationRetryEventHandler?(.completed)
        guard lifecycle != .stopped else {
            transportState = .stopped
            return
        }
        transportState = .failed(error)
        EngineLog.emit(
            "[BlackCarrierAVPlayerSession] transport readiness failed: "
                + error.localizedDescription,
            category: .session
        )
    }

}
