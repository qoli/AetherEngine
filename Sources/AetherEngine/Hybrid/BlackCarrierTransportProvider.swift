import Foundation

/// Carrier provider ownership contract used by `BlackCarrierAVPlayerSession`.
///
/// Eager providers have nothing to prepare. Incremental providers use
/// `prepareForTransportStart()` to make init and startup segments available before the loopback
/// server accepts AVPlayer requests, avoiding an unobservable startup 404 or watchdog timeout.
protocol BlackCarrierTransportProvider: HLSSegmentProvider {
    func prepareForTransportStart() throws
    func close()
}

extension BlackCarrierTransportProvider {
    func prepareForTransportStart() throws {}
}
