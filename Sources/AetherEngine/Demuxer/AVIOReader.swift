import Foundation
import os
import Libavformat
import Libavutil

/// Custom AVIO context feeding FFmpeg via URLSession. Three modes:
/// - **Persistent** (known size + prefetch=true, playback path): single long-lived
///   `Range: bytes=<pos>-` GET into a sliding window; reconnects on drop/429/503.
///   Fix for AetherEngine#25 (CDN stutter collapsing playback). See `readPersistent`.
/// - **Seekable chunked** (known size + prefetch=false, still/frame-extraction):
///   discrete Range chunks for random access. See `readSeekable`.
/// - **Streaming** (size=-1): forward-only sequential reads with generation-fenced
///   same-source reconnect and clean-response EOF confirmation. See `readStreaming`.
///
/// AVIO callbacks run on the demux queue; prefetch/delivery on background queues.
/// Shared state protected by locks.

/// Dedupes `ReaderNetworkPhase` emissions so a flapping origin does not spam the callback (#85).
/// Mutated only on the demux thread (the read loop), so it needs no locking.
struct NetworkPhaseGate {
    private var last: ReaderNetworkPhase = .flowing
    mutating func shouldEmit(_ next: ReaderNetworkPhase) -> Bool {
        guard next != last else { return false }
        last = next
        return true
    }
}

struct AVIOPersistentRetryDecision: Sendable, Equatable {
    let attempt: Int
    let delaySeconds: TimeInterval
    fileprivate let progressGeneration: UInt64
    let retryLogEmission:
        AetherBoundedRetryLogEmission?
    let firstRetryLogCause: String?
}

enum AVIOPersistentRetryWaitOutcome:
    Sendable,
    Equatable
{
    case retry
    case progressed
    case cancelled
}

struct AVIOStreamingResumePlan:
    Sendable,
    Equatable
{
    let discardPrefixBytes: Int64
    let validator: SourceByteStoreValidator?
}

/// One cancellation-aware retry ledger for the production persistent reader.
///
/// Transport failures are intentionally unbounded. Only unique source-byte
/// progress resets the attempt sequence; cancellation permanently closes
/// admission so a late callback cannot start another connection.
final class AVIOPersistentRetryController:
    @unchecked Sendable
{
    private static let maximumRetryAfterSeconds:
        TimeInterval = 30

    private let condition = NSCondition()
    private let policy: AetherPlaybackLivenessPolicy
    private let retryLogClock: any AetherBoundedRetryLogClock
    private let onWaitStarted:
        (@Sendable () -> Void)?
    private var attempt = 0
    private var progressGeneration: UInt64 = 0
    private var isCancelled = false
    private var retryLogCadence:
        AetherBoundedRetryLogCadence
    private var firstRetryLogCause: String?

    init(
        policy: AetherPlaybackLivenessPolicy =
            .production,
        retryLogClock: any AetherBoundedRetryLogClock =
            AetherSystemBoundedRetryLogClock(),
        onWaitStarted: (@Sendable () -> Void)? =
            nil
    ) {
        self.policy = policy
        self.retryLogClock = retryLogClock
        self.onWaitStarted = onWaitStarted
        retryLogCadence = AetherBoundedRetryLogCadence(
            policy: policy
        )
    }

    var progressToken: UInt64 {
        condition.lock()
        defer { condition.unlock() }
        return progressGeneration
    }

    func noProgressWindowSeconds(
        forAttempt attempt: Int
    ) -> TimeInterval {
        policy.noProgressWindowSeconds(
            forAttempt: attempt
        )
    }

    /// Returns nil if progress raced the observed failure or cancellation has
    /// already fenced retry admission.
    func recordTransientFailure(
        observedProgressToken: UInt64,
        retryAfterSeconds: TimeInterval = 0,
        retryLogCause: String? = nil
    ) -> AVIOPersistentRetryDecision? {
        condition.lock()
        defer { condition.unlock() }
        guard !isCancelled,
              observedProgressToken
                == progressGeneration else {
            return nil
        }
        if attempt < Int.max {
            attempt += 1
        }
        let retryAfter = Self.clampRetryAfter(
            retryAfterSeconds
        )
        let retryLogEmission: AetherBoundedRetryLogEmission?
        let firstRetryLogCause: String?
        if let retryLogCause {
            self.firstRetryLogCause = self.firstRetryLogCause
                ?? retryLogCause
            retryLogEmission = retryLogCadence.recordFailure(
                now: retryLogClock.now()
            )
            firstRetryLogCause = self.firstRetryLogCause
        } else {
            retryLogEmission = nil
            firstRetryLogCause = nil
        }
        return AVIOPersistentRetryDecision(
            attempt: attempt,
            delaySeconds: max(
                policy.retryBackoffSeconds(
                    forAttempt: attempt
                ),
                retryAfter
            ),
            progressGeneration: progressGeneration,
            retryLogEmission: retryLogEmission,
            firstRetryLogCause: firstRetryLogCause
        )
    }

    func recordProgress() {
        condition.lock()
        guard !isCancelled else {
            condition.unlock()
            return
        }
        attempt = 0
        progressGeneration &+= 1
        retryLogCadence.resetAfterProgress()
        firstRetryLogCause = nil
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilRetry(
        _ decision: AVIOPersistentRetryDecision,
        shouldAbort: @Sendable () -> Bool = {
            false
        }
    ) -> AVIOPersistentRetryWaitOutcome {
        condition.lock()
        defer { condition.unlock() }
        guard !isCancelled,
              !shouldAbort() else {
            return .cancelled
        }
        guard decision.progressGeneration
                == progressGeneration else {
            return .progressed
        }
        guard decision.delaySeconds > 0 else {
            return .retry
        }

        let deadline = Date(
            timeIntervalSinceNow:
                decision.delaySeconds
        )
        onWaitStarted?()
        while true {
            if isCancelled || shouldAbort() {
                return .cancelled
            }
            if decision.progressGeneration
                != progressGeneration {
                return .progressed
            }
            let now = Date()
            if now >= deadline {
                return .retry
            }
            // The short ceiling observes a bounded read deadline even when it
            // is armed from outside this controller. markClosed()/progress
            // still broadcast and wake immediately.
            _ = condition.wait(
                until: min(
                    deadline,
                    now.addingTimeInterval(0.1)
                )
            )
        }
    }

    func cancel() {
        condition.lock()
        isCancelled = true
        condition.broadcast()
        condition.unlock()
    }

    private static func clampRetryAfter(
        _ seconds: TimeInterval
    ) -> TimeInterval {
        guard !seconds.isNaN else { return 0 }
        return min(
            max(seconds, 0),
            maximumRetryAfterSeconds
        )
    }
}

/// Privacy-safe monotonic unique-byte counters emitted by AVIO readers that
/// share one launch ledger.
///
/// Absolute byte intervals never leave the ledger. The callback contains no
/// URL, offset, response header or credential material. A byte is attributed
/// to whichever path first made that exact interval available, so reconnects,
/// repeated ranges and later store reads cannot manufacture liveness.
struct AetherFetchedByteProgress: Sendable, Equatable {
    let originBytesFetched: Int64
    let sourceStoreBytesReused: Int64

    var totalAdvancedBytes: Int64 {
        originBytesFetched &+ sourceStoreBytesReused
    }
}

enum AetherFetchedByteProgressKind: Sendable {
    case origin
    case sourceStore
}

/// Session-scoped interval union used across progressive preflight attempts
/// and by the retained first playback Demuxer.
///
/// The merged intervals are deliberately private. Only aggregate unique-byte
/// counts cross the AVIO boundary.
final class AetherFetchedByteProgressLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var intervals: [Range<Int64>] = []
    private var originBytesFetched: Int64 = 0
    private var sourceStoreBytesReused: Int64 = 0

    @discardableResult
    func record(
        offset: Int64,
        count: Int,
        kind: AetherFetchedByteProgressKind
    ) -> AetherFetchedByteProgress? {
        guard offset >= 0, count > 0 else { return nil }
        let (upperBound, overflow) = offset.addingReportingOverflow(
            Int64(count)
        )
        guard !overflow, upperBound > offset else { return nil }

        lock.lock()
        let delta = insertUniqueRange(
            offset..<upperBound
        )
        guard delta > 0 else {
            lock.unlock()
            return nil
        }
        switch kind {
        case .origin:
            originBytesFetched &+= delta
        case .sourceStore:
            sourceStoreBytesReused &+= delta
        }
        let snapshot = AetherFetchedByteProgress(
            originBytesFetched: originBytesFetched,
            sourceStoreBytesReused: sourceStoreBytesReused
        )
        lock.unlock()
        return snapshot
    }

    var snapshot: AetherFetchedByteProgress {
        lock.lock()
        defer { lock.unlock() }
        return AetherFetchedByteProgress(
            originBytesFetched: originBytesFetched,
            sourceStoreBytesReused: sourceStoreBytesReused
        )
    }

    /// Inserts into a sorted, disjoint interval union and returns only the
    /// newly covered byte count. Adjacent ranges are coalesced as well.
    private func insertUniqueRange(_ proposed: Range<Int64>) -> Int64 {
        var uniqueDelta =
            proposed.upperBound - proposed.lowerBound
        var mergedLower = proposed.lowerBound
        var mergedUpper = proposed.upperBound
        var replacement: [Range<Int64>] = []
        replacement.reserveCapacity(intervals.count + 1)
        var didInsert = false

        for existing in intervals {
            if existing.upperBound < mergedLower {
                replacement.append(existing)
                continue
            }
            if existing.lowerBound > mergedUpper {
                if !didInsert {
                    replacement.append(
                        mergedLower..<mergedUpper
                    )
                    didInsert = true
                }
                replacement.append(existing)
                continue
            }

            let overlapLower = max(
                proposed.lowerBound,
                existing.lowerBound
            )
            let overlapUpper = min(
                proposed.upperBound,
                existing.upperBound
            )
            if overlapUpper > overlapLower {
                uniqueDelta -= overlapUpper - overlapLower
            }
            mergedLower = min(
                mergedLower,
                existing.lowerBound
            )
            mergedUpper = max(
                mergedUpper,
                existing.upperBound
            )
        }
        if !didInsert {
            replacement.append(mergedLower..<mergedUpper)
        }
        intervals = replacement
        return uniqueDelta
    }
}

/// Counts attempt-owned URLSession tasks through their terminal delegate
/// callbacks. Cancellation only closes admission; quiescence is reached when
/// every token completes.
final class AetherIOQuiescenceTracker: @unchecked Sendable {
    private let condition = NSCondition()
    private var acceptsNewActivity = true
    private var activeActivityCount = 0

    func beginActivity() -> AetherIOActivityToken? {
        condition.lock()
        defer { condition.unlock() }
        guard acceptsNewActivity else { return nil }
        activeActivityCount += 1
        return AetherIOActivityToken(tracker: self)
    }

    func beginShutdown() {
        condition.lock()
        acceptsNewActivity = false
        if activeActivityCount == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }

    func waitForShutdown() {
        condition.lock()
        acceptsNewActivity = false
        while activeActivityCount > 0 {
            condition.wait()
        }
        condition.unlock()
    }

    fileprivate func completeActivity() {
        condition.lock()
        precondition(activeActivityCount > 0)
        activeActivityCount -= 1
        if !acceptsNewActivity,
           activeActivityCount == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }
}

final class AetherIOActivityToken: @unchecked Sendable {
    private let lock = NSLock()
    private var tracker:
        AetherIOQuiescenceTracker?

    fileprivate init(
        tracker: AetherIOQuiescenceTracker
    ) {
        self.tracker = tracker
    }

    func complete() {
        lock.lock()
        let tracker = tracker
        self.tracker = nil
        lock.unlock()
        tracker?.completeActivity()
    }
}

final class AVIOReader: AVIOProvider, @unchecked Sendable {

