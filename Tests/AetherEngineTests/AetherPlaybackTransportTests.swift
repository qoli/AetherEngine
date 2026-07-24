import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AetherEngine

@MainActor
private final class ControllableOuterTransportRoute:
    AetherPlaybackTransportRoute
{
    enum Event: Equatable {
        case play
        case pause
        case setRate(Float)
        case seekStarted(seconds: Double, capturedPlaying: Bool)
        case seekCompletedWithCapturedPlay
        case seekCompletedWithCapturedPause
    }

    var transportIdentity: ObjectIdentifier {
        ObjectIdentifier(self)
    }
    var transportApplicationIsTemporarilyUnavailable = false

    private(set) var events: [Event] = []
    private var isPlaying = false
    private var pendingSeek:
        (capturedPlaying: Bool, continuation: CheckedContinuation<Void, Never>)?

    var hasPendingSeek: Bool { pendingSeek != nil }
    private(set) var lastSeekTimeout: TimeInterval?

    func play() throws {
        events.append(.play)
        isPlaying = true
    }

    func pause() throws {
        events.append(.pause)
        isPlaying = false
    }

    func setRate(_ rate: Float) throws {
        events.append(.setRate(rate))
    }

    func seek(
        to target: CMTime,
        timeout: TimeInterval
    ) async throws -> AetherPlaybackSeekResult {
        precondition(pendingSeek == nil)
        lastSeekTimeout = timeout
        let capturedPlaying = isPlaying
        events.append(
            .seekStarted(
                seconds: target.seconds,
                capturedPlaying: capturedPlaying
            )
        )
        await withCheckedContinuation { continuation in
            pendingSeek = (capturedPlaying, continuation)
        }
        if capturedPlaying {
            events.append(.seekCompletedWithCapturedPlay)
            isPlaying = true
        } else {
            events.append(.seekCompletedWithCapturedPause)
            isPlaying = false
        }
        return .applied
    }

    func completePendingSeek() {
        guard let pendingSeek else {
            Issue.record("No pending transport seek to complete")
            return
        }
        self.pendingSeek = nil
        pendingSeek.continuation.resume()
    }
}

@Suite("Aether outer transport intent")
struct AetherPlaybackTransportTests {
    private enum HarnessError: Error {
        case seekDidNotStart
    }

    @MainActor
    private func waitForPendingSeek(
        _ route: ControllableOuterTransportRoute
    ) async throws {
        for _ in 0..<100 {
            if route.hasPendingSeek { return }
            await Task.yield()
        }
        throw HarnessError.seekDidNotStart
    }

    @MainActor
    @Test("Public seek uses the liveness no-progress window")
    func publicSeekUsesLivenessWindow() async throws {
        let route = ControllableOuterTransportRoute()
        let policy = AetherPlaybackLivenessPolicy(
            noProgressWindowsSeconds: [7, 11],
            retryBackoffSeconds: [0.01],
            diagnosticCheckpointsSeconds: [0.01],
            repeatingDiagnosticIntervalSeconds: 1
        )
        let session = AetherPlaybackSession(
            url: URL(
                fileURLWithPath: "/tmp/aether-seek-liveness"
            ),
            options: LoadOptions(),
            variantSelection: .highestBandwidth,
            recoveryBudget: AetherPlaybackRecoveryBudget(
                maximumEpisodeDurationSeconds: 0.01,
                livenessPolicy: policy
            )
        )
        defer { session.stop() }
        session.installTransportRaceTestHarness(route)

        let seek = Task { @MainActor in
            try await session.seek(to: .zero)
        }
        try await waitForPendingSeek(route)
        #expect(route.lastSeekTimeout == 7)
        #expect(route.lastSeekTimeout != 0.01)
        route.completePendingSeek()
        #expect(try await seek.value == .applied)
    }

