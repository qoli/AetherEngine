import CoreMedia
import Foundation
import Libavcodec

/// Deterministic selected-variant policy for HLS preflight. The session must use the same selected variant
/// that was inspected; it may not let an adaptive AVPlayer choice invalidate the route decision later.
public enum HLSPreflightVariantSelection: Sendable, Equatable {
    case highestBandwidth
    case exactURI(String)
}

/// Transport or manifest failure while gathering preflight evidence. This is distinct from a successful
/// preflight that returns `.unsupported` for a known-but-unsupported source contract.
public enum HLSPreflightError: Error, Sendable, Equatable, LocalizedError {
    case httpStatus(Int)
    case invalidPlaylist(String)
    case unresolvableURI(String)
    case requestedVariantNotFound(String)
    case selectedVariantWasNotMediaPlaylist
    case seekableVODPlaylistNotFinite
    case unsupportedSeekableVODResourceGraph(reason: String)
    case resourceTooLarge(limit: Int)
    case unsupportedContentEncoding(String)
    case contentLengthMismatch(expected: Int64, actual: Int)
    case redirectCredentialScopeViolation
    case nonHTTPResponse
    case transportFailure(code: Int?)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let status): "HLS preflight HTTP status \(status)"
        case .invalidPlaylist(let reason): "Invalid HLS playlist: \(reason)"
        case .unresolvableURI(let uri): "Unresolvable HLS URI: \(uri)"
        case .requestedVariantNotFound(let uri): "Requested HLS variant not found: \(uri)"
        case .selectedVariantWasNotMediaPlaylist: "Selected HLS variant was not a media playlist"
        case .seekableVODPlaylistNotFinite:
            "Seekable HLS VOD requires a finite media playlist with EXT-X-ENDLIST"
        case .unsupportedSeekableVODResourceGraph(let reason):
            "Unsupported seekable HLS VOD resource graph: \(reason)"
        case .resourceTooLarge(let limit):
            "HLS preflight resource exceeded \(limit) bytes"
        case .unsupportedContentEncoding(let value):
            "HLS preflight requires identity content encoding, found \(value)"
        case .contentLengthMismatch(let expected, let actual):
            "HLS preflight resource declared \(expected) bytes but delivered \(actual)"
        case .redirectCredentialScopeViolation:
            "HLS preflight redirect crossed origin while request-scoped headers were present"
        case .nonHTTPResponse:
            "HLS preflight response was not HTTP"
        case .transportFailure(let code):
            if let code {
                "HLS preflight transport failed with URL error \(code)"
            } else {
                "HLS preflight transport failed"
            }
        }
    }
}

extension AetherEngine {
    /// Fetch and inspect an HLS playlist, selected media playlist, init segment (when present), and first
    /// media segment before creating any playback session. The result is deterministic and never invokes an
    /// AVPlayer-first / black-screen-later fallback.
    ///
    /// `sourceIsSeekableVOD` has no inferred default. Hybrid playback requires the caller to establish this
    /// source fact from its catalog/session contract rather than treating `#EXT-X-ENDLIST` as proof.
    public nonisolated static func preflightHLS(
        url: URL,
        sourceIsSeekableVOD: Bool,
        variantSelection: HLSPreflightVariantSelection,
        hybridCapabilities: HybridPlaybackCapabilities,
        options: LoadOptions = .init()
    ) async throws -> PlaybackPreflightResult {
        try await preflightHLSPlayback(
            url: url,
            sourceIsSeekableVOD: sourceIsSeekableVOD,
            variantSelection: variantSelection,
            hybridCapabilities: hybridCapabilities,
            options: options
        ).result
    }

    /// Inspect HLS packaging and retain an opaque binding to the exact selected VOD video resources.
    ///
    /// Raw signed URLs and HTTP headers remain engine-private. The returned resource digest and mirrored
    /// timeline are safe for host diagnostics, while every HLS hybrid session must consume the opaque
    /// binding instead of reopening the root master and selecting a potentially different variant. Every
    /// separate alternate-audio playlist in the selected group is bound too. An admitted result can be
    /// passed only to `AetherHybridPlaybackSession.makeHLSVOD(preflight:)`; the generic seekable-VOD
    /// factory rejects HLS so callers cannot bypass this graph binding.
    /// Gate 1 hosts that require a structured started/completed/failed lifecycle must execute this work
    /// through `AetherPlaybackPreflightOperation.inspectHLS`.
    public nonisolated static func preflightHLSPlayback(
        url: URL,
        sourceIsSeekableVOD: Bool,
        variantSelection: HLSPreflightVariantSelection,
        hybridCapabilities: HybridPlaybackCapabilities,
        options: LoadOptions = .init()
    ) async throws -> AetherHLSPlaybackPreflight {
        let inspector = HLSPreflightInspector(httpHeaders: options.httpHeaders)
        return try await inspector.inspect(
            rootURL: url,
            sourceIsSeekableVOD: sourceIsSeekableVOD,
            variantSelection: variantSelection,
            hybridCapabilities: hybridCapabilities
        )
    }
}

struct HLSPreflightFetchResponse: Sendable {
    let data: Data
    let effectiveURL: URL
}

private struct HLSPreflightResolvedMedia: Sendable {
    let variant: HLSVariant?
    let separateAudioGroupID: String?
    let audioRenditions: [HLSAudioRendition]
    let separateSubtitleGroupID: String?
    let subtitleRenditions: [HLSSubtitleRendition]
    let rootEffectiveURL: URL
    let mediaURL: URL
    let mediaData: Data
    let media: HLSMediaPlaylist
}

private struct HLSInspectedVideo: Sendable {
    let codec: AetherVideoCodec
    let format: VideoFormat
    let dolbyVisionConfiguration:
        AetherDolbyVisionConfiguration?
    let hasVerifiedDolbyVisionProfile84BaseLayer: Bool
    let sampleEntry: HLSVideoSampleEntry
    let hdr10PlusEvidence:
        AetherHLSHDR10PlusPreflightEvidence
    let overlaySubtitleTracks:
        [AetherHybridOverlaySubtitleTrack]
}

