import CoreMedia
import Foundation
import Libavcodec
import Libavformat
import Libavutil

enum BlackCarrierAudioRenditionMuxerError: Error, LocalizedError, Sendable, Equatable {
    case emptyTimeline
    case audioStreamMissing(index: Int32)
    case unsupportedCodec(rawCodecID: UInt32)
    case codecParametersCopyFailed
    case atmosStreamCopyUnavailable(code: Int32)
    case bridgeCreationFailed(reason: String)
    case bridgeHeaderRejected(code: Int32)
    case muxerSetupFailed(reason: String)
    case bridgeFeedFailed(reason: String)
    case nonMonotonicSegment(previous: Int, next: Int)
    case emptySegment(index: Int)
    case packetWriteFailed(segmentIndex: Int, code: Int32)
    case segmentFinalizeFailed(index: Int)
    case initSegmentMissing
    case alreadyFinished

    var errorDescription: String? {
        switch self {
        case .emptyTimeline:
            return "Black carrier audio rendition requires a non-empty timeline"
        case .audioStreamMissing(let index):
            return "Black carrier audio stream \(index) is unavailable"
        case .unsupportedCodec(let rawCodecID):
            return "Black carrier audio codec \(rawCodecID) is unsupported"
        case .codecParametersCopyFailed:
            return "Black carrier audio codec parameters could not be copied"
        case .atmosStreamCopyUnavailable(let code):
            return "EAC3 JOC Atmos cannot be preserved in the audio rendition (\(code))"
        case .bridgeCreationFailed(let reason):
            return "Black carrier audio bridge could not be created: \(reason)"
        case .bridgeHeaderRejected(let code):
            return "Black carrier bridged-audio header was rejected (\(code))"
        case .muxerSetupFailed(let reason):
            return "Black carrier audio-only muxer could not be created: \(reason)"
        case .bridgeFeedFailed(let reason):
            return "Black carrier audio bridge failed while decoding: \(reason)"
        case .nonMonotonicSegment(let previous, let next):
            return "Black carrier audio segment order regressed from \(previous) to \(next)"
        case .emptySegment(let index):
            return "Black carrier audio rendition has no packet for segment \(index)"
        case .packetWriteFailed(let segmentIndex, let code):
            return "Black carrier audio segment \(segmentIndex) packet write failed (\(code))"
        case .segmentFinalizeFailed(let index):
            return "Black carrier audio segment \(index) could not be finalized"
        case .initSegmentMissing:
            return "Black carrier audio muxer did not produce an init segment"
        case .alreadyFinished:
            return "Black carrier audio rendition writer is already finished"
        }
    }
}

enum BlackCarrierAudioPipeline: Sendable, Equatable {
    case streamCopy(codecString: String)
    case bridge(mode: AudioBridgeMode, codecString: String)
}

struct BlackCarrierAudioRenditionSummary: Sendable, Equatable {
    let pipeline: BlackCarrierAudioPipeline
    let codecString: String
    let channelsAttribute: String
    let declaredCodecInitialPaddingSamples: Int64
    let presentationTrimSamples: Int64
    let peakBandwidth: Int
    let averageBandwidth: Int
}

struct BlackCarrierAudioRenditionDescriptor: Sendable, Equatable {
    let pipeline: BlackCarrierAudioPipeline
    let codecString: String
    let channelsAttribute: String
    let declaredCodecInitialPaddingSamples: Int64
}

enum BlackCarrierAudioRenditionMuxer {
    typealias SegmentSink = (
        _ timing: BlackCarrierSegmentTiming,
        _ stagingPath: URL,
        _ bytesWritten: Int
    ) throws -> Void

    private struct PreparedRoute {
        let pipeline: BlackCarrierAudioPipeline
        let codecString: String
        let channelsAttribute: String
        let audioConfig: MP4SegmentMuxer.AudioConfig
        let packetTimeBase: AVRational
        let packetStartOffset: Int64
        let minimumRelativePacketTimestamp: Int64
        let fallbackDuration: Int64
        let sourceCodecID: AVCodecID
        let sampleRate: Int32
        let declaredCodecInitialPaddingSamples: Int64
        let ownedCodecParameters: HLSVideoEngine.OwnedCodecParameters?
        let bridge: AudioBridge?
    }

