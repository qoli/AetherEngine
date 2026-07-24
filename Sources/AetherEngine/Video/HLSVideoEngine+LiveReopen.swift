import Foundation

extension HLSVideoEngine {

    /// Pure transport-recovery decision. A VOD read error is never silently
    /// parked, even after media was produced. Zero-output EOF is also
    /// transport-shaped because a successfully probed video cannot naturally
    /// finish before its first packet.
    static func requiresVODSourceRecovery(
        reason: HLSSegmentProducer.PumpExitReason,
        isLive: Bool,
        packetsWritten: Int,
        cachedSegments: Int
    ) -> Bool {
        guard !isLive else { return false }
        switch reason {
        case .readError:
            return true
        case .eof:
            return packetsWritten == 0
                && cachedSegments == 0
        default:
            return false
        }
    }

    func handlePumpFinished(_ prod: HLSSegmentProducer,
                                    reason: HLSSegmentProducer.PumpExitReason) {
        if case .readError(let code) = reason {
            guard let epoch =
                    currentProducerEpoch(
                        prod
                    ) else {
                return
            }
            let error: Error =
                prod.terminalReadError
                    ?? DemuxerError.readFailed(
                        code: code
                    )
            switch HLSReopenFailureClassifier
                .classify(
                    error,
                    caseCode: isLiveSession
                        ? "live.read"
                        : "vod.read",
                    hasCompleteValidatedSourceEvidence:
                        hasCompleteValidatedProgressiveSourceEvidence
                ) {
            case .cancelled:
                return
            case .permanent(let failure):
                _ = publishTerminalReopenFailure(
                    failure,
                    epoch: epoch,
                    expectedProducer: prod
                )
                return
            case .retry:
                if !isLiveSession {
                    scheduleVODSourceRecovery(
                        failedProducer: prod,
                        trigger:
                            "transientRead"
                    )
                    return
                }
                // Live URL sources continue into the same-source reopen loop.
            }
        }
        if Self.requiresVODSourceRecovery(
            reason: reason,
            isLive: isLiveSession,
            packetsWritten:
                prod.packetsWrittenCount,
            cachedSegments:
                cache?.count ?? 0
        ), case .eof = reason {
            // A VOD probed as playable cannot naturally finish before one
            // packet or segment. Treat this as truncated weak-network input,
            // not as successful EOF or a terminal elapsed-time outcome.
            scheduleVODSourceRecovery(
                failedProducer: prod,
                trigger: "zeroOutputEOF"
            )
            return
        }
        // #65 (VOD only): a broken backpressure wedge means AVPlayer is stuck behind a parked producer.
        // Re-anchor the producer on AVPlayer's real position so the segments it is starved for get produced.
        if case .backpressureWedge = reason,
           !isLiveSession {
            handleBackpressureWedge(prod)
            return
        }
        // #99 failure mode B: a VOD muxer death (e.g. first cut before any bridged audio packet, so
        // mov_write_moov cannot build the dec3 box) previously had NO recovery arm; the session sat
        // starved forever. Bounded revive through the normal restart path, which rebuilds the muxer
        // and re-arms (post-EOF: rebuilds) the audio bridge.
        if case .muxerFailed = reason, !isLiveSession {
            handleVODMuxerFailure(prod)
            return
        }
        guard isLiveSession else { return }
        switch reason {
        case .stopRequested:
            return
        case .muxerFailed:
            publishCurrentProducerStructuralFailure(
                producer: prod,
                kind: .routeRuntimeFailure,
                caseCode: "live.muxerFailed"
            )
            return
        case .backpressureWedge:
            publishCurrentProducerStructuralFailure(
                producer: prod,
                kind: .invariantViolation,
                caseCode:
                    "live.backpressureWedge"
            )
            return
        case .sourceReplay:
            publishCurrentProducerStructuralFailure(
                producer: prod,
                kind: .invariantViolation,
                caseCode: "live.sourceReplay"
            )
            return
        case .eof, .readError, .keyframeStarvation,
             .segmentStall:
            // Custom readers (for example live HLS ingest) own same-request
            // reconnection. A URL reopen is unavailable here, so publish reset
            // evidence rather than spending the Aether budget on a known-impossible
            // operation or suggesting an alternate source.
            if !sourceReopenableByURL {
                publishCurrentProducerStructuralFailure(
                    producer: prod,
                    kind:
                        .unsupportedCapability,
                    caseCode:
                        "live.customSourceReopenUnavailable"
                )
                return
            }
        }
        restartLock.lock()
        let segmentsNow = provider?.liveContinuationPoint().nextIndex ?? 0
        let madeSegmentProgress =
            segmentsNow != lastReopenSegmentCount
        if !madeSegmentProgress {
            if barrenReopenCycles < Int.max {
                barrenReopenCycles += 1
            }
        } else {
            barrenReopenCycles = 0
            barrenReopenDiagnostics
                .resetAfterProgress()
        }
        lastReopenSegmentCount = segmentsNow
        let barrenNow = barrenReopenCycles
        let diagnostic =
            barrenReopenDiagnostics
                .recordFailure()
        restartLock.unlock()
        if let diagnostic {
            EngineLog.emit(
                "[HLSVideoEngine] live pump exited "
                    + "(reason=\(reason)); segmentProgress="
                    + "\(madeSegmentProgress) barrenCycles="
                    + "\(barrenNow) failures="
                    + "\(diagnostic.cumulativeFailures) elapsed="
                    + "\(Int(diagnostic.elapsedSeconds))s"
                    + (diagnostic
                        .checkpointSeconds
                        .map {
                            " checkpoint=\(Int($0))s"
                        } ?? " firstFailure")
                    + "; continuing same-source recovery "
                    + "until cancellation",
                category: .session
            )
        }
        guard let operation =
            reopenIOCleanupFence.beginOperation() else {
            return
        }
        let cleanupFence = reopenIOCleanupFence
        Task.detached(priority: .userInitiated) {
            [weak self, cleanupFence] in
            defer {
                cleanupFence.endOperation(operation)
            }
            await self?.performLiveReopen(
                failedProducer: prod,
                operation: operation
            )
        }
    }

