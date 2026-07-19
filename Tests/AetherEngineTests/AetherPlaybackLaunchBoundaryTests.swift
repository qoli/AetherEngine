import AVFoundation
import Foundation
import Testing
@testable import AetherEngine

@Suite("Aether playback launch boundary")
struct AetherPlaybackLaunchBoundaryTests {
    private func makeWAV(
        sampleRate: Int = 48_000,
        channels: Int = 1,
        seconds: Double = 2
    ) -> Data {
        let frames = Int(Double(sampleRate) * seconds)
        var pcm = Data(capacity: frames * channels * 2)
        for frame in 0 ..< frames {
            let value = Int16(
                9_000 * sin(
                    2 * .pi * 440 * Double(frame)
                        / Double(sampleRate)
                )
            )
            for _ in 0 ..< channels {
                withUnsafeBytes(of: value.littleEndian) {
                    pcm.append(contentsOf: $0)
                }
            }
        }
        var data = Data()
        func append(_ value: String) {
            data.append(value.data(using: .ascii)!)
        }
        func append(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        func append(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        append("RIFF")
        append(UInt32(36 + pcm.count))
        append("WAVE")
        append("fmt ")
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(channels))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * channels * 2))
        append(UInt16(channels * 2))
        append(UInt16(16))
        append("data")
        append(UInt32(pcm.count))
        data.append(pcm)
        return data
    }

    private func nativePreflight() -> PlaybackPreflightResult {
        PlaybackPreflight.resolve(
            sourceProfile: AetherSourceProfile(
                sourceKind: .progressive,
                isSeekableVOD: true,
                videoCodec: .h264,
                videoFormat: .sdr
            ),
            hlsPackaging: nil,
            hybridCapabilities:
                AetherHybridPlaybackSession.capabilities
        )
    }

    private func temporaryWAV() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("source.wav")
        try makeWAV().write(to: url)
        return url
    }

    @Test("HLS classification is based on bytes, including BOM and whitespace")
    func hlsSignatureClassification() throws {
        let prefix = Data(
            [0xEF, 0xBB, 0xBF]
                + Array(" \n\t#EXTM3U\n#EXT-X-VERSION:7".utf8)
        )

        #expect(
            try AetherURLPlaybackSourceClassifier
                .classify(prefix: prefix) == .hls
        )
    }

    @Test("A misleading m3u8 path cannot override progressive bytes")
    func suffixDoesNotControlClassification() throws {
        let progressivePrefix = Data([
            0x00, 0x00, 0x00, 0x18,
            0x66, 0x74, 0x79, 0x70,
            0x69, 0x73, 0x6F, 0x6D,
        ])

        #expect(
            try AetherURLPlaybackSourceClassifier
                .classify(prefix: progressivePrefix)
                == .progressive
        )
    }

    @Test("Empty classification evidence fails instead of choosing a route")
    func emptyPrefixFails() {
        #expect(throws:
            AetherURLPlaybackSourceClassificationError
                .emptyResource
        ) {
            try AetherURLPlaybackSourceClassifier
                .classify(prefix: Data())
        }
    }

    @Test("Local file classification reads only source bytes")
    func localFileClassification() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("not-a-manifest.mp4")
        try Data("#EXTM3U\n#EXT-X-ENDLIST\n".utf8).write(to: url)

        #expect(
            try await AetherURLPlaybackSourceClassifier
                .classify(url: url) == .hls
        )
    }

    @MainActor
    @Test("Native session factory rejects a Hybrid route before asset creation")
    func nativeSessionRejectsHybridPreflight() throws {
        let profile = AetherSourceProfile(
            sourceKind: .progressive,
            isSeekableVOD: true,
            videoCodec: .vp9,
            videoFormat: .sdr
        )
        let preflight = PlaybackPreflight.resolve(
            sourceProfile: profile,
            hlsPackaging: nil,
            hybridCapabilities:
                AetherHybridPlaybackSession.capabilities
        )
        let expected = AetherNativePlaybackSessionError
            .preflightRequiresNative(
                route: preflight.route,
                reason: preflight.reason
            )

        #expect(throws: expected) {
            try AetherNativePlaybackSession.make(
                url: URL(fileURLWithPath: "/not-opened.mp4"),
                preflightResult: preflight
            )
        }
    }

    @MainActor
    @Test("A native session exclusively owns and tears down its player item")
    func nativeSessionOwnership() throws {
        let profile = AetherSourceProfile(
            sourceKind: .progressive,
            isSeekableVOD: true,
            videoCodec: .h264,
            videoFormat: .sdr
        )
        let preflight = PlaybackPreflight.resolve(
            sourceProfile: profile,
            hlsPackaging: nil,
            hybridCapabilities:
                AetherHybridPlaybackSession.capabilities
        )
        let session = try AetherNativePlaybackSession.make(
            url: URL(fileURLWithPath: "/not-opened.mp4"),
            preflightResult: preflight
        )

        #expect(session.avPlayer.currentItem === session.avPlayerItem)
        session.stop()
        session.stop()
        #expect(session.avPlayer.currentItem == nil)
        #expect(session.state == .stopped)
        #expect(throws: AetherNativePlaybackSessionError.stopped) {
            try session.play()
        }
    }

    @MainActor
    @Test("Native route implementation retains the unified player identity")
    func nativeRouteUsesInjectedPlayer() throws {
        let stablePlayer = AVPlayer()
        let session = try AetherNativePlaybackSession.make(
            url: URL(fileURLWithPath: "/not-opened.mp4"),
            preflightResult: nativePreflight(),
            audioAnalysisBinding: .unavailable(
                sourceURL: URL(
                    fileURLWithPath: "/not-opened.mp4"
                ),
                httpHeaders: [:],
                error: .analysisFailed("not prepared")
            ),
            avPlayer: stablePlayer
        )

        #expect(session.avPlayer === stablePlayer)
        #expect(stablePlayer.currentItem === session.avPlayerItem)
        session.stop()
        #expect(stablePlayer.currentItem == nil)
    }

    @MainActor
    @Test("Native session supplies independent source-time PCM without moving AVPlayer")
    func nativeIndependentAudioAnalysis() async throws {
        let url = try temporaryWAV()
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent()
            )
        }
        let probe = try AetherEngine.probe(url: url)
        let binding = AetherNativeAudioAnalysisBinding.progressive(
            sourceURL: url,
            httpHeaders: [:],
            probe: probe
        )
        let session = try AetherNativePlaybackSession.make(
            url: url,
            preflightResult: nativePreflight(),
            audioAnalysisBinding: binding
        )
        guard let trackID = binding.publicTrackIDs.first else {
            Issue.record("WAV probe did not expose an audio track")
            return
        }
        session.handleMediaSelectionChange(
            selectedAudioOptionIndex: 0
        )
        #expect(session.selectedAudioAnalysisTrackID == trackID)
        #expect(
            session.audioAnalysisAvailability(for: trackID)
                == .available
        )

        let request = try AudioAnalysisRequest(
            audioTrackID: trackID,
            range: 0 ..< 0.5
        )
        let stream = try session.audioAnalysisStream(
            request: request
        )
        var iterator = stream.makeAsyncIterator()
        var bufferCount = 0
        var previousEnd: Int64?
        while let buffer = try await iterator.next() {
            #expect(buffer.pcm.format.sampleRate == 48_000)
            #expect(buffer.pcm.format.channelCount == 1)
            #expect(!buffer.isDiscontinuous)
            if let previousEnd {
                #expect(
                    buffer.sourceSamplePosition == previousEnd
                )
            }
            previousEnd = buffer.sourceSamplePosition
                + Int64(buffer.pcm.frameLength)
            bufferCount += 1
        }
        #expect(bufferCount > 0)
        #expect(session.avPlayer.currentTime() == .zero)
        for _ in 0 ..< 100
        where session.activeAudioAnalysisRequestCount != 0 {
            await Task.yield()
        }
        #expect(session.activeAudioAnalysisRequestCount == 0)
        session.stop()
    }

    @MainActor
    @Test("Native audio selection cancels the old cursor before publishing replacement identity")
    func nativeSelectionCancelsOldAnalysisCursor() async throws {
        let url = try temporaryWAV()
        defer {
            try? FileManager.default.removeItem(
                at: url.deletingLastPathComponent()
            )
        }
        let probe = try AetherEngine.probe(url: url)
        guard let sourceTrack = probe.audioTracks.first else {
            Issue.record("WAV probe did not expose an audio track")
            return
        }
        let binding = AetherNativeAudioAnalysisBinding(
            sourceURL: url,
            httpHeaders: [:],
            durationSeconds: probe.durationSeconds,
            tracks: [
                .init(
                    publicTrackID: 11,
                    sourceTrack: sourceTrack,
                    availability: .available
                ),
                .init(
                    publicTrackID: 22,
                    sourceTrack: sourceTrack,
                    availability: .available
                ),
            ],
            optionTrackIDs: [11, 22],
            allTracksUnavailable: nil
        )
        let session = try AetherNativePlaybackSession.make(
            url: url,
            preflightResult: nativePreflight(),
            audioAnalysisBinding: binding
        )
        session.handleMediaSelectionChange(
            selectedAudioOptionIndex: 0
        )
        let stream = try session.audioAnalysisStream(
            request: try AudioAnalysisRequest(
                audioTrackID: 11,
                range: 0 ..< 1
            )
        )

        session.handleMediaSelectionChange(
            selectedAudioOptionIndex: 1
        )
        #expect(session.selectedAudioAnalysisTrackID == 22)
        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("cancelled old cursor produced a buffer")
        } catch let error as AudioAnalysisError {
            #expect(error == .cancelled)
        }
        session.stop()
    }

    @Test("Native HLS binding rejects a rendition language mismatch")
    func nativeHLSBindingRejectsTrackContractMismatch() {
        let source = AetherSourceProfile(
            sourceKind: .hls,
            isSeekableVOD: true,
            videoCodec: .h264,
            videoFormat: .sdr
        )
        let packaging = HLSVideoPackaging(
            container: .fragmentedMP4,
            sampleEntry: .avc1,
            manifestCodecs: ["avc1.640028"],
            actualVideoCodec: .h264,
            codecVerification: .verified,
            contentProtection: .none
        )
        let result = PlaybackPreflight.resolve(
            sourceProfile: source,
            hlsPackaging: packaging,
            hybridCapabilities:
                AetherHybridPlaybackSession.capabilities
        )
        let policy = AetherHLSAudioRenditionAnalysisPolicy(
            audioTrackID: 0,
            name: "English",
            language: "en",
            isDefault: true,
            availability: .requiresPlaybackSessionBinding
        )
        let preflight = AetherHLSPlaybackPreflight(
            result: result,
            resourceGraph: nil,
            httpHeaders: [:],
            audioAnalysisPolicy:
                .selectedAlternateAudioRenditions([policy])
        )
        let url = URL(string: "https://example.com/master.m3u8")!
        let probe = SourceProbe(
            url: url,
            durationSeconds: 60,
            videoFormat: .sdr,
            videoCodecID: 0,
            videoCodecName: "h264",
            videoWidth: 1920,
            videoHeight: 1080,
            videoFrameRate: 24,
            isDolbyVision: false,
            audioTracks: [
                TrackInfo(
                    id: 4,
                    name: "Spanish",
                    codec: "aac",
                    language: "es",
                    isDefault: true
                )
            ],
            subtitleTracks: []
        )
        let binding = AetherNativeAudioAnalysisBinding.hls(
            sourceURL: url,
            httpHeaders: [:],
            preflight: preflight,
            probe: probe
        )

        #expect(
            binding.availability(for: 0)
                == .unavailable(
                    .sourceTrackContractChanged(audioTrackID: 0)
                )
        )
        #expect(binding.optionTrackIDs == [0])
    }
}
