import Foundation

/// The only render route a host may use after AetherEngine has inspected a source.
///
/// A route is selected before creating an AVPlayer item or a decoder session. Hosts must not infer a
/// different route from a later AVPlayer failure, a timeout, or a black frame.
public enum PlaybackRenderRoute: String, Sendable, Equatable {
    case nativeAVPlayer
    case hybridCarrier
    case unsupported
}

/// The source family supplied to the deterministic playback preflight.
///
/// The caller must state this fact rather than relying on a URL suffix: HLS endpoints commonly have no
/// `.m3u8` path extension.
public enum AetherMediaSourceKind: String, Sendable, Equatable, Hashable {
    case hls
    case progressive
    case custom
    /// URL evidence is still inconclusive. This state is not playback
    /// admission for any player; the owning liveness policy keeps resolving
    /// the same request until cancellation or typed permanent evidence.
    case unclassifiedURL
}

/// Codec identity used by the route policy. `.unknown` is deliberately not treated as AVPlayer-compatible.
public enum AetherVideoCodec: String, Sendable, Equatable, Hashable {
    case h264
    case hevc
    case prores
    case av1
    case vp9
    case vp8
    case mpeg2
    case mpeg4Part2
    case vc1
    case unknown

    init(codecName: String?) {
        self = switch codecName?.lowercased() {
        case "h264", "avc": .h264
        case "hevc", "h265": .hevc
        case "prores": .prores
        case "av1": .av1
        case "vp9": .vp9
        case "vp8": .vp8
        case "mpeg2video": .mpeg2
        case "mpeg4": .mpeg4Part2
        case "vc1": .vc1
        default: .unknown
        }
    }
}

/// Positive audio codec identity used only where the render route depends on
/// an Aether-owned audio backend. Unknown or unlisted codecs never imply that
/// the bridge can decode them.
public enum AetherAudioCodec: String, Sendable, Equatable, Hashable {
    case vorbis
    case pcmS24LE = "pcm_s24le"
    case unknown

    init(codecName: String?) {
        self = switch codecName?.lowercased() {
        case "vorbis": .vorbis
        case "pcm_s24le": .pcmS24LE
        default: .unknown
        }
    }
}

/// Immutable source facts needed to select a playback route.
///
/// `isSeekableVOD` is intentionally a positive fact instead of a derived `!isLive`: the hybrid contract
/// requires both VOD semantics and a seekable byte/timeline source.
public struct AetherSourceProfile: Sendable, Equatable {
    public let sourceKind: AetherMediaSourceKind
    public let isSeekableVOD: Bool
    /// Exact stream inventory. Only `provenAbsent` may admit an audio-only
    /// route; `unknown` remains fail-closed.
    public let videoStreamPresence: AetherVideoStreamPresence
    public var hasVideoStream: Bool {
        videoStreamPresence == .provenPresent
    }
    public let videoCodec: AetherVideoCodec
    /// Bridge-relevant codec families copied from the completed demux
    /// inventory. Unlisted codecs remain `.unknown`; no codec is inferred from
    /// a container or filename.
    public let audioCodecs: Set<AetherAudioCodec>
    public let sourceContainer: AetherSourceContainer
    public let videoScanType: AetherVideoScanType
    public let videoFormat: VideoFormat
    public let dolbyVisionConfiguration:
        AetherDolbyVisionConfiguration?
    public let hasVerifiedDolbyVisionProfile84BaseLayer: Bool

    public init(
        sourceKind: AetherMediaSourceKind,
        isSeekableVOD: Bool,
        hasVideoStream: Bool = true,
        videoCodec: AetherVideoCodec,
        audioCodecs: Set<AetherAudioCodec> = [],
        sourceContainer: AetherSourceContainer = .unknown,
        videoScanType: AetherVideoScanType = .unknown,
        videoFormat: VideoFormat,
        dolbyVisionConfiguration:
            AetherDolbyVisionConfiguration? = nil,
        hasVerifiedDolbyVisionProfile84BaseLayer: Bool = false
    ) {
        self.init(
            sourceKind: sourceKind,
            isSeekableVOD: isSeekableVOD,
            videoStreamPresence: hasVideoStream
                ? .provenPresent
                : .provenAbsent,
            videoCodec: videoCodec,
            audioCodecs: audioCodecs,
            sourceContainer: sourceContainer,
            videoScanType: videoScanType,
            videoFormat: videoFormat,
            dolbyVisionConfiguration:
                dolbyVisionConfiguration,
            hasVerifiedDolbyVisionProfile84BaseLayer:
                hasVerifiedDolbyVisionProfile84BaseLayer
        )
    }

