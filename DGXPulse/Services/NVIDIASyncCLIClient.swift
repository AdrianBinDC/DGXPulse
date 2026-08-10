import Darwin
import Foundation

/// Talks to the NVIDIA Sync CLI (`nvsync status` / `connect` / `open`).
///
/// Sync is the source of truth for ephemeral local ports. After Mac sleep the
/// detached `nvsync connect` process is often gone (`NOT_RUNNING`); DGXPulse
/// restarts it, opens remote dashboard port `11000`, then reads `local_port`.
/// Concurrent callers share one in-flight discovery so wake + stream retry
/// do not race `connect` / `open`.
final class NVIDIASyncCLIClient: NVIDIASyncTunnelProviding, @unchecked Sendable {
    private let logger: any Logging
    private let executableURL: URL?
    private let sshConfigURL: URL
    private let stateStoreURL: URL
    private let runCommand: @Sendable (URL, [String]) async -> CommandResult
    private let connectSettleDelay: Duration
    private let openSettleDelay: Duration
    private let pollInterval: Duration
    private let pollAttempts: Int

    private let discoveryLock = NSLock()
    private var inFlightDiscovery: Task<NVIDIASyncTunnelDiscovery, Never>?

    init(
        logger: any Logging,
        executableURL: URL? = NVIDIASyncCLILocator.executableURL(),
        sshConfigURL: URL = NVIDIASyncPaths.sshConfigURL,
        stateStoreURL: URL = NVIDIASyncPaths.stateStoreURL,
        connectSettleDelay: Duration = DashboardPorts.syncConnectSettleDelay,
        openSettleDelay: Duration = DashboardPorts.syncOpenSettleDelay,
        pollInterval: Duration = DashboardPorts.syncTunnelPollInterval,
        pollAttempts: Int = DashboardPorts.syncTunnelPollAttempts,
        runCommand: @escaping @Sendable (URL, [String]) async -> CommandResult = ProcessRunner.run
    ) {
        self.logger = logger
        self.executableURL = executableURL
        self.sshConfigURL = sshConfigURL
        self.stateStoreURL = stateStoreURL
        self.connectSettleDelay = connectSettleDelay
        self.openSettleDelay = openSettleDelay
        self.pollInterval = pollInterval
        self.pollAttempts = pollAttempts
        self.runCommand = runCommand
    }

    func discover() async -> NVIDIASyncTunnelDiscovery {
        let task: Task<NVIDIASyncTunnelDiscovery, Never>
        discoveryLock.lock()
        if let inFlightDiscovery {
            task = inFlightDiscovery
            discoveryLock.unlock()
            return await task.value
        }
        task = Task { await self.performDiscover() }
        inFlightDiscovery = task
        discoveryLock.unlock()

        let result = await task.value
        discoveryLock.lock()
        if inFlightDiscovery == task {
            inFlightDiscovery = nil
        }
        discoveryLock.unlock()
        return result
    }

    private func performDiscover() async -> NVIDIASyncTunnelDiscovery {
        let aliases = discoveredAliases()
        guard let executableURL else {
            logger.info(
                "NVIDIA Sync CLI not found; skipping Sync tunnel discovery",
                category: .endpoint
            )
            return NVIDIASyncTunnelDiscovery(hasConfiguredAliases: !aliases.isEmpty, urls: [])
        }

        guard !aliases.isEmpty else {
            return NVIDIASyncTunnelDiscovery(hasConfiguredAliases: false, urls: [])
        }

        var urls: [URL] = []
        for alias in aliases {
            if let url = await dashboardURL(for: alias, executableURL: executableURL) {
                urls.append(url)
            }
        }
        return NVIDIASyncTunnelDiscovery(hasConfiguredAliases: true, urls: urls)
    }

    private func dashboardURL(for alias: String, executableURL: URL) async -> URL? {
        var didAttemptConnect = false
        var didAttemptOpen = false

        for attempt in 0..<pollAttempts {
            var status = await fetchStatus(alias: alias, executableURL: executableURL)

            // After sleep, Sync's detached connect process is usually gone.
            if !didAttemptConnect, status?.isRunning != true {
                didAttemptConnect = true
                logger.info(
                    "Sync alias \(alias) is not running; starting detached connect",
                    category: .endpoint
                )
                let connect = await runCommand(executableURL, ["connect", "--detach", alias])
                if connect.exitCode != 0 {
                    let detail = String(data: connect.stderr, encoding: .utf8) ?? ""
                    logger.error(
                        "nvsync connect --detach \(alias) failed (exit \(connect.exitCode)) \(detail)",
                        category: .endpoint
                    )
                }
                try? await Task.sleep(for: connectSettleDelay)
                status = await fetchStatus(alias: alias, executableURL: executableURL)
            }

            if status?.isRunning == true, status?.dashboardLocalPort == nil, !didAttemptOpen {
                didAttemptOpen = true
                let remote = NVIDIASyncKnownPorts.remoteDashboard
                logger.info(
                    "Sync alias \(alias) connected without dashboard tunnel; opening remote \(remote)",
                    category: .endpoint
                )
                _ = await runCommand(
                    executableURL,
                    ["open", alias, String(NVIDIASyncKnownPorts.remoteDashboard)]
                )
                try? await Task.sleep(for: openSettleDelay)
                status = await fetchStatus(alias: alias, executableURL: executableURL)
            }

            if let status, status.isRunning, let localPort = status.dashboardLocalPort {
                let remote = NVIDIASyncKnownPorts.remoteDashboard
                logger.info(
                    "Sync alias \(alias): remote \(remote) → local \(localPort)",
                    category: .endpoint
                )
                return URL(string: "http://127.0.0.1:\(localPort)")
            }

            let connection = status?.connectionStatus ?? "unavailable"
            let isLastAttempt = attempt == pollAttempts - 1
            if isLastAttempt {
                logger.info(
                    "Sync alias \(alias) has no open dashboard tunnel (status=\(connection))",
                    category: .endpoint
                )
                return nil
            }

            logger.info(
                "Sync alias \(alias) not ready (status=\(connection)); retrying…",
                category: .endpoint
            )
            try? await Task.sleep(for: pollInterval)
        }

        return nil
    }

