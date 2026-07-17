import CoreGraphics
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import QuartzCore
@preconcurrency import SwiftLibass

/// Why an Aether-owned subtitle track needs the Hybrid overlay instead of an
/// AVPlayer WebVTT rendition.
public enum AetherHybridOverlaySubtitleKind:
    String,
    Sendable,
    Equatable
{
    case bitmap
    case styledText
}

/// Track-local failure. A failure here disables only this subtitle track; it
/// never changes the playback route, video renderer, audio track, or clock.
public enum AetherHybridSubtitleUnavailableReason:
    String,
    Sendable,
    Equatable
{
    case decoderUnavailable
    case decodeFailed
    case rendererUnavailable
    case malformedStyledTrack
}

public enum AetherHybridOverlaySubtitleAvailability:
    Sendable,
    Equatable
{
    case available
    case unavailable(AetherHybridSubtitleUnavailableReason)
}

public enum AetherHybridSubtitleSelectionError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case unknownTrack(Int)
    case trackUnavailable(
        trackID: Int,
        reason: AetherHybridSubtitleUnavailableReason
    )

    public var errorDescription: String? {
        switch self {
        case .unknownTrack(let trackID):
            "Hybrid subtitle track \(trackID) is unknown"
        case .trackUnavailable(let trackID, let reason):
            "Hybrid subtitle track \(trackID) is unavailable: \(reason.rawValue)"
        }
    }
}

/// Privacy-safe public metadata for one bitmap/styled Hybrid subtitle track.
/// The stable ID is the source stream ID established by Aether preflight or
/// the graph-bound first-segment contract.
public struct AetherHybridOverlaySubtitleTrack:
    Identifiable,
    Sendable,
    Equatable
{
    public let id: Int
    public let name: String
    public let language: String?
    public let isDefault: Bool
    public let isForced: Bool
    public let kind: AetherHybridOverlaySubtitleKind
    public let availability:
        AetherHybridOverlaySubtitleAvailability

    public init(
        id: Int,
        name: String,
        language: String?,
        isDefault: Bool,
        isForced: Bool,
        kind: AetherHybridOverlaySubtitleKind,
        availability:
            AetherHybridOverlaySubtitleAvailability = .available
    ) {
        self.id = id
        self.name = name
        self.language = language
        self.isDefault = isDefault
        self.isForced = isForced
        self.kind = kind
        self.availability = availability
    }
}

struct HybridStyledSubtitleFrame {
    let image: CGImage
    let frame: CGRect
}

enum HybridStyledSubtitleRendererError:
    Error,
    Sendable,
    Equatable
{
    case libraryInitializationFailed
    case rendererInitializationFailed
    case invalidCanvasSize
    case trackParseFailed
    case imageBlendFailed
}

/// Minimal libass owner for the Aether Hybrid overlay.
///
/// This deliberately does not depend on `swift-ass-renderer`: Aether exact
/// pins the audited C wrapper and owns lifecycle, clock sampling, blending,
/// and error policy itself. All calls are MainActor-confined because the
/// overlay is driven from the carrier AVPlayer time observer.
@MainActor
final class HybridStyledSubtitleRenderer {
    nonisolated(unsafe) private var library: OpaquePointer?
    nonisolated(unsafe) private var renderer: OpaquePointer?
    nonisolated(unsafe) private var track:
        UnsafeMutablePointer<ASS_Track>?
    private var canvasSize: CGSize = .zero

    init() throws {
        guard let library = ass_library_init() else {
            throw HybridStyledSubtitleRendererError
                .libraryInitializationFailed
        }
        self.library = library
        // libass's default callback prints font paths and free-form subtitle
        // diagnostics. Hybrid exposes only typed, privacy-safe track state, so
        // the embedded renderer must not inherit that process-wide console
        // behavior.
        ass_set_message_cb(
            library,
            { _, _, _, _ in },
            nil
        )
        guard let renderer = ass_renderer_init(library) else {
            ass_library_done(library)
            self.library = nil
            throw HybridStyledSubtitleRendererError
                .rendererInitializationFailed
        }
        self.renderer = renderer
        ass_set_extract_fonts(library, 1)
        // CoreText avoids a writable fontconfig cache and resolves installed
        // Apple platform fonts through the public libass provider contract.
        ass_set_fonts(
            renderer,
            nil,
            "sans-serif",
            Int32(ASS_FONTPROVIDER_CORETEXT.rawValue),
            nil,
            1
        )
    }

