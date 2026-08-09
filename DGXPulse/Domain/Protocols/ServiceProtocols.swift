import Foundation

protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse)
}

protocol EndpointResolving: Sendable {
    func resolve() async throws -> URL
    func rememberSuccessfulEndpoint(_ url: URL) async
}

protocol AuthSessionStoring: Sendable {
    func loadUsername() async -> String?
    func loadToken() async -> String?
    func save(username: String, token: String) async throws
    func clear() async
}

enum MetricsEvent: Sendable {
    case connected
    case sample(MetricsSample)
    case failure(ConnectionFailure)
}

protocol MetricsSource: Sendable {
    func events(token: String, baseURL: URL) -> AsyncStream<MetricsEvent>
}

protocol MetricsHistoryStoring: Sendable {
    func append(_ sample: MetricsSample) async throws
    func recent(since date: Date) async throws -> [MetricsSample]
    func prune(olderThan date: Date) async throws
}

protocol Logging: Sendable {
    func debug(_ message: String, category: LogCategory)
    func info(_ message: String, category: LogCategory)
    func error(_ message: String, category: LogCategory)
}

enum LogCategory: String, Sendable {
    case app = "App"
    case endpoint = "Endpoint"
    case auth = "Auth"
    case telemetry = "Telemetry"
    case ui = "UI"
    case history = "History"
}

protocol Clock: Sendable {
    func now() -> Date
}

protocol Sleeping: Sendable {
    func sleep(for duration: Duration) async throws
}
