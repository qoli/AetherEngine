import Foundation
import Testing
@testable import AetherEngine

@Suite("Aether playback source generation identity")
struct AetherPlaybackSourceGenerationTests {
    @Test("Same metadata cannot admit different validator-bound bytes")
    func validatorDriftFailsIdentity() throws {
        let original = try SourceByteStoreGeneration(
            contentLength: 1_048_576,
            validator: .strongETag("\"generation-a\"")
        )
        let replacement = try SourceByteStoreGeneration(
            contentLength: 1_048_576,
            validator: .strongETag("\"generation-b\"")
        )

        let failure = try #require(
            AetherPlaybackSession
                .freshProgressiveSourceGenerationFailure(
                    previousGeneration: original,
                    freshGeneration: replacement
                )
        )
        #expect(failure.stage == .preflight)
        #expect(failure.kind == .invariantViolation)
        #expect(
            failure.caseCode
                == "progressiveSourceGenerationChanged"
        )
    }

    @Test("Missing replacement generation fails after identity was pinned")
    func missingReplacementGenerationFailsIdentity() throws {
        let original = try SourceByteStoreGeneration(
            contentLength: 2_097_152,
            validator: .lastModified(
                "Wed, 22 Jul 2026 14:00:00 GMT"
            )
        )

        #expect(
            AetherPlaybackSession
                .freshProgressiveSourceGenerationFailure(
                    previousGeneration: original,
                    freshGeneration: nil
                )?.kind == .invariantViolation
        )
    }

    @Test("Same-length validatorless generations fail closed")
    func validatorlessSameLengthGenerationFailsIdentity() throws {
        let original = try SourceByteStoreGeneration(
            contentLength: 25_005_843_710,
            validator: nil
        )
        let changedBytesAtSameLength = try SourceByteStoreGeneration(
            contentLength: 25_005_843_710,
            validator: nil
        )

        let failure = try #require(
            AetherPlaybackSession
                .freshProgressiveSourceGenerationFailure(
                    previousGeneration: original,
                    freshGeneration: changedBytesAtSameLength
                )
        )
        #expect(failure.stage == .preflight)
        #expect(failure.kind == .invariantViolation)
        #expect(
            failure.caseCode
                == "progressiveSourceGenerationUnverifiable"
        )
    }

    @Test("Exact generation remains admissible")
    func exactGenerationRemainsAdmissible() throws {
        let generation = try SourceByteStoreGeneration(
            contentLength: 4_194_304,
            validator: .strongETag("\"stable\"")
        )

        #expect(
            AetherPlaybackSession
                .freshProgressiveSourceGenerationFailure(
                    previousGeneration: generation,
                    freshGeneration: generation
                ) == nil
        )
    }
}
