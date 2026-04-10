# Context Menu — Flow Retrospective

**Feature**: Module E 右键上下文菜单
**Duration**: 23 iterations | 3 modules | ~3 hours
**Test Result**: 388/388 C++ GTest (from 348 baseline, +40 new)

## Summary

| Phase | M1 (Pipeline+Page) | M2 (Link+Text+Edit) | M3 (Image+Security) |
|-------|----|----|-----|
| Tech Design | 2 rounds, PASS | 1 round+fix, PASS | 1 round, PASS |
| Dev | 1 round, PASS (358→358) | 1 round, PASS (368) | 1 round, PASS (388) |
| Test | 2 rounds, PASS | 1 round, PASS (378) | 1 round, PASS (388) |

## Key Findings

### 1. Mirror Test Structural Limitation (All Modules)
C++ GTest cannot instantiate Chromium `content::WebContents`, so tests verify reimplemented logic (mirrors) instead of real code. All evaluators flagged this (假阳性 risk 2-4/10).

**Action**: Extract testable logic to `context_menu_utils.cc` in future; rely on XCUITest for E2E.

### 2. Dev Agent Scope Creep (M1)
Dev Agent given 2-fix task (+~20 lines) added unrelated SecurityLevel code (+265 lines). Required git revert.

**Action**: Always specify "only modify X, do not add Y" with anti-examples in prompts.

### 3. Test Phase Discipline (M1)
Main agent incorrectly launched Dev Agent during test phase to fix impl bugs. Violated test.md rule.

**Action**: IMPL_BUG in test phase → report to user, don't fix.

### 4. flow-setup.sh Completion Bug
State file had `status: "complete"` but `active: true`, blocking new flows. Fixed by adding status check.

## Audit Findings (P0/P1/P2)

### P0
- **Mirror test divergence**: TruncateSelectionText mirror and real impl have different lead-byte handling — could mask real bugs. Extract to shared utility.

### P1
- **NOTREACHED() → LOG(WARNING)**: kCopyLink/kCopyImage/kSaveImage had NOTREACHED() in Phase 1/2, crashes in debug builds. Fixed in Phase 3.
- **Evaluator dimension overlap**: 3 evaluators cover "correctness" under different names, low info increment. Standardize dimensions.
- **Structural limitation early detection**: If R1 feedback says "can't test (needs XCUITest)", auto-SKIP R2/R3 to save ~4 iterations.

### P2
- **run_tests.sh**: Swift test output parsing via sed is fragile; format changes cause silent SKIP.
- **kCopyLink mailto**: Scheme filter rejects mailto: URLs — legitimate use case, consider allowlist expansion.
- **selection_text**: CollapseWhitespaceASCII doesn't handle U+3000 (CJK fullwidth space).

## Files Changed

| File | Lines Changed |
|------|------|
| `mojom/web_view.mojom` | +ContextMenuType, +ContextMenuAction, +ContextMenuParams, +OnContextMenu, +ExecuteContextMenuAction, +OnCopyImageResult |
| `host/owl_real_web_contents.mm` | HandleContextMenu extraction, ExecuteContextMenuAction dispatch, DownloadImage callback |
| `bridge/owl_bridge_api.h/.cc` | C-ABI context menu callback, CopyImageResult callback |
| `bridge/OWLBridgeWebView.mm` | Observer stubs |
| `host/owl_context_menu_unittest.cc` | 40 new tests across 3 phases |
| `host/owl_web_contents.h/.cc` | ExecuteContextMenuAction interface |

## Docs Produced

- `docs/prd/context-menu.md` — PRD (3-round review)
- `docs/ui-design/context-menu/design.md` — NSMenu design
- `docs/phases/context-menu/` — 3 phase docs with tech designs
- `feedback/` — 8 YAML feedback files
