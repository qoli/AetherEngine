import CoreMedia
import CryptoKit
import Foundation

/// Public, privacy-safe result of HLS inspection.
///
/// The raw selected playlist, init-segment and media-segment URLs remain engine-private because they may
/// contain signed query parameters. For an admitted `.hybridCarrierMetal` route, `resourceIdentity` is a
/// SHA-256 binding over those resolved video resources, every separate alternate-audio playlist/resource,
/// the exact playlist bytes, the preflight-inspected video init/first-segment evidence and the request
/// headers. Native and unsupported routes do not create the hybrid graph. A host may persist the digest,
/// but must pass this value object back to AetherEngine rather than reconstructing an HLS resource graph
/// from public fields.
public struct AetherHLSPlaybackPreflight: Sendable, Equatable {
    public let result: PlaybackPreflightResult
    public let hybridTimeline: BlackCarrierTimeline?
    public let resourceIdentity: String?
    public let selectedVariantBandwidth: Int?
    public let mediaSegmentCount: Int
    public let hasSeparateAudioRenditions: Bool
    public let audioRenditionCount: Int

    let resourceGraph: HLSVODResourceGraph?
    let httpHeaders: [String: String]

    init(
        result: PlaybackPreflightResult,
        resourceGraph: HLSVODResourceGraph?,
        httpHeaders: [String: String]
    ) {
        self.result = result
        hybridTimeline = resourceGraph?.timeline
        resourceIdentity = resourceGraph?.identity
        selectedVariantBandwidth = resourceGraph?.selectedVariantBandwidth
        mediaSegmentCount = resourceGraph?.segments.count ?? 0
        audioRenditionCount =
            resourceGraph?.audioRenditions.count ?? 0
        hasSeparateAudioRenditions = audioRenditionCount > 0
        self.resourceGraph = resourceGraph
        self.httpHeaders = httpHeaders
    }
}

struct HLSVODSegmentResource: Sendable, Equatable {
    let index: Int
    let mediaSequence: Int
    let duration: CMTime
    let url: URL
}

struct HLSVODOriginScope:
    Sendable,
    Equatable,
    Hashable
{
    let scheme: String
    let host: String
    let port: Int

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else {
            return nil
        }
        self.scheme = scheme
        self.host = host
        port = url.port ?? (scheme == "https" ? 443 : 80)
    }
}

struct HLSVODAudioRenditionResource: Sendable, Equatable {
    let ordinal: Int
    let groupID: String
    let name: String
    let language: String?
    let isDefault: Bool
    let isAutoselect: Bool
    let channels: String?
    let playlistURL: URL
    let playlistData: Data
    let initSegmentURL: URL?
    let segments: [HLSVODSegmentResource]
}

enum HLSVODResourceDigest {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Engine-private immutable snapshot of the exact clear, finite HLS VOD video resources inspected before
/// route selection. Future hybrid demux generations must consume these resolved URLs; reopening the root
/// master and choosing a different adaptive variant would violate the preflight contract. Every separate
/// audio rendition in the selected variant's group is bound to the same identity. The graph now feeds the
/// incremental media pump and internal carrier session; public HLS admission remains blocked by startup
/// bandwidth ownership and the remaining public/device gates.
struct HLSVODResourceGraph: Sendable, Equatable {
    let requestedRootURL: URL
    let effectiveRootURL: URL
    let selectedMediaPlaylistURL: URL
    let selectedVariantURI: String?
    let selectedVariantBandwidth: Int?
    let separateAudioGroupID: String?
    let initSegmentURL: URL?
    let segments: [HLSVODSegmentResource]
    let audioRenditions: [HLSVODAudioRenditionResource]
    let inspectedInitSegmentData: Data?
    let inspectedInitSegmentEffectiveURL: URL?
    let inspectedFirstMediaSegmentData: Data
    let inspectedFirstMediaSegmentEffectiveURL: URL
    let timeline: BlackCarrierTimeline
    let identity: String

