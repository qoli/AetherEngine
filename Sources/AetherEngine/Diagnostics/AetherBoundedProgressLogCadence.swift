import Foundation

/// Privacy-safe progress evidence accepted by the bounded logging module.
///
/// The interface deliberately cannot carry a URL, request, header, token,
/// signature, path or error description. AVIO and URLSession callbacks must
/// first publish numeric evidence to their owner; this module itself is owned
/// and mutated only by the main-actor playback session.
enum AetherPlaybackProgressLogSample: Sendable, Equatable {
    case sourceBytes(
        phase: AetherPlaybackLivenessPhase,
        generation: UInt64,
        attempt: Int,
        uniqueBytes: Int64,
        progressUptime: TimeInterval,
        observedUptime: TimeInterval
    )
    case containerMilestone(
        phase: AetherPlaybackLivenessPhase,
        generation: UInt64,
        attempt: Int,
        preflightEpoch: UInt64,
        ordinal: UInt64,
        progressUptime: TimeInterval,
        observedUptime: TimeInterval
    )
    case routePreparationMilestone(
        phase: AetherPlaybackLivenessPhase,
        generation: UInt64,
        attempt: Int,
        ordinal: UInt64,
        progressUptime: TimeInterval,
        observedUptime: TimeInterval
    )
    case presentedFrame(
        phase: AetherPlaybackLivenessPhase,
        generation: UInt64,
        attempt: Int,
        frameGeneration: UInt64,
        frameSequence: UInt64,
        mediaTimeSeconds: Double,
        progressUptime: TimeInterval,
        observedUptime: TimeInterval
    )
    case loadedRange(
        phase: AetherPlaybackLivenessPhase,
        generation: UInt64,
        attempt: Int,
        fromSeconds: Double,
        toSeconds: Double,
        progressUptime: TimeInterval,
        observedUptime: TimeInterval
    )
}

enum AetherPlaybackProgressLogMetric: Sendable, Equatable {
    case sourceBytes(
        uniqueBytes: Int64,
        deltaBytes: Int64,
        wallRateBytesPerSecond: Int64,
        progressGapMilliseconds: Int64,
        lastProgressAgeMilliseconds: Int64
    )
    case containerMilestone(
        preflightEpoch: UInt64,
        ordinal: UInt64,
        deltaMilestones: UInt64,
        progressGapMilliseconds: Int64,
        lastProgressAgeMilliseconds: Int64
    )
    case routePreparationMilestone(
        ordinal: UInt64,
        deltaMilestones: UInt64,
        progressGapMilliseconds: Int64,
        lastProgressAgeMilliseconds: Int64
    )
    case presentedFrame(
        frameGeneration: UInt64,
        frameSequence: UInt64,
        fromMediaTimeSeconds: Double,
        toMediaTimeSeconds: Double,
        deltaMediaTimeSeconds: Double,
        wallRateMediaPerSecond: Double,
        progressGapMilliseconds: Int64,
        lastProgressAgeMilliseconds: Int64
    )
    case loadedRange(
        fromSeconds: Double,
        toSeconds: Double,
        deltaSeconds: Double,
        wallRateRangeSecondsPerSecond: Double,
        progressGapMilliseconds: Int64,
        lastProgressAgeMilliseconds: Int64
    )
}

