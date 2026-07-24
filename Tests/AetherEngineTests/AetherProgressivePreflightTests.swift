import Foundation
import Testing
@testable import AetherEngine

@Suite("Progressive network preflight", .serialized)
struct AetherProgressivePreflightTests {
    private enum AttemptBehavior: Sendable {
        case transientFailure(progress: Int64)
        case permanentFailure
        case success(progress: Int64)
        case ledgerSuccess(offset: Int64, count: Int)
        case progressingSuccess
        case milestoneProgressingSuccess
        case transientFailureAfterMilestones(Int)
        case progressThenStall(
            progress: Int64,
            seconds: TimeInterval
        )
        case lateSuccessAfterCancellation(
            delay: TimeInterval
        )
    }

    private final class AttemptController:
        @unchecked Sendable
    {
        private let lock = NSLock()
        private let behaviors: [AttemptBehavior]
        private let repeatsLastBehavior: Bool
        private var attempts:
            [Int: TestAttempt] = [:]
        private var produced:
            [Int: AetherPreparedURLSource] = [:]
        private var _requests:
            [AetherProgressivePreflightRequest] = []
        private var _storeIdentifiers:
            [ObjectIdentifier?] = []
        private var _ledgerIdentifiers:
            [ObjectIdentifier] = []
        private var _startedCount = 0
        private var _activeCount = 0
        private var _maximumActiveCount = 0
        private var _cancellationRequests:
            Set<Int> = []

        init(
            behaviors: [AttemptBehavior],
            repeatsLastBehavior: Bool = false
        ) {
            precondition(!behaviors.isEmpty)
            self.behaviors = behaviors
            self.repeatsLastBehavior =
                repeatsLastBehavior
        }

        func makeAttempt(
            request:
                AetherProgressivePreflightRequest,
            sourceByteStore: SourceByteStore?,
            ledger:
                AetherFetchedByteProgressLedger,
            liveness:
                AetherProgressivePreflightLiveness,
            onProgress:
                @escaping @Sendable (
                    AetherFetchedByteProgress
                ) -> Void,
            onProbeMilestone:
                @escaping @Sendable () -> Void
        ) -> any AetherProgressivePreflightAttempt {
            lock.lock()
            let number = attempts.count + 1
            let index = number - 1
            let behavior: AttemptBehavior
            if index < behaviors.count {
                behavior = behaviors[index]
            } else if repeatsLastBehavior {
                behavior = behaviors[
                    behaviors.count - 1
                ]
            } else {
                behavior = .permanentFailure
            }
            let attempt = TestAttempt(
                number: number,
                behavior: behavior,
                request: request,
                sourceByteStore: sourceByteStore,
                ledger: ledger,
                liveness: liveness,
                onProgress: onProgress,
                onProbeMilestone:
                    onProbeMilestone,
                controller: self
            )
            attempts[number] = attempt
            _requests.append(request)
            _storeIdentifiers.append(
                sourceByteStore.map(ObjectIdentifier.init)
            )
            _ledgerIdentifiers.append(
                ObjectIdentifier(ledger)
            )
            lock.unlock()
            return attempt
        }

        func recordStart() {
            lock.lock()
            _startedCount += 1
            _activeCount += 1
            _maximumActiveCount = max(
                _maximumActiveCount,
                _activeCount
            )
            lock.unlock()
        }

        func recordFinish() {
            lock.lock()
            _activeCount -= 1
            lock.unlock()
        }

        func recordCancellation(attempt: Int) {
            lock.lock()
            _cancellationRequests.insert(attempt)
            lock.unlock()
        }

        func recordProduced(
            _ source: AetherPreparedURLSource,
            attempt: Int
        ) {
            lock.lock()
            produced[attempt] = source
            lock.unlock()
        }

        var startedCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _startedCount
        }

