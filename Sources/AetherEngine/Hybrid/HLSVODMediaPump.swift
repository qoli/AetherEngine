import CoreMedia
import Foundation
import Libavcodec
import Libavformat
import Libavutil

enum HLSVODMediaPumpError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case invalidPreflight
    case closed
    case cancelled
    case targetSegmentOutOfRange(Int)
    case restartRequiresUserSeek
    case seekIntentSegmentMismatch(
        expected: Int,
        actual: Int
    )
    case generationSuperseded(generation: UInt64)
    case restartTimelineOffsetUnavailable(
        renditionOrdinal: Int
    )
    case fragmentDecodeTimeMissing(
        trackID: UInt32,
        segmentIndex: Int
    )
    case finalFixtureSummaryUnavailableAfterRestart(
        generation: UInt64
    )
    case origin(HLSVODOriginResourceError)
    case demuxOpenFailed
    case packetReadFailed
    case videoStreamCount(segmentIndex: Int, count: Int)
    case videoContractChanged(segmentIndex: Int)
    case videoPacketMissing(segmentIndex: Int)
    case audioRenditionContainsVideo(
        renditionOrdinal: Int,
        inputSegmentIndex: Int
    )
    case audioStreamCount(
        renditionOrdinal: Int,
        inputSegmentIndex: Int,
        count: Int
    )
    case audioContractChanged(
        renditionOrdinal: Int,
        inputSegmentIndex: Int
    )
    case audioPacketMissing(
        renditionOrdinal: Int,
        inputSegmentIndex: Int
    )
    case muxedAudioStreamCount(
        segmentIndex: Int,
        expected: Int,
        actual: Int
    )
    case muxedAudioContractChanged(
        ordinal: Int,
        segmentIndex: Int
    )
    case muxedAudioPacketMissing(
        ordinal: Int,
        segmentIndex: Int
    )
    case timestampMissing(
        streamIndex: Int,
        segmentIndex: Int
    )
    case timestampOverflow(
        streamIndex: Int,
        segmentIndex: Int
    )
    case videoSinkFailed(reason: String)
    case audioMuxerFailed(
        renditionOrdinal: Int,
        error: BlackCarrierAudioRenditionMuxerError
    )
    case audioStoreFailed(
        renditionOrdinal: Int,
        error: BlackCarrierAudioRenditionStoreError
    )
    case retiredSegmentRequest(
        index: Int,
        generationStart: Int
    )
    case requestedSegmentUnavailable(Int)
    case unexpected(reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidPreflight:
            "HLS VOD media pump requires an admitted hybrid resource graph"
        case .closed:
            "HLS VOD media pump is closed"
        case .cancelled:
            "HLS VOD media pump was cancelled"
        case .targetSegmentOutOfRange(let index):
            "HLS VOD media pump target segment \(index) is out of range"
        case .restartRequiresUserSeek:
            "HLS VOD media pump restart requires an explicit user-seek intent"
        case .seekIntentSegmentMismatch(
            let expected,
            let actual
        ):
            "HLS VOD seek intent segment \(actual) does not match target segment \(expected)"
        case .generationSuperseded(let generation):
            "HLS VOD media pump generation \(generation) was superseded by a later seek"
        case .restartTimelineOffsetUnavailable(
            let ordinal
        ):
            "HLS VOD audio rendition \(ordinal) has no startup timeline offset for restart"
        case .fragmentDecodeTimeMissing(
            let trackID,
            let segmentIndex
        ):
            "HLS VOD fMP4 segment \(segmentIndex) has no unique tfdt evidence for track \(trackID)"
        case .finalFixtureSummaryUnavailableAfterRestart(
            let generation
        ):
            "HLS VOD generation \(generation) cannot produce a final fixture summary after seek restart"
        case .origin(let error):
            error.localizedDescription
        case .demuxOpenFailed:
            "HLS VOD media pump could not open a graph-bound segment"
        case .packetReadFailed:
            "HLS VOD media pump packet read failed"
        case .videoStreamCount(let index, let count):
            "HLS VOD video segment \(index) exposed \(count) video streams"
        case .videoContractChanged(let index):
            "HLS VOD video stream contract changed in segment \(index)"
        case .videoPacketMissing(let index):
            "HLS VOD video segment \(index) produced no video packet"
        case .audioRenditionContainsVideo(let ordinal, let index):
            "HLS VOD audio rendition \(ordinal) segment \(index) unexpectedly contains video"
        case .audioStreamCount(let ordinal, let index, let count):
            "HLS VOD audio rendition \(ordinal) segment \(index) exposed \(count) audio streams"
        case .audioContractChanged(let ordinal, let index):
            "HLS VOD audio rendition \(ordinal) contract changed in segment \(index)"
        case .audioPacketMissing(let ordinal, let index):
            "HLS VOD audio rendition \(ordinal) segment \(index) produced no audio packet"
        case .muxedAudioStreamCount(let index, let expected, let actual):
            "HLS VOD video segment \(index) exposed \(actual) muxed audio streams; expected \(expected)"
        case .muxedAudioContractChanged(let ordinal, let index):
            "HLS VOD muxed audio rendition \(ordinal) contract changed in video segment \(index)"
        case .muxedAudioPacketMissing(let ordinal, let index):
            "HLS VOD muxed audio rendition \(ordinal) produced no packet in video segment \(index)"
        case .timestampMissing(let streamIndex, let segmentIndex):
            "HLS VOD stream \(streamIndex) segment \(segmentIndex) has no packet timestamp"
        case .timestampOverflow(let streamIndex, let segmentIndex):
            "HLS VOD stream \(streamIndex) segment \(segmentIndex) timestamp exceeded the source axis"
        case .videoSinkFailed(let reason):
            "HLS VOD real-video packet sink failed: \(reason)"
        case .audioMuxerFailed(let ordinal, let error):
            "HLS VOD audio rendition \(ordinal) failed: \(error.localizedDescription)"
        case .audioStoreFailed(let ordinal, let error):
            "HLS VOD audio rendition \(ordinal) storage failed: \(error.localizedDescription)"
        case .retiredSegmentRequest(
            let index,
            let generationStart
        ):
            "HLS VOD carrier request for retired segment \(index) precedes generation start \(generationStart)"
        case .requestedSegmentUnavailable(let index):
            "HLS VOD carrier segment \(index) was not produced"
        case .unexpected(let reason):
            "HLS VOD media pump failed unexpectedly: \(reason)"
        }
    }
}

struct HLSVODMediaPumpSnapshot: Sendable, Equatable {
    let generation: UInt64
    let generationStartSegmentIndex: Int
    let nextVideoInputSegmentIndex: Int
    let nextAudioInputSegmentIndices: [Int]
    let highestProducedVideoSegmentIndex: Int
    let highestFinalizedAudioSegmentIndices: [Int]
    let videoPacketCount: Int
    let audioPacketCounts: [Int]
    let isClosed: Bool
}

