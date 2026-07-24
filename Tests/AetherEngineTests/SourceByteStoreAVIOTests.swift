import Darwin
import CoreMedia
import Foundation
import Libavcodec
import Testing
@testable import AetherEngine

@Suite("Source byte store AVIO integration", .serialized)
struct SourceByteStoreAVIOTests {
    @Test("Redirected upstream expiry re-resolves the canonical source")
    func redirectedUpstreamExpiryReResolvesCanonical() throws {
        let body = Data("redirect-refresh".utf8)
        let server = try RedirectExpiryFixtureServer(
            mode: .redirectedExpiryThenSuccess,
            body: body
        )
        defer { server.close() }
        let reader = AVIOReader(
            url: server.canonicalURL,
            chunkSize: body.count,
            prefetchEnabled: false,
            chunkMaxRetries: 1
        )
        defer {
            reader.close()
            reader.waitForIOQuiescence()
        }

        #expect(
            reader.fetchChunkForTesting(
                from: 0,
                size: body.count
            ) == body
        )
        #expect(reader.terminalError == nil)
        #expect(
            server.snapshot
                == RedirectExpiryFixtureServer.Snapshot(
                    canonicalRequestCount: 2,
                    upstreamRequestCount: 2
                )
        )
    }

    @Test("Canonical hard rejection remains terminal")
    func canonicalHardRejectionRemainsTerminal() throws {
        let server = try RedirectExpiryFixtureServer(
            mode: .canonicalRejected,
            body: Data("unreachable".utf8)
        )
        defer { server.close() }
        let reader = AVIOReader(
            url: server.canonicalURL,
            chunkSize: 4,
            prefetchEnabled: false,
            chunkMaxRetries: 1
        )
        defer {
            reader.close()
            reader.waitForIOQuiescence()
        }

        #expect(
            reader.fetchChunkForTesting(
                from: 0,
                size: 4
            ) == nil
        )
        #expect(
            reader.terminalError
                == .httpStatus(statusCode: 403)
        )
        #expect(
            server.snapshot
                == RedirectExpiryFixtureServer.Snapshot(
                    canonicalRequestCount: 1,
                    upstreamRequestCount: 0
                )
        )
    }

    @Test(
        "markClosed before provider install fences a late URL open"
    )
    func markClosedBeforeOpenStartsNoReader()
        throws
    {
        let server = try RangeFixtureServer(
            body: makeWAV(seconds: 0.1),
            eTag: "\"late-open-fence\""
        )
        defer { server.close() }
        let demuxer = Demuxer()
        demuxer.markClosed()
        defer {
            demuxer.close()
            demuxer.waitForIOQuiescence()
        }

        #expect(throws: CancellationError.self) {
            try demuxer.open(url: server.url)
        }
        #expect(server.snapshot.requestCount == 0)
    }

    @Test("Concurrent AVIO readers fetch one exact origin range")
    func concurrentReaderRangeSingleFlight() async throws {
        let source = makeWAV(seconds: 1)
        let firstRequestObserved =
            DispatchSemaphore(value: 0)
        let releaseFirstResponse =
            DispatchSemaphore(value: 0)
        let server = try RangeFixtureServer(
            body: source,
            eTag: "\"single-flight-generation\"",
            firstRequestObserved: firstRequestObserved,
            releaseFirstResponse: releaseFirstResponse
        )
        defer { server.close() }
        let store = try SourceByteStore(
            blockSize: 64 * 1024,
            capacityBytes: 2 * 1024 * 1024
        )
        defer { store.close() }
        let firstReader = AVIOReader(
            url: server.url,
            chunkSize: source.count,
            prefetchEnabled: false,
            sourceByteStore: store
        )
        let secondReader = AVIOReader(
            url: server.url,
            chunkSize: source.count,
            prefetchEnabled: false,
            sourceByteStore: store
        )
        defer {
            firstReader.close()
            secondReader.close()
        }

        let first = Task.detached {
            firstReader.fetchChunkForTesting(
                from: 0,
                size: source.count
            )
        }
        #expect(
            await waitForRangeServer(
                firstRequestObserved
            )
        )

        let secondStarted = DispatchSemaphore(value: 0)
        let second = Task.detached {
            secondStarted.signal()
            return secondReader.fetchChunkForTesting(
                from: 0,
                size: source.count
            )
        }
        #expect(
            await waitForRangeServer(secondStarted)
        )
        try await Task.sleep(for: .milliseconds(100))
        releaseFirstResponse.signal()

        #expect(await first.value == source)
        #expect(await second.value == source)
        #expect(server.snapshot.requestCount == 1)
        #expect(server.snapshot.bodyBytesSent == source.count)
    }

    @Test("A validated complete generation reopens without redownloading media body")
    func validatedCacheOnlyReopen() throws {
        let source = makeWAV(seconds: 2)
        let server = try RangeFixtureServer(
            body: source,
            eTag: "\"source-generation-a\""
        )
        defer { server.close() }
        let store = try SourceByteStore(
            blockSize: 64 * 1024,
            capacityBytes: Int64(source.count + 64 * 1024)
        )
        defer { store.close() }

        let first = Demuxer()
        try first.open(
            url: server.url,
            sourceByteStore: store
        )
        var firstPacketCount = 0
        while let packet = try first.readPacket() {
            var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&packetToFree)
            firstPacketCount += 1
        }
        first.close()
        #expect(firstPacketCount > 0)
        #expect(store.snapshot?.isComplete == true)
        let afterFirst = server.snapshot
        #expect(afterFirst.bodyBytesSent >= source.count)

        let second = Demuxer()
        try second.open(
            url: server.url,
            sourceByteStore: store
        )
        var secondPacketCount = 0
        while let packet = try second.readPacket() {
            var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&packetToFree)
            secondPacketCount += 1
        }
        second.close()

        let afterSecond = server.snapshot
        #expect(secondPacketCount == firstPacketCount)
        #expect(afterSecond.requestCount == afterFirst.requestCount + 1)
        #expect(afterSecond.conditionalRequestCount == 1)
        #expect(
            afterSecond.bodyBytesSent - afterFirst.bodyBytesSent <= 1
        )
    }

    @Test("A changed validator fails closed before cached generations can mix")
    func changedValidatorFailsClosed() throws {
        let firstSource = makeWAV(seconds: 1)
        let replacement = makeWAV(seconds: 1.25)
        let server = try RangeFixtureServer(
            body: firstSource,
            eTag: "\"source-generation-a\""
        )
        defer { server.close() }
        let store = try SourceByteStore(
            blockSize: 64 * 1024,
            capacityBytes: 2 * 1024 * 1024
        )
        defer { store.close() }

        let first = Demuxer()
        try first.open(
            url: server.url,
            sourceByteStore: store
        )
        while let packet = try first.readPacket() {
            var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&packetToFree)
        }
        first.close()
        #expect(store.snapshot?.isComplete == true)

        server.replace(
            body: replacement,
            eTag: "\"source-generation-b\""
        )
        let second = Demuxer()
        #expect(
            throws: AVIOReaderError.sourceByteStore(
                .generationMismatch
            )
        ) {
            try second.open(
                url: server.url,
                sourceByteStore: store
            )
        }
        second.close()
        let originalGeneration = try SourceByteStoreGeneration(
            contentLength: Int64(firstSource.count),
            validator: .strongETag("\"source-generation-a\"")
        )
        #expect(store.snapshot?.generation == originalGeneration)
        #expect(store.snapshot?.isComplete == true)
    }

    @Test("Resident bytes without a validator are not reused across readers")
    func unvalidatedGenerationIsNotReused() throws {
        let source = makeWAV(seconds: 1)
        let server = try RangeFixtureServer(
            body: source,
            eTag: nil
        )
        defer { server.close() }
        let store = try SourceByteStore(
            blockSize: 64 * 1024,
            capacityBytes: 2 * 1024 * 1024
        )
        defer { store.close() }

        let first = Demuxer()
        try first.open(
            url: server.url,
            sourceByteStore: store
        )
        while let packet = try first.readPacket() {
            var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&packetToFree)
        }
        first.close()
        let afterFirst = server.snapshot
        #expect(store.snapshot?.isComplete == true)
        #expect(store.validationCandidate == nil)

        let second = Demuxer()
        try second.open(
            url: server.url,
            sourceByteStore: store
        )
        while let packet = try second.readPacket() {
            var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&packetToFree)
        }
        second.close()

        let afterSecond = server.snapshot
        #expect(afterSecond.conditionalRequestCount == 0)
        #expect(
            afterSecond.bodyBytesSent - afterFirst.bodyBytesSent
                >= source.count
        )
    }

    @Test("Validatorless Hybrid source fails closed before a seek generation reopens")
    func validatorlessHybridSeekGenerationFailsClosed() throws {
        let source = makeWAV(seconds: 5.25)
        let server = try RangeFixtureServer(
            body: source,
            eTag: nil
        )
        defer { server.close() }
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: 5.25,
                preferredTimescale: 90_000
            )
        )
        let pump = try BlackCarrierMediaFanoutPump
            .makeSeekableVOD(
                source: .url(server.url),
                options: LoadOptions(),
                timeline: timeline
            )
        defer { pump.closeAndWaitForIOQuiescence() }
        _ = try #require(
            try pump.initSegment(ordinal: 0)
        )
        let beforeRestart = server.snapshot

        var replacement = source
        replacement[replacement.count - 1] ^= 0x01
        server.replace(body: replacement, eTag: nil)

        var classifier = HybridSeekIntentClassifier(
            timeline: timeline
        )
        let intent = try classifier.registerExplicitHostSeek(
            to: CMTime(
                seconds: 4.5,
                preferredTimescale: 90_000
            )
        )
        let expected = BlackCarrierMediaFanoutPumpError
            .demuxFailure(
                evidence: BlackCarrierDemuxFailureEvidence(
                    category: .invariant,
                    caseCode:
                        "sourceByteStore.generationMismatch",
                    domain:
                        "AetherEngine.SourceByteStore",
                    code: 3
                )
            )
        #expect(throws: expected) {
            _ = try pump.restart(for: intent)
        }
        #expect(server.snapshot == beforeRestart)
        #expect(pump.generation == 0)
    }

    @Test("Hybrid fresh demux keeps validator drift as typed generation evidence")
    func hybridFreshDemuxPreservesValidatorDrift() throws {
        let source = makeWAV(seconds: 5.25)
        let server = try RangeFixtureServer(
            body: source,
            eTag: "\"hybrid-generation-a\""
        )
        defer { server.close() }
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: 5.25,
                preferredTimescale: 90_000
            )
        )
        let pump = try BlackCarrierMediaFanoutPump
            .makeSeekableVOD(
                source: .url(server.url),
                options: LoadOptions(),
                timeline: timeline
            )
        defer { pump.closeAndWaitForIOQuiescence() }
        _ = try #require(
            try pump.initSegment(ordinal: 0)
        )

        var replacement = source
        replacement[replacement.count - 1] ^= 0x01
        server.replace(
            body: replacement,
            eTag: "\"hybrid-generation-b\""
        )

        var classifier = HybridSeekIntentClassifier(
            timeline: timeline
        )
        let intent = try classifier.registerExplicitHostSeek(
            to: CMTime(
                seconds: 4.5,
                preferredTimescale: 90_000
            )
        )
        let expected = BlackCarrierMediaFanoutPumpError
            .demuxFailure(
                evidence: BlackCarrierDemuxFailureEvidence(
                    category: .invariant,
                    caseCode:
                        "sourceByteStore.generationMismatch",
                    domain:
                        "AetherEngine.SourceByteStore",
                    code: 3
                )
            )
        #expect(throws: expected) {
            _ = try pump.restart(for: intent)
        }
        #expect(server.snapshot.conditionalRequestCount == 1)
        #expect(pump.generation == 0)
    }

    @Test("Black-carrier startup reuses its original demux without a measurement pass")
    func blackCarrierStartupUsesOneDemuxPass() throws {
        let source = makeWAV(seconds: 5.25)
        let server = try RangeFixtureServer(
            body: source,
            eTag: "\"carrier-generation-a\""
        )
        defer { server.close() }
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: 5.25,
                preferredTimescale: 90_000
            )
        )
        let videoProvider = try BlackCarrierVideoProvider(
            timeline: timeline
        )
        let provider = try BlackCarrierLazyCompositeProvider
            .buildSeekableVOD(
                videoProvider: videoProvider,
                source: .url(server.url),
                options: LoadOptions(),
                timeline: timeline
            )
        defer { provider.close() }

        try provider.prepareForTransportStart()
        let snapshot = server.snapshot
        #expect(snapshot.conditionalRequestCount == 0)
        #expect(snapshot.bodyBytesSent <= source.count + 1)
        #expect(provider.alternateAudioRenditions.count == 1)
        #expect(
            provider.alternateAudioMediaSegmentURL(
                ordinal: 0,
                index: 0
            ) != nil
        )
    }

    @Test("Hybrid audio analysis keeps an independent cursor over the shared source bytes")
    func hybridAnalysisReusesSourceBytes() async throws {
        let source = makeWAV(seconds: 5.25)
        let server = try RangeFixtureServer(
            body: source,
            eTag: "\"analysis-generation-a\""
        )
        defer { server.close() }
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: 5.25,
                preferredTimescale: 90_000
            )
        )
        let provider = try BlackCarrierLazyCompositeProvider
            .buildSeekableVOD(
                videoProvider: try BlackCarrierVideoProvider(
                    timeline: timeline
                ),
                source: .url(server.url),
                options: LoadOptions(),
                timeline: timeline
            )
        defer { provider.close() }
        try provider.prepareForTransportStart()
        let beforeAnalysis = server.snapshot

        let request = try AudioAnalysisRequest(
            audioTrackID: 0,
            range: 0.25..<0.75
        )
        let session = AudioAnalysisSession()
        let stream = AudioAnalysisStream(
            gate: session.gate,
            cancel: { session.cancel() }
        )
        let input = try provider.makeAudioAnalysisInput()
        let task = Task.detached {
            await AudioAnalysisRunner.run(
                session: session,
                input: input,
                request: request
            )
        }
        session.install(task: task)

        var totalFrames: Int64 = 0
        var iterator = stream.makeAsyncIterator()
        while let buffer = try await iterator.next() {
            totalFrames += Int64(buffer.pcm.frameLength)
        }
        await task.value

        let afterAnalysis = server.snapshot
        #expect(abs(totalFrames - 24_000) <= 1_200)
        #expect(
            afterAnalysis.conditionalRequestCount
                == beforeAnalysis.conditionalRequestCount + 1
        )
        #expect(
            afterAnalysis.bodyBytesSent
                - beforeAnalysis.bodyBytesSent <= 1
        )
    }

    private func makeWAV(seconds: Double) -> Data {
        let sampleRate = 48_000
        let channels = 2
        let frames = Int(Double(sampleRate) * seconds)
        var pcm = Data(capacity: frames * channels * 2)
        for frame in 0..<frames {
            let value = Int16(
                9_000 * sin(
                    2 * .pi * 440 * Double(frame) / Double(sampleRate)
                )
            )
            for _ in 0..<channels {
                withUnsafeBytes(of: value.littleEndian) {
                    pcm.append(contentsOf: $0)
                }
            }
        }

        var data = Data()
        func appendString(_ value: String) {
            data.append(value.data(using: .ascii)!)
        }
        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        func appendUInt16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        appendString("RIFF")
        appendUInt32(UInt32(36 + pcm.count))
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(UInt16(channels))
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * channels * 2))
        appendUInt16(UInt16(channels * 2))
        appendUInt16(16)
        appendString("data")
        appendUInt32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}

