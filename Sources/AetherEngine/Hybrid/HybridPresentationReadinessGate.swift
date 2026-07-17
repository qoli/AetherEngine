import CoreMedia

enum HybridPresentationReadinessError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case invalidTargetTime
    case invalidTolerance
    case carrierFailed(reason: String)
    case decoderFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidTargetTime:
            return "Hybrid presentation readiness requires a numeric target time"
        case .invalidTolerance:
            return "Hybrid presentation readiness tolerances must be finite and non-negative"
        case .carrierFailed(let reason):
            return "Hybrid carrier readiness failed: \(reason)"
        case .decoderFailed(let reason):
            return "Hybrid decoder readiness failed: \(reason)"
        }
    }
}

enum HybridPresentationReadinessState: Sendable, Equatable {
    case idle
    case waiting(
        generation: UInt64,
        carrierReady: Bool,
        decodedFrameReady: Bool
    )
    case ready(
        generation: UInt64,
        framePresentationTime: CMTime
    )
    case failed(
        generation: UInt64,
        error: HybridPresentationReadinessError
    )
}

enum HybridPresentationReadinessSignalOutcome: Sendable, Equatable {
    case acceptedWaiting
    case becameReady
    case alreadyReady
    case staleGeneration
    case frameOutsideTargetWindow
    case terminalFailure
}

/// Generation-scoped gate that prevents carrier audio from starting before real video is ready.
///
/// The carrier signal means the AVPlayer transport is ready at startup, or its seek completion has
/// landed for a later generation. A decoded frame qualifies only when its presentation interval
/// intersects the target window. Decoder pre-roll from an older point is rejected by the session
/// before renderer admission, so it cannot fill the presentation queue or reveal pre-seek content.
struct HybridPresentationReadinessGate {
    private(set) var state: HybridPresentationReadinessState = .idle

    private var generation: UInt64 = 0
    private var targetTime: CMTime = .invalid
    private var toleranceBefore: CMTime = .zero
    private var toleranceAfter: CMTime = .zero
    private var carrierReady = false
    private var readyFramePresentationTime: CMTime?

    mutating func beginGeneration(
        _ generation: UInt64,
        targetTime: CMTime,
        toleranceBefore: CMTime = CMTime(
            seconds: 0.1,
            preferredTimescale: 600
        ),
        toleranceAfter: CMTime = CMTime(
            seconds: 0.25,
            preferredTimescale: 600
        ),
        carrierAlreadyReady: Bool = false
    ) throws {
        guard targetTime.isValid, targetTime.isNumeric else {
            throw HybridPresentationReadinessError.invalidTargetTime
        }
        guard Self.isValidTolerance(toleranceBefore),
              Self.isValidTolerance(toleranceAfter) else {
            throw HybridPresentationReadinessError.invalidTolerance
        }

        self.generation = generation
        self.targetTime = targetTime
        self.toleranceBefore = toleranceBefore
        self.toleranceAfter = toleranceAfter
        carrierReady = carrierAlreadyReady
        readyFramePresentationTime = nil
        state = .waiting(
            generation: generation,
            carrierReady: carrierAlreadyReady,
            decodedFrameReady: false
        )
    }

    mutating func markCarrierReady(
        generation candidateGeneration: UInt64
    ) -> HybridPresentationReadinessSignalOutcome {
        guard candidateGeneration == generation else {
            return .staleGeneration
        }
        switch state {
        case .ready:
            return .alreadyReady
        case .failed:
            return .terminalFailure
        case .idle:
            return .staleGeneration
        case .waiting:
            carrierReady = true
            return refreshWaitingState()
        }
    }

    mutating func considerDecodedFrame(
        _ frame: DecodedVideoFrame
    ) -> HybridPresentationReadinessSignalOutcome {
        guard frame.generation == generation else {
            return .staleGeneration
        }
        switch state {
        case .ready:
            return .alreadyReady
        case .failed:
            return .terminalFailure
        case .idle:
            return .staleGeneration
        case .waiting:
            break
        }
        guard Self.frameIntersectsTargetWindow(
            frame: frame,
            targetTime: targetTime,
            toleranceBefore: toleranceBefore,
            toleranceAfter: toleranceAfter
        ) else {
            return .frameOutsideTargetWindow
        }
        readyFramePresentationTime = frame.presentationTime
        return refreshWaitingState()
    }

    mutating func failCarrier(
        generation candidateGeneration: UInt64,
        reason: String
    ) -> HybridPresentationReadinessSignalOutcome {
        fail(
            generation: candidateGeneration,
            error: .carrierFailed(reason: reason)
        )
    }

    mutating func failDecoder(
        generation candidateGeneration: UInt64,
        reason: String
    ) -> HybridPresentationReadinessSignalOutcome {
        fail(
            generation: candidateGeneration,
            error: .decoderFailed(reason: reason)
        )
    }

    private mutating func refreshWaitingState()
        -> HybridPresentationReadinessSignalOutcome
    {
        if carrierReady, let framePresentationTime = readyFramePresentationTime {
            state = .ready(
                generation: generation,
                framePresentationTime: framePresentationTime
            )
            return .becameReady
        }
        state = .waiting(
            generation: generation,
            carrierReady: carrierReady,
            decodedFrameReady: readyFramePresentationTime != nil
        )
        return .acceptedWaiting
    }

    private mutating func fail(
        generation candidateGeneration: UInt64,
        error: HybridPresentationReadinessError
    ) -> HybridPresentationReadinessSignalOutcome {
        guard candidateGeneration == generation else {
            return .staleGeneration
        }
        switch state {
        case .ready:
            return .alreadyReady
        case .failed:
            return .terminalFailure
        case .idle:
            return .staleGeneration
        case .waiting:
            state = .failed(generation: generation, error: error)
            return .terminalFailure
        }
    }

    private static func isValidTolerance(_ value: CMTime) -> Bool {
        value.isValid
            && value.isNumeric
            && CMTimeCompare(value, .zero) >= 0
    }

    static func frameIntersectsTargetWindow(
        frame: DecodedVideoFrame,
        targetTime: CMTime,
        toleranceBefore: CMTime,
        toleranceAfter: CMTime
    ) -> Bool {
        guard frame.presentationTime.isValid,
              frame.presentationTime.isNumeric else {
            return false
        }
        let frameDuration = frame.duration.isValid
            && frame.duration.isNumeric
            && CMTimeCompare(frame.duration, .zero) > 0
            ? frame.duration
            : .zero
        let frameEnd = CMTimeAdd(frame.presentationTime, frameDuration)
        let targetWindowStart = CMTimeSubtract(targetTime, toleranceBefore)
        let targetWindowEnd = CMTimeAdd(targetTime, toleranceAfter)
        return CMTimeCompare(frameEnd, targetWindowStart) >= 0
            && CMTimeCompare(frame.presentationTime, targetWindowEnd) <= 0
    }
}
