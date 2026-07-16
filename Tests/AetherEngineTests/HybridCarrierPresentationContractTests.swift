import Testing
@testable import AetherEngine

@Suite("Hybrid carrier presentation contract")
struct HybridCarrierPresentationContractTests {
    @Test("Missing tvOS host configuration is a distinct terminal reason")
    func missingConfigurationFails() {
        let failure = HybridCarrierPresentationContract.failure(
            wasConfigured: false,
            playerControllerAvailable: false,
            playerMatchesSession: false,
            carrierUsesAspectFit: false,
            automaticallyAppliesDisplayCriteria: true
        )

        #expect(failure == .carrierPresentationNotConfigured)
        #expect(
            AetherHybridPlaybackTelemetryState(
                .failed(.carrierPresentationNotConfigured)
            ) == .failed(.carrierPresentationNotConfigured)
        )
    }

    @Test("Player, carrier gravity and automatic criteria drift all fail explicitly", arguments: [
        (false, true, false),
        (true, false, false),
        (true, true, true),
    ])
    func changedContractFails(
        playerMatchesSession: Bool,
        carrierUsesAspectFit: Bool,
        automaticallyAppliesDisplayCriteria: Bool
    ) {
        let failure = HybridCarrierPresentationContract.failure(
            wasConfigured: true,
            playerControllerAvailable: true,
            playerMatchesSession: playerMatchesSession,
            carrierUsesAspectFit: carrierUsesAspectFit,
            automaticallyAppliesDisplayCriteria:
                automaticallyAppliesDisplayCriteria
        )

        #expect(failure == .carrierPresentationContractChanged)
        #expect(
            AetherHybridPlaybackTelemetryState(
                .failed(.carrierPresentationContractChanged)
            ) == .failed(.carrierPresentationContractChanged)
        )
    }

    @Test("Exact carrier-host contract is admitted")
    func exactContractIsAdmitted() {
        #expect(HybridCarrierPresentationContract.failure(
            wasConfigured: true,
            playerControllerAvailable: true,
            playerMatchesSession: true,
            carrierUsesAspectFit: true,
            automaticallyAppliesDisplayCriteria: false
        ) == nil)
    }
}
