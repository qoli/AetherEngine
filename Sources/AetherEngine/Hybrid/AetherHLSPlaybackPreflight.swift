import CoreMedia
import CryptoKit
import Foundation

/// Public, privacy-safe result of HLS inspection.
///
/// The raw selected playlist, init-segment and media-segment URLs remain engine-private because they may
/// contain signed query parameters. For an admitted `.hybridCarrierMetal` route, `resourceIdentity` is a
/// SHA-256 binding over those resolved video resources, the exact media-playlist bytes and the request
/// headers. A separate alternate-audio group is reported but is not yet part of this first binding. Native
/// and unsupported routes do not create the hybrid graph. A host may persist the digest, but must pass this
/// value object back to AetherEngine rather than reconstructing an HLS resource graph from public fields.
public struct AetherHLSPlaybackPreflight: Sendable, Equatable {
    public let result: PlaybackPreflightResult
    public let hybridTimeline: BlackCarrierTimeline?
    public let resourceIdentity: String?
    public let selectedVariantBandwidth: Int?
    public let mediaSegmentCount: Int
    public let hasSeparateAudioRenditions: Bool

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
        hasSeparateAudioRenditions =
            resourceGraph?.separateAudioGroupID != nil
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

/// Engine-private immutable snapshot of the exact clear, finite HLS VOD video resources inspected before
/// route selection. Future hybrid demux generations must consume these resolved URLs; reopening the root
/// master and choosing a different adaptive variant would violate the preflight contract. Alternate-audio
/// playlists remain a separate pending graph and therefore still block public HLS session admission.
struct HLSVODResourceGraph: Sendable, Equatable {
    let requestedRootURL: URL
    let effectiveRootURL: URL
    let selectedMediaPlaylistURL: URL
    let selectedVariantURI: String?
    let selectedVariantBandwidth: Int?
    let separateAudioGroupID: String?
    let initSegmentURL: URL?
    let segments: [HLSVODSegmentResource]
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
        httpHeaders: [String: String]
    ) throws -> HLSVODResourceGraph {
        guard media.hasEndList else {
            throw HLSPreflightError.seekableVODPlaylistNotFinite
        }
        guard !media.hasByteRange else {
            throw HLSPreflightError.unsupportedSeekableVODResourceGraph(
                reason: "byte-range media or init resources"
            )
        }
        guard media.segments.allSatisfy({
            $0.duration > 0
                && $0.duration.isFinite
                && !$0.discontinuityBefore
        }) else {
            throw HLSPreflightError.unsupportedSeekableVODResourceGraph(
                reason: "invalid duration or discontinuity"
            )
        }

        let initSegmentURL: URL?
        if let mapURI = media.mapURI {
            guard let resolved = HLSPlaylistParser.resolve(
                uri: mapURI,
                against: selectedMediaPlaylistURL
            ) else {
                throw HLSPreflightError.unresolvableURI(mapURI)
            }
            initSegmentURL = resolved
        } else {
            initSegmentURL = nil
        }

        let segmentResources = try media.segments.enumerated().map {
            index,
            segment -> HLSVODSegmentResource in
            guard let url = HLSPlaylistParser.resolve(
                uri: segment.uri,
                against: selectedMediaPlaylistURL
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
        let timeline = try BlackCarrierTimeline.mirroredHLSVOD(
            segmentDurations: segmentResources.map(\.duration)
        )
        let identity = makeIdentity(
            requestedRootURL: requestedRootURL,
            effectiveRootURL: effectiveRootURL,
            selectedMediaPlaylistURL: selectedMediaPlaylistURL,
            selectedVariant: selectedVariant,
            separateAudioGroupID: separateAudioGroupID,
            mediaPlaylistData: mediaPlaylistData,
            initSegmentURL: initSegmentURL,
            segmentResources: segmentResources,
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
            timeline: timeline,
            identity: identity
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
        for (field, value) in httpHeaders.sorted(by: {
            let left = $0.key.lowercased()
            let right = $1.key.lowercased()
            return left == right ? $0.key < $1.key : left < right
        }) {
            append(field.lowercased(), to: &evidence)
            append(value, to: &evidence)
        }
        return SHA256.hash(data: evidence)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func append(_ value: String, to data: inout Data) {
        data.append(contentsOf: value.utf8)
        data.append(0)
    }
}
