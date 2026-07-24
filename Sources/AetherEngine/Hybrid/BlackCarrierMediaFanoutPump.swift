import CoreMedia
import Foundation
import Libavcodec
import Libavformat
import Libavutil

struct BlackCarrierDemuxFailureEvidence:
    Sendable,
    Equatable
{
    let category: HybridPlaybackFailureCategory
    let caseCode: String
    let domain: String
    let code: Int

    static func capture(
        _ error: Error,
        sourceIsComplete: Bool = false
    )
        -> BlackCarrierDemuxFailureEvidence?
    {
        if let avio = error as? AVIOReaderError {
            return captureAVIO(avio)
        }
        if let demuxer = error as? DemuxerError {
            return captureDemuxer(
                demuxer,
                sourceIsComplete: sourceIsComplete
            )
        }
        if let store = error as? SourceByteStoreError {
            return captureSourceStore(store)
        }
        return nil
    }

    private static func captureAVIO(
        _ error: AVIOReaderError
    ) -> BlackCarrierDemuxFailureEvidence {
        switch error {
        case .allocationFailed:
            return .init(
                category: .routeRuntime,
                caseCode: "avio.allocationFailed",
                domain: "AetherEngine.AVIOReader",
                code: 1
            )
        case .noResponse:
            return .init(
                category: .transientTransport,
                caseCode: "avio.noResponse",
                domain: "AetherEngine.AVIOReader",
                code: 2
            )
        case .requestTimeout:
            return .init(
                category: .transientTransport,
                caseCode: "avio.requestTimeout",
                domain: "AetherEngine.AVIOReader",
                code: 3
            )
        case .httpStatus(let statusCode):
            let category: HybridPlaybackFailureCategory
            if statusCode == 401 || statusCode == 403 {
                category = .authentication
            } else if statusCode == 408
                        || statusCode == 425
                        || statusCode == 429
                        || statusCode >= 500 {
                category = .transientTransport
            } else {
                category = .malformedMedia
            }
            return .init(
                category: category,
                caseCode: "avio.httpStatus",
                domain: "AetherEngine.AVIOReader.HTTP",
                code: statusCode
            )
        case .sourceByteStore(let sourceError):
            return captureSourceStore(sourceError)
        case .sourceByteStoreValidationFailed:
            // Validation that did not yield a typed generation mismatch is
            // inconclusive transport availability, not positive byte drift.
            return .init(
                category: .transientTransport,
                caseCode: "sourceByteStore.validationFailed",
                domain: "AetherEngine.SourceByteStore",
                code: 14
            )
        }
    }

    private static func captureSourceStore(
        _ error: SourceByteStoreError
    ) -> BlackCarrierDemuxFailureEvidence {
        let category: HybridPlaybackFailureCategory
        let caseCode: String
        let code: Int
        switch error {
        case .invalidCapacity:
            (category, caseCode, code) =
                (.invariant, "invalidCapacity", 1)
        case .invalidGeneration:
            (category, caseCode, code) =
                (.invariant, "invalidGeneration", 2)
        case .generationMismatch:
            (category, caseCode, code) =
                (.invariant, "generationMismatch", 3)
        case .unsupportedContentEncoding:
            (category, caseCode, code) =
                (.unsupportedCapability, "unsupportedContentEncoding", 4)
        case .invalidRange:
            (category, caseCode, code) =
                (.invariant, "invalidRange", 5)
        case .cancelled:
            (category, caseCode, code) =
                (.cancelled, "cancelled", 6)
        case .rangeFetchFailed:
            (category, caseCode, code) =
                (.transientTransport, "rangeFetchFailed", 7)
        case .rangeFetchRateLimited:
            (category, caseCode, code) =
                (.transientTransport, "rangeFetchRateLimited", 8)
        case .closed:
            (category, caseCode, code) =
                (.cancelled, "closed", 9)
        case .directoryCreationFailed:
            (category, caseCode, code) =
                (.routeRuntime, "directoryCreationFailed", 10)
        case .blockOpenFailed:
            (category, caseCode, code) =
                (.routeRuntime, "blockOpenFailed", 11)
        case .blockReadFailed:
            (category, caseCode, code) =
                (.routeRuntime, "blockReadFailed", 12)
        case .blockWriteFailed:
            (category, caseCode, code) =
                (.routeRuntime, "blockWriteFailed", 13)
        }
        return .init(
            category: category,
            caseCode: "sourceByteStore.\(caseCode)",
            domain: "AetherEngine.SourceByteStore",
            code: code
        )
    }

    private static func captureDemuxer(
        _ error: DemuxerError,
        sourceIsComplete: Bool
    ) -> BlackCarrierDemuxFailureEvidence {
        let category: HybridPlaybackFailureCategory
        switch error.ffmpegCode {
        case FFmpegErr.invalidData, FFmpegErr.eof:
            // INVALIDDATA/EOF from an incomplete remote generation can be a
            // truncated read. Only a complete validator-bound store turns it
            // into positive malformed-media evidence.
            category = sourceIsComplete
                ? .malformedMedia
                : .transientTransport
        case -5, FFmpegErr.eagain:
            category = .transientTransport
        default:
            category = .routeRuntime
        }
        let caseCode: String = switch error {
        case .openFailed: "demux.openFailed"
        case .streamInfoFailed: "demux.streamInfoFailed"
        case .readFailed: "demux.readFailed"
        }
        return .init(
            category: category,
            caseCode: caseCode,
            domain: "AetherEngine.Demuxer",
            code: Int(error.ffmpegCode)
        )
    }
}

