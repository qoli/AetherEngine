import AVFoundation
import Combine
import CoreMedia
import Foundation
import Metal

/// System video-output features whose presentation surface is outside the inline AVKit hierarchy.
///
/// The first production hybrid contract does not move the engine-owned Metal surface into any of these
/// destinations. A host must use this policy to disable the corresponding controls; it must not infer
/// support from the carrier AVPlayer alone.
public enum HybridPlaybackSystemFeature: String, Sendable, Equatable, CaseIterable {
    case pictureInPictureVideo
    case airPlayVideo
    case externalDisplayVideo
}

public enum HybridPlaybackSystemFeatureRestriction: String, Sendable, Equatable {
    case metalOverlayUnavailableInPictureInPicture
    case metalOverlayUnavailableOnAirPlayReceiver
    case metalOverlayUnavailableOnExternalDisplay
}

public enum HybridPlaybackSystemFeatureAvailability: Sendable, Equatable {
    case available
    case unavailable(HybridPlaybackSystemFeatureRestriction)
}

/// Explicit host policy for features that AVPlayer could otherwise appear to support through the black
/// carrier alone.
public struct HybridPlaybackSystemFeaturePolicy: Sendable, Equatable {
    public let pictureInPictureVideo: HybridPlaybackSystemFeatureAvailability
    public let airPlayVideo: HybridPlaybackSystemFeatureAvailability
    public let externalDisplayVideo: HybridPlaybackSystemFeatureAvailability

    public init(
        pictureInPictureVideo: HybridPlaybackSystemFeatureAvailability,
        airPlayVideo: HybridPlaybackSystemFeatureAvailability,
        externalDisplayVideo: HybridPlaybackSystemFeatureAvailability
    ) {
        self.pictureInPictureVideo = pictureInPictureVideo
        self.airPlayVideo = airPlayVideo
        self.externalDisplayVideo = externalDisplayVideo
    }

    public func availability(
        for feature: HybridPlaybackSystemFeature
    ) -> HybridPlaybackSystemFeatureAvailability {
        switch feature {
        case .pictureInPictureVideo:
            pictureInPictureVideo
        case .airPlayVideo:
            airPlayVideo
        case .externalDisplayVideo:
            externalDisplayVideo
        }
    }

    public static let firstRelease = HybridPlaybackSystemFeaturePolicy(
        pictureInPictureVideo: .unavailable(
            .metalOverlayUnavailableInPictureInPicture
        ),
        airPlayVideo: .unavailable(
            .metalOverlayUnavailableOnAirPlayReceiver
        ),
        externalDisplayVideo: .unavailable(
            .metalOverlayUnavailableOnExternalDisplay
        )
    )
}

/// Sendable mirror of `AVPlayer.TimeControlStatus` for diagnostics persistence and telemetry.
public enum HybridCarrierTimeControlStatus: String, Sendable, Equatable {
    case paused
    case waitingToPlayAtSpecifiedRate
    case playing
}

/// On-demand, structured snapshot of the public hybrid session boundary.
///
/// This intentionally reports the carrier clock and the engine renderer together. A host must not treat a
/// ready AVPlayer item as proof that the real-video generation is ready.
public struct AetherHybridPlaybackDiagnostics: Sendable, Equatable {
    public let preflightResult: PlaybackPreflightResult
    public let state: HybridPlaybackSessionState
    public let generation: UInt64
    public let videoFormat: VideoFormat
    public let timelineDurationSeconds: Double
    public let carrierTimeSeconds: Double?
    public let carrierRate: Float
    public let carrierTimeControlStatus: HybridCarrierTimeControlStatus
    public let audioAnalysisTrackIDs: [Int]
    public let activeAudioAnalysisRequestCount: Int
    public let renderer: AetherMetalPlayerView.Diagnostics
    public let systemFeaturePolicy: HybridPlaybackSystemFeaturePolicy

