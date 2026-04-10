# Feature Flow v2 — GAN 架构重设计

> 基于 Anthropic Harness Design + OpenAI Harness Engineering 最佳实践的完整重设计方案。
> 核心转变：从"N-reviewer 全票通过"到"单评估器评分收敛"的纯 GAN 模式。

## 一、当前架构 vs 纯 GAN 架构

### 当前模式（问题根源）

```
Generator (Dev Agent) → 产出代码
                ↓
6 个 Reviewer → 各自列出 P0/P1/P2 问题清单
                ↓
收敛条件: 6 个 Reviewer 全部 0 P0/P1  ← 概率学不可能
                ↓
不收敛 → 修复 → 新一轮 6 Reviewer → 修可能引入新问题 → 随机游走
```

**根本问题**:
1. 6 reviewer 全通过概率仅 ~26%（假设单 reviewer 80% 通过率，0.8^6）
2. "列问题"是发散操作——每个 reviewer 都可以发现新问题
3. 修复 reviewer A 的意见可能触发 reviewer B 的新意见
4. 没有共享的"什么算好"标准，每个 reviewer 用自己的标准
5. Reviewer 只读代码不运行验证，信号弱

### 纯 GAN 模式（Anthropic 方法）

```
                    ┌─── 合同协商 ───┐
                    ↓               ↓
             Generator          Evaluator
             (生成者)            (评估者)
                ↓                   ↑
             产出物 ──────────→ 评分 (1-5/维度)
                ↑                   │
                └── 反馈 + 策略 ←───┘
                    (精修 or 转向)
```

**核心区别**:
1. **合同先行**: 开工前协商成功标准，不是做完再挑毛病
2. **评分代替列问题**: 4 个维度各 1-5 分，提供梯度信号
3. **硬阈值收敛**: 所有维度 ≥ 4 分即通过，确定性可达
4. **单评估器**: 一个校准过的评估器 > N 个未校准的 reviewer
5. **验证不仅阅读**: 评估器实际运行测试、截图、操作应用
6. **精修 or 转向**: 分数趋势上升 → 精修，卡住 → 换方案

## 二、GAN 核心循环设计

### 通用循环（适用于所有 phase）

```
┌───────────────────────────────────────────────────────┐
│ Phase GAN Loop                                        │
│                                                       │
│ 1. CONTRACT (合同)                                     │
│    - 主 agent 根据 phase 类型生成评分标准              │
│    - 4-6 个维度，每个有 1-5 分描述 + few-shot 校准      │
│    - 明确验证方法（运行测试？截图？追溯 AC？）          │
│                                                       │
│ 2. GENERATE (生成)                                     │
│    - Generator subagent 产出 phase 成果物              │
│    - 接收合同标准 + 上轮反馈（如有）                    │
│                                                       │
│ 3. EVALUATE (评估)                                     │
│    - Evaluator subagent 执行验证操作                   │
│    - 对每个维度打分 (1-5) + 具体反馈                   │
│    - 关键: Evaluator 必须实际验证（运行/截图/追溯）     │
│                                                       │
│ 4. CONVERGE (收敛判定)                                  │
│    - 所有维度 ≥ 4? → 通过，进入下一 phase              │
│    - 分数趋势上升? → 精修（Generator 修复低分项）       │
│    - 连续 2 轮某维度 ≤ 2? → 转向（Generator 换方案）   │
│    - 达到 max_rounds (3)? → 人工介入                   │
│                                                       │
│ Max rounds: 3 (文档 phase) / 4 (代码 phase)           │
└───────────────────────────────────────────────────────┘
```

### 评分量表（通用）

| 分数 | 含义 | 行动 |
|------|------|------|
| 5 | 优秀 — 超出预期，无需改动 | — |
| 4 | 良好 — 达到标准，微调可选 | 通过阈值 |
| 3 | 及格 — 达到底线，需要特定改进 | 需精修 |
| 2 | 不足 — 显著缺陷，必须修复 | 需精修或转向 |
| 1 | 不可接受 — 根本性问题，需换方案 | 必须转向 |

### 精修 vs 转向决策

```python
def convergence_decision(scores, prev_scores, round_num, max_rounds=3):
    """
    收敛判定逻辑（经全盲评审修正 PIVOT 条件）
    
    修正点: 
    - prev_scores 默认值从 5 改为 0，防止第 2 轮误触发 PIVOT
    - PIVOT 要求同一维度连续两轮 <=2 且未改善
    """
    if all(s >= 4 for s in scores.values()):
        return "PASS"
    if round_num >= max_rounds:
        return "ESCALATE_TO_HUMAN"
    if round_num >= 2 and prev_scores:
        # 只有连续两轮同一维度都 <=2 且分数未上升才触发 PIVOT
        stuck_dims = [
            k for k in scores
            if scores[k] <= 2
            and prev_scores.get(k, 0) <= 2  # 默认 0: 上轮无数据不触发
            and scores[k] <= prev_scores[k]  # 分数未改善
        ]
        if stuck_dims:
            return "PIVOT"
    return "REFINE"
```

