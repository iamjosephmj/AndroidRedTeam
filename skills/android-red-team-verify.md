# Android Red Team -- Verification Agent

Post-patch verification checklist for Android APK red team engagements. Run through this systematically after every patched build before declaring the engagement complete.

This is a **rigid** skill -- follow every phase in order. Do not skip phases. A single unchecked item can mean a silent failure in the field.

---

## How to Use

After patching an APK (smali edits, asset modifications, hook injection), run through each phase below. Each phase has:
- **Check**: what to verify
- **Command**: the exact command to run
- **Pass criteria**: what a passing result looks like
- **Fail action**: what to do if the check fails

Create a todo item for each phase and mark them as you go.

---

## Phase 0: Pre-Flight (Before Install)

### 0.1 APK Exists and Is Signed
```bash
ls -la <patched-apk>
apksigner verify --verbose <patched-apk>
```
- **Pass:** File exists, `Verified using v1 scheme (JAR signing): true` and/or `v2 scheme: true`
- **Fail:** Re-run `zipalign` then `apksigner sign`. Remember: zipalign BEFORE signing, never after.

### 0.2 Signing Scheme Matches Original
```bash
apksigner verify --verbose <original-apk>
apksigner verify --verbose <patched-apk>
```
- **Pass:** Patched APK has the same signing schemes enabled (v1, v2, v3) as original
- **Fail:** Re-sign with explicit `--v1-signing-enabled true --v2-signing-enabled true` flags matching original

### 0.3 Manifest Sanity
```bash
# Check debuggable flag (should be true for JDWP debugging, remove for stealth)
grep 'android:debuggable' <decoded-dir>/AndroidManifest.xml

# Check added permissions are present
grep 'MANAGE_EXTERNAL_STORAGE\|READ_EXTERNAL_STORAGE\|CAMERA\|ACCESS_FINE_LOCATION' <decoded-dir>/AndroidManifest.xml

# Check Application class is unchanged (or intentionally modified for bootstrap)
grep 'android:name=' <decoded-dir>/AndroidManifest.xml | head -3
```
- **Pass:** Expected permissions present, Application class correct
- **Fail:** Edit manifest, rebuild

### 0.4 Smali Patch Files in Correct Location
```bash
# Verify injected classes exist in the right smali directory
find <decoded-dir>/smali*/ -name "FrameInterceptor.smali" -o -name "LocationInterceptor.smali" -o -name "SensorInterceptor.smali" | sort

# Verify .class directive matches file path
head -3 <decoded-dir>/smali_classes2/com/target/package/FrameInterceptor.smali
# Should show: .class public Lcom/target/package/FrameInterceptor;
```
- **Pass:** All injected classes found, `.class` directives match directory paths
- **Fail:** Move files to correct directory, fix `.class` directives

### 0.5 No Kotlin References in Pure-Java APK
```bash
# Check if Kotlin runtime exists in APK
find <decoded-dir>/smali*/ -path "*/kotlin/*" -name "*.smali" | head -3

# If no Kotlin runtime, check that injected code doesn't reference it
grep -rn "Lkotlin/" <decoded-dir>/smali*/com/hookengine/ 2>/dev/null
grep -rn "Lkotlin/" <decoded-dir>/smali*/com/target/*/FrameInterceptor.smali 2>/dev/null
```
- **Pass:** Either Kotlin runtime exists OR no injected code references `Lkotlin/`
- **Fail:** Rewrite injected smali to use only Java/Android framework classes

### 0.6 Asset Modifications Intact
```bash
# Verify modified configs
cat <decoded-dir>/assets/sdk_config.json 2>/dev/null | python3 -m json.tool
cat <decoded-dir>/res/xml/remote_config_defaults.xml 2>/dev/null

# Verify replaced ML models (file size should differ from original)
ls -la <decoded-dir>/assets/*.tflite 2>/dev/null
```
- **Pass:** Config values match your intended modifications, model files replaced
- **Fail:** Re-apply asset edits, rebuild

---

## Phase 1: Install & Permissions

### 1.1 Clean Install
```bash
# Uninstall any existing version (signature mismatch will block upgrade)
adb uninstall <package> 2>/dev/null

# Install
adb install <patched-apk>
```
- **Pass:** `Success`
- **Fail action by error:**

| Error | Fix |
|-------|-----|
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | `adb uninstall <package>` then retry |
| `INSTALL_FAILED_INVALID_APK` | APK corrupt -- re-run build + zipalign + sign pipeline |
| `INSTALL_FAILED_NO_MATCHING_ABIS` | Architecture mismatch -- check `lib/` matches device ABI |
| `INSTALL_FAILED_TEST_ONLY` | Remove `android:testOnly="true"` from manifest, or `adb install -t` |

