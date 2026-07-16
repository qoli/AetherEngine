import CoreMedia
import Foundation

struct BlackCarrierAudioRenditionMetadata: Sendable, Equatable {
    let ordinal: Int
    let sourceTrackID: Int
    let language: String?
    let name: String
    let isDefault: Bool
    let isAutoselect: Bool
}

enum BlackCarrierAudioRenditionStoreError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case muxer(BlackCarrierAudioRenditionMuxerError)
    case segmentStoreFailed(trackID: Int, index: Int)
    case incompleteStorage(trackID: Int)
    case unexpected(trackID: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .muxer(let error):
            return error.localizedDescription
        case .segmentStoreFailed(let trackID, let index):
            return "Carrier audio track \(trackID) segment \(index) could not be stored"
        case .incompleteStorage(let trackID):
            return "Carrier audio track \(trackID) storage is incomplete"
        case .unexpected(let trackID, let reason):
            return "Carrier audio track \(trackID) failed unexpectedly: \(reason)"
        }
    }
}

/// Disk-backed bytes and HLS metadata for one selectable real-audio rendition.
///
/// The synchronous initializer is the deterministic assembly boundary used by fixtures and
/// prebuilt VOD sessions. It consumes only the supplied audio demuxer. The production hybrid
/// session can construct the same store from a future shared-demux fanout without changing the
/// provider/server contract.
final class BlackCarrierAudioRenditionStore: @unchecked Sendable {
    let metadata: BlackCarrierAudioRenditionMetadata
    let summary: BlackCarrierAudioRenditionSummary

    private let cache: SegmentCache
    private let segmentDurations: [Double]
    private let closeLock = NSLock()
    private var isClosed = false

    init(
        metadata: BlackCarrierAudioRenditionMetadata,
        demuxer: Demuxer,
        audioStreamIndex: Int32,
        sourceStartPTS: Int64,
        timeline: BlackCarrierTimeline,
        bridgeMode: AudioBridgeMode = .surroundCompat
    ) throws {
        let cache = SegmentCache(
            forwardWindow: max(1, timeline.segments.count),
            backwardWindow: max(1, timeline.segments.count)
        )
        do {
            let summary = try BlackCarrierAudioRenditionMuxer.mux(
                demuxer: demuxer,
                audioStreamIndex: audioStreamIndex,
                sourceStartPTS: sourceStartPTS,
                timeline: timeline,
                bridgeMode: bridgeMode,
                sessionDirectory: cache.sessionDir,
                onInit: { cache.setInit($0) },
                onSegment: { timing, stagingPath, bytesWritten in
                    cache.adopt(
                        index: timing.index,
                        stagingPath: stagingPath,
                        byteCount: bytesWritten
                    )
                    guard cache.peekURL(index: timing.index) != nil else {
                        throw BlackCarrierAudioRenditionStoreError.segmentStoreFailed(
                            trackID: metadata.sourceTrackID,
                            index: timing.index
                        )
                    }
                }
            )
            guard cache.fetchInit(timeout: 0) != nil,
                  timeline.segments.allSatisfy({
                      cache.peekURL(index: $0.index) != nil
                  }) else {
                throw BlackCarrierAudioRenditionStoreError.incompleteStorage(
                    trackID: metadata.sourceTrackID
                )
            }
            self.metadata = metadata
            self.summary = summary
            self.cache = cache
            segmentDurations = timeline.segments.map {
                CMTimeGetSeconds($0.duration)
            }
        } catch let error as BlackCarrierAudioRenditionStoreError {
            cache.close()
            throw error
        } catch let error as BlackCarrierAudioRenditionMuxerError {
            cache.close()
            throw BlackCarrierAudioRenditionStoreError.muxer(error)
        } catch {
            cache.close()
            throw BlackCarrierAudioRenditionStoreError.unexpected(
                trackID: metadata.sourceTrackID,
                reason: String(describing: error)
            )
        }
    }