    private let url: URL
    private let extraHeaders: [String: String]
    private let sourceByteStore: SourceByteStore?
    private let ioQuiescence =
        AetherIOQuiescenceTracker()
    /// Session config factory. Short-lived probes/chunks get a 60s resource timeout;
    /// long-lived persistent/streaming connections omit it (fires mid-stream, NSURLError
    /// -1001; stall detection is handled by `connStallTimeout`). `urlCache = nil` avoids
    /// the "N URLCaches racing async invalidation" leak (reverted in fef8ef4).
    private static func makeSessionConfig(longLived: Bool = false) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        if !longLived {
            config.timeoutIntervalForResource = 60
        }
        config.httpMaximumConnectionsPerHost = 2
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // No URLCache instance, kills the in-memory cache that the
        // long-lived-session fix from fef8ef4 was working around.
        config.urlCache = nil
        return config
    }
    private var position: Int64 = 0
    private var fileSize: Int64 = -1
    private var sourceStoreReadEnabled = false
    private var usesValidatedCompleteSourceStore = false

    private let terminalErrorLock = NSLock()
    private var _terminalHTTPError: AVIOReaderError?
    var terminalError: AVIOReaderError? {
        terminalErrorLock.lock()
        let httpError = _terminalHTTPError
        terminalErrorLock.unlock()
        if let httpError {
            return httpError
        }
        return sourceStoreFailure.map(
            AVIOReaderError.sourceByteStore
        )
    }

    private func recordTerminalReaderError(
        _ error: AVIOReaderError
    ) {
        terminalErrorLock.lock()
        if _terminalHTTPError == nil {
            _terminalHTTPError = error
        }
        terminalErrorLock.unlock()
        persistentRetryController.cancel()
    }

    private let sourceStoreFailureLock = NSLock()
    private var _sourceStoreFailure: SourceByteStoreError?
    private var sourceStoreFailure: SourceByteStoreError? {
        sourceStoreFailureLock.lock()
        defer { sourceStoreFailureLock.unlock() }
        return _sourceStoreFailure
    }
    private func recordSourceStoreFailure(_ error: SourceByteStoreError) {
        sourceStoreFailureLock.lock()
        if _sourceStoreFailure == nil {
            _sourceStoreFailure = error
        }
        sourceStoreFailureLock.unlock()
        persistentRetryController.cancel()
    }

    /// Session-scoped unique-range ledger. Progressive preflight installs the
    /// same instance on every quiesced attempt and transfers it with the exact
    /// successful Demuxer.
    var fetchedByteProgressLedger =
        AetherFetchedByteProgressLedger()

    /// Monotonic, privacy-safe unique-byte progress. Set before `open()` by
    /// the owning demuxer.
    var onFetchedByteProgress:
        (@Sendable (AetherFetchedByteProgress) -> Void)?

    private let sourceStoreCounterLock = NSLock()
    private var _sourceStoreBytesServed: Int64 = 0
    var sourceStoreBytesServed: Int64 {
        sourceStoreCounterLock.lock()
        defer { sourceStoreCounterLock.unlock() }
        return _sourceStoreBytesServed
    }

    private func addSourceStoreBytesServed(
        _ count: Int,
        at offset: Int64
    ) {
        guard count > 0 else { return }
        sourceStoreCounterLock.lock()
        _sourceStoreBytesServed &+= Int64(count)
        sourceStoreCounterLock.unlock()
        if let snapshot = fetchedByteProgressLedger.record(
            offset: offset,
            count: count,
            kind: .sourceStore
        ) {
            persistentRetryController.recordProgress()
            onFetchedByteProgress?(snapshot)
        }
    }

    /// Typed source-fetch network phase, pushed on every stall/reconnect/recovery transition (#85).
    /// Mirrors `HLSVideoEngine.onSeekStateChanged`. `@Sendable`: invoked from the demux thread, the
    /// consumer hops to the main actor. Set only on the MAIN playback reader, never the subtitle side reader.
    var onNetworkPhaseChanged: (@Sendable (ReaderNetworkPhase) -> Void)?

    /// Demux-thread-only dedupe for `onNetworkPhaseChanged`.
    private var networkPhaseGate = NetworkPhaseGate()

    /// Emit a phase transition through the gate (demux thread only).
    private func emitNetworkPhase(_ phase: ReaderNetworkPhase) {
        if networkPhaseGate.shouldEmit(phase) {
            onNetworkPhaseChanged?(phase)
        }
    }

    /// Cached CDN URL after redirect resolution; skips proxy hop on subsequent chunks.
    /// Auth-expiry statuses (401/403/404/410) against it invalidate and fall back to
    /// the source URL. See AetherEngine#12.
    private let resolvedURLLock = NSLock()
    private var _resolvedURL: URL?

    private func requestURL() -> URL {
        resolvedURLLock.lock()
        defer { resolvedURLLock.unlock() }
        return _resolvedURL ?? url
    }

    private func cachedResolvedURL() -> URL? {
        resolvedURLLock.lock()
        defer { resolvedURLLock.unlock() }
        return _resolvedURL
    }

    private func recordResolvedURL(_ resolved: URL?) {
        guard let resolved else { return }
        resolvedURLLock.lock()
        defer { resolvedURLLock.unlock() }
        if resolved != url && resolved != _resolvedURL {
            _resolvedURL = resolved
            #if DEBUG
            EngineLog.emit("[AVIOReader] Cached resolved URL host=\(resolved.host ?? "?")", category: .demux)
            #endif
        }
    }

    private func invalidateResolvedURL() {
        resolvedURLLock.lock()
        defer { resolvedURLLock.unlock() }
        if _resolvedURL != nil {
            _resolvedURL = nil
            #if DEBUG
            EngineLog.emit("[AVIOReader] Dropped resolved URL cache (expiry status)", category: .demux)
            #endif
        }
    }

    private static func isResolvedExpiryStatus(_ status: Int) -> Bool {
        return status == 401 || status == 403 || status == 404 || status == 410
    }

    static func terminalHTTPError(
        statusCode: Int,
        responseWasResolvedUpstream: Bool
    ) -> AVIOReaderError? {
        guard isResolvedExpiryStatus(statusCode),
              !responseWasResolvedUpstream else {
            return nil
        }
        return .httpStatus(statusCode: statusCode)
    }

    /// Returns true when the hard status came from a resolved-upstream hop and
    /// the same canonical source should be resolved again. A request that
    /// started at the canonical URL can still reach an expiring signed
    /// upstream through redirects, so the response route — not only the
    /// initial request URL — owns this decision.
    @discardableResult
    private func handleHardHTTPStatus(
        _ statusCode: Int,
        responseWasResolvedUpstream: Bool
    ) -> Bool {
        guard Self.isResolvedExpiryStatus(statusCode) else {
            return false
        }
        if responseWasResolvedUpstream {
            invalidateResolvedURL()
            return true
        }
        if let error = Self.terminalHTTPError(
            statusCode: statusCode,
            responseWasResolvedUpstream: false
        ) {
            recordTerminalReaderError(error)
        }
        return false
    }

    // Cumulative delivered origin bytes since open. This intentionally keeps
    // its historical raw-byte semantics for reconnect and memory diagnostics;
    // progressive liveness uses the separate unique-range ledger above.
    private let counterLock = NSLock()
    private var _cumulativeBytesFetched: Int64 = 0
    var cumulativeBytesFetched: Int64 {
        counterLock.lock()
        defer { counterLock.unlock() }
        return _cumulativeBytesFetched
    }

    private func addBytesFetched(
        _ count: Int,
        at offset: Int64
    ) {
        guard count > 0 else { return }
        counterLock.lock()
        _cumulativeBytesFetched &+= Int64(count)
        counterLock.unlock()
        if let snapshot = fetchedByteProgressLedger.record(
            offset: offset,
            count: count,
            kind: .origin
        ) {
            persistentRetryController.recordProgress()
            onFetchedByteProgress?(snapshot)
        }
    }

    private var isStreaming: Bool { fileSize <= 0 }

    /// #126: a VOD source that resolved no size runs the forward-only streaming reader
    /// (1 MB back-window plus same-source reconnect); it must not be routed onto
    /// seek-dependent paths.
    /// Live keeps true: the persistent reader owns reconnection and live routing never
    /// seeks backward. Meaningful only after `open()` has resolved the mode.
    var isSeekable: Bool { isLive || !isStreaming }

    private(set) var context: UnsafeMutablePointer<AVIOContext>?
    private var buffer: UnsafeMutablePointer<UInt8>?

    // MARK: - Seekable Mode (Range requests)

    /// Default 4 MB. Delegate-based incremental delivery (ChunkFetchDelegate on a
    /// shared long-lived chunkSession) avoids the per-request URLSession task-pool
    /// leak that made 8 MB chunks bleed ~6 MB/s (e327e5e). 4 MB gives ~0.7 s
    /// cold-start on 45 Mbps 4K HEVC. Smaller values add HTTP roundtrip overhead
    /// at 5+ ops/sec without meaningful latency benefit. Still-extraction passes a
    /// smaller value for random-access single-keyframe fetches.
    private let chunkSize: Int
    /// When false, no speculative next-chunk prefetch (random-access: next read
    /// almost always seeks elsewhere, so prefetch would be wasted bandwidth).
    private let prefetchEnabled: Bool
    /// When set, the open-time data connection requests a finite `bytes=0-N` range instead of the
    /// open-ended `bytes=0-` stream (#93 residual). Scopes to the open connection only; read-loop
    /// reconnects and seek reconnects stay open-ended. nil = open-ended everywhere (playback).
    private let boundedInitialFetch: Int64?
    private static let avioBufferSize: Int32 = 256 * 1024  // 256 KB
    private static let streamTrimThreshold = 1024 * 1024  // 1 MB, keep for small backward seeks
    // Backpressure: suspend the streaming task above highWater, resume below lowWater.
    private static let streamHighWater = 64 * 1024 * 1024
    private static let streamLowWater = 32 * 1024 * 1024

    private let bufferLock = NSLock()
    private var currentBuffer = Data()
    private var currentOffset: Int64 = 0
    private var prefetchBuffer: Data?
    private var prefetchOffset: Int64 = 0
    private var isPrefetching = false
    private let prefetchReady = DispatchSemaphore(value: 0)
    private let prefetchQueue = DispatchQueue(label: "com.aetherengine.avio.prefetch", qos: .userInitiated)
    private static let maxRetries = 3

    // MARK: - Streaming Mode (sequential GET)

    private var streamBuffer = Data()
    private var streamBytesRead: Int64 = 0
    private var streamBytesReceived: Int64 = 0
    private var streamConfirmedEOF = false
    private var streamGeneration = 0
    private var streamAttemptAcceptedResponse = false
    private var streamAttemptRetryAfter:
        TimeInterval = 0
    private var streamAttemptDiscardPrefixBytes:
        Int64 = 0
    private var streamAttemptStartBytes: Int64 = 0
    private var streamNoProgressAttempt = 1
    private var streamProgressDeadline =
        Date.distantFuture
    private var streamSourceValidator:
        SourceByteStoreValidator?
    private let streamLock = NSCondition()
    private let streamDataReady = DispatchSemaphore(value: 0)
    #if DEBUG
    private var streamActiveReaderCount = 0
    private var streamMaximumConcurrentReaderCount = 0
    #endif

    // MARK: - Persistent Mode (single forward-streaming connection, playback path)

    // Backpressure: pause delivery above highWater; peak resident window ~22 MB.
    private static let winHighWater = 16 * 1024 * 1024
    // Keep this many bytes behind the cursor for small matroska backward re-reads.
    private static let winLookback = 2 * 1024 * 1024
    // Trim in batches to avoid O(n^2) memmove storm on every 256 KB read.
    private static let winTrimBatch = 4 * 1024 * 1024
    // Forward seeks within this distance keep the live connection; beyond it, reconnect.
    private static let seekKeepForwardLimit = 8 * 1024 * 1024
    // CDN stall threshold: no bytes for this long triggers reconnect.
    private static let connStallTimeout: TimeInterval = 20

    // MARK: - Detour Block Cache (random-access parse reads; AetherEngine#69)

    // A non-faststart / coarsely-interleaved remote MP4 makes the demuxer ping-pong between
    // distant file regions (header, trailing moov, sample data) during find_stream_info /
    // index parse. Each non-sequential read used to tear down + reopen the persistent
    // connection (seekReconnect), so the parse storm hammered the origin into a 429.
    // Instead, serve those random-access reads through the pooled keep-alive chunkSession
    // (the one fetchChunk already uses), caching 4 MB aligned blocks. The streaming
    // connection stays ANCHORED; the ping-pong becomes cache hits; the storm collapses to
    // the two legitimate reconnects (open + the one seek to the moov). The sequential
    // playback fast path never enters this code, so it carries zero overhead.
    private static let detourBlockSize = 4 * 1024 * 1024
    private static let detourMaxBlocks = 8                       // ~32 MB LRU ceiling
    // Once detour reads turn sequential past this much, re-anchor the streaming connection
    // there so sustained playback returns to the cheap window path (e.g. after a backward scrub).
    private static let detourReanchorBytes: Int64 = 8 * 1024 * 1024
    // Interactive per-fetch budget for a detour block (#93/#96). A backward-scrub read serves via the
    // detour cache; a miss fetches a 4 MB block over the pooled session. On a per-connection-starved
    // origin that fetch used to ride the full chunkRequestTimeout (idle 15s / total 35s) before falling
    // through to the rescue reconnect, which opens a fresh connection the origin serves in ~30-190ms
    // (rrgomes' #93/#96 traces: the whole 15-35s sat here, invisibly, in the detour fetch). A 4 MB block
    // over a healthy remote 4K source lands in ~1s, so a tight budget aborts a starved fetch fast and
    // lets the reconnect serve, without tripping healthy parse-time detour fetches (#69 stays intact:
    // its fetches complete well under this, and a genuinely slow parse fetch reconnects with the
    // production liveness backoff, far gentler than the pre-cache per-read storm).
    private static let detourFetchBudgetSeconds: TimeInterval = 4

    /// Effective per-fetch budget for a detour block: the tight interactive cap, never exceeding the
    /// caller's chunk budget (still-extraction passes a smaller one; it never reaches this path, but
    /// the clamp keeps the invariant). Internal so the bound is unit-tested without a live origin.
    static func effectiveDetourBudget(chunkRequestTimeout: TimeInterval) -> TimeInterval {
        min(detourFetchBudgetSeconds, chunkRequestTimeout)
    }

    /// NSCondition guards all persistent-mode fields and serves as the
    /// edge-triggered condition variable for read waits and backpressure.
    private let winCond = NSCondition()
    private let persistentRetryController:
        AVIOPersistentRetryController
    /// Sliding window of bytes from the live connection, starting at `winStart`.
    /// `position - winStart` is the read offset within `window`.
    private var window = Data()
    private var winStart: Int64 = 0
    // Connection state.
    private var connEnded = false
    private var connStatus = 0
    // Retry-After seconds from 429/503, honoured before reconnect.
    private var connRetryAfter: TimeInterval = 0
    // Bumped on every (re)connect; stale delegate callbacks are ignored.
    private var connGeneration = 0
    // A body callback is admitted only after the matching generation's response
    // passed status, range, and immutable-source identity validation.
    private var connResponseAccepted = false
    // A persistent VOD connection may initially establish a generation without
    // a validator. Once any body byte from that generation is accepted, however,
    // a reconnect must prove the exact non-nil validator-bound generation before
    // another body can be combined with the existing window/store bytes.
    private var persistentSourceGeneration:
        SourceByteStoreGeneration?
    private var persistentAcceptedBodyBytes: Int64 = 0
    private var activeSession: URLSession?
    private var activeTask: URLSessionDataTask?
    // #93 restart latency diagnostics (winCond-guarded): bytes dropped by the stale-generation
    // guard, plus per-generation time-to-first-data tracking.
    private var staleGenDroppedBytes: Int64 = 0
    private var connStartedAt = DispatchTime.now()
    private var connFirstDataSeen = false

    /// Detour LRU block cache (its own leaf lock, never held across `fetchChunk`/network or
    /// `winCond`). Stores only full-size blocks; short bodies are served once but never cached
    /// (see serveFromDetour), so eviction never shadows a re-fetchable tail. Pure copy/eviction
    /// math lives on the cache and is unit-tested without any network.
    private let detourCache = DetourBlockCache(blockSize: AVIOReader.detourBlockSize,
                                               maxBlocks: AVIOReader.detourMaxBlocks)
    // Re-anchor run tracking (demux-thread-only): the file offset the next sequential detour read
    // would continue from, and how many contiguous bytes the current detour run has served.
    private var detourRunNextExpected: Int64 = -1
    private var detourRunBytes: Int64 = 0

    /// Playback path (known size + prefetch) or live feeds. Live always uses the
    /// persistent reader; unknown-length VOD uses the forward-only reconnecting reader.
    private var usePersistentReader: Bool {
        if isLive { return prefetchEnabled }
        return !isStreaming && prefetchEnabled
    }

    /// True for endless live feeds. Suppresses `position >= fileSize` EOF synthesis;
    /// transport recovery continues until explicit cancellation or a typed terminal.
    let isLive: Bool

    /// Detour cache is VOD-only: live feeds have no meaningful random access and a
    /// non-authoritative size, so they stay on the unchanged reconnect path.
    private var detourEligible: Bool { !isLive && fileSize > 0 }

    /// Timestamp of the last unplanned reconnect (drop/stall, not a seek).
    /// Producer correlates with a backward source-PTS reset to detect Jellyfin
    /// transcode respawn (re-serves from byte 0 on re-GET, invisible at byte level).
    /// Demux-thread-only (AVIO callback executes synchronously inside av_read_frame).
    private(set) var lastUnplannedReconnectAt: Date?

    /// Seekable-path per-chunk Range-request budget (seconds) and retry passes.
    /// Defaults preserve the historical playback/probe behaviour; still extraction
    /// passes smaller values so a stalled scrub thumbnail aborts fast (issue #27).
    private let chunkRequestTimeout: TimeInterval
    private let chunkMaxRetries: Int

    /// TEST-ONLY slow-CDN throttle (kbit/s, 0 = unlimited), captured once from the static hook at init.
    private let throttleKbps: Int
    private var throttleVClockNs: UInt64 = 0
    private let throttleLock = NSLock()

    init(
        url: URL,
        extraHeaders: [String: String] = [:],
        chunkSize: Int = 4 * 1024 * 1024,
        prefetchEnabled: Bool = true,
        isLive: Bool = false,
        chunkRequestTimeout: TimeInterval = 35,
        chunkMaxRetries: Int = 3,
        boundedInitialFetch: Int64? = nil,
        sourceByteStore: SourceByteStore? = nil,
        livenessPolicy:
            AetherPlaybackLivenessPolicy =
                .production
    ) {
        self.url = url
        self.extraHeaders = extraHeaders
        self.sourceByteStore = sourceByteStore
        self.chunkSize = chunkSize
        self.prefetchEnabled = prefetchEnabled
        self.isLive = isLive
        self.chunkRequestTimeout = chunkRequestTimeout
        self.chunkMaxRetries = max(1, chunkMaxRetries)
        self.boundedInitialFetch = boundedInitialFetch.map { max(1, $0) }
        self.throttleKbps = AetherEngine.sourceThrottleKbpsForTesting
        self.persistentRetryController =
            AVIOPersistentRetryController(
                policy: livenessPolicy
            )
    }

    /// Slow-CDN simulation: hold delivered bytes to `throttleKbps` by sleeping the demux thread before the
    /// bytes reach the demuxer. No-op unless the test hook is set. Lock-guarded: prefetch and demux paths
    /// can both deliver. Sleeping here is consistent with the existing reconnect backoff on this thread.
    private func applyThrottle(deliveredBytes: Int) {
        guard throttleKbps > 0, deliveredBytes > 0 else { return }
        throttleLock.lock()
        let sleepNs = SourceThrottle.advance(
            vclockNs: &throttleVClockNs,
            nowNs: DispatchTime.now().uptimeNanoseconds,
            deliveredBytes: deliveredBytes,
            kbps: throttleKbps
        )
        throttleLock.unlock()
        if sleepNs > 0 { Thread.sleep(forTimeInterval: Double(sleepNs) / 1_000_000_000) }
    }

    private func applyExtraHeaders(_ request: inout URLRequest) {
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    private func applySourceByteStoreHeaders(
        _ request: inout URLRequest
    ) {
        guard sourceByteStore != nil else { return }
        request.setValue(
            "identity",
            forHTTPHeaderField: "Accept-Encoding"
        )
    }

    func open() throws {
        guard let buf = av_malloc(Int(Self.avioBufferSize)) else {
            throw AVIOReaderError.allocationFailed
        }
        buffer = buf.assumingMemoryBound(to: UInt8.self)

        let opaque = Unmanaged.passUnretained(self).toOpaque()
        guard let ctx = avio_alloc_context(
            buffer,
            Self.avioBufferSize,
            0,
            opaque,
            readCallback,
            nil,
            seekCallback
        ) else {
            av_free(buf)
            buffer = nil
            throw AVIOReaderError.allocationFailed
        }

        context = ctx

        if !isLive, let sourceByteStore,
           let snapshot = sourceByteStore.snapshot,
           snapshot.residentBytes > 0 {
            if let candidate = sourceByteStore.validationCandidate {
                switch validateSourceStore(candidate.generation) {
                case .valid:
                    fileSize = candidate.generation.contentLength
                    sourceStoreReadEnabled = true
                    usesValidatedCompleteSourceStore =
                        candidate.isComplete
                    EngineLog.emit(
                        "[AVIOReader] validated session source-byte store "
                            + "length=\(candidate.generation.contentLength) "
                            + "complete=\(candidate.isComplete)",
                        category: .demux
                    )
                case .changed:
                    close()
                    throw AVIOReaderError.sourceByteStore(
                        .generationMismatch
                    )
                case .failed(let reason):
                    close()
                    throw AVIOReaderError.sourceByteStoreValidationFailed(
                        reason: reason
                    )
                case .terminal(let error):
                    close()
                    throw error
                }
            } else {
                do {
                    try sourceByteStore.reset()
                    EngineLog.emit(
                        "[AVIOReader] discarded unvalidated resident source bytes",
                        category: .demux
                    )
                } catch let error as SourceByteStoreError {
                    close()
                    throw AVIOReaderError.sourceByteStore(error)
                }
            }
        }

        if usesValidatedCompleteSourceStore {
            if let ctx = context {
                ctx.pointee.seekable = AVIO_SEEKABLE_NORMAL
            }
            return
        }

        if prefetchEnabled {
            // Playback path. The persistent connection's `Range: bytes=0-` request is itself
            // the size probe: its 206 Content-Range is folded into fileSize by
            // persistentReceivedResponse (issue #70), so the common case skips the dedicated
            // probeFileSize() round-trip (and its HEAD fallback, the request some origins 429).
            startPersistentConnection(at: 0, boundedTo: boundedInitialFetch)
            let gotData = awaitFirstPersistentData()
            if let terminalError {
                throw terminalError
            }
            var tookFallback = false
            if !isLive {
                // Atomically decide, under winCond, whether the optimistic connection resolved
                // a size; if not, abandon it (generation bump ignores a size landing in the
                // race window). fileSize is read under the lock because the delegate thread now
                // writes it (issue #70 review #4/#5).
                let (haveSize, abandoned) = resolveOptimisticOpen()
                abandoned?.invalidateAndCancel()
                if !haveSize {
                    // The data connection resolved no size (no-length origin, a transient 429,
                    // slow headers, or an origin whose length only comes via HEAD). Fall back to
                    // the exact pre-#70 probe path (Range bytes=0- then HEAD, on its own
                    // connection and budget): it keeps seekability whenever a size is reachable
                    // and only streams on a genuinely length-less source, restoring main's
                    // resilience to all of those cases (issue #70 review #1/#3/#4).
                    tookFallback = true
                    EngineLog.emit("[AVIOReader] Data connection resolved no size, falling back to probe", category: .demux, level: .verbose)
                    fileSize = resolveInitialFileSize()
                    if let terminalError {
                        throw terminalError
                    }
                    if isStreaming {
                        startStreamingDownload()
                        _ = streamDataReady.wait(timeout: .now() + .seconds(15))
                    } else {
                        startPersistentConnection(at: 0)
                        if !awaitFirstPersistentData() {
                            EngineLog.emit("[AVIOReader] Persistent open (post-probe): no data within 15s, proceeding to read-loop reconnect", category: .demux)
                        }
                    }
                }
            }
            if !tookFallback && !gotData {
                // No first byte within 15s; read loop's stall/reconnect machinery takes over.
                EngineLog.emit("[AVIOReader] Persistent open: no first byte within 15s, proceeding to read-loop reconnect", category: .demux)
            }
        } else {
            // Non-prefetch (still extraction / one-shot seekable): the size is needed up
            // front for SEEK_END and container index seeks, so keep the dedicated probe.
            fileSize = resolveInitialFileSize()
            if let terminalError {
                throw terminalError
            }
            if isStreaming {
                startStreamingDownload()
                _ = streamDataReady.wait(timeout: .now() + .seconds(15))
            } else {
                if let data = fetchChunk(from: 0, size: chunkSize) {
                    currentBuffer = data
                    currentOffset = 0
                }
                if let terminalError {
                    throw terminalError
                }
            }
        }

        if let terminalError {
            throw terminalError
        }

        // #126: a VOD source that finishes open() without a resolved size runs the forward-only
        // streaming reader; FFmpeg must not believe pb is seekable. With a seekable-flagged pb the
        // mov demuxer far-forward-skips to a tail moov (buffering the entire skipped span in RAM),
        // parses an index it can never rewind to, and every sample read then dies with "partial
        // file" / zero produced packets. Non-seekable pb makes moov-at-end fail cleanly at open
        // and keeps faststart files on honest sequential reads.
        if !isLive, isStreaming, let ctx = context {
            ctx.pointee.seekable = 0
        }
    }

    /// Block up to 15s for the persistent connection's first window bytes. The response
    /// (and thus any Content-Range size) has already been processed by the time data
    /// arrives. Demux thread, open-time only. Returns true if data arrived.
    private func awaitFirstPersistentData() -> Bool {
        winCond.lock()
        let deadline = Date(timeIntervalSinceNow: 15)
        while window.isEmpty && !connEnded && !isClosed {
            if !winCond.wait(until: deadline) { break }
        }
        let gotData = !window.isEmpty
        winCond.unlock()
        return gotData
    }

    /// Under a single winCond critical section: snapshot whether the optimistic open-time
    /// connection resolved a size (fileSize > 0, written by the delegate thread in
    /// persistentReceivedResponse), and if not, atomically abandon that connection so the
    /// open can fall back to the probe path. Bumping the generation inside the same lock as
    /// the read means a size that lands in the race window is ignored rather than racing a
    /// half-done teardown (issue #70 review #4/#5). Returns the session to cancel outside
    /// the lock. Demux thread, open-time only; leaves the AVIO context intact (unlike close()).
    private func resolveOptimisticOpen() -> (haveSize: Bool, abandoned: URLSession?) {
        winCond.lock()
        defer { winCond.unlock() }
        if fileSize > 0 { return (true, nil) }
        connGeneration &+= 1
        let session = activeSession
        activeSession = nil
        activeTask = nil
        window = Data()
        connEnded = true
        winCond.broadcast()
        return (false, session)
    }

    // Close flags written on the teardown thread (markClosed / fullyClose) and read on the demux
    // thread plus the URLSession delegate threads (persistent-connection callbacks). Backed by a
    // leaf unfair lock so every access is synchronized; the bare Bools were a TSan-confirmed data
    // race (markClosed write vs appendPersistentData read). The lock is only ever held for the
    // get/set itself (never across another lock), so it cannot invert with winCond/streamLock.
    private let isClosedLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    private var isClosed: Bool {
        get { isClosedLock.withLock { $0 } }
        set { isClosedLock.withLock { $0 = newValue } }
    }
    private let isFullyClosedLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    private var isFullyClosed: Bool {
        get { isFullyClosedLock.withLock { $0 } }
        set { isFullyClosedLock.withLock { $0 = newValue } }
    }

    /// #112 round 8: the resolved total byte size (Content-Length / Content-Range), nil until known.
    /// Read under winCond like every other fileSize access. Used by `Demuxer.seekByteEstimate` for the
    /// single-probe byte-position fallback when a timestamp seek on an index-less container times out.
    var resolvedByteSize: Int64? {
        winCond.lock()
        defer { winCond.unlock() }
        return fileSize > 0 ? fileSize : nil
    }

    /// Wall-clock deadline for reads. Armed by `beginReadDeadline` to abort
    /// a `avformat_seek_file` that degrades into a linear scan when MKV Cues
    /// index is missing or past EOF (tens of minutes on remote sources).
    private var readDeadline = Date.distantFuture
    private var isPastReadDeadline: Bool { Date() >= readDeadline }
    /// Set when a read returned early due to deadline. `seekBounded` uses this
    /// since matroska may still return success with a partial index after abort.
    private(set) var readDeadlineFired = false

    /// Contract: `readDeadline`/`readDeadlineFired` are demux-thread-only. The
    /// still-extraction (FrameExtractor) reader satisfies this because it runs on one
    /// serial decode queue and `avioPrefetch:false` means no background prefetch thread
    /// touches them. A future profile that re-enables prefetch on a deadline-armed
    /// reader would need these guarded.
    func beginReadDeadline(secondsFromNow seconds: TimeInterval) {
        readDeadlineFired = false
        readDeadline = Date(timeIntervalSinceNow: seconds)
        // Wake a read already parked in the forward-wait so it re-evaluates
        // against the new deadline instead of sleeping the full stall window.
        winCond.lock()
        winCond.broadcast()
        winCond.unlock()
        streamLock.lock()
        streamLock.broadcast()
        streamLock.unlock()
    }

    func endReadDeadline() {
        readDeadline = .distantFuture
    }

    /// Deadline expired; latches `readDeadlineFired` at the check sites.
    private var readDeadlinePassedOrAborted: Bool { isPastReadDeadline }

    // Streaming task/session held so teardown can cancel and unblock streamDownloadSync.
    private var streamingSession: URLSession?
    private var streamingTask: URLSessionDataTask?
    // Suspend/resume calls are balanced under streamLock.
    private var streamingTaskSuspended = false

    /// Unblock a suspended av_read_frame and release the live network connection.
    /// Must be called BEFORE acquiring the demuxer's access lock.
    func markClosed() {
        isClosed = true
        ioQuiescence.beginShutdown()
        persistentRetryController.cancel()
        // Wake any semaphore waits so the read callbacks can exit
        prefetchReady.signal()
        streamDataReady.signal()
        streamLock.lock()
        streamGeneration &+= 1
        let sTask = streamingTask
        let sSession = streamingSession
        let wasSuspended = streamingTaskSuspended
        streamingTaskSuspended = false
        streamingTask = nil
        streamingSession = nil
        streamLock.broadcast()
        streamLock.unlock()
        if wasSuspended { sTask?.resume() }
        sTask?.cancel()
        sSession?.invalidateAndCancel()
        winCond.lock()
        connGeneration &+= 1
        // #93/#96 residual: cancel the persistent Range GET here, not only in close(). markClosed is
        // the abort used by the #79 reopen path (dem.markClosed() to unblock a wedged read); leaving
        // its long-lived open-ended connection alive lets it keep draining the origin for the whole
        // reopen + first-read window, and that connection fair-shares the origin's bandwidth with the
        // fresh reader's cold read, which is exactly the per-connection starvation behind the residual
        // 15-30s cold reads. The AVIO context is untouched (close() still frees it); only the socket
        // is released. Grab under winCond, invalidate outside it (mirrors close()).
        let session = activeSession
        let task = activeTask
        activeSession = nil
        activeTask = nil
        connEnded = true
        winCond.broadcast()
        winCond.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
    }

    /// Free all resources. Separate from `markClosed` (step 1: unblock reads)
    /// because `isClosed` alone can't gate this: prior misuse of that guard
    /// silently leaked 64 MB current + 64 MB prefetch buffers on teardown.
    /// `isFullyClosed` is the idempotency latch for this step.
    func close() {
        guard !isFullyClosed else { return }
        isFullyClosed = true
        isClosed = true
        ioQuiescence.beginShutdown()
        persistentRetryController.cancel()
        if let ctx = context {
            // avio_context_free does NOT free ctx->buffer (verified, aviobuf.c).
            // Free ctx.pointee.buffer, not original av_malloc ptr: FFmpeg can
            // realloc internally via ffio_set_buf_size.
            av_free(ctx.pointee.buffer)
            avio_context_free(&context)
        }
        context = nil
        buffer = nil

        bufferLock.lock()
        currentBuffer = Data()
        prefetchBuffer = nil
        bufferLock.unlock()

        detourCache.clear()

        streamLock.lock()
        streamGeneration &+= 1
        streamBuffer = Data()
        let sTask = streamingTask
        let sSession = streamingSession
        let wasSuspended = streamingTaskSuspended
        streamingTaskSuspended = false
        streamingTask = nil
        streamingSession = nil
        streamLock.broadcast()
        streamLock.unlock()
        if wasSuspended { sTask?.resume() }
        streamDataReady.signal()
        // Covers a close() without prior markClosed().
        sTask?.cancel()
        sSession?.invalidateAndCancel()

        winCond.lock()
        connGeneration &+= 1
        connEnded = true
        let session = activeSession
        activeSession = nil
        activeTask = nil
        window = Data()
        winCond.broadcast()
        winCond.unlock()
        session?.invalidateAndCancel()
    }

    func waitForIOQuiescence() {
        ioQuiescence.waitForShutdown()
    }

    // MARK: - Read (called by FFmpeg on demux thread)

    fileprivate func read(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        guard !isClosed else { return -1 }
        if readDeadlinePassedOrAborted { readDeadlineFired = true; return -1 }
        if terminalError != nil { return -1 }
        if sourceStoreFailure != nil { return -1 }
        let sourceStoreOffset = sourceStoreReadPosition()
        if sourceStoreReadEnabled,
           let cached = readFromSourceStore(
               at: sourceStoreOffset,
               maximumLength: Int(size)
           ) {
            cached.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    buf.update(
                        from: base.assumingMemoryBound(to: UInt8.self),
                        count: cached.count
                    )
                }
            }
            advancePositionAfterSourceStoreRead(cached.count)
            addSourceStoreBytesServed(
                cached.count,
                at: sourceStoreOffset
            )
            applyThrottle(deliveredBytes: cached.count)
            return Int32(cached.count)
        }
        if sourceStoreFailure != nil { return -1 }
        if usesValidatedCompleteSourceStore {
            let currentPosition = sourceStoreReadPosition()
            return currentPosition >= fileSize ? FFmpegErr.eof : -1
        }
        // Check usePersistentReader before isStreaming: live feeds without
        // Content-Length must use the reconnect-capable persistent path.
        let n: Int32
        if usePersistentReader { n = readPersistent(into: buf, size: size) }
        else if isStreaming { n = readStreaming(into: buf, size: size) }
        else { n = readSeekable(into: buf, size: size) }
        if n > 0 { applyThrottle(deliveredBytes: Int(n)) }
        return n
    }

    private func sourceStoreReadPosition() -> Int64 {
        if usePersistentReader || usesValidatedCompleteSourceStore {
            winCond.lock()
            let current = position
            winCond.unlock()
            return current
        }
        return position
    }

    private func readFromSourceStore(
        at offset: Int64,
        maximumLength: Int
    ) -> Data? {
        guard let sourceByteStore, maximumLength > 0 else { return nil }
        do {
            return try sourceByteStore.read(
                at: offset,
                maximumLength: maximumLength
            )
        } catch let error as SourceByteStoreError {
            recordSourceStoreFailure(error)
            return nil
        } catch {
            recordSourceStoreFailure(.blockReadFailed(errno: EIO))
            return nil
        }
    }

    private func advancePositionAfterSourceStoreRead(_ count: Int) {
        if usePersistentReader || usesValidatedCompleteSourceStore {
            winCond.lock()
            position += Int64(count)
            winCond.broadcast()
            winCond.unlock()
        } else {
            position += Int64(count)
        }
    }

    // MARK: - Seekable Read (Range-based)

    private func readSeekable(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        let requestSize = Int(size)
        var totalRead = 0

        while totalRead < requestSize {
            // Abort a superseded / torn-down / past-deadline still read between chunk
            // fetches so it cannot park the decode queue (issue #27). Mirrors the
            // checks readPersistent already does at its loop head.
            if isClosed { return totalRead > 0 ? Int32(totalRead) : -1 }
            if readDeadlinePassedOrAborted { readDeadlineFired = true; return totalRead > 0 ? Int32(totalRead) : -1 }

            bufferLock.lock()
            let bufEnd = currentOffset + Int64(currentBuffer.count)
            let inRange = position >= currentOffset && position < bufEnd
            bufferLock.unlock()

            if inRange {
                bufferLock.lock()
                let offsetInBuffer = Int(position - currentOffset)
                let available = currentBuffer.count - offsetInBuffer
                let toCopy = min(available, requestSize - totalRead)

                currentBuffer.withUnsafeBytes { raw in
                    let src = raw.baseAddress!.advanced(by: offsetInBuffer)
                        .assumingMemoryBound(to: UInt8.self)
                    buf.advanced(by: totalRead).update(from: src, count: toCopy)
                }
                position += Int64(toCopy)
                totalRead += toCopy

                let consumed = Double(position - currentOffset) / Double(currentBuffer.count)
                let nextPrefetchOffset = currentOffset + Int64(currentBuffer.count)
                let needsPrefetch = prefetchEnabled && consumed > 0.5 && !isPrefetching && prefetchBuffer == nil
                bufferLock.unlock()

                if needsPrefetch {
                    triggerPrefetch(from: nextPrefetchOffset)
                }
            } else {
                bufferLock.lock()
                if let prefetch = prefetchBuffer, position >= prefetchOffset &&
                    position < prefetchOffset + Int64(prefetch.count) {
                    currentBuffer = prefetch
                    currentOffset = prefetchOffset
                    prefetchBuffer = nil
                    bufferLock.unlock()
                    continue
                }
                let hasPrefetchInFlight = isPrefetching
                bufferLock.unlock()

                if hasPrefetchInFlight {
                    _ = prefetchReady.wait(timeout: .now() + .seconds(15))
                    bufferLock.lock()
                    if let prefetch = prefetchBuffer, position >= prefetchOffset &&
                        position < prefetchOffset + Int64(prefetch.count) {
                        currentBuffer = prefetch
                        currentOffset = prefetchOffset
                        prefetchBuffer = nil
                        bufferLock.unlock()
                        continue
                    }
                    bufferLock.unlock()
                }

                let fetchSize: Int
                if fileSize > 0 {
                    fetchSize = min(chunkSize, Int(fileSize - position))
                } else {
                    fetchSize = chunkSize
                }

                if fetchSize <= 0 { break }

                guard let data = fetchChunk(from: position, size: fetchSize), !data.isEmpty else {
                    // An aborted fetch (supersede/close/deadline) must report a read
                    // error, not EOF (which would truncate the stream cleanly). issue #27.
                    if isClosed || readDeadlinePassedOrAborted {
                        if readDeadlinePassedOrAborted { readDeadlineFired = true }
                        return totalRead > 0 ? Int32(totalRead) : -1
                    }
                    // nil = transport failure; empty = 2xx with no body (would loop forever otherwise).
                    break
                }

                bufferLock.lock()
                currentBuffer = data
                currentOffset = position
                prefetchBuffer = nil
                bufferLock.unlock()
            }
        }

        return totalRead > 0 ? Int32(totalRead) : FFmpegErr.eof
    }

    // MARK: - Streaming Read (sequential GET)

    private func readStreaming(
        into buf: UnsafeMutablePointer<UInt8>,
        size: Int32
    ) -> Int32 {
        let requestSize = Int(size)
        var totalRead = 0

        while totalRead < requestSize {
            if isClosed {
                return totalRead > 0
                    ? Int32(totalRead)
                    : -1
            }
            if readDeadlinePassedOrAborted {
                readDeadlineFired = true
                return totalRead > 0
                    ? Int32(totalRead)
                    : -1
            }
            if terminalError != nil {
                return totalRead > 0
                    ? Int32(totalRead)
                    : -1
            }

            streamLock.lock()
            let posInBuffer = Int(
                position - streamBytesRead
            )
            let available =
                streamBuffer.count - posInBuffer

            if available > 0 && posInBuffer >= 0 {
                let toCopy = min(
                    available,
                    requestSize - totalRead
                )
                streamBuffer.withUnsafeBytes { raw in
                    let src = raw.baseAddress!
                        .advanced(by: posInBuffer)
                        .assumingMemoryBound(
                            to: UInt8.self
                        )
                    buf.advanced(by: totalRead)
                        .update(
                            from: src,
                            count: toCopy
                        )
                }
                position += Int64(toCopy)
                totalRead += toCopy

                // subdata (not removeFirst): removeFirst leaks backing
                // storage (see trimWindowLocked).
                let consumed = Int(
                    position - streamBytesRead
                )
                if consumed
                    > Self.streamTrimThreshold {
                    let trimAmount =
                        consumed
                        - Self.streamTrimThreshold
                    streamBuffer = streamBuffer
                        .subdata(
                            in: trimAmount..<streamBuffer.count
                        )
                    streamBytesRead +=
                        Int64(trimAmount)
                }
                var toResume:
                    URLSessionDataTask?
                if streamingTaskSuspended,
                   streamBuffer.count
                    < Self.streamLowWater {
                    streamingTaskSuspended = false
                    toResume = streamingTask
                }
                streamLock.unlock()
                toResume?.resume()
                emitNetworkPhase(.flowing)
                continue
            }

            if streamConfirmedEOF {
                streamLock.unlock()
                break
            }

            // Resume before waiting: a suspended task would never deliver.
            var toResume: URLSessionDataTask?
            if streamingTaskSuspended {
                streamingTaskSuspended = false
                toResume = streamingTask
            }
            let observedGeneration =
                streamGeneration
            let observedBytes =
                streamBytesReceived
            let progressDeadline =
                streamProgressDeadline
            streamLock.unlock()
            toResume?.resume()

            streamLock.lock()
            let waitDeadline = min(
                progressDeadline,
                readDeadline
            )
            if !isClosed,
               terminalError == nil,
               !streamConfirmedEOF,
               streamGeneration
                    == observedGeneration,
               streamBytesReceived
                    == observedBytes,
               Date() < waitDeadline {
                _ = streamLock.wait(
                    until: waitDeadline
                )
            }
            let shouldRestartStalledTask =
                !isClosed
                && terminalError == nil
                && !streamConfirmedEOF
                && streamGeneration
                    == observedGeneration
                && streamBytesReceived
                    == observedBytes
                && Date() >= progressDeadline
            let stalledTask =
                shouldRestartStalledTask
                    ? streamingTask
                    : nil
            if stalledTask != nil {
                streamProgressDeadline =
                    .distantFuture
            }
            streamLock.unlock()

            if let stalledTask {
                lastUnplannedReconnectAt = Date()
                emitNetworkPhase(.reconnecting)
                stalledTask.cancel()
            }
        }

        return totalRead > 0
            ? Int32(totalRead)
            : FFmpegErr.eof
    }

    /// Keeps persistent/unknown-length retry output bounded while leaving the
    /// retry decision and backoff untouched. Cause strings are closed local
    /// codes, never request URLs, headers, credentials, or response bodies.
    private func emitBoundedRetryDiagnostic(
        currentCause: String,
        decision: AVIOPersistentRetryDecision
    ) {
        guard let emission = decision.retryLogEmission,
              let firstCause = decision.firstRetryLogCause else {
            return
        }
        let checkpoint = emission.checkpointSeconds.map {
            String(Int($0))
        } ?? "first"
        EngineLog.emit(
            "[AVIOReader] retry checkpoint=\(checkpoint) "
                + "elapsed=\(Int(emission.elapsedSeconds)) "
                + "firstFailure=\(firstCause) "
                + "cumulative=\(emission.cumulativeFailureCount) "
                + "currentFailure=\(currentCause) "
                + "attempt=\(decision.attempt) "
                + "delay=\(Int(decision.delaySeconds))",
            category: .demux
        )
    }

    // MARK: - Persistent Read (single forward-streaming connection)

    /// Sliding-window read over a single long-lived Range: bytes=<offset>- connection.
    /// State machine: inside window -> copy; before window -> backward reconnect;
    /// position >= fileSize -> EOF (only EOF path); far forward -> reconnect;
    /// just ahead + live conn -> wait; conn ended -> reconnect + backoff.
    /// Fetch failures reconnect at the frontier, never collapse to AVERROR_EOF (AetherEngine#25).
    private func readPersistent(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        let requestSize = Int(size)
        var totalRead = 0

        // #93 restart latency: accumulate where THIS read spends its time; one summary line fires
        // on completion when the whole call exceeded the threshold (see SlowReadDiagnostics).
        let readStart = DispatchTime.now()
        var diag = SlowReadDiagnostics()
        func msSince(_ t: DispatchTime) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000
        }
        // #93/#96 residual: count the reconnect AND time the synchronous connect path it drives
        // (the old session's invalidateAndCancel + new task setup, all on this demux thread), so a
        // slow read that sinks its time into reconnecting names it as `connect=` instead of `unaccounted=`.
        func timedReconnect(seek: Bool, at offset: Int64) {
            diag.recordReconnect()
            let connectStart = DispatchTime.now()
            if seek { seekReconnect(at: offset) } else { startPersistentConnection(at: offset) }
            diag.recordConnect(ms: msSince(connectStart))
        }
        func awaitPersistentRetry(
            _ decision: AVIOPersistentRetryDecision
        ) -> AVIOPersistentRetryWaitOutcome {
            let backoffStart = DispatchTime.now()
            let outcome =
                persistentRetryController
                    .waitUntilRetry(decision) {
                        [weak self] in
                        guard let self else {
                            return true
                        }
                        return self.isClosed
                            || self
                                .readDeadlinePassedOrAborted
                            || self.terminalError != nil
                    }
            diag.recordBackoff(
                ms: msSince(backoffStart)
            )
            return outcome
        }
        func cancelledReadResult() -> Int32 {
            if readDeadlinePassedOrAborted {
                readDeadlineFired = true
            }
            return totalRead > 0
                ? Int32(totalRead)
                : -1
        }
        winCond.lock()
        let diagEntryPosition = position
        let diagGenAtStart = connGeneration
        let diagDropsAtStart = staleGenDroppedBytes
        winCond.unlock()
        defer {
            let elapsedMs = msSince(readStart)
            if elapsedMs >= diag.thresholdMs {
                winCond.lock()
                let genAtEnd = connGeneration
                let dropped = staleGenDroppedBytes - diagDropsAtStart
                winCond.unlock()
                diag.recordStaleGenerationDrop(bytes: dropped)
                if let line = diag.line(elapsedMs: elapsedMs, offset: diagEntryPosition,
                                        generationSpan: (diagGenAtStart, genAtEnd)) {
                    EngineLog.emit(line, category: .demux)
                }
            }
        }

        while totalRead < requestSize {
            diag.recordIteration()
            if isClosed { return totalRead > 0 ? Int32(totalRead) : -1 }
            if readDeadlinePassedOrAborted { readDeadlineFired = true; return totalRead > 0 ? Int32(totalRead) : -1 }
            if terminalError != nil {
                return totalRead > 0 ? Int32(totalRead) : -1
            }

            // #93/#96 residual: time the loop-head lock acquisition. A delegate thread holding winCond
            // across its copy + backpressure window blocks the read HERE with nothing to show for it, so
            // this turns that invisible wait into `lockWait=`.
            let lockWaitStart = DispatchTime.now()
            winCond.lock()
            diag.recordLockWait(ms: msSince(lockWaitStart))

            if activeTask == nil {
                let target = position
                winCond.unlock()
                timedReconnect(seek: true, at: target)
                continue
            }

            let curPosition = position

            if curPosition < winStart {
                let observedProgressToken =
                    persistentRetryController
                        .progressToken
                winCond.unlock()
                // Backward random-access read (MP4 parse ping-pong, or a large backward scrub).
                // Serve via the pooled detour cache so the anchored streaming connection is NOT
                // torn down (the reconnect storm + origin 429, AetherEngine#69).
                if detourEligible {
                    // Re-anchor the streaming connection once detour reads have turned sequential
                    // past the threshold (playback resumed here), so steady playback returns to
                    // the cheap window path instead of fetching 4 MB blocks forever.
                    if curPosition == detourRunNextExpected && detourRunBytes >= Self.detourReanchorBytes {
                        detourResetRun()
                        timedReconnect(seek: true, at: curPosition)
                        continue
                    }
                    let detourStart = DispatchTime.now()
                    switch serveFromDetour(into: buf.advanced(by: totalRead),
                                           maxLen: requestSize - totalRead,
                                           at: curPosition, allowFetch: true) {
                    case .served(let n):
                        // A resident-block hit is a pure memcpy (sub-ms); anything slower crossed the network.
                        let detourMs = msSince(detourStart)
                        diag.recordDetourServe(ms: detourMs, fetched: detourMs > 2)
                        winCond.lock(); position = curPosition + Int64(n); winCond.broadcast(); winCond.unlock()
                        totalRead += n
                        emitNetworkPhase(.flowing)   // detour cache served: not stalled (#85)
                        detourTrackSequential(at: curPosition, length: n)
                        continue
                    case .rateLimited(let retryAfter):
                        // #93/#96: account the (throttled) fetch attempt's time so it leaves `unaccounted`.
                        diag.recordDetourFetchAttempt(ms: msSince(detourStart))
                        // Origin is throttling the detour fetch too (#71). Back off in place and
                        // retry the same source. Production playback has no transport-attempt cap.
                        guard let decision =
                                persistentRetryController
                                    .recordTransientFailure(
                                        observedProgressToken:
                                            observedProgressToken,
                                        retryAfterSeconds:
                                            retryAfter,
                                        retryLogCause:
                                            "detourRateLimited"
                                    ) else {
                            continue
                        }
                        emitBoundedRetryDiagnostic(
                            currentCause:
                                "detourRateLimited",
                            decision: decision
                        )
                        if awaitPersistentRetry(decision)
                            == .cancelled {
                            return cancelledReadResult()
                        }
                        continue
                    case .miss:
                        // #93/#96: this is where the residual cold read actually lived. A starved fetch
                        // rode its budget then missed; account that time (else it hides in `unaccounted`)
                        // before falling through to the rescue reconnect that serves in ~30-190ms.
                        diag.recordDetourFetchAttempt(ms: msSince(detourStart))
                        if isClosed { return totalRead > 0 ? Int32(totalRead) : -1 }
                        if readDeadlinePassedOrAborted { readDeadlineFired = true; return totalRead > 0 ? Int32(totalRead) : -1 }
                        if terminalError != nil {
                            return totalRead > 0
                                ? Int32(totalRead)
                                : -1
                        }
                        guard let decision =
                                persistentRetryController
                                    .recordTransientFailure(
                                        observedProgressToken:
                                            observedProgressToken,
                                        retryLogCause:
                                            "detourTransportMiss"
                                    ) else {
                            continue
                        }
                        emitBoundedRetryDiagnostic(
                            currentCause:
                                "detourTransportMiss",
                            decision: decision
                        )
                        switch awaitPersistentRetry(
                            decision
                        ) {
                        case .retry:
                            timedReconnect(
                                seek: true,
                                at: curPosition
                            )
                        case .progressed:
                            break
                        case .cancelled:
                            return cancelledReadResult()
                        }
                        continue
                    }
                }
                timedReconnect(seek: true, at: curPosition)
                continue
            }

            let posInWindow = Int(curPosition - winStart)
            let available = window.count - posInWindow
            if available > 0 {
                let copyNow = min(available, requestSize - totalRead)
                window.withUnsafeBytes { raw in
                    let src = raw.baseAddress!.advanced(by: posInWindow)
                        .assumingMemoryBound(to: UInt8.self)
                    buf.advanced(by: totalRead).update(from: src, count: copyNow)
                }
                position = curPosition + Int64(copyNow)
                totalRead += copyNow
                trimWindowLocked()
                emitNetworkPhase(.flowing)      // recovered: source delivering again (#85)
                winCond.broadcast()              // window may have shrunk: wake backpressure
                winCond.unlock()
                continue
            }

            let frontier = winStart + Int64(window.count)
            let ended = connEnded
            let retryAfter = connRetryAfter

            // Genuine EOF: only path that returns AVERROR_EOF. Skip for live
            // (fileSize non-authoritative on live feeds).
            if !isLive && fileSize > 0 && curPosition >= fileSize {
                winCond.unlock()
                return totalRead > 0 ? Int32(totalRead) : FFmpegErr.eof
            }

            if curPosition > frontier + Int64(Self.seekKeepForwardLimit) {
                winCond.unlock()
                // Far-forward seek. Serve from the detour cache ONLY if the block is already
                // resident (e.g. the moov region the parser revisits); a genuine forward scrub
                // misses and re-anchors the streaming window there, never chunk-serving forever.
                if detourEligible {
                    switch serveFromDetour(into: buf.advanced(by: totalRead),
                                           maxLen: requestSize - totalRead,
                                           at: curPosition, allowFetch: false) {
                    case .served(let n):
                        diag.recordDetourServe(ms: 0, fetched: false)   // resident-only path
                        winCond.lock(); position = curPosition + Int64(n); winCond.broadcast(); winCond.unlock()
                        totalRead += n
                        emitNetworkPhase(.flowing)   // detour cache served: not stalled (#85)
                        detourTrackSequential(at: curPosition, length: n)
                        continue
                    case .rateLimited, .miss:
                        break   // allowFetch:false never rate-limits; a miss falls through to reconnect
                    }
                }
                timedReconnect(seek: true, at: curPosition)
                continue
            }

            if !ended {
                // Wait for the live connection to fill forward. A false return
                // means connStallTimeout elapsed with no data (socket stall).
                let waitStart = DispatchTime.now()
                let signaled = winCond.wait(until: min(Date(timeIntervalSinceNow: Self.connStallTimeout), readDeadline))
                let observedProgressToken =
                    persistentRetryController
                        .progressToken
                winCond.unlock()
                diag.recordStallWait(ms: msSince(waitStart), signaled: signaled)
                // Check deadline before stall handling to avoid misrouting a
                // deadline wake as a socket stall (which would reconnect).
                if isPastReadDeadline { continue }
                if !signaled {
                    guard let decision =
                            persistentRetryController
                                .recordTransientFailure(
                                    observedProgressToken:
                                        observedProgressToken,
                                    retryLogCause:
                                        "persistentStall"
                                ) else {
                        continue
                    }
                    emitBoundedRetryDiagnostic(
                        currentCause: "persistentStall",
                        decision: decision
                    )
                    lastUnplannedReconnectAt = Date()
                    emitNetworkPhase(.reconnecting)   // unplanned reconnect now in flight (#85)
                    switch awaitPersistentRetry(
                        decision
                    ) {
                    case .retry:
                        timedReconnect(
                            seek: false,
                            at: frontier
                        )
                    case .progressed:
                        break
                    case .cancelled:
                        return cancelledReadResult()
                    }
                }
                continue
            }

            // Connection ended before EOF; reconnect at frontier. Honour Retry-After for 429/503.
            let observedProgressToken =
                persistentRetryController
                    .progressToken
            winCond.unlock()
            guard let decision =
                    persistentRetryController
                        .recordTransientFailure(
                                observedProgressToken:
                                    observedProgressToken,
                            retryAfterSeconds:
                                retryAfter,
                            retryLogCause:
                                "persistentConnectionEnded"
                        ) else {
                continue
            }
            emitBoundedRetryDiagnostic(
                currentCause: "persistentConnectionEnded",
                decision: decision
            )
            lastUnplannedReconnectAt = Date()
            emitNetworkPhase(.reconnecting)   // unplanned reconnect now in flight (#85)
            switch awaitPersistentRetry(decision) {
            case .retry:
                timedReconnect(
                    seek: false,
                    at: frontier
                )
            case .progressed:
                break
            case .cancelled:
                return cancelledReadResult()
            }
        }

        return Int32(totalRead)
    }

    /// Drop consumed bytes in ~winTrimBatch steps to avoid O(n^2) memmove.
    /// MUST use `subdata` (not `removeFirst`): removeFirst only advances the slice's
    /// lower bound but backing storage grows with count.setter in appendPersistentData,
    /// leaking ~14 MB/s on 80 Mbps remux (AetherEngine#31). subdata re-bases to compact
    /// storage. Caller holds `winCond`.
    private func trimWindowLocked() {
        let behind = Int(position - winStart)
        let dropThreshold = Self.winLookback + Self.winTrimBatch
        if behind > dropThreshold {
            let drop = behind - Self.winLookback
            window = window.subdata(in: drop..<window.count)
            winStart += Int64(drop)
        }
    }

    /// Intentional seek reconnect does not count as progress and therefore
    /// cannot hide an existing transport-failure sequence.
    private func seekReconnect(at offset: Int64) {
        startPersistentConnection(at: offset)
    }

    // MARK: - Detour Block Cache (AetherEngine#69)

    private enum DetourServe { case served(Int); case rateLimited(TimeInterval); case miss }
    private enum DetourFetch { case ok(Data); case rateLimited(TimeInterval); case failed }

    /// Serve `[offset, offset+maxLen)` (clamped to one 4 MB block) from the detour cache,
    /// fetching the block over the pooled keep-alive chunkSession on a miss when `allowFetch`.
    /// Demux-thread call; may block on the network via `detourFetchBlock` (no lock held across it).
    /// Returns `.miss` (never `.served(0)`) so callers fall back to a single reconnect.
    private func serveFromDetour(into dst: UnsafeMutablePointer<UInt8>, maxLen: Int,
                                 at offset: Int64, allowFetch: Bool) -> DetourServe {
        guard fileSize > 0, offset < fileSize, maxLen > 0 else { return .miss }

        // Resident-block hit: pure copy, no network.
        if let n = detourCache.serveCached(into: dst, maxLen: maxLen, at: offset) {
            return .served(n)
        }
        guard allowFetch else { return .miss }

        let blockStart = (offset / Int64(Self.detourBlockSize)) * Int64(Self.detourBlockSize)
        let blockLen = Int(min(Int64(Self.detourBlockSize), fileSize - blockStart))
        let block: Data
        switch detourFetchBlock(from: blockStart, size: blockLen) {
        case .ok(let fetched):
            // Cache only FULL-length blocks. A truncated 206 cached verbatim would shadow the
            // re-fetch path for its uncovered tail, so the parser ping-ponging into that tail
            // would cost one reconnect per read, reintroducing a mild storm (#69 review). Serve
            // the short body once; the next read of this block re-fetches.
            if fetched.count == blockLen, !isFullyClosed {
                detourCache.insert(blockStart / Int64(Self.detourBlockSize), fetched)
                #if DEBUG
                EngineLog.emit("[AVIOReader] detour fill block=\(blockStart / Int64(Self.detourBlockSize)) offset=\(blockStart) size=\(fetched.count) (resident=\(detourCache.residentCount))", category: .demux)
                #endif
            }
            block = fetched
        case .rateLimited(let retryAfter):
            return .rateLimited(retryAfter)
        case .failed:
            return .miss
        }

        let inBlock = Int(offset - blockStart)
        guard inBlock >= 0, inBlock < block.count else { return .miss }
        let n = min(maxLen, block.count - inBlock)
        block.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                dst.update(from: base.advanced(by: inBlock).assumingMemoryBound(to: UInt8.self), count: n)
            }
        }
        return .served(n)
    }

    /// Single Range fetch for a detour block over the pooled chunkSession. Surfaces 429/503 with
    /// its Retry-After so the caller can back off in place rather than churn the connection (#71).
    private func detourFetchBlock(from offset: Int64, size: Int) -> DetourFetch {
        guard let sourceByteStore else {
            do {
                return .ok(
                    try detourOriginRange(
                        from: offset,
                        size: size
                    ).data
                )
            } catch SourceByteStoreError
                    .rangeFetchRateLimited(
                        let retryAfter
                    ) {
                return .rateLimited(retryAfter)
            } catch {
                return .failed
            }
        }
        let budget = Self.effectiveDetourBudget(
            chunkRequestTimeout: chunkRequestTimeout
        )
        let deadline = Date(
            timeIntervalSinceNow: budget
        )
        do {
            return .ok(
                try sourceByteStore.fetchExactRange(
                    at: offset,
                    length: size,
                    shouldAbort: { [weak self] in
                        guard let self else { return true }
                        return self.isClosed
                            || self.readDeadlinePassedOrAborted
                            || Date() >= deadline
                    },
                    originFetch: { [weak self] in
                        guard let self else {
                            throw SourceByteStoreError.cancelled
                        }
                        let origin = try self.detourOriginRange(
                            from: offset,
                            size: size
                        )
                        guard let generation =
                                origin.generation else {
                            throw SourceByteStoreError
                                .invalidGeneration
                        }
                        return SourceByteStoreFetchedRange(
                            generation: generation,
                            data: origin.data
                        )
                    }
                )
            )
        } catch SourceByteStoreError
                .rangeFetchRateLimited(
                    let retryAfter
                ) {
            return .rateLimited(retryAfter)
        } catch let error as SourceByteStoreError
                where error == .cancelled
                    || error == .rangeFetchFailed {
            return .failed
        } catch let error as SourceByteStoreError {
            recordSourceStoreFailure(error)
            return .failed
        } catch {
            return .failed
        }
    }

    private func detourOriginRange(
        from offset: Int64,
        size: Int,
        forceSource: Bool = false
    ) throws -> OriginChunk {
        let rangeEnd = offset + Int64(size) - 1
        let targetURL = forceSource ? url : requestURL()
        let usedCachedResolvedURL =
            !forceSource
                && cachedResolvedURL() == targetURL
                && targetURL != url
        var request = URLRequest(url: targetURL)
        request.setValue("bytes=\(offset)-\(rangeEnd)", forHTTPHeaderField: "Range")
        // #93/#96: a starved backward-scrub detour fetch must abort fast (the rescue reconnect serves
        // instantly), so this path uses the tight interactive budget, not the full chunk timeout.
        let budget = Self.effectiveDetourBudget(chunkRequestTimeout: chunkRequestTimeout)
        request.timeoutInterval = budget
        applyExtraHeaders(&request)
        applySourceByteStoreHeaders(&request)
        do {
            let result = try syncRequest(
                request,
                budget: budget
            )
            let data = result.data
            let response = result.response
            var sourceGeneration:
                SourceByteStoreGeneration?
            if let http = response as? HTTPURLResponse {
                let status = http.statusCode
                if status == 429 || status == 503 {
                    throw SourceByteStoreError
                        .rangeFetchRateLimited(
                            Self.parseRetryAfter(http)
                        )
                }
                if status != 200 && status != 206 {
                    let shouldRetryCanonical =
                        handleHardHTTPStatus(
                        status,
                        responseWasResolvedUpstream:
                            usedCachedResolvedURL
                                || result.didFollowRedirect
                    )
                    if shouldRetryCanonical && !forceSource {
                        return try detourOriginRange(
                            from: offset,
                            size: size,
                            forceSource: true
                        )
                    }
                    throw SourceByteStoreError
                        .rangeFetchFailed
                }
                // VOD: 200 at offset > 0 = server ignored Range; silent corruption. Reject.
                if status == 200 && offset > 0 && !isLive {
                    EngineLog.emit("[AVIOReader] detour: server ignored Range (200 for offset \(offset)); rejecting", category: .demux, level: .verbose)
                    throw SourceByteStoreError
                        .rangeFetchFailed
                }
                if sourceByteStore != nil {
                    guard let generation =
                            sourceStoreFetchGeneration(
                                response: http,
                                requestedOffset: offset
                            ) else {
                        throw sourceStoreFailure
                            ?? SourceByteStoreError
                                .invalidGeneration
                    }
                    sourceGeneration = generation
                }
            }
            addBytesFetched(
                data.count,
                at: offset
            )
            if sourceByteStore != nil {
                guard let sourceGeneration else {
                    throw SourceByteStoreError
                        .invalidGeneration
                }
                return OriginChunk(
                    data: data,
                    generation: sourceGeneration
                )
            }
            return OriginChunk(
                data: data,
                generation: nil
            )
        } catch let error as SourceByteStoreError {
            throw error
        } catch {
            if isClosed || readDeadlinePassedOrAborted {
                throw SourceByteStoreError.cancelled
            }
            throw SourceByteStoreError.rangeFetchFailed
        }
    }

    /// Tracks contiguity of detour reads for the re-anchor heuristic. Shared by BOTH the backward
    /// and far-forward branches; the re-anchor check itself lives only in the backward branch on
    /// purpose, so a forward-accumulated run later met by a contiguous backward read is an intended
    /// re-anchor, not an accident. A non-contiguous read restarts the run. Demux-thread-only.
    private func detourTrackSequential(at offset: Int64, length: Int) {
        if offset == detourRunNextExpected {
            detourRunBytes += Int64(length)
        } else {
            detourRunBytes = Int64(length)
        }
        detourRunNextExpected = offset + Int64(length)
    }

    private func detourResetRun() {
        detourRunNextExpected = -1
        detourRunBytes = 0
    }

    // MARK: - Persistent Connection (lifecycle + delegate callbacks)

    /// Open a fresh Range: bytes=<offset>- connection. Bumps generation so
    /// late callbacks from the old connection are ignored.
    private func startPersistentConnection(at offset: Int64, boundedTo: Int64? = nil) {
        let sourceStoreValidator =
            sourceByteStore?
                .snapshot?
                .generation
                .validator
        winCond.lock()
        connGeneration &+= 1
        let generation = connGeneration
        let admittedValidator =
            isLive
                ? nil
                : (
                    persistentSourceGeneration?
                        .validator
                        ?? sourceStoreValidator
                )
        winStart = offset
        window = Data()
        connEnded = false
        connStatus = 0
        connRetryAfter = 0
        connResponseAccepted = false
        connStartedAt = DispatchTime.now()   // #93: time-to-first-data per generation
        connFirstDataSeen = false
        let oldSession = activeSession
        activeSession = nil
        activeTask = nil
        // Wake a backpressure-blocked old-gen delegate so it sees it is stale.
        winCond.broadcast()
        winCond.unlock()

        oldSession?.invalidateAndCancel()

        if isClosed { return }
        guard let ioActivity =
                ioQuiescence.beginActivity() else {
            return
        }

        let targetURL = requestURL()
        let usedCachedResolvedURL =
            cachedResolvedURL() == targetURL
                && targetURL != url
        var request = URLRequest(url: targetURL)
        // #93 residual: a bounded open connection asks for a finite range so an origin that dribbles
        // the open-ended `bytes=0-` stream serves it as a fast finite GET. The 206 Content-Range still
        // carries the total size, so fileSize resolution (issue #70) is unaffected.
        if let boundedTo {
            request.setValue("bytes=\(offset)-\(offset + boundedTo - 1)", forHTTPHeaderField: "Range")
        } else {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        request.timeoutInterval = 0  // long-lived; stalls handled by the reader
        applyExtraHeaders(&request)
        applySourceByteStoreHeaders(&request)
        if let admittedValidator {
            request.setValue(
                Self.ifRangeValue(
                    for: admittedValidator
                ),
                forHTTPHeaderField: "If-Range"
            )
        }

        let delegate = PersistentReadDelegate(
            reader: self,
            generation: generation,
            extraHeaders: extraHeaders,
            usedCachedResolvedURL:
                usedCachedResolvedURL,
            ioActivity: ioActivity
        )
        let session = URLSession(
            configuration: Self.makeSessionConfig(longLived: true),
            delegate: delegate,
            delegateQueue: nil
        )
        let task = session.dataTask(with: request)

        winCond.lock()
        // A close() that raced in bumped the generation; don't install a stale connection.
        guard generation == connGeneration, !isClosed else {
            winCond.unlock()
            session.invalidateAndCancel()
            return
        }
        activeSession = session
        activeTask = task
        winCond.unlock()

        task.resume()
        #if DEBUG
        EngineLog.emit("[AVIOReader] Persistent conn start gen=\(generation) offset=\(offset)", category: .demux)
        #endif
    }

    /// Force-copies `data` into the sliding window and applies backpressure by
    /// blocking until the consumer drains below winHighWater. Force-copy releases
    /// source dispatch_data per delivery (same leak control as the chunk path).
    fileprivate func appendPersistentData(_ data: Data, generation: Int) {
        winCond.lock()
        guard generation == connGeneration,
              connResponseAccepted,
              !isFullyClosed else {
            // #93: a slow read's summary line reports how much data the stale-generation
            // or unadmitted-response guard discarded while the read waited.
            staleGenDroppedBytes += Int64(data.count)
            winCond.unlock()
            return
        }
        let sourceOffset = winStart + Int64(window.count)
        var firstDataMs: Double? = nil
        if !connFirstDataSeen {
            connFirstDataSeen = true
            firstDataMs = Double(DispatchTime.now().uptimeNanoseconds - connStartedAt.uptimeNanoseconds) / 1_000_000
        }
        let count = data.count
        persistentAcceptedBodyBytes &+= Int64(count)
        let base = window.count
        window.count = base + count
        window.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                if let d = dst.baseAddress, let s = src.baseAddress {
                    (d + base).copyMemory(from: s, byteCount: count)
                }
            }
        }
        addBytesFetched(
            count,
            at: sourceOffset
        )
        winCond.broadcast()
        // Backpressure: 0.2s timeout is belt-and-suspenders; correctness from broadcasts.
        while generation == connGeneration && !isClosed {
            let ahead = window.count - max(0, Int(position - winStart))
            if ahead <= Self.winHighWater { break }
            _ = winCond.wait(until: Date(timeIntervalSinceNow: 0.2))
        }
        winCond.unlock()
        storeSourceBytes(data, at: sourceOffset)
        if let firstDataMs {
            // #93/#96 residual: a slow first-data gap is release-visible so a device trace can pair it
            // with the response-header timing above. Small header gap + large first-data gap = the body
            // stalled after headers; large header gap = server-side connection queuing. Fast reads stay
            // on the DEBUG-only path to keep the release log quiet.
            if firstDataMs > 2000 {
                EngineLog.emit("[AVIOReader] gen=\(generation) first data after \(Int(firstDataMs))ms",
                               category: .demux)
            } else {
                #if DEBUG
                EngineLog.emit("[AVIOReader] gen=\(generation) first data after \(Int(firstDataMs))ms",
                               category: .demux)
                #endif
            }
        }
    }

    fileprivate func persistentReceivedResponse(
        _ http: HTTPURLResponse,
        resolvedURL: URL?,
        generation: Int,
        responseWasResolvedUpstream: Bool
    ) -> Bool {
        let status = http.statusCode
        var isOK = status == 200 || status == 206
        var retryAfter: TimeInterval = 0
        if status == 429 || status == 503 {
            retryAfter = Self.parseRetryAfter(http)
        }
        var headerMs: Double? = nil
        winCond.lock()
        let isCurrentGeneration = generation == connGeneration
        if isCurrentGeneration {
            connStatus = status
            connRetryAfter = retryAfter
            connResponseAccepted = false
            // #93/#96 residual: time-to-first-response-header for this generation. A large value here
            // with a small subsequent first-data gap points at server-side connection queuing (the
            // origin accepted the socket but withheld the response while it served another connection
            // of the same file at full rate), the prime suspect for the ~15s cold reads.
            headerMs = Double(DispatchTime.now().uptimeNanoseconds - connStartedAt.uptimeNanoseconds) / 1_000_000
        }
        // VOD: 200 at offset > 0 means server ignored Range and sent the full body
        // from byte 0 (silent corruption). Reject it. Live is exempt: transcode
        // reconnect legitimately answers 200 with "from now".
        let requestedOffset = isCurrentGeneration ? winStart : 0
        let exactResponseGeneration =
            !isLive
                ? Self.sourceStoreGeneration(
                    response: http,
                    requestedOffset:
                        requestedOffset
                )
                : nil
        // Issue #70: the first from-0 data connection doubles as the size probe, so the
        // playback open skips probeFileSize() entirely. Derive the total from this
        // response (206 Content-Range, or Content-Length on a from-0 2xx). Write-once
        // (fileSize <= 0), current-gen only, and never for live (whose length is
        // non-authoritative). The response precedes any body and no read() reads fileSize
        // until open() returns, so this write is ordered behind winCond just like the data.
        if isCurrentGeneration, !isLive, fileSize <= 0,
           let total = Self.sizeFromResponse(http, requestedOffset: requestedOffset) {
            fileSize = total
            // #112: share this resolved length so a later side demuxer on the same origin can skip a probe that
            // might be starved under this connection's load and would otherwise collapse it to forward-only.
            SourceContentLengthCache.store(total, for: url)
            #if DEBUG
            EngineLog.emit("[AVIOReader] File size: \(total) bytes (data connection)", category: .demux)
            #endif
        }
        winCond.unlock()
        if isOK, isCurrentGeneration, !isLive {
            winCond.lock()
            if generation != connGeneration {
                isOK = false
            } else if persistentAcceptedBodyBytes > 0 {
                guard let admitted =
                        persistentSourceGeneration,
                      admitted.validator != nil,
                      let exactResponseGeneration,
                      exactResponseGeneration
                        == admitted else {
                    winCond.unlock()
                    recordSourceStoreFailure(
                        .generationMismatch
                    )
                    return false
                }
            } else {
                persistentSourceGeneration =
                    exactResponseGeneration
            }
            winCond.unlock()
        }
        if isOK, isCurrentGeneration,
           !admitSourceStoreResponse(
               http,
               requestedOffset: requestedOffset
           ) {
            isOK = false
        }
        if let headerMs, headerMs > 2000 {
            EngineLog.emit(
                "[AVIOReader] gen=\(generation) response headers after \(Int(headerMs))ms status=\(status)",
                category: .demux
            )
        }
        if status == 200 && requestedOffset > 0 && !isLive {
            EngineLog.emit(
                "[AVIOReader] server ignored Range (200 for offset \(requestedOffset)); rejecting body",
                category: .demux
            )
            isOK = false
        }

        if isOK {
            winCond.lock()
            guard generation == connGeneration,
                  !isClosed,
                  terminalError == nil else {
                winCond.unlock()
                return false
            }
            connResponseAccepted = true
            winCond.unlock()
            if let resolvedURL { recordResolvedURL(resolvedURL) }
            return true
        }
        handleHardHTTPStatus(
            status,
            responseWasResolvedUpstream:
                responseWasResolvedUpstream
        )
        return false
    }

    fileprivate func persistentConnectionEnded(error: Error?, generation: Int) {
        winCond.lock()
        let isCurrentGen = (generation == connGeneration)
        if isCurrentGen {
            connEnded = true
        }
        let windowAhead = isCurrentGen ? (window.count - max(0, Int(position - winStart))) : 0
        winCond.broadcast()
        winCond.unlock()
        _ = error
        _ = windowAhead
    }

    /// Parses delta-seconds Retry-After; HTTP-date form falls back to policy
    /// backoff. A server hint can extend the policy delay, capped at 30s.
    private static func parseRetryAfter(_ http: HTTPURLResponse) -> TimeInterval {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)) else {
            return 0
        }
        return min(max(seconds, 0), 30)
    }

    private func admitSourceStoreResponse(
        _ response: HTTPURLResponse,
        requestedOffset: Int64
    ) -> Bool {
        guard let sourceByteStore else { return true }
        if let contentEncoding = response.value(
            forHTTPHeaderField: "Content-Encoding"
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
           !contentEncoding.isEmpty,
           contentEncoding.lowercased() != "identity" {
            recordSourceStoreFailure(
                .unsupportedContentEncoding(contentEncoding)
            )
            return false
        }
        guard let generation = Self.sourceStoreGeneration(
            response: response,
            requestedOffset: requestedOffset
        ) else {
            return true
        }
        do {
            try sourceByteStore.admit(generation)
            return true
        } catch let error as SourceByteStoreError {
            recordSourceStoreFailure(error)
            return false
        } catch {
            recordSourceStoreFailure(.generationMismatch)
            return false
        }
    }

    private func sourceStoreFetchGeneration(
        response: HTTPURLResponse,
        requestedOffset: Int64
    ) -> SourceByteStoreGeneration? {
        if let contentEncoding = response.value(
            forHTTPHeaderField: "Content-Encoding"
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
           !contentEncoding.isEmpty,
           contentEncoding.lowercased() != "identity" {
            recordSourceStoreFailure(
                .unsupportedContentEncoding(contentEncoding)
            )
            return nil
        }
        guard let generation = Self.sourceStoreGeneration(
            response: response,
            requestedOffset: requestedOffset
        ) else {
            recordSourceStoreFailure(.invalidGeneration)
            return nil
        }
        return generation
    }

    private func storeSourceBytes(_ data: Data, at offset: Int64) {
        guard let sourceByteStore, !data.isEmpty else { return }
        do {
            try sourceByteStore.store(data, at: offset)
        } catch let error as SourceByteStoreError {
            recordSourceStoreFailure(error)
        } catch {
            recordSourceStoreFailure(.blockWriteFailed(errno: EIO))
        }
    }

    private static func sourceStoreGeneration(
        response: HTTPURLResponse,
        requestedOffset: Int64
    ) -> SourceByteStoreGeneration? {
        guard let contentLength = sizeFromResponse(
            response,
            requestedOffset: requestedOffset
        ), contentLength > 0 else {
            return nil
        }
        let validator: SourceByteStoreValidator?
        if let rawETag = response.value(forHTTPHeaderField: "ETag")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawETag.isEmpty,
           !rawETag.lowercased().hasPrefix("w/") {
            validator = .strongETag(rawETag)
        } else if let lastModified = response.value(
            forHTTPHeaderField: "Last-Modified"
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !lastModified.isEmpty {
            validator = .lastModified(lastModified)
        } else {
            validator = nil
        }
        return try? SourceByteStoreGeneration(
            contentLength: contentLength,
            validator: validator
        )
    }

    static func sourceStoreGenerationMatches(
        _ expected: SourceByteStoreGeneration,
        response: HTTPURLResponse,
        requestedOffset: Int64
    ) -> Bool {
        sourceStoreGeneration(
            response: response,
            requestedOffset: requestedOffset
        ) == expected
    }

    // MARK: - Streaming Download (background)

    private func startStreamingDownload() {
        prefetchQueue.async { [weak self] in
            self?.streamDownloadSync()
        }
    }

    private func streamDownloadSync() {
        while !isClosed && terminalError == nil {
            streamLock.lock()
            if streamConfirmedEOF {
                streamLock.unlock()
                return
            }
            streamGeneration &+= 1
            let generation = streamGeneration
            let requestedOffset =
                streamBytesReceived
            let validator =
                streamSourceValidator
            streamAttemptAcceptedResponse = false
            streamAttemptRetryAfter = 0
            streamAttemptDiscardPrefixBytes = 0
            streamAttemptStartBytes =
                streamBytesReceived
            streamProgressDeadline = Date(
                timeIntervalSinceNow:
                    persistentRetryController
                        .noProgressWindowSeconds(
                            forAttempt:
                                streamNoProgressAttempt
                        )
            )
            streamLock.broadcast()
            streamLock.unlock()

            guard let ioActivity =
                    ioQuiescence
                        .beginActivity() else {
                return
            }

            let targetURL = requestURL()
            let usedCachedResolvedURL =
                cachedResolvedURL() == targetURL
                    && targetURL != url
            var request = URLRequest(
                url: targetURL
            )
            request.timeoutInterval = 0
            if requestedOffset > 0 {
                request.setValue(
                    "bytes=\(requestedOffset)-",
                    forHTTPHeaderField: "Range"
                )
                if let validator {
                    request.setValue(
                        Self.ifRangeValue(
                            for: validator
                        ),
                        forHTTPHeaderField:
                            "If-Range"
                    )
                }
            }
            request.setValue(
                "identity",
                forHTTPHeaderField:
                    "Accept-Encoding"
            )
            applyExtraHeaders(&request)

            let semaphore =
                DispatchSemaphore(value: 0)
            let delegate = StreamingDelegate(
                extraHeaders: extraHeaders,
                onResponse: {
                    [weak self] response,
                    resolvedURL,
                    didFollowRedirect in
                    guard let self else {
                        return false
                    }
                    return self
                        .streamingReceivedResponse(
                            response,
                            resolvedURL:
                                resolvedURL,
                            requestedOffset:
                                requestedOffset,
                            generation:
                                generation,
                            responseWasResolvedUpstream:
                                usedCachedResolvedURL
                                || didFollowRedirect
                        )
                },
                onData: {
                    [weak self] data in
                    self?.appendStreamingData(
                        data,
                        generation: generation
                    )
                },
                onComplete: {
                    [weak self] completedWithoutError in
                    self?
                        .streamingConnectionEnded(
                            completedWithoutError:
                                completedWithoutError,
                            generation:
                                generation
                        )
                },
                onStopped: {
                    semaphore.signal()
                },
                ioActivity: ioActivity
            )
            let streamSession = URLSession(
                configuration:
                    Self.makeSessionConfig(
                        longLived: true
                    ),
                delegate: delegate,
                delegateQueue: nil
            )
            let task =
                streamSession.dataTask(
                    with: request
                )

            // Register before resume so markClosed()/close() can cancel.
            streamLock.lock()
            guard generation == streamGeneration,
                  !isClosed else {
                streamLock.unlock()
                streamSession
                    .invalidateAndCancel()
                return
            }
            streamingSession = streamSession
            streamingTask = task
            #if DEBUG
            streamActiveReaderCount += 1
            streamMaximumConcurrentReaderCount =
                max(
                    streamMaximumConcurrentReaderCount,
                    streamActiveReaderCount
                )
            #endif
            streamLock.broadcast()
            streamLock.unlock()

            task.resume()

            #if DEBUG
            EngineLog.emit(
                "[AVIOReader] Unknown-length stream started generation=\(generation) offset=\(requestedOffset)",
                category: .demux
            )
            #endif

            semaphore.wait()
            streamSession.invalidateAndCancel()

            streamLock.lock()
            #if DEBUG
            streamActiveReaderCount -= 1
            #endif
            let isCurrentGeneration =
                generation == streamGeneration
            if isCurrentGeneration {
                streamingSession = nil
                streamingTask = nil
                streamProgressDeadline =
                    .distantFuture
                streamLock.broadcast()
            }
            let retryAfter =
                isCurrentGeneration
                    ? streamAttemptRetryAfter
                    : 0
            let reachedEOF =
                isCurrentGeneration
                    && streamConfirmedEOF
            streamLock.unlock()

            if isClosed
                || terminalError != nil
                || reachedEOF {
                return
            }

            let observedProgressToken =
                persistentRetryController
                    .progressToken
            guard let decision =
                    persistentRetryController
                        .recordTransientFailure(
                                observedProgressToken:
                                    observedProgressToken,
                            retryAfterSeconds:
                                retryAfter,
                            retryLogCause:
                                "unknownLengthReconnect"
                        ) else {
                continue
            }
            emitBoundedRetryDiagnostic(
                currentCause: "unknownLengthReconnect",
                decision: decision
            )
            streamLock.lock()
            streamLock.broadcast()
            streamLock.unlock()
            let outcome =
                persistentRetryController
                    .waitUntilRetry(decision) {
                        [weak self] in
                        guard let self else {
                            return true
                        }
                        return self.isClosed
                            || self.terminalError
                                != nil
                    }
            guard outcome == .retry else {
                if outcome == .cancelled {
                    return
                }
                continue
            }
        }
    }

    private func streamingReceivedResponse(
        _ response: HTTPURLResponse,
        resolvedURL: URL?,
        requestedOffset: Int64,
        generation: Int,
        responseWasResolvedUpstream: Bool
    ) -> Bool {
        let statusCode = response.statusCode
        guard statusCode == 200
                || statusCode == 206 else {
            let retryAfter =
                statusCode == 429
                    || statusCode == 503
                    ? Self.parseRetryAfter(
                        response
                    )
                    : 0
            streamLock.lock()
            if generation == streamGeneration {
                streamAttemptRetryAfter =
                    retryAfter
                streamLock.broadcast()
            }
            streamLock.unlock()
            handleHardHTTPStatus(
                statusCode,
                responseWasResolvedUpstream:
                    responseWasResolvedUpstream
            )
            return false
        }

        let plan: AVIOStreamingResumePlan
        do {
            plan = try Self.streamingResumePlan(
                statusCode: statusCode,
                requestedOffset:
                    requestedOffset,
                contentRange: response
                    .value(
                        forHTTPHeaderField:
                            "Content-Range"
                    ),
                admittedValidator:
                    streamValidatorSnapshot(),
                responseValidator:
                    Self.responseValidator(
                        response
                    ),
                contentEncoding: response
                    .value(
                        forHTTPHeaderField:
                            "Content-Encoding"
                    )
            )
        } catch let error as AVIOReaderError {
            recordTerminalReaderError(error)
            streamLock.lock()
            streamLock.broadcast()
            streamLock.unlock()
            return false
        } catch {
            recordTerminalReaderError(
                .sourceByteStore(
                    .generationMismatch
                )
            )
            streamLock.lock()
            streamLock.broadcast()
            streamLock.unlock()
            return false
        }

        streamLock.lock()
        guard generation == streamGeneration,
              !isClosed else {
            streamLock.unlock()
            return false
        }
        streamAttemptAcceptedResponse = true
        streamAttemptDiscardPrefixBytes =
            plan.discardPrefixBytes
        if requestedOffset == 0 {
            streamSourceValidator =
                plan.validator
        }
        streamLock.broadcast()
        streamLock.unlock()
        if let resolvedURL {
            recordResolvedURL(resolvedURL)
        }
        return true
    }

    private func streamValidatorSnapshot()
        -> SourceByteStoreValidator? {
        streamLock.lock()
        defer { streamLock.unlock() }
        return streamSourceValidator
    }

    private func appendStreamingData(
        _ data: Data,
        generation: Int
    ) {
        guard !data.isEmpty else { return }
        streamLock.lock()
        guard generation == streamGeneration,
              streamAttemptAcceptedResponse,
              !isClosed else {
            streamLock.unlock()
            return
        }

        var startIndex = 0
        if streamAttemptDiscardPrefixBytes > 0 {
            let discarded = min(
                Int64(data.count),
                streamAttemptDiscardPrefixBytes
            )
            streamAttemptDiscardPrefixBytes -=
                discarded
            startIndex = Int(discarded)
            // This does not advance the unique-byte ledger, but it keeps one
            // validated replay alive long enough to reach the resume offset.
            streamProgressDeadline = Date(
                timeIntervalSinceNow:
                    persistentRetryController
                        .noProgressWindowSeconds(
                            forAttempt:
                                streamNoProgressAttempt
                        )
            )
        }

        let appendedCount =
            data.count - startIndex
        guard appendedCount > 0 else {
            streamLock.broadcast()
            streamLock.unlock()
            return
        }
        let sourceOffset =
            streamBytesReceived
        streamBytesReceived &+=
            Int64(appendedCount)
        if startIndex == 0 {
            streamBuffer.append(data)
        } else {
            streamBuffer.append(
                data.subdata(
                    in: startIndex..<data.count
                )
            )
        }
        streamNoProgressAttempt = 1
        streamProgressDeadline = Date(
            timeIntervalSinceNow:
                persistentRetryController
                    .noProgressWindowSeconds(
                        forAttempt: 1
                    )
        )

        // Backpressure: park the transfer once the retained buffer exceeds
        // the high-water mark; readStreaming resumes below the low-water mark.
        var toSuspend:
            URLSessionDataTask?
        if !streamingTaskSuspended,
           streamBuffer.count
            > Self.streamHighWater {
            streamingTaskSuspended = true
            toSuspend = streamingTask
        }
        streamLock.broadcast()
        streamLock.unlock()
        toSuspend?.suspend()

        addBytesFetched(
            appendedCount,
            at: sourceOffset
        )
        streamDataReady.signal()
    }

    private func streamingConnectionEnded(
        completedWithoutError: Bool,
        generation: Int
    ) {
        var truncatedReplayBytes: Int64 = 0
        streamLock.lock()
        guard generation == streamGeneration else {
            streamLock.unlock()
            return
        }
        let madeUniqueProgress =
            streamBytesReceived
                > streamAttemptStartBytes
        if completedWithoutError,
           streamAttemptAcceptedResponse {
            if streamAttemptDiscardPrefixBytes
                > 0 {
                truncatedReplayBytes =
                    streamAttemptDiscardPrefixBytes
            } else {
                streamConfirmedEOF = true
            }
        } else if !madeUniqueProgress,
                  streamNoProgressAttempt
                    < Int.max {
            streamNoProgressAttempt += 1
        }
        streamProgressDeadline =
            .distantFuture
        streamLock.broadcast()
        streamLock.unlock()

        if truncatedReplayBytes > 0 {
            recordTerminalReaderError(
                .sourceByteStore(
                    .generationMismatch
                )
            )
        }
        streamDataReady.signal()
    }

    static func streamingResumePlan(
        statusCode: Int,
        requestedOffset: Int64,
        contentRange: String?,
        admittedValidator:
            SourceByteStoreValidator?,
        responseValidator:
            SourceByteStoreValidator?,
        contentEncoding: String?
    ) throws -> AVIOStreamingResumePlan {
        precondition(
            statusCode == 200
                || statusCode == 206
        )
        if let contentEncoding =
                contentEncoding?
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
           !contentEncoding.isEmpty,
           contentEncoding.lowercased()
            != "identity" {
            throw AVIOReaderError
                .sourceByteStore(
                    .unsupportedContentEncoding(
                        contentEncoding
                    )
                )
        }

        if requestedOffset == 0 {
            if statusCode == 206,
               Self.contentRangeStart(
                    contentRange
               ) != 0 {
                throw AVIOReaderError
                    .sourceByteStore(
                        .invalidRange
                    )
            }
            return AVIOStreamingResumePlan(
                discardPrefixBytes: 0,
                validator: responseValidator
            )
        }

        guard let admittedValidator else {
            throw AVIOReaderError
                .sourceByteStore(
                    .invalidGeneration
                )
        }
        guard responseValidator
                == admittedValidator else {
            throw AVIOReaderError
                .sourceByteStore(
                    .generationMismatch
                )
        }
        if statusCode == 206 {
            guard Self.contentRangeStart(
                contentRange
            ) == requestedOffset else {
                throw AVIOReaderError
                    .sourceByteStore(
                        .invalidRange
                    )
            }
            return AVIOStreamingResumePlan(
                discardPrefixBytes: 0,
                validator:
                    admittedValidator
            )
        }
        return AVIOStreamingResumePlan(
            discardPrefixBytes:
                requestedOffset,
            validator: admittedValidator
        )
    }

    private static func contentRangeStart(
        _ value: String?
    ) -> Int64? {
        guard let value else { return nil }
        let trimmed = value
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        guard trimmed.lowercased()
                .hasPrefix("bytes ") else {
            return nil
        }
        let rangeAndTotal =
            trimmed.dropFirst(6)
        guard let dash =
                rangeAndTotal.firstIndex(
                    of: "-"
                ) else {
            return nil
        }
        return Int64(
            rangeAndTotal[..<dash]
        )
    }

    private static func responseValidator(
        _ response: HTTPURLResponse
    ) -> SourceByteStoreValidator? {
        if let rawETag = response.value(
            forHTTPHeaderField: "ETag"
        )?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ),
           !rawETag.isEmpty,
           !rawETag.lowercased()
            .hasPrefix("w/") {
            return .strongETag(rawETag)
        }
        if let lastModified = response.value(
            forHTTPHeaderField:
                "Last-Modified"
        )?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ),
           !lastModified.isEmpty {
            return .lastModified(
                lastModified
            )
        }
        return nil
    }

    private static func ifRangeValue(
        for validator:
            SourceByteStoreValidator
    ) -> String {
        switch validator {
        case .strongETag(let value),
             .lastModified(let value):
            return value
        }
    }

    // MARK: - Prefetch (background, seekable mode only)

    private func triggerPrefetch(from offset: Int64) {
        guard prefetchEnabled else { return }
        if fileSize > 0 && offset >= fileSize { return }

        bufferLock.lock()
        guard !isPrefetching else { bufferLock.unlock(); return }
        isPrefetching = true
        bufferLock.unlock()

        prefetchQueue.async { [weak self] in
            guard let self = self else { return }

            // Bail if close() ran to avoid writing stale data back into prefetchBuffer.
            if self.isFullyClosed {
                self.bufferLock.lock()
                self.isPrefetching = false
                self.bufferLock.unlock()
                self.prefetchReady.signal()
                return
            }

            let size: Int
            if self.fileSize > 0 {
                size = min(self.chunkSize, Int(self.fileSize - offset))
            } else {
                size = self.chunkSize
            }

            let data = size > 0 ? self.fetchChunk(from: offset, size: size) : nil

            self.bufferLock.lock()
            // Re-check: close() may have fired while fetchChunk was on the network.
            if !self.isFullyClosed {
                self.prefetchBuffer = data
                self.prefetchOffset = offset
            }
            self.isPrefetching = false
            self.bufferLock.unlock()

            self.prefetchReady.signal()
        }
    }

    // MARK: - Seek

    fileprivate func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence == AVSEEK_SIZE { return fileSize }
        // For persistent mode, position is shared with the delegate thread;
        // read SEEK_CUR base under the window lock.
        let newPosition: Int64
        switch whence {
        case SEEK_SET:
            newPosition = offset
        case SEEK_CUR:
            if usePersistentReader {
                winCond.lock(); let cur = position; winCond.unlock()
                newPosition = cur + offset
            } else {
                newPosition = position + offset
            }
        case SEEK_END:
            guard fileSize >= 0 else { return -1 }
            newPosition = fileSize + offset
        default:
            return -1
        }

        if usePersistentReader {
            // Just move the cursor; the read loop decides whether to reconnect.
            // Coalesces the matroska seek-storm on open into minimal reconnects.
            winCond.lock()
            position = newPosition
            winCond.broadcast()
            winCond.unlock()
        } else if !isStreaming {
            position = newPosition
            bufferLock.lock()
            let inCurrent = position >= currentOffset &&
                position < currentOffset + Int64(currentBuffer.count)
            if !inCurrent {
                currentBuffer = Data()
                currentOffset = position
                prefetchBuffer = nil
            }
            bufferLock.unlock()
        } else {
            // Streaming: forward-only; backward seeks below the retained
            // window fail explicitly because this reader cannot reconstruct
            // bytes it has already discarded.
            streamLock.lock()
            let oldestRetained = streamBytesRead
            streamLock.unlock()
            if newPosition < oldestRetained { return -1 }
            position = newPosition
        }

        return newPosition
    }

    // MARK: - Network (seekable mode)

    /// Long-lived session for file-size probes. Per-request sessions force fresh TLS
    /// handshakes, which Cloudflare-fronted origins can flag as suspicious. Distinct
    /// from syncRequest's per-request pattern (load-bearing for chunk-fetch leak control).
    private static let probeSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config, delegate: nil, delegateQueue: nil)
    }()

    private enum SourceStoreValidationResult {
        case valid
        case changed
        case failed(reason: String)
        case terminal(AVIOReaderError)
    }

    private func validateSourceStore(
        _ candidate: SourceByteStoreGeneration,
        allowResolvedExpiryRetry: Bool = true
    ) -> SourceStoreValidationResult {
        guard let validator = candidate.validator else {
            return .failed(reason: "complete store has no response validator")
        }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        switch validator {
        case .strongETag(let value), .lastModified(let value):
            request.setValue(value, forHTTPHeaderField: "If-Range")
        }
        request.timeoutInterval = min(20, chunkRequestTimeout)
        applyExtraHeaders(&request)
        applySourceByteStoreHeaders(&request)

        guard let ioActivity =
                ioQuiescence.beginActivity() else {
            return .failed(
                reason: "conditional range validation cancelled"
            )
        }
        let delegate = SourceByteStoreValidationDelegate(
            extraHeaders: extraHeaders,
            ioActivity: ioActivity
        )
        let task = Self.probeSession.dataTask(with: request)
        task.delegate = delegate
        let semaphore = DispatchSemaphore(value: 0)
        delegate.onCompletion = { semaphore.signal() }
        task.resume()

        let outcome = Self.awaitSignal(
            semaphore,
            budget: min(25, chunkRequestTimeout),
            pollInterval: 0.1,
            shouldAbort: { [weak self] in self?.isClosed == true }
        )
        guard outcome == .signaled else {
            task.cancel()
            return .failed(reason: "conditional range validation timed out")
        }
        guard let response = delegate.response else {
            return .failed(reason: "conditional range validation returned no response")
        }
        let shouldRetryCanonical = handleHardHTTPStatus(
            response.statusCode,
            responseWasResolvedUpstream:
                delegate.didFollowRedirect
        )
        if shouldRetryCanonical,
           allowResolvedExpiryRetry {
            return validateSourceStore(
                candidate,
                allowResolvedExpiryRetry: false
            )
        }
        if let error = Self.terminalHTTPError(
            statusCode: response.statusCode,
            responseWasResolvedUpstream:
                delegate.didFollowRedirect
        ) {
            return .terminal(error)
        }
        switch response.statusCode {
        case 206:
            if let contentEncoding = response.value(
                forHTTPHeaderField: "Content-Encoding"
            )?.trimmingCharacters(in: .whitespacesAndNewlines),
               !contentEncoding.isEmpty,
               contentEncoding.lowercased() != "identity" {
                return .failed(
                    reason: "conditional range validation used "
                        + "Content-Encoding \(contentEncoding)"
                )
            }
            guard Self.sourceStoreGenerationMatches(
                candidate,
                response: response,
                requestedOffset: 0
            ) else {
                return .changed
            }
            return .valid
        case 200, 412, 416:
            return .changed
        default:
            return .failed(
                reason: "conditional range validation returned HTTP "
                    + "\(response.statusCode)"
            )
        }
    }

    /// Total size from a data-connection response: `Content-Range` total on a 206, or
    /// `Content-Length` on a from-0 2xx (origins that answer 200 ignoring Range). Nil when
    /// the origin gave no usable length (chunked, or an unknown `*` total). Issue #70.
    static func sizeFromResponse(_ http: HTTPURLResponse, requestedOffset: Int64) -> Int64? {
        // On a 206 the total lives ONLY in Content-Range; Content-Length is the partial span,
        // so a 206 with an unknown (`*`) or unparseable range must report no size, never fall
        // through to the partial length (issue #70 review #6).
        if http.statusCode == 206 {
            guard let cr = http.value(forHTTPHeaderField: "Content-Range"),
                  let total = HTTPDiscIOReader.parseContentRangeTotal(cr), total > 0 else {
                return nil
            }
            return total
        }
        if (200...299).contains(http.statusCode), requestedOffset == 0,
           http.expectedContentLength > 0 {
            return http.expectedContentLength
        }
        return nil
    }

    /// #112: resolve the source length for the open, preferring a live probe and falling back to a length another
    /// demuxer already resolved for the same origin. A fresh probe here can be 429'd or answered without a length
    /// while the video producer is hammering the origin, which would drop this reader to forward-only streaming so
    /// every `avformat_seek_file` returns -1 and PGS reconstruction reads nothing. The producer's persistent open
    /// caches the real length (SourceContentLengthCache.store at the data-connection response), so a starved probe
    /// reuses it and stays byte-seekable. A successful probe also seeds the cache for whoever opens next.
    private func resolveInitialFileSize() -> Int64 {
        let probed = probeFileSize()
        if probed > 0 {
            SourceContentLengthCache.store(probed, for: url)
            return probed
        }
        if let cached = SourceContentLengthCache.lookup(url), cached > 0 {
            EngineLog.emit("[AVIOReader] size probe empty; reusing cached \(cached) bytes to keep seekability (#112)", category: .demux)
            return cached
        }
        return probed
    }

    private func probeFileSize() -> Int64 {
        // Range bytes=0- probe (AetherEngine#8: HEAD breaks on Cloudflare-fronted
        // origins returning 405). Without a known size, streaming mode is used and
        // SEEK_SET/SEEK_END return -1, breaking MKV/AVI index seeks and scrubbing.
        if let size = rangeProbeFileSize(range: "bytes=0-"), size > 0 {
            #if DEBUG
            EngineLog.emit("[AVIOReader] File size: \(size) bytes (Range probe)", category: .demux)
            #endif
            return size
        }
        if terminalError != nil {
            return -1
        }
        let headSize = headProbeFileSize()
        if headSize > 0 { return headSize }
        if terminalError != nil {
            return -1
        }
        // #126: origins that answer bytes=0- with 200/chunked (no length) and reject HEAD can
        // still honor real ranges (Emby behind a buffering proxy). A bounded two-byte range is
        // the last probe before degrading to forward-only streaming mode; a 206 carries the
        // total in Content-Range.
        if let size = rangeProbeFileSize(range: "bytes=0-1"), size > 0 {
            EngineLog.emit("[AVIOReader] File size: \(size) bytes (bounded-range fallback)", category: .demux)
            return size
        }
        EngineLog.emit("[AVIOReader] no probe resolved a size, streaming mode (forward-only)", category: .demux)
        return -1
    }

    /// Range GET cancelled at didReceive response (no body transfers). Returns the total from
    /// Content-Range on 206, or expectedContentLength on 2xx (origins that ignore Range).
    /// The primary probe is the open-ended bytes=0- form; bytes=0- over bytes=0-0: some origins
    /// special-case the single-byte form and omit length, then 429 the HEAD fallback (issue #70);
    /// bytes=0- answers with a proper Content-Range in one shot. The bounded bytes=0-1 form is
    /// the #126 last-resort probe for origins that answer bytes=0- without a length but honor
    /// real ranges.
    private func rangeProbeFileSize(
        range: String,
        allowResolvedExpiryRetry: Bool = true
    ) -> Int64? {
        var request = URLRequest(url: url)
        request.setValue(range, forHTTPHeaderField: "Range")
        request.timeoutInterval = 20
        applyExtraHeaders(&request)
        applySourceByteStoreHeaders(&request)

        guard let ioActivity =
                ioQuiescence.beginActivity() else {
            return nil
        }
        let delegate = ProbeDelegate(
            extraHeaders: extraHeaders,
            ioActivity: ioActivity
        )
        let task = Self.probeSession.dataTask(with: request)
        task.delegate = delegate

        let semaphore = DispatchSemaphore(value: 0)
        delegate.onCompletion = { semaphore.signal() }
        delegate.onResolved = { [weak self] resolved in
            self?.recordResolvedURL(resolved)
        }
        task.resume()

        // Bound + make abortable: still extraction caps this at its small budget so a
        // reopen mid-scrub on a stalled source can't park ~25s, and a teardown during
        // open returns at once (issue #27). Playback keeps its 25s ceiling.
        let probeBudget = min(25, chunkRequestTimeout)
        if Self.awaitSignal(semaphore, budget: probeBudget, pollInterval: 0.1,
                            shouldAbort: { [weak self] in
                                self?.isClosed == true
                            }) != .signaled {
            task.cancel()
            EngineLog.emit("[AVIOReader] Range probe (\(range)) timed out", category: .demux, level: .verbose)
            return nil
        }

        if delegate.totalSize == nil {
            EngineLog.emit("[AVIOReader] Range probe (\(range)) didn't yield a size", category: .demux, level: .verbose)
        }
        if let statusCode = delegate.statusCode {
            let shouldRetryCanonical =
                handleHardHTTPStatus(
                statusCode,
                responseWasResolvedUpstream:
                    delegate.didFollowRedirect
            )
            if shouldRetryCanonical,
               allowResolvedExpiryRetry {
                return rangeProbeFileSize(
                    range: range,
                    allowResolvedExpiryRetry: false
                )
            }
        }
        return delegate.totalSize
    }

    /// HEAD probe fallback for live-transcode endpoints that reject Range.
    private func headProbeFileSize(
        allowResolvedExpiryRetry: Bool = true
    ) -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        applyExtraHeaders(&request)
        applySourceByteStoreHeaders(&request)

        do {
            // Honour the still budget here too so the open-time HEAD fallback can't
            // ride the default 35s on a stalled origin during a cold/reopen scrub (#27).
            let result = try syncRequest(
                request,
                budget: chunkRequestTimeout
            )
            let response = result.response
            guard let http = response as? HTTPURLResponse else {
                EngineLog.emit("[AVIOReader] HEAD failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1))", category: .demux, level: .verbose)
                return -1
            }
            guard (200...299).contains(http.statusCode) else {
                let shouldRetryCanonical =
                    handleHardHTTPStatus(
                    http.statusCode,
                    responseWasResolvedUpstream:
                        result.didFollowRedirect
                )
                if shouldRetryCanonical,
                   allowResolvedExpiryRetry {
                    return headProbeFileSize(
                        allowResolvedExpiryRetry: false
                    )
                }
                EngineLog.emit("[AVIOReader] HEAD failed (HTTP \(http.statusCode))", category: .demux, level: .verbose)
                return -1
            }
            let length = http.expectedContentLength
            #if DEBUG
            EngineLog.emit("[AVIOReader] File size: \(length) bytes (HEAD fallback)", category: .demux)
            #endif
            return length
        } catch {
            return -1
        }
    }

    private struct OriginChunk {
        let data: Data
        let generation: SourceByteStoreGeneration?
    }

    private func fetchChunk(from offset: Int64, size: Int) -> Data? {
        guard let sourceByteStore else {
            return fetchOriginChunk(
                from: offset,
                size: size
            )?.data
        }
        do {
            return try sourceByteStore.fetchExactRange(
                at: offset,
                length: size,
                shouldAbort: { [weak self] in
                    guard let self else { return true }
                    return self.isClosed
                        || self.readDeadlinePassedOrAborted
                },
                originFetch: { [weak self] in
                    guard let self else {
                        throw SourceByteStoreError.cancelled
                    }
                    guard let origin = self.fetchOriginChunk(
                        from: offset,
                        size: size
                    ) else {
                        if let failure =
                                self.sourceStoreFailure {
                            throw failure
                        }
                        if self.isClosed
                            || self.readDeadlinePassedOrAborted {
                            throw SourceByteStoreError.cancelled
                        }
                        throw SourceByteStoreError.rangeFetchFailed
                    }
                    guard let generation = origin.generation else {
                        throw SourceByteStoreError
                            .invalidGeneration
                    }
                    return SourceByteStoreFetchedRange(
                        generation: generation,
                        data: origin.data
                    )
                }
            )
        } catch let error as SourceByteStoreError
                where error == .cancelled
                    || error == .rangeFetchFailed {
            return nil
        } catch SourceByteStoreError
                .rangeFetchRateLimited(_) {
            return nil
        } catch let error as SourceByteStoreError {
            recordSourceStoreFailure(error)
            return nil
        } catch {
            recordSourceStoreFailure(
                .rangeFetchFailed
            )
            return nil
        }
    }

    #if DEBUG
    func fetchChunkForTesting(
        from offset: Int64,
        size: Int
    ) -> Data? {
        fetchChunk(from: offset, size: size)
    }

    func startUnknownLengthStreamForTesting() {
        startStreamingDownload()
    }

    func readUnknownLengthStreamForTesting(
        maximumLength: Int
    ) -> (result: Int32, data: Data) {
        var data = Data(
            count: max(1, maximumLength)
        )
        let result = data
            .withUnsafeMutableBytes { raw in
                readStreaming(
                    into: raw.baseAddress!
                        .assumingMemoryBound(
                            to: UInt8.self
                        ),
                    size: Int32(
                        max(1, maximumLength)
                    )
                )
            }
        if result > 0 {
            data.count = Int(result)
        } else {
            data.removeAll()
        }
        return (result, data)
    }

    func readPersistentStreamForTesting(
        maximumLength: Int
    ) -> (result: Int32, data: Data) {
        var data = Data(
            count: max(1, maximumLength)
        )
        let result = data
            .withUnsafeMutableBytes { raw in
                readPersistent(
                    into: raw.baseAddress!
                        .assumingMemoryBound(
                            to: UInt8.self
                        ),
                    size: Int32(
                        max(1, maximumLength)
                    )
                )
            }
        if result > 0 {
            data.count = Int(result)
        } else {
            data.removeAll()
        }
        return (result, data)
    }

    var unknownLengthStreamGenerationForTesting:
        Int {
        streamLock.lock()
        defer { streamLock.unlock() }
        return streamGeneration
    }

    var unknownLengthMaximumConcurrentReadersForTesting:
        Int {
        streamLock.lock()
        defer { streamLock.unlock() }
        return streamMaximumConcurrentReaderCount
    }

    var unknownLengthBytesReceivedForTesting:
        Int64 {
        streamLock.lock()
        defer { streamLock.unlock() }
        return streamBytesReceived
    }

    func appendUnknownLengthDataForTesting(
        _ data: Data,
        generation: Int
    ) {
        appendStreamingData(
            data,
            generation: generation
        )
    }
    #endif

    private func fetchOriginChunk(
        from offset: Int64,
        size: Int
    ) -> OriginChunk? {
        let hadCachedResolvedURL =
            cachedResolvedURL() != nil
        let firstAttempt = fetchChunkAttempt(
            from: offset,
            size: size,
            forceSource: false
        )
        if let chunk = firstAttempt.chunk {
            return chunk
        }
        // Retry against source URL only if a cached resolved URL was used
        // or this canonical request followed a redirect to an expired
        // resolved upstream (so the proxy can re-issue a fresh signature).
        if (hadCachedResolvedURL
                || firstAttempt.shouldRetryCanonical),
           sourceStoreFailure == nil {
            return fetchChunkAttempt(
                from: offset,
                size: size,
                forceSource: true
            ).chunk
        }
        return nil
    }

    private func fetchChunkAttempt(
        from offset: Int64,
        size: Int,
        forceSource: Bool
    ) -> (
        chunk: OriginChunk?,
        shouldRetryCanonical: Bool
    ) {
        let usingCachedURL = !forceSource && cachedResolvedURL() != nil
        let target = forceSource ? url : requestURL()
        let rangeEnd = offset + Int64(size) - 1
        var request = URLRequest(url: target)
        request.setValue("bytes=\(offset)-\(rangeEnd)", forHTTPHeaderField: "Range")
        request.timeoutInterval = min(15, chunkRequestTimeout)
        applyExtraHeaders(&request)
        applySourceByteStoreHeaders(&request)

        var lastError: Error?
        for attempt in 0..<chunkMaxRetries {
            do {
                let result = try syncRequest(
                    request,
                    budget: chunkRequestTimeout
                )
                let data = result.data
                let response = result.response
                var sourceGeneration:
                    SourceByteStoreGeneration?
                if let http = response as? HTTPURLResponse {
                    let status = http.statusCode
                    if status != 200 && status != 206 {
                        let shouldRetryCanonical =
                            handleHardHTTPStatus(
                            status,
                            responseWasResolvedUpstream:
                                usingCachedURL
                                    || result.didFollowRedirect
                        )
                        EngineLog.emit("[AVIOReader] chunk fetch got HTTP \(status) at offset \(offset)\(usingCachedURL ? " (cached URL, will retry source)" : "")", category: .demux, level: .verbose)
                        return (
                            nil,
                            shouldRetryCanonical
                        )
                    }
                    // VOD: 200 at offset > 0 = server ignored Range; silent corruption. Reject.
                    if status == 200 && offset > 0 && !isLive {
                        EngineLog.emit(
                            "[AVIOReader] server ignored Range (200 for offset \(offset)); rejecting chunk",
                            category: .demux
                        )
                        return (nil, false)
                    }
                    if sourceByteStore != nil {
                        guard let generation =
                                sourceStoreFetchGeneration(
                                    response: http,
                                    requestedOffset: offset
                                ) else {
                            return (nil, false)
                        }
                        sourceGeneration = generation
                    }
                }
                addBytesFetched(
                    data.count,
                    at: offset
                )
                return (
                    OriginChunk(
                        data: data,
                        generation: sourceGeneration
                    ),
                    false
                )
            } catch {
                // Superseded / closed / past the read deadline: this read is disposable,
                // bail at once instead of retrying into the abort (issue #27).
                if isClosed || isPastReadDeadline {
                    return (nil, false)
                }
                lastError = error
                if attempt < chunkMaxRetries - 1 {
                    Thread.sleep(forTimeInterval: Double(1 << attempt) * 0.5)
                }
            }
        }

        _ = lastError
        return (nil, false)
    }

    /// Long-lived session for seekable-path chunk fetches paired with per-task
    /// ChunkFetchDelegate. Delegate-based incremental delivery (not completion-handler)
    /// releases source dispatch_data per delivery, avoiding the task-pool accumulation
    /// that drove the original leak (completion-handler style). No invalidation overhead.
    private static let chunkSession: URLSession = {
        let config = makeSessionConfig()
        return URLSession(configuration: config, delegate: nil, delegateQueue: nil)
    }()

    /// Outcome of an abortable semaphore wait (issue #27).
    enum WaitOutcome: Equatable { case signaled, timedOut, aborted }

    /// Wait on `semaphore` up to `budget` seconds, polling `shouldAbort` every
    /// `pollInterval`. Returns `.signaled` the moment the semaphore fires,
    /// `.aborted` within one poll of `shouldAbort()` going true, or `.timedOut`
    /// when the budget elapses. Lets a seekable chunk read bail promptly on
    /// supersede / close / read-deadline instead of parking the decode queue in a
    /// flat 35s wait (the root cause of the frozen scrub preview, issue #27).
    static func awaitSignal(
        _ semaphore: DispatchSemaphore,
        budget: TimeInterval,
        pollInterval: TimeInterval,
        shouldAbort: () -> Bool
    ) -> WaitOutcome {
        let deadline = Date(timeIntervalSinceNow: budget)
        while true {
            if shouldAbort() { return .aborted }
            let now = Date()
            if now >= deadline { return .timedOut }
            let slice = min(pollInterval, deadline.timeIntervalSince(now))
            if semaphore.wait(timeout: .now() + max(0.001, slice)) == .success {
                return .signaled
            }
        }
    }

    private func syncRequest(
        _ request: URLRequest,
        budget: TimeInterval = 35
    ) throws -> (
        data: Data,
        response: URLResponse,
        didFollowRedirect: Bool
    ) {
        guard let ioActivity =
                ioQuiescence.beginActivity() else {
            throw CancellationError()
        }
        let delegate = ChunkFetchDelegate(
            extraHeaders: extraHeaders,
            ioActivity: ioActivity
        )
        let task = Self.chunkSession.dataTask(with: request)
        task.delegate = delegate

        let semaphore = DispatchSemaphore(value: 0)
        delegate.onCompletion = { semaphore.signal() }
        delegate.onResolved = { [weak self] resolved in
            self?.recordResolvedURL(resolved)
        }
        task.resume()

        // Poll for close / read-deadline so a superseded or torn-down still-extraction
        // read aborts within ~100ms instead of riding the full budget (issue #27).
        let outcome = Self.awaitSignal(
            semaphore, budget: budget, pollInterval: 0.1,
            shouldAbort: { [weak self] in self?.isClosed == true || self?.readDeadlinePassedOrAborted == true }
        )
        guard outcome == .signaled else {
            task.cancel()
            throw AVIOReaderError.requestTimeout
        }

        if let err = delegate.error { throw err }
        guard let response = delegate.response else { throw AVIOReaderError.noResponse }
        return (
            delegate.body,
            response,
            delegate.didFollowRedirect
        )
    }
}

