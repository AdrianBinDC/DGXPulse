import Foundation
import SwiftData

@MainActor
struct AppDependencies {
    var httpClient: any HTTPClient
    var endpointResolver: any EndpointResolving
    var sessionStore: any AuthSessionStoring
    var metricsSource: any MetricsSource
    var historyStore: any MetricsHistoryStoring
    var authClient: DashboardAuthClient
    var logger: any Logging
    var diagnostics: DiagnosticsRingBuffer
    var clock: any Clock
    var sleeper: any Sleeping
    var preferences: PreferenceStore
    var modelContainer: ModelContainer

    static func live(modelContainer: ModelContainer) -> AppDependencies {
        let http = URLSessionHTTPClient()
        let ring = DiagnosticsRingBuffer()
        let logger: any Logging = MultiplexLogger(primary: OSLogLogger(), ring: ring)
        let preferences = PreferenceStore()
        let history = SwiftDataMetricsHistoryStore(
            modelContainer: modelContainer,
            logger: logger
        )

        let syncTunnels = NVIDIASyncCLIClient(logger: logger)
        return AppDependencies(
            httpClient: http,
            endpointResolver: LocalDashboardEndpointResolver(
                http: http,
                preferences: preferences,
                logger: logger,
                syncTunnels: syncTunnels
            ),
            sessionStore: KeychainSessionStore(),
            metricsSource: DashboardSSEMetricsSource(http: http, logger: logger, clock: SystemClock()),
            historyStore: history,
            authClient: DashboardAuthClient(http: http, logger: logger),
            logger: logger,
            diagnostics: ring,
            clock: SystemClock(),
            sleeper: SystemSleeper(),
            preferences: preferences,
            modelContainer: modelContainer
        )
    }

    static func mock(
        modelContainer: ModelContainer? = nil,
        metricsSource: any MetricsSource = StaticMetricsSource(events: []),
        sessionStore: any AuthSessionStoring = InMemorySessionStore(),
        endpointResolver: any EndpointResolving = StaticEndpointResolver(
            url: URL(string: "http://127.0.0.1:11000") ?? URL(fileURLWithPath: "/")
        ),
        historyStore: (any MetricsHistoryStoring)? = nil
    ) -> AppDependencies {
        let container: ModelContainer
        if let modelContainer {
            container = modelContainer
        } else {
            do {
                container = try ModelContainer(
                    for: TelemetrySampleRecord.self,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
                )
            } catch {
                fatalError("Unable to create in-memory ModelContainer: \(error)")
            }
        }
        let ring = DiagnosticsRingBuffer()
        let logger = MultiplexLogger(primary: OSLogLogger(subsystem: "DGXPulseTests"), ring: ring)
        let http = URLSessionHTTPClient()
        let defaults = UserDefaults(suiteName: "DGXPulseTests") ?? .standard
        let preferences = PreferenceStore(defaults: defaults)

        return AppDependencies(
            httpClient: http,
            endpointResolver: endpointResolver,
            sessionStore: sessionStore,
            metricsSource: metricsSource,
            historyStore: historyStore ?? InMemoryMetricsHistoryStore(),
            authClient: DashboardAuthClient(http: http, logger: logger),
            logger: logger,
            diagnostics: ring,
            clock: SystemClock(),
            sleeper: ImmediateSleeper(),
            preferences: preferences,
            modelContainer: container
        )
    }
}

struct ImmediateSleeper: Sleeping {
    func sleep(for duration: Duration) async throws {
        // Avoid a hot reconnect spin in tests when delays are mocked out.
        try await Task.sleep(for: .milliseconds(5))
    }
}

struct StaticEndpointResolver: EndpointResolving {
    let url: URL
    func resolve() async throws -> URL { url }
    func rememberSuccessfulEndpoint(_ url: URL) async {}
}

actor InMemorySessionStore: AuthSessionStoring {
    private var username: String?
    private var token: String?

    func loadUsername() async -> String? { username }
    func loadToken() async -> String? { token }

    func save(username: String, token: String) async throws {
        self.username = username
        self.token = token
    }

    func clear() async {
        username = nil
        token = nil
    }
}

struct StaticMetricsSource: MetricsSource {
    let events: [MetricsEvent]
    var hangAfterEvents: Bool = true

    func events(token: String, baseURL: URL) -> AsyncStream<MetricsEvent> {
        AsyncStream { continuation in
            let task = Task {
                for event in events {
                    continuation.yield(event)
                }
                if hangAfterEvents {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(60))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
