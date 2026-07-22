import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Backend-neutral scaling policy for real video over the fixed black carrier.
public enum AetherHybridVideoGravity: String, Sendable, Equatable {
    case resizeAspect
    case resizeAspectFill
}

public enum HybridFrameEnqueueOutcome: Sendable, Equatable {
    case accepted
    case staleGeneration
    case backpressured
}

enum HybridRendererStallAction: Sendable, Equatable {
    case inactive
    case wait(TimeInterval)
    case fail(noProgressSeconds: TimeInterval)
}

struct HybridRendererStallDecision {
    static func resolve(
        detectionEnabled: Bool,
        generationMatches: Bool,
        pendingDepth: Int,
        lowWaterMark: Int,
        backpressureStartedAt: TimeInterval?,
        detectionEnabledAt: TimeInterval?,
        lastCapacityProgressAt: TimeInterval?,
        now: TimeInterval,
        threshold: TimeInterval
    ) -> HybridRendererStallAction {
        guard detectionEnabled,
              generationMatches,
              pendingDepth > lowWaterMark,
              let backpressureStartedAt,
              let detectionEnabledAt,
              now.isFinite,
              threshold.isFinite,
              threshold > 0 else {
            return .inactive
        }
        let lastProgress = max(
            backpressureStartedAt,
            detectionEnabledAt,
            lastCapacityProgressAt ?? backpressureStartedAt
        )
        let noProgress = max(0, now - lastProgress)
        guard noProgress >= threshold else {
            return .wait(threshold - noProgress)
        }
        return .fail(noProgressSeconds: noProgress)
    }
}

struct HybridRendererDrainWorkerDiagnostics: Sendable, Equatable {
    let readyCallbacks: UInt64
    let workersStarted: UInt64
    let coalescedCallbacks: UInt64
}

final class HybridRendererDrainWorkerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var workerIsScheduled = false
    private var readyCallbacks: UInt64 = 0
    private var workersStarted: UInt64 = 0
    private var coalescedCallbacks: UInt64 = 0

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        readyCallbacks &+= 1
        guard !workerIsScheduled else {
            coalescedCallbacks &+= 1
            return false
        }
        workerIsScheduled = true
        workersStarted &+= 1
        return true
    }

    func release() {
        lock.lock()
        workerIsScheduled = false
        lock.unlock()
    }

    var diagnostics: HybridRendererDrainWorkerDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        return HybridRendererDrainWorkerDiagnostics(
            readyCallbacks: readyCallbacks,
            workersStarted: workersStarted,
            coalescedCallbacks: coalescedCallbacks
        )
    }
}

/// Typed failures for the only Hybrid real-video presentation backend.
///
/// None of these failures select another renderer, clock, route, player, or
/// color policy. The owning Hybrid session must terminate and preserve this
/// exact cause.
public enum AetherHybridPresentationError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case invalidPresentationTime
    case invalidFrameDuration
    case invalidGeometry
    case unsupportedRotation(Int)
    case unsupportedVideoFormat(VideoFormat)
    case frameFormatDiverged(expected: VideoFormat, actual: VideoFormat)
    case pixelBufferNotIOSurfaceBacked
    case nonMonotonicPresentationTime(previous: CMTime, current: CMTime)
    /// Legacy diagnostic retained for decoding old telemetry. Production
    /// enqueue no longer throws when the bounded mailbox reaches high-water.
    case pendingQueueOverflow(limit: Int)
    case formatDescriptionCreationFailed(status: OSStatus)
    case sampleBufferCreationFailed(status: OSStatus)
    case sampleAttachmentCreationFailed
    case carrierTimebaseUnavailable
    case carrierBindingChanged
    case displayLayerTimebaseChanged
    case rendererStalled(durationSeconds: TimeInterval, queueDepth: Int)
    case rendererFailed(domain: String, code: Int, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidPresentationTime:
            return "Hybrid decoded frame has no valid presentation timestamp"
        case .invalidFrameDuration:
            return "Hybrid decoded frame has no valid positive duration"
        case .invalidGeometry:
            return "Hybrid decoded frame geometry is invalid"
        case .unsupportedRotation(let degrees):
            return "Hybrid sample-buffer presentation supports only quarter-turn rotation, got \(degrees) degrees"
        case .unsupportedVideoFormat(let format):
            return "Hybrid sample-buffer presentation has no verified device contract for \(String(describing: format))"
        case .frameFormatDiverged(let expected, let actual):
            return "Hybrid decoded frame format \(String(describing: actual)) diverged from session format \(String(describing: expected))"
        case .pixelBufferNotIOSurfaceBacked:
            return "Hybrid sample-buffer presentation requires an IOSurface-backed pixel buffer"
        case .nonMonotonicPresentationTime(let previous, let current):
            return "Hybrid sample-buffer presentation timestamp regressed from \(previous.seconds) to \(current.seconds)"
        case .pendingQueueOverflow(let limit):
            return "Hybrid sample-buffer pending queue exceeded its \(limit)-frame bound"
        case .formatDescriptionCreationFailed(let status):
            return "Hybrid CMSampleBuffer format description creation failed (\(status))"
        case .sampleBufferCreationFailed(let status):
            return "Hybrid CMSampleBuffer creation failed (\(status))"
        case .sampleAttachmentCreationFailed:
            return "Hybrid CMSampleBuffer could not create its per-frame attachment dictionary"
        case .carrierTimebaseUnavailable:
            return "Hybrid carrier AVPlayerItem did not publish a valid timebase"
        case .carrierBindingChanged:
            return "Hybrid carrier AVPlayerItem or timebase changed after presentation binding"
        case .displayLayerTimebaseChanged:
            return "Hybrid AVSampleBufferDisplayLayer controlTimebase no longer matches the carrier"
        case .rendererStalled(let durationSeconds, let queueDepth):
            return "Hybrid sample-buffer renderer made no capacity progress for \(durationSeconds) seconds at queue depth \(queueDepth)"
        case .rendererFailed(let domain, let code, let reason):
            return "Hybrid AVSampleBufferVideoRenderer failed: \(domain)(\(code)): \(reason)"
        }
    }
}

/// Aether-owned, backend-neutral Hybrid real-video surface.
///
/// The only production backend is `AVSampleBufferDisplayLayer`. The layer's
/// `controlTimebase` is bound to the carrier `AVPlayerItem.timebase`, making
/// the carrier AVPlayer the only Hybrid clock and audio owner. The host embeds
/// this view but never receives the layer, queue, or timebase.
@MainActor
public final class AetherHybridPresentationView: PlatformBaseView {
    public enum RendererStatus: String, Sendable, Equatable {
        case unknown
        case rendering
        case failed
    }

