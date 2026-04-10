# OWL GitHub Upload Plan

## 目标
把 `third_party/owl` 发布到 GitHub 时，只上传可复现源码与文档，不上传本地构建物、日志、内部协作元数据。

## 建议上传（白名单思路）
- `bridge/`
- `client/`
- `host/`
- `mojom/`
- `owl-client-app/App/`
- `owl-client-app/CLI/`
- `owl-client-app/Models/`
- `owl-client-app/Resources/`
- `owl-client-app/Services/`
- `owl-client-app/docs/`
- `owl-client-app/TestKit/`
- `owl-client-app/Tests/`
- `owl-client-app/UITests/`
- `owl-client-app/ViewModels/`
- `owl-client-app/Views/`
- `owl-client-app/scripts/`
- `owl-client-app/docs/`
- `owl-client-app/Package.swift`
- `owl-client-app/Package.resolved`
- `owl-client-app/project.yml`
- `owl-client-app/OWLBrowser.xcodeproj/`
- `docs/`
- `BUILD.gn`
- `.gitignore`

## 不建议上传（黑名单）
- `owl-client-app/.build/`
- `owl-client-app/build/`
- `owl-client-app/playwright/node_modules/`
- `owl-client-app/playwright/`
- `*.xcresult`, `*.profraw`, `*.log`
- `.claude/`, `.playwright-mcp/`, `feedback/`
- `CLAUDE.md`, `.flow-state.local.md`, `.flow-transcript.local.jsonl`
- `EXPORT_FILE_LIST.txt`
- `test_e2e_input.py`
- `owl-client-app/UITest/`

## 推荐导出流程（发布前）
```bash
cd /Users/xiaoyang/Project/chromium/src/third_party/owl
tools/github_export.sh
```

导出脚本支持 dry-run：
```bash
tools/github_export.sh --dry-run
```

首发分批提交顺序见：
- `docs/GITHUB_FIRST_PUSH_ORDER.md`

新增一键分批提交脚本：
```bash
tools/github_publish_batches.sh
```
支持参数：
- `--batch 1|2|3|4|5`
- `--skip-export`
- `--dry-run`

## 发布前检查
```bash
# 1) 确认没有构建垃圾
find . -type d \( -name .build -o -name build -o -name node_modules \)

# 2) 粗查敏感字符串
rg -n "OPENAI_API_KEY|TOKEN|PASSWORD|SECRET|BEGIN RSA|BEGIN OPENSSH" .
```

## 仓库边界建议
- 若要长期开源，建议将 `third_party/owl` 作为独立仓库维护。
- Chromium 主仓不建议直接镜像到 GitHub（体积过大且边界不清晰）。
