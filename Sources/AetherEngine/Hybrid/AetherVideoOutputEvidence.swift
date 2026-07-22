import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Privacy-safe truth about whether the active Aether route has produced a
/// real video frame. Transport progress, item readiness, renderer enqueue and
/// route state are deliberately not frame evidence.
public enum AetherVideoOutputStatus: String, Sendable, Equatable {
    /// At least one newer frame was decoded and made available for display by
    /// the active route in the current generation.
    case presented
    /// The active playback item was inspected and contains no video track.
    case notExpected
    /// Video is expected (or track inspection is still inconclusive), but no
    /// real presented-frame evidence exists for the current generation.
    case missing
}

/// Stable wire spelling for the codec of the video track actually observed by
/// Aether. This is intentionally separate from route-policy implementation
/// names such as `mpeg4Part2`.
public enum AetherCanonicalVideoCodec: String, Sendable, Equatable {
    case h264
    case hevc
    case av1
    case vp9
    case vp8
    case mpeg2
    case mpeg4
    case vc1
    case unknown
    case none
}

/// Route-neutral, privacy-safe video-output evidence for one stable
/// `AetherPlaybackSession`.
///
/// `frameSequence` never decreases for the life of the outer session. A seek,
/// item rebuild or Aether-owned route transition advances `frameGeneration`
/// and returns the status to `missing` until a real frame is observed again.
public struct AetherVideoOutputSnapshot: Sendable, Equatable {
    public let videoExpected: Bool
    public let outputStatus: AetherVideoOutputStatus
    public let frameSequence: UInt64
    public let frameGeneration: UInt64
    public let lastPresentedFrameMediaTimeSeconds: Double?
    public let observedAtUptimeSeconds: TimeInterval?
    public let activeRoute: PlaybackRenderRoute?
    public let canonicalCodec: AetherCanonicalVideoCodec

    public init(
        videoExpected: Bool,
        outputStatus: AetherVideoOutputStatus,
        frameSequence: UInt64,
        frameGeneration: UInt64,
        lastPresentedFrameMediaTimeSeconds: Double?,
        observedAtUptimeSeconds: TimeInterval?,
        activeRoute: PlaybackRenderRoute?,
        canonicalCodec: AetherCanonicalVideoCodec
    ) {
        self.videoExpected = videoExpected
        self.outputStatus = outputStatus
        self.frameSequence = frameSequence
        self.frameGeneration = frameGeneration
        self.lastPresentedFrameMediaTimeSeconds =
            lastPresentedFrameMediaTimeSeconds
        self.observedAtUptimeSeconds = observedAtUptimeSeconds
        self.activeRoute = activeRoute
        self.canonicalCodec = canonicalCodec
    }

    static let unresolved = AetherVideoOutputSnapshot(
        videoExpected: false,
        outputStatus: .missing,
        frameSequence: 0,
        frameGeneration: 0,
        lastPresentedFrameMediaTimeSeconds: nil,
        observedAtUptimeSeconds: nil,
        activeRoute: nil,
        canonicalCodec: .unknown
    )
}

extension AetherVideoCodec {
    var canonicalVideoOutputCodec: AetherCanonicalVideoCodec {
        switch self {
        case .h264: .h264
        case .hevc: .hevc
        case .av1: .av1
        case .vp9: .vp9
        case .vp8: .vp8
        case .mpeg2: .mpeg2
        case .mpeg4Part2: .mpeg4
        case .vc1: .vc1
        case .unknown: .unknown
        }
    }
}

/// Pure session-level fold that translates route-local generations and frame
/// sequences into one monotonic outer-session contract. Binding tokens retire
/// publisher events from a rebuilt or replaced route before they can mutate
/// public evidence.
struct AetherSessionVideoOutputReducer {
    private(set) var snapshot = AetherVideoOutputSnapshot.unresolved
    private var nextBindingToken: UInt64 = 0
    private var activeBindingToken: UInt64?
    private var routeGeneration: UInt64?
    private var routeSequence: UInt64 = 0

