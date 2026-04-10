# Agent-First 测试基础设施

**版本**: v2.1 — 2026-04-08（Round 2 修复）
**状态**: 评审通过 ✓

---

## 愿景

让 AI Agent 自主完成测试全生命周期：**编写 → 运行 → 读日志 → 诊断 → 修复 → 重跑**。测试系统是 agent 开发的核心基础设施。

## 核心原则

1. **日志即上下文** — Agent 理解系统行为的唯一方式是读日志。日志必须完整、可关联
2. **LLM 不需要 JSON** — LLM 从 `[OWL] Mojo pipe disconnected` 提取信息和从 JSON 一样好。只有入口摘要需要结构化
3. **Skill 描述方向，不规定命令** — 告诉 agent 找什么特征，不硬编码 grep 命令
4. **脚本即接口** — Agent 通过 `scripts/` 操作，脚本负责捕获所有输出
5. **越少文件越好** — Agent 读 1 个交织日志比在 5 个文件间跳转更高效

---

## 架构总览

```
┌─────────────────────────────────────────────────────────────────┐
│                    Agent 自闭环迭代                               │
│                                                                  │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐  │
│  │ /test-write│→ │ /owl-test │→  │ /test-debug│→ │  修复代码  │  │
│  │ 写测试     │   │ 跑 + 捕获 │   │ 读日志诊断 │   │  重新跑   │  │
│  └──────────┘   └─────┬─────┘   └─────┬─────┘   └──────────┘  │
│                       │               │                         │
│                       ▼               ▼                         │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │            /tmp/owl_test_logs/run-{timestamp}/           │   │
│  │                                                          │   │
│  │  summary.json   ← 结构化入口：pass/fail/耗时/时间范围     │   │
│  │  run.log         ← 全部 stdout+stderr 交织（Swift+Chrome）│   │
│  │  cdp-events.log  ← CDP 事件（仅 dual-e2e 时产生）        │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
├──────────────────────────────────────────────────────────────────┤
│  Layer 1: 全栈日志捕获（零代码变更：stderr/stdout 重定向）        │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  NSLog → stderr ──┐                                      │   │
│  │  LOG(INFO) → stderr┼→ tee run.log   单文件，时间交织     │   │
│  │  test output ─────┘                                      │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
│  Layer 2: 测试执行引擎                                           │
│  ┌──────────────┬──────────────┬──────────────┬────────────┐   │
│  │ GTest (L0)   │ Pipeline(L1) │ XCUITest(L3) │ Dual(L4)   │   │
│  │ run_tests.sh │ summary.json │ CDPHelper    │ Playwright  │   │
│  └──────────────┴──────────────┴──────────────┴────────────┘   │
│                                                                  │
│  Layer 3: Agent 指引系统                                         │
│  ┌──────────────┬──────────────┬──────────────┐                 │
│  │ Skills       │ Rules        │ CLAUDE.md    │                  │
│  │ /owl-test    │ testing.md   │ 测试章节     │                  │
│  │ /test-write  │              │              │                  │
│  │ /test-debug  │              │              │                  │
│  └──────────────┴──────────────┴──────────────┘                 │
└──────────────────────────────────────────────────────────────────┘
```

---

## Component 1: 全栈日志捕获

### 设计哲学：零代码变更

**Round 1 Gemini 关键洞察**：LLM 不需要结构化 JSON 日志。`[OWL] Bridge connected pid=12345` 对 LLM 来说和 `{"category":"bridge","message":"connected","pid":12345}` 一样可读。

因此：**不引入 OWLLogger，不迁移 NSLog，不改 Chromium logging 代码。** 完全依靠 run_tests.sh 的 stderr/stdout 重定向捕获所有日志。

### 1.1 日志捕获机制

```
OWL Browser 进程
├── Swift 层: NSLog("[OWL] ...") → stderr
├── Bridge 层: LOG(INFO) << "[OWL] ..." → stderr
└── Host 子进程: LOG(INFO) << "[OWL] ..." → stderr (继承父进程)

run_tests.sh
└── app 启动命令 2>&1 | tee $LOG_DIR/run.log
    → Swift + Chromium 日志自然交织，保留时序
```

