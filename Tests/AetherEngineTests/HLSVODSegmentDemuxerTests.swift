import Foundation
import Libavcodec
import Libavformat
import XCTest
@testable import AetherEngine

final class HLSVODSegmentDemuxerTests: XCTestCase {
    private struct Fixture {
        let preflight: AetherHLSPlaybackPreflight
        let audioInitURL: URL
        let audioSegmentURL: URL
        let audioInitData: Data
        let audioSegmentData: Data
    }

    func testGraphBoundVideoAndAudioSegmentsPassRealDemuxAdmission()
        async throws
    {
        let fixture = try makeFixture(
            expectedVideoCodec: .h264,
            declaredAudioChannels: "2"
        )
        let demuxer = try makeSegmentDemuxer(fixture)
        addTeardownBlock {
            try await demuxer.close()
        }

        let video = try await demuxer.inspectVideoSegment(
            at: 0
        )
        XCTAssertEqual(video.container, .fragmentedMP4)
        XCTAssertEqual(video.videoCodec, .h264)
        XCTAssertEqual(video.mediaSequence, 17)
        XCTAssertGreaterThan(video.videoPacketCount, 0)
        XCTAssertTrue(video.muxedAudioStreams.isEmpty)

        let audio = try await demuxer.inspectAudioSegment(
            renditionOrdinal: 0,
            segmentIndex: 0
        )
        XCTAssertEqual(audio.container, .fragmentedMP4)
        XCTAssertEqual(audio.mediaSequence, 31)
        XCTAssertEqual(audio.manifestName, "English")
        XCTAssertEqual(audio.manifestLanguage, "en")
        XCTAssertEqual(audio.manifestChannels, "2")
        XCTAssertEqual(audio.stream.track.codec, "eac3")
        XCTAssertEqual(audio.stream.track.channels, 2)
        XCTAssertGreaterThan(audio.stream.packetCount, 0)
        XCTAssertEqual(
            audio.stream.carrierDescriptor.pipeline,
            .streamCopy(codecString: "ec-3")
        )
        XCTAssertEqual(
            audio.stream.carrierDescriptor.channelsAttribute,
            "2"
        )
        try await demuxer.close()
    }

    func testVideoCodecChangeFailsBeforePumpCreation()
        async throws
    {
        let fixture = try makeFixture(
            expectedVideoCodec: .hevc,
            declaredAudioChannels: "2"
        )
        let demuxer = try makeSegmentDemuxer(fixture)
        addTeardownBlock {
            try await demuxer.close()
        }

        do {
            _ = try await demuxer.inspectVideoSegment(
                at: 0
            )
            XCTFail("changed video codec unexpectedly admitted")
        } catch let error as HLSVODSegmentDemuxError {
            XCTAssertEqual(
                error,
                .videoCodecMismatch(
                    expected: .hevc,
                    actual: .h264
                )
            )
        }
        try await demuxer.close()
    }

    func testManifestChannelsMismatchFailsExplicitly()
        async throws
    {
        let fixture = try makeFixture(
            expectedVideoCodec: .h264,
            declaredAudioChannels: "6"
        )
        let demuxer = try makeSegmentDemuxer(fixture)
        addTeardownBlock {
            try await demuxer.close()
        }

        do {
            _ = try await demuxer.inspectAudioSegment(
                renditionOrdinal: 0,
                segmentIndex: 0
            )
            XCTFail("mismatched CHANNELS unexpectedly admitted")
        } catch let error as HLSVODSegmentDemuxError {
            XCTAssertEqual(
                error,
                .audioChannelsMismatch(
                    renditionOrdinal: 0,
                    declared: "6",
                    admitted: "2"
                )
            )
        }
        try await demuxer.close()
    }

    private func makeSegmentDemuxer(
        _ fixture: Fixture
    ) throws -> HLSVODSegmentDemuxer {
        let responses: [
            URL:
                HLSVODOriginFetchResponse
        ] = [
            fixture.audioInitURL:
                HLSVODOriginFetchResponse(
                    data: fixture.audioInitData,
                    effectiveURL: fixture.audioInitURL,
                    statusCode: 200,
                    contentLength:
                        Int64(fixture.audioInitData.count),
                    contentEncoding: nil
                ),
            fixture.audioSegmentURL:
                HLSVODOriginFetchResponse(
                    data: fixture.audioSegmentData,
                    effectiveURL:
                        fixture.audioSegmentURL,
                    statusCode: 200,
                    contentLength:
                        Int64(
                            fixture.audioSegmentData.count
                        ),
                    contentEncoding: nil
                ),
        ]
        return try HLSVODSegmentDemuxer(
            preflight: fixture.preflight,
            fetchOverride: { request, _ in
                guard let url = request.url,
                      let response = responses[url] else {
                    throw HLSVODOriginResourceError
                        .httpStatus(404)
                }
                return response
            }
        )
    }

