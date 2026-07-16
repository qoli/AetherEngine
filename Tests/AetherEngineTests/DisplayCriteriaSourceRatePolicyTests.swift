import Testing
@testable import AetherEngine

@Suite("Display criteria source-rate policy")
struct DisplayCriteriaSourceRatePolicyTests {
    @Test("Missing or invalid source rates never become a synthetic display rate", arguments: [
        nil,
        .nan,
        .infinity,
        -.infinity,
        0,
        -23.976,
    ] as [Double?])
    func invalidRateIsNotAdmitted(_ frameRate: Double?) {
        #expect(
            DisplayCriteriaSourceRatePolicy.validated(
                frameRate
            ) == nil
        )
    }

    @Test("A positive finite decoded rate is preserved exactly")
    func validRateIsPreserved() {
        let sourceRate = 30_000.0 / 1_001.0
        #expect(
            DisplayCriteriaSourceRatePolicy.validated(
                sourceRate
            ) == sourceRate
        )
    }

    @Test("Application result separates no-write from an applied criteria")
    func applicationResultIsExplicit() {
        #expect(!DisplayCriteriaApplicationResult.notApplied.didApply)
        #expect(
            !DisplayCriteriaApplicationResult.notApplied
                .requiresDynamicRangeSwitch
        )
        #expect(
            DisplayCriteriaApplicationResult
                .applied(requiresDynamicRangeSwitch: false)
                .didApply
        )
        #expect(
            DisplayCriteriaApplicationResult
                .applied(requiresDynamicRangeSwitch: true)
                .requiresDynamicRangeSwitch
        )
    }
}
