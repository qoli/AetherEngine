import Foundation
import Libavformat

/// Closed, privacy-safe dependency capabilities checked from source-byte facts
/// before a progressive demux is attempted.
public enum AetherPlaybackDependencyCapability:
    String,
    Sendable,
    Equatable
{
    case libavformatASFDemuxer = "libavformat.asfDemuxer"
}

/// Failure while determining the media family from the source bytes.
///
/// The error deliberately carries no URL, header or response-body text. Classification is a primary
/// decision boundary: callers must not catch one of these failures and try a different player or route.
public enum AetherURLPlaybackSourceClassificationError:
    Error,
    Sendable,
    Equatable,
    LocalizedError
{
    case unsupportedURLScheme
    case unreadableFile
    case emptyResource
    case nonHTTPResponse
    case httpStatus(Int)
    case unsupportedContentEncoding
    case redirectCredentialScopeViolation
    case sourceIdentityChanged
    case dependencyCapabilityUnavailable(
        AetherPlaybackDependencyCapability
    )
    case nonMediaPayload(AetherURLPlaybackNonMediaPayloadFamily)
    case transport(code: Int?)

    public var errorDescription: String? {
        switch self {
        case .unsupportedURLScheme:
            "Playback source classification supports only file, HTTP and HTTPS URLs"
        case .unreadableFile:
            "Playback source classification could not read the local file"
        case .emptyResource:
            "Playback source classification received an empty resource"
        case .nonHTTPResponse:
            "Playback source classification did not receive an HTTP response"
        case .httpStatus(let status):
            "Playback source classification received HTTP status \(status)"
        case .unsupportedContentEncoding:
            "Playback source classification requires identity content encoding"
        case .redirectCredentialScopeViolation:
            "Playback source classification rejected a cross-origin credential redirect"
        case .sourceIdentityChanged:
            "Playback source classification detected changed source bytes while retrying"
        case .dependencyCapabilityUnavailable(let capability):
            "Playback dependency capability is unavailable: \(capability.rawValue)"
        case .nonMediaPayload(let family):
            "Playback source classification rejected a non-media \(family.rawValue) payload"
        case .transport(let code):
            if let code {
                "Playback source classification transport failed with URL error \(code)"
            } else {
                "Playback source classification transport failed"
            }
        }
    }
}

/// High-confidence text response families which cannot be a playable media
/// source. Values are intentionally coarse and safe to retain as typed
/// evidence; response text, URLs and headers remain private.
public enum AetherURLPlaybackNonMediaPayloadFamily:
    String,
    Sendable,
    Equatable
{
    case html
    case json
}

/// Content-backed URL source classification used before Aether route preflight.
///
/// This classifier never uses a path extension, MIME type or declared codec. HLS and ISO-BMFF are
/// recognized only by signatures in the fetched bytes. High-confidence HTML
/// and complete JSON responses fail as typed non-media payloads; every other
/// non-empty payload is classified as a progressive resource. No error path
/// selects another source kind or playback backend.
enum AetherURLPlaybackSourceSignature: Sendable, Equatable {
    case hls
    case isoBaseMedia
    case progressive

    var sourceKind: AetherMediaSourceKind {
        switch self {
        case .hls:
            .hls
        case .isoBaseMedia, .progressive:
            .progressive
        }
    }

    var canonicalResolutionStep:
        AetherURLPlaybackSourceResolutionStep
    {
        switch self {
        case .hls:
            .inspectHLS
        case .isoBaseMedia, .progressive:
            // ISO-BMFF identifies a container, not a codec or playback
            // route. It must reach the same source probe as every other
            // progressive resource before Aether can admit Native or Hybrid.
            .probeProgressive
        }
    }
}

enum AetherURLPlaybackSourceResolutionStep:
    Sendable,
    Equatable
{
    case inspectHLS
    case probeProgressive
}

public enum AetherURLPlaybackSourceClassifier {
    public static let defaultMaximumPrefixBytes = 64 * 1024

