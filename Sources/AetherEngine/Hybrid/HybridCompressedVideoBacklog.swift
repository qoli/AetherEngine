import CoreMedia
import Darwin
import Foundation
import Libavcodec
import Libavutil

struct HybridCompressedVideoBacklogConfiguration:
    Sendable,
    Equatable
{
    static let production = HybridCompressedVideoBacklogConfiguration(
        residentByteLimit: 96 * 1_024 * 1_024,
        packetLimit: 8_192,
        spoolContentByteLimit: 256 * 1_024 * 1_024,
        sideDataElementLimit: 64
    )

    let residentByteLimit: Int
    let packetLimit: Int
    let spoolContentByteLimit: Int
    let sideDataElementLimit: Int

    init(
        residentByteLimit: Int,
        packetLimit: Int,
        spoolContentByteLimit: Int,
        sideDataElementLimit: Int = 64
    ) {
        self.residentByteLimit = residentByteLimit
        self.packetLimit = packetLimit
        self.spoolContentByteLimit = spoolContentByteLimit
        self.sideDataElementLimit = sideDataElementLimit
    }
}

struct HybridCompressedVideoBacklogSnapshot:
    Sendable,
    Equatable
{
    let queuedPayloadBytes: Int
    let queuedContentBytes: Int
    let queuedPackets: Int
    let residentContentBytes: Int
    let residentPackets: Int
    let spooledContentBytes: Int
    let spooledPackets: Int
    let maximumResidentContentBytes: Int
    let maximumResidentPackets: Int
    let maximumSpooledContentBytes: Int
    let totalSpooledPackets: Int
    let enqueueSequence: UInt64
    let dequeueSequence: UInt64
    let isClosed: Bool
}

enum HybridCompressedVideoBacklogError:
    Error,
    Sendable,
    Equatable
{
    case invalidConfiguration
    case packetCloneFailed
    case packetLimitExceeded(bytes: Int, packets: Int)
    case spoolCapacityExceeded(bytes: Int, packets: Int)
    case spoolCreateFailed
    case spoolWriteFailed
    case spoolReadFailed
    case spoolCleanupFailed
    case spoolRecordCorrupt
    case sideDataElementLimitExceeded(elements: Int, limit: Int)
    case unsupportedOpaquePacketMetadata
    case cancelled
    case closed
}

/// Lossless, generation-scoped FIFO for compressed Hybrid video packets.
///
/// The first 96 MiB remain in ref-counted AVPackets. Once that resident bound
/// is reached, later packets are serialized to a private scratch file instead
/// of blocking the shared demux loop. This is important during carrier
/// bootstrap: the same loop must keep reaching PCM packets so audio segment
/// zero can become ready. Spooled content bytes and the one-file-per-packet
/// count are independently bounded; neither limit is converted into transport
/// retry. The content-byte limit does not claim to measure filesystem block or
/// directory-metadata allocation.
///
/// The byte invariant is compressed payload plus packet side-data content.
/// It intentionally does not claim to measure allocator RSS. AVPacket/buffer
/// metadata and padding are instead bounded by the packet limit and the
/// per-packet side-data element limit.
final class HybridCompressedVideoBacklog {
    private static let ioChunkByteCount = 1 * 1_024 * 1_024

    struct DequeuedPacket {
        let packet: UnsafeMutablePointer<AVPacket>
        let decodeTime: CMTime
        let payloadByteCount: Int
    }

    private struct PacketProperties {
        let pts: Int64
        let dts: Int64
        let duration: Int64
        let position: Int64
        let streamIndex: Int32
        let flags: Int32
        let timeBaseNumerator: Int32
        let timeBaseDenominator: Int32
    }

    private struct SideDataRecord {
        let type: AVPacketSideDataType
        let size: Int
        let fileOffset: Int64
    }

    private struct DiskRecord {
        let properties: PacketProperties
        let decodeTime: CMTime
        let payloadByteCount: Int
        let fileURL: URL
        let payloadFileOffset: Int64
        let sideData: [SideDataRecord]
        let contentByteCount: Int
    }

    private enum Entry {
        case resident(
            packet: UnsafeMutablePointer<AVPacket>,
            decodeTime: CMTime,
            payloadByteCount: Int,
            contentByteCount: Int
        )
        case spooled(DiskRecord)
    }