## 三、各 Phase 评估标准 + 校准

### 3.1 PRD Phase

**评估维度**:

| 维度 | 定义 | 验证方法 |
|------|------|---------|
| 完整性 | 所有用户故事覆盖？边界明确？异常处理？ | 逐条检查用户故事 + 边界列表 |
| 可测性 | 每个 AC 都是具体、可量化、可自动化的？ | 对每个 AC 尝试写测试描述 |
| 清晰性 | 无歧义？无矛盾？术语一致？ | 搜索模糊词（"适当"、"合理"、"等等"） |
| 可行性 | 技术上可实现？与现有架构兼容？ | 追溯 AC 到架构层级 |

**Few-Shot 校准示例（嵌入 Evaluator prompt）**:

```markdown
## 可测性评分示例（5 档全覆盖，尤其关注 3→4 边界）

**5 分**: "用户点击历史条目后，WebView 在 500ms 内导航到该 URL，地址栏显示对应 URL"
→ 行为明确、阈值量化、可自动断言

**4 分（通过阈值）**: "用户点击历史条目后，WebView 导航到该 URL"
→ 行为和触发条件明确，可写断言；缺少性能阈值但不影响功能测试
→ 为什么是 4 而不是 3: 触发条件（"点击条目"）和预期结果（"导航到 URL"）都是具体可断言的

**3 分（需精修）**: "用户可以查看浏览历史"
→ "查看"不够具体：是列表？搜索？分页？排序？可以写测试但需要猜测验收行为
→ 为什么是 3 而不是 4: 缺少交互动作和预期结果，测试工程师需要自行假设

**2 分（显著不足）**: "系统应该记录历史"
→ 只有系统行为没有用户可感知的验收标准，不知道"记录"意味着什么

**1 分**: "历史功能应该好用"
→ 完全不可测，无任何具体行为描述
```

### 3.2 UI Design Phase

**评估维度**:

| 维度 | 定义 | 验证方法 |
|------|------|---------|
| 设计质量 | 整体协调性、视觉层次、与项目风格一致 | 截图审查 + 与现有 UI 对比 |
| 交互完整性 | 所有状态覆盖（默认/悬停/空/加载/错误/禁用） | 状态清单逐条核对 |
| 可实现性 | 组件拆分合理？复用现有组件？性能可控？ | 追溯组件到 SwiftUI 实现 |
| 无障碍 | 对比度、焦点管理、键盘导航 | 检查 WCAG 标准 |

**Few-Shot 校准示例**:

```markdown
## 交互完整性评分示例

**5 分**: 设计稿覆盖了 8 种状态：默认、悬停、选中、禁用、加载中、空数据、
错误、搜索中间态。每种状态都有独立的视觉说明和过渡动画描述。

**3 分**: 设计稿有默认态和悬停态，但缺少空数据态和错误态。
→ 核心交互覆盖了，但异常路径缺失

**1 分**: 只有一张"最终效果图"，无状态说明
→ 无法据此实现交互
```

### 3.3 Tech Design Phase

**评估维度**:

| 维度 | 定义 | 验证方法 |
|------|------|---------|
| 架构适配 | 遵循项目分层？模块边界清晰？模式一致？ | 对照 CLAUDE.md 架构规则 |
| 正确性 | 逻辑无漏洞？并发安全？边界处理？ | 心智模拟数据流 + 找反例 |
| 简洁性 | 最小必要复杂度？复用现有代码？无过度工程？ | 检查是否有现成可复用的模块 |
| 可测性 | 测试策略可执行？Mock 策略合理？ | 对每个组件尝试描述测试方法 |

**Few-Shot 校准示例**:

```markdown
## 简洁性评分示例

**5 分**: 方案复用了现有 BookmarkService 的 SQLite 封装，
只新增 HistoryEntry 表和对应的 CRUD 方法，无新抽象层。

**3 分**: 方案引入了新的 StorageAbstractionLayer 来统一
Bookmark/History/Settings 的存储，但当前只有 History 用它。
→ 抽象超前于需求，但技术上合理

**1 分**: 方案引入了 Repository Pattern + Unit of Work +
Event Sourcing，代码量预估从 250 行膨胀到 800 行。
→ 严重过度工程
```

### 3.4 Dev Phase（核心 GAN 环节）

**评估维度**:

