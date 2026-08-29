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

        let loginURL = request.url?.absoluteString ?? "api/login"
        logger.info("Signing in to dashboard POST \(loginURL)", category: .auth)

        let (data, response) = try await http.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Login returned a non-HTTP response", category: .auth)
            throw ConnectionFailure.server("Invalid login response.")
        }

        logger.info("Login HTTP \(httpResponse.statusCode)", category: .auth)

        if httpResponse.statusCode == 401 {
            throw ConnectionFailure.loginFailed("Login failed. Check your credentials.")
        }

        guard httpResponse.statusCode == 200 else {
            logger.error("Login failed \(JSONDiagnostics.summarize(data))", category: .auth)
            if let errorBody = try? JSONDecoder().decode(DashboardErrorResponse.self, from: data) {
                throw ConnectionFailure.loginFailed(errorBody.error)
            }
            throw ConnectionFailure.loginFailed("Login failed (HTTP \(httpResponse.statusCode)).")
        }

        do {
            let login = try JSONDecoder().decode(LoginResponse.self, from: data)
            logger.info("Login succeeded", category: .auth)
            return login.token
        } catch {
            logger.error(
                "Login JSON decode failed: \(JSONDiagnostics.describe(error)) \(JSONDiagnostics.summarize(data))",
                category: .auth
            )
            throw ConnectionFailure.server("Invalid login response.")
        }
    }
}
