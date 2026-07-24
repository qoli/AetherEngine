import Testing
@testable import AetherEngine

struct StartupReadinessGateTests {

    @Test("A ready item proceeds")
    func readyProceeds() {
        #expect(StartupReadinessGate.nextAction(
            outcome: .ready) == .proceed)
    }

    @Test("Elapsed readiness is observation only")
    func timeoutKeepsExactItem() {
        #expect(StartupReadinessGate.nextAction(
            outcome: .timedOut)
            == .observeSameItem)
    }

    @Test("Generic item death keeps the exact item recoverable")
    func deadKeepsExactItem() {
        #expect(StartupReadinessGate.nextAction(
            outcome: .dead)
            == .observeSameItem)
    }

    @Test("Positive display rejection fails typed without fallback")
    func displayRejectionFailsTyped() {
        let rejection = DisplayRejection(
            code: -11868,
            message:
                "domain=AVFoundationErrorDomain code=-11868"
        )
        #expect(
            StartupReadinessGate
                .nextAction(
                    outcome:
                        .displayRejected(
                            rejection
                        )
                )
                == .failTyped(rejection)
        )
    }
}