enum BlackCarrierMediaFanoutPumpError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case videoStreamMissing
    case invalidRenditionOrdinal(ordinal: Int)
    case invalidSegmentIndex(index: Int)
    case restartRequiresUserSeek
    case seekIntentSegmentMismatch(expected: Int, actual: Int)
    case demuxSeekFailed(segmentIndex: Int)
    case restartTimelineOffsetUnavailable(trackID: Int)
    case freshDemuxerFactoryMissing
    case analysisSourceFactoryMissing
    case freshDemuxerOpenFailed(reason: String)
    case restartSourceContractMismatch
    case restartTrackContractMismatch
    case generationSuperseded(generation: UInt64)
    case closed
    case demuxFailure(evidence: BlackCarrierDemuxFailureEvidence)
    case demuxFailed(reason: String)
    case videoPacketSinkFailed(reason: String)
    case videoDecoderFailed(error: HybridVideoDecodeSinkError)
    case audioMuxerFailed(
        trackID: Int,
        error: BlackCarrierAudioRenditionMuxerError
    )
    case audioStoreFailed(error: BlackCarrierAudioRenditionStoreError)
    case requestedSegmentUnavailable(index: Int)

    var errorDescription: String? {
        switch self {
        case .videoStreamMissing:
            return "Black carrier media fanout video packet sink requires a real video stream"
        case .invalidRenditionOrdinal(let ordinal):
            return "Black carrier audio rendition ordinal \(ordinal) is unavailable"
        case .invalidSegmentIndex(let index):
            return "Black carrier media fanout segment \(index) is out of range"
        case .restartRequiresUserSeek:
            return "Black carrier media fanout restart requires an explicit user-seek intent"
        case .seekIntentSegmentMismatch(let expected, let actual):
            return "Black carrier seek intent segment \(actual) does not match target segment \(expected)"
        case .demuxSeekFailed(let segmentIndex):
            return "Black carrier demux could not seek to segment \(segmentIndex)"
        case .restartTimelineOffsetUnavailable(let trackID):
            return "Black carrier audio track \(trackID) has no startup timeline offset for restart"
        case .freshDemuxerFactoryMissing:
            return "Black carrier lazy restart requires a fresh-demux factory"
        case .analysisSourceFactoryMissing:
            return "Black carrier audio analysis requires the session-owned source factory"
        case .freshDemuxerOpenFailed(let reason):
            return "Black carrier fresh demux generation could not open: \(reason)"
        case .restartSourceContractMismatch:
            return "Black carrier fresh demux generation changed the admitted source contract"
        case .restartTrackContractMismatch:
            return "Black carrier fresh demux generation changed the admitted track contract"
        case .generationSuperseded(let generation):
            return "Black carrier generation \(generation) was superseded by an explicit seek"
        case .closed:
            return "Black carrier media fanout pump is closed"
        case .demuxFailure(let evidence):
            return "Black carrier media fanout demux failed at "
                + "\(evidence.caseCode) "
                + "(\(evidence.domain):\(evidence.code))"
        case .demuxFailed(let reason):
            return "Black carrier media fanout demux failed: \(reason)"
        case .videoPacketSinkFailed(let reason):
            return "Black carrier real-video packet sink failed: \(reason)"
        case .videoDecoderFailed(let error):
            return "Black carrier real-video decoder failed: \(error.localizedDescription)"
        case .audioMuxerFailed(let trackID, let error):
            return "Black carrier audio track \(trackID) failed: \(error.localizedDescription)"
        case .audioStoreFailed(let error):
            return error.localizedDescription
        case .requestedSegmentUnavailable(let index):
            return "Black carrier requested segment \(index) was not produced"
        }
    }

    /// Stable, exhaustive identity used when the progressive Hybrid provider
    /// publishes terminal evidence. This intentionally preserves the nested
    /// audio-muxer case instead of relying on Swift's synthesized NSError code.
    var failureCaseCode: String {
        switch self {
        case .videoStreamMissing: "videoStreamMissing"
        case .invalidRenditionOrdinal: "invalidRenditionOrdinal"
        case .invalidSegmentIndex: "invalidSegmentIndex"
        case .restartRequiresUserSeek: "restartRequiresUserSeek"
        case .seekIntentSegmentMismatch: "seekIntentSegmentMismatch"
        case .demuxSeekFailed: "demuxSeekFailed"
        case .restartTimelineOffsetUnavailable:
            "restartTimelineOffsetUnavailable"
        case .freshDemuxerFactoryMissing: "freshDemuxerFactoryMissing"
        case .analysisSourceFactoryMissing: "analysisSourceFactoryMissing"
        case .freshDemuxerOpenFailed: "freshDemuxerOpenFailed"
        case .restartSourceContractMismatch:
            "restartSourceContractMismatch"
        case .restartTrackContractMismatch:
            "restartTrackContractMismatch"
        case .generationSuperseded: "generationSuperseded"
        case .closed: "closed"
        case .demuxFailure(let evidence): evidence.caseCode
        case .demuxFailed: "demuxFailed"
        case .videoPacketSinkFailed: "videoPacketSinkFailed"
        case .videoDecoderFailed(let error):
            if error.isPixelBufferConversionCapabilityFailure {
                "videoDecoder.pixelBufferConversionFailed"
            } else if error.isLocalQueueInvariantFailure {
                "videoDecoder.localQueueInvariant"
            } else {
                "videoDecoder.failed"
            }
        case .audioMuxerFailed(_, let error):
            "audioMuxer.\(error.failureCaseCode)"
        case .audioStoreFailed(let error):
            switch error {
            case .muxer(let nested):
                "audioStore.muxer.\(nested.failureCaseCode)"
            case .segmentStoreFailed: "audioStore.segmentStoreFailed"
            case .incompleteStorage: "audioStore.incompleteStorage"
            case .unexpected: "audioStore.unexpected"
            }
        case .requestedSegmentUnavailable:
            "requestedSegmentUnavailable"
        }
    }

    var failureDomain: String {
        switch self {
        case .audioMuxerFailed,
             .audioStoreFailed(.muxer):
            "AetherEngine.BlackCarrierAudioRenditionMuxer"
        case .audioStoreFailed:
            "AetherEngine.BlackCarrierAudioRenditionStore"
        case .videoDecoderFailed:
            "AetherEngine.HybridVideoDecodeSink"
        case .demuxFailure(let evidence):
            evidence.domain
        default:
            "AetherEngine.BlackCarrierMediaFanoutPump"
        }
    }

    var failureCode: Int {
        switch self {
        case .videoStreamMissing: 1
        case .invalidRenditionOrdinal: 2
        case .invalidSegmentIndex: 3
        case .restartRequiresUserSeek: 4
        case .seekIntentSegmentMismatch: 5
        case .demuxSeekFailed: 6
        case .restartTimelineOffsetUnavailable: 7
        case .freshDemuxerFactoryMissing: 8
        case .analysisSourceFactoryMissing: 9
        case .freshDemuxerOpenFailed: 10
        case .restartSourceContractMismatch: 11
        case .restartTrackContractMismatch: 12
        case .generationSuperseded: 13
        case .closed: 14
        case .demuxFailure(let evidence): evidence.code
        case .demuxFailed: 15
        case .videoPacketSinkFailed: 16
        case .videoDecoderFailed(let error):
            if error.isPixelBufferConversionCapabilityFailure {
                1
            } else if error.isLocalQueueInvariantFailure {
                3
            } else {
                2
            }
        case .audioMuxerFailed(_, let error):
            error.failureCode
        case .audioStoreFailed(let error):
            switch error {
            case .muxer(let nested): nested.failureCode
            case .segmentStoreFailed: 1
            case .incompleteStorage: 2
            case .unexpected: 3
            }
        case .requestedSegmentUnavailable: 17
        }
    }

    var failureCategory: HybridPlaybackFailureCategory {
        if case .demuxFailure(let evidence) = self {
            return evidence.category
        }
        if case .videoDecoderFailed(let error) = self,
           error.isPixelBufferConversionCapabilityFailure {
            return .unsupportedCapability
        }
        if case .videoDecoderFailed(let error) = self,
           error.isLocalQueueInvariantFailure {
            return .invariant
        }
        switch self {
        case .audioMuxerFailed(
            _,
            .bridgeCapabilityUnavailable
        ),
             .audioStoreFailed(
                .muxer(.bridgeCapabilityUnavailable)
             ):
            return .unsupportedCapability
        default:
            break
        }
        return .routeRuntime
    }

    static func wrappingVideoSinkFailure(
        _ error: Error
    ) -> BlackCarrierMediaFanoutPumpError {
        if let decoder =
                error as? HybridVideoDecodeSinkError {
            if decoder == .closed {
                return .closed
            }
            return .videoDecoderFailed(error: decoder)
        }
        return .videoPacketSinkFailed(
            reason: String(describing: error)
        )
    }

    static func wrappingDemuxFailure(
        _ error: Error,
        sourceIsComplete: Bool = false
    ) -> BlackCarrierMediaFanoutPumpError {
        if let typed = BlackCarrierDemuxFailureEvidence.capture(
            error,
            sourceIsComplete: sourceIsComplete
        ) {
            return .demuxFailure(evidence: typed)
        }
        return .demuxFailed(reason: String(describing: error))
    }

    static func wrappingFreshDemuxerOpenFailure(
        _ error: Error,
        sourceIsComplete: Bool = false
    ) -> BlackCarrierMediaFanoutPumpError {
        if let typed = BlackCarrierDemuxFailureEvidence.capture(
            error,
            sourceIsComplete: sourceIsComplete
        ) {
            return .demuxFailure(evidence: typed)
        }
        return .freshDemuxerOpenFailed(
            reason: String(describing: error)
        )
    }
}

enum BlackCarrierMediaFanoutRestartResult: Sendable, Equatable {
    case applied(generation: UInt64, segmentIndex: Int)
    case stale(currentGeneration: UInt64)
}

struct BlackCarrierDemuxContract: Sendable, Equatable {
    let durationMicroseconds: Int64
    let formatStartTime: Int64
    let containerBitRate: Int64
    let progressiveSourceFacts: AetherProgressiveSourceFacts

    init(demuxer: Demuxer) {
        durationMicroseconds = Int64(
            (demuxer.duration * 1_000_000).rounded()
        )
        formatStartTime = demuxer.formatStartTime
        containerBitRate = demuxer.bitRate
        progressiveSourceFacts = AetherProgressiveSourceFacts(
            probe: AetherEngine.makeSourceProbe(
                demuxer: demuxer,
                displayURL: URL(
                    string: "aether-hybrid://source"
                )!
            )
        )
    }
}

private final class BlackCarrierIOQuiescenceDiagnosticFence:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var pending = true

    func finish() {
        lock.lock()
        pending = false
        lock.unlock()
    }

    var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }
}

struct BlackCarrierNativeSubtitleRenditionMetadata:
    Sendable,
    Equatable
{
    let ordinal: Int
    let sourceTrackID: Int
    let language: String?
    let name: String
    let isDefault: Bool
    let isAutoselect: Bool
    let isForced: Bool
}

/// Incremental single-demux packet fanout for carrier audio and the future real-video decoder.
///
/// `produce(throughSegment:)` advances only until every audio rendition has finalized the requested
/// segment. The same source demux loop may synchronously hand video packets to `videoPacketSink`, so
/// production does not require a second playback cursor. Calls are serialized; a future provider can
/// safely invoke them from concurrent HLS request threads.
final class BlackCarrierMediaFanoutPump: @unchecked Sendable {
    typealias FreshDemuxerFactory = @Sendable () throws -> Demuxer
    typealias DemuxerReleaseFence =
        @Sendable (Demuxer) -> Void

    typealias VideoPacketSink = (
        _ packet: UnsafeMutablePointer<AVPacket>
    ) throws -> Void

    private final class Rendition {
        let metadata: BlackCarrierAudioRenditionMetadata
        let cache: SegmentCache
        var writer: BlackCarrierAudioRenditionMuxer.Writer

        init(
            metadata: BlackCarrierAudioRenditionMetadata,
            cache: SegmentCache,
            writer: BlackCarrierAudioRenditionMuxer.Writer
        ) {
            self.metadata = metadata
            self.cache = cache
            self.writer = writer
        }
    }

    private final class NativeSubtitleRendition {
        let metadata: BlackCarrierNativeSubtitleRenditionMetadata
        let sourceTrackInfo: TrackInfo
        let store = NativeSubtitleCueStore()
        var decoder: EmbeddedSubtitleDecoder
        var timeBase: AVRational
        var isAvailable = true

        init(
            metadata: BlackCarrierNativeSubtitleRenditionMetadata,
            sourceTrackInfo: TrackInfo,
            decoder: EmbeddedSubtitleDecoder,
            timeBase: AVRational,
            shiftSeconds: Double
        ) {
            self.metadata = metadata
            self.sourceTrackInfo = sourceTrackInfo
            self.decoder = decoder
            self.timeBase = timeBase
            store.setShiftSeconds(shiftSeconds)
        }
    }

    let renditionMetadata: [BlackCarrierAudioRenditionMetadata]
    let renditionDescriptors: [BlackCarrierAudioRenditionDescriptor]
    let nativeSubtitleRenditionMetadata:
        [BlackCarrierNativeSubtitleRenditionMetadata]
    let sourceContract: BlackCarrierDemuxContract
    let progressiveSourceGeneration:
        SourceByteStoreGeneration?
    var progressiveSourceFacts: AetherProgressiveSourceFacts {
        sourceContract.progressiveSourceFacts
    }
    let hybridSubtitleContracts:
        [HybridSubtitleDecodeContract]
    let hybridSubtitlePacketStore = SubtitlePacketStore()
    let hybridSubtitleRuntimeAvailability =
        HybridSubtitleRuntimeAvailabilityStore()

