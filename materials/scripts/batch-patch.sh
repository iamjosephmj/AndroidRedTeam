#!/usr/bin/env bash
# batch-patch.sh — Patch multiple APKs in a single run
# Usage: ./batch-patch.sh [targets_dir] [output_dir]
#
# Defaults:
#   targets_dir = ./targets/
#   output_dir  = ./patched/

set -euo pipefail

TARGETS_DIR="${1:-./targets}"
OUTPUT_DIR="${2:-./patched}"
PATCH_TOOL="${PATCH_TOOL:-./patch-tool.jar}"
WORK_DIR="./work"
REPORTS_DIR="./reports"

mkdir -p "$OUTPUT_DIR" "$WORK_DIR" "$REPORTS_DIR"

if [ ! -f "$PATCH_TOOL" ]; then
    echo "[!] patch-tool.jar not found at $PATCH_TOOL"
    echo "    Set PATCH_TOOL=/path/to/patch-tool.jar or place it in the current directory"
    exit 1
fi

APKS=$(find "$TARGETS_DIR" -name "*.apk" -type f | sort)
TOTAL=$(echo "$APKS" | grep -c "." || true)

if [ "$TOTAL" -eq 0 ]; then
    echo "[!] No APK files found in $TARGETS_DIR"
    exit 1
fi

echo "=========================================="
echo "  BATCH PATCH — $TOTAL target(s)"
echo "=========================================="
echo ""

PASS=0
FAIL=0

for apk in $APKS; do
    name=$(basename "$apk" .apk)
    echo "--- [$name] ---"

    if java -jar "$PATCH_TOOL" "$apk" \
        --out "$OUTPUT_DIR/${name}-patched.apk" \
        --work-dir "$WORK_DIR/$name" 2>&1 | tee "$REPORTS_DIR/${name}_patch.log"; then
        echo "[+] $name: PATCHED"
        ((PASS++))
    else
        echo "[!] $name: FAILED"
        ((FAIL++))
    fi
    echo ""
done

echo "=========================================="
echo "  Results: $PASS patched, $FAIL failed"
echo "  Patched APKs: $OUTPUT_DIR/"
echo "  Patch logs:   $REPORTS_DIR/"
echo "=========================================="