struct AetherPlaybackProgressLogEmission:
    Sendable,
    Equatable
{
    let phase: AetherPlaybackLivenessPhase
    let generation: UInt64
    let attempt: Int
    let metric: AetherPlaybackProgressLogMetric

    /// Stable structured fields for `EngineLog`. Every represented value is
    /// public playback state or a numeric progress measurement.
    var logFields: String {
        let common =
            "phase=\(phase.rawValue) "
            + "generation=\(generation) "
            + "attempt=\(attempt) "
        switch metric {
        case .sourceBytes(
            let uniqueBytes,
            let deltaBytes,
            let wallRateBytesPerSecond,
            let progressGapMilliseconds,
            let lastProgressAgeMilliseconds
        ):
            return "progress_kind=source_bytes "
                + common
                + "unique_bytes=\(uniqueBytes) "
                + "delta_bytes=\(deltaBytes) "
                + "wall_rate_bps=\(wallRateBytesPerSecond) "
                + "progress_gap_ms=\(progressGapMilliseconds) "
                + "last_progress_age_ms="
                + "\(lastProgressAgeMilliseconds)"
        case .containerMilestone(
            let preflightEpoch,
            let ordinal,
            let deltaMilestones,
            let progressGapMilliseconds,
            let lastProgressAgeMilliseconds
        ):
            return "progress_kind=container_milestone "
                + common
                + "preflight_epoch=\(preflightEpoch) "
                + "milestone_ordinal=\(ordinal) "
                + "delta_milestones=\(deltaMilestones) "
                + "progress_gap_ms=\(progressGapMilliseconds) "
                + "last_progress_age_ms="
                + "\(lastProgressAgeMilliseconds)"
        case .routePreparationMilestone(
            let ordinal,
            let deltaMilestones,
            let progressGapMilliseconds,
            let lastProgressAgeMilliseconds
        ):
            return "progress_kind=route_preparation_milestone "
                + common
                + "milestone_ordinal=\(ordinal) "
                + "delta_milestones=\(deltaMilestones) "
                + "progress_gap_ms=\(progressGapMilliseconds) "
                + "last_progress_age_ms="
                + "\(lastProgressAgeMilliseconds)"
        case .presentedFrame(
            let frameGeneration,
            let frameSequence,
            let fromMediaTimeSeconds,
            let toMediaTimeSeconds,
            let deltaMediaTimeSeconds,
            let wallRateMediaPerSecond,
            let progressGapMilliseconds,
            let lastProgressAgeMilliseconds
        ):
            return "progress_kind=presented_frame "
                + common
                + "frame_generation=\(frameGeneration) "
                + "frame_sequence=\(frameSequence) "
                + "from_media_seconds="
                + "\(Self.fixed(fromMediaTimeSeconds)) "
                + "to_media_seconds="
                + "\(Self.fixed(toMediaTimeSeconds)) "
                + "delta_media_seconds="
                + "\(Self.fixed(deltaMediaTimeSeconds)) "
                + "wall_rate_media_per_second="
                + "\(Self.fixed(wallRateMediaPerSecond)) "
                + "progress_gap_ms=\(progressGapMilliseconds) "
                + "last_progress_age_ms="
                + "\(lastProgressAgeMilliseconds)"
        case .loadedRange(
            let fromSeconds,
            let toSeconds,
            let deltaSeconds,
            let wallRateRangeSecondsPerSecond,
            let progressGapMilliseconds,
            let lastProgressAgeMilliseconds
        ):
            return "progress_kind=loaded_range "
                + common
                + "from_seconds=\(Self.fixed(fromSeconds)) "
                + "to_seconds=\(Self.fixed(toSeconds)) "
                + "delta_seconds=\(Self.fixed(deltaSeconds)) "
                + "wall_rate_range_seconds_per_second="
                + "\(Self.fixed(wallRateRangeSecondsPerSecond)) "
                + "progress_gap_ms=\(progressGapMilliseconds) "
                + "last_progress_age_ms="
                + "\(lastProgressAgeMilliseconds)"
        }
    }

    private static func fixed(_ value: Double) -> String {
        String(
            format: "%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            arguments: [value]
        )
    }
}

struct AetherPlaybackProgressLogDecision:
    Sendable,
    Equatable
{
    let acceptedProgress: Bool
    let emission: AetherPlaybackProgressLogEmission?

    static let ignored = Self(
        acceptedProgress: false,
        emission: nil
    )

    static func accepted(
        _ emission: AetherPlaybackProgressLogEmission?
    ) -> Self {
        Self(acceptedProgress: true, emission: emission)
    }
}

struct AetherClassificationProgressToken:
    Sendable,
    Equatable
{
    let epoch: UInt64
    let readerGeneration: UInt64
}

