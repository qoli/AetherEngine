import CoreMedia
import Foundation

enum HLSVODCarrierProviderError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case startupResourceMissing(ordinal: Int)
    case pump(HLSVODMediaPumpError)
    case closed
    case unexpected(HybridPlaybackFailureEvidence)

    var errorDescription: String? {
        switch self {
        case .startupResourceMissing(let ordinal):
            "HLS VOD carrier audio rendition \(ordinal) did not produce startup init and segment 0"
        case .pump(let error):
            error.localizedDescription
        case .closed:
            "HLS VOD carrier provider is closed"
        case .unexpected(let evidence):
            "HLS VOD carrier provider failed at \(evidence.stage.rawValue).\(evidence.caseCode) (\(evidence.underlyingDomain):\(evidence.underlyingCode))"
        }
    }
}

/// Loopback-HLS transport adapter for the engine-private graph-bound HLS media pump.
///
/// The existing server/provider surface is synchronous because each request owns a dedicated connection
/// worker. This adapter blocks only that worker while an unstructured task awaits the pump actor. It
/// advertises Aether's fixed 2 Mbps AVPlayer loopback transport budget. The budget is the primary policy;
/// it is never replaced by source bitrate, full-asset measurement or an audio transcode. Playback and
/// independent analysis share the same graph-bound loader while retaining separate demux/decoder cursors.
final class HLSVODCarrierProvider:
    BlackCarrierTransportProvider,
    HybridAudioAnalysisSource,
    HybridAudioAnalysisPlaybackPressureSink,
    HybridCarrierBandwidthTelemetrySource,
    HybridRealVideoBitrateTelemetrySource,
    HybridOverlaySubtitleSource,
    @unchecked Sendable
{
    private static let slowServeThresholdSeconds: TimeInterval = 2

    private let videoProvider: BlackCarrierVideoProvider
    private let pump: HLSVODMediaPump
    private let metadata:
        [BlackCarrierAudioRenditionMetadata]
    private let descriptors:
        [BlackCarrierAudioRenditionDescriptor]
    private let subtitleRenditions:
        [HLSVODSubtitleRenditionResource]
    private let timeline: BlackCarrierTimeline
    private let codecs: String
    private let resolvedHybridVideoFormat: VideoFormat?
    private let resolvedHybridDolbyVisionConfiguration:
        AetherDolbyVisionConfiguration?
    private let resolvedHybridVideoFrameRate: Double?
    private let analysisInput: AudioAnalysisInput
    let hybridSubtitleContracts:
        [HybridSubtitleDecodeContract]
    let hybridSubtitlePacketStore: SubtitlePacketStore
    let hybridSubtitleRuntimeAvailability:
        HybridSubtitleRuntimeAvailabilityStore

    private let closeLock = NSLock()
    private let restartLock = NSLock()
    private var isClosed = false
    private let failureLock = NSLock()
    private var _terminalError:
        HLSVODCarrierProviderError?
    private var terminalHybridPlaybackErrorHandler:
        (@Sendable (
            HybridPlaybackSessionError
        ) -> Void)?

    static func make(
        preflight: AetherHLSPlaybackPreflight,
        bridgeMode: AudioBridgeMode = .surroundCompat,
        videoPacketSink:
            HLSVODMediaPump.VideoPacketSink? = nil,
        decodedFrameHandler:
            HybridVideoDecodeSink.FrameHandler? = nil,
        videoFailureHandler:
            HybridVideoDecodeSink.FailureHandler? = nil,
        decoderPreference: HybridVideoDecoderPreference = .automatic,
        initialGeneration: UInt64 = 0,
        maximumResourceBytes: Int =
            HLSVODOriginResourceLoader.defaultMaximumResourceBytes,
        capacityBytes: Int64 =
            HLSVODOriginResourceLoader.defaultCapacityBytes,
        baseDirectory: URL =
            FileManager.default.temporaryDirectory,
        transportRetryBudget: PlaybackTransportRetryBudget = .init(
            maximumFailureAttempts: 3
        ),
        fetchOverride:
            HLSVODOriginResourceLoader.Fetch? = nil
    ) async throws -> HLSVODCarrierProvider {
        guard let timeline =
                preflight.hybridTimeline else {
            throw HLSVODCarrierProviderError
                .pump(.invalidPreflight)
        }
        let videoProvider: BlackCarrierVideoProvider
        do {
            videoProvider =
                try BlackCarrierVideoProvider(
                    timeline: timeline
                )
        } catch {
            throw HLSVODCarrierProviderError
                .unexpected(
                    HybridPlaybackFailureEvidence(
                        stage: .routeCreation,
                        caseCode: "videoProvider",
                        error: error
                    )
                )
        }
        let pump: HLSVODMediaPump
        do {
            pump = try await HLSVODMediaPump.make(
                preflight: preflight,
                bridgeMode: bridgeMode,
                videoPacketSink: videoPacketSink,
                decodedFrameHandler:
                    decodedFrameHandler,
                videoFailureHandler:
                    videoFailureHandler,
                decoderPreference: decoderPreference,
                initialGeneration:
                    initialGeneration,
                maximumResourceBytes:
                    maximumResourceBytes,
                capacityBytes: capacityBytes,
                baseDirectory: baseDirectory,
                transportRetryBudget: transportRetryBudget,
                fetchOverride: fetchOverride
            )
        } catch {
            videoProvider.close()
            if let typed =
                    error as? HLSVODMediaPumpError {
                throw HLSVODCarrierProviderError
                    .pump(typed)
            }
            throw HLSVODCarrierProviderError
                .unexpected(
                    HybridPlaybackFailureEvidence(
                        stage: .routeCreation,
                        caseCode: "mediaPump",
                        error: error
                    )
                )
        }

        do {
            return try await HLSVODCarrierProvider(
                videoProvider: videoProvider,
                pump: pump,
                timeline: timeline
            )
        } catch {
            videoProvider.close()
            do {
                try await pump.close()
            } catch {
                let nsError = error as NSError
                EngineLog.emit(
                    "[HLSVODCarrierProvider] setup cleanup failed: "
                        + "domain=\(nsError.domain) code=\(nsError.code)",
                    category: .session
                )
            }
            throw error
        }
    }

    private init(
        videoProvider: BlackCarrierVideoProvider,
        pump: HLSVODMediaPump,
        timeline: BlackCarrierTimeline
    ) async throws {
        let metadata = pump.renditionMetadata
        let descriptors =
            pump.renditionDescriptors
        let subtitleRenditions =
            pump.subtitleRenditions
        self.videoProvider = videoProvider
        self.pump = pump
        self.metadata = metadata
        self.descriptors = descriptors
        self.subtitleRenditions = subtitleRenditions
        self.timeline = timeline
        resolvedHybridVideoFormat =
            await pump.hybridVideoFormat
        resolvedHybridDolbyVisionConfiguration =
            await pump.hybridDolbyVisionConfiguration
        resolvedHybridVideoFrameRate =
            await pump.hybridVideoFrameRate
        hybridSubtitleContracts =
            pump.hybridSubtitleContracts
        hybridSubtitlePacketStore =
            pump.hybridSubtitlePacketStore
        hybridSubtitleRuntimeAvailability =
            pump.hybridSubtitleRuntimeAvailability
        analysisInput =
            try await pump.makeAudioAnalysisInput()

        var uniqueCodecs = [
            BlackCarrierProfile.approved.codecString
        ]
        for descriptor in descriptors
        where !uniqueCodecs.contains(
            descriptor.codecString
        ) {
            uniqueCodecs.append(
                descriptor.codecString
            )
        }
        codecs = uniqueCodecs.joined(
            separator: ","
        )
    }

    deinit {
        close()
    }

    var terminalError:
        HLSVODCarrierProviderError? {
        failureLock.lock()
        defer { failureLock.unlock() }
        return _terminalError
    }

    var terminalHybridPlaybackError:
        HybridPlaybackSessionError?
    {
        guard let terminalError else {
            return nil
        }
        return Self.hybridPlaybackSessionError(
            from: terminalError
        )
    }

    func setTerminalHybridPlaybackErrorHandler(
        _ handler:
            (@Sendable (
                HybridPlaybackSessionError
            ) -> Void)?
    ) {
        failureLock.lock()
        terminalHybridPlaybackErrorHandler =
            handler
        let existing = _terminalError.flatMap {
            Self.hybridPlaybackSessionError(
                from: $0
            )
        }
        failureLock.unlock()
        if let existing {
            handler?(existing)
        }
    }

    var hybridVideoFormat: VideoFormat? {
        resolvedHybridVideoFormat
    }

    var hybridDolbyVisionConfiguration:
        AetherDolbyVisionConfiguration?
    {
        resolvedHybridDolbyVisionConfiguration
    }

    var hybridVideoFrameRate: Double? {
        resolvedHybridVideoFrameRate
    }

    var audioAnalysisTrackIDs: [Int] {
        metadata.map(\.sourceTrackID)
    }

    func makeAudioAnalysisInput() throws
        -> AudioAnalysisInput
    {
        try requireOpen()
        return analysisInput
    }

    func setAudioAnalysisPlaybackPressure(
        _ pressure: HybridAudioAnalysisPlaybackPressure
    ) async {
        await pump.setAudioAnalysisPlaybackPressure(
            pressure
        )
    }

    func mediaPumpSnapshot() throws
        -> HLSVODMediaPumpSnapshot
    {
        try requireOpen()
        return try BlockingAsyncBridge.wait {
            await self.pump.snapshot()
        }
    }

    func originLoaderSnapshot() async
        -> HLSVODOriginResourceLoaderSnapshot
    {
        await pump.originLoaderSnapshot()
    }

    func prepareForTransportStart() throws {
        try requireOpen()
        do {
            try BlockingAsyncBridge.wait {
                try await self.pump.produce(
                    throughSegment: 0
                )
            }
            for ordinal in metadata.indices {
                let initSegment =
                    try BlockingAsyncBridge.wait {
                        try await self.pump
                            .audioInitSegment(
                                renditionOrdinal:
                                    ordinal
                            )
                    }
                let mediaURL =
                    try BlockingAsyncBridge.wait {
                        try await self.pump
                            .audioMediaSegmentURL(
                                renditionOrdinal:
                                    ordinal,
                                segmentIndex: 0
                            )
                    }
                guard initSegment != nil,
                      mediaURL != nil else {
                    throw HLSVODCarrierProviderError
                        .startupResourceMissing(
                            ordinal: ordinal
                        )
                }
            }
        } catch {
            let typed = Self.typed(error)
            record(typed)
            throw typed
        }
    }

    func advanceVideoDecodeDemand(
        to time: CMTime
    ) throws {
        try requireOpen()
        do {
            try BlockingAsyncBridge.wait {
                try await self.pump
                    .advanceVideoDecodeDemand(
                        to: time
                    )
            }
        } catch {
            let typed = Self.typed(error)
            record(typed)
            throw typed
        }
    }

    func restartMedia(
        for intent: HybridSeekIntent
    ) throws -> BlackCarrierMediaFanoutRestartResult {
        restartLock.lock()
        defer { restartLock.unlock() }
        try requireOpen()
        do {
            return try BlockingAsyncBridge.wait {
                try await self.pump.restart(
                    for: intent
                )
            }
        } catch {
            let typed = Self.typed(error)
            recordIfTerminal(typed)
            throw typed
        }
    }

    func prepareHybridGeneration(
        segmentIndex: Int
    ) throws {
        try requireOpen()
        do {
            try BlockingAsyncBridge.wait {
                try await self.pump.produce(
                    throughSegment:
                        segmentIndex
                )
            }
        } catch {
            let typed = Self.typed(error)
            recordIfTerminal(typed)
            throw typed
        }
    }

    func close() {
        closeLock.lock()
        guard !isClosed else {
            closeLock.unlock()
            return
        }
        isClosed = true
        closeLock.unlock()
        videoProvider.close()
        do {
            try BlockingAsyncBridge.wait {
                try await self.pump.close()
            }
        } catch {
            let nsError = error as NSError
            EngineLog.emit(
                "[HLSVODCarrierProvider] close failed: "
                    + "domain=\(nsError.domain) code=\(nsError.code)",
                category: .session
            )
        }
    }

    func initSegment() -> Data? {
        guard isAvailable else { return nil }
        return videoProvider.initSegment()
    }

    func mediaSegment(at index: Int) -> Data? {
        guard prepareVideoSegment(index) else {
            return nil
        }
        return videoProvider.mediaSegment(at: index)
    }

    func mediaSegmentURL(at index: Int) -> URL? {
        guard prepareVideoSegment(index) else {
            return nil
        }
        return videoProvider.mediaSegmentURL(
            at: index
        )
    }

    var segmentCount: Int {
        timeline.segments.count
    }

    func segmentDuration(at index: Int)
        -> Double
    {
        guard timeline.segments.indices
            .contains(index) else {
            return 0
        }
        return timeline.segments[index]
            .duration.seconds
    }

    var playlistType: HLSPlaylistType { .vod }
    var masterCodecs: String? { codecs }
    var masterResolution: (
        width: Int,
        height: Int
    )? {
        videoProvider.masterResolution
    }
    var masterVideoRange: HLSVideoRange? {
        videoProvider.masterVideoRange
    }
    var masterBandwidth: Int? {
        AetherHybridCarrierBandwidthPolicy
            .loopbackTransportBudget
    }
    var masterAverageBandwidth: Int? { nil }
    var masterFrameRate: Double? {
        videoProvider.masterFrameRate
    }
    var masterClosedCaptions: String? {
        videoProvider.masterClosedCaptions
    }

    var carrierBandwidthTelemetry:
        AetherHybridCarrierBandwidthTelemetry
    {
        do {
            let videoSamples = try videoProvider
                .observedBandwidthSegmentSamples()
            let audioSamples = try BlockingAsyncBridge
                .wait {
                    await self.pump
                        .observedAudioBandwidthSegmentSamples()
                }
            return BlackCarrierBandwidthTelemetryCalculator
                .calculate(
                    timeline: timeline,
                    videoSamples: videoSamples,
                    audioSamples: audioSamples
                )
        } catch {
            return .unavailable(
                audioRenditionCount:
                    metadata.count
            )
        }
    }

    var realVideoBitrateTelemetry:
        AetherHybridRealVideoBitrateTelemetry
    {
        do {
            return try BlockingAsyncBridge.wait {
                await self.pump
                    .realVideoBitrateTelemetry()
            }
        } catch {
            return .unavailable()
        }
    }

    var alternateAudioRenditions:
        [HLSAudioRenditionInfo] {
        zip(metadata, descriptors).map {
            metadata,
            descriptor in
            HLSAudioRenditionInfo(
                ordinal: metadata.ordinal,
                language: metadata.language,
                name: metadata.name,
                isDefault: metadata.isDefault,
                isAutoselect:
                    metadata.isAutoselect,
                channels:
                    descriptor.channelsAttribute
            )
        }
    }

    var nativeSubtitleRenditions: [(
        ordinal: Int,
        language: String?,
        name: String,
        isDefault: Bool,
        isAutoselect: Bool,
        isForced: Bool
    )] {
        subtitleRenditions.map {
            (
                ordinal: $0.ordinal,
                language: $0.language,
                name: $0.name,
                isDefault: $0.isDefault,
                isAutoselect: $0.isAutoselect,
                isForced: $0.isForced
            )
        }
    }

    var nativeSubtitleDefaultOrdinal: Int {
        subtitleRenditions.first(where: \.isDefault)?
            .ordinal ?? 0
    }

    var nativeSubtitleWholeProgram: Bool { false }

    func nativeSubtitleVTT(
        ordinal: Int,
        segmentIndex: Int
    ) -> String? {
        guard subtitleRenditions.indices.contains(
                ordinal
              ),
              timeline.segments.indices.contains(
                segmentIndex
              ) else {
            return nil
        }
        do {
            return try BlockingAsyncBridge.wait {
                await self.pump.subtitleVTT(
                    renditionOrdinal: ordinal,
                    segmentIndex: segmentIndex
                )
            }
        } catch {
            EngineLog.emit(
                "[HLSVODCarrierProvider] subtitle rendition unavailable ordinal=\(ordinal)",
                category: .session
            )
            return nil
        }
    }

    func alternateAudioInitSegment(
        ordinal: Int
    ) -> Data? {
        guard metadata.indices.contains(ordinal),
              isAvailable else {
            return nil
        }
        do {
            return try BlockingAsyncBridge.wait {
                try await self.pump
                    .audioInitSegment(
                        renditionOrdinal: ordinal
                    )
            }
        } catch {
            recordIfTerminal(
                Self.typed(error)
            )
            return nil
        }
    }

    func alternateAudioMediaSegment(
        ordinal: Int,
        index: Int
    ) -> Data? {
        guard metadata.indices.contains(ordinal),
              timeline.segments.indices
                .contains(index),
              isAvailable else {
            return nil
        }
        do {
            return try BlockingAsyncBridge.wait {
                try await self.pump
                    .audioMediaSegment(
                        renditionOrdinal: ordinal,
                        segmentIndex: index
                    )
            }
        } catch {
            recordIfTerminal(
                Self.typed(error)
            )
            return nil
        }
    }

    func alternateAudioMediaSegmentURL(
        ordinal: Int,
        index: Int
    ) -> URL? {
        guard metadata.indices.contains(ordinal),
              timeline.segments.indices
                .contains(index),
              isAvailable else {
            return nil
        }
        do {
            return try BlockingAsyncBridge.wait {
                try await self.pump
                    .audioMediaSegmentURL(
                        renditionOrdinal: ordinal,
                        segmentIndex: index
                    )
            }
        } catch {
            recordIfTerminal(
                Self.typed(error)
            )
            return nil
        }
    }

    func alternateAudioMediaSegmentURL(
        ordinal: Int,
        index: Int,
        onSlow: (@Sendable () -> Void)?
    ) -> URL? {
        guard let onSlow else {
            return alternateAudioMediaSegmentURL(
                ordinal: ordinal,
                index: index
            )
        }
        let signal = SlowServeSignal(
            thresholdSeconds:
                Self.slowServeThresholdSeconds,
            onSlow: onSlow
        )
        defer { signal.complete() }
        return alternateAudioMediaSegmentURL(
            ordinal: ordinal,
            index: index
        )
    }

    func sourceTrackID(
        forAudioOrdinal ordinal: Int
    ) -> Int? {
        guard metadata.indices.contains(ordinal)
        else {
            return nil
        }
        return metadata[ordinal].sourceTrackID
    }

    private var isAvailable: Bool {
        closeLock.lock()
        let available = !isClosed
        closeLock.unlock()
        failureLock.lock()
        let failed = _terminalError != nil
        failureLock.unlock()
        return available && !failed
    }

    private func requireOpen() throws {
        guard isAvailable else {
            if let terminalError {
                throw terminalError
            }
            throw HLSVODCarrierProviderError.closed
        }
    }

    private func prepareVideoSegment(
        _ index: Int
    ) -> Bool {
        guard timeline.segments.indices
            .contains(index),
              isAvailable else {
            return false
        }
        do {
            try BlockingAsyncBridge.wait {
                try await self.pump.produce(
                    throughSegment: index
                )
            }
            return true
        } catch {
            recordIfTerminal(
                Self.typed(error)
            )
            return false
        }
    }

    private func recordIfTerminal(
        _ error: HLSVODCarrierProviderError
    ) {
        if case .pump(
            .generationSuperseded
        ) = error {
            return
        }
        if case .pump(
            .retiredSegmentRequest
        ) = error {
            return
        }
        record(error)
    }

    private func record(
        _ error: HLSVODCarrierProviderError
    ) {
        failureLock.lock()
        let isFirst: Bool
        let handler:
            (@Sendable (
                HybridPlaybackSessionError
            ) -> Void)?
        if _terminalError == nil {
            _terminalError = error
            isFirst = true
            handler =
                terminalHybridPlaybackErrorHandler
        } else {
            isFirst = false
            handler = nil
        }
        failureLock.unlock()
        guard isFirst else { return }
        if let typed =
                Self.hybridPlaybackSessionError(
                    from: error
                ) {
            handler?(typed)
        }
        EngineLog.emit(
            "[HLSVODCarrierProvider] terminal error: "
                + error.localizedDescription,
            category: .session
        )
    }

    private static func typed(
        _ error: Error
    ) -> HLSVODCarrierProviderError {
        if let typed =
                error as? HLSVODCarrierProviderError {
            return typed
        }
        if let pump =
                error as? HLSVODMediaPumpError {
            return .pump(pump)
        }
        return .unexpected(
            HybridPlaybackFailureEvidence(
                stage: .provider,
                caseCode: "runtime",
                error: error
            )
        )
    }

    static func hybridPlaybackSessionError(
        from error: Error
    ) -> HybridPlaybackSessionError? {
        if let provider =
                error as? HLSVODCarrierProviderError {
            switch provider {
            case .pump(let pump):
                return hybridPlaybackSessionError(
                    from: pump
                )
            case .unexpected(let evidence):
                return .providerFailed(evidence)
            case .startupResourceMissing, .closed:
                return nil
            }
        }
        if let pump = error as? HLSVODMediaPumpError {
            guard case .origin(let origin) = pump else {
                return nil
            }
            return hybridPlaybackSessionError(
                from: origin
            )
        }
        if let origin =
                error as? HLSVODOriginResourceError {
            if case .preflightGenerationInvalidated(
                let reason
            ) = origin {
                return .hlsPreflightGenerationInvalidated(
                    reason.publicReason
                )
            }
            return .originFailed(
                originFailure(from: origin)
            )
        }
        return nil
    }

    private static func originFailure(
        from error: HLSVODOriginResourceError
    ) -> HybridPlaybackOriginFailure {
        switch error {
        case .transport(let code):
            let scope: HybridPlaybackOriginFailureScope =
                switch HLSVODOriginResourceLoader
                    .transportDisposition(for: code) {
                case .transient: .transient
                case .cancelled: .cancelled
                case .security: .security
                case .invariant: .invariant
                }
            return .init(
                scope: scope,
                caseCode: "transport",
                underlyingDomain: NSURLErrorDomain,
                underlyingCode: code.rawValue
            )
        case .transportFailure:
            return .init(
                scope: .transient,
                caseCode: "transportFailure",
                underlyingDomain: NSURLErrorDomain,
                underlyingCode: URLError.Code.unknown.rawValue
            )
        case .transportBudgetExhausted:
            return .init(
                scope: .transient,
                caseCode: "transportBudgetExhausted",
                underlyingDomain: "AetherPlaybackRecovery",
                underlyingCode: 3
            )
        case .httpStatus(let status):
            let scope: HybridPlaybackOriginFailureScope
            if status == 401 || status == 403 {
                scope = .authentication
            } else if status == 408 || status == 425
                        || status == 429 || status >= 500 {
                scope = .transient
            } else {
                scope = .malformed
            }
            return .init(
                scope: scope,
                caseCode: "httpStatus",
                underlyingDomain: "HTTP",
                underlyingCode: status
            )
        case .contentLengthMismatch, .emptyResource:
            return .init(
                scope: .transient,
                caseCode: "truncatedResponse",
                underlyingDomain: "AetherHLSOrigin",
                underlyingCode: 1
            )
        case .effectiveOriginMismatch,
             .redirectCredentialScopeViolation:
            return .init(
                scope: .security,
                caseCode: "originScope",
                underlyingDomain: "AetherHLSOrigin",
                underlyingCode: 2
            )
        case .preflightEvidenceMismatch:
            return .init(
                scope: .graphInvalidated,
                caseCode: "contentChanged",
                underlyingDomain: "AetherHLSOrigin",
                underlyingCode: 3
            )
        case .resourceTooLarge, .unsupportedContentEncoding,
             .nonHTTPResponse:
            return .init(
                scope: .malformed,
                caseCode: "invalidResponse",
                underlyingDomain: "AetherHLSOrigin",
                underlyingCode: 4
            )
        case .preflightGenerationInvalidated:
            return .init(
                scope: .graphInvalidated,
                caseCode: "generationInvalidated",
                underlyingDomain: "AetherHLSOrigin",
                underlyingCode: 5
            )
        case .closed:
            return .init(
                scope: .resource,
                caseCode: "closed",
                underlyingDomain: "AetherHLSOrigin",
                underlyingCode: 6
            )
        case .invalidLimits, .resourceNotBound,
             .cacheDirectoryCreationFailed, .cacheReadFailed,
             .cacheWriteFailed, .cacheEvictionFailed,
             .cacheCleanupFailed:
            return .init(
                scope: .resource,
                caseCode: "resourceFailure",
                underlyingDomain: "AetherHLSOrigin",
                underlyingCode: 7
            )
        }
    }
}

