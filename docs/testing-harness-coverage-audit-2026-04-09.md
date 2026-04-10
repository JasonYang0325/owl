# OWL Browser 测试 Harness 覆盖审计

**日期**: 2026-04-09  
**作者**: Codex review  
**目标**: 评估当前测试框架是否足以覆盖项目中的主要用户用例，判断这套 harness 是真正有用，还是“看起来很多测试，但无法有效防止真实回归”。
**更新**:
- 当日后续修复已收敛 pipeline 挂起（`OWLTestBridge` 回调签名/退出回收 + pipeline 过滤器）
- 已补齐最小 cross-layer harness（`AppHost / WaitHelper / ProcessGuard`）并落地真实 `OWLIntegrationTests`

---

## 一句话结论

当前 harness **不是虚有其表**，但也**不能证明当前项目中的所有主要用户用例都被完整覆盖**。

更准确地说，它现在的状态是：

- 底层模块测试有价值，能挡住一部分实现级回归
- 顶层 UI / E2E 也不是空白，已经覆盖了一些真实链路
- 默认门禁已覆盖一条真实跨层旅程，但覆盖宽度仍不足
- 中间层 integration harness 已建立最小版本，但 case 仍偏少
- 多个真实用户入口仍缺少确定性、可重复、可门禁的测试

因此，当前测试体系只能提供**中等信心**，还不能提供“用户照着真实功能再做一遍也不会出问题”的发布级信心。

---

## 判断 Harness 是否真的有用的标准

一套测试 harness 真正有用，至少要同时满足下面几条：

1. **关键用户旅程能在默认门禁中被跑到**
   - 不是只有底层纯函数、ViewModel、mock 路径在跑
   - 而是用户高频入口真的被执行到

2. **断言的是用户可见结果，不只是“没崩”**
   - 例如 URL 真的变化、列表真的更新、状态真的持久化、错误提示真的出现
   - 不是只看 exit code 为 0 或函数被调用过

3. **测试是确定性的**
   - 不依赖外网
   - 不依赖签名/人工前台/随机 timing
   - 不依赖 skip 才能保持“绿”

4. **测试本身是稳定可执行的**
   - 不会经常挂住
   - 不需要靠超时硬杀来收尾
   - 不会误入真实 bridge / host 路径导致 unit test 崩溃

5. **覆盖矩阵能对上当前功能面**
   - 每个用户可见功能至少有一条可信的验证路径
   - 错误路径、持久化、重启恢复、多步交互、异步竞争至少有基本覆盖

---

## 当前总体现状

### 明显有价值的部分

- C++ GTest 基础量比较大，底层 Host 逻辑并非空白
- Swift ViewModel 测试在 History / Downloads / Console / Tabs / Bookmarks / Session Restore 等模块已形成一定规模
- XCUITest 和 pipeline 也已经覆盖到部分真实浏览器行为
- `run_tests.sh` 已经提供统一入口，并能写 `run.log` 与 `summary.json`

### 明显不够硬的部分

- 默认 `e2e` 已包含 `integration`，但仍**不包含** CLI、XCUITest、system、dual-e2e
- cross-layer harness 目前只有 1 个稳定 case，覆盖宽度不足
- CLI 测试仍是 smoke test，主要检查退出码，不验证语义
- Storage / Settings / Address Bar / AI / Socket 等真实入口覆盖明显偏弱
- 部分 unit test 不 hermetic，会误入真实 bridge 路径
- 顶层 UI 测试仍受签名、外网、窗口状态、skip 等因素影响

---

## 模块级覆盖矩阵

状态定义：

- **已覆盖**: 有单测/集成/UI 组合证据，且对用户主流程已有较强信心
- **部分覆盖**: 有测试，但存在明显缺口、脆弱性、失败点或只覆盖部分路径
- **基本未覆盖**: 功能存在，但当前主测试面中证据很弱
- **未建立**: 对应测试层本身还未成型

