# OWL

This repository contains the exported `third_party/owl` codebase from Chromium, extracted as an independent open repository with its runtime core and Swift client.

## Goal
Provide a browser bridge stack (Chromium host / Swift client) with an end-to-end testing baseline and maintenance workflow.

## Repo Layout
- `bridge/` Chromium bridge layer
- `client/` Swift/C++ client bindings and shared logic
- `host/` Host-side Chromium runtime and feature implementation
- `mojom/` Cross-process interfaces
- `owl-client-app/` macOS Swift application, CLI bridge, views, tests, scripts
- `docs/` architecture, design, PRD, milestones, testing documentation
- `tools/` export and publishing scripts for GitHub upload
- `BUILD.gn` top-level build target entry for Chromium build integration

## Quick Start
### 1) Run app from source
Open
- `owl-client-app/OWLBrowser.xcodeproj`

### 2) Run CLI/automation tasks
- `cd owl-client-app`
- `./scripts/run_tests.sh`
- `./scripts/run_cli.sh` (for CLI checks when present)

### 3) Use test harness
- Unit/integration/UITest cases are under `owl-client-app/Tests`, `owl-client-app/TestKit`, and `owl-client-app/UITests`
- See
  - `docs/TESTING.md`
  - `docs/TESTING-ROADMAP.md`

## GitHub 发布与更新
This project uses a scripted split-commit publish flow:

- `tools/github_export.sh` — create public export snapshot
- `tools/github_publish_batches.sh` — 5-batch commit template for first push / incremental uploads

Run:
```bash
cd /path/to/third_party/owl
tools/github_publish_batches.sh
```

## Recommended Local Ignored Files
See `.github-export-ignore` and `.gitignore`.

## References
- `docs/ARCHITECTURE.md`
- `docs/CONVENTIONS.md`
- `docs/GITHUB_UPLOAD_PLAN.md`
- `docs/GITHUB_FIRST_PUSH_ORDER.md`