### 1.2 For Split APKs
```bash
adb install-multiple <patched-base.apk> <split_config.arm64_v8a.apk> <split_config.en.apk>
```
- **Pass:** `Success`
- **Fail:** All splits must be signed with same key. Re-sign ALL of them.

### 1.3 Grant Permissions
```bash
adb shell pm grant <package> android.permission.CAMERA
adb shell pm grant <package> android.permission.ACCESS_FINE_LOCATION
adb shell pm grant <package> android.permission.ACCESS_COARSE_LOCATION
adb shell pm grant <package> android.permission.READ_EXTERNAL_STORAGE

# API 30+ scoped storage
adb shell appops set <package> MANAGE_EXTERNAL_STORAGE allow
```
- **Pass:** No errors from each command
- **Fail:** Permission may not be declared in manifest. Check manifest, rebuild if needed.

### 1.4 Verify Permissions Granted
```bash
adb shell dumpsys package <package> | grep -A 30 "granted=true"
```
- **Pass:** All required permissions show `granted=true`
- **Fail:** Re-run grant commands, check manifest declares the permission

---

## Phase 2: Payload Deployment

### 2.1 Push Payloads to Device
```bash
# Camera frames
adb push ./face_frames/ /sdcard/poc_frames/face_neutral/
adb push ./doc_frames/ /sdcard/poc_frames/document/

# Location config
adb push ./location_config.json /sdcard/poc_location/config.json

# Sensor config
adb push ./sensor_holding.json /sdcard/poc_sensor/config.json
```
- **Pass:** Files transferred without error
- **Fail:** Check device storage space: `adb shell df /sdcard/`

### 2.2 Verify Payloads on Device
```bash
adb shell ls -la /sdcard/poc_frames/face_neutral/ | head -5
adb shell ls -la /sdcard/poc_frames/face_neutral/ | wc -l
adb shell ls -la /sdcard/poc_location/config.json
adb shell ls -la /sdcard/poc_sensor/config.json

# Verify frame files are readable images
adb shell file /sdcard/poc_frames/face_neutral/frame_0001.png 2>/dev/null || \
  adb shell ls -la /sdcard/poc_frames/face_neutral/frame_0001.png
```
- **Pass:** Files exist, frame directory has expected number of files, configs present
- **Fail:** Re-push. Check paths match what the interceptor code reads.

### 2.3 Verify Payload Paths Match Hook Code
```bash
# What path does the interceptor read from?
grep -rn "poc_frames\|poc_location\|poc_sensor" <decoded-dir>/smali*/

# Compare with what's on device
adb shell ls /sdcard/poc_frames/
adb shell ls /sdcard/poc_location/
adb shell ls /sdcard/poc_sensor/
```
- **Pass:** Directory names and structure match exactly between hook code and device
- **Fail:** Either rename device directories or fix hook code paths, rebuild

---

## Phase 3: Cold Launch

### 3.1 Clear Previous State
```bash
adb logcat -c
```

### 3.2 Launch App
```bash
adb shell am start -n <package>/<launcher-activity>

# If you don't know the launcher activity:
adb shell cmd package resolve-activity --brief <package> | tail -1
```
- **Pass:** App opens without crash
- **Fail:** Check logcat immediately (Phase 3.3)

### 3.3 Check for Immediate Crashes
```bash
# Wait 3 seconds for app to initialize, then check
sleep 3
adb logcat -d | grep -iE "FATAL EXCEPTION|VerifyError|ClassNotFound|NoSuchMethod|SecurityException" | head -10
```
- **Pass:** No fatal exceptions
- **Fail action by error:**

| Error | Likely Cause | Fix |
|-------|-------------|-----|
| `java.lang.VerifyError` | Smali register type conflict | Review the smali edit -- check `.locals`, register types at merge points |
| `java.lang.ClassNotFoundException` | Injected class in wrong smali dir, or references missing class | Check class placement, verify Kotlin/AndroidX dependencies |
| `java.lang.NoSuchMethodError` | Method signature mismatch in hook | Verify method descriptor matches exactly (params + return type) |
| `java.lang.SecurityException` | Missing permission | Grant permission, or add to manifest |
| App closes silently (no crash) | Anti-tamper killed the process | Check for signature verification, installer check, DEX integrity -- patch those first |

