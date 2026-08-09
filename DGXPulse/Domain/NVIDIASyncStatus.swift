import Foundation

/// Remote DGX Dashboard listen port on the Spark (documented NVIDIA default).
enum NVIDIASyncKnownPorts {
    static let remoteDashboard = 11_000
}

/// One forwarded port from `nvsync status`.
struct NVIDIASyncPortStatus: Decodable, Equatable, Sendable {
    var localPort: Int
    var status: String
    var error: String

    enum CodingKeys: String, CodingKey {
        case localPort = "local_port"
        case status
        case error
    }

    var isOpened: Bool {
        status.caseInsensitiveCompare("OPENED") == .orderedSame
    }
}

/// Parsed output of `nvsync status <alias>`.
///
/// NVIDIA Sync tunnels remote application ports to localhost. The remote dashboard
/// port is always `11000`, but the **local** bind may differ when `11000` is busy
/// (common after sleep / reconnect). `local_port` is the authoritative value.
struct NVIDIASyncStatus: Decodable, Equatable, Sendable {
    var connectionStatus: String
    var error: String
    var dashboardInstalled: Bool
    var ports: [String: NVIDIASyncPortStatus]

    enum CodingKeys: String, CodingKey {
        case connectionStatus = "status"
        case error
        case dashboardInstalled = "dashboard_installed"
        case ports
    }

    var isRunning: Bool {
        connectionStatus.caseInsensitiveCompare("RUNNING") == .orderedSame
    }

    /// Localhost port currently forwarding the remote DGX Dashboard, if open.
    var dashboardLocalPort: Int? {
        let key = String(NVIDIASyncKnownPorts.remoteDashboard)
        guard let port = ports[key], port.isOpened else { return nil }
        return port.localPort
    }
}

enum NVIDIASyncSSHConfigParser {
    /// Extracts `Host` aliases from NVIDIA Sync's generated ssh_config.
    static func aliases(from contents: String) -> [String] {
        var aliases: [String] = []
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("host ") else { continue }
            let name = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != "*", !name.contains(" "), !name.hasPrefix("!") else {
                continue
            }
            if !aliases.contains(String(name)) {
                aliases.append(String(name))
            }
        }
        return aliases
    }
}

struct NVIDIASyncStateStoreDevice: Decodable {
    var alias: String?
}

struct NVIDIASyncStateStoreRoot: Decodable {
    var devices: [NVIDIASyncStateStoreDevice]?
}

enum NVIDIASyncStateStoreParser {
    /// Reads device aliases from Sync's UI state store (no secrets).
    static func aliases(fromJSON data: Data) -> [String] {
        guard let root = try? JSONDecoder().decode(NVIDIASyncStateStoreRoot.self, from: data) else {
            return []
        }
        return (root.devices ?? [])
            .compactMap { device in
                let alias = device.alias?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let alias, !alias.isEmpty else { return nil }
                return alias
            }
    }
}
