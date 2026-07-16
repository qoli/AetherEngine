import XCTest
@testable import AetherEngine

final class HLSPlaylistTests: XCTestCase {

    func testParsesMasterAndPicksHighestBandwidth() throws {
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1280000,RESOLUTION=640x360
        low/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=5120000,RESOLUTION=1920x1080
        high/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2560000,RESOLUTION=1280x720
        mid/index.m3u8
        """
        guard case .master(let master) = try HLSPlaylistParser.parse(text) else {
            return XCTFail("expected master playlist")
        }
        let variants = master.variants
        XCTAssertEqual(variants.count, 3)
        XCTAssertEqual(variants.max(by: { $0.bandwidth < $1.bandwidth })?.uri, "high/index.m3u8")
    }

    func testBandwidthAttributeIgnoresAverageBandwidth() throws {
        // AVERAGE-BANDWIDTH precedes BANDWIDTH on typical STREAM-INF
        // lines; an unanchored substring match used to return the
        // AVERAGE value and could rank variants wrongly.
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=9000000,BANDWIDTH=1280000,RESOLUTION=640x360
        low/index.m3u8
        #EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=4500000,BANDWIDTH=6000000,RESOLUTION=1920x1080
        high/index.m3u8
        """
        guard case .master(let master) = try HLSPlaylistParser.parse(text) else {
            return XCTFail("expected master playlist")
        }
        let variants = master.variants
        XCTAssertEqual(variants[0].bandwidth, 1_280_000)
        XCTAssertEqual(variants[1].bandwidth, 6_000_000)
        XCTAssertEqual(variants.max(by: { $0.bandwidth < $1.bandwidth })?.uri, "high/index.m3u8")
    }

    func testBandwidthAttributeIgnoresQuotedContent() throws {
        // A comma+KEY sequence INSIDE a quoted value is content, not an
        // attribute boundary; the parser must skip it.
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:CODECS="avc1.64001f,BANDWIDTH=99",BANDWIDTH=100,RESOLUTION=640x360
        low/index.m3u8
        """
        guard case .master(let master) = try HLSPlaylistParser.parse(text) else {
            return XCTFail("expected master playlist")
        }
        let variants = master.variants
        XCTAssertEqual(variants[0].bandwidth, 100)
    }

    func testMasterRejectsMissingOrInvalidBandwidth() {
        for text in [
            """
            #EXTM3U
            #EXT-X-STREAM-INF:CODECS="avc1.42C01E"
            media.m3u8
            """,
            """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=0
            media.m3u8
            """,
        ] {
            XCTAssertThrowsError(try HLSPlaylistParser.parse(text))
        }
    }

    func testParsesVariantCodecAndHDRAttributes() throws {
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=6000000,CODECS="hvc1.2.4.L150,ec-3",SUPPLEMENTAL-CODECS="dvh1.08.06",VIDEO-RANGE=PQ
        high/index.m3u8
        """
        guard case .master(let master) = try HLSPlaylistParser.parse(text) else {
            return XCTFail("expected master playlist")
        }
        XCTAssertEqual(master.variants[0].codecs, ["hvc1.2.4.l150", "ec-3"])
        XCTAssertEqual(master.variants[0].supplementalCodecs, ["dvh1.08.06"])
        XCTAssertEqual(master.variants[0].videoRange, "PQ")
    }

