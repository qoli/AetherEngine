import Foundation

/// A display rejecting the served HLS master playlist: the `AVPlayerItem` failed with a
/// display-incompatibility error. `-11868` (AVErrorNoCompatibleAlternatesForExternalDisplay) is the
/// iOS external-SDR-monitor case; `-11848` is an HDR master shipped to an SDR-parked panel.
struct DisplayRejection: Sendable, Equatable {
    let code: Int
    let message: String
}

enum MasterDisplayRejectionAction:
    Sendable,
    Equatable
{
    case ignore
    case failTyped
}

/// Fail-closed display-capability policy. A rejected master is positive
/// capability evidence; it never authorizes a reduced master or bare media
/// playlist that would silently drop DV, subtitles or closed captions.
enum MasterFallbackDecision {

    /// The two AVFoundationErrorDomain codes that mean "this display cannot present the master".
    static func isDisplayRejectionCode(_ code: Int) -> Bool {
        code == -11868 || code == -11848
    }

    static func productionAction(
        errorCode: Int
    ) -> MasterDisplayRejectionAction {
        isDisplayRejectionCode(errorCode)
            ? .failTyped
            : .ignore
    }
}
