import CoreMedia
import Foundation
import Testing
@testable import AetherEngine

@Suite("Black carrier fresh-demux restart", .serialized)
struct BlackCarrierFreshDemuxRestartTests {
    private enum FixtureError: Error {
        case freshOpenRejected
    }

    private final class BlockingIOReader: IOReader, @unchecked Sendable {
        private let condition = NSCondition()
        private let data: Data
        private var position: Int64 = 0
        private var shouldBlock = false
        private var isBlocked = false
        private var isCancelled = false

        init(data: Data) {
            self.data = data
        }

        func armBlockingReads() {
            condition.lock()
            shouldBlock = true
            condition.unlock()
        }

        func waitUntilBlocked(
            timeout: TimeInterval
        ) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(timeout)
            while !isBlocked, !isCancelled {
                if !condition.wait(until: deadline) {
                    break
                }
            }
            return isBlocked
        }

        func read(
            _ buffer: UnsafeMutablePointer<UInt8>?,
            size: Int32
        ) -> Int32 {
            condition.lock()
            while shouldBlock, !isCancelled {
                isBlocked = true
                condition.broadcast()
                condition.wait()
            }
            guard !isCancelled, let buffer else {
                condition.unlock()
                return -1
            }
            let available = max(0, data.count - Int(position))
            let count = min(available, Int(size))
            if count > 0 {
                data.copyBytes(
                    to: buffer,
                    from: Int(position)..<(Int(position) + count)
                )
                position += Int64(count)
            }
            condition.unlock()
            return Int32(count)
        }

        func seek(
            offset: Int64,
            whence: Int32
        ) -> Int64 {
            condition.lock()
            defer { condition.unlock() }
            guard !isCancelled else { return -1 }
            if whence == 65_536 {
                return Int64(data.count)
            }
            let target: Int64
            switch whence {
            case 0:
                target = offset
            case 1:
                target = position + offset
            case 2:
                target = Int64(data.count) + offset
            default:
                return -1
            }
            guard target >= 0, target <= Int64(data.count) else {
                return -1
            }
            position = target
            return position
        }

        func cancel() {
            condition.lock()
            isCancelled = true
            condition.broadcast()
            condition.unlock()
        }