**Host 子进程日志继承**：`base::LaunchProcess` 默认继承父进程的 stderr。Swift 通过 `swift run OWLBrowser` 启动时，Host 子进程的 LOG() 输出自然流入同一 stderr。`tee` 同时将输出保存到文件和终端。

**验证**：现有 `launch.sh` 已经使用 `2>&1 | tee /tmp/owl-launch.log` 捕获所有输出。只需将 tee 目标改为 `$LOG_DIR/run.log`。

### 1.2 统一日志目录

```
/tmp/owl_test_logs/
├── latest → run-20260408-143022/     # symlink（summary.json 写完后才更新）
└── run-20260408-143022/
    ├── summary.json                   # 结构化入口（Agent 必读）
    ├── run.log                        # 全部 stdout+stderr 交织
    └── cdp-events.log                 # CDP 事件（仅 dual-e2e）
```

**3 个文件，不是 6 个。**

### 1.3 summary.json 格式

```json
{
  "timestamp": "2026-04-08T14:30:22Z",
  "duration_seconds": 45.2,
  "level": "e2e",
  "total": 12,
  "passed": 10,
  "failed": 2,
  "skipped": 0,
  "log_dir": "/tmp/owl_test_logs/run-20260408-143022",
  "tests": [
    {
      "name": "testAddressBarNavigate",
      "suite": "OWLBrowserUITests",
      "status": "passed",
      "start_time": "2026-04-08T14:30:25Z",
      "end_time": "2026-04-08T14:30:28Z",
      "duration_ms": 3200
    },
    {
      "name": "testBookmarkNavigate",
      "suite": "OWLDualDriverTests",
      "status": "failed",
      "start_time": "2026-04-08T14:30:28Z",
      "end_time": "2026-04-08T14:30:43Z",
      "duration_ms": 15000,
      "error": "XCTAssertEqual failed: (\"Loading...\") is not equal to (\"Example Domain\")",
      "file": "OWLDualDriverTests.swift",
      "line": 87
    }
  ]
}
```

**Round 1 修复**：每个 test 增加 `start_time` / `end_time`（ISO8601），Agent 可精确定位日志时间窗口。

### 1.4 run_tests.sh 增强

```bash
# 日志目录初始化（所有测试级别共享）
setup_log_dir() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    LOG_DIR="/tmp/owl_test_logs/run-${timestamp}"
    mkdir -p "$LOG_DIR" || {
        echo "WARNING: Failed to create log dir, running without logging"
        LOG_DIR=""
        return
    }
    export OWL_LOG_DIR="$LOG_DIR"
}

# summary.json 原子写入
write_summary() {
    [ -z "$LOG_DIR" ] && return
    local level="$1" total="$2" passed="$3" skipped="$4" duration="$5"
    local failed=$((total - passed - skipped))
    local tmp="$LOG_DIR/.summary.tmp"

    # 构建 JSON（tests 数组由各 runner 追加到 .test_entries）
    cat > "$tmp" <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "duration_seconds": $duration,
  "level": "$level",
  "total": $total,
  "passed": $passed,
  "failed": $failed,
  "skipped": $skipped,
  "log_dir": "$LOG_DIR",
  "tests": [$(cat "$LOG_DIR/.test_entries" 2>/dev/null | paste -sd, -)]
}
EOF
    # 原子写入：先写 tmp，再 mv
    mv "$tmp" "$LOG_DIR/summary.json"

    # 最后才更新 latest symlink（确保 Agent 读到完整数据）
    ln -sfn "$LOG_DIR" /tmp/owl_test_logs/latest

    echo "📄 Summary: $LOG_DIR/summary.json"
    echo "📄 Full log: $LOG_DIR/run.log"
}

# 每个测试结果追加一条 entry（由各 runner 解析后调用）
append_test_entry() {
    [ -z "$LOG_DIR" ] && return
    local name="$1" suite="$2" status="$3" start="$4" end="$5" dur="$6"
    local error="${7:-}"
    local entry="{\"name\":\"$name\",\"suite\":\"$suite\",\"status\":\"$status\""
    entry="$entry,\"start_time\":\"$start\",\"end_time\":\"$end\",\"duration_ms\":$dur"
    if [ -n "$error" ]; then
        # 【Round 2 修复】完整 JSON 转义：换行→空格，反斜杠→\\，双引号→\"，制表符→空格
        local safe_error
        safe_error=$(printf '%s' "$error" | tr '\n\t' '  ' | sed 's/\\/\\\\/g; s/"/\\"/g')
        entry="$entry,\"error\":\"$safe_error\""
    fi
    entry="$entry}"
    echo "$entry" >> "$LOG_DIR/.test_entries"
}
```

