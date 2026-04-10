# 权限与安全体系 — Phase 总览

## 概述
- PRD: [docs/prd/permissions.md](../../prd/permissions.md)
- UI 设计稿: [docs/ui-design/permissions/design.md](../../ui-design/permissions/design.md)
- Module 技术参考: [docs/modules/module-c-permissions.md](../../modules/module-c-permissions.md)

## Phase 列表

| Phase | 名称 | 预估行数 | 依赖 | 状态 |
|-------|------|---------|------|------|
| 1 | Host PermissionManager + 持久化 | ~300 | 无 | pending |
| 2 | Mojom + Bridge 权限通道 | ~200 | Phase 1 | pending |
| 3 | 权限弹窗 UI + ViewModel | ~250 | Phase 2 | pending |
| 4 | SSL 安全状态 + 错误页 | ~250 | Phase 1 | pending |
| 5 | 设置页权限管理 | ~150 | Phase 2 | pending |

总预估: ~1150 行（含测试）

## 依赖关系

```
Phase 1 (Host Core)
  ├──→ Phase 2 (Mojom+Bridge)
  │       ├──→ Phase 3 (权限弹窗 UI)
  │       └──→ Phase 5 (设置页)
  └──→ Phase 4 (SSL 安全)
```

## 跨 Phase 接口契约

### Phase 1 → Phase 2
- `OwlPermissionManager` 暴露: `RequestPermission()`, `GetPermission()`, `SetPermission()`, `GetAllPermissions()`, `ResetPermission()`
- `OwlSSLHostStateDelegate` 暴露: `AllowCert()`, `HasAllowedCert()`
- 数据类型: `PermissionType` enum, `PermissionStatus` enum

### Phase 2 → Phase 3/5
- C-ABI 回调: `OWLBridge_PermissionRequestCallback`, `OWLBridge_SSLErrorCallback`
- C-ABI 函数: `OWLBridge_RespondToPermission()`, `OWLBridge_PermissionGetAll()`, `OWLBridge_PermissionReset()`

## 共享决策
- 权限持久化: JSON 文件 (permissions.json)，UI 线程单线程写入
- 安全等级: 4 级 (Secure/Info/Warning/Dangerous)
- notifications 双授权: 系统级 UNUserNotificationCenter + Chromium 级
