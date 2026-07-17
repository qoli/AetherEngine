import CoreMedia
import Foundation

public enum AetherPlaybackSessionFactoryError:
    Error,
    Sendable,
    Equatable,
    LocalizedError
{
    case invalidURLSourceKind

    public var errorDescription: String? {
        "URL playback classification produced an invalid source kind"
    }
}

/// Typed session result consumed by hosts after Aether has completed source classification and route
/// preflight. `.unsupported` is terminal and must not be interpreted as permission to try another player.
@MainActor
public enum AetherPlaybackSessionLaunchResult {
    case native(AetherNativePlaybackSession)
    case hybrid(AetherHybridPlaybackSession)
    case unsupported(PlaybackPreflightResult)

    public var preflightResult: PlaybackPreflightResult {
        switch self {
        case .native(let session):
            session.preflightResult
        case .hybrid(let session):
            session.preflightResult
        case .unsupported(let result):
            result
        }
    }
}

/// Single Aether-owned launch boundary for URL-backed, finite, seekable VOD.
///
/// Source bytes establish HLS versus progressive before any route policy runs. The selected route then
/// creates exactly one Aether-owned session. Classification, probe, HLS inspection and session creation do
/// not catch one another's errors to retry a different source kind, player or renderer.
@MainActor
public enum AetherPlaybackSessionFactory {
    public static func makeSeekableURLVOD(
        url: URL,
        options: LoadOptions = .init(),
        variantSelection: HLSPreflightVariantSelection = .highestBandwidth,
        preflightOperation: AetherPlaybackPreflightOperation
    ) async throws -> AetherPlaybackSessionLaunchResult {
        let sourceKind = try await AetherURLPlaybackSourceClassifier
            .classify(url: url, options: options)

        switch sourceKind {
        case .hls:
            let preflight = try await preflightOperation.inspectHLS(
                url: url,
                sourceIsSeekableVOD: true,
                variantSelection: variantSelection,
                hybridCapabilities:
                    AetherHybridPlaybackSession.capabilities,
                options: options
            )
            switch preflight.result.route {
            case .nativeAVPlayer:
                return .native(
                    try AetherNativePlaybackSession.make(
                        url: url,
                        options: options,
                        preflightResult: preflight.result
                    )
                )
            case .hybridCarrier:
                return .hybrid(
                    try await AetherHybridPlaybackSession
                        .makeHLSVOD(preflight: preflight)
                )
            case .unsupported:
                return .unsupported(preflight.result)
            }

        case .progressive:
            let probe = try await Task.detached(
                priority: .userInitiated
            ) {
                try AetherEngine.probe(
                    url: url,
                    options: options
                )
            }.value
            let isSeekableVOD =
                probe.durationSeconds.isFinite
                && probe.durationSeconds > 0
                && !probe.isLive
            let sourceProfile = AetherSourceProfile(
                probe: probe,
                sourceKind: .progressive,
                isSeekableVOD: isSeekableVOD
            )
            let result = try await preflightOperation.resolve(
                sourceProfile: sourceProfile,
                hlsPackaging: nil,
                hybridCapabilities:
                    AetherHybridPlaybackSession.capabilities
            )
            switch result.route {
            case .nativeAVPlayer:
                return .native(
                    try AetherNativePlaybackSession.make(
                        url: url,
                        options: options,
                        preflightResult: result
                    )
                )
            case .hybridCarrier:
                guard isSeekableVOD else {
                    return .unsupported(result)
                }
                let timeline = try BlackCarrierTimeline.fileVOD(
                    duration: CMTime(
                        seconds: probe.durationSeconds,
                        preferredTimescale: 90_000
                    )
                )
                return .hybrid(
                    try await AetherHybridPlaybackSession
                        .makeSeekableVOD(
                            source: .url(url),
                            options: options,
                            timeline: timeline,
                            preflightResult: result
                        )
                )
            case .unsupported:
                return .unsupported(result)
            }

        case .custom:
            throw AetherPlaybackSessionFactoryError.invalidURLSourceKind
        }
    }
}