    /// ASF Header Object GUID in its on-wire byte order. Unlike a `.wmv`
    /// suffix or MIME declaration, this is positive container evidence.
    private static let asfHeaderObjectSignature: [UInt8] = [
        0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11,
        0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C,
    ]

    static func isDependencyCapabilityAvailable(
        _ capability: AetherPlaybackDependencyCapability
    ) -> Bool {
        switch capability {
        case .libavformatASFDemuxer:
            av_find_input_format("asf") != nil
        }
    }

    public static func classify(
        url: URL,
        options: LoadOptions = .init(),
        maximumPrefixBytes: Int = defaultMaximumPrefixBytes
    ) async throws -> AetherMediaSourceKind {
        try await inspect(
            url: url,
            options: options,
            maximumPrefixBytes: maximumPrefixBytes
        ).sourceKind
    }

    static func inspect(
        url: URL,
        options: LoadOptions = .init(),
        maximumPrefixBytes: Int = defaultMaximumPrefixBytes,
        onVerifiedPrefixProgress:
            @escaping AetherURLPlaybackVerifiedPrefixProgress = { _ in }
    ) async throws -> AetherURLPlaybackSourceSignature {
        guard maximumPrefixBytes > 0 else {
            throw AetherURLPlaybackSourceClassificationError.emptyResource
        }

        let data: Data
        if url.isFileURL {
            do {
                data = try await Task.detached(priority: .userInitiated) {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    return try handle.read(upToCount: maximumPrefixBytes) ?? Data()
                }.value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AetherURLPlaybackSourceClassificationError.unreadableFile
            }
            try Task.checkCancellation()
            if !data.isEmpty {
                onVerifiedPrefixProgress(data.count)
            }
        } else {
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                throw AetherURLPlaybackSourceClassificationError.unsupportedURLScheme
            }
            var request = URLRequest(url: url)
            for (field, value) in options.httpHeaders {
                request.setValue(value, forHTTPHeaderField: field)
            }
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            data = try await AetherURLPlaybackPrefixFetcher.fetch(
                request: request,
                maximumBytes: maximumPrefixBytes,
                onVerifiedPrefixProgress: onVerifiedPrefixProgress
            )
        }
        return try inspect(prefix: data)
    }

    /// Pure signature classifier exposed for contract tests and catalog adapters.
    public static func classify(prefix: Data) throws -> AetherMediaSourceKind {
        try inspect(prefix: prefix).sourceKind
    }

    static func inspect(
        prefix: Data,
        dependencyCapabilityIsAvailable:
            (AetherPlaybackDependencyCapability) -> Bool =
                isDependencyCapabilityAvailable
    ) throws -> AetherURLPlaybackSourceSignature {
        guard !prefix.isEmpty else {
            throw AetherURLPlaybackSourceClassificationError.emptyResource
        }
        if prefix.starts(with: asfHeaderObjectSignature) {
            let capability = AetherPlaybackDependencyCapability
                .libavformatASFDemuxer
            guard dependencyCapabilityIsAvailable(capability) else {
                throw AetherURLPlaybackSourceClassificationError
                    .dependencyCapabilityUnavailable(capability)
            }
            return .progressive
        }
        if prefix.count >= 8,
           prefix.dropFirst(4).prefix(4).elementsEqual([
               0x66, 0x74, 0x79, 0x70,
           ]) {
            return .isoBaseMedia
        }
        var bytes = prefix
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes.removeFirst(3)
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            return AetherURLPlaybackSourceSignature.progressive
        }
        let firstNonWhitespace = text.drop(while: { $0.isWhitespace })
        if firstNonWhitespace.hasPrefix("#EXTM3U") {
            return AetherURLPlaybackSourceSignature.hls
        }

        let leadingText = firstNonWhitespace
            .prefix(512)
            .lowercased()
        if leadingText.hasPrefix("<!doctype html")
            || leadingText.hasPrefix("<html")
            || leadingText.hasPrefix("<head")
            || leadingText.hasPrefix("<body")
            || leadingText.hasPrefix("<script")
            || leadingText.hasPrefix("<meta")
            || (leadingText.hasPrefix("<?xml")
                && leadingText.contains("<html")) {
            throw AetherURLPlaybackSourceClassificationError
                .nonMediaPayload(.html)
        }

        // A prefix may be a truncated progressive resource, so JSON is only
        // rejected when the fetched bytes form one complete JSON value.
        if (firstNonWhitespace.hasPrefix("{")
                || firstNonWhitespace.hasPrefix("[")),
           (try? JSONSerialization.jsonObject(with: bytes)) != nil {
            throw AetherURLPlaybackSourceClassificationError
                .nonMediaPayload(.json)
        }
        return AetherURLPlaybackSourceSignature.progressive
    }

    /// Returns true only when an incomplete network prefix already contains
    /// enough bytes to make the normal classifier's result permanent. Unknown
    /// text such as `<!doc` deliberately remains undecided until more bytes or
    /// a clean response completion arrives.
    static func isDecisiveNetworkPrefix(_ prefix: Data) -> Bool {
        guard !prefix.isEmpty else { return false }
        if prefix.starts(with: asfHeaderObjectSignature) {
            return true
        }
        if prefix.count >= 8,
           prefix.dropFirst(4).prefix(4).elementsEqual([
               0x66, 0x74, 0x79, 0x70,
           ]) {
            return true
        }

        var bytes = prefix
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes.removeFirst(3)
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            return false
        }
        let firstNonWhitespace = text.drop(while: { $0.isWhitespace })
        if firstNonWhitespace.hasPrefix("#EXTM3U") {
            return true
        }
        let leadingText = firstNonWhitespace.prefix(512).lowercased()
        if leadingText.hasPrefix("<!doctype html")
            || leadingText.hasPrefix("<html")
            || leadingText.hasPrefix("<head")
            || leadingText.hasPrefix("<body")
            || leadingText.hasPrefix("<script")
            || leadingText.hasPrefix("<meta")
            || (leadingText.hasPrefix("<?xml")
                && leadingText.contains("<html")) {
            return true
        }
        if (firstNonWhitespace.hasPrefix("{")
                || firstNonWhitespace.hasPrefix("[")),
           (try? JSONSerialization.jsonObject(with: bytes)) != nil {
            return true
        }
        return false
    }
}

