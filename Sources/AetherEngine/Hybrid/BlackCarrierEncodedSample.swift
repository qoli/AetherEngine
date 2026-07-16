import CryptoKit
import Foundation

public enum BlackCarrierEncodedSampleError: Error, LocalizedError, Sendable, Equatable {
    case resourceMissing(name: String)
    case resourceUnreadable(name: String)
    case invalidHashManifest
    case hashManifestMismatch(expected: String, actual: String)
    case hashMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .resourceMissing(let name):
            return "Black carrier resource is missing: \(name)"
        case .resourceUnreadable(let name):
            return "Black carrier resource cannot be read: \(name)"
        case .invalidHashManifest:
            return "Black carrier hash manifest is invalid"
        case .hashManifestMismatch(let expected, let actual):
            return "Black carrier hash manifest mismatch: expected \(expected), got \(actual)"
        case .hashMismatch(let expected, let actual):
            return "Black carrier encoded sample mismatch: expected \(expected), got \(actual)"
        }
    }
}

/// Verified, pre-encoded H.264 IDR asset for the AVKit black carrier.
///
/// Runtime code must reuse this payload and assign source-axis timestamps while muxing. It must
/// not create a VideoToolbox or FFmpeg video encoder. The checked-in manifest is useful for
/// release auditing, while this compiled constant prevents changing the asset and manifest
/// together without also changing the engine contract.
public enum BlackCarrierEncodedSample {
    public static let approvedSHA256 =
        "a410d40376c11c10df2e5fdc7709ad1438fd64e7f5672479ac18bd3fd5203c29"

    private static let resourceName = "black-carrier-idr"
    private static let mediaExtension = "mp4"
    private static let manifestExtension = "sha256"

    public static func verifiedMP4Data() throws -> Data {
        let manifestHash = try bundledManifestSHA256()
        guard manifestHash == approvedSHA256 else {
            throw BlackCarrierEncodedSampleError.hashManifestMismatch(
                expected: approvedSHA256,
                actual: manifestHash
            )
        }

        let data = try bundledResourceData(extension: mediaExtension)
        return try verify(data: data)
    }

    static func bundledManifestSHA256() throws -> String {
        let data = try bundledResourceData(extension: manifestExtension)
        guard let text = String(data: data, encoding: .utf8) else {
            throw BlackCarrierEncodedSampleError.invalidHashManifest
        }
        let hash = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard hash.count == 64,
              hash.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }) else {
            throw BlackCarrierEncodedSampleError.invalidHashManifest
        }
        return hash
    }

    @discardableResult
    static func verify(data: Data) throws -> Data {
        let actual = sha256Hex(data)
        guard actual == approvedSHA256 else {
            throw BlackCarrierEncodedSampleError.hashMismatch(
                expected: approvedSHA256,
                actual: actual
            )
        }
        return data
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func bundledResourceData(extension fileExtension: String) throws -> Data {
        let filename = "\(resourceName).\(fileExtension)"
        guard let url = Bundle.module.url(
            forResource: resourceName,
            withExtension: fileExtension
        ) else {
            throw BlackCarrierEncodedSampleError.resourceMissing(name: filename)
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw BlackCarrierEncodedSampleError.resourceUnreadable(name: filename)
        }
        return data
    }
}
