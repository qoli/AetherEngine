import Foundation
import Libavcodec
import XCTest
@testable import AetherEngine

/// Private-fixture integration diagnostic for the physical Atmos device gate.
///
/// CI has no redistributable E-AC-3 JOC asset, so this test skips unless the
/// caller supplies both the fixture URL and its local generated directory. It
/// proves the contract that the hybrid carrier's first audio fragment contains
/// the same compressed JOC access units as the legally supplied source. No
/// compressed bytes, paths or URLs are printed.
final class LicensedJOCBlackCarrierDiagnosticsTests: XCTestCase {
    func testLicensedJOCStreamCopyPreservesCompressedAccessUnits()
        async throws
    {
        let environment = ProcessInfo.processInfo.environment
        guard let fixtureURLValue =
                environment["AETHER_ACCEPTANCE_FIXTURE_URL"],
              let fixtureURL = URL(string: fixtureURLValue),
              let fixtureDirectoryValue =
                environment["AETHER_ACCEPTANCE_FIXTURE_DIRECTORY"] else {
            throw XCTSkip(
                "licensed JOC fixture URL and directory were not supplied"
            )
        }

        let fixtureDirectory = URL(
            fileURLWithPath: fixtureDirectoryValue,
            isDirectory: true
        )
        let sourceInit = try Data(
            contentsOf:
                fixtureDirectory
                    .appendingPathComponent("atmos")
                    .appendingPathComponent("init_1.mp4")
        )
        let sourceMedia = try Data(
            contentsOf:
                fixtureDirectory
                    .appendingPathComponent("atmos")
                    .appendingPathComponent("segment_000.m4s")
        )

        let operation = AetherPlaybackPreflightOperation()
        let preflight = try await operation.inspectHLS(
            url: fixtureURL,
            sourceIsSeekableVOD: true,
            variantSelection: .highestBandwidth,
            hybridCapabilities: AetherHybridPlaybackSession.capabilities
        )
        XCTAssertEqual(preflight.result.route, .hybridCarrier)

        let provider = try await HLSVODCarrierProvider.make(
            preflight: preflight
        )
        defer { provider.close() }
        try provider.prepareForTransportStart()

        let carrierInit = try XCTUnwrap(
            provider.alternateAudioInitSegment(ordinal: 0)
        )
        let carrierMedia = try XCTUnwrap(
            provider.alternateAudioMediaSegment(ordinal: 0, index: 0)
        )

        let source = try inspectEAC3(sourceInit + sourceMedia)
        let carrier = try inspectEAC3(carrierInit + carrierMedia)
        XCTAssertEqual(source.profile, 30)
        XCTAssertEqual(carrier.profile, 30)
        XCTAssertFalse(source.accessUnits.isEmpty)
        XCTAssertEqual(carrier.accessUnits, source.accessUnits)

        XCTAssertTrue(carrierInit.containsASCII("ec-3"))
        XCTAssertTrue(carrierInit.containsASCII("dec3"))
        let sourceDEC3 = sourceInit.firstISOBox(named: "dec3")
        let carrierDEC3 = carrierInit.firstISOBox(named: "dec3")
        XCTAssertNotNil(sourceDEC3)
        XCTAssertNotNil(carrierDEC3)

        print(
            "AETHER_JOC_DIAGNOSTIC "
                + "sourceProfile=30 carrierProfile=30 "
                + "accessUnits=\(carrier.accessUnits.count) "
                + "compressedBytes=\(carrier.accessUnits.reduce(0) { $0 + $1.count }) "
                + "payloadIdentity=true "
                + "sourceDEC3Bytes=\(sourceDEC3?.count ?? 0) "
                + "carrierDEC3Bytes=\(carrierDEC3?.count ?? 0) "
                + "dec3Identity=\(sourceDEC3 == carrierDEC3)"
        )
    }

    private func inspectEAC3(
        _ data: Data
    ) throws -> (profile: Int32, accessUnits: [Data]) {
        let demuxer = Demuxer()
        try demuxer.open(
            reader: DataIOReader(data: data),
            formatHint: "mp4"
        )
        defer { demuxer.close() }

        let stream = try XCTUnwrap(
            demuxer.stream(at: demuxer.audioStreamIndex)
        )
        XCTAssertEqual(
            stream.pointee.codecpar.pointee.codec_id,
            AV_CODEC_ID_EAC3
        )
        var accessUnits: [Data] = []
        while let packet = try demuxer.readPacket() {
            var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&packetToFree) }
            guard packet.pointee.stream_index == demuxer.audioStreamIndex,
                  let bytes = packet.pointee.data,
                  packet.pointee.size > 0 else {
                continue
            }
            accessUnits.append(
                Data(bytes: bytes, count: Int(packet.pointee.size))
            )
        }
        return (
            stream.pointee.codecpar.pointee.profile,
            accessUnits
        )
    }
}

private extension Data {
    func containsASCII(_ value: String) -> Bool {
        range(of: Data(value.utf8)) != nil
    }

    func firstISOBox(named name: String) -> Data? {
        let marker = Data(name.utf8)
        guard marker.count == 4,
              let markerRange = range(of: marker),
              markerRange.lowerBound >= 4 else {
            return nil
        }
        let sizeOffset = markerRange.lowerBound - 4
        let sizeBytes = self[sizeOffset..<markerRange.lowerBound]
        let size = sizeBytes.reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        guard size >= 8,
              sizeOffset + Int(size) <= count else {
            return nil
        }
        return self[sizeOffset..<(sizeOffset + Int(size))]
    }
}
