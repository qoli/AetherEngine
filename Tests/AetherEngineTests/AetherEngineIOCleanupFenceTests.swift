import Foundation
import Testing
@testable import AetherEngine

private actor AetherCleanupTestGate {
    private var isOpen = false
    private var waiters:
        [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation {
            continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private final class HLSGenerationSequenceProbe:
    @unchecked Sendable
{
    struct Snapshot: Sendable, Equatable {
        let cancellationRequested: Bool
        let diagnosticCount: Int
        let waitTimeouts: [TimeInterval]
        let ioQuiesced: Bool
        let successorOpened: Bool
        let maximumConcurrentReaders: Int
    }

    let secondWorkerWaitEntered =
        DispatchSemaphore(value: 0)
    let releaseWorker =
        DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var cancellationRequested = false
    private var diagnosticCount = 0
    private var waitTimeouts: [TimeInterval] = []
    private var ioQuiesced = false
    private var successorOpened = false
    private var activeReaders = 1
    private var maximumConcurrentReaders = 1

    func requestCancellation() {
        lock.lock()
        cancellationRequested = true
        lock.unlock()
    }

    func waitForWorker(
        timeout: TimeInterval
    ) -> Bool {
        lock.lock()
        waitTimeouts.append(timeout)
        let call = waitTimeouts.count
        lock.unlock()
        if call == 1 {
            return false
        }
        secondWorkerWaitEntered.signal()
        releaseWorker.wait()
        return true
    }

    func recordDiagnostic() {
        lock.lock()
        diagnosticCount += 1
        lock.unlock()
    }

    func waitForIOQuiescence() {
        lock.lock()
        ioQuiesced = true
        activeReaders -= 1
        lock.unlock()
    }

    func openSuccessor() {
        lock.lock()
        activeReaders += 1
        maximumConcurrentReaders = max(
            maximumConcurrentReaders,
            activeReaders
        )
        successorOpened = true
        lock.unlock()
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            cancellationRequested:
                cancellationRequested,
            diagnosticCount: diagnosticCount,
            waitTimeouts: waitTimeouts,
            ioQuiesced: ioQuiesced,
            successorOpened: successorOpened,
            maximumConcurrentReaders:
                maximumConcurrentReaders
        )
    }
}

private final class HLSBooleanBox:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool) {
        self.value = value
    }

    func set(_ value: Bool) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    var snapshot: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class HLSProgressCapture:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var totals: [Int64] = []
    private var probeMilestones = 0

    func record(
        _ progress: AetherFetchedByteProgress
    ) {
        lock.lock()
        totals.append(
            progress.totalAdvancedBytes
        )
        lock.unlock()
    }

    func recordProbeMilestone() {
        lock.lock()
        probeMilestones += 1
        lock.unlock()
    }

    var snapshot:
        (totals: [Int64], probeMilestones: Int)
    {
        lock.lock()
        defer { lock.unlock() }
        return (
            totals,
            probeMilestones
        )
    }
}

@Suite(
    "Aether public I/O cleanup admission",
    .serialized
)
@MainActor
struct AetherEngineIOCleanupFenceTests {
    @Test(
        "Public load admits no source before predecessor cleanup"
    )
    func loadAwaitsPredecessorCleanup() async throws {
        let engine = try AetherEngine()
        let gate = AetherCleanupTestGate()
        engine.installNativeVideoIOCleanup(
            Task.detached {
                await gate.wait()
            }
        )
        let initialGeneration =
            engine.loadGeneration
        let load = Task { @MainActor in
            try await engine.load(
                url: URL(
                    string:
                        "https://example.invalid/not-opened.mp4"
                )!
            )
        }

        for _ in 0..<100
        where engine.loadGeneration
            == initialGeneration {
            await Task.yield()
        }
        #expect(
            engine.loadGeneration
                == initialGeneration + 1
        )
        #expect(engine.loadedURL == nil)
        #expect(engine.state == .idle)

