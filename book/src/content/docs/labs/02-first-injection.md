---
title: "Lab 2: First Injection"
description: "Patch an APK, deploy it, verify all three injection subsystems activate"
---

**Prerequisites:** Lab 1 complete (recon report produced). Chapter 6 (The Injection Pipeline) read.
**Estimated time:** 20 minutes.
**Chapter reference:** Chapter 6 -- The Injection Pipeline.

You have a recon report that predicts exactly which hooks will fire and which will be skipped. Now you run the patch-tool, compare its output against those predictions, deploy the patched APK, and verify the injection runtime is live. By the end of this lab, you will have a weaponized APK running on your emulator with all three injection subsystems armed and the overlay operational.

All commands assume you are working from the project root (where `patch-tool.jar` lives).

---

## Step 1: Patch the Target

Run the patch-tool against the course target:

```bash
java -jar patch-tool.jar course-1/targets/target-kyc-basic.apk \
  --out patched.apk \
  --work-dir ./work
```

This takes 30-60 seconds. The tool decodes the APK, injects 1,134 runtime classes, patches the hook points, rebuilds, aligns, and signs.

Save the full output for your records:

```bash
java -jar patch-tool.jar course-1/targets/target-kyc-basic.apk \
  --out patched.apk \
  --work-dir ./work 2>&1 | tee patch_output.txt
```

---

## Step 2: Read the Patch Output

The patch-tool communicates through line prefixes. Learn to read them:

| Prefix | Meaning |
|--------|---------|
| `[*]` | Info -- telling you what is happening |
| `[+]` | Success -- that step completed |
| `[!]` | Warning -- a hook target was not found, skipped |
| `[-]` | Error -- something broke |

Scan the output for every `[+]` and `[!]` line. You should see something like this:

```text
[+] Injected 1134 runtime smali files into smali_classes7/
[+] Detected: com.poc.PocApplication
[+] Patched Application.onCreate()
[+] Patched toBitmap() in 1 file(s)
[+] Patched analyze() in 1 method(s)
[+] Patched onCaptureSuccess() in 1 method(s)
[!] No Surface(SurfaceTexture) found -- target may not use Camera2
[!] No getSurface() found -- target may not use Camera2
[!] No OnImageAvailableListener found -- target may not use Camera2
[+] Patched onLocationResult() in 1 method(s)
[!] No onLocationChanged(Location) found -- target may not use LocationListener
[!] No onSensorChanged(SensorEvent) found -- target may not use SensorEventListener
```

Every `[!]` warning is normal for this target. The warnings mean the hook target does not exist in the APK -- because the app does not use that API. Your recon already told you this.

Any `[-]` error means the patching failed. Stop and diagnose before continuing.

---

## Step 3: Cross-Reference with Your Recon Report

Pull up the recon report from Lab 1. Compare every patch-tool line against your predictions:

| Your Recon Prediction | Expected Patch Output | Actual Output |
|----------------------|----------------------|---------------|
| CameraX `ImageAnalysis.Analyzer` found | `[+] Patched analyze()` | |
| CameraX `toBitmap()` found | `[+] Patched toBitmap()` | |
| CameraX `OnImageCapturedCallback` found | `[+] Patched onCaptureSuccess()` | |
| No Camera2 `OnImageAvailableListener` | `[!] No OnImageAvailableListener` | |
| `onLocationResult` found | `[+] Patched onLocationResult()` | |
| No legacy `onLocationChanged` | `[!] No onLocationChanged` | |
| Sensor: based on your findings | `[+]` or `[!]` for onSensorChanged | |

Fill in the "Actual Output" column from your `patch_output.txt`. Every line should match. If something does not match -- a hook you expected to fire shows as skipped, or a hook fires that your recon did not predict -- investigate before deploying. Go to the `./work` directory and inspect the smali directly.

This cross-reference is not busywork. On real engagements with obfuscated targets, this is how you catch missing hooks before they cost you hours of debugging.

---

## Step 4: Deploy to the Emulator

### 4a: Uninstall Any Previous Installation