    mutating func beginBinding(
        _ initial: AetherVideoOutputSnapshot
    ) -> UInt64 {
        nextBindingToken &+= 1
        let token = nextBindingToken
        activeBindingToken = token
        routeGeneration = nil
        routeSequence = 0
        _ = apply(initial, bindingToken: token)
        return token
    }

    @discardableResult
    mutating func apply(
        _ routeSnapshot: AetherVideoOutputSnapshot,
        bindingToken: UInt64
    ) -> AetherVideoOutputSnapshot? {
        guard activeBindingToken == bindingToken else { return nil }
        var outerGeneration = snapshot.frameGeneration
        if routeGeneration != routeSnapshot.frameGeneration {
            routeGeneration = routeSnapshot.frameGeneration
            outerGeneration &+= 1
        }

        var outerSequence = snapshot.frameSequence
        if routeSnapshot.outputStatus == .presented,
           routeSnapshot.frameSequence > routeSequence {
            // A coalesced route update still represents one observation at
            // the public boundary. Duplicate or older local updates cannot
            // advance the outer sequence.
            outerSequence &+= 1
        }
        routeSequence = max(
            routeSequence,
            routeSnapshot.frameSequence
        )

        snapshot = AetherVideoOutputSnapshot(
            videoExpected: routeSnapshot.videoExpected,
            outputStatus: routeSnapshot.outputStatus,
            frameSequence: outerSequence,
            frameGeneration: outerGeneration,
            lastPresentedFrameMediaTimeSeconds:
                routeSnapshot.outputStatus == .presented
                    ? routeSnapshot
                        .lastPresentedFrameMediaTimeSeconds
                    : nil,
            observedAtUptimeSeconds:
                routeSnapshot.outputStatus == .presented
                    ? routeSnapshot.observedAtUptimeSeconds
                    : nil,
            activeRoute: routeSnapshot.activeRoute,
            canonicalCodec: routeSnapshot.canonicalCodec
        )
        return snapshot
    }

    @discardableResult
    mutating func invalidate() -> AetherVideoOutputSnapshot {
        activeBindingToken = nil
        routeGeneration = nil
        routeSequence = 0
        snapshot = AetherVideoOutputSnapshot(
            videoExpected: false,
            outputStatus: .missing,
            frameSequence: snapshot.frameSequence,
            frameGeneration: snapshot.frameGeneration &+ 1,
            lastPresentedFrameMediaTimeSeconds: nil,
            observedAtUptimeSeconds: nil,
            activeRoute: nil,
            canonicalCodec: .unknown
        )
        return snapshot
    }
}

enum AetherObservedVideoCodec {
    static func canonical(
        formatDescriptions: [CMFormatDescription]
    ) -> AetherCanonicalVideoCodec {
        for description in formatDescriptions {
            switch fourccString(
                CMFormatDescriptionGetMediaSubType(description)
            ).lowercased() {
            case "avc1", "avc3": return .h264
            case "hvc1", "hev1", "dvh1", "dvhe": return .hevc
            case "av01": return .av1
            case "vp09": return .vp9
            case "vp08": return .vp8
            case "mp2v": return .mpeg2
            case "mp4v": return .mpeg4
            case "vc-1", "wvc1": return .vc1
            default: continue
            }
        }
        return .unknown
    }
}

/// Pure policy for reconciling source-positive video facts with the tracks
/// exposed by the exact Native AVPlayerItem. An empty track list may prove an
/// audio-only item only when preflight did not already prove a video codec.
enum AetherNativeVideoTrackInspectionResult:
    Sendable,
    Equatable
{
    case observedVideo(AetherCanonicalVideoCodec)
    case observedNoVideo
    case expectedVideoMissing(AetherCanonicalVideoCodec)
    case unexpectedVideo(AetherCanonicalVideoCodec)
    case nativeRouteRejectedHEVC
    case inconclusive

    static func resolve(
        sourceHasVideo: Bool,
        sourceCodec: AetherVideoCodec,
        observedTrackCodec: AetherCanonicalVideoCodec?
    ) -> Self {
        if let observedTrackCodec {
            guard sourceHasVideo || sourceCodec != .unknown else {
                return .unexpectedVideo(observedTrackCodec)
            }
            if observedTrackCodec == .hevc {
                return .nativeRouteRejectedHEVC
            }
            return .observedVideo(observedTrackCodec)
        }
        guard !sourceHasVideo, sourceCodec == .unknown else {
            return .expectedVideoMissing(
                sourceCodec.canonicalVideoOutputCodec
            )
        }
        return .observedNoVideo
    }
}

