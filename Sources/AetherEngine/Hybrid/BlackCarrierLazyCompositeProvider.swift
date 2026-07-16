import Foundation

enum BlackCarrierAudioBandwidthEvidence: Sendable, Equatable {
    case measuredFullAsset(
        peakBandwidth: Int,
        averageBandwidth: Int
    )
    case verifiedConstantRate(
        payloadBandwidth: Int,
        maximumContainerOverhead: Int,
        averageContainerOverhead: Int
    )

    var peakBandwidth: Int {
        switch self {
        case .measuredFullAsset(let peakBandwidth, _):
            return peakBandwidth
        case .verifiedConstantRate(
            let payloadBandwidth,
            let maximumContainerOverhead,
            _
        ):
            return payloadBandwidth + maximumContainerOverhead
        }
    }

    var averageBandwidth: Int {
        switch self {
        case .measuredFullAsset(_, let averageBandwidth):
            return averageBandwidth
        case .verifiedConstantRate(
            let payloadBandwidth,
            _,
            let averageContainerOverhead
        ):
            return payloadBandwidth + averageContainerOverhead
        }
    }

    var isValid: Bool {
        switch self {
        case .measuredFullAsset(let peak, let average):
            return peak > 0 && average > 0 && peak >= average
        case .verifiedConstantRate(
            let payload,
            let maximumOverhead,
            let averageOverhead
        ):
            return payload > 0
                && maximumOverhead >= 0
                && averageOverhead >= 0
                && maximumOverhead >= averageOverhead
        }
    }
}

struct BlackCarrierAudioBandwidthAdmission: Sendable, Equatable {
    let ordinal: Int
    let evidence: BlackCarrierAudioBandwidthEvidence
}

enum BlackCarrierLazyCompositeProviderError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case admissionCountMismatch(expected: Int, actual: Int)
    case admissionOrdinalMismatch(expected: Int, actual: Int)
    case invalidBandwidthEvidence(ordinal: Int)
    case startupResourceMissing(ordinal: Int)
    case pump(BlackCarrierMediaFanoutPumpError)

    var errorDescription: String? {
        switch self {
        case .admissionCountMismatch(let expected, let actual):
            return "Lazy carrier requires \(expected) audio bandwidth admissions, found \(actual)"
        case .admissionOrdinalMismatch(let expected, let actual):
            return "Lazy carrier audio bandwidth ordinal \(actual) is invalid; expected \(expected)"
        case .invalidBandwidthEvidence(let ordinal):
            return "Lazy carrier audio rendition \(ordinal) has invalid peak-bandwidth evidence"
        case .startupResourceMissing(let ordinal):
            return "Lazy carrier audio rendition \(ordinal) did not produce its startup init and segment"
        case .pump(let error):
            return error.localizedDescription
        }
    }
}

