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
}

public enum AetherNativePlaybackSessionError:
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
    case stopped
    case invalidRate
    case invalidSeekTarget

    public var errorDescription: String? {
        switch self {
        case .preflightRequiresNative(let route, let reason):
            "Native playback session requires a native preflight route, found \(route.rawValue) (\(reason.rawValue))"
        case .assetNotPlayable:
            "The native playback asset is not playable"
        case .stopped:
            "The native playback session has stopped"
        case .invalidRate:
            "The native playback rate is invalid"
        case .invalidSeekTarget:
            "The native playback seek target is invalid"
        }
    }
}

/// Aether-owned AVPlayer lifecycle for a preflight-admitted `.nativeAVPlayer` route.
///
/// The host may mount `avPlayer` in AVPlayerViewController and observe `state`, but it does not create or
/// replace the asset, player item or player. Terminal item failure remains on this session and never
/// selects the Hybrid or legacy route.
@MainActor
public final class AetherNativePlaybackSession: ObservableObject {
    public let preflightResult: PlaybackPreflightResult
    public let avPlayer: AVPlayer
    public let avPlayerItem: AVPlayerItem

    @Published public private(set) var state:
        AetherNativePlaybackSessionState = .idle

    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var isStopped = false

    private init(
        preflightResult: PlaybackPreflightResult,
        asset: AVURLAsset
    ) {
        self.preflightResult = preflightResult
        avPlayerItem = AVPlayerItem(asset: asset)
        avPlayer = AVPlayer(playerItem: avPlayerItem)
        avPlayer.actionAtItemEnd = .pause
        avPlayer.preventsDisplaySleepDuringVideoPlayback = true
        avPlayer.automaticallyWaitsToMinimizeStalling = true
        installObservers()
    }

    public static func make(
        url: URL,
        options: LoadOptions = .init(),
        preflightResult: PlaybackPreflightResult
    ) throws -> AetherNativePlaybackSession {
        guard preflightResult.route == .nativeAVPlayer else {
            throw AetherNativePlaybackSessionError
                .preflightRequiresNative(
                    route: preflightResult.route,
                    reason: preflightResult.reason
                )
        }
        var assetOptions: [String: Any] = [:]
        if !options.httpHeaders.isEmpty {
            assetOptions["AVURLAssetHTTPHeaderFieldsKey"] =
                options.httpHeaders
        }
        return AetherNativePlaybackSession(
            preflightResult: preflightResult,
            asset: AVURLAsset(url: url, options: assetOptions)
        )
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
        avPlayer.play()
        state = .playing
    }

    public func pause() throws {
        try requireActive()
        avPlayer.pause()
        state = .paused
    }

    public func setRate(_ rate: Float) throws {
        try requireActive()
        guard rate.isFinite, rate >= 0 else {
            throw AetherNativePlaybackSessionError.invalidRate
        }
        if rate == 0 {
            avPlayer.pause()
            state = .paused
        } else {
            avPlayer.rate = rate
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
        let finished = await withCheckedContinuation {
            (continuation: CheckedContinuation<Bool, Never>) in
            avPlayer.seek(
                to: target,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { finished in
                continuation.resume(returning: finished)
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

    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        state = .stopped
    }

    private func installObservers() {
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
    }

    private func requireActive() throws {
        guard !isStopped else {
            throw AetherNativePlaybackSessionError.stopped
        }
    }
}