    static func make(
        requestedRootURL: URL,
        effectiveRootURL: URL,
        selectedMediaPlaylistURL: URL,
        selectedVariant: HLSVariant?,
        separateAudioGroupID: String?,
        mediaPlaylistData: Data,
        media: HLSMediaPlaylist,
        audioRenditions: [HLSVODAudioRenditionResource],
        inspectedInitSegmentData: Data?,
        inspectedInitSegmentEffectiveURL: URL?,
        inspectedFirstMediaSegmentData: Data,
        inspectedFirstMediaSegmentEffectiveURL: URL,
        httpHeaders: [String: String]
    ) throws -> HLSVODResourceGraph {
        if let separateAudioGroupID {
            guard !audioRenditions.isEmpty,
                  audioRenditions.allSatisfy({
                      $0.groupID == separateAudioGroupID
                  }),
                  audioRenditions.map(\.ordinal)
                    == Array(audioRenditions.indices),
                  audioRenditions.filter(\.isDefault).count <= 1 else {
                throw HLSPreflightError
                    .unsupportedSeekableVODResourceGraph(
                        reason:
                            "invalid separate alternate-audio group"
                    )
            }
        } else if !audioRenditions.isEmpty {
            throw HLSPreflightError
                .unsupportedSeekableVODResourceGraph(
                    reason:
                        "alternate-audio resources without a selected group"
                )
        }
        let initSegmentURL = try resolvedInitSegmentURL(
            media: media,
            playlistURL: selectedMediaPlaylistURL
        )
        let segmentResources = try validatedSegments(
            media: media,
            playlistURL: selectedMediaPlaylistURL,
            label: "selected video rendition"
        )
        guard !inspectedFirstMediaSegmentData.isEmpty else {
            throw HLSPreflightError.invalidPlaylist(
                "selected video first-segment evidence is empty"
            )
        }
        guard HLSVODOriginScope(
            url: inspectedFirstMediaSegmentEffectiveURL
        ) != nil else {
            throw HLSPreflightError.invalidPlaylist(
                "selected video first-segment effective URL is not HTTP(S)"
            )
        }
        if initSegmentURL == nil {
            guard inspectedInitSegmentData == nil,
                  inspectedInitSegmentEffectiveURL == nil else {
                throw HLSPreflightError.invalidPlaylist(
                    "selected video init-segment evidence has no bound URI"
                )
            }
        } else {
            guard let inspectedInitSegmentData,
                  !inspectedInitSegmentData.isEmpty,
                  let inspectedInitSegmentEffectiveURL,
                  HLSVODOriginScope(
                    url: inspectedInitSegmentEffectiveURL
                  ) != nil else {
                throw HLSPreflightError.invalidPlaylist(
                    "selected video init-segment evidence is missing"
                )
            }
        }
        let timeline = try BlackCarrierTimeline.mirroredHLSVOD(
            segmentDurations: segmentResources.map(\.duration)
        )
        for rendition in audioRenditions {
            let audioDuration = try summedDuration(
                rendition.segments
            )
            guard audioDuration == timeline.duration.value else {
                throw HLSPreflightError
                    .unsupportedSeekableVODResourceGraph(
                        reason:
                            "alternate-audio rendition duration does not match selected video"
                    )
            }
        }
        let identity = makeIdentity(
            requestedRootURL: requestedRootURL,
            effectiveRootURL: effectiveRootURL,
            selectedMediaPlaylistURL: selectedMediaPlaylistURL,
            selectedVariant: selectedVariant,
            separateAudioGroupID: separateAudioGroupID,
            mediaPlaylistData: mediaPlaylistData,
            initSegmentURL: initSegmentURL,
            segmentResources: segmentResources,
            audioRenditions: audioRenditions,
            inspectedInitSegmentData: inspectedInitSegmentData,
            inspectedInitSegmentEffectiveURL:
                inspectedInitSegmentEffectiveURL,
            inspectedFirstMediaSegmentData:
                inspectedFirstMediaSegmentData,
            inspectedFirstMediaSegmentEffectiveURL:
                inspectedFirstMediaSegmentEffectiveURL,
            httpHeaders: httpHeaders
        )
        return HLSVODResourceGraph(
            requestedRootURL: requestedRootURL,
            effectiveRootURL: effectiveRootURL,
            selectedMediaPlaylistURL: selectedMediaPlaylistURL,
            selectedVariantURI: selectedVariant?.uri,
            selectedVariantBandwidth: selectedVariant?.bandwidth,
            separateAudioGroupID: separateAudioGroupID,
            initSegmentURL: initSegmentURL,
            segments: segmentResources,
            audioRenditions: audioRenditions,
            inspectedInitSegmentData: inspectedInitSegmentData,
            inspectedInitSegmentEffectiveURL:
                inspectedInitSegmentEffectiveURL,
            inspectedFirstMediaSegmentData:
                inspectedFirstMediaSegmentData,
            inspectedFirstMediaSegmentEffectiveURL:
                inspectedFirstMediaSegmentEffectiveURL,
            timeline: timeline,
            identity: identity
        )
    }

