# Phase: IME 中文输入修复

## 问题

在 OWL 浏览器中，中文输入法（IME）无法正常工作。用户在百度搜索框等输入区域使用拼音输入法时，composition 文本和最终提交的中文字符都不会显示在页面中。

## 根因分析（日志确认）

### macOS 侧 ✅ 正常
日志确认 `OWLRemoteLayerView` 的 `NSTextInputClient` 实现正确：
- `setMarkedText:` 被正确调用（如 `'a s d f'`）
- `insertText:` 正确提交中文字符（如 `'阿斯顿发是短发'`）
- `inputContext` 非 nil，`isFirstResponder` = true

### Bridge 侧 ✅ 正常
- `OWLBridge_ImeSetComposition` / `OWLBridge_ImeCommitText` 被正确调用
- Mojo IPC 传输到 Host 进程

### Host/Renderer 侧 ❌ 问题所在
- `RenderWidgetHostImpl::ImeSetComposition()` 调用了 `GetWidgetInputHandler()->ImeSetComposition()`
- Renderer 侧 `WidgetBase::ImeSetComposition()` 第一行检查 `ShouldHandleImeEvents()`
- `ShouldHandleImeEvents()` → `HasFocus()` → `has_focus_` = **false** → **静默丢弃所有 IME 事件**
- 对比：英文键盘输入走 `ForwardKeyboardEvent` → `InputRouter` 路径，**不检查 focus**，所以正常

### 为什么 renderer 认为自己没有 focus？

OWL 的 offscreen window 架构导致 focus 状态不可靠：

1. `EnsureRendererReady()` 在页面加载时调用 `view->Focus()` → `GotFocus()` → `SetFocus(true)`
2. 但 `RenderWidgetHostViewMac::Focus()` 有 guard：`if (is_first_responder_) return;`
3. 导航后新 renderer widget 的 `has_focus_` 从 false 开始
4. Browser 侧 `is_focused_` 可能仍为 true（旧状态），导致 `EnsureImeFocus()` 判断 "已 focused" 而跳过
5. 实际 renderer 侧 `has_focus_` = false → IME 事件被丢弃

## 验收标准

1. 中文拼音输入法在所有文本输入框中正常工作（composition + commit）
2. 日文/韩文 IME 同样正常
3. 英文输入不受影响
4. 多标签页切换后 IME 仍正常
5. 导航后 IME 仍正常

---

## 技术方案

### 1. 架构设计

分两个层次修复：

**Layer 1（立即生效）**：强制 focus 同步 — 每次 IME 调用前无条件重置 renderer focus 状态

**Layer 2（完整方案）**：TextInputState 桥接 — 将 renderer 的文本输入状态回传到 bridge，让 OWLRemoteLayerView 维护与 Chromium 一致的状态

```
                    Layer 1: Focus 强制同步
                    ┌──────────────────────┐
SwiftUI             │  OWLRemoteLayerView  │  (NSTextInputClient)
                    └──────┬───────────────┘
                           │ setMarkedText / insertText
                    ┌──────▼───────────────┐
Bridge (C-ABI)      │  OWLBridge_Ime*()    │
                    └──────┬───────────────┘
                           │ Mojo IPC
                    ┌──────▼───────────────┐
Host                │  OWLWebContents      │
                    │  SendIme*()          │
                    └──────┬───────────────┘
                           │ g_real_ime_*_func
                    ┌──────▼───────────────┐
                    │  RealIme*()          │──► EnsureImeFocus() ──► rwhi->GotFocus()
                    └──────┬───────────────┘    (Layer 1: 强制 focus)
                           │
                    ┌──────▼───────────────┐
Renderer            │  WidgetBase          │
                    │  ::ImeSetComposition │──► ShouldHandleImeEvents() ──► has_focus_ ✓
                    └──────────────────────┘
```

### 2. Layer 1：强制 Focus 同步（最小修复）

#### 问题
`EnsureImeFocus()` 检查 `rwhi->is_focused()` 来决定是否调 `GotFocus()`。
但 browser 侧 `is_focused_` 可能是 true（旧状态），而 renderer 侧 `has_focus_` 是 false（导航后新 widget）。

#### 修复
用 `LostFocus()` + `GotFocus()` 强制重置，确保 `SetFocus(true)` **一定到达 renderer**。
只在首次 IME 调用时执行（用标志位避免每次按键都 reset）。

