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
    /// URL evidence remained inconclusive after the bounded retry budget.
    /// This is an explicit same-URL Native trial contract, not inferred
    /// progressive provenance and never a Hybrid admission.
    case unclassifiedURL
}

/// Codec identity used by the route policy. `.unknown` is deliberately not treated as AVPlayer-compatible.
public enum AetherVideoCodec: String, Sendable, Equatable {
    case h264
    case hevc
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

/// Immutable source facts needed to select a playback route.
///
/// `isSeekableVOD` is intentionally a positive fact instead of a derived `!isLive`: the hybrid contract
/// requires both VOD semantics and a seekable byte/timeline source.
public struct AetherSourceProfile: Sendable, Equatable {
    public let sourceKind: AetherMediaSourceKind
    public let isSeekableVOD: Bool
    public let videoCodec: AetherVideoCodec
    public let sourceContainer: AetherSourceContainer
    public let videoFormat: VideoFormat
    public let dolbyVisionConfiguration:
        AetherDolbyVisionConfiguration?
    public let hasVerifiedDolbyVisionProfile84BaseLayer: Bool

    public init(
        sourceKind: AetherMediaSourceKind,
        isSeekableVOD: Bool,
        videoCodec: AetherVideoCodec,
        sourceContainer: AetherSourceContainer = .unknown,
        videoFormat: VideoFormat,
        dolbyVisionConfiguration:
            AetherDolbyVisionConfiguration? = nil,
        hasVerifiedDolbyVisionProfile84BaseLayer: Bool = false
    ) {
        self.sourceKind = sourceKind
        self.isSeekableVOD = isSeekableVOD
        self.videoCodec = videoCodec
        self.sourceContainer = sourceContainer
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
            videoCodec: AetherVideoCodec(codecName: probe.videoCodecName),
            sourceContainer: probe.sourceContainer,
            videoFormat: probe.videoFormat,
            dolbyVisionConfiguration:
                probe.dolbyVisionConfiguration,
            hasVerifiedDolbyVisionProfile84BaseLayer:
                probe.hasVerifiedDolbyVisionProfile84BaseLayer
        )
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

    public init(
        container: HLSVideoContainer,
        sampleEntry: HLSVideoSampleEntry,
        manifestCodecs: [String],
        actualVideoCodec: AetherVideoCodec,
        codecVerification: HLSManifestCodecVerification,
        contentProtection: HLSContentProtection
    ) {
        self.container = container
        self.sampleEntry = sampleEntry
        self.manifestCodecs = manifestCodecs
        self.actualVideoCodec = actualVideoCodec
        self.codecVerification = codecVerification
        self.contentProtection = contentProtection
    }
}

/// Capabilities that must all be positively established before the hybrid route can be selected.
///
/// The set of color formats is intentionally caller-supplied. A missing Dolby Vision/HDR format must select
/// `.unsupported`, not an implicit SDR tone-map path.
public struct HybridPlaybackCapabilities: Sendable, Equatable {
    public let hasDirectVideoDecoder: Bool
    public let hasSampleBufferRenderer: Bool
    public let supportedVideoFormats: Set<VideoFormat>
    public let supportedDolbyVisionProfiles:
        Set<AetherDolbyVisionProfile>
    public let supportedSourceKinds: Set<AetherMediaSourceKind>

    public init(
        hasDirectVideoDecoder: Bool,
        hasSampleBufferRenderer: Bool,
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
        self.hasSampleBufferRenderer = hasSampleBufferRenderer
        self.supportedVideoFormats = supportedVideoFormats
        self.supportedDolbyVisionProfiles =
            supportedDolbyVisionProfiles
        self.supportedSourceKinds = supportedSourceKinds
    }
}

/// Stable diagnostic reason accompanying every preflight route.
public enum PlaybackRouteReason: String, Sendable, Equatable {
    case nativeHLSContractVerified
    case nativeProtectedHLSContractVerified
    case nativeHLSFMP4Remux
    case nativeProvisionalURL
    case hybridRecoveryAfterNativeFailure
    case hybridHEV1SampleEntry
    case hybridHEVCInMPEGTransport
    case hybridHLSManifestMissingCodecs
    case hybridHLSManifestSegmentMismatch
    case hybridNonAVPlayerCodec
    case unsupportedHLSPreflightMissing
    case unsupportedHLSSegmentNotInspected
    case unsupportedHLSContentProtection
    case unsupportedHLSVideoPackaging
    case unsupportedHybridRequiresSeekableVOD
    case unsupportedHybridSourceKind
    case unsupportedHybridDecoderUnavailable
    case unsupportedHybridSampleBufferRendererUnavailable
    case unsupportedHybridVideoFormat
    case unsupportedProgressiveContainerUnverified
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
    public static func resolve(
        sourceProfile: AetherSourceProfile,
        hlsPackaging: HLSVideoPackaging?,
        hybridCapabilities: HybridPlaybackCapabilities
    ) -> PlaybackPreflightResult {
        switch sourceProfile.sourceKind {
        case .hls:
            return resolveHLS(
                sourceProfile: sourceProfile,
                hlsPackaging: hlsPackaging,
                hybridCapabilities: hybridCapabilities
            )
        case .unclassifiedURL:
            return result(
                sourceProfile,
                nil,
                .nativeAVPlayer,
                .nativeProvisionalURL
            )
        case .progressive, .custom:
            switch sourceProfile.videoCodec {
            case .h264, .hevc:
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
            case .unknown:
                return result(sourceProfile, nil, .unsupported, .unsupportedVideoCodec)
            default:
                return hybridResult(
                    sourceProfile: sourceProfile,
                    hlsPackaging: nil,
                    reason: .hybridNonAVPlayerCodec,
                    capabilities: hybridCapabilities
                )
            }
        }
    }