| 模块 | 关键用户用例 | 当前主要证据 | 覆盖判断 | 主要问题 |
|------|--------------|--------------|----------|----------|
| History | 导航后入历史、搜索、删除、撤销、回跳 | ViewModel + UI | 已覆盖 | 缺重启后持久化验证 |
| Downloads | 触发下载、查看进度、暂停/恢复、取消 | ViewModel + UI | 已覆盖 | 缺文件系统副作用/重启场景 |
| Console | 输出显示、过滤、搜索、清空 | ViewModel + UI | 已覆盖 | 缺多标签隔离与重载场景 |
| Bookmarks | 添加、删除、列表、星标、导航 | ViewModel + pipeline 部分 | 部分覆盖 | UI 星标入口与持久化较弱 |
| Tabs / Session Restore | 新建、关闭、撤销关闭、Pin、恢复会话 | Unit + UI | 部分覆盖 | unit 隔离不稳，真实 bridge 误入 |
| Permissions | 权限弹窗、超时自动拒绝、设置页修改 | Unit + Settings VM | 部分覆盖 | 存在失败 case，真实 UI 闭环不足 |
| Navigation / Browser Flow | 输入地址、导航、stop、前进后退、错误页 | pipeline + UI | 部分覆盖 | AddressBar 壳层与失败路径覆盖仍不足 |
| Context Menu | 链接/图片/文本/页面右键 | C++ + UI | 部分覆盖 | Host 侧仍残留 mirror-test 风险 |
| Storage / Cookies | cookie list/delete、storage usage、clear data | 服务/UI/CLI 入口存在 | 基本未覆盖 | 缺成体系测试 |
| Settings UI | Settings 分组页、Storage/Permissions 面板交互 | UI 已存在 | 基本未覆盖 | 缺配套 UI 套件 |
| Address Bar 壳层 | 聚焦、显示切换、输入、回车、失焦恢复 | 真实实现已存在 | 基本未覆盖 | 缺稳定专测 |
| CLI | page/cookie/storage/bookmark/history 命令 | smoke test | 基本未覆盖 | 只测退出码，不测语义 |
| AI / Socket | AI chat、IPC/Socket 协作 | 代码存在 | 基本未覆盖 | 几乎不在主测试面 |
| Cross-layer Harness | AppHost + Bridge + Host/Renderer 串联 | `OWLIntegrationTests` + `OWLTestKit` | 部分覆盖 | 已建立最小可用层，但仅 1 个 case，需扩展到多模块 |

---

## 模块级详细清单

### 1. History

**当前用户用例**

- 浏览页面后写入历史
- 历史列表按时间排序
- 搜索历史
- 删除单条历史
- 撤销删除
- 点击历史重新导航

**当前证据**

- `Tests/Unit/HistoryViewModelTests.swift`
- `UITests/OWLHistoryUITests.swift`

**结论**

这是当前覆盖最完整的模块之一，已经具备真实价值。

**仍缺的 case**

- app 重启后历史是否仍然存在
- 历史数据库损坏时的恢复路径
- 多 profile / 隔离数据场景

**建议补法**

- 增加 1 个本地 profile 持久化 E2E
- 增加 1 个 corrupt data 恢复测试

---

### 2. Downloads

**当前用户用例**

- 点击下载链接触发下载
- 列表出现下载项
- 进度更新
- 暂停 / 恢复 / 取消
- 错误显示

**当前证据**

- `Tests/Unit/DownloadViewModelTests.swift`
- `UITests/OWLDownloadUITests.swift`

**结论**

主流程已经被覆盖到，是真正有价值的一块。

**仍缺的 case**

- 下载完成后文件是否真实落盘
- 重启后下载记录是否保留
- 文件名冲突、路径不可写、权限不足

**建议补法**

- 使用本地 HTTP server + 临时目录校验文件落盘
- 增加 restart-resume / completed history 保留测试

---

### 3. Console

**当前用户用例**

- 页面输出 console message
- 控制台面板展示
- 过滤错误等级
- 搜索 / 清空

**当前证据**

- `Tests/Unit/ConsoleViewModelTests.swift`
- `UITests/OWLConsoleUITests.swift`

**结论**

覆盖不错，但更偏单 tab、单页面。

**仍缺的 case**

- 多标签页 console 是否隔离
- 页面重载后旧消息保留策略
- 超长日志 / 高频日志 ring buffer 行为在真实 UI 中是否正确