| 维度 | 定义 | 验证方法 |
|------|------|---------|
| AC 覆盖 | 每个 AC 都有对应实现 + 测试？ | AC→代码→测试 追溯矩阵 |
| 代码质量 | 遵循约定？接口清晰？无死代码？ | 读代码 + 对照 CLAUDE.md |
| 测试质量 | 断言有意义？边界覆盖？测试独立？ | 读测试 + 检查断言 |
| 功能正确 | 编译通过？测试全绿？ | **实际运行** 构建和测试 |

**Evaluator 验证操作（Dev Phase 专用）**:
```
1. 运行构建命令，确认编译通过
2. 运行测试命令，确认测试全绿
3. 读取 AC 列表，逐条追溯到实现代码和测试代码
4. 对每个维度打分 + 给出具体反馈
```

**Few-Shot 校准示例**:

```markdown
## AC 覆盖评分示例

**5 分**: 全部 8 个 AC 都有对应实现，每个 AC 至少有 1 个 happy-path
测试 + 1 个边界测试。测试注释标注了 AC 编号。

**3 分**: 7/8 AC 有实现和测试，但 AC-005（分页）只有 happy-path
测试，缺少空列表和末页边界。

**1 分**: 实现只覆盖了 3/8 AC，测试没有 AC 编号标注，
无法确认哪些 AC 被测试了。
```

### 3.5 Test Review Phase

**评估维度**:

| 维度 | 定义 | 验证方法 |
|------|------|---------|
| 路径覆盖 | 所有函数/分支有测试？ | 代码路径枚举 vs 测试清单 |
| 断言质量 | 测试真正验证行为（非重言式）？ | 读每个断言，确认它能抓到 bug |
| 集成覆盖 | 跨组件交互有测试？ | 追溯数据流跨模块边界 |
| 需求追溯 | 每个 AC 映射到至少一个测试？ | AC→测试 矩阵完整性 |

## 四、多轮全盲评审优化

### 当前多轮评审 vs 优化后的 GAN 评审

| 方面 | 当前 | 优化后 |
|------|------|--------|
| 评审者数量 | 4-6 个同质 reviewer | **2 Claude Evaluator + 1 跨 LLM 专项** |
| 信号类型 | P0/P1/P2 问题列表 | **4 维度 1-5 分** + 具体反馈 |
| 收敛条件 | 全部 0 P0/P1 | **两个 Evaluator 的保守分数 ≥ 4** |
| 校准方式 | 无 | **Few-shot 示例** |
| 验证方式 | 只读代码 | **实际运行 + 截图 + 追溯** |
| 最大轮次 | 无上限（靠 same_phase_count=8） | **3-4 轮硬上限** |
| 失败策略 | 只有精修 | **精修 or 转向** |
| 跨 LLM | 4 个 LLM（全降级为同模型） | **按 phase 类型选 Codex 或 Gemini** |

### 评估器组合设计

#### 为什么 2 个 Evaluator + 1 跨 LLM

**2 个 Claude Evaluator（互盲）**:
- 防止单个 Evaluator 的幻觉或盲点
- 两个独立评分取保守值（每维度取 min），确保通过的产出真正达标
- 互盲 = 两个 Evaluator 互不可见，各自独立打分

**1 个跨 LLM 专项评审**:
- 不同 LLM 有不同的认知偏差，跨模型抵消幻觉
- 按 phase 类型选用最适合的 LLM
- 跨 LLM 评审不使用评分模式，而是输出"高置信度发现"列表（≤5 条），补充 Evaluator 视角

#### 各 Phase 的评估器配置

**关键原则: 两个 Evaluator 都评估全部维度**，但各自有侧重角度和验证方式。
这样 `min()` 才有真正的互盲校验价值。

| Phase | Evaluator A 侧重 | Evaluator B 侧重 | 跨 LLM | 为什么 |
|-------|------------------|------------------|--------|--------|
| PRD | 偏验证操作（逐条检查 AC） | 偏全局审查（结构/一致性） | Codex: 技术风险 | GPT 逻辑推理强 |
| UI Design | 偏视觉验证（截图审查） | 偏结构审查（组件树/token） | Gemini: UX 审查 | Gemini 前端视角 |
| Tech Design | 偏正确性验证（数据流追溯） | 偏全局审查（简洁性/复用） | Codex: 安全/正确性 | GPT 找逻辑漏洞 |
| Dev | 偏运行验证（编译+测试+AC 追溯） | 偏代码阅读（质量+约定） | Codex: 代码审查 | GPT 代码审查深入 |
| Test | 偏运行验证（执行测试+覆盖率） | 偏静态审查（断言质量+追溯） | Codex: 边界 case | GPT 找边界强 |
| UI Verify | 偏截图对比 | 偏交互验证 | Gemini: 视觉 | Gemini 多模态 |