    public init(
        sourceKind: AetherMediaSourceKind,
        isSeekableVOD: Bool,
        videoStreamPresence: AetherVideoStreamPresence,
        videoCodec: AetherVideoCodec,
        audioCodecs: Set<AetherAudioCodec> = [],
        sourceContainer: AetherSourceContainer = .unknown,
        videoScanType: AetherVideoScanType = .unknown,
        videoFormat: VideoFormat,
        dolbyVisionConfiguration:
            AetherDolbyVisionConfiguration? = nil,
        hasVerifiedDolbyVisionProfile84BaseLayer: Bool = false
    ) {
        self.sourceKind = sourceKind
        self.isSeekableVOD = isSeekableVOD
        // A non-unknown codec is itself positive video evidence. Normalizing
        // here prevents a contradictory caller flag from disguising HEVC as
        // audio-only and bypassing the Hybrid route invariant.
        self.videoStreamPresence = videoCodec != .unknown
            ? .provenPresent
            : videoStreamPresence
        self.videoCodec = videoCodec
        self.audioCodecs = audioCodecs
        self.sourceContainer = sourceContainer
        self.videoScanType = videoScanType
        self.videoFormat = videoFormat
        self.dolbyVisionConfiguration =
            dolbyVisionConfiguration
        self.hasVerifiedDolbyVisionProfile84BaseLayer =
            hasVerifiedDolbyVisionProfile84BaseLayer
    }

    /// Build a profile from a completed probe plus source facts that FFmpeg cannot infer reliably from a
    /// standalone URL. The caller must explicitly establish `sourceKind` and `isSeekableVOD`.
    public init(
        probe: SourceProbe,
        sourceKind: AetherMediaSourceKind,
        isSeekableVOD: Bool
    ) {
        self.init(
            sourceKind: sourceKind,
            isSeekableVOD: isSeekableVOD,
            videoStreamPresence: probe.videoStreamPresence,
            videoCodec: AetherVideoCodec(codecName: probe.videoCodecName),
            audioCodecs: Set(
                probe.audioTracks.map {
                    AetherAudioCodec(codecName: $0.codec)
                }
            ),
            sourceContainer: probe.sourceContainer,
            videoScanType: probe.videoScanType,
            videoFormat: probe.videoFormat,
            dolbyVisionConfiguration:
                probe.dolbyVisionConfiguration,
            hasVerifiedDolbyVisionProfile84BaseLayer:
                probe.hasVerifiedDolbyVisionProfile84BaseLayer
        )
    }
}

/// Immutable progressive facts pinned between the exact preflight demuxer
/// and the first Hybrid generation. URL identity alone is insufficient: an
/// origin can return different bytes on a second request while keeping the
/// same path and color format.
struct AetherProgressiveSourceFacts: Sendable, Equatable {
    let durationMicroseconds: Int64
    let videoStreamPresence: AetherVideoStreamPresence
    let videoCodec: AetherVideoCodec
    let audioCodecs: Set<AetherAudioCodec>
    let sourceContainer: AetherSourceContainer
    let videoScanType: AetherVideoScanType
    let isSourceSeekable: Bool
    let isLive: Bool
    let videoFormat: VideoFormat
    let dolbyVisionConfiguration:
        AetherDolbyVisionConfiguration?
    let hasVerifiedDolbyVisionProfile84BaseLayer: Bool

    init(probe: SourceProbe) {
        if probe.durationSeconds.isFinite,
           probe.durationSeconds > 0,
           probe.durationSeconds
                <= Double(Int64.max) / 1_000_000 {
            durationMicroseconds = Int64(
                (probe.durationSeconds * 1_000_000).rounded()
            )
        } else {
            durationMicroseconds = -1
        }
        videoStreamPresence = probe.videoStreamPresence
        videoCodec = AetherVideoCodec(
            codecName: probe.videoCodecName
        )
        audioCodecs = Set(
            probe.audioTracks.map {
                AetherAudioCodec(codecName: $0.codec)
            }
        )
        sourceContainer = probe.sourceContainer
        videoScanType = probe.videoScanType
        isSourceSeekable = probe.isSourceSeekable
        isLive = probe.isLive
        videoFormat = probe.videoFormat
        dolbyVisionConfiguration =
            probe.dolbyVisionConfiguration
        hasVerifiedDolbyVisionProfile84BaseLayer =
            probe.hasVerifiedDolbyVisionProfile84BaseLayer
    }

