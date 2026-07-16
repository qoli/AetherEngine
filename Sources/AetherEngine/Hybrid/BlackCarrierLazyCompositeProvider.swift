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
    case calibratedConstantRate(
        payloadBandwidth: Int,
        peakBandwidth: Int,
        averageBandwidth: Int,
        sampleRate: Int,
        channelCount: Int,
        measuredSegmentCount: Int
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
        case .calibratedConstantRate(
            _,
            let peakBandwidth,
            _,
            _,
            _,
            _
        ):
            return peakBandwidth
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
        case .calibratedConstantRate(
            _,
            _,
            let averageBandwidth,
            _,
            _,
            _
        ):
            return averageBandwidth
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
        case .calibratedConstantRate(
            let payload,
            let peak,
            let average,
            let sampleRate,
            let channelCount,
            let measuredSegmentCount
        ):
            return payload > 0
                && peak >= payload
                && average >= payload
                && peak >= average
                && sampleRate > 0
                && channelCount > 0
                && measuredSegmentCount > 0
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

enum BlackCarrierConstantRateBandwidthCalibrationError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case invalidTimeline
    case invalidProfile(ordinal: Int)
    case syntheticSourceTooLarge
    case segmentMissing(ordinal: Int, index: Int)
    case byteCountOverflow(ordinal: Int)
    case outputContractMismatch(ordinal: Int)

    var errorDescription: String? {
        switch self {
        case .invalidTimeline:
            return "Constant-rate bandwidth calibration requires a fixed four-second file-VOD timeline"
        case .invalidProfile(let ordinal):
            return "Constant-rate bandwidth calibration profile \(ordinal) is invalid"
        case .syntheticSourceTooLarge:
            return "Constant-rate bandwidth calibration source exceeds its bounded RIFF size"
        case .segmentMissing(let ordinal, let index):
            return "Constant-rate bandwidth calibration rendition \(ordinal) did not emit segment \(index)"
        case .byteCountOverflow(let ordinal):
            return "Constant-rate bandwidth calibration rendition \(ordinal) byte count overflowed"
        case .outputContractMismatch(let ordinal):
            return "Constant-rate bandwidth calibration rendition \(ordinal) changed its EAC3 output contract"
        }
    }
}

enum BlackCarrierConstantRateBandwidthCalibration {
    private struct TimelinePlan {
        let calibrationTimeline: BlackCarrierTimeline
        let fullSegmentCount: Int
        let tailDuration: CMTime?
    }

    static func admissions(
        descriptors: [BlackCarrierAudioRenditionDescriptor],
        timeline: BlackCarrierTimeline
    ) throws -> [BlackCarrierAudioBandwidthAdmission]? {
        guard timeline.source == .fixedFileVOD,
              !descriptors.isEmpty else {
            return nil
        }
        let profiles = descriptors.map(\.constantRateBridgeProfile)
        guard profiles.allSatisfy({ $0 != nil }) else {
            return nil
        }
        let resolvedProfiles = profiles.compactMap { $0 }
        let timelineSeconds = timeline.duration.seconds
        guard timelineSeconds.isFinite, timelineSeconds > 0 else {
            throw BlackCarrierConstantRateBandwidthCalibrationError
                .invalidTimeline
        }
        for (ordinal, profile) in resolvedProfiles.enumerated() {
            let durationTolerance =
                1 / Double(profile.sampleRate)
            guard profile.sampleRate == 48_000,
                  profile.channelCount > 0,
                  profile.channelCount <= 6,
                  profile.payloadBandwidth > 0,
                  abs(
                      profile.sourceDurationSeconds
                          - timelineSeconds
                  ) <= durationTolerance else {
                return nil
            }
            guard descriptors[ordinal].pipeline == .bridge(
                mode: .surroundCompat,
                codecString: "ec-3"
            ) else {
                throw BlackCarrierConstantRateBandwidthCalibrationError
                    .invalidProfile(ordinal: ordinal)
            }
        }

        let plan = try timelinePlan(for: timeline)
        return try zip(descriptors.indices, resolvedProfiles).map {
            ordinal,
            profile in
            let evidence = try calibrate(
                ordinal: ordinal,
                descriptor: descriptors[ordinal],
                profile: profile,
                originalTimeline: timeline,
                plan: plan
            )
            return BlackCarrierAudioBandwidthAdmission(
                ordinal: ordinal,
                evidence: evidence
            )
        }
    }

