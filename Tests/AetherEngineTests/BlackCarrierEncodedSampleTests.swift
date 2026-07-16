import Foundation
import Libavcodec
import Libavformat
import Testing
@testable import AetherEngine

@Suite("Black carrier encoded sample")
struct BlackCarrierEncodedSampleTests {
    @Test("Bundled asset and manifest match the approved SHA-256")
    func approvedHash() throws {
        let data = try BlackCarrierEncodedSample.verifiedMP4Data()

        #expect(BlackCarrierEncodedSample.sha256Hex(data) == BlackCarrierEncodedSample.approvedSHA256)
        #expect(try BlackCarrierEncodedSample.bundledManifestSHA256() == BlackCarrierEncodedSample.approvedSHA256)
    }

    @Test("Bundled MP4 declares the approved avc1 sample entry")
    func approvedSampleEntry() throws {
        let data = try BlackCarrierEncodedSample.verifiedMP4Data()

        #expect(BMFFVideoSampleEntryInspector.inspect(initSegment: data) == .avc1)
    }

    @Test("Demuxed sample matches the locked carrier profile and packet timing")
    func demuxedContract() throws {
        let packetBalanceBefore = PacketBalanceTracker.alive

        do {
            let data = try BlackCarrierEncodedSample.verifiedMP4Data()
            let demuxer = Demuxer()
            try demuxer.open(reader: DataIOReader(data: data))
            defer { demuxer.close() }

            #expect(abs(demuxer.duration - 1) < 0.000_001)
            #expect(demuxer.videoStreamIndex == 0)

            let stream = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
            let codecParameters = try #require(stream.pointee.codecpar)
            #expect(codecParameters.pointee.codec_id == AV_CODEC_ID_H264)
            #expect(codecParameters.pointee.profile == AV_PROFILE_H264_CONSTRAINED_BASELINE)
            #expect(codecParameters.pointee.level == 30)
            #expect(codecParameters.pointee.width == Int32(BlackCarrierProfile.approved.width))
            #expect(codecParameters.pointee.height == Int32(BlackCarrierProfile.approved.height))
            #expect(stream.pointee.time_base.num == 1)
            #expect(stream.pointee.time_base.den == BlackCarrierProfile.approved.timescale)

            let packet = try #require(try demuxer.readPacket())
            var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&packetToFree) }

            #expect(packet.pointee.stream_index == demuxer.videoStreamIndex)
            #expect((packet.pointee.flags & AV_PKT_FLAG_KEY) != 0)
            #expect(packet.pointee.pts == 0)
            #expect(packet.pointee.dts == 0)
            #expect(packet.pointee.duration == BlackCarrierProfile.approved.frameDurationTicks)
            #expect(packet.pointee.size == 718)
            #expect(try demuxer.readPacket() == nil)
        }

        #expect(PacketBalanceTracker.alive == packetBalanceBefore)
    }

    @Test("Payload drift returns a typed hash mismatch")
    func rejectsPayloadDrift() throws {
        var data = try BlackCarrierEncodedSample.verifiedMP4Data()
        data[data.startIndex] ^= 0x01

        do {
            _ = try BlackCarrierEncodedSample.verify(data: data)
            Issue.record("Expected hash mismatch")
        } catch let error as BlackCarrierEncodedSampleError {
            guard case .hashMismatch(let expected, let actual) = error else {
                Issue.record("Unexpected typed error: \(error)")
                return
            }
            #expect(expected == BlackCarrierEncodedSample.approvedSHA256)
            #expect(actual != expected)
        }
    }
}