    @MainActor
    @Test("Async paused seek completion reapplies only the newest play or pause intent")
    func asyncPausedSeekUsesLatestTransportIntent() async throws {
        let route = ControllableOuterTransportRoute()
        let session = AetherPlaybackSession(
            url: URL(fileURLWithPath: "/tmp/aether-transport-race"),
            options: LoadOptions(),
            variantSelection: .highestBandwidth
        )
        defer { session.stop() }
        session.installTransportRaceTestHarness(route)

        try session.pause()
        let generation = session.transportSnapshot.routeGeneration
        let firstSeek = Task { @MainActor in
            try await session.seek(to: .zero)
        }
        try await waitForPendingSeek(route)

        // play() is newer than the paused seek, but must wait until the route
        // has landed. The delayed route completion first restores its captured
        // pause, then the outer session must issue canonical play.
        try session.play()
        let requestedPlay = session.transportSnapshot
        #expect(requestedPlay.commandSequence == 3)
        #expect(requestedPlay.routeGeneration == generation)
        #expect(requestedPlay.desiredPlaying)
        #expect(
            route.events == [
                .pause,
                .seekStarted(seconds: 0, capturedPlaying: false),
            ]
        )
        route.completePendingSeek()
        #expect(try await firstSeek.value == .applied)
        #expect(
            route.events == [
                .pause,
                .seekStarted(seconds: 0, capturedPlaying: false),
                .seekCompletedWithCapturedPause,
                .play,
            ]
        )

        let secondSeek = Task { @MainActor in
            try await session.seek(to: .zero)
        }
        try await waitForPendingSeek(route)

        // The inverse race proves a captured play completion cannot overwrite
        // a newer pause command either.
        try session.pause()
        let requestedPause = session.transportSnapshot
        #expect(requestedPause.commandSequence == 5)
        #expect(requestedPause.routeGeneration == generation)
        #expect(!requestedPause.desiredPlaying)
        route.completePendingSeek()
        #expect(try await secondSeek.value == .applied)
        #expect(
            Array(route.events.suffix(3)) == [
                .seekStarted(seconds: 0, capturedPlaying: true),
                .seekCompletedWithCapturedPlay,
                .pause,
            ]
        )
        #expect(session.transportSnapshot.commandSequence == 5)
        #expect(!session.transportSnapshot.desiredPlaying)
        #expect(!route.events.contains(.setRate(1)))
    }

    @MainActor
    @Test("Delayed predecessor seek cannot apply transport to a successor route generation")
    func staleSeekCannotCrossRouteGeneration() async throws {
        let predecessor = ControllableOuterTransportRoute()
        let successor = ControllableOuterTransportRoute()
        let session = AetherPlaybackSession(
            url: URL(fileURLWithPath: "/tmp/aether-generation-race"),
            options: LoadOptions(),
            variantSelection: .highestBandwidth
        )
        defer { session.stop() }
        session.installTransportRaceTestHarness(predecessor)

        try session.pause()
        let seek = Task { @MainActor in
            try await session.seek(to: .zero)
        }
        try await waitForPendingSeek(predecessor)
        try session.play()
        let predecessorGeneration = session.transportSnapshot
            .routeGeneration

        try session.replaceTransportRaceTestRoute(with: successor)
        let successorSnapshot = session.transportSnapshot
        #expect(
            successorSnapshot.routeGeneration
                == predecessorGeneration + 1
        )
        #expect(successorSnapshot.commandSequence == 3)
        #expect(successorSnapshot.desiredPlaying)
        #expect(successor.events == [.play])

        predecessor.completePendingSeek()
        var rejectedStaleCompletion = false
        do {
            _ = try await seek.value
        } catch is CancellationError {
            rejectedStaleCompletion = true
        }
        #expect(rejectedStaleCompletion)
        #expect(
            predecessor.events.suffix(1)
                == [.seekCompletedWithCapturedPause]
        )
        #expect(successor.events == [.play])
        #expect(
            session.transportSnapshot.routeGeneration
                == successorSnapshot.routeGeneration
        )
        #expect(
            session.transportSnapshot.commandSequence
                == successorSnapshot.commandSequence
        )
        #expect(session.transportSnapshot.desiredPlaying)
    }

    @Test("Positive rate always plays first and only non-1x adds rate")
    func canonicalTransportOperations() {
        #expect(
            AetherPlaybackTransportDecision.operations(
                desiredPlaying: false,
                desiredRate: 1
            ) == [.pause]
        )
        #expect(
            AetherPlaybackTransportDecision.operations(
                desiredPlaying: true,
                desiredRate: 1
            ) == [.play]
        )
        #expect(
            AetherPlaybackTransportDecision.operations(
                desiredPlaying: true,
                desiredRate: 1.5
            ) == [.play, .setRate(1.5)]
        )
    }

    @Test("Parked ready transport reasserts once for the current command")
    func boundedReassert() {
        let shouldReassert = AetherPlaybackTransportDecision
            .shouldReassert(
                requestedSequence: 7,
                currentSequence: 7,
                requestedGeneration: 3,
                currentGeneration: 3,
                desiredPlaying: true,
                desiredRate: 1,
                itemIsReady: true,
                actualRate: 0,
                timeControlStatus: .paused,
                reassertCount: 0
            )
        #expect(shouldReassert)

        for denied in [
            AetherPlaybackTransportDecision.shouldReassert(
                requestedSequence: 7,
                currentSequence: 8,
                requestedGeneration: 3,
                currentGeneration: 3,
                desiredPlaying: true,
                desiredRate: 1,
                itemIsReady: true,
                actualRate: 0,
                timeControlStatus: .paused,
                reassertCount: 0
            ),
            AetherPlaybackTransportDecision.shouldReassert(
                requestedSequence: 7,
                currentSequence: 7,
                requestedGeneration: 3,
                currentGeneration: 4,
                desiredPlaying: true,
                desiredRate: 1,
                itemIsReady: true,
                actualRate: 0,
                timeControlStatus: .paused,
                reassertCount: 0
            ),
            AetherPlaybackTransportDecision.shouldReassert(
                requestedSequence: 7,
                currentSequence: 7,
                requestedGeneration: 3,
                currentGeneration: 3,
                desiredPlaying: false,
                desiredRate: 1,
                itemIsReady: true,
                actualRate: 0,
                timeControlStatus: .paused,
                reassertCount: 0
            ),
            AetherPlaybackTransportDecision.shouldReassert(
                requestedSequence: 7,
                currentSequence: 7,
                requestedGeneration: 3,
                currentGeneration: 3,
                desiredPlaying: true,
                desiredRate: 1,
                itemIsReady: true,
                actualRate: 0,
                timeControlStatus: .paused,
                reassertCount: 1
            ),
            AetherPlaybackTransportDecision.shouldReassert(
                requestedSequence: 7,
                currentSequence: 7,
                requestedGeneration: 3,
                currentGeneration: 3,
                desiredPlaying: true,
                desiredRate: 1,
                itemIsReady: true,
                actualRate: 0,
                timeControlStatus: .unknown,
                reassertCount: 0
            ),
            AetherPlaybackTransportDecision.shouldReassert(
                requestedSequence: 7,
                currentSequence: 7,
                requestedGeneration: 3,
                currentGeneration: 3,
                desiredPlaying: true,
                desiredRate: 1,
                itemIsReady: true,
                actualRate: 0,
                timeControlStatus: .paused,
                routeApplicationIsTemporarilyUnavailable: true,
                reassertCount: 0
            ),
        ] {
            #expect(!denied)
        }
    }

    @Test("Startup decision distinguishes parked intent and no progress")
    func startupFailureClassification() {
        let parked = AetherPlaybackTransportDecision.startupFailure(
            requestedSequence: 4,
            currentSequence: 4,
            requestedGeneration: 2,
            currentGeneration: 2,
            desiredPlaying: true,
            madeProgress: false,
            itemIsReady: true,
            actualRate: 0,
            timeControlStatus: .paused
        )
        #expect(parked == .transportIntentNotApplied)

        let waiting = AetherPlaybackTransportDecision.startupFailure(
            requestedSequence: 4,
            currentSequence: 4,
            requestedGeneration: 2,
            currentGeneration: 2,
            desiredPlaying: true,
            madeProgress: false,
            itemIsReady: true,
            actualRate: 0,
            timeControlStatus: .waitingToPlay
        )
        #expect(waiting == .startupNoProgress)

        let progressing = AetherPlaybackTransportDecision.startupFailure(
            requestedSequence: 4,
            currentSequence: 4,
            requestedGeneration: 2,
            currentGeneration: 2,
            desiredPlaying: true,
            madeProgress: true,
            itemIsReady: true,
            actualRate: 1,
            timeControlStatus: .playing
        )
        #expect(progressing == nil)

        let superseded = AetherPlaybackTransportDecision.startupFailure(
            requestedSequence: 4,
            currentSequence: 5,
            requestedGeneration: 2,
            currentGeneration: 2,
            desiredPlaying: true,
            madeProgress: false,
            itemIsReady: true,
            actualRate: 0,
            timeControlStatus: .paused
        )
        #expect(superseded == nil)
    }

    @Test("Outer AVPlayer acknowledgement cannot revive stale play intent")
    func outerTransportAcknowledgement() {
        let playing = AetherPlaybackTransportDecision.reconciledState(
            requestedSequence: 8,
            currentSequence: 8,
            requestedGeneration: 3,
            currentGeneration: 3,
            desiredPlaying: true,
            timeControlStatus: .waitingToPlay
        )
        #expect(playing == .playing)

        for denied in [
            AetherPlaybackTransportDecision.reconciledState(
                requestedSequence: 7,
                currentSequence: 8,
                requestedGeneration: 3,
                currentGeneration: 3,
                desiredPlaying: true,
                timeControlStatus: .playing
            ),
            AetherPlaybackTransportDecision.reconciledState(
                requestedSequence: 8,
                currentSequence: 8,
                requestedGeneration: 2,
                currentGeneration: 3,
                desiredPlaying: true,
                timeControlStatus: .playing
            ),
            AetherPlaybackTransportDecision.reconciledState(
                requestedSequence: 8,
                currentSequence: 8,
                requestedGeneration: 3,
                currentGeneration: 3,
                desiredPlaying: false,
                timeControlStatus: .playing
            ),
            AetherPlaybackTransportDecision.reconciledState(
                requestedSequence: 8,
                currentSequence: 8,
                requestedGeneration: 3,
                currentGeneration: 3,
                desiredPlaying: true,
                timeControlStatus: .paused
            ),
        ] {
            #expect(denied == nil)
        }
    }

    @Test("Direct stall recovery is mid-play and current-epoch only")
    func directRuntimeStallAdmission() {
        let admitted = AetherNativeDirectStallDecision.shouldAct(
            requestedTransportGeneration: 5,
            currentTransportGeneration: 5,
            itemMatches: true,
            directPlayIntent: true,
            demonstratedProgressInEpoch: true,
            madeProgressSinceCheckpoint: false,
            isStopped: false
        )
        #expect(admitted)

        let denied = [
            AetherNativeDirectStallDecision.shouldAct(
                requestedTransportGeneration: 4,
                currentTransportGeneration: 5,
                itemMatches: true,
                directPlayIntent: true,
                demonstratedProgressInEpoch: true,
                madeProgressSinceCheckpoint: false,
                isStopped: false
            ),
            AetherNativeDirectStallDecision.shouldAct(
                requestedTransportGeneration: 5,
                currentTransportGeneration: 5,
                itemMatches: false,
                directPlayIntent: true,
                demonstratedProgressInEpoch: true,
                madeProgressSinceCheckpoint: false,
                isStopped: false
            ),
            AetherNativeDirectStallDecision.shouldAct(
                requestedTransportGeneration: 5,
                currentTransportGeneration: 5,
                itemMatches: true,
                directPlayIntent: false,
                demonstratedProgressInEpoch: true,
                madeProgressSinceCheckpoint: false,
                isStopped: false
            ),
            AetherNativeDirectStallDecision.shouldAct(
                requestedTransportGeneration: 5,
                currentTransportGeneration: 5,
                itemMatches: true,
                directPlayIntent: true,
                demonstratedProgressInEpoch: false,
                madeProgressSinceCheckpoint: false,
                isStopped: false
            ),
            AetherNativeDirectStallDecision.shouldAct(
                requestedTransportGeneration: 5,
                currentTransportGeneration: 5,
                itemMatches: true,
                directPlayIntent: true,
                demonstratedProgressInEpoch: true,
                madeProgressSinceCheckpoint: true,
                isStopped: false
            ),
            AetherNativeDirectStallDecision.shouldAct(
                requestedTransportGeneration: 5,
                currentTransportGeneration: 5,
                itemMatches: true,
                directPlayIntent: true,
                demonstratedProgressInEpoch: true,
                madeProgressSinceCheckpoint: false,
                isStopped: true
            ),
        ]
        #expect(denied.allSatisfy { !$0 })
    }

    @Test("Direct seek landing is a new progress baseline, not progress")
    func directSeekLandingResetsProgressEpoch() {
        var epoch = AetherNativeDirectProgressEpoch()
        epoch.begin(
            at: CMTime(seconds: 10, preferredTimescale: 600)
        )
        epoch.land(
            at: CMTime(seconds: 150, preferredTimescale: 600)
        )

        #expect(!epoch.wasDemonstrated)
        #expect(
            !AetherNativeDirectStallDecision.shouldAct(
                requestedTransportGeneration: 5,
                currentTransportGeneration: 5,
                itemMatches: true,
                directPlayIntent: true,
                demonstratedProgressInEpoch:
                    epoch.wasDemonstrated,
                madeProgressSinceCheckpoint: false,
                isStopped: false
            )
        )

        // A queued pre-seek AVPlayer tick belongs to the retired timeline.
        // Ignoring it keeps the landed target as the new epoch baseline.
        epoch.observe(
            CMTime(seconds: 10, preferredTimescale: 600),
            isEligiblePlayback: true
        )
        #expect(!epoch.wasDemonstrated)

        epoch.observe(
            CMTime(seconds: 150.05, preferredTimescale: 600),
            isEligiblePlayback: true
        )
        #expect(!epoch.wasDemonstrated)

        epoch.observe(
            CMTime(seconds: 150.2, preferredTimescale: 600),
            isEligiblePlayback: true
        )
        #expect(epoch.wasDemonstrated)
        #expect(
            AetherNativeDirectStallDecision.shouldAct(
                requestedTransportGeneration: 5,
                currentTransportGeneration: 5,
                itemMatches: true,
                directPlayIntent: true,
                demonstratedProgressInEpoch:
                    epoch.wasDemonstrated,
                madeProgressSinceCheckpoint: false,
                isStopped: false
            )
        )
    }

    @Test("Progress evidence is media-time movement, not transport flags")
    func startupProgressEvidence() {
        let baseline = CMTime(seconds: 10, preferredTimescale: 600)
        #expect(
            !AetherPlaybackSession.madeStartupProgress(
                from: baseline,
                to: CMTime(seconds: 10.1, preferredTimescale: 600)
            )
        )
        #expect(
            AetherPlaybackSession.madeStartupProgress(
                from: baseline,
                to: CMTime(seconds: 10.2, preferredTimescale: 600)
            )
        )
    }

    @Test("Production startup outcome owns observation recovery and publication")
    func startupOutcomeBudget() {
        let budget = AetherPlaybackRecoveryBudget.production
        #expect(budget.startupProgressObservationSeconds == 30)
        #expect(budget.maximumEpisodeDurationSeconds == 30)
        #expect(
            budget.startupTerminalPublicationHeadroomSeconds == 0.25
        )
        #expect(budget.maximumStartupOutcomeSeconds == 60.25)

        let focused = AetherPlaybackRecoveryBudget(
            maximumEpisodeDurationSeconds: 4,
            startupProgressObservationSeconds: 2,
            startupTerminalPublicationHeadroomSeconds: 0.5
        )
        #expect(focused.maximumStartupOutcomeSeconds == 6.5)
    }

    @Test("Recovery install clamps startup observation to the existing episode")
    func recoveryObservationDoesNotRestartBudget() {
        #expect(
            AetherPlaybackTransportDecision.startupObservationDelay(
                configuredSeconds: 30,
                recoveryRemainingSeconds: nil,
                publicationHeadroomSeconds: 0.25
            ) == 30
        )
        #expect(
            AetherPlaybackTransportDecision.startupObservationDelay(
                configuredSeconds: 30,
                recoveryRemainingSeconds: 12,
                publicationHeadroomSeconds: 0.25
            ) == 11.75
        )
        #expect(
            AetherPlaybackTransportDecision.startupObservationDelay(
                configuredSeconds: 30,
                recoveryRemainingSeconds: 0.1,
                publicationHeadroomSeconds: 0.25
            ) == 0
        )
        #expect(
            AetherPlaybackTransportDecision.startupObservationDelay(
                configuredSeconds: 2,
                recoveryRemainingSeconds: 20,
                publicationHeadroomSeconds: 0.25
            ) == 2
        )
    }

    @MainActor
    @Test("All execution paths keep no-progress recovery alive on the same route")
    func routeSpecificOuterWatchdogBoundary() async throws {
        for target in [
            AetherPlaybackStartupWatchdogTarget.directNative,
            .nativeAudioBridge,
            .hybrid,
        ] {
            let session = AetherPlaybackSession(
                url: URL(
                    fileURLWithPath:
                        "/tmp/aether-startup-watchdog-harness"
                ),
                options: LoadOptions(),
                variantSelection: .highestBandwidth,
                recoveryBudget: AetherPlaybackRecoveryBudget(
                    maximumSameRouteRebuilds: 0,
                    maximumSoftwareDecoderTransitions: 0,
                    maximumRouteTransitions: 0,
                    initialPreparationSettleSeconds: 0.1,
                    maximumEpisodeDurationSeconds: 0.05,
                    startupProgressObservationSeconds: 0.01,
                    startupTerminalPublicationHeadroomSeconds: 0,
                    livenessPolicy:
                        AetherPlaybackLivenessPolicy(
                            noProgressWindowsSeconds: [0.01],
                            // Keep the harness inside the scheduled same-source
                            // retry. Its intentionally missing local fixture is
                            // not transport evidence and must not be allowed to
                            // turn this watchdog-policy test into an identity
                            // failure.
                            retryBackoffSeconds: [60],
                            diagnosticCheckpointsSeconds: [0.01],
                            repeatingDiagnosticIntervalSeconds: 1
                        )
                )
            )
            session.installStartupWatchdogTestHarness(
                target: target
            )

            for _ in 0..<30 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }

            #expect(session.terminalFailure == nil)
            #expect(
                session.firstFailure?.caseCode
                    == "startupNoProgress"
            )
            #expect(
                session.recoveryHistory.contains {
                    $0.fromRoute == target.route
                        && $0.toRoute == target.route
                        && $0.outcome == .scheduled
                }
            )
            #expect(
                !session.recoveryHistory.contains {
                    $0.action == .terminate
                        || $0.outcome == .exhausted
                }
            )
            session.stop()
            try await Task.sleep(nanoseconds: 20_000_000)
            #expect(session.state == .stopped)
            #expect(session.livenessSnapshot.phase == .cancelled)
        }
    }

    @MainActor
    @Test("Recovery handoff preserves pending no-progress without terminal")
    func recoveryHandoffDoesNotLoseImmediateStartupFailure() async throws {
        let session = AetherPlaybackSession(
            url: URL(
                fileURLWithPath:
                    "/tmp/aether-recovery-handoff-harness"
            ),
            options: LoadOptions(),
            variantSelection: .highestBandwidth,
            recoveryBudget: AetherPlaybackRecoveryBudget(
                maximumSameRouteRebuilds: 0,
                maximumSoftwareDecoderTransitions: 0,
                maximumRouteTransitions: 0,
                initialPreparationSettleSeconds: 0.1,
                maximumEpisodeDurationSeconds: 0.03,
                startupProgressObservationSeconds: 0.02,
                startupTerminalPublicationHeadroomSeconds: 0.005,
                livenessPolicy:
                    AetherPlaybackLivenessPolicy(
                        noProgressWindowsSeconds: [0.01],
                        retryBackoffSeconds: [60],
                        diagnosticCheckpointsSeconds: [0.01],
                        repeatingDiagnosticIntervalSeconds: 1
                    )
            )
        )
        defer { session.stop() }
        session.installStartupWatchdogTestHarness(
            target: .hybrid,
            holdRecoveryOwner: true,
            deferMonitoringUntilRecoveryHandoff: true
        )
        try await Task.sleep(nanoseconds: 40_000_000)

        session.releaseStartupWatchdogTestRecoveryOwner()
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(session.terminalFailure == nil)
        #expect(
            session.firstFailure?.caseCode == "startupNoProgress"
        )
        #expect(
            !session.recoveryHistory.contains {
                $0.action == .terminate
                    || $0.outcome == .exhausted
            }
        )
    }

    @Test("Transport snapshot uses only closed diagnostic categories")
    func privacySafeSnapshotContract() {
        let snapshot = AetherPlaybackTransportSnapshot(
            commandSequence: 9,
            routeGeneration: 4,
            desiredPlaying: true,
            desiredRate: 1,
            route: .hybridCarrier,
            applicationPhase: .parkedPaused,
            actualRate: 0,
            timeControlStatus: .paused,
            waitingReason: .none,
            itemStatus: .readyToPlay,
            mediaTimeSeconds: 0,
            loadedTimeRangeCount: 2,
            recoverySequence: 3,
            reassertCount: 1,
            lastReassertedCommandSequence: 9
        )
        #expect(snapshot.commandSequence == 9)
        #expect(snapshot.route == .hybridCarrier)
        #expect(snapshot.applicationPhase.rawValue == "parkedPaused")
        #expect(snapshot.timeControlStatus.rawValue == "paused")
        #expect(snapshot.waitingReason.rawValue == "none")
        #expect(snapshot.itemStatus.rawValue == "readyToPlay")
        #expect(snapshot.lastReassertedCommandSequence == 9)
        #expect(
            AetherPlaybackSession.transportSnapshotMediaTime(
                CMTime(seconds: -0.5, preferredTimescale: 600)
            ) == nil
        )
        #expect(
            AetherPlaybackSession.transportSnapshotMediaTime(
                .indefinite
            ) == nil
        )
        #expect(
            AetherPlaybackSession.transportSnapshotMediaTime(
                CMTime(seconds: 1.5, preferredTimescale: 600)
            ) == 1.5
        )

        #expect(
            Set([
                AetherPlaybackWaitingReason.none.rawValue,
                AetherPlaybackWaitingReason
                    .evaluatingBufferingRate.rawValue,
                AetherPlaybackWaitingReason.noItemToPlay.rawValue,
                AetherPlaybackWaitingReason.minimizingStalls.rawValue,
                AetherPlaybackWaitingReason.other.rawValue,
            ]).count == 5
        )
    }

    @MainActor
    @Test("Session exposes an idle privacy-safe transport snapshot")
    func sessionTransportSnapshot() {
        let session = AetherPlaybackSession(
            url: URL(fileURLWithPath: "/tmp/aether-transport-snapshot"),
            options: LoadOptions(),
            variantSelection: .highestBandwidth
        )
        defer { session.stop() }

        let snapshot = session.transportSnapshot
        #expect(snapshot.commandSequence == 0)
        #expect(snapshot.routeGeneration == 0)
        #expect(!snapshot.desiredPlaying)
        #expect(snapshot.desiredRate == 1)
        #expect(snapshot.route == nil)
        #expect(snapshot.applicationPhase == .idle)
        #expect(snapshot.timeControlStatus == .paused)
        #expect(snapshot.waitingReason == .none)
        #expect(snapshot.itemStatus == .absent)
        #expect(snapshot.loadedTimeRangeCount == 0)
        #expect(snapshot.recoverySequence == 0)
        #expect(snapshot.reassertCount == 0)
        #expect(snapshot.lastReassertedCommandSequence == nil)
    }
}
