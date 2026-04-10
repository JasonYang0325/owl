# 右键上下文菜单 — PRD

## 1. 背景与目标

OWL Browser 当前完全抑制了右键菜单（`HandleContextMenu` 返回 `true`），用户无法通过右键访问常见浏览器操作（复制链接、保存图片、复制文本等）。右键上下文菜单是浏览器 P1 基础功能，缺失它严重影响日常使用体验。

**目标**: 实现根据点击目标（链接/图片/选中文本/空白区域/可编辑区域）显示不同菜单项的原生右键上下文菜单，并正确执行对应操作。

**成功指标**:
- 12 个 AC 全部通过自动化测试（含 XCUITest 端到端验收）
- 菜单弹出延迟 < 100ms（从右键事件到 NSMenu 显示）
- 核心操作（复制链接、保存图片等）100% 正确执行；已知边界异常（如跨域图片 CORS 失败）按设计降级处理（复制图片 URL）
- 不同点击目标正确识别并显示对应菜单

## 2. 用户故事

- **US-001**: As a 浏览器用户, I want 右键链接时看到"在新标签页中打开"和"复制链接地址", so that 我可以在新标签页打开链接或分享 URL。
- **US-002**: As a 浏览器用户, I want 右键图片时看到"将图片存储到「下载」"、"复制图片"和"复制图片地址", so that 我可以保存或分享图片。
- **US-003**: As a 浏览器用户, I want 右键选中文本时看到"复制"和"搜索", so that 我可以复制文本或快速搜索选中内容。
- **US-004**: As a 浏览器用户, I want 右键空白区域时看到"后退"、"前进"、"重新加载"和"查看页面源代码", so that 我可以快速执行导航操作。
- **US-005**: As a 浏览器用户, I want 点击菜单项后立即执行对应操作, so that 操作是即时响应的。
- **US-006**: As a 浏览器用户, I want 右键可编辑区域时看到系统标准的剪切/复制/粘贴菜单, so that 表单输入体验一致。

## 3. 功能描述

### 3.1 核心流程

#### 右键菜单触发流程
```
用户在页面上右键点击
  → Chromium renderer 收集点击位置的上下文信息（content::ContextMenuParams）
  → content::WebContentsDelegate::HandleContextMenu(params) 被调用
  → Host 提取关键字段，返回 true 表示"已处理"（阻止 Chromium 默认菜单）
  → 通过 Mojo Observer 接口将 OWL ContextMenuParams 传递到客户端
  → Bridge C-ABI 回调通知 Swift
  → Swift 根据 ContextMenuType 构建 NSMenu
  → NSMenu 在点击位置弹出（popUp(positioning:at:in:)）
```

**关键**: `HandleContextMenu` 仍返回 `true`（表示"已处理"），但不再静默丢弃，而是提取参数后转发。这确保 Chromium 不会同时弹出自己的默认菜单。

#### 菜单项执行流程
```
用户点击菜单项
  → NSMenu action 触发
  → 本地操作（复制到剪贴板）直接在 Swift 层执行
  → 需要 Host 参与的操作（新标签页、保存图片、导航）→ Bridge C-ABI → Host 执行
  → Host 通过 ExecuteContextMenuAction(menu_id, action_id) 分发
  → menu_id 匹配当前有效菜单，action_id 映射到具体操作
```

### 3.2 详细规则

**上下文类型判定**（按优先级，高优先匹配）:

| 优先级 | 条件 | ContextMenuType | 菜单项 |
|--------|------|----------------|--------|
| 0 | 可编辑区域（`is_editable == true`） | Editable | 剪切 (⌘X)、复制 (⌘C)、粘贴 (⌘V)、全选 (⌘A) |
| 1 | 点击在链接上（`link_url` 非空） | Link | 在新标签页中打开、复制链接地址 |
| 2 | 点击在图片上（`has_image_contents == true`） | Image | 将图片存储到「下载」、复制图片、复制图片地址 |
| 3 | 有选中文本（`selection_text` 非空） | Selection | 复制 (⌘C)、搜索"<选中文本>" |
| 4 | 其他（空白区域） | Page | 后退 (⌘[)、前进 (⌘])、重新加载 (⌘R)、查看页面源代码 (⌘U) |

**复合场景处理**（P2，首版不实现，仅按最高优先级类型显示）:
- 链接上的图片：按 Link 类型处理（优先级 1 > 2）
- 链接上的选中文本：按 Link 类型处理（优先级 1 > 3）

**菜单项操作映射**:

