import Foundation
import Testing
@testable import AetherEngine

struct ASFDependencyCapabilityTests {
    private let asfHeaderObject = Data([
        0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11,
        0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C,
        0xE5, 0x13, 0x00, 0x00,
    ])

    @Test("Positive ASF signature reports missing libavformat capability")
    func unavailableASFDemuxerIsTyped() {
        #expect(throws:
            AetherURLPlaybackSourceClassificationError
                .dependencyCapabilityUnavailable(
                    .libavformatASFDemuxer
                )
        ) {
            try AetherURLPlaybackSourceClassifier.inspect(
                prefix: asfHeaderObject,
                dependencyCapabilityIsAvailable: { _ in false }
            )
        }
    }

    @Test("Positive ASF signature remains progressive when dependency exists")
    func availableASFDemuxerKeepsCanonicalSource() throws {
        let signature = try AetherURLPlaybackSourceClassifier.inspect(
            prefix: asfHeaderObject,
            dependencyCapabilityIsAvailable: { capability in
                capability == .libavformatASFDemuxer
            }
        )

        #expect(signature == .progressive)
        #expect(signature.sourceKind == .progressive)
        #expect(signature.canonicalResolutionStep == .probeProgressive)
    }

    @Test("Near ASF signature does not invent a dependency boundary")
    func nearSignatureRemainsGenericProgressive() throws {
        var nearSignature = asfHeaderObject
        nearSignature[15] ^= 0x01

        let signature = try AetherURLPlaybackSourceClassifier.inspect(
            prefix: nearSignature,
            dependencyCapabilityIsAvailable: { _ in false }
        )

        #expect(signature == .progressive)
    }

    @Test("Runtime libavformat capability and classification agree")
    func runtimeCapabilityProducesTruthfulOutcome() throws {
        let capability = AetherPlaybackDependencyCapability
            .libavformatASFDemuxer
        let isAvailable = AetherURLPlaybackSourceClassifier
            .isDependencyCapabilityAvailable(capability)

        if isAvailable {
            #expect(
                try AetherURLPlaybackSourceClassifier.classify(
                    prefix: asfHeaderObject
                ) == .progressive
            )
        } else {
            #expect(throws:
                AetherURLPlaybackSourceClassificationError
                    .dependencyCapabilityUnavailable(capability)
            ) {
                try AetherURLPlaybackSourceClassifier.classify(
                    prefix: asfHeaderObject
                )
            }
        }
    }

    @Test("Missing ASF dependency maps to a permanent privacy-safe failure")
    func unavailableASFDemuxerFailureEvidence() {
        let error = AetherURLPlaybackSourceClassificationError
            .dependencyCapabilityUnavailable(
                .libavformatASFDemuxer
            )

        #expect(
            AetherPlaybackSession.classify(error)
                == .unsupportedCapability
        )
        #expect(
            AetherPlaybackSession.failureCaseCode(error)
                == "dependency.libavformat.asfDemuxerUnavailable"
        )
        #expect(
            error.localizedDescription
                == "Playback dependency capability is unavailable: "
                    + "libavformat.asfDemuxer"
        )
    }
}
