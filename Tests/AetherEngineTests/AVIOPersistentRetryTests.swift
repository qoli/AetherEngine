import Darwin
import Foundation
import Testing
@testable import AetherEngine

@Suite("AVIO persistent transport retry")
struct AVIOPersistentRetryTests {
    @Test(
        "Hundreds of transient failures remain admitted"
    )
    func transientFailuresAreUnbounded() throws {
        let controller =
            AVIOPersistentRetryController()
        let policy =
            AetherPlaybackLivenessPolicy.production

        for attempt in 1...500 {
            let decision = try #require(
                controller.recordTransientFailure(
                    observedProgressToken:
                        controller.progressToken
                )
            )
            #expect(decision.attempt == attempt)
            #expect(
                decision.delaySeconds
                    == policy.retryBackoffSeconds(
                        forAttempt: attempt
                    )
            )
        }
    }

    @Test(
        "Production backoff and Retry-After use exact caps"
    )
    func exactBackoffAndRetryAfter() throws {
        let controller =
            AVIOPersistentRetryController()
        var observed: [TimeInterval] = []

        for _ in 1...8 {
            let decision = try #require(
                controller.recordTransientFailure(
                    observedProgressToken:
                        controller.progressToken
                )
            )
            observed.append(decision.delaySeconds)
        }
        #expect(
            observed
                == [1, 2, 4, 8, 15, 30, 30, 30]
        )

        let hinted =
            AVIOPersistentRetryController()
        let first = try #require(
            hinted.recordTransientFailure(
                observedProgressToken:
                    hinted.progressToken,
                retryAfterSeconds: 25
            )
        )
        #expect(first.delaySeconds == 25)
        let second = try #require(
            hinted.recordTransientFailure(
                observedProgressToken:
                    hinted.progressToken,
                retryAfterSeconds: 300
            )
        )
        #expect(second.delaySeconds == 30)
    }

    @Test(
        "Retry diagnostics keep the first failure and emit only bounded checkpoints"
    )
    func retryDiagnosticsAreBoundedAndRestartAfterProgress()
        throws
    {
        let clock = ManualRetryLogClock()
        let controller = AVIOPersistentRetryController(
            retryLogClock: clock
        )

        func record(
            _ cause: String = "persistentStall"
        ) throws -> AVIOPersistentRetryDecision {
            try #require(
                controller.recordTransientFailure(
                    observedProgressToken:
                        controller.progressToken,
                    retryLogCause: cause
                )
            )
        }

        let first = try record()
        #expect(
            first.retryLogEmission
                == AetherBoundedRetryLogEmission(
                    cumulativeFailureCount: 1,
                    elapsedSeconds: 0,
                    checkpointSeconds: nil
                )
        )
        #expect(first.firstRetryLogCause == "persistentStall")

        clock.advance(to: 14)
        #expect(try record().retryLogEmission == nil)
        clock.advance(to: 15)
        let at15 = try record("persistentConnectionEnded")
        #expect(at15.retryLogEmission?.cumulativeFailureCount == 3)
        #expect(at15.retryLogEmission?.checkpointSeconds == 15)
        #expect(at15.firstRetryLogCause == "persistentStall")

        clock.advance(to: 45)
        #expect(try record().retryLogEmission?.checkpointSeconds == 45)
        clock.advance(to: 90)
        #expect(try record().retryLogEmission?.checkpointSeconds == 90)
        clock.advance(to: 300)
        #expect(try record().retryLogEmission?.checkpointSeconds == 300)
        clock.advance(to: 599)
        #expect(try record().retryLogEmission == nil)
        clock.advance(to: 600)
        #expect(try record().retryLogEmission?.checkpointSeconds == 600)

        controller.recordProgress()
        clock.advance(to: 601)
        let afterProgress = try record("unknownLengthReconnect")
        #expect(
            afterProgress.retryLogEmission
                == AetherBoundedRetryLogEmission(
                    cumulativeFailureCount: 1,
                    elapsedSeconds: 0,
                    checkpointSeconds: nil
                )
        )
        #expect(
            afterProgress.firstRetryLogCause
                == "unknownLengthReconnect"
        )
    }

    @Test(
        "Unique byte progress resets and wakes pending retry"
    )
    func progressResetsAndWakesRetry() throws {
        let started =
            DispatchSemaphore(value: 0)
        let finished =
            DispatchSemaphore(value: 0)
        let outcome = RetryOutcomeBox()
        let controller =
            AVIOPersistentRetryController(
                onWaitStarted: {
                    started.signal()
                }
            )
        let decision = try #require(
            controller.recordTransientFailure(
                observedProgressToken:
                    controller.progressToken,
                retryAfterSeconds: 30
            )
        )

        DispatchQueue.global().async {
            outcome.set(
                controller.waitUntilRetry(
                    decision
                )
            )
            finished.signal()
        }
        #expect(
            started.wait(
                timeout: .now() + 1
            ) == .success
        )

        controller.recordProgress()

        #expect(
            finished.wait(
                timeout: .now() + 1
            ) == .success
        )
        #expect(outcome.value == .progressed)
        let reset = try #require(
            controller.recordTransientFailure(
                observedProgressToken:
                    controller.progressToken
            )
        )
        #expect(reset.attempt == 1)
        #expect(reset.delaySeconds == 1)
    }

    @Test(
        "Cancellation wakes backoff and fences late retry"
    )
    func cancellationWakesAndFencesLateRetry()
        throws
    {
        let started =
            DispatchSemaphore(value: 0)
        let finished =
            DispatchSemaphore(value: 0)
        let outcome = RetryOutcomeBox()
        let controller =
            AVIOPersistentRetryController(
                onWaitStarted: {
                    started.signal()
                }
            )
        let decision = try #require(
            controller.recordTransientFailure(
                observedProgressToken:
                    controller.progressToken,
                retryAfterSeconds: 30
            )
        )

        DispatchQueue.global().async {
            outcome.set(
                controller.waitUntilRetry(
                    decision
                )
            )
            finished.signal()
        }
        #expect(
            started.wait(
                timeout: .now() + 1
            ) == .success
        )

        let cancelStarted = Date()
        controller.cancel()

        #expect(
            finished.wait(
                timeout: .now() + 1
            ) == .success
        )
        #expect(
            Date().timeIntervalSince(cancelStarted)
                < 1
        )
        #expect(outcome.value == .cancelled)
        #expect(
            controller.recordTransientFailure(
                observedProgressToken:
                    controller.progressToken
            ) == nil
        )
        #expect(
            controller.waitUntilRetry(decision)
                == .cancelled
        )
    }

    @Test(
        "Only direct canonical auth and absence statuses are terminal"
    )
    func canonicalHardStatusContract() {
        for status in [401, 403, 404, 410] {
            #expect(
                AVIOReader.terminalHTTPError(
                    statusCode: status,
                    responseWasResolvedUpstream:
                        false
                )
                    == .httpStatus(
                        statusCode: status
                    )
            )
            #expect(
                AVIOReader.terminalHTTPError(
                    statusCode: status,
                    responseWasResolvedUpstream:
                        true
                ) == nil
            )
        }
        for transientStatus in [0, 429, 500, 503] {
            #expect(
                AVIOReader.terminalHTTPError(
                    statusCode:
                        transientStatus,
                    responseWasResolvedUpstream:
                        false
                ) == nil
            )
        }
    }

    @Test(
        "Unknown-length stream stall retries and clean 2xx alone confirms EOF"
    )
    func unknownLengthStallRetriesBeforeEOF()
        throws
    {
        let server =
            try UnknownLengthRetryServer()
        defer { server.close() }
        let reader = AVIOReader(
            url: server.url,
            livenessPolicy:
                AetherPlaybackLivenessPolicy(
                    noProgressWindowsSeconds:
                        [0.05],
                    retryBackoffSeconds:
                        [0.01]
                )
        )
        defer {
            reader.close()
            reader.waitForIOQuiescence()
        }

        reader
            .startUnknownLengthStreamForTesting()
        let payload = reader
            .readUnknownLengthStreamForTesting(
                maximumLength: 5
            )

        #expect(payload.result == 5)
        #expect(
            payload.data
                == Data("hello".utf8)
        )
        #expect(server.requestCount >= 2)
        #expect(
            reader
                .unknownLengthStreamGenerationForTesting
                >= 2
        )
        #expect(
            reader
                .unknownLengthMaximumConcurrentReadersForTesting
                == 1
        )
        #expect(reader.terminalError == nil)

        let eof = reader
            .readUnknownLengthStreamForTesting(
                maximumLength: 1
            )
        #expect(eof.result == FFmpegErr.eof)
    }

    @Test(
        "Unknown-length cancellation discards late generation data"
    )
    func unknownLengthCancellationFencesLateData() {
        let reader = AVIOReader(
            url: URL(
                string:
                    "https://example.invalid/stream"
            )!
        )
        let staleGeneration = reader
            .unknownLengthStreamGenerationForTesting

        reader.markClosed()
        reader
            .appendUnknownLengthDataForTesting(
                Data("late".utf8),
                generation: staleGeneration
            )

        #expect(
            reader
                .unknownLengthBytesReceivedForTesting
                == 0
        )
        #expect(
            reader
                .fetchedByteProgressLedger
                .snapshot
                .totalAdvancedBytes == 0
        )
        reader.close()
        reader.waitForIOQuiescence()
    }

    @Test(
        "Unknown-length resume requires matching identity and exact range"
    )
    func unknownLengthResumeAdmission()
        throws
    {
        let validator =
            SourceByteStoreValidator
                .strongETag("\"stable\"")
        let ranged = try AVIOReader
            .streamingResumePlan(
                statusCode: 206,
                requestedOffset: 5,
                contentRange:
                    "bytes 5-9/*",
                admittedValidator:
                    validator,
                responseValidator:
                    validator,
                contentEncoding:
                    "identity"
            )
        #expect(
            ranged
                == AVIOStreamingResumePlan(
                    discardPrefixBytes: 0,
                    validator: validator
                )
        )

        let replay = try AVIOReader
            .streamingResumePlan(
                statusCode: 200,
                requestedOffset: 5,
                contentRange: nil,
                admittedValidator:
                    validator,
                responseValidator:
                    validator,
                contentEncoding: nil
            )
        #expect(
            replay.discardPrefixBytes == 5
        )

        #expect(
            throws:
                AVIOReaderError
                    .sourceByteStore(
                        .invalidGeneration
                    )
        ) {
            _ = try AVIOReader
                .streamingResumePlan(
                    statusCode: 206,
                    requestedOffset: 5,
                    contentRange:
                        "bytes 5-9/*",
                    admittedValidator: nil,
                    responseValidator: nil,
                    contentEncoding: nil
                )
        }
        #expect(
            throws:
                AVIOReaderError
                    .sourceByteStore(
                        .generationMismatch
                    )
        ) {
            _ = try AVIOReader
                .streamingResumePlan(
                    statusCode: 206,
                    requestedOffset: 5,
                    contentRange:
                        "bytes 5-9/*",
                    admittedValidator:
                        validator,
                    responseValidator:
                        .strongETag(
                            "\"changed\""
                        ),
                    contentEncoding: nil
                )
        }
        #expect(
            throws:
                AVIOReaderError
                    .sourceByteStore(
                        .invalidRange
                    )
        ) {
            _ = try AVIOReader
                .streamingResumePlan(
                    statusCode: 206,
                    requestedOffset: 5,
                    contentRange:
                        "bytes 4-9/*",
                    admittedValidator:
                        validator,
                    responseValidator:
                        validator,
                    contentEncoding: nil
                )
        }
    }

    @Test(
        "Validatorless reconnect fails before changed same-length bytes can mix"
    )
    func validatorlessReconnectNeverMixesChangedBody()
        throws
    {
        let server =
            try PersistentGenerationFixtureServer(
                firstPrefix: Data("AAAA".utf8),
                reconnectSuffix:
                    Data("bbbb".utf8),
                eTag: nil
            )
        defer { server.close() }
        let store = try SourceByteStore(
            blockSize: 4,
            capacityBytes: 8
        )
        defer { store.close() }
        let reader = AVIOReader(
            url: server.url,
            sourceByteStore: store,
            livenessPolicy:
                AetherPlaybackLivenessPolicy(
                    noProgressWindowsSeconds:
                        [0.05],
                    retryBackoffSeconds:
                        [0.01]
                )
        )
        defer {
            reader.close()
            reader.waitForIOQuiescence()
        }

        try reader.open()
        let read = reader
            .readPersistentStreamForTesting(
                maximumLength: 8
            )

        #expect(read.result == 4)
        #expect(read.data == Data("AAAA".utf8))
        #expect(
            reader.terminalError
                == .sourceByteStore(
                    .generationMismatch
                )
        )
        #expect(server.snapshot.requestCount == 2)
        #expect(
            reader.fetchedByteProgressLedger
                .snapshot
                .totalAdvancedBytes == 4
        )
        #expect(
            try store.read(
                at: 4,
                maximumLength: 4
            ) == nil
        )
        #expect(store.snapshot?.residentBytes == 4)
    }

    @Test(
        "Validator-bound persistent reconnect sends If-Range"
    )
    func persistentReconnectUsesIfRange()
        throws
    {
        let server =
            try PersistentGenerationFixtureServer(
                firstPrefix: Data("AAAA".utf8),
                reconnectSuffix:
                    Data("bbbb".utf8),
                eTag: "\"stable\""
            )
        defer { server.close() }
        let reader = AVIOReader(
            url: server.url,
            livenessPolicy:
                AetherPlaybackLivenessPolicy(
                    noProgressWindowsSeconds:
                        [0.05],
                    retryBackoffSeconds:
                        [0.01]
                )
        )
        defer {
            reader.close()
            reader.waitForIOQuiescence()
        }

        try reader.open()
        let read = reader
            .readPersistentStreamForTesting(
                maximumLength: 8
            )

        #expect(read.result == 8)
        #expect(
            read.data
                == Data("AAAAbbbb".utf8)
        )
        #expect(reader.terminalError == nil)
        #expect(server.snapshot.requestCount == 2)
        #expect(
            server.snapshot.secondRequestIfRange
                == "\"stable\""
        )
    }
}