    /// Resolve the only evidence-backed alternate route allowed after the
    /// active route has exhausted its same-route rebuild. The source profile,
    /// packaging and capability facts are unchanged.
    public static func resolveRecoveryAlternate(
        sourceProfile: AetherSourceProfile,
        hlsPackaging: HLSVideoPackaging?,
        excluding activeRoute: PlaybackRenderRoute,
        hybridCapabilities: HybridPlaybackCapabilities
    ) -> PlaybackPreflightResult? {
        switch activeRoute {
        case .nativeAVPlayer:
            guard sourceProfile.sourceKind != .unclassifiedURL,
                  sourceProfile.videoCodec != .unknown,
                  sourceProfile.videoCodec != .h264,
                  sourceProfile.videoCodec != .hevc else {
                return nil
            }
            guard resolve(
                sourceProfile: sourceProfile,
                hlsPackaging: hlsPackaging,
                hybridCapabilities: hybridCapabilities
            ).route == .nativeAVPlayer else {
                return nil
            }
            if sourceProfile.sourceKind == .progressive
                || sourceProfile.sourceKind == .custom {
                guard sourceProfile.sourceContainer
                        .supportsNativeHLSFMP4Remux else {
                    return nil
                }
            }
            if sourceProfile.sourceKind == .hls {
                guard let hlsPackaging,
                      hlsPackaging.contentProtection == .none,
                      hlsPackaging.codecVerification
                        != .segmentNotInspected,
                      hlsPackaging.actualVideoCodec
                        == sourceProfile.videoCodec else {
                    return nil
                }
            }
            let result = hybridResult(
                sourceProfile: sourceProfile,
                hlsPackaging: hlsPackaging,
                reason: .hybridRecoveryAfterNativeFailure,
                capabilities: hybridCapabilities
            )
            return result.route == .hybridCarrier ? result : nil

        case .hybridCarrier:
            let result = resolve(
                sourceProfile: sourceProfile,
                hlsPackaging: hlsPackaging,
                hybridCapabilities: hybridCapabilities
            )
            return result.route == .nativeAVPlayer ? result : nil

        case .unsupported:
            return nil
        }
    }

    private static func resolveHLS(
        sourceProfile: AetherSourceProfile,
        hlsPackaging: HLSVideoPackaging?,
        hybridCapabilities: HybridPlaybackCapabilities
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

        let nativeContractVerified: Bool
        switch sourceProfile.videoCodec {
        case .h264:
            nativeContractVerified =
                hlsPackaging.codecVerification == .verified
                || hlsPackaging.codecVerification
                    == .protectedManifestVerified
        case .hevc:
            nativeContractVerified =
                hlsPackaging.container == .fragmentedMP4
                && (
                    hlsPackaging.sampleEntry == .hvc1
                    || hlsPackaging.sampleEntry == .dvh1
                )
                && (
                    hlsPackaging.codecVerification == .verified
                    || hlsPackaging.codecVerification
                        == .protectedManifestVerified
                )
        case .av1, .vp9, .vp8, .mpeg2, .mpeg4Part2, .vc1,
             .unknown:
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
            if hlsPackaging.container == .fragmentedMP4,
               hlsPackaging.sampleEntry == .hvc1 || hlsPackaging.sampleEntry == .dvh1 {
                return result(sourceProfile, hlsPackaging, .nativeAVPlayer, .nativeHLSContractVerified)
            }
            if let reason = nativeCodecMetadataFailure(
                sourceProfile
            ) {
                return result(
                    sourceProfile,
                    hlsPackaging,
                    .unsupported,
                    reason
                )
            }
            // HEVC remains an AVPlayer decoder capability. Packaging that AVPlayer cannot consume is a
            // positive packaging boundary, not evidence for the Hybrid codec route and not permission to
            // invent remote-HLS normalization inside the adapter.
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
                capabilities: hybridCapabilities
            )
        }
    }

    private static func nativeCodecMetadataFailure(
        _ sourceProfile: AetherSourceProfile
    ) -> PlaybackRouteReason? {
        if sourceProfile.videoFormat == .dolbyVision {
            guard let configuration =
                    sourceProfile.dolbyVisionConfiguration else {
                return .unsupportedDolbyVisionConfigurationMissing
            }
            guard configuration.profile == 8,
                  configuration.baseLayerSignalCompatibilityID == 4 else {
                return .unsupportedDolbyVisionProfile
            }
            guard configuration.verifiedHybridProfile != nil,
                  sourceProfile
                    .hasVerifiedDolbyVisionProfile84BaseLayer else {
                return .unsupportedDolbyVisionConfigurationMismatch
            }
        } else if sourceProfile.dolbyVisionConfiguration != nil
                    || sourceProfile
                        .hasVerifiedDolbyVisionProfile84BaseLayer {
            return .unsupportedDolbyVisionConfigurationMismatch
        }
        return nil
    }

    private static func hybridResult(
        sourceProfile: AetherSourceProfile,
        hlsPackaging: HLSVideoPackaging?,
        reason: PlaybackRouteReason,
        capabilities: HybridPlaybackCapabilities
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
