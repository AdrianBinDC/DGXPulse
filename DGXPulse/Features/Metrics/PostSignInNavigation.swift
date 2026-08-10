import AppKit
import SwiftUI

/// After interactive sign-in, close the Sign In window and present the dashboard.
struct PostSignInNavigationModifier: ViewModifier {
    @Bindable var viewModel: MetricsViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.onChange(of: viewModel.postSignInNavigationPending) { _, pending in
            guard pending else { return }
            viewModel.acknowledgePostSignInNavigation()
            viewModel.openDetail()
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: AppWindowID.dashboard)
            dismissWindow(id: AppWindowID.settings)
        }
    }
}

extension View {
    func navigateAfterSignIn(using viewModel: MetricsViewModel) -> some View {
        modifier(PostSignInNavigationModifier(viewModel: viewModel))
    }
}
