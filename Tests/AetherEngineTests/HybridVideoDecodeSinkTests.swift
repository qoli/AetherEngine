import CoreMedia
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Testing
@testable import AetherEngine

@Suite("Hybrid video decode sink", .serialized)
struct HybridVideoDecodeSinkTests {
    private final class FrameBox: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [DecodedVideoFrame] = []

        func append(_ frame: DecodedVideoFrame) {
            lock.lock()
            frames.append(frame)
            lock.unlock()
        }

        func snapshot() -> [DecodedVideoFrame] {
            lock.lock()
            defer { lock.unlock() }
            return frames
        }
    }

    private final class ClonableDataReader: IOReader, @unchecked Sendable {
        private let data: Data
        private let lock = NSLock()
        private var position = 0
        private var isClosed = false

        init(data: Data) {
            self.data = data
        }

        func read(
            _ buffer: UnsafeMutablePointer<UInt8>?,
            size: Int32
        ) -> Int32 {
            guard let buffer, size > 0 else { return -1 }
            lock.lock()
            defer { lock.unlock() }
            guard !isClosed else { return -1 }
            guard position < data.count else { return 0 }
            let count = min(Int(size), data.count - position)
            data.copyBytes(
                to: buffer,
                from: position..<(position + count)
            )
            position += count
            return Int32(count)
        }

        func seek(offset: Int64, whence: Int32) -> Int64 {
            if whence == 65_536 {
                return Int64(data.count)
            }
            lock.lock()
            defer { lock.unlock() }
            guard !isClosed else { return -1 }
            let target: Int
            switch whence {
            case 0:
                target = Int(offset)
            case 1:
                target = position + Int(offset)
            case 2:
                target = data.count + Int(offset)
            default:
                return -1
            }
            guard target >= 0, target <= data.count else {
                return -1
            }
            position = target
            return Int64(position)
        }

        func close() {
            lock.lock()
            isClosed = true
            lock.unlock()
        }

        func makeIndependentReader() -> IOReader? {
            ClonableDataReader(data: data)
        }
    }

    @Test("Bounded-latency decoder thread budget stays within FFmpeg's supported range")
    func boundedLatencyThreadBudget() {
        #expect(
            SoftwareVideoDecoder.boundedLatencyThreadCount(
                activeProcessorCount: 24
            ) == 16
        )
        #expect(
            SoftwareVideoDecoder.boundedLatencyThreadCount(
                activeProcessorCount: 0
            ) == 1
        )
    }

    @Test("Compressed packets become generation-tagged decoded frames")
    func decodesFramesAcrossGenerations() throws {
        let data = try BlackCarrierEncodedSample.verifiedMP4Data()
        let firstDemuxer = try openDemuxer(data: data)
        defer { firstDemuxer.close() }
        let frames = FrameBox()
        let sink = try HybridVideoDecodeSink(
            demuxer: firstDemuxer,
            initialGeneration: 7,
            onFrame: { frames.append($0) }
        )
        defer { sink.close() }

        try feedVideoPackets(from: firstDemuxer, into: sink)
        try sink.finish()
        let firstFrame = try #require(frames.snapshot().first)
        #expect(firstFrame.generation == 7)
        #expect(firstFrame.videoFormat == .sdr)
        #expect(firstFrame.presentationTime.isNumeric)
        #expect(firstFrame.geometry.codedWidth == 640)
        #expect(firstFrame.geometry.codedHeight == 360)
        #expect(firstFrame.geometry.cleanAperture.width == 640)
        #expect(firstFrame.geometry.cleanAperture.height == 360)
        #expect(firstFrame.geometry.pixelAspectRatioNumerator == 1)
        #expect(firstFrame.geometry.pixelAspectRatioDenominator == 1)
        #expect(firstFrame.geometry.rotationDegrees == 0)

        let secondDemuxer = try openDemuxer(data: data)
        defer { secondDemuxer.close() }
        let secondVideoIndex = secondDemuxer.videoStreamIndex
        let secondStream = try #require(
            secondDemuxer.stream(at: secondVideoIndex)
        )
        try sink.beginGeneration(
            8,
            targetTime: .zero,
            restartDecodeAnchorTime: .zero,
            demuxer: secondDemuxer,
            stream: secondStream
        )
        try feedVideoPackets(from: secondDemuxer, into: sink)
        try sink.finish()

        let snapshot = frames.snapshot()
        #expect(snapshot.contains(where: { $0.generation == 7 }))
        #expect(snapshot.contains(where: { $0.generation == 8 }))
        #expect(sink.failure == nil)
    }

    @Test("Closed sink fails explicitly")
    func closedSinkFails() throws {
        let data = try BlackCarrierEncodedSample.verifiedMP4Data()
        let demuxer = try openDemuxer(data: data)
        defer { demuxer.close() }
        let sink = try HybridVideoDecodeSink(
            demuxer: demuxer,
            initialGeneration: 0,
            onFrame: { _ in }
        )
        sink.close()
        let packet = try #require(try demuxer.readPacket())
        defer {
            var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&packetToFree)
        }
        #expect(throws: HybridVideoDecodeSinkError.closed) {
            try sink.consume(packet)
        }
    }

    @Test("Invalid clock demand fails explicitly")
    func invalidClockDemandFails() throws {
        let data = try BlackCarrierEncodedSample.verifiedMP4Data()
        let demuxer = try openDemuxer(data: data)
        defer { demuxer.close() }
        let sink = try HybridVideoDecodeSink(
            demuxer: demuxer,
            initialGeneration: 0,
            onFrame: { _ in }
        )
        defer { sink.close() }

        #expect(throws: HybridVideoDecodeSinkError.invalidDecodeDemand) {
            try sink.advanceDecodeDemand(to: .invalid)
        }
        #expect(sink.failure == .invalidDecodeDemand)
    }

    @Test("Missing packet timestamps fail explicitly")
    func missingPacketTimestampFails() throws {
        let data = try BlackCarrierEncodedSample.verifiedMP4Data()
        let demuxer = try openDemuxer(data: data)
        defer { demuxer.close() }
        let sink = try HybridVideoDecodeSink(
            demuxer: demuxer,
            initialGeneration: 0,
            onFrame: { _ in }
        )
        defer { sink.close() }
        let packet = try #require(try demuxer.readPacket())
        defer {
            var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&packetToFree)
        }
        packet.pointee.pts = Int64.min
        packet.pointee.dts = Int64.min

        #expect(throws: HybridVideoDecodeSinkError.packetTimestampMissing) {
            try sink.consume(packet)
        }
        #expect(sink.failure == .packetTimestampMissing)
    }

    @Test("Invalid video packet time base fails before decoder creation")
    func invalidPacketTimeBaseFails() throws {
        let data = try BlackCarrierEncodedSample.verifiedMP4Data()
        let demuxer = try openDemuxer(data: data)
        defer { demuxer.close() }
        let stream = try #require(demuxer.stream(
            at: demuxer.videoStreamIndex
        ))
        let original = stream.pointee.time_base
        stream.pointee.time_base = AVRational(num: 0, den: 0)
        defer { stream.pointee.time_base = original }

        #expect(throws: HybridVideoDecodeSinkError
            .invalidPacketTimeBase) {
            _ = try HybridVideoDecodeSink(
                demuxer: demuxer,
                initialGeneration: 0,
                onFrame: { _ in }
            )
        }
    }

    @Test("Real-video frame rate is snapped for display criteria without inventing unusual rates")
    func displayFrameRateContract() throws {
        let data = try BlackCarrierEncodedSample.verifiedMP4Data()
        let standardDemuxer = try openDemuxer(data: data)
        defer { standardDemuxer.close() }
        let standardStream = try #require(
            standardDemuxer.stream(
                at: standardDemuxer.videoStreamIndex
            )
        )
        standardStream.pointee.avg_frame_rate = AVRational(
            num: 30_000,
            den: 1_001
        )
        let standardSink = try HybridVideoDecodeSink(
            demuxer: standardDemuxer,
            initialGeneration: 0,
            onFrame: { _ in }
        )
        defer { standardSink.close() }
        #expect(
            standardSink.streamContract.displayFrameRate
                == 29.97
        )

        let unusualDemuxer = try openDemuxer(data: data)
        defer { unusualDemuxer.close() }
        let unusualStream = try #require(
            unusualDemuxer.stream(
                at: unusualDemuxer.videoStreamIndex
            )
        )
        unusualStream.pointee.avg_frame_rate = AVRational(
            num: 1,
            den: 1
        )
        unusualStream.pointee.r_frame_rate = AVRational(
            num: 1,
            den: 1
        )
        let unusualSink = try HybridVideoDecodeSink(
            demuxer: unusualDemuxer,
            initialGeneration: 0,
            onFrame: { _ in }
        )
        defer { unusualSink.close() }
        #expect(
            unusualSink.streamContract.displayFrameRate == nil
        )
    }

    @Test("Non-zero source origin is normalized before decode demand and frame delivery")
    func nonZeroSourceOriginNormalization() throws {
        let data = try makeVideoOnlySource(
            seconds: 1,
            sourceStartSeconds: 5
        )
        let demuxer = try openDemuxer(data: data)
        defer { demuxer.close() }
        let frames = FrameBox()
        let sink = try HybridVideoDecodeSink(
            demuxer: demuxer,
            initialGeneration: 0,
            onFrame: { frames.append($0) }
        )
        defer { sink.close() }

        #expect(
            abs(sink.streamContract.sourceStartTime.seconds - 5)
                < 0.000_001
        )
        try feedVideoPackets(from: demuxer, into: sink)

        let frame = try #require(frames.snapshot().first)
        #expect(abs(frame.presentationTime.seconds) < 0.000_001)
        #expect(sink.isTargetFrameReady)
    }

    @Test("Restart timestamp reset rebases only with distinct packet-position evidence")
    func restartTimestampResetRebase() throws {
        let data = try BlackCarrierEncodedSample.verifiedMP4Data()
        let initialDemuxer = try openDemuxer(data: data)
        defer { initialDemuxer.close() }
        let frames = FrameBox()
        let sink = try HybridVideoDecodeSink(
            demuxer: initialDemuxer,
            initialGeneration: 7,
            onFrame: { frames.append($0) }
        )
        defer { sink.close() }
        let initialPacket = try #require(
            try initialDemuxer.readPacket()
        )
        let originPosition = initialPacket.pointee.pos
        #expect(originPosition >= 0)
        try sink.consume(initialPacket)
        var initialPacketToFree:
            UnsafeMutablePointer<AVPacket>? = initialPacket
        trackedPacketFree(&initialPacketToFree)
        try sink.finish()

        let freshDemuxer = try openDemuxer(data: data)
        defer { freshDemuxer.close() }
        let freshStream = try #require(freshDemuxer.stream(
            at: freshDemuxer.videoStreamIndex
        ))
        try sink.beginGeneration(
            8,
            targetTime: CMTime(
                seconds: 4.5,
                preferredTimescale: 600
            ),
            restartDecodeAnchorTime: CMTime(
                seconds: 4,
                preferredTimescale: 600
            ),
            demuxer: freshDemuxer,
            stream: freshStream
        )
        let resetPacket = try #require(
            try freshDemuxer.readPacket()
        )
        defer {
            var packetToFree:
                UnsafeMutablePointer<AVPacket>? = resetPacket
            trackedPacketFree(&packetToFree)
        }
        resetPacket.pointee.pts =
            sink.streamContract.sourceStartPTS
        resetPacket.pointee.dts =
            sink.streamContract.sourceStartPTS
        resetPacket.pointee.pos = originPosition + 1

        try sink.consume(resetPacket)
        try sink.finish()

        let rebased = try #require(
            frames.snapshot().last(where: {
                $0.generation == 8
            })
        )
        #expect(abs(rebased.presentationTime.seconds - 4) < 0.000_001)
    }

    @Test("Ambiguous restart timestamp reset fails instead of guessing")
    func ambiguousRestartTimestampResetFails() throws {
        let data = try BlackCarrierEncodedSample.verifiedMP4Data()
        let initialDemuxer = try openDemuxer(data: data)
        defer { initialDemuxer.close() }
        let sink = try HybridVideoDecodeSink(
            demuxer: initialDemuxer,
            initialGeneration: 0,
            onFrame: { _ in }
        )
        defer { sink.close() }
        let initialPacket = try #require(
            try initialDemuxer.readPacket()
        )
        try sink.consume(initialPacket)
        var initialPacketToFree:
            UnsafeMutablePointer<AVPacket>? = initialPacket
        trackedPacketFree(&initialPacketToFree)
        try sink.finish()

        let freshDemuxer = try openDemuxer(data: data)
        defer { freshDemuxer.close() }
        let freshStream = try #require(freshDemuxer.stream(
            at: freshDemuxer.videoStreamIndex
        ))
        try sink.beginGeneration(
            1,
            targetTime: CMTime(
                seconds: 4.5,
                preferredTimescale: 600
            ),
            restartDecodeAnchorTime: nil,
            demuxer: freshDemuxer,
            stream: freshStream
        )
        let resetPacket = try #require(
            try freshDemuxer.readPacket()
        )
        defer {
            var packetToFree:
                UnsafeMutablePointer<AVPacket>? = resetPacket
            trackedPacketFree(&packetToFree)
        }
        resetPacket.pointee.pts =
            sink.streamContract.sourceStartPTS
        resetPacket.pointee.dts =
            sink.streamContract.sourceStartPTS
        resetPacket.pointee.pos = -1
        let expected = HybridVideoDecodeSinkError
            .restartTimestampRebaseAmbiguous(
                generation: 1,
                timestamp: sink.streamContract.sourceStartPTS
            )

        #expect(throws: expected) {
            try sink.consume(resetPacket)
        }
        #expect(sink.failure == expected)
    }

    @Test("Origin packet at the same byte position is not falsely rebased")
    func sameOriginPacketPositionIsNotRebased() throws {
        let data = try BlackCarrierEncodedSample.verifiedMP4Data()
        let initialDemuxer = try openDemuxer(data: data)
        defer { initialDemuxer.close() }
        let frames = FrameBox()
        let sink = try HybridVideoDecodeSink(
            demuxer: initialDemuxer,
            initialGeneration: 3,
            onFrame: { frames.append($0) }
        )
        defer { sink.close() }
        let initialPacket = try #require(
            try initialDemuxer.readPacket()
        )
        let originPosition = initialPacket.pointee.pos
        #expect(originPosition >= 0)
        try sink.consume(initialPacket)
        var initialPacketToFree:
            UnsafeMutablePointer<AVPacket>? = initialPacket
        trackedPacketFree(&initialPacketToFree)
        try sink.finish()

        let freshDemuxer = try openDemuxer(data: data)
        defer { freshDemuxer.close() }
        let freshStream = try #require(freshDemuxer.stream(
            at: freshDemuxer.videoStreamIndex
        ))
        try sink.beginGeneration(
            4,
            targetTime: CMTime(
                seconds: 4.5,
                preferredTimescale: 600
            ),
            restartDecodeAnchorTime: .zero,
            demuxer: freshDemuxer,
            stream: freshStream
        )
        let originPacket = try #require(
            try freshDemuxer.readPacket()
        )
        defer {
            var packetToFree:
                UnsafeMutablePointer<AVPacket>? = originPacket
            trackedPacketFree(&packetToFree)
        }
        originPacket.pointee.pts =
            sink.streamContract.sourceStartPTS
        originPacket.pointee.dts =
            sink.streamContract.sourceStartPTS
        originPacket.pointee.pos = originPosition

        try sink.consume(originPacket)
        try sink.finish()

        let frame = try #require(frames.snapshot().last(where: {
            $0.generation == 4
        }))
        #expect(abs(frame.presentationTime.seconds) < 0.000_001)
        #expect(sink.failure == nil)
    }

    @Test("Non-zero source origin carrier reaches startup and seek readiness")
    func nonZeroOriginCarrierIntegration() throws {
        let duration = 5.25
        let sourceData = try makeVideoOnlySource(
            seconds: duration,
            sourceStartSeconds: 5
        )
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: duration,
                preferredTimescale: 90_000
            )
        )
        let videoProvider = try BlackCarrierVideoProvider(
            timeline: timeline
        )
        let frames = FrameBox()
        let provider = try BlackCarrierLazyCompositeProvider
            .buildSeekableVOD(
                videoProvider: videoProvider,
                source: .custom(
                    ClonableDataReader(data: sourceData),
                    formatHint: "mp4"
                ),
                options: LoadOptions(),
                timeline: timeline,
                decodedFrameHandler: { frames.append($0) }
            )
        defer { provider.close() }

        try provider.prepareForTransportStart()
        #expect(provider.mediaSegmentURL(at: 0) != nil)
        #expect(frames.snapshot().contains(where: {
            $0.generation == 0
                && abs($0.presentationTime.seconds) < 0.000_001
        }))

        var classifier = HybridSeekIntentClassifier(
            timeline: timeline
        )
        let target = CMTime(
            seconds: 4.5,
            preferredTimescale: 90_000
        )
        let intent = try classifier.registerExplicitHostSeek(
            to: target
        )
        #expect(try provider.restartMedia(for: intent) == .applied(
            generation: 1,
            segmentIndex: 1
        ))
        #expect(provider.mediaSegmentURL(at: 1) != nil)
        #expect(frames.snapshot().contains(where: {
            $0.generation == 1
                && CMTimeCompare(
                    $0.presentationTime,
                    CMTime(
                        seconds: 4,
                        preferredTimescale: 90_000
                    )
                ) >= 0
        }))
        #expect(provider.terminalError == nil)
    }

    @Test("Shared carrier fanout decodes real video on startup and seek generations")
    func carrierFanoutIntegration() throws {
        let duration = 5.25
        let sourceData = try makeAVSource(seconds: duration)
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: duration,
                preferredTimescale: 90_000
            )
        )
        let videoProvider = try BlackCarrierVideoProvider(
            timeline: timeline
        )
        let frames = FrameBox()
        let provider = try BlackCarrierLazyCompositeProvider
            .buildSeekableVOD(
                videoProvider: videoProvider,
                source: .custom(
                    ClonableDataReader(data: sourceData),
                    formatHint: "mp4"
                ),
                options: LoadOptions(),
                timeline: timeline,
                decodedFrameHandler: { frames.append($0) }
            )
        defer { provider.close() }

        try provider.prepareForTransportStart()
        #expect(frames.snapshot().contains(where: {
            $0.generation == 0
        }))

        var classifier = HybridSeekIntentClassifier(timeline: timeline)
        let intent = try classifier.registerExplicitHostSeek(
            to: CMTime(seconds: 4.5, preferredTimescale: 90_000)
        )
        #expect(try provider.restartMedia(for: intent) == .applied(
            generation: 1,
            segmentIndex: 1
        ))
        _ = try #require(provider.alternateAudioMediaSegment(
            ordinal: 0,
            index: 1
        ))
        #expect(frames.snapshot().contains(where: {
            $0.generation == 1
                && CMTimeCompare(
                    $0.presentationTime,
                    CMTime(seconds: 4, preferredTimescale: 90_000)
                ) >= 0
        }))
        #expect(provider.terminalError == nil)
    }

    @Test("Video-only source uses carrier transport without a silent audio rendition")
    func videoOnlyCarrier() throws {
        let duration = 5.25
        let sourceData = try makeVideoOnlySource(seconds: duration)
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: duration,
                preferredTimescale: 90_000
            )
        )
        let videoProvider = try BlackCarrierVideoProvider(
            timeline: timeline
        )
        let frames = FrameBox()
        let provider = try BlackCarrierLazyCompositeProvider
            .buildSeekableVOD(
                videoProvider: videoProvider,
                source: .custom(
                    ClonableDataReader(data: sourceData),
                    formatHint: "mp4"
                ),
                options: LoadOptions(),
                timeline: timeline,
                decodedFrameHandler: { frames.append($0) }
            )
        defer { provider.close() }

        try provider.prepareForTransportStart()
        #expect(provider.alternateAudioRenditions.isEmpty)
        #expect(provider.masterCodecs == "avc1.42C01E")
        #expect(provider.mediaSegmentURL(at: 0) != nil)
        #expect(frames.snapshot().contains(where: {
            $0.generation == 0
        }))

        var classifier = HybridSeekIntentClassifier(timeline: timeline)
        let intent = try classifier.registerExplicitHostSeek(
            to: CMTime(seconds: 4.5, preferredTimescale: 90_000)
        )
        #expect(try provider.restartMedia(for: intent) == .applied(
            generation: 1,
            segmentIndex: 1
        ))
        #expect(provider.mediaSegmentURL(at: 1) != nil)
        #expect(frames.snapshot().contains(where: {
            $0.generation == 1
                && CMTimeCompare(
                    $0.presentationTime,
                    CMTime(seconds: 4, preferredTimescale: 90_000)
                ) >= 0
        }))
        #expect(provider.terminalError == nil)
    }

    private func openDemuxer(data: Data) throws -> Demuxer {
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data))
        let videoIndex = demuxer.videoStreamIndex
        guard videoIndex >= 0 else {
            demuxer.close()
            throw HybridVideoDecodeSinkError.videoStreamMissing
        }
        demuxer.discardAllStreamsExcept([videoIndex])
        return demuxer
    }

    private func feedVideoPackets(
        from demuxer: Demuxer,
        into sink: HybridVideoDecodeSink
    ) throws {
        let videoIndex = demuxer.videoStreamIndex
        while let packet = try demuxer.readPacket() {
            var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&packetToFree) }
            guard packet.pointee.stream_index == videoIndex else {
                continue
            }
            try sink.consume(packet)
        }
    }

    private func makeAVSource(seconds: Double) throws -> Data {
        let videoData = try BlackCarrierEncodedSample.verifiedMP4Data()
        let videoDemuxer = try openDemuxer(data: videoData)
        defer { videoDemuxer.close() }
        let videoIndex = videoDemuxer.videoStreamIndex
        let videoStream = try #require(
            videoDemuxer.stream(at: videoIndex)
        )
        let sourceVideoPacket = try #require(
            try videoDemuxer.readPacket()
        )
        defer {
            var packetToFree: UnsafeMutablePointer<AVPacket>? =
                sourceVideoPacket
            trackedPacketFree(&packetToFree)
        }

        let audioDemuxer = Demuxer()
        try audioDemuxer.open(
            reader: DataIOReader(data: makeWAV(seconds: seconds))
        )
        defer { audioDemuxer.close() }
        let audioIndex = audioDemuxer.audioStreamIndex
        let audioStream = try #require(
            audioDemuxer.stream(at: audioIndex)
        )
        let bridge = try AudioBridge(
            srcCodecpar: audioStream.pointee.codecpar,
            srcTimeBase: audioStream.pointee.time_base,
            mode: .surroundCompat
        )
        defer { bridge.close() }
        let encoderParameters = try #require(bridge.encoderCodecpar)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "HybridVideoDecodeSink-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        var initSegment: Data?
        let muxer = try MP4SegmentMuxer(
            initialSegmentIndex: 0,
            sessionDir: directory,
            video: MP4SegmentMuxer.VideoConfig(
                codecpar: UnsafePointer(videoStream.pointee.codecpar),
                timeBase: videoStream.pointee.time_base,
                codecTagOverride: "avc1"
            ),
            audio: MP4SegmentMuxer.AudioConfig(
                codecpar: UnsafePointer(encoderParameters),
                timeBase: bridge.encoderTimeBase
            ),
            onInitCaptured: { initSegment = $0 }
        )

        var packets: [
            (
                isVideo: Bool,
                timeBase: AVRational,
                packet: UnsafeMutablePointer<AVPacket>
            )
        ] = []
        defer {
            for entry in packets {
                var packet: UnsafeMutablePointer<AVPacket>? = entry.packet
                trackedPacketFree(&packet)
            }
        }

        let wholeSeconds = Int(ceil(seconds))
        for second in 0..<wholeSeconds {
            guard let packet = av_packet_clone(sourceVideoPacket) else {
                continue
            }
            let start = Double(second)
            let sampleDuration = min(1, seconds - start)
            guard sampleDuration > 0 else {
                var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
                trackedPacketFree(&packetToFree)
                continue
            }
            packet.pointee.pts = av_rescale_q(
                Int64(start * 90_000),
                AVRational(num: 1, den: 90_000),
                videoStream.pointee.time_base
            )
            packet.pointee.dts = packet.pointee.pts
            packet.pointee.duration = av_rescale_q(
                Int64(sampleDuration * 90_000),
                AVRational(num: 1, den: 90_000),
                videoStream.pointee.time_base
            )
            packets.append((
                isVideo: true,
                timeBase: videoStream.pointee.time_base,
                packet: packet
            ))
        }

        while let sourcePacket = try audioDemuxer.readPacket() {
            var sourcePacketToFree: UnsafeMutablePointer<AVPacket>? =
                sourcePacket
            defer { trackedPacketFree(&sourcePacketToFree) }
            guard sourcePacket.pointee.stream_index == audioIndex else {
                continue
            }
            for packet in try bridge.feed(packet: sourcePacket) {
                packets.append((
                    isVideo: false,
                    timeBase: bridge.encoderTimeBase,
                    packet: packet
                ))
            }
        }
        for packet in bridge.flush() {
            packets.append((
                isVideo: false,
                timeBase: bridge.encoderTimeBase,
                packet: packet
            ))
        }
        packets.sort {
            packetTime($0.packet, timeBase: $0.timeBase)
                < packetTime($1.packet, timeBase: $1.timeBase)
        }

        for entry in packets {
            entry.packet.pointee.stream_index = entry.isVideo
                ? muxer.videoOutputStreamIndex
                : muxer.audioOutputStreamIndex
            av_packet_rescale_ts(
                entry.packet,
                entry.timeBase,
                entry.isVideo
                    ? muxer.muxerVideoTimeBase
                    : muxer.muxerAudioTimeBase
            )
            #expect(muxer.writePacket(entry.packet) >= 0)
        }
        let finalized = try #require(muxer.finalize())
        return try #require(initSegment)
            + Data(contentsOf: finalized.path)
    }

    private func makeVideoOnlySource(
        seconds: Double,
        sourceStartSeconds: Double = 0
    ) throws -> Data {
        let videoData = try BlackCarrierEncodedSample.verifiedMP4Data()
        let videoDemuxer = try openDemuxer(data: videoData)
        defer { videoDemuxer.close() }
        let videoIndex = videoDemuxer.videoStreamIndex
        let videoStream = try #require(
            videoDemuxer.stream(at: videoIndex)
        )
        let sourceVideoPacket = try #require(
            try videoDemuxer.readPacket()
        )
        defer {
            var packetToFree: UnsafeMutablePointer<AVPacket>? =
                sourceVideoPacket
            trackedPacketFree(&packetToFree)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "HybridVideoOnly-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        var initSegment: Data?
        let muxer = try MP4SegmentMuxer(
            initialSegmentIndex: 0,
            sessionDir: directory,
            video: MP4SegmentMuxer.VideoConfig(
                codecpar: UnsafePointer(videoStream.pointee.codecpar),
                timeBase: videoStream.pointee.time_base,
                codecTagOverride: "avc1"
            ),
            audio: nil,
            onInitCaptured: { initSegment = $0 }
        )

        for second in 0..<Int(ceil(seconds)) {
            let start = Double(second)
            let sourcePresentationTime =
                sourceStartSeconds + start
            let sampleDuration = min(1, seconds - start)
            guard sampleDuration > 0,
                  let packet = av_packet_clone(sourceVideoPacket) else {
                continue
            }
            defer {
                var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
                trackedPacketFree(&packetToFree)
            }
            packet.pointee.pts = av_rescale_q(
                Int64(sourcePresentationTime * 90_000),
                AVRational(num: 1, den: 90_000),
                videoStream.pointee.time_base
            )
            packet.pointee.dts = packet.pointee.pts
            packet.pointee.duration = av_rescale_q(
                Int64(sampleDuration * 90_000),
                AVRational(num: 1, den: 90_000),
                videoStream.pointee.time_base
            )
            packet.pointee.stream_index = muxer.videoOutputStreamIndex
            av_packet_rescale_ts(
                packet,
                videoStream.pointee.time_base,
                muxer.muxerVideoTimeBase
            )
            #expect(muxer.writePacket(packet) >= 0)
        }
        let finalized = try #require(muxer.finalize())
        return try #require(initSegment)
            + Data(contentsOf: finalized.path)
    }

    private func packetTime(
        _ packet: UnsafeMutablePointer<AVPacket>,
        timeBase: AVRational
    ) -> Double {
        let timestamp = packet.pointee.dts != Int64.min
            ? packet.pointee.dts
            : packet.pointee.pts
        return Double(timestamp) * Double(timeBase.num)
            / Double(timeBase.den)
    }

    private func makeWAV(seconds: Double) -> Data {
        let sampleRate = 48_000
        let channels = 2
        let frames = Int(Double(sampleRate) * seconds)
        var pcm = Data(capacity: frames * channels * 2)
        for frame in 0..<frames {
            let value = Int16(
                9_000 * sin(
                    2 * .pi * 440 * Double(frame) / Double(sampleRate)
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
