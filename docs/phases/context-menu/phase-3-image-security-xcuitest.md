# Phase 3: 图片菜单 + 安全加固 + XCUITest

## 目标

实现图片右键菜单（P1），添加安全加固措施，完成 XCUITest 端到端验收测试覆盖所有 AC。

## 范围

| 操作 | 文件 | 内容 |
|------|------|------|
| 修改 | `host/owl_web_contents.h/.cc` | 图片保存（复用 Module B DownloadManager）、复制图片数据、查看页面源代码 |
| 修改 | `client/ContextMenuHandler.swift` | Image 类型菜单 + CORS 降级逻辑 |
| 修改 | `host/owl_web_contents.h/.cc` | URL scheme 过滤逻辑（安全加固） |
| 新增 | XCUITest 文件 | 端到端验收测试 |
| 修改 | C++ GTest | 扩展测试覆盖图片和安全场景 |

## 依赖

- Phase 2（链接/文本/可编辑区域菜单）
- Module B DownloadManager（保存图片）

## 技术要点

1. **保存图片**: 复用 Module B 的下载链路，用 `src_url` 触发下载到 `~/Downloads`
2. **复制图片**: Host 获取图片数据（通过 `content::WebContents` API），成功则写入 `NSPasteboard` 为图片数据；CORS 失败则降级复制 `src_url` 为文本
3. **查看页面源代码 (P1)**: 用 `view-source:<page_url>` 打开新标签页。`view-source:` 仅限内部使用，不从 `link_url` 接受
4. **安全加固**: 所有打开新标签页的操作执行前校验 URL scheme，拒绝 `javascript:`/`file:`/`data:`（>10KB）
5. **XCUITest**: 需要准备测试用 HTML 页面（含链接、图片、文本、input 等元素），通过 XCUITest 模拟右键点击验证菜单弹出和操作执行

## 验收标准

- [ ] 右键图片弹出菜单含"将图片存储到「下载」"、"复制图片"、"复制图片地址"
- [ ] 点击"将图片存储到「下载」"图片文件出现在 ~/Downloads/
- [ ] 点击"复制图片"图片数据写入剪贴板（或 CORS 失败时降级复制 URL）
- [ ] 查看页面源代码：点击后打开 view-source 页
- [ ] javascript:/file: URL 被拒绝
- [ ] XCUITest 覆盖 AC-001 到 AC-005f，全部通过

## 技术方案

### 1. 架构设计

Phase 3 在 Phase 1/2 管线上扩展：
- **Host**: ExecuteContextMenuAction 新增 kSaveImage/kCopyImage/kViewSource 处理
- **Swift**: Image 类型菜单构建 + CORS 降级 + view-source
- **XCUITest**: 端到端验收（解决 Phase 1/2 镜像测试无法覆盖真实路径的问题）

```
Phase 3 新增执行路径:
  kSaveImage   → Host 触发 DownloadManager 下载 src_url
  kCopyImage   → Host 获取图片数据 → C-ABI 回调 → Swift NSPasteboard
                  (CORS 失败 → 降级复制 src_url 文本)
  kCopyImageUrl → Swift 本地 NSPasteboard（不经 Host）
  kViewSource  → Host 导航到 view-source:<page_url>
```

### 2. Mojom 变更

无新增类型。kCopyImage/kSaveImage/kCopyLink 已在 Phase 1 定义。Phase 2 添加的 payload 参数可复用。

需要为 kCopyImage 的异步结果添加回调（或新的 Observer 方法）：

```mojom
// WebViewObserver 新增（图片复制结果回调）
OnCopyImageResult(bool success, string? fallback_url);
```

### 3. Host: ExecuteContextMenuAction 扩展

```cpp
case owl::mojom::ContextMenuAction::kSaveImage: {
  GURL url(payload);  // payload = src_url
  if (!url.is_valid()) break;
  // 复用 Module B DownloadManager 链路
  // content::DownloadManager* dm = content::BrowserContext::GetDownloadManager(browser_context_);
  // dm->DownloadUrl(...) 或通过已有的 OWLDownloadManagerDelegate
  break;
}
case owl::mojom::ContextMenuAction::kCopyImage: {
  GURL url(payload);  // payload = src_url
  if (!url.is_valid()) break;
  // 通过 WebContents 获取图片数据
  // 方案 A: 使用 content::WebContents::DownloadImage()
  wc->DownloadImage(
      url, false, gfx::Size(), 0, false,
      base::BindOnce(&RealWebContents::OnImageDownloaded,
                     weak_factory_.GetWeakPtr(), url));
  break;
}
case owl::mojom::ContextMenuAction::kViewSource: {
  // payload = page_url（由 Swift 传回）
  GURL page_url(payload);
  if (!page_url.is_valid() || !page_url.SchemeIsHTTPOrHTTPS()) break;
  GURL view_source_url("view-source:" + page_url.spec());
  // 在当前标签页导航到 view-source URL
  wc->GetController().LoadURL(view_source_url, content::Referrer(),
                               ui::PAGE_TRANSITION_LINK, std::string());
  break;
}
```

