# AGENT — Host 目录

## 职责

Chromium Host 子系统：`host/` 下的浏览器运行时、服务实现、持久化、下载/权限/存储等核心能力。

## 常用入口

- Host 服务实现：`host/owl_*.cc/.h`
- 会话与上下文：`host/owl_browser_context.*`
- 浏览内容观察：`host/owl_real_web_contents.*`

## 测试与质量

- 优先级：C++ 单测（C++ GTest）+ integration 关键通路。
- 变更后建议执行：`owl-client-app/scripts/run_tests.sh cpp`。
- 新增/改动测试行为需同步到该能力对应 `docs/modules/module-*.md`。

## 风险约束

- 不改变 IPC 合同前先确认 `mojom/` 与 `client/`/`bridge/` 协议兼容。
- Host 崩溃路径与生命周期代码必须尽量保持可预测（日志先于回退）。
