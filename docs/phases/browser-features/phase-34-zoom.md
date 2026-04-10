# Phase 34: Zoom 控制

## 目标

用户可以通过快捷键或 UI 控制页面缩放级别。

## 范围

### 修改文件

| 层级 | 文件 | 变更 |
|------|------|------|
| Mojom | `mojom/web_view.mojom` | +SetZoomLevel, +GetZoomLevel, +OnZoomLevelChanged |
| Host stub | `host/owl_web_contents.h/.cc` | +SetZoomLevel/GetZoomLevel + g_real_* |
| Host real | `host/owl_real_web_contents.h/.mm` | +HostZoomMap 集成 |
| ObjC++ Bridge | `bridge/OWLBridgeWebView.h/.mm` | +setZoomLevel/getZoomLevel |
| C-ABI | `bridge/owl_bridge_api.h/.cc` | +OWLBridge_SetZoomLevel, +GetZoomLevel, +SetZoomCallback |
| Swift VM | `ViewModels/TabViewModel.swift` | +zoomLevel 属性, +zoomIn/zoomOut/resetZoom |
| SwiftUI | `Views/TopBar/AddressBarView.swift` | zoom level 显示（非 100% 时） |
| SwiftUI | `Views/BrowserWindow.swift` | Cmd+/Cmd-/Cmd+0 快捷键 |
| Tests | `host/owl_web_contents_unittest.cc` | +Zoom 单元测试 |
| Tests | `Tests/OWLBrowserTests.swift` | +Zoom E2E 测试 |

## 依赖

- 无前置 phase 依赖
- Chromium 依赖：`content::HostZoomMap`, `blink::PageZoomLevelToZoomFactor()`

## 技术要点

### Chromium Zoom API

```cpp
// 设置 zoom level（0.0 = 100%，正值放大，负值缩小）
// Round 1 P1 fix: API 名称为 SetZoomLevel（非 SetZoomLevelForWebContents）
content::HostZoomMap::SetZoomLevel(web_contents, level);

// 获取当前 zoom level
double level = content::HostZoomMap::GetZoomLevel(web_contents);

// Zoom level ↔ factor 转换
// Round 1 P2 fix: API 名称为 ZoomLevelToZoomFactor（非 PageZoomLevelToZoomFactor）
double factor = blink::ZoomLevelToZoomFactor(level);  // 0.0 → 1.0
double level = blink::ZoomFactorToZoomLevel(factor);   // 1.0 → 0.0

// Round 1 P0 fix: 正确的 zoom level ↔ 百分比对照表
// 公式：factor = pow(1.2, level), percent = factor * 100
// level  factor  percent
// -7.6   0.25    25%
// -2.2   0.63    63%
// -1.2   0.80    80%
//  0.0   1.00    100%
//  1.0   1.20    120%
//  1.2   1.24    124%   (≈125%)
//  2.2   1.60    160%
//  3.8   2.07    207%   (≈200%)
//  5.6   3.00    300%
//  8.8   5.16    516%   (≈500%)
```

### Mojom 接口设计

```mojom
// WebViewHost 新增
SetZoomLevel(double level) => ();
GetZoomLevel() => (double level);

// WebViewObserver 新增
OnZoomLevelChanged(double new_level);
```

### C-ABI 设计

```c
OWL_EXPORT void OWLBridge_SetZoomLevel(uint64_t webview_id, double level,
                                        OWLBridge_ZoomCallback callback, void* ctx);
OWL_EXPORT void OWLBridge_GetZoomLevel(uint64_t webview_id,
                                        OWLBridge_GetZoomCallback callback, void* ctx);
typedef void (*OWLBridge_ZoomChangedCallback)(double new_level, void* ctx);
OWL_EXPORT void OWLBridge_SetZoomChangedCallback(uint64_t webview_id,
                                                   OWLBridge_ZoomChangedCallback callback, void* ctx);
```

### Swift 层

```swift
// TabViewModel 新增
@Published var zoomLevel: Double = 0.0  // 0.0 = 100%
var zoomPercent: Int { Int(round(pow(1.2, zoomLevel) * 100)) }

func zoomIn() { setZoom(zoomLevel + 0.6) }   // 约 +25%
func zoomOut() { setZoom(zoomLevel - 0.6) }   // 约 -25%
func resetZoom() { setZoom(0.0) }
```

### UI 行为

