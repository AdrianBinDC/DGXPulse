import AppKit
import SwiftUI

struct MetricsMenuView: View {
    @Bindable var viewModel: MetricsViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let sample = viewModel.latestSample {
                let ram = Int(sample.memoryUtilizationPercent.rounded())
                let used = String(format: "%.1f", sample.memoryUsedGB)
                let total = String(format: "%.0f", sample.memoryTotalGB)
                Text("RAM \(ram)% · \(used) / \(total) GB")
                Text("GPU \(Int(sample.gpuUtilizationPercent.rounded()))%")
            }

            Text(viewModel.statusMessage)
                .foregroundStyle(.secondary)

            Divider()

            if viewModel.phase == .signedOut || isAuthFailure {
                signInFields
                Button("Sign In") { viewModel.signIn() }
                    .disabled(!viewModel.canSignIn)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Open Dashboard") {
                    viewModel.openDetail()
                    openWindow(id: "dashboard")
                }
                Button("Retry / Rediscover") { viewModel.rediscover() }
                Button("Sign Out") { viewModel.signOut() }
            }

            Divider()

            Button("Preferences…") {
                openWindow(id: "settings")
            }
            .keyboardShortcut(",")

            Button("Diagnostics") {
                viewModel.refreshDiagnostics()
                openWindow(id: "diagnostics")
            }

            Button("Quit DGXPulse") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(4)
    }

    private var isAuthFailure: Bool {
        if case .failed(.unauthorized) = viewModel.phase { return true }
        if case .failed(.loginFailed) = viewModel.phase { return true }
        return false
    }

    @ViewBuilder
    private var signInFields: some View {
        TextField("Username", text: $viewModel.username)
        SecureField("Password", text: $viewModel.password)
    }
}