    final class Writer {
        private final class InitCapture {
            var data: Data?
        }

        let sourceStreamIndex: Int32

        private let timeline: BlackCarrierTimeline
        private let lastTiming: BlackCarrierSegmentTiming
        private let route: PreparedRoute
        private let muxer: MP4SegmentMuxer
        private let initCapture: InitCapture
        private let onInit: (Data) -> Void
        private let onSegment: SegmentSink

        private var currentOffset = 0
        private var wroteCurrentSegment = false
        private var peakBandwidth = 0
        private var totalMediaBytes = 0
        private var presentationTimelineOffset: Int64?
        private var isFinished = false
        private var didPublishInit = false
        private(set) var highestFinalizedSegmentIndex: Int

        fileprivate init(
            sourceStreamIndex: Int32,
            sourceStream: UnsafeMutablePointer<AVStream>,
            sourceStartPTS: Int64,
            timeline: BlackCarrierTimeline,
            bridgeMode: AudioBridgeMode,
            sessionDirectory: URL,
            onInit: @escaping (Data) -> Void,
            onSegment: @escaping SegmentSink
        ) throws {
            guard let firstTiming = timeline.segments.first,
                  let lastTiming = timeline.segments.last else {
                throw BlackCarrierAudioRenditionMuxerError.emptyTimeline
            }
            self.sourceStreamIndex = sourceStreamIndex
            self.timeline = timeline
            self.lastTiming = lastTiming
            self.onInit = onInit
            self.onSegment = onSegment
            highestFinalizedSegmentIndex = firstTiming.index - 1
            route = try prepareRoute(
                sourceStream: sourceStream,
                sourceStartPTS: sourceStartPTS,
                bridgeMode: bridgeMode
            )
            _ = route.ownedCodecParameters

            let capture = InitCapture()
            initCapture = capture
            do {
                muxer = try MP4SegmentMuxer(
                    initialSegmentIndex: firstTiming.index,
                    sessionDir: sessionDirectory,
                    audioOnly: route.audioConfig,
                    preserveEncoderPriming: true,
                    maxBufferedFragmentSeconds: maxBufferedFragmentSeconds(
                        for: timeline
                    ),
                    onInitCaptured: { capture.data = $0 }
                )
            } catch {
                route.bridge?.close()
                throw BlackCarrierAudioRenditionMuxerError.muxerSetupFailed(
                    reason: String(describing: error)
                )
            }
        }

        deinit {
            route.bridge?.close()
        }

        var descriptor: BlackCarrierAudioRenditionDescriptor {
            BlackCarrierAudioRenditionDescriptor(
                pipeline: route.pipeline,
                codecString: route.codecString,
                channelsAttribute: route.channelsAttribute,
                declaredCodecInitialPaddingSamples:
                    route.declaredCodecInitialPaddingSamples
            )
        }

        func consume(
            _ sourcePacket: UnsafeMutablePointer<AVPacket>
        ) throws {
            guard !isFinished else {
                throw BlackCarrierAudioRenditionMuxerError.alreadyFinished
            }
            guard sourcePacket.pointee.stream_index == sourceStreamIndex else {
                return
            }

            if let bridge = route.bridge {
                let outputs: [UnsafeMutablePointer<AVPacket>]
                do {
                    outputs = try bridge.feed(packet: sourcePacket)
                } catch {
                    throw BlackCarrierAudioRenditionMuxerError.bridgeFeedFailed(
                        reason: String(describing: error)
                    )
                }
                for output in outputs {
                    var outputToFree: UnsafeMutablePointer<AVPacket>? = output
                    defer { trackedPacketFree(&outputToFree) }
                    try writeOutputPacket(output)
                }
            } else {
                try writeOutputPacket(sourcePacket)
            }
        }