    private var demuxer: Demuxer
    private let freshDemuxerFactory: FreshDemuxerFactory?
    private let demuxerReleaseFence: DemuxerReleaseFence
    private var sourceFactory: BlackCarrierDemuxSourceFactory?
    private let timeline: BlackCarrierTimeline
    private let bridgeMode: AudioBridgeMode
    private var videoStreamIndex: Int32
    private let videoPacketSink: VideoPacketSink?
    private let hybridVideoDecodeSink: HybridVideoDecodeSink?
    private let videoTimeBaseNumerator: Int32
    private let videoTimeBaseDenominator: Int32
    private let nominalVideoFrameDuration: CMTime
    private let videoSourceStartPTS: Int64
    private let renditions: [Rendition]
    private var renditionsByStream: [
        Int32: Rendition
    ]
    private var subtitleContractsByStream: [
        Int32: HybridSubtitleDecodeContract
    ]
    private var nativeSubtitleRenditionsByStream: [
        Int32: NativeSubtitleRendition
    ]
    private let overlaySourceTrackInfos: [TrackInfo]
    private let nativeSubtitleRenditions:
        [NativeSubtitleRendition]
    private let lock = NSLock()
    private let restartLock = NSLock()
    private let generationLock = NSLock()
    private let demuxerReferenceLock = NSLock()
    private let routePreparationProgressLock = NSLock()
    /// Independent from the demux/segment serialization lock so MainActor can
    /// observe an in-flight carrier request without waiting for weak-network
    /// I/O to finish.
    private let segmentProductionActivityLock = NSLock()

    private var summaries: [
        Int: BlackCarrierAudioRenditionSummary
    ] = [:]
    private var terminalError: BlackCarrierMediaFanoutPumpError?
    private var isFinished = false
    private var isClosed = false
    private var generationStartSegmentIndex: Int
    private var currentGeneration: UInt64
    private var requestedRestartGeneration: UInt64?
    private var interruptibleDemuxer: Demuxer
    private var ownsActiveDemuxer = false
    private var videoProductionEnd: CMTime = .invalid
    private var routePreparationProgressHandler:
        (@Sendable (
            AetherRoutePreparationProgressKind
        ) -> Void)?
    private var activeSegmentProductionRequests = 0

    init(
        demuxer: Demuxer,
        timeline: BlackCarrierTimeline,
        bridgeMode: AudioBridgeMode = .surroundCompat,
        videoStreamIndex: Int32? = nil,
        videoPacketSink: VideoPacketSink? = nil,
        hybridVideoDecodeSink: HybridVideoDecodeSink? = nil,
        initialGeneration: UInt64 = 0,
        freshDemuxerFactory: FreshDemuxerFactory? = nil,
        ownsInitialDemuxer: Bool = false,
        sourceFactory: BlackCarrierDemuxSourceFactory? = nil,
        demuxerReleaseFence:
            @escaping DemuxerReleaseFence = {
                demuxer in
                demuxer.close()
                demuxer.waitForIOQuiescence()
            }
    ) throws {
        guard let firstSegmentIndex = timeline.segments.first?.index else {
            throw BlackCarrierMediaFanoutPumpError
                .invalidSegmentIndex(index: 0)
        }
        guard videoPacketSink == nil || hybridVideoDecodeSink == nil else {
            throw BlackCarrierMediaFanoutPumpError.videoPacketSinkFailed(
                reason: "Multiple real-video packet sinks were supplied"
            )
        }
        let resolvedVideoPacketSink: VideoPacketSink? = videoPacketSink
            ?? hybridVideoDecodeSink.map { sink in
                { packet in try sink.consume(packet) }
            }
        let resolvedVideoStreamIndex = videoStreamIndex
            ?? demuxer.videoStreamIndex
        guard resolvedVideoPacketSink == nil || resolvedVideoStreamIndex >= 0 else {
            throw BlackCarrierMediaFanoutPumpError.videoStreamMissing
        }
        if let hybridVideoDecodeSink {
            guard let stream = demuxer.stream(
                at: resolvedVideoStreamIndex
            ) else {
                throw BlackCarrierMediaFanoutPumpError.videoStreamMissing
            }
            do {
                guard try hybridVideoDecodeSink.validate(
                    demuxer: demuxer,
                    stream: stream
                ) else {
                    throw HybridVideoDecodeSinkError.streamContractMismatch
                }
            } catch {
                throw BlackCarrierMediaFanoutPumpError
                    .wrappingVideoSinkFailure(error)
            }
        }
        let videoStream = resolvedVideoPacketSink == nil
            ? nil
            : demuxer.stream(at: resolvedVideoStreamIndex)
        if resolvedVideoPacketSink != nil, videoStream == nil {
            throw BlackCarrierMediaFanoutPumpError.videoStreamMissing
        }
        let allSubtitleTrackInfos = demuxer
            .subtitleTrackInfos()
        let overlaySourceTrackInfos = allSubtitleTrackInfos
            .filter(Self.isHybridOverlaySubtitleTrack)
        let nativeSubtitleSourceTrackInfos = allSubtitleTrackInfos
            .filter(Self.isFaithfullyConvertibleNativeSubtitleTrack)
        let splitDisplaySetStreams = demuxer
            .splitDisplaySetSubtitleStreamIndices()
        let sourceVideoWidth = max(
            1,
            videoStream?.pointee.codecpar?.pointee.width
                ?? 1_920
        )
        let sourceVideoHeight = max(
            1,
            videoStream?.pointee.codecpar?.pointee.height
                ?? 1_080
        )
        let subtitleContracts: [HybridSubtitleDecodeContract] =
            overlaySourceTrackInfos.compactMap {
            info in
            let streamIndex = Int32(info.id)
            guard let stream = demuxer.stream(at: streamIndex) else {
                return nil
            }
            return HybridSubtitleDecodeContract(
                trackID: info.id,
                packetStreamID: streamIndex,
                info: info,
                stream: stream,
                sourceVideoWidth: sourceVideoWidth,
                sourceVideoHeight: sourceVideoHeight,
                assembleSplitDisplaySets:
                    splitDisplaySetStreams.contains(streamIndex)
            )
        }
        guard subtitleContracts.count
                == overlaySourceTrackInfos.count else {
            throw BlackCarrierMediaFanoutPumpError.demuxFailed(
                reason: "Hybrid subtitle contract could not be copied"
            )
        }
        let nativeSubtitleMetadata =
            Self.nativeSubtitleMetadata(
                for: nativeSubtitleSourceTrackInfos
            )
        var preparedNativeSubtitles:
            [NativeSubtitleRendition] = []
        for (info, renditionMetadata) in zip(
            nativeSubtitleSourceTrackInfos,
            nativeSubtitleMetadata
        ) {
            let streamIndex = Int32(info.id)
            guard let stream = demuxer.stream(at: streamIndex),
                  let decoder = EmbeddedSubtitleDecoder(
                    stream: stream,
                    sourceVideoWidth: Int32(sourceVideoWidth),
                    sourceVideoHeight: Int32(sourceVideoHeight),
                    preserveASSMarkup: false
                  ) else {
                EngineLog.emit(
                    "[BlackCarrierMediaFanoutPump] native subtitle track unavailable during admission trackID=\(info.id)",
                    category: .session
                )
                continue
            }
            let timeBase = stream.pointee.time_base
            let sourceStartPTS =
                BlackCarrierSourceAxis.sourceStartPTS(
                    demuxer: demuxer,
                    streamIndex: streamIndex
                )
            let shiftSeconds = Double(sourceStartPTS)
                * Double(timeBase.num)
                / Double(timeBase.den)
            preparedNativeSubtitles.append(
                NativeSubtitleRendition(
                    metadata:
                        BlackCarrierNativeSubtitleRenditionMetadata(
                            ordinal: preparedNativeSubtitles.count,
                            sourceTrackID:
                                renditionMetadata.sourceTrackID,
                            language: renditionMetadata.language,
                            name: renditionMetadata.name,
                            isDefault: renditionMetadata.isDefault,
                            isAutoselect:
                                renditionMetadata.isAutoselect,
                            isForced: renditionMetadata.isForced
                        ),
                    sourceTrackInfo: info,
                    decoder: decoder,
                    timeBase: timeBase,
                    shiftSeconds: shiftSeconds
                )
            )
        }
        let tracks = demuxer.audioTrackInfos()
        let metadata = BlackCarrierCompositeProvider.renditionMetadata(
            for: tracks
        )
        var prepared: [Rendition] = []
        do {
            for (track, renditionMetadata) in zip(tracks, metadata) {
                let cache = SegmentCache(
                    forwardWindow: max(1, timeline.segments.count),
                    backwardWindow: max(1, timeline.segments.count)
                )
                do {
                    let streamIndex = Int32(track.id)
                    let writer = try Self.makeWriter(
                        demuxer: demuxer,
                        streamIndex: streamIndex,
                        metadata: renditionMetadata,
                        cache: cache,
                        timeline: timeline,
                        bridgeMode: bridgeMode,
                        startingSegmentIndex: firstSegmentIndex,
                        preserveEncoderPriming: true
                    )
                    prepared.append(Rendition(
                        metadata: renditionMetadata,
                        cache: cache,
                        writer: writer
                    ))
                } catch {
                    cache.close()
                    throw error
                }
            }
        } catch let error as BlackCarrierAudioRenditionMuxerError {
            prepared.forEach { $0.cache.close() }
            let trackID = prepared.count < tracks.count
                ? tracks[prepared.count].id
                : -1
            throw BlackCarrierMediaFanoutPumpError.audioMuxerFailed(
                trackID: trackID,
                error: error
            )
        } catch let error as BlackCarrierAudioRenditionStoreError {
            prepared.forEach { $0.cache.close() }
            throw BlackCarrierMediaFanoutPumpError.audioStoreFailed(
                error: error
            )
        } catch {
            prepared.forEach { $0.cache.close() }
            throw BlackCarrierMediaFanoutPumpError
                .wrappingDemuxFailure(error)
        }

        self.demuxer = demuxer
        self.freshDemuxerFactory = freshDemuxerFactory
        self.demuxerReleaseFence = demuxerReleaseFence
        self.sourceFactory = sourceFactory
        self.timeline = timeline
        self.bridgeMode = bridgeMode
        self.videoStreamIndex = resolvedVideoPacketSink == nil
            ? -1
            : resolvedVideoStreamIndex
        self.videoPacketSink = resolvedVideoPacketSink
        self.hybridVideoDecodeSink = hybridVideoDecodeSink
        videoTimeBaseNumerator = videoStream?.pointee.time_base.num ?? 0
        videoTimeBaseDenominator = videoStream?.pointee.time_base.den ?? 0
        nominalVideoFrameDuration = videoStream.map {
            Self.nominalFrameDuration(stream: $0)
        } ?? .invalid
        videoSourceStartPTS = resolvedVideoPacketSink == nil
            ? 0
            : BlackCarrierSourceAxis.sourceStartPTS(
                demuxer: demuxer,
                streamIndex: resolvedVideoStreamIndex
            )
        sourceContract = BlackCarrierDemuxContract(demuxer: demuxer)
        progressiveSourceGeneration =
            sourceFactory?.progressiveSourceGeneration
        renditionMetadata = metadata
        renditions = prepared
        renditionDescriptors = prepared.map(\.writer.descriptor)
        nativeSubtitleRenditions = preparedNativeSubtitles
        nativeSubtitleRenditionMetadata =
            preparedNativeSubtitles.map(\.metadata)
        hybridSubtitleContracts = subtitleContracts
        self.overlaySourceTrackInfos = overlaySourceTrackInfos
        generationStartSegmentIndex = firstSegmentIndex
        currentGeneration = initialGeneration
        interruptibleDemuxer = demuxer
        ownsActiveDemuxer = ownsInitialDemuxer
        renditionsByStream = Dictionary(
            uniqueKeysWithValues: prepared.map {
                ($0.writer.sourceStreamIndex, $0)
            }
        )
        subtitleContractsByStream = Dictionary(
            uniqueKeysWithValues: subtitleContracts.map {
                ($0.packetStreamID, $0)
            }
        )
        nativeSubtitleRenditionsByStream = Dictionary(
            uniqueKeysWithValues: preparedNativeSubtitles.map {
                (Int32($0.metadata.sourceTrackID), $0)
            }
        )

        var keep = Set(renditionsByStream.keys)
        if self.videoStreamIndex >= 0 {
            keep.insert(self.videoStreamIndex)
        }
        keep.formUnion(subtitleContractsByStream.keys)
        keep.formUnion(nativeSubtitleRenditionsByStream.keys)
        demuxer.discardAllStreamsExcept(keep)
    }

