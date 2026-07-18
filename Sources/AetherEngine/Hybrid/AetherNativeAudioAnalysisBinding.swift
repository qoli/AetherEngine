import Foundation

/// Immutable binding between AVKit's native audio-option ordering and the
/// concrete source tracks consumed by Aether's independent decoder.
///
/// This remains session-internal: hosts receive only stable public track IDs,
/// availability and `AudioAnalysisStream`. A missing or contradictory binding
/// disables analysis for that track without changing the playback route.
struct AetherNativeAudioAnalysisBinding: Sendable {
    struct Track: Sendable, Equatable {
        let publicTrackID: Int
        let sourceTrack: TrackInfo?
        let availability: AudioAnalysisTrackAvailability
    }

    let sourceURL: URL
    let httpHeaders: [String: String]
    let durationSeconds: Double?
    let tracks: [Track]
    let optionTrackIDs: [Int]
    let allTracksUnavailable: AudioAnalysisError?

    static func unavailable(
        sourceURL: URL,
        httpHeaders: [String: String],
        error: AudioAnalysisError
    ) -> Self {
        Self(
            sourceURL: sourceURL,
            httpHeaders: httpHeaders,
            durationSeconds: nil,
            tracks: [],
            optionTrackIDs: [],
            allTracksUnavailable: error
        )
    }

    static func progressive(
        sourceURL: URL,
        httpHeaders: [String: String],
        probe: SourceProbe
    ) -> Self {
        guard probe.durationSeconds.isFinite,
              probe.durationSeconds > 0,
              !probe.isLive else {
            return unavailable(
                sourceURL: sourceURL,
                httpHeaders: httpHeaders,
                error: .sourceNotSeekable
            )
        }
        let tracks = probe.audioTracks.map {
            Track(
                publicTrackID: $0.id,
                sourceTrack: $0,
                availability: .available
            )
        }
        return Self(
            sourceURL: sourceURL,
            httpHeaders: httpHeaders,
            durationSeconds: probe.durationSeconds,
            tracks: tracks,
            optionTrackIDs: tracks.map(\.publicTrackID),
            allTracksUnavailable: nil
        )
    }

    static func hls(
        sourceURL: URL,
        httpHeaders: [String: String],
        preflight: AetherHLSPlaybackPreflight,
        probe: SourceProbe?
    ) -> Self {
        switch preflight.audioAnalysisPolicy {
        case .unavailableForAllTracks(let error):
            return unavailable(
                sourceURL: sourceURL,
                httpHeaders: httpHeaders,
                error: error
            )

        case .sessionScopedTrackAvailability:
            guard let probe else {
                return unavailable(
                    sourceURL: sourceURL,
                    httpHeaders: httpHeaders,
                    error: .analysisFailed(
                        "native HLS analysis source probe unavailable"
                    )
                )
            }
            return progressive(
                sourceURL: sourceURL,
                httpHeaders: httpHeaders,
                probe: probe
            )

        case .selectedAlternateAudioRenditions(let policies):
            let publicIDs = policies.map(\.audioTrackID)
            guard Set(publicIDs).count == publicIDs.count else {
                return unavailable(
                    sourceURL: sourceURL,
                    httpHeaders: httpHeaders,
                    error: .analysisFailed(
                        "native HLS analysis track IDs are duplicated"
                    )
                )
            }
            let sourceTracks = probe?.audioTracks ?? []
            let hasExactCount = sourceTracks.count == policies.count
            let duration = probe.flatMap {
                $0.durationSeconds.isFinite
                    && $0.durationSeconds > 0
                    && !$0.isLive
                    ? $0.durationSeconds
                    : nil
            }
            let tracks = policies.enumerated().map {
                index,
                policy -> Track in
                switch policy.availability {
                case .unavailable(let error):
                    return Track(
                        publicTrackID: policy.audioTrackID,
                        sourceTrack: nil,
                        availability: .unavailable(error)
                    )
                case .requiresPlaybackSessionBinding:
                    guard hasExactCount,
                          duration != nil,
                          Self.matches(
                            policy: policy,
                            sourceTrack: sourceTracks[index]
                          ) else {
                        return Track(
                            publicTrackID: policy.audioTrackID,
                            sourceTrack: nil,
                            availability: .unavailable(
                                .sourceTrackContractChanged(
                                    audioTrackID:
                                        policy.audioTrackID
                                )
                            )
                        )
                    }
                    return Track(
                        publicTrackID: policy.audioTrackID,
                        sourceTrack: sourceTracks[index],
                        availability: .available
                    )
                }
            }
            return Self(
                sourceURL: sourceURL,
                httpHeaders: httpHeaders,
                durationSeconds: duration,
                tracks: tracks,
                optionTrackIDs: publicIDs,
                allTracksUnavailable: nil
            )
        }
    }

    static func hlsRequiresSourceProbe(
        _ preflight: AetherHLSPlaybackPreflight
    ) -> Bool {
        switch preflight.audioAnalysisPolicy {
        case .sessionScopedTrackAvailability:
            true
        case .selectedAlternateAudioRenditions(let policies):
            policies.contains {
                if case .requiresPlaybackSessionBinding =
                    $0.availability {
                    return true
                }
                return false
            }
        case .unavailableForAllTracks:
            false
        }
    }

    var publicTrackIDs: [Int] {
        tracks.map(\.publicTrackID)
    }

    func availability(
        for publicTrackID: Int
    ) -> AudioAnalysisTrackAvailability {
        if let allTracksUnavailable {
            return .unavailable(allTracksUnavailable)
        }
        guard let track = tracks.first(
            where: { $0.publicTrackID == publicTrackID }
        ) else {
            return .unavailable(
                .audioTrackUnavailable(publicTrackID)
            )
        }
        return track.availability
    }

    func input(for publicTrackID: Int) throws -> AudioAnalysisInput {
        switch availability(for: publicTrackID) {
        case .available:
            break
        case .unavailable(let error):
            throw error
        }
        guard let sourceTrack = tracks.first(
            where: { $0.publicTrackID == publicTrackID }
        )?.sourceTrack else {
            throw AudioAnalysisError.sourceTrackContractChanged(
                audioTrackID: publicTrackID
            )
        }
        return .boundURL(
            sourceURL,
            httpHeaders: httpHeaders,
            sourceByteStore: nil,
            sourceTrack: sourceTrack
        )
    }

    private static func matches(
        policy: AetherHLSAudioRenditionAnalysisPolicy,
        sourceTrack: TrackInfo
    ) -> Bool {
        guard let policyLanguage = normalizedLanguage(
            policy.language
        ) else {
            return true
        }
        return normalizedLanguage(sourceTrack.language)
            == policyLanguage
    }

    private static func normalizedLanguage(
        _ language: String?
    ) -> String? {
        guard let language else { return nil }
        let normalized = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        guard !normalized.isEmpty else { return nil }
        return normalized.split(separator: "-").first.map(String.init)
    }
}