        func finish() throws -> BlackCarrierAudioRenditionSummary {
            guard !isFinished else {
                throw BlackCarrierAudioRenditionMuxerError.alreadyFinished
            }
            isFinished = true
            defer { route.bridge?.close() }

            if let bridge = route.bridge {
                for output in bridge.flush() {
                    var outputToFree: UnsafeMutablePointer<AVPacket>? = output
                    defer { trackedPacketFree(&outputToFree) }
                    try writeOutputPacket(output)
                }
            }

            guard currentOffset == timeline.segments.count - 1,
                  wroteCurrentSegment else {
                let missingOffset = min(
                    currentOffset + (wroteCurrentSegment ? 1 : 0),
                    timeline.segments.count - 1
                )
                throw BlackCarrierAudioRenditionMuxerError.emptySegment(
                    index: timeline.segments[missingOffset].index
                )
            }
            try emitFinalized(muxer.finalize(), timing: lastTiming)

            publishInitIfAvailable()
            guard didPublishInit else {
                throw BlackCarrierAudioRenditionMuxerError.initSegmentMissing
            }

            let duration = CMTimeGetSeconds(timeline.duration)
            let presentationTrimSamples = samples(
                forTicks: presentationTimelineOffset ?? 0,
                packetTimeBase: route.packetTimeBase,
                sampleRate: route.sampleRate
            )
            return BlackCarrierAudioRenditionSummary(
                pipeline: route.pipeline,
                codecString: route.codecString,
                channelsAttribute: route.channelsAttribute,
                declaredCodecInitialPaddingSamples:
                    route.declaredCodecInitialPaddingSamples,
                presentationTrimSamples: presentationTrimSamples,
                peakBandwidth: max(1, peakBandwidth),
                averageBandwidth: max(
                    1,
                    Int(ceil(Double(totalMediaBytes) * 8 / duration))
                )
            )
        }

        private func emitFinalized(
            _ finalized: (path: URL, bytesWritten: Int)?,
            timing: BlackCarrierSegmentTiming
        ) throws {
            guard let finalized else {
                throw BlackCarrierAudioRenditionMuxerError.segmentFinalizeFailed(
                    index: timing.index
                )
            }
            try onSegment(timing, finalized.path, finalized.bytesWritten)
            highestFinalizedSegmentIndex = timing.index
            publishInitIfAvailable()
            let duration = CMTimeGetSeconds(timing.duration)
            peakBandwidth = max(
                peakBandwidth,
                Int(ceil(Double(finalized.bytesWritten) * 8 / duration))
            )
            totalMediaBytes += finalized.bytesWritten
        }

        private func writeOutputPacket(
            _ packet: UnsafeMutablePointer<AVPacket>
        ) throws {
            if packet.pointee.pts == Int64.min {
                packet.pointee.pts = packet.pointee.dts
            }
            if packet.pointee.dts == Int64.min {
                packet.pointee.dts = packet.pointee.pts
            }
            guard packet.pointee.pts != Int64.min,
                  packet.pointee.dts != Int64.min else {
                return
            }

            packet.pointee.pts -= route.packetStartOffset
            packet.pointee.dts -= route.packetStartOffset
            guard packet.pointee.pts >= route.minimumRelativePacketTimestamp,
                  packet.pointee.dts >= route.minimumRelativePacketTimestamp else {
                return
            }
            if presentationTimelineOffset == nil {
                presentationTimelineOffset = max(0, -packet.pointee.pts)
            }
            if packet.pointee.duration <= 0 {
                packet.pointee.duration = route.fallbackDuration
            }
            if route.sourceCodecID == AV_CODEC_ID_AAC {
                stripADTSHeaderIfPresent(packet)
            }

            let presentationPTS =
                packet.pointee.pts + (presentationTimelineOffset ?? 0)
            guard presentationPTS >= 0 else {
                return
            }
            let timelinePTS = av_rescale_q(
                presentationPTS,
                route.packetTimeBase,
                approvedTimelineTimeBase
            )
            guard timelinePTS < timeline.duration.value else {
                return
            }
            let nextOffset = segmentOffset(
                forTimelinePTS: timelinePTS,
                timeline: timeline
            )
            guard nextOffset >= currentOffset else {
                throw BlackCarrierAudioRenditionMuxerError.nonMonotonicSegment(
                    previous: timeline.segments[currentOffset].index,
                    next: timeline.segments[nextOffset].index
                )
            }

            while currentOffset < nextOffset {
                let timing = timeline.segments[currentOffset]
                guard wroteCurrentSegment else {
                    throw BlackCarrierAudioRenditionMuxerError.emptySegment(
                        index: timing.index
                    )
                }
                try emitFinalized(
                    muxer.cutFragmentForNextSegment(
                        timeline.segments[currentOffset + 1].index
                    ),
                    timing: timing
                )
                currentOffset += 1
                wroteCurrentSegment = false
            }

            packet.pointee.stream_index = muxer.audioOutputStreamIndex
            packet.pointee.pos = -1
            av_packet_rescale_ts(
                packet,
                route.packetTimeBase,
                muxer.muxerAudioTimeBase
            )
            let result = muxer.writePacket(packet)
            guard result >= 0 else {
                throw BlackCarrierAudioRenditionMuxerError.packetWriteFailed(
                    segmentIndex: timeline.segments[currentOffset].index,
                    code: result
                )
            }
            wroteCurrentSegment = true
            publishInitIfAvailable()
        }

