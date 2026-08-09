import Foundation

final class LocalDashboardEndpointResolver: EndpointResolving, @unchecked Sendable {
    private let http: any HTTPClient
    private let preferences: PreferenceStore
    private let logger: any Logging
    private let probePorts: [Int]

    init(
        http: any HTTPClient,
        preferences: PreferenceStore = PreferenceStore(),
        logger: any Logging,
        probePorts: [Int] = DashboardPorts.discoveryCandidates
    ) {
        self.http = http
        self.preferences = preferences
        self.logger = logger
        self.probePorts = probePorts
    }

    func resolve() async throws -> URL {
        var candidates: [URL] = []
        if let override = preferences.overrideBaseURL {
            candidates.append(override)
        }
        if let lastKnown = preferences.lastKnownBaseURL {
            candidates.append(lastKnown)
        }
        if let defaultURL = URL(string: "http://127.0.0.1:\(DashboardPorts.default)") {
            candidates.append(defaultURL)
        }
        for port in probePorts {
            if let url = URL(string: "http://127.0.0.1:\(port)") {
                candidates.append(url)
            }
        }

        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0.absoluteString).inserted }

        for candidate in unique {
            if await isDashboard(at: candidate) {
                logger.info("Resolved dashboard at \(candidate.absoluteString)", category: .endpoint)
                preferences.lastKnownBaseURL = candidate
                return candidate
            }
        }

        logger.error("No local DGX Dashboard found", category: .endpoint)
        throw ConnectionFailure.tunnelUnavailable
    }

    func rememberSuccessfulEndpoint(_ url: URL) async {
        preferences.lastKnownBaseURL = url
        logger.info("Remembered dashboard endpoint \(url.absoluteString)", category: .endpoint)
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
