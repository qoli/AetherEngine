import Testing
@testable import AetherEngine

struct MasterFallbackDecisionTests {

    @Test("Display-rejection codes are the two AVFoundation display-reject codes")
    func recognisesRejectionCodes() {
        #expect(MasterFallbackDecision.isDisplayRejectionCode(-11868))
        #expect(MasterFallbackDecision.isDisplayRejectionCode(-11848))
        #expect(!MasterFallbackDecision.isDisplayRejectionCode(-12889)) // media timeout
        #expect(!MasterFallbackDecision.isDisplayRejectionCode(-11800)) // generic unknown
        #expect(!MasterFallbackDecision.isDisplayRejectionCode(0))
    }

    @Test("Display rejection fails typed and never changes playlist")
    func productionFailsClosed() {
        #expect(
            MasterFallbackDecision
                .productionAction(
                    errorCode: -11868
                ) == .failTyped
        )
        #expect(
            MasterFallbackDecision
                .productionAction(
                    errorCode: -11848
                ) == .failTyped
        )
        #expect(
            MasterFallbackDecision
                .productionAction(
                    errorCode: -12889
                ) == .ignore
        )
    }
}
