import CoreMedia
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Testing
@testable import AetherEngine

@Suite("Black carrier audio rendition pump", .serialized)
struct BlackCarrierAudioRenditionMuxerTests {
    @Test("PCM source bridges to EAC3 and follows the carrier segment timeline")
    func bridgedPCM() throws {
        let sourceData = makeWAV(
            sampleRate: 48_000,
            channels: 2,
            seconds: 5.25
        )
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: sourceData))
        defer { demuxer.close() }

        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(seconds: 5.25, preferredTimescale: 90_000)
        )
        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AetherAudioRendition-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        var initSegment: Data?
        var mediaSegments: [Data] = []
        let summary = try BlackCarrierAudioRenditionMuxer.mux(
            demuxer: demuxer,
            audioStreamIndex: demuxer.audioStreamIndex,
            sourceStartPTS: 0,
            timeline: timeline,
            bridgeMode: .surroundCompat,
            sessionDirectory: outputDirectory,
            onInit: { initSegment = $0 },
            onSegment: { _, path, bytesWritten in
                let data = try Data(contentsOf: path)
                #expect(data.count == bytesWritten)
                mediaSegments.append(data)
            }
        )

        #expect(summary.pipeline == .bridge(
            mode: .surroundCompat,
            codecString: "ec-3"
        ))
        #expect(summary.codecString == "ec-3")
        #expect(summary.peakBandwidth >= summary.averageBandwidth)
        #expect(summary.channelsAttribute == "2")
        #expect(summary.declaredCodecInitialPaddingSamples == 256)
        #expect(summary.presentationTrimSamples == 256)
        #expect(mediaSegments.count == 2)

        let initData = try #require(initSegment)
        #expect(editListEntries(initData) == [
            EditListEntry(segmentDuration: 0, mediaTime: 256)
        ])
        for (offset, mediaSegment) in mediaSegments.enumerated() {
            let expectedStart = av_rescale_q(
                timeline.segments[offset].startTime.value,
                AVRational(num: 1, den: 90_000),
                AVRational(num: 1, den: 48_000)
            )
            #expect(fragmentBaseMediaDecodeTime(mediaSegment) == UInt64(expectedStart))

            let outputDemuxer = Demuxer()
            try outputDemuxer.open(
                reader: DataIOReader(data: initData + mediaSegment)
            )
            defer { outputDemuxer.close() }

            #expect(outputDemuxer.videoStreamIndex == -1)
            #expect(outputDemuxer.audioStreamIndex == 0)
            let outputStream = try #require(outputDemuxer.stream(at: 0))
            #expect(outputStream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_EAC3)
            #expect(outputStream.pointee.time_base.num == 1)
            #expect(outputStream.pointee.time_base.den == 48_000)

            var firstPTS: Int64?
            var packetCount = 0
            while let packet = try outputDemuxer.readPacket() {
                var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
                defer { trackedPacketFree(&packetToFree) }
                guard packet.pointee.stream_index == 0 else { continue }
                firstPTS = firstPTS ?? packet.pointee.pts
                packetCount += 1
            }
            #expect(packetCount > 0)
            #expect(firstPTS == expectedStart - summary.presentationTrimSamples)
        }
    }

    @Test("EAC3 source stream-copies while preserving its presentation trim")
    func streamCopiedEAC3() throws {
        let sourceData = try makeEAC3FragmentedMP4(seconds: 5.25)
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: sourceData))
        defer { demuxer.close() }

        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(seconds: 5.25, preferredTimescale: 90_000)
        )
        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AetherAudioRenditionCopy-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        var initSegment: Data?
        var mediaSegments: [Data] = []
        let summary = try BlackCarrierAudioRenditionMuxer.mux(
            demuxer: demuxer,
            audioStreamIndex: demuxer.audioStreamIndex,
            sourceStartPTS: 0,
            timeline: timeline,
            sessionDirectory: outputDirectory,
            onInit: { initSegment = $0 },
            onSegment: { _, path, bytesWritten in
                let data = try Data(contentsOf: path)
                #expect(data.count == bytesWritten)
                mediaSegments.append(data)
            }
        )

        #expect(summary.pipeline == .streamCopy(codecString: "ec-3"))
        #expect(summary.codecString == "ec-3")
        #expect(summary.declaredCodecInitialPaddingSamples == 0)
        #expect(summary.presentationTrimSamples == 256)
        #expect(mediaSegments.count == 2)

        let initData = try #require(initSegment)
        #expect(editListEntries(initData) == [
            EditListEntry(segmentDuration: 0, mediaTime: 256)
        ])
        for (offset, mediaSegment) in mediaSegments.enumerated() {
            let expectedStart = av_rescale_q(
                timeline.segments[offset].startTime.value,
                AVRational(num: 1, den: 90_000),
                AVRational(num: 1, den: 48_000)
            )
            #expect(fragmentBaseMediaDecodeTime(mediaSegment) == UInt64(expectedStart))

            let outputDemuxer = Demuxer()
            try outputDemuxer.open(
                reader: DataIOReader(data: initData + mediaSegment)
            )
            defer { outputDemuxer.close() }

            var firstPTS: Int64?
            var packetCount = 0
            while let packet = try outputDemuxer.readPacket() {
                var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
                defer { trackedPacketFree(&packetToFree) }
                guard packet.pointee.stream_index == 0 else { continue }
                firstPTS = firstPTS ?? packet.pointee.pts
                packetCount += 1
            }
            #expect(packetCount > 0)
            #expect(firstPTS == expectedStart - summary.presentationTrimSamples)
        }
    }

    @Test("Two rendition writers consume one interleaved demux pass")
    func sharedDemuxFanout() throws {
        let sourceData = try makeDualEAC3Container(seconds: 1)
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: sourceData))
        defer { demuxer.close() }
        let tracks = demuxer.audioTrackInfos()
        #expect(tracks.map(\.id) == [0, 1])

        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(seconds: 1, preferredTimescale: 90_000)
        )
        let caches = [
            SegmentCache(forwardWindow: 1, backwardWindow: 1),
            SegmentCache(forwardWindow: 1, backwardWindow: 1),
        ]
        defer { caches.forEach { $0.close() } }

        let writers = try tracks.enumerated().map { ordinal, track in
            try BlackCarrierAudioRenditionMuxer.makeWriter(
                demuxer: demuxer,
                audioStreamIndex: Int32(track.id),
                sourceStartPTS: 0,
                timeline: timeline,
                sessionDirectory: caches[ordinal].sessionDir,
                onInit: { caches[ordinal].setInit($0) },
                onSegment: { timing, stagingPath, bytesWritten in
                    caches[ordinal].adopt(
                        index: timing.index,
                        stagingPath: stagingPath,
                        byteCount: bytesWritten
                    )
                }
            )
        }
        let writersByStream = Dictionary(
            uniqueKeysWithValues: writers.map {
                ($0.sourceStreamIndex, $0)
            }
        )
        demuxer.discardAllStreamsExcept(Set(writersByStream.keys))

        var packetsByStream: [Int32: Int] = [:]
        while let packet = try demuxer.readPacket() {
            var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&packetToFree) }
            guard let writer = writersByStream[packet.pointee.stream_index] else {
                Issue.record("Unexpected stream \(packet.pointee.stream_index)")
                continue
            }
            packetsByStream[packet.pointee.stream_index, default: 0] += 1
            try writer.consume(packet)
        }

        let summaries = try writers.map { try $0.finish() }
        #expect(packetsByStream[0, default: 0] > 0)
        #expect(packetsByStream[1, default: 0] > 0)
        #expect(summaries.allSatisfy {
            $0.pipeline == .streamCopy(codecString: "ec-3")
        })
        for cache in caches {
            #expect(cache.fetchInit(timeout: 0) != nil)
            #expect(cache.peekURL(index: 0) != nil)
        }
        #expect(throws: BlackCarrierAudioRenditionMuxerError.alreadyFinished) {
            _ = try writers[0].finish()
        }
    }

    @Test("Composite builder assembles every audio track from one demuxer")
    func sharedDemuxCompositeBuilder() throws {
        let sourceData = try makeDualEAC3Container(seconds: 1)
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: sourceData))
        defer { demuxer.close() }

        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(seconds: 1, preferredTimescale: 90_000)
        )
        let videoProvider = try BlackCarrierVideoProvider(timeline: timeline)
        let directories = [videoProvider.sessionDirectory]

        let provider = try BlackCarrierCompositeProvider.build(
            videoProvider: videoProvider,
            audioDemuxer: demuxer,
            timeline: timeline
        )
        let audioDirectories = provider.alternateAudioRenditions.compactMap {
            provider.alternateAudioMediaSegmentURL(
                ordinal: $0.ordinal,
                index: 0
            )?.deletingLastPathComponent()
        }

        #expect(provider.alternateAudioRenditions.count == 2)
        #expect(provider.alternateAudioRenditions.map(\.ordinal) == [0, 1])
        #expect(provider.alternateAudioRenditions.filter(\.isDefault).count == 1)
        #expect(provider.sourceTrackID(forAudioOrdinal: 0) == 0)
        #expect(provider.sourceTrackID(forAudioOrdinal: 1) == 1)
        #expect(provider.masterCodecs == "avc1.42C01E,ec-3")
        for ordinal in 0...1 {
            #expect(provider.alternateAudioInitSegment(ordinal: ordinal) != nil)
            #expect(provider.alternateAudioMediaSegment(
                ordinal: ordinal,
                index: 0
            ) != nil)
        }

        provider.close()
        for directory in directories + audioDirectories {
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }

    @Test("Media fanout pump stops after the requested segment and resumes to EOF")
    func incrementalMediaFanoutPump() throws {
        let sourceData = try makeDualEAC3Container(seconds: 5.25)
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: sourceData))
        defer { demuxer.close() }
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(seconds: 5.25, preferredTimescale: 90_000)
        )
        let pump = try BlackCarrierMediaFanoutPump(
            demuxer: demuxer,
            timeline: timeline
        )
        defer { pump.close() }

        #expect(pump.renditionMetadata.map(\.ordinal) == [0, 1])
        #expect(pump.renditionDescriptors.allSatisfy {
            $0.pipeline == .streamCopy(codecString: "ec-3")
        })
        #expect(!pump.finished)
        #expect(pump.peekInitSegment(ordinal: 0) == nil)
        #expect(throws: BlackCarrierMediaFanoutPumpError
            .invalidRenditionOrdinal(ordinal: 9)) {
            _ = try pump.initSegment(ordinal: 9)
        }
        #expect(pump.peekInitSegment(ordinal: 0) == nil)

        let firstInit = try pump.initSegment(ordinal: 0)
        #expect(firstInit != nil)
        #expect(pump.peekInitSegment(ordinal: 1) != nil)
        #expect(pump.peekMediaSegmentURL(ordinal: 0, index: 0) != nil)
        #expect(pump.peekMediaSegmentURL(ordinal: 1, index: 0) != nil)
        #expect(pump.peekMediaSegmentURL(ordinal: 0, index: 1) == nil)
        #expect(pump.peekMediaSegmentURL(ordinal: 1, index: 1) == nil)
        #expect(!pump.finished)

        try pump.produce(throughSegment: 1)
        #expect(pump.finished)
        for ordinal in 0...1 {
            #expect(pump.peekMediaSegmentURL(
                ordinal: ordinal,
                index: 1
            ) != nil)
            #expect(pump.summary(ordinal: ordinal)?.codecString == "ec-3")
        }
    }

    private struct EditListEntry: Equatable {
        let segmentDuration: UInt64
        let mediaTime: Int64
    }

    private func editListEntries(
        _ data: Data
    ) -> [EditListEntry] {
        guard let moov = boxes(in: data, range: 0..<data.count)
            .first(where: { $0.type == "moov" })?.body,
              let trak = boxes(in: data, range: moov)
                .first(where: { $0.type == "trak" })?.body,
              let edts = boxes(in: data, range: trak)
                .first(where: { $0.type == "edts" })?.body,
              let elst = boxes(in: data, range: edts)
                .first(where: { $0.type == "elst" })?.body else {
            return []
        }
        let version = data[elst.lowerBound]
        let count = Int(readUInt32(data, at: elst.lowerBound + 4))
        var entries: [EditListEntry] = []
        var offset = elst.lowerBound + 8
        for _ in 0..<count {
            if version == 1 {
                let duration = readUInt64(data, at: offset)
                let mediaTime = Int64(bitPattern: readUInt64(data, at: offset + 8))
                entries.append(EditListEntry(
                    segmentDuration: duration,
                    mediaTime: mediaTime
                ))
                offset += 20
            } else {
                let duration = UInt64(readUInt32(data, at: offset))
                let mediaTime = Int64(Int32(bitPattern: readUInt32(
                    data,
                    at: offset + 4
                )))
                entries.append(EditListEntry(
                    segmentDuration: duration,
                    mediaTime: mediaTime
                ))
                offset += 12
            }
        }
        return entries
    }

    private func fragmentBaseMediaDecodeTime(_ data: Data) -> UInt64? {
        for (type, body) in boxes(in: data, range: 0..<data.count) where type == "moof" {
            for (childType, childBody) in boxes(in: data, range: body)
            where childType == "traf" {
                for (trafType, trafBody) in boxes(in: data, range: childBody)
                where trafType == "tfdt" {
                    let version = data[trafBody.lowerBound]
                    if version == 1 {
                        return readUInt64(data, at: trafBody.lowerBound + 4)
                    }
                    return UInt64(readUInt32(data, at: trafBody.lowerBound + 4))
                }
            }
        }
        return nil
    }

    private func boxes(
        in data: Data,
        range: Range<Int>
    ) -> [(type: String, body: Range<Int>)] {
        var result: [(String, Range<Int>)] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            let size = Int(readUInt32(data, at: offset))
            guard size >= 8, offset + size <= range.upperBound else { break }
            let type = String(
                bytes: data[(offset + 4)..<(offset + 8)],
                encoding: .ascii
            ) ?? "????"
            result.append((type, (offset + 8)..<(offset + size)))
            offset += size
        }
        return result
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(
                fromByteOffset: offset,
                as: UInt32.self
            ))
        }
    }

    private func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        data.withUnsafeBytes {
            UInt64(bigEndian: $0.loadUnaligned(
                fromByteOffset: offset,
                as: UInt64.self
            ))
        }
    }

    private func makeEAC3FragmentedMP4(seconds: Double) throws -> Data {
        let sourceData = makeWAV(
            sampleRate: 48_000,
            channels: 2,
            seconds: seconds
        )
        let sourceDemuxer = Demuxer()
        try sourceDemuxer.open(reader: DataIOReader(data: sourceData))
        defer { sourceDemuxer.close() }

        let sourceStream = try #require(
            sourceDemuxer.stream(at: sourceDemuxer.audioStreamIndex)
        )
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

        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AetherAudioRenditionSource-\(UUID().uuidString)",
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
            preserveEncoderPriming: true,
            onInitCaptured: { initSegment = $0 }
        )

        func write(_ packet: UnsafeMutablePointer<AVPacket>) throws {
            packet.pointee.stream_index = muxer.audioOutputStreamIndex
            av_packet_rescale_ts(
                packet,
                bridge.encoderTimeBase,
                muxer.muxerAudioTimeBase
            )
            let result = muxer.writePacket(packet)
            guard result >= 0 else {
                throw BlackCarrierAudioRenditionMuxerError.packetWriteFailed(
                    segmentIndex: 0,
                    code: result
                )
            }
        }

        while let sourcePacket = try sourceDemuxer.readPacket() {
            var sourcePacketToFree: UnsafeMutablePointer<AVPacket>? = sourcePacket
            defer { trackedPacketFree(&sourcePacketToFree) }
            guard sourcePacket.pointee.stream_index == sourceDemuxer.audioStreamIndex else {
                continue
            }
            for encodedPacket in try bridge.feed(packet: sourcePacket) {
                var encodedPacketToFree: UnsafeMutablePointer<AVPacket>? = encodedPacket
                defer { trackedPacketFree(&encodedPacketToFree) }
                try write(encodedPacket)
            }
        }
        for encodedPacket in bridge.flush() {
            var encodedPacketToFree: UnsafeMutablePointer<AVPacket>? = encodedPacket
            defer { trackedPacketFree(&encodedPacketToFree) }
            try write(encodedPacket)
        }

        let finalized = try #require(muxer.finalize())
        return try #require(initSegment) + Data(contentsOf: finalized.path)
    }

    private func makeDualEAC3Container(seconds: Double) throws -> Data {
        let sourceDemuxers = try [
            makeWAVDemuxer(seconds: seconds, frequency: 440),
            makeWAVDemuxer(seconds: seconds, frequency: 660),
        ]
        defer { sourceDemuxers.forEach { $0.close() } }
        let bridges = try sourceDemuxers.map { demuxer in
            let stream = try #require(
                demuxer.stream(at: demuxer.audioStreamIndex)
            )
            return try AudioBridge(
                srcCodecpar: stream.pointee.codecpar,
                srcTimeBase: stream.pointee.time_base,
                mode: .surroundCompat
            )
        }
        defer { bridges.forEach { $0.close() } }

        var encodedPackets: [
            (streamIndex: Int32, packet: UnsafeMutablePointer<AVPacket>)
        ] = []
        defer {
            for entry in encodedPackets {
                var packet: UnsafeMutablePointer<AVPacket>? = entry.packet
                trackedPacketFree(&packet)
            }
        }
        for (streamIndex, pair) in zip(sourceDemuxers, bridges).enumerated() {
            let demuxer = pair.0
            let bridge = pair.1
            while let sourcePacket = try demuxer.readPacket() {
                var sourcePacketToFree: UnsafeMutablePointer<AVPacket>? =
                    sourcePacket
                defer { trackedPacketFree(&sourcePacketToFree) }
                guard sourcePacket.pointee.stream_index
                    == demuxer.audioStreamIndex else {
                    continue
                }
                encodedPackets.append(contentsOf: try bridge.feed(
                    packet: sourcePacket
                ).map {
                    (streamIndex: Int32(streamIndex), packet: $0)
                })
            }
            encodedPackets.append(contentsOf: bridge.flush().map {
                (streamIndex: Int32(streamIndex), packet: $0)
            })
        }
        encodedPackets.sort {
            if $0.packet.pointee.pts == $1.packet.pointee.pts {
                return $0.streamIndex < $1.streamIndex
            }
            return $0.packet.pointee.pts < $1.packet.pointee.pts
        }

        var contextOut: UnsafeMutablePointer<AVFormatContext>?
        let allocResult = avformat_alloc_output_context2(
            &contextOut,
            nil,
            "mp4",
            nil
        )
        guard allocResult >= 0, let context = contextOut else {
            throw BlackCarrierAudioRenditionMuxerError.muxerSetupFailed(
                reason: "dual-audio MP4 context \(allocResult)"
            )
        }
        defer { avformat_free_context(context) }

        var ioContext: UnsafeMutablePointer<AVIOContext>?
        let ioResult = avio_open_dyn_buf(&ioContext)
        guard ioResult >= 0, let ioContext else {
            throw BlackCarrierAudioRenditionMuxerError.muxerSetupFailed(
                reason: "dual-audio dynamic IO \(ioResult)"
            )
        }
        context.pointee.pb = ioContext

        var dynamicBuffer: UnsafeMutablePointer<UInt8>?
        defer {
            if context.pointee.pb != nil {
                _ = avio_close_dyn_buf(ioContext, &dynamicBuffer)
                context.pointee.pb = nil
            }
            if dynamicBuffer != nil {
                av_free(dynamicBuffer)
            }
        }

        for bridge in bridges {
            guard let stream = avformat_new_stream(context, nil) else {
                throw BlackCarrierAudioRenditionMuxerError.muxerSetupFailed(
                    reason: "dual-audio stream allocation"
                )
            }
            let encoderCodecParameters = try #require(bridge.encoderCodecpar)
            let copyResult = avcodec_parameters_copy(
                stream.pointee.codecpar,
                encoderCodecParameters
            )
            guard copyResult >= 0 else {
                throw BlackCarrierAudioRenditionMuxerError.muxerSetupFailed(
                    reason: "dual-audio codec parameters \(copyResult)"
                )
            }
            stream.pointee.time_base = bridge.encoderTimeBase
        }

        let headerResult = avformat_write_header(context, nil)
        guard headerResult >= 0 else {
            throw BlackCarrierAudioRenditionMuxerError.muxerSetupFailed(
                reason: "dual-audio header \(headerResult)"
            )
        }

        for entry in encodedPackets {
            let packet = entry.packet
            packet.pointee.stream_index = entry.streamIndex
            let outputStream = context.pointee.streams[
                Int(entry.streamIndex)
            ]!
            av_packet_rescale_ts(
                packet,
                bridges[Int(entry.streamIndex)].encoderTimeBase,
                outputStream.pointee.time_base
            )
            let writeResult = av_interleaved_write_frame(context, packet)
            guard writeResult >= 0 else {
                throw BlackCarrierAudioRenditionMuxerError.muxerSetupFailed(
                    reason: "dual-audio packet write \(writeResult)"
                )
            }
        }

        let trailerResult = av_write_trailer(context)
        guard trailerResult >= 0 else {
            throw BlackCarrierAudioRenditionMuxerError.muxerSetupFailed(
                reason: "dual-audio trailer \(trailerResult)"
            )
        }

        let size = avio_close_dyn_buf(ioContext, &dynamicBuffer)
        context.pointee.pb = nil
        guard size > 0, let dynamicBuffer else {
            throw BlackCarrierAudioRenditionMuxerError.muxerSetupFailed(
                reason: "dual-audio output is empty"
            )
        }
        return Data(bytes: dynamicBuffer, count: Int(size))
    }

    private func makeWAVDemuxer(
        seconds: Double,
        frequency: Double
    ) throws -> Demuxer {
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: makeWAV(
            sampleRate: 48_000,
            channels: 2,
            seconds: seconds,
            frequency: frequency
        )))
        return demuxer
    }

    private func makeWAV(
        sampleRate: Int,
        channels: Int,
        seconds: Double,
        frequency: Double = 440
    ) -> Data {
        let frames = Int(Double(sampleRate) * seconds)
        var pcm = Data(capacity: frames * channels * 2)
        for frame in 0..<frames {
            let value = Int16(
                9_000 * sin(
                    2 * .pi * frequency * Double(frame) / Double(sampleRate)
                )
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
