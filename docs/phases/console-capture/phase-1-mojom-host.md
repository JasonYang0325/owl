# Phase 1: Mojom + Host Console 捕获

## 目标
- 在 Host C++ 层通过 OnDidAddMessageToConsole 捕获 console 消息
- Mojom 定义 ConsoleLevel + ConsoleMessage + OnConsoleMessage
- GTest 验证级别映射

## 范围
| 文件 | 变更 |
|------|------|
| `mojom/web_view.mojom` | ConsoleLevel enum + ConsoleMessage struct + OnConsoleMessage |
| `host/owl_real_web_contents.mm` | OnDidAddMessageToConsole 回调 |
| 所有 Observer 实现 | OnConsoleMessage 空 stub |

## 技术要点
- Chromium API: `OnDidAddMessageToConsole(RenderFrameHost*, log_level, message, line_no, source_id, untrusted_stack_trace)`
- 主帧过滤: `source_frame->IsInPrimaryMainFrame()`
- 消息截断: message + stack_trace 合并后截断至 10KB
- timestamp: `base::Time::Now().InSecondsFSinceUnixEpoch()`
- 级别映射: kVerbose→0, kInfo→1, kWarning→2, kError→3

## 验收标准
- [ ] Mojom 编译通过
- [ ] console.log/warn/error 触发 OnConsoleMessage（仅主帧）
- [ ] 级别映射正确
- [ ] 消息截断 10KB
- [ ] timestamp 非零
- [ ] 现有测试不回归