    private func fetchStatus(alias: String, executableURL: URL) async -> NVIDIASyncStatus? {
        let result = await runCommand(executableURL, ["status", alias])
        guard result.exitCode == 0 else {
            logger.error(
                "nvsync status \(alias) failed (exit \(result.exitCode))",
                category: .endpoint
            )
            return nil
        }

        do {
            return try JSONDecoder().decode(NVIDIASyncStatus.self, from: result.stdout)
        } catch {
            logger.error(
                "Failed to decode nvsync status for \(alias): \(error.localizedDescription)",
                category: .endpoint
            )
            return nil
        }
    }

    private func discoveredAliases() -> [String] {
        var aliases: [String] = []

        do {
            let data = try Data(contentsOf: stateStoreURL)
            aliases.append(contentsOf: NVIDIASyncStateStoreParser.aliases(fromJSON: data))
        } catch {
            logger.info(
                "Could not read Sync state store at \(stateStoreURL.path): \(error.localizedDescription)",
                category: .endpoint
            )
        }

        do {
            let contents = try String(contentsOf: sshConfigURL, encoding: .utf8)
            for alias in NVIDIASyncSSHConfigParser.aliases(from: contents) where !aliases.contains(alias) {
                aliases.append(alias)
            }
        } catch {
            logger.info(
                "Could not read Sync ssh_config at \(sshConfigURL.path): \(error.localizedDescription)",
                category: .endpoint
            )
        }

        if aliases.isEmpty {
            logger.info(
                "No NVIDIA Sync device aliases found under \(NVIDIASyncPaths.applicationSupportSync.path)",
                category: .endpoint
            )
        }

        return aliases
    }
}

enum NVIDIASyncPaths {
    /// Real user home (not an App Sandbox container). Prefer passwd over
    /// `FileManager.homeDirectoryForCurrentUser`, which is containerized when sandboxed.
    static var userHomeURL: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var applicationSupportSync: URL {
        userHomeURL
            .appendingPathComponent("Library/Application Support/NVIDIA/Sync", isDirectory: true)
    }

    static var sshConfigURL: URL {
        applicationSupportSync.appendingPathComponent("config/ssh_config", isDirectory: false)
    }

    static var stateStoreURL: URL {
        applicationSupportSync.appendingPathComponent("config/state-store.json", isDirectory: false)
    }
}

enum NVIDIASyncCLILocator {
    static func executableURL(
        fileManager: FileManager = .default,
        architecture: String = NVIDIASyncCLILocator.currentArchitecture
    ) -> URL? {
        let binaryName = architecture == "arm64" ? "nvsync-arm64" : "nvsync-amd64"
        let bundled = URL(fileURLWithPath: "/Applications/NVIDIA Sync.app/Contents/Resources/bin")
            .appendingPathComponent(binaryName, isDirectory: false)
        if fileManager.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        // Optional Homebrew / PATH install.
        let pathResult = ProcessRunner.runSync(
            URL(fileURLWithPath: "/usr/bin/which"),
            arguments: ["nvsync"]
        )
        if pathResult.exitCode == 0,
            let path = String(data: pathResult.stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty,
            fileManager.isExecutableFile(atPath: path)
        {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    static var currentArchitecture: String {
        #if arch(arm64)
            return "arm64"
        #else
            return "x86_64"
        #endif
    }
}

struct CommandResult: Sendable {
    var exitCode: Int32
    var stdout: Data
    var stderr: Data
}

nonisolated enum ProcessRunner {
    nonisolated static func run(_ executable: URL, _ arguments: [String]) async -> CommandResult {
        await Task.detached(priority: .utility) {
            runSync(executable, arguments: arguments)
        }
        .value
    }

    nonisolated static func runSync(_ executable: URL, arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CommandResult(
                exitCode: 127,
                stdout: Data(),
                stderr: Data(error.localizedDescription.utf8)
            )
        }

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
            stderr: stderr.fileHandleForReading.readDataToEndOfFile()
        )
    }
}

struct StaticNVIDIASyncTunnelProvider: NVIDIASyncTunnelProviding {
    let discovery: NVIDIASyncTunnelDiscovery

    init(urls: [URL], hasConfiguredAliases: Bool = false) {
        self.discovery = NVIDIASyncTunnelDiscovery(
            hasConfiguredAliases: hasConfiguredAliases || !urls.isEmpty,
            urls: urls
        )
    }

    func discover() async -> NVIDIASyncTunnelDiscovery { discovery }
}
