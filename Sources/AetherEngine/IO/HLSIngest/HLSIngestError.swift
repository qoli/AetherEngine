import Foundation

/// Typed terminal errors from one Aether-owned live HLS ingest attempt.
///
/// A same-request retry or reopen remains an Aether decision and must retain
/// the canonical upstream, credentials, DRM meaning, and provenance. These
/// cases do not authorize the host to silently replace the request with a
/// Jellyfin- or otherwise server-mediated URL.
public enum HLSIngestError: Error, Equatable, CustomStringConvertible {
    case playlistUnreachable(status: Int)
    case playlistInvalid(reason: String)
    /// SAMPLE-AES / SAMPLE-AES-CTR, or AES-128 tag with no URI. Plain AES-128 clear-key is handled by `HLSSegmentDecryptor`.
    case encryptedNotSupported
    /// AES-128 key fetch failed or CommonCrypto rejected key/IV/ciphertext.
    /// Fails explicitly rather than feeding ciphertext to the demuxer or
    /// selecting an alternate source.
    case segmentDecryptFailed(reason: String)
    /// EXT-X-MAP present, or first segment is not TS (main) or TS/packed-audio (companion). fMP4-segment HLS is a later phase.
    case unsupportedSegmentFormat
    case ingestStalled
    /// Demuxed-audio rendition in a shape the ingest cannot handle: unresolvable URI, packed audio without a parsable PRIV timestamp (ARD-style, device repro: Das Erste HD), or no program-clock anchor to align audio without risking silent A/V desync.
    case demuxedAudioNotSupported

    public var description: String {
        switch self {
        case .playlistUnreachable(let status): "playlistUnreachable(\(status))"
        case .playlistInvalid(let reason): "playlistInvalid(\(reason))"
        case .encryptedNotSupported: "encryptedNotSupported"
        case .segmentDecryptFailed(let reason): "segmentDecryptFailed(\(reason))"
        case .unsupportedSegmentFormat: "unsupportedSegmentFormat"
        case .ingestStalled: "ingestStalled"
        case .demuxedAudioNotSupported: "demuxedAudioNotSupported"
        }
    }
}
