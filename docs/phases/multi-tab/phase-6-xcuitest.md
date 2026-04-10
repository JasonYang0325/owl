# Phase 6: XCUITest E2E + 回归测试

## 目标
- XCUITest 覆盖所有 AC（AC-001~009）
- 验证已有功能在多标签环境下无回归
- 确保 webview_id=0 兼容层已完全移除

## 范围

### 新增文件
| 文件 | 内容 |
|------|------|
| `owl-client-app/OWLXCUITests/MultiTabXCUITests.swift` | E2E 测试 suite |
| `owl-client-app/OWLXCUITests/Resources/multi-tab-test.html` | 测试用 HTML 页面（含 target="_blank" 链接等） |

### 修改文件
| 文件 | 变更 |
|------|------|
| `bridge/owl_bridge_api.cc` | 移除 webview_id=0 兼容层，改为 DCHECK_NE(webview_id, 0u) |

## 依赖
- Phase 1-5 全部完成

## 技术要点

### 测试用例矩阵

| AC | 测试场景 | 验证方法 |
|----|---------|---------|
| AC-001 | 创建 2 个标签，各自导航不同 URL | 验证两个标签标题独立 |
| AC-002 | 在标签 A/B 间切换 | 验证渲染区域内容切换 |
| AC-003 | 关闭标签 B | 验证 B 从列表消失，A 不受影响 |
| AC-004 | 退出重启 | 验证标签列表恢复一致 |
| AC-005 | 右键固定标签 | 验证固定标签样式 + 关闭保护 |
| AC-006 | 关闭标签后 Cmd+Shift+T | 验证恢复到正确 URL 和位置 |
| AC-007 | 点击 target="_blank" 链接 | 验证新标签创建 |
| AC-008 | 运行完整 suite | 全部通过 |
| AC-009 | 多标签下执行 Find/Zoom/Bookmarks | 验证操作正确路由到活跃标签 |

### 兼容层移除
- 搜索所有 `webview_id == 0` 的路由逻辑
- 替换为 `DCHECK_NE(webview_id, 0u)` + 错误返回
- 验证所有调用方已传递有效 webview_id

### 已知约束
- XCUITest 运行需要 Apple 开发者签名
- 如无签名环境，测试可编译验证但无法运行（与 Module E XCUITest 同样的约束）

## 验收标准
- [ ] XCUITest suite 编译通过
- [ ] 所有 AC 测试用例定义完整
- [ ] webview_id=0 兼容层已移除
- [ ] 签名环境下所有测试通过（AC-008）

## 技术方案

### 1. 架构设计

Phase 6 有两个独立工作项：
1. **XCUITest E2E suite**（新增测试，编译验证为主 — 运行需签名环境）
2. **webview_id=0 兼容层移除**（Bridge 层安全加固）

### 2. XCUITest 结构

```swift
// owl-client-app/OWLXCUITests/MultiTabXCUITests.swift
class MultiTabXCUITests: XCTestCase {
    let app = XCUIApplication()
    
    override func setUp() {
        continueAfterFailure = false
        app.launch()
    }
    
    // AC-001: 独立 WebView
    func testMultipleTabsIndependentNavigation() { ... }
    // AC-002: 渲染表面切换
    func testTabSwitchRendering() { ... }
    // AC-003: 资源释放
    func testCloseTabReleasesResources() { ... }
    // AC-004: 会话恢复
    func testSessionRestore() { ... }
    // AC-005: 固定标签
    func testPinTab() { ... }
    // AC-006: 撤销关闭
    func testUndoCloseTab() { ... }
    // AC-007: 新标签打开
    func testTargetBlankOpensNewTab() { ... }
    // AC-009: 回归
    func testFindInPageOnActiveTab() { ... }
    func testZoomOnActiveTab() { ... }
}
```

### 3. 测试 HTML 页面

```html
<!-- owl-client-app/OWLXCUITests/Resources/multi-tab-test.html -->
<!DOCTYPE html>
<html>
<body>
  <h1 id="page-title">Multi-Tab Test Page</h1>
  <a id="blank-link" href="https://example.com" target="_blank">Open in New Tab</a>
  <a id="normal-link" href="https://example.org">Normal Link</a>
  <p id="content">Test content for tab identification</p>
</body>
</html>
```

### 4. webview_id=0 兼容层移除

在 `bridge/owl_bridge_api.cc` 的 `GetWebViewEntry()` 中：

```cpp
// 现有：
if (webview_id == 0) {
    uint64_t active = g_active_webview_id.load();
    if (active == 0) return nullptr;
    DLOG(WARNING) << "webview_id=0 used...";
    webview_id = active;
}

// 改为：
if (webview_id == 0) {
    DCHECK_NE(webview_id, 0u) << "webview_id=0 is no longer supported";
    LOG(ERROR) << "webview_id=0 called, returning nullptr";
    return nullptr;
}
```

同时 grep 确认所有 Swift/ObjC 调用方传递了有效 webview_id（不再传 0）。

### 5. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `owl-client-app/OWLXCUITests/MultiTabXCUITests.swift` | 新增 | E2E 测试 suite |
| `owl-client-app/OWLXCUITests/Resources/multi-tab-test.html` | 新增 | 测试 HTML |
| `bridge/owl_bridge_api.cc` | 修改 | 移除 webview_id=0 兼容层 |

### 6. 测试策略

- XCUITest 编译验证：`owl-client-app/scripts/run_tests.sh xcuitest`
- 签名环境下运行完整 suite
- 兼容层移除后运行全量 GTest 确认无回归：`run_tests.sh cpp`

### 7. 风险 & 缓解

| 风险 | 缓解 |
|------|------|
| XCUITest 无签名环境无法运行 | 编译通过即可，与 Module E 同等约束 |
| 兼容层移除可能暴露遗漏的 webview_id=0 调用 | 移除前 grep 验证，release build 用 LOG(ERROR)+nullptr 而非 crash |

## 状态
- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
