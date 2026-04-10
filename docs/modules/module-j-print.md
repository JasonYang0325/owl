# Module J: 打印支持

| 属性 | 值 |
|------|-----|
| 优先级 | P3 |
| 依赖 | 无 |
| 预估规模 | ~300 行 |
| 状态 | pending |

## 目标

支持 Cmd+P 打印当前页面，以及另存为 PDF。

## 用户故事

As a 浏览器用户, I want 打印网页或保存为 PDF, so that 我可以获取页面的离线副本。

## 验收标准

- AC-001: Cmd+P 触发打印流程
- AC-002: 可选择打印到打印机或保存为 PDF
- AC-003: 打印预览显示正确的页面内容
- AC-004: Cmd+Shift+P 或菜单可直接另存为 PDF

## 技术方案

### 层级分解

#### 1. Host C++

两种路径：
- **路径 A**（简单）：`content::WebContents::Print()` + 系统打印对话框
- **路径 B**（PDF 导出）：`HeadlessWebContents::PrintToPDF()` 或 DevTools Protocol 的 `Page.printToPDF`

推荐路径 A 作为 MVP：
```cpp
void OWLWebContents::PrintPage(PrintPageCallback callback) {
  if (g_real_print_func) {
    g_real_print_func(std::move(callback));
  } else {
    std::move(callback).Run(false);
  }
}
```

real 实现调用 `content::WebContents::Print()`。

#### 2. Mojom（扩展 `web_view.mojom`）

```
interface WebViewHost {
  // ... existing ...
  PrintPage() => (bool success);
  ExportPDF(string output_path) => (bool success);
};
```

#### 3. Bridge C-ABI

```c
OWL_EXPORT void OWLBridge_PrintPage(OWLBridge_BoolCallback cb, void* ctx);
OWL_EXPORT void OWLBridge_ExportPDF(const char* path, OWLBridge_BoolCallback cb, void* ctx);
```

#### 4. Swift

- `OWLShortcutManager` 或 SwiftUI `.keyboardShortcut` 添加 Cmd+P
- PDF 导出使用 NSSavePanel 选择路径

## 测试计划

| 层级 | 测试内容 |
|------|---------|
| C++ GTest | PrintPage stub/real 分发 |
| E2E Pipeline | 调用 ExportPDF → 验证文件生成 |

## 文件清单

| 操作 | 文件 |
|------|------|
| 修改 | `mojom/web_view.mojom`（PrintPage + ExportPDF） |
| 修改 | `host/owl_web_contents.h/.cc` |
| 修改 | `host/owl_real_web_contents.mm` |
| 修改 | `bridge/owl_bridge_api.h/.cc` |
| 修改 | `owl-client-app/Views/BrowserWindow.swift`（Cmd+P 快捷键） |
| 修改 | `client/OWLShortcutManager.mm`（Print action） |
