---
title: "Lab 3: Camera Injection"
description: "Replace the live camera feed with pre-recorded frames and pass face detection"
---

**Prerequisites:** Lab 2 complete (patched APK deployed, overlay verified). Chapter 7 (Camera Injection) read.
**Estimated time:** 40 minutes.
**Chapter reference:** Chapter 7 -- Camera Injection.

This lab has two exercises. Exercise 3A injects face frames into the camera pipeline and gets ML Kit to detect a face that is not physically in front of the camera. Exercise 3B injects a QR code image and gets the barcode scanner to decode it. Together, they demonstrate that you control what the camera sees -- any image, any format, any content -- and the app processes it as if it came from real camera hardware.

Both exercises use the patched APK from Lab 2. If you have not completed Lab 2, go back and finish it. The patched APK must be installed, permissions must be granted, and the overlay must be functional.

All commands assume you are working from the project root.

---

## Exercise 3A: Face Injection

### Objective

Inject pre-recorded face frames into the camera feed so that Google ML Kit detects a face, draws a bounding box, and processes the injected frames as if a real person were holding the phone.

### Step 1: Prepare Face Frames

You need a sequence of face frames -- PNG images at 640x480 resolution showing a human face. The course does not distribute face images for privacy reasons. You must generate your own.

**Option A: Extract from a selfie video (recommended)**

Record a 3-5 second selfie video on any device. Transfer it to your workstation. Then extract frames:

```bash
mkdir -p face_frames/face_neutral
ffmpeg -i selfie.mp4 -vf "fps=15,scale=640:480" face_frames/face_neutral/%03d.png
```

This produces 45-75 PNG frames at 15fps. The face should be roughly centered, well-lit, and frontal or near-frontal. ML Kit is tolerant of moderate variation in angle and lighting, but extremely dark or heavily rotated faces will fail detection.

**Option B: Use a single face image**

If you have a clear frontal face photograph (your own or an AI-generated face):

```bash
mkdir -p face_frames/face_neutral
ffmpeg -i face_photo.jpg -vf "scale=640:480" face_frames/face_neutral/001.png
```

A single frame will loop -- the same image repeats on every callback. This passes basic face detection but will fail any active liveness check that expects motion (blinking, head turns). For this lab, a single frame is sufficient to demonstrate injection and ML Kit detection.

**Option C: Generate a synthetic test frame**

If you want to verify the pipeline without any face at all, you can use the gray test frames from Lab 2. ML Kit will not detect a face, but you will still see the injection pipeline operating in logcat. This is useful for confirming the mechanics before introducing real face data.

### Step 2: Push Frames to the Device

```bash
adb shell mkdir -p /sdcard/poc_frames/face_neutral/
adb push face_frames/face_neutral/ /sdcard/poc_frames/face_neutral/
```

Verify the frames arrived:

```bash
adb shell ls /sdcard/poc_frames/face_neutral/ | head -5
adb shell ls /sdcard/poc_frames/face_neutral/ | wc -l
```

You should see your PNG files listed and a count matching the number of frames you generated.

### Step 3: Restart the App

The `FrameInterceptor` scans payload directories on startup. If the app is already running from Lab 2, force-stop and relaunch:

```bash
adb shell am force-stop com.poc.biometric
adb shell monkey -p com.poc.biometric -c android.intent.category.LAUNCHER 1
```

### Step 4: Start Logcat Monitoring

In a separate terminal:

```bash
adb logcat -s FrameInterceptor FrameStore HookEngine
```

### Step 5: Observe the Injection

Navigate through the app to the camera screen (the face capture or selfie verification screen). What you observe depends on which frames you prepared:

**With real face frames:**
- The camera preview shows your injected face frames, not the live camera feed.
- ML Kit detects the face and draws a bounding box around it.
- The bounding box tracks the face position across frames.
- If the app has quality checks (face centered, face large enough, eyes open), they pass.

