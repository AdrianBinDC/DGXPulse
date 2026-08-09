import Foundation

enum DashboardPorts {
    static let `default` = 11_000
    static let jupyterDefault = 11_002
    static let discoveryCandidates: [Int] = [11_000, 58_170, 11_001, 11_002]
}

enum AppPreferenceKey {
    static let dashboardBaseURL = "DGXPulse.DashboardBaseURL"
    static let lastKnownBaseURL = "DGXPulse.LastKnownBaseURL"
    static let username = "DGXPulse.DashboardUsername"
    static let historyRetentionHours = "DGXPulse.HistoryRetentionHours"
}