/// Thread-safe numeric handoff for a classifier callback that may run away
/// from the main actor. The owner drains the high-water before retiring the
/// reader token, so the final valid callback is neither lost nor allowed to
/// arrive after classification ownership has ended.
final class AetherClassificationProgressRelay:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var maximumVerifiedByteCount = 0

    func record(_ verifiedByteCount: Int) {
        guard verifiedByteCount > 0 else { return }
        lock.withLock {
            maximumVerifiedByteCount = max(
                maximumVerifiedByteCount,
                verifiedByteCount
            )
        }
    }

    var snapshot: Int {
        lock.withLock { maximumVerifiedByteCount }
    }
}

/// Main-actor ownership fence for classifier retry callbacks.
///
/// A retry reader receives a new generation without resetting the surrounding
/// classification epoch. Therefore replay remains deduplicated by verified
/// prefix count, while a retired reader's delayed larger callback is rejected.
@MainActor
struct AetherClassificationProgressFence: Equatable {
    private(set) var epoch: UInt64 = 0
    private var readerGeneration: UInt64 = 0
    private var activeReaderGeneration: UInt64?

    @discardableResult
    mutating func beginEpoch() -> UInt64 {
        epoch &+= 1
        readerGeneration = 0
        activeReaderGeneration = nil
        return epoch
    }

    mutating func beginReader()
        -> AetherClassificationProgressToken
    {
        precondition(epoch > 0)
        readerGeneration &+= 1
        activeReaderGeneration = readerGeneration
        return AetherClassificationProgressToken(
            epoch: epoch,
            readerGeneration: readerGeneration
        )
    }

    mutating func retire(
        _ token: AetherClassificationProgressToken
    ) {
        guard token.epoch == epoch,
              token.readerGeneration
                == activeReaderGeneration else {
            return
        }
        activeReaderGeneration = nil
    }

    func admits(
        _ token: AetherClassificationProgressToken
    ) -> Bool {
        token.epoch == epoch
            && token.readerGeneration
                == activeReaderGeneration
    }
}

/// Hard-caps durable progress output while preserving useful evidence.
///
/// Each fixed progress kind emits its first accepted sample immediately, then
/// at most once per `minimumIntervalSeconds`. The number of kinds is constant,
/// so total output is bounded independently of read/frame callback volume.
/// Suppressed samples still advance their constant-memory validation cursor.
@MainActor
struct AetherBoundedProgressLogCadence: Equatable {
    private struct SourceState: Equatable {
        var lastObservedBytes: Int64 = 0
        var lastProgressUptime: TimeInterval?
        var lastEmittedBytes: Int64 = 0
        var lastEmissionUptime: TimeInterval?
        var lastEmissionProgressUptime: TimeInterval?
    }

    private struct ContainerState: Equatable {
        var epoch: UInt64 = 0
        var lastObservedOrdinal: UInt64 = 0
        var lastProgressUptime: TimeInterval?
        var lastEmissionUptime: TimeInterval?
        var lastEmittedOrdinal: UInt64 = 0
    }

    private struct RoutePreparationState: Equatable {
        var generation: UInt64 = 0
        var lastObservedOrdinal: UInt64 = 0
        var lastProgressUptime: TimeInterval?
        var lastEmissionUptime: TimeInterval?
        var lastEmittedOrdinal: UInt64 = 0
    }

    private struct PresentedFrameState: Equatable {
        var frameGeneration: UInt64 = 0
        var frameSequence: UInt64 = 0
        var mediaTimeSeconds: Double?
        var lastProgressUptime: TimeInterval?
        var lastEmissionUptime: TimeInterval?
        var lastEmittedFrameGeneration: UInt64?
        var lastEmittedMediaTimeSeconds: Double?
        var lastEmissionProgressUptime: TimeInterval?
    }

    private struct LoadedRangeState: Equatable {
        var generation: UInt64 = 0
        var lastObservedEndSeconds: Double = 0
        var lastProgressUptime: TimeInterval?
        var lastEmissionUptime: TimeInterval?
        var lastEmittedEndSeconds: Double?
        var lastEmissionProgressUptime: TimeInterval?
    }

    private let minimumIntervalSeconds: TimeInterval
    private var epochStartedUptime: TimeInterval?
    private var source = SourceState()
    private var container = ContainerState()
    private var routePreparation =
        RoutePreparationState()
    private var presentedFrame = PresentedFrameState()
    private var loadedRange = LoadedRangeState()

