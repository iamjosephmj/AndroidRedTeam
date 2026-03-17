---
title: "Lab 11: Batch Operations"
description: "Process three targets through a single automated pipeline"
---

> **Prerequisites:** All previous labs complete, Chapter 12 (Scaling Operations) read.
>
> **Estimated time:** 60 minutes.
>
> **Chapter reference:** Chapter 12 -- Scaling Operations.
>
> **Target:** `target-batch-1.apk`, `target-batch-2.apk`, `target-batch-3.apk` if available in `targets/`. If not present, use copies of `target-kyc-basic.apk` renamed as `target-batch-1.apk`, `target-batch-2.apk`, `target-batch-3.apk` to practice the pipeline workflow. See `targets/README.md`.

You have been given three target APKs as part of a security assessment. Each uses a different combination of attack surfaces. Your client wants results for all three by end of day. You could run three manual engagements -- that is 45-60 minutes of mechanical work plus reporting. Or you could build a pipeline that does it in a single run.

This lab is about building that pipeline: three shell scripts (patch, deploy, verify) that process all targets end-to-end, produce a consolidated summary table, and generate target catalog entries for future reference.

---

## Target Matrix

| Target | Camera | Location | Sensors | Expected Payloads |
|--------|--------|----------|---------|------------------|
| `target-batch-1` | CameraX face detection | -- | -- | Face frames |
| `target-batch-2` | -- | GPS geofence | -- | Location config |
| `target-batch-3` | CameraX + face | GPS geofence | Accelerometer + gyro | All three |

---

## Step 1: Recon All Three Targets

Before scripting, do a quick recon on each target so you know what to expect:

```bash
cd /Users/josejames/Documents/android-red-team

for apk in course-1/targets/target-batch-*.apk; do
    name=$(basename "$apk" .apk)
    echo "=== $name ==="
    apktool d "$apk" -o "decoded-$name/" -f

    echo "  Camera:"
    grep -rl "ImageAnalysis\$Analyzer\|OnImageAvailableListener" "decoded-$name/smali"*/ 2>/dev/null | wc -l | tr -d ' '

    echo "  Location:"
    grep -rn "onLocationResult\|onLocationChanged" "decoded-$name/smali"*/ 2>/dev/null | wc -l | tr -d ' '

    echo "  Sensors:"
    grep -rn "onSensorChanged" "decoded-$name/smali"*/ 2>/dev/null | wc -l | tr -d ' '

    echo "---"
done
```

Record the surface counts for each target. You will use these to verify the pipeline results.

---

## Step 2: Write `patch_all.sh`

Create the batch patching script:

```bash
#!/usr/bin/env bash
set -euo pipefail

TARGETS_DIR="course-1/targets"
PATCH_TOOL="patch-tool.jar"

mkdir -p patched reports work

echo "=========================================="
echo "  BATCH PATCH: $(date +%Y-%m-%d)"
echo "=========================================="

TOTAL=0
SUCCESS=0
FAILED=0

for apk in ${TARGETS_DIR}/target-batch-*.apk; do
    name=$(basename "$apk" .apk)
    echo ""
    echo "=== Patching: $name ==="

    if java -jar "$PATCH_TOOL" "$apk" \
        --out "patched/${name}-patched.apk" \
        --work-dir "work/$name" 2>&1 | tee "reports/${name}_patch.log"; then
        echo "[OK] $name patched successfully"
        ((SUCCESS++))
    else
        echo "[FAIL] $name patching failed"
        ((FAILED++))
    fi
    ((TOTAL++))
done

echo ""
echo "=========================================="
echo "  BATCH PATCH COMPLETE"
echo "  Total: $TOTAL | Success: $SUCCESS | Failed: $FAILED"
echo "=========================================="
```

---

## Step 3: Write `deploy_all.sh`

The deployment script installs each APK, grants permissions, pushes the appropriate payloads, launches the app, captures delivery logs, and then kills the app before moving to the next target.

Payload mapping:

| Target | Frames | Location | Sensor |
|--------|--------|----------|--------|
| batch-1 | face frames | -- | -- |
| batch-2 | -- | `default_location.json` | -- |
| batch-3 | face frames | `default_location.json` | `holding.json` |