    func testDetectsDemuxedAudioGroups() throws {
        // ARD-style (Das Erste HD): demuxed audio playlist; ingesting without it yields silent video.
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="Deutsch",DEFAULT=YES,URI="audio/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=8500800,RESOLUTION=1920x1080,AUDIO="aac"
        video/high.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720,AUDIO="aac"
        video/mid.m3u8
        """
        guard case .master(let master) = try HLSPlaylistParser.parse(text) else {
            return XCTFail("expected master playlist")
        }
        XCTAssertEqual(master.demuxedAudioGroupIDs, ["aac"])
        XCTAssertEqual(master.variants[0].audioGroupID, "aac")
    }

    func testExtractsAudioRenditions() throws {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="Klare Sprache",LANGUAGE="de",DEFAULT=NO,AUTOSELECT=YES,CHANNELS="2",URI="audio/ks/index.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="Deutsch",LANGUAGE="de-DE",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="6",URI="audio/de/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=8500800,RESOLUTION=1920x1080,AUDIO="aac"
        video/high.m3u8
        """
        guard case .master(let master) = try HLSPlaylistParser.parse(text) else {
            return XCTFail("expected master playlist")
        }
        XCTAssertEqual(master.audioRenditions.count, 2)
        XCTAssertEqual(master.audioRenditions[0].groupID, "aac")
        XCTAssertEqual(master.audioRenditions[0].uri, "audio/ks/index.m3u8")
        XCTAssertEqual(master.audioRenditions[0].name, "Klare Sprache")
        XCTAssertEqual(master.audioRenditions[0].language, "de")
        XCTAssertFalse(master.audioRenditions[0].isDefault)
        XCTAssertTrue(master.audioRenditions[0].isAutoselect)
        XCTAssertEqual(master.audioRenditions[0].channels, "2")
        XCTAssertEqual(master.audioRenditions[1].uri, "audio/de/index.m3u8")
        XCTAssertEqual(master.audioRenditions[1].name, "Deutsch")
        XCTAssertEqual(master.audioRenditions[1].language, "de-DE")
        XCTAssertTrue(master.audioRenditions[1].isDefault)
        XCTAssertTrue(master.audioRenditions[1].isAutoselect)
        XCTAssertEqual(master.audioRenditions[1].channels, "6")
        let group = master.audioRenditions.filter { $0.groupID == "aac" }
        XCTAssertEqual(
            (group.first(where: { $0.isDefault }) ?? group.first)?.uri,
            "audio/de/index.m3u8"
        )
    }

    func testAudioRenditionWithoutDefaultFallsBackToFirst() throws {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="Deutsch",URI="audio/de/index.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="English",URI="audio/en/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,AUDIO="aac"
        video/mid.m3u8
        """
        guard case .master(let master) = try HLSPlaylistParser.parse(text) else {
            return XCTFail("expected master playlist")
        }
        XCTAssertEqual(master.audioRenditions.map(\.isDefault), [false, false])
        let group = master.audioRenditions.filter { $0.groupID == "aac" }
        XCTAssertEqual(
            (group.first(where: { $0.isDefault }) ?? group.first)?.uri,
            "audio/de/index.m3u8"
        )
        XCTAssertEqual(master.demuxedAudioGroupIDs, ["aac"])
    }

    func testInBandAudioRenditionIsNotDemuxed() throws {
        // EXT-X-MEDIA without URI = audio muxed into the variant; must not trip the demuxed-audio gate.
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="Deutsch",DEFAULT=YES
        #EXT-X-STREAM-INF:BANDWIDTH=3493377,AUDIO="aac"
        chunks.m3u8
        """
        guard case .master(let master) = try HLSPlaylistParser.parse(text) else {
            return XCTFail("expected master playlist")
        }
        XCTAssertTrue(master.demuxedAudioGroupIDs.isEmpty)
        XCTAssertTrue(master.audioRenditions.isEmpty)
        XCTAssertEqual(master.variants[0].audioGroupID, "aac")
    }

    func testParsesMediaPlaylist() throws {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:147
        #EXTINF:6.000,
        seg147.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:5.760,
        seg148.ts
        """
        guard case .media(let media) = try HLSPlaylistParser.parse(text) else {
            return XCTFail("expected media playlist")
        }
        XCTAssertEqual(media.targetDuration, 6.0)
        XCTAssertEqual(media.mediaSequence, 147)
        XCTAssertEqual(media.segments.count, 2)
        XCTAssertEqual(media.segments[0].uri, "seg147.ts")
        XCTAssertFalse(media.segments[0].discontinuityBefore)
        XCTAssertTrue(media.segments[1].discontinuityBefore)
        XCTAssertFalse(media.hasEndList)
        XCTAssertFalse(media.isEncrypted)
        XCTAssertFalse(media.hasMap)
        XCTAssertFalse(media.hasByteRange)
    }

    func testMediaPlaylistRejectsSegmentWithoutEXTINF() {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        seg0.ts
        """
        XCTAssertThrowsError(try HLSPlaylistParser.parse(text))
    }