    public struct Diagnostics: Sendable, Equatable {
        public let generation: UInt64
        public let pendingSampleBuffers: Int
        public let staleGenerationDrops: Int
        public let backPressureObservations: Int
        public let currentBackpressureDurationSeconds: TimeInterval?
        public let lastCapacityProgressUptime: TimeInterval?
        public let mediaDataReadyCallbacks: UInt64
        public let drainWorkersStarted: UInt64
        public let coalescedDrainCallbacks: UInt64
        public let enqueuedSampleBuffers: Int
        /// Samples actually enqueued into the active generation's
        /// AVSampleBufferDisplayLayer with the Apple HDR10+ attachment.
        public let hdr10PlusAttachedSampleBuffers: Int
        /// PTS of the first enqueued HDR10+ sample in the active generation.
        public let firstHDR10PlusAttachmentTimeSeconds: Double?
        public let lastEnqueuedTimeSeconds: Double?
        /// Whether one asynchronous AVFoundation video-performance-metrics
        /// request is currently outstanding for the active generation.
        public let metricsSampleInFlight: Bool
        /// Carrier media time captured when the latest metrics request began.
        public let lastMetricsRequestCarrierTimeSeconds: Double?
        /// Carrier media time re-read when the latest metrics request retired.
        public let lastMetricsCompletionCarrierTimeSeconds: Double?
        /// Number of metrics requests retired in the active generation.
        public let metricsCompletionCount: UInt64
        /// `nil` before any completion, `false` when AVFoundation completed
        /// with no counters, and `true` when the latest completion had them.
        public let lastMetricsCompletionHadCounters: Bool?
        /// Latest cumulative renderer counters returned by AVFoundation.
        public let lastRendererTotalFrameCount: Int?
        public let lastRendererDroppedFrameCount: Int?
        public let lastRendererDisplayedFrameCount: Int?
        /// Signed displayed-counter change at the latest metrics completion.
        /// A negative value records a renderer counter reset.
        public let lastRendererDisplayedFrameDelta: Int?
        /// PTS of the latest frame for which Aether published actual renderer
        /// evidence. Enqueueing alone never updates this value.
        public let lastPublishedEvidenceTimeSeconds: Double?
        /// Source-derived duration of the newest frame admitted in the active generation.
        public let lastAcceptedFrameDurationSeconds: Double?
        /// Geometry from the newest frame admitted in the active generation.
        /// The fixed black carrier canvas is never a source for this value.
        public let lastAcceptedGeometry:
            DecodedVideoFrameGeometry?
        public let carrierTimebaseBound: Bool
        public let rendererStatus: RendererStatus
        public let styledSubtitleVisible: Bool
        public let visibleBitmapSubtitleCount: Int
        public let nativeWebVTTVisible: Bool
        public let visibleNativeWebVTTCueCount: Int

        init(
            generation: UInt64,
            pendingSampleBuffers: Int,
            staleGenerationDrops: Int,
            backPressureObservations: Int,
            currentBackpressureDurationSeconds: TimeInterval? = nil,
            lastCapacityProgressUptime: TimeInterval? = nil,
            mediaDataReadyCallbacks: UInt64 = 0,
            drainWorkersStarted: UInt64 = 0,
            coalescedDrainCallbacks: UInt64 = 0,
            enqueuedSampleBuffers: Int,
            hdr10PlusAttachedSampleBuffers: Int,
            firstHDR10PlusAttachmentTimeSeconds: Double?,
            lastEnqueuedTimeSeconds: Double?,
            metricsSampleInFlight: Bool,
            lastMetricsRequestCarrierTimeSeconds: Double?,
            lastMetricsCompletionCarrierTimeSeconds: Double?,
            metricsCompletionCount: UInt64,
            lastMetricsCompletionHadCounters: Bool?,
            lastRendererTotalFrameCount: Int?,
            lastRendererDroppedFrameCount: Int?,
            lastRendererDisplayedFrameCount: Int?,
            lastRendererDisplayedFrameDelta: Int?,
            lastPublishedEvidenceTimeSeconds: Double?,
            lastAcceptedFrameDurationSeconds: Double?,
            lastAcceptedGeometry:
                DecodedVideoFrameGeometry?,
            carrierTimebaseBound: Bool,
            rendererStatus: RendererStatus,
            styledSubtitleVisible: Bool,
            visibleBitmapSubtitleCount: Int,
            nativeWebVTTVisible: Bool,
            visibleNativeWebVTTCueCount: Int
        ) {
            self.generation = generation
            self.pendingSampleBuffers = pendingSampleBuffers
            self.staleGenerationDrops = staleGenerationDrops
            self.backPressureObservations = backPressureObservations
            self.currentBackpressureDurationSeconds =
                currentBackpressureDurationSeconds
            self.lastCapacityProgressUptime =
                lastCapacityProgressUptime
            self.mediaDataReadyCallbacks = mediaDataReadyCallbacks
            self.drainWorkersStarted = drainWorkersStarted
            self.coalescedDrainCallbacks = coalescedDrainCallbacks
            self.enqueuedSampleBuffers = enqueuedSampleBuffers
            self.hdr10PlusAttachedSampleBuffers =
                hdr10PlusAttachedSampleBuffers
            self.firstHDR10PlusAttachmentTimeSeconds =
                firstHDR10PlusAttachmentTimeSeconds
            self.lastEnqueuedTimeSeconds = lastEnqueuedTimeSeconds
            self.metricsSampleInFlight = metricsSampleInFlight
            self.lastMetricsRequestCarrierTimeSeconds =
                lastMetricsRequestCarrierTimeSeconds
            self.lastMetricsCompletionCarrierTimeSeconds =
                lastMetricsCompletionCarrierTimeSeconds
            self.metricsCompletionCount = metricsCompletionCount
            self.lastMetricsCompletionHadCounters =
                lastMetricsCompletionHadCounters
            self.lastRendererTotalFrameCount =
                lastRendererTotalFrameCount
            self.lastRendererDroppedFrameCount =
                lastRendererDroppedFrameCount
            self.lastRendererDisplayedFrameCount =
                lastRendererDisplayedFrameCount
            self.lastRendererDisplayedFrameDelta =
                lastRendererDisplayedFrameDelta
            self.lastPublishedEvidenceTimeSeconds =
                lastPublishedEvidenceTimeSeconds
            self.lastAcceptedFrameDurationSeconds =
                lastAcceptedFrameDurationSeconds
            self.lastAcceptedGeometry = lastAcceptedGeometry
            self.carrierTimebaseBound = carrierTimebaseBound
            self.rendererStatus = rendererStatus
            self.styledSubtitleVisible = styledSubtitleVisible
            self.visibleBitmapSubtitleCount =
                visibleBitmapSubtitleCount
            self.nativeWebVTTVisible = nativeWebVTTVisible
            self.visibleNativeWebVTTCueCount =
                visibleNativeWebVTTCueCount
        }
    }