```bash
#!/usr/bin/env bash
set -euo pipefail

mkdir -p reports/delivery

# Prepare default configs
cat > /tmp/batch_location.json << 'EOF'
{"latitude":40.7580,"longitude":-73.9855,"altitude":5.0,"accuracy":8.0,"speed":0.0,"bearing":0.0}
EOF

cat > /tmp/batch_sensor.json << 'EOF'
{"accelX":0.1,"accelY":9.5,"accelZ":2.5,"gyroX":0.0,"gyroY":0.0,"gyroZ":0.0,"jitter":0.15,"proximity":5.0,"light":300.0}
EOF

echo "=========================================="
echo "  BATCH DEPLOY: $(date +%Y-%m-%d)"
echo "=========================================="

for apk in patched/target-batch-*-patched.apk; do
    name=$(basename "$apk" -patched.apk)
    echo ""
    echo "=== Deploying: $name ==="

    # Extract package name from manifest
    MANIFEST="work/$name/AndroidManifest.xml"
    if [ ! -f "$MANIFEST" ]; then
        echo "[WARN] Manifest not found at $MANIFEST -- trying aapt2"
        PKG=$(aapt2 dump badging "$apk" 2>/dev/null | grep "package:" | grep -o "name='[^']*'" | cut -d"'" -f2)
    else
        PKG=$(grep 'package=' "$MANIFEST" | grep -o 'package="[^"]*"' | cut -d'"' -f2)
    fi
    LAUNCHER=$(grep -B2 'android.intent.category.LAUNCHER' "$MANIFEST" 2>/dev/null | grep 'android:name' | grep -o '"[^"]*"' | tr -d '"' | head -1)

    echo "  Package: $PKG"
    echo "  Launcher: $LAUNCHER"

    # Uninstall previous version
    adb uninstall "$PKG" 2>/dev/null || true

    # Install
    adb install -r "$apk"

    # Grant permissions
    for PERM in CAMERA ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION READ_EXTERNAL_STORAGE WRITE_EXTERNAL_STORAGE; do
        adb shell pm grant "$PKG" "android.permission.${PERM}" 2>/dev/null || true
    done
    adb shell appops set "$PKG" MANAGE_EXTERNAL_STORAGE allow 2>/dev/null || true

    # Clear payload directories
    adb shell rm -rf /sdcard/poc_frames/* /sdcard/poc_location/* /sdcard/poc_sensor/*
    adb shell mkdir -p /sdcard/poc_frames/ /sdcard/poc_location/ /sdcard/poc_sensor/

    # Push payloads based on target
    case "$name" in
        *batch-1*)
            [ -d "/tmp/face_frames/" ] && adb push /tmp/face_frames/ /sdcard/poc_frames/
            ;;
        *batch-2*)
            adb push /tmp/batch_location.json /sdcard/poc_location/config.json
            ;;
        *batch-3*)
            [ -d "/tmp/face_frames/" ] && adb push /tmp/face_frames/ /sdcard/poc_frames/
            adb push /tmp/batch_location.json /sdcard/poc_location/config.json
            adb push /tmp/batch_sensor.json /sdcard/poc_sensor/config.json
            ;;
    esac

    # Clear logcat and launch
    adb logcat -c
    adb shell am start -n "${PKG}/${LAUNCHER}"

    # Wait for injection to activate
    sleep 5

    # Capture delivery log
    adb logcat -d -s FrameInterceptor,LocationInterceptor,SensorInterceptor \
        > "reports/delivery/${name}_delivery.log"

    echo "  Delivery log saved."

    # Kill the app before next target
    adb shell am force-stop "$PKG"
    sleep 1

    echo "[OK] $name deployed and captured"
done

echo ""
echo "=========================================="
echo "  BATCH DEPLOY COMPLETE"
echo "=========================================="
```

---

## Step 4: Write `verify_all.sh`

The verification script parses delivery logs, counts events, produces a formatted summary table, and flags failures.

