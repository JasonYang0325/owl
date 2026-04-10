import SwiftUI

struct ContentAreaView: View {
    @EnvironmentObject var viewModel: BrowserViewModel

    var body: some View {
        ZStack {
            // Opaque fallback background — prevents transparency leak during
            // navigation transitions (about:blank → URL, tab switching, etc.).
            OWL.surfacePrimary

            if let activeTab = viewModel.activeTab {
                // Use inner view that directly observes the TabViewModel
                TabContentView(tab: activeTab)
            } else {
                OWL.surfaceSecondary
            }

            // Phase 4: SSL error page overlay.
            SSLErrorOverlay(
                securityVM: viewModel.securityVM,
                canGoBack: viewModel.activeTab?.canGoBack ?? false,
                onGoBack: { [weak viewModel] in
                    guard let vm = viewModel else { return }
                    vm.securityVM.goBackToSafety()
                    if vm.activeTab?.canGoBack == true {
                        vm.activeTab?.goBack()
                    } else {
                        vm.activeTab?.navigate(to: "about:blank")
                    }
                }
            )
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.activeTab?.id)
    }
}

/// Inner view observing SecurityViewModel for SSL error overlay.
private struct SSLErrorOverlay: View {
    @ObservedObject var securityVM: SecurityViewModel
    let canGoBack: Bool
    let onGoBack: () -> Void

    var body: some View {
        if let sslError = securityVM.pendingSSLError {
            SSLErrorPage(
                errorInfo: sslError,
                canGoBack: canGoBack,
                onGoBack: onGoBack,
                onProceed: {
                    securityVM.proceedAnyway()
                }
            )
            .transition(.opacity)
        }
    }
}

/// Inner view that directly observes TabViewModel via @ObservedObject.
/// This ensures SwiftUI re-renders when tab properties change (url, isLoading, caContextId).
private struct TabContentView: View {
    @ObservedObject var tab: TabViewModel
    @EnvironmentObject var viewModel: BrowserViewModel

    var body: some View {
        ZStack {
            // Phase 2 Navigation: error page takes priority over other content.
            if let error = tab.navigationError,
               !error.isAborted,
               error.navigationId == tab.currentNavigationId {
                ErrorPageView(
                    title: error.localizedTitle,
                    message: error.localizedMessage,
                    onRetry: { tab.reload() },
                    errorCode: Int(error.errorCode),
                    suggestion: error.suggestion,
                    onGoBack: {
                        if tab.canGoBack {
                            tab.goBack()
                        } else {
                            tab.navigate(to: "about:blank")
                        }
                    },
                    showRetry: !error.requiresGoBack
                )
                .transition(.opacity)
            } else if tab.isWelcomePage {
                WelcomeView { text in
                    tab.navigate(to: text)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if tab.hasRenderSurface {
                RemoteLayerView(
                    webviewId: tab.webviewId,
                    contextId: tab.caContextId,
                    pixelWidth: tab.renderPixelWidth,
                    pixelHeight: tab.renderPixelHeight,
                    scaleFactor: tab.renderScaleFactor,
                    // Phase 35: Cross-screen DPI change — update viewport on drag.
                    onScaleChange: { newScale, dipSize in
                        tab.updateViewport(
                            dipWidth: dipSize.width,
                            dipHeight: dipSize.height,
                            scale: newScale
                        )
                    },
                    // Context menu: expose NSView reference to ContextMenuHandler.
                    onViewCreated: { [weak viewModel] nsView in
                        viewModel?.contextMenuHandler?.view = nsView
                    }
                )
                .accessibilityIdentifier("webContentView")
                .transition(.opacity)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(tab.url ?? "加载中...")
                        .font(OWL.bodyFont)
                        .foregroundColor(OWL.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(OWL.surfacePrimary)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                if tab.isFindBarVisible {
                    FindBarView(tab: tab)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if tab.isSlowLoading {
                    SlowLoadingBanner()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: tab.isFindBarVisible)
        .animation(.easeInOut(duration: 0.2), value: tab.isSlowLoading)
        .animation(.easeInOut(duration: 0.2), value: tab.navigationError?.id)
        .animation(.easeInOut(duration: 0.3), value: tab.hasRenderSurface)
        .animation(.easeInOut(duration: 0.2), value: tab.isWelcomePage)
        .onGeometryChange(for: CGSize.self) { geo in
            geo.size
        } action: { size in
            let scale = NSApp.keyWindow?.screen?.backingScaleFactor ?? 2.0
            tab.updateViewport(dipWidth: size.width, dipHeight: size.height, scale: scale)
        }
    }
}
