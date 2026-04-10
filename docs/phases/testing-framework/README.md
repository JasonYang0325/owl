# OWL Browser 测试框架

## 方案版本

**v2 — 三层混合架构**（2026-03-30）

## 测试层次

| 层级 | 工具 | 测什么 | CI 要求 | 测试数 |
|------|------|--------|---------|--------|
| L0 | C++ GTest | Bridge/Host/Client 内部 | 无 | 74+ |
| **L1** | OWLTestBridge | 输入管线、JS、IME、导航 | 无 GUI | 19 |
| L1b | OWLUnitTests (MockConfig) | ViewModel 状态机 | 无 GUI | 7 |
| **L2** | CGEvent (OWLUITest) | 系统输入链验证 | GUI + 独占 | 5 |
| **L3** | XCUITest (需签名) | 原生壳层 UI | 签名 + GUI | 待开发 |

## 运行命令

```bash
# 快速（单元 + 管道，无 GUI）
./scripts/run_tests.sh

# 仅 ViewModel 单元测试
./scripts/run_tests.sh unit

# 仅管道集成测试
./scripts/run_tests.sh pipeline

# CGEvent 系统测试（需 GUI）
./scripts/run_tests.sh system

# 全部
./scripts/run_tests.sh all
```

## 实施状态

| Phase | 内容 | 状态 |
|-------|------|------|
| Phase 0 | OWLBrowserLib 拆分 | 已完成 |
| Phase A | NSEvent POC | 已完成(不可行) |
| Phase B | MockConfig + ViewModel 测试 | 已完成 (7 tests) |
| Phase C | OWLTestBridge 扩展 | 已完成 (3 new tests) |
| Phase D | CGEvent 测试改进 | 已完成 |
| Phase E | 签名 + XCUITest | 需开发者账号 |
| Phase F | 测试脚本 | 已完成 |