If the target was previously installed (with a different signature), the install will fail with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`. Uninstall first:

```bash
adb uninstall com.poc.biometric
```

If the app was never installed, this returns a "not installed" message. That is fine.

### 4b: Install the Patched APK

```bash
adb install -r patched.apk
```

**Expected output:**

```text
Performing Streamed Install
Success
```

If you see `INSTALL_FAILED_UPDATE_INCOMPATIBLE`, you did not uninstall the old version. If you see `INSTALL_FAILED_NO_MATCHING_ABIS`, you have an architecture mismatch (ARM APK on x86 emulator or vice versa).

### 4c: Grant Permissions

Grant all permissions up front so permission dialogs do not interrupt the flow:

```bash
# Camera
adb shell pm grant com.poc.biometric android.permission.CAMERA

# Location
adb shell pm grant com.poc.biometric android.permission.ACCESS_FINE_LOCATION
adb shell pm grant com.poc.biometric android.permission.ACCESS_COARSE_LOCATION

# Storage (legacy)
adb shell pm grant com.poc.biometric android.permission.READ_EXTERNAL_STORAGE
adb shell pm grant com.poc.biometric android.permission.WRITE_EXTERNAL_STORAGE

# Storage (API 30+)
adb shell appops set com.poc.biometric MANAGE_EXTERNAL_STORAGE allow
```

Some of these may return errors if the target does not declare that specific permission. That is harmless -- grant what you can, skip what you cannot.

---

## Step 5: Arm the Overlay

The overlay (lightning bolt button) only appears when payload directories contain content. Before launching, create the directories and push test frames.

### 5a: Generate Test Frames

Frame payloads are not distributed with the course materials (privacy constraints on face images). Generate simple test frames to verify the injection pipeline. These gray rectangles will not pass face detection, but they prove the injection is operational.

You need `ffmpeg` installed (`brew install ffmpeg` on macOS, `sudo apt install ffmpeg` on Linux).

```bash
mkdir -p /tmp/test_frames
for i in $(seq -w 1 30); do
  ffmpeg -y -f lavfi -i "color=c=gray:size=640x480:d=0.1" \
    -frames:v 1 "/tmp/test_frames/${i}.png" 2>/dev/null
done
```

This creates 30 solid gray PNGs at 640x480. The exact content does not matter for pipeline verification.

### 5b: Push Frames to the Device

```bash
adb shell mkdir -p /sdcard/poc_frames/test/
adb push /tmp/test_frames/ /sdcard/poc_frames/test/
```

### 5c: Push Location Config (Optional)

If you want to verify all three subsystems, push a location config:

```bash
adb shell mkdir -p /sdcard/poc_location/
echo '{"latitude":40.7580,"longitude":-73.9855,"altitude":5.0,"accuracy":8.0}' > /tmp/loc.json
adb push /tmp/loc.json /sdcard/poc_location/config.json
```

### 5d: Push Sensor Config (Optional)

```bash
adb shell mkdir -p /sdcard/poc_sensor/
echo '{"accelX":0.1,"accelY":9.5,"accelZ":2.5,"gyroX":0,"gyroY":0,"gyroZ":0,"jitter":0.15}' > /tmp/sensor.json
adb push /tmp/sensor.json /sdcard/poc_sensor/config.json
```

At minimum, you need `/sdcard/poc_frames/` with content for the overlay to appear.

---

## Step 6: Launch and Verify

### 6a: Start Logcat Monitoring

Open a separate terminal and start monitoring:

```bash
adb logcat -s FrameInterceptor HookEngine ActivityLifecycleHook OverlayController LocationInterceptor SensorInterceptor FrameStore
```

Leave this running.

### 6b: Launch the App

```bash
adb shell am start -n com.poc.biometric/com.poc.biometric.ui.LauncherActivity
```

Or, if you don't know the launcher activity:

```bash
adb shell monkey -p com.poc.biometric -c android.intent.category.LAUNCHER 1
```

### 6c: Verify the Overlay

Look at the emulator screen. You should see a **lightning bolt icon** in the top-right corner of the app. This is the overlay control button. Its presence confirms:

1. The patched `Application.onCreate()` fired.
2. `HookEngine.init()` bootstrapped successfully.
3. `ActivityLifecycleCallbacks` registered and attached the overlay to the current Activity.
4. At least one payload directory has content.

Tap the lightning bolt. A menu should appear with access to three modules:

- **Frame Injection** -- shows the frame source, delivery count, and toggle
- **Location Injection** -- shows coordinates and toggle
- **Sensor Injection** -- shows sensor config and toggle

If all three payload directories have content, all three modules should show as armed.

### 6d: Verify via Logcat

Switch to the logcat terminal. Look for these key messages:

```text
HookEngine: init() called
ActivityLifecycleHook: registered
OverlayController: attached to activity
FrameInterceptor: armed, N sources available
```

If you pushed location and sensor configs, also look for:

```text
LocationInterceptor: armed
SensorInterceptor: armed
```

---

## Step 7: Capture Evidence

```bash
# Screenshot with overlay visible
adb exec-out screencap -p > lab2-overlay.png

