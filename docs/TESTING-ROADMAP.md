# OWL Browser 测试建设路线图

> 2026-04-09 补充审计见 `docs/testing-harness-coverage-audit-2026-04-09.md`，该文档提供模块级覆盖矩阵与 P0/P1 补强清单。

> 测试能力现状与背景分析。具体任务跟踪见 [BACKLOG.md](BACKLOG.md)（单一来源）。

## 当前测试能力

| 层级 | 参数 | 实际测试数 | 状态 |
|------|------|----------|------|
| C++ GTest | `cpp` | 600+ | 稳定（当前环境 `owl_client_unittests` 可能被跳过） |
| Swift 单元测试 | `unit` | 467+ | 稳定 |
| Swift Integration | `integration` | 8 | 已落地（跨层关键旅程） |
| Pipeline E2E | `pipeline` | 33 | 稳定可退出 |
| XCUITest | `xcuitest` | ~19 | 2个失败，需签名 |
| CGEvent 系统测试 | `system` | ~5 | 需前台窗口 |

## 已知阻塞项

### A1. Mirror Test 结构性限制 (P0)

**问题**: C++ GTest 无法实例化 `content::WebContents`，导致 `HandleContextMenu`、`ExecuteContextMenuAction` 等函数只能通过"镜像测试"（在测试文件中重新实现算法）验证。镜像与真实代码可能漂移。

**影响**: Context Menu 的 40 个新测试全部是镜像测试。evaluator 假阳性风险评分 2-4/10。

**解决方案（按优先级）**:
1. **P0: 提取可测试逻辑到独立文件**
   - 将 `DetermineContextMenuType()`、`TruncateSelectionText()`、URL scheme 过滤等纯函数从 `owl_real_web_contents.mm` 提取到 `host/owl_context_menu_utils.h/.cc`
   - GTest 直接 include 测试真实函数，消除镜像
   - 预估: ~50 行新文件 + ~30 行测试重构
2. **P1: 增加 Mojo 集成测试**
   - 使用 `content::TestWebContents` mock 构建轻量级集成测试
   - 验证 HandleContextMenu → OnContextMenu → ExecuteContextMenuAction 完整路径
   - 需要调研 TestWebContents 在 OWL 项目中的可行性
3. **P2: XCUITest 覆盖真实路径**
   - AC-006 要求 XCUITest 端到端覆盖所有 AC
   - 需要解决签名、测试 HTML 页面、右键模拟等问题

### A2. XCUITest 基础设施不完善 (P1)

**问题**:
- 需要 Apple 开发者账号签名
- 2 个已有测试失败（find next、search timeout）
- 右键菜单在 WebView 中的 XCUITest 模拟可能不稳定
- 依赖外网资源（如 placeholder 图片服务）不适合 CI

**解决方案**:
1. 使用本地 HTTP server 托管测试页面（已有 TestHTTPServer）
2. 测试图片用 base64 inline data URI 或本地文件
3. 右键模拟用 `.rightClick()` + 坐标定位
4. 签名问题需用户手动配置开发者账号

### A3. Pipeline 测试生命周期过短（已缓解）

**原问题**: Pipeline 测试生命周期过短，且偶发长时间无输出。

**已实施**:
- `run_tests.sh pipeline` 已增加 timeout 兜底（`perl alarm`）
- 过滤器收敛到 `OWLBrowserTests.OWLBrowserTests`
- pipeline 现可稳定 33/33 通过并退出

### A4. Swift 测试挂起（已修复）

**原问题**: `swift test` 在 pipeline 层偶发不退出（Host 生命周期收尾异常）。

**修复**:
- 修正 `OWLTestBridge` 中多处 C-ABI callback 签名错位（避免测试进程崩溃后遗留 Host）
- `shutdown()` 增强为 `SIGTERM + 超时 + SIGKILL` 回收策略
- `run_tests.sh pipeline` 过滤器收窄到 `OWLBrowserTests.OWLBrowserTests`，避免误拉起 GUI 依赖的 `OWLSystemEventTests`

**现状**: pipeline 可稳定产出并退出；脚本保留 timeout 作为兜底防护。

### A5. Cross-layer Integration Harness（已修复）

**原问题**: `OWLTestKit` / `OWLIntegrationTests` 为 placeholder，中间层缺失。

**修复**:
- `TestKit` 新增 `AppHost / WaitHelper / ProcessGuard`
- `OWLIntegrationTests` 替换为真实跨层用例（导航 + JS 断言 + 输入事件）
- `run_tests.sh` 新增 `integration` 层，并接入默认 `e2e`

**现状**: `swift test --filter OWLIntegrationTests.OWLIntegrationTests` 稳定通过。

## 建设需求（按优先级）

### P0: 消除镜像测试

| 任务 | 描述 | 预估 |
|------|------|------|
| 提取 context_menu_utils | 将纯函数从 owl_real_web_contents.mm 提取到独立 .h/.cc | 2h |
| 重构 GTest | 替换镜像 helper 为真实函数 include | 1h |
| 验证 | 确认 388 个测试仍全绿 | 0.5h |

### P1: 补充 XCUITest (AC-006)

| 任务 | 描述 | 预估 |
|------|------|------|
| 创建测试 HTML | context-menu-test.html（含链接、图片、文本、input） | 0.5h |
| 编写 XCUITest | ContextMenuXCUITests.swift，覆盖 AC-001~005f | 3h |
| 签名配置 | resign_for_testing.sh 适配 | 0.5h |

### P2: 增加集成测试层

| 任务 | 描述 | 预估 |
|------|------|------|
| 调研 TestWebContents | 确认在 OWL 项目中是否可用 | 1h |
| Mojo 往返测试 | HandleContextMenu → Observer → Bridge → 回调完整路径 | 3h |

## Flow 中的测试策略建议

### Agent 调度模式（基于本次 session 教训）

```
评审只有 Claude agents:
  → 前台并行（单条消息多个 Agent tool call）

评审有 Claude + Codex/Gemini:
  → Claude agents: background
  → Codex/Gemini llm-review.sh: 前台 bash（阻塞）
  → 不要用 bash for 循环轮询 agent 进度
```

### test 阶段规则

- IMPL_BUG → 报告给用户，不在 test 阶段修改实现
- 镜像测试标注: 文件头部 NOTE 说明"这些是 Host 逻辑的镜像"
- 新模块开发时优先创建 `*_utils.h/.cc`，避免镜像

## 变更日志

- 2026-04-04: 初始创建，基于 Module E (Context Menu) flow retrospective