### 3.4 Check Hook Initialization
```bash
adb logcat -d -s HookEngine | tail -10
```
- **Pass:** Log shows hook initialization messages (e.g., "HookEngine initialized", "Interceptors armed")
- **Fail:** Bootstrap hook not firing. Verify Application.onCreate() patch, or check if the app uses a custom Application class.

### 3.5 Check Anti-Tamper Status
```bash
adb logcat -d | grep -iE "tamper|integrity|signature|invalid|unauthorized|security" | head -10
```
- **Pass:** No tamper/integrity warnings
- **Fail:** Anti-tamper check active. Identify which check (see Section 10 of skill), patch it, rebuild.

---

## Phase 4: Functional Verification (Per Hook Type)

### 4.1 Camera Frame Injection
```bash
# Navigate to the camera/selfie screen in the app, then:
adb logcat -d -s FrameInterceptor | tail -20

# Look for:
# - "FRAME_DELIVERED" messages with incrementing count
# - No "FILE_NOT_FOUND" or "DECODE_ERROR"
# - Frame dimensions match expected (e.g., "Delivering 640x480 frame")
```

**Checklist:**
- [ ] `FRAME_DELIVERED` count > 0
- [ ] No `DECODE_ERROR` (frame format/size mismatch)
- [ ] No `FILE_NOT_FOUND` (payload path wrong)
- [ ] Frame count advances (not stuck at frame 0)
- [ ] SDK processes the frames (no "no face detected" errors from the SDK)

**If SDK says "no face detected":**
```bash
# Check frame quality
adb shell ls -la /sdcard/poc_frames/face_neutral/frame_0001.png
# Verify: face takes up >30% of frame, centered, good lighting
# Verify: frame resolution matches SDK expectation (check ImageAnalysis config)
```

### 4.2 Location Spoofing
```bash
adb logcat -d -s LocationInterceptor | tail -20

# Look for:
# - "LOCATION_DELIVERED" with lat/lng values
# - No "CONFIG_NOT_FOUND"
# - Coordinates match your config file
```

**Checklist:**
- [ ] `LOCATION_DELIVERED` count > 0
- [ ] Latitude/longitude match config values
- [ ] No "mock location detected" in app UI or logs
- [ ] Accuracy value is realistic (5-15m)
- [ ] Timestamp is fresh (not stale)

**If mock location detected:**
```bash
# Check if isFromMockProvider/isMock patches applied
grep -rn "isFromMockProvider\|isMock" <decoded-dir>/smali*/
# Should show patched methods returning false
```

### 4.3 Sensor Injection
```bash
adb logcat -d -s SensorInterceptor | tail -20

# Look for:
# - "SENSOR_DELIVERED" messages
# - Accelerometer values match config
# - No physics violations (sqrt(x^2+y^2+z^2) ~= 9.81)
```

**Checklist:**
- [ ] `SENSOR_DELIVERED` count > 0
- [ ] Accelerometer magnitude ~9.81 m/s^2
- [ ] Gyroscope near zero (stationary)
- [ ] No "device motion anomaly" from SDK
- [ ] Sensor values match the camera scenario (holding phone for selfie, flat for document)

**If SDK detects anomaly:**
```bash
# Verify physics consistency
python3 -c "
import json, math
c = json.load(open('sensor_holding.json'))
mag = math.sqrt(c['accelX']**2 + c['accelY']**2 + c['accelZ']**2)
print(f'Magnitude: {mag:.2f} (should be ~9.81)')
"
```

### 4.4 Asset Modification Verification
```bash
# If you modified JSON configs, check the app behavior:
adb logcat -d | grep -iE "threshold|liveness|config|debug" | head -10

# If you replaced ML models:
adb logcat -d | grep -iE "model|tflite|inference|predict" | head -10
```

**Checklist:**
- [ ] App doesn't crash due to malformed config
- [ ] Modified thresholds take effect (liveness passes more easily)
- [ ] Replaced model loads without error
- [ ] No "integrity check failed on asset" errors

---

## Phase 5: End-to-End Flow

### 5.1 Complete the Full User Journey
Navigate the app through the entire verification flow:
1. Onboarding / consent screens
2. Document capture (if applicable)
3. Selfie / liveness check
4. Location verification (if applicable)
5. Final result screen

**Log the entire flow:**
```bash
# Start recording
adb logcat -c
adb shell screenrecord /sdcard/poc_recording.mp4 &

# ... perform the full flow ...

# Stop recording (Ctrl+C or after flow completes)
# Pull evidence
adb pull /sdcard/poc_recording.mp4 ./evidence/
adb logcat -d > ./evidence/full_logcat.txt
```

