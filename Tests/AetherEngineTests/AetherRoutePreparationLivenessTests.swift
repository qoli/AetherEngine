import Foundation
import Testing
@testable import AetherEngine

private actor ManualRoutePreparationClock:
    AetherRoutePreparationLivenessClock
{
    private struct Waiter {
        let deadline: TimeInterval
        let continuation:
            CheckedContinuation<Void, Error>
    }

    private var currentTime: TimeInterval = 0
    private var waiters: [Waiter] = []

    func now() async -> TimeInterval {
        currentTime
    }

    func sleep(for seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        let deadline = currentTime + seconds
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
        currentTime += seconds
        let ready = waiters.filter {
            $0.deadline <= currentTime
        }
        waiters.removeAll {
            $0.deadline <= currentTime
        }
        ready.forEach {
            $0.continuation.resume()
        }
    }

    func nextDeadline() -> TimeInterval? {
        waiters.map(\.deadline).min()
    }
}

@MainActor
private final class RouteProgressRecorder {
    private(set) var ordinals: [UInt64] = []

    func record(
        _ evidence:
            AetherRoutePreparationProgressEvidence
    ) {
        ordinals.append(evidence.semanticOrdinal)
    }
}

@MainActor
private final class ControlledRoutePreparation {
    private var continuation:
        CheckedContinuation<Void, Never>?
    private(set) var activeReaderCount = 0
    private(set) var maximumActiveReaderCount = 0
    private(set) var stopCount = 0
    private(set) var didQuiesce = false
    private(set) var successorStartedAfterQuiescence = false

    func run() async throws {
        activeReaderCount += 1
        maximumActiveReaderCount = max(
            maximumActiveReaderCount,
            activeReaderCount
        )
        await withCheckedContinuation {
            continuation = $0
        }
        activeReaderCount -= 1
        throw CancellationError()
    }

    func stopAndWaitForIOQuiescence() async {
        stopCount += 1
        let pending = continuation
        continuation = nil
        pending?.resume()
        while activeReaderCount > 0 {
            await Task.yield()
        }
        didQuiesce = true
    }

    func startSuccessor() {
        successorStartedAfterQuiescence =
            didQuiesce && activeReaderCount == 0
    }
}

@MainActor
private final class RouteRecoveryOwnerState {
    var phase: AetherPlaybackLivenessPhase?
}

@Suite("Route preparation liveness")
struct AetherRoutePreparationLivenessTests {
    private enum HarnessError: Error {
        case clockDidNotSuspend(at: TimeInterval)
        case progressWasNotObserved(Int)
        case expectedNoProgress
    }

    @MainActor
    private func waitForSleep(
        _ clock: ManualRoutePreparationClock,
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
    private func waitForProgress(
        _ recorder: RouteProgressRecorder,
        count: Int
    ) async throws {
        for _ in 0..<1_000 {
            if recorder.ordinals.count == count {
                return
            }
            await Task.yield()
        }
        throw HarnessError.progressWasNotObserved(count)
    }

    @MainActor
    @Test(
        "semantic packet progress keeps fixed unique bytes alive beyond 300 seconds"
    )
    func semanticProgressResetsEveryNoProgressWindow()
        async throws
    {
        let clock = ManualRoutePreparationClock()
        let ledger =
            AetherRoutePreparationProgressLedger()
        let recorder = RouteProgressRecorder()
        let supervisor =
            AetherRoutePreparationLivenessSupervisor(
                policy:
                    AetherPlaybackLivenessPolicy
                        .production,
                clock: clock,
                pollIntervalSeconds: 35
            )
        let task = Task { @MainActor in
            try await supervisor.waitForNoProgress(
                attempt: 1,
                evidence: {
                    let snapshot = ledger.snapshot
                    return AetherRoutePreparationProgressEvidence(
                        uniqueBytes: 4_096,
                        semanticOrdinal: snapshot.ordinal,
                        semanticProgressUptimeSeconds:
                            snapshot
                                .lastProgressUptimeSeconds
                    )
                },
                onProgress: {
                    recorder.record($0)
                }
            )
        }

        for index in 1...10 {
            let deadline = TimeInterval(index * 35)
            try await waitForSleep(
                clock,
                deadline: deadline
            )
            await clock.advance(by: 34)
            ledger.record(
                .demuxPacket,
                at: deadline - 1
            )
            await clock.advance(by: 1)
            try await waitForProgress(
                recorder,
                count: index
            )
        }

        #expect(await clock.now() == 350)
        #expect(
            recorder.ordinals
                == Array(1...10).map(UInt64.init)
        )
        try await waitForSleep(clock, deadline: 385)
        task.cancel()
        await clock.advance(by: 35)
        do {
            _ = try await task.value
            Issue.record("cancelled supervisor returned a stall")
        } catch is CancellationError {
            // Expected: the same route remained live until explicit cancel.
        }
    }

