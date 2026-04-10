# 权限与安全体系 — UI 设计稿

## 1. 设计概述

- **设计目标**: 原生 macOS 风格，最小化用户打扰，安全信息清晰可见
- **设计原则**: 权限弹窗简洁明了（5 秒内理解）；安全状态始终可见但不侵入

## 2. 信息架构

```
TopBar (地址栏)
  └── SecurityIndicator (锁图标) ← 常驻
       └── SecurityPopover (点击展开) ← AC-004, P1

PermissionAlertView ← 按需弹出, .sheet modifier

SSLErrorPage ← 全屏替换 WebView 内容

Settings (已有)
  └── PermissionsPanel ← 新增 tab
```

## 3. 页面/组件设计

### 3.1 SecurityIndicator（地址栏锁图标）

#### 布局
```
┌─────────────────────────────────────────────┐
│ [🔒]  https://meet.google.com         [⟳]  │
│  ↑                                          │
│  SecurityIndicator                          │
└─────────────────────────────────────────────┘
```
位于地址栏最左侧，URL 文本之前。固定 20x20pt 大小。

#### 视觉规范
| 状态 | SF Symbol | 颜色 | 条件 |
|------|-----------|------|------|
| Secure | `lock.fill` | `.green` (system) | 有效 HTTPS |
| Info | `lock.open` | `.secondary` | HTTP / localhost |
| Warning | `exclamationmark.triangle.fill` | `.yellow` | 证书错误但用户选择继续 |
| Dangerous | `xmark.shield.fill` | `.red` | 证书错误未处理 |

#### 交互设计
- **默认**: 显示对应状态图标
- **悬停**: 轻微放大 (scaleEffect 1.1) + tooltip 显示安全等级文字
- **点击**: 展开 SecurityPopover（P1，首版可不实现点击）
- **导航中**: 图标暂时变为 `.secondary` 色（页面加载完成后更新）

### 3.2 PermissionAlertView（权限弹窗）

#### 布局
```
┌────────────────────────────────────┐
│         [camera.fill icon]         │
│                                    │
│  "meet.google.com" 想要使用         │
│      你的摄像头                     │
│                                    │
│  ┌──────────┐   ┌──────────────┐  │
│  │   拒绝   │   │     允许     │  │
│  └──────────┘   └──────────────┘  │
│           30 秒后自动拒绝           │
└────────────────────────────────────┘
```
实现方式: 自定义 `ZStack` overlay + `.transition(.move(edge: .top))` 动画，从地址栏下方滑出。
**不使用 `.sheet`**（macOS 上 `.sheet` 是居中模态面板，无法锚定到地址栏）。宽 320pt，锚定到窗口顶部中央。

#### 视觉规范
- 背景: `.ultraThinMaterial`
- 图标: 48pt SF Symbol，权限类型对应色 (camera=blue, mic=red, geo=green, notifications=orange)
- Origin 文字: `.headline` weight, 加粗
- 权限名称: `.body`, `.secondary` color
- 按钮: "拒绝" = `.bordered`, "允许" = `.borderedProminent`
- 超时提示: `.caption`, `.tertiary`, 倒计时显示

#### 交互设计
| 状态 | 描述 |
|------|------|
| 默认 | 弹窗滑入，显示 origin + 权限类型 |
| 倒计时 | 底部显示 "30 秒后自动拒绝"，逐秒更新 |
| 用户点击允许 | 弹窗滑出，权限立即生效 |
| 用户点击拒绝 | 弹窗滑出，权限拒绝 |
| 超时 | 弹窗滑出 + Toast "权限请求已超时，已自动拒绝" |
| 队列中有多个 | 当前弹窗处理完后自动弹出下一个 |

#### 权限类型图标映射
| 权限 | SF Symbol | 颜色 |
|------|-----------|------|
| camera | `camera.fill` | `.blue` |
| microphone | `mic.fill` | `.red` |
| geolocation | `location.fill` | `.green` |
| notifications | `bell.fill` | `.orange` |

#### notifications 双授权流程
notifications 权限需要两步授权:
1. **系统授权**: 首次请求时先调用 `UNUserNotificationCenter.requestAuthorization()` 弹出 macOS 系统级弹窗
2. **Chromium 授权**: 系统授权通过后，弹出 OWL 自己的 PermissionAlertView 记录站点级权限
3. **系统已拒绝**: 如果 macOS 系统设置中已拒绝通知权限，不弹 OWL 弹窗，改为显示 Toast: "请在系统设置中允许 OWL Browser 发送通知"

### 3.3 SSLErrorPage（证书错误警告页）