    init(
        metadata: BlackCarrierAudioRenditionMetadata,
        summary: BlackCarrierAudioRenditionSummary,
        cache: SegmentCache,
        timeline: BlackCarrierTimeline
    ) throws {
        guard cache.fetchInit(timeout: 0) != nil,
              timeline.segments.allSatisfy({
                  cache.peekURL(index: $0.index) != nil
              }) else {
            cache.close()
            throw BlackCarrierAudioRenditionStoreError.incompleteStorage(
                trackID: metadata.sourceTrackID
            )
        }
        self.metadata = metadata
        self.summary = summary
        self.cache = cache
        segmentDurations = timeline.segments.map {
            CMTimeGetSeconds($0.duration)
        }
    }

    deinit {
        close()
    }

    var renditionInfo: HLSAudioRenditionInfo {
        HLSAudioRenditionInfo(
            ordinal: metadata.ordinal,
            language: metadata.language,
            name: metadata.name,
            isDefault: metadata.isDefault,
            isAutoselect: metadata.isAutoselect,
            channels: summary.channelsAttribute
        )
    }

    var codecString: String { summary.codecString }
    var peakBandwidth: Int { summary.peakBandwidth }
    var averageBandwidth: Int { summary.averageBandwidth }
    var segmentCount: Int { segmentDurations.count }
    var sessionDirectory: URL { cache.sessionDir }

    func segmentDuration(at index: Int) -> Double {
        guard segmentDurations.indices.contains(index) else { return 0 }
        return segmentDurations[index]
    }

    func initSegment() -> Data? {
        cache.fetchInit(timeout: 0)
    }

    func mediaSegment(at index: Int) -> Data? {
        guard segmentDurations.indices.contains(index) else { return nil }
        return cache.peek(index: index)
    }

    func mediaSegmentURL(at index: Int) -> URL? {
        guard segmentDurations.indices.contains(index) else { return nil }
        return cache.peekURL(index: index)
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
}

enum BlackCarrierCompositeProviderError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case audioTracksMissing
    case audioDemuxFailed(reason: String)
    case audioMuxerFailed(
        trackID: Int,
        error: BlackCarrierAudioRenditionMuxerError
    )
    case audioStoreFailed(error: BlackCarrierAudioRenditionStoreError)
    case nonContiguousOrdinal(expected: Int, actual: Int)
    case duplicateSourceTrackID(id: Int)
    case duplicateName(name: String)
    case invalidDefaultCount(count: Int)
    case segmentCountMismatch(trackID: Int, video: Int, audio: Int)
    case segmentDurationMismatch(
        trackID: Int,
        index: Int,
        video: Double,
        audio: Double
    )

    var errorDescription: String? {
        switch self {
        case .audioTracksMissing:
            return "Carrier source contains no real audio track"
        case .audioDemuxFailed(let reason):
            return "Carrier audio demux failed: \(reason)"
        case .audioMuxerFailed(let trackID, let error):
            return "Carrier audio track \(trackID) failed: \(error.localizedDescription)"
        case .audioStoreFailed(let error):
            return error.localizedDescription
        case .nonContiguousOrdinal(let expected, let actual):
            return "Carrier audio ordinal \(actual) is invalid; expected \(expected)"
        case .duplicateSourceTrackID(let id):
            return "Carrier source audio track \(id) is duplicated"
        case .duplicateName(let name):
            return "Carrier audio rendition name \"\(name)\" is duplicated"
        case .invalidDefaultCount(let count):
            return "Carrier audio group requires exactly one default rendition, found \(count)"
        case .segmentCountMismatch(let trackID, let video, let audio):
            return "Carrier audio track \(trackID) has \(audio) segments; video has \(video)"
        case .segmentDurationMismatch(let trackID, let index, let video, let audio):
            return "Carrier audio track \(trackID) segment \(index) duration \(audio) does not match video \(video)"
        }
    }
}

/// One HLS provider containing fixed black video plus every selectable real-audio rendition.
///
/// It adopts ownership of the supplied video/audio stores. Validation is all-or-nothing: one
/// malformed or missing audio rendition closes every store and fails the carrier before a server
/// or AVPlayer session can be created.
final class BlackCarrierCompositeProvider: HLSSegmentProvider, @unchecked Sendable {
    private let videoProvider: BlackCarrierVideoProvider
    private let audioStores: [BlackCarrierAudioRenditionStore]
    private let audioStoresByOrdinal: [Int: BlackCarrierAudioRenditionStore]
    private let codecs: String
    private let bandwidth: Int
    private let averageBandwidth: Int
    private let closeLock = NSLock()
    private var isClosed = false

