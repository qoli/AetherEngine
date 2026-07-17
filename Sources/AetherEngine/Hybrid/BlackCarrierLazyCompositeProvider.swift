import CoreMedia
import Foundation

enum BlackCarrierLazyCompositeProviderError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case startupResourceMissing(ordinal: Int)
    case pump(BlackCarrierMediaFanoutPumpError)

    var errorDescription: String? {
        switch self {
        case .startupResourceMissing(let ordinal):
            return "Lazy carrier audio rendition \(ordinal) did not produce its startup init and segment"
        case .pump(let error):
            return error.localizedDescription
        }
    }
}

/// HLS provider whose alternate-audio requests advance one incremental shared-demux pump.
///
/// The black video representation remains deterministic and prebuilt. Real audio init/segments are
/// generated through `BlackCarrierMediaFanoutPump` only as AVPlayer needs them. Master bandwidth is
/// the fixed 2 Mbps AVPlayer loopback transport budget. The value is the primary local-transport
/// policy, not a source estimate or a fallback for missing evidence.
final class BlackCarrierLazyCompositeProvider:
    BlackCarrierTransportProvider,
    HybridCarrierBandwidthTelemetrySource,
    HybridOverlaySubtitleSource,
    @unchecked Sendable
{
    private let videoProvider: BlackCarrierVideoProvider
    private let pump: BlackCarrierMediaFanoutPump
    private let codecs: String
    private let closeLock = NSLock()
    private var isClosed = false
    private let failureLock = NSLock()
    private var _terminalError: BlackCarrierLazyCompositeProviderError?

    init(
        videoProvider: BlackCarrierVideoProvider,
        pump: BlackCarrierMediaFanoutPump
    ) throws {
        guard pump.supportsFreshDemuxRestart else {
            videoProvider.close()
            pump.close()
            throw BlackCarrierLazyCompositeProviderError.pump(
                .freshDemuxerFactoryMissing
            )
        }
        self.videoProvider = videoProvider
        self.pump = pump

        var uniqueCodecs = [BlackCarrierProfile.approved.codecString]
        for descriptor in pump.renditionDescriptors
        where !uniqueCodecs.contains(descriptor.codecString) {
            uniqueCodecs.append(descriptor.codecString)
        }
        codecs = uniqueCodecs.joined(separator: ",")

    }

    static func buildSeekableVOD(
        videoProvider: BlackCarrierVideoProvider,
        source: MediaSource,
        options: LoadOptions,
        timeline: BlackCarrierTimeline,
        bridgeMode: AudioBridgeMode = .surroundCompat,
        videoPacketSink: BlackCarrierMediaFanoutPump.VideoPacketSink? = nil,
        decodedFrameHandler: HybridVideoDecodeSink.FrameHandler? = nil,
        videoFailureHandler: HybridVideoDecodeSink.FailureHandler? = nil,
        initialGeneration: UInt64 = 0,
        selectTitleID: Int? = nil
    ) throws -> BlackCarrierLazyCompositeProvider {
        let sourceFactory: BlackCarrierDemuxSourceFactory
        do {
            sourceFactory = try BlackCarrierDemuxSourceFactory.adopting(
                source: source,
                options: options,
                selectTitleID: selectTitleID
            )
        } catch {
            videoProvider.close()
            throw error
        }

        let pump: BlackCarrierMediaFanoutPump
        do {
            pump = try BlackCarrierMediaFanoutPump.makeSeekableVOD(
                sourceFactory: sourceFactory,
                ownsSourceFactory: true,
                timeline: timeline,
                bridgeMode: bridgeMode,
                videoPacketSink: videoPacketSink,
                decodedFrameHandler: decodedFrameHandler,
                videoFailureHandler: videoFailureHandler,
                initialGeneration: initialGeneration
            )
        } catch {
            sourceFactory.close()
            videoProvider.close()
            throw error
        }

        do {
            return try BlackCarrierLazyCompositeProvider(
                videoProvider: videoProvider,
                pump: pump
            )
        } catch {
            pump.close()
            videoProvider.close()
            throw error
        }
    }

    deinit {
        close()
    }

    var terminalError: BlackCarrierLazyCompositeProviderError? {
        failureLock.lock()
        defer { failureLock.unlock() }
        return _terminalError
    }

    var hybridVideoFormat: VideoFormat? {
        pump.hybridVideoFormat
    }

    var hybridVideoFrameRate: Double? {
        pump.hybridVideoFrameRate
    }

    var hybridSubtitleContracts:
        [HybridSubtitleDecodeContract]
    {
        pump.hybridSubtitleContracts
    }

    var hybridSubtitlePacketStore: SubtitlePacketStore {
        pump.hybridSubtitlePacketStore
    }

    var hybridSubtitleRuntimeAvailability:
        HybridSubtitleRuntimeAvailabilityStore
    {
        pump.hybridSubtitleRuntimeAvailability
    }

    var audioAnalysisTrackIDs: [Int] {
        pump.renditionMetadata.map(\.sourceTrackID)
    }

    func makeAudioAnalysisInput() throws -> AudioAnalysisInput {
        try pump.makeAudioAnalysisInput()
    }

    func prepareForTransportStart() throws {
        do {
            for ordinal in pump.renditionMetadata.indices {
                guard try pump.initSegment(ordinal: ordinal) != nil,
                      pump.peekMediaSegmentURL(
                          ordinal: ordinal,
                          index: 0
                      ) != nil else {
                    let error = BlackCarrierLazyCompositeProviderError
                        .startupResourceMissing(ordinal: ordinal)
                    record(error)
                    throw error
                }
            }
            try pump.produce(throughSegment: 0)
        } catch let error as BlackCarrierMediaFanoutPumpError {
            let typed = BlackCarrierLazyCompositeProviderError.pump(error)
            record(typed)
            throw typed
        }
    }

    func restartMedia(
        for intent: HybridSeekIntent
    ) throws -> BlackCarrierMediaFanoutRestartResult {
        do {
            return try pump.restart(for: intent)
        } catch let error as BlackCarrierMediaFanoutPumpError {
            record(.pump(error))
            throw error
        } catch {
            let typed = BlackCarrierMediaFanoutPumpError.demuxFailed(
                reason: String(describing: error)
            )
            record(.pump(typed))
            throw typed
        }
    }

    func advanceVideoDecodeDemand(to time: CMTime) throws {
        do {
            try pump.advanceVideoDecodeDemand(to: time)
        } catch let error as BlackCarrierMediaFanoutPumpError {
            record(.pump(error))
            throw error
        } catch {
            let typed = BlackCarrierMediaFanoutPumpError.demuxFailed(
                reason: String(describing: error)
            )
            record(.pump(typed))
            throw typed
        }
    }

    func prepareHybridGeneration(segmentIndex: Int) throws {
        do {
            try pump.produce(throughSegment: segmentIndex)
        } catch let error as BlackCarrierMediaFanoutPumpError {
            let typed = BlackCarrierLazyCompositeProviderError.pump(error)
            record(typed)
            throw typed
        } catch {
            let typed = BlackCarrierMediaFanoutPumpError.demuxFailed(
                reason: String(describing: error)
            )
            record(.pump(typed))
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
        pump.close()
    }

    func initSegment() -> Data? {
        videoProvider.initSegment()
    }

    func mediaSegment(at index: Int) -> Data? {
        guard prepareVideoSegment(index: index) else { return nil }
        return videoProvider.mediaSegment(at: index)
    }

    func mediaSegmentURL(at index: Int) -> URL? {
        guard prepareVideoSegment(index: index) else { return nil }
        return videoProvider.mediaSegmentURL(at: index)
    }

    var segmentCount: Int { videoProvider.segmentCount }

    func segmentDuration(at index: Int) -> Double {
        videoProvider.segmentDuration(at: index)
    }

    var playlistType: HLSPlaylistType { videoProvider.playlistType }
    var masterCodecs: String? { codecs }
    var masterResolution: (width: Int, height: Int)? {
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
            return pump.carrierBandwidthTelemetry(
                videoSamples:
                    try videoProvider
                        .observedBandwidthSegmentSamples()
            )
        } catch {
            return .unavailable(
                audioRenditionCount:
                    pump.renditionMetadata.count
            )
        }
    }

    var alternateAudioRenditions: [HLSAudioRenditionInfo] {
        zip(pump.renditionMetadata, pump.renditionDescriptors).map {
            metadata,
            descriptor in
            HLSAudioRenditionInfo(
                ordinal: metadata.ordinal,
                language: metadata.language,
                name: metadata.name,
                isDefault: metadata.isDefault,
                isAutoselect: metadata.isAutoselect,
                channels: descriptor.channelsAttribute
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
        pump.nativeSubtitleRenditionMetadata.map {
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
        pump.nativeSubtitleRenditionMetadata
            .first(where: \.isDefault)?.ordinal ?? 0
    }

    var nativeSubtitleWholeProgram: Bool { false }

    func nativeSubtitleVTT(
        ordinal: Int,
        segmentIndex: Int
    ) -> String? {
        guard pump.nativeSubtitleRenditionMetadata.indices
                .contains(ordinal),
              0..<segmentCount ~= segmentIndex else {
            return nil
        }
        do {
            return try pump.nativeSubtitleVTT(
                ordinal: ordinal,
                segmentIndex: segmentIndex
            )
        } catch let error as BlackCarrierMediaFanoutPumpError {
            if case .generationSuperseded = error {
                return nil
            }
            recordIfTerminal(error)
            return nil
        } catch {
            record(.pump(.demuxFailed(
                reason: String(describing: error)
            )))
            return nil
        }
    }

    func alternateAudioInitSegment(ordinal: Int) -> Data? {
        guard pump.renditionMetadata.indices.contains(ordinal) else {
            return nil
        }
        do {
            return try pump.initSegment(ordinal: ordinal)
        } catch let error as BlackCarrierMediaFanoutPumpError {
            recordIfTerminal(error)
            return nil
        } catch {
            record(.pump(.demuxFailed(reason: String(describing: error))))
            return nil
        }
    }

    func alternateAudioMediaSegment(
        ordinal: Int,
        index: Int
    ) -> Data? {
        guard pump.renditionMetadata.indices.contains(ordinal),
              0..<segmentCount ~= index else {
            return nil
        }
        do {
            return try pump.mediaSegment(
                ordinal: ordinal,
                index: index
            )
        } catch let error as BlackCarrierMediaFanoutPumpError {
            recordIfTerminal(error)
            return nil
        } catch {
            record(.pump(.demuxFailed(reason: String(describing: error))))
            return nil
        }
    }

    func alternateAudioMediaSegmentURL(
        ordinal: Int,
        index: Int
    ) -> URL? {
        guard pump.renditionMetadata.indices.contains(ordinal),
              0..<segmentCount ~= index else {
            return nil
        }
        do {
            return try pump.mediaSegmentURL(
                ordinal: ordinal,
                index: index
            )
        } catch let error as BlackCarrierMediaFanoutPumpError {
            recordIfTerminal(error)
            return nil
        } catch {
            record(.pump(.demuxFailed(reason: String(describing: error))))
            return nil
        }
    }

    func sourceTrackID(forAudioOrdinal ordinal: Int) -> Int? {
        guard pump.renditionMetadata.indices.contains(ordinal) else {
            return nil
        }
        return pump.renditionMetadata[ordinal].sourceTrackID
    }

    private func record(_ error: BlackCarrierLazyCompositeProviderError) {
        failureLock.lock()
        let isFirstError: Bool
        if _terminalError == nil {
            _terminalError = error
            isFirstError = true
        } else {
            isFirstError = false
        }
        failureLock.unlock()
        guard isFirstError else { return }
        EngineLog.emit(
            "[BlackCarrierLazyCompositeProvider] terminal error: "
                + error.localizedDescription,
            category: .session
        )
    }

    private func recordIfTerminal(
        _ error: BlackCarrierMediaFanoutPumpError
    ) {
        if case .generationSuperseded = error {
            return
        }
        record(.pump(error))
    }

    private func prepareVideoSegment(index: Int) -> Bool {
        guard 0..<segmentCount ~= index else { return false }
        do {
            try pump.produce(throughSegment: index)
            return true
        } catch let error as BlackCarrierMediaFanoutPumpError {
            recordIfTerminal(error)
            return false
        } catch {
            record(.pump(.demuxFailed(reason: String(describing: error))))
            return false
        }
    }
}
