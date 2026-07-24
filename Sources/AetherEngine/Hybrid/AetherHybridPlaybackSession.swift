import AVFoundation
import Combine
import CoreMedia
import Foundation
import Libavcodec

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
        presentationOverlayAttached: Bool
    ) -> HybridPlaybackSessionError? {
        guard wasConfigured else {
            return .carrierPresentationNotConfigured
        }
        guard playerControllerAvailable,
              playerMatchesSession,
              carrierUsesAspectFit,
              !automaticallyAppliesDisplayCriteria,
              presentationOverlayAttached else {
            return .carrierPresentationContractChanged
        }
        return nil
    }
}

/// System video-output features whose presentation surface is outside the inline AVKit hierarchy.
///
/// The first production hybrid contract does not move the engine-owned sample-buffer surface into any of these
/// destinations. A host must use this policy to disable the corresponding controls; it must not infer
/// support from the carrier AVPlayer alone.
public enum HybridPlaybackSystemFeature: String, Sendable, Equatable, CaseIterable {
    case pictureInPictureVideo
    case airPlayVideo
    case externalDisplayVideo
}

public enum HybridPlaybackSystemFeatureRestriction: String, Sendable, Equatable {
    case presentationOverlayUnavailableInPictureInPicture
    case presentationOverlayUnavailableOnAirPlayReceiver
    case presentationOverlayUnavailableOnExternalDisplay
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
            .presentationOverlayUnavailableInPictureInPicture
        ),
        airPlayVideo: .unavailable(
            .presentationOverlayUnavailableOnAirPlayReceiver
        ),
        externalDisplayVideo: .unavailable(
            .presentationOverlayUnavailableOnExternalDisplay
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
    public let selectedAudioAnalysisTrackID: Int?
    public let activeAudioAnalysisRequestCount: Int
    /// Decoder pre-roll rejected before renderer admission in the current generation.
    public let readinessPrerollFramesRejected: UInt64
    public let carrierBandwidth:
        AetherHybridCarrierBandwidthTelemetry
    public let realVideoBitrate:
        AetherHybridRealVideoBitrateTelemetry
    public let renderer: AetherHybridPresentationView.Diagnostics
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
        selectedAudioAnalysisTrackID: Int?,
        activeAudioAnalysisRequestCount: Int,
        readinessPrerollFramesRejected: UInt64,
        carrierBandwidth:
            AetherHybridCarrierBandwidthTelemetry,
        realVideoBitrate:
            AetherHybridRealVideoBitrateTelemetry,
        renderer: AetherHybridPresentationView.Diagnostics,
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
        self.selectedAudioAnalysisTrackID =
            selectedAudioAnalysisTrackID
        self.activeAudioAnalysisRequestCount = activeAudioAnalysisRequestCount
        self.readinessPrerollFramesRejected =
            readinessPrerollFramesRejected
        self.carrierBandwidth = carrierBandwidth
        self.realVideoBitrate = realVideoBitrate
        self.renderer = renderer
        self.systemFeaturePolicy = systemFeaturePolicy
    }
}