/// Incremental packet pump for the exact HLS VOD resources admitted by preflight.
///
/// Each upstream segment is opened in a fresh finite in-memory FFmpeg demuxer. Packet timestamps are
/// normalized from that segment's local origin onto the immutable 90 kHz graph timeline before they
/// enter the real-video sink or long-lived carrier-audio writer. FFmpeg never receives a URL and cannot
/// reopen the master playlist, choose a different variant or perform network I/O.
///
/// This remains an engine-private source pump. The public HLS session factory, transport,
/// seek-generation replacement and independent graph-bound analysis cursor own the same bounded origin
/// loader; callers receive only the AVPlayer, sample-buffer surface and typed public diagnostics.
/// Audio production may read one upstream segment ahead because an audio access unit from
/// the next carrier interval is the evidence that lets the long-lived fMP4 writer finalize the requested
/// fragment; the following carrier fragment is not finalized until a later demand.
actor HLSVODMediaPump {
    typealias VideoPacketSink =
        BlackCarrierMediaFanoutPump.VideoPacketSink

    let renditionMetadata: [BlackCarrierAudioRenditionMetadata]
    let renditionDescriptors: [BlackCarrierAudioRenditionDescriptor]
    let subtitleRenditions:
        [HLSVODSubtitleRenditionResource]
    let hybridSubtitleContracts:
        [HybridSubtitleDecodeContract]
    let hybridSubtitlePacketStore: SubtitlePacketStore
    let hybridSubtitleRuntimeAvailability:
        HybridSubtitleRuntimeAvailabilityStore

    private let graph: HLSVODResourceGraph
    private let loader: HLSVODOriginResourceLoader
    /// Isolated so a subtitle-origin failure can disable only that track without invalidating playback.
    private let subtitleLoader:
        HLSVODOriginResourceLoader?
    private let worker: Worker
    private let videoInitData: Data?
    private let audioInitData: [Data?]
    private let analysisInput: AudioAnalysisInput

    private var nextVideoInputSegmentIndex = 0
    private var nextAudioInputSegmentIndices: [Int]
    private var terminalError: HLSVODMediaPumpError?
    private var isClosed = false
    private var productionInProgress = false
    private var restartInProgress = false
    private var currentGeneration: UInt64
    private var generationStartSegmentIndex = 0
    private var didRestart = false
    private var requestedRestartGeneration: UInt64?
    private var unavailableSubtitleOrdinals:
        Set<Int> = []
    private var productionTask: Task<Void, Never>?
    private var productionWaiters: [
        CheckedContinuation<Void, Never>
    ] = []

    static func make(
        preflight: AetherHLSPlaybackPreflight,
        bridgeMode: AudioBridgeMode = .surroundCompat,
        videoPacketSink: VideoPacketSink? = nil,
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
    ) async throws -> HLSVODMediaPump {
        guard preflight.result.route == .hybridCarrier,
              preflight.result.sourceProfile.sourceKind == .hls,
              let graph = preflight.resourceGraph else {
            throw HLSVODMediaPumpError.invalidPreflight
        }
        guard videoPacketSink == nil
                || decodedFrameHandler == nil else {
            throw HLSVODMediaPumpError.videoSinkFailed(
                reason:
                    "Multiple real-video packet sinks were supplied"
            )
        }
        let loader: HLSVODOriginResourceLoader
        do {
            loader = try HLSVODOriginResourceLoader(
                graph: graph,
                httpHeaders: preflight.httpHeaders,
                maximumResourceBytes: maximumResourceBytes,
                capacityBytes: capacityBytes,
                baseDirectory: baseDirectory,
                fetchOverride: fetchOverride
            )
        } catch let error as HLSVODOriginResourceError {
            throw HLSVODMediaPumpError.origin(error)
        }

        let subtitleLoader:
            HLSVODOriginResourceLoader?
        if graph.subtitleRenditions.isEmpty {
            subtitleLoader = nil
        } else {
            do {
                subtitleLoader = try HLSVODOriginResourceLoader(
                    graph: graph,
                    httpHeaders: preflight.httpHeaders,
                    maximumResourceBytes:
                        maximumResourceBytes,
                    capacityBytes: capacityBytes,
                    baseDirectory: baseDirectory,
                    fetchOverride: fetchOverride
                )
            } catch {
                EngineLog.emit(
                    "[HLSVODMediaPump] subtitle loader unavailable; subtitle renditions disabled",
                    category: .session
                )
                subtitleLoader = nil
            }
        }

        do {
            let videoInitData: Data?
            if graph.initSegmentURL != nil {
                videoInitData = try await loader.payload(
                    for: .videoInit
                ).data
            } else {
                videoInitData = nil
            }
            let firstVideoSegment = try await loader.payload(
                for: .videoSegment(index: 0)
            ).data

            var audioInitData: [Data?] = []
            var firstAudioSegments: [Data] = []
            audioInitData.reserveCapacity(
                graph.audioRenditions.count
            )
            firstAudioSegments.reserveCapacity(
                graph.audioRenditions.count
            )
            for rendition in graph.audioRenditions {
                if rendition.initSegmentURL != nil {
                    audioInitData.append(
                        try await loader.payload(
                            for: .audioInit(
                                renditionOrdinal:
                                    rendition.ordinal
                            )
                        ).data
                    )
                } else {
                    audioInitData.append(nil)
                }
                firstAudioSegments.append(
                    try await loader.payload(
                        for: .audioSegment(
                            renditionOrdinal:
                                rendition.ordinal,
                            index: 0
                        )
                    ).data
                )
            }

            let worker = try Worker(
                graph: graph,
                bridgeMode: bridgeMode,
                videoInitData: videoInitData,
                firstVideoSegmentData:
                    firstVideoSegment,
                audioInitData: audioInitData,
                firstAudioSegmentData:
                    firstAudioSegments,
                videoPacketSink: videoPacketSink,
                decodedFrameHandler:
                    decodedFrameHandler,
                videoFailureHandler:
                    videoFailureHandler,
                initialGeneration: initialGeneration
            )
            guard worker.hybridSubtitleContracts.map(\.track)
                    == preflight.overlaySubtitleTracks else {
                worker.close()
                throw HLSVODMediaPumpError.invalidPreflight
            }
            return try HLSVODMediaPump(
                graph: graph,
                loader: loader,
                subtitleLoader: subtitleLoader,
                worker: worker,
                videoInitData: videoInitData,
                audioInitData: audioInitData,
                initialGeneration: initialGeneration
            )
        } catch {
            do {
                try await loader.close()
            } catch {
                EngineLog.emit(
                    "[HLSVODMediaPump] setup cleanup failed: "
                        + String(describing: error),
                    category: .session
                )
            }
            if let subtitleLoader {
                do {
                    try await subtitleLoader.close()
                } catch {
                    EngineLog.emit(
                        "[HLSVODMediaPump] subtitle setup cleanup failed",
                        category: .session
                    )
                }
            }
            throw Self.typed(error)
        }
    }

    private init(
        graph: HLSVODResourceGraph,
        loader: HLSVODOriginResourceLoader,
        subtitleLoader:
            HLSVODOriginResourceLoader?,
        worker: Worker,
        videoInitData: Data?,
        audioInitData: [Data?],
        initialGeneration: UInt64
    ) throws {
        self.graph = graph
        self.loader = loader
        self.subtitleLoader = subtitleLoader
        self.worker = worker
        self.videoInitData = videoInitData
        self.audioInitData = audioInitData
        analysisInput = .hlsVOD(
            try HLSVODAudioAnalysisInput(
                graph: graph,
                loader: loader,
                metadata: worker.renditionMetadata,
                contracts: worker.audioAnalysisContracts
            )
        )
        currentGeneration = initialGeneration
        renditionMetadata = worker.renditionMetadata
        renditionDescriptors = worker.renditionDescriptors
        subtitleRenditions = subtitleLoader == nil
            ? []
            : graph.subtitleRenditions
        hybridSubtitleContracts =
            worker.hybridSubtitleContracts
        hybridSubtitlePacketStore =
            worker.hybridSubtitlePacketStore
        hybridSubtitleRuntimeAvailability =
            worker.hybridSubtitleRuntimeAvailability
        nextAudioInputSegmentIndices = Array(
            repeating: 0,
            count: graph.audioRenditions.count
        )
    }

    func produce(throughSegment target: Int) async throws {
        guard graph.segments.indices.contains(target) else {
            throw HLSVODMediaPumpError
                .targetSegmentOutOfRange(target)
        }
        let operationGeneration = currentGeneration

        while true {
            try requireAvailable(
                generation: operationGeneration
            )
            if target < generationStartSegmentIndex {
                guard worker.cachedSegmentExists(
                    target
                ) else {
                    let workerSnapshot = worker.snapshot()
                    EngineLog.emit(
                        "[HLSVODMediaPump] requested retired segment unavailable "
                            + "operationGeneration=\(operationGeneration) "
                            + "currentGeneration=\(currentGeneration) "
                            + "generationStart=\(generationStartSegmentIndex) "
                            + "target=\(target) "
                            + "nextVideo=\(nextVideoInputSegmentIndex) "
                            + "nextAudio=\(nextAudioInputSegmentIndices) "
                            + "highestVideo=\(workerSnapshot.highestProducedVideoSegmentIndex) "
                            + "highestAudio=\(workerSnapshot.highestFinalizedAudioSegmentIndices)",
                        category: .session
                    )
                    throw HLSVODMediaPumpError
                        .retiredSegmentRequest(
                            index: target,
                            generationStart:
                                generationStartSegmentIndex
                        )
                }
                return
            }
            if worker.hasProduced(segment: target) {
                return
            }
            if productionInProgress
                || restartInProgress {
                try await waitForProduction()
                continue
            }

            productionInProgress = true
            let task = Task {
                await performProduction(
                    throughSegment: target,
                    generation:
                        operationGeneration
                )
            }
            productionTask = task
            try await waitForProduction()
        }
    }

    func restart(
        for intent: HybridSeekIntent
    ) async throws
        -> BlackCarrierMediaFanoutRestartResult
    {
        guard case .userSeek(
            let target,
            let requestedSegmentIndex,
            let requestedGeneration
        ) = intent else {
            throw HLSVODMediaPumpError
                .restartRequiresUserSeek
        }
        guard let expectedSegmentIndex =
                graph.timeline.segmentIndex(
                    containing: target
                ) else {
            throw HLSVODMediaPumpError
                .targetSegmentOutOfRange(
                    requestedSegmentIndex
                )
        }
        guard requestedSegmentIndex
                == expectedSegmentIndex else {
            throw HLSVODMediaPumpError
                .seekIntentSegmentMismatch(
                    expected: expectedSegmentIndex,
                    actual: requestedSegmentIndex
                )
        }

        while restartInProgress {
            try requireAvailable()
            try await waitForProduction()
        }
        try requireAvailable()
        if requestedGeneration
                <= currentGeneration {
            return .stale(
                currentGeneration:
                    currentGeneration
            )
        }

        requestedRestartGeneration =
            requestedGeneration
        let retiringProduction =
            productionTask
        retiringProduction?.cancel()
        if let retiringProduction {
            await retiringProduction.value
        }
        try requireRestartCurrent(
            requestedGeneration
        )
        restartInProgress = true

        do {
            try Task.checkCancellation()
            let videoSegmentData =
                try await loader.payload(
                    for: .videoSegment(
                        index:
                            expectedSegmentIndex
                    )
                ).data
            try requireRestartCurrent(
                requestedGeneration
            )
            var audioInputSegmentIndices: [Int] =
                []
            var audioSegmentData: [Data] = []
            audioInputSegmentIndices.reserveCapacity(
                graph.audioRenditions.count
            )
            audioSegmentData.reserveCapacity(
                graph.audioRenditions.count
            )
            let targetSegmentStart =
                graph.timeline.segments[
                    expectedSegmentIndex
                ].startTime
            for rendition in
                    graph.audioRenditions {
                let inputSegmentIndex =
                    try Self.audioInputSegmentIndex(
                        containing:
                            targetSegmentStart,
                        segments:
                            rendition.segments
                    )
                audioInputSegmentIndices.append(
                    inputSegmentIndex
                )
                audioSegmentData.append(
                    try await loader.payload(
                        for: .audioSegment(
                            renditionOrdinal:
                                rendition.ordinal,
                            index:
                                inputSegmentIndex
                        )
                    ).data
                )
                try requireRestartCurrent(
                    requestedGeneration
                )
            }
            try Task.checkCancellation()
            try requireRestartCurrent(
                requestedGeneration
            )
            try worker.restart(
                generation: requestedGeneration,
                targetTime: target,
                segmentIndex:
                    expectedSegmentIndex,
                videoInitData:
                    videoInitData,
                videoSegmentData:
                    videoSegmentData,
                audioInitData:
                    audioInitData,
                audioInputSegmentIndices:
                    audioInputSegmentIndices,
                audioSegmentData:
                    audioSegmentData
            )
            nextVideoInputSegmentIndex =
                expectedSegmentIndex
            nextAudioInputSegmentIndices =
                audioInputSegmentIndices
            currentGeneration =
                requestedGeneration
            generationStartSegmentIndex =
                expectedSegmentIndex
            EngineLog.emit(
                "[HLSVODMediaPump] restart applied "
                    + "generation=\(currentGeneration) "
                    + "generationStart=\(generationStartSegmentIndex) "
                    + "nextVideo=\(nextVideoInputSegmentIndex) "
                    + "nextAudio=\(nextAudioInputSegmentIndices)",
                category: .session
            )
            didRestart = true
            requestedRestartGeneration = nil
            restartInProgress = false
            resumeProductionWaiters()
            return .applied(
                generation: requestedGeneration,
                segmentIndex:
                    expectedSegmentIndex
            )
        } catch {
            restartInProgress = false
            resumeProductionWaiters()
            let typed = Self.typed(error)
            if case .generationSuperseded =
                    typed {
                return .stale(
                    currentGeneration:
                        max(
                            currentGeneration,
                            requestedRestartGeneration
                                ?? currentGeneration
                        )
                )
            }
            requestedRestartGeneration = nil
            if !isClosed {
                terminalError = typed
            }
            worker.close()
            do {
                try await loader.close()
            } catch {
                EngineLog.emit(
                    "[HLSVODMediaPump] restart failure cleanup failed: "
                        + String(describing: error),
                    category: .session
                )
            }
            throw typed
        }
    }

    func audioInitSegment(
        renditionOrdinal: Int
    ) async throws -> Data? {
        guard renditionMetadata.indices
            .contains(renditionOrdinal) else {
            return nil
        }
        try await produce(throughSegment: 0)
        return worker.audioInitSegment(
            renditionOrdinal: renditionOrdinal
        )
    }

    func audioMediaSegmentURL(
        renditionOrdinal: Int,
        segmentIndex: Int
    ) async throws -> URL? {
        guard renditionMetadata.indices
            .contains(renditionOrdinal),
              graph.segments.indices
                .contains(segmentIndex) else {
            return nil
        }
        try await produceCarrierAudioSegment(
            segmentIndex
        )
        return worker.audioMediaSegmentURL(
            renditionOrdinal: renditionOrdinal,
            segmentIndex: segmentIndex
        )
    }

    func audioMediaSegment(
        renditionOrdinal: Int,
        segmentIndex: Int
    ) async throws -> Data? {
        guard renditionMetadata.indices
            .contains(renditionOrdinal),
              graph.segments.indices
                .contains(segmentIndex) else {
            return nil
        }
        try await produceCarrierAudioSegment(
            segmentIndex
        )
        return worker.audioMediaSegment(
            renditionOrdinal: renditionOrdinal,
            segmentIndex: segmentIndex
        )
    }

    /// A loopback audio request is bound to an advertised carrier URI, not to the decoder generation
    /// that happened to be active when AVPlayer opened the HTTP connection. If a stall-triggered seek
    /// retires that generation, keep the same local request attached to the replacement production and
    /// fulfill it from the new writer. Returning `generationSuperseded` here truncates an already-committed
    /// chunked response; AVPlayer does not reliably re-request alternate audio after that truncation.
    private func produceCarrierAudioSegment(
        _ segmentIndex: Int
    ) async throws {
        while true {
            do {
                try await produce(
                    throughSegment: segmentIndex
                )
                return
            } catch let error
                    as HLSVODMediaPumpError {
                guard case .generationSuperseded =
                        error else {
                    throw error
                }
                while requestedRestartGeneration
                        != nil
                        || restartInProgress {
                    try requireAvailable()
                    try await waitForProduction()
                }
            }
        }
    }

    /// Exhausts the graph for deterministic mux-fixture verification.
    ///
    /// Production provider construction and startup never call this test-only assembly boundary.
    func finishFixtureProduction() async throws
        -> [BlackCarrierAudioRenditionSummary]
    {
        guard !didRestart else {
            throw HLSVODMediaPumpError
                .finalFixtureSummaryUnavailableAfterRestart(
                    generation:
                        currentGeneration
                )
        }
        guard let last =
                graph.segments.indices.last else {
            throw HLSVODMediaPumpError
                .targetSegmentOutOfRange(0)
        }
        try await produce(throughSegment: last)
        guard let summaries =
                worker.audioSummaries() else {
            throw HLSVODMediaPumpError
                .requestedSegmentUnavailable(last)
        }
        return summaries
    }

    func makeAudioAnalysisInput() throws
        -> AudioAnalysisInput
    {
        try requireAvailable()
        return analysisInput
    }

    func setAudioAnalysisPlaybackPressure(
        _ pressure: HybridAudioAnalysisPlaybackPressure
    ) async {
        guard !isClosed else { return }
        await loader.setAudioAnalysisPlaybackPressure(
            pressure
        )
    }

    func advanceVideoDecodeDemand(
        to time: CMTime
    ) throws {
        try requireAvailable()
        do {
            try worker.advanceVideoDecodeDemand(to: time)
        } catch {
            let typed = HLSVODMediaPumpError
                .videoSinkFailed(
                    reason: String(describing: error)
                )
            terminalError = typed
            worker.close()
            throw typed
        }
    }

    var hybridVideoFormat: VideoFormat? {
        worker.hybridVideoFormat
    }

    var hybridDolbyVisionConfiguration:
        AetherDolbyVisionConfiguration?
    {
        worker.hybridDolbyVisionConfiguration
    }

    var hybridVideoFrameRate: Double? {
        worker.hybridVideoFrameRate
    }

    var isTargetFrameReady: Bool {
        worker.isTargetFrameReady
    }

    func snapshot() -> HLSVODMediaPumpSnapshot {
        let workerSnapshot = worker.snapshot()
        return HLSVODMediaPumpSnapshot(
            generation: currentGeneration,
            generationStartSegmentIndex:
                generationStartSegmentIndex,
            nextVideoInputSegmentIndex:
                nextVideoInputSegmentIndex,
            nextAudioInputSegmentIndices:
                nextAudioInputSegmentIndices,
            highestProducedVideoSegmentIndex:
                workerSnapshot
                    .highestProducedVideoSegmentIndex,
            highestFinalizedAudioSegmentIndices:
                workerSnapshot
                    .highestFinalizedAudioSegmentIndices,
            videoPacketCount:
                workerSnapshot.videoPacketCount,
            audioPacketCounts:
                workerSnapshot.audioPacketCounts,
            isClosed: isClosed
        )
    }

    func observedAudioBandwidthSegmentSamples()
        -> [[BlackCarrierBandwidthSegmentSample]]
    {
        worker.observedAudioBandwidthSegmentSamples()
    }

    /// Return the exact admitted WebVTT segment. Any failure disables only this rendition.
    func subtitleVTT(
        renditionOrdinal: Int,
        segmentIndex: Int
    ) async -> String? {
        guard let subtitleLoader,
              subtitleRenditions.indices.contains(
                renditionOrdinal
              ),
              subtitleRenditions[renditionOrdinal]
                .segments.indices.contains(segmentIndex),
              !unavailableSubtitleOrdinals.contains(
                renditionOrdinal
              ) else {
            return nil
        }
        do {
            let data = try await subtitleLoader.payload(
                for: .subtitleSegment(
                    renditionOrdinal:
                        renditionOrdinal,
                    index: segmentIndex
                )
            ).data
            guard Self.isWebVTT(data),
                  let text = String(
                    data: data,
                    encoding: .utf8
                  ) else {
                unavailableSubtitleOrdinals.insert(
                    renditionOrdinal
                )
                EngineLog.emit(
                    "[HLSVODMediaPump] subtitle rendition disabled after invalid WebVTT payload ordinal=\(renditionOrdinal)",
                    category: .session
                )
                return nil
            }
            return text
        } catch {
            unavailableSubtitleOrdinals.insert(
                renditionOrdinal
            )
            EngineLog.emit(
                "[HLSVODMediaPump] subtitle rendition disabled after origin failure ordinal=\(renditionOrdinal)",
                category: .session
            )
            return nil
        }
    }

    func originLoaderSnapshot() async
        -> HLSVODOriginResourceLoaderSnapshot
    {
        await loader.snapshot
    }

    func close() async throws {
        guard !isClosed else { return }
        isClosed = true
        requestedRestartGeneration = nil
        productionTask?.cancel()
        worker.close()
        resumeProductionWaiters()
        var loaderCloseError:
            HLSVODOriginResourceError?
        do {
            try await loader.close()
        } catch let error as HLSVODOriginResourceError {
            loaderCloseError = error
        }
        if let subtitleLoader {
            do {
                try await subtitleLoader.close()
            } catch {
                EngineLog.emit(
                    "[HLSVODMediaPump] subtitle loader cleanup failed",
                    category: .session
                )
            }
        }
        if let loaderCloseError {
            throw HLSVODMediaPumpError.origin(
                loaderCloseError
            )
        }
    }

    private func runProduction(
        throughSegment target: Int,
        generation: UInt64
    ) async throws {
        while nextVideoInputSegmentIndex
                < graph.segments.count,
              nextVideoInputSegmentIndex <= target
                || worker.muxedAudioNeedsInput(
                    throughSegment: target
                ) {
            try requireAvailable(
                generation: generation
            )
            let index = nextVideoInputSegmentIndex
            let data = try await loader.payload(
                for: .videoSegment(index: index)
            ).data
            try requireAvailable(
                generation: generation
            )
            try worker.consumeVideoSegment(
                index: index,
                initData: videoInitData,
                segmentData: data
            )
            nextVideoInputSegmentIndex += 1
        }
        if nextVideoInputSegmentIndex
                == graph.segments.count,
           target == graph.segments.count - 1 {
            try worker.finishVideoInput()
        }

        for rendition in graph.audioRenditions {
            let ordinal = rendition.ordinal
            while nextAudioInputSegmentIndices[ordinal]
                    < rendition.segments.count,
                  worker.audioNeedsInput(
                    renditionOrdinal: ordinal,
                    throughSegment: target
                  ) {
                try requireAvailable(
                    generation: generation
                )
                let index =
                    nextAudioInputSegmentIndices[ordinal]
                let data = try await loader.payload(
                    for: .audioSegment(
                        renditionOrdinal: ordinal,
                        index: index
                    )
                ).data
                try requireAvailable(
                    generation: generation
                )
                try worker.consumeAudioSegment(
                    renditionOrdinal: ordinal,
                    inputSegmentIndex: index,
                    initData: audioInitData[ordinal],
                    segmentData: data
                )
                nextAudioInputSegmentIndices[ordinal]
                    += 1
            }
            if nextAudioInputSegmentIndices[ordinal]
                    == rendition.segments.count,
               target == graph.segments.count - 1 {
                try worker.finishAudioInput(
                    renditionOrdinal: ordinal
                )
            }
        }

        guard worker.hasProduced(segment: target) else {
            let workerSnapshot = worker.snapshot()
            EngineLog.emit(
                "[HLSVODMediaPump] requested segment unavailable "
                    + "generation=\(generation) "
                    + "generationStart=\(generationStartSegmentIndex) "
                    + "target=\(target) "
                    + "nextVideo=\(nextVideoInputSegmentIndex) "
                    + "nextAudio=\(nextAudioInputSegmentIndices) "
                    + "highestVideo=\(workerSnapshot.highestProducedVideoSegmentIndex) "
                    + "highestAudio=\(workerSnapshot.highestFinalizedAudioSegmentIndices) "
                    + "videoPackets=\(workerSnapshot.videoPacketCount) "
                    + "audioPackets=\(workerSnapshot.audioPacketCounts)",
                category: .session
            )
            throw HLSVODMediaPumpError
                .requestedSegmentUnavailable(target)
        }
    }

    private func requireAvailable(
        generation: UInt64? = nil
    ) throws {
        if let terminalError {
            throw terminalError
        }
        guard !isClosed else {
            throw HLSVODMediaPumpError.closed
        }
        if let generation,
           currentGeneration > generation
            || (
                requestedRestartGeneration
                    ?? generation
            ) > generation {
            throw HLSVODMediaPumpError
                .generationSuperseded(
                    generation: generation
                )
        }
    }

    private static func isWebVTT(_ data: Data) -> Bool {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes.removeFirst(3)
        }
        return bytes.starts(with: Data("WEBVTT".utf8))
    }

    private func performProduction(
        throughSegment target: Int,
        generation: UInt64
    ) async {
        do {
            try await runProduction(
                throughSegment: target,
                generation: generation
            )
        } catch {
            let typed = Self.typed(error)
            let superseded =
                Self.isSuperseded(
                    typed,
                    generation: generation,
                    currentGeneration:
                        currentGeneration,
                    requestedRestartGeneration:
                        requestedRestartGeneration
                )
            if !isClosed, !superseded {
                terminalError = typed
                worker.close()
                do {
                    try await loader.close()
                } catch {
                    EngineLog.emit(
                        "[HLSVODMediaPump] failure cleanup failed: "
                            + String(
                                describing: error
                            ),
                        category: .session
                    )
                }
            }
        }
        productionInProgress = false
        productionTask = nil
        resumeProductionWaiters()
    }

    private func waitForProduction() async throws {
        do {
            try Task.checkCancellation()
        } catch {
            throw HLSVODMediaPumpError.cancelled
        }
        await withCheckedContinuation {
            continuation in
            productionWaiters.append(continuation)
        }
        do {
            try Task.checkCancellation()
        } catch {
            throw HLSVODMediaPumpError.cancelled
        }
    }

    private func resumeProductionWaiters() {
        let waiters = productionWaiters
        productionWaiters.removeAll(
            keepingCapacity: true
        )
        waiters.forEach { $0.resume() }
    }

    private func requireRestartCurrent(
        _ generation: UInt64
    ) throws {
        try requireAvailable()
        guard requestedRestartGeneration
                == generation,
              currentGeneration
                < generation else {
            throw HLSVODMediaPumpError
                .generationSuperseded(
                    generation: generation
                )
        }
    }

    nonisolated private static func isSuperseded(
        _ error: HLSVODMediaPumpError,
        generation: UInt64,
        currentGeneration: UInt64,
        requestedRestartGeneration: UInt64?
    ) -> Bool {
        if case .generationSuperseded =
                error {
            return true
        }
        return currentGeneration > generation
            || (
                requestedRestartGeneration
                    ?? generation
            ) > generation
    }

    nonisolated private static func audioInputSegmentIndex(
        containing time: CMTime,
        segments: [HLSVODSegmentResource]
    ) throws -> Int {
        guard time.isValid,
              time.isNumeric,
              CMTimeCompare(time, .zero) >= 0,
              !segments.isEmpty else {
            throw HLSVODMediaPumpError
                .targetSegmentOutOfRange(0)
        }
        var start = CMTime.zero
        for segment in segments {
            let end = CMTimeAdd(
                start,
                segment.duration
            )
            if CMTimeCompare(time, end) < 0 {
                return segment.index
            }
            start = end
        }
        if CMTimeCompare(time, start) == 0,
           let last = segments.last {
            return last.index
        }
        throw HLSVODMediaPumpError
            .targetSegmentOutOfRange(
                segments.count
            )
    }

    nonisolated private static func typed(
        _ error: Error
    ) -> HLSVODMediaPumpError {
        if let typed = error as? HLSVODMediaPumpError {
            return typed
        }
        if let origin =
                error as? HLSVODOriginResourceError {
            return .origin(origin)
        }
        if error is CancellationError {
            return .cancelled
        }
        return .unexpected(
            reason: String(describing: error)
        )
    }
}