private struct HLSProtectedManifestVideo: Sendable {
    let codec: AetherVideoCodec
    let format: VideoFormat
    let container: HLSVideoContainer
    let sampleEntry: HLSVideoSampleEntry
}

/// Stateful only through its immutable HTTP header set. Tests exercise parsing and verification helpers
/// directly; runtime I/O is isolated here so it cannot fall back to the AudioTap retry path.
struct HLSPreflightInspector {
    typealias Fetch = @Sendable (
        _ url: URL,
        _ httpHeaders: [String: String]
    ) async throws -> HLSPreflightFetchResponse

    private let httpHeaders: [String: String]
    private let fetchOverride: Fetch?

    init(
        httpHeaders: [String: String],
        fetchOverride: Fetch? = nil
    ) {
        self.httpHeaders = httpHeaders
        self.fetchOverride = fetchOverride
    }

    func inspect(
        rootURL: URL,
        sourceIsSeekableVOD: Bool,
        variantSelection: HLSPreflightVariantSelection,
        hybridCapabilities: HybridPlaybackCapabilities
    ) async throws -> AetherHLSPlaybackPreflight {
        let resolved = try await resolveMedia(
            rootURL: rootURL,
            selection: variantSelection
        )
        let manifestCodecs = (resolved.variant?.codecs ?? [])
            + (resolved.variant?.supplementalCodecs ?? [])

        // Protected media never enters hybrid direct decode. A manifest contract that is already
        // AVPlayer-native stays native without fetching a key, init segment or media body. Every contract
        // that would require AetherEngine clear samples becomes a normal typed unsupported route.
        guard resolved.media.contentProtection == .none else {
            let protectedResult = protectedManifestResult(
                resolved: resolved,
                isSeekableVOD: sourceIsSeekableVOD,
                manifestCodecs: manifestCodecs,
                hybridCapabilities: hybridCapabilities
            )
            return AetherHLSPlaybackPreflight(
                result: protectedResult,
                resourceGraph: nil,
                httpHeaders: httpHeaders,
                audioAnalysisPolicy:
                    try await inspectNativeAudioAnalysisPolicy(
                        resolved
                    )
            )
        }

        // The parser currently records only that a byte range exists, not its offset/length. Fetching the
        // whole backing object would be both unbounded and different from the selected HLS resource.
        guard !resolved.media.hasByteRange else {
            return AetherHLSPlaybackPreflight(
                result: unresolvedResult(
                    isSeekableVOD: sourceIsSeekableVOD,
                    manifestCodecs: manifestCodecs,
                    contentProtection: .none,
                    hybridCapabilities: hybridCapabilities
                ),
                resourceGraph: nil,
                httpHeaders: httpHeaders
            )
        }

        guard let firstSegment = resolved.media.segments.first,
              let segmentURL = HLSPlaylistParser.resolve(uri: firstSegment.uri, against: resolved.mediaURL) else {
            throw HLSPreflightError.unresolvableURI(resolved.media.segments.first?.uri ?? "<missing first segment>")
        }
        let segment = try await fetch(segmentURL)

        let container: HLSVideoContainer
        let initSegment: Data?
        let initSegmentEffectiveURL: URL?
        if let mapURI = resolved.media.mapURI {
            guard let initURL = HLSPlaylistParser.resolve(uri: mapURI, against: resolved.mediaURL) else {
                throw HLSPreflightError.unresolvableURI(mapURI)
            }
            container = .fragmentedMP4
            let response = try await fetch(initURL)
            initSegment = response.data
            initSegmentEffectiveURL = response.effectiveURL
        } else {
            // RFC 8216 fragmented-MP4 media requires EXT-X-MAP. A video
            // rendition without a map is therefore admitted through the
            // MPEG-TS demux probe. FFmpeg, not a byte-zero magic check,
            // establishes whether the selected segment is actually usable;
            // this also accepts transport streams with recoverable leading
            // data while preserving a typed unsupported result on probe
            // failure.
            container = .mpegTransport
            initSegment = nil
            initSegmentEffectiveURL = nil
        }

        guard let inspected = Self.inspectVideo(
            initSegment: initSegment,
            segment: segment.data,
            container: container
        ) else {
            return AetherHLSPlaybackPreflight(
                result: unresolvedResult(
                    isSeekableVOD: sourceIsSeekableVOD,
                    manifestCodecs: manifestCodecs,
                    contentProtection: .none,
                    hybridCapabilities: hybridCapabilities,
                    container: container
                ),
                resourceGraph: nil,
                httpHeaders: httpHeaders
            )
        }

        let packaging = HLSVideoPackaging(
            container: container,
            sampleEntry: inspected.sampleEntry,
            manifestCodecs: manifestCodecs,
            actualVideoCodec: inspected.codec,
            codecVerification: Self.codecVerification(
                manifestCodecs: manifestCodecs,
                actualCodec: inspected.codec,
                sampleEntry: inspected.sampleEntry
            ),
            contentProtection: .none
        )
        let hdr10PlusAdmission = Self.resolveHDR10PlusAdmission(
            baseFormat: inspected.format,
            evidence: inspected.hdr10PlusEvidence
        )
        let source = AetherSourceProfile(
            sourceKind: .hls,
            isSeekableVOD: sourceIsSeekableVOD,
            videoCodec: inspected.codec,
            videoFormat: hdr10PlusAdmission.videoFormat,
            dolbyVisionConfiguration:
                inspected.dolbyVisionConfiguration,
            hasVerifiedDolbyVisionProfile84BaseLayer:
                inspected.hasVerifiedDolbyVisionProfile84BaseLayer
        )
        let resolvedResult = PlaybackPreflight.resolve(
            sourceProfile: source,
            hlsPackaging: packaging,
            hybridCapabilities: hybridCapabilities
        )
        let result = hdr10PlusAdmission.failureReason.map {
            PlaybackPreflightResult(
                sourceProfile: source,
                hlsPackaging: packaging,
                route: .unsupported,
                reason: $0
            )
        } ?? resolvedResult
        let resourceGraph: HLSVODResourceGraph?
        let audioAnalysisPolicy:
            AetherHLSAudioAnalysisPolicy
        let subtitlePolicies:
            [AetherHLSSubtitleRenditionPolicy]
        if result.route == .hybridCarrier {
            let subtitleResolution =
                try await resolveSubtitleRenditions(
                    resolved.subtitleRenditions,
                    rootEffectiveURL:
                        resolved.rootEffectiveURL,
                    selectedVideoMedia:
                        resolved.media
                )
            subtitlePolicies =
                subtitleResolution.policies
            let audioResolution = try await resolveAudioRenditions(
                resolved.audioRenditions,
                rootEffectiveURL: resolved.rootEffectiveURL
            )
            switch audioResolution {
            case .clear(
                let audioRenditions,
                let renditionPolicies
            ):
                resourceGraph = try HLSVODResourceGraph.make(
                    requestedRootURL: rootURL,
                    effectiveRootURL: resolved.rootEffectiveURL,
                    selectedMediaPlaylistURL: resolved.mediaURL,
                    selectedVariant: resolved.variant,
                    separateAudioGroupID: resolved.separateAudioGroupID,
                    mediaPlaylistData: resolved.mediaData,
                    media: resolved.media,
                    audioRenditions: audioRenditions,
                    separateSubtitleGroupID:
                        subtitleResolution.resources.isEmpty
                        ? nil
                        : resolved.separateSubtitleGroupID,
                    subtitleRenditions:
                        subtitleResolution.resources,
                    inspectedInitSegmentData: initSegment,
                    inspectedInitSegmentEffectiveURL:
                        initSegmentEffectiveURL,
                    inspectedFirstMediaSegmentData: segment.data,
                    inspectedFirstMediaSegmentEffectiveURL:
                        segment.effectiveURL,
                    httpHeaders: httpHeaders
                )
                audioAnalysisPolicy =
                    renditionPolicies.isEmpty
                    ? .sessionScopedTrackAvailability
                    : .selectedAlternateAudioRenditions(
                        renditionPolicies
                    )
            case .protected(
                let protection,
                let renditionPolicies
            ):
                return AetherHLSPlaybackPreflight(
                    result: unsupportedProtectedHybridResult(
                        result,
                        protection: protection,
                        hybridCapabilities:
                            hybridCapabilities
                    ),
                    resourceGraph: nil,
                    httpHeaders: httpHeaders,
                    audioAnalysisPolicy:
                        .selectedAlternateAudioRenditions(
                            renditionPolicies
                        ),
                    subtitleRenditions:
                        subtitlePolicies,
                    hdr10PlusEvidence:
                        inspected.hdr10PlusEvidence
                )
            }
        } else {
            resourceGraph = nil
            subtitlePolicies = []
            audioAnalysisPolicy =
                try await inspectNativeAudioAnalysisPolicy(
                    resolved
                )
        }
        return AetherHLSPlaybackPreflight(
            result: result,
            resourceGraph: resourceGraph,
            httpHeaders: httpHeaders,
            audioAnalysisPolicy:
                audioAnalysisPolicy,
            subtitleRenditions:
                subtitlePolicies,
            overlaySubtitleTracks:
                inspected.overlaySubtitleTracks,
            hdr10PlusEvidence:
                inspected.hdr10PlusEvidence
        )
    }