    private func currentProducerEpoch(
        _ candidate: HLSSegmentProducer
    ) -> UInt64? {
        restartLock.lock()
        defer { restartLock.unlock() }
        guard producer === candidate,
              provider != nil else {
            return nil
        }
        return sessionEpoch
    }

    private func publishCurrentProducerStructuralFailure(
        producer candidate:
            HLSSegmentProducer,
        kind: AetherPlaybackFailureKind,
        caseCode: String
    ) {
        guard let epoch =
                currentProducerEpoch(
                    candidate
                ) else {
            return
        }
        _ = publishTerminalReopenFailure(
            HLSReopenFailureClassifier
                .structuralFailure(
                    kind: kind,
                    caseCode: caseCode
                ),
            epoch: epoch,
            expectedProducer: candidate
        )
    }

    private func scheduleVODSourceRecovery(
        failedProducer: HLSSegmentProducer,
        trigger: String
    ) {
        guard let epoch =
                currentProducerEpoch(
                    failedProducer
                ) else {
            return
        }
        let frozen =
            currentPlaybackPositionProvider?()
                ?? 0
        let anchor =
            AetherEngine.recoveryAnchorPosition(
                frozenPosition: frozen,
                pendingSeekTarget:
                    recoverySeekTargetProvider?(),
                currentRendered: frozen
            )
        let index =
            segmentIndexForPlaylistTime(
                anchor
            )
        restartLock.lock()
        if failedProducer
            .packetsWrittenCount > 0 {
            vodSourceRecoveryDiagnostics
                .resetAfterProgress()
        }
        let diagnostic =
            vodSourceRecoveryDiagnostics
                .recordFailure()
        restartLock.unlock()
        if let diagnostic {
            EngineLog.emit(
                "[HLSVideoEngine] VOD \(trigger) "
                    + "at \(String(format: "%.2f", anchor))s; "
                    + "retiring the failed reader and reopening "
                    + "the same source at seg\(index); failures="
                    + "\(diagnostic.cumulativeFailures) elapsed="
                    + "\(Int(diagnostic.elapsedSeconds))s"
                    + (diagnostic
                        .checkpointSeconds
                        .map {
                            " checkpoint=\(Int($0))s"
                        } ?? " firstFailure"),
                category: .session
            )
        }
        Task.detached(
            priority: .userInitiated
        ) { [weak self, weak failedProducer] in
            guard let self,
                  let failedProducer else {
                return
            }
            self.performRestart(
                at: index,
                forceFreshSourceGeneration:
                    true,
                expectedProducer:
                    failedProducer,
                expectedEpoch:
                    epoch
            )
        }
    }