- Cmd+= (或 Cmd+Shift+=) 放大
- Cmd+- 缩小
- Cmd+0 重置为 100%
- 非 100% 时在地址栏右侧显示百分比（如 "125%"），点击重置
- Cmd+鼠标滚轮缩放（可选，P2）

### 已知陷阱

- Zoom level 不是线性的：level 0.6 ≈ 125%，不是 160%
- Round 1 P1 fix: HostZoomMap::SetZoomLevel 实际是 per-host 存储（非 per-tab）。单 tab 模式下等价于 per-tab。未来多 tab 时同 host 的不同 tab 会共享 zoom level，这是 Chromium 默认行为（与 Chrome 一致）
- SetZoomLevel 后 Chromium 会自动重新布局，不需要额外 resize

## 验收标准

- [ ] AC-001: Cmd+= 放大页面，页面内容变大
- [ ] AC-002: Cmd+- 缩小页面，页面内容变小
- [ ] AC-003: Cmd+0 重置为 100%
- [ ] AC-004: 非 100% 时地址栏区域显示当前缩放百分比
- [ ] AC-005: 缩放级别在 25%~500% 范围内有效（超范围忽略）
- [ ] AC-006: C++ 单元测试覆盖 SetZoomLevel/GetZoomLevel
- [ ] AC-007: E2E 测试验证 zoom 功能

---

## 技术方案

### 1. 架构设计

**复用 Phase 33 全栈模式**：Mojom → Host C++ (stub/real) → C-ABI → Swift VM → SwiftUI。Zoom 比 Find 更简单——纯同步 get/set，无增量回调、无 request_id。

**数据流（SetZoomLevel）**：
```
用户按 Cmd+=
  │
  BrowserWindow 键盘快捷键
  │
  TabViewModel.zoomIn() → setZoom(currentLevel + step)
  │
  OWLBridge_SetZoomLevel(1, level, callback, ctx)
  │
  IO thread → remote_->SetZoomLevel(level)
  │
  OWLWebContents::SetZoomLevel → g_real_set_zoom_func(level)
  │
  RealSetZoom → HostZoomMap::SetZoomLevel(web_contents_, level)
  │
  Chromium 自动重新布局 → 无需额外 resize
  │
  HostZoomMap 通知变更 → RealWebContents observer
  │
  observer_->OnZoomLevelChanged(new_level)
  │
  C-ABI zoom changed callback → dispatch_async(main) → Swift
  │
  TabViewModel.zoomLevel = new_level → UI 显示 "125%"
```

### 2. 接口设计

#### 2.1 Mojom（web_view.mojom 新增）

```mojom
// WebViewHost
SetZoomLevel(double level) => ();
GetZoomLevel() => (double level);

// WebViewObserver
OnZoomLevelChanged(double new_level);
```

#### 2.2 函数指针（owl_web_contents.h 新增）

```cpp
// Set zoom: fire-and-forget（Chromium 同步生效，callback 仅 Mojo ack）
using RealSetZoomFunc = void (*)(double level);
inline RealSetZoomFunc g_real_set_zoom_func = nullptr;

// Get zoom: 同步返回当前 level
using RealGetZoomFunc = double (*)();
inline RealGetZoomFunc g_real_get_zoom_func = nullptr;
```

**OnZoomLevelChanged** 直接通过 `observer_->OnZoomLevelChanged()` 推送（与 OnFindReply、OnPageInfoChanged 模式一致），不需要函数指针。

#### 2.3 C-ABI（owl_bridge_api.h 新增）

```c
// 设置 zoom level（callback 返回 ack）
typedef void (*OWLBridge_ZoomCallback)(void* ctx);
OWL_EXPORT void OWLBridge_SetZoomLevel(uint64_t webview_id, double level,
                                        OWLBridge_ZoomCallback callback,
                                        void* callback_context);

// 获取 zoom level（callback 返回当前 level）
typedef void (*OWLBridge_GetZoomCallback)(double level, void* ctx);
OWL_EXPORT void OWLBridge_GetZoomLevel(uint64_t webview_id,
                                        OWLBridge_GetZoomCallback callback,
                                        void* callback_context);

// Zoom 变更通知（HostZoomMap 变更时触发）
typedef void (*OWLBridge_ZoomChangedCallback)(double new_level, void* ctx);
OWL_EXPORT void OWLBridge_SetZoomChangedCallback(
    uint64_t webview_id,
    OWLBridge_ZoomChangedCallback callback,
    void* callback_context);
```

