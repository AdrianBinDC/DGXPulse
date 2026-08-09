import Darwin
import Foundation

/// Talks to the NVIDIA Sync CLI (`nvsync status` / `nvsync open`).
///
/// Sync is the source of truth for ephemeral local ports. We do **not** scrape
/// `lsof` or trust Sync's UI `openPorts` list (that list tracks remote ports).
final class NVIDIASyncCLIClient: NVIDIASyncTunnelProviding, @unchecked Sendable {
    private let logger: any Logging
    private let executableURL: URL?
    private let sshConfigURL: URL
    private let stateStoreURL: URL
    private let runCommand: @Sendable (URL, [String]) async -> CommandResult

    init(
        logger: any Logging,
        executableURL: URL? = NVIDIASyncCLILocator.executableURL(),
        sshConfigURL: URL = NVIDIASyncPaths.sshConfigURL,
        stateStoreURL: URL = NVIDIASyncPaths.stateStoreURL,
        runCommand: @escaping @Sendable (URL, [String]) async -> CommandResult = ProcessRunner.run
    ) {
        self.logger = logger
        self.executableURL = executableURL
        self.sshConfigURL = sshConfigURL
        self.stateStoreURL = stateStoreURL
        self.runCommand = runCommand
    }

    func dashboardBaseURLs() async -> [URL] {
        guard let executableURL else {
            logger.info(
                "NVIDIA Sync CLI not found; skipping Sync tunnel discovery",
                category: .endpoint
            )
            return []
        }

        let aliases = discoveredAliases()
        guard !aliases.isEmpty else {
            return []
        }

        var urls: [URL] = []
        for alias in aliases {
            if let url = await dashboardURL(for: alias, executableURL: executableURL) {
                urls.append(url)
            }
        }
        return urls
    }

    private func dashboardURL(for alias: String, executableURL: URL) async -> URL? {
        var status = await fetchStatus(alias: alias, executableURL: executableURL)

        if status?.isRunning == true, status?.dashboardLocalPort == nil {
            let remote = NVIDIASyncKnownPorts.remoteDashboard
            logger.info(
                "Sync alias \(alias) connected without dashboard tunnel; opening remote \(remote)",
                category: .endpoint
            )
            _ = await runCommand(
                executableURL,
                ["open", alias, String(NVIDIASyncKnownPorts.remoteDashboard)]
            )
            status = await fetchStatus(alias: alias, executableURL: executableURL)
        }

        guard let status else { return nil }
        guard status.isRunning, let localPort = status.dashboardLocalPort else {
            logger.info(
                "Sync alias \(alias) has no open dashboard tunnel (status=\(status.connectionStatus))",
                category: .endpoint
            )
            return nil
        }

        let remote = NVIDIASyncKnownPorts.remoteDashboard
        logger.info(
            "Sync alias \(alias): remote \(remote) → local \(localPort)",
            category: .endpoint
        )
        return URL(string: "http://127.0.0.1:\(localPort)")
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

enum ProcessRunner {
    static func run(_ executable: URL, _ arguments: [String]) async -> CommandResult {
        await Task.detached(priority: .utility) {
            runSync(executable, arguments: arguments)
        }
        .value
    }

    static func runSync(_ executable: URL, arguments: [String]) -> CommandResult {
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
    let urls: [URL]
    func dashboardBaseURLs() async -> [URL] { urls }
}