/// Public host lifecycle for AetherEngine's `.hybridCarrier` route.
///
/// The host receives exactly one AVPlayer for AVPlayerViewController and one engine-owned presentation view for
/// `contentOverlayView`. It never receives the provider, demuxer, decoder, frame queue or source-byte store.
/// Call `stop()` when the playback page is dismissed.
@MainActor
final class AetherHybridPlaybackSession: ObservableObject {
    /// Capabilities that the current public session can actually admit.
    ///
    /// Clear, finite, seekable HLS VOD is admitted only through an opaque
    /// `AetherHLSPlaybackPreflight` resource binding. The verified renderer admits
    /// SDR, HDR10, HLG, and verified Dolby Vision Profile 8.4; every other
    /// color format is rejected by preflight rather than tone-mapped.
    public nonisolated static var capabilities: HybridPlaybackCapabilities {
        var videoCodecs: Set<AetherVideoCodec> = []
        for (codec, codecID) in [
            (AetherVideoCodec.h264, AV_CODEC_ID_H264),
            (.prores, AV_CODEC_ID_PRORES),
            (.av1, AV_CODEC_ID_AV1),
            (.vp9, AV_CODEC_ID_VP9),
            (.vp8, AV_CODEC_ID_VP8),
            (.mpeg2, AV_CODEC_ID_MPEG2VIDEO),
            (.mpeg4Part2, AV_CODEC_ID_MPEG4),
            (.vc1, AV_CODEC_ID_VC1),
        ] where avcodec_find_decoder(codecID) != nil {
            videoCodecs.insert(codec)
        }
        var audioCodecs: Set<AetherAudioCodec> = []
        if avcodec_find_decoder(AV_CODEC_ID_PCM_S24LE) != nil {
            audioCodecs.insert(.pcmS24LE)
        }
        if avcodec_find_decoder(AV_CODEC_ID_VORBIS) != nil {
            audioCodecs.insert(.vorbis)
        }
        let audioBridgeModes = AudioBridge.supportedModes
        return HybridPlaybackCapabilities(
            hasDirectVideoDecoder: true,
            libavcodecDecodableVideoCodecs: videoCodecs,
            libavcodecDecodableAudioCodecs: audioCodecs,
            hasSampleBufferRenderer: true,
            hasAudioBridgeCarrier: !audioBridgeModes.isEmpty,
            supportedAudioBridgeModes: audioBridgeModes,
            supportedVideoFormats: AetherHybridPresentationView
                .verifiedVideoFormats,
            supportedDolbyVisionProfiles: [.profile84],
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
    public let presentationView: AetherHybridPresentationView
    public let timeline: BlackCarrierTimeline
    public let telemetrySessionID: UUID

    @Published public private(set) var state:
        HybridPlaybackSessionState
    @Published private(set) var videoOutputSnapshot:
        AetherVideoOutputSnapshot
    @Published public private(set) var overlaySubtitleTracks:
        [AetherHybridOverlaySubtitleTrack]
    @Published public private(set) var activeOverlaySubtitleTrackID:
        Int?
    /// Stable Aether source-track identity corresponding to AVKit's current
    /// audible selection. `nil` means the selection cannot be proven and
    /// independent analysis must stay unavailable.
    @Published public private(set) var selectedAudioAnalysisTrackID:
        Int?

    var audioTracks: [AetherPlaybackTrack] {
        core.audioTracks
    }

    var subtitleTracks: [AetherPlaybackTrack] {
        core.subtitleTracks
    }

    var selectedAudioTrackID: Int? {
        core.selectedAudioTrackID
    }

    var selectedSubtitleTrackIdentifier: String? {
        core.selectedSubtitleTrackIdentifier
    }

    private let core: HybridPlaybackSession
    private let telemetryHub:
        AetherHybridPlaybackTelemetryHub
    private var videoOutputSequence: UInt64 = 0
    var routePreparationRetryEventDidChange:
        (@MainActor @Sendable (
            AetherRoutePreparationRetryEvent
        ) -> Void)?
    #if os(tvOS)
    private weak var configuredCarrierPlayerViewController:
        AVPlayerViewController?
    private var didConfigureCarrierPlayerViewController = false
    private var hostTransportBarCustomMenuItems:
        [UIMenuElement] = []
    #endif

    private init(
        core: HybridPlaybackSession,
        preflightResult: PlaybackPreflightResult,
        timeline: BlackCarrierTimeline,
        presentationView: AetherHybridPresentationView
    ) {
        let telemetryHub =
            AetherHybridPlaybackTelemetryHub()
        self.core = core
        self.preflightResult = preflightResult
        self.timeline = timeline
        self.presentationView = presentationView
        self.telemetryHub = telemetryHub
        let videoExpected = preflightResult.sourceProfile
            .videoStreamPresence == .provenPresent
        videoOutputSnapshot = AetherVideoOutputSnapshot(
            videoExpected: videoExpected,
            outputStatus: videoExpected ? .missing : .notExpected,
            frameSequence: 0,
            frameGeneration: core.generation,
            lastPresentedFrameMediaTimeSeconds: nil,
            observedAtUptimeSeconds: nil,
            activeRoute: .hybridCarrier,
            canonicalCodec: videoExpected
                ? preflightResult.sourceProfile
                    .videoCodec.canonicalVideoOutputCodec
                : .none
        )
        telemetrySessionID = telemetryHub.sessionID
        avPlayer = core.avPlayer
        state = core.state
        overlaySubtitleTracks = core.overlaySubtitleTracks
        activeOverlaySubtitleTrackID =
            core.activeOverlaySubtitleTrackID
        selectedAudioAnalysisTrackID =
            core.selectedAudioAnalysisTrackID
        core.stateDidChange = { [weak self] state in
            guard let self else { return }
            self.state = state
            self.resetVideoOutputIfGenerationChanged(state)
            #if os(tvOS)
            switch state {
            case .failed, .stopped:
                self.releaseCarrierPlayerViewControllerContract()
            default:
                break
            }
            #endif
            self.publishTelemetry(for: state)
        }
        core.telemetryDidChange = { [weak self] trigger in
            self?.publishTelemetry(for: trigger)
        }
        core.presentedFrameDidChange = { [weak self] evidence in
            self?.publishPresentedFrame(evidence)
        }
        core.subtitleTracksDidChange = {
            [weak self] tracks, selectedTrackID in
            guard let self else { return }
            self.overlaySubtitleTracks = tracks
            self.activeOverlaySubtitleTrackID = selectedTrackID
            #if os(tvOS)
            self.installOverlaySubtitleMenuIfNeeded()
            #endif
        }
        core.selectedAudioAnalysisTrackIDDidChange = {
            [weak self] trackID in
            self?.selectedAudioAnalysisTrackID = trackID
        }
        core.routePreparationRetryEventDidChange = {
            [weak self] event in
            self?.routePreparationRetryEventDidChange?(event)
        }
        #if os(tvOS)
        core.runtimePresentationValidation = {
            [weak self] in
            guard let self else {
                throw HybridPlaybackSessionError
                    .carrierPresentationContractChanged
            }
            try self.validateCarrierPresentationContract()
        }
        #endif
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
        guard preflightResult.route == .hybridCarrier else {
            throw HybridPlaybackSessionError.preflightRequiresHybrid(
                route: preflightResult.route,
                reason: preflightResult.reason
            )
        }

        let currentResult = PlaybackPreflight.resolve(
            sourceProfile: preflightResult.sourceProfile,
            hlsPackaging: preflightResult.hlsPackaging,
            hybridCapabilities: capabilities,
            requiredAudioBridgeMode: options.audioBridgeMode
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
            if preflightResult.reason == .hybridAudioBridge,
               preflightResult.sourceProfile.videoStreamPresence
                    == .provenAbsent,
               preflightResult.sourceProfile.audioCodecs == [.vorbis] {
                core = try await HybridPlaybackSession
                    .makeAudioOnlySeekableVOD(
                        source: source,
                        options: options,
                        timeline: timeline,
                        initialGeneration: initialGeneration,
                        selectTitleID: selectTitleID
                    )
            } else {
                core = try await HybridPlaybackSession.makeSeekableVOD(
                    source: source,
                    options: options,
                    timeline: timeline,
                    initialGeneration: initialGeneration,
                    selectTitleID: selectTitleID
                )
            }
        } catch let error as HybridPlaybackSessionError {
            throw error
        } catch BlackCarrierDemuxSourceFactoryError
                    .independentReaderUnavailable {
            throw HybridPlaybackSessionError
                .sourceIndependentReaderUnavailable
        } catch let error as AetherHybridPresentationError {
            throw HybridPlaybackSessionError.presentationFailed(error)
        } catch {
            throw HybridPlaybackSessionError.providerFailed(
                HybridPlaybackFailureEvidence(
                    stage: .routeCreation,
                    caseCode: "progressiveProvider",
                    error: error
                )
            )
        }
        guard let sourceFacts = core.progressiveSourceFacts,
              sourceFacts.matches(
                preflightProfile: preflightResult.sourceProfile,
                timelineDurationSeconds:
                    CMTimeGetSeconds(timeline.duration)
              ) else {
            core.stop()
            throw HybridPlaybackSessionError
                .progressiveSourceFactsDiverged
        }
        guard preflightResult.sourceProfile.videoStreamPresence
                != .provenPresent
                || core.sourceVideoFormat
                    == preflightResult.sourceProfile.videoFormat else {
            let decoded = core.sourceVideoFormat
            core.stop()
            throw HybridPlaybackSessionError
                .sourceVideoFormatDiverged(
                    preflight: preflightResult.sourceProfile.videoFormat,
                    decoded: decoded
                )
        }
        guard core.sourceDolbyVisionConfiguration
                == preflightResult.sourceProfile
                    .dolbyVisionConfiguration else {
            core.stop()
            throw HybridPlaybackSessionError
                .sourceDolbyVisionConfigurationDiverged
        }
        guard let presentationView = core.presentationView else {
            core.stop()
            throw HybridPlaybackSessionError.renderSurfaceMissing
        }
        return AetherHybridPlaybackSession(
            core: core,
            preflightResult: preflightResult,
            timeline: timeline,
            presentationView: presentationView
        )
    }

    static func makeSeekableVOD(
        source: MediaSource,
        preparedURLSource: AetherPreparedURLSource? = nil,
        options: LoadOptions,
        timeline: BlackCarrierTimeline,
        preflightResult: PlaybackPreflightResult,
        avPlayer: AVPlayer,
        decoderPreference: HybridVideoDecoderPreference = .automatic,
        videoBacklogConfiguration:
            HybridCompressedVideoBacklogConfiguration = .production,
        videoBacklogScratchRoot: URL? = nil,
        initialGeneration: UInt64 = 0,
        selectTitleID: Int? = nil
    ) async throws -> AetherHybridPlaybackSession {
        try await makeInjectedSeekableVOD(
            source: source,
            preparedURLSource: preparedURLSource,
            options: options,
            timeline: timeline,
            preflightResult: preflightResult,
            avPlayer: avPlayer,
            decoderPreference: decoderPreference,
            videoBacklogConfiguration:
                videoBacklogConfiguration,
            videoBacklogScratchRoot:
                videoBacklogScratchRoot,
            initialGeneration: initialGeneration,
            selectTitleID: selectTitleID
        )
    }

    private static func makeInjectedSeekableVOD(
        source: MediaSource,
        preparedURLSource: AetherPreparedURLSource?,
        options: LoadOptions,
        timeline: BlackCarrierTimeline,
        preflightResult: PlaybackPreflightResult,
        avPlayer: AVPlayer,
        decoderPreference: HybridVideoDecoderPreference,
        videoBacklogConfiguration:
            HybridCompressedVideoBacklogConfiguration,
        videoBacklogScratchRoot: URL?,
        initialGeneration: UInt64,
        selectTitleID: Int?
    ) async throws -> AetherHybridPlaybackSession {
        guard preflightResult.route == .hybridCarrier else {
            throw HybridPlaybackSessionError.preflightRequiresHybrid(
                route: preflightResult.route,
                reason: preflightResult.reason
            )
        }
        let currentResult = PlaybackPreflight.resolve(
            sourceProfile: preflightResult.sourceProfile,
            hlsPackaging: preflightResult.hlsPackaging,
            hybridCapabilities: capabilities,
            requiredAudioBridgeMode: options.audioBridgeMode
        )
        guard currentResult == preflightResult else {
            throw HybridPlaybackSessionError.preflightContractChanged(
                route: currentResult.route,
                reason: currentResult.reason
            )
        }
        guard preflightResult.sourceProfile.sourceKind != .hls else {
            throw HybridPlaybackSessionError.hlsPreflightRequired
        }
        try validate(
            source: source,
            options: options,
            timeline: timeline,
            sourceKind: preflightResult.sourceProfile.sourceKind
        )
        let core: HybridPlaybackSession
        if preflightResult.reason == .hybridAudioBridge,
           preflightResult.sourceProfile.videoStreamPresence
                == .provenAbsent,
           preflightResult.sourceProfile.audioCodecs == [.vorbis] {
            core = try await HybridPlaybackSession
                .makeAudioOnlySeekableVOD(
                    source: source,
                    preparedURLSource: preparedURLSource,
                    options: options,
                    timeline: timeline,
                    avPlayer: avPlayer,
                    initialGeneration: initialGeneration,
                    selectTitleID: selectTitleID
                )
        } else {
            core = try await HybridPlaybackSession.makeSeekableVOD(
                source: source,
                preparedURLSource: preparedURLSource,
                options: options,
                timeline: timeline,
                avPlayer: avPlayer,
                decoderPreference: decoderPreference,
                videoBacklogConfiguration:
                    videoBacklogConfiguration,
                videoBacklogScratchRoot:
                    videoBacklogScratchRoot,
                initialGeneration: initialGeneration,
                selectTitleID: selectTitleID
            )
        }
        guard let sourceFacts = core.progressiveSourceFacts,
              sourceFacts.matches(
                preflightProfile: preflightResult.sourceProfile,
                timelineDurationSeconds:
                    CMTimeGetSeconds(timeline.duration)
              ) else {
            core.stop()
            throw HybridPlaybackSessionError
                .progressiveSourceFactsDiverged
        }
        guard preflightResult.sourceProfile.videoStreamPresence
                != .provenPresent
                || core.sourceVideoFormat
                    == preflightResult.sourceProfile.videoFormat else {
            let decoded = core.sourceVideoFormat
            core.stop()
            throw HybridPlaybackSessionError.sourceVideoFormatDiverged(
                preflight: preflightResult.sourceProfile.videoFormat,
                decoded: decoded
            )
        }
        guard core.sourceDolbyVisionConfiguration
                == preflightResult.sourceProfile.dolbyVisionConfiguration else {
            core.stop()
            throw HybridPlaybackSessionError.sourceDolbyVisionConfigurationDiverged
        }
        guard let presentationView = core.presentationView else {
            core.stop()
            throw HybridPlaybackSessionError.renderSurfaceMissing
        }
        return AetherHybridPlaybackSession(
            core: core,
            preflightResult: preflightResult,
            timeline: timeline,
            presentationView: presentationView
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
                == .hybridCarrier else {
            throw HybridPlaybackSessionError
                .preflightRequiresHybrid(
                    route: preflight.result.route,
                    reason: preflight.result.reason
                )
        }
        let currentResult = PlaybackPreflight.resolve(
            sourceProfile: preflight.result.sourceProfile,
            hlsPackaging: preflight.result.hlsPackaging,
            hybridCapabilities: capabilities,
            requiredAudioBridgeMode: bridgeMode
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
        } catch let error as AetherHybridPresentationError {
            throw HybridPlaybackSessionError
                .presentationFailed(error)
        } catch {
            throw HybridPlaybackSessionError
                .providerFailed(
                    HybridPlaybackFailureEvidence(
                        stage: .routeCreation,
                        caseCode: "hlsProvider",
                        error: error
                    )
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
        guard core.sourceDolbyVisionConfiguration
                == preflight.result.sourceProfile
                    .dolbyVisionConfiguration else {
            core.stop()
            throw HybridPlaybackSessionError
                .sourceDolbyVisionConfigurationDiverged
        }
        guard let presentationView = core.presentationView else {
            core.stop()
            throw HybridPlaybackSessionError
                .renderSurfaceMissing
        }
        return AetherHybridPlaybackSession(
            core: core,
            preflightResult: preflight.result,
            timeline: timeline,
            presentationView: presentationView
        )
    }

    static func makeHLSVOD(
        preflight: AetherHLSPlaybackPreflight,
        bridgeMode: AudioBridgeMode = .surroundCompat,
        avPlayer: AVPlayer,
        decoderPreference: HybridVideoDecoderPreference = .automatic,
        initialGeneration: UInt64 = 0,
        transportRetryBudget: PlaybackTransportRetryBudget = .init(
            maximumFailureAttempts: nil
        )
    ) async throws -> AetherHybridPlaybackSession {
        guard preflight.result.route == .hybridCarrier else {
            throw HybridPlaybackSessionError.preflightRequiresHybrid(
                route: preflight.result.route,
                reason: preflight.result.reason
            )
        }
        let currentResult = PlaybackPreflight.resolve(
            sourceProfile: preflight.result.sourceProfile,
            hlsPackaging: preflight.result.hlsPackaging,
            hybridCapabilities: capabilities,
            requiredAudioBridgeMode: bridgeMode
        )
        guard currentResult == preflight.result else {
            throw HybridPlaybackSessionError.preflightContractChanged(
                route: currentResult.route,
                reason: currentResult.reason
            )
        }
        guard preflight.result.sourceProfile.sourceKind == .hls else {
            throw HybridPlaybackSessionError.sourceKindMismatch(expected: .hls)
        }
        guard let resourceGraph = preflight.resourceGraph else {
            throw HybridPlaybackSessionError.hlsPreflightResourceGraphMissing
        }
        let core = try await HybridPlaybackSession.makeHLSVOD(
            preflight: preflight,
            bridgeMode: bridgeMode,
            avPlayer: avPlayer,
            decoderPreference: decoderPreference,
            initialGeneration: initialGeneration,
            transportRetryBudget: transportRetryBudget
        )
        guard core.sourceVideoFormat == preflight.result.sourceProfile.videoFormat else {
            let decoded = core.sourceVideoFormat
            core.stop()
            throw HybridPlaybackSessionError.sourceVideoFormatDiverged(
                preflight: preflight.result.sourceProfile.videoFormat,
                decoded: decoded
            )
        }
        guard core.sourceDolbyVisionConfiguration
                == preflight.result.sourceProfile.dolbyVisionConfiguration else {
            core.stop()
            throw HybridPlaybackSessionError.sourceDolbyVisionConfigurationDiverged
        }
        guard resourceGraph.timeline.source == .mirroredHLSVOD,
              let presentationView = core.presentationView else {
            core.stop()
            throw HybridPlaybackSessionError.renderSurfaceMissing
        }
        return AetherHybridPlaybackSession(
            core: core,
            preflightResult: preflight.result,
            timeline: resourceGraph.timeline,
            presentationView: presentationView
        )
    }

    public var audioAnalysisTrackIDs: [Int] {
        core.audioAnalysisTrackIDs
    }

    #if os(tvOS)
    /// Applies the non-negotiable tvOS carrier-host contract before presentation.
    ///
    /// AVKit remains the controller and audio/system-integration owner. Its fixed black carrier stays
    /// aspect-fit and cannot write display criteria from the SDR carrier; Aether's presentation view owns the real
    /// video's fit/fill policy while `HybridPlaybackSession` writes criteria from real-video metadata.
    /// The host must attach `presentationView` beneath `contentOverlayView` before calling `prepare`.
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
        let isReplacingController =
            configuredCarrierPlayerViewController != nil
                && configuredCarrierPlayerViewController
                    !== playerViewController
        if isReplacingController,
           let previous = configuredCarrierPlayerViewController {
            previous.transportBarCustomMenuItems =
                hostTransportBarCustomMenuItems
            if previous.player === avPlayer {
                previous.player = nil
            }
            hostTransportBarCustomMenuItems = []
        }
        playerViewController.player = avPlayer
        playerViewController.videoGravity = .resizeAspect
        playerViewController
            .appliesPreferredDisplayCriteriaAutomatically = false
        presentationView.videoGravity = realVideoGravity
        if configuredCarrierPlayerViewController
                !== playerViewController {
            hostTransportBarCustomMenuItems =
                playerViewController
                    .transportBarCustomMenuItems
        }
        configuredCarrierPlayerViewController =
            playerViewController
        installOverlaySubtitleMenuIfNeeded()
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
            selectedAudioAnalysisTrackID:
                core.selectedAudioAnalysisTrackID,
            activeAudioAnalysisRequestCount:
                core.activeAudioAnalysisRequestCount,
            readinessPrerollFramesRejected:
                core.readinessPrerollFramesRejected,
            carrierBandwidth:
                core.carrierBandwidthTelemetry,
            realVideoBitrate:
                core.realVideoBitrateTelemetry,
            renderer: presentationView.diagnostics,
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

    func setRoutePreparationProgressHandler(
        _ handler:
            (@Sendable (
                AetherRoutePreparationProgressKind
            ) -> Void)?
    ) {
        core.setRoutePreparationProgressHandler(handler)
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

    func pollVideoOutput() {
        core.pollPresentedVideoOutput()
    }

    public func audioAnalysisStream(
        request: AudioAnalysisRequest
    ) throws -> AudioAnalysisStream {
        try core.audioAnalysisStream(request: request)
    }

    public func cancelAudioAnalysisStreams() {
        core.cancelAudioAnalysisStreams()
    }

    /// Select one Aether-owned bitmap/styled subtitle track, or `nil` for
    /// off. Native WebVTT remains in AVKit's native media-selection menu.
    public func selectOverlaySubtitleTrack(
        _ trackID: Int?
    ) throws {
        try core.selectOverlaySubtitleTrack(trackID)
    }

    func selectAudioTrack(_ trackID: Int) async throws {
        try await core.selectAudioTrack(trackID)
    }

    func selectNativeSubtitleTrack(
        _ ordinal: Int?
    ) async throws {
        try await core.selectNativeSubtitleTrack(ordinal)
    }

    public func stop() {
        core.stop()
        telemetryHub.finish()
    }

    func stopAndWaitForIOQuiescence() async {
        await core.stopAndWaitForIOQuiescence()
        telemetryHub.finish()
    }

    private func resetVideoOutputIfGenerationChanged(
        _ state: HybridPlaybackSessionState
    ) {
        let generation: UInt64? = switch state {
        case .preparing(let generation, _),
             .ready(let generation),
             .seeking(let generation, _),
             .ended(let generation):
            generation
        case .idle, .failed, .stopped:
            nil
        }
        guard let generation,
              generation != videoOutputSnapshot.frameGeneration else {
            return
        }
        let videoExpected = preflightResult.sourceProfile
            .videoStreamPresence == .provenPresent
        videoOutputSnapshot = AetherVideoOutputSnapshot(
            videoExpected: videoExpected,
            outputStatus: videoExpected ? .missing : .notExpected,
            frameSequence: videoOutputSequence,
            frameGeneration: generation,
            lastPresentedFrameMediaTimeSeconds: nil,
            observedAtUptimeSeconds: nil,
            activeRoute: .hybridCarrier,
            canonicalCodec: videoExpected
                ? preflightResult.sourceProfile
                    .videoCodec.canonicalVideoOutputCodec
                : .none
        )
    }

    private func publishPresentedFrame(
        _ evidence: AetherHybridPresentedFrameEvidence
    ) {
        guard preflightResult.sourceProfile.videoStreamPresence
                == .provenPresent,
              evidence.generation == core.generation,
              evidence.mediaTimeSeconds.isFinite,
              evidence.observedAtUptimeSeconds.isFinite else {
            return
        }
        if evidence.generation
                != videoOutputSnapshot.frameGeneration {
            resetVideoOutputIfGenerationChanged(core.state)
        }
        guard evidence.generation
                == videoOutputSnapshot.frameGeneration else {
            return
        }
        videoOutputSequence &+= 1
        videoOutputSnapshot = AetherVideoOutputSnapshot(
            videoExpected: true,
            outputStatus: .presented,
            frameSequence: videoOutputSequence,
            frameGeneration: evidence.generation,
            lastPresentedFrameMediaTimeSeconds:
                evidence.mediaTimeSeconds,
            observedAtUptimeSeconds:
                evidence.observedAtUptimeSeconds,
            activeRoute: .hybridCarrier,
            canonicalCodec: preflightResult.sourceProfile
                .videoCodec.canonicalVideoOutputCodec
        )
    }

    #if os(tvOS)
    private func validateCarrierPresentationContract() throws {
        let playerViewController =
            configuredCarrierPlayerViewController
        let presentationOverlayAttached: Bool
        if let overlay =
                playerViewController?.contentOverlayView {
            presentationOverlayAttached =
                presentationView.isDescendant(of: overlay)
        } else {
            presentationOverlayAttached = false
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
                presentationOverlayAttached:
                    presentationOverlayAttached
        ) {
            throw error
        }
    }

    /// Releases Hybrid-specific menus and validation ownership without ever
    /// clearing the stable AVPlayer binding owned by AetherPlaybackSession.
    private func releaseCarrierPlayerViewControllerContract() {
        configuredCarrierPlayerViewController?
            .transportBarCustomMenuItems =
                hostTransportBarCustomMenuItems
        configuredCarrierPlayerViewController = nil
        didConfigureCarrierPlayerViewController = false
        hostTransportBarCustomMenuItems = []
    }

    private func installOverlaySubtitleMenuIfNeeded() {
        guard let controller =
                configuredCarrierPlayerViewController else {
            return
        }
        guard !overlaySubtitleTracks.isEmpty else {
            controller.transportBarCustomMenuItems =
                hostTransportBarCustomMenuItems
            return
        }
        let off = UIAction(
            title: "Off",
            state: activeOverlaySubtitleTrackID == nil
                ? .on
                : .off
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                do {
                    try self?.selectOverlaySubtitleTrack(nil)
                } catch {
                    let nsError = error as NSError
                    EngineLog.emit(
                        "[AetherHybridPlaybackSession] overlay subtitle off failed: "
                            + "domain=\(nsError.domain) code=\(nsError.code)",
                        category: .session
                    )
                }
            }
        }
        let actions = overlaySubtitleTracks.map { track in
            let action = UIAction(
                title: track.name,
                state: activeOverlaySubtitleTrackID == track.id
                    ? .on
                    : .off
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    do {
                        try self?.selectOverlaySubtitleTrack(track.id)
                    } catch {
                        let nsError = error as NSError
                        EngineLog.emit(
                            "[AetherHybridPlaybackSession] overlay subtitle selection failed trackID=\(track.id): "
                                + "domain=\(nsError.domain) code=\(nsError.code)",
                            category: .session
                        )
                    }
                }
            }
            if case .unavailable = track.availability {
                action.attributes.insert(.disabled)
            }
            return action
        }
        let menu = UIMenu(
            title: "Aether Subtitles",
            image: UIImage(systemName: "captions.bubble"),
            children: [off] + actions
        )
        controller.transportBarCustomMenuItems =
            hostTransportBarCustomMenuItems + [menu]
    }
    #endif

    private func publishTelemetry(
        _ kind: AetherHybridPlaybackTelemetryEventKind,
        payload: AetherHybridPlaybackTelemetryPayload = .none
    ) {
        telemetryHub.emit(
            kind: kind,
            payload: payload,
            snapshot: telemetrySnapshot()
        )
    }

    private func publishTelemetry(
        for state: HybridPlaybackSessionState
    ) {
        switch state {
        case .failed(let error):
            publishTelemetry(
                .sessionFailed,
                payload: .sessionFailed(
                    AetherHybridPlaybackTelemetryFailure(error)
                )
            )
        case .stopped:
            publishTelemetry(
                .sessionEnded,
                payload: .sessionEnded(.stoppedByHost)
            )
        case .idle, .preparing, .ready, .seeking, .ended:
            publishTelemetry(.stateChanged)
        }
    }

    private func publishTelemetry(
        for trigger: HybridPlaybackTelemetryTrigger
    ) {
        switch trigger {
        case .transportChanged:
            publishTelemetry(.transportChanged)
        case .videoFormatChanged:
            publishTelemetry(.videoFormatChanged)
        case .periodicSample(let playerTimeSeconds):
            let renderer = presentationView.diagnostics
            let lastEnqueuedTime =
                renderer.lastEnqueuedTimeSeconds
            let enqueueLeadMilliseconds: Double?
            if let lastEnqueuedTime,
               lastEnqueuedTime.isFinite {
                enqueueLeadMilliseconds =
                    (lastEnqueuedTime - playerTimeSeconds) * 1_000
            } else {
                enqueueLeadMilliseconds = nil
            }
            publishTelemetry(
                .sampleBufferQueueSample,
                payload: .sampleBufferQueueSample(
                    AetherHybridSampleBufferQueueTelemetry(
                        playerTimeSeconds:
                            playerTimeSeconds,
                        lastEnqueuedTimeSeconds:
                            lastEnqueuedTime,
                        enqueueLeadMilliseconds:
                            enqueueLeadMilliseconds,
                        pendingSampleBuffers:
                            renderer.pendingSampleBuffers
                    )
                )
            )
        case .playbackPressureChanged:
            let current = diagnostics
            publishTelemetry(
                .bufferStateChanged,
                payload: .bufferStateChanged(
                    AetherHybridBufferTelemetry(
                        pressure:
                            current
                                .audioAnalysisPlaybackPressure,
                        carrierForwardBufferSeconds:
                            current
                                .carrierForwardBufferSeconds,
                        carrierTimeControlStatus:
                            current
                                .carrierTimeControlStatus,
                        carrierRate: current.carrierRate
                    )
                )
            )
        case .carrierReady(let point):
            publishTelemetry(
                .carrierReady,
                payload: .carrierReady(point)
            )
        case .videoFirstFrameReady(let point):
            publishTelemetry(
                .videoFirstFrameReady,
                payload: .videoFirstFrameReady(point)
            )
        case .playbackStarted(let point):
            publishTelemetry(
                .playbackStarted,
                payload: .playbackStarted(point)
            )
        case .seekRequested(let point):
            publishTelemetry(
                .seekRequested,
                payload: .seekRequested(point)
            )
        case .seekVideoReady(let point):
            publishTelemetry(
                .seekVideoReady,
                payload: .seekVideoReady(point)
            )
        case .sessionEnded(let reason):
            publishTelemetry(
                .sessionEnded,
                payload: .sessionEnded(reason)
            )
        case .audioAnalysis(let event):
            let kind:
                AetherHybridPlaybackTelemetryEventKind
            switch event.phase {
            case .started:
                kind = .audioAnalysisStarted
            case .progress:
                kind = .audioAnalysisProgress
            case .completed:
                kind = .audioAnalysisCompleted
            case .failed:
                kind = .audioAnalysisFailed
            }
            publishTelemetry(
                kind,
                payload: .audioAnalysis(event)
            )
        }
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
            selectedAudioAnalysisTrackID:
                current.selectedAudioAnalysisTrackID,
            activeAudioAnalysisRequestCount:
                current.activeAudioAnalysisRequestCount,
            readinessPrerollFramesRejected:
                current.readinessPrerollFramesRejected,
            carrierBandwidth:
                current.carrierBandwidth,
            realVideoBitrate:
                current.realVideoBitrate,
            renderer: current.renderer,
            systemFeaturePolicy:
                current.systemFeaturePolicy
        )
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
        case .hls, .unclassifiedURL:
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
