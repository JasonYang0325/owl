# Phase 2: 链接 + 选中文本 + 可编辑区域菜单

## 目标

扩展 Phase 1 的菜单框架，实现链接、选中文本和可编辑区域三种上下文类型的菜单。完成后覆盖 5 种上下文类型中的 4 种（除图片外全部 P0 功能）。

## 范围

| 操作 | 文件 | 内容 |
|------|------|------|
| 修改 | `host/owl_web_contents.h/.cc` | 扩展 action 分发：新标签页、搜索、WebContents::Cut/Copy/Paste/SelectAll |
| 修改 | `client/ContextMenuHandler.swift` | 扩展 NSMenu 构建：Link/Selection/Editable 三种类型 |
| 修改 | `bridge/owl_bridge_api.h/.cc` | 扩展 action_id 枚举（如需） |

## 依赖

- Phase 1（管线 + action 分发框架）

## 技术要点

1. **新标签页操作**: Host 侧调用 TabManager（或等效接口）用 `link_url` 创建新 tab。需校验 URL scheme（仅允许 http/https）
2. **复制到剪贴板**: Link 和 Selection 的复制操作在 Swift 层直接执行（`NSPasteboard.general.setString()`），不需要回调 Host
3. **搜索操作**: 拼接 `https://www.google.com/search?q=<encoded_text>`，用新标签页打开
4. **可编辑区域**: 使用 `WebContents::Cut()/Copy()/Paste()/SelectAll()`（非废弃的 `document.execCommand`）
5. **搜索显示文本**: 选中文本 ≤ 20 字符显示全文，> 20 字符截断为前 17 字符 + "..."
6. **selection_text 长度限制**: Mojo IPC 传输前截断至 10KB

## 验收标准

- [ ] 右键链接弹出菜单含"在新标签页中打开"、"复制链接地址"
- [ ] 点击"在新标签页中打开"打开新标签页，URL 正确
- [ ] 点击"复制链接地址"将 URL 写入系统剪贴板
- [ ] 右键选中文本弹出菜单含"复制"、"搜索'<文本>'"
- [ ] 点击"复制"将文本写入剪贴板
- [ ] 右键 input/textarea 弹出"剪切/复制/粘贴/全选"菜单，操作正确
- [ ] 特殊协议 URL（javascript:, file:）被拒绝，不打开新标签页

## 技术方案

### 1. 架构设计

Phase 2 在 Phase 1 管线基础上扩展，不新增架构层。变更集中在两处：
- **Host**: `ExecuteContextMenuAction` 从 stub 变为实际分发
- **Swift**: `ContextMenuHandler.showContextMenu` 扩展 3 种新菜单类型

```
Phase 1 管线（不变）:
  HandleContextMenu → OnContextMenu → C-ABI callback → Swift

Phase 2 新增的执行路径:
  a) Swift 本地: 复制链接/复制文本 → NSPasteboard（不经 Host）
  b) Host-only:  新标签页/搜索/剪切/粘贴/全选 → ExecuteContextMenuAction IPC → Host 分发
```

### 2. Mojom 变更

扩展 `ContextMenuAction` 枚举（web_view.mojom）：

```mojom
enum ContextMenuAction {
  kCopyLink,       // 已有（Swift 本地，不经此路径）
  kCopyImage,      // Phase 3
  kSaveImage,      // Phase 3
  kCopy,           // 已有（Swift 本地，选中文本场景）
  kCut,            // 已有
  kPaste,          // 已有
  kSelectAll,      // 已有
  kOpenLinkInNewTab,  // 新增 Phase 2
  kSearch,            // 新增 Phase 2
};
```

### 3. Host: ExecuteContextMenuAction 实现

**设计决策**: 不在 Host 缓存 link_url/selection_text。Swift 已收到这些数据，需要 Host 操作时随 action 传回。

修改 Mojom `ExecuteContextMenuAction` 签名携带 payload：

```mojom
// 扩展签名：增加 optional payload 参数
ExecuteContextMenuAction(ContextMenuAction action, uint32 menu_id, string? payload);
```

```cpp
void RealWebContents::ExecuteContextMenuAction(int32_t action, uint32_t menu_id,
                                                const std::string& payload) {
  if (menu_id != current_menu_id_) return;  // 过期菜单

  auto* wc = web_contents();
  switch (static_cast<owl::mojom::ContextMenuAction>(action)) {
    case owl::mojom::ContextMenuAction::kOpenLinkInNewTab: {
      GURL url(payload);  // payload = link_url（Swift 传回）
      if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS()) break;
      // 通过 OWLBrowserContext 创建新 WebView
      break;
    }
    case owl::mojom::ContextMenuAction::kSearch: {
      // payload = selection_text（Swift 传回，已截断）
      // 过滤控制字符/换行符后编码
      std::string clean = base::CollapseWhitespaceASCII(payload, true);
      std::string query = net::EscapeQueryParamValue(clean, false);
      GURL search_url("https://www.google.com/search?q=" + query);
      // 通过新标签页打开
      break;
    }
    case owl::mojom::ContextMenuAction::kCopy:
      wc->Copy(); break;  // editable 区域的复制
    case owl::mojom::ContextMenuAction::kCut:
      wc->Cut(); break;
    case owl::mojom::ContextMenuAction::kPaste:
      wc->Paste(); break;
    case owl::mojom::ContextMenuAction::kSelectAll:
      wc->SelectAll(); break;
    case owl::mojom::ContextMenuAction::kCopyLink:
    case owl::mojom::ContextMenuAction::kCopyImage:
    case owl::mojom::ContextMenuAction::kSaveImage:
      NOTREACHED() << "Should be handled client-side or in Phase 3";
      break;
  }
}
```

