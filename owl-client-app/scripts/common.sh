#!/bin/bash
# OWL Browser — shared script configuration
CHROMIUM_SRC="${CHROMIUM_SRC:-/Users/xiaoyang/Project/chromium/src}"
BUILD_DIR="${OWL_HOST_DIR:-$CHROMIUM_SRC/out/owl-host}"
export PATH="$CHROMIUM_SRC/third_party/depot_tools:$PATH"

# autoninja with fallback
if command -v autoninja &>/dev/null && autoninja --version &>/dev/null 2>&1; then
  NINJA="autoninja"
else
  NINJA="ninja"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'