**注**: Evaluator A 和 B 都输出全部 4 个维度的评分。"侧重"指验证操作的重点，
不是限制评分范围。这确保每个维度有两个独立评分，`min()` 有实际意义。

#### 评分合并策略

```python
def merge_evaluator_scores(eval_a_scores, eval_b_scores, cross_llm_findings):
    """
    两个 Evaluator 的分数合并 + 跨 LLM 发现作为参考
    
    设计原则（经全盲评审修正）:
    - 两个 Evaluator 都评估全部 4 个维度 → min() 有真正的互盲价值
    - 跨 LLM 发现不直接降分 → 作为下一轮 Evaluator 的参考输入
    - Evaluator 是评分权威，跨 LLM 是补充视角
    """
    merged = {}
    for dim in eval_a_scores:
        # 保守策略: 取两个 Evaluator 的较低分
        merged[dim] = min(eval_a_scores[dim], eval_b_scores[dim])

    # 跨 LLM 发现不降分，而是附加为参考信息
    # 在下一轮 REFINE 时传给 Evaluator，由 Evaluator 自行决定是否采纳
    supplementary_findings = [
        f for f in cross_llm_findings if f.confidence >= 0.8
    ]

    return merged, supplementary_findings
```

**跨 LLM 发现的传递路径**:
```
Round N: 跨 LLM 输出高置信发现 → 不改分数，存入 supplementary_findings
Round N+1: Evaluator 收到上轮 supplementary_findings 作为参考
            → Evaluator 自行判断是否影响本轮评分
```

这样 **Evaluator 始终是评分权威**，跨 LLM 提供的是认知多样性（补充视角），
而非拥有否决权的第三方评判者。

#### 跨 LLM 调用方式

```bash
# 代码/技术方案 → Codex
bash .claude/scripts/llm-review.sh codex \
  "你是独立代码审查员。只报告你有 ≥80% 置信度的问题。
   对每个问题: 1行描述 + 关联维度(ac_coverage|code_quality|test_quality|functionality)
   最多 5 个发现。无发现则输出 LGTM。
   文件路径: {paths}" --timeout 120

# 前端/UI → Gemini
bash .claude/scripts/llm-review.sh gemini \
  "你是独立 UI/UX 审查员。只报告你有 ≥80% 置信度的问题。
   对每个问题: 1行描述 + 关联维度(design_quality|interaction|implementability|a11y)
   最多 5 个发现。无发现则输出 LGTM。" --timeout 120

# 降级规则: 如果 Codex/Gemini 不可用 → 改用 Agent(model: "sonnet") 执行
# 降级后仍保留跨 LLM 补充视角的价值（sonnet vs opus 也有认知差异）
```

### "全盲"保留机制

每轮评审保持严格全盲：

```
Round 1:
  Evaluator A 独立打分（4 维度）
  Evaluator B 独立打分（4 维度）
  跨 LLM 独立审查（高置信度发现）
  → 合并分数

Round 2:
  Step 1 (Q1): 两个 Evaluator 全盲重新审查修改后的产出
  Step 2 (Q2): 给出 Round 1 的合并分数，验证低分项是否改善
  Step 3:     综合 Q1+Q2 给出本轮最终分数
  跨 LLM: 只对 Round 1 有发现的维度做针对性复查

Round 3: 同 Round 2 模式
```

**关键**: 
- 两个 Evaluator 互盲 = 独立认知，避免单点幻觉
- Q1 全盲扫描防止锚定效应
- Q2 针对性验证确保问题确实修复
- 跨 LLM 提供认知多样性而非重复评审
- 取 min 分数 = 保守策略，宁可多修一轮也不放过问题

## 五、自循环迭代机制重设计

### 5.1 动态 Orchestrator Prompt

Stop hook 不再注入固定 225 行文本，而是生成 **动态 micro-prompt**:

```bash
# flow-stop-hook.sh 改动

# 读取状态文件
STATE=$(cat "$STATE_FILE")
PHASE=$(parse_field "current_phase")
SUB_STEP=$(parse_field "current_sub_step")
LAST_SCORES=$(parse_field "last_scores")
LAST_FEEDBACK=$(parse_field "last_feedback")

# 生成动态 prompt
PROMPT="继续 Feature Flow: ${FEATURE_NAME}
Phase: ${PHASE} | Module: ${CURRENT_MODULE}/${TOTAL_MODULES}
Sub-step: ${SUB_STEP}

上轮结果: ${LAST_SCORES}
待处理: ${LAST_FEEDBACK}

下一步: 读取状态文件 .claude/feature-flow.local.md 获取完整上下文。
规则文件: ~/.claude/commands/${PHASE}.md（仅首次进入 phase 时需要读取）"
```