extension HLSVODCarrierProvider:
    HybridCarrierTransportProvider
{}

extension HLSVODCarrierProvider:
    HybridPlaybackTerminalErrorSource
{}

private enum BlockingAsyncBridge {
    private final class ResultBox<Value>:
        @unchecked Sendable
    {
        private let lock = NSLock()
        private var result: Result<Value, Error>?

        func store(
            _ result: Result<Value, Error>
        ) {
            lock.lock()
            self.result = result
            lock.unlock()
        }

        func take() -> Result<Value, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    static func wait<Value: Sendable>(
        _ operation:
            @escaping @Sendable () async throws
                -> Value
    ) throws -> Value {
        let semaphore = DispatchSemaphore(
            value: 0
        )
        let box = ResultBox<Value>()
        Task.detached(priority: .userInitiated) {
            do {
                box.store(
                    .success(
                        try await operation()
                    )
                )
            } catch {
                box.store(.failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let result = box.take() else {
            throw HLSVODCarrierProviderError
                .unexpected(
                    HybridPlaybackFailureEvidence(
                        stage: .provider,
                        caseCode: "asyncBridgeMissingResult",
                        underlyingDomain:
                            "HLSVODCarrierProvider",
                        underlyingCode: 1
                    )
                )
        }
        return try result.get()
    }
}