### 4. 图片复制回调

```cpp
void RealWebContents::OnImageDownloaded(
    const GURL& fallback_url,
    int id, int status_code,
    const GURL& image_url,
    const std::vector<SkBitmap>& bitmaps,
    const std::vector<gfx::Size>& sizes) {
  if (bitmaps.empty()) {
    // CORS 失败或图片不可获取 → 通知 Swift 降级
    (*observer_)->OnCopyImageResult(false, fallback_url.spec());
    return;
  }
  // 将图片数据编码为 PNG，通过 C-ABI 回调传给 Swift 写入 NSPasteboard
  // 或直接在 Host 侧写 NSPasteboard（ObjC++ 可直接用 AppKit）
  NSImage* image = /* 从 SkBitmap 转换 */;
  [[NSPasteboard generalPasteboard] clearContents];
  [[NSPasteboard generalPasteboard] writeObjects:@[image]];
  (*observer_)->OnCopyImageResult(true, std::nullopt);
}
```

**设计决策**: 图片写剪贴板直接在 Host ObjC++ 层完成（HandleContextMenu 已在主线程），无需经 C-ABI 传图片数据到 Swift。降级时通知 Swift 复制 URL。

### 5. XCUITest 端到端验收

#### 5.1 测试 HTML 页面

创建 `owl-client-app/Tests/Resources/context-menu-test.html`：

```html
<!DOCTYPE html>
<html>
<body>
  <a id="test-link" href="https://example.com">Test Link</a>
  <img id="test-image" src="https://via.placeholder.com/100" alt="Test Image">
  <p id="test-text">This is selectable text for context menu testing</p>
  <input id="test-input" type="text" value="editable content">
  <div id="blank-area" style="height:200px"></div>
</body>
</html>
```

#### 5.2 XCUITest 用例

```swift
// ContextMenuXCUITests.swift
class ContextMenuXCUITests: XCTestCase {
    // AC-001: 右键链接 → 菜单含"在新标签页中打开"、"复制链接地址"
    func testLinkContextMenu() {
        // 导航到测试页 → 右键 #test-link → 验证菜单项
    }

    // AC-002: 右键图片 → 菜单含"将图片存储到「下载」"等
    func testImageContextMenu() { ... }

    // AC-003: 选中文本右键 → 菜单含"复制"、"搜索"
    func testSelectionContextMenu() { ... }

    // AC-004a: 空白区域右键 → 后退/前进/重新加载
    func testPageContextMenu() { ... }

    // AC-005a: 复制链接地址 → 剪贴板验证
    func testCopyLinkUrl() { ... }

    // AC-005b: 在新标签页中打开
    func testOpenLinkInNewTab() { ... }

    // AC-005d: 复制文本 → 剪贴板验证
    func testCopyText() { ... }

    // AC-005e: 后退/前进/重新加载执行
    func testNavigationActions() { ... }

    // AC-005f: 可编辑区域菜单
    func testEditableContextMenu() { ... }
}
```

#### 5.3 XCUITest 右键模拟

macOS XCUITest 支持 `.rightClick()` 方法：
```swift
let element = app.webViews.firstMatch.links["test-link"]
element.rightClick()
// 菜单项通过 app.menuItems["在新标签页中打开"] 查找
```

### 6. 文件变更清单

| 文件 | 操作 | 变更 |
|------|------|------|
| `mojom/web_view.mojom` | 修改 | +OnCopyImageResult Observer 方法 |
| `host/owl_real_web_contents.mm` | 修改 | ExecuteContextMenuAction: +kSaveImage/kCopyImage/kViewSource; +OnImageDownloaded 回调 |
| `bridge/owl_bridge_api.h/.cc` | 修改 | +CopyImageResult C-ABI 回调（如需通知 Swift 降级） |
| Swift ContextMenuHandler | 修改 | Image 菜单 + CORS 降级 UI 反馈 |
| 新增 XCUITest | 新增 | 端到端验收测试 |
| 新增 测试 HTML | 新增 | context-menu-test.html |
| C++ GTest | 修改 | +kSaveImage/kCopyImage/kViewSource 测试 |

### 7. 测试策略

**C++ GTest**: 图片 action 分发、view-source URL 构建、scheme 过滤
**XCUITest**: 真正的端到端验收（解决 Phase 1/2 镜像测试的结构性限制）：
- 每个 AC 有对应的 XCUITest
- 验证菜单弹出、菜单项存在、操作执行结果
- 使用本地 HTML 测试页面

### 8. 风险 & 缓解

| 风险 | 缓解 |
|------|------|
| DownloadImage CORS 失败 | 降级复制 URL，通过 OnCopyImageResult 通知 Swift |
| XCUITest 右键在 WebView 中不稳定 | 使用坐标定位替代 accessibility 查找 |
| view-source: URL 可能被安全策略阻止 | 在 Host 侧直接 LoadURL，不经 Swift 外部调用 |
| Module B DownloadManager 可能未就绪 | 如未就绪，kSaveImage 降级为打开 src_url 在新标签页 |

## 状态

- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