private extension HLSVODMediaPump {
    struct WorkerSnapshot {
        let highestProducedVideoSegmentIndex: Int
        let highestFinalizedAudioSegmentIndices:
            [Int]
        let videoPacketCount: Int
        let audioPacketCounts: [Int]
    }

    final class AudioRendition {
        let metadata: BlackCarrierAudioRenditionMetadata
        let descriptor:
            BlackCarrierAudioRenditionDescriptor
        let contract: HLSVODAudioStreamContract
        let cache: SegmentCache
        var writer:
            BlackCarrierAudioRenditionMuxer.Writer
        var summary:
            BlackCarrierAudioRenditionSummary?
        var packetCount = 0

        init(
            metadata: BlackCarrierAudioRenditionMetadata,
            descriptor:
                BlackCarrierAudioRenditionDescriptor,
            contract: HLSVODAudioStreamContract,
            cache: SegmentCache,
            writer:
                BlackCarrierAudioRenditionMuxer.Writer
        ) {
            self.metadata = metadata
            self.descriptor = descriptor
            self.contract = contract
            self.cache = cache
            self.writer = writer
        }
    }

    final class Worker: @unchecked Sendable {
        let renditionMetadata:
            [BlackCarrierAudioRenditionMetadata]
        let renditionDescriptors:
            [BlackCarrierAudioRenditionDescriptor]
        let hybridSubtitleContracts:
            [HybridSubtitleDecodeContract]
        let hybridSubtitlePacketStore = SubtitlePacketStore()
        let hybridSubtitleRuntimeAvailability =
            HybridSubtitleRuntimeAvailabilityStore()

