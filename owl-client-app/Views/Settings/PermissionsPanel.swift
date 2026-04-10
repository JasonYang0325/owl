import SwiftUI

struct PermissionsPanel: View {
    @ObservedObject var vm: SettingsPermissionsViewModel

    var body: some View {
        VStack(spacing: 0) {
            if vm.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.siteGroups.isEmpty {
                emptyState
            } else {
                permissionsList
            }

            Divider()

            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .task {
            async let a: Void = vm.loadAll()
            async let b: Void = vm.checkSystemPermissions()
            _ = await (a, b)
        }
        .accessibilityIdentifier("permissionsPanel")
    }

    // MARK: - Permissions List

    private var permissionsList: some View {
        List {
            ForEach(vm.siteGroups) { group in
                Section {
                    ForEach(group.permissions) { perm in
                        permissionRow(perm: perm, group: group)
                    }
                } header: {
                    Text(displayOrigin(group.origin))
                        .font(OWL.captionFont)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Permission Row

    private func permissionRow(perm: SitePermission, group: SettingsSiteGroup) -> some View {
        let isDisabled = vm.systemDisabledTypes.contains(perm.permissionType)

        return HStack {
            Image(systemName: perm.permissionType.sfSymbol)
                .foregroundStyle(perm.permissionType.iconColor)
                .frame(width: 20)

            Text(perm.permissionType.displayName)
                .font(OWL.bodyFont)

            Spacer()

            if isDisabled {
                Text("在系统设置中已禁用")
                    .font(OWL.captionFont)
                    .foregroundStyle(.secondary)
            }

            Picker("", selection: Binding(
                get: { perm.permissionStatus },
                set: { newStatus in
                    Task { @MainActor in
                        await vm.setPermission(
                            origin: group.origin,
                            type: perm.permissionType,
                            status: newStatus)
                    }
                }
            )) {
                Text("允许").tag(PermissionStatus.granted)
                Text("拒绝").tag(PermissionStatus.denied)
                Text("询问").tag(PermissionStatus.ask)
            }
            .pickerStyle(.menu)
            .frame(width: 90)
            .disabled(isDisabled)
        }
        .opacity(isDisabled ? 0.5 : 1.0)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "lock.slash")
                .font(.system(size: 32))
                .foregroundColor(OWL.textTertiary)
            Text("尚未授予任何站点权限")
                .font(OWL.bodyFont)
                .foregroundColor(OWL.textSecondary)
                .accessibilityIdentifier("permissionsEmptyTitle")
            Text("当网站请求摄像头、麦克风等权限时\n会在此处显示")
                .font(OWL.captionFont)
                .foregroundColor(OWL.textTertiary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("permissionsEmptySubtitle")
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("重置所有权限", role: .destructive) {
                vm.showResetAllConfirm = true
            }
            .accessibilityIdentifier("permissionsResetAllButton")
            .disabled(vm.siteGroups.isEmpty)
            .alert("重置所有权限", isPresented: $vm.showResetAllConfirm) {
                Button("取消", role: .cancel) {}
                Button("重置", role: .destructive) {
                    vm.confirmResetAll()
                }
            } message: {
                Text("将清除所有站点的已存储权限，下次访问时重新询问。")
            }
        }
    }

    // MARK: - Helpers

    private func displayOrigin(_ origin: String) -> String {
        URL(string: origin)?.host ?? origin
    }
}