**关键改进**: prompt 从 225 行降到 5-10 行，携带上轮反馈，agent 不需要每次从头定位。

### 5.2 状态文件重设计

从 frontmatter + markdown body 改为 **纯结构化 YAML**:

```yaml
# .claude/feature-flow.local.md
---
active: true
session_id: "abc123"
feature_name: "history"
workflow_type: "feature"
status: "running"  # running | error-retriable | blocked | complete

# 进度追踪
current_phase: "dev"
current_module: 2
total_modules: 5
current_sub_step: "evaluate"  # contract | generate | evaluate | converge

# GAN 循环状态
gan_round: 2
max_rounds: 3
last_scores:
  ac_coverage: 4
  code_quality: 3
  test_quality: 4
  functionality: 5
last_feedback_file: ".claude/feedback/dev-module-2-round-2.md"  # 结构化反馈存独立文件
convergence_decision: "refine"  # refine | pivot | pass | escalate
# 跨 LLM 补充发现（不降分，传给下轮 Evaluator 参考）
supplementary_findings:
  - "Codex: addHistoryEntry 未处理 URL 超过 2048 字符的情况 [dim:code_quality]"

# 迭代控制
iteration: 12
max_iterations: 100
skill_loaded: true  # compact 后重置为 false

# 错误追踪
error_count: 0
last_error: ""
failure_stats:
  IMPL_BUG: 0
  TEST_BUG: 1
  SPEC_AMBIGUITY: 0

# 模块进度（替代 markdown checkbox）
modules:
  - name: "Host HistoryService Core"
    phases: {tech: done, dev: in_progress, test: pending, review: pending}
  - name: "Mojo + Bridge"
    phases: {tech: pending, dev: pending, test: pending, review: pending}
  - name: "History Sidebar UI"
    phases: {tech: pending, dev: pending, test: pending, ui_verify: pending, review: pending}

# 经验教训
lessons:
  - "SQLite FTS5 需要在 GN 中显式启用"
  - "bridge/*.h 修改后需重建 framework"
---
```

**改进点**:
- 消除 body 冗余，一个来源管一切
- `current_sub_step` 提供 phase 内粒度
- `last_scores` 携带 GAN 评分，`last_feedback_file` 指向结构化反馈详情
- `supplementary_findings` 存跨 LLM 发现（供下轮 Evaluator 参考，不直接降分）
- `skill_loaded` 避免重复读 skill 文件
- `failure_stats` 支持诊断反馈

**反馈文件格式** (`.claude/feedback/{phase}-module-{N}-round-{R}.md`):
```yaml
round: 2
evaluator_a:
  scores: {ac_coverage: 4, code_quality: 3, test_quality: 4, functionality: 5}
  feedback:
    code_quality:
      - "函数 addHistoryEntry 超过 80 行，建议拆分为 validate + insert"
      - "缺少对 URL scheme 的校验（允许 javascript: URL 是安全风险）"
evaluator_b:
  scores: {ac_coverage: 4, code_quality: 3, test_quality: 3, functionality: 5}
  feedback:
    code_quality:
      - "命名不一致: addHistoryEntry vs insertBookmark，建议统一为 insert*"
    test_quality:
      - "testAddEntry 只测了 happy path，缺少空 URL / 超长 URL 边界"
cross_llm:
  - source: "codex"
    finding: "addHistoryEntry 未处理 URL > 2048 字符"
    dimension: "code_quality"
    confidence: 0.9
merged_scores: {ac_coverage: 4, code_quality: 3, test_quality: 3, functionality: 5}
verdict: "REFINE"
```

### 5.3 收敛熔断器

```yaml
# 替代 same_phase_count=8
max_rounds: 3          # GAN 评审最多 3 轮（代码 phase 可设 4）
max_sub_step_retries: 3 # 子步骤（如编译修复）最多重试 3 次
```

Stop hook 中的检测逻辑：
```bash
# 熔断检测
if [[ $GAN_ROUND -ge $MAX_ROUNDS ]]; then
  # 检查最后一轮分数
  if all_scores_above_threshold "$LAST_SCORES" 4; then
    # 收敛了，继续
    :
  else
    # 未收敛，升级到人工
    set_status "blocked"
    set_feedback "评审 $MAX_ROUNDS 轮未收敛，最低分: ..."
    exit 0
  fi
fi
```

## 六、Phase Skill 文件改造

### 通用模板（所有 phase 共享的 GAN 循环部分）

每个 skill 文件的评审部分统一改为以下结构：