@MainActor
protocol AetherNativePresentedFrameOutput: AnyObject {
    func bind(to item: AVPlayerItem)
    func unbind()
    func copyPresentedFrameTime(
        for item: AVPlayerItem,
        hostTimeSeconds: TimeInterval
    ) -> CMTime?
}

@MainActor
final class AetherAVPlayerItemPresentedFrameOutput:
    AetherNativePresentedFrameOutput
{
    private let output: AVPlayerItemVideoOutput
    private weak var item: AVPlayerItem?

    init() {
        output = AVPlayerItemVideoOutput(
            pixelBufferAttributes: nil
        )
        // Aether observes the same output AVPlayer renders. Observation must
        // never suppress the host-visible presentation path.
        output.suppressesPlayerRendering = false
    }

    func bind(to item: AVPlayerItem) {
        guard self.item !== item else { return }
        unbind()
        self.item = item
        item.add(output)
    }

    func unbind() {
        item?.remove(output)
        item = nil
    }

    func copyPresentedFrameTime(
        for item: AVPlayerItem,
        hostTimeSeconds: TimeInterval
    ) -> CMTime? {
        guard self.item === item,
              hostTimeSeconds.isFinite else { return nil }
        let itemTime = output.itemTime(
            forHostTime: hostTimeSeconds
        )
        guard itemTime.isValid,
              itemTime.isNumeric,
              output.hasNewPixelBuffer(
                forItemTime: itemTime
              ) else { return nil }
        var displayTime = CMTime.invalid
        guard output.copyPixelBuffer(
            forItemTime: itemTime,
            itemTimeForDisplay: &displayTime
        ) != nil else { return nil }
        return displayTime.isValid && displayTime.isNumeric
            ? displayTime
            : itemTime
    }
}

/// Native route reducer kept independent from AVPlayer clock movement so a
/// progressing HEVC media clock with no decoded output remains `missing`.
@MainActor
final class AetherNativeVideoOutputMonitor {
    private enum TrackObservation {
        case unknown
        case video(AetherCanonicalVideoCodec)
        case noVideo
    }

    private let output: any AetherNativePresentedFrameOutput
    private weak var item: AVPlayerItem?
    private var trackObservation: TrackObservation = .unknown
    private var lastPresentedTime: CMTime?
    private(set) var snapshot: AetherVideoOutputSnapshot

    init(
        output: any AetherNativePresentedFrameOutput =
            AetherAVPlayerItemPresentedFrameOutput()
    ) {
        self.output = output
        snapshot = AetherVideoOutputSnapshot(
            videoExpected: false,
            outputStatus: .missing,
            frameSequence: 0,
            frameGeneration: 0,
            lastPresentedFrameMediaTimeSeconds: nil,
            observedAtUptimeSeconds: nil,
            activeRoute: .nativeAVPlayer,
            canonicalCodec: .unknown
        )
    }

    func bind(to item: AVPlayerItem) {
        guard self.item !== item else { return }
        self.item = item
        output.bind(to: item)
        trackObservation = .unknown
        beginGeneration()
    }

    func unbind() {
        output.unbind()
        item = nil
    }

    func clearItem() {
        output.unbind()
        item = nil
        trackObservation = .unknown
        beginGeneration()
    }

    func beginSeekGeneration() {
        beginGeneration()
    }