    init(
        preflightResult: PlaybackPreflightResult,
        state: HybridPlaybackSessionState,
        generation: UInt64,
        videoFormat: VideoFormat,
        timelineDurationSeconds: Double,
        carrierTimeSeconds: Double?,
        carrierRate: Float,
        carrierTimeControlStatus: HybridCarrierTimeControlStatus,
        audioAnalysisTrackIDs: [Int],
        activeAudioAnalysisRequestCount: Int,
        renderer: AetherMetalPlayerView.Diagnostics,
        systemFeaturePolicy: HybridPlaybackSystemFeaturePolicy
    ) {
        self.preflightResult = preflightResult
        self.state = state
        self.generation = generation
        self.videoFormat = videoFormat
        self.timelineDurationSeconds = timelineDurationSeconds
        self.carrierTimeSeconds = carrierTimeSeconds
        self.carrierRate = carrierRate
        self.carrierTimeControlStatus = carrierTimeControlStatus
        self.audioAnalysisTrackIDs = audioAnalysisTrackIDs
        self.activeAudioAnalysisRequestCount = activeAudioAnalysisRequestCount
        self.renderer = renderer
        self.systemFeaturePolicy = systemFeaturePolicy
    }
}

/// Public host lifecycle for AetherEngine's `.hybridCarrierMetal` route.
///
/// The host receives exactly one AVPlayer for AVPlayerViewController and one engine-owned Metal view for
/// `contentOverlayView`. It never receives the provider, demuxer, decoder, frame queue or source-byte store.
/// Call `stop()` when the playback page is dismissed.
@MainActor
public final class AetherHybridPlaybackSession: ObservableObject {
    /// Capabilities that the current public session can actually admit.
    ///
    /// HLS is deliberately absent until its playlist/segment resource graph has the same validated
    /// byte-identity and cancellation guarantees as progressive/custom VOD. The verified renderer remains
    /// SDR-only; unsupported color formats are rejected by preflight rather than tone-mapped.
    public nonisolated static var capabilities: HybridPlaybackCapabilities {
        HybridPlaybackCapabilities(
            hasDirectVideoDecoder: true,
            hasMetalRenderer: MTLCreateSystemDefaultDevice() != nil,
            supportedVideoFormats: AetherMetalPlayerView
                .verifiedVideoFormats,
            supportedSourceKinds: [.progressive, .custom]
        )
    }

    public nonisolated static let systemFeaturePolicy =
        HybridPlaybackSystemFeaturePolicy.firstRelease

    public let preflightResult: PlaybackPreflightResult
    public let avPlayer: AVPlayer
    public let metalPlayerView: AetherMetalPlayerView
    public let timeline: BlackCarrierTimeline

    @Published public private(set) var state:
        HybridPlaybackSessionState

    private let core: HybridPlaybackSession

    private init(
        core: HybridPlaybackSession,
        preflightResult: PlaybackPreflightResult,
        timeline: BlackCarrierTimeline,
        metalPlayerView: AetherMetalPlayerView
    ) {
        self.core = core
        self.preflightResult = preflightResult
        self.timeline = timeline
        self.metalPlayerView = metalPlayerView
        avPlayer = core.avPlayer
        state = core.state
        core.stateDidChange = { [weak self] state in
            self?.state = state
        }
    }

    /// Construct a session only from the exact preflight result used by the host route decision.
    ///
    /// The result is resolved again against current public capabilities before any provider or network
    /// reader is built. A stale/forged route therefore fails explicitly and cannot fall through to another
    /// player or renderer.
    public static func makeSeekableVOD(
        source: MediaSource,
        options: LoadOptions,
        timeline: BlackCarrierTimeline,
        preflightResult: PlaybackPreflightResult,
        initialGeneration: UInt64 = 0,
        selectTitleID: Int? = nil
    ) async throws -> AetherHybridPlaybackSession {
        guard preflightResult.route == .hybridCarrierMetal else {
            throw HybridPlaybackSessionError.preflightRequiresHybrid(
                route: preflightResult.route,
                reason: preflightResult.reason
            )
        }

        let currentResult = PlaybackPreflight.resolve(
            sourceProfile: preflightResult.sourceProfile,
            hlsPackaging: preflightResult.hlsPackaging,
            hybridCapabilities: capabilities
        )
        guard currentResult == preflightResult else {
            throw HybridPlaybackSessionError
                .preflightContractChanged(
                    route: currentResult.route,
                    reason: currentResult.reason
                )
        }
        try validate(
            source: source,
            options: options,
            timeline: timeline,
            sourceKind: preflightResult.sourceProfile.sourceKind
        )

        let core: HybridPlaybackSession
        do {
            core = try await HybridPlaybackSession.makeSeekableVOD(
                source: source,
                options: options,
                timeline: timeline,
                initialGeneration: initialGeneration,
                selectTitleID: selectTitleID
            )
        } catch let error as HybridPlaybackSessionError {
            throw error
        } catch BlackCarrierDemuxSourceFactoryError
                    .independentReaderUnavailable {
            throw HybridPlaybackSessionError
                .sourceIndependentReaderUnavailable
        } catch let error as AetherMetalRendererError {
            throw HybridPlaybackSessionError.rendererFailed(error)
        } catch {
            throw HybridPlaybackSessionError.providerFailed(
                reason: String(describing: error)
            )
        }
        guard core.sourceVideoFormat
                == preflightResult.sourceProfile.videoFormat else {
            let decoded = core.sourceVideoFormat
            core.stop()
            throw HybridPlaybackSessionError
                .sourceVideoFormatDiverged(
                    preflight: preflightResult.sourceProfile.videoFormat,
                    decoded: decoded
                )
        }
        guard let metalPlayerView = core.metalPlayerView else {
            core.stop()
            throw HybridPlaybackSessionError.renderSurfaceMissing
        }
        return AetherHybridPlaybackSession(
            core: core,
            preflightResult: preflightResult,
            timeline: timeline,
            metalPlayerView: metalPlayerView
        )
    }