```markdown
## GAN 评审循环

### Step 1: 合同（Contract）

主 agent 构建评估合同，包含：
1. 本 phase 的 4 个评估维度（见下方维度定义）
2. 每个维度的 1-5 分描述
3. Few-shot 校准示例
4. 验证方法（Evaluator 需要执行的操作）

### Step 2: 生成（Generate）

启动 Generator subagent:
```
Agent(
  description: "Generator: {phase} 产出",
  prompt: """
  {共享上下文}
  {合同标准}
  {上轮反馈: 如有}
  
  任务: 生成/修复 {phase} 产出物
  策略: {refine | pivot}
  """
)
```

### Step 3: 评估（Evaluate）

启动 Evaluator subagent:
```
Agent(
  description: "Evaluator: {phase} 评估",
  model: "opus",  # Evaluator 用最强模型
  prompt: """
  你是独立评估者。你没有参与生成过程。
  
  {合同标准 + few-shot 校准}
  
  ## 验证操作
  {phase 特定的验证步骤}
  
  ## 评分要求
  对每个维度:
  1. 执行验证操作
  2. 给出 1-5 分
  3. 如 < 4 分，给出具体、可操作的反馈
  4. 如 ≤ 2 分，建议"精修"还是"转向"
  
  ## 输出格式
  SCORES:
    维度1: N/5 — 理由
    维度2: N/5 — 理由
    ...
  VERDICT: PASS | REFINE | PIVOT
  FEEDBACK: (仅 REFINE/PIVOT 时)
    - 维度X: 具体改进建议
  """
)
```

### Step 4: 收敛判定（Converge）

主 agent 解析 Evaluator 输出:
- PASS → 更新状态，进入下一 phase
- REFINE → 将反馈传给 Generator，gan_round++，回到 Step 2
- PIVOT → 将反馈 + "请换一个方案" 传给 Generator，gan_round++
- gan_round > max_rounds → 状态改为 blocked，汇总给用户

### Step 5: 可选第二视角（仅复杂 phase）

在 Step 3 的 Evaluator 之外，可选启动 Devil's Advocate:
```
Agent(
  description: "Devil's Advocate: {phase}",
  model: "sonnet",
  prompt: """
  假设这个 {phase} 产出物会导致项目失败。
  最可能的 3 个原因是什么？
  对每个原因给出具体证据。
  
  注意: 只报告你有高置信度 (>80%) 的问题。
  不要为了凑数而编造问题。
  """
)
```

Devil's Advocate 的发现作为 Evaluator 反馈的补充，不独立触发收敛判定。
```

### Dev Phase 改造示例

当前 dev.md 的 5 角色并行改为：

```markdown
## Dev Phase GAN 循环

### Generator 组 (并行)
- Dev Agent: 写实现
- Test Writer: 写测试（仍保持隔离，不看实现代码）

### Evaluator 组（并行，在 Generator 完成后）

三个 Evaluator 并行启动，互不可见：

**Evaluator A (Claude Opus)**:
- 维度: AC 覆盖 + 功能正确
- 验证: 运行构建 + 运行测试 + AC 追溯矩阵

**Evaluator B (Claude Opus)**:
- 维度: 代码质量 + 测试质量
- 验证: 读代码 + 检查约定 + 断言审查

**Codex 审查 (GPT-5.4)**:
- 角色: 跨 LLM 代码审查（高置信度发现，≤5 条）
- 验证: 读代码 + 找逻辑漏洞/安全问题/边界 case

三者合并：取 A/B 每维度的 min 分数 + Codex 高置信发现可降分。

### 角色变化
| 旧 | 新 | 原因 |
|----|-----|------|
| Dev Agent | Generator-Dev | 不变 |
| Test Writer | Generator-Test | 不变 |
| 6 Reviewer | 2 Evaluator + 1 Codex | 互盲双评 + 跨 LLM 防幻觉 |
| Runner | Evaluator A 内置 | 运行测试是验证的一部分 |
| Arbitrator | Evaluator 合并判定 | 失败归因融入评分 |

Agent 总数: 10 → 5 (Dev + Writer + Eval-A + Eval-B + Codex)
```

## 七、自适应复杂度

### 复杂度分级

```
简单 (<200 行, 单模块):
  Plan → Implement+Test → 1 Evaluator, max 2 轮
  跳过: PRD, UI Design, Task Split, Test Review
  
中等 (200-500 行, 2-3 模块):
  PRD(简) → Task Split → [Tech+Dev+Test] per module → 1 Evaluator, max 3 轮
  跳过: UI Design（除非明确涉及 UI）, Test Review
  
复杂 (>500 行, 4+ 模块):
  完整 flow + Evaluator + 可选 Devil's Advocate, max 3 轮
```

