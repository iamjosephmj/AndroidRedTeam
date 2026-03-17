---
title: "Lab 9: Automated Engagement"
description: "Execute a full engagement pipeline using automation -- shell scripts or AI-assisted"
---

> **Prerequisites:** Labs 0-6 complete, Chapter 16 (Automation and Scaling) read.
>
> **Estimated time:** 30-45 minutes.
>
> **Chapter reference:** Chapter 16 -- Automation and Scaling.
>
> **Target:** `materials/targets/target-unknown.apk` if available. If not present, use `materials/targets/target-kyc-basic.apk` as the "mystery" target -- pretend you do not know what it contains and let the automation discover it.

You have been handed an APK you have never seen before. You do not know the package name, camera API, location checks, sensor usage, or anti-tamper defenses. It is a black box. Instead of running the manual engagement pipeline -- decode, grep, patch, install, push, launch, verify (15-20 minutes of mechanical work) -- you are going to automate the entire pipeline and run it in a single invocation.

This lab offers two paths. Choose the one that fits your workflow:

| Path | Approach | Time |
|------|----------|------|
| **Path A: Shell Script** | Write a `full_engagement.sh` script that executes the complete pipeline | 30 min |
| **Path B: AI-Assisted** | Use an AI coding assistant with the `android-red-team` skill to drive the pipeline | 20 min + verification |

Both paths produce the same output: a recon report, a patched APK, deployment evidence, and an engagement report. The critical skill in both cases is **verification** -- confirming that the automated output is correct.

---

## Path A: Shell Script Automation

### Step 1: Write the Engagement Script

Create `full_engagement.sh` that takes a single argument -- the APK path -- and executes the complete pipeline:

```bash
#!/usr/bin/env bash
set -euo pipefail

APK="$1"
NAME=$(basename "$APK" .apk)
WORK_DIR="./engagement-${NAME}"
REPORT_DIR="${WORK_DIR}/reports"

mkdir -p "$WORK_DIR" "$REPORT_DIR"

echo "=== PHASE 1: RECON ==="

# Decode
apktool d "$APK" -o "${WORK_DIR}/decoded" -f

# Extract package name and launcher activity
PKG=$(grep 'package=' "${WORK_DIR}/decoded/AndroidManifest.xml" | grep -o 'package="[^"]*"' | cut -d'"' -f2)
LAUNCHER=$(grep -B2 'android.intent.category.LAUNCHER' "${WORK_DIR}/decoded/AndroidManifest.xml" | grep 'android:name' | grep -o '"[^"]*"' | tr -d '"' | head -1)
echo "Package: $PKG"
echo "Launcher: $LAUNCHER"

# Surface scan
echo "--- Camera ---" > "${REPORT_DIR}/recon.txt"
grep -rl "ImageAnalysis\$Analyzer\|OnImageAvailableListener" "${WORK_DIR}/decoded/smali"*/ 2>/dev/null >> "${REPORT_DIR}/recon.txt" || echo "  (none)" >> "${REPORT_DIR}/recon.txt"

echo "--- Location ---" >> "${REPORT_DIR}/recon.txt"
grep -rn "onLocationResult\|onLocationChanged" "${WORK_DIR}/decoded/smali"*/ 2>/dev/null >> "${REPORT_DIR}/recon.txt" || echo "  (none)" >> "${REPORT_DIR}/recon.txt"

echo "--- Sensors ---" >> "${REPORT_DIR}/recon.txt"
grep -rn "onSensorChanged" "${WORK_DIR}/decoded/smali"*/ 2>/dev/null >> "${REPORT_DIR}/recon.txt" || echo "  (none)" >> "${REPORT_DIR}/recon.txt"

echo "--- Mock Detection ---" >> "${REPORT_DIR}/recon.txt"
grep -rn "isFromMockProvider\|isMock" "${WORK_DIR}/decoded/smali"*/ 2>/dev/null >> "${REPORT_DIR}/recon.txt" || echo "  (none)" >> "${REPORT_DIR}/recon.txt"

echo "Recon saved to ${REPORT_DIR}/recon.txt"

echo ""
echo "=== PHASE 2: PATCH ==="

java -jar patch-tool.jar "$APK" \
  --out "${WORK_DIR}/${NAME}-patched.apk" \
  --work-dir "${WORK_DIR}/patch-work" 2>&1 | tee "${REPORT_DIR}/patch.log"

echo ""
echo "=== PHASE 3: DEPLOY ==="

adb uninstall "$PKG" 2>/dev/null || true
adb install -r "${WORK_DIR}/${NAME}-patched.apk"

# Grant all relevant permissions
for PERM in CAMERA ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION READ_EXTERNAL_STORAGE WRITE_EXTERNAL_STORAGE; do
  adb shell pm grant "$PKG" "android.permission.${PERM}" 2>/dev/null || true
done
adb shell appops set "$PKG" MANAGE_EXTERNAL_STORAGE allow 2>/dev/null || true

# Push default payloads
adb shell mkdir -p /sdcard/poc_frames/ /sdcard/poc_location/ /sdcard/poc_sensor/

# Push face frames if available
if [ -d "/tmp/face_frames/" ]; then
  adb push /tmp/face_frames/ /sdcard/poc_frames/
fi

# Push default location config
cat > /tmp/auto_location.json << 'LOCEOF'
{"latitude":40.7580,"longitude":-73.9855,"altitude":5.0,"accuracy":8.0,"speed":0.0,"bearing":0.0}
LOCEOF
adb push /tmp/auto_location.json /sdcard/poc_location/config.json

# Push default sensor config
cat > /tmp/auto_sensor.json << 'SENEOF'
{"accelX":0.1,"accelY":9.5,"accelZ":2.5,"gyroX":0.0,"gyroY":0.0,"gyroZ":0.0,"jitter":0.15,"proximity":5.0,"light":300.0}
SENEOF
adb push /tmp/auto_sensor.json /sdcard/poc_sensor/config.json

echo ""
echo "=== PHASE 4: LAUNCH AND VERIFY ==="

adb logcat -c
adb shell am start -n "${PKG}/${LAUNCHER}"

# Wait for injection to activate
sleep 5

# Capture delivery log
adb logcat -d -s FrameInterceptor,LocationInterceptor,SensorInterceptor > "${REPORT_DIR}/delivery.log"

FRAMES=$(grep -c "FRAME_DELIVERED" "${REPORT_DIR}/delivery.log" 2>/dev/null || echo 0)
LOCS=$(grep -c "LOCATION_DELIVERED" "${REPORT_DIR}/delivery.log" 2>/dev/null || echo 0)
SENSORS=$(grep -c "SENSOR_DELIVERED" "${REPORT_DIR}/delivery.log" 2>/dev/null || echo 0)

echo ""
echo "=== RESULTS ==="
echo "Package:    $PKG"
echo "Frames:     $FRAMES"
echo "Locations:  $LOCS"
echo "Sensors:    $SENSORS"

# Generate summary report
cat > "${REPORT_DIR}/engagement_report.txt" << RPTEOF
ENGAGEMENT REPORT
=================
Target:     $NAME
Package:    $PKG
Launcher:   $LAUNCHER
Date:       $(date +%Y-%m-%d)

DELIVERY STATISTICS
  Frames delivered:     $FRAMES
  Locations delivered:  $LOCS
  Sensor events:        $SENSORS

STATUS: $([ "$FRAMES" -gt 0 ] || [ "$LOCS" -gt 0 ] || [ "$SENSORS" -gt 0 ] && echo "INJECTION ACTIVE" || echo "NO INJECTION DETECTED")
RPTEOF

echo ""
echo "Engagement report: ${REPORT_DIR}/engagement_report.txt"
echo "=== DONE ==="
```

### Step 2: Run It

```bash
chmod +x full_engagement.sh
./full_engagement.sh materials/targets/target-kyc-basic.apk
```

The entire pipeline runs in a single invocation. Review the output -- every phase should complete without errors.

