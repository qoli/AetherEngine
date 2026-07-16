import Darwin
import CoreMedia
import Foundation
import Libavcodec
import Testing
@testable import AetherEngine

@Suite("Source byte store AVIO integration", .serialized)
struct SourceByteStoreAVIOTests {
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

    @Test("A changed validator invalidates cached bytes before the next open")
    func changedValidatorInvalidatesGeneration() throws {
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
        try second.open(
            url: server.url,
            sourceByteStore: store
        )
        while let packet = try second.readPacket() {
            var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&packetToFree)
        }
        #expect(abs(second.duration - 1.25) < 0.01)
        second.close()
        let expectedGeneration = try SourceByteStoreGeneration(
            contentLength: Int64(replacement.count),
            validator: .strongETag("\"source-generation-b\"")
        )
        #expect(store.snapshot?.generation == expectedGeneration)
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

    @Test("Black-carrier measurement and playback share one validated origin generation")
    func blackCarrierMeasurementPlaybackReuse() throws {
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
        #expect(snapshot.conditionalRequestCount == 1)
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
