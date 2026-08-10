import Foundation

enum ReconnectBackoff: Sendable {
    static func delay(
        forAttempt attempt: Int, base: Duration = .milliseconds(500), cap: Duration = .seconds(30)
    )
        -> Duration
    {
        let clampedAttempt = max(0, min(attempt, 16))
        let multiplier = pow(2.0, Double(clampedAttempt))
        let baseNanos =
            Double(base.components.seconds) * 1_000_000_000
            + Double(base.components.attoseconds) / 1_000_000_000
        let uncapped = baseNanos * multiplier
        let capNanos =
            Double(cap.components.seconds) * 1_000_000_000
            + Double(cap.components.attoseconds) / 1_000_000_000
        let nanos = min(uncapped, capNanos)
        return .nanoseconds(Int64(nanos))
    }
}

enum TokenRedactor {
    static func redact(_ token: String) -> String {
        guard token.count > 4 else { return "…****" }
        return "…" + token.suffix(4)
    }
}