    func matches(
        preflightProfile: AetherSourceProfile,
        timelineDurationSeconds: Double
    ) -> Bool {
        guard timelineDurationSeconds.isFinite,
              timelineDurationSeconds > 0,
              durationMicroseconds >= 0,
              timelineDurationSeconds
                <= Double(Int64.max) / 1_000_000 else {
            return false
        }
        let expectedDuration = Int64(
            (timelineDurationSeconds * 1_000_000).rounded()
        )
        let durationDelta = abs(
            Double(durationMicroseconds) - Double(expectedDuration)
        )
        return durationDelta <= 1_000
            && videoStreamPresence
                == preflightProfile.videoStreamPresence
            && videoCodec == preflightProfile.videoCodec
            && audioCodecs == preflightProfile.audioCodecs
            && sourceContainer == preflightProfile.sourceContainer
            && videoScanType == preflightProfile.videoScanType
            && isSourceSeekable
            && !isLive
            && preflightProfile.isSeekableVOD
            && videoFormat == preflightProfile.videoFormat
            && dolbyVisionConfiguration
                == preflightProfile.dolbyVisionConfiguration
            && hasVerifiedDolbyVisionProfile84BaseLayer
                == preflightProfile
                    .hasVerifiedDolbyVisionProfile84BaseLayer
    }

    func hasSameMediaIdentity(
        as other: AetherProgressiveSourceFacts
    ) -> Bool {
        let durationDelta = abs(
            Double(durationMicroseconds)
                - Double(other.durationMicroseconds)
        )
        return durationMicroseconds >= 0
            && other.durationMicroseconds >= 0
            && durationDelta <= 1_000
            && videoStreamPresence == other.videoStreamPresence
            && videoCodec == other.videoCodec
            && audioCodecs == other.audioCodecs
            && sourceContainer == other.sourceContainer
            && videoScanType == other.videoScanType
            && isSourceSeekable == other.isSourceSeekable
            && isLive == other.isLive
            && videoFormat == other.videoFormat
            && dolbyVisionConfiguration
                == other.dolbyVisionConfiguration
            && hasVerifiedDolbyVisionProfile84BaseLayer
                == other.hasVerifiedDolbyVisionProfile84BaseLayer
    }
}

/// Transport container established by HLS manifest and segment inspection.
public enum HLSVideoContainer: String, Sendable, Equatable {
    case fragmentedMP4
    case mpegTransport
    case unknown
}

/// BMFF sample entry established for the selected HLS variant.
///
/// Clear fMP4 uses init-segment evidence. Protected fMP4 may use the selected variant's normalized codec
/// declaration only alongside `.protectedManifestVerified`. MPEG-TS has no BMFF sample entry, therefore
/// uses `.notApplicable` rather than an invented value.
public enum HLSVideoSampleEntry: String, Sendable, Equatable {
    case avc1
    case hvc1
    case hev1
    case dvh1
    case notApplicable
    case unknown
}

/// Evidence used to compare the selected variant's `CODECS` declaration with its media packaging.
///
/// Clear media requires segment inspection. Protected media can use `.protectedManifestVerified` only for
/// an AVPlayer-native contract; that state never admits hybrid direct decode because AetherEngine has no
/// clear compressed-sample contract.
public enum HLSManifestCodecVerification: String, Sendable, Equatable {
    case verified
    case manifestMissingButSegmentVerified
    case mismatch
    case protectedManifestVerified
    case segmentNotInspected
}

/// Content protection observed on the selected HLS presentation.
///
/// For a hybrid candidate, this includes protection on any required alternate-audio rendition. Hybrid
/// direct decode requires clear packets and samples, while an AVPlayer-native protected presentation can
/// remain on the native route without exposing keys or clear samples to AetherEngine.
public enum HLSContentProtection: String, Sendable, Equatable {
    case none
    case aes128
    case sampleAES
    case fairPlay
    case unknown
}

/// Selected-presentation packaging facts plus their explicit verification state.
///
/// Clear media is segment-backed. Protected media can be manifest-backed only when
/// `codecVerification == .protectedManifestVerified`, which is sufficient solely for the native AVPlayer
/// route and never for hybrid direct decode.
public struct HLSVideoPackaging: Sendable, Equatable {
    public let container: HLSVideoContainer
    public let sampleEntry: HLSVideoSampleEntry
    /// Normalized video-related tokens from the selected variant's `CODECS` attribute. Empty is meaningful
    /// only alongside `.manifestMissingButSegmentVerified`.
    public let manifestCodecs: [String]
    public let actualVideoCodec: AetherVideoCodec
    public let codecVerification: HLSManifestCodecVerification
    public let contentProtection: HLSContentProtection
    /// Root-master evidence that an uninspected alternate variant advertises
    /// HEVC. A Native session receives the root master and may select that
    /// different variant, so this fact requires graph-bound Hybrid playback
    /// even when the selected segment is positively H.264. The selected
    /// variant is excluded because its segment evidence already resolves stale
    /// or mismatched manifest metadata.
    public let masterContainsUninspectedHEVCVariant: Bool