    deinit {
        if let track {
            ass_free_track(track)
        }
        if let renderer {
            ass_renderer_done(renderer)
        }
        if let library {
            ass_library_done(library)
        }
    }

    func setCanvasSize(_ size: CGSize) throws {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0,
              size.width <= Double(Int32.max),
              size.height <= Double(Int32.max),
              let renderer else {
            throw HybridStyledSubtitleRendererError.invalidCanvasSize
        }
        guard canvasSize != size else { return }
        canvasSize = size
        ass_set_frame_size(
            renderer,
            Int32(size.width.rounded()),
            Int32(size.height.rounded())
        )
        ass_set_storage_size(
            renderer,
            Int32(size.width.rounded()),
            Int32(size.height.rounded())
        )
    }

    func load(script: String) throws {
        guard let library else {
            throw HybridStyledSubtitleRendererError
                .libraryInitializationFailed
        }
        if let track {
            ass_free_track(track)
            self.track = nil
        }
        var utf8 = script.utf8CString
        guard utf8.count > 1 else {
            throw HybridStyledSubtitleRendererError.trackParseFailed
        }
        let loaded = utf8.withUnsafeMutableBufferPointer {
            buffer in
            ass_read_memory(
                library,
                buffer.baseAddress,
                buffer.count - 1,
                nil
            )
        }
        guard let loaded else {
            throw HybridStyledSubtitleRendererError.trackParseFailed
        }
        track = loaded
    }

    func frame(at sourceTimeSeconds: Double) throws
        -> HybridStyledSubtitleFrame?
    {
        guard sourceTimeSeconds.isFinite,
              sourceTimeSeconds >= 0,
              canvasSize.width > 0,
              canvasSize.height > 0,
              let renderer,
              let track else {
            return nil
        }
        var changed: Int32 = 0
        let milliseconds = Int64(
            (sourceTimeSeconds * 1_000).rounded()
        )
        guard let first = ass_render_frame(
            renderer,
            track,
            milliseconds,
            &changed
        ) else {
            return nil
        }
        return try Self.blend(first: first)
    }