        load.cancel()
        await gate.open()
        do {
            _ = try await load.value
            Issue.record(
                "Cancelled load unexpectedly succeeded"
            )
        } catch is CancellationError {
            // Expected after the fail-closed cleanup wait.
        }
        await engine.waitForIOQuiescence()
    }

    @Test(
        "Public stop publishes idle only after cleanup quiescence"
    )
    func stopDefersIdlePublication() async throws {
        let engine = try AetherEngine()
        engine.state = .playing
        let gate = AetherCleanupTestGate()
        engine.installNativeVideoIOCleanup(
            Task.detached {
                await gate.wait()
            }
        )

        engine.stop()
        await Task.yield()
        #expect(engine.state == .playing)

        await gate.open()
        await engine.waitForIOQuiescence()
        for _ in 0..<100
        where engine.state != .idle {
            await Task.yield()
        }
        #expect(engine.state == .idle)
    }

    @Test(
        "Superseded stop cannot publish idle over a successor"
    )
    func staleStopFinalizerCannotPublishIdle()
        async throws
    {
        let engine = try AetherEngine()
        engine.state = .playing
        let gate = AetherCleanupTestGate()
        engine.installNativeVideoIOCleanup(
            Task.detached {
                await gate.wait()
            }
        )

        engine.stop()
        engine.loadGeneration &+= 1
        engine.state = .loading
        await gate.open()
        await engine.waitForIOQuiescence()
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(engine.state == .loading)
    }
}

@Suite(
    "HLS reopen I/O cleanup fence",
    .serialized
)
struct HLSReopenIOCleanupFenceTests {
    @Test(
        "Diagnostic checkpoint never admits an overlapping reader"
    )
    func successorWaitsForWorkerAndIOQuiescence()
    {
        let probe = HLSGenerationSequenceProbe()
        let replacementFinished =
            DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            HLSReopenGenerationGate
                .retirePredecessor(
                    requestCancellation: {
                        probe.requestCancellation()
                    },
                    waitForWorker: { timeout in
                        probe.waitForWorker(
                            timeout: timeout
                        )
                    },
                    waitForIOQuiescence: {
                        probe.waitForIOQuiescence()
                    },
                    onCancellationUnresponsive: {
                        probe.recordDiagnostic()
                    }
                )
            probe.openSuccessor()
            replacementFinished.signal()
        }

