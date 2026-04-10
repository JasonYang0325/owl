# OWL Browser Testing

## 统一入口

```bash
owl-client-app/scripts/run_tests.sh [层级]
```

默认推荐使用代码驱动 harness：

```bash
owl-client-app/scripts/run_tests.sh harness
# 或直接默认入口（e2e 已切换为 harness）
owl-client-app/scripts/run_tests.sh
```

## 测试层次

| 层级 | 脚本参数 | 需要 Host | 需要 GUI | 测试数 |
|------|---------|---------|---------|--------|
| C++ GTest | `cpp` | 否 | 否 | 600+ |
| OWLViewModelTests | `unit` | 否 | 否 | 467+ |
| Code-driven Harness | `harness` | 部分 | 否 | 策略驱动 |
| OWLIntegrationTests | `integration` | 是 | 否 | 8 |
| OWLBrowserTests | `pipeline` | 是 | 否 | 33 |
| OWLBrowserUITests | `xcuitest` | 是 | 是 | ~19 |
| OWLUITest (CGEvent) | `system` | 是 | 是 | ~5 |
| Static Lints (Architecture/Policy/Docs) | `docs` | 否 | 否 | 规则驱动 |
| Harness Maintenance | `maintenance` | 否 | 否 | 周期性 |

默认（无参数）运行 `e2e`，当前等价于 `harness`（策略文件见 `owl-client-app/scripts/harness_policy.json`）。

`docs` 层会执行三类静态校验：`Architecture Boundary Lint`（分层依赖约束）+ `Harness Policy Lint`（策略质量与覆盖约束）+ `Docs Consistency Lint`（文档一致性）。

## Harness 产物

`harness` 会生成完整机器可读产物（用于 agent 自循环）：

- `harness_summary.json`: 套件状态、重试、flake、策略违规
- `harness_metrics.json`: 运行可观测指标（suite 耗时、总耗时、阈值断言结果）
- `harness_cases.jsonl`: case 级结果（包含 not_run）
- `harness_case_inventory.json`: 每个 suite 的发现用例清单（用于覆盖审计）
- `harness_usecase_coverage.json`: 用户用例覆盖矩阵（use-case -> case selector）
- `harness_junit.xml`: 聚合 JUnit
- `harness_report.md`: 人类可读汇总 + 失败提示
- `harness_playbook.md`: 自动生成的失败复现与排障指令
- `harness_manifest.json`: 所有产物的路径、大小、SHA256（便于 agent 确定性消费）

策略文件 `owl-client-app/scripts/harness_policy.json` 现在同时约束：

- suite 级门禁（required / timeout / retries / stability_runs）
- case 发现完整性（`min_discovered_cases`、`max_not_run_cases`）
- use-case 覆盖门禁（`use_cases` + profile `required_use_cases`）
- 可观测性阈值断言（profile `observability_assertions`）

`harness` 运行后会执行 flake 趋势门禁（默认开启），基于历史窗口检查 required suite 的持续抖动：

- `OWL_HARNESS_FLAKE_TREND=0` 可临时关闭趋势门禁
- `OWL_HARNESS_TREND_HISTORY` 指定历史文件（默认 `/tmp/owl_harness_history/history.jsonl`）
- `OWL_HARNESS_TREND_WINDOW` / `OWL_HARNESS_TREND_MIN_RUNS` / `OWL_HARNESS_TREND_MAX_RATE` / `OWL_HARNESS_TREND_MAX_CONSECUTIVE` 调整阈值

可选 profile：
- `ci-core`（默认）
- `swift-fast`（Swift 快速迭代）
- `release-gate`（发布门禁：在 deterministic core 基础上要求 `cli/xcuitest`）
- `release-nightly`（夜间门禁：在 deterministic 套件基础上扩展 `cli/xcuitest/dual-e2e` script suites）

使用方式：

```bash
OWL_HARNESS_PROFILE=release-nightly owl-client-app/scripts/run_tests.sh harness
```

`maintenance` 可独立跑一次周期清扫：

```bash
owl-client-app/scripts/run_tests.sh maintenance
```

## 辅助脚本