/// Privacy-safe evidence that the canonical byte-zero prefix grew.
///
/// The callback deliberately exposes only the monotonic verified byte count:
/// no URL, path, request header, credential, response body or byte content can
/// cross this boundary.
typealias AetherURLPlaybackVerifiedPrefixProgress =
    @Sendable (_ verifiedByteCount: Int) -> Void

/// Testable clock seam for the prefix reader's no-progress window and retry
/// backoff. This measures inactivity, never total fetch duration.
protocol AetherURLPlaybackPrefixFetchClock: Sendable {
    func sleep(for seconds: TimeInterval) async throws
}

private struct AetherSystemURLPlaybackPrefixFetchClock:
    AetherURLPlaybackPrefixFetchClock
{
    func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(
            nanoseconds: UInt64(seconds * 1_000_000_000)
        )
    }
}

struct AetherURLPlaybackPrefixResponse: Sendable {
    let statusCode: Int
    let contentEncoding: String?
    let contentRange: String?
}

/// A single physical reader for a prefix fetch generation. The coordinator
/// owns retries, so this protocol deliberately exposes neither URLs, headers
/// nor credentials to diagnostics or liveness state.
protocol AetherURLPlaybackPrefixReader: AnyObject, Sendable {
    func start(
        onResponse: @escaping @Sendable (AetherURLPlaybackPrefixResponse) -> Void,
        onBytes: @escaping @Sendable (Data) -> Void,
        onCompletion: @escaping @Sendable (Error?) -> Void
    )
    func cancel()
}

/// Same-canonical-source prefix coordinator. A byte which extends the prefix
/// resets only the inactivity window. No received bytes are discarded because
/// an origin took longer than a URLSession resource timeout.
final class AetherURLPlaybackPrefixFetcher: @unchecked Sendable {
    static let transportGuardTimeoutSeconds: TimeInterval =
        7 * 24 * 60 * 60