    private func resolveMedia(
        rootURL: URL,
        selection: HLSPreflightVariantSelection
    ) async throws -> HLSPreflightResolvedMedia {
        let root = try await fetch(rootURL)
        let rootPlaylist = try parsePlaylist(root.data)
        switch rootPlaylist {
        case .media(let media):
            return HLSPreflightResolvedMedia(
                variant: nil,
                separateAudioGroupID: nil,
                audioRenditions: [],
                separateSubtitleGroupID: nil,
                subtitleRenditions: [],
                rootEffectiveURL: root.effectiveURL,
                mediaURL: root.effectiveURL,
                mediaData: root.data,
                media: media
            )

        case .master(let master):
            let variant: HLSVariant
            switch selection {
            case .highestBandwidth:
                guard let selected = master.variants.max(by: { $0.bandwidth < $1.bandwidth }) else {
                    throw HLSPreflightError.invalidPlaylist("master playlist without variants")
                }
                variant = selected
            case .exactURI(let uri):
                guard let selected = master.variants.first(where: { $0.uri == uri }) else {
                    throw HLSPreflightError.requestedVariantNotFound(uri)
                }
                variant = selected
            }
            guard let mediaURL = HLSPlaylistParser.resolve(uri: variant.uri, against: root.effectiveURL) else {
                throw HLSPreflightError.unresolvableURI(variant.uri)
            }
            let response = try await fetch(mediaURL)
            guard case .media(let media) = try parsePlaylist(response.data) else {
                throw HLSPreflightError.selectedVariantWasNotMediaPlaylist
            }
            return HLSPreflightResolvedMedia(
                variant: variant,
                separateAudioGroupID: variant.audioGroupID.flatMap {
                    master.demuxedAudioGroupIDs.contains($0)
                        ? $0
                        : nil
                },
                audioRenditions: variant.audioGroupID.map {
                    groupID in
                    master.audioRenditions.filter {
                        $0.groupID == groupID
                    }
                } ?? [],
                separateSubtitleGroupID:
                    variant.subtitleGroupID,
                subtitleRenditions:
                    variant.subtitleGroupID.map {
                        groupID in
                        master.subtitleRenditions.filter {
                            $0.groupID == groupID
                        }
                    } ?? [],
                rootEffectiveURL: root.effectiveURL,
                mediaURL: response.effectiveURL,
                mediaData: response.data,
                media: media
            )
        }
    }