    init(minimumIntervalSeconds: TimeInterval = 15) {
        precondition(
            minimumIntervalSeconds.isFinite
                && minimumIntervalSeconds > 0
        )
        self.minimumIntervalSeconds = minimumIntervalSeconds
    }

    mutating func reset(now: TimeInterval) {
        epochStartedUptime = Self.normalizedUptime(
            now,
            floor: nil
        )
        source = SourceState()
        container = ContainerState()
        routePreparation = RoutePreparationState()
        presentedFrame = PresentedFrameState()
        loadedRange = LoadedRangeState()
    }

    mutating func record(
        _ sample: AetherPlaybackProgressLogSample
    ) -> AetherPlaybackProgressLogDecision {
        switch sample {
        case .sourceBytes(
            let phase,
            let generation,
            let attempt,
            let uniqueBytes,
            let progressUptime,
            let observedUptime
        ):
            recordSourceBytes(
                phase: phase,
                generation: generation,
                attempt: attempt,
                uniqueBytes: uniqueBytes,
                progressUptime: progressUptime,
                observedUptime: observedUptime
            )
        case .containerMilestone(
            let phase,
            let generation,
            let attempt,
            let preflightEpoch,
            let ordinal,
            let progressUptime,
            let observedUptime
        ):
            recordContainerMilestone(
                phase: phase,
                generation: generation,
                attempt: attempt,
                preflightEpoch: preflightEpoch,
                ordinal: ordinal,
                progressUptime: progressUptime,
                observedUptime: observedUptime
            )
        case .routePreparationMilestone(
            let phase,
            let generation,
            let attempt,
            let ordinal,
            let progressUptime,
            let observedUptime
        ):
            recordRoutePreparationMilestone(
                phase: phase,
                generation: generation,
                attempt: attempt,
                ordinal: ordinal,
                progressUptime: progressUptime,
                observedUptime: observedUptime
            )
        case .presentedFrame(
            let phase,
            let generation,
            let attempt,
            let frameGeneration,
            let frameSequence,
            let mediaTimeSeconds,
            let progressUptime,
            let observedUptime
        ):
            recordPresentedFrame(
                phase: phase,
                generation: generation,
                attempt: attempt,
                frameGeneration: frameGeneration,
                frameSequence: frameSequence,
                mediaTimeSeconds: mediaTimeSeconds,
                progressUptime: progressUptime,
                observedUptime: observedUptime
            )
        case .loadedRange(
            let phase,
            let generation,
            let attempt,
            let fromSeconds,
            let toSeconds,
            let progressUptime,
            let observedUptime
        ):
            recordLoadedRange(
                phase: phase,
                generation: generation,
                attempt: attempt,
                fromSeconds: fromSeconds,
                toSeconds: toSeconds,
                progressUptime: progressUptime,
                observedUptime: observedUptime
            )
        }
    }

    private mutating func recordSourceBytes(
        phase: AetherPlaybackLivenessPhase,
        generation: UInt64,
        attempt: Int,
        uniqueBytes: Int64,
        progressUptime: TimeInterval,
        observedUptime: TimeInterval
    ) -> AetherPlaybackProgressLogDecision {
        guard attempt >= 0,
              uniqueBytes > source.lastObservedBytes else {
            return .ignored
        }
        let times = normalizedTimes(
            progressUptime: progressUptime,
            observedUptime: observedUptime,
            lastProgressUptime: source.lastProgressUptime
        )
        let progressGap = progressGapMilliseconds(
            current: times.progress,
            previous: source.lastProgressUptime
        )
        source.lastObservedBytes = uniqueBytes
        source.lastProgressUptime = times.progress

        guard shouldEmit(
            now: times.observed,
            lastEmission: source.lastEmissionUptime
        ) else {
            return .accepted(nil)
        }
        let delta = uniqueBytes - source.lastEmittedBytes
        guard delta > 0 else { return .ignored }
        let rate = wallRate(
            amount: Double(delta),
            progressUptime: times.progress,
            lastEmissionProgressUptime:
                source.lastEmissionProgressUptime
        )
        source.lastEmittedBytes = uniqueBytes
        source.lastEmissionUptime = times.observed
        source.lastEmissionProgressUptime = times.progress
        return .accepted(
            AetherPlaybackProgressLogEmission(
                phase: phase,
                generation: generation,
                attempt: attempt,
                metric: .sourceBytes(
                    uniqueBytes: uniqueBytes,
                    deltaBytes: delta,
                    wallRateBytesPerSecond:
                        Self.boundedInt64(rate),
                    progressGapMilliseconds: progressGap,
                    lastProgressAgeMilliseconds:
                        Self.milliseconds(
                            times.observed - times.progress
                        )
                )
            )
        )
    }