#### 2.4 Swift ViewModel（TabViewModel 新增）

```swift
@Published var zoomLevel: Double = 0.0  // 0.0 = 100%

// Zoom factor display: level → percentage
var zoomPercent: Int {
    Int(round(pow(1.2, zoomLevel) * 100))
}
var isDefaultZoom: Bool { abs(zoomLevel) < 0.01 }

// Round 1 P0 fix: 正确的 zoom level 范围
// pow(1.2, level) = factor. 25% → level ≈ -7.6, 500% → level ≈ 8.8
// 但实际 Chromium 浏览器限制更窄：blink::kMinimumBrowserZoomFactor = 0.25,
// blink::kMaximumBrowserZoomFactor = 5.0。对应 level ≈ -7.6 ~ +8.8。
// 使用 Chromium preset zoom factors 的范围更实际：25%~500%。
private let zoomStep = 1.0  // pow(1.2, 1.0) ≈ 1.2x，即 ±20% per step
private let minZoomLevel = -7.6   // ≈ 25%
private let maxZoomLevel = 8.8    // ≈ 500%

func zoomIn() {
    let newLevel = min(zoomLevel + zoomStep, maxZoomLevel)
    setZoom(newLevel)
}
func zoomOut() {
    let newLevel = max(zoomLevel - zoomStep, minZoomLevel)
    setZoom(newLevel)
}
func resetZoom() { setZoom(0.0) }

private func setZoom(_ level: Double) {
    #if canImport(OWLBridge)
    OWLBridge_SetZoomLevel(1, level, { ctx in
        // ack, no-op
    }, nil)
    #else
    zoomLevel = level  // Mock mode
    #endif
}
```

### 3. 核心逻辑

#### 3.1 OWLWebContents（owl_web_contents.cc）

```cpp
void OWLWebContents::SetZoomLevel(double level, SetZoomLevelCallback callback) {
  // Round 1 P1 fix: Host-side isfinite validation.
  if (!std::isfinite(level)) {
    std::move(callback).Run();
    return;
  }
  // Round 2 P1 fix: blink min/max clamp 移至 RealSetZoom（owl_real_web_contents.mm），
  // 避免 :host target 依赖 //third_party/blink/public/common。
  if (g_real_set_zoom_func) {
    g_real_set_zoom_func(level);
  }
  std::move(callback).Run();
}

void OWLWebContents::GetZoomLevel(GetZoomLevelCallback callback) {
  double level = 0.0;
  if (g_real_get_zoom_func) {
    level = g_real_get_zoom_func();
  }
  std::move(callback).Run(level);
}
```

#### 3.2 RealWebContents（owl_real_web_contents.mm）

```cpp
class RealWebContents : ... {
 public:
  void SetZoom(double level) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    if (!web_contents_) return;
    // Round 2 P1 fix: clamp 在 real 层做（:host_content 有 blink dep）。
    double min_level = blink::ZoomFactorToZoomLevel(blink::kMinimumBrowserZoomFactor);
    double max_level = blink::ZoomFactorToZoomLevel(blink::kMaximumBrowserZoomFactor);
    level = std::clamp(level, min_level, max_level);
    content::HostZoomMap::SetZoomLevel(web_contents_.get(), level);
  }

  double GetZoom() {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    if (!web_contents_) return 0.0;
    return content::HostZoomMap::GetZoomLevel(web_contents_.get());
  }
};

// Free functions
void RealSetZoom(double level) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (g_real_web_contents) g_real_web_contents->SetZoom(level);
}
double RealGetZoom() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!g_real_web_contents) return 0.0;
  return g_real_web_contents->GetZoom();
}
```

**OnZoomLevelChanged 通知**：通过 `content::HostZoomMap::AddZoomLevelChangedCallback` 注册，在 `RealWebContents` 构造函数中设置：

```cpp
// In RealWebContents constructor:
zoom_subscription_ = content::HostZoomMap::GetDefaultForBrowserContext(
    g_browser_context)->AddZoomLevelChangedCallback(
    base::BindRepeating(&RealWebContents::OnZoomChanged,
                        base::Unretained(this)));

// Callback:
void OnZoomChanged(const content::HostZoomMap::ZoomLevelChange& change) {
  if (observer_ && observer_->is_connected()) {
    double level = content::HostZoomMap::GetZoomLevel(web_contents_.get());
    (*observer_)->OnZoomLevelChanged(level);
  }
}

// Member (Round 2 P1 fix: MUST be before weak_factory_ for correct destructor order):
base::CallbackListSubscription zoom_subscription_;
```

