# AGENT — 文档域

## 目标

保证项目文档可直接驱动新 session 自循环，不靠口头记忆。

## 文档治理规则

- `docs/ARCHITECTURE.md`：架构边界与测试能力说明（与实施保持一致）。
- `docs/TESTING.md`：测试入口与已知问题。
- `docs/TESTING-ROADMAP.md`：P0/P1/P2 按优先级可执行任务。
- `docs/BACKLOG.md`：唯一任务来源。
- `docs/modules/*.md`：每个功能模块的实现与验证闭环。

## 变更规则

- 新增模块能力时先更新 `docs/modules/`，再更新 `docs/BACKLOG.md` 与 `docs/TESTING-ROADMAP.md`。
- 文档中出现的测试套件和脚本命名必须与实际脚本一致。
- 运行前后至少做一次文档一致性检查（含链接校验）。

## 文档自检命令

- `owl-client-app/scripts/run_tests.sh docs`
- `python3 owl-client-app/scripts/check_docs_consistency.py docs/TESTING.md docs/ARCHITECTURE.md`
