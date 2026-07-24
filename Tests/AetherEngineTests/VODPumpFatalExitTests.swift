import Testing
@testable import AetherEngine

/// A VOD transport exit must either reopen the exact source or publish a
/// typed permanent failure; it must never leave the loopback playlist parked.
struct VODPumpRecoveryTests {

    @Test("VOD readError with nothing produced requires source recovery")
    func zeroProgressReadErrorRequiresRecovery() {
        #expect(HLSVideoEngine.requiresVODSourceRecovery(
            reason: .readError(code: -1), isLive: false,
            packetsWritten: 0, cachedSegments: 0))
    }

    @Test("Mid-session VOD readError also requires source recovery")
    func midSessionReadErrorRequiresRecovery() {
        #expect(HLSVideoEngine.requiresVODSourceRecovery(
            reason: .readError(code: -5), isLive: false,
            packetsWritten: 4821, cachedSegments: 0))
    }

    @Test("Cached segments do not permit a dead VOD reader")
    func cachedSegmentsStillRequireRecovery() {
        #expect(HLSVideoEngine.requiresVODSourceRecovery(
            reason: .readError(code: -1), isLive: false,
            packetsWritten: 0, cachedSegments: 12))
    }

    @Test("Live readError is owned by the live reopen loop")
    func liveReadErrorIsNotVODRecovery() {
        #expect(!HLSVideoEngine.requiresVODSourceRecovery(
            reason: .readError(code: -1), isLive: true,
            packetsWritten: 0, cachedSegments: 0))
    }

    @Test("Zero-output VOD EOF requires source recovery")
    func zeroOutputEOFRequiresRecovery() {
        #expect(HLSVideoEngine.requiresVODSourceRecovery(
            reason: .eof, isLive: false,
            packetsWritten: 0, cachedSegments: 0))
    }

    @Test("Natural VOD EOF and teardown do not recover")
    func completedEOFAndStopDoNotRecover() {
        #expect(!HLSVideoEngine.requiresVODSourceRecovery(
            reason: .eof, isLive: false,
            packetsWritten: 20, cachedSegments: 4))
        #expect(!HLSVideoEngine.requiresVODSourceRecovery(
            reason: .stopRequested, isLive: false,
            packetsWritten: 0, cachedSegments: 0))
    }
}
