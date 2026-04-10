# AGENT — OWL Browser 项目总入口

## 目标

本仓库是 Chromium-based 的 macOS 浏览器能力工程。每次会话目标是持续交付，不做临时修补。

## 你在本仓库默认要做的事

1. 先读本文件，再读 `docs/ARCHITECTURE.md` 与 `CLAUDE.md`。
2. 任务按 `docs/BACKLOG.md` 的 `P0/`P1/`P2` 入口选取。
3. 文档与脚本同步更新：任何可维护决策必须落在 `docs/` 或 `owl-client-app/scripts/`。

## 关键操作路径

- 统一测试入口：`owl-client-app/scripts/run_tests.sh`
- 常用默认：`owl-client-app/scripts/run_tests.sh`（默认走 harness）
- 文档一致性：`owl-client-app/scripts/run_tests.sh docs`
- 代码/文档 lint：`python3 owl-client-app/scripts/check_architecture_boundaries.py`、`python3 owl-client-app/scripts/check_harness_quality.py`

## 变更规则

- 先在脚本里实现可重复操作，再改命令。
- 测试修复要和测试资产一起补：新增/修改用例时同步更新 `docs/TESTING.md` 的验证闭环描述。
- 新增/重命名目录时，给目录补 `AGENT.md` 作为下一次会话接入点。
- 所有重要决策（门禁、风险等级、失败归因）写回 `docs/TESTING-ROADMAP.md`。

## 会话交接清单（每次结束前）

- 更新 `docs/BACKLOG.md` 的对应条目状态。
- 若引入新脚本，补充到 `docs/GITHUB_UPLOAD_PLAN.md`。
- 运行 `owl-client-app/scripts/run_tests.sh docs`，确保一致性通过。