**With a single face image:**
- The preview shows the same face on every frame.
- ML Kit detects the face and draws a static bounding box.
- The app may report the face as detected but fail liveness checks that require motion.

**With gray test frames:**
- The preview shows a gray rectangle.
- ML Kit finds no face. Any face detection step fails.
- But the injection pipeline is confirmed working -- logcat shows frame delivery.

### Step 6: Verify via Logcat

In the logcat output, look for these patterns:

```text
FrameStore: loaded N frames from /sdcard/poc_frames/face_neutral/
FrameInterceptor: armed, source: face_neutral
FrameInterceptor: FRAME_DELIVERED [frame 1/N]
FrameInterceptor: FRAME_CONSUMED
FrameInterceptor: intercept swapped ImageProxy
```

Key signals:

- **`FRAME_DELIVERED`** -- The interceptor replaced the real camera frame with your injected frame. This fires on every `analyze()` callback, typically 15-30 times per second.
- **`FRAME_CONSUMED`** -- The app's code processed the injected frame (called `close()` on the FakeImageProxy).
- **`intercept swapped ImageProxy`** -- Confirms the FakeImageProxy was substituted for the real one.

If you see `FRAME_DELIVERED` but not `FRAME_CONSUMED`, the app received the frame but something in its processing pipeline rejected it. Check the frame dimensions (must be 640x480 or match what the app expects) and format.

### Step 7: Capture Evidence

With ML Kit drawing a bounding box on the injected face:

```bash
adb exec-out screencap -p > lab3a-face-injection.png
```

This screenshot shows that ML Kit processed your injected frames and detected a face. The bounding box is the proof -- it means the ML model ran inference on your data and found a face where there is no physical face in front of the camera.

Save the logcat output:

```bash
adb logcat -s FrameInterceptor FrameStore -d > lab3a-logcat.txt
```

### Exercise 3A Self-Check

```bash
#!/usr/bin/env bash
# lab3a-selfcheck.sh

PASS=0
FAIL=0

echo ""
echo "=========================================="
echo "  LAB 3A: FACE INJECTION SELF-CHECK"
echo "=========================================="
echo ""

# Check frames exist on device
FRAME_COUNT=$(adb shell "ls /sdcard/poc_frames/face_neutral/*.png 2>/dev/null | wc -l" | tr -d '[:space:]')
if [ "$FRAME_COUNT" -gt 0 ]; then
    echo "  [PASS] Face frames on device: $FRAME_COUNT PNG(s)"
    ((PASS++))
else
    echo "  [FAIL] No face frames found at /sdcard/poc_frames/face_neutral/"
    ((FAIL++))
fi

# Check logcat for frame delivery
DELIVERED=$(adb logcat -d -s FrameInterceptor 2>/dev/null | grep -c "FRAME_DELIVERED")
if [ "$DELIVERED" -gt 0 ]; then
    echo "  [PASS] Frame delivery confirmed: $DELIVERED FRAME_DELIVERED events"
    ((PASS++))
else
    echo "  [FAIL] No FRAME_DELIVERED in logcat -- injection may not be active"
    ((FAIL++))
fi

# Check logcat for intercept swap
SWAPPED=$(adb logcat -d -s FrameInterceptor 2>/dev/null | grep -c "intercept swapped")
if [ "$SWAPPED" -gt 0 ]; then
    echo "  [PASS] ImageProxy swap confirmed: $SWAPPED swaps"
    ((PASS++))
else
    echo "  [FAIL] No intercept swaps in logcat"
    ((FAIL++))
fi

# Check screenshot exists
if [ -f "lab3a-face-injection.png" ]; then
    echo "  [PASS] Screenshot captured: lab3a-face-injection.png"
    ((PASS++))
else
    echo "  [FAIL] Screenshot not found -- capture with adb screencap"
    ((FAIL++))
fi

echo ""
echo "=========================================="
echo "  Results: $PASS passed, $FAIL failed"
echo "=========================================="
echo ""
```