        private let graph: HLSVODResourceGraph
        private let bridgeMode: AudioBridgeMode
        private let videoContract:
            HybridVideoStreamContract
        private let videoStreamIndex: Int32
        private let videoPacketSink: VideoPacketSink?
        private let videoDecodeSink:
            HybridVideoDecodeSink?
        private let audioRenditions: [AudioRendition]
        private let usesSeparateAudio: Bool
        private let overlaySourceTrackInfos: [TrackInfo]

        private var highestProducedVideoSegmentIndex =
            -1
        private var videoPacketCount = 0
        private var videoInputFinished = false
        private var isClosed = false

        init(
            graph: HLSVODResourceGraph,
            bridgeMode: AudioBridgeMode,
            videoInitData: Data?,
            firstVideoSegmentData: Data,
            audioInitData: [Data?],
            firstAudioSegmentData: [Data],
            videoPacketSink: VideoPacketSink?,
            decodedFrameHandler:
                HybridVideoDecodeSink.FrameHandler?,
            videoFailureHandler:
                HybridVideoDecodeSink.FailureHandler?,
            initialGeneration: UInt64
        ) throws {
            self.graph = graph
            self.bridgeMode = bridgeMode
            usesSeparateAudio =
                !graph.audioRenditions.isEmpty

            let videoDemuxer = try Self.openVideoDemuxer(
                initData: videoInitData,
                segmentData: firstVideoSegmentData
            )
            defer { videoDemuxer.close() }
            let videoStreams = try Self.streamIndices(
                demuxer: videoDemuxer,
                mediaType: AVMEDIA_TYPE_VIDEO
            )
            guard videoStreams.count == 1 else {
                throw HLSVODMediaPumpError
                    .videoStreamCount(
                        segmentIndex: 0,
                        count: videoStreams.count
                    )
            }
            videoStreamIndex = videoStreams[0]
            guard let videoStream = videoDemuxer.stream(
                at: videoStreamIndex
            ) else {
                throw HLSVODMediaPumpError
                    .videoStreamCount(
                        segmentIndex: 0,
                        count: 0
                    )
            }
            videoContract =
                try HybridVideoStreamContract(
                    demuxer: videoDemuxer,
                    stream: videoStream,
                    sourceStartPTSOverride: 0
                )
            self.videoPacketSink = videoPacketSink
            if let decodedFrameHandler {
                videoDecodeSink =
                    try HybridVideoDecodeSink(
                        demuxer: videoDemuxer,
                        initialGeneration:
                            initialGeneration,
                        sourceStartPTSOverride: 0,
                        onFrame: decodedFrameHandler,
                        onFailure:
                            videoFailureHandler
                    )
            } else {
                videoDecodeSink = nil
            }

            let overlaySourceTrackInfos = videoDemuxer
                .subtitleTrackInfos()
                .filter(Self.isHybridOverlaySubtitleTrack)
            let splitDisplaySetStreams = videoDemuxer
                .splitDisplaySetSubtitleStreamIndices()
            let sourceVideoWidth = max(
                1,
                videoStream.pointee.codecpar?.pointee.width
                    ?? 1_920
            )
            let sourceVideoHeight = max(
                1,
                videoStream.pointee.codecpar?.pointee.height
                    ?? 1_080
            )
            let subtitleContracts: [HybridSubtitleDecodeContract] =
                overlaySourceTrackInfos.compactMap {
                info in
                let streamIndex = Int32(info.id)
                guard let stream = videoDemuxer.stream(
                    at: streamIndex
                ) else { return nil }
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
                videoDecodeSink?.close()
                throw HLSVODMediaPumpError.invalidPreflight
            }
            self.overlaySourceTrackInfos = overlaySourceTrackInfos
            hybridSubtitleContracts = subtitleContracts

            if usesSeparateAudio {
                guard audioInitData.count
                        == graph.audioRenditions.count,
                      firstAudioSegmentData.count
                        == graph.audioRenditions.count else {
                    throw HLSVODMediaPumpError
                        .invalidPreflight
                }
                var prepared: [AudioRendition] = []
                do {
                    for rendition in
                            graph.audioRenditions {
                        let ordinal = rendition.ordinal
                        let demuxer =
                            try Self.openAudioDemuxer(
                                initData:
                                    audioInitData[ordinal],
                                segmentData:
                                    firstAudioSegmentData[
                                        ordinal
                                    ]
                            )
                        defer { demuxer.close() }
                        let videoStreams =
                            try Self.streamIndices(
                                demuxer: demuxer,
                                mediaType:
                                    AVMEDIA_TYPE_VIDEO
                            )
                        guard videoStreams.isEmpty else {
                            throw HLSVODMediaPumpError
                                .audioRenditionContainsVideo(
                                    renditionOrdinal:
                                        ordinal,
                                    inputSegmentIndex: 0
                                )
                        }
                        let audioStreams =
                            try Self.streamIndices(
                                demuxer: demuxer,
                                mediaType:
                                    AVMEDIA_TYPE_AUDIO
                            )
                        guard audioStreams.count == 1,
                              let stream =
                                demuxer.stream(
                                    at: audioStreams[0]
                                ) else {
                            throw HLSVODMediaPumpError
                                .audioStreamCount(
                                    renditionOrdinal:
                                        ordinal,
                                    inputSegmentIndex: 0,
                                    count:
                                        audioStreams.count
                                )
                        }
                        prepared.append(
                            try Self.makeRendition(
                                graph: graph,
                                metadata:
                                    BlackCarrierAudioRenditionMetadata(
                                        ordinal: ordinal,
                                        sourceTrackID:
                                            ordinal,
                                        language:
                                            rendition.language,
                                        name:
                                            rendition.name,
                                        isDefault:
                                            rendition.isDefault,
                                        isAutoselect:
                                            rendition.isAutoselect
                                    ),
                                demuxer: demuxer,
                                stream: stream,
                                streamIndex:
                                    audioStreams[0],
                                bridgeMode:
                                    bridgeMode,
                                declaredChannels:
                                    rendition.channels
                            )
                        )
                    }
                } catch {
                    prepared.forEach {
                        $0.cache.close()
                    }
                    videoDecodeSink?.close()
                    throw error
                }
                audioRenditions = prepared
            } else {
                let audioTracks =
                    videoDemuxer.audioTrackInfos()
                let metadata =
                    BlackCarrierCompositeProvider
                        .renditionMetadata(
                            for: audioTracks
                        )
                var prepared: [AudioRendition] = []
                do {
                    for (track, metadata) in zip(
                        audioTracks,
                        metadata
                    ) {
                        guard let stream =
                                videoDemuxer.stream(
                                    at: Int32(track.id)
                                ) else {
                            throw HLSVODMediaPumpError
                                .muxedAudioStreamCount(
                                    segmentIndex: 0,
                                    expected:
                                        audioTracks.count,
                                    actual:
                                        prepared.count
                                )
                        }
                        prepared.append(
                            try Self.makeRendition(
                                graph: graph,
                                metadata: metadata,
                                demuxer: videoDemuxer,
                                stream: stream,
                                streamIndex:
                                    Int32(track.id),
                                bridgeMode:
                                    bridgeMode,
                                declaredChannels: nil
                            )
                        )
                    }
                } catch {
                    prepared.forEach {
                        $0.cache.close()
                    }
                    videoDecodeSink?.close()
                    throw error
                }
                audioRenditions = prepared
            }
            renditionMetadata =
                audioRenditions.map(\.metadata)
            renditionDescriptors =
                audioRenditions.map(\.descriptor)
        }

        deinit {
            close()
        }

        var hybridVideoFormat: VideoFormat? {
            videoDecodeSink?
                .streamContract.videoFormat
        }

        var hybridDolbyVisionConfiguration:
            AetherDolbyVisionConfiguration?
        {
            videoDecodeSink?
                .streamContract
                .dolbyVisionConfiguration
        }

