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
/// provider composes this with separately muxed real-audio renditions and raises master bandwidth
/// by the highest-cost selectable audio rendition.
final class BlackCarrierVideoProvider: HLSSegmentProvider, @unchecked Sendable {
    private struct Storage {
        let cache: SegmentCache
        let peakBandwidth: Int
        let averageBandwidth: Int
    }

    private let cache: SegmentCache
    private let timeline: BlackCarrierTimeline
    private let peakBandwidth: Int
    private let averageBandwidth: Int
    private let closeLock = NSLock()
    private var isClosed = false

    init(timeline: BlackCarrierTimeline) throws {
        let storage = try Self.makeStorage(timeline: timeline)
        cache = storage.cache
        self.timeline = timeline
        peakBandwidth = storage.peakBandwidth
        averageBandwidth = storage.averageBandwidth
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
    var masterBandwidth: Int? { peakBandwidth }
    var masterAverageBandwidth: Int? { averageBandwidth }
    var masterFrameRate: Double? {
        Double(BlackCarrierProfile.approved.nominalFramesPerSecond)
    }
    var masterClosedCaptions: String? { "NONE" }

    var sessionDirectory: URL {
        cache.sessionDir
    }

    private static func makeStorage(
        timeline: BlackCarrierTimeline
    ) throws -> Storage {
        let segmentWindow = max(1, timeline.segments.count)
        let cache = SegmentCache(
            forwardWindow: segmentWindow,
            backwardWindow: segmentWindow
        )
        var peakBandwidth = 0
        var totalMediaBytes = 0

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
                    let duration = CMTimeGetSeconds(timing.duration)
                    let segmentBandwidth = Int(
                        ceil(Double(bytesWritten) * 8 / duration)
                    )
                    peakBandwidth = max(peakBandwidth, segmentBandwidth)
                    totalMediaBytes += bytesWritten
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

        let duration = CMTimeGetSeconds(timeline.duration)
        let averageBandwidth = Int(
            ceil(Double(totalMediaBytes) * 8 / duration)
        )
        return Storage(
            cache: cache,
            peakBandwidth: max(1, peakBandwidth),
            averageBandwidth: max(1, averageBandwidth)
        )
    }
}
