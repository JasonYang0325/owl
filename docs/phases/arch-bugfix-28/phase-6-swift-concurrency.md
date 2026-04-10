# Phase 6: Swift 并发安全 (BH-008, BH-012, BH-018)

## Goal
修复 Swift 层的内存泄漏、actor 竞争和初始化线程安全问题。

## Scope
- **Modified**: `owl-client-app/ViewModels/BrowserViewModel.swift`, `owl-client-app/ViewModels/AIChatViewModel.swift`, `owl-client-app/Services/AIService.swift`, `owl-client-app/Services/OWLBridgeSwift.swift`, Swift test files
- **Layers**: Swift

## Dependencies
- None (all independent)

## Items

### BH-008: passRetained → withCheckedContinuation
- One-shot C 回调改用 `Box<CheckedContinuation>` 模式
- 参考 BookmarkService 的正确实践
- 覆盖: createTab, createTabForNewTabRequest, activateTab(deferred), undoCloseTab

### BH-012: AIChatViewModel AsyncStream
- `onToken` 闭包 → `AsyncStream<String>`
- 消除 actor 边界闭包传递
- AIService 接口改为返回 `AsyncStream`

### BH-018: OWLBridgeSwift os_unfair_lock
- `@MainActor` → `os_unfair_lock` / `OSAllocatedUnfairLock`
- 保护 `initialized` 静态变量
- C-ABI 同步调用兼容

## Acceptance Criteria
- [ ] Swift Unit Test: 正常路径和取消路径均正确释放
- [ ] Swift Unit Test: 并发 stream 访问无 data race
- [ ] Swift Unit Test: 并发初始化只执行一次
- [ ] TSan: 无 data race 报告
- [ ] 新增测试 ≥ 5

## Status
- [ ] Tech design review
- [ ] Development
- [ ] Code review
- [ ] Tests pass
