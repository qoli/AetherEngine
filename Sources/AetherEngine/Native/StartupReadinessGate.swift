import Foundation

/// Outcome of one startup-readiness attempt: did the freshly (re)loaded item reach a playable state,
/// die, or run out the settle window without doing either?
enum StartupReadiness: Sendable, Equatable {
    /// The item produced a non-zero presentation size or actually started playing (hasEverPlayed).
    case ready
    /// Generic `item.status == .failed`. Without positive capability evidence
    /// this is transport-inconclusive and remains recoverable.
    case dead
    /// AVPlayer positively identified the display as unable to present the
    /// exact capability contract.
    case displayRejected(DisplayRejection)
    /// The settle window elapsed with the item neither ready nor failed: the silent 0-track park
    /// (`AVPlayerWaitingWithNoItemToPlayReason`, `asset.tracks` empty).
    case timedOut
}

/// The gate's next move after one attempt.
enum StartupGateAction: Sendable, Equatable {
    /// Item is playable; stop the gate and keep playing.
    case proceed
    /// The checkpoint elapsed without positive failure evidence. Keep the
    /// exact item/master/capability set alive; elapsed time is diagnostic.
    case observeSameItem
    /// Publish one typed display-capability terminal; no playlist or player
    /// transition.
    case failTyped(DisplayRejection)
}

/// Pure observation policy for cold DV/HDR startup. Time alone never reloads
/// or downgrades the selected playlist. Generic item death remains on the
/// same item contract; only positive display-capability evidence terminates
/// the exact playback task.
enum StartupReadinessGate {
    static func nextAction(
        outcome: StartupReadiness
    ) -> StartupGateAction {
        switch outcome {
        case .ready:
            return .proceed
        case .timedOut:
            return .observeSameItem
        case .dead:
            return .observeSameItem
        case .displayRejected(let rejection):
            return .failTyped(rejection)
        }
    }
}
