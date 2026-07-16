import Foundation

enum HLSVODOriginResourceKey: Hashable, Sendable {
    case videoInit
    case videoSegment(index: Int)
    case audioInit(renditionOrdinal: Int)
    case audioSegment(renditionOrdinal: Int, index: Int)

    fileprivate var cacheFileName: String {
        switch self {
        case .videoInit:
            "video-init"
        case .videoSegment(let index):
            "video-segment-\(index)"
        case .audioInit(let ordinal):
            "audio-\(ordinal)-init"
        case .audioSegment(let ordinal, let index):
            "audio-\(ordinal)-segment-\(index)"
        }
    }
}

enum HLSVODOriginResourceError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case invalidLimits
    case resourceNotBound(HLSVODOriginResourceKey)
    case closed
    case nonHTTPResponse
    case httpStatus(Int)
    case unsupportedContentEncoding(String)
    case emptyResource(HLSVODOriginResourceKey)
    case resourceTooLarge(limit: Int, actual: Int?)
    case contentLengthMismatch(expected: Int64, actual: Int)
    case preflightEvidenceMismatch(HLSVODOriginResourceKey)
    case transport(URLError.Code)
    case transportFailure
    case cacheDirectoryCreationFailed
    case cacheReadFailed
    case cacheWriteFailed
    case cacheEvictionFailed
    case cacheCleanupFailed

    var errorDescription: String? {
        switch self {
        case .invalidLimits:
            "HLS VOD origin-resource limits are invalid"
        case .resourceNotBound:
            "Requested HLS VOD origin resource is not part of the admitted graph"
        case .closed:
            "HLS VOD origin-resource loader is closed"
        case .nonHTTPResponse:
            "HLS VOD origin-resource response was not HTTP"
        case .httpStatus(let status):
            "HLS VOD origin-resource HTTP status \(status)"
        case .unsupportedContentEncoding(let value):
            "HLS VOD origin resource requires identity content encoding, found \(value)"
        case .emptyResource:
            "HLS VOD origin resource was empty"
        case .resourceTooLarge(let limit, let actual):
            if let actual {
                "HLS VOD origin resource exceeded \(limit) bytes (actual \(actual))"
            } else {
                "HLS VOD origin resource exceeded \(limit) bytes"
            }
        case .contentLengthMismatch(let expected, let actual):
            "HLS VOD origin resource declared \(expected) bytes but delivered \(actual)"
        case .preflightEvidenceMismatch:
            "HLS VOD origin resource no longer matches preflight evidence"
        case .transport(let code):
            "HLS VOD origin-resource transport failed with URL error \(code.rawValue)"
        case .transportFailure:
            "HLS VOD origin-resource transport failed"
        case .cacheDirectoryCreationFailed:
            "HLS VOD origin-resource cache directory could not be created"
        case .cacheReadFailed:
            "HLS VOD origin-resource cache could not be read"
        case .cacheWriteFailed:
            "HLS VOD origin-resource cache could not be written"
        case .cacheEvictionFailed:
            "HLS VOD origin-resource cache entry could not be evicted"
        case .cacheCleanupFailed:
            "HLS VOD origin-resource session cache could not be removed"
        }
    }
}

struct HLSVODOriginFetchResponse: Sendable {
    let data: Data
    let effectiveURL: URL
    let statusCode: Int
    let contentLength: Int64?
    let contentEncoding: String?
}

struct HLSVODOriginResourcePayload: Sendable, Equatable {
    let key: HLSVODOriginResourceKey
    let effectiveURL: URL
    let data: Data
    let sha256: String
}

struct HLSVODOriginResourceLoaderSnapshot: Sendable, Equatable {
    let cachedResourceCount: Int
    let cachedBytes: Int64
    let inFlightResourceCount: Int
    let inFlightWaiterCount: Int
    let isClosed: Bool
}