| 菜单项 | 快捷键 | 执行层 | 操作 |
|--------|--------|--------|------|
| 在新标签页中打开 | — | Host | 用 `link_url` 创建新标签页 |
| 复制链接地址 | — | Swift | `link_url` 写入 `NSPasteboard` |
| 将图片存储到「下载」 | — | Host | 下载 `src_url` 到 `~/Downloads`（复用 Module B 下载链路） |
| 复制图片 | — | Host+Swift | Host 获取图片数据 → Swift 写入 `NSPasteboard`（CORS 失败时降级复制图片 URL） |
| 复制图片地址 | — | Swift | `src_url` 写入 `NSPasteboard` |
| 复制（选中文本） | ⌘C | Swift | `selection_text` 写入 `NSPasteboard`（仅 kSelection 类型） |
| 复制（可编辑区域） | ⌘C | Host | 调用 `WebContents::Copy()`（仅 kEditable 类型） |
| 搜索"..." | — | Host | 用搜索 URL 模板（`https://www.google.com/search?q=`）+ 选中文本打开新标签页 |
| 后退 | ⌘[ | Host | `GoBack()` |
| 前进 | ⌘] | Host | `GoForward()` |
| 重新加载 | ⌘R | Host | `Reload()` |
| 查看页面源代码 | ⌘U | Host | 打开 `view-source:<当前URL>` 的新标签页 |
| 剪切 | ⌘X | Host | 调用 `WebContents::Cut()`（Chromium 内置剪贴板操作） |
| 粘贴 | ⌘V | Host | 调用 `WebContents::Paste()` |
| 全选 | ⌘A | Host | 调用 `WebContents::SelectAll()` |

**搜索菜单项显示规则**:
- 选中文本 ≤ 20 字符：显示 `搜索"<全文>"`
- 选中文本 > 20 字符：显示 `搜索"<前17字符>..."`

### 3.3 异常/边界处理

- **空 URL**: 如果 `link_url` 或 `src_url` 为空字符串，对应菜单项不显示
- **无法后退/前进**: 如果导航历史不支持，"后退"/"前进"菜单项置灰（`isEnabled = false`）
- **可编辑区域判定**: 通过 `content::ContextMenuParams::is_editable` 字段判定（Chromium 对 `<input>`/`<textarea>`/`contenteditable` 均设为 `true`）。可编辑区域优先级最高（优先级 0），确保不会被链接/图片类型覆盖
- **menu_id 失效机制**: Host 维护一个递增的 `current_menu_id`。每次 `OnContextMenu` 分配新 ID，页面导航时自动递增。`ExecuteContextMenuAction` 收到不匹配的 `menu_id` 时直接忽略，不执行操作
- **跨域图片**: "复制图片"依赖 Host 获取图片数据，CORS 限制下可能失败 → 降级为复制图片 URL 到剪贴板（用户始终有反馈，不会静默失败）
- **特殊协议 URL 过滤**: "在新标签页中打开"和"搜索"操作执行前，Host 必须校验 URL scheme。拒绝 `javascript:`、`file:`、`data:`（长度 > 10KB）等危险协议，仅允许 `http:`/`https:`/`view-source:` 打开新标签页。`view-source:` 仅限内部"查看页面源代码"操作使用，不从外部 `link_url` 接受
- **selection_text 长度限制**: Mojo IPC 传输的 `selection_text` 截断至 10KB（约 5000 个中文字符），防止用户全选超长页面导致 IPC 阻塞或 OOM
- **坐标系转换**: `content::ContextMenuParams` 中的 `(x, y)` 是相对于 WebContents 的坐标。传递到客户端后需要转换为 NSWindow 坐标系以正确定位 NSMenu

## 4. 非功能需求

- **性能**: 菜单弹出 < 100ms，菜单项点击到操作执行 < 50ms
- **兼容性**: 使用原生 `NSMenu`，自动适配 macOS 深色/浅色模式，支持 VoiceOver 辅助功能
- **内存**: 无常驻内存开销，菜单实例在关闭后释放

## 5. 数据模型变更

### Mojom 新增（扩展 `web_view.mojom`）

```
enum ContextMenuType { kPage, kLink, kImage, kSelection, kEditable };

struct ContextMenuParams {
  ContextMenuType type;
  bool is_editable;
  string? link_url;
  string? src_url;
  bool has_image_contents;
  string? selection_text;
  string page_url;
  int32 x;
  int32 y;
};

// WebViewObserver 新增方法:
OnContextMenu(ContextMenuParams params, uint64 menu_id);

// WebViewHost 新增方法:
ExecuteContextMenuAction(uint64 menu_id, int32 action_id);
```

