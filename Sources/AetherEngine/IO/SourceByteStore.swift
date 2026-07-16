import Darwin
import Foundation

enum SourceByteStoreError: Error, LocalizedError, Sendable, Equatable {
    case invalidCapacity
    case invalidGeneration
    case generationMismatch
    case unsupportedContentEncoding(String)
    case invalidRange
    case closed
    case directoryCreationFailed
    case blockOpenFailed(errno: Int32)
    case blockReadFailed(errno: Int32)
    case blockWriteFailed(errno: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidCapacity:
            return "Source byte store capacity must be at least one block"
        case .invalidGeneration:
            return "Source byte store generation requires a positive content length"
        case .generationMismatch:
            return "Source byte store response changed the admitted content generation"
        case .unsupportedContentEncoding(let value):
            return "Source byte store requires identity content encoding, found \(value)"
        case .invalidRange:
            return "Source byte store byte range is invalid"
        case .closed:
            return "Source byte store is closed"
        case .directoryCreationFailed:
            return "Source byte store session directory could not be created"
        case .blockOpenFailed(let code):
            return "Source byte store block could not be opened (errno \(code))"
        case .blockReadFailed(let code):
            return "Source byte store block read failed (errno \(code))"
        case .blockWriteFailed(let code):
            return "Source byte store block write failed (errno \(code))"
        }
    }
}

enum SourceByteStoreValidator: Sendable, Equatable {
    case strongETag(String)
    case lastModified(String)
}

struct SourceByteStoreGeneration: Sendable, Equatable {
    let contentLength: Int64
    let validator: SourceByteStoreValidator?

    init(
        contentLength: Int64,
        validator: SourceByteStoreValidator?
    ) throws {
        guard contentLength > 0 else {
            throw SourceByteStoreError.invalidGeneration
        }
        self.contentLength = contentLength
        self.validator = validator
    }
}

struct SourceByteStoreSnapshot: Sendable, Equatable {
    let generation: SourceByteStoreGeneration
    let residentBytes: Int64
    let isComplete: Bool
}

struct SourceByteStoreValidationCandidate: Sendable, Equatable {
    let generation: SourceByteStoreGeneration
    let isComplete: Bool
}

/// Session-scoped immutable origin-byte store.
///
/// Blocks are stored under a UUID-only temporary directory; URL, Authorization, Cookie and
/// signed-header values are never used as filenames or persisted metadata. Each reader keeps its
/// own cursor and only asks this store for immutable byte ranges. A generation mismatch fails
/// explicitly so bytes from two source revisions can never be combined into valid-looking media.
final class SourceByteStore: @unchecked Sendable {
    private struct Block {
        var coveredRanges: [Range<Int>] = []
        var coveredBytes = 0
        var lastAccess: UInt64 = 0
    }

    static let defaultBlockSize = 1 * 1024 * 1024
    static let defaultCapacityBytes: Int64 = 256 * 1024 * 1024

    let sessionDirectory: URL
    let blockSize: Int
    let capacityBytes: Int64

    private let lock = NSLock()
    private var generation: SourceByteStoreGeneration?
    private var blocks: [Int64: Block] = [:]
    private var residentBytes: Int64 = 0
    private var accessCounter: UInt64 = 0
    private var isClosed = false

    init(
        blockSize: Int = SourceByteStore.defaultBlockSize,
        capacityBytes: Int64 = SourceByteStore.defaultCapacityBytes,
        baseDirectory: URL = FileManager.default.temporaryDirectory
    ) throws {
        guard blockSize > 0, capacityBytes >= Int64(blockSize) else {
            throw SourceByteStoreError.invalidCapacity
        }
        self.blockSize = blockSize
        self.capacityBytes = capacityBytes
        sessionDirectory = baseDirectory.appendingPathComponent(
            "AetherSourceBytes-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: sessionDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw SourceByteStoreError.directoryCreationFailed
        }
    }

    deinit {
        close()
    }

