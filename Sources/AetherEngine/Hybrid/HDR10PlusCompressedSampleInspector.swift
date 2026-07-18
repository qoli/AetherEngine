import Foundation
import Libavutil

enum HEVCCompressedSampleFraming: Sendable, Equatable {
    case annexB
    case lengthPrefixed(lengthFieldBytes: Int)
}

enum HDR10PlusCompressedSampleInspection: Sendable, Equatable {
    case notDetected
    case validated(t35PayloadByteCount: Int)
    case malformedHDR10PlusMetadata
    case malformedCompressedSample
    case validatorUnavailable
}

enum HDR10PlusCompressedSampleExtraction: Sendable, Equatable {
    case notDetected
    case validated(t35Payload: Data)
    case malformedHDR10PlusMetadata
    case malformedCompressedSample
    case validatorUnavailable
}

/// Bounded, decoder-free inspection of one compressed HEVC sample.
///
/// The scanner recognizes only `user_data_registered_itu_t_t35` SEI messages whose registered
/// identifier is HDR10+ (`B5 00 3C 00 01 04`). A matching identifier is then parsed by the same
/// FFmpeg ST 2094-40 validator used by the decoder. A matching-but-invalid payload is an explicit
/// failure; arbitrary occurrences of the six identifier bytes inside slice data are ignored.
enum HDR10PlusCompressedSampleInspector {
    private static let registeredIdentifier: [UInt8] = [
        0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04,
    ]
    private static let userDataRegisteredITUTT35PayloadType = 4
    private static let prefixSEINALUnitType = 39
    private static let suffixSEINALUnitType = 40

    static func inspect(
        _ sample: Data,
        framing: HEVCCompressedSampleFraming
    ) -> HDR10PlusCompressedSampleInspection {
        switch extract(sample, framing: framing) {
        case .notDetected:
            return .notDetected
        case .validated(let payload):
            return .validated(
                t35PayloadByteCount: payload.count
            )
        case .malformedHDR10PlusMetadata:
            return .malformedHDR10PlusMetadata
        case .malformedCompressedSample:
            return .malformedCompressedSample
        case .validatorUnavailable:
            return .validatorUnavailable
        }
    }

    static func extract(
        _ sample: Data,
        framing: HEVCCompressedSampleFraming
    ) -> HDR10PlusCompressedSampleExtraction {
        let bytes = [UInt8](sample)
        guard !bytes.isEmpty else {
            return .malformedCompressedSample
        }
        let units: [[UInt8]]
        switch framing {
        case .annexB:
            guard let parsed = annexBNALUnits(bytes) else {
                return .malformedCompressedSample
            }
            units = parsed
        case .lengthPrefixed(let lengthFieldBytes):
            guard let parsed = lengthPrefixedNALUnits(
                bytes,
                lengthFieldBytes: lengthFieldBytes
            ) else {
                return .malformedCompressedSample
            }
            units = parsed
        }

        for unit in units {
            guard unit.count >= 2,
                  (unit[0] & 0x80) == 0,
                  (unit[1] & 0x07) != 0 else {
                return .malformedCompressedSample
            }
            let nalUnitType = Int((unit[0] >> 1) & 0x3F)
            guard nalUnitType == prefixSEINALUnitType
                    || nalUnitType == suffixSEINALUnitType else {
                continue
            }
            let inspection = extractSEIRBSP(
                removingEmulationPrevention(from: unit.dropFirst(2))
            )
            switch inspection {
            case .notDetected:
                continue
            case .validated,
                 .malformedHDR10PlusMetadata,
                 .malformedCompressedSample,
                 .validatorUnavailable:
                return inspection
            }
        }
        return .notDetected
    }

    private static func annexBNALUnits(
        _ bytes: [UInt8]
    ) -> [[UInt8]]? {
        guard let first = startCode(in: bytes, from: 0),
              bytes[..<first.offset].allSatisfy({ $0 == 0 }) else {
            return nil
        }
        var units: [[UInt8]] = []
        var current = first
        while true {
            let payloadStart = current.offset + current.length
            if let next = startCode(in: bytes, from: payloadStart) {
                guard next.offset > payloadStart else {
                    return nil
                }
                units.append(Array(bytes[payloadStart..<next.offset]))
                current = next
            } else {
                guard payloadStart < bytes.count else {
                    return nil
                }
                units.append(Array(bytes[payloadStart..<bytes.count]))
                break
            }
        }
        return units.isEmpty ? nil : units
    }

