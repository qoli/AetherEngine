import Testing
@testable import AetherEngine

@Suite("Positive FFmpeg source-container classification")
struct SourceContainerClassificationTests {
    @Test("FLV is an explicit Native-remux-capable container")
    func flashVideo() {
        #expect(
            Demuxer.sourceContainer(formatName: "flv")
                == .flashVideo
        )
        #expect(AetherSourceContainer.flashVideo
            .supportsNativeHLSFMP4Remux)
    }

    @Test("unknown formats remain closed instead of inheriting FLV support")
    func unknownFormat() {
        #expect(
            Demuxer.sourceContainer(formatName: "mystery")
                == .other
        )
        #expect(!AetherSourceContainer.other
            .supportsNativeHLSFMP4Remux)
    }
}
