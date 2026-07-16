import CoreMedia
import Foundation
import Testing
@testable import AetherEngine

@Suite("Black carrier demux source factory", .serialized)
struct BlackCarrierDemuxSourceFactoryTests {
    private final class ReaderState: @unchecked Sendable {
        let data: Data
        private let lock = NSLock()
        private var _cloneCount = 0
        private var _prototypeCloseCount = 0
        private var _cloneCloseCount = 0

        init(data: Data) {
            self.data = data
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

        func recordClone() {
            lock.lock()
            _cloneCount += 1
            lock.unlock()
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

    private final class ClonableReader: IOReader, @unchecked Sendable {
        private let state: ReaderState
        private let isPrototype: Bool
        private let lock = NSLock()
        private var position = 0
        private var isClosed = false

        init(state: ReaderState, isPrototype: Bool = true) {
            self.state = state
            self.isPrototype = isPrototype
        }

        func read(
            _ buffer: UnsafeMutablePointer<UInt8>?,
            size: Int32
        ) -> Int32 {
            guard let buffer, size > 0 else { return -1 }
            lock.lock()
            defer { lock.unlock() }
            guard !isClosed else { return -1 }
            guard position < state.data.count else { return 0 }
            let count = min(Int(size), state.data.count - position)
            state.data.copyBytes(
                to: buffer,
                from: position..<(position + count)
            )
            position += count
            return Int32(count)
        }

        func seek(offset: Int64, whence: Int32) -> Int64 {
            if whence == 65_536 {
                return Int64(state.data.count)
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
                target = state.data.count + Int(offset)
            default:
                return -1
            }
            guard target >= 0, target <= state.data.count else {
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
            state.recordClone()
            return ClonableReader(state: state, isPrototype: false)
        }
    }

    private final class OneShotReader: IOReader, @unchecked Sendable {
        private let lock = NSLock()
        private var isClosed = false
        private(set) var closeCount = 0

        func read(
            _ buffer: UnsafeMutablePointer<UInt8>?,
            size: Int32
        ) -> Int32 {
            0
        }

        func seek(offset: Int64, whence: Int32) -> Int64 {
            whence == 65_536 ? 1 : 0
        }

        func close() {
            lock.lock()
            if !isClosed {
                isClosed = true
                closeCount += 1
            }
            lock.unlock()
        }
    }

    @Test("Custom source generations use independent cursors and close owned resources")
    func customSourceGenerations() throws {
        let state = ReaderState(data: makeWAV(seconds: 5.25))
        let prototype = ClonableReader(state: state)
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(seconds: 5.25, preferredTimescale: 90_000)
        )
        let pump = try BlackCarrierMediaFanoutPump.makeSeekableVOD(
            source: .custom(prototype, formatHint: "wav"),
            options: LoadOptions(),
            timeline: timeline
        )

        _ = try #require(try pump.initSegment(ordinal: 0))
        var classifier = HybridSeekIntentClassifier(timeline: timeline)
        let intent = try classifier.registerExplicitHostSeek(
            to: CMTime(seconds: 4.5, preferredTimescale: 90_000)
        )
        #expect(try pump.restart(for: intent) == .applied(
            generation: 1,
            segmentIndex: 1
        ))
        _ = try #require(
            try pump.mediaSegment(ordinal: 0, index: 1)
        )
        pump.close()

        #expect(state.cloneCount == 2)
        #expect(state.prototypeCloseCount == 1)
        #expect(state.cloneCloseCount == 2)
    }

    @Test("One-shot custom source fails before carrier construction")
    func oneShotSourceRejected() throws {
        let reader = OneShotReader()
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(seconds: 1, preferredTimescale: 90_000)
        )

        #expect(
            throws: BlackCarrierDemuxSourceFactoryError
                .independentReaderUnavailable
        ) {
            _ = try BlackCarrierMediaFanoutPump.makeSeekableVOD(
                source: .custom(reader, formatHint: "wav"),
                options: LoadOptions(),
                timeline: timeline
            )
        }
        #expect(reader.closeCount == 1)
    }

    @Test("A changed source is rejected on a fresh seek generation")
    func changedSourceRejectedOnRestart() throws {
        let state = ReaderState(data: makeWAV(seconds: 5.25))
        let replacementState = ReaderState(data: makeWAV(seconds: 6.25))
        let reader = SequencedPrototypeReader(
            states: [state, replacementState]
        )
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(seconds: 5.25, preferredTimescale: 90_000)
        )
        let pump = try BlackCarrierMediaFanoutPump.makeSeekableVOD(
            source: .custom(reader, formatHint: "wav"),
            options: LoadOptions(),
            timeline: timeline
        )
        defer { pump.close() }
        _ = try #require(try pump.initSegment(ordinal: 0))

        var classifier = HybridSeekIntentClassifier(timeline: timeline)
        let intent = try classifier.registerExplicitHostSeek(
            to: CMTime(seconds: 4.5, preferredTimescale: 90_000)
        )
        #expect(
            throws: BlackCarrierMediaFanoutPumpError
                .restartSourceContractMismatch
        ) {
            _ = try pump.restart(for: intent)
        }
    }

    @Test("Live input is rejected and the adopted custom source is closed")
    func liveSourceRejected() throws {
        let reader = OneShotReader()
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(seconds: 1, preferredTimescale: 90_000)
        )
        var options = LoadOptions()
        options.isLive = true

        #expect(
            throws: BlackCarrierDemuxSourceFactoryError.seekableVODRequired
        ) {
            _ = try BlackCarrierMediaFanoutPump.makeSeekableVOD(
                source: .custom(reader, formatHint: "wav"),
                options: options,
                timeline: timeline
            )
        }
        #expect(reader.closeCount == 1)
    }

    private final class SequencedPrototypeReader:
        IOReader,
        @unchecked Sendable
    {
        private let lock = NSLock()
        private var states: [ReaderState]
        private var isClosed = false

        init(states: [ReaderState]) {
            self.states = states
        }

        func read(
            _ buffer: UnsafeMutablePointer<UInt8>?,
            size: Int32
        ) -> Int32 {
            -1
        }

        func seek(offset: Int64, whence: Int32) -> Int64 {
            -1
        }

        func close() {
            lock.lock()
            isClosed = true
            lock.unlock()
        }

        func makeIndependentReader() -> IOReader? {
            lock.lock()
            guard !isClosed, !states.isEmpty else {
                lock.unlock()
                return nil
            }
            let state = states.removeFirst()
            state.recordClone()
            lock.unlock()
            return ClonableReader(state: state, isPrototype: false)
        }
    }

    private func makeWAV(seconds: Double) -> Data {
        let sampleRate = 48_000
        let channels = 2
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
