# Phase E — XCUITest 原生 Shell 测试（开发者账号签名）

**版本**: v3.0 — 2026-03-30（Round 2 评审修复）
**状态**: Round 3 验证中

---

## 背景

OWL Browser 已有 `UITests/OWLBrowserUITests.swift`（6 个测试），但无法运行，因为：

1. XCUITest 要求 app + test runner bundle 用**同一 Team ID** 签名
2. 当前全部是 ad-hoc（`codesign --sign -`），library validation 拒绝
3. `OWLBrowser.entitlements` 为空，缺少 `get-task-allow`（test runner 需要此权限 attach 到 app）

---

## 现有文件清单

| 文件 | 当前状态 |
|------|---------|
| `UITests/OWLBrowserUITests.swift` | 6 个测试，已写好 |
| `UITests/UITests.entitlements` | 有 `get-task-allow` ✓ |
| `OWLBrowser.entitlements` | 空 dict |
| `project.yml` | 主 app 无显式签名；UITest target 禁用签名 |
| Post-build script | `codesign --sign -`（ad-hoc）+ `--deep`（已废弃） |
| `out/owl-host/*.dylib` | 474 个 Chromium dylib，ad-hoc 签名 |
| `out/owl-host/OWLBridge.framework` | ad-hoc 签名 |
| `out/owl-host/OWL Host.app` | 独立子进程，ad-hoc 签名 |

---

## 技术方案 v2

### 1. 架构设计

#### XCUITest 签名链路（修正后）

```
xcodebuild test
  ├─ OWLBrowser.app                    ← Apple Development (Team T) + get-task-allow
  │   └─ Frameworks/
  │       ├─ OWLBridge.framework       ← 必须签名（$EXPANDED_CODE_SIGN_IDENTITY）
  │       │   └─ OWLBridge (binary)    ← 先签 binary，再签 framework bundle
  │       └─ lib*.dylib × 474         ← 逐个签名（$EXPANDED_CODE_SIGN_IDENTITY 或 ad-hoc，HARDENED_RUNTIME OFF 时均可）
  └─ OWLBrowserUITests.xctest          ← Apple Development (Team T)，同 Team ID

out/owl-host/OWL Host.app              ← 独立子进程，不在 app bundle 内
                                          ad-hoc 签名即可（本地开发模式）
```

**关键设计决策一览：**

| 决策 | 选择 | 理由 |
|------|------|------|
| Hardened Runtime | OFF | 474 个 Chromium dylib 无法全部用 developer cert 重签；OFF 时 library validation 也关闭，ad-hoc dylib 可加载 |
| 474 dylib 签名 | `$EXPANDED_CODE_SIGN_IDENTITY`（fallback `-`） | post-build script 动态复制，无法用 Xcode copyFiles；使用 Xcode 展开的 cert hash 保持一致性 |
| Host.app 签名 | ad-hoc（不重签） | Host 是外部子进程，不受 OWLBrowser.app bundle 签名约束；本地开发无 Gatekeeper 拦截 |
| Team ID | `CODE_SIGN_STYLE: Automatic` + 命令行 `DEVELOPMENT_TEAM=` 覆盖 | 不硬编码，开发者换机器无需改代码 |

#### 为什么 resign_for_testing.sh 只需针对 Host.app？

- `OWLBridge.framework` 和 474 个 dylib：由 Xcode post-build script 在每次 build 时自动复制并签名到 app bundle，不需要外部脚本
- `OWL Host.app`：独立路径（`out/owl-host/`），不被 Xcode post-build 处理；但 ad-hoc 签名已足够本地运行，resign 脚本是**可选的**（仅当 macOS 拒绝加载 ad-hoc Host 时使用）

### 2. 文件变更清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `OWLBrowser.entitlements` | 修改 | 加 `get-task-allow` |
| `project.yml` | 修改 | 主 app + UITest target 签名；修复 post-build 脚本签名顺序 |
| `scripts/resign_for_testing.sh` | 新增 | 可选：对 Host.app 重签（无 --deep，无 --entitlements） |
| `CLAUDE.md` | 修改 | 补充 Phase E 命令 |

### 3. 核心变更详情

#### 3.1 OWLBrowser.entitlements

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.get-task-allow</key>
    <true/>
