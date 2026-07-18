import AetherEngine
import AVFoundation
import AVKit
import CoreMedia
import OSLog
import UIKit

private enum AcceptanceHarnessError: Error, LocalizedError {
    case invalidFixtureURL
    case routeIsNotHybrid(route: PlaybackRenderRoute, reason: PlaybackRouteReason)
    case contentOverlayUnavailable
    case sessionUnavailable
    case assertionFailed(step: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .invalidFixtureURL:
            return "A non-empty HTTPS or local-network HTTP fixture URL is required"
        case .routeIsNotHybrid(let route, let reason):
            return "Preflight selected \(route.rawValue) (\(reason.rawValue)); this Hybrid-only harness will not start another route"
        case .contentOverlayUnavailable:
            return "AVPlayerViewController.contentOverlayView is unavailable"
        case .sessionUnavailable:
            return "No prepared Hybrid session is available"
        case .assertionFailed(let step, let detail):
            return "Acceptance assertion failed at \(step): \(detail)"
        }
    }
}

@MainActor
final class AcceptanceViewController: UIViewController {
    private static let logger = Logger(
        subsystem: "com.qoli.AetherHybridAcceptance",
        category: "acceptance"
    )

    private let playerViewController = AVPlayerViewController()
    private let fixtureURLField = UITextField()
    private let statusLabel = UILabel()
    private let setupPanel = UIStackView()
    private let actionPanel = UIStackView()

    private var session: AetherHybridPlaybackSession?
    private var loadTask: Task<Void, Never>?
    private var telemetryTask: Task<Void, Never>?
    private var diagnosticsTask: Task<Void, Never>?
    private var didStartAutomaticRun = false
    private var observedCarrierStallPressure = false

    private var automaticRunEnabled: Bool {
        ProcessInfo.processInfo.environment["AETHER_ACCEPTANCE_AUTORUN"] == "1"
    }

    private var automaticStallRunEnabled: Bool {
        ProcessInfo.processInfo.environment[
            "AETHER_ACCEPTANCE_STALL_AUTORUN"
        ] == "1"
    }

    private var automaticColorRunEnabled: Bool {
        ProcessInfo.processInfo.environment[
            "AETHER_ACCEPTANCE_COLOR_AUTORUN"
        ] == "1"
    }

    private var automaticGeometryRunEnabled: Bool {
        ProcessInfo.processInfo.environment[
            "AETHER_ACCEPTANCE_GEOMETRY_AUTORUN"
        ] == "1"
    }

    private var automaticSubtitleRunEnabled: Bool {
        ProcessInfo.processInfo.environment[
            "AETHER_ACCEPTANCE_SUBTITLE_AUTORUN"
        ] == "1"
    }

    private var automaticOverlaySubtitleRunEnabled: Bool {
        ProcessInfo.processInfo.environment[
            "AETHER_ACCEPTANCE_OVERLAY_SUBTITLE_AUTORUN"
        ] == "1"
    }

    private var automaticProgressiveNativeSubtitleRunEnabled: Bool {
        ProcessInfo.processInfo.environment[
            "AETHER_ACCEPTANCE_PROGRESSIVE_NATIVE_SUBTITLE_AUTORUN"
        ] == "1"
    }

    private var automaticBitmapSubtitleRunEnabled: Bool {
        ProcessInfo.processInfo.environment[
            "AETHER_ACCEPTANCE_BITMAP_SUBTITLE_AUTORUN"
        ] == "1"
    }

    private var automaticNegativeRunEnabled: Bool {
        ProcessInfo.processInfo.environment[
            "AETHER_ACCEPTANCE_NEGATIVE_CASE"
        ]?.isEmpty == false
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configurePlayerController()
        configureSetupPanel()
        configureActionPanel()
        configureStatusLabel()
        installConstraints()
        setSessionControlsEnabled(false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard automaticRunEnabled
                || automaticStallRunEnabled
                || automaticColorRunEnabled
                || automaticGeometryRunEnabled
                || automaticSubtitleRunEnabled
                || automaticOverlaySubtitleRunEnabled
                || automaticProgressiveNativeSubtitleRunEnabled
                || automaticBitmapSubtitleRunEnabled
                || automaticNegativeRunEnabled,
              !didStartAutomaticRun,
              fixtureURLField.text?.isEmpty == false else {
            return
        }
        didStartAutomaticRun = true
        startTapped()
    }

    deinit {
        loadTask?.cancel()
        telemetryTask?.cancel()
        diagnosticsTask?.cancel()
    }

    private func configurePlayerController() {
        playerViewController.showsPlaybackControls = true
        playerViewController.allowsPictureInPicturePlayback = false
        playerViewController.view.backgroundColor = .black
        addChild(playerViewController)
        playerViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playerViewController.view)
        playerViewController.didMove(toParent: self)
    }

    private func configureSetupPanel() {
        setupPanel.axis = .horizontal
        setupPanel.alignment = .center
        setupPanel.spacing = 20
        setupPanel.translatesAutoresizingMaskIntoConstraints = false
        setupPanel.backgroundColor = UIColor.black.withAlphaComponent(0.78)
        setupPanel.layer.cornerRadius = 18
        setupPanel.isLayoutMarginsRelativeArrangement = true
        setupPanel.layoutMargins = UIEdgeInsets(top: 18, left: 22, bottom: 18, right: 22)

        fixtureURLField.placeholder = "https://europe.olemovienews.com/ts4/20260618/xrhy3o7h/mp4/xrhy3o7h.mp4/master.m3u8"
        fixtureURLField.textContentType = .URL
        fixtureURLField.keyboardType = .URL
        fixtureURLField.autocapitalizationType = .none
        fixtureURLField.autocorrectionType = .no
        fixtureURLField.borderStyle = .roundedRect
        fixtureURLField.text = ProcessInfo.processInfo.environment["AETHER_ACCEPTANCE_FIXTURE_URL"]
        fixtureURLField.widthAnchor.constraint(greaterThanOrEqualToConstant: 720).isActive = true

        let start = makeButton(title: "Preflight + Start", action: #selector(startTapped))
        setupPanel.addArrangedSubview(fixtureURLField)
        setupPanel.addArrangedSubview(start)
        view.addSubview(setupPanel)
    }

    private func configureActionPanel() {
        actionPanel.axis = .horizontal
        actionPanel.alignment = .center
        actionPanel.distribution = .fillEqually
        actionPanel.spacing = 12
        actionPanel.translatesAutoresizingMaskIntoConstraints = false
        actionPanel.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        actionPanel.layer.cornerRadius = 16
        actionPanel.isLayoutMarginsRelativeArrangement = true
        actionPanel.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

        [
            makeButton(title: "Pause", action: #selector(pauseTapped)),
            makeButton(title: "0.5×", action: #selector(rateHalfTapped)),
            makeButton(title: "1×", action: #selector(rateNormalTapped)),
            makeButton(title: "2×", action: #selector(rateDoubleTapped)),
            makeButton(title: "−10s", action: #selector(seekBackwardTapped)),
            makeButton(title: "+10s", action: #selector(seekForwardTapped)),
            makeButton(title: "Stop", action: #selector(stopTapped)),
        ].forEach(actionPanel.addArrangedSubview)
        view.addSubview(actionPanel)
    }

    private func configureStatusLabel() {
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.numberOfLines = 3
        statusLabel.font = .monospacedSystemFont(ofSize: 24, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        statusLabel.layer.cornerRadius = 12
        statusLabel.layer.masksToBounds = true
        statusLabel.textAlignment = .center
        statusLabel.text = "Awaiting explicit Hybrid HLS fixture"
        view.addSubview(statusLabel)
    }

    private func installConstraints() {
        NSLayoutConstraint.activate([
            playerViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            playerViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            setupPanel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 48),
            setupPanel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -48),
            setupPanel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 30),

            actionPanel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 48),
            actionPanel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -48),
            actionPanel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -34),

            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: setupPanel.bottomAnchor, constant: 18),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 900),
            statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 84),
        ])
    }

