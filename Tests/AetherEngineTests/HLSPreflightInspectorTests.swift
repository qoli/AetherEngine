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
                effectiveURL: initURL
            ),
            segmentURL: HLSPreflightFetchResponse(
                data: segmentData,
                effectiveURL: segmentURL
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
            httpHeaders: [
                "Authorization": "Bearer changed-secret",
                "User-Agent": "AetherTests/1",
            ]
        )
        XCTAssertNotEqual(changed.identity, identity)
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
