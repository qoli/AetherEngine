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
            try await pump.finishProduction()
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
                .finishProduction()
            XCTFail(
                "seek generation unexpectedly produced full-asset bandwidth evidence"
            )
        } catch let error
                as HLSVODMediaPumpError {
            XCTAssertEqual(
                error,
                .fullAssetSummaryUnavailableAfterRestart(
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
        let measurementPump =
            try await HLSVODMediaPump.make(
                preflight: fixture.preflight,
                fetchOverride: { request, _ in
                    try fixture.fetchStore.response(
                        for: request
                    )
                }
            )
        let summaries =
            try await measurementPump
                .finishProduction()
        try await measurementPump.close()
        let admissions = summaries.enumerated().map {
            ordinal,
            summary in
            BlackCarrierAudioBandwidthAdmission(
                ordinal: ordinal,
                evidence: .measuredFullAsset(
                    peakBandwidth:
                        summary.peakBandwidth,
                    averageBandwidth:
                        summary.averageBandwidth
                )
            )
        }
        let provider =
            try await HLSVODCarrierProvider.make(
                preflight: fixture.preflight,
                bandwidthAdmissions: admissions,
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

    func testCarrierProviderRejectsMissingBandwidthEvidence()
        async throws
    {
        let fixture = try makeFixture()
        do {
            _ = try await HLSVODCarrierProvider.make(
                preflight: fixture.preflight,
                bandwidthAdmissions: [],
                fetchOverride: { request, _ in
                    try fixture.fetchStore.response(
                        for: request
                    )
                }
            )
            XCTFail(
                "provider unexpectedly invented audio bandwidth"
            )
        } catch let error
                as HLSVODCarrierProviderError {
            XCTAssertEqual(
                error,
                .admissionCountMismatch(
                    expected: 1,
                    actual: 0
                )
            )
        }
    }

    private func makeFixture(
        declaredAudioChannels: String = "2"
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
        let graph = try HLSVODResourceGraph.make(
            requestedRootURL: rootURL,
            effectiveRootURL: effectiveRootURL,
            selectedMediaPlaylistURL:
                videoPlaylistURL,
            selectedVariant: HLSVariant(
                bandwidth: 1_400_000,
                uri: "video/main.m3u8",
                audioGroupID: "audio",
                codecs: ["avc1.42c01e"]
            ),
            separateAudioGroupID: "audio",
            mediaPlaylistData:
                Data("#EXTM3U".utf8),
            media: videoMedia,
            audioRenditions: [audioResource],
            inspectedInitSegmentData:
                videoInitData,
            inspectedFirstMediaSegmentData:
                videoSegments[0],
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
                codecVerification: .verified,
                contentProtection: .none
            ),
            route: .hybridCarrierMetal,
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
        for index in audioSegmentURLs.indices {
            responses[audioSegmentURLs[index]] =
                response(
                    data: audio.mediaSegments[index],
                    url: audioSegmentURLs[index]
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
