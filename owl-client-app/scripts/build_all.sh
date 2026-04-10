#!/bin/bash
# Build all OWL components: Host (C++ GN) + Bridge Framework + Client (Swift SPM)
set +e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../.."

source "$SCRIPT_DIR/common.sh"

echo -e "${CYAN}=== OWL Build All ===${NC}"

# Step 1: Host app (C++ via GN/ninja)
echo -e "${CYAN}[1/3] Building Host ($NINJA)...${NC}"
output=$("$NINJA" -C "$BUILD_DIR" owl_host_app 2>&1)
rc=$?
echo "$output" | tail -3
if [ $rc -ne 0 ]; then
    echo "$output"
    echo -e "${RED}FAIL: Host build failed${NC}"
    exit 1
fi
echo -e "${GREEN}  Host: OK${NC}"

# Step 2: OWLBridge.framework
echo -e "${CYAN}[2/3] Building OWLBridge.framework ($NINJA)...${NC}"
output=$("$NINJA" -C "$BUILD_DIR" OWLBridge.framework 2>&1)
rc=$?
echo "$output" | tail -3
if [ $rc -ne 0 ]; then
    echo "$output"
    echo -e "${RED}FAIL: OWLBridge.framework build failed${NC}"
    exit 1
fi
echo -e "${GREEN}  OWLBridge: OK${NC}"

# Step 3: Swift client (SPM)
echo -e "${CYAN}[3/3] Building Swift client (SPM)...${NC}"
cd owl-client-app
output=$(swift build 2>&1)
rc=$?
echo "$output" | tail -3
if [ $rc -ne 0 ]; then
    echo "$output"
    echo -e "${RED}FAIL: Swift build failed${NC}"
    exit 1
fi
echo -e "${GREEN}  Swift: OK${NC}"

echo -e "${GREEN}=== Build complete ===${NC}"