# Screenshot with overlay menu open (tap the lightning bolt first)
adb exec-out screencap -p > lab2-menu.png

# Save logcat dump
adb logcat -s FrameInterceptor HookEngine ActivityLifecycleHook OverlayController -d > lab2-logcat.txt
```

---

## Self-Check

```bash
echo "=== Lab 2 Self-Check ==="

# Check 1: patched APK exists
[ -f patched.apk ] && echo "[PASS] patched.apk exists" || echo "[FAIL] patched.apk not found"

# Check 2: patch output shows success
grep -q "APK patched successfully\|Injected.*runtime" patch_output.txt 2>/dev/null \
  && echo "[PASS] Patch completed successfully" \
  || echo "[FAIL] patch_output.txt missing or patch failed"

# Check 3: at least one hook was applied
HOOKS=$(grep -c '^\[+\]' patch_output.txt 2>/dev/null || echo 0)
[ "$HOOKS" -gt 0 ] && echo "[PASS] $HOOKS hooks applied" || echo "[FAIL] No hooks applied"

# Check 4: app is installed
adb shell pm list packages | grep -q "com.poc.biometric" \
  && echo "[PASS] com.poc.biometric installed" \
  || echo "[FAIL] com.poc.biometric not installed"

# Check 5: lifecycle hook registered
adb logcat -d -s HookEngine ActivityLifecycleHook | grep -qi "registered\|init" \
  && echo "[PASS] Lifecycle hook registered" \
  || echo "[FAIL] Lifecycle hook not found (launch the app first)"

# Check 6: evidence captured
[ -f lab2-overlay.png ] && echo "[PASS] Overlay screenshot captured" || echo "[FAIL] lab2-overlay.png not found"
[ -f patch_output.txt ] && echo "[PASS] Patch output saved" || echo "[FAIL] patch_output.txt not found"
```

---

## Deliverables

- [ ] **`patch_output.txt`** -- full patch-tool console output
- [ ] **Cross-reference table** -- recon predictions vs. actual patch output, all matching
- [ ] **`lab2-overlay.png`** -- screenshot of the app with overlay visible
- [ ] **`lab2-menu.png`** -- screenshot of the overlay menu showing all three modules
- [ ] **`lab2-logcat.txt`** -- logcat dump showing bootstrap messages

---

## Success Criteria

- [ ] Patch-tool completed without `[-]` errors
- [ ] 1,134 runtime classes injected into `smali_classes7/`
- [ ] Application class correctly detected and patched
- [ ] CameraX hooks fired: `analyze()`, `toBitmap()`, `onCaptureSuccess()`
- [ ] Camera2 hooks skipped with `[!]` warnings (expected for this target)
- [ ] Cross-reference table complete -- all predictions match
- [ ] Patched APK installed successfully
- [ ] Overlay (lightning bolt) visible in the app
- [ ] Overlay menu shows three modules
- [ ] Logcat confirms bootstrap messages
- [ ] Self-check script reports 0 failures

---

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| Overlay does not appear | No payload files on device | Push frames to `/sdcard/poc_frames/` |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | Different signature than installed version | `adb uninstall com.poc.biometric` first |
| "already patched" in logcat | APK was previously patched | Normal -- idempotent behavior |
| "SurfaceViewImplementation" warning | CameraX internal message | Harmless -- ignore |
| App crashes on launch | Missing permissions or API mismatch | Check `adb logcat` unfiltered for the exception |

---

## What You Just Demonstrated

You took the recon intelligence from Lab 1, fed it through the patch-tool, and verified that the tool's behavior matched your predictions exactly. You deployed a patched APK containing 1,134 injected classes, granted the permissions it needs, armed the payload directories, and confirmed that the injection runtime bootstrapped correctly. The overlay is live. The interceptors are armed. The app is running normally -- the user experience is identical to the original -- but every camera frame, every GPS coordinate, and every sensor reading now passes through your hooks first.

The next step is feeding the machine. Lab 3 puts real payloads through the camera injection pipeline.