        private func publishInitIfAvailable() {
            guard !didPublishInit, let initSegment = initCapture.data else {
                return
            }
            didPublishInit = true
            onInit(initSegment)
        }
    }

    static func makeWriter(
        demuxer: Demuxer,
        audioStreamIndex: Int32,
        sourceStartPTS: Int64,
        timeline: BlackCarrierTimeline,
        bridgeMode: AudioBridgeMode = .surroundCompat,
        sessionDirectory: URL,
        onInit: @escaping (Data) -> Void,
        onSegment: @escaping SegmentSink
    ) throws -> Writer {
        guard audioStreamIndex >= 0,
              let sourceStream = demuxer.stream(at: audioStreamIndex),
              sourceStream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO else {
            throw BlackCarrierAudioRenditionMuxerError.audioStreamMissing(
                index: audioStreamIndex
            )
        }
        return try Writer(
            sourceStreamIndex: audioStreamIndex,
            sourceStream: sourceStream,
            sourceStartPTS: sourceStartPTS,
            timeline: timeline,
            bridgeMode: bridgeMode,
            sessionDirectory: sessionDirectory,
            onInit: onInit,
            onSegment: onSegment
        )
    }

    static func mux(
        demuxer: Demuxer,
        audioStreamIndex: Int32,
        sourceStartPTS: Int64,
        timeline: BlackCarrierTimeline,
        bridgeMode: AudioBridgeMode = .surroundCompat,
        sessionDirectory: URL,
        onInit: @escaping (Data) -> Void,
        onSegment: @escaping SegmentSink
    ) throws -> BlackCarrierAudioRenditionSummary {
        let writer = try makeWriter(
            demuxer: demuxer,
            audioStreamIndex: audioStreamIndex,
            sourceStartPTS: sourceStartPTS,
            timeline: timeline,
            bridgeMode: bridgeMode,
            sessionDirectory: sessionDirectory,
            onInit: onInit,
            onSegment: onSegment
        )
        demuxer.discardAllStreamsExcept([audioStreamIndex])
        while let sourcePacket = try demuxer.readPacket() {
            var sourcePacketToFree: UnsafeMutablePointer<AVPacket>? = sourcePacket
            defer { trackedPacketFree(&sourcePacketToFree) }
            try writer.consume(sourcePacket)
        }
        return try writer.finish()
    }

    private static let approvedTimelineTimeBase = AVRational(
        num: 1,
        den: BlackCarrierProfile.approved.timescale
    )

