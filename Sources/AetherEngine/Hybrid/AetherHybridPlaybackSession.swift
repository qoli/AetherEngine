import AVFoundation
import Combine
import CoreMedia
import Foundation
import Metal

#if os(tvOS)
import AVKit
#endif

enum HybridCarrierPresentationContract {
    static func configurationFailure(
        sessionIsIdle: Bool
    ) -> HybridPlaybackSessionError? {
        sessionIsIdle
            ? nil
            : .carrierPresentationConfigurationTooLate
    }

    static func failure(
        wasConfigured: Bool,
        playerControllerAvailable: Bool,
        playerMatchesSession: Bool,
        carrierUsesAspectFit: Bool,
        automaticallyAppliesDisplayCriteria: Bool,
        metalOverlayAttached: Bool
    ) -> HybridPlaybackSessionError? {
        guard wasConfigured else {
            return .carrierPresentationNotConfigured
        }
        guard playerControllerAvailable,
              playerMatchesSession,
              carrierUsesAspectFit,
              !automaticallyAppliesDisplayCriteria,
              metalOverlayAttached else {
            return .carrierPresentationContractChanged
        }
        return nil
    }
}

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
    public let realVideoFrameRate: Double?
    public let timelineDurationSeconds: Double
    public let carrierTimeSeconds: Double?
    public let carrierRate: Float
    public let carrierTimeControlStatus: HybridCarrierTimeControlStatus
    public let carrierForwardBufferSeconds: Double?
    public let audioAnalysisPlaybackPressure:
        HybridAudioAnalysisPlaybackPressure
    public let audioAnalysisForwardBufferPressureThresholdSeconds:
        Double
    public let audioAnalysisTrackIDs: [Int]
    public let activeAudioAnalysisRequestCount: Int
    public let carrierBandwidth:
        AetherHybridCarrierBandwidthTelemetry
    public let renderer: AetherMetalPlayerView.Diagnostics
    public let systemFeaturePolicy: HybridPlaybackSystemFeaturePolicy

    init(
        preflightResult: PlaybackPreflightResult,
        state: HybridPlaybackSessionState,
        generation: UInt64,
        videoFormat: VideoFormat,
        realVideoFrameRate: Double?,
        timelineDurationSeconds: Double,
        carrierTimeSeconds: Double?,
        carrierRate: Float,
        carrierTimeControlStatus: HybridCarrierTimeControlStatus,
        carrierForwardBufferSeconds: Double?,
        audioAnalysisPlaybackPressure:
            HybridAudioAnalysisPlaybackPressure,
        audioAnalysisForwardBufferPressureThresholdSeconds:
            Double,
        audioAnalysisTrackIDs: [Int],
        activeAudioAnalysisRequestCount: Int,
        carrierBandwidth:
            AetherHybridCarrierBandwidthTelemetry,
        renderer: AetherMetalPlayerView.Diagnostics,
        systemFeaturePolicy: HybridPlaybackSystemFeaturePolicy
    ) {
        self.preflightResult = preflightResult
        self.state = state
        self.generation = generation
        self.videoFormat = videoFormat
        self.realVideoFrameRate = realVideoFrameRate
        self.timelineDurationSeconds = timelineDurationSeconds
        self.carrierTimeSeconds = carrierTimeSeconds
        self.carrierRate = carrierRate
        self.carrierTimeControlStatus = carrierTimeControlStatus
        self.carrierForwardBufferSeconds =
            carrierForwardBufferSeconds
        self.audioAnalysisPlaybackPressure =
            audioAnalysisPlaybackPressure
        self.audioAnalysisForwardBufferPressureThresholdSeconds =
            audioAnalysisForwardBufferPressureThresholdSeconds
        self.audioAnalysisTrackIDs = audioAnalysisTrackIDs
        self.activeAudioAnalysisRequestCount = activeAudioAnalysisRequestCount
        self.carrierBandwidth = carrierBandwidth
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
    /// Clear, finite, seekable HLS VOD is admitted only through an opaque
    /// `AetherHLSPlaybackPreflight` resource binding. The verified renderer remains SDR-only;
    /// unsupported color formats are rejected by preflight rather than tone-mapped.
    public nonisolated static var capabilities: HybridPlaybackCapabilities {
        HybridPlaybackCapabilities(
            hasDirectVideoDecoder: true,
            hasMetalRenderer: MTLCreateSystemDefaultDevice() != nil,
            supportedVideoFormats: AetherMetalPlayerView
                .verifiedVideoFormats,
            supportedSourceKinds: [
                .hls,
                .progressive,
                .custom,
            ]
        )
    }

    public nonisolated static let systemFeaturePolicy =
        HybridPlaybackSystemFeaturePolicy.firstRelease

    public let preflightResult: PlaybackPreflightResult
    public let avPlayer: AVPlayer
    public let metalPlayerView: AetherMetalPlayerView
    public let timeline: BlackCarrierTimeline
    public let telemetrySessionID: UUID

    @Published public private(set) var state:
        HybridPlaybackSessionState

    private let core: HybridPlaybackSession
    private let telemetryHub:
        AetherHybridPlaybackTelemetryHub
    #if os(tvOS)
    private weak var configuredCarrierPlayerViewController:
        AVPlayerViewController?
    private var didConfigureCarrierPlayerViewController = false
    #endif

    private init(
        core: HybridPlaybackSession,
        preflightResult: PlaybackPreflightResult,
        timeline: BlackCarrierTimeline,
        metalPlayerView: AetherMetalPlayerView
    ) {
        let telemetryHub =
            AetherHybridPlaybackTelemetryHub()
        self.core = core
        self.preflightResult = preflightResult
        self.timeline = timeline
        self.metalPlayerView = metalPlayerView
        self.telemetryHub = telemetryHub
        telemetrySessionID = telemetryHub.sessionID
        avPlayer = core.avPlayer
        state = core.state
        core.stateDidChange = { [weak self] state in
            guard let self else { return }
            self.state = state
            #if os(tvOS)
            switch state {
            case .failed, .stopped:
                self.detachCarrierPlayerViewControllerIfOwned()
            default:
                break
            }
            #endif
            self.publishTelemetry(.stateChanged)
        }
        core.telemetryDidChange = { [weak self] trigger in
            self?.publishTelemetry(
                Self.telemetryEventKind(for: trigger)
            )
        }
        publishTelemetry(.sessionCreated)
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
        guard preflightResult.sourceProfile.sourceKind
                != .hls else {
            throw HybridPlaybackSessionError
                .hlsPreflightRequired
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

    /// Construct a graph-bound Hybrid session from the exact HLS preflight used for route selection.
    ///
    /// The opaque preflight owns every selected playlist, init segment, media segment and request-header
    /// binding. This factory never reopens the root master, chooses another variant or falls through to
    /// native/legacy playback. A stale capability result, missing resource graph or invalidated origin
    /// generation fails explicitly.
    public static func makeHLSVOD(
        preflight: AetherHLSPlaybackPreflight,
        bridgeMode: AudioBridgeMode = .surroundCompat,
        initialGeneration: UInt64 = 0
    ) async throws -> AetherHybridPlaybackSession {
        try await makeHLSVOD(
            preflight: preflight,
            bridgeMode: bridgeMode,
            initialGeneration: initialGeneration,
            fetchOverride: nil
        )
    }

    static func makeHLSVOD(
        preflight: AetherHLSPlaybackPreflight,
        bridgeMode: AudioBridgeMode = .surroundCompat,
        initialGeneration: UInt64 = 0,
        fetchOverride:
            HLSVODOriginResourceLoader.Fetch?
    ) async throws -> AetherHybridPlaybackSession {
        guard preflight.result.route
                == .hybridCarrierMetal else {
            throw HybridPlaybackSessionError
                .preflightRequiresHybrid(
                    route: preflight.result.route,
                    reason: preflight.result.reason
                )
        }
        let currentResult = PlaybackPreflight.resolve(
            sourceProfile: preflight.result.sourceProfile,
            hlsPackaging: preflight.result.hlsPackaging,
            hybridCapabilities: capabilities
        )
        guard currentResult == preflight.result else {
            throw HybridPlaybackSessionError
                .preflightContractChanged(
                    route: currentResult.route,
                    reason: currentResult.reason
                )
        }
        guard preflight.result.sourceProfile.sourceKind
                == .hls else {
            throw HybridPlaybackSessionError
                .sourceKindMismatch(expected: .hls)
        }
        guard let resourceGraph = preflight.resourceGraph else {
            throw HybridPlaybackSessionError
                .hlsPreflightResourceGraphMissing
        }
        let timeline = resourceGraph.timeline
        guard timeline.source == .mirroredHLSVOD else {
            throw HybridPlaybackSessionError
                .timelineSourceMismatch(
                    sourceKind: .hls,
                    timelineSource: timeline.source
                )
        }

        let core: HybridPlaybackSession
        do {
            core = try await HybridPlaybackSession
                .makeHLSVOD(
                    preflight: preflight,
                    bridgeMode: bridgeMode,
                    initialGeneration:
                        initialGeneration,
                    fetchOverride: fetchOverride
                )
        } catch let error as HybridPlaybackSessionError {
            throw error
        } catch let error as AetherMetalRendererError {
            throw HybridPlaybackSessionError
                .rendererFailed(error)
        } catch {
            throw HybridPlaybackSessionError
                .providerFailed(
                    reason: String(describing: error)
                )
        }
        guard core.sourceVideoFormat
                == preflight.result.sourceProfile.videoFormat else {
            let decoded = core.sourceVideoFormat
            core.stop()
            throw HybridPlaybackSessionError
                .sourceVideoFormatDiverged(
                    preflight:
                        preflight.result.sourceProfile
                            .videoFormat,
                    decoded: decoded
                )
        }
        guard let metalPlayerView = core.metalPlayerView else {
            core.stop()
            throw HybridPlaybackSessionError
                .renderSurfaceMissing
        }
        return AetherHybridPlaybackSession(
            core: core,
            preflightResult: preflight.result,
            timeline: timeline,
            metalPlayerView: metalPlayerView
        )
    }

    public var audioAnalysisTrackIDs: [Int] {
        core.audioAnalysisTrackIDs
    }

    #if os(tvOS)
    /// Applies the non-negotiable tvOS carrier-host contract before presentation.
    ///
    /// AVKit remains the controller and audio/system-integration owner. Its fixed black carrier stays
    /// aspect-fit and cannot write display criteria from the SDR carrier; Aether's Metal view owns the real
    /// video's fit/fill policy while `HybridPlaybackSession` writes criteria from real-video metadata.
    /// The host must attach `metalPlayerView` beneath `contentOverlayView` before calling `prepare`.
    public func configureCarrierPlayerViewController(
        _ playerViewController: AVPlayerViewController,
        realVideoGravity: AetherHybridVideoGravity = .resizeAspect
    ) throws {
        if let error =
                HybridCarrierPresentationContract
                    .configurationFailure(
                        sessionIsIdle: state == .idle
                    ) {
            throw error
        }
        if let previous =
                configuredCarrierPlayerViewController,
           previous !== playerViewController,
           previous.player === avPlayer {
            previous.player = nil
        }
        playerViewController.player = avPlayer
        playerViewController.videoGravity = .resizeAspect
        playerViewController
            .appliesPreferredDisplayCriteriaAutomatically = false
        metalPlayerView.videoGravity = realVideoGravity
        configuredCarrierPlayerViewController =
            playerViewController
        didConfigureCarrierPlayerViewController = true
    }
    #endif

    /// Bounded, sequence-ordered telemetry for the complete public hybrid session lifecycle.
    ///
    /// Each subscriber receives up to the latest 64 events before live delivery. The stream finishes after
    /// `stop()`. Events never expose source URLs, request headers, credentials or arbitrary error strings.
    public func telemetryEvents()
        -> AsyncStream<AetherHybridPlaybackTelemetryEvent>
    {
        telemetryHub.stream()
    }

    public func audioAnalysisAvailability(
        for audioTrackID: Int
    ) -> AudioAnalysisTrackAvailability {
        core.audioAnalysisAvailability(
            for: audioTrackID
        )
    }

    public var diagnostics: AetherHybridPlaybackDiagnostics {
        let time = avPlayer.currentTime()
        return AetherHybridPlaybackDiagnostics(
            preflightResult: preflightResult,
            state: state,
            generation: core.generation,
            videoFormat: core.sourceVideoFormat,
            realVideoFrameRate:
                core.sourceVideoFrameRate,
            timelineDurationSeconds: timeline.duration.seconds,
            carrierTimeSeconds: Self.validSeconds(time),
            carrierRate: avPlayer.rate,
            carrierTimeControlStatus: Self.timeControlStatus(
                avPlayer.timeControlStatus
            ),
            carrierForwardBufferSeconds:
                core.carrierForwardBufferSeconds,
            audioAnalysisPlaybackPressure:
                core.audioAnalysisPlaybackPressure,
            audioAnalysisForwardBufferPressureThresholdSeconds:
                HybridPlaybackSession
                    .analysisForwardBufferPressureThresholdSeconds,
            audioAnalysisTrackIDs: core.audioAnalysisTrackIDs,
            activeAudioAnalysisRequestCount:
                core.activeAudioAnalysisRequestCount,
            carrierBandwidth:
                core.carrierBandwidthTelemetry,
            renderer: metalPlayerView.diagnostics,
            systemFeaturePolicy: Self.systemFeaturePolicy
        )
    }

    public func prepare(timeout: TimeInterval = 15) async throws {
        #if os(tvOS)
        try await core.prepare(timeout: timeout) { [self] in
            try validateCarrierPresentationContract()
        }
        #else
        try await core.prepare(timeout: timeout)
        #endif
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
        telemetryHub.finish()
    }

    #if os(tvOS)
    private func validateCarrierPresentationContract() throws {
        let playerViewController =
            configuredCarrierPlayerViewController
        let metalOverlayAttached: Bool
        if let overlay =
                playerViewController?.contentOverlayView {
            metalOverlayAttached =
                metalPlayerView.isDescendant(of: overlay)
        } else {
            metalOverlayAttached = false
        }
        if let error = HybridCarrierPresentationContract.failure(
                wasConfigured:
                    didConfigureCarrierPlayerViewController,
                playerControllerAvailable:
                    playerViewController != nil,
                playerMatchesSession:
                    playerViewController?.player === avPlayer,
                carrierUsesAspectFit:
                    playerViewController?.videoGravity
                        == .resizeAspect,
                automaticallyAppliesDisplayCriteria:
                    playerViewController?
                        .appliesPreferredDisplayCriteriaAutomatically
                        ?? true,
                metalOverlayAttached:
                    metalOverlayAttached
        ) {
            throw error
        }
    }

    private func detachCarrierPlayerViewControllerIfOwned() {
        if configuredCarrierPlayerViewController?.player
                === avPlayer {
            configuredCarrierPlayerViewController?.player = nil
        }
        configuredCarrierPlayerViewController = nil
        didConfigureCarrierPlayerViewController = false
    }
    #endif

    private func publishTelemetry(
        _ kind: AetherHybridPlaybackTelemetryEventKind
    ) {
        telemetryHub.emit(
            kind: kind,
            snapshot: telemetrySnapshot()
        )
    }

    private func telemetrySnapshot()
        -> AetherHybridPlaybackTelemetrySnapshot
    {
        let current = diagnostics
        return AetherHybridPlaybackTelemetrySnapshot(
            route: preflightResult.route,
            routeReason: preflightResult.reason,
            state:
                AetherHybridPlaybackTelemetryState(
                    current.state
                ),
            generation: current.generation,
            videoFormat: current.videoFormat,
            realVideoFrameRate:
                current.realVideoFrameRate,
            timelineDurationSeconds:
                current.timelineDurationSeconds,
            carrierTimeSeconds:
                current.carrierTimeSeconds,
            carrierRate: current.carrierRate,
            carrierTimeControlStatus:
                current.carrierTimeControlStatus,
            carrierForwardBufferSeconds:
                current.carrierForwardBufferSeconds,
            audioAnalysisPlaybackPressure:
                current.audioAnalysisPlaybackPressure,
            audioAnalysisTrackIDs:
                current.audioAnalysisTrackIDs,
            activeAudioAnalysisRequestCount:
                current.activeAudioAnalysisRequestCount,
            carrierBandwidth:
                current.carrierBandwidth,
            renderer: current.renderer,
            systemFeaturePolicy:
                current.systemFeaturePolicy
        )
    }

    private static func telemetryEventKind(
        for trigger: HybridPlaybackTelemetryTrigger
    ) -> AetherHybridPlaybackTelemetryEventKind {
        switch trigger {
        case .transportChanged:
            .transportChanged
        case .periodicSample:
            .periodicSample
        case .playbackPressureChanged:
            .playbackPressureChanged
        case .audioAnalysisChanged:
            .audioAnalysisChanged
        }
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
        case (.url, .progressive), (.custom, .custom):
            break
        default:
            throw HybridPlaybackSessionError
                .sourceKindMismatch(expected: sourceKind)
        }

        let timelineMatches = switch sourceKind {
        case .progressive, .custom:
            timeline.source == .fixedFileVOD
        case .hls:
            false
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