private struct HLSVODBoundOriginResource: Sendable {
    let key: HLSVODOriginResourceKey
    let url: URL
    let seededData: Data?
    let expectedSHA256: String?
}

extension HLSVODResourceGraph {
    fileprivate func boundOriginResource(
        for key: HLSVODOriginResourceKey
    ) throws -> HLSVODBoundOriginResource {
        switch key {
        case .videoInit:
            guard let initSegmentURL,
                  let inspectedInitSegmentData else {
                throw HLSVODOriginResourceError.resourceNotBound(key)
            }
            return HLSVODBoundOriginResource(
                key: key,
                url: initSegmentURL,
                seededData: inspectedInitSegmentData,
                expectedSHA256:
                    HLSVODResourceDigest.sha256(
                        inspectedInitSegmentData
                    )
            )

        case .videoSegment(let index):
            guard segments.indices.contains(index) else {
                throw HLSVODOriginResourceError.resourceNotBound(key)
            }
            let seededData =
                index == 0 ? inspectedFirstMediaSegmentData : nil
            return HLSVODBoundOriginResource(
                key: key,
                url: segments[index].url,
                seededData: seededData,
                expectedSHA256:
                    seededData.map(HLSVODResourceDigest.sha256)
            )

        case .audioInit(let ordinal):
            guard audioRenditions.indices.contains(ordinal),
                  let initSegmentURL =
                    audioRenditions[ordinal].initSegmentURL else {
                throw HLSVODOriginResourceError.resourceNotBound(key)
            }
            return HLSVODBoundOriginResource(
                key: key,
                url: initSegmentURL,
                seededData: nil,
                expectedSHA256: nil
            )

        case .audioSegment(let ordinal, let index):
            guard audioRenditions.indices.contains(ordinal),
                  audioRenditions[ordinal].segments.indices
                    .contains(index) else {
                throw HLSVODOriginResourceError.resourceNotBound(key)
            }
            return HLSVODBoundOriginResource(
                key: key,
                url: audioRenditions[ordinal].segments[index].url,
                seededData: nil,
                expectedSHA256: nil
            )
        }
    }
}

