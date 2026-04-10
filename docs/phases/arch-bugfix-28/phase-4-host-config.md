# Phase 4: Host 配置与安全 (BH-007, BH-017, BH-021)

## Goal
修复数据路径安全、权限持久化性能和 JS 执行安全。

## Scope
- **Modified**: `host/owl_content_browser_context.cc`, `host/owl_permission_manager.cc`, `host/owl_web_contents.cc`, unittest files
- **Layers**: Host

## Dependencies
- BH-007 should be done before/alongside Phase 2 BH-005 (unified data path)

## Items

### BH-007: 数据路径 → user-data-dir
- `OWLContentBrowserContext` 使用 `--user-data-dir` 命令行参数
- 权限 0700
- GTest in `base::ScopedTempDir`

### BH-017: PermissionManager 异步持久化
- UI 线程 snapshot 权限数据
- PostTask 到 file_task_runner_ 后台写入
- temp file + rename 原子写

### BH-021: EvaluateJavaScript 安全
- 移除 `OWL_ENABLE_TEST_JS` 环境变量检查
- 仅保留 `--enable-owl-test-js` 命令行开关

## Acceptance Criteria
- [ ] GTest: 路径来自命令行参数且权限 0700
- [ ] GTest: 异步写入完成且文件完整
- [ ] GTest: 无命令行开关时 JS 执行被拒绝
- [ ] 新增测试 ≥ 4

## 技术方案

### BH-007: OWLContentBrowserContext 数据路径
**现状**: `path_` 硬编码为 `base::DIR_TEMP/OWLBrowserData`（`/tmp/OWLBrowserData`），世界可读。
**方案**:
1. 从 `base::CommandLine` 读取 `--user-data-dir`
2. 若无参数，fallback 到 `~/Library/Application Support/OWLBrowser/`（macOS 标准路径）
3. `base::CreateDirectoryAndGetError` 创建目录，权限 0700
4. 不再使用 `base::DIR_TEMP`

### BH-017: PermissionManager 异步持久化
**现状**: `PersistNow()` 在 UI 线程同步 `base::WriteFile()`。
**方案**:
1. `PersistNow()` 在 UI 线程序列化权限数据为 JSON string（snapshot）
2. PostTask snapshot 到 `base::ThreadPool::CreateSequencedTaskRunner` 后台写
3. 后台写用 temp file + `base::Move(temp, target)` 原子替换
4. ResetAll() 只调一次 PersistNow()（批量修改完后）

### BH-021: EvaluateJavaScript 安全
**现状**: 检查环境变量 `OWL_ENABLE_TEST_JS` 或命令行 `--enable-owl-test-js`。
**方案**: 删除环境变量检查，仅保留命令行开关。

### 文件变更清单
| 文件 | 说明 |
|------|------|
| `host/owl_content_browser_context.cc` | BH-007 路径改为 --user-data-dir |
| `host/owl_permission_manager.cc` | BH-017 异步写 |
| `host/owl_permission_manager.h` | BH-017 添加 file_task_runner_ 成员 |
| `host/owl_web_contents.cc` | BH-021 删除环境变量检查 |
| unittest files | 新增测试 |

## Status
- [x] Tech design
- [ ] Development
- [ ] Code review
- [ ] Tests pass
