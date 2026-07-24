import AVFoundation
import Combine
import CoreMedia
import Foundation

#if os(tvOS)
import AVKit
#endif

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public enum AetherPlaybackSessionState:
    Sendable,
    Equatable
{
    case idle
    case preparing
    case ready
    case playing
    case paused
    case seeking
    case recovering(AetherPlaybackRecoveryEvent)
    case ended
    case failed(AetherPlaybackFailure)
    case stopped
}

public enum AetherPlaybackSessionError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case invalidFactorySource
    case invalidState
    case noActiveRoute
    case recoveryDeadlineExceeded(seconds: TimeInterval)
    case unsupported(PlaybackRouteReason)
    case terminal(AetherPlaybackFailure)

    public var errorDescription: String? {
        switch self {
        case .invalidFactorySource:
            "Aether playback session requires a finite URL-backed VOD request"
        case .invalidState:
            "Aether playback session is not available in its current state"
        case .noActiveRoute:
            "Aether playback session has no active render route"
        case .recoveryDeadlineExceeded(let seconds):
            "Aether playback recovery exceeded its \(seconds)-second episode deadline"
        case .unsupported(let reason):
            "The media contract is unsupported: \(reason.rawValue)"
        case .terminal(let failure):
            failure.localizedDescription
        }
    }
}

public enum AetherPlaybackSeekResult: Sendable, Equatable {
    case applied
    case superseded
}

/// Privacy-safe phase of the latest outer-session transport intent.
public enum AetherPlaybackTransportApplicationPhase:
    String,
    Sendable,
    Equatable
{
    case idle
    case preparing
    case ready
    case applying
    case waiting
    case playing
    case parkedPaused
    case paused
    case recovering
    case ended
    case failed
    case stopped
}

public enum AetherPlaybackTimeControlStatus:
    String,
    Sendable,
    Equatable
{
    case paused
    case waitingToPlay
    case playing
    case unknown
}

public enum AetherPlaybackWaitingReason:
    String,
    Sendable,
    Equatable
{
    case none
    case evaluatingBufferingRate
    case noItemToPlay
    case minimizingStalls
    case other
}

public enum AetherPlaybackItemStatus:
    String,
    Sendable,
    Equatable
{
    case absent
    case unknown
    case readyToPlay
    case failed
}

/// Read-only transport evidence for host diagnostics and acceptance runners.
/// It deliberately excludes source URLs, request fields and media payloads.
public struct AetherPlaybackTransportSnapshot:
    Sendable,
    Equatable
{
    public let commandSequence: UInt64
    public let routeGeneration: UInt64
    public let desiredPlaying: Bool
    public let desiredRate: Float
    public let route: PlaybackRenderRoute?
    public let applicationPhase: AetherPlaybackTransportApplicationPhase
    public let actualRate: Float
    public let timeControlStatus: AetherPlaybackTimeControlStatus
    public let waitingReason: AetherPlaybackWaitingReason
    public let itemStatus: AetherPlaybackItemStatus
    public let mediaTimeSeconds: Double?
    public let loadedTimeRangeCount: Int
    public let recoverySequence: UInt64
    public let reassertCount: Int
    public let lastReassertedCommandSequence: UInt64?

    public init(
        commandSequence: UInt64,
        routeGeneration: UInt64,
        desiredPlaying: Bool,
        desiredRate: Float,
        route: PlaybackRenderRoute?,
        applicationPhase: AetherPlaybackTransportApplicationPhase,
        actualRate: Float,
        timeControlStatus: AetherPlaybackTimeControlStatus,
        waitingReason: AetherPlaybackWaitingReason,
        itemStatus: AetherPlaybackItemStatus,
        mediaTimeSeconds: Double?,
        loadedTimeRangeCount: Int,
        recoverySequence: UInt64,
        reassertCount: Int,
        lastReassertedCommandSequence: UInt64?
    ) {
        precondition(desiredRate.isFinite && desiredRate >= 0)
        precondition(actualRate.isFinite && actualRate >= 0)
        if let mediaTimeSeconds {
            precondition(
                mediaTimeSeconds.isFinite && mediaTimeSeconds >= 0
            )
        }
        precondition(loadedTimeRangeCount >= 0)
        precondition(reassertCount >= 0)
        self.commandSequence = commandSequence
        self.routeGeneration = routeGeneration
        self.desiredPlaying = desiredPlaying
        self.desiredRate = desiredRate
        self.route = route
        self.applicationPhase = applicationPhase
        self.actualRate = actualRate
        self.timeControlStatus = timeControlStatus
        self.waitingReason = waitingReason
        self.itemStatus = itemStatus
        self.mediaTimeSeconds = mediaTimeSeconds
        self.loadedTimeRangeCount = loadedTimeRangeCount
        self.recoverySequence = recoverySequence
        self.reassertCount = reassertCount
        self.lastReassertedCommandSequence =
            lastReassertedCommandSequence
    }
}

enum AetherPlaybackTransportOperation: Sendable, Equatable {
    case play
    case pause
    case setRate(Float)
}

enum AetherPlaybackStartupFailureCase: String, Sendable, Equatable {
    case transportIntentNotApplied
    case startupNoProgress
}

/// Pure policy used by the async transport tasks. Keeping timing and command
/// validity out of the Task bodies makes stale-intent and no-progress behavior
/// deterministic under unit test.
enum AetherPlaybackTransportDecision {
    static func operations(
        desiredPlaying: Bool,
        desiredRate: Float
    ) -> [AetherPlaybackTransportOperation] {
        guard desiredPlaying, desiredRate.isFinite, desiredRate > 0 else {
            return [.pause]
        }
        if desiredRate == 1 { return [.play] }
        return [.play, .setRate(desiredRate)]
    }

    static func shouldReassert(
        requestedSequence: UInt64,
        currentSequence: UInt64,
        requestedGeneration: UInt64,
        currentGeneration: UInt64,
        desiredPlaying: Bool,
        desiredRate: Float,
        itemIsReady: Bool,
        actualRate: Float,
        timeControlStatus: AetherPlaybackTimeControlStatus,
        routeApplicationIsTemporarilyUnavailable: Bool = false,
        reassertCount: Int
    ) -> Bool {
        requestedSequence == currentSequence
            && requestedGeneration == currentGeneration
            && desiredPlaying
            && desiredRate.isFinite
            && desiredRate > 0
            && itemIsReady
            && actualRate == 0
            && timeControlStatus == .paused
            && !routeApplicationIsTemporarilyUnavailable
            && reassertCount == 0
    }

    static func startupFailure(
        requestedSequence: UInt64,
        currentSequence: UInt64,
        requestedGeneration: UInt64,
        currentGeneration: UInt64,
        desiredPlaying: Bool,
        madeProgress: Bool,
        itemIsReady: Bool,
        actualRate: Float,
        timeControlStatus: AetherPlaybackTimeControlStatus
    ) -> AetherPlaybackStartupFailureCase? {
        guard requestedSequence == currentSequence,
              requestedGeneration == currentGeneration,
              desiredPlaying,
              !madeProgress else { return nil }
        if itemIsReady,
           actualRate == 0,
           timeControlStatus == .paused {
            return .transportIntentNotApplied
        }
        return .startupNoProgress
    }

    static func startupObservationDelay(
        configuredSeconds: TimeInterval,
        recoveryRemainingSeconds: TimeInterval?,
        publicationHeadroomSeconds: TimeInterval
    ) -> TimeInterval {
        guard let recoveryRemainingSeconds else {
            return configuredSeconds
        }
        return min(
            configuredSeconds,
            max(
                0,
                recoveryRemainingSeconds
                    - publicationHeadroomSeconds
            )
        )
    }

    static func reconciledState(
        requestedSequence: UInt64,
        currentSequence: UInt64,
        requestedGeneration: UInt64,
        currentGeneration: UInt64,
        desiredPlaying: Bool,
        timeControlStatus: AetherPlaybackTimeControlStatus
    ) -> AetherPlaybackSessionState? {
        guard requestedSequence == currentSequence,
              requestedGeneration == currentGeneration,
              desiredPlaying else { return nil }
        return switch timeControlStatus {
        case .waitingToPlay, .playing: .playing
        case .paused, .unknown: nil
        }
    }
}

public enum AetherPlaybackTrackKind: String, Sendable, Equatable {
    case audio
    case subtitle
}

public struct AetherPlaybackTrack:
    Identifiable,
    Sendable,
    Equatable
{
    public let id: String
    public let sourceTrackID: Int?
    public let kind: AetherPlaybackTrackKind
    public let name: String
    public let language: String?
    public let codec: String?
    public let isDefault: Bool
    public let isForced: Bool
    public let isAtmos: Bool
    public let isExternal: Bool

    public init(
        id: String,
        sourceTrackID: Int?,
        kind: AetherPlaybackTrackKind,
        name: String,
        language: String?,
        codec: String?,
        isDefault: Bool,
        isForced: Bool = false,
        isAtmos: Bool = false,
        isExternal: Bool = false
    ) {
        self.id = id
        self.sourceTrackID = sourceTrackID
        self.kind = kind
        self.name = name
        self.language = language
        self.codec = codec
        self.isDefault = isDefault
        self.isForced = isForced
        self.isAtmos = isAtmos
        self.isExternal = isExternal
    }
}

public enum AetherPlaybackTrackSelectionError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case unknownTrack(String)
    case selectionUnavailable(String)
    case selectedTrackCouldNotBeRestored(String)

    public var errorDescription: String? {
        switch self {
        case .unknownTrack(let id):
            return "Playback track \(id) is unknown"
        case .selectionUnavailable(let id):
            return "Playback track \(id) cannot be selected on the active route"
        case .selectedTrackCouldNotBeRestored(let id):
            return "Selected playback track \(id) could not be restored"
        }
    }
}

public struct AetherPlaybackCapabilities:
    Sendable,
    Equatable
{
    public let route: PlaybackRenderRoute?
    public let systemFeaturePolicy:
        HybridPlaybackSystemFeaturePolicy
    public let audioAnalysisTrackIDs: [Int]
    public let selectedAudioAnalysisTrackID: Int?
    public let videoFormat: VideoFormat?
    public let dolbyVisionProfile: Int?
    public let variantBitrate: Int?
    public let audioTracks: [AetherPlaybackTrack]
    public let subtitleTracks: [AetherPlaybackTrack]
    public let selectedAudioTrackID: String?
    public let selectedSubtitleTrackID: String?
    public let atmosAvailable: Bool
    public let audioAnalysisAvailable: Bool

    public init(
        route: PlaybackRenderRoute?,
        systemFeaturePolicy:
            HybridPlaybackSystemFeaturePolicy,
        audioAnalysisTrackIDs: [Int],
        selectedAudioAnalysisTrackID: Int?,
        videoFormat: VideoFormat?,
        dolbyVisionProfile: Int?,
        variantBitrate: Int?,
        audioTracks: [AetherPlaybackTrack],
        subtitleTracks: [AetherPlaybackTrack],
        selectedAudioTrackID: String?,
        selectedSubtitleTrackID: String?
    ) {
        self.route = route
        self.systemFeaturePolicy = systemFeaturePolicy
        self.audioAnalysisTrackIDs = audioAnalysisTrackIDs
        self.selectedAudioAnalysisTrackID =
            selectedAudioAnalysisTrackID
        self.videoFormat = videoFormat
        self.dolbyVisionProfile = dolbyVisionProfile
        self.variantBitrate = variantBitrate
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.selectedAudioTrackID = selectedAudioTrackID
        self.selectedSubtitleTrackID = selectedSubtitleTrackID
        atmosAvailable = audioTracks.contains(where: \.isAtmos)
        audioAnalysisAvailable = !audioAnalysisTrackIDs.isEmpty
    }
}

/// Stable host-mounted container for the only Hybrid presentation backend.
/// Native playback leaves it empty; Hybrid installs exactly one
/// `AetherHybridPresentationView` backed by AVSampleBufferDisplayLayer.
@MainActor
public final class AetherPlaybackPresentationView:
    PlatformBaseView
{
    public private(set) weak var hybridPresentationView:
        AetherHybridPresentationView?

    #if canImport(UIKit)
    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    public convenience init() {
        self.init(frame: .zero)
    }

    public required init?(coder: NSCoder) { nil }
    #elseif canImport(AppKit)
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    public convenience init() {
        self.init(frame: .zero)
    }

    public required init?(coder: NSCoder) { nil }
    #endif

    func install(
        _ view: AetherHybridPresentationView?
    ) {
        if hybridPresentationView === view { return }
        hybridPresentationView?.removeFromSuperview()
        hybridPresentationView = view
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

/// Narrow route boundary used by the outer session's transport coordinator.
/// Production dispatch remains backed by `AetherActiveRouteSession`; package
/// tests can supply a controllable route without constructing media or a
/// second player implementation.
@MainActor
protocol AetherPlaybackTransportRoute {
    var transportIdentity: ObjectIdentifier { get }
    /// True only while the same admitted route is completing an operation
    /// that temporarily cannot accept another transport command. This is not
    /// a route failure and must not start outer recovery.
    var transportApplicationIsTemporarilyUnavailable: Bool { get }

    func play() throws
    func pause() throws
    func setRate(_ rate: Float) throws
    func seek(
        to target: CMTime,
        timeout: TimeInterval
    ) async throws -> AetherPlaybackSeekResult
}

extension AetherPlaybackTransportRoute {
    var transportApplicationIsTemporarilyUnavailable: Bool { false }
}

@MainActor
private enum AetherActiveRouteSession:
    AetherPlaybackTransportRoute
{
    case native(AetherNativePlaybackSession)
    case hybrid(AetherHybridPlaybackSession)

    var route: PlaybackRenderRoute {
        switch self {
        case .native: .nativeAVPlayer
        case .hybrid: .hybridCarrier
        }
    }

    var transportIdentity: ObjectIdentifier {
        switch self {
        case .native(let session): ObjectIdentifier(session)
        case .hybrid(let session): ObjectIdentifier(session)
        }
    }

    var transportApplicationIsTemporarilyUnavailable: Bool {
        guard case .hybrid(let session) = self else { return false }
        return switch session.state {
        case .preparing, .seeking: true
        case .idle, .ready, .ended, .failed, .stopped: false
        }
    }

    func isIdentical(to other: AetherActiveRouteSession) -> Bool {
        switch (self, other) {
        case (.native(let lhs), .native(let rhs)):
            lhs === rhs
        case (.hybrid(let lhs), .hybrid(let rhs)):
            lhs === rhs
        default:
            false
        }
    }

    var preflightResult: PlaybackPreflightResult {
        switch self {
        case .native(let session): session.preflightResult
        case .hybrid(let session): session.preflightResult
        }
    }

    var audioAnalysisTrackIDs: [Int] {
        switch self {
        case .native(let session): session.audioAnalysisTrackIDs
        case .hybrid(let session): session.audioAnalysisTrackIDs
        }
    }

    var selectedAudioAnalysisTrackID: Int? {
        switch self {
        case .native(let session):
            session.selectedAudioAnalysisTrackID
        case .hybrid(let session):
            session.selectedAudioAnalysisTrackID
        }
    }

    var audioTracks: [AetherPlaybackTrack] {
        switch self {
        case .native(let session):
            session.audioTracks.map { track in
                AetherPlaybackTrack(
                    id: "audio-source:\(track.id)",
                    sourceTrackID: track.id,
                    kind: .audio,
                    name: track.name,
                    language: track.language,
                    codec: track.codec,
                    isDefault: track.isDefault,
                    isAtmos: track.isAtmos
                )
            }
        case .hybrid(let session):
            session.audioTracks
        }
    }

    var subtitleTracks: [AetherPlaybackTrack] {
        switch self {
        case .native(let session):
            session.subtitleTracks.map { track in
                AetherPlaybackTrack(
                    id: "subtitle-source:\(track.id)",
                    sourceTrackID: track.id,
                    kind: .subtitle,
                    name: track.name,
                    language: track.language,
                    codec: track.codec,
                    isDefault: track.isDefault,
                    isForced: track.isForced,
                    isExternal: track.isExternal
                )
            }
        case .hybrid(let session):
            session.subtitleTracks.map { track in
                guard track.id.hasPrefix("subtitle-overlay:"),
                      let sourceTrackID = track.sourceTrackID else {
                    return track
                }
                return AetherPlaybackTrack(
                    id: "subtitle-source:\(sourceTrackID)",
                    sourceTrackID: sourceTrackID,
                    kind: track.kind,
                    name: track.name,
                    language: track.language,
                    codec: track.codec,
                    isDefault: track.isDefault,
                    isForced: track.isForced,
                    isAtmos: track.isAtmos,
                    isExternal: track.isExternal
                )
            }
        }
    }

    var selectedAudioTrackIdentifier: String? {
        switch self {
        case .native(let session):
            session.selectedAudioTrackID.map { "audio-source:\($0)" }
        case .hybrid(let session):
            session.selectedAudioTrackID.map { "audio-source:\($0)" }
        }
    }

    var selectedSubtitleTrackIdentifier: String? {
        switch self {
        case .native(let session):
            session.selectedSubtitleTrackID.map {
                "subtitle-source:\($0)"
            }
        case .hybrid(let session):
            if let overlayID = session.activeOverlaySubtitleTrackID {
                "subtitle-source:\(overlayID)"
            } else {
                session.selectedSubtitleTrackIdentifier
            }
        }
    }

    var audioAnalysisDurationSeconds: Double? {
        switch self {
        case .native(let session):
            session.audioAnalysisDurationSeconds
        case .hybrid(let session):
            session.diagnostics.timelineDurationSeconds
        }
    }

    var videoOutputSnapshot: AetherVideoOutputSnapshot {
        switch self {
        case .native(let session): session.videoOutputSnapshot
        case .hybrid(let session): session.videoOutputSnapshot
        }
    }

    var nativeFailureEvidence:
        AetherNativePlaybackFailureEvidence?
    {
        guard case .native(let session) = self else { return nil }
        return session.lastFailureEvidence
    }

    func pollVideoOutput() {
        switch self {
        case .native(let session): session.pollVideoOutput()
        case .hybrid(let session): session.pollVideoOutput()
        }
    }

    func prepare() async throws {
        switch self {
        case .native(let session): try await session.prepare()
        case .hybrid(let session): try await session.prepare()
        }
    }

    func setRoutePreparationProgressHandler(
        _ handler:
            (@Sendable (
                AetherRoutePreparationProgressKind
            ) -> Void)?
    ) {
        switch self {
        case .native:
            break
        case .hybrid(let session):
            session.setRoutePreparationProgressHandler(handler)
        }
    }

    func play() throws {
        switch self {
        case .native(let session): try session.play()
        case .hybrid(let session): try session.play()
        }
    }

    func pause() throws {
        switch self {
        case .native(let session): try session.pause()
        case .hybrid(let session): try session.pause()
        }
    }

    func setRate(_ rate: Float) throws {
        switch self {
        case .native(let session): try session.setRate(rate)
        case .hybrid(let session): try session.setRate(rate)
        }
    }

    func seek(
        to target: CMTime,
        timeout: TimeInterval
    ) async throws -> AetherPlaybackSeekResult {
        switch self {
        case .native(let session):
            return try await session.seek(
                to: target,
                timeout: timeout
            )
        case .hybrid(let session):
            return switch try await session.seek(
                to: target,
                timeout: timeout
            ) {
            case .applied: .applied
            case .superseded: .superseded
            }
        }
    }

    func audioAnalysisAvailability(
        for trackID: Int
    ) -> AudioAnalysisTrackAvailability {
        switch self {
        case .native(let session):
            session.audioAnalysisAvailability(for: trackID)
        case .hybrid(let session):
            session.audioAnalysisAvailability(for: trackID)
        }
    }

    func audioAnalysisStream(
        request: AudioAnalysisRequest
    ) throws -> AudioAnalysisStream {
        switch self {
        case .native(let session):
            try session.audioAnalysisStream(request: request)
        case .hybrid(let session):
            try session.audioAnalysisStream(request: request)
        }
    }

    func cancelAudioAnalysisStreams() {
        switch self {
        case .native(let session):
            session.cancelAudioAnalysisStreams()
        case .hybrid(let session):
            session.cancelAudioAnalysisStreams()
        }
    }

    func selectAudioTrack(_ id: String) async throws {
        guard let track = audioTracks.first(where: { $0.id == id }),
              let sourceTrackID = track.sourceTrackID else {
            throw AetherPlaybackTrackSelectionError.unknownTrack(id)
        }
        switch self {
        case .native(let session):
            try await session.selectAudioTrack(sourceTrackID)
        case .hybrid(let session):
            try await session.selectAudioTrack(sourceTrackID)
        }
    }

    func selectSubtitleTrack(_ id: String?) async throws {
        switch self {
        case .native(let session):
            if let id {
                guard let track = subtitleTracks.first(where: {
                    $0.id == id
                }), let sourceTrackID = track.sourceTrackID else {
                    throw AetherPlaybackTrackSelectionError
                        .unknownTrack(id)
                }
                try await session.selectSubtitleTrack(sourceTrackID)
            } else {
                try await session.selectSubtitleTrack(nil)
            }
        case .hybrid(let session):
            guard let id else {
                try session.selectOverlaySubtitleTrack(nil)
                try await session.selectNativeSubtitleTrack(nil)
                return
            }
            if id.hasPrefix("subtitle-source:"),
               let trackID = Int(id.dropFirst(
                    "subtitle-source:".count
               )) {
                try session.selectOverlaySubtitleTrack(trackID)
            } else if id.hasPrefix("subtitle-overlay:"),
               let trackID = Int(id.dropFirst(
                    "subtitle-overlay:".count
               )) {
                try session.selectOverlaySubtitleTrack(trackID)
            } else if id.hasPrefix("subtitle-native:"),
                      let ordinal = Int(id.dropFirst(
                        "subtitle-native:".count
                      )) {
                try await session.selectNativeSubtitleTrack(ordinal)
            } else {
                throw AetherPlaybackTrackSelectionError.unknownTrack(id)
            }
        }
    }

    func stop() {
        switch self {
        case .native(let session): session.stop()
        case .hybrid(let session): session.stop()
        }
    }

    func stopAndWaitForIOQuiescence() async {
        switch self {
        case .native(let session):
            await session.stopAndWaitForIOQuiescence()
        case .hybrid(let session):
            await session.stopAndWaitForIOQuiescence()
        }
    }
}

@MainActor
private enum AetherResolvedPlaybackSource {
    case hls(AetherHLSPlaybackPreflight)
    case progressive(
        probe: SourceProbe,
        result: PlaybackPreflightResult,
        preparedSource: AetherPreparedURLSource?
    )
    /// Package-test-only route fixture. Production source resolution never
    /// constructs this case and cannot use it as playback admission.
    case startupWatchdogTestHarness(PlaybackPreflightResult)

    var result: PlaybackPreflightResult {
        switch self {
        case .hls(let preflight): preflight.result
        case .progressive(_, let result, _): result
        case .startupWatchdogTestHarness(let result): result
        }
    }

    var nativeExecutionMode:
        AetherNativePlaybackExecutionMode?
    {
        guard result.route == .nativeAVPlayer else { return nil }
        return result.reason == .nativeHLSFMP4Remux
            ? .aetherRemux
            : .directAsset
    }

    var progressiveSourceFacts: AetherProgressiveSourceFacts? {
        guard case .progressive(let probe, _, _) = self else {
            return nil
        }
        return AetherProgressiveSourceFacts(probe: probe)
    }

    var progressiveSourceGeneration:
        SourceByteStoreGeneration?
    {
        guard case .progressive(
            _, _, let preparedSource
        ) = self else {
            return nil
        }
        return preparedSource?.sourceGeneration
    }

    /// Generic FFmpeg INVALIDDATA/EOF is positive malformed-media evidence
    /// only after the exact validator-bound generation is fully resident.
    /// Partial or unvalidated remote bytes remain transport availability.
    var progressiveSourceIsCompleteAndValidatorBound: Bool {
        guard case .progressive(
            _, _, let preparedSource
        ) = self,
        let snapshot = preparedSource?
            .sourceByteStore?.snapshot,
        snapshot.isComplete,
        snapshot.generation.validator != nil else {
            return false
        }
        return true
    }

    var hlsResourceIdentity: String? {
        guard case .hls(let preflight) = self else { return nil }
        return preflight.resourceIdentity
    }

    func discardUnconsumedPreparedSourceAndWaitForIOQuiescence()
        async
    {
        guard case .progressive(
            _, _, let preparedSource
        ) = self,
        let preparedSource else {
            return
        }
        await Task.detached(priority: .userInitiated) {
            preparedSource
                .discardAndWaitForIOQuiescence()
        }.value
    }

    func admitting(
        route: PlaybackRenderRoute,
        requiredAudioBridgeMode: AudioBridgeMode
    ) -> AetherResolvedPlaybackSource? {
        _ = requiredAudioBridgeMode
        return result.route == route ? self : nil
    }
}

enum AetherNativePlaybackExecutionMode:
    String,
    Sendable,
    Equatable
{
    case directAsset
    case aetherRemux
}

/// Closed identity for the three execution paths monitored by the one outer
/// startup watchdog. The Native render route intentionally has two execution
/// modes; keeping them explicit here proves that neither owns a private
/// startup watchdog or escapes Aether's same-route recovery boundary.
enum AetherPlaybackStartupWatchdogTarget:
    String,
    Sendable,
    Equatable
{
    case directNative
    case nativeAudioBridge
    case hybrid

    var route: PlaybackRenderRoute {
        switch self {
        case .directNative, .nativeAudioBridge: .nativeAVPlayer
        case .hybrid: .hybridCarrier
        }
    }

    static func resolve(
        activeRoute: PlaybackRenderRoute?,
        nativeExecutionMode: AetherNativePlaybackExecutionMode?
    ) -> Self? {
        switch (activeRoute, nativeExecutionMode) {
        case (.nativeAVPlayer, .directAsset): .directNative
        case (.nativeAVPlayer, .aetherRemux): .nativeAudioBridge
        case (.hybridCarrier, _): .hybrid
        case (.nativeAVPlayer, nil), (.unsupported, _), (nil, _): nil
        }
    }
}

private struct AetherPendingTransportMonitoringRequest {
    let sequence: UInt64
    let generation: UInt64
}

private struct AetherPendingTransportStartupFailure {
    let sequence: UInt64
    let generation: UInt64
    let failure: AetherPlaybackFailure
}

private final class AetherCancellationQuiescenceFence:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var didQuiesce = false

    func markQuiesced() {
        lock.lock()
        didQuiesce = true
        lock.unlock()
    }

    var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !didQuiesce
    }
}

