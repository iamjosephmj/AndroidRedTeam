#!/bin/bash
# Lab Health Check — verify all required tools are installed and working.
# Run from the project root (where patch-tool.jar lives).
#
# Usage: ./lab-health-check.sh

set -uo pipefail

PASS=0
FAIL=0

check() {
  local label="$1"
  local cmd="$2"
  local result
  result=$(eval "$cmd" 2>&1) || true
  if [ -n "$result" ] && ! echo "$result" | grep -qi "not found\|error\|no such"; then
    echo "[PASS] $label: $result"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] $label: not found or error"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Lab Health Check ==="
echo ""

check "Java" "java -version 2>&1 | head -1"
check "ADB" "adb version 2>&1 | head -1"
check "Emulator" "emulator -version 2>&1 | head -1"
check "apktool" "apktool --version 2>&1 | head -1"

# patch-tool — check from project root
if [ -f "patch-tool.jar" ]; then
  PT_RESULT=$(java -jar patch-tool.jar --help 2>&1 | head -1)
  echo "[PASS] patch-tool: $PT_RESULT"
  PASS=$((PASS + 1))
else
  echo "[FAIL] patch-tool: patch-tool.jar not found in current directory"
  FAIL=$((FAIL + 1))
fi

# Connected devices
DEVICE_COUNT=$(adb devices 2>/dev/null | grep -c 'device$' || echo 0)
if [ "$DEVICE_COUNT" -gt 0 ]; then
  echo "[PASS] Devices: $DEVICE_COUNT connected"
  PASS=$((PASS + 1))
else
  echo "[FAIL] Devices: none connected (start emulator or connect device)"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && echo "Lab is ready." || echo "Fix the failures above before proceeding."
