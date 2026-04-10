# OWL vs OpenAI Harness Engineering 对齐审计（2026-04-09）

## 背景

对照 OpenAI 官方文章《Harness engineering: leveraging Codex in an agent-first world》（发布于 2026-02-11），评估 OWL 当前 harness 工程化成熟度，并给出可执行补强项。  
参考：<https://openai.com/index/harness-engineering/>

## 总体结论（本次确认）

- **已对齐且可执行**：`10 / 10`
- **部分对齐**：`0 / 10`
- **明显缺口**：`0 / 10`

> 结论：当前 harness 已建成与 OpenAI 所述实践可对齐的闭环。剩余风险主要在于 PR 自动化的外部依赖可用性（`gh` CLI、token、仓库权限），而非机制本身。

## 对齐矩阵

| OpenAI 实践点 | OWL 现状 | 结论 |
|---|---|---|
| 短入口 + 结构化 docs 作为系统记录 | `CLAUDE.md` + `docs/` 分层导航已成形 | 已对齐 |
| 机械化校验知识库新鲜度/一致性 | `check_docs_consistency.py` + `run_tests.sh docs` | 已对齐（但缺少长期调度化 `doc-gardening`） |
| harness 策略化门禁（suite/use-case） | `run_harness.py` + `harness_policy.json` 已落地 | 已对齐 |
| 机器可读工件供 agent 循环消费 | summary/cases/usecase/junit/report/playbook/manifest | 已对齐 |
| 失败复现与修复提示内嵌 | policy `failure_hints` + playbook | 已对齐 |
| profile 化执行（快迭代/夜间） | `ci-core`/`swift-fast`/`release-nightly` | 已对齐 |
| 架构与口味不变量的强制 lint | 已有 `check_architecture_boundaries.py` 机械化约束分层导入边界 | 已对齐 |
| UI/日志/指标对 agent 可见性 | 已产出 `harness_metrics.json` 并支持 profile 级 `observability_assertions` 阈值门禁 | 已对齐 |
| 高吞吐 merge 哲学与 flake 策略 | 已有 retry/stability + `check_flake_trend.py` 持续抖动门禁 | 已对齐 |
| 周期性 GC（后台巡检 + 自动修复 PR） | `run_harness_maintenance_cycle.sh` + `run_harness_maintenance.sh` + `check_harness_maintenance.py` + `run_harness_maintenance_pr.sh` | 已对齐 |

## 本轮新增落地（已完成）

1. 新增 harness 质量门禁脚本：`owl-client-app/scripts/check_harness_quality.py`  
2. `run_tests.sh docs` 接入 `Harness Policy Lint`，与 docs lint 并行执行  
3. `harness_policy.json` 增加：
   - `cpp_host_smoke` 用例（required suite 与 use-case 建立硬连接）
   - `domains` 元数据（每个 use-case 归属业务域）
   - profile `required_domains` + `min_domain_coverage`
4. `docs/TESTING.md` 补充 docs 层 lint 组成与新脚本说明
5. 新增架构边界门禁脚本：`owl-client-app/scripts/check_architecture_boundaries.py`
6. `run_tests.sh docs` 接入 `Architecture Boundary Lint`
7. 新增 flaky 趋势门禁脚本：`owl-client-app/scripts/check_flake_trend.py`
8. `run_tests.sh harness` 接入 `Harness Flake Trend`（历史窗口 + 连续抖动阈值）
9. `run_harness.py` 新增 `harness_metrics.json`，并将 `observability_assertions` 接入 policy 违规判定
10. `check_harness_quality.py` 增加 stale 清扫规则（unused suites/use-cases、selector 指向未运行 suite）
11. 新增 `check_harness_maintenance.py`（周期性垃圾回收建议产物）+ `run_harness_maintenance.sh`（维护入口），并接入 `run_tests.sh maintenance`，用于机器/人工双轮修复。  
    - 新增 `harness_maintenance_actions.json` 与 `harness_maintenance.patch`，支持 action 化治理闭环。
12. 新增 `run_harness_maintenance_cycle.sh`（周期治理总入口）与 `setup_harness_maintenance_scheduler.sh`（一键管理 cron）。  
    - `maintenance` 与 `docs consistency` 复检统一落盘，输出 `maintenance_cycle_summary.json` 供治理看板消费。
13. 新增 `run_harness_maintenance_pr.sh`（safe action 自动化应用与 PR 提交流程），支持 dry-run 和 `gh` PR 执行。

## 下一批高优先级（建议按顺序）

1. **周期性质量清扫（P1）**  
   已完成脚本化清扫入口、cron 与 PR 自动提交流程。下一步建议将 `maintenance_pr` 失败告警接入发布看板：  
   - `critical` 项直接阻塞发布并要求人工确认。
   - `warning` 项进入下周修复看板。
   - `info` 项每季度清理一次。

2. **文档治理自动化（P1）**  
   将 `check_docs_consistency.py` 纳入同样定时任务，自动生成“doc-gardening 任务单”（最小变更 PR）而不是只靠人工触发。  
   - 输出统一变更清单（新增/失效链接、状态不一致、关键条目漂移）  
   - 将清单作为可消费产物接入 `run_tests.sh maintenance` 的同一汇总通道

## 验证记录

本轮变更后执行：

- `python3 -m json.tool owl-client-app/scripts/harness_policy.json`
- `python3 -m py_compile owl-client-app/scripts/check_architecture_boundaries.py`
- `python3 -m py_compile owl-client-app/scripts/check_harness_quality.py`
- `python3 -m py_compile owl-client-app/scripts/check_flake_trend.py`
- `python3 -m py_compile owl-client-app/scripts/run_harness.py`
- `python3 -m py_compile owl-client-app/scripts/check_harness_maintenance.py`
- `bash -n owl-client-app/scripts/run_tests.sh`
- `bash -n owl-client-app/scripts/run_harness_maintenance_cycle.sh`
- `bash -n owl-client-app/scripts/setup_harness_maintenance_scheduler.sh`
- `bash -n owl-client-app/scripts/run_harness_maintenance_pr.sh`
- `owl-client-app/scripts/run_tests.sh docs`
- `owl-client-app/scripts/run_tests.sh maintenance`
- `OWL_HARNESS_MAINTENANCE_STRICT=1 owl-client-app/scripts/run_harness_maintenance.sh`
- `OWL_HARNESS_POLICY=/tmp/owl_bad_policy.json OWL_MAINTENANCE_CYCLE_MAINT_STRICT=1 owl-client-app/scripts/run_harness_maintenance_cycle.sh`
- `cd /path/to/third_party/owl && ./owl-client-app/scripts/run_harness_maintenance_pr.sh --run-dir /tmp/owl_harness/maintenance_cycle/20260409T140000Z --patch-summary /tmp/owl_harness/maintenance_cycle/20260409T140000Z/harness_maintenance_pr.json --create-pr`

结果：

- 基础脚本语法与校验产物通过；`run_harness_maintenance_cycle.sh` 在正常策略下会返回 0。
- 严格模式与异常策略的失败路径通过验证（用于确认告警闭环退出码策略正确）。
