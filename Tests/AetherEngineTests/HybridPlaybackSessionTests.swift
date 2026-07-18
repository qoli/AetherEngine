import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import AetherEngine

private enum HybridPlaybackSessionFixtureError: Error {
    case pixelBufferCreationFailed
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
    private final class Provider:
        HybridCarrierTransportProvider,
        HybridAudioAnalysisSource,
        HybridAudioAnalysisPlaybackPressureSink,
        HybridPlaybackTerminalErrorSource,
        @unchecked Sendable
    {
        private let relay: HybridPlaybackFrameRelay
        private let timeline: BlackCarrierTimeline
        private let analysisData: Data?
        private let videoFormat: VideoFormat
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
        private var preparedGenerationFrameTimes: [Double]?
        private var terminalErrorHandler:
            (@Sendable (
                HybridPlaybackSessionError
            ) -> Void)?

        init(
            relay: HybridPlaybackFrameRelay,
            timeline: BlackCarrierTimeline,
            analysisData: Data? = nil,
            videoFormat: VideoFormat = .sdr
        ) {
            self.relay = relay
            self.timeline = timeline
            self.analysisData = analysisData
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
            analysisData == nil ? [] : [0]
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
            lock.unlock()
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
            lock.unlock()
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
            lock.unlock()
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
        let avPlayer = AVPlayer()
        private(set) var didStart = false
        private(set) var didStop = false
        private(set) var seekTargets: [CMTime] = []

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

        func seek(to time: CMTime) async -> Bool {
            seekTargets.append(time)
            return true
        }

        func stop() {
            didStop = true
            avPlayer.pause()
            avPlayer.replaceCurrentItem(with: nil)
        }
    }

    @MainActor
    private final class RenderSurface: HybridPlaybackRenderSurface {
        private(set) var generation: UInt64 = 0
        private(set) var videoFormat: VideoFormat?
        private(set) var frames: [DecodedVideoFrame] = []
        private(set) var carrierClockValidationCount = 0
        private(set) var boundItem: AVPlayerItem?
        private(set) var boundTimebase: CMTimebase?
        private(set) var flushCount = 0

        func beginGeneration(
            _ generation: UInt64,
            videoFormat: VideoFormat
        ) throws {
            self.generation = generation
            self.videoFormat = videoFormat
            frames.removeAll()
        }

        func enqueue(
            _ frame: DecodedVideoFrame
        ) throws -> HybridFrameEnqueueOutcome {
            guard frame.generation == generation else {
                return .staleGeneration
            }
            frames.append(frame)
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
            frames.removeAll()
        }

        func invalidate() {
            flush(removingDisplayedImage: true)
            boundItem = nil
            boundTimebase = nil
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

    @Test("Decoder failure is terminal and tears down transport and renderer")
    @MainActor
    func decoderFailureTerminates() async throws {
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

    @Test("Carrier stall rebuilds sample-buffer presentation in a new generation")
    @MainActor
    func carrierStallRebuildsGeneration() async throws {
        let fixture = try makeSession()
        defer { fixture.session.stop() }
        try await fixture.session.prepare(timeout: 1)

        fixture.session.handleCarrierStall()
        try await waitUntil {
            fixture.session.state == .ready(generation: 1)
        }

        #expect(fixture.provider.snapshot().restarts.count == 1)
        #expect(fixture.renderSurface.generation == 1)
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
        videoFormat: VideoFormat = .sdr
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
        let session = try HybridPlaybackSession(
            provider: provider,
            transport: transport,
            renderSurface: renderSurface,
            timeline: timeline,
            relay: relay
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
}
