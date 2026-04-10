# Phase 5: XCUITest E2E

## 目标
- 编写端到端 XCUITest 覆盖 AC-001~005 的关键场景
- 包含测试用 HTML 页面

## 范围

### 新增文件
| 文件 | 内容 |
|------|------|
| `owl-client-app/UITests/OWLNavigationUITests.swift` | XCUITest 测试用例 |
| `owl-client-app/UITests/TestNavigationHTMLServer.swift` | 可选：测试 HTTP 服务器（如需 Auth 测试） |

### 修改文件
| 文件 | 变更 |
|------|------|
| `owl-client-app/UITests/` 目录 | 可能需要共享的测试辅助方法 |

## 依赖
- Phase 2（进度条 + 错误页面 UI）
- Phase 3（Auth 对话框 UI）

## 技术要点

### 测试用例

#### (a) 正常导航进度条可见性
```swift
func testProgressBarVisibleDuringNavigation() {
    // 导航到一个有效页面
    // 验证进度条元素存在且可见
    // 等待加载完成
    // 验证进度条消失
}
```

#### (b) 导航到无效域名显示错误页
```swift
func testNavigationErrorPage() {
    // 导航到 https://this-domain-does-not-exist-12345.com
    // 等待错误页面出现
    // 验证标题包含"无法访问"
    // 验证"重试"按钮存在
    // 点击重试按钮
    // 验证再次尝试加载
}
```

#### (c) 停止加载按钮
```swift
func testStopLoadingButton() {
    // 导航到一个页面
    // 在加载中验证停止按钮可见
    // 点击停止按钮
    // 验证进度条消失
    // 验证不显示错误页面
}
```

#### (d) Auth 对话框弹出和提交
```swift
func testAuthDialogAppears() {
    // 导航到需要 401 认证的页面（需要本地测试服务器）
    // 验证 Auth 对话框出现
    // 验证 realm 和 URL 显示
    // 输入用户名密码
    // 点击登录
    // 验证对话框关闭
}
```

### 已知陷阱
- XCUITest 需要签名配置（Apple 开发者账号），编译通过但运行需要签名
- 进度条存在时间很短，需要合理的等待策略
- Auth 测试需要本地 HTTP 服务器返回 401（可用 TestNavigationHTMLServer）
- 现有 XCUITest 框架参考: OWLBrowserUITests.swift, OWLDownloadUITests.swift

### 可达性说明
- 编译验证: `run_tests.sh xcuitest` 可验证编译
- 运行验证: 需要签名 + GUI 环境，CI 中可能跳过

## 验收标准
- [ ] XCUITest 编译通过（`run_tests.sh xcuitest`）
- [ ] 测试覆盖 4 个场景（进度条/错误页/停止/Auth）
- [ ] 每个测试有明确的断言
- [ ] 不依赖外部网络（使用 localhost 测试服务器或无效域名）

## 状态
- [ ] 技术方案评审
- [ ] 开发完成
- [ ] 代码评审通过
- [ ] 测试通过
