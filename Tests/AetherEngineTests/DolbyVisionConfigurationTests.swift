import XCTest
@testable import AetherEngine

final class DolbyVisionConfigurationTests: XCTestCase {
    func testPlainHLGBaseLayerIsNotDolbyVisionEvidenceWithoutConfiguration() {
        XCTAssertFalse(
            AetherEngine.scopedDolbyVisionProfile84BaseLayerEvidence(
                configuration: nil,
                baseLayerMatches: true
            )
        )
    }

    func testProfile84SerializesExact24ByteDVVCRecord() throws {
        let configuration = AetherDolbyVisionConfiguration(
            versionMajor: 1,
            versionMinor: 0,
            profile: 8,
            level: 1,
            rpuPresent: true,
            enhancementLayerPresent: false,
            baseLayerPresent: true,
            baseLayerSignalCompatibilityID: 4,
            metadataCompression: 0
        )

        XCTAssertEqual(configuration.verifiedHybridProfile, .profile84)
        XCTAssertTrue(
            AetherEngine.scopedDolbyVisionProfile84BaseLayerEvidence(
                configuration: configuration,
                baseLayerMatches: true
            )
        )
        let bytes = try XCTUnwrap(configuration.profile84DVVCData())
        XCTAssertEqual(bytes.count, 24)
        XCTAssertEqual(
            Array(bytes),
            [0x01, 0x00, 0x10, 0x0D, 0x40]
                + [UInt8](repeating: 0, count: 19)
        )
    }

    func testProfile84SerializationRejectsCompressedMetadata() {
        let configuration = AetherDolbyVisionConfiguration(
            versionMajor: 1,
            versionMinor: 0,
            profile: 8,
            level: 1,
            rpuPresent: true,
            enhancementLayerPresent: false,
            baseLayerPresent: true,
            baseLayerSignalCompatibilityID: 4,
            metadataCompression: 1
        )

        XCTAssertNil(configuration.verifiedHybridProfile)
        XCTAssertNil(configuration.profile84DVVCData())
    }
}