**建议补法**

- 增加多 tab + reload E2E
- 增加 stress / truncation integration case

---

### 4. Bookmarks

**当前用户用例**

- 对当前页面加星标
- 删除书签
- 列出书签
- 点击书签重新导航

**当前证据**

- `Tests/Unit/BookmarkViewModelTests.swift`
- `Tests/OWLBrowserTests.swift` 中存在 bookmark 相关 pipeline case

**结论**

不是没测，但还没有形成“用户入口到持久化”的完整闭环。

**仍缺的 case**

- 地址栏星标按钮真实 UI 交互
- app 重启后书签是否保留
- CLI bookmark 命令的语义正确性

**建议补法**

- 增加 AddressBar 星标 E2E
- 增加书签持久化测试
- 为 CLI 增加 golden JSON 检查

---

### 5. Tabs / Session Restore

**当前用户用例**

- 新建 tab
- 切换 tab
- 关闭 tab
- Undo close
- Pin tab
- 重启后恢复会话

**当前证据**

- `Tests/Unit/TabViewModelTests.swift`
- `Tests/Unit/Phase4PinUndoCloseTests.swift`
- `Tests/Unit/SessionRestoreTests.swift`
- `UITests/OWLTabManagementUITests.swift`

**结论**

功能面上测试很多，但这里是“测试数量多，不代表信心高”的典型模块。

**已观察到的问题**

- unit test 文件里明确写了要避免进入真实 `navigate()` 路径
- 但真实 URL 场景仍可能误入 `OWLBridge_Navigate`
- 实跑时确实发生 crash

**仍缺的 case**

- 关闭最后一个 tab 后的 auto-blank 逻辑与 undo 组合
- 多 tab + restore + pin 混合场景
- Host 存在时与 mock 模式之间的一致性

**建议补法**

- 先修复 unit hermeticity：将导航依赖注入/隔离
- 再补一个真实 restart restore E2E
- 增加 tab state matrix 测试

---

### 6. Permissions

**当前用户用例**

- 页面请求权限时弹窗
- 用户允许 / 拒绝
- 超时自动拒绝
- 设置页查看与修改站点权限

**当前证据**

- `Tests/Unit/PermissionViewModelTests.swift`
- `Tests/Unit/SettingsPermissionsViewModelTests.swift`

**结论**

逻辑层有一定覆盖，但主流程还不算“真能托底”。

**已观察到的问题**

- `testTimeout_toastMessage` 实跑失败

**仍缺的 case**

- 真实 UI 弹窗与 Settings 面板联动
- 系统权限被禁用时的用户路径
- 权限持久化后的重启行为

**建议补法**

- 先修复当前失败单测
- 增加 PermissionsPanel UI 测试
- 增加真实 Host mock permission request integration test

---

### 7. Navigation / Browser Flow

**当前用户用例**

- 地址栏输入 URL / 搜索词
- 回车导航
- 停止加载
- 前进后退
- 导航失败展示错误页
- 身份认证弹窗

**当前证据**

- `Tests/OWLBrowserTests.swift`
- `UITests/OWLNavigationUITests.swift`
- `UITests/OWLBrowserUITests.swift`

**结论**

这层是用户最关键的旅程，但当前证据不够硬。

**已观察到的问题**

- `swift test --filter OWLBrowserTests` build 后长时间无输出，最终超时
- 文档也明确记录了挂起问题

**仍缺的 case**

- 地址栏真实壳层的 focus / blur / enter / displayURL 变化
- 本地确定性页面上的导航成功 / 失败 / 重定向
- 与外网无关的搜索行为验证

**建议补法**

- 先解决 pipeline 生命周期与收尾问题
- 把依赖外网页面的用例迁到本地 HTTP server
- 单独建立 AddressBar E2E 套件

---

### 8. Context Menu

**当前用户用例**

- 对链接、图片、文本、页面、可编辑区域右键
- 执行 copy/open/save 等操作

**当前证据**

- C++ GTest
- `UITests/ContextMenuUITests.swift`

**结论**

已经有价值，但 Host 侧结构性限制尚未完全消除。

**仍缺的 case**

