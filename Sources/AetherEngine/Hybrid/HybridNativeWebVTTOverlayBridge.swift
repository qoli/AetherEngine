import AVFoundation
import CoreMedia
import Foundation

/// Presentation-only bridge for the WebVTT rendition selected by AVKit.
///
/// AVPlayer remains the sole carrier clock and media-selection owner. The
/// bridge observes the already-selected legible samples and places their
/// public CoreMedia attributed-string representation above Aether's real
/// video. It never fetches, parses, schedules, or selects a second subtitle
/// source and therefore is not another subtitle backend or fallback route.
@MainActor
final class HybridNativeWebVTTOverlayBridge:
    NSObject,
    AVPlayerItemLegibleOutputPushDelegate
{
    private final class LegibleCallbackPayload:
        @unchecked Sendable
    {
        let strings: [NSAttributedString]
        let nativeSampleCount: Int
        let itemTime: CMTime

        init(
            strings: [NSAttributedString],
            nativeSampleCount: Int,
            itemTime: CMTime
        ) {
            self.strings = strings.map {
                NSAttributedString(
                    attributedString: $0
                )
            }
            self.nativeSampleCount = nativeSampleCount
            self.itemTime = itemTime
        }
    }

    private let presentationView:
        AetherHybridPresentationView
    private let expectedRenditionCount: Int
    private let output = AVPlayerItemLegibleOutput()
    private weak var item: AVPlayerItem?
    private var legibleGroup: AVMediaSelectionGroup?
    private var groupResolutionTask: Task<Void, Never>?
    private var overlaySubtitleActive = false

    var nativeSelectionDidActivate:
        (@MainActor () -> Void)?

    private(set) var isAttached = false
    private(set) var resolvedMediaSelectionOptionCount: Int?

    init(
        presentationView: AetherHybridPresentationView,
        expectedRenditionCount: Int
    ) {
        self.presentationView = presentationView
        self.expectedRenditionCount =
            expectedRenditionCount
        super.init()
        output.suppressesPlayerRendering = true
        output.textStylingResolution = .default
        output.setDelegate(self, queue: .main)
    }

    func attach(to item: AVPlayerItem) throws {
        if let currentItem = self.item {
            guard currentItem === item else {
                throw AetherHybridPresentationError
                    .carrierBindingChanged
            }
            return
        }
        self.item = item
        item.add(output)
        isAttached = true
        groupResolutionTask = Task {
            [weak self, weak item] in
            guard let self,
                  let item else { return }
            do {
                let group = try await item.asset
                    .loadMediaSelectionGroup(
                        for: .legible
                    )
                guard !Task.isCancelled,
                      self.item === item else {
                    return
                }
                self.legibleGroup = group
                self.resolvedMediaSelectionOptionCount =
                    group?.options.count ?? 0
                if self.expectedRenditionCount > 0,
                   group == nil {
                    EngineLog.emit(
                        "[HybridNativeWebVTTOverlayBridge] native WebVTT media-selection group unavailable",
                        category: .session
                    )
                }
                self.applyPresentationOwnershipPolicy()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.resolvedMediaSelectionOptionCount = 0
                EngineLog.emit(
                    "[HybridNativeWebVTTOverlayBridge] native WebVTT media-selection group load failed type=\(String(reflecting: type(of: error)))",
                    category: .session
                )
            }
        }
    }

    /// Selecting an Aether bitmap/styled subtitle gives that presentation
    /// exclusive ownership and explicitly deselects AVKit's legible group.
    /// Turning the overlay off does not silently reselect a native track.
    func setOverlaySubtitleActive(_ active: Bool) {
        overlaySubtitleActive = active
        if active {
            presentationView.clearNativeWebVTTCues()
        }
        applyPresentationOwnershipPolicy()
    }

    func mediaSelectionDidChange() {
        applyPresentationOwnershipPolicy()
    }

    func detach() {
        groupResolutionTask?.cancel()
        groupResolutionTask = nil
        output.setDelegate(nil, queue: nil)
        if let item {
            item.remove(output)
        }
        item = nil
        legibleGroup = nil
        resolvedMediaSelectionOptionCount = nil
        overlaySubtitleActive = false
        isAttached = false
        presentationView.clearNativeWebVTTCues()
    }

    private func applyPresentationOwnershipPolicy() {
        guard let item,
              let legibleGroup else {
            return
        }
        if overlaySubtitleActive {
            if item.currentMediaSelection
                .selectedMediaOption(
                    in: legibleGroup
                ) != nil {
                item.select(nil, in: legibleGroup)
            }
            presentationView.clearNativeWebVTTCues()
            return
        }
        if item.currentMediaSelection
            .selectedMediaOption(in: legibleGroup) != nil {
            nativeSelectionDidActivate?()
        } else {
            presentationView.clearNativeWebVTTCues()
        }
    }

    nonisolated func legibleOutput(
        _ output: AVPlayerItemLegibleOutput,
        didOutputAttributedStrings strings:
            [NSAttributedString],
        nativeSampleBuffers: [Any],
        forItemTime itemTime: CMTime
    ) {
        let payload = LegibleCallbackPayload(
            strings: strings,
            nativeSampleCount:
                nativeSampleBuffers.count,
            itemTime: itemTime
        )
        MainActor.assumeIsolated {
            guard output === self.output,
                  self.isAttached else {
                return
            }
            self.receive(
                payload.strings,
                nativeSampleCount:
                    payload.nativeSampleCount,
                itemTime: payload.itemTime
            )
        }
    }

    func receive(
        _ strings: [NSAttributedString],
        nativeSampleCount: Int,
        itemTime: CMTime
    ) {
        guard isAttached else { return }
        if nativeSampleCount > 0 {
            EngineLog.emit(
                "[HybridNativeWebVTTOverlayBridge] unexpected native legible samples omitted count=\(nativeSampleCount)",
                category: .session
            )
        }
        guard !overlaySubtitleActive else {
            presentationView.clearNativeWebVTTCues()
            return
        }
        let visible = strings.filter {
            !$0.string.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        }
        guard !visible.isEmpty else {
            presentationView.clearNativeWebVTTCues()
            return
        }
        nativeSelectionDidActivate?()
        presentationView.showNativeWebVTTCues(visible)
        EngineLog.emit(
            "[HybridNativeWebVTTOverlayBridge] presented cues=\(visible.count) itemTime=\(itemTime.seconds)",
            category: .session,
            level: .verbose
        )
    }
}
