import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AetherEngine

@Suite("Black carrier AVPlayer transport session", .serialized)
struct BlackCarrierAVPlayerSessionTests {
    private enum FixtureError: Error {
        case preparationRejected
    }

    private final class FailingProvider:
        BlackCarrierTransportProvider,
        @unchecked Sendable
    {
        private(set) var didPrepare = false
        private(set) var didClose = false

        func prepareForTransportStart() throws {
            didPrepare = true
            throw FixtureError.preparationRejected
        }

        func close() {
            didClose = true
        }

        func initSegment() -> Data? { nil }
        func mediaSegment(at index: Int) -> Data? { nil }
        var segmentCount: Int { 1 }
        func segmentDuration(at index: Int) -> Double { 1 }
        var playlistType: HLSPlaylistType { .vod }
    }

    private final class TrackingProvider:
        BlackCarrierTransportProvider,
        @unchecked Sendable
    {
        private(set) var didClose = false

        func close() {
            didClose = true
        }

        func initSegment() -> Data? { Data([0]) }
        func mediaSegment(at index: Int) -> Data? { Data([0]) }
        var segmentCount: Int { 1 }
        func segmentDuration(at index: Int) -> Double { 1 }
        var playlistType: HLSPlaylistType { .vod }
    }

    private final class FrameCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    @Test("Session serves the composite carrier and creates a restricted AVPlayer item")
    @MainActor
    func sessionLifecycle() async throws {
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(seconds: 1, preferredTimescale: 90_000)
        )
        let videoProvider = try BlackCarrierVideoProvider(timeline: timeline)
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: makeWAV(seconds: 1)))
        defer { demuxer.close() }

        let audioStore = try BlackCarrierAudioRenditionStore(
            metadata: BlackCarrierAudioRenditionMetadata(
                ordinal: 0,
                sourceTrackID: 0,
                language: "eng",
                name: "English",
                isDefault: true,
                isAutoselect: true
            ),
            demuxer: demuxer,
            audioStreamIndex: demuxer.audioStreamIndex,
            sourceStartPTS: 0,
            timeline: timeline
        )
        let videoDirectory = videoProvider.sessionDirectory
        let audioDirectory = audioStore.sessionDirectory
        let provider = try BlackCarrierCompositeProvider(
            videoProvider: videoProvider,
            audioStores: [audioStore]
        )
        let stablePlayer = AVPlayer()
        stablePlayer.allowsExternalPlayback = true
        #if os(iOS) || os(tvOS)
        stablePlayer.usesExternalPlaybackWhileExternalScreenIsActive = true
        #endif
        let session = BlackCarrierAVPlayerSession(
            provider: provider,
            avPlayer: stablePlayer
        )

        #expect(session.avPlayer === stablePlayer)
        #expect(session.avPlayer.currentItem == nil)
        #expect(session.avPlayer.allowsExternalPlayback)
        #expect(session.transportState == .idle)
        await #expect(throws: BlackCarrierAVPlayerSessionError.notStarted) {
            try await session.prepare()
        }
        try session.start()
        #expect(!session.avPlayer.allowsExternalPlayback)
        #if os(iOS) || os(tvOS)
        #expect(
            !session.avPlayer
                .usesExternalPlaybackWhileExternalScreenIsActive
        )
        #endif

        let playlistURL = try #require(session.playlistURL)
        #expect(playlistURL.lastPathComponent == "master.m3u8")
        #expect(session.avPlayer.currentItem != nil)
        #expect(session.transportState == .started)
        #expect(session.avPlayer.currentItem?.preferredForwardBufferDuration == 4)
        #expect(session.avPlayer.currentItem?.appliesPerFrameHDRDisplayMetadata == false)
        #expect(
            session.avPlayer.currentItem?
                .canUseNetworkResourcesForLiveStreamingWhilePaused == false
        )

        let master = try await fetchText(playlistURL)
        #expect(master.contains("CODECS=\"avc1.42C01E,ec-3\""))
        #expect(master.contains("AUDIO=\"audio\""))

        let baseURL = playlistURL.deletingLastPathComponent()
        let audioPlaylist = try await fetchText(
            baseURL.appendingPathComponent("audio_0.m3u8")
        )
        #expect(audioPlaylist.contains("#EXT-X-MAP:URI=\"audio_0_init.mp4\""))
        #expect(audioPlaylist.contains("#EXTINF:1.000,"))

        let audioInit = try await fetchData(
            baseURL.appendingPathComponent("audio_0_init.mp4")
        )
        let audioSegment = try await fetchData(
            baseURL.appendingPathComponent("audio_0_seg_0.mp4")
        )
        #expect(!audioInit.isEmpty)
        #expect(!audioSegment.isEmpty)

        try await session.prepare(timeout: 10)
        #expect(session.transportState == .ready)
        try await session.prepare(timeout: 10)

        #expect(throws: BlackCarrierAVPlayerSessionError.alreadyStarted) {
            try session.start()
        }

        session.stop()
        #expect(session.avPlayer.currentItem == nil)
        #expect(session.avPlayer.allowsExternalPlayback)
        #if os(iOS) || os(tvOS)
        #expect(
            session.avPlayer
                .usesExternalPlaybackWhileExternalScreenIsActive
        )
        #endif
        #expect(session.playlistURL == nil)
        #expect(session.transportState == .stopped)
        #expect(!FileManager.default.fileExists(atPath: videoDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: audioDirectory.path))
        #expect(throws: BlackCarrierAVPlayerSessionError.alreadyStopped) {
            try session.start()
        }
    }

    @Test("Preparation rejects a non-positive readiness budget with a typed failure")
    @MainActor
    func invalidReadinessBudget() async throws {
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(seconds: 0.25, preferredTimescale: 90_000)
        )
        let videoProvider = try BlackCarrierVideoProvider(timeline: timeline)
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: makeWAV(seconds: 0.25)))
        defer { demuxer.close() }
        let audioStore = try BlackCarrierAudioRenditionStore(
            metadata: BlackCarrierAudioRenditionMetadata(
                ordinal: 0,
                sourceTrackID: 0,
                language: nil,
                name: "Audio",
                isDefault: true,
                isAutoselect: true
            ),
            demuxer: demuxer,
            audioStreamIndex: demuxer.audioStreamIndex,
            sourceStartPTS: 0,
            timeline: timeline
        )
        let provider = try BlackCarrierCompositeProvider(
            videoProvider: videoProvider,
            audioStores: [audioStore]
        )
        let session = BlackCarrierAVPlayerSession(provider: provider)
        try session.start()

        let error = BlackCarrierAVPlayerSessionError.readinessTimedOut(
            seconds: 0
        )
        await #expect(throws: error) {
            try await session.prepare(timeout: 0)
        }
        #expect(session.transportState == .failed(error))

        session.stop()
        #expect(session.transportState == .stopped)
    }

    @Test("Provider startup preparation fails before the loopback server starts")
    @MainActor
    func providerPreparationFailure() {
        let provider = FailingProvider()
        let session = BlackCarrierAVPlayerSession(provider: provider)

        #expect(throws: BlackCarrierAVPlayerSessionError
            .providerPreparationFailed(
                reason: String(describing: FixtureError.preparationRejected)
            )) {
            try session.start()
        }
        #expect(provider.didPrepare)
        #expect(provider.didClose)
        #expect(session.playlistURL == nil)
        #expect(session.transportState == .stopped)
    }

    @Test("A late carrier stop cannot clear a successor AVPlayer item")
    @MainActor
    func stopPreservesSuccessorItem() throws {
        let provider = TrackingProvider()
        let player = AVPlayer()
        player.allowsExternalPlayback = true
        #if os(iOS) || os(tvOS)
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        #endif
        let session = BlackCarrierAVPlayerSession(
            provider: provider,
            avPlayer: player
        )
        try session.start()
        #expect(!player.allowsExternalPlayback)
        let ownedItem = try #require(player.currentItem)
        let successor = AVPlayerItem(asset: AVMutableComposition())

        player.replaceCurrentItem(with: successor)
        player.allowsExternalPlayback = true
        #if os(iOS) || os(tvOS)
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        #endif
        #expect(player.currentItem === successor)
        #expect(player.currentItem !== ownedItem)

        session.stop()

        #expect(provider.didClose)
        #expect(player.currentItem === successor)
        #expect(player.allowsExternalPlayback)
        #if os(iOS) || os(tvOS)
        #expect(player.usesExternalPlaybackWhileExternalScreenIsActive)
        #endif
        #expect(session.transportState == .stopped)
        player.replaceCurrentItem(with: nil)
    }

    @Test("Video-only carrier reaches AVPlayer readiness without silent audio")
    @MainActor
    func videoOnlyCarrierSession() async throws {
        let sourceData = try BlackCarrierEncodedSample.verifiedMP4Data()
        let sourceDemuxer = Demuxer()
        try sourceDemuxer.open(reader: DataIOReader(data: sourceData))
        let duration = sourceDemuxer.duration
        sourceDemuxer.close()
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: duration,
                preferredTimescale: 90_000
            )
        )
        let videoProvider = try BlackCarrierVideoProvider(
            timeline: timeline
        )
        let frameCounter = FrameCounter()
        let provider = try BlackCarrierLazyCompositeProvider
            .buildSeekableVOD(
                videoProvider: videoProvider,
                source: .custom(
                    DataIOReader(data: sourceData),
                    formatHint: "mp4"
                ),
                options: LoadOptions(),
                timeline: timeline,
                decodedFrameHandler: { _ in
                    frameCounter.increment()
                }
            )
        let session = BlackCarrierAVPlayerSession(provider: provider)
        try session.start()
        defer { session.stop() }

        let playlistURL = try #require(session.playlistURL)
        let master = try await fetchText(playlistURL)
        #expect(master.contains("CODECS=\"avc1.42C01E\""))
        #expect(!master.contains("#EXT-X-MEDIA:TYPE=AUDIO"))
        #expect(!master.contains("AUDIO=\"audio\""))

        try await session.prepare(timeout: 10)
        #expect(session.transportState == .ready)
        #expect(frameCounter.count > 0)
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
