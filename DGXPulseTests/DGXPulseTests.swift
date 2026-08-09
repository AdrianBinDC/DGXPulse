import Foundation
import Testing

@testable import DGXPulse

enum FixtureData {
    static func load(_ name: String) throws -> Data {
        let thisFile = URL(fileURLWithPath: #filePath)
        let fixtures =
            thisFile
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try Data(contentsOf: fixtures)
    }
}

struct TelemetryParserTests {
    @Test func parsesLiveGpuTelemetryFixture() throws {
        let data = try FixtureData.load("gpu_telemetry.json")
        let sample = try TelemetryParser.parseSample(from: data, at: Date(timeIntervalSince1970: 0))
        #expect(sample.gpuUtilizationPercent == 0)
        #expect(sample.memoryTotalMB == 131_072)
        #expect(sample.memoryUsedMB == 131_072 - 27_302)
        #expect(abs(sample.memoryUsedGB - 103.77) < 0.01)
        #expect(abs(sample.memoryTotalGB - 128) < 0.001)
    }

    @Test func parsesLoginSuccessFixture() throws {
        let data = try FixtureData.load("login_success.json")
        let login = try JSONDecoder().decode(LoginResponse.self, from: data)
        #expect(login.token == "REDACTED_DASHBOARD_SESSION_TOKEN")
    }

    @Test func parsesUnauthorizedFixture() throws {
        let data = try FixtureData.load("unauthorized_telemetry.json")
        let error = try JSONDecoder().decode(DashboardErrorResponse.self, from: data)
        #expect(error.error == "missing or invalid Authorization header")
    }

    @Test func parsesLoginFailureFixture() throws {
        let data = try FixtureData.load("login_failure.json")
        let error = try JSONDecoder().decode(DashboardErrorResponse.self, from: data)
        #expect(error.error == "Failed to run authenticate operation")
    }
}

struct ReconnectBackoffTests {
    @Test func growsThenCaps() {
        let first = ReconnectBackoff.delay(forAttempt: 0)
        let later = ReconnectBackoff.delay(forAttempt: 20)
        #expect(first < later)
        #expect(later <= .seconds(30))
    }
}

struct HistoryStoreTests {
    @Test func appendAndPrune() async throws {
        let store = InMemoryMetricsHistoryStore()
        let old = MetricsSample(
            timestamp: Date(timeIntervalSince1970: 1),
            gpuUtilizationPercent: 10,
            memoryUsedMB: 1_000,
            memoryTotalMB: 128_000
        )
        let recent = MetricsSample(
            timestamp: Date(timeIntervalSince1970: 100),
            gpuUtilizationPercent: 20,
            memoryUsedMB: 2_000,
            memoryTotalMB: 128_000
        )
        try await store.append(old)
        try await store.append(recent)
        try await store.prune(olderThan: Date(timeIntervalSince1970: 50))
        let kept = try await store.recent(since: Date(timeIntervalSince1970: 0))
        #expect(kept.count == 1)
        #expect(kept[0].gpuUtilizationPercent == 20)
    }
}

struct TokenRedactorTests {
    @Test func redacts() {
        #expect(TokenRedactor.redact("abcdefghij") == "…ghij")
    }
}

struct HistoryDownsamplerTests {
    @Test func keepsCompletedBucketsStableWhenAppending() {
        let range = HistoryRange.fiveMinutes
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var samples: [MetricsSample] = []
        for second in 0..<20 {
            samples.append(
                MetricsSample(
                    timestamp: base.addingTimeInterval(Double(second)),
                    gpuUtilizationPercent: Double(second),
                    memoryUsedMB: 50_000,
                    memoryTotalMB: 131_072
                )
            )
        }

        let first = HistoryDownsampler.downsample(samples, range: range, now: base.addingTimeInterval(20))
        samples.append(
            MetricsSample(
                timestamp: base.addingTimeInterval(21),
                gpuUtilizationPercent: 99,
                memoryUsedMB: 50_000,
                memoryTotalMB: 131_072
            )
        )
        let second = HistoryDownsampler.downsample(samples, range: range, now: base.addingTimeInterval(21))

        #expect(first.count >= 2)
        #expect(second.count >= first.count)
        // All but possibly the newest bucket should match exactly.
        let shared = min(first.count, second.count) - 1
        for index in 0..<shared {
            #expect(first[index] == second[index])
        }
    }
}

struct NVIDIASyncStatusTests {
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

        let client = NVIDIASyncCLIClient(
            logger: OSLogLogger(subsystem: "DGXPulseTests"),
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            sshConfigURL: sshConfig,
            stateStoreURL: stateStore
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
            return CommandResult(
                exitCode: 1,
                stdout: Data(),
                stderr: Data("unexpected".utf8)
            )
        }

        let urls = await client.dashboardBaseURLs()
        #expect(urls.map(\.port) == [61_704])
        #expect(openCalls == 1)
        #expect(statusCalls == 2)
    }
}

private struct ProbeHTTPClient: HTTPClient {
    let dashboardPorts: Set<Int>

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
        if dashboardPorts.contains(port) {
            return (Data("<title>DGX Dashboard</title>".utf8), response)
        }
        return (Data("<title>Other</title>".utf8), response)
    }

    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        throw URLError(.unsupportedURL)
    }
}