    /// #99: revive a VOD session whose pump died with muxerFailed. The restart path rebuilds the
    /// producer with a fresh muxer and calls audioBridge.startSegment() (which also rebuilds a
    /// post-EOF-drained encoder), so the known transient causes heal. Aimed like the wedge re-anchor:
    /// a pending never-landed seek target owns the recovery aim, else AVPlayer's real position.
    func handleVODMuxerFailure(
        _ failedProducer:
            HLSSegmentProducer
    ) {
        restartLock.lock()
        guard producer === failedProducer else {
            restartLock.unlock()
            return
        }
        let epoch = sessionEpoch
        let admitted = muxerFailureReviveGate.admit()
        let attempts = muxerFailureReviveGate.attempts
        let cap = muxerFailureReviveGate.maxAttempts
        restartLock.unlock()
        guard admitted else {
            EngineLog.emit(
                "[HLSVideoEngine] #99 VOD muxerFailed revive cap reached "
                + "(\(attempts) failures, cap \(cap)); giving up (source not muxable in this session)",
                category: .session
            )
            _ = publishTerminalReopenFailure(
                HLSReopenFailureClassifier
                    .structuralFailure(
                        kind:
                            .routeRuntimeFailure,
                        caseCode:
                            "vod.muxerRecoveryExhausted",
                        code: attempts
                    ),
                epoch: epoch,
                expectedProducer:
                    failedProducer
            )
            return
        }
        let frozen = currentPlaybackPositionProvider?() ?? 0
        let anchor = AetherEngine.recoveryAnchorPosition(
            frozenPosition: frozen, pendingSeekTarget: recoverySeekTargetProvider?(),
            currentRendered: frozen)
        let idx = segmentIndexForPlaylistTime(anchor)
        EngineLog.emit(
            "[HLSVideoEngine] #99 VOD pump died with muxerFailed; rebuilding producer + muxer at "
            + "\(String(format: "%.2f", anchor))s -> seg\(idx) "
            + "(attempt \(attempts)/\(cap))",
            category: .session
        )
        requestRestart(
            at: idx,
            authoritative: true,
            expectedProducer:
                failedProducer,
            expectedEpoch: epoch
        )
    }

    /// #65: re-base the producer onto AVPlayer's real (lagging) position after a VOD backpressure wedge.
    /// The producer was parked 10 segments ahead of a frozen consumer target; re-anchoring to where AVPlayer
    /// actually is puts the starved segments back into the producible window so AVPlayer can resume and land.
    /// Capped so a truly dead AVPlayer (never resumes requesting) can't drive an endless restart storm.
    static func backpressureRecoveryTerminalCaseCode(
        hasPlaybackPosition: Bool,
        attempts: Int,
        maximumAttempts: Int =
            maxConsecutiveWedgeReanchors
    ) -> String? {
        if !hasPlaybackPosition {
            return "vod.backpressurePositionUnavailable"
        }
        if attempts > maximumAttempts {
            return "vod.backpressureRecoveryExhausted"
        }
        return nil
    }

