import CoreMedia
import Foundation

enum BlackCarrierAudioBandwidthEvidence: Sendable, Equatable {
    case measuredFullAsset(
        peakBandwidth: Int,
        averageBandwidth: Int
    )
    case verifiedConstantRate(
        payloadBandwidth: Int,
        maximumContainerOverhead: Int,
        averageContainerOverhead: Int
    )

    var peakBandwidth: Int {
        switch self {
        case .measuredFullAsset(let peakBandwidth, _):
            return peakBandwidth
        case .verifiedConstantRate(
            let payloadBandwidth,
            let maximumContainerOverhead,
            _
        ):
            return payloadBandwidth + maximumContainerOverhead
        }
    }

    var averageBandwidth: Int {
        switch self {
        case .measuredFullAsset(_, let averageBandwidth):
            return averageBandwidth
        case .verifiedConstantRate(
            let payloadBandwidth,
            _,
            let averageContainerOverhead
        ):
            return payloadBandwidth + averageContainerOverhead
        }
    }

    var isValid: Bool {
        switch self {
        case .measuredFullAsset(let peak, let average):
            return peak > 0 && average > 0 && peak >= average
        case .verifiedConstantRate(
            let payload,
            let maximumOverhead,
            let averageOverhead
        ):
            return payload > 0
                && maximumOverhead >= 0
                && averageOverhead >= 0
                && maximumOverhead >= averageOverhead
        }
    }
}

struct BlackCarrierAudioBandwidthAdmission: Sendable, Equatable {
    let ordinal: Int
    let evidence: BlackCarrierAudioBandwidthEvidence
}

struct BlackCarrierAudioBandwidthMeasurement: Sendable, Equatable {
    let sourceContract: BlackCarrierDemuxContract
    let renditionMetadata: [BlackCarrierAudioRenditionMetadata]
    let renditionDescriptors: [BlackCarrierAudioRenditionDescriptor]
    let admissions: [BlackCarrierAudioBandwidthAdmission]
}

enum BlackCarrierAudioBandwidthPreflight {
    static func measure(
        sourceFactory: BlackCarrierDemuxSourceFactory,
        timeline: BlackCarrierTimeline,
        bridgeMode: AudioBridgeMode
    ) throws -> BlackCarrierAudioBandwidthMeasurement {
        EngineLog.emit(
            "[BlackCarrierAudioBandwidthPreflight] full-asset measurement started",
            category: .session
        )
        let pump = try BlackCarrierMediaFanoutPump.makeSeekableVOD(
            sourceFactory: sourceFactory,
            ownsSourceFactory: false,
            timeline: timeline,
            bridgeMode: bridgeMode
        )
        let stores = try pump.finishStores()
        defer { stores.forEach { $0.close() } }
        let admissions = stores.map {
            BlackCarrierAudioBandwidthAdmission(
                ordinal: $0.metadata.ordinal,
                evidence: .measuredFullAsset(
                    peakBandwidth: $0.peakBandwidth,
                    averageBandwidth: $0.averageBandwidth
                )
            )
        }
        EngineLog.emit(
            "[BlackCarrierAudioBandwidthPreflight] full-asset measurement completed "
                + admissions.map {
                    "audio[\($0.ordinal)] peak=\($0.evidence.peakBandwidth) "
                        + "average=\($0.evidence.averageBandwidth)"
                }.joined(separator: " "),
            category: .session
        )
        return BlackCarrierAudioBandwidthMeasurement(
            sourceContract: pump.sourceContract,
            renditionMetadata: pump.renditionMetadata,
            renditionDescriptors: pump.renditionDescriptors,
            admissions: admissions
        )
    }
}

