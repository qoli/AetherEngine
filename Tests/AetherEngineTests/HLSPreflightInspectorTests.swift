import XCTest
@testable import AetherEngine

final class HLSPreflightInspectorTests: XCTestCase {
    func testHVC1RequiresMatchingManifestToken() {
        XCTAssertEqual(
            HLSPreflightInspector.codecVerification(
                manifestCodecs: ["hvc1.2.4.l150", "ec-3"],
                actualCodec: .hevc,
                sampleEntry: .hvc1
            ),
            .verified
        )
    }

    func testHEVCManifestMismatchIsNotConsideredVerified() {
        XCTAssertEqual(
            HLSPreflightInspector.codecVerification(
                manifestCodecs: ["avc1.640028"],
                actualCodec: .hevc,
                sampleEntry: .hvc1
            ),
            .mismatch
        )
    }

    func testMissingManifestCodecRequiresHybridEvidencePath() {
        XCTAssertEqual(
            HLSPreflightInspector.codecVerification(
                manifestCodecs: [],
                actualCodec: .hevc,
                sampleEntry: .hev1
            ),
            .manifestMissingButSegmentVerified
        )
    }

    func testUnknownActualCodecIsNotAUsableInspection() {
        XCTAssertEqual(
            HLSPreflightInspector.codecVerification(
                manifestCodecs: ["hvc1.2.4.l150"],
                actualCodec: .unknown,
                sampleEntry: .hvc1
            ),
            .segmentNotInspected
        )
    }
}
