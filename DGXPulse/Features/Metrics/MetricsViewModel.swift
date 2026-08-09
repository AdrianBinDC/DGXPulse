// swiftlint:disable file_length
import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class MetricsViewModel {
    private(set) var phase: ConnectionPhase = .signedOut
    private(set) var latestSample: MetricsSample?
    private(set) var history: [MetricsSample] = []
    private(set) var statusMessage: String = "Sign in to stream metrics."
    private(set) var diagnostics: [String] = []
    private(set) var menuBarTitle: String = "DGXPulse"
    private(set) var isDetailPresented = false
    /// One-shot signal after interactive sign-in so the UI can swap windows.
    private(set) var postSignInNavigationPending = false

    var username: String = ""
    var password: String = ""
    var overrideBaseURLString: String = ""
    var selectedHistoryRange: HistoryRange = .fiveMinutes

    private let dependencies: AppDependencies
    private var streamTask: Task<Void, Never>?
    private var lastPublishedMenuBarKey: String?
    private var lastMenuBarPublish: Date?
    private var lastHistoryPublish: Date?
    private var lastSampleReceivedAt: Date?
    private var reconnectAttempt = 0
    nonisolated(unsafe) private var wakeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var staleWatchTask: Task<Void, Never>?

    var isSignedIn: Bool {
        switch phase {
        case .signedOut, .failed(.unauthorized), .failed(.loginFailed):
            return false
        default:
            return true
        }
    }

    var canSignIn: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        installWakeObserver()
        startStaleWatch()
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        staleWatchTask?.cancel()
    }

    func onAppear() {
        Task { await bootstrap() }
    }

    func bootstrap() async {
        overrideBaseURLString = dependencies.preferences.overrideBaseURL?.absoluteString ?? ""
        selectedHistoryRange = dependencies.preferences.historyRange
        if let savedUsername = await dependencies.sessionStore.loadUsername() {
            username = savedUsername
        }
        if let token = await dependencies.sessionStore.loadToken() {
            statusMessage = "Restoring session…"
            // Sync often rebinds a new localhost port after relaunch/sleep.
            dependencies.preferences.lastKnownBaseURL = nil
            await startStreaming(with: token)
        } else {
            phase = .signedOut
            statusMessage = "Sign in to stream metrics."
        }
    }

    func signIn() {
        Task { await performSignIn() }
    }

    func acknowledgePostSignInNavigation() {
        postSignInNavigationPending = false
    }

    func signOut() {
        streamTask?.cancel()
        streamTask = nil
        Task {
            await dependencies.sessionStore.clear()
            phase = .signedOut
            latestSample = nil
            history = []
            password = ""
            statusMessage = "Signed out."
            menuBarTitle = "DGXPulse"
            lastPublishedMenuBarKey = nil
            dependencies.logger.info("Signed out", category: .auth)
        }
    }

    func retry() {
        Task {
            if let token = await dependencies.sessionStore.loadToken() {
                await startStreaming(with: token)
            } else {
                phase = .signedOut
                statusMessage = "Sign in to stream metrics."
            }
        }
    }

    func rediscover() {
        dependencies.preferences.lastKnownBaseURL = nil
        clearStalePresentation(status: "Looking for DGX Dashboard…")
        retry()
    }

    func handleSystemWake() {
        dependencies.logger.info("System woke; waiting for NVIDIA Sync before rediscovery", category: .endpoint)
        dependencies.preferences.lastKnownBaseURL = nil
        clearStalePresentation(status: "Mac woke — waiting for NVIDIA Sync…")
        streamTask?.cancel()
        streamTask = nil
        Task {
            do {
                try await dependencies.sleeper.sleep(for: DashboardPorts.postWakeSettleDelay)
            } catch {
                return
            }
            retry()
        }
    }

    func saveOverrideURL() {
        let trimmed = overrideBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            dependencies.preferences.overrideBaseURL = nil
        } else if let url = URL(string: trimmed) {
            dependencies.preferences.overrideBaseURL = url
        }
    }

    func resetDefaults() {
        overrideBaseURLString = ""
        dependencies.preferences.overrideBaseURL = nil
        dependencies.preferences.lastKnownBaseURL = nil
        dependencies.preferences.historyRetentionHours = 24
        selectedHistoryRange = .fiveMinutes
        dependencies.preferences.historyRange = .fiveMinutes
    }

    func refreshDiagnostics() {
        Task {
            diagnostics = await dependencies.diagnostics.snapshot()
        }
    }

    func openDetail() {
        isDetailPresented = true
        Task { await refreshHistory() }
    }

    func historyRangeChanged() {
        dependencies.preferences.historyRange = selectedHistoryRange
        Task { await refreshHistory() }
    }

    private func performSignIn() async {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !password.isEmpty else {
            phase = .signedOut
            statusMessage = "Enter your dashboard username and password."
            return
        }

        phase = .resolvingEndpoint
        statusMessage = "Looking for DGX Dashboard…"
        do {
            let baseURL = try await dependencies.endpointResolver.resolve()
            phase = .authenticating
            statusMessage = "Signing in…"
            let token = try await dependencies.authClient.login(
                baseURL: baseURL,
                username: trimmed,
                password: password
            )
            try await dependencies.sessionStore.save(username: trimmed, token: token)
            password = ""
            username = trimmed
            await dependencies.endpointResolver.rememberSuccessfulEndpoint(baseURL)
            postSignInNavigationPending = true
            await startStreaming(with: token, baseURL: baseURL)
        } catch let failure as ConnectionFailure {
            await handleFailure(failure)
        } catch {
            await handleFailure(.server(error.localizedDescription))
        }
    }

    private func startStreaming(with token: String, baseURL: URL? = nil) async {
        streamTask?.cancel()
        reconnectAttempt = 0

        streamTask = Task { [weak self] in
            guard let self else { return }
            var activeToken = token
            // First attempt may reuse the URL from sign-in; later attempts always rediscover.
            var preferredBase = baseURL

            while !Task.isCancelled {
                do {
                    self.phase = .resolvingEndpoint
                    self.statusMessage = "Looking for DGX Dashboard…"
                    let resolved: URL
                    if let preferred = preferredBase {
                        resolved = preferred
                        preferredBase = nil
                    } else {
                        resolved = try await self.dependencies.endpointResolver.resolve()
                    }
                    await self.dependencies.endpointResolver.rememberSuccessfulEndpoint(resolved)

                    self.phase = .streaming
                    self.statusMessage = "Connected. Waiting for telemetry…"

                    for await event in self.dependencies.metricsSource.events(
                        token: activeToken,
                        baseURL: resolved
                    ) {
                        if Task.isCancelled { return }
                        switch event {
                        case .connected:
                            self.reconnectAttempt = 0
                            self.phase = .streaming
                            self.statusMessage = "Live"
                            self.dependencies.logger.info(
                                "Telemetry stream connected",
                                category: .telemetry
                            )
                        case .sample(let sample):
                            self.reconnectAttempt = 0
                            self.phase = .streaming
                            self.statusMessage = "Live"
                            await self.accept(sample)
                        case .failure(let failure):
                            if failure == .cancelled { return }
                            if failure == .unauthorized {
                                await self.dependencies.sessionStore.clear()
                                self.phase = .signedOut
                                self.statusMessage = failure.userMessage
                                self.menuBarTitle = "DGXPulse"
                                return
                            }
                            if failure == .malformedTelemetry {
                                self.dependencies.logger.error(
                                    "Ignoring malformed telemetry event",
                                    category: .telemetry
                                )
                                continue
                            }
                            throw failure
                        }
                    }

                    throw ConnectionFailure.tunnelUnavailable
                } catch let failure as ConnectionFailure {
                    if failure == .cancelled || Task.isCancelled { return }
                    if failure == .unauthorized {
                        await self.dependencies.sessionStore.clear()
                        self.phase = .signedOut
                        self.statusMessage = failure.userMessage
                        return
                    }

                    self.phase = .reconnecting(failure)
                    self.statusMessage = failure.userMessage
                    self.latestSample = nil
                    self.lastSampleReceivedAt = nil
                    self.menuBarTitle = "DGXPulse"
                    self.dependencies.preferences.lastKnownBaseURL = nil
                    preferredBase = nil
                    let delay = ReconnectBackoff.delay(forAttempt: self.reconnectAttempt)
                    self.reconnectAttempt += 1
                    self.dependencies.logger.error(
                        "Stream interrupted: \(failure.userMessage); retry in \(delay)",
                        category: .telemetry
                    )
                    do {
                        try await self.dependencies.sleeper.sleep(for: delay)
                    } catch {
                        return
                    }

                    if let refreshed = await self.dependencies.sessionStore.loadToken() {
                        activeToken = refreshed
                    }
                } catch {
                    self.phase = .failed(.server(error.localizedDescription))
                    self.statusMessage = error.localizedDescription
                    return
                }
            }
        }
    }

    private func accept(_ sample: MetricsSample) async {
        latestSample = sample
        lastSampleReceivedAt = dependencies.clock.now()
        publishMenuBarIfNeeded(sample)

        do {
            try await dependencies.historyStore.append(sample)
            let retention = dependencies.preferences.historyRetentionHours
            let cutoff = dependencies.clock.now().addingTimeInterval(-retention * 3_600)
            try await dependencies.historyStore.prune(olderThan: cutoff)
            if isDetailPresented {
                await refreshHistory(force: false)
            }
        } catch {
            dependencies.logger.error(
                "History write failed: \(error.localizedDescription)",
                category: .history
            )
        }
    }

    private func refreshHistory(force: Bool = true) async {
        let now = dependencies.clock.now()
        if !force, let lastHistoryPublish, now.timeIntervalSince(lastHistoryPublish) < 1 {
            return
        }
        lastHistoryPublish = now

        let since = now.addingTimeInterval(-selectedHistoryRange.duration)
        do {
            let samples = try await dependencies.historyStore.recent(since: since)
            history = HistoryDownsampler.downsample(
                samples,
                range: selectedHistoryRange,
                now: now
            )
        } catch {
            dependencies.logger.error(
                "History read failed: \(error.localizedDescription)",
                category: .history
            )
        }
    }

    private func publishMenuBarIfNeeded(_ sample: MetricsSample) {
        let gpu = Int(sample.gpuUtilizationPercent.rounded())
        let ram = Int(sample.memoryUtilizationPercent.rounded())
        let key = "\(ram)|\(gpu)"
        let now = dependencies.clock.now()
        if let lastPublishedMenuBarKey, lastPublishedMenuBarKey == key,
            let lastMenuBarPublish, now.timeIntervalSince(lastMenuBarPublish) < 1
        {
            return
        }
        if let lastMenuBarPublish, now.timeIntervalSince(lastMenuBarPublish) < 1,
            lastPublishedMenuBarKey != nil
        {
            return
        }
        lastPublishedMenuBarKey = key
        lastMenuBarPublish = now
        menuBarTitle = "RAM \(ram)%  GPU \(gpu)%"
    }

    private func handleFailure(_ failure: ConnectionFailure) async {
        password = ""
        switch failure {
        case .unauthorized, .loginFailed:
            await dependencies.sessionStore.clear()
            phase = .signedOut
        default:
            phase = .failed(failure)
        }
        statusMessage = failure.userMessage
        menuBarTitle = "DGXPulse"
        dependencies.logger.error(failure.userMessage, category: .app)
    }

    private func installWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSystemWake()
            }
        }
    }

    private func startStaleWatch() {
        staleWatchTask?.cancel()
        staleWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.markStaleIfNeeded()
            }
        }
    }

    private func markStaleIfNeeded() {
        guard phase == .streaming else { return }
        guard let receivedAt = lastSampleReceivedAt else { return }
        let age = dependencies.clock.now().timeIntervalSince(receivedAt)
        guard age > DashboardPorts.sampleStaleInterval else { return }

        statusMessage = "No live telemetry — reconnecting…"
        menuBarTitle = "DGXPulse"
        latestSample = nil
        lastSampleReceivedAt = nil
        dependencies.preferences.lastKnownBaseURL = nil
        dependencies.logger.error(
            "Telemetry went stale after \(Int(age))s; rediscovering",
            category: .telemetry
        )
        retry()
    }

    private func clearStalePresentation(status: String) {
        latestSample = nil
        lastSampleReceivedAt = nil
        lastPublishedMenuBarKey = nil
        menuBarTitle = "DGXPulse"
        statusMessage = status
    }
}
