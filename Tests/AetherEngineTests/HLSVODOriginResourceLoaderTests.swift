import CoreMedia
import Foundation
import XCTest
@testable import AetherEngine

final class HLSVODOriginResourceLoaderTests: XCTestCase {
    private struct Fixture {
        let graph: HLSVODResourceGraph
        let videoInitData: Data
        let videoFirstSegmentData: Data
        let videoFirstSegmentEffectiveURL: URL
        let audioFirstSegmentData: Data
        let audioFirstSegmentURL: URL
    }

    private actor FetchRecorder {
        private let responses: [
            URL:
                HLSVODOriginFetchResponse
        ]
        private let delayNanoseconds: UInt64
        private var requests: [URLRequest] = []

        init(
            responses: [URL: HLSVODOriginFetchResponse],
            delayNanoseconds: UInt64 = 0
        ) {
            self.responses = responses
            self.delayNanoseconds = delayNanoseconds
        }

        func fetch(
            _ request: URLRequest,
            maximumBytes: Int
        ) async throws -> HLSVODOriginFetchResponse {
            requests.append(request)
            if delayNanoseconds > 0 {
                try await Task.sleep(
                    nanoseconds: delayNanoseconds
                )
            }
            guard let url = request.url,
                  let response = responses[url] else {
                throw HLSVODOriginResourceError.httpStatus(404)
            }
            return response
        }

        var requestCount: Int {
            requests.count
        }

        func headers(at index: Int) -> [String: String]? {
            guard requests.indices.contains(index) else {
                return nil
            }
            return requests[index].allHTTPHeaderFields
        }
    }

    private actor ScheduledFetchRecorder {
        private let responses: [
            URL: HLSVODOriginFetchResponse
        ]
        private let blockedURLs: Set<URL>
        private var releasedURLs: Set<URL> = []
        private var requests: [URL] = []

        init(
            responses: [
                URL: HLSVODOriginFetchResponse
            ],
            blockedURLs: Set<URL>
        ) {
            self.responses = responses
            self.blockedURLs = blockedURLs
        }

        func fetch(
            _ request: URLRequest,
            maximumBytes: Int
        ) async throws -> HLSVODOriginFetchResponse {
            guard let url = request.url else {
                throw HLSVODOriginResourceError
                    .transportFailure
            }
            requests.append(url)
            while blockedURLs.contains(url),
                  !releasedURLs.contains(url) {
                try await Task.sleep(
                    for: .milliseconds(5)
                )
            }
            guard let response = responses[url] else {
                throw HLSVODOriginResourceError
                    .httpStatus(404)
            }
            return response
        }

        func waitForRequestCount(
            _ expected: Int
        ) async throws {
            for _ in 0..<400 {
                if requests.count >= expected {
                    return
                }
                try await Task.sleep(
                    for: .milliseconds(5)
                )
            }
            throw HLSVODOriginResourceError
                .transportFailure
        }

        func release(_ url: URL) {
            releasedURLs.insert(url)
        }

        var requestedURLs: [URL] {
            requests
        }
    }

    func testTransportDispositionSeparatesTransientSecurityCancellationAndInvariant() {
        XCTAssertEqual(
            HLSVODOriginResourceLoader.transportDisposition(
                for: .networkConnectionLost
            ),
            .transient
        )
        XCTAssertEqual(
            HLSVODOriginResourceLoader.transportDisposition(
                for: .cancelled
            ),
            .cancelled
        )
        XCTAssertEqual(
            HLSVODOriginResourceLoader.transportDisposition(
                for: .serverCertificateUntrusted
            ),
            .security
        )
        XCTAssertEqual(
            HLSVODOriginResourceLoader.transportDisposition(
                for: .badURL
            ),
            .invariant
        )
    }

    func testRetryAfterDeltaSecondsIsPreserved() {
        XCTAssertEqual(
            HLSVODBoundedHTTPFetcher.retryAfterSeconds("4"),
            4
        )
        XCTAssertNil(
            HLSVODBoundedHTTPFetcher.retryAfterSeconds("not-a-date")
        )
    }