    /// Admission contains only formats with passing fixture, physical Apple TV,
    /// display-mode, and human visual evidence. The backend itself is never
    /// replaced.
    public nonisolated static let verifiedVideoFormats: Set<VideoFormat> = [
        .sdr,
        .hdr10,
        .hlg,
        .dolbyVision,
    ]

    private struct PendingSample {
        let sampleBuffer: CMSampleBuffer
        let presentationTime: CMTime
        let hasHDR10PlusAttachment: Bool
    }

    nonisolated static let maximumPendingSampleBuffers = 24
    nonisolated static let pendingSampleLowWaterMark = 8

    private let displayLayer = AVSampleBufferDisplayLayer()
    private var subtitleCanvas: HybridSubtitleOverlayCanvas!
    private weak var boundCarrierItem: AVPlayerItem?
    private var boundCarrierTimebase: CMTimebase?
    private var pendingSamples: [PendingSample] = []
    private var activeGeneration: UInt64 = 0
    private var activeVideoFormat: VideoFormat = .sdr
    private var sourceRotationDegrees: Int?
    private var lastAcceptedPresentationTime: CMTime?
    private var lastAcceptedFrameDurationSeconds: Double?
    private var lastAcceptedGeometry:
        DecodedVideoFrameGeometry?
    private var lastEnqueuedPresentationTime: CMTime?
    private var staleGenerationDrops = 0
    private var backPressureObservations = 0
    private var enqueuedSampleBuffers = 0
    private var hdr10PlusAttachedSampleBuffers = 0
    private var firstHDR10PlusAttachmentTime: CMTime?
    private let rendererDrainQueue = DispatchQueue(
        label: "AetherEngine.HybridPresentationDrain",
        qos: .userInteractive
    )
    private var isRequestingMediaData = false
    private let drainWorkerGate = HybridRendererDrainWorkerGate()
    private var backpressureStartedAt: TimeInterval?
    private var backpressureWatchdog: Task<Void, Never>?
    private var lastCapacityProgressUptime: TimeInterval?
    private var rendererStallDetectionEnabled = false
    private var rendererStallDetectionEnabledAt: TimeInterval?
    private var frameDidLeaveMailbox: (@Sendable () -> Void)?
    private var asynchronousFailureHandler:
        (@MainActor (AetherHybridPresentationError) -> Void)?
    private let displayedFrameEvidence =
        AetherHybridDisplayedFrameEvidenceReducer()
    private var presentedFrameCallback:
        (@MainActor (AetherHybridPresentedFrameEvidence) -> Void)?
    private var metricsSamplingTask: Task<Void, Never>?
    private var metricsSamplingGate =
        AetherHybridMetricsSamplingGate()
    private var metricsDiagnostics =
        AetherHybridRendererMetricsDiagnosticsReducer()
    private var lastMetricsSampleRequestUptime: TimeInterval?
    private var hasBegunVideoGeneration = false
    private var directDisplayedPixelEvidenceAllowed = false

    public var videoGravity: AetherHybridVideoGravity = .resizeAspect {
        didSet {
            displayLayer.videoGravity = switch videoGravity {
            case .resizeAspect: .resizeAspect
            case .resizeAspectFill: .resizeAspectFill
            }
            applyLayerGeometry()
        }
    }

    #if canImport(UIKit)
    public override init(frame: CGRect) {
        super.init(frame: frame)
        configureView()
    }

    public convenience init() {
        self.init(frame: .zero)
    }

    public required init?(coder: NSCoder) {
        return nil
    }
    #elseif canImport(AppKit)
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    public convenience init() {
        self.init(frame: .zero)
    }

    public required init?(coder: NSCoder) {
        return nil
    }
    #endif

    private func configureView() {
        #if canImport(UIKit)
        backgroundColor = .black
        isUserInteractionEnabled = false
        clipsToBounds = true
        layer.addSublayer(displayLayer)
        subtitleCanvas = HybridSubtitleOverlayCanvas(
            parent: layer
        )
        #elseif canImport(AppKit)
        wantsLayer = true
        layer?.backgroundColor = CGColor.black
        layer?.masksToBounds = true
        layer?.addSublayer(displayLayer)
        if let layer {
            subtitleCanvas = HybridSubtitleOverlayCanvas(
                parent: layer
            )
        }
        #endif
        displayLayer.videoGravity = .resizeAspect
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
        applyLayerGeometry()
    }

    #if canImport(UIKit)
    public override func layoutSubviews() {
        super.layoutSubviews()
        applyLayerGeometry()
    }
    #elseif canImport(AppKit)
    public override func layout() {
        super.layout()
        applyLayerGeometry()
    }
    #endif

    /// Start a new decoder/carrier generation and discard every pending sample
    /// from the previous generation. A healthy renderer is flushed; a failed
    /// renderer is surfaced instead of being reset and reused.
    func beginGeneration(
        _ generation: UInt64,
        videoFormat: VideoFormat
    ) throws {
        guard Self.verifiedVideoFormats.contains(videoFormat) else {
            throw AetherHybridPresentationError
                .unsupportedVideoFormat(videoFormat)
        }
        try throwIfRendererFailed()
        flushRenderer(removingDisplayedImage: false)
        activeGeneration = generation
        // `flush(removingDisplayedImage: false)` intentionally preserves the
        // previous picture across seeks. Because the renderer does not expose
        // that pixel buffer's generation, direct pixel evidence is safe only
        // for this view's first generation. Later generations require a
        // displayed-frame metrics advance.
        directDisplayedPixelEvidenceAllowed =
            !hasBegunVideoGeneration
        hasBegunVideoGeneration = true
        metricsSamplingTask?.cancel()
        metricsSamplingTask = nil
        metricsSamplingGate.invalidate()
        metricsDiagnostics.beginGeneration(generation)
        lastMetricsSampleRequestUptime = nil
        displayedFrameEvidence.beginGeneration(generation)
        activeVideoFormat = videoFormat
        releasePendingSamples()
        stopRequestingMediaDataIfNeeded()
        clearBackpressureIfNeeded(force: true)
        lastAcceptedPresentationTime = nil
        lastAcceptedFrameDurationSeconds = nil
        lastAcceptedGeometry = nil
        lastEnqueuedPresentationTime = nil
        hdr10PlusAttachedSampleBuffers = 0
        firstHDR10PlusAttachmentTime = nil
        subtitleCanvas.clear()
    }