    public init(
        container: HLSVideoContainer,
        sampleEntry: HLSVideoSampleEntry,
        manifestCodecs: [String],
        actualVideoCodec: AetherVideoCodec,
        codecVerification: HLSManifestCodecVerification,
        contentProtection: HLSContentProtection,
        masterContainsUninspectedHEVCVariant: Bool = false
    ) {
        self.container = container
        self.sampleEntry = sampleEntry
        self.manifestCodecs = manifestCodecs
        self.actualVideoCodec = actualVideoCodec
        self.codecVerification = codecVerification
        self.contentProtection = contentProtection
        self.masterContainsUninspectedHEVCVariant =
            masterContainsUninspectedHEVCVariant
    }
}

/// Capabilities that must all be positively established before the hybrid route can be selected.
///
/// The set of color formats is intentionally caller-supplied. A missing Dolby Vision/HDR format must select
/// `.unsupported`, not an implicit SDR tone-map path.
public struct HybridPlaybackCapabilities: Sendable, Equatable {
    public let hasDirectVideoDecoder: Bool
    /// Codecs whose software decoder has been positively established in the
    /// linked libavcodec build. An empty set means no codec-specific software
    /// decoder capability has been established.
    public let libavcodecDecodableVideoCodecs: Set<AetherVideoCodec>
    /// Audio codecs whose source decoder has been positively established in
    /// the linked libavcodec build.
    public let libavcodecDecodableAudioCodecs: Set<AetherAudioCodec>
    public let hasSampleBufferRenderer: Bool
    public let hasAudioBridgeCarrier: Bool
    /// Audio bridge output modes whose encoders are positively present in the
    /// linked libavcodec build.
    public let supportedAudioBridgeModes: Set<AudioBridgeMode>
    public let supportedVideoFormats: Set<VideoFormat>
    public let supportedDolbyVisionProfiles:
        Set<AetherDolbyVisionProfile>
    public let supportedSourceKinds: Set<AetherMediaSourceKind>

    public init(
        hasDirectVideoDecoder: Bool,
        libavcodecDecodableVideoCodecs: Set<AetherVideoCodec> = [],
        libavcodecDecodableAudioCodecs: Set<AetherAudioCodec> = [],
        hasSampleBufferRenderer: Bool,
        hasAudioBridgeCarrier: Bool = false,
        supportedAudioBridgeModes: Set<AudioBridgeMode>? = nil,
        supportedVideoFormats: Set<VideoFormat>,
        supportedDolbyVisionProfiles:
            Set<AetherDolbyVisionProfile> = [],
        supportedSourceKinds: Set<AetherMediaSourceKind> = [
            .hls,
            .progressive,
            .custom,
        ]
    ) {
        self.hasDirectVideoDecoder = hasDirectVideoDecoder
        self.libavcodecDecodableVideoCodecs =
            libavcodecDecodableVideoCodecs
        self.libavcodecDecodableAudioCodecs =
            libavcodecDecodableAudioCodecs
        self.hasSampleBufferRenderer = hasSampleBufferRenderer
        self.hasAudioBridgeCarrier = hasAudioBridgeCarrier
        self.supportedAudioBridgeModes =
            supportedAudioBridgeModes
            ?? (hasAudioBridgeCarrier
                ? Set(AudioBridgeMode.allCases)
                : [])
        self.supportedVideoFormats = supportedVideoFormats
        self.supportedDolbyVisionProfiles =
            supportedDolbyVisionProfiles
        self.supportedSourceKinds = supportedSourceKinds
    }

    public func supportsAudioBridge(
        mode: AudioBridgeMode
    ) -> Bool {
        hasAudioBridgeCarrier
            && supportedAudioBridgeModes.contains(mode)
    }
}

/// Stable diagnostic reason accompanying every preflight route.
public enum PlaybackRouteReason: String, Sendable, Equatable {
    case nativeAudioOnly
    case nativeHLSContractVerified
    case nativeProtectedHLSContractVerified
    case nativeHLSFMP4Remux
    @available(
        *,
        deprecated,
        message:
            "Unknown URL facts are not playback admission; classification remains pending or fails typed"
    )
    case nativeProvisionalURL
    case hybridRecoveryAfterNativeFailure
    case hybridAudioBridge
    case hybridInterlacedH264
    case hybridHEVC
    case hybridProRes
    case hybridHEV1SampleEntry
    case hybridHEVCInMPEGTransport
    case hybridHLSManifestMissingCodecs
    case hybridHLSManifestSegmentMismatch
    case hybridHLSMasterContainsHEVCVariant
    case hybridNonAVPlayerCodec
    case unsupportedHLSPreflightMissing
    case unsupportedHLSSegmentNotInspected
    case unsupportedHLSContentProtection
    case unsupportedHLSVideoPackaging
    case unsupportedHybridRequiresSeekableVOD
    case unsupportedHybridSourceKind
    case unsupportedHybridDecoderUnavailable
    case unsupportedHybridSampleBufferRendererUnavailable
    case unsupportedHybridAudioBridgeUnavailable
    case unsupportedHybridVideoFormat
    case unsupportedProgressiveContainerUnverified
    case unsupportedSourceClassificationInconclusive
    case unsupportedProvisionalURLFactsResolved
    case unsupportedVideoStreamPresenceInconclusive
    case unsupportedDolbyVisionConfigurationMissing
    case unsupportedDolbyVisionProfile
    case unsupportedDolbyVisionConfigurationMismatch
    case unsupportedHDR10PlusBaseLayerMismatch
    case unsupportedHDR10PlusCompressedSampleEvidenceMissing
    case unsupportedHDR10PlusCompressedSampleMalformed
    case unsupportedHDR10PlusCompressedSampleUninspectable
    case unsupportedHDR10PlusValidatorUnavailable
    case unsupportedVideoCodec
}