    private static func prepareRoute(
        sourceStream: UnsafeMutablePointer<AVStream>,
        sourceStartPTS: Int64,
        bridgeMode: AudioBridgeMode
    ) throws -> PreparedRoute {
        let sourceCodecParameters = sourceStream.pointee.codecpar!
        let sourceTimeBase = sourceStream.pointee.time_base
        let codecID = sourceCodecParameters.pointee.codec_id
        let compatibility = HLSVideoEngine.AudioCodecCompat.from(codecID)
        guard compatibility != .unsupported else {
            throw BlackCarrierAudioRenditionMuxerError.unsupportedCodec(
                rawCodecID: codecID.rawValue
            )
        }

        let hasCodecConfiguration =
            sourceCodecParameters.pointee.extradata != nil
            && sourceCodecParameters.pointee.extradata_size > 0
        let needsHEAACBridge =
            codecID == AV_CODEC_ID_AAC
            && HLSVideoEngine.aacRequiresBridge(
                profile: sourceCodecParameters.pointee.profile,
                frameSize: sourceCodecParameters.pointee.frame_size,
                hasASC: hasCodecConfiguration
            )
        let needsAACConfigurationBridge =
            codecID == AV_CODEC_ID_AAC && !hasCodecConfiguration
        let requiresBridge =
            compatibility.requiresBridge
            || needsHEAACBridge
            || needsAACConfigurationBridge

        if !requiresBridge {
            guard let owned = HLSVideoEngine.OwnedCodecParameters(
                copying: sourceCodecParameters
            ) else {
                throw BlackCarrierAudioRenditionMuxerError.codecParametersCopyFailed
            }
            normalizeFixedAudioFrameSize(owned.ptr)
            let config = MP4SegmentMuxer.AudioConfig(
                codecpar: UnsafePointer(owned.ptr),
                timeBase: sourceTimeBase
            )
            let probeResult = MP4SegmentMuxer.probeAudioWriteHeader(audio: config)
            if probeResult >= 0 {
                let fallbackPacketDuration = fallbackDuration(
                    codecParameters: sourceCodecParameters,
                    timeBase: sourceTimeBase
                )
                let declaredPaddingTicks = initialPaddingTicks(
                    codecParameters: sourceCodecParameters,
                    packetTimeBase: sourceTimeBase
                )
                let isAtmos =
                    codecID == AV_CODEC_ID_EAC3
                    && sourceCodecParameters.pointee.profile == 30
                let channels = isAtmos
                    ? "16/JOC"
                    : String(max(1, sourceCodecParameters.pointee.ch_layout.nb_channels))
                return PreparedRoute(
                    pipeline: .streamCopy(
                        codecString: compatibility.hlsCodecsString
                    ),
                    codecString: compatibility.hlsCodecsString,
                    channelsAttribute: channels,
                    audioConfig: config,
                    packetTimeBase: sourceTimeBase,
                    packetStartOffset: sourceStartPTS,
                    minimumRelativePacketTimestamp: -max(
                        declaredPaddingTicks,
                        fallbackPacketDuration * 2
                    ),
                    fallbackDuration: fallbackPacketDuration,
                    sourceCodecID: codecID,
                    sampleRate: sourceCodecParameters.pointee.sample_rate,
                    declaredCodecInitialPaddingSamples: Int64(
                        sourceCodecParameters.pointee.initial_padding
                    ),
                    ownedCodecParameters: owned,
                    bridge: nil
                )
            }
            if codecID == AV_CODEC_ID_EAC3,
               sourceCodecParameters.pointee.profile == 30 {
                throw BlackCarrierAudioRenditionMuxerError.atmosStreamCopyUnavailable(
                    code: probeResult
                )
            }
        }

        let bridge: AudioBridge
        do {
            bridge = try AudioBridge(
                srcCodecpar: sourceCodecParameters,
                srcTimeBase: sourceTimeBase,
                mode: bridgeMode
            )
        } catch {
            throw BlackCarrierAudioRenditionMuxerError.bridgeCreationFailed(
                reason: String(describing: error)
            )
        }
        guard let encoderCodecParameters = bridge.encoderCodecpar else {
            bridge.close()
            throw BlackCarrierAudioRenditionMuxerError.bridgeCreationFailed(
                reason: "encoder codec parameters unavailable"
            )
        }
        let config = MP4SegmentMuxer.AudioConfig(
            codecpar: UnsafePointer(encoderCodecParameters),
            timeBase: bridge.encoderTimeBase
        )
        let probeResult = MP4SegmentMuxer.probeAudioWriteHeader(audio: config)
        guard probeResult >= 0 else {
            bridge.close()
            throw BlackCarrierAudioRenditionMuxerError.bridgeHeaderRejected(
                code: probeResult
            )
        }
        let codecString: String
        switch bridgeMode {
        case .surroundCompat:
            codecString = "ec-3"
        case .lossless:
            codecString = "fLaC"
        }
        return PreparedRoute(
            pipeline: .bridge(mode: bridgeMode, codecString: codecString),
            codecString: codecString,
            channelsAttribute: String(
                max(1, encoderCodecParameters.pointee.ch_layout.nb_channels)
            ),
            audioConfig: config,
            packetTimeBase: bridge.encoderTimeBase,
            packetStartOffset: av_rescale_q(
                sourceStartPTS,
                sourceTimeBase,
                bridge.encoderTimeBase
            ),
            minimumRelativePacketTimestamp: -initialPaddingTicks(
                codecParameters: encoderCodecParameters,
                packetTimeBase: bridge.encoderTimeBase
            ),
            fallbackDuration: max(1, Int64(encoderCodecParameters.pointee.frame_size)),
            sourceCodecID: encoderCodecParameters.pointee.codec_id,
            sampleRate: encoderCodecParameters.pointee.sample_rate,
            declaredCodecInitialPaddingSamples: Int64(
                encoderCodecParameters.pointee.initial_padding
            ),
            ownedCodecParameters: nil,
            bridge: bridge
        )
    }