        var hybridVideoFrameRate: Double? {
            videoDecodeSink?
                .streamContract.displayFrameRate
        }

        var audioAnalysisContracts:
            [HLSVODAudioStreamContract]
        {
            audioRenditions.map(\.contract)
        }

        var isTargetFrameReady: Bool {
            videoDecodeSink?.isTargetFrameReady
                ?? true
        }

        func restart(
            generation: UInt64,
            targetTime: CMTime,
            segmentIndex: Int,
            videoInitData: Data?,
            videoSegmentData: Data,
            audioInitData: [Data?],
            audioInputSegmentIndices: [Int],
            audioSegmentData: [Data]
        ) throws {
            try requireOpen()
            guard graph.segments.indices
                    .contains(segmentIndex) else {
                throw HLSVODMediaPumpError
                    .targetSegmentOutOfRange(
                        segmentIndex
                    )
            }

            let videoDemuxer =
                try Self.openVideoDemuxer(
                    initData: videoInitData,
                    segmentData:
                        videoSegmentData
                )
            defer { videoDemuxer.close() }
            let videoStreams =
                try Self.streamIndices(
                    demuxer: videoDemuxer,
                    mediaType:
                        AVMEDIA_TYPE_VIDEO
                )
            guard videoStreams.count == 1,
                  let videoStream =
                    videoDemuxer.stream(
                        at: videoStreams[0]
                    ) else {
                throw HLSVODMediaPumpError
                    .videoStreamCount(
                        segmentIndex:
                            segmentIndex,
                        count: videoStreams.count
                    )
            }
            guard try HybridVideoStreamContract(
                demuxer: videoDemuxer,
                stream: videoStream,
                sourceStartPTSOverride: 0
            ) == videoContract else {
                throw HLSVODMediaPumpError
                    .videoContractChanged(
                        segmentIndex:
                            segmentIndex
                    )
            }

            let replacementWriters: [
                BlackCarrierAudioRenditionMuxer
                    .Writer
            ]
            if usesSeparateAudio {
                guard audioInitData.count
                        == audioRenditions.count,
                      audioInputSegmentIndices.count
                        == audioRenditions.count,
                      audioSegmentData.count
                        == audioRenditions.count else {
                    throw HLSVODMediaPumpError
                        .invalidPreflight
                }
                replacementWriters =
                    try audioRenditions.map {
                        rendition in
                        let ordinal =
                            rendition.metadata.ordinal
                        let inputSegmentIndex =
                            audioInputSegmentIndices[
                                ordinal
                            ]
                        let demuxer =
                            try Self.openAudioDemuxer(
                                initData:
                                    audioInitData[
                                        ordinal
                                    ],
                                segmentData:
                                    audioSegmentData[
                                        ordinal
                                    ]
                            )
                        defer { demuxer.close() }
                        let unexpectedVideo =
                            try Self.streamIndices(
                                demuxer: demuxer,
                                mediaType:
                                    AVMEDIA_TYPE_VIDEO
                            )
                        guard unexpectedVideo
                                .isEmpty else {
                            throw HLSVODMediaPumpError
                                .audioRenditionContainsVideo(
                                    renditionOrdinal:
                                        ordinal,
                                    inputSegmentIndex:
                                        inputSegmentIndex
                                )
                        }
                        let audioStreams =
                            try Self.streamIndices(
                                demuxer: demuxer,
                                mediaType:
                                    AVMEDIA_TYPE_AUDIO
                            )
                        guard audioStreams.count
                                == 1,
                              let stream =
                                demuxer.stream(
                                    at:
                                        audioStreams[
                                            0
                                        ]
                                ) else {
                            throw HLSVODMediaPumpError
                                .audioStreamCount(
                                    renditionOrdinal:
                                        ordinal,
                                    inputSegmentIndex:
                                        inputSegmentIndex,
                                    count:
                                        audioStreams.count
                                )
                        }
                        guard HLSVODAudioStreamContract(
                            stream: stream
                        ) == rendition.contract else {
                            throw HLSVODMediaPumpError
                                .audioContractChanged(
                                    renditionOrdinal:
                                        ordinal,
                                    inputSegmentIndex:
                                        inputSegmentIndex
                                )
                        }
                        return try Self
                            .makeReplacementWriter(
                                graph: graph,
                                rendition:
                                    rendition,
                                demuxer: demuxer,
                                streamIndex:
                                    audioStreams[0],
                                bridgeMode:
                                    bridgeMode,
                                sourceSegmentData:
                                    audioSegmentData[
                                        ordinal
                                    ],
                                sourceAudioStreamOrdinal:
                                    0,
                                requiresFragmentDecodeTime:
                                    audioInitData[
                                        ordinal
                                    ] != nil,
                                sourceSegmentStart:
                                    try Self.startTime(
                                        segments:
                                            graph
                                                .audioRenditions[
                                                    ordinal
                                                ]
                                                .segments,
                                        index:
                                            inputSegmentIndex
                                    ),
                                startingSegmentIndex:
                                    segmentIndex
                            )
                    }
            } else {
                guard audioInputSegmentIndices
                        .isEmpty,
                      audioSegmentData.isEmpty else {
                    throw HLSVODMediaPumpError
                        .invalidPreflight
                }
                let actualAudioStreams =
                    try Self.streamIndices(
                        demuxer: videoDemuxer,
                        mediaType:
                            AVMEDIA_TYPE_AUDIO
                    )
                guard actualAudioStreams.count
                        == audioRenditions.count else {
                    throw HLSVODMediaPumpError
                        .muxedAudioStreamCount(
                            segmentIndex:
                                segmentIndex,
                            expected:
                                audioRenditions.count,
                            actual:
                                actualAudioStreams.count
                        )
                }
                let actualMetadata =
                    BlackCarrierCompositeProvider
                        .renditionMetadata(
                            for:
                                videoDemuxer
                                    .audioTrackInfos()
                        )
                guard actualMetadata
                        == renditionMetadata else {
                    throw HLSVODMediaPumpError
                        .muxedAudioContractChanged(
                            ordinal: 0,
                            segmentIndex:
                                segmentIndex
                        )
                }
                replacementWriters =
                    try zip(
                        audioRenditions,
                        actualAudioStreams
                    ).map {
                        rendition,
                        streamIndex in
                        guard let stream =
                                videoDemuxer.stream(
                                    at: streamIndex
                                ),
                              HLSVODAudioStreamContract(
                                stream: stream
                              ) == rendition
                                .contract else {
                            throw HLSVODMediaPumpError
                                .muxedAudioContractChanged(
                                    ordinal:
                                        rendition
                                            .metadata
                                            .ordinal,
                                    segmentIndex:
                                        segmentIndex
                                )
                        }
                        return try Self
                            .makeReplacementWriter(
                                graph: graph,
                                rendition:
                                    rendition,
                                demuxer:
                                    videoDemuxer,
                                streamIndex:
                                    streamIndex,
                                bridgeMode:
                                    bridgeMode,
                                sourceSegmentData:
                                    videoSegmentData,
                                sourceAudioStreamOrdinal:
                                    rendition
                                        .metadata
                                        .ordinal,
                                requiresFragmentDecodeTime:
                                    videoInitData
                                        != nil,
                                sourceSegmentStart:
                                    graph.timeline
                                        .segments[
                                            segmentIndex
                                        ]
                                        .startTime,
                                startingSegmentIndex:
                                    segmentIndex
                            )
                    }
            }
            guard replacementWriters.map(
                \.descriptor
            ) == renditionDescriptors else {
                throw HLSVODMediaPumpError
                    .audioContractChanged(
                        renditionOrdinal: 0,
                        inputSegmentIndex:
                            segmentIndex
                    )
            }

            if let videoDecodeSink {
                do {
                    try videoDecodeSink
                        .beginGeneration(
                            generation,
                            targetTime:
                                targetTime,
                            restartDecodeAnchorTime:
                                nil,
                            demuxer:
                                videoDemuxer,
                            stream:
                                videoStream,
                            sourceStartPTSOverride:
                                0,
                            packetsAreNormalizedToSourceAxis:
                                true
                        )
                } catch {
                    throw HLSVODMediaPumpError
                        .videoSinkFailed(
                            reason:
                                String(
                                    describing: error
                                )
                        )
                }
            }

            for (rendition, replacement) in
                    zip(
                        audioRenditions,
                        replacementWriters
                    ) {
                rendition.writer = replacement
                rendition.summary = nil
            }
            highestProducedVideoSegmentIndex =
                segmentIndex - 1
            videoInputFinished = false
        }