/// Complete deterministic preflight result. `route == .unsupported` is a valid, user-presentable result;
/// it is not a request for the host to try a legacy player.
public struct PlaybackPreflightResult: Sendable, Equatable {
    public let sourceProfile: AetherSourceProfile
    public let hlsPackaging: HLSVideoPackaging?
    public let route: PlaybackRenderRoute
    public let reason: PlaybackRouteReason

    public init(
        sourceProfile: AetherSourceProfile,
        hlsPackaging: HLSVideoPackaging?,
        route: PlaybackRenderRoute,
        reason: PlaybackRouteReason
    ) {
        self.sourceProfile = sourceProfile
        self.hlsPackaging = hlsPackaging
        self.route = route
        self.reason = reason
    }
}

/// Pure route policy shared by HLS inspection, session creation and tests.
///
/// This policy performs no I/O. The HLS inspector is responsible for constructing
/// `HLSVideoPackaging` from the selected playlist, init segment and first media segment before calling it.
public enum PlaybackPreflight {
    private static let softwareDecodedVideoCodecs:
        Set<AetherVideoCodec> = [
            .h264,
            .prores,
            .av1,
            .vp9,
            .vp8,
            .mpeg2,
            .mpeg4Part2,
            .vc1,
        ]

    public static func resolve(
        sourceProfile: AetherSourceProfile,
        hlsPackaging: HLSVideoPackaging?,
        hybridCapabilities: HybridPlaybackCapabilities,
        requiredAudioBridgeMode: AudioBridgeMode? = nil
    ) -> PlaybackPreflightResult {
        switch sourceProfile.sourceKind {
        case .hls:
            return resolveHLS(
                sourceProfile: sourceProfile,
                hlsPackaging: hlsPackaging,
                hybridCapabilities: hybridCapabilities,
                requiredAudioBridgeMode:
                    requiredAudioBridgeMode
            )
        case .unclassifiedURL:
            guard sourceProfile.videoStreamPresence == .unknown,
                  sourceProfile.videoCodec == .unknown,
                  sourceProfile.audioCodecs.isEmpty,
                  sourceProfile.sourceContainer == .unknown,
                  sourceProfile.videoScanType == .unknown,
                  sourceProfile.videoFormat == .sdr,
                  sourceProfile.dolbyVisionConfiguration == nil,
                  !sourceProfile
                    .hasVerifiedDolbyVisionProfile84BaseLayer else {
                return result(
                    sourceProfile,
                    nil,
                    .unsupported,
                    .unsupportedProvisionalURLFactsResolved
                )
            }
            guard hlsPackaging == nil else {
                return result(
                    sourceProfile,
                    hlsPackaging,
                    .unsupported,
                    .unsupportedProvisionalURLFactsResolved
                )
            }
            return result(
                sourceProfile,
                nil,
                .unsupported,
                .unsupportedSourceClassificationInconclusive
            )
        case .progressive, .custom:
            switch sourceProfile.videoStreamPresence {
            case .provenAbsent:
                if sourceProfile.audioCodecs == [.vorbis] {
                    return hybridAudioResult(
                        sourceProfile: sourceProfile,
                        capabilities: hybridCapabilities,
                        requiredAudioBridgeMode:
                            requiredAudioBridgeMode
                    )
                }
                return result(
                    sourceProfile,
                    nil,
                    .nativeAVPlayer,
                    .nativeAudioOnly
                )
            case .unknown:
                return result(
                    sourceProfile,
                    nil,
                    .unsupported,
                    .unsupportedVideoStreamPresenceInconclusive
                )
            case .provenPresent:
                break
            }
            switch sourceProfile.videoCodec {
            case .h264:
                if sourceProfile.videoScanType == .interlaced {
                    return hybridResult(
                        sourceProfile: sourceProfile,
                        hlsPackaging: nil,
                        reason: .hybridInterlacedH264,
                        capabilities: hybridCapabilities,
                        requiredAudioBridgeMode:
                            requiredAudioBridgeMode
                    )
                }
                guard sourceProfile.sourceContainer
                        .supportsNativeHLSFMP4Remux else {
                    return result(
                        sourceProfile,
                        nil,
                        .unsupported,
                        .unsupportedProgressiveContainerUnverified
                    )
                }
                return result(
                    sourceProfile,
                    nil,
                    .nativeAVPlayer,
                    .nativeHLSFMP4Remux
                )
            case .hevc:
                return hybridResult(
                    sourceProfile: sourceProfile,
                    hlsPackaging: nil,
                    reason: .hybridHEVC,
                    capabilities: hybridCapabilities,
                    requiredAudioBridgeMode:
                        requiredAudioBridgeMode
                )
            case .prores:
                return hybridResult(
                    sourceProfile: sourceProfile,
                    hlsPackaging: nil,
                    reason: .hybridProRes,
                    capabilities: hybridCapabilities,
                    requiredAudioBridgeMode:
                        requiredAudioBridgeMode
                )
            case .unknown:
                return result(sourceProfile, nil, .unsupported, .unsupportedVideoCodec)
            default:
                return hybridResult(
                    sourceProfile: sourceProfile,
                    hlsPackaging: nil,
                    reason: .hybridNonAVPlayerCodec,
                    capabilities: hybridCapabilities,
                    requiredAudioBridgeMode:
                        requiredAudioBridgeMode
                )
            }
        }
    }