    private mutating func recordContainerMilestone(
        phase: AetherPlaybackLivenessPhase,
        generation: UInt64,
        attempt: Int,
        preflightEpoch: UInt64,
        ordinal: UInt64,
        progressUptime: TimeInterval,
        observedUptime: TimeInterval
    ) -> AetherPlaybackProgressLogDecision {
        guard attempt >= 0,
              preflightEpoch >= container.epoch else {
            return .ignored
        }
        if preflightEpoch > container.epoch {
            container.epoch = preflightEpoch
            container.lastObservedOrdinal = 0
            container.lastEmittedOrdinal = 0
            container.lastProgressUptime = nil
        }
        guard ordinal > container.lastObservedOrdinal else {
            return .ignored
        }
        let times = normalizedTimes(
            progressUptime: progressUptime,
            observedUptime: observedUptime,
            lastProgressUptime:
                container.lastProgressUptime
        )
        let progressGap = progressGapMilliseconds(
            current: times.progress,
            previous: container.lastProgressUptime
        )
        container.lastObservedOrdinal = ordinal
        container.lastProgressUptime = times.progress

        guard shouldEmit(
            now: times.observed,
            lastEmission: container.lastEmissionUptime
        ) else {
            return .accepted(nil)
        }
        let delta = ordinal - container.lastEmittedOrdinal
        container.lastEmittedOrdinal = ordinal
        container.lastEmissionUptime = times.observed
        return .accepted(
            AetherPlaybackProgressLogEmission(
                phase: phase,
                generation: generation,
                attempt: attempt,
                metric: .containerMilestone(
                    preflightEpoch: preflightEpoch,
                    ordinal: ordinal,
                    deltaMilestones: delta,
                    progressGapMilliseconds: progressGap,
                    lastProgressAgeMilliseconds:
                        Self.milliseconds(
                            times.observed - times.progress
                        )
                )
            )
        )
    }

    private mutating func recordRoutePreparationMilestone(
        phase: AetherPlaybackLivenessPhase,
        generation: UInt64,
        attempt: Int,
        ordinal: UInt64,
        progressUptime: TimeInterval,
        observedUptime: TimeInterval
    ) -> AetherPlaybackProgressLogDecision {
        guard attempt >= 0,
              generation >= routePreparation.generation else {
            return .ignored
        }
        if generation > routePreparation.generation {
            routePreparation.generation = generation
            routePreparation.lastObservedOrdinal = 0
            routePreparation.lastEmittedOrdinal = 0
            routePreparation.lastProgressUptime = nil
        }
        guard ordinal
                > routePreparation.lastObservedOrdinal else {
            return .ignored
        }
        let times = normalizedTimes(
            progressUptime: progressUptime,
            observedUptime: observedUptime,
            lastProgressUptime:
                routePreparation.lastProgressUptime
        )
        let progressGap = progressGapMilliseconds(
            current: times.progress,
            previous:
                routePreparation.lastProgressUptime
        )
        routePreparation.lastObservedOrdinal = ordinal
        routePreparation.lastProgressUptime = times.progress

        guard shouldEmit(
            now: times.observed,
            lastEmission:
                routePreparation.lastEmissionUptime
        ) else {
            return .accepted(nil)
        }
        let delta =
            ordinal - routePreparation.lastEmittedOrdinal
        routePreparation.lastEmittedOrdinal = ordinal
        routePreparation.lastEmissionUptime = times.observed
        return .accepted(
            AetherPlaybackProgressLogEmission(
                phase: phase,
                generation: generation,
                attempt: attempt,
                metric: .routePreparationMilestone(
                    ordinal: ordinal,
                    deltaMilestones: delta,
                    progressGapMilliseconds: progressGap,
                    lastProgressAgeMilliseconds:
                        Self.milliseconds(
                            times.observed - times.progress
                        )
                )
            )
        )
    }