**优势**: 无 Host 缓存状态，无 menu_id 与缓存错配风险。Swift 自主决定传什么参数。

### 4. Swift: ContextMenuHandler 扩展

```swift
@MainActor
func showContextMenu(type: Int, isEditable: Bool, linkUrl: String?,
                     srcUrl: String?, selectionText: String?,
                     pageUrl: String, x: Int, y: Int, menuId: UInt32) {
    self.currentMenuId = menuId
    let menu = NSMenu()

    switch ContextMenuType(rawValue: type) {
    case .editable:  // 优先级 0
        menu.addItem(makeItem("剪切", action: .cut, key: "x"))
        menu.addItem(makeItem("复制", action: .copy, key: "c"))
        menu.addItem(makeItem("粘贴", action: .paste, key: "v"))
        menu.addItem(.separator())
        menu.addItem(makeItem("全选", action: .selectAll, key: "a"))

    case .link:  // 优先级 1
        guard let url = linkUrl, !url.isEmpty else { return }  // 空 URL 不显示菜单
        menu.addItem(makeItem("在新标签页中打开", action: .openLinkInNewTab, payload: url))
        menu.addItem(makeLocalItem("复制链接地址") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
        })

    case .selection:  // 优先级 3
        menu.addItem(makeLocalItem("复制") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selectionText ?? "", forType: .string)
        })
        let searchText = truncateForDisplay(selectionText ?? "", maxLen: 20)
        menu.addItem(makeItem("搜索\"\(searchText)\"", action: .search))

    case .page:  // 优先级 4（Phase 1 已实现）
        // ... 后退/前进/重新加载

    default: break
    }

    let pt = view.convert(NSPoint(x: CGFloat(x), y: CGFloat(y)), to: nil)
    menu.popUp(positioning: nil, at: pt, in: view)
}

// 本地操作（不走 IPC）
private func makeLocalItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem { ... }

// Host 操作（走 ExecuteContextMenuAction IPC）
private func makeItem(_ title: String, action: ContextMenuAction, key: String = "") -> NSMenuItem { ... }
```

### 5. 文件变更清单

| 文件 | 操作 | 变更 |
|------|------|------|
| `mojom/web_view.mojom` | 修改 | +kOpenLinkInNewTab, +kSearch; ExecuteContextMenuAction 签名 +payload 参数 |
| `host/owl_real_web_contents.mm` | 修改 | ExecuteContextMenuAction 实现分发; HandleContextMenu 缓存 link_url/selection_text; URL scheme 过滤 |
| `bridge/owl_bridge_api.h` | 无变更 | C-ABI 接口不变（action_id 是 int32_t，枚举值变化不影响 ABI） |
| `bridge/owl_bridge_api.cc` | 无变更 | 透传逻辑不变 |
| Swift 客户端 | 修改 | ContextMenuHandler 扩展 Link/Selection/Editable 菜单构建 |

### 6. 测试策略

**C++ GTest**:
- `ExecuteAction_OpenLinkInNewTab`: 验证 kOpenLinkInNewTab 调用新标签页创建
- `ExecuteAction_Search`: 验证搜索 URL 正确拼接
- `ExecuteAction_CutPasteSelectAll`: 验证 WebContents 编辑命令调用
- `ExecuteAction_SchemeFilter`: 验证 javascript:/file: URL 被拒绝
- `ExecuteAction_StaleMenuId`: 验证过期 menu_id 被忽略（复用 Phase 1 机制）

**注意**: Phase 1 反馈指出单元测试的结构性限制（镜像测试），Phase 2 应尽量通过 `RealExecuteContextMenuAction` 函数指针测试真实分发逻辑。

### 7. 风险 & 缓解

| 风险 | 缓解 |
|------|------|
| 新标签页创建依赖 TabManager 接口 | 如果 TabManager 不存在，降级为 Navigate 当前标签页 |
| kCut/kPaste 在非可编辑区域调用 | HandleContextMenu 已通过 type 判定，kEditable 才有这些选项 |
| 搜索 URL 中特殊字符 | 使用 net::EscapeQueryParamValue 编码 |
| selection_text 为空但 type 为 kSelection | HandleContextMenu 中 selection_text 非空才设为 kSelection |

## 状态

- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