    func observeVideoTrack(
        codec: AetherCanonicalVideoCodec
    ) {
        trackObservation = .video(codec)
        snapshot = AetherVideoOutputSnapshot(
            videoExpected: true,
            outputStatus: snapshot.outputStatus == .presented
                ? .presented
                : .missing,
            frameSequence: snapshot.frameSequence,
            frameGeneration: snapshot.frameGeneration,
            lastPresentedFrameMediaTimeSeconds:
                snapshot.lastPresentedFrameMediaTimeSeconds,
            observedAtUptimeSeconds:
                snapshot.observedAtUptimeSeconds,
            activeRoute: .nativeAVPlayer,
            canonicalCodec: codec
        )
    }

    func observeNoVideoTrack() {
        trackObservation = .noVideo
        lastPresentedTime = nil
        snapshot = AetherVideoOutputSnapshot(
            videoExpected: false,
            outputStatus: .notExpected,
            frameSequence: snapshot.frameSequence,
            frameGeneration: snapshot.frameGeneration,
            lastPresentedFrameMediaTimeSeconds: nil,
            observedAtUptimeSeconds: nil,
            activeRoute: .nativeAVPlayer,
            canonicalCodec: .none
        )
    }

    func observeTrackInspectionFailure() {
        trackObservation = .unknown
        lastPresentedTime = nil
        snapshot = AetherVideoOutputSnapshot(
            videoExpected: false,
            outputStatus: .missing,
            frameSequence: snapshot.frameSequence,
            frameGeneration: snapshot.frameGeneration,
            lastPresentedFrameMediaTimeSeconds: nil,
            observedAtUptimeSeconds: nil,
            activeRoute: .nativeAVPlayer,
            canonicalCodec: .unknown
        )
    }

    @discardableResult
    func poll(
        playerTime: CMTime,
        hostTimeSeconds: TimeInterval
    ) -> AetherVideoOutputSnapshot {
        guard case .video = trackObservation,
              let item,
              playerTime.isValid,
              playerTime.isNumeric,
              playerTime.seconds.isFinite,
              let presentedTime = output.copyPresentedFrameTime(
                for: item,
                hostTimeSeconds: hostTimeSeconds
              ),
              presentedTime.isValid,
              presentedTime.isNumeric,
              presentedTime.seconds.isFinite,
              // A seek can preserve the old displayed image. The output must
              // correspond to the current player clock before it can prove a
              // frame for the new generation.
              abs(presentedTime.seconds - playerTime.seconds) <= 1 else {
            return snapshot
        }
        if let lastPresentedTime,
           CMTimeCompare(presentedTime, lastPresentedTime) <= 0 {
            return snapshot
        }
        lastPresentedTime = presentedTime
        snapshot = AetherVideoOutputSnapshot(
            videoExpected: true,
            outputStatus: .presented,
            frameSequence: snapshot.frameSequence &+ 1,
            frameGeneration: snapshot.frameGeneration,
            lastPresentedFrameMediaTimeSeconds:
                presentedTime.seconds,
            observedAtUptimeSeconds:
                ProcessInfo.processInfo.systemUptime,
            activeRoute: .nativeAVPlayer,
            canonicalCodec: snapshot.canonicalCodec
        )
        return snapshot
    }

    private func beginGeneration() {
        lastPresentedTime = nil
        let videoExpected: Bool
        let status: AetherVideoOutputStatus
        let codec: AetherCanonicalVideoCodec
        switch trackObservation {
        case .unknown:
            videoExpected = false
            status = .missing
            codec = .unknown
        case .video(let observedCodec):
            videoExpected = true
            status = .missing
            codec = observedCodec
        case .noVideo:
            videoExpected = false
            status = .notExpected
            codec = .none
        }
        snapshot = AetherVideoOutputSnapshot(
            videoExpected: videoExpected,
            outputStatus: status,
            frameSequence: snapshot.frameSequence,
            frameGeneration: snapshot.frameGeneration &+ 1,
            lastPresentedFrameMediaTimeSeconds: nil,
            observedAtUptimeSeconds: nil,
            activeRoute: .nativeAVPlayer,
            canonicalCodec: codec
        )
    }
}