    static func makeAudioRendition(
        ordinal: Int,
        metadata: HLSAudioRendition,
        playlistURL: URL,
        playlistData: Data,
        media: HLSMediaPlaylist
    ) throws -> HLSVODAudioRenditionResource {
        guard media.contentProtection == .none else {
            throw HLSPreflightError.unsupportedSeekableVODResourceGraph(
                reason:
                    "protected alternate-audio rendition \(metadata.name)"
            )
        }
        let segments = try validatedSegments(
            media: media,
            playlistURL: playlistURL,
            label: "alternate-audio rendition \(metadata.name)"
        )
        let initSegmentURL = try resolvedInitSegmentURL(
            media: media,
            playlistURL: playlistURL
        )
        return HLSVODAudioRenditionResource(
            ordinal: ordinal,
            groupID: metadata.groupID,
            name: metadata.name,
            language: metadata.language,
            isDefault: metadata.isDefault,
            isAutoselect: metadata.isAutoselect,
            channels: metadata.channels,
            playlistURL: playlistURL,
            playlistData: playlistData,
            initSegmentURL: initSegmentURL,
            segments: segments
        )
    }

    private static func makeIdentity(
        requestedRootURL: URL,
        effectiveRootURL: URL,
        selectedMediaPlaylistURL: URL,
        selectedVariant: HLSVariant?,
        separateAudioGroupID: String?,
        mediaPlaylistData: Data,
        initSegmentURL: URL?,
        segmentResources: [HLSVODSegmentResource],
        audioRenditions: [HLSVODAudioRenditionResource],
        inspectedInitSegmentData: Data?,
        inspectedInitSegmentEffectiveURL: URL?,
        inspectedFirstMediaSegmentData: Data,
        inspectedFirstMediaSegmentEffectiveURL: URL,
        httpHeaders: [String: String]
    ) -> String {
        var evidence = Data()
        append(requestedRootURL.absoluteString, to: &evidence)
        append(effectiveRootURL.absoluteString, to: &evidence)
        append(selectedMediaPlaylistURL.absoluteString, to: &evidence)
        append(selectedVariant?.uri ?? "<direct-media-playlist>", to: &evidence)
        append(
            selectedVariant.map { String($0.bandwidth) } ?? "<no-bandwidth>",
            to: &evidence
        )
        append(separateAudioGroupID ?? "<no-separate-audio>", to: &evidence)
        append(initSegmentURL?.absoluteString ?? "<no-init-segment>", to: &evidence)
        append(
            inspectedInitSegmentData.map(HLSVODResourceDigest.sha256)
                ?? "<no-inspected-init-segment>",
            to: &evidence
        )
        append(
            inspectedInitSegmentEffectiveURL?.absoluteString
                ?? "<no-inspected-init-effective-url>",
            to: &evidence
        )
        append(
            HLSVODResourceDigest.sha256(
                inspectedFirstMediaSegmentData
            ),
            to: &evidence
        )
        append(
            inspectedFirstMediaSegmentEffectiveURL.absoluteString,
            to: &evidence
        )
        evidence.append(mediaPlaylistData)
        evidence.append(0)
        for segment in segmentResources {
            append(String(segment.index), to: &evidence)
            append(String(segment.mediaSequence), to: &evidence)
            append(
                "\(segment.duration.value)/\(segment.duration.timescale)",
                to: &evidence
            )
            append(segment.url.absoluteString, to: &evidence)
        }
        for rendition in audioRenditions {
            append(String(rendition.ordinal), to: &evidence)
            append(rendition.groupID, to: &evidence)
            append(rendition.name, to: &evidence)
            append(rendition.language ?? "<no-language>", to: &evidence)
            append(rendition.isDefault ? "default" : "not-default", to: &evidence)
            append(
                rendition.isAutoselect
                    ? "autoselect"
                    : "not-autoselect",
                to: &evidence
            )
            append(rendition.channels ?? "<no-channels>", to: &evidence)
            append(rendition.playlistURL.absoluteString, to: &evidence)
            append(
                rendition.initSegmentURL?.absoluteString
                    ?? "<no-audio-init-segment>",
                to: &evidence
            )
            evidence.append(rendition.playlistData)
            evidence.append(0)
            for segment in rendition.segments {
                append(String(segment.index), to: &evidence)
                append(String(segment.mediaSequence), to: &evidence)
                append(
                    "\(segment.duration.value)/\(segment.duration.timescale)",
                    to: &evidence
                )
                append(segment.url.absoluteString, to: &evidence)
            }
        }
        for (field, value) in httpHeaders.sorted(by: {
            let left = $0.key.lowercased()
            let right = $1.key.lowercased()
            return left == right ? $0.key < $1.key : left < right
        }) {
            append(field.lowercased(), to: &evidence)
            append(value, to: &evidence)
        }
        return HLSVODResourceDigest.sha256(evidence)
    }