        func close() {
            cancel()
        }
    }

    private final class ProduceResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Void, Error>?

        func store(_ result: Result<Void, Error>) {
            lock.lock()
            self.result = result
            lock.unlock()
        }

        func load() -> Result<Void, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    private final class FreshFactoryGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var waiterPresent = false
        private var isOpen = false

        func wait() {
            condition.lock()
            waiterPresent = true
            condition.broadcast()
            while !isOpen {
                condition.wait()
            }
            condition.unlock()
        }

        func waitUntilBlocked(timeout: TimeInterval) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(timeout)
            while !waiterPresent, Date() < deadline {
                condition.wait(until: deadline)
            }
            return waiterPresent && !isOpen
        }

        func release() {
            condition.lock()
            isOpen = true
            condition.broadcast()
            condition.unlock()
        }
    }

    private final class DemuxerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Demuxer?

        func store(_ demuxer: Demuxer) {
            lock.lock()
            value = demuxer
            lock.unlock()
        }

        func load() -> Demuxer? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class BoolBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func store(_ value: Bool) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        func load() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    @Test("Explicit seek cancels a blocked old demux before opening the new generation")
    func preemptsBlockedRead() throws {
        let sourceData = makeWAV(seconds: 12.25)
        let initialReader = BlockingIOReader(data: sourceData)
        let initialDemuxer = Demuxer()
        try initialDemuxer.open(reader: initialReader)
        defer { initialDemuxer.close() }
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(seconds: 12.25, preferredTimescale: 90_000)
        )
        let factoryObservedClosedRetiringDemuxer =
            BoolBox()
        let pump = try BlackCarrierMediaFanoutPump(
            demuxer: initialDemuxer,
            timeline: timeline,
            freshDemuxerFactory: {
                factoryObservedClosedRetiringDemuxer.store(
                    initialDemuxer.sourceContainer == .unknown
                )
                let fresh = Demuxer()
                try fresh.open(reader: DataIOReader(data: sourceData))
                return fresh
            }
        )
        defer { pump.close() }

        _ = try #require(try pump.initSegment(ordinal: 0))
        initialReader.armBlockingReads()

        let produceResult = ProduceResultBox()
        let produceFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            produceResult.store(Result {
                try pump.produce(throughSegment: 2)
            })
            produceFinished.signal()
        }
        #expect(initialReader.waitUntilBlocked(timeout: 2))
        #expect(pump.isCarrierSegmentProductionActive)

        var classifier = HybridSeekIntentClassifier(timeline: timeline)
        let intent = try classifier.registerExplicitHostSeek(
            to: CMTime(seconds: 8.25, preferredTimescale: 90_000)
        )
        let startedAt = Date()
        #expect(try pump.restart(for: intent) == .applied(
            generation: 1,
            segmentIndex: 2
        ))
        #expect(factoryObservedClosedRetiringDemuxer.load())
        #expect(Date().timeIntervalSince(startedAt) < 1)
        #expect(produceFinished.wait(timeout: .now() + 1) == .success)
        #expect(!pump.isCarrierSegmentProductionActive)

        let oldResult = try #require(produceResult.load())
        switch oldResult {
        case .success:
            Issue.record("Superseded generation unexpectedly completed")
        case .failure(let error):
            #expect(
                error as? BlackCarrierMediaFanoutPumpError
                    == .generationSuperseded(generation: 0)
            )
        }

        let restarted = try #require(
            try pump.mediaSegment(ordinal: 0, index: 2)
        )
        #expect(!restarted.isEmpty)
        #expect(pump.generation == 1)
    }

    @MainActor
    @Test("Close returns while fresh open is blocked and rejects its late generation")
    func closeRejectsLateFreshOpen() throws {
        let sourceData = makeWAV(seconds: 12.25)
        let initialDemuxer = Demuxer()
        try initialDemuxer.open(reader: DataIOReader(data: sourceData))
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(seconds: 12.25, preferredTimescale: 90_000)
        )
        let factoryGate = FreshFactoryGate()
        let rejectedReleaseGate = FreshFactoryGate()
        let freshDemuxerBox = DemuxerBox()
        defer {
            factoryGate.release()
            rejectedReleaseGate.release()
        }
        let pump = try BlackCarrierMediaFanoutPump(
            demuxer: initialDemuxer,
            timeline: timeline,
            freshDemuxerFactory: {
                factoryGate.wait()
                let fresh = Demuxer()
                try fresh.open(reader: DataIOReader(data: sourceData))
                freshDemuxerBox.store(fresh)
                return fresh
            },
            ownsInitialDemuxer: true,
            demuxerReleaseFence: { demuxer in
                demuxer.close()
                if demuxer !== initialDemuxer {
                    rejectedReleaseGate.wait()
                }
                demuxer.waitForIOQuiescence()
            }
        )
        _ = try #require(try pump.initSegment(ordinal: 0))

        var classifier = HybridSeekIntentClassifier(timeline: timeline)
        let intent = try classifier.registerExplicitHostSeek(
            to: CMTime(seconds: 8.25, preferredTimescale: 90_000)
        )
        let restartResult = ProduceResultBox()
        let restartFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            restartResult.store(Result {
                _ = try pump.restart(for: intent)
            })
            restartFinished.signal()
        }
        #expect(factoryGate.waitUntilBlocked(timeout: 2))

        let closeStartedAt = ProcessInfo.processInfo.systemUptime
        pump.close()
        let closeElapsed = ProcessInfo.processInfo.systemUptime
            - closeStartedAt
        #expect(closeElapsed < 0.25)
        #expect(pump.generation == 0)

        let closeAndWaitFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            pump.closeAndWaitForIOQuiescence()
            closeAndWaitFinished.signal()
        }
        #expect(
            closeAndWaitFinished.wait(
                timeout: .now() + 0.05
            ) == .timedOut
        )

        factoryGate.release()
        #expect(
            rejectedReleaseGate.waitUntilBlocked(timeout: 1)
        )
        #expect(
            restartFinished.wait(timeout: .now() + 0.05)
                == .timedOut
        )
        #expect(
            closeAndWaitFinished.wait(
                timeout: .now() + 0.05
            ) == .timedOut
        )

        rejectedReleaseGate.release()
        #expect(
            restartFinished.wait(timeout: .now() + 1)
                == .success
        )
        #expect(
            closeAndWaitFinished.wait(
                timeout: .now() + 1
            ) == .success
        )
        let result = try #require(restartResult.load())
        switch result {
        case .success:
            Issue.record("Late fresh open committed after close")
        case .failure(let error):
            #expect(
                error as? BlackCarrierMediaFanoutPumpError == .closed
            )
        }
        #expect(pump.generation == 0)
        let rejectedFreshDemuxer = try #require(
            freshDemuxerBox.load()
        )
        #expect(rejectedFreshDemuxer.sourceContainer == .unknown)
    }

    @Test("Fresh-demux open failure is terminal and preserves the original cause")
    func freshOpenFailure() throws {
        let sourceData = makeWAV(seconds: 5.25)
        let initialDemuxer = Demuxer()
        try initialDemuxer.open(reader: DataIOReader(data: sourceData))
        defer { initialDemuxer.close() }
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(seconds: 5.25, preferredTimescale: 90_000)
        )
        let pump = try BlackCarrierMediaFanoutPump(
            demuxer: initialDemuxer,
            timeline: timeline,
            freshDemuxerFactory: {
                throw FixtureError.freshOpenRejected
            }
        )
        _ = try #require(try pump.initSegment(ordinal: 0))

        var classifier = HybridSeekIntentClassifier(timeline: timeline)
        let intent = try classifier.registerExplicitHostSeek(
            to: CMTime(seconds: 4.5, preferredTimescale: 90_000)
        )
        let expected = BlackCarrierMediaFanoutPumpError
            .freshDemuxerOpenFailed(
                reason: String(describing: FixtureError.freshOpenRejected)
            )
        #expect(throws: expected) {
            _ = try pump.restart(for: intent)
        }
        #expect(throws: BlackCarrierMediaFanoutPumpError.closed) {
            try pump.produce(throughSegment: 1)
        }
    }

    @Test("Fresh-demux transport failure preserves typed retry evidence")
    func freshTransportOpenFailure() throws {
        let sourceData = makeWAV(seconds: 5.25)
        let initialDemuxer = Demuxer()
        try initialDemuxer.open(
            reader: DataIOReader(data: sourceData)
        )
        defer { initialDemuxer.close() }
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: 5.25,
                preferredTimescale: 90_000
            )
        )
        let pump = try BlackCarrierMediaFanoutPump(
            demuxer: initialDemuxer,
            timeline: timeline,
            freshDemuxerFactory: {
                throw AVIOReaderError.requestTimeout
            }
        )
        _ = try #require(try pump.initSegment(ordinal: 0))

        var classifier = HybridSeekIntentClassifier(
            timeline: timeline
        )
        let intent = try classifier.registerExplicitHostSeek(
            to: CMTime(
                seconds: 4.5,
                preferredTimescale: 90_000
            )
        )
        let expected = BlackCarrierMediaFanoutPumpError
            .demuxFailure(
                evidence: BlackCarrierDemuxFailureEvidence(
                    category: .transientTransport,
                    caseCode: "avio.requestTimeout",
                    domain: "AetherEngine.AVIOReader",
                    code: 3
                )
            )
        #expect(throws: expected) {
            _ = try pump.restart(for: intent)
        }
        #expect(expected.failureCategory == .transientTransport)
    }

    @Test("Explicit provider close does not record its interrupted demux read as terminal")
    func closeDoesNotRecordInterruptedRead() throws {
        let sourceData = makeWAV(seconds: 12.25)
        let initialReader = BlockingIOReader(data: sourceData)
        let initialDemuxer = Demuxer()
        try initialDemuxer.open(reader: initialReader)
        defer { initialDemuxer.close() }
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(seconds: 12.25, preferredTimescale: 90_000)
        )
        let videoProvider = try BlackCarrierVideoProvider(
            timeline: timeline
        )
        let pump = try BlackCarrierMediaFanoutPump(
            demuxer: initialDemuxer,
            timeline: timeline,
            freshDemuxerFactory: {
                let fresh = Demuxer()
                try fresh.open(reader: DataIOReader(data: sourceData))
                return fresh
            }
        )
        let provider = try BlackCarrierLazyCompositeProvider(
            videoProvider: videoProvider,
            pump: pump
        )
        defer { provider.close() }

        try provider.prepareForTransportStart()
        initialReader.armBlockingReads()

        let produceResult = ProduceResultBox()
        let produceFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            produceResult.store(Result {
                try provider.prepareHybridGeneration(segmentIndex: 2)
            })
            produceFinished.signal()
        }
        #expect(initialReader.waitUntilBlocked(timeout: 2))

        let closeFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            provider.close()
            closeFinished.signal()
        }

        #expect(produceFinished.wait(timeout: .now() + 1) == .success)
        #expect(closeFinished.wait(timeout: .now() + 1) == .success)
        let result = try #require(produceResult.load())
        if case .success = result {
            Issue.record("Interrupted fanout unexpectedly completed")
        }
        #expect(provider.terminalError == nil)
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
