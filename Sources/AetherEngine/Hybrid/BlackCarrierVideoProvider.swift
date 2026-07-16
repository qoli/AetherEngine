import CoreMedia
import Foundation

enum BlackCarrierVideoProviderError: Error, LocalizedError, Sendable, Equatable {
    case muxer(BlackCarrierVideoMuxerError)
    case segmentStoreFailed(index: Int)
    case unexpected(reason: String)

    var errorDescription: String? {
        switch self {
        case .muxer(let error):
            return error.localizedDescription
        case .segmentStoreFailed(let index):
            return "Black carrier segment \(index) could not be adopted into session storage"
        case .unexpected(let reason):
            return "Black carrier video provider failed unexpectedly: \(reason)"
        }
    }
}

/// Disk-backed video-only carrier provider for the existing loopback HLS server.
///
/// The provider owns only the fixed black video representation. The eventual hybrid carrier
/// provider composes this with separately muxed real-audio renditions. The master playlist advertises
/// the fixed Hybrid loopback transport budget; measured black-video bytes are diagnostics only.
final class BlackCarrierVideoProvider:
    HLSSegmentProvider,
    HybridCarrierBandwidthTelemetrySource,
    @unchecked Sendable
{
    private struct Storage {
        let cache: SegmentCache
    }

    private let cache: SegmentCache
    private let timeline: BlackCarrierTimeline
    private let closeLock = NSLock()
    private var isClosed = false

    init(timeline: BlackCarrierTimeline) throws {
        let storage = try Self.makeStorage(timeline: timeline)
        cache = storage.cache
        self.timeline = timeline
    }

    deinit {
        close()
    }

    func close() {
        closeLock.lock()
        guard !isClosed else {
            closeLock.unlock()
            return
        }
        isClosed = true
        closeLock.unlock()
        cache.close()
    }

    func initSegment() -> Data? {
        cache.fetchInit(timeout: 0)
    }

    func mediaSegment(at index: Int) -> Data? {
        guard index >= 0, index < segmentCount else { return nil }
        return cache.peek(index: index)
    }

    func mediaSegmentURL(at index: Int) -> URL? {
        guard index >= 0, index < segmentCount else { return nil }
        return cache.peekURL(index: index)
    }

    var segmentCount: Int {
        timeline.segments.count
    }

    func segmentDuration(at index: Int) -> Double {
        guard index >= 0, index < timeline.segments.count else { return 0 }
        return CMTimeGetSeconds(timeline.segments[index].duration)
    }

    var playlistType: HLSPlaylistType { .vod }
    var masterCodecs: String? { BlackCarrierProfile.approved.codecString }
    var masterResolution: (width: Int, height: Int)? {
        (BlackCarrierProfile.approved.width, BlackCarrierProfile.approved.height)
    }
    var masterVideoRange: HLSVideoRange? { .sdr }
    var masterBandwidth: Int? {
        AetherHybridCarrierBandwidthPolicy
            .loopbackTransportBudget
    }
    var masterAverageBandwidth: Int? { nil }
    var masterFrameRate: Double? {
        Double(BlackCarrierProfile.approved.nominalFramesPerSecond)
    }
    var masterClosedCaptions: String? { "NONE" }

    var sessionDirectory: URL {
        cache.sessionDir
    }

    var carrierTimeline: BlackCarrierTimeline {
        timeline
    }

    func observedBandwidthSegmentSamples() throws
        -> [BlackCarrierBandwidthSegmentSample]
    {
        let urls = timeline.segments.compactMap {
            segment -> (segmentIndex: Int, url: URL)? in
            guard let url = cache.peekURL(
                index: segment.index
            ) else {
                return nil
            }
            return (segment.index, url)
        }
        return try BlackCarrierBandwidthTelemetryCalculator
            .fileSamples(urls: urls)
    }

    var carrierBandwidthTelemetry:
        AetherHybridCarrierBandwidthTelemetry
    {
        do {
            return BlackCarrierBandwidthTelemetryCalculator
                .calculate(
                    timeline: timeline,
                    videoSamples:
                        try observedBandwidthSegmentSamples(),
                    audioSamples: []
                )
        } catch {
            return .unavailable(
                audioRenditionCount: 0
            )
        }
    }

    private static func makeStorage(
        timeline: BlackCarrierTimeline
    ) throws -> Storage {
        let segmentWindow = max(1, timeline.segments.count)
        let cache = SegmentCache(
            forwardWindow: segmentWindow,
            backwardWindow: segmentWindow
        )
        do {
            try BlackCarrierVideoMuxer.mux(
                timeline: timeline,
                sessionDirectory: cache.sessionDir,
                onInit: { cache.setInit($0) },
                onSegment: { timing, stagingPath, bytesWritten in
                    cache.adopt(
                        index: timing.index,
                        stagingPath: stagingPath,
                        byteCount: bytesWritten
                    )
                    guard cache.peekURL(index: timing.index) != nil else {
                        throw BlackCarrierVideoProviderError.segmentStoreFailed(
                            index: timing.index
                        )
                    }
                }
            )
        } catch let error as BlackCarrierVideoProviderError {
            cache.close()
            throw error
        } catch let error as BlackCarrierVideoMuxerError {
            cache.close()
            throw BlackCarrierVideoProviderError.muxer(error)
        } catch {
            cache.close()
            throw BlackCarrierVideoProviderError.unexpected(
                reason: String(describing: error)
            )
        }

        return Storage(cache: cache)
    }
}
