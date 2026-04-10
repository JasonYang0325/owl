# 双驱动 E2E 测试

XCUITest（原生 UI）+ Playwright CDP（Web 内容）双驱动 E2E 测试架构。

## Phases

| Phase | 内容 | 状态 |
|-------|------|------|
| Phase 1 | 双驱动架构：CDPHelper + Playwright + 跨层测试 | 技术方案评审 ✓ |

## 接口契约

- CDP 端口：`OWL_CDP_PORT` 环境变量（默认 9222）
- Playwright 连接：`chromium.connectOverCDP()`（不是 `launch()`）
- 不调用 `browser.newContext()`（content layer 限制）
