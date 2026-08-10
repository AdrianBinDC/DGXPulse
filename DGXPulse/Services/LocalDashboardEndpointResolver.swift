import Foundation

/// Resolves the local HTTP base URL for the DGX Dashboard.
///
/// Discovery order:
/// 1. Explicit user override
/// 2. NVIDIA Sync CLI (`connect` / `status` / `open`) — authoritative local port for remote `11000`
/// 3. Last working URL (verified still serving the dashboard)
/// 4. Manual-tunnel default `http://127.0.0.1:11000` — only when Sync is not configured
final class LocalDashboardEndpointResolver: EndpointResolving, @unchecked Sendable {
    private let http: any HTTPClient
    private let preferences: PreferenceStore
    private let logger: any Logging
    private let syncTunnels: any NVIDIASyncTunnelProviding
    private let manualTunnelPorts: [Int]
    private let readinessAttempts: Int
    private let readinessInterval: Duration

    init(
        http: any HTTPClient,
        preferences: PreferenceStore = PreferenceStore(),
        logger: any Logging,
        syncTunnels: any NVIDIASyncTunnelProviding,
        manualTunnelPorts: [Int] = [DashboardPorts.default],
        readinessAttempts: Int = DashboardPorts.dashboardReadinessAttempts,
        readinessInterval: Duration = DashboardPorts.dashboardReadinessInterval
    ) {
        self.http = http
        self.preferences = preferences
        self.logger = logger
        self.syncTunnels = syncTunnels
        self.manualTunnelPorts = manualTunnelPorts
        self.readinessAttempts = max(1, readinessAttempts)
        self.readinessInterval = readinessInterval
    }

    func resolve() async throws -> URL {
        var candidates: [URL] = []

        if let override = preferences.overrideBaseURL {
            candidates.append(override)
        }

        let discovery = await syncTunnels.discover()
        let syncURLKeys = Set(discovery.urls.map(\.absoluteString))
        candidates.append(contentsOf: discovery.urls)

        if let lastKnown = preferences.lastKnownBaseURL {
            candidates.append(lastKnown)
        }

        // Manual `11000` is for users who tunnel without NVIDIA Sync. When Sync
        // aliases exist, probing dead `:11000` after sleep only floods refused-connection logs.
        if !discovery.hasConfiguredAliases {
            for port in manualTunnelPorts {
                if let url = URL(string: "http://127.0.0.1:\(port)") {
                    candidates.append(url)
                }
            }
        } else if discovery.urls.isEmpty {
            logger.info(
                "NVIDIA Sync is configured but no dashboard tunnel is open yet",
                category: .endpoint
            )
        }

        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0.absoluteString).inserted }

        for candidate in unique {
            let attempts = syncURLKeys.contains(candidate.absoluteString) ? readinessAttempts : 1
            if await waitForDashboard(at: candidate, attempts: attempts) {
                logger.info("Resolved dashboard at \(candidate.absoluteString)", category: .endpoint)
                preferences.lastKnownBaseURL = candidate
                return candidate
            }

            if candidate == preferences.lastKnownBaseURL {
                logger.info(
                    "Forgetting stale dashboard endpoint \(candidate.absoluteString)",
                    category: .endpoint
                )
                preferences.lastKnownBaseURL = nil
            }
        }

        logger.error("No local DGX Dashboard found", category: .endpoint)
        throw ConnectionFailure.tunnelUnavailable
    }

    func rememberSuccessfulEndpoint(_ url: URL) async {
        preferences.lastKnownBaseURL = url
        logger.info("Remembered dashboard endpoint \(url.absoluteString)", category: .endpoint)
    }

    private func waitForDashboard(at baseURL: URL, attempts: Int) async -> Bool {
        for attempt in 0..<attempts {
            if await isDashboard(at: baseURL) {
                return true
            }
            let isLast = attempt == attempts - 1
            if !isLast {
                logger.info(
                    "Dashboard not ready at \(baseURL.absoluteString); waiting…",
                    category: .endpoint
                )
                try? await Task.sleep(for: readinessInterval)
            }
        }
        return false
    }

    private func isDashboard(at baseURL: URL) async -> Bool {
        var request = URLRequest(url: baseURL)
        request.timeoutInterval = 1.5
        request.httpMethod = "GET"

        do {
            let (data, response) = try await http.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                (200..<400).contains(httpResponse.statusCode)
            else { return false }
            guard let body = String(data: data, encoding: .utf8) else { return false }
            return body.localizedCaseInsensitiveContains("DGX Dashboard")
        } catch {
            return false
        }
    }
}
