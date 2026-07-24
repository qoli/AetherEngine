import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import AetherEngine

private enum HybridPlaybackSessionFixtureError: Error {
    case pixelBufferCreationFailed
}

private extension HybridPlaybackSeekResult {
    var isSuperseded: Bool {
        if case .superseded = self {
            return true
        }
        return false
    }
}

@MainActor
private final class HybridTelemetryTriggerRecorder {
    private(set) var values:
        [HybridPlaybackTelemetryTrigger] = []

    func record(_ value: HybridPlaybackTelemetryTrigger) {
        values.append(value)
    }

    func removeAll() {
        values.removeAll()
    }
}

@MainActor
private final class HybridPresentationContractState {
    var isValid = true
}

private func makeHybridPlaybackSessionFrame(
    time: Double,
    duration: Double = 1,
    generation: UInt64,
    videoFormat: VideoFormat = .sdr,
    hdr10PlusT35: Data? = nil
) throws -> DecodedVideoFrame {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        16,
        16,
        videoFormat == .sdr
            ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        [
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
        ] as CFDictionary,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw HybridPlaybackSessionFixtureError
            .pixelBufferCreationFailed
    }
    if videoFormat == .hdr10 || videoFormat == .hdr10Plus {
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_2020,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_2020,
            .shouldPropagate
        )
    }
    return try DecodedVideoFrame(
        pixelBuffer: pixelBuffer,
        presentationTime: CMTime(
            seconds: time,
            preferredTimescale: 600
        ),
        duration: CMTime(
            seconds: duration,
            preferredTimescale: 600
        ),
        videoFormat: videoFormat,
        geometry: DecodedVideoFrameGeometry(
            codedWidth: 16,
            codedHeight: 16,
            cleanAperture: .init(
                x: 0,
                y: 0,
                width: 16,
                height: 16
            ),
            pixelAspectRatioNumerator: 1,
            pixelAspectRatioDenominator: 1,
            rotationDegrees: 0
        ),
        hdr10PlusT35: hdr10PlusT35,
        generation: generation
    )
}

@Suite("Hybrid playback session", .serialized)
struct HybridPlaybackSessionTests {
    private final class ThreadSafeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        func snapshot() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class RestartGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var isOpen = false
        private var waiterPresent = false

        func wait() {
            condition.lock()
            waiterPresent = true
            condition.broadcast()
            while !isOpen {
                condition.wait()
            }
            condition.unlock()
        }

        func release() {
            condition.lock()
            isOpen = true
            condition.broadcast()
            condition.unlock()
        }