    private func makeButton(title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 28, weight: .semibold)
        button.addTarget(self, action: action, for: .primaryActionTriggered)
        return button
    }

    @objc private func startTapped() {
        guard loadTask == nil else { return }
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { loadTask = nil }
            do {
                let fixtureURL = try validatedFixtureURL()
                stopCurrentSession()
                observedCarrierStallPressure = false
                setStatus("preflight running", detail: "route not yet selected")

                if automaticOverlaySubtitleRunEnabled
                    || automaticProgressiveNativeSubtitleRunEnabled
                    || automaticBitmapSubtitleRunEnabled {
                    try await runAutomaticProgressiveSubtitleFixture(
                        fixtureURL
                    )
                    return
                }

                let operation = AetherPlaybackPreflightOperation()
                let preflight: AetherHLSPlaybackPreflight
                do {
                    preflight = try await operation.inspectHLS(
                        url: fixtureURL,
                        sourceIsSeekableVOD: true,
                        variantSelection: .highestBandwidth,
                        hybridCapabilities: AetherHybridPlaybackSession.capabilities
                    )
                } catch {
                    await emitPreflightTelemetry(operation)
                    emitLocalPreflightDiagnosticIfRequested(error)
                    throw error
                }
                await emitPreflightTelemetry(operation)
                guard preflight.result.route == .hybridCarrier else {
                    throw AcceptanceHarnessError.routeIsNotHybrid(
                        route: preflight.result.route,
                        reason: preflight.result.reason
                    )
                }
                let nativeSubtitleCount = preflight.subtitleRenditions.reduce(0) {
                    count, rendition in
                    if case .nativeWebVTT = rendition.availability {
                        count + 1
                    } else {
                        count
                    }
                }
                let unavailableSubtitleCount =
                    preflight.subtitleRenditions.count - nativeSubtitleCount
                Self.logger.notice(
                    "preflight route=\(preflight.result.route.rawValue, privacy: .public) reason=\(preflight.result.reason.rawValue, privacy: .public) segments=\(preflight.mediaSegmentCount) audioRenditions=\(preflight.audioRenditionCount) nativeSubtitles=\(nativeSubtitleCount) unavailableSubtitles=\(unavailableSubtitleCount)"
                )
                print(
                    "AETHER_ACCEPTANCE preflight route=\(preflight.result.route.rawValue) reason=\(preflight.result.reason.rawValue) segments=\(preflight.mediaSegmentCount) audioRenditions=\(preflight.audioRenditionCount) nativeSubtitles=\(nativeSubtitleCount) unavailableSubtitles=\(unavailableSubtitleCount)"
                )

                print("AETHER_ACCEPTANCE phase=session-create")
                let session = try await AetherHybridPlaybackSession.makeHLSVOD(
                    preflight: preflight
                )
                self.session = session
                print("AETHER_ACCEPTANCE phase=host-install")
                try install(session: session)
                if try await runPreparationNegativeScenarioIfRequested(
                    session: session
                ) {
                    return
                }
                print("AETHER_ACCEPTANCE phase=prepare")
                try await session.prepare(timeout: 30)
                print("AETHER_ACCEPTANCE phase=play")
                try session.play()
                startTelemetry(for: session)
                startDiagnosticsSampling()
                setSessionControlsEnabled(true)
                setupPanel.isHidden = true
                setStatus("playing", diagnostics: session.diagnostics)
                if automaticStallRunEnabled {
                    try await runAutomaticStallScenario(session: session)
                } else if automaticNegativeRunEnabled {
                    try await runAutomaticNegativeScenario(
                        session: session
                    )
                } else if automaticColorRunEnabled {
                    try await runAutomaticColorScenario(
                        session: session
                    )
                } else if automaticGeometryRunEnabled {
                    try await runAutomaticGeometryScenario(
                        session: session
                    )
                } else if automaticSubtitleRunEnabled {
                    try await runAutomaticSubtitleScenario(
                        session: session
                    )
                } else if automaticRunEnabled {
                    try await runAutomaticClockScenario(session: session)
                    try await runAutomaticAudioTrackSwitchScenario(
                        session: session
                    )
                    try await runAutomaticStopAndReopenScenario(
                        preflight: preflight,
                        priorSession: session
                    )
                }
            } catch is CancellationError {
                setStatus("cancelled", detail: "no route or backend was started")
            } catch {
                session?.stop()
                session = nil
                setSessionControlsEnabled(false)
                setupPanel.isHidden = false
                setStatus("terminal failure", detail: error.localizedDescription)
                Self.logger.error("terminal failure=\(String(describing: error), privacy: .public)")
                print(
                    "AETHER_ACCEPTANCE terminalFailure type=\(String(reflecting: type(of: error)))\(acceptanceFailureSuffix(error))"
                )
            }
        }
    }

    private func validatedFixtureURL() throws -> URL {
        guard let text = fixtureURLField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.user == nil,
              url.password == nil else {
            throw AcceptanceHarnessError.invalidFixtureURL
        }
        return url
    }

    private func emitPreflightTelemetry(
        _ operation: AetherPlaybackPreflightOperation
    ) async {
        let events = await operation.telemetryEvents()
        for await event in events {
            switch event.snapshot {
            case .started(let request):
                print(
                    "AETHER_ACCEPTANCE preflightEvent sequence=\(event.sequence) kind=started sourceKind=\(request.sourceKind.rawValue) seekable=\(request.sourceIsSeekableVOD)"
                )
            case .completed(let result):
                print(
                    "AETHER_ACCEPTANCE preflightEvent sequence=\(event.sequence) kind=completed route=\(result.route.rawValue) reason=\(result.reason.rawValue)"
                )
            case .failed(let failure):
                print(
                    "AETHER_ACCEPTANCE preflightEvent sequence=\(event.sequence) kind=failed reason=\(String(describing: failure.reason))"
                )
            }
        }
    }

    private func runAutomaticProgressiveSubtitleFixture(
        _ fixtureURL: URL
    ) async throws {
        let probe = try await Task.detached {
            try AetherEngine.probe(url: fixtureURL)
        }.value
        guard probe.durationSeconds.isFinite,
              probe.durationSeconds > 0,
              !probe.isLive else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "overlay-preflight",
                detail: "fixture is not a finite seekable VOD"
            )
        }
        let sourceProfile = AetherSourceProfile(
            probe: probe,
            sourceKind: .progressive,
            isSeekableVOD: true
        )
        let operation = AetherPlaybackPreflightOperation()
        let preflightResult = try await operation.resolve(
            sourceProfile: sourceProfile,
            hlsPackaging: nil,
            hybridCapabilities:
                AetherHybridPlaybackSession.capabilities
        )
        await emitPreflightTelemetry(operation)
        guard preflightResult.route == .hybridCarrier else {
            throw AcceptanceHarnessError.routeIsNotHybrid(
                route: preflightResult.route,
                reason: preflightResult.reason
            )
        }
        let timeline = try BlackCarrierTimeline.fileVOD(
            duration: CMTime(
                seconds: probe.durationSeconds,
                preferredTimescale: 90_000
            )
        )
        print(
            "AETHER_ACCEPTANCE preflight route=\(preflightResult.route.rawValue) reason=\(preflightResult.reason.rawValue) sourceKind=progressive videoCodec=\(sourceProfile.videoCodec.rawValue) subtitleTracks=\(probe.subtitleTracks.count)"
        )
        print("AETHER_ACCEPTANCE phase=session-create")
        let session = try await AetherHybridPlaybackSession
            .makeSeekableVOD(
                source: .url(fixtureURL),
                options: .init(),
                timeline: timeline,
                preflightResult: preflightResult
            )
        self.session = session
        print("AETHER_ACCEPTANCE phase=host-install")
        try install(session: session)
        print("AETHER_ACCEPTANCE phase=prepare")
        try await session.prepare(timeout: 30)
        print("AETHER_ACCEPTANCE phase=play")
        try session.play()
        startTelemetry(for: session)
        startDiagnosticsSampling()
        setSessionControlsEnabled(true)
        setupPanel.isHidden = true
        if automaticProgressiveNativeSubtitleRunEnabled {
            try await runAutomaticSubtitleScenario(
                session: session
            )
        } else if automaticBitmapSubtitleRunEnabled {
            try await runAutomaticBitmapSubtitleScenario(
                session: session
            )
        } else {
            try await runAutomaticOverlaySubtitleScenario(
                session: session
            )
        }
    }

    private func emitLocalPreflightDiagnosticIfRequested(_ error: Error) {
        guard ProcessInfo.processInfo.environment[
            "AETHER_ACCEPTANCE_LOCAL_DIAGNOSTICS"
        ] == "1" else {
            return
        }
        guard case HLSPreflightError.unsupportedSeekableVODResourceGraph(
            let reason
        ) = error else {
            print(
                "AETHER_ACCEPTANCE localDiagnostic preflightError=\(String(reflecting: type(of: error)))"
            )
            return
        }
        print(
            "AETHER_ACCEPTANCE localDiagnostic unsupportedResourceGraph=\(reason)"
        )
    }

    private func install(session: AetherHybridPlaybackSession) throws {
        _ = playerViewController.view
        guard let overlay = playerViewController.contentOverlayView else {
            throw AcceptanceHarnessError.contentOverlayUnavailable
        }
        session.avPlayer.allowsExternalPlayback = false
        let presentationView = session.presentationView
        presentationView.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(presentationView)
        NSLayoutConstraint.activate([
            presentationView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            presentationView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            presentationView.topAnchor.constraint(equalTo: overlay.topAnchor),
            presentationView.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
        ])
        try session.configureCarrierPlayerViewController(playerViewController)
    }

    private func startTelemetry(for session: AetherHybridPlaybackSession) {
        telemetryTask?.cancel()
        telemetryTask = Task { [weak self] in
            for await event in session.telemetryEvents() {
                guard !Task.isCancelled else { return }
                if event.snapshot.audioAnalysisPlaybackPressure
                    == .carrierPlaybackStalled {
                    self?.observedCarrierStallPressure = true
                }
                Self.logger.notice(
                    "event sequence=\(event.sequence) kind=\(event.kind.rawValue, privacy: .public) route=\(event.snapshot.route.rawValue, privacy: .public) generation=\(event.snapshot.generation) carrierTime=\(event.snapshot.carrierTimeSeconds ?? -1, format: .fixed(precision: 3)) pending=\(event.snapshot.renderer.pendingSampleBuffers) enqueued=\(event.snapshot.renderer.enqueuedSampleBuffers) prerollRejected=\(event.snapshot.readinessPrerollFramesRejected) timebaseBound=\(event.snapshot.renderer.carrierTimebaseBound) renderer=\(event.snapshot.renderer.rendererStatus.rawValue, privacy: .public)"
                )
                print(
                    "AETHER_ACCEPTANCE event sequence=\(event.sequence) kind=\(event.kind.rawValue) route=\(event.snapshot.route.rawValue) generation=\(event.snapshot.generation) carrierTime=\(event.snapshot.carrierTimeSeconds ?? -1) rate=\(event.snapshot.carrierRate) timeControl=\(event.snapshot.carrierTimeControlStatus.rawValue) forwardBuffer=\(event.snapshot.carrierForwardBufferSeconds ?? -1) pressure=\(event.snapshot.audioAnalysisPlaybackPressure.rawValue) pending=\(event.snapshot.renderer.pendingSampleBuffers) enqueued=\(event.snapshot.renderer.enqueuedSampleBuffers) prerollRejected=\(event.snapshot.readinessPrerollFramesRejected) timebaseBound=\(event.snapshot.renderer.carrierTimebaseBound) renderer=\(event.snapshot.renderer.rendererStatus.rawValue) carrierBudget=\(event.snapshot.carrierBandwidth.declaredTransportBudget) carrierObservedPeak=\(event.snapshot.carrierBandwidth.observedPeakBandwidth ?? -1) carrierObservedAverage=\(event.snapshot.carrierBandwidth.observedAverageBandwidth ?? -1) carrierObservedSegments=\(event.snapshot.carrierBandwidth.observedSegmentCount) carrierBandwidthState=\(event.snapshot.carrierBandwidth.state.rawValue)\(self?.telemetryFailureSuffix(event.payload) ?? "")"
                )
                self?.setStatus("event \(event.kind.rawValue)", diagnostics: session.diagnostics)
            }
        }
    }

    private func telemetryFailureSuffix(
        _ payload: AetherHybridPlaybackTelemetryPayload
    ) -> String {
        guard case .sessionFailed(let failure) = payload else {
            return ""
        }
        return " failure=\(String(describing: failure))"
    }

    private func acceptanceFailureSuffix(_ error: Error) -> String {
        if let error = error as? AcceptanceHarnessError {
            return " reason=\(error.localizedDescription)"
        }
        guard ProcessInfo.processInfo.environment[
            "AETHER_ACCEPTANCE_LOCAL_DIAGNOSTICS"
        ] == "1" else {
            return ""
        }
        return " localReason=\(error.localizedDescription)"
    }

    private func startDiagnosticsSampling() {
        diagnosticsTask?.cancel()
        diagnosticsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled,
                      let self,
                      let session = self.session else {
                    return
                }
                self.setStatus("running", diagnostics: session.diagnostics)
            }
        }
    }

    private func runAutomaticClockScenario(
        session: AetherHybridPlaybackSession
    ) async throws {
        try await Task.sleep(for: .seconds(3))
        try requireClockBound(session, step: "startup")
        recordCheckpoint("startup", session: session)

        try session.pause()
        let pausedAt = try carrierTime(session, step: "pause-start")
        try await Task.sleep(for: .seconds(2))
        let pausedAfter = try carrierTime(session, step: "pause-end")
        guard abs(pausedAfter - pausedAt) <= 0.25 else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "pause",
                detail: "carrier advanced \(pausedAfter - pausedAt) seconds"
            )
        }
        try requireClockBound(session, step: "pause")
        recordCheckpoint("pause", session: session)

        try await verifyRate(0.5, duration: .seconds(3), session: session)
        try await verifyRate(1, duration: .seconds(3), session: session)
        try await verifyRate(2, duration: .seconds(3), session: session)
        try session.setRate(1)

        try await verifySeek(offset: 10, name: "forward-seek", session: session)
        try await verifySeek(offset: -10, name: "backward-seek", session: session)
        recordCheckpoint("automatic-clock-scenario-passed", session: session)
        setStatus("automatic clock scenario passed", diagnostics: session.diagnostics)
    }

    private func runAutomaticStallScenario(
        session: AetherHybridPlaybackSession
    ) async throws {
        try await Task.sleep(for: .seconds(2))
        try requireClockBound(session, step: "stall-startup")
        let item = session.avPlayer.currentItem
        let startingGeneration = session.diagnostics.generation
        let deadline = ProcessInfo.processInfo.systemUptime + 35
        var recoveredClockStart: Double?
        var observedRecoveryGeneration: UInt64?

        while ProcessInfo.processInfo.systemUptime < deadline {
            switch session.state {
            case .ready(let generation)
                where observedCarrierStallPressure
                    && generation > startingGeneration:
                guard session.avPlayer.currentItem === item else {
                    throw AcceptanceHarnessError.assertionFailed(
                        step: "controlled-stall",
                        detail: "carrier item changed during recovery"
                    )
                }
                try requireClockBound(session, step: "controlled-stall")
                let currentTime = try carrierTime(
                    session,
                    step: "controlled-stall-clock"
                )
                if observedRecoveryGeneration == nil {
                    observedRecoveryGeneration = generation
                    print(
                        "AETHER_ACCEPTANCE checkpoint=controlled-stall-generation-rebuilt generation=\(generation) carrierTime=\(currentTime)"
                    )
                }
                if let recoveredClockStart,
                   currentTime - recoveredClockStart >= 0.5 {
                    recordCheckpoint(
                        "controlled-stall-recovery-passed",
                        session: session
                    )
                    setStatus(
                        "controlled stall recovery passed",
                        diagnostics: session.diagnostics
                    )
                    return
                }
                recoveredClockStart = recoveredClockStart ?? currentTime
            case .failed(let error):
                throw error
            case .idle, .preparing, .ready, .seeking, .stopped:
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let diagnostics = session.diagnostics
        throw AcceptanceHarnessError.assertionFailed(
            step: "controlled-stall",
            detail: "recovery incomplete stallObserved=\(observedCarrierStallPressure) rebuiltGeneration=\(observedRecoveryGeneration.map(String.init) ?? "none") carrierTime=\(diagnostics.carrierTimeSeconds ?? -1) rate=\(diagnostics.carrierRate) timeControl=\(diagnostics.carrierTimeControlStatus.rawValue) forwardBuffer=\(diagnostics.carrierForwardBufferSeconds ?? -1) pressure=\(diagnostics.audioAnalysisPlaybackPressure.rawValue)"
        )
    }

    private func runAutomaticColorScenario(
        session: AetherHybridPlaybackSession
    ) async throws {
        let expected = try expectedVideoFormat()
        try await Task.sleep(for: .seconds(3))
        try requireClockBound(
            session,
            step: "color-startup"
        )
        let diagnostics = session.diagnostics
        guard diagnostics.videoFormat == expected else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "color-startup",
                detail: "expected \(videoFormatName(expected)), decoded \(videoFormatName(diagnostics.videoFormat))"
            )
        }
        guard diagnostics.renderer.rendererStatus
                == .rendering,
              diagnostics.renderer
                .enqueuedSampleBuffers > 0,
              (diagnostics.carrierTimeSeconds ?? 0) > 1 else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "color-startup",
                detail: "renderer or carrier clock did not advance"
            )
        }
        print(
            "AETHER_ACCEPTANCE colorEvidence videoFormat=\(videoFormatName(expected)) generation=\(diagnostics.generation) timebaseBound=\(diagnostics.renderer.carrierTimebaseBound) renderer=\(diagnostics.renderer.rendererStatus.rawValue) enqueued=\(diagnostics.renderer.enqueuedSampleBuffers)"
        )
        recordCheckpoint(
            "color-\(videoFormatName(expected))-passed",
            session: session
        )
        setStatus(
            "color \(videoFormatName(expected)) passed",
            diagnostics: diagnostics
        )
    }

    private struct GeometryExpectation {
        let mode: String
        let codedWidth: Int
        let codedHeight: Int
        let cleanAperture:
            DecodedVideoFrameGeometry.CleanAperture
        let pixelAspectRatioNumerator: Int
        let pixelAspectRatioDenominator: Int
        let rotationDegrees: Int
        let frameRate: Double
    }

    private func runAutomaticGeometryScenario(
        session: AetherHybridPlaybackSession
    ) async throws {
        let expected = try geometryExpectation()
        try await Task.sleep(for: .seconds(3))
        try requireClockBound(
            session,
            step: "geometry-\(expected.mode)"
        )
        let diagnostics = session.diagnostics
        let actual = try requireGeometry(
            diagnostics.renderer.lastAcceptedGeometry,
            mode: expected.mode
        )
        let frameDuration = diagnostics.renderer
            .lastAcceptedFrameDurationSeconds ?? -1
        let frameRate = frameDuration > 0
            ? 1 / frameDuration
            : -1
        guard actual.codedWidth == expected.codedWidth,
              actual.codedHeight == expected.codedHeight,
              actual.cleanAperture == expected.cleanAperture,
              actual.pixelAspectRatioNumerator
                == expected.pixelAspectRatioNumerator,
              actual.pixelAspectRatioDenominator
                == expected.pixelAspectRatioDenominator,
              actual.rotationDegrees == expected.rotationDegrees,
              abs(frameRate - expected.frameRate) < 0.001,
              diagnostics.renderer.rendererStatus == .rendering,
              diagnostics.renderer.enqueuedSampleBuffers > 0,
              (diagnostics.carrierTimeSeconds ?? 0) > 1 else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "geometry-\(expected.mode)",
                detail: "actual coded=\(actual.codedWidth)x\(actual.codedHeight) aperture=\(actual.cleanAperture.x),\(actual.cleanAperture.y),\(actual.cleanAperture.width),\(actual.cleanAperture.height) sar=\(actual.pixelAspectRatioNumerator):\(actual.pixelAspectRatioDenominator) rotation=\(actual.rotationDegrees) frameRate=\(frameRate)"
            )
        }
        if expected.mode == "clean_aperture" {
            guard playerViewController.videoGravity
                    == .resizeAspect else {
                throw AcceptanceHarnessError.assertionFailed(
                    step: "geometry-gravity-ownership",
                    detail: "carrier gravity changed before real-video policy test"
                )
            }
            session.presentationView.videoGravity =
                .resizeAspectFill
            try await Task.sleep(for: .milliseconds(250))
            try requireClockBound(
                session,
                step: "geometry-gravity-ownership"
            )
            guard session.presentationView.videoGravity
                    == .resizeAspectFill,
                  playerViewController.videoGravity
                    == .resizeAspect else {
                throw AcceptanceHarnessError.assertionFailed(
                    step: "geometry-gravity-ownership",
                    detail: "real-video gravity leaked into the carrier controller"
                )
            }
            session.presentationView.videoGravity = .resizeAspect
            print(
                "AETHER_ACCEPTANCE checkpoint=geometry-gravity-policy-passed realVideo=resizeAspectFill carrier=resizeAspect timebaseBound=true"
            )
        }
        print(
            "AETHER_ACCEPTANCE geometryEvidence mode=\(expected.mode) coded=\(actual.codedWidth)x\(actual.codedHeight) aperture=\(actual.cleanAperture.x),\(actual.cleanAperture.y),\(actual.cleanAperture.width),\(actual.cleanAperture.height) sar=\(actual.pixelAspectRatioNumerator):\(actual.pixelAspectRatioDenominator) rotation=\(actual.rotationDegrees) frameRate=\(frameRate) timebaseBound=\(diagnostics.renderer.carrierTimebaseBound) renderer=\(diagnostics.renderer.rendererStatus.rawValue)"
        )
        recordCheckpoint(
            "geometry-\(expected.mode)-passed",
            session: session
        )
        setStatus(
            "geometry \(expected.mode) passed",
            diagnostics: diagnostics
        )
    }

    private func requireGeometry(
        _ geometry: DecodedVideoFrameGeometry?,
        mode: String
    ) throws -> DecodedVideoFrameGeometry {
        guard let geometry else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "geometry-\(mode)",
                detail: "renderer has not admitted decoded geometry"
            )
        }
        return geometry
    }

    private func geometryExpectation() throws
        -> GeometryExpectation
    {
        let mode = ProcessInfo.processInfo.environment[
            "AETHER_ACCEPTANCE_GEOMETRY_MODE"
        ] ?? ""
        switch mode {
        case "standard", "clean_aperture":
            return GeometryExpectation(
                mode: mode,
                codedWidth: 1920,
                codedHeight: 1080,
                cleanAperture: .init(
                    x: 0,
                    y: 0,
                    width: 1920,
                    height: 1080
                ),
                pixelAspectRatioNumerator: 1,
                pixelAspectRatioDenominator: 1,
                rotationDegrees: 0,
                frameRate: 24
            )
        case "sar_4_3":
            return GeometryExpectation(
                mode: mode,
                codedWidth: 720,
                codedHeight: 576,
                cleanAperture: .init(
                    x: 0,
                    y: 0,
                    width: 720,
                    height: 576
                ),
                pixelAspectRatioNumerator: 16,
                pixelAspectRatioDenominator: 15,
                rotationDegrees: 0,
                frameRate: 25
            )
        case "rotation_90", "rotation_180", "rotation_270":
            let rotation = Int(
                mode.dropFirst("rotation_".count)
            ) ?? -1
            return GeometryExpectation(
                mode: mode,
                codedWidth: 1280,
                codedHeight: 720,
                cleanAperture: .init(
                    x: 0,
                    y: 0,
                    width: 1280,
                    height: 720
                ),
                pixelAspectRatioNumerator: 1,
                pixelAspectRatioDenominator: 1,
                rotationDegrees: rotation,
                frameRate: 24
            )
        case "fps_24000_1001":
            return GeometryExpectation(
                mode: mode,
                codedWidth: 1280,
                codedHeight: 720,
                cleanAperture: .init(
                    x: 0,
                    y: 0,
                    width: 1280,
                    height: 720
                ),
                pixelAspectRatioNumerator: 1,
                pixelAspectRatioDenominator: 1,
                rotationDegrees: 0,
                frameRate: 24_000 / 1_001
            )
        case "fps_15":
            return GeometryExpectation(
                mode: mode,
                codedWidth: 1280,
                codedHeight: 720,
                cleanAperture: .init(
                    x: 0,
                    y: 0,
                    width: 1280,
                    height: 720
                ),
                pixelAspectRatioNumerator: 1,
                pixelAspectRatioDenominator: 1,
                rotationDegrees: 0,
                frameRate: 15
            )
        default:
            throw AcceptanceHarnessError.assertionFailed(
                step: "geometry-configuration",
                detail: "geometry mode is missing or invalid"
            )
        }
    }

    private func runAutomaticNegativeScenario(
        session: AetherHybridPlaybackSession
    ) async throws {
        guard let mutation = ProcessInfo.processInfo
            .environment[
                "AETHER_ACCEPTANCE_NEGATIVE_CASE"
            ] else {
            throw AcceptanceHarnessError
                .assertionFailed(
                    step: "negative-configuration",
                    detail: "mutation is missing"
                )
        }
        try await Task.sleep(for: .seconds(2))
        try requireClockBound(
            session,
            step: "negative-\(mutation)-startup"
        )

        switch mutation {
        case "player":
            playerViewController.player = AVPlayer()
        case "gravity":
            playerViewController.videoGravity =
                .resizeAspectFill
        case "automaticDisplayCriteria":
            throw AcceptanceHarnessError
                .assertionFailed(
                    step: "negative-automaticDisplayCriteria",
                    detail: "this mutation must run before prepare"
                )
        case "presentationOverlay":
            session.presentationView.removeFromSuperview()
        case "carrierItem":
            guard let currentItem =
                    session.avPlayer.currentItem else {
                throw AcceptanceHarnessError
                    .assertionFailed(
                        step: "negative-carrierItem",
                        detail: "current carrier item is unavailable"
                    )
            }
            session.avPlayer.replaceCurrentItem(
                with: AVPlayerItem(
                    asset: currentItem.asset
                )
            )
        default:
            throw AcceptanceHarnessError
                .assertionFailed(
                    step: "negative-configuration",
                    detail: "unknown mutation \(mutation)"
                )
        }

        let deadline = ProcessInfo.processInfo
            .systemUptime + 5
        while ProcessInfo.processInfo.systemUptime
                < deadline {
            if case .failed(let error) = session.state {
                print(
                    "AETHER_ACCEPTANCE checkpoint=negative-case-passed mutation=\(mutation) failure=\(String(describing: error)) route=\(session.preflightResult.route.rawValue)"
                )
                setStatus(
                    "negative \(mutation) passed",
                    detail: String(describing: error)
                )
                return
            }
            try await Task.sleep(
                for: .milliseconds(50)
            )
        }
        throw AcceptanceHarnessError.assertionFailed(
            step: "negative-\(mutation)",
            detail: "mutation did not terminate the Hybrid session"
        )
    }

    private func runPreparationNegativeScenarioIfRequested(
        session: AetherHybridPlaybackSession
    ) async throws -> Bool {
        guard ProcessInfo.processInfo.environment[
            "AETHER_ACCEPTANCE_NEGATIVE_CASE"
        ] == "automaticDisplayCriteria" else {
            return false
        }
        playerViewController
            .appliesPreferredDisplayCriteriaAutomatically = true
        print("AETHER_ACCEPTANCE phase=negative-prepare")
        do {
            try await session.prepare(timeout: 30)
        } catch let error as HybridPlaybackSessionError {
            guard error
                    == .carrierPresentationContractChanged,
                  session.state == .failed(
                    .carrierPresentationContractChanged
                  ) else {
                throw error
            }
            print(
                "AETHER_ACCEPTANCE checkpoint=negative-case-passed mutation=automaticDisplayCriteria failure=\(String(describing: error)) route=\(session.preflightResult.route.rawValue)"
            )
            setStatus(
                "negative automaticDisplayCriteria passed",
                detail: String(describing: error)
            )
            return true
        }
        throw AcceptanceHarnessError.assertionFailed(
            step: "negative-automaticDisplayCriteria",
            detail: "prepare admitted a conflicting AVKit display-criteria writer"
        )
    }

    private func expectedVideoFormat() throws
        -> VideoFormat
    {
        switch ProcessInfo.processInfo.environment[
            "AETHER_ACCEPTANCE_EXPECTED_VIDEO_FORMAT"
        ]?.lowercased() {
        case "sdr": return .sdr
        case "hdr10": return .hdr10
        case "hdr10plus": return .hdr10Plus
        case "hlg": return .hlg
        case "dolbyvision": return .dolbyVision
        default:
            throw AcceptanceHarnessError
                .assertionFailed(
                    step: "color-configuration",
                    detail: "expected video format is missing or invalid"
                )
        }
    }

    private func videoFormatName(
        _ format: VideoFormat
    ) -> String {
        switch format {
        case .sdr: "sdr"
        case .hdr10: "hdr10"
        case .hdr10Plus: "hdr10plus"
        case .hlg: "hlg"
        case .dolbyVision: "dolbyvision"
        }
    }

    private func runAutomaticStopAndReopenScenario(
        preflight: AetherHLSPlaybackPreflight,
        priorSession: AetherHybridPlaybackSession
    ) async throws {
        let priorPresentationView = priorSession.presentationView
        priorSession.stop()
        let stoppedDiagnostics = priorSession.diagnostics
        guard priorSession.state == .stopped,
              priorSession.avPlayer.currentItem == nil,
              !stoppedDiagnostics.renderer.carrierTimebaseBound,
              stoppedDiagnostics.renderer.pendingSampleBuffers == 0 else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "stop",
                detail: "carrier item, timebase, or pending samples survived stop"
            )
        }
        priorPresentationView.removeFromSuperview()
        session = nil
        playerViewController.player = nil
        print(
            "AETHER_ACCEPTANCE checkpoint=stop state=stopped itemReleased=true timebaseBound=false pending=0"
        )

        print("AETHER_ACCEPTANCE phase=reopen-session-create")
        let reopened = try await AetherHybridPlaybackSession.makeHLSVOD(
            preflight: preflight
        )
        guard reopened.presentationView !== priorPresentationView else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "reopen",
                detail: "new session reused the stopped presentation view"
            )
        }
        session = reopened
        print("AETHER_ACCEPTANCE phase=reopen-host-install")
        try install(session: reopened)
        print("AETHER_ACCEPTANCE phase=reopen-prepare")
        try await reopened.prepare(timeout: 30)
        print("AETHER_ACCEPTANCE phase=reopen-play")
        try reopened.play()
        startTelemetry(for: reopened)
        try await Task.sleep(for: .seconds(3))
        try requireClockBound(reopened, step: "reopen")
        guard reopened.diagnostics.generation == 0,
              (reopened.diagnostics.carrierTimeSeconds ?? 0) > 1,
              !priorSession.diagnostics.renderer.carrierTimebaseBound else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "reopen",
                detail: "new generation did not start cleanly or old timebase rebound"
            )
        }
        recordCheckpoint("stop-and-reopen-passed", session: reopened)
        setStatus("stop and reopen passed", diagnostics: reopened.diagnostics)
    }

    private func runAutomaticAudioTrackSwitchScenario(
        session: AetherHybridPlaybackSession
    ) async throws {
        guard let item = session.avPlayer.currentItem else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "audio-track-switch",
                detail: "carrier item is unavailable"
            )
        }
        guard let group = try await item.asset.loadMediaSelectionGroup(
            for: .audible
        ), group.options.count >= 2 else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "audio-track-switch",
                detail: "carrier does not expose two audible options"
            )
        }
        let original = item.currentMediaSelection
            .selectedMediaOption(in: group) ?? group.options[0]
        guard let alternate = group.options.first(where: {
            !$0.isEqual(original)
        }) else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "audio-track-switch",
                detail: "carrier has no alternate audible option"
            )
        }

        let outboundGeneration = session.diagnostics.generation
        item.select(alternate, in: group)
        try await waitForReadyGeneration(
            after: outboundGeneration,
            session: session,
            step: "audio-track-switch-outbound"
        )
        guard item.currentMediaSelection
                .selectedMediaOption(in: group)?.isEqual(alternate) == true else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "audio-track-switch-outbound",
                detail: "alternate audible option was not selected"
            )
        }
        recordCheckpoint("audio-track-switch-outbound", session: session)

        let returnGeneration = session.diagnostics.generation
        item.select(original, in: group)
        try await waitForReadyGeneration(
            after: returnGeneration,
            session: session,
            step: "audio-track-switch-return"
        )
        guard item.currentMediaSelection
                .selectedMediaOption(in: group)?.isEqual(original) == true else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "audio-track-switch-return",
                detail: "original audible option was not restored"
            )
        }
        recordCheckpoint("audio-track-switch-passed", session: session)
    }

    private func runAutomaticSubtitleScenario(
        session: AetherHybridPlaybackSession
    ) async throws {
        try await Task.sleep(for: .seconds(3))
        try requireClockBound(session, step: "subtitle-startup")
        guard let item = session.avPlayer.currentItem else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "subtitle-selection",
                detail: "carrier item is unavailable"
            )
        }
        guard let group = try await item.asset.loadMediaSelectionGroup(
            for: .legible
        ), let option = group.options.first else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "subtitle-selection",
                detail: "carrier does not expose a legible option"
            )
        }
        let wasInitiallySelected = item.currentMediaSelection
            .selectedMediaOption(in: group) != nil
        item.select(nil, in: group)
        try await Task.sleep(for: .milliseconds(500))
        let start = try carrierTime(session, step: "subtitle-select-start")
        item.select(option, in: group)
        try await Task.sleep(for: .seconds(2))
        guard item.currentMediaSelection
                .selectedMediaOption(in: group)?.isEqual(option) == true else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "subtitle-select",
                detail: "native WebVTT option was not selected"
            )
        }
        try requireHealthySubtitleClock(
            after: start,
            session: session,
            step: "subtitle-select"
        )

        item.select(nil, in: group)
        try await Task.sleep(for: .milliseconds(500))
        guard item.currentMediaSelection
                .selectedMediaOption(in: group) == nil else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "subtitle-deselect",
                detail: "native subtitle option remained selected"
            )
        }
        item.select(option, in: group)
        try await Task.sleep(for: .seconds(1))
        guard item.currentMediaSelection
                .selectedMediaOption(in: group)?.isEqual(option) == true else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "subtitle-reselect",
                detail: "native subtitle option was not restored"
            )
        }
        try requireClockBound(session, step: "subtitle-reselect")
        try await waitForNativeWebVTT(
            visible: true,
            session: session,
            step: "subtitle-presentation"
        )
        print(
            "AETHER_ACCEPTANCE subtitleEvidence legibleOptions=\(group.options.count) initiallySelected=\(wasInitiallySelected) select=true deselect=true reselect=true aetherPresentation=true"
        )
        recordCheckpoint("native-webvtt-selection-passed", session: session)
        setStatus(
            "native WebVTT selection passed",
            diagnostics: session.diagnostics
        )
    }

    private func waitForNativeWebVTT(
        visible: Bool,
        session: AetherHybridPlaybackSession,
        step: String
    ) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while ProcessInfo.processInfo.systemUptime < deadline {
            if case .failed(let error) = session.state {
                throw error
            }
            if session.diagnostics.renderer
                    .nativeWebVTTVisible == visible {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AcceptanceHarnessError.assertionFailed(
            step: step,
            detail:
                "Aether native WebVTT overlay visibility did not become \(visible)"
        )
    }

    private func runAutomaticOverlaySubtitleScenario(
        session: AetherHybridPlaybackSession
    ) async throws {
        guard session.activeOverlaySubtitleTrackID == nil else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "overlay-initial-selection",
                detail: "overlay track was selected without a host action"
            )
        }
        guard session.overlaySubtitleTracks.count == 1,
              let track = session.overlaySubtitleTracks.first,
              track.kind == .styledText,
              track.availability == .available else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "overlay-track-contract",
                detail: "expected one available styled track"
            )
        }
        guard playerViewController.transportBarCustomMenuItems
                .contains(where: { $0.title == "Aether Subtitles" }) else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "overlay-avkit-menu",
                detail: "Aether subtitle menu is not installed in AVKit"
            )
        }

        try session.selectOverlaySubtitleTrack(track.id)
        try await waitForStyledSubtitle(
            visible: true,
            session: session,
            step: "overlay-startup"
        )
        try requireClockBound(session, step: "overlay-startup")
        recordCheckpoint("styled-overlay-startup", session: session)

        let generation = session.diagnostics.generation
        _ = try await session.seek(
            to: CMTime(
                seconds: 16.5,
                preferredTimescale: 90_000
            ),
            timeout: 30
        )
        guard session.diagnostics.generation > generation else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "overlay-seek",
                detail: "presentation generation did not advance"
            )
        }
        try await waitForStyledSubtitle(
            visible: true,
            session: session,
            step: "overlay-seek"
        )
        try requireClockBound(session, step: "overlay-seek")
        recordCheckpoint("styled-overlay-seek", session: session)

        try session.selectOverlaySubtitleTrack(nil)
        try await waitForStyledSubtitle(
            visible: false,
            session: session,
            step: "overlay-off"
        )
        guard session.activeOverlaySubtitleTrackID == nil else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "overlay-off",
                detail: "active track survived explicit Off"
            )
        }
        try session.selectOverlaySubtitleTrack(track.id)
        try await waitForStyledSubtitle(
            visible: true,
            session: session,
            step: "overlay-reselect"
        )
        try requireClockBound(session, step: "overlay-reselect")
        print(
            "AETHER_ACCEPTANCE subtitleOverlayEvidence kind=styled initialSelection=off menuInstalled=true select=true seek=true deselect=true reselect=true visible=true"
        )
        recordCheckpoint(
            "styled-overlay-selection-passed",
            session: session
        )
        setStatus(
            "styled overlay selection passed",
            diagnostics: session.diagnostics
        )
    }

    private func runAutomaticBitmapSubtitleScenario(
        session: AetherHybridPlaybackSession
    ) async throws {
        guard session.activeOverlaySubtitleTrackID == nil else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "bitmap-initial-selection",
                detail: "bitmap track was selected without a host action"
            )
        }
        guard session.overlaySubtitleTracks.count == 1,
              let track = session.overlaySubtitleTracks.first,
              track.kind == .bitmap,
              track.availability == .available else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "bitmap-track-contract",
                detail: "expected one available bitmap track"
            )
        }
        guard playerViewController.transportBarCustomMenuItems
                .contains(where: { $0.title == "Aether Subtitles" }) else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "bitmap-avkit-menu",
                detail: "Aether subtitle menu is not installed in AVKit"
            )
        }

        try session.selectOverlaySubtitleTrack(track.id)
        let initialTime = try carrierTime(
            session,
            step: "bitmap-before-first-cue"
        )
        guard initialTime < 1 else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "bitmap-before-first-cue",
                detail: "fixture setup did not complete before the first cue"
            )
        }
        try await waitForBitmapSubtitle(
            visible: false,
            session: session,
            step: "bitmap-before-first-cue"
        )
        try await waitForCarrierTime(
            atLeast: 1.1,
            session: session,
            step: "bitmap-first-cue-time"
        )
        try await waitForBitmapSubtitle(
            visible: true,
            session: session,
            step: "bitmap-startup"
        )
        try requireClockBound(session, step: "bitmap-startup")
        recordCheckpoint("bitmap-overlay-startup", session: session)

        let generation = session.diagnostics.generation
        _ = try await session.seek(
            to: CMTime(
                seconds: 16.5,
                preferredTimescale: 90_000
            ),
            timeout: 30
        )
        guard session.diagnostics.generation > generation else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "bitmap-seek",
                detail: "presentation generation did not advance"
            )
        }
        try await waitForBitmapSubtitle(
            visible: true,
            session: session,
            step: "bitmap-seek"
        )
        try requireClockBound(session, step: "bitmap-seek")
        recordCheckpoint("bitmap-overlay-seek", session: session)

        try session.selectOverlaySubtitleTrack(nil)
        try await waitForBitmapSubtitle(
            visible: false,
            session: session,
            step: "bitmap-off"
        )
        guard session.activeOverlaySubtitleTrackID == nil else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "bitmap-off",
                detail: "active track survived explicit Off"
            )
        }
        try session.selectOverlaySubtitleTrack(track.id)
        try await waitForBitmapSubtitle(
            visible: true,
            session: session,
            step: "bitmap-reselect"
        )
        try requireClockBound(session, step: "bitmap-reselect")
        print(
            "AETHER_ACCEPTANCE subtitleOverlayEvidence kind=bitmap initialSelection=off menuInstalled=true select=true seek=true deselect=true reselect=true visible=true"
        )
        recordCheckpoint(
            "bitmap-overlay-selection-passed",
            session: session
        )
        setStatus(
            "bitmap overlay selection passed",
            diagnostics: session.diagnostics
        )
    }

    private func waitForCarrierTime(
        atLeast target: Double,
        session: AetherHybridPlaybackSession,
        step: String
    ) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while ProcessInfo.processInfo.systemUptime < deadline {
            if case .failed(let error) = session.state {
                throw error
            }
            if let time = session.diagnostics.carrierTimeSeconds,
               time >= target {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AcceptanceHarnessError.assertionFailed(
            step: step,
            detail: "carrier time did not reach \(target)"
        )
    }

    private func waitForBitmapSubtitle(
        visible: Bool,
        session: AetherHybridPlaybackSession,
        step: String
    ) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while ProcessInfo.processInfo.systemUptime < deadline {
            if case .failed(let error) = session.state {
                throw error
            }
            let visibleCount = session.diagnostics.renderer
                .visibleBitmapSubtitleCount
            if (visibleCount > 0) == visible {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AcceptanceHarnessError.assertionFailed(
            step: step,
            detail:
                "bitmap subtitle visibility did not become \(visible)"
        )
    }

    private func waitForStyledSubtitle(
        visible: Bool,
        session: AetherHybridPlaybackSession,
        step: String
    ) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while ProcessInfo.processInfo.systemUptime < deadline {
            if case .failed(let error) = session.state {
                throw error
            }
            if session.diagnostics.renderer
                    .styledSubtitleVisible == visible {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AcceptanceHarnessError.assertionFailed(
            step: step,
            detail: "styled subtitle visibility did not become \(visible)"
        )
    }

    private func requireHealthySubtitleClock(
        after start: Double,
        session: AetherHybridPlaybackSession,
        step: String
    ) throws {
        if case .failed(let error) = session.state {
            throw error
        }
        let end = try carrierTime(session, step: step)
        guard end - start >= 1 else {
            throw AcceptanceHarnessError.assertionFailed(
                step: step,
                detail: "carrier clock stopped while changing subtitle selection"
            )
        }
        try requireClockBound(session, step: step)
    }

    private func waitForReadyGeneration(
        after generation: UInt64,
        session: AetherHybridPlaybackSession,
        step: String
    ) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while ProcessInfo.processInfo.systemUptime < deadline {
            switch session.state {
            case .ready(let currentGeneration)
                where currentGeneration > generation:
                return
            case .failed(let error):
                throw error
            case .idle, .preparing, .ready, .seeking, .stopped:
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AcceptanceHarnessError.assertionFailed(
            step: step,
            detail: "presentation generation did not rebuild"
        )
    }

    private func verifyRate(
        _ rate: Float,
        duration: Duration,
        session: AetherHybridPlaybackSession
    ) async throws {
        try session.setRate(rate)
        let start = try carrierTime(session, step: "rate-\(rate)-start")
        try await Task.sleep(for: duration)
        let end = try carrierTime(session, step: "rate-\(rate)-end")
        let elapsed = Double(duration.components.seconds)
        let expectedAdvance = elapsed * Double(rate)
        let actualAdvance = end - start
        let tolerance = max(0.75, expectedAdvance * 0.35)
        guard abs(actualAdvance - expectedAdvance) <= tolerance else {
            throw AcceptanceHarnessError.assertionFailed(
                step: "rate-\(rate)",
                detail: "expected \(expectedAdvance)s, observed \(actualAdvance)s"
            )
        }
        try requireClockBound(session, step: "rate-\(rate)")
        recordCheckpoint("rate-\(rate)", session: session)
    }

    private func verifySeek(
        offset: Double,
        name: String,
        session: AetherHybridPlaybackSession
    ) async throws {
        let before = session.diagnostics
        let current = try carrierTime(session, step: "\(name)-start")
        let target = min(
            max(0, current + offset),
            max(0, before.timelineDurationSeconds - 2)
        )
        _ = try await session.seek(
            to: CMTime(seconds: target, preferredTimescale: 90_000),
            timeout: 30
        )
        let after = session.diagnostics
        guard after.generation > before.generation else {
            throw AcceptanceHarnessError.assertionFailed(
                step: name,
                detail: "generation did not advance"
            )
        }
        let landed = try carrierTime(session, step: "\(name)-landed")
        guard abs(landed - target) <= 1.5 else {
            throw AcceptanceHarnessError.assertionFailed(
                step: name,
                detail: "target \(target), landed \(landed)"
            )
        }
        try requireClockBound(session, step: name)
        recordCheckpoint(name, session: session)
    }

    private func carrierTime(
        _ session: AetherHybridPlaybackSession,
        step: String
    ) throws -> Double {
        guard let time = session.diagnostics.carrierTimeSeconds else {
            throw AcceptanceHarnessError.assertionFailed(
                step: step,
                detail: "carrier time is unavailable"
            )
        }
        return time
    }

    private func requireClockBound(
        _ session: AetherHybridPlaybackSession,
        step: String
    ) throws {
        guard session.diagnostics.renderer.carrierTimebaseBound else {
            throw AcceptanceHarnessError.assertionFailed(
                step: step,
                detail: "sample-buffer layer is not bound to the carrier timebase"
            )
        }
    }

    private func recordCheckpoint(
        _ step: String,
        session: AetherHybridPlaybackSession
    ) {
        let diagnostics = session.diagnostics
        Self.logger.notice(
            "checkpoint=\(step, privacy: .public) generation=\(diagnostics.generation) carrierTime=\(diagnostics.carrierTimeSeconds ?? -1, format: .fixed(precision: 3)) rate=\(diagnostics.carrierRate) timebaseBound=\(diagnostics.renderer.carrierTimebaseBound) pending=\(diagnostics.renderer.pendingSampleBuffers) enqueued=\(diagnostics.renderer.enqueuedSampleBuffers)"
        )
        print(
            "AETHER_ACCEPTANCE checkpoint=\(step) generation=\(diagnostics.generation) carrierTime=\(diagnostics.carrierTimeSeconds ?? -1) rate=\(diagnostics.carrierRate) timebaseBound=\(diagnostics.renderer.carrierTimebaseBound) pending=\(diagnostics.renderer.pendingSampleBuffers) enqueued=\(diagnostics.renderer.enqueuedSampleBuffers)"
        )
    }

    @objc private func pauseTapped() {
        performSessionAction("pause") { try $0.pause() }
    }

    @objc private func rateHalfTapped() {
        performSessionAction("rate 0.5") { try $0.setRate(0.5) }
    }

    @objc private func rateNormalTapped() {
        performSessionAction("rate 1.0") { try $0.setRate(1) }
    }

    @objc private func rateDoubleTapped() {
        performSessionAction("rate 2.0") { try $0.setRate(2) }
    }

    @objc private func seekBackwardTapped() {
        seek(by: -10)
    }

    @objc private func seekForwardTapped() {
        seek(by: 10)
    }

    private func seek(by offset: Double) {
        guard let session else {
            setStatus("terminal failure", detail: AcceptanceHarnessError.sessionUnavailable.localizedDescription)
            return
        }
        let diagnostics = session.diagnostics
        let current = diagnostics.carrierTimeSeconds ?? 0
        let target = min(max(0, current + offset), diagnostics.timelineDurationSeconds)
        Task { [weak self] in
            do {
                _ = try await session.seek(
                    to: CMTime(seconds: target, preferredTimescale: 90_000),
                    timeout: 30
                )
                self?.setStatus("seek landed", diagnostics: session.diagnostics)
            } catch {
                self?.handleTerminal(error)
            }
        }
    }

    @objc private func stopTapped() {
        stopCurrentSession()
        setupPanel.isHidden = false
        setStatus("stopped", detail: "old generation and carrier were released")
    }

    private func performSessionAction(
        _ name: String,
        action: (AetherHybridPlaybackSession) throws -> Void
    ) {
        guard let session else {
            setStatus("terminal failure", detail: AcceptanceHarnessError.sessionUnavailable.localizedDescription)
            return
        }
        do {
            try action(session)
            setStatus(name, diagnostics: session.diagnostics)
        } catch {
            handleTerminal(error)
        }
    }

    private func stopCurrentSession() {
        telemetryTask?.cancel()
        telemetryTask = nil
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        session?.stop()
        session = nil
        playerViewController.player = nil
        setSessionControlsEnabled(false)
    }

    private func handleTerminal(_ error: Error) {
        session?.stop()
        session = nil
        telemetryTask?.cancel()
        telemetryTask = nil
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        setSessionControlsEnabled(false)
        setupPanel.isHidden = false
        setStatus("terminal failure", detail: error.localizedDescription)
        Self.logger.error("terminal failure=\(String(describing: error), privacy: .public)")
    }

    private func setSessionControlsEnabled(_ enabled: Bool) {
        actionPanel.isHidden = !enabled
        actionPanel.arrangedSubviews.forEach { $0.isUserInteractionEnabled = enabled }
    }

    private func setStatus(_ title: String, detail: String) {
        statusLabel.text = "\(title)\n\(detail)"
    }

    private func setStatus(
        _ title: String,
        diagnostics: AetherHybridPlaybackDiagnostics
    ) {
        let time = diagnostics.carrierTimeSeconds ?? -1
        statusLabel.text = [
            title,
            "route=\(diagnostics.preflightResult.route.rawValue) generation=\(diagnostics.generation) time=\(String(format: "%.3f", time)) rate=\(diagnostics.carrierRate)",
            "timebase=\(diagnostics.renderer.carrierTimebaseBound) renderer=\(diagnostics.renderer.rendererStatus.rawValue) pending=\(diagnostics.renderer.pendingSampleBuffers) enqueued=\(diagnostics.renderer.enqueuedSampleBuffers)",
        ].joined(separator: "\n")
    }
}
