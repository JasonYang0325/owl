#!/bin/bash
# resign_for_testing.sh — Optional: re-sign OWL Host.app with developer cert.
#
# OWL Host.app is a standalone subprocess launched from OWLBridge via posix_spawn.
# It lives outside the OWLBrowser.app bundle so Xcode's post-build signing doesn't cover it.
# For local development, ad-hoc signing is usually sufficient. Run this script only if macOS
# refuses to launch the Host subprocess (rare outside of distribution builds).
#
# Usage: ./scripts/resign_for_testing.sh [TEAM_ID]
#   TEAM_ID: optional — filters to the certificate matching this team.
#             If omitted, uses the first available Apple Development certificate.
#
# Example: ./scripts/resign_for_testing.sh 25S5LV8GU9

set -e
cd "$(dirname "$0")/.."
BUILD_DIR="${OWL_HOST_DIR:-/Users/xiaoyang/Project/chromium/src/out/owl-host}"
HOST_APP="$BUILD_DIR/OWL Host.app"

if [ ! -d "$HOST_APP" ]; then
    echo "ERROR: Host.app not found at: $HOST_APP"
    echo "  Build with: autoninja -C out/owl-host owl_host_app"
    exit 1
fi

# Locate signing identity, optionally filtered by Team ID
TEAM_FILTER="${1:-}"
if [ -n "$TEAM_FILTER" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning | \
              grep "Apple Development.*$TEAM_FILTER" | head -1 | awk '{print $2}')
else
    SIGN_ID=$(security find-identity -v -p codesigning | \
              grep "Apple Development" | head -1 | awk '{print $2}')
fi

if [ -z "$SIGN_ID" ]; then
    echo "ERROR: No valid 'Apple Development' certificate found."
    echo "  Open Xcode → Settings → Accounts → Manage Certificates → + → Apple Development"
    exit 1
fi

echo "Signing identity : $SIGN_ID"
echo "Host.app         : $HOST_APP"

# Sign Host.app without --deep (deprecated) and without --entitlements.
# Host is a separate process; it does not need get-task-allow (that belongs to OWLBrowser.app).
codesign --force --sign "$SIGN_ID" "$HOST_APP"

echo "Done."
