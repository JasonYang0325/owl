import SwiftUI

/// Main content view that switches between connected/loading/error states.
/// Extracted from OWLBrowserApp.swift for separation of concerns.
package struct MainContentView: View {
    @EnvironmentObject var viewModel: BrowserViewModel

    package init() {}

    package var body: some View {
        Group {
            switch viewModel.connectionState {
            case .connected:
                BrowserWindow()
            case .failed(let message):
                ErrorPageView(
                    message: message,
                    onRetry: { viewModel.launch() }
                )
            default:
                ProgressView("正在连接浏览器引擎...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(OWL.surfaceSecondary)
            }
        }
        .frame(minWidth: 480, minHeight: 400)
        .task {
            // Deferred Mojo initialization: window already exists at this point.
            // This avoids mojo::core::Init() blocking SwiftUI WindowGroup creation.
            await viewModel.initializeAndLaunch()
        }
    }
}
