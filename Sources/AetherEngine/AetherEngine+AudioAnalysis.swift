import Foundation

extension AetherEngine {
    /// Open an independent, lossless-with-respect-to-delivery audio-analysis cursor.
    ///
    /// The request is tied to `TrackInfo.id`, rather than `activeAudioTrackIndex`, and its output is fixed to
    /// mono Float32 non-interleaved 48 kHz. It never follows the playback cursor and never uses the lossy
    /// `installAudioTap()` path. Live/DVR sources and custom sources without an independent clone fail before
    /// any fallback playback behavior can be selected.
    @MainActor
    public func audioAnalysisStream(request: AudioAnalysisRequest) throws -> AudioAnalysisStream {
        switch state {
        case .idle, .error:
            throw AudioAnalysisError.noActiveSession
        case .loading, .playing, .paused, .seeking, .ended:
            break
        }
        guard !isLive, !loadedOptions.isLive else {
            throw AudioAnalysisError.liveOrDVRUnsupported
        }
        guard let loadedURL else {
            throw AudioAnalysisError.noActiveSession
        }
        guard audioTracks.contains(where: { $0.id == request.audioTrackID }) else {
            throw AudioAnalysisError.audioTrackUnavailable(request.audioTrackID)
        }

        let input: AudioAnalysisInput
        if isCustomSource {
            guard customSourceIsSeekable else {
                throw AudioAnalysisError.sourceNotSeekable
            }
            guard let reader = customReader?.makeIndependentReader() else {
                throw AudioAnalysisError.sourceCannotCreateIndependentReader
            }
            input = .reader(reader, formatHint: customFormatHint)
        } else {
            input = .url(loadedURL, httpHeaders: loadedOptions.httpHeaders)
        }

        let session = AudioAnalysisSession()
        let stream = AudioAnalysisStream(gate: session.gate, cancel: { session.cancel() })
        // Register before spawning so a very short source cannot finish before it becomes tear-down visible.
        audioAnalysisSessions[session.id] = session
        let sessionID = session.id
        let task = Task.detached(priority: .utility) { [weak self] in
            await AudioAnalysisRunner.run(session: session, input: input, request: request)
            await self?.removeAudioAnalysisSession(id: sessionID)
        }
        session.install(task: task)
        return stream
    }

    /// Explicitly cancel all independent readers without altering playback. Used by stop/reload and available
    /// to a host that is abandoning a group of analysis requests before replacing its own UI state.
    @MainActor
    public func cancelAudioAnalysisStreams() {
        let sessions = Array(audioAnalysisSessions.values)
        audioAnalysisSessions.removeAll()
        for session in sessions { session.cancel() }
    }

    @MainActor
    private func removeAudioAnalysisSession(id: UUID) {
        audioAnalysisSessions.removeValue(forKey: id)
    }
}