    typealias ReaderFactory = @Sendable (
        URLRequest
    ) -> any AetherURLPlaybackPrefixReader

    private let request: URLRequest
    private let maximumBytes: Int
    private let policy: AetherPlaybackLivenessPolicy
    private let clock: any AetherURLPlaybackPrefixFetchClock
    private let makeReader: ReaderFactory
    private let onVerifiedPrefixProgress:
        AetherURLPlaybackVerifiedPrefixProgress
    private let lock = NSLock()
    private var activeAttempt: Attempt?
    private var isCancelled = false
    private var lastReportedVerifiedPrefixCount = 0

    private init(
        request: URLRequest,
        maximumBytes: Int,
        policy: AetherPlaybackLivenessPolicy,
        clock: any AetherURLPlaybackPrefixFetchClock,
        makeReader: @escaping ReaderFactory,
        onVerifiedPrefixProgress:
            @escaping AetherURLPlaybackVerifiedPrefixProgress
    ) {
        var request = Self.applyingTransportGuard(to: request)
        request.setValue(
            "bytes=0-\(maximumBytes - 1)",
            forHTTPHeaderField: "Range"
        )
        self.request = request
        self.maximumBytes = maximumBytes
        self.policy = policy
        self.clock = clock
        self.makeReader = makeReader
        self.onVerifiedPrefixProgress = onVerifiedPrefixProgress
    }

    static func applyingTransportGuard(
        to request: URLRequest
    ) -> URLRequest {
        var request = request
        request.timeoutInterval = transportGuardTimeoutSeconds
        return request
    }

    static func fetch(
        request: URLRequest,
        maximumBytes: Int,
        onVerifiedPrefixProgress:
            @escaping AetherURLPlaybackVerifiedPrefixProgress = { _ in }
    ) async throws -> Data {
        try await fetch(
            request: request,
            maximumBytes: maximumBytes,
            policy: .production,
            clock: AetherSystemURLPlaybackPrefixFetchClock(),
            makeReader: { AetherURLSessionPrefixReader(request: $0) },
            onVerifiedPrefixProgress: onVerifiedPrefixProgress
        )
    }

    /// Internal so controlled readers can prove the progress, retry, and
    /// cancellation contract without live network time.
    static func fetch(
        request: URLRequest,
        maximumBytes: Int,
        policy: AetherPlaybackLivenessPolicy,
        clock: any AetherURLPlaybackPrefixFetchClock,
        makeReader: @escaping ReaderFactory,
        onVerifiedPrefixProgress:
            @escaping AetherURLPlaybackVerifiedPrefixProgress = { _ in }
    ) async throws -> Data {
        let fetcher = AetherURLPlaybackPrefixFetcher(
            request: request,
            maximumBytes: maximumBytes,
            policy: policy,
            clock: clock,
            makeReader: makeReader,
            onVerifiedPrefixProgress: onVerifiedPrefixProgress
        )
        return try await withTaskCancellationHandler {
            try await fetcher.run()
        } onCancel: {
            fetcher.cancel()
        }
    }

