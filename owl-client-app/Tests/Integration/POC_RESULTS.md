# Phase A POC 结果

## 结论：NSEvent 进程内注入在 XCTest 环境中无法触发 SwiftUI 交互

### 测试环境
- `swift test` (SPM XCTest) 进程
- NSWindow + NSHostingView + SwiftUI Button/TextField/DragGesture
- macOS 15 (Darwin 25.3.0)

### 尝试的 3 种方法

| 方法 | 结果 | 原因 |
|------|------|------|
| `NSApp.sendEvent(mouseDown)` | 失败 | xctest 进程中窗口无法成为 key window，NSWindow 不转发事件到 content view |
| 直接 `hostingView.mouseDown(with:)` | 失败 | SwiftUI 内部 hit testing 在非 key window 中不工作 |
| AXUIElement AXPress | 失败 | SwiftUI Button 没有暴露到 AX 树（可能需要 `.accessibilityAddTraits(.isButton)`） |

### 根因
1. `swift test` 进程不是通过 NSApplicationMain 启动的正常 GUI app
2. `NSApp.setActivationPolicy(.regular)` 可以让 isActive=true，但窗口仍然不能成为 key window
3. NSWindow 在非 key 状态下不将鼠标事件路由到 SwiftUI 的手势识别系统
4. SwiftUI Button 是纯 SwiftUI 渲染（不是 NSButton），不在 NSView 层级中

### 需要重新评估的方案选择
1. **CGEvent** 仍然是唯一能在 swift test 中触发真实 UI 交互的方式（通过 WindowServer 路由）
2. **XCUITest** 是 Apple 官方的 UI 测试方案（需要签名）
3. **ViewModel 直接测试** 不需要 UI 交互，可以覆盖大部分业务逻辑