// MARK: - Detour Block Cache

/// Fixed-block LRU cache backing the persistent reader's detour path (AetherEngine#69). Random-access
/// parse reads on a non-faststart remote MP4 are served from here over the pooled keep-alive session
/// instead of tearing down the anchored streaming connection. Thread-safe via a single leaf lock
/// (demux-thread reads + teardown-thread `clear`); never held across the network. Stores only
/// full-size blocks (the fetch/insert decision is the caller's), so eviction can't shadow a
/// re-fetchable short-body tail. The copy + eviction math is pure and unit-tested without a network.
final class DetourBlockCache: @unchecked Sendable {
    private let lock = NSLock()
    private var blocks: [Int64: Data] = [:]
    private var lru: [Int64] = []
    private let maxBlocks: Int
    let blockSize: Int

    init(blockSize: Int, maxBlocks: Int) {
        self.blockSize = blockSize
        self.maxBlocks = maxBlocks
    }

    /// Returns the resident block for `idx` and bumps its recency, or nil on a miss.
    func block(_ idx: Int64) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let data = blocks[idx] else { return nil }
        if let i = lru.firstIndex(of: idx) {
            lru.remove(at: i)
            lru.append(idx)
        }
        return data
    }

    /// Inserts a (full-size) block, evicting the least-recently-used tail beyond `maxBlocks`.
    func insert(_ idx: Int64, _ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if blocks[idx] == nil { lru.append(idx) }
        blocks[idx] = data
        while lru.count > maxBlocks {
            blocks.removeValue(forKey: lru.removeFirst())
        }
    }

    func clear() {
        lock.lock()
        blocks.removeAll()
        lru.removeAll()
        lock.unlock()
    }

    var residentCount: Int {
        lock.lock(); defer { lock.unlock() }
        return blocks.count
    }

    /// Copy up to `maxLen` bytes covering `offset` from the resident block into `dst`, returning the
    /// byte count. Returns nil if the covering block is not resident, or if `offset` lands in the
    /// uncovered tail of a short block (so the caller re-fetches rather than serving stale bytes).
    /// One call serves at most to the block boundary; a read spanning blocks is driven by the caller
    /// re-entering at the advanced offset. Pure given the cache contents; bumps recency on a hit.
    func serveCached(into dst: UnsafeMutablePointer<UInt8>, maxLen: Int, at offset: Int64) -> Int? {
        guard maxLen > 0, offset >= 0 else { return nil }
        let idx = offset / Int64(blockSize)
        let blockStart = idx * Int64(blockSize)
        guard let blk = block(idx) else { return nil }
        let inBlock = Int(offset - blockStart)
        guard inBlock >= 0, inBlock < blk.count else { return nil }
        let n = min(maxLen, blk.count - inBlock)
        blk.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                dst.update(from: base.advanced(by: inBlock).assumingMemoryBound(to: UInt8.self), count: n)
            }
        }
        return n
    }
}