    private func run() async throws -> Data {
        var attemptNumber = 1
        var verifiedPrefix = Data()
        while true {
            try Task.checkCancellation()
            let attempt = Attempt(
                generation: UInt64(attemptNumber),
                maximumBytes: maximumBytes,
                expectedPrefix: verifiedPrefix,
                noProgressWindow: policy.noProgressWindowSeconds(
                    forAttempt: attemptNumber
                ),
                clock: clock,
                reader: makeReader(request),
                onVerifiedPrefixProgress: { [weak self] byteCount in
                    self?.reportVerifiedPrefixProgress(byteCount)
                }
            )
            let wasCancelled = lock.withLock { () -> Bool in
                guard !isCancelled else { return true }
                activeAttempt = attempt
                return false
            }
            if wasCancelled {
                throw CancellationError()
            }
            let result: Attempt.Result
            do {
                result = try await attempt.run()
            } catch {
                clearActiveAttempt(attempt)
                throw error
            }
            clearActiveAttempt(attempt)
            switch result {
            case .maximumPrefix(let candidate):
                verifiedPrefix = try mergeRestartedPrefix(
                    candidate,
                    into: verifiedPrefix,
                    requireCompleteReplay: false
                )
                reportVerifiedPrefixProgress(verifiedPrefix.count)
                return verifiedPrefix
            case .cleanCompletion(let candidate):
                verifiedPrefix = try mergeRestartedPrefix(
                    candidate,
                    into: verifiedPrefix,
                    requireCompleteReplay: true
                )
                reportVerifiedPrefixProgress(verifiedPrefix.count)
                guard !verifiedPrefix.isEmpty else {
                    throw AetherURLPlaybackSourceClassificationError
                        .emptyResource
                }
                return verifiedPrefix
            case .incomplete(let candidate):
                verifiedPrefix = try mergeRestartedPrefix(
                    candidate,
                    into: verifiedPrefix,
                    requireCompleteReplay: false
                )
                reportVerifiedPrefixProgress(verifiedPrefix.count)
                if AetherURLPlaybackSourceClassifier
                    .isDecisiveNetworkPrefix(verifiedPrefix) {
                    return verifiedPrefix
                }
                try await clock.sleep(
                    for: policy.retryBackoffSeconds(
                        forAttempt: attemptNumber
                    )
                )
                attemptNumber += 1
            }
        }
    }

    private func clearActiveAttempt(_ attempt: Attempt) {
        lock.withLock {
            if activeAttempt === attempt {
                activeAttempt = nil
            }
        }
    }

    private func reportVerifiedPrefixProgress(_ byteCount: Int) {
        let callback = lock.withLock {
            () -> AetherURLPlaybackVerifiedPrefixProgress? in
            guard !isCancelled,
                  byteCount > lastReportedVerifiedPrefixCount else {
                return nil
            }
            lastReportedVerifiedPrefixCount = byteCount
            return onVerifiedPrefixProgress
        }
        callback?(byteCount)
    }

    /// Every retry restarts at byte zero. Only an exact overlap can extend the
    /// retained prefix; a shorter clean replay or any changed overlap proves
    /// source identity drift. Candidate suffixes are never stitched onto a
    /// different generation.
    private func mergeRestartedPrefix(
        _ candidate: Data,
        into verified: Data,
        requireCompleteReplay: Bool
    ) throws -> Data {
        if requireCompleteReplay, candidate.count < verified.count {
            throw AetherURLPlaybackSourceClassificationError
                .sourceIdentityChanged
        }
        let overlapCount = min(candidate.count, verified.count)
        guard candidate.prefix(overlapCount).elementsEqual(
            verified.prefix(overlapCount)
        ) else {
            throw AetherURLPlaybackSourceClassificationError
                .sourceIdentityChanged
        }
        return candidate.count > verified.count ? candidate : verified
    }

    private func cancel() {
        let attempt = lock.withLock { () -> Attempt? in
            isCancelled = true
            return activeAttempt
        }
        attempt?.cancelByCaller()
    }

    private final class Attempt: @unchecked Sendable {
        enum Result {
            case maximumPrefix(Data)
            case cleanCompletion(Data)
            case incomplete(Data)
        }

        private enum State {
            case idle
            case reading
            case awaitingCompletion(Result)
            case finished
        }

        private let generation: UInt64
        private let maximumBytes: Int
        private let expectedPrefix: Data
        private let noProgressWindow: TimeInterval
        private let clock: any AetherURLPlaybackPrefixFetchClock
        private let reader: any AetherURLPlaybackPrefixReader
        private let onVerifiedPrefixProgress:
            AetherURLPlaybackVerifiedPrefixProgress
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result, Error>?
        private var state: State = .idle
        private var data = Data()
        private var receivedResponse = false
        private var watchdogGeneration: UInt64 = 0