    init(
        videoProvider: BlackCarrierVideoProvider,
        audioStores: [BlackCarrierAudioRenditionStore]
    ) throws {
        do {
            try Self.validate(
                videoProvider: videoProvider,
                audioStores: audioStores
            )
        } catch {
            videoProvider.close()
            audioStores.forEach { $0.close() }
            throw error
        }

        self.videoProvider = videoProvider
        self.audioStores = audioStores
        audioStoresByOrdinal = Dictionary(
            uniqueKeysWithValues: audioStores.map {
                ($0.metadata.ordinal, $0)
            }
        )

        var uniqueCodecs: [String] = []
        if let videoCodec = videoProvider.masterCodecs {
            uniqueCodecs.append(videoCodec)
        }
        for store in audioStores where !uniqueCodecs.contains(store.codecString) {
            uniqueCodecs.append(store.codecString)
        }
        codecs = uniqueCodecs.joined(separator: ",")

        bandwidth = max(
            1,
            (videoProvider.masterBandwidth ?? 0)
                + (audioStores.map(\.peakBandwidth).max() ?? 0)
        )
        averageBandwidth = max(
            1,
            (videoProvider.masterAverageBandwidth ?? 0)
                + (audioStores.map(\.averageBandwidth).max() ?? 0)
        )
    }

    deinit {
        close()
    }

    static func renditionMetadata(
        for tracks: [TrackInfo]
    ) -> [BlackCarrierAudioRenditionMetadata] {
        guard !tracks.isEmpty else { return [] }
        let defaultIndex = tracks.firstIndex(where: \.isDefault) ?? 0
        var nameCounts: [String: Int] = [:]
        return tracks.enumerated().map { ordinal, track in
            let baseName = track.name.isEmpty
                ? "Audio \(ordinal + 1)"
                : track.name
            let count = (nameCounts[baseName] ?? 0) + 1
            nameCounts[baseName] = count
            return BlackCarrierAudioRenditionMetadata(
                ordinal: ordinal,
                sourceTrackID: track.id,
                language: track.language,
                name: count == 1 ? baseName : "\(baseName) \(count)",
                isDefault: ordinal == defaultIndex,
                isAutoselect: true
            )
        }
    }

    /// Eagerly builds every real-audio rendition from one shared demux pass.
    ///
    /// This is the deterministic VOD assembly boundary for the first hybrid carrier. It adopts
    /// `videoProvider` immediately and closes the video plus every audio cache if any track,
    /// packet, or final store fails. Inputs without audio fail explicitly; the separate
    /// silent-carrier path must create its synthetic audio track before calling this builder.
    static func build(
        videoProvider: BlackCarrierVideoProvider,
        audioDemuxer: Demuxer,
        timeline: BlackCarrierTimeline,
        bridgeMode: AudioBridgeMode = .surroundCompat
    ) throws -> BlackCarrierCompositeProvider {
        let pump: BlackCarrierMediaFanoutPump
        do {
            pump = try BlackCarrierMediaFanoutPump(
                demuxer: audioDemuxer,
                timeline: timeline,
                bridgeMode: bridgeMode
            )
        } catch let error as BlackCarrierMediaFanoutPumpError {
            videoProvider.close()
            throw compositeError(from: error)
        } catch {
            videoProvider.close()
            throw BlackCarrierCompositeProviderError.audioDemuxFailed(
                reason: String(describing: error)
            )
        }

        do {
            let stores = try pump.finishStores()
            return try BlackCarrierCompositeProvider(
                videoProvider: videoProvider,
                audioStores: stores
            )
        } catch let error as BlackCarrierMediaFanoutPumpError {
            pump.close()
            videoProvider.close()
            throw compositeError(from: error)
        } catch {
            pump.close()
            videoProvider.close()
            throw error
        }
    }

    func close() {
        closeLock.lock()
        guard !isClosed else {
            closeLock.unlock()
            return
        }
        isClosed = true
        closeLock.unlock()
        videoProvider.close()
        audioStores.forEach { $0.close() }
    }

    func initSegment() -> Data? {
        videoProvider.initSegment()
    }

    func mediaSegment(at index: Int) -> Data? {
        videoProvider.mediaSegment(at: index)
    }

