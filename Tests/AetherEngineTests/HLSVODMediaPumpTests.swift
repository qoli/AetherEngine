import CoreMedia
import Foundation
import Libavcodec
import Libavformat
import XCTest
@testable import AetherEngine

final class HLSVODMediaPumpTests: XCTestCase {
    private final class FetchStore: @unchecked Sendable {
        private let lock = NSLock()
        private let responses: [
            URL: HLSVODOriginFetchResponse
        ]
        private var counts: [URL: Int] = [:]

        init(
            responses: [
                URL: HLSVODOriginFetchResponse
            ]
        ) {
            self.responses = responses
        }

        func response(
            for request: URLRequest
        ) throws -> HLSVODOriginFetchResponse {
            guard let url = request.url else {
                throw HLSVODOriginResourceError
                    .transportFailure
            }
            lock.lock()
            counts[url, default: 0] += 1
            let response = responses[url]
            lock.unlock()
            guard let response else {
                throw HLSVODOriginResourceError
                    .httpStatus(404)
            }
            return response
        }

        func count(for url: URL) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return counts[url, default: 0]
        }
    }

    private final class PacketCapture:
        @unchecked Sendable
    {
        private let lock = NSLock()
        private var presentationTimes: [Int64] = []

        func append(
            _ packet: UnsafeMutablePointer<AVPacket>
        ) {
            lock.lock()
            presentationTimes.append(packet.pointee.pts)
            lock.unlock()
        }

        var values: [Int64] {
            lock.lock()
            defer { lock.unlock() }
            return presentationTimes
        }
    }

    private final class FrameCapture:
        @unchecked Sendable
    {
        private let lock = NSLock()
        private var frames: [DecodedVideoFrame] = []

        func append(_ frame: DecodedVideoFrame) {
            lock.lock()
            frames.append(frame)
            lock.unlock()
        }

        var values: [CMTime] {
            lock.lock()
            defer { lock.unlock() }
            return frames.map(\.presentationTime)
        }

        var generations: [UInt64] {
            lock.lock()
            defer { lock.unlock() }
            return frames.map(\.generation)
        }
    }

    private actor FetchBlocker {
        private let store: FetchStore
        private let blockedURL: URL
        private var requestCount = 0
        private var isReleased = false

        init(
            store: FetchStore,
            blockedURL: URL
        ) {
            self.store = store
            self.blockedURL = blockedURL
        }

        func response(
            for request: URLRequest
        ) async throws
            -> HLSVODOriginFetchResponse
        {
            if request.url == blockedURL {
                requestCount += 1
                while !isReleased {
                    try await Task.sleep(
                        for: .milliseconds(5)
                    )
                }
            }
            return try store.response(
                for: request
            )
        }

        func waitForRequestCount(
            _ expected: Int
        ) async throws {
            while requestCount < expected {
                try await Task.sleep(
                    for: .milliseconds(5)
                )
            }
        }

        func release() {
            isReleased = true
        }

        var count: Int { requestCount }
    }

    private struct Fixture {
        let preflight: AetherHLSPlaybackPreflight
        let fetchStore: FetchStore
        let videoSegmentURLs: [URL]
        let audioSegmentURLs: [URL]
        let audioSegmentBaseDecodeTimes: [UInt64]
    }

    private struct MuxedFixture {
        let preflight: AetherHLSPlaybackPreflight
        let fetchStore: FetchStore
        let videoSegmentURLs: [URL]
    }

    func testIncrementalPumpNormalizesPacketsAndBuildsCarrierAudio()
        async throws
    {
        let fixture = try makeFixture()
        let capture = PacketCapture()
        let pump = try await HLSVODMediaPump.make(
            preflight: fixture.preflight,
            videoPacketSink: { packet in
                capture.append(packet)
            },
            fetchOverride: { request, _ in
                try fixture.fetchStore.response(
                    for: request
                )
            }
        )
        addTeardownBlock {
            try await pump.close()
        }

        try await pump.produce(
            throughSegment: 0
        )
        let first = await pump.snapshot()
        XCTAssertEqual(
            first.highestProducedVideoSegmentIndex,
            0
        )
        XCTAssertEqual(
            first.highestFinalizedAudioSegmentIndices,
            [0]
        )
        XCTAssertEqual(
            first.nextVideoInputSegmentIndex,
            1
        )
        XCTAssertEqual(
            first.nextAudioInputSegmentIndices,
            [2]
        )
        XCTAssertGreaterThan(first.videoPacketCount, 0)
        XCTAssertGreaterThan(
            first.audioPacketCounts[0],
            0
        )
        XCTAssertTrue(
            capture.values.allSatisfy {
                $0 >= 0 && $0 < 90_000
            }
        )

        let optionalAudioInit =
            try await pump.audioInitSegment(
                renditionOrdinal: 0
            )
        let audioInit = try XCTUnwrap(
            optionalAudioInit
        )
        let optionalFirstAudioSegment =
            try await pump.audioMediaSegment(
                renditionOrdinal: 0,
                segmentIndex: 0
            )
        let firstAudioSegment = try XCTUnwrap(
            optionalFirstAudioSegment
        )
        XCTAssertEqual(
            fragmentBaseMediaDecodeTime(
                firstAudioSegment
            ),
            fixture.audioSegmentBaseDecodeTimes[0]
        )
        try assertAudioSegment(
            initData: audioInit,
            mediaData: firstAudioSegment,
            minimumPTS: -256,
            maximumPTS: 48_000
        )

        try await pump.produce(
            throughSegment: 1
        )
        let summaries =
            try await pump.finishFixtureProduction()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(
            summaries[0].pipeline,
            .streamCopy(codecString: "ec-3")
        )
        XCTAssertGreaterThanOrEqual(
            summaries[0].peakBandwidth,
            summaries[0].averageBandwidth
        )
        let final = await pump.snapshot()
        XCTAssertEqual(
            final.highestProducedVideoSegmentIndex,
            1
        )
        XCTAssertEqual(
            final.highestFinalizedAudioSegmentIndices,
            [1]
        )
        XCTAssertEqual(
            final.nextVideoInputSegmentIndex,
            2
        )
        XCTAssertTrue(
            capture.values.contains {
                $0 >= 90_000
            }
        )
        let optionalSecondAudioSegment =
            try await pump.audioMediaSegment(
                renditionOrdinal: 0,
                segmentIndex: 1
            )
        let secondAudioSegment = try XCTUnwrap(
            optionalSecondAudioSegment
        )
        XCTAssertEqual(
            fragmentBaseMediaDecodeTime(
                secondAudioSegment
            ),
            fixture.audioSegmentBaseDecodeTimes[1]
        )
        try assertAudioSegment(
            initData: audioInit,
            mediaData: secondAudioSegment,
            minimumPTS: 48_000 - 256,
            maximumPTS: 96_000
        )
    }

    func testWebVTTRenditionUsesNativeCarrierEndpointsAndFailureStaysTrackLocal()
        async throws
    {
        let fixture = try makeFixture(
            includeWebVTTSubtitles: true,
            omitSecondSubtitleSegment: true
        )
        let provider = try await HLSVODCarrierProvider.make(
            preflight: fixture.preflight,
            fetchOverride: { request, _ in
                try fixture.fetchStore.response(
                    for: request
                )
            }
        )
        addTeardownBlock {
            provider.close()
        }

        XCTAssertEqual(
            provider.nativeSubtitleRenditions.map(\.name),
            ["English"]
        )
        let master = try HLSLocalServer
            .buildMasterPlaylistText(provider: provider)
        XCTAssertTrue(
            master.contains(
                "#EXT-X-MEDIA:TYPE=SUBTITLES"
            )
        )
        XCTAssertTrue(master.contains("SUBTITLES=\"subs\""))
        XCTAssertTrue(
            master.contains(
                "DEFAULT=YES,AUTOSELECT=YES,FORCED=NO"
            )
        )
        XCTAssertEqual(
            provider.nativeSubtitleVTT(
                ordinal: 0,
                segmentIndex: 0
            ),
            "WEBVTT\n\n00:00:00.100 --> 00:00:00.900\nfirst\n"
        )
        XCTAssertNil(
            provider.nativeSubtitleVTT(
                ordinal: 0,
                segmentIndex: 1
            )
        )
        XCTAssertNotNil(provider.mediaSegment(at: 1))
        XCTAssertNil(provider.terminalError)
    }

    func testHLSAudioAnalysisIsDemandDrivenRangeExactAndCursorIndependent()
        async throws
    {
        let fixture = try makeFixture()
        let pump = try await HLSVODMediaPump.make(
            preflight: fixture.preflight,
            fetchOverride: { request, _ in
                try fixture.fetchStore.response(
                    for: request
                )
            }
        )
        addTeardownBlock {
            try await pump.close()
        }
        let before = await pump.snapshot()
        let input = try await pump
            .makeAudioAnalysisInput()
        let request = try AudioAnalysisRequest(
            audioTrackID: 0,
            range: 0.25..<1.75
        )
        let session = AudioAnalysisSession()
        let stream = AudioAnalysisStream(
            gate: session.gate,
            cancel: { session.cancel() }
        )
        let task = Task.detached {
            await AudioAnalysisRunner.run(
                session: session,
                input: input,
                request: request
            )
        }
        session.install(task: task)

        try await Task.sleep(
            for: .milliseconds(25)
        )
        XCTAssertEqual(
            fixture.fetchStore.count(
                for: fixture.audioSegmentURLs[1]
            ),
            0,
            "creating an analysis stream must not fetch the requested segment"
        )

        var iterator = stream.makeAsyncIterator()
        var totalFrames: Int64 = 0
        var firstPosition: Int64?
        var finalPosition: Int64?
        var sawDiscontinuity = false
        while let buffer = try await iterator.next() {
            firstPosition = firstPosition
                ?? buffer.sourceSamplePosition
            totalFrames += Int64(
                buffer.pcm.frameLength
            )
            finalPosition =
                buffer.sourceSamplePosition
                + Int64(buffer.pcm.frameLength)
            sawDiscontinuity =
                sawDiscontinuity
                || buffer.isDiscontinuous
        }
        await task.value

        XCTAssertEqual(
            Double(try XCTUnwrap(firstPosition)),
            12_000,
            accuracy: 128
        )
        XCTAssertEqual(
            Double(try XCTUnwrap(finalPosition)),
            84_000,
            accuracy: 128
        )
        XCTAssertEqual(
            Double(totalFrames),
            72_000,
            accuracy: 256
        )
        XCTAssertFalse(sawDiscontinuity)
        XCTAssertEqual(
            fixture.fetchStore.count(
                for: fixture.audioSegmentURLs[0]
            ),
            1,
            "analysis must reuse the first segment already admitted by playback"
        )
        XCTAssertEqual(
            fixture.fetchStore.count(
                for: fixture.audioSegmentURLs[1]
            ),
            1
        )
        let after = await pump.snapshot()
        XCTAssertEqual(
            after,
            before,
            "analysis must not advance the playback pump cursor or generation"
        )
    }

    func testCancellingBlockedHLSAnalysisReleasesItsWaiterAndPlaybackRemainsUsable()
        async throws
    {
        let fixture = try makeFixture()
        let blocker = FetchBlocker(
            store: fixture.fetchStore,
            blockedURL:
                fixture.audioSegmentURLs[1]
        )
        let pump = try await HLSVODMediaPump.make(
            preflight: fixture.preflight,
            fetchOverride: { request, _ in
                try await blocker.response(
                    for: request
                )
            }
        )
        addTeardownBlock {
            try await pump.close()
        }
        let input = try await pump
            .makeAudioAnalysisInput()
        let source: HLSVODAudioAnalysisInput
        guard case .hlsVOD(let hlsSource) = input else {
            return XCTFail(
                "HLS pump did not expose its graph-bound analysis source"
            )
        }
        source = hlsSource
        let request = try AudioAnalysisRequest(
            audioTrackID: 0,
            range: 1.1..<1.8
        )
        let session = AudioAnalysisSession()
        let stream = AudioAnalysisStream(
            gate: session.gate,
            cancel: { session.cancel() }
        )
        let runner = Task.detached {
            await AudioAnalysisRunner.run(
                session: session,
                input: input,
                request: request
            )
        }
        session.install(task: runner)
        let consumer = Task {
            var iterator =
                stream.makeAsyncIterator()
            return try await iterator.next()
        }

        try await blocker.waitForRequestCount(1)
        let blocked = await source.loaderSnapshot()
        XCTAssertEqual(
            blocked.inFlightAnalysisWaiterCount,
            1
        )
        XCTAssertEqual(
            blocked.inFlightPlaybackWaiterCount,
            0
        )
        stream.cancel()
        do {
            _ = try await consumer.value
            XCTFail(
                "cancelled analysis unexpectedly produced PCM"
            )
        } catch let error as AudioAnalysisError {
            XCTAssertEqual(error, .cancelled)
        }
        await runner.value

        let cancelled = await source.loaderSnapshot()
        XCTAssertEqual(
            cancelled.inFlightAnalysisWaiterCount,
            0
        )
        XCTAssertEqual(
            cancelled.inFlightResourceCount,
            0
        )
        XCTAssertEqual(
            fixture.fetchStore.count(
                for: fixture.audioSegmentURLs[1]
            ),
            0,
            "the cancelled origin task must not publish bytes into the shared cache"
        )

        await blocker.release()
        try await pump.produce(
            throughSegment: 1
        )
        let playback = await pump.snapshot()
        XCTAssertEqual(
            playback.highestProducedVideoSegmentIndex,
            1
        )
        XCTAssertEqual(
            playback.highestFinalizedAudioSegmentIndices,
            [1]
        )
        XCTAssertEqual(
            fixture.fetchStore.count(
                for: fixture.audioSegmentURLs[1]
            ),
            1,
            "playback must be able to issue a fresh graph-bound request after analysis cancellation"
        )
    }

    func testHLSAudioAnalysisRejectsUnknownTrackAndOutOfTimelineRangeWithoutFetching()
        async throws
    {
        let fixture = try makeFixture()
        let pump = try await HLSVODMediaPump.make(
            preflight: fixture.preflight,
            fetchOverride: { request, _ in
                try fixture.fetchStore.response(
                    for: request
                )
            }
        )
        addTeardownBlock {
            try await pump.close()
        }
        let input = try await pump
            .makeAudioAnalysisInput()
        let source: HLSVODAudioAnalysisInput
        guard case .hlsVOD(let hlsSource) = input else {
            return XCTFail(
                "HLS pump did not expose its graph-bound analysis source"
            )
        }
        source = hlsSource

        let unknownTrack = try AudioAnalysisRequest(
            audioTrackID: 99,
            range: 0..<1
        )
        XCTAssertThrowsError(
            try source.track(for: unknownTrack)
        ) { error in
            XCTAssertEqual(
                error as? AudioAnalysisError,
                .audioTrackUnavailable(99)
            )
        }
        let outsideTimeline = try AudioAnalysisRequest(
            audioTrackID: 0,
            range: 1.5..<2.5
        )
        XCTAssertThrowsError(
            try source.track(for: outsideTimeline)
        ) { error in
            XCTAssertEqual(
                error as? AudioAnalysisError,
                .rangeOutsideSource
            )
        }
        XCTAssertEqual(
            fixture.fetchStore.count(
                for: fixture.audioSegmentURLs[1]
            ),
            0
        )
    }

    func testHLSAudioAnalysisDecodesMuxedVariantWithoutMovingPlaybackState()
        async throws
    {
        let fixture = try makeMuxedFixture()
        let pump = try await HLSVODMediaPump.make(
            preflight: fixture.preflight,
            fetchOverride: { request, _ in
                try fixture.fetchStore.response(
                    for: request
                )
            }
        )
        addTeardownBlock {
            try await pump.close()
        }
        let metadata = await pump.renditionMetadata
        let trackID = try XCTUnwrap(
            metadata.first?.sourceTrackID
        )
        let before = await pump.snapshot()
        let input = try await pump
            .makeAudioAnalysisInput()
        let request = try AudioAnalysisRequest(
            audioTrackID: trackID,
            range: 0.25..<1.75
        )
        let session = AudioAnalysisSession()
        let stream = AudioAnalysisStream(
            gate: session.gate,
            cancel: { session.cancel() }
        )
        let task = Task.detached {
            await AudioAnalysisRunner.run(
                session: session,
                input: input,
                request: request
            )
        }
        session.install(task: task)

        var iterator = stream.makeAsyncIterator()
        var totalFrames: Int64 = 0
        var firstPosition: Int64?
        var finalPosition: Int64?
        var sawDiscontinuity = false
        while let buffer = try await iterator.next() {
            firstPosition =
                firstPosition
                ?? buffer.sourceSamplePosition
            totalFrames += Int64(
                buffer.pcm.frameLength
            )
            finalPosition =
                buffer.sourceSamplePosition
                + Int64(buffer.pcm.frameLength)
            sawDiscontinuity =
                sawDiscontinuity
                || buffer.isDiscontinuous
        }
        await task.value

        XCTAssertEqual(
            Double(try XCTUnwrap(firstPosition)),
            12_000,
            accuracy: 128
        )
        XCTAssertEqual(
            Double(try XCTUnwrap(finalPosition)),
            84_000,
            accuracy: 128
        )
        XCTAssertEqual(
            Double(totalFrames),
            72_000,
            accuracy: 256
        )
        XCTAssertFalse(sawDiscontinuity)
        XCTAssertEqual(
            fixture.fetchStore.count(
                for: fixture.videoSegmentURLs[1]
            ),
            1
        )
        let after = await pump.snapshot()
        XCTAssertEqual(after, before)
    }

    func testConcurrentDemandUsesOneSerializedProductionRun()
        async throws
    {
        let fixture = try makeFixture()
        let pump = try await HLSVODMediaPump.make(
            preflight: fixture.preflight,
            fetchOverride: { request, _ in
                try fixture.fetchStore.response(
                    for: request
                )
            }
        )
        addTeardownBlock {
            try await pump.close()
        }

        async let first: Void =
            pump.produce(throughSegment: 1)
        async let second: Void =
            pump.produce(throughSegment: 1)
        _ = try await (first, second)

        XCTAssertEqual(
            fixture.fetchStore.count(
                for: fixture.videoSegmentURLs[1]
            ),
            1
        )
        XCTAssertEqual(
            fixture.fetchStore.count(
                for: fixture.audioSegmentURLs[0]
            ),
            1
        )
        XCTAssertEqual(
            fixture.fetchStore.count(
                for: fixture.audioSegmentURLs[1]
            ),
            1
        )
        let snapshot = await pump.snapshot()
        XCTAssertEqual(
            snapshot.highestFinalizedAudioSegmentIndices,
            [1]
        )
    }

    func testDecodedFramesUseTheGlobalMirroredTimeline()
        async throws
    {
        let fixture = try makeFixture()
        let capture = FrameCapture()
        let pump = try await HLSVODMediaPump.make(
            preflight: fixture.preflight,
            decodedFrameHandler: { frame in
                capture.append(frame)
            },
            fetchOverride: { request, _ in
                try fixture.fetchStore.response(
                    for: request
                )
            }
        )
        addTeardownBlock {
            try await pump.close()
        }

        try await pump.advanceVideoDecodeDemand(
            to: CMTime(
                value: 180_000,
                timescale: 90_000
            )
        )
        try await pump.produce(
            throughSegment: 1
        )

        XCTAssertTrue(
            capture.values.contains {
                CMTimeCompare($0, .zero) == 0
            }
        )
        XCTAssertTrue(
            capture.values.contains {
                CMTimeCompare(
                    $0,
                    CMTime(
                        value: 90_000,
                        timescale: 90_000
                    )
                ) == 0
            }
        )
    }

    func testExplicitSeekReplacesTheHLSGeneration()
        async throws
    {
        let fixture = try makeFixture()
        let capture = FrameCapture()
        let pump = try await HLSVODMediaPump.make(
            preflight: fixture.preflight,
            decodedFrameHandler: { frame in
                capture.append(frame)
            },
            fetchOverride: { request, _ in
                try fixture.fetchStore.response(
                    for: request
                )
            }
        )
        addTeardownBlock {
            try await pump.close()
        }

        try await pump.produce(
            throughSegment: 0
        )
        let optionalInitialAudioInit =
            try await pump.audioInitSegment(
                renditionOrdinal: 0
            )
        let initialAudioInit = try XCTUnwrap(
            optionalInitialAudioInit
        )
        var classifier =
            HybridSeekIntentClassifier(
                timeline:
                    try XCTUnwrap(
                        fixture.preflight
                            .hybridTimeline
                    )
            )
        let intent =
            try classifier
                .registerExplicitHostSeek(
                    to: CMTime(
                        seconds: 1.5,
                        preferredTimescale:
                            90_000
                    )
                )

        let restartResult =
            try await pump.restart(for: intent)
        XCTAssertEqual(
            restartResult,
            .applied(
                generation: 1,
                segmentIndex: 1
            )
        )
        let restarted =
            await pump.snapshot()
        XCTAssertEqual(restarted.generation, 1)
        XCTAssertEqual(
            restarted
                .nextVideoInputSegmentIndex,
            1
        )
        XCTAssertEqual(
            restarted
                .nextAudioInputSegmentIndices,
            [1]
        )
        XCTAssertEqual(
            restarted
                .highestProducedVideoSegmentIndex,
            0
        )
        XCTAssertEqual(
            restarted
                .highestFinalizedAudioSegmentIndices,
            [0]
        )

        try await pump.produce(
            throughSegment: 1
        )
        let final = await pump.snapshot()
        XCTAssertEqual(
            final.highestProducedVideoSegmentIndex,
            1
        )
        XCTAssertEqual(
            final
                .highestFinalizedAudioSegmentIndices,
            [1]
        )
        XCTAssertTrue(
            capture.generations.contains(1)
        )
        XCTAssertTrue(
            zip(
                capture.generations,
                capture.values
            ).contains {
                generation,
                presentationTime in
                generation == 1
                    && CMTimeCompare(
                        presentationTime,
                        CMTime(
                            value: 90_000,
                            timescale: 90_000
                        )
                    ) == 0
            }
        )

        let optionalRestartedAudioInit =
            try await pump.audioInitSegment(
                renditionOrdinal: 0
            )
        let restartedAudioInit =
            try XCTUnwrap(
                optionalRestartedAudioInit
            )
        XCTAssertEqual(
            restartedAudioInit,
            initialAudioInit
        )
        let optionalRestartedAudio =
            try await pump.audioMediaSegment(
                renditionOrdinal: 0,
                segmentIndex: 1
            )
        let restartedAudio =
            try XCTUnwrap(
                optionalRestartedAudio
            )
        XCTAssertEqual(
            fragmentBaseMediaDecodeTime(
                restartedAudio
            ),
            fixture
                .audioSegmentBaseDecodeTimes[1]
        )
        let staleResult =
            try await pump.restart(for: intent)
        XCTAssertEqual(
            staleResult,
            .stale(currentGeneration: 1)
        )
        do {
            _ = try await pump
                .finishFixtureProduction()
            XCTFail(
                "seek generation unexpectedly produced a final fixture summary"
            )
        } catch let error
                as HLSVODMediaPumpError {
            XCTAssertEqual(
                error,
                .finalFixtureSummaryUnavailableAfterRestart(
                    generation: 1
                )
            )
        }

        let backwardIntent =
            try classifier
                .registerPlayerTimeJump(
                    to: CMTime(
                        seconds: 0.25,
                        preferredTimescale:
                            90_000
                    )
                )
        let backwardRestart =
            try await pump.restart(
                for: backwardIntent
            )
        XCTAssertEqual(
            backwardRestart,
            .applied(
                generation: 2,
                segmentIndex: 0
            )
        )
        try await pump.produce(
            throughSegment: 0
        )
        let backwardSnapshot =
            await pump.snapshot()
        XCTAssertEqual(
            backwardSnapshot.generation,
            2
        )
        XCTAssertEqual(
            backwardSnapshot
                .generationStartSegmentIndex,
            0
        )
        XCTAssertTrue(
            zip(
                capture.generations,
                capture.values
            ).contains {
                generation,
                presentationTime in
                generation == 2
                    && CMTimeCompare(
                        presentationTime,
                        .zero
                    ) == 0
            }
        )
        let optionalBackwardAudio =
            try await pump.audioMediaSegment(
                renditionOrdinal: 0,
                segmentIndex: 0
            )
        let backwardAudio =
            try XCTUnwrap(
                optionalBackwardAudio
            )
        XCTAssertEqual(
            fragmentBaseMediaDecodeTime(
                backwardAudio
            ),
            fixture
                .audioSegmentBaseDecodeTimes[0]
        )
    }

    func testPendingCarrierAudioServeTransfersToReplacementGeneration()
        async throws
    {
        let fixture = try makeFixture()
        let blocker = FetchBlocker(
            store: fixture.fetchStore,
            blockedURL:
                fixture.audioSegmentURLs[1]
        )
        let pump = try await HLSVODMediaPump.make(
            preflight: fixture.preflight,
            fetchOverride: { request, _ in
                try await blocker.response(
                    for: request
                )
            }
        )
        addTeardownBlock {
            try await pump.close()
        }

        let pendingCarrierServe = Task {
            try await pump.audioMediaSegmentURL(
                renditionOrdinal: 0,
                segmentIndex: 1
            )
        }
        try await blocker.waitForRequestCount(1)

        var classifier =
            HybridSeekIntentClassifier(
                timeline:
                    try XCTUnwrap(
                        fixture.preflight
                            .hybridTimeline
                    )
            )
        let intent = try classifier
            .registerExplicitHostSeek(
                to: CMTime(
                    seconds: 1.5,
                    preferredTimescale: 90_000
                )
            )
        let restart = Task {
            try await pump.restart(for: intent)
        }
        try await blocker.waitForRequestCount(2)
        await blocker.release()

        let restartResult = try await restart.value
        XCTAssertEqual(
            restartResult,
            .applied(
                generation: 1,
                segmentIndex: 1
            )
        )
        let servedURL = try await
            pendingCarrierServe.value
        XCTAssertNotNil(servedURL)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: try XCTUnwrap(
                    servedURL
                ).path
            )
        )
        let snapshot = await pump.snapshot()
        XCTAssertEqual(snapshot.generation, 1)
        XCTAssertEqual(
            snapshot
                .highestFinalizedAudioSegmentIndices,
            [1]
        )
    }

    func testHLSRestartRejectsNonSeekAndMismatchedIntent()
        async throws
    {
        let fixture = try makeFixture()
        let pump = try await HLSVODMediaPump.make(
            preflight: fixture.preflight,
            fetchOverride: { request, _ in
                try fixture.fetchStore.response(
                    for: request
                )
            }
        )
        addTeardownBlock {
            try await pump.close()
        }

        do {
            _ = try await pump.restart(
                for: .prefetch(
                    segmentIndex: 1,
                    generation: 0
                )
            )
            XCTFail(
                "prefetch unexpectedly restarted HLS media"
            )
        } catch let error
                as HLSVODMediaPumpError {
            XCTAssertEqual(
                error,
                .restartRequiresUserSeek
            )
        }

        do {
            _ = try await pump.restart(
                for: .userSeek(
                    target: CMTime(
                        seconds: 1.5,
                        preferredTimescale:
                            90_000
                    ),
                    segmentIndex: 0,
                    generation: 1
                )
            )
            XCTFail(
                "mismatched seek intent unexpectedly restarted HLS media"
            )
        } catch let error
                as HLSVODMediaPumpError {
            XCTAssertEqual(
                error,
                .seekIntentSegmentMismatch(
                    expected: 1,
                    actual: 0
                )
            )
        }
    }

    func testSeekSupersedesInFlightHLSProduction()
        async throws
    {
        let fixture = try makeFixture()
        let blocker = FetchBlocker(
            store: fixture.fetchStore,
            blockedURL:
                fixture.videoSegmentURLs[1]
        )
        let pump = try await HLSVODMediaPump.make(
            preflight: fixture.preflight,
            fetchOverride: { request, _ in
                try await blocker.response(
                    for: request
                )
            }
        )
        addTeardownBlock {
            try await pump.close()
        }

        try await pump.produce(
            throughSegment: 0
        )
        let retiringProduction = Task {
            try await pump.produce(
                throughSegment: 1
            )
        }
        try await blocker.waitForRequestCount(1)

        var classifier =
            HybridSeekIntentClassifier(
                timeline:
                    try XCTUnwrap(
                        fixture.preflight
                            .hybridTimeline
                    )
            )
        let intent =
            try classifier
                .registerExplicitHostSeek(
                    to: CMTime(
                        seconds: 1.5,
                        preferredTimescale:
                            90_000
                    )
                )
        let restart = Task {
            try await pump.restart(for: intent)
        }
        try await blocker.waitForRequestCount(2)
        await blocker.release()

        let restartResult =
            try await restart.value
        XCTAssertEqual(
            restartResult,
            .applied(
                generation: 1,
                segmentIndex: 1
            )
        )
        do {
            try await retiringProduction.value
            XCTFail(
                "retiring generation unexpectedly completed"
            )
        } catch let error
                as HLSVODMediaPumpError {
            XCTAssertEqual(
                error,
                .generationSuperseded(
                    generation: 0
                )
            )
        }
        let blockedRequestCount =
            await blocker.count
        XCTAssertEqual(
            blockedRequestCount,
            2
        )

        try await pump.produce(
            throughSegment: 1
        )
        let snapshot = await pump.snapshot()
        XCTAssertEqual(snapshot.generation, 1)
        XCTAssertEqual(
            snapshot
                .generationStartSegmentIndex,
            1
        )
        XCTAssertEqual(
            snapshot
                .highestFinalizedAudioSegmentIndices,
            [1]
        )
    }

    func testFactoryRejectsManifestChannelMismatch()
        async throws
    {
        let fixture = try makeFixture(
            declaredAudioChannels: "6"
        )
        do {
            _ = try await HLSVODMediaPump.make(
                preflight: fixture.preflight,
                fetchOverride: { request, _ in
                    try fixture.fetchStore.response(
                        for: request
                    )
                }
            )
            XCTFail(
                "mismatched audio CHANNELS unexpectedly admitted"
            )
        } catch let error as HLSVODMediaPumpError {
            XCTAssertEqual(
                error,
                .audioContractChanged(
                    renditionOrdinal: 0,
                    inputSegmentIndex: 0
                )
            )
        }
    }

    func testCarrierProviderServesPumpOutputThroughLoopbackHLS()
        async throws
    {
        let fixture = try makeFixture()
        let provider =
            try await HLSVODCarrierProvider.make(
                preflight: fixture.preflight,
                fetchOverride: { request, _ in
                    try fixture.fetchStore.response(
                        for: request
                    )
                }
            )
        let server = HLSLocalServer(
            provider: provider
        )
        try server.start()
        addTeardownBlock {
            server.stop()
            provider.close()
        }
        let masterURL = try XCTUnwrap(
            server.playlistURL
        )
        let baseURL =
            masterURL.deletingLastPathComponent()

        let master = try await fetchText(
            masterURL
        )
        XCTAssertTrue(
            master.contains("BANDWIDTH=2000000")
        )
        XCTAssertFalse(
            master.contains("AVERAGE-BANDWIDTH")
        )
        XCTAssertTrue(
            master.contains(
                "CODECS=\"avc1.42C01E,ec-3\""
            )
        )
        XCTAssertTrue(
            master.contains("AUDIO=\"audio\"")
        )
        let audioPlaylist = try await fetchText(
            baseURL.appendingPathComponent(
                "audio_0.m3u8"
            )
        )
        XCTAssertTrue(
            audioPlaylist.contains(
                "audio_0_seg_1.mp4"
            )
        )
        let audioInit = try await fetchData(
            baseURL.appendingPathComponent(
                "audio_0_init.mp4"
            )
        )
        let firstAudio = try await fetchData(
            baseURL.appendingPathComponent(
                "audio_0_seg_0.mp4"
            )
        )
        var classifier =
            HybridSeekIntentClassifier(
                timeline:
                    try XCTUnwrap(
                        fixture.preflight
                            .hybridTimeline
                    )
            )
        let intent =
            try classifier
                .registerExplicitHostSeek(
                    to: CMTime(
                        seconds: 1.5,
                        preferredTimescale:
                            90_000
                    )
                )
        XCTAssertEqual(
            try provider.restartMedia(
                for: intent
            ),
            .applied(
                generation: 1,
                segmentIndex: 1
            )
        )
        XCTAssertEqual(
            try provider.restartMedia(
                for: intent
            ),
            .stale(currentGeneration: 1)
        )
        let secondVideo = try await fetchData(
            baseURL.appendingPathComponent(
                "seg1.mp4"
            )
        )
        let secondAudio = try await fetchData(
            baseURL.appendingPathComponent(
                "audio_0_seg_1.mp4"
            )
        )
        XCTAssertFalse(audioInit.isEmpty)
        XCTAssertFalse(firstAudio.isEmpty)
        XCTAssertFalse(secondVideo.isEmpty)
        XCTAssertFalse(secondAudio.isEmpty)
        XCTAssertNil(provider.terminalError)
    }

    @MainActor
    func testPublicHybridSessionComposesHLSProviderIntoAVPlayerAndSampleBufferPresentation()
        async throws
    {
        let fixture = try makeFixture()
        let session =
            try await AetherHybridPlaybackSession
                .makeHLSVOD(
                    preflight: fixture.preflight,
                    fetchOverride: {
                        request,
                        _ in
                        try fixture.fetchStore
                            .response(for: request)
                    }
                )
        defer { session.stop() }

        try await session.prepare(timeout: 10)

        XCTAssertEqual(
            session.state,
            .ready(generation: 0)
        )
        XCTAssertEqual(
            session.preflightResult,
            fixture.preflight.result
        )
        XCTAssertEqual(
            session.timeline.source,
            .mirroredHLSVOD
        )
        XCTAssertEqual(
            session.audioAnalysisTrackIDs,
            [0]
        )
        XCTAssertNotNil(session.avPlayer.currentItem)
        let presentationView = session.presentationView
        XCTAssertEqual(
            presentationView.diagnostics.generation,
            0
        )
        XCTAssertEqual(
            try XCTUnwrap(
                presentationView.diagnostics
                    .lastEnqueuedTimeSeconds
            ),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            session.diagnostics.carrierBandwidth
                .declaredTransportBudget,
            2_000_000
        )
    }

    @MainActor
    func testPublicHybridSessionRejectsNonHybridHLSBeforeOriginFetch()
        async throws
    {
        let fixture = try makeFixture()
        let result = PlaybackPreflightResult(
            sourceProfile:
                fixture.preflight.result
                    .sourceProfile,
            hlsPackaging:
                fixture.preflight.result
                    .hlsPackaging,
            route: .nativeAVPlayer,
            reason: .nativeHLSContractVerified
        )
        let preflight = AetherHLSPlaybackPreflight(
            result: result,
            resourceGraph: nil,
            httpHeaders: [:]
        )
        let expected = HybridPlaybackSessionError
            .preflightRequiresHybrid(
                route: .nativeAVPlayer,
                reason: .nativeHLSContractVerified
            )

        do {
            _ = try await AetherHybridPlaybackSession
                .makeHLSVOD(
                    preflight: preflight,
                    fetchOverride: {
                        request,
                        _ in
                        try fixture.fetchStore
                            .response(for: request)
                    }
                )
            XCTFail(
                "non-hybrid HLS unexpectedly created a hybrid session"
            )
        } catch let error
                as HybridPlaybackSessionError {
            XCTAssertEqual(error, expected)
        }
        for url in
            fixture.videoSegmentURLs
                + fixture.audioSegmentURLs {
            XCTAssertEqual(
                fixture.fetchStore.count(for: url),
                0
            )
        }
    }

    @MainActor
    func testPublicHybridSessionRejectsMissingResourceGraphBeforeOriginFetch()
        async throws
    {
        let fixture = try makeFixture()
        let preflight = AetherHLSPlaybackPreflight(
            result: fixture.preflight.result,
            resourceGraph: nil,
            httpHeaders: [:]
        )

        do {
            _ = try await AetherHybridPlaybackSession
                .makeHLSVOD(
                    preflight: preflight,
                    fetchOverride: {
                        request,
                        _ in
                        try fixture.fetchStore
                            .response(for: request)
                    }
                )
            XCTFail(
                "graphless HLS preflight unexpectedly created a public session"
            )
        } catch let error
                as HybridPlaybackSessionError {
            XCTAssertEqual(
                error,
                .hlsPreflightResourceGraphMissing
            )
        }
        for url in
            fixture.videoSegmentURLs
                + fixture.audioSegmentURLs {
            XCTAssertEqual(
                fixture.fetchStore.count(for: url),
                0
            )
        }
    }

    @MainActor
    func testPublicHybridSessionRevalidatesColorCapabilityBeforeOriginFetch()
        async throws
    {
        let fixture = try makeFixture()
        let source = AetherSourceProfile(
            sourceKind: .hls,
            isSeekableVOD: true,
            videoCodec: .h264,
            videoFormat: .hdr10
        )
        let result = PlaybackPreflight.resolve(
            sourceProfile: source,
            hlsPackaging:
                fixture.preflight.result
                    .hlsPackaging,
            hybridCapabilities:
                HybridPlaybackCapabilities(
                    hasDirectVideoDecoder: true,
                    hasSampleBufferRenderer: true,
                    supportedVideoFormats: [.hdr10]
                )
        )
        XCTAssertEqual(
            result.route,
            .hybridCarrier
        )
        let preflight = AetherHLSPlaybackPreflight(
            result: result,
            resourceGraph:
                fixture.preflight.resourceGraph,
            httpHeaders: [:]
        )
        let expected = HybridPlaybackSessionError
            .preflightContractChanged(
                route: .unsupported,
                reason:
                    .unsupportedHybridVideoFormat
            )

        do {
            _ = try await AetherHybridPlaybackSession
                .makeHLSVOD(
                    preflight: preflight,
                    fetchOverride: {
                        request,
                        _ in
                        try fixture.fetchStore
                            .response(for: request)
                    }
                )
            XCTFail(
                "stale HDR capability unexpectedly created a public session"
            )
        } catch let error
                as HybridPlaybackSessionError {
            XCTAssertEqual(error, expected)
        }
        for url in
            fixture.videoSegmentURLs
                + fixture.audioSegmentURLs {
            XCTAssertEqual(
                fixture.fetchStore.count(for: url),
                0
            )
        }
    }

    @MainActor
    func testHybridSessionRequiresNewPreflightWhenStartupCredentialIsRejected()
        async throws
    {
        let fixture = try makeFixture()
        let rejectedURL = fixture.audioSegmentURLs[0]
        let rejected = FetchStore(
            responses: [
                rejectedURL:
                    HLSVODOriginFetchResponse(
                        data: Data(),
                        effectiveURL: rejectedURL,
                        statusCode: 403,
                        contentLength: 0,
                        contentEncoding: nil
                    ),
            ]
        )
        let expected = HybridPlaybackSessionError
            .hlsPreflightGenerationInvalidated(
                .credentialRejected(
                    statusCode: 403,
                    resource: .audioSegment(
                        renditionOrdinal: 0,
                        index: 0
                    )
                )
            )

        do {
            _ = try await AetherHybridPlaybackSession
                .makeHLSVOD(
                    preflight: fixture.preflight,
                    fetchOverride: {
                        request,
                        _ in
                        if request.url == rejectedURL {
                            return try rejected.response(
                                for: request
                            )
                        }
                        return try fixture.fetchStore
                            .response(for: request)
                    }
                )
            XCTFail(
                "expired startup credential unexpectedly created a hybrid session"
            )
        } catch let error
                as HybridPlaybackSessionError {
            XCTAssertEqual(error, expected)
        }
        XCTAssertEqual(
            rejected.count(for: rejectedURL),
            1,
            "session creation must not retry the rejected preflight generation"
        )
    }

    func testCarrierProviderPublishesTypedRuntimeRepreflightRequirement()
        async throws
    {
        let fixture = try makeFixture()
        let rejectedURL = fixture.videoSegmentURLs[1]
        let rejected = FetchStore(
            responses: [
                rejectedURL:
                    HLSVODOriginFetchResponse(
                        data: Data(),
                        effectiveURL: rejectedURL,
                        statusCode: 410,
                        contentLength: 0,
                        contentEncoding: nil
                    ),
            ]
        )
        let provider =
            try await HLSVODCarrierProvider.make(
                preflight: fixture.preflight,
                fetchOverride: {
                    request,
                    _ in
                    if request.url == rejectedURL {
                        return try rejected.response(
                            for: request
                        )
                    }
                    return try fixture.fetchStore
                        .response(for: request)
                }
            )
        defer { provider.close() }
        try provider.prepareForTransportStart()

        let expected = HybridPlaybackSessionError
            .hlsPreflightGenerationInvalidated(
                .resourceUnavailable(
                    statusCode: 410,
                    resource: .videoSegment(index: 1)
                )
            )
        do {
            try provider.prepareHybridGeneration(
                segmentIndex: 1
            )
            XCTFail(
                "gone runtime resource unexpectedly kept the provider usable"
            )
        } catch {
            XCTAssertEqual(
                HLSVODCarrierProvider
                    .hybridPlaybackSessionError(
                        from: error
                    ),
                expected
            )
        }
        XCTAssertEqual(
            provider.terminalHybridPlaybackError,
            expected
        )

        do {
            try provider.prepareHybridGeneration(
                segmentIndex: 1
            )
            XCTFail(
                "invalidated provider unexpectedly retried its old graph"
            )
        } catch {
            XCTAssertEqual(
                HLSVODCarrierProvider
                    .hybridPlaybackSessionError(
                        from: error
                    ),
                expected
            )
        }
        XCTAssertEqual(
            rejected.count(for: rejectedURL),
            1,
            "terminal provider must not retry the invalidated graph"
        )
    }

    func testCarrierProviderUsesPrimaryFixedLoopbackBudgetWithoutMeasurement()
        async throws
    {
        let fixture = try makeFixture()
        let provider =
            try await HLSVODCarrierProvider.make(
                preflight: fixture.preflight,
                fetchOverride: { request, _ in
                    try fixture.fetchStore.response(
                        for: request
                    )
                }
            )
        defer { provider.close() }

        XCTAssertEqual(
            provider.masterBandwidth,
            AetherHybridCarrierBandwidthPolicy
                .loopbackTransportBudget
        )
        XCTAssertNil(provider.masterAverageBandwidth)
        XCTAssertEqual(
            provider.carrierBandwidthTelemetry.state,
            .awaitingCarrierSegments
        )
        XCTAssertEqual(
            fixture.fetchStore.count(
                for: fixture.videoSegmentURLs[1]
            ),
            0,
            "provider construction must not measure the full video asset"
        )
        XCTAssertEqual(
            fixture.fetchStore.count(
                for: fixture.audioSegmentURLs[1]
            ),
            0,
            "provider construction must not measure the full audio asset"
        )

        try provider.prepareForTransportStart()
        let telemetry = provider.carrierBandwidthTelemetry
        XCTAssertEqual(telemetry.state, .partial)
        XCTAssertEqual(telemetry.audioRenditionCount, 1)
        XCTAssertEqual(telemetry.observedSegmentCount, 1)
        XCTAssertNotNil(telemetry.observedPeakBandwidth)
        XCTAssertNotNil(telemetry.observedAverageBandwidth)
    }

    func testCarrierProviderForwardsAVPlayerPressureToTheOriginLoader()
        async throws
    {
        let fixture = try makeFixture()
        let provider =
            try await HLSVODCarrierProvider.make(
                preflight: fixture.preflight,
                fetchOverride: { request, _ in
                    try fixture.fetchStore.response(
                        for: request
                    )
                }
            )
        addTeardownBlock {
            provider.close()
        }

        await provider.setAudioAnalysisPlaybackPressure(
            .carrierWaitingToPlay
        )
        var snapshot =
            await provider.originLoaderSnapshot()
        XCTAssertEqual(
            snapshot.declaredPlaybackPressure,
            .carrierWaitingToPlay
        )

        await provider.setAudioAnalysisPlaybackPressure(
            .none
        )
        snapshot = await provider.originLoaderSnapshot()
        XCTAssertEqual(
            snapshot.declaredPlaybackPressure,
            .none
        )
    }

    func testHLSAnalysisReusesThePlaybackOriginGraph()
        async throws
    {
        let fixture = try makeFixture()
        let provider =
            try await HLSVODCarrierProvider.make(
                preflight: fixture.preflight,
                fetchOverride: { request, _ in
                    try fixture.fetchStore.response(
                        for: request
                    )
                }
            )
        addTeardownBlock {
            provider.close()
        }
        XCTAssertEqual(
            provider.audioAnalysisTrackIDs,
            [0]
        )
        let input =
            try provider.makeAudioAnalysisInput()
        let playbackBeforeAnalysis =
            try provider.mediaPumpSnapshot()
        let session = AudioAnalysisSession()
        let stream = AudioAnalysisStream(
            gate: session.gate,
            cancel: { session.cancel() }
        )
        let request = try AudioAnalysisRequest(
            audioTrackID: 0,
            range: 0.25..<1.75
        )
        let task = Task.detached {
            await AudioAnalysisRunner.run(
                session: session,
                input: input,
                request: request
            )
        }
        session.install(task: task)

        try await Task.sleep(
            for: .milliseconds(25)
        )
        XCTAssertEqual(
            fixture.fetchStore.count(
                for: fixture.audioSegmentURLs[1]
            ),
            0,
            "creating an HLS analysis stream must not fetch before first demand"
        )

        var totalFrames: Int64 = 0
        var firstPosition: Int64?
        var finalPosition: Int64?
        var iterator = stream.makeAsyncIterator()
        while let buffer = try await iterator.next() {
            firstPosition = firstPosition
                ?? buffer.sourceSamplePosition
            totalFrames += Int64(
                buffer.pcm.frameLength
            )
            finalPosition =
                buffer.sourceSamplePosition
                + Int64(buffer.pcm.frameLength)
        }
        await task.value

        XCTAssertEqual(
            Double(totalFrames),
            72_000,
            accuracy: 2_400
        )
        XCTAssertEqual(
            Double(try XCTUnwrap(firstPosition)),
            12_000,
            accuracy: 240
        )
        XCTAssertEqual(
            Double(try XCTUnwrap(finalPosition)),
            84_000,
            accuracy: 240
        )
        XCTAssertEqual(
            fixture.fetchStore.count(
                for: fixture.audioSegmentURLs[0]
            ),
            1
        )
        XCTAssertEqual(
            fixture.fetchStore.count(
                for: fixture.audioSegmentURLs[1]
            ),
            1
        )
        let playbackAfterAnalysis =
            try provider.mediaPumpSnapshot()
        XCTAssertEqual(
            playbackAfterAnalysis,
            playbackBeforeAnalysis,
            "independent analysis must not move or produce the playback cursor"
        )

        try provider.prepareForTransportStart()
        XCTAssertEqual(
            fixture.fetchStore.count(
                for: fixture.audioSegmentURLs[1]
            ),
            1,
            "playback must reuse the segment fetched by analysis"
        )
    }

    func testCancellingHLSAnalysisDoesNotCancelAPlaybackWaiter()
        async throws
    {
        let fixture = try makeFixture()
        let blocker = FetchBlocker(
            store: fixture.fetchStore,
            blockedURL:
                fixture.audioSegmentURLs[1]
        )
        let provider =
            try await HLSVODCarrierProvider.make(
                preflight: fixture.preflight,
                fetchOverride: { request, _ in
                    try await blocker.response(
                        for: request
                    )
                }
            )
        addTeardownBlock {
            provider.close()
        }
        let input =
            try provider.makeAudioAnalysisInput()
        let hlsInput: HLSVODAudioAnalysisInput
        guard case .hlsVOD(let resolved) = input else {
            XCTFail("provider returned a non-HLS analysis input")
            return
        }
        hlsInput = resolved

        let session = AudioAnalysisSession()
        let stream = AudioAnalysisStream(
            gate: session.gate,
            cancel: { session.cancel() }
        )
        let request = try AudioAnalysisRequest(
            audioTrackID: 0,
            range: 1.1..<1.8
        )
        let analysisTask = Task.detached {
            await AudioAnalysisRunner.run(
                session: session,
                input: input,
                request: request
            )
        }
        session.install(task: analysisTask)
        let nextTask = Task {
            var iterator =
                stream.makeAsyncIterator()
            return try await iterator.next()
        }
        try await blocker.waitForRequestCount(1)

        let playbackTask = Task.detached {
            try provider.prepareForTransportStart()
        }
        while true {
            let snapshot =
                await hlsInput.loaderSnapshot()
            if snapshot.inFlightPlaybackWaiterCount == 1,
               snapshot.inFlightAnalysisWaiterCount == 1 {
                break
            }
            try await Task.sleep(
                for: .milliseconds(5)
            )
        }

        stream.cancel()
        while true {
            let snapshot =
                await hlsInput.loaderSnapshot()
            if snapshot.inFlightPlaybackWaiterCount == 1,
               snapshot.inFlightAnalysisWaiterCount == 0 {
                break
            }
            try await Task.sleep(
                for: .milliseconds(5)
            )
        }
        await blocker.release()

        do {
            _ = try await nextTask.value
            XCTFail(
                "cancelled analysis unexpectedly produced a buffer"
            )
        } catch let error as AudioAnalysisError {
            XCTAssertEqual(error, .cancelled)
        }
        await analysisTask.value
        try await playbackTask.value
        let blockedRequestCount =
            await blocker.count
        XCTAssertEqual(
            blockedRequestCount,
            1,
            "analysis and playback must share one graph-bound origin fetch"
        )
    }

    func testHLSAnalysisFailsWhenAGraphResourceIsMissing()
        async throws
    {
        let fixture = try makeFixture(
            omitSecondAudioSegment: true
        )
        let provider =
            try await HLSVODCarrierProvider.make(
                preflight: fixture.preflight,
                fetchOverride: { request, _ in
                    try fixture.fetchStore.response(
                        for: request
                    )
                }
            )
        addTeardownBlock {
            provider.close()
        }
        let input =
            try provider.makeAudioAnalysisInput()
        let session = AudioAnalysisSession()
        let stream = AudioAnalysisStream(
            gate: session.gate,
            cancel: { session.cancel() }
        )
        let request = try AudioAnalysisRequest(
            audioTrackID: 0,
            range: 1.1..<1.8
        )
        let task = Task.detached {
            await AudioAnalysisRunner.run(
                session: session,
                input: input,
                request: request
            )
        }
        session.install(task: task)

        do {
            var iterator =
                stream.makeAsyncIterator()
            _ = try await iterator.next()
            XCTFail(
                "missing HLS resource unexpectedly produced analysis output"
            )
        } catch let error as AudioAnalysisError {
            guard case .hlsResourceFailure(
                let reason
            ) = error else {
                XCTFail(
                    "unexpected analysis error \(error)"
                )
                return
            }
            XCTAssertTrue(reason.contains("404"))
        }
        await task.value
    }

    private func makeFixture(
        declaredAudioChannels: String = "2",
        omitSecondAudioSegment: Bool = false,
        includeWebVTTSubtitles: Bool = false,
        omitSecondSubtitleSegment: Bool = false
    ) throws -> Fixture {
        let timeline =
            try BlackCarrierTimeline.mirroredHLSVOD(
                segmentDurations: [
                    CMTime(
                        value: 90_000,
                        timescale: 90_000
                    ),
                    CMTime(
                        value: 90_000,
                        timescale: 90_000
                    ),
                ]
            )
        let videoProvider =
            try BlackCarrierVideoProvider(
                timeline: timeline
            )
        defer { videoProvider.close() }
        let videoInitData = try XCTUnwrap(
            videoProvider.initSegment()
        )
        let videoSegments = try timeline.segments.map {
            timing in
            try XCTUnwrap(
                videoProvider.mediaSegment(
                    at: timing.index
                )
            )
        }
        let audio = try makeAudioFMP4(
            timeline: timeline
        )

        let rootURL = URL(
            string:
                "https://origin.example/master.m3u8"
        )!
        let effectiveRootURL = URL(
            string:
                "https://cdn.example/master.m3u8"
        )!
        let videoPlaylistURL = URL(
            string:
                "https://cdn.example/video/main.m3u8"
        )!
        let videoInitURL = URL(
            string:
                "https://cdn.example/video/init.mp4"
        )!
        let videoSegmentURLs = [
            URL(
                string:
                    "https://cdn.example/video/v0.m4s"
            )!,
            URL(
                string:
                    "https://cdn.example/video/v1.m4s"
            )!,
        ]
        let audioPlaylistURL = URL(
            string:
                "https://cdn.example/audio/en.m3u8"
        )!
        let audioInitURL = URL(
            string:
                "https://cdn.example/audio/init.mp4"
        )!
        let audioSegmentURLs = [
            URL(
                string:
                    "https://cdn.example/audio/a0.m4s"
            )!,
            URL(
                string:
                    "https://cdn.example/audio/a1.m4s"
            )!,
        ]
        let subtitlePlaylistURL = URL(
            string:
                "https://cdn.example/subtitles/en.m3u8"
        )!
        let subtitleSegmentURLs = [
            URL(
                string:
                    "https://cdn.example/subtitles/s0.vtt"
            )!,
            URL(
                string:
                    "https://cdn.example/subtitles/s1.vtt"
            )!,
        ]
        let subtitleSegments = [
            Data(
                "WEBVTT\n\n00:00:00.100 --> 00:00:00.900\nfirst\n"
                    .utf8
            ),
            Data(
                "WEBVTT\n\n00:00:01.100 --> 00:00:01.900\nsecond\n"
                    .utf8
            ),
        ]
        let videoMedia = HLSMediaPlaylist(
            targetDuration: 1,
            mediaSequence: 17,
            segments:
                videoSegmentURLs.map {
                    HLSMediaSegment(
                        uri: $0.lastPathComponent,
                        duration: 1,
                        discontinuityBefore: false
                    )
                },
            hasEndList: true,
            hasUnsupportedEncryption: false,
            hasMap: true,
            mapURI:
                videoInitURL.lastPathComponent,
            contentProtection: .none
        )
        let audioMedia = HLSMediaPlaylist(
            targetDuration: 1,
            mediaSequence: 31,
            segments:
                audioSegmentURLs.map {
                    HLSMediaSegment(
                        uri: $0.lastPathComponent,
                        duration: 1,
                        discontinuityBefore: false
                    )
                },
            hasEndList: true,
            hasUnsupportedEncryption: false,
            hasMap: true,
            mapURI:
                audioInitURL.lastPathComponent,
            contentProtection: .none
        )
        let audioResource =
            try HLSVODResourceGraph
                .makeAudioRendition(
                    ordinal: 0,
                    metadata:
                        HLSAudioRendition(
                            groupID: "audio",
                            uri: "en.m3u8",
                            name: "English",
                            language: "en",
                            isDefault: true,
                            isAutoselect: true,
                            channels:
                                declaredAudioChannels
                        ),
                    playlistURL:
                        audioPlaylistURL,
                    playlistData:
                        Data("#EXTM3U".utf8),
                    media: audioMedia
                )
        let subtitleResources:
            [HLSVODSubtitleRenditionResource]
        if includeWebVTTSubtitles {
            let subtitleMedia = HLSMediaPlaylist(
                targetDuration: 1,
                mediaSequence: 51,
                segments:
                    subtitleSegmentURLs.map {
                        HLSMediaSegment(
                            uri: $0.lastPathComponent,
                            duration: 1,
                            discontinuityBefore: false
                        )
                    },
                hasEndList: true,
                hasUnsupportedEncryption: false,
                hasMap: false,
                mapURI: nil,
                contentProtection: .none
            )
            subtitleResources = [
                try HLSVODResourceGraph
                    .makeSubtitleRendition(
                        ordinal: 0,
                        metadata: HLSSubtitleRendition(
                            groupID: "subs",
                            uri: "en.m3u8",
                            name: "English",
                            language: "en",
                            isDefault: true,
                            isAutoselect: true,
                            isForced: false
                        ),
                        playlistURL:
                            subtitlePlaylistURL,
                        playlistData:
                            Data("#EXTM3U".utf8),
                        media: subtitleMedia,
                        inspectedFirstSegmentData:
                            subtitleSegments[0],
                        inspectedFirstSegmentEffectiveURL:
                            subtitleSegmentURLs[0]
                    ),
            ]
        } else {
            subtitleResources = []
        }
        let graph = try HLSVODResourceGraph.make(
            requestedRootURL: rootURL,
            effectiveRootURL: effectiveRootURL,
            selectedMediaPlaylistURL:
                videoPlaylistURL,
            selectedVariant: HLSVariant(
                bandwidth: 1_400_000,
                uri: "video/main.m3u8",
                audioGroupID: "audio",
                subtitleGroupID:
                    includeWebVTTSubtitles
                    ? "subs"
                    : nil,
                codecs: ["avc1.42c01e"]
            ),
            separateAudioGroupID: "audio",
            mediaPlaylistData:
                Data("#EXTM3U".utf8),
            media: videoMedia,
            audioRenditions: [audioResource],
            separateSubtitleGroupID:
                includeWebVTTSubtitles
                ? "subs"
                : nil,
            subtitleRenditions:
                subtitleResources,
            inspectedInitSegmentData:
                videoInitData,
            inspectedInitSegmentEffectiveURL:
                videoInitURL,
            inspectedFirstMediaSegmentData:
                videoSegments[0],
            inspectedFirstMediaSegmentEffectiveURL:
                videoSegmentURLs[0],
            httpHeaders: [:]
        )
        let result = PlaybackPreflightResult(
            sourceProfile: AetherSourceProfile(
                sourceKind: .hls,
                isSeekableVOD: true,
                videoCodec: .h264,
                videoFormat: .sdr
            ),
            hlsPackaging: HLSVideoPackaging(
                container: .fragmentedMP4,
                sampleEntry: .avc1,
                manifestCodecs:
                    ["avc1.42c01e"],
                actualVideoCodec: .h264,
                codecVerification: .mismatch,
                contentProtection: .none
            ),
            route: .hybridCarrier,
            reason:
                .hybridHLSManifestSegmentMismatch
        )
        var responses: [
            URL: HLSVODOriginFetchResponse
        ] = [:]
        responses[videoSegmentURLs[1]] =
            response(
                data: videoSegments[1],
                url: videoSegmentURLs[1]
            )
        responses[audioInitURL] = response(
            data: audio.initData,
            url: audioInitURL
        )
        for index in audioSegmentURLs.indices
        where !omitSecondAudioSegment || index != 1 {
            responses[audioSegmentURLs[index]] =
                response(
                    data: audio.mediaSegments[index],
                    url: audioSegmentURLs[index]
                )
        }
        if includeWebVTTSubtitles,
           !omitSecondSubtitleSegment {
            responses[subtitleSegmentURLs[1]] = response(
                data: subtitleSegments[1],
                url: subtitleSegmentURLs[1]
            )
        }
        return Fixture(
            preflight: AetherHLSPlaybackPreflight(
                result: result,
                resourceGraph: graph,
                httpHeaders: [:]
            ),
            fetchStore: FetchStore(
                responses: responses
            ),
            videoSegmentURLs: videoSegmentURLs,
            audioSegmentURLs: audioSegmentURLs,
            audioSegmentBaseDecodeTimes:
                try audio.mediaSegments.map {
                    try XCTUnwrap(
                        fragmentBaseMediaDecodeTime($0)
                    )
                }
        )
    }

    private func makeMuxedFixture()
        throws -> MuxedFixture
    {
        let timeline =
            try BlackCarrierTimeline.mirroredHLSVOD(
                segmentDurations: [
                    CMTime(
                        value: 90_000,
                        timescale: 90_000
                    ),
                    CMTime(
                        value: 90_000,
                        timescale: 90_000
                    ),
                ]
            )
        let muxed = try makeMuxedAVFMP4(
            timeline: timeline
        )
        let rootURL = URL(
            string:
                "https://origin.example/muxed-master.m3u8"
        )!
        let effectiveRootURL = URL(
            string:
                "https://cdn.example/muxed-master.m3u8"
        )!
        let playlistURL = URL(
            string:
                "https://cdn.example/muxed/main.m3u8"
        )!
        let initURL = URL(
            string:
                "https://cdn.example/muxed/init.mp4"
        )!
        let segmentURLs = [
            URL(
                string:
                    "https://cdn.example/muxed/v0.m4s"
            )!,
            URL(
                string:
                    "https://cdn.example/muxed/v1.m4s"
            )!,
        ]
        let media = HLSMediaPlaylist(
            targetDuration: 1,
            mediaSequence: 41,
            segments:
                segmentURLs.map {
                    HLSMediaSegment(
                        uri: $0.lastPathComponent,
                        duration: 1,
                        discontinuityBefore: false
                    )
                },
            hasEndList: true,
            hasUnsupportedEncryption: false,
            hasMap: true,
            mapURI: initURL.lastPathComponent,
            contentProtection: .none
        )
        let graph = try HLSVODResourceGraph.make(
            requestedRootURL: rootURL,
            effectiveRootURL: effectiveRootURL,
            selectedMediaPlaylistURL: playlistURL,
            selectedVariant: HLSVariant(
                bandwidth: 1_800_000,
                uri: "muxed/main.m3u8",
                audioGroupID: nil,
                codecs: [
                    "avc1.42c01e",
                    "ec-3",
                ]
            ),
            separateAudioGroupID: nil,
            mediaPlaylistData:
                Data("#EXTM3U".utf8),
            media: media,
            audioRenditions: [],
            inspectedInitSegmentData:
                muxed.initData,
            inspectedInitSegmentEffectiveURL:
                initURL,
            inspectedFirstMediaSegmentData:
                muxed.mediaSegments[0],
            inspectedFirstMediaSegmentEffectiveURL:
                segmentURLs[0],
            httpHeaders: [:]
        )
        let result = PlaybackPreflightResult(
            sourceProfile: AetherSourceProfile(
                sourceKind: .hls,
                isSeekableVOD: true,
                videoCodec: .h264,
                videoFormat: .sdr
            ),
            hlsPackaging: HLSVideoPackaging(
                container: .fragmentedMP4,
                sampleEntry: .avc1,
                manifestCodecs: [
                    "avc1.42c01e",
                    "ec-3",
                ],
                actualVideoCodec: .h264,
                codecVerification: .mismatch,
                contentProtection: .none
            ),
            route: .hybridCarrier,
            reason:
                .hybridHLSManifestSegmentMismatch
        )
        let responses: [
            URL: HLSVODOriginFetchResponse
        ] = [
            segmentURLs[1]:
                response(
                    data: muxed.mediaSegments[1],
                    url: segmentURLs[1]
                ),
        ]
        return MuxedFixture(
            preflight: AetherHLSPlaybackPreflight(
                result: result,
                resourceGraph: graph,
                httpHeaders: [:]
            ),
            fetchStore: FetchStore(
                responses: responses
            ),
            videoSegmentURLs: segmentURLs
        )
    }

    private func response(
        data: Data,
        url: URL
    ) -> HLSVODOriginFetchResponse {
        HLSVODOriginFetchResponse(
            data: data,
            effectiveURL: url,
            statusCode: 200,
            contentLength: Int64(data.count),
            contentEncoding: nil
        )
    }

    private func fetchData(
        _ url: URL
    ) async throws -> Data {
        let (
            data,
            response
        ) = try await URLSession.shared.data(
            from: url
        )
        let http = try XCTUnwrap(
            response as? HTTPURLResponse
        )
        XCTAssertEqual(http.statusCode, 200)
        return data
    }

    private func fetchText(
        _ url: URL
    ) async throws -> String {
        let data = try await fetchData(url)
        return try XCTUnwrap(
            String(
                data: data,
                encoding: .utf8
            )
        )
    }

    private func makeAudioFMP4(
        timeline: BlackCarrierTimeline
    ) throws -> (
        initData: Data,
        mediaSegments: [Data]
    ) {
        let demuxer = Demuxer()
        try demuxer.open(
            reader: DataIOReader(
                data: makeWAV(
                    sampleRate: 48_000,
                    channels: 2,
                    seconds:
                        timeline.duration.seconds
                )
            ),
            formatHint: "wav"
        )
        defer { demuxer.close() }
        let directory =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "AetherHLSVODMediaPump-\(UUID().uuidString)",
                    isDirectory: true
                )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(
                at: directory
            )
        }
        var initData: Data?
        var mediaSegments: [Int: Data] = [:]
        _ = try BlackCarrierAudioRenditionMuxer.mux(
            demuxer: demuxer,
            audioStreamIndex:
                demuxer.audioStreamIndex,
            sourceStartPTS: 0,
            timeline: timeline,
            sessionDirectory: directory,
            onInit: {
                initData = $0
            },
            onSegment: {
                timing,
                path,
                bytesWritten in
                let data = try Data(
                    contentsOf: path
                )
                XCTAssertEqual(
                    data.count,
                    bytesWritten
                )
                mediaSegments[timing.index] =
                    data
            }
        )
        return (
            try XCTUnwrap(initData),
            try timeline.segments.map {
                try XCTUnwrap(
                    mediaSegments[$0.index]
                )
            }
        )
    }

    private func makeMuxedAVFMP4(
        timeline: BlackCarrierTimeline
    ) throws -> (
        initData: Data,
        mediaSegments: [Data]
    ) {
        let videoDemuxer = Demuxer()
        try videoDemuxer.open(
            reader: DataIOReader(
                data:
                    try BlackCarrierEncodedSample
                        .verifiedMP4Data()
            ),
            formatHint: "mp4"
        )
        defer { videoDemuxer.close() }
        let videoIndex =
            videoDemuxer.videoStreamIndex
        let videoStream = try XCTUnwrap(
            videoDemuxer.stream(at: videoIndex)
        )
        let sourceVideoPacket = try XCTUnwrap(
            try videoDemuxer.readPacket()
        )
        defer {
            var packet:
                UnsafeMutablePointer<AVPacket>? =
                    sourceVideoPacket
            trackedPacketFree(&packet)
        }

        let audioDemuxer = Demuxer()
        try audioDemuxer.open(
            reader: DataIOReader(
                data: makeWAV(
                    sampleRate: 48_000,
                    channels: 2,
                    seconds:
                        timeline.duration.seconds
                )
            ),
            formatHint: "wav"
        )
        defer { audioDemuxer.close() }
        let audioIndex =
            audioDemuxer.audioStreamIndex
        let audioStream = try XCTUnwrap(
            audioDemuxer.stream(at: audioIndex)
        )
        let bridge = try AudioBridge(
            srcCodecpar:
                audioStream.pointee.codecpar,
            srcTimeBase:
                audioStream.pointee.time_base,
            mode: .surroundCompat
        )
        defer { bridge.close() }
        let encoderParameters = try XCTUnwrap(
            bridge.encoderCodecpar
        )

        let directory =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "AetherHLSVODMuxed-\(UUID().uuidString)",
                    isDirectory: true
                )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(
                at: directory
            )
        }
        var initData: Data?
        let muxer = try MP4SegmentMuxer(
            initialSegmentIndex: 0,
            sessionDir: directory,
            video: MP4SegmentMuxer.VideoConfig(
                codecpar:
                    UnsafePointer(
                        videoStream.pointee.codecpar
                    ),
                timeBase:
                    videoStream.pointee.time_base,
                codecTagOverride: "avc1"
            ),
            audio: MP4SegmentMuxer.AudioConfig(
                codecpar:
                    UnsafePointer(
                        encoderParameters
                    ),
                timeBase:
                    bridge.encoderTimeBase
            ),
            onInitCaptured: {
                initData = $0
            }
        )
        var packets: [
            (
                isVideo: Bool,
                timeBase: AVRational,
                packet: UnsafeMutablePointer<AVPacket>
            )
        ] = []
        defer {
            for entry in packets {
                var packet:
                    UnsafeMutablePointer<AVPacket>? =
                        entry.packet
                trackedPacketFree(&packet)
            }
        }

        for timing in timeline.segments {
            let packet = try XCTUnwrap(
                av_packet_clone(
                    sourceVideoPacket
                )
            )
            packet.pointee.pts = av_rescale_q(
                timing.startTime.value,
                AVRational(
                    num: 1,
                    den:
                        timing.startTime.timescale
                ),
                videoStream.pointee.time_base
            )
            packet.pointee.dts =
                packet.pointee.pts
            packet.pointee.duration =
                av_rescale_q(
                    timing.duration.value,
                    AVRational(
                        num: 1,
                        den:
                            timing.duration.timescale
                    ),
                    videoStream.pointee.time_base
                )
            packets.append((
                isVideo: true,
                timeBase:
                    videoStream.pointee.time_base,
                packet: packet
            ))
        }

        while let sourcePacket =
                try audioDemuxer.readPacket() {
            var packetToFree:
                UnsafeMutablePointer<AVPacket>? =
                    sourcePacket
            defer {
                trackedPacketFree(
                    &packetToFree
                )
            }
            guard sourcePacket.pointee.stream_index
                    == audioIndex else {
                continue
            }
            for packet in try bridge.feed(
                packet: sourcePacket
            ) {
                packets.append((
                    isVideo: false,
                    timeBase:
                        bridge.encoderTimeBase,
                    packet: packet
                ))
            }
        }
        for packet in bridge.flush() {
            packets.append((
                isVideo: false,
                timeBase:
                    bridge.encoderTimeBase,
                packet: packet
            ))
        }
        packets.sort {
            packetTime(
                $0.packet,
                timeBase: $0.timeBase
            ) < packetTime(
                $1.packet,
                timeBase: $1.timeBase
            )
        }

        var mediaSegments: [Int: Data] = [:]
        var nextSegmentIndex = 1
        for entry in packets {
            let time = packetTime(
                entry.packet,
                timeBase: entry.timeBase
            )
            while nextSegmentIndex
                    < timeline.segments.count,
                  time >= timeline.segments[
                    nextSegmentIndex
                  ].startTime.seconds {
                let completed = try XCTUnwrap(
                    muxer.cutFragmentForNextSegment(
                        nextSegmentIndex
                    )
                )
                mediaSegments[
                    nextSegmentIndex - 1
                ] = try Data(
                    contentsOf: completed.path
                )
                nextSegmentIndex += 1
            }
            entry.packet.pointee.stream_index =
                entry.isVideo
                ? muxer.videoOutputStreamIndex
                : muxer.audioOutputStreamIndex
            av_packet_rescale_ts(
                entry.packet,
                entry.timeBase,
                entry.isVideo
                    ? muxer.muxerVideoTimeBase
                    : muxer.muxerAudioTimeBase
            )
            XCTAssertGreaterThanOrEqual(
                muxer.writePacket(entry.packet),
                0
            )
        }
        let final = try XCTUnwrap(
            muxer.finalize()
        )
        mediaSegments[
            muxer.currentSegmentIndex
        ] = try Data(
            contentsOf: final.path
        )
        return (
            try XCTUnwrap(initData),
            try timeline.segments.map {
                try XCTUnwrap(
                    mediaSegments[$0.index]
                )
            }
        )
    }

    private func packetTime(
        _ packet: UnsafeMutablePointer<AVPacket>,
        timeBase: AVRational
    ) -> Double {
        let timestamp =
            packet.pointee.dts != Int64.min
            ? packet.pointee.dts
            : packet.pointee.pts
        return Double(timestamp)
            * Double(timeBase.num)
            / Double(timeBase.den)
    }

    private func assertAudioSegment(
        initData: Data,
        mediaData: Data,
        minimumPTS: Int64,
        maximumPTS: Int64
    ) throws {
        let demuxer = Demuxer()
        try demuxer.open(
            reader: DataIOReader(
                data: initData + mediaData
            ),
            formatHint: "mp4"
        )
        defer { demuxer.close() }
        XCTAssertEqual(
            demuxer.audioTrackInfos().count,
            1
        )
        var packetCount = 0
        while let packet = try demuxer.readPacket() {
            var packetToFree:
                UnsafeMutablePointer<AVPacket>? =
                    packet
            defer {
                trackedPacketFree(&packetToFree)
            }
            guard packet.pointee.stream_index
                == demuxer.audioStreamIndex else {
                continue
            }
            XCTAssertGreaterThanOrEqual(
                packet.pointee.pts,
                minimumPTS
            )
            XCTAssertLessThan(
                packet.pointee.pts,
                maximumPTS
            )
            packetCount += 1
        }
        XCTAssertGreaterThan(packetCount, 0)
    }

    private func makeWAV(
        sampleRate: Int,
        channels: Int,
        seconds: Double
    ) -> Data {
        let frameCount = Int(
            Double(sampleRate) * seconds
        )
        let bytesPerSample = 2
        let blockAlign = channels * bytesPerSample
        let payloadSize = frameCount * blockAlign
        var data = Data()
        func appendASCII(_ value: String) {
            data.append(
                value.data(using: .ascii)!
            )
        }
        func appendUInt16(_ value: UInt16) {
            withUnsafeBytes(
                of: value.littleEndian
            ) {
                data.append(contentsOf: $0)
            }
        }
        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(
                of: value.littleEndian
            ) {
                data.append(contentsOf: $0)
            }
        }
        appendASCII("RIFF")
        appendUInt32(UInt32(36 + payloadSize))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(UInt16(channels))
        appendUInt32(UInt32(sampleRate))
        appendUInt32(
            UInt32(sampleRate * blockAlign)
        )
        appendUInt16(UInt16(blockAlign))
        appendUInt16(16)
        appendASCII("data")
        appendUInt32(UInt32(payloadSize))
        for frame in 0..<frameCount {
            let sample = Int16(
                sin(
                    2 * .pi * 440
                        * Double(frame)
                        / Double(sampleRate)
                ) * 12_000
            )
            for _ in 0..<channels {
                appendUInt16(
                    UInt16(
                        bitPattern: sample
                    )
                )
            }
        }
        return data
    }

    private struct Box {
        let type: String
        let start: Int
        let end: Int
        let headerSize: Int
    }

    private func boxes(
        in data: Data,
        range: Range<Int>
    ) -> [Box] {
        var result: [Box] = []
        var cursor = range.lowerBound
        while cursor + 8 <= range.upperBound {
            let size32 = Int(
                readUInt32(data, at: cursor)
            )
            let typeData = data[
                (cursor + 4)..<(cursor + 8)
            ]
            let type = String(
                data: typeData,
                encoding: .ascii
            ) ?? ""
            var size = size32
            var headerSize = 8
            if size32 == 1,
               cursor + 16 <= range.upperBound {
                size = Int(
                    readUInt64(
                        data,
                        at: cursor + 8
                    )
                )
                headerSize = 16
            } else if size32 == 0 {
                size = range.upperBound - cursor
            }
            guard size >= headerSize,
                  cursor + size
                    <= range.upperBound else {
                break
            }
            result.append(
                Box(
                    type: type,
                    start: cursor,
                    end: cursor + size,
                    headerSize: headerSize
                )
            )
            cursor += size
        }
        return result
    }

    private func fragmentBaseMediaDecodeTime(
        _ data: Data
    ) -> UInt64? {
        guard let moof = boxes(
            in: data,
            range: 0..<data.count
        ).first(where: { $0.type == "moof" }),
        let traf = boxes(
            in: data,
            range: (
                moof.start + moof.headerSize
            )..<moof.end
        ).first(where: { $0.type == "traf" }),
        let tfdt = boxes(
            in: data,
            range: (
                traf.start + traf.headerSize
            )..<traf.end
        ).first(where: { $0.type == "tfdt" })
        else {
            return nil
        }
        let payload = tfdt.start + tfdt.headerSize
        guard payload + 8 <= tfdt.end else {
            return nil
        }
        let version = data[payload]
        if version == 1 {
            guard payload + 12 <= tfdt.end else {
                return nil
            }
            return readUInt64(
                data,
                at: payload + 4
            )
        }
        return UInt64(
            readUInt32(
                data,
                at: payload + 4
            )
        )
    }

    private func readUInt32(
        _ data: Data,
        at offset: Int
    ) -> UInt32 {
        data[
            offset..<(offset + 4)
        ].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
    }

    private func readUInt64(
        _ data: Data,
        at offset: Int
    ) -> UInt64 {
        data[
            offset..<(offset + 8)
        ].reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
    }
}