        func consumeVideoSegment(
            index: Int,
            initData: Data?,
            segmentData: Data
        ) throws {
            try requireOpen()
            let demuxer = try Self.openVideoDemuxer(
                initData: initData,
                segmentData: segmentData
            )
            defer { demuxer.close() }
            let videoStreams = try Self.streamIndices(
                demuxer: demuxer,
                mediaType: AVMEDIA_TYPE_VIDEO
            )
            guard videoStreams.count == 1 else {
                throw HLSVODMediaPumpError
                    .videoStreamCount(
                        segmentIndex: index,
                        count: videoStreams.count
                    )
            }
            let actualVideoIndex = videoStreams[0]
            guard let actualVideoStream =
                    demuxer.stream(
                        at: actualVideoIndex
                    ),
                  try HybridVideoStreamContract(
                    demuxer: demuxer,
                    stream: actualVideoStream,
                    sourceStartPTSOverride: 0
                  ) == videoContract else {
                throw HLSVODMediaPumpError
                    .videoContractChanged(
                        segmentIndex: index
                    )
            }

            let actualAudioStreams =
                try Self.streamIndices(
                    demuxer: demuxer,
                    mediaType: AVMEDIA_TYPE_AUDIO
                )
            var muxedByStream: [
                Int32: AudioRendition
            ] = [:]
            let actualOverlayTracks = demuxer
                .subtitleTrackInfos()
                .filter(Self.isHybridOverlaySubtitleTrack)
            let subtitleContractsByStream:
                [Int32: HybridSubtitleDecodeContract]
            if actualOverlayTracks == overlaySourceTrackInfos {
                subtitleContractsByStream = Dictionary(
                    uniqueKeysWithValues: zip(
                        actualOverlayTracks,
                        hybridSubtitleContracts
                    ).map { info, contract in
                        (Int32(info.id), contract)
                    }
                )
            } else {
                subtitleContractsByStream = [:]
                for contract in hybridSubtitleContracts {
                    hybridSubtitleRuntimeAvailability.markUnavailable(
                        trackID: contract.track.id,
                        reason: .decodeFailed
                    )
                }
            }
            let splitDisplaySetStreams = demuxer
                .splitDisplaySetSubtitleStreamIndices()
            if !usesSeparateAudio {
                guard actualAudioStreams.count
                        == audioRenditions.count else {
                    throw HLSVODMediaPumpError
                        .muxedAudioStreamCount(
                            segmentIndex: index,
                            expected:
                                audioRenditions.count,
                            actual:
                                actualAudioStreams.count
                        )
                }
                let actualMetadata =
                    BlackCarrierCompositeProvider
                        .renditionMetadata(
                            for:
                                demuxer.audioTrackInfos()
                        )
                guard actualMetadata
                        == renditionMetadata else {
                    let mismatch =
                        zip(
                            actualMetadata,
                            renditionMetadata
                        )
                        .enumerated()
                        .first {
                            $0.element.0
                                != $0.element.1
                        }?
                        .offset
                        ?? min(
                            actualMetadata.count,
                            renditionMetadata.count
                        )
                    throw HLSVODMediaPumpError
                        .muxedAudioContractChanged(
                            ordinal: mismatch,
                            segmentIndex: index
                        )
                }
                for (ordinal, streamIndex) in
                        actualAudioStreams.enumerated() {
                    guard let stream =
                            demuxer.stream(
                                at: streamIndex
                            ),
                          HLSVODAudioStreamContract(
                            stream: stream
                          ) == audioRenditions[
                            ordinal
                          ].contract else {
                        throw HLSVODMediaPumpError
                            .muxedAudioContractChanged(
                                ordinal: ordinal,
                                segmentIndex: index
                            )
                    }
                    muxedByStream[streamIndex] =
                        audioRenditions[ordinal]
                }
            }

            var videoPackets = 0
            var audioPackets = Array(
                repeating: 0,
                count: audioRenditions.count
            )
            do {
                while let packet =
                        try demuxer.readPacket() {
                    var packetToFree:
                        UnsafeMutablePointer<AVPacket>? =
                            packet
                    defer {
                        trackedPacketFree(
                            &packetToFree
                        )
                    }
                    let streamIndex =
                        packet.pointee.stream_index
                    if streamIndex
                            == actualVideoIndex {
                        try Self.normalize(
                            packet: packet,
                            demuxer: demuxer,
                            streamIndex:
                                actualVideoIndex,
                            outputStreamIndex:
                                videoStreamIndex,
                            segmentStart:
                                graph.timeline.segments[
                                    index
                                ].startTime,
                            segmentIndex: index
                        )
                        do {
                            if let videoPacketSink {
                                try videoPacketSink(
                                    packet
                                )
                            }
                            if let videoDecodeSink {
                                try videoDecodeSink
                                    .consume(packet)
                            }
                        } catch {
                            throw HLSVODMediaPumpError
                                .videoSinkFailed(
                                    reason:
                                        String(
                                            describing:
                                                error
                                        )
                                )
                        }
                        videoPackets += 1
                    } else if let rendition =
                                muxedByStream[
                                    streamIndex
                                ] {
                        let ordinal =
                            rendition.metadata.ordinal
                        try Self.normalize(
                            packet: packet,
                            demuxer: demuxer,
                            streamIndex:
                                streamIndex,
                            outputStreamIndex:
                                rendition.writer
                                    .sourceStreamIndex,
                            segmentStart:
                                graph.timeline.segments[
                                    index
                                ].startTime,
                            segmentIndex: index
                        )
                        try Self.consume(
                            packet: packet,
                            rendition: rendition
                        )
                        audioPackets[ordinal] += 1
                    } else if let contract =
                                subtitleContractsByStream[
                                    streamIndex
                                ],
                              let stream = demuxer.stream(
                                at: streamIndex
                              ) {
                        do {
                            let assembles = splitDisplaySetStreams
                                .contains(streamIndex)
                            if packet.pointee.pts != Int64.min
                                || packet.pointee.dts != Int64.min {
                                try Self.normalize(
                                    packet: packet,
                                    demuxer: demuxer,
                                    streamIndex: streamIndex,
                                    outputStreamIndex:
                                        contract.packetStreamID,
                                    segmentStart:
                                        graph.timeline.segments[
                                            index
                                        ].startTime,
                                    segmentIndex: index
                                )
                            } else {
                                packet.pointee.stream_index =
                                    contract.packetStreamID
                            }
                            hybridSubtitlePacketStore.harvest(
                                streamIndex:
                                    contract.packetStreamID,
                                packet: packet,
                                timeBase:
                                    stream.pointee.time_base,
                                assembleSplitDisplaySets:
                                    assembles
                            )
                        } catch {
                            hybridSubtitleRuntimeAvailability
                                .markUnavailable(
                                    trackID: contract.track.id,
                                    reason: .decodeFailed
                                )
                        }
                    }
                }
            } catch let error
                    as HLSVODMediaPumpError {
                throw error
            } catch {
                throw HLSVODMediaPumpError
                    .packetReadFailed
            }
            guard videoPackets > 0 else {
                throw HLSVODMediaPumpError
                    .videoPacketMissing(
                        segmentIndex: index
                    )
            }
            if !usesSeparateAudio {
                for ordinal in audioRenditions.indices
                where audioPackets[ordinal] == 0 {
                    throw HLSVODMediaPumpError
                        .muxedAudioPacketMissing(
                            ordinal: ordinal,
                            segmentIndex: index
                        )
                }
            }
            highestProducedVideoSegmentIndex =
                max(
                    highestProducedVideoSegmentIndex,
                    index
                )
            videoPacketCount += videoPackets
        }

        func consumeAudioSegment(
            renditionOrdinal: Int,
            inputSegmentIndex: Int,
            initData: Data?,
            segmentData: Data
        ) throws {
            try requireOpen()
            guard audioRenditions.indices
                .contains(renditionOrdinal),
                  graph.audioRenditions.indices
                    .contains(renditionOrdinal) else {
                throw HLSVODMediaPumpError
                    .invalidPreflight
            }
            let demuxer = try Self.openAudioDemuxer(
                initData: initData,
                segmentData: segmentData
            )
            defer { demuxer.close() }
            let videoStreams = try Self.streamIndices(
                demuxer: demuxer,
                mediaType: AVMEDIA_TYPE_VIDEO
            )
            guard videoStreams.isEmpty else {
                throw HLSVODMediaPumpError
                    .audioRenditionContainsVideo(
                        renditionOrdinal:
                            renditionOrdinal,
                        inputSegmentIndex:
                            inputSegmentIndex
                    )
            }
            let audioStreams = try Self.streamIndices(
                demuxer: demuxer,
                mediaType: AVMEDIA_TYPE_AUDIO
            )
            guard audioStreams.count == 1,
                  let stream = demuxer.stream(
                    at: audioStreams[0]
                  ) else {
                throw HLSVODMediaPumpError
                    .audioStreamCount(
                        renditionOrdinal:
                            renditionOrdinal,
                        inputSegmentIndex:
                            inputSegmentIndex,
                        count: audioStreams.count
                    )
            }
            let rendition =
                audioRenditions[renditionOrdinal]
            guard HLSVODAudioStreamContract(stream: stream)
                    == rendition.contract else {
                throw HLSVODMediaPumpError
                    .audioContractChanged(
                        renditionOrdinal:
                            renditionOrdinal,
                        inputSegmentIndex:
                            inputSegmentIndex
                    )
            }
            let segmentStart = try Self.startTime(
                segments:
                    graph.audioRenditions[
                        renditionOrdinal
                    ].segments,
                index: inputSegmentIndex
            )
            var packetCount = 0
            do {
                while let packet =
                        try demuxer.readPacket() {
                    var packetToFree:
                        UnsafeMutablePointer<AVPacket>? =
                            packet
                    defer {
                        trackedPacketFree(
                            &packetToFree
                        )
                    }
                    guard packet.pointee.stream_index
                        == audioStreams[0] else {
                        continue
                    }
                    try Self.normalize(
                        packet: packet,
                        demuxer: demuxer,
                        streamIndex: audioStreams[0],
                        outputStreamIndex:
                            rendition.writer
                                .sourceStreamIndex,
                        segmentStart: segmentStart,
                        segmentIndex:
                            inputSegmentIndex
                    )
                    try Self.consume(
                        packet: packet,
                        rendition: rendition
                    )
                    packetCount += 1
                }
            } catch let error
                    as HLSVODMediaPumpError {
                throw error
            } catch {
                throw HLSVODMediaPumpError
                    .packetReadFailed
            }
            guard packetCount > 0 else {
                throw HLSVODMediaPumpError
                    .audioPacketMissing(
                        renditionOrdinal:
                            renditionOrdinal,
                        inputSegmentIndex:
                            inputSegmentIndex
                    )
            }
        }

        func finishVideoInput() throws {
            guard !videoInputFinished else { return }
            videoInputFinished = true
            if let videoDecodeSink {
                do {
                    try videoDecodeSink
                        .markEndOfStream()
                } catch {
                    throw HLSVODMediaPumpError
                        .videoSinkFailed(
                            reason:
                                String(
                                    describing: error
                                )
                        )
                }
            }
            if !usesSeparateAudio {
                for rendition in audioRenditions {
                    try finish(rendition)
                }
            }
        }

        func finishAudioInput(
            renditionOrdinal: Int
        ) throws {
            guard usesSeparateAudio,
                  audioRenditions.indices
                    .contains(renditionOrdinal) else {
                return
            }
            try finish(
                audioRenditions[renditionOrdinal]
            )
        }

        func hasProduced(segment index: Int) -> Bool {
            guard highestProducedVideoSegmentIndex
                    >= index else {
                return false
            }
            return audioRenditions.allSatisfy {
                $0.writer
                    .highestFinalizedSegmentIndex
                    >= index
                    && $0.cache.peekURL(
                        index: index
                    ) != nil
            }
        }

        func cachedSegmentExists(
            _ index: Int
        ) -> Bool {
            audioRenditions.allSatisfy {
                $0.cache.peekURL(index: index)
                    != nil
            }
        }

        func muxedAudioNeedsInput(
            throughSegment index: Int
        ) -> Bool {
            guard !usesSeparateAudio else {
                return false
            }
            return audioRenditions.contains {
                $0.writer
                    .highestFinalizedSegmentIndex
                    < index
            }
        }

        func audioNeedsInput(
            renditionOrdinal: Int,
            throughSegment index: Int
        ) -> Bool {
            guard usesSeparateAudio,
                  audioRenditions.indices
                    .contains(renditionOrdinal) else {
                return false
            }
            return audioRenditions[
                renditionOrdinal
            ].writer.highestFinalizedSegmentIndex
                < index
        }

        func audioInitSegment(
            renditionOrdinal: Int
        ) -> Data? {
            guard audioRenditions.indices
                .contains(renditionOrdinal) else {
                return nil
            }
            return audioRenditions[
                renditionOrdinal
            ].cache.fetchInit(timeout: 0)
        }

        func audioMediaSegmentURL(
            renditionOrdinal: Int,
            segmentIndex: Int
        ) -> URL? {
            guard audioRenditions.indices
                .contains(renditionOrdinal) else {
                return nil
            }
            return audioRenditions[
                renditionOrdinal
            ].cache.peekURL(index: segmentIndex)
        }

        func audioMediaSegment(
            renditionOrdinal: Int,
            segmentIndex: Int
        ) -> Data? {
            guard audioRenditions.indices
                .contains(renditionOrdinal) else {
                return nil
            }
            return audioRenditions[
                renditionOrdinal
            ].cache.peek(index: segmentIndex)
        }

        func audioSummaries()
            -> [BlackCarrierAudioRenditionSummary]?
        {
            let summaries =
                audioRenditions.compactMap(\.summary)
            guard summaries.count
                    == audioRenditions.count else {
                return nil
            }
            return summaries
        }

