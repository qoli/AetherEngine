import CoreMedia
import Foundation
import Libavcodec
import Libavformat
import Libavutil

enum BlackCarrierVideoMuxerError: Error, LocalizedError, Sendable, Equatable {
    case encodedSample(BlackCarrierEncodedSampleError)
    case sourceDemuxFailed(reason: String)
    case sourceVideoMissing
    case sourcePacketMissing
    case emptyTimeline
    case outputDirectoryFailed
    case muxerSetupFailed(reason: String)
    case packetAllocationFailed
    case packetReferenceFailed(code: Int32)
    case packetWriteFailed(segmentIndex: Int, code: Int32)
    case segmentFinalizeFailed(index: Int)
    case segmentReadFailed(index: Int)
    case initSegmentMissing

    public var errorDescription: String? {
        switch self {
        case .encodedSample(let error):
            return error.localizedDescription
        case .sourceDemuxFailed(let reason):
            return "Black carrier encoded sample could not be demuxed: \(reason)"
        case .sourceVideoMissing:
            return "Black carrier encoded sample has no video stream"
        case .sourcePacketMissing:
            return "Black carrier encoded sample has no reusable video packet"
        case .emptyTimeline:
            return "Black carrier timeline has no segments"
        case .outputDirectoryFailed:
            return "Black carrier temporary output directory could not be created"
        case .muxerSetupFailed(let reason):
            return "Black carrier fMP4 muxer could not be created: \(reason)"
        case .packetAllocationFailed:
            return "Black carrier packet allocation failed"
        case .packetReferenceFailed(let code):
            return "Black carrier packet reference failed (\(code))"
        case .packetWriteFailed(let segmentIndex, let code):
            return "Black carrier segment \(segmentIndex) packet write failed (\(code))"
        case .segmentFinalizeFailed(let index):
            return "Black carrier segment \(index) could not be finalized"
        case .segmentReadFailed(let index):
            return "Black carrier segment \(index) could not be read"
        case .initSegmentMissing:
            return "Black carrier muxer did not produce an init segment"
        }
    }
}

struct BlackCarrierVideoSegment: Sendable, Equatable {
    let index: Int
    let startTime: CMTime
    let duration: CMTime
    let data: Data

    init(timing: BlackCarrierSegmentTiming, data: Data) {
        index = timing.index
        startTime = timing.startTime
        duration = timing.duration
        self.data = data
    }
}

/// Ready-to-serve video-only fMP4 representation of a black-carrier timeline.
///
/// Alternate real-audio renditions are muxed separately and linked by the eventual carrier
/// master playlist. Keeping this representation video-only lets every source audio track remain
/// an AVKit-selectable rendition without duplicating the black video bytes per track.
struct BlackCarrierVideoPresentation: Sendable, Equatable {
    let initSegment: Data
    let segments: [BlackCarrierVideoSegment]
    let codecString: String
    let duration: CMTime

    init(initSegment: Data, segments: [BlackCarrierVideoSegment], duration: CMTime) {
        self.initSegment = initSegment
        self.segments = segments
        codecString = BlackCarrierProfile.approved.codecString
        self.duration = duration
    }
}

/// Builds fMP4 init/media segments by re-timestamping the approved pre-encoded black IDR.
///
/// This is deliberately synchronous and intended for an engine-owned worker queue. Runtime
/// work is packet reference + fMP4 mux only; no video decoder or encoder is created.
enum BlackCarrierVideoMuxer {
    static func build(
        timeline: BlackCarrierTimeline
    ) throws -> BlackCarrierVideoPresentation {
        guard let firstSegment = timeline.segments.first else {
            throw BlackCarrierVideoMuxerError.emptyTimeline
        }
        let encodedData: Data
        do {
            encodedData = try BlackCarrierEncodedSample.verifiedMP4Data()
        } catch let error as BlackCarrierEncodedSampleError {
            throw BlackCarrierVideoMuxerError.encodedSample(error)
        }

        let sourceDemuxer = Demuxer()
        do {
            try sourceDemuxer.open(reader: DataIOReader(data: encodedData))
        } catch {
            throw BlackCarrierVideoMuxerError.sourceDemuxFailed(reason: String(describing: error))
        }
        defer { sourceDemuxer.close() }

        let sourceVideoIndex = sourceDemuxer.videoStreamIndex
        guard sourceVideoIndex >= 0,
              let sourceStream = sourceDemuxer.stream(at: sourceVideoIndex),
              let sourceCodecParameters = sourceStream.pointee.codecpar else {
            throw BlackCarrierVideoMuxerError.sourceVideoMissing
        }
        guard let sourcePacket = try sourceDemuxer.readPacket() else {
            throw BlackCarrierVideoMuxerError.sourcePacketMissing
        }
        var sourcePacketToFree: UnsafeMutablePointer<AVPacket>? = sourcePacket
        defer { trackedPacketFree(&sourcePacketToFree) }

        let fileManager = FileManager.default
        let outputDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "AetherBlackCarrier-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw BlackCarrierVideoMuxerError.outputDirectoryFailed
        }
        defer { try? fileManager.removeItem(at: outputDirectory) }

