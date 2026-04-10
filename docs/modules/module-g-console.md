# Module G: Console 与 JS 错误捕获

| 属性 | 值 |
|------|-----|
| 优先级 | P2 |
| 依赖 | 无 |
| 预估规模 | ~400 行 |
| 状态 | pending |

## 目标

捕获网页的 `console.log/warn/error` 输出和 JS 异常，在 OWL 右侧面板展示。这是 AI 浏览器的差异化能力——让 AI 能理解页面运行状态。

## 用户故事

As a 开发者/AI 用户, I want 查看页面的 console 输出和 JS 错误, so that 我可以调试网页问题或让 AI 分析页面状态。

## 验收标准

- AC-001: 捕获 `console.log/info/warn/error` 并分级显示
- AC-002: 捕获未处理的 JS 异常（含堆栈）
- AC-003: 右侧面板 Console Tab 实时滚动显示
- AC-004: 支持按级别过滤（All/Error/Warning/Info）
- AC-005: 消息可复制
- AC-006: 可清除 Console
- AC-007: AI Chat 可引用 Console 错误作为上下文

## 技术方案

### 层级分解

#### 1. Host C++

实现 `WebContentsObserver::OnDidAddMessageToConsole()`：
- 参数：`log_level`、`message`、`source_url`、`line_number`
- 映射 `blink::mojom::ConsoleMessageLevel` → OWL 枚举

#### 2. Mojom（扩展 `web_view.mojom`）

```
enum ConsoleLevel {
  kVerbose,
  kInfo,
  kWarning,
  kError,
};

struct ConsoleMessage {
  ConsoleLevel level;
  string message;
  string source;
  int32 line_number;
  mojo_base.mojom.TimeTicks timestamp;
};

// WebViewObserver 新增:
OnConsoleMessage(ConsoleMessage message);
```

#### 3. Bridge C-ABI

```c
typedef void (*OWLBridge_ConsoleMessageCallback)(
    int level, const char* message, const char* source, int line, void* ctx);
OWL_EXPORT void OWLBridge_SetConsoleMessageCallback(OWLBridge_ConsoleMessageCallback cb, void* ctx);
```

#### 4. Swift ViewModel (`ViewModels/ConsoleViewModel.swift`)

- 环形缓冲区（最近 1000 条消息）
- `@Published var messages: [ConsoleMessage]`
- `@Published var filter: ConsoleLevel?`
- `var errorCount: Int`（badge 用）

#### 5. SwiftUI Views

- `ConsolePanelView`: 右侧面板 Console Tab
- `ConsoleRow`: 单条消息（颜色分级 + source:line）
- 过滤工具栏（All / Errors / Warnings）
- 清除按钮

## 测试计划

| 层级 | 测试内容 |
|------|---------|
| C++ GTest | ConsoleMessage 级别映射、Observer 分发 |
| Swift ViewModel | 环形缓冲区、过滤逻辑 |
| E2E Pipeline | EvaluateJS("console.error('test')") → 验证回调 |

## 文件清单

| 操作 | 文件 |
|------|------|
| 修改 | `mojom/web_view.mojom`（ConsoleMessage + Observer） |
| 修改 | `host/owl_real_web_contents.mm`（OnDidAddMessageToConsole） |
| 修改 | `host/owl_web_contents.h/.cc` |
| 修改 | `bridge/owl_bridge_api.h/.cc` |
| 新增 | `owl-client-app/ViewModels/ConsoleViewModel.swift` |
| 新增 | `owl-client-app/Views/Panel/ConsolePanelView.swift` |
| 新增 | `owl-client-app/Views/Panel/ConsoleRow.swift` |
| 修改 | `owl-client-app/Views/Panel/RightPanelContainer.swift`（添加 Console Tab） |