    private static func blend(
        first: UnsafeMutablePointer<ASS_Image>
    ) throws -> HybridStyledSubtitleFrame {
        var images: [ASS_Image] = []
        var current: UnsafeMutablePointer<ASS_Image>? = first
        while let pointer = current {
            let image = pointer.pointee
            if image.w > 0, image.h > 0, image.bitmap != nil {
                images.append(image)
            }
            current = image.next
        }
        guard let minX = images.map({ Int($0.dst_x) }).min(),
              let minY = images.map({ Int($0.dst_y) }).min(),
              let maxX = images.map({ Int($0.dst_x + $0.w) }).max(),
              let maxY = images.map({ Int($0.dst_y + $0.h) }).max(),
              maxX > minX,
              maxY > minY else {
            throw HybridStyledSubtitleRendererError.imageBlendFailed
        }
        let width = maxX - minX
        let height = maxY - minY
        guard width <= 16_384,
              height <= 16_384,
              width <= Int.max / max(1, height) / 4 else {
            throw HybridStyledSubtitleRendererError.imageBlendFailed
        }
        var pixels = [UInt8](
            repeating: 0,
            count: width * height * 4
        )
        for image in images {
            let colorAlpha = 255 - Int(image.color & 0xFF)
            guard colorAlpha > 0,
                  let bitmap = image.bitmap else { continue }
            let red = Int((image.color >> 24) & 0xFF)
            let green = Int((image.color >> 16) & 0xFF)
            let blue = Int((image.color >> 8) & 0xFF)
            let imageWidth = Int(image.w)
            let imageHeight = Int(image.h)
            let stride = max(imageWidth, Int(image.stride))
            let relativeX = Int(image.dst_x) - minX
            let relativeY = Int(image.dst_y) - minY
            for y in 0..<imageHeight {
                for x in 0..<imageWidth {
                    let mask = Int(bitmap[y * stride + x])
                    let sourceAlpha = mask * colorAlpha / 255
                    guard sourceAlpha > 0 else { continue }
                    let destination = (
                        (relativeY + y) * width
                        + relativeX + x
                    ) * 4
                    let inverseAlpha = 255 - sourceAlpha
                    let destinationAlpha = Int(pixels[destination + 3])
                    pixels[destination] = UInt8(clamping:
                        (red * sourceAlpha
                         + Int(pixels[destination]) * inverseAlpha) / 255
                    )
                    pixels[destination + 1] = UInt8(clamping:
                        (green * sourceAlpha
                         + Int(pixels[destination + 1]) * inverseAlpha) / 255
                    )
                    pixels[destination + 2] = UInt8(clamping:
                        (blue * sourceAlpha
                         + Int(pixels[destination + 2]) * inverseAlpha) / 255
                    )
                    pixels[destination + 3] = UInt8(clamping:
                        sourceAlpha
                        + destinationAlpha * inverseAlpha / 255
                    )
                }
            }
        }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue:
                        CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            throw HybridStyledSubtitleRendererError.imageBlendFailed
        }
        return HybridStyledSubtitleFrame(
            image: image,
            frame: CGRect(
                x: minX,
                y: minY,
                width: width,
                height: height
            )
        )
    }
}

@MainActor
final class HybridSubtitleOverlayCanvas {
    private let rootLayer = CALayer()
    private let styledLayer = CALayer()
    private var bitmapLayers: [CALayer] = []
    private(set) var styledSubtitleVisible = false
    private(set) var visibleBitmapSubtitleCount = 0

    init(parent: CALayer) {
        rootLayer.masksToBounds = true
        #if canImport(AppKit) && !canImport(UIKit)
        rootLayer.isGeometryFlipped = true
        #endif
        styledLayer.contentsGravity = .resize
        rootLayer.addSublayer(styledLayer)
        parent.addSublayer(rootLayer)
    }

    func layout(
        in bounds: CGRect,
        videoRect: CGRect
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.frame = videoRect
        CATransaction.commit()
    }

    var canvasSize: CGSize { rootLayer.bounds.size }

    func showStyled(_ frame: HybridStyledSubtitleFrame?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        styledLayer.contents = frame?.image
        styledLayer.frame = frame?.frame ?? .zero
        styledLayer.isHidden = frame == nil
        styledSubtitleVisible = frame != nil
        visibleBitmapSubtitleCount = 0
        clearBitmapLayers()
        CATransaction.commit()
    }

    func showBitmaps(_ images: [SubtitleImage]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        styledLayer.contents = nil
        styledLayer.isHidden = true
        styledSubtitleVisible = false
        visibleBitmapSubtitleCount = images.count
        while bitmapLayers.count < images.count {
            let layer = CALayer()
            layer.contentsGravity = .resize
            rootLayer.addSublayer(layer)
            bitmapLayers.append(layer)
        }
        for (index, layer) in bitmapLayers.enumerated() {
            guard images.indices.contains(index) else {
                layer.contents = nil
                layer.isHidden = true
                continue
            }
            let subtitle = images[index]
            layer.contents = subtitle.cgImage
            layer.frame = bitmapFrame(
                subtitle,
                canvas: rootLayer.bounds
            )
            layer.isHidden = false
        }
        CATransaction.commit()
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        styledLayer.contents = nil
        styledLayer.isHidden = true
        styledSubtitleVisible = false
        visibleBitmapSubtitleCount = 0
        clearBitmapLayers()
        CATransaction.commit()
    }