    func handleBackpressureWedge(
        _ failedProducer:
            HLSSegmentProducer
    ) {
        guard let epoch =
                currentProducerEpoch(
                    failedProducer
                ) else {
            return
        }
        guard let pos = currentPlaybackPositionProvider?() else {
            EngineLog.emit(
                "[HLSVideoEngine] #65 backpressure wedge but no AVPlayer position available; cannot re-anchor",
                category: .session
            )
            _ = publishTerminalReopenFailure(
                HLSReopenFailureClassifier
                    .structuralFailure(
                        kind:
                            .routeRuntimeFailure,
                        caseCode:
                            Self
                                .backpressureRecoveryTerminalCaseCode(
                                    hasPlaybackPosition:
                                        false,
                                    attempts: 0
                                )!
                    ),
                epoch: epoch,
                expectedProducer:
                    failedProducer
            )
            return
        }
        restartLock.lock()
        guard producer === failedProducer,
              sessionEpoch == epoch else {
            restartLock.unlock()
            return
        }
        // Reset the storm counter when AVPlayer's position has advanced since the last wedge (real progress);
        // a frozen position across consecutive wedges means AVPlayer never recovered, so we eventually give up.
        if pos > lastWedgeReanchorPosition + 0.5 {
            consecutiveWedgeReanchors = 0
        }
        lastWedgeReanchorPosition = pos
        consecutiveWedgeReanchors += 1
        let attempts = consecutiveWedgeReanchors
        restartLock.unlock()

        if let terminalCaseCode =
                Self
                    .backpressureRecoveryTerminalCaseCode(
                        hasPlaybackPosition:
                            true,
                        attempts: attempts
                    ) {
            EngineLog.emit(
                "[HLSVideoEngine] #65 backpressure wedge re-anchor cap reached "
                + "(\(attempts) consecutive at pos=\(String(format: "%.2f", pos))s); "
                + "publishing typed terminal without changing source or route. "
                + "Engine clock was already reconciled by the seek-deadline path.",
                category: .session
            )
            _ = publishTerminalReopenFailure(
                HLSReopenFailureClassifier
                    .structuralFailure(
                        kind:
                            .routeRuntimeFailure,
                        caseCode:
                            terminalCaseCode,
                        code: attempts
                    ),
                epoch: epoch,
                expectedProducer:
                    failedProducer
            )
            return
        }

        // #93 retest: a pending user seek that never landed owns the recovery aim. AVPlayer only
        // requests media at the seek TARGET after a hard zero-tolerance seek, so a producer
        // re-anchored on the frozen clock fills a window nobody fetches (and can evict the target's
        // segments from retention). Same decision the nudge and stage-2 reload already apply.
        let anchor = AetherEngine.recoveryAnchorPosition(
            frozenPosition: pos, pendingSeekTarget: recoverySeekTargetProvider?(),
            currentRendered: pos)
        let idx = segmentIndexForPlaylistTime(anchor)
        EngineLog.emit(
            "[HLSVideoEngine] #65 backpressure wedge: re-anchoring producer to "
            + "\(String(format: "%.2f", anchor))s -> seg\(idx)"
            + (anchor != pos ? " (requested seek target; frozen clock \(String(format: "%.2f", pos))s)" : " (AVPlayer position)")
            + " (attempt \(attempts)/\(Self.maxConsecutiveWedgeReanchors))",
            category: .session
        )
        // #79: re-anchor authoritatively. The anchor is where recovery must aim (pending seek target,
        // else AVPlayer's real position), so it must win the coalescer's pending slot over any stale
        // in-flight scrub target (else the producer settles at the scrub target and AVPlayer stays starved).
        requestRestart(
            at: idx,
            authoritative: true,
            expectedProducer:
                failedProducer,
            expectedEpoch: epoch
        )

        // #93 residual: the producer is re-anchored and can serve, but a stalled AVPlayer sometimes
        // never resumes REQUESTING (zero GETs, waitingToMinimizeStalls forever, item never fails).
        // Watch the provider's fetch counter through a grace window; if the consumer stays silent
        // while it still wants to play, ask the host for a re-engage nudge.
        let fetchesAtReanchor = provider?.mediaFetchCount ?? 0
        let watchdogEpoch =
            sessionEpochSnapshot()
        Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.consumerReengageGraceSeconds * 1_000_000_000))
            guard let self,
                  self.isSessionEpochCurrent(
                    watchdogEpoch
                  ) else {
                return
            }
            let fetchesNow = self.provider?.mediaFetchCount ?? 0
            guard fetchesNow == fetchesAtReanchor,
                  self.playIntentProvider?() == true else { return }
            // #115: re-read the position at nudge time. On VOD the consumer keeps rendering
            // buffered segments through the grace window, so the wedge-trip capture is behind
            // the on-screen frame and a zero-tolerance nudge to it replays visibly.
            let freshPos = self.currentPlaybackPositionProvider?() ?? pos
            EngineLog.emit(
                "[HLSVideoEngine] #65 consumer re-engage: no segment fetch for "
                + "\(Int(Self.consumerReengageGraceSeconds))s after wedge re-anchor "
                + "(pos=\(String(format: "%.2f", freshPos))s"
                + (freshPos != pos ? ", wedge capture \(String(format: "%.2f", pos))s" : "")
                + "); asking host to nudge AVPlayer",
                category: .session
            )
            self.onConsumerReengageNeeded?(freshPos)
        }
    }

    private func performLiveReopen(
        failedProducer: HLSSegmentProducer,
        operation: HLSReopenIOCleanupFence.Operation
    ) async {
        guard let claim = detachLivePredecessor(
            failedProducer: failedProducer,
            operation: operation
        ) else {
            return
        }
        let predecessorDemuxers =
            claim.predecessorDemuxers
        let epoch = claim.epoch
        let expectedStreamShape =
            claim.expectedStreamShape
        let expectedAudioStreamIndex =
            claim.expectedAudioStreamIndex

        Self.retireReaderGeneration(
            producer: failedProducer,
            demuxers:
                predecessorDemuxers,
            context: "live reopen"
        )
        for predecessorDemuxer
            in predecessorDemuxers {
            reopenIOCleanupFence
                .discardAndWait(
                    predecessorDemuxer
                )
        }
        if claim.hadSideAudio {
            _ = publishTerminalReopenFailure(
                HLSReopenFailureClassifier
                    .structuralFailure(
                        kind:
                            .unsupportedCapability,
                        caseCode:
                            "sideSourceReopenUnavailable"
                    ),
                epoch: epoch
            )
            return
        }

        var attempts = HLSReopenAttemptLedger()
        while true {
            guard liveReopenIsCurrent(
                epoch: epoch
            ) else {
                return
            }
            let backoff = attempts.backoffSeconds
            guard reopenIOCleanupFence
                .waitForRetryDelay(
                    backoff,
                    operation: operation
                ),
                liveReopenIsCurrent(
                    epoch: epoch
                ) else {
                return
            }

            let dem = Demuxer()
            configureProgressiveLiveness(
                on: dem
            )
            guard reopenIOCleanupFence.register(
                dem,
                for: operation
            ) else {
                // Stop won during backoff. Admission is closed, so this late
                // result must never begin another source open.
                reopenIOCleanupFence.discardAndWait(dem)
                return
            }
            var transferredToSession = false
            defer {
                if !transferredToSession {
                    reopenIOCleanupFence
                        .discardAndWait(dem)
                }
            }
            do {
                try dem.open(url: sourceURL, extraHeaders: sourceHTTPHeaders, profile: openProfile, isLive: true)
            } catch {
                switch HLSReopenFailureClassifier
                    .classify(
                        error,
                        caseCode: "live.open"
                    ) {
                case .cancelled:
                    return
                case .permanent(let failure):
                    _ = publishTerminalReopenFailure(
                        failure,
                        epoch: epoch
                    )
                    return
                case .retry:
                    if let diagnostic =
                            attempts
                                .recordFailure() {
                        EngineLog.emit(
                            "[HLSVideoEngine] live transient "
                                + "same-source reopen failures="
                                + "\(diagnostic.cumulativeFailures) "
                                + "elapsed="
                                + "\(Int(diagnostic.elapsedSeconds))s"
                                + (diagnostic
                                    .checkpointSeconds
                                    .map {
                                        " checkpoint=\(Int($0))s"
                                    } ?? " firstFailure")
                                + "; retry remains active",
                            category: .session
                        )
                    }
                    continue
                }
            }
            // Reopened producer reuses savedVideoConfig/savedAudioConfig.
            // Admit it only after codec, time-base, dimensions and selected
            // audio layout all match the first generation.
            let freshStreamShape =
                HLSReopenStreamShape.capture(
                    demuxer: dem,
                    videoStreamIndex:
                        videoStreamIndex,
                    audioStreamIndex:
                        expectedAudioStreamIndex
                )
            if let failure =
                    HLSReopenIdentityValidator
                        .streamShapeFailure(
                            expected:
                                expectedStreamShape,
                            fresh:
                                freshStreamShape,
                            isLive: true
                        ) {
                _ = publishTerminalReopenFailure(
                    failure,
                    epoch: epoch
                )
                return
            }

            switch finishLiveReopen(
                dem: dem,
                attempt: attempts.attempt,
                epoch: epoch
            ) {
            case .done:
                transferredToSession = true
                return
            case .aborted:
                return
            case .retry:
                _ = attempts.recordFailure()
                continue
            }
        }
    }

    private func detachLivePredecessor(
        failedProducer: HLSSegmentProducer,
        operation: HLSReopenIOCleanupFence.Operation
    ) -> (
        predecessorDemuxers: [Demuxer],
        hadSideAudio: Bool,
        epoch: UInt64,
        expectedStreamShape:
            HLSReopenStreamShape?,
        expectedAudioStreamIndex: Int32
    )? {
        restartLock.lock()
        defer { restartLock.unlock() }
        guard producer === failedProducer,
              let predecessor = demuxer else {
            return nil
        }
        let side = sideAudioDemuxer
        let predecessorDemuxers =
            [predecessor]
                + [side].compactMap { $0 }
        guard
              reopenIOCleanupFence.register(
                predecessorDemuxers,
                for: operation
              ) else {
            return nil
        }
        let epoch = sessionEpoch
        // The failed generation belongs to this reopen operation now. Stop
        // can cancel it through the cleanup fence; no closed predecessor is
        // left installed as session state.
        producer = nil
        demuxer = nil
        sideAudioDemuxer = nil
        return (
            predecessorDemuxers,
            side != nil,
            epoch,
            committedReopenStreamShape,
            reopenAudioSourceStreamIndex
        )
    }

    /// Synchronous lock wrapper used by the detached retry loop.
    private func liveReopenIsCurrent(
        epoch: UInt64
    ) -> Bool {
        restartLock.lock()
        defer { restartLock.unlock() }
        return sessionEpoch == epoch
            && producer == nil
            && demuxer == nil
            && provider != nil
    }

    private enum LiveReopenOutcome { case done, aborted, retry }

    private func finishLiveReopen(
        dem: Demuxer,
        attempt: Int,
        epoch: UInt64
    )
        -> LiveReopenOutcome
    {
        restartLock.lock()
        guard sessionEpoch == epoch,
              producer == nil,
              demuxer == nil,
              let prov = provider else {
            restartLock.unlock()
            return .aborted
        }
        demuxer = dem
        let (nextIndex, outputEnd) = prov.liveContinuationPoint()
        let newProducer: HLSSegmentProducer
        do {
            newProducer = try makeProducer(
                baseIndex: nextIndex,
                liveReopenOutputEndSeconds: outputEnd
            )
        } catch {
            // The predecessor is already closed and must never be restored.
            demuxer = nil
            restartLock.unlock()
            _ = publishTerminalReopenFailure(
                HLSReopenFailureClassifier
                    .structuralFailure(
                        kind: .routeRuntimeFailure,
                        caseCode:
                            "live.producerBuild",
                        code: attempt
                    ),
                epoch: epoch
            )
            return .aborted
        }
        // Fresh connection joins the broadcast at "now"; source clock jumps,
        // so the seam carries #EXT-X-DISCONTINUITY. Shift handoff is deferred
        // until playback reaches the seam.
        newProducer.firstSegmentDiscontinuous = true
        newProducer.onVideoShiftKnown = {
            [weak self] shiftPts in
            self?.handleLiveTimelineRebase(
                shiftPts,
                seamOutputSeconds: outputEnd
            )
        }
        producer = newProducer
        reopenIOCleanupFence.transferToSession(dem)
        restartLock.unlock()

        // Start outside restartLock. If stop wins in this narrow window it
        // marks the never-started producer finished, so start() becomes a
        // no-op and no late reader generation can escape.
        newProducer.start()
        EngineLog.emit(
            "[HLSVideoEngine] live reopen succeeded on attempt \(attempt): "
                + "continuing at seg\(nextIndex) "
                + "(outputEnd="
                + "\(String(format: "%.1f", outputEnd))s)",
            category: .session
        )
        return .done
    }
}
