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
        let parsed = try TelemetryParser.parse(data, at: Date(timeIntervalSince1970: 0))
        let sample = parsed.sample
        #expect(sample.gpuUtilizationPercent == 0)
        #expect(sample.memoryTotalMB == 131_072)
        #expect(sample.memoryUsedMB == 131_072 - 27_302)
        // Dashboard `GB` = KiB * 1024 / 1e9; `GiB` = KiB / 1048576.
        #expect(abs(sample.memoryTotalGiB - 128) < 0.001)
        #expect(abs(sample.memoryTotalGB - 137.438_953_472) < 0.000_001)
        #expect(abs(sample.memoryUsedGiB - (103_770 / 1_024)) < 0.000_001)
        #expect(abs(sample.memoryUsedGB - 108.810_731_52) < 0.000_001)
        #expect(parsed.memoryFields == .kibibytes)
    }

    @Test func parsesLegacyMegabyteTelemetryFields() throws {
        let json = try FixtureData.load("gpu_telemetry_legacy_mb.json")
        let parsed = try TelemetryParser.parse(json, at: Date(timeIntervalSince1970: 0))
        #expect(parsed.memoryFields == .megabytes)
        #expect(parsed.sample.gpuUtilizationPercent == 12)
        #expect(parsed.sample.memoryTotalMB == 131_072)
        #expect(parsed.sample.memoryUsedMB == 131_072 - 27_302)
    }

    @Test func summarizesLiveTelemetryKeysForDiagnostics() throws {
        let data = try FixtureData.load("gpu_telemetry.json")
        let summary = JSONDiagnostics.summarize(data)
        #expect(summary.contains("memory_total_in_kib"))
        #expect(summary.contains("memory_available_in_kib"))
        #expect(summary.contains("percentage_utilization"))
        #expect(!summary.contains("memory_total_in_mb"))
    }

    @Test func describesMissingTelemetryKeys() {
        let json = Data(#"{"TelemetryForGPUs":[{}]}"#.utf8)
        do {
            _ = try TelemetryParser.parse(json, at: Date(timeIntervalSince1970: 0))
            Issue.record("Expected decode to fail")
        } catch {
            let description = JSONDiagnostics.describe(error)
            #expect(description.contains("missing"))
            #expect(description.contains("percentage_utilization") || description.contains("memory_"))
        }
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
