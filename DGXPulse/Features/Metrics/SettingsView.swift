import SwiftUI

struct SettingsView: View {
    @Bindable var viewModel: MetricsViewModel

    var body: some View {
        Form {
            Section("Dashboard") {
                TextField("Username", text: $viewModel.username)
                SecureField("Password", text: $viewModel.password)
                Button("Sign In") { viewModel.signIn() }
                    .disabled(!viewModel.canSignIn)
                Button("Sign Out", role: .destructive) { viewModel.signOut() }
            }

            Section("Endpoint") {
                TextField("Base URL override", text: $viewModel.overrideBaseURLString)
                    .textFieldStyle(.roundedBorder)
                Text("Leave blank to auto-discover. Default port is \(DashboardPorts.default).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Save Override") { viewModel.saveOverrideURL() }
                Button("Reset Defaults") { viewModel.resetDefaults() }
                Button("Rediscover") { viewModel.rediscover() }
            }

            Section("Status") {
                Text(viewModel.statusMessage)
            }
        }
        .padding()
        .frame(width: 420, height: 360)
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
        .onAppear { viewModel.refreshDiagnostics() }
    }
}