    private func makeFixture(
        expectedVideoCodec: AetherVideoCodec,
        declaredAudioChannels: String
    ) throws -> Fixture {
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: 2,
                preferredTimescale:
                    BlackCarrierProfile.approved.timescale
            )
        )
        let videoProvider = try BlackCarrierVideoProvider(
            timeline: timeline
        )
        defer { videoProvider.close() }
        let videoInitData = try XCTUnwrap(
            videoProvider.initSegment()
        )
        let videoSegmentData = try XCTUnwrap(
            videoProvider.mediaSegment(at: 0)
        )
        let audio = try makeAudioFMP4(seconds: 2)

        let rootURL = URL(
            string: "https://origin.example/master.m3u8"
        )!
        let effectiveRootURL = URL(
            string: "https://cdn.example/master.m3u8"
        )!
        let videoPlaylistURL = URL(
            string: "https://cdn.example/video/main.m3u8"
        )!
        let videoInitURL = URL(
            string: "https://cdn.example/video/init.mp4"
        )!
        let videoSegmentURL = URL(
            string: "https://cdn.example/video/v0.m4s"
        )!
        let audioPlaylistURL = URL(
            string: "https://cdn.example/audio/en.m3u8"
        )!
        let audioInitURL = URL(
            string: "https://cdn.example/audio/init.mp4"
        )!
        let audioSegmentURL = URL(
            string: "https://cdn.example/audio/a0.m4s"
        )!
        let videoMedia = HLSMediaPlaylist(
            targetDuration: 2,
            mediaSequence: 17,
            segments: [
                HLSMediaSegment(
                    uri: videoSegmentURL.lastPathComponent,
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
            targetDuration: 2,
            mediaSequence: 31,
            segments: [
                HLSMediaSegment(
                    uri: audioSegmentURL.lastPathComponent,
                    duration: 2,
                    discontinuityBefore: false
                ),
            ],
            hasEndList: true,
            hasUnsupportedEncryption: false,
            hasMap: true,
            mapURI: audioInitURL.lastPathComponent,
            contentProtection: .none
        )
        let audioResource =
            try HLSVODResourceGraph.makeAudioRendition(
                ordinal: 0,
                metadata: HLSAudioRendition(
                    groupID: "audio",
                    uri: "en.m3u8",
                    name: "English",
                    language: "en",
                    isDefault: true,
                    isAutoselect: true,
                    channels: declaredAudioChannels
                ),
                playlistURL: audioPlaylistURL,
                playlistData: Data("#EXTM3U".utf8),
                media: audioMedia
            )
        let graph = try HLSVODResourceGraph.make(
            requestedRootURL: rootURL,
            effectiveRootURL: effectiveRootURL,
            selectedMediaPlaylistURL: videoPlaylistURL,
            selectedVariant: HLSVariant(
                bandwidth: 1_400_000,
                uri: "video/main.m3u8",
                audioGroupID: "audio",
                codecs: ["avc1.42c01e"]
            ),
            separateAudioGroupID: "audio",
            mediaPlaylistData: Data("#EXTM3U".utf8),
            media: videoMedia,
            audioRenditions: [audioResource],
            inspectedInitSegmentData: videoInitData,
            inspectedInitSegmentEffectiveURL:
                videoInitURL,
            inspectedFirstMediaSegmentData:
                videoSegmentData,
            inspectedFirstMediaSegmentEffectiveURL:
                videoSegmentURL,
            httpHeaders: [:]
        )
        let result = PlaybackPreflightResult(
            sourceProfile: AetherSourceProfile(
                sourceKind: .hls,
                isSeekableVOD: true,
                videoCodec: expectedVideoCodec,
                videoFormat: .sdr
            ),
            hlsPackaging: HLSVideoPackaging(
                container: .fragmentedMP4,
                sampleEntry: .avc1,
                manifestCodecs: ["avc1.42c01e"],
                actualVideoCodec: expectedVideoCodec,
                codecVerification: .verified,
                contentProtection: .none
            ),
            route: .hybridCarrierMetal,
            reason: .hybridHLSManifestSegmentMismatch
        )
        return Fixture(
            preflight: AetherHLSPlaybackPreflight(
                result: result,
                resourceGraph: graph,
                httpHeaders: [:]
            ),
            audioInitURL: audioInitURL,
            audioSegmentURL: audioSegmentURL,
            audioInitData: audio.initData,
            audioSegmentData: audio.mediaData
        )
    }

    private func makeAudioFMP4(
        seconds: Double
    ) throws -> (initData: Data, mediaData: Data) {
        let sourceDemuxer = Demuxer()
        try sourceDemuxer.open(
            reader: DataIOReader(
                data: makeWAV(
                    sampleRate: 48_000,
                    channels: 2,
                    seconds: seconds
                )
            )
        )
        defer { sourceDemuxer.close() }
        let sourceAudioIndex =
            sourceDemuxer.audioStreamIndex
        let sourceStream = try XCTUnwrap(
            sourceDemuxer.stream(
                at: sourceAudioIndex
            )
        )
        let bridge = try AudioBridge(
            srcCodecpar: sourceStream.pointee.codecpar,
            srcTimeBase: sourceStream.pointee.time_base,
            mode: .surroundCompat
        )
        defer { bridge.close() }
        let encoderCodecParameters = try XCTUnwrap(
            bridge.encoderCodecpar
        )
        let outputDirectory =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "AetherHLSVODSegmentDemux-\(UUID().uuidString)",
                    isDirectory: true
                )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(
                at: outputDirectory
            )
        }
        var initData: Data?
        let muxer = try MP4SegmentMuxer(
            initialSegmentIndex: 0,
            sessionDir: outputDirectory,
            audioOnly: MP4SegmentMuxer.AudioConfig(
                codecpar:
                    UnsafePointer(
                        encoderCodecParameters
                    ),
                timeBase: bridge.encoderTimeBase
            ),
            onInitCaptured: {
                initData = $0
            }
        )
        var encodedPackets:
            [UnsafeMutablePointer<AVPacket>] = []
        while let sourcePacket =
                try sourceDemuxer.readPacket() {
            var sourcePacketToFree:
                UnsafeMutablePointer<AVPacket>? =
                    sourcePacket
            defer {
                trackedPacketFree(
                    &sourcePacketToFree
                )
            }
            guard sourcePacket.pointee.stream_index
                == sourceAudioIndex else {
                continue
            }
            encodedPackets.append(
                contentsOf:
                    try bridge.feed(
                        packet: sourcePacket
                    )
            )
        }
        encodedPackets.append(
            contentsOf: bridge.flush()
        )
        for packet in encodedPackets {
            var packetToFree:
                UnsafeMutablePointer<AVPacket>? =
                    packet
            defer {
                trackedPacketFree(&packetToFree)
            }
            packet.pointee.stream_index =
                muxer.audioOutputStreamIndex
            av_packet_rescale_ts(
                packet,
                bridge.encoderTimeBase,
                muxer.muxerAudioTimeBase
            )
            XCTAssertGreaterThanOrEqual(
                muxer.writePacket(packet),
                0
            )
        }
        let finalized = try XCTUnwrap(
            muxer.finalize()
        )
        return (
            try XCTUnwrap(initData),
            try Data(contentsOf: finalized.path)
        )
    }

    private func makeWAV(
        sampleRate: Int,
        channels: Int,
        seconds: Double
    ) -> Data {
        let frames = Int(
            Double(sampleRate) * seconds
        )
        var pcm = Data(
            capacity: frames * channels * 2
        )
        for frame in 0..<frames {
            let value = Int16(
                9_000
                    * sin(
                        2 * .pi * 440
                            * Double(frame)
                            / Double(sampleRate)
                    )
            )
            for _ in 0..<channels {
                withUnsafeBytes(
                    of: value.littleEndian
                ) {
                    pcm.append(contentsOf: $0)
                }
            }
        }
        var data = Data()
        func appendString(_ value: String) {
            data.append(
                value.data(using: .ascii)!
            )
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
        appendUInt32(
            UInt32(sampleRate * channels * 2)
        )
        appendUInt16(UInt16(channels * 2))
        appendUInt16(16)
        appendString("data")
        appendUInt32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
