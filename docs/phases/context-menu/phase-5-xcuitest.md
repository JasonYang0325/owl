# Phase 5: XCUITest 端到端验收

## 目标

AC-006: XCUITest 覆盖 AC-001~AC-005f，端到端验证右键菜单功能。

## 范围

| 操作 | 文件 | 内容 |
|------|------|------|
| 新增 | `owl-client-app/UITests/ContextMenuUITests.swift` | XCUITest 用例 |
| 新增 | `owl-client-app/Tests/Resources/context-menu-test.html` | 测试用 HTML 页面 |

## 依赖

- Phase 4 Swift 客户端已完成
- XCUITest 签名（resign_for_testing.sh）
- GUI 环境

## 技术方案

### 1. 测试 HTML 页面

本地 HTML，不依赖外网：

```html
<!DOCTYPE html>
<html><body>
  <a id="link" href="https://example.com">Test Link</a>
  <img id="img" src="data:image/png;base64,iVBOR..." width="100" height="100">
  <p id="text">Selectable text for context menu</p>
  <input id="input" type="text" value="editable">
  <div id="blank" style="height:200px;background:#eee"></div>
</body></html>
```

图片使用 base64 data URI（小 PNG），避免网络依赖。

### 2. XCUITest 用例

```swift
class ContextMenuUITests: XCTestCase {
    func testLinkContextMenu()      // AC-001: 右键链接 → 菜单项
    func testImageContextMenu()     // AC-002: 右键图片 → 菜单项
    func testSelectionContextMenu() // AC-003: 选中文本 → 菜单项
    func testPageContextMenu()      // AC-004a: 空白区域 → 菜单项
    func testCopyLinkUrl()          // AC-005a: 复制链接到剪贴板
    func testCopyText()             // AC-005d: 复制文本到剪贴板
    func testNavigationActions()    // AC-005e: 后退/前进/重新加载
    func testEditableMenu()         // AC-005f: 可编辑区域菜单
}
```

### 3. 右键模拟

```swift
let webView = app.webViews.firstMatch
// 右键 = 控制+点击 or .rightClick()
webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
// 菜单项查找
let menuItem = app.menuItems["复制链接地址"]
XCTAssertTrue(menuItem.waitForExistence(timeout: 2))
menuItem.click()
```

### 4. 已知限制

- XCUITest 签名依赖开发者账号
- WebView 内元素定位可能不精确（用坐标偏移）
- 菜单弹出时机可能需要 waitForExistence

## 状态

- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 测试通过
