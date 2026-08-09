import SwiftUI

struct DetailDashboardView: View {
    @Bindable var viewModel: MetricsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Welcome")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Your DGX Dashboard")
                            .font(.largeTitle.bold())
                    }

                    Spacer()

                    Picker("Range", selection: $viewModel.selectedHistoryRange) {
                        ForEach(HistoryRange.allCases) { range in
                            Text(range.title).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                    .onChange(of: viewModel.selectedHistoryRange) { _, _ in
                        viewModel.historyRangeChanged()
                    }
                }

                statusBanner

                MetricPanel(
                    title: "System Memory",
                    gaugeValue: viewModel.latestSample?.memoryUsedGB ?? 0,
                    gaugeMax: max(viewModel.latestSample?.memoryTotalGB ?? 128, 1),
                    primaryText: memoryPrimary,
                    secondaryText: memorySecondary,
                    samples: viewModel.history,
                    chartValue: \.memoryUsedGB,
                    yLabel: String(format: "%.0fGB", viewModel.latestSample?.memoryTotalGB ?? 128)
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
        return String(format: "%.0f GB total", sample.memoryTotalGB)
    }

    private var gpuPrimary: String {
        guard let sample = viewModel.latestSample else { return "— %" }
        return String(format: "%.0f %%", sample.gpuUtilizationPercent)
    }
}
