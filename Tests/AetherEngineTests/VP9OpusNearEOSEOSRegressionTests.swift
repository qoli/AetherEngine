import CoreMedia
import Foundation
import Testing
@testable import AetherEngine

private let vp9OpusNearEOSFixtureURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("PlayerTestVideos")
    .appendingPathComponent("06-seek-5min")
    .appendingPathComponent("progressive-hybrid-vp9-opus-ass-5min.mkv")

private let vp9OpusNearEOSFixtureExists = FileManager.default.fileExists(
    atPath: vp9OpusNearEOSFixtureURL.path
)

@Suite("VP9/Opus near-EOS audio carrier regression", .serialized)
struct VP9OpusNearEOSEOSRegressionTests {
    @Test("Nested EOF coverage failure has stable closed Hybrid evidence")
    func eofCoverageFailureEvidence() throws {
        let nested = BlackCarrierAudioRenditionMuxerError.emptySegment(
            index: 75
        )
        let pump = BlackCarrierMediaFanoutPumpError.audioMuxerFailed(
            trackID: 1,
            error: nested
        )

        #expect(nested.failureCaseCode == "emptySegment")
        #expect(nested.failureCode == 13)
        #expect(pump.failureCaseCode == "audioMuxer.emptySegment")
        #expect(
            pump.failureDomain
                == "AetherEngine.BlackCarrierAudioRenditionMuxer"
        )
        #expect(pump.failureCode == 13)

        let mapped = try #require(
            BlackCarrierLazyCompositeProvider.hybridPlaybackSessionError(
                from: BlackCarrierLazyCompositeProviderError.pump(pump)
            )
        )
        guard case .providerFailed(let evidence) = mapped else {
            Issue.record("Expected typed progressive provider evidence")
            return
        }
        #expect(evidence.stage == .provider)
        #expect(
            evidence.caseCode
                == "progressive.audioMuxer.emptySegment"
        )
        #expect(
            evidence.underlyingDomain
                == "AetherEngine.BlackCarrierAudioRenditionMuxer"
        )
        #expect(evidence.underlyingCode == 13)

        let unified = AetherPlaybackSession.hybridFailure(
            evidence: evidence
        )
        #expect(unified.stage == .playback)
        #expect(unified.kind == .routeRuntimeFailure)
        #expect(
            unified.caseCode
                == "progressive.audioMuxer.emptySegment"
        )
        #expect(
            unified.domain
                == "AetherEngine.BlackCarrierAudioRenditionMuxer"
        )
        #expect(unified.code == 13)

        let privateProviderEvidence = HybridPlaybackFailureEvidence(
            stage: .provider,
            caseCode: "progressive.internalProviderState",
            underlyingDomain: "AetherEngine.InternalProvider",
            underlyingCode: 1
        )
        #expect(
            AetherPlaybackSession.hybridFailure(
                evidence: privateProviderEvidence
            ).caseCode == nil
        )
    }

    @Test(
        "Finite Opus bridge finalizes every carrier segment at source EOF",
        .enabled(
            if: vp9OpusNearEOSFixtureExists,
            "PlayerTestVideos VP9/Opus/ASS fixture is unavailable"
        ),
        .timeLimit(.minutes(2))
    )
    func finiteOpusBridgeFinalizesAtEOF() throws {
        let demuxer = Demuxer()
        try demuxer.open(url: vp9OpusNearEOSFixtureURL)
        defer { demuxer.close() }

        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: demuxer.duration,
                preferredTimescale: BlackCarrierProfile.approved.timescale
            )
        )
        let audioStreamIndex = demuxer.audioStreamIndex
        let sourceStartPTS = BlackCarrierSourceAxis.sourceStartPTS(
            demuxer: demuxer,
            streamIndex: audioStreamIndex
        )
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AetherVP9OpusNearEOS-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        var finalizedSegmentIndices: [Int] = []
        let summary = try BlackCarrierAudioRenditionMuxer.mux(
            demuxer: demuxer,
            audioStreamIndex: audioStreamIndex,
            sourceStartPTS: sourceStartPTS,
            timeline: timeline,
            sessionDirectory: outputDirectory,
            onInit: { _ in },
            onSegment: { timing, _, _ in
                finalizedSegmentIndices.append(timing.index)
            }
        )

        #expect(
            summary.pipeline
                == .bridge(mode: .surroundCompat, codecString: "ec-3")
        )
        #expect(
            finalizedSegmentIndices == timeline.segments.map(\.index)
        )
    }

    @Test(
        "Forward and backward seek generation reaches VP9/Opus EOF in one pump",
        .enabled(
            if: vp9OpusNearEOSFixtureExists,
            "PlayerTestVideos VP9/Opus/ASS fixture is unavailable"
        ),
        .timeLimit(.minutes(2))
    )
    func seekGenerationsReachEOF() throws {
        let initialDemuxer = Demuxer()
        try initialDemuxer.open(url: vp9OpusNearEOSFixtureURL)
        defer { initialDemuxer.close() }
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: initialDemuxer.duration,
                preferredTimescale: BlackCarrierProfile.approved.timescale
            )
        )
        let pump = try BlackCarrierMediaFanoutPump(
            demuxer: initialDemuxer,
            timeline: timeline,
            freshDemuxerFactory: {
                let fresh = Demuxer()
                try fresh.open(url: vp9OpusNearEOSFixtureURL)
                return fresh
            }
        )
        defer { pump.close() }

        _ = try #require(try pump.initSegment(ordinal: 0))
        var classifier = HybridSeekIntentClassifier(timeline: timeline)

        let forwardTarget = CMTime(
            seconds: 150,
            preferredTimescale: BlackCarrierProfile.approved.timescale
        )
        let forwardIndex = try #require(
            timeline.segmentIndex(containing: forwardTarget)
        )
        let forwardIntent = try classifier.registerExplicitHostSeek(
            to: forwardTarget
        )
        #expect(
            try pump.restart(for: forwardIntent)
                == .applied(generation: 1, segmentIndex: forwardIndex)
        )
        _ = try #require(
            try pump.mediaSegment(
                ordinal: 0,
                index: forwardIndex
            )
        )

        let backwardTarget = CMTime(
            seconds: 60,
            preferredTimescale: BlackCarrierProfile.approved.timescale
        )
        let backwardIndex = try #require(
            timeline.segmentIndex(containing: backwardTarget)
        )
        let backwardIntent = try classifier.registerExplicitHostSeek(
            to: backwardTarget
        )
        #expect(
            try pump.restart(for: backwardIntent)
                == .applied(generation: 2, segmentIndex: backwardIndex)
        )
        _ = try #require(
            try pump.mediaSegment(
                ordinal: 0,
                index: backwardIndex
            )
        )

        let finalIndex = try #require(timeline.segments.indices.last)
        let finalSegment = try #require(
            try pump.mediaSegment(
                ordinal: 0,
                index: finalIndex
            )
        )
        #expect(!finalSegment.isEmpty)
        #expect(pump.summary(ordinal: 0) != nil)
        #expect(pump.finished)
        #expect(pump.generation == 2)
    }
}
