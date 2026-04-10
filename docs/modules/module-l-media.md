# Module L: 全屏与媒体控制

| 属性 | 值 |
|------|-----|
| 优先级 | P3 |
| 依赖 | 无 |
| 预估规模 | ~400 行 |
| 状态 | pending |

## 目标

支持网页全屏（视频全屏、F11 全屏）和标签页音频状态指示/静音控制。

## 用户故事

As a 浏览器用户, I want 视频可以全屏播放、可以识别和静音播放音频的标签页, so that 我有更好的媒体浏览体验。

## 验收标准

- AC-001: 网页请求全屏时（如 YouTube 全屏按钮）进入 macOS 全屏模式
- AC-002: 按 Esc 退出全屏
- AC-003: 播放音频的标签页显示音量图标
- AC-004: 点击音量图标可静音/取消静音该标签页
- AC-005: F11 切换浏览器全屏模式

## 技术方案

### 层级分解

#### 1. Host C++

**全屏**：
- 实现 `WebContentsDelegate::EnterFullscreenModeForTab()`
- 实现 `WebContentsDelegate::ExitFullscreenModeForTab()`
- 通过 Observer 通知客户端进入/退出全屏

**音频**：
- `WebContentsObserver::OnAudioStateChanged(bool audible)` → 检测音频播放
- `content::WebContents::SetAudioMuted(bool muted)` → 静音控制

#### 2. Mojom（扩展 `web_view.mojom`）

```
// WebViewObserver 新增:
OnFullscreenChanged(bool is_fullscreen);
OnAudioStateChanged(bool is_playing_audio);

// WebViewHost 新增:
ExitFullscreen();
SetAudioMuted(bool muted);
GetAudioState() => (bool is_playing, bool is_muted);
```

#### 3. Bridge C-ABI

```c
typedef void (*OWLBridge_FullscreenCallback)(bool is_fullscreen, void* ctx);
typedef void (*OWLBridge_AudioStateCallback)(bool is_playing, void* ctx);

OWL_EXPORT void OWLBridge_SetFullscreenCallback(OWLBridge_FullscreenCallback cb, void* ctx);
OWL_EXPORT void OWLBridge_ExitFullscreen(void);
OWL_EXPORT void OWLBridge_SetAudioStateCallback(OWLBridge_AudioStateCallback cb, void* ctx);
OWL_EXPORT void OWLBridge_SetAudioMuted(bool muted);
```

#### 4. Swift

**全屏**：
- `NSWindow.toggleFullScreen()` 响应全屏请求
- `TabViewModel.isFullscreen` 状态

**音频**：
- `TabViewModel.isPlayingAudio` / `isMuted`
- `TabRowView` 显示音频指示器

#### 5. SwiftUI

- `TabRowView` 音频图标（扬声器 / 已静音）
- BrowserWindow 全屏状态管理
- F11 快捷键绑定

## 测试计划

| 层级 | 测试内容 |
|------|---------|
| C++ GTest | 全屏请求/退出回调、音频状态 |
| Swift ViewModel | 全屏/音频状态切换 |
| E2E Pipeline | 音频状态回调、静音控制 |

## 文件清单

| 操作 | 文件 |
|------|------|
| 修改 | `mojom/web_view.mojom`（Observer + Host 扩展） |
| 修改 | `host/owl_real_web_contents.mm`（全屏 + 音频回调） |
| 修改 | `host/owl_web_contents.h/.cc` |
| 修改 | `bridge/owl_bridge_api.h/.cc` |
| 修改 | `owl-client-app/ViewModels/TabViewModel.swift`（音频状态） |
| 修改 | `owl-client-app/Views/Sidebar/TabRowView.swift`（音频指示器） |
| 修改 | `owl-client-app/Views/BrowserWindow.swift`（全屏管理） |