@MainActor
private struct AetherPlaybackContextSnapshot {
    let position: CMTime
}

@MainActor
private final class AetherPlaybackAudioAnalysisProxy {
    let id = UUID()
    let originalRequest: AudioAnalysisRequest
    let gate = AudioAnalysisDemandGate()
    var task: Task<Void, Never>?
    var lastConfirmedSamplePosition: Int64?
    var shouldMarkDiscontinuity = false

    init(request: AudioAnalysisRequest) {
        originalRequest = request
    }
}

/// Single-resume broker for Aether-owned asynchronously suspended work that
/// may ignore task cancellation while blocked in a framework or native
/// dependency. Unlike a structured task-group race, the caller never waits
/// for the losing operation after the deadline. This cannot preempt
/// synchronous MainActor work; lower layers must still place cancellation or
/// generation checks immediately after their own suspension points. The
/// owning route transaction remains the authority that rejects any late
/// install or commit.
@MainActor
final class AetherPlaybackOperationDeadlineRace<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var onAbandon: (() -> Void)?

    func run(
        timeout: TimeInterval,
        timeoutFailure: AetherPlaybackFailure,
        onAbandon: @escaping () -> Void = {},
        operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        guard timeout.isFinite, timeout > 0 else {
            onAbandon()
            throw timeoutFailure
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(
                    continuation: continuation,
                    timeout: timeout,
                    timeoutFailure: timeoutFailure,
                    onAbandon: onAbandon,
                    operation: operation
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    private func start(
        continuation: CheckedContinuation<Value, Error>,
        timeout: TimeInterval,
        timeoutFailure: AetherPlaybackFailure,
        onAbandon: @escaping () -> Void,
        operation: @escaping @MainActor @Sendable () async throws -> Value
    ) {
        self.continuation = continuation
        self.onAbandon = onAbandon
        operationTask = Task { @MainActor [self] in
            do {
                resolve(.success(try await operation()))
            } catch {
                resolve(.failure(error))
            }
        }
        timeoutTask = Task { @MainActor [self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(timeout * 1_000_000_000)
                )
            } catch {
                return
            }
            guard continuationIsPending else { return }
            self.onAbandon?()
            resolve(.failure(timeoutFailure))
        }
    }

    private var continuationIsPending: Bool {
        continuation != nil
    }

    func cancel() {
        guard continuationIsPending else { return }
        onAbandon?()
        resolve(.failure(CancellationError()))
    }

    private func resolve(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        onAbandon = nil
        operationTask?.cancel()
        timeoutTask?.cancel()
        operationTask = nil
        timeoutTask = nil
        continuation.resume(with: result)
    }
}

/// Aether-owned playback lifecycle. The host mounts one player and one
/// presentation container; route reconstruction and evidence-backed route
/// transitions remain entirely inside this object.
@MainActor
public final class AetherPlaybackSession: ObservableObject {
    /// Production publication allowance retained for source compatibility
    /// with focused policy tests. The recovery budget is the single source of
    /// truth; this is not an additional retry window.
    nonisolated static var recoveryTerminalPublicationHeadroomSeconds:
        TimeInterval
    {
        AetherPlaybackRecoveryBudget.production
            .startupTerminalPublicationHeadroomSeconds
    }

    /// Public admission catalog for the internally owned Hybrid route.
    /// Hosts may display capability information, but cannot construct or
    /// select the route implementation directly.
    public nonisolated static var hybridCapabilities:
        HybridPlaybackCapabilities
    {
        AetherHybridPlaybackSession.capabilities
    }

    /// System-feature contract that would apply if recovery admits Hybrid.
    public nonisolated static var hybridSystemFeaturePolicy:
        HybridPlaybackSystemFeaturePolicy
    {
        AetherHybridPlaybackSession.systemFeaturePolicy
    }

    public let avPlayer: AVPlayer
    public let presentationView: AetherPlaybackPresentationView
    public let sessionID: UUID
    public let sourceFingerprint: String

    @Published public private(set) var state:
        AetherPlaybackSessionState = .idle
    @Published public private(set) var currentItem: AVPlayerItem?
    @Published public private(set) var activeRoute:
        PlaybackRenderRoute?
    @Published public private(set) var videoOutputSnapshot:
        AetherVideoOutputSnapshot = .unresolved
    @Published public private(set) var preflightResult:
        PlaybackPreflightResult?
    @Published public private(set) var capabilities:
        AetherPlaybackCapabilities
    @Published public private(set) var recoveryHistory:
        [AetherPlaybackRecoveryEvent] = []
    @Published public private(set) var firstFailure:
        AetherPlaybackFailure?
    @Published public private(set) var terminalFailure:
        AetherPlaybackTerminalFailure?
    @Published public private(set) var livenessSnapshot:
        AetherPlaybackLivenessSnapshot = .idle
    @Published public private(set) var selectedAudioAnalysisTrackID:
        Int?
    @Published public private(set) var audioTracks:
        [AetherPlaybackTrack] = []
    @Published public private(set) var subtitleTracks:
        [AetherPlaybackTrack] = []
    @Published public private(set) var selectedAudioTrackID: String?
    @Published public private(set) var selectedSubtitleTrackID: String?
    @Published public private(set) var overlaySubtitleTracks:
        [AetherHybridOverlaySubtitleTrack] = []
    @Published public private(set) var activeOverlaySubtitleTrackID:
        Int?

    public var audioAnalysisTrackIDs: [Int] {
        activeSession?.audioAnalysisTrackIDs ?? []
    }

    public var audioAnalysisDurationSeconds: Double? {
        activeSession?.audioAnalysisDurationSeconds
    }

    public var hybridDiagnostics: AetherHybridPlaybackDiagnostics? {
        guard case .hybrid(let session) = activeSession else {
            return nil
        }
        return session.diagnostics
    }

    /// Current privacy-safe transport evidence. This is observational only;
    /// media-time progress and presented frames remain the acceptance proof.
    public var transportSnapshot: AetherPlaybackTransportSnapshot {
        let item = avPlayer.currentItem
        let time = avPlayer.currentTime()
        let seconds = Self.transportSnapshotMediaTime(time)
        return AetherPlaybackTransportSnapshot(
            commandSequence: transportCommandSequence,
            routeGeneration: transportRouteGeneration,
            desiredPlaying: desiredPlaying,
            desiredRate: desiredRate,
            route: activeSession?.route ?? activeRoute,
            applicationPhase: transportApplicationPhase(
                item: item
            ),
            actualRate: avPlayer.rate,
            timeControlStatus: Self.timeControlStatus(
                avPlayer.timeControlStatus
            ),
            waitingReason: Self.waitingReason(
                avPlayer.reasonForWaitingToPlay
            ),
            itemStatus: Self.itemStatus(item),
            mediaTimeSeconds: seconds,
            loadedTimeRangeCount: item?.loadedTimeRanges.count ?? 0,
            recoverySequence: eventSequence,
            reassertCount: transportReassertCount,
            lastReassertedCommandSequence:
                lastReassertedTransportCommandSequence
        )
    }

    /// Monotonic count of all recovery events emitted by this session.
    ///
    /// `recoveryHistory` intentionally retains only the latest 64 events; this
    /// counter preserves the full attempt/event total without unbounded memory.
    public var totalRecoveryEventCount: UInt64 {
        eventSequence
    }

    nonisolated static func transportSnapshotMediaTime(
        _ time: CMTime
    ) -> Double? {
        guard time.isValid,
              time.isNumeric,
              time.seconds.isFinite,
              time.seconds >= 0 else { return nil }
        return time.seconds
    }

    private let url: URL
    private let options: LoadOptions
    private let variantSelection: HLSPreflightVariantSelection
    private let recoveryBudget: AetherPlaybackRecoveryBudget
    private let routeNeutralAllowsExternalPlayback: Bool
    #if os(iOS) || os(tvOS)
    private let routeNeutralUsesExternalPlaybackWhileExternalScreenIsActive:
        Bool
    #endif
    private var resolvedSource: AetherResolvedPlaybackSource?
    private var activeSession: AetherActiveRouteSession?
    private var transportTestRoute:
        (any AetherPlaybackTransportRoute)?
    private var transportRoute:
        (any AetherPlaybackTransportRoute)?
    {
        if let transportTestRoute { return transportTestRoute }
        return activeSession
    }
    private var activeNativeExecutionMode:
        AetherNativePlaybackExecutionMode?
    private var routeCancellables = Set<AnyCancellable>()
    private var videoOutputReducer =
        AetherSessionVideoOutputReducer()
    private var currentItemObservation: NSKeyValueObservation?
    private var transportTimeControlObservation:
        NSKeyValueObservation?
    private var healthyProgressObserver: Any?
    private var playbackProgressEpoch = PlaybackProgressEpoch()
    private var lastConfirmedMediaTime: CMTime = .zero
    private var recoveryTask: Task<Void, Never>?
    private var routeIOQuiescenceTask:
        Task<Void, Never>?
    private var routeIOQuiescenceGeneration: UInt64 = 0
    private var pendingIOOwnershipOperationCount = 0
    private var ioOwnershipQuiescenceWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var shutdownTask: Task<Void, Never>?
    private var shutdownGeneration: UInt64 = 0
    private var isStopped = false
    private var isPreparingOrRecovering = false
    private var didCompleteInitialPrepare = false
    private var desiredPlaying = false
    private var desiredRate: Float = 1
    private var transportCommandSequence: UInt64 = 0
    private var transportRouteGeneration: UInt64 = 0
    private var transportReassertCount = 0
    private var lastReassertedTransportCommandSequence: UInt64?
    private var transportIsApplying = false
    private var transportMonitoringGeneration: UInt64 = 0
    private var transportReassertTask: Task<Void, Never>?
    private var startupProgressTask: Task<Void, Never>?
    private var pendingTransportMonitoringRequest:
        AetherPendingTransportMonitoringRequest?
    private var pendingTransportStartupFailure:
        AetherPendingTransportStartupFailure?
    private var desiredSeekTarget: CMTime?
    private var desiredAudioTrackID: String?
    private var desiredSubtitleTrackID: String?
    private var operationCoordinator = PlaybackOperationCoordinator()
    private var routeTransactions =
        PlaybackRouteTransactionCoordinator()
    private var activeSeekOperationSequence: UInt64?
    private var lastAppliedSeekOperationSequence: UInt64?
    private var desiredOverlaySubtitleTrackID: Int?
    private var externalMetadata: [AVMetadataItem] = []
    private var systemActivity = AetherSystemPlaybackActivity()
    private var eventSequence: UInt64 = 0
    private var recoveryCoordinator = PlaybackRecoveryCoordinator(
        now: ProcessInfo.processInfo.systemUptime
    )
    private var recoveryLogCadence:
        AetherBoundedRetryLogCadence
    private var progressLogCadence =
        AetherBoundedProgressLogCadence()
    private var routePreparationRetryProjection =
        AetherRoutePreparationRetryProjection()
    private var capabilitiesBeforeRecoveryAttempt:
        AetherPlaybackCapabilities?
    private var mergedRuntimeFailureKeys = Set<String>()
    private var lastRecoveryFailure: AetherPlaybackFailure?
    private let transportRetryBudget:
        PlaybackTransportRetryBudget
    private var transportLivenessAttempt = 0
    private var livenessGeneration: UInt64 = 0
    private var livenessDiagnosticTask: Task<Void, Never>?
    private let livenessDiagnosticClock:
        any AetherLivenessDiagnosticClock
    private let livenessDiagnosticCheckpointObserver:
        (@MainActor (TimeInterval) -> Void)?
    private var activeProgressivePreflight:
        AetherProgressivePreflight?
    private var progressiveLivenessObservationTask:
        Task<Void, Never>?
    private var progressivePreflightEpoch: UInt64 = 0
    private var classificationProgressFence =
        AetherClassificationProgressFence()
    private let progressiveFetchedByteProgressLedger =
        AetherFetchedByteProgressLedger()
    private var audioAnalysisProxies: [
        UUID: AetherPlaybackAudioAnalysisProxy
    ] = [:]

    #if os(tvOS)
    private weak var playerViewController: AVPlayerViewController?
    #endif

    init(
        url: URL,
        options: LoadOptions,
        variantSelection: HLSPreflightVariantSelection,
        recoveryBudget: AetherPlaybackRecoveryBudget = .production,
        livenessDiagnosticClock:
            any AetherLivenessDiagnosticClock =
                AetherSystemLivenessDiagnosticClock(),
        livenessDiagnosticCheckpointObserver:
            (@MainActor (TimeInterval) -> Void)? = nil
    ) {
        self.url = url
        self.options = options
        self.variantSelection = variantSelection
        self.recoveryBudget = recoveryBudget
        recoveryLogCadence = AetherBoundedRetryLogCadence(
            policy: recoveryBudget.livenessPolicy
        )
        self.livenessDiagnosticClock =
            livenessDiagnosticClock
        self.livenessDiagnosticCheckpointObserver =
            livenessDiagnosticCheckpointObserver
        // Transport liveness is intentionally unbounded. Structural route and
        // decoder transitions remain governed by `recoveryBudget`.
        transportRetryBudget = PlaybackTransportRetryBudget(
            maximumFailureAttempts: nil
        )
        let stablePlayer = AVPlayer()
        avPlayer = stablePlayer
        routeNeutralAllowsExternalPlayback =
            stablePlayer.allowsExternalPlayback
        #if os(iOS) || os(tvOS)
        routeNeutralUsesExternalPlaybackWhileExternalScreenIsActive =
            stablePlayer.usesExternalPlaybackWhileExternalScreenIsActive
        #endif
        presentationView = AetherPlaybackPresentationView()
        sessionID = UUID()
        var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )
        components?.query = nil
        components?.fragment = nil
        let publicSourceClass = components?.url?.absoluteString
            ?? "invalid-url-class"
        sourceFingerprint = String(
            HLSVODResourceDigest.sha256(
                Data(publicSourceClass.utf8)
            ).prefix(12)
        )
        capabilities = Self.capabilities(for: nil, source: nil)
        currentItemObservation = avPlayer.observe(
            \.currentItem,
            options: [.initial, .new]
        ) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                self?.publishCurrentItem(player.currentItem)
            }
        }
        transportTimeControlObservation = avPlayer.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self] player, _ in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player else { return }
                let sequence = self.transportCommandSequence
                let generation = self.transportRouteGeneration
                self.reconcileObservedTransport(
                    Self.timeControlStatus(
                        player.timeControlStatus
                    ),
                    commandSequence: sequence,
                    routeGeneration: generation
                )
            }
        }
        healthyProgressObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(
                seconds: 0.5,
                preferredTimescale: 600
            ),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.observeHealthyProgress(time)
            }
        }
    }

    public func prepare() async throws {
        guard !isStopped, state == .idle else {
            throw AetherPlaybackSessionError.invalidState
        }
        beginLivenessObservation(phase: .classifying)
        state = .preparing
        isPreparingOrRecovering = true
        do {
            let source = try await resolveCanonicalSource()
            try await installAndPrepare(source)
            try await applyCanonicalDefaultTrackIntent()
            didCompleteInitialPrepare = true
            isPreparingOrRecovering = false
            state = .ready
            if desiredPlaying {
                try applyTransportIntent(
                    sequence: transportCommandSequence,
                    expectedRouteGeneration:
                        transportRouteGeneration
                )
            }
            resetRecoveryEpisode()
        } catch is CancellationError {
            isPreparingOrRecovering = false
            await stopAndWaitForIOQuiescence()
            throw CancellationError()
        } catch {
            let initialFailure = failure(
                stage: Self.initialPreparationFailureStage(
                    hasInstalledRoute: activeSession != nil
                ),
                error: error
            )
            try await recoverOrTerminate(
                from: initialFailure,
                duringInitialPrepare: true,
                failureStage: .preparation,
                exhaustionReason: "initial recovery exhausted"
            )
            didCompleteInitialPrepare = true
            isPreparingOrRecovering = false
            return
        }
    }

    public func play() throws {
        guard !isStopped,
              terminalFailure == nil else {
            throw AetherPlaybackSessionError.invalidState
        }
        desiredPlaying = true
        if desiredRate <= 0 { desiredRate = 1 }
        let sequence = beginTransportCommand()
        guard !isPreparingOrRecovering,
              activeSeekOperationSequence == nil else { return }
        try applyTransportIntent(sequence: sequence)
    }

    public func pause() throws {
        guard !isStopped,
              terminalFailure == nil else {
            throw AetherPlaybackSessionError.invalidState
        }
        desiredPlaying = false
        let sequence = beginTransportCommand()
        guard !isPreparingOrRecovering,
              activeSeekOperationSequence == nil else { return }
        try applyTransportIntent(sequence: sequence)
    }

    public func setRate(_ rate: Float) throws {
        guard rate.isFinite, rate >= 0,
              !isStopped,
              terminalFailure == nil else {
            throw AetherPlaybackSessionError.invalidState
        }
        desiredRate = rate == 0 ? max(desiredRate, 1) : rate
        desiredPlaying = rate > 0
        let sequence = beginTransportCommand()
        guard !isPreparingOrRecovering,
              activeSeekOperationSequence == nil else { return }
        try applyTransportIntent(sequence: sequence)
    }

    @discardableResult
    private func beginTransportCommand() -> UInt64 {
        transportCommandSequence &+= 1
        transportReassertCount = 0
        lastReassertedTransportCommandSequence = nil
        pendingTransportMonitoringRequest = nil
        pendingTransportStartupFailure = nil
        cancelTransportMonitoring()
        return transportCommandSequence
    }

    /// The single outer-session transport application boundary. Every
    /// positive-rate intent starts the route through `play()`; speed is a
    /// second operation only when it differs from canonical 1x playback.
    private func applyTransportIntent(
        sequence: UInt64,
        expectedRouteGeneration: UInt64? = nil,
        isReassertion: Bool = false,
        deferMonitoringUntilRecoveryHandoff: Bool = false
    ) throws {
        guard sequence == transportCommandSequence,
              expectedRouteGeneration == nil
                || expectedRouteGeneration == transportRouteGeneration else {
            return
        }
        guard let transportRoute else {
            throw AetherPlaybackSessionError.noActiveRoute
        }
        let generation = transportRouteGeneration
        let routeIdentity = transportRoute.transportIdentity
        transportIsApplying = true
        defer { transportIsApplying = false }
        for operation in AetherPlaybackTransportDecision.operations(
            desiredPlaying: desiredPlaying,
            desiredRate: desiredRate
        ) {
            switch operation {
            case .play:
                try transportRoute.play()
            case .pause:
                try transportRoute.pause()
            case .setRate(let rate):
                try transportRoute.setRate(rate)
            }
            guard sequence == transportCommandSequence,
                  generation == transportRouteGeneration,
                  self.transportRoute?.transportIdentity
                    == routeIdentity else {
                return
            }
        }
        if desiredPlaying {
            state = Self.stateAfterAppliedSeek(
                desiredPlaying: desiredPlaying,
                desiredRate: desiredRate,
                carrierRate: avPlayer.rate,
                carrierTimeControlStatus: avPlayer.timeControlStatus
            )
            if isReassertion {
                transportReassertCount += 1
                lastReassertedTransportCommandSequence = sequence
                EngineLog.emit(
                    "[AetherPlaybackSession] transport reasserted "
                        + "session=\(sessionID.uuidString.prefix(8)) "
                        + "command=\(sequence) generation=\(generation) "
                        + "count=\(transportReassertCount)",
                    category: .session
                )
            } else if deferMonitoringUntilRecoveryHandoff {
                pendingTransportMonitoringRequest =
                    AetherPendingTransportMonitoringRequest(
                        sequence: sequence,
                        generation: generation
                    )
            } else {
                scheduleTransportMonitoring(
                    sequence: sequence,
                    generation: generation
                )
            }
        } else {
            cancelTransportMonitoring()
            state = .paused
        }
    }

    private func cancelTransportMonitoring() {
        transportMonitoringGeneration &+= 1
        transportReassertTask?.cancel()
        transportReassertTask = nil
        startupProgressTask?.cancel()
        startupProgressTask = nil
    }

    private func reconcileObservedTransport(
        _ observedStatus: AetherPlaybackTimeControlStatus,
        commandSequence: UInt64,
        routeGeneration: UInt64
    ) {
        guard !isStopped,
              terminalFailure == nil,
              !isPreparingOrRecovering,
              activeSeekOperationSequence == nil else { return }
        switch state {
        case .ended, .failed, .stopped:
            return
        case .idle, .preparing, .ready, .playing, .paused,
             .seeking, .recovering:
            break
        }
        guard let reconciled = AetherPlaybackTransportDecision
            .reconciledState(
                requestedSequence: commandSequence,
                currentSequence: transportCommandSequence,
                requestedGeneration: routeGeneration,
                currentGeneration: transportRouteGeneration,
                desiredPlaying: desiredPlaying,
                timeControlStatus: observedStatus
            ) else { return }
        state = reconciled
    }

    private func scheduleTransportMonitoring(
        sequence: UInt64,
        generation: UInt64
    ) {
        cancelTransportMonitoring()
        let monitoringGeneration = transportMonitoringGeneration
        let baseline = avPlayer.currentTime()
        let baselineUniqueBytes =
            livenessSnapshot.uniqueBytesFetched
        let baselineLoadedRangeEnd =
            Self.maximumLoadedRangeEndSeconds(
                avPlayer.currentItem
            )
        let baselinePresentedFrameSequence =
            videoOutputSnapshot.frameSequence
        let watchdogTarget = AetherPlaybackStartupWatchdogTarget
            .resolve(
                activeRoute: activeRoute,
                nativeExecutionMode: activeNativeExecutionMode
            )
        let observation = recoveryBudget.livenessPolicy
            .noProgressWindowSeconds(
                forAttempt: max(1, transportLivenessAttempt + 1)
            )
        transportReassertTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.transportMonitoringGeneration
                    == monitoringGeneration {
                    self.transportReassertTask = nil
                }
            }
            do {
                let readinessDeadline =
                    ProcessInfo.processInfo.systemUptime + observation
                while self.avPlayer.currentItem?.status != .readyToPlay {
                    guard self.transportMonitoringGeneration
                            == monitoringGeneration,
                          self.avPlayer.currentItem?.status != .failed,
                          ProcessInfo.processInfo.systemUptime
                            < readinessDeadline else { return }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            guard self.transportMonitoringGeneration
                    == monitoringGeneration else { return }
            self.activeSession?.pollVideoOutput()
            let item = self.avPlayer.currentItem
            guard AetherPlaybackTransportDecision.shouldReassert(
                requestedSequence: sequence,
                currentSequence: self.transportCommandSequence,
                requestedGeneration: generation,
                currentGeneration: self.transportRouteGeneration,
                desiredPlaying: self.desiredPlaying,
                desiredRate: self.desiredRate,
                itemIsReady: item?.status == .readyToPlay,
                actualRate: self.avPlayer.rate,
                timeControlStatus: Self.timeControlStatus(
                    self.avPlayer.timeControlStatus
                ),
                routeApplicationIsTemporarilyUnavailable:
                    self.transportRoute?
                        .transportApplicationIsTemporarilyUnavailable
                        ?? false,
                reassertCount: self.transportReassertCount
            ) else {
                if self.transportRoute?
                    .transportApplicationIsTemporarilyUnavailable
                    == true {
                    self.publishTransientRouteBuffering(
                        sequence: sequence,
                        generation: generation,
                        reason: "reassert-deferred"
                    )
                }
                return
            }
            do {
                try self.applyTransportIntent(
                    sequence: sequence,
                    expectedRouteGeneration: generation,
                    isReassertion: true
                )
            } catch {
                if self.transportRoute?
                    .transportApplicationIsTemporarilyUnavailable
                    == true {
                    self.publishTransientRouteBuffering(
                        sequence: sequence,
                        generation: generation,
                        reason: "reassert-raced-route-activity"
                    )
                    return
                }
                self.scheduleTransportStartupRecovery(
                    .transportIntentNotApplied,
                    sequence: sequence,
                    generation: generation,
                    watchdogTarget: watchdogTarget,
                    underlyingError: error
                )
            }
        }

        startupProgressTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.transportMonitoringGeneration
                    == monitoringGeneration {
                    self.startupProgressTask = nil
                }
            }
            do {
                if observation > 0 {
                    try await Task.sleep(
                        nanoseconds:
                            UInt64(observation * 1_000_000_000)
                    )
                }
            } catch {
                return
            }
            guard self.transportMonitoringGeneration
                    == monitoringGeneration else { return }
            self.activeSession?.pollVideoOutput()
            let item = self.avPlayer.currentItem
            let currentTime = self.avPlayer.currentTime()
            let nativeMediaTimeMadeProgress =
                self.activeRoute == .nativeAVPlayer
                && Self.madeStartupProgress(
                from: baseline,
                to: currentTime
            )
            let presentedFrameMadeProgress =
                self.videoOutputSnapshot.outputStatus
                    == .presented
                && self.videoOutputSnapshot.frameSequence
                    > baselinePresentedFrameSequence
            let madeProgress =
                nativeMediaTimeMadeProgress
                || presentedFrameMadeProgress
            let loadedRangeEnd =
                Self.maximumLoadedRangeEndSeconds(item)
            let loadedRangeMadeProgress =
                self.activeRoute == .nativeAVPlayer
                && loadedRangeEnd
                    > baselineLoadedRangeEnd + 0.05
            let sourceMadeProgress =
                self.livenessSnapshot.uniqueBytesFetched
                    > baselineUniqueBytes
                || loadedRangeMadeProgress
            if madeProgress {
                self.transportLivenessAttempt = 0
                self.publishLiveness(
                    phase: .flowing,
                    attempt: 0,
                    uniqueBytesFetched:
                        self.livenessSnapshot.uniqueBytesFetched,
                    lastMeaningfulProgressUptimeSeconds:
                        ProcessInfo.processInfo.systemUptime,
                    nextRetryUptimeSeconds: nil
                )
                self.scheduleTransportMonitoring(
                    sequence: sequence,
                    generation: generation
                )
                return
            }
            if !madeProgress, sourceMadeProgress {
                self.transportLivenessAttempt = 0
                if loadedRangeMadeProgress {
                    let progressUptime =
                        ProcessInfo.processInfo.systemUptime
                    _ = self.emitBoundedProgressLog(
                        .loadedRange(
                            phase: .buffering,
                            generation:
                                self.livenessGeneration,
                            attempt: 0,
                            fromSeconds:
                                baselineLoadedRangeEnd,
                            toSeconds: loadedRangeEnd,
                            progressUptime: progressUptime,
                            observedUptime: progressUptime
                        )
                    )
                }
                self.publishLiveness(
                    phase: .buffering,
                    attempt: 0,
                    uniqueBytesFetched:
                        self.livenessSnapshot.uniqueBytesFetched,
                    lastMeaningfulProgressUptimeSeconds:
                        ProcessInfo.processInfo.systemUptime,
                    nextRetryUptimeSeconds: nil
                )
                self.scheduleTransportMonitoring(
                    sequence: sequence,
                    generation: generation
                )
                return
            }
            guard let failureCase =
                    AetherPlaybackTransportDecision.startupFailure(
                requestedSequence: sequence,
                currentSequence: self.transportCommandSequence,
                requestedGeneration: generation,
                currentGeneration: self.transportRouteGeneration,
                desiredPlaying: self.desiredPlaying,
                madeProgress: madeProgress,
                itemIsReady: item?.status == .readyToPlay,
                actualRate: self.avPlayer.rate,
                timeControlStatus: Self.timeControlStatus(
                    self.avPlayer.timeControlStatus
                )
            ) else { return }
            let snapshot = self.transportSnapshot
            EngineLog.emit(
                "[AetherPlaybackSession] startup no-progress "
                    + "session=\(self.sessionID.uuidString.prefix(8)) "
                    + "command=\(sequence) generation=\(generation) "
                    + "case=\(failureCase.rawValue) "
                    + "execution=\(watchdogTarget?.rawValue ?? "unknown") "
                    + "route=\(snapshot.route?.rawValue ?? "none") "
                    + "phase=\(snapshot.applicationPhase.rawValue) "
                    + "item=\(snapshot.itemStatus.rawValue) "
                    + "timeControl=\(snapshot.timeControlStatus.rawValue) "
                    + "loadedRanges=\(snapshot.loadedTimeRangeCount)",
                category: .session
            )
            self.scheduleTransportStartupRecovery(
                failureCase,
                sequence: sequence,
                generation: generation,
                watchdogTarget: watchdogTarget
            )
        }
    }

    private func publishTransientRouteBuffering(
        sequence: UInt64,
        generation: UInt64,
        reason: String
    ) {
        guard sequence == transportCommandSequence,
              generation == transportRouteGeneration,
              desiredPlaying,
              !isStopped,
              terminalFailure == nil else { return }
        publishLiveness(
            phase: .buffering,
            attempt: livenessSnapshot.attempt,
            uniqueBytesFetched:
                livenessSnapshot.uniqueBytesFetched,
            lastMeaningfulProgressUptimeSeconds:
                livenessSnapshot
                    .lastMeaningfulProgressUptimeSeconds,
            nextRetryUptimeSeconds: nil
        )
        EngineLog.emit(
            "[AetherPlaybackSession] transport buffering "
                + "session=\(sessionID.uuidString.prefix(8)) "
                + "command=\(sequence) generation=\(generation) "
                + "reason=\(reason)",
            category: .session
        )
    }

    private func scheduleTransportStartupRecovery(
        _ failureCase: AetherPlaybackStartupFailureCase,
        sequence: UInt64,
        generation: UInt64,
        watchdogTarget: AetherPlaybackStartupWatchdogTarget?,
        underlyingError: Error? = nil
    ) {
        guard sequence == transportCommandSequence,
              generation == transportRouteGeneration,
              desiredPlaying,
              !isStopped,
              terminalFailure == nil else { return }
        let failure = transportStartupFailure(
            failureCase,
            underlyingError: underlyingError
        )
        EngineLog.emit(
            "[AetherPlaybackSession] outer startup recovery "
                + "execution=\(watchdogTarget?.rawValue ?? "unknown") "
                + "route=\(watchdogTarget?.route.rawValue ?? activeRoute?.rawValue ?? "none") "
                + "case=\(failureCase.rawValue)",
            category: .session
        )
        if recoveryTask != nil {
            pendingTransportStartupFailure =
                AetherPendingTransportStartupFailure(
                    sequence: sequence,
                    generation: generation,
                    failure: failure
                )
            EngineLog.emit(
                "[AetherPlaybackSession] startup recovery latched "
                    + "command=\(sequence) generation=\(generation)",
                category: .session
            )
            return
        }
        scheduleRuntimeRecovery(failure)
    }

    @discardableResult
    private func drainPendingTransportStartupFailure() -> Bool {
        guard let pending = pendingTransportStartupFailure else {
            return false
        }
        pendingTransportStartupFailure = nil
        guard pending.sequence == transportCommandSequence,
              pending.generation == transportRouteGeneration,
              desiredPlaying,
              !isStopped,
              terminalFailure == nil else { return false }
        scheduleRuntimeRecovery(pending.failure)
        return recoveryTask != nil || terminalFailure != nil
    }

    private func drainPendingTransportMonitoringRequest() {
        guard let pending = pendingTransportMonitoringRequest else {
            return
        }
        pendingTransportMonitoringRequest = nil
        guard recoveryTask == nil,
              pending.sequence == transportCommandSequence,
              pending.generation == transportRouteGeneration,
              desiredPlaying,
              !isStopped,
              terminalFailure == nil else { return }
        scheduleTransportMonitoring(
            sequence: pending.sequence,
            generation: pending.generation
        )
    }

    private func completeRecoveryTransportHandoff() {
        guard recoveryTask == nil else { return }
        if !drainPendingTransportStartupFailure() {
            drainPendingTransportMonitoringRequest()
        }
    }

    private func transportStartupFailure(
        _ failureCase: AetherPlaybackStartupFailureCase,
        underlyingError: Error? = nil
    ) -> AetherPlaybackFailure {
        let nsError = underlyingError.map { $0 as NSError }
        return AetherPlaybackFailure(
            stage: .playback,
            kind: .routeRuntimeFailure,
            domain: nsError?.domain ?? "AetherPlaybackTransport",
            code: nsError?.code ?? 0,
            caseCode: failureCase.rawValue,
            reason: "aether.playback.\(failureCase.rawValue)"
        )
    }

    nonisolated static func madeStartupProgress(
        from baseline: CMTime,
        to current: CMTime
    ) -> Bool {
        guard baseline.isNumeric, current.isNumeric else { return false }
        return CMTimeSubtract(current, baseline).seconds > 0.1
    }

    nonisolated static func maximumLoadedRangeEndSeconds(
        _ item: AVPlayerItem?
    ) -> Double {
        item?.loadedTimeRanges.reduce(0) { current, value in
            let range = value.timeRangeValue
            let end = CMTimeGetSeconds(
                CMTimeRangeGetEnd(range)
            )
            guard end.isFinite else { return current }
            return max(current, end)
        } ?? 0
    }

    /// Package-test seam for exercising the real async outer-session command
    /// coordinator. The controllable fake remains in the test target; this
    /// method only installs its narrow transport boundary.
    func installTransportRaceTestHarness(
        _ route: any AetherPlaybackTransportRoute,
        renderRoute: PlaybackRenderRoute = .nativeAVPlayer
    ) {
        precondition(state == .idle)
        precondition(activeSession == nil)
        precondition(transportTestRoute == nil)
        transportTestRoute = route
        activeRoute = renderRoute
        didCompleteInitialPrepare = true
        transportRouteGeneration &+= 1
        state = .ready
    }

    /// Package-test seam for the release-fence publication contract. The
    /// supplied operation models an already-detached route whose reader has
    /// not yet emitted `ioStopped`.
    func installRouteIOQuiescenceTestHarness(
        _ operation:
            @escaping @MainActor @Sendable () async -> Void
    ) {
        precondition(state == .idle)
        precondition(routeIOQuiescenceTask == nil)
        routeIOQuiescenceGeneration &+= 1
        routeIOQuiescenceTask = Task { @MainActor in
            await operation()
        }
        state = .ready
    }

    /// Models a committed route rebuild for the transport race harness. The
    /// latest outer intent is applied to the successor generation before a
    /// delayed predecessor seek is allowed to finish.
    func replaceTransportRaceTestRoute(
        with route: any AetherPlaybackTransportRoute
    ) throws {
        precondition(transportTestRoute != nil)
        cancelTransportMonitoring()
        transportRouteGeneration &+= 1
        transportTestRoute = route
        try applyTransportIntent(
            sequence: transportCommandSequence,
            expectedRouteGeneration: transportRouteGeneration
        )
    }

    /// Package-test harness for the outer watchdog boundary. It installs the
    /// same route/execution identity and fixed AVPlayer clock observed in
    /// production without constructing a second player implementation.
    /// Recovery still runs through `scheduleRuntimeRecovery`, history and the
    /// typed terminal publisher.
    func installStartupWatchdogTestHarness(
        target: AetherPlaybackStartupWatchdogTarget,
        holdRecoveryOwner: Bool = false,
        deferMonitoringUntilRecoveryHandoff: Bool = false
    ) {
        precondition(state == .idle)
        resolvedSource = startupWatchdogTestHarnessSource()
        activeRoute = target.route
        activeNativeExecutionMode = switch target {
        case .directNative: .directAsset
        case .nativeAudioBridge: .aetherRemux
        case .hybrid: nil
        }
        didCompleteInitialPrepare = true
        desiredPlaying = true
        desiredRate = 1
        transportCommandSequence &+= 1
        transportRouteGeneration &+= 1
        let item = AVPlayerItem(
            asset: AVURLAsset(
                url: URL(
                    fileURLWithPath:
                        "/tmp/aether-startup-watchdog-test-missing"
                )
            )
        )
        avPlayer.replaceCurrentItem(with: item)
        state = .playing
        if holdRecoveryOwner {
            beginRecoveryEpisodeIfNeeded(
                transportStartupFailure(.startupNoProgress)
            )
            isPreparingOrRecovering = true
            recoveryTask = Task {}
        }
        let request = AetherPendingTransportMonitoringRequest(
            sequence: transportCommandSequence,
            generation: transportRouteGeneration
        )
        if deferMonitoringUntilRecoveryHandoff {
            pendingTransportMonitoringRequest = request
        } else {
            scheduleTransportMonitoring(
                sequence: request.sequence,
                generation: request.generation
            )
        }
    }

    func releaseStartupWatchdogTestRecoveryOwner() {
        recoveryTask?.cancel()
        recoveryTask = nil
        isPreparingOrRecovering = false
        completeRecoveryTransportHandoff()
    }

    public func seek(
        to target: CMTime
    ) async throws -> AetherPlaybackSeekResult {
        guard target.isValid,
              target.isNumeric,
              target.seconds.isFinite,
              target.seconds >= 0 else {
            throw AetherPlaybackSessionError.invalidState
        }
        guard !isStopped,
              terminalFailure == nil else {
            throw AetherPlaybackSessionError.invalidState
        }
        // Seek is a new user operation even though it preserves play/pause
        // and rate. Advance the command sequence so a pre-seek reassert or
        // watchdog can never act on the seeking route.
        _ = beginTransportCommand()
        resetRecoveryEpisode()
        let operationSequence = operationCoordinator.beginSeek()
        desiredSeekTarget = target
        let formattedTarget = String(format: "%.3f", target.seconds)
        EngineLog.emit(
            "[AetherPlaybackSession] seek operation=\(operationSequence) "
                + "session=\(sessionID.uuidString.prefix(8)) "
                + "target=\(formattedTarget)",
            category: .session
        )

        while isPreparingOrRecovering {
            guard operationCoordinator.isCurrentSeek(operationSequence) else {
                return .superseded
            }
            if let terminalFailure {
                throw AetherPlaybackSessionError.terminal(
                    terminalFailure.finalFailure
                )
            }
            guard !isStopped else { throw CancellationError() }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard operationCoordinator.isCurrentSeek(operationSequence) else {
            return .superseded
        }
        if lastAppliedSeekOperationSequence == operationSequence {
            desiredSeekTarget = nil
            return .applied
        }
        guard let transportRoute else {
            throw AetherPlaybackSessionError.noActiveRoute
        }
        let routeIdentity = transportRoute.transportIdentity

        state = .seeking
        activeSeekOperationSequence = operationSequence
        do {
            let seekAttempt = max(
                1,
                transportLivenessAttempt + 1
            )
            let result = try await transportRoute.seek(
                to: target,
                timeout: recoveryBudget.livenessPolicy
                    .noProgressWindowSeconds(
                        forAttempt: seekAttempt
                    )
            )
            if activeSeekOperationSequence == operationSequence {
                activeSeekOperationSequence = nil
            }
            guard operationCoordinator.isCurrentSeek(operationSequence) else {
                return .superseded
            }
            guard result == .applied else {
                return .superseded
            }
            guard self.transportRoute?.transportIdentity
                    == routeIdentity else {
                throw CancellationError()
            }
            // The route owns seek mechanics; the stable outer session owns
            // the newest transport command. A late seek completion may only
            // apply that still-current command to the still-current route.
            try applyTransportIntent(
                sequence: transportCommandSequence,
                expectedRouteGeneration: transportRouteGeneration
            )
            lastConfirmedMediaTime = target
            lastAppliedSeekOperationSequence = operationSequence
            desiredSeekTarget = nil
            return .applied
        } catch is CancellationError {
            if activeSeekOperationSequence == operationSequence {
                activeSeekOperationSequence = nil
            }
            guard operationCoordinator.isCurrentSeek(operationSequence) else {
                return .superseded
            }
            throw CancellationError()
        } catch {
            if activeSeekOperationSequence == operationSequence {
                activeSeekOperationSequence = nil
            }
            guard operationCoordinator.isCurrentSeek(operationSequence) else {
                return .superseded
            }
            let seekFailure = if let evidence =
                    activeSession?.nativeFailureEvidence,
                !Self.isNativeSeekTimeout(error) {
                Self.nativeFailure(
                    stage: .playback,
                    evidence: evidence
                )
            } else {
                failure(stage: .playback, error: error)
            }
            try await recoverOrTerminate(
                from: seekFailure,
                duringInitialPrepare: false,
                failureStage: .playback,
                exhaustionReason: "seek recovery exhausted"
            )
            guard operationCoordinator.isCurrentSeek(operationSequence) else {
                return .superseded
            }
            lastAppliedSeekOperationSequence = operationSequence
            desiredSeekTarget = nil
            return .applied
        }
    }

    /// Actively polls the current Aether-owned output surface until a newer
    /// real frame is observed. The call returns immediately for a positively
    /// observed audio-only item and returns the latest fail-closed snapshot at
    /// the bounded deadline.
    ///
    /// This method never treats media-clock movement, `readyToPlay`, route
    /// state, or a renderer enqueue as frame evidence.
    public func waitForVideoFrame(
        after sequence: UInt64,
        timeout: TimeInterval
    ) async -> AetherVideoOutputSnapshot {
        guard timeout.isFinite, timeout >= 0,
              !isStopped else { return videoOutputSnapshot }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !Task.isCancelled, !isStopped {
            activeSession?.pollVideoOutput()
            let snapshot = videoOutputSnapshot
            if snapshot.outputStatus == .notExpected {
                return snapshot
            }
            if snapshot.outputStatus == .presented,
               snapshot.frameSequence > sequence {
                return snapshot
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                return videoOutputSnapshot
            }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return videoOutputSnapshot
            }
        }
        return videoOutputSnapshot
    }

    public func setExternalMetadata(
        _ metadata: [AVMetadataItem]
    ) {
        externalMetadata = metadata
        #if os(tvOS) || os(iOS)
        currentItem?.externalMetadata = metadata
        #endif
    }

    /// Truthful public state after the route has applied a seek and the outer
    /// session has reasserted its transport intent. A positive desired rate is
    /// not enough by itself: AVPlayer must expose an active/waiting transport
    /// or a positive real rate before `.playing` is published.
    nonisolated static func stateAfterAppliedSeek(
        desiredPlaying: Bool,
        desiredRate: Float,
        carrierRate: Float,
        carrierTimeControlStatus:
            AVPlayer.TimeControlStatus
    ) -> AetherPlaybackSessionState {
        guard desiredPlaying,
              desiredRate.isFinite,
              desiredRate > 0 else {
            return .paused
        }
        let carrierHasPlaybackIntent =
            (carrierRate.isFinite && carrierRate > 0)
                || carrierTimeControlStatus != .paused
        return carrierHasPlaybackIntent ? .playing : .paused
    }

    nonisolated static func timeControlStatus(
        _ status: AVPlayer.TimeControlStatus
    ) -> AetherPlaybackTimeControlStatus {
        switch status {
        case .paused: .paused
        case .waitingToPlayAtSpecifiedRate: .waitingToPlay
        case .playing: .playing
        @unknown default: .unknown
        }
    }

    nonisolated static func waitingReason(
        _ reason: AVPlayer.WaitingReason?
    ) -> AetherPlaybackWaitingReason {
        guard let reason else { return .none }
        if reason == .evaluatingBufferingRate {
            return .evaluatingBufferingRate
        }
        if reason == .noItemToPlay {
            return .noItemToPlay
        }
        if reason == .toMinimizeStalls {
            return .minimizingStalls
        }
        return .other
    }

    nonisolated static func itemStatus(
        _ item: AVPlayerItem?
    ) -> AetherPlaybackItemStatus {
        guard let item else { return .absent }
        switch item.status {
        case .unknown: return .unknown
        case .readyToPlay: return .readyToPlay
        case .failed: return .failed
        @unknown default: return .unknown
        }
    }

    private func transportApplicationPhase(
        item: AVPlayerItem?
    ) -> AetherPlaybackTransportApplicationPhase {
        if isStopped { return .stopped }
        if terminalFailure != nil { return .failed }
        if state == .ended { return .ended }
        if isPreparingOrRecovering {
            return didCompleteInitialPrepare ? .recovering : .preparing
        }
        if transportIsApplying { return .applying }
        guard desiredPlaying, desiredRate > 0 else {
            return switch state {
            case .idle: .idle
            case .preparing: .preparing
            case .ready: .ready
            case .recovering: .recovering
            case .ended: .ended
            case .failed: .failed
            case .stopped: .stopped
            case .playing, .paused, .seeking: .paused
            }
        }
        if transportRoute?
            .transportApplicationIsTemporarilyUnavailable == true {
            return .waiting
        }
        switch avPlayer.timeControlStatus {
        case .playing:
            return .playing
        case .waitingToPlayAtSpecifiedRate:
            return .waiting
        case .paused:
            if avPlayer.rate > 0 { return .playing }
            return item?.status == .readyToPlay
                ? .parkedPaused : .applying
        @unknown default:
            return .applying
        }
    }

    /// Recovery capability differences are meaningful only after the outer
    /// session has published a committed route. Initial preparation can have
    /// an installed, partially prepared route while the public capability
    /// value is still the route-neutral default; that value is not a baseline.
    nonisolated static func committedRecoveryCapabilityBaseline(
        didCompleteInitialPrepare: Bool,
        activeRoute: PlaybackRenderRoute?,
        fromRoute: PlaybackRenderRoute?,
        capabilities: AetherPlaybackCapabilities
    ) -> AetherPlaybackCapabilities? {
        guard didCompleteInitialPrepare,
              let activeRoute,
              activeRoute == fromRoute,
              capabilities.route == activeRoute else {
            return nil
        }
        return capabilities
    }

    /// Once a route is committed, a fresh source result cannot reinterpret the
    /// same request as another player route. Classification must finish before
    /// admission; route drift is a typed terminal invariant failure.
    nonisolated static func freshRouteReclassificationFailure(
        previousResult _: PlaybackPreflightResult?,
        from failedRoute: PlaybackRenderRoute,
        freshResult: PlaybackPreflightResult
    ) -> AetherPlaybackFailure? {
        let freshRoute = freshResult.route
        guard freshRoute != .unsupported,
              freshRoute != failedRoute else { return nil }

        return AetherPlaybackFailure(
            stage: .preflight,
            kind: .invariantViolation,
            domain: "AetherPlaybackRoutePolicy",
            code: 0,
            caseCode: "routeIdentityChanged",
            reason:
                "fresh source facts diverged from committed codec or route identity"
        )
    }

    /// Once a progressive probe has established media identity, every fresh
    /// recovery probe must describe that same media. This check runs before
    /// route admission so a same-route codec/container/duration drift cannot
    /// be hidden by rebuilding a new implementation.
    nonisolated static func freshProgressiveSourceIdentityFailure(
        previousFacts: AetherProgressiveSourceFacts?,
        freshFacts: AetherProgressiveSourceFacts?
    ) -> AetherPlaybackFailure? {
        guard let previousFacts else { return nil }
        guard let freshFacts,
              previousFacts.hasSameMediaIdentity(as: freshFacts) else {
            return AetherPlaybackFailure(
                stage: .preflight,
                kind: .invariantViolation,
                domain: "AetherPlaybackSourceIdentity",
                code: 0,
                reason: "fresh progressive facts diverged from committed source identity"
            )
        }
        return nil
    }

    /// Media metadata can remain unchanged while the bytes behind the request
    /// change. Every same-session replacement must therefore prove that both
    /// generations are validator-bound and exactly equal. Content length alone
    /// is not source identity, even when both generations report the same
    /// value.
    nonisolated static func freshProgressiveSourceGenerationFailure(
        previousGeneration: SourceByteStoreGeneration?,
        freshGeneration: SourceByteStoreGeneration?
    ) -> AetherPlaybackFailure? {
        guard let previousGeneration else { return nil }
        guard previousGeneration.validator != nil,
              let freshGeneration,
              freshGeneration.validator != nil else {
            return AetherPlaybackFailure(
                stage: .preflight,
                kind: .invariantViolation,
                domain: "AetherPlaybackSourceIdentity",
                code: 0,
                caseCode: "progressiveSourceGenerationUnverifiable",
                reason:
                    "same-source progressive recovery requires validator-bound generations"
            )
        }
        guard freshGeneration == previousGeneration else {
            return AetherPlaybackFailure(
                stage: .preflight,
                kind: .invariantViolation,
                domain: "AetherPlaybackSourceIdentity",
                code: 0,
                caseCode: "progressiveSourceGenerationChanged",
                reason:
                    "fresh progressive bytes diverged from the pinned source generation"
            )
        }
        return nil
    }

    /// A software decoder transition is a new Hybrid implementation build,
    /// so it must come from a freshly resolved, unconsumed source owner while
    /// remaining byte/graph-identical to the committed HEVC request.
    nonisolated static func freshSoftwareRecoverySourceIdentityFailure(
        previousResult: PlaybackPreflightResult?,
        previousProgressiveFacts: AetherProgressiveSourceFacts?,
        previousHLSResourceIdentity: String?,
        freshResult: PlaybackPreflightResult,
        freshProgressiveFacts: AetherProgressiveSourceFacts?,
        freshHLSResourceIdentity: String?
    ) -> AetherPlaybackFailure? {
        let sameProgressiveIdentity: Bool
        if let previousProgressiveFacts {
            sameProgressiveIdentity = freshProgressiveFacts.map {
                previousProgressiveFacts.hasSameMediaIdentity(as: $0)
            } ?? false
        } else {
            sameProgressiveIdentity = freshProgressiveFacts == nil
        }
        let sameHLSIdentity: Bool
        if let previousHLSResourceIdentity {
            sameHLSIdentity =
                freshHLSResourceIdentity == previousHLSResourceIdentity
        } else {
            sameHLSIdentity = freshHLSResourceIdentity == nil
        }
        let identityShapeMatches = switch previousResult?
            .sourceProfile.sourceKind {
        case .progressive:
            previousProgressiveFacts != nil
                && freshProgressiveFacts != nil
                && previousHLSResourceIdentity == nil
                && freshHLSResourceIdentity == nil
        case .hls:
            previousProgressiveFacts == nil
                && freshProgressiveFacts == nil
                && previousHLSResourceIdentity != nil
                && freshHLSResourceIdentity != nil
        case .custom, .unclassifiedURL, nil:
            false
        }
        guard let previousResult,
              previousResult.route == .hybridCarrier,
              previousResult.sourceProfile.videoCodec == .hevc,
              freshResult == previousResult,
              identityShapeMatches,
              sameProgressiveIdentity,
              sameHLSIdentity else {
            return AetherPlaybackFailure(
                stage: .preflight,
                kind: .invariantViolation,
                domain: "AetherPlaybackSourceIdentity",
                code: 0,
                reason: "fresh software recovery source diverged from committed HEVC identity"
            )
        }
        return nil
    }

    public func setSystemPlaybackActivity(
        _ activity: AetherSystemPlaybackActivity
    ) {
        systemActivity = activity
    }

    #if os(tvOS)
    public func configurePlayerViewController(
        _ controller: AVPlayerViewController,
        realVideoGravity: AetherHybridVideoGravity = .resizeAspect
    ) throws {
        guard !isStopped else {
            throw AetherPlaybackSessionError.invalidState
        }
        playerViewController = controller
        controller.player = avPlayer
        controller.appliesPreferredDisplayCriteriaAutomatically = true
        if let activeSession {
            try configure(
                activeSession,
                controller: controller,
                realVideoGravity: realVideoGravity
            )
        }
    }
    #endif

    public func audioAnalysisAvailability(
        for trackID: Int
    ) -> AudioAnalysisTrackAvailability {
        activeSession?.audioAnalysisAvailability(for: trackID)
            ?? .unavailable(.noActiveSession)
    }

    public func audioAnalysisStream(
        request: AudioAnalysisRequest
    ) throws -> AudioAnalysisStream {
        guard !isStopped,
              terminalFailure == nil else {
            throw AudioAnalysisError.noActiveSession
        }
        let proxy = AetherPlaybackAudioAnalysisProxy(
            request: request
        )
        audioAnalysisProxies[proxy.id] = proxy
        proxy.task = Task { @MainActor [weak self, weak proxy] in
            guard let self, let proxy else { return }
            await self.runAudioAnalysisProxy(proxy)
        }
        let proxyID = proxy.id
        return AudioAnalysisStream(
            gate: proxy.gate,
            cancel: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.cancelAudioAnalysisProxy(proxyID)
                }
            }
        )
    }

    public func cancelAudioAnalysisStreams() {
        let ids = Array(audioAnalysisProxies.keys)
        ids.forEach(cancelAudioAnalysisProxy)
        activeSession?.cancelAudioAnalysisStreams()
    }

    public func selectAudioTrack(_ id: String) async throws {
        guard !isStopped,
              terminalFailure == nil,
              audioTracks.contains(where: { $0.id == id }) else {
            throw AetherPlaybackTrackSelectionError.unknownTrack(id)
        }
        desiredAudioTrackID = id
        while isPreparingOrRecovering {
            guard !isStopped else { throw CancellationError() }
            if let terminalFailure {
                throw AetherPlaybackSessionError.terminal(
                    terminalFailure.finalFailure
                )
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard let activeSession else {
            throw AetherPlaybackSessionError.noActiveRoute
        }
        do {
            try await activeSession.selectAudioTrack(id)
            guard let current = self.activeSession,
                  current.isIdentical(to: activeSession) else {
                throw CancellationError()
            }
            publishTrackState(from: activeSession)
            publishCapabilities()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let selectionFailure = failure(
                stage: .playback,
                error: error
            )
            try await recoverOrTerminate(
                from: selectionFailure,
                duringInitialPrepare: false,
                failureStage: .playback,
                exhaustionReason:
                    "selected audio track could not be restored"
            )
            return
        }
    }

    public func selectSubtitleTrack(_ id: String?) async throws {
        guard !isStopped,
              terminalFailure == nil else {
            throw AetherPlaybackSessionError.invalidState
        }
        if let id,
           !subtitleTracks.contains(where: { $0.id == id }) {
            throw AetherPlaybackTrackSelectionError.unknownTrack(id)
        }
        desiredSubtitleTrackID = id
        desiredOverlaySubtitleTrackID = id.flatMap { selectedID in
            subtitleTracks.first(where: {
                $0.id == selectedID
                    && $0.id.hasPrefix("subtitle-source:")
            })?.sourceTrackID
        }
        while isPreparingOrRecovering {
            guard !isStopped else { throw CancellationError() }
            if let terminalFailure {
                throw AetherPlaybackSessionError.terminal(
                    terminalFailure.finalFailure
                )
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard let activeSession else {
            throw AetherPlaybackSessionError.noActiveRoute
        }
        try await activeSession.selectSubtitleTrack(id)
        guard let current = self.activeSession,
              current.isIdentical(to: activeSession) else {
            throw CancellationError()
        }
        publishTrackState(from: activeSession)
        publishCapabilities()
    }

    private func applyCanonicalDefaultTrackIntent() async throws {
        guard desiredSubtitleTrackID == nil,
              !options.externalSubtitles.isEmpty,
              let activeSession else {
            return
        }
        publishTrackState(from: activeSession)
        guard let externalTrack = subtitleTracks.first(where: {
            $0.isExternal && $0.isDefault
        }) ?? subtitleTracks.first(where: \.isExternal) else {
            EngineLog.emit(
                "[AetherPlaybackSession] canonical external subtitle "
                    + "unavailable session=\(sessionID.uuidString.prefix(8)) "
                    + "route=\(activeSession.route.rawValue)",
                category: .session
            )
            return
        }
        guard let routeTransaction = routeTransactions.activeSequence else {
            return
        }
        do {
            let deadline = try operationDeadline(stage: .preparation)
            try await AetherPlaybackOperationDeadlineRace<Void>().run(
                timeout: deadline.timeout,
                timeoutFailure: deadline.failure
            ) {
                try await activeSession.selectSubtitleTrack(
                    externalTrack.id
                )
            }
            try requireCurrentRouteTransaction(routeTransaction)
            guard let current = self.activeSession,
                  current.isIdentical(to: activeSession) else {
                throw CancellationError()
            }
            desiredSubtitleTrackID = externalTrack.id
            desiredOverlaySubtitleTrackID = externalTrack.sourceTrackID
            publishTrackState(from: activeSession)
            publishCapabilities()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // External subtitles are a declared degradable capability. Keep
            // playback alive and publish their unselected state.
            desiredSubtitleTrackID = nil
            desiredOverlaySubtitleTrackID = nil
            publishTrackState(from: activeSession)
            publishCapabilities()
            EngineLog.emit(
                "[AetherPlaybackSession] canonical external subtitle "
                    + "selection unavailable session=\(sessionID.uuidString.prefix(8)) "
                    + "code=externalSubtitleSelectionUnavailable",
                category: .session
            )
        }
    }

    private func runAudioAnalysisProxy(
        _ proxy: AetherPlaybackAudioAnalysisProxy
    ) async {
        defer {
            audioAnalysisProxies.removeValue(forKey: proxy.id)
        }
        while !Task.isCancelled, !isStopped {
            while isPreparingOrRecovering {
                guard !Task.isCancelled, !isStopped else {
                    await proxy.gate.cancel()
                    return
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            guard let activeSession else {
                await proxy.gate.fail(.noActiveSession)
                return
            }
            let request: AudioAnalysisRequest
            do {
                let lowerBound = proxy.lastConfirmedSamplePosition.map {
                    Double($0) / 48_000
                } ?? proxy.originalRequest.range.lowerBound
                guard lowerBound
                        < proxy.originalRequest.range.upperBound else {
                    await proxy.gate.finish()
                    return
                }
                request = try AudioAnalysisRequest(
                    audioTrackID:
                        proxy.originalRequest.audioTrackID,
                    range: lowerBound
                        ..< proxy.originalRequest.range.upperBound
                )
            } catch let error as AudioAnalysisError {
                await proxy.gate.fail(error)
                return
            } catch {
                await proxy.gate.fail(.invalidRange)
                return
            }

            switch activeSession.audioAnalysisAvailability(
                for: request.audioTrackID
            ) {
            case .available:
                break
            case .unavailable(let error):
                publishCapabilities()
                await proxy.gate.fail(error)
                return
            }

            do {
                let stream = try activeSession.audioAnalysisStream(
                    request: request
                )
                var iterator = stream.makeAsyncIterator()
                while !Task.isCancelled {
                    try await proxy.gate.waitForDemand()
                    guard let buffer = try await iterator.next() else {
                        await proxy.gate.finish()
                        return
                    }
                    let delivered: AudioAnalysisBuffer
                    if proxy.shouldMarkDiscontinuity {
                        delivered = AudioAnalysisBuffer(
                            pcm: buffer.pcm,
                            sourceSamplePosition:
                                buffer.sourceSamplePosition,
                            isDiscontinuous: true
                        )
                        proxy.shouldMarkDiscontinuity = false
                        EngineLog.emit(
                            "[AetherPlaybackSession] analysis discontinuity "
                                + "session=\(sessionID.uuidString.prefix(8)) "
                                + "analysis=\(proxy.id.uuidString.prefix(8))",
                            category: .session
                        )
                    } else {
                        delivered = buffer
                    }
                    let didDeliver = await proxy.gate.yield(delivered)
                    guard didDeliver else { return }
                    proxy.lastConfirmedSamplePosition =
                        delivered.sourceSamplePosition
                        + Int64(delivered.pcm.frameLength)
                }
            } catch let error as AudioAnalysisError {
                if error == .cancelled {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    if isPreparingOrRecovering {
                        proxy.shouldMarkDiscontinuity = true
                        continue
                    }
                }
                await proxy.gate.fail(error)
                return
            } catch is CancellationError {
                await proxy.gate.cancel()
                return
            } catch {
                await proxy.gate.fail(
                    .analysisFailed(
                        "route analysis failed at \(String(reflecting: type(of: error)))"
                    )
                )
                return
            }
        }
        await proxy.gate.cancel()
    }

    private func cancelAudioAnalysisProxy(_ id: UUID) {
        guard let proxy = audioAnalysisProxies.removeValue(
            forKey: id
        ) else { return }
        proxy.task?.cancel()
        proxy.task = nil
        Task { await proxy.gate.cancel() }
    }

    public func stop() {
        _ = beginShutdown()
    }

    private func beginShutdown() -> Task<Void, Never> {
        if let shutdownTask {
            return shutdownTask
        }
        if isStopped {
            return Task {}
        }

        isStopped = true
        shutdownGeneration &+= 1
        let generation = shutdownGeneration
        activeProgressivePreflight?.requestCancellation()
        activeProgressivePreflight = nil
        progressiveLivenessObservationTask?.cancel()
        progressiveLivenessObservationTask = nil
        livenessDiagnosticTask?.cancel()
        livenessDiagnosticTask = nil
        publishLiveness(
            phase: .cancelling,
            attempt: livenessSnapshot.attempt,
            uniqueBytesFetched:
                livenessSnapshot.uniqueBytesFetched,
            lastMeaningfulProgressUptimeSeconds:
                livenessSnapshot
                    .lastMeaningfulProgressUptimeSeconds,
            nextRetryUptimeSeconds: nil
        )
        cancelTransportMonitoring()
        transportRouteGeneration &+= 1
        routeTransactions.invalidate()
        let recoveryTaskToAwait = recoveryTask
        recoveryTaskToAwait?.cancel()
        recoveryTask = nil
        routeCancellables.removeAll()
        teardownActiveRoute()
        let resolvedSourceToDiscard = resolvedSource
        resolvedSource = nil
        transportTestRoute = nil
        restoreRouteNeutralPlayerCapabilities()
        invalidateVideoOutputRoute()
        activeNativeExecutionMode = nil
        presentationView.install(nil)
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        currentItemObservation?.invalidate()
        currentItemObservation = nil
        transportTimeControlObservation?.invalidate()
        transportTimeControlObservation = nil
        if let healthyProgressObserver {
            avPlayer.removeTimeObserver(healthyProgressObserver)
            self.healthyProgressObserver = nil
        }
        activeRoute = nil
        overlaySubtitleTracks = []
        activeOverlaySubtitleTrackID = nil
        audioTracks = []
        subtitleTracks = []
        selectedAudioTrackID = nil
        selectedSubtitleTrackID = nil
        capabilities = Self.capabilities(for: nil, source: nil)
        #if os(tvOS)
        if playerViewController?.player === avPlayer {
            playerViewController?.player = nil
        }
        playerViewController = nil
        #endif

        let shutdownQuiescenceFence =
            AetherCancellationQuiescenceFence()
        let shutdownWatchdog = Task.detached {
            do {
                try await Task.sleep(
                    nanoseconds: 2_000_000_000
                )
            } catch {
                return
            }
            guard shutdownQuiescenceFence.isPending else {
                return
            }
            EngineLog.emit(
                "[AetherPlaybackSession] cancellationUnresponsive "
                    + "scope=shutdown generation=\(generation) "
                    + "readerOverlap=forbidden",
                category: .session
            )
        }
        let task = Task { @MainActor [weak self] in
            guard let self else {
                await resolvedSourceToDiscard?
                    .discardUnconsumedPreparedSourceAndWaitForIOQuiescence()
                shutdownQuiescenceFence.markQuiesced()
                shutdownWatchdog.cancel()
                return
            }
            await self.waitForIOOwnershipOperationsToQuiesce()
            await recoveryTaskToAwait?.value
            await self.teardownActiveRouteAndWaitForIOQuiescence()
            await resolvedSourceToDiscard?
                .discardUnconsumedPreparedSourceAndWaitForIOQuiescence()
            shutdownQuiescenceFence.markQuiesced()
            shutdownWatchdog.cancel()
            self.publishLiveness(
                phase: .cancelled,
                attempt: self.livenessSnapshot.attempt,
                uniqueBytesFetched:
                    self.livenessSnapshot.uniqueBytesFetched,
                lastMeaningfulProgressUptimeSeconds:
                    self.livenessSnapshot
                        .lastMeaningfulProgressUptimeSeconds,
                nextRetryUptimeSeconds: nil
            )
            self.state = .stopped
            self.shutdownTask = nil
        }
        shutdownTask = task
        return task
    }

    private func stopAndWaitForIOQuiescence() async {
        let task = beginShutdown()
        await task.value
    }

    /// Test-visible release fence for the externally synchronous `stop()`.
    func waitForStopIOQuiescence() async {
        await shutdownTask?.value
    }

    func beginLivenessObservation(
        phase: AetherPlaybackLivenessPhase
    ) {
        progressLogCadence.reset(
            now: ProcessInfo.processInfo.systemUptime
        )
        routePreparationRetryProjection.reset()
        livenessGeneration &+= 1
        transportLivenessAttempt = 0
        publishLiveness(
            phase: phase,
            attempt: 0,
            uniqueBytesFetched: 0,
            lastMeaningfulProgressUptimeSeconds: nil,
            nextRetryUptimeSeconds: nil
        )
        livenessDiagnosticTask?.cancel()
        let scheduler = AetherLivenessDiagnosticScheduler(
            policy: recoveryBudget.livenessPolicy,
            clock: livenessDiagnosticClock
        )
        livenessDiagnosticTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await scheduler.run(
                while: {
                    !self.isStopped
                        && self.terminalFailure == nil
                },
                onCheckpoint: { elapsed in
                    self.logLivenessCheckpoint(
                        elapsedSeconds: elapsed
                    )
                    self.livenessDiagnosticCheckpointObserver?(
                        elapsed
                    )
                }
            )
        }
    }

    private func publishLiveness(
        phase: AetherPlaybackLivenessPhase,
        attempt: Int,
        uniqueBytesFetched: Int64,
        lastMeaningfulProgressUptimeSeconds:
            TimeInterval?,
        nextRetryUptimeSeconds: TimeInterval?
    ) {
        livenessSnapshot = AetherPlaybackLivenessSnapshot(
            phase: phase,
            generation: livenessGeneration,
            attempt: attempt,
            uniqueBytesFetched: uniqueBytesFetched,
            lastMeaningfulProgressUptimeSeconds:
                lastMeaningfulProgressUptimeSeconds,
            nextRetryUptimeSeconds:
                nextRetryUptimeSeconds
        )
    }

    private func logLivenessCheckpoint(
        elapsedSeconds: TimeInterval
    ) {
        let snapshot = livenessSnapshot
        let lastProgressAge: TimeInterval
        if let last = snapshot
            .lastMeaningfulProgressUptimeSeconds {
            lastProgressAge = max(
                0,
                ProcessInfo.processInfo.systemUptime - last
            )
        } else {
            lastProgressAge = elapsedSeconds
        }
        EngineLog.emit(
            "[AetherPlaybackSession] liveness checkpoint "
                + "session=\(sessionID.uuidString.prefix(8)) "
                + "generation=\(snapshot.generation) "
                + "elapsed=\(Int(elapsedSeconds)) "
                + "phase=\(snapshot.phase.rawValue) "
                + "attempt=\(snapshot.attempt) "
                + "bytes=\(snapshot.uniqueBytesFetched) "
                + "lastProgressAge=\(Int(lastProgressAge))",
            category: .session
        )
    }

    @discardableResult
    private func emitBoundedProgressLog(
        _ sample: AetherPlaybackProgressLogSample
    ) -> Bool {
        let decision = progressLogCadence.record(sample)
        if let emission = decision.emission {
            EngineLog.emit(
                "[AetherPlaybackSession] progress "
                    + "session=\(sessionID.uuidString.prefix(8)) "
                    + emission.logFields,
                category: .session
            )
        }
        return decision.acceptedProgress
    }

    private func observeProgressivePreflightEvents(
        _ events: AsyncStream<AetherProgressivePreflightEvent>
    ) {
        progressiveLivenessObservationTask?.cancel()
        progressivePreflightEpoch &+= 1
        let preflightEpoch = progressivePreflightEpoch
        livenessGeneration &+= 1
        progressiveLivenessObservationTask = Task {
            @MainActor [weak self] in
            guard let self else { return }
            for await event in events {
                guard !Task.isCancelled,
                      !self.isStopped,
                      self.progressivePreflightEpoch
                        == preflightEpoch else {
                    return
                }
                if case .attemptStarted(let attempt, _) = event {
                    self.publishLiveness(
                        phase: .preflighting,
                        attempt: attempt,
                        uniqueBytesFetched:
                            self.livenessSnapshot
                                .uniqueBytesFetched,
                        lastMeaningfulProgressUptimeSeconds:
                            self.livenessSnapshot
                                .lastMeaningfulProgressUptimeSeconds,
                        nextRetryUptimeSeconds: nil
                    )
                }
                if case .byteProgress(_, let snapshot) = event {
                    self.applyProgressiveLivenessSnapshot(
                        snapshot
                    )
                }
                if case .probeMilestone(
                    let attempt,
                    let ordinal,
                    let snapshot
                ) = event {
                    self.applyProgressiveProbeMilestone(
                        preflightEpoch: preflightEpoch,
                        attempt: attempt,
                        ordinal: ordinal,
                        snapshot: snapshot
                    )
                }
                if case .prepared(_, let snapshot) = event {
                    self.applyProgressiveLivenessSnapshot(
                        snapshot
                    )
                }
                if case .retryScheduled(
                    _,
                    let nextAttempt,
                    let backoff,
                    _
                ) = event {
                    self.publishLiveness(
                        phase: .retryScheduled,
                        attempt: nextAttempt,
                        uniqueBytesFetched:
                            self.livenessSnapshot
                                .uniqueBytesFetched,
                        lastMeaningfulProgressUptimeSeconds:
                            self.livenessSnapshot
                                .lastMeaningfulProgressUptimeSeconds,
                        nextRetryUptimeSeconds:
                            ProcessInfo.processInfo.systemUptime
                            + backoff
                    )
                }
                if case .cancellationRequested = event {
                    self.publishLiveness(
                        phase: .cancelling,
                        attempt:
                            self.livenessSnapshot.attempt,
                        uniqueBytesFetched:
                            self.livenessSnapshot
                                .uniqueBytesFetched,
                        lastMeaningfulProgressUptimeSeconds:
                            self.livenessSnapshot
                                .lastMeaningfulProgressUptimeSeconds,
                        nextRetryUptimeSeconds: nil
                    )
                }
                if case .cancelled = event {
                    self.publishLiveness(
                        phase: .cancelled,
                        attempt:
                            self.livenessSnapshot.attempt,
                        uniqueBytesFetched:
                            self.livenessSnapshot
                                .uniqueBytesFetched,
                        lastMeaningfulProgressUptimeSeconds:
                            self.livenessSnapshot
                                .lastMeaningfulProgressUptimeSeconds,
                        nextRetryUptimeSeconds: nil
                    )
                }
            }
        }
    }

    private func observeProgressiveLiveness(
        _ liveness: AetherProgressivePreflightLiveness?
    ) {
        progressiveLivenessObservationTask?.cancel()
        guard let liveness else {
            progressiveLivenessObservationTask = nil
            return
        }
        progressiveLivenessObservationTask = Task {
            @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !self.isStopped {
                self.applyProgressiveLivenessSnapshot(
                    liveness.snapshot
                )
                do {
                    try await Task.sleep(
                        nanoseconds: 250_000_000
                    )
                } catch {
                    return
                }
            }
        }
    }

    private func applyProgressiveLivenessSnapshot(
        _ snapshot:
            AetherProgressivePreflightLivenessSnapshot
    ) {
        guard livenessSnapshot.phase != .cancelling,
              livenessSnapshot.phase != .cancelled else {
            return
        }
        let ledgerSnapshot =
            progressiveFetchedByteProgressLedger.snapshot
        let combinedBytes = max(
            livenessSnapshot.uniqueBytesFetched,
            ledgerSnapshot.totalAdvancedBytes
        )
        let didAdvance =
            combinedBytes > livenessSnapshot.uniqueBytesFetched
        if didAdvance {
            transportLivenessAttempt = 0
            transportRetryBudget.reset()
            recoveryLogCadence.resetAfterProgress()
        }
        let sourcePhase: AetherPlaybackLivenessPhase = switch snapshot.state {
        case .idle: .waitingForSource
        case .probing: .preflighting
        case .backingOff: .retryScheduled
        case .prepared:
            desiredPlaying ? .buffering : .preparingRoute
        case .cancelled: .cancelled
        case .failed: .preflighting
        }
        let phase =
            routePreparationRetryProjection.phase
                ?? sourcePhase
        let attempt =
            routePreparationRetryProjection.attempt
                ?? snapshot.attempt
                ?? livenessSnapshot.attempt
        if didAdvance {
            let observedUptime =
                ProcessInfo.processInfo.systemUptime
            emitBoundedProgressLog(
                .sourceBytes(
                    phase: phase,
                    generation: livenessGeneration,
                    attempt: attempt,
                    uniqueBytes: combinedBytes,
                    progressUptime:
                        snapshot.lastProgressUptime
                        ?? observedUptime,
                    observedUptime: observedUptime
                )
            )
        }
        publishLiveness(
            phase: phase,
            attempt: attempt,
            uniqueBytesFetched: combinedBytes,
            lastMeaningfulProgressUptimeSeconds:
                didAdvance
                    ? (snapshot.lastProgressUptime
                        ?? ProcessInfo.processInfo.systemUptime)
                    : livenessSnapshot
                        .lastMeaningfulProgressUptimeSeconds,
            nextRetryUptimeSeconds:
                routePreparationRetryProjection
                    .nextRetryUptimeSeconds
                    ?? (phase == .retryScheduled
                        ? livenessSnapshot
                            .nextRetryUptimeSeconds
                        : nil)
        )
    }

    private func applyProgressiveProbeMilestone(
        preflightEpoch: UInt64,
        attempt: Int,
        ordinal: UInt64,
        snapshot:
            AetherProgressivePreflightLivenessSnapshot
    ) {
        let observedUptime =
            ProcessInfo.processInfo.systemUptime
        let progressUptime =
            snapshot.lastProgressUptime
                ?? observedUptime
        transportLivenessAttempt = 0
        transportRetryBudget.reset()
        recoveryLogCadence.resetAfterProgress()
        emitBoundedProgressLog(
            .containerMilestone(
                phase: .preflighting,
                generation: livenessGeneration,
                attempt: attempt,
                preflightEpoch: preflightEpoch,
                ordinal: ordinal,
                progressUptime: progressUptime,
                observedUptime: observedUptime
            )
        )
        publishLiveness(
            phase: .preflighting,
            attempt: attempt,
            uniqueBytesFetched:
                livenessSnapshot.uniqueBytesFetched,
            lastMeaningfulProgressUptimeSeconds:
                progressUptime,
            nextRetryUptimeSeconds: nil
        )
    }

    private func resolveCanonicalSource()
        async throws -> AetherResolvedPlaybackSource
    {
        await waitForPendingRouteIOQuiescence()
        try Task.checkCancellation()
        guard !isStopped else {
            throw CancellationError()
        }
        let sourceSignature: AetherURLPlaybackSourceSignature
        classificationProgressFence.beginEpoch()
        let classificationLivenessGeneration =
            livenessGeneration
        do {
            sourceSignature = try await retryTransport(
                stage: .classification
            ) {
                let progressToken =
                    self.classificationProgressFence
                        .beginReader()
                let progressRelay =
                    AetherClassificationProgressRelay()
                defer {
                    self.recordVerifiedPrefixProgress(
                        progressToken: progressToken,
                        livenessGeneration:
                            classificationLivenessGeneration,
                        verifiedByteCount:
                            progressRelay.snapshot
                    )
                    self.classificationProgressFence
                        .retire(progressToken)
                }
                return try await AetherURLPlaybackSourceClassifier.inspect(
                    url: self.url,
                    options: self.options,
                    onVerifiedPrefixProgress: {
                        [weak self] verifiedByteCount in
                        progressRelay.record(verifiedByteCount)
                        Task { @MainActor [weak self] in
                            self?.recordVerifiedPrefixProgress(
                                progressToken:
                                    progressToken,
                                livenessGeneration:
                                    classificationLivenessGeneration,
                                verifiedByteCount:
                                    verifiedByteCount
                            )
                        }
                    }
                )
            }
        } catch {
            let failure = failure(stage: .classification, error: error)
            throw failure
        }

        switch sourceSignature.canonicalResolutionStep {
        case .inspectHLS:
            publishLiveness(
                phase: .preflighting,
                attempt: transportLivenessAttempt,
                uniqueBytesFetched:
                    livenessSnapshot.uniqueBytesFetched,
                lastMeaningfulProgressUptimeSeconds:
                    livenessSnapshot
                        .lastMeaningfulProgressUptimeSeconds,
                nextRetryUptimeSeconds: nil
            )
            do {
                let preflight = try await retryTransport(
                    stage: .preflight
                ) {
                    let operation = AetherPlaybackPreflightOperation()
                    return try await operation.inspectHLS(
                        url: self.url,
                        sourceIsSeekableVOD: true,
                        variantSelection: self.variantSelection,
                        hybridCapabilities:
                            AetherHybridPlaybackSession.capabilities,
                        options: self.options
                    )
                }
                return .hls(preflight)
            } catch {
                throw failure(stage: .preflight, error: error)
            }

        case .probeProgressive:
            publishLiveness(
                phase: .preflighting,
                attempt: transportLivenessAttempt,
                uniqueBytesFetched:
                    livenessSnapshot.uniqueBytesFetched,
                lastMeaningfulProgressUptimeSeconds:
                    livenessSnapshot
                        .lastMeaningfulProgressUptimeSeconds,
                nextRetryUptimeSeconds: nil
            )
            do {
                let preparedSource = try await retryTransport(
                    stage: .preflight
                ) {
                    let preflight = try AetherProgressivePreflight(
                        url: self.url,
                        options: self.options,
                        retryPolicy:
                            AetherProgressivePreflightRetryPolicy(
                                inactivitySeconds:
                                    self.recoveryBudget
                                        .livenessPolicy
                                        .noProgressWindowsSeconds,
                                backoffSeconds:
                                    self.recoveryBudget
                                        .livenessPolicy
                                        .retryBackoffSeconds
                            ),
                        fetchedByteProgressLedger:
                            self.progressiveFetchedByteProgressLedger
                    )
                    self.activeProgressivePreflight = preflight
                    self.observeProgressivePreflightEvents(
                        preflight.events
                    )
                    defer {
                        if self.activeProgressivePreflight
                            === preflight {
                            self.activeProgressivePreflight = nil
                        }
                    }
                    self.beginIOOwnershipOperation()
                    defer {
                        self.endIOOwnershipOperation()
                    }
                    let prepared = try await preflight.prepare()
                    self.observeProgressiveLiveness(
                        prepared.progressiveLiveness
                    )
                    return prepared
                }
                let probe = preparedSource.probe
                let profile = AetherSourceProfile(
                    probe: probe,
                    sourceKind: .progressive,
                    isSeekableVOD: probe.isFiniteSeekableVOD
                )
                let result = PlaybackPreflight.resolve(
                    sourceProfile: profile,
                    hlsPackaging: nil,
                    hybridCapabilities:
                        AetherHybridPlaybackSession.capabilities,
                    requiredAudioBridgeMode:
                        options.audioBridgeMode
                )
                let retainedPreparedSource:
                    AetherPreparedURLSource?
                if result.route == .hybridCarrier
                    || (result.route == .nativeAVPlayer
                        && result.reason == .nativeHLSFMP4Remux) {
                    retainedPreparedSource = preparedSource
                } else {
                    // Direct Native/unsupported admission would otherwise
                    // open a successor while the probe URLSession can still
                    // deliver late callbacks. Retire and fence the exact
                    // prepared reader before exposing the result.
                    await Task.detached(priority: .userInitiated) {
                        preparedSource
                            .discardAndWaitForIOQuiescence()
                    }.value
                    progressiveLivenessObservationTask?.cancel()
                    progressiveLivenessObservationTask = nil
                    retainedPreparedSource = nil
                }
                return .progressive(
                    probe: probe,
                    result: result,
                    preparedSource: retainedPreparedSource
                )
            } catch {
                throw failure(stage: .preflight, error: error)
            }
        }
    }

    private func recordVerifiedPrefixProgress(
        progressToken:
            AetherClassificationProgressToken,
        livenessGeneration expectedGeneration: UInt64,
        verifiedByteCount: Int
    ) {
        guard classificationProgressFence
                .admits(progressToken),
              expectedGeneration == livenessGeneration,
              !isStopped,
              terminalFailure == nil else {
            return
        }
        let progressUptime =
            ProcessInfo.processInfo.systemUptime
        guard let ledgerSnapshot =
                progressiveFetchedByteProgressLedger.record(
                    offset: 0,
                    count: verifiedByteCount,
                    kind: .origin
                ) else {
            return
        }
        guard emitBoundedProgressLog(
            .sourceBytes(
                phase: .classifying,
                generation: expectedGeneration,
                attempt: transportLivenessAttempt,
                uniqueBytes:
                    ledgerSnapshot.totalAdvancedBytes,
                progressUptime: progressUptime,
                observedUptime: progressUptime
            )
        ) else {
            return
        }
        transportLivenessAttempt = 0
        transportRetryBudget.reset()
        recoveryLogCadence.resetAfterProgress()
        publishLiveness(
            phase: .classifying,
            attempt: 0,
            uniqueBytesFetched:
                ledgerSnapshot.totalAdvancedBytes,
            lastMeaningfulProgressUptimeSeconds:
                progressUptime,
            nextRetryUptimeSeconds: nil
        )
    }

    private func startupWatchdogTestHarnessSource(
        sourceContainer: AetherSourceContainer = .unknown
    )
        -> AetherResolvedPlaybackSource
    {
        let profile = AetherSourceProfile(
            sourceKind: .unclassifiedURL,
            isSeekableVOD: true,
            videoStreamPresence: .unknown,
            videoCodec: .unknown,
            sourceContainer: sourceContainer,
            // The watchdog harness does not perform source admission.
            videoFormat: .sdr
        )
        return .startupWatchdogTestHarness(
            PlaybackPreflightResult(
                sourceProfile: profile,
                hlsPackaging: nil,
                route: .nativeAVPlayer,
                reason: .nativeHLSContractVerified
            )
        )
    }

    private func installAndPrepare(
        _ source: AetherResolvedPlaybackSource,
        decoderPreference: HybridVideoDecoderPreference = .automatic
    ) async throws {
        publishLiveness(
            phase: .preparingRoute,
            attempt: transportLivenessAttempt,
            uniqueBytesFetched:
                livenessSnapshot.uniqueBytesFetched,
            lastMeaningfulProgressUptimeSeconds:
                livenessSnapshot
                    .lastMeaningfulProgressUptimeSeconds,
            nextRetryUptimeSeconds: nil
        )
        // Route preparation may depend on the same slow canonical source.
        // A wall-clock race cannot distinguish slow progress from a dead
        // operation and therefore must not own the terminal outcome.
        try await installAndPrepareWithoutDeadline(
            source,
            decoderPreference: decoderPreference
        )
    }

    private func installAndPrepareWithoutDeadline(
        _ source: AetherResolvedPlaybackSource,
        decoderPreference: HybridVideoDecoderPreference
    ) async throws {
        await waitForPendingRouteIOQuiescence()
        try Task.checkCancellation()
        guard !isStopped else {
            throw CancellationError()
        }
        guard source.result.route != .unsupported else {
            throw AetherPlaybackSessionError.unsupported(
                source.result.reason
            )
        }
        // Retain the positively resolved same-source contract before route
        // construction so a bounded construction timeout can still rebuild
        // that exact admitted route without inventing another source.
        resolvedSource = source
        let transaction = routeTransactions.begin()
        let route: AetherActiveRouteSession
        beginIOOwnershipOperation()
        defer {
            endIOOwnershipOperation()
        }
        do {
            route = try await makeRouteSession(
                source,
                decoderPreference: decoderPreference,
                transaction: transaction
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw failure(stage: .routeCreation, error: error)
                .recordingRecoveryDiagnostic(step: .install)
        }
        do {
            try requireCurrentRouteTransaction(transaction)
            try install(
                route,
                source: source,
                transaction: transaction
            )
        } catch is CancellationError {
            await route.stopAndWaitForIOQuiescence()
            throw CancellationError()
        } catch {
            await route.stopAndWaitForIOQuiescence()
            throw failure(stage: .routeCreation, error: error)
                .recordingRecoveryDiagnostic(step: .install)
        }
        let routePreparationProgress =
            AetherRoutePreparationProgressLedger()
        let supervisesProgressiveHybridPreparation: Bool
        if case .progressive = source,
           route.route == .hybridCarrier {
            supervisesProgressiveHybridPreparation = true
        } else {
            supervisesProgressiveHybridPreparation = false
        }
        if supervisesProgressiveHybridPreparation {
            route.setRoutePreparationProgressHandler {
                [routePreparationProgress] kind in
                routePreparationProgress.record(kind)
            }
        }
        defer {
            route.setRoutePreparationProgressHandler(nil)
        }
        do {
            if supervisesProgressiveHybridPreparation {
                try await prepareRouteWithLiveness(
                    route,
                    progress:
                        routePreparationProgress
                )
            } else {
                try await route.prepare()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let evidence = route.nativeFailureEvidence {
                throw Self.nativeFailure(
                    stage: .preparation,
                    evidence: evidence
                ).recordingRecoveryDiagnostic(step: .prepare)
            }
            throw failure(stage: .preparation, error: error)
                .recordingRecoveryDiagnostic(step: .prepare)
        }
        do {
            try requireCurrentRouteTransaction(transaction)
            try await commit(
                route,
                source: source,
                transaction: transaction
            )
        } catch is CancellationError {
            await route.stopAndWaitForIOQuiescence()
            throw CancellationError()
        } catch {
            await route.stopAndWaitForIOQuiescence()
            throw failure(stage: .routeCreation, error: error)
                .recordingRecoveryDiagnostic(step: .install)
        }
        publishCurrentItem(avPlayer.currentItem)
    }

    private func prepareRouteWithLiveness(
        _ route: AetherActiveRouteSession,
        progress:
            AetherRoutePreparationProgressLedger
    ) async throws {
        let attempt = max(
            1,
            transportLivenessAttempt + 1
        )
        let supervisor =
            AetherRoutePreparationLivenessSupervisor(
                policy: recoveryBudget.livenessPolicy
            )
        let byteLedger =
            progressiveFetchedByteProgressLedger

        let race =
            AetherRoutePreparationLivenessRace()
        do {
            try await race.run(
                operation: {
                    try await route.prepare()
                },
                monitor: { @MainActor [weak self] in
                guard let self else {
                    throw CancellationError()
                }
                return try await supervisor
                    .waitForNoProgress(
                        attempt: attempt,
                        evidence: {
                            let semantic = progress.snapshot
                            return AetherRoutePreparationProgressEvidence(
                                uniqueBytes:
                                    byteLedger.snapshot
                                        .totalAdvancedBytes,
                                semanticOrdinal:
                                    semantic.ordinal,
                                semanticProgressUptimeSeconds:
                                    semantic
                                        .lastProgressUptimeSeconds
                            )
                        },
                        recoveryOwnerPhase: {
                            self
                                .routePreparationRetryProjection
                                .phase
                        },
                        onProgress: {
                            [weak self] evidence in
                            self?
                                .recordRoutePreparationProgress(
                                    evidence
                                )
                        }
                    )
                },
                stopAndWaitForIOQuiescence: {
                    [weak self] noProgress in
                    await self?
                        .stopRoutePreparationAfterNoProgress(
                            route,
                            evidence: noProgress
                        )
                }
            )
        } catch let noProgress
                as AetherRoutePreparationNoProgress {
            throw Self.routePreparationNoProgressFailure(
                noProgress
            )
        }
    }

    private func recordRoutePreparationProgress(
        _ evidence:
            AetherRoutePreparationProgressEvidence
    ) {
        let observedUptime =
            ProcessInfo.processInfo.systemUptime
        let progressUptime =
            evidence.semanticProgressUptimeSeconds
                ?? observedUptime
        if evidence.semanticOrdinal > 0 {
            emitBoundedProgressLog(
                .routePreparationMilestone(
                    phase:
                        routePreparationRetryProjection.phase
                            ?? .preparingRoute,
                    generation: livenessGeneration,
                    attempt:
                        routePreparationRetryProjection.attempt
                            ?? 0,
                    ordinal:
                        evidence.semanticOrdinal,
                    progressUptime: progressUptime,
                    observedUptime: observedUptime
                )
            )
        }
        transportLivenessAttempt = 0
        transportRetryBudget.reset()
        recoveryLogCadence.resetAfterProgress()
        publishLiveness(
            phase:
                routePreparationRetryProjection.phase
                    ?? .preparingRoute,
            attempt:
                routePreparationRetryProjection.attempt
                    ?? 0,
            uniqueBytesFetched: max(
                livenessSnapshot.uniqueBytesFetched,
                evidence.uniqueBytes
            ),
            lastMeaningfulProgressUptimeSeconds:
                max(
                    livenessSnapshot
                        .lastMeaningfulProgressUptimeSeconds
                        ?? 0,
                    progressUptime
                ),
            nextRetryUptimeSeconds:
                routePreparationRetryProjection
                    .nextRetryUptimeSeconds
        )
    }

    private func stopRoutePreparationAfterNoProgress(
        _ route: AetherActiveRouteSession,
        evidence: AetherRoutePreparationNoProgress
    ) async {
        publishLiveness(
            phase: .cancelling,
            attempt: evidence.attempt,
            uniqueBytesFetched:
                livenessSnapshot.uniqueBytesFetched,
            lastMeaningfulProgressUptimeSeconds:
                livenessSnapshot
                    .lastMeaningfulProgressUptimeSeconds,
            nextRetryUptimeSeconds: nil
        )
        let fence =
            AetherCancellationQuiescenceFence()
        let generation = livenessGeneration
        let watchdog = Task.detached {
            do {
                try await Task.sleep(
                    nanoseconds: 2_000_000_000
                )
            } catch {
                return
            }
            guard fence.isPending else { return }
            EngineLog.emit(
                "[AetherPlaybackSession] cancellationUnresponsive "
                    + "scope=routePreparation "
                    + "generation=\(generation) "
                    + "readerOverlap=forbidden",
                category: .session
            )
        }
        await route.stopAndWaitForIOQuiescence()
        fence.markQuiesced()
        watchdog.cancel()
        EngineLog.emit(
            "[AetherPlaybackSession] route preparation ioStopped "
                + "generation=\(generation) "
                + "attempt=\(evidence.attempt)",
            category: .session
        )
    }

    nonisolated private static func
        routePreparationNoProgressFailure(
            _ noProgress:
                AetherRoutePreparationNoProgress
        ) -> AetherPlaybackFailure {
        AetherPlaybackFailure(
            stage: .preparation,
            kind: .transientTransport,
            domain:
                "AetherEngine.RoutePreparationLiveness",
            code: 1,
            caseCode: "routePreparation.noProgress",
            reason:
                "route preparation made no unique-byte or semantic progress "
                + "for \(Int(noProgress.windowSeconds)) seconds"
        )
    }

    private func makeRouteSession(
        _ source: AetherResolvedPlaybackSource,
        decoderPreference: HybridVideoDecoderPreference = .automatic,
        transaction: UInt64
    ) async throws -> AetherActiveRouteSession {
        switch source.result.route {
        case .nativeAVPlayer:
            let binding: AetherNativeAudioAnalysisBinding
            switch source {
            case .hls(let preflight):
                binding = try await AetherPlaybackSessionFactory
                    .makeNativeHLSAudioAnalysisBinding(
                        url: url,
                        options: options,
                        preflight: preflight
                    )
                try requireCurrentRouteTransaction(transaction)
            case .progressive(let probe, _, _):
                binding = .progressive(
                    sourceURL: url,
                    httpHeaders: options.httpHeaders,
                    probe: probe
                )
            case .startupWatchdogTestHarness:
                binding = .unavailable(
                    sourceURL: url,
                    httpHeaders: options.httpHeaders,
                    error: .analysisFailed(
                        "source evidence remained inconclusive"
                    )
                )
            }
            if case .progressive(
                _, let result, let preparedSource
            ) = source,
               result.reason == .nativeHLSFMP4Remux {
                guard let preparedSource else {
                    throw AetherNativePlaybackSessionError
                        .nativeRemuxRequiresPreparedSource
                }
                let session = try await AetherNativePlaybackSession
                    .makeRemuxed(
                        preparedSource: preparedSource,
                        options: options,
                        preflightResult: source.result,
                        audioAnalysisBinding: binding,
                        avPlayer: avPlayer
                    )
                return try await admitConstructedRoute(
                    .native(session),
                    transaction: transaction
                )
            } else {
                try requireCurrentRouteTransaction(transaction)
                let session = try AetherNativePlaybackSession.make(
                        url: url,
                        options: options,
                        preflightResult: source.result,
                        audioAnalysisBinding: binding,
                        avPlayer: avPlayer
                    )
                return try await admitConstructedRoute(
                    .native(session),
                    transaction: transaction
                )
            }

        case .hybridCarrier:
            switch source {
            case .hls(let preflight):
                let session = try await AetherHybridPlaybackSession
                    .makeHLSVOD(
                        preflight: preflight,
                        avPlayer: avPlayer,
                        decoderPreference: decoderPreference,
                        transportRetryBudget: transportRetryBudget
                    )
                return try await admitConstructedRoute(
                    .hybrid(session),
                    transaction: transaction
                )
            case .progressive(
                let probe,
                let result,
                let preparedSource
            ):
                guard let preparedSource else {
                    throw AetherPlaybackSessionError.invalidFactorySource
                }
                let timelineDuration = CMTime(
                    seconds: probe.durationSeconds,
                    preferredTimescale:
                        BlackCarrierProfile.approved.timescale
                )
                let segmentDecision =
                    try AetherProgressiveProResSegmentPolicy
                        .decide(
                            sourceKind:
                                result.sourceProfile.sourceKind,
                            route: result.route,
                            reason: result.reason,
                            sourceGeneration:
                                preparedSource.sourceGeneration,
                            durationSeconds:
                                probe.durationSeconds
                        )
                EngineLog.emit(
                    "[AetherPlaybackSession] progressive file-VOD segment policy "
                        + "source_kind=\(result.sourceProfile.sourceKind.rawValue) "
                        + "route=\(result.route.rawValue) "
                        + "route_reason=\(result.reason.rawValue) "
                        + "selection=\(segmentDecision.selection.rawValue) "
                        + "validator_bound=\(preparedSource.sourceGeneration?.validator != nil) "
                        + "content_length_bytes=\(segmentDecision.contentLengthBytes.map(String.init) ?? "unavailable") "
                        + "duration_ticks=\(segmentDecision.durationTicks.map(String.init) ?? "unavailable") "
                        + "average_source_bytes_per_second=\(segmentDecision.averageSourceBytesPerSecond.map(String.init) ?? "unavailable") "
                        + "nominal_segment_bytes=\(segmentDecision.nominalSegmentBytes.map(String.init) ?? "unavailable") "
                        + "segment_count=\(segmentDecision.segmentCount.map(String.init) ?? "unavailable") "
                        + "segment_duration_ticks=\(segmentDecision.segmentDurationTicks)",
                    category: .session
                )
                let timeline: BlackCarrierTimeline
                if segmentDecision.isAdaptive {
                    timeline = try BlackCarrierTimeline.fileVOD(
                        duration: timelineDuration,
                        segmentDurationTicks:
                            segmentDecision
                                .segmentDurationTicks
                    )
                } else {
                    timeline = try BlackCarrierTimeline.fileVOD(
                        duration: timelineDuration
                    )
                }
                let session = try await AetherHybridPlaybackSession
                    .makeSeekableVOD(
                        source: .url(url),
                        preparedURLSource: preparedSource,
                        options: options,
                        timeline: timeline,
                        preflightResult: result,
                        avPlayer: avPlayer,
                        decoderPreference: decoderPreference
                    )
                return try await admitConstructedRoute(
                    .hybrid(session),
                    transaction: transaction
                )
            case .startupWatchdogTestHarness:
                throw AetherPlaybackSessionError.invalidFactorySource
            }

        case .unsupported:
            throw AetherPlaybackSessionError.unsupported(
                source.result.reason
            )
        }
    }

    private func requireCurrentRouteTransaction(
        _ transaction: UInt64
    ) throws {
        try Task.checkCancellation()
        guard routeTransactions.isActive(transaction) else {
            throw CancellationError()
        }
    }

    private func admitConstructedRoute(
        _ route: AetherActiveRouteSession,
        transaction: UInt64
    ) async throws -> AetherActiveRouteSession {
        do {
            try requireCurrentRouteTransaction(transaction)
            return route
        } catch {
            await route.stopAndWaitForIOQuiescence()
            throw error
        }
    }

    private func install(
        _ session: AetherActiveRouteSession,
        source: AetherResolvedPlaybackSource,
        transaction: UInt64
    ) throws {
        guard routeTransactions.isActive(transaction) else {
            throw CancellationError()
        }
        cancelTransportMonitoring()
        transportRouteGeneration &+= 1
        routeCancellables.removeAll()
        activeSession = session
        resolvedSource = source
        switch session {
        case .native(let native):
            restoreRouteNeutralPlayerCapabilities()
            presentationView.install(nil)
            bind(native)
        case .hybrid(let hybrid):
            presentationView.install(hybrid.presentationView)
            bind(hybrid)
        }
        #if os(tvOS)
        if let playerViewController {
            try configure(
                session,
                controller: playerViewController,
                realVideoGravity: .resizeAspect
            )
        }
        #endif
        publishCurrentItem(avPlayer.currentItem)
    }

    private func commit(
        _ session: AetherActiveRouteSession,
        source: AetherResolvedPlaybackSource,
        transaction: UInt64
    ) async throws {
        guard routeTransactions.isActive(transaction),
              let activeSession,
              activeSession.isIdentical(to: session) else {
            await session.stopAndWaitForIOQuiescence()
            throw CancellationError()
        }
        resolvedSource = source
        activeRoute = session.route
        activeNativeExecutionMode = source.nativeExecutionMode
        preflightResult = session.preflightResult
        publishCapabilities()
        if case .hybrid(let hybrid) = session {
            overlaySubtitleTracks = hybrid.overlaySubtitleTracks
            activeOverlaySubtitleTrackID =
                hybrid.activeOverlaySubtitleTrackID
        } else {
            overlaySubtitleTracks = []
            activeOverlaySubtitleTrackID = nil
        }
        publishTrackState(from: session)
        EngineLog.emit(
            "[AetherPlaybackSession] route committed "
                + "session=\(sessionID.uuidString.prefix(8)) "
                + "source=\(sourceFingerprint) "
                + "route=\(session.route.rawValue) "
                + "nativeExecution=\(activeNativeExecutionMode?.rawValue ?? "none")",
            category: .session
        )
    }

    private func bind(
        _ session: AetherNativePlaybackSession
    ) {
        bindVideoOutput(
            session.$videoOutputSnapshot,
            initial: session.videoOutputSnapshot
        )
        session.$state.sink { [weak self, weak session] state in
            guard let self,
                  let session,
                  case .native(let active) = self.activeSession,
                  active === session else { return }
            self.handleNativeState(
                state,
                evidence: session.lastFailureEvidence
            )
        }.store(in: &routeCancellables)
        session.$selectedAudioAnalysisTrackID
            .removeDuplicates()
            .sink { [weak self] trackID in
                self?.selectedAudioAnalysisTrackID = trackID
                if self?.activeRoute == .nativeAVPlayer,
                   self?.isPreparingOrRecovering == false {
                    self?.publishCapabilities()
                }
            }
            .store(in: &routeCancellables)
    }

    private func bind(
        _ session: AetherHybridPlaybackSession
    ) {
        routePreparationRetryProjection.reset()
        session.routePreparationRetryEventDidChange = {
            [weak self, weak session] event in
            guard let self,
                  let session,
                  case .hybrid(let active) =
                    self.activeSession,
                  active === session else {
                return
            }
            self.applyRoutePreparationRetryEvent(event)
        }
        bindVideoOutput(
            session.$videoOutputSnapshot,
            initial: session.videoOutputSnapshot
        )
        session.$state.sink { [weak self, weak session] state in
            guard let self,
                  let session,
                  case .hybrid(let active) = self.activeSession,
                  active === session else { return }
            self.handleHybridState(state)
        }.store(in: &routeCancellables)
        session.$selectedAudioAnalysisTrackID
            .removeDuplicates()
            .sink { [weak self] trackID in
                self?.selectedAudioAnalysisTrackID = trackID
                if self?.activeRoute == .hybridCarrier,
                   self?.isPreparingOrRecovering == false {
                    self?.publishCapabilities()
                }
            }
            .store(in: &routeCancellables)
        session.$overlaySubtitleTracks
            .combineLatest(session.$activeOverlaySubtitleTrackID)
            .sink { [weak self] tracks, selectedTrackID in
                guard self?.activeRoute == .hybridCarrier,
                      self?.isPreparingOrRecovering == false else {
                    return
                }
                self?.overlaySubtitleTracks = tracks
                self?.activeOverlaySubtitleTrackID = selectedTrackID
            }
            .store(in: &routeCancellables)
    }

    private func applyRoutePreparationRetryEvent(
        _ event: AetherRoutePreparationRetryEvent
    ) {
        routePreparationRetryProjection.apply(event)
        guard !isStopped,
              livenessSnapshot.phase != .cancelling,
              livenessSnapshot.phase != .cancelled else {
            return
        }
        publishLiveness(
            phase:
                routePreparationRetryProjection.phase
                    ?? (isPreparingOrRecovering
                        ? .preparingRoute
                        : livenessSnapshot.phase),
            attempt:
                routePreparationRetryProjection.attempt
                    ?? (isPreparingOrRecovering
                        ? transportLivenessAttempt
                        : livenessSnapshot.attempt),
            uniqueBytesFetched:
                livenessSnapshot.uniqueBytesFetched,
            lastMeaningfulProgressUptimeSeconds:
                livenessSnapshot
                    .lastMeaningfulProgressUptimeSeconds,
            nextRetryUptimeSeconds:
                routePreparationRetryProjection
                    .nextRetryUptimeSeconds
        )
    }

    private func bindVideoOutput(
        _ publisher: Published<
            AetherVideoOutputSnapshot
        >.Publisher,
        initial: AetherVideoOutputSnapshot
    ) {
        let bindingToken = videoOutputReducer.beginBinding(initial)
        videoOutputSnapshot = videoOutputReducer.snapshot
        publisher.sink { [weak self] snapshot in
            guard let self,
                  let outerSnapshot = self.videoOutputReducer.apply(
                    snapshot,
                    bindingToken: bindingToken
                  ) else { return }
            self.videoOutputSnapshot = outerSnapshot
            self.recordPresentedVideoOutput(outerSnapshot)
        }.store(in: &routeCancellables)
    }

    private func recordPresentedVideoOutput(
        _ snapshot: AetherVideoOutputSnapshot
    ) {
        guard snapshot.outputStatus == .presented,
              let mediaTime =
                snapshot.lastPresentedFrameMediaTimeSeconds else {
            return
        }
        let observedUptime =
            ProcessInfo.processInfo.systemUptime
        let progressUptime =
            snapshot.observedAtUptimeSeconds
                ?? observedUptime
        let phase: AetherPlaybackLivenessPhase =
            desiredPlaying
                ? .flowing
                : livenessSnapshot.phase
        guard emitBoundedProgressLog(
            .presentedFrame(
                phase: phase,
                generation: livenessGeneration,
                attempt: livenessSnapshot.attempt,
                frameGeneration:
                    snapshot.frameGeneration,
                frameSequence: snapshot.frameSequence,
                mediaTimeSeconds: mediaTime,
                progressUptime: progressUptime,
                observedUptime: observedUptime
            )
        ) else {
            return
        }
        transportLivenessAttempt = 0
        transportRetryBudget.reset()
        recoveryLogCadence.resetAfterProgress()
        publishLiveness(
            phase: phase,
            attempt: 0,
            uniqueBytesFetched:
                livenessSnapshot.uniqueBytesFetched,
            lastMeaningfulProgressUptimeSeconds:
                progressUptime,
            nextRetryUptimeSeconds: nil
        )
    }

    private func invalidateVideoOutputRoute() {
        videoOutputSnapshot = videoOutputReducer.invalidate()
    }

    private func handleNativeState(
        _ nativeState: AetherNativePlaybackSessionState,
        evidence: AetherNativePlaybackFailureEvidence?
    ) {
        switch nativeState {
        case .idle: break
        case .preparing: if !isPreparingOrRecovering { state = .preparing }
        case .ready: if !isPreparingOrRecovering { state = .ready }
        case .playing: if !isPreparingOrRecovering { state = .playing }
        case .paused: if !isPreparingOrRecovering { state = .paused }
        case .seeking: if !isPreparingOrRecovering { state = .seeking }
        case .ended:
            cancelTransportMonitoring()
            state = .ended
        case .failed(let failure):
            guard didCompleteInitialPrepare,
                  !isPreparingOrRecovering,
                  activeSeekOperationSequence == nil else { return }
            scheduleRuntimeRecovery(Self.nativeRuntimeFailure(
                fallback: failure,
                evidence: evidence
            ))
        case .stopped: break
        }
    }

    private func handleHybridState(
        _ hybridState: HybridPlaybackSessionState
    ) {
        switch hybridState {
        case .idle: break
        case .preparing:
            if !isPreparingOrRecovering { state = .preparing }
        case .ready:
            if !isPreparingOrRecovering {
                state = desiredPlaying ? .playing : .ready
            }
        case .seeking:
            if !isPreparingOrRecovering { state = .seeking }
        case .ended:
            cancelTransportMonitoring()
            state = .ended
        case .failed(let error):
            guard didCompleteInitialPrepare,
                  !isPreparingOrRecovering,
                  activeSeekOperationSequence == nil else { return }
            scheduleRuntimeRecovery(
                failure(stage: .playback, error: error)
            )
        case .stopped: break
        }
    }

    private func scheduleRuntimeRecovery(
        _ failure: AetherPlaybackFailure
    ) {
        guard !isStopped,
              !recoveryCoordinator.terminalOutcomeWasIssued else {
            return
        }
        if Self.isPermanentFailure(failure.kind) {
            recoveryTask?.cancel()
            _ = finishRecoveryAsTerminal(
                initialFailure:
                    recoveryCoordinator.sessionFirstFailure
                    ?? failure,
                finalFailure: failure,
                exhaustionReason:
                    "permanent failure superseded recovery"
            )
            return
        }
        if recoveryTask != nil {
            let key = "\(failure.stage.rawValue):\(failure.kind.rawValue):\(failure.domain):\(failure.code)"
            if mergedRuntimeFailureKeys.insert(key).inserted {
                publishRecovery(
                    failure: failure,
                    action: .rebuildSameRoute,
                    from: activeRoute,
                    to: activeRoute,
                    outcome: .merged
                )
            }
            return
        }
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if Self.requiresPersistentSameSourceRecovery(
                    failure
                ) {
                    try await self
                        .recoverSameSourceTransportUntilSuccess(
                            from: failure,
                            duringInitialPrepare: false
                        )
                } else {
                    let recovered = try await self.recover(
                        from: failure,
                        duringInitialPrepare: false
                    )
                    if !recovered {
                        _ = self.finishRecoveryAsTerminal(
                            initialFailure: failure,
                            finalFailure:
                                self.lastRecoveryFailure ?? failure,
                            exhaustionReason:
                                "runtime structural recovery exhausted"
                        )
                    }
                }
            } catch is CancellationError {
                if !self.isStopped,
                   !self.recoveryCoordinator
                    .terminalOutcomeWasIssued {
                    let cancelled = self.failure(
                        stage: .playback,
                        error: CancellationError()
                    )
                    _ = self.finishRecoveryAsTerminal(
                        initialFailure: failure,
                        finalFailure: cancelled,
                        exhaustionReason:
                            "runtime recovery cancelled"
                    )
                }
            } catch {
                let finalFailure = self.failure(
                    stage: .playback,
                    error: error
                )
                _ = self.finishRecoveryAsTerminal(
                    initialFailure: failure,
                    finalFailure: finalFailure,
                    exhaustionReason:
                        "runtime recovery operation failed"
                )
            }
            self.recoveryTask = nil
            self.completeRecoveryTransportHandoff()
        }
    }

    nonisolated static func
        requiresPersistentSameSourceRecovery(
            _ failure: AetherPlaybackFailure
        ) -> Bool
    {
        failure.kind == .transientTransport
            || failure.kind == .inconclusiveEvidence
            || PlaybackRecoveryDecision
                .requiresSameRouteTransportRecovery(
                    failure: failure
                )
    }

    /// Rebuilds only the already-admitted route for the same canonical
    /// request. Transport and startup no-progress never consume a total
    /// attempt or wall-clock budget; every failed generation is stopped
    /// before the next generation is admitted.
    private func recoverSameSourceTransportUntilSuccess(
        from initialFailure: AetherPlaybackFailure,
        duringInitialPrepare: Bool
    ) async throws {
        guard !isStopped else { throw CancellationError() }
        isPreparingOrRecovering = true
        firstFailure = firstFailure ?? initialFailure
        beginRecoveryEpisodeIfNeeded(initialFailure)

        let failedRoute = activeSession?.route
            ?? activeRoute
            ?? resolvedSource?.result.route
        let failedSourceResult = resolvedSource?.result
        let failedProgressiveSourceFacts =
            resolvedSource?.progressiveSourceFacts
        let failedProgressiveSourceGeneration =
            resolvedSource?.progressiveSourceGeneration
        let failedHLSResourceIdentity =
            resolvedSource?.hlsResourceIdentity
        let playbackContext = snapshotPlaybackContext()
        var latestFailure = initialFailure

        guard let failedRoute,
              failedRoute != .unsupported else {
            isPreparingOrRecovering = false
            throw AetherPlaybackFailure(
                stage: initialFailure.stage,
                kind: .invariantViolation,
                domain: "AetherPlaybackSameSourceRecovery",
                code: 0,
                caseCode: "sameSourceRouteMissing",
                reason:
                    "same-source transport recovery has no admitted route"
            )
        }

        while !isStopped {
            try Task.checkCancellation()
            transportLivenessAttempt += 1
            let attempt = transportLivenessAttempt
            let delay = recoveryBudget.livenessPolicy
                .retryBackoffSeconds(forAttempt: attempt)
            let action =
                AetherPlaybackRecoveryAction.retrySameOperation(
                    afterSeconds: delay
                )
            recoveryCoordinator.recordAttempt(action)
            publishRecovery(
                failure: latestFailure,
                action: action,
                from: failedRoute,
                to: failedRoute,
                outcome: .scheduled
            )

            publishLiveness(
                phase: .cancelling,
                attempt: attempt,
                uniqueBytesFetched:
                    livenessSnapshot.uniqueBytesFetched,
                lastMeaningfulProgressUptimeSeconds:
                    livenessSnapshot
                        .lastMeaningfulProgressUptimeSeconds,
                nextRetryUptimeSeconds: nil
            )
            let cancellationFence =
                AetherCancellationQuiescenceFence()
            let cancellationGeneration = livenessGeneration
            let cancellationWatchdog = Task.detached {
                do {
                    try await Task.sleep(
                        nanoseconds: 2_000_000_000
                    )
                } catch {
                    return
                }
                guard cancellationFence.isPending else { return }
                EngineLog.emit(
                    "[AetherPlaybackSession] cancellationUnresponsive "
                        + "generation=\(cancellationGeneration) "
                        + "readerOverlap=forbidden",
                    category: .session
                )
            }
            await teardownActiveRouteAndWaitForIOQuiescence()
            await resolvedSource?
                .discardUnconsumedPreparedSourceAndWaitForIOQuiescence()
            resolvedSource = nil
            cancellationFence.markQuiesced()
            cancellationWatchdog.cancel()

            publishLiveness(
                phase: .retryScheduled,
                attempt: attempt,
                uniqueBytesFetched:
                    livenessSnapshot.uniqueBytesFetched,
                lastMeaningfulProgressUptimeSeconds:
                    livenessSnapshot
                        .lastMeaningfulProgressUptimeSeconds,
                nextRetryUptimeSeconds:
                    ProcessInfo.processInfo.systemUptime + delay
            )
            if delay > 0 {
                try await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
            }
            try Task.checkCancellation()
            livenessGeneration &+= 1

            do {
                let freshSource = try await resolveCanonicalSource()
                if let sourceDivergence = Self
                    .freshProgressiveSourceIdentityFailure(
                        previousFacts:
                            failedProgressiveSourceFacts,
                        freshFacts:
                            freshSource.progressiveSourceFacts
                    ) {
                    throw sourceDivergence
                }
                if let generationDivergence = Self
                    .freshProgressiveSourceGenerationFailure(
                        previousGeneration:
                            failedProgressiveSourceGeneration,
                        freshGeneration:
                            freshSource.progressiveSourceGeneration
                    ) {
                    await freshSource
                        .discardUnconsumedPreparedSourceAndWaitForIOQuiescence()
                    throw generationDivergence
                }
                if let failedHLSResourceIdentity,
                   freshSource.hlsResourceIdentity
                    != failedHLSResourceIdentity {
                    throw AetherPlaybackFailure(
                        stage: .preflight,
                        kind: .invariantViolation,
                        domain: "AetherPlaybackSourceIdentity",
                        code: 0,
                        caseCode: "hlsResourceIdentityChanged",
                        reason:
                            "fresh HLS facts diverged from committed source identity"
                    )
                }
                if let failedSourceResult,
                   freshSource.result != failedSourceResult {
                    throw AetherPlaybackFailure(
                        stage: .preflight,
                        kind: .invariantViolation,
                        domain: "AetherPlaybackSourceIdentity",
                        code: 0,
                        caseCode: "preflightIdentityChanged",
                        reason:
                            "fresh source facts diverged from committed playback identity"
                    )
                }
                guard let admitted = freshSource.admitting(
                    route: failedRoute,
                    requiredAudioBridgeMode:
                        options.audioBridgeMode
                ) else {
                    throw AetherPlaybackFailure(
                        stage: .preflight,
                        kind: .invariantViolation,
                        domain: "AetherPlaybackSourceIdentity",
                        code: 0,
                        caseCode: "sameRouteAdmissionChanged",
                        reason:
                            "same-source transport recovery changed route admission"
                    )
                }

                try await installAndPrepare(admitted)
                try await restorePlaybackContextForTransportLiveness(
                    playbackContext,
                    duringInitialPrepare: duringInitialPrepare,
                    attempt: attempt
                )
                publishRecovery(
                    failure: latestFailure,
                    action: action,
                    from: failedRoute,
                    to: failedRoute,
                    outcome: .succeeded
                )
                transportLivenessAttempt = 0
                transportRetryBudget.reset()
                recoveryLogCadence.resetAfterProgress()
                isPreparingOrRecovering = false
                publishLiveness(
                    phase: desiredPlaying ? .buffering : .preparingRoute,
                    attempt: 0,
                    uniqueBytesFetched:
                        livenessSnapshot.uniqueBytesFetched,
                    lastMeaningfulProgressUptimeSeconds:
                        ProcessInfo.processInfo.systemUptime,
                    nextRetryUptimeSeconds: nil
                )
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                latestFailure = failure(
                    stage: .preparation,
                    error: error
                )
                publishRecovery(
                    failure: latestFailure,
                    action: action,
                    from: failedRoute,
                    to: failedRoute,
                    outcome: .failed
                )
                guard Self.requiresPersistentSameSourceRecovery(
                    latestFailure
                ) else {
                    isPreparingOrRecovering = false
                    throw latestFailure
                }
            }
        }
        throw CancellationError()
    }

    private func restorePlaybackContextForTransportLiveness(
        _ context: AetherPlaybackContextSnapshot,
        duringInitialPrepare: Bool,
        attempt: Int
    ) async throws {
        do {
            if !duringInitialPrepare {
                guard let activeSession else {
                    throw AetherPlaybackSessionError.noActiveRoute
                }
                let resumeTime = desiredSeekTarget ?? context.position
                if resumeTime.isValid,
                   resumeTime.isNumeric,
                   resumeTime.seconds.isFinite,
                   resumeTime.seconds >= 0 {
                    let result = try await activeSession.seek(
                        to: resumeTime,
                        timeout: recoveryBudget.livenessPolicy
                            .noProgressWindowSeconds(
                                forAttempt: attempt
                            )
                    )
                    guard result == .applied else {
                        throw AetherPlaybackFailure(
                            stage: .playback,
                            kind: .routeRuntimeFailure,
                            domain:
                                "AetherPlaybackSameSourceRecovery",
                            code: 0,
                            caseCode: "startupNoProgress",
                            reason:
                                "recovery seek was superseded before media progress"
                        )
                    }
                    lastConfirmedMediaTime = resumeTime
                }
            }
            try await applyRestoredPlaybackContext()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let typed = failure(stage: .playback, error: error)
            if Self.isPermanentFailure(typed.kind)
                || typed.kind == .decoderRuntimeFailure {
                throw typed
            }
            if typed.kind == .transientTransport
                || typed.kind == .inconclusiveEvidence {
                throw typed
            }
            throw AetherPlaybackFailure(
                stage: .playback,
                kind: .routeRuntimeFailure,
                domain: typed.domain,
                code: typed.code,
                caseCode: "startupNoProgress",
                reason:
                    "same-source recovery context made no usable media progress"
            )
        }
    }

    private func recover(
        from initialFailure: AetherPlaybackFailure,
        duringInitialPrepare: Bool
    ) async throws -> Bool {
        guard !isStopped else { throw CancellationError() }
        isPreparingOrRecovering = true
        firstFailure = firstFailure ?? initialFailure
        beginRecoveryEpisodeIfNeeded(initialFailure)
        let failedRoute = activeSession?.route
            ?? activeRoute
            ?? resolvedSource?.result.route
        let failedSourceResult = resolvedSource?.result
        let failedProgressiveSourceFacts =
            resolvedSource?.progressiveSourceFacts
        let failedProgressiveSourceGeneration =
            resolvedSource?.progressiveSourceGeneration
        let failedHLSResourceIdentity =
            resolvedSource?.hlsResourceIdentity
        let playbackContext = snapshotPlaybackContext()
        var latestFailure = initialFailure
        var freshSource = resolvedSource
        let requiresImmediateNativeExit = PlaybackRecoveryDecision
            .requiresImmediateNativeExit(
                failure: initialFailure,
                activeRoute: failedRoute
            )

        switch initialFailure.kind {
        case .unsupportedCapability, .authenticationRejected,
             .securityBoundary, .malformedMedia,
             .hostContractViolation, .cancelled,
             .invariantViolation:
            publishRecovery(
                failure: initialFailure,
                action: .terminate,
                from: failedRoute,
                to: nil,
                outcome: .exhausted
            )
            isPreparingOrRecovering = false
            return false
        case .transientTransport, .inconclusiveEvidence,
             .routeRuntimeFailure, .decoderRuntimeFailure:
            break
        }
        // Persistent transport work is routed before this structural method.
        // Without an admitted route there is no decoder or implementation
        // structure to rebuild.
        guard failedRoute != nil else {
            publishRecovery(
                failure: initialFailure,
                action: .terminate,
                from: nil,
                to: nil,
                outcome: .exhausted
            )
            isPreparingOrRecovering = false
            return false
        }

        if requiresImmediateNativeExit {
            // Positive codec evidence disproves the installed Native route.
            // This session cannot change players after launch, so terminate
            // rather than silently admitting Hybrid.
            publishRecovery(
                failure: initialFailure,
                action: .terminate,
                from: failedRoute,
                to: nil,
                outcome: .exhausted
            )
            teardownActiveRoute()
            isPreparingOrRecovering = false
            return false
        }

        if recoveryCoordinator.sameRouteRebuildCount
                < recoveryBudget.maximumSameRouteRebuilds,
           let failedRoute {
            let action = AetherPlaybackRecoveryAction.rebuildSameRoute
            recoveryCoordinator.recordAttempt(action)
            publishRecovery(
                failure: latestFailure,
                action: action,
                from: failedRoute,
                to: failedRoute,
                outcome: .scheduled
            )
            teardownActiveRoute()
            do {
                freshSource = try await resolveCanonicalSource()
                guard let freshSource else {
                    throw AetherPlaybackSessionError.unsupported(
                        .unsupportedVideoCodec
                    )
                }
                if let sourceDivergence = Self
                    .freshProgressiveSourceIdentityFailure(
                        previousFacts:
                            failedProgressiveSourceFacts,
                        freshFacts:
                            freshSource.progressiveSourceFacts
                    ) {
                    throw sourceDivergence
                }
                if let generationDivergence = Self
                    .freshProgressiveSourceGenerationFailure(
                        previousGeneration:
                            failedProgressiveSourceGeneration,
                        freshGeneration:
                            freshSource.progressiveSourceGeneration
                    ) {
                    await freshSource
                        .discardUnconsumedPreparedSourceAndWaitForIOQuiescence()
                    throw generationDivergence
                }
                if let failedHLSResourceIdentity,
                   freshSource.hlsResourceIdentity
                    != failedHLSResourceIdentity {
                    await freshSource
                        .discardUnconsumedPreparedSourceAndWaitForIOQuiescence()
                    throw AetherPlaybackFailure(
                        stage: .preflight,
                        kind: .invariantViolation,
                        domain: "AetherPlaybackSourceIdentity",
                        code: 0,
                        caseCode: "hlsResourceIdentityChanged",
                        reason:
                            "fresh HLS facts diverged from committed source identity"
                    )
                }
                if let failedSourceResult,
                   freshSource.result != failedSourceResult {
                    await freshSource
                        .discardUnconsumedPreparedSourceAndWaitForIOQuiescence()
                    throw AetherPlaybackFailure(
                        stage: .preflight,
                        kind: .invariantViolation,
                        domain: "AetherPlaybackSourceIdentity",
                        code: 0,
                        caseCode: "preflightIdentityChanged",
                        reason:
                            "fresh source facts diverged from committed playback identity"
                    )
                }
                guard let admitted = freshSource.admitting(
                    route: failedRoute,
                    requiredAudioBridgeMode:
                        options.audioBridgeMode
                ) else {
                    if let reclassified = Self
                        .freshRouteReclassificationFailure(
                            previousResult: failedSourceResult,
                            from: failedRoute,
                            freshResult: freshSource.result
                        ) {
                        throw reclassified
                    }
                    throw AetherPlaybackSessionError.unsupported(
                        freshSource.result.reason
                    )
                }
                try await installAndPrepare(admitted)
                try await restorePlaybackContext(
                    playbackContext,
                    duringInitialPrepare: duringInitialPrepare
                )
                publishRecovery(
                    failure: latestFailure,
                    action: action,
                    from: failedRoute,
                    to: failedRoute,
                    outcome: .succeeded
                )
                isPreparingOrRecovering = false
                return true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                latestFailure = failure(
                    stage: .preparation,
                    error: error
                )
                publishRecovery(
                    failure: latestFailure,
                    action: action,
                    from: failedRoute,
                    to: failedRoute,
                    outcome: .failed
                )
                if Self.requiresPersistentSameSourceRecovery(
                    latestFailure
                ) {
                    try await recoverSameSourceTransportUntilSuccess(
                        from: latestFailure,
                        duringInitialPrepare:
                            duringInitialPrepare
                    )
                    return true
                }
            }
        }

        if freshSource == nil {
            do {
                freshSource = try await resolveCanonicalSource()
            } catch {
                latestFailure = failure(stage: .preflight, error: error)
                if Self.requiresPersistentSameSourceRecovery(
                    latestFailure
                ) {
                    try await recoverSameSourceTransportUntilSuccess(
                        from: latestFailure,
                        duringInitialPrepare:
                            duringInitialPrepare
                    )
                    return true
                }
            }
        }
        var softwareRecoverySource: AetherResolvedPlaybackSource?
        if failedRoute == .hybridCarrier,
           initialFailure.kind == .decoderRuntimeFailure,
           !Self.isPermanentFailure(latestFailure.kind) {
            do {
                let candidate = try await resolveCanonicalSource()
                if let generationDivergence = Self
                    .freshProgressiveSourceGenerationFailure(
                        previousGeneration:
                            failedProgressiveSourceGeneration,
                        freshGeneration:
                            candidate.progressiveSourceGeneration
                    ) {
                    await candidate
                        .discardUnconsumedPreparedSourceAndWaitForIOQuiescence()
                    throw generationDivergence
                }
                if let sourceDivergence = Self
                    .freshSoftwareRecoverySourceIdentityFailure(
                        previousResult: failedSourceResult,
                        previousProgressiveFacts:
                            failedProgressiveSourceFacts,
                        previousHLSResourceIdentity:
                            failedHLSResourceIdentity,
                        freshResult: candidate.result,
                        freshProgressiveFacts:
                            candidate.progressiveSourceFacts,
                        freshHLSResourceIdentity:
                            candidate.hlsResourceIdentity
                    ) {
                    throw sourceDivergence
                }
                freshSource = candidate
                softwareRecoverySource = candidate.admitting(
                    route: .hybridCarrier,
                    requiredAudioBridgeMode:
                        options.audioBridgeMode
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                latestFailure = failure(
                    stage: .preflight,
                    error: error
                )
                if Self.requiresPersistentSameSourceRecovery(
                    latestFailure
                ) {
                    try await recoverSameSourceTransportUntilSuccess(
                        from: latestFailure,
                        duringInitialPrepare:
                            duringInitialPrepare
                    )
                    return true
                }
            }
        }
        if failedRoute == .hybridCarrier,
           initialFailure.kind == .decoderRuntimeFailure,
           let softwareSource = softwareRecoverySource,
           isSoftwareHEVCRecoveryEligible(softwareSource) {
            let softwareAction = PlaybackRecoveryDecision.resolve(
                context: AetherPlaybackRecoveryContext(
                    failure: initialFailure,
                    activeRoute: failedRoute,
                    positivelyAdmittedAlternateRoute: nil,
                    transportAttempt:
                        max(
                            1,
                            transportRetryBudget
                                .currentFailureAttempt
                        ),
                    sameRouteRebuildCount:
                        recoveryCoordinator.sameRouteRebuildCount,
                    softwareDecoderTransitionCount:
                        recoveryCoordinator
                            .softwareDecoderTransitionCount,
                    softwareDecoderRecoveryEligible: true,
                    routeTransitionCount:
                        recoveryCoordinator.routeTransitionCount,
                    elapsedSeconds: episodeElapsedSeconds,
                    systemActivity: systemActivity
                ),
                budget: recoveryBudget
            )
            if softwareAction == .switchToSoftwareDecoder {
                recoveryCoordinator.recordAttempt(softwareAction)
                publishRecovery(
                    failure: latestFailure,
                    action: softwareAction,
                    from: failedRoute,
                    to: failedRoute,
                    outcome: .scheduled
                )
                teardownActiveRoute()
                do {
                    try await installAndPrepare(
                        softwareSource,
                        decoderPreference: .softwareHEVCRecovery
                    )
                    try await restorePlaybackContext(
                        playbackContext,
                        duringInitialPrepare: duringInitialPrepare
                    )
                    publishRecovery(
                        failure: latestFailure,
                        action: softwareAction,
                        from: failedRoute,
                        to: failedRoute,
                        outcome: .succeeded
                    )
                    isPreparingOrRecovering = false
                    return true
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    latestFailure = failure(
                        stage: .decoder,
                        error: error
                    )
                    publishRecovery(
                        failure: latestFailure,
                        action: softwareAction,
                        from: failedRoute,
                        to: failedRoute,
                        outcome: .failed
                    )
                    if Self.requiresPersistentSameSourceRecovery(
                        latestFailure
                    ) {
                        try await
                            recoverSameSourceTransportUntilSuccess(
                                from: latestFailure,
                                duringInitialPrepare:
                                    duringInitialPrepare
                            )
                        return true
                    }
                }
            }
        }
        if Self.requiresPersistentSameSourceRecovery(
            latestFailure
        ) {
            try await recoverSameSourceTransportUntilSuccess(
                from: latestFailure,
                duringInitialPrepare: duringInitialPrepare
            )
            return true
        }
        publishRecovery(
            failure: latestFailure,
            action: .terminate,
            from: failedRoute,
            to: nil,
            outcome: .exhausted
        )
        isPreparingOrRecovering = false
        return false
    }

    private func recoverOrTerminate(
        from initialFailure: AetherPlaybackFailure,
        duringInitialPrepare: Bool,
        failureStage: AetherPlaybackRecoveryStage,
        exhaustionReason: String
    ) async throws {
        do {
            if Self.requiresPersistentSameSourceRecovery(
                initialFailure
            ) {
                try await recoverSameSourceTransportUntilSuccess(
                    from: initialFailure,
                    duringInitialPrepare: duringInitialPrepare
                )
                completeRecoveryTransportHandoff()
                return
            }
            if try await recover(
                from: initialFailure,
                duringInitialPrepare: duringInitialPrepare
            ) {
                completeRecoveryTransportHandoff()
                return
            }
            let terminal = finishRecoveryAsTerminal(
                initialFailure: initialFailure,
                finalFailure: lastRecoveryFailure ?? initialFailure,
                exhaustionReason: exhaustionReason
            )
            throw AetherPlaybackSessionError.terminal(terminal)
        } catch is CancellationError {
            if isStopped {
                isPreparingOrRecovering = false
                throw CancellationError()
            }
            let cancelled = failure(
                stage: failureStage,
                error: CancellationError()
            )
            _ = finishRecoveryAsTerminal(
                initialFailure: initialFailure,
                finalFailure: cancelled,
                exhaustionReason:
                    "recovery cancelled without successor"
            )
            throw CancellationError()
        } catch let terminal as AetherPlaybackSessionError {
            if case .terminal = terminal {
                throw terminal
            }
            let finalFailure = failure(
                stage: failureStage,
                error: terminal
            )
            let original = finishRecoveryAsTerminal(
                initialFailure: initialFailure,
                finalFailure: finalFailure,
                exhaustionReason: exhaustionReason
            )
            throw AetherPlaybackSessionError.terminal(original)
        } catch {
            let finalFailure = failure(
                stage: failureStage,
                error: error
            )
            let terminal = finishRecoveryAsTerminal(
                initialFailure: initialFailure,
                finalFailure: finalFailure,
                exhaustionReason: exhaustionReason
            )
            throw AetherPlaybackSessionError.terminal(terminal)
        }
    }

    @discardableResult
    private func finishRecoveryAsTerminal(
        initialFailure: AetherPlaybackFailure,
        finalFailure: AetherPlaybackFailure,
        exhaustionReason: String
    ) -> AetherPlaybackFailure {
        let original = recoveryCoordinator.episodeFirstFailure
            ?? initialFailure
        if recoveryHistory.last?.outcome != .exhausted {
            publishRecovery(
                failure: finalFailure,
                action: .terminate,
                from: activeSession?.route
                    ?? activeRoute
                    ?? resolvedSource?.result.route,
                to: nil,
                outcome: .exhausted
            )
        }
        teardownActiveRoute()
        isPreparingOrRecovering = false
        publishTerminal(
            original,
            finalFailure: finalFailure,
            exhaustionReason: exhaustionReason
        )
        return original
    }

    private func restorePlaybackContext(
        _ context: AetherPlaybackContextSnapshot,
        duringInitialPrepare: Bool
    ) async throws {
        let stage: AetherPlaybackRecoveryStage =
            duringInitialPrepare ? .preparation : .playback
        let envelope = Self.recoveryLivenessOperationDeadline(
            stage: stage,
            firstStep: duringInitialPrepare
                ? .contextApply
                : .contextSeek,
            policy: recoveryBudget.livenessPolicy,
            attempt: max(
                1,
                transportLivenessAttempt + 1
            ),
            now: ProcessInfo.processInfo.systemUptime
        )
        if !duringInitialPrepare {
            try await performRecoveryContextOperation(
                step: .contextSeek,
                stage: stage,
                deadline: envelope.deadline,
                timeoutFailure: envelope.failure
            ) { [self] in
                try await restorePlaybackContextSeek(
                    context,
                    deadline: envelope.deadline
                )
            }
        }
        try await performRecoveryContextOperation(
            step: .contextApply,
            stage: stage,
            deadline: envelope.deadline,
            timeoutFailure: envelope.failure
        ) { [self] in
            try await applyRestoredPlaybackContext()
        }
    }

    private func restorePlaybackContextSeek(
        _ context: AetherPlaybackContextSnapshot,
        deadline: PlaybackRecoveryDeadline
    ) async throws {
        guard let activeSession else {
            throw AetherPlaybackSessionError.noActiveRoute
        }
        guard let routeTransaction = routeTransactions.activeSequence else {
            throw CancellationError()
        }
        func requireCurrentRoute() throws {
            guard routeTransactions.isActive(routeTransaction),
                  let current = self.activeSession,
                  current.isIdentical(to: activeSession) else {
                throw CancellationError()
            }
        }
        let resumeTime = desiredSeekTarget ?? context.position
        guard resumeTime.isValid,
              resumeTime.isNumeric,
              resumeTime.seconds.isFinite,
              resumeTime.seconds >= 0 else {
            return
        }
        let seekTimeout = deadline.remainingSeconds(
            now: ProcessInfo.processInfo.systemUptime
        )
        guard seekTimeout > 0 else {
            throw Self.seekTimeoutFailure(
                seconds: deadline.durationSeconds
            ).recordingRecoveryDiagnostic(
                step: .contextSeek
            )
        }
        let seekResult = try await activeSession.seek(
            to: resumeTime,
            timeout: seekTimeout
        )
        guard seekResult == .applied else {
            throw CancellationError()
        }
        try requireCurrentRoute()
        lastConfirmedMediaTime = resumeTime
        if desiredSeekTarget != nil {
            lastAppliedSeekOperationSequence =
                operationCoordinator.latestSeekSequence
        }
    }

    private func applyRestoredPlaybackContext() async throws {
        guard let activeSession else {
            throw AetherPlaybackSessionError.noActiveRoute
        }
        guard let routeTransaction = routeTransactions.activeSequence else {
            throw CancellationError()
        }
        func requireCurrentRoute() throws {
            guard routeTransactions.isActive(routeTransaction),
                  let current = self.activeSession,
                  current.isIdentical(to: activeSession) else {
                throw CancellationError()
            }
        }
        try requireCurrentRoute()
        // The stable player and session-owned intent remain live while a route
        // is being rebuilt. Apply their latest values instead of replaying an
        // episode-start snapshot over changes made during recovery.
        #if os(tvOS) || os(iOS)
        currentItem?.externalMetadata = externalMetadata
        #endif
        publishCurrentItem(avPlayer.currentItem)
        if let desiredAudioTrackID {
            guard activeSession.audioTracks.contains(where: {
                $0.id == desiredAudioTrackID
            }) else {
                throw AetherPlaybackTrackSelectionError
                    .selectedTrackCouldNotBeRestored(
                        desiredAudioTrackID
                    )
            }
            try await activeSession.selectAudioTrack(
                desiredAudioTrackID
            )
            try requireCurrentRoute()
        }
        if let desiredSubtitleTrackID {
            if activeSession.subtitleTracks.contains(where: {
                $0.id == desiredSubtitleTrackID
            }) {
                do {
                    try await activeSession.selectSubtitleTrack(
                        desiredSubtitleTrackID
                    )
                    try requireCurrentRoute()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    try requireCurrentRoute()
                    selectedSubtitleTrackID = nil
                    EngineLog.emit(
                        "[AetherPlaybackSession] optional subtitle unavailable "
                            + "session=\(sessionID.uuidString.prefix(8)) "
                            + "track=declared",
                        category: .session
                    )
                }
            } else {
                selectedSubtitleTrackID = nil
                EngineLog.emit(
                    "[AetherPlaybackSession] optional subtitle unavailable "
                        + "session=\(sessionID.uuidString.prefix(8)) "
                        + "track=missing",
                    category: .session
                )
            }
        }
        try requireCurrentRoute()
        publishTrackState(from: activeSession)
        publishCapabilities()
        if desiredPlaying || didCompleteInitialPrepare {
            try applyTransportIntent(
                sequence: transportCommandSequence,
                expectedRouteGeneration: transportRouteGeneration,
                deferMonitoringUntilRecoveryHandoff: true
            )
        } else {
            state = .ready
        }
    }

    /// Production structural context restoration owns an independent
    /// no-progress observation window. The deprecated recovery-episode
    /// duration is not a wall-clock terminal for route recovery.
    nonisolated static func recoveryLivenessOperationDeadline(
        stage: AetherPlaybackRecoveryStage,
        firstStep: AetherPlaybackRecoveryStep,
        policy: AetherPlaybackLivenessPolicy,
        attempt: Int,
        now: TimeInterval
    ) -> (
        deadline: PlaybackRecoveryDeadline,
        failure: AetherPlaybackFailure
    ) {
        precondition(now.isFinite)
        let timeout = policy.noProgressWindowSeconds(
            forAttempt: max(1, attempt)
        )
        let failure = (
            firstStep == .contextSeek
                ? Self.seekTimeoutFailure(seconds: timeout)
                : Self.recoveryContextNoProgressFailure(
                    stage: stage,
                    seconds: timeout
                )
        ).recordingRecoveryDiagnostic(step: firstStep)
        return (
            PlaybackRecoveryDeadline(
                startedAt: now,
                durationSeconds: timeout
            ),
            failure
        )
    }

    private func performRecoveryContextOperation<Value: Sendable>(
        step: AetherPlaybackRecoveryStep,
        stage: AetherPlaybackRecoveryStage,
        deadline: PlaybackRecoveryDeadline,
        timeoutFailure: AetherPlaybackFailure,
        operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        let timeout = deadline.remainingSeconds(
            now: ProcessInfo.processInfo.systemUptime
        )
        let steppedTimeout = timeoutFailure
            .recordingRecoveryDiagnostic(step: step)
        guard timeout > 0 else { throw steppedTimeout }
        do {
            return try await AetherPlaybackOperationDeadlineRace<Value>()
                .run(
                    timeout: timeout,
                    timeoutFailure: steppedTimeout,
                    onAbandon: { [weak self] in
                        self?.teardownActiveRoute()
                    },
                    operation: operation
                )
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as AetherPlaybackFailure {
            throw failure.recordingRecoveryDiagnostic(step: step)
        } catch {
            throw failure(stage: stage, error: error)
                .recordingRecoveryDiagnostic(step: step)
        }
    }

    private func snapshotPlaybackContext()
        -> AetherPlaybackContextSnapshot
    {
        let playerTime = avPlayer.currentTime()
        let confirmedPosition: CMTime
        if let desiredSeekTarget {
            confirmedPosition = desiredSeekTarget
        } else if lastConfirmedMediaTime.isValid,
                  lastConfirmedMediaTime.isNumeric,
                  lastConfirmedMediaTime.seconds.isFinite {
            confirmedPosition = lastConfirmedMediaTime
        } else if playerTime.isValid,
                  playerTime.isNumeric,
                  playerTime.seconds.isFinite {
            confirmedPosition = playerTime
        } else {
            confirmedPosition = .zero
        }
        let formattedPosition = String(
            format: "%.3f",
            confirmedPosition.seconds
        )
        EngineLog.emit(
            "[AetherPlaybackSession] context snapshot "
                + "session=\(sessionID.uuidString.prefix(8)) "
                + "seekOperation=\(operationCoordinator.latestSeekSequence) "
                + "position=\(formattedPosition) "
                + "playing=\(desiredPlaying) rate=\(desiredRate)",
            category: .session
        )
        return AetherPlaybackContextSnapshot(
            position: confirmedPosition
        )
    }

    private func isSoftwareHEVCRecoveryEligible(
        _ source: AetherResolvedPlaybackSource
    ) -> Bool {
        PlaybackRecoveryDecision.permitsSoftwareHEVCRecovery(
            sourceProfile: source.result.sourceProfile
        )
    }

    private func retryTransport<T: Sendable>(
        stage: AetherPlaybackRecoveryStage,
        operation: @escaping @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        var pendingRetry:
            (AetherPlaybackFailure, AetherPlaybackRecoveryAction)?
        while true {
            do {
                try Task.checkCancellation()
                let value = try await operation()
                if let pendingRetry {
                    publishRecovery(
                        failure: pendingRetry.0,
                        action: pendingRetry.1,
                        from: activeRoute,
                        to: activeRoute,
                        outcome: .succeeded
                    )
                }
                transportLivenessAttempt = 0
                transportRetryBudget.reset()
                recoveryLogCadence.resetAfterProgress()
                publishLiveness(
                    phase: stage == .classification
                        ? .classifying
                        : .preflighting,
                    attempt: 0,
                    uniqueBytesFetched:
                        livenessSnapshot.uniqueBytesFetched,
                    lastMeaningfulProgressUptimeSeconds:
                        ProcessInfo.processInfo.systemUptime,
                    nextRetryUptimeSeconds: nil
                )
                return value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let typed = failure(stage: stage, error: error)
                if let pendingRetry {
                    publishRecovery(
                        failure: pendingRetry.0,
                        action: pendingRetry.1,
                        from: activeRoute,
                        to: activeRoute,
                        outcome: .failed
                    )
                }
                pendingRetry = nil
                beginRecoveryEpisodeIfNeeded(typed)
                let isRetryable = typed.kind == .transientTransport
                    || typed.kind == .inconclusiveEvidence
                guard isRetryable else {
                    throw typed
                }
                transportLivenessAttempt += 1
                let transportAttempt =
                    transportRetryBudget.recordRetryableFailure()
                let delay = recoveryBudget.livenessPolicy
                    .retryBackoffSeconds(
                        forAttempt: transportLivenessAttempt
                    )
                let action =
                    AetherPlaybackRecoveryAction
                        .retrySameOperation(
                            afterSeconds: delay
                        )
                recoveryCoordinator.recordAttempt(action)
                publishRecovery(
                    failure: typed,
                    action: action,
                    from: activeRoute,
                    to: activeRoute,
                    outcome: .scheduled
                )
                pendingRetry = (typed, action)
                let nextRetry =
                    ProcessInfo.processInfo.systemUptime + delay
                publishLiveness(
                    phase: .retryScheduled,
                    attempt: max(
                        transportLivenessAttempt,
                        transportAttempt
                    ),
                    uniqueBytesFetched:
                        livenessSnapshot.uniqueBytesFetched,
                    lastMeaningfulProgressUptimeSeconds:
                        livenessSnapshot
                            .lastMeaningfulProgressUptimeSeconds,
                    nextRetryUptimeSeconds: nextRetry
                )
                try await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
            }
        }
    }

    private func operationDeadline(
        stage: AetherPlaybackRecoveryStage
    ) throws -> (timeout: TimeInterval, failure: AetherPlaybackFailure) {
        let timeout = recoveryBudget.livenessPolicy
            .noProgressWindowSeconds(
                forAttempt: max(
                    1,
                    transportLivenessAttempt + 1
                )
            )
        let failure = Self.operationDeadlineFailure(
            stage: stage,
            seconds: timeout
        )
        return (timeout, failure)
    }

    nonisolated static func operationDeadlineFailure(
        stage: AetherPlaybackRecoveryStage,
        seconds: TimeInterval
    ) -> AetherPlaybackFailure {
        let kind: AetherPlaybackFailureKind = switch stage {
        case .classification, .preflight, .origin:
            .transientTransport
        case .routeCreation, .preparation, .playback,
             .decoder, .presentation:
            .routeRuntimeFailure
        }
        return AetherPlaybackFailure(
            stage: stage,
            kind: kind,
            domain: "AetherPlaybackOperationDeadline",
            code: Int(seconds.rounded(.up)),
            caseCode: "operation.deadlineExceeded",
            reason: "aether.operation.deadlineExceeded"
        )
    }

    nonisolated static func seekTimeoutFailure(
        seconds: TimeInterval
    ) -> AetherPlaybackFailure {
        AetherPlaybackFailure(
            stage: .playback,
            kind: .transientTransport,
            domain: "AetherPlaybackSeekDeadline",
            code: Int(seconds.rounded(.up)),
            caseCode: "seekTimedOut",
            reason: "aether.seek.noProgress"
        )
    }

    /// Restoring the committed route can wait on transport-backed track or
    /// player work. An elapsed no-progress window therefore requests another
    /// same-source generation; it is never structural exhaustion by itself.
    nonisolated static func recoveryContextNoProgressFailure(
        stage: AetherPlaybackRecoveryStage,
        seconds: TimeInterval
    ) -> AetherPlaybackFailure {
        AetherPlaybackFailure(
            stage: stage,
            kind: .transientTransport,
            domain: "AetherPlaybackRecoveryContext",
            code: Int(seconds.rounded(.up)),
            caseCode: "startupNoProgress",
            reason: "aether.recovery.context.noProgress"
        )
    }

    private func failure(
        stage: AetherPlaybackRecoveryStage,
        error: Error
    ) -> AetherPlaybackFailure {
        if let failure = error as? AetherPlaybackFailure {
            return failure
        }
        if error is CancellationError {
            return AetherPlaybackFailure(
                stage: stage,
                kind: .cancelled,
                domain: "CancellationError",
                code: 0,
                reason: "Playback operation was cancelled"
            )
        }
        if error is AetherNativePlaybackSessionError,
           !Self.isNativeSeekTimeout(error),
           let evidence = activeSession?.nativeFailureEvidence {
            return Self.nativeFailure(
                stage: stage,
                evidence: evidence
            )
        }
        if let hybrid = error as? HybridPlaybackSessionError,
           case .originFailed(let origin) = hybrid {
            let originKind: AetherPlaybackFailureKind
            switch origin.scope {
            case .transient:
                originKind = .transientTransport
            case .authentication:
                originKind = .authenticationRejected
            case .security:
                originKind = .securityBoundary
            case .graphInvalidated, .resource:
                originKind = .routeRuntimeFailure
            case .malformed:
                originKind = .malformedMedia
            case .cancelled:
                originKind = .cancelled
            case .invariant:
                originKind = .invariantViolation
            }
            return AetherPlaybackFailure(
                stage: .origin,
                kind: originKind,
                domain: origin.underlyingDomain,
                code: origin.underlyingCode,
                reason: "hybrid.origin.\(origin.caseCode)"
            )
        }
        if let hybrid = error as? HybridPlaybackSessionError {
            let evidence: HybridPlaybackFailureEvidence?
            switch hybrid {
            case .providerFailed(let value),
                 .carrierFailed(let value):
                evidence = value
            default:
                evidence = nil
            }
            if let evidence {
                return Self.hybridFailure(evidence: evidence)
            }
        }

        let kind: AetherPlaybackFailureKind
        switch error {
        case let error as AetherURLPlaybackSourceClassificationError:
            kind = Self.classify(error)
        case let error as HLSPreflightError:
            kind = Self.classify(error)
        case let error as HybridPlaybackSessionError:
            kind = Self.classify(error)
        case let error as DemuxerError:
            kind = Self.classify(
                error,
                sourceIsCompleteAndValidatorBound:
                    activeSession != nil
                    && (resolvedSource?
                        .progressiveSourceIsCompleteAndValidatorBound
                        ?? false)
            )
        case let error as AVIOReaderError:
            return Self.nativeFailure(
                stage: stage,
                evidence: AetherNativePlaybackSession
                    .failureEvidence(
                        error: error,
                        caseCode: "engineSourceRead"
                    )
            )
        case let error as AetherNativePlaybackSessionError:
            kind = Self.classify(error)
        case let error as
                AetherProgressiveProResSegmentPolicyError:
            kind = Self.classify(error)
        case let error as AetherPlaybackSessionError:
            switch error {
            case .unsupported: kind = .unsupportedCapability
            case .recoveryDeadlineExceeded:
                kind = .routeRuntimeFailure
            case .invalidFactorySource, .invalidState,
                 .noActiveRoute, .terminal:
                kind = .invariantViolation
            }
        default:
            let urlError = error as? URLError
            kind = urlError == nil
                ? .routeRuntimeFailure
                : .transientTransport
        }
        let nsError = error as NSError
        let code = (error as? DemuxerError)
            .map { Int($0.ffmpegCode) }
            ?? nsError.code
        let caseCode: String? = switch error {
        case let error as AetherURLPlaybackSourceClassificationError:
            Self.failureCaseCode(error)
        case let error as DemuxerError:
            Self.failureCaseCode(error)
        case let error as AetherNativePlaybackSessionError:
            Self.failureCaseCode(error)
        case let error as
                AetherProgressiveProResSegmentPolicyError:
            Self.failureCaseCode(error)
        default:
            nil
        }
        return AetherPlaybackFailure(
            stage: stage,
            kind: kind,
            domain: String(reflecting: type(of: error)),
            code: code,
            caseCode: caseCode,
            reason: Self.redactedReason(
                kind: kind,
                stage: stage,
                error: error
            )
        )
    }

    nonisolated static func initialPreparationFailureStage(
        hasInstalledRoute: Bool
    ) -> AetherPlaybackRecoveryStage {
        hasInstalledRoute ? .preparation : .preflight
    }

    nonisolated static func nativeFailure(
        stage: AetherPlaybackRecoveryStage,
        evidence: AetherNativePlaybackFailureEvidence
    ) -> AetherPlaybackFailure {
        if let pretypedFailure =
                evidence.pretypedFailure {
            return pretypedFailure
        }
        let kind: AetherPlaybackFailureKind = switch evidence.category {
        case .transientTransport: .transientTransport
        case .authentication: .authenticationRejected
        case .security: .securityBoundary
        case .unsupportedCapability: .unsupportedCapability
        case .decoder: .decoderRuntimeFailure
        case .malformed: .malformedMedia
        case .routeRuntime: .routeRuntimeFailure
        case .cancelled: .cancelled
        case .invariant: .invariantViolation
        }
        let caseCode = "native.\(evidence.caseCode)"
        return AetherPlaybackFailure(
            stage: stage,
            kind: kind,
            domain: evidence.domain,
            code: evidence.code,
            caseCode: caseCode,
            reason: caseCode
        )
    }

    /// Converts the actual Native state callback into recovery evidence. Keep
    /// this path closed over the same machine code used by preparation so a
    /// positively observed HEVC item cannot fall through to a Native rebuild.
    nonisolated static func nativeRuntimeFailure(
        fallback: AetherNativePlaybackSessionFailure,
        evidence: AetherNativePlaybackFailureEvidence?
    ) -> AetherPlaybackFailure {
        guard let evidence else {
            return AetherPlaybackFailure(
                stage: .playback,
                kind: .routeRuntimeFailure,
                domain: "AetherNativePlaybackSessionFailure",
                code: 0,
                reason: fallback.rawValue
            )
        }
        return nativeFailure(stage: .playback, evidence: evidence)
    }

    /// Preserves provider/carrier closed case codes through the unified
    /// Aether terminal and recovery history boundary.
    nonisolated static func hybridFailure(
        evidence: HybridPlaybackFailureEvidence
    ) -> AetherPlaybackFailure {
        let stage: AetherPlaybackRecoveryStage = switch evidence.stage {
        case .routeCreation: .routeCreation
        case .preparation: .preparation
        case .seek, .runtime, .provider, .carrier: .playback
        }
        let kind: AetherPlaybackFailureKind = switch evidence.category {
        case .routeRuntime: .routeRuntimeFailure
        case .transientTransport: .transientTransport
        case .authentication: .authenticationRejected
        case .security: .securityBoundary
        case .unsupportedCapability: .unsupportedCapability
        case .malformedMedia: .malformedMedia
        case .cancelled: .cancelled
        case .invariant: .invariantViolation
        }
        return AetherPlaybackFailure(
            stage: stage,
            kind: kind,
            domain: evidence.underlyingDomain,
            code: evidence.underlyingCode,
            caseCode: publicHybridCaseCode(evidence.caseCode),
            recoveryTrigger: evidence.recoveryTrigger,
            recoveryStep: evidence.recoveryStep,
            reason: "hybrid.\(evidence.stage.rawValue).\(evidence.caseCode)"
        )
    }

    /// Only closed, documented Hybrid cases cross the public Aether/host
    /// boundary. Internal provider labels remain redacted diagnostics.
    nonisolated static func publicHybridCaseCode(
        _ caseCode: String
    ) -> String? {
        switch caseCode {
        case "progressive.audioMuxer.emptySegment",
             "progressive.audioMuxer.bridgeCapabilityUnavailable",
             "progressive.audioStore.muxer.bridgeCapabilityUnavailable",
             "videoDecoder.pixelBufferConversionFailed",
             "progressive.videoDecoder.pixelBufferConversionFailed",
             "seekTimedOut",
             "presentationRebuildTimedOut",
             "progressive.avio.allocationFailed",
             "progressive.avio.noResponse",
             "progressive.avio.requestTimeout",
             "progressive.avio.httpStatus",
             "progressive.sourceByteStore.invalidCapacity",
             "progressive.sourceByteStore.invalidGeneration",
             "progressive.sourceByteStore.generationMismatch",
             "progressive.sourceByteStore.unsupportedContentEncoding",
             "progressive.sourceByteStore.invalidRange",
             "progressive.sourceByteStore.cancelled",
             "progressive.sourceByteStore.rangeFetchFailed",
             "progressive.sourceByteStore.rangeFetchRateLimited",
             "progressive.sourceByteStore.closed",
             "progressive.sourceByteStore.directoryCreationFailed",
             "progressive.sourceByteStore.blockOpenFailed",
             "progressive.sourceByteStore.blockReadFailed",
             "progressive.sourceByteStore.blockWriteFailed",
             "progressive.sourceByteStore.validationFailed",
             "progressive.demux.openFailed",
             "progressive.demux.streamInfoFailed",
             "progressive.demux.readFailed":
            caseCode
        default: nil
        }
    }

    nonisolated static func classify(
        _ error: AetherURLPlaybackSourceClassificationError
    ) -> AetherPlaybackFailureKind {
        switch error {
        case .emptyResource, .transport:
            .transientTransport
        case .httpStatus(let status):
            if status == 401 || status == 403 {
                .authenticationRejected
            } else if status == 408 || status == 425
                        || status == 429 || status >= 500 {
                .transientTransport
            } else {
                .malformedMedia
            }
        case .redirectCredentialScopeViolation:
            .securityBoundary
        case .dependencyCapabilityUnavailable:
            .unsupportedCapability
        case .nonMediaPayload:
            .malformedMedia
        case .unsupportedURLScheme, .unreadableFile,
             .nonHTTPResponse, .unsupportedContentEncoding,
             .sourceIdentityChanged:
            .invariantViolation
        }
    }

    nonisolated static func classify(
        _ error: DemuxerError,
        sourceIsCompleteAndValidatorBound: Bool = false
    ) -> AetherPlaybackFailureKind {
        switch error.ffmpegCode {
        case FFmpegErr.invalidData, FFmpegErr.eof:
            sourceIsCompleteAndValidatorBound
                ? .malformedMedia
                : .transientTransport
        case -5, FFmpegErr.eagain:
            // Aether's AVIO boundary reports exhausted I/O as EIO. EAGAIN is
            // likewise transport availability, not evidence that the media
            // bytes themselves are malformed.
            .transientTransport
        default:
            // Preserve ambiguous FFmpeg failures as Aether-owned runtime
            // evidence instead of guessing that the upstream bytes are bad.
            .routeRuntimeFailure
        }
    }

    nonisolated static func classify(
        _ error: AetherNativePlaybackSessionError
    ) -> AetherPlaybackFailureKind {
        switch error {
        case .seekTimedOut:
            .transientTransport
        case .preflightRequiresNative, .assetNotPlayable,
             .itemFailed:
            .routeRuntimeFailure
        case .expectedVideoTrackMissing,
             .videoTrackInspectionInconclusive,
             .observedHEVCRequiresHybrid,
             .seekDidNotApply:
            .routeRuntimeFailure
        case .audioAnalysisBindingSourceMismatch,
             .nativeRemuxRequiresPreparedSource,
             .incompatibleRemuxOptions,
             .sourceFactsDiverged,
             .engineRouteContractDiverged,
             .unexpectedVideoTrack,
             .stopped, .invalidRate, .invalidSeekTarget:
            .invariantViolation
        }
    }

    nonisolated static func classify(
        _ error: AetherProgressiveProResSegmentPolicyError
    ) -> AetherPlaybackFailureKind {
        _ = error
        return .unsupportedCapability
    }

    nonisolated static func isNativeSeekTimeout(
        _ error: Error
    ) -> Bool {
        guard let native =
                error as? AetherNativePlaybackSessionError else {
            return false
        }
        if case .seekTimedOut = native {
            return true
        }
        return false
    }

    nonisolated static func failureCaseCode(
        _ error: AetherURLPlaybackSourceClassificationError
    ) -> String? {
        switch error {
        case .nonMediaPayload(let family):
            "classification.nonMediaPayload.\(family.rawValue)"
        case .dependencyCapabilityUnavailable(
            .libavformatASFDemuxer
        ):
            "dependency.libavformat.asfDemuxerUnavailable"
        case .sourceIdentityChanged:
            "classification.sourceIdentityChanged"
        default:
            nil
        }
    }

    nonisolated static func failureCaseCode(
        _ error: DemuxerError
    ) -> String {
        switch error {
        case .openFailed:
            "demux.openFailed"
        case .streamInfoFailed:
            "demux.streamInfoFailed"
        case .readFailed:
            "demux.readFailed"
        }
    }

    nonisolated static func failureCaseCode(
        _ error: AetherNativePlaybackSessionError
    ) -> String? {
        switch error {
        case .seekTimedOut:
            "native.seekTimedOut"
        case .itemFailed:
            "native.itemFailed"
        default:
            nil
        }
    }

    nonisolated static func failureCaseCode(
        _ error: AetherProgressiveProResSegmentPolicyError
    ) -> String {
        switch error {
        case .durationOutsideTimelineRange:
            "progressiveProRes.timelineDurationUnsupported"
        case .segmentCountExceedsCapacity:
            "progressiveProRes.segmentPlanCapacityExceeded"
        }
    }

    private static func classify(
        _ error: HLSPreflightError
    ) -> AetherPlaybackFailureKind {
        switch error {
        case .transportFailure, .contentLengthMismatch:
            .transientTransport
        case .httpStatus(let status):
            if status == 401 || status == 403 {
                .authenticationRejected
            } else if status == 408 || status == 425
                        || status == 429 || status >= 500 {
                .transientTransport
            } else {
                .malformedMedia
            }
        case .redirectCredentialScopeViolation:
            .securityBoundary
        case .unsupportedSeekableVODResourceGraph,
             .selectedVariantWasNotMediaPlaylist:
            .inconclusiveEvidence
        case .requestedVariantNotFound(
            "next-lower-compatible"
        ):
            .inconclusiveEvidence
        case .invalidPlaylist, .unresolvableURI,
             .requestedVariantNotFound,
             .seekableVODPlaylistNotFinite,
             .resourceTooLarge,
             .unsupportedContentEncoding,
             .nonHTTPResponse:
            .malformedMedia
        }
    }

    private static func classify(
        _ error: HybridPlaybackSessionError
    ) -> AetherPlaybackFailureKind {
        switch error {
        case .providerFailed, .carrierFailed, .readinessFailed,
             .readinessTimedOut,
             .carrierSeekDidNotLand:
            .routeRuntimeFailure
        case .originFailed(let failure):
            switch failure.scope {
            case .transient: .transientTransport
            case .authentication: .authenticationRejected
            case .security: .securityBoundary
            case .graphInvalidated, .resource:
                .routeRuntimeFailure
            case .malformed: .malformedMedia
            case .cancelled: .cancelled
            case .invariant: .invariantViolation
            }
        case .decoderFailed:
            .decoderRuntimeFailure
        case .presentationFailed(let error):
            PlaybackFailureEvidenceDecision.kind(for: error)
        case .hlsPreflightGenerationInvalidated(let reason):
            switch reason {
            case .resourceUnavailable, .contentChanged:
                .routeRuntimeFailure
            case .credentialRejected:
                .authenticationRejected
            case .effectiveOriginChanged,
                 .credentialScopeChanged:
                .securityBoundary
            }
        case .carrierPresentationNotConfigured,
             .carrierPresentationConfigurationTooLate,
             .carrierPresentationContractChanged:
            .hostContractViolation
        case .cancelled:
            .cancelled
        case .videoPipelineMissing, .audioPipelineMissing:
            .unsupportedCapability
        case .carrierItemMissing, .carrierClockUnavailable,
             .resumeIntentMissing, .generationDiverged,
             .sourceVideoFormatDiverged,
             .sourceDolbyVisionConfigurationDiverged:
            .routeRuntimeFailure
        case .renderSurfaceMissing,
             .invalidSeekableVODOptions,
             .sourceIndependentReaderUnavailable,
             .progressiveSourceFactsDiverged,
             .hlsPreflightRequired,
             .hlsPreflightResourceGraphMissing,
             .sourceKindMismatch, .timelineSourceMismatch,
             .preflightRequiresHybrid,
             .preflightContractChanged,
             .invalidReadinessTimeout, .invalidSeekTarget,
             .invalidRate, .notReady, .alreadyPreparing,
             .alreadyStopped:
            .invariantViolation
        }
    }

    private static func redactedReason(
        kind: AetherPlaybackFailureKind,
        stage: AetherPlaybackRecoveryStage,
        error: Error
    ) -> String {
        switch error {
        case let error as AetherPlaybackSessionError:
            return error.localizedDescription
        case let error as AetherNativePlaybackSessionError:
            return error.localizedDescription
        case let error as HybridPlaybackSessionError:
            return hybridFailureCode(error)
        case is HLSPreflightError:
            return "HLS preflight failed (\(kind.rawValue))"
        case let error as AetherURLPlaybackSourceClassificationError:
            return error.localizedDescription
        case is DemuxerError:
            return "Media demux \(stage.rawValue) failed (\(kind.rawValue))"
        default:
            return "Playback \(stage.rawValue) failed (\(kind.rawValue))"
        }
    }

    private static func hybridFailureCode(
        _ error: HybridPlaybackSessionError
    ) -> String {
        switch error {
        case .providerFailed:
            return "hybrid.provider.failed"
        case .originFailed(let failure):
            return "hybrid.origin.\(failure.caseCode)"
        case .carrierFailed:
            return "hybrid.carrier.failed"
        case .decoderFailed:
            return "hybrid.decoder.failed"
        case .readinessFailed:
            return "hybrid.readiness.failed"
        case .readinessTimedOut:
            return "hybrid.readiness.timeout"
        case .carrierSeekDidNotLand:
            return "hybrid.carrier.seekDidNotLand"
        case .generationDiverged:
            return "hybrid.operation.generationDiverged"
        case .progressiveSourceFactsDiverged:
            return "hybrid.source.factsDiverged"
        case .cancelled:
            return "hybrid.operation.cancelled"
        case .hlsPreflightGenerationInvalidated(let reason):
            return PlaybackFailureEvidenceDecision
                .hlsGraphFailureCode(reason)
        case .presentationFailed(let error):
            switch error {
            case .invalidPresentationTime, .invalidFrameDuration,
                 .invalidGeometry, .unsupportedRotation,
                 .frameFormatDiverged,
                 .nonMonotonicPresentationTime:
                return "hybrid.presentation.mediaDivergence.\(String(reflecting: type(of: error)))"
            case .pixelBufferNotIOSurfaceBacked:
                return "hybrid.presentation.iosurfaceUnavailable"
            case .carrierBindingChanged:
                return "hybrid.presentation.carrierBindingDrift"
            case .rendererStalled:
                return "hybrid.presentation.rendererStalled"
            case .pendingQueueOverflow:
                return "hybrid.presentation.legacyQueueOverflow"
            default:
                return "hybrid.presentation.resourceFailure"
            }
        default:
            return "hybrid.session.\(String(reflecting: type(of: error)))"
        }
    }

    private func beginRecoveryEpisodeIfNeeded(
        _ failure: AetherPlaybackFailure
    ) {
        recoveryCoordinator.begin(
            with: failure,
            now: ProcessInfo.processInfo.systemUptime
        )
        firstFailure = recoveryCoordinator.sessionFirstFailure
    }

    private func resetRecoveryEpisode(
        beginProgressEpoch: Bool = true
    ) {
        recoveryCoordinator.resetEpisode(
            now: ProcessInfo.processInfo.systemUptime
        )
        recoveryLogCadence.resetAfterProgress()
        if beginProgressEpoch {
            playbackProgressEpoch.begin()
        }
        mergedRuntimeFailureKeys.removeAll(keepingCapacity: true)
        lastRecoveryFailure = nil
        transportRetryBudget.reset()
    }

    nonisolated static func isPermanentFailure(
        _ kind: AetherPlaybackFailureKind
    ) -> Bool {
        switch kind {
        case .unsupportedCapability, .authenticationRejected,
             .securityBoundary, .malformedMedia,
             .hostContractViolation, .invariantViolation:
            true
        case .transientTransport, .inconclusiveEvidence,
             .routeRuntimeFailure, .decoderRuntimeFailure,
             .cancelled:
            false
        }
    }

    private func observeHealthyProgress(_ time: CMTime) {
        guard time.isValid,
              time.isNumeric,
              time.seconds.isFinite else {
            return
        }
        let previousTime = lastConfirmedMediaTime
        lastConfirmedMediaTime = time
        if previousTime.isValid,
           previousTime.isNumeric,
           previousTime.seconds.isFinite,
           time.seconds > previousTime.seconds {
            transportLivenessAttempt = 0
            publishLiveness(
                phase: .flowing,
                attempt: 0,
                uniqueBytesFetched:
                    livenessSnapshot.uniqueBytesFetched,
                lastMeaningfulProgressUptimeSeconds:
                    ProcessInfo.processInfo.systemUptime,
                nextRetryUptimeSeconds: nil
            )
        }
        let demonstratedHealthyProgress = playbackProgressEpoch.observe(
            seconds: time.seconds,
            eligible: desiredPlaying
                && state == .playing
                && !isPreparingOrRecovering,
            requiredProgressSeconds:
                recoveryBudget.healthyProgressResetSeconds
        )
        guard demonstratedHealthyProgress else {
            return
        }
        resetRecoveryEpisode(beginProgressEpoch: false)
    }

    private var episodeElapsedSeconds: TimeInterval {
        recoveryCoordinator.elapsedSeconds(
            now: ProcessInfo.processInfo.systemUptime
        )
    }

    private func publishRecovery(
        failure: AetherPlaybackFailure,
        action: AetherPlaybackRecoveryAction,
        from: PlaybackRenderRoute?,
        to: PlaybackRenderRoute?,
        outcome: AetherPlaybackRecoveryOutcome
    ) {
        beginRecoveryEpisodeIfNeeded(failure)
        lastRecoveryFailure = failure
        eventSequence += 1
        let capabilityDelta:
            AetherPlaybackCapabilityDelta?
        if outcome == .scheduled {
            capabilitiesBeforeRecoveryAttempt = Self
                .committedRecoveryCapabilityBaseline(
                    didCompleteInitialPrepare:
                        didCompleteInitialPrepare,
                    activeRoute: activeRoute,
                    fromRoute: from,
                    capabilities: capabilities
                )
            capabilityDelta = nil
        } else if outcome != .merged,
                  let before = capabilitiesBeforeRecoveryAttempt {
            capabilityDelta = AetherPlaybackCapabilityDelta(
                before: before,
                after: capabilities
            )
            capabilitiesBeforeRecoveryAttempt = nil
        } else {
            capabilityDelta = nil
        }
        let event = AetherPlaybackRecoveryEvent(
            sequence: eventSequence,
            episodeID: recoveryCoordinator.episodeID,
            attempt: recoveryCoordinator.attemptCount,
            fromRoute: from,
            toRoute: to,
            failure: failure,
            action: action,
            outcome: outcome,
            capabilityDelta: capabilityDelta
        )
        recoveryHistory.append(event)
        if recoveryHistory.count > 64 {
            recoveryHistory.removeFirst(
                recoveryHistory.count - 64
            )
        }
        state = .recovering(event)
        if let emission = recoveryLogCadence.recordFailure(
            now: ProcessInfo.processInfo.systemUptime
        ) {
            let firstFailure = recoveryCoordinator.episodeFirstFailure
                ?? failure
            let checkpoint = emission.checkpointSeconds.map {
                String(Int($0))
            } ?? "first"
            EngineLog.emit(
                "[AetherPlaybackSession] recovery checkpoint=\(checkpoint) "
                    + "elapsed=\(Int(emission.elapsedSeconds)) "
                    + "firstStage=\(firstFailure.stage.rawValue) "
                    + "firstKind=\(firstFailure.kind.rawValue) "
                    + "cumulative=\(emission.cumulativeFailureCount) "
                    + "sequence=\(event.sequence) "
                    + "attempt=\(event.attempt) "
                    + "from=\(from?.rawValue ?? "none") "
                    + "to=\(to?.rawValue ?? "none") "
                    + "kind=\(failure.kind.rawValue) "
                    + "capabilityChanged=\(capabilityDelta.map { $0.before != $0.after } ?? false) "
                    + "outcome=\(outcome.rawValue)",
                category: .session
            )
        }
    }

    private func publishTerminal(
        _ failure: AetherPlaybackFailure
    ) {
        publishTerminal(
            failure,
            finalFailure: failure,
            exhaustionReason: terminalExhaustionReason(for: failure)
        )
    }

    private func publishTerminal(
        _ firstCandidate: AetherPlaybackFailure,
        finalFailure: AetherPlaybackFailure,
        exhaustionReason: String
    ) {
        guard !isStopped,
              recoveryCoordinator.claimTerminalOutcome() else {
            return
        }
        let original = recoveryCoordinator.sessionFirstFailure
            ?? firstFailure
            ?? firstCandidate
        firstFailure = original
        terminalFailure = AetherPlaybackTerminalFailure(
            firstFailure: original,
            finalFailure: finalFailure,
            exhaustionReason: exhaustionReason
        )
        livenessDiagnosticTask?.cancel()
        livenessDiagnosticTask = nil
        progressiveLivenessObservationTask?.cancel()
        progressiveLivenessObservationTask = nil
        publishLiveness(
            phase: .failed,
            attempt: livenessSnapshot.attempt,
            uniqueBytesFetched:
                livenessSnapshot.uniqueBytesFetched,
            lastMeaningfulProgressUptimeSeconds:
                livenessSnapshot
                    .lastMeaningfulProgressUptimeSeconds,
            nextRetryUptimeSeconds: nil
        )
        teardownActiveRoute()
        EngineLog.emit(
            "[AetherPlaybackSession] terminal "
                + "session=\(sessionID.uuidString.prefix(8)) "
                + "source=\(sourceFingerprint) "
                + "first=\(original.kind.rawValue) "
                + "final=\(finalFailure.kind.rawValue) "
                + "attempts=\(recoveryCoordinator.attemptCount) "
                + "reason=\(exhaustionReason)",
            category: .session
        )
        state = .failed(finalFailure)
    }

    private func terminalExhaustionReason(
        for failure: AetherPlaybackFailure
    ) -> String {
        switch failure.kind {
        case .authenticationRejected:
            return "authorization rejected"
        case .securityBoundary:
            return "security boundary"
        case .hostContractViolation:
            return "host presentation contract violated"
        case .unsupportedCapability:
            return "positive capability boundary"
        case .malformedMedia:
            return "positive corrupt media evidence"
        case .cancelled:
            return "operation cancelled without successor"
        case .invariantViolation:
            return "required playback invariant failed"
        case .transientTransport, .inconclusiveEvidence,
             .routeRuntimeFailure, .decoderRuntimeFailure:
            return "bounded recovery exhausted"
        }
    }

    private func teardownActiveRoute() {
        let session = detachActiveRouteForTeardown()
        guard let session else { return }
        // Begin cancellation immediately, then retain an engine-owned release
        // fence. Any later source resolution or route construction awaits this
        // task before it can admit another reader.
        session.stop()
        let predecessor = routeIOQuiescenceTask
        routeIOQuiescenceGeneration &+= 1
        let generation = routeIOQuiescenceGeneration
        routeIOQuiescenceTask = Task { @MainActor in
            await predecessor?.value
            await session.stopAndWaitForIOQuiescence()
            EngineLog.emit(
                "[AetherPlaybackSession] route ioStopped "
                    + "generation=\(generation)",
                category: .session
            )
        }
    }

    private func teardownActiveRouteAndWaitForIOQuiescence()
        async
    {
        teardownActiveRoute()
        await waitForPendingRouteIOQuiescence()
    }

    private func waitForPendingRouteIOQuiescence() async {
        while let task = routeIOQuiescenceTask {
            let generation = routeIOQuiescenceGeneration
            await task.value
            if routeIOQuiescenceGeneration == generation {
                routeIOQuiescenceTask = nil
            }
        }
    }

    private func beginIOOwnershipOperation() {
        pendingIOOwnershipOperationCount += 1
    }

    private func endIOOwnershipOperation() {
        precondition(pendingIOOwnershipOperationCount > 0)
        pendingIOOwnershipOperationCount -= 1
        guard pendingIOOwnershipOperationCount == 0 else {
            return
        }
        let waiters = ioOwnershipQuiescenceWaiters
        ioOwnershipQuiescenceWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForIOOwnershipOperationsToQuiesce()
        async
    {
        guard pendingIOOwnershipOperationCount > 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            ioOwnershipQuiescenceWaiters.append(
                continuation
            )
        }
    }

    private func detachActiveRouteForTeardown()
        -> AetherActiveRouteSession?
    {
        cancelTransportMonitoring()
        transportRouteGeneration &+= 1
        routeTransactions.invalidate()
        routeCancellables.removeAll()
        routePreparationRetryProjection.reset()
        let session = activeSession
        session?.cancelAudioAnalysisStreams()
        activeSession = nil
        transportTestRoute = nil
        restoreRouteNeutralPlayerCapabilities()
        invalidateVideoOutputRoute()
        presentationView.install(nil)
        return session
    }

    private func restoreRouteNeutralPlayerCapabilities() {
        avPlayer.allowsExternalPlayback =
            routeNeutralAllowsExternalPlayback
        #if os(iOS) || os(tvOS)
        avPlayer.usesExternalPlaybackWhileExternalScreenIsActive =
            routeNeutralUsesExternalPlaybackWhileExternalScreenIsActive
        #endif
    }

    private func publishCurrentItem(
        _ item: AVPlayerItem?
    ) {
        currentItem = item
        #if os(tvOS) || os(iOS)
        if let item, !externalMetadata.isEmpty {
            item.externalMetadata = externalMetadata
        }
        #endif
    }

    private func publishCapabilities() {
        capabilities = Self.capabilities(
            for: activeSession,
            source: resolvedSource
        )
    }

    private func publishTrackState(
        from session: AetherActiveRouteSession
    ) {
        audioTracks = session.audioTracks
        subtitleTracks = session.subtitleTracks
        selectedAudioTrackID =
            session.selectedAudioTrackIdentifier
        selectedSubtitleTrackID =
            session.selectedSubtitleTrackIdentifier
    }

    private static func capabilities(
        for session: AetherActiveRouteSession?,
        source: AetherResolvedPlaybackSource?
    ) -> AetherPlaybackCapabilities {
        let nativePolicy = HybridPlaybackSystemFeaturePolicy(
            pictureInPictureVideo: .available,
            airPlayVideo: .available,
            externalDisplayVideo: .available
        )
        switch session {
        case .native(let native):
            let tracks = AetherActiveRouteSession
                .native(native)
            return AetherPlaybackCapabilities(
                route: .nativeAVPlayer,
                systemFeaturePolicy: nativePolicy,
                audioAnalysisTrackIDs:
                    native.audioAnalysisTrackIDs,
                selectedAudioAnalysisTrackID:
                    native.selectedAudioAnalysisTrackID,
                videoFormat:
                    native.preflightResult.sourceProfile.videoFormat,
                dolbyVisionProfile: native.preflightResult
                    .sourceProfile.dolbyVisionConfiguration
                    .map { Int($0.profile) },
                variantBitrate: selectedVariantBitrate(source),
                audioTracks: tracks.audioTracks,
                subtitleTracks: tracks.subtitleTracks,
                selectedAudioTrackID:
                    tracks.selectedAudioTrackIdentifier,
                selectedSubtitleTrackID:
                    tracks.selectedSubtitleTrackIdentifier
            )
        case .hybrid(let hybrid):
            let tracks = AetherActiveRouteSession
                .hybrid(hybrid)
            return AetherPlaybackCapabilities(
                route: .hybridCarrier,
                systemFeaturePolicy:
                    AetherHybridPlaybackSession.systemFeaturePolicy,
                audioAnalysisTrackIDs:
                    hybrid.audioAnalysisTrackIDs,
                selectedAudioAnalysisTrackID:
                    hybrid.selectedAudioAnalysisTrackID,
                videoFormat:
                    hybrid.preflightResult.sourceProfile.videoFormat,
                dolbyVisionProfile: hybrid.preflightResult
                    .sourceProfile.dolbyVisionConfiguration
                    .map { Int($0.profile) },
                variantBitrate: selectedVariantBitrate(source),
                audioTracks: tracks.audioTracks,
                subtitleTracks: tracks.subtitleTracks,
                selectedAudioTrackID:
                    tracks.selectedAudioTrackIdentifier,
                selectedSubtitleTrackID:
                    tracks.selectedSubtitleTrackIdentifier
            )
        case nil:
            return AetherPlaybackCapabilities(
                route: nil,
                systemFeaturePolicy:
                    AetherHybridPlaybackSession.systemFeaturePolicy,
                audioAnalysisTrackIDs: [],
                selectedAudioAnalysisTrackID: nil,
                videoFormat: nil,
                dolbyVisionProfile: nil,
                variantBitrate: nil,
                audioTracks: [],
                subtitleTracks: [],
                selectedAudioTrackID: nil,
                selectedSubtitleTrackID: nil
            )
        }
    }

    private static func selectedVariantBitrate(
        _ source: AetherResolvedPlaybackSource?
    ) -> Int? {
        guard case .hls(let preflight) = source else {
            return nil
        }
        return preflight.selectedVariantBandwidth
    }

    #if os(tvOS)
    private func configure(
        _ session: AetherActiveRouteSession,
        controller: AVPlayerViewController,
        realVideoGravity: AetherHybridVideoGravity
    ) throws {
        switch session {
        case .native(let native):
            try native.configurePlayerViewController(controller)
            controller.allowsPictureInPicturePlayback = true
        case .hybrid(let hybrid):
            try hybrid.configureCarrierPlayerViewController(
                controller,
                realVideoGravity: realVideoGravity
            )
            controller.allowsPictureInPicturePlayback = false
        }
    }
    #endif
}
