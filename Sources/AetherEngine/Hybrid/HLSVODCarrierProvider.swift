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
    case unexpected(reason: String)

    var errorDescription: String? {
        switch self {
        case .startupResourceMissing(let ordinal):
            "HLS VOD carrier audio rendition \(ordinal) did not produce startup init and segment 0"
        case .pump(let error):
            error.localizedDescription
        case .closed:
            "HLS VOD carrier provider is closed"
        case .unexpected(let reason):
            "HLS VOD carrier provider failed unexpectedly: \(reason)"
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
    @unchecked Sendable
{
    private let videoProvider: BlackCarrierVideoProvider
    private let pump: HLSVODMediaPump
    private let metadata:
        [BlackCarrierAudioRenditionMetadata]
    private let descriptors:
        [BlackCarrierAudioRenditionDescriptor]
    private let timeline: BlackCarrierTimeline
    private let codecs: String
    private let resolvedHybridVideoFormat: VideoFormat?
    private let analysisInput: AudioAnalysisInput

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
        initialGeneration: UInt64 = 0,
        maximumResourceBytes: Int =
            HLSVODOriginResourceLoader.defaultMaximumResourceBytes,
        capacityBytes: Int64 =
            HLSVODOriginResourceLoader.defaultCapacityBytes,
        baseDirectory: URL =
            FileManager.default.temporaryDirectory,
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
                    reason: String(describing: error)
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
                initialGeneration:
                    initialGeneration,
                maximumResourceBytes:
                    maximumResourceBytes,
                capacityBytes: capacityBytes,
                baseDirectory: baseDirectory,
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
                    reason: String(describing: error)
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
                EngineLog.emit(
                    "[HLSVODCarrierProvider] setup cleanup failed: "
                        + String(describing: error),
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
        self.videoProvider = videoProvider
        self.pump = pump
        self.metadata = metadata
        self.descriptors = descriptors
        self.timeline = timeline
        resolvedHybridVideoFormat =
            await pump.hybridVideoFormat
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
            EngineLog.emit(
                "[HLSVODCarrierProvider] close failed: "
                    + String(describing: error),
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
            reason: String(describing: error)
        )
    }

    static func hybridPlaybackSessionError(
        from error: Error
    ) -> HybridPlaybackSessionError? {
        if let provider =
                error as? HLSVODCarrierProviderError {
            guard case .pump(let pump) = provider else {
                return nil
            }
            return hybridPlaybackSessionError(
                from: pump
            )
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
                error as? HLSVODOriginResourceError,
           case .preflightGenerationInvalidated(
                let reason
           ) = origin {
            return .hlsPreflightGenerationInvalidated(
                reason.publicReason
            )
        }
        return nil
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
                    reason:
                        "async bridge completed without a result"
                )
        }
        return try result.get()
    }
}
