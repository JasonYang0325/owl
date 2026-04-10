# Phase 8: 清理与维护 (BH-003, BH-010, BH-026, BH-027)

## Goal
补充测试、清理多 Tab 资源泄漏、修复 UI 闪烁、统一 Mojom 参数名。

## Scope
- **Modified**: `bridge/owl_bridge_api.cc` (test only), `host/owl_real_web_contents.mm`, `owl-client-app/Views/Sidebar/HistorySidebarView.swift`, `mojom/web_view.mojom`, related files
- **Layers**: Bridge + Host + Swift + Mojom

## Dependencies
- BH-010 depends on Phase 1 (webview_id-keyed map)

## Items

### BH-003: Download dispatch_async 补测试
- 代码已安全（ObjC block 按值捕获 std::string）
- 仅补充 GTest 验证此行为

### BH-010: RealDetachObserver 按 webview_id 清理
- detach 时按 webview_id 从 flat_map 查找删除
- 关闭非活跃 tab 后正确释放 RealWebContents
- 依赖 Phase 1 的重新键控 map

### BH-026: HistorySkeletonView 随机宽度
- `.random(in:)` → 预计算 `static let` 数组
- 手动验收

### BH-027: Mojom 参数名
- `size_in_pixels` → `size_in_dips`
- 同步更新所有引用（Mono-repo 同步编译）

## Acceptance Criteria
- [ ] GTest: Download 事件回调字符串生命周期正确
- [ ] GTest: 关闭非活跃 tab 后 RealWebContents 被删除
- [ ] 手动: HistorySkeletonView 无闪烁
- [ ] 编译: Mojom 参数名更新后全部编译通过
- [ ] 新增测试 ≥ 3

## Status
- [ ] Tech design review
- [ ] Development
- [ ] Code review
- [ ] Tests pass
