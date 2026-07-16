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
            automaticallyAppliesDisplayCriteria: true,
            metalOverlayAttached: false
        )

        #expect(failure == .carrierPresentationNotConfigured)
        #expect(
            AetherHybridPlaybackTelemetryState(
                .failed(.carrierPresentationNotConfigured)
            ) == .failed(.carrierPresentationNotConfigured)
        )
    }

    @Test("Player, carrier gravity, automatic criteria and Metal overlay drift all fail explicitly", arguments: [
        (false, true, false, true),
        (true, false, false, true),
        (true, true, true, true),
        (true, true, false, false),
    ])
    func changedContractFails(
        playerMatchesSession: Bool,
        carrierUsesAspectFit: Bool,
        automaticallyAppliesDisplayCriteria: Bool,
        metalOverlayAttached: Bool
    ) {
        let failure = HybridCarrierPresentationContract.failure(
            wasConfigured: true,
            playerControllerAvailable: true,
            playerMatchesSession: playerMatchesSession,
            carrierUsesAspectFit: carrierUsesAspectFit,
            automaticallyAppliesDisplayCriteria:
                automaticallyAppliesDisplayCriteria,
            metalOverlayAttached: metalOverlayAttached
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
            automaticallyAppliesDisplayCriteria: false,
            metalOverlayAttached: true
        ) == nil)
    }

    @Test("Carrier presentation cannot be configured after idle")
    func lateConfigurationFails() {
        #expect(
            HybridCarrierPresentationContract
                .configurationFailure(sessionIsIdle: true)
                == nil
        )
        let failure =
            HybridCarrierPresentationContract
                .configurationFailure(sessionIsIdle: false)
        #expect(
            failure
                == .carrierPresentationConfigurationTooLate
        )
        #expect(
            AetherHybridPlaybackTelemetryState(
                .failed(
                    .carrierPresentationConfigurationTooLate
                )
            ) == .failed(
                .carrierPresentationConfigurationTooLate
            )
        )
    }
}