enum BlackCarrierLazyCompositeProviderError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case admissionCountMismatch(expected: Int, actual: Int)
    case admissionOrdinalMismatch(expected: Int, actual: Int)
    case invalidBandwidthEvidence(ordinal: Int)
    case bandwidthMeasurementContractMismatch
    case startupResourceMissing(ordinal: Int)
    case pump(BlackCarrierMediaFanoutPumpError)

    var errorDescription: String? {
        switch self {
        case .admissionCountMismatch(let expected, let actual):
            return "Lazy carrier requires \(expected) audio bandwidth admissions, found \(actual)"
        case .admissionOrdinalMismatch(let expected, let actual):
            return "Lazy carrier audio bandwidth ordinal \(actual) is invalid; expected \(expected)"
        case .invalidBandwidthEvidence(let ordinal):
            return "Lazy carrier audio rendition \(ordinal) has invalid peak-bandwidth evidence"
        case .bandwidthMeasurementContractMismatch:
            return "Lazy carrier playback tracks changed after bandwidth measurement"
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
/// admitted only with explicit evidence; this type never substitutes the old fixed 5 Mbps fallback.
final class BlackCarrierLazyCompositeProvider:
    BlackCarrierTransportProvider,
    @unchecked Sendable
{
    private let videoProvider: BlackCarrierVideoProvider
    private let pump: BlackCarrierMediaFanoutPump
    private let codecs: String
    private let bandwidth: Int
    private let averageBandwidth: Int
    private let closeLock = NSLock()
    private var isClosed = false
    private let failureLock = NSLock()
    private var _terminalError: BlackCarrierLazyCompositeProviderError?

    init(
        videoProvider: BlackCarrierVideoProvider,
        pump: BlackCarrierMediaFanoutPump,
        bandwidthAdmissions: [BlackCarrierAudioBandwidthAdmission]
    ) throws {
        guard pump.supportsFreshDemuxRestart else {
            videoProvider.close()
            pump.close()
            throw BlackCarrierLazyCompositeProviderError.pump(
                .freshDemuxerFactoryMissing
            )
        }
        let expectedCount = pump.renditionMetadata.count
        guard bandwidthAdmissions.count == expectedCount else {
            videoProvider.close()
            pump.close()
            throw BlackCarrierLazyCompositeProviderError
                .admissionCountMismatch(
                    expected: expectedCount,
                    actual: bandwidthAdmissions.count
                )
        }
        for (expectedOrdinal, admission) in bandwidthAdmissions.enumerated() {
            guard admission.ordinal == expectedOrdinal else {
                videoProvider.close()
                pump.close()
                throw BlackCarrierLazyCompositeProviderError
                    .admissionOrdinalMismatch(
                        expected: expectedOrdinal,
                        actual: admission.ordinal
                    )
            }
            guard admission.evidence.isValid else {
                videoProvider.close()
                pump.close()
                throw BlackCarrierLazyCompositeProviderError
                    .invalidBandwidthEvidence(ordinal: admission.ordinal)
            }
        }

        self.videoProvider = videoProvider
        self.pump = pump

        var uniqueCodecs = [BlackCarrierProfile.approved.codecString]
        for descriptor in pump.renditionDescriptors
        where !uniqueCodecs.contains(descriptor.codecString) {
            uniqueCodecs.append(descriptor.codecString)
        }
        codecs = uniqueCodecs.joined(separator: ",")

        bandwidth = max(
            1,
            (videoProvider.masterBandwidth ?? 0)
                + (bandwidthAdmissions.map {
                    $0.evidence.peakBandwidth
                }.max() ?? 0)
        )
        averageBandwidth = max(
            1,
            (videoProvider.masterAverageBandwidth ?? 0)
                + (bandwidthAdmissions.map {
                    $0.evidence.averageBandwidth
                }.max() ?? 0)
        )
    }

    convenience init(
        videoProvider: BlackCarrierVideoProvider,
        pump: BlackCarrierMediaFanoutPump,
        bandwidthMeasurement: BlackCarrierAudioBandwidthMeasurement
    ) throws {
        guard bandwidthMeasurement.sourceContract
                == pump.sourceContract,
              bandwidthMeasurement.renditionMetadata
                == pump.renditionMetadata,
              bandwidthMeasurement.renditionDescriptors
                == pump.renditionDescriptors else {
            videoProvider.close()
            pump.close()
            throw BlackCarrierLazyCompositeProviderError
                .bandwidthMeasurementContractMismatch
        }
        try self.init(
            videoProvider: videoProvider,
            pump: pump,
            bandwidthAdmissions: bandwidthMeasurement.admissions
        )
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

        let measurement: BlackCarrierAudioBandwidthMeasurement
        do {
            measurement = try BlackCarrierAudioBandwidthPreflight.measure(
                sourceFactory: sourceFactory,
                timeline: timeline,
                bridgeMode: bridgeMode
            )
        } catch {
            sourceFactory.close()
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
                pump: pump,
                bandwidthMeasurement: measurement
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
    var masterBandwidth: Int? { bandwidth }
    var masterAverageBandwidth: Int? { averageBandwidth }
    var masterFrameRate: Double? {
        videoProvider.masterFrameRate
    }
    var masterClosedCaptions: String? {
        videoProvider.masterClosedCaptions
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
