import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import Metal
import MetalKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Engine-owned Metal render surface for `.hybridCarrierMetal`.
///
/// Syncnext places this view over `AVPlayerViewController.contentOverlayView`; it never creates an MTLDevice,
/// shader, frame queue, timing policy or color policy. The host drives `advanceMasterClock(to:)` from the
/// carrier AVPlayer's clock, which is the only master clock for hybrid presentation.
///
/// The initial renderer has a verified SDR/BT.709 path only. It rejects HDR10, HDR10+, HLG and Dolby Vision
/// frames rather than applying an implicit tone-map. `HybridPlaybackCapabilities` must therefore advertise
/// only `.sdr` until the corresponding color and display-criteria paths have device evidence.
@MainActor
public final class AetherMetalPlayerView: PlatformBaseView {
    public struct Diagnostics: Sendable, Equatable {
        public let generation: UInt64
        public let queuedFrames: Int
        public let staleGenerationDrops: Int
        public let queuePressureDrops: Int
        public let timelineDrops: Int
        public let lastPresentedTimeSeconds: Double?

        init(
            generation: UInt64,
            queuedFrames: Int,
            staleGenerationDrops: Int,
            queuePressureDrops: Int,
            timelineDrops: Int,
            lastPresentedTimeSeconds: Double?
        ) {
            self.generation = generation
            self.queuedFrames = queuedFrames
            self.staleGenerationDrops = staleGenerationDrops
            self.queuePressureDrops = queuePressureDrops
            self.timelineDrops = timelineDrops
            self.lastPresentedTimeSeconds = lastPresentedTimeSeconds
        }
    }

    /// This is deliberately the only color format currently advertised by the production renderer.
    /// Adding another format requires an end-to-end Metal/display-criteria device acceptance test first.
    public nonisolated static let verifiedVideoFormats: Set<VideoFormat> = [.sdr]

    public let metalView: MTKView
    private let renderer: AetherMetalFrameRenderer
    private var scheduler = HybridFrameScheduler()
    private var activeVideoFormat: VideoFormat = .sdr
    private var lastPresentedTime: CMTime?

    /// Scaling policy for the real decoded video. The fixed carrier canvas never participates in geometry.
    public var videoGravity: AetherHybridVideoGravity = .resizeAspect {
        didSet {
            renderer.videoGravity = videoGravity
            requestDraw()
        }
    }

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw AetherMetalRendererError.metalDeviceUnavailable }
        self.renderer = try AetherMetalFrameRenderer(device: device)
        self.metalView = MTKView(frame: .zero, device: device)
        #if canImport(UIKit)
        super.init(frame: .zero)
        #elseif canImport(AppKit)
        super.init(frame: .zero)
        #endif
        configureView()
    }

    public required init?(coder: NSCoder) {
        return nil
    }

    private func configureView() {
        #if canImport(UIKit)
        backgroundColor = .black
        isUserInteractionEnabled = false
        #elseif canImport(AppKit)
        wantsLayer = true
        layer?.backgroundColor = CGColor.black
        #endif

        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.enableSetNeedsDisplay = true
        metalView.isPaused = true
        metalView.framebufferOnly = false
        metalView.colorPixelFormat = .bgra8Unorm_srgb
        metalView.clearColor = MTLClearColorMake(0, 0, 0, 1)
        metalView.delegate = renderer
        addSubview(metalView)
        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Starts a new carrier/decoder generation and flushes every frame from the previous one.
    public func beginGeneration(_ generation: UInt64, videoFormat: VideoFormat) throws {
        guard Self.verifiedVideoFormats.contains(videoFormat) else {
            throw AetherMetalRendererError.unsupportedVideoFormat(videoFormat)
        }
        activeVideoFormat = videoFormat
        scheduler.beginGeneration(generation)
        lastPresentedTime = nil
        renderer.frame = nil
        requestDraw()
    }

    /// Queue a decoded frame. A stale-generation outcome is expected during seek/reload races and is exposed
    /// to diagnostics; it is never allowed to reach the drawable.
    @discardableResult
    public func enqueue(_ frame: DecodedVideoFrame) throws -> HybridFrameEnqueueOutcome {
        guard frame.presentationTime.isValid, frame.presentationTime.isNumeric else {
            throw AetherMetalRendererError.invalidPresentationTime
        }
        guard frame.videoFormat == activeVideoFormat,
              Self.verifiedVideoFormats.contains(frame.videoFormat) else {
            throw AetherMetalRendererError.unsupportedVideoFormat(frame.videoFormat)
        }
        try HybridVideoPresentationLayout.validate(
            geometry: frame.geometry
        )
        return scheduler.enqueue(frame)
    }

    /// Advance the renderer from carrier AVPlayer time. This method has no decoder or wall-clock fallback.
    public func advanceMasterClock(to time: CMTime, tolerance: CMTime = CMTime(value: 1, timescale: 120)) {
        guard let selected = scheduler.selectFrame(for: time, tolerance: tolerance) else { return }
        renderer.frame = selected
        lastPresentedTime = selected.presentationTime
        requestDraw()
    }

    /// Flushes queued and displayed frames. The caller must begin a new generation before accepting frames.
    public func flush() {
        scheduler.flush()
        renderer.frame = nil
        lastPresentedTime = nil
        requestDraw()
    }

    public var diagnostics: Diagnostics {
        Diagnostics(
            generation: scheduler.generation,
            queuedFrames: scheduler.queuedFrames.count,
            staleGenerationDrops: scheduler.staleGenerationDrops,
            queuePressureDrops: scheduler.queuePressureDrops,
            timelineDrops: scheduler.timelineDrops,
            lastPresentedTimeSeconds: lastPresentedTime?.seconds
        )
    }

    private func requestDraw() {
        #if canImport(UIKit)
        metalView.setNeedsDisplay()
        #elseif canImport(AppKit)
        metalView.setNeedsDisplay(metalView.bounds)
        #endif
    }
}