    private func clearBitmapLayers() {
        for layer in bitmapLayers {
            layer.contents = nil
            layer.isHidden = true
        }
    }

    private func bitmapFrame(
        _ image: SubtitleImage,
        canvas: CGRect
    ) -> CGRect {
        let sourceCanvas = image.canvasSize.width <= 0
            || image.canvasSize.height <= 0
            ? canvas.size
            : image.canvasSize
        guard sourceCanvas.width > 0,
              sourceCanvas.height > 0 else { return .zero }
        // Disc bitmap canvases are authored against coded video. Width-align
        // and center vertically so cropped sources retain authored placement.
        let scale = canvas.width / sourceCanvas.width
        let mappedHeight = sourceCanvas.height * scale
        let verticalOrigin = (canvas.height - mappedHeight) / 2
        let x = image.position.minX
            * sourceCanvas.width * scale
        let y = verticalOrigin
            + image.position.minY
            * sourceCanvas.height * scale
        let width = image.position.width
            * sourceCanvas.width * scale
        let height = image.position.height
            * sourceCanvas.height * scale
        return CGRect(
            x: x,
            y: y,
            width: width,
            height: height
        ).integral
    }
}

final class HybridSubtitleDecodeContract: @unchecked Sendable {
    let track: AetherHybridOverlaySubtitleTrack
    let assHeader: String?
    let packetStreamID: Int32
    let assembleSplitDisplaySets: Bool

    private var codecParameters:
        UnsafeMutablePointer<AVCodecParameters>?
    private let sourceVideoWidth: Int32
    private let sourceVideoHeight: Int32

    init?(
        trackID: Int,
        packetStreamID: Int32,
        info: TrackInfo,
        stream: UnsafeMutablePointer<AVStream>,
        sourceVideoWidth: Int32,
        sourceVideoHeight: Int32,
        assembleSplitDisplaySets: Bool
    ) {
        guard let source = stream.pointee.codecpar,
              source.pointee.codec_type
                == AVMEDIA_TYPE_SUBTITLE else {
            return nil
        }
        let kind: AetherHybridOverlaySubtitleKind
        if EmbeddedSubtitleDecoder.isBitmapCodec(
            source.pointee.codec_id
        ) {
            kind = .bitmap
        } else if source.pointee.codec_id == AV_CODEC_ID_ASS
                    || source.pointee.codec_id == AV_CODEC_ID_SSA {
            kind = .styledText
        } else {
            return nil
        }
        guard let copy = avcodec_parameters_alloc(),
              avcodec_parameters_copy(copy, source) >= 0 else {
            return nil
        }
        codecParameters = copy
        self.track = AetherHybridOverlaySubtitleTrack(
            id: trackID,
            name: info.name,
            language: info.language,
            isDefault: info.isDefault,
            isForced: info.isForced,
            kind: kind
        )
        assHeader = info.assHeader
        self.packetStreamID = packetStreamID
        self.sourceVideoWidth = max(1, sourceVideoWidth)
        self.sourceVideoHeight = max(1, sourceVideoHeight)
        self.assembleSplitDisplaySets = assembleSplitDisplaySets
    }

    deinit {
        avcodec_parameters_free(&codecParameters)
    }

    func makeDecoder() -> EmbeddedSubtitleDecoder? {
        guard let codecParameters else { return nil }
        return EmbeddedSubtitleDecoder(
            codecParameters: codecParameters,
            sourceVideoWidth: sourceVideoWidth,
            sourceVideoHeight: sourceVideoHeight,
            preserveASSMarkup: track.kind == .styledText
        )
    }
}

protocol HybridOverlaySubtitleSource: AnyObject {
    var hybridSubtitleContracts:
        [HybridSubtitleDecodeContract] { get }
    var hybridSubtitlePacketStore: SubtitlePacketStore { get }
    var hybridSubtitleRuntimeAvailability:
        HybridSubtitleRuntimeAvailabilityStore { get }
}

