import CoreMedia
import Foundation
import Testing
@testable import AetherEngine

@Suite("Black carrier bandwidth preflight", .serialized)
struct BlackCarrierBandwidthPreflightTests {
    private final class ReaderState: @unchecked Sendable {
        let payloads: [Data]
        private let lock = NSLock()
        private var nextPayload = 0
        private var _cloneCount = 0
        private var _prototypeCloseCount = 0
        private var _cloneCloseCount = 0

        init(payloads: [Data]) {
            self.payloads = payloads
        }

        var cloneCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _cloneCount
        }

        var prototypeCloseCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _prototypeCloseCount
        }

        var cloneCloseCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _cloneCloseCount
        }

        func nextClonePayload() -> Data {
            lock.lock()
            let index = min(nextPayload, payloads.count - 1)
            nextPayload += 1
            _cloneCount += 1
            let payload = payloads[index]
            lock.unlock()
            return payload
        }

        func recordClose(isPrototype: Bool) {
            lock.lock()
            if isPrototype {
                _prototypeCloseCount += 1
            } else {
                _cloneCloseCount += 1
            }
            lock.unlock()
        }
    }

    private final class SequencedReader: IOReader, @unchecked Sendable {
        private let state: ReaderState
        private let data: Data?
        private let isPrototype: Bool
        private let lock = NSLock()
        private var position = 0
        private var isClosed = false

        init(
            state: ReaderState,
            data: Data? = nil,
            isPrototype: Bool = true
        ) {
            self.state = state
            self.data = data
            self.isPrototype = isPrototype
        }

        func read(
            _ buffer: UnsafeMutablePointer<UInt8>?,
            size: Int32
        ) -> Int32 {
            guard let data, let buffer, size > 0 else { return -1 }
            lock.lock()
            defer { lock.unlock() }
            guard !isClosed else { return -1 }
            guard position < data.count else { return 0 }
            let count = min(Int(size), data.count - position)
            data.copyBytes(
                to: buffer,
                from: position..<(position + count)
            )
            position += count
            return Int32(count)
        }

        func seek(offset: Int64, whence: Int32) -> Int64 {
            guard let data else { return -1 }
            if whence == 65_536 {
                return Int64(data.count)
            }
            lock.lock()
            defer { lock.unlock() }
            guard !isClosed else { return -1 }
            let target: Int
            switch whence {
            case 0:
                target = Int(offset)
            case 1:
                target = position + Int(offset)
            case 2:
                target = data.count + Int(offset)
            default:
                return -1
            }
            guard target >= 0, target <= data.count else {
                return -1
            }
            position = target
            return Int64(position)
        }

        func close() {
            lock.lock()
            guard !isClosed else {
                lock.unlock()
                return
            }
            isClosed = true
            lock.unlock()
            state.recordClose(isPrototype: isPrototype)
        }

        func makeIndependentReader() -> IOReader? {
            SequencedReader(
                state: state,
                data: state.nextClonePayload(),
                isPrototype: false
            )
        }
    }

    @Test("Full-asset measurement supplies exact master admissions")
    func measuredAdmissionsFeedProvider() throws {
        let sourceData = makeWAV(
            sampleRate: 48_000,
            channels: 2,
            seconds: 5.25
        )
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(seconds: 5.25, preferredTimescale: 90_000)
        )

        let measurementState = ReaderState(payloads: [sourceData])
        let measurementFactory =
            try BlackCarrierDemuxSourceFactory.adopting(
                source: .custom(
                    SequencedReader(state: measurementState),
                    formatHint: "wav"
                ),
                options: LoadOptions()
            )
        let measurement = try BlackCarrierAudioBandwidthPreflight.measure(
            sourceFactory: measurementFactory,
            timeline: timeline,
            bridgeMode: .surroundCompat
        )
        measurementFactory.close()
        let admission = try #require(measurement.admissions.first)
        #expect(measurement.admissions.count == 1)
        #expect(admission.ordinal == 0)
        #expect(admission.evidence.isValid)
        guard case .measuredFullAsset(let peak, let average) =
                admission.evidence else {
            Issue.record("Production preflight did not return measured evidence")
            return
        }
        #expect(peak >= average)
        #expect(measurementState.cloneCount == 1)
        #expect(measurementState.prototypeCloseCount == 1)
        #expect(measurementState.cloneCloseCount == 1)

        let playbackState = ReaderState(payloads: [sourceData])
        let videoProvider = try BlackCarrierVideoProvider(
            timeline: timeline
        )
        let videoPeak = try #require(videoProvider.masterBandwidth)
        let videoAverage = try #require(
            videoProvider.masterAverageBandwidth
        )
        let provider = try BlackCarrierLazyCompositeProvider
            .buildSeekableVOD(
                videoProvider: videoProvider,
                source: .custom(
                    SequencedReader(state: playbackState),
                    formatHint: "wav"
                ),
                options: LoadOptions(),
                timeline: timeline
            )
        #expect(provider.masterBandwidth == videoPeak + peak)
        #expect(
            provider.masterAverageBandwidth
                == videoAverage + average
        )
        #expect(playbackState.cloneCount == 2)
        provider.close()
        #expect(playbackState.prototypeCloseCount == 1)
        #expect(playbackState.cloneCloseCount == 2)
    }

    @Test("Source changes between measurement and playback fail atomically")
    func contractMismatchFails() throws {
        let firstVersion = makeWAV(
            sampleRate: 48_000,
            channels: 2,
            seconds: 1
        )
        let replacement = makeWAV(
            sampleRate: 48_000,
            channels: 2,
            seconds: 2
        )
        let state = ReaderState(payloads: [firstVersion, replacement])
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(seconds: 1, preferredTimescale: 90_000)
        )
        let videoProvider = try BlackCarrierVideoProvider(
            timeline: timeline
        )
        let videoDirectory = videoProvider.sessionDirectory

        #expect(
            throws: BlackCarrierLazyCompositeProviderError
                .bandwidthMeasurementContractMismatch
        ) {
            _ = try BlackCarrierLazyCompositeProvider.buildSeekableVOD(
                videoProvider: videoProvider,
                source: .custom(
                    SequencedReader(state: state),
                    formatHint: "wav"
                ),
                options: LoadOptions(),
                timeline: timeline
            )
        }
        #expect(state.cloneCount == 2)
        #expect(state.prototypeCloseCount == 1)
        #expect(state.cloneCloseCount == 2)
        #expect(
            !FileManager.default.fileExists(
                atPath: videoDirectory.path
            )
        )
    }

    @Test("Video-only source skips the full-asset audio measurement generation")
    func videoOnlySkipsAudioMeasurement() throws {
        let sourceData = try BlackCarrierEncodedSample
            .verifiedMP4Data()
        let probe = Demuxer()
        try probe.open(reader: DataIOReader(data: sourceData))
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: probe.duration,
                preferredTimescale: 90_000
            )
        )
        probe.close()

        let state = ReaderState(payloads: [sourceData])
        let videoProvider = try BlackCarrierVideoProvider(
            timeline: timeline
        )
        let videoPeak = try #require(
            videoProvider.masterBandwidth
        )
        let videoAverage = try #require(
            videoProvider.masterAverageBandwidth
        )
        let provider = try BlackCarrierLazyCompositeProvider
            .buildSeekableVOD(
                videoProvider: videoProvider,
                source: .custom(
                    SequencedReader(state: state),
                    formatHint: "mp4"
                ),
                options: LoadOptions(),
                timeline: timeline,
                decodedFrameHandler: { _ in }
            )

        #expect(state.cloneCount == 1)
        #expect(state.prototypeCloseCount == 0)
        #expect(state.cloneCloseCount == 0)
        #expect(provider.audioAnalysisTrackIDs.isEmpty)
        #expect(provider.masterCodecs == "avc1.42C01E")
        #expect(provider.masterBandwidth == videoPeak)
        #expect(provider.masterAverageBandwidth == videoAverage)

        provider.close()
        #expect(state.prototypeCloseCount == 1)
        #expect(state.cloneCloseCount == 1)
    }

    private func makeWAV(
        sampleRate: Int,
        channels: Int,
        seconds: Double
    ) -> Data {
        let frames = Int(Double(sampleRate) * seconds)
        var pcm = Data(capacity: frames * channels * 2)
        for frame in 0..<frames {
            let value = Int16(
                9_000 * sin(
                    2 * .pi * 440 * Double(frame) / Double(sampleRate)
                )
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