```bash
#!/usr/bin/env bash

echo "=========================================="
echo "  BATCH VERIFICATION: $(date +%Y-%m-%d)"
echo "=========================================="
echo ""

# Print header
printf "%-20s | %8s | %10s | %8s | %s\n" "Target" "Frames" "Locations" "Sensors" "Status"
printf "%-20s-+-%8s-+-%10s-+-%8s-+-%s\n" "--------------------" "--------" "----------" "--------" "------"

TOTAL=0
PASS=0
FAIL=0

for log in reports/delivery/target-batch-*_delivery.log; do
    name=$(basename "$log" _delivery.log)

    FRAMES=$(grep -c "FRAME_DELIVERED" "$log" 2>/dev/null || echo 0)
    LOCS=$(grep -c "LOCATION_DELIVERED" "$log" 2>/dev/null || echo 0)
    SENSORS=$(grep -c "SENSOR_DELIVERED" "$log" 2>/dev/null || echo 0)

    # Determine expected surfaces and check
    STATUS="PASS"
    case "$name" in
        *batch-1*)
            [ "$FRAMES" -eq 0 ] && STATUS="FAIL"
            ;;
        *batch-2*)
            [ "$LOCS" -eq 0 ] && STATUS="FAIL"
            ;;
        *batch-3*)
            [ "$FRAMES" -eq 0 ] || [ "$LOCS" -eq 0 ] || [ "$SENSORS" -eq 0 ] && STATUS="FAIL"
            ;;
    esac

    printf "%-20s | %8d | %10d | %8d | %s\n" "$name" "$FRAMES" "$LOCS" "$SENSORS" "$STATUS"

    ((TOTAL++))
    if [ "$STATUS" = "PASS" ]; then
        ((PASS++))
    else
        ((FAIL++))
    fi
done

echo ""
echo "=========================================="
echo "  SUMMARY: $PASS/$TOTAL passed, $FAIL failed"
echo "=========================================="

# Generate summary report file
SUMMARY_FILE="reports/batch_summary_$(date +%Y%m%d).txt"
{
    echo "BATCH ENGAGEMENT SUMMARY"
    echo "Date: $(date +%Y-%m-%d)"
    echo "Targets processed: $TOTAL"
    echo "Passed: $PASS"
    echo "Failed: $FAIL"
    echo ""
    printf "%-20s | %8s | %10s | %8s | %s\n" "Target" "Frames" "Locations" "Sensors" "Status"
    for log in reports/delivery/target-batch-*_delivery.log; do
        name=$(basename "$log" _delivery.log)
        F=$(grep -c "FRAME_DELIVERED" "$log" 2>/dev/null || echo 0)
        L=$(grep -c "LOCATION_DELIVERED" "$log" 2>/dev/null || echo 0)
        S=$(grep -c "SENSOR_DELIVERED" "$log" 2>/dev/null || echo 0)
        printf "%-20s | %8d | %10d | %8d\n" "$name" "$F" "$L" "$S"
    done
} > "$SUMMARY_FILE"

echo "Summary report saved to: $SUMMARY_FILE"
```

---

## Step 5: Run the Full Pipeline

```bash
chmod +x patch_all.sh deploy_all.sh verify_all.sh

./patch_all.sh
./deploy_all.sh
./verify_all.sh
```

The full pipeline should complete in 3-5 minutes. The patch-tool typically takes 15-30 seconds per APK.

**Expected output from `verify_all.sh`:**

```text
Target               |   Frames |  Locations |  Sensors | Status
---------------------+----------+------------+----------+-------
target-batch-1       |       42 |          0 |        0 | PASS
target-batch-2       |        0 |         15 |        0 | PASS
target-batch-3       |       38 |         12 |       87 | PASS

SUMMARY: 3/3 passed, 0 failed
```

> **Between targets:** The `deploy_all.sh` script clears payload directories before pushing for each target. If you run targets manually instead, remember to clear: `adb shell rm -rf /sdcard/poc_frames/* /sdcard/poc_location/* /sdcard/poc_sensor/*`

---

## Step 6: Write Target Catalog Entries

For each of the three targets, create a YAML catalog entry. These entries capture intelligence for future reference -- the next time you or a teammate encounters any of these apps, the data is already there.