```cpp
// owl_real_web_contents.mm

static bool g_ime_focus_synced = false;
static uint64_t g_ime_focus_webview_id = 0;

void EnsureImeFocus() {
  auto* rwhi = GetRWHI();
  if (!rwhi) return;

  // 只在首次 IME 调用或 webview 切换时强制同步
  if (g_ime_focus_synced && g_ime_focus_webview_id == g_active_webview_id)
    return;

  LOG(INFO) << "[OWL] IME: force-syncing renderer focus";
  // 无条件重置：先 Lost 再 Got，确保 SetFocus(true) 到达 renderer
  if (rwhi->is_focused()) {
    rwhi->LostFocus();
  }
  rwhi->GotFocus();
  g_ime_focus_synced = true;
  g_ime_focus_webview_id = g_active_webview_id;
}
```

#### 重置时机
在以下事件时将 `g_ime_focus_synced` 设为 false：
- 导航完成（`DidFinishNavigation`）
- Tab 切换（`SetActive`）
- 新页面加载完成

#### 文件变更

| 文件 | 操作 | 说明 |
|------|------|------|
| `host/owl_real_web_contents.mm` | 修改 | `EnsureImeFocus()` 改为强制 reset 模式 |

### 3. Layer 2：完善 Focus 生命周期

#### 3.1 实现 `SetActive`

当前 `OWLWebContents::SetActive()` 是空实现。需要正确路由 focus：

```cpp
// owl_web_contents.cc
void OWLWebContents::SetActive(bool active) {
  base::AutoReset<uint64_t> scoped_id(&g_active_webview_id, webview_id_);
  if (g_real_set_active_func) {
    g_real_set_active_func(active);
  }
}

// owl_real_web_contents.mm
void RealSetActive(bool active) {
  auto* rwc = GetActiveRealWebContents();
  if (!rwc) return;
  auto* wc = rwc->GetWebContents();
  if (!wc) return;
  auto* rwhv = wc->GetRenderWidgetHostView();
  if (!rwhv) return;
  auto* rwhi = content::RenderWidgetHostImpl::From(rwhv->GetRenderWidgetHost());
  if (!rwhi) return;

  if (active) {
    rwhv->Focus();
    rwhi->GotFocus();
  } else {
    rwhi->LostFocus();
  }

  // 重置 IME focus 标志
  g_ime_focus_synced = false;
}
```

#### 3.2 导航后重置 Focus

在 `DidFinishNavigation` 回调中重置 focus 标志：

```cpp
// 在 RealWebContents 的 WebContentsObserver 回调中：
void DidFinishNavigation(content::NavigationHandle* handle) override {
  // ... existing code ...
  // 导航完成后，新 renderer widget 可能需要重新同步 focus
  g_ime_focus_synced = false;
}
```

#### 3.3 Swift 侧 Tab 切换触发 SetActive

```swift
// TabViewModel / BrowserViewModel
func switchToTab(_ tab: TabViewModel) {
    // 通知旧 tab 失活
    OWLBridge_SetActive(oldTab.webviewId, false)
    // 通知新 tab 激活
    OWLBridge_SetActive(newTab.webviewId, true)
}
```

### 4. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `host/owl_real_web_contents.mm` | 修改 | `EnsureImeFocus()` 强制 reset + `RealSetActive()` + 导航重置 |
| `host/owl_web_contents.cc` | 修改 | `SetActive()` 从空实现改为实际路由 |
| `host/owl_web_contents.h` | 修改 | 添加 `g_real_set_active_func` 声明 |
| `bridge/owl_bridge_api.h` | 可选 | 如需新增 `OWLBridge_SetActive` C-ABI 函数 |
| `bridge/owl_bridge_api.cc` | 可选 | `OWLBridge_SetActive` 实现 |

### 5. 测试策略

- **手动验证**：百度搜索框中文拼音输入 → composition 可见 + commit 后中文显示
- **回归**：英文输入不受影响
- **多标签页**：切换 tab 后 IME 仍正常
- **导航后**：从 A 站导航到 B 站，IME 仍正常

### 6. 风险 & 缓解

| 风险 | 严重性 | 缓解 |
|------|--------|------|
| `LostFocus()`+`GotFocus()` 循环可能触发 renderer 副作用 | 中 | 用标志位确保只在首次 IME 时执行一次 |
| 频繁 focus reset 可能影响性能 | 低 | 标志位保证大多数按键不触发 reset |
| 跨进程导航创建新 renderer 后 focus 丢失 | 高 | `DidFinishNavigation` 回调重置标志 |
