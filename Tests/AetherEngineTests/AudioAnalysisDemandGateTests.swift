import XCTest
import AVFAudio
@testable import AetherEngine

final class AudioAnalysisDemandGateTests: XCTestCase {
    private actor Counter {
        private var value = 0
        func increment() { value += 1 }
        func read() -> Int { value }
    }

    private func buffer() -> AudioAnalysisBuffer {
        let pcm = AVAudioPCMBuffer(
            pcmFormat: AetherEngine.audioAnalysisFormat,
            frameCapacity: 480
        )!
        pcm.frameLength = 480
        return AudioAnalysisBuffer(pcm: pcm, sourceSamplePosition: 96_000)
    }

    func testProducerDoesNotAdvanceWithoutConsumerDemand() async throws {
        let gate = AudioAnalysisDemandGate()
        let counter = Counter()
        let output = buffer()
        let producer = Task {
            try await gate.waitForDemand()
            await counter.increment()
            _ = await gate.yield(output)
        }

        try await Task.sleep(for: .milliseconds(20))
        let beforeDemand = await counter.read()
        XCTAssertEqual(beforeDemand, 0)

        let stream = AudioAnalysisStream(gate: gate, cancel: { Task { await gate.cancel() } })
        var iterator = stream.makeAsyncIterator()
        let received = try await iterator.next()
        let afterDemand = await counter.read()
        XCTAssertEqual(afterDemand, 1)
        XCTAssertEqual(received?.sourceSamplePosition, 96_000)
        XCTAssertEqual(received?.sourceTime, 2.0)
        _ = try await producer.value
    }

    func testFinishResumesDemandingConsumerWithNil() async throws {
        let gate = AudioAnalysisDemandGate()
        let stream = AudioAnalysisStream(gate: gate, cancel: { Task { await gate.cancel() } })
        var iterator = stream.makeAsyncIterator()
        let consumer = Task { try await iterator.next() }
        try await Task.sleep(for: .milliseconds(10))
        await gate.finish()
        let end = try await consumer.value
        XCTAssertNil(end)
    }

    func testCancellationIsTypedAndWakesProducer() async {
        let gate = AudioAnalysisDemandGate()
        let producer = Task { () -> Error? in
            do {
                try await gate.waitForDemand()
                return nil
            } catch { return error }
        }
        try? await Task.sleep(for: .milliseconds(10))
        await gate.cancel()
        let error = await producer.value
        XCTAssertEqual(error as? AudioAnalysisError, .cancelled)
    }

    func testSecondIteratorIsRejectedEvenWhenFirstIsNotWaiting() async throws {
        let gate = AudioAnalysisDemandGate()
        let stream = AudioAnalysisStream(gate: gate, cancel: { Task { await gate.cancel() } })
        var first = stream.makeAsyncIterator()
        var second = stream.makeAsyncIterator()

        let firstWait = Task { try await first.next() }
        try await Task.sleep(for: .milliseconds(10))
        do {
            _ = try await second.next()
            XCTFail("second iterator unexpectedly consumed the single-cursor stream")
        } catch let error as AudioAnalysisError {
            XCTAssertEqual(error, .concurrentConsumer)
        }
        await gate.cancel()
        _ = try? await firstWait.value
    }
}