    private enum AudioRenditionResolution {
        case clear(
            [HLSVODAudioRenditionResource],
            [AetherHLSAudioRenditionAnalysisPolicy]
        )
        case protected(
            HLSContentProtection,
            [AetherHLSAudioRenditionAnalysisPolicy]
        )
    }

    private struct SubtitleRenditionResolution {
        let resources:
            [HLSVODSubtitleRenditionResource]
        let policies:
            [AetherHLSSubtitleRenditionPolicy]
    }

    private func resolveSubtitleRenditions(
        _ renditions: [HLSSubtitleRendition],
        rootEffectiveURL: URL,
        selectedVideoMedia: HLSMediaPlaylist
    ) async throws -> SubtitleRenditionResolution {
        guard !renditions.isEmpty else {
            return SubtitleRenditionResolution(
                resources: [],
                policies: []
            )
        }
        let manifestIsValid =
            renditions.filter(\.isDefault).count <= 1
            && Set(renditions.map(\.name)).count
                == renditions.count
        guard manifestIsValid else {
            return SubtitleRenditionResolution(
                resources: [],
                policies: renditions.enumerated().map {
                    Self.subtitlePolicy(
                        sourceOrdinal: $0.offset,
                        rendition: $0.element,
                        availability: .unavailable(
                            .invalidManifest
                        )
                    )
                }
            )
        }

        var resources:
            [HLSVODSubtitleRenditionResource] = []
        var policies:
            [AetherHLSSubtitleRenditionPolicy] = []
        resources.reserveCapacity(renditions.count)
        policies.reserveCapacity(renditions.count)
        for (sourceOrdinal, rendition) in
                renditions.enumerated() {
            do {
                guard let playlistURL =
                        HLSPlaylistParser.resolve(
                            uri: rendition.uri,
                            against: rootEffectiveURL
                        ) else {
                    policies.append(
                        Self.subtitlePolicy(
                            sourceOrdinal: sourceOrdinal,
                            rendition: rendition,
                            availability: .unavailable(
                                .invalidManifest
                            )
                        )
                    )
                    continue
                }
                let playlistResponse = try await fetch(
                    playlistURL
                )
                guard case .media(let media) =
                        try parsePlaylist(
                            playlistResponse.data
                        ) else {
                    policies.append(
                        Self.subtitlePolicy(
                            sourceOrdinal: sourceOrdinal,
                            rendition: rendition,
                            availability: .unavailable(
                                .invalidManifest
                            )
                        )
                    )
                    continue
                }
                guard media.contentProtection == .none else {
                    policies.append(
                        Self.subtitlePolicy(
                            sourceOrdinal: sourceOrdinal,
                            rendition: rendition,
                            availability: .unavailable(
                                .contentProtectionUnsupported
                            )
                        )
                    )
                    continue
                }
                guard Self.subtitleTimelineMatches(
                    media,
                    selectedVideoMedia
                ) else {
                    policies.append(
                        Self.subtitlePolicy(
                            sourceOrdinal: sourceOrdinal,
                            rendition: rendition,
                            availability: .unavailable(
                                .timelineMismatch
                            )
                        )
                    )
                    continue
                }
                guard let first = media.segments.first,
                      let firstURL =
                        HLSPlaylistParser.resolve(
                            uri: first.uri,
                            against:
                                playlistResponse.effectiveURL
                        ) else {
                    policies.append(
                        Self.subtitlePolicy(
                            sourceOrdinal: sourceOrdinal,
                            rendition: rendition,
                            availability: .unavailable(
                                .invalidManifest
                            )
                        )
                    )
                    continue
                }
                let firstResponse = try await fetch(firstURL)
                let resource = try HLSVODResourceGraph
                    .makeSubtitleRendition(
                        ordinal: resources.count,
                        metadata: rendition,
                        playlistURL:
                            playlistResponse.effectiveURL,
                        playlistData:
                            playlistResponse.data,
                        media: media,
                        inspectedFirstSegmentData:
                            firstResponse.data,
                        inspectedFirstSegmentEffectiveURL:
                            firstResponse.effectiveURL
                    )
                resources.append(resource)
                policies.append(
                    Self.subtitlePolicy(
                        sourceOrdinal: sourceOrdinal,
                        rendition: rendition,
                        availability: .nativeWebVTT
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as HLSPreflightError {
                if case .transportFailure(let code) = error,
                   code == URLError.cancelled.rawValue {
                    throw CancellationError()
                }
                policies.append(
                    Self.subtitlePolicy(
                        sourceOrdinal: sourceOrdinal,
                        rendition: rendition,
                        availability: .unavailable(
                            Self.subtitleUnavailableReason(
                                error
                            )
                        )
                    )
                )
            } catch {
                policies.append(
                    Self.subtitlePolicy(
                        sourceOrdinal: sourceOrdinal,
                        rendition: rendition,
                        availability: .unavailable(
                            .resourceUnavailable
                        )
                    )
                )
            }
        }
        return SubtitleRenditionResolution(
            resources: resources,
            policies: policies
        )
    }

    private static func subtitleTimelineMatches(
        _ subtitle: HLSMediaPlaylist,
        _ video: HLSMediaPlaylist
    ) -> Bool {
        guard subtitle.hasEndList,
              !subtitle.hasByteRange,
              subtitle.mapURI == nil,
              subtitle.segments.count
                == video.segments.count else {
            return false
        }
        return zip(
            subtitle.segments,
            video.segments
        ).allSatisfy { pair in
            CMTime(
                seconds: pair.0.duration,
                preferredTimescale:
                    BlackCarrierProfile.approved.timescale
            ) == CMTime(
                seconds: pair.1.duration,
                preferredTimescale:
                    BlackCarrierProfile.approved.timescale
            )
        }
    }

    private static func subtitlePolicy(
        sourceOrdinal: Int,
        rendition: HLSSubtitleRendition,
        availability:
            AetherHLSSubtitleRenditionAvailability
    ) -> AetherHLSSubtitleRenditionPolicy {
        AetherHLSSubtitleRenditionPolicy(
            subtitleTrackID: sourceOrdinal,
            name: rendition.name,
            language: rendition.language,
            isDefault: rendition.isDefault,
            isAutoselect: rendition.isAutoselect,
            isForced: rendition.isForced,
            availability: availability
        )
    }

    private static func subtitleUnavailableReason(
        _ error: HLSPreflightError
    ) -> AetherHLSSubtitleUnavailableReason {
        switch error {
        case .unsupportedSeekableVODResourceGraph(
            let reason
        ) where reason.contains("not WebVTT"):
            .unsupportedFormat
        case .unsupportedSeekableVODResourceGraph:
            .invalidManifest
        case .invalidPlaylist,
             .unresolvableURI,
             .selectedVariantWasNotMediaPlaylist,
             .seekableVODPlaylistNotFinite:
            .invalidManifest
        case .httpStatus,
             .resourceTooLarge,
             .unsupportedContentEncoding,
             .contentLengthMismatch,
             .redirectCredentialScopeViolation,
             .nonHTTPResponse,
             .transportFailure,
             .requestedVariantNotFound:
            .resourceUnavailable
        }
    }

    private func resolveAudioRenditions(
        _ renditions: [HLSAudioRendition],
        rootEffectiveURL: URL
    ) async throws -> AudioRenditionResolution {
        var inspected: [(
            ordinal: Int,
            rendition: HLSAudioRendition,
            response: HLSPreflightFetchResponse,
            media: HLSMediaPlaylist
        )] = []
        var policies:
            [AetherHLSAudioRenditionAnalysisPolicy] = []
        var protectedContent:
            HLSContentProtection?
        inspected.reserveCapacity(renditions.count)
        policies.reserveCapacity(renditions.count)
        for (ordinal, rendition) in renditions.enumerated() {
            guard let playlistURL = HLSPlaylistParser.resolve(
                uri: rendition.uri,
                against: rootEffectiveURL
            ) else {
                throw HLSPreflightError.unresolvableURI(
                    rendition.uri
                )
            }
            let response = try await fetch(playlistURL)
            guard case .media(let media) =
                    try parsePlaylist(response.data) else {
                throw HLSPreflightError.invalidPlaylist(
                    "alternate-audio rendition was not a media playlist"
                )
            }
            inspected.append((
                ordinal: ordinal,
                rendition: rendition,
                response: response,
                media: media
            ))
            if media.contentProtection != .none {
                protectedContent =
                    protectedContent
                    ?? media.contentProtection
                policies.append(
                    Self.audioRenditionPolicy(
                        ordinal: ordinal,
                        rendition: rendition,
                        availability: .unavailable(
                            .contentProtectionUnsupported
                        )
                    )
                )
                continue
            }
            policies.append(
                Self.audioRenditionPolicy(
                    ordinal: ordinal,
                    rendition: rendition,
                    availability:
                        .requiresPlaybackSessionBinding
                )
            )
        }
        if let protectedContent {
            return .protected(
                protectedContent,
                policies
            )
        }
        let resources = try inspected.map {
            try HLSVODResourceGraph.makeAudioRendition(
                ordinal: $0.ordinal,
                metadata: $0.rendition,
                playlistURL: $0.response.effectiveURL,
                playlistData: $0.response.data,
                media: $0.media
            )
        }
        return .clear(resources, policies)
    }

    /// Native playback remains available when optional analysis metadata cannot be inspected. Each failed
    /// rendition is marked unavailable with a privacy-safe reason; the failure never changes the playback
    /// route and never triggers a media-body or key request.
    private func inspectNativeAudioAnalysisPolicy(
        _ resolved: HLSPreflightResolvedMedia
    ) async throws -> AetherHLSAudioAnalysisPolicy {
        guard !resolved.audioRenditions.isEmpty else {
            return resolved.media.contentProtection == .none
                ? .sessionScopedTrackAvailability
                : .unavailableForAllTracks(
                    .contentProtectionUnsupported
                )
        }

        var policies:
            [AetherHLSAudioRenditionAnalysisPolicy] = []
        policies.reserveCapacity(
            resolved.audioRenditions.count
        )
        for (ordinal, rendition) in
                resolved.audioRenditions.enumerated() {
            let unavailable: AudioAnalysisError =
                .hlsResourceFailure(
                    "alternate-audio playlist preflight failed"
                )
            guard let playlistURL =
                    HLSPlaylistParser.resolve(
                        uri: rendition.uri,
                        against:
                            resolved.rootEffectiveURL
                    ) else {
                policies.append(
                    Self.audioRenditionPolicy(
                        ordinal: ordinal,
                        rendition: rendition,
                        availability:
                            .unavailable(unavailable)
                    )
                )
                continue
            }
            do {
                let response = try await fetch(
                    playlistURL
                )
                guard case .media(let media) =
                        try parsePlaylist(response.data)
                else {
                    policies.append(
                        Self.audioRenditionPolicy(
                            ordinal: ordinal,
                            rendition: rendition,
                            availability:
                                .unavailable(unavailable)
                        )
                    )
                    continue
                }
                policies.append(
                    Self.audioRenditionPolicy(
                        ordinal: ordinal,
                        rendition: rendition,
                        availability:
                            media.contentProtection
                                == .none
                            ? .requiresPlaybackSessionBinding
                            : .unavailable(
                                .contentProtectionUnsupported
                            )
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as HLSPreflightError {
                if case .transportFailure(let code) =
                        error,
                   code == URLError.cancelled.rawValue {
                    throw CancellationError()
                }
                policies.append(
                    Self.audioRenditionPolicy(
                        ordinal: ordinal,
                        rendition: rendition,
                        availability:
                            .unavailable(unavailable)
                    )
                )
            } catch {
                policies.append(
                    Self.audioRenditionPolicy(
                        ordinal: ordinal,
                        rendition: rendition,
                        availability:
                            .unavailable(unavailable)
                    )
                )
            }
        }
        return .selectedAlternateAudioRenditions(
            policies
        )
    }

    private static func audioRenditionPolicy(
        ordinal: Int,
        rendition: HLSAudioRendition,
        availability:
            AetherHLSAudioAnalysisPreflightAvailability
    ) -> AetherHLSAudioRenditionAnalysisPolicy {
        AetherHLSAudioRenditionAnalysisPolicy(
            audioTrackID: ordinal,
            name: rendition.name,
            language: rendition.language,
            isDefault: rendition.isDefault,
            availability: availability
        )
    }

    private func fetch(_ url: URL) async throws -> HLSPreflightFetchResponse {
        if let fetchOverride {
            return try await fetchOverride(url, httpHeaders)
        }
        var request = URLRequest(url: url)
        for (field, value) in httpHeaders { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue(
            "identity",
            forHTTPHeaderField: "Accept-Encoding"
        )
        do {
            let response = try await HLSVODBoundedHTTPFetcher
                .fetch(
                    request: request,
                    maximumBytes:
                        HLSVODOriginResourceLoader
                            .defaultMaximumResourceBytes
                )
            return HLSPreflightFetchResponse(
                data: response.data,
                effectiveURL: response.effectiveURL
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HLSVODOriginResourceError {
            switch error {
            case .httpStatus(let status):
                throw HLSPreflightError.httpStatus(status)
            case .resourceTooLarge(let limit, _):
                throw HLSPreflightError.resourceTooLarge(
                    limit: limit
                )
            case .unsupportedContentEncoding(let value):
                throw HLSPreflightError
                    .unsupportedContentEncoding(value)
            case .contentLengthMismatch(
                let expected,
                let actual
            ):
                throw HLSPreflightError
                    .contentLengthMismatch(
                        expected: expected,
                        actual: actual
                    )
            case .redirectCredentialScopeViolation:
                throw HLSPreflightError
                    .redirectCredentialScopeViolation
            case .nonHTTPResponse:
                throw HLSPreflightError.nonHTTPResponse
            case .transport(let code):
                throw HLSPreflightError.transportFailure(
                    code: code.rawValue
                )
            case .transportFailure:
                throw HLSPreflightError.transportFailure(
                    code: nil
                )
            default:
                throw HLSPreflightError.invalidPlaylist(
                    error.localizedDescription
                )
            }
        } catch let error as URLError {
            throw HLSPreflightError.transportFailure(
                code: error.code.rawValue
            )
        } catch {
            throw HLSPreflightError.transportFailure(code: nil)
        }
    }

    private func parsePlaylist(_ data: Data) throws -> HLSPlaylist {
        guard let text = String(data: data, encoding: .utf8) else {
            throw HLSPreflightError.invalidPlaylist("non-UTF8")
        }
        do {
            return try HLSPlaylistParser.parse(text)
        } catch HLSIngestError.playlistInvalid(let reason) {
            throw HLSPreflightError.invalidPlaylist(reason)
        } catch {
            throw HLSPreflightError.invalidPlaylist(
                String(describing: error)
            )
        }
    }

    private func unresolvedResult(
        isSeekableVOD: Bool,
        manifestCodecs: [String],
        contentProtection: HLSContentProtection,
        hybridCapabilities: HybridPlaybackCapabilities,
        container: HLSVideoContainer = .unknown
    ) -> PlaybackPreflightResult {
        let source = AetherSourceProfile(
            sourceKind: .hls,
            isSeekableVOD: isSeekableVOD,
            videoCodec: .unknown,
            videoFormat: .sdr
        )
        let packaging = HLSVideoPackaging(
            container: container,
            sampleEntry: .unknown,
            manifestCodecs: manifestCodecs,
            actualVideoCodec: .unknown,
            codecVerification: .segmentNotInspected,
            contentProtection: contentProtection
        )
        return PlaybackPreflight.resolve(
            sourceProfile: source,
            hlsPackaging: packaging,
            hybridCapabilities: hybridCapabilities
        )
    }

    private func protectedManifestResult(
        resolved: HLSPreflightResolvedMedia,
        isSeekableVOD: Bool,
        manifestCodecs: [String],
        hybridCapabilities: HybridPlaybackCapabilities
    ) -> PlaybackPreflightResult {
        guard let inspected = Self.inspectProtectedManifestVideo(
            manifestCodecs: manifestCodecs,
            videoRange: resolved.variant?.videoRange,
            hasMap: resolved.media.hasMap
        ) else {
            return unresolvedResult(
                isSeekableVOD: isSeekableVOD,
                manifestCodecs: manifestCodecs,
                contentProtection:
                    resolved.media.contentProtection,
                hybridCapabilities: hybridCapabilities
            )
        }
        let source = AetherSourceProfile(
            sourceKind: .hls,
            isSeekableVOD: isSeekableVOD,
            videoCodec: inspected.codec,
            videoFormat: inspected.format
        )
        let packaging = HLSVideoPackaging(
            container: inspected.container,
            sampleEntry: inspected.sampleEntry,
            manifestCodecs: manifestCodecs,
            actualVideoCodec: inspected.codec,
            codecVerification: .protectedManifestVerified,
            contentProtection:
                resolved.media.contentProtection
        )
        return PlaybackPreflight.resolve(
            sourceProfile: source,
            hlsPackaging: packaging,
            hybridCapabilities: hybridCapabilities
        )
    }

    private func unsupportedProtectedHybridResult(
        _ result: PlaybackPreflightResult,
        protection: HLSContentProtection,
        hybridCapabilities: HybridPlaybackCapabilities
    ) -> PlaybackPreflightResult {
        guard let packaging = result.hlsPackaging else {
            return PlaybackPreflightResult(
                sourceProfile: result.sourceProfile,
                hlsPackaging: nil,
                route: .unsupported,
                reason: .unsupportedHLSContentProtection
            )
        }
        let protectedPackaging = HLSVideoPackaging(
            container: packaging.container,
            sampleEntry: packaging.sampleEntry,
            manifestCodecs: packaging.manifestCodecs,
            actualVideoCodec: packaging.actualVideoCodec,
            codecVerification: packaging.codecVerification,
            contentProtection: protection
        )
        return PlaybackPreflight.resolve(
            sourceProfile: result.sourceProfile,
            hlsPackaging: protectedPackaging,
            hybridCapabilities: hybridCapabilities
        )
    }

    private static func inspectProtectedManifestVideo(
        manifestCodecs: [String],
        videoRange: String?,
        hasMap: Bool
    ) -> HLSProtectedManifestVideo? {
        let tokens = manifestCodecs.filter(isVideoCodecToken)
        let codecs = Set(tokens.compactMap(codec(forManifestToken:)))
        guard codecs.count == 1,
              let codec = codecs.first else {
            return nil
        }
        let sampleEntry: HLSVideoSampleEntry
        if tokens.contains(where: { $0.hasPrefix("dvh1") }) {
            sampleEntry = .dvh1
        } else if tokens.contains(where: { $0.hasPrefix("hvc1") }) {
            sampleEntry = .hvc1
        } else if tokens.contains(where: { $0.hasPrefix("hev1") }) {
            sampleEntry = .hev1
        } else if tokens.contains(where: {
            $0.hasPrefix("avc1") || $0.hasPrefix("avc3")
        }) {
            sampleEntry = .avc1
        } else {
            sampleEntry = .unknown
        }
        return HLSProtectedManifestVideo(
            codec: codec,
            format: manifestVideoFormat(
                tokens: tokens,
                videoRange: videoRange
            ),
            container: hasMap
                ? .fragmentedMP4
                : .mpegTransport,
            sampleEntry: sampleEntry
        )
    }

    private static func codec(
        forManifestToken token: String
    ) -> AetherVideoCodec? {
        if token.hasPrefix("avc1")
            || token.hasPrefix("avc3") {
            return .h264
        }
        if token.hasPrefix("hvc1")
            || token.hasPrefix("hev1")
            || token.hasPrefix("dvh1")
            || token.hasPrefix("dvhe") {
            return .hevc
        }
        if token.hasPrefix("av01") {
            return .av1
        }
        if token.hasPrefix("vp09") {
            return .vp9
        }
        if token.hasPrefix("vp08") {
            return .vp8
        }
        if token.hasPrefix("mp4v") {
            return .mpeg4Part2
        }
        if token.hasPrefix("mpeg2") {
            return .mpeg2
        }
        if token.hasPrefix("vc-1") {
            return .vc1
        }
        return nil
    }

    private static func manifestVideoFormat(
        tokens: [String],
        videoRange: String?
    ) -> VideoFormat {
        if tokens.contains(where: {
            $0.hasPrefix("dvh1") || $0.hasPrefix("dvhe")
        }) {
            return .dolbyVision
        }
        switch videoRange?.uppercased() {
        case "PQ":
            return .hdr10
        case "HLG":
            return .hlg
        default:
            return .sdr
        }
    }

    private static func inspectVideo(
        initSegment: Data?,
        segment: Data,
        container: HLSVideoContainer
    ) -> HLSInspectedVideo? {
        let probeData: Data
        let formatHint: String
        let sampleEntry: HLSVideoSampleEntry
        switch container {
        case .fragmentedMP4:
            guard let initSegment else { return nil }
            probeData = initSegment + segment
            formatHint = "mp4"
            sampleEntry = BMFFVideoSampleEntryInspector.inspect(initSegment: initSegment)
        case .mpegTransport:
            probeData = segment
            formatHint = "mpegts"
            sampleEntry = .notApplicable
        case .unknown:
            return nil
        }

        let demuxer = Demuxer()
        do {
            try demuxer.open(reader: DataIOReader(data: probeData), formatHint: formatHint)
            defer { demuxer.close() }
            let probe = AetherEngine.makeSourceProbe(
                demuxer: demuxer,
                displayURL: URL(string: "aether-hls-preflight://segment")!
            )
            let codec = AetherVideoCodec(codecName: probe.videoCodecName)
            guard codec != .unknown else { return nil }
            let hdr10PlusEvidence = inspectHDR10PlusEvidence(
                demuxer: demuxer,
                codec: codec,
                container: container
            )
            return HLSInspectedVideo(
                codec: codec,
                format: probe.videoFormat,
                dolbyVisionConfiguration:
                    probe.dolbyVisionConfiguration,
                hasVerifiedDolbyVisionProfile84BaseLayer:
                    probe.hasVerifiedDolbyVisionProfile84BaseLayer,
                sampleEntry: sampleEntry,
                hdr10PlusEvidence: hdr10PlusEvidence,
                overlaySubtitleTracks:
                    demuxer.subtitleTrackInfos().compactMap {
                        info in
                        let kind:
                            AetherHybridOverlaySubtitleKind
                        if AetherEngine.isBitmapSubtitleCodec(
                            info.codec
                        ) {
                            kind = .bitmap
                        } else if info.codec == "ass"
                                    || info.codec == "ssa" {
                            kind = .styledText
                        } else {
                            return nil
                        }
                        return AetherHybridOverlaySubtitleTrack(
                            id: info.id,
                            name: info.name,
                            language: info.language,
                            isDefault: info.isDefault,
                            isForced: info.isForced,
                            kind: kind
                        )
                    }
            )
        } catch {
            return nil
        }
    }

    private static func inspectHDR10PlusEvidence(
        demuxer: Demuxer,
        codec: AetherVideoCodec,
        container: HLSVideoContainer
    ) -> AetherHLSHDR10PlusPreflightEvidence {
        guard codec == .hevc else {
            return .notRequired
        }
        let framing: HEVCCompressedSampleFraming
        switch container {
        case .mpegTransport:
            framing = .annexB
        case .fragmentedMP4:
            guard let stream = demuxer.stream(
                at: demuxer.videoStreamIndex
            ),
            let codecParameters = stream.pointee.codecpar,
            let extradata = codecParameters.pointee.extradata,
            codecParameters.pointee.extradata_size > 21 else {
                return .compressedSampleUninspectable(
                    sampleIndex: 0
                )
            }
            let lengthFieldBytes =
                Int(extradata[21] & 0x03) + 1
            guard (1...4).contains(lengthFieldBytes) else {
                return .compressedSampleUninspectable(
                    sampleIndex: 0
                )
            }
            framing = .lengthPrefixed(
                lengthFieldBytes: lengthFieldBytes
            )
        case .unknown:
            return .compressedSampleUninspectable(
                sampleIndex: 0
            )
        }

        let videoStreamIndex = demuxer.videoStreamIndex
        guard videoStreamIndex >= 0 else {
            return .compressedSampleUninspectable(
                sampleIndex: 0
            )
        }
        var sampleIndex = 0
        do {
            while let packet = try demuxer.readPacket() {
                var packetToFree:
                    UnsafeMutablePointer<AVPacket>? = packet
                defer {
                    trackedPacketFree(&packetToFree)
                }
                guard packet.pointee.stream_index
                        == videoStreamIndex else {
                    continue
                }
                guard let data = packet.pointee.data,
                      packet.pointee.size > 0 else {
                    return .compressedSampleUninspectable(
                        sampleIndex: sampleIndex
                    )
                }
                let sample = Data(
                    bytes: data,
                    count: Int(packet.pointee.size)
                )
                switch HDR10PlusCompressedSampleInspector.inspect(
                    sample,
                    framing: framing
                ) {
                case .notDetected:
                    sampleIndex += 1
                case .validated(
                    let t35PayloadByteCount
                ):
                    return .validated(
                        sampleIndex: sampleIndex,
                        t35PayloadByteCount:
                            t35PayloadByteCount
                    )
                case .malformedHDR10PlusMetadata:
                    return .malformed(
                        sampleIndex: sampleIndex
                    )
                case .malformedCompressedSample:
                    return .compressedSampleUninspectable(
                        sampleIndex: sampleIndex
                    )
                case .validatorUnavailable:
                    return .validatorUnavailable(
                        sampleIndex: sampleIndex
                    )
                }
            }
        } catch {
            return .compressedSampleUninspectable(
                sampleIndex: sampleIndex
            )
        }
        guard sampleIndex > 0 else {
            return .compressedSampleUninspectable(
                sampleIndex: 0
            )
        }
        return .notDetectedInFirstSegment(
            scannedVideoSampleCount: sampleIndex
        )
    }

    static func resolveHDR10PlusAdmission(
        baseFormat: VideoFormat,
        evidence: AetherHLSHDR10PlusPreflightEvidence
    ) -> (
        videoFormat: VideoFormat,
        failureReason: PlaybackRouteReason?
    ) {
        switch evidence {
        case .validated:
            guard baseFormat == .hdr10 else {
                return (
                    baseFormat,
                    .unsupportedHDR10PlusBaseLayerMismatch
                )
            }
            return (.hdr10Plus, nil)
        case .malformed:
            return (
                baseFormat,
                .unsupportedHDR10PlusCompressedSampleMalformed
            )
        case .compressedSampleUninspectable:
            return (
                baseFormat,
                .unsupportedHDR10PlusCompressedSampleUninspectable
            )
        case .validatorUnavailable:
            return (
                baseFormat,
                .unsupportedHDR10PlusValidatorUnavailable
            )
        case .notRequired,
             .notDetectedInFirstSegment:
            guard baseFormat != .hdr10Plus else {
                return (
                    baseFormat,
                    .unsupportedHDR10PlusCompressedSampleEvidenceMissing
                )
            }
            return (baseFormat, nil)
        }
    }

    static func codecVerification(
        manifestCodecs: [String],
        actualCodec: AetherVideoCodec,
        sampleEntry: HLSVideoSampleEntry
    ) -> HLSManifestCodecVerification {
        guard actualCodec != .unknown else { return .segmentNotInspected }
        let videoTokens = manifestCodecs.filter(Self.isVideoCodecToken)
        guard !videoTokens.isEmpty else { return .manifestMissingButSegmentVerified }
        guard videoTokens.contains(where: { Self.matches($0, actualCodec: actualCodec) }) else {
            return .mismatch
        }
        switch sampleEntry {
        case .avc1:
            return videoTokens.contains(where: { $0.hasPrefix("avc1") || $0.hasPrefix("avc3") }) ? .verified : .mismatch
        case .hvc1:
            return videoTokens.contains(where: { $0.hasPrefix("hvc1") }) ? .verified : .mismatch
        case .hev1:
            return videoTokens.contains(where: { $0.hasPrefix("hev1") }) ? .verified : .mismatch
        case .dvh1:
            return videoTokens.contains(where: { $0.hasPrefix("dvh1") }) ? .verified : .mismatch
        case .notApplicable, .unknown:
            return .verified
        }
    }

    private static func isVideoCodecToken(_ token: String) -> Bool {
        ["avc1", "avc3", "hvc1", "hev1", "dvh1", "dvhe", "av01", "vp09", "vp08", "mp4v", "mpeg2", "vc-1"].contains {
            token.hasPrefix($0)
        }
    }

    private static func matches(_ token: String, actualCodec: AetherVideoCodec) -> Bool {
        switch actualCodec {
        case .h264: token.hasPrefix("avc1") || token.hasPrefix("avc3")
        case .hevc: token.hasPrefix("hvc1") || token.hasPrefix("hev1") || token.hasPrefix("dvh1") || token.hasPrefix("dvhe")
        case .av1: token.hasPrefix("av01")
        case .vp9: token.hasPrefix("vp09")
        case .vp8: token.hasPrefix("vp08")
        case .mpeg2: token.hasPrefix("mpeg2")
        case .mpeg4Part2: token.hasPrefix("mp4v")
        case .vc1: token.hasPrefix("vc-1")
        case .unknown: false
        }
    }

}