    static func makeSeekableVOD(
        source: MediaSource,
        options: LoadOptions,
        timeline: BlackCarrierTimeline,
        bridgeMode: AudioBridgeMode = .surroundCompat,
        videoPacketSink: VideoPacketSink? = nil,
        decodedFrameHandler: HybridVideoDecodeSink.FrameHandler? = nil,
        videoFailureHandler: HybridVideoDecodeSink.FailureHandler? = nil,
        decoderPreference: HybridVideoDecoderPreference = .automatic,
        videoBacklogConfiguration:
            HybridCompressedVideoBacklogConfiguration = .production,
        videoBacklogScratchRoot: URL? = nil,
        initialGeneration: UInt64 = 0,
        selectTitleID: Int? = nil
    ) throws -> BlackCarrierMediaFanoutPump {
        let sourceFactory = try BlackCarrierDemuxSourceFactory.adopting(
            source: source,
            options: options,
            selectTitleID: selectTitleID
        )
        return try makeSeekableVOD(
            sourceFactory: sourceFactory,
            ownsSourceFactory: true,
            timeline: timeline,
            bridgeMode: bridgeMode,
            videoPacketSink: videoPacketSink,
            decodedFrameHandler: decodedFrameHandler,
            videoFailureHandler: videoFailureHandler,
            decoderPreference: decoderPreference,
            videoBacklogConfiguration:
                videoBacklogConfiguration,
            videoBacklogScratchRoot:
                videoBacklogScratchRoot,
            initialGeneration: initialGeneration
        )
    }

    static func makeSeekableVOD(
        sourceFactory: BlackCarrierDemuxSourceFactory,
        ownsSourceFactory: Bool,
        timeline: BlackCarrierTimeline,
        bridgeMode: AudioBridgeMode = .surroundCompat,
        videoPacketSink: VideoPacketSink? = nil,
        decodedFrameHandler: HybridVideoDecodeSink.FrameHandler? = nil,
        videoFailureHandler: HybridVideoDecodeSink.FailureHandler? = nil,
        decoderPreference: HybridVideoDecoderPreference = .automatic,
        videoBacklogConfiguration:
            HybridCompressedVideoBacklogConfiguration = .production,
        videoBacklogScratchRoot: URL? = nil,
        initialGeneration: UInt64 = 0
    ) throws -> BlackCarrierMediaFanoutPump {
        do {
            let demuxer = try sourceFactory.openDemuxer()
            let decodeSink = try decodedFrameHandler.map { handler in
                try HybridVideoDecodeSink(
                    demuxer: demuxer,
                    initialGeneration: initialGeneration,
                    maximumQueuedBytes:
                        videoBacklogConfiguration
                            .residentByteLimit,
                    maximumQueuedPackets:
                        videoBacklogConfiguration.packetLimit,
                    maximumSpoolContentBytes:
                        videoBacklogConfiguration
                            .spoolContentByteLimit,
                    backlogScratchRoot:
                        videoBacklogScratchRoot,
                    decoderPreference: decoderPreference,
                    onFrame: handler,
                    onFailure: videoFailureHandler
                )
            }
            do {
                return try BlackCarrierMediaFanoutPump(
                    demuxer: demuxer,
                    timeline: timeline,
                    bridgeMode: bridgeMode,
                    videoStreamIndex: demuxer.videoStreamIndex,
                    videoPacketSink: videoPacketSink,
                    hybridVideoDecodeSink: decodeSink,
                    initialGeneration: initialGeneration,
                    freshDemuxerFactory: {
                        try sourceFactory.openDemuxer()
                    },
                    ownsInitialDemuxer: true,
                    sourceFactory: ownsSourceFactory ? sourceFactory : nil
                )
            } catch {
                decodeSink?.close()
                demuxer.close()
                demuxer.waitForIOQuiescence()
                throw error
            }
        } catch {
            if ownsSourceFactory {
                sourceFactory.close()
            }
            throw error
        }
    }

    deinit {
        close()
    }