### 复杂度评估标准

在 Phase 0（需求澄清）后，主 agent 根据以下维度评估：

```
- 预估代码行数
- 涉及架构层数（仅 Swift? Swift+Bridge? Swift+Bridge+Host?）
- 是否涉及 UI 变更
- 是否涉及新的 Mojo 接口
- 是否涉及数据持久化
```

## 八、实施路线图

### Phase 1: 核心 GAN 循环（最高优先级）

**改动文件**:
- `~/.claude/commands/dev.md` — 从 5 角色改为 GAN 3 角色
- `~/.claude/commands/test.md` — 从 Writer+3Reviewer 改为 GAN
- `~/.claude/commands/prd.md` — 从 4-LLM 评审改为 GAN
- `~/.claude/commands/tech-design.md` — 从 3-LLM 评审改为 GAN

**核心改动**: 每个 skill 文件的评审部分替换为 GAN 循环模板 + phase 专用评分标准。

### Phase 2: 状态管理简化

**改动文件**:
- `.claude/scripts/flow-setup.sh` — 生成新格式状态文件
- `.claude/scripts/flow-stop-hook.sh` — 动态 micro-prompt
- `.claude/scripts/flow-compact-hook.sh` — 适配新状态格式
- `.claude/scripts/flow-phase-gate.sh` — 从状态文件读取 modules 进度

**核心改动**: 状态文件从 frontmatter+body 改为纯 YAML，stop hook 输出动态 prompt。

### Phase 3: 校准体系

**新增文件**:
- `~/.claude/commands/evaluator-calibration.md` — 通用校准模板
- 每个 phase skill 文件中嵌入 few-shot 校准示例

**核心改动**: 为每个 phase 的每个评估维度编写 5/3/1 分的校准示例。

### Phase 4: 自适应复杂度

**改动文件**:
- `~/.claude/commands/flow.md` — 增加复杂度评估 + 分级逻辑
- `.claude/scripts/flow-setup.sh` — 支持 `--complexity simple|medium|complex`

### Phase 5: 可选优化

- Devil's Advocate 机制（仅复杂 phase）
- 多 LLM 集成（作为可选插件，默认关闭）
- 进度可见性（`flow-status.sh` 脚本）
- 成本追踪（状态文件记录 token 估算）

## 九、预期效果对比

| 指标 | Flow v1 | Flow v2 (GAN) |
|------|---------|---------------|
| 评审者/phase | 4-6 同质 | **2 Claude Evaluator + 1 跨 LLM** |
| 收敛条件 | 全部 0 P0/P1 | **双 Evaluator min 分 ≥ 4** |
| 最大评审轮次 | 无上限 | 3 (文档) / 4 (代码) |
| Agent 总数/模块 | 23-80 | 7-10 |
| 5 模块总 agent | 210-420 | 40-60 |
| 评审信号类型 | 问题列表(发散) | 分数+反馈(收敛) |
| 校准方式 | 无 | Few-shot 示例 |
| 验证方式 | 只读代码 | 运行+截图+追溯 |
| 迭代次数(预估) | ~50 | ~15-20 |
| Token 消耗(预估) | ~50M | ~8-12M |

## 十、脚本驱动的确定性状态机

### 核心原则

> **Agent 是执行者，脚本是指挥者。**
> 所有编排逻辑（下一步做什么、启动哪些 agent、怎么判断收敛）由确定性脚本控制。
> Agent 只做 LLM 擅长的事：读代码、写代码、评估质量。

### 架构对比

```
v1 (agent 驱动):
  Stop Hook → 注入 225 行固定 prompt
  Agent → 读 skill 文件 → 自行决定做什么 → 自行组装 subagent prompt
  → 不确定性: agent 可能误解指令、跳步、漏步、忘记更新状态

v2 (脚本驱动):
  Stop Hook → 调用 flow-orchestrator.sh
  Orchestrator → 读状态 → 确定性状态机 → 输出精确指令（含完整 prompt）
  Agent → 机械执行指令（启动指定 agent、运行指定命令、写指定文件）
  → 不确定性: 仅限于 LLM 生成/评估的质量，编排逻辑完全确定
```

### 状态机定义

```
每个 GAN Phase (prd/tech-design/dev/test/test-review) 内部:

  ┌─────────┐    ┌──────────┐    ┌───────────────┐    ┌──────────┐
  │ prepare │───→│ generate │───→│ compile_check │───→│ evaluate │
  └─────────┘    └──────────┘    └───────────────┘    └──────────┘
                       ↑                                    │
                       │              ┌──────────┐          │
                       │              │  parse   │←─────────┘
                       │              └──────────┘
                       │                    │
                       │         ┌──────────┴──────────┐
                       │         │ converge decision   │
                       │         └──────────┬──────────┘
                       │              ┌─────┴─────┐
                       │         REFINE│     │PASS  │PIVOT
                       │              │     │      │
                       └──────────────┘     │      └──→ generate (新方案)
                                            │
                                      next phase

非 GAN Phase (task-split/clarify):
  prepare → execute → validate → next phase
```

