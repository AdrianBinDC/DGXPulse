import Foundation

enum ConnectionFailure: Error, Equatable, Sendable {
    case tunnelUnavailable
    case unauthorized
    case unreachable(String)
    case loginFailed(String)
    case malformedTelemetry
    case cancelled
    case server(String)

    var userMessage: String {
        switch self {
        case .tunnelUnavailable:
            return "Connect NVIDIA Sync (or open a dashboard tunnel), then try again."
        case .unauthorized:
            return "Session expired. Sign in again."
        case .unreachable(let endpoint):
            return "Can't reach the dashboard at \(endpoint)."
        case .loginFailed(let detail):
            return detail.isEmpty ? "Login failed. Check your credentials." : detail
        case .malformedTelemetry:
            return "Received unexpected telemetry data."
        case .cancelled:
            return "Cancelled."
        case .server(let message):
            return message
        }
    }
}

enum ConnectionPhase: Equatable, Sendable {
    case signedOut
    case resolvingEndpoint
    case authenticating
    case streaming
    case reconnecting(ConnectionFailure)
    case failed(ConnectionFailure)
}
