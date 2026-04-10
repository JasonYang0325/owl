# OWL Browser — 统一待办清单

> 所有待完成工作的**单一来源**。`/flow` 从此文件选取下一个任务。

## 条目格式

每个条目使用统一字段，脚本可通过 `grep "^- \[" | grep "TODO"` 提取：

```
- [ID] P优先级 | 状态 | 估时 | 依赖 | 描述
  范围: ...
  验收: ...
```

**状态枚举**: `TODO` `IN_PROGRESS` `BLOCKED` `DONE`
**优先级**: `P0`(阻断) `P1`(质量) `P2`(优化)

---

## 模块开发（Module A-L）

来源: `docs/modules/README.md`。每个 pending 模块至少占一条。

- [MOD-B] P0 | DONE | - | 无 | 下载管理系统（Host+Bridge+Swift 全栈）
- [MOD-E-SWIFT] P0 | DONE | 4h | MOD-E-HOST done | Module E Swift 客户端: ContextMenuHandler + NSMenu 构建 + 坐标转换
  范围: 新增 ContextMenuHandler.swift, 注册 C-ABI 回调, 5 种菜单类型, 本地操作 NSPasteboard, Host 操作 ExecuteContextMenuAction
  验收: 右键弹出菜单，操作正确执行
  参考: docs/ui-design/context-menu/design.md
- [MOD-E-XCUI] P0 | DONE | 4h | MOD-E-SWIFT | Module E XCUITest AC-006: 端到端验收（编译通过，运行需签名+GUI）
  范围: 测试 HTML 页面 + ContextMenuXCUITests.swift, 覆盖 AC-001~005f
  验收: XCUITest 全绿
  阻塞: XCUITest 签名配置（需 Apple 开发者账号）
- [MOD-C] P1 | DONE | - | 无 | 权限与安全体系（全栈已实现：Host+Bridge+Swift+Tests）
- [MOD-D] P1 | DONE | - | OWL-CLI | Cookie 与存储管理（CLI + UI 全栈完成）
- [MOD-F] P1 | TODO | - | 无 | 导航事件与错误处理（待 task-split）
- [MOD-G] P2 | TODO | - | 无 | Console 与 JS 错误捕获（待 task-split）
- [MOD-H] P2 | TODO | - | MOD-A | 多标签增强（待 task-split）
- [MOD-I] P2 | TODO | - | MOD-C,MOD-D | 设置与偏好系统（待 task-split）
- [MOD-J] P3 | TODO | - | 无 | 打印支持
- [MOD-K] P2 | TODO | - | 无 | 网络请求监控
- [MOD-L] P3 | TODO | - | 无 | 全屏与媒体控制

## 技术债与修复

- [E-UTILS] P1 | DONE | 3h | 无 | 消除 context menu 镜像测试: 提取到 owl_context_menu_utils.h/.cc
- [E-SECURITY] P1 | DONE | 0.5h | 无 | 已确认无 NOTREACHED()，全部为 LOG(WARNING)
- [E-MAILTO] P2 | TODO | 0.5h | 无 | kCopyLink 支持 mailto: scheme
- [TEST-UTF8] P2 | DONE | - | E-UTILS | UTF-8 截断镜像差异（E-UTILS 提取后自动消除）
- [TEST-HARNESS-AUDIT] P1 | DONE | 2h | 无 | 测试 harness 覆盖审计与补强矩阵
  范围: 形成模块级覆盖矩阵、识别默认门禁缺口、梳理 P0/P1 补强优先级
  产物: `docs/testing-harness-coverage-audit-2026-04-09.md`
- [TEST-INTEGRATION-HARNESS] P0 | DONE | 1d | 无 | 建立最小可用 cross-layer integration harness
  范围: 实现 `OWLTestKit` 最小能力（AppHost / WaitHelper / ProcessGuard），替换 `OWLIntegrationTests` placeholder
  验收: `swift test --filter OWLIntegrationTests.OWLIntegrationTests` 稳定通过（真实 C-ABI → Mojo → Host → Renderer 链路）
  完成: 新增 `AppHost.swift`/`WaitHelper.swift`/`ProcessGuard.swift`，`run_tests.sh` 新增 `integration` 层并并入默认 `e2e`
- [TEST-PIPELINE-STABILITY] P0 | DONE | 0.5d | 无 | 修复 pipeline 挂起与生命周期过短
  范围: 修复 `OWLTestBridge` callback 签名错位崩溃、增强 Host 退出回收；`run_tests.sh pipeline` 精确过滤到 `OWLBrowserTests.OWLBrowserTests`
  验收: `swift test --filter OWLBrowserTests.OWLBrowserTests` 稳定输出并退出；`run_tests.sh pipeline` 33/33 通过
- [TEST-TABS-HERMETIC] P0 | DONE | 0.5d | 无 | 修复 Tabs 单测误入真实 bridge 路径
  范围: 隔离 `TabViewModel.navigate()` 对真实 `OWLBridge_Navigate` 的依赖，避免 unit 环境 crash
  验收: `Phase4PinUndoCloseTests` 稳定运行，不因 bridge 未初始化而崩溃