### 脚本职责分工

```
.claude/scripts/
├── flow-stop-hook.sh           # 精简: 只调 orchestrator, 输出 JSON
├── flow-orchestrator.sh        # 核心: 状态机 + 指令生成
├── flow-parse-scores.sh        # 解析评估输出 + 收敛决策
├── flow-gen-prompt.sh          # 组装 Evaluator/Generator prompt
├── flow-phase-transition.sh    # Phase 切换 + 前置验证
├── flow-compact-hook.sh        # 压缩后恢复
├── flow-setup.sh               # 初始化
├── llm-review.sh               # 跨 LLM 调用（已有）
└── templates/                  # Prompt 模板
    ├── evaluator-dev.md
    ├── evaluator-prd.md
    ├── evaluator-tech.md
    ├── generator-dev.md
    └── calibration/
        ├── dev-scores.md
        ├── prd-scores.md
        └── tech-scores.md
```

### 指令格式

Orchestrator 输出结构化指令，agent 机械执行:

```markdown
## 🔧 Flow 指令 #12

**动作**: LAUNCH_EVALUATORS
**Phase**: dev | **Module**: 2/5 | **GAN Round**: 1

### 步骤 1: 并行启动 Evaluator A + Evaluator B + 跨 LLM

**Evaluator A** — Agent(description: "Eval-A: dev m2", model: "opus"):
<PROMPT_A>
(由 flow-gen-prompt.sh 生成的完整 prompt，含校准示例)
</PROMPT_A>

**Evaluator B** — Agent(description: "Eval-B: dev m2", model: "opus"):
<PROMPT_B>
(由 flow-gen-prompt.sh 生成的完整 prompt，含校准示例)
</PROMPT_B>

**跨 LLM** — Bash:
bash .claude/scripts/llm-review.sh codex "(prompt)"

### 步骤 2: 写入反馈文件

将结果写入 `.claude/feedback/dev-m2-r1.yaml`:
(脚本提供模板)

### 步骤 3: 更新状态

修改 `.claude/feature-flow.local.md`:
  current_sub_step: "parse"

⚠️ 严格按步骤执行。完成后 session 会自动继续。
```

### Evaluator 输出格式（脚本可解析）

```
SCORES:
ac_coverage: 4
code_quality: 3
test_quality: 4
functionality: 5
VERDICT: REFINE
FEEDBACK:
[code_quality]: 函数 addHistoryEntry 超过 80 行，建议拆分
[code_quality]: 缺少对 URL scheme 的校验
[test_quality]: testAddEntry 只测了 happy path
```

`flow-parse-scores.sh` 用 grep/sed 解析此格式，计算 min 分数，做收敛决策。

### 关键: 脚本处理的 vs Agent 处理的

| 操作 | 谁处理 | 为什么 |
|------|--------|--------|
| 决定下一步做什么 | **脚本** | 确定性状态机 |
| 组装 subagent prompt | **脚本** | 模板 + 变量替换 |
| 解析评审分数 | **脚本** | 正则匹配 |
| 收敛/精修/转向决策 | **脚本** | 确定性函数 |
| Phase 切换 | **脚本** | 前置检查 + 状态更新 |
| 启动 subagent | **Agent** | 需要 Agent tool |
| 写代码/文档 | **Agent** | 需要 LLM |
| 评估质量/打分 | **Agent** | 需要 LLM |
| 运行测试 | **Agent** | 需要 Bash tool |

## 十一、关于保留多轮评审的说明

你的直觉是对的——**多轮评审让每个阶段的产出更稳定成熟**。GAN 模式不是取消多轮评审，
而是让每一轮更有效：

1. **评分信号 > 问题清单**: 评分是收敛的（向 4-5 分靠拢），问题清单是发散的（每轮可以发现新问题）
2. **单个校准评估器 > 多个未校准 reviewer**: 一致性更高，避免随机游走
3. **硬上限 + 转向**: 防止在错误方向上无限精修
4. **验证不仅阅读**: 评估器实际运行代码，发现的问题更真实

你原来的"Q1 全盲 → Q2 验旧 → Q3 查新"模式完全保留，只是用评分包装：
- Q1: 评估器全盲打分（不看上轮评审）
- Q2: 对照上轮低分项，确认是否改善
- Q3: 综合给出本轮分数 + 新反馈
