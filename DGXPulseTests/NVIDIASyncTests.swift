import Foundation
import Testing

@testable import DGXPulse

struct NVIDIASyncStatusTests {
    @Test func parsesNotRunningStatus() throws {
        let data = try FixtureData.load("nvsync_status_not_running.json")
        let status = try JSONDecoder().decode(NVIDIASyncStatus.self, from: data)
        #expect(status.isRunning == false)
        #expect(status.dashboardLocalPort == nil)
    }

    @Test func parsesEphemeralLocalDashboardPort() throws {
        let data = try FixtureData.load("nvsync_status_ephemeral.json")
        let status = try JSONDecoder().decode(NVIDIASyncStatus.self, from: data)
        #expect(status.isRunning)
        #expect(status.dashboardLocalPort == 61_704)
    }

    @Test func missingOpenDashboardPortReturnsNil() throws {
        let data = try FixtureData.load("nvsync_status_no_ports.json")
        let status = try JSONDecoder().decode(NVIDIASyncStatus.self, from: data)
        #expect(status.isRunning)
        #expect(status.dashboardLocalPort == nil)
    }

    @Test func parsesSyncSSHConfigHosts() {
        let config = """
            Host example-spark
              ### CreatedBy: NVIDIA Sync
              Hostname example.local
              Port 22

            Host *
              IdentitiesOnly yes
            """
        #expect(NVIDIASyncSSHConfigParser.aliases(from: config) == ["example-spark"])
    }

    @Test func parsesStateStoreAliases() throws {
        let json = Data(
            """
            {"devices":[{"alias":"mnemo","name":"mnemo"},{"alias":"","name":"x"},{"name":"no-alias"}]}
            """
            .utf8
        )
        #expect(NVIDIASyncStateStoreParser.aliases(fromJSON: json) == ["mnemo"])
    }
}

struct EndpointResolverTests {
    @Test func prefersSyncMappedPortOverLastKnown() async throws {
        let suiteName = "DGXPulse.EndpointResolverTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Unable to create test UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        let preferences = PreferenceStore(defaults: defaults)
        preferences.lastKnownBaseURL = URL(string: "http://127.0.0.1:11000")

        let syncURL = URL(string: "http://127.0.0.1:61704")!
        let http = ProbeHTTPClient(dashboardPorts: [11_000, 61_704])
        let resolver = LocalDashboardEndpointResolver(
            http: http,
            preferences: preferences,
            logger: OSLogLogger(subsystem: "DGXPulseTests"),
            syncTunnels: StaticNVIDIASyncTunnelProvider(urls: [syncURL]),
            manualTunnelPorts: [11_000]
        )

        let url = try await resolver.resolve()
        #expect(url.port == 61_704)
        #expect(preferences.lastKnownBaseURL?.port == 61_704)
    }

    @Test func fallsBackToManualTunnelWhenSyncAbsent() async throws {
        let suiteName = "DGXPulse.EndpointResolverManual.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Unable to create test UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        let preferences = PreferenceStore(defaults: defaults)

        let http = ProbeHTTPClient(dashboardPorts: [11_000])
        let resolver = LocalDashboardEndpointResolver(
            http: http,
            preferences: preferences,
            logger: OSLogLogger(subsystem: "DGXPulseTests"),
            syncTunnels: StaticNVIDIASyncTunnelProvider(urls: []),
            manualTunnelPorts: [11_000]
        )

        let url = try await resolver.resolve()
        #expect(url.port == 11_000)
    }