    private mutating func recordPresentedFrame(
        phase: AetherPlaybackLivenessPhase,
        generation: UInt64,
        attempt: Int,
        frameGeneration: UInt64,
        frameSequence: UInt64,
        mediaTimeSeconds: Double,
        progressUptime: TimeInterval,
        observedUptime: TimeInterval
    ) -> AetherPlaybackProgressLogDecision {
        guard attempt >= 0,
              mediaTimeSeconds.isFinite,
              mediaTimeSeconds >= 0,
              frameGeneration
                >= presentedFrame.frameGeneration,
              frameSequence
                > presentedFrame.frameSequence else {
            return .ignored
        }
        let isNewFrameGeneration =
            frameGeneration
                > presentedFrame.frameGeneration
        if !isNewFrameGeneration,
           let previousMediaTime =
                presentedFrame.mediaTimeSeconds,
           mediaTimeSeconds <= previousMediaTime {
            return .ignored
        }
        let times = normalizedTimes(
            progressUptime: progressUptime,
            observedUptime: observedUptime,
            lastProgressUptime:
                presentedFrame.lastProgressUptime
        )
        let progressGap = progressGapMilliseconds(
            current: times.progress,
            previous: presentedFrame.lastProgressUptime
        )
        presentedFrame.frameGeneration =
            frameGeneration
        presentedFrame.frameSequence = frameSequence
        presentedFrame.mediaTimeSeconds =
            mediaTimeSeconds
        presentedFrame.lastProgressUptime =
            times.progress

        guard shouldEmit(
            now: times.observed,
            lastEmission:
                presentedFrame.lastEmissionUptime
        ) else {
            return .accepted(nil)
        }
        let canContinueEmissionEpoch =
            presentedFrame.lastEmittedFrameGeneration
                == frameGeneration
        let from = canContinueEmissionEpoch
            ? (presentedFrame
                .lastEmittedMediaTimeSeconds
                ?? mediaTimeSeconds)
            : mediaTimeSeconds
        let delta = max(0, mediaTimeSeconds - from)
        let rate = wallRate(
            amount: delta,
            progressUptime: times.progress,
            lastEmissionProgressUptime:
                presentedFrame
                    .lastEmissionProgressUptime
        )
        presentedFrame.lastEmissionUptime =
            times.observed
        presentedFrame.lastEmittedFrameGeneration =
            frameGeneration
        presentedFrame.lastEmittedMediaTimeSeconds =
            mediaTimeSeconds
        presentedFrame.lastEmissionProgressUptime =
            times.progress
        return .accepted(
            AetherPlaybackProgressLogEmission(
                phase: phase,
                generation: generation,
                attempt: attempt,
                metric: .presentedFrame(
                    frameGeneration: frameGeneration,
                    frameSequence: frameSequence,
                    fromMediaTimeSeconds: from,
                    toMediaTimeSeconds: mediaTimeSeconds,
                    deltaMediaTimeSeconds: delta,
                    wallRateMediaPerSecond: rate,
                    progressGapMilliseconds: progressGap,
                    lastProgressAgeMilliseconds:
                        Self.milliseconds(
                            times.observed - times.progress
                        )
                )
            )
        )
    }

