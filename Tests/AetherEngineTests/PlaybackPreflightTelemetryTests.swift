import Foundation
import Testing
@testable import AetherEngine

@Suite("Playback preflight telemetry")
struct PlaybackPreflightTelemetryTests {
    @Test("Native, hybrid and unsupported policy decisions are terminal observable results")
    func policyDecisionCoverage() async throws {
        let cases: [(
            codec: AetherVideoCodec,
            expectedRoute: PlaybackRenderRoute,
            expectedReason: PlaybackRouteReason
        )] = [
            (.h264, .nativeAVPlayer, .nativeHLSFMP4Remux),
            (.vp9, .hybridCarrier, .hybridNonAVPlayerCodec),
            (.unknown, .unsupported, .unsupportedVideoCodec),
        ]

        for (index, item) in cases.enumerated() {
            let operationID = UUID(
                uuidString: String(
                    format:
                        "00000000-0000-0000-0000-%012d",
                    index + 1
                )
            )!
            let operation = AetherPlaybackPreflightOperation(
                operationID: operationID
            )
            let stream = await operation.telemetryEvents()
            let result = try await operation.resolve(
                sourceProfile: AetherSourceProfile(
                    sourceKind: .progressive,
                    isSeekableVOD: true,
                    videoCodec: item.codec,
                    sourceContainer: item.codec == .h264
                        ? .matroska
                        : .unknown,
                    videoFormat: .sdr
                ),
                hlsPackaging: nil,
                hybridCapabilities: capabilities
            )
            let events = await collect(stream)

            #expect(result.route == item.expectedRoute)
            #expect(result.reason == item.expectedReason)
            #expect(events.map(\.sequence) == [1, 2])
            #expect(events.map(\.kind) == [.started, .completed])
            #expect(
                events.allSatisfy {
                    $0.operationID == operationID
                }
            )
            guard case .completed(let completed) =
                    events.last?.snapshot else {
                Issue.record("Missing terminal completed event")
                continue
            }
            #expect(completed.route == item.expectedRoute)
            #expect(completed.reason == item.expectedReason)
            #expect(completed.hlsEvidence == nil)
        }
    }

    @Test("Successful HLS inspection exposes typed evidence without URL or credentials")
    func successfulHLSInspectionIsPrivacySafe() async throws {
        let rootURL = URL(
            string:
                "https://signed.example/master.m3u8?token=secret-token"
        )!
        let mediaURL = URL(
            string:
                "https://signed.example/video.m3u8?token=secret-token"
        )!
        let responses: [URL: HLSPreflightFetchResponse] = [
            rootURL: HLSPreflightFetchResponse(
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-STREAM-INF:BANDWIDTH=4000000,CODECS="hvc1.2.4.L150",VIDEO-RANGE=PQ
                    video.m3u8?token=secret-token
                    """.utf8
                ),
                effectiveURL: rootURL
            ),
            mediaURL: HLSPreflightFetchResponse(
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-TARGETDURATION:4
                    #EXT-X-KEY:METHOD=SAMPLE-AES,KEYFORMAT="com.apple.streamingkeydelivery",URI="skd://secret-license"
                    #EXT-X-MAP:URI="init.mp4?token=secret-token"
                    #EXTINF:4,
                    seg0.m4s?token=secret-token
                    #EXT-X-ENDLIST
                    """.utf8
                ),
                effectiveURL: mediaURL
            ),
        ]
        let operation = AetherPlaybackPreflightOperation(
            operationID: UUID(
                uuidString:
                    "11111111-2222-3333-4444-555555555555"
            )!
        )
        let stream = await operation.telemetryEvents()
        let preflight = try await operation.inspectHLS(
            rootURL: rootURL,
            sourceIsSeekableVOD: true,
            variantSelection: .highestBandwidth,
            hybridCapabilities: capabilities,
            inspector: HLSPreflightInspector(
                httpHeaders: [
                    "Authorization": "Bearer secret-credential"
                ],
                fetchOverride: { url, _ in
                    guard let response = responses[url] else {
                        throw HLSPreflightError.httpStatus(599)
                    }
                    return response
                }
            )
        )
        let events = await collect(stream)

        #expect(preflight.result.route == .nativeAVPlayer)
        #expect(events.map(\.kind) == [.started, .completed])
        let description = String(describing: events)
        #expect(!description.contains("secret-token"))
        #expect(!description.contains("secret-credential"))
        #expect(!description.contains("signed.example"))
        #expect(!description.contains("secret-license"))
        guard case .completed(let completed) =
                events.last?.snapshot else {
            Issue.record("Missing HLS completed event")
            return
        }
        #expect(completed.route == .nativeAVPlayer)
        #expect(
            completed.reason
                == .nativeProtectedHLSContractVerified
        )
        #expect(
            completed.hlsPackaging?.contentProtection
                == .fairPlay
        )
        #expect(
            completed.hlsPackaging?.codecVerification
                == .protectedManifestVerified
        )
        #expect(
            completed.hlsEvidence
                == AetherPlaybackPreflightTelemetryHLSEvidence(
                    preflight
                )
        )
        #expect(
            completed.hlsEvidence?.hasRetainedResourceGraph
                == false
        )
    }

    @Test("HLS failure preserves the thrown cause while telemetry removes arbitrary URI text")
    func hlsFailurePreservesCauseAndSanitizesEvent() async throws {
        let secretVariant =
            "https://signed.example/video.m3u8?token=secret"
        let original = HLSPreflightError
            .requestedVariantNotFound(secretVariant)
        let operation = AetherPlaybackPreflightOperation(
            operationID: UUID(
                uuidString:
                    "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            )!
        )
        let stream = await operation.telemetryEvents()

        do {
            _ = try await operation.inspectHLS(
                rootURL: URL(
                    string:
                        "https://signed.example/master.m3u8?token=secret"
                )!,
                sourceIsSeekableVOD: true,
                variantSelection: .exactURI(secretVariant),
                hybridCapabilities: capabilities,
                inspector: HLSPreflightInspector(
                    httpHeaders: [
                        "Cookie": "session=secret"
                    ],
                    fetchOverride: { _, _ in
                        throw original
                    }
                )
            )
            Issue.record("Expected the original HLS failure")
        } catch let error as HLSPreflightError {
            #expect(error == original)
        }
        let events = await collect(stream)

        #expect(events.map(\.kind) == [.started, .failed])
        #expect(!String(describing: events).contains("secret"))
        guard case .started(let request) =
                events.first?.snapshot else {
            Issue.record("Missing HLS started event")
            return
        }
        #expect(
            request.kind
                == .hlsInspection(.exactVariant)
        )
        guard case .failed(let failure) =
                events.last?.snapshot else {
            Issue.record("Missing HLS failed event")
            return
        }
        #expect(
            failure.reason
                == .hlsRequestedVariantNotFound
        )
    }

    @Test("Invalid-playlist telemetry stays stable while the thrown parser reason is preserved")
    func invalidPlaylistReasonIsNotCopiedIntoTelemetry() async throws {
        let parserReason =
            "missing TARGETDURATION private-parser-context"
        let original = HLSPreflightError
            .invalidPlaylist(parserReason)
        let operation = AetherPlaybackPreflightOperation()
        let stream = await operation.telemetryEvents()

        do {
            _ = try await operation.inspectHLS(
                rootURL: URL(
                    string: "https://example.com/invalid.m3u8"
                )!,
                sourceIsSeekableVOD: true,
                variantSelection: .highestBandwidth,
                hybridCapabilities: capabilities,
                inspector: HLSPreflightInspector(
                    httpHeaders: [:],
                    fetchOverride: { _, _ in
                        throw original
                    }
                )
            )
            Issue.record("Expected invalid playlist")
        } catch let error as HLSPreflightError {
            #expect(error == original)
        }

        let events = await collect(stream)
        #expect(events.map(\.kind) == [.started, .failed])
        #expect(!String(describing: events).contains(parserReason))
        guard case .failed(let failure) =
                events.last?.snapshot else {
            Issue.record("Missing HLS failed event")
            return
        }
        #expect(failure.reason == .hlsInvalidPlaylist)
    }

    @Test("A preflight operation cannot be reused or silently restarted")
    func oneShotOperationRejectsReuse() async throws {
        let operation = AetherPlaybackPreflightOperation()
        let stream = await operation.telemetryEvents()
        _ = try await operation.resolve(
            sourceProfile: AetherSourceProfile(
                sourceKind: .progressive,
                isSeekableVOD: true,
                videoCodec: .h264,
                videoFormat: .sdr
            ),
            hlsPackaging: nil,
            hybridCapabilities: capabilities
        )

        do {
            _ = try await operation.resolve(
                sourceProfile: AetherSourceProfile(
                    sourceKind: .progressive,
                    isSeekableVOD: true,
                    videoCodec: .vp9,
                    videoFormat: .sdr
                ),
                hlsPackaging: nil,
                hybridCapabilities: capabilities
            )
            Issue.record("Expected one-shot reuse failure")
        } catch let error as
                AetherPlaybackPreflightOperationError {
            #expect(error == .alreadyStarted)
        }
        let events = await collect(stream)
        #expect(events.map(\.kind) == [.started, .completed])
    }

    @Test("Late subscribers replay the terminal lifecycle and finish")
    func lateSubscriberReplay() async throws {
        let operation = AetherPlaybackPreflightOperation()
        _ = try await operation.resolve(
            sourceProfile: AetherSourceProfile(
                sourceKind: .progressive,
                isSeekableVOD: true,
                videoCodec: .h264,
                videoFormat: .sdr
            ),
            hlsPackaging: nil,
            hybridCapabilities: capabilities
        )

        let events = await collect(
            await operation.telemetryEvents()
        )
        #expect(events.map(\.sequence) == [1, 2])
        #expect(events.map(\.kind) == [.started, .completed])
    }

    @Test("Cancellation remains cancellation and is not reported as transport fallback")
    func cancellationRemainsTyped() async throws {
        let operation = AetherPlaybackPreflightOperation()
        let stream = await operation.telemetryEvents()

        do {
            _ = try await operation.inspectHLS(
                rootURL: URL(
                    string: "https://example.com/master.m3u8"
                )!,
                sourceIsSeekableVOD: true,
                variantSelection: .highestBandwidth,
                hybridCapabilities: capabilities,
                inspector: HLSPreflightInspector(
                    httpHeaders: [:],
                    fetchOverride: { _, _ in
                        throw CancellationError()
                    }
                )
            )
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // The original cancellation identity is required.
        }
        let events = await collect(stream)

        #expect(events.map(\.kind) == [.started, .failed])
        guard case .failed(let failure) =
                events.last?.snapshot else {
            Issue.record("Missing cancelled terminal event")
            return
        }
        #expect(failure.reason == .cancelled)
    }

    private var capabilities: HybridPlaybackCapabilities {
        HybridPlaybackCapabilities(
            hasDirectVideoDecoder: true,
            hasSampleBufferRenderer: true,
            supportedVideoFormats: [.sdr],
            supportedSourceKinds: [
                .hls,
                .progressive,
                .custom,
            ]
        )
    }

    private func collect(
        _ stream:
            AsyncStream<AetherPlaybackPreflightTelemetryEvent>
    ) async -> [AetherPlaybackPreflightTelemetryEvent] {
        var events:
            [AetherPlaybackPreflightTelemetryEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }
}
