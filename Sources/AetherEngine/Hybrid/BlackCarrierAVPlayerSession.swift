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

/// AVPlayer transport surface for a prebuilt black-video / real-audio carrier.
///
/// This type deliberately does not play, seek, render real video, or own hybrid first-frame
/// readiness policy. It only proves the carrier transport reached `readyToPlay`. The eventual
/// HybridPlaybackSession composes it with the decoder, Metal renderer, AVPlayer clock adapter,
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

    private let provider: BlackCarrierCompositeProvider
    private let server: HLSLocalServer
    private var lifecycle: Lifecycle = .idle
    private var statusObservation: NSKeyValueObservation?
    private var readinessContinuation: CheckedContinuation<Void, Error>?
    private var preparationTimedOut = false

    init(provider: BlackCarrierCompositeProvider) {
        self.provider = provider
        server = HLSLocalServer(provider: provider)

        let player = AVPlayer()
        player.allowsExternalPlayback = false
        #if os(iOS) || os(tvOS)
        player.usesExternalPlaybackWhileExternalScreenIsActive = false
        #endif
        avPlayer = player
    }

    func start() throws {
        switch lifecycle {
        case .idle:
            break
        case .started:
            throw BlackCarrierAVPlayerSessionError.alreadyStarted
        case .stopped:
            throw BlackCarrierAVPlayerSessionError.alreadyStopped
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

        let asset = AVURLAsset(url: playlistURL)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = Double(
            BlackCarrierProfile.approved.nominalFileSegmentDurationTicks
        ) / Double(BlackCarrierProfile.approved.timescale)
        item.appliesPerFrameHDRDisplayMetadata = false
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        avPlayer.replaceCurrentItem(with: item)

        self.playlistURL = playlistURL
        lifecycle = .started
        transportState = .started
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
        guard timeout > 0 else {
            let error = BlackCarrierAVPlayerSessionError.readinessTimedOut(
                seconds: timeout
            )
            transportState = .failed(error)
            throw error
        }
        guard let item = avPlayer.currentItem else {
            let error = BlackCarrierAVPlayerSessionError.notStarted
            transportState = .failed(error)
            throw error
        }

        transportState = .preparing
        preparationTimedOut = false
        let timeoutError = BlackCarrierAVPlayerSessionError.readinessTimedOut(
            seconds: timeout
        )
        let readinessTask = Task { @MainActor [weak self] in
            guard let self else {
                throw BlackCarrierAVPlayerSessionError.preparationCancelled
            }
            try await self.loadAndAwaitReady(item: item)
        }
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(timeout * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            self?.markPreparationTimedOutAndCancel(readinessTask)
        }
        defer {
            timeoutTask.cancel()
            readinessTask.cancel()
            preparationTimedOut = false
        }
        do {
            try await withTaskCancellationHandler {
                try await readinessTask.value
            } onCancel: {
                readinessTask.cancel()
            }
            if preparationTimedOut {
                throw timeoutError
            }
            transportState = .ready
            EngineLog.emit(
                "[BlackCarrierAVPlayerSession] transport ready",
                category: .session
            )
        } catch let error as BlackCarrierAVPlayerSessionError {
            let resolved = preparationTimedOut ? timeoutError : error
            cancelPendingReadiness(with: resolved)
            recordPreparationFailure(resolved)
            throw resolved
        } catch is CancellationError {
            let error = preparationTimedOut
                ? timeoutError
                : BlackCarrierAVPlayerSessionError.preparationCancelled
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
        cancelPendingReadiness(with: .preparationCancelled)
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        server.stop()
        provider.close()
        playlistURL = nil
        lifecycle = .stopped
        transportState = .stopped
    }

    private func failAndClose() {
        cancelPendingReadiness(with: .preparationCancelled)
        server.stop()
        provider.close()
        playlistURL = nil
        lifecycle = .stopped
        transportState = .stopped
    }

    private func loadAndAwaitReady(item: AVPlayerItem) async throws {
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
        try await awaitReadyStatus(item: item)
    }

    private func awaitReadyStatus(item: AVPlayerItem) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                readinessContinuation = continuation
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
                            self?.completePendingReadiness()
                        case .failed:
                            self?.cancelPendingReadiness(
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

    private func completePendingReadiness() {
        let continuation = readinessContinuation
        readinessContinuation = nil
        statusObservation?.invalidate()
        statusObservation = nil
        continuation?.resume()
    }

    private func cancelPendingReadiness(
        with error: BlackCarrierAVPlayerSessionError
    ) {
        let continuation = readinessContinuation
        readinessContinuation = nil
        statusObservation?.invalidate()
        statusObservation = nil
        continuation?.resume(throwing: error)
    }

    private func recordPreparationFailure(
        _ error: BlackCarrierAVPlayerSessionError
    ) {
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

    private func markPreparationTimedOutAndCancel(
        _ readinessTask: Task<Void, Error>
    ) {
        guard lifecycle == .started,
              transportState == .preparing else {
            return
        }
        preparationTimedOut = true
        readinessTask.cancel()
    }
}
