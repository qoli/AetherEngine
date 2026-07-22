import Testing
import Libavcodec
@testable import AetherEngine

@Suite("VideoRoutingPolicy (#107 interlaced H.264 deinterlace routing)")
struct VideoRoutingPolicyTests {
    @Test("interlaced H.264 routes to software for deinterlace")
    func interlacedH264Software() {
        for order in [AV_FIELD_TT, AV_FIELD_BB, AV_FIELD_TB, AV_FIELD_BT] {
            #expect(VideoRoutingPolicy.requiresSoftwarePath(
                codecID: AV_CODEC_ID_H264, fieldOrder: order, av1Available: true))
        }
    }

    @Test("progressive / unknown H.264 stays native")
    func progressiveH264Native() {
        #expect(!VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_H264, fieldOrder: AV_FIELD_PROGRESSIVE, av1Available: true))
        #expect(!VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_H264, fieldOrder: AV_FIELD_UNKNOWN, av1Available: true))
    }

    @Test("field order maps to explicit unified scan evidence")
    func fieldOrderScanEvidence() {
        #expect(VideoRoutingPolicy.scanType(
            fieldOrder: AV_FIELD_BT) == .interlaced)
        #expect(VideoRoutingPolicy.scanType(
            fieldOrder: AV_FIELD_PROGRESSIVE) == .progressive)
        #expect(VideoRoutingPolicy.scanType(
            fieldOrder: AV_FIELD_UNKNOWN) == .unknown)
    }

    @Test("low-level interlaced HEVC stays native; unified routing is stricter")
    func interlacedHEVCNative() {
        #expect(!VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_HEVC, fieldOrder: AV_FIELD_TT, av1Available: true))
    }

    @Test("MPEG-2 / VC-1 always software regardless of field order")
    func mpeg2AlwaysSoftware() {
        #expect(VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_MPEG2VIDEO, fieldOrder: AV_FIELD_PROGRESSIVE, av1Available: true))
        #expect(VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_VC1, fieldOrder: AV_FIELD_UNKNOWN, av1Available: true))
    }

    @Test("AV1 follows hardware availability")
    func av1FollowsHardware() {
        #expect(VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_AV1, fieldOrder: AV_FIELD_PROGRESSIVE, av1Available: false))
        #expect(!VideoRoutingPolicy.requiresSoftwarePath(
            codecID: AV_CODEC_ID_AV1, fieldOrder: AV_FIELD_PROGRESSIVE, av1Available: true))
    }
}