    /// Bind exactly once to the carrier item and its actual AVPlayerItem
    /// timebase. Rebinding to another item or timebase is forbidden.
    func bindCarrierClock(
        item: AVPlayerItem,
        timebase: CMTimebase
    ) throws {
        try validateTimebase(timebase)
        if let boundCarrierItem,
           let boundCarrierTimebase {
            guard boundCarrierItem === item,
                  Self.isSameTimebase(boundCarrierTimebase, timebase) else {
                throw AetherHybridPresentationError.carrierBindingChanged
            }
            try validateCarrierClock(item: item, timebase: timebase)
            try drainPendingSamples()
            requestMediaDataDrainIfNeeded()
            return
        }
        boundCarrierItem = item
        boundCarrierTimebase = timebase
        displayLayer.controlTimebase = timebase
        try validateCarrierClock(item: item, timebase: timebase)
        try drainPendingSamples()
        requestMediaDataDrainIfNeeded()
    }

    func validateCarrierClock(
        item: AVPlayerItem,
        timebase: CMTimebase
    ) throws {
        try validateTimebase(timebase)
        guard let boundCarrierItem,
              let boundCarrierTimebase,
              boundCarrierItem === item,
              Self.isSameTimebase(boundCarrierTimebase, timebase) else {
            throw AetherHybridPresentationError.carrierBindingChanged
        }
        guard let layerTimebase = displayLayer.controlTimebase,
              Self.isSameTimebase(layerTimebase, timebase) else {
            throw AetherHybridPresentationError.displayLayerTimebaseChanged
        }
        try throwIfRendererFailed()
        try drainPendingSamples()
    }

    @discardableResult
    func enqueue(
        _ frame: DecodedVideoFrame
    ) throws -> HybridFrameEnqueueOutcome {
        guard frame.generation == activeGeneration else {
            staleGenerationDrops += 1
            return .staleGeneration
        }
        guard frame.presentationTime.isValid,
              frame.presentationTime.isNumeric else {
            throw AetherHybridPresentationError.invalidPresentationTime
        }
        guard frame.duration.isValid,
              frame.duration.isNumeric,
              CMTimeCompare(frame.duration, .zero) > 0 else {
            throw AetherHybridPresentationError.invalidFrameDuration
        }
        guard Self.formatsAreCompatible(
            expected: activeVideoFormat,
            actual: frame.videoFormat
        ) else {
            throw AetherHybridPresentationError.frameFormatDiverged(
                expected: activeVideoFormat,
                actual: frame.videoFormat
            )
        }
        try validateGeometry(frame.geometry)
        if let sourceRotationDegrees {
            guard sourceRotationDegrees == frame.geometry.rotationDegrees else {
                throw AetherHybridPresentationError.invalidGeometry
            }
        } else {
            sourceRotationDegrees = frame.geometry.rotationDegrees
            applyLayerGeometry()
        }
        guard CVPixelBufferGetIOSurface(frame.pixelBuffer) != nil else {
            throw AetherHybridPresentationError.pixelBufferNotIOSurfaceBacked
        }
        if let previous = lastAcceptedPresentationTime,
           CMTimeCompare(frame.presentationTime, previous) <= 0 {
            throw AetherHybridPresentationError
                .nonMonotonicPresentationTime(
                    previous: previous,
                    current: frame.presentationTime
                )
        }
        try drainPendingSamples()
        guard pendingSamples.count
                < Self.maximumPendingSampleBuffers else {
            beginBackpressureIfNeeded()
            requestMediaDataDrainIfNeeded()
            return .backpressured
        }
        let sampleBuffer = try makeSampleBuffer(frame)
        pendingSamples.append(PendingSample(
            sampleBuffer: sampleBuffer,
            presentationTime: frame.presentationTime,
            hasHDR10PlusAttachment: frame.hdr10PlusT35 != nil
        ))
        lastAcceptedPresentationTime = frame.presentationTime
        lastAcceptedFrameDurationSeconds = frame.duration.seconds
        lastAcceptedGeometry = frame.geometry
        applyLayerGeometry()
        try drainPendingSamples()
        requestMediaDataDrainIfNeeded()
        return .accepted
    }

    func flush(removingDisplayedImage: Bool) {
        releasePendingSamples()
        stopRequestingMediaDataIfNeeded()
        clearBackpressureIfNeeded(force: true)
        lastAcceptedPresentationTime = nil
        lastEnqueuedPresentationTime = nil
        subtitleCanvas.clear()
        flushRenderer(removingDisplayedImage: removingDisplayedImage)
    }

    func invalidate() {
        metricsSamplingTask?.cancel()
        metricsSamplingTask = nil
        metricsSamplingGate.invalidate()
        metricsDiagnostics.invalidate()
        flush(removingDisplayedImage: true)
        displayLayer.controlTimebase = nil
        boundCarrierItem = nil
        boundCarrierTimebase = nil
        sourceRotationDegrees = nil
        lastAcceptedFrameDurationSeconds = nil
        lastAcceptedGeometry = nil
        applyLayerGeometry()
    }

