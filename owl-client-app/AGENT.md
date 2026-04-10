# AGENT — OWL Swift 应用

## 职责

SwiftUI 应用主入口、业务状态机、服务层、UI 测试和 CLI。

## 代码入口

- 应用入口：`owl-client-app/OWLBrowserApp.swift`
- 业务状态：`owl-client-app/ViewModels/`
- 服务层：`owl-client-app/Services/`
- UI：`owl-client-app/Views/`
- 测试：`owl-client-app/Tests/`、`owl-client-app/UITests/`

## 测试与质量

- 单测：`owl-client-app/scripts/run_tests.sh unit`
- 集成：`owl-client-app/scripts/run_tests.sh integration`
- Pipeline：`owl-client-app/scripts/run_tests.sh pipeline`
- UI：`owl-client-app/scripts/run_tests.sh xcuitest`

## 迭代规则

- 新特性优先在 ViewModel/Service 中形成可测状态变化，再映射到 UI。
- UI 自动化尽量走“高价值冒烟 + 本地资源”策略。
- 与 CLI 变更保持同步：脚本与文档同时更新。
