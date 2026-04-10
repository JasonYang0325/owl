# 权限与安全体系 — PRD

## 1. 背景与目标

OWL Browser 当前静默拒绝所有网站权限请求，且不显示页面安全状态。用户无法授权可信站点使用设备资源（如摄像头用于视频会议），也无法判断当前页面是否安全。

**目标**: 实现完整的权限管理和安全状态显示体系，使 OWL Browser 达到现代浏览器的基线安全体验。

**成功指标**:
- 7 个 AC 全部通过自动化测试
- 权限决定在 app 重启后仍然生效（持久化验证）
- SSL 状态在页面导航后 100ms 内更新
- 用户首次遇到权限弹窗时能在 5 秒内理解请求内容并做出决定（UX 基线）

## 2. 用户故事

- **US-001**: As a 视频会议用户, I want 授权 Google Meet 使用我的摄像头和麦克风, so that 我可以正常参加视频会议。
- **US-002**: As a 地图用户, I want 授权 Google Maps 获取我的位置, so that 我可以看到附近的搜索结果。
- **US-003**: As a 安全敏感用户, I want 看到地址栏的安全锁图标, so that 我知道当前页面是否使用 HTTPS。
- **US-004**: As a 隐私保护用户, I want 在设置中查看和撤销已授予的权限, so that 我可以管理哪些站点可以访问我的设备资源。
- **US-005**: As a 普通用户, I want 在遇到证书错误时看到清晰的警告, so that 我可以决定是否继续访问。

## 验收标准（完整定义）

| AC | 描述 | 输入 | 操作 | 预期输出 |
|----|------|------|------|---------|
| AC-001 | 权限弹窗 | 网站请求 camera 权限 | 用户看到弹窗 | 弹窗显示: origin、权限类型图标+名称、"允许"/"拒绝"按钮 |
| AC-002 | 权限持久化 | 用户授权 camera | 重启 app，再次访问同站 | 不再弹窗，权限自动生效 |
| AC-003 | 锁图标 | 导航到 HTTPS/HTTP 页面 | 观察地址栏 | HTTPS=绿锁, HTTP=灰锁, 证书错误=红色警告 |
| AC-004 | 锁图标详情 | HTTPS 页面 | 点击锁图标 | 弹窗显示: 连接安全等级、证书颁发者、该站点已授予的权限列表 |
| AC-005 | 设置页权限管理 | 已有多个站点权限 | 打开设置→权限 | 列出所有站点+权限，可单条撤销，撤销后下次访问重新弹窗 |
| AC-006 | SSL 错误页 | 导航到证书错误的站点 | 自动显示 | 全屏警告页: 错误说明、"返回安全页面"(主)、"继续访问(不安全)"(次) |
| AC-007 | 4 种权限类型 | 分别测试 | 各自请求 | camera、microphone、geolocation、notifications 均可弹窗并持久化 |

**支持的权限类型（明确列表）**: `camera`、`microphone`、`geolocation`、`notifications`

**注意**: notifications 权限在 macOS 上除了 Chromium 侧授权外，还需调用 `UNUserNotificationCenter.requestAuthorization()` 获取系统级推送授权。弹窗应先请求系统授权，再记录 Chromium 侧授权。

## 3. 功能描述

### 3.1 核心流程

#### 权限请求流程
```
网站调用 navigator.permissions.request()
  → Chromium content layer 回调 PermissionControllerDelegate
  → Host 通过 Mojo Observer 通知客户端
  → Bridge C-ABI 回调
  → Swift PermissionViewModel 更新状态
  → SwiftUI 弹出 PermissionAlertView
  → 用户点击"允许"/"拒绝"
  → Swift → Bridge → Mojo → Host 回传结果
  → Host 持久化到 permissions.json
  → Chromium 将结果返回给网站
```

#### 安全状态显示流程
```
页面导航完成
  → Host 获取 SSL 信息 (NavigationHandle)
  → 通过 Mojo Observer 通知客户端安全等级
  → SecurityViewModel 更新锁图标状态
  → SwiftUI SecurityIndicator 实时反映
```

### 3.2 详细规则

**权限持久化模型**:
```json
{
  "https://meet.google.com": {
    "camera": "granted",
    "microphone": "granted"
  },
  "https://maps.google.com": {
    "geolocation": "granted"
  }
}
```

- Key = origin（scheme + host + port）
- Value = `granted` | `denied` | `ask`（默认）
- 存储位置: `user_data_dir/permissions.json`
- 读取时机: PermissionManager 初始化时加载全量
- 写入时机: 用户做出权限决定后立即写入