/// Preserves Range + extra headers across cross-host redirects. URLSession strips
/// custom headers on host change; without this, CDN behind AIOStreams proxy gets a
/// plain GET and either streams the full body or 400s.
private func redirectPreservingHeaders(
    task: URLSessionTask,
    newRequest request: URLRequest,
    extraHeaders: [String: String]
) -> URLRequest {
    var updated = request
    for (name, value) in extraHeaders {
        updated.setValue(value, forHTTPHeaderField: name)
    }
    if let originalRange = task.originalRequest?.value(forHTTPHeaderField: "Range") {
        updated.setValue(originalRange, forHTTPHeaderField: "Range")
    }
    if let originalIfRange = task.originalRequest?
        .value(forHTTPHeaderField: "If-Range") {
        updated.setValue(originalIfRange, forHTTPHeaderField: "If-Range")
    }
    if let originalEncoding = task.originalRequest?
        .value(forHTTPHeaderField: "Accept-Encoding") {
        updated.setValue(
            originalEncoding,
            forHTTPHeaderField: "Accept-Encoding"
        )
    }
    return updated
}

// MARK: - Persistent Read Delegate

/// Forwards deliveries into the reader's sliding window with generation tagging
/// so stale-connection late callbacks are no-ops. @unchecked Sendable: only
/// mutable coupling is weak reader, guarded by winCond.
private final class PersistentReadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    weak var reader: AVIOReader?
    let generation: Int
    let extraHeaders: [String: String]
    let usedCachedResolvedURL: Bool
    let ioActivity: AetherIOActivityToken
    private var didFollowRedirect = false

    init(
        reader: AVIOReader,
        generation: Int,
        extraHeaders: [String: String],
        usedCachedResolvedURL: Bool,
        ioActivity: AetherIOActivityToken
    ) {
        self.reader = reader
        self.generation = generation
        self.extraHeaders = extraHeaders
        self.usedCachedResolvedURL =
            usedCachedResolvedURL
        self.ioActivity = ioActivity
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        didFollowRedirect = true
        completionHandler(redirectPreservingHeaders(
            task: task, newRequest: request, extraHeaders: extraHeaders))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, let reader else {
            completionHandler(.cancel)
            return
        }
        let resolved = (http.statusCode == 200 || http.statusCode == 206)
            ? dataTask.currentRequest?.url
            : nil
        let allow = reader.persistentReceivedResponse(
            http,
            resolvedURL: resolved,
            generation: generation,
            responseWasResolvedUpstream:
                usedCachedResolvedURL || didFollowRedirect
        )
        completionHandler(allow ? .allow : .cancel)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        reader?.appendPersistentData(data, generation: generation)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        reader?.persistentConnectionEnded(error: error, generation: generation)
        ioActivity.complete()
    }
}