    /// Retained for source compatibility. A playback task cannot change
    /// players after admission, so recovery never exposes an alternate route.
    @available(
        *,
        deprecated,
        message:
            "Playback recovery is same-route only and never returns an alternate player"
    )
    public static func resolveRecoveryAlternate(
        sourceProfile: AetherSourceProfile,
        hlsPackaging: HLSVideoPackaging?,
        excluding activeRoute: PlaybackRenderRoute,
        hybridCapabilities: HybridPlaybackCapabilities,
        requiredAudioBridgeMode: AudioBridgeMode? = nil
    ) -> PlaybackPreflightResult? {
        _ = sourceProfile
        _ = hlsPackaging
        _ = activeRoute
        _ = hybridCapabilities
        _ = requiredAudioBridgeMode
        return nil
    }

    private static func resolveHLS(
        sourceProfile: AetherSourceProfile,
        hlsPackaging: HLSVideoPackaging?,
        hybridCapabilities: HybridPlaybackCapabilities,
        requiredAudioBridgeMode: AudioBridgeMode?
    ) -> PlaybackPreflightResult {
        guard let hlsPackaging else {
            return result(sourceProfile, nil, .unsupported, .unsupportedHLSPreflightMissing)
        }
        if hlsPackaging.contentProtection == .unknown {
            return result(
                sourceProfile,
                hlsPackaging,
                .unsupported,
                .unsupportedHLSContentProtection
            )
        }
        if hlsPackaging.codecVerification == .segmentNotInspected {
            return result(
                sourceProfile,
                hlsPackaging,
                .unsupported,
                hlsPackaging.contentProtection == .none
                    ? .unsupportedHLSSegmentNotInspected
                    : .unsupportedHLSContentProtection
            )
        }
        if hlsPackaging.codecVerification
                == .protectedManifestVerified,
           hlsPackaging.contentProtection == .none {
            return result(
                sourceProfile,
                hlsPackaging,
                .unsupported,
                .unsupportedHLSSegmentNotInspected
            )
        }
        guard hlsPackaging.actualVideoCodec == sourceProfile.videoCodec else {
            return result(sourceProfile, hlsPackaging, .unsupported, .unsupportedHLSVideoPackaging)
        }
        if hlsPackaging.masterContainsUninspectedHEVCVariant,
           sourceProfile.videoCodec != .hevc {
            guard hlsPackaging.contentProtection == .none else {
                return result(
                    sourceProfile,
                    hlsPackaging,
                    .unsupported,
                    .unsupportedHLSContentProtection
                )
            }
            return hybridResult(
                sourceProfile: sourceProfile,
                hlsPackaging: hlsPackaging,
                reason: .hybridHLSMasterContainsHEVCVariant,
                capabilities: hybridCapabilities,
                requiredAudioBridgeMode:
                    requiredAudioBridgeMode
            )
        }
        if sourceProfile.videoCodec == .hevc,
           hlsPackaging.codecVerification == .mismatch {
            return result(
                sourceProfile,
                hlsPackaging,
                .unsupported,
                .unsupportedHLSVideoPackaging
            )
        }
        if sourceProfile.videoCodec == .h264,
           sourceProfile.videoScanType == .interlaced {
            guard hlsPackaging.contentProtection == .none else {
                return result(
                    sourceProfile,
                    hlsPackaging,
                    .unsupported,
                    .unsupportedHLSContentProtection
                )
            }
            return hybridResult(
                sourceProfile: sourceProfile,
                hlsPackaging: hlsPackaging,
                reason: .hybridInterlacedH264,
                capabilities: hybridCapabilities,
                requiredAudioBridgeMode:
                    requiredAudioBridgeMode
            )
        }

        let nativeContractVerified: Bool
        switch sourceProfile.videoCodec {
        case .h264:
            nativeContractVerified =
                hlsPackaging.codecVerification == .verified
                || hlsPackaging.codecVerification
                    == .protectedManifestVerified
        case .hevc, .prores, .av1, .vp9, .vp8, .mpeg2,
             .mpeg4Part2, .vc1, .unknown:
            nativeContractVerified = false
        }
        if hlsPackaging.contentProtection != .none {
            return result(
                sourceProfile,
                hlsPackaging,
                nativeContractVerified
                    ? .nativeAVPlayer
                    : .unsupported,
                nativeContractVerified
                    ? .nativeProtectedHLSContractVerified
                    : .unsupportedHLSContentProtection
            )
        }

        switch sourceProfile.videoCodec {
        case .h264:
            // A direct media playlist is not required to declare CODECS. Once the selected segment
            // positively identifies an AVPlayer-supported H.264 stream, the segment fact is authoritative
            // for decoder capability. Missing or stale manifest metadata must not create another media
            // pipeline.
            return result(
                sourceProfile,
                hlsPackaging,
                .nativeAVPlayer,
                .nativeHLSContractVerified
            )

        case .hevc:
            let reason: PlaybackRouteReason
            if hlsPackaging.codecVerification
                    == .manifestMissingButSegmentVerified {
                reason = .hybridHLSManifestMissingCodecs
            } else if hlsPackaging.container == .mpegTransport {
                reason = .hybridHEVCInMPEGTransport
            } else if hlsPackaging.sampleEntry == .hev1 {
                reason = .hybridHEV1SampleEntry
            } else {
                reason = .hybridHEVC
            }
            return hybridResult(
                sourceProfile: sourceProfile,
                hlsPackaging: hlsPackaging,
                reason: reason,
                capabilities: hybridCapabilities,
                requiredAudioBridgeMode:
                    requiredAudioBridgeMode
            )

        case .prores:
            // ProRes capability admission is currently proven only by the
            // progressive/custom demux contract. Recognizing an HLS codec
            // token is identity evidence, not an HLS packaging admission.
            return result(
                sourceProfile,
                hlsPackaging,
                .unsupported,
                .unsupportedHLSVideoPackaging
            )

        case .unknown:
            return result(sourceProfile, hlsPackaging, .unsupported, .unsupportedVideoCodec)

        default:
            return hybridResult(
                sourceProfile: sourceProfile,
                hlsPackaging: hlsPackaging,
                reason: .hybridNonAVPlayerCodec,
                capabilities: hybridCapabilities,
                requiredAudioBridgeMode:
                    requiredAudioBridgeMode
            )
        }
    }