        init(
            generation: UInt64,
            maximumBytes: Int,
            expectedPrefix: Data,
            noProgressWindow: TimeInterval,
            clock: any AetherURLPlaybackPrefixFetchClock,
            reader: any AetherURLPlaybackPrefixReader,
            onVerifiedPrefixProgress:
                @escaping AetherURLPlaybackVerifiedPrefixProgress
        ) {
            self.generation = generation
            self.maximumBytes = maximumBytes
            self.expectedPrefix = expectedPrefix
            self.noProgressWindow = noProgressWindow
            self.clock = clock
            self.reader = reader
            self.onVerifiedPrefixProgress = onVerifiedPrefixProgress
        }

        func run() async throws -> Result {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard case .idle = state else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                state = .reading
                lock.unlock()
                reader.start(
                    onResponse: { [weak self] response in
                        self?.receive(response, generation: self?.generation)
                    },
                    onBytes: { [weak self] bytes in
                        self?.receive(bytes, generation: self?.generation)
                    },
                    onCompletion: { [weak self] error in
                        self?.complete(error, generation: self?.generation)
                    }
                )
                resetWatchdog()
            }
        }

        func cancelByCaller() {
            let continuation = lock.withLock { () -> CheckedContinuation<Result, Error>? in
                guard case .finished = state else {
                    state = .finished
                    let continuation = self.continuation
                    self.continuation = nil
                    return continuation
                }
                return nil
            }
            reader.cancel()
            continuation?.resume(throwing: CancellationError())
        }

        private func receive(
            _ response: AetherURLPlaybackPrefixResponse,
            generation: UInt64?
        ) {
            guard generation == self.generation else { return }
            let terminal: Error?
            let retry: Bool
            lock.lock()
            guard case .reading = state else {
                lock.unlock()
                return
            }
            receivedResponse = true
            if (200..<300).contains(response.statusCode) {
                if response.statusCode == 206,
                   !Self.isZeroBasedContentRange(
                       response.contentRange
                   ) {
                    terminal = AetherURLPlaybackSourceClassificationError
                        .sourceIdentityChanged
                    retry = false
                } else if let encoding = response.contentEncoding,
                   !encoding.isEmpty,
                   encoding.lowercased() != "identity" {
                    terminal = AetherURLPlaybackSourceClassificationError
                        .unsupportedContentEncoding
                    retry = false
                } else {
                    terminal = nil
                    retry = false
                }
            } else if Self.isPermanentHTTPStatus(response.statusCode) {
                terminal = AetherURLPlaybackSourceClassificationError
                    .httpStatus(response.statusCode)
                retry = false
            } else {
                terminal = nil
                retry = true
            }
            if retry {
                state = .awaitingCompletion(.incomplete(data))
            }
            lock.unlock()
            if let terminal {
                finish(.failure(terminal))
                reader.cancel()
            } else if retry {
                reader.cancel()
            }
        }

        private func receive(_ bytes: Data, generation: UInt64?) {
            guard generation == self.generation, !bytes.isEmpty else { return }
            var prefix: Data?
            var progressed = false
            var identityChanged = false
            var verifiedPrefixCount: Int?
            lock.lock()
            guard case .reading = state else {
                lock.unlock()
                return
            }
            let remaining = maximumBytes - data.count
            if remaining > 0 {
                let previousCount = data.count
                let appended = bytes.prefix(remaining)
                data.append(appended)
                let overlapEnd = min(
                    data.count,
                    expectedPrefix.count
                )
                if overlapEnd > previousCount,
                   !data[previousCount..<overlapEnd].elementsEqual(
                       expectedPrefix[previousCount..<overlapEnd]
                   ) {
                    identityChanged = true
                }
                progressed = data.count > max(
                    previousCount,
                    expectedPrefix.count
                )
                if !identityChanged, progressed {
                    verifiedPrefixCount = data.count
                }
            }
            if data.count == maximumBytes {
                prefix = data
            }
            lock.unlock()
            if identityChanged {
                finish(.failure(
                    AetherURLPlaybackSourceClassificationError
                        .sourceIdentityChanged
                ))
                reader.cancel()
            } else {
                if let verifiedPrefixCount {
                    onVerifiedPrefixProgress(verifiedPrefixCount)
                }
                if let prefix {
                    finish(.success(.maximumPrefix(prefix)))
                    reader.cancel()
                } else if progressed {
                    resetWatchdog()
                }
            }
        }

