import Foundation

/// Reads the selected video's BMFF sample entry from an HLS init segment without guessing from a byte
/// substring. `hvc1` versus `hev1` is a packaging fact that controls the AVPlayer/native route.
enum BMFFVideoSampleEntryInspector {
    private static let containerTypes: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "edts", "dinf", "mvex"]

    static func inspect(initSegment: Data) -> HLSVideoSampleEntry {
        var entries: [HLSVideoSampleEntry] = []
        visitBoxes(in: initSegment, range: 0..<initSegment.count, entries: &entries)
        guard let entry = entries.first, entries.allSatisfy({ $0 == entry }) else { return .unknown }
        return entry
    }

    private static func visitBoxes(
        in data: Data,
        range: Range<Int>,
        entries: inout [HLSVideoSampleEntry]
    ) {
        var cursor = range.lowerBound
        while cursor + 8 <= range.upperBound {
            guard let size32 = uint32(data, at: cursor),
                  let type = fourCC(data, at: cursor + 4) else { return }
            var headerSize = 8
            let boxSize: Int
            if size32 == 1 {
                guard cursor + 16 <= range.upperBound,
                      let extended = uint64(data, at: cursor + 8),
                      extended <= UInt64(Int.max) else { return }
                headerSize = 16
                boxSize = Int(extended)
            } else if size32 == 0 {
                boxSize = range.upperBound - cursor
            } else {
                boxSize = Int(size32)
            }
            guard boxSize >= headerSize, cursor + boxSize <= range.upperBound else { return }
            let contentRange = (cursor + headerSize)..<(cursor + boxSize)
            if type == "stsd" {
                inspectSampleDescriptions(in: data, contentRange: contentRange, entries: &entries)
            } else if containerTypes.contains(type) {
                visitBoxes(in: data, range: contentRange, entries: &entries)
            }
            cursor += boxSize
        }
    }

    private static func inspectSampleDescriptions(
        in data: Data,
        contentRange: Range<Int>,
        entries: inout [HLSVideoSampleEntry]
    ) {
        // FullBox version/flags (4 bytes) + entry_count (4 bytes).
        guard contentRange.count >= 8,
              let count = uint32(data, at: contentRange.lowerBound + 4) else { return }
        var cursor = contentRange.lowerBound + 8
        for _ in 0..<count {
            guard cursor + 8 <= contentRange.upperBound,
                  let size = uint32(data, at: cursor),
                  size >= 8,
                  Int(size) <= contentRange.upperBound - cursor,
                  let type = fourCC(data, at: cursor + 4) else { return }
            switch type {
            case "avc1": entries.append(.avc1)
            case "hvc1": entries.append(.hvc1)
            case "hev1": entries.append(.hev1)
            case "dvh1": entries.append(.dvh1)
            default: break
            }
            cursor += Int(size)
        }
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func uint64(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        var value: UInt64 = 0
        for index in offset..<(offset + 8) { value = (value << 8) | UInt64(data[index]) }
        return value
    }

    private static func fourCC(_ data: Data, at offset: Int) -> String? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return String(bytes: data[offset..<(offset + 4)], encoding: .ascii)
    }
}