        var capturedInitSegment: Data?
        let muxer: MP4SegmentMuxer
        do {
            muxer = try MP4SegmentMuxer(
                initialSegmentIndex: firstSegment.index,
                sessionDir: outputDirectory,
                video: MP4SegmentMuxer.VideoConfig(
                    codecpar: UnsafePointer(sourceCodecParameters),
                    timeBase: approvedTimeBase,
                    codecTagOverride: BlackCarrierProfile.approved.codecSampleEntry,
                    colorOverride: MP4SegmentMuxer.ColorOverride(
                        primaries: AVCOL_PRI_BT709,
                        trc: AVCOL_TRC_BT709,
                        space: AVCOL_SPC_BT709,
                        range: AVCOL_RANGE_MPEG
                    )
                ),
                audio: nil,
                maxBufferedFragmentSeconds: maxBufferedFragmentSeconds(for: timeline),
                onInitCaptured: { capturedInitSegment = $0 }
            )
        } catch {
            throw BlackCarrierVideoMuxerError.muxerSetupFailed(
                reason: String(describing: error)
            )
        }

        var outputSegments: [BlackCarrierVideoSegment] = []
        outputSegments.reserveCapacity(timeline.segments.count)

        for (offset, segment) in timeline.segments.enumerated() {
            for sample in segment.samples {
                try write(
                    sourcePacket: sourcePacket,
                    timing: sample,
                    segmentIndex: segment.index,
                    muxer: muxer
                )
            }

            let finalized: (path: URL, bytesWritten: Int)?
            if offset + 1 < timeline.segments.count {
                finalized = muxer.cutFragmentForNextSegment(
                    timeline.segments[offset + 1].index
                )
            } else {
                finalized = muxer.finalize()
            }
            guard let finalized else {
                throw BlackCarrierVideoMuxerError.segmentFinalizeFailed(index: segment.index)
            }
            guard let data = try? Data(contentsOf: finalized.path),
                  data.count == finalized.bytesWritten else {
                throw BlackCarrierVideoMuxerError.segmentReadFailed(index: segment.index)
            }
            outputSegments.append(BlackCarrierVideoSegment(timing: segment, data: data))
        }

        guard let initSegment = capturedInitSegment else {
            throw BlackCarrierVideoMuxerError.initSegmentMissing
        }
        return BlackCarrierVideoPresentation(
            initSegment: initSegment,
            segments: outputSegments,
            duration: timeline.duration
        )
    }

    private static let approvedTimeBase = AVRational(
        num: 1,
        den: BlackCarrierProfile.approved.timescale
    )

    private static func maxBufferedFragmentSeconds(
        for timeline: BlackCarrierTimeline
    ) -> Double {
        let longestSegment = timeline.segments.reduce(0.0) {
            max($0, CMTimeGetSeconds($1.duration))
        }
        return longestSegment + CMTimeGetSeconds(
            CMTime(
                value: BlackCarrierProfile.approved.frameDurationTicks,
                timescale: BlackCarrierProfile.approved.timescale
            )
        )
    }

    private static func write(
        sourcePacket: UnsafeMutablePointer<AVPacket>,
        timing: BlackCarrierSampleTiming,
        segmentIndex: Int,
        muxer: MP4SegmentMuxer
    ) throws {
        guard let packet = trackedPacketAlloc() else {
            throw BlackCarrierVideoMuxerError.packetAllocationFailed
        }
        var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
        defer { trackedPacketFree(&packetToFree) }

        let referenceResult = av_packet_ref(packet, sourcePacket)
        guard referenceResult >= 0 else {
            throw BlackCarrierVideoMuxerError.packetReferenceFailed(code: referenceResult)
        }

        let presentationTime = CMTimeConvertScale(
            timing.presentationTime,
            timescale: BlackCarrierProfile.approved.timescale,
            method: .default
        )
        let duration = CMTimeConvertScale(
            timing.duration,
            timescale: BlackCarrierProfile.approved.timescale,
            method: .default
        )
        packet.pointee.stream_index = muxer.videoOutputStreamIndex
        packet.pointee.pts = presentationTime.value
        packet.pointee.dts = presentationTime.value
        packet.pointee.duration = duration.value
        packet.pointee.flags |= AV_PKT_FLAG_KEY
        packet.pointee.pos = -1
        av_packet_rescale_ts(packet, approvedTimeBase, muxer.muxerVideoTimeBase)

        let writeResult = muxer.writePacket(packet)
        guard writeResult >= 0 else {
            throw BlackCarrierVideoMuxerError.packetWriteFailed(
                segmentIndex: segmentIndex,
                code: writeResult
            )
        }
    }
}
