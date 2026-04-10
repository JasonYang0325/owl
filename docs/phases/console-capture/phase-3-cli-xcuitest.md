# Phase 3: CLI + XCUITest

## 目标
- `owl console` CLI 命令
- XCUITest E2E 覆盖

## 范围
| 文件 | 变更 |
|------|------|
| `owl-client-app/CLI/Commands/ConsoleCommand.swift` | 🆕 |
| `owl-client-app/CLI/CLIMain.swift` | 注册 ConsoleCommand |
| `owl-client-app/Services/CLICommandRouter.swift` | console 路由 |
| `owl-client-app/UITests/OWLConsoleUITests.swift` | 🆕 |

## 验收标准
- [ ] `owl console --level error --limit 10` 返回 JSON
- [ ] timestamp 为 ISO 8601 格式
- [ ] XCUITest: Console 面板可打开 + error 消息可见 + 过滤功能
- [ ] build_all.sh 通过