#### 3.3 C-ABI 实现

```cpp
void OWLBridge_SetZoomLevel(uint64_t webview_id, double level,
                             OWLBridge_ZoomCallback callback, void* ctx) {
  CHECK(g_initialized.load(std::memory_order_acquire));
  (*g_io_thread)->task_runner()->PostTask(FROM_HERE,
      base::BindOnce([](double lvl, OWLBridge_ZoomCallback cb, void* ctx) {
        if ((*g_webview) && (*g_webview)->remote.is_connected()) {
          (*g_webview)->remote->SetZoomLevel(lvl,
              base::BindOnce([](OWLBridge_ZoomCallback cb, void* ctx) {
                dispatch_async(dispatch_get_main_queue(), ^{ if (cb) cb(ctx); });
              }, cb, ctx));
        } else if (cb) {
          dispatch_async(dispatch_get_main_queue(), ^{ cb(ctx); });
        }
      }, level, callback, ctx));
}

// SetZoomChangedCallback: 与 SetFindResultCallback 模式一致（main thread 设置）
void OWLBridge_SetZoomChangedCallback(uint64_t webview_id,
                                       OWLBridge_ZoomChangedCallback callback,
                                       void* ctx) {
  CHECK(*g_webview) << "No active web view";
  (*g_webview)->zoom_changed_callback = callback;
  (*g_webview)->zoom_changed_ctx = ctx;
}
```

#### 3.4 SwiftUI

**BrowserWindow.swift 键盘快捷键**：
```swift
.background {
    // Cmd+= zoom in
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
}
```

**AddressBarView.swift zoom 指示器**（非 100% 时显示）：
```swift
// 在地址栏右侧
if let tab = viewModel.activeTab, !tab.isDefaultZoom {
    Button("\(tab.zoomPercent)%") {
        tab.resetZoom()
    }
    .font(OWL.captionFont)
    .buttonStyle(.borderless)
    .accessibilityIdentifier("zoomIndicator")
}
```

### 4. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `mojom/web_view.mojom` | 修改 | +SetZoomLevel, +GetZoomLevel (WebViewHost); +OnZoomLevelChanged (WebViewObserver) |
| `host/owl_web_contents.h` | 修改 | +RealSetZoomFunc, +RealGetZoomFunc 函数指针; +SetZoomLevel/GetZoomLevel 方法声明 |
| `host/owl_web_contents.cc` | 修改 | +SetZoomLevel/GetZoomLevel 分发实现 |
| `host/owl_real_web_contents.mm` | 修改 | +SetZoom/GetZoom/OnZoomChanged 方法; +zoom_subscription_ 成员; +HostZoomMap include; +RealSetZoom/RealGetZoom 自由函数; +函数指针注册 |
| `bridge/owl_bridge_api.h` | 修改 | +OWLBridge_SetZoomLevel, +GetZoomLevel, +SetZoomChangedCallback 声明 |
| `bridge/owl_bridge_api.cc` | 修改 | +实现; WebViewObserverImpl +OnZoomLevelChanged; WebViewState +zoom_changed_callback/ctx |
| `bridge/OWLBridgeWebView.mm` | 修改 | +OnZoomLevelChanged override (no-op, C-ABI path) |
| `owl-client-app/ViewModels/TabViewModel.swift` | 修改 | +zoomLevel/zoomPercent/isDefaultZoom; +zoomIn/zoomOut/resetZoom/setZoom; +setupZoomCallbackIfNeeded |
| `owl-client-app/Views/BrowserWindow.swift` | 修改 | +Cmd+=/-/0 快捷键 |
| `owl-client-app/Views/TopBar/AddressBarView.swift` | 修改 | +zoom 百分比指示器 |
| `host/owl_web_contents_unittest.cc` | 修改 | +SetZoomLevel/GetZoomLevel stub + real 测试; TearDown 加函数指针重置 |

BUILD.gn：`:host_content` 已依赖 `//content/public/browser`（含 HostZoomMap），无需修改。`blink::ZoomLevelToZoomFactor` 在 `//third_party/blink/public/common` 中，`:host_content` 已依赖。

### 5. 测试策略