---

## Path B: AI-Assisted Automation

### Step 1: Set Up the Skill

Ensure the `android-red-team` skill file is available in your project:

```bash
ls .claude/skills/android-red-team.md
# If not present:
mkdir -p .claude/skills/
cp skills/android-red-team.md .claude/skills/
```

### Step 2: Launch the AI Assistant and Engage

Open your AI coding assistant in the working directory. Place the target APK in the directory. Then issue the prompt:

```text
Run a full engagement against target-unknown.apk.
Use the default face frames and location config.
```

Watch the AI execute the pipeline. It will:

1. Decode the APK and grep for hook surfaces
2. Identify the Application class, camera API, location API, sensor usage
3. Run the patch-tool
4. Install on the emulator
5. Grant permissions
6. Push payloads
7. Launch the app
8. Check logcat for injection confirmation
9. Generate an engagement report

**Do not correct the AI mid-run.** Let it complete the full pipeline, then verify in the next step.

### Step 3: Review the AI Output

The AI produces a recon report, patch output, logcat analysis, and engagement report. Your job is to verify every claim independently.

---

## Verification (Both Paths)

Regardless of which path you took, run these manual checks to validate the automated findings:

```bash
# Verify recon: does the app actually use the APIs the automation identified?
DECODED=$(ls -d engagement-*/decoded decoded-target-* manual-check/ 2>/dev/null | head -1)
if [ -n "$DECODED" ]; then
  echo "Camera (CameraX):"
  grep -rl "ImageAnalysis\$Analyzer" "$DECODED/smali"*/ 2>/dev/null | wc -l
  echo "Camera (Camera2):"
  grep -rl "OnImageAvailableListener" "$DECODED/smali"*/ 2>/dev/null | grep -v "androidx/camera" | wc -l
  echo "Location:"
  grep -rn "onLocationResult" "$DECODED/smali"*/ 2>/dev/null | wc -l
  echo "Sensors:"
  grep -rn "onSensorChanged" "$DECODED/smali"*/ 2>/dev/null | wc -l
fi

# Verify injection: is it actually active?
adb logcat -d -s FrameInterceptor,LocationInterceptor,SensorInterceptor | head -30

# Verify delivery counts
echo "Frames:    $(adb logcat -d -s FrameInterceptor 2>/dev/null | grep -c FRAME_DELIVERED)"
echo "Locations: $(adb logcat -d -s LocationInterceptor 2>/dev/null | grep -c LOCATION_DELIVERED)"
echo "Sensors:   $(adb logcat -d -s SensorInterceptor 2>/dev/null | grep -c SENSOR_DELIVERED)"
```

### Write Verification Notes

For each section of the automated report, document:

| Section | Correct? | Evidence | Missed? | Wrong? |
|---------|----------|----------|---------|--------|
| Camera API | Yes/No | Grep results | | |
| Location API | Yes/No | Grep results | | |
| Sensor usage | Yes/No | Grep results | | |
| Hook count | Yes/No | Patch log | | |
| Delivery stats | Yes/No | Logcat | | |

Save your notes alongside the automated report. The combination of automated execution and manual verification is the final deliverable.

---

## Deliverables

| Artifact | Description |
|----------|-------------|
| `full_engagement.sh` (Path A) or AI transcript (Path B) | The automation that ran the pipeline |
| Engagement report | Generated by the automation |
| Verification notes | Your manual confirmation of each finding |
| Delivery log | Logcat capture proving injection was active |

---

## Success Criteria

- [ ] Automation successfully completed the full pipeline (recon, patch, deploy, verify)
- [ ] The engagement report is structurally complete (target info, surfaces, hooks, results)
- [ ] Manual verification confirms or corrects every automated finding
- [ ] You documented at least one thing the automation got right and one area where your judgment improved the result
- [ ] The final verified report accurately reflects the target's actual attack surfaces

---

## Self-Check Script

