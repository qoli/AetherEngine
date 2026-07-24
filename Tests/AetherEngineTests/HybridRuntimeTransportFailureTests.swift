import Foundation
import Libavutil
import Testing
@testable import AetherEngine

@Suite("Hybrid runtime transport failure propagation", .serialized)
struct HybridRuntimeTransportFailureTests {
    @Test("Demux EIO remains transient through pump, provider, and outer session")
    func demuxEIORemainsTransient() throws {
        let pump = BlackCarrierMediaFanoutPumpError
            .wrappingDemuxFailure(
                DemuxerError.readFailed(code: -5)
            )
        #expect(pump.failureCategory == .transientTransport)
        #expect(pump.failureCaseCode == "demux.readFailed")
        #expect(pump.failureDomain == "AetherEngine.Demuxer")
        #expect(pump.failureCode == -5)

        let provider = try #require(
            BlackCarrierLazyCompositeProvider
                .hybridPlaybackSessionError(from: pump)
        )
        guard case .providerFailed(let evidence) = provider else {
            Issue.record("Expected provider failure evidence")
            return
        }
        #expect(evidence.category == .transientTransport)
        #expect(evidence.caseCode == "progressive.demux.readFailed")

        let outer = AetherPlaybackSession.hybridFailure(
            evidence: evidence
        )
        #expect(outer.kind == .transientTransport)
        #expect(outer.caseCode == "progressive.demux.readFailed")
        #expect(outer.domain == "AetherEngine.Demuxer")
        #expect(outer.code == -5)
    }

    @Test("AVIO timeout and zero-response evidence remain transient")
    func avioAvailabilityRemainsTransient() throws {
        for (error, expectedCase, expectedCode) in [
            (
                AVIOReaderError.requestTimeout,
                "progressive.avio.requestTimeout",
                3
            ),
            (
                AVIOReaderError.noResponse,
                "progressive.avio.noResponse",
                2
            ),
        ] {
            let pump = BlackCarrierMediaFanoutPumpError
                .wrappingDemuxFailure(error)
            let provider = try #require(
                BlackCarrierLazyCompositeProvider
                    .hybridPlaybackSessionError(from: pump)
            )
            guard case .providerFailed(let evidence) = provider else {
                Issue.record("Expected provider failure evidence")
                continue
            }
            let outer = AetherPlaybackSession.hybridFailure(
                evidence: evidence
            )
            #expect(evidence.category == .transientTransport)
            #expect(outer.kind == .transientTransport)
            #expect(outer.caseCode == expectedCase)
            #expect(outer.code == expectedCode)
        }
    }

    @Test("Positive HTTP authentication and malformed evidence stay permanent")
    func positiveHTTPFailuresStayPermanent() throws {
        for (status, expected) in [
            (401, AetherPlaybackFailureKind.authenticationRejected),
            (403, AetherPlaybackFailureKind.authenticationRejected),
            (404, AetherPlaybackFailureKind.malformedMedia),
            (410, AetherPlaybackFailureKind.malformedMedia),
        ] {
            let pump = BlackCarrierMediaFanoutPumpError
                .wrappingDemuxFailure(
                    AVIOReaderError.httpStatus(
                        statusCode: status
                    )
                )
            let provider = try #require(
                BlackCarrierLazyCompositeProvider
                    .hybridPlaybackSessionError(from: pump)
            )
            guard case .providerFailed(let evidence) = provider else {
                Issue.record("Expected provider failure evidence")
                continue
            }
            let outer = AetherPlaybackSession.hybridFailure(
                evidence: evidence
            )
            #expect(outer.kind == expected)
            #expect(outer.caseCode == "progressive.avio.httpStatus")
            #expect(outer.code == status)
        }
    }

    @Test("INVALIDDATA is permanent only for a complete pinned generation")
    func invalidDataRequiresCompleteGeneration() {
        let truncated = BlackCarrierMediaFanoutPumpError
            .wrappingDemuxFailure(
                DemuxerError.readFailed(
                    code: FFmpegErr.invalidData
                ),
                sourceIsComplete: false
            )
        let complete = BlackCarrierMediaFanoutPumpError
            .wrappingDemuxFailure(
                DemuxerError.readFailed(
                    code: FFmpegErr.invalidData
                ),
                sourceIsComplete: true
            )

        #expect(truncated.failureCategory == .transientTransport)
        #expect(complete.failureCategory == .malformedMedia)
    }

    @Test("Cooperative sink cancellation remains pump closure")
    func sinkCancellationDoesNotBecomeDecoderFailure() {
        let pump = BlackCarrierMediaFanoutPumpError
            .wrappingVideoSinkFailure(
                HybridVideoDecodeSinkError.closed
            )

        #expect(pump == .closed)
        #expect(pump.failureCaseCode == "closed")
        if case .videoDecoderFailed = pump {
            Issue.record(
                "Cooperative cancellation became decoder failure"
            )
        }
    }

    @Test("Pixel conversion capability remains permanent through both terminal paths")
    func pixelConversionCapabilityIsTyped() throws {
        let decoderError =
            HybridVideoDecodeSinkError.decoderFailed(
                .pixelBufferConversionFailed
            )
        let pump = BlackCarrierMediaFanoutPumpError
            .wrappingVideoSinkFailure(decoderError)

        #expect(pump.failureCategory == .unsupportedCapability)
        #expect(
            pump.failureCaseCode
                == "videoDecoder.pixelBufferConversionFailed"
        )
        #expect(
            pump.failureDomain
                == "AetherEngine.HybridVideoDecodeSink"
        )

        let provider = try #require(
            BlackCarrierLazyCompositeProvider
                .hybridPlaybackSessionError(
                    from: pump,
                    stage: .routeCreation
                )
        )
        guard case .providerFailed(let evidence) = provider else {
            Issue.record("Expected typed capability evidence")
            return
        }
        #expect(evidence.stage == .routeCreation)
        #expect(evidence.category == .unsupportedCapability)
        #expect(
            evidence.caseCode
                == "progressive.videoDecoder.pixelBufferConversionFailed"
        )

        let outer = AetherPlaybackSession.hybridFailure(
            evidence: evidence
        )
        #expect(outer.kind == .unsupportedCapability)
        #expect(
            outer.caseCode
                == "progressive.videoDecoder.pixelBufferConversionFailed"
        )
    }

    @Test("Audio bridge capability survives muxer and store wrappers")
    func audioBridgeCapabilityIsTyped() throws {
        let capability =
            BlackCarrierAudioRenditionMuxerError
                .bridgeCapabilityUnavailable(
                    reason: "fixture capability unavailable"
                )
        let failures = [
            BlackCarrierMediaFanoutPumpError.audioMuxerFailed(
                trackID: 1,
                error: capability
            ),
            BlackCarrierMediaFanoutPumpError.audioStoreFailed(
                error: .muxer(capability)
            ),
        ]

        for failure in failures {
            #expect(
                failure.failureCategory
                    == .unsupportedCapability
            )
            let provider = try #require(
                BlackCarrierLazyCompositeProvider
                    .hybridPlaybackSessionError(
                        from: failure,
                        stage: .routeCreation
                    )
            )
            guard case .providerFailed(let evidence) =
                    provider else {
                Issue.record(
                    "Expected typed audio capability evidence"
                )
                continue
            }
            let outer = AetherPlaybackSession.hybridFailure(
                evidence: evidence
            )
            #expect(evidence.stage == .routeCreation)
            #expect(
                evidence.category == .unsupportedCapability
            )
            #expect(outer.kind == .unsupportedCapability)
            #expect(outer.caseCode != nil)
        }
    }
}