    @Test func skipsManualTunnelWhenSyncConfiguredButDown() async {
        let suiteName = "DGXPulse.EndpointResolverSyncDown.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Unable to create test UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        let preferences = PreferenceStore(defaults: defaults)

        let http = ProbeHTTPClient(dashboardPorts: [11_000])
        let resolver = LocalDashboardEndpointResolver(
            http: http,
            preferences: preferences,
            logger: OSLogLogger(subsystem: "DGXPulseTests"),
            syncTunnels: StaticNVIDIASyncTunnelProvider(
                urls: [],
                hasConfiguredAliases: true
            ),
            manualTunnelPorts: [11_000]
        )

        await #expect(throws: ConnectionFailure.tunnelUnavailable) {
            _ = try await resolver.resolve()
        }
    }

    @Test func retriesSyncURLUntilDashboardAnswers() async throws {
        let suiteName = "DGXPulse.EndpointResolverReadiness.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Unable to create test UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        let preferences = PreferenceStore(defaults: defaults)

        let syncURL = URL(string: "http://127.0.0.1:61704")!
        let http = ProbeHTTPClient(dashboardPorts: [61_704], failuresBeforeSuccess: 2)
        let resolver = LocalDashboardEndpointResolver(
            http: http,
            preferences: preferences,
            logger: OSLogLogger(subsystem: "DGXPulseTests"),
            syncTunnels: StaticNVIDIASyncTunnelProvider(urls: [syncURL]),
            manualTunnelPorts: [],
            readinessAttempts: 4,
            readinessInterval: .zero
        )

        let url = try await resolver.resolve()
        #expect(url.port == 61_704)
        #expect(http.probeCount == 3)
    }
}

