import Foundation

enum DashboardPorts {
    /// Documented remote / manual-tunnel dashboard port on the Spark.
    static let `default` = NVIDIASyncKnownPorts.remoteDashboard
    static let jupyterDefault = 11_002
    /// Max silence on the telemetry stream before forcing reconnect.
    static let telemetryIdleTimeout: Duration = .seconds(30)
    /// Treat menu-bar samples older than this as stale after sleep/disconnect.
    static let sampleStaleInterval: TimeInterval = 45
}

enum AppPreferenceKey {
    static let dashboardBaseURL = "DGXPulse.DashboardBaseURL"
    static let lastKnownBaseURL = "DGXPulse.LastKnownBaseURL"
    static let username = "DGXPulse.DashboardUsername"
    static let historyRetentionHours = "DGXPulse.HistoryRetentionHours"
    static let historyRange = "DGXPulse.HistoryRange"
}