    private mutating func recordLoadedRange(
        phase: AetherPlaybackLivenessPhase,
        generation: UInt64,
        attempt: Int,
        fromSeconds: Double,
        toSeconds: Double,
        progressUptime: TimeInterval,
        observedUptime: TimeInterval
    ) -> AetherPlaybackProgressLogDecision {
        guard attempt >= 0,
              fromSeconds.isFinite,
              toSeconds.isFinite,
              fromSeconds >= 0,
              toSeconds > fromSeconds,
              generation >= loadedRange.generation else {
            return .ignored
        }
        if generation > loadedRange.generation {
            loadedRange.generation = generation
            loadedRange.lastObservedEndSeconds = 0
            loadedRange.lastEmittedEndSeconds = nil
            loadedRange.lastProgressUptime = nil
        }
        guard toSeconds
                > loadedRange.lastObservedEndSeconds else {
            return .ignored
        }
        let times = normalizedTimes(
            progressUptime: progressUptime,
            observedUptime: observedUptime,
            lastProgressUptime:
                loadedRange.lastProgressUptime
        )
        let progressGap = progressGapMilliseconds(
            current: times.progress,
            previous: loadedRange.lastProgressUptime
        )
        loadedRange.lastObservedEndSeconds = toSeconds
        loadedRange.lastProgressUptime = times.progress

        guard shouldEmit(
            now: times.observed,
            lastEmission: loadedRange.lastEmissionUptime
        ) else {
            return .accepted(nil)
        }
        let aggregateFrom = min(
            toSeconds,
            loadedRange.lastEmittedEndSeconds
                ?? fromSeconds
        )
        let delta = toSeconds - aggregateFrom
        let rate = wallRate(
            amount: delta,
            progressUptime: times.progress,
            lastEmissionProgressUptime:
                loadedRange.lastEmissionProgressUptime
        )
        loadedRange.lastEmissionUptime = times.observed
        loadedRange.lastEmittedEndSeconds = toSeconds
        loadedRange.lastEmissionProgressUptime = times.progress
        return .accepted(
            AetherPlaybackProgressLogEmission(
                phase: phase,
                generation: generation,
                attempt: attempt,
                metric: .loadedRange(
                    fromSeconds: aggregateFrom,
                    toSeconds: toSeconds,
                    deltaSeconds: delta,
                    wallRateRangeSecondsPerSecond: rate,
                    progressGapMilliseconds: progressGap,
                    lastProgressAgeMilliseconds:
                        Self.milliseconds(
                            times.observed - times.progress
                        )
                )
            )
        )
    }

    private func normalizedTimes(
        progressUptime: TimeInterval,
        observedUptime: TimeInterval,
        lastProgressUptime: TimeInterval?
    ) -> (progress: TimeInterval, observed: TimeInterval) {
        let progress = Self.normalizedUptime(
            progressUptime,
            floor: lastProgressUptime
                ?? epochStartedUptime
        )
        return (
            progress,
            Self.normalizedUptime(
                observedUptime,
                floor: progress
            )
        )
    }

    private func progressGapMilliseconds(
        current: TimeInterval,
        previous: TimeInterval?
    ) -> Int64 {
        Self.milliseconds(
            current - (
                previous
                    ?? epochStartedUptime
                    ?? current
            )
        )
    }

    private func shouldEmit(
        now: TimeInterval,
        lastEmission: TimeInterval?
    ) -> Bool {
        guard let lastEmission else { return true }
        return now - lastEmission
            >= minimumIntervalSeconds
    }

    private func wallRate(
        amount: Double,
        progressUptime: TimeInterval,
        lastEmissionProgressUptime: TimeInterval?
    ) -> Double {
        let window = max(
            0,
            progressUptime - (
                lastEmissionProgressUptime
                    ?? epochStartedUptime
                    ?? progressUptime
            )
        )
        return window > 0 ? amount / window : 0
    }

    private static func normalizedUptime(
        _ value: TimeInterval,
        floor: TimeInterval?
    ) -> TimeInterval {
        let nonnegativeFloor = max(0, floor ?? 0)
        guard value.isFinite else {
            return nonnegativeFloor
        }
        return max(nonnegativeFloor, value, 0)
    }

    private static func milliseconds(
        _ seconds: TimeInterval
    ) -> Int64 {
        boundedInt64(max(0, seconds) * 1_000)
    }

    private static func boundedInt64(_ value: Double) -> Int64 {
        if value.isNaN || value <= 0 { return 0 }
        if value == .infinity
            || value >= Double(Int64.max) {
            return Int64.max
        }
        return Int64(value.rounded())
    }
}