- `HandleContextMenu -> Observer -> Bridge -> ExecuteAction` 完整真实链路
- 不依赖 mirror helper 的更多断言

**建议补法**

- 增加轻量级 Mojo / TestWebContents integration test
- 将剩余 mirror 辅助继续向真实函数收敛

---

### 9. Storage / Cookies

**当前用户用例**

- 查看 cookie domain 列表
- 删除某个站点 cookie
- 查看 storage usage
- 清除 browsing data

**当前证据**

- 代码入口已存在：`StorageViewModel` / `StoragePanel` / CLI storage commands

**结论**

这是当前最典型的“功能已经在产品里，但测试证据明显不足”的模块。

**仍缺的 case**

- `loadDomains / loadUsage` 的状态机测试
- 删除 cookie 与 clear-data 的错误路径
- Settings 页面中的交互与确认框
- CLI 返回 JSON 的语义和过滤行为

**建议补法**

- 增加 `StorageViewModelTests.swift`
- 增加 `StoragePanelUITests.swift`
- 增加 CLI storage golden tests

---

### 10. Settings UI

**当前用户用例**

- 打开设置
- 切换 settings 分组
- 在 Storage / Permissions 面板中完成核心操作

**当前证据**

- `Views/Settings/*.swift` 已实现

**结论**

用户入口真实存在，但没有形成可信测试面。

**仍缺的 case**

- Settings 各 tab 是否可达
- 面板初始加载状态
- 确认弹窗与 destructive action

**建议补法**

- 增加 Settings smoke 套件
- 至少覆盖 StoragePanel 与 PermissionsPanel 两个高风险面板

---

### 11. Address Bar 壳层

**当前用户用例**

- 点击地址栏聚焦
- 聚焦时显示完整 URL，失焦时显示 domain
- 输入后回车导航
- XCUITest / CGEvent / AppKit 真正共用同一路径

**当前证据**

- `Views/TopBar/AddressBarView.swift`

**结论**

这是当前最关键、但最欠缺稳定专测的用户入口之一。

地址栏实现本身已经说明它要同时兼容：

- 真实键盘输入
- `typeText("...\n")`
- `typeKey(.return)`
- AppKit delegate 命令路径

这意味着它特别需要 dedicated tests，而不适合只靠旁路浏览器流程间接覆盖。

**仍缺的 case**

- 聚焦/失焦显示切换
- 回车导航
- command+a 替换输入
- 第二个 tab 中地址栏输入路由

**建议补法**

- 增加 AddressBar 专门 UI 套件
- 用本地页面代替外网验证 URL/state 变化

---

### 12. CLI

**当前用户用例**

- `owl page info`
- `owl cookie list/delete`
- `owl clear-data`
- `owl storage usage`
- 后续 bookmark/history/navigation 命令

**当前证据**

- `scripts/test_cli.sh`
- `Services/CLICommandRouter.swift`

**结论**

目前只能算 smoke test，不足以证明 CLI 对用户可用。

**仍缺的 case**

- JSON 结构断言
- 参数过滤行为
- 错误参数与错误码
- 调用后的状态副作用
- 与真实浏览器状态的一致性

**建议补法**

- 增加 CLI golden tests
- 将“退出码检查”升级为“输出 + 状态变化”检查

---

### 13. AI / Socket

**当前用户用例**

- AI 面板状态管理
- socket / IPC 协议稳定性

**当前证据**

- 代码存在，但当前主测试面几乎没有成体系案例

**结论**

当前基本未覆盖。

**建议补法**

- 先从 service / protocol contract tests 开始
- 再考虑接入端到端测试

---

### 14. Cross-layer Integration Harness

**当前目标**

- 稳定提供 `AppHost + UIDriver + WebDriver + WaitHelper + ProcessGuard`
- 让测试既不是过度 mock，也不是只能上脆弱 GUI

**当前证据**

- `TestKit/AppHost.swift`：Host 生命周期、Context/WebView 创建、导航、JS 执行、输入注入
- `TestKit/WaitHelper.swift`：可复用等待器
- `TestKit/ProcessGuard.swift`：Host 进程回收守卫
- `Tests/Integration/OWLIntegrationTests.swift`：真实跨层用例（data URL 导航 + DOM 断言 + 键盘输入）
- `run_tests.sh integration`：已加入脚本入口，且默认 `e2e` 会执行