    var finished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isFinished
    }

    var generation: UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        return currentGeneration
    }

    var supportsFreshDemuxRestart: Bool {
        freshDemuxerFactory != nil
    }

    var hybridVideoFormat: VideoFormat? {
        hybridVideoDecodeSink?.streamContract.videoFormat
    }

    var hybridDolbyVisionConfiguration:
        AetherDolbyVisionConfiguration?
    {
        hybridVideoDecodeSink?
            .streamContract.dolbyVisionConfiguration
    }

    var hybridVideoFrameRate: Double? {
        hybridVideoDecodeSink?
            .streamContract.displayFrameRate
    }

    var realVideoBitrateTelemetry:
        AetherHybridRealVideoBitrateTelemetry
    {
        hybridVideoDecodeSink?
            .realVideoBitrateTelemetry
            ?? .unavailable()
    }

    var compressedVideoBacklogSnapshot:
        HybridCompressedVideoBacklogSnapshot?
    {
        hybridVideoDecodeSink?.compressedBacklogSnapshot
    }

    func setRoutePreparationProgressHandler(
        _ handler:
            (@Sendable (
                AetherRoutePreparationProgressKind
            ) -> Void)?
    ) {
        routePreparationProgressLock.lock()
        routePreparationProgressHandler = handler
        routePreparationProgressLock.unlock()
    }

    private func reportRoutePreparationProgress(
        _ kind: AetherRoutePreparationProgressKind
    ) {
        routePreparationProgressLock.lock()
        let handler = routePreparationProgressHandler
        routePreparationProgressLock.unlock()
        handler?(kind)
    }

    func restart(
        for intent: HybridSeekIntent
    ) throws -> BlackCarrierMediaFanoutRestartResult {
        guard case .userSeek(
            let target,
            let requestedSegmentIndex,
            let requestedGeneration
        ) = intent else {
            throw BlackCarrierMediaFanoutPumpError.restartRequiresUserSeek
        }

        restartLock.lock()
        defer { restartLock.unlock() }

        generationLock.lock()
        guard requestedGeneration > currentGeneration else {
            let result = BlackCarrierMediaFanoutRestartResult.stale(
                currentGeneration: currentGeneration
            )
            generationLock.unlock()
            return result
        }
        requestedRestartGeneration = requestedGeneration
        generationLock.unlock()

        demuxerReferenceLock.lock()
        let retiringDemuxer = interruptibleDemuxer
        demuxerReferenceLock.unlock()
        retiringDemuxer.markClosed()

        let restartFactory: FreshDemuxerFactory
        let restartSourceFactory:
            BlackCarrierDemuxSourceFactory?
        let expectedSegmentIndex: Int
        lock.lock()
        guard !isClosed else {
            clearRequestedRestart()
            lock.unlock()
            throw BlackCarrierMediaFanoutPumpError.closed
        }
        if let terminalError {
            clearRequestedRestart()
            lock.unlock()
            throw terminalError
        }
        guard let freshDemuxerFactory else {
            let error = BlackCarrierMediaFanoutPumpError
                .freshDemuxerFactoryMissing
            failWhileLocked(error)
            lock.unlock()
            throw error
        }
        guard let resolvedSegmentIndex = timeline.segmentIndex(
            containing: target
        ) else {
            let error = BlackCarrierMediaFanoutPumpError
                .invalidSegmentIndex(index: requestedSegmentIndex)
            failWhileLocked(error)
            lock.unlock()
            throw error
        }
        guard requestedSegmentIndex == resolvedSegmentIndex else {
            let error = BlackCarrierMediaFanoutPumpError
                .seekIntentSegmentMismatch(
                    expected: resolvedSegmentIndex,
                    actual: requestedSegmentIndex
                )
            failWhileLocked(error)
            lock.unlock()
            throw error
        }
        restartFactory = freshDemuxerFactory
        restartSourceFactory = sourceFactory
        expectedSegmentIndex = resolvedSegmentIndex
        lock.unlock()

        // Closing the AVIO context is not the release fence. The retiring
        // reader must deliver every terminal URLSession callback before a new
        // same-source reader is opened.
        let quiescenceFence =
            BlackCarrierIOQuiescenceDiagnosticFence()
        let quiescenceWatchdog = Task.detached {
            do {
                try await Task.sleep(
                    nanoseconds: 2_000_000_000
                )
            } catch {
                return
            }
            guard quiescenceFence.isPending else { return }
            EngineLog.emit(
                "[BlackCarrierMediaFanoutPump] cancellationUnresponsive "
                    + "readerOverlap=forbidden",
                category: .session
            )
        }
        demuxerReleaseFence(retiringDemuxer)
        quiescenceFence.finish()
        quiescenceWatchdog.cancel()

        lock.lock()
        let restartWasClosed = isClosed
        lock.unlock()
        guard !restartWasClosed else {
            clearRequestedRestart()
            throw BlackCarrierMediaFanoutPumpError.closed
        }

        do {
            try restartSourceFactory?
                .requireProgressiveRestartGeneration(
                    progressiveSourceGeneration
                )
        } catch {
            let typed = BlackCarrierMediaFanoutPumpError
                .wrappingDemuxFailure(
                    error,
                    sourceIsComplete:
                        restartSourceFactory?
                            .progressiveSourceIsComplete
                            ?? false
                )
            lock.lock()
            if isClosed {
                lock.unlock()
                throw BlackCarrierMediaFanoutPumpError.closed
            }
            failWhileLocked(typed)
            lock.unlock()
            throw typed
        }

        // Fresh source open may contain a non-cooperative synchronous read.
        // It must not hold the production lock: timeout teardown first marks
        // the retiring demuxer closed, then acquires this lock to publish
        // `isClosed` and clear the generation token. A late factory result is
        // revalidated below and can only be closed, never installed.
        let freshDemuxer: Demuxer
        do {
            freshDemuxer = try restartFactory()
        } catch {
            let typed = BlackCarrierMediaFanoutPumpError
                .wrappingFreshDemuxerOpenFailure(
                    error,
                    sourceIsComplete:
                        restartSourceFactory?
                            .progressiveSourceIsComplete
                            ?? false
                )
            lock.lock()
            if isClosed {
                lock.unlock()
                throw BlackCarrierMediaFanoutPumpError.closed
            }
            failWhileLocked(typed)
            lock.unlock()
            throw typed
        }

        lock.lock()
        var freshDemuxerToClose: Demuxer? = freshDemuxer
        var retiredDemuxerToClose: Demuxer?
        defer {
            lock.unlock()
            if let freshDemuxerToClose {
                demuxerReleaseFence(
                    freshDemuxerToClose
                )
            }
            retiredDemuxerToClose?.close()
        }
        guard !isClosed else {
            throw BlackCarrierMediaFanoutPumpError.closed
        }
        if let terminalError {
            throw terminalError
        }
        generationLock.lock()
        let restartIsCurrent = requestedRestartGeneration
            == requestedGeneration
            && requestedGeneration > currentGeneration
        generationLock.unlock()
        guard restartIsCurrent else {
            throw BlackCarrierMediaFanoutPumpError
                .generationSuperseded(generation: requestedGeneration)
        }

        do {
            try restartSourceFactory?
                .requireProgressiveRestartGeneration(
                    progressiveSourceGeneration
                )
            let timelineOffsets = try renditions.map { rendition in
                guard let offset =
                        rendition.writer.presentationTimelineOffset else {
                    throw BlackCarrierMediaFanoutPumpError
                        .restartTimelineOffsetUnavailable(
                            trackID: rendition.metadata.sourceTrackID
                        )
                }
                return offset
            }
            guard freshDemuxer !== retiringDemuxer else {
                throw BlackCarrierMediaFanoutPumpError
                    .restartTrackContractMismatch
            }
            guard BlackCarrierDemuxContract(demuxer: freshDemuxer)
                    == sourceContract else {
                throw BlackCarrierMediaFanoutPumpError
                    .restartSourceContractMismatch
            }

            let freshTracks = freshDemuxer.audioTrackInfos()
            let freshMetadata =
                BlackCarrierCompositeProvider.renditionMetadata(
                    for: freshTracks
                )
            guard freshMetadata == renditionMetadata else {
                throw BlackCarrierMediaFanoutPumpError
                    .restartTrackContractMismatch
            }
            let freshSubtitleTracks = freshDemuxer
                .subtitleTrackInfos()
                .filter(Self.isHybridOverlaySubtitleTrack)
            let freshSubtitleTracksByID = Dictionary(
                uniqueKeysWithValues: freshSubtitleTracks.map {
                    ($0.id, $0)
                }
            )
            var freshSubtitleContractsByStream:
                [Int32: HybridSubtitleDecodeContract] = [:]
            for (sourceTrack, contract) in zip(
                overlaySourceTrackInfos,
                hybridSubtitleContracts
            ) {
                guard freshSubtitleTracksByID[sourceTrack.id]
                        == sourceTrack else {
                    hybridSubtitleRuntimeAvailability
                        .markUnavailable(
                            trackID: contract.track.id,
                            reason: .decodeFailed
                        )
                    continue
                }
                freshSubtitleContractsByStream[
                    Int32(sourceTrack.id)
                ] = contract
            }
            let freshNativeSubtitleTracksByID = Dictionary(
                uniqueKeysWithValues: freshDemuxer
                    .subtitleTrackInfos()
                    .filter(Self.isFaithfullyConvertibleNativeSubtitleTrack)
                    .map { ($0.id, $0) }
            )
            var freshNativeSubtitleRenditionsByStream:
                [Int32: NativeSubtitleRendition] = [:]
            for rendition in nativeSubtitleRenditions
            where rendition.isAvailable {
                let trackID = rendition.metadata.sourceTrackID
                guard freshNativeSubtitleTracksByID[trackID]
                        == rendition.sourceTrackInfo,
                      let freshStream = freshDemuxer.stream(
                        at: Int32(trackID)
                      ),
                      let decoder = EmbeddedSubtitleDecoder(
                        stream: freshStream,
                        sourceVideoWidth: Int32(max(
                            1,
                            freshDemuxer.stream(
                                at: freshDemuxer.videoStreamIndex
                            )?.pointee.codecpar?.pointee.width ?? 1_920
                        )),
                        sourceVideoHeight: Int32(max(
                            1,
                            freshDemuxer.stream(
                                at: freshDemuxer.videoStreamIndex
                            )?.pointee.codecpar?.pointee.height ?? 1_080
                        )),
                        preserveASSMarkup: false
                      ) else {
                    rendition.isAvailable = false
                    EngineLog.emit(
                        "[BlackCarrierMediaFanoutPump] native subtitle track unavailable after generation change trackID=\(trackID)",
                        category: .session
                    )
                    continue
                }
                rendition.decoder = decoder
                rendition.timeBase = freshStream.pointee.time_base
                freshNativeSubtitleRenditionsByStream[
                    Int32(trackID)
                ] = rendition
            }
            let freshVideoStreamIndex: Int32
            if videoPacketSink == nil {
                freshVideoStreamIndex = -1
            } else {
                freshVideoStreamIndex = freshDemuxer.videoStreamIndex
                guard freshVideoStreamIndex >= 0 else {
                    throw BlackCarrierMediaFanoutPumpError.videoStreamMissing
                }
            }

            let segment = timeline.segments[expectedSegmentIndex]
            let videoDecodeRestartAnchor =
                Self.videoDecodeRestartAnchor(
                    demuxer: freshDemuxer,
                    streamIndex: freshVideoStreamIndex,
                    targetTime: segment.startTime
                )
            guard freshDemuxer.seek(
                to: CMTimeGetSeconds(segment.startTime)
            ) else {
                throw BlackCarrierMediaFanoutPumpError
                    .demuxSeekFailed(segmentIndex: expectedSegmentIndex)
            }
            let replacementWriters = try zip(
                zip(renditions, freshTracks),
                timelineOffsets
            ).map { pair, timelineOffset in
                let rendition = pair.0
                let freshTrack = pair.1
                return try Self.makeWriter(
                    demuxer: freshDemuxer,
                    streamIndex: Int32(freshTrack.id),
                    metadata: rendition.metadata,
                    cache: rendition.cache,
                    timeline: timeline,
                    bridgeMode: bridgeMode,
                    startingSegmentIndex: expectedSegmentIndex,
                    preserveEncoderPriming: false,
                    presentationTimelineOffset: timelineOffset,
                    decodeTimestampOffset: timelineOffset,
                    restartTimestampRebaseEnabled: true
                )
            }
            let freshDescriptors = replacementWriters.map(\.descriptor)
            guard freshDescriptors == renditionDescriptors else {
                throw BlackCarrierMediaFanoutPumpError
                    .restartTrackContractMismatch
            }
            if let hybridVideoDecodeSink {
                guard let freshVideoStream = freshDemuxer.stream(
                    at: freshVideoStreamIndex
                ) else {
                    throw BlackCarrierMediaFanoutPumpError.videoStreamMissing
                }
                do {
                    try hybridVideoDecodeSink.beginGeneration(
                        requestedGeneration,
                        targetTime: target,
                        restartDecodeAnchorTime:
                            videoDecodeRestartAnchor,
                        demuxer: freshDemuxer,
                        stream: freshVideoStream
                    )
                } catch {
                    throw BlackCarrierMediaFanoutPumpError
                        .wrappingVideoSinkFailure(error)
                }
            }
            for (rendition, replacement) in zip(
                renditions,
                replacementWriters
            ) {
                rendition.writer = replacement
            }
            var keep = Set(replacementWriters.map(\.sourceStreamIndex))
            if freshVideoStreamIndex >= 0 {
                keep.insert(freshVideoStreamIndex)
            }
            keep.formUnion(
                freshSubtitleContractsByStream.keys
            )
            keep.formUnion(
                freshNativeSubtitleRenditionsByStream.keys
            )
            freshDemuxer.discardAllStreamsExcept(keep)
            renditionsByStream = Dictionary(
                uniqueKeysWithValues: renditions.map {
                    ($0.writer.sourceStreamIndex, $0)
                }
            )
            subtitleContractsByStream =
                freshSubtitleContractsByStream
            nativeSubtitleRenditionsByStream =
                freshNativeSubtitleRenditionsByStream
            videoStreamIndex = freshVideoStreamIndex
            summaries.removeAll(keepingCapacity: true)
            isFinished = false
            videoProductionEnd = .invalid
            generationStartSegmentIndex = expectedSegmentIndex
            retiredDemuxerToClose = demuxer
            demuxer = freshDemuxer
            ownsActiveDemuxer = true
            demuxerReferenceLock.lock()
            interruptibleDemuxer = freshDemuxer
            demuxerReferenceLock.unlock()
            freshDemuxerToClose = nil
            generationLock.lock()
            currentGeneration = requestedGeneration
            requestedRestartGeneration = nil
            generationLock.unlock()
            return .applied(
                generation: requestedGeneration,
                segmentIndex: expectedSegmentIndex
            )
        } catch let error as BlackCarrierMediaFanoutPumpError {
            failWhileLocked(error)
            throw error
        } catch let error as BlackCarrierAudioRenditionMuxerError {
            let trackID = renditions.first?.metadata.sourceTrackID ?? -1
            let typed = BlackCarrierMediaFanoutPumpError.audioMuxerFailed(
                trackID: trackID,
                error: error
            )
            failWhileLocked(typed)
            throw typed
        } catch let error as BlackCarrierAudioRenditionStoreError {
            let typed = BlackCarrierMediaFanoutPumpError.audioStoreFailed(
                error: error
            )
            failWhileLocked(typed)
            throw typed
        } catch {
            let typed = BlackCarrierMediaFanoutPumpError
                .wrappingDemuxFailure(
                    error,
                    sourceIsComplete:
                        sourceFactory?
                            .progressiveSourceIsComplete
                            ?? false
                )
            failWhileLocked(typed)
            throw typed
        }
    }

    func produce(throughSegment index: Int) throws {
        beginSegmentProductionRequest()
        defer { endSegmentProductionRequest() }

        lock.lock()
        defer { lock.unlock() }
        let operationGeneration = generationSnapshot()

        guard !isClosed else {
            throw BlackCarrierMediaFanoutPumpError.closed
        }
        if let terminalError {
            throw terminalError
        }
        if let videoError = hybridVideoDecodeSink?.failure {
            let typed = BlackCarrierMediaFanoutPumpError
                .videoDecoderFailed(error: videoError)
            fail(typed)
            throw typed
        }
        guard timeline.segments.indices.contains(index) else {
            throw BlackCarrierMediaFanoutPumpError.invalidSegmentIndex(
                index: index
            )
        }
        if index < generationStartSegmentIndex {
            guard cachedSegmentExists(index) else {
                throw BlackCarrierMediaFanoutPumpError
                    .requestedSegmentUnavailable(index: index)
            }
            return
        }
        if hasSegment(index) {
            return
        }

        do {
            while !hasSegment(index), !isFinished {
                try throwIfVideoDecoderFailed()
                guard let packet = try demuxer.readPacket() else {
                    if isGenerationSuperseded(operationGeneration) {
                        throw BlackCarrierMediaFanoutPumpError
                            .generationSuperseded(
                                generation: operationGeneration
                            )
                    }
                    try finishWriters()
                    break
                }
                reportRoutePreparationProgress(.demuxPacket)
                var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
                defer { trackedPacketFree(&packetToFree) }

                if let rendition = renditionsByStream[
                    packet.pointee.stream_index
                ] {
                    do {
                        try rendition.writer.consume(packet)
                    } catch let error as BlackCarrierAudioRenditionMuxerError {
                        throw BlackCarrierMediaFanoutPumpError.audioMuxerFailed(
                            trackID: rendition.metadata.sourceTrackID,
                            error: error
                        )
                    } catch let error as BlackCarrierAudioRenditionStoreError {
                        throw BlackCarrierMediaFanoutPumpError.audioStoreFailed(
                            error: error
                        )
                    }
                } else if packet.pointee.stream_index == videoStreamIndex,
                          let videoPacketSink {
                    do {
                        try videoPacketSink(packet)
                        updateVideoProductionEnd(packet)
                    } catch {
                        throw BlackCarrierMediaFanoutPumpError
                            .wrappingVideoSinkFailure(error)
                    }
                } else if let contract =
                            subtitleContractsByStream[
                                packet.pointee.stream_index
                            ],
                          let stream = demuxer.stream(
                            at: packet.pointee.stream_index
                          ) {
                    hybridSubtitlePacketStore.harvest(
                        streamIndex: contract.packetStreamID,
                        packet: packet,
                        timeBase: stream.pointee.time_base,
                        assembleSplitDisplaySets:
                            contract.assembleSplitDisplaySets
                    )
                } else if let rendition =
                            nativeSubtitleRenditionsByStream[
                                packet.pointee.stream_index
                            ],
                          rendition.isAvailable {
                    let event = rendition.decoder.decode(
                        packet: packet,
                        streamTimeBase: rendition.timeBase
                    )
                    if let event {
                        rendition.store.appendCues(event.cues)
                    }
                    if let errorCode =
                            rendition.decoder.lastDecodeErrorCode {
                        rendition.isAvailable = false
                        nativeSubtitleRenditionsByStream.removeValue(
                            forKey: packet.pointee.stream_index
                        )
                        EngineLog.emit(
                            "[BlackCarrierMediaFanoutPump] native subtitle track disabled after decode failure trackID=\(rendition.metadata.sourceTrackID) code=\(errorCode)",
                            category: .session
                        )
                    }
                }
            }
            try throwIfVideoDecoderFailed()
            guard hasSegment(index) else {
                throw BlackCarrierMediaFanoutPumpError
                    .requestedSegmentUnavailable(index: index)
            }
        } catch let error as BlackCarrierMediaFanoutPumpError {
            if isGenerationSuperseded(operationGeneration) {
                throw BlackCarrierMediaFanoutPumpError
                    .generationSuperseded(
                        generation: operationGeneration
                    )
            }
            fail(error)
            throw error
        } catch {
            if isGenerationSuperseded(operationGeneration) {
                throw BlackCarrierMediaFanoutPumpError
                    .generationSuperseded(
                        generation: operationGeneration
                    )
            }
            let typed = BlackCarrierMediaFanoutPumpError
                .wrappingDemuxFailure(
                    error,
                    sourceIsComplete:
                        sourceFactory?
                            .progressiveSourceIsComplete
                            ?? false
                )
            fail(typed)
            throw typed
        }
    }

    var isCarrierSegmentProductionActive: Bool {
        segmentProductionActivityLock.lock()
        defer { segmentProductionActivityLock.unlock() }
        return activeSegmentProductionRequests > 0
    }

    private func beginSegmentProductionRequest() {
        segmentProductionActivityLock.lock()
        activeSegmentProductionRequests += 1
        segmentProductionActivityLock.unlock()
    }

    private func endSegmentProductionRequest() {
        segmentProductionActivityLock.lock()
        activeSegmentProductionRequests -= 1
        assert(activeSegmentProductionRequests >= 0)
        segmentProductionActivityLock.unlock()
    }

    func initSegment(ordinal: Int) throws -> Data? {
        guard renditionMetadata.indices.contains(ordinal) else {
            throw BlackCarrierMediaFanoutPumpError.invalidRenditionOrdinal(
                ordinal: ordinal
            )
        }
        if let cached = peekInitSegment(ordinal: ordinal) {
            return cached
        }
        try produce(throughSegment: 0)
        lock.lock()
        defer { lock.unlock() }
        return rendition(at: ordinal)?.cache.fetchInit(timeout: 0)
    }

    func mediaSegmentURL(
        ordinal: Int,
        index: Int
    ) throws -> URL? {
        guard renditionMetadata.indices.contains(ordinal) else {
            throw BlackCarrierMediaFanoutPumpError.invalidRenditionOrdinal(
                ordinal: ordinal
            )
        }
        try produce(throughSegment: index)
        lock.lock()
        defer { lock.unlock() }
        return rendition(at: ordinal)?.cache.peekURL(index: index)
    }

    func mediaSegment(
        ordinal: Int,
        index: Int
    ) throws -> Data? {
        guard renditionMetadata.indices.contains(ordinal) else {
            throw BlackCarrierMediaFanoutPumpError.invalidRenditionOrdinal(
                ordinal: ordinal
            )
        }
        try produce(throughSegment: index)
        lock.lock()
        defer { lock.unlock() }
        return rendition(at: ordinal)?.cache.peek(index: index)
    }

    func nativeSubtitleVTT(
        ordinal: Int,
        segmentIndex: Int
    ) throws -> String? {
        guard nativeSubtitleRenditions.indices.contains(ordinal),
              timeline.segments.indices.contains(segmentIndex) else {
            return nil
        }
        let subtitle = nativeSubtitleRenditions[ordinal]
        try produce(throughSegment: segmentIndex)
        lock.lock()
        defer { lock.unlock() }
        guard subtitle.isAvailable else { return nil }
        let segment = timeline.segments[segmentIndex]
        let start = CMTimeGetSeconds(segment.startTime)
        let end = CMTimeGetSeconds(
            CMTimeAdd(segment.startTime, segment.duration)
        )
        return WebVTTBuilder.segment(
            cues: subtitle.store.cuesInWindow(
                start: start,
                end: end
            ),
            segmentStart: start
        )
    }

    func summary(
        ordinal: Int
    ) -> BlackCarrierAudioRenditionSummary? {
        lock.lock()
        defer { lock.unlock() }
        return summaries[ordinal]
    }

    func observedAudioBandwidthSegmentSamples()
        -> [[BlackCarrierBandwidthSegmentSample]]
    {
        lock.lock()
        defer { lock.unlock() }
        return renditions.map {
            $0.writer.observedBandwidthSegmentSamples
        }
    }

    func carrierBandwidthTelemetry(
        videoSamples:
            [BlackCarrierBandwidthSegmentSample]
    ) -> AetherHybridCarrierBandwidthTelemetry {
        lock.lock()
        defer { lock.unlock() }
        return BlackCarrierBandwidthTelemetryCalculator
            .calculate(
                timeline: timeline,
                videoSamples: videoSamples,
                audioSamples: renditions.map {
                    $0.writer
                        .observedBandwidthSegmentSamples
                }
            )
    }

    func advanceVideoDecodeDemand(to time: CMTime) throws {
        guard let hybridVideoDecodeSink else { return }

        // Update the sink first so packets read while producing the demand's
        // carrier segment decode immediately up to the current clock horizon.
        // A carrier resource may already be cached by AVPlayer after a seek,
        // so loopback HTTP requests cannot be the only owner that advances the
        // fresh generation's source demuxer.
        do {
            try hybridVideoDecodeSink.advanceDecodeDemand(to: time)
        } catch {
            let typed = BlackCarrierMediaFanoutPumpError
                .wrappingVideoSinkFailure(error)
            failAfterUnlock(typed)
            throw typed
        }

        let reachesFiniteEnd = CMTimeCompare(
            time,
            timeline.duration
        ) >= 0
        let demandedSegmentIndex: Int?
        if reachesFiniteEnd {
            demandedSegmentIndex = timeline.segments.indices.last
        } else {
            demandedSegmentIndex = timeline.segmentIndex(
                containing: time
            )
        }
        guard let demandedSegmentIndex else {
            let typed = BlackCarrierMediaFanoutPumpError
                .invalidSegmentIndex(index: 0)
            failAfterUnlock(typed)
            throw typed
        }

        // Do not catch this call here. Source, demux, mux and generation
        // failures are already typed by `produce` and must not be mislabeled
        // as decoder/sink failures.
        try produce(throughSegment: demandedSegmentIndex)

        guard reachesFiniteEnd else { return }
        // Exact-end demand is also the decoded-video completion barrier for
        // this generation. `finish` drains queued packets, delayed decoder
        // output and presentation ordering before returning; the renderer may
        // still display relay-owned frames asynchronously.
        do {
            try hybridVideoDecodeSink.finish()
        } catch {
            let typed = BlackCarrierMediaFanoutPumpError
                .wrappingVideoSinkFailure(error)
            failAfterUnlock(typed)
            throw typed
        }
    }

    func finishStores() throws -> [BlackCarrierAudioRenditionStore] {
        guard let lastIndex = timeline.segments.indices.last else {
            throw BlackCarrierMediaFanoutPumpError.invalidSegmentIndex(
                index: 0
            )
        }
        try produce(throughSegment: lastIndex)

        lock.lock()
        guard !isClosed else {
            lock.unlock()
            throw BlackCarrierMediaFanoutPumpError.closed
        }
        do {
            let stores = try renditions.map { rendition in
                guard let summary = summaries[
                    rendition.metadata.ordinal
                ] else {
                    throw BlackCarrierMediaFanoutPumpError
                        .requestedSegmentUnavailable(index: lastIndex)
                }
                return try BlackCarrierAudioRenditionStore(
                    metadata: rendition.metadata,
                    summary: summary,
                    cache: rendition.cache,
                    timeline: timeline
                )
            }
            isClosed = true
            let demuxerToClose = ownsActiveDemuxer ? demuxer : nil
            ownsActiveDemuxer = false
            let sourceFactoryToClose = sourceFactory
            sourceFactory = nil
            lock.unlock()
            demuxerToClose?.close()
            hybridVideoDecodeSink?.close()
            sourceFactoryToClose?.close()
            return stores
        } catch let error as BlackCarrierMediaFanoutPumpError {
            lock.unlock()
            failAfterUnlock(error)
            throw error
        } catch let error as BlackCarrierAudioRenditionStoreError {
            let typed = BlackCarrierMediaFanoutPumpError.audioStoreFailed(
                error: error
            )
            lock.unlock()
            failAfterUnlock(typed)
            throw typed
        } catch {
            let typed = BlackCarrierMediaFanoutPumpError
                .wrappingDemuxFailure(error)
            lock.unlock()
            failAfterUnlock(typed)
            throw typed
        }
    }

    func peekInitSegment(ordinal: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return rendition(at: ordinal)?.cache.fetchInit(timeout: 0)
    }

    func peekMediaSegmentURL(
        ordinal: Int,
        index: Int
    ) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return rendition(at: ordinal)?.cache.peekURL(index: index)
    }

    func makeAudioAnalysisInput() throws -> AudioAnalysisInput {
        let factory: BlackCarrierDemuxSourceFactory
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            throw BlackCarrierMediaFanoutPumpError.closed
        }
        guard let sourceFactory else {
            lock.unlock()
            throw BlackCarrierMediaFanoutPumpError
                .analysisSourceFactoryMissing
        }
        factory = sourceFactory
        lock.unlock()
        return try factory.makeAudioAnalysisInput()
    }

    func close() {
        setRoutePreparationProgressHandler(nil)
        demuxerReferenceLock.lock()
        let activeDemuxer = interruptibleDemuxer
        demuxerReferenceLock.unlock()
        activeDemuxer.markClosed()

        lock.lock()
        let caches: [SegmentCache]
        if isClosed {
            caches = []
        } else {
            isClosed = true
            caches = renditions.map(\.cache)
        }
        let demuxerToClose = ownsActiveDemuxer ? demuxer : nil
        ownsActiveDemuxer = false
        let sourceFactoryToClose = sourceFactory
        sourceFactory = nil
        clearRequestedRestart()
        lock.unlock()
        caches.forEach { $0.close() }
        demuxerToClose?.close()
        hybridVideoDecodeSink?.close()
        sourceFactoryToClose?.close()
    }

    /// Release fence for route replacement. `close()` performs the fast
    /// cooperative interrupt; this method additionally waits for a late
    /// restart factory and every active Demuxer-owned asynchronous callback.
    func closeAndWaitForIOQuiescence() {
        close()
        restartLock.lock()
        restartLock.unlock()

        demuxerReferenceLock.lock()
        let finalDemuxer = interruptibleDemuxer
        demuxerReferenceLock.unlock()
        demuxerReleaseFence(finalDemuxer)
    }

    private func finishWriters() throws {
        guard !isFinished else { return }
        if let hybridVideoDecodeSink {
            do {
                try hybridVideoDecodeSink.markEndOfStream()
            } catch {
                throw BlackCarrierMediaFanoutPumpError
                    .wrappingVideoSinkFailure(error)
            }
        }
        for rendition in renditions {
            do {
                summaries[rendition.metadata.ordinal] =
                    try rendition.writer.finish()
            } catch let error as BlackCarrierAudioRenditionMuxerError {
                throw BlackCarrierMediaFanoutPumpError.audioMuxerFailed(
                    trackID: rendition.metadata.sourceTrackID,
                    error: error
                )
            } catch let error as BlackCarrierAudioRenditionStoreError {
                throw BlackCarrierMediaFanoutPumpError.audioStoreFailed(
                    error: error
                )
            }
        }
        nativeSubtitleRenditions.forEach {
            $0.store.markFinished()
        }
        isFinished = true
    }

    private func hasSegment(_ index: Int) -> Bool {
        let audioReady = renditions.allSatisfy {
            $0.writer.highestFinalizedSegmentIndex >= index
                && $0.cache.peekURL(index: index) != nil
        }
        guard audioReady else { return false }
        guard videoSourceCoversSegment(index) else { return false }
        return hybridVideoDecodeSink?.isTargetFrameReady ?? true
    }

    private func videoSourceCoversSegment(_ index: Int) -> Bool {
        guard videoPacketSink != nil else { return true }
        guard timeline.segments.indices.contains(index) else { return false }
        if isFinished {
            return true
        }
        guard videoProductionEnd.isValid,
              videoProductionEnd.isNumeric else {
            return false
        }
        let segment = timeline.segments[index]
        let segmentEnd = CMTimeAdd(
            segment.startTime,
            segment.duration
        )
        return CMTimeCompare(videoProductionEnd, segmentEnd) >= 0
    }

    private func updateVideoProductionEnd(
        _ packet: UnsafeMutablePointer<AVPacket>
    ) {
        guard videoTimeBaseNumerator > 0,
              videoTimeBaseDenominator > 0 else {
            return
        }
        let timestamp = packet.pointee.pts != Int64.min
            ? packet.pointee.pts
            : packet.pointee.dts
        guard timestamp != Int64.min else { return }
        let start = BlackCarrierSourceAxis.timelineTime(
            timestamp: timestamp,
            sourceStartPTS: videoSourceStartPTS,
            timeBase: AVRational(
                num: videoTimeBaseNumerator,
                den: videoTimeBaseDenominator
            )
        )
        let duration = packet.pointee.duration > 0
            ? CMTime(
                value: packet.pointee.duration
                    * Int64(videoTimeBaseNumerator),
                timescale: videoTimeBaseDenominator
            )
            : nominalVideoFrameDuration
        let end = duration.isValid
            && duration.isNumeric
            && CMTimeCompare(duration, .zero) > 0
            ? CMTimeAdd(start, duration)
            : start
        if !videoProductionEnd.isValid
            || !videoProductionEnd.isNumeric
            || CMTimeCompare(end, videoProductionEnd) > 0 {
            videoProductionEnd = end
        }
    }

    private func throwIfVideoDecoderFailed() throws {
        guard let error = hybridVideoDecodeSink?.failure else {
            return
        }
        throw BlackCarrierMediaFanoutPumpError
            .videoDecoderFailed(error: error)
    }

    private func cachedSegmentExists(_ index: Int) -> Bool {
        renditions.allSatisfy {
            $0.cache.peekURL(index: index) != nil
        }
    }

    private func rendition(at ordinal: Int) -> Rendition? {
        guard renditions.indices.contains(ordinal) else { return nil }
        return renditions[ordinal]
    }

    private func fail(_ error: BlackCarrierMediaFanoutPumpError) {
        terminalError = error
        renditions.forEach { $0.cache.close() }
    }

    private func failWhileLocked(
        _ error: BlackCarrierMediaFanoutPumpError
    ) {
        terminalError = error
        isClosed = true
        clearRequestedRestart()
        renditions.forEach { $0.cache.close() }
    }

    private func failAfterUnlock(
        _ error: BlackCarrierMediaFanoutPumpError
    ) {
        lock.lock()
        terminalError = error
        isClosed = true
        let caches = renditions.map(\.cache)
        lock.unlock()
        caches.forEach { $0.close() }
    }

    private func generationSnapshot() -> UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        return currentGeneration
    }

    private func isGenerationSuperseded(
        _ generation: UInt64
    ) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        if let requestedRestartGeneration {
            return requestedRestartGeneration > generation
        }
        return currentGeneration > generation
    }

    private func clearRequestedRestart() {
        generationLock.lock()
        requestedRestartGeneration = nil
        generationLock.unlock()
    }

    private static func makeWriter(
        demuxer: Demuxer,
        streamIndex: Int32,
        metadata: BlackCarrierAudioRenditionMetadata,
        cache: SegmentCache,
        timeline: BlackCarrierTimeline,
        bridgeMode: AudioBridgeMode,
        startingSegmentIndex: Int,
        preserveEncoderPriming: Bool,
        presentationTimelineOffset: Int64? = nil,
        decodeTimestampOffset: Int64 = 0,
        restartTimestampRebaseEnabled: Bool = false
    ) throws -> BlackCarrierAudioRenditionMuxer.Writer {
        try BlackCarrierAudioRenditionMuxer.makeWriter(
            demuxer: demuxer,
            audioStreamIndex: streamIndex,
            sourceStartPTS: BlackCarrierSourceAxis.sourceStartPTS(
                demuxer: demuxer,
                streamIndex: streamIndex
            ),
            timeline: timeline,
            bridgeMode: bridgeMode,
            startingSegmentIndex: startingSegmentIndex,
            preserveEncoderPriming: preserveEncoderPriming,
            presentationTimelineOffset: presentationTimelineOffset,
            decodeTimestampOffset: decodeTimestampOffset,
            restartTimestampRebaseEnabled:
                restartTimestampRebaseEnabled,
            sessionDirectory: cache.sessionDir,
            onInit: {
                if cache.fetchInit(timeout: 0) == nil {
                    cache.setInit($0)
                }
            },
            onSegment: { timing, stagingPath, bytesWritten in
                cache.adopt(
                    index: timing.index,
                    stagingPath: stagingPath,
                    byteCount: bytesWritten
                )
                guard cache.peekURL(index: timing.index) != nil else {
                    throw BlackCarrierAudioRenditionStoreError
                        .segmentStoreFailed(
                            trackID: metadata.sourceTrackID,
                            index: timing.index
                        )
                }
            }
        )
    }

    private static func nominalFrameDuration(
        stream: UnsafeMutablePointer<AVStream>
    ) -> CMTime {
        let frameRate = stream.pointee.avg_frame_rate.den > 0
            && stream.pointee.avg_frame_rate.num > 0
            ? stream.pointee.avg_frame_rate
            : stream.pointee.r_frame_rate
        guard frameRate.num > 0, frameRate.den > 0 else {
            return .invalid
        }
        return CMTime(
            value: Int64(frameRate.den),
            timescale: frameRate.num
        )
    }

    private static func videoDecodeRestartAnchor(
        demuxer: Demuxer,
        streamIndex: Int32,
        targetTime: CMTime
    ) -> CMTime? {
        guard streamIndex >= 0,
              let stream = demuxer.stream(at: streamIndex) else {
            return nil
        }
        let sourceStartPTS =
            BlackCarrierSourceAxis.sourceStartPTS(
                demuxer: demuxer,
                streamIndex: streamIndex
            )
        let timeBase = stream.pointee.time_base
        return demuxer.indexedKeyframes(
            streamIndex: streamIndex
        )
        .lazy
        .map {
            BlackCarrierSourceAxis.timelineTime(
                timestamp: $0,
                sourceStartPTS: sourceStartPTS,
                timeBase: timeBase
            )
        }
        .filter {
            $0.isValid
                && $0.isNumeric
                && CMTimeCompare($0, .zero) >= 0
                && CMTimeCompare($0, targetTime) <= 0
        }
        .max(by: {
            CMTimeCompare($0, $1) < 0
        })
    }

    private static func isHybridOverlaySubtitleTrack(
        _ info: TrackInfo
    ) -> Bool {
        AetherEngine.isBitmapSubtitleCodec(info.codec)
            || info.codec == "ass"
            || info.codec == "ssa"
    }

    static func isFaithfullyConvertibleNativeSubtitleTrack(
        _ info: TrackInfo
    ) -> Bool {
        guard !AetherEngine.isEmbeddedClosedCaptionCodec(info.codec) else {
            return false
        }
        switch info.codec.lowercased() {
        case "subrip", "srt", "mov_text", "webvtt", "text":
            return true
        default:
            return false
        }
    }

    static func nativeSubtitleMetadata(
        for tracks: [TrackInfo]
    ) -> [BlackCarrierNativeSubtitleRenditionMetadata] {
        let defaultTrackID = tracks.first(where: \.isDefault)?.id
        var nameCounts: [String: Int] = [:]
        return tracks.enumerated().map { ordinal, track in
            let baseName = track.name.isEmpty
                ? "Subtitle \(ordinal + 1)"
                : track.name
            let count = (nameCounts[baseName] ?? 0) + 1
            nameCounts[baseName] = count
            return BlackCarrierNativeSubtitleRenditionMetadata(
                ordinal: ordinal,
                sourceTrackID: track.id,
                language: track.language,
                name: count == 1
                    ? baseName
                    : "\(baseName) \(count)",
                isDefault: track.id == defaultTrackID,
                isAutoselect: true,
                isForced: track.isForced
            )
        }
    }
}
