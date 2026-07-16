import CoreMedia
import Foundation
import Testing
@testable import AetherEngine

@Suite("Black carrier video HLS provider", .serialized)
struct BlackCarrierVideoProviderTests {
    @Test("Disk-backed provider publishes an exact finite VOD")
    func exactVODPlaylist() throws {
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(seconds: 9.25, preferredTimescale: 90_000)
        )
        let provider = try BlackCarrierVideoProvider(timeline: timeline)
        let sessionDirectory = provider.sessionDirectory
        defer { provider.close() }

        #expect(FileManager.default.fileExists(atPath: sessionDirectory.path))
        #expect(provider.segmentCount == 3)
        #expect(provider.initSegment()?.isEmpty == false)
        for index in 0..<provider.segmentCount {
            #expect(provider.mediaSegment(at: index)?.isEmpty == false)
            #expect(provider.mediaSegmentURL(at: index) != nil)
        }
        #expect(provider.mediaSegment(at: -1) == nil)
        #expect(provider.mediaSegment(at: provider.segmentCount) == nil)

        let master = try HLSLocalServer.buildMasterPlaylistText(
            provider: provider
        )
        #expect(master.contains("#EXT-X-INDEPENDENT-SEGMENTS"))
        #expect(master.contains("BANDWIDTH=\(provider.masterBandwidth!)"))
        #expect(master.contains("AVERAGE-BANDWIDTH=\(provider.masterAverageBandwidth!)"))
        #expect(master.contains("CODECS=\"avc1.42C01E\""))
        #expect(master.contains("RESOLUTION=640x360"))
        #expect(master.contains("FRAME-RATE=1.000"))
        #expect(master.contains("VIDEO-RANGE=SDR"))
        #expect(master.contains("CLOSED-CAPTIONS=NONE"))
        #expect(master.hasSuffix("media.m3u8\n"))

        guard case .master(let parsedMaster) = try HLSPlaylistParser.parse(master) else {
            Issue.record("Expected master playlist")
            return
        }
        #expect(parsedMaster.variants.count == 1)
        #expect(parsedMaster.variants[0].bandwidth == provider.masterBandwidth)
        #expect(parsedMaster.variants[0].codecs == ["avc1.42c01e"])

        let media = HLSLocalServer.buildMediaPlaylistText(provider: provider)
        #expect(media.contains("#EXT-X-TARGETDURATION:4"))
        #expect(media.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        #expect(media.contains("#EXT-X-MAP:URI=\"init.mp4\""))
        #expect(media.contains("#EXTINF:4.000,\nseg0.mp4"))
        #expect(media.contains("#EXTINF:4.000,\nseg1.mp4"))
        #expect(media.contains("#EXTINF:1.250,\nseg2.mp4"))
        #expect(media.hasSuffix("#EXT-X-ENDLIST\n"))

        guard case .media(let parsedMedia) = try HLSPlaylistParser.parse(media) else {
            Issue.record("Expected media playlist")
            return
        }
        #expect(parsedMedia.targetDuration == 4)
        #expect(parsedMedia.mediaSequence == 0)
        #expect(parsedMedia.mapURI == "init.mp4")
        #expect(parsedMedia.segments.map(\.duration) == [4, 4, 1.25])
        #expect(parsedMedia.segments.map(\.uri) == ["seg0.mp4", "seg1.mp4", "seg2.mp4"])
        #expect(parsedMedia.hasEndList)

        provider.close()
        #expect(!FileManager.default.fileExists(atPath: sessionDirectory.path))
    }
}
