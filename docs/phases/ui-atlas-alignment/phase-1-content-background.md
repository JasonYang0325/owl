# Phase 1: ContentArea 背景修复

## 目标
修复 WebContent 区域透明背景问题，导航时不再漏出窗口底色。

## 范围
- 修改：`owl-client-app/Views/Content/ContentAreaView.swift`
- 不修改 RemoteLayerView 或 bridge 层

## 依赖
- 无前置依赖

## 技术要点
- 在 `ContentAreaView.body` 的 ZStack **底层**（所有分支之前）添加 `OWL.surfacePrimary` 填充
- `OWL.surfacePrimary` 自动支持 light/dark mode（light: white, dark: #1A1A1A）
- **不修改** `RemoteLayerView` 的 NSView/CALayerHost，避免与 Chromium compositor 冲突
- 注意 ZStack 的 Z 顺序：背景色在最底层，各内容分支在上层

## 验收标准
- [ ] ContentArea 在所有状态（加载中、WelcomeView、RemoteLayerView、ErrorPage）下背景均为不透明色
- [ ] Dark mode 下背景为 #1A1A1A
- [ ] 从 about:blank 导航到任意 URL 过程中无透明漏底
- [ ] 现有 transition 动画不受影响

## 技术方案

### 1. 架构设计

单文件改动，无架构变更。在 `ContentAreaView` 的 ZStack 底层插入一个不透明色块作为所有内容状态的兜底背景。

数据流不变：`ContentAreaView` → `TabContentView` → 各内容分支（WelcomeView/RemoteLayerView/ErrorPage/Loading）

### 2. 核心逻辑

**修复层级选择：ContentAreaView（外层）而非 TabContentView（内层）**

为什么选择外层：
- `TabContentView` 内部的 ZStack 各分支（WelcomeView/RemoteLayerView/ErrorPage/Loading）在 transition 切换期间短暂两层都部分透明，漏底穿透 TabContentView 到达 ContentAreaView
- 在 ContentAreaView 外层加背景色，无论 TabContentView 内部哪个状态、哪个 transition 阶段，底层都有不透明色兜底
- 如果在 TabContentView 内层加，需要给每个分支单独加背景或在 TabContentView 的 ZStack 加，但 TabContentView 是 private struct，且 Loading 分支已有 `.background(OWL.surfacePrimary)`——在外层统一加一层更简洁

在 `ContentAreaView.body` 的 ZStack 内、`if let activeTab` 分支之前插入：

```swift
// ContentAreaView.body — 实际代码结构
var body: some View {
    ZStack {
        OWL.surfacePrimary  // ← 新增：兜底不透明背景

        if let activeTab = viewModel.activeTab {
            TabContentView(tab: activeTab)  // 内部 ZStack 各分支在 transition 时透明，由外层 surfacePrimary 兜底
        } else {
            OWL.surfaceSecondary  // 原有：无 tab 时的浅灰占位（不透明，叠在 surfacePrimary 之上）
        }

        SSLErrorOverlay(...)  // 原有
    }
    .animation(.easeInOut(duration: 0.2), value: viewModel.activeTab?.id)
}
```

关键点：
- `OWL.surfacePrimary` = `Color(light: .white, dark: #1A1A1A)`，自动支持 dark mode
- 不加 `.ignoresSafeArea()`（macOS 无 safe area inset，无必要）
- `Color` 视图为静态填充，不参与 `.animation` 的 transition（SwiftUI 中 `Color` 没有可动画属性变化，不会被 opacity transition 影响）
- 原有 `OWL.surfaceSecondary`（无 activeTab 时）保留在上层，语义为占位色，与底层 surfacePrimary 不冲突

### 3. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `owl-client-app/Views/Content/ContentAreaView.swift` | 修改 | ZStack 底层加 `OWL.surfacePrimary` |

### 4. 测试策略

- **编译验证**：`run_tests.sh cpp` 确认无编译错误
- **手动验证**：启动浏览器，从新标签页导航到任意 URL，确认无透明漏底
- **Dark mode 验证**：切换系统 dark mode，确认背景为 #1A1A1A
- **XCUITest 验收**（项目规范要求）：在 E2E 测试中验证 `webContentView` 存在时背景不透明（可通过截图像素采样或 accessibility 检查确认内容区域可见）

### 5. 风险 & 缓解

| 风险 | 概率 | 缓解 |
|------|------|------|
| surfacePrimary 遮住其他内容 | 极低 | ZStack 底层，其他内容在上层 |
| transition 动画受影响 | 低 | 背景色静态不参与 animation |
| Dark mode 颜色错误 | 极低 | surfacePrimary 已有 light/dark 定义 |

## 状态
- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