</dict>
</plist>
```

`get-task-allow` 必须在**被测 app**（OWLBrowser.app）的 entitlements 中，允许 test runner 通过 `task_for_pid()` attach。

> ⚠️ Xcode Automatic Signing 会在这个基础上注入 `com.apple.application-identifier` 和 `com.apple.developer.team-identifier`。resign 脚本中**不能**用这个裸文件重签 Host.app（会破坏 Host 的完整 entitlements）。

#### 3.2 project.yml — OWLBrowser target

```yaml
targets:
  OWLBrowser:
    type: application
    platform: macOS
    sources:
      - path: App
      - path: ViewModels
      - path: Views
      - path: Services
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.antlerai.owl.browser
        GENERATE_INFOPLIST_FILE: YES
        CODE_SIGN_ENTITLEMENTS: OWLBrowser.entitlements
        CODE_SIGN_STYLE: Automatic          # ← 新增
        CODE_SIGN_IDENTITY: "Apple Development"  # ← 新增
        DEVELOPMENT_TEAM: ""               # ← 新增，留空；xcodebuild 时用 DEVELOPMENT_TEAM=xxx 覆盖
        CODE_SIGNING_REQUIRED: YES         # ← 新增
        CODE_SIGNING_ALLOWED: YES          # ← 新增
        ENABLE_HARDENED_RUNTIME: "NO"      # ← 新增（仅 UITest 配置）
        FRAMEWORK_SEARCH_PATHS: /Users/xiaoyang/Project/chromium/src/out/owl-host
        LD_RUNPATH_SEARCH_PATHS: "@executable_path/../Frameworks /Users/xiaoyang/Project/chromium/src/out/owl-host"
        OTHER_SWIFT_FLAGS: "-F/Users/xiaoyang/Project/chromium/src/out/owl-host"
        OTHER_LDFLAGS:
          - "-F/Users/xiaoyang/Project/chromium/src/out/owl-host"
          - "-framework"
          - "OWLBridge"
    entitlements:
      path: OWLBrowser.entitlements
    postBuildScripts:
      - name: "Embed OWLBridge + Chromium dylibs"
        script: |
          OWL_HOST_DIR="/Users/xiaoyang/Project/chromium/src/out/owl-host"
          FRAMEWORK_DST="${BUILT_PRODUCTS_DIR}/${FRAMEWORKS_FOLDER_PATH}"
          mkdir -p "$FRAMEWORK_DST"

          # Resolve signing identity: use Xcode-expanded cert hash (developer build),
          # fall back to ad-hoc (-) if not available.
          SIGN_ID="${EXPANDED_CODE_SIGN_IDENTITY:--}"
          if [ -z "$EXPANDED_CODE_SIGN_IDENTITY" ]; then
            echo "warning: EXPANDED_CODE_SIGN_IDENTITY is empty, using ad-hoc signing" >&2
          fi

          # 1. Copy + sign each dylib individually (no --deep: deprecated, skips bare dylibs)
          # Note: cp stderr suppressed (some dylibs may not exist); codesign errors NOT suppressed
          for dylib in "$OWL_HOST_DIR"/lib*.dylib; do
            cp "$dylib" "$FRAMEWORK_DST/" 2>/dev/null || true
            codesign --force --sign "$SIGN_ID" "$FRAMEWORK_DST/$(basename "$dylib")" || \
              echo "warning: failed to sign $(basename "$dylib")" >&2
          done

          # 2. Copy OWLBridge.framework, sign binary first (deterministic path), then bundle
          cp -R "$OWL_HOST_DIR/OWLBridge.framework" "$FRAMEWORK_DST/"
          FW="$FRAMEWORK_DST/OWLBridge.framework"
          # Use deterministic symlink path (OWLBridge.framework/OWLBridge → Versions/Current/OWLBridge)
          FW_BIN="$FW/OWLBridge"
          if [ ! -f "$FW_BIN" ]; then
            echo "error: OWLBridge binary not found at $FW_BIN" >&2
            exit 1
          fi
          codesign --force --sign "$SIGN_ID" "$FW_BIN"
          # Then sign the framework bundle
          codesign --force --sign "$SIGN_ID" "$FW"
```

#### 3.3 project.yml — OWLBrowserUITests target

```yaml
  OWLBrowserUITests:
    type: bundle.ui-testing
    platform: macOS
    sources:
      - path: UITests
        excludes:
          - "**/*.entitlements"
    dependencies:
      - target: OWLBrowser
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.antlerai.owl.browser.uitests
        GENERATE_INFOPLIST_FILE: YES
        CODE_SIGN_STYLE: Automatic          # ← 改：从禁用签名改为自动签名
        CODE_SIGN_IDENTITY: "Apple Development"  # ← 改
        DEVELOPMENT_TEAM: ""               # ← 新增
        CODE_SIGNING_REQUIRED: YES         # ← 改：从 NO 改为 YES
        CODE_SIGNING_ALLOWED: YES          # ← 改：从 NO 改为 YES
        ENABLE_HARDENED_RUNTIME: "NO"      # ← 保留
        CODE_SIGN_ENTITLEMENTS: UITests/UITests.entitlements  # ← 新增（引用已存在的文件）
        FRAMEWORK_SEARCH_PATHS: ""
        OTHER_LDFLAGS: ""
        OTHER_SWIFT_FLAGS: ""