| 脚本 | 用途 |
|------|------|
| `owl-client-app/scripts/resign_for_testing.sh` | XCUITest 签名 |
| `owl-client-app/scripts/check_xcuitest.py` | XCUITest 合规检查 |
| `owl-client-app/scripts/check_architecture_boundaries.py` | 架构依赖边界校验（层级导入规则） |
| `owl-client-app/scripts/check_harness_quality.py` | harness policy 质量门禁（profile/use-case/domain 覆盖校验） |
| `owl-client-app/scripts/check_harness_maintenance.py` | 周期性清扫建议（未引用 suite/use-case、观测建议、冗余配置） |
| `owl-client-app/scripts/check_flake_trend.py` | harness flaky 趋势门禁（历史窗口/连续抖动） |
| `owl-client-app/scripts/check_docs_consistency.py` | 文档与脚本/Backlog 一致性检查 |
| `owl-client-app/scripts/run_harness_maintenance.sh` | 周期性垃圾回收报表入口（JSON + Markdown + Actions + Patch + History） |
| `owl-client-app/scripts/run_harness_maintenance_cycle.sh` | 周期治理总入口（maintenance + docs consistency 聚合，带时间戳目录和 JSON 汇总） |
| `owl-client-app/scripts/run_harness_maintenance_pr.sh` | 周期性 maintenance 自动修复 PR（safe actions，支持 dry-run） |
| `owl-client-app/scripts/setup_harness_maintenance_scheduler.sh` | 生成/安装/移除 Cron 调度（含周期开关与日志路径） |

## 周期清扫（建议按周执行）

可执行：

```bash
OWL_HARNESS_MAINTENANCE_DIR=/tmp/owl_harness/maintenance \
  OWL_HARNESS_MAINTENANCE_HISTORY_WINDOW=20 \
  owl-client-app/scripts/run_harness_maintenance.sh
```

建议在维护工位跑：每周一 10:00 输出 `harness_maintenance_report.md/json`，把 `critical` 与 `warning` 项提交进治理工单；`info` 项可累计压测修复。
可按需设置历史窗口/留存：

```bash
OWL_HARNESS_MAINTENANCE_HISTORY=/tmp/owl_harness/maintenance/harness_maintenance_history.jsonl \
OWL_HARNESS_MAINTENANCE_HISTORY_WINDOW=20 \
OWL_HARNESS_MAINTENANCE_MAX_ROWS=200 \
OWL_HARNESS_MAINTENANCE_STRICT=1 \
owl-client-app/scripts/run_tests.sh maintenance
```

`OWL_HARNESS_MAINTENANCE_STRICT=1` 表示启用阻塞模式（`critical`/`warning` 会让维护入口返回非零）；未设置时保持非阻塞，仅持续记录历史和动作。

`run_tests.sh maintenance` 路径还会附加执行：

```bash
owl-client-app/scripts/test_harness_maintenance_pr.sh
```

用于回归 `run_harness_maintenance_pr.sh` 的关键路径：dry-run 无动作、no-dry-run 提交、缺失 `gh` 的失败分支。

`run_harness_maintenance_pr.sh` 支持把 safe 操作封装为可提交 PR（可选）：

```bash
./owl-client-app/scripts/run_harness_maintenance_pr.sh \
  --run-dir /tmp/owl_harness/maintenance_cycle/20260409T140000Z \
  --no-dry-run --create-pr
```

### 自动调度（推荐）

周期化治理建议统一用 `run_harness_maintenance_cycle.sh` 执行。

```bash
cd /path/to/third_party/owl
OWL_MAINTENANCE_CYCLE_STRICT=1 \
OWL_MAINTENANCE_CYCLE_DIR=/tmp/owl_harness/maintenance_cycle \
OWL_MAINTENANCE_CYCLE_AUTO_PR=1 \
OWL_MAINTENANCE_CYCLE_PR_DRY_RUN=1 \
OWL_MAINTENANCE_CYCLE_PR_CREATE=0 \
./owl-client-app/scripts/run_harness_maintenance_cycle.sh
```

生成后可用 `setup_harness_maintenance_scheduler.sh` 管理 crontab：

```bash
./owl-client-app/scripts/setup_harness_maintenance_scheduler.sh show
./owl-client-app/scripts/setup_harness_maintenance_scheduler.sh install
./owl-client-app/scripts/setup_harness_maintenance_scheduler.sh remove
```

### 本地自检脚本

维护 PR 脚本的关键执行路径新增了冒烟验证，可直接运行：

```bash
./owl-client-app/scripts/test_harness_maintenance_pr.sh
```

它会覆盖：

1. dry-run 无动作路径（`no_action`）
2. no-dry-run 提交路径（`committed`）
3. `--create-pr` 在 `gh` 缺失时的失败路径（`create_pr_tool_missing`）

## 已知问题

- CGEvent 测试需要前台窗口 + 无人操作，运行时别动鼠标键盘
- NSEvent 进程内注入在 XCTest 中不可行（窗口无法成为 key window）
- XCUITest 需要 Apple 开发者账号签名所有组件
- AddressBar 焦点后显示 full URL 仍是已知缺陷（XCUITest 以 `XCTExpectFailure` 跟踪）
- 当前环境 `cpp` 层的 `owl_client_unittests` 可能出现链接失败并被脚本标记为跳过（`owl_host_unittests` 正常）
