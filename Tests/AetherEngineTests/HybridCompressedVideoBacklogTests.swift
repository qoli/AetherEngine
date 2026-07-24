import CoreMedia
import Foundation
import Libavcodec
import Libavutil
import Testing
@testable import AetherEngine

@Suite("Hybrid compressed video backlog", .serialized)
struct HybridCompressedVideoBacklogTests {
    @Test("Spilled packets retain FIFO payload timing flags and side data")
    func losslessSpillRoundTripAndChurn() throws {
        let scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AetherHybridBacklogTest-\(UUID().uuidString)",
                isDirectory: true
            )
        let queue = try HybridCompressedVideoBacklog(
            configuration: .init(
                residentByteLimit: 8,
                packetLimit: 16,
                spoolContentByteLimit: 64
            ),
            scratchRoot: scratchRoot
        )
        defer { queue.close() }

        try appendPacket(
            sequence: 1,
            payloadBytes: 8,
            marker: 0x11,
            sideData: nil,
            to: queue
        )
        try appendPacket(
            sequence: 2,
            payloadBytes: 8,
            marker: 0x22,
            sideData: [0xA1, 0xB2, 0xC3],
            to: queue
        )
        var snapshot = queue.snapshot
        #expect(snapshot.residentContentBytes == 8)
        #expect(snapshot.residentPackets == 1)
        #expect(snapshot.spooledContentBytes == 11)
        #expect(snapshot.spooledPackets == 1)
        #expect(snapshot.maximumResidentContentBytes == 8)
        #expect(snapshot.totalSpooledPackets == 1)
        #expect(queue.scratchExistsForTesting)
        #expect(try directoryByteCount(scratchRoot) == 11)

        let first = try #require(try queue.popFirst())
        defer {
            var packet: UnsafeMutablePointer<AVPacket>? = first.packet
            trackedPacketFree(&packet)
        }
        try expectPacket(
            first.packet,
            sequence: 1,
            marker: 0x11,
            sideData: nil
        )

        // A resident slot becoming free must not let a newer packet overtake
        // the existing disk record. It also must not grow physical scratch
        // beyond the live spool-byte cap under pop/append churn.
        try appendPacket(
            sequence: 3,
            payloadBytes: 9,
            marker: 0x33,
            sideData: nil,
            to: queue
        )
        #expect(try directoryByteCount(scratchRoot) == 20)

        let second = try #require(try queue.popFirst())
        defer {
            var packet: UnsafeMutablePointer<AVPacket>? = second.packet
            trackedPacketFree(&packet)
        }
        try expectPacket(
            second.packet,
            sequence: 2,
            marker: 0x22,
            sideData: [0xA1, 0xB2, 0xC3]
        )
        #expect(try directoryByteCount(scratchRoot) == 9)

        try appendPacket(
            sequence: 4,
            payloadBytes: 10,
            marker: 0x44,
            sideData: nil,
            to: queue
        )
        #expect(try directoryByteCount(scratchRoot) == 19)

        for expected in [(3, UInt8(0x33)), (4, UInt8(0x44))] {
            let item = try #require(try queue.popFirst())
            try expectPacket(
                item.packet,
                sequence: Int64(expected.0),
                marker: expected.1,
                sideData: nil
            )
            var packet: UnsafeMutablePointer<AVPacket>? = item.packet
            trackedPacketFree(&packet)
        }

        snapshot = queue.snapshot
        #expect(snapshot.queuedPackets == 0)
        #expect(snapshot.residentContentBytes == 0)
        #expect(snapshot.spooledContentBytes == 0)
        #expect(snapshot.enqueueSequence == 4)
        #expect(snapshot.dequeueSequence == 4)
        #expect(!queue.scratchExistsForTesting)