```bash
#!/usr/bin/env bash
echo "=========================================="
echo "  LAB 9: AUTOMATED ENGAGEMENT SELF-CHECK"
echo "=========================================="
PASS=0; FAIL=0

# Check that automation artifacts exist
REPORT=$(ls engagement-*/reports/engagement_report.txt engagement_report.md ai_engagement_report.md 2>/dev/null | head -1)
if [ -n "$REPORT" ]; then
  echo "  [PASS] Engagement report found: $REPORT"
  ((PASS++))
else
  echo "  [FAIL] No engagement report found"
  ((FAIL++))
fi

# Check for the script (Path A) or transcript (Path B)
if [ -f full_engagement.sh ]; then
  echo "  [PASS] full_engagement.sh found (Path A)"
  ((PASS++))
elif ls ai_transcript* claude_transcript* 2>/dev/null | head -1 > /dev/null 2>&1; then
  echo "  [PASS] AI transcript found (Path B)"
  ((PASS++))
else
  echo "  [WARN] Neither engagement script nor AI transcript found"
fi

# Check for verification notes
NOTES=$(ls verification_notes* manual_verification* 2>/dev/null | head -1)
if [ -n "$NOTES" ]; then
  echo "  [PASS] Verification notes found: $NOTES"
  ((PASS++))
else
  echo "  [FAIL] No verification notes found"
  ((FAIL++))
fi

# Check that injection was active
FRAMES=$(adb logcat -d -s FrameInterceptor 2>/dev/null | grep -c "FRAME_DELIVERED")
LOCS=$(adb logcat -d -s LocationInterceptor 2>/dev/null | grep -c "LOCATION_DELIVERED")
SENSORS=$(adb logcat -d -s SensorInterceptor 2>/dev/null | grep -c "SENSOR_DELIVERED")
echo "  Injection status -- Frames: $FRAMES, Locations: $LOCS, Sensors: $SENSORS"
if [ "$FRAMES" -gt 0 ] || [ "$LOCS" -gt 0 ] || [ "$SENSORS" -gt 0 ]; then
  echo "  [PASS] At least one injection subsystem active"
  ((PASS++))
else
  echo "  [FAIL] No injection activity detected"
  ((FAIL++))
fi

# Check report quality
if [ -n "$REPORT" ]; then
  grep -qi "recon\|surface\|camera" "$REPORT" 2>/dev/null && echo "  [PASS] Report covers recon" && ((PASS++)) || { echo "  [FAIL] Report missing recon"; ((FAIL++)); }
  grep -qi "hook\|patch" "$REPORT" 2>/dev/null && echo "  [PASS] Report covers hooks/patches" && ((PASS++)) || { echo "  [FAIL] Report missing hooks"; ((FAIL++)); }
  grep -qi "deliver\|inject\|frame\|location" "$REPORT" 2>/dev/null && echo "  [PASS] Report covers delivery" && ((PASS++)) || { echo "  [FAIL] Report missing delivery"; ((FAIL++)); }
fi

echo ""
echo "  Results: $PASS passed, $FAIL failed"
echo ""
echo "  Manual checks:"
echo "    1. Does the report correctly identify which APIs the target uses?"
echo "    2. Did you verify at least one finding with your own grep/decode?"
echo "    3. Did you document what the automation got right and what it missed?"
echo "=========================================="
[ "$FAIL" -eq 0 ] && echo "  Lab 9 COMPLETE." || echo "  Lab 9 INCOMPLETE -- review failed checks."
```

---

## What You Just Demonstrated

The manual engagement pipeline takes 15-20 minutes of mechanical work. The automated version takes 2-3 minutes for execution plus 5 minutes for verification. Total: under 10 minutes for a complete engagement with verified results.

The key insight is not that automation is faster -- it is that automation is *consistent*. A shell script does not forget to check for mock detection. It does not skip the sensor recon because it is tired. It runs the same checks in the same order every time. Your job shifts from executing the pipeline to verifying the output and making the judgment calls that require context and experience.

This is how professional red team operations scale. Not by working faster, but by automating the repeatable parts and spending human attention on the parts that matter.