final class HybridSubtitleRuntimeAvailabilityStore:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var reasons:
        [Int: AetherHybridSubtitleUnavailableReason] = [:]

    func markUnavailable(
        trackID: Int,
        reason: AetherHybridSubtitleUnavailableReason
    ) {
        lock.lock()
        reasons[trackID] = reason
        lock.unlock()
    }

    func reason(for trackID: Int)
        -> AetherHybridSubtitleUnavailableReason?
    {
        lock.lock()
        defer { lock.unlock() }
        return reasons[trackID]
    }
}

@MainActor
final class HybridSubtitleSessionController {
    private static let drainLeadSeconds = 60.0
    private static let drainBackscanSeconds = 15.0
    private static let jumpThresholdSeconds = 2.5

    private let source: any HybridOverlaySubtitleSource
    private unowned let presentationView:
        AetherHybridPresentationView
    private var contractsByID:
        [Int: HybridSubtitleDecodeContract]
    private var selectedContract:
        HybridSubtitleDecodeContract?
    private var decoder: EmbeddedSubtitleDecoder?
    private var cursor: SubtitleDrainCursor?
    private var cues: [SubtitleCue] = []
    private var assBuilder: ASSScriptBuilder?
    private var assRenderer:
        HybridStyledSubtitleRenderer?
    private var styledScriptDirty = false
    private var pgsGate = PGSStaleArrivalGate()
    private var currentPlayheadSeconds = 0.0

    var tracksDidChange:
        (@MainActor ([AetherHybridOverlaySubtitleTrack], Int?) -> Void)?

    private(set) var tracks:
        [AetherHybridOverlaySubtitleTrack]
    private(set) var selectedTrackID: Int?

    init(
        source: any HybridOverlaySubtitleSource,
        presentationView: AetherHybridPresentationView
    ) {
        self.source = source
        self.presentationView = presentationView
        contractsByID = Dictionary(
            uniqueKeysWithValues:
                source.hybridSubtitleContracts.map {
                    ($0.track.id, $0)
                }
        )
        tracks = source.hybridSubtitleContracts.map(\.track)
    }

    func select(trackID: Int?) throws {
        presentationView.clearSubtitleOverlay()
        if let trackID {
            guard let contract = contractsByID[trackID] else {
                throw AetherHybridSubtitleSelectionError
                    .unknownTrack(trackID)
            }
            if let track = tracks.first(where: { $0.id == trackID }),
               case .unavailable(let reason) = track.availability {
                throw AetherHybridSubtitleSelectionError
                    .trackUnavailable(
                        trackID: trackID,
                        reason: reason
                    )
            }
            selectedContract = contract
        } else {
            selectedContract = nil
        }
        selectedTrackID = trackID
        decoder = nil
        cursor = nil
        cues.removeAll(keepingCapacity: true)
        assBuilder = nil
        assRenderer = nil
        styledScriptDirty = false
        pgsGate.reset()
        guard let contract = selectedContract else {
            publish()
            return
        }
        guard let decoder = contract.makeDecoder() else {
            disableSelected(.decoderUnavailable)
            return
        }
        self.decoder = decoder
        if contract.track.kind == .styledText {
            guard let header = contract.assHeader,
                  !header.isEmpty else {
                disableSelected(.malformedStyledTrack)
                return
            }
            assBuilder = ASSScriptBuilder(header: header)
            do {
                assRenderer = try HybridStyledSubtitleRenderer()
            } catch {
                disableSelected(.rendererUnavailable)
                return
            }
        }
        publish()
    }

    func resetForGeneration() {
        presentationView.clearSubtitleOverlay()
        cursor = nil
        cues.removeAll(keepingCapacity: true)
        guard let selectedTrackID else { return }
        do {
            try select(trackID: selectedTrackID)
        } catch {
            disableSelected(.decoderUnavailable)
        }
    }

