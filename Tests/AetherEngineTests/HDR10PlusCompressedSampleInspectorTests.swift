import Foundation
import Testing
@testable import AetherEngine

@Suite("HDR10+ compressed-sample preflight")
struct HDR10PlusCompressedSampleInspectorTests {
    @Test("Valid Annex-B T.35 SEI is validated")
    func validAnnexBMetadata() {
        let payload = validHDR10PlusT35Payload()
        let sample = annexBSample(
            nalUnits: [seiNALUnit(payload: payload)]
        )

        #expect(
            HDR10PlusCompressedSampleInspector.inspect(
                sample,
                framing: .annexB
            ) == .validated(
                t35PayloadByteCount: payload.count
            )
        )
    }

    @Test("Valid length-prefixed T.35 SEI is validated")
    func validLengthPrefixedMetadata() {
        let payload = validHDR10PlusT35Payload()
        let sample = lengthPrefixedSample(
            nalUnits: [seiNALUnit(payload: payload)],
            lengthFieldBytes: 4
        )

        #expect(
            HDR10PlusCompressedSampleInspector.inspect(
                sample,
                framing: .lengthPrefixed(
                    lengthFieldBytes: 4
                )
            ) == .validated(
                t35PayloadByteCount: payload.count
            )
        )
    }

    @Test("Identifier bytes inside slice data are not HDR10+ evidence")
    func identifierInsideSliceIsIgnored() {
        let vclNAL: [UInt8] = [
            0x26, 0x01,
            0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04,
            0x80,
        ]
        let sample = annexBSample(nalUnits: [vclNAL])

        #expect(
            HDR10PlusCompressedSampleInspector.inspect(
                sample,
                framing: .annexB
            ) == .notDetected
        )
    }

    @Test("Registered HDR10+ identifier with invalid ST 2094-40 payload fails")
    func malformedMetadataFails() {
        let malformedPayload: [UInt8] = [
            0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04,
            0x01,
        ]
        let sample = annexBSample(
            nalUnits: [seiNALUnit(payload: malformedPayload)]
        )

        #expect(
            HDR10PlusCompressedSampleInspector.inspect(
                sample,
                framing: .annexB
            ) == .malformedHDR10PlusMetadata
        )
    }

    @Test("Truncated length-prefixed sample fails explicitly")
    func truncatedLengthPrefixFails() {
        let sample = Data([0x00, 0x00, 0x00, 0x10, 0x4E, 0x01])

        #expect(
            HDR10PlusCompressedSampleInspector.inspect(
                sample,
                framing: .lengthPrefixed(
                    lengthFieldBytes: 4
                )
            ) == .malformedCompressedSample
        )
    }

    @Test("Valid dynamic metadata promotes only a PQ HDR10 base layer")
    func validMetadataRequiresHDR10BaseLayer() {
        let evidence =
            AetherHLSHDR10PlusPreflightEvidence.validated(
                sampleIndex: 3,
                t35PayloadByteCount: 22
            )
        let admitted = HLSPreflightInspector
            .resolveHDR10PlusAdmission(
                baseFormat: .hdr10,
                evidence: evidence
            )
        #expect(admitted.videoFormat == .hdr10Plus)
        #expect(admitted.failureReason == nil)

        let mismatched = HLSPreflightInspector
            .resolveHDR10PlusAdmission(
                baseFormat: .hlg,
                evidence: evidence
            )
        #expect(mismatched.videoFormat == .hlg)
        #expect(
            mismatched.failureReason
                == .unsupportedHDR10PlusBaseLayerMismatch
        )
    }

    @Test("Claimed HDR10+ without compressed-sample evidence fails")
    func missingEvidenceFails() {
        let admission = HLSPreflightInspector
            .resolveHDR10PlusAdmission(
                baseFormat: .hdr10Plus,
                evidence: .notDetectedInFirstSegment(
                    scannedVideoSampleCount: 120
                )
            )

        #expect(admission.videoFormat == .hdr10Plus)
        #expect(
            admission.failureReason
                == .unsupportedHDR10PlusCompressedSampleEvidenceMissing
        )
    }

    @Test("Malformed and uninspectable evidence remain distinct typed failures")
    func evidenceFailuresRemainDistinct() {
        let malformed = HLSPreflightInspector
            .resolveHDR10PlusAdmission(
                baseFormat: .hdr10,
                evidence: .malformed(sampleIndex: 0)
            )
        #expect(
            malformed.failureReason
                == .unsupportedHDR10PlusCompressedSampleMalformed
        )

        let uninspectable = HLSPreflightInspector
            .resolveHDR10PlusAdmission(
                baseFormat: .hdr10,
                evidence: .compressedSampleUninspectable(
                    sampleIndex: 0
                )
            )
        #expect(
            uninspectable.failureReason
                == .unsupportedHDR10PlusCompressedSampleUninspectable
        )

        let validatorUnavailable = HLSPreflightInspector
            .resolveHDR10PlusAdmission(
                baseFormat: .hdr10,
                evidence: .validatorUnavailable(
                    sampleIndex: 0
                )
            )
        #expect(
            validatorUnavailable.failureReason
                == .unsupportedHDR10PlusValidatorUnavailable
        )
    }

    @Test("Validated HDR10+ evidence is retained by privacy-safe preflight telemetry")
    func telemetryRetainsTypedEvidence() {
        let evidence =
            AetherHLSHDR10PlusPreflightEvidence.validated(
                sampleIndex: 2,
                t35PayloadByteCount: 22
            )
        let profile = AetherSourceProfile(
            sourceKind: .hls,
            isSeekableVOD: true,
            videoCodec: .hevc,
            videoFormat: .hdr10Plus
        )
        let preflight = AetherHLSPlaybackPreflight(
            result: PlaybackPreflightResult(
                sourceProfile: profile,
                hlsPackaging: nil,
                route: .unsupported,
                reason: .unsupportedHybridVideoFormat
            ),
            resourceGraph: nil,
            httpHeaders: [:],
            hdr10PlusEvidence: evidence
        )

        #expect(
            AetherPlaybackPreflightTelemetryHLSEvidence(
                preflight
            ).hdr10PlusEvidence == evidence
        )
    }

    private func validHDR10PlusT35Payload() -> [UInt8] {
        var bits = BitWriter()
        bits.append(1, count: 8)       // application version
        bits.append(1, count: 2)       // num_windows
        bits.append(1_000, count: 27)  // target display luminance
        bits.append(0, count: 1)       // target display peak-luminance grid absent
        bits.append(0, count: 17)      // maxSCL R
        bits.append(0, count: 17)      // maxSCL G
        bits.append(0, count: 17)      // maxSCL B
        bits.append(0, count: 17)      // average MaxRGB
        bits.append(0, count: 4)       // distribution percentile count
        bits.append(0, count: 10)      // fraction bright pixels
        bits.append(0, count: 1)       // mastering peak-luminance grid absent
        bits.append(0, count: 1)       // tone mapping absent
        bits.append(0, count: 1)       // saturation mapping absent
        return [
            0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04,
        ] + bits.bytes
    }

    private func seiNALUnit(payload: [UInt8]) -> [UInt8] {
        precondition(payload.count < 255)
        let rbsp = [
            UInt8(4),
            UInt8(payload.count),
        ] + payload + [0x80]
        return [0x4E, 0x01] + escapeRBSP(rbsp)
    }

    private func annexBSample(
        nalUnits: [[UInt8]]
    ) -> Data {
        Data(
            nalUnits.flatMap {
                [0x00, 0x00, 0x00, 0x01] + $0
            }
        )
    }

    private func lengthPrefixedSample(
        nalUnits: [[UInt8]],
        lengthFieldBytes: Int
    ) -> Data {
        var bytes: [UInt8] = []
        for unit in nalUnits {
            for shift in stride(
                from: (lengthFieldBytes - 1) * 8,
                through: 0,
                by: -8
            ) {
                bytes.append(
                    UInt8((unit.count >> shift) & 0xFF)
                )
            }
            bytes.append(contentsOf: unit)
        }
        return Data(bytes)
    }

    private func escapeRBSP(_ bytes: [UInt8]) -> [UInt8] {
        var escaped: [UInt8] = []
        var zeroCount = 0
        for byte in bytes {
            if zeroCount >= 2, byte <= 0x03 {
                escaped.append(0x03)
                zeroCount = 0
            }
            escaped.append(byte)
            zeroCount = byte == 0 ? zeroCount + 1 : 0
        }
        return escaped
    }
}

private struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var bitCount = 0

    mutating func append(
        _ value: UInt64,
        count: Int
    ) {
        precondition((1...64).contains(count))
        for bitOffset in stride(
            from: count - 1,
            through: 0,
            by: -1
        ) {
            if bitCount % 8 == 0 {
                bytes.append(0)
            }
            let bit = UInt8((value >> bitOffset) & 1)
            bytes[bytes.count - 1] |= bit
                << UInt8(7 - (bitCount % 8))
            bitCount += 1
        }
    }
}
