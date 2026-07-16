import XCTest
@testable import AetherEngine

final class BMFFVideoSampleEntryInspectorTests: XCTestCase {
    private func uint32(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)
        ])
    }

    private func box(_ type: String, _ payload: Data) -> Data {
        var data = uint32(UInt32(payload.count + 8))
        data.append(type.data(using: .ascii)!)
        data.append(payload)
        return data
    }

    private func initSegment(sampleEntry: String) -> Data {
        var entry = uint32(16)
        entry.append(sampleEntry.data(using: .ascii)!)
        entry.append(Data(repeating: 0, count: 8))

        var stsdPayload = Data(repeating: 0, count: 4) // FullBox version/flags
        stsdPayload.append(uint32(1))
        stsdPayload.append(entry)
        let stbl = box("stbl", box("stsd", stsdPayload))
        return box("moov", box("trak", box("mdia", box("minf", stbl))))
    }

    func testReadsHEV1FromSampleDescription() {
        XCTAssertEqual(
            BMFFVideoSampleEntryInspector.inspect(initSegment: initSegment(sampleEntry: "hev1")),
            .hev1
        )
    }

    func testReadsDVH1FromSampleDescription() {
        XCTAssertEqual(
            BMFFVideoSampleEntryInspector.inspect(initSegment: initSegment(sampleEntry: "dvh1")),
            .dvh1
        )
    }

    func testDoesNotGuessFromMalformedData() {
        XCTAssertEqual(
            BMFFVideoSampleEntryInspector.inspect(initSegment: Data("hvc1".utf8)),
            .unknown
        )
    }
}
