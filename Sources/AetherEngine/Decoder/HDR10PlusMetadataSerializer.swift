import Foundation
import Libavcodec
import Libavutil

enum HDR10PlusMetadataSerializationError: Error, Equatable {
    case sideDataTooSmall
    case serializationFailed(code: Int32)
    case emptyPayload
}

/// Converts FFmpeg's structured ST 2094-40 side data into the exact byte
/// contract required by `kCMSampleAttachmentKey_HDR10PlusPerFrameData`.
/// Apple requires a complete User Data Registered ITU-T T.35 payload starting
/// with country code 0xB5; FFmpeg's serializer intentionally omits that
/// six-byte HDR10+ registration prefix.
enum HDR10PlusMetadataSerializer {
    private static let registrationPrefix = Data([
        0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04,
    ])

    static func fromPacket(
        _ packet: UnsafeMutablePointer<AVPacket>
    ) throws -> Data? {
        var sideDataSize = 0
        guard let sideData = av_packet_get_side_data(
            packet,
            AV_PKT_DATA_DYNAMIC_HDR10_PLUS,
            &sideDataSize
        ) else {
            return nil
        }
        guard sideDataSize >= MemoryLayout<AVDynamicHDRPlus>.size else {
            throw HDR10PlusMetadataSerializationError.sideDataTooSmall
        }
        return try sideData.withMemoryRebound(
            to: AVDynamicHDRPlus.self,
            capacity: 1
        ) { record in
            try serialize(record)
        }
    }

    static func fromFrame(
        _ frame: UnsafeMutablePointer<AVFrame>
    ) throws -> Data? {
        let count = Int(frame.pointee.nb_side_data)
        guard count > 0,
              let sideData = frame.pointee.side_data else {
            return nil
        }
        for index in 0..<count {
            guard let entry = sideData[index],
                  entry.pointee.type
                    == AV_FRAME_DATA_DYNAMIC_HDR_PLUS else {
                continue
            }
            guard let raw = entry.pointee.data,
                  entry.pointee.size
                    >= MemoryLayout<AVDynamicHDRPlus>.size else {
                throw HDR10PlusMetadataSerializationError
                    .sideDataTooSmall
            }
            return try raw.withMemoryRebound(
                to: AVDynamicHDRPlus.self,
                capacity: 1
            ) { record in
                try serialize(record)
            }
        }
        return nil
    }

    private static func serialize(
        _ record: UnsafePointer<AVDynamicHDRPlus>
    ) throws -> Data {
        var bytes: UnsafeMutablePointer<UInt8>?
        var size = 0
        let result = av_dynamic_hdr_plus_to_t35(
            record,
            &bytes,
            &size
        )
        guard result >= 0 else {
            throw HDR10PlusMetadataSerializationError
                .serializationFailed(code: result)
        }
        guard let bytes, size > 0 else {
            throw HDR10PlusMetadataSerializationError.emptyPayload
        }
        defer { av_free(bytes) }
        return registrationPrefix + Data(bytes: bytes, count: size)
    }
}