    func update(playheadSeconds: Double) {
        refreshRuntimeAvailability()
        guard playheadSeconds.isFinite,
              playheadSeconds >= 0,
              let contract = selectedContract,
              decoder != nil else {
            presentationView.clearSubtitleOverlay()
            return
        }
        currentPlayheadSeconds = playheadSeconds
        let plan = SubtitleOverlayDrainer.drainPlan(
            cursor: cursor,
            playhead: playheadSeconds,
            lead: Self.drainLeadSeconds,
            backscan: Self.drainBackscanSeconds,
            jumpThreshold: Self.jumpThresholdSeconds
        )
        let window: (Double, Double)?
        switch plan {
        case .idle:
            cursor?.lastPlayhead = playheadSeconds
            window = nil
        case .decode(let from, let through):
            window = (from, through)
        case .resetAndDecode(let from, let through):
            guard let fresh = contract.makeDecoder() else {
                disableSelected(.decoderUnavailable)
                return
            }
            self.decoder = fresh
            cues.removeAll(keepingCapacity: true)
            pgsGate.reset()
            assBuilder = contract.track.kind == .styledText
                ? contract.assHeader.map(ASSScriptBuilder.init)
                : nil
            styledScriptDirty = contract.track.kind == .styledText
            window = (from, through)
        }
        if let window,
           let currentDecoder = self.decoder {
            let entries = source.hybridSubtitlePacketStore.entries(
                streamIndex: contract.packetStreamID,
                from: window.0,
                through: window.1
            )
            var lastDecoded = cursor?.lastDecodedPts
            for entry in entries {
                if let event = Self.decode(
                    entry,
                    with: currentDecoder
                ) {
                    apply(event)
                } else if currentDecoder.lastDecodeErrorCode != nil {
                    disableSelected(.decodeFailed)
                    return
                }
                lastDecoded = entry.ptsSeconds
            }
            cursor = SubtitleDrainCursor(
                lastDecodedPts:
                    lastDecoded ?? window.0,
                lastPlayhead: playheadSeconds
            )
        }
        render(at: playheadSeconds)
    }

    func stop() {
        selectedTrackID = nil
        selectedContract = nil
        decoder = nil
        cursor = nil
        cues.removeAll()
        assBuilder = nil
        assRenderer = nil
        pgsGate.reset()
        presentationView.clearSubtitleOverlay()
        publish()
    }

    private func apply(
        _ event: EmbeddedSubtitleDecoder.SubtitleEvent
    ) {
        if let trimAt = event.pgsTrimAt {
            for index in cues.indices {
                guard case .image = cues[index].body,
                      cues[index].startTime < trimAt,
                      cues[index].endTime > trimAt else {
                    continue
                }
                let cue = cues[index]
                cues[index] = SubtitleCue(
                    id: cue.id,
                    startTime: cue.startTime,
                    endTime: trimAt,
                    body: cue.body
                )
            }
            for cue in pgsGate.resolveHeld(
                trimAt: trimAt,
                playhead: currentPlayheadSeconds
            ) {
                cues.append(cue)
            }
        }
        let admitted = pgsGate.admit(
            cues: event.cues,
            isPGS: event.isPGS,
            isSelfContained: event.isSelfContainedPGS,
            playhead: currentPlayheadSeconds
        )
        for cue in admitted {
            if case .text(let raw) = cue.body,
               let assBuilder,
               assBuilder.add(
                rawEventText: raw,
                start: cue.startTime,
                end: cue.endTime
               ) {
                styledScriptDirty = true
            }
            if !cues.contains(where: {
                $0.startTime == cue.startTime
                    && $0.endTime == cue.endTime
                    && $0.body.kindKey == cue.body.kindKey
            }) {
                cues.append(cue)
            }
        }
        cues.sort {
            ($0.startTime, $0.id) < ($1.startTime, $1.id)
        }
    }

