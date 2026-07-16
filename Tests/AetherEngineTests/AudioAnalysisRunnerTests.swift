import XCTest
@testable import AetherEngine

final class AudioAnalysisRunnerTests: XCTestCase {
    private final class CountingReader: IOReader, @unchecked Sendable {
        private let lock = NSLock()
        private var accesses = 0

        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            lock.lock(); accesses += 1; lock.unlock()
            return 0
        }

        func seek(offset: Int64, whence: Int32) -> Int64 {
            lock.lock(); accesses += 1; lock.unlock()
            return 0
        }

        func close() {}
        func cancel() {}

        func accessCount() -> Int {
            lock.lock(); defer { lock.unlock() }
            return accesses
        }
    }

    private func makeWAV(sampleRate: Int, channels: Int, seconds: Double) -> Data {
        let frames = Int(Double(sampleRate) * seconds)
        var pcm = Data(capacity: frames * channels * 2)
        for n in 0..<frames {
            let value = Int16(9_000 * sin(2 * .pi * 440 * Double(n) / Double(sampleRate)))
            for _ in 0..<channels {
                withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
            }
        }
        var data = Data()
        func string(_ value: String) { data.append(value.data(using: .ascii)!) }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        string("RIFF"); u32(UInt32(36 + pcm.count)); string("WAVE")
        string("fmt "); u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
        string("data"); u32(UInt32(pcm.count)); data.append(pcm)
        return data
    }

    func testIndependentRunnerDownmixesResamplesAndClipsExactRange() async throws {
        let request = try AudioAnalysisRequest(audioTrackID: 0, range: 0.25..<0.75)
        let session = AudioAnalysisSession()
        let stream = AudioAnalysisStream(gate: session.gate, cancel: { session.cancel() })
        let wav = makeWAV(sampleRate: 44_100, channels: 2, seconds: 2)
        let task = Task.detached {
            await AudioAnalysisRunner.run(
                session: session,
                input: .reader(DataIOReader(data: wav),
                               formatHint: "wav"),
                request: request
            )
        }
        session.install(task: task)

        var iterator = stream.makeAsyncIterator()
        var buffers: [AudioAnalysisBuffer] = []
        while let buffer = try await iterator.next() {
            buffers.append(buffer)
        }
        await task.value

        XCTAssertFalse(buffers.isEmpty)
        var previousEnd: Int64? = nil
        var totalFrames: Int64 = 0
        for (index, buffer) in buffers.enumerated() {
            XCTAssertEqual(buffer.pcm.format.sampleRate, 48_000)
            XCTAssertEqual(buffer.pcm.format.channelCount, 1)
            XCTAssertGreaterThanOrEqual(buffer.sourceSamplePosition, 12_000)
            XCTAssertLessThan(buffer.sourceSamplePosition, 36_000)
            XCTAssertFalse(buffer.isDiscontinuous, "unexpected source gap at buffer \(index)")
            if let previousEnd { XCTAssertEqual(buffer.sourceSamplePosition, previousEnd) }
            totalFrames += Int64(buffer.pcm.frameLength)
            previousEnd = buffer.sourceSamplePosition + Int64(buffer.pcm.frameLength)
        }
        XCTAssertEqual(Double(totalFrames), 24_000, accuracy: 1_200)
        XCTAssertEqual(Double(buffers.first!.sourceSamplePosition), 12_000, accuracy: 120)
        XCTAssertEqual(Double(previousEnd!), 36_000, accuracy: 120)
    }

    func testRunnerDoesNotOpenSourceBeforeFirstConsumerDemand() async throws {
        let request = try AudioAnalysisRequest(audioTrackID: 0, range: 0..<1)
        let session = AudioAnalysisSession()
        let reader = CountingReader()
        let stream = AudioAnalysisStream(gate: session.gate, cancel: { session.cancel() })
        let task = Task.detached {
            await AudioAnalysisRunner.run(session: session, input: .reader(reader, formatHint: "wav"), request: request)
        }
        session.install(task: task)

        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(reader.accessCount(), 0)
        stream.cancel()
        await task.value
    }
}