    private static func append(_ value: String, to data: inout Data) {
        data.append(contentsOf: value.utf8)
        data.append(0)
    }

    private static func resolvedInitSegmentURL(
        media: HLSMediaPlaylist,
        playlistURL: URL
    ) throws -> URL? {
        guard let mapURI = media.mapURI else {
            return nil
        }
        guard let resolved = HLSPlaylistParser.resolve(
            uri: mapURI,
            against: playlistURL
        ) else {
            throw HLSPreflightError.unresolvableURI(mapURI)
        }
        return resolved
    }

    private static func validatedSegments(
        media: HLSMediaPlaylist,
        playlistURL: URL,
        label: String
    ) throws -> [HLSVODSegmentResource] {
        guard media.hasEndList else {
            throw HLSPreflightError.seekableVODPlaylistNotFinite
        }
        guard !media.hasByteRange else {
            throw HLSPreflightError.unsupportedSeekableVODResourceGraph(
                reason: "\(label) uses byte ranges"
            )
        }
        guard media.segments.allSatisfy({
            $0.duration > 0
                && $0.duration.isFinite
                && !$0.discontinuityBefore
        }) else {
            throw HLSPreflightError.unsupportedSeekableVODResourceGraph(
                reason: "\(label) has invalid duration or discontinuity"
            )
        }
        return try media.segments.enumerated().map {
            index,
            segment -> HLSVODSegmentResource in
            guard let url = HLSPlaylistParser.resolve(
                uri: segment.uri,
                against: playlistURL
            ) else {
                throw HLSPreflightError.unresolvableURI(segment.uri)
            }
            let (mediaSequence, overflow) =
                media.mediaSequence.addingReportingOverflow(index)
            guard !overflow else {
                throw HLSPreflightError.invalidPlaylist(
                    "MEDIA-SEQUENCE overflow"
                )
            }
            return HLSVODSegmentResource(
                index: index,
                mediaSequence: mediaSequence,
                duration: CMTime(
                    seconds: segment.duration,
                    preferredTimescale:
                        BlackCarrierProfile.approved.timescale
                ),
                url: url
            )
        }
    }

    private static func summedDuration(
        _ segments: [HLSVODSegmentResource]
    ) throws -> CMTimeValue {
        guard !segments.isEmpty else {
            throw HLSPreflightError
                .unsupportedSeekableVODResourceGraph(
                    reason:
                        "alternate-audio rendition has no segments"
                )
        }
        var total: CMTimeValue = 0
        for segment in segments {
            let addition = total.addingReportingOverflow(
                segment.duration.value
            )
            guard !addition.overflow else {
                throw HLSPreflightError.invalidPlaylist(
                    "alternate-audio duration overflow"
                )
            }
            total = addition.partialValue
        }
        return total
    }
}