        func advanceVideoDecodeDemand(
            to time: CMTime
        ) throws {
            try videoDecodeSink?
                .advanceDecodeDemand(to: time)
        }

        func snapshot() -> WorkerSnapshot {
            WorkerSnapshot(
                highestProducedVideoSegmentIndex:
                    highestProducedVideoSegmentIndex,
                highestFinalizedAudioSegmentIndices:
                    audioRenditions.map {
                        $0.writer
                            .highestFinalizedSegmentIndex
                    },
                videoPacketCount:
                    videoPacketCount,
                audioPacketCounts:
                    audioRenditions.map(
                        \.packetCount
                    )
            )
        }

        func observedAudioBandwidthSegmentSamples()
            -> [[BlackCarrierBandwidthSegmentSample]]
        {
            audioRenditions.map {
                $0.writer
                    .observedBandwidthSegmentSamples
            }
        }

        func close() {
            guard !isClosed else { return }
            isClosed = true
            audioRenditions.forEach {
                $0.cache.close()
            }
            videoDecodeSink?.close()
        }

        private func requireOpen() throws {
            guard !isClosed else {
                throw HLSVODMediaPumpError.closed
            }
        }

        private func finish(
            _ rendition: AudioRendition
        ) throws {
            guard rendition.summary == nil else {
                return
            }
            do {
                rendition.summary =
                    try rendition.writer.finish()
            } catch let error
                    as BlackCarrierAudioRenditionMuxerError {
                throw HLSVODMediaPumpError
                    .audioMuxerFailed(
                        renditionOrdinal:
                            rendition.metadata.ordinal,
                        error: error
                    )
            } catch let error
                    as BlackCarrierAudioRenditionStoreError {
                throw HLSVODMediaPumpError
                    .audioStoreFailed(
                        renditionOrdinal:
                            rendition.metadata.ordinal,
                        error: error
                    )
            }
        }

        private static func consume(
            packet: UnsafeMutablePointer<AVPacket>,
            rendition: AudioRendition
        ) throws {
            do {
                try rendition.writer.consume(packet)
                rendition.packetCount += 1
            } catch let error
                    as BlackCarrierAudioRenditionMuxerError {
                throw HLSVODMediaPumpError
                    .audioMuxerFailed(
                        renditionOrdinal:
                            rendition.metadata.ordinal,
                        error: error
                    )
            } catch let error
                    as BlackCarrierAudioRenditionStoreError {
                throw HLSVODMediaPumpError
                    .audioStoreFailed(
                        renditionOrdinal:
                            rendition.metadata.ordinal,
                        error: error
                    )
            }
        }

        private static func makeRendition(
            graph: HLSVODResourceGraph,
            metadata: BlackCarrierAudioRenditionMetadata,
            demuxer: Demuxer,
            stream: UnsafeMutablePointer<AVStream>,
            streamIndex: Int32,
            bridgeMode: AudioBridgeMode,
            declaredChannels: String?
        ) throws -> AudioRendition {
            let descriptor =
                try BlackCarrierAudioRenditionMuxer
                    .admissionDescriptor(
                        demuxer: demuxer,
                        audioStreamIndex:
                            streamIndex,
                        bridgeMode: bridgeMode
                    )
            if let declaredChannels,
               declaredChannels
                != descriptor.channelsAttribute {
                throw HLSVODMediaPumpError
                    .audioContractChanged(
                        renditionOrdinal:
                            metadata.ordinal,
                        inputSegmentIndex: 0
                    )
            }
            let cache = SegmentCache(
                forwardWindow:
                    max(1, graph.segments.count),
                backwardWindow:
                    max(1, graph.segments.count)
            )
            do {
                let writer =
                    try BlackCarrierAudioRenditionMuxer
                        .makeWriter(
                            demuxer: demuxer,
                            audioStreamIndex:
                                streamIndex,
                            sourceStartPTS: 0,
                            timeline: graph.timeline,
                            bridgeMode: bridgeMode,
                            sessionDirectory:
                                cache.sessionDir,
                            onInit: {
                                if cache.fetchInit(
                                    timeout: 0
                                ) == nil {
                                    cache.setInit($0)
                                }
                            },
                            onSegment: {
                                timing,
                                stagingPath,
                                bytesWritten in
                                cache.adopt(
                                    index: timing.index,
                                    stagingPath:
                                        stagingPath,
                                    byteCount:
                                        bytesWritten
                                )
                                guard cache.peekURL(
                                    index: timing.index
                                ) != nil else {
                                    throw BlackCarrierAudioRenditionStoreError
                                        .segmentStoreFailed(
                                            trackID:
                                                metadata
                                                    .sourceTrackID,
                                            index:
                                                timing.index
                                        )
                                }
                            }
                        )
                guard writer.descriptor
                        == descriptor else {
                    cache.close()
                    throw HLSVODMediaPumpError
                        .audioContractChanged(
                            renditionOrdinal:
                                metadata.ordinal,
                            inputSegmentIndex: 0
                        )
                }
                return AudioRendition(
                    metadata: metadata,
                    descriptor: descriptor,
                    contract:
                        HLSVODAudioStreamContract(
                            stream: stream
                        ),
                    cache: cache,
                    writer: writer
                )
            } catch {
                cache.close()
                throw error
            }
        }

        private static func makeReplacementWriter(
            graph: HLSVODResourceGraph,
            rendition: AudioRendition,
            demuxer: Demuxer,
            streamIndex: Int32,
            bridgeMode: AudioBridgeMode,
            sourceSegmentData: Data,
            sourceAudioStreamOrdinal: Int,
            requiresFragmentDecodeTime: Bool,
            sourceSegmentStart: CMTime,
            startingSegmentIndex: Int
        ) throws
            -> BlackCarrierAudioRenditionMuxer
                .Writer
        {
            guard let timelineOffset =
                    rendition.writer
                        .presentationTimelineOffset else {
                throw HLSVODMediaPumpError
                    .restartTimelineOffsetUnavailable(
                        renditionOrdinal:
                            rendition.metadata.ordinal
                    )
            }
            guard let stream =
                    demuxer.stream(
                        at: streamIndex
                    ),
                  let globalSourceStart =
                    BlackCarrierSourceAxis
                        .streamTicks(
                            for:
                                sourceSegmentStart,
                            timeBase:
                                stream.pointee
                                    .time_base
                        ) else {
                throw HLSVODMediaPumpError
                    .timestampOverflow(
                        streamIndex:
                            Int(streamIndex),
                        segmentIndex:
                            startingSegmentIndex
                    )
            }
            let sourceDecodeTimestamp =
                try restartSourceDecodeTimestamp(
                    segmentData:
                        sourceSegmentData,
                    requiresFragmentDecodeTime:
                        requiresFragmentDecodeTime,
                    demuxer: demuxer,
                    streamIndex: streamIndex,
                    sourceAudioStreamOrdinal:
                        sourceAudioStreamOrdinal,
                    renditionOrdinal:
                        rendition.metadata.ordinal,
                    segmentIndex:
                        startingSegmentIndex
                )
            let decodeDelta =
                sourceDecodeTimestamp
                    .subtractingReportingOverflow(
                        globalSourceStart
                    )
            guard !decodeDelta.overflow else {
                throw HLSVODMediaPumpError
                    .timestampOverflow(
                        streamIndex:
                            Int(streamIndex),
                        segmentIndex:
                            startingSegmentIndex
                    )
            }
            let decodeTimestampOffset =
                try rendition.writer
                    .restartDecodeTimestampOffset(
                        sourceDecodeDelta:
                            decodeDelta.partialValue,
                        sourceTimeBase:
                            stream.pointee.time_base
                    )
            let writer =
                try BlackCarrierAudioRenditionMuxer
                    .makeWriter(
                        demuxer: demuxer,
                        audioStreamIndex:
                            streamIndex,
                        sourceStartPTS: 0,
                        timeline: graph.timeline,
                        bridgeMode: bridgeMode,
                        startingSegmentIndex:
                            startingSegmentIndex,
                        preserveEncoderPriming:
                            false,
                        presentationTimelineOffset:
                            timelineOffset,
                        decodeTimestampOffset:
                            decodeTimestampOffset,
                        restartTimestampRebaseEnabled:
                            false,
                        sessionDirectory:
                            rendition.cache
                                .sessionDir,
                        onInit: {
                            if rendition.cache
                                .fetchInit(
                                    timeout: 0
                                ) == nil {
                                rendition.cache
                                    .setInit($0)
                            }
                        },
                        onSegment: {
                            timing,
                            stagingPath,
                            bytesWritten in
                            rendition.cache.adopt(
                                index:
                                    timing.index,
                                stagingPath:
                                    stagingPath,
                                byteCount:
                                    bytesWritten
                            )
                            guard rendition.cache
                                    .peekURL(
                                        index:
                                            timing.index
                                    ) != nil else {
                                throw BlackCarrierAudioRenditionStoreError
                                    .segmentStoreFailed(
                                        trackID:
                                            rendition
                                                .metadata
                                                .sourceTrackID,
                                        index:
                                            timing.index
                                    )
                            }
                        }
                    )
            guard writer.descriptor
                    == rendition.descriptor else {
                throw HLSVODMediaPumpError
                    .audioContractChanged(
                        renditionOrdinal:
                            rendition.metadata.ordinal,
                        inputSegmentIndex:
                            startingSegmentIndex
                    )
            }
            return writer
        }

        private static func restartSourceDecodeTimestamp(
            segmentData: Data,
            requiresFragmentDecodeTime: Bool,
            demuxer: Demuxer,
            streamIndex: Int32,
            sourceAudioStreamOrdinal: Int,
            renditionOrdinal: Int,
            segmentIndex: Int
        ) throws -> Int64 {
            if requiresFragmentDecodeTime {
                let fragmentDecodeTimes =
                    try fragmentDecodeTimes(
                        segmentData
                    )
                guard let stream =
                        demuxer.stream(
                            at: streamIndex
                        ) else {
                    throw HLSVODMediaPumpError
                        .demuxOpenFailed
                }
                let trackID =
                    UInt32(
                        bitPattern:
                            stream.pointee.id
                    )
                guard let decodeTime =
                        fragmentDecodeTimes[
                            trackID
                        ],
                      decodeTime
                        <= UInt64(Int64.max) else {
                    throw HLSVODMediaPumpError
                        .fragmentDecodeTimeMissing(
                            trackID: trackID,
                            segmentIndex:
                                segmentIndex
                        )
                }
                return Int64(decodeTime)
            }

            let packetDemuxer =
                try openAudioDemuxer(
                    initData: nil,
                    segmentData: segmentData
                )
            defer { packetDemuxer.close() }
            let audioStreams =
                try streamIndices(
                    demuxer: packetDemuxer,
                    mediaType:
                        AVMEDIA_TYPE_AUDIO
                )
            guard audioStreams.indices.contains(
                sourceAudioStreamOrdinal
            ) else {
                throw HLSVODMediaPumpError
                    .audioStreamCount(
                        renditionOrdinal:
                            renditionOrdinal,
                        inputSegmentIndex:
                            segmentIndex,
                        count: audioStreams.count
                    )
            }
            let packetStreamIndex =
                audioStreams[
                    sourceAudioStreamOrdinal
                ]
            while let packet =
                    try packetDemuxer
                        .readPacket() {
                var packetToFree:
                    UnsafeMutablePointer<AVPacket>? =
                        packet
                defer {
                    trackedPacketFree(
                        &packetToFree
                    )
                }
                guard packet.pointee
                    .stream_index
                        == packetStreamIndex else {
                    continue
                }
                let timestamp =
                    packet.pointee.dts
                        != Int64.min
                    ? packet.pointee.dts
                    : packet.pointee.pts
                guard timestamp != Int64.min else {
                    throw HLSVODMediaPumpError
                        .timestampMissing(
                            streamIndex:
                                Int(streamIndex),
                            segmentIndex:
                                segmentIndex
                        )
                }
                return timestamp
            }
            throw HLSVODMediaPumpError
                .audioPacketMissing(
                    renditionOrdinal:
                        renditionOrdinal,
                    inputSegmentIndex:
                        segmentIndex
                )
        }