// MARK: - Chunk Fetch Delegate

/// Single-use per fetch; force-copies each delivery into `body` so source
/// dispatch_data is released per delivery. @unchecked Sendable: ownership
/// via semaphore ensures no concurrent access to mutable fields.
private final class ChunkFetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let extraHeaders: [String: String]
    var body = Data()
    var response: URLResponse?
    var error: Error?
    var onCompletion: (() -> Void)?
    var onResolved: ((URL) -> Void)?
    private(set) var didFollowRedirect = false
    let ioActivity: AetherIOActivityToken

    init(
        extraHeaders: [String: String],
        ioActivity: AetherIOActivityToken
    ) {
        self.extraHeaders = extraHeaders
        self.ioActivity = ioActivity
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        didFollowRedirect = true
        completionHandler(redirectPreservingHeaders(
            task: task, newRequest: request, extraHeaders: extraHeaders))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        self.response = response
        if let http = response as? HTTPURLResponse {
            let len = Int(http.expectedContentLength)
            if len > 0 { body.reserveCapacity(len) }
            let status = http.statusCode
            if status == 200 || status == 206,
               let resolved = dataTask.currentRequest?.url {
                onResolved?(resolved)
            }
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        // Force-copy: body.append(data) may retain source dispatch_data via CoW,
        // defeating the per-delivery release. Manual memcpy guarantees drop on return.
        let count = data.count
        let baseCount = body.count
        body.count = baseCount + count
        body.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                if let dstBase = dst.baseAddress, let srcBase = src.baseAddress {
                    (dstBase + baseCount).copyMemory(from: srcBase, byteCount: count)
                }
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        self.error = error
        onCompletion?()
        ioActivity.complete()
    }
}

