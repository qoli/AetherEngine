import Foundation
import Testing
@testable import AetherEngine

private final class AlternateAudioMockProvider: HLSSegmentProvider, @unchecked Sendable {
    func initSegment() -> Data? { Data([0x00]) }
    func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
    var segmentCount: Int { 3 }
    func segmentDuration(at index: Int) -> Double {
        [4.0, 4.0, 1.25][index]
    }
    var playlistType: HLSPlaylistType { .vod }
    var masterCodecs: String? { "avc1.42C01E,mp4a.40.2,ec-3" }
    var masterResolution: (width: Int, height: Int)? { (640, 360) }
    var masterVideoRange: HLSVideoRange? { .sdr }
    var masterBandwidth: Int? { 1_500_000 }
    var masterAverageBandwidth: Int? { 900_000 }
    var alternateAudioRenditions: [HLSAudioRenditionInfo] {
        [
            HLSAudioRenditionInfo(
                ordinal: 0,
                language: "eng",
                name: "English",
                isDefault: true,
                isAutoselect: true,
                channels: "2"
            ),
            HLSAudioRenditionInfo(
                ordinal: 1,
                language: "jpn",
                name: "日本語",
                isDefault: false,
                isAutoselect: true,
                channels: "6"
            ),
        ]
    }
    func alternateAudioInitSegment(ordinal: Int) -> Data? {
        Data([UInt8(ordinal)])
    }
    func alternateAudioMediaSegment(ordinal: Int, index: Int) -> Data? {
        Data([UInt8(ordinal), UInt8(index)])
    }
}

@Suite("Alternate-audio HLS rendition contract")
struct AlternateAudioRenditionPlaylistTests {
    @Test("Master exposes every audio track through one native selection group")
    func masterPlaylist() throws {
        let provider = AlternateAudioMockProvider()
        let master = HLSLocalServer.buildMasterPlaylistText(provider: provider)

        #expect(master.contains(
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"English\",LANGUAGE=\"eng\",DEFAULT=YES,AUTOSELECT=YES,CHANNELS=\"2\",URI=\"audio_0.m3u8\""
        ))
        #expect(master.contains(
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"日本語\",LANGUAGE=\"jpn\",DEFAULT=NO,AUTOSELECT=YES,CHANNELS=\"6\",URI=\"audio_1.m3u8\""
        ))
        #expect(master.contains("AUDIO=\"audio\""))
        #expect(master.contains("CODECS=\"avc1.42C01E,mp4a.40.2,ec-3\""))

        guard case .master(let parsed) = try HLSPlaylistParser.parse(master) else {
            Issue.record("Expected master playlist")
            return
        }
        #expect(parsed.audioRenditions.count == 2)
        #expect(parsed.audioRenditions.map(\.uri) == ["audio_0.m3u8", "audio_1.m3u8"])
        #expect(parsed.audioRenditions.map(\.isDefault) == [true, false])
        #expect(parsed.variants[0].audioGroupID == "audio")
    }

    @Test("Audio media playlist mirrors the exact carrier segment timeline")
    func mediaPlaylist() throws {
        let provider = AlternateAudioMockProvider()
        let playlist = try #require(
            HLSLocalServer.buildAlternateAudioMediaPlaylistText(
                ordinal: 1,
                provider: provider
            )
        )

        #expect(playlist.contains("#EXT-X-TARGETDURATION:4"))
        #expect(playlist.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        #expect(playlist.contains("#EXT-X-MAP:URI=\"audio_1_init.mp4\""))
        #expect(playlist.contains("#EXTINF:4.000,\naudio_1_seg_0.mp4"))
        #expect(playlist.contains("#EXTINF:4.000,\naudio_1_seg_1.mp4"))
        #expect(playlist.contains("#EXTINF:1.250,\naudio_1_seg_2.mp4"))
        #expect(playlist.hasSuffix("#EXT-X-ENDLIST\n"))

        guard case .media(let parsed) = try HLSPlaylistParser.parse(playlist) else {
            Issue.record("Expected media playlist")
            return
        }
        #expect(parsed.mapURI == "audio_1_init.mp4")
        #expect(parsed.segments.map(\.duration) == [4, 4, 1.25])
        #expect(parsed.segments.map(\.uri) == [
            "audio_1_seg_0.mp4",
            "audio_1_seg_1.mp4",
            "audio_1_seg_2.mp4",
        ])
    }

    @Test("Unknown rendition is unavailable rather than mapped to another track")
    func unknownRendition() {
        #expect(HLSLocalServer.buildAlternateAudioMediaPlaylistText(
            ordinal: 9,
            provider: AlternateAudioMockProvider()
        ) == nil)
    }

    @Test("Audio endpoint parser rejects malformed and negative identifiers")
    func endpointParser() {
        #expect(HLSLocalServer.parseAudioResourcePath("/audio_2.m3u8") == .playlist(ordinal: 2))
        #expect(HLSLocalServer.parseAudioResourcePath("/audio_2_init.mp4") == .initSegment(ordinal: 2))
        #expect(HLSLocalServer.parseAudioResourcePath("/audio_2_seg_17.mp4") == .mediaSegment(
            ordinal: 2,
            index: 17
        ))
        #expect(HLSLocalServer.parseAudioResourcePath("/audio_-1.m3u8") == nil)
        #expect(HLSLocalServer.parseAudioResourcePath("/audio_2_seg_-1.mp4") == nil)
        #expect(HLSLocalServer.parseAudioResourcePath("/audio_x_init.mp4") == nil)
        #expect(HLSLocalServer.parseAudioResourcePath("/audio_2.mp4") == nil)
    }
}
