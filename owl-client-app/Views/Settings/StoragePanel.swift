import SwiftUI

struct StoragePanel: View {
    @ObservedObject var vm: StorageViewModel

    @State private var selectedTab = "cookies"

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker: Cookies / Storage Usage
            Picker("", selection: $selectedTab) {
                Text("Cookies")
                    .accessibilityIdentifier("storageCookiesSegment")
                    .tag("cookies")
                Text("Storage")
                    .accessibilityIdentifier("storageUsageSegment")
                    .tag("usage")
            }
            .accessibilityIdentifier("storagePanelTabPicker")
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            if vm.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selectedTab == "cookies" {
                cookiesTab
            } else {
                usageTab
            }

            Divider()

            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .task {
            async let a: Void = vm.loadDomains()
            async let b: Void = vm.loadUsage()
            _ = await (a, b)
        }
        .accessibilityIdentifier("storagePanel")
    }

    // MARK: - Cookies Tab

    private var cookiesTab: some View {
        Group {
            if vm.domains.isEmpty {
                emptyState(
                    icon: "birthday.cake",
                    title: "No Cookies",
                    subtitle: "Cookie data will appear here after browsing."
                )
            } else {
                List {
                    ForEach(vm.domains) { domain in
                        HStack {
                            Text(domain.domain)
                                .font(OWL.bodyFont)
                                .lineLimit(1)

                            Spacer()

                            Text("\(domain.count) cookie\(domain.count == 1 ? "" : "s")")
                                .font(OWL.captionFont)
                                .foregroundStyle(.secondary)

                            Button(role: .destructive) {
                                Task { await vm.deleteDomain(domain.domain) }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.borderless)
                            .help("Delete cookies for \(domain.domain)")
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Storage Usage Tab

    private var usageTab: some View {
        Group {
            if vm.usageEntries.isEmpty {
                emptyState(
                    icon: "externaldrive",
                    title: "No Storage Data",
                    subtitle: "Storage usage will appear here after sites store data."
                )
            } else {
                List {
                    ForEach(vm.usageEntries) { entry in
                        HStack {
                            Text(displayOrigin(entry.origin))
                                .font(OWL.bodyFont)
                                .lineLimit(1)

                            Spacer()

                            Text(StorageViewModel.formatBytes(entry.usage_bytes))
                                .font(OWL.captionFont)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Empty State

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundColor(OWL.textTertiary)
            Text(title)
                .font(OWL.bodyFont)
                .foregroundColor(OWL.textSecondary)
                .accessibilityIdentifier(title == "No Cookies"
                    ? "storageCookiesEmptyTitle"
                    : "storageUsageEmptyTitle")
            Text(subtitle)
                .font(OWL.captionFont)
                .foregroundColor(OWL.textTertiary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier(title == "No Cookies"
                    ? "storageCookiesEmptySubtitle"
                    : "storageUsageEmptySubtitle")
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let error = vm.errorMessage {
                Text(error)
                    .font(OWL.captionFont)
                    .foregroundColor(OWL.error)
                    .lineLimit(1)
            }

            Spacer()

            Button("Clear All Browsing Data...", role: .destructive) {
                vm.showClearAllConfirm = true
            }
            .accessibilityIdentifier("storageClearAllButton")
            .alert("Clear All Browsing Data", isPresented: $vm.showClearAllConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) {
                    vm.confirmClearAll()
                }
            } message: {
                Text("This will delete all cookies, cache, and site storage. This action cannot be undone.")
            }
        }
    }

    // MARK: - Helpers

    private func displayOrigin(_ origin: String) -> String {
        URL(string: origin)?.host ?? origin
    }
}