// MARK: - Streaming Delegate

private final class StreamingDelegate:
    NSObject,
    URLSessionDataDelegate,
    @unchecked Sendable
{
    let extraHeaders: [String: String]
    let onResponse:
        @Sendable (
            HTTPURLResponse,
            URL?,
            Bool
        ) -> Bool
    let onData: @Sendable (Data) -> Void
    let onComplete: @Sendable (Bool) -> Void
    let onStopped: @Sendable () -> Void
    let ioActivity: AetherIOActivityToken
    private var didFollowRedirect = false

    init(
        extraHeaders: [String: String],
        onResponse:
            @escaping @Sendable (
                HTTPURLResponse,
                URL?,
                Bool
            ) -> Bool,
        onData: @escaping @Sendable (Data) -> Void,
        onComplete:
            @escaping @Sendable (Bool) -> Void,
        onStopped:
            @escaping @Sendable () -> Void,
        ioActivity: AetherIOActivityToken
    ) {
        self.extraHeaders = extraHeaders
        self.onResponse = onResponse
        self.onData = onData
        self.onComplete = onComplete
        self.onStopped = onStopped
        self.ioActivity = ioActivity
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        didFollowRedirect = true
        completionHandler(
            redirectPreservingHeaders(
                task: task,
                newRequest: request,
                extraHeaders: extraHeaders
            )
        )
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler:
            @escaping (
                URLSession.ResponseDisposition
            ) -> Void
    ) {
        guard let http =
                response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        let resolvedURL =
            (http.statusCode == 200
                || http.statusCode == 206)
                ? dataTask.currentRequest?.url
                : nil
        completionHandler(
            onResponse(
                http,
                resolvedURL,
                didFollowRedirect
            )
                ? .allow
                : .cancel
        )
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        onData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onComplete(error == nil)
        ioActivity.complete()
        onStopped()
    }
}