### Exercise 3A Success Criteria

- [ ] Face frames generated (from video, photo, or synthetic) at 640x480 resolution
- [ ] Frames pushed to `/sdcard/poc_frames/face_neutral/` on the device
- [ ] App relaunched after pushing frames
- [ ] Camera preview shows injected frames (not the live camera feed)
- [ ] ML Kit draws a bounding box on the injected face (with real face frames)
- [ ] Logcat shows `FRAME_DELIVERED` events
- [ ] Logcat shows `intercept swapped ImageProxy`
- [ ] Screenshot captured showing bounding box on injected face

---

## Exercise 3B: Barcode Injection

### Objective

Inject a QR code image into the camera feed so that the barcode scanner decodes it and displays the encoded payload. This demonstrates that camera injection works for any image processing pipeline, not just face detection.

### Step 1: Generate a QR Code Image

Create a QR code encoding the text `HOOKENGINE_BYPASS`:

```bash
# Using Python (pip install qrcode pillow)
python3 -c "
import qrcode
img = qrcode.make('HOOKENGINE_BYPASS')
img = img.resize((640, 480))
img.save('qr_hookengine.png')
"
```

Or using an online QR generator: create a QR code for the text `HOOKENGINE_BYPASS`, download the image, and resize it to 640x480:

```bash
ffmpeg -i downloaded_qr.png -vf "scale=640:480" qr_hookengine.png
```

Or using `zbarimg` and ImageMagick if you prefer staying in the terminal:

```bash
# Generate with qrencode (brew install qrencode)
qrencode -o qr_hookengine_raw.png -s 10 "HOOKENGINE_BYPASS"
# Resize to camera dimensions
ffmpeg -i qr_hookengine_raw.png -vf "scale=640:480" qr_hookengine.png
```

### Step 2: Push the QR Code to the Device

```bash
adb shell mkdir -p /sdcard/poc_frames/barcode/
adb push qr_hookengine.png /sdcard/poc_frames/barcode/001.png
```

A single image is sufficient -- the barcode scanner only needs one clean frame to decode the QR code.

### Step 3: Switch Frame Source

You have two options for switching the frame source:

**Option A: Use the overlay (recommended)**

If the app is already running with the face_neutral source from Exercise 3A:

1. Tap the lightning bolt icon.
2. Open the Frame Injection panel.
3. Tap the `barcode` folder to switch the frame source.

The `FrameStore` hot-reloads from the new directory. No app restart needed.

**Option B: Restart the app**

If the overlay switching is not available, or if you want a clean start:

```bash
# Remove the face frames (or just clear them from the active source)
adb shell rm -rf /sdcard/poc_frames/face_neutral/

# Verify only barcode source remains
adb shell ls /sdcard/poc_frames/

# Restart the app
adb shell am force-stop com.poc.biometric
adb shell monkey -p com.poc.biometric -c android.intent.category.LAUNCHER 1
```

### Step 4: Navigate to the Scanner

Open the barcode/QR scanning feature in the app. The camera should display the QR code image instead of the live camera feed.

### Step 5: Observe the Decode

The barcode scanner should:

1. Detect the QR code in the injected frame.
2. Decode the content.
3. Display `HOOKENGINE_BYPASS` as the scanned result.

This happens within 1-2 seconds of the scanner opening, because the QR code is immediately present in every frame. No need to hold a phone up to a real QR code -- the scanner sees your injected image on every callback.

### Step 6: Verify via Logcat

```bash
adb logcat -s FrameInterceptor FrameStore -d | tail -20
```

You should see:

```text
FrameStore: loaded 1 frames from /sdcard/poc_frames/barcode/
FrameInterceptor: armed, source: barcode
FrameInterceptor: FRAME_DELIVERED [frame 1/1]
```

The frame count is `1/1` because there is only one image. It delivers the same frame on every callback until the scanner successfully decodes it.

### Step 7: Capture Evidence