    func admit(_ proposed: SourceByteStoreGeneration) throws {
        lock.lock()
        defer { lock.unlock() }
        try requireOpen()
        if let generation {
            guard generation == proposed else {
                throw SourceByteStoreError.generationMismatch
            }
        } else {
            generation = proposed
        }
    }

    /// Clears all resident blocks and starts a newly validated content generation.
    func replaceGeneration(
        with proposed: SourceByteStoreGeneration
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try requireOpen()
        removeAllBlocksLocked()
        generation = proposed
    }

    /// Clears an invalidated generation. The next admitted response establishes the replacement.
    func reset() throws {
        lock.lock()
        defer { lock.unlock() }
        try requireOpen()
        removeAllBlocksLocked()
        generation = nil
    }

    func store(_ data: Data, at offset: Int64) throws {
        guard offset >= 0, !data.isEmpty else {
            if data.isEmpty { return }
            throw SourceByteStoreError.invalidRange
        }

        lock.lock()
        defer { lock.unlock() }
        try requireOpen()
        guard let generation else {
            throw SourceByteStoreError.invalidGeneration
        }
        guard offset <= generation.contentLength,
              Int64(data.count) <= generation.contentLength - offset else {
            throw SourceByteStoreError.invalidRange
        }

        var sourceOffset = 0
        while sourceOffset < data.count {
            let absoluteOffset = offset + Int64(sourceOffset)
            let blockIndex = absoluteOffset / Int64(blockSize)
            let offsetInBlock = Int(absoluteOffset % Int64(blockSize))
            let count = min(
                blockSize - offsetInBlock,
                data.count - sourceOffset
            )
            try writeLocked(
                data,
                sourceRange: sourceOffset..<(sourceOffset + count),
                blockIndex: blockIndex,
                offsetInBlock: offsetInBlock
            )
            sourceOffset += count
        }
    }

    /// Returns one contiguous resident slice. Calls never cross a block boundary; readers can
    /// immediately request the following offset to continue without sharing cursor state.
    func read(at offset: Int64, maximumLength: Int) throws -> Data? {
        guard offset >= 0, maximumLength > 0 else {
            throw SourceByteStoreError.invalidRange
        }

        lock.lock()
        defer { lock.unlock() }
        try requireOpen()
        guard let generation, offset < generation.contentLength else {
            return nil
        }
        let blockIndex = offset / Int64(blockSize)
        let offsetInBlock = Int(offset % Int64(blockSize))
        guard var block = blocks[blockIndex],
              let range = block.coveredRanges.first(
                where: { $0.contains(offsetInBlock) }
              ) else {
            return nil
        }

        let count = min(
            maximumLength,
            range.upperBound - offsetInBlock,
            Int(generation.contentLength - offset)
        )
        guard count > 0 else { return nil }
        let data = try readBlockLocked(
            blockIndex: blockIndex,
            offset: offsetInBlock,
            count: count
        )
        accessCounter &+= 1
        block.lastAccess = accessCounter
        blocks[blockIndex] = block
        return data
    }