    private static func timelinePlan(
        for timeline: BlackCarrierTimeline
    ) throws -> TimelinePlan {
        let profile = BlackCarrierProfile.approved
        let fullTicks =
            profile.nominalFileSegmentDurationTicks
        guard !timeline.segments.isEmpty else {
            throw BlackCarrierConstantRateBandwidthCalibrationError
                .invalidTimeline
        }
        let tail = timeline.segments.last.flatMap {
            $0.duration.value == fullTicks ? nil : $0.duration
        }
        let fullCount =
            timeline.segments.count - (tail == nil ? 0 : 1)
        guard fullCount >= 0,
              timeline.segments
                .prefix(fullCount)
                .allSatisfy({
                    $0.duration.timescale == profile.timescale
                        && $0.duration.value == fullTicks
                }) else {
            throw BlackCarrierConstantRateBandwidthCalibrationError
                .invalidTimeline
        }

        let calibratedFullCount = min(fullCount, 2)
        var durationTicks =
            Int64(calibratedFullCount) * fullTicks
        if let tail {
            let converted = CMTimeConvertScale(
                tail,
                timescale: profile.timescale,
                method: .roundHalfAwayFromZero
            )
            let sum = durationTicks.addingReportingOverflow(
                converted.value
            )
            guard !sum.overflow else {
                throw BlackCarrierConstantRateBandwidthCalibrationError
                    .invalidTimeline
            }
            durationTicks = sum.partialValue
        }
        guard durationTicks > 0 else {
            throw BlackCarrierConstantRateBandwidthCalibrationError
                .invalidTimeline
        }
        let calibrationTimeline =
            try BlackCarrierTimeline.fileVOD(
                duration: CMTime(
                    value: durationTicks,
                    timescale: profile.timescale
                )
            )
        return TimelinePlan(
            calibrationTimeline: calibrationTimeline,
            fullSegmentCount: fullCount,
            tailDuration: tail
        )
    }

    private static func calibrate(
        ordinal: Int,
        descriptor: BlackCarrierAudioRenditionDescriptor,
        profile: BlackCarrierConstantRateBridgeProfile,
        originalTimeline: BlackCarrierTimeline,
        plan: TimelinePlan
    ) throws -> BlackCarrierAudioBandwidthEvidence {
        let data = try syntheticWAV(
            sampleRate: profile.sampleRate,
            channelCount: profile.channelCount,
            duration: plan.calibrationTimeline.duration
        )
        let demuxer = Demuxer()
        try demuxer.open(
            reader: DataIOReader(data: data),
            formatHint: "wav"
        )
        defer { demuxer.close() }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AetherBandwidthCalibration-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        var segmentBytes: [Int: Int] = [:]
        let summary = try BlackCarrierAudioRenditionMuxer.mux(
            demuxer: demuxer,
            audioStreamIndex: demuxer.audioStreamIndex,
            sourceStartPTS: 0,
            timeline: plan.calibrationTimeline,
            bridgeMode: .surroundCompat,
            sessionDirectory: directory,
            onInit: { _ in },
            onSegment: { timing, _, bytesWritten in
                segmentBytes[timing.index] = bytesWritten
            }
        )
        guard summary.pipeline == descriptor.pipeline,
              summary.codecString == descriptor.codecString,
              summary.channelsAttribute
                == descriptor.channelsAttribute,
              summary.declaredCodecInitialPaddingSamples
                == descriptor.declaredCodecInitialPaddingSamples else {
            throw BlackCarrierConstantRateBandwidthCalibrationError
                .outputContractMismatch(ordinal: ordinal)
        }

        let fullDuration = Double(
            BlackCarrierProfile.approved
                .nominalFileSegmentDurationTicks
        ) / Double(BlackCarrierProfile.approved.timescale)
        var totalBytes: Int64 = 0
        var peakBandwidth = 0
        var measuredSegmentCount = 0
        if plan.fullSegmentCount > 0 {
            let firstBytes = try requiredBytes(
                segmentBytes,
                ordinal: ordinal,
                index: 0
            )
            totalBytes = try adding(
                totalBytes,
                Int64(firstBytes),
                ordinal: ordinal
            )
            peakBandwidth = max(
                peakBandwidth,
                bandwidth(bytes: firstBytes, duration: fullDuration)
            )
            measuredSegmentCount += 1

            if plan.fullSegmentCount > 1 {
                let steadyBytes = try requiredBytes(
                    segmentBytes,
                    ordinal: ordinal,
                    index: 1
                )
                let repeated = Int64(plan.fullSegmentCount - 1)
                    .multipliedReportingOverflow(
                        by: Int64(steadyBytes)
                    )
                guard !repeated.overflow else {
                    throw BlackCarrierConstantRateBandwidthCalibrationError
                        .byteCountOverflow(ordinal: ordinal)
                }
                totalBytes = try adding(
                    totalBytes,
                    repeated.partialValue,
                    ordinal: ordinal
                )
                peakBandwidth = max(
                    peakBandwidth,
                    bandwidth(
                        bytes: steadyBytes,
                        duration: fullDuration
                    )
                )
                measuredSegmentCount += 1
            }
        }
        if let tailDuration = plan.tailDuration {
            let tailIndex = min(plan.fullSegmentCount, 2)
            let tailBytes = try requiredBytes(
                segmentBytes,
                ordinal: ordinal,
                index: tailIndex
            )
            totalBytes = try adding(
                totalBytes,
                Int64(tailBytes),
                ordinal: ordinal
            )
            peakBandwidth = max(
                peakBandwidth,
                bandwidth(
                    bytes: tailBytes,
                    duration: tailDuration.seconds
                )
            )
            measuredSegmentCount += 1
        }

        let averageBandwidth = Int(
            ceil(
                Double(totalBytes) * 8
                    / originalTimeline.duration.seconds
            )
        )
        return .calibratedConstantRate(
            payloadBandwidth: profile.payloadBandwidth,
            peakBandwidth: peakBandwidth,
            averageBandwidth: averageBandwidth,
            sampleRate: profile.sampleRate,
            channelCount: profile.channelCount,
            measuredSegmentCount: measuredSegmentCount
        )
    }

