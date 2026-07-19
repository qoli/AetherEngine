import Foundation

public enum AetherPlaybackSessionFactoryError:
    Error,
    Sendable,
    Equatable,
    LocalizedError
{
    case invalidURLSourceKind

    public var errorDescription: String? {
        "URL playback requires a file, HTTP or HTTPS canonical source"
    }
}

/// Single Aether-owned launch boundary for URL-backed, finite, seekable VOD.
///
/// The factory returns a stable session before source inspection. Classification,
/// preflight, route construction and bounded recovery run inside `prepare()` so
/// the host never owns a route decision or replacement player.
@MainActor
public enum AetherPlaybackSessionFactory {
    public static func makeSeekableURLVOD(
        url: URL,
        options: LoadOptions = .init(),
        variantSelection: HLSPreflightVariantSelection = .highestBandwidth
    ) throws -> AetherPlaybackSession {
        if url.isFileURL {
            return AetherPlaybackSession(
                url: url,
                options: options,
                variantSelection: variantSelection
            )
        }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw AetherPlaybackSessionFactoryError
                .invalidURLSourceKind
        }
        return AetherPlaybackSession(
            url: url,
            options: options,
            variantSelection: variantSelection
        )
    }

    static func makeNativeHLSAudioAnalysisBinding(
        url: URL,
        options: LoadOptions,
        preflight: AetherHLSPlaybackPreflight
    ) async throws -> AetherNativeAudioAnalysisBinding {
        guard AetherNativeAudioAnalysisBinding
                .hlsRequiresSourceProbe(preflight) else {
            return .hls(
                sourceURL: url,
                httpHeaders: options.httpHeaders,
                preflight: preflight,
                probe: nil
            )
        }

        var probe: SourceProbe?
        do {
            try Task.checkCancellation()
            probe = try await Task.detached(
                priority: .userInitiated
            ) {
                try AetherEngine.probe(
                    url: url,
                    options: options
                )
            }.value
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Independent audio analysis is optional and visibly unavailable.
            // This never changes the admitted playback route or source.
            probe = nil
        }
        return .hls(
            sourceURL: url,
            httpHeaders: options.httpHeaders,
            preflight: preflight,
            probe: probe
        )
    }
}
