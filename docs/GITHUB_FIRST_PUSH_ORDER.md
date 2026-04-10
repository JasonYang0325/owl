# OWL 首次推送建议顺序

## 目的
减少首次 GitHub 推送风险：每批提交都可独立 review、可单独回滚。

## 分批建议（5 批）
1. `chore(repo): define github export boundary`
 - `.gitignore`
 - `.github-export-ignore`
 - `tools/github_export.sh`
 - `tools/github_publish_batches.sh`
 - `docs/GITHUB_UPLOAD_PLAN.md`
 - `docs/GITHUB_FIRST_PUSH_ORDER.md`

2. `feat(core): bridge + mojom + host/client runtime`
 - `bridge/`
 - `mojom/`
 - `host/`
 - `client/`
 - `BUILD.gn`

3. `feat(app): owl-client-app main sources`
 - `owl-client-app/App/`
 - `owl-client-app/CLI/`
 - `owl-client-app/Models/`
 - `owl-client-app/Resources/`
 - `owl-client-app/Services/`
 - `owl-client-app/docs/`
 - `owl-client-app/ViewModels/`
 - `owl-client-app/Views/`
 - `owl-client-app/Package.swift`
 - `owl-client-app/Package.resolved`
 - `owl-client-app/project.yml`
 - `owl-client-app/OWLBrowser.xcodeproj/`
 - `owl-client-app/OWLBrowser.entitlements`

4. `test(harness): tests + scripts`
 - `owl-client-app/TestKit/`
 - `owl-client-app/Tests/`
 - `owl-client-app/UITests/`
 - `owl-client-app/scripts/`
 - `docs/TESTING.md`
 - `docs/TESTING-ROADMAP.md`

5. `docs: architecture and phase docs`
 - `docs/` 其余文档

## 推送前命令
```bash
cd /Users/xiaoyang/Project/chromium/src/third_party/owl
tools/github_export.sh
cd /tmp/owl-github-export
git init
git checkout -b main
```

## 一键执行脚本（推荐）
`tools/github_publish_batches.sh` 将完成导出与分批提交，可选只跑某一批：
```bash
cd /Users/xiaoyang/Project/chromium/src/third_party/owl
tools/github_publish_batches.sh
```

示例：
```bash
tools/github_publish_batches.sh --batch 2                    # 只做第 2 批
tools/github_publish_batches.sh --dry-run                     # 预演所有命令
tools/github_publish_batches.sh --skip-export --batch 4        # 已导出时，提交第 4 批
```

## 每批提交模板
```bash
git add <batch-paths>
git commit -m "<message>"
```

## 最后检查
```bash
git status
git log --oneline --decorate -n 10
rg -n "OPENAI_API_KEY|TOKEN|PASSWORD|SECRET|BEGIN RSA|BEGIN OPENSSH" .
```
