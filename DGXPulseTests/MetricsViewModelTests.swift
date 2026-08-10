import Foundation
import Testing

@testable import DGXPulse

@MainActor
struct MetricsViewModelTests {
    @Test func acceptsSamplesFromMetricsSource() async throws {
        let data = try FixtureData.load("gpu_telemetry.json")
        let sample = try TelemetryParser.parseSample(from: data, at: Date(timeIntervalSince1970: 42))
        let source = StaticMetricsSource(events: [.connected, .sample(sample)])
        let session = InMemorySessionStore()
        try await session.save(username: "abolinger", token: "token")

        let deps = AppDependencies.mock(
            metricsSource: source,
            sessionStore: session,
            endpointResolver: StaticEndpointResolver(url: URL(string: "http://127.0.0.1:11000")!)
        )
        let viewModel = MetricsViewModel(dependencies: deps)
        await viewModel.bootstrap()

        // Allow stream task to process events.
        try await Task.sleep(for: .milliseconds(50))

        #expect(viewModel.latestSample?.gpuUtilizationPercent == 0)
        #expect(viewModel.phase == .streaming || viewModel.latestSample != nil)
    }
}