// MARK: - Source Byte Store Validation Delegate

/// Captures only response headers for a conditional one-byte Range request, then cancels before
/// the response body can redownload cached media. `If-Range` is preserved across redirects by the
/// shared redirect helper.
private final class SourceByteStoreValidationDelegate:
    NSObject,
    URLSessionDataDelegate,
    @unchecked Sendable
{
    let extraHeaders: [String: String]
    var response: HTTPURLResponse?
    var onCompletion: (() -> Void)?
    let ioActivity: AetherIOActivityToken
    private(set) var didFollowRedirect = false

    init(
        extraHeaders: [String: String],
        ioActivity: AetherIOActivityToken
    ) {
        self.extraHeaders = extraHeaders
        self.ioActivity = ioActivity
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        didFollowRedirect = true
        completionHandler(redirectPreservingHeaders(
            task: task,
            newRequest: request,
            extraHeaders: extraHeaders
        ))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        self.response = response as? HTTPURLResponse
        completionHandler(.cancel)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        onCompletion?()
        ioActivity.complete()
    }
}

// MARK: - Probe Delegate

/// File-size Range probe delegate. Preserves Range across cross-host redirects,
/// captures total from Content-Range, cancels before the body streams.
/// @unchecked Sendable: single-use per probe, semaphore ownership prevents concurrency.
private final class ProbeDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let extraHeaders: [String: String]
    var totalSize: Int64?
    var statusCode: Int?
    var onCompletion: (() -> Void)?
    var onResolved: ((URL) -> Void)?
    private(set) var didFollowRedirect = false
    let ioActivity: AetherIOActivityToken

    init(
        extraHeaders: [String: String],
        ioActivity: AetherIOActivityToken
    ) {
        self.extraHeaders = extraHeaders
        self.ioActivity = ioActivity
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        didFollowRedirect = true
        completionHandler(redirectPreservingHeaders(
            task: task, newRequest: request, extraHeaders: extraHeaders))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        defer { completionHandler(.cancel) }
        guard let http = response as? HTTPURLResponse else { return }
        let status = http.statusCode
        statusCode = status
        if (200...299).contains(status), let resolved = dataTask.currentRequest?.url {
            onResolved?(resolved)
        }
        // The probe requests `bytes=0-`, so requestedOffset is 0. Shared with the
        // data-connection path so a 206 with an unknown (`*`) total never reports its
        // partial Content-Length as the size (issue #70 review #6).
        totalSize = AVIOReader.sizeFromResponse(http, requestedOffset: 0)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onCompletion?()
        ioActivity.complete()
    }
}