    /// Audio-only Hybrid admission uses AVPlayer only for the Aether-owned
    /// black carrier while `AudioBridge` decodes the exact source audio and
    /// emits a truthful carrier rendition. It has no real-video decoder or
    /// presentation-surface requirement.
    private static func audioBridgeIsAvailable(
        capabilities: HybridPlaybackCapabilities,
        requiredMode: AudioBridgeMode?
    ) -> Bool {
        guard let requiredMode else {
            return capabilities.hasAudioBridgeCarrier
                && !capabilities
                    .supportedAudioBridgeModes.isEmpty
        }
        return capabilities.supportsAudioBridge(
            mode: requiredMode
        )
    }

    private static func hybridAudioResult(
        sourceProfile: AetherSourceProfile,
        capabilities: HybridPlaybackCapabilities,
        requiredAudioBridgeMode: AudioBridgeMode?
    ) -> PlaybackPreflightResult {
        guard sourceProfile.videoStreamPresence == .provenAbsent,
              sourceProfile.videoCodec == .unknown,
              sourceProfile.audioCodecs == [.vorbis] else {
            return result(
                sourceProfile,
                nil,
                .unsupported,
                .unsupportedVideoStreamPresenceInconclusive
            )
        }
        guard sourceProfile.isSeekableVOD else {
            return result(
                sourceProfile,
                nil,
                .unsupported,
                .unsupportedHybridRequiresSeekableVOD
            )
        }
        guard capabilities.supportedSourceKinds.contains(
            sourceProfile.sourceKind
        ) else {
            return result(
                sourceProfile,
                nil,
                .unsupported,
                .unsupportedHybridSourceKind
            )
        }
        guard audioBridgeIsAvailable(
            capabilities: capabilities,
            requiredMode: requiredAudioBridgeMode
        ) else {
            return result(
                sourceProfile,
                nil,
                .unsupported,
                .unsupportedHybridAudioBridgeUnavailable
            )
        }
        guard capabilities.libavcodecDecodableAudioCodecs
                .contains(.vorbis) else {
            return result(
                sourceProfile,
                nil,
                .unsupported,
                .unsupportedHybridAudioBridgeUnavailable
            )
        }
        return result(
            sourceProfile,
            nil,
            .hybridCarrier,
            .hybridAudioBridge
        )
    }