/// Session-scoped loader for the immutable origin resources admitted by `HLSVODResourceGraph`.
///
/// The loader never accepts an arbitrary URL. Preflight-inspected video init/first-segment bytes seed the
/// cache directly, so playback cannot silently use bytes different from those that selected the route.
/// Remaining resources use exact-key single-flight. Cancelling one waiter does not cancel a fetch still
/// needed by another waiter; the origin task is cancelled when the final waiter leaves or the loader closes.
///
/// Cache paths contain only a UUID session directory and structural resource keys. URLs, signed query
/// parameters, Authorization and Cookie values remain in memory and are never written as metadata.
actor HLSVODOriginResourceLoader {
    typealias Fetch = @Sendable (
        _ request: URLRequest,
        _ maximumBytes: Int
    ) async throws -> HLSVODOriginFetchResponse

    static let defaultMaximumResourceBytes = 32 * 1024 * 1024
    static let defaultCapacityBytes: Int64 = 256 * 1024 * 1024

    private struct CacheEntry {
        let fileURL: URL
        let byteCount: Int
        let effectiveURL: URL
        let sha256: String
        var lastAccess: UInt64
    }

    private struct Flight {
        var waiters: [
            UUID:
                CheckedContinuation<
                    HLSVODOriginResourcePayload,
                    Error
                >
        ]
        var task: Task<Void, Never>?
    }

    private let graph: HLSVODResourceGraph
    private let httpHeaders: [String: String]
    private let maximumResourceBytes: Int
    private let capacityBytes: Int64
    private let fetch: Fetch
    let sessionDirectory: URL

    private var cache: [HLSVODOriginResourceKey: CacheEntry] = [:]
    private var flights: [HLSVODOriginResourceKey: Flight] = [:]
    private var cachedBytes: Int64 = 0
    private var accessCounter: UInt64 = 0
    private var isClosed = false
    private var closeError: HLSVODOriginResourceError?

    init(
        graph: HLSVODResourceGraph,
        httpHeaders: [String: String],
        maximumResourceBytes: Int =
            HLSVODOriginResourceLoader.defaultMaximumResourceBytes,
        capacityBytes: Int64 =
            HLSVODOriginResourceLoader.defaultCapacityBytes,
        baseDirectory: URL = FileManager.default.temporaryDirectory,
        fetchOverride: Fetch? = nil
    ) throws {
        guard maximumResourceBytes > 0,
              capacityBytes >= Int64(maximumResourceBytes) else {
            throw HLSVODOriginResourceError.invalidLimits
        }
        self.graph = graph
        self.httpHeaders = httpHeaders
        self.maximumResourceBytes = maximumResourceBytes
        self.capacityBytes = capacityBytes
        if let fetchOverride {
            fetch = fetchOverride
        } else {
            fetch = { request, maximumBytes in
                try await HLSVODBoundedHTTPFetcher.fetch(
                    request: request,
                    maximumBytes: maximumBytes
                )
            }
        }
        sessionDirectory = baseDirectory.appendingPathComponent(
            "AetherHLSOrigin-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: sessionDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw HLSVODOriginResourceError
                .cacheDirectoryCreationFailed
        }
    }

    deinit {
        for flight in flights.values {
            flight.task?.cancel()
        }
        if FileManager.default.fileExists(
            atPath: sessionDirectory.path
        ) {
            do {
                try FileManager.default.removeItem(
                    at: sessionDirectory
                )
            } catch {
                EngineLog.emit(
                    "[HLSVODOriginResourceLoader] cache cleanup failed during deinit",
                    category: .session
                )
            }
        }
    }

    nonisolated func payload(
        for key: HLSVODOriginResourceKey
    ) async throws -> HLSVODOriginResourcePayload {
        try Task.checkCancellation()
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await registerWaiter(
                waiterID,
                for: key
            )
        } onCancel: {
            Task {
                await self.cancelWaiter(
                    waiterID,
                    for: key
                )
            }
        }
    }

    var snapshot: HLSVODOriginResourceLoaderSnapshot {
        HLSVODOriginResourceLoaderSnapshot(
            cachedResourceCount: cache.count,
            cachedBytes: cachedBytes,
            inFlightResourceCount: flights.count,
            inFlightWaiterCount: flights.values.reduce(0) {
                $0 + $1.waiters.count
            },
            isClosed: isClosed
        )
    }

    func close() throws {
        if isClosed {
            if let closeError { throw closeError }
            return
        }
        isClosed = true
        let error = HLSVODOriginResourceError.closed
        for flight in flights.values {
            flight.task?.cancel()
            for continuation in flight.waiters.values {
                continuation.resume(throwing: error)
            }
        }
        flights.removeAll()
        cache.removeAll()
        cachedBytes = 0
        do {
            try FileManager.default.removeItem(
                at: sessionDirectory
            )
        } catch {
            let error =
                HLSVODOriginResourceError.cacheCleanupFailed
            closeError = error
            throw error
        }
    }

    private func registerWaiter(
        _ waiterID: UUID,
        for key: HLSVODOriginResourceKey
    ) async throws -> HLSVODOriginResourcePayload {
        guard !isClosed else {
            throw HLSVODOriginResourceError.closed
        }
        let resource = try graph.boundOriginResource(for: key)
        if let payload = try cachedPayload(for: key) {
            return payload
        }

        return try await withCheckedThrowingContinuation {
            continuation in
            if var flight = flights[key] {
                flight.waiters[waiterID] = continuation
                flights[key] = flight
                return
            }

            flights[key] = Flight(
                waiters: [waiterID: continuation],
                task: nil
            )
            let fetch = self.fetch
            let headers = httpHeaders
            let maximumBytes = maximumResourceBytes
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let response: HLSVODOriginFetchResponse
                    if let seededData = resource.seededData {
                        response = HLSVODOriginFetchResponse(
                            data: seededData,
                            effectiveURL: resource.url,
                            statusCode: 200,
                            contentLength: Int64(seededData.count),
                            contentEncoding: nil
                        )
                    } else {
                        var request = URLRequest(url: resource.url)
                        for (field, value) in headers {
                            request.setValue(
                                value,
                                forHTTPHeaderField: field
                            )
                        }
                        request.setValue(
                            "identity",
                            forHTTPHeaderField: "Accept-Encoding"
                        )
                        response = try await fetch(
                            request,
                            maximumBytes
                        )
                    }
                    await self.finish(
                        resource,
                        result: .success(response)
                    )
                } catch {
                    await self.finish(
                        resource,
                        result: .failure(error)
                    )
                }
            }
            if var flight = flights[key] {
                flight.task = task
                flights[key] = flight
            } else {
                task.cancel()
            }
        }
    }

    private func cancelWaiter(
        _ waiterID: UUID,
        for key: HLSVODOriginResourceKey
    ) {
        guard var flight = flights[key],
              let continuation =
                flight.waiters.removeValue(forKey: waiterID) else {
            return
        }
        continuation.resume(throwing: CancellationError())
        if flight.waiters.isEmpty {
            flight.task?.cancel()
            flights.removeValue(forKey: key)
        } else {
            flights[key] = flight
        }
    }

    private func finish(
        _ resource: HLSVODBoundOriginResource,
        result: Result<HLSVODOriginFetchResponse, Error>
    ) {
        guard let flight = flights.removeValue(
            forKey: resource.key
        ) else {
            return
        }
        do {
            let response = try result.get()
            let payload = try validateAndCache(
                response,
                for: resource
            )
            for continuation in flight.waiters.values {
                continuation.resume(returning: payload)
            }
        } catch is CancellationError {
            for continuation in flight.waiters.values {
                continuation.resume(
                    throwing: CancellationError()
                )
            }
        } catch let error as HLSVODOriginResourceError {
            for continuation in flight.waiters.values {
                continuation.resume(throwing: error)
            }
        } catch let error as URLError {
            let typed = HLSVODOriginResourceError.transport(
                error.code
            )
            for continuation in flight.waiters.values {
                continuation.resume(throwing: typed)
            }
        } catch {
            let typed =
                HLSVODOriginResourceError.transportFailure
            for continuation in flight.waiters.values {
                continuation.resume(throwing: typed)
            }
        }
    }

    private func validateAndCache(
        _ response: HLSVODOriginFetchResponse,
        for resource: HLSVODBoundOriginResource
    ) throws -> HLSVODOriginResourcePayload {
        guard (200..<300).contains(response.statusCode) else {
            throw HLSVODOriginResourceError.httpStatus(
                response.statusCode
            )
        }
        if let encoding = response.contentEncoding,
           !encoding.isEmpty,
           encoding.lowercased() != "identity" {
            throw HLSVODOriginResourceError
                .unsupportedContentEncoding(encoding)
        }
        guard !response.data.isEmpty else {
            throw HLSVODOriginResourceError.emptyResource(
                resource.key
            )
        }
        guard response.data.count <= maximumResourceBytes else {
            throw HLSVODOriginResourceError.resourceTooLarge(
                limit: maximumResourceBytes,
                actual: response.data.count
            )
        }
        if let contentLength = response.contentLength,
           contentLength != Int64(response.data.count) {
            throw HLSVODOriginResourceError.contentLengthMismatch(
                expected: contentLength,
                actual: response.data.count
            )
        }
        let sha256 = HLSVODResourceDigest.sha256(response.data)
        if let expectedSHA256 = resource.expectedSHA256,
           sha256 != expectedSHA256 {
            throw HLSVODOriginResourceError
                .preflightEvidenceMismatch(resource.key)
        }
        let payload = HLSVODOriginResourcePayload(
            key: resource.key,
            effectiveURL: response.effectiveURL,
            data: response.data,
            sha256: sha256
        )
        try cache(payload)
        return payload
    }

    private func cachedPayload(
        for key: HLSVODOriginResourceKey
    ) throws -> HLSVODOriginResourcePayload? {
        guard var entry = cache[key] else { return nil }
        let data: Data
        do {
            data = try Data(
                contentsOf: entry.fileURL,
                options: [.mappedIfSafe]
            )
        } catch {
            throw HLSVODOriginResourceError.cacheReadFailed
        }
        guard data.count == entry.byteCount,
              HLSVODResourceDigest.sha256(data) == entry.sha256 else {
            throw HLSVODOriginResourceError.cacheReadFailed
        }
        accessCounter &+= 1
        entry.lastAccess = accessCounter
        cache[key] = entry
        return HLSVODOriginResourcePayload(
            key: key,
            effectiveURL: entry.effectiveURL,
            data: data,
            sha256: entry.sha256
        )
    }

    private func cache(
        _ payload: HLSVODOriginResourcePayload
    ) throws {
        let byteCount = payload.data.count
        try evictToFit(Int64(byteCount))
        let fileURL = sessionDirectory.appendingPathComponent(
            payload.key.cacheFileName,
            isDirectory: false
        )
        do {
            try payload.data.write(
                to: fileURL,
                options: [.atomic]
            )
        } catch {
            throw HLSVODOriginResourceError.cacheWriteFailed
        }
        if let old = cache[payload.key] {
            cachedBytes -= Int64(old.byteCount)
        }
        accessCounter &+= 1
        cache[payload.key] = CacheEntry(
            fileURL: fileURL,
            byteCount: byteCount,
            effectiveURL: payload.effectiveURL,
            sha256: payload.sha256,
            lastAccess: accessCounter
        )
        cachedBytes += Int64(byteCount)
    }

    private func evictToFit(
        _ incomingBytes: Int64
    ) throws {
        while cachedBytes + incomingBytes > capacityBytes,
              let victim = cache.min(by: {
                  $0.value.lastAccess < $1.value.lastAccess
              }) {
            do {
                try FileManager.default.removeItem(
                    at: victim.value.fileURL
                )
            } catch {
                throw HLSVODOriginResourceError
                    .cacheEvictionFailed
            }
            cache.removeValue(forKey: victim.key)
            cachedBytes -= Int64(victim.value.byteCount)
        }
    }
}

