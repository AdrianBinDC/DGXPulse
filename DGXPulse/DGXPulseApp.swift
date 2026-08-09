import SwiftData
import SwiftUI

@main
struct DGXPulseApp: App {
    private let modelContainer: ModelContainer
    private let dependencies: AppDependencies
    @State private var viewModel: MetricsViewModel

    init() {
        let schema = Schema([TelemetrySampleRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            self.modelContainer = container
            let deps = AppDependencies.live(modelContainer: container)
            self.dependencies = deps
            self._viewModel = State(initialValue: MetricsViewModel(dependencies: deps))
            // Kick off session restore as soon as the menu bar appears.
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MetricsMenuView(viewModel: viewModel)
                .task {
                    await viewModel.bootstrap()
                }
        } label: {
            Text(viewModel.menuBarTitle)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.menu)

        Window("DGXPulse", id: "dashboard") {
            DetailDashboardView(viewModel: viewModel)
        }
        .defaultSize(width: 860, height: 640)
        .modelContainer(modelContainer)

        Window("Preferences", id: "settings") {
            SettingsView(viewModel: viewModel)
        }
        .defaultSize(width: 440, height: 380)

        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView(viewModel: viewModel)
        }
        .defaultSize(width: 580, height: 380)
    }
}