    private static func hybridResult(
        sourceProfile: AetherSourceProfile,
        hlsPackaging: HLSVideoPackaging?,
        reason: PlaybackRouteReason,
        capabilities: HybridPlaybackCapabilities,
        requiredAudioBridgeMode: AudioBridgeMode?
    ) -> PlaybackPreflightResult {
        guard sourceProfile.isSeekableVOD else {
            return result(sourceProfile, hlsPackaging, .unsupported, .unsupportedHybridRequiresSeekableVOD)
        }
        guard capabilities.supportedSourceKinds.contains(sourceProfile.sourceKind) else {
            return result(sourceProfile, hlsPackaging, .unsupported, .unsupportedHybridSourceKind)
        }
        guard capabilities.hasDirectVideoDecoder else {
            return result(sourceProfile, hlsPackaging, .unsupported, .unsupportedHybridDecoderUnavailable)
        }
        if softwareDecodedVideoCodecs.contains(
            sourceProfile.videoCodec
        ) {
            guard capabilities.libavcodecDecodableVideoCodecs
                    .contains(sourceProfile.videoCodec) else {
                return result(
                    sourceProfile,
                    hlsPackaging,
                    .unsupported,
                    .unsupportedHybridDecoderUnavailable
                )
            }
        }
        if sourceProfile.audioCodecs.contains(.pcmS24LE),
           (!capabilities.libavcodecDecodableAudioCodecs
                .contains(.pcmS24LE)
            || !audioBridgeIsAvailable(
                capabilities: capabilities,
                requiredMode: requiredAudioBridgeMode
            )) {
                return result(
                    sourceProfile,
                    hlsPackaging,
                    .unsupported,
                    .unsupportedHybridAudioBridgeUnavailable
                )
        }
        guard capabilities.hasSampleBufferRenderer else {
            return result(
                sourceProfile,
                hlsPackaging,
                .unsupported,
                .unsupportedHybridSampleBufferRendererUnavailable
            )
        }
        if sourceProfile.videoFormat == .dolbyVision {
            guard let configuration =
                    sourceProfile.dolbyVisionConfiguration else {
                return result(
                    sourceProfile,
                    hlsPackaging,
                    .unsupported,
                    .unsupportedDolbyVisionConfigurationMissing
                )
            }
            guard configuration.profile == 8,
                  configuration.baseLayerSignalCompatibilityID == 4 else {
                return result(
                    sourceProfile,
                    hlsPackaging,
                    .unsupported,
                    .unsupportedDolbyVisionProfile
                )
            }
            guard let profile =
                    configuration.verifiedHybridProfile else {
                return result(
                    sourceProfile,
                    hlsPackaging,
                    .unsupported,
                    .unsupportedDolbyVisionConfigurationMismatch
                )
            }
            guard sourceProfile
                    .hasVerifiedDolbyVisionProfile84BaseLayer else {
                return result(
                    sourceProfile,
                    hlsPackaging,
                    .unsupported,
                    .unsupportedDolbyVisionConfigurationMismatch
                )
            }
            guard capabilities.supportedDolbyVisionProfiles
                    .contains(profile) else {
                return result(
                    sourceProfile,
                    hlsPackaging,
                    .unsupported,
                    .unsupportedDolbyVisionProfile
                )
            }
        } else if sourceProfile.dolbyVisionConfiguration != nil
                    || sourceProfile
                        .hasVerifiedDolbyVisionProfile84BaseLayer {
            return result(
                sourceProfile,
                hlsPackaging,
                .unsupported,
                .unsupportedDolbyVisionConfigurationMismatch
            )
        }
        guard capabilities.supportedVideoFormats.contains(sourceProfile.videoFormat) else {
            return result(sourceProfile, hlsPackaging, .unsupported, .unsupportedHybridVideoFormat)
        }
        return result(sourceProfile, hlsPackaging, .hybridCarrier, reason)
    }

    private static func result(
        _ sourceProfile: AetherSourceProfile,
        _ hlsPackaging: HLSVideoPackaging?,
        _ route: PlaybackRenderRoute,
        _ reason: PlaybackRouteReason
    ) -> PlaybackPreflightResult {
        PlaybackPreflightResult(
            sourceProfile: sourceProfile,
            hlsPackaging: hlsPackaging,
            route: route,
            reason: reason
        )
    }
}