        #expect(
            probe.secondWorkerWaitEntered.wait(
                timeout: .now() + 2
            ) == .success
        )
        let checkpoint = probe.snapshot
        #expect(checkpoint.cancellationRequested)
        #expect(checkpoint.diagnosticCount == 1)
        #expect(!checkpoint.ioQuiesced)
        #expect(!checkpoint.successorOpened)
        #expect(
            checkpoint.waitTimeouts
                == [2, 2]
        )

        probe.releaseWorker.signal()
        #expect(
            replacementFinished.wait(
                timeout: .now() + 2
            ) == .success
        )
        let completed = probe.snapshot
        #expect(completed.ioQuiesced)
        #expect(completed.successorOpened)
        #expect(
            completed.maximumConcurrentReaders == 1
        )
    }

    @Test(
        "Shutdown wakes long reopen backoff and rejects late admission"
    )
    func shutdownCancelsRetryBackoff()
        throws
    {
        let fence = HLSReopenIOCleanupFence()
        let operation = try #require(
            fence.beginOperation()
        )
        let waitStarted =
            DispatchSemaphore(value: 0)
        let waitFinished =
            DispatchSemaphore(value: 0)
        let retryAllowed = HLSBooleanBox(true)
        DispatchQueue.global().async {
            waitStarted.signal()
            retryAllowed.set(
                fence.waitForRetryDelay(
                    30,
                    operation: operation
                )
            )
            waitFinished.signal()
        }
        #expect(
            waitStarted.wait(
                timeout: .now() + 2
            ) == .success
        )

        let started = DispatchTime.now()
        _ = fence.beginShutdown()
        #expect(
            waitFinished.wait(
                timeout: .now() + 2
            ) == .success
        )
        #expect(!retryAllowed.snapshot)
        let elapsed =
            Double(
                DispatchTime.now().uptimeNanoseconds
                    - started.uptimeNanoseconds
            ) / 1_000_000_000
        #expect(elapsed < 1)

        let late = Demuxer()
        #expect(
            !fence.register(
                late,
                for: operation
            )
        )
        late.close()
        late.waitForIOQuiescence()
        fence.endOperation(operation)
        #expect(fence.waitForQuiescence())
    }

    @Test(
        "Superseded restart retains detached worker until retirement"
    )
    func stopWaitsForDetachedPredecessorLease()
        throws
    {
        let fence = HLSReopenIOCleanupFence()
        let operation = try #require(
            fence.beginOperation()
        )
        let predecessorDetached =
            DispatchSemaphore(value: 0)
        let stopWonEpochGuard =
            DispatchSemaphore(value: 0)
        let retirementStarted =
            DispatchSemaphore(value: 0)
        let releaseRetirement =
            DispatchSemaphore(value: 0)
        let stopFinished =
            DispatchSemaphore(value: 0)
        let lease = HLSDetachedPredecessorLease {
            retirementStarted.signal()
            releaseRetirement.wait()
        }

        let restartFinished =
            DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer {
                // Models every early return from performRestart after its
                // producer field has been detached.
                lease.ensureQuiescence()
                fence.endOperation(operation)
                restartFinished.signal()
            }
            predecessorDetached.signal()
            stopWonEpochGuard.wait()
        }
        #expect(
            predecessorDetached.wait(
                timeout: .now() + 2
            ) == .success
        )

        _ = fence.beginShutdown()
        DispatchQueue.global().async {
            _ = fence.waitForQuiescence()
            stopFinished.signal()
        }
        // The restart now observes the stop/epoch guard and returns.
        stopWonEpochGuard.signal()
        #expect(
            retirementStarted.wait(
                timeout: .now() + 2
            ) == .success
        )
        #expect(
            stopFinished.wait(
                timeout: .now() + 0.05
            ) == .timedOut
        )

        releaseRetirement.signal()
        #expect(
            restartFinished.wait(
                timeout: .now() + 2
            ) == .success
        )
        #expect(
            stopFinished.wait(
                timeout: .now() + 2
            ) == .success
        )
    }

    @Test(
        "Hundreds of failures keep retry admission with capped backoff"
    )
    func attemptLedgerHasNoTransportCap() {
        var ledger = HLSReopenAttemptLedger()
        var observed: [TimeInterval] = []
        for index in 1...500 {
            #expect(ledger.attempt == index)
            if index <= 8 || index == 500 {
                observed.append(
                    ledger.backoffSeconds
                )
            }
            ledger.recordFailure()
        }
        #expect(ledger.attempt == 501)
        #expect(ledger.backoffSeconds == 30)
        #expect(
            observed
                == [1, 2, 4, 8, 15, 30, 30, 30, 30]
        )
    }

    @Test(
        "Retry diagnostics use manual-clock liveness checkpoints"
    )
    func retryDiagnosticsAreCheckpointBounded() {
        var ledger = HLSReopenAttemptLedger()

        let first =
            ledger.recordFailure(
                nowUptime: 1_000
            )
        #expect(first?.cumulativeFailures == 1)
        #expect(first?.checkpointSeconds == nil)
        #expect(
            ledger.recordFailure(
                nowUptime: 1_001
            ) == nil
        )
        #expect(
            ledger.recordFailure(
                nowUptime: 1_014.9
            ) == nil
        )
        #expect(
            ledger.recordFailure(
                nowUptime: 1_015
            )?.checkpointSeconds == 15
        )
        #expect(
            ledger.recordFailure(
                nowUptime: 1_044
            ) == nil
        )
        #expect(
            ledger.recordFailure(
                nowUptime: 1_045
            )?.checkpointSeconds == 45
        )
        #expect(
            ledger.recordFailure(
                nowUptime: 1_090
            )?.checkpointSeconds == 90
        )
        #expect(
            ledger.recordFailure(
                nowUptime: 1_300
            )?.checkpointSeconds == 300
        )
        #expect(
            ledger.recordFailure(
                nowUptime: 1_599
            ) == nil
        )
        #expect(
            ledger.recordFailure(
                nowUptime: 1_600
            )?.checkpointSeconds == 600
        )

        ledger.resetAfterProgress()
        #expect(ledger.attempt == 1)
        #expect(
            ledger.recordFailure(
                nowUptime: 2_000
            )?.checkpointSeconds == nil
        )
    }

    @Test(
        "No-cut wall clock emits diagnostics without a terminal boundary"
    )
    func noCutDiagnosticsUseLivenessCheckpoints() {
        #expect(
            HLSSegmentProducer
                .latestLivenessDiagnosticCheckpoint(
                    elapsed: 14.9
                ) == nil
        )
        #expect(
            HLSSegmentProducer
                .latestLivenessDiagnosticCheckpoint(
                    elapsed: 15
                ) == 15
        )
        #expect(
            HLSSegmentProducer
                .latestLivenessDiagnosticCheckpoint(
                    elapsed: 89
                ) == 45
        )
        #expect(
            HLSSegmentProducer
                .latestLivenessDiagnosticCheckpoint(
                    elapsed: 599
                ) == 300
        )
        #expect(
            HLSSegmentProducer
                .latestLivenessDiagnosticCheckpoint(
                    elapsed: 600
                ) == 600
        )
    }

    @Test(
        "Backpressure structural cap publishes terminal instead of parking"
    )
    func backpressureCapHasTypedTerminalDecision() {
        #expect(
            HLSVideoEngine
                .backpressureRecoveryTerminalCaseCode(
                    hasPlaybackPosition: true,
                    attempts:
                        HLSVideoEngine
                            .maxConsecutiveWedgeReanchors
                ) == nil
        )
        #expect(
            HLSVideoEngine
                .backpressureRecoveryTerminalCaseCode(
                    hasPlaybackPosition: true,
                    attempts:
                        HLSVideoEngine
                            .maxConsecutiveWedgeReanchors
                            + 1
                )
                == "vod.backpressureRecoveryExhausted"
        )
        #expect(
            HLSVideoEngine
                .backpressureRecoveryTerminalCaseCode(
                    hasPlaybackPosition: false,
                    attempts: 0
                )
                == "vod.backpressurePositionUnavailable"
        )
    }

    @Test(
        "Late producer recovery cannot restart a successor generation"
    )
    func structuralRecoveryRequiresExactGeneration() {
        #expect(
            HLSRecoveryEntryPolicy
                .shouldAdmit(
                    currentEpoch: 9,
                    expectedEpoch: 9,
                    expectedProducerIsCurrent:
                        true
                )
        )
        #expect(
            !HLSRecoveryEntryPolicy
                .shouldAdmit(
                    currentEpoch: 10,
                    expectedEpoch: 9,
                    expectedProducerIsCurrent:
                        true
                )
        )
        #expect(
            !HLSRecoveryEntryPolicy
                .shouldAdmit(
                    currentEpoch: 9,
                    expectedEpoch: 9,
                    expectedProducerIsCurrent:
                        false
                )
        )
    }

    @Test(
        "Fresh HLS generations inherit one monotonic preflight liveness ledger"
    )
    func progressiveLivenessSurvivesRestart() throws {
        let ledger =
            AetherFetchedByteProgressLedger()
        let capture = HLSProgressCapture()
        let engine = HLSVideoEngine(
            url: URL(
                string:
                    "https://example.invalid/exact.mov"
            )!
        )
        engine.adoptProgressiveSourceIdentity(
            byteStore: nil,
            generation: nil,
            fetchedByteProgressLedger:
                ledger,
            onFetchedByteProgress: {
                capture.record($0)
            },
            onProbeMilestone: {
                capture.recordProbeMilestone()
            }
        )

        let initial = Demuxer()
        let successor = Demuxer()
        engine.configureProgressiveLiveness(
            on: initial
        )
        engine.configureProgressiveLiveness(
            on: successor
        )
        #expect(
            initial.fetchedByteProgressLedger
                === ledger
        )
        #expect(
            successor.fetchedByteProgressLedger
                === ledger
        )

        let first = try #require(
            initial.fetchedByteProgressLedger
                .record(
                    offset: 0,
                    count: 64,
                    kind: .origin
                )
        )
        initial.onFetchedByteProgress?(
            first
        )
        let second = try #require(
            successor.fetchedByteProgressLedger
                .record(
                    offset: 32,
                    count: 64,
                    kind: .origin
                )
        )
        successor.onFetchedByteProgress?(
            second
        )
        initial.onProbeMilestone?()
        successor.onProbeMilestone?()

        let snapshot = capture.snapshot
        #expect(
            snapshot.totals == [64, 96]
        )
        #expect(
            snapshot.probeMilestones == 2
        )
    }

    @Test(
        "Shutdown tracks every operation and Demuxer until discard"
    )
    func shutdownWaitsForAllReopenOwners()
        throws
    {
        let fence = HLSReopenIOCleanupFence()
        let firstOperation = try #require(
            fence.beginOperation()
        )
        let secondOperation = try #require(
            fence.beginOperation()
        )
        let firstDemuxer = Demuxer()
        let secondDemuxer = Demuxer()
        #expect(
            fence.register(
                firstDemuxer,
                for: firstOperation
            )
        )
        #expect(
            fence.register(
                secondDemuxer,
                for: secondOperation
            )
        )

        let admitted = fence.beginShutdown()
        #expect(admitted.count == 2)
        for demuxer in admitted {
            demuxer.markClosed()
        }
        #expect(fence.beginOperation() == nil)
        #expect(
            !fence.waitForQuiescence(
                timeout: 0.001
            )
        )

        fence.discardAndWait(firstDemuxer)
        fence.endOperation(firstOperation)
        #expect(
            fence.snapshot
                == .init(
                    isShuttingDown: true,
                    operationCount: 1,
                    demuxerCount: 1
                )
        )
        #expect(
            !fence.waitForQuiescence(
                timeout: 0.001
            )
        )

        fence.discardAndWait(secondDemuxer)
        fence.endOperation(secondOperation)
        #expect(fence.waitForQuiescence())
        #expect(
            fence.snapshot
                == .init(
                    isShuttingDown: true,
                    operationCount: 0,
                    demuxerCount: 0
                )
        )
    }

    @Test(
        "Transferred Demuxer leaves reopen ownership atomically"
    )
    func transferMovesOwnershipToSession() throws {
        let fence = HLSReopenIOCleanupFence()
        let operation = try #require(
            fence.beginOperation()
        )
        let demuxer = Demuxer()
        #expect(
            fence.register(
                demuxer,
                for: operation
            )
        )

        fence.transferToSession(demuxer)
        #expect(
            fence.snapshot.demuxerCount == 0
        )
        _ = fence.beginShutdown()
        #expect(
            !fence.waitForQuiescence(
                timeout: 0.001
            )
        )
        fence.endOperation(operation)
        #expect(fence.waitForQuiescence())

        demuxer.close()
        demuxer.waitForIOQuiescence()
    }

    @Test(
        "VOD reopen admits only the exact validator-bound generation"
    )
    func vodGenerationAdmissionFailsClosed()
        throws
    {
        let expected =
            try SourceByteStoreGeneration(
                contentLength: 25_005_843_710,
                validator:
                    .strongETag("\"stable\"")
            )
        #expect(
            HLSReopenIdentityValidator
                .vodGenerationFailure(
                    expected: expected,
                    fresh: expected,
                    requiresValidatorBoundGeneration:
                        true
                ) == nil
        )

        let changed =
            try SourceByteStoreGeneration(
                contentLength: expected.contentLength,
                validator:
                    .strongETag("\"changed\"")
            )
        #expect(
            HLSReopenIdentityValidator
                .vodGenerationFailure(
                    expected: expected,
                    fresh: changed,
                    requiresValidatorBoundGeneration:
                        true
                )?.caseCode
                == "vod.progressiveSourceGenerationChanged"
        )
        #expect(
            HLSReopenIdentityValidator
                .vodGenerationFailure(
                    expected: nil,
                    fresh: nil,
                    requiresValidatorBoundGeneration:
                        true
                )?.caseCode
                == "vod.progressiveSourceGenerationUnverifiable"
        )
        #expect(
            HLSReopenIdentityValidator
                .vodGenerationFailure(
                    expected: nil,
                    fresh: nil,
                    requiresValidatorBoundGeneration:
                        false
                ) == nil
        )
    }

    @Test(
        "Fresh live and VOD readers must preserve codec timebase and audio layout"
    )
    func streamShapeAdmissionRejectsDrift() {
        let expected =
            reopenShape(
                audioLayout: "5.1",
                videoTimeBaseDenominator:
                    90_000
            )
        #expect(
            HLSReopenIdentityValidator
                .streamShapeFailure(
                    expected: expected,
                    fresh: expected,
                    isLive: true
                ) == nil
        )

        let layoutDrift =
            reopenShape(
                audioLayout: "stereo",
                videoTimeBaseDenominator:
                    90_000
            )
        #expect(
            HLSReopenIdentityValidator
                .streamShapeFailure(
                    expected: expected,
                    fresh: layoutDrift,
                    isLive: true
                )?.caseCode
                == "live.streamShapeDrift"
        )

        let timeBaseDrift =
            reopenShape(
                audioLayout: "5.1",
                videoTimeBaseDenominator:
                    1_000
            )
        #expect(
            HLSReopenIdentityValidator
                .streamShapeFailure(
                    expected: expected,
                    fresh: timeBaseDrift,
                    isLive: false
                )?.caseCode
                == "vod.streamShapeDrift"
        )
    }

    @Test(
        "Terminal reopen publication is exact-epoch current and one-shot"
    )
    func terminalPublicationPolicyRejectsLateFailure() {
        #expect(
            HLSReopenTerminalPublicationPolicy
                .shouldPublish(
                    currentEpoch: 41,
                    failureEpoch: 41,
                    hasActiveSession: true,
                    hasExistingFailure: false,
                    expectedProducerIsCurrent:
                        true
                )
        )
        #expect(
            !HLSReopenTerminalPublicationPolicy
                .shouldPublish(
                    currentEpoch: 42,
                    failureEpoch: 41,
                    hasActiveSession: true,
                    hasExistingFailure: false,
                    expectedProducerIsCurrent:
                        true
                )
        )
        #expect(
            !HLSReopenTerminalPublicationPolicy
                .shouldPublish(
                    currentEpoch: 41,
                    failureEpoch: 41,
                    hasActiveSession: true,
                    hasExistingFailure: true,
                    expectedProducerIsCurrent:
                        true
                )
        )
        #expect(
            !HLSReopenTerminalPublicationPolicy
                .shouldPublish(
                    currentEpoch: 41,
                    failureEpoch: 41,
                    hasActiveSession: true,
                    hasExistingFailure: false,
                    expectedProducerIsCurrent:
                        false
                )
        )
    }

    @Test(
        "Reopen classifier retries transport but terminates canonical auth and proven corruption"
    )
    func reopenFailureClassification() {
        #expect(
            HLSReopenFailureClassifier
                .classify(
                    URLError(.timedOut),
                    caseCode: "test.timeout"
                ) == .retry
        )
        #expect(
            HLSReopenFailureClassifier
                .classify(
                    CancellationError(),
                    caseCode: "test.cancel"
                ) == .cancelled
        )
        if case .permanent(let failure) =
                HLSReopenFailureClassifier
                    .classify(
                        AVIOReaderError
                            .httpStatus(
                                statusCode: 403
                            ),
                        caseCode:
                            "test.canonicalAuth"
                    ) {
            #expect(
                failure.kind
                    == .authenticationRejected
            )
        } else {
            Issue.record(
                "Canonical 403 was not terminal"
            )
        }
        #expect(
            HLSReopenFailureClassifier
                .classify(
                    DemuxerError.readFailed(
                        code:
                            FFmpegErr.invalidData
                    ),
                    caseCode:
                        "test.partialInvalidData"
                ) == .retry
        )
        if case .permanent(let failure) =
                HLSReopenFailureClassifier
                    .classify(
                        DemuxerError.readFailed(
                            code:
                                FFmpegErr
                                    .invalidData
                        ),
                        caseCode:
                            "test.completeInvalidData",
                        hasCompleteValidatedSourceEvidence:
                            true
                    ) {
            #expect(
                failure.kind
                    == .malformedMedia
            )
        } else {
            Issue.record(
                "Complete validator-bound invalid data was not terminal"
            )
        }
    }

    private func reopenShape(
        audioLayout: String,
        videoTimeBaseDenominator: Int32
    ) -> HLSReopenStreamShape {
        HLSReopenStreamShape(
            video: .init(
                streamIndex: 0,
                codecID: 27,
                profile: 100,
                level: 51,
                pixelFormat: 0,
                width: 3_840,
                height: 2_160,
                timeBaseNumerator: 1,
                timeBaseDenominator:
                    videoTimeBaseDenominator
            ),
            audio: .init(
                streamIndex: 1,
                codecID: 86018,
                profile: 1,
                sampleFormat: 8,
                sampleRate: 48_000,
                frameSize: 1_024,
                channelCount:
                    audioLayout == "stereo"
                        ? 2
                        : 6,
                channelLayoutDescription:
                    audioLayout,
                timeBaseNumerator: 1,
                timeBaseDenominator:
                    48_000
            ),
            audioStreamCount: 1
        )
    }
}
