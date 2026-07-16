import XCTest
import CoreMedia
import Foundation
@testable import AetherEngine

final class HLSPreflightInspectorTests: XCTestCase {
    func testHVC1RequiresMatchingManifestToken() {
        XCTAssertEqual(
            HLSPreflightInspector.codecVerification(
                manifestCodecs: ["hvc1.2.4.l150", "ec-3"],
                actualCodec: .hevc,
                sampleEntry: .hvc1
            ),
            .verified
        )
    }

    func testHEVCManifestMismatchIsNotConsideredVerified() {
        XCTAssertEqual(
            HLSPreflightInspector.codecVerification(
                manifestCodecs: ["avc1.640028"],
                actualCodec: .hevc,
                sampleEntry: .hvc1
            ),
            .mismatch
        )
    }

    func testMissingManifestCodecRequiresHybridEvidencePath() {
        XCTAssertEqual(
            HLSPreflightInspector.codecVerification(
                manifestCodecs: [],
                actualCodec: .hevc,
                sampleEntry: .hev1
            ),
            .manifestMissingButSegmentVerified
        )
    }

    func testUnknownActualCodecIsNotAUsableInspection() {
        XCTAssertEqual(
            HLSPreflightInspector.codecVerification(
                manifestCodecs: ["hvc1.2.4.l150"],
                actualCodec: .unknown,
                sampleEntry: .hvc1
            ),
            .segmentNotInspected
        )
    }

    func testProtectedNativeHLSUsesManifestContractWithoutFetchingMedia()
        async throws
    {
        let rootURL = URL(
            string: "https://example.com/master.m3u8"
        )!
        let mediaURL = URL(
            string: "https://example.com/video.m3u8"
        )!
        let fetchedURLs = LockedURLs()
        let responses: [URL: HLSPreflightFetchResponse] = [
            rootURL: HLSPreflightFetchResponse(
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-STREAM-INF:BANDWIDTH=4000000,CODECS="hvc1.2.4.L150",VIDEO-RANGE=PQ
                    video.m3u8
                    """.utf8
                ),
                effectiveURL: rootURL
            ),
            mediaURL: HLSPreflightFetchResponse(
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-TARGETDURATION:4
                    #EXT-X-KEY:METHOD=SAMPLE-AES,KEYFORMAT="com.apple.streamingkeydelivery",URI="skd://license"
                    #EXT-X-MAP:URI="init.mp4"
                    #EXTINF:4,
                    seg0.m4s
                    #EXT-X-ENDLIST
                    """.utf8
                ),
                effectiveURL: mediaURL
            ),
        ]
        let inspected = try await HLSPreflightInspector(
            httpHeaders: [:],
            fetchOverride: { url, _ in
                fetchedURLs.append(url)
                guard let response = responses[url] else {
                    throw HLSPreflightError.httpStatus(599)
                }
                return response
            }
        ).inspect(
            rootURL: rootURL,
            sourceIsSeekableVOD: true,
            variantSelection: .highestBandwidth,
            hybridCapabilities: HybridPlaybackCapabilities(
                hasDirectVideoDecoder: true,
                hasMetalRenderer: true,
                supportedVideoFormats: [.sdr]
            )
        )