    var diagnostics: Diagnostics {
        Diagnostics(
            generation: activeGeneration,
            pendingSampleBuffers: pendingSamples.count,
            staleGenerationDrops: staleGenerationDrops,
            backPressureObservations: backPressureObservations,
            currentBackpressureDurationSeconds:
                backpressureStartedAt.map {
                    ProcessInfo.processInfo.systemUptime - $0
                },
            lastCapacityProgressUptime:
                lastCapacityProgressUptime,
            mediaDataReadyCallbacks:
                drainWorkerGate.diagnostics.readyCallbacks,
            drainWorkersStarted:
                drainWorkerGate.diagnostics.workersStarted,
            coalescedDrainCallbacks:
                drainWorkerGate.diagnostics.coalescedCallbacks,
            enqueuedSampleBuffers: enqueuedSampleBuffers,
            hdr10PlusAttachedSampleBuffers:
                hdr10PlusAttachedSampleBuffers,
            firstHDR10PlusAttachmentTimeSeconds:
                firstHDR10PlusAttachmentTime?.seconds,
            lastEnqueuedTimeSeconds:
                lastEnqueuedPresentationTime?.seconds,
            metricsSampleInFlight:
                metricsSamplingGate.hasActiveSample,
            lastMetricsRequestCarrierTimeSeconds:
                metricsDiagnostics
                    .lastRequestCarrierTimeSeconds,
            lastMetricsCompletionCarrierTimeSeconds:
                metricsDiagnostics
                    .lastCompletionCarrierTimeSeconds,
            metricsCompletionCount:
                metricsDiagnostics.completionCount,
            lastMetricsCompletionHadCounters:
                metricsDiagnostics.lastCompletionHadCounters,
            lastRendererTotalFrameCount:
                metricsDiagnostics.lastTotalFrameCount,
            lastRendererDroppedFrameCount:
                metricsDiagnostics.lastDroppedFrameCount,
            lastRendererDisplayedFrameCount:
                metricsDiagnostics.lastDisplayedFrameCount,
            lastRendererDisplayedFrameDelta:
                metricsDiagnostics.lastDisplayedFrameDelta,
            lastPublishedEvidenceTimeSeconds:
                metricsDiagnostics
                    .lastPublishedEvidenceTimeSeconds,
            lastAcceptedFrameDurationSeconds:
                lastAcceptedFrameDurationSeconds,
            lastAcceptedGeometry: lastAcceptedGeometry,
            carrierTimebaseBound:
                boundCarrierItem != nil
                && boundCarrierTimebase != nil,
            rendererStatus: rendererStatus,
            styledSubtitleVisible:
                subtitleCanvas.styledSubtitleVisible,
            visibleBitmapSubtitleCount:
                subtitleCanvas.visibleBitmapSubtitleCount,
            nativeWebVTTVisible:
                subtitleCanvas.nativeWebVTTVisible,
            visibleNativeWebVTTCueCount:
                subtitleCanvas.visibleNativeWebVTTCueCount
        )
    }

    var controlTimebase: CMTimebase? {
        displayLayer.controlTimebase
    }

    var subtitleCanvasSize: CGSize {
        subtitleCanvas.canvasSize
    }

    func showStyledSubtitle(
        _ frame: HybridStyledSubtitleFrame?
    ) {
        subtitleCanvas.showStyled(frame)
    }

    func showBitmapSubtitles(_ images: [SubtitleImage]) {
        subtitleCanvas.showBitmaps(images)
    }

    func showNativeWebVTTCues(
        _ attributedStrings: [NSAttributedString]
    ) {
        subtitleCanvas.showNativeWebVTT(
            attributedStrings
        )
    }

    func clearNativeWebVTTCues() {
        subtitleCanvas.clearNativeWebVTT()
    }

    func clearSubtitleOverlay() {
        subtitleCanvas.clear()
    }