/// HLS provider whose alternate-audio requests advance one incremental shared-demux pump.
///
/// The black video representation remains deterministic and prebuilt. Real audio init/segments are
/// generated through `BlackCarrierMediaFanoutPump` only as AVPlayer needs them. Master bandwidth is
/// admitted only with explicit evidence; this type never substitutes the old fixed 5 Mbps fallback.
final class BlackCarrierLazyCompositeProvider:
    BlackCarrierTransportProvider,
    @unchecked Sendable
{
    private let videoProvider: BlackCarrierVideoProvider
    private let pump: BlackCarrierMediaFanoutPump
    private let codecs: String
    private let bandwidth: Int
    private let averageBandwidth: Int
    private let closeLock = NSLock()
    private var isClosed = false
    private let failureLock = NSLock()
    private var _terminalError: BlackCarrierLazyCompositeProviderError?

    init(
        videoProvider: BlackCarrierVideoProvider,
        pump: BlackCarrierMediaFanoutPump,
        bandwidthAdmissions: [BlackCarrierAudioBandwidthAdmission]
    ) throws {
        let expectedCount = pump.renditionMetadata.count
        guard bandwidthAdmissions.count == expectedCount else {
            videoProvider.close()
            pump.close()
            throw BlackCarrierLazyCompositeProviderError
                .admissionCountMismatch(
                    expected: expectedCount,
                    actual: bandwidthAdmissions.count
                )
        }
        for (expectedOrdinal, admission) in bandwidthAdmissions.enumerated() {
            guard admission.ordinal == expectedOrdinal else {
                videoProvider.close()
                pump.close()
                throw BlackCarrierLazyCompositeProviderError
                    .admissionOrdinalMismatch(
                        expected: expectedOrdinal,
                        actual: admission.ordinal
                    )
            }
            guard admission.evidence.isValid else {
                videoProvider.close()
                pump.close()
                throw BlackCarrierLazyCompositeProviderError
                    .invalidBandwidthEvidence(ordinal: admission.ordinal)
            }
        }

        self.videoProvider = videoProvider
        self.pump = pump

        var uniqueCodecs = [BlackCarrierProfile.approved.codecString]
        for descriptor in pump.renditionDescriptors
        where !uniqueCodecs.contains(descriptor.codecString) {
            uniqueCodecs.append(descriptor.codecString)
        }
        codecs = uniqueCodecs.joined(separator: ",")

        bandwidth = max(
            1,
            (videoProvider.masterBandwidth ?? 0)
                + (bandwidthAdmissions.map {
                    $0.evidence.peakBandwidth
                }.max() ?? 0)
        )
        averageBandwidth = max(
            1,
            (videoProvider.masterAverageBandwidth ?? 0)
                + (bandwidthAdmissions.map {
                    $0.evidence.averageBandwidth
                }.max() ?? 0)
        )
    }

    deinit {
        close()
    }

    var terminalError: BlackCarrierLazyCompositeProviderError? {
        failureLock.lock()
        defer { failureLock.unlock() }
        return _terminalError
    }

    func prepareForTransportStart() throws {
        for ordinal in pump.renditionMetadata.indices {
            do {
                guard try pump.initSegment(ordinal: ordinal) != nil,
                      pump.peekMediaSegmentURL(
                          ordinal: ordinal,
                          index: 0
                      ) != nil else {
                    let error = BlackCarrierLazyCompositeProviderError
                        .startupResourceMissing(ordinal: ordinal)
                    record(error)
                    throw error
                }
            } catch let error as BlackCarrierMediaFanoutPumpError {
                let typed = BlackCarrierLazyCompositeProviderError.pump(error)
                record(typed)
                throw typed
            }
        }
    }

    func close() {
        closeLock.lock()
        guard !isClosed else {
            closeLock.unlock()
            return
        }
        isClosed = true
        closeLock.unlock()
        videoProvider.close()
        pump.close()
    }

    func initSegment() -> Data? {
        videoProvider.initSegment()
    }

    func mediaSegment(at index: Int) -> Data? {
        videoProvider.mediaSegment(at: index)
    }

    func mediaSegmentURL(at index: Int) -> URL? {
        videoProvider.mediaSegmentURL(at: index)
    }

    var segmentCount: Int { videoProvider.segmentCount }

    func segmentDuration(at index: Int) -> Double {
        videoProvider.segmentDuration(at: index)
    }

    var playlistType: HLSPlaylistType { videoProvider.playlistType }
    var masterCodecs: String? { codecs }
    var masterResolution: (width: Int, height: Int)? {
        videoProvider.masterResolution
    }
    var masterVideoRange: HLSVideoRange? {
        videoProvider.masterVideoRange
    }
    var masterBandwidth: Int? { bandwidth }
    var masterAverageBandwidth: Int? { averageBandwidth }
    var masterFrameRate: Double? {
        videoProvider.masterFrameRate
    }
    var masterClosedCaptions: String? {
        videoProvider.masterClosedCaptions
    }

    var alternateAudioRenditions: [HLSAudioRenditionInfo] {
        zip(pump.renditionMetadata, pump.renditionDescriptors).map {
            metadata,
            descriptor in
            HLSAudioRenditionInfo(
                ordinal: metadata.ordinal,
                language: metadata.language,
                name: metadata.name,
                isDefault: metadata.isDefault,
                isAutoselect: metadata.isAutoselect,
                channels: descriptor.channelsAttribute
            )
        }
    }

    func alternateAudioInitSegment(ordinal: Int) -> Data? {
        guard pump.renditionMetadata.indices.contains(ordinal) else {
            return nil
        }
        do {
            return try pump.initSegment(ordinal: ordinal)
        } catch let error as BlackCarrierMediaFanoutPumpError {
            record(.pump(error))
            return nil
        } catch {
            record(.pump(.demuxFailed(reason: String(describing: error))))
            return nil
        }
    }

    func alternateAudioMediaSegment(
        ordinal: Int,
        index: Int
    ) -> Data? {
        guard pump.renditionMetadata.indices.contains(ordinal),
              0..<segmentCount ~= index else {
            return nil
        }
        do {
            return try pump.mediaSegment(
                ordinal: ordinal,
                index: index
            )
        } catch let error as BlackCarrierMediaFanoutPumpError {
            record(.pump(error))
            return nil
        } catch {
            record(.pump(.demuxFailed(reason: String(describing: error))))
            return nil
        }
    }

    func alternateAudioMediaSegmentURL(
        ordinal: Int,
        index: Int
    ) -> URL? {
        guard pump.renditionMetadata.indices.contains(ordinal),
              0..<segmentCount ~= index else {
            return nil
        }
        do {
            return try pump.mediaSegmentURL(
                ordinal: ordinal,
                index: index
            )
        } catch let error as BlackCarrierMediaFanoutPumpError {
            record(.pump(error))
            return nil
        } catch {
            record(.pump(.demuxFailed(reason: String(describing: error))))
            return nil
        }
    }

    func sourceTrackID(forAudioOrdinal ordinal: Int) -> Int? {
        guard pump.renditionMetadata.indices.contains(ordinal) else {
            return nil
        }
        return pump.renditionMetadata[ordinal].sourceTrackID
    }

    private func record(_ error: BlackCarrierLazyCompositeProviderError) {
        failureLock.lock()
        let isFirstError: Bool
        if _terminalError == nil {
            _terminalError = error
            isFirstError = true
        } else {
            isFirstError = false
        }
        failureLock.unlock()
        guard isFirstError else { return }
        EngineLog.emit(
            "[BlackCarrierLazyCompositeProvider] terminal error: "
                + error.localizedDescription,
            category: .session
        )
    }
}