    private static func startCode(
        in bytes: [UInt8],
        from start: Int
    ) -> (offset: Int, length: Int)? {
        guard bytes.count >= 3, start <= bytes.count - 3 else {
            return nil
        }
        var index = start
        while index <= bytes.count - 3 {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 {
                    return (index, 3)
                }
                if index + 3 < bytes.count,
                   bytes[index + 2] == 0,
                   bytes[index + 3] == 1 {
                    return (index, 4)
                }
            }
            index += 1
        }
        return nil
    }

    private static func lengthPrefixedNALUnits(
        _ bytes: [UInt8],
        lengthFieldBytes: Int
    ) -> [[UInt8]]? {
        guard (1...4).contains(lengthFieldBytes) else {
            return nil
        }
        var units: [[UInt8]] = []
        var cursor = 0
        while cursor < bytes.count {
            guard cursor + lengthFieldBytes <= bytes.count else {
                return nil
            }
            var length = 0
            for byte in bytes[cursor..<(cursor + lengthFieldBytes)] {
                length = (length << 8) | Int(byte)
            }
            cursor += lengthFieldBytes
            guard length > 0, cursor + length <= bytes.count else {
                return nil
            }
            units.append(Array(bytes[cursor..<(cursor + length)]))
            cursor += length
        }
        return units.isEmpty ? nil : units
    }

    private static func removingEmulationPrevention(
        from bytes: ArraySlice<UInt8>
    ) -> [UInt8] {
        let source = Array(bytes)
        var result: [UInt8] = []
        result.reserveCapacity(source.count)
        var consecutiveZeroes = 0
        var index = 0
        while index < source.count {
            let byte = source[index]
            if consecutiveZeroes >= 2,
               byte == 0x03,
               index + 1 < source.count,
               source[index + 1] <= 0x03 {
                consecutiveZeroes = 0
                index += 1
                continue
            }
            result.append(byte)
            consecutiveZeroes = byte == 0
                ? consecutiveZeroes + 1
                : 0
            index += 1
        }
        return result
    }

    private static func extractSEIRBSP(
        _ bytes: [UInt8]
    ) -> HDR10PlusCompressedSampleExtraction {
        var cursor = 0
        while cursor < bytes.count {
            if bytes[cursor] == 0x80,
               bytes[(cursor + 1)...].allSatisfy({ $0 == 0 }) {
                return .notDetected
            }
            guard let payloadType = readExtendedValue(
                bytes,
                cursor: &cursor
            ),
            let payloadSize = readExtendedValue(
                bytes,
                cursor: &cursor
            ),
            payloadSize >= 0,
            cursor + payloadSize <= bytes.count else {
                return .malformedCompressedSample
            }
            let payload = Array(
                bytes[cursor..<(cursor + payloadSize)]
            )
            cursor += payloadSize
            guard payloadType == userDataRegisteredITUTT35PayloadType,
                  payload.starts(with: registeredIdentifier) else {
                continue
            }
            guard payload.count > registeredIdentifier.count else {
                return .malformedHDR10PlusMetadata
            }
            switch validateApplicationPayload(
                payload.dropFirst(registeredIdentifier.count)
            ) {
            case .valid:
                return .validated(
                    t35Payload: Data(payload)
                )
            case .invalid:
                return .malformedHDR10PlusMetadata
            case .unavailable:
                return .validatorUnavailable
            }
        }
        return .notDetected
    }

    private static func readExtendedValue(
        _ bytes: [UInt8],
        cursor: inout Int
    ) -> Int? {
        var value = 0
        while cursor < bytes.count, bytes[cursor] == 0xFF {
            guard value <= Int.max - 255 else {
                return nil
            }
            value += 255
            cursor += 1
        }
        guard cursor < bytes.count,
              value <= Int.max - Int(bytes[cursor]) else {
            return nil
        }
        value += Int(bytes[cursor])
        cursor += 1
        return value
    }

    private enum ValidationResult {
        case valid
        case invalid
        case unavailable
    }

    private static func validateApplicationPayload(
        _ payload: ArraySlice<UInt8>
    ) -> ValidationResult {
        guard let metadata = av_dynamic_hdr_plus_alloc(nil) else {
            return .unavailable
        }
        defer { av_free(metadata) }
        let data = Array(payload)
        let result = data.withUnsafeBytes { rawBuffer -> Int32 in
            guard let baseAddress = rawBuffer.bindMemory(
                to: UInt8.self
            ).baseAddress else {
                return -1
            }
            return av_dynamic_hdr_plus_from_t35(
                metadata,
                baseAddress,
                data.count
            )
        }
        return result >= 0 ? .valid : .invalid
    }
}
