import Foundation
import XCTest
import Libavcodec
import Libavutil
@testable import AetherEngine

final class HDR10PlusMetadataSerializerTests: XCTestCase {
    func testPacketSideDataBecomesCompleteAppleT35Payload() throws {
        var rawPacket: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&rawPacket) }
        let packet = try XCTUnwrap(rawPacket)
        let record = try XCTUnwrap(
            av_packet_new_side_data(
                packet,
                AV_PKT_DATA_DYNAMIC_HDR10_PLUS,
                MemoryLayout<AVDynamicHDRPlus>.size
            )
        )
        try populate(record)

        let serialized = try XCTUnwrap(
            HDR10PlusMetadataSerializer.fromPacket(packet)
        )

        XCTAssertEqual(serialized, Self.validT35Payload)
        XCTAssertEqual(serialized.first, 0xB5)
    }

    func testFrameSideDataUsesTheSameCompletePayload() throws {
        var rawFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&rawFrame) }
        let frame = try XCTUnwrap(rawFrame)
        let sideData = try XCTUnwrap(
            av_frame_new_side_data(
                frame,
                AV_FRAME_DATA_DYNAMIC_HDR_PLUS,
                MemoryLayout<AVDynamicHDRPlus>.size
            )
        )
        let record = try XCTUnwrap(sideData.pointee.data)
        try populate(record)

        XCTAssertEqual(
            try HDR10PlusMetadataSerializer.fromFrame(frame),
            Self.validT35Payload
        )
    }

    func testMalformedPacketSideDataFailsExplicitly() throws {
        var rawPacket: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        defer { av_packet_free(&rawPacket) }
        let packet = try XCTUnwrap(rawPacket)
        XCTAssertNotNil(
            av_packet_new_side_data(
                packet,
                AV_PKT_DATA_DYNAMIC_HDR10_PLUS,
                1
            )
        )

        XCTAssertThrowsError(
            try HDR10PlusMetadataSerializer.fromPacket(packet)
        ) { error in
            XCTAssertEqual(
                error as? HDR10PlusMetadataSerializationError,
                .sideDataTooSmall
            )
        }
    }

    private func populate(
        _ storage: UnsafeMutablePointer<UInt8>
    ) throws {
        let result = Self.validT35Payload.dropFirst(6)
            .withContiguousStorageIfAvailable { bytes in
                storage.withMemoryRebound(
                    to: AVDynamicHDRPlus.self,
                    capacity: 1
                ) { record in
                    av_dynamic_hdr_plus_from_t35(
                        record,
                        bytes.baseAddress,
                        bytes.count
                    )
                }
            }
        XCTAssertEqual(result, 0)
    }

    private static let validT35Payload = Data([
        0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04,
        0x01, 0x40, 0x00, 0x1F, 0x40, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ])
}