        private static func fragmentDecodeTimes(
            _ data: Data
        ) throws -> [UInt32: UInt64] {
            let topLevel = try bmffBoxes(
                in: data,
                range: 0..<data.count
            )
            let moofs = topLevel.filter {
                $0.type == "moof"
            }
            guard !moofs.isEmpty else {
                return [:]
            }
            var result: [UInt32: UInt64] =
                [:]
            for moof in moofs {
                let trafs = try bmffBoxes(
                    in: data,
                    range: moof.body
                ).filter {
                    $0.type == "traf"
                }
                for traf in trafs {
                    let children =
                        try bmffBoxes(
                            in: data,
                            range: traf.body
                        )
                    guard let tfhd =
                            children.first(
                                where: {
                                    $0.type == "tfhd"
                                }
                            ),
                          let tfdt =
                            children.first(
                                where: {
                                    $0.type == "tfdt"
                                }
                            ),
                          tfhd.body.count >= 8,
                          tfdt.body.count >= 8 else {
                        throw HLSVODMediaPumpError
                            .demuxOpenFailed
                    }
                    let trackID = try readUInt32(
                        data,
                        at:
                            tfhd.body.lowerBound
                                + 4
                    )
                    let version =
                        data[tfdt.body.lowerBound]
                    let decodeTime: UInt64
                    if version == 1 {
                        guard tfdt.body.count
                                >= 12 else {
                            throw HLSVODMediaPumpError
                                .demuxOpenFailed
                        }
                        decodeTime =
                            try readUInt64(
                                data,
                                at:
                                    tfdt.body
                                        .lowerBound
                                        + 4
                            )
                    } else if version == 0 {
                        decodeTime = UInt64(
                            try readUInt32(
                                data,
                                at:
                                    tfdt.body
                                        .lowerBound
                                        + 4
                            )
                        )
                    } else {
                        throw HLSVODMediaPumpError
                            .demuxOpenFailed
                    }
                    guard result[trackID] == nil else {
                        throw HLSVODMediaPumpError
                            .demuxOpenFailed
                    }
                    result[trackID] =
                        decodeTime
                }
            }
            return result
        }

        private static func bmffBoxes(
            in data: Data,
            range: Range<Int>
        ) throws -> [
            (type: String, body: Range<Int>)
        ] {
            var boxes: [
                (type: String, body: Range<Int>)
            ] = []
            var offset = range.lowerBound
            while offset < range.upperBound {
                guard offset + 8
                        <= range.upperBound else {
                    throw HLSVODMediaPumpError
                        .demuxOpenFailed
                }
                let size32 =
                    try readUInt32(
                        data,
                        at: offset
                    )
                let typeData =
                    data[
                        (offset + 4)..<(offset + 8)
                    ]
                guard let type = String(
                    data: typeData,
                    encoding: .ascii
                ) else {
                    throw HLSVODMediaPumpError
                        .demuxOpenFailed
                }
                let headerSize: Int
                let size: UInt64
                if size32 == 1 {
                    guard offset + 16
                            <= range.upperBound else {
                        throw HLSVODMediaPumpError
                            .demuxOpenFailed
                    }
                    headerSize = 16
                    size = try readUInt64(
                        data,
                        at: offset + 8
                    )
                } else if size32 == 0 {
                    headerSize = 8
                    size = UInt64(
                        range.upperBound
                            - offset
                    )
                } else {
                    headerSize = 8
                    size = UInt64(size32)
                }
                guard size
                        >= UInt64(headerSize),
                      size
                        <= UInt64(
                            range.upperBound
                                - offset
                        ) else {
                    throw HLSVODMediaPumpError
                        .demuxOpenFailed
                }
                let end = offset + Int(size)
                boxes.append(
                    (
                        type,
                        (offset + headerSize)..<end
                    )
                )
                offset = end
            }
            return boxes
        }

        private static func readUInt32(
            _ data: Data,
            at offset: Int
        ) throws -> UInt32 {
            guard offset >= 0,
                  offset + 4 <= data.count else {
                throw HLSVODMediaPumpError
                    .demuxOpenFailed
            }
            return data.withUnsafeBytes {
                UInt32(
                    bigEndian:
                        $0.loadUnaligned(
                            fromByteOffset:
                                offset,
                            as: UInt32.self
                        )
                )
            }
        }

        private static func readUInt64(
            _ data: Data,
            at offset: Int
        ) throws -> UInt64 {
            guard offset >= 0,
                  offset + 8 <= data.count else {
                throw HLSVODMediaPumpError
                    .demuxOpenFailed
            }
            return data.withUnsafeBytes {
                UInt64(
                    bigEndian:
                        $0.loadUnaligned(
                            fromByteOffset:
                                offset,
                            as: UInt64.self
                        )
                )
            }
        }

        private static func openVideoDemuxer(
            initData: Data?,
            segmentData: Data
        ) throws -> Demuxer {
            let data: Data
            let formatHint: String
            if let initData {
                data = initData + segmentData
                formatHint = "mp4"
            } else {
                data = segmentData
                formatHint = "mpegts"
            }
            return try openDemuxer(
                data: data,
                formatHint: formatHint
            )
        }

        private static func openAudioDemuxer(
            initData: Data?,
            segmentData: Data
        ) throws -> Demuxer {
            let data: Data
            let formatHint: String?
            if let initData {
                data = initData + segmentData
                formatHint = "mp4"
            } else {
                data = segmentData
                formatHint =
                    LiveSegmentFormat.classify(
                        segmentData
                    ) == .mpegts
                    ? "mpegts"
                    : nil
            }
            return try openDemuxer(
                data: data,
                formatHint: formatHint
            )
        }

        private static func openDemuxer(
            data: Data,
            formatHint: String?
        ) throws -> Demuxer {
            let demuxer = Demuxer()
            do {
                try demuxer.open(
                    reader: DataIOReader(data: data),
                    formatHint: formatHint
                )
                return demuxer
            } catch {
                demuxer.close()
                throw HLSVODMediaPumpError
                    .demuxOpenFailed
            }
        }

        private static func streamIndices(
            demuxer: Demuxer,
            mediaType: AVMediaType
        ) throws -> [Int32] {
            var indices: [Int32] = []
            for index in 0..<demuxer.streamCount {
                guard let stream = demuxer.stream(
                    at: Int32(index)
                ) else {
                    continue
                }
                let parameters =
                    stream.pointee.codecpar!
                guard parameters.pointee.codec_type
                    == mediaType else {
                    continue
                }
                guard parameters.pointee.codec_id
                        != AV_CODEC_ID_NONE,
                      stream.pointee.time_base.num > 0,
                      stream.pointee.time_base.den
                        > 0 else {
                    throw HLSVODMediaPumpError
                        .demuxOpenFailed
                }
                indices.append(Int32(index))
            }
            return indices
        }

        private static func isHybridOverlaySubtitleTrack(
            _ info: TrackInfo
        ) -> Bool {
            AetherEngine.isBitmapSubtitleCodec(info.codec)
                || info.codec == "ass"
                || info.codec == "ssa"
        }

        private static func normalize(
            packet: UnsafeMutablePointer<AVPacket>,
            demuxer: Demuxer,
            streamIndex: Int32,
            outputStreamIndex: Int32,
            segmentStart: CMTime,
            segmentIndex: Int
        ) throws {
            guard let stream = demuxer.stream(
                at: streamIndex
            ) else {
                throw HLSVODMediaPumpError
                    .demuxOpenFailed
            }
            let localStart =
                BlackCarrierSourceAxis.sourceStartPTS(
                    demuxer: demuxer,
                    streamIndex: streamIndex
                )
            guard let globalStart =
                    BlackCarrierSourceAxis.streamTicks(
                        for: segmentStart,
                        timeBase:
                            stream.pointee.time_base
                    ) else {
                throw HLSVODMediaPumpError
                    .timestampOverflow(
                        streamIndex:
                            Int(streamIndex),
                        segmentIndex:
                            segmentIndex
                    )
            }
            if packet.pointee.pts == Int64.min,
               packet.pointee.dts == Int64.min {
                throw HLSVODMediaPumpError
                    .timestampMissing(
                        streamIndex:
                            Int(streamIndex),
                        segmentIndex:
                            segmentIndex
                    )
            }
            if packet.pointee.pts != Int64.min {
                packet.pointee.pts = try normalized(
                    packet.pointee.pts,
                    localStart: localStart,
                    globalStart: globalStart,
                    streamIndex: streamIndex,
                    segmentIndex: segmentIndex
                )
            }
            if packet.pointee.dts != Int64.min {
                packet.pointee.dts = try normalized(
                    packet.pointee.dts,
                    localStart: localStart,
                    globalStart: globalStart,
                    streamIndex: streamIndex,
                    segmentIndex: segmentIndex
                )
            }
            packet.pointee.stream_index =
                outputStreamIndex
            packet.pointee.pos = -1
        }

        private static func normalized(
            _ timestamp: Int64,
            localStart: Int64,
            globalStart: Int64,
            streamIndex: Int32,
            segmentIndex: Int
        ) throws -> Int64 {
            let local = timestamp
                .subtractingReportingOverflow(
                    localStart
                )
            let global = local.partialValue
                .addingReportingOverflow(globalStart)
            guard !local.overflow, !global.overflow else {
                throw HLSVODMediaPumpError
                    .timestampOverflow(
                        streamIndex:
                            Int(streamIndex),
                        segmentIndex:
                            segmentIndex
                    )
            }
            return global.partialValue
        }

        private static func startTime(
            segments: [HLSVODSegmentResource],
            index: Int
        ) throws -> CMTime {
            guard segments.indices.contains(index) else {
                throw HLSVODMediaPumpError
                    .targetSegmentOutOfRange(index)
            }
            var ticks: CMTimeValue = 0
            for segment in segments.prefix(index) {
                let addition =
                    ticks.addingReportingOverflow(
                        segment.duration.value
                    )
                guard !addition.overflow else {
                    throw HLSVODMediaPumpError
                        .timestampOverflow(
                            streamIndex: 0,
                            segmentIndex: index
                        )
                }
                ticks = addition.partialValue
            }
            return CMTime(
                value: ticks,
                timescale:
                    BlackCarrierProfile.approved
                        .timescale
            )
        }
    }
}