### Bridge C-ABI 新增

```c
typedef void (*OWLBridge_ContextMenuCallback)(
    int type, bool is_editable, const char* link_url, const char* src_url,
    bool has_image_contents, const char* selection_text, const char* page_url,
    int x, int y, uint64_t menu_id, void* ctx);
OWL_EXPORT void OWLBridge_SetContextMenuCallback(OWLBridge_ContextMenuCallback cb, void* ctx);
OWL_EXPORT void OWLBridge_ExecuteContextMenuAction(uint64_t menu_id, int32_t action_id);
```

## 6. 影响范围

| 模块 | 影响 |
|------|------|
| `host/owl_real_web_contents.mm` | 修改 `HandleContextMenu`：仍返回 true 但提取参数转发（防止 Chromium 默认菜单） |
| `host/owl_web_contents.h/.cc` | 新增 context menu 转发逻辑 + menu_id 管理 |
| `mojom/web_view.mojom` | 新增 ContextMenuParams struct + Observer/Host 方法 |
| `bridge/owl_bridge_api.h/.cc` | 新增 C-ABI 回调和执行函数 |
| `bridge/OWLBridgeWebView.mm` | Mojo → C-ABI 桥接 |
| `client/OWLRemoteLayerView.mm` | 接收回调，构建并显示 NSMenu |
| **依赖** | TabManager（新标签页操作）、Module B DownloadManager（保存图片）、已有导航基础设施（GoBack/GoForward/Reload） |

## 7. 里程碑 & 优先级

| 优先级 | 功能 |
|--------|------|
| P0 | 五种上下文类型识别（含可编辑区域）+ 菜单显示 |
| P0 | 复制链接地址、复制文本（纯本地操作） |
| P0 | 后退/前进/重新加载（已有基础设施） |
| P0 | 在新标签页中打开（链接菜单核心功能） |
| P0 | 可编辑区域：剪切/复制/粘贴/全选 |
| P1 | 将图片存储到「下载」、复制图片、复制图片地址 |
| P1 | 搜索选中文本 |
| P1 | 查看页面源代码 |
| P2 | 复合场景（链接上的图片/文本）菜单合并 |
| P0 | 菜单项快捷键提示显示（NSMenu keyEquivalent，实现量极小） |

## 8. 验收标准（完整定义）

| AC | 描述 | 输入 | 操作 | 预期输出 |
|----|------|------|------|---------|
| AC-001 | 链接右键菜单 | 页面上有超链接 | 右键点击链接 | 弹出菜单含"在新标签页中打开"、"复制链接地址" |
| AC-002 | 图片右键菜单 | 页面上有图片 | 右键点击图片 | 弹出菜单含"将图片存储到「下载」"、"复制图片"、"复制图片地址" |
| AC-003 | 选中文本右键菜单 | 页面上选中一段文本 | 右键点击选区 | 弹出菜单含"复制"、"搜索'<选中文本>'" |
| AC-004a | 空白区域右键菜单(P0) | 页面空白区域 | 右键点击 | 弹出菜单含"后退"、"前进"、"重新加载" |
| AC-004b | 查看页面源代码(P1) | 页面空白区域 | 右键点击 | 菜单额外含"查看页面源代码"，点击后打开 view-source 页 |
| AC-005a | 复制链接地址 | 链接菜单显示中 | 点击"复制链接地址" | 链接 URL 写入系统剪贴板（NSPasteboard 可读取） |
| AC-005b | 在新标签页中打开 | 链接菜单显示中 | 点击"在新标签页中打开" | 新标签页打开，URL 为链接地址 |
| AC-005c | 将图片存储到「下载」 | 图片菜单显示中 | 点击"将图片存储到「下载」" | 图片文件出现在 ~/Downloads/ |
| AC-005d | 复制文本 | 选中文本菜单显示中 | 点击"复制" | 选中文本写入系统剪贴板 |
| AC-005e | 导航操作 | 空白区域菜单显示中 | 点击"后退"/"前进"/"重新加载" | 页面执行对应导航操作 |
| AC-005f | 可编辑区域菜单 | input/textarea 中 | 右键点击 | 弹出菜单含"剪切"、"复制"、"粘贴"、"全选"，操作正确执行 |
| AC-006 | XCUITest 验收 | 全部 P0 AC | 自动化测试 | XCUITest 端到端测试覆盖所有 P0 AC（AC-001~005f）；P1 AC（004b、005c）随对应功能解锁后补充 |

## 9. 开放问题

无待确认决策点。技术方案参考 `docs/modules/module-e-context-menu.md`。