    private func render(at playhead: Double) {
        guard let contract = selectedContract else {
            presentationView.clearSubtitleOverlay()
            return
        }
        switch contract.track.kind {
        case .bitmap:
            let images = cues.compactMap { cue -> SubtitleImage? in
                guard cue.startTime <= playhead,
                      playhead < cue.endTime,
                      case .image(let image) = cue.body else {
                    return nil
                }
                return image
            }
            presentationView.showBitmapSubtitles(images)
        case .styledText:
            guard let assBuilder,
                  let assRenderer else {
                disableSelected(.rendererUnavailable)
                return
            }
            do {
                try assRenderer.setCanvasSize(
                    presentationView.subtitleCanvasSize
                )
                if styledScriptDirty {
                    try assRenderer.load(
                        script: assBuilder.script()
                    )
                    styledScriptDirty = false
                }
                presentationView.showStyledSubtitle(
                    try assRenderer.frame(at: playhead)
                )
            } catch {
                disableSelected(.rendererUnavailable)
            }
        }
    }

    private func disableSelected(
        _ reason: AetherHybridSubtitleUnavailableReason
    ) {
        guard let selectedTrackID,
              let contract = contractsByID[selectedTrackID],
              let index = tracks.firstIndex(where: {
                $0.id == selectedTrackID
              }) else {
            return
        }
        tracks[index] = AetherHybridOverlaySubtitleTrack(
            id: contract.track.id,
            name: contract.track.name,
            language: contract.track.language,
            isDefault: contract.track.isDefault,
            isForced: contract.track.isForced,
            kind: contract.track.kind,
            availability: .unavailable(reason)
        )
        self.selectedTrackID = nil
        selectedContract = nil
        decoder = nil
        assBuilder = nil
        assRenderer = nil
        presentationView.clearSubtitleOverlay()
        publish()
    }

    private func publish() {
        tracksDidChange?(tracks, selectedTrackID)
    }

    private func refreshRuntimeAvailability() {
        var changed = false
        for index in tracks.indices {
            let track = tracks[index]
            guard case .available = track.availability,
                  let reason = source
                    .hybridSubtitleRuntimeAvailability
                    .reason(for: track.id) else {
                continue
            }
            tracks[index] = AetherHybridOverlaySubtitleTrack(
                id: track.id,
                name: track.name,
                language: track.language,
                isDefault: track.isDefault,
                isForced: track.isForced,
                kind: track.kind,
                availability: .unavailable(reason)
            )
            changed = true
            if selectedTrackID == track.id {
                selectedTrackID = nil
                selectedContract = nil
                decoder = nil
                assBuilder = nil
                assRenderer = nil
                presentationView.clearSubtitleOverlay()
            }
        }
        if changed { publish() }
    }

    private static func decode(
        _ entry: StoredSubtitlePacket,
        with decoder: EmbeddedSubtitleDecoder
    ) -> EmbeddedSubtitleDecoder.SubtitleEvent? {
        guard !entry.payload.isEmpty,
              let packet = av_packet_alloc() else {
            return nil
        }
        defer {
            var packet: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&packet)
        }
        guard av_new_packet(
            packet,
            Int32(entry.payload.count)
        ) >= 0 else { return nil }
        entry.payload.withUnsafeBytes { raw in
            guard let source = raw.baseAddress,
                  let destination = packet.pointee.data else {
                return
            }
            memcpy(
                destination,
                source,
                entry.payload.count
            )
        }
        packet.pointee.pts = Int64(
            (entry.ptsSeconds * 1_000).rounded()
        )
        packet.pointee.dts = packet.pointee.pts
        packet.pointee.duration = Int64(
            (entry.durationSeconds * 1_000).rounded()
        )
        packet.pointee.flags = entry.flags
        return decoder.decode(
            packet: packet,
            streamTimeBase: AVRational(num: 1, den: 1_000)
        )
    }
}

private extension SubtitleCue.Body {
    var kindKey: String {
        switch self {
        case .text(let value):
            "text:\(value)"
        case .image(let image):
            "image:\(image.cgImage.width)x\(image.cgImage.height):\(image.position)"
        }
    }
}
