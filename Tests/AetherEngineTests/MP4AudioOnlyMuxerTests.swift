import Foundation
import Libavcodec
import Libavformat
import Testing
@testable import AetherEngine

@Suite("MP4SegmentMuxer audio-only mode", .serialized)
struct MP4AudioOnlyMuxerTests {
    @Test("Bridged EAC3 produces an audio-only fMP4 init and media fragment")
    func bridgedEAC3() throws {
        let sourceData = makeWAV(sampleRate: 48_000, channels: 2, seconds: 2)
        let sourceDemuxer = Demuxer()
        try sourceDemuxer.open(reader: DataIOReader(data: sourceData))
        defer { sourceDemuxer.close() }

        let sourceAudioIndex = sourceDemuxer.audioStreamIndex
        let sourceStream = try #require(sourceDemuxer.stream(at: sourceAudioIndex))
        let bridge = try AudioBridge(
            srcCodecpar: sourceStream.pointee.codecpar,
            srcTimeBase: sourceStream.pointee.time_base,
            mode: .surroundCompat
        )
        defer { bridge.close() }
        let encoderCodecParameters = try #require(bridge.encoderCodecpar)
        let audioConfig = MP4SegmentMuxer.AudioConfig(
            codecpar: UnsafePointer(encoderCodecParameters),
            timeBase: bridge.encoderTimeBase
        )
        #expect(MP4SegmentMuxer.probeAudioWriteHeader(audio: audioConfig) == 0)

        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AetherAudioOnlyMuxer-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        var initSegment: Data?
        let muxer = try MP4SegmentMuxer(
            initialSegmentIndex: 0,
            sessionDir: outputDirectory,
            audioOnly: audioConfig,
            onInitCaptured: { initSegment = $0 }
        )
        #expect(muxer.videoOutputStreamIndex == -1)
        #expect(muxer.audioOutputStreamIndex == 0)

        var encodedPackets: [UnsafeMutablePointer<AVPacket>] = []
        while let sourcePacket = try sourceDemuxer.readPacket() {
            var sourcePacketToFree: UnsafeMutablePointer<AVPacket>? = sourcePacket
            defer { trackedPacketFree(&sourcePacketToFree) }
            guard sourcePacket.pointee.stream_index == sourceAudioIndex else { continue }
            encodedPackets.append(contentsOf: try bridge.feed(packet: sourcePacket))
        }
        encodedPackets.append(contentsOf: bridge.flush())
        #expect(!encodedPackets.isEmpty)

        for encodedPacket in encodedPackets {
            var encodedPacketToFree: UnsafeMutablePointer<AVPacket>? = encodedPacket
            defer { trackedPacketFree(&encodedPacketToFree) }
            encodedPacket.pointee.stream_index = muxer.audioOutputStreamIndex
            av_packet_rescale_ts(
                encodedPacket,
                bridge.encoderTimeBase,
                muxer.muxerAudioTimeBase
            )
            #expect(muxer.writePacket(encodedPacket) >= 0)
        }

        let finalized = try #require(muxer.finalize())
        let initData = try #require(initSegment)
        let mediaData = try Data(contentsOf: finalized.path)
        #expect(mediaData.count == finalized.bytesWritten)

        let outputDemuxer = Demuxer()
        try outputDemuxer.open(reader: DataIOReader(data: initData + mediaData))
        defer { outputDemuxer.close() }
        #expect(outputDemuxer.videoStreamIndex == -1)
        #expect(outputDemuxer.audioStreamIndex == 0)

        let outputStream = try #require(outputDemuxer.stream(at: 0))
        let outputCodecParameters = try #require(outputStream.pointee.codecpar)
        #expect(outputCodecParameters.pointee.codec_id == AV_CODEC_ID_EAC3)
        #expect(outputStream.pointee.time_base.num == 1)
        #expect(outputStream.pointee.time_base.den == 48_000)

        var packetCount = 0
        var previousDTS: Int64?
        while let packet = try outputDemuxer.readPacket() {
            var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&packetToFree) }
            guard packet.pointee.stream_index == 0 else { continue }
            packetCount += 1
            #expect(packet.pointee.duration > 0)
            if let previousDTS {
                #expect(packet.pointee.dts > previousDTS)
            }
            previousDTS = packet.pointee.dts
        }
        #expect(packetCount > 0)
    }

    private func makeWAV(
        sampleRate: Int,
        channels: Int,
        seconds: Double
    ) -> Data {
        let frames = Int(Double(sampleRate) * seconds)
        var pcm = Data(capacity: frames * channels * 2)
        for frame in 0..<frames {
            let value = Int16(
                9_000 * sin(2 * .pi * 440 * Double(frame) / Double(sampleRate))
            )
            for _ in 0..<channels {
                withUnsafeBytes(of: value.littleEndian) {
                    pcm.append(contentsOf: $0)
                }
            }
        }

        var data = Data()
        func appendString(_ value: String) {
            data.append(value.data(using: .ascii)!)
        }
        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        func appendUInt16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) {
                data.append(contentsOf: $0)
            }
        }

        appendString("RIFF")
        appendUInt32(UInt32(36 + pcm.count))
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(UInt16(channels))
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * channels * 2))
        appendUInt16(UInt16(channels * 2))
        appendUInt16(16)
        appendString("data")
        appendUInt32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
