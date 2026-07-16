import CoreMedia
import Foundation
import XCTest
@testable import AetherEngine

final class HLSVODOriginResourceLoaderTests: XCTestCase {
    private struct Fixture {
        let graph: HLSVODResourceGraph
        let videoInitData: Data
        let videoFirstSegmentData: Data
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
            inspectedFirstMediaSegmentData:
                videoFirstSegmentData,
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