    @MainActor
    @Test(
        "true zero progress stops and quiesces before successor generation"
    )
    func noProgressUsesCooperativeQuiescenceHandoff()
        async throws
    {
        let clock = ManualRoutePreparationClock()
        let controlled = ControlledRoutePreparation()
        let supervisor =
            AetherRoutePreparationLivenessSupervisor(
                policy:
                    AetherPlaybackLivenessPolicy
                        .production,
                clock: clock,
                pollIntervalSeconds: 35
            )
        let race =
            AetherRoutePreparationLivenessRace()
        let task = Task { @MainActor in
            try await race.run(
                operation: {
                    try await controlled.run()
                },
                monitor: {
                    try await supervisor.waitForNoProgress(
                        attempt: 1,
                        evidence: {
                            AetherRoutePreparationProgressEvidence(
                                uniqueBytes: 0,
                                semanticOrdinal: 0,
                                semanticProgressUptimeSeconds: nil
                            )
                        }
                    )
                },
                stopAndWaitForIOQuiescence: { _ in
                    await controlled
                        .stopAndWaitForIOQuiescence()
                }
            )
        }

        try await waitForSleep(clock, deadline: 35)
        await clock.advance(by: 35)

        do {
            try await task.value
            throw HarnessError.expectedNoProgress
        } catch let noProgress
                as AetherRoutePreparationNoProgress {
            #expect(noProgress.attempt == 1)
            #expect(noProgress.windowSeconds == 35)
        }
        controlled.startSuccessor()
        #expect(controlled.stopCount == 1)
        #expect(controlled.didQuiesce)
        #expect(controlled.activeReaderCount == 0)
        #expect(controlled.maximumActiveReaderCount == 1)
        #expect(
            controlled.successorStartedAfterQuiescence
        )
    }

    @MainActor
    @Test(
        "inner readiness gets a bounded timer handoff but cannot suppress source recovery"
    )
    func innerReadinessOwnershipIsBounded()
        async throws
    {
        let clock = ManualRoutePreparationClock()
        let owner = RouteRecoveryOwnerState()
        owner.phase = .preparingRoute
        let supervisor =
            AetherRoutePreparationLivenessSupervisor(
                policy:
                    AetherPlaybackLivenessPolicy
                        .production,
                clock: clock,
                pollIntervalSeconds: 35,
                recoveryOwnerGraceSeconds: 2
            )
        let task = Task { @MainActor in
            try await supervisor.waitForNoProgress(
                attempt: 1,
                evidence: {
                    AetherRoutePreparationProgressEvidence(
                        uniqueBytes: 0,
                        semanticOrdinal: 0,
                        semanticProgressUptimeSeconds: nil
                    )
                },
                recoveryOwnerPhase: {
                    owner.phase
                }
            )
        }

        try await waitForSleep(clock, deadline: 35)
        await clock.advance(by: 35)
        try await waitForSleep(clock, deadline: 37)
        owner.phase = .retryScheduled
        await clock.advance(by: 2)

        let noProgress = try await task.value
        #expect(noProgress.windowSeconds == 35)
        #expect(noProgress.evidence.semanticOrdinal == 0)
    }

    @Test(
        "inner carrier retry projects attempt and next retry without becoming progress"
    )
    func innerRetryProjectionIsPrivacySafeAndReversible() {
        var projection =
            AetherRoutePreparationRetryProjection()
        projection.apply(.attemptStarted(attempt: 1))
        #expect(projection.phase == .preparingRoute)
        #expect(projection.attempt == 1)
        #expect(projection.nextRetryUptimeSeconds == nil)

        projection.apply(
            .retryScheduled(
                completedAttempt: 1,
                nextAttempt: 2,
                nextRetryUptimeSeconds: 42
            )
        )
        #expect(projection.phase == .retryScheduled)
        #expect(projection.attempt == 2)
        #expect(projection.nextRetryUptimeSeconds == 42)

        projection.apply(.attemptStarted(attempt: 2))
        #expect(projection.phase == .preparingRoute)
        #expect(projection.attempt == 2)
        #expect(projection.nextRetryUptimeSeconds == nil)

        projection.apply(.completed)
        #expect(
            projection
                == AetherRoutePreparationRetryProjection()
        )
    }
}