// MARK: - C Callbacks


// AVERROR(EIO) = -5: live source lost (distinct from AVERROR_EOF).
private func readCallback(
    opaque: UnsafeMutableRawPointer?,
    buf: UnsafeMutablePointer<UInt8>?,
    size: Int32
) -> Int32 {
    guard let opaque = opaque, let buf = buf else { return -1 }
    let reader = Unmanaged<AVIOReader>.fromOpaque(opaque).takeUnretainedValue()
    return reader.read(into: buf, size: size)
}

private func seekCallback(
    opaque: UnsafeMutableRawPointer?,
    offset: Int64,
    whence: Int32
) -> Int64 {
    guard let opaque = opaque else { return -1 }
    let reader = Unmanaged<AVIOReader>.fromOpaque(opaque).takeUnretainedValue()
    return reader.seek(offset: offset, whence: whence)
}

// MARK: - Errors

enum AVIOReaderError:
    Error,
    CustomStringConvertible,
    Sendable,
    Equatable
{
    case allocationFailed
    case noResponse
    case requestTimeout
    case httpStatus(statusCode: Int)
    case sourceByteStore(SourceByteStoreError)
    case sourceByteStoreValidationFailed(reason: String)

    var description: String {
        switch self {
        case .allocationFailed: return "Failed to allocate AVIO buffer"
        case .noResponse: return "No response from server"
        case .requestTimeout: return "Request timed out"
        case .httpStatus(let statusCode):
            return "HTTP source rejected request with status \(statusCode)"
        case .sourceByteStore(let error):
            return error.localizedDescription
        case .sourceByteStoreValidationFailed(let reason):
            return "Source byte store validation failed: \(reason)"
        }
    }
}