**安全等级定义**:
| 等级 | 条件 | 图标 | 颜色 |
|------|------|------|------|
| Secure | 有效 HTTPS 证书 | 🔒 | 绿色 |
| Info | HTTP 或 localhost | 🔓 | 灰色 |
| Warning | 证书警告（过期、域名不匹配等） | ⚠️ | 黄色 |
| Dangerous | 证书错误且用户未选择继续 | 🔴 | 红色 |

**权限弹窗内容规格**:
- 标题: "「{origin}」想要使用你的{权限名称}"
- 图标: 权限类型对应的 SF Symbol（camera.fill / mic.fill / location.fill / bell.fill）
- 按钮: "允许"（Primary）| "拒绝"（Secondary）
- 超时: 30 秒无操作 → 自动拒绝 + Toast 提示 "权限请求已超时，已自动拒绝"
- 无"不再询问"选项（拒绝后下次访问仍弹窗，直到用户在设置中手动设为"拒绝"）

**锁图标详情弹窗内容**:
- 安全等级标题（"连接安全" / "连接不安全"）
- 证书信息: 颁发者、有效期（HTTPS 时显示）
- 该站点已授予的权限列表（如有）
- "管理权限" 按钮 → 跳转设置页

**SSL 错误处理**:
- 触发点: `WebContentsDelegate::CertificateError()` 拦截导航
- 证书错误时显示全屏警告页
- 警告页包含: 错误类型说明、风险提示、"返回安全页面"（Primary）和"继续访问（不安全）"（Secondary, 需二次确认）
- "继续访问"的决定仅会话级有效（app 重启后重置）
- 选择继续后，地址栏显示 Warning 等级（黄色），不显示 Secure

### 3.3 异常/边界处理

- **同时多个权限请求**: 队列化处理，逐个弹窗，各自独立计时 30 秒
- **权限请求超时**: 30 秒无操作自动拒绝 + Toast 提示
- **permissions.json 损坏**: 回退到全部 `ask` 状态，记录日志
- **permissions.json 写入失败**: 内存中保留决定（本次会话有效），不阻塞用户操作，记录错误日志
- **permissions.json 并发写入**: PermissionManager 在 UI 线程单线程写入，不存在并发（所有权限决定经 Mojo UI 线程回调）
- **嵌套 iframe 请求权限**: 上溯至 main frame 的 origin（通过 `RenderFrameHost::GetMainFrame()`）
- **隐私浏览模式**: ⚠️ 当前未实现隐私模式。若后续实现，权限存储必须隔离（会话级 in-memory store）。此为已识别技术债，非边界处理。

## 4. 非功能需求

- **性能**: 权限查询延迟 < 5ms（内存缓存）；安全状态更新 < 100ms
- **安全**: permissions.json 仅应用自身可读写；不存储敏感凭据
- **兼容性**: 实现 `PermissionControllerDelegate` 的所有纯虚方法（含 `RequestPermissionsFromCurrentDocument`、`ResetPermission`、`GetPermissionResultForCurrentDocument` 等），以及 `SSLHostStateDelegate` 接口。注意线程约束: 所有 callback 必须在 UI 线程回调，跨线程使用 `base::PostTask`。
- **预估规模**: ~1200 行（C++ ~600 + Swift ~400 + Bridge/Mojom ~200），原估 ~800 偏低

## 5. 数据模型变更

新增文件:
- `user_data_dir/permissions.json` — 权限持久化存储

新增 Mojom:
- `mojom/permissions.mojom` — PermissionService 接口 + Observer/Host 扩展

## 6. 影响范围

| 模块 | 影响 |
|------|------|
| `host/owl_content_browser_context` | 返回 PermissionControllerDelegate 和 SSLHostStateDelegate |
| `mojom/web_view.mojom` | 新增 Observer 和 Host 方法 |
| `bridge/owl_bridge_api.h` | 新增权限和 SSL 的 C-ABI 函数 |
| `owl-client-app/` | 新增 ViewModel 和 Views |
| 地址栏 | 新增 SecurityIndicator 组件 |

## 7. 里程碑 & 优先级

| 优先级 | 功能 |
|--------|------|
| P0 | AC-001 权限弹窗、AC-002 持久化、AC-007 4种权限类型 |
| P0 | AC-003 锁图标、AC-005 设置页权限管理（基础撤销能力）、AC-006 SSL 错误页 |
| P1 | AC-004 锁图标详情弹窗（证书信息+权限列表） |

## 8. 开放问题

- ~~权限存储格式~~ → JSON 文件（已决定）
- ~~隐私模式权限~~ → 当前未实现隐私模式，已标注为技术债（见 3.3）
- ~~AC-005 优先级~~ → 升为 P0（用户必须有撤销权限的途径）
- 后续是否需要支持"仅本次允许"的临时权限？→ 🔮 后续迭代
- 隐私浏览模式下的权限隔离？→ 🔮 后续迭代
- 更多权限类型（clipboard、midi 等）？→ 🔮 后续迭代
