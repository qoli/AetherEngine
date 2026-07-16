import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Testing
@testable import AetherEngine

@Suite("Black carrier video fMP4 muxer", .serialized)
struct BlackCarrierVideoMuxerTests {
    private struct PacketTiming: Equatable {
        let pts: Int64
        let dts: Int64
        let duration: Int64
        let size: Int32
        let isKeyframe: Bool
    }

    @Test("File VOD produces deterministic avc1 init and exact segment timelines")
    func exactFileVODTimeline() throws {
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(seconds: 9.25, preferredTimescale: 90_000)
        )
        let packetBalanceBefore = PacketBalanceTracker.alive

        let first = try BlackCarrierVideoMuxer.build(timeline: timeline)
        let second = try BlackCarrierVideoMuxer.build(timeline: timeline)

        #expect(first == second)
        #expect(first.codecString == BlackCarrierProfile.approved.codecString)
        #expect(first.duration == timeline.duration)
        #expect(first.segments.count == 3)
        #expect(BMFFVideoSampleEntryInspector.inspect(initSegment: first.initSegment) == .avc1)
        #expect(topLevelBoxTypes(first.initSegment) == ["ftyp", "moov"])

        for (output, expected) in zip(first.segments, timeline.segments) {
            #expect(output.index == expected.index)
            #expect(output.startTime == expected.startTime)
            #expect(output.duration == expected.duration)
            #expect(topLevelBoxTypes(output.data) == ["moof", "mdat"])

            let contract = try demuxedContract(
                initSegment: first.initSegment,
                mediaSegment: output.data
            )
            #expect(contract.timeBase.num == 1)
            #expect(contract.timeBase.den == BlackCarrierProfile.approved.timescale)
            #expect(contract.codecID == AV_CODEC_ID_H264)
            #expect(contract.profile == AV_PROFILE_H264_CONSTRAINED_BASELINE)
            #expect(contract.level == 30)
            #expect(contract.width == Int32(BlackCarrierProfile.approved.width))
            #expect(contract.height == Int32(BlackCarrierProfile.approved.height))
            #expect(contract.colorPrimaries == AVCOL_PRI_BT709)
            #expect(contract.colorTransfer == AVCOL_TRC_BT709)
            #expect(contract.colorSpace == AVCOL_SPC_BT709)
            #expect(contract.colorRange == AVCOL_RANGE_MPEG)

            let expectedPackets = expected.samples.map {
                PacketTiming(
                    pts: $0.presentationTime.value,
                    dts: $0.presentationTime.value,
                    duration: $0.duration.value,
                    size: 718,
                    isKeyframe: true
                )
            }
            #expect(contract.packets == expectedPackets)
        }

        #expect(PacketBalanceTracker.alive == packetBalanceBefore)
    }

    private func demuxedContract(
        initSegment: Data,
        mediaSegment: Data
    ) throws -> (
        timeBase: AVRational,
        codecID: AVCodecID,
        profile: Int32,
        level: Int32,
        width: Int32,
        height: Int32,
        colorPrimaries: AVColorPrimaries,
        colorTransfer: AVColorTransferCharacteristic,
        colorSpace: AVColorSpace,
        colorRange: AVColorRange,
        packets: [PacketTiming]
    ) {
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: initSegment + mediaSegment))
        defer { demuxer.close() }

        let videoIndex = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: videoIndex))
        let codecParameters = try #require(stream.pointee.codecpar)
        var packets: [PacketTiming] = []

        while let packet = try demuxer.readPacket() {
            var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&packetToFree) }
            guard packet.pointee.stream_index == videoIndex else { continue }
            packets.append(
                PacketTiming(
                    pts: packet.pointee.pts,
                    dts: packet.pointee.dts,
                    duration: packet.pointee.duration,
                    size: packet.pointee.size,
                    isKeyframe: (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
                )
            )
        }

        return (
            timeBase: stream.pointee.time_base,
            codecID: codecParameters.pointee.codec_id,
            profile: codecParameters.pointee.profile,
            level: codecParameters.pointee.level,
            width: codecParameters.pointee.width,
            height: codecParameters.pointee.height,
            colorPrimaries: codecParameters.pointee.color_primaries,
            colorTransfer: codecParameters.pointee.color_trc,
            colorSpace: codecParameters.pointee.color_space,
            colorRange: codecParameters.pointee.color_range,
            packets: packets
        )
    }

    private func topLevelBoxTypes(_ data: Data) -> [String] {
        var types: [String] = []
        var offset = 0
        while offset + 8 <= data.count {
            let size = Int(readUInt32(data, at: offset))
            guard size >= 8, offset + size <= data.count else { break }
            types.append(
                String(bytes: data[(offset + 4)..<(offset + 8)], encoding: .ascii) ?? "????"
            )
            offset += size
        }
        return types
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }
}
