# OWL Browser Conventions

## Real/Mock 模式

- `#if canImport(OWLBridge)` 控制编译期 real/mock 切换
- `BrowserViewModel.MockConfig` 用于 ViewModel 单元测试（运行时覆盖编译期开关）
- 单元测试不依赖 Host 进程，通过 MockConfig 注入

## Access Level

- 跨 SPM target 可见的类型用 `package` access level
- 仅模块内部使用的类型用 `internal`（默认）

## Bridge 层

- C-ABI 回调在 main thread（`dispatch_get_main_queue`）
- Swift 侧用 `Task { @MainActor in }` 接收回调
- `OWLBridge_Initialize()` 只能调用一次 → 用 `OWLBridgeSwift.initialize()`（有幂等守卫）
- 修改 `bridge/*.h` 后需重建 OWLBridge.framework（`build_all.sh` 自动处理）

## Host 层

- 服务在 `OWLBrowserContext` 中懒创建（参考 BookmarkService / HistoryService）
- SQLite 数据库使用 WAL 模式，DB 操作在专用线程
- 导航事件通过 `DidFinishNavigation` hook 触发（非手动调用）

## 脚本优先原则

所有构建、启动、测试操作通过 `owl-client-app/scripts/` 执行。

理由：脚本可复用、可审查，会处理环境清理和错误检测。Agent 临时拼的 bash 命令不可复现。

规则：
1. 新操作需要多步骤？→ 先写脚本，再通过脚本执行
2. 调试中发现的有效操作 → 会话结束前固化为脚本
