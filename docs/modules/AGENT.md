# AGENT — 模块目录

## 模块职责

- `module-a-history.md`～`module-l-media.md` 记录 A-L 基础能力。
- `docs/modules/README.md` 是索引入口，必须与 `docs/BACKLOG.md` 状态一致。

## 模块维护规则

1. 每次改一个模块，先更新该模块文档对应文件。
2. 模块状态变更同时更新：
   - `docs/modules/README.md` 的状态列
   - `docs/BACKLOG.md` 的对应模块 ID 或聚合条目
3. 模块测试新增时同步更新 `docs/TESTING-ROADMAP.md` 与 `docs/TESTING.md`。

## 目录核查项

- `docs/modules/README.md` 必须包含 A-L 全量入口。
- 每个模块文档至少包含：目标、验收标准、文件清单、测试计划。
- `check_docs_consistency.py` 会校验模块索引与 Backlog 状态映射。