struct AetherHybridDisplayedFrameCounters: Sendable, Equatable {
    let total: Int
    let dropped: Int

    var displayed: Int {
        max(0, total - dropped)
    }
}

/// Privacy-safe, generation-scoped observations from the renderer metrics
/// bridge. This is diagnostic state only: it can describe a request,
/// completion, or counter change, but it can never manufacture displayed-frame
/// evidence.
struct AetherHybridRendererMetricsDiagnosticsReducer:
    Sendable,
    Equatable
{
    private(set) var lastRequestCarrierTimeSeconds: Double?
    private(set) var lastCompletionCarrierTimeSeconds: Double?
    private(set) var completionCount: UInt64 = 0
    private(set) var lastCompletionHadCounters: Bool?
    private(set) var lastTotalFrameCount: Int?
    private(set) var lastDroppedFrameCount: Int?
    private(set) var lastDisplayedFrameCount: Int?
    private(set) var lastDisplayedFrameDelta: Int?
    private(set) var lastPublishedEvidenceTimeSeconds: Double?

    private var generation: UInt64?

    mutating func beginGeneration(_ generation: UInt64) {
        self = Self()
        self.generation = generation
    }

    mutating func invalidate() {
        self = Self()
    }

    mutating func recordRequest(carrierTime: CMTime) {
        lastRequestCarrierTimeSeconds = Self.finiteSeconds(
            carrierTime
        )
    }

    mutating func recordCompletion(
        carrierTime: CMTime?,
        counters: AetherHybridDisplayedFrameCounters?
    ) {
        lastCompletionCarrierTimeSeconds = carrierTime.flatMap(
            Self.finiteSeconds
        )
        completionCount &+= 1
        lastCompletionHadCounters = counters != nil
        lastDisplayedFrameDelta = nil
        guard let counters else { return }

        let displayed = counters.displayed
        if let previous = lastDisplayedFrameCount {
            // Keep a negative delta visible: it identifies an AVFoundation
            // counter reset instead of disguising it as no progress.
            lastDisplayedFrameDelta = displayed - previous
        }
        lastTotalFrameCount = counters.total
        lastDroppedFrameCount = counters.dropped
        lastDisplayedFrameCount = displayed
    }

    mutating func recordPublishedEvidence(
        _ evidence: AetherHybridPresentedFrameEvidence
    ) {
        guard evidence.generation == generation,
              evidence.mediaTimeSeconds.isFinite else { return }
        lastPublishedEvidenceTimeSeconds =
            evidence.mediaTimeSeconds
    }

    private static func finiteSeconds(_ time: CMTime) -> Double? {
        guard time.isValid,
              time.isNumeric,
              time.seconds.isFinite else { return nil }
        return time.seconds
    }
}

struct AetherHybridPresentedFrameEvidence: Sendable, Equatable {
    let generation: UInt64
    let mediaTimeSeconds: Double
    let observedAtUptimeSeconds: TimeInterval
}

/// Retires asynchronous renderer-metrics samples by identity. A completion
/// from a cancelled seek generation must never clear the newer generation's
/// in-flight sample.
struct AetherHybridMetricsSamplingGate {
    private var nextToken: UInt64 = 0
    private(set) var activeToken: UInt64?

    var hasActiveSample: Bool { activeToken != nil }

    mutating func beginSample() -> UInt64? {
        guard activeToken == nil else { return nil }
        nextToken &+= 1
        activeToken = nextToken
        return nextToken
    }

    mutating func complete(_ token: UInt64) -> Bool {
        guard activeToken == token else { return false }
        activeToken = nil
        return true
    }

    mutating func invalidate() {
        nextToken &+= 1
        activeToken = nil
    }
}

/// Fail-closed bridge from the sample-buffer renderer's actual displayed
/// evidence to a media timestamp from the current generation. Merely
/// enqueueing a sample can never produce evidence.
@MainActor
final class AetherHybridDisplayedFrameEvidenceReducer {
    private var generation: UInt64 = 0
    private var generationHasMetricsBaseline = false
    private var lastDisplayedCount: Int?
    private var enqueuedTimes: [CMTime] = []
    private var lastPresentedTime: CMTime?

