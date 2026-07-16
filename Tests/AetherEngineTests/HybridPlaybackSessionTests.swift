import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import AetherEngine

private enum HybridPlaybackSessionFixtureError: Error {
    case pixelBufferCreationFailed
}

private func makeHybridPlaybackSessionFrame(
    time: Double,
    duration: Double = 1,
    generation: UInt64
) throws -> DecodedVideoFrame {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        16,
        16,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        [
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
        ] as CFDictionary,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw HybridPlaybackSessionFixtureError
            .pixelBufferCreationFailed
    }
    return DecodedVideoFrame(
        pixelBuffer: pixelBuffer,
        presentationTime: CMTime(
            seconds: time,
            preferredTimescale: 600
        ),
        duration: CMTime(
            seconds: duration,
            preferredTimescale: 600
        ),
        videoFormat: .sdr,
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
        hdr10PlusT35: nil,
        generation: generation
    )
}

@Suite("Hybrid playback session", .serialized)
struct HybridPlaybackSessionTests {
    private final class Provider:
        HybridCarrierTransportProvider,
        HybridAudioAnalysisSource,
        HybridAudioAnalysisPlaybackPressureSink,
        @unchecked Sendable
    {
        private let relay: HybridPlaybackFrameRelay
        private let timeline: BlackCarrierTimeline
        private let analysisData: Data?
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

        init(
            relay: HybridPlaybackFrameRelay,
            timeline: BlackCarrierTimeline,
            analysisData: Data? = nil
        ) {
            self.relay = relay
            self.timeline = timeline
            self.analysisData = analysisData
        }

        var hybridVideoFormat: VideoFormat? { .sdr }
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
                generation: 0
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
            lock.unlock()
            let segment = timeline.segments[segmentIndex]
            relay.emit(try makeHybridPlaybackSessionFrame(
                time: segment.startTime.seconds,
                duration: segment.duration.seconds,
                generation: generation
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
        private(set) var clockSamples: [CMTime] = []
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

        func advanceMasterClock(
            to time: CMTime,
            tolerance: CMTime
        ) {
            clockSamples.append(time)
        }

        func flush() {
            flushCount += 1
            frames.removeAll()
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
        let request = try AudioAnalysisRequest(
            audioTrackID: 0,
            range: 0.25..<0.75
        )
        let stream = try session.audioAnalysisStream(
            request: request
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
            fixture.renderSurface.clockSamples.contains {
                abs($0.seconds - 1) < 0.000_001
            }
        )
    }

    @Test("Explicit seek creates one provider and renderer generation")
    @MainActor
    func explicitSeekGeneration() async throws {
        let fixture = try makeSession()
        defer { fixture.session.stop() }
        try await fixture.session.prepare(timeout: 1)

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

    @Test("Real video-only fixture composes carrier, decoder and Metal surface")
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
        let metalView = try #require(session.metalPlayerView)
        #expect(metalView.diagnostics.generation == 0)
        #expect(
            abs(
                try #require(
                    metalView.diagnostics
                        .lastPresentedTimeSeconds
                )
            ) < 0.000_001
        )
    }

    @MainActor
    private func makeSession() throws -> (
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
            timeline: timeline
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