```bash
mkdir -p catalog
```

**Example entry for target-batch-1:**

```yaml
# catalog/target-batch-1.yml
target:
  name: target-batch-1
  package: com.example.batch1
  version: "1.0"
  date_assessed: 2026-03-17

surfaces:
  camera:
    api: CameraX
    hooks: [analyze, toBitmap, onCaptureSuccess]
    files:
      - smali/com/example/batch1/CameraActivity.smali
  location:
    present: false
  sensors:
    present: false

payloads:
  camera_frames: face_neutral/
  location_config: null
  sensor_config: null

results:
  frames_delivered: 42
  locations_delivered: 0
  sensor_events: 0
  outcome: PASS

notes: |
  Camera-only target. CameraX with ML Kit face detection.
  No location or sensor surfaces. Straightforward single-subsystem injection.
```

Create similar entries for `target-batch-2` and `target-batch-3`. Fill in actual values from your pipeline run.

---

## Step 7: Generate the Summary Report

Create a consolidated engagement report that covers all three targets:

```bash
cat > reports/batch_engagement_report.txt << 'RPTEOF'
BATCH ENGAGEMENT REPORT
=======================
Date:     YYYY-MM-DD
Assessor: [your name]
Targets:  3

TARGET SUMMARY
--------------
1. target-batch-1: Camera-only (CameraX). Frame injection PASS.
2. target-batch-2: Location-only (FusedLocationProvider). GPS injection PASS.
3. target-batch-3: Full surface (Camera + Location + Sensors). All subsystems PASS.

DELIVERY STATISTICS
-------------------
[Paste the verify_all.sh output table here]

PIPELINE PERFORMANCE
--------------------
Total wall time:  [X minutes]
Patch time:       [X seconds per APK]
Deploy time:      [X seconds per target]
Verification:     Automated

FINDINGS
--------
All three targets were successfully patched and verified through the automated
pipeline. No manual intervention was required during patching or deployment.

[Target-specific notes for each]

RECOMMENDATIONS
---------------
1. [Per-target recommendations based on which surfaces were present]
RPTEOF
```

Edit the report with actual data from your run.

---

## Deliverables

| Artifact | Description |
|----------|-------------|
| `patch_all.sh` | Batch patching script |
| `deploy_all.sh` | Batch deployment and payload push script |
| `verify_all.sh` | Verification and summary script |
| Pipeline output | Full console output from all three scripts |
| Summary table | Delivery statistics for each target |
| 3 catalog entries | YAML files in `catalog/`, one per target |
| Batch report | Consolidated engagement report |

---

## Success Criteria

- [ ] All three APKs patched successfully by `patch_all.sh`
- [ ] All three APKs deployed and launched by `deploy_all.sh`
- [ ] `verify_all.sh` produces a readable summary with delivery counts
- [ ] `target-batch-1`: frame injection active (`FRAME_DELIVERED` events)
- [ ] `target-batch-2`: location injection active (`LOCATION_DELIVERED` events)
- [ ] `target-batch-3`: all three subsystems active (frame + location + sensor events)
- [ ] Three catalog entries created with complete fields
- [ ] Summary report covers all targets with delivery statistics

---

## Self-Check Script

