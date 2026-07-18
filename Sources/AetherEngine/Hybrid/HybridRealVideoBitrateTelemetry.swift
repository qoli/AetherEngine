import Foundation

/// Completeness of the compressed-byte bitrate observation for the current
/// real-video generation.
public enum AetherHybridRealVideoBitrateObservationState:
    String,
    Sendable,
    Equatable
{
    case awaitingCompressedPackets
    case partial
    case complete
    case unavailable
}

/// Privacy-safe bitrate evidence from selected real-video packets already
/// admitted to the Hybrid decoder.
///
/// The average is `compressed video bytes * 8 / exact packet source duration`.
/// It excludes carrier video, carrier audio, container overhead, URLs and track
/// identity. Invalid or missing packet timing makes the observation unavailable;
/// no manifest, carrier or nominal-frame-rate estimate is substituted.
public struct AetherHybridRealVideoBitrateTelemetry:
    Sendable,
    Equatable
{
    /// Average selected-video bitrate in bits per second.
    public let observedAverageBitrate: Int?
    public let observedCompressedByteCount: Int
    public let observedSourceDurationSeconds: Double?
    public let observedPacketCount: Int
    public let state:
        AetherHybridRealVideoBitrateObservationState

    init(
        observedAverageBitrate: Int?,
        observedCompressedByteCount: Int,
        observedSourceDurationSeconds: Double?,
        observedPacketCount: Int,
        state: AetherHybridRealVideoBitrateObservationState
    ) {
        self.observedAverageBitrate = observedAverageBitrate
        self.observedCompressedByteCount =
            observedCompressedByteCount
        self.observedSourceDurationSeconds =
            observedSourceDurationSeconds
        self.observedPacketCount = observedPacketCount
        self.state = state
    }

    static func awaiting() -> Self {
        Self(
            observedAverageBitrate: nil,
            observedCompressedByteCount: 0,
            observedSourceDurationSeconds: nil,
            observedPacketCount: 0,
            state: .awaitingCompressedPackets
        )
    }

    static func unavailable() -> Self {
        Self(
            observedAverageBitrate: nil,
            observedCompressedByteCount: 0,
            observedSourceDurationSeconds: nil,
            observedPacketCount: 0,
            state: .unavailable
        )
    }
}

struct HybridRealVideoBitrateAccumulator {
    private var compressedByteCount = 0
    private var sourceDurationSeconds = 0.0
    private var packetCount = 0
    private var isComplete = false
    private var isUnavailable = false

    mutating func record(
        byteCount: Int,
        durationTicks: Int64,
        timeBaseNumerator: Int32,
        timeBaseDenominator: Int32
    ) {
        guard !isUnavailable else { return }
        guard byteCount > 0,
              durationTicks > 0,
              timeBaseNumerator > 0,
              timeBaseDenominator > 0 else {
            invalidate()
            return
        }
        let duration = Double(durationTicks)
            * Double(timeBaseNumerator)
            / Double(timeBaseDenominator)
        guard duration.isFinite, duration > 0 else {
            invalidate()
            return
        }
        let (newByteCount, byteOverflow) =
            compressedByteCount.addingReportingOverflow(
                byteCount
            )
        let (newPacketCount, packetOverflow) =
            packetCount.addingReportingOverflow(1)
        let newDuration = sourceDurationSeconds + duration
        guard !byteOverflow,
              !packetOverflow,
              newDuration.isFinite,
              newDuration > 0 else {
            invalidate()
            return
        }
        compressedByteCount = newByteCount
        packetCount = newPacketCount
        sourceDurationSeconds = newDuration
    }

    mutating func markComplete() {
        isComplete = true
    }

    mutating func reset() {
        self = Self()
    }

    func snapshot()
        -> AetherHybridRealVideoBitrateTelemetry
    {
        guard !isUnavailable else {
            return unavailableSnapshot()
        }
        guard packetCount > 0,
              compressedByteCount > 0,
              sourceDurationSeconds.isFinite,
              sourceDurationSeconds > 0 else {
            return isComplete
                ? unavailableSnapshot()
                : .awaiting()
        }
        let bitsPerSecond =
            Double(compressedByteCount) * 8
            / sourceDurationSeconds
        guard bitsPerSecond.isFinite,
              bitsPerSecond > 0,
              bitsPerSecond <= Double(Int.max) else {
            return unavailableSnapshot()
        }
        return AetherHybridRealVideoBitrateTelemetry(
            observedAverageBitrate:
                Int(bitsPerSecond.rounded()),
            observedCompressedByteCount:
                compressedByteCount,
            observedSourceDurationSeconds:
                sourceDurationSeconds,
            observedPacketCount: packetCount,
            state: isComplete ? .complete : .partial
        )
    }

    private mutating func invalidate() {
        isUnavailable = true
    }

    private func unavailableSnapshot()
        -> AetherHybridRealVideoBitrateTelemetry
    {
        AetherHybridRealVideoBitrateTelemetry(
            observedAverageBitrate: nil,
            observedCompressedByteCount:
                compressedByteCount,
            observedSourceDurationSeconds:
                sourceDurationSeconds > 0
                ? sourceDurationSeconds
                : nil,
            observedPacketCount: packetCount,
            state: .unavailable
        )
    }
}

protocol HybridRealVideoBitrateTelemetrySource:
    AnyObject
{
    var realVideoBitrateTelemetry:
        AetherHybridRealVideoBitrateTelemetry { get }
}
