import Foundation

/// Privacy-safe description of how one observable preflight was requested.
///
/// Exact HLS variant URIs, source URLs and request headers deliberately remain outside this contract.
public enum AetherPlaybackPreflightTelemetryRequestKind:
    Sendable,
    Equatable
{
    case policyResolution
    case hlsInspection(
        AetherHLSPreflightTelemetryVariantSelection
    )
}

public enum AetherHLSPreflightTelemetryVariantSelection:
    Sendable,
    Equatable
{
    case highestBandwidth
    case exactVariant

    init(_ selection: HLSPreflightVariantSelection) {
        self = switch selection {
        case .highestBandwidth:
            .highestBandwidth
        case .exactURI:
            .exactVariant
        }
    }
}

public struct AetherPlaybackPreflightTelemetryRequest:
    Sendable,
    Equatable
{
    public let kind:
        AetherPlaybackPreflightTelemetryRequestKind
    public let sourceKind: AetherMediaSourceKind
    public let sourceIsSeekableVOD: Bool

    init(
        kind: AetherPlaybackPreflightTelemetryRequestKind,
        sourceKind: AetherMediaSourceKind,
        sourceIsSeekableVOD: Bool
    ) {
        self.kind = kind
        self.sourceKind = sourceKind
        self.sourceIsSeekableVOD = sourceIsSeekableVOD
    }
}

/// HLS packaging facts safe to persist as telemetry.
///
/// The manifest's arbitrary codec strings are intentionally excluded. The normalized codec and typed
/// verification state carry the route-relevant evidence without accepting unbounded manifest text.
public struct AetherPlaybackPreflightTelemetryHLSPackaging:
    Sendable,
    Equatable
{
    public let container: HLSVideoContainer
    public let sampleEntry: HLSVideoSampleEntry
    public let actualVideoCodec: AetherVideoCodec
    public let codecVerification:
        HLSManifestCodecVerification
    public let contentProtection: HLSContentProtection

    init(_ packaging: HLSVideoPackaging) {
        container = packaging.container
        sampleEntry = packaging.sampleEntry
        actualVideoCodec = packaging.actualVideoCodec
        codecVerification = packaging.codecVerification
        contentProtection = packaging.contentProtection
    }
}

/// Public HLS evidence retained by a completed inspection.
///
/// The resource identity digest and every URL/header remain engine-private. A Boolean records whether an
/// immutable graph was retained without turning that graph identity into a cross-system tracking value.
public struct AetherPlaybackPreflightTelemetryHLSEvidence:
    Sendable,
    Equatable
{
    public let hasRetainedResourceGraph: Bool
    public let selectedVariantBandwidth: Int?
    public let mediaSegmentCount: Int
    public let audioRenditionCount: Int
    public let hdr10PlusEvidence:
        AetherHLSHDR10PlusPreflightEvidence

    init(_ preflight: AetherHLSPlaybackPreflight) {
        hasRetainedResourceGraph =
            preflight.resourceIdentity != nil
        selectedVariantBandwidth =
            preflight.selectedVariantBandwidth
        mediaSegmentCount = preflight.mediaSegmentCount
        audioRenditionCount = preflight.audioRenditionCount
        hdr10PlusEvidence = preflight.hdr10PlusEvidence
    }
}

/// Privacy-safe terminal result for native, hybrid and typed-unsupported preflight decisions.
public struct AetherPlaybackPreflightTelemetryResult:
    Sendable,
    Equatable
{
    public let sourceProfile: AetherSourceProfile
    public let hlsPackaging:
        AetherPlaybackPreflightTelemetryHLSPackaging?
    public let route: PlaybackRenderRoute
    public let reason: PlaybackRouteReason
    public let hlsEvidence:
        AetherPlaybackPreflightTelemetryHLSEvidence?

    init(
        result: PlaybackPreflightResult,
        hlsPreflight: AetherHLSPlaybackPreflight?
    ) {
        sourceProfile = result.sourceProfile
        hlsPackaging = result.hlsPackaging.map(
            AetherPlaybackPreflightTelemetryHLSPackaging
                .init
        )
        route = result.route
        reason = result.reason
        hlsEvidence = hlsPreflight.map(
            AetherPlaybackPreflightTelemetryHLSEvidence.init
        )
    }
}