    private static func requiredBytes(
        _ segmentBytes: [Int: Int],
        ordinal: Int,
        index: Int
    ) throws -> Int {
        guard let bytes = segmentBytes[index], bytes > 0 else {
            throw BlackCarrierConstantRateBandwidthCalibrationError
                .segmentMissing(ordinal: ordinal, index: index)
        }
        return bytes
    }

    private static func adding(
        _ lhs: Int64,
        _ rhs: Int64,
        ordinal: Int
    ) throws -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            throw BlackCarrierConstantRateBandwidthCalibrationError
                .byteCountOverflow(ordinal: ordinal)
        }
        return result.partialValue
    }

    private static func bandwidth(
        bytes: Int,
        duration: Double
    ) -> Int {
        Int(ceil(Double(bytes) * 8 / duration))
    }

    private static func syntheticWAV(
        sampleRate: Int,
        channelCount: Int,
        duration: CMTime
    ) throws -> Data {
        let seconds = duration.seconds
        guard seconds.isFinite,
              seconds > 0,
              sampleRate > 0,
              channelCount > 0 else {
            throw BlackCarrierConstantRateBandwidthCalibrationError
                .invalidTimeline
        }
        let frameCount = Int(
            ceil(seconds * Double(sampleRate))
        )
        let payload = frameCount
            .multipliedReportingOverflow(
                by: channelCount * MemoryLayout<Int16>.size
            )
        guard !payload.overflow,
              payload.partialValue <= Int(UInt32.max) - 36 else {
            throw BlackCarrierConstantRateBandwidthCalibrationError
                .syntheticSourceTooLarge
        }

        var data = Data()
        data.reserveCapacity(44 + payload.partialValue)
        func appendASCII(_ value: String) {
            data.append(value.data(using: .ascii)!)
        }
        func appendUInt16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        let blockAlign = channelCount
            * MemoryLayout<Int16>.size
        appendASCII("RIFF")
        appendUInt32(UInt32(36 + payload.partialValue))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(UInt16(channelCount))
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * blockAlign))
        appendUInt16(UInt16(blockAlign))
        appendUInt16(16)
        appendASCII("data")
        appendUInt32(UInt32(payload.partialValue))
        data.append(Data(count: payload.partialValue))
        return data
    }
}

enum BlackCarrierAudioBandwidthPreflight {
    static func measure(
        sourceFactory: BlackCarrierDemuxSourceFactory,
        timeline: BlackCarrierTimeline,
        bridgeMode: AudioBridgeMode
    ) throws -> BlackCarrierAudioBandwidthMeasurement {
        EngineLog.emit(
            "[BlackCarrierAudioBandwidthPreflight] admission started",
            category: .session
        )
        let pump = try BlackCarrierMediaFanoutPump.makeSeekableVOD(
            sourceFactory: sourceFactory,
            ownsSourceFactory: false,
            timeline: timeline,
            bridgeMode: bridgeMode
        )
        do {
            if let admissions =
                    try BlackCarrierConstantRateBandwidthCalibration
                        .admissions(
                            descriptors: pump.renditionDescriptors,
                            timeline: timeline
                        ) {
                pump.close()
                EngineLog.emit(
                    "[BlackCarrierAudioBandwidthPreflight] "
                        + "bounded constant-rate calibration completed "
                        + admissions.map {
                            "audio[\($0.ordinal)] "
                                + "peak=\($0.evidence.peakBandwidth) "
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
        } catch {
            pump.close()
            throw error
        }
        EngineLog.emit(
            "[BlackCarrierAudioBandwidthPreflight] "
                + "strategy=full-asset-measurement",
            category: .session
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

        guard !pump.renditionMetadata.isEmpty else {
            EngineLog.emit(
                "[BlackCarrierAudioBandwidthPreflight] skipped "
                    + "reason=no-audio-renditions",
                category: .session
            )
            do {
                return try BlackCarrierLazyCompositeProvider(
                    videoProvider: videoProvider,
                    pump: pump,
                    bandwidthAdmissions: []
                )
            } catch {
                pump.close()
                videoProvider.close()
                throw error
            }
        }

        let measurement: BlackCarrierAudioBandwidthMeasurement
        do {
            measurement = try BlackCarrierAudioBandwidthPreflight.measure(
                sourceFactory: sourceFactory,
                timeline: timeline,
                bridgeMode: bridgeMode
            )
        } catch {
            pump.close()
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
