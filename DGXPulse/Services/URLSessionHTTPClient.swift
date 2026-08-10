import Foundation

struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            // Drop half-open SSE sockets after sleep / Sync port changes.
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60 * 60 * 24
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await session.bytes(for: request)
    }
}