struct NVIDIASyncCLIClientTests {
    @Test func readsDashboardURLFromStatusAndOpensWhenMissing() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("DGXPulseSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let sshConfig = temporary.appendingPathComponent("ssh_config")
        try """
        Host demo
          ### CreatedBy: NVIDIA Sync
        """
        .write(to: sshConfig, atomically: true, encoding: .utf8)

        let stateStore = temporary.appendingPathComponent("state-store.json")
        try Data(#"{"devices":[{"alias":"demo"}]}"#.utf8).write(to: stateStore)

        let ephemeral = try FixtureData.load("nvsync_status_ephemeral.json")
        let emptyPorts = try FixtureData.load("nvsync_status_no_ports.json")
        var statusCalls = 0
        var openCalls = 0
        var connectCalls = 0

        let client = NVIDIASyncCLIClient(
            logger: OSLogLogger(subsystem: "DGXPulseTests"),
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            sshConfigURL: sshConfig,
            stateStoreURL: stateStore,
            connectSettleDelay: .zero,
            openSettleDelay: .zero,
            pollInterval: .zero
        ) { _, arguments in
            if arguments.first == "status" {
                statusCalls += 1
                // First status has no open dashboard; after open, return mapped port.
                let payload = statusCalls == 1 ? emptyPorts : ephemeral
                return CommandResult(exitCode: 0, stdout: payload, stderr: Data())
            }
            if arguments.first == "open" {
                openCalls += 1
                return CommandResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            if arguments.first == "connect" {
                connectCalls += 1
                return CommandResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            return CommandResult(
                exitCode: 1,
                stdout: Data(),
                stderr: Data("unexpected".utf8)
            )
        }

        let discovery = await client.discover()
        #expect(discovery.hasConfiguredAliases)
        #expect(discovery.urls.map(\.port) == [61_704])
        #expect(openCalls == 1)
        #expect(statusCalls == 2)
        #expect(connectCalls == 0)
    }

    @Test func reconnectsDetachedConnectWhenNotRunning() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("DGXPulseSyncReconnect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let sshConfig = temporary.appendingPathComponent("ssh_config")
        try """
        Host demo
          ### CreatedBy: NVIDIA Sync
        """
        .write(to: sshConfig, atomically: true, encoding: .utf8)

        let stateStore = temporary.appendingPathComponent("state-store.json")
        try Data(#"{"devices":[{"alias":"demo"}]}"#.utf8).write(to: stateStore)

        let notRunning = try FixtureData.load("nvsync_status_not_running.json")
        let emptyPorts = try FixtureData.load("nvsync_status_no_ports.json")
        let ephemeral = try FixtureData.load("nvsync_status_ephemeral.json")
        var statusCalls = 0
        var openCalls = 0
        var connectCalls = 0

        let client = NVIDIASyncCLIClient(
            logger: OSLogLogger(subsystem: "DGXPulseTests"),
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            sshConfigURL: sshConfig,
            stateStoreURL: stateStore,
            connectSettleDelay: .zero,
            openSettleDelay: .zero,
            pollInterval: .zero
        ) { _, arguments in
            if arguments.first == "status" {
                statusCalls += 1
                let payload: Data
                switch statusCalls {
                case 1:
                    payload = notRunning
                case 2:
                    payload = emptyPorts
                default:
                    payload = ephemeral
                }
                return CommandResult(exitCode: 0, stdout: payload, stderr: Data())
            }
            if arguments.first == "connect" {
                connectCalls += 1
                #expect(arguments == ["connect", "--detach", "demo"])
                return CommandResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            if arguments.first == "open" {
                openCalls += 1
                #expect(arguments == ["open", "demo", "11000"])
                return CommandResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            return CommandResult(
                exitCode: 1,
                stdout: Data(),
                stderr: Data("unexpected".utf8)
            )
        }

        let discovery = await client.discover()
        #expect(discovery.urls.map(\.port) == [61_704])
        #expect(connectCalls == 1)
        #expect(openCalls == 1)
        #expect(statusCalls == 3)
    }

    @Test func sharesOneInFlightDiscoveryAcrossConcurrentCallers() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("DGXPulseSyncSingleFlight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let sshConfig = temporary.appendingPathComponent("ssh_config")
        try """
        Host demo
          ### CreatedBy: NVIDIA Sync
        """
        .write(to: sshConfig, atomically: true, encoding: .utf8)

        let stateStore = temporary.appendingPathComponent("state-store.json")
        try Data(#"{"devices":[{"alias":"demo"}]}"#.utf8).write(to: stateStore)

        let ephemeral = try FixtureData.load("nvsync_status_ephemeral.json")
        let emptyPorts = try FixtureData.load("nvsync_status_no_ports.json")
        let lock = NSLock()
        var openCalls = 0

        let client = NVIDIASyncCLIClient(
            logger: OSLogLogger(subsystem: "DGXPulseTests"),
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            sshConfigURL: sshConfig,
            stateStoreURL: stateStore,
            connectSettleDelay: .zero,
            openSettleDelay: .milliseconds(50),
            pollInterval: .zero
        ) { _, arguments in
            if arguments.first == "status" {
                lock.lock()
                // Shared across concurrent callers; first status has no open dashboard.
                let payload: Data
                if openCalls == 0 {
                    payload = emptyPorts
                } else {
                    payload = ephemeral
                }
                lock.unlock()
                return CommandResult(exitCode: 0, stdout: payload, stderr: Data())
            }
            if arguments.first == "open" {
                lock.lock()
                openCalls += 1
                lock.unlock()
                return CommandResult(exitCode: 0, stdout: Data(), stderr: Data())
            }
            return CommandResult(
                exitCode: 1,
                stdout: Data(),
                stderr: Data("unexpected".utf8)
            )
        }

        async let first = client.discover()
        async let second = client.discover()
        let results = await [first, second]

        #expect(results.map { $0.urls.map(\.port) } == [[61_704], [61_704]])
        #expect(openCalls == 1)
    }
}

private final class ProbeHTTPClient: HTTPClient, @unchecked Sendable {
    let dashboardPorts: Set<Int>
    private let lock = NSLock()
    private var remainingFailuresBeforeSuccess: Int
    private(set) var probeCount = 0

    init(dashboardPorts: Set<Int>, failuresBeforeSuccess: Int = 0) {
        self.dashboardPorts = dashboardPorts
        self.remainingFailuresBeforeSuccess = failuresBeforeSuccess
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let port = request.url?.port ?? -1
        let fallbackURL = URL(fileURLWithPath: "/")
        guard
            let response = HTTPURLResponse(
                url: request.url ?? fallbackURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )
        else {
            throw URLError(.badServerResponse)
        }

        lock.lock()
        probeCount += 1
        let shouldFail = remainingFailuresBeforeSuccess > 0
        if shouldFail {
            remainingFailuresBeforeSuccess -= 1
        }
        lock.unlock()

        if shouldFail || !dashboardPorts.contains(port) {
            return (Data("<title>Other</title>".utf8), response)
        }
        return (Data("<title>DGX Dashboard</title>".utf8), response)
    }

    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        throw URLError(.unsupportedURL)
    }
}
