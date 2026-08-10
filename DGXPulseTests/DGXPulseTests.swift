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
