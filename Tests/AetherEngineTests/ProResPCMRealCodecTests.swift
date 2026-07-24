import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Testing
@testable import AetherEngine

#if canImport(AppKit)
import AppKit
#endif

@Suite("Real ProRes and PCM S24LE codec regression", .serialized)
struct ProResPCMRealCodecTests {
    private final class RangeServer:
        @unchecked Sendable
    {
        struct Snapshot: Sendable, Equatable {
            let requestCount: Int
            let transientFailureCount: Int
            let rangeResponseCount: Int
            let bodyBytesSent: Int
            let maximumConcurrentResponses: Int
            let throttledResponseCount: Int
        }

        private let listener: Int32
        private let acceptQueue = DispatchQueue(
            label: "AetherEngineTests.ProResRange.accept"
        )
        private let responseQueue = DispatchQueue(
            label: "AetherEngineTests.ProResRange.response",
            attributes: .concurrent
        )
        private let lock = NSLock()
        private let body: Data
        private let eTag: String
        private var transientFailuresRemaining: Int
        private var requestCount = 0
        private var transientFailureCount = 0
        private var rangeResponseCount = 0
        private var bodyBytesSent = 0
        private var activeResponses = 0
        private var maximumConcurrentResponses = 0
        private var throttledResponsesRemaining: Int
        private var throttledResponseCount = 0
        private var isClosed = false

        let url: URL

        init(
            body: Data,
            eTag: String,
            transientFailures: Int,
            throttledSuccessfulResponses: Int = 0
        ) throws {
            self.body = body
            self.eTag = eTag
            transientFailuresRemaining = transientFailures
            throttledResponsesRemaining =
                throttledSuccessfulResponses
            let bound = try Self.makeListener()
            listener = bound.descriptor
            url = URL(
                string:
                    "http://127.0.0.1:\(bound.port)/prores-pcm.mov"
            )!
            acceptQueue.async { [weak self] in
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
                requestCount: requestCount,
                transientFailureCount: transientFailureCount,
                rangeResponseCount: rangeResponseCount,
                bodyBytesSent: bodyBytesSent,
                maximumConcurrentResponses:
                    maximumConcurrentResponses,
                throttledResponseCount:
                    throttledResponseCount
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
            let bindResult = withUnsafePointer(
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
                responseQueue.async { [weak self] in
                    guard let self else {
                        Darwin.close(client)
                        return
                    }
                    var noSignal: Int32 = 1
                    setsockopt(
                        client,
                        SOL_SOCKET,
                        SO_NOSIGPIPE,
                        &noSignal,
                        socklen_t(MemoryLayout<Int32>.size)
                    )
                    self.beginResponse()
                    self.handle(client)
                    self.endResponse()
                    Darwin.close(client)
                }
            }
        }

        private func beginResponse() {
            lock.lock()
            activeResponses += 1
            maximumConcurrentResponses = max(
                maximumConcurrentResponses,
                activeResponses
            )
            lock.unlock()
        }

        private func endResponse() {
            lock.lock()
            activeResponses -= 1
            lock.unlock()
        }

        private func handle(_ client: Int32) {
            var requestData = Data()
            var buffer = [UInt8](
                repeating: 0,
                count: 4 * 1024
            )
            while requestData.range(
                of: Data("\r\n\r\n".utf8)
            ) == nil {
                let count = recv(
                    client,
                    &buffer,
                    buffer.count,
                    0
                )
                guard count > 0 else { return }
                requestData.append(
                    contentsOf: buffer[0..<count]
                )
                guard requestData.count <= 64 * 1024 else {
                    return
                }
            }
            guard let request = String(
                data: requestData,
                encoding: .utf8
            ) else {
                return
            }
            let lines = request.components(
                separatedBy: "\r\n"
            )
            let method = lines.first?
                .split(separator: " ")
                .first
                .map(String.init) ?? "GET"
            let headers = lines.dropFirst().reduce(
                into: [String: String]()
            ) { result, line in
                guard let separator = line.firstIndex(
                    of: ":"
                ) else {
                    return
                }
                let name = line[..<separator].lowercased()
                let value = line[
                    line.index(after: separator)...
                ].trimmingCharacters(in: .whitespaces)
                result[name] = value
            }

            lock.lock()
            requestCount += 1
            let shouldFail = transientFailuresRemaining > 0
            if shouldFail {
                transientFailuresRemaining -= 1
                transientFailureCount += 1
            }
            lock.unlock()

            if shouldFail {
                sendResponse(
                    status: "500 Internal Server Error",
                    headers: [
                        "Content-Length: 0",
                        "Connection: close",
                    ],
                    body: Data(),
                    method: method,
                    client: client
                )
                return
            }

            lock.lock()
            let shouldThrottle =
                method != "HEAD"
                && throttledResponsesRemaining > 0
            if shouldThrottle {
                throttledResponsesRemaining -= 1
                throttledResponseCount += 1
            }
            lock.unlock()

            let requestedRange = headers["range"]
            let responseBody: Data
            let status: String
            var responseHeaders = [
                "Accept-Ranges: bytes",
                "Content-Type: video/quicktime",
                "ETag: \(eTag)",
                "Connection: close",
            ]
            if let requestedRange,
               let parsed = parseRange(
                   requestedRange,
                   total: body.count
               ) {
                status = "206 Partial Content"
                let responseRange =
                    parsed.lowerBound..<(parsed.upperBound + 1)
                responseBody = body.subdata(in: responseRange)
                responseHeaders.append(
                    "Content-Range: bytes "
                        + "\(parsed.lowerBound)-"
                        + "\(parsed.upperBound)/\(body.count)"
                )
                lock.lock()
                rangeResponseCount += 1
                lock.unlock()
            } else {
                status = "200 OK"
                responseBody = body
            }
            responseHeaders.append(
                "Content-Length: \(responseBody.count)"
            )
            sendResponse(
                status: status,
                headers: responseHeaders,
                body: responseBody,
                method: method,
                client: client,
                throttleBody: shouldThrottle
            )
        }

        private func sendResponse(
            status: String,
            headers: [String],
            body: Data,
            method: String,
            client: Int32,
            throttleBody: Bool = false
        ) {
            let head = Data(
                (
                    "HTTP/1.1 \(status)\r\n"
                        + headers.joined(separator: "\r\n")
                        + "\r\n\r\n"
                ).utf8
            )
            guard sendAll(head, to: client) == head.count,
                  method != "HEAD" else {
                return
            }
            let sent = throttleBody
                ? sendThrottledBody(body, to: client)
                : sendAll(body, to: client)
            lock.lock()
            bodyBytesSent += sent
            lock.unlock()
        }

        /// Send real response bytes for more than the legacy 45-second
        /// boundary. Every half-second write is unique source-byte progress;
        /// this is deliberately not a sleep-only or retry-only simulation.
        private func sendThrottledBody(
            _ data: Data,
            to client: Int32
        ) -> Int {
            let targetChunkCount = min(94, max(1, data.count))
            let chunkSize = max(
                1,
                Int(
                    ceil(
                        Double(data.count)
                            / Double(targetChunkCount)
                    )
                )
            )
            var total = 0
            var lowerBound = 0
            while lowerBound < data.count {
                let upperBound = min(
                    data.count,
                    lowerBound + chunkSize
                )
                let chunk = data.subdata(
                    in: lowerBound..<upperBound
                )
                let sent = sendAll(chunk, to: client)
                total += sent
                guard sent == chunk.count else { break }
                lowerBound = upperBound
                if lowerBound < data.count {
                    usleep(500_000)
                }
            }
            return total
        }

        private func parseRange(
            _ value: String,
            total: Int
        ) -> ClosedRange<Int>? {
            guard value.hasPrefix("bytes="),
                  total > 0 else {
                return nil
            }
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
            let upper = min(
                requestedUpper ?? (total - 1),
                total - 1
            )
            guard upper >= lower else { return nil }
            return lower...upper
        }

        private func sendAll(
            _ data: Data,
            to client: Int32
        ) -> Int {
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else {
                    return 0
                }
                var total = 0
                while total < data.count {
                    let sent = Darwin.send(
                        client,
                        base.advanced(by: total),
                        data.count - total,
                        0
                    )
                    if sent < 0 {
                        if errno == EINTR {
                            continue
                        }
                        break
                    }
                    guard sent > 0 else { break }
                    total += sent
                }
                return total
            }
        }
    }