        queue.close()
        #expect(queue.snapshot.isClosed)
        #expect(!FileManager.default.fileExists(
            atPath: scratchRoot.path
        ))
    }

    @Test("Observed 170-packet 101694752-byte backlog stays below 96 MiB resident")
    func observedHighBitrateBacklogSpillsWithoutOverflow() throws {
        let exactPayloadBytes = 101_694_752
        let packetCount = 170
        let basePacketBytes = exactPayloadBytes / packetCount
        let largerPacketCount = exactPayloadBytes % packetCount
        let residentLimit = 96 * 1_024 * 1_024
        let scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AetherHybridBacklogObserved-\(UUID().uuidString)",
                isDirectory: true
            )
        let queue = try HybridCompressedVideoBacklog(
            configuration: .init(
                residentByteLimit: residentLimit,
                packetLimit: 8_192,
                spoolContentByteLimit: 8 * 1_024 * 1_024
            ),
            scratchRoot: scratchRoot
        )
        defer { queue.close() }

        for index in 0..<packetCount {
            let payloadBytes = basePacketBytes
                + (index < largerPacketCount ? 1 : 0)
            try appendPacket(
                sequence: Int64(index),
                payloadBytes: payloadBytes,
                marker: UInt8(truncatingIfNeeded: index),
                sideData: nil,
                to: queue
            )
            #expect(
                queue.snapshot.residentContentBytes
                    <= residentLimit
            )
        }

        let snapshot = queue.snapshot
        #expect(snapshot.queuedPayloadBytes == exactPayloadBytes)
        #expect(snapshot.queuedPackets == packetCount)
        #expect(snapshot.maximumResidentContentBytes <= residentLimit)
        #expect(snapshot.spooledPackets > 0)
        #expect(snapshot.totalSpooledPackets > 0)
        #expect(snapshot.spooledContentBytes < 8 * 1_024 * 1_024)

        for index in 0..<packetCount {
            let item = try #require(try queue.popFirst())
            #expect(item.packet.pointee.pts == Int64(index))
            #expect(
                item.packet.pointee.data?.pointee
                    == UInt8(truncatingIfNeeded: index)
            )
            var packet: UnsafeMutablePointer<AVPacket>? = item.packet
            trackedPacketFree(&packet)
        }
        #expect(queue.snapshot.queuedPackets == 0)
        #expect(!queue.scratchExistsForTesting)
    }

    @Test("Long FIFO churn compacts consumed prefixes amortized")
    func longChurnDoesNotGrowBackingArray() throws {
        let queue = try HybridCompressedVideoBacklog(
            configuration: .init(
                residentByteLimit: 1_024,
                packetLimit: 8,
                spoolContentByteLimit: 1_024
            )
        )
        defer { queue.close() }

        for index in 0..<5_000 {
            try appendPacket(
                sequence: Int64(index),
                payloadBytes: 1,
                marker: UInt8(truncatingIfNeeded: index),
                sideData: nil,
                to: queue
            )
            let item = try #require(try queue.popFirst())
            var packet: UnsafeMutablePointer<AVPacket>? =
                item.packet
            trackedPacketFree(&packet)
        }

        #expect(queue.snapshot.queuedPackets == 0)
        #expect(queue.snapshot.enqueueSequence == 5_000)
        #expect(queue.snapshot.dequeueSequence == 5_000)
        #expect(queue.backingEntryCountForTesting < 1_024)
    }

    @Test("Resident byte bound includes side data with no payload")
    func zeroPayloadLargeSideDataSpills() throws {
        let queue = try HybridCompressedVideoBacklog(
            configuration: .init(
                residentByteLimit: 8,
                packetLimit: 8,
                spoolContentByteLimit: 32
            )
        )
        defer { queue.close() }

        let sideData = Array(repeating: UInt8(0xA5), count: 16)
        try appendPacket(
            sequence: 1,
            payloadBytes: 0,
            marker: 0,
            sideData: sideData,
            to: queue
        )

        let snapshot = queue.snapshot
        #expect(snapshot.queuedPayloadBytes == 0)
        #expect(snapshot.queuedContentBytes == 16)
        #expect(snapshot.residentContentBytes == 0)
        #expect(snapshot.residentPackets == 0)
        #expect(snapshot.spooledContentBytes == 16)
        #expect(snapshot.spooledPackets == 1)

        let restored = try #require(try queue.popFirst())
        defer {
            var packet:
                UnsafeMutablePointer<AVPacket>? = restored.packet
            trackedPacketFree(&packet)
        }
        try expectPacket(
            restored.packet,
            sequence: 1,
            payloadBytes: 0,
            marker: 0,
            sideData: sideData
        )
    }

    @Test("Unsupported opaque metadata is rejected before resident admission")
    func opaqueMetadataIsRejectedOnResidentFirstPath() throws {
        let queue = try HybridCompressedVideoBacklog(
            configuration: .init(
                residentByteLimit: 1_024,
                packetLimit: 8,
                spoolContentByteLimit: 1_024
            )
        )
        defer { queue.close() }

        for kind in OpaqueMetadataKind.allCases {
            #expect(throws: HybridCompressedVideoBacklogError
                .unsupportedOpaquePacketMetadata) {
                try appendPacket(
                    sequence: 1,
                    payloadBytes: 8,
                    marker: 0x11,
                    sideData: nil,
                    opaqueMetadata: kind,
                    to: queue
                )
            }
        }
        #expect(queue.snapshot.queuedPackets == 0)
        #expect(queue.snapshot.totalSpooledPackets == 0)
    }

    @Test("Zero-length side-data elements cannot bypass resident bounds")
    func sideDataElementCountHasHardBound() throws {
        let queue = try HybridCompressedVideoBacklog(
            configuration: .init(
                residentByteLimit: 1_024,
                packetLimit: 8,
                spoolContentByteLimit: 1_024,
                sideDataElementLimit: 1
            )
        )
        defer { queue.close() }
        let packet = try #require(trackedPacketAlloc())
        var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
        defer { trackedPacketFree(&packetToFree) }
        packet.pointee.pts = 1
        packet.pointee.dts = 1
        packet.pointee.time_base = AVRational(num: 1, den: 90_000)
        _ = try #require(av_packet_new_side_data(
            packet,
            AV_PKT_DATA_PALETTE,
            0
        ))
        _ = try #require(av_packet_new_side_data(
            packet,
            AV_PKT_DATA_NEW_EXTRADATA,
            0
        ))

        #expect(throws: HybridCompressedVideoBacklogError
            .sideDataElementLimitExceeded(elements: 2, limit: 1)) {
            try queue.append(
                packet: packet,
                decodeTime: CMTime(value: 1, timescale: 90_000)
            )
        }
        #expect(queue.snapshot.queuedPackets == 0)
    }

    @Test("Pop commits only after its spool record is removed")
    func popCleanupFailurePreservesRecordAndCounters() throws {
        let scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AetherHybridBacklogPopCleanup-\(UUID().uuidString)",
                isDirectory: true
            )
        var failRecordRemoval = true
        let queue = try HybridCompressedVideoBacklog(
            configuration: .init(
                residentByteLimit: 1,
                packetLimit: 8,
                spoolContentByteLimit: 16
            ),
            scratchRoot: scratchRoot,
            removeItem: { url in
                if failRecordRemoval,
                   url.lastPathComponent.hasPrefix("packet-") {
                    throw InjectedRemovalError.denied
                }
                try FileManager.default.removeItem(at: url)
            }
        )
        defer { queue.close() }
        try appendPacket(
            sequence: 1,
            payloadBytes: 8,
            marker: 0x11,
            sideData: nil,
            to: queue
        )
        let before = queue.snapshot

        #expect(throws: HybridCompressedVideoBacklogError
            .spoolCleanupFailed) {
            _ = try queue.popFirst()
        }
        #expect(queue.snapshot == before)
        #expect(try directoryByteCount(scratchRoot) == 8)

        failRecordRemoval = false
        let restored = try #require(try queue.popFirst())
        var packet: UnsafeMutablePointer<AVPacket>? =
            restored.packet
        trackedPacketFree(&packet)
        #expect(queue.snapshot.queuedPackets == 0)
        #expect(!queue.scratchExistsForTesting)
    }

    @Test("Generation reset remains truthful when scratch removal fails")
    func resetCleanupFailurePreservesRecordAndCounters() throws {
        let scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AetherHybridBacklogResetCleanup-\(UUID().uuidString)",
                isDirectory: true
            )
        var failRootRemoval = true
        let queue = try HybridCompressedVideoBacklog(
            configuration: .init(
                residentByteLimit: 1,
                packetLimit: 8,
                spoolContentByteLimit: 16
            ),
            scratchRoot: scratchRoot,
            removeItem: { url in
                if failRootRemoval,
                   url.lastPathComponent.hasPrefix(
                       "\(scratchRoot.lastPathComponent).retired-"
                   ) {
                    throw InjectedRemovalError.denied
                }
                try FileManager.default.removeItem(at: url)
            }
        )
        defer { queue.close() }
        try appendPacket(
            sequence: 1,
            payloadBytes: 8,
            marker: 0x11,
            sideData: nil,
            to: queue
        )
        let before = queue.snapshot

        #expect(throws: HybridCompressedVideoBacklogError
            .spoolCleanupFailed) {
            try queue.resetForGeneration()
        }
        #expect(queue.snapshot == before)
        #expect(
            try directoryByteCount(
                queue.scratchRootForTesting
            ) == 8
        )
        #expect(
            HybridVideoDecodeSinkError
                .packetSpoolCleanupFailed
                .isLocalQueueInvariantFailure
        )

        failRootRemoval = false
        try queue.resetForGeneration()
        #expect(queue.snapshot.queuedPackets == 0)
        #expect(queue.snapshot.spooledContentBytes == 0)
        #expect(!queue.scratchExistsForTesting)
    }

    @Test("Partial recursive cleanup reconciles the retired spool")
    func partialResetCleanupFailureRemainsTruthful() throws {
        let scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AetherHybridBacklogPartialCleanup-\(UUID().uuidString)",
                isDirectory: true
            )
        var failAfterOneRemoval = true
        let queue = try HybridCompressedVideoBacklog(
            configuration: .init(
                residentByteLimit: 1,
                packetLimit: 8,
                spoolContentByteLimit: 32
            ),
            scratchRoot: scratchRoot,
            removeItem: { url in
                if failAfterOneRemoval,
                   url.lastPathComponent.hasPrefix(
                       "\(scratchRoot.lastPathComponent).retired-"
                   ) {
                    let firstFile = try #require(
                        FileManager.default
                            .contentsOfDirectory(
                                at: url,
                                includingPropertiesForKeys: nil
                            )
                            .first
                    )
                    try FileManager.default.removeItem(
                        at: firstFile
                    )
                    throw InjectedRemovalError.denied
                }
                try FileManager.default.removeItem(at: url)
            }
        )
        defer { queue.close() }
        for sequence in 1...2 {
            try appendPacket(
                sequence: Int64(sequence),
                payloadBytes: 8,
                marker: UInt8(sequence),
                sideData: nil,
                to: queue
            )
        }
        #expect(queue.snapshot.spooledPackets == 2)
        #expect(queue.snapshot.spooledContentBytes == 16)

        #expect(throws: HybridCompressedVideoBacklogError
            .spoolCleanupFailed) {
            try queue.resetForGeneration()
        }
        let retained = queue.snapshot
        #expect(retained.queuedPackets == 1)
        #expect(retained.queuedPayloadBytes == 8)
        #expect(retained.spooledPackets == 1)
        #expect(retained.spooledContentBytes == 8)
        #expect(queue.scratchExistsForTesting)
        #expect(
            try directoryByteCount(
                queue.scratchRootForTesting
            ) == 8
        )

        failAfterOneRemoval = false
        try queue.resetForGeneration()
        #expect(queue.snapshot.queuedPackets == 0)
        #expect(queue.snapshot.spooledContentBytes == 0)
        #expect(!queue.scratchExistsForTesting)
    }

    @Test("Disk hard limit maps to a permanent local invariant")
    func diskLimitIsPermanentInvariant() throws {
        let queue = try HybridCompressedVideoBacklog(
            configuration: .init(
                residentByteLimit: 1,
                packetLimit: 8,
                spoolContentByteLimit: 4
            )
        )
        defer { queue.close() }

        #expect(throws: HybridCompressedVideoBacklogError
            .spoolCapacityExceeded(bytes: 5, packets: 1)) {
            try appendPacket(
                sequence: 0,
                payloadBytes: 5,
                marker: 0x55,
                sideData: nil,
                to: queue
            )
        }

        let providerError =
            BlackCarrierMediaFanoutPumpError.videoDecoderFailed(
                error: .packetSpoolCapacityExceeded(
                    bytes: 5,
                    packets: 1
                )
            )
        #expect(providerError.failureCategory == .invariant)
        #expect(
            providerError.failureCaseCode
                == "videoDecoder.localQueueInvariant"
        )
        let failure = AetherPlaybackSession.hybridFailure(
            evidence: HybridPlaybackFailureEvidence(
                stage: .preparation,
                category: providerError.failureCategory,
                caseCode: providerError.failureCaseCode,
                underlyingDomain: providerError.failureDomain,
                underlyingCode: providerError.failureCode
            )
        )
        #expect(failure.kind == .invariantViolation)
        #expect(
            PlaybackRecoveryDecision.resolve(
                context: AetherPlaybackRecoveryContext(
                    failure: failure,
                    activeRoute: .hybridCarrier,
                    positivelyAdmittedAlternateRoute: nil,
                    transportAttempt: 100,
                    sameRouteRebuildCount: 0,
                    routeTransitionCount: 0,
                    elapsedSeconds: 10_000
                )
            ) == .terminate
        )
    }

    private func appendPacket(
        sequence: Int64,
        payloadBytes: Int,
        marker: UInt8,
        sideData: [UInt8]?,
        opaqueMetadata: OpaqueMetadataKind? = nil,
        to queue: HybridCompressedVideoBacklog
    ) throws {
        let packet = try #require(trackedPacketAlloc())
        var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
        defer {
            packet.pointee.opaque = nil
            trackedPacketFree(&packetToFree)
        }
        if payloadBytes > 0 {
            #expect(av_new_packet(packet, Int32(payloadBytes)) >= 0)
            guard let payload = packet.pointee.data else {
                Issue.record("packet payload allocation failed")
                return
            }
            memset(payload, Int32(marker), payloadBytes)
        }
        packet.pointee.pts = sequence
        packet.pointee.dts = sequence - 1
        packet.pointee.duration = 2
        packet.pointee.pos = sequence * 101
        packet.pointee.stream_index = 7
        packet.pointee.flags =
            sequence.isMultiple(of: 2) ? AV_PKT_FLAG_KEY : 0
        packet.pointee.time_base = AVRational(num: 1, den: 90_000)
        if let sideData {
            let storage = try #require(
                av_packet_new_side_data(
                    packet,
                    AV_PKT_DATA_DYNAMIC_HDR10_PLUS,
                    sideData.count
                )
            )
            sideData.withUnsafeBytes {
                guard let base = $0.baseAddress else { return }
                memcpy(storage, base, sideData.count)
            }
        }
        switch opaqueMetadata {
        case .opaque:
            packet.pointee.opaque =
                UnsafeMutableRawPointer(bitPattern: 1)
        case .opaqueReference:
            packet.pointee.opaque_ref = av_buffer_alloc(1)
        case nil:
            break
        }
        try queue.append(
            packet: packet,
            decodeTime: CMTime(
                value: sequence,
                timescale: 90_000
            )
        )
    }

    private func expectPacket(
        _ packet: UnsafeMutablePointer<AVPacket>,
        sequence: Int64,
        payloadBytes: Int? = nil,
        marker: UInt8,
        sideData: [UInt8]?
    ) throws {
        #expect(packet.pointee.pts == sequence)
        #expect(packet.pointee.dts == sequence - 1)
        #expect(packet.pointee.duration == 2)
        #expect(packet.pointee.pos == sequence * 101)
        #expect(packet.pointee.stream_index == 7)
        #expect(
            packet.pointee.flags
                == (sequence.isMultiple(of: 2)
                    ? AV_PKT_FLAG_KEY
                    : 0)
        )
        #expect(packet.pointee.time_base.num == 1)
        #expect(packet.pointee.time_base.den == 90_000)
        if let payloadBytes {
            #expect(packet.pointee.size == payloadBytes)
        }
        if payloadBytes != 0 {
            #expect(packet.pointee.data?.pointee == marker)
        }
        if let sideData {
            #expect(packet.pointee.side_data_elems == 1)
            let item = try #require(packet.pointee.side_data)
            #expect(item.pointee.type == AV_PKT_DATA_DYNAMIC_HDR10_PLUS)
            #expect(item.pointee.size == sideData.count)
            let restored = Array(
                UnsafeBufferPointer(
                    start: item.pointee.data,
                    count: item.pointee.size
                )
            )
            #expect(restored == sideData)
        } else {
            #expect(packet.pointee.side_data_elems == 0)
        }
    }

    private enum OpaqueMetadataKind: CaseIterable {
        case opaque
        case opaqueReference
    }

    private enum InjectedRemovalError: Error {
        case denied
    }

    private func directoryByteCount(_ directory: URL) throws -> Int {
        guard FileManager.default.fileExists(
            atPath: directory.path
        ) else {
            return 0
        }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ).reduce(0) {
            $0 + (
                try $1.resourceValues(
                    forKeys: [.fileSizeKey]
                ).fileSize ?? 0
            )
        }
    }
}
