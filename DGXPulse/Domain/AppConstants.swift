import Foundation

nonisolated enum DashboardPorts {
    /// Documented remote / manual-tunnel dashboard port on the Spark.
    static let `default` = NVIDIASyncKnownPorts.remoteDashboard
    static let jupyterDefault = 11_002
    /// Max silence on the telemetry stream before forcing reconnect.
    static let telemetryIdleTimeout: Duration = .seconds(30)
    /// Treat menu-bar samples older than this as stale after sleep/disconnect.
    static let sampleStaleInterval: TimeInterval = 45
    /// Give NVIDIA Sync time to come back after Mac wake before rediscovering.
    static let postWakeSettleDelay: Duration = .seconds(6)
    /// Poll window while Sync reconnects / opens the dashboard tunnel after sleep.
    static let syncTunnelPollAttempts = 12
    static let syncTunnelPollInterval: Duration = .seconds(2)
    /// Pause after issuing `nvsync connect --detach` before the first status poll.
    static let syncConnectSettleDelay: Duration = .seconds(3)
    /// Pause after `nvsync open` before trusting the mapped local port.
    static let syncOpenSettleDelay: Duration = .milliseconds(750)
    /// Sync marks tunnels OPENED before HTTP answers; probe a few times.
    static let dashboardReadinessAttempts = 8
    static let dashboardReadinessInterval: Duration = .milliseconds(500)
}

nonisolated enum AppPreferenceKey {
    static let dashboardBaseURL = "DGXPulse.DashboardBaseURL"
    static let lastKnownBaseURL = "DGXPulse.LastKnownBaseURL"
    static let username = "DGXPulse.DashboardUsername"
    static let historyRetentionHours = "DGXPulse.HistoryRetentionHours"
    static let historyRange = "DGXPulse.HistoryRange"
}

nonisolated enum AppWindowID {
    static let dashboard = "dashboard"
    static let settings = "settings"
    static let diagnostics = "diagnostics"
}