```

#### 3.4 scripts/resign_for_testing.sh（可选，仅 Host.app）

```bash
#!/bin/bash
# resign_for_testing.sh — 可选：对 OWL Host.app 用 developer cert 重新签名
# 仅在 macOS 拒绝加载 ad-hoc signed Host.app 时需要执行
#
# Usage: ./scripts/resign_for_testing.sh [TEAM_ID]
#   TEAM_ID: 可选，用于过滤匹配正确的证书

set -e
cd "$(dirname "$0")/.."
BUILD_DIR="${OWL_HOST_DIR:-/Users/xiaoyang/Project/chromium/src/out/owl-host}"
HOST_APP="$BUILD_DIR/OWL Host.app"

if [ ! -d "$HOST_APP" ]; then
    echo "ERROR: Host.app not found at: $HOST_APP"
    exit 1
fi

# Find signing identity, optionally filtered by Team ID
if [ -n "$1" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning | \
              grep "Apple Development.*$1" | head -1 | awk '{print $2}')
else
    SIGN_ID=$(security find-identity -v -p codesigning | \
              grep "Apple Development" | head -1 | awk '{print $2}')
fi

if [ -z "$SIGN_ID" ]; then
    echo "ERROR: No 'Apple Development' certificate found."
    echo "  Open Xcode → Settings → Accounts → Manage Certificates → + → Apple Development"
    exit 1
fi
echo "Signing identity: $SIGN_ID"
echo "Host.app: $HOST_APP"

# NOTE: Do NOT use --deep (deprecated, skips bare dylibs).
# NOTE: Do NOT pass --entitlements (Host is a separate process, not OWLBrowser's entitlements).
# Host.app only needs a valid developer signature to satisfy macOS process launch checks.
codesign --force --sign "$SIGN_ID" "$HOST_APP"

echo "Done: OWL Host.app re-signed."
```

### 4. 前置步骤（手动，一次性）

```
Xcode → Settings (Cmd+,) → Accounts → + → 登录 Apple ID
→ 选择 Team → Manage Certificates → + → Apple Development
→ Xcode 自动生成并安装证书到 Keychain
```

验证：
```bash
security find-identity -v -p codesigning | grep "Apple Development"
# 输出: 1) ABCD1234EF... "Apple Development: Your Name (TEAMIDHERE)"
```

### 5. 完整运行命令

```bash
# 获取 Team ID（证书安装后）
TEAM_ID=$(security find-identity -v -p codesigning | grep "Apple Development" \
          | sed 's/.*(\(.*\))/\1/' | head -1)
echo "Team ID: $TEAM_ID"

# 重新生成 Xcode project
cd /Users/xiaoyang/Project/chromium/src/third_party/owl/owl-client-app
xcodegen generate

# 运行 XCUITest（加 -allowProvisioningUpdates 允许自动下载 provisioning profile）
xcodebuild test \
  -project OWLBrowser.xcodeproj \
  -scheme OWLBrowserUITests \
  -destination 'platform=macOS' \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  2>&1 | grep -E "Test Case|passed|failed|error:"

# 如果 Host.app 被 macOS 拒绝（罕见），再执行：
# ./scripts/resign_for_testing.sh "$TEAM_ID"
```

### 6. 测试策略

| 测试 | 验证点 |
|------|--------|
| `testNavigateViaAddressBar` | 地址栏输入 + 回车 → 页面加载 |
| `testSearchFromAddressBar` | 搜索 query → 导航 |
| `testTypeInWebContent` | 点击 web 内容区 + 键盘输入 |
| `testClickInWebContent` | 鼠标点击链接 → 导航 |
| `testNavigateTwice` | 二次导航不崩溃 |
| `testTabKeyStaysInWebContent` | Tab 键被 web content 拦截 |

### 7. 风险 & 缓解

| 风险 | 可能性 | 缓解 |
|------|--------|------|
| Gatekeeper 拒绝 Host.app | 低（本地开发） | 运行 `resign_for_testing.sh $TEAM_ID` |
| `EXPANDED_CODE_SIGN_IDENTITY` 为空 | 低 | post-build 脚本有 fallback ad-hoc + warning |
| provisioning profile 未缓存 | 中（首次/CI） | `xcodebuild -allowProvisioningUpdates` |
| 网络测试不稳定 | 中 | 测试有 sleep buffer；可重跑 |
| 多 Apple Development 证书 | 低 | resign 脚本支持 Team ID 过滤参数 |

> ⚠️ `ENABLE_HARDENED_RUNTIME: NO` 仅用于本地 UITest 开发配置。Distribution/Release scheme 必须保持 Hardened Runtime ON（App Store 审核要求）。

---

## 实施状态

| 步骤 | 状态 |
|------|------|
| 技术方案 v1 | ✅ 完成 |
| Round 1 评审 | ✅ 完成（3 个 P0/P1 修复） |
| 技术方案 v2 | ✅ 更新 |
| Round 2 评审 | 进行中 |
| 实施 | 待开始 |