/// Stable failure identity for an HLS inspection that could not produce a route decision.
///
/// Arbitrary playlist parser reasons, URIs, content-encoding strings and transport descriptions are
/// collapsed. The original error is still thrown to the direct caller and is never replaced by this value.
public enum AetherPlaybackPreflightTelemetryFailureReason:
    Sendable,
    Equatable
{
    case hlsHTTPStatus(Int)
    case hlsInvalidPlaylist
    case hlsUnresolvableURI
    case hlsRequestedVariantNotFound
    case hlsSelectedVariantWasNotMediaPlaylist
    case hlsSeekableVODPlaylistNotFinite
    case hlsUnsupportedSeekableVODResourceGraph
    case hlsResourceTooLarge
    case hlsUnsupportedContentEncoding
    case hlsContentLengthMismatch
    case hlsRedirectCredentialScopeViolation
    case hlsNonHTTPResponse
    case hlsTransportFailure(code: Int?)
    case cancelled
    case unexpectedFailure

    init(_ error: HLSPreflightError) {
        self = switch error {
        case .httpStatus(let status):
            .hlsHTTPStatus(status)
        case .invalidPlaylist:
            .hlsInvalidPlaylist
        case .unresolvableURI:
            .hlsUnresolvableURI
        case .requestedVariantNotFound:
            .hlsRequestedVariantNotFound
        case .selectedVariantWasNotMediaPlaylist:
            .hlsSelectedVariantWasNotMediaPlaylist
        case .seekableVODPlaylistNotFinite:
            .hlsSeekableVODPlaylistNotFinite
        case .unsupportedSeekableVODResourceGraph:
            .hlsUnsupportedSeekableVODResourceGraph
        case .resourceTooLarge:
            .hlsResourceTooLarge
        case .unsupportedContentEncoding:
            .hlsUnsupportedContentEncoding
        case .contentLengthMismatch:
            .hlsContentLengthMismatch
        case .redirectCredentialScopeViolation:
            .hlsRedirectCredentialScopeViolation
        case .nonHTTPResponse:
            .hlsNonHTTPResponse
        case .transportFailure(let code):
            .hlsTransportFailure(code: code)
        }
    }
}

public struct AetherPlaybackPreflightTelemetryFailure:
    Sendable,
    Equatable
{
    public let request:
        AetherPlaybackPreflightTelemetryRequest
    public let reason:
        AetherPlaybackPreflightTelemetryFailureReason

    init(
        request: AetherPlaybackPreflightTelemetryRequest,
        reason:
            AetherPlaybackPreflightTelemetryFailureReason
    ) {
        self.request = request
        self.reason = reason
    }
}

public enum AetherPlaybackPreflightTelemetryEventKind:
    String,
    Sendable,
    Equatable
{
    case started
    case completed
    case failed
}

public enum AetherPlaybackPreflightTelemetrySnapshot:
    Sendable,
    Equatable
{
    case started(AetherPlaybackPreflightTelemetryRequest)
    case completed(AetherPlaybackPreflightTelemetryResult)
    case failed(AetherPlaybackPreflightTelemetryFailure)
}

public struct AetherPlaybackPreflightTelemetryEvent:
    Sendable,
    Equatable
{
    public let operationID: UUID
    public let sequence: UInt64
    public let kind:
        AetherPlaybackPreflightTelemetryEventKind
    public let snapshot:
        AetherPlaybackPreflightTelemetrySnapshot

    init(
        operationID: UUID,
        sequence: UInt64,
        kind: AetherPlaybackPreflightTelemetryEventKind,
        snapshot:
            AetherPlaybackPreflightTelemetrySnapshot
    ) {
        self.operationID = operationID
        self.sequence = sequence
        self.kind = kind
        self.snapshot = snapshot
    }
}

public enum AetherPlaybackPreflightOperationError:
    Error,
    Sendable,
    Equatable,
    LocalizedError
{
    case alreadyStarted

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            "A playback preflight operation is one-shot and has already started"
        }
    }
}

