import CoreGraphics
import Libavcodec
import Libavformat
import Testing
@testable import AetherEngine

@Suite("Hybrid styled subtitle renderer")
@MainActor
struct HybridSubtitleRendererTests {
    private final class OverlaySource:
        HybridOverlaySubtitleSource
    {
        let hybridSubtitleContracts:
            [HybridSubtitleDecodeContract]
        let hybridSubtitlePacketStore =
            SubtitlePacketStore()
        let hybridSubtitleRuntimeAvailability =
            HybridSubtitleRuntimeAvailabilityStore()

        init(_ contract: HybridSubtitleDecodeContract) {
            hybridSubtitleContracts = [contract]
        }
    }

    private let header = """
    [Script Info]
    PlayResX: 1280
    PlayResY: 720

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,sans-serif,54,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,3,1,2,40,40,46,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    """

    @Test("libass renders styled events on the Aether-owned canvas")
    func rendersStyledEvent() throws {
        let builder = ASSScriptBuilder(header: header)
        #expect(builder.add(
            rawEventText:
                "0,0,Default,,0,0,0,,{\\i1}Aether{\\i0} subtitle",
            start: 1,
            end: 3
        ))
        let renderer = try HybridStyledSubtitleRenderer()
        try renderer.setCanvasSize(
            CGSize(width: 1_280, height: 720)
        )
        try renderer.load(script: builder.script())

        let frame = try renderer.frame(at: 2)
        #expect(frame != nil)
        #expect((frame?.frame.width ?? 0) > 0)
        #expect((frame?.frame.height ?? 0) > 0)
        #expect(frame?.image.width == Int(frame?.frame.width ?? 0))
        #expect(frame?.image.height == Int(frame?.frame.height ?? 0))
    }

    @Test("styled renderer clears outside the cue interval")
    func clearsOutsideInterval() throws {
        let builder = ASSScriptBuilder(header: header)
        builder.add(
            rawEventText: "0,0,Default,,0,0,0,,Visible",
            start: 1,
            end: 2
        )
        let renderer = try HybridStyledSubtitleRenderer()
        try renderer.setCanvasSize(
            CGSize(width: 1_280, height: 720)
        )
        try renderer.load(script: builder.script())

        #expect(try renderer.frame(at: 0.5) == nil)
        #expect(try renderer.frame(at: 2.5) == nil)
    }

    @Test("runtime track failure turns selection Off without another track")
    func runtimeFailureDisablesOnlySelectedTrack() throws {
        let format = try #require(avformat_alloc_context())
        defer { avformat_free_context(format) }
        let stream = try #require(
            avformat_new_stream(format, nil)
        )
        let codecParameters = try #require(
            stream.pointee.codecpar
        )
        codecParameters.pointee.codec_type =
            AVMEDIA_TYPE_SUBTITLE
        codecParameters.pointee.codec_id = AV_CODEC_ID_ASS
        let info = TrackInfo(
            id: 3,
            name: "Styled",
            codec: "ass",
            language: "en",
            isDefault: true,
            assHeader: header
        )
        let contract = try #require(
            HybridSubtitleDecodeContract(
                trackID: 3,
                packetStreamID: 3,
                info: info,
                stream: stream,
                sourceVideoWidth: 1_280,
                sourceVideoHeight: 720,
                assembleSplitDisplaySets: false
            )
        )
        let source = OverlaySource(contract)
        let controller = HybridSubtitleSessionController(
            source: source,
            presentationView: AetherHybridPresentationView()
        )

        try controller.select(trackID: 3)
        #expect(controller.selectedTrackID == 3)
        source.hybridSubtitleRuntimeAvailability
            .markUnavailable(
                trackID: 3,
                reason: .decodeFailed
            )
        controller.update(playheadSeconds: 0)

        #expect(controller.selectedTrackID == nil)
        #expect(controller.tracks.count == 1)
        #expect(
            controller.tracks[0].availability
                == .unavailable(.decodeFailed)
        )
        #expect(throws: AetherHybridSubtitleSelectionError.self) {
            try controller.select(trackID: 3)
        }
    }
}
