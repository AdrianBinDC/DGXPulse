import Foundation

struct DashboardAuthClient: Sendable {
    private let http: any HTTPClient
    private let logger: any Logging

    init(http: any HTTPClient, logger: any Logging) {
        self.http = http
        self.logger = logger
    }

    func login(baseURL: URL, username: String, password: String) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "api/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": username,
            "password": password,
        ])

        logger.info("Signing in to dashboard", category: .auth)

        let (data, response) = try await http.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ConnectionFailure.server("Invalid login response.")
        }

        if httpResponse.statusCode == 401 {
            throw ConnectionFailure.loginFailed("Login failed. Check your credentials.")
        }

        guard httpResponse.statusCode == 200 else {
            if let errorBody = try? JSONDecoder().decode(DashboardErrorResponse.self, from: data) {
                throw ConnectionFailure.loginFailed(errorBody.error)
            }
            throw ConnectionFailure.loginFailed("Login failed (HTTP \(httpResponse.statusCode)).")
        }

        let login = try JSONDecoder().decode(LoginResponse.self, from: data)
        logger.info("Login succeeded", category: .auth)
        return login.token
    }
}