private final class RedirectExpiryFixtureServer:
    @unchecked Sendable
{
    enum Mode: Sendable {
        case redirectedExpiryThenSuccess
        case canonicalRejected
    }

    struct Snapshot: Sendable, Equatable {
        let canonicalRequestCount: Int
        let upstreamRequestCount: Int
    }

    private let listener: Int32
    private let queue = DispatchQueue(
        label: "com.aetherengine.tests.redirect-expiry-server"
    )
    private let lock = NSLock()
    private let mode: Mode
    private let body: Data
    private var canonicalRequestCount = 0
    private var upstreamRequestCount = 0
    private var isClosed = false

    let canonicalURL: URL
    private let upstreamURL: URL

    init(mode: Mode, body: Data) throws {
        self.mode = mode
        self.body = body
        let bound = try Self.makeListener()
        listener = bound.descriptor
        canonicalURL = URL(
            string: "http://127.0.0.1:\(bound.port)/p/source"
        )!
        upstreamURL = URL(
            string: "http://127.0.0.1:\(bound.port)/upstream"
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
            canonicalRequestCount: canonicalRequestCount,
            upstreamRequestCount: upstreamRequestCount
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

    private static func makeListener() throws -> (
        descriptor: Int32,
        port: UInt16
    ) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(.EIO)
        }
        var reuse: Int32 = 1
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) {
            pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(
                        MemoryLayout<sockaddr_in>.size
                    )
                )
            }
        }
        guard bindResult == 0,
              Darwin.listen(descriptor, 8) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EIO)
        }
        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(
            MemoryLayout<sockaddr_in>.size
        )
        let nameResult = withUnsafeMutablePointer(
            to: &boundAddress
        ) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                getsockname(
                    descriptor,
                    $0,
                    &boundLength
                )
            }
        }
        guard nameResult == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EIO)
        }
        return (
            descriptor,
            UInt16(bigEndian: boundAddress.sin_port)
        )
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            var noSignal: Int32 = 1
            setsockopt(
                client,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSignal,
                socklen_t(MemoryLayout<Int32>.size)
            )
            handle(client)
            Darwin.close(client)
        }
    }

    private func handle(_ client: Int32) {
        guard let path = readRequestPath(client) else {
            return
        }
        switch path {
        case "/p/source":
            lock.lock()
            canonicalRequestCount += 1
            lock.unlock()
            switch mode {
            case .redirectedExpiryThenSuccess:
                sendResponse(
                    client,
                    status: "302 Found",
                    headers: [
                        "Location: \(upstreamURL.absoluteString)",
                    ],
                    body: Data()
                )
            case .canonicalRejected:
                sendResponse(
                    client,
                    status: "403 Forbidden",
                    body: Data()
                )
            }

        case "/upstream":
            lock.lock()
            upstreamRequestCount += 1
            let attempt = upstreamRequestCount
            lock.unlock()
            if attempt == 1 {
                sendResponse(
                    client,
                    status: "403 Forbidden",
                    body: Data()
                )
            } else {
                sendResponse(
                    client,
                    status: "206 Partial Content",
                    headers: [
                        "Accept-Ranges: bytes",
                        "Content-Range: bytes 0-\(body.count - 1)/\(body.count)",
                    ],
                    body: body
                )
            }

        default:
            sendResponse(
                client,
                status: "404 Not Found",
                body: Data()
            )
        }
    }

    private func readRequestPath(_ client: Int32) -> String? {
        var requestData = Data()
        var buffer = [UInt8](repeating: 0, count: 4 * 1024)
        while requestData.range(
            of: Data("\r\n\r\n".utf8)
        ) == nil {
            let count = recv(
                client,
                &buffer,
                buffer.count,
                0
            )
            guard count > 0 else { return nil }
            requestData.append(
                contentsOf: buffer[0..<count]
            )
            guard requestData.count <= 64 * 1024 else {
                return nil
            }
        }
        guard let request = String(
            data: requestData,
            encoding: .utf8
        ),
        let requestLine = request
            .components(separatedBy: "\r\n")
            .first else {
            return nil
        }
        let fields = requestLine.split(separator: " ")
        guard fields.count >= 2 else { return nil }
        return String(fields[1])
    }

    private func sendResponse(
        _ client: Int32,
        status: String,
        headers: [String] = [],
        body: Data
    ) {
        let responseHeaders = [
            "HTTP/1.1 \(status)",
            "Content-Length: \(body.count)",
            "Connection: close",
        ] + headers
        let head = Data(
            (responseHeaders.joined(separator: "\r\n")
                + "\r\n\r\n").utf8
        )
        sendAll(head, to: client)
        sendAll(body, to: client)
    }

    private func sendAll(
        _ data: Data,
        to client: Int32
    ) {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else {
                return
            }
            var sent = 0
            while sent < rawBuffer.count {
                let count = Darwin.send(
                    client,
                    base.advanced(by: sent),
                    rawBuffer.count - sent,
                    0
                )
                guard count > 0 else { return }
                sent += count
            }
        }
    }
}

