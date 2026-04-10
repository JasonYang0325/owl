# Console 与 JS 错误捕获 — PRD

## 1. 背景与目标

OWL Browser 当前无法查看网页的 console 输出和 JS 异常。对于开发者调试和 AI 分析页面状态，这是关键缺失能力。本模块是 AI 浏览器的差异化功能——让 AI 能理解页面运行时状态。

**目标**: 实现 console 消息全栈捕获（Host → Bridge → Swift），右侧面板实时展示，支持级别过滤/文本搜索/复制/清除，以及 CLI 命令和 XCUITest。

**成功指标**:
- 8 个 AC 全部通过自动化测试
- Console 消息状态机正确性：GTest 验证级别映射和消息分发
- 环形缓冲区 1000 条消息，内存占用 < 5MB
- UI 渲染节流：极端高频输出（>100 条/秒）下面板仍可交互

## 2. 用户故事

- **US-001**: As a 开发者, I want 查看页面的 console.log/warn/error 输出, so that 我可以调试网页问题。
- **US-002**: As a 开发者, I want 查看未处理的 JS 异常和错误信息, so that 我可以定位代码 bug。
- **US-003**: As a 用户, I want 按级别过滤 console 消息, so that 我可以快速找到错误。
- **US-004**: As a 开发者, I want 复制 console 消息, so that 我可以分享给团队。
- **US-005**: As a 开发者/AI, I want 通过 CLI 查看 console 输出, so that 自动化脚本可以监控页面运行状态。
- **US-006**: As a 开发者, I want 通过关键字搜索 console 消息, so that 我可以在大量日志中定位目标。

## 验收标准（完整定义）

| AC | 描述 | 输入 | 操作 | 预期输出 |
|----|------|------|------|---------|
| AC-001 | 捕获 console 分级 | 页面执行 `console.log/info/warn/error/debug` | 打开 Console 面板 | 显示对应级别消息，颜色分级（verbose=灰, info=默认, warn=橙, error=红） |
| AC-002 | 捕获 JS 异常 | 页面抛出未处理异常 | 打开 Console 面板 | 显示错误消息 + 源文件:行号（堆栈信息包含在 message 内，不单独解析），级别为 error |
| AC-003 | 实时滚动 | 页面持续输出 console | 观察 Console 面板 | 新消息自动追加到底部，面板自动滚动到最新（用户手动滚动上方则暂停） |
| AC-004 | 级别过滤 | Console 中有混合级别消息 | 点击过滤按钮（All/Verbose/Info/Warning/Error） | 仅显示对应级别的消息，各级别计数 badge 更新 |
| AC-005 | 消息复制 | Console 中有消息 | 选中消息行 → Cmd+C 或右键复制 | 纯文本格式: `[warn] 12:34:56.789 message text\nsource.js:42`。工具栏"复制全部"按钮复制当前过滤视图的所有消息（同格式，换行分隔） |
| AC-006 | 清除 Console | Console 中有消息 | 点击清除按钮 | 所有消息清空，计数归零 |
| AC-007 | CLI console | 页面有 console 输出 | `owl console [--level error] [--limit 20]` | 返回 JSON 格式的 console 消息列表（含 timestamp） |
| AC-008 | XCUITest | 构建完成的 OWL | 运行 XCUITest | 覆盖: (a) Console 面板可打开 (b) console.error 消息可见 (c) 过滤功能 |

## 3. 功能描述

### 3.1 核心流程

#### Console 消息捕获流程
```
网页执行 console.log("hello") / console.error("bug") / throw new Error("crash")
  → Chromium Blink 引擎生成 ConsoleMessage
  → WebContentsObserver::OnDidAddMessageToConsole(
      RenderFrameHost* source_frame,
      blink::mojom::ConsoleMessageLevel log_level,
      const std::u16string& message,
      int32_t line_no,
      const std::u16string& source_id,
      const std::optional<std::u16string>& untrusted_stack_trace)
  → Host: 过滤仅主帧（source_frame->IsInPrimaryMainFrame()）
    映射 blink::mojom::ConsoleMessageLevel → owl::mojom::ConsoleLevel
    截断 message 至 10KB
    timestamp = base::TimeTicks::Now()
  → Mojo: OnConsoleMessage(ConsoleMessage)
  → Bridge C-ABI: console_message_callback(level, message, source, line, timestamp_ms, ctx)
  → Swift: ConsoleViewModel.addMessage(...)
  → SwiftUI: ConsolePanelView 实时更新（节流：最多 5Hz UI 刷新）
```

