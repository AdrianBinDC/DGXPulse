import SwiftUI

struct DetailDashboardView: View {
    @Bindable var viewModel: MetricsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Your DGX Dashboard")
                        .font(.largeTitle.bold())
                }

                statusBanner

                MetricPanel(
                    title: "System Memory",
                    gaugeValue: viewModel.latestSample?.memoryUsedGB ?? 0,
                    gaugeMax: max(memoryTotalGB, 1),
                    primaryText: memoryPrimary,
                    secondaryText: memorySecondary,
                    samples: viewModel.history,
                    chartValue: \.memoryUsedGB,
                    yLabel: memoryChartYLabel
                )

                MetricPanel(
                    title: "GPU Utilization",
                    gaugeValue: viewModel.latestSample?.gpuUtilizationPercent ?? 0,
                    gaugeMax: 100,
                    primaryText: gpuPrimary,
                    secondaryText: "",
                    samples: viewModel.history,
                    chartValue: \.gpuUtilizationPercent,
                    yLabel: "100%"
                )
            }
            .padding(24)
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .onAppear {
            viewModel.openDetail()
        }
    }

    private var memoryTotalGB: Double {
        viewModel.latestSample?.memoryTotalGB ?? 0
    }

    private var memoryChartYLabel: String {
        String(format: "%.2f GB", memoryTotalGB)
    }

    private var statusBanner: some View {
        Text(viewModel.statusMessage)
            .font(.callout)
            .foregroundStyle(.white.opacity(0.7))
    }

    private var memoryPrimary: String {
        guard let sample = viewModel.latestSample else { return "— GB" }
        return String(format: "%.2f GB", sample.memoryUsedGB)
    }

    private var memorySecondary: String {
        guard let sample = viewModel.latestSample else { return "— GB total" }
        return String(format: "%.2f GB total", sample.memoryTotalGB)
    }

    private var gpuPrimary: String {
        guard let sample = viewModel.latestSample else { return "— %" }
        return "\(Int(sample.gpuUtilizationPercent.rounded())) %"
    }
}