    public var audioAnalysisTrackIDs: [Int] {
        core.audioAnalysisTrackIDs
    }

    public var diagnostics: AetherHybridPlaybackDiagnostics {
        let time = avPlayer.currentTime()
        return AetherHybridPlaybackDiagnostics(
            preflightResult: preflightResult,
            state: state,
            generation: core.generation,
            videoFormat: core.sourceVideoFormat,
            timelineDurationSeconds: timeline.duration.seconds,
            carrierTimeSeconds: Self.validSeconds(time),
            carrierRate: avPlayer.rate,
            carrierTimeControlStatus: Self.timeControlStatus(
                avPlayer.timeControlStatus
            ),
            audioAnalysisTrackIDs: core.audioAnalysisTrackIDs,
            activeAudioAnalysisRequestCount:
                core.activeAudioAnalysisRequestCount,
            renderer: metalPlayerView.diagnostics,
            systemFeaturePolicy: Self.systemFeaturePolicy
        )
    }

    public func prepare(timeout: TimeInterval = 15) async throws {
        try await core.prepare(timeout: timeout)
    }

    public func play() throws {
        try core.play()
    }

    public func pause() throws {
        try core.pause()
    }

    public func setRate(_ rate: Float) throws {
        try core.setRate(rate)
    }

    public func seek(
        to target: CMTime,
        timeout: TimeInterval = 15
    ) async throws -> HybridPlaybackSeekResult {
        try await core.seek(to: target, timeout: timeout)
    }

    public func audioAnalysisStream(
        request: AudioAnalysisRequest
    ) throws -> AudioAnalysisStream {
        try core.audioAnalysisStream(request: request)
    }

    public func cancelAudioAnalysisStreams() {
        core.cancelAudioAnalysisStreams()
    }

    public func stop() {
        core.stop()
    }

    private static func validate(
        source: MediaSource,
        options: LoadOptions,
        timeline: BlackCarrierTimeline,
        sourceKind: AetherMediaSourceKind
    ) throws {
        guard !options.isLive,
              !options.audioOnly,
              options.dvrWindowSeconds == nil,
              !options.nativeRemoteHLS else {
            throw HybridPlaybackSessionError
                .invalidSeekableVODOptions
        }

        switch (source, sourceKind) {
        case (.url, .hls), (.url, .progressive),
             (.custom, .custom):
            break
        default:
            throw HybridPlaybackSessionError
                .sourceKindMismatch(expected: sourceKind)
        }

        let timelineMatches = switch sourceKind {
        case .hls:
            timeline.source == .mirroredHLSVOD
        case .progressive, .custom:
            timeline.source == .fixedFileVOD
        }
        guard timelineMatches else {
            throw HybridPlaybackSessionError
                .timelineSourceMismatch(
                    sourceKind: sourceKind,
                    timelineSource: timeline.source
                )
        }
    }

    private static func validSeconds(_ time: CMTime) -> Double? {
        guard time.isValid, time.isNumeric else { return nil }
        let seconds = time.seconds
        return seconds.isFinite ? seconds : nil
    }

    private static func timeControlStatus(
        _ status: AVPlayer.TimeControlStatus
    ) -> HybridCarrierTimeControlStatus {
        switch status {
        case .paused:
            .paused
        case .waitingToPlayAtSpecifiedRate:
            .waitingToPlayAtSpecifiedRate
        case .playing:
            .playing
        @unknown default:
            .paused
        }
    }
}