#### Console 面板开关
```
用户操作：
  - 工具栏右侧面板按钮 → 切换右侧面板 → 选择 Console Tab
  - 或者: 菜单/快捷键 (后续可扩展, 本 Phase 不实现快捷键)

面板状态:
  - 默认隐藏（rightPanel == .none）
  - 打开后显示在右侧，宽度 OWL.rightPanelWidth (360pt)
  - 已有 RightPanelContainer，支持多 Tab（当前有 Downloads Tab）
```

### 3.2 详细规则

**Chromium API（真实签名）**:
```cpp
void OnDidAddMessageToConsole(
    content::RenderFrameHost* source_frame,
    blink::mojom::ConsoleMessageLevel log_level,
    const std::u16string& message,
    int32_t line_no,
    const std::u16string& source_id,
    const std::optional<std::u16string>& untrusted_stack_trace) override;
```

**级别映射**:
| Blink Level | OWL Level | 颜色 | 对应 console API |
|-------------|-----------|------|-----------------|
| kVerbose | verbose | textTertiary | console.debug |
| kInfo | info | textPrimary | console.log, console.info |
| kWarning | warning | OWL.warning (#FF9500) | console.warn |
| kError | error | OWL.error (#FF3B30) | console.error, uncaught exception |

**堆栈信息说明**: Chromium 的 `untrusted_stack_trace` 参数仅在异常时可用，且为未经验证的字符串。OWL 将其追加到 `message` 末尾（换行分隔），不单独解析。`console.table`/`console.group` 等结构化 API 在 Chromium 层已扁平化为文本。

**环形缓冲区规则**:
- 容量: 1000 条消息
- 超出时 FIFO 淘汰最旧消息
- 清除操作: 清空整个缓冲区

**导航清除规则**:
- 默认行为: 页面导航时**自动清除** Console（与 Chrome/Safari 一致）
- "保留日志"开关: Console 工具栏提供 toggle（默认 off），勾选后跨页面保留
- 保留模式下的视觉分割: 在日志列表中插入系统分割线 `--- Navigated to {url} ---`

**消息格式**:
```
[级别图标] [HH:mm:ss.SSS] 消息内容
                           source.js:42
```

**自动滚动规则**:
- 用户在底部 → 新消息自动滚动
- 用户手动滚动到上方 → 停止自动滚动
- 底部显示"新消息 ↓"按钮（可点击回到底部）

**UI 渲染节流**:
- 数据层（环形缓冲区）完整接收所有消息，不丢弃
- UI 层最多每 200ms 批量刷新一次（5Hz），防止高频输出卡顿
- 实现方式: ConsoleViewModel 用 `@Published` 的 debounce 或 Timer batch

### 3.3 异常/边界处理

- **超长消息**: Host 层先合并 message + stack_trace（换行分隔），再截断合并结果至 10KB，UI 显示红色截断标记 `... (已截断至 10KB)`
- **高频输出**: 数据完整保留，UI 节流 5Hz
- **空 source/line**: JS eval 或 inline script 可能无源文件，显示 "(unknown):0"
- **仅主帧**: Host 层过滤 `source_frame->IsInPrimaryMainFrame()`，子帧 console 不捕获

## 4. 非功能需求

- **性能**: LazyVStack 渲染 + 5Hz UI 节流，极端高频下面板仍可交互
- **内存**: 环形缓冲区 1000 条 × ~5KB/条 ≈ 5MB 上限
- **安全**: console 消息可能包含敏感信息，不持久化到磁盘

## 5. 数据模型变更

### Mojom 新增
```mojom
enum ConsoleLevel {
  kVerbose,
  kInfo,
  kWarning,
  kError,
};

struct ConsoleMessage {
  ConsoleLevel level;
  string message;       // 截断至 10KB，异常时含 stack trace
  string source;        // 源文件 URL
  int32 line_number;    // 行号，0 表示未知
  double timestamp;     // Host 层 base::TimeTicks::Now() 转 seconds since epoch
};

// WebViewObserver 新增:
OnConsoleMessage(ConsoleMessage message);
```

### Bridge C-ABI 新增
```c
typedef void (*OWLBridge_ConsoleMessageCallback)(
    int level, const char* message, const char* source,
    int line, double timestamp, void* ctx);
OWL_EXPORT void OWLBridge_SetConsoleMessageCallback(
    uint64_t webview_id, OWLBridge_ConsoleMessageCallback cb, void* ctx);
```

### CLI 新增命令
```
owl console [--level error|warning|info|verbose] [--limit 50]
→ JSON: [{ "level": "error", "message": "...", "source": "...", "line": 42, "timestamp": "2026-04-05T..." }]
```

单标签模式下默认取 active tab 的 console。CLI 层将 `double timestamp` 转为 ISO 8601 UTC 字符串输出。

## 6. 影响范围

| 模块 | 影响 |
|------|------|
| `mojom/web_view.mojom` | ConsoleLevel enum + ConsoleMessage struct + OnConsoleMessage |
| `host/owl_real_web_contents.mm` | OnDidAddMessageToConsole 回调（含主帧过滤+截断+timestamp） |
| `host/owl_web_contents.h` | 无变更（Observer 接口由 Mojom 自动生成） |
| `bridge/owl_bridge_api.h/.cc` | Console callback typedef + setter + Observer 转发 |
| `bridge/OWLBridgeWebView.mm` | OnConsoleMessage stub |
| `owl-client-app/ViewModels/ConsoleViewModel.swift` | 🆕 环形缓冲+过滤+搜索+节流 |
| `owl-client-app/Views/Panel/ConsolePanelView.swift` | 🆕 Console 面板 |
| `owl-client-app/Views/Panel/ConsoleRow.swift` | 🆕 单条消息行 |
| `owl-client-app/Views/Panel/RightPanelContainer.swift` | 修改: 添加 Console Tab |
| `owl-client-app/ViewModels/BrowserViewModel.swift` | 修改: ConsoleViewModel 实例 + callback 注册 |
| `owl-client-app/CLI/Commands/ConsoleCommand.swift` | 🆕 CLI 命令 |
| `owl-client-app/UITests/OWLConsoleUITests.swift` | 🆕 XCUITest |
| 所有 Observer 实现 + test doubles | 修改: OnConsoleMessage stub |

## 7. 里程碑 & 优先级

本模块属于项目整体 P2。内部功能排序：

| 优先级 | 功能 | AC |
|--------|------|----|
| P2-Critical | Console 消息全栈传递（含 timestamp） | AC-001, AC-002 |
| P2-Critical | Console 面板 UI + 实时滚动 | AC-003 |
| P2-High | 级别过滤（含 Verbose）+ 文本搜索 | AC-004 |
| P2-High | 复制（单条+全部）+ 清除 | AC-005, AC-006 |
| P2-Normal | CLI 命令 | AC-007 |
| P2-Normal | XCUITest | AC-008 |

## 8. 已决策事项

1. **消息持久化**: 不持久化，仅内存环形缓冲区
2. **导航清除**: 默认自动清除，提供"保留日志"开关（与 Chrome/Safari 一致）
3. **截断策略**: Host 层截断消息至 10KB，UI 显示明确截断标记
4. **堆栈信息**: Chromium `untrusted_stack_trace` 追加到 message 末尾，不单独解析字段
5. **AI 集成**: 推迟到 AI Chat 模块（数据模型兼容，ConsoleViewModel 可被 AI 模块消费）
6. **timestamp**: Host 层生成（base::TimeTicks::Now() → seconds since epoch），通过 Mojom/Bridge 传递
7. **UI 节流**: 数据完整保留，UI 渲染最多 5Hz（200ms batch），防高频卡顿
8. **子帧过滤**: 仅捕获主帧 console（source_frame->IsInPrimaryMainFrame()）