```bash
adb exec-out screencap -p > lab3b-barcode-injection.png
```

The screenshot should show the QR code visible on the camera preview and/or the decoded result `HOOKENGINE_BYPASS` displayed by the app.

### Exercise 3B Self-Check

```bash
#!/usr/bin/env bash
# lab3b-selfcheck.sh

PASS=0
FAIL=0

echo ""
echo "=========================================="
echo "  LAB 3B: BARCODE INJECTION SELF-CHECK"
echo "=========================================="
echo ""

# Check QR code exists on device
QR_EXISTS=$(adb shell "ls /sdcard/poc_frames/barcode/*.png 2>/dev/null | wc -l" | tr -d '[:space:]')
if [ "$QR_EXISTS" -gt 0 ]; then
    echo "  [PASS] QR code image on device"
    ((PASS++))
else
    echo "  [FAIL] No QR code at /sdcard/poc_frames/barcode/"
    ((FAIL++))
fi

# Check frame delivery for barcode source
DELIVERED=$(adb logcat -d -s FrameInterceptor 2>/dev/null | grep "barcode" | grep -c "FRAME_DELIVERED")
if [ "$DELIVERED" -gt 0 ]; then
    echo "  [PASS] Barcode frame delivery confirmed"
    ((PASS++))
else
    echo "  [FAIL] No barcode frame delivery in logcat"
    ((FAIL++))
fi

# Check screenshot
if [ -f "lab3b-barcode-injection.png" ]; then
    echo "  [PASS] Screenshot captured: lab3b-barcode-injection.png"
    ((PASS++))
else
    echo "  [FAIL] Screenshot not found"
    ((FAIL++))
fi

echo ""
echo "=========================================="
echo "  Results: $PASS passed, $FAIL failed"
echo "=========================================="
echo ""
```

### Exercise 3B Success Criteria

- [ ] QR code image generated encoding `HOOKENGINE_BYPASS`
- [ ] QR code pushed to `/sdcard/poc_frames/barcode/` on the device
- [ ] Frame source switched to barcode (via overlay or restart)
- [ ] Scanner displays the QR code image (not the live camera)
- [ ] Scanner decodes and displays `HOOKENGINE_BYPASS`
- [ ] Logcat confirms frame delivery from barcode source
- [ ] Screenshot captured showing decoded result

---

## Combined Self-Check

Run this after completing both exercises:

```bash
#!/usr/bin/env bash
# lab3-selfcheck.sh

PASS=0
FAIL=0

echo ""
echo "=========================================="
echo "  LAB 3: CAMERA INJECTION SELF-CHECK"
echo "=========================================="
echo ""

echo "--- Exercise 3A: Face Injection ---"

FACE_FRAMES=$(adb shell "ls /sdcard/poc_frames/face_neutral/*.png 2>/dev/null | wc -l" | tr -d '[:space:]')
if [ "$FACE_FRAMES" -gt 0 ]; then
    echo "  [PASS] Face frames on device: $FACE_FRAMES"
    ((PASS++))
else
    echo "  [FAIL] No face frames on device"
    ((FAIL++))
fi

FACE_DELIVERY=$(adb logcat -d -s FrameInterceptor 2>/dev/null | grep -c "FRAME_DELIVERED")
if [ "$FACE_DELIVERY" -gt 0 ]; then
    echo "  [PASS] Frame delivery events: $FACE_DELIVERY"
    ((PASS++))
else
    echo "  [FAIL] No frame delivery events in logcat"
    ((FAIL++))
fi

if [ -f "lab3a-face-injection.png" ]; then
    echo "  [PASS] Face injection screenshot captured"
    ((PASS++))
else
    echo "  [FAIL] Face injection screenshot missing"
    ((FAIL++))
fi

echo ""
echo "--- Exercise 3B: Barcode Injection ---"

QR_EXISTS=$(adb shell "ls /sdcard/poc_frames/barcode/*.png 2>/dev/null | wc -l" | tr -d '[:space:]')
if [ "$QR_EXISTS" -gt 0 ]; then
    echo "  [PASS] QR code on device"
    ((PASS++))
else
    echo "  [FAIL] No QR code on device"
    ((FAIL++))
fi

if [ -f "lab3b-barcode-injection.png" ]; then
    echo "  [PASS] Barcode injection screenshot captured"
    ((PASS++))
else
    echo "  [FAIL] Barcode injection screenshot missing"
    ((FAIL++))
fi

echo ""
echo "=========================================="
echo "  Results: $PASS passed, $FAIL failed"
echo "=========================================="

if [ "$FAIL" -eq 0 ]; then
    echo ""
    echo "  CAMERA INJECTION VERIFIED. You are ready for Lab 4."
    echo ""
else
    echo ""
    echo "  FIX FAILURES BEFORE CONTINUING."
    echo ""
fi
```