private final class RetryOutcomeBox:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage:
        AVIOPersistentRetryWaitOutcome?

    var value:
        AVIOPersistentRetryWaitOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(
        _ value:
            AVIOPersistentRetryWaitOutcome
    ) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

private final class ManualRetryLogClock:
    AetherBoundedRetryLogClock,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: TimeInterval = 0

    func now() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func advance(to value: TimeInterval) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

private final class PersistentGenerationFixtureServer:
    @unchecked Sendable
{
    struct Snapshot: Sendable, Equatable {
        let requestCount: Int
        let secondRequestIfRange: String?
    }

    private let listener: Int32
    private let queue = DispatchQueue(
        label:
            "com.aetherengine.tests.persistent-generation"
    )
    private let lock = NSLock()
    private let firstPrefix: Data
    private let reconnectSuffix: Data
    private let eTag: String?
    private var requests = 0
    private var secondRequestIfRange:
        String?
    private var isClosed = false

    let url: URL

    init(
        firstPrefix: Data,
        reconnectSuffix: Data,
        eTag: String?
    ) throws {
        self.firstPrefix = firstPrefix
        self.reconnectSuffix =
            reconnectSuffix
        self.eTag = eTag

        let descriptor = socket(
            AF_INET,
            SOCK_STREAM,
            0
        )
        guard descriptor >= 0 else {
            throw POSIXError(.EIO)
        }
        var reuse: Int32 = 1
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(
                MemoryLayout<Int32>.size
            )
        )
        var address = sockaddr_in()
        address.sin_family =
            sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr =
            inet_addr("127.0.0.1")
        let bound = withUnsafePointer(
            to: &address
        ) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(
                        MemoryLayout<
                            sockaddr_in
                        >.size
                    )
                )
            }
        }
        guard bound == 0,
              Darwin.listen(
                descriptor,
                4
              ) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EIO)
        }
        var actual = sockaddr_in()
        var actualLength = socklen_t(
            MemoryLayout<sockaddr_in>.size
        )
        let named = withUnsafeMutablePointer(
            to: &actual
        ) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                getsockname(
                    descriptor,
                    $0,
                    &actualLength
                )
            }
        }
        guard named == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EIO)
        }
        listener = descriptor
        url = URL(
            string:
                "http://127.0.0.1:\(UInt16(bigEndian: actual.sin_port))/source"
        )!
        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    deinit {
        close()
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            requestCount: requests,
            secondRequestIfRange:
                secondRequestIfRange
        )
    }

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        lock.unlock()
        shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
    }

    private func acceptLoop() {
        while true {
            let client = accept(
                listener,
                nil,
                nil
            )
            guard client >= 0 else { return }
            var noSignal: Int32 = 1
            setsockopt(
                client,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSignal,
                socklen_t(
                    MemoryLayout<Int32>.size
                )
            )
            handle(client)
            Darwin.close(client)
        }
    }

    private func handle(_ client: Int32) {
        guard let headers =
                readHeaders(client) else {
            return
        }
        lock.lock()
        requests += 1
        let attempt = requests
        if attempt == 2 {
            secondRequestIfRange =
                headers["if-range"]
        }
        lock.unlock()

        let totalLength =
            firstPrefix.count
                + reconnectSuffix.count
        let body =
            attempt == 1
                ? firstPrefix
                : reconnectSuffix
        let lowerBound =
            attempt == 1
                ? 0
                : firstPrefix.count
        var responseHeaders = [
            "Content-Length: \(body.count)",
            "Content-Range: bytes \(lowerBound)-"
                + "\(lowerBound + body.count - 1)/"
                + "\(totalLength)",
            "Accept-Ranges: bytes",
            "Connection: close",
        ]
        if let eTag {
            responseHeaders.append(
                "ETag: \(eTag)"
            )
        }
        let head = Data(
            (
                "HTTP/1.1 206 Partial Content\r\n"
                    + responseHeaders.joined(
                        separator: "\r\n"
                    )
                    + "\r\n\r\n"
            ).utf8
        )
        sendAll(head, to: client)
        sendAll(body, to: client)
    }

    private func readHeaders(
        _ client: Int32
    ) -> [String: String]? {
        var data = Data()
        var bytes = [UInt8](
            repeating: 0,
            count: 1_024
        )
        let marker = Data("\r\n\r\n".utf8)
        while data.range(of: marker) == nil {
            let count = recv(
                client,
                &bytes,
                bytes.count,
                0
            )
            guard count > 0 else {
                return nil
            }
            data.append(
                contentsOf:
                    bytes[0..<count]
            )
            guard data.count
                    <= 16 * 1_024 else {
                return nil
            }
        }
        guard let request = String(
            data: data,
            encoding: .utf8
        ) else {
            return nil
        }
        return request
            .components(
                separatedBy: "\r\n"
            )
            .dropFirst()
            .reduce(
                into: [String: String]()
            ) { result, line in
                guard let separator =
                        line.firstIndex(
                            of: ":"
                        ) else {
                    return
                }
                let name = line[
                    ..<separator
                ].lowercased()
                let value = line[
                    line.index(
                        after: separator
                    )...
                ].trimmingCharacters(
                    in: .whitespaces
                )
                result[name] = value
            }
    }

    private func sendAll(
        _ data: Data,
        to client: Int32
    ) {
        data.withUnsafeBytes { raw in
            guard let base =
                    raw.baseAddress else {
                return
            }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(
                    client,
                    base.advanced(by: sent),
                    raw.count - sent,
                    0
                )
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    return
                }
                sent += count
            }
        }
    }
}

