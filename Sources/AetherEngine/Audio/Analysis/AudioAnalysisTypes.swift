import Foundation
import AVFAudio

/// Typed terminal states for an independent audio-analysis request. None of these states permits the
/// engine to retarget another audio track, seek the playback cursor, or substitute `installAudioTap()`.
public enum AudioAnalysisError: Error, Sendable, Equatable, LocalizedError {
    case invalidRange
    case noActiveSession
    case liveOrDVRUnsupported
    case sourceNotSeekable
    case sourceCannotCreateIndependentReader
    case audioTrackUnavailable(Int)
    case contentProtectionUnsupported
    case concurrentConsumer
    case cancelled
    case analysisFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRange: "Audio analysis range must be finite and have positive duration"
        case .noActiveSession: "No active AetherEngine session"
        case .liveOrDVRUnsupported: "Independent audio analysis supports seekable VOD only"
        case .sourceNotSeekable: "Source cannot seek independently for audio analysis"
        case .sourceCannotCreateIndependentReader: "Source cannot create an independent analysis reader"
        case .audioTrackUnavailable(let id): "Audio track \(id) is not available in this source"
        case .contentProtectionUnsupported: "Content protection prevents clear audio analysis"
        case .concurrentConsumer: "AudioAnalysisStream supports exactly one consumer"
        case .cancelled: "Audio analysis was cancelled"
        case .analysisFailed(let message): "Audio analysis failed: \(message)"
        }
    }
}

/// Immutable request bound to one source stream index and source-time range.
///
/// `audioTrackID` is a `TrackInfo.id` / FFmpeg stream index, not a user-facing ordinal. It is never
/// automatically retargeted after an AVKit audio-selection change.
public struct AudioAnalysisRequest: Sendable, Equatable {
    public let audioTrackID: Int
    public let range: Range<Double>

    public init(audioTrackID: Int, range: Range<Double>) throws {
        guard audioTrackID >= 0,
              range.lowerBound.isFinite,
              range.upperBound.isFinite,
              range.lowerBound >= 0,
              range.upperBound > range.lowerBound else {
            throw AudioAnalysisError.invalidRange
        }
        self.audioTrackID = audioTrackID
        self.range = range
    }
}

/// One demand-delivered PCM output block from `AudioAnalysisStream`.
///
/// The buffer is mono Float32, non-interleaved, 48 kHz. `sourceSamplePosition` is on the fixed 48 kHz
/// source-time axis, so it is exact at the output sample boundary and does not depend on an AVPlayer cursor.
public struct AudioAnalysisBuffer: @unchecked Sendable {
    public let pcm: AVAudioPCMBuffer
    public let sourceSamplePosition: Int64
    /// True when this buffer does not directly abut the preceding expected source sample. The first buffer is
    /// also marked when an imprecise source seek cannot provide the beginning of the requested range.
    public let isDiscontinuous: Bool
    public let sourceTime: Double

    init(pcm: AVAudioPCMBuffer, sourceSamplePosition: Int64, isDiscontinuous: Bool = false) {
        self.pcm = pcm
        self.sourceSamplePosition = sourceSamplePosition
        self.isDiscontinuous = isDiscontinuous
        self.sourceTime = Double(sourceSamplePosition) / 48_000
    }
}

public extension AetherEngine {
    /// Fixed output format for `audioAnalysisStream`. Kept distinct from the playback-following audio-tap
    /// property so a consumer cannot mistake its loss-tolerant contract for independent analysis.
    nonisolated static var audioAnalysisFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
    }
}
