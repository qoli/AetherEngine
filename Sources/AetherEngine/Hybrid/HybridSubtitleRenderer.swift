import CoreGraphics
import CoreMedia
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import QuartzCore
@preconcurrency import SwiftLibass

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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
    private let nativeWebVTTRenderer:
        HybridNativeWebVTTOverlayRenderer
    private var bitmapLayers: [CALayer] = []
    private(set) var styledSubtitleVisible = false
    private(set) var visibleBitmapSubtitleCount = 0

    var nativeWebVTTVisible: Bool {
        nativeWebVTTRenderer.visibleCueCount > 0
    }

    var visibleNativeWebVTTCueCount: Int {
        nativeWebVTTRenderer.visibleCueCount
    }

    init(parent: CALayer) {
        rootLayer.masksToBounds = true
        #if canImport(AppKit) && !canImport(UIKit)
        rootLayer.isGeometryFlipped = true
        #endif
        styledLayer.contentsGravity = .resize
        rootLayer.addSublayer(styledLayer)
        nativeWebVTTRenderer =
            HybridNativeWebVTTOverlayRenderer(
                parent: rootLayer
            )
        parent.addSublayer(rootLayer)
    }

    func layout(
        in bounds: CGRect,
        videoRect: CGRect
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.frame = videoRect
        nativeWebVTTRenderer.layout(
            in: rootLayer.bounds
        )
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
        nativeWebVTTRenderer.clear()
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
        nativeWebVTTRenderer.clear()
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

    func showNativeWebVTT(
        _ attributedStrings: [NSAttributedString]
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        styledLayer.contents = nil
        styledLayer.isHidden = true
        styledSubtitleVisible = false
        visibleBitmapSubtitleCount = 0
        clearBitmapLayers()
        nativeWebVTTRenderer.show(attributedStrings)
        CATransaction.commit()
    }

    func clearNativeWebVTT() {
        nativeWebVTTRenderer.clear()
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        styledLayer.contents = nil
        styledLayer.isHidden = true
        styledSubtitleVisible = false
        visibleBitmapSubtitleCount = 0
        nativeWebVTTRenderer.clear()
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

/// Draws the common-format attributed strings emitted by
/// `AVPlayerItemLegibleOutput` above Aether's real-video display layer.
///
/// AVFoundation's common format uses the public CoreMedia text-markup keys,
/// not UIKit/AppKit drawing keys. This renderer translates those keys while
/// retaining the source cue geometry and the user's Media Accessibility
/// styling that `AVPlayerItemLegibleOutput.TextStylingResolution.default`
/// has already resolved. It never parses or independently clocks WebVTT.
@MainActor
private final class HybridNativeWebVTTOverlayRenderer {
    private struct CueLayout {
        let attributedText: NSAttributedString
        let containerColor: CGColor?
        let positionPercent: CGFloat
        let linePercent: CGFloat
        let maximumWidthPercent: CGFloat
        let alignment: CATextLayerAlignmentMode
        let edgeStyle: String?
    }

    private final class CueLayer {
        let container = CALayer()
        let text = CATextLayer()

        init(parent: CALayer, contentsScale: CGFloat) {
            container.masksToBounds = false
            text.contentsScale = contentsScale
            text.isWrapped = true
            text.truncationMode = .none
            container.addSublayer(text)
            parent.addSublayer(container)
        }

        func remove() {
            container.removeFromSuperlayer()
        }
    }

    private let rootLayer = CALayer()
    private var cueLayers: [CueLayer] = []
    private var cues: [NSAttributedString] = []
    private(set) var visibleCueCount = 0

    init(parent: CALayer) {
        rootLayer.masksToBounds = true
        parent.addSublayer(rootLayer)
    }

    func layout(in bounds: CGRect) {
        rootLayer.frame = bounds
        render()
    }

    func show(_ attributedStrings: [NSAttributedString]) {
        cues = attributedStrings.filter {
            !$0.string.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        }
        render()
    }

    func clear() {
        cues.removeAll(keepingCapacity: true)
        visibleCueCount = 0
        for cueLayer in cueLayers {
            cueLayer.container.isHidden = true
            cueLayer.text.string = nil
        }
    }

    private func render() {
        let bounds = rootLayer.bounds
        guard bounds.width > 0,
              bounds.height > 0,
              !cues.isEmpty else {
            clear()
            return
        }
        while cueLayers.count < cues.count {
            cueLayers.append(CueLayer(
                parent: rootLayer,
                contentsScale: Self.contentsScale
            ))
        }
        var renderedCount = 0
        for (index, cueLayer) in cueLayers.enumerated() {
            guard cues.indices.contains(index),
                  let layout = makeLayout(
                    cues[index],
                    canvasHeight: bounds.height
                  ) else {
                cueLayer.container.isHidden = true
                cueLayer.text.string = nil
                continue
            }
            apply(
                layout,
                to: cueLayer,
                in: bounds
            )
            renderedCount += 1
        }
        visibleCueCount = renderedCount
    }

    private func makeLayout(
        _ source: NSAttributedString,
        canvasHeight: CGFloat
    ) -> CueLayout? {
        guard source.length > 0 else { return nil }
        let wholeRange = NSRange(
            location: 0,
            length: source.length
        )
        let whole = source.attributes(
            at: 0,
            effectiveRange: nil
        )
        // Vertical WebVTT requires glyph rotation and vertical line stacking.
        // It remains a track-local graceful degradation, never a route or
        // subtitle-backend switch.
        guard whole[Self.verticalLayoutKey] == nil else {
            EngineLog.emit(
                "[HybridNativeWebVTTOverlayRenderer] vertical cue omitted",
                category: .session
            )
            return nil
        }

        let baseFontPercent = Self.number(
            whole[Self.baseFontSizeKey]
        ) ?? 4.25
        let baseFontSize = max(
            16,
            canvasHeight * baseFontPercent / 100
        )
        let output = NSMutableAttributedString(
            attributedString: source
        )
        let paragraph = NSMutableParagraphStyle()
        let alignment = Self.alignment(
            whole[Self.alignmentKey]
        )
        paragraph.alignment = Self.textAlignment(alignment)
        output.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: wholeRange
        )
        source.enumerateAttributes(
            in: wholeRange
        ) { attributes, range, _ in
            let relativeSize = Self.number(
                attributes[Self.relativeFontSizeKey]
            ) ?? 100
            let pointSize = max(
                1,
                baseFontSize * relativeSize / 100
            )
            let font = Self.font(
                family: attributes[Self.fontFamilyKey]
                    as? String,
                genericFamily:
                    attributes[Self.genericFontFamilyKey]
                        as? String,
                pointSize: pointSize,
                bold: Self.boolean(
                    attributes[Self.boldKey]
                ),
                italic: Self.boolean(
                    attributes[Self.italicKey]
                )
            )
            output.addAttribute(
                .font,
                value: font,
                range: range
            )
            if let color = Self.platformColor(
                attributes[Self.foregroundColorKey]
            ) {
                output.addAttribute(
                    .foregroundColor,
                    value: color,
                    range: range
                )
            } else {
                output.addAttribute(
                    .foregroundColor,
                    value: Self.defaultForegroundColor,
                    range: range
                )
            }
            if let color = Self.platformColor(
                attributes[Self.characterBackgroundColorKey]
            ), color.cgColor.alpha > 0 {
                output.addAttribute(
                    .backgroundColor,
                    value: color,
                    range: range
                )
            }
            if Self.boolean(
                attributes[Self.underlineKey]
            ) {
                output.addAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: range
                )
            }
        }
        let edgeStyle = whole[Self.edgeStyleKey]
            as? String
        if edgeStyle
            == (kCMTextMarkupCharacterEdgeStyle_Uniform as String) {
            output.addAttribute(
                .strokeColor,
                value: Self.defaultEdgeColor,
                range: wholeRange
            )
            output.addAttribute(
                .strokeWidth,
                value: NSNumber(value: -3),
                range: wholeRange
            )
        }

        return CueLayout(
            attributedText: output,
            containerColor: Self.platformColor(
                whole[Self.backgroundColorKey]
            )?.cgColor,
            positionPercent: Self.clampedPercent(
                Self.number(whole[Self.positionKey]) ?? 50
            ),
            linePercent: Self.clampedPercent(
                Self.number(whole[Self.linePositionKey]) ?? 95
            ),
            maximumWidthPercent: max(
                1,
                Self.clampedPercent(
                    Self.number(whole[Self.writingSizeKey])
                        ?? 100
                )
            ),
            alignment: alignment,
            edgeStyle: edgeStyle
        )
    }

    private func apply(
        _ layout: CueLayout,
        to cueLayer: CueLayer,
        in canvas: CGRect
    ) {
        let horizontalPadding = max(12, canvas.height * 0.012)
        let verticalPadding = max(6, canvas.height * 0.006)
        let maximumWidth = max(
            1,
            canvas.width * layout.maximumWidthPercent / 100
        )
        let drawingWidth = max(
            1,
            maximumWidth - horizontalPadding * 2
        )
        let measured = layout.attributedText.boundingRect(
            with: CGSize(
                width: drawingWidth,
                height: .greatestFiniteMagnitude
            ),
            options: [
                .usesLineFragmentOrigin,
                .usesFontLeading,
            ],
            context: nil
        ).integral
        let width = min(
            maximumWidth,
            max(1, measured.width + horizontalPadding * 2)
        )
        let height = min(
            canvas.height,
            max(1, measured.height + verticalPadding * 2)
        )
        let anchorX = canvas.width
            * layout.positionPercent / 100
        let originX: CGFloat
        switch layout.alignment {
        case .left:
            originX = anchorX
        case .right:
            originX = anchorX - width
        default:
            originX = anchorX - width / 2
        }
        // AVFoundation resolves 0...100 cue positions inside a caption-safe
        // region so captions remain above AVKit's transport controls. Mirror
        // that public presentation behavior without inspecting AVKit's
        // private caption hierarchy.
        let captionSafeLinePercent = 10
            + layout.linePercent * 0.7
        let unclampedY = canvas.height
            * captionSafeLinePercent / 100 - height
        let frame = CGRect(
            x: min(
                max(0, originX),
                max(0, canvas.width - width)
            ),
            y: min(
                max(0, unclampedY),
                max(0, canvas.height - height)
            ),
            width: width,
            height: height
        ).integral

        cueLayer.container.frame = frame
        cueLayer.container.backgroundColor =
            layout.containerColor
        cueLayer.container.isHidden = false
        cueLayer.text.frame = cueLayer.container.bounds.insetBy(
            dx: horizontalPadding,
            dy: verticalPadding
        )
        cueLayer.text.string = layout.attributedText
        cueLayer.text.alignmentMode = layout.alignment
        Self.applyEdgeStyle(
            layout.edgeStyle,
            to: cueLayer.text
        )
    }

    private static func applyEdgeStyle(
        _ value: String?,
        to layer: CATextLayer
    ) {
        layer.shadowOpacity = 0
        layer.shadowRadius = 0
        layer.shadowOffset = .zero
        guard let value else { return }
        if value == kCMTextMarkupCharacterEdgeStyle_DropShadow
            as String {
            layer.shadowColor = CGColor(
                gray: 0,
                alpha: 1
            )
            layer.shadowOpacity = 1
            layer.shadowRadius = 2
            layer.shadowOffset = CGSize(width: 2, height: 2)
        } else if value
            == kCMTextMarkupCharacterEdgeStyle_Raised as String {
            layer.shadowColor = CGColor(
                gray: 1,
                alpha: 0.8
            )
            layer.shadowOpacity = 1
            layer.shadowRadius = 1
            layer.shadowOffset = CGSize(width: -1, height: -1)
        } else if value
            == kCMTextMarkupCharacterEdgeStyle_Depressed as String {
            layer.shadowColor = CGColor(
                gray: 0,
                alpha: 0.9
            )
            layer.shadowOpacity = 1
            layer.shadowRadius = 1
            layer.shadowOffset = CGSize(width: 1, height: 1)
        }
    }

    private static func alignment(
        _ value: Any?
    ) -> CATextLayerAlignmentMode {
        guard let value = value as? String else {
            return .center
        }
        if value == kCMTextMarkupAlignmentType_Start as String
            || value == kCMTextMarkupAlignmentType_Left as String {
            return .left
        }
        if value == kCMTextMarkupAlignmentType_End as String
            || value == kCMTextMarkupAlignmentType_Right as String {
            return .right
        }
        return .center
    }

    private static func textAlignment(
        _ alignment: CATextLayerAlignmentMode
    ) -> NSTextAlignment {
        switch alignment {
        case .left: .left
        case .right: .right
        default: .center
        }
    }

    private static func number(_ value: Any?) -> CGFloat? {
        if let number = value as? NSNumber {
            return CGFloat(number.doubleValue)
        }
        return nil
    }

    private static func boolean(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? false
    }

    private static func clampedPercent(_ value: CGFloat) -> CGFloat {
        min(100, max(0, value))
    }

    #if canImport(UIKit)
    private static var contentsScale: CGFloat {
        UIScreen.main.scale
    }

    private static var defaultForegroundColor: UIColor {
        .white
    }

    private static var defaultEdgeColor: UIColor {
        .black
    }

    private static func platformColor(_ value: Any?) -> UIColor? {
        guard let components = value as? [NSNumber],
              components.count == 4 else {
            return nil
        }
        return UIColor(
            red: CGFloat(components[1].doubleValue),
            green: CGFloat(components[2].doubleValue),
            blue: CGFloat(components[3].doubleValue),
            alpha: CGFloat(components[0].doubleValue)
        )
    }

    private static func font(
        family: String?,
        genericFamily: String?,
        pointSize: CGFloat,
        bold: Bool,
        italic: Bool
    ) -> UIFont {
        let resolvedFamily = concreteFontFamily(
            family: family,
            genericFamily: genericFamily
        )
        var font = resolvedFamily.flatMap {
            UIFont(name: $0, size: pointSize)
        } ?? UIFont.systemFont(ofSize: pointSize)
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if let descriptor = font.fontDescriptor
            .withSymbolicTraits(traits) {
            font = UIFont(
                descriptor: descriptor,
                size: pointSize
            )
        }
        return font
    }
    #elseif canImport(AppKit)
    private static var contentsScale: CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2
    }

    private static var defaultForegroundColor: NSColor {
        .white
    }

    private static var defaultEdgeColor: NSColor {
        .black
    }

    private static func platformColor(_ value: Any?) -> NSColor? {
        guard let components = value as? [NSNumber],
              components.count == 4 else {
            return nil
        }
        return NSColor(
            srgbRed: CGFloat(components[1].doubleValue),
            green: CGFloat(components[2].doubleValue),
            blue: CGFloat(components[3].doubleValue),
            alpha: CGFloat(components[0].doubleValue)
        )
    }

    private static func font(
        family: String?,
        genericFamily: String?,
        pointSize: CGFloat,
        bold: Bool,
        italic: Bool
    ) -> NSFont {
        let resolvedFamily = concreteFontFamily(
            family: family,
            genericFamily: genericFamily
        )
        var font = resolvedFamily.flatMap {
            NSFont(name: $0, size: pointSize)
        } ?? NSFont.systemFont(ofSize: pointSize)
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        if !traits.isEmpty {
            font = NSFontManager.shared.convert(
                font,
                toHaveTrait: traits
            )
        }
        return font
    }
    #endif

    private static func concreteFontFamily(
        family: String?,
        genericFamily: String?
    ) -> String? {
        if let family,
           !family.isEmpty,
           !family.hasPrefix(".") {
            return family
        }
        guard let genericFamily else { return nil }
        if genericFamily
            == (kCMTextMarkupGenericFontName_Serif as String)
            || genericFamily
                == (kCMTextMarkupGenericFontName_ProportionalSerif
                    as String) {
            return "Times New Roman"
        }
        if genericFamily
            == (kCMTextMarkupGenericFontName_Monospace as String)
            || genericFamily
                == (kCMTextMarkupGenericFontName_MonospaceSerif
                    as String)
            || genericFamily
                == (kCMTextMarkupGenericFontName_MonospaceSansSerif
                    as String) {
            return "Courier"
        }
        if genericFamily
            == (kCMTextMarkupGenericFontName_Cursive as String)
            || genericFamily
                == (kCMTextMarkupGenericFontName_Casual as String) {
            return "Snell Roundhand"
        }
        return nil
    }

    private static let foregroundColorKey = NSAttributedString.Key(
        rawValue: kCMTextMarkupAttribute_ForegroundColorARGB as String
    )
    private static let backgroundColorKey = NSAttributedString.Key(
        rawValue: kCMTextMarkupAttribute_BackgroundColorARGB as String
    )
    private static let characterBackgroundColorKey = NSAttributedString.Key(
        rawValue:
            kCMTextMarkupAttribute_CharacterBackgroundColorARGB
                as String
    )
    private static let boldKey = NSAttributedString.Key(
        rawValue: kCMTextMarkupAttribute_BoldStyle as String
    )
    private static let italicKey = NSAttributedString.Key(
        rawValue: kCMTextMarkupAttribute_ItalicStyle as String
    )
    private static let underlineKey = NSAttributedString.Key(
        rawValue: kCMTextMarkupAttribute_UnderlineStyle as String
    )
    private static let fontFamilyKey = NSAttributedString.Key(
        rawValue: kCMTextMarkupAttribute_FontFamilyName as String
    )
    private static let genericFontFamilyKey = NSAttributedString.Key(
        rawValue: kCMTextMarkupAttribute_GenericFontFamilyName as String
    )
    private static let baseFontSizeKey = NSAttributedString.Key(
        rawValue:
            kCMTextMarkupAttribute_BaseFontSizePercentageRelativeToVideoHeight
                as String
    )
    private static let relativeFontSizeKey = NSAttributedString.Key(
        rawValue: kCMTextMarkupAttribute_RelativeFontSize as String
    )
    private static let verticalLayoutKey = NSAttributedString.Key(
        rawValue: kCMTextMarkupAttribute_VerticalLayout as String
    )
    private static let alignmentKey = NSAttributedString.Key(
        rawValue: kCMTextMarkupAttribute_Alignment as String
    )
    private static let positionKey = NSAttributedString.Key(
        rawValue:
            kCMTextMarkupAttribute_TextPositionPercentageRelativeToWritingDirection
                as String
    )
    private static let linePositionKey = NSAttributedString.Key(
        rawValue:
            kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection
                as String
    )
    private static let writingSizeKey = NSAttributedString.Key(
        rawValue:
            kCMTextMarkupAttribute_WritingDirectionSizePercentage
                as String
    )
    private static let edgeStyleKey = NSAttributedString.Key(
        rawValue: kCMTextMarkupAttribute_CharacterEdgeStyle as String
    )
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
        guard let trackID else {
            deselect()
            return
        }
        presentationView.clearSubtitleOverlay()
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

    func deselect() {
        presentationView.clearSubtitleOverlay()
        selectedContract = nil
        selectedTrackID = nil
        decoder = nil
        cursor = nil
        cues.removeAll(keepingCapacity: true)
        assBuilder = nil
        assRenderer = nil
        styledScriptDirty = false
        pgsGate.reset()
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
