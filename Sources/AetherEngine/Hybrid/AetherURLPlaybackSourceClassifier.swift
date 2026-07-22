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
        maximumPrefixBytes: Int = defaultMaximumPrefixBytes
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
