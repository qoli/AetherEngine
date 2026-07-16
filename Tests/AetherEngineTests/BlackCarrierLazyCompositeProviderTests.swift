import CoreMedia
import Foundation
import Testing
@testable import AetherEngine

@Suite("Black carrier lazy composite provider", .serialized)
struct BlackCarrierLazyCompositeProviderTests {
    @Test("Loopback audio requests advance only through the requested segment")
    func requestedSegmentProduction() async throws {
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(seconds: 5.25, preferredTimescale: 90_000)
        )
        let videoProvider = try BlackCarrierVideoProvider(timeline: timeline)
        let videoDirectory = videoProvider.sessionDirectory
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: makeWAV(seconds: 5.25)))
        defer { demuxer.close() }
        let pump = try BlackCarrierMediaFanoutPump(
            demuxer: demuxer,
            timeline: timeline
        )
        let evidence = BlackCarrierAudioBandwidthEvidence
            .verifiedConstantRate(
                payloadBandwidth: 256_000,
                maximumContainerOverhead: 64_000,
                averageContainerOverhead: 32_000
            )
        let expectedBandwidth =
            try #require(videoProvider.masterBandwidth)
            + evidence.peakBandwidth
        let provider = try BlackCarrierLazyCompositeProvider(
            videoProvider: videoProvider,
            pump: pump,
            bandwidthAdmissions: [
                BlackCarrierAudioBandwidthAdmission(
                    ordinal: 0,
                    evidence: evidence
                ),
            ]
        )

        try provider.prepareForTransportStart()
        let firstAudioURL = try #require(
            pump.peekMediaSegmentURL(ordinal: 0, index: 0)
        )
        let audioDirectory = firstAudioURL.deletingLastPathComponent()
        #expect(!pump.finished)
        #expect(pump.peekMediaSegmentURL(ordinal: 0, index: 1) == nil)
        #expect(provider.masterCodecs == "avc1.42C01E,ec-3")
        #expect(provider.masterBandwidth == expectedBandwidth)
        #expect(provider.terminalError == nil)

        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer {
            server.stop()
            provider.close()
        }
        let masterURL = try #require(server.playlistURL)
        let baseURL = masterURL.deletingLastPathComponent()

        let master = try await fetchText(masterURL)
        #expect(master.contains("BANDWIDTH=\(expectedBandwidth)"))
        #expect(master.contains("AUDIO=\"audio\""))
        let audioPlaylist = try await fetchText(
            baseURL.appendingPathComponent("audio_0.m3u8")
        )
        #expect(audioPlaylist.contains("audio_0_seg_1.mp4"))

        let initData = try await fetchData(
            baseURL.appendingPathComponent("audio_0_init.mp4")
        )
        let firstSegment = try await fetchData(
            baseURL.appendingPathComponent("audio_0_seg_0.mp4")
        )
        #expect(!initData.isEmpty)
        #expect(!firstSegment.isEmpty)
        #expect(!pump.finished)
        #expect(pump.peekMediaSegmentURL(ordinal: 0, index: 1) == nil)

        var classifier = HybridSeekIntentClassifier(timeline: timeline)
        let seekIntent = try classifier.registerExplicitHostSeek(
            to: CMTime(seconds: 4.5, preferredTimescale: 90_000)
        )
        #expect(try provider.restartMedia(
            for: seekIntent
        ) == .applied(
            generation: 1,
            segmentIndex: 1
        ))
        #expect(pump.generation == 1)
        #expect(!pump.finished)
        #expect(pump.peekMediaSegmentURL(ordinal: 0, index: 1) == nil)

        let secondSegment = try await fetchData(
            baseURL.appendingPathComponent("audio_0_seg_1.mp4")
        )
        #expect(!secondSegment.isEmpty)
        #expect(pump.finished)
        #expect(provider.terminalError == nil)

        server.stop()
        provider.close()
        #expect(!FileManager.default.fileExists(atPath: videoDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: audioDirectory.path))
    }

    @Test("Invalid bandwidth evidence closes adopted provider resources")
    func invalidBandwidthEvidence() throws {
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(seconds: 1, preferredTimescale: 90_000)
        )
        let videoProvider = try BlackCarrierVideoProvider(timeline: timeline)
        let videoDirectory = videoProvider.sessionDirectory
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: makeWAV(seconds: 1)))
        defer { demuxer.close() }
        let pump = try BlackCarrierMediaFanoutPump(
            demuxer: demuxer,
            timeline: timeline
        )
        let evidence = BlackCarrierAudioBandwidthEvidence
            .measuredFullAsset(
                peakBandwidth: 100,
                averageBandwidth: 200
            )

        #expect(throws: BlackCarrierLazyCompositeProviderError
            .invalidBandwidthEvidence(ordinal: 0)) {
            _ = try BlackCarrierLazyCompositeProvider(
                videoProvider: videoProvider,
                pump: pump,
                bandwidthAdmissions: [
                    BlackCarrierAudioBandwidthAdmission(
                        ordinal: 0,
                        evidence: evidence
                    ),
                ]
            )
        }
        #expect(!FileManager.default.fileExists(atPath: videoDirectory.path))
        #expect(throws: BlackCarrierMediaFanoutPumpError.closed) {
            try pump.produce(throughSegment: 0)
        }
    }

    private func fetchText(_ url: URL) async throws -> String {
        let data = try await fetchData(url)
        return try #require(String(data: data, encoding: .utf8))
    }

    private func fetchData(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        return data
    }

    private func makeWAV(seconds: Double) -> Data {
        let sampleRate = 48_000
        let channels = 2
        let frames = Int(Double(sampleRate) * seconds)
        var pcm = Data(capacity: frames * channels * 2)
        for frame in 0..<frames {
            let value = Int16(
                9_000 * sin(2 * .pi * 440 * Double(frame) / Double(sampleRate))
            )
            for _ in 0..<channels {
                withUnsafeBytes(of: value.littleEndian) {
                    pcm.append(contentsOf: $0)
                }
            }
        }

        var data = Data()
        func appendString(_ value: String) {
            data.append(value.data(using: .ascii)!)
        }
        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        func appendUInt16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) {
                data.append(contentsOf: $0)
            }
        }

        appendString("RIFF")
        appendUInt32(UInt32(36 + pcm.count))
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(UInt16(channels))
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * channels * 2))
        appendUInt16(UInt16(channels * 2))
        appendUInt16(16)
        appendString("data")
        appendUInt32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
