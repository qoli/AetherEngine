import Foundation
import Testing
@testable import AetherEngine

private actor ManualPrefixFetchClock: AetherURLPlaybackPrefixFetchClock {
    private struct Waiter {
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
    }

    private var now: TimeInterval = 0
    private var waiters: [Waiter] = []

    func sleep(for seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        let deadline = now + seconds
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(
                Waiter(deadline: deadline, continuation: continuation)
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

    func pendingWaiterCount() -> Int {
        waiters.count
    }
}

private final class ControlledPrefixReader:
    AetherURLPlaybackPrefixReader,
    @unchecked Sendable
{
    private let concurrencyProbe: PrefixReaderConcurrencyProbe?
    private let lock = NSLock()
    private var onResponse:
        (@Sendable (AetherURLPlaybackPrefixResponse) -> Void)?
    private var onBytes: (@Sendable (Data) -> Void)?
    private var onCompletion: (@Sendable (Error?) -> Void)?
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private var isActive = false

    init(concurrencyProbe: PrefixReaderConcurrencyProbe? = nil) {
        self.concurrencyProbe = concurrencyProbe
    }

    var started: Bool { lock.withLock { startCount > 0 } }
    var cancellations: Int { lock.withLock { cancelCount } }

    func start(
        onResponse: @escaping @Sendable (AetherURLPlaybackPrefixResponse) -> Void,
        onBytes: @escaping @Sendable (Data) -> Void,
        onCompletion: @escaping @Sendable (Error?) -> Void
    ) {
        var began = false
        lock.withLock {
            startCount += 1
            if !isActive {
                isActive = true
                began = true
            }
            self.onResponse = onResponse
            self.onBytes = onBytes
            self.onCompletion = onCompletion
        }
        if began { concurrencyProbe?.begin() }
    }

    func cancel() {
        lock.withLock { cancelCount += 1 }
    }

    func respond(
        status: Int,
        encoding: String? = nil,
        contentRange: String? = nil
    ) {
        let callback = lock.withLock { onResponse }
        callback?(
            AetherURLPlaybackPrefixResponse(
                statusCode: status,
                contentEncoding: encoding,
                contentRange: contentRange
            )
        )
    }

    func send(_ bytes: Data) {
        let callback = lock.withLock { onBytes }
        callback?(bytes)
    }

    func complete(_ error: Error? = nil) {
        var ended = false
        let callback = lock.withLock { () -> (@Sendable (Error?) -> Void)? in
            if isActive {
                isActive = false
                ended = true
            }
            return onCompletion
        }
        if ended { concurrencyProbe?.end() }
        callback?(error)
    }
}

private final class PrefixReaderConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0

    var maximumActive: Int { lock.withLock { maximum } }

    func begin() {
        lock.withLock {
            active += 1
            maximum = max(maximum, active)
        }
    }

    func end() {
        lock.withLock { active -= 1 }
    }
}

private final class ControlledPrefixReaderFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let readers: [ControlledPrefixReader]
    private var next = 0
    private var requests: [URLRequest] = []

    init(_ readers: [ControlledPrefixReader]) {
        self.readers = readers
    }

    func make(_ request: URLRequest) -> any AetherURLPlaybackPrefixReader {
        lock.withLock {
            requests.append(request)
            let reader = readers[min(next, readers.count - 1)]
            next += 1
            return reader
        }
    }

    var requestTimeouts: [TimeInterval] {
        lock.withLock { requests.map(\.timeoutInterval) }
    }

    var requestRanges: [String?] {
        lock.withLock {
            requests.map {
                $0.value(forHTTPHeaderField: "Range")
            }
        }
    }
}

private final class VerifiedPrefixProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCounts: [Int] = []

    var counts: [Int] { lock.withLock { recordedCounts } }

    func record(_ byteCount: Int) {
        lock.withLock { recordedCounts.append(byteCount) }
    }
}

@Suite("Aether URL playback prefix liveness")
struct AetherURLPlaybackPrefixFetcherTests {
    private enum HarnessError: Error {
        case readerDidNotStart
        case readerWasNotCancelled
    }

    private func policy(
        noProgress: TimeInterval = 60,
        backoff: TimeInterval = 2
    ) -> AetherPlaybackLivenessPolicy {
        AetherPlaybackLivenessPolicy(
            noProgressWindowsSeconds: [noProgress],
            retryBackoffSeconds: [backoff],
            diagnosticCheckpointsSeconds: [1],
            repeatingDiagnosticIntervalSeconds: 1
        )
    }