### 5.2 Verify Final Result
- [ ] App reached the "success" / "verified" state
- [ ] No error dialogs appeared during the flow
- [ ] No retry prompts (suggests partial failure)
- [ ] Screen recording captures the full journey

### 5.3 Count Deliveries
```bash
echo "=== Delivery Summary ==="
echo "Frames:   $(adb logcat -d | grep -c 'FRAME_DELIVERED')"
echo "Location: $(adb logcat -d | grep -c 'LOCATION_DELIVERED')"
echo "Sensors:  $(adb logcat -d | grep -c 'SENSOR_DELIVERED')"
```
- **Pass:** All relevant counters > 0
- **Fail:** Identify which hook didn't fire. Check Phase 4 for that specific hook.

---

## Phase 6: Edge Cases & Stability

### 6.1 App Backgrounding
```bash
# Press home, wait 5 seconds, reopen
adb shell input keyevent KEYCODE_HOME
sleep 5
adb shell am start -n <package>/<launcher-activity>

# Check hooks still work after resume
adb logcat -d -s HookEngine FrameInterceptor | tail -5
```
- **Pass:** Hooks continue firing after resume
- **Fail:** Hook state lost on pause/resume. May need to re-arm in `onResume()`

### 6.2 Rotation / Config Change
```bash
# Force rotation
adb shell settings put system accelerometer_rotation 0
adb shell settings put system user_rotation 1   # landscape
sleep 2
adb shell settings put system user_rotation 0   # portrait
```
- **Pass:** App doesn't crash, hooks survive config change
- **Fail:** Activity recreated and hooks lost. Check if hooks are tied to Activity lifecycle.

### 6.3 Permission Revocation (Defensive)
```bash
# Revoke a permission and see how app handles it
adb shell pm revoke <package> android.permission.CAMERA
# Reopen the camera flow
# App should either crash or show permission dialog -- NOT silently bypass
```
- **Pass:** App requests permission again or shows error (expected behavior)
- **Note:** Re-grant after testing: `adb shell pm grant <package> android.permission.CAMERA`

### 6.4 Hot-Reload Config (If Supported)
```bash
# Push new location while app is running
adb push new_location.json /sdcard/poc_location/config.json
# Wait for interceptor to pick up new config (typically 2 seconds)
sleep 3
adb logcat -d -s LocationInterceptor | tail -5
# Verify new coordinates appear
```
- **Pass:** New coordinates delivered within expected interval
- **Fail:** Interceptor doesn't re-read config. May need app restart.

---

## Phase 7: Evidence Collection

### 7.1 Gather All Artifacts
```bash
mkdir -p ./evidence/$(date +%Y%m%d)

# Screen recording
adb pull /sdcard/poc_recording.mp4 ./evidence/$(date +%Y%m%d)/

# Full logcat
adb logcat -d > ./evidence/$(date +%Y%m%d)/logcat.txt

# Filtered logs per hook
adb logcat -d -s HookEngine > ./evidence/$(date +%Y%m%d)/hook_engine.txt
adb logcat -d -s FrameInterceptor > ./evidence/$(date +%Y%m%d)/frames.txt
adb logcat -d -s LocationInterceptor > ./evidence/$(date +%Y%m%d)/location.txt
adb logcat -d -s SensorInterceptor > ./evidence/$(date +%Y%m%d)/sensors.txt

# Screenshots
adb exec-out screencap -p > ./evidence/$(date +%Y%m%d)/final_screen.png

# Device info
adb shell getprop ro.product.model > ./evidence/$(date +%Y%m%d)/device_info.txt
adb shell getprop ro.build.version.sdk >> ./evidence/$(date +%Y%m%d)/device_info.txt
adb shell getprop ro.product.cpu.abi >> ./evidence/$(date +%Y%m%d)/device_info.txt
```

### 7.2 Verify Evidence Completeness
- [ ] Screen recording shows full flow from launch to success
- [ ] Logcat contains hook initialization + delivery events
- [ ] Delivery counts are non-zero for all active hook types
- [ ] Screenshots show final "verified" state
- [ ] Device info captured (model, API level, ABI)

### 7.3 Verify No Sensitive Data Leaked
```bash
# Check evidence files don't contain real user data
grep -riE "bearer|password|ssn|social.security|credit.card" ./evidence/$(date +%Y%m%d)/*.txt
```
- **Pass:** No real credentials or PII in evidence files
- **Fail:** Redact before including in report

---

## Phase 8: Reproducibility

