import CoreMedia
import Foundation
import Libavformat
import Libavutil

enum BlackCarrierSourceAxis {
    static func sourceStartPTS(
        demuxer: Demuxer,
        streamIndex: Int32
    ) -> Int64 {
        guard let stream = demuxer.stream(at: streamIndex) else {
            return 0
        }
        let formatStart = demuxer.formatStartTime
        if formatStart != Int64.min {
            return av_rescale_q(
                formatStart,
                AVRational(num: 1, den: AV_TIME_BASE),
                stream.pointee.time_base
            )
        }
        let videoStreamIndex = demuxer.videoStreamIndex
        if videoStreamIndex >= 0,
           let videoStream = demuxer.stream(at: videoStreamIndex),
           videoStream.pointee.start_time != Int64.min {
            return av_rescale_q(
                videoStream.pointee.start_time,
                videoStream.pointee.time_base,
                stream.pointee.time_base
            )
        }
        return stream.pointee.start_time == Int64.min
            ? 0
            : stream.pointee.start_time
    }

    static func timelineTime(
        timestamp: Int64,
        sourceStartPTS: Int64,
        timeBase: AVRational
    ) -> CMTime {
        guard timestamp != Int64.min,
              timeBase.num > 0,
              timeBase.den > 0 else {
            return .invalid
        }
        let relative = timestamp.subtractingReportingOverflow(
            sourceStartPTS
        )
        guard !relative.overflow else { return .invalid }
        let scaled = relative.partialValue
            .multipliedReportingOverflow(
                by: Int64(timeBase.num)
            )
        guard !scaled.overflow else { return .invalid }
        return CMTime(
            value: scaled.partialValue,
            timescale: timeBase.den
        )
    }

    static func streamTicks(
        for time: CMTime,
        timeBase: AVRational
    ) -> Int64? {
        guard time.isValid,
              time.isNumeric,
              time.timescale > 0,
              timeBase.num > 0,
              timeBase.den > 0 else {
            return nil
        }
        return av_rescale_q(
            time.value,
            AVRational(num: 1, den: time.timescale),
            timeBase
        )
    }
}
