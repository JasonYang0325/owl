# Phase 5: Client 层修复 (BH-013, BH-015, BH-020, BH-023, BH-028)

## Goal
修复 Client ObjC++ 层的 URL 编码、线程安全、URL 检测、状态机问题。

## Scope
- **Modified**: `client/OWLAddressBarController.mm`, `client/OWLAIChatSession.mm`, `client/OWLBrowserMemory.mm`, `client/OWLWebContentView.mm`, `client/OWLAgentSession.mm`, unittest files
- **Layers**: Client

## Dependencies
- None (all independent)

## Items

### BH-013: URL 编码 → NSURLComponents
- `NSURLComponents.queryItems` 自动编码 query value
- 不使用 `URLQueryAllowedCharacterSet`
- GURL 对已编码 URL 不二次编码

### BH-015: ObjC 集合 main-thread 断言
- `NSAssert([NSThread isMainThread], ...)` in DEBUG
- 影响: OWLAIChatSession, OWLBrowserMemory

### BH-020: inputLooksLikeURL 统一
- 合并 `OWLAddressBarController.mm` 和 `AddressBarViewModel.swift` 判断逻辑
- 统一使用 C-ABI `OWLBridge_InputLooksLikeURL`
- 改进启发式: TLD 白名单

### BH-023: OWLWebContentView → test-only
- GN `testonly = true`
- 移除 CALayerHost placeholder
- 注释说明生产路径用 OWLRemoteLayerView

### BH-028: AgentTask 状态机
- 新增 `startTask:` (Pending → Running)
- 当前为 UI mock 层补全

## Acceptance Criteria
- [ ] GTest: `C++` / `a=1&b=2` 正确编码
- [ ] GTest: 错误线程调用触发断言
- [ ] GTest + Swift: `1.0.0` / `localhost:8080` / IP 正确识别
- [ ] GTest: AgentTask Pending → Running → Completed
- [ ] 新增测试 ≥ 8

## 技术方案

### BH-013: URL 编码
**现状**: `OWLAddressBarController.mm` 用 `URLQueryAllowedCharacterSet` percent-encode，`+&=` 不被编码。
**方案**: 改用 `NSURLComponents`：
```objc
NSURLComponents *comp = [NSURLComponents componentsWithString:@"https://www.google.com/search"];
comp.queryItems = @[[NSURLQueryItem queryItemWithName:@"q" value:trimmed]];
return comp.URL;
```
`NSURLComponents.queryItems` 自动编码 query value 中的所有特殊字符。

### BH-015: ObjC main-thread 断言
**方案**: 在 `OWLAIChatSession` 和 `OWLBrowserMemory` 的公开方法开头添加：
```objc
NSAssert([NSThread isMainThread], @"Must be called on main thread");
```

### BH-020: inputLooksLikeURL 统一
**现状**: `OWLAddressBarController.mm` 用 `containsString:@"."` 判断，过于宽泛。
**方案**: 改进启发式 — 检查是否以 scheme:// 开头、是否是 localhost、是否包含已知 TLD（.com/.org/.net/.io 等），否则视为搜索。统一由 C-ABI `OWLBridge_InputLooksLikeURL` 处理（已有更好的逻辑）。

### BH-023: OWLWebContentView test-only
**方案**: 在 `client/BUILD.gn` 中将 `OWLWebContentView` 移到 testonly sources，添加注释说明生产用 `OWLRemoteLayerView`。删除 production 路径的 nil placeholder。

### BH-028: AgentTask 状态机
**方案**: `OWLAgentSession.mm` 新增 `startTask:` 方法：
```objc
- (void)startTask:(OWLAgentTask*)task {
  if (_destroyed) return;
  if (task.status != OWLAgentTaskStatusPending) return;
  task.status = OWLAgentTaskStatusRunning;
  if ([_delegate respondsToSelector:@selector(agentSession:taskDidChangeStatus:)])
    [_delegate agentSession:self taskDidChangeStatus:task];
}
```

## Status
- [x] Tech design
- [ ] Development
- [ ] Code review
- [ ] Tests pass