### 8.1 Cold Start Verification (Second Run)
```bash
# Kill the app completely
adb shell am force-stop <package>
adb shell pm clear <package>   # WARNING: clears all app data

# Re-grant permissions
adb shell pm grant <package> android.permission.CAMERA
adb shell pm grant <package> android.permission.ACCESS_FINE_LOCATION
adb shell pm grant <package> android.permission.READ_EXTERNAL_STORAGE
adb shell appops set <package> MANAGE_EXTERNAL_STORAGE allow

# Re-launch and run the flow again
adb logcat -c
adb shell am start -n <package>/<launcher-activity>
```
- **Pass:** Bypass works on clean second run (not dependent on leftover state)
- **Fail:** Hook relies on cached state from first run. Fix initialization logic.

### 8.2 Different Device / Emulator (Optional but Recommended)
If available, repeat the full flow on a second device to verify:
- Different Android version works
- Different screen resolution doesn't break frame injection
- Architecture mismatch (arm64 vs x86_64) is handled

---

## Verification Summary Template

Copy and fill this after completing all phases:

```
=== VERIFICATION SUMMARY ===
Date:           YYYY-MM-DD
Target APK:     <package name> v<version>
Patched APK:    <filename>
Device:         <model> (API <level>, <arch>)
apktool:        <version>

PHASE 0 - Pre-Flight:
  [x] APK signed
  [x] Signing scheme matches
  [x] Manifest correct
  [x] Smali patches in place
  [x] No invalid dependencies
  [x] Assets modified

PHASE 1 - Install:
  [x] Clean install success
  [x] Permissions granted

PHASE 2 - Payloads:
  [x] Frames pushed         (N files)
  [x] Location config pushed
  [x] Sensor config pushed
  [x] Paths match hook code

PHASE 3 - Cold Launch:
  [x] No crash
  [x] Hooks initialized
  [x] No anti-tamper triggers

PHASE 4 - Functional:
  [x] Camera:    FRAME_DELIVERED count = N
  [x] Location:  LOCATION_DELIVERED count = N
  [x] Sensors:   SENSOR_DELIVERED count = N
  [x] Assets:    Modified configs effective

PHASE 5 - E2E Flow:
  [x] Full journey completed
  [x] Final result: SUCCESS / VERIFIED
  [x] Screen recording captured

PHASE 6 - Edge Cases:
  [x] Survives backgrounding
  [x] Survives rotation
  [x] Hot-reload works

PHASE 7 - Evidence:
  [x] Recording saved
  [x] Logcat saved
  [x] Screenshots saved
  [x] No PII leaked

PHASE 8 - Reproducibility:
  [x] Second cold run passes
  [ ] Second device tested (optional)

RESULT: PASS / FAIL
NOTES: <any issues encountered and resolved>
```

---

## Quick Verification (Abbreviated)

When time is short, run this minimum viable check:

```bash
#!/usr/bin/env bash
set -euo pipefail
PKG="${1:?Usage: $0 <package-name>}"

echo "=== Quick Verify ==="

# 1. Check app is installed
adb shell pm path "$PKG" > /dev/null && echo "[OK] App installed" || echo "[FAIL] App not installed"

# 2. Check permissions
for perm in CAMERA ACCESS_FINE_LOCATION READ_EXTERNAL_STORAGE; do
    adb shell dumpsys package "$PKG" | grep -q "$perm.*granted=true" \
        && echo "[OK] $perm granted" \
        || echo "[WARN] $perm not granted"
done

# 3. Check payloads on device
adb shell ls /sdcard/poc_frames/ > /dev/null 2>&1 && echo "[OK] Frames on device" || echo "[WARN] No frames"
adb shell ls /sdcard/poc_location/config.json > /dev/null 2>&1 && echo "[OK] Location config" || echo "[WARN] No location config"
adb shell ls /sdcard/poc_sensor/config.json > /dev/null 2>&1 && echo "[OK] Sensor config" || echo "[WARN] No sensor config"

# 4. Launch and check for crash
adb logcat -c
ACTIVITY=$(adb shell cmd package resolve-activity --brief "$PKG" | tail -1)
adb shell am start -n "$ACTIVITY"
sleep 4
CRASHES=$(adb logcat -d | grep -c "FATAL EXCEPTION" || true)
[ "$CRASHES" -eq 0 ] && echo "[OK] No crash on launch" || echo "[FAIL] $CRASHES crashes detected"

# 5. Check hooks
HOOKS=$(adb logcat -d | grep -c "HookEngine\|Interceptor.*init" || true)
[ "$HOOKS" -gt 0 ] && echo "[OK] Hooks initialized ($HOOKS log entries)" || echo "[WARN] No hook logs found"

echo "=== Done ==="
```