    var snapshot: SourceByteStoreSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, let generation else { return nil }
        return SourceByteStoreSnapshot(
            generation: generation,
            residentBytes: residentBytes,
            isComplete: isCompleteLocked(generation: generation)
        )
    }

    /// Cross-reader reuse is permitted only when resident bytes have an in-memory validator that
    /// a fresh conditional request can verify. Complete candidates can reopen cache-only; partial
    /// candidates remain normal read-through sessions after validation.
    var validationCandidate: SourceByteStoreValidationCandidate? {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed,
              let generation,
              generation.validator != nil,
              residentBytes > 0 else {
            return nil
        }
        return SourceByteStoreValidationCandidate(
            generation: generation,
            isComplete: isCompleteLocked(generation: generation)
        )
    }

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        blocks.removeAll()
        generation = nil
        residentBytes = 0
        lock.unlock()
        try? FileManager.default.removeItem(at: sessionDirectory)
    }

    private func requireOpen() throws {
        guard !isClosed else { throw SourceByteStoreError.closed }
    }

    private func blockURL(_ index: Int64) -> URL {
        sessionDirectory.appendingPathComponent(
            String(index),
            isDirectory: false
        )
    }

    private func writeLocked(
        _ data: Data,
        sourceRange: Range<Int>,
        blockIndex: Int64,
        offsetInBlock: Int
    ) throws {
        let path = blockURL(blockIndex).path
        let descriptor = Darwin.open(
            path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw SourceByteStoreError.blockOpenFailed(errno: errno)
        }
        defer { Darwin.close(descriptor) }

        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < sourceRange.count {
                let result = Darwin.pwrite(
                    descriptor,
                    base.advanced(by: sourceRange.lowerBound + written),
                    sourceRange.count - written,
                    off_t(offsetInBlock + written)
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw SourceByteStoreError.blockWriteFailed(errno: errno)
                }
                guard result > 0 else {
                    throw SourceByteStoreError.blockWriteFailed(errno: EIO)
                }
                written += result
            }
        }

        var block = blocks[blockIndex] ?? Block()
        let oldCoveredBytes = block.coveredBytes
        block.coveredRanges = Self.merged(
            block.coveredRanges,
            adding: offsetInBlock..<(offsetInBlock + sourceRange.count)
        )
        block.coveredBytes = block.coveredRanges.reduce(0) {
            $0 + $1.count
        }
        accessCounter &+= 1
        block.lastAccess = accessCounter
        blocks[blockIndex] = block
        residentBytes += Int64(block.coveredBytes - oldCoveredBytes)
        evictLocked(protecting: blockIndex)
    }

    private func readBlockLocked(
        blockIndex: Int64,
        offset: Int,
        count: Int
    ) throws -> Data {
        let descriptor = Darwin.open(blockURL(blockIndex).path, O_RDONLY)
        guard descriptor >= 0 else {
            throw SourceByteStoreError.blockOpenFailed(errno: errno)
        }
        defer { Darwin.close(descriptor) }

        var data = Data(count: count)
        try data.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var totalRead = 0
            while totalRead < count {
                let result = Darwin.pread(
                    descriptor,
                    base.advanced(by: totalRead),
                    count - totalRead,
                    off_t(offset + totalRead)
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw SourceByteStoreError.blockReadFailed(errno: errno)
                }
                guard result > 0 else {
                    throw SourceByteStoreError.blockReadFailed(errno: EIO)
                }
                totalRead += result
            }
        }
        return data
    }

    private func evictLocked(protecting protectedIndex: Int64) {
        while residentBytes > capacityBytes {
            guard let victim = blocks
                .filter({ $0.key != protectedIndex })
                .min(by: { $0.value.lastAccess < $1.value.lastAccess }) else {
                break
            }
            residentBytes -= Int64(victim.value.coveredBytes)
            blocks.removeValue(forKey: victim.key)
            try? FileManager.default.removeItem(at: blockURL(victim.key))
        }
    }

    private func removeAllBlocksLocked() {
        for index in blocks.keys {
            try? FileManager.default.removeItem(at: blockURL(index))
        }
        blocks.removeAll()
        residentBytes = 0
    }

    private func isCompleteLocked(
        generation: SourceByteStoreGeneration
    ) -> Bool {
        guard residentBytes == generation.contentLength else { return false }
        var offset: Int64 = 0
        while offset < generation.contentLength {
            let blockIndex = offset / Int64(blockSize)
            let expectedCount = Int(
                min(
                    Int64(blockSize),
                    generation.contentLength - offset
                )
            )
            guard let block = blocks[blockIndex],
                  block.coveredRanges == [0..<expectedCount] else {
                return false
            }
            offset += Int64(expectedCount)
        }
        return true
    }

    private static func merged(
        _ existing: [Range<Int>],
        adding added: Range<Int>
    ) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var pending = added
        for range in existing.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if range.upperBound < pending.lowerBound {
                result.append(range)
            } else if pending.upperBound < range.lowerBound {
                result.append(pending)
                pending = range
            } else {
                pending = min(range.lowerBound, pending.lowerBound)
                    ..< max(range.upperBound, pending.upperBound)
            }
        }
        result.append(pending)
        return result
    }
}
