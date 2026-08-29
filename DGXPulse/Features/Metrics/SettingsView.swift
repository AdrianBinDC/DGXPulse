import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: MetricsViewModel

    var body: some View {
        Form {
            Section("Sign In") {
                Text("Use the same username and password as the DGX Dashboard web UI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Username", text: $viewModel.username)
                    .textFieldStyle(.roundedBorder)

                SecureField("Password", text: $viewModel.password)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Sign In") {
                        viewModel.signIn()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canSignIn)
                    .keyboardShortcut(.defaultAction)

                    Button("Sign Out", role: .destructive) {
                        viewModel.signOut()
                    }
                }

                Text(viewModel.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Endpoint") {
                TextField("Base URL override", text: $viewModel.overrideBaseURLString)
                    .textFieldStyle(.roundedBorder)
                Text(
                    "Leave blank to use NVIDIA Sync (`nvsync status`) or a manual tunnel "
                        + "on port \(DashboardPorts.default)."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Button("Save Override") { viewModel.saveOverrideURL() }
                Button("Reset Defaults") { viewModel.resetDefaults() }
                Button("Rediscover") { viewModel.rediscover() }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 420, minHeight: 380)
        .navigateAfterSignIn(using: viewModel)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

struct DiagnosticsView: View {
    @Bindable var viewModel: MetricsViewModel

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Diagnostics").font(.headline)
                Spacer()
                Button("Refresh") { viewModel.refreshDiagnostics() }
                Button("Copy") { viewModel.copyDiagnostics() }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(viewModel.diagnostics.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding()
        .frame(width: 560, height: 360)
        .onAppear {
            viewModel.refreshDiagnostics()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
