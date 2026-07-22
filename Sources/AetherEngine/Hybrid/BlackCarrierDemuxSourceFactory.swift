import Foundation

enum BlackCarrierDemuxSourceFactoryError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case seekableVODRequired
    case independentReaderUnavailable
    case closed
    case openFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .seekableVODRequired:
            return "Black carrier demux generations require a seekable VOD source"
        case .independentReaderUnavailable:
            return "Black carrier custom source cannot create an independent reader generation"
        case .closed:
            return "Black carrier demux source factory is closed"
        case .openFailed(let reason):
            return "Black carrier demux source could not open: \(reason)"
        }
    }
}

/// Session-owned source opener for black-carrier demux generations.
///
/// URL sources reopen through the same URL/options. Custom sources never reuse the caller's
/// mutable cursor: every generation must come from `makeIndependentReader()`. The factory owns
/// the caller-provided custom reader after successful session construction and closes it exactly
/// once with the pump.
final class BlackCarrierDemuxSourceFactory: @unchecked Sendable {
    private enum Backing {
        case url(
            URL,
            headers: [String: String],
            profile: DemuxerOpenProfile,
            selectTitleID: Int?
        )
        case custom(
            IOReader,
            formatHint: String?,
            profile: DemuxerOpenProfile,
            selectTitleID: Int?,
            discCacheKey: String?
        )
    }

    private let backing: Backing
    private let sourceByteStore: SourceByteStore?
    private let lock = NSLock()
    private var isClosed = false
    /// Exact demuxer that established progressive preflight facts. The first
    /// Hybrid generation consumes it instead of reopening the URL between
    /// admission and commit; later explicit generations use `backing`.
    private var preparedInitialDemuxer: Demuxer?

    init(
        source: MediaSource,
        options: LoadOptions,
        selectTitleID: Int? = nil
    ) throws {
        guard !options.isLive else {
            throw BlackCarrierDemuxSourceFactoryError.seekableVODRequired
        }
        let profile = DemuxerOpenProfile.playback.withProbeBudget(
            probesize: options.probesize,
            maxAnalyzeDuration: options.maxAnalyzeDuration
        )
        switch source {
        case .url(let url):
            sourceByteStore = try SourceByteStore()
            preparedInitialDemuxer = nil
            backing = .url(
                url,
                headers: options.httpHeaders,
                profile: profile,
                selectTitleID: selectTitleID
            )
        case .custom(let reader, let formatHint):
            sourceByteStore = nil
            preparedInitialDemuxer = nil
            backing = .custom(
                reader,
                formatHint: formatHint,
                profile: profile,
                selectTitleID: selectTitleID,
                discCacheKey: nil
            )
        }
    }

    private init(
        preparedURLSource: AetherPreparedURLSource,
        url: URL,
        options: LoadOptions
    ) throws {
        guard !options.isLive else {
            throw BlackCarrierDemuxSourceFactoryError.seekableVODRequired
        }
        let profile = DemuxerOpenProfile.playback.withProbeBudget(
            probesize: options.probesize,
            maxAnalyzeDuration: options.maxAnalyzeDuration
        )
        sourceByteStore = try SourceByteStore()
        backing = .url(
            url,
            headers: options.httpHeaders,
            profile: profile,
            selectTitleID: nil
        )
        preparedInitialDemuxer = try preparedURLSource.consume(
            url: url,
            options: options
        )
    }

    static func adopting(
        source: MediaSource,
        options: LoadOptions,
        selectTitleID: Int? = nil
    ) throws -> BlackCarrierDemuxSourceFactory {
        do {
            return try BlackCarrierDemuxSourceFactory(
                source: source,
                options: options,
                selectTitleID: selectTitleID
            )
        } catch {
            if case .custom(let reader, _) = source {
                reader.close()
            }
            throw error
        }
    }

    static func adopting(
        preparedURLSource: AetherPreparedURLSource,
        url: URL,
        options: LoadOptions
    ) throws -> BlackCarrierDemuxSourceFactory {
        try BlackCarrierDemuxSourceFactory(
            preparedURLSource: preparedURLSource,
            url: url,
            options: options
        )
    }

    deinit {
        close()
    }

    func openDemuxer() throws -> Demuxer {
        let source: Backing
        let preparedDemuxer: Demuxer?
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            throw BlackCarrierDemuxSourceFactoryError.closed
        }
        source = backing
        preparedDemuxer = preparedInitialDemuxer
        preparedInitialDemuxer = nil
        lock.unlock()

        if let preparedDemuxer {
            return preparedDemuxer
        }

        let demuxer = Demuxer()
        do {
            switch source {
            case .url(
                let url,
                let headers,
                let profile,
                let selectTitleID
            ):
                try demuxer.open(
                    url: url,
                    extraHeaders: headers,
                    profile: profile,
                    isLive: false,
                    selectTitleID: selectTitleID,
                    sourceByteStore: sourceByteStore
                )
            case .custom(
                let prototype,
                let formatHint,
                let profile,
                let selectTitleID,
                let discCacheKey
            ):
                guard let reader = prototype.makeIndependentReader() else {
                    throw BlackCarrierDemuxSourceFactoryError
                        .independentReaderUnavailable
                }
                do {
                    try demuxer.open(
                        reader: reader,
                        formatHint: formatHint,
                        profile: profile,
                        isLive: false,
                        selectTitleID: selectTitleID,
                        discCacheKey: discCacheKey
                    )
                    demuxer.adoptOwnedReader(reader)
                } catch {
                    reader.close()
                    throw error
                }
            }
            return demuxer
        } catch let error as BlackCarrierDemuxSourceFactoryError {
            demuxer.close()
            throw error
        } catch {
            demuxer.close()
            throw BlackCarrierDemuxSourceFactoryError.openFailed(
                reason: String(describing: error)
            )
        }
    }

    func makeAudioAnalysisInput() throws -> AudioAnalysisInput {
        let source: Backing
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            throw BlackCarrierDemuxSourceFactoryError.closed
        }
        source = backing
        lock.unlock()

        switch source {
        case .url(let url, let headers, _, _):
            return .url(
                url,
                httpHeaders: headers,
                sourceByteStore: sourceByteStore
            )
        case .custom(let prototype, let formatHint, _, _, _):
            guard let reader = prototype.makeIndependentReader() else {
                throw BlackCarrierDemuxSourceFactoryError
                    .independentReaderUnavailable
            }
            return .reader(reader, formatHint: formatHint)
        }
    }

    func close() {
        let customReader: IOReader?
        let initialDemuxer: Demuxer?
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        initialDemuxer = preparedInitialDemuxer
        preparedInitialDemuxer = nil
        if case .custom(let reader, _, _, _, _) = backing {
            customReader = reader
        } else {
            customReader = nil
        }
        lock.unlock()
        initialDemuxer?.close()
        customReader?.close()
        sourceByteStore?.close()
    }
}