    private func waitForStart(
        _ reader: ControlledPrefixReader
    ) async throws {
        for _ in 0..<1_000 {
            if reader.started { return }
            await Task.yield()
        }
        throw HarnessError.readerDidNotStart
    }

    private func waitForCancellation(
        _ reader: ControlledPrefixReader
    ) async throws {
        for _ in 0..<1_000 {
            if reader.cancellations > 0 { return }
            await Task.yield()
        }
        throw HarnessError.readerWasNotCancelled
    }

    private func waitForDeadline(
        _ clock: ManualPrefixFetchClock,
        deadline: TimeInterval
    ) async throws {
        for _ in 0..<1_000 {
            if await clock.nextDeadline() == deadline { return }
            await Task.yield()
        }
        throw HarnessError.readerDidNotStart
    }

    private func waitForWaiterCount(
        _ clock: ManualPrefixFetchClock,
        count: Int
    ) async throws {
        for _ in 0..<1_000 {
            if await clock.pendingWaiterCount() >= count { return }
            await Task.yield()
        }
        throw HarnessError.readerDidNotStart
    }

    @Test("transport guard overrides original and redirected request defaults")
    func transportGuardOverridesEveryRequest() {
        var original = URLRequest(
            url: URL(string: "https://example.invalid/original")!
        )
        original.timeoutInterval = 60
        var redirected = URLRequest(
            url: URL(string: "https://example.invalid/redirected")!
        )
        redirected.timeoutInterval = 12

        #expect(
            AetherURLPlaybackPrefixFetcher
                .applyingTransportGuard(to: original)
                .timeoutInterval
                == AetherURLPlaybackPrefixFetcher
                    .transportGuardTimeoutSeconds
        )
        #expect(
            AetherURLPlaybackPrefixFetcher
                .applyingTransportGuard(to: redirected)
                .timeoutInterval
                == AetherURLPlaybackPrefixFetcher
                    .transportGuardTimeoutSeconds
        )
    }

    @Test("slow progressive prefix crosses legacy 30, 45 and 90 second limits")
    func slowProgressiveCrossesLegacyResourceWindows() async throws {
        let clock = ManualPrefixFetchClock()
        let reader = ControlledPrefixReader()
        let factory = ControlledPrefixReaderFactory([reader])
        let progress = VerifiedPrefixProgressRecorder()
        let request = URLRequest(url: URL(string: "https://example.invalid/media")!)
        let task = Task {
            try await AetherURLPlaybackPrefixFetcher.fetch(
                request: request,
                maximumBytes: 512 * 1024,
                policy: policy(),
                clock: clock,
                makeReader: factory.make,
                onVerifiedPrefixProgress: { progress.record($0) }
            )
        }

        try await waitForStart(reader)
        reader.respond(status: 200)
        try await waitForDeadline(clock, deadline: 60)

        await clock.advance(by: 30)
        reader.send(Data([0x00, 0x00, 0x00, 0x18]))
        await Task.yield()
        await clock.advance(by: 15)
        reader.send(Data([0x66, 0x74]))
        await Task.yield()
        await clock.advance(by: 45)
        reader.send(Data([0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D]))
        reader.complete()

        let prefix = try await task.value
        #expect(
            try AetherURLPlaybackSourceClassifier.inspect(prefix: prefix)
                == .isoBaseMedia
        )
        #expect(reader.cancellations == 0)
        #expect(progress.counts == [4, 6, 12])
        #expect(
            factory.requestTimeouts
                == [AetherURLPlaybackPrefixFetcher
                    .transportGuardTimeoutSeconds]
        )
        #expect(factory.requestRanges == ["bytes=0-524287"])
    }

    @Test("retry replay is deduplicated before verified prefix grows")
    func retryReplayDoesNotManufactureProgress() async throws {
        let clock = ManualPrefixFetchClock()
        let first = ControlledPrefixReader()
        let second = ControlledPrefixReader()
        let factory = ControlledPrefixReaderFactory([first, second])
        let progress = VerifiedPrefixProgressRecorder()
        let request = URLRequest(
            url: URL(string: "https://example.invalid/media")!
        )
        let task = Task {
            try await AetherURLPlaybackPrefixFetcher.fetch(
                request: request,
                maximumBytes: 512 * 1024,
                policy: policy(noProgress: 5, backoff: 1),
                clock: clock,
                makeReader: factory.make,
                onVerifiedPrefixProgress: { progress.record($0) }
            )
        }

        try await waitForStart(first)
        first.respond(status: 200)
        try await waitForDeadline(clock, deadline: 5)
        first.send(Data("ABC".utf8))
        #expect(progress.counts == [3])
        // The byte callback installs a replacement watchdog asynchronously.
        // Wait for both the retired and replacement manual-clock sleepers so
        // advancing the clock cannot race ahead of the progress reset under
        // the full suite's parallel scheduler.
        try await waitForWaiterCount(clock, count: 2)
        await clock.advance(by: 5)
        try await waitForCancellation(first)
        first.complete(URLError(.cancelled))
        try await waitForDeadline(clock, deadline: 6)
        await clock.advance(by: 1)

        try await waitForStart(second)
        second.respond(status: 200)
        second.send(Data("ABC".utf8))
        #expect(progress.counts == [3])
        second.send(Data("D".utf8))
        #expect(progress.counts == [3, 4])
        second.complete()

        #expect(try await task.value == Data("ABCD".utf8))
        #expect(progress.counts == [3, 4])
    }

    @Test("same-source retry keeps maximum reader concurrency at one")
    func retriesUseOneReaderAtATime() async throws {
        let clock = ManualPrefixFetchClock()
        let probe = PrefixReaderConcurrencyProbe()
        let first = ControlledPrefixReader(concurrencyProbe: probe)
        let second = ControlledPrefixReader(concurrencyProbe: probe)
        let factory = ControlledPrefixReaderFactory([first, second])
        let request = URLRequest(url: URL(string: "https://example.invalid/media")!)
        let task = Task {
            try await AetherURLPlaybackPrefixFetcher.fetch(
                request: request,
                maximumBytes: 512 * 1024,
                policy: policy(noProgress: 5, backoff: 2),
                clock: clock,
                makeReader: factory.make
            )
        }

        try await waitForStart(first)
        first.respond(status: 200)
        try await waitForDeadline(clock, deadline: 5)
        await clock.advance(by: 5)
        try await waitForCancellation(first)
        #expect(!second.started)

        first.complete(URLError(.cancelled))
        try await waitForDeadline(clock, deadline: 7)
        await clock.advance(by: 2)
        try await waitForStart(second)
        second.respond(status: 200)
        second.send(Data("#EXTM3U\n".utf8))
        second.complete()

        #expect(try await task.value == Data("#EXTM3U\n".utf8))
        #expect(probe.maximumActive == 1)
        #expect(
            factory.requestTimeouts.allSatisfy {
                $0 == AetherURLPlaybackPrefixFetcher
                    .transportGuardTimeoutSeconds
            }
        )
        #expect(
            factory.requestRanges.allSatisfy {
                $0 == "bytes=0-524287"
            }
        )
    }

    @Test("one-byte HTML chunks remain undecided across retry windows")
    func tinyHTMLChunksEventuallyRejectHTML() async throws {
        let clock = ManualPrefixFetchClock()
        let readers = (0..<4).map { _ in ControlledPrefixReader() }
        let factory = ControlledPrefixReaderFactory(readers)
        let request = URLRequest(
            url: URL(string: "https://example.invalid/openlist")!
        )
        let task = Task {
            let prefix = try await AetherURLPlaybackPrefixFetcher.fetch(
                request: request,
                maximumBytes: 512 * 1024,
                policy: policy(noProgress: 5, backoff: 1),
                clock: clock,
                makeReader: factory.make
            )
            return try AetherURLPlaybackSourceClassifier.inspect(
                prefix: prefix
            )
        }
        let restartedPrefixes = [
            "<",
            "<!d",
            "<!doct",
            "<!doctype html><html>",
        ]
        var now: TimeInterval = 0

        for (index, reader) in readers.enumerated() {
            try await waitForStart(reader)
            reader.respond(status: 200)
            try await waitForDeadline(clock, deadline: now + 5)
            for byte in restartedPrefixes[index].utf8 {
                reader.send(Data([byte]))
            }
            let newlyVerifiedByteCount = restartedPrefixes[index]
                .utf8.count
                - (index == 0
                    ? 0
                    : restartedPrefixes[index - 1].utf8.count)
            try await waitForWaiterCount(
                clock,
                count: 1 + newlyVerifiedByteCount
            )
            await clock.advance(by: 5)
            now += 5
            try await waitForCancellation(reader)
            reader.complete(URLError(.cancelled))
            if index < readers.count - 1 {
                try await waitForDeadline(clock, deadline: now + 1)
                await clock.advance(by: 1)
                now += 1
            }
        }

        await #expect(
            throws: AetherURLPlaybackSourceClassificationError
                .nonMediaPayload(.html)
        ) {
            try await task.value
        }
    }

    @Test("same-length changed restart prefix fails identity without stitching")
    func changedRestartPrefixFailsIdentity() async throws {
        let clock = ManualPrefixFetchClock()
        let first = ControlledPrefixReader()
        let second = ControlledPrefixReader()
        let factory = ControlledPrefixReaderFactory([first, second])
        let progress = VerifiedPrefixProgressRecorder()
        let request = URLRequest(
            url: URL(string: "https://example.invalid/media")!
        )
        let task = Task {
            try await AetherURLPlaybackPrefixFetcher.fetch(
                request: request,
                maximumBytes: 512 * 1024,
                policy: policy(noProgress: 5, backoff: 1),
                clock: clock,
                makeReader: factory.make,
                onVerifiedPrefixProgress: { progress.record($0) }
            )
        }

        try await waitForStart(first)
        first.respond(status: 200)
        try await waitForDeadline(clock, deadline: 5)
        first.send(Data("A".utf8))
        try await waitForWaiterCount(clock, count: 2)
        await clock.advance(by: 5)
        try await waitForCancellation(first)
        first.complete(URLError(.cancelled))
        try await waitForDeadline(clock, deadline: 6)
        await clock.advance(by: 1)

        try await waitForStart(second)
        second.respond(status: 200)
        second.send(Data("B".utf8))
        second.complete()

        await #expect(
            throws: AetherURLPlaybackSourceClassificationError
                .sourceIdentityChanged
        ) {
            try await task.value
        }
        #expect(progress.counts == [1])
        #expect(
            AetherPlaybackSession.classify(.sourceIdentityChanged)
                == .invariantViolation
        )
        #expect(
            AetherPlaybackSession.failureCaseCode(
                .sourceIdentityChanged
            ) == "classification.sourceIdentityChanged"
        )
    }

    @Test("cancellation fences late reader bytes and completion")
    func cancellationDiscardsLateReaderResult() async throws {
        let clock = ManualPrefixFetchClock()
        let reader = ControlledPrefixReader()
        let factory = ControlledPrefixReaderFactory([reader])
        let progress = VerifiedPrefixProgressRecorder()
        let request = URLRequest(url: URL(string: "https://example.invalid/media")!)
        let task = Task {
            try await AetherURLPlaybackPrefixFetcher.fetch(
                request: request,
                maximumBytes: 512 * 1024,
                policy: policy(),
                clock: clock,
                makeReader: factory.make,
                onVerifiedPrefixProgress: { progress.record($0) }
            )
        }

        try await waitForStart(reader)
        reader.respond(status: 200)
        reader.send(Data("A".utf8))
        #expect(progress.counts == [1])
        task.cancel()
        try await waitForCancellation(reader)
        reader.send(Data("BC".utf8))
        reader.complete()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(progress.counts == [1])
    }

    @Test("canonical authorization and absence statuses remain permanent")
    func canonicalPermanentStatusesDoNotRetry() async throws {
        for status in [401, 403, 404, 410] {
            let clock = ManualPrefixFetchClock()
            let reader = ControlledPrefixReader()
            let factory = ControlledPrefixReaderFactory([reader])
            let request = URLRequest(url: URL(string: "https://example.invalid/media")!)
            let task = Task {
                try await AetherURLPlaybackPrefixFetcher.fetch(
                    request: request,
                    maximumBytes: 512 * 1024,
                    policy: policy(),
                    clock: clock,
                    makeReader: factory.make
                )
            }
            try await waitForStart(reader)
            reader.respond(status: status)
            await #expect(
                throws: AetherURLPlaybackSourceClassificationError.httpStatus(status)
            ) {
                try await task.value
            }
        }

        let reader = ControlledPrefixReader()
        let factory = ControlledPrefixReaderFactory([reader])
        let task = Task {
            try await AetherURLPlaybackPrefixFetcher.fetch(
                request: URLRequest(
                    url: URL(string: "https://example.invalid/media")!
                ),
                maximumBytes: 512 * 1024,
                policy: policy(),
                clock: ManualPrefixFetchClock(),
                makeReader: factory.make
            )
        }
        try await waitForStart(reader)
        reader.complete(
            AetherURLPlaybackSourceClassificationError
                .redirectCredentialScopeViolation
        )
        await #expect(
            throws: AetherURLPlaybackSourceClassificationError
                .redirectCredentialScopeViolation
        ) {
            try await task.value
        }
    }
}