- [TEST-PERMISSIONS-STABILITY] P0 | DONE | 0.25d | 无 | 修复权限超时测试失败与行为漂移
  范围: 修复 `PermissionViewModelTests.testTimeout_toastMessage` 失败，确认 toast 行为与产品一致
  验收: 权限测试套件稳定全绿
- [TEST-STORAGE-COVERAGE] P0 | DONE | 1d | MOD-D done | 建立 Storage / Cookies 测试体系
  范围: 新增 `StorageViewModelTests`、Settings 面板交互测试、clear-data / delete-domain 失败路径
  验收: cookie list/delete、storage usage、clear-data 主流程均有 unit 或 UI 证据
- [TEST-ADDRESSBAR-E2E] P0 | IN_PROGRESS | 1d | TEST-PIPELINE-STABILITY | 补齐 Address Bar 壳层专项测试
  范围: 覆盖 focus / blur / full URL display / Enter navigate / command+a 替换输入 / 多标签路由
  验收: 不依赖外网的本地页面用例稳定通过
  进展: 已新增本地 HTTP fixture + deterministic XCUITest，覆盖 Enter navigate / Cmd+A 替换输入 / 多标签路由；focus 后显示 full URL 仍暴露为已知缺陷并以 `XCTExpectFailure` 跟踪
- [TEST-CLI-SEMANTICS] P0 | DONE | 0.5d | OWL-CLI done | 将 CLI 从 smoke test 升级为语义测试
  范围: 为 page/cookie/storage/bookmark/history 增加 JSON、过滤参数、错误码、副作用断言
  验收: `test_cli.sh` 不再只检查 exit code
- [TEST-SETTINGS-SMOKE] P0 | DONE | 0.5d | MOD-I | 补齐 Settings UI 最小 smoke 覆盖
  范围: 至少覆盖 Settings 打开、Tab 切换、PermissionsPanel、StoragePanel 两个高风险面板
  验收: 用户可见设置入口有可重复 UI 验证
  完成: 已补设置入口/面板 accessibility 标识，改为可稳定进入 AX 树的 in-window modal，并新增 XCUITest smoke case 验证 Settings 打开、Permissions/Storage tab 切换与存储子视图切换
- [TEST-BOOKMARK-PERSISTENCE] P1 | TODO | 0.5d | 无 | 补书签持久化与地址栏星标链路
  范围: 地址栏 star button、重启后书签保留、CLI bookmark 语义检查
  验收: add/remove/list/navigate 与持久化闭环
- [TEST-DOWNLOAD-PERSISTENCE] P1 | TODO | 0.5d | MOD-B done | 补下载文件落盘与重启场景
  范围: 本地 HTTP 下载、临时目录落盘、completed item 重启后保留
  验收: 下载不仅“UI 显示成功”，且文件真实可验证
- [TEST-CONSOLE-MULTITAB] P1 | TODO | 0.5d | MOD-G | 补 Console 多标签与重载场景
  范围: 多 tab 隔离、reload 后消息行为、长日志 ring buffer 验证
  验收: Console 行为在真实浏览器流程中稳定
- [TEST-HISTORY-PERSISTENCE] P1 | TODO | 0.5d | MOD-A done | 补历史持久化与异常恢复测试
  范围: 重启后历史仍在、损坏数据恢复路径
  验收: 历史不仅在内存态正确，且持久化可信
- [TEST-CONTEXTMENU-INTEGRATION] P1 | TODO | 0.5d | E-UTILS done | 补 Context Menu 完整 Host->Bridge 集成测试
  范围: `HandleContextMenu -> Observer -> Bridge -> ExecuteAction` 真链路验证
  验收: 减少对 mirror helper 的依赖
- [TEST-AI-SOCKET-CONTRACT] P2 | TODO | 0.5d | 无 | 为 AI / Socket 模块建立基础 contract tests
  范围: service 协议、socket 协议、异常输入处理
  验收: AI / IPC 不再完全游离于主测试面之外
- [TEST-ARCH-GUIDANCE] P0 | TODO | 1d | 无 | 按风险分层固化全栈测试对齐
  范围: 将 `docs/ARCHITECTURE.md` 的测试层级映射与 `docs/TESTING-ROADMAP.md` 的借鉴实践映射为 PR 强制执行清单
  验收: 通过 `check_harness_quality.py` 与 `check_docs_consistency.py` 后，出现任一关键层缺失自动阻断
- [TEST-UPGRADE-SMOKE] P0 | TODO | 0.5d | TEST-ARCH-GUIDANCE | 建立 Chromium 升级回归触发套件
  范围: 以 Chromium 版本窗口为触发条件，新建 `chromium_compat_smoke` 任务列表（兼容性冒烟 + 关键 web_api）
  验收: 升级窗口发布时，相关关键测试自动触发并输出失败归因日志
- [TEST-FLAKY-TRIAGE] P0 | TODO | 1d | TEST-ARCH-GUIDANCE | 建立稳定可执行 flake 治理闭环
  范围: 统一 flaky 标签定义，维护可过期黑名单，新增周报输出“连续抖动/超标比例”
  验收: `run_harness_maintenance` 周期报告中显示每周新增/移除的 flaky 列表与解禁日期