        var isWaiting: Bool {
            condition.lock()
            defer { condition.unlock() }
            return waiterPresent && !isOpen
        }
    }

    private final class CloseProbeIOReader:
        IOReader,
        @unchecked Sendable
    {
        private let base: DataIOReader
        private let lock = NSLock()
        private var closed = false

        init(data: Data) {
            base = DataIOReader(data: data)
        }

        func read(
            _ buffer: UnsafeMutablePointer<UInt8>?,
            size: Int32
        ) -> Int32 {
            base.read(buffer, size: size)
        }

        func seek(offset: Int64, whence: Int32) -> Int64 {
            base.seek(offset: offset, whence: whence)
        }

        func cancel() {
            base.cancel()
        }

        func close() {
            base.close()
            lock.lock()
            closed = true
            lock.unlock()
        }

        var wasClosed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return closed
        }
    }

    private class Provider:
        HybridCarrierTransportProvider,
        HybridAudioAnalysisSource,
        HybridAudioAnalysisPlaybackPressureSink,
        HybridPlaybackTerminalErrorSource,
        HybridCarrierSegmentProductionActivitySource,
        @unchecked Sendable
    {
        private let relay: HybridPlaybackFrameRelay
        private let timeline: BlackCarrierTimeline
        private let analysisData: Data?
        private let analysisTrackIDs: [Int]
        private let videoFormat: VideoFormat?
        private let lock = NSLock()

        private(set) var didPrepareInitial = false
        private(set) var didClose = false
        private(set) var restartIntents: [HybridSeekIntent] = []
        private(set) var preparedSegments: [Int] = []
        private(set) var decodeDemands: [CMTime] = []
        private(set) var prepareMainThreadSamples: [Bool] = []
        private(set) var analysisPlaybackPressures:
            [HybridAudioAnalysisPlaybackPressure] = []
        private var currentGeneration: UInt64 = 0
        private var forcedRestartResult:
            BlackCarrierMediaFanoutRestartResult?
        private var terminalError:
            HybridPlaybackSessionError?
        private var emitsInitialFrame = true
        private var preparedGenerationFrameTimes: [Double]?
        private var restartGate: RestartGate?
        private var decodeDemandGate: RestartGate?
        private var terminalDecodeDemandFrameTime: Double?
        private var carrierSegmentProductionActive = false
        private var terminalErrorHandler:
            (@Sendable (
                HybridPlaybackSessionError
            ) -> Void)?

        init(
            relay: HybridPlaybackFrameRelay,
            timeline: BlackCarrierTimeline,
            analysisData: Data? = nil,
            analysisTrackIDs: [Int]? = nil,
            videoFormat: VideoFormat? = .sdr
        ) {
            self.relay = relay
            self.timeline = timeline
            self.analysisData = analysisData
            self.analysisTrackIDs = analysisData == nil
                ? []
                : (analysisTrackIDs ?? [0])
            self.videoFormat = videoFormat
        }

        var hybridVideoFormat: VideoFormat? { videoFormat }
        var hybridDolbyVisionConfiguration:
            AetherDolbyVisionConfiguration? { nil }
        var hybridVideoFrameRate: Double? { 24 }
        var terminalHybridPlaybackError:
            HybridPlaybackSessionError?
        {
            lock.lock()
            defer { lock.unlock() }
            return terminalError
        }
        var audioAnalysisTrackIDs: [Int] {
            analysisTrackIDs
        }
        var isCarrierSegmentProductionActive: Bool {
            lock.lock()
            defer { lock.unlock() }
            return carrierSegmentProductionActive
        }
        var alternateAudioRenditions:
            [HLSAudioRenditionInfo]
        {
            analysisTrackIDs.enumerated().map {
                ordinal, _ in
                HLSAudioRenditionInfo(
                    ordinal: ordinal,
                    language: nil,
                    name: "Audio \(ordinal + 1)",
                    isDefault: ordinal == 0,
                    isAutoselect: true,
                    channels: "1"
                )
            }
        }
        func sourceTrackID(
            forAudioOrdinal ordinal: Int
        ) -> Int? {
            guard analysisTrackIDs.indices
                    .contains(ordinal) else {
                return nil
            }
            return analysisTrackIDs[ordinal]
        }

        func makeAudioAnalysisInput() throws
            -> AudioAnalysisInput
        {
            guard let analysisData else {
                throw AudioAnalysisError.audioTrackUnavailable(0)
            }
            return .reader(
                DataIOReader(data: analysisData),
                formatHint: "wav"
            )
        }

        func setAudioAnalysisPlaybackPressure(
            _ pressure: HybridAudioAnalysisPlaybackPressure
        ) async {
            recordAudioAnalysisPlaybackPressure(pressure)
        }

        func setTerminalHybridPlaybackErrorHandler(
            _ handler:
                (@Sendable (
                    HybridPlaybackSessionError
                ) -> Void)?
        ) {
            lock.lock()
            terminalErrorHandler = handler
            let existing = terminalError
            lock.unlock()
            if let existing {
                handler?(existing)
            }
        }

        private func recordAudioAnalysisPlaybackPressure(
            _ pressure: HybridAudioAnalysisPlaybackPressure
        ) {
            lock.lock()
            analysisPlaybackPressures.append(pressure)
            lock.unlock()
        }

        func prepareForTransportStart() throws {
            lock.lock()
            didPrepareInitial = true
            prepareMainThreadSamples.append(Thread.isMainThread)
            let shouldEmitInitialFrame =
                emitsInitialFrame
            lock.unlock()
            guard shouldEmitInitialFrame,
                  let videoFormat else {
                return
            }
            relay.emit(try makeHybridPlaybackSessionFrame(
                time: 0,
                generation: 0,
                videoFormat: videoFormat
            ))
        }

        func restartMedia(
            for intent: HybridSeekIntent
        ) throws -> BlackCarrierMediaFanoutRestartResult {
            guard case .userSeek(
                _,
                let segmentIndex,
                let generation
            ) = intent else {
                throw BlackCarrierMediaFanoutPumpError
                    .restartRequiresUserSeek
            }
            lock.lock()
            restartIntents.append(intent)
            currentGeneration = generation
            let forcedResult = forcedRestartResult
            let restartGate = restartIntents.count == 1
                ? self.restartGate
                : nil
            lock.unlock()
            restartGate?.wait()
            if let forcedResult {
                return forcedResult
            }
            return .applied(
                generation: generation,
                segmentIndex: segmentIndex
            )
        }

        func prepareHybridGeneration(segmentIndex: Int) throws {
            lock.lock()
            preparedSegments.append(segmentIndex)
            let generation = currentGeneration
            let configuredFrameTimes = preparedGenerationFrameTimes
            lock.unlock()
            guard let videoFormat else { return }
            if let configuredFrameTimes {
                for time in configuredFrameTimes {
                    relay.emit(try makeHybridPlaybackSessionFrame(
                        time: time,
                        duration: 1 / 24,
                        generation: generation,
                        videoFormat: videoFormat
                    ))
                }
                return
            }
            let segment = timeline.segments[segmentIndex]
            relay.emit(try makeHybridPlaybackSessionFrame(
                time: segment.startTime.seconds,
                duration: segment.duration.seconds,
                generation: generation,
                videoFormat: videoFormat
            ))
        }

        func advanceVideoDecodeDemand(to time: CMTime) throws {
            lock.lock()
            decodeDemands.append(time)
            let gate = decodeDemandGate
            decodeDemandGate = nil
            let terminalFrameTime =
                CMTimeCompare(time, timeline.duration) >= 0
                    ? terminalDecodeDemandFrameTime
                    : nil
            let generation = currentGeneration
            lock.unlock()
            gate?.wait()
            if let terminalFrameTime, let videoFormat {
                relay.emit(
                    try makeHybridPlaybackSessionFrame(
                        time: terminalFrameTime,
                        duration: 0.25,
                        generation: generation,
                        videoFormat: videoFormat
                    )
                )
            }
        }

        func close() {
            lock.lock()
            didClose = true
            lock.unlock()
        }

        func forceRestartResult(
            _ result: BlackCarrierMediaFanoutRestartResult
        ) {
            lock.lock()
            forcedRestartResult = result
            lock.unlock()
        }

        func configurePreparedGenerationFrameTimes(
            _ frameTimes: [Double]
        ) {
            lock.lock()
            preparedGenerationFrameTimes = frameTimes
            lock.unlock()
        }

        func configureInitialFrameEnabled(
            _ enabled: Bool
        ) {
            lock.lock()
            emitsInitialFrame = enabled
            lock.unlock()
        }

        func configureRestartGate(_ gate: RestartGate) {
            lock.lock()
            restartGate = gate
            lock.unlock()
        }

        func configureDecodeDemandGate(_ gate: RestartGate) {
            lock.lock()
            decodeDemandGate = gate
            lock.unlock()
        }

        func configureTerminalDecodeDemandFrameTime(
            _ time: Double
        ) {
            lock.lock()
            terminalDecodeDemandFrameTime = time
            lock.unlock()
        }

        func configureCarrierSegmentProductionActive(
            _ active: Bool
        ) {
            lock.lock()
            carrierSegmentProductionActive = active
            lock.unlock()
        }

        func failTerminally(
            _ error: HybridPlaybackSessionError
        ) {
            lock.lock()
            terminalError = error
            let handler = terminalErrorHandler
            lock.unlock()
            handler?(error)
        }

        func snapshot()
            -> (
                prepared: Bool,
                restarts: [HybridSeekIntent],
                segments: [Int],
                demands: [CMTime],
                prepareMainThreads: [Bool],
                analysisPlaybackPressures:
                    [HybridAudioAnalysisPlaybackPressure],
                closed: Bool
            )
        {
            lock.lock()
            defer { lock.unlock() }
            return (
                didPrepareInitial,
                restartIntents,
                preparedSegments,
                decodeDemands,
                prepareMainThreadSamples,
                analysisPlaybackPressures,
                didClose
            )
        }

        func initSegment() -> Data? { Data([0]) }
        func mediaSegment(at index: Int) -> Data? { Data([0]) }
        var segmentCount: Int { timeline.segments.count }
        func segmentDuration(at index: Int) -> Double {
            timeline.segments[index].duration.seconds
        }
        var playlistType: HLSPlaylistType { .vod }
    }

    @MainActor
    private final class Transport: HybridCarrierPlayerTransport {
        private final class ClockPlayer: AVPlayer {
            nonisolated(unsafe) var controlledTime = CMTime.zero

            override func currentTime() -> CMTime {
                controlledTime
            }
        }

        private let clockPlayer = ClockPlayer()
        var avPlayer: AVPlayer { clockPlayer }
        private(set) var didStart = false
        private(set) var didStop = false
        private(set) var seekTargets: [CMTime] = []
        var onSeek: (@MainActor (CMTime) -> Void)?
        var onStop: (@MainActor () -> Void)?

        func startPrepared() throws {
            didStart = true
            let asset = AVURLAsset(
                url: URL(string: "https://example.invalid/carrier.m3u8")!
            )
            avPlayer.replaceCurrentItem(
                with: AVPlayerItem(asset: asset)
            )
        }

        func prepare(timeout: TimeInterval) async throws {}

        func seek(to time: CMTime, timeout: TimeInterval) async -> Bool {
            seekTargets.append(time)
            clockPlayer.controlledTime = time
            onSeek?(time)
            return true
        }

        func setCurrentTime(_ time: CMTime) {
            clockPlayer.controlledTime = time
        }

        func stop() {
            didStop = true
            avPlayer.pause()
            avPlayer.replaceCurrentItem(with: nil)
            onStop?()
        }
    }

    private final class BlockingProviderTelemetryProbe:
        @unchecked Sendable
    {
        let carrier = AetherHybridCarrierBandwidthTelemetry(
            observedPeakBandwidth: 640_000,
            observedAverageBandwidth: 512_000,
            observedSegmentCount: 2,
            audioRenditionCount: 1,
            state: .partial
        )
        let realVideo = AetherHybridRealVideoBitrateTelemetry(
            observedAverageBitrate: 1_200_000,
            observedCompressedByteCount: 300_000,
            observedSourceDurationSeconds: 2,
            observedPacketCount: 48,
            state: .partial
        )

        private let condition = NSCondition()
        private var isReleased = false
        private var readCount = 0
        private var mainThreadReadCount = 0

        func readCarrier()
            -> AetherHybridCarrierBandwidthTelemetry
        {
            waitForReleaseIfOffMainThread()
            return carrier
        }

        func readRealVideo()
            -> AetherHybridRealVideoBitrateTelemetry
        {
            waitForReleaseIfOffMainThread()
            return realVideo
        }

        var hasReadStarted: Bool {
            condition.lock()
            defer { condition.unlock() }
            return readCount > 0
        }

        var observedMainThreadReadCount: Int {
            condition.lock()
            defer { condition.unlock() }
            return mainThreadReadCount
        }

        func release() {
            condition.lock()
            isReleased = true
            condition.broadcast()
            condition.unlock()
        }

        private func waitForReleaseIfOffMainThread() {
            condition.lock()
            readCount += 1
            if Thread.isMainThread {
                mainThreadReadCount += 1
                condition.unlock()
                return
            }
            condition.broadcast()
            while !isReleased {
                condition.wait()
            }
            condition.unlock()
        }
    }

    private final class TelemetryProvider:
        Provider,
        HybridCarrierBandwidthTelemetrySource,
        HybridRealVideoBitrateTelemetrySource,
        @unchecked Sendable
    {
        private let telemetryProbe:
            BlockingProviderTelemetryProbe

        init(
            relay: HybridPlaybackFrameRelay,
            timeline: BlackCarrierTimeline,
            telemetryProbe: BlockingProviderTelemetryProbe
        ) {
            self.telemetryProbe = telemetryProbe
            super.init(
                relay: relay,
                timeline: timeline
            )
        }

        var carrierBandwidthTelemetry:
            AetherHybridCarrierBandwidthTelemetry
        {
            telemetryProbe.readCarrier()
        }

        var realVideoBitrateTelemetry:
            AetherHybridRealVideoBitrateTelemetry
        {
            telemetryProbe.readRealVideo()
        }
    }

    @MainActor
    private final class RenderSurface: HybridPlaybackRenderSurface {
        private(set) var generation: UInt64 = 0
        private(set) var videoFormat: VideoFormat?
        private(set) var frames: [DecodedVideoFrame] = []
        private(set) var acceptedFrameCount = 0
        private(set) var carrierClockValidationCount = 0
        private(set) var boundItem: AVPlayerItem?
        private(set) var boundTimebase: CMTimebase?
        private(set) var flushCount = 0
        var retainsAcceptedFramesUntilCapacityCallback = false
        var synchronouslyReleasesAcceptedFrames = false
        private var frameDidLeaveMailbox: (@Sendable () -> Void)?

        func beginGeneration(
            _ generation: UInt64,
            videoFormat: VideoFormat
        ) throws {
            self.generation = generation
            self.videoFormat = videoFormat
            if retainsAcceptedFramesUntilCapacityCallback {
                releaseRetainedFrames()
            } else {
                frames.removeAll()
            }
        }

        func enqueue(
            _ frame: DecodedVideoFrame
        ) throws -> HybridFrameEnqueueOutcome {
            guard frame.generation == generation else {
                return .staleGeneration
            }
            frames.append(frame)
            acceptedFrameCount += 1
            if retainsAcceptedFramesUntilCapacityCallback,
               synchronouslyReleasesAcceptedFrames {
                frames.removeLast()
                frameDidLeaveMailbox?()
            }
            return .accepted
        }

        func bindCarrierClock(
            item: AVPlayerItem,
            timebase: CMTimebase
        ) throws {
            boundItem = item
            boundTimebase = timebase
        }

        func validateCarrierClock(
            item: AVPlayerItem,
            timebase: CMTimebase
        ) throws {
            guard boundItem === item,
                  let boundTimebase,
                  CFEqual(boundTimebase, timebase) else {
                throw AetherHybridPresentationError
                    .carrierBindingChanged
            }
            carrierClockValidationCount += 1
        }

        func flush(removingDisplayedImage: Bool) {
            flushCount += 1
            if retainsAcceptedFramesUntilCapacityCallback {
                releaseRetainedFrames()
            } else {
                frames.removeAll()
            }
        }

        func invalidate() {
            flush(removingDisplayedImage: true)
            boundItem = nil
            boundTimebase = nil
        }

        func installMailboxCallbacks(
            frameDidLeaveMailbox: @escaping @Sendable () -> Void,
            asynchronousFailureHandler: @escaping @MainActor (
                AetherHybridPresentationError
            ) -> Void
        ) {
            self.frameDidLeaveMailbox = frameDidLeaveMailbox
        }

        func releaseRetainedFrames() {
            let count = frames.count
            frames.removeAll(keepingCapacity: true)
            for _ in 0..<count {
                frameDidLeaveMailbox?()
            }
        }
    }

    private func makeAnalysisWAV(seconds: Double) -> Data {
        let sampleRate = 48_000
        let channels = 2
        let frames = Int(Double(sampleRate) * seconds)
        var pcm = Data(capacity: frames * channels * 2)
        for frame in 0..<frames {
            let value = Int16(
                9_000 * sin(
                    2 * .pi * 440 * Double(frame) / Double(sampleRate)
                )
            )
            for _ in 0..<channels {
                withUnsafeBytes(of: value.littleEndian) {
                    pcm.append(contentsOf: $0)
                }
            }
        }
        var data = Data()
        func appendString(_ value: String) {
            data.append(value.data(using: .ascii)!)
        }
        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        func appendUInt16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        appendString("RIFF")
        appendUInt32(UInt32(36 + pcm.count))
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(UInt16(channels))
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * channels * 2))
        appendUInt16(UInt16(channels * 2))
        appendUInt16(16)
        appendString("data")
        appendUInt32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }

    @MainActor
    @Test("Public Hybrid seek timeout stays transient and same-source")
    func hybridSeekTimeoutEvidence() {
        let evidence = HybridPlaybackSession
            .seekTimeoutFailureEvidence(
                seconds: 35,
                recoveryStep: .providerRestart
            )
        #expect(evidence.stage == .seek)
        #expect(evidence.category == .transientTransport)
        #expect(evidence.caseCode == "seekTimedOut")
        #expect(evidence.underlyingCode == 35)
        #expect(evidence.recoveryStep == .providerRestart)

        let outer = AetherPlaybackSession.hybridFailure(
            evidence: evidence
        )
        #expect(outer.kind == .transientTransport)
        #expect(outer.caseCode == "seekTimedOut")
        #expect(
            AetherPlaybackSession
                .requiresPersistentSameSourceRecovery(outer)
        )
    }

    @MainActor
    @Test("Hybrid session owns independent demand-driven audio analysis")
    func hybridAudioAnalysisStream() async throws {
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: 2,
                preferredTimescale: 90_000
            )
        )
        let relay = HybridPlaybackFrameRelay()
        let provider = Provider(
            relay: relay,
            timeline: timeline,
            analysisData: makeAnalysisWAV(seconds: 2)
        )
        let transport = Transport()
        let renderSurface = RenderSurface()
        let session = try HybridPlaybackSession(
            provider: provider,
            transport: transport,
            renderSurface: renderSurface,
            timeline: timeline,
            relay: relay
        )
        defer { session.stop() }
        let telemetry = HybridTelemetryTriggerRecorder()
        session.telemetryDidChange = {
            telemetry.record($0)
        }
        let request = try AudioAnalysisRequest(
            audioTrackID: 0,
            range: 0.25..<0.75
        )
        #expect(
            session.audioAnalysisAvailability(
                for: 0
            ) == .available
        )
        #expect(
            session.audioAnalysisAvailability(
                for: 99
            ) == .unavailable(
                .audioTrackUnavailable(99)
            )
        )
        let stream = try session.audioAnalysisStream(
            request: request
        )
        try await waitUntil {
            telemetry.values.contains { trigger in
                guard case .audioAnalysis(let event) =
                        trigger else {
                    return false
                }
                return event.phase == .started
            }
        }
        session.applyAudioAnalysisPlaybackPressure(
            .carrierPlaybackStalled,
            forwardBufferSeconds: 0.25
        )
        try await Task.sleep(nanoseconds: 20_000_000)
        session.applyAudioAnalysisPlaybackPressure(
            .none,
            forwardBufferSeconds: 4
        )

        var totalFrames: Int64 = 0
        var firstPosition: Int64?
        var finalPosition: Int64?
        var bufferIndex = 0
        var iterator = stream.makeAsyncIterator()
        while let buffer = try await iterator.next() {
            firstPosition = firstPosition
                ?? buffer.sourceSamplePosition
            totalFrames += Int64(buffer.pcm.frameLength)
            finalPosition = buffer.sourceSamplePosition
                + Int64(buffer.pcm.frameLength)
            #expect(buffer.pcm.format.sampleRate == 48_000)
            #expect(buffer.pcm.format.channelCount == 1)
            if bufferIndex > 0 {
                #expect(!buffer.isDiscontinuous)
            }
            bufferIndex += 1
        }

        let resolvedFirstPosition = try #require(firstPosition)
        let resolvedFinalPosition = try #require(finalPosition)
        #expect(abs(totalFrames - 24_000) <= 1_200)
        #expect(abs(resolvedFirstPosition - 12_000) <= 120)
        #expect(abs(resolvedFinalPosition - 36_000) <= 120)
        try await waitUntil {
            telemetry.values.contains { trigger in
                guard case .audioAnalysis(let event) =
                        trigger else {
                    return false
                }
                return event.phase == .completed
            }
        }
        let analysisEvents = telemetry.values.compactMap {
            trigger -> AetherHybridAudioAnalysisTelemetry? in
            guard case .audioAnalysis(let event) = trigger else {
                return nil
            }
            return event
        }
        #expect(analysisEvents.first?.phase == .started)
        #expect(
            analysisEvents.contains { $0.phase == .progress }
        )
        #expect(analysisEvents.last?.phase == .completed)
        #expect(
            analysisEvents.last?.decodedUntilSeconds != nil
        )
        #expect(
            analysisEvents.last?.bufferedFrames == 0
        )
        #expect(
            analysisEvents.last?.pausedForPlaybackCount == 1
        )
        #expect(
            try #require(
                analysisEvents.last?
                    .pausedForPlaybackDurationSeconds
            ) > 0
        )
    }

    @MainActor
    @Test("Carrier audio selection publishes the stable track and cancels the old analysis cursor")
    func audioSelectionCancelsAnalysisCursor() async throws {
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: 2,
                preferredTimescale: 90_000
            )
        )
        let relay = HybridPlaybackFrameRelay()
        let provider = Provider(
            relay: relay,
            timeline: timeline,
            analysisData: makeAnalysisWAV(seconds: 2),
            analysisTrackIDs: [11, 22]
        )
        let session = try HybridPlaybackSession(
            provider: provider,
            transport: Transport(),
            renderSurface: RenderSurface(),
            timeline: timeline,
            relay: relay
        )
        defer { session.stop() }

        var selections: [Int?] = []
        session.selectedAudioAnalysisTrackIDDidChange = {
            selections.append($0)
        }
        session.handleCarrierMediaSelectionChange(
            selectedAudioOptionIndex: 0
        )
        #expect(session.selectedAudioAnalysisTrackID == 11)

        let request = try AudioAnalysisRequest(
            audioTrackID: 11,
            range: 0..<1
        )
        let stream = try session.audioAnalysisStream(
            request: request
        )
        #expect(session.activeAudioAnalysisRequestCount == 1)

        session.handleCarrierMediaSelectionChange(
            selectedAudioOptionIndex: 1
        )
        #expect(session.selectedAudioAnalysisTrackID == 22)
        #expect(session.activeAudioAnalysisRequestCount == 0)
        #expect(selections == [22])

        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("retired analysis cursor unexpectedly produced PCM")
        } catch let error as AudioAnalysisError {
            #expect(error == .cancelled)
        }
    }

    @MainActor
    @Test("AVPlayer pressure policy is explicit and does not pressure paused playback")
    func audioAnalysisPlaybackPressurePolicy() {
        let ready = HybridPlaybackSessionState.ready(
            generation: 0
        )
        #expect(
            HybridPlaybackSession
                .resolveAudioAnalysisPlaybackPressure(
                    state: .preparing(
                        generation: 0,
                        target: .zero
                    ),
                    timeControlStatus: .paused,
                    rate: 0,
                    playbackStalled: false,
                    isPlaybackBufferEmpty: false,
                    isPlaybackLikelyToKeepUp: true,
                    forwardBufferSeconds: nil
                )
                == .carrierPreparingOrSeeking
        )
        #expect(
            HybridPlaybackSession
                .resolveAudioAnalysisPlaybackPressure(
                    state: ready,
                    timeControlStatus: .paused,
                    rate: 0,
                    playbackStalled: false,
                    isPlaybackBufferEmpty: true,
                    isPlaybackLikelyToKeepUp: false,
                    forwardBufferSeconds: 0
                )
                == .none
        )
        #expect(
            HybridPlaybackSession
                .resolveAudioAnalysisPlaybackPressure(
                    state: ready,
                    timeControlStatus:
                        .waitingToPlayAtSpecifiedRate,
                    rate: 0,
                    playbackStalled: false,
                    isPlaybackBufferEmpty: false,
                    isPlaybackLikelyToKeepUp: true,
                    forwardBufferSeconds: 4
                )
                == .carrierWaitingToPlay
        )
        #expect(
            HybridPlaybackSession
                .resolveAudioAnalysisPlaybackPressure(
                    state: ready,
                    timeControlStatus: .playing,
                    rate: 1,
                    playbackStalled: true,
                    isPlaybackBufferEmpty: false,
                    isPlaybackLikelyToKeepUp: true,
                    forwardBufferSeconds: 4
                )
                == .carrierPlaybackStalled
        )
        #expect(
            HybridPlaybackSession
                .resolveAudioAnalysisPlaybackPressure(
                    state: ready,
                    timeControlStatus: .playing,
                    rate: 1,
                    playbackStalled: false,
                    isPlaybackBufferEmpty: true,
                    isPlaybackLikelyToKeepUp: false,
                    forwardBufferSeconds: 0
                )
                == .carrierBufferEmpty
        )
        #expect(
            HybridPlaybackSession
                .resolveAudioAnalysisPlaybackPressure(
                    state: ready,
                    timeControlStatus: .playing,
                    rate: 1,
                    playbackStalled: false,
                    isPlaybackBufferEmpty: false,
                    isPlaybackLikelyToKeepUp: true,
                    forwardBufferSeconds: 1.999
                )
                == .carrierForwardBufferLow
        )
        #expect(
            HybridPlaybackSession
                .resolveAudioAnalysisPlaybackPressure(
                    state: ready,
                    timeControlStatus: .playing,
                    rate: 1,
                    playbackStalled: false,
                    isPlaybackBufferEmpty: false,
                    isPlaybackLikelyToKeepUp: false,
                    forwardBufferSeconds: nil
                )
                == .carrierNotLikelyToKeepUp
        )
        #expect(
            HybridPlaybackSession
                .resolveAudioAnalysisPlaybackPressure(
                    state: ready,
                    timeControlStatus: .playing,
                    rate: 1,
                    playbackStalled: false,
                    isPlaybackBufferEmpty: false,
                    isPlaybackLikelyToKeepUp: true,
                    forwardBufferSeconds:
                        HybridPlaybackSession
                            .analysisForwardBufferPressureThresholdSeconds
                )
                == .none
        )
    }

    @Test("Forward-buffer coverage merges overlap and stops at the first gap")
    func audioAnalysisForwardBufferCoverage() {
        let second: CMTimeScale = 600
        func range(
            _ start: Double,
            _ duration: Double
        ) -> CMTimeRange {
            CMTimeRange(
                start: CMTime(
                    seconds: start,
                    preferredTimescale: second
                ),
                duration: CMTime(
                    seconds: duration,
                    preferredTimescale: second
                )
            )
        }

        #expect(
            HybridPlaybackSession.forwardBufferSeconds(
                currentTime: CMTime(
                    seconds: 5,
                    preferredTimescale: second
                ),
                loadedTimeRanges: []
            ) == nil
        )
        #expect(
            HybridPlaybackSession.forwardBufferSeconds(
                currentTime: CMTime(
                    seconds: 5,
                    preferredTimescale: second
                ),
                loadedTimeRanges: [
                    range(0, 6),
                    range(5.5, 4.5),
                ]
            ) == 5
        )
        #expect(
            HybridPlaybackSession.forwardBufferSeconds(
                currentTime: CMTime(
                    seconds: 5,
                    preferredTimescale: second
                ),
                loadedTimeRanges: [
                    range(0, 6),
                    range(6.1, 3.9),
                ]
            ) == 1
        )
        #expect(
            HybridPlaybackSession.forwardBufferSeconds(
                currentTime: CMTime(
                    seconds: 5,
                    preferredTimescale: second
                ),
                loadedTimeRanges: [
                    range(6, 4),
                ]
            ) == 0
        )
        #expect(
            HybridPlaybackSession.forwardBufferSeconds(
                currentTime: CMTime(
                    seconds: 11,
                    preferredTimescale: second
                ),
                loadedTimeRanges: [
                    range(0, 10),
                ]
            ) == 0
        )
    }

    @MainActor
    @Test("Hybrid session forwards ordered pressure reasons to the provider")
    func audioAnalysisPlaybackPressurePropagation() async throws {
        let fixture = try makeSession()
        defer { fixture.session.stop() }

        fixture.session.applyAudioAnalysisPlaybackPressure(
            .carrierPlaybackStalled,
            forwardBufferSeconds: 0.25
        )
        try await waitUntil {
            fixture.provider.snapshot()
                .analysisPlaybackPressures.last
                == .carrierPlaybackStalled
        }
        #expect(
            fixture.session.audioAnalysisPlaybackPressure
                == .carrierPlaybackStalled
        )
        #expect(
            fixture.session.carrierForwardBufferSeconds
                == 0.25
        )

        fixture.session.applyAudioAnalysisPlaybackPressure(
            .none,
            forwardBufferSeconds: 4
        )
        try await waitUntil {
            fixture.provider.snapshot()
                .analysisPlaybackPressures.last
                == HybridAudioAnalysisPlaybackPressure.none
        }
        #expect(
            fixture.provider.snapshot()
                .analysisPlaybackPressures
                == [
                    .carrierPlaybackStalled,
                    .none,
                ]
        )
    }

    @MainActor
    @Test("Frame relay pauses at high-water and generation flush releases the producer")
    func boundedFrameRelayBackpressure() async throws {
        let fixture = try makeSession(
            retainsFramesUntilCapacityCallback: true
        )
        defer { fixture.session.stop() }
        try await fixture.session.prepare(timeout: 10)
        fixture.renderSurface.releaseRetainedFrames()
        let baseline = fixture.renderSurface.acceptedFrameCount

        let frames = try (0..<25).map { index in
            try makeHybridPlaybackSessionFrame(
                time: Double(index + 1) / 60,
                duration: 1.0 / 60,
                generation: fixture.session.generation
            )
        }
        let emitted = ThreadSafeCounter()
        let producer = Task.detached {
            for frame in frames {
                fixture.relay.emit(frame)
                emitted.increment()
            }
        }

        try await waitUntil {
            emitted.snapshot() == 24
                && fixture.renderSurface.frames.count == 24
        }
        #expect(fixture.renderSurface.frames.count == 24)
        #expect(fixture.session.state != .failed(.cancelled))

        fixture.renderSurface.flush(
            removingDisplayedImage: false
        )
        await producer.value
        try await waitUntil {
            fixture.renderSurface.acceptedFrameCount
                == baseline + 25
        }
        #expect(emitted.snapshot() == 25)
        #expect(
            fixture.renderSurface.acceptedFrameCount
                == baseline + 25
        )
        fixture.renderSurface.releaseRetainedFrames()
        try await waitUntil {
            fixture.relay.diagnostics.mailboxDepth == 0
        }
        #expect(fixture.relay.diagnostics.mailboxDepth == 0)
    }

    @MainActor
    @Test("Synchronous renderer release does not leak frame ownership")
    func synchronousRendererReleaseOwnership() async throws {
        let fixture = try makeSession(
            retainsFramesUntilCapacityCallback: true,
            synchronouslyReleasesAcceptedFrames: true
        )
        defer { fixture.session.stop() }
        try await fixture.session.prepare(timeout: 1)
        let baseline = fixture.renderSurface.acceptedFrameCount
        #expect(fixture.relay.diagnostics.mailboxDepth == 0)

        let frames = try (0..<96).map { index in
            try makeHybridPlaybackSessionFrame(
                time: Double(index + 1) / 60,
                duration: 1.0 / 60,
                generation: fixture.session.generation
            )
        }
        let emitted = ThreadSafeCounter()
        let producer = Task.detached {
            for frame in frames {
                fixture.relay.emit(frame)
                emitted.increment()
            }
        }

        let completed = await waitUntilResult {
            emitted.snapshot() == frames.count
                && fixture.renderSurface.acceptedFrameCount
                    == baseline + frames.count
        }
        if !completed {
            fixture.relay.detach()
        }
        await producer.value

        #expect(completed)
        #expect(emitted.snapshot() == frames.count)
        #expect(fixture.relay.diagnostics.mailboxDepth == 0)
    }

    @Test("Initial carrier and decoded frame must both become ready")
    @MainActor
    func initialReadinessAndClockDemand() async throws {
        let fixture = try makeSession()
        defer { fixture.session.stop() }

        try await fixture.session.prepare(timeout: 1)
        #expect(fixture.session.state == .ready(generation: 0))
        #expect(fixture.transport.didStart)
        #expect(fixture.renderSurface.generation == 0)
        #expect(fixture.renderSurface.frames.count == 1)
        #expect(fixture.renderSurface.videoFormat == .sdr)
        #expect(
            fixture.renderSurface.boundItem
                === fixture.transport.avPlayer.currentItem
        )
        #expect(fixture.renderSurface.boundTimebase != nil)
        #expect(fixture.provider.snapshot().prepared)
        #expect(
            fixture.provider.snapshot().prepareMainThreads == [false]
        )

        fixture.session.handleClockTick(
            CMTime(seconds: 1, preferredTimescale: 600)
        )
        try await waitUntil {
            fixture.provider.snapshot().demands.contains {
                abs($0.seconds - 1.25) < 0.000_001
            }
        }
        let demand = try #require(
            fixture.provider.snapshot().demands.first {
                abs($0.seconds - 1.25) < 0.000_001
            }
        )
        #expect(abs(demand.seconds - 1.25) < 0.000_001)
        #expect(
            fixture.renderSurface.carrierClockValidationCount > 0
        )
    }

    @Test(
        "Initial real-frame readiness survives the legacy timeout value"
    )
    @MainActor
    func initialFrameReadinessDoesNotTimeOut() async throws {
        let fixture = try makeSession()
        defer { fixture.session.stop() }
        fixture.provider.configureInitialFrameEnabled(false)

        let prepare = Task { @MainActor in
            try await fixture.session.prepare(
                timeout: 0.01
            )
        }
        let preparing = await waitUntilResult {
            if case .preparing =
                    fixture.session.state {
                return true
            }
            return false
        }
        #expect(preparing)
        try await Task.sleep(
            nanoseconds: 100_000_000
        )
        #expect(
            fixture.session.state
                == .preparing(
                    generation: 0,
                    target: .zero
                )
        )
        #expect(!fixture.transport.didStop)

        fixture.relay.emit(
            try makeHybridPlaybackSessionFrame(
                time: 0,
                generation: 0,
                videoFormat: .sdr
            )
        )
        try await prepare.value

        #expect(
            fixture.session.state
                == .ready(generation: 0)
        )
    }

    @Test("Audio-only Hybrid carrier is ready and seekable without source-video evidence")
    @MainActor
    func audioOnlyCarrierReadinessAndSeek() async throws {
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: 5.25,
                preferredTimescale: 90_000
            )
        )
        let relay = HybridPlaybackFrameRelay()
        let provider = Provider(
            relay: relay,
            timeline: timeline,
            analysisData: Data([0]),
            videoFormat: nil
        )
        let transport = Transport()
        let renderSurface = RenderSurface()
        let session = try HybridPlaybackSession(
            provider: provider,
            transport: transport,
            renderSurface: renderSurface,
            timeline: timeline,
            relay: relay,
            allowsAudioOnlyCarrier: true
        )
        defer { session.stop() }

        try await session.prepare(timeout: 1)
        let carrierItem = try #require(transport.avPlayer.currentItem)
        #expect(session.state == .ready(generation: 0))
        #expect(session.avPlayer === transport.avPlayer)
        #expect(provider.snapshot().prepared)
        #expect(provider.snapshot().demands.isEmpty)
        #expect(renderSurface.frames.isEmpty)
        #expect(renderSurface.videoFormat == nil)

        session.handleClockTick(
            CMTime(seconds: 1, preferredTimescale: 600)
        )
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(provider.snapshot().demands.isEmpty)

        let target = CMTime(
            seconds: 4.5,
            preferredTimescale: 600
        )
        let result = try await session.seek(
            to: target,
            timeout: 1
        )

        #expect(result == .applied(generation: 1, target: target))
        #expect(session.state == .ready(generation: 1))
        #expect(transport.avPlayer.currentItem === carrierItem)
        #expect(transport.seekTargets == [target])
        #expect(provider.snapshot().segments == [1])
        #expect(provider.snapshot().demands.isEmpty)
        #expect(renderSurface.frames.isEmpty)
        #expect(renderSurface.generation == 0)
    }

    @Test("Late HDR10 Plus metadata upgrades format without changing generation")
    @MainActor
    func lateHDR10PlusUpgradeKeepsGeneration() async throws {
        let fixture = try makeSession(videoFormat: .hdr10)
        defer { fixture.session.stop() }
        let telemetry = HybridTelemetryTriggerRecorder()
        fixture.session.telemetryDidChange = {
            telemetry.record($0)
        }

        try await fixture.session.prepare(timeout: 1)
        #expect(fixture.session.sourceVideoFormat == .hdr10)
        #expect(fixture.renderSurface.generation == 0)
        telemetry.removeAll()

        fixture.relay.emit(try makeHybridPlaybackSessionFrame(
            time: 1,
            generation: 0,
            videoFormat: .hdr10Plus,
            hdr10PlusT35: Data([
                0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04, 0x01,
            ])
        ))
        try await waitUntil {
            fixture.session.sourceVideoFormat == .hdr10Plus
        }

        #expect(fixture.session.sourceVideoFormat == .hdr10Plus)
        #expect(fixture.renderSurface.generation == 0)
        #expect(fixture.renderSurface.frames.last?.videoFormat == .hdr10Plus)
        #expect(telemetry.values.contains(.videoFormatChanged))
    }

    @Test("Presentation drift before provider prewarm is terminal and never starts carrier")
    @MainActor
    func presentationDriftBeforeProviderPrewarm() async throws {
        let fixture = try makeSession()
        let expected = HybridPlaybackSessionError
            .carrierPresentationContractChanged
        var validationCount = 0

        await #expect(throws: expected) {
            try await fixture.session.prepare(
                timeout: 1
            ) {
                validationCount += 1
                if validationCount == 2 {
                    throw expected
                }
            }
        }

        #expect(validationCount == 2)
        #expect(!fixture.provider.snapshot().prepared)
        #expect(!fixture.transport.didStart)
        #expect(fixture.transport.didStop)
        #expect(fixture.renderSurface.flushCount == 1)
        #expect(fixture.session.state == .failed(expected))
    }

    @Test("Presentation drift after provider prewarm is terminal before carrier startup")
    @MainActor
    func presentationDriftAfterProviderPrewarm() async throws {
        let fixture = try makeSession()
        let expected = HybridPlaybackSessionError
            .carrierPresentationContractChanged
        var validationCount = 0

        await #expect(throws: expected) {
            try await fixture.session.prepare(
                timeout: 1
            ) {
                validationCount += 1
                if validationCount == 3 {
                    throw expected
                }
            }
        }

        #expect(validationCount == 3)
        #expect(fixture.provider.snapshot().prepared)
        #expect(!fixture.transport.didStart)
        #expect(fixture.transport.didStop)
        #expect(fixture.renderSurface.flushCount == 1)
        #expect(fixture.session.state == .failed(expected))
    }

    @Test("Hybrid telemetry emits immediate transport changes and at most one clock sample per second")
    @MainActor
    func structuredTelemetryTriggerCadence() async throws {
        let fixture = try makeSession()
        defer { fixture.session.stop() }
        let telemetry = HybridTelemetryTriggerRecorder()
        fixture.session.telemetryDidChange = {
            telemetry.record($0)
        }

        try await fixture.session.prepare(timeout: 1)
        #expect(
            telemetry.values.contains { trigger in
                guard case .carrierReady(let point) = trigger else {
                    return false
                }
                return point.generation == 0
                    && point.segmentIndex == 0
            }
        )
        #expect(
            telemetry.values.contains { trigger in
                guard case .videoFirstFrameReady(let point) =
                        trigger else {
                    return false
                }
                return point.generation == 0
                    && point.framePresentationTimeSeconds == 0
            }
        )
        #expect(
            telemetry.values.contains { trigger in
                guard case .playbackStarted(let point) =
                        trigger else {
                    return false
                }
                return point.generation == 0
            }
        )
        #expect(
            telemetry.values.contains { trigger in
                if case .periodicSample = trigger {
                    return true
                }
                return false
            }
        )
        telemetry.removeAll()

        fixture.session.handleClockTick(
            CMTime(
                seconds: 0.5,
                preferredTimescale: 600
            )
        )
        #expect(
            !telemetry.values.contains { trigger in
                if case .periodicSample = trigger {
                    return true
                }
                return false
            }
        )

        fixture.session.handleClockTick(
            CMTime(
                seconds: 1,
                preferredTimescale: 600
            )
        )
        #expect(
            telemetry.values.filter {
                if case .periodicSample = $0 {
                    return true
                }
                return false
            }.count == 1
        )

        try fixture.session.play()
        #expect(
            telemetry.values.contains(.transportChanged)
        )
    }

    @Test("Carrier completion is exact, stale post-seek EOS is ignored, and true EOS resets")
    @MainActor
    func carrierCompletionStateAndStaleSeekReset() async throws {
        let fixture = try makeSession()
        defer { fixture.session.stop() }
        let telemetry = HybridTelemetryTriggerRecorder()
        fixture.session.telemetryDidChange = {
            telemetry.record($0)
        }
        try await fixture.session.prepare(timeout: 1)
        telemetry.removeAll()
        let item = try #require(
            fixture.session.avPlayer.currentItem
        )
        let unrelatedItem = AVPlayerItem(
            asset: AVURLAsset(
                url: URL(
                    string: "https://example.invalid/unrelated.m3u8"
                )!
            )
        )

        fixture.transport.setCurrentTime(
            CMTime(
                seconds: 5.1,
                preferredTimescale: 600
            )
        )
        NotificationCenter.default.post(
            name: AVPlayerItem.didPlayToEndTimeNotification,
            object: unrelatedItem
        )
        #expect(fixture.session.state == .ready(generation: 0))
        #expect(telemetry.values.isEmpty)

        try fixture.session.setRate(1.5)

        NotificationCenter.default.post(
            name: AVPlayerItem.didPlayToEndTimeNotification,
            object: item
        )

        try await waitUntil {
            fixture.session.state == .ended(generation: 0)
        }

        #expect(fixture.session.state == .ended(generation: 0))
        #expect(fixture.session.avPlayer.rate == 0)
        #expect(
            fixture.session.avPlayer.timeControlStatus == .paused
        )
        #expect(
            telemetry.values.filter { trigger in
                if case .sessionEnded(.playbackCompleted) = trigger {
                    return true
                }
                return false
            }.count == 1
        )

        let target = CMTime(
            seconds: 1.25,
            preferredTimescale: 600
        )
        let result = try await fixture.session.seek(
            to: target,
            timeout: 1
        )
        #expect(
            result == .applied(
                generation: 1,
                target: target
            )
        )
        #expect(fixture.session.state == .ready(generation: 1))
        #expect(fixture.session.avPlayer.rate == 1.5)
        #expect(
            fixture.session.avPlayer.timeControlStatus != .paused
        )

        // This is the exact carrier item's delayed generation-zero EOS, now
        // delivered after the explicit seek established generation one. The
        // actual carrier clock is at the new target, so it must not terminate
        // the new generation.
        NotificationCenter.default.post(
            name: AVPlayerItem.didPlayToEndTimeNotification,
            object: item
        )
        #expect(fixture.session.state == .ready(generation: 1))
        #expect(
            telemetry.values.filter { trigger in
                if case .sessionEnded(.playbackCompleted) = trigger {
                    return true
                }
                return false
            }.count == 1
        )

        fixture.transport.setCurrentTime(
            CMTime(
                seconds: 5.2,
                preferredTimescale: 600
            )
        )
        NotificationCenter.default.post(
            name: AVPlayerItem.didPlayToEndTimeNotification,
            object: item
        )
        NotificationCenter.default.post(
            name: AVPlayerItem.didPlayToEndTimeNotification,
            object: item
        )
        try await waitUntil {
            fixture.session.state == .ended(generation: 1)
        }
        #expect(fixture.session.state == .ended(generation: 1))
        #expect(fixture.session.avPlayer.rate == 0)
        #expect(
            telemetry.values.filter { trigger in
                if case .sessionEnded(.playbackCompleted) = trigger {
                    return true
                }
                return false
            }.count == 2
        )
    }

    @Test("Carrier completion drains the coalesced exact-end video demand before ended")
    @MainActor
    func carrierCompletionDrainsPendingDecodeDemand() async throws {
        let fixture = try makeSession()
        defer { fixture.session.stop() }
        let telemetry = HybridTelemetryTriggerRecorder()
        fixture.session.telemetryDidChange = {
            telemetry.record($0)
        }
        try await fixture.session.prepare(timeout: 1)
        try await waitUntil {
            !fixture.provider.snapshot().demands.isEmpty
        }
        telemetry.removeAll()

        let gate = RestartGate()
        fixture.provider.configureDecodeDemandGate(gate)
        fixture.provider.configureTerminalDecodeDemandFrameTime(5.0)

        fixture.session.handleClockTick(
            CMTime(
                seconds: 1,
                preferredTimescale: 600
            )
        )
        try await waitUntil { gate.isWaiting }

        // This later ordinary clock request must be coalesced into the exact
        // finite-end request while the first provider call remains in flight.
        fixture.session.handleClockTick(
            CMTime(
                seconds: 3,
                preferredTimescale: 600
            )
        )
        fixture.transport.setCurrentTime(
            CMTime(
                seconds: 5.25,
                preferredTimescale: 600
            )
        )
        let item = try #require(
            fixture.session.avPlayer.currentItem
        )
        NotificationCenter.default.post(
            name: AVPlayerItem.didPlayToEndTimeNotification,
            object: item
        )

        #expect(fixture.session.state == .ready(generation: 0))
        #expect(
            !telemetry.values.contains { trigger in
                if case .sessionEnded(.playbackCompleted) = trigger {
                    return true
                }
                return false
            }
        )

        gate.release()
        try await waitUntil {
            fixture.session.state == .ended(generation: 0)
        }

        let demandSeconds = fixture.provider.snapshot().demands.map(
            \.seconds
        )
        #expect(
            abs(try #require(demandSeconds.last) - 5.25)
                < 0.000_001
        )
        #expect(
            !demandSeconds.contains {
                abs($0 - 3.25) < 0.000_001
            }
        )
        #expect(
            abs(
                try #require(
                    fixture.renderSurface.frames.last?
                        .presentationTime.seconds
                ) - 5.0
            ) < 0.000_001
        )
        #expect(
            telemetry.values.filter { trigger in
                if case .sessionEnded(.playbackCompleted) = trigger {
                    return true
                }
                return false
            }.count == 1
        )
    }

    @Test(
        "Carrier completion has no elapsed-time terminal while the typed provider drain remains active"
    )
    @MainActor
    func carrierCompletionWaitsPastFormerDrainDeadline()
        async throws
    {
        let fixture = try makeSession()
        defer { fixture.session.stop() }
        try await fixture.session.prepare(timeout: 1)
        try await waitUntil {
            !fixture.provider.snapshot().demands.isEmpty
        }

        let gate = RestartGate()
        defer { gate.release() }
        fixture.provider.configureDecodeDemandGate(gate)
        fixture.provider
            .configureTerminalDecodeDemandFrameTime(5.0)
        fixture.session.handleClockTick(
            CMTime(
                seconds: 1,
                preferredTimescale: 600
            )
        )
        try await waitUntil { gate.isWaiting }

        fixture.transport.setCurrentTime(
            CMTime(
                seconds: 5.25,
                preferredTimescale: 600
            )
        )
        let item = try #require(
            fixture.session.avPlayer.currentItem
        )
        NotificationCenter.default.post(
            name:
                AVPlayerItem
                    .didPlayToEndTimeNotification,
            object: item
        )

        try await Task.sleep(
            nanoseconds: 5_250_000_000
        )
        #expect(
            fixture.session.state
                == .ready(generation: 0)
        )
        #expect(gate.isWaiting)

        gate.release()
        try await waitUntil {
            fixture.session.state
                == .ended(generation: 0)
        }
    }

    @Test("Seek supersedes a provisional carrier-completion video drain")
    @MainActor
    func seekSupersedesCarrierCompletionDrain() async throws {
        let fixture = try makeSession()
        defer { fixture.session.stop() }
        let telemetry = HybridTelemetryTriggerRecorder()
        fixture.session.telemetryDidChange = {
            telemetry.record($0)
        }
        try await fixture.session.prepare(timeout: 1)
        try await waitUntil {
            !fixture.provider.snapshot().demands.isEmpty
        }
        telemetry.removeAll()

        let gate = RestartGate()
        defer { gate.release() }
        fixture.provider.configureDecodeDemandGate(gate)
        fixture.session.handleClockTick(
            CMTime(
                seconds: 1,
                preferredTimescale: 600
            )
        )
        try await waitUntil { gate.isWaiting }

        fixture.transport.setCurrentTime(
            CMTime(
                seconds: 5.25,
                preferredTimescale: 600
            )
        )
        let item = try #require(
            fixture.session.avPlayer.currentItem
        )
        NotificationCenter.default.post(
            name: AVPlayerItem.didPlayToEndTimeNotification,
            object: item
        )
        #expect(fixture.session.state == .ready(generation: 0))

        let target = CMTime(
            seconds: 1.25,
            preferredTimescale: 600
        )
        let seekTask = Task { @MainActor in
            try await fixture.session.seek(
                to: target,
                timeout: 1
            )
        }
        try await waitUntil {
            if case .seeking(
                let generation,
                let observedTarget
            ) = fixture.session.state {
                return generation == 1
                    && observedTarget == target
            }
            return false
        }
        gate.release()

        #expect(
            try await seekTask.value
                == .applied(generation: 1, target: target)
        )
        #expect(fixture.session.state == .ready(generation: 1))
        #expect(
            !telemetry.values.contains { trigger in
                if case .sessionEnded(.playbackCompleted) = trigger {
                    return true
                }
                return false
            }
        )
    }

    @Test("Carrier completion clock admission is finite and tightly bounded")
    func carrierCompletionClockAdmission() {
        let duration = CMTime(
            seconds: 5.25,
            preferredTimescale: 600
        )
        #expect(
            HybridPlaybackSession.isCarrierClockAtFiniteEnd(
                currentTime: CMTime(
                    seconds: 5.1,
                    preferredTimescale: 600
                ),
                duration: duration
            )
        )
        #expect(
            !HybridPlaybackSession.isCarrierClockAtFiniteEnd(
                currentTime: CMTime(
                    seconds: 4.99,
                    preferredTimescale: 600
                ),
                duration: duration
            )
        )
        #expect(
            !HybridPlaybackSession.isCarrierClockAtFiniteEnd(
                currentTime: CMTime(
                    seconds: 5.51,
                    preferredTimescale: 600
                ),
                duration: duration
            )
        )
        #expect(
            !HybridPlaybackSession.isCarrierClockAtFiniteEnd(
                currentTime: .indefinite,
                duration: duration
            )
        )
        #expect(
            !HybridPlaybackSession.isCarrierClockAtFiniteEnd(
                currentTime: duration,
                duration: .indefinite
            )
        )
    }

    @Test("Explicit seek creates one provider and renderer generation")
    @MainActor
    func explicitSeekGeneration() async throws {
        let fixture = try makeSession()
        defer { fixture.session.stop() }
        let telemetry = HybridTelemetryTriggerRecorder()
        fixture.session.telemetryDidChange = {
            telemetry.record($0)
        }
        try await fixture.session.prepare(timeout: 1)
        telemetry.removeAll()

        let target = CMTime(
            seconds: 4.5,
            preferredTimescale: 600
        )
        let result = try await fixture.session.seek(
            to: target,
            timeout: 1
        )

        #expect(result == .applied(
            generation: 1,
            target: target
        ))
        #expect(fixture.session.state == .ready(generation: 1))
        #expect(fixture.renderSurface.generation == 1)
        let hasGenerationOneFrame =
            fixture.renderSurface.frames.contains(where: {
            $0.generation == 1
                && $0.presentationTime.seconds == 4
            })
        #expect(hasGenerationOneFrame)
        #expect(fixture.transport.seekTargets == [target])
        let provider = fixture.provider.snapshot()
        #expect(provider.segments == [1])
        #expect(provider.restarts.count == 1)
        #expect(provider.restarts.first == .userSeek(
            target: target,
            segmentIndex: 1,
            generation: 1
        ))
        #expect(
            telemetry.values.contains { trigger in
                guard case .seekRequested(let point) = trigger else {
                    return false
                }
                return point.generation == 1
                    && point.segmentIndex == 1
                    && point.targetSeconds == 4.5
            }
        )
        #expect(
            telemetry.values.contains { trigger in
                guard case .carrierReady(let point) = trigger else {
                    return false
                }
                return point.generation == 1
            }
        )
        #expect(
            telemetry.values.contains { trigger in
                guard case .seekVideoReady(let point) = trigger else {
                    return false
                }
                return point.generation == 1
                    && point.framePresentationTimeSeconds == 4
            }
        )
    }

    @Test("Seek decoder preroll is rejected before renderer admission")
    @MainActor
    func seekPrerollAdmission() async throws {
        let fixture = try makeSession()
        defer { fixture.session.stop() }
        try await fixture.session.prepare(timeout: 1)

        let prerollTimes = (0..<64).map { Double($0) * 0.05 }
        fixture.provider.configurePreparedGenerationFrameTimes(
            prerollTimes + [4.5]
        )
        let target = CMTime(
            seconds: 4.5,
            preferredTimescale: 600
        )
        let result = try await fixture.session.seek(
            to: target,
            timeout: 1
        )

        #expect(result == .applied(
            generation: 1,
            target: target
        ))
        #expect(
            fixture.session.readinessPrerollFramesRejected == 64
        )
        #expect(fixture.renderSurface.frames.count == 1)
        #expect(
            fixture.renderSurface.frames.first?.presentationTime
                == target
        )
    }

    @Test("Carrier lands before target decode can fill the renderer mailbox")
    @MainActor
    func carrierSeekPrecedesTargetDecodePressure() async throws {
        let fixture = try makeSession(
            retainsFramesUntilCapacityCallback: true
        )
        defer { fixture.session.stop() }
        try await fixture.session.prepare(timeout: 1)
        fixture.renderSurface.releaseRetainedFrames()

        let target = CMTime(
            seconds: 4.5,
            preferredTimescale: 600
        )
        fixture.provider.configurePreparedGenerationFrameTimes(
            Array(repeating: target.seconds, count: 120)
        )
        fixture.transport.onSeek = { _ in
            fixture.renderSurface
                .synchronouslyReleasesAcceptedFrames = true
        }

        let seekTask = Task { @MainActor in
            try await fixture.session.seek(
                to: target,
                timeout: 2
            )
        }
        let carrierLandedBeforePressure = await waitUntilResult {
            fixture.transport.seekTargets == [target]
        }
        if !carrierLandedBeforePressure {
            fixture.renderSurface
                .synchronouslyReleasesAcceptedFrames = true
            fixture.renderSurface.releaseRetainedFrames()
        }
        let result = try await seekTask.value

        #expect(carrierLandedBeforePressure)
        #expect(result == .applied(
            generation: 1,
            target: target
        ))
        #expect(fixture.provider.snapshot().restarts.count == 1)
        #expect(fixture.relay.diagnostics.mailboxDepth == 0)
    }

    @Test("Rapid seeks keep one in-flight restart and only the latest pending target")
    @MainActor
    func rapidSeekCoalescing() async throws {
        let fixture = try makeSession()
        defer { fixture.session.stop() }
        try await fixture.session.prepare(timeout: 1)
        let gate = RestartGate()
        fixture.provider.configureRestartGate(gate)

        let targets = (0..<20).map { index in
            CMTime(
                seconds: 0.5 + Double(index) * 0.2,
                preferredTimescale: 600
            )
        }
        let first = Task { @MainActor in
            try await fixture.session.seek(
                to: targets[0],
                timeout: 2
            )
        }
        let firstRestartBlocked = await waitUntilResult {
            gate.isWaiting
        }
        #expect(firstRestartBlocked)

        let remaining = targets.dropFirst().map { target in
            Task { @MainActor in
                try await fixture.session.seek(
                    to: target,
                    timeout: 2
                )
            }
        }
        for _ in 0..<40 {
            await Task.yield()
        }
        gate.release()

        let firstResult = try await first.value
        var laterResults: [HybridPlaybackSeekResult] = []
        for task in remaining {
            laterResults.append(try await task.value)
        }

        #expect(firstResult.isSuperseded)
        let intermediateSeeksWereSuperseded =
            laterResults.dropLast().allSatisfy {
                $0.isSuperseded
            }
        #expect(intermediateSeeksWereSuperseded)
        #expect(laterResults.last == .applied(
            generation: 2,
            target: targets.last!
        ))
        #expect(fixture.provider.snapshot().restarts.count == 2)
        #expect(fixture.transport.seekTargets == [
            targets[0],
            targets.last!,
        ])
    }

    @Test("A blocked provider restart survives the legacy seek deadline")
    @MainActor
    func providerRestartSurvivesSeekDeadline() async throws {
        let fixture = try makeSession()
        defer { fixture.session.stop() }
        try await fixture.session.prepare(timeout: 1)
        let gate = RestartGate()
        fixture.provider.configureRestartGate(gate)
        let target = CMTime(
            seconds: 4.5,
            preferredTimescale: 600
        )

        let seek = Task { @MainActor in
            try await fixture.session.seek(
                to: target,
                timeout: 0.05
            )
        }
        let restartBlocked = await waitUntilResult {
            gate.isWaiting
        }
        #expect(restartBlocked)
        try await Task.sleep(
            nanoseconds: 100_000_000
        )
        #expect(
            fixture.session.state
                == .seeking(
                    generation: 1,
                    target: target
                )
        )
        #expect(!fixture.transport.didStop)

        gate.release()

        #expect(
            try await seek.value
                == .applied(
                    generation: 1,
                    target: target
                )
        )
        #expect(
            fixture.session.state
                == .ready(generation: 1)
        )
    }

    @Test("A blocked production fresh open remains pending until it progresses")
    @MainActor
    func productionRestartWaitsForFreshOpenProgress() async throws {
        let sourceData = makeAnalysisWAV(seconds: 5.25)
        let initialDemuxer = Demuxer()
        try initialDemuxer.open(
            reader: DataIOReader(data: sourceData)
        )
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: 5.25,
                preferredTimescale: 90_000
            )
        )
        let freshOpenGate = RestartGate()
        let freshReader = CloseProbeIOReader(data: sourceData)
        let pump = try BlackCarrierMediaFanoutPump(
            demuxer: initialDemuxer,
            timeline: timeline,
            freshDemuxerFactory: {
                freshOpenGate.wait()
                let fresh = Demuxer()
                try fresh.open(reader: freshReader)
                fresh.adoptOwnedReader(freshReader)
                return fresh
            },
            ownsInitialDemuxer: true
        )
        let provider = try BlackCarrierLazyCompositeProvider(
            videoProvider: try BlackCarrierVideoProvider(
                timeline: timeline
            ),
            pump: pump
        )
        let relay = HybridPlaybackFrameRelay()
        let transport = Transport()
        transport.onStop = { provider.close() }
        let session = try HybridPlaybackSession(
            provider: provider,
            transport: transport,
            renderSurface: RenderSurface(),
            timeline: timeline,
            relay: relay,
            allowsAudioOnlyCarrier: true,
            internalPresentationRebuildTimeout: 0.05
        )
        defer {
            freshOpenGate.release()
            session.stop()
            provider.close()
        }
        try await session.prepare(timeout: 1)

        session.handleCarrierStall()
        let freshOpenBlocked = await waitUntilResult {
            freshOpenGate.isWaiting
        }
        #expect(freshOpenBlocked, "Production fresh open was not entered")
        try await Task.sleep(
            nanoseconds: 100_000_000
        )
        if case .failed = session.state {
            Issue.record(
                "Elapsed time published a terminal while fresh open was progressing"
            )
        }
        #expect(!transport.didStop)
        #expect(freshOpenGate.isWaiting)
        #expect(pump.generation == 0)

        freshOpenGate.release()
        let recovered = await waitUntilResult {
            session.state
                == .ready(generation: 1)
        }
        #expect(recovered)
        #expect(pump.generation == 1)
        #expect(!freshReader.wasClosed)
    }

    @Test("Paused seek enters restart before a blocked decode demand retires")
    @MainActor
    func pausedSeekPreemptsBlockedDecodeDemand() async throws {
        let fixture = try makeSession()
        defer { fixture.session.stop() }
        try await fixture.session.prepare(timeout: 1)
        try await waitUntil {
            !fixture.provider.snapshot().demands.isEmpty
        }
        try fixture.session.pause()

        let gate = RestartGate()
        defer { gate.release() }
        fixture.provider.configureDecodeDemandGate(gate)
        fixture.session.handleClockTick(
            CMTime(
                seconds: 1,
                preferredTimescale: 600
            )
        )
        try await waitUntil { gate.isWaiting }

        let target = CMTime(
            seconds: 1.25,
            preferredTimescale: 600
        )
        let seek = Task { @MainActor in
            try await fixture.session.seek(
                to: target,
                timeout: 2
            )
        }

        // Production restart marks the retiring progressive demuxer closed
        // before waiting on its pump lock. Reaching this provider call while
        // the old demand is still blocked proves the control operation is no
        // longer queued behind that demand on the coordinator actor.
        let restartEnteredBeforeDemandRetired = await waitUntilResult {
            !fixture.provider.snapshot().restarts.isEmpty
                && gate.isWaiting
        }
        #expect(restartEnteredBeforeDemandRetired)

        gate.release()
        #expect(
            try await seek.value
                == .applied(generation: 1, target: target)
        )
        #expect(fixture.session.state == .ready(generation: 1))
        #expect(fixture.provider.snapshot().restarts.count == 1)
    }

    @Test("Playback stall rebuild remains pending without a real frame")
    @MainActor
    func playbackStallRebuildDoesNotTimeOut() async throws {
        let fixture = try makeSession(
            internalPresentationRebuildTimeout: 0.05
        )
        defer { fixture.session.stop() }
        try await fixture.session.prepare(timeout: 1)
        fixture.provider.configurePreparedGenerationFrameTimes([])

        fixture.session.handleCarrierStall()
        let rebuildStarted = await waitUntilResult {
            if case .seeking = fixture.session.state {
                return true
            }
            return false
        }
        #expect(rebuildStarted)
        try await Task.sleep(nanoseconds: 100_000_000)
        if case .failed = fixture.session.state {
            Issue.record(
                "Elapsed presentation wait terminated playback"
            )
        }
        #expect(!fixture.transport.didStop)
    }

    @Test("Time jump rebuild remains pending without a real frame")
    @MainActor
    func timeJumpRebuildDoesNotTimeOut() async throws {
        let fixture = try makeSession(
            internalPresentationRebuildTimeout: 0.05
        )
        defer { fixture.session.stop() }
        try await fixture.session.prepare(timeout: 1)
        fixture.provider.configurePreparedGenerationFrameTimes([])
        fixture.session.handleClockTick(.zero)
        fixture.transport.setCurrentTime(
            CMTime(seconds: 1, preferredTimescale: 600)
        )
        let item = try #require(fixture.session.avPlayer.currentItem)

        NotificationCenter.default.post(
            name: AVPlayerItem.timeJumpedNotification,
            object: item
        )
        let rebuildStarted = await waitUntilResult {
            if case .seeking = fixture.session.state {
                return true
            }
            return false
        }
        #expect(rebuildStarted)
        try await Task.sleep(nanoseconds: 100_000_000)
        if case .failed = fixture.session.state {
            Issue.record(
                "Elapsed time-jump presentation wait terminated playback"
            )
        }
        #expect(!fixture.transport.didStop)
    }

    @Test("Media-selection rebuild remains pending without a real frame")
    @MainActor
    func mediaSelectionRebuildDoesNotTimeOut() async throws {
        let fixture = try makeSession(
            internalPresentationRebuildTimeout: 0.05
        )
        defer { fixture.session.stop() }
        try await fixture.session.prepare(timeout: 1)
        fixture.provider.configurePreparedGenerationFrameTimes([])

        fixture.session.handleCarrierMediaSelectionChange(
            selectedAudioOptionIndex: nil
        )
        let rebuildStarted = await waitUntilResult {
            if case .seeking = fixture.session.state {
                return true
            }
            return false
        }
        #expect(rebuildStarted)
        try await Task.sleep(nanoseconds: 100_000_000)
        if case .failed = fixture.session.state {
            Issue.record(
                "Elapsed media-selection presentation wait terminated playback"
            )
        }
        #expect(!fixture.transport.didStop)
    }

    @Test("Route implementation reports decoder failure and tears down its generation")
    @MainActor
    func decoderFailureIsReportedToUnifiedCoordinator() async throws {
        let fixture = try makeSession()
        try await fixture.session.prepare(timeout: 1)

        fixture.relay.fail(.packetTimestampMissing)
        try await waitUntil {
            if case .failed = fixture.session.state {
                return true
            }
            return false
        }

        #expect(fixture.session.state == .failed(
            .decoderFailed(
                reason: HybridVideoDecodeSinkError
                    .packetTimestampMissing.localizedDescription
            )
        ))
        #expect(fixture.transport.didStop)
        #expect(fixture.renderSurface.flushCount == 1)
    }

    @Test("Pixel conversion failure is a typed permanent capability terminal")
    @MainActor
    func pixelConversionFailureIsCapabilityTerminal()
        async throws
    {
        let fixture = try makeSession()
        try await fixture.session.prepare(timeout: 1)

        fixture.relay.fail(
            .decoderFailed(.pixelBufferConversionFailed)
        )
        try await waitUntil {
            if case .failed = fixture.session.state {
                return true
            }
            return false
        }

        guard case .failed(.providerFailed(let evidence)) =
                fixture.session.state else {
            Issue.record(
                "Expected typed pixel conversion capability"
            )
            return
        }
        #expect(evidence.category == .unsupportedCapability)
        #expect(
            evidence.caseCode
                == "videoDecoder.pixelBufferConversionFailed"
        )
        #expect(fixture.transport.didStop)
        #expect(fixture.renderSurface.flushCount == 1)
    }

    @Test("Local compressed queue failure is a permanent invariant terminal")
    @MainActor
    func localQueueFailureIsInvariantTerminal() async throws {
        let fixture = try makeSession()
        try await fixture.session.prepare(timeout: 1)

        fixture.relay.fail(.packetSpoolCleanupFailed)
        try await waitUntil {
            if case .failed = fixture.session.state {
                return true
            }
            return false
        }

        guard case .failed(.providerFailed(let evidence)) =
                fixture.session.state else {
            Issue.record(
                "Expected typed local queue invariant terminal"
            )
            return
        }
        #expect(evidence.category == .invariant)
        #expect(
            evidence.caseCode
                == "progressive.videoDecoder.localQueueInvariant"
        )
        let publicFailure = AetherPlaybackSession.hybridFailure(
            evidence: evidence
        )
        #expect(publicFailure.kind == .invariantViolation)
        #expect(
            PlaybackRecoveryDecision.resolve(
                context: AetherPlaybackRecoveryContext(
                    failure: publicFailure,
                    activeRoute: .hybridCarrier,
                    positivelyAdmittedAlternateRoute: nil,
                    transportAttempt: 100,
                    sameRouteRebuildCount: 0,
                    routeTransitionCount: 0,
                    elapsedSeconds: 10_000
                )
            ) == .terminate
        )
        #expect(fixture.transport.didStop)
        #expect(fixture.renderSurface.flushCount == 1)
    }

    @Test("Carrier stall rebuilds sample-buffer presentation in a new generation")
    @MainActor
    func carrierStallRebuildsGeneration() async throws {
        let fixture = try makeSession()
        defer { fixture.session.stop() }
        try await fixture.session.prepare(timeout: 1)

        #expect(
            !fixture.provider
                .isCarrierSegmentProductionActive
        )
        fixture.session.handleCarrierStall()
        try await waitUntil {
            fixture.session.state == .ready(generation: 1)
        }

        #expect(fixture.provider.snapshot().restarts.count == 1)
        #expect(fixture.renderSurface.generation == 1)
        #expect(fixture.transport.seekTargets.isEmpty)
    }

    @Test("Carrier stall preserves the generation while segment production is active")
    @MainActor
    func carrierStallDuringSegmentProductionKeepsGeneration() async throws {
        let fixture = try makeSession()
        defer { fixture.session.stop() }
        try await fixture.session.prepare(timeout: 1)
        fixture.provider
            .configureCarrierSegmentProductionActive(true)

        fixture.session.handleCarrierStall()
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(
            fixture.session.state
                == .ready(generation: 0)
        )
        #expect(fixture.provider.snapshot().restarts.isEmpty)
        #expect(fixture.renderSurface.generation == 0)
        #expect(fixture.transport.seekTargets.isEmpty)
    }

    @Test("Carrier media-selection change flushes into a new video generation")
    @MainActor
    func mediaSelectionChangeRebuildsGeneration() async throws {
        let fixture = try makeSession()
        defer { fixture.session.stop() }
        try await fixture.session.prepare(timeout: 1)

        fixture.session.handleCarrierMediaSelectionChange()
        try await waitUntil {
            fixture.session.state == .ready(generation: 1)
        }

        #expect(fixture.provider.snapshot().restarts.count == 1)
        #expect(fixture.renderSurface.generation == 1)
        #expect(fixture.transport.seekTargets.isEmpty)
    }

    @Test("Replacing the carrier item after binding is a terminal typed failure")
    @MainActor
    func carrierItemReplacementTerminates() async throws {
        let fixture = try makeSession()
        try await fixture.session.prepare(timeout: 1)
        let replacement = AVPlayerItem(asset: AVURLAsset(
            url: URL(
                string:
                    "https://example.invalid/replaced-carrier.m3u8"
            )!
        ))
        fixture.transport.avPlayer.replaceCurrentItem(
            with: replacement
        )

        fixture.session.handleClockTick(.zero)

        #expect(fixture.session.state == .failed(
            .presentationFailed(.carrierBindingChanged)
        ))
        #expect(fixture.transport.didStop)
        #expect(fixture.renderSurface.flushCount == 1)
    }

    @Test("Runtime host presentation drift is terminal on the next carrier clock validation")
    @MainActor
    func runtimePresentationDriftTerminates()
        async throws
    {
        let fixture = try makeSession()
        let presentationContract =
            HybridPresentationContractState()
        fixture.session.runtimePresentationValidation = {
            guard presentationContract.isValid else {
                throw HybridPlaybackSessionError
                    .carrierPresentationContractChanged
            }
        }
        try await fixture.session.prepare(timeout: 1)
        presentationContract.isValid = false

        fixture.session.handleClockTick(.zero)

        #expect(fixture.session.state == .failed(
            .carrierPresentationContractChanged
        ))
        #expect(fixture.transport.didStop)
        #expect(fixture.renderSurface.flushCount == 1)
    }

    @Test("Provider invalidation terminates a paused session without waiting for decode demand")
    @MainActor
    func providerInvalidationTerminatesPausedSession()
        async throws
    {
        let fixture = try makeSession()
        try await fixture.session.prepare(timeout: 1)
        try fixture.session.pause()
        let expected = HybridPlaybackSessionError
            .hlsPreflightGenerationInvalidated(
                .credentialRejected(
                    statusCode: 403,
                    resource: .audioSegment(
                        renditionOrdinal: 0,
                        index: 3
                    )
                )
            )

        fixture.provider.failTerminally(expected)
        try await waitUntil {
            fixture.session.state == .failed(expected)
        }

        #expect(fixture.session.state == .failed(expected))
        #expect(fixture.transport.didStop)
        #expect(fixture.renderSurface.flushCount == 1)
    }

    @Test("Stop removes the session from frame relay")
    @MainActor
    func stopDetachesFrames() async throws {
        let fixture = try makeSession()
        try await fixture.session.prepare(timeout: 1)
        fixture.session.stop()
        let frameCount = fixture.renderSurface.frames.count

        fixture.relay.emit(try makeHybridPlaybackSessionFrame(
            time: 1,
            generation: 0
        ))
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(fixture.session.state == .stopped)
        #expect(fixture.renderSurface.frames.count == frameCount)
        #expect(fixture.transport.didStop)
    }

    @Test("Managed seek time jump is suppressed only near its live target")
    func managedSeekTimeJumpSuppression() {
        let target = CMTime(
            seconds: 4.5,
            preferredTimescale: 600
        )
        #expect(HybridPlaybackSession.shouldSuppressObservedTimeJump(
            observed: CMTime(
                seconds: 4.6,
                preferredTimescale: 600
            ),
            managedTarget: target,
            suppressionDeadline: 20,
            now: 19
        ))
        #expect(!HybridPlaybackSession.shouldSuppressObservedTimeJump(
            observed: CMTime(
                seconds: 5.1,
                preferredTimescale: 600
            ),
            managedTarget: target,
            suppressionDeadline: 20,
            now: 19
        ))
        #expect(!HybridPlaybackSession.shouldSuppressObservedTimeJump(
            observed: target,
            managedTarget: target,
            suppressionDeadline: 20,
            now: 21
        ))
    }

    @Test("Invalid playback rate fails with its own typed error")
    @MainActor
    func invalidPlaybackRate() async throws {
        let fixture = try makeSession()
        defer { fixture.session.stop() }
        try await fixture.session.prepare(timeout: 1)

        #expect(throws: HybridPlaybackSessionError.invalidRate) {
            try fixture.session.setRate(.nan)
        }
        #expect(throws: HybridPlaybackSessionError.invalidRate) {
            try fixture.session.setRate(-1)
        }
        #expect(fixture.session.state == .ready(generation: 0))
    }

    @Test("Hybrid route play canonicalizes a stale non-unit rate")
    @MainActor
    func canonicalPlayResetsHybridResumeRate() async throws {
        let fixture = try makeSession()
        defer { fixture.session.stop() }
        try await fixture.session.prepare(timeout: 1)

        try fixture.session.setRate(1.5)
        #expect(fixture.session.transportWantsPlayback)
        #expect(fixture.session.transportResumeRate == 1.5)
        try fixture.session.pause()
        #expect(!fixture.session.transportWantsPlayback)
        #expect(fixture.session.transportResumeRate == 1.5)

        try fixture.session.play()
        #expect(fixture.session.transportWantsPlayback)
        #expect(fixture.session.transportResumeRate == 1)

        // The unified outer session preserves an explicit non-1x command by
        // applying it after canonical play.
        try fixture.session.setRate(1.25)
        #expect(fixture.session.transportResumeRate == 1.25)
    }

    @Test("Repeated unit rate never synchronously samples provider telemetry")
    @MainActor
    func repeatedUnitRateDoesNotSynchronouslySampleProviderTelemetry()
        async throws
    {
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: 5.25,
                preferredTimescale: 90_000
            )
        )
        let relay = HybridPlaybackFrameRelay()
        let telemetryProbe = BlockingProviderTelemetryProbe()
        let provider = TelemetryProvider(
            relay: relay,
            timeline: timeline,
            telemetryProbe: telemetryProbe
        )
        let transport = Transport()
        let renderSurface = RenderSurface()
        let session = try HybridPlaybackSession(
            provider: provider,
            transport: transport,
            renderSurface: renderSurface,
            timeline: timeline,
            relay: relay
        )
        defer {
            telemetryProbe.release()
            session.telemetryDidChange = nil
            session.stop()
        }

        var transportChangeCount = 0
        session.telemetryDidChange = { trigger in
            // Production AetherHybridPlaybackSession builds a diagnostics
            // snapshot synchronously for every trigger. Reading these cached
            // properties here recreates that boundary without a public route.
            _ = session.carrierBandwidthTelemetry
            _ = session.realVideoBitrateTelemetry
            if trigger == .transportChanged {
                transportChangeCount += 1
            }
        }

        try await session.prepare(timeout: 1)
        try await waitUntil {
            telemetryProbe.hasReadStarted
        }
        #expect(
            session.carrierBandwidthTelemetry.state
                == .awaitingCarrierSegments
        )
        #expect(
            session.realVideoBitrateTelemetry.state
                == .awaitingCompressedPackets
        )

        try session.play()
        let validationCountBeforeRates =
            renderSurface.carrierClockValidationCount
        try session.setRate(1)
        try session.setRate(1)

        #expect(
            renderSurface.carrierClockValidationCount
                == validationCountBeforeRates + 2
        )
        #expect(transportChangeCount == 3)
        #expect(telemetryProbe.observedMainThreadReadCount == 0)
        #expect(session.state == .ready(generation: 0))

        telemetryProbe.release()
        try await waitUntil {
            session.carrierBandwidthTelemetry
                == telemetryProbe.carrier
                && session.realVideoBitrateTelemetry
                    == telemetryProbe.realVideo
        }
        #expect(telemetryProbe.observedMainThreadReadCount == 0)
    }

    @Test("Provider generation divergence is a terminal typed failure")
    @MainActor
    func providerGenerationDivergence() async throws {
        let fixture = try makeSession()
        try await fixture.session.prepare(timeout: 1)
        fixture.provider.forceRestartResult(.stale(
            currentGeneration: 99
        ))
        let target = CMTime(
            seconds: 4.5,
            preferredTimescale: 600
        )
        let expected = HybridPlaybackSessionError
            .generationDiverged(
                sessionGeneration: 1,
                providerGeneration: 99
            )

        await #expect(throws: expected) {
            try await fixture.session.seek(
                to: target,
                timeout: 1
            )
        }
        #expect(fixture.session.state == .failed(expected))
        #expect(fixture.transport.didStop)
        #expect(fixture.renderSurface.flushCount == 1)
    }

    @Test("Real video-only fixture composes carrier, decoder and sample-buffer surface")
    @MainActor
    func realVideoOnlyComposition() async throws {
        let sourceData = try BlackCarrierEncodedSample
            .verifiedMP4Data()
        let demuxer = Demuxer()
        try demuxer.open(
            reader: DataIOReader(data: sourceData)
        )
        let duration = demuxer.duration
        demuxer.close()
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: duration,
                preferredTimescale: 90_000
            )
        )
        let session = try await HybridPlaybackSession
            .makeSeekableVOD(
                source: .custom(
                    DataIOReader(data: sourceData),
                    formatHint: "mp4"
                ),
                options: LoadOptions(),
                timeline: timeline
            )
        defer { session.stop() }

        try await session.prepare(timeout: 10)

        #expect(session.state == .ready(generation: 0))
        #expect(session.avPlayer.currentItem != nil)
        let presentationView = try #require(
            session.presentationView
        )
        #expect(presentationView.diagnostics.generation == 0)
        #expect(
            abs(
                try #require(
                    presentationView.diagnostics
                        .lastEnqueuedTimeSeconds
                )
            ) < 0.000_001
        )
    }

    @MainActor
    private func makeSession(
        videoFormat: VideoFormat = .sdr,
        retainsFramesUntilCapacityCallback: Bool = false,
        synchronouslyReleasesAcceptedFrames: Bool = false,
        internalPresentationRebuildTimeout: TimeInterval = 15
    ) throws -> (
        session: HybridPlaybackSession,
        provider: Provider,
        transport: Transport,
        renderSurface: RenderSurface,
        relay: HybridPlaybackFrameRelay
    ) {
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: 5.25,
                preferredTimescale: 90_000
            )
        )
        let relay = HybridPlaybackFrameRelay()
        let provider = Provider(
            relay: relay,
            timeline: timeline,
            videoFormat: videoFormat
        )
        let transport = Transport()
        let renderSurface = RenderSurface()
        renderSurface.retainsAcceptedFramesUntilCapacityCallback =
            retainsFramesUntilCapacityCallback
        renderSurface.synchronouslyReleasesAcceptedFrames =
            synchronouslyReleasesAcceptedFrames
        let session = try HybridPlaybackSession(
            provider: provider,
            transport: transport,
            renderSurface: renderSurface,
            timeline: timeline,
            relay: relay,
            internalPresentationRebuildTimeout:
                internalPresentationRebuildTimeout
        )
        return (
            session,
            provider,
            transport,
            renderSurface,
            relay
        )
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<500 {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for hybrid session state")
    }

    @MainActor
    private func waitUntilResult(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}