    private static func segmentOffset(
        forTimelinePTS pts: Int64,
        timeline: BlackCarrierTimeline
    ) -> Int {
        var low = 0
        var high = timeline.segments.count
        while low < high {
            let middle = low + (high - low) / 2
            if timeline.segments[middle].startTime.value <= pts {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return min(max(low - 1, 0), timeline.segments.count - 1)
    }

    private static func fallbackDuration(
        codecParameters: UnsafeMutablePointer<AVCodecParameters>,
        timeBase: AVRational
    ) -> Int64 {
        let parameters = codecParameters.pointee
        let frameSamples: Int64
        if parameters.frame_size > 0 {
            frameSamples = Int64(parameters.frame_size)
        } else {
            switch parameters.codec_id {
            case AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3:
                frameSamples = 1_536
            case AV_CODEC_ID_AAC:
                frameSamples = 1_024
            case AV_CODEC_ID_FLAC, AV_CODEC_ID_ALAC:
                frameSamples = 4_096
            default:
                frameSamples = 1_024
            }
        }
        guard parameters.sample_rate > 0,
              timeBase.num > 0,
              timeBase.den > 0 else {
            return 1
        }
        return max(
            1,
            frameSamples * Int64(timeBase.den)
                / (Int64(parameters.sample_rate) * Int64(timeBase.num))
        )
    }

    private static func initialPaddingTicks(
        codecParameters: UnsafeMutablePointer<AVCodecParameters>,
        packetTimeBase: AVRational
    ) -> Int64 {
        let parameters = codecParameters.pointee
        guard parameters.initial_padding > 0,
              parameters.sample_rate > 0,
              packetTimeBase.num > 0,
              packetTimeBase.den > 0 else {
            return 0
        }
        return av_rescale_q(
            Int64(parameters.initial_padding),
            AVRational(num: 1, den: parameters.sample_rate),
            packetTimeBase
        )
    }

    private static func normalizeFixedAudioFrameSize(
        _ codecParameters: UnsafeMutablePointer<AVCodecParameters>
    ) {
        guard codecParameters.pointee.frame_size <= 0 else { return }
        switch codecParameters.pointee.codec_id {
        case AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3:
            // ISO BMFF needs the fixed access-unit size to describe AC-3 family timing.
            // Some demuxers leave codecpar.frame_size unset even though the codec contract is 1536.
            codecParameters.pointee.frame_size = 1_536
        default:
            break
        }
    }

    private static func samples(
        forTicks ticks: Int64,
        packetTimeBase: AVRational,
        sampleRate: Int32
    ) -> Int64 {
        guard ticks > 0,
              sampleRate > 0,
              packetTimeBase.num > 0,
              packetTimeBase.den > 0 else {
            return 0
        }
        return av_rescale_q(
            ticks,
            packetTimeBase,
            AVRational(num: 1, den: sampleRate)
        )
    }

    private static func maxBufferedFragmentSeconds(
        for timeline: BlackCarrierTimeline
    ) -> Double {
        let longestSegment = timeline.segments.reduce(0.0) {
            max($0, CMTimeGetSeconds($1.duration))
        }
        return longestSegment + 1
    }

    private static func stripADTSHeaderIfPresent(
        _ packet: UnsafeMutablePointer<AVPacket>
    ) {
        guard let data = packet.pointee.data,
              packet.pointee.size >= 7,
              data[0] == 0xFF,
              (data[1] & 0xF0) == 0xF0 else {
            return
        }
        let headerLength: Int32 = (data[1] & 0x01) != 0 ? 7 : 9
        guard packet.pointee.size > headerLength else { return }
        packet.pointee.data = data.advanced(by: Int(headerLength))
        packet.pointee.size -= headerLength
    }
}
