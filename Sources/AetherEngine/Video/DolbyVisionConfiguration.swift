import Foundation
import Libavcodec
import Libavformat
import Libavutil

/// Dolby Vision profiles that Aether's hybrid sample-buffer path has an exact,
/// device-verifiable presentation contract for.
public enum AetherDolbyVisionProfile: String, Sendable, Equatable, Hashable {
    /// HEVC Main10 with an HLG-compatible base layer (profile 8, compatibility ID 4).
    case profile84
}

/// Exact fields carried by FFmpeg's `AV_PKT_DATA_DOVI_CONF` side data and the
/// ISO BMFF `dvcC` / `dvvC` configuration record.
///
/// Keeping every field prevents route admission from treating a manifest codec
/// token or profile number alone as proof that VideoToolbox can preserve the
/// source's Dolby Vision metadata.
public struct AetherDolbyVisionConfiguration:
    Sendable,
    Equatable,
    Hashable
{
    public let versionMajor: UInt8
    public let versionMinor: UInt8
    public let profile: UInt8
    public let level: UInt8
    public let rpuPresent: Bool
    public let enhancementLayerPresent: Bool
    public let baseLayerPresent: Bool
    public let baseLayerSignalCompatibilityID: UInt8
    public let metadataCompression: UInt8

    public init(
        versionMajor: UInt8,
        versionMinor: UInt8,
        profile: UInt8,
        level: UInt8,
        rpuPresent: Bool,
        enhancementLayerPresent: Bool,
        baseLayerPresent: Bool,
        baseLayerSignalCompatibilityID: UInt8,
        metadataCompression: UInt8
    ) {
        self.versionMajor = versionMajor
        self.versionMinor = versionMinor
        self.profile = profile
        self.level = level
        self.rpuPresent = rpuPresent
        self.enhancementLayerPresent = enhancementLayerPresent
        self.baseLayerPresent = baseLayerPresent
        self.baseLayerSignalCompatibilityID =
            baseLayerSignalCompatibilityID
        self.metadataCompression = metadataCompression
    }

    /// The hybrid route intentionally admits only the exact P8.4 shape that
    /// Apple documents for an HLG-compatible HEVC base layer.
    public var verifiedHybridProfile: AetherDolbyVisionProfile? {
        guard versionMajor == 1,
              versionMinor == 0,
              profile == 8,
              level > 0,
              level <= 63,
              rpuPresent,
              !enhancementLayerPresent,
              baseLayerPresent,
              baseLayerSignalCompatibilityID == 4,
              metadataCompression == 0 else {
            return nil
        }
        return .profile84
    }

    /// Serialize the 24-byte `dvvC` payload used by
    /// `kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms`.
    /// Callers must first require `verifiedHybridProfile == .profile84`.
    func profile84DVVCData() -> Data? {
        guard verifiedHybridProfile == .profile84 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 24)
        bytes[0] = versionMajor
        bytes[1] = versionMinor
        let packed =
            (UInt16(profile & 0x7F) << 9)
            | (UInt16(level & 0x3F) << 3)
            | (rpuPresent ? 1 << 2 : 0)
            | (enhancementLayerPresent ? 1 << 1 : 0)
            | (baseLayerPresent ? 1 : 0)
        bytes[2] = UInt8((packed >> 8) & 0xFF)
        bytes[3] = UInt8(packed & 0xFF)
        bytes[4] =
            ((baseLayerSignalCompatibilityID & 0x0F) << 4)
            | ((metadataCompression & 0x03) << 2)
        return Data(bytes)
    }
}

extension AetherEngine {
    /// Read the authoritative Dolby Vision configuration from FFmpeg coded
    /// side data. Missing or truncated data is not inferred from an RPU NAL or
    /// a manifest codec token.
    nonisolated static func dolbyVisionConfiguration(
        stream: UnsafeMutablePointer<AVStream>
    ) -> AetherDolbyVisionConfiguration? {
        guard let codecParameters = stream.pointee.codecpar else {
            return nil
        }
        return dolbyVisionConfiguration(
            codecParameters: UnsafePointer(codecParameters)
        )
    }

    nonisolated static func dolbyVisionConfiguration(
        codecParameters:
            UnsafePointer<AVCodecParameters>
    ) -> AetherDolbyVisionConfiguration? {
        let count = Int(codecParameters.pointee.nb_coded_side_data)
        guard count > 0,
              let sideData = codecParameters.pointee.coded_side_data else {
            return nil
        }
        for index in 0..<count {
            let item = sideData[index]
            guard item.type == AV_PKT_DATA_DOVI_CONF else { continue }
            guard let raw = item.data,
                  item.size >= MemoryLayout<
                    AVDOVIDecoderConfigurationRecord
                  >.size else {
                return nil
            }
            let record = raw.withMemoryRebound(
                to: AVDOVIDecoderConfigurationRecord.self,
                capacity: 1
            ) { $0.pointee }
            return AetherDolbyVisionConfiguration(
                versionMajor: record.dv_version_major,
                versionMinor: record.dv_version_minor,
                profile: record.dv_profile,
                level: record.dv_level,
                rpuPresent: record.rpu_present_flag != 0,
                enhancementLayerPresent:
                    record.el_present_flag != 0,
                baseLayerPresent: record.bl_present_flag != 0,
                baseLayerSignalCompatibilityID:
                    record.dv_bl_signal_compatibility_id,
                metadataCompression: record.dv_md_compression
            )
        }
        return nil
    }

    /// Positive source evidence for the only currently specified hybrid Dolby
    /// Vision base layer. This is evaluated during preflight and repeated when
    /// the decoder opens so a changed or contradictory resource cannot pass on
    /// its `dvvC` compatibility ID alone.
    nonisolated static func hasVerifiedDolbyVisionProfile84BaseLayer(
        stream: UnsafeMutablePointer<AVStream>
    ) -> Bool {
        guard let codecParameters = stream.pointee.codecpar else {
            return false
        }
        let parameters = codecParameters.pointee
        guard parameters.codec_id == AV_CODEC_ID_HEVC,
              let extradata = parameters.extradata,
              parameters.extradata_size > 1,
              extradata[0] == 1,
              extradata[1] & 0x1F == 2,
              parameters.color_primaries == AVCOL_PRI_BT2020,
              parameters.color_trc == AVCOL_TRC_ARIB_STD_B67,
              parameters.color_space == AVCOL_SPC_BT2020_NCL else {
            return false
        }
        return true
    }
}
