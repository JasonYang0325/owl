# OWL Browser Architecture

## 全栈分层

```
┌─────────────────────────────────┐
│  SwiftUI Views                  │  owl-client-app/Views/
│  ViewModels                     │  owl-client-app/ViewModels/
│  Services (Swift)               │  owl-client-app/Services/
├─────────────────────────────────┤
│  OWLBridge.framework (C-ABI)    │  bridge/
├─────────────────────────────────┤
│  Mojo IPC                       │  mojom/
├─────────────────────────────────┤
│  ObjC++ Client Components       │  client/
│  (TabManager, InputTranslator)  │
├─────────────────────────────────┤
│  C++ Host Process               │  host/
│  (BrowserImpl, WebContents,     │
│   HistoryService, BookmarkService)│
├─────────────────────────────────┤
│  Chromium Content Layer         │  (upstream)
└─────────────────────────────────┘
```

## 目录职责

| 目录 | 语言 | 构建系统 | 职责 |
|------|------|---------|------|
| `owl-client-app/` | Swift | SPM | SwiftUI 前端 |
| `bridge/` | ObjC++ | GN → framework | C-ABI 桥接层 |
| `client/` | ObjC++ | GN | 客户端组件 |
| `host/` | C++ | GN | Host 子进程 |
| `mojom/` | Mojom IDL | GN | IPC 接口定义 |

## SPM Target 结构

```
OWLBrowserLib (library)     → Views + ViewModels + Services
OWLBrowser (executable)     → @main 入口，依赖 OWLBrowserLib
OWLTestKit (library)        → 共享测试工具，依赖 OWLBrowserLib
OWLUITest (executable)      → CGEvent 系统级测试
OWLBrowserTests (test)      → Pipeline 集成测试（需 Host）
OWLUnitTests (test)         → ViewModel 单元测试（不需 Host）
OWLIntegrationTests (test)  → 跨层集成测试（真实 C-ABI → Mojo → Host → Renderer）
```

## 数据流

新增全栈功能的典型路径：

1. **Mojom** — 定义 IPC 接口（`mojom/*.mojom`）
2. **Host C++** — 实现服务逻辑（`host/owl_*.cc`）
3. **Bridge C-ABI** — 暴露 C 函数（`bridge/owl_bridge_api.h`）
4. **Swift Service** — 封装异步调用（`Services/*.swift`）
5. **ViewModel** — 状态管理 + MockConfig（`ViewModels/*.swift`）
6. **SwiftUI View** — UI 展示（`Views/*.swift`）

参考实现：BookmarkService（已完成）、HistoryService（已完成）
