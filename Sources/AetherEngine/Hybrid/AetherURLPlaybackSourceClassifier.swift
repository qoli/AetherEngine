import Foundation

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
        case .transport(let code):
            if let code {
                "Playback source classification transport failed with URL error \(code)"
            } else {
                "Playback source classification transport failed"
            }
        }
    }
}

/// Content-backed URL source classification used before Aether route preflight.
///
/// This classifier never uses a path extension, MIME type or declared codec. HLS is recognized only by
/// the `#EXTM3U` signature in the fetched bytes; every other non-empty payload is classified as a
/// progressive resource and must still pass Aether's FFmpeg probe. No error path selects another source
/// kind or playback backend.
public enum AetherURLPlaybackSourceClassifier {
    public static let defaultMaximumPrefixBytes = 64 * 1024

    public static func classify(
        url: URL,
        options: LoadOptions = .init(),
        maximumPrefixBytes: Int = defaultMaximumPrefixBytes
    ) async throws -> AetherMediaSourceKind {
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
                maximumBytes: maximumPrefixBytes
            )
        }
        return try classify(prefix: data)
    }

    /// Pure signature classifier exposed for contract tests and catalog adapters.
    public static func classify(prefix: Data) throws -> AetherMediaSourceKind {
        guard !prefix.isEmpty else {
            throw AetherURLPlaybackSourceClassificationError.emptyResource
        }
        var bytes = prefix
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes.removeFirst(3)
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            return .progressive
        }
        let firstNonWhitespace = text.drop(while: { $0.isWhitespace })
        return firstNonWhitespace.hasPrefix("#EXTM3U")
            ? .hls
            : .progressive
    }
}

/// One-shot prefix fetch. A server may ignore `Range`; reaching the prefix cap is therefore successful
/// completion, not a whole-resource size failure. The task is cancelled immediately after the cap and no
/// retry or alternate URL is attempted.
private final class AetherURLPlaybackPrefixFetcher:
    NSObject,
    URLSessionDataDelegate,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let request: URLRequest
    private let maximumBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var data = Data()
    private var receivedResponse = false
    private var isFinished = false

    private init(request: URLRequest, maximumBytes: Int) {
        self.request = request
        self.maximumBytes = maximumBytes
    }

    static func fetch(
        request: URLRequest,
        maximumBytes: Int
    ) async throws -> Data {
        let fetcher = AetherURLPlaybackPrefixFetcher(
            request: request,
            maximumBytes: maximumBytes
        )
        return try await withTaskCancellationHandler {
            try await fetcher.start()
        } onCancel: {
            fetcher.finish(.failure(CancellationError()))
        }
    }

    private func start() async throws -> Data {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 30
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
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
            finish(.failure(
                AetherURLPlaybackSourceClassificationError
                    .redirectCredentialScopeViolation
            ))
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
                finish(.failure(
                    AetherURLPlaybackSourceClassificationError
                        .redirectCredentialScopeViolation
                ))
                return
            }
            for (field, value) in originalHeaders
            where Self.safeCrossOriginHeaders.contains(field.lowercased()) {
                redirected.setValue(value, forHTTPHeaderField: field)
            }
        }
        redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        completionHandler(redirected)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(
                AetherURLPlaybackSourceClassificationError.nonHTTPResponse
            ))
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            completionHandler(.cancel)
            finish(.failure(
                AetherURLPlaybackSourceClassificationError.httpStatus(
                    http.statusCode
                )
            ))
            return
        }
        if let encoding = http.value(forHTTPHeaderField: "Content-Encoding"),
           !encoding.isEmpty,
           encoding.lowercased() != "identity" {
            completionHandler(.cancel)
            finish(.failure(
                AetherURLPlaybackSourceClassificationError
                    .unsupportedContentEncoding
            ))
            return
        }
        lock.withLock { receivedResponse = true }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive chunk: Data
    ) {
        var completedPrefix: Data?
        lock.lock()
        let remaining = maximumBytes - data.count
        if remaining > 0 {
            data.append(chunk.prefix(remaining))
        }
        if data.count == maximumBytes {
            completedPrefix = data
        }
        lock.unlock()
        if let completedPrefix {
            dataTask.cancel()
            finish(.success(completedPrefix))
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
                finish(.failure(
                    AetherURLPlaybackSourceClassificationError.transport(
                        code: urlError.code.rawValue
                    )
                ))
            } else {
                finish(.failure(
                    AetherURLPlaybackSourceClassificationError.transport(
                        code: nil
                    )
                ))
            }
            return
        }
        let responseAndData = lock.withLock { (receivedResponse, data) }
        guard responseAndData.0 else {
            finish(.failure(
                AetherURLPlaybackSourceClassificationError.nonHTTPResponse
            ))
            return
        }
        guard !responseAndData.1.isEmpty else {
            finish(.failure(
                AetherURLPlaybackSourceClassificationError.emptyResource
            ))
            return
        }
        finish(.success(responseAndData.1))
    }

    private func finish(_ result: Result<Data, Error>) {
        let continuation: CheckedContinuation<Data, Error>?
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

    private static let safeCrossOriginHeaders: Set<String> = [
        "accept",
        "accept-encoding",
        "accept-language",
        "range",
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