- [TEST-ARTIFACT-STD] P1 | TODO | 0.5d | TEST-ARCH-GUIDANCE | 统一失败标准化产物与重跑策略
  范围: 所有可执行套件失败时强制产出日志、截图/trace（可用时）、case 指纹；业务失败禁止盲目重试
  验收: 失败工单从 `harness_playbook.md` 可直接复现到固定命令与上下文
- [TEST-UI-SMOKE-CORE] P1 | TODO | 1d | TEST-ARCH-GUIDANCE | 收敛 XCUITest 高价值冒烟集合
  范围: 将 XCUITest 收敛为 ≤5 条核心用例（启动/导航/权限弹窗/下载/核心设置）
  验收: 通过 `run_tests.sh xcuitest` 每次提交可获得稳定冒烟结果（非签名/GUI 时跳过）
- [TEST-SECURITY-BASELINE] P1 | TODO | 1d | 测试框架与服务边界梳理 | 建立权限/ACL/同步高风险回归路径
  范围: 增补权限模型、会话/同步隔离、可注入输入的负向用例；最小 fuzz/坏输入回归
  验收: 关键风险域具备跨层 unit + integration 最低闭环
- [TEST-LOCAL-RESILIENCE] P2 | TODO | 0.5d | TEST-FLAKY-TRIAGE | 统一测试依赖本地化与可复现素材
  范围: 所有 UI 套件剥离外网依赖，统一本地 HTTP/fixture 与 data URI 资源模板
  验收: `flow` 与 CI 日志中不再出现外网占位资源导致的随机失败

## Flow 基础设施

- [FLOW-EVAL-DIM] P1 | DONE | 1h | 无 | 评审维度标准化: 统一为 correctness/coverage/quality/security
- [FLOW-SKIP] P1 | DONE | 1h | 无 | structural_note + min>=5 自动 STRUCTURAL_PASS
- [FLOW-TPL-VAR] P2 | DONE | 0.5h | 无 | orchestrator sed 自动替换模板变量
- [OWL-CLI] P0 | DONE | 6h | 无 | OWL CLI 骨架: ArgumentParser + Unix socket IPC + 命令路由
  范围: CLI 入口、socket server/client、JSON 协议、NavigationCommands（owl navigate/back/forward/reload）
  验收: `owl page info` 返回当前页面 JSON
  参考: docs/design/agent-api-layer.md
- [INFRA-PIPELINE] P2 | DONE | 2h | 无 | Pipeline 测试生命周期: 增加 timeout 与稳定收敛
- [INFRA-SWIFT] P2 | DONE | - | - | Swift 测试挂起（已收敛，保留 timeout 兜底）
- [INFRA-HARNESS-CODEDRIVEN] P0 | DONE | 0.5d | TEST-INTEGRATION-HARNESS | 构建代码驱动 harness（策略+产物+稳定性门禁）
  范围: 新增 `scripts/harness_policy.json` 与 `scripts/run_harness.py`，输出 summary/cases/junit/report，支持 retry+flake gate
  验收: `run_tests.sh harness` 可作为默认 `e2e` 入口，非文档驱动
- [INFRA-HARNESS-USECASE-GATE] P0 | DONE | 0.5d | INFRA-HARNESS-CODEDRIVEN | 增加 use-case 覆盖门禁与确定性产物
  范围: policy 增加 `use_cases`/`required_use_cases` 与 case 发现阈值；harness 输出 case inventory/usecase coverage/playbook/manifest
  验收: harness 可直接判断“关键用户用例是否被执行并通过”，且产物可供 agent 稳定消费
- [FLOW-STATE-GUARD] P0 | DONE | 1h | 无 | Flow 状态转移强制校验 + test-review 跳过优化
  范围: flow-orchestrator.sh 增加 validate_phase_transition() + test-review 自动推进
  完成: test-review 从 GAN phase 移除（v3 优化）；新增状态转移校验函数

## 已完成（超过 20 条后移至 docs/ARCHIVE.md）

- [MOD-A] DONE | 2026-03-31 | 浏览历史系统
- [MOD-B] DONE | 2026-04-03 | 下载管理系统
- [MOD-E-HOST] DONE | 2026-04-04 | Context Menu Host+Bridge（388 GTest, 23 次 flow 迭代）
- [MOD-E-SWIFT] DONE | 2026-04-04 | Context Menu Swift 客户端（评审 PASS 9/9/9/9）
- [MOD-E-XCUI] DONE | 2026-04-04 | Context Menu XCUITest（编译通过，运行需签名）
- [FLOW-SETUP-BUG] DONE | 2026-04-04 | flow-setup.sh 完成状态 active 未重置
- [FLOW-TPL] DONE | 2026-04-04 | Stop hook 模板外置（3 个模板文件）
- [FLOW-DISPATCH] DONE | 2026-04-04 | Agent 调度策略 Golden Rule（已强化为禁止 run_in_background）
- [FLOW-RUN-TESTS] DONE | 2026-04-04 | orchestrator 补充 run_tests sub_step 处理
