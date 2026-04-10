# Phase 2: Bridge + Swift + Console 面板 UI

## 目标
- Bridge C-ABI 转发 console 消息到 Swift
- ConsoleViewModel 实现环形缓冲 + 过滤 + 搜索 + 节流
- ConsolePanelView 实现右侧面板 Console Tab

## 范围
| 文件 | 变更 |
|------|------|
| `bridge/owl_bridge_api.h/.cc` | Console callback + setter |
| `owl-client-app/ViewModels/ConsoleViewModel.swift` | 🆕 |
| `owl-client-app/Views/RightPanel/ConsolePanelView.swift` | 🆕 |
| `owl-client-app/Views/RightPanel/ConsoleRow.swift` | 🆕 |
| `owl-client-app/Views/RightPanel/RightPanelContainer.swift` | 添加 .console case |
| `owl-client-app/ViewModels/BrowserViewModel.swift` | ConsoleViewModel + callback 注册 |

## 验收标准
- [ ] Console 面板在右侧面板可打开
- [ ] console.log/warn/error 消息实时显示
- [ ] 级别过滤（All/Verbose/Info/Warning/Error）
- [ ] 文本搜索
- [ ] 消息复制（单条 + 全部）
- [ ] 清除按钮
- [ ] 保留日志开关
- [ ] 自动滚动 + 新消息按钮
- [ ] build_all.sh 通过
