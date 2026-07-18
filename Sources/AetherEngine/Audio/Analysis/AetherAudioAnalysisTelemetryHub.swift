import Foundation

/// Bounded, session-scoped fan-out for backend-neutral audio-analysis
/// telemetry. Events contain only stable IDs, ranges and counters defined by
/// `AetherAudioAnalysisTelemetry`; source URLs and decoder strings never enter
/// this hub.
@MainActor
final class AetherAudioAnalysisTelemetryHub {
    private static let historyLimit = 64

    private var history: [AetherAudioAnalysisTelemetry] = []
    private var continuations: [
        UUID: AsyncStream<AetherAudioAnalysisTelemetry>.Continuation
    ] = [:]
    private var isFinished = false

    func stream() -> AsyncStream<AetherAudioAnalysisTelemetry> {
        let subscriptionID = UUID()
        let pair = AsyncStream.makeStream(
            of: AetherAudioAnalysisTelemetry.self,
            bufferingPolicy: .bufferingNewest(Self.historyLimit)
        )
        for event in history {
            pair.continuation.yield(event)
        }
        guard !isFinished else {
            pair.continuation.finish()
            return pair.stream
        }
        continuations[subscriptionID] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.continuations.removeValue(
                    forKey: subscriptionID
                )
            }
        }
        return pair.stream
    }

    func emit(_ event: AetherAudioAnalysisTelemetry) {
        guard !isFinished else { return }
        history.append(event)
        if history.count > Self.historyLimit {
            history.removeFirst(
                history.count - Self.historyLimit
            )
        }
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }
}
