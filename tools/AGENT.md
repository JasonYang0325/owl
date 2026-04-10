# AGENT — Tools 目录

## 职责

发布、导出和工程维护脚本集中地。

## 常用入口

- `tools/github_export.sh`：从 Chromium 提交树导出公开快照。
- `tools/github_publish_batches.sh`：分批提交到 GitHub。
- `tools/setup_repo_*`：环境与任务协作相关脚本（按文件名说明）。

## 质量规则

- 发布前先核对 `docs/GITHUB_UPLOAD_PLAN.md`。
- 改导出脚本后执行 `shellcheck`/基础执行冒烟。
- 确保 `.github-export-ignore` 与 `README.md` 与发布动作一致。
