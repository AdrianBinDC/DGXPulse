import Foundation

struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await session.bytes(for: request)
    }
}