/// One-shot bounded HTTP fetch used by the HLS VOD origin loader. Redirects retain the exact admitted
/// request headers, including Authorization/Referer, while the response body is cancelled as soon as it
/// crosses the configured cap. No retry or alternate URL is attempted.
final class HLSVODBoundedHTTPFetcher:
    NSObject,
    URLSessionDataDelegate,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let request: URLRequest
    private let maximumBytes: Int
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var continuation:
        CheckedContinuation<
            HLSVODOriginFetchResponse,
            Error
        >?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var isFinished = false

    private init(
        request: URLRequest,
        maximumBytes: Int,
        configuration: URLSessionConfiguration
    ) {
        self.request = request
        self.maximumBytes = maximumBytes
        self.configuration = configuration
    }

    static func fetch(
        request: URLRequest,
        maximumBytes: Int,
        configuration: URLSessionConfiguration = .ephemeral
    ) async throws -> HLSVODOriginFetchResponse {
        let fetcher = HLSVODBoundedHTTPFetcher(
            request: request,
            maximumBytes: maximumBytes,
            configuration: configuration
        )
        return try await withTaskCancellationHandler {
            try await fetcher.start()
        } onCancel: {
            fetcher.cancel()
        }
    }

    private func start() async throws
        -> HLSVODOriginFetchResponse
    {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation {
            continuation in
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                continuation.resume(
                    throwing: CancellationError()
                )
                return
            }
            self.continuation = continuation
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 30
            let session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: nil
            )
            let task = session.dataTask(with: request)
            self.session = session
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    private func cancel() {
        finish(.failure(CancellationError()))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var redirected = request
        for (field, value) in self.request
            .allHTTPHeaderFields ?? [:] {
            redirected.setValue(
                value,
                forHTTPHeaderField: field
            )
        }
        completionHandler(redirected)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler:
            @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(
                .failure(
                    HLSVODOriginResourceError.nonHTTPResponse
                )
            )
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            completionHandler(.cancel)
            finish(
                .failure(
                    HLSVODOriginResourceError.httpStatus(
                        http.statusCode
                    )
                )
            )
            return
        }
        if let encoding = http.value(
            forHTTPHeaderField: "Content-Encoding"
        ),
           !encoding.isEmpty,
           encoding.lowercased() != "identity" {
            completionHandler(.cancel)
            finish(
                .failure(
                    HLSVODOriginResourceError
                        .unsupportedContentEncoding(encoding)
                )
            )
            return
        }
        let contentLength = http.expectedContentLength
        if contentLength > Int64(maximumBytes) {
            completionHandler(.cancel)
            finish(
                .failure(
                    HLSVODOriginResourceError.resourceTooLarge(
                        limit: maximumBytes,
                        actual:
                            contentLength <= Int64(Int.max)
                            ? Int(contentLength)
                            : nil
                    )
                )
            )
            return
        }
        lock.withLock {
            self.response = http
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive chunk: Data
    ) {
        let exceeded: Int?
        lock.lock()
        if chunk.count > maximumBytes - data.count {
            exceeded = data.count + chunk.count
        } else {
            data.append(chunk)
            exceeded = nil
        }
        lock.unlock()
        if let exceeded {
            dataTask.cancel()
            finish(
                .failure(
                    HLSVODOriginResourceError.resourceTooLarge(
                        limit: maximumBytes,
                        actual: exceeded
                    )
                )
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            if (error as? URLError)?.code == .cancelled {
                finish(.failure(CancellationError()))
            } else if let urlError = error as? URLError {
                finish(
                    .failure(
                        HLSVODOriginResourceError.transport(
                            urlError.code
                        )
                    )
                )
            } else {
                finish(
                    .failure(
                        HLSVODOriginResourceError
                            .transportFailure
                    )
                )
            }
            return
        }

        let responseAndData:
            (HTTPURLResponse?, Data) = lock.withLock {
                (response, data)
            }
        guard let response = responseAndData.0 else {
            finish(
                .failure(
                    HLSVODOriginResourceError.nonHTTPResponse
                )
            )
            return
        }
        if response.expectedContentLength >= 0,
           response.expectedContentLength
            != Int64(responseAndData.1.count) {
            finish(
                .failure(
                    HLSVODOriginResourceError
                        .contentLengthMismatch(
                            expected:
                                response
                                    .expectedContentLength,
                            actual:
                                responseAndData.1.count
                        )
                )
            )
            return
        }
        finish(
            .success(
                HLSVODOriginFetchResponse(
                    data: responseAndData.1,
                    effectiveURL:
                        response.url ?? request.url!,
                    statusCode: response.statusCode,
                    contentLength:
                        response.expectedContentLength >= 0
                        ? response.expectedContentLength
                        : nil,
                    contentEncoding: response.value(
                        forHTTPHeaderField:
                            "Content-Encoding"
                    )
                )
            )
        )
    }

    private func finish(
        _ result: Result<HLSVODOriginFetchResponse, Error>
    ) {
        let continuation: CheckedContinuation<
            HLSVODOriginFetchResponse,
            Error
        >?
        let session: URLSession?
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        continuation = self.continuation
        self.continuation = nil
        session = self.session
        self.session = nil
        task = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}