        var maximumActiveCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _maximumActiveCount
        }

        var requests:
            [AetherProgressivePreflightRequest] {
            lock.lock()
            defer { lock.unlock() }
            return _requests
        }

        var storeIdentifiers:
            [ObjectIdentifier?] {
            lock.lock()
            defer { lock.unlock() }
            return _storeIdentifiers
        }

        var ledgerIdentifiers:
            [ObjectIdentifier] {
            lock.lock()
            defer { lock.unlock() }
            return _ledgerIdentifiers
        }

        func wasCancelled(_ attempt: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return _cancellationRequests
                .contains(attempt)
        }

        func producedSource(
            attempt: Int
        ) -> AetherPreparedURLSource? {
            lock.lock()
            defer { lock.unlock() }
            return produced[attempt]
        }

        func emit(
            attempt: Int,
            progress: Int64
        ) {
            lock.lock()
            let attempt = attempts[attempt]
            lock.unlock()
            attempt?.emit(progress: progress)
        }
    }

    private final class TestAttempt:
        AetherProgressivePreflightAttempt,
        @unchecked Sendable
    {
        private let number: Int
        private let behavior: AttemptBehavior
        private let request:
            AetherProgressivePreflightRequest
        private let sourceByteStore:
            SourceByteStore?
        private let ledger:
            AetherFetchedByteProgressLedger
        private let liveness:
            AetherProgressivePreflightLiveness
        private let onProgress:
            @Sendable (
                AetherFetchedByteProgress
            ) -> Void
        private let onProbeMilestone:
            @Sendable () -> Void
        private weak var controller:
            AttemptController?
        private let condition = NSCondition()
        private var cancellationRequested = false
        private var didRecordCancellation = false

        init(
            number: Int,
            behavior: AttemptBehavior,
            request:
                AetherProgressivePreflightRequest,
            sourceByteStore: SourceByteStore?,
            ledger:
                AetherFetchedByteProgressLedger,
            liveness:
                AetherProgressivePreflightLiveness,
            onProgress:
                @escaping @Sendable (
                    AetherFetchedByteProgress
                ) -> Void,
            onProbeMilestone:
                @escaping @Sendable () -> Void,
            controller: AttemptController
        ) {
            self.number = number
            self.behavior = behavior
            self.request = request
            self.sourceByteStore = sourceByteStore
            self.ledger = ledger
            self.liveness = liveness
            self.onProgress = onProgress
            self.onProbeMilestone =
                onProbeMilestone
            self.controller = controller
        }

        func run() throws -> AetherPreparedURLSource {
            controller?.recordStart()
            defer { controller?.recordFinish() }

            switch behavior {
            case .transientFailure(let progress):
                emit(progress: progress)
                throw URLError(.timedOut)

            case .permanentFailure:
                throw DemuxerError.openFailed(
                    code: FFmpegErr.invalidData
                )

            case .success(let progress):
                emit(progress: progress)
                return makePreparedSource()

            case .ledgerSuccess(let offset, let count):
                if let progress = ledger.record(
                    offset: offset,
                    count: count,
                    kind: .origin
                ) {
                    onProgress(progress)
                }
                return makePreparedSource()

            case .progressingSuccess:
                for tick in 1...24 {
                    guard !isCancellationRequested else {
                        throw CancellationError()
                    }
                    emit(
                        progress: Int64(tick * 4_096)
                    )
                    Thread.sleep(
                        forTimeInterval: 0.005
                    )
                }
                return makePreparedSource()

            case .milestoneProgressingSuccess:
                for _ in 1...6 {
                    guard !isCancellationRequested else {
                        throw CancellationError()
                    }
                    onProbeMilestone()
                    Thread.sleep(
                        forTimeInterval: 0.006
                    )
                }
                return makePreparedSource()

            case .transientFailureAfterMilestones(
                let count
            ):
                for _ in 0..<count {
                    onProbeMilestone()
                }
                throw URLError(.timedOut)

            case .progressThenStall(
                let progress,
                let seconds
            ):
                emit(progress: progress)
                let deadline = Date(
                    timeIntervalSinceNow: seconds
                )
                condition.lock()
                while !cancellationRequested,
                      Date() < deadline {
                    _ = condition.wait(until: deadline)
                }
                let wasCancelled =
                    cancellationRequested
                condition.unlock()
                guard !wasCancelled else {
                    throw CancellationError()
                }
                return makePreparedSource()

            case .lateSuccessAfterCancellation(
                let delay
            ):
                condition.lock()
                while !cancellationRequested {
                    condition.wait()
                }
                condition.unlock()
                Thread.sleep(forTimeInterval: delay)
                return makePreparedSource()
            }
        }

        func requestCancellation() {
            condition.lock()
            cancellationRequested = true
            let shouldRecord =
                !didRecordCancellation
            didRecordCancellation = true
            condition.broadcast()
            condition.unlock()
            if shouldRecord {
                controller?.recordCancellation(
                    attempt: number
                )
            }
        }

        func emit(progress: Int64) {
            guard progress > 0 else { return }
            onProgress(
                AetherFetchedByteProgress(
                    originBytesFetched: progress,
                    sourceStoreBytesReused: 0
                )
            )
        }

        private var isCancellationRequested: Bool {
            condition.lock()
            defer { condition.unlock() }
            return cancellationRequested
        }

        private func makePreparedSource()
            -> AetherPreparedURLSource
        {
            let source = AetherPreparedURLSource(
                url: request.url,
                options: request.options,
                probe: SourceProbe(
                    url: request.url,
                    durationSeconds: 60,
                    videoFormat: .sdr,
                    videoCodecID: 0,
                    videoCodecName: nil,
                    videoWidth: 1_920,
                    videoHeight: 1_080,
                    videoFrameRate: 24,
                    isDolbyVision: false,
                    audioTracks: [],
                    subtitleTracks: [],
                    isSourceSeekable: true,
                    videoStreamPresence:
                        .provenPresent
                ),
                demuxer: Demuxer(),
                progressiveLiveness: liveness,
                sourceByteStore: sourceByteStore,
                fetchedByteProgressLedger: ledger,
                onFetchedByteProgress: onProgress,
                onProbeMilestone:
                    onProbeMilestone
            )
            controller?.recordProduced(
                source,
                attempt: number
            )
            return source
        }
    }

    @Test("Production schedules clamp without a total attempt limit")
    func productionSchedulesClamp() {
        let policy =
            AetherProgressivePreflightRetryPolicy
                .production

        #expect(
            (1...7).map {
                policy.inactivityTimeout(
                    attempt: $0
                )
            } == [35, 60, 120, 300, 300, 300, 300]
        )
        #expect(
            (1...9).map {
                policy.backoff(afterAttempt: $0)
            } == [1, 2, 4, 8, 15, 30, 30, 30, 30]
        )
        #expect(
            policy.cancellationResponseSeconds == 2
        )
    }

    @Test("Unique-range ledger ignores reconnect and cache overlap")
    func uniqueRangeLedger() throws {
        let ledger =
            AetherFetchedByteProgressLedger()

        let first = try #require(
            ledger.record(
                offset: 0,
                count: 100,
                kind: .origin
            )
        )
        #expect(first.totalAdvancedBytes == 100)
        #expect(
            ledger.record(
                offset: 20,
                count: 40,
                kind: .origin
            ) == nil
        )

        let overlap = try #require(
            ledger.record(
                offset: 80,
                count: 40,
                kind: .sourceStore
            )
        )
        #expect(overlap.originBytesFetched == 100)
        #expect(overlap.sourceStoreBytesReused == 20)
        #expect(overlap.totalAdvancedBytes == 120)

        _ = ledger.record(
            offset: 200,
            count: 10,
            kind: .origin
        )
        let bridge = try #require(
            ledger.record(
                offset: 120,
                count: 80,
                kind: .sourceStore
            )
        )
        #expect(bridge.originBytesFetched == 110)
        #expect(
            bridge.sourceStoreBytesReused == 100
        )
        #expect(bridge.totalAdvancedBytes == 210)
        #expect(
            ledger.record(
                offset: 0,
                count: 210,
                kind: .origin
            ) == nil
        )
    }

    @Test(
        "fresh preflights sharing one ledger do not recount the same prefix"
    )
    func freshPreflightsDoNotDoubleCountPrefix()
        async throws
    {
        let ledger = AetherFetchedByteProgressLedger()
        let firstStore = try SourceByteStore()
        let secondStore = try SourceByteStore()
        let first = makePreflight(
            controller: AttemptController(
                behaviors: [
                    .ledgerSuccess(offset: 0, count: 4_096)
                ]
            ),
            sourceByteStore: firstStore,
            inactivity: 1,
            backoff: 0,
            fetchedByteProgressLedger: ledger
        )
        let second = makePreflight(
            controller: AttemptController(
                behaviors: [
                    .ledgerSuccess(offset: 0, count: 4_096)
                ]
            ),
            sourceByteStore: secondStore,
            inactivity: 1,
            backoff: 0,
            fetchedByteProgressLedger: ledger
        )

        let firstPrepared = try await first.prepare()
        let firstLiveness = try #require(
            firstPrepared.progressiveLiveness
        )
        #expect(
            firstLiveness.snapshot.totalAdvancedBytes
                == 4_096
        )
        let secondPrepared = try await second.prepare()
        let secondLiveness = try #require(
            secondPrepared.progressiveLiveness
        )
        #expect(
            secondLiveness.snapshot.totalAdvancedBytes == 0
        )
        #expect(
            ledger.snapshot.totalAdvancedBytes == 4_096
        )

        firstPrepared.discard()
        secondPrepared.discard()
        firstStore.close()
        secondStore.close()
    }

    @Test("I/O quiescence waits for every terminal callback")
    func ioQuiescenceWaitsForTerminalCallback()
        throws
    {
        let tracker = AetherIOQuiescenceTracker()
        let activity = try #require(
            tracker.beginActivity()
        )
        let completed = DispatchSemaphore(value: 0)

        tracker.beginShutdown()
        DispatchQueue.global().async {
            tracker.waitForShutdown()
            completed.signal()
        }

        #expect(
            completed.wait(
                timeout: .now() + 0.01
            ) == .timedOut
        )
        activity.complete()
        #expect(
            completed.wait(
                timeout: .now() + 1
            ) == .success
        )
        #expect(tracker.beginActivity() == nil)
    }

    @Test("Source store validation requires exact generation identity")
    func sourceStoreValidationIdentity() throws {
        let expected = try SourceByteStoreGeneration(
            contentLength: 1_000,
            validator: .strongETag("\"v1\"")
        )
        let url = URL(
            string: "https://example.invalid/media"
        )!

        func response(
            contentLength: Int64,
            etag: String?
        ) -> HTTPURLResponse {
            var headers = [
                "Content-Range":
                    "bytes 0-0/\(contentLength)"
            ]
            if let etag {
                headers["ETag"] = etag
            }
            return HTTPURLResponse(
                url: url,
                statusCode: 206,
                httpVersion: nil,
                headerFields: headers
            )!
        }

        #expect(
            AVIOReader.sourceStoreGenerationMatches(
                expected,
                response: response(
                    contentLength: 1_000,
                    etag: "\"v1\""
                ),
                requestedOffset: 0
            )
        )
        #expect(
            !AVIOReader.sourceStoreGenerationMatches(
                expected,
                response: response(
                    contentLength: 1_000,
                    etag: "\"v2\""
                ),
                requestedOffset: 0
            )
        )
        #expect(
            !AVIOReader.sourceStoreGenerationMatches(
                expected,
                response: response(
                    contentLength: 2_000,
                    etag: "\"v1\""
                ),
                requestedOffset: 0
            )
        )
        #expect(
            !AVIOReader.sourceStoreGenerationMatches(
                expected,
                response: response(
                    contentLength: 1_000,
                    etag: nil
                ),
                requestedOffset: 0
            )
        )
    }

    @Test("Cached CDN hard status retries canonical before typed terminal")
    func hardHTTPStatusRequiresCanonicalAttempt() {
        for statusCode in [401, 403, 404, 410] {
            #expect(
                AVIOReader.terminalHTTPError(
                    statusCode: statusCode,
                    responseWasResolvedUpstream: true
                ) == nil
            )
            #expect(
                AVIOReader.terminalHTTPError(
                    statusCode: statusCode,
                    responseWasResolvedUpstream: false
                ) == .httpStatus(
                    statusCode: statusCode
                )
            )
        }
        #expect(
            AVIOReader.terminalHTTPError(
                statusCode: 503,
                responseWasResolvedUpstream: false
            ) == nil
        )
    }

    @Test("Continuous unique-byte progress extends one attempt")
    func continuousProgressExtendsAttempt() async throws {
        let controller = AttemptController(
            behaviors: [.progressingSuccess]
        )
        let store = try SourceByteStore()
        let preflight = makePreflight(
            controller: controller,
            sourceByteStore: store,
            inactivity: 0.025,
            backoff: 0
        )

        let prepared = try await preflight.prepare()
        defer {
            prepared.discard()
            store.close()
        }

        #expect(controller.startedCount == 1)
        #expect(controller.maximumActiveCount == 1)
        let liveness = try #require(
            prepared.progressiveLiveness
        )
        #expect(liveness.snapshot.state == .prepared)
        #expect(
            liveness.snapshot.totalAdvancedBytes
                == 24 * 4_096
        )
    }

    @Test("Probe milestones extend inactivity without inventing bytes")
    func probeMilestonesExtendAttempt() async throws {
        let controller = AttemptController(
            behaviors: [
                .milestoneProgressingSuccess
            ]
        )
        let store = try SourceByteStore()
        let preflight = makePreflight(
            controller: controller,
            sourceByteStore: store,
            inactivity: 0.01,
            backoff: 0
        )
        let eventsTask = Task {
            var values:
                [AetherProgressivePreflightEvent] = []
            for await event in preflight.events {
                values.append(event)
                if case .prepared = event {
                    break
                }
            }
            return values
        }

        let prepared = try await preflight.prepare()
        defer {
            prepared.discard()
            store.close()
        }
        let liveness = try #require(
            prepared.progressiveLiveness
        )
        #expect(controller.startedCount == 1)
        #expect(
            liveness.snapshot.totalAdvancedBytes
                == 0
        )
        #expect(
            liveness.snapshot.lastProgressUptime
                != nil
        )
        let events = await eventsTask.value
        let milestoneSnapshots = events.compactMap {
            event -> (
                ordinal: UInt64,
                snapshot:
                    AetherProgressivePreflightLivenessSnapshot
            )? in
            guard case .probeMilestone(
                attempt: 1,
                ordinal: let ordinal,
                snapshot: let snapshot
            ) = event else {
                return nil
            }
            return (ordinal, snapshot)
        }
        #expect(
            milestoneSnapshots.allSatisfy {
                $0.snapshot.totalAdvancedBytes == 0
                    && $0.snapshot.lastProgressUptime
                        != nil
            }
        )
        let milestoneGenerations =
            milestoneSnapshots.map(\.ordinal)
        #expect(
            milestoneGenerations == [1, 2, 3, 4, 5, 6]
        )
    }

    @Test("Effective progress resets retry policy epoch")
    func effectiveProgressResetsPolicyEpoch()
        async throws
    {
        let controller = AttemptController(
            behaviors: [
                .transientFailure(progress: 0),
                .transientFailure(progress: 100),
                .success(progress: 200),
            ]
        )
        let store = try SourceByteStore()
        let preflight = makePreflight(
            controller: controller,
            sourceByteStore: store,
            inactivity: 1,
            backoff: 0.001,
            inactivitySchedule: [1, 2, 4],
            backoffSchedule: [0.001, 0.002, 0.004]
        )
        let eventsTask = Task {
            var values:
                [AetherProgressivePreflightEvent] = []
            for await event in preflight.events {
                values.append(event)
                if case .prepared = event {
                    break
                }
            }
            return values
        }

        let prepared = try await preflight.prepare()
        defer {
            prepared.discard()
            store.close()
        }
        let events = await eventsTask.value
        let inactivityWindows = events.compactMap {
            event -> TimeInterval? in
            guard case .attemptStarted(
                attempt: _,
                inactivitySeconds: let seconds
            ) = event else {
                return nil
            }
            return seconds
        }
        let backoffs = events.compactMap {
            event -> TimeInterval? in
            guard case .retryScheduled(
                afterAttempt: _,
                nextAttempt: _,
                backoffSeconds: let seconds,
                reason: _
            ) = event else {
                return nil
            }
            return seconds
        }

        #expect(inactivityWindows == [1, 2, 1])
        #expect(backoffs == [0.001, 0.001])
    }

    @Test("Effective progress resets the active attempt to the first inactivity window")
    func effectiveProgressResetsActiveInactivityWindow()
        async throws
    {
        let controller = AttemptController(
            behaviors: [
                .transientFailure(progress: 0),
                .progressThenStall(
                    progress: 100,
                    seconds: 0.05
                ),
                .success(progress: 200),
            ]
        )
        let store = try SourceByteStore()
        let preflight = makePreflight(
            controller: controller,
            sourceByteStore: store,
            inactivity: 0.01,
            backoff: 0,
            inactivitySchedule: [0.01, 0.2]
        )

        let prepared = try await preflight.prepare()
        defer {
            prepared.discard()
            store.close()
        }

        #expect(controller.startedCount == 3)
        #expect(controller.wasCancelled(2))
        #expect(controller.maximumActiveCount == 1)
    }

    @Test("Repeated probe stages across retries do not refresh progress")
    func repeatedProbeStagesDoNotRefreshProgress()
        async throws
    {
        let controller = AttemptController(
            behaviors: [
                .transientFailureAfterMilestones(2),
                .transientFailureAfterMilestones(2),
                .transientFailureAfterMilestones(2),
                .success(progress: 100),
            ]
        )
        let store = try SourceByteStore()
        let preflight = makePreflight(
            controller: controller,
            sourceByteStore: store,
            inactivity: 1,
            backoff: 0,
            inactivitySchedule: [1, 2, 4]
        )
        let eventsTask = Task {
            var values:
                [AetherProgressivePreflightEvent] = []
            for await event in preflight.events {
                values.append(event)
                if case .prepared = event {
                    break
                }
            }
            return values
        }

        let prepared = try await preflight.prepare()
        defer {
            prepared.discard()
            store.close()
        }
        let events = await eventsTask.value
        let inactivityWindows = events.compactMap {
            event -> TimeInterval? in
            guard case .attemptStarted(
                attempt: _,
                inactivitySeconds: let seconds
            ) = event else {
                return nil
            }
            return seconds
        }

        #expect(inactivityWindows == [1, 1, 2, 4])
        let milestoneGenerations = events.compactMap {
            event -> UInt64? in
            guard case .probeMilestone(
                attempt: _,
                ordinal: let ordinal,
                snapshot: _
            ) = event else {
                return nil
            }
            return ordinal
        }
        #expect(milestoneGenerations == [1, 2])
        #expect(controller.maximumActiveCount == 1)
    }

    @Test("Hundreds of zero-progress transport retries remain single-flight until success")
    func hundredsOfZeroProgressRetriesRemainAlive()
        async throws
    {
        let failures = (0..<200).map { _ in
            AttemptBehavior.transientFailure(progress: 0)
        }
        let controller = AttemptController(
            behaviors: failures + [.success(progress: 4_096)]
        )
        let store = try SourceByteStore()
        let preflight = makePreflight(
            controller: controller,
            sourceByteStore: store,
            inactivity: 0.01,
            backoff: 0,
            inactivitySchedule: [0.01],
            backoffSchedule: [0]
        )

        let prepared = try await preflight.prepare()
        defer {
            prepared.discard()
            store.close()
        }

        #expect(controller.startedCount == 201)
        #expect(controller.maximumActiveCount == 1)
        #expect(
            prepared.progressiveLiveness?
                .snapshot.totalAdvancedBytes == 4_096
        )
    }

    @Test("Transient failures retry after progress and transfer exact ownership")
    func retryAndOwnershipTransfer() async throws {
        let controller = AttemptController(
            behaviors: [
                .transientFailure(progress: 100),
                .transientFailure(progress: 200),
                .success(progress: 300),
            ]
        )
        let store = try SourceByteStore()
        let generation =
            try SourceByteStoreGeneration(
                contentLength: 8_192,
                validator:
                    .strongETag("\"generation-1\"")
            )
        try store.admit(generation)
        let request =
            AetherProgressivePreflightRequest(
                url: URL(
                    string:
                        "https://example.invalid/media.mkv"
                )!,
                options: LoadOptions(
                    httpHeaders: [
                        "Authorization": "redacted"
                    ]
                )
            )
        let preflight = makePreflight(
            controller: controller,
            request: request,
            sourceByteStore: store,
            inactivity: 1,
            backoff: 0.001
        )

        let prepared = try await preflight.prepare()
        let liveness = try #require(
            prepared.progressiveLiveness
        )
        #expect(controller.startedCount == 3)
        #expect(controller.maximumActiveCount == 1)
        #expect(
            controller.requests
                == [request, request, request]
        )
        #expect(
            Set(
                controller.storeIdentifiers
                    .compactMap { $0 }
            ).count == 1
        )
        #expect(
            Set(controller.ledgerIdentifiers).count
                == 1
        )
        #expect(prepared.sourceByteStore === store)
        #expect(
            prepared.sourceGeneration == generation
        )
        #expect(liveness.snapshot.state == .prepared)
        #expect(
            liveness.snapshot.totalAdvancedBytes
                == 300
        )

        controller.emit(attempt: 3, progress: 400)
        #expect(
            liveness.snapshot.totalAdvancedBytes
                == 400
        )

        let factory =
            try BlackCarrierDemuxSourceFactory
                .adopting(
                    preparedURLSource: prepared,
                    url: request.url,
                    options: request.options
                )
        #expect(
            factory.sourceByteStoreForTesting
                === store
        )
        #expect(
            factory.progressiveSourceGeneration
                == generation
        )
        #expect(!factory.progressiveSourceIsComplete)
        try store.store(
            Data(repeating: 0, count: 8_192),
            at: 0
        )
        #expect(factory.progressiveSourceIsComplete)
        let demuxer = try factory.openDemuxer()
        controller.emit(attempt: 3, progress: 500)
        #expect(
            liveness.snapshot.totalAdvancedBytes
                == 500
        )
        let freshDemuxer =
            factory
                .makeProgressConfiguredDemuxerForTesting()
        let preparedLedger = try #require(
            prepared.fetchedByteProgressLedger
        )
        #expect(
            freshDemuxer.fetchedByteProgressLedger
                === preparedLedger
        )
        let freshProgress = try #require(
            freshDemuxer.fetchedByteProgressLedger
                .record(
                    offset: 0,
                    count: 600,
                    kind: .origin
                )
        )
        freshDemuxer.onFetchedByteProgress?(
            freshProgress
        )
        #expect(
            liveness.snapshot.totalAdvancedBytes
                == 600
        )
        freshDemuxer.close()
        demuxer.close()
        factory.close()
    }

    @Test("Cancellation diagnostics never permit overlapping readers")
    func cancellationWaitsForRealQuiescence()
        async throws
    {
        let controller = AttemptController(
            behaviors: [
                .lateSuccessAfterCancellation(
                    delay: 0.04
                ),
                .success(progress: 100),
            ]
        )
        let store = try SourceByteStore()
        let preflight = makePreflight(
            controller: controller,
            sourceByteStore: store,
            inactivity: 0.01,
            backoff: 0,
            cancellationResponse: 0.01
        )
        let eventsTask = Task {
            var values:
                [AetherProgressivePreflightEvent] = []
            for await event in preflight.events {
                values.append(event)
                if case .prepared = event {
                    break
                }
            }
            return values
        }

        let prepared = try await preflight.prepare()
        defer {
            prepared.discard()
            store.close()
        }
        let events = await eventsTask.value

        #expect(controller.startedCount == 2)
        #expect(controller.maximumActiveCount == 1)
        #expect(controller.wasCancelled(1))
        #expect(
            eventIndex(
                in: events,
                matching: {
                    if case .cancellationUnresponsive(
                        attempt: 1,
                        waitedSeconds: _
                    ) = $0 {
                        return true
                    }
                    return false
                }
            ) != nil
        )
        let stopped = try #require(
            eventIndex(
                in: events,
                matching: {
                    if case .ioStopped(attempt: 1) =
                        $0 {
                        return true
                    }
                    return false
                }
            )
        )
        let successor = try #require(
            eventIndex(
                in: events,
                matching: {
                    if case .attemptStarted(
                        attempt: 2,
                        inactivitySeconds: _
                    ) = $0 {
                        return true
                    }
                    return false
                }
            )
        )
        #expect(stopped < successor)

        let late = try #require(
            controller.producedSource(attempt: 1)
        )
        #expect(
            throws:
                AetherPreparedURLSourceError
                    .alreadyConsumed
        ) {
            _ = try late.consume(
                url: late.url,
                options: LoadOptions()
            )
        }
    }

    @Test("Retry remains unbounded until owner cancellation")
    func unboundedRetryUntilCancellation()
        async throws
    {
        let controller = AttemptController(
            behaviors: [
                .transientFailure(progress: 0)
            ],
            repeatsLastBehavior: true
        )
        let store = try SourceByteStore()
        let preflight = makePreflight(
            controller: controller,
            sourceByteStore: store,
            inactivity: 1,
            backoff: 0.001
        )
        let task = Task {
            try await preflight.prepare()
        }

        let reached = await waitUntil(
            timeout: 2
        ) {
            controller.startedCount >= 9
        }
        #expect(reached)
        preflight.requestCancellation()

        do {
            let prepared = try await task.value
            prepared.discard()
            Issue.record(
                "Expected owner cancellation"
            )
        } catch is CancellationError {
            // Expected terminal: caller cancellation only.
        } catch {
            Issue.record(
                "Unexpected error: \(type(of: error))"
            )
        }
        #expect(controller.startedCount >= 9)
        #expect(controller.maximumActiveCount == 1)
    }

    @Test("Only explicit permanent evidence is terminal")
    func failureClassification() {
        #expect(
            AetherProgressivePreflightFailureClassifier
                .classify(
                    DemuxerError.openFailed(code: -5)
                ) == .retry
        )
        #expect(
            AetherProgressivePreflightFailureClassifier
                .classify(
                    DemuxerError.openFailed(
                        code: FFmpegErr.eof
                    )
                ) == .retry
        )
        #expect(
            AetherProgressivePreflightFailureClassifier
                .classify(
                    DemuxerError.openFailed(
                        code: FFmpegErr.invalidData
                    )
                ) == .retry
        )
        #expect(
            AetherProgressivePreflightFailureClassifier
                .classify(
                    DemuxerError.openFailed(
                        code: FFmpegErr.invalidData
                    ),
                    hasCompleteValidatedSourceEvidence:
                        true
                ) == .permanent
        )
        #expect(
            AetherProgressivePreflightFailureClassifier
                .classify(
                    URLError(.timedOut)
                ) == .retry
        )
        #expect(
            AetherProgressivePreflightFailureClassifier
                .classify(
                    SourceByteStoreError
                        .generationMismatch
                ) == .permanent
        )
        #expect(
            AetherProgressivePreflightFailureClassifier
                .classify(
                    AVIOReaderError
                        .sourceByteStoreValidationFailed(
                            reason: "transport timeout"
                        )
                ) == .retry
        )
        #expect(
            AetherProgressivePreflightFailureClassifier
                .classify(
                    AVIOReaderError.httpStatus(
                        statusCode: 403
                    )
                ) == .permanent
        )
    }

    private func makePreflight(
        controller: AttemptController,
        request:
            AetherProgressivePreflightRequest =
                AetherProgressivePreflightRequest(
                    url: URL(
                        string:
                            "https://example.invalid/media.mkv"
                    )!,
                    options: LoadOptions()
                ),
        sourceByteStore: SourceByteStore?,
        inactivity: TimeInterval,
        backoff: TimeInterval,
        cancellationResponse:
            TimeInterval = 0.05,
        inactivitySchedule:
            [TimeInterval]? = nil,
        backoffSchedule:
            [TimeInterval]? = nil,
        fetchedByteProgressLedger:
            AetherFetchedByteProgressLedger =
                AetherFetchedByteProgressLedger()
    ) -> AetherProgressivePreflight {
        AetherProgressivePreflight(
            request: request,
            retryPolicy:
                AetherProgressivePreflightRetryPolicy(
                    inactivitySeconds:
                        inactivitySchedule
                        ?? [inactivity],
                    backoffSeconds:
                        backoffSchedule
                        ?? [backoff],
                    cancellationResponseSeconds:
                        cancellationResponse
                ),
            sourceByteStore: sourceByteStore,
            dependencies:
                AetherProgressivePreflightDependencies(
                    makeAttempt: {
                        request,
                        store,
                        ledger,
                        liveness,
                        progress,
                        probeMilestone in
                        controller.makeAttempt(
                            request: request,
                            sourceByteStore: store,
                            ledger: ledger,
                            liveness: liveness,
                            onProgress: progress,
                            onProbeMilestone:
                                probeMilestone
                        )
                    },
                    sleep: { seconds in
                        try await Task.sleep(
                            nanoseconds: UInt64(
                                seconds
                                    * 1_000_000_000
                            )
                        )
                    }
                ),
            fetchedByteProgressLedger:
                fetchedByteProgressLedger
        )
    }

    private func eventIndex(
        in events:
            [AetherProgressivePreflightEvent],
        matching predicate:
            (AetherProgressivePreflightEvent)
                -> Bool
    ) -> Int? {
        events.firstIndex(where: predicate)
    }

    private func waitUntil(
        timeout: TimeInterval,
        predicate: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let deadline =
            ProcessInfo.processInfo.systemUptime
                + timeout
        while ProcessInfo.processInfo.systemUptime
                < deadline {
            if predicate() {
                return true
            }
            try? await Task.sleep(
                nanoseconds: 1_000_000
            )
        }
        return predicate()
    }
}