        private func complete(_ error: Error?, generation: UInt64?) {
            guard generation == self.generation else { return }
            let outcome = lock.withLock { () -> Swift.Result<Result, Error>? in
                switch state {
                case .awaitingCompletion(let result):
                    return .success(result)
                case .reading:
                    if let permanent = Self.permanentClassificationError(
                        error
                    ) {
                        return .failure(permanent)
                    }
                    if error == nil {
                        guard receivedResponse else {
                            return .failure(
                                AetherURLPlaybackSourceClassificationError
                                    .nonHTTPResponse
                            )
                        }
                        return .success(.cleanCompletion(data))
                    }
                    return .success(.incomplete(data))
                case .idle, .finished:
                    return nil
                }
            }
            if let outcome {
                finish(outcome)
            }
        }

        private func resetWatchdog() {
            let watchdogToken = lock.withLock { () -> UInt64? in
                guard case .reading = state else { return nil }
                watchdogGeneration += 1
                return watchdogGeneration
            }
            guard let watchdogToken else { return }
            _ = makeWatchdog(token: watchdogToken)
        }

        private func makeWatchdog(token: UInt64) -> Task<Void, Never> {
            let clock = clock
            let window = noProgressWindow
            return Task { [weak self] in
                do {
                    try await clock.sleep(for: window)
                } catch {
                    return
                }
                self?.noProgressElapsed(token: token)
            }
        }

        private func noProgressElapsed(token: UInt64) {
            let result = lock.withLock { () -> Result? in
                guard case .reading = state,
                      token == watchdogGeneration else {
                    return nil
                }
                // An incomplete generation is never classification evidence
                // by itself. The coordinator verifies its byte-zero overlap
                // before retaining it for a same-source retry.
                let result: Result = .incomplete(data)
                state = .awaitingCompletion(result)
                return result
            }
            guard result != nil else { return }
            reader.cancel()
        }

        private static func permanentClassificationError(
            _ error: Error?
        ) -> Error? {
            guard let error = error as? AetherURLPlaybackSourceClassificationError
            else {
                return nil
            }
            switch error {
            case .transport:
                return nil
            default:
                return error
            }
        }

        private func finish(_ result: Swift.Result<Result, Error>) {
            let continuation = lock.withLock { () -> CheckedContinuation<Result, Error>? in
                guard case .finished = state else {
                    state = .finished
                    let continuation = self.continuation
                    self.continuation = nil
                    return continuation
                }
                return nil
            }
            continuation?.resume(with: result)
        }

        private static func isPermanentHTTPStatus(_ status: Int) -> Bool {
            switch status {
            case 401, 403, 404, 410:
                true
            default:
                false
            }
        }

        private static func isZeroBasedContentRange(
            _ value: String?
        ) -> Bool {
            guard let value else { return false }
            let normalized = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard normalized.hasPrefix("bytes ") else {
                return false
            }
            let range = normalized.dropFirst("bytes ".count)
            return range.hasPrefix("0-")
        }
    }
}

