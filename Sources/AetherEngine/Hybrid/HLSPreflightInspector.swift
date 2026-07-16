import Foundation

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

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let status): "HLS preflight HTTP status \(status)"
        case .invalidPlaylist(let reason): "Invalid HLS playlist: \(reason)"
        case .unresolvableURI(let uri): "Unresolvable HLS URI: \(uri)"
        case .requestedVariantNotFound(let uri): "Requested HLS variant not found: \(uri)"
        case .selectedVariantWasNotMediaPlaylist: "Selected HLS variant was not a media playlist"
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
        let inspector = HLSPreflightInspector(httpHeaders: options.httpHeaders)
        return try await inspector.inspect(
            rootURL: url,
            sourceIsSeekableVOD: sourceIsSeekableVOD,
            variantSelection: variantSelection,
            hybridCapabilities: hybridCapabilities
        )
    }
}

private struct HLSPreflightFetchResponse: Sendable {
    let data: Data
    let effectiveURL: URL
}

private struct HLSPreflightResolvedMedia: Sendable {
    let variant: HLSVariant?
    let mediaURL: URL
    let media: HLSMediaPlaylist
}

private struct HLSInspectedVideo: Sendable {
    let codec: AetherVideoCodec
    let format: VideoFormat
    let sampleEntry: HLSVideoSampleEntry
}

/// Stateful only through its immutable HTTP header set. Tests exercise parsing and verification helpers
/// directly; runtime I/O is isolated here so it cannot fall back to the AudioTap retry path.
struct HLSPreflightInspector {
    private let httpHeaders: [String: String]

    init(httpHeaders: [String: String]) {
        self.httpHeaders = httpHeaders
    }

    func inspect(
        rootURL: URL,
        sourceIsSeekableVOD: Bool,
        variantSelection: HLSPreflightVariantSelection,
        hybridCapabilities: HybridPlaybackCapabilities
    ) async throws -> PlaybackPreflightResult {
        let resolved = try await resolveMedia(
            rootURL: rootURL,
            selection: variantSelection
        )
        let manifestCodecs = (resolved.variant?.codecs ?? [])
            + (resolved.variant?.supplementalCodecs ?? [])

        // Protected media has no clear-packet hybrid contract. Return a normal typed route result rather
        // than fetching keys, asking AVPlayer to try it, or silently changing to a legacy path.
        guard resolved.media.contentProtection == .none else {
            return unresolvedResult(
                isSeekableVOD: sourceIsSeekableVOD,
                manifestCodecs: manifestCodecs,
                contentProtection: resolved.media.contentProtection,
                hybridCapabilities: hybridCapabilities
            )
        }

        guard let firstSegment = resolved.media.segments.first,
              let segmentURL = HLSPlaylistParser.resolve(uri: firstSegment.uri, against: resolved.mediaURL) else {
            throw HLSPreflightError.unresolvableURI(resolved.media.segments.first?.uri ?? "<missing first segment>")
        }
        let segment = try await fetch(segmentURL)

        let container: HLSVideoContainer
        let initSegment: Data?
        if let mapURI = resolved.media.mapURI {
            guard let initURL = HLSPlaylistParser.resolve(uri: mapURI, against: resolved.mediaURL) else {
                throw HLSPreflightError.unresolvableURI(mapURI)
            }
            container = .fragmentedMP4
            initSegment = try await fetch(initURL).data
        } else if Self.isMPEGTransport(segment.data) {
            container = .mpegTransport
            initSegment = nil
        } else {
            return unresolvedResult(
                isSeekableVOD: sourceIsSeekableVOD,
                manifestCodecs: manifestCodecs,
                contentProtection: .none,
                hybridCapabilities: hybridCapabilities
            )
        }

        guard let inspected = Self.inspectVideo(
            initSegment: initSegment,
            segment: segment.data,
            container: container
        ) else {
            return unresolvedResult(
                isSeekableVOD: sourceIsSeekableVOD,
                manifestCodecs: manifestCodecs,
                contentProtection: .none,
                hybridCapabilities: hybridCapabilities,
                container: container
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
        let source = AetherSourceProfile(
            sourceKind: .hls,
            isSeekableVOD: sourceIsSeekableVOD,
            videoCodec: inspected.codec,
            videoFormat: inspected.format
        )
        return PlaybackPreflight.resolve(
            sourceProfile: source,
            hlsPackaging: packaging,
            hybridCapabilities: hybridCapabilities
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
            return HLSPreflightResolvedMedia(variant: nil, mediaURL: root.effectiveURL, media: media)

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
            return HLSPreflightResolvedMedia(variant: variant, mediaURL: response.effectiveURL, media: media)
        }
    }

    private func fetch(_ url: URL) async throws -> HLSPreflightFetchResponse {
        var request = URLRequest(url: url)
        for (field, value) in httpHeaders { request.setValue(value, forHTTPHeaderField: field) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        let (data, response) = try await URLSession(configuration: config).data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HLSPreflightError.invalidPlaylist("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HLSPreflightError.httpStatus(http.statusCode)
        }
        return HLSPreflightFetchResponse(data: data, effectiveURL: response.url ?? url)
    }

    private func parsePlaylist(_ data: Data) throws -> HLSPlaylist {
        guard let text = String(data: data, encoding: .utf8) else {
            throw HLSPreflightError.invalidPlaylist("non-UTF8")
        }
        do {
            return try HLSPlaylistParser.parse(text)
        } catch {
            throw HLSPreflightError.invalidPlaylist(error.localizedDescription)
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
            return HLSInspectedVideo(codec: codec, format: probe.videoFormat, sampleEntry: sampleEntry)
        } catch {
            return nil
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

    private static func isMPEGTransport(_ data: Data) -> Bool {
        // Three 188-byte sync markers reject arbitrary data that happens to begin with 0x47.
        data.count >= 376
            && data[0] == 0x47
            && data[188] == 0x47
            && (data.count < 564 || data[376] == 0x47)
    }
}