```bash
#!/usr/bin/env bash
echo "=========================================="
echo "  LAB 11: BATCH OPERATIONS SELF-CHECK"
echo "=========================================="
PASS=0; FAIL=0

# Check scripts exist and are executable
echo "--- Scripts ---"
for script in patch_all.sh deploy_all.sh verify_all.sh; do
  if [ -f "$script" ]; then
    echo "  [PASS] $script exists"
    ((PASS++))
    if [ -x "$script" ]; then
      echo "  [PASS] $script is executable"
      ((PASS++))
    else
      echo "  [WARN] $script not executable -- run: chmod +x $script"
    fi
  else
    echo "  [FAIL] $script not found"
    ((FAIL++))
  fi
done

# Check patched APKs
echo ""
echo "--- Patched APKs ---"
PATCHED_COUNT=$(ls patched/*-patched.apk 2>/dev/null | wc -l | tr -d ' ')
echo "  Patched APKs: $PATCHED_COUNT"
if [ "$PATCHED_COUNT" -ge 3 ]; then
  echo "  [PASS] All 3 targets patched"
  ((PASS++))
else
  echo "  [FAIL] Expected 3 patched APKs, found $PATCHED_COUNT"
  ((FAIL++))
fi

# Check patch logs
echo ""
echo "--- Patch Logs ---"
for i in 1 2 3; do
  LOG=$(ls reports/target-batch-${i}_patch.log 2>/dev/null | head -1)
  if [ -n "$LOG" ]; then
    HOOKS=$(grep -c "\[+\] Patched\|\[+\] Applied" "$LOG" 2>/dev/null || echo 0)
    echo "  target-batch-$i: $HOOKS hooks applied"
    ((PASS++))
  else
    echo "  target-batch-$i: [WARN] No patch log found"
  fi
done

# Check delivery logs
echo ""
echo "--- Delivery Logs ---"
for i in 1 2 3; do
  DLOG="reports/delivery/target-batch-${i}_delivery.log"
  if [ -f "$DLOG" ]; then
    F=$(grep -c "FRAME_DELIVERED" "$DLOG" 2>/dev/null || echo 0)
    L=$(grep -c "LOCATION_DELIVERED" "$DLOG" 2>/dev/null || echo 0)
    S=$(grep -c "SENSOR_DELIVERED" "$DLOG" 2>/dev/null || echo 0)
    echo "  target-batch-$i: Frames=$F, Locations=$L, Sensors=$S"
  else
    echo "  target-batch-$i: [FAIL] No delivery log"
    ((FAIL++))
  fi
done

# Check catalog entries
echo ""
echo "--- Target Catalog ---"
CATALOG_COUNT=$(ls catalog/*.yml catalog/*.yaml 2>/dev/null | wc -l | tr -d ' ')
echo "  Catalog entries: $CATALOG_COUNT"
if [ "$CATALOG_COUNT" -ge 3 ]; then
  echo "  [PASS] All 3 catalog entries created"
  ((PASS++))
else
  echo "  [FAIL] Expected 3 catalog entries, found $CATALOG_COUNT"
  ((FAIL++))
fi

# Check summary report
echo ""
echo "--- Summary Report ---"
REPORT=$(ls reports/batch_engagement_report.txt reports/batch_summary_*.txt 2>/dev/null | head -1)
if [ -n "$REPORT" ]; then
  echo "  [PASS] Summary report found: $REPORT"
  ((PASS++))
else
  echo "  [FAIL] No summary report found"
  ((FAIL++))
fi

echo ""
echo "  Results: $PASS passed, $FAIL failed"
echo ""
echo "  Manual checks:"
echo "    1. Run ./verify_all.sh and confirm delivery stats for all 3 targets"
echo "    2. target-batch-1: FRAME_DELIVERED events present"
echo "    3. target-batch-2: LOCATION_DELIVERED events present"
echo "    4. target-batch-3: FRAME + LOCATION + SENSOR events all present"
echo "    5. Each catalog entry has: package name, surfaces, hooks, payloads, result"
echo "=========================================="
[ "$FAIL" -eq 0 ] && echo "  Lab 11 COMPLETE." || echo "  Lab 11 INCOMPLETE -- review failed checks."
```

---

## What You Just Demonstrated

A repeatable, scriptable engagement pipeline. Three targets, one command sequence, complete results with evidence and intelligence artifacts.

This scales. Add a fourth target to the `targets/` directory and the scripts process it automatically. Update the patch-tool with a new hook module (Lab 8) and re-run the entire batch. Swap the payloads for a different face profile and re-verify. The pipeline handles the mechanics. You handle the intelligence -- which targets to test, which payloads to use, and what the results mean for the client.

The catalog entries you created are the beginning of an institutional knowledge base. Every target you assess adds to the catalog. Over time, you build a library of known app behaviors, successful payloads, and quirks that save hours on repeat engagements. The pipeline runs the engagement. The catalog captures the learning. Together, they make every subsequent assessment faster and more reliable than the last.