    func testPreflightEvidenceSeedsVideoAndAudioFetchIsSingleFlight()
        async throws
    {
        let fixture = try makeFixture()
        let audioResponse = HLSVODOriginFetchResponse(
            data: fixture.audioFirstSegmentData,
            effectiveURL: fixture.audioFirstSegmentURL,
            statusCode: 200,
            contentLength:
                Int64(fixture.audioFirstSegmentData.count),
            contentEncoding: nil
        )
        let recorder = FetchRecorder(
            responses: [
                fixture.audioFirstSegmentURL: audioResponse,
            ],
            delayNanoseconds: 100_000_000
        )
        let headers = [
            "Authorization": "Bearer secret",
            "Referer": "https://example.com/",
        ]
        let loader = try HLSVODOriginResourceLoader(
            graph: fixture.graph,
            httpHeaders: headers,
            fetchOverride: { request, maximumBytes in
                try await recorder.fetch(
                    request,
                    maximumBytes: maximumBytes
                )
            }
        )
        let directory = await loader.sessionDirectory

        let videoInit = try await loader.payload(
            for: .videoInit
        )
        let firstVideo = try await loader.payload(
            for: .videoSegment(index: 0)
        )
        XCTAssertEqual(videoInit.data, fixture.videoInitData)
        XCTAssertEqual(
            firstVideo.data,
            fixture.videoFirstSegmentData
        )
        XCTAssertEqual(
            firstVideo.effectiveURL,
            fixture.videoFirstSegmentEffectiveURL
        )
        let seededRequestCount = await recorder.requestCount
        XCTAssertEqual(seededRequestCount, 0)

        let firstAudio = Task {
            try await loader.payload(
                for: .audioSegment(
                    renditionOrdinal: 0,
                    index: 0
                )
            )
        }
        let secondAudio = Task {
            try await loader.payload(
                for: .audioSegment(
                    renditionOrdinal: 0,
                    index: 0
                )
            )
        }
        try await waitForWaiters(2, loader: loader)

        let firstPayload = try await firstAudio.value
        let secondPayload = try await secondAudio.value
        XCTAssertEqual(
            firstPayload.data,
            fixture.audioFirstSegmentData
        )
        XCTAssertEqual(firstPayload, secondPayload)
        let singleFlightRequestCount =
            await recorder.requestCount
        XCTAssertEqual(singleFlightRequestCount, 1)
        let recordedHeaders = await recorder.headers(at: 0)
        let seenHeaders = try XCTUnwrap(recordedHeaders)
        XCTAssertEqual(
            seenHeaders["Authorization"],
            headers["Authorization"]
        )
        XCTAssertEqual(
            seenHeaders["Referer"],
            headers["Referer"]
        )
        XCTAssertEqual(
            seenHeaders["Accept-Encoding"],
            "identity"
        )

        let snapshot = await loader.snapshot
        XCTAssertEqual(snapshot.cachedResourceCount, 3)
        XCTAssertEqual(snapshot.inFlightResourceCount, 0)
        XCTAssertEqual(snapshot.inFlightWaiterCount, 0)
        XCTAssertEqual(
            snapshot.cachedBytes,
            Int64(
                fixture.videoInitData.count
                    + fixture.videoFirstSegmentData.count
                    + fixture.audioFirstSegmentData.count
            )
        )
        let cacheFiles = try FileManager.default
            .contentsOfDirectory(
                atPath: directory.path
            )
            .sorted()
        XCTAssertEqual(
            cacheFiles,
            [
                "audio-0-segment-0",
                "video-init",
                "video-segment-0",
            ]
        )
        XCTAssertFalse(
            cacheFiles.joined().contains("secret")
        )

        try await loader.close()
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.path
            )
        )
    }

    func testCorruptExactCacheEntryRefetchesTheSameBoundResource()
        async throws
    {
        let fixture = try makeFixture()
        let response = HLSVODOriginFetchResponse(
            data: fixture.audioFirstSegmentData,
            effectiveURL: fixture.audioFirstSegmentURL,
            statusCode: 200,
            contentLength: Int64(
                fixture.audioFirstSegmentData.count
            ),
            contentEncoding: nil
        )
        let recorder = FetchRecorder(
            responses: [
                fixture.audioFirstSegmentURL: response,
            ]
        )
        let loader = try HLSVODOriginResourceLoader(
            graph: fixture.graph,
            httpHeaders: [:],
            fetchOverride: { request, maximumBytes in
                try await recorder.fetch(
                    request,
                    maximumBytes: maximumBytes
                )
            }
        )
        let key = HLSVODOriginResourceKey.audioSegment(
            renditionOrdinal: 0,
            index: 0
        )
        let first = try await loader.payload(for: key)
        XCTAssertEqual(first.data, fixture.audioFirstSegmentData)

        let directory = await loader.sessionDirectory
        try Data("corrupt".utf8).write(
            to: directory.appendingPathComponent(
                "audio-0-segment-0"
            ),
            options: [.atomic]
        )

        let recovered = try await loader.payload(for: key)
        XCTAssertEqual(recovered.data, fixture.audioFirstSegmentData)
        XCTAssertEqual(
            recovered.sha256,
            HLSVODResourceDigest.sha256(
                fixture.audioFirstSegmentData
            )
        )
        let recoveredRequestCount = await recorder.requestCount
        XCTAssertEqual(recoveredRequestCount, 2)
        let snapshot = await loader.snapshot
        XCTAssertTrue(snapshot.cacheIsAvailable)
        XCTAssertEqual(snapshot.cacheFailureCount, 1)
        XCTAssertEqual(snapshot.cachedResourceCount, 1)
        try await loader.close()
    }

    func testUnavailableCacheDoesNotTerminateVerifiedOriginDelivery()
        async throws
    {
        let fixture = try makeFixture()
        let basePath = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("not-a-directory".utf8).write(to: basePath)
        defer { try? FileManager.default.removeItem(at: basePath) }
        let recorder = FetchRecorder(
            responses: [
                fixture.audioFirstSegmentURL:
                    HLSVODOriginFetchResponse(
                        data: fixture.audioFirstSegmentData,
                        effectiveURL:
                            fixture.audioFirstSegmentURL,
                        statusCode: 200,
                        contentLength: Int64(
                            fixture.audioFirstSegmentData.count
                        ),
                        contentEncoding: nil
                    ),
            ]
        )
        let loader = try HLSVODOriginResourceLoader(
            graph: fixture.graph,
            httpHeaders: [:],
            baseDirectory: basePath,
            fetchOverride: { request, maximumBytes in
                try await recorder.fetch(
                    request,
                    maximumBytes: maximumBytes
                )
            }
        )

        let payload = try await loader.payload(
            for: .audioSegment(
                renditionOrdinal: 0,
                index: 0
            )
        )
        XCTAssertEqual(payload.data, fixture.audioFirstSegmentData)
        let requestCount = await recorder.requestCount
        XCTAssertEqual(requestCount, 1)
        let snapshot = await loader.snapshot
        XCTAssertFalse(snapshot.cacheIsAvailable)
        XCTAssertEqual(snapshot.cacheFailureCount, 1)
        XCTAssertEqual(snapshot.cachedResourceCount, 0)
        try await loader.close()
    }

    func testCancellingOneWaiterKeepsSharedFetchAlive()
        async throws
    {
        let fixture = try makeFixture()
        let recorder = FetchRecorder(
            responses: [
                fixture.audioFirstSegmentURL:
                    HLSVODOriginFetchResponse(
                        data: fixture.audioFirstSegmentData,
                        effectiveURL:
                            fixture.audioFirstSegmentURL,
                        statusCode: 200,
                        contentLength:
                            Int64(
                                fixture.audioFirstSegmentData
                                    .count
                            ),
                        contentEncoding: nil
                    ),
            ],
            delayNanoseconds: 200_000_000
        )
        let loader = try HLSVODOriginResourceLoader(
            graph: fixture.graph,
            httpHeaders: [:],
            fetchOverride: { request, maximumBytes in
                try await recorder.fetch(
                    request,
                    maximumBytes: maximumBytes
                )
            }
        )
        let key = HLSVODOriginResourceKey.audioSegment(
            renditionOrdinal: 0,
            index: 0
        )
        let cancelled = Task {
            try await loader.payload(for: key)
        }
        let survivor = Task {
            try await loader.payload(for: key)
        }
        try await waitForWaiters(2, loader: loader)

        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("cancelled waiter unexpectedly received data")
        } catch is CancellationError {
            // Expected: cancellation detaches only this waiter.
        }
        let pendingSnapshot = await loader.snapshot
        XCTAssertEqual(pendingSnapshot.inFlightResourceCount, 1)
        XCTAssertEqual(pendingSnapshot.inFlightWaiterCount, 1)

        let payload = try await survivor.value
        XCTAssertEqual(
            payload.data,
            fixture.audioFirstSegmentData
        )
        let requestCount = await recorder.requestCount
        XCTAssertEqual(requestCount, 1)
        try await loader.close()
    }

    func testAnalysisDeliveryDistinguishesOriginFetchFromReuse()
        async throws
    {
        let fixture = try makeFixture()
        let recorder = FetchRecorder(
            responses: [
                fixture.audioFirstSegmentURL:
                    HLSVODOriginFetchResponse(
                        data: fixture.audioFirstSegmentData,
                        effectiveURL:
                            fixture.audioFirstSegmentURL,
                        statusCode: 200,
                        contentLength: Int64(
                            fixture.audioFirstSegmentData.count
                        ),
                        contentEncoding: nil
                    ),
            ]
        )
        let loader = try HLSVODOriginResourceLoader(
            graph: fixture.graph,
            httpHeaders: [:],
            fetchOverride: { request, maximumBytes in
                try await recorder.fetch(
                    request,
                    maximumBytes: maximumBytes
                )
            }
        )
        let key = HLSVODOriginResourceKey.audioSegment(
            renditionOrdinal: 0,
            index: 0
        )

        let fetched = try await loader.payloadWithDelivery(
            for: key,
            purpose: .analysis
        )
        let reused = try await loader.payloadWithDelivery(
            for: key,
            purpose: .analysis
        )

        XCTAssertEqual(fetched.source, .analysisOriginFetch)
        XCTAssertEqual(reused.source, .reused)
        XCTAssertEqual(
            fetched.payload.data,
            fixture.audioFirstSegmentData
        )
        let requestCount = await recorder.requestCount
        XCTAssertEqual(requestCount, 1)
        try await loader.close()
    }

    func testAnalysisSchedulerAllowsOnlyOneOriginFetch()
        async throws
    {
        let fixture = try makeFixture()
        let audioSegments =
            fixture.graph.audioRenditions[0]
                .segments
        let firstURL = audioSegments[0].url
        let secondURL = audioSegments[1].url
        let recorder = ScheduledFetchRecorder(
            responses: [
                firstURL:
                    response(
                        data:
                            fixture.audioFirstSegmentData,
                        url: firstURL
                    ),
                secondURL:
                    response(
                        data:
                            fixture.audioFirstSegmentData,
                        url: secondURL
                    ),
            ],
            blockedURLs: [firstURL]
        )
        let loader = try HLSVODOriginResourceLoader(
            graph: fixture.graph,
            httpHeaders: [:],
            fetchOverride: { request, maximumBytes in
                try await recorder.fetch(
                    request,
                    maximumBytes: maximumBytes
                )
            }
        )
        let first = Task {
            try await loader.payload(
                for: .audioSegment(
                    renditionOrdinal: 0,
                    index: 0
                ),
                purpose: .analysis
            )
        }
        try await recorder.waitForRequestCount(1)
        let second = Task {
            try await loader.payload(
                for: .audioSegment(
                    renditionOrdinal: 0,
                    index: 1
                ),
                purpose: .analysis
            )
        }
        try await waitForAnalysisScheduler(
            active: 1,
            queued: 1,
            loader: loader
        )
        let queued = await loader.snapshot
        XCTAssertEqual(
            queued.activeAnalysisFetchCount,
            1
        )
        XCTAssertEqual(
            queued.activePlaybackFetchCount,
            0
        )
        let requestsWhileQueued =
            await recorder.requestedURLs
        XCTAssertEqual(
            requestsWhileQueued,
            [firstURL],
            "a second analysis resource must stay queued while the first origin fetch is active"
        )

        await recorder.release(firstURL)
        _ = try await first.value
        try await recorder.waitForRequestCount(2)
        _ = try await second.value
        let completedRequests =
            await recorder.requestedURLs
        XCTAssertEqual(
            completedRequests,
            [
                firstURL,
                secondURL,
            ]
        )
        let final = await loader.snapshot
        XCTAssertEqual(
            final.activeAnalysisRequestCount,
            0
        )
        XCTAssertEqual(
            final.queuedAnalysisRequestCount,
            0
        )
        try await loader.close()
    }

    func testDeclaredPlaybackPressureQueuesAnalysisBeforeFetch()
        async throws
    {
        let fixture = try makeFixture()
        let firstURL =
            fixture.graph.audioRenditions[0]
                .segments[0].url
        let recorder = ScheduledFetchRecorder(
            responses: [
                firstURL:
                    response(
                        data:
                            fixture.audioFirstSegmentData,
                        url: firstURL
                    ),
            ],
            blockedURLs: []
        )
        let loader = try HLSVODOriginResourceLoader(
            graph: fixture.graph,
            httpHeaders: [:],
            fetchOverride: { request, maximumBytes in
                try await recorder.fetch(
                    request,
                    maximumBytes: maximumBytes
                )
            }
        )
        await loader.setAudioAnalysisPlaybackPressure(
            .carrierWaitingToPlay
        )
        let analysis = Task {
            try await loader.payload(
                for: .audioSegment(
                    renditionOrdinal: 0,
                    index: 0
                ),
                purpose: .analysis
            )
        }
        try await waitForAnalysisScheduler(
            active: 0,
            queued: 1,
            loader: loader
        )
        let pressured = await loader.snapshot
        XCTAssertEqual(
            pressured.declaredPlaybackPressure,
            .carrierWaitingToPlay
        )
        let requestsWhilePressured =
            await recorder.requestedURLs
        XCTAssertEqual(requestsWhilePressured, [])

        await loader.setAudioAnalysisPlaybackPressure(.none)
        try await recorder.waitForRequestCount(1)
        let payload = try await analysis.value
        XCTAssertEqual(
            payload.data,
            fixture.audioFirstSegmentData
        )
        let requestsAfterPressure =
            await recorder.requestedURLs
        XCTAssertEqual(requestsAfterPressure, [firstURL])
        try await loader.close()
    }

    func testDeclaredPlaybackPressurePausesAndResumesExactAnalysisKey()
        async throws
    {
        let fixture = try makeFixture()
        let firstURL =
            fixture.graph.audioRenditions[0]
                .segments[0].url
        let recorder = ScheduledFetchRecorder(
            responses: [
                firstURL:
                    response(
                        data:
                            fixture.audioFirstSegmentData,
                        url: firstURL
                    ),
            ],
            blockedURLs: [firstURL]
        )
        let loader = try HLSVODOriginResourceLoader(
            graph: fixture.graph,
            httpHeaders: [:],
            fetchOverride: { request, maximumBytes in
                try await recorder.fetch(
                    request,
                    maximumBytes: maximumBytes
                )
            }
        )
        let analysis = Task {
            try await loader.payload(
                for: .audioSegment(
                    renditionOrdinal: 0,
                    index: 0
                ),
                purpose: .analysis
            )
        }
        try await recorder.waitForRequestCount(1)

        await loader.setAudioAnalysisPlaybackPressure(
            .carrierForwardBufferLow
        )
        try await waitForAnalysisScheduler(
            active: 1,
            queued: 0,
            paused: 1,
            loader: loader
        )
        let paused = await loader.snapshot
        XCTAssertEqual(
            paused.declaredPlaybackPressure,
            .carrierForwardBufferLow
        )
        XCTAssertEqual(paused.analysisPreemptionCount, 1)
        XCTAssertEqual(paused.activeAnalysisFetchCount, 0)
        let requestsWhilePaused =
            await recorder.requestedURLs
        XCTAssertEqual(requestsWhilePaused, [firstURL])

        await loader.setAudioAnalysisPlaybackPressure(.none)
        try await recorder.waitForRequestCount(2)
        let resumedRequests =
            await recorder.requestedURLs
        XCTAssertEqual(
            resumedRequests,
            [firstURL, firstURL],
            "clearing declared pressure must resume the same admitted key"
        )
        await recorder.release(firstURL)
        let payload = try await analysis.value
        XCTAssertEqual(
            payload.data,
            fixture.audioFirstSegmentData
        )
        let completed = await loader.snapshot
        XCTAssertEqual(
            completed.declaredPlaybackPressure,
            .none
        )
        try await loader.close()
    }

    func testCancellingDeclaredPressureQueueNeverStartsAfterClear()
        async throws
    {
        let fixture = try makeFixture()
        let firstURL =
            fixture.graph.audioRenditions[0]
                .segments[0].url
        let recorder = ScheduledFetchRecorder(
            responses: [
                firstURL:
                    response(
                        data:
                            fixture.audioFirstSegmentData,
                        url: firstURL
                    ),
            ],
            blockedURLs: []
        )
        let loader = try HLSVODOriginResourceLoader(
            graph: fixture.graph,
            httpHeaders: [:],
            fetchOverride: { request, maximumBytes in
                try await recorder.fetch(
                    request,
                    maximumBytes: maximumBytes
                )
            }
        )
        await loader.setAudioAnalysisPlaybackPressure(
            .carrierPlaybackStalled
        )
        let analysis = Task {
            try await loader.payload(
                for: .audioSegment(
                    renditionOrdinal: 0,
                    index: 0
                ),
                purpose: .analysis
            )
        }
        try await waitForAnalysisScheduler(
            active: 0,
            queued: 1,
            loader: loader
        )

        analysis.cancel()
        do {
            _ = try await analysis.value
            XCTFail(
                "cancelled pressure-queued analysis unexpectedly completed"
            )
        } catch is CancellationError {
            // Expected.
        }
        try await waitForAnalysisScheduler(
            active: 0,
            queued: 0,
            loader: loader
        )
        await loader.setAudioAnalysisPlaybackPressure(.none)
        try await Task.sleep(for: .milliseconds(25))
        let requestedURLs =
            await recorder.requestedURLs
        XCTAssertEqual(
            requestedURLs,
            [],
            "clearing pressure must not revive a cancelled queued analysis request"
        )
        try await loader.close()
    }

    func testPlaybackBypassesQueuedAnalysisAndKeepsPriority()
        async throws
    {
        let fixture = try makeFixture()
        let audioSegments =
            fixture.graph.audioRenditions[0]
                .segments
        let firstAudioURL = audioSegments[0].url
        let secondAudioURL = audioSegments[1].url
        let secondVideoURL =
            fixture.graph.segments[1].url
        let recorder = ScheduledFetchRecorder(
            responses: [
                firstAudioURL:
                    response(
                        data:
                            fixture.audioFirstSegmentData,
                        url: firstAudioURL
                    ),
                secondAudioURL:
                    response(
                        data:
                            fixture.audioFirstSegmentData,
                        url: secondAudioURL
                    ),
                secondVideoURL:
                    response(
                        data:
                            fixture.videoFirstSegmentData,
                        url: secondVideoURL
                    ),
            ],
            blockedURLs: [
                firstAudioURL,
                secondVideoURL,
            ]
        )
        let loader = try HLSVODOriginResourceLoader(
            graph: fixture.graph,
            httpHeaders: [:],
            fetchOverride: { request, maximumBytes in
                try await recorder.fetch(
                    request,
                    maximumBytes: maximumBytes
                )
            }
        )
        let firstAnalysis = Task {
            try await loader.payload(
                for: .audioSegment(
                    renditionOrdinal: 0,
                    index: 0
                ),
                purpose: .analysis
            )
        }
        try await recorder.waitForRequestCount(1)
        let secondAnalysis = Task {
            try await loader.payload(
                for: .audioSegment(
                    renditionOrdinal: 0,
                    index: 1
                ),
                purpose: .analysis
            )
        }
        try await waitForAnalysisScheduler(
            active: 1,
            queued: 1,
            loader: loader
        )

        let playback = Task {
            try await loader.payload(
                for: .videoSegment(index: 1),
                purpose: .playback
            )
        }
        try await recorder.waitForRequestCount(2)
        let paused = await loader.snapshot
        XCTAssertEqual(
            paused.pausedAnalysisRequestCount,
            1
        )
        XCTAssertEqual(
            paused.analysisPreemptionCount,
            1
        )
        XCTAssertEqual(
            paused.inFlightPlaybackWaiterCount,
            1
        )
        XCTAssertEqual(
            paused.activeAnalysisFetchCount,
            0
        )
        XCTAssertEqual(
            paused.activePlaybackFetchCount,
            1
        )
        let requestsBeforeRelease =
            await recorder.requestedURLs
        XCTAssertEqual(
            requestsBeforeRelease,
            [
                firstAudioURL,
                secondVideoURL,
            ],
            "playback must not wait behind an analysis permit queue"
        )

        await recorder.release(secondVideoURL)
        _ = try await playback.value
        try await recorder.waitForRequestCount(3)
        let resumed = await loader.snapshot
        XCTAssertEqual(
            resumed.pausedAnalysisRequestCount,
            0
        )
        XCTAssertEqual(
            resumed.analysisPreemptionCount,
            1
        )
        XCTAssertEqual(
            resumed.activeAnalysisFetchCount,
            1
        )
        XCTAssertEqual(
            resumed.activePlaybackFetchCount,
            0
        )
        let requestsAfterResume =
            await recorder.requestedURLs
        XCTAssertEqual(
            requestsAfterResume,
            [
                firstAudioURL,
                secondVideoURL,
                firstAudioURL,
            ],
            "the exact paused analysis key must resume only after playback pressure clears"
        )

        await recorder.release(firstAudioURL)
        _ = try await firstAnalysis.value
        try await recorder.waitForRequestCount(4)
        _ = try await secondAnalysis.value
        let prioritizedRequests =
            await recorder.requestedURLs
        XCTAssertEqual(
            prioritizedRequests,
            [
                firstAudioURL,
                secondVideoURL,
                firstAudioURL,
                secondAudioURL,
            ]
        )
        try await loader.close()
    }

    func testCancellingQueuedAnalysisDoesNotStartItsFetch()
        async throws
    {
        let fixture = try makeFixture()
        let audioSegments =
            fixture.graph.audioRenditions[0]
                .segments
        let firstURL = audioSegments[0].url
        let secondURL = audioSegments[1].url
        let recorder = ScheduledFetchRecorder(
            responses: [
                firstURL:
                    response(
                        data:
                            fixture.audioFirstSegmentData,
                        url: firstURL
                    ),
                secondURL:
                    response(
                        data:
                            fixture.audioFirstSegmentData,
                        url: secondURL
                    ),
            ],
            blockedURLs: [firstURL]
        )
        let loader = try HLSVODOriginResourceLoader(
            graph: fixture.graph,
            httpHeaders: [:],
            fetchOverride: { request, maximumBytes in
                try await recorder.fetch(
                    request,
                    maximumBytes: maximumBytes
                )
            }
        )
        let first = Task {
            try await loader.payload(
                for: .audioSegment(
                    renditionOrdinal: 0,
                    index: 0
                ),
                purpose: .analysis
            )
        }
        try await recorder.waitForRequestCount(1)
        let queued = Task {
            try await loader.payload(
                for: .audioSegment(
                    renditionOrdinal: 0,
                    index: 1
                ),
                purpose: .analysis
            )
        }
        try await waitForAnalysisScheduler(
            active: 1,
            queued: 1,
            loader: loader
        )
        queued.cancel()
        do {
            _ = try await queued.value
            XCTFail(
                "cancelled queued analysis unexpectedly fetched"
            )
        } catch is CancellationError {
            // Expected.
        }
        try await waitForAnalysisScheduler(
            active: 1,
            queued: 0,
            loader: loader
        )
        let requestsAfterCancellation =
            await recorder.requestedURLs
        XCTAssertEqual(
            requestsAfterCancellation,
            [firstURL]
        )

        await recorder.release(firstURL)
        _ = try await first.value
        try await loader.close()
    }

    func testCancellingPausedAnalysisDoesNotRestartItsFetch()
        async throws
    {
        let fixture = try makeFixture()
        let firstAudioURL =
            fixture.graph.audioRenditions[0]
                .segments[0].url
        let secondVideoURL =
            fixture.graph.segments[1].url
        let recorder = ScheduledFetchRecorder(
            responses: [
                firstAudioURL:
                    response(
                        data:
                            fixture.audioFirstSegmentData,
                        url: firstAudioURL
                    ),
                secondVideoURL:
                    response(
                        data:
                            fixture.videoFirstSegmentData,
                        url: secondVideoURL
                    ),
            ],
            blockedURLs: [
                firstAudioURL,
                secondVideoURL,
            ]
        )
        let loader = try HLSVODOriginResourceLoader(
            graph: fixture.graph,
            httpHeaders: [:],
            fetchOverride: { request, maximumBytes in
                try await recorder.fetch(
                    request,
                    maximumBytes: maximumBytes
                )
            }
        )
        let analysis = Task {
            try await loader.payload(
                for: .audioSegment(
                    renditionOrdinal: 0,
                    index: 0
                ),
                purpose: .analysis
            )
        }
        try await recorder.waitForRequestCount(1)
        let playback = Task {
            try await loader.payload(
                for: .videoSegment(index: 1),
                purpose: .playback
            )
        }
        try await recorder.waitForRequestCount(2)
        try await waitForAnalysisScheduler(
            active: 1,
            queued: 0,
            paused: 1,
            loader: loader
        )

        analysis.cancel()
        do {
            _ = try await analysis.value
            XCTFail(
                "cancelled paused analysis unexpectedly delivered data"
            )
        } catch is CancellationError {
            // Expected.
        }
        try await waitForAnalysisScheduler(
            active: 0,
            queued: 0,
            paused: 0,
            loader: loader
        )

        await recorder.release(secondVideoURL)
        _ = try await playback.value
        try await Task.sleep(for: .milliseconds(25))
        let requestedURLs =
            await recorder.requestedURLs
        XCTAssertEqual(
            requestedURLs,
            [
                firstAudioURL,
                secondVideoURL,
            ],
            "cancelling a paused analysis waiter must remove its exact key instead of restarting it"
        )
        try await loader.close()
    }

    func testCancellingSameKeyPlaybackRestoresAnalysisPreemption()
        async throws
    {
        let fixture = try makeFixture()
        let firstAudioURL =
            fixture.graph.audioRenditions[0]
                .segments[0].url
        let secondVideoURL =
            fixture.graph.segments[1].url
        let recorder = ScheduledFetchRecorder(
            responses: [
                firstAudioURL:
                    response(
                        data:
                            fixture.audioFirstSegmentData,
                        url: firstAudioURL
                    ),
                secondVideoURL:
                    response(
                        data:
                            fixture.videoFirstSegmentData,
                        url: secondVideoURL
                    ),
            ],
            blockedURLs: [
                firstAudioURL,
                secondVideoURL,
            ]
        )
        let loader = try HLSVODOriginResourceLoader(
            graph: fixture.graph,
            httpHeaders: [:],
            fetchOverride: { request, maximumBytes in
                try await recorder.fetch(
                    request,
                    maximumBytes: maximumBytes
                )
            }
        )
        let analysis = Task {
            try await loader.payload(
                for: .audioSegment(
                    renditionOrdinal: 0,
                    index: 0
                ),
                purpose: .analysis
            )
        }
        try await recorder.waitForRequestCount(1)
        let sameKeyPlayback = Task {
            try await loader.payload(
                for: .audioSegment(
                    renditionOrdinal: 0,
                    index: 0
                ),
                purpose: .playback
            )
        }
        try await waitForFetchCounts(
            playback: 1,
            analysis: 0,
            loader: loader
        )
        let sameKeyRequests =
            await recorder.requestedURLs
        XCTAssertEqual(
            sameKeyRequests,
            [firstAudioURL],
            "same-key playback must join the existing origin fetch"
        )

        sameKeyPlayback.cancel()
        do {
            _ = try await sameKeyPlayback.value
            XCTFail(
                "cancelled same-key playback unexpectedly delivered data"
            )
        } catch is CancellationError {
            // Expected.
        }
        try await waitForFetchCounts(
            playback: 0,
            analysis: 1,
            loader: loader
        )

        let differentKeyPlayback = Task {
            try await loader.payload(
                for: .videoSegment(index: 1),
                purpose: .playback
            )
        }
        try await recorder.waitForRequestCount(2)
        try await waitForAnalysisScheduler(
            active: 1,
            queued: 0,
            paused: 1,
            loader: loader
        )
        let preempted = await loader.snapshot
        XCTAssertEqual(
            preempted.activeAnalysisFetchCount,
            0
        )
        XCTAssertEqual(
            preempted.activePlaybackFetchCount,
            1
        )
        let requestsAfterPreemption =
            await recorder.requestedURLs
        XCTAssertEqual(
            requestsAfterPreemption,
            [
                firstAudioURL,
                secondVideoURL,
            ],
            "a later different-key playback fetch must preempt the analysis flight after the same-key playback waiter leaves"
        )

        await recorder.release(secondVideoURL)
        _ = try await differentKeyPlayback.value
        try await recorder.waitForRequestCount(3)
        let requestsAfterResume =
            await recorder.requestedURLs
        XCTAssertEqual(
            requestsAfterResume,
            [
                firstAudioURL,
                secondVideoURL,
                firstAudioURL,
            ]
        )
        await recorder.release(firstAudioURL)
        _ = try await analysis.value
        try await loader.close()
    }

    func testUnboundAndOversizedResourcesFailExplicitly()
        async throws
    {
        let fixture = try makeFixture()
        let recorder = FetchRecorder(
            responses: [
                fixture.audioFirstSegmentURL:
                    HLSVODOriginFetchResponse(
                        data: Data(repeating: 0xA5, count: 5),
                        effectiveURL:
                            fixture.audioFirstSegmentURL,
                        statusCode: 200,
                        contentLength: 5,
                        contentEncoding: nil
                    ),
            ]
        )
        let loader = try HLSVODOriginResourceLoader(
            graph: fixture.graph,
            httpHeaders: [:],
            maximumResourceBytes: 4,
            capacityBytes: 4,
            fetchOverride: { request, maximumBytes in
                try await recorder.fetch(
                    request,
                    maximumBytes: maximumBytes
                )
            }
        )
        let unbound = HLSVODOriginResourceKey
            .audioSegment(
                renditionOrdinal: 99,
                index: 0
            )
        do {
            _ = try await loader.payload(for: unbound)
            XCTFail("unbound resource unexpectedly loaded")
        } catch let error as HLSVODOriginResourceError {
            XCTAssertEqual(error, .resourceNotBound(unbound))
        }
        let requestCountAfterUnbound =
            await recorder.requestCount
        XCTAssertEqual(requestCountAfterUnbound, 0)

        do {
            _ = try await loader.payload(
                for: .audioSegment(
                    renditionOrdinal: 0,
                    index: 0
                )
            )
            XCTFail("oversized resource unexpectedly loaded")
        } catch let error as HLSVODOriginResourceError {
            XCTAssertEqual(
                error,
                .resourceTooLarge(limit: 4, actual: 5)
            )
        }
        let requestCountAfterOversized =
            await recorder.requestCount
        XCTAssertEqual(requestCountAfterOversized, 1)
        try await loader.close()
    }

    func testCredentialRejectionInvalidatesTheWholePreflightGeneration()
        async throws
    {
        let fixture = try makeFixture()
        let key = HLSVODOriginResourceKey.audioSegment(
            renditionOrdinal: 0,
            index: 0
        )
        let recorder = FetchRecorder(
            responses: [
                fixture.audioFirstSegmentURL:
                    HLSVODOriginFetchResponse(
                        data: Data(),
                        effectiveURL:
                            fixture.audioFirstSegmentURL,
                        statusCode: 403,
                        contentLength: 0,
                        contentEncoding: nil
                    ),
            ]
        )
        let loader = try HLSVODOriginResourceLoader(
            graph: fixture.graph,
            httpHeaders: [
                "Authorization": "Bearer expired",
            ],
            fetchOverride: { request, maximumBytes in
                try await recorder.fetch(
                    request,
                    maximumBytes: maximumBytes
                )
            }
        )
        let directory = await loader.sessionDirectory
        _ = try await loader.payload(
            for: .videoSegment(index: 0)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.path
            )
        )

        let invalidation =
            HLSVODPreflightGenerationInvalidation
                .credentialRejected(
                    statusCode: 403,
                    resource: key
                )
        let expected = HLSVODOriginResourceError
            .preflightGenerationInvalidated(
                invalidation
            )
        do {
            _ = try await loader.payload(for: key)
            XCTFail(
                "expired credential unexpectedly kept the preflight generation usable"
            )
        } catch let error as HLSVODOriginResourceError {
            XCTAssertEqual(error, expected)
        }

        let invalidated = await loader.snapshot
        XCTAssertEqual(
            invalidated.preflightGenerationInvalidation,
            invalidation
        )
        XCTAssertEqual(invalidated.cachedResourceCount, 0)
        XCTAssertEqual(invalidated.cachedBytes, 0)
        XCTAssertEqual(invalidated.inFlightResourceCount, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.path
            )
        )

        do {
            _ = try await loader.payload(
                for: .videoSegment(index: 0)
            )
            XCTFail(
                "invalidated generation unexpectedly served seeded or cached bytes"
            )
        } catch let error as HLSVODOriginResourceError {
            XCTAssertEqual(error, expected)
        }
        let requestCount = await recorder.requestCount
        XCTAssertEqual(
            requestCount,
            1,
            "generation invalidation must not retry the expired request"
        )
        try await loader.close()
    }

    func testGenerationInvalidationMapsToPrivacySafePublicSessionError()
        throws
    {
        let key = HLSVODOriginResourceKey.audioSegment(
            renditionOrdinal: 2,
            index: 7
        )
        let invalidation =
            HLSVODPreflightGenerationInvalidation
                .credentialRejected(
                    statusCode: 403,
                    resource: key
                )
        let publicReason =
            AetherHLSPreflightInvalidationReason
                .credentialRejected(
                    statusCode: 403,
                    resource: .audioSegment(
                        renditionOrdinal: 2,
                        index: 7
                    )
                )
        XCTAssertEqual(
            invalidation.publicReason,
            publicReason
        )

        let origin = HLSVODOriginResourceError
            .preflightGenerationInvalidated(
                invalidation
            )
        let provider = HLSVODCarrierProviderError
            .pump(.origin(origin))
        XCTAssertEqual(
            HLSVODCarrierProvider
                .hybridPlaybackSessionError(
                    from: provider
                ),
            .hlsPreflightGenerationInvalidated(
                publicReason
            )
        )
        XCTAssertNil(
            HLSVODCarrierProvider
                .hybridPlaybackSessionError(
                    from:
                        HLSVODCarrierProviderError
                            .closed
                )
        )
    }

    func testGoneResourceRequiresRepreflightWithoutAutomaticRetry()
        async throws
    {
        let fixture = try makeFixture()
        let key = HLSVODOriginResourceKey.audioSegment(
            renditionOrdinal: 0,
            index: 0
        )
        let recorder = FetchRecorder(
            responses: [
                fixture.audioFirstSegmentURL:
                    HLSVODOriginFetchResponse(
                        data: Data(),
                        effectiveURL:
                            fixture.audioFirstSegmentURL,
                        statusCode: 410,
                        contentLength: 0,
                        contentEncoding: nil
                    ),
            ]
        )
        let loader = try HLSVODOriginResourceLoader(
            graph: fixture.graph,
            httpHeaders: [:],
            fetchOverride: { request, maximumBytes in
                try await recorder.fetch(
                    request,
                    maximumBytes: maximumBytes
                )
            }
        )
        let invalidation =
            HLSVODPreflightGenerationInvalidation
                .resourceUnavailable(
                    statusCode: 410,
                    resource: key
                )
        do {
            _ = try await loader.payload(for: key)
            XCTFail(
                "gone graph resource unexpectedly remained usable"
            )
        } catch let error as HLSVODOriginResourceError {
            XCTAssertEqual(
                error,
                .preflightGenerationInvalidated(
                    invalidation
                )
            )
        }
        let snapshot = await loader.snapshot
        XCTAssertEqual(
            snapshot.preflightGenerationInvalidation,
            invalidation
        )
        let requestCount = await recorder.requestCount
        XCTAssertEqual(requestCount, 1)
        try await loader.close()
    }

    func testGenerationInvalidationFailsOtherInFlightWaiters()
        async throws
    {
        let fixture = try makeFixture()
        let audioSegments =
            fixture.graph.audioRenditions[0].segments
        let blockedKey = HLSVODOriginResourceKey
            .audioSegment(
                renditionOrdinal: 0,
                index: 0
            )
        let rejectedKey = HLSVODOriginResourceKey
            .audioSegment(
                renditionOrdinal: 0,
                index: 1
            )
        let blockedURL = audioSegments[0].url
        let rejectedURL = audioSegments[1].url
        let recorder = ScheduledFetchRecorder(
            responses: [
                blockedURL:
                    response(
                        data:
                            fixture.audioFirstSegmentData,
                        url: blockedURL
                    ),
                rejectedURL:
                    HLSVODOriginFetchResponse(
                        data: Data(),
                        effectiveURL: rejectedURL,
                        statusCode: 401,
                        contentLength: 0,
                        contentEncoding: nil
                    ),
            ],
            blockedURLs: [blockedURL]
        )
        let loader = try HLSVODOriginResourceLoader(
            graph: fixture.graph,
            httpHeaders: [
                "Authorization": "Bearer expired",
            ],
            fetchOverride: { request, maximumBytes in
                try await recorder.fetch(
                    request,
                    maximumBytes: maximumBytes
                )
            }
        )
        let blocked = Task {
            try await loader.payload(for: blockedKey)
        }
        try await recorder.waitForRequestCount(1)
        let rejected = Task {
            try await loader.payload(for: rejectedKey)
        }
        try await recorder.waitForRequestCount(2)

        let expected = HLSVODOriginResourceError
            .preflightGenerationInvalidated(
                .credentialRejected(
                    statusCode: 401,
                    resource: rejectedKey
                )
            )
        for task in [blocked, rejected] {
            do {
                _ = try await task.value
                XCTFail(
                    "invalidated generation unexpectedly delivered an in-flight resource"
                )
            } catch let error as HLSVODOriginResourceError {
                XCTAssertEqual(error, expected)
            }
        }
        let snapshot = await loader.snapshot
        XCTAssertEqual(snapshot.inFlightResourceCount, 0)
        XCTAssertEqual(snapshot.inFlightWaiterCount, 0)
        XCTAssertEqual(
            snapshot.preflightGenerationInvalidation,
            .credentialRejected(
                statusCode: 401,
                resource: rejectedKey
            )
        )
        try await loader.close()
    }

    func testAnalysisCredentialFailureDoesNotInvalidatePlayback()
        async throws
    {
        let fixture = try makeFixture()
        let key = HLSVODOriginResourceKey.audioSegment(
            renditionOrdinal: 0,
            index: 0
        )
        let recorder = FetchRecorder(
            responses: [
                fixture.audioFirstSegmentURL:
                    HLSVODOriginFetchResponse(
                        data: Data(),
                        effectiveURL:
                            fixture.audioFirstSegmentURL,
                        statusCode: 403,
                        contentLength: 0,
                        contentEncoding: nil
                    ),
            ]
        )
        let loader = try HLSVODOriginResourceLoader(
            graph: fixture.graph,
            httpHeaders: [
                "Authorization": "Bearer expired",
            ],
            fetchOverride: { request, maximumBytes in
                try await recorder.fetch(
                    request,
                    maximumBytes: maximumBytes
                )
            }
        )

        do {
            _ = try await loader.payload(
                for: key,
                purpose: .analysis
            )
            XCTFail(
                "expired analysis credential unexpectedly produced bytes"
            )
        } catch let error as HLSVODOriginResourceError {
            XCTAssertEqual(error, .httpStatus(403))
        }
        let afterAnalysis = await loader.snapshot
        XCTAssertNil(
            afterAnalysis.preflightGenerationInvalidation
        )
        XCTAssertFalse(afterAnalysis.isClosed)

        let playback = try await loader.payload(
            for: .videoSegment(index: 0),
            purpose: .playback
        )
        XCTAssertEqual(
            playback.data,
            fixture.videoFirstSegmentData
        )
        let requestCount = await recorder.requestCount
        XCTAssertEqual(requestCount, 1)
        try await loader.close()
    }

    func testServerFailureUsesBoundedTransportRetriesWithoutInvalidatingGraph()
        async throws
    {
        let fixture = try makeFixture()
        let key = HLSVODOriginResourceKey.audioSegment(
            renditionOrdinal: 0,
            index: 0
        )
        let recorder = FetchRecorder(
            responses: [
                fixture.audioFirstSegmentURL:
                    HLSVODOriginFetchResponse(
                        data: Data(),
                        effectiveURL:
                            fixture.audioFirstSegmentURL,
                        statusCode: 503,
                        contentLength: 0,
                        contentEncoding: nil
                    ),
            ]
        )
        let loader = try HLSVODOriginResourceLoader(
            graph: fixture.graph,
            httpHeaders: [:],
            fetchOverride: { request, maximumBytes in
                try await recorder.fetch(
                    request,
                    maximumBytes: maximumBytes
                )
            }
        )

        do {
            _ = try await loader.payload(for: key)
            XCTFail("HTTP 503 unexpectedly produced bytes")
        } catch let error as HLSVODOriginResourceError {
            XCTAssertEqual(error, .httpStatus(503))
        }
        let firstSnapshot = await loader.snapshot
        XCTAssertNil(
            firstSnapshot.preflightGenerationInvalidation
        )
        let firstRequestCount = await recorder.requestCount
        XCTAssertEqual(
            firstRequestCount,
            3,
            "one transport operation may make at most three attempts"
        )

        do {
            _ = try await loader.payload(for: key)
            XCTFail("explicit second request unexpectedly produced bytes")
        } catch let error as HLSVODOriginResourceError {
            XCTAssertEqual(error, .transportBudgetExhausted)
        }
        let secondRequestCount = await recorder.requestCount
        XCTAssertEqual(
            secondRequestCount,
            3,
            "the recovery episode owns one shared transport budget"
        )
        try await loader.close()
    }

    func testRuntimeEffectiveOriginMustRemainInsidePreflightScope()
        async throws
    {
        let fixture = try makeFixture()
        let key = HLSVODOriginResourceKey.audioSegment(
            renditionOrdinal: 0,
            index: 0
        )
        let recorder = FetchRecorder(
            responses: [
                fixture.audioFirstSegmentURL:
                    HLSVODOriginFetchResponse(
                        data: fixture.audioFirstSegmentData,
                        effectiveURL: URL(
                            string:
                                "https://unadmitted.example/audio/a0.aac"
                        )!,
                        statusCode: 200,
                        contentLength: Int64(
                            fixture.audioFirstSegmentData.count
                        ),
                        contentEncoding: nil
                    ),
            ]
        )
        let loader = try HLSVODOriginResourceLoader(
            graph: fixture.graph,
            httpHeaders: [:],
            fetchOverride: { request, maximumBytes in
                try await recorder.fetch(
                    request,
                    maximumBytes: maximumBytes
                )
            }
        )

        do {
            _ = try await loader.payload(for: key)
            XCTFail(
                "unadmitted redirect origin unexpectedly entered the graph cache"
            )
        } catch let error as HLSVODOriginResourceError {
            XCTAssertEqual(
                error,
                .preflightGenerationInvalidated(
                    .effectiveOriginChanged(
                        resource: key
                    )
                )
            )
        }
        let snapshot = await loader.snapshot
        XCTAssertEqual(snapshot.cachedResourceCount, 0)
        XCTAssertEqual(snapshot.cachedBytes, 0)
        XCTAssertEqual(
            snapshot.preflightGenerationInvalidation,
            .effectiveOriginChanged(
                resource: key
            )
        )
        try await loader.close()
    }

    func testRuntimeRedirectMayUseThePreflightAdmittedVideoOrigin()
        async throws
    {
        let fixture = try makeFixture()
        let key = HLSVODOriginResourceKey.videoSegment(
            index: 1
        )
        let requestURL =
            fixture.graph.segments[1].url
        let responseURL =
            fixture.videoFirstSegmentEffectiveURL
                .deletingLastPathComponent()
                .appendingPathComponent("v1.m4s")
        let bytes = Data([
            0x00, 0x00, 0x00, 0x08,
            0x6D, 0x64, 0x61, 0x74,
        ])
        let recorder = FetchRecorder(
            responses: [
                requestURL:
                    HLSVODOriginFetchResponse(
                        data: bytes,
                        effectiveURL: responseURL,
                        statusCode: 200,
                        contentLength: Int64(bytes.count),
                        contentEncoding: nil
                    ),
            ]
        )
        let loader = try HLSVODOriginResourceLoader(
            graph: fixture.graph,
            httpHeaders: [:],
            fetchOverride: { request, maximumBytes in
                try await recorder.fetch(
                    request,
                    maximumBytes: maximumBytes
                )
            }
        )

        let payload = try await loader.payload(
            for: key
        )
        XCTAssertEqual(payload.effectiveURL, responseURL)
        XCTAssertEqual(payload.data, bytes)
        try await loader.close()
    }

    func testCloseFailsActiveAndQueuedAnalysisRequests()
        async throws
    {
        let fixture = try makeFixture()
        let audioSegments =
            fixture.graph.audioRenditions[0]
                .segments
        let firstURL = audioSegments[0].url
        let secondURL = audioSegments[1].url
        let recorder = ScheduledFetchRecorder(
            responses: [
                firstURL:
                    response(
                        data:
                            fixture.audioFirstSegmentData,
                        url: firstURL
                    ),
                secondURL:
                    response(
                        data:
                            fixture.audioFirstSegmentData,
                        url: secondURL
                    ),
            ],
            blockedURLs: [firstURL]
        )
        let loader = try HLSVODOriginResourceLoader(
            graph: fixture.graph,
            httpHeaders: [:],
            fetchOverride: { request, maximumBytes in
                try await recorder.fetch(
                    request,
                    maximumBytes: maximumBytes
                )
            }
        )
        let active = Task {
            try await loader.payload(
                for: .audioSegment(
                    renditionOrdinal: 0,
                    index: 0
                ),
                purpose: .analysis
            )
        }
        try await recorder.waitForRequestCount(1)
        let queued = Task {
            try await loader.payload(
                for: .audioSegment(
                    renditionOrdinal: 0,
                    index: 1
                ),
                purpose: .analysis
            )
        }
        try await waitForAnalysisScheduler(
            active: 1,
            queued: 1,
            loader: loader
        )

        try await loader.close()
        for task in [active, queued] {
            do {
                _ = try await task.value
                XCTFail(
                    "closed scheduler unexpectedly delivered analysis data"
                )
            } catch let error
                    as HLSVODOriginResourceError {
                XCTAssertEqual(error, .closed)
            }
        }
        let snapshot = await loader.snapshot
        XCTAssertTrue(snapshot.isClosed)
        XCTAssertEqual(
            snapshot.activeAnalysisRequestCount,
            0
        )
        XCTAssertEqual(
            snapshot.queuedAnalysisRequestCount,
            0
        )
    }

    func testCloseFailsPendingWaiterAndRemovesSessionCache()
        async throws
    {
        let fixture = try makeFixture()
        let recorder = FetchRecorder(
            responses: [
                fixture.audioFirstSegmentURL:
                    HLSVODOriginFetchResponse(
                        data: fixture.audioFirstSegmentData,
                        effectiveURL:
                            fixture.audioFirstSegmentURL,
                        statusCode: 200,
                        contentLength:
                            Int64(
                                fixture.audioFirstSegmentData
                                    .count
                            ),
                        contentEncoding: nil
                    ),
            ],
            delayNanoseconds: 5_000_000_000
        )
        let loader = try HLSVODOriginResourceLoader(
            graph: fixture.graph,
            httpHeaders: [:],
            fetchOverride: { request, maximumBytes in
                try await recorder.fetch(
                    request,
                    maximumBytes: maximumBytes
                )
            }
        )
        let directory = await loader.sessionDirectory
        let pending = Task {
            try await loader.payload(
                for: .audioSegment(
                    renditionOrdinal: 0,
                    index: 0
                )
            )
        }
        try await waitForWaiters(1, loader: loader)

        try await loader.close()
        do {
            _ = try await pending.value
            XCTFail("closed loader unexpectedly delivered data")
        } catch let error as HLSVODOriginResourceError {
            XCTAssertEqual(error, .closed)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.path
            )
        )
    }

    func testBoundedHTTPTransportRejectsDeclaredOversize()
        async throws
    {
        let url = URL(
            string: "https://origin.test/oversized.m4s"
        )!
        HLSVODOriginURLProtocol.reset()
        HLSVODOriginURLProtocol.fixtures[
            url.absoluteString
        ] = .init(
            statusCode: 200,
            headers: ["Content-Length": "5"],
            body: Data(repeating: 0xAB, count: 5)
        )
        let configuration =
            URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            HLSVODOriginURLProtocol.self,
        ]
        var request = URLRequest(url: url)
        request.setValue(
            "Bearer secret",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            "identity",
            forHTTPHeaderField: "Accept-Encoding"
        )

        do {
            _ = try await HLSVODBoundedHTTPFetcher.fetch(
                request: request,
                maximumBytes: 4,
                configuration: configuration
            )
            XCTFail("declared oversized response unexpectedly loaded")
        } catch let error as HLSVODOriginResourceError {
            XCTAssertEqual(
                error,
                .resourceTooLarge(limit: 4, actual: 5)
            )
        }
        let recorded = HLSVODOriginURLProtocol
            .recordedHeaders(for: url)
        XCTAssertEqual(
            recorded?["Authorization"],
            "Bearer secret"
        )
        XCTAssertEqual(
            recorded?["Accept-Encoding"],
            "identity"
        )
    }

    func testBoundedHTTPTransportReturnsRetryAfterEvidenceFor429()
        async throws
    {
        let url = URL(
            string: "https://origin.test/rate-limited.m4s"
        )!
        HLSVODOriginURLProtocol.reset()
        HLSVODOriginURLProtocol.fixtures[
            url.absoluteString
        ] = .init(
            statusCode: 429,
            headers: ["Retry-After": "4"],
            body: Data()
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            HLSVODOriginURLProtocol.self,
        ]

        let response = try await HLSVODBoundedHTTPFetcher.fetch(
            request: URLRequest(url: url),
            maximumBytes: 4,
            configuration: configuration
        )

        XCTAssertEqual(response.statusCode, 429)
        XCTAssertEqual(response.retryAfterSeconds, 4)
        XCTAssertTrue(response.data.isEmpty)
    }

    func testBoundedHTTPTransportRejectsCredentialedCrossOriginRedirect()
        async throws
    {
        let sourceURL = URL(
            string: "https://origin.test/redirect.m4s"
        )!
        let targetURL = URL(
            string: "https://cdn.test/segment.m4s"
        )!
        HLSVODOriginURLProtocol.reset()
        HLSVODOriginURLProtocol.fixtures[
            sourceURL.absoluteString
        ] = .init(
            statusCode: 302,
            headers: [
                "Location": targetURL.absoluteString,
            ],
            body: Data(),
            redirectURL: targetURL
        )
        HLSVODOriginURLProtocol.fixtures[
            targetURL.absoluteString
        ] = .init(
            statusCode: 200,
            headers: ["Content-Length": "1"],
            body: Data([0xAB])
        )
        let configuration =
            URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            HLSVODOriginURLProtocol.self,
        ]
        var request = URLRequest(url: sourceURL)
        request.setValue(
            "Bearer secret",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            "identity",
            forHTTPHeaderField: "Accept-Encoding"
        )

        do {
            _ = try await HLSVODBoundedHTTPFetcher.fetch(
                request: request,
                maximumBytes: 4,
                configuration: configuration
            )
            XCTFail(
                "credentialed cross-origin redirect unexpectedly followed"
            )
        } catch let error as HLSVODOriginResourceError {
            XCTAssertEqual(
                error,
                .redirectCredentialScopeViolation
            )
        }
        XCTAssertNil(
            HLSVODOriginURLProtocol.recordedHeaders(
                for: targetURL
            )
        )
    }

    func testBoundedHTTPTransportKeepsOnlySafeCrossOriginHeaders()
        async throws
    {
        let sourceURL = URL(
            string: "https://origin.test/redirect-safe.m4s"
        )!
        let targetURL = URL(
            string: "https://cdn.test/segment-safe.m4s"
        )!
        HLSVODOriginURLProtocol.reset()
        HLSVODOriginURLProtocol.fixtures[
            sourceURL.absoluteString
        ] = .init(
            statusCode: 302,
            headers: [
                "Location": targetURL.absoluteString,
            ],
            body: Data(),
            redirectURL: targetURL
        )
        HLSVODOriginURLProtocol.fixtures[
            targetURL.absoluteString
        ] = .init(
            statusCode: 200,
            headers: ["Content-Length": "1"],
            body: Data([0xAB])
        )
        let configuration =
            URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            HLSVODOriginURLProtocol.self,
        ]
        var request = URLRequest(url: sourceURL)
        request.setValue(
            "bytes=0-15",
            forHTTPHeaderField: "Range"
        )
        request.setValue(
            "AetherTests/1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(
            "https://catalog.example/title/1",
            forHTTPHeaderField: "Referer"
        )
        request.setValue(
            "identity",
            forHTTPHeaderField: "Accept-Encoding"
        )

        let response =
            try await HLSVODBoundedHTTPFetcher.fetch(
                request: request,
                maximumBytes: 4,
                configuration: configuration
            )

        XCTAssertEqual(response.effectiveURL, targetURL)
        XCTAssertEqual(response.data, Data([0xAB]))
        let recorded = try XCTUnwrap(
            HLSVODOriginURLProtocol.recordedHeaders(
                for: targetURL
            )
        )
        XCTAssertEqual(recorded["Range"], "bytes=0-15")
        XCTAssertEqual(
            recorded["User-Agent"],
            "AetherTests/1"
        )
        XCTAssertEqual(
            recorded["Accept-Encoding"],
            "identity"
        )
        XCTAssertNil(recorded["Authorization"])
        XCTAssertNil(recorded["Cookie"])
        XCTAssertEqual(
            recorded["Referer"],
            "https://catalog.example/title/1"
        )
    }

    func testBoundedHTTPTransportKeepsHeadersOnSameOriginRedirect()
        async throws
    {
        let sourceURL = URL(
            string:
                "https://origin.test/redirect-same-origin.m4s"
        )!
        let targetURL = URL(
            string: "https://origin.test/segment.m4s"
        )!
        let bytes = Data([0xAB])
        HLSVODOriginURLProtocol.reset()
        HLSVODOriginURLProtocol.fixtures[
            sourceURL.absoluteString
        ] = .init(
            statusCode: 302,
            headers: [
                "Location": targetURL.absoluteString,
            ],
            body: Data(),
            redirectURL: targetURL
        )
        HLSVODOriginURLProtocol.fixtures[
            targetURL.absoluteString
        ] = .init(
            statusCode: 200,
            headers: ["Content-Length": "1"],
            body: bytes
        )
        let configuration =
            URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            HLSVODOriginURLProtocol.self,
        ]
        var request = URLRequest(url: sourceURL)
        request.setValue(
            "Bearer secret",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            "identity",
            forHTTPHeaderField: "Accept-Encoding"
        )

        let response =
            try await HLSVODBoundedHTTPFetcher.fetch(
                request: request,
                maximumBytes: 4,
                configuration: configuration
            )
        XCTAssertEqual(response.data, bytes)
        XCTAssertEqual(response.effectiveURL, targetURL)
        let targetHeaders =
            HLSVODOriginURLProtocol.recordedHeaders(
                for: targetURL
            )
        XCTAssertEqual(
            targetHeaders?["Authorization"],
            "Bearer secret"
        )
        XCTAssertEqual(
            targetHeaders?["Accept-Encoding"],
            "identity"
        )
    }

    private func waitForWaiters(
        _ expected: Int,
        loader: HLSVODOriginResourceLoader
    ) async throws {
        for _ in 0..<200 {
            if await loader.snapshot.inFlightWaiterCount
                == expected {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("timed out waiting for \(expected) loader waiters")
    }

    private func waitForAnalysisScheduler(
        active: Int,
        queued: Int,
        paused: Int? = nil,
        loader: HLSVODOriginResourceLoader
    ) async throws {
        for _ in 0..<400 {
            let snapshot = await loader.snapshot
            if snapshot.activeAnalysisRequestCount
                    == active,
               snapshot.queuedAnalysisRequestCount
                    == queued,
               paused == nil
                    || snapshot.pausedAnalysisRequestCount
                        == paused {
                return
            }
            try await Task.sleep(
                for: .milliseconds(5)
            )
        }
        XCTFail(
            "timed out waiting for analysis scheduler active=\(active) queued=\(queued) paused=\(String(describing: paused))"
        )
    }

    private func waitForFetchCounts(
        playback: Int,
        analysis: Int,
        loader: HLSVODOriginResourceLoader
    ) async throws {
        for _ in 0..<400 {
            let snapshot = await loader.snapshot
            if snapshot.activePlaybackFetchCount
                    == playback,
               snapshot.activeAnalysisFetchCount
                    == analysis {
                return
            }
            try await Task.sleep(
                for: .milliseconds(5)
            )
        }
        XCTFail(
            "timed out waiting for fetch counts playback=\(playback) analysis=\(analysis)"
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

    private func makeFixture() throws -> Fixture {
        let playlistURL = URL(
            string: "https://cdn.example/video/main.m3u8"
        )!
        let videoInitURL = URL(
            string: "https://cdn.example/video/init.mp4"
        )!
        let videoFirstSegmentURL = URL(
            string: "https://cdn.example/video/v0.m4s"
        )!
        let videoFirstSegmentEffectiveURL = URL(
            string:
                "https://media-cdn.example/video/v0.m4s"
        )!
        let audioPlaylistURL = URL(
            string: "https://cdn.example/audio/en.m3u8"
        )!
        let audioFirstSegmentURL = URL(
            string: "https://cdn.example/audio/a0.aac"
        )!
        let videoInitData = Data([0x00, 0x00, 0x00, 0x18])
        let videoFirstSegmentData = Data([
            0x00, 0x00, 0x00, 0x08, 0x6D, 0x6F, 0x6F, 0x66,
        ])
        let audioFirstSegmentData = Data([
            0xFF, 0xF1, 0x50, 0x80, 0x00, 0x1F, 0xFC,
        ])
        let videoMedia = HLSMediaPlaylist(
            targetDuration: 4,
            mediaSequence: 17,
            segments: [
                HLSMediaSegment(
                    uri: videoFirstSegmentURL.lastPathComponent,
                    duration: 4,
                    discontinuityBefore: false
                ),
                HLSMediaSegment(
                    uri: "v1.m4s",
                    duration: 2,
                    discontinuityBefore: false
                ),
            ],
            hasEndList: true,
            hasUnsupportedEncryption: false,
            hasMap: true,
            mapURI: videoInitURL.lastPathComponent,
            contentProtection: .none
        )
        let audioMedia = HLSMediaPlaylist(
            targetDuration: 4,
            mediaSequence: 31,
            segments: [
                HLSMediaSegment(
                    uri: audioFirstSegmentURL.lastPathComponent,
                    duration: 4,
                    discontinuityBefore: false
                ),
                HLSMediaSegment(
                    uri: "a1.aac",
                    duration: 2,
                    discontinuityBefore: false
                ),
            ],
            hasEndList: true,
            hasUnsupportedEncryption: false,
            hasMap: false,
            mapURI: nil,
            contentProtection: .none
        )
        let audioResource =
            try HLSVODResourceGraph.makeAudioRendition(
                ordinal: 0,
                metadata: HLSAudioRendition(
                    groupID: "audio",
                    uri: audioPlaylistURL.lastPathComponent,
                    name: "English",
                    language: "en",
                    isDefault: true,
                    isAutoselect: true,
                    channels: "2"
                ),
                playlistURL: audioPlaylistURL,
                playlistData: Data("#EXTM3U".utf8),
                media: audioMedia
            )
        let graph = try HLSVODResourceGraph.make(
            requestedRootURL: URL(
                string: "https://origin.example/master.m3u8"
            )!,
            effectiveRootURL: URL(
                string: "https://cdn.example/master.m3u8"
            )!,
            selectedMediaPlaylistURL: playlistURL,
            selectedVariant: HLSVariant(
                bandwidth: 1_400_000,
                uri: "video/main.m3u8",
                audioGroupID: "audio",
                codecs: ["hev1.2.4.l150"]
            ),
            separateAudioGroupID: "audio",
            mediaPlaylistData: Data("#EXTM3U".utf8),
            media: videoMedia,
            audioRenditions: [audioResource],
            inspectedInitSegmentData: videoInitData,
            inspectedInitSegmentEffectiveURL:
                videoInitURL,
            inspectedFirstMediaSegmentData:
                videoFirstSegmentData,
            inspectedFirstMediaSegmentEffectiveURL:
                videoFirstSegmentEffectiveURL,
            httpHeaders: [:]
        )
        XCTAssertEqual(
            graph.initSegmentURL,
            videoInitURL
        )
        XCTAssertEqual(
            graph.segments.first?.url,
            videoFirstSegmentURL
        )
        XCTAssertEqual(
            graph.audioRenditions.first?.segments.first?.url,
            audioFirstSegmentURL
        )
        return Fixture(
            graph: graph,
            videoInitData: videoInitData,
            videoFirstSegmentData: videoFirstSegmentData,
            videoFirstSegmentEffectiveURL:
                videoFirstSegmentEffectiveURL,
            audioFirstSegmentData: audioFirstSegmentData,
            audioFirstSegmentURL: audioFirstSegmentURL
        )
    }
}

private final class HLSVODOriginURLProtocol:
    URLProtocol,
    @unchecked Sendable
{
    struct Fixture {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
        let redirectURL: URL?

        init(
            statusCode: Int,
            headers: [String: String],
            body: Data,
            redirectURL: URL? = nil
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
            self.redirectURL = redirectURL
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) static var fixtures:
        [String: Fixture] = [:]
    nonisolated(unsafe) private static var headersByURL:
        [String: [String: String]] = [:]

    static func reset() {
        lock.withLock {
            fixtures = [:]
            headersByURL = [:]
        }
    }

    static func recordedHeaders(
        for url: URL
    ) -> [String: String]? {
        lock.withLock {
            headersByURL[url.absoluteString]
        }
    }

    override class func canInit(
        with request: URLRequest
    ) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badURL)
            )
            return
        }
        let fixture: Fixture? = Self.lock.withLock {
            Self.headersByURL[url.absoluteString] =
                request.allHTTPHeaderFields ?? [:]
            return Self.fixtures[url.absoluteString]
        }
        guard let fixture else {
            client?.urlProtocol(
                self,
                didFailWithError:
                    URLError(.fileDoesNotExist)
            )
            return
        }
        if let redirectURL = fixture.redirectURL {
            let response = HTTPURLResponse(
                url: url,
                statusCode: fixture.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: fixture.headers
            )!
            client?.urlProtocol(
                self,
                wasRedirectedTo:
                    URLRequest(url: redirectURL),
                redirectResponse: response
            )
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: fixture.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: fixture.headers
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: fixture.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
