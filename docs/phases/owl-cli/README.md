# OWL CLI + Cookie 存储管理 — Phase 总览

## 概述

- PRD: [docs/prd/owl-cli.md](../../prd/owl-cli.md)
- 架构: [docs/design/agent-api-layer.md](../../design/agent-api-layer.md)

## Phase 列表

| Phase | 名称 | 状态 | 依赖 | 预估 | AC 覆盖 |
|-------|------|------|------|------|---------|
| 1 | CLI 骨架 + 导航命令 | pending | 无 | ~300 行 | AC-001, AC-002, AC-009 |
| 2 | Host StorageService | pending | 无 | ~400 行 | AC-003~006 后端 |
| 3 | Storage CLI + UI + Tests | pending | Phase 1+2 | ~300 行 | AC-003~008 |

## 依赖图

```
Phase 1 (CLI 骨架)     Phase 2 (StorageService C++)
      ↓                       ↓
      └───── Phase 3 (Storage CLI + UI + Tests) ─────┘
```

Phase 1 和 Phase 2 可并行。Phase 3 依赖两者。
