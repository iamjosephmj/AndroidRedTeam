#!/usr/bin/env bash
# batch-deploy.sh — Deploy multiple patched APKs to an emulator/device
# Usage: ./batch-deploy.sh [patched_dir] [payloads_dir]
#
# For each patched APK:
#   1. Extracts package name
#   2. Uninstalls previous version
#   3. Installs the patched APK
#   4. Grants permissions
#   5. Pushes payloads (frames, location, sensor)
#   6. Launches the app
#   7. Waits for injection to activate
#   8. Captures delivery log
#   9. Stops the app

set -euo pipefail

PATCHED_DIR="${1:-./patched}"
PAYLOADS_DIR="${2:-./materials/payloads}"
LOGS_DIR="./delivery-logs"
WAIT_SECONDS=10

mkdir -p "$LOGS_DIR"

# Check adb connectivity
if ! adb devices 2>/dev/null | grep -q "device$"; then
    echo "[!] No device/emulator connected. Run 'adb devices' to check."
    exit 1
fi

APKS=$(find "$PATCHED_DIR" -name "*-patched.apk" -type f | sort)
TOTAL=$(echo "$APKS" | grep -c "." || true)

if [ "$TOTAL" -eq 0 ]; then
    echo "[!] No patched APKs found in $PATCHED_DIR"
    exit 1
fi

echo "=========================================="
echo "  BATCH DEPLOY — $TOTAL target(s)"
echo "=========================================="
echo ""

get_package_name() {
    local apk="$1"
    # Try aapt2 first, fall back to aapt
    if command -v aapt2 &>/dev/null; then
        aapt2 dump badging "$apk" 2>/dev/null | grep "package:" | sed "s/.*name='//" | sed "s/'.*//"
    elif command -v aapt &>/dev/null; then
        aapt dump badging "$apk" 2>/dev/null | grep "package:" | sed "s/.*name='//" | sed "s/'.*//"
    else
        echo ""
    fi
}

PASS=0
FAIL=0

for apk in $APKS; do
    name=$(basename "$apk" .apk | sed 's/-patched$//')
    echo "--- [$name] ---"

    # Extract package name
    PKG=$(get_package_name "$apk")
    if [ -z "$PKG" ]; then
        echo "[!] Could not determine package name for $apk — skipping"
        ((FAIL++))
        continue
    fi
    echo "  Package: $PKG"

    # Uninstall previous
    adb uninstall "$PKG" 2>/dev/null || true

    # Install
    if ! adb install -r "$apk" 2>/dev/null; then
        echo "[!] Install failed for $name"
        ((FAIL++))
        continue
    fi

    # Grant permissions
    adb shell pm grant "$PKG" android.permission.CAMERA 2>/dev/null || true
    adb shell pm grant "$PKG" android.permission.ACCESS_FINE_LOCATION 2>/dev/null || true
    adb shell pm grant "$PKG" android.permission.ACCESS_COARSE_LOCATION 2>/dev/null || true
    adb shell pm grant "$PKG" android.permission.READ_EXTERNAL_STORAGE 2>/dev/null || true
    adb shell pm grant "$PKG" android.permission.WRITE_EXTERNAL_STORAGE 2>/dev/null || true
    adb shell appops set "$PKG" MANAGE_EXTERNAL_STORAGE allow 2>/dev/null || true

    # Clear previous payloads
    adb shell rm -rf /sdcard/poc_frames/* /sdcard/poc_location/* /sdcard/poc_sensor/* 2>/dev/null || true

    # Push payloads
    adb shell mkdir -p /sdcard/poc_frames/ /sdcard/poc_location/ /sdcard/poc_sensor/

    # Push frames if available
    if [ -d "$PAYLOADS_DIR/frames/" ]; then
        # Push any PNG files or subdirectories
        for item in "$PAYLOADS_DIR/frames/"*/; do
            [ -d "$item" ] && adb push "$item" /sdcard/poc_frames/ 2>/dev/null || true
        done
    fi

    # Push location config
    LOCATION_FILE=$(find "$PAYLOADS_DIR/locations/" -name "*.json" -type f 2>/dev/null | head -1)
    if [ -n "$LOCATION_FILE" ]; then
        adb push "$LOCATION_FILE" /sdcard/poc_location/config.json 2>/dev/null || true
    fi

    # Push sensor config
    SENSOR_FILE=$(find "$PAYLOADS_DIR/sensors/" -name "holding.json" -type f 2>/dev/null | head -1)
    if [ -n "$SENSOR_FILE" ]; then
        adb push "$SENSOR_FILE" /sdcard/poc_sensor/config.json 2>/dev/null || true
    fi

    # Clear logcat and start capture
    adb logcat -c
    adb logcat -s FrameInterceptor,LocationInterceptor,SensorInterceptor \
        > "$LOGS_DIR/${name}_delivery.log" 2>/dev/null &
    LOGCAT_PID=$!

    # Launch
    adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 2>/dev/null || true
    echo "  Launched. Waiting ${WAIT_SECONDS}s for injection..."
    sleep "$WAIT_SECONDS"

    # Stop logcat capture
    kill "$LOGCAT_PID" 2>/dev/null || true
    wait "$LOGCAT_PID" 2>/dev/null || true

    # Stop the app
    adb shell am force-stop "$PKG" 2>/dev/null || true

    # Report
    FRAMES=$(grep -c "FRAME_DELIVERED" "$LOGS_DIR/${name}_delivery.log" 2>/dev/null || echo 0)
    LOCS=$(grep -c "LOCATION_DELIVERED" "$LOGS_DIR/${name}_delivery.log" 2>/dev/null || echo 0)
    SENSORS=$(grep -c "SENSOR_DELIVERED" "$LOGS_DIR/${name}_delivery.log" 2>/dev/null || echo 0)
    echo "  Frames: $FRAMES | Locations: $LOCS | Sensors: $SENSORS"

    if [ "$FRAMES" -gt 0 ] || [ "$LOCS" -gt 0 ] || [ "$SENSORS" -gt 0 ]; then
        echo "[+] $name: INJECTION ACTIVE"
        ((PASS++))
    else
        echo "[!] $name: NO INJECTION DETECTED"
        ((FAIL++))
    fi
    echo ""
done

echo "=========================================="
echo "  Results: $PASS active, $FAIL failed"
echo "  Delivery logs: $LOGS_DIR/"
echo "=========================================="