    private let configuration: HybridCompressedVideoBacklogConfiguration
    private let baseScratchRoot: URL
    private let removeItem: (URL) throws -> Void
    private let shouldCancelIO: () -> Bool
    private let ioChunkDidComplete: (() -> Void)?
    private var currentScratchRoot: URL
    private var cleanupPending = false
    private var entries: [Entry] = []
    private var headIndex = 0
    private var residentContentBytes = 0
    private var residentPackets = 0
    private var spooledContentBytes = 0
    private var spooledPackets = 0
    private var queuedPayloadBytes = 0
    private var maximumResidentContentBytes = 0
    private var maximumResidentPackets = 0
    private var maximumSpooledContentBytes = 0
    private var totalSpooledPackets = 0
    private var enqueueSequence: UInt64 = 0
    private var dequeueSequence: UInt64 = 0
    private var isClosed = false

    init(
        configuration: HybridCompressedVideoBacklogConfiguration =
            .production,
        scratchRoot: URL? = nil,
        removeItem: @escaping (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        },
        shouldCancelIO: @escaping () -> Bool = { false },
        ioChunkDidComplete: (() -> Void)? = nil
    ) throws {
        guard configuration.residentByteLimit > 0,
              configuration.packetLimit > 0,
              configuration.spoolContentByteLimit > 0,
              configuration.sideDataElementLimit > 0 else {
            throw HybridCompressedVideoBacklogError
                .invalidConfiguration
        }
        self.configuration = configuration
        let resolvedScratchRoot = scratchRoot
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "AetherHybridVideoBacklog-\(UUID().uuidString)",
                    isDirectory: true
                )
        baseScratchRoot = resolvedScratchRoot
        currentScratchRoot = resolvedScratchRoot
        self.removeItem = removeItem
        self.shouldCancelIO = shouldCancelIO
        self.ioChunkDidComplete = ioChunkDidComplete
    }

    deinit {
        _ = close()
    }

    var snapshot: HybridCompressedVideoBacklogSnapshot {
        HybridCompressedVideoBacklogSnapshot(
            queuedPayloadBytes: queuedPayloadBytes,
            queuedContentBytes:
                residentContentBytes + spooledContentBytes,
            queuedPackets: activeEntryCount,
            residentContentBytes: residentContentBytes,
            residentPackets: residentPackets,
            spooledContentBytes: spooledContentBytes,
            spooledPackets: spooledPackets,
            maximumResidentContentBytes:
                maximumResidentContentBytes,
            maximumResidentPackets: maximumResidentPackets,
            maximumSpooledContentBytes:
                maximumSpooledContentBytes,
            totalSpooledPackets: totalSpooledPackets,
            enqueueSequence: enqueueSequence,
            dequeueSequence: dequeueSequence,
            isClosed: isClosed
        )
    }

    var isEmpty: Bool { activeEntryCount == 0 }

    var backingEntryCountForTesting: Int { entries.count }

    func append(
        packet: UnsafeMutablePointer<AVPacket>,
        decodeTime: CMTime
    ) throws {
        guard !isClosed else {
            throw HybridCompressedVideoBacklogError.closed
        }
        guard !cleanupPending else {
            throw HybridCompressedVideoBacklogError
                .spoolCleanupFailed
        }
        guard packet.pointee.opaque == nil,
              packet.pointee.opaque_ref == nil else {
            throw HybridCompressedVideoBacklogError
                .unsupportedOpaquePacketMetadata
        }
        let payloadByteCount = max(0, Int(packet.pointee.size))
        let contentByteCount = try Self.contentByteCount(
            packet: packet,
            payloadByteCount: payloadByteCount,
            packetCount: activeEntryCount + 1,
            sideDataElementLimit:
                configuration.sideDataElementLimit
        )
        guard activeEntryCount < configuration.packetLimit else {
            throw HybridCompressedVideoBacklogError
                .packetLimitExceeded(
                    bytes:
                        residentContentBytes
                            + spooledContentBytes
                            + contentByteCount,
                    packets: activeEntryCount + 1
                )
        }

        let canRemainResident =
            spooledPackets == 0
            && residentContentBytes + contentByteCount
                <= configuration.residentByteLimit
        if canRemainResident {
            guard let copy = av_packet_clone(packet) else {
                throw HybridCompressedVideoBacklogError
                    .packetCloneFailed
            }
            entries.append(.resident(
                packet: copy,
                decodeTime: decodeTime,
                payloadByteCount: payloadByteCount,
                contentByteCount: contentByteCount
            ))
            residentContentBytes += contentByteCount
            residentPackets += 1
            maximumResidentContentBytes = max(
                maximumResidentContentBytes,
                residentContentBytes
            )
            maximumResidentPackets = max(
                maximumResidentPackets,
                residentPackets
            )
        } else {
            let record = try spool(
                packet: packet,
                decodeTime: decodeTime,
                payloadByteCount: payloadByteCount,
                contentByteCount: contentByteCount
            )
            entries.append(.spooled(record))
            spooledContentBytes += record.contentByteCount
            spooledPackets += 1
            totalSpooledPackets += 1
            maximumSpooledContentBytes = max(
                maximumSpooledContentBytes,
                spooledContentBytes
            )
        }
        queuedPayloadBytes += payloadByteCount
        enqueueSequence &+= 1
    }

    func firstDecodeTime() -> CMTime? {
        guard headIndex < entries.count else { return nil }
        let first = entries[headIndex]
        switch first {
        case .resident(_, let decodeTime, _, _):
            return decodeTime
        case .spooled(let record):
            return record.decodeTime
        }
    }

    func popFirst() throws -> DequeuedPacket? {
        guard !isClosed else {
            throw HybridCompressedVideoBacklogError.closed
        }
        guard !cleanupPending else {
            throw HybridCompressedVideoBacklogError
                .spoolCleanupFailed
        }
        guard headIndex < entries.count else { return nil }
        let first = entries[headIndex]

        let result: DequeuedPacket
        switch first {
        case .resident(
            let packet,
            let decodeTime,
            let payloadByteCount,
            let contentByteCount
        ):
            result = DequeuedPacket(
                packet: packet,
                decodeTime: decodeTime,
                payloadByteCount: payloadByteCount
            )
            residentContentBytes -= contentByteCount
            residentPackets -= 1

        case .spooled(let record):
            let restored = try restore(record)
            do {
                try removeItem(record.fileURL)
            } catch {
                var packetToFree:
                    UnsafeMutablePointer<AVPacket>? =
                        restored.packet
                trackedPacketFree(&packetToFree)
                throw HybridCompressedVideoBacklogError
                    .spoolCleanupFailed
            }
            result = restored
            spooledContentBytes -= record.contentByteCount
            spooledPackets -= 1
        }

        headIndex += 1
        compactConsumedPrefixIfNeeded()
        queuedPayloadBytes -= result.payloadByteCount
        dequeueSequence &+= 1
        retireScratchIfEmpty()
        return result
    }

    func resetForGeneration() throws {
        guard !isClosed else {
            throw HybridCompressedVideoBacklogError.closed
        }
        try retireCurrentScratchRoot()
        releaseResidentPackets()
        clearState()
    }

    @discardableResult
    func close() -> HybridCompressedVideoBacklogError? {
        guard !isClosed || cleanupPending else { return nil }
        isClosed = true
        let cleanupError: HybridCompressedVideoBacklogError?
        do {
            try retireCurrentScratchRoot()
            releaseResidentPackets()
            clearState()
            cleanupError = nil
        } catch let error as HybridCompressedVideoBacklogError {
            // Explicit teardown always releases resident AVPacket references.
            // Spooled records that still exist remain in the snapshot and keep
            // their remapped retired-root URLs so a later close retry targets
            // the same bounded content instead of claiming it was removed.
            releaseResidentPacketsForFailedClose()
            cleanupError = error
        } catch {
            releaseResidentPacketsForFailedClose()
            cleanupError = .spoolCleanupFailed
        }
        return cleanupError
    }

    private func releaseResidentPackets() {
        for entry in entries[headIndex...] {
            guard case .resident(let packet, _, _, _) = entry else {
                continue
            }
            var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&packetToFree)
        }
    }

    private func releaseResidentPacketsForFailedClose() {
        var retainedEntries: [Entry] = []
        retainedEntries.reserveCapacity(spooledPackets)
        for entry in entries[headIndex...] {
            switch entry {
            case .resident(
                let packet,
                _,
                let payloadByteCount,
                let contentByteCount
            ):
                var packetToFree:
                    UnsafeMutablePointer<AVPacket>? = packet
                trackedPacketFree(&packetToFree)
                residentContentBytes -= contentByteCount
                residentPackets -= 1
                queuedPayloadBytes -= payloadByteCount
            case .spooled:
                retainedEntries.append(entry)
            }
        }
        entries = retainedEntries
        headIndex = 0
    }

    private func clearState() {
        entries.removeAll(keepingCapacity: true)
        headIndex = 0
        residentContentBytes = 0
        residentPackets = 0
        spooledContentBytes = 0
        spooledPackets = 0
        queuedPayloadBytes = 0
        maximumResidentContentBytes = 0
        maximumResidentPackets = 0
        maximumSpooledContentBytes = 0
        totalSpooledPackets = 0
        enqueueSequence = 0
        dequeueSequence = 0
        cleanupPending = false
        currentScratchRoot = baseScratchRoot
    }

    private func retireCurrentScratchRoot() throws {
        guard FileManager.default.fileExists(
            atPath: currentScratchRoot.path
        ) else {
            reconcileRetiredEntriesWithFilesystem()
            cleanupPending = false
            currentScratchRoot = baseScratchRoot
            return
        }

        if !cleanupPending {
            let sourceRoot = currentScratchRoot
            let retiredRoot = sourceRoot
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "\(sourceRoot.lastPathComponent).retired-\(UUID().uuidString)",
                    isDirectory: true
                )
            let renameResult =
                sourceRoot.withUnsafeFileSystemRepresentation {
                    sourcePath -> Int32 in
                    guard let sourcePath else { return -1 }
                    return retiredRoot
                        .withUnsafeFileSystemRepresentation {
                            retiredPath -> Int32 in
                            guard let retiredPath else {
                                return -1
                            }
                            return Darwin.rename(
                                sourcePath,
                                retiredPath
                            )
                        }
                }
            guard renameResult == 0 else {
                throw HybridCompressedVideoBacklogError
                    .spoolCleanupFailed
            }
            remapActiveDiskRecords(to: retiredRoot)
            currentScratchRoot = retiredRoot
            cleanupPending = true
        }

        do {
            try removeItem(currentScratchRoot)
        } catch {
            reconcileRetiredEntriesWithFilesystem()
            throw HybridCompressedVideoBacklogError
                .spoolCleanupFailed
        }
        cleanupPending = false
        currentScratchRoot = baseScratchRoot
    }

    private func remapActiveDiskRecords(to root: URL) {
        var remappedEntries: [Entry] = []
        remappedEntries.reserveCapacity(activeEntryCount)
        for entry in entries[headIndex...] {
            switch entry {
            case .resident:
                remappedEntries.append(entry)
            case .spooled(let record):
                remappedEntries.append(.spooled(
                    DiskRecord(
                        properties: record.properties,
                        decodeTime: record.decodeTime,
                        payloadByteCount:
                            record.payloadByteCount,
                        fileURL: root.appendingPathComponent(
                            record.fileURL.lastPathComponent
                        ),
                        payloadFileOffset:
                            record.payloadFileOffset,
                        sideData: record.sideData,
                        contentByteCount:
                            record.contentByteCount
                    )
                ))
            }
        }
        entries = remappedEntries
        headIndex = 0
    }

    private func reconcileRetiredEntriesWithFilesystem() {
        var retainedEntries: [Entry] = []
        retainedEntries.reserveCapacity(activeEntryCount)
        for entry in entries[headIndex...] {
            switch entry {
            case .resident:
                retainedEntries.append(entry)
            case .spooled(let record):
                if FileManager.default.fileExists(
                    atPath: record.fileURL.path
                ) {
                    retainedEntries.append(entry)
                } else {
                    spooledContentBytes -=
                        record.contentByteCount
                    spooledPackets -= 1
                    queuedPayloadBytes -=
                        record.payloadByteCount
                }
            }
        }
        entries = retainedEntries
        headIndex = 0
    }

    var scratchExistsForTesting: Bool {
        FileManager.default.fileExists(
            atPath: currentScratchRoot.path
        )
    }

    var scratchRootForTesting: URL { currentScratchRoot }

    private func spool(
        packet: UnsafeMutablePointer<AVPacket>,
        decodeTime: CMTime,
        payloadByteCount: Int,
        contentByteCount: Int
    ) throws -> DiskRecord {
        let sideDataCount = max(
            0,
            Int(packet.pointee.side_data_elems)
        )
        guard contentByteCount
                <= configuration.spoolContentByteLimit
                    - spooledContentBytes else {
            throw HybridCompressedVideoBacklogError
                .spoolCapacityExceeded(
                    bytes:
                        spooledContentBytes
                            + contentByteCount,
                    packets: activeEntryCount + 1
                )
        }

        do {
            try FileManager.default.createDirectory(
                at: currentScratchRoot,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: currentScratchRoot.path
            )
        } catch {
            throw HybridCompressedVideoBacklogError
                .spoolCreateFailed
        }
        let fileURL = currentScratchRoot.appendingPathComponent(
            "packet-\(enqueueSequence).bin"
        )
        let descriptor = fileURL.withUnsafeFileSystemRepresentation {
            path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(
                path,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw HybridCompressedVideoBacklogError
                .spoolCreateFailed
        }
        var writeOffset: Int64 = 0
        var sideDataRecords: [SideDataRecord] = []
        do {
            if payloadByteCount > 0 {
                guard let payload = packet.pointee.data else {
                    throw HybridCompressedVideoBacklogError
                        .spoolRecordCorrupt
                }
                try Self.writeAll(
                    descriptor: descriptor,
                    UnsafeRawPointer(payload),
                    count: payloadByteCount,
                    offset: writeOffset,
                    shouldCancel: shouldCancelIO,
                    ioChunkDidComplete:
                        ioChunkDidComplete
                )
                writeOffset += Int64(payloadByteCount)
            }

            sideDataRecords.reserveCapacity(sideDataCount)
            if sideDataCount > 0,
               let sideData = packet.pointee.side_data {
                for index in 0..<sideDataCount {
                    let item = sideData[index]
                    let itemOffset = writeOffset
                    if item.size > 0 {
                        guard let bytes = item.data else {
                            throw HybridCompressedVideoBacklogError
                                .spoolRecordCorrupt
                        }
                        try Self.writeAll(
                            descriptor: descriptor,
                            UnsafeRawPointer(bytes),
                            count: item.size,
                            offset: writeOffset,
                            shouldCancel: shouldCancelIO,
                            ioChunkDidComplete:
                                ioChunkDidComplete
                        )
                        writeOffset += Int64(item.size)
                    }
                    sideDataRecords.append(SideDataRecord(
                        type: item.type,
                        size: item.size,
                        fileOffset: itemOffset
                    ))
                }
            }
        } catch {
            Darwin.close(descriptor)
            if error as? HybridCompressedVideoBacklogError
                == .cancelled {
                try? removeItem(fileURL)
                retireScratchIfEmpty()
                throw HybridCompressedVideoBacklogError.cancelled
            }
            do {
                try removeItem(fileURL)
            } catch {
                throw HybridCompressedVideoBacklogError
                    .spoolCleanupFailed
            }
            retireScratchIfEmpty()
            throw error
        }
        Darwin.close(descriptor)

        return DiskRecord(
            properties: PacketProperties(
                pts: packet.pointee.pts,
                dts: packet.pointee.dts,
                duration: packet.pointee.duration,
                position: packet.pointee.pos,
                streamIndex: packet.pointee.stream_index,
                flags: packet.pointee.flags,
                timeBaseNumerator:
                    packet.pointee.time_base.num,
                timeBaseDenominator:
                    packet.pointee.time_base.den
            ),
            decodeTime: decodeTime,
            payloadByteCount: payloadByteCount,
            fileURL: fileURL,
            payloadFileOffset: 0,
            sideData: sideDataRecords,
            contentByteCount: contentByteCount
        )
    }

    private static func contentByteCount(
        packet: UnsafeMutablePointer<AVPacket>,
        payloadByteCount: Int,
        packetCount: Int,
        sideDataElementLimit: Int
    ) throws -> Int {
        let sideDataCount = max(
            0,
            Int(packet.pointee.side_data_elems)
        )
        guard sideDataCount <= sideDataElementLimit else {
            throw HybridCompressedVideoBacklogError
                .sideDataElementLimitExceeded(
                    elements: sideDataCount,
                    limit: sideDataElementLimit
                )
        }
        guard sideDataCount > 0 else {
            return payloadByteCount
        }
        guard let sideData = packet.pointee.side_data else {
            throw HybridCompressedVideoBacklogError
                .spoolRecordCorrupt
        }
        var result = payloadByteCount
        for index in 0..<sideDataCount {
            let itemSize = sideData[index].size
            guard itemSize <= Int.max - result else {
                throw HybridCompressedVideoBacklogError
                    .spoolCapacityExceeded(
                        bytes: Int.max,
                        packets: packetCount
                    )
            }
            result += itemSize
        }
        return result
    }

    private func restore(
        _ record: DiskRecord
    ) throws -> DequeuedPacket {
        let descriptor = record.fileURL
            .withUnsafeFileSystemRepresentation {
                path -> Int32 in
                guard let path else { return -1 }
                return Darwin.open(path, O_RDONLY | O_CLOEXEC)
            }
        guard descriptor >= 0 else {
            throw HybridCompressedVideoBacklogError
                .spoolReadFailed
        }
        defer { Darwin.close(descriptor) }
        guard let packet = trackedPacketAlloc() else {
            throw HybridCompressedVideoBacklogError
                .packetCloneFailed
        }
        var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
        do {
            if record.payloadByteCount > 0 {
                guard record.payloadByteCount <= Int(Int32.max),
                      av_new_packet(
                          packet,
                          Int32(record.payloadByteCount)
                      ) >= 0,
                      let payload = packet.pointee.data else {
                    throw HybridCompressedVideoBacklogError
                        .packetCloneFailed
                }
                try Self.readAll(
                    descriptor: descriptor,
                    UnsafeMutableRawPointer(payload),
                    count: record.payloadByteCount,
                    offset: record.payloadFileOffset,
                    shouldCancel: shouldCancelIO,
                    ioChunkDidComplete:
                        ioChunkDidComplete
                )
            }
            for item in record.sideData {
                guard let destination =
                        av_packet_new_side_data(
                            packet,
                            item.type,
                            item.size
                        ) else {
                    throw HybridCompressedVideoBacklogError
                        .packetCloneFailed
                }
                if item.size > 0 {
                    try Self.readAll(
                        descriptor: descriptor,
                        UnsafeMutableRawPointer(destination),
                        count: item.size,
                        offset: item.fileOffset,
                        shouldCancel: shouldCancelIO,
                        ioChunkDidComplete:
                            ioChunkDidComplete
                    )
                }
            }
            packet.pointee.pts = record.properties.pts
            packet.pointee.dts = record.properties.dts
            packet.pointee.duration = record.properties.duration
            packet.pointee.pos = record.properties.position
            packet.pointee.stream_index =
                record.properties.streamIndex
            packet.pointee.flags = record.properties.flags
            packet.pointee.time_base = AVRational(
                num: record.properties.timeBaseNumerator,
                den: record.properties.timeBaseDenominator
            )
            packetToFree = nil
            return DequeuedPacket(
                packet: packet,
                decodeTime: record.decodeTime,
                payloadByteCount: record.payloadByteCount
            )
        } catch {
            trackedPacketFree(&packetToFree)
            throw error
        }
    }

    private func retireScratchIfEmpty() {
        if spooledPackets == 0,
           FileManager.default.fileExists(
               atPath: currentScratchRoot.path
           ) {
            try? removeItem(currentScratchRoot)
        }
    }

    private var activeEntryCount: Int {
        entries.count - headIndex
    }

    private func compactConsumedPrefixIfNeeded() {
        guard headIndex >= 1_024,
              headIndex * 2 >= entries.count else {
            return
        }
        entries.removeFirst(headIndex)
        headIndex = 0
    }

    private static func writeAll(
        descriptor: Int32,
        _ source: UnsafeRawPointer,
        count: Int,
        offset: Int64,
        shouldCancel: () -> Bool,
        ioChunkDidComplete: (() -> Void)?
    ) throws {
        var written = 0
        while written < count {
            guard !shouldCancel() else {
                throw HybridCompressedVideoBacklogError
                    .cancelled
            }
            let chunkByteCount = min(
                count - written,
                ioChunkByteCount
            )
            let result = Darwin.pwrite(
                descriptor,
                source.advanced(by: written),
                chunkByteCount,
                off_t(offset + Int64(written))
            )
            if result < 0, errno == EINTR {
                continue
            }
            guard result > 0 else {
                throw HybridCompressedVideoBacklogError
                    .spoolWriteFailed
            }
            written += result
            ioChunkDidComplete?()
        }
    }

    private static func readAll(
        descriptor: Int32,
        _ destination: UnsafeMutableRawPointer,
        count: Int,
        offset: Int64,
        shouldCancel: () -> Bool,
        ioChunkDidComplete: (() -> Void)?
    ) throws {
        var readCount = 0
        while readCount < count {
            guard !shouldCancel() else {
                throw HybridCompressedVideoBacklogError
                    .cancelled
            }
            let chunkByteCount = min(
                count - readCount,
                ioChunkByteCount
            )
            let result = Darwin.pread(
                descriptor,
                destination.advanced(by: readCount),
                chunkByteCount,
                off_t(offset + Int64(readCount))
            )
            if result < 0, errno == EINTR {
                continue
            }
            guard result > 0 else {
                throw HybridCompressedVideoBacklogError
                    .spoolReadFailed
            }
            readCount += result
            ioChunkDidComplete?()
        }
    }
}
