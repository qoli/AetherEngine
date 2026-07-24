import Foundation
import Testing
@testable import AetherEngine

private actor ManualLivenessDiagnosticClock:
    AetherLivenessDiagnosticClock
{
    private struct Waiter {
        let deadline: TimeInterval
        let continuation:
            CheckedContinuation<Void, Error>
    }

    private var now: TimeInterval = 0
    private var waiters: [Waiter] = []

    func sleep(for seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        let deadline = now + seconds
        try await withCheckedThrowingContinuation {
            continuation in
            waiters.append(
                Waiter(
                    deadline: deadline,
                    continuation: continuation
                )
            )
        }
        try Task.checkCancellation()
    }

    func advance(by seconds: TimeInterval) {
        now += seconds
        let ready = waiters.filter { $0.deadline <= now }
        waiters.removeAll { $0.deadline <= now }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func nextDeadline() -> TimeInterval? {
        waiters.map(\.deadline).min()
    }
}

@MainActor
private final class LivenessCheckpointRecorder {
    private(set) var elapsedSeconds: [TimeInterval] = []

    func record(_ elapsed: TimeInterval) {
        elapsedSeconds.append(elapsed)
    }
}

@Suite("Aether liveness diagnostic scheduler")
struct AetherLivenessDiagnosticSchedulerTests {
    private enum HarnessError: Error {
        case clockDidNotSuspend(at: TimeInterval)
        case checkpointWasNotEmitted(Int)
    }

    @MainActor
    private func waitForSleep(
        _ clock: ManualLivenessDiagnosticClock,
        deadline: TimeInterval
    ) async throws {
        for _ in 0..<1_000 {
            if await clock.nextDeadline() == deadline {
                return
            }
            await Task.yield()
        }
        throw HarnessError.clockDidNotSuspend(at: deadline)
    }

    @MainActor
    private func waitForCheckpoint(
        _ recorder: LivenessCheckpointRecorder,
        count: Int
    ) async throws {
        for _ in 0..<1_000 {
            if recorder.elapsedSeconds.count == count {
                return
            }
            await Task.yield()
        }
        throw HarnessError.checkpointWasNotEmitted(count)
    }

    @MainActor
    @Test(
        "15, 45, 90, 300 and repeating checkpoints are diagnostic only"
    )
    func productionCheckpointsDoNotMutatePlaybackState()
        async throws
    {
        let clock = ManualLivenessDiagnosticClock()
        let recorder = LivenessCheckpointRecorder()
        let session = AetherPlaybackSession(
            url: URL(
                fileURLWithPath:
                    "/tmp/aether-liveness-diagnostic-clock"
            ),
            options: LoadOptions(),
            variantSelection: .highestBandwidth,
            livenessDiagnosticClock: clock,
            livenessDiagnosticCheckpointObserver: {
                recorder.record($0)
            }
        )

        session.beginLivenessObservation(phase: .buffering)
        let playbackState = session.state
        let livenessState = session.livenessSnapshot

        let deadlines: [TimeInterval] = [
            15,
            45,
            90,
            300,
            600,
            900,
        ]
        var previous: TimeInterval = 0

        for (index, deadline) in deadlines.enumerated() {
            try await waitForSleep(clock, deadline: deadline)
            let remaining = deadline - previous
            await clock.advance(by: remaining - 1)
            await Task.yield()
            #expect(recorder.elapsedSeconds.count == index)
            #expect(session.state == playbackState)
            #expect(session.livenessSnapshot == livenessState)

            await clock.advance(by: 1)
            try await waitForCheckpoint(
                recorder,
                count: index + 1
            )
            #expect(
                recorder.elapsedSeconds == Array(
                    deadlines.prefix(index + 1)
                )
            )
            #expect(session.state == playbackState)
            #expect(session.livenessSnapshot == livenessState)
            previous = deadline
        }

        session.stop()
        await clock.advance(by: 300)
        await session.waitForStopIOQuiescence()
    }
}
