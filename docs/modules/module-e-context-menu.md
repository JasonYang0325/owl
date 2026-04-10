# Module E: 右键上下文菜单

| 属性 | 值 |
|------|-----|
| 优先级 | P1 |
| 依赖 | 无 |
| 预估规模 | ~400 行 |
| 状态 | pending |

## 目标

当前右键菜单被完全抑制（`HandleContextMenu` 返回 true）。本模块实现原生右键菜单：根据点击目标（链接/图片/文本/页面）显示不同菜单项。

## 用户故事

As a 浏览器用户, I want 右键点击页面元素时看到上下文菜单, so that 我可以复制链接、保存图片、查看源码等。

## 验收标准

- AC-001: 右键链接 → 显示"在新标签页中打开"、"复制链接地址"
- AC-002: 右键图片 → 显示"保存图片"、"复制图片"、"复制图片地址"
- AC-003: 右键选中文本 → 显示"复制"、"搜索"
- AC-004: 右键空白区域 → 显示"后退"、"前进"、"重新加载"、"查看页面源代码"
- AC-005: 菜单项点击后执行对应操作

## 技术方案

### 层级分解

#### 1. Host C++

修改 `owl_real_web_contents.mm`:
- `HandleContextMenu()` 不再返回 true
- 改为捕获 `content::ContextMenuParams` 并通过 Observer 发送

#### 2. Mojom（扩展 `web_view.mojom`）

```
enum ContextMenuType {
  kPage,
  kLink,
  kImage,
  kSelection,
  kMedia,
};

struct ContextMenuParams {
  ContextMenuType type;
  string? link_url;
  string? src_url;       // 图片/媒体 URL
  string? selection_text;
  string page_url;
  int32 x;
  int32 y;
};

// WebViewObserver 新增:
OnContextMenu(ContextMenuParams params, uint64 menu_id);

// WebViewHost 新增:
ExecuteContextMenuAction(uint64 menu_id, int32 action_id);
```

#### 3. Bridge C-ABI

```c
typedef void (*OWLBridge_ContextMenuCallback)(
    int type, const char* link_url, const char* src_url,
    const char* selection_text, int x, int y, uint64_t menu_id, void* ctx);
OWL_EXPORT void OWLBridge_SetContextMenuCallback(OWLBridge_ContextMenuCallback cb, void* ctx);
OWL_EXPORT void OWLBridge_ExecuteContextMenuAction(uint64_t menu_id, int32_t action_id);
```

#### 4. Swift / AppKit

直接使用 `NSMenu` 构建原生菜单（不用 SwiftUI，macOS 右键菜单必须是 NSMenu）：
- 根据 `ContextMenuType` 组装菜单项
- 菜单项 action 调用 C-ABI 或本地操作（如复制到剪贴板）

## 测试计划

| 层级 | 测试内容 |
|------|---------|
| C++ GTest | ContextMenuParams 正确提取 |
| E2E Pipeline | 模拟右键 → 验证回调参数 |

## 文件清单

| 操作 | 文件 |
|------|------|
| 修改 | `mojom/web_view.mojom`（ContextMenuParams + Observer） |
| 修改 | `host/owl_real_web_contents.mm`（HandleContextMenu） |
| 修改 | `host/owl_web_contents.h/.cc`（转发） |
| 修改 | `bridge/owl_bridge_api.h/.cc` |
| 新增 | `owl-client-app/Services/ContextMenuHandler.swift` |
| 修改 | `bridge/OWLBridgeWebView.mm`（接收 ContextMenu 回调，桥接到 Swift） |