    func beginGeneration(_ generation: UInt64) {
        self.generation = generation
        generationHasMetricsBaseline = false
        lastDisplayedCount = nil
        enqueuedTimes.removeAll(keepingCapacity: true)
        lastPresentedTime = nil
    }

    func recordEnqueued(
        presentationTime: CMTime,
        generation: UInt64
    ) {
        guard generation == self.generation,
              presentationTime.isValid,
              presentationTime.isNumeric else { return }
        enqueuedTimes.append(presentationTime)
        if enqueuedTimes.count > 360 {
            enqueuedTimes.removeFirst(enqueuedTimes.count - 360)
        }
    }

    func observeDisplayedPixelBuffer(
        carrierTime: CMTime,
        now: TimeInterval
    ) -> AetherHybridPresentedFrameEvidence? {
        publishCandidate(carrierTime: carrierTime, now: now)
    }

    func observeMetrics(
        _ counters: AetherHybridDisplayedFrameCounters,
        carrierTime: CMTime,
        now: TimeInterval
    ) -> AetherHybridPresentedFrameEvidence? {
        observeMetrics(
            counters,
            requestCarrierTime: carrierTime,
            completionCarrierTime: carrierTime,
            now: now
        )
    }

    /// A renderer metrics request is asynchronous. Once its counters arrive,
    /// the matching PTS bound must come from the completion-side carrier clock
    /// instead of the stale request-side clock. The request time is retained
    /// only as a fail-closed guard against an unannounced backward clock jump
    /// inside one generation.
    func observeMetrics(
        _ counters: AetherHybridDisplayedFrameCounters,
        requestCarrierTime: CMTime,
        completionCarrierTime: CMTime,
        now: TimeInterval
    ) -> AetherHybridPresentedFrameEvidence? {
        guard requestCarrierTime.isValid,
              requestCarrierTime.isNumeric,
              completionCarrierTime.isValid,
              completionCarrierTime.isNumeric,
              CMTimeCompare(
                completionCarrierTime,
                requestCarrierTime
              ) >= 0 else { return nil }
        let displayed = counters.displayed
        guard generationHasMetricsBaseline else {
            generationHasMetricsBaseline = true
            lastDisplayedCount = displayed
            return nil
        }
        guard let previous = lastDisplayedCount else {
            lastDisplayedCount = displayed
            return nil
        }
        guard displayed >= previous else {
            // AVFoundation reset the metrics at a renderer flush. Establish a
            // fresh baseline; never credit an ambiguous count to this
            // generation.
            lastDisplayedCount = displayed
            return nil
        }
        guard displayed > previous else { return nil }
        lastDisplayedCount = displayed
        return publishCandidate(
            carrierTime: completionCarrierTime,
            now: now
        )
    }

    private func publishCandidate(
        carrierTime: CMTime,
        now: TimeInterval
    ) -> AetherHybridPresentedFrameEvidence? {
        guard carrierTime.isValid,
              carrierTime.isNumeric,
              carrierTime.seconds.isFinite,
              now.isFinite else { return nil }
        let tolerance = CMTime(
            seconds: 0.050,
            preferredTimescale: 600
        )
        let upperBound = CMTimeAdd(carrierTime, tolerance)
        guard let candidate = enqueuedTimes.last(where: {
            CMTimeCompare($0, upperBound) <= 0
        }) else { return nil }
        if let lastPresentedTime,
           CMTimeCompare(candidate, lastPresentedTime) <= 0 {
            return nil
        }
        lastPresentedTime = candidate
        enqueuedTimes.removeAll(where: {
            CMTimeCompare($0, candidate) < 0
        })
        return AetherHybridPresentedFrameEvidence(
            generation: generation,
            mediaTimeSeconds: candidate.seconds,
            observedAtUptimeSeconds: now
        )
    }
}