**结论**

这层已经从“未建立”进入“可用但薄覆盖”状态，结构性缺口被打开了突破口。

**建议补法**

- 将 integration case 扩展到至少 5 条高价值链路（Address Bar、Storage、Bookmarks、History、Context Menu）
- 每条 case 都保持本地 deterministic（data URL / 本地 server）
- 将 integration 层纳入发布前必跑门禁（当前已纳入默认 e2e，可继续补 fail-path）

---

## 已观察到的关键问题

### A. 默认门禁无法代表“真实用户没问题”

默认 `e2e` 不包含 CLI、XCUITest、system、dual-e2e，因此默认全绿只能说明：

- 底层逻辑大致没坏
- 某些 pipeline 路径没立刻炸

但不能说明：

- 设置页没坏
- 地址栏壳层没坏
- CLI 没坏
- 权限与存储这类真实用户入口没坏

### B. pipeline 可执行性已收敛，但仍需持续观察

pipeline 目前已能稳定 33/33 通过并退出，可靠性明显提升。现阶段主要风险从“跑不完”转为“是否覆盖足够多真实路径”。

### C. unit hermeticity 不足

`Phase4PinUndoCloseTests` 中已有注释说明某些场景必须避开 `navigate()` 才能在 unit 环境运行；而真实 URL case 仍可能进入 bridge 路径并 crash。

这说明当前 unit harness 的隔离边界还不够稳。

### D. CLI 覆盖浅

`test_cli.sh` 目前几乎只检查 exit code，不检查语义正确性。

### E. 顶层 UI 仍偏脆弱

- 依赖签名
- 依赖 GUI 前台
- 存在已知失败
- 部分用例依赖外网或不稳定条件

---

## P0 / P1 / P2 补强优先级

### P0：必须优先补

1. **扩展 Cross-layer Integration Harness 用例宽度（从 1 条提升到多模块）**
2. **修复 Tabs unit hermeticity**
3. **补 Storage 测试体系**
4. **补 Address Bar 专项测试**
5. **补 CLI 语义测试**
6. **补 Settings UI 最小 smoke + 两个高风险面板**

### P1：增强发布信心

1. Bookmarks 持久化 + UI 星标链路
2. Downloads 文件落盘与重启场景
3. Console 多 tab / reload 场景
4. History 重启后持久化
5. Context Menu 的完整 Host->Bridge integration

### P2：后续完善

1. AI / Socket contract tests
2. 更细的压力测试与长时间运行测试
3. 多 profile / 数据损坏恢复测试

---

## 推荐落地顺序

### 第一阶段：把门禁变得可信

- 修 unit hermeticity
- 修当前失败 case
- 让默认门禁至少覆盖一个关键真实用户旅程

### 第二阶段：补高频用户入口

- Address Bar
- Storage / Cookies
- Settings UI
- CLI

### 第三阶段：补持久化与重启场景

- Bookmarks
- History
- Downloads
- Session Restore

### 第四阶段：补中间层 integration 套件

- 把当前高频功能逐步从“只能靠 GUI”迁移到“中间层可稳定验证”

---

## 最终验收标准

当下面条件都满足时，才能说当前 harness 真正“有用且可靠”：

1. 默认门禁覆盖关键用户旅程，而不是只覆盖无 GUI 子集
2. 每个用户可见功能至少有 1 个稳定、本地、确定性的真 E2E
3. 每个核心状态机至少有 unit 或 integration 覆盖失败路径
4. pipeline / unit / CLI 测试本身稳定可执行，不依赖超时硬杀
5. Storage / Settings / AddressBar / CLI 不再是覆盖盲区

---

## 参考文件

- `docs/TESTING.md`
- `docs/TESTING-ROADMAP.md`
- `docs/design/agent-testing-infrastructure.md`
- `owl-client-app/scripts/run_tests.sh`
- `owl-client-app/scripts/test_cli.sh`
- `owl-client-app/TestKit/OWLTestKit.swift`
- `owl-client-app/Tests/Integration/OWLIntegrationTests.swift`
