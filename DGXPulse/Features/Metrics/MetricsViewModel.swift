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

    var username: String = ""
    var password: String = ""
    var overrideBaseURLString: String = ""
    var selectedHistoryRange: HistoryRange = .fiveMinutes

    private let dependencies: AppDependencies
    private var streamTask: Task<Void, Never>?
    private var lastPublishedMenuBarKey: String?
    private var lastMenuBarPublish: Date?
    private var reconnectAttempt = 0

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
            await startStreaming(with: token)
        } else {
            phase = .signedOut
            statusMessage = "Sign in to stream metrics."
        }
    }

    func signIn() {
        Task { await performSignIn() }
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
        retry()
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
            var knownBase = baseURL

            while !Task.isCancelled {
                do {
                    self.phase = .resolvingEndpoint
                    self.statusMessage = "Looking for DGX Dashboard…"
                    let resolved: URL
                    if let knownBase {
                        resolved = knownBase
                    } else {
                        resolved = try await self.dependencies.endpointResolver.resolve()
                    }
                    knownBase = resolved
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
                            self.dependencies.logger.info("Telemetry stream connected", category: .telemetry)
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
                                // Keep last good sample; continue stream.
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
                    knownBase = nil
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
        publishMenuBarIfNeeded(sample)

        do {
            try await dependencies.historyStore.append(sample)
            let retention = dependencies.preferences.historyRetentionHours
            let cutoff = dependencies.clock.now().addingTimeInterval(-retention * 3_600)
            try await dependencies.historyStore.prune(olderThan: cutoff)
            if isDetailPresented {
                await refreshHistory()
            }
        } catch {
            dependencies.logger.error("History write failed: \(error.localizedDescription)", category: .history)
        }
    }

    private func refreshHistory() async {
        let since = dependencies.clock.now().addingTimeInterval(-selectedHistoryRange.duration)
        do {
            let samples = try await dependencies.historyStore.recent(since: since)
            history = HistoryDownsampler.downsample(
                samples,
                maxPoints: selectedHistoryRange.maxChartPoints
            )
        } catch {
            dependencies.logger.error("History read failed: \(error.localizedDescription)", category: .history)
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
            // Throttle to ~1 Hz even when values change.
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
}