**日志捕获（各测试级别）**：

```bash
# C++ GTest — 输出已有结构化格式 [N/TOTAL]
run_gtest() {
    "$GTEST_BIN" --gtest_color=no 2>&1 | tee -a "$LOG_DIR/run.log"
}

# Swift test — 捕获所有输出
run_swift_test() {
    swift test --filter "$FILTER" 2>&1 | tee -a "$LOG_DIR/run.log"
}

# XCUITest — xcodebuild 输出捕获
run_xcuitest() {
    local output
    output=$(xcodebuild test-without-building \
        -project "$XCODEPROJ" \
        -scheme OWLBrowserUITests \
        -destination 'platform=macOS' \
        2>&1) || true
    echo "$output" >> "$LOG_DIR/run.log"
    echo "$output" | parse_xcuitest_results
}
```

### 1.5 XCUITest 日志捕获

**xcodebuild 日志行为**：`xcodebuild test-without-building` 将被测 app 的 NSLog/LOG() 输出混入自身 stdout（带进程标识前缀）。`run_xcuitest()` 捕获 xcodebuild 全量输出到 `run.log`，app 日志自然包含在内。无需额外的文件写入机制，符合"零代码变更"原则。

**XCUITest setUp 中的环境变量**：

```swift
// UITests setUp — 仅注入功能性环境变量
override func setUp() async throws {
    let app = XCUIApplication()
    app.launchEnvironment["OWL_CLEAN_SESSION"] = "1"
    app.launchEnvironment["OWL_CDP_PORT"] = "9222"
    app.launch()
}
```

---

## Component 2: 测试执行引擎

### 2.1 现有层级

已有完整测试框架（466 个测试），详见 `docs/TESTING.md`。

### 2.2 双驱动 E2E（已设计）

详见 `docs/phases/dual-driver-e2e/phase-1-dual-driver.md`（v2.2，评审通过）。

CDPHelper 和 Playwright 在双驱动测试中将 CDP 事件（console + network）写入 `$OWL_LOG_DIR/cdp-events.log`（单文件，时间交织）。

### 2.3 Agent 视角的测试层级简化

在 Agent 指引中，将 5 个层级简化为 3 个概念：

| Agent 概念 | 对应层级 | 命令 |
|-----------|---------|------|
| **Unit** | L0 GTest + L1b Swift Unit | `run_tests.sh cpp` / `run_tests.sh unit` |
| **Integration** | L1 Pipeline | `run_tests.sh pipeline` |
| **E2E** | L3 XCUITest + L4 Dual | `run_tests.sh xcuitest` / `run_tests.sh dual-e2e` |

Agent 不需要理解 L0/L1/L1b/L3/L4 的细节，只需要知道"单元测试 vs 集成测试 vs 端到端测试"。

---

## Component 3: Agent 指引系统

### 3.1 Skills

#### /owl-test（增强现有）

在现有 `.claude/commands/owl-test.md` 基础上增加日志分析能力：

```markdown
# /owl-test [level] [filter]

运行 OWL 测试并分析结果。

## 参数
- level: cpp | unit | pipeline | xcuitest | dual-e2e | e2e | all（默认 e2e）
- filter: 可选的测试名过滤

## 执行步骤

### Step 1: 运行
```bash
owl-client-app/scripts/run_tests.sh {level} {filter}
```

### Step 2: 读取结果
读取 `/tmp/owl_test_logs/latest/summary.json`。
- 全部通过 → 报告成功
- 有失败 → 进入 Step 3

### Step 3: 诊断失败
对每个 status=="failed" 的测试：
1. 从 summary.json 获取 start_time 和 end_time
2. 读取 run.log 中该时间窗口的内容
3. 根据日志特征判断根因（见下方特征库）

### 日志特征库（找什么，不是怎么找）

**Swift 侧特征**：
- `[OWL] Mojo pipe disconnected` → Host 进程崩溃或断连
- `[OWL] callback is nil` → C-ABI 回调未注册
- `[OWL] Navigation error` → 页面加载失败
- `[OWL] timeout` → 异步操作超时

**Chromium 侧特征**：
- `RenderProcessTerminated` → 渲染进程崩溃（最常见的跨层问题）
- `net::ERR_` → 网络错误（DNS/连接/SSL）
- `DCHECK failed` → C++ 断言失败
- `GPU process exited` → GPU 进程异常

**跨层关联**：
- Swift 日志显示操作发起 → Chromium 日志显示崩溃 → 根因在 C++ 层
- Chromium 日志正常 → Swift 日志显示 callback nil → 根因在 Bridge 注册逻辑

### 输出格式
```
## 测试结果: N/M passed