---

## Deliverables

1. **Face frames** -- the PNG sequence you generated (or a note on how you generated them)
2. **QR code image** -- the PNG encoding `HOOKENGINE_BYPASS`
3. **Screenshot 3A** (`lab3a-face-injection.png`) -- ML Kit bounding box on injected face
4. **Screenshot 3B** (`lab3b-barcode-injection.png`) -- scanner showing `HOOKENGINE_BYPASS`
5. **Logcat dumps** -- `lab3a-logcat.txt` showing `FRAME_DELIVERED` and `intercept swapped`
6. **Self-check output** -- combined self-check showing all checks passed

---

## Troubleshooting

**Preview shows the live camera, not injected frames:**
- The `FrameInterceptor` is not armed. Check logcat for `FrameInterceptor: armed`. If absent, the payload directory is empty or the path is wrong.
- Force-stop and relaunch the app. The interceptor scans directories on startup.
- Verify the push: `adb shell ls /sdcard/poc_frames/face_neutral/`. PNG files must be present.

**ML Kit does not draw a bounding box:**
- The injected face is too small, too dark, or at an extreme angle. ML Kit needs a clearly visible frontal face. Try a different source image with better lighting and a centered face.
- If using gray test frames, ML Kit will correctly report "no face found." That is expected.

**Frame delivery rate is very low:**
- The emulator camera may be running at a low framerate. This is an emulator limitation, not an injection issue. On a physical device, frame rates will be higher.

**App crashes when opening the camera:**
- Check permissions: `adb shell pm grant com.poc.biometric android.permission.CAMERA`
- Check logcat for the exception. `SecurityException` usually means a missing permission.

**QR code is not decoded:**
- The QR code image may be too small within the 640x480 frame. Ensure the QR code fills a significant portion of the frame. If you resized from a tiny source image, the QR code may be unreadable after scaling.
- Try regenerating at a larger size before resizing to 640x480.

**`FrameStore: 0 files loaded`:**
- The directory exists but contains no PNG files. Verify filenames end in `.png` (lowercase). The FrameStore scans for PNG files specifically.

---

## What You Just Demonstrated

You replaced the live camera feed with arbitrary images and the app could not tell the difference. ML Kit ran its face detection model on your injected frames and returned face bounding boxes, landmark positions, and classification scores -- all derived from data you chose to provide. The barcode scanner decoded a QR code that was never physically present in front of the camera. Both operations happened at the API boundary, below the app's logic, below the SDK's processing -- at the exact point where Android delivers camera data to the application.

This is the core capability of the toolkit. Everything the app sees through the camera is under your control. In a real engagement, the face frames would be sequenced for liveness challenges (blinking, turning, nodding), the barcode payloads would target specific workflows (document QR codes, payment tokens), and the frame sources would be switched mid-flow via the overlay to handle multi-step verification. Lab 4 adds the second dimension -- GPS coordinate spoofing -- and Lab 5 adds the third -- sensor data injection. Lab 6 brings all three together in a full engagement simulation.