/// One observable, one-shot playback preflight.
///
/// Hosts subscribe before invoking `resolve` or `inspectHLS`. The event stream is bounded and replayable,
/// so native and typed-unsupported decisions remain observable even though no Hybrid session is created.
/// Reusing an operation fails explicitly; it never starts a second inspection or selects another route.
public actor AetherPlaybackPreflightOperation {
    public nonisolated let operationID: UUID

    private static let historyLimit = 8

    private enum State: Equatable {
        case idle
        case running
        case finished
    }

    private var state = State.idle
    private var sequence: UInt64 = 0
    private var history:
        [AetherPlaybackPreflightTelemetryEvent] = []
    private var continuations: [
        UUID:
            AsyncStream<
                AetherPlaybackPreflightTelemetryEvent
            >.Continuation
    ] = [:]

    public init() {
        operationID = UUID()
    }

    init(operationID: UUID) {
        self.operationID = operationID
    }

    public func telemetryEvents()
        -> AsyncStream<AetherPlaybackPreflightTelemetryEvent>
    {
        let subscriptionID = UUID()
        let pair = AsyncStream.makeStream(
            of: AetherPlaybackPreflightTelemetryEvent.self,
            bufferingPolicy: .bufferingNewest(
                Self.historyLimit
            )
        )
        for event in history {
            pair.continuation.yield(event)
        }
        guard state != .finished else {
            pair.continuation.finish()
            return pair.stream
        }
        continuations[subscriptionID] = pair.continuation
        pair.continuation.onTermination = {
            [weak self] _ in
            Task {
                await self?.removeContinuation(
                    subscriptionID
                )
            }
        }
        return pair.stream
    }

    /// Execute the pure route policy with an observable terminal decision.
    public func resolve(
        sourceProfile: AetherSourceProfile,
        hlsPackaging: HLSVideoPackaging?,
        hybridCapabilities: HybridPlaybackCapabilities
    ) throws -> PlaybackPreflightResult {
        let request = AetherPlaybackPreflightTelemetryRequest(
            kind: .policyResolution,
            sourceKind: sourceProfile.sourceKind,
            sourceIsSeekableVOD:
                sourceProfile.isSeekableVOD
        )
        try begin(request)
        let result = PlaybackPreflight.resolve(
            sourceProfile: sourceProfile,
            hlsPackaging: hlsPackaging,
            hybridCapabilities: hybridCapabilities
        )
        complete(
            result: result,
            hlsPreflight: nil
        )
        return result
    }

    /// Fetch and inspect one exact HLS selection while publishing a privacy-safe lifecycle.
    ///
    /// Transport and manifest failures are rethrown unchanged after a typed failed event is emitted.
    public func inspectHLS(
        url: URL,
        sourceIsSeekableVOD: Bool,
        variantSelection: HLSPreflightVariantSelection,
        hybridCapabilities: HybridPlaybackCapabilities,
        options: LoadOptions = .init()
    ) async throws -> AetherHLSPlaybackPreflight {
        try await inspectHLS(
            rootURL: url,
            sourceIsSeekableVOD: sourceIsSeekableVOD,
            variantSelection: variantSelection,
            hybridCapabilities: hybridCapabilities,
            inspector: HLSPreflightInspector(
                httpHeaders: options.httpHeaders
            )
        )
    }

    func inspectHLS(
        rootURL: URL,
        sourceIsSeekableVOD: Bool,
        variantSelection: HLSPreflightVariantSelection,
        hybridCapabilities: HybridPlaybackCapabilities,
        inspector: HLSPreflightInspector
    ) async throws -> AetherHLSPlaybackPreflight {
        let request = AetherPlaybackPreflightTelemetryRequest(
            kind: .hlsInspection(
                AetherHLSPreflightTelemetryVariantSelection(
                    variantSelection
                )
            ),
            sourceKind: .hls,
            sourceIsSeekableVOD:
                sourceIsSeekableVOD
        )
        try begin(request)
        do {
            let preflight = try await inspector.inspect(
                rootURL: rootURL,
                sourceIsSeekableVOD:
                    sourceIsSeekableVOD,
                variantSelection: variantSelection,
                hybridCapabilities: hybridCapabilities
            )
            complete(
                result: preflight.result,
                hlsPreflight: preflight
            )
            return preflight
        } catch let error as CancellationError {
            fail(request: request, reason: .cancelled)
            throw error
        } catch let error as HLSPreflightError {
            fail(
                request: request,
                reason:
                    AetherPlaybackPreflightTelemetryFailureReason(
                        error
                    )
            )
            throw error
        } catch {
            fail(
                request: request,
                reason: .unexpectedFailure
            )
            throw error
        }
    }

    private func begin(
        _ request: AetherPlaybackPreflightTelemetryRequest
    ) throws {
        guard state == .idle else {
            throw AetherPlaybackPreflightOperationError
                .alreadyStarted
        }
        state = .running
        emit(
            kind: .started,
            snapshot: .started(request)
        )
    }

    private func complete(
        result: PlaybackPreflightResult,
        hlsPreflight: AetherHLSPlaybackPreflight?
    ) {
        emit(
            kind: .completed,
            snapshot: .completed(
                AetherPlaybackPreflightTelemetryResult(
                    result: result,
                    hlsPreflight: hlsPreflight
                )
            )
        )
        finish()
    }

    private func fail(
        request: AetherPlaybackPreflightTelemetryRequest,
        reason:
            AetherPlaybackPreflightTelemetryFailureReason
    ) {
        emit(
            kind: .failed,
            snapshot: .failed(
                AetherPlaybackPreflightTelemetryFailure(
                    request: request,
                    reason: reason
                )
            )
        )
        finish()
    }

    private func emit(
        kind: AetherPlaybackPreflightTelemetryEventKind,
        snapshot: AetherPlaybackPreflightTelemetrySnapshot
    ) {
        sequence &+= 1
        let event = AetherPlaybackPreflightTelemetryEvent(
            operationID: operationID,
            sequence: sequence,
            kind: kind,
            snapshot: snapshot
        )
        history.append(event)
        if history.count > Self.historyLimit {
            history.removeFirst(
                history.count - Self.historyLimit
            )
        }
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func finish() {
        state = .finished
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