    func testDetectsByteRangeResources() throws {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-MAP:URI="init.mp4",BYTERANGE="720@0"
        #EXTINF:4,
        #EXT-X-BYTERANGE:4096@720
        media.mp4
        #EXT-X-ENDLIST
        """
        guard case .media(let media) = try HLSPlaylistParser.parse(text) else {
            return XCTFail("expected media playlist")
        }
        XCTAssertTrue(media.hasByteRange)
    }

    func testDetectsEncryptionAndMapAndEndlist() throws {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4.0,
        seg0.m4s
        #EXT-X-ENDLIST
        """
        guard case .media(let media) = try HLSPlaylistParser.parse(text) else {
            return XCTFail("expected media playlist")
        }
        XCTAssertTrue(media.isEncrypted)
        XCTAssertTrue(media.hasMap)
        XCTAssertEqual(media.mapURI, "init.mp4")
        XCTAssertEqual(media.contentProtection, .aes128)
        XCTAssertTrue(media.hasEndList)
    }

    func testDetectsSampleAESAndFairPlayProtection() throws {
        let sampleAES = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="key.bin"
        #EXTINF:4.0,
        seg0.ts
        """
        guard case .media(let sampleMedia) = try HLSPlaylistParser.parse(sampleAES) else {
            return XCTFail("expected media playlist")
        }
        XCTAssertEqual(sampleMedia.contentProtection, .sampleAES)

        let fairPlay = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-KEY:METHOD=SAMPLE-AES,KEYFORMAT="com.apple.streamingkeydelivery",URI="skd://license"
        #EXTINF:4.0,
        seg0.ts
        """
        guard case .media(let fairPlayMedia) = try HLSPlaylistParser.parse(fairPlay) else {
            return XCTFail("expected media playlist")
        }
        XCTAssertEqual(fairPlayMedia.contentProtection, .fairPlay)
    }

    func testKeyMethodNoneIsNotEncrypted() throws {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-KEY:METHOD=NONE
        #EXTINF:4.0,
        seg0.ts
        """
        guard case .media(let media) = try HLSPlaylistParser.parse(text) else {
            return XCTFail("expected media playlist")
        }
        XCTAssertFalse(media.isEncrypted)
    }

    func testRejectsNonPlaylist() {
        XCTAssertThrowsError(try HLSPlaylistParser.parse("<!DOCTYPE html><html></html>")) { error in
            guard case HLSIngestError.playlistInvalid = error else {
                return XCTFail("expected playlistInvalid, got \(error)")
            }
        }
    }

    func testRejectsMediaPlaylistWithoutSegments() {
        XCTAssertThrowsError(try HLSPlaylistParser.parse("#EXTM3U\n#EXT-X-TARGETDURATION:6\n"))
    }

    func testResolvesRelativeAndAbsoluteURIs() {
        let base = URL(string: "https://cdn.example.com/live/ch1/index.m3u8")!
        XCTAssertEqual(
            HLSPlaylistParser.resolve(uri: "seg1.ts", against: base)?.absoluteString,
            "https://cdn.example.com/live/ch1/seg1.ts"
        )
        XCTAssertEqual(
            HLSPlaylistParser.resolve(uri: "/abs/seg1.ts", against: base)?.absoluteString,
            "https://cdn.example.com/abs/seg1.ts"
        )
        XCTAssertEqual(
            HLSPlaylistParser.resolve(uri: "https://other.example.com/s.ts", against: base)?.absoluteString,
            "https://other.example.com/s.ts"
        )
    }
}