private final class RangeFixtureServer: @unchecked Sendable {
    struct Snapshot: Sendable, Equatable {
        let requestCount: Int
        let conditionalRequestCount: Int
        let bodyBytesSent: Int
    }

    private let listener: Int32
    private let queue = DispatchQueue(
        label: "com.aetherengine.tests.source-byte-range-server"
    )
    private let lock = NSLock()
    private var body: Data
    private var eTag: String?
    private var requestCount = 0
    private var conditionalRequestCount = 0
    private var bodyBytesSent = 0
    private var isClosed = false
    private let firstRequestObserved:
        DispatchSemaphore?
    private let releaseFirstResponse:
        DispatchSemaphore?
    private var didGateFirstRequest = false

    let url: URL

    init(
        body: Data,
        eTag: String?,
        firstRequestObserved:
            DispatchSemaphore? = nil,
        releaseFirstResponse:
            DispatchSemaphore? = nil
    ) throws {
        self.body = body
        self.eTag = eTag
        self.firstRequestObserved =
            firstRequestObserved
        self.releaseFirstResponse =
            releaseFirstResponse
        let bound = try Self.makeListener()
        listener = bound.descriptor
        url = URL(
            string: "http://127.0.0.1:\(bound.port)/source.wav"
        )!
        queue.async { [weak self] in self?.acceptLoop() }
    }