| 测试类型 | 内容 | AC |
|---------|------|-----|
| C++ 单元测试 | SetZoomLevel stub 模式：callback 正常返回 | AC-006 |
| C++ 单元测试 | GetZoomLevel stub 模式：返回 0.0 | AC-006 |
| C++ 单元测试 | SetZoomLevel real 模式：委托到 g_real_set_zoom_func | AC-006 |
| C++ 单元测试 | GetZoomLevel real 模式：返回 g_real_get_zoom_func 的值 | AC-006 |
| Swift E2E | SetZoomLevel → GetZoomLevel 验证值一致 | AC-007 |
| XCUITest | Cmd+= → 地址栏显示百分比 > 100% | AC-001, AC-004 |
| XCUITest | Cmd+- → 百分比 < 100% | AC-002, AC-004 |
| XCUITest | Cmd+0 → 百分比消失（回到 100%） | AC-003 |

### 6. 风险 & 缓解

| 风险 | 概率 | 缓解 |
|------|------|------|
| HostZoomMap 需要 BrowserContext 初始化 | 低 | g_browser_context 在 OWLRealWebContents_Init 时已设置 |
| zoom_subscription_ 在 RealWebContents 析构后 dangling | 低 | CallbackListSubscription 自动在析构时取消注册 |
| SetZoomLevel 超范围值 | 低 | Swift 层 min/max 限制 + Chromium 内部也有 kMin/kMaximumBrowserZoomFactor 兜底 |
| Zoom level 精度误差导致 UI 显示跳变 | 中 | 使用 `blink::ZoomValuesEqual` 比较 + round 到最近整数百分比 |
| OnZoomLevelChanged 在非当前 tab 的 zoom 变化时也触发 | 无（当前） | 单 tab 模式自然隔离 |
| GetZoomLevel Mojo handler 线程安全 | 低 | OWLWebContents receiver 通过 BrowserContextHost→CreateWebView 绑定。Host 进程中 BrowserContextHost 的 receiver 绑定在 UI thread（content::BrowserMainLoop），因此 OWLWebContents 的所有 Mojo handler（含 GetZoomLevel）也在 UI thread 执行，DCHECK 安全。已有 Phase 27-33 的 Navigate/Find 等函数指针调用验证了此线程模型 |

### Round 1 评审修复记录

| 来源 | 级别 | 问题 | 修复 |
|------|------|------|------|
| Codex P0 | P0 | zoom level ↔ 百分比换算错误（pow(1.2,3.8)≈200% 非 500%） | 修正对照表 + Swift clamp 范围改为 -7.6~+8.8 + zoomStep 改为 1.0 |
| Codex P1 | P1 | per-tab 语义与 HostZoomMap per-host 不匹配 | 文档更正为 per-host（单 tab 下等价） |
| Codex P1 | P1 | Host/C-ABI 无 zoom level 范围校验 | Host SetZoomLevel 加 isfinite + blink min/max clamp |
| Claude P1-1 | P1 | 技术要点 API 名称笔误 | 统一为 HostZoomMap::SetZoomLevel / blink::ZoomLevelToZoomFactor |
| Claude P1-2 | P1 | GetZoomLevel Mojo handler 线程安全 | 风险表加注释：receiver 绑定在 UI thread（已有 Phase 27-33 验证） |
| Gemini P0 | 降级P2 | 全局函数指针过度工程 | 当前架构统一用函数指针模式，技术债 TODO 已记录（与 Phase 33 决策一致） |

### Round 2 评审修复记录

| 来源 | 级别 | 问题 | 修复 |
|------|------|------|------|
| Claude Q1 P1 | P1 | zoom_subscription_ 必须在 weak_factory_ 前声明（析构顺序） | 加注释标注 |
| Claude Q3 P1 | P1 | blink::ZoomFactorToZoomLevel 在 :host 中无 dep | clamp 逻辑移至 RealSetZoom（:host_content 有 blink dep） |

## 状态

- [x] 技术方案评审（2 轮，1 P0 + 7 P1 修复，最终 0 P0/P1）
- [x] 开发完成（11 文件修改，~150 行）
- [x] 测试通过（100 C++ GTest + 2 Swift E2E + 6 XCUITest + 9 ViewModel 单元测试，含 5+2+6+9 Phase 34）
- [x] 测试评审通过（2 轮 4-agent 全盲评审，Round 1: 9 P0/P1 修复，Round 2: 3 P1 修复，最终 0 P0/P1）
