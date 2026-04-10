import SwiftUI

#if canImport(OWLBridge)
import OWLBridge
#endif

enum LayoutMode: Equatable {
    case full       // >= 1000px
    case compact    // 600-999px
    case minimal    // < 600px

    static func from(width: CGFloat) -> LayoutMode {
        if width >= 1000 { return .full }
        if width >= 600 { return .compact }
        return .minimal
    }

    var isCompact: Bool { self == .compact }
    var sidebarVisible: Bool { self != .minimal }
}

struct BrowserWindow: View {
    @EnvironmentObject var viewModel: BrowserViewModel
    @State private var sidebarWidth: CGFloat = OWL.sidebarWidth
    @State private var layoutMode: LayoutMode = .full
    @State private var tabSwitchMonitor: Any?
    @State private var showSettings = false
    @AppStorage("owl.sidebar.manuallyVisible") private var isSidebarManuallyVisible: Bool = true

    private var isSidebarActuallyVisible: Bool {
        layoutMode.sidebarVisible && isSidebarManuallyVisible
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBarView(
                layoutMode: layoutMode,
                onTogglePanel: { panel in viewModel.togglePanel(panel) },
                onToggleSidebar: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isSidebarManuallyVisible.toggle()
                    }
                },
                isSidebarVisible: isSidebarActuallyVisible
            )
            HStack(spacing: 0) {
                if isSidebarActuallyVisible {
                    Group {
                        SidebarView(
                            isCompact: layoutMode.isCompact,
                            width: layoutMode.isCompact ? 36 : sidebarWidth,
                            onTogglePanel: { panel in viewModel.togglePanel(panel) },
                            onOpenSettings: { showSettings = true }
                        )
                        SidebarDivider(
                            width: $sidebarWidth,
                            isDragEnabled: layoutMode == .full
                        )
                    }
                    .transition(.move(edge: .leading))
                }
                ContentAreaView()
                if viewModel.rightPanel != .none {
                    Divider()
                    RightPanelContainer(activePanel: $viewModel.rightPanel,
                                       consoleVM: viewModel.consoleVM)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 400)
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                PermissionAlertView(permissionVM: viewModel.permissionVM)
                    .padding(.top, OWL.topBarHeight)
                if viewModel.permissionVM.showToast,
                   let msg = viewModel.permissionVM.toastMessage {
                    Text(msg)
                        .font(.caption)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8),
                       value: viewModel.permissionVM.pendingAlert?.id)
            .animation(.easeOut(duration: 0.3),
                       value: viewModel.permissionVM.showToast)
        }
        .overlay(alignment: .bottomTrailing) {
            if showSettings {
                Text("settings-open")
                    .font(.caption2)
                    .foregroundStyle(.clear)
                    .padding(1)
                    .accessibilityIdentifier("settingsPresentedSentinel")
            }
        }
        .overlay {
            if showSettings {
                ZStack {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .onTapGesture { showSettings = false }

                    SettingsView()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
                        .accessibilityIdentifier("settingsModal")
                }
            }
        }
        .background {
            // Cmd+F: show find bar. Hidden button with keyboard shortcut.
            Button("") { viewModel.activeTab?.showFindBar() }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
            // Escape: hide find bar.
            Button("") {
                if showSettings {
                    showSettings = false
                } else if viewModel.activeTab?.isFindBarVisible == true {
                    viewModel.activeTab?.hideFindBar()
                }
            }
            .keyboardShortcut(.escape, modifiers: [])
            .hidden()
            // Cmd+, open settings
            Button("") { showSettings = true }
                .keyboardShortcut(",", modifiers: .command)
                .hidden()
            // Phase 34: Cmd+= zoom in
            Button("") { viewModel.activeTab?.zoomIn() }
                .keyboardShortcut("=", modifiers: .command)
                .hidden()
            // Cmd+- zoom out
            Button("") { viewModel.activeTab?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .hidden()
            // Cmd+0 reset zoom
            Button("") { viewModel.activeTab?.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
                .hidden()

            // Phase 3: Cmd+Shift+L toggle sidebar
            Button("") {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isSidebarManuallyVisible.toggle()
                }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .hidden()

            // Phase 4: Tab lifecycle shortcuts
            // Cmd+T: new tab
            Button("") { viewModel.createTab() }
                .keyboardShortcut("t", modifiers: .command)
                .hidden()
            // Cmd+W: close active tab (including pinned)
            Button("") {
                if let tab = viewModel.activeTab {
                    viewModel.closeTab(tab)
                }
            }
            .keyboardShortcut("w", modifiers: .command)
            .hidden()
            // Cmd+Shift+T: undo close tab
            Button("") { viewModel.undoCloseTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .hidden()

            // Cmd+1~8: select tab by index
            Button("") { viewModel.selectTabByIndex(1) }
                .keyboardShortcut("1", modifiers: .command)
                .hidden()
            Button("") { viewModel.selectTabByIndex(2) }
                .keyboardShortcut("2", modifiers: .command)
                .hidden()
            Button("") { viewModel.selectTabByIndex(3) }
                .keyboardShortcut("3", modifiers: .command)
                .hidden()
            Button("") { viewModel.selectTabByIndex(4) }
                .keyboardShortcut("4", modifiers: .command)
                .hidden()
            Button("") { viewModel.selectTabByIndex(5) }
                .keyboardShortcut("5", modifiers: .command)
                .hidden()
            Button("") { viewModel.selectTabByIndex(6) }
                .keyboardShortcut("6", modifiers: .command)
                .hidden()
            Button("") { viewModel.selectTabByIndex(7) }
                .keyboardShortcut("7", modifiers: .command)
                .hidden()
            Button("") { viewModel.selectTabByIndex(8) }
                .keyboardShortcut("8", modifiers: .command)
                .hidden()
            // Cmd+9: always select last tab
            Button("") { viewModel.selectTabByIndex(9) }
                .keyboardShortcut("9", modifiers: .command)
                .hidden()
        }
        .onAppear {
            // Cmd+Option+Up/Down: switch tabs via NSEvent monitor
            // (SwiftUI keyboardShortcut cannot capture arrow+option combos reliably)
            guard tabSwitchMonitor == nil else { return }
            tabSwitchMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.modifierFlags.contains([.command, .option]) else { return event }
                if event.keyCode == 126 { // Up arrow
                    Task { @MainActor in viewModel.selectPreviousTab() }
                    return nil
                } else if event.keyCode == 125 { // Down arrow
                    Task { @MainActor in viewModel.selectNextTab() }
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = tabSwitchMonitor {
                NSEvent.removeMonitor(monitor)
                tabSwitchMonitor = nil
            }
        }
        .sheet(item: Binding<AuthChallenge?>(
            get: { viewModel.activeTab?.authChallenge },
            set: { viewModel.activeTab?.authChallenge = $0 }
        )) { challenge in
            AuthAlertView(
                challenge: challenge,
                onSubmit: { username, password in
                    #if canImport(OWLBridge)
                    username.withCString { uCStr in
                        password.withCString { pCStr in
                            OWLBridge_RespondToAuth(challenge.authId, uCStr, pCStr)
                        }
                    }
                    #endif
                    viewModel.activeTab?.authChallenge = nil
                },
                onCancel: {
                    #if canImport(OWLBridge)
                    OWLBridge_RespondToAuth(challenge.authId, nil, nil)
                    #endif
                    viewModel.activeTab?.authChallenge = nil
                }
            )
        }
        .onGeometryChange(for: CGFloat.self) { geo in
            geo.size.width
        } action: { newWidth in
            withAnimation(.easeInOut(duration: 0.25)) {
                layoutMode = LayoutMode.from(width: newWidth)
            }
        }
    }
}

// MARK: - Sidebar Divider

struct SidebarDivider: View {
    @Binding var width: CGFloat
    let isDragEnabled: Bool
    @State private var isHovered = false
    @GestureState private var dragStartWidth: CGFloat? = nil

    var body: some View {
        Rectangle()
            .fill(isHovered ? OWL.accentPrimary : OWL.border)
            .frame(width: isHovered ? 3 : 1)
            .onHover { isHovered = isDragEnabled && $0 }
            .gesture(isDragEnabled ? dragGesture : nil)
            .animation(.easeOut(duration: 0.15), value: isHovered)
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .updating($dragStartWidth) { _, state, _ in
                if state == nil { state = width }
            }
            .onChanged { value in
                let start = dragStartWidth ?? width
                width = max(160, min(280, start + value.translation.width))
            }
    }
}
