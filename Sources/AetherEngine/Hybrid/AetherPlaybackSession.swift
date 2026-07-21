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

@MainActor
private enum AetherActiveRouteSession {
    case native(AetherNativePlaybackSession)
    case hybrid(AetherHybridPlaybackSession)

    var route: PlaybackRenderRoute {
        switch self {
        case .native: .nativeAVPlayer
        case .hybrid: .hybridCarrier
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

    func prepare() async throws {
        switch self {
        case .native(let session): try await session.prepare()
        case .hybrid(let session): try await session.prepare()
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
}

@MainActor
private enum AetherResolvedPlaybackSource {
    case hls(AetherHLSPlaybackPreflight)
    case progressive(
        probe: SourceProbe,
        result: PlaybackPreflightResult,
        preparedSource: AetherPreparedURLSource?
    )
    case provisionalNative(PlaybackPreflightResult)

    var result: PlaybackPreflightResult {
        switch self {
        case .hls(let preflight): preflight.result
        case .progressive(_, let result, _): result
        case .provisionalNative(let result): result
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

    func admitting(
        route: PlaybackRenderRoute
    ) -> AetherResolvedPlaybackSource? {
        if result.route == route { return self }
        guard let alternate = PlaybackPreflight
                .resolveRecoveryAlternate(
                    sourceProfile: result.sourceProfile,
                    hlsPackaging: result.hlsPackaging,
                    excluding: result.route,
                    hybridCapabilities:
                        AetherHybridPlaybackSession.capabilities
                ),
              alternate.route == route else {
            return nil
        }
        switch self {
        case .hls(let preflight):
            return .hls(preflight.replacingResult(alternate))
        case .progressive(let probe, _, let preparedSource):
            return .progressive(
                probe: probe,
                result: alternate,
                preparedSource: preparedSource
            )
        case .provisionalNative:
            return nil
        }
    }

    func alternate(
        excluding route: PlaybackRenderRoute
    ) -> AetherResolvedPlaybackSource? {
        guard let result = PlaybackPreflight
                .resolveRecoveryAlternate(
                    sourceProfile: self.result.sourceProfile,
                    hlsPackaging: self.result.hlsPackaging,
                    excluding: route,
                    hybridCapabilities:
                        AetherHybridPlaybackSession.capabilities
                ) else {
            return nil
        }
        switch self {
        case .hls(let preflight):
            return .hls(preflight.replacingResult(result))
        case .progressive(let probe, _, let preparedSource):
            return .progressive(
                probe: probe,
                result: result,
                preparedSource: preparedSource
            )
        case .provisionalNative:
            return nil
        }
    }
}

private enum AetherNativePlaybackExecutionMode:
    String,
    Sendable,
    Equatable
{
    case directAsset
    case aetherRemux
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

/// Aether-owned playback lifecycle. The host mounts one player and one
/// presentation container; route reconstruction and evidence-backed route
/// transitions remain entirely inside this object.
@MainActor
public final class AetherPlaybackSession: ObservableObject {
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

    private let url: URL
    private let options: LoadOptions
    private let variantSelection: HLSPreflightVariantSelection
    private let recoveryBudget: AetherPlaybackRecoveryBudget
    private var resolvedSource: AetherResolvedPlaybackSource?
    private var activeSession: AetherActiveRouteSession?
    private var activeNativeExecutionMode:
        AetherNativePlaybackExecutionMode?
    private var routeCancellables = Set<AnyCancellable>()
    private var currentItemObservation: NSKeyValueObservation?
    private var healthyProgressObserver: Any?
    private var playbackProgressEpoch = PlaybackProgressEpoch()
    private var lastConfirmedMediaTime: CMTime = .zero
    private var recoveryTask: Task<Void, Never>?
    private var isStopped = false
    private var isPreparingOrRecovering = false
    private var didCompleteInitialPrepare = false
    private var desiredPlaying = false
    private var desiredRate: Float = 1
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
    private var capabilitiesBeforeRecoveryAttempt:
        AetherPlaybackCapabilities?
    private var mergedRuntimeFailureKeys = Set<String>()
    private var lastRecoveryFailure: AetherPlaybackFailure?
    private let transportRetryBudget:
        PlaybackTransportRetryBudget
    private var lowerVariantRecoveryWasAttempted = false
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
        recoveryBudget: AetherPlaybackRecoveryBudget = .production
    ) {
        self.url = url
        self.options = options
        self.variantSelection = variantSelection
        self.recoveryBudget = recoveryBudget
        transportRetryBudget = PlaybackTransportRetryBudget(
            maximumFailureAttempts:
                recoveryBudget.maximumTransportAttempts
        )
        avPlayer = AVPlayer()
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
        state = .preparing
        isPreparingOrRecovering = true
        do {
            let source = try await resolveCanonicalSource(
                allowProvisionalNative: true
            )
            try await installAndPrepare(source)
            await applyCanonicalDefaultTrackIntent()
            didCompleteInitialPrepare = true
            isPreparingOrRecovering = false
            state = .ready
            resetRecoveryEpisode()
        } catch is CancellationError {
            isPreparingOrRecovering = false
            let failure = failure(
                stage: .preparation,
                error: CancellationError()
            )
            publishTerminal(failure)
            throw CancellationError()
        } catch {
            let initialFailure = failure(
                stage: activeRoute == nil ? .preflight : .preparation,
                error: error
            )
            if try await recover(
                from: initialFailure,
                duringInitialPrepare: true
            ) {
                didCompleteInitialPrepare = true
                isPreparingOrRecovering = false
                return
            }
            isPreparingOrRecovering = false
            let terminal = recoveryCoordinator.episodeFirstFailure
                ?? initialFailure
            publishTerminal(
                terminal,
                finalFailure: lastRecoveryFailure ?? initialFailure,
                exhaustionReason: "initial recovery exhausted"
            )
            throw AetherPlaybackSessionError.terminal(terminal)
        }
    }

    public func play() throws {
        guard !isStopped,
              terminalFailure == nil else {
            throw AetherPlaybackSessionError.invalidState
        }
        desiredPlaying = true
        if desiredRate <= 0 { desiredRate = 1 }
        guard !isPreparingOrRecovering else { return }
        guard let activeSession else {
            throw AetherPlaybackSessionError.noActiveRoute
        }
        try activeSession.play()
        if desiredRate != 1 {
            try activeSession.setRate(desiredRate)
        }
        state = .playing
    }

    public func pause() throws {
        guard !isStopped,
              terminalFailure == nil else {
            throw AetherPlaybackSessionError.invalidState
        }
        desiredPlaying = false
        guard !isPreparingOrRecovering else { return }
        guard let activeSession else {
            throw AetherPlaybackSessionError.noActiveRoute
        }
        try activeSession.pause()
        state = .paused
    }

    public func setRate(_ rate: Float) throws {
        guard rate.isFinite, rate >= 0,
              !isStopped,
              terminalFailure == nil else {
            throw AetherPlaybackSessionError.invalidState
        }
        desiredRate = rate == 0 ? max(desiredRate, 1) : rate
        desiredPlaying = rate > 0
        guard !isPreparingOrRecovering else { return }
        guard let activeSession else {
            throw AetherPlaybackSessionError.noActiveRoute
        }
        try activeSession.setRate(rate)
        state = rate == 0 ? .paused : .playing
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
        guard let activeSession else {
            throw AetherPlaybackSessionError.noActiveRoute
        }

        state = .seeking
        activeSeekOperationSequence = operationSequence
        do {
            let result = try await activeSession.seek(
                to: target,
                timeout: try remainingRecoveryOperationTimeout()
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
            lastConfirmedMediaTime = target
            lastAppliedSeekOperationSequence = operationSequence
            desiredSeekTarget = nil
            state = desiredPlaying ? .playing : .paused
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
            let seekFailure = failure(stage: .playback, error: error)
            if try await recover(
                from: seekFailure,
                duringInitialPrepare: false
            ) {
                guard operationCoordinator.isCurrentSeek(operationSequence) else {
                    return .superseded
                }
                lastAppliedSeekOperationSequence = operationSequence
                desiredSeekTarget = nil
                return .applied
            }
            publishTerminal(
                recoveryCoordinator.episodeFirstFailure ?? seekFailure,
                finalFailure: seekFailure,
                exhaustionReason: "seek recovery exhausted"
            )
            throw AetherPlaybackSessionError.terminal(seekFailure)
        }
    }

    public func setExternalMetadata(
        _ metadata: [AVMetadataItem]
    ) {
        externalMetadata = metadata
        #if os(tvOS) || os(iOS)
        currentItem?.externalMetadata = metadata
        #endif
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
            publishTrackState(from: activeSession)
            publishCapabilities()
        } catch {
            let selectionFailure = failure(
                stage: .playback,
                error: error
            )
            if try await recover(
                from: selectionFailure,
                duringInitialPrepare: false
            ) {
                return
            }
            publishTerminal(
                selectionFailure,
                finalFailure: selectionFailure,
                exhaustionReason:
                    "selected audio track could not be restored"
            )
            throw AetherPlaybackSessionError.terminal(
                selectionFailure
            )
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
        publishTrackState(from: activeSession)
        publishCapabilities()
    }

    private func applyCanonicalDefaultTrackIntent() async {
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
        do {
            try await activeSession.selectSubtitleTrack(externalTrack.id)
            desiredSubtitleTrackID = externalTrack.id
            desiredOverlaySubtitleTrackID = externalTrack.sourceTrackID
            publishTrackState(from: activeSession)
            publishCapabilities()
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
        guard !isStopped else { return }
        isStopped = true
        routeTransactions.invalidate()
        recoveryTask?.cancel()
        recoveryTask = nil
        routeCancellables.removeAll()
        activeSession?.stop()
        activeSession = nil
        activeNativeExecutionMode = nil
        presentationView.install(nil)
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        currentItemObservation?.invalidate()
        currentItemObservation = nil
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
        state = .stopped
        #if os(tvOS)
        if playerViewController?.player === avPlayer {
            playerViewController?.player = nil
        }
        playerViewController = nil
        #endif
    }

    private func resolveCanonicalSource(
        allowProvisionalNative: Bool,
        variantSelectionOverride:
            HLSPreflightVariantSelection? = nil
    ) async throws -> AetherResolvedPlaybackSource {
        let sourceSignature: AetherURLPlaybackSourceSignature
        do {
            sourceSignature = try await retryTransport(
                stage: .classification
            ) {
                try await AetherURLPlaybackSourceClassifier.inspect(
                    url: self.url,
                    options: self.options
                )
            }
        } catch {
            let failure = failure(stage: .classification, error: error)
            if allowProvisionalNative,
               failure.kind == .transientTransport
                    || failure.kind == .inconclusiveEvidence {
                return provisionalNativeSource()
            }
            throw failure
        }

        if allowProvisionalNative,
           sourceSignature == .isoBaseMedia {
            return provisionalNativeSource(
                sourceContainer: .isoBaseMedia
            )
        }

        switch sourceSignature.sourceKind {
        case .hls:
            do {
                let preflight = try await retryTransport(
                    stage: .preflight
                ) {
                    let operation = AetherPlaybackPreflightOperation()
                    return try await operation.inspectHLS(
                        url: self.url,
                        sourceIsSeekableVOD: true,
                        variantSelection:
                            variantSelectionOverride
                            ?? self.variantSelection,
                        hybridCapabilities:
                            AetherHybridPlaybackSession.capabilities,
                        options: self.options
                    )
                }
                if allowProvisionalNative,
                   preflight.result.route == .unsupported,
                   Self.isInconclusiveHLSPreflight(preflight) {
                    return provisionalNativeSource()
                }
                return .hls(preflight)
            } catch {
                let failure = failure(stage: .preflight, error: error)
                if allowProvisionalNative,
                   failure.kind == .transientTransport
                        || failure.kind == .inconclusiveEvidence {
                    return provisionalNativeSource()
                }
                throw failure
            }

        case .progressive:
            do {
                let preparedSource = try await retryTransport(
                    stage: .preflight
                ) {
                    try await Task.detached(priority: .userInitiated) {
                        try AetherEngine.prepareURLSource(
                            url: self.url,
                            options: self.options
                        )
                    }.value
                }
                let probe = preparedSource.probe
                let isSeekableVOD =
                    probe.durationSeconds.isFinite
                    && probe.durationSeconds > 0
                    && !probe.isLive
                let profile = AetherSourceProfile(
                    probe: probe,
                    sourceKind: .progressive,
                    isSeekableVOD: isSeekableVOD
                )
                let result = PlaybackPreflight.resolve(
                    sourceProfile: profile,
                    hlsPackaging: nil,
                    hybridCapabilities:
                        AetherHybridPlaybackSession.capabilities
                )
                let retainedPreparedSource:
                    AetherPreparedURLSource?
                if result.route == .nativeAVPlayer,
                   result.reason == .nativeHLSFMP4Remux {
                    retainedPreparedSource = preparedSource
                } else {
                    preparedSource.discard()
                    retainedPreparedSource = nil
                }
                return .progressive(
                    probe: probe,
                    result: result,
                    preparedSource: retainedPreparedSource
                )
            } catch {
                let failure = failure(stage: .preflight, error: error)
                if allowProvisionalNative,
                   failure.kind == .transientTransport
                        || failure.kind == .inconclusiveEvidence {
                    return provisionalNativeSource()
                }
                throw failure
            }

        case .custom, .unclassifiedURL:
            throw AetherPlaybackSessionError.invalidFactorySource
        }
    }

    private func provisionalNativeSource(
        sourceContainer: AetherSourceContainer = .unknown
    )
        -> AetherResolvedPlaybackSource
    {
        let profile = AetherSourceProfile(
            sourceKind: .unclassifiedURL,
            isSeekableVOD: true,
            videoCodec: .unknown,
            sourceContainer: sourceContainer,
            // Ignored by the provisional Native-only contract.
            videoFormat: .sdr
        )
        return .provisionalNative(
            PlaybackPreflight.resolve(
                sourceProfile: profile,
                hlsPackaging: nil,
                hybridCapabilities:
                    AetherHybridPlaybackSession.capabilities
            )
        )
    }

    private static func isInconclusiveHLSPreflight(
        _ preflight: AetherHLSPlaybackPreflight
    ) -> Bool {
        switch preflight.result.reason {
        case .unsupportedHLSPreflightMissing,
             .unsupportedHLSSegmentNotInspected:
            return true
        case .unsupportedHLSContentProtection:
            return preflight.result.hlsPackaging?
                .contentProtection == .unknown
        default:
            return false
        }
    }

    private func installAndPrepare(
        _ source: AetherResolvedPlaybackSource,
        decoderPreference: HybridVideoDecoderPreference = .automatic
    ) async throws {
        guard source.result.route != .unsupported else {
            throw AetherPlaybackSessionError.unsupported(
                source.result.reason
            )
        }
        let transaction = routeTransactions.begin()
        let route = try await makeRouteSession(
            source,
            decoderPreference: decoderPreference
        )
        guard routeTransactions.isActive(transaction) else {
            route.stop()
            throw CancellationError()
        }
        try install(
            route,
            source: source,
            transaction: transaction
        )
        try await route.prepare()
        try commit(
            route,
            source: source,
            transaction: transaction
        )
        publishCurrentItem(avPlayer.currentItem)
    }

    private func makeRouteSession(
        _ source: AetherResolvedPlaybackSource,
        decoderPreference: HybridVideoDecoderPreference = .automatic
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
            case .progressive(let probe, _, _):
                binding = .progressive(
                    sourceURL: url,
                    httpHeaders: options.httpHeaders,
                    probe: probe
                )
            case .provisionalNative:
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
                return .native(
                    try await AetherNativePlaybackSession.makeRemuxed(
                        preparedSource: preparedSource,
                        options: options,
                        preflightResult: source.result,
                        audioAnalysisBinding: binding,
                        avPlayer: avPlayer
                    )
                )
            } else {
                return .native(
                    try AetherNativePlaybackSession.make(
                        url: url,
                        options: options,
                        preflightResult: source.result,
                        audioAnalysisBinding: binding,
                        avPlayer: avPlayer
                    )
                )
            }

        case .hybridCarrier:
            switch source {
            case .hls(let preflight):
                return .hybrid(
                    try await AetherHybridPlaybackSession.makeHLSVOD(
                        preflight: preflight,
                        avPlayer: avPlayer,
                        decoderPreference: decoderPreference,
                        transportRetryBudget: transportRetryBudget
                    )
                )
            case .progressive(let probe, let result, _):
                let timeline = try BlackCarrierTimeline.fileVOD(
                    duration: CMTime(
                        seconds: probe.durationSeconds,
                        preferredTimescale: 90_000
                    )
                )
                return .hybrid(
                    try await AetherHybridPlaybackSession.makeSeekableVOD(
                        source: .url(url),
                        options: options,
                        timeline: timeline,
                        preflightResult: result,
                        avPlayer: avPlayer,
                        decoderPreference: decoderPreference
                    )
                )
            case .provisionalNative:
                throw AetherPlaybackSessionError.invalidFactorySource
            }

        case .unsupported:
            throw AetherPlaybackSessionError.unsupported(
                source.result.reason
            )
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
        routeCancellables.removeAll()
        activeSession = session
        resolvedSource = source
        switch session {
        case .native(let native):
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
    ) throws {
        guard routeTransactions.isActive(transaction),
              let activeSession,
              activeSession.isIdentical(to: session) else {
            session.stop()
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
        case .ended: state = .ended
        case .failed(let failure):
            guard didCompleteInitialPrepare,
                  !isPreparingOrRecovering,
                  activeSeekOperationSequence == nil else { return }
            let kind: AetherPlaybackFailureKind =
                switch evidence?.category {
                case .transientTransport: .transientTransport
                case .authentication: .authenticationRejected
                case .security: .securityBoundary
                case .decoder: .decoderRuntimeFailure
                case .malformed: .malformedMedia
                case .cancelled: .cancelled
                case .invariant: .invariantViolation
                case .routeRuntime, nil: .routeRuntimeFailure
                }
            scheduleRuntimeRecovery(AetherPlaybackFailure(
                stage: .playback,
                kind: kind,
                domain: evidence?.domain
                    ?? "AetherNativePlaybackSessionFailure",
                code: evidence?.code ?? 0,
                reason: evidence.map {
                    "native.\($0.caseCode)"
                } ?? failure.rawValue
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
        if recoveryTask != nil {
            if Self.isPermanentFailure(failure.kind) {
                recoveryTask?.cancel()
                publishRecovery(
                    failure: failure,
                    action: .terminate,
                    from: activeRoute,
                    to: nil,
                    outcome: .exhausted
                )
                publishTerminal(
                    recoveryCoordinator.sessionFirstFailure ?? failure,
                    finalFailure: failure,
                    exhaustionReason:
                        "permanent failure superseded active recovery"
                )
                return
            }
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
                let recovered = try await self.recover(
                    from: failure,
                    duringInitialPrepare: false
                )
                if !recovered {
                    let original = self.recoveryCoordinator
                        .episodeFirstFailure ?? failure
                    self.publishTerminal(
                        original,
                        finalFailure:
                            self.lastRecoveryFailure ?? failure,
                        exhaustionReason:
                            "runtime recovery exhausted"
                    )
                }
            } catch is CancellationError {
                if !self.isStopped {
                    self.publishTerminal(
                        self.failure(
                            stage: .playback,
                            error: CancellationError()
                        )
                    )
                }
            } catch {
                self.publishTerminal(
                    self.recoveryCoordinator.episodeFirstFailure
                        ?? self.failure(stage: .playback, error: error)
                )
            }
            self.recoveryTask = nil
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
        let recoveryDeadline = currentRecoveryDeadline
        try ensureRecoveryDeadline(recoveryDeadline)
        let failedRoute = activeSession?.route ?? activeRoute
        let playbackContext = snapshotPlaybackContext()
        var latestFailure = initialFailure
        var freshSource = resolvedSource

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

        // Classification/preflight/remux transport work has already passed
        // through retryTransport's single three-attempt session budget. With
        // no candidate route there is nothing to rebuild and starting another
        // classifier loop here would double-count that budget.
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
                try ensureRecoveryDeadline(recoveryDeadline)
                freshSource = try await resolveSameRouteRecoverySource(
                    failedRoute: failedRoute,
                    allowLowerVariant:
                        isSelectedVariantAvailabilityFailure(
                            initialFailure
                        )
                )
                guard let admitted = freshSource?.admitting(
                    route: failedRoute
                ) else {
                    throw AetherPlaybackSessionError.unsupported(
                        freshSource?.result.reason
                            ?? .unsupportedVideoCodec
                    )
                }
                try await installAndPrepare(admitted)
                try ensureRecoveryDeadline(recoveryDeadline)
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
            }
        }

        if freshSource == nil {
            do {
                try ensureRecoveryDeadline(recoveryDeadline)
                freshSource = try await resolveCanonicalSource(
                    allowProvisionalNative: true
                )
            } catch {
                latestFailure = failure(stage: .preflight, error: error)
            }
        }
        if failedRoute == .hybridCarrier,
           initialFailure.kind == .decoderRuntimeFailure,
           let softwareSource = freshSource?.admitting(
                route: .hybridCarrier
           ),
           isSoftwareHEVCRecoveryEligible(softwareSource) {
            let softwareAction = PlaybackRecoveryDecision.resolve(
                context: AetherPlaybackRecoveryContext(
                    failure: initialFailure,
                    activeRoute: failedRoute,
                    positivelyAdmittedAlternateRoute: nil,
                    transportAttempt:
                        recoveryBudget.maximumTransportAttempts,
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
                    try ensureRecoveryDeadline(recoveryDeadline)
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
                }
            }
        }
        let alternate = failedRoute.flatMap {
            freshSource?.alternate(excluding: $0)
                ?? freshSource?.admitting(
                    route: freshSource?.result.route ?? .unsupported
                )
        }
        let selectionCompatibleAlternate:
            AetherResolvedPlaybackSource? = alternate.flatMap {
                source -> AetherResolvedPlaybackSource? in
            guard permitsRouteTransition(after: latestFailure) else {
                return nil
            }
            return source
        }
        let action = PlaybackRecoveryDecision.resolve(
            context: AetherPlaybackRecoveryContext(
                failure: latestFailure,
                activeRoute: failedRoute,
                positivelyAdmittedAlternateRoute:
                    selectionCompatibleAlternate?.result.route,
                transportAttempt: recoveryBudget.maximumTransportAttempts,
                sameRouteRebuildCount:
                    recoveryCoordinator.sameRouteRebuildCount,
                softwareDecoderTransitionCount:
                    recoveryCoordinator
                        .softwareDecoderTransitionCount,
                softwareDecoderRecoveryEligible: false,
                routeTransitionCount:
                    recoveryCoordinator.routeTransitionCount,
                elapsedSeconds: episodeElapsedSeconds,
                systemActivity: systemActivity
            ),
            budget: recoveryBudget
        )
        guard case .transition(let targetRoute) = action,
              let alternate = selectionCompatibleAlternate,
              alternate.result.route == targetRoute else {
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

        recoveryCoordinator.recordAttempt(action)
        publishRecovery(
            failure: latestFailure,
            action: action,
            from: failedRoute,
            to: targetRoute,
            outcome: .scheduled
        )
        teardownActiveRoute()
        do {
            try ensureRecoveryDeadline(recoveryDeadline)
            try await installAndPrepare(alternate)
            try ensureRecoveryDeadline(recoveryDeadline)
            try await restorePlaybackContext(
                playbackContext,
                duringInitialPrepare: duringInitialPrepare
            )
            publishRecovery(
                failure: latestFailure,
                action: action,
                from: failedRoute,
                to: targetRoute,
                outcome: .succeeded
            )
            isPreparingOrRecovering = false
            return true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            latestFailure = failure(stage: .preparation, error: error)
            publishRecovery(
                failure: latestFailure,
                action: action,
                from: failedRoute,
                to: targetRoute,
                outcome: .failed
            )
            isPreparingOrRecovering = false
            return false
        }
    }

    private func restorePlaybackContext(
        _ context: AetherPlaybackContextSnapshot,
        duringInitialPrepare: Bool
    ) async throws {
        guard let activeSession else {
            throw AetherPlaybackSessionError.noActiveRoute
        }
        let resumeTime = desiredSeekTarget ?? context.position
        if !duringInitialPrepare,
           resumeTime.isValid,
           resumeTime.isNumeric,
           resumeTime.seconds.isFinite,
           resumeTime.seconds >= 0 {
            let seekResult = try await activeSession.seek(
                to: resumeTime,
                timeout: try remainingRecoveryOperationTimeout()
            )
            guard seekResult == .applied else {
                throw CancellationError()
            }
            lastConfirmedMediaTime = resumeTime
            if desiredSeekTarget != nil {
                lastAppliedSeekOperationSequence =
                    operationCoordinator.latestSeekSequence
            }
        }
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
        }
        if let desiredSubtitleTrackID {
            if activeSession.subtitleTracks.contains(where: {
                $0.id == desiredSubtitleTrackID
            }) {
                do {
                    try await activeSession.selectSubtitleTrack(
                        desiredSubtitleTrackID
                    )
                } catch {
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
        publishTrackState(from: activeSession)
        publishCapabilities()
        if desiredPlaying {
            try activeSession.play()
            if desiredRate != 1 {
                try activeSession.setRate(desiredRate)
            }
            state = .playing
        } else {
            state = didCompleteInitialPrepare ? .paused : .ready
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

    private func lowerCompatibleVariantSelection(
        for failedRoute: PlaybackRenderRoute
    ) -> HLSPreflightVariantSelection? {
        guard failedRoute == .hybridCarrier,
              case .hls(let preflight) = resolvedSource,
              let graph = preflight.resourceGraph,
              let bandwidth = graph.selectedVariantBandwidth else {
            return nil
        }
        return .nextLowerCompatible(
            thanBandwidth: bandwidth,
            audioGroupID: graph.separateAudioGroupID,
            subtitleGroupID: graph.separateSubtitleGroupID
        )
    }

    private func resolveSameRouteRecoverySource(
        failedRoute: PlaybackRenderRoute,
        allowLowerVariant: Bool
    ) async throws -> AetherResolvedPlaybackSource {
        guard allowLowerVariant,
              !lowerVariantRecoveryWasAttempted,
              let lowerSelection = lowerCompatibleVariantSelection(
            for: failedRoute
        ) else {
            return try await resolveCanonicalSource(
                allowProvisionalNative: false
            )
        }
        lowerVariantRecoveryWasAttempted = true
        do {
            return try await resolveCanonicalSource(
                allowProvisionalNative: false,
                variantSelectionOverride: lowerSelection
            )
        } catch let failure as AetherPlaybackFailure
        where failure.kind == .inconclusiveEvidence {
            return try await resolveCanonicalSource(
                allowProvisionalNative: false
            )
        }
    }

    private func isSoftwareHEVCRecoveryEligible(
        _ source: AetherResolvedPlaybackSource
    ) -> Bool {
        PlaybackRecoveryDecision.permitsSoftwareHEVCRecovery(
            sourceProfile: source.result.sourceProfile
        )
    }

    private func isSelectedVariantAvailabilityFailure(
        _ failure: AetherPlaybackFailure
    ) -> Bool {
        failure.kind == .transientTransport
            && failure.reason == "hybrid.origin.selectedVariantUnavailable"
    }

    private func permitsRouteTransition(
        after failure: AetherPlaybackFailure
    ) -> Bool {
        !failure.reason.hasPrefix("hybrid.presentation.mediaDivergence")
    }

    private func retryTransport<T>(
        stage: AetherPlaybackRecoveryStage,
        operation: () async throws -> T
    ) async throws -> T {
        var pendingRetry:
            (AetherPlaybackFailure, AetherPlaybackRecoveryAction)?
        while true {
            do {
                if recoveryCoordinator.episodeFirstFailure != nil {
                    try ensureRecoveryDeadline(currentRecoveryDeadline)
                    if transportRetryBudget.isExhausted {
                        throw AetherPlaybackFailure(
                            stage: stage,
                            kind: .transientTransport,
                            domain: "AetherPlaybackRecovery",
                            code: recoveryBudget
                                .maximumTransportAttempts,
                            reason:
                                "transport recovery budget exhausted"
                        )
                    }
                }
                let value = try await operation()
                if recoveryCoordinator.episodeFirstFailure != nil {
                    try ensureRecoveryDeadline(currentRecoveryDeadline)
                }
                if let pendingRetry {
                    publishRecovery(
                        failure: pendingRetry.0,
                        action: pendingRetry.1,
                        from: activeRoute,
                        to: activeRoute,
                        outcome: .succeeded
                    )
                }
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
                let transportAttempt = isRetryable
                    ? transportRetryBudget.recordRetryableFailure()
                    : transportRetryBudget.currentFailureAttempt
                let action = PlaybackRecoveryDecision.resolve(
                    context: AetherPlaybackRecoveryContext(
                        failure: typed,
                        activeRoute: activeRoute,
                        positivelyAdmittedAlternateRoute: nil,
                        transportAttempt: max(1, transportAttempt),
                        sameRouteRebuildCount:
                            recoveryCoordinator.sameRouteRebuildCount,
                        softwareDecoderTransitionCount:
                            recoveryCoordinator
                                .softwareDecoderTransitionCount,
                        routeTransitionCount:
                            recoveryCoordinator.routeTransitionCount,
                        elapsedSeconds: episodeElapsedSeconds,
                        systemActivity: systemActivity
                    ),
                    budget: recoveryBudget
                )
                guard case .retrySameOperation(let delay) = action else {
                    throw typed
                }
                recoveryCoordinator.recordAttempt(action)
                publishRecovery(
                    failure: typed,
                    action: action,
                    from: activeRoute,
                    to: activeRoute,
                    outcome: .scheduled
                )
                pendingRetry = (typed, action)
                let remaining = currentRecoveryDeadline.remainingSeconds(
                    now: ProcessInfo.processInfo.systemUptime
                )
                guard delay < remaining else {
                    throw AetherPlaybackSessionError
                        .recoveryDeadlineExceeded(
                            seconds: recoveryBudget
                                .maximumEpisodeDurationSeconds
                        )
                }
                try await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
            }
        }
    }

    private var currentRecoveryDeadline: PlaybackRecoveryDeadline {
        PlaybackRecoveryDeadline(
            startedAt: recoveryCoordinator.episodeStartedAt,
            durationSeconds:
                recoveryBudget.maximumEpisodeDurationSeconds
        )
    }

    private func ensureRecoveryDeadline(
        _ deadline: PlaybackRecoveryDeadline
    ) throws {
        guard !deadline.isExpired(
            now: ProcessInfo.processInfo.systemUptime
        ) else {
            throw AetherPlaybackSessionError
                .recoveryDeadlineExceeded(
                    seconds:
                        recoveryBudget.maximumEpisodeDurationSeconds
                )
        }
    }

    private func remainingRecoveryOperationTimeout()
        throws -> TimeInterval
    {
        let remaining = currentRecoveryDeadline.remainingSeconds(
            now: ProcessInfo.processInfo.systemUptime
        )
        guard remaining > 0 else {
            throw AetherPlaybackSessionError
                .recoveryDeadlineExceeded(
                    seconds:
                        recoveryBudget.maximumEpisodeDurationSeconds
                )
        }
        return remaining
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
                let evidenceStage:
                    AetherPlaybackRecoveryStage = switch evidence.stage {
                case .routeCreation: .routeCreation
                case .preparation: .preparation
                case .seek, .runtime, .provider, .carrier: .playback
                }
                return AetherPlaybackFailure(
                    stage: evidenceStage,
                    kind: .routeRuntimeFailure,
                    domain: evidence.underlyingDomain,
                    code: evidence.underlyingCode,
                    reason: "hybrid.\(evidence.stage.rawValue).\(evidence.caseCode)"
                )
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
        case is AetherNativePlaybackSessionError:
            kind = .routeRuntimeFailure
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
        return AetherPlaybackFailure(
            stage: stage,
            kind: kind,
            domain: String(reflecting: type(of: error)),
            code: nsError.code,
            reason: Self.redactedReason(
                kind: kind,
                stage: stage,
                error: error
            )
        )
    }

    private static func classify(
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
        case .unsupportedURLScheme, .unreadableFile,
             .nonHTTPResponse, .unsupportedContentEncoding:
            .invariantViolation
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
        case .videoPipelineMissing:
            .unsupportedCapability
        case .carrierItemMissing, .carrierClockUnavailable,
             .resumeIntentMissing, .generationDiverged,
             .sourceVideoFormatDiverged,
             .sourceDolbyVisionConfigurationDiverged:
            .routeRuntimeFailure
        case .renderSurfaceMissing,
             .invalidSeekableVODOptions,
             .sourceIndependentReaderUnavailable,
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
        if beginProgressEpoch {
            playbackProgressEpoch.begin()
        }
        mergedRuntimeFailureKeys.removeAll(keepingCapacity: true)
        lastRecoveryFailure = nil
        transportRetryBudget.reset()
    }

    private static func isPermanentFailure(
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
        lastConfirmedMediaTime = time
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
            capabilitiesBeforeRecoveryAttempt = capabilities
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
        EngineLog.emit(
            "[AetherPlaybackSession] recovery sequence=\(event.sequence) "
                + "attempt=\(event.attempt) "
                + "from=\(from?.rawValue ?? "none") "
                + "to=\(to?.rawValue ?? "none") "
                + "kind=\(failure.kind.rawValue) "
                + "capabilityChanged=\(capabilityDelta.map { $0.before != $0.after } ?? false) "
                + "outcome=\(outcome.rawValue)",
            category: .session
        )
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
        routeTransactions.invalidate()
        routeCancellables.removeAll()
        activeSession?.cancelAudioAnalysisStreams()
        activeSession?.stop()
        activeSession = nil
        presentationView.install(nil)
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
            avPlayer.allowsExternalPlayback = true
        case .hybrid(let hybrid):
            try hybrid.configureCarrierPlayerViewController(
                controller,
                realVideoGravity: realVideoGravity
            )
            controller.allowsPictureInPicturePlayback = false
            avPlayer.allowsExternalPlayback = false
        }
    }
    #endif
}