@MainActor
private final class AetherMetalFrameRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext
    var frame: DecodedVideoFrame?
    var videoGravity: AetherHybridVideoGravity = .resizeAspect

    init(device: MTLDevice) throws {
        guard let queue = device.makeCommandQueue() else {
            throw AetherMetalRendererError.metalDeviceUnavailable
        }
        commandQueue = queue
        ciContext = CIContext(
            mtlDevice: device,
            options: [CIContextOption.workingColorSpace: CGColorSpace(name: CGColorSpace.itur_709)!]
        )
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let frame,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        // Clear letterbox/pillarbox around the real video before Core Image writes the fitted image.
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
            encoder.endEncoding()
        }

        let source = CIImage(cvPixelBuffer: frame.pixelBuffer)
        let layout: HybridVideoPresentationLayout
        do {
            guard let resolved = try HybridVideoPresentationLayout(
                geometry: frame.geometry,
                drawableSize: view.drawableSize,
                gravity: videoGravity
            ) else {
                commandBuffer.present(drawable)
                commandBuffer.commit()
                return
            }
            layout = resolved
        } catch {
            // `enqueue` validates the immutable frame first. Reaching this branch is an engine invariant
            // violation, not permission to redraw with guessed geometry.
            assertionFailure(
                "Validated hybrid frame geometry became invalid: \(error)"
            )
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }
        let transformed = source
            .cropped(to: layout.sourceCrop)
            .transformed(by: CGAffineTransform(
                translationX: -layout.sourceCrop.minX,
                y: -layout.sourceCrop.minY
            ))
            .transformed(by: CGAffineTransform(
                scaleX: layout.pixelAspectRatio,
                y: 1
            ))
            .transformed(by: layout.rotationTransform)
            .transformed(by: CGAffineTransform(
                scaleX: layout.uniformScale,
                y: layout.uniformScale
            ))
            .transformed(by: CGAffineTransform(
                translationX: layout.targetRect.minX,
                y: layout.targetRect.minY
            ))
        ciContext.render(
            transformed,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: CGRect(
                origin: .zero,
                size: view.drawableSize
            ),
            colorSpace: CGColorSpace(name: CGColorSpace.itur_709)!
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