    private final class FrameBox: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [DecodedVideoFrame] = []

        func append(_ frame: DecodedVideoFrame) {
            lock.lock()
            frames.append(frame)
            lock.unlock()
        }

        func snapshot() -> [DecodedVideoFrame] {
            lock.lock()
            defer { lock.unlock() }
            return frames
        }
    }

    @Test("Real ProRes 422 10-bit video and PCM S24LE audio traverse Hybrid codecs")
    func realProResAndPCMS24LECodecPath() throws {
        let fixture = try makeFixture()

        let videoDemuxer = Demuxer()
        try videoDemuxer.open(reader: DataIOReader(data: fixture))
        defer { videoDemuxer.close() }

        let videoIndex = videoDemuxer.videoStreamIndex
        let videoStream = try #require(videoDemuxer.stream(at: videoIndex))
        let videoCodecParameters = try #require(
            videoStream.pointee.codecpar
        )
        #expect(
            videoCodecParameters.pointee.codec_id == AV_CODEC_ID_PRORES
        )
        #expect(
            videoCodecParameters.pointee.format
                == AV_PIX_FMT_YUV422P10LE.rawValue
        )
        #expect(videoCodecParameters.pointee.bits_per_raw_sample == 10)
        #expect(avcodec_find_decoder(AV_CODEC_ID_PRORES) != nil)

        videoDemuxer.discardAllStreamsExcept([videoIndex])
        let frames = FrameBox()
        let videoSink = try HybridVideoDecodeSink(
            demuxer: videoDemuxer,
            initialGeneration: 1,
            onFrame: { frames.append($0) }
        )
        defer { videoSink.close() }

        var videoPacketCount = 0
        while let packet = try videoDemuxer.readPacket() {
            var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&packetToFree) }
            guard packet.pointee.stream_index == videoIndex else {
                continue
            }
            videoPacketCount += 1
            try videoSink.consume(packet)
        }
        try videoSink.finish()

        #expect(videoPacketCount > 0)
        let decodedFrame = try #require(frames.snapshot().first)
        let pixelBuffer = decodedFrame.pixelBuffer
        #expect(
            CVPixelBufferGetPixelFormatType(pixelBuffer)
                == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        #expect(CVPixelBufferGetPlaneCount(pixelBuffer) == 2)
        #expect(CVPixelBufferGetWidth(pixelBuffer) == 16)
        #expect(CVPixelBufferGetHeight(pixelBuffer) == 16)
        #expect(pixelBufferContainsNonZeroBytes(pixelBuffer))

        let audioDemuxer = Demuxer()
        try audioDemuxer.open(reader: DataIOReader(data: fixture))
        defer { audioDemuxer.close() }

        let audioIndex = audioDemuxer.audioStreamIndex
        let audioStream = try #require(audioDemuxer.stream(at: audioIndex))
        let audioCodecParameters = try #require(
            audioStream.pointee.codecpar
        )
        #expect(
            audioCodecParameters.pointee.codec_id
                == AV_CODEC_ID_PCM_S24LE
        )
        #expect(audioCodecParameters.pointee.bits_per_raw_sample == 24)
        #expect(audioCodecParameters.pointee.ch_layout.nb_channels == 6)

        let audioBridge = try AudioBridge(
            srcCodecpar: audioCodecParameters,
            srcTimeBase: audioStream.pointee.time_base,
            mode: .lossless
        )
        defer { audioBridge.close() }

        let encodedCodecParameters = try #require(
            audioBridge.encoderCodecpar
        )
        #expect(
            encodedCodecParameters.pointee.codec_id == AV_CODEC_ID_FLAC
        )
        #expect(encodedCodecParameters.pointee.bits_per_raw_sample == 24)
        #expect(encodedCodecParameters.pointee.ch_layout.nb_channels == 6)

        var audioPacketCount = 0
        var encodedPacketCount = 0
        var encodedByteCount = 0
        while let packet = try audioDemuxer.readPacket() {
            var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&packetToFree) }
            guard packet.pointee.stream_index == audioIndex else {
                continue
            }
            audioPacketCount += 1
            for encodedPacket in try audioBridge.feed(packet: packet) {
                var encodedPacketToFree:
                    UnsafeMutablePointer<AVPacket>? = encodedPacket
                defer { trackedPacketFree(&encodedPacketToFree) }
                encodedPacketCount += 1
                encodedByteCount += Int(encodedPacket.pointee.size)
            }
        }
        for encodedPacket in audioBridge.flush() {
            var encodedPacketToFree:
                UnsafeMutablePointer<AVPacket>? = encodedPacket
            defer { trackedPacketFree(&encodedPacketToFree) }
            encodedPacketCount += 1
            encodedByteCount += Int(encodedPacket.pointee.size)
        }

        #expect(audioPacketCount > 0)
        #expect(encodedPacketCount > 0)
        #expect(encodedByteCount > 0)
        #expect(audioBridge.outputBytesLifetime == Int64(encodedByteCount))
    }

    @Test("ProRes backlog spills while PCM still completes carrier segment zero")
    func proResBacklogDoesNotBlockCarrierAudioBootstrap() throws {
        let fixture = try makeFourSecondFixture()
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: 4,
                preferredTimescale: 90_000
            )
        )
        let videoProvider = try BlackCarrierVideoProvider(
            timeline: timeline
        )
        let frames = FrameBox()
        let scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AetherProResBacklogTest-\(UUID().uuidString)",
                isDirectory: true
            )
        let provider = try BlackCarrierLazyCompositeProvider
            .buildSeekableVOD(
                videoProvider: videoProvider,
                source: .custom(
                    DataIOReader(data: fixture),
                    formatHint: "mov"
                ),
                options: LoadOptions(
                    audioBridgeMode: .surroundCompat
                ),
                timeline: timeline,
                bridgeMode: .surroundCompat,
                decodedFrameHandler: {
                    frames.append($0)
                },
                videoBacklogConfiguration: .init(
                    residentByteLimit: 200,
                    packetLimit: 8_192,
                    spoolContentByteLimit: 1 * 1_024 * 1_024
                ),
                videoBacklogScratchRoot: scratchRoot
            )
        defer { provider.close() }

        try provider.prepareForTransportStart()

        let backlog = try #require(
            provider.compressedVideoBacklogSnapshot
        )
        #expect(backlog.maximumResidentContentBytes <= 200)
        #expect(backlog.totalSpooledPackets > 0)
        #expect(backlog.spooledContentBytes > 0)
        #expect(provider.terminalError == nil)
        #expect(!frames.snapshot().isEmpty)
        #expect(
            try #require(
                provider.alternateAudioInitSegment(ordinal: 0)
            ).isEmpty == false
        )
        #expect(
            try #require(
                provider.alternateAudioMediaSegment(
                    ordinal: 0,
                    index: 0
                )
            ).isEmpty == false
        )

        // Carrier-clock demand drains exactly the same FIFO. No new route,
        // source, player or demux reader is introduced by the spill path.
        try provider.advanceVideoDecodeDemand(to: timeline.duration)
        #expect(provider.terminalError == nil)
        #expect(
            provider.compressedVideoBacklogSnapshot?
                .queuedPackets == 0
        )

        provider.close()
        #expect(!FileManager.default.fileExists(
            atPath: scratchRoot.path
        ))
    }

    #if canImport(AppKit)
    @MainActor
    @Test(
        "Same-source byte progress crosses 45 seconds, then ProRes presents"
    )
    func controlledRangeSourceSurvivesLegacyDeadlineAndPresents()
        async throws
    {
        let fixture = try makeFourSecondFixture()
        let server = try RangeServer(
            body: fixture,
            eTag: "\"prores-pcm-generation-1\"",
            transientFailures: 0,
            throttledSuccessfulResponses: 1
        )
        defer { server.close() }
        let options = LoadOptions(
            audioBridgeMode: .surroundCompat
        )
        let preflight = AetherProgressivePreflight(
            request: AetherProgressivePreflightRequest(
                url: server.url,
                options: options
            ),
            retryPolicy: .production,
            sourceByteStore: try SourceByteStore(),
            dependencies: .production
        )
        let slowTransferStartedAt =
            ProcessInfo.processInfo.systemUptime
        let prepared = try await preflight.prepare()
        defer {
            prepared.discardAndWaitForIOQuiescence()
        }

        #expect(
            prepared.progressiveLiveness?.snapshot.state
                == .prepared
        )
        #expect(
            prepared.progressiveLiveness?
                .snapshot.totalAdvancedBytes ?? 0 > 0
        )

        let probe = prepared.probe
        #expect(probe.videoCodecName == "prores")
        #expect(
            probe.audioTracks.map(\.codec)
                .contains("pcm_s24le")
        )
        let profile = AetherSourceProfile(
            probe: probe,
            sourceKind: .progressive,
            isSeekableVOD: probe.isFiniteSeekableVOD
        )
        let result = PlaybackPreflight.resolve(
            sourceProfile: profile,
            hlsPackaging: nil,
            hybridCapabilities:
                AetherHybridPlaybackSession.capabilities,
            requiredAudioBridgeMode: options.audioBridgeMode
        )
        #expect(result.route == .hybridCarrier)
        #expect(result.reason == .hybridProRes)
        #expect(result.sourceProfile.videoCodec == .prores)
        #expect(
            result.sourceProfile.audioCodecs
                == [.pcmS24LE]
        )

        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: probe.durationSeconds,
                preferredTimescale: 90_000
            )
        )
        let session = try await AetherHybridPlaybackSession
            .makeSeekableVOD(
                source: .url(server.url),
                preparedURLSource: prepared,
                options: options,
                timeline: timeline,
                preflightResult: result,
                avPlayer: AVPlayer()
            )
        defer { session.stop() }

        // The real AVSampleBufferDisplayLayer must be drawable for
        // `displayedPixelBuffer` / renderer metrics to publish evidence.
        // A borderless window supplies that production surface; enqueue count
        // alone is deliberately not accepted by this test.
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 64,
                height: 64
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = session.presentationView
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        try await session.prepare(timeout: 10)
        let slowPreparationElapsed =
            ProcessInfo.processInfo.systemUptime
                - slowTransferStartedAt
        #expect(slowPreparationElapsed > 45)
        let postPrepareLiveness =
            try #require(
                prepared.progressiveLiveness?
                    .snapshot
            )
        #expect(
            try #require(
                postPrepareLiveness
                    .lastProgressUptime
            ) - slowTransferStartedAt > 45
        )
        #expect(
            session.state == .ready(generation: 0)
        )
        #expect(
            session.diagnostics.renderer
                .lastEnqueuedTimeSeconds != nil
        )

        var presentedMediaTimes: [Double] = []
        func capturePresentedEvidence() {
            session.pollVideoOutput()
            let snapshot = session.videoOutputSnapshot
            guard snapshot.outputStatus == .presented,
                  let mediaTime =
                    snapshot
                        .lastPresentedFrameMediaTimeSeconds,
                  mediaTime.isFinite,
                  presentedMediaTimes.last.map({
                      mediaTime > $0
                  }) ?? true else {
                return
            }
            presentedMediaTimes.append(mediaTime)
        }

        capturePresentedEvidence()
        try session.play()
        let wallDeadline =
            ProcessInfo.processInfo.systemUptime + 8
        while ProcessInfo.processInfo.systemUptime
                < wallDeadline {
            capturePresentedEvidence()
            if presentedMediaTimes.count >= 3,
               let first = presentedMediaTimes.first,
               let last = presentedMediaTimes.last,
               last - first >= 2 {
                break
            }
            try await Task.sleep(
                nanoseconds: 50_000_000
            )
        }

        #expect(presentedMediaTimes.count >= 3)
        #expect(
            zip(
                presentedMediaTimes,
                presentedMediaTimes.dropFirst()
            ).allSatisfy(<)
        )
        if let first = presentedMediaTimes.first,
           let last = presentedMediaTimes.last {
            #expect(last - first >= 2)
        } else {
            Issue.record(
                "real renderer did not publish media-time evidence"
            )
        }
        #expect(
            session.videoOutputSnapshot.outputStatus
                == .presented
        )
        #expect(
            session.diagnostics.renderer
                .lastPublishedEvidenceTimeSeconds != nil
        )

        let serverSnapshot = server.snapshot
        #expect(serverSnapshot.transientFailureCount == 0)
        #expect(serverSnapshot.throttledResponseCount == 1)
        #expect(serverSnapshot.rangeResponseCount > 0)
        #expect(serverSnapshot.bodyBytesSent >= fixture.count)
        #expect(
            serverSnapshot.maximumConcurrentResponses == 1
        )
    }
    #endif

    private func pixelBufferContainsNonZeroBytes(
        _ pixelBuffer: CVPixelBuffer
    ) -> Bool {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
                == kCVReturnSuccess else {
            return false
        }
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }

        for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
            guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(
                pixelBuffer,
                plane
            ) else {
                continue
            }
            let byteCount = CVPixelBufferGetBytesPerRowOfPlane(
                pixelBuffer,
                plane
            ) * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
            if (0..<byteCount).contains(where: { bytes[$0] != 0 }) {
                return true
            }
        }
        return false
    }

    /// A byte-for-byte reconstruction of `/tmp/aether-prores-pcm-tiny.mov`
    /// (SHA-256 962e5abe6e44734a864ec96cc408fbcbc48f4ac554fa8b4c9e5fc5c0c001a782).
    ///
    /// The source contains one tiny ProRes 422 10-bit frame followed by 14,400
    /// bytes of silent six-channel PCM S24LE. The longest zero run also covers
    /// the first two bytes of the trailing `moov` size, hence 14,402 zeros.
    private func makeFixture() throws -> Data {
        let prefix = try #require(Data(base64Encoded:
            "AAAAFGZ0eXBxdCAgAAACAHF0ICAAAAAId2lkZQAAObdtZGF0AAABb2ljcGYAlAAATGF2YwAQABCAAAICAgAAAwQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQFBAQEBAQEBQUEBAQEBAUFBgQEBAQFBQYHBAQEBAUGBwcEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBQQEBAQEBAUFBAQEBAQFBQYEBAQEBQUGBwQEBAQFBgcHQAAAANMAATAAyTArAHMAKSJQKHtDt2iZKJFcIQlNQ/xAgzF/FxDtMiks3EyNo7FqYnRFodhZUXEvUI24kVhnEoVRDKYT8b6Nyc9DGaakkO14rZQj4vR84a4UewNoos9nq1z6IstNKyUTBeRcWyYnE9ED03nJ1SHPuooJPH2osrzMUJhUG+FsQWZidEaFldtySIVQclYxlEE1aubsTaE49+SM9QL1sOwIq57BENDKOlvphIVRjKkR572sLR3Cl6vI/EXdF2USj0S/idrvbe8CewdoqA=="
        ))
        let suffix = try #require(Data(base64Encoded:
            "BO1tb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPoAAAAZAABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADAAACLXRyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAAAZAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAEAAAABAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAAGQAAAAAAAEAAAAAAaVtZGlhAAAAIG1kaGQAAAAAAAAAAAAAAAAAACgAAAAEAH//AAAAAAAtaGRscgAAAABtaGxydmlkZQAAAAAAAAAAAAAAAAxWaWRlb0hhbmRsZXIAAAFQbWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAALGhkbHIAAAAAZGhscnVybCAAAAAAAAAAAAAAAAALRGF0YUhhbmRsZXIAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAADkc3RibAAAAIBzdHNkAAAAAAAAAAEAAABwYXBjaAAAAAAAAAABAAAAAEZGTVAAAAIAAAACAAAQABAASAAAAEgAAAAAAAAAARdMYXZjNjIuMjguMTAxIHByb3Jlc19rcwAAAAAAAAAAABj//wAAAApmaWVsAQAAAAAQcGFzcAAAAAEAAAABAAAAGHN0dHMAAAAAAAAAAQAAAAEAAAQAAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAABAAAAAQAAABRzdHN6AAAAAAAAAW8AAAABAAAAFHN0Y28AAAAAAAAAAQAAACQAAAIrdHJhawAAAFx0a2hkAAAAAwAAAAAAAAAAAAAAAgAAAAAAAABkAAAAAAAAAAAAAAABAQAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAJGVkdHMAAAAcZWxzdAAAAAAAAAABAAAAZAAAAAAAAQAAAAABo21kaWEAAAAgbWRoZAAAAAAAAAAAAAAAAAAAH0AAAAMgf/8AAAAAAC1oZGxyAAAAAG1obHJzb3VuAAAAAAAAAAAAAAAADFNvdW5kSGFuZGxlcgAAAU5taW5mAAAAEHNtaGQAAAAAAAAAAAAAACxoZGxyAAAAAGRobHJ1cmwgAAAAAAAAAAAAAAAAC0RhdGFIYW5kbGVyAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAAA5nN0YmwAAACCc3RzZAAAAAAAAAABAAAAcmluMjQAAAAAAAAAAQABAAAAAAAAAAYAEAAAAAAfQAAAAAAAAQAAAAMAAAASAAAAAgAAACZ3YXZlAAAADGZybWFpbjI0AAAACmVuZGEAAQAAAAgAAAAAAAAAGGNoYW4AAAAAAAEAAAAAAD8AAAAAAAAAGHN0dHMAAAAAAAAAAQAAAyAAAAABAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAMgAAAAAQAAABRzdHN6AAAAAAAAABIAAAMgAAAAFHN0Y28AAAAAAAAAAQAAAZMAAAAhdWR0YQAAABmpc3dyAA1VxExhdmY2Mi4xMi4xMDE="
        ))

        var data = prefix
        data.append(Data(repeating: 0, count: 14_402))
        data.append(suffix)
        #expect(data.count == 16_064)
        return data
    }

    /// Four seconds of real ProRes 422 10-bit video at 4 fps plus six-channel
    /// PCM S24LE at 48 kHz. The sparse zero runs are silent PCM payload. The
    /// reconstructed MOV is 3,460,377 bytes with SHA-256
    /// `e717ece2adb83945faaa378a8db6b00ec369b6ed500adde3dc80ff9666eb3d47`.
    private func makeFourSecondFixture() throws -> Data {
        let prefix = try #require(Data(base64Encoded:
            "AAAAFGZ0eXBxdCAgAAACAHF0ICAAAAXFbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAD6AAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAwAAAml0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAD6AAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAABAAAAAQAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAA+gAAAAAAABAAAAAAHhbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAABAAAABAAB//wAAAAAALWhkbHIAAAAAbWhscnZpZGUAAAAAAAAAAAAAAAAMVmlkZW9IYW5kbGVyAAABjG1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACxoZGxyAAAAAGRobHJ1cmwgAAAAAAAAAAAAAAAAC0RhdGFIYW5kbGVyAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAABIHN0YmwAAACAc3RzZAAAAAAAAAABAAAAcGFwY24AAAAAAAAAAQAAAABGRk1QAAACAAAAAgAAEAAQAEgAAABIAAAAAAAAAAEXTGF2YzYyLjI4LjEwMSBwcm9yZXNfa3MAAAAAAAAAAAAY//8AAAAKZmllbAEAAAAAEHBhc3AAAAABAAAAAQAAABhzdHRzAAAAAAAAAAEAAAAQAAAQAAAAABxzdHNjAAAAAAAAAAEAAAABAAAAAQAAAAEAAAAUc3RzegAAAAAAAACzAAAAEAAAAFBzdGNvAAAAAAAAABAAAAXpAANmnAAGx08ACigCAA1AtQAQoWgAFAIbABdizgAae4EAHdw0ACE85wAkVZoAJ7ZNACsXAAAud7MAMZBmAAACx3RyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAIAAAAAAAAPoAAAAAAAAAAAAAAAAQEAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAD6AAAAAAAAEAAAAAAj9tZGlhAAAAIG1kaGQAAAAAAAAAAAAAAAAAALuAAALuAH//AAAAAAAtaGRscgAAAABtaGxyc291bgAAAAAAAAAAAAAAAAxTb3VuZEhhbmRsZXIAAAHqbWluZgAAABBzbWhkAAAAAAAAAAAAAAAsaGRscgAAAABkaGxydXJsIAAAAAAAAAAAAAAAAAtEYXRhSGFuZGxlcgAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAYJzdGJsAAAAgnN0c2QAAAAAAAAAAQAAAHJpbjI0AAAAAAAAAAEAAQAAAAAAAAAGABAAAAAAu4AAAAAAAAEAAAADAAAAEgAAAAIAAAAmd2F2ZQAAAAxmcm1haW4yNAAAAAplbmRhAAEAAAAIAAAAAAAAABhjaGFuAAAAAAABAAAAAAA/AAAAAAAAABhzdHRzAAAAAAAAAAEAAu4AAAAAAQAAAHxzdHNjAAAAAAAAAAkAAAABAAAwAAAAAAEAAAAEAAAsAAAAAAEAAAAFAAAwAAAAAAEAAAAIAAAsAAAAAAEAAAAJAAAwAAAAAAEAAAALAAAsAAAAAAEAAAAMAAAwAAAAAAEAAAAPAAAsAAAAAAEAAAAQAAAuAAAAAAEAAAAUc3RzegAAAAAAAAASAALuAAAAAFBzdGNvAAAAAAAAABAAAAacAANnTwAGyAIACii1AA1BaAAQohsAFALOABdjgQAafDQAHdznACE9mgAkVk0AJ7cAACsXswAueGYAMZEZAAAAIXVkdGEAAAAZqXN3cgANVcRMYXZmNjIuMTIuMTAxAAAACHdpZGUANMc4bWRhdAAAALNpY3BmAJQAAExhdmMAEAAQgAACAgIAAAMEBAUFBgcHCQQEBQYHBwkJBQUGBwcJCQoFBQYHBwkJCgUGBwcICQoMBgcHCAkKDA8GBwcJCgsOEQcHCQoLDhEVBAQFBQYHBwkEBAUGBwcJCQUFBgcHCQkKBQUGBwcJCQoFBgcHCAkKDAYHBwgJCgwPBgcHCQoLDhEHBwkKCw4RFUAAAAAXAAEwAA0wBAADAAIHH4yCAII="
        ))
        let proResFrame = try #require(Data(base64Encoded:
            "s2ljcGYAlAAATGF2YwAQABCAAAICAgAAAwQEBQUGBwcJBAQFBgcHCQkFBQYHBwkJCgUFBgcHCQkKBQYHBwgJCgwGBwcICQoMDwYHBwkKCw4RBwcJCgsOERUEBAUFBgcHCQQEBQYHBwkJBQUGBwcJCQoFBQYHBwkJCgUGBwcICQoMBgcHCAkKDA8GBwcJCgsOEQcHCQoLDhEVQAAAABcAATAADTAEAAMAAgcfjIIAgg=="
        ))
        let silentPCMRunLengths = [
            221_188, 221_188, 221_188, 202_756,
            221_188, 221_188, 221_188, 202_756,
            221_188, 221_188, 202_756, 221_188,
            221_188, 221_188, 202_756, 211_969,
        ]
        var data = prefix
        for (index, runLength) in
                silentPCMRunLengths.enumerated() {
            data.append(
                Data(repeating: 0, count: runLength)
            )
            if index < silentPCMRunLengths.count - 1 {
                data.append(proResFrame)
            }
        }
        #expect(data.count == 3_460_377)
        return data
    }
}
