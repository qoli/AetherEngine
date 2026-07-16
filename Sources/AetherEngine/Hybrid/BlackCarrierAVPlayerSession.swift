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
    case serverStartFailed(reason: String)
    case playlistURLUnavailable

    var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            return "Black carrier AVPlayer session is already started"
        case .alreadyStopped:
            return "Black carrier AVPlayer session is already stopped"
        case .serverStartFailed(let reason):
            return "Black carrier HLS server could not start: \(reason)"
        case .playlistURLUnavailable:
            return "Black carrier HLS server did not publish a playlist URL"
        }
    }
}

/// AVPlayer transport surface for a prebuilt black-video / real-audio carrier.
///
/// This type deliberately does not play, seek, render real video, or own readiness policy. The
/// eventual HybridPlaybackSession composes it with the decoder, Metal renderer, AVPlayer clock
/// adapter, and generation gates. Call `stop()` before releasing the session.
@MainActor
final class BlackCarrierAVPlayerSession {
    private enum Lifecycle {
        case idle
        case started
        case stopped
    }

    let avPlayer: AVPlayer
    private(set) var playlistURL: URL?

    private let provider: BlackCarrierCompositeProvider
    private let server: HLSLocalServer
    private var lifecycle: Lifecycle = .idle

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
    }

    func stop() {
        guard lifecycle != .stopped else { return }
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        server.stop()
        provider.close()
        playlistURL = nil
        lifecycle = .stopped
    }

    private func failAndClose() {
        server.stop()
        provider.close()
        playlistURL = nil
        lifecycle = .stopped
    }
}