### 失败: testXxx
- 错误: [assertion 内容]
- 日志线索: [从 run.log 中找到的关键行]
- 根因: [分析]
- 修复方向: [建议]
```
```

#### /test-write

```markdown
# /test-write <description>

为指定功能编写测试。

## 选择测试类型

问自己一个问题：**这个测试需要什么环境？**

- **不需要任何东西** → Unit 测试
  - 纯逻辑/算法 → C++ GTest (`*_unittest.cc`)
  - ViewModel 状态 → Swift Unit (`Tests/Unit/*Tests.swift`)

- **需要 Host 进程** → Integration 测试
  - C-ABI → Mojo 管线 → Swift Pipeline (`Tests/OWLBrowserTests.swift`)

- **需要真实 UI** → E2E 测试
  - 原生 UI 操作 → XCUITest (`UITests/*UITests.swift`)
  - 原生 + Web 内容 → Dual Driver (`UITests/OWLDualDriverTests.swift`)

## 编写步骤

1. 读取同类型的现有测试，学习模式
2. 编写测试
3. 运行: `/owl-test {level} {testName}`
4. 读取 run.log 确认测试行为正确（不仅看 pass/fail）
5. 多跑几次确认不 flaky

## 关键约定
- XCUITest 用 AccessibleLabel（NSTextField），不用 SwiftUI Text + clipped
- 修改 bridge/*.h 后必须重建 framework（build_all.sh）
- GTest 无法实例化 WebContents，提取纯函数到 utils
```

#### /test-debug

```markdown
# /test-debug [test-name]

调试失败的测试。

## Step 1: 读取摘要
读取 `/tmp/owl_test_logs/latest/summary.json`，找到失败的测试。

## Step 2: 读取对应时间窗口的日志
从 summary.json 获取 start_time / end_time，读取 run.log 中该范围的内容。

## Step 3: 模式匹配

按以下顺序排查：

1. **是 assertion failure？** → 看断言的预期值 vs 实际值
2. **有 Mojo disconnected？** → Host 进程崩溃，查 chromium 侧日志
3. **有 net::ERR？** → 网络问题，检查 URL 是否可达
4. **有 DCHECK failed？** → C++ 断言，定位代码行
5. **有 timeout？** → 异步等待超时，检查等待条件
6. **两侧都无错误？** → 可能是死锁或主线程阻塞

## Step 4: 输出修复建议
```
根因: [描述]
涉及文件: [路径]
修复: [具体建议]
```
```

### 3.2 Rules

#### .claude/rules/testing.md

```markdown
# 测试系统规则

## 日志优先
- 测试失败后，先读 summary.json 再读 run.log，不要猜测原因
- /tmp/owl_test_logs/latest/ 是最近一次运行的日志

## 测试选择
- 能用 Unit 测的不用 Integration，能用 Integration 测的不用 E2E
- 跨层验证（原生 UI → Web 内容）才用 Dual Driver

## 自闭环
- 写完测试必须跑一次验证 pass
- 失败后读日志诊断，不盲目重试
- 修复后重跑确认不引入新失败

## 已知陷阱
- Pipeline 测试太短（~2s），可能漏掉子进程启动崩溃
- XCUITest 的 AccessibleLabel 必须用 NSTextField，不能用 SwiftUI Text
- 修改 bridge/*.h 后必须 build_all.sh 重建 framework
- GTest 无法实例化 WebContents（mirror test 限制）
```

### 3.3 CLAUDE.md 追加

```markdown
## 测试系统（Agent 操作指南）

### 运行测试
```bash
owl-client-app/scripts/run_tests.sh e2e       # 标准（CI 安全）
owl-client-app/scripts/run_tests.sh all        # 全量
```

### 日志
测试后查看 `/tmp/owl_test_logs/latest/`：
- `summary.json` — 结构化摘要（先读这个）
- `run.log` — 全部日志（Swift + Chromium 交织）

### Agent 技能
- `/owl-test` — 运行 + 分析
- `/test-write` — 编写测试
- `/test-debug` — 调试失败
```

---

## Component 4: 自闭环迭代

### Agent 迭代循环示例

```
任务: "为书签导航写 E2E 测试"

Round 1:
├── Agent 读 /test-write → 决策: Dual Driver（原生 + Web）
├── Agent 编写 testBookmarkNavigate()
├── Agent 运行 /owl-test dual-e2e testBookmarkNavigate
│
├── 读 summary.json → FAILED
│   error: "CDPError.timeout: waitForSelector(h1)"
│
├── Agent 读 run.log 中 14:30:28~14:30:43 时段:
│   14:30:29 [OWL] Navigation started url=about:blank  ← 没导航到目标！
│   14:30:30 [OWL] Page info: title="New Tab"
│   → 根因: 书签点击的 accessibility identifier 拼错
│
└── 修复 identifier → 重跑 → PASSED

Round 2:
├── Agent 多跑 3 次 → 1 次 FAIL
├── 读 run.log → 14:31:15 waitForSelector timeout 在 commit 前触发
└── 修复: timeout 10s → 15s → 跑 5 次全 PASSED → 完成
```

### 日志驱动诊断（决策指引）

```
测试失败
│
├── 读 summary.json → 哪个测试？什么错误？
│
├── 读 run.log 对应时间窗口
│   ├── 有 "[OWL]" 错误日志？
│   │   ├── Mojo disconnected → Host 崩溃，找 RenderProcessTerminated
│   │   ├── callback nil → Bridge 回调未注册
│   │   └── Navigation error → 网络或 URL 问题
│   │
│   ├── 有 Chromium ERROR/FATAL？
│   │   ├── DCHECK → C++ 断言，定位代码行
│   │   ├── GPU process exited → GPU 问题
│   │   └── net::ERR_ → 网络层
│   │
│   └── 两侧都正常？
│       → timeout / 死锁 / 主线程阻塞
│
└── 输出修复建议
```

---

## 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| **Phase 0: Agent 指引（零代码）** | | |
| `.claude/commands/owl-test.md` | 修改 | 增加日志分析能力（Step 2-3） |
| `.claude/commands/test-write.md` | 新增 | 编写测试指引 |
| `.claude/commands/test-debug.md` | 新增 | 调试指引 |
| `.claude/rules/testing.md` | 新增 | 测试规则 |
| `CLAUDE.md` | 修改 | 追加测试系统章节 |
| **Phase 1: 日志捕获** | | |
| `owl-client-app/scripts/run_tests.sh` | 修改 | setup_log_dir + write_summary + append_test_entry + tee 日志 |
| **Phase 2: 双驱动 E2E（已设计）** | | |
| 见 dual-driver phase-1 | | CDPHelper + Playwright |

**注意：不需要新增 OWLLogger.swift，不需要修改 NSLog，不需要修改 Chromium logging 代码。**

---

## 实施计划

| Phase | 内容 | 代码变更 | 优先级 |
|-------|------|---------|--------|
| **Phase 0** | Agent 指引：Skills + Rules + CLAUDE.md | 0 行（纯 Markdown） | **立即** |
| **Phase 1** | run_tests.sh 结构化输出 + 日志捕获 | ~100 行 bash | **高** |
| **Phase 2** | 双驱动 E2E（CDPHelper + Playwright） | ~500 行 Swift/TS | 中 |

**Phase 0 + Phase 1 合计 ~100 行 bash 代码变更。** 没有 Phase 3/4（已砍掉 OWLLogger 迁移）。

---

## 风险 & 缓解

| 风险 | 严重度 | 缓解 |
|------|--------|------|
| Host stderr 未被 tee 捕获（LaunchOptions 改变） | P1 | `base::LaunchProcess` 默认继承父进程 fd；验证：`launch.sh` 已成功捕获 Host 日志到 `/tmp/owl-launch.log` |
| summary.json 的 test entries 解析各 runner 格式困难 | P1 | GTest 有 `--gtest_output=json`；swift test 用正则；xcuitest 解析 `Test Case` 行。先对 GTest 实现（格式最规范），其他层"最佳努力" |
| run.log 过大（长测试） | P2 | Agent 用 summary.json 的 start_time/end_time 精确定位时间窗口，不需要全量读 |
| XCUITest 的 app stderr 被 xcodebuild 吞掉 | P1 | xcodebuild 将 app 的 NSLog/LOG() 混入自身 stdout 输出（带 `[App]` 前缀）。`run_xcuitest()` 捕获 xcodebuild 全量输出到 run.log，app 日志自然包含在内。不需要额外的文件写入机制 |

---

## 评审记录

### Round 1（v1.0, 2026-04-08）

| Agent | LLM | Verdict | P0 | P1 | P2 |
|-------|-----|---------|----|----|-----|
| Claude (架构) | Claude | REVISE | 2 | 5 | 3 |
| Codex (正确性) | GPT-5.4 | REVISE | 2 | 6 | 1 |
| Gemini (简洁性) | Gemini 3.1 Pro | 需重构 | 2 | 2 | 1 |

**关键修复**：

| # | 来源 | 问题 | 修复 |
|---|------|------|------|
| 1 | Gemini P0 | OWLLogger 是过度工程（LLM 不需要 JSON 日志） | **砍掉 OWLLogger 和 NSLog 迁移**。用 stderr/stdout 重定向零代码捕获 |
| 2 | Gemini P0 | 日志文件碎片化（5 个文件 Agent 跳转成本高） | 合并为 3 个文件：summary.json + run.log + cdp-events.log |
| 3 | Claude+Codex P0 | Host 子进程 OWL_LOG_DIR 传递缺失 | 改为 stderr 继承方案，Host 的 LOG() 自动流入同一 stderr，被 tee 捕获 |
| 4 | Claude+Codex P0 | Chromium log_file_path 悬空指针 | 删除方案：不再修改 Chromium logging 代码 |
| 5 | Claude+Codex P1 | summary.json 缺 start_time/end_time | 增加 `start_time` / `end_time` 字段 |
| 6 | Claude P1 | /test-run 与 /owl-test 重叠 | 合并：增强现有 /owl-test |
| 7 | Claude P1 | Bridge Trace 层设计缺失 | 删除：架构图中移除 Bridge Trace 列 |
| 8 | Gemini P1 | Skills 硬编码 grep 命令 | 改为"特征库"模式：描述找什么特征，不规定用什么命令 |
| 9 | Gemini P1 | 测试层级决策树过复杂 | 简化为 Unit / Integration / E2E 三层 |
| 10 | Codex P1 | summary.json 非原子写入 | 先写 .summary.tmp 再 mv；latest symlink 最后更新 |
| 11 | Codex P1 | OWL_LOG_DIR 对 XCUITest 传播不完整 | XCUITest setUp 中从 ProcessInfo 读取并通过 launchEnvironment 注入 |
| 12 | Claude P1 | OWLLogger.configure() 调用时机未定义 | 删除：不再需要 OWLLogger |

### Round 2（v2.0, 2026-04-08）

| Agent | LLM | Verdict | Q2 | Q3 新 P1 |
|-------|-----|---------|----|----|
| Claude (架构) | Claude | REVISE | 7/7 FIXED | 1 |
| Codex (正确性) | GPT-5.4 | REVISE | 7/8 FIXED | 2 |
| Gemini (简洁性) | Gemini 3.1 Pro | REVISE | 4/4 FIXED | 1 |

Round 1 问题几乎全部修复。新 P1 修复：

| # | 来源 | 问题 | 修复 |
|---|------|------|------|
| 1 | Claude+Codex | append_test_entry error 字段 JSON 转义不完整（换行/反斜杠） | 完整转义：`tr '\n\t' '  ' | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g'` |
| 2 | Codex+Gemini | XCUITest 文件日志兜底与"零代码变更"矛盾 | 删除兜底方案。xcodebuild 已将 app 日志混入自身输出，run_xcuitest() 捕获全量输出即可 |