/// URLSession adapter for exactly one prefix reader generation. URLSession's
/// own request/resource timeouts are deliberately long: the coordinator above
/// owns the shorter, progress-resetting liveness window.
private final class AetherURLSessionPrefixReader:
    NSObject,
    URLSessionDataDelegate,
    URLSessionTaskDelegate,
    AetherURLPlaybackPrefixReader,
    @unchecked Sendable
{
    private let request: URLRequest
    private let lock = NSLock()
    private var onResponse: (@Sendable (AetherURLPlaybackPrefixResponse) -> Void)?
    private var onBytes: (@Sendable (Data) -> Void)?
    private var onCompletion: (@Sendable (Error?) -> Void)?
    private var session: URLSession?
    private var task: URLSessionDataTask?

    init(request: URLRequest) {
        self.request = AetherURLPlaybackPrefixFetcher
            .applyingTransportGuard(to: request)
    }

    func start(
        onResponse: @escaping @Sendable (AetherURLPlaybackPrefixResponse) -> Void,
        onBytes: @escaping @Sendable (Data) -> Void,
        onCompletion: @escaping @Sendable (Error?) -> Void
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        // These are guards against an abandoned URLSession task, not the
        // classification deadline. Byte progress is governed by the policy.
        configuration.timeoutIntervalForRequest =
            AetherURLPlaybackPrefixFetcher
                .transportGuardTimeoutSeconds
        configuration.timeoutIntervalForResource =
            AetherURLPlaybackPrefixFetcher
                .transportGuardTimeoutSeconds
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )
        let request = AetherURLPlaybackPrefixFetcher
            .applyingTransportGuard(to: request)
        let task = session.dataTask(with: request)
        lock.withLock {
            self.onResponse = onResponse
            self.onBytes = onBytes
            self.onCompletion = onCompletion
            self.session = session
            self.task = task
        }
        task.resume()
    }

    func cancel() {
        let session = lock.withLock { () -> URLSession? in
            task?.cancel()
            task = nil
            let session = self.session
            self.session = nil
            return session
        }
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let sourceURL = response.url ?? task.currentRequest?.url,
              let targetURL = request.url,
              let sourceOrigin = HLSVODOriginScope(url: sourceURL),
              let targetOrigin = HLSVODOriginScope(url: targetURL) else {
            completionHandler(nil)
            emitCompletion(
                AetherURLPlaybackSourceClassificationError
                    .redirectCredentialScopeViolation
            )
            return
        }
        let originalHeaders = self.request.allHTTPHeaderFields ?? [:]
        var redirected = request
        redirected.allHTTPHeaderFields = nil
        if sourceOrigin == targetOrigin {
            for (field, value) in originalHeaders {
                redirected.setValue(value, forHTTPHeaderField: field)
            }
        } else {
            guard !Self.hasCredentialScopedHeaders(originalHeaders) else {
                completionHandler(nil)
                emitCompletion(
                    AetherURLPlaybackSourceClassificationError
                        .redirectCredentialScopeViolation
                )
                return
            }
            for (field, value) in originalHeaders
            where Self.safeCrossOriginHeaders.contains(field.lowercased()) {
                redirected.setValue(value, forHTTPHeaderField: field)
            }
        }
        redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        redirected = AetherURLPlaybackPrefixFetcher
            .applyingTransportGuard(to: redirected)
        completionHandler(redirected)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            emitCompletion(
                AetherURLPlaybackSourceClassificationError.nonHTTPResponse
            )
            return
        }
        let callback = lock.withLock { onResponse }
        callback?(
            AetherURLPlaybackPrefixResponse(
                statusCode: response.statusCode,
                contentEncoding: response.value(
                    forHTTPHeaderField: "Content-Encoding"
                ),
                contentRange: response.value(
                    forHTTPHeaderField: "Content-Range"
                )
            )
        )
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let callback = lock.withLock { onBytes }
        callback?(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        emitCompletion(error)
    }

    private func emitCompletion(_ error: Error?) {
        let callback = lock.withLock { () -> (@Sendable (Error?) -> Void)? in
            let callback = onCompletion
            onCompletion = nil
            onResponse = nil
            onBytes = nil
            task = nil
            session = nil
            return callback
        }
        callback?(error)
    }

    private static let safeCrossOriginHeaders: Set<String> = [
        "accept",
        "accept-encoding",
        "accept-language",
        "range",
        "referer",
        "user-agent",
    ]

    private static func hasCredentialScopedHeaders(
        _ headers: [String: String]
    ) -> Bool {
        headers.keys.contains {
            !safeCrossOriginHeaders.contains($0.lowercased())
        }
    }
}
