import AppKit
import SwiftUI

struct MetricsMenuView: View {
    @Bindable var viewModel: MetricsViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            if needsSignIn {
                signInForm
            } else {
                connectedActions
            }

            Divider()

            Button("Preferences…") {
                presentWindow(id: AppWindowID.settings)
            }
            .keyboardShortcut(",")

            Button("Diagnostics") {
                viewModel.refreshDiagnostics()
                presentWindow(id: AppWindowID.diagnostics)
            }

            Button("Quit DGXPulse") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 280)
        .navigateAfterSignIn(using: viewModel)
        .task {
            await viewModel.bootstrap()
            if needsSignIn {
                presentWindow(id: AppWindowID.settings)
            }
        }
    }

    private var needsSignIn: Bool {
        switch viewModel.phase {
        case .signedOut:
            return true
        case .failed(.unauthorized), .failed(.loginFailed):
            return true
        default:
            return false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("DGXPulse")
                .font(.headline)
            Text(viewModel.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let sample = viewModel.latestSample {
                let ram = Int(sample.memoryUtilizationPercent.rounded())
                let used = String(format: "%.1f", sample.memoryUsedGB)
                let total = String(format: "%.0f", sample.memoryTotalGB)
                Text("RAM \(ram)% · \(used) / \(total) GB")
                    .font(.caption.monospacedDigit())
                Text("GPU \(Int(sample.gpuUtilizationPercent.rounded()))%")
                    .font(.caption.monospacedDigit())
            }
        }
    }

    private var signInForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sign in with your DGX Dashboard credentials.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Username", text: $viewModel.username)
                .textFieldStyle(.roundedBorder)

            SecureField("Password", text: $viewModel.password)
                .textFieldStyle(.roundedBorder)

            Button("Sign In") {
                viewModel.signIn()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canSignIn)
            .keyboardShortcut(.defaultAction)

            Button("Open Sign-In Window…") {
                presentWindow(id: AppWindowID.settings)
            }
            .buttonStyle(.link)
        }
    }

    private var connectedActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Open Dashboard") {
                viewModel.openDetail()
                presentWindow(id: AppWindowID.dashboard)
            }
            Button("Retry / Rediscover") {
                viewModel.rediscover()
            }
            Button("Sign Out", role: .destructive) {
                viewModel.signOut()
            }
        }
    }

    private func presentWindow(id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }
}
