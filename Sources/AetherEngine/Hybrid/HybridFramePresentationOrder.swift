import CoreMedia
import Foundation

/// Converts decoder callback order into the source-declared presentation order.
///
/// `reorderDepth` is the demuxer's `AVCodecParameters.video_delay`: the number
/// of decoded frames that may precede an earlier presentation timestamp. The
/// buffer never drops or rewrites a frame or timestamp. A regression that
/// arrives outside this declared window remains visible to the presentation
/// invariant and fails there.
struct HybridFramePresentationOrder<Element> {
    private struct Entry {
        let element: Element
        let presentationTime: CMTime
        let ordinal: UInt64
    }

    private let reorderDepth: Int
    private var entries: [Entry] = []
    private var nextOrdinal: UInt64 = 0

    init(reorderDepth: Int) {
        precondition(reorderDepth >= 0)
        self.reorderDepth = reorderDepth
    }

    mutating func insert(
        _ element: Element,
        presentationTime: CMTime
    ) -> [Element] {
        let entry = Entry(
            element: element,
            presentationTime: presentationTime,
            ordinal: nextOrdinal
        )
        nextOrdinal &+= 1
        let insertionIndex = entries.firstIndex(where: {
            let comparison = CMTimeCompare(
                $0.presentationTime,
                presentationTime
            )
            return comparison > 0
                || (comparison == 0 && $0.ordinal > entry.ordinal)
        }) ?? entries.endIndex
        entries.insert(entry, at: insertionIndex)

        guard entries.count > reorderDepth else { return [] }
        return [entries.removeFirst().element]
    }

    mutating func drain() -> [Element] {
        defer { entries.removeAll(keepingCapacity: true) }
        return entries.map(\.element)
    }

    mutating func discard() {
        entries.removeAll(keepingCapacity: true)
    }
}