    func mediaSegmentURL(at index: Int) -> URL? {
        videoProvider.mediaSegmentURL(at: index)
    }

    var segmentCount: Int {
        videoProvider.segmentCount
    }

    func segmentDuration(at index: Int) -> Double {
        videoProvider.segmentDuration(at: index)
    }

    var playlistType: HLSPlaylistType {
        videoProvider.playlistType
    }

    var masterCodecs: String? { codecs }
    var masterResolution: (width: Int, height: Int)? {
        videoProvider.masterResolution
    }
    var masterVideoRange: HLSVideoRange? {
        videoProvider.masterVideoRange
    }
    var masterBandwidth: Int? { bandwidth }
    var masterAverageBandwidth: Int? { averageBandwidth }
    var masterFrameRate: Double? {
        videoProvider.masterFrameRate
    }
    var masterClosedCaptions: String? {
        videoProvider.masterClosedCaptions
    }

    var alternateAudioRenditions: [HLSAudioRenditionInfo] {
        audioStores.map(\.renditionInfo)
    }

    func alternateAudioInitSegment(ordinal: Int) -> Data? {
        audioStoresByOrdinal[ordinal]?.initSegment()
    }

    func alternateAudioMediaSegment(ordinal: Int, index: Int) -> Data? {
        audioStoresByOrdinal[ordinal]?.mediaSegment(at: index)
    }

    func alternateAudioMediaSegmentURL(ordinal: Int, index: Int) -> URL? {
        audioStoresByOrdinal[ordinal]?.mediaSegmentURL(at: index)
    }

    func sourceTrackID(forAudioOrdinal ordinal: Int) -> Int? {
        audioStoresByOrdinal[ordinal]?.metadata.sourceTrackID
    }

    private static func validate(
        videoProvider: BlackCarrierVideoProvider,
        audioStores: [BlackCarrierAudioRenditionStore]
    ) throws {
        for (expectedOrdinal, store) in audioStores.enumerated() {
            guard store.metadata.ordinal == expectedOrdinal else {
                throw BlackCarrierCompositeProviderError.nonContiguousOrdinal(
                    expected: expectedOrdinal,
                    actual: store.metadata.ordinal
                )
            }
        }

        var names = Set<String>()
        var sourceTrackIDs = Set<Int>()
        for store in audioStores {
            guard sourceTrackIDs.insert(store.metadata.sourceTrackID).inserted else {
                throw BlackCarrierCompositeProviderError.duplicateSourceTrackID(
                    id: store.metadata.sourceTrackID
                )
            }
            guard names.insert(store.metadata.name).inserted else {
                throw BlackCarrierCompositeProviderError.duplicateName(
                    name: store.metadata.name
                )
            }
        }

        if !audioStores.isEmpty {
            let defaultCount = audioStores.filter {
                $0.metadata.isDefault
            }.count
            guard defaultCount == 1 else {
                throw BlackCarrierCompositeProviderError.invalidDefaultCount(
                    count: defaultCount
                )
            }
        }

        for store in audioStores {
            guard store.segmentCount == videoProvider.segmentCount else {
                throw BlackCarrierCompositeProviderError.segmentCountMismatch(
                    trackID: store.metadata.sourceTrackID,
                    video: videoProvider.segmentCount,
                    audio: store.segmentCount
                )
            }
            for index in 0..<videoProvider.segmentCount {
                let videoDuration = videoProvider.segmentDuration(at: index)
                let audioDuration = store.segmentDuration(at: index)
                guard abs(videoDuration - audioDuration) < 0.000_001 else {
                    throw BlackCarrierCompositeProviderError.segmentDurationMismatch(
                        trackID: store.metadata.sourceTrackID,
                        index: index,
                        video: videoDuration,
                        audio: audioDuration
                    )
                }
            }
        }
    }

    private static func compositeError(
        from error: BlackCarrierMediaFanoutPumpError
    ) -> BlackCarrierCompositeProviderError {
        switch error {
        case .audioTracksMissing:
            return .audioTracksMissing
        case .audioMuxerFailed(let trackID, let error):
            return .audioMuxerFailed(trackID: trackID, error: error)
        case .audioStoreFailed(let error):
            return .audioStoreFailed(error: error)
        default:
            return .audioDemuxFailed(reason: error.localizedDescription)
        }
    }
}