    private var queueTarget: any AVQueuedSampleBufferRendering {
        if #available(tvOS 17.0, iOS 17.0, macOS 14.0, *) {
            return displayLayer.sampleBufferRenderer
        }
        return displayLayer
    }

    private var rendererStatus: RendererStatus {
        switch currentRendererStatus {
        case .unknown: .unknown
        case .rendering: .rendering
        case .failed: .failed
        @unknown default: .failed
        }
    }

    private func throwIfRendererFailed() throws {
        guard currentRendererStatus != .failed else {
            let error = currentRendererError as NSError?
            let carrierTime = boundCarrierItem?.currentTime().seconds
            let carrierDuration = boundCarrierItem?.duration.seconds
            let lastAcceptedEnd = lastAcceptedPresentationTime.map {
                CMTimeAdd(
                    $0,
                    CMTime(
                        seconds: lastAcceptedFrameDurationSeconds ?? 0,
                        preferredTimescale: 600
                    )
                ).seconds
            }
            let requiresFlush: Bool
            if #available(tvOS 17.0, iOS 17.0, macOS 14.0, *) {
                requiresFlush = displayLayer.sampleBufferRenderer
                    .requiresFlushToResumeDecoding
            } else {
                requiresFlush = displayLayer
                    .requiresFlushToResumeDecoding
            }
            EngineLog.emit(
                "[AetherHybridPresentationView] renderer failure "
                    + "domain=\(error?.domain ?? "AVFoundation") "
                    + "code=\(error?.code ?? -1) "
                    + "requiresFlush=\(requiresFlush) "
                    + "generation=\(activeGeneration) "
                    + "pending=\(pendingSamples.count) "
                    + "enqueued=\(enqueuedSampleBuffers) "
                    + "carrierTime=\(Self.diagnosticTime(carrierTime)) "
                    + "carrierDuration=\(Self.diagnosticTime(carrierDuration)) "
                    + "lastAcceptedEnd=\(Self.diagnosticTime(lastAcceptedEnd)) "
                    + "lastEnqueuedPTS=\(Self.diagnosticTime(lastEnqueuedPresentationTime?.seconds))",
                category: .session
            )
            throw AetherHybridPresentationError.rendererFailed(
                domain: error?.domain ?? "AVFoundation",
                code: error?.code ?? -1,
                reason: error?.localizedDescription
                    ?? "renderer failed without an NSError"
            )
        }
    }

    private static func diagnosticTime(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "unknown" }
        return String(format: "%.6f", seconds)
    }

    private var currentRendererStatus: AVQueuedSampleBufferRenderingStatus {
        if #available(tvOS 17.0, iOS 17.0, macOS 14.0, *) {
            return displayLayer.sampleBufferRenderer.status
        }
        return displayLayer.status
    }

    private var currentRendererError: Error? {
        if #available(tvOS 17.0, iOS 17.0, macOS 14.0, *) {
            return displayLayer.sampleBufferRenderer.error
        }
        return displayLayer.error
    }

    private func drainPendingSamples() throws {
        guard boundCarrierItem != nil,
              boundCarrierTimebase != nil else {
            return
        }
        try throwIfRendererFailed()
        let target = queueTarget
        while target.isReadyForMoreMediaData,
              !pendingSamples.isEmpty {
            let pending = pendingSamples.removeFirst()
            target.enqueue(pending.sampleBuffer)
            displayedFrameEvidence.recordEnqueued(
                presentationTime: pending.presentationTime,
                generation: activeGeneration
            )
            lastCapacityProgressUptime =
                ProcessInfo.processInfo.systemUptime
            frameDidLeaveMailbox?()
            enqueuedSampleBuffers += 1
            if pending.hasHDR10PlusAttachment {
                hdr10PlusAttachedSampleBuffers += 1
                firstHDR10PlusAttachmentTime =
                    firstHDR10PlusAttachmentTime
                    ?? pending.presentationTime
            }
            lastEnqueuedPresentationTime =
                pending.presentationTime
            try throwIfRendererFailed()
        }
        if !pendingSamples.isEmpty {
            backPressureObservations += 1
            beginBackpressureIfNeeded()
        } else {
            stopRequestingMediaDataIfNeeded()
            clearBackpressureIfNeeded(force: false)
        }
        if pendingSamples.count
                <= Self.pendingSampleLowWaterMark {
            clearBackpressureIfNeeded(force: false)
        }
    }

    private func releasePendingSamples() {
        let releasedCount = pendingSamples.count
        pendingSamples.removeAll(keepingCapacity: true)
        guard releasedCount > 0 else { return }
        for _ in 0..<releasedCount {
            frameDidLeaveMailbox?()
        }
        lastCapacityProgressUptime =
            ProcessInfo.processInfo.systemUptime
    }

    func installMailboxCallbacks(
        frameDidLeaveMailbox: @escaping @Sendable () -> Void,
        asynchronousFailureHandler: @escaping @MainActor (
            AetherHybridPresentationError
        ) -> Void
    ) {
        self.frameDidLeaveMailbox = frameDidLeaveMailbox
        self.asynchronousFailureHandler =
            asynchronousFailureHandler
    }

    func installPresentedFrameCallback(
        _ callback: @escaping @MainActor (
            AetherHybridPresentedFrameEvidence
        ) -> Void
    ) {
        presentedFrameCallback = callback
    }

    /// Samples the actual AVSampleBufferVideoRenderer output. A queued sample
    /// is only timestamp inventory; it becomes evidence after either a real
    /// displayed pixel buffer (paused rate) or a displayed-frame metrics
    /// advance from AVFoundation.
    func pollPresentedFrame(
        generation: UInt64,
        carrierTime: CMTime
    ) {
        guard generation == activeGeneration,
              carrierTime.isValid,
              carrierTime.isNumeric else { return }
        guard #available(
            tvOS 17.4,
            iOS 17.4,
            macOS 14.4,
            *
        ) else {
            // Older systems expose enqueue state but no truthful displayed
            // surface. Keep the public result `missing`.
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if directDisplayedPixelEvidenceAllowed,
           let timebase = boundCarrierTimebase,
           CMTimebaseGetRate(timebase) == 0,
           displayLayer.sampleBufferRenderer
                .displayedPixelBuffer() != nil,
           let evidence = displayedFrameEvidence
                .observeDisplayedPixelBuffer(
                    carrierTime: carrierTime,
                    now: now
                ) {
            metricsDiagnostics.recordPublishedEvidence(evidence)
            presentedFrameCallback?(evidence)
        }

        guard !metricsSamplingGate.hasActiveSample,
              lastMetricsSampleRequestUptime.map({
                now - $0 >= 0.20
              }) ?? true,
              let sampleToken = metricsSamplingGate
                .beginSample() else { return }
        lastMetricsSampleRequestUptime = now
        metricsDiagnostics.recordRequest(carrierTime: carrierTime)
        metricsSamplingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let metrics = await self.displayLayer
                .sampleBufferRenderer.videoPerformanceMetrics
            guard self.metricsSamplingGate
                    .complete(sampleToken) else { return }
            self.metricsSamplingTask = nil
            guard !Task.isCancelled,
                  generation == self.activeGeneration else { return }
            let completionCarrierTime =
                self.boundCarrierItem?.currentTime()
            let counters = metrics.map {
                AetherHybridDisplayedFrameCounters(
                    total: $0.totalNumberOfFrames,
                    dropped: $0.numberOfDroppedFrames
                )
            }
            self.metricsDiagnostics.recordCompletion(
                carrierTime: completionCarrierTime,
                counters: counters
            )
            guard self.boundCarrierItem != nil,
                  let boundCarrierTimebase = self.boundCarrierTimebase,
                  let layerTimebase = self.displayLayer.controlTimebase,
                  Self.isSameTimebase(
                    boundCarrierTimebase,
                    layerTimebase
                  ) else { return }
            guard let completionCarrierTime,
                  let counters,
                  let evidence = self.displayedFrameEvidence
                    .observeMetrics(
                        counters,
                        requestCarrierTime: carrierTime,
                        completionCarrierTime:
                            completionCarrierTime,
                        now: ProcessInfo.processInfo.systemUptime
                    ) else { return }
            self.metricsDiagnostics.recordPublishedEvidence(evidence)
            self.presentedFrameCallback?(evidence)
        }
    }

    func setRendererStallDetectionEnabled(_ enabled: Bool) {
        guard enabled != rendererStallDetectionEnabled else {
            return
        }
        rendererStallDetectionEnabled = enabled
        if enabled {
            rendererStallDetectionEnabledAt =
                ProcessInfo.processInfo.systemUptime
            scheduleBackpressureWatchdogIfNeeded()
        } else {
            rendererStallDetectionEnabledAt = nil
            backpressureWatchdog?.cancel()
            backpressureWatchdog = nil
        }
    }

    private func requestMediaDataDrainIfNeeded() {
        guard !pendingSamples.isEmpty,
              boundCarrierItem != nil,
              boundCarrierTimebase != nil,
              !isRequestingMediaData else {
            return
        }
        isRequestingMediaData = true
        let drainWorkerGate = drainWorkerGate
        queueTarget.requestMediaDataWhenReady(
            on: rendererDrainQueue
        ) { [weak self] in
            guard drainWorkerGate.claim() else { return }
            Task { @MainActor [weak self] in
                defer { drainWorkerGate.release() }
                guard let self else { return }
                guard self.isRequestingMediaData else { return }
                do {
                    try self.drainPendingSamples()
                } catch let error as AetherHybridPresentationError {
                    self.stopRequestingMediaDataIfNeeded()
                    self.asynchronousFailureHandler?(error)
                } catch {
                    self.stopRequestingMediaDataIfNeeded()
                    self.asynchronousFailureHandler?(
                        .rendererFailed(
                            domain: String(reflecting: type(of: error)),
                            code: (error as NSError).code,
                            reason: "asynchronous renderer drain failed"
                        )
                    )
                }
            }
        }
    }

    private func stopRequestingMediaDataIfNeeded() {
        guard isRequestingMediaData else { return }
        queueTarget.stopRequestingMediaData()
        isRequestingMediaData = false
    }

    private func beginBackpressureIfNeeded() {
        guard backpressureStartedAt == nil else { return }
        backpressureStartedAt = ProcessInfo.processInfo.systemUptime
        scheduleBackpressureWatchdogIfNeeded()
        EngineLog.emit(
            "[AetherHybridPresentationView] mailbox high-water "
                + "generation=\(activeGeneration) "
                + "depth=\(pendingSamples.count)",
            category: .session
        )
    }

    private func scheduleBackpressureWatchdogIfNeeded() {
        guard rendererStallDetectionEnabled,
              backpressureStartedAt != nil,
              backpressureWatchdog == nil else {
            return
        }
        let generation = activeGeneration
        backpressureWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self {
                let now = ProcessInfo.processInfo.systemUptime
                let action = HybridRendererStallDecision.resolve(
                    detectionEnabled:
                        self.rendererStallDetectionEnabled,
                    generationMatches:
                        self.activeGeneration == generation,
                    pendingDepth: self.pendingSamples.count,
                    lowWaterMark: Self.pendingSampleLowWaterMark,
                    backpressureStartedAt:
                        self.backpressureStartedAt,
                    detectionEnabledAt:
                        self.rendererStallDetectionEnabledAt,
                    lastCapacityProgressAt:
                        self.lastCapacityProgressUptime,
                    now: now,
                    threshold: 3
                )
                switch action {
                case .inactive:
                    self.backpressureWatchdog = nil
                    return
                case .wait(let seconds):
                    let nanoseconds = UInt64(
                        max(0.001, seconds) * 1_000_000_000
                    )
                    try? await Task.sleep(nanoseconds: nanoseconds)
                case .fail(let noProgressSeconds):
                    self.backpressureWatchdog = nil
                    self.asynchronousFailureHandler?(
                        .rendererStalled(
                            durationSeconds: noProgressSeconds,
                            queueDepth: self.pendingSamples.count
                        )
                    )
                    return
                }
            }
        }
    }

    private func clearBackpressureIfNeeded(force: Bool) {
        guard let startedAt = backpressureStartedAt,
              force || pendingSamples.count
                <= Self.pendingSampleLowWaterMark else {
            return
        }
        let duration = ProcessInfo.processInfo.systemUptime - startedAt
        let formattedDuration = String(format: "%.3f", duration)
        backpressureStartedAt = nil
        backpressureWatchdog?.cancel()
        backpressureWatchdog = nil
        EngineLog.emit(
            "[AetherHybridPresentationView] mailbox capacity resumed "
                + "generation=\(activeGeneration) "
                + "depth=\(pendingSamples.count) "
                + "duration=\(formattedDuration)",
            category: .session
        )
    }

    private func flushRenderer(removingDisplayedImage: Bool) {
        if #available(tvOS 17.0, iOS 17.0, macOS 14.0, *) {
            displayLayer.sampleBufferRenderer.flush(
                removingDisplayedImage: removingDisplayedImage,
                completionHandler: nil
            )
        } else if removingDisplayedImage {
            displayLayer.flushAndRemoveImage()
        } else {
            displayLayer.flush()
        }
    }

    private func validateTimebase(_ timebase: CMTimebase) throws {
        let time = CMTimebaseGetTime(timebase)
        let rate = CMTimebaseGetRate(timebase)
        guard time.isValid,
              time.isNumeric,
              rate.isFinite,
              rate >= 0 else {
            throw AetherHybridPresentationError
                .carrierTimebaseUnavailable
        }
    }

    private static func isSameTimebase(
        _ lhs: CMTimebase,
        _ rhs: CMTimebase
    ) -> Bool {
        Unmanaged.passUnretained(lhs).toOpaque()
            == Unmanaged.passUnretained(rhs).toOpaque()
    }

    private static func formatsAreCompatible(
        expected: VideoFormat,
        actual: VideoFormat
    ) -> Bool {
        if expected == actual { return true }
        return (expected == .hdr10 && actual == .hdr10Plus)
            || (expected == .hdr10Plus && actual == .hdr10)
    }

    private func validateGeometry(
        _ geometry: DecodedVideoFrameGeometry
    ) throws {
        guard geometry.codedWidth > 0,
              geometry.codedHeight > 0,
              geometry.cleanAperture.x.isFinite,
              geometry.cleanAperture.y.isFinite,
              geometry.cleanAperture.width.isFinite,
              geometry.cleanAperture.height.isFinite,
              geometry.cleanAperture.width > 0,
              geometry.cleanAperture.height > 0,
              geometry.cleanAperture.x >= 0,
              geometry.cleanAperture.y >= 0,
              geometry.cleanAperture.x
                + geometry.cleanAperture.width
                <= Double(geometry.codedWidth),
              geometry.cleanAperture.y
                + geometry.cleanAperture.height
                <= Double(geometry.codedHeight),
              geometry.pixelAspectRatioNumerator > 0,
              geometry.pixelAspectRatioDenominator > 0 else {
            throw AetherHybridPresentationError.invalidGeometry
        }
        guard [0, 90, 180, 270].contains(
            geometry.rotationDegrees
        ) else {
            throw AetherHybridPresentationError
                .unsupportedRotation(geometry.rotationDegrees)
        }
    }

    func makeSampleBuffer(
        _ frame: DecodedVideoFrame
    ) throws -> CMSampleBuffer {
        applyFormatDescriptionAttachments(to: frame.pixelBuffer, frame: frame)
        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame.pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr,
              let formatDescription else {
            throw AetherHybridPresentationError
                .formatDescriptionCreationFailed(
                    status: formatStatus
                )
        }
        var timing = CMSampleTimingInfo(
            duration: frame.duration,
            presentationTimeStamp: frame.presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame.pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr,
              let sampleBuffer else {
            throw AetherHybridPresentationError
                .sampleBufferCreationFailed(status: sampleStatus)
        }
        if let hdr10PlusT35 = frame.hdr10PlusT35 {
            try attachHDR10Plus(
                hdr10PlusT35,
                to: sampleBuffer
            )
        }
        return sampleBuffer
    }

    private func applyFormatDescriptionAttachments(
        to pixelBuffer: CVPixelBuffer,
        frame: DecodedVideoFrame
    ) {
        let geometry = frame.geometry
        let horizontalOffset = geometry.cleanAperture.x
            + geometry.cleanAperture.width / 2
            - Double(geometry.codedWidth) / 2
        let verticalOffset = geometry.cleanAperture.y
            + geometry.cleanAperture.height / 2
            - Double(geometry.codedHeight) / 2
        let cleanAperture = [
                kCVImageBufferCleanApertureWidthKey:
                    geometry.cleanAperture.width,
                kCVImageBufferCleanApertureHeightKey:
                    geometry.cleanAperture.height,
                kCVImageBufferCleanApertureHorizontalOffsetKey:
                    horizontalOffset,
                kCVImageBufferCleanApertureVerticalOffsetKey:
                    verticalOffset,
            ] as CFDictionary
        let pixelAspectRatio = [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey:
                    geometry.pixelAspectRatioNumerator,
                kCVImageBufferPixelAspectRatioVerticalSpacingKey:
                    geometry.pixelAspectRatioDenominator,
            ] as CFDictionary
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferCleanApertureKey,
            cleanAperture,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferPixelAspectRatioKey,
            pixelAspectRatio,
            .shouldPropagate
        )
        let color = frame.colorMetadata
        setAttachment(
            colorPrimaries(color.colorPrimaries),
            key: kCVImageBufferColorPrimariesKey,
            on: pixelBuffer
        )
        setAttachment(
            transferFunction(color.transferFunction),
            key: kCVImageBufferTransferFunctionKey,
            on: pixelBuffer
        )
        setAttachment(
            yCbCrMatrix(color.yCbCrMatrix),
            key: kCVImageBufferYCbCrMatrixKey,
            on: pixelBuffer
        )
        setAttachment(
            color.masteringDisplayColorVolume as CFData?,
            key: kCVImageBufferMasteringDisplayColorVolumeKey,
            on: pixelBuffer
        )
        setAttachment(
            color.contentLightLevelInfo as CFData?,
            key: kCVImageBufferContentLightLevelInfoKey,
            on: pixelBuffer
        )
        setAttachment(
            color.ambientViewingEnvironment as CFData?,
            key: kCVImageBufferAmbientViewingEnvironmentKey,
            on: pixelBuffer
        )
    }

    private func setAttachment(
        _ value: CFTypeRef?,
        key: CFString,
        on pixelBuffer: CVPixelBuffer
    ) {
        if let value {
            CVBufferSetAttachment(
                pixelBuffer,
                key,
                value,
                .shouldPropagate
            )
        } else {
            CVBufferRemoveAttachment(pixelBuffer, key)
        }
    }

    private func attachHDR10Plus(
        _ data: Data,
        to sampleBuffer: CMSampleBuffer
    ) throws {
        guard let attachments =
                CMSampleBufferGetSampleAttachmentsArray(
                    sampleBuffer,
                    createIfNecessary: true
                ),
              CFArrayGetCount(attachments) > 0,
              let rawDictionary =
                CFArrayGetValueAtIndex(attachments, 0) else {
            throw AetherHybridPresentationError
                .sampleAttachmentCreationFailed
        }
        let dictionary = unsafeBitCast(
            rawDictionary,
            to: CFMutableDictionary.self
        )
        let value = data as CFData
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(
                kCMSampleAttachmentKey_HDR10PlusPerFrameData
            ).toOpaque(),
            Unmanaged.passUnretained(value).toOpaque()
        )
    }

    private func colorPrimaries(
        _ value: DecodedVideoFrameColorMetadata.ColorPrimaries
    ) -> CFString? {
        switch value {
        case .ituR709:
            kCVImageBufferColorPrimaries_ITU_R_709_2
        case .ituR2020:
            kCVImageBufferColorPrimaries_ITU_R_2020
        case .p3D65:
            kCVImageBufferColorPrimaries_P3_D65
        case .unspecified, .unrecognized:
            nil
        }
    }

    private func transferFunction(
        _ value: DecodedVideoFrameColorMetadata.TransferFunction
    ) -> CFString? {
        switch value {
        case .ituR709:
            kCVImageBufferTransferFunction_ITU_R_709_2
        case .pq:
            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case .hlg:
            kCVImageBufferTransferFunction_ITU_R_2100_HLG
        case .unspecified, .unrecognized:
            nil
        }
    }

    private func yCbCrMatrix(
        _ value: DecodedVideoFrameColorMetadata.YCbCrMatrix
    ) -> CFString? {
        switch value {
        case .ituR709:
            kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case .ituR2020:
            kCVImageBufferYCbCrMatrix_ITU_R_2020
        case .unspecified, .unrecognized:
            nil
        }
    }

    private func applyLayerGeometry() {
        let rotation = CGFloat(sourceRotationDegrees ?? 0)
            * .pi / 180
        let rotated = sourceRotationDegrees == 90
            || sourceRotationDegrees == 270
        let layerSize = rotated
            ? CGSize(width: bounds.height, height: bounds.width)
            : bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.setAffineTransform(.identity)
        displayLayer.bounds = CGRect(origin: .zero, size: layerSize)
        displayLayer.position = CGPoint(
            x: bounds.midX,
            y: bounds.midY
        )
        displayLayer.setAffineTransform(
            CGAffineTransform(rotationAngle: rotation)
        )
        subtitleCanvas?.layout(
            in: bounds,
            videoRect: realVideoRect(in: bounds)
        )
        CATransaction.commit()
    }

    private func realVideoRect(in bounds: CGRect) -> CGRect {
        guard let geometry = lastAcceptedGeometry else {
            return bounds
        }
        var width = geometry.cleanAperture.width
            * Double(geometry.pixelAspectRatioNumerator)
            / Double(geometry.pixelAspectRatioDenominator)
        var height = geometry.cleanAperture.height
        if geometry.rotationDegrees == 90
            || geometry.rotationDegrees == 270 {
            swap(&width, &height)
        }
        guard width.isFinite,
              height.isFinite,
              width > 0,
              height > 0,
              !bounds.isEmpty else {
            return bounds
        }
        let horizontalScale = bounds.width / width
        let verticalScale = bounds.height / height
        let scale = switch videoGravity {
        case .resizeAspect:
            min(horizontalScale, verticalScale)
        case .resizeAspectFill:
            max(horizontalScale, verticalScale)
        }
        let size = CGSize(
            width: width * scale,
            height: height * scale
        )
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
