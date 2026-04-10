# Module I: 设置与偏好系统

| 属性 | 值 |
|------|-----|
| 优先级 | P2 |
| 依赖 | C（权限设置项）、D（存储设置项），但核心框架可独立开发 |
| 预估规模 | ~500 行 |
| 状态 | pending |

## 目标

当前设置页仅有 AI Key + 主题/搜索引擎切换。本模块建立完整的偏好系统，支持分组设置、持久化、同步到 Host 进程。

## 用户故事

As a 浏览器用户, I want 自定义浏览器的各项设置, so that 浏览器行为符合我的习惯和隐私需求。

## 验收标准

- AC-001: 设置项使用 UserDefaults 持久化，重启后保留
- AC-002: 设置分组：通用 / 外观 / 隐私与安全 / 搜索 / 高级
- AC-003: 通用：启动页（新标签/上次会话）、默认下载路径
- AC-004: 外观：主题（浅/深/系统跟随）、字体大小、工具栏显示模式
- AC-005: 隐私：清除浏览数据（集成 Module D）、Cookie 策略、权限管理入口（集成 Module C）
- AC-006: 搜索：默认搜索引擎、地址栏搜索建议开关
- AC-007: 高级：User-Agent 自定义、代理设置、开发者模式开关
- AC-008: 修改 User-Agent/代理后同步到 Host 进程

## 技术方案

### 层级分解

#### 1. Swift 偏好框架

```swift
enum PreferenceKey: String {
    case startupBehavior       // "newTab" | "restoreSession"
    case downloadPath          // ~/Downloads
    case theme                 // "light" | "dark" | "system"
    case fontSize              // Int (12-24)
    case defaultSearchEngine   // "google" | "bing" | "duckduckgo"
    case searchSuggestions     // Bool
    case customUserAgent       // String?
    case proxyHost             // String?
    case proxyPort             // Int?
    case developerMode         // Bool
}
```

使用 `@AppStorage` + `UserDefaults.standard`。

#### 2. Host 同步（Mojom 扩展）

```
// SessionHost 新增:
SetPreference(string key, string json_value);
```

需同步的设置项：
- User-Agent → `content::WebContents::SetUserAgentOverride()`
- 代理 → 网络上下文配置

#### 3. Bridge C-ABI

```c
OWL_EXPORT void OWLBridge_SetPreference(const char* key, const char* json_value);
```

#### 4. SwiftUI Views

- `SettingsView` 重写为分组 Tab 页面
- `GeneralSettingsView` / `AppearanceSettingsView` / `PrivacySettingsView` / `SearchSettingsView` / `AdvancedSettingsView`

## 测试计划

| 层级 | 测试内容 |
|------|---------|
| Swift ViewModel | 偏好读写、默认值、类型安全 |
| E2E Pipeline | 修改 User-Agent → Host 验证生效 |

## 文件清单

| 操作 | 文件 |
|------|------|
| 新增 | `owl-client-app/Services/PreferenceService.swift` |
| 修改 | `mojom/session.mojom`（SetPreference） |
| 修改 | `host/owl_browser_impl.h/.cc` |
| 修改 | `bridge/owl_bridge_api.h/.cc` |
| 重写 | `owl-client-app/Views/Settings/SettingsView.swift` |
| 新增 | `owl-client-app/Views/Settings/GeneralSettingsView.swift` |
| 新增 | `owl-client-app/Views/Settings/AppearanceSettingsView.swift` |
| 新增 | `owl-client-app/Views/Settings/PrivacySettingsView.swift` |
| 新增 | `owl-client-app/Views/Settings/SearchSettingsView.swift` |
| 新增 | `owl-client-app/Views/Settings/AdvancedSettingsView.swift` |