    private static func makeListener() throws -> (
        descriptor: Int32,
        port: UInt16
    ) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var reuse: Int32 = 1
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, 8) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EIO)
        }
        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(
            to: &boundAddress
        ) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                getsockname(descriptor, $0, &boundLength)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EIO)
        }
        let port = UInt16(bigEndian: boundAddress.sin_port)
        return (descriptor, port)
    }

    deinit {
        close()
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            requestCount: requestCount,
            conditionalRequestCount: conditionalRequestCount,
            bodyBytesSent: bodyBytesSent
        )
    }

    func replace(body: Data, eTag: String?) {
        lock.lock()
        self.body = body
        self.eTag = eTag
        lock.unlock()
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
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            var noSignal: Int32 = 1
            setsockopt(
                client,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSignal,
                socklen_t(MemoryLayout<Int32>.size)
            )
            handle(client)
            Darwin.close(client)
        }
    }

    private func handle(_ client: Int32) {
        var requestData = Data()
        var buffer = [UInt8](repeating: 0, count: 4 * 1024)
        while requestData.range(
            of: Data("\r\n\r\n".utf8)
        ) == nil {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            requestData.append(contentsOf: buffer[0..<count])
            guard requestData.count <= 64 * 1024 else { return }
        }
        guard let request = String(
            data: requestData,
            encoding: .utf8
        ) else {
            return
        }
        let headers = request
            .components(separatedBy: "\r\n")
            .dropFirst()
            .reduce(into: [String: String]()) { result, line in
                guard let separator = line.firstIndex(of: ":") else {
                    return
                }
                let name = line[..<separator].lowercased()
                let value = line[line.index(after: separator)...]
                    .trimmingCharacters(in: .whitespaces)
                result[name] = value
            }

        lock.lock()
        let currentBody = body
        let currentETag = eTag
        requestCount += 1
        let ifRange = headers["if-range"]
        if ifRange != nil {
            conditionalRequestCount += 1
        }
        let shouldGate = !didGateFirstRequest
            && releaseFirstResponse != nil
        if shouldGate {
            didGateFirstRequest = true
        }
        lock.unlock()

        if shouldGate {
            firstRequestObserved?.signal()
            releaseFirstResponse?.wait()
        }

        let requestedRange = headers["range"]
        let validatorMatches = ifRange == nil || ifRange == currentETag
        let responseBody: Data
        let status: String
        var responseHeaders = [
            "Accept-Ranges: bytes",
            "Content-Type: audio/wav",
            "Connection: close",
        ]
        if let currentETag {
            responseHeaders.append("ETag: \(currentETag)")
        }
        if validatorMatches,
           let requestedRange,
           let parsed = parseRange(
               requestedRange,
               total: currentBody.count
           ) {
            status = "206 Partial Content"
            responseBody = currentBody.subdata(
                in: parsed.lowerBound..<(parsed.upperBound + 1)
            )
            responseHeaders.append(
                "Content-Range: bytes \(parsed.lowerBound)-"
                    + "\(parsed.upperBound)/\(currentBody.count)"
            )
        } else {
            status = "200 OK"
            responseBody = currentBody
        }
        responseHeaders.append(
            "Content-Length: \(responseBody.count)"
        )
        let head = Data(
            (
                "HTTP/1.1 \(status)\r\n"
                    + responseHeaders.joined(separator: "\r\n")
                    + "\r\n\r\n"
            ).utf8
        )
        guard sendAll(head, to: client) == head.count else { return }
        let sent = sendAll(responseBody, to: client)
        lock.lock()
        bodyBytesSent += sent
        lock.unlock()
    }

    private func parseRange(
        _ value: String,
        total: Int
    ) -> ClosedRange<Int>? {
        guard value.hasPrefix("bytes="), total > 0 else { return nil }
        let bounds = value.dropFirst(6).split(
            separator: "-",
            omittingEmptySubsequences: false
        )
        guard let first = bounds.first,
              let lower = Int(first),
              lower >= 0,
              lower < total else {
            return nil
        }
        let requestedUpper = bounds.count > 1
            ? Int(bounds[1])
            : nil
        let upper = min(requestedUpper ?? (total - 1), total - 1)
        guard upper >= lower else { return nil }
        return lower...upper
    }

    private func sendAll(_ data: Data, to client: Int32) -> Int {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return 0 }
            var total = 0
            while total < data.count {
                let sent = Darwin.send(
                    client,
                    base.advanced(by: total),
                    data.count - total,
                    0
                )
                if sent < 0 {
                    if errno == EINTR { continue }
                    break
                }
                guard sent > 0 else { break }
                total += sent
            }
            return total
        }
    }
}

private func waitForRangeServer(
    _ semaphore: DispatchSemaphore
) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(
                returning:
                    semaphore.wait(
                        timeout: .now() + 2
                    ) == .success
            )
        }
    }
}