private final class UnknownLengthRetryServer:
    @unchecked Sendable
{
    private let listener: Int32
    private let queue = DispatchQueue(
        label:
            "com.aetherengine.tests.unknown-length-retry"
    )
    private let lock = NSLock()
    private var requests = 0
    private var isClosed = false

    let url: URL

    init() throws {
        let descriptor = socket(
            AF_INET,
            SOCK_STREAM,
            0
        )
        guard descriptor >= 0 else {
            throw POSIXError(.EIO)
        }
        var reuse: Int32 = 1
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(
                MemoryLayout<Int32>.size
            )
        )
        var address = sockaddr_in()
        address.sin_family =
            sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr =
            inet_addr("127.0.0.1")
        let bound = withUnsafePointer(
            to: &address
        ) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(
                        MemoryLayout<
                            sockaddr_in
                        >.size
                    )
                )
            }
        }
        guard bound == 0,
              Darwin.listen(
                descriptor,
                4
              ) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EIO)
        }
        var actual = sockaddr_in()
        var actualLength = socklen_t(
            MemoryLayout<sockaddr_in>.size
        )
        let named = withUnsafeMutablePointer(
            to: &actual
        ) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                getsockname(
                    descriptor,
                    $0,
                    &actualLength
                )
            }
        }
        guard named == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EIO)
        }
        listener = descriptor
        url = URL(
            string:
                "http://127.0.0.1:\(UInt16(bigEndian: actual.sin_port))/stream"
        )!
        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    deinit {
        close()
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        lock.unlock()
        shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
    }

    private func acceptLoop() {
        while true {
            let client = accept(
                listener,
                nil,
                nil
            )
            guard client >= 0 else { return }
            var noSignal: Int32 = 1
            setsockopt(
                client,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSignal,
                socklen_t(
                    MemoryLayout<Int32>.size
                )
            )
            handle(client)
            Darwin.close(client)
        }
    }

    private func handle(_ client: Int32) {
        guard readHeaders(client) else {
            return
        }
        lock.lock()
        requests += 1
        let attempt = requests
        lock.unlock()

        let headers = Data(
            (
                "HTTP/1.1 200 OK\r\n"
                + "Transfer-Encoding: chunked\r\n"
                + "ETag: \"stable\"\r\n"
                + "Connection: close\r\n\r\n"
            ).utf8
        )
        sendAll(headers, to: client)
        if attempt == 1 {
            Thread.sleep(
                forTimeInterval: 0.2
            )
            return
        }
        sendAll(
            Data(
                "5\r\nhello\r\n0\r\n\r\n"
                    .utf8
            ),
            to: client
        )
    }

    private func readHeaders(
        _ client: Int32
    ) -> Bool {
        var data = Data()
        var bytes = [UInt8](
            repeating: 0,
            count: 1_024
        )
        let marker = Data("\r\n\r\n".utf8)
        while data.range(of: marker) == nil {
            let count = recv(
                client,
                &bytes,
                bytes.count,
                0
            )
            guard count > 0 else {
                return false
            }
            data.append(
                contentsOf:
                    bytes[0..<count]
            )
            guard data.count
                    <= 16 * 1_024 else {
                return false
            }
        }
        return true
    }

    private func sendAll(
        _ data: Data,
        to client: Int32
    ) {
        data.withUnsafeBytes { raw in
            guard let base =
                    raw.baseAddress else {
                return
            }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(
                    client,
                    base.advanced(by: sent),
                    raw.count - sent,
                    0
                )
                guard count > 0 else {
                    return
                }
                sent += count
            }
        }
    }
}