#### 布局
```
┌────────────────────────────────────────────┐
│                                            │
│         [⚠️ exclamationmark.triangle]       │
│                                            │
│       你的连接不是私密连接                    │
│                                            │
│  攻击者可能正在试图从 example.com            │
│  窃取你的信息（例如密码、消息或信用卡）。      │
│                                            │
│  错误代码: NET::ERR_CERT_DATE_INVALID      │
│                                            │
│        ┌─────────────────────┐             │
│        │    返回安全页面      │             │
│        └─────────────────────┘             │
│                                            │
│        继续访问（不安全）→                    │
│                                            │
└────────────────────────────────────────────┘
```
全屏覆盖 WebView 区域。

#### 视觉规范
- 背景: `.background` system color
- 警告图标: 64pt, `.red`
- 标题: `.title`, `.bold`
- 说明文字: `.body`, `.secondary`, 最大宽度 480pt
- 错误代码: `.caption`, `.monospaced`, `.tertiary`
- "返回安全页面": `.borderedProminent`, `.large`
- "继续访问": `.plain` 文字按钮, `.secondary`, 较小字体, 右侧箭头

#### 交互设计
| 状态 | 描述 |
|------|------|
| 显示 | 替换 WebView 内容区域 |
| 点击返回 | 有历史: goBack()；无历史（首次导航即错误）: 导航到 about:blank，按钮文案变为"打开空白页" |
| 点击继续 | 二次确认 Alert: "确定要继续？此站点证书无效" → 确认后加载页面，地址栏变 Warning |

### 3.4 SecurityPopover（锁图标详情 — P1）

#### 布局
```
┌────────────────────────────┐
│  🔒 连接安全                │
│  ────────────────────────  │
│  证书由 Let's Encrypt 颁发  │
│  有效期至 2026-12-01       │
│  ────────────────────────  │
│  权限:                     │
│   📷 摄像头    ✅ 已允许    │
│   🎤 麦克风    ✅ 已允许    │
│  ────────────────────────  │
│  [管理权限]                 │
└────────────────────────────┘
```
通过 `NSViewRepresentable` 包装 `NSPopover`，锚定到 SecurityIndicator 的 NSView。
SwiftUI 原生 `.popover` 在 macOS 上锚定行为不一致，需 AppKit 桥接。

### 3.5 Settings — PermissionsPanel（权限管理面板）

#### 布局
```
┌─────────────────────────────────────────┐
│  设置                                    │
│  ┌─────┬─────────────────────────────┐  │
│  │ 通用 │  站点权限                    │  │
│  │ 权限 │                             │  │
│  │ ... │  meet.google.com             │  │
│  │     │    📷 摄像头   [已允许 ▾]     │  │
│  │     │    🎤 麦克风   [已允许 ▾]     │  │
│  │     │                             │  │
│  │     │  maps.google.com             │  │
│  │     │    📍 位置     [已允许 ▾]     │  │
│  │     │                             │  │
│  │     │  ─────────────────────────  │  │
│  │     │  [重置所有权限]              │  │
│  └─────┴─────────────────────────────┘  │
└─────────────────────────────────────────┘
```

#### 交互设计
| 状态 | 描述 |
|------|------|
| 默认 | 按站点分组显示所有权限 |
| 空状态 | "尚未授予任何站点权限" + 说明文字 |
| 修改权限 | 下拉菜单: 允许 / 拒绝 / 询问(重置) |
| 系统级拒绝 | 权限行显示灰色 + "在系统设置中已禁用" 标注，下拉菜单禁用 |
| 撤销后 | 下次访问该站点时重新弹窗 |
| 重置所有 | 二次确认后清除所有站点权限 |

## 4. 状态流转

### 权限弹窗状态机
```
idle → pending (收到请求) → showing (弹窗可见) → decided (用户操作)
                                ↓
                           timeout → auto-denied
```

### 安全指示器状态机
```
loading (导航中) → secure / info / warning / dangerous (导航完成)
```

## 5. 设计决策记录

1. **弹窗用 ZStack overlay 而非 .sheet/NSAlert**: macOS `.sheet` 是居中模态面板无法锚定；ZStack overlay 可自定义位置和动画（从地址栏下方滑出）
- **所有颜色使用系统语义色**（`.green`, `.yellow`, `.red`, `.secondary` 等），自动适配 Dark Mode
2. **SSL 错误用全屏替换而非弹窗**: Chrome/Safari 都用全屏，用户预期一致
3. **不加"不再询问"**: 减少决策负担；要永久拒绝可在设置中操作
4. **P1 降级 SecurityPopover**: 首版锁图标只需可见状态，详情可后续补充

## 6. 无障碍考量

- SecurityIndicator: `accessibilityLabel` 动态设置为 "安全连接" / "不安全连接" 等
- PermissionAlertView: VoiceOver 焦点自动移到弹窗，读出 origin 和权限类型
- SSLErrorPage: "返回安全页面" 按钮为 VoiceOver 首焦点
- 所有按钮对比度 ≥ 4.5:1 (WCAG AA)