        XCTAssertEqual(inspected.result.route, .nativeAVPlayer)
        XCTAssertEqual(
            inspected.result.reason,
            .nativeProtectedHLSContractVerified
        )
        XCTAssertEqual(
            inspected.result.sourceProfile.videoFormat,
            .hdr10
        )
        XCTAssertEqual(
            inspected.result.hlsPackaging?.contentProtection,
            .fairPlay
        )
        XCTAssertEqual(
            inspected.result.hlsPackaging?.codecVerification,
            .protectedManifestVerified
        )
        XCTAssertEqual(
            inspected.audioAnalysisPolicy,
            .unavailableForAllTracks(
                .contentProtectionUnsupported
            )
        )
        XCTAssertEqual(
            inspected.audioAnalysisPreflightAvailability(
                for: 0
            ),
            .unavailable(
                .contentProtectionUnsupported
            )
        )
        XCTAssertNil(inspected.resourceGraph)
        XCTAssertEqual(
            fetchedURLs.snapshot(),
            [rootURL, mediaURL]
        )
    }

    func testProtectedHEV1HLSIsTypedUnsupportedWithoutFetchingMedia()
        async throws
    {
        let rootURL = URL(
            string: "https://example.com/master.m3u8"
        )!
        let mediaURL = URL(
            string: "https://example.com/video.m3u8"
        )!
        let fetchedURLs = LockedURLs()
        let responses: [URL: HLSPreflightFetchResponse] = [
            rootURL: HLSPreflightFetchResponse(
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-STREAM-INF:BANDWIDTH=4000000,CODECS="hev1.2.4.L150"
                    video.m3u8
                    """.utf8
                ),
                effectiveURL: rootURL
            ),
            mediaURL: HLSPreflightFetchResponse(
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-TARGETDURATION:4
                    #EXT-X-KEY:METHOD=SAMPLE-AES,URI="key.bin"
                    #EXT-X-MAP:URI="init.mp4"
                    #EXTINF:4,
                    seg0.m4s
                    #EXT-X-ENDLIST
                    """.utf8
                ),
                effectiveURL: mediaURL
            ),
        ]
        let inspected = try await HLSPreflightInspector(
            httpHeaders: [:],
            fetchOverride: { url, _ in
                fetchedURLs.append(url)
                guard let response = responses[url] else {
                    throw HLSPreflightError.httpStatus(599)
                }
                return response
            }
        ).inspect(
            rootURL: rootURL,
            sourceIsSeekableVOD: true,
            variantSelection: .highestBandwidth,
            hybridCapabilities: HybridPlaybackCapabilities(
                hasDirectVideoDecoder: true,
                hasMetalRenderer: true,
                supportedVideoFormats: [.sdr]
            )
        )

        XCTAssertEqual(inspected.result.route, .unsupported)
        XCTAssertEqual(
            inspected.result.reason,
            .unsupportedHLSContentProtection
        )
        XCTAssertEqual(
            inspected.result.hlsPackaging?.contentProtection,
            .sampleAES
        )
        XCTAssertEqual(
            inspected.audioAnalysisPolicy,
            .unavailableForAllTracks(
                .contentProtectionUnsupported
            )
        )
        XCTAssertNil(inspected.resourceGraph)
        XCTAssertEqual(
            fetchedURLs.snapshot(),
            [rootURL, mediaURL]
        )
    }

    func testProtectedNativeHLSPublishesPerRenditionAnalysisPolicyWithoutFetchingMedia()
        async throws
    {
        let rootURL = URL(
            string: "https://example.com/master.m3u8"
        )!
        let mediaURL = URL(
            string: "https://example.com/video.m3u8"
        )!
        let clearAudioURL = URL(
            string: "https://example.com/clear.m3u8"
        )!
        let protectedAudioURL = URL(
            string: "https://example.com/protected.m3u8"
        )!
        let fetchedURLs = LockedURLs()
        let responses: [URL: HLSPreflightFetchResponse] = [
            rootURL: HLSPreflightFetchResponse(
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Clear",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="clear.m3u8"
                    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Protected",LANGUAGE="ja",DEFAULT=NO,AUTOSELECT=YES,URI="protected.m3u8"
                    #EXT-X-STREAM-INF:BANDWIDTH=4000000,CODECS="hvc1.2.4.L150",AUDIO="audio"
                    video.m3u8
                    """.utf8
                ),
                effectiveURL: rootURL
            ),
            mediaURL: HLSPreflightFetchResponse(
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-TARGETDURATION:4
                    #EXT-X-KEY:METHOD=SAMPLE-AES,KEYFORMAT="com.apple.streamingkeydelivery",URI="skd://license"
                    #EXT-X-MAP:URI="init.mp4"
                    #EXTINF:4,
                    video0.m4s
                    #EXT-X-ENDLIST
                    """.utf8
                ),
                effectiveURL: mediaURL
            ),
            clearAudioURL: HLSPreflightFetchResponse(
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-TARGETDURATION:4
                    #EXTINF:4,
                    clear0.aac
                    #EXT-X-ENDLIST
                    """.utf8
                ),
                effectiveURL: clearAudioURL
            ),
            protectedAudioURL: HLSPreflightFetchResponse(
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-TARGETDURATION:4
                    #EXT-X-KEY:METHOD=SAMPLE-AES,URI="audio.key"
                    #EXTINF:4,
                    protected0.aac
                    #EXT-X-ENDLIST
                    """.utf8
                ),
                effectiveURL: protectedAudioURL
            ),
        ]

        let inspected = try await HLSPreflightInspector(
            httpHeaders: [:],
            fetchOverride: { url, _ in
                fetchedURLs.append(url)
                guard let response = responses[url] else {
                    throw HLSPreflightError.httpStatus(599)
                }
                return response
            }
        ).inspect(
            rootURL: rootURL,
            sourceIsSeekableVOD: true,
            variantSelection: .highestBandwidth,
            hybridCapabilities: HybridPlaybackCapabilities(
                hasDirectVideoDecoder: true,
                hasMetalRenderer: true,
                supportedVideoFormats: [.sdr]
            )
        )

        XCTAssertEqual(inspected.result.route, .nativeAVPlayer)
        XCTAssertEqual(
            inspected.audioAnalysisPolicy,
            .selectedAlternateAudioRenditions([
                AetherHLSAudioRenditionAnalysisPolicy(
                    audioTrackID: 0,
                    name: "Clear",
                    language: "en",
                    isDefault: true,
                    availability:
                        .requiresPlaybackSessionBinding
                ),
                AetherHLSAudioRenditionAnalysisPolicy(
                    audioTrackID: 1,
                    name: "Protected",
                    language: "ja",
                    isDefault: false,
                    availability: .unavailable(
                        .contentProtectionUnsupported
                    )
                ),
            ])
        )
        XCTAssertEqual(
            inspected.audioAnalysisPreflightAvailability(
                for: 0
            ),
            .requiresPlaybackSessionBinding
        )
        XCTAssertEqual(
            inspected.audioAnalysisPreflightAvailability(
                for: 1
            ),
            .unavailable(
                .contentProtectionUnsupported
            )
        )
        XCTAssertEqual(
            inspected.audioAnalysisPreflightAvailability(
                for: 99
            ),
            .unavailable(
                .audioTrackUnavailable(99)
            )
        )
        XCTAssertEqual(
            fetchedURLs.snapshot(),
            [
                rootURL,
                mediaURL,
                clearAudioURL,
                protectedAudioURL,
            ]
        )
    }

    func testNativePlaybackSurvivesAlternateAudioAnalysisPreflightFailure()
        async throws
    {
        let rootURL = URL(
            string: "https://example.com/master.m3u8"
        )!
        let mediaURL = URL(
            string: "https://example.com/video.m3u8"
        )!
        let brokenAudioURL = URL(
            string: "https://example.com/broken.m3u8"
        )!
        let fetchedURLs = LockedURLs()
        let responses: [URL: HLSPreflightFetchResponse] = [
            rootURL: HLSPreflightFetchResponse(
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Broken",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="broken.m3u8"
                    #EXT-X-STREAM-INF:BANDWIDTH=4000000,CODECS="hvc1.2.4.L150",AUDIO="audio"
                    video.m3u8
                    """.utf8
                ),
                effectiveURL: rootURL
            ),
            mediaURL: HLSPreflightFetchResponse(
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-TARGETDURATION:4
                    #EXT-X-KEY:METHOD=SAMPLE-AES,KEYFORMAT="com.apple.streamingkeydelivery",URI="skd://license"
                    #EXT-X-MAP:URI="init.mp4"
                    #EXTINF:4,
                    video0.m4s
                    #EXT-X-ENDLIST
                    """.utf8
                ),
                effectiveURL: mediaURL
            ),
        ]

        let inspected = try await HLSPreflightInspector(
            httpHeaders: [:],
            fetchOverride: { url, _ in
                fetchedURLs.append(url)
                guard let response = responses[url] else {
                    throw HLSPreflightError.httpStatus(503)
                }
                return response
            }
        ).inspect(
            rootURL: rootURL,
            sourceIsSeekableVOD: true,
            variantSelection: .highestBandwidth,
            hybridCapabilities: HybridPlaybackCapabilities(
                hasDirectVideoDecoder: true,
                hasMetalRenderer: true,
                supportedVideoFormats: [.sdr]
            )
        )

        XCTAssertEqual(inspected.result.route, .nativeAVPlayer)
        XCTAssertEqual(
            inspected.result.reason,
            .nativeProtectedHLSContractVerified
        )
        XCTAssertEqual(
            inspected.audioAnalysisPolicy,
            .selectedAlternateAudioRenditions([
                AetherHLSAudioRenditionAnalysisPolicy(
                    audioTrackID: 0,
                    name: "Broken",
                    language: "en",
                    isDefault: true,
                    availability: .unavailable(
                        .hlsResourceFailure(
                            "alternate-audio playlist preflight failed"
                        )
                    )
                ),
            ])
        )
        XCTAssertNil(inspected.resourceGraph)
        XCTAssertEqual(
            fetchedURLs.snapshot(),
            [rootURL, mediaURL, brokenAudioURL]
        )
    }

    func testProtectedAlternateAudioTurnsHybridCandidateIntoTypedUnsupported()
        async throws
    {
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: 1,
                preferredTimescale: 90_000
            )
        )
        let provider = try BlackCarrierVideoProvider(
            timeline: timeline
        )
        defer { provider.close() }
        let initData = try XCTUnwrap(provider.initSegment())
        let segmentData = try XCTUnwrap(
            provider.mediaSegment(at: 0)
        )
        let rootURL = URL(
            string: "https://example.com/master.m3u8"
        )!
        let mediaURL = URL(
            string: "https://example.com/video.m3u8"
        )!
        let initURL = URL(
            string: "https://example.com/init.mp4"
        )!
        let segmentURL = URL(
            string: "https://example.com/seg0.m4s"
        )!
        let audioURL = URL(
            string: "https://example.com/audio.m3u8"
        )!
        let responses: [URL: HLSPreflightFetchResponse] = [
            rootURL: HLSPreflightFetchResponse(
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",DEFAULT=YES,AUTOSELECT=YES,URI="audio.m3u8"
                    #EXT-X-STREAM-INF:BANDWIDTH=1200000,CODECS="hvc1.2.4.L150",AUDIO="audio"
                    video.m3u8
                    """.utf8
                ),
                effectiveURL: rootURL
            ),
            mediaURL: HLSPreflightFetchResponse(
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-TARGETDURATION:1
                    #EXT-X-MAP:URI="init.mp4"
                    #EXTINF:1,
                    seg0.m4s
                    #EXT-X-ENDLIST
                    """.utf8
                ),
                effectiveURL: mediaURL
            ),
            initURL: HLSPreflightFetchResponse(
                data: initData,
                effectiveURL: initURL
            ),
            segmentURL: HLSPreflightFetchResponse(
                data: segmentData,
                effectiveURL: segmentURL
            ),
            audioURL: HLSPreflightFetchResponse(
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-TARGETDURATION:1
                    #EXT-X-KEY:METHOD=SAMPLE-AES,URI="key.bin"
                    #EXTINF:1,
                    audio0.aac
                    #EXT-X-ENDLIST
                    """.utf8
                ),
                effectiveURL: audioURL
            ),
        ]
        let inspected = try await HLSPreflightInspector(
            httpHeaders: [:],
            fetchOverride: { url, _ in
                guard let response = responses[url] else {
                    throw HLSPreflightError.httpStatus(599)
                }
                return response
            }
        ).inspect(
            rootURL: rootURL,
            sourceIsSeekableVOD: true,
            variantSelection: .highestBandwidth,
            hybridCapabilities: HybridPlaybackCapabilities(
                hasDirectVideoDecoder: true,
                hasMetalRenderer: true,
                supportedVideoFormats: [.sdr]
            )
        )

        XCTAssertEqual(inspected.result.route, .unsupported)
        XCTAssertEqual(
            inspected.result.reason,
            .unsupportedHLSContentProtection
        )
        XCTAssertEqual(
            inspected.result.hlsPackaging?.contentProtection,
            .sampleAES
        )
        XCTAssertEqual(
            inspected.audioAnalysisPolicy,
            .selectedAlternateAudioRenditions([
                AetherHLSAudioRenditionAnalysisPolicy(
                    audioTrackID: 0,
                    name: "English",
                    language: nil,
                    isDefault: true,
                    availability: .unavailable(
                        .contentProtectionUnsupported
                    )
                ),
            ])
        )
        XCTAssertNil(inspected.resourceGraph)
        XCTAssertNil(inspected.resourceIdentity)
        XCTAssertNil(inspected.hybridTimeline)
    }

    func testSelectedVODResourcesAreBoundWithoutExposingSignedURLs() async throws {
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: 1.25,
                preferredTimescale: 90_000
            )
        )
        let provider = try BlackCarrierVideoProvider(timeline: timeline)
        defer { provider.close() }
        let initData = try XCTUnwrap(provider.initSegment())
        let segmentData = try XCTUnwrap(provider.mediaSegment(at: 0))

        let requestedRoot = URL(
            string:
                "https://origin.example/master.m3u8?token=root-secret"
        )!
        let effectiveRoot = URL(
            string:
                "https://cdn.example/catalog/master.m3u8?token=redirect-secret"
        )!
        let selectedURI =
            "video/main.m3u8?token=media-secret"
        let selectedMediaURL = URL(
            string:
                "https://cdn.example/catalog/video/main.m3u8?token=media-secret"
        )!
        let initURL = URL(
            string:
                "https://cdn.example/catalog/video/init.mp4?token=init-secret"
        )!
        let segmentURL = URL(
            string:
                "https://cdn.example/catalog/video/seg0.m4s?token=segment-secret"
        )!
        let effectiveInitURL = URL(
            string:
                "https://media-cdn.example/video/init.mp4?token=effective-init-secret"
        )!
        let effectiveSegmentURL = URL(
            string:
                "https://media-cdn.example/video/seg0.m4s?token=effective-segment-secret"
        )!
        let audioPlaylistURL = URL(
            string:
                "https://cdn.example/audio/en.m3u8?token=audio-playlist-secret"
        )!
        let alternateAudioPlaylistURL = URL(
            string:
                "https://cdn.example/audio/fr.m3u8?token=alternate-audio-playlist-secret"
        )!
        let master = Data(
            """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="2",URI="../audio/en.m3u8?token=audio-playlist-secret"
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Français",LANGUAGE="fr",DEFAULT=NO,AUTOSELECT=YES,CHANNELS="2",URI="../audio/fr.m3u8?token=alternate-audio-playlist-secret"
            #EXT-X-STREAM-INF:BANDWIDTH=900000,CODECS="avc1.42C01E"
            video/low.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=1400000,CODECS="hvc1.2.4.L150",AUDIO="audio"
            \(selectedURI)
            """.utf8
        )
        let media = Data(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:2
            #EXT-X-MEDIA-SEQUENCE:17
            #EXT-X-MAP:URI="init.mp4?token=init-secret"
            #EXTINF:1.250,
            seg0.m4s?token=segment-secret
            #EXT-X-ENDLIST
            """.utf8
        )
        let audioMedia = Data(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:2
            #EXT-X-MEDIA-SEQUENCE:31
            #EXTINF:0.625,
            a0.aac?token=audio-segment-0-secret
            #EXTINF:0.625,
            a1.aac?token=audio-segment-1-secret
            #EXT-X-ENDLIST
            """.utf8
        )
        let alternateAudioMedia = Data(
            """
            #EXTM3U
            #EXT-X-TARGETDURATION:2
            #EXT-X-MEDIA-SEQUENCE:41
            #EXTINF:0.625,
            a0.aac?token=alternate-audio-segment-0-secret
            #EXTINF:0.625,
            a1.aac?token=alternate-audio-segment-1-secret
            #EXT-X-ENDLIST
            """.utf8
        )
        let responses: [URL: HLSPreflightFetchResponse] = [
            requestedRoot: HLSPreflightFetchResponse(
                data: master,
                effectiveURL: effectiveRoot
            ),
            selectedMediaURL: HLSPreflightFetchResponse(
                data: media,
                effectiveURL: selectedMediaURL
            ),
            initURL: HLSPreflightFetchResponse(
                data: initData,
                effectiveURL: effectiveInitURL
            ),
            segmentURL: HLSPreflightFetchResponse(
                data: segmentData,
                effectiveURL: effectiveSegmentURL
            ),
            audioPlaylistURL: HLSPreflightFetchResponse(
                data: audioMedia,
                effectiveURL: audioPlaylistURL
            ),
            alternateAudioPlaylistURL: HLSPreflightFetchResponse(
                data: alternateAudioMedia,
                effectiveURL: alternateAudioPlaylistURL
            ),
        ]
        let headers = [
            "Authorization": "Bearer header-secret",
            "User-Agent": "AetherTests/1",
        ]
        let fetch: HLSPreflightInspector.Fetch = {
            url,
            receivedHeaders in
            XCTAssertEqual(receivedHeaders, headers)
            guard let response = responses[url] else {
                throw HLSPreflightError.httpStatus(404)
            }
            return response
        }
        let capabilities = HybridPlaybackCapabilities(
            hasDirectVideoDecoder: true,
            hasMetalRenderer: true,
            supportedVideoFormats: [.sdr]
        )
        let inspected = try await HLSPreflightInspector(
            httpHeaders: headers,
            fetchOverride: fetch
        ).inspect(
            rootURL: requestedRoot,
            sourceIsSeekableVOD: true,
            variantSelection: .exactURI(selectedURI),
            hybridCapabilities: capabilities
        )

        XCTAssertEqual(inspected.result.route, .hybridCarrierMetal)
        XCTAssertEqual(
            inspected.audioAnalysisPolicy,
            .selectedAlternateAudioRenditions([
                AetherHLSAudioRenditionAnalysisPolicy(
                    audioTrackID: 0,
                    name: "English",
                    language: "en",
                    isDefault: true,
                    availability:
                        .requiresPlaybackSessionBinding
                ),
                AetherHLSAudioRenditionAnalysisPolicy(
                    audioTrackID: 1,
                    name: "Français",
                    language: "fr",
                    isDefault: false,
                    availability:
                        .requiresPlaybackSessionBinding
                ),
            ])
        )
        XCTAssertEqual(
            inspected.result.reason,
            .hybridHLSManifestSegmentMismatch
        )
        XCTAssertEqual(inspected.selectedVariantBandwidth, 1_400_000)
        XCTAssertEqual(inspected.mediaSegmentCount, 1)
        XCTAssertTrue(inspected.hasSeparateAudioRenditions)
        XCTAssertEqual(inspected.audioRenditionCount, 2)
        XCTAssertEqual(
            inspected.hybridTimeline?.segments.map(\.duration),
            timeline.segments.map(\.duration)
        )
        let identity = try XCTUnwrap(inspected.resourceIdentity)
        XCTAssertEqual(identity.count, 64)
        XCTAssertNil(identity.range(of: "secret"))
        XCTAssertEqual(
            inspected.resourceGraph?.selectedMediaPlaylistURL,
            selectedMediaURL
        )
        XCTAssertEqual(
            inspected.resourceGraph?.segments.first?.mediaSequence,
            17
        )
        XCTAssertEqual(
            inspected.resourceGraph?.segments.first?.url,
            segmentURL
        )
        XCTAssertEqual(
            inspected.resourceGraph?
                .inspectedInitSegmentEffectiveURL,
            effectiveInitURL
        )
        XCTAssertEqual(
            inspected.resourceGraph?
                .inspectedFirstMediaSegmentEffectiveURL,
            effectiveSegmentURL
        )
        XCTAssertEqual(
            inspected.resourceGraph?.audioRenditions.first?.name,
            "English"
        )
        XCTAssertEqual(
            inspected.resourceGraph?.audioRenditions.first?.language,
            "en"
        )
        XCTAssertEqual(
            inspected.resourceGraph?.audioRenditions.first?.channels,
            "2"
        )
        XCTAssertEqual(
            inspected.resourceGraph?.audioRenditions.first?.segments
                .map(\.mediaSequence),
            [31, 32]
        )
        XCTAssertEqual(
            inspected.resourceGraph?.audioRenditions.last?.name,
            "Français"
        )
        XCTAssertEqual(
            inspected.resourceGraph?.audioRenditions.last?.language,
            "fr"
        )
        XCTAssertEqual(
            inspected.resourceGraph?.audioRenditions.last?.segments
                .map(\.mediaSequence),
            [41, 42]
        )

        guard case .media(let parsedMedia) = try HLSPlaylistParser.parse(
            String(decoding: media, as: UTF8.self)
        ) else {
            return XCTFail("expected media playlist")
        }
        let changed = try HLSVODResourceGraph.make(
            requestedRootURL: requestedRoot,
            effectiveRootURL: effectiveRoot,
            selectedMediaPlaylistURL: selectedMediaURL,
            selectedVariant: HLSVariant(
                bandwidth: 1_400_000,
                uri: selectedURI,
                audioGroupID: "audio",
                codecs: ["avc1.42c01e"]
            ),
            separateAudioGroupID: "audio",
            mediaPlaylistData: media,
            media: parsedMedia,
            audioRenditions:
                try XCTUnwrap(inspected.resourceGraph)
                    .audioRenditions,
            inspectedInitSegmentData: initData,
            inspectedInitSegmentEffectiveURL:
                effectiveInitURL,
            inspectedFirstMediaSegmentData: segmentData,
            inspectedFirstMediaSegmentEffectiveURL:
                effectiveSegmentURL,
            httpHeaders: [
                "Authorization": "Bearer changed-secret",
                "User-Agent": "AetherTests/1",
            ]
        )
        XCTAssertNotEqual(changed.identity, identity)

        var changedFirstSegment = segmentData
        changedFirstSegment.append(0)
        let changedEvidence = try HLSVODResourceGraph.make(
            requestedRootURL: requestedRoot,
            effectiveRootURL: effectiveRoot,
            selectedMediaPlaylistURL: selectedMediaURL,
            selectedVariant: HLSVariant(
                bandwidth: 1_400_000,
                uri: selectedURI,
                audioGroupID: "audio",
                codecs: ["avc1.42c01e"]
            ),
            separateAudioGroupID: "audio",
            mediaPlaylistData: media,
            media: parsedMedia,
            audioRenditions:
                try XCTUnwrap(inspected.resourceGraph)
                    .audioRenditions,
            inspectedInitSegmentData: initData,
            inspectedInitSegmentEffectiveURL:
                effectiveInitURL,
            inspectedFirstMediaSegmentData:
                changedFirstSegment,
            inspectedFirstMediaSegmentEffectiveURL:
                effectiveSegmentURL,
            httpHeaders: headers
        )
        XCTAssertNotEqual(changedEvidence.identity, identity)

        let changedRedirect = try HLSVODResourceGraph.make(
            requestedRootURL: requestedRoot,
            effectiveRootURL: effectiveRoot,
            selectedMediaPlaylistURL: selectedMediaURL,
            selectedVariant: HLSVariant(
                bandwidth: 1_400_000,
                uri: selectedURI,
                audioGroupID: "audio",
                codecs: ["avc1.42c01e"]
            ),
            separateAudioGroupID: "audio",
            mediaPlaylistData: media,
            media: parsedMedia,
            audioRenditions:
                try XCTUnwrap(inspected.resourceGraph)
                    .audioRenditions,
            inspectedInitSegmentData: initData,
            inspectedInitSegmentEffectiveURL:
                effectiveInitURL,
            inspectedFirstMediaSegmentData: segmentData,
            inspectedFirstMediaSegmentEffectiveURL:
                URL(
                    string:
                        "https://other-cdn.example/video/seg0.m4s"
                )!,
            httpHeaders: headers
        )
        XCTAssertNotEqual(
            changedRedirect.identity,
            identity
        )
    }

    func testResourceGraphRejectsAlternateAudioOutsideSelectedGroup() throws {
        let baseURL = URL(
            string: "https://example.com/video/media.m3u8"
        )!
        let media = HLSMediaPlaylist(
            targetDuration: 4,
            mediaSequence: 0,
            segments: [
                HLSMediaSegment(
                    uri: "seg0.ts",
                    duration: 4,
                    discontinuityBefore: false
                ),
            ],
            hasEndList: true,
            hasUnsupportedEncryption: false,
            hasMap: false,
            mapURI: nil,
            contentProtection: .none
        )
        let wrongGroup = HLSVODAudioRenditionResource(
            ordinal: 0,
            groupID: "commentary",
            name: "Commentary",
            language: "en",
            isDefault: false,
            isAutoselect: true,
            channels: "2",
            playlistURL: baseURL,
            playlistData: Data(),
            initSegmentURL: nil,
            segments: []
        )

        XCTAssertThrowsError(
            try HLSVODResourceGraph.make(
                requestedRootURL: baseURL,
                effectiveRootURL: baseURL,
                selectedMediaPlaylistURL: baseURL,
                selectedVariant: nil,
                separateAudioGroupID: "audio",
                mediaPlaylistData: Data(),
                media: media,
                audioRenditions: [wrongGroup],
                inspectedInitSegmentData: nil,
                inspectedInitSegmentEffectiveURL: nil,
                inspectedFirstMediaSegmentData: Data([0x47]),
                inspectedFirstMediaSegmentEffectiveURL:
                    baseURL,
                httpHeaders: [:]
            )
        ) { error in
            XCTAssertEqual(
                error as? HLSPreflightError,
                .unsupportedSeekableVODResourceGraph(
                    reason: "invalid separate alternate-audio group"
                )
            )
        }
    }

    func testResourceGraphRejectsAlternateAudioDurationMismatch()
        throws
    {
        let baseURL = URL(
            string: "https://example.com/video/media.m3u8"
        )!
        let videoMedia = HLSMediaPlaylist(
            targetDuration: 4,
            mediaSequence: 0,
            segments: [
                HLSMediaSegment(
                    uri: "video.ts",
                    duration: 4,
                    discontinuityBefore: false
                ),
            ],
            hasEndList: true,
            hasUnsupportedEncryption: false,
            hasMap: false,
            mapURI: nil,
            contentProtection: .none
        )
        let audioMedia = HLSMediaPlaylist(
            targetDuration: 3,
            mediaSequence: 0,
            segments: [
                HLSMediaSegment(
                    uri: "audio.aac",
                    duration: 3,
                    discontinuityBefore: false
                ),
            ],
            hasEndList: true,
            hasUnsupportedEncryption: false,
            hasMap: false,
            mapURI: nil,
            contentProtection: .none
        )
        let audio = try HLSVODResourceGraph
            .makeAudioRendition(
                ordinal: 0,
                metadata: HLSAudioRendition(
                    groupID: "audio",
                    uri: "audio.m3u8",
                    name: "English",
                    isDefault: true
                ),
                playlistURL: baseURL,
                playlistData: Data(),
                media: audioMedia
            )

        XCTAssertThrowsError(
            try HLSVODResourceGraph.make(
                requestedRootURL: baseURL,
                effectiveRootURL: baseURL,
                selectedMediaPlaylistURL: baseURL,
                selectedVariant: nil,
                separateAudioGroupID: "audio",
                mediaPlaylistData: Data(),
                media: videoMedia,
                audioRenditions: [audio],
                inspectedInitSegmentData: nil,
                inspectedInitSegmentEffectiveURL: nil,
                inspectedFirstMediaSegmentData:
                    Data([0x47]),
                inspectedFirstMediaSegmentEffectiveURL:
                    baseURL,
                httpHeaders: [:]
            )
        ) { error in
            XCTAssertEqual(
                error as? HLSPreflightError,
                .unsupportedSeekableVODResourceGraph(
                    reason:
                        "alternate-audio rendition duration does not match selected video"
                )
            )
        }
    }

    func testSeekableVODResourceGraphRejectsNonFiniteOrAmbiguousPlaylists() throws {
        let baseURL = URL(
            string: "https://example.com/video/media.m3u8"
        )!
        let segment = HLSMediaSegment(
            uri: "seg0.ts",
            duration: 4,
            discontinuityBefore: false
        )
        let makeMedia: (
            Bool,
            Bool,
            Bool
        ) -> HLSMediaPlaylist = {
            hasEndList,
            hasByteRange,
            discontinuity in
            HLSMediaPlaylist(
                targetDuration: 4,
                mediaSequence: 0,
                segments: [
                    HLSMediaSegment(
                        uri: segment.uri,
                        duration: segment.duration,
                        discontinuityBefore: discontinuity
                    ),
                ],
                hasEndList: hasEndList,
                hasUnsupportedEncryption: false,
                hasMap: false,
                mapURI: nil,
                hasByteRange: hasByteRange,
                contentProtection: .none
            )
        }

        XCTAssertThrowsError(
            try HLSVODResourceGraph.make(
                requestedRootURL: baseURL,
                effectiveRootURL: baseURL,
                selectedMediaPlaylistURL: baseURL,
                selectedVariant: nil,
                separateAudioGroupID: nil,
                mediaPlaylistData: Data(),
                media: makeMedia(false, false, false),
                audioRenditions: [],
                inspectedInitSegmentData: nil,
                inspectedInitSegmentEffectiveURL: nil,
                inspectedFirstMediaSegmentData: Data([0x47]),
                inspectedFirstMediaSegmentEffectiveURL:
                    baseURL,
                httpHeaders: [:]
            )
        ) { error in
            XCTAssertEqual(
                error as? HLSPreflightError,
                .seekableVODPlaylistNotFinite
            )
        }
        for media in [
            makeMedia(true, true, false),
            makeMedia(true, false, true),
        ] {
            XCTAssertThrowsError(
                try HLSVODResourceGraph.make(
                    requestedRootURL: baseURL,
                    effectiveRootURL: baseURL,
                    selectedMediaPlaylistURL: baseURL,
                    selectedVariant: nil,
                    separateAudioGroupID: nil,
                    mediaPlaylistData: Data(),
                    media: media,
                    audioRenditions: [],
                    inspectedInitSegmentData: nil,
                    inspectedInitSegmentEffectiveURL: nil,
                    inspectedFirstMediaSegmentData: Data([0x47]),
                    inspectedFirstMediaSegmentEffectiveURL:
                        baseURL,
                    httpHeaders: [:]
                )
            )
        }
    }

    func testNativeHLSDoesNotApplyHybridResourceGraphRestrictions() async throws {
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: 1,
                preferredTimescale: 90_000
            )
        )
        let provider = try BlackCarrierVideoProvider(timeline: timeline)
        defer { provider.close() }
        let initData = try XCTUnwrap(provider.initSegment())
        let segmentData = try XCTUnwrap(provider.mediaSegment(at: 0))
        let rootURL = URL(
            string: "https://example.com/master.m3u8"
        )!
        let mediaURL = URL(
            string: "https://example.com/media.m3u8"
        )!
        let initURL = URL(
            string: "https://example.com/init.mp4"
        )!
        let segmentURL = URL(
            string: "https://example.com/seg0.m4s"
        )!
        let responses: [URL: HLSPreflightFetchResponse] = [
            rootURL: HLSPreflightFetchResponse(
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-STREAM-INF:BANDWIDTH=1000000,CODECS="avc1.42C01E"
                    media.m3u8
                    """.utf8
                ),
                effectiveURL: rootURL
            ),
            mediaURL: HLSPreflightFetchResponse(
                data: Data(
                    """
                    #EXTM3U
                    #EXT-X-TARGETDURATION:1
                    #EXT-X-MAP:URI="init.mp4"
                    #EXT-X-DISCONTINUITY
                    #EXTINF:1,
                    seg0.m4s
                    #EXT-X-ENDLIST
                    """.utf8
                ),
                effectiveURL: mediaURL
            ),
            initURL: HLSPreflightFetchResponse(
                data: initData,
                effectiveURL: initURL
            ),
            segmentURL: HLSPreflightFetchResponse(
                data: segmentData,
                effectiveURL: segmentURL
            ),
        ]
        let inspected = try await HLSPreflightInspector(
            httpHeaders: [:],
            fetchOverride: { url, _ in
                guard let response = responses[url] else {
                    throw HLSPreflightError.httpStatus(404)
                }
                return response
            }
        ).inspect(
            rootURL: rootURL,
            sourceIsSeekableVOD: true,
            variantSelection: .highestBandwidth,
            hybridCapabilities: HybridPlaybackCapabilities(
                hasDirectVideoDecoder: true,
                hasMetalRenderer: true,
                supportedVideoFormats: [.sdr]
            )
        )

        XCTAssertEqual(inspected.result.route, .nativeAVPlayer)
        XCTAssertNil(inspected.resourceGraph)
        XCTAssertNil(inspected.resourceIdentity)
        XCTAssertNil(inspected.hybridTimeline)
    }

    func testByteRangeHLSStopsBeforeFetchingTheBackingObject() async throws {
        let rootURL = URL(
            string: "https://example.com/media.m3u8"
        )!
        let fetchedURLs = LockedURLs()
        let inspected = try await HLSPreflightInspector(
            httpHeaders: [:],
            fetchOverride: { url, _ in
                fetchedURLs.append(url)
                guard url == rootURL else {
                    throw HLSPreflightError.httpStatus(599)
                }
                return HLSPreflightFetchResponse(
                    data: Data(
                        """
                        #EXTM3U
                        #EXT-X-TARGETDURATION:4
                        #EXT-X-MAP:URI="media.mp4",BYTERANGE="720@0"
                        #EXTINF:4,
                        #EXT-X-BYTERANGE:4096@720
                        media.mp4
                        #EXT-X-ENDLIST
                        """.utf8
                    ),
                    effectiveURL: rootURL
                )
            }
        ).inspect(
            rootURL: rootURL,
            sourceIsSeekableVOD: true,
            variantSelection: .highestBandwidth,
            hybridCapabilities: HybridPlaybackCapabilities(
                hasDirectVideoDecoder: true,
                hasMetalRenderer: true,
                supportedVideoFormats: [.sdr]
            )
        )

        XCTAssertEqual(
            inspected.result.reason,
            .unsupportedHLSSegmentNotInspected
        )
        XCTAssertEqual(fetchedURLs.snapshot(), [rootURL])
        XCTAssertNil(inspected.resourceGraph)
    }
}

private final class LockedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL] = []

    func append(_ url: URL) {
        lock.withLock {
            values.append(url)
        }
    }

    func snapshot() -> [URL] {
        lock.withLock { values }
    }
}
