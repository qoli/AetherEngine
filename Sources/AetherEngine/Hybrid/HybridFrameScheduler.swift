import CoreMedia

public enum HybridFrameEnqueueOutcome: Sendable, Equatable {
    case accepted
    case acceptedAfterDroppingOldest(count: Int)
    case staleGeneration
}

/// Bounded, generation-aware decoded-frame scheduler for the hybrid Metal route.
///
/// The scheduler does not own a clock. `selectFrame(for:)` is called with AVPlayer time, so it cannot
/// advance video based on decoder throughput or wall time. Frames that become obsolete before their
/// presentation deadline are intentionally dropped and counted; this is renderer pacing, not a fallback.
struct HybridFrameScheduler {
    private(set) var generation: UInt64 = 0
    private(set) var queuedFrames: [DecodedVideoFrame] = []
    private(set) var lastPresentedFrame: DecodedVideoFrame?
    private(set) var staleGenerationDrops = 0
    private(set) var queuePressureDrops = 0
    private(set) var timelineDrops = 0

    let maximumQueuedFrames: Int

    init(maximumQueuedFrames: Int = 12) {
        self.maximumQueuedFrames = max(1, maximumQueuedFrames)
    }

    mutating func beginGeneration(_ generation: UInt64) {
        self.generation = generation
        queuedFrames.removeAll(keepingCapacity: true)
        lastPresentedFrame = nil
    }

    mutating func flush() {
        queuedFrames.removeAll(keepingCapacity: true)
        lastPresentedFrame = nil
    }

    mutating func enqueue(_ frame: DecodedVideoFrame) -> HybridFrameEnqueueOutcome {
        guard frame.generation == generation else {
            staleGenerationDrops += 1
            return .staleGeneration
        }

        let insertionIndex = partitioningIndex { queued in
            CMTimeCompare(queued.presentationTime, frame.presentationTime) > 0
        }
        queuedFrames.insert(frame, at: insertionIndex)

        let overflow = max(0, queuedFrames.count - maximumQueuedFrames)
        guard overflow > 0 else { return .accepted }
        queuedFrames.removeFirst(overflow)
        queuePressureDrops += overflow
        return .acceptedAfterDroppingOldest(count: overflow)
    }

    /// Returns the latest frame whose PTS is not later than `masterTime + tolerance`.
    /// Future frames remain queued. The chosen frame is retained separately so the drawable can be refreshed
    /// without re-presenting an older timing candidate.
    mutating func selectFrame(for masterTime: CMTime, tolerance: CMTime) -> DecodedVideoFrame? {
        guard masterTime.isValid, masterTime.isNumeric else { return nil }
        let deadline = CMTimeAdd(masterTime, tolerance)
        var selectedIndex: Int?
        for (index, frame) in queuedFrames.enumerated() {
            if CMTimeCompare(frame.presentationTime, deadline) <= 0 {
                selectedIndex = index
            } else {
                break
            }
        }
        guard let selectedIndex else { return nil }

        if selectedIndex > 0 {
            timelineDrops += selectedIndex
            queuedFrames.removeFirst(selectedIndex)
        }
        let frame = queuedFrames.removeFirst()
        lastPresentedFrame = frame
        return frame
    }

    mutating func partitioningIndex(
        where predicate: (DecodedVideoFrame) -> Bool
    ) -> Int {
        var lower = 0
        var upper = queuedFrames.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if predicate(queuedFrames[middle]) {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        return lower
    }
}
