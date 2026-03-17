---
title: "Camera Injection"
description: "Replacing live camera feeds with pre-recorded frames to bypass face detection and liveness checks"
---

This is the core capability. Everything else in the toolkit -- location spoofing, sensor injection -- is supporting fire. Important, sometimes essential for passing multi-factor checks, but ultimately secondary. Camera frame injection is the primary weapon. It is the capability that lets you feed a synthetic face into a liveness check, a fabricated ID document into an OCR scanner, a QR code containing arbitrary data into a barcode reader. You replace what the camera sees with whatever you want, whenever you want.

What makes this fundamentally different from screen overlays, virtual cameras, or video loopback tools: the hooks do not modify the camera hardware. They do not interfere with Android's camera stack. They do not create a virtual camera device. They sit between the camera and the app's code -- at the API boundary, in the method calls the app already makes -- and swap the data in transit. The app calls `analyze()` and it gets a `FakeImageProxy`. It calls `toBitmap()` and it gets your frame. It calls `getPlanes()` and it gets your frame converted to YUV. It calls `getImage()` and it gets a `FakeImage` with your plane data. Every access path returns your data.

The app does not know. The SDK does not know. Google ML Kit and other commercial liveness SDKs -- they all process what they receive through standard Android camera APIs. And what they receive is what you chose to give them. As far as any code in the process is concerned, a real person is holding a real phone and a real camera is looking at a real face.

This chapter teaches you how the injection works at a technical level, how to prepare frames that pass detection, and how to operate the injection against live targets. By the end, you will have the skills to bypass any camera-based verification that processes frames through the standard Android camera APIs.

> **Ethics Note:** Camera injection can bypass biometric verification. Use only synthetic face data (your own or AI-generated) and only against authorized targets. Never use photographs of real people without consent. The techniques described in this chapter are powerful and can cause real harm if misused. Authorization and scope must be established before any engagement. If you skipped Chapter 2, go back and read it now.

---

## How Android Cameras Deliver Frames

You do not need to understand the entire Android camera subsystem to use this toolkit. But you need to understand enough to know why the injection is invisible to the app, and what can go wrong when it is not.

The camera hardware produces raw image data. Android's camera framework reads that data, processes it (auto-exposure, auto-focus, white balance), and wraps each processed frame in a container object. The app never touches raw sensor output. It receives a wrapped object and extracts image data from it through a defined API.

The key abstraction is `ImageProxy`. This is CameraX's wrapper around a camera frame. When an app uses CameraX for image analysis -- which is the majority of modern Android camera apps -- every frame arrives as an `ImageProxy` passed to the app's `Analyzer.analyze()` method. The `ImageProxy` exposes multiple ways to access the underlying pixel data:

- **`toBitmap()`** returns the frame as an Android `Bitmap` -- an ARGB pixel buffer suitable for display or image processing. This is what most SDKs use when they need to display the frame or run lightweight processing.

- **`getPlanes()`** returns the raw YUV color data as an array of `PlaneProxy` objects. Machine learning models often consume YUV data directly because it is closer to what the camera sensor produces and avoids the overhead of ARGB conversion.

- **`getImage()`** returns the underlying `android.media.Image` object, which provides its own `getPlanes()` method for native-level access. SDKs that call `InputImage.fromMediaImage()` -- including Google ML Kit -- go through this path.

- **`getWidth()` and `getHeight()`** return the frame dimensions. SDKs use these for coordinate mapping, bounding box calculations, and resolution validation.

The critical insight: the app does not verify where the data came from. It calls one or more of these methods, gets pixels back, and processes them. There is no authentication, no signature, no hardware attestation on individual frames. The API delivers data. The app trusts it.

> **What is YUV?** A color format used internally by cameras. Instead of storing Red/Green/Blue values per pixel, YUV stores brightness (Y) and two color-difference signals (U, V). It is more efficient for camera hardware and is the native format for most video processing. You never need to deal with YUV directly -- the toolkit handles all conversions automatically. But when you see "YUV" in logcat or documentation, that is what it means.

---

## The CameraX Injection Pipeline

CameraX is Google's recommended camera library and the one you will encounter in the vast majority of modern targets. Understanding the normal flow and the hooked flow is essential for troubleshooting and for knowing exactly what happens when your injection fires.

### Normal flow

```text
Camera hardware
  -> Android camera framework (auto-exposure, auto-focus, etc.)
  -> ImageReader (internal buffer)
  -> ImageProxy (wraps the frame)
  -> App's Analyzer.analyze(imageProxy)
     -> imageProxy.toBitmap()   -> SDK processes the Bitmap
     -> imageProxy.getPlanes()  -> SDK processes raw YUV data
     -> imageProxy.getImage()   -> SDK processes the native Image
```

The app implements `ImageAnalysis.Analyzer`, a single-method interface with `analyze(ImageProxy imageProxy)`. CameraX calls this method on every analysis frame -- typically 15 to 30 times per second. The app extracts the image data through whichever access method its SDK prefers and processes it: face detection, barcode scanning, OCR, liveness analysis.

### Hooked flow

```text
Camera hardware
  -> ImageReader
  -> ImageProxy (real -- from the actual camera)
        |
        v
  FrameInterceptor.intercept(imageProxy)
        |
        v
  FakeImageProxy (wraps original, replaces all data)
    .toBitmap()    -> returns YOUR frame as Bitmap
    .getPlanes()   -> returns YOUR frame as fake YUV planes
    .getImage()    -> returns FakeImage with YOUR frame's planes
    .getWidth()    -> matches original resolution
    .getHeight()   -> matches original resolution
        |
        v
  App's Analyzer.analyze(fakeImageProxy)
  -> every method the SDK calls returns YOUR data
```

The patch-tool inserts a call at the top of the app's `analyze()` method. Before any of the app's original code runs, `FrameInterceptor.intercept()` fires. It receives the real `ImageProxy`, creates a `FakeImageProxy` containing your frame, and the `FakeImageProxy` is what gets passed to the rest of the method. The app's code runs exactly as the developer wrote it. It just operates on different data.

### The FakeImageProxy stack

Three classes work together to make injection transparent to every SDK access pattern:

**`FakeImageProxy`** implements the `ImageProxy` interface. It takes the original ImageProxy (for metadata) and your Bitmap (for data). Every data-access method returns your frame:

| Method | Returns |
|--------|---------|
| `toBitmap()` | Your frame as a Bitmap |
| `getPlanes()` | Your frame converted to fake YUV plane data |
| `getImage()` | A `FakeImage` wrapping your frame's planes |
| `getWidth()` | Original ImageProxy width (resolution match) |
| `getHeight()` | Original ImageProxy height (resolution match) |
| `getFormat()` | Original ImageProxy format (format match) |
| `getImageInfo()` | Original ImageProxy metadata (timestamp, rotation) |
| `close()` | Closes the original ImageProxy (proper resource cleanup) |

**`FakeImage`** lives in the `android.media` package. This is deliberate and technically necessary: `android.media.Image` has a package-private constructor that can only be called from within the same package. By placing `FakeImage` in `android.media`, it can extend `Image` and call that constructor. Its `getPlanes()` returns `FakeImagePlane` objects containing your frame data as YUV_420_888.

**`FakeImagePlane`** also lives in `android.media` for the same package-private access reason. It extends `Image.Plane` and wraps a `ByteBuffer` containing your frame data with the correct pixel stride and row stride for YUV_420_888 format.

The YUV conversion pipeline runs like this: your Bitmap (ARGB format) is converted to an NV21 byte array, which is then wrapped in three `FakePlaneProxy` objects representing the Y, U, and V planes. These are what the SDK receives when it calls `getPlanes()` or when it obtains a `FakeImage` through `getImage()` and reads its planes. This handles SDKs that skip `toBitmap()` entirely and read raw plane data for model inference.

**`TimestampGenerator`** generates monotonically increasing nanosecond timestamps for each FakeImageProxy. SDKs that analyze frame delivery timing -- checking for unnaturally uniform intervals that might indicate injection -- see timestamps that look like a real camera feed. Each frame is slightly different, never exactly periodic. This is a small detail, but it matters against sophisticated liveness SDKs.

### What about the preview?

The camera preview -- what appears on screen -- is handled separately from the analysis pipeline. By default, the real camera still renders to the PreviewView. But the hooks cover the preview too.

For CameraX targets, a `BitmapSurfaceView` is overlaid on top of the PreviewView. Your injected frames render on screen. The person looking at the phone sees your frames. The SDK processing the analysis data also sees your frames. Everything is visually and logically consistent.

This matters for two reasons. First, if someone is watching the screen (a compliance officer during a supervised verification, for instance), the preview must match the analysis data. Second, some SDKs verify consistency between the preview and the analysis feed. With the overlay in place, both show the same thing.

---

## The Camera2 Injection Pipeline

Not all apps use CameraX. Older applications and those that need fine-grained camera control use Camera2, Android's lower-level camera API. Camera2 apps do not use `ImageProxy`. They use `Surface` objects for preview and `OnImageAvailableListener` for frame processing. The injection strategy is fundamentally different.

### The decoy surface technique

Camera2 preview works by binding a `Surface` to a camera capture session. The camera hardware writes frames directly into that Surface, and whatever view owns the Surface (usually a `TextureView`) displays them on screen. To inject frames into the preview, you need to redirect the camera away from the real display surface and draw your own frames into it.

```text
Normal Camera2 flow:
  Camera -> Surface(TextureView's SurfaceTexture) -> TextureView shows camera

Injected Camera2 flow:
  Camera -> Surface(DECOY SurfaceTexture) -> frames silently consumed, invisible
  Injected frames -> Surface(REAL SurfaceTexture) -> TextureView shows YOUR frames
```

When `new Surface(SurfaceTexture)` is called to set up the camera preview, `Camera2Interceptor.onSurfaceCreated()` intercepts it and runs through a precise sequence:

1. **Call-stack analysis.** The interceptor walks the stack trace looking for `android.hardware.camera2.*` or `androidx.camera.*` references. If the Surface is not being created for a camera -- if it is for ExoPlayer, a MapView, a GL renderer, or any other non-camera use -- it passes through untouched. This prevents breaking unrelated functionality in the target app.

2. **Captures the real SurfaceTexture.** The interceptor saves a reference to the TextureView's SurfaceTexture. This is where injected frames will be drawn.

3. **Creates a decoy.** A new `SurfaceTexture(0)` is built with `setDefaultBufferSize(640, 480)` and an `onFrameAvailableListener` that calls `updateTexImage()` to drain the buffer queue. Without this drain, the camera would stall after a few frames because its output buffer is full and nobody is consuming it.

4. **Returns the decoy Surface.** The camera binds to the decoy and renders its frames there. Nobody sees them.

5. **Draws injected frames to the real surface.** `SurfaceSwapper.drawFrame()` locks the real Surface's hardware canvas, draws your Bitmap scaled to fill, and posts it. The TextureView renders your frames natively, exactly as if they came from the camera.

### Frame processing hooks

For the analysis pipeline, Camera2 uses `OnImageAvailableListener.onImageAvailable(ImageReader reader)`. The app calls `reader.acquireLatestImage()` to get the frame, then processes it. The hook intercepts at the listener level and replaces the Bitmap that the processing pipeline receives with your injected frame. The mechanism is different from CameraX's `FakeImageProxy` approach, but the result is identical: the processing code receives your data.

### TextureView vs SurfaceView

Camera2 apps use one of two view types for preview:

**TextureView apps** use the decoy surface swap described above. The TextureView natively renders injected frames. Clean and seamless.

**SurfaceView apps** manage their own Surface internally, so the decoy swap does not work. Instead, `SurfaceHolderHookVisitorFactory` captures the Surface from `SurfaceHolder.getSurface()` and `SurfaceSwapper.drawFrame()` paints directly into it. The camera still renders real frames too, creating a visual flicker between real and injected frames. For the analysis pipeline, this does not matter -- the Bitmap hook handles that separately. But the preview looks rough. If the target uses SurfaceView and preview consistency matters, note this in your report.

### Secondary surface protection

Camera2 apps often create multiple Surfaces -- one for preview, one for recording, one for still capture. The SurfaceSwapper only intercepts the first `Surface(SurfaceTexture)` call. Subsequent Surfaces pass through untouched. This prevents breaking video recording or photo capture functionality in the target app. The injection is surgical: it replaces what needs replacing and leaves everything else alone.

---

## The Hook Points

Six hooks cover every camera path in Android:

| Hook | When it fires | What happens | API |
|------|--------------|--------------|-----|
| `analyze(ImageProxy)` | Every analysis frame (~15-30fps) | ImageProxy replaced with FakeImageProxy | CameraX |
| `toBitmap()` | SDK extracts Bitmap from ImageProxy | Bitmap replaced with injected frame | CameraX |
| `onCaptureSuccess(ImageProxy)` | App captures a still photo | ImageProxy replaced with FakeImageProxy | CameraX |
| `Surface(SurfaceTexture)` | Camera2 sets up preview | Surface swapped to decoy | Camera2 |
| `SurfaceHolder.getSurface()` | Camera2 gets preview surface | Surface captured for injection | Camera2 |
| `OnImageAvailableListener` | Camera2 frame available | Bitmap replaced with injected frame | Camera2 |

The first three are CameraX hooks. The last three are Camera2 hooks. Your recon (Chapter 5) told you which API the target uses. Those are the hooks that will fire.

In practice, most modern targets use CameraX. When you see `[+] Patched analyze()` in the patch-tool output and `[!] No Camera2 hooks found` as a warning, that is the normal case. The Camera2 hooks exist for the targets that need them, and they fire automatically when the target app makes Camera2 API calls.

---

## Preparing Your Frames

The frames you inject determine whether the bypass succeeds or fails. A perfect injection pipeline delivering bad frames still fails the verification. Frame preparation is an operational skill, not just a technical step.

### From video -- for liveness checks

Liveness SDKs expect movement. Blinking, head turns, nodding, smiling. A single static photo will fail any active liveness check. You need a frame sequence extracted from a video of someone performing the expected motions.

```bash
# Extract at 15fps, resize to 640x480
ffmpeg -i face_video.mp4 -vf "fps=15,scale=640:480" face_frames/%03d.png

# Extract a specific time range (seconds 2 through 5)
ffmpeg -i face_video.mp4 -ss 2 -to 5 -vf "fps=15,scale=640:480" face_frames/%03d.png

# Extract at original resolution (for higher-quality targets)
ffmpeg -i face_video.mp4 -vf "fps=15" face_frames/%03d.png
```

15fps is the sweet spot. Most analysis pipelines sample at 15-30fps. Extracting at 15 gives you enough frames for smooth motion without creating thousands of files. A 2-second clip at 15fps produces 30 frames -- enough for most liveness challenges.

### From images -- for document scans and static checks

Document OCR, barcode scanning, basic face detection without liveness -- these do not need motion. One frame is enough.

```bash
mkdir -p id_card
cp passport_photo.png id_card/001.png
```

The runtime cycles through available frames in alphabetical order. With one frame, it serves the same image every time. That is exactly what you want for a document scan or a QR code injection -- the processing logic receives a stable, consistent image on every analysis cycle.

### From MP4 directly -- the VideoFrameExtractor

If you do not want to extract frames to PNGs, push the video file directly:

```bash
adb push liveness_video.mp4 /sdcard/poc_frames/
```

The runtime uses `VideoFrameExtractor`, a hardware-accelerated video decoder built on `MediaCodec`. This is not `MediaMetadataRetriever` (which seeks frame-by-frame and is painfully slow). The extractor:

1. Probes the video with `MediaMetadataRetriever` for duration and FPS metadata.
2. Spins up a background decode thread using `MediaCodec` with H.264 hardware decoding.
3. Pre-decodes all frames into a `Bitmap[]` buffer, pre-scaled to the target resolution (default 480x640).
4. Plays back time-synced -- tracks elapsed nanoseconds since playback started and serves the frame that matches the current timestamp.
5. Loops automatically -- when it reaches the end, it resets to frame 0.

The decode happens on a background thread. For the first few seconds after launch, the overlay shows "buffering" while frames decode. Once the buffer is ready, frame delivery is instantaneous -- it is just an array index lookup.

Video requirements:
- H.264 codec in MP4 container. If your source uses a different codec, re-encode: `ffmpeg -i input.mp4 -c:v libx264 -preset fast output.mp4`
- Any resolution -- frames are pre-scaled to camera dimensions automatically
- Supported containers: `.mp4`, `.3gp`, `.mkv` (H.264 only)

### Quality requirements

Resolution and image quality directly affect whether the target SDK accepts your frames. Low-resolution, poorly lit, or badly positioned frames will fail face detection before liveness even enters the picture.

**Resolution.** Match the camera's output resolution as closely as practical. The runtime auto-scales frames to the camera's dimensions, but closer source resolution means cleaner scaling.

| Target resolution | When you see it |
|-------------------|-----------------|
| 640x480 | Front-facing camera analysis (most common for selfie KYC) |
| 1280x720 | Higher quality capture modes |
| 1920x1080 | Full-resolution capture, document scanning |

Aspect ratio matters more than exact pixel count. A 4:3 source for a 4:3 camera gives clean scaling without distortion. A 16:9 source scaled into a 4:3 frame stretches the face unnaturally, and face detection algorithms are sensitive to facial proportions.

**Face positioning.** The face should fill at least 30% of the frame for reliable detection. Most face detection SDKs have a minimum face size threshold -- typically around 100x100 pixels in the processed image. If your source face is too small in the frame, detection will fail before any liveness analysis runs.

**Lighting.** Even, diffuse lighting with no harsh shadows. Overexposed or underexposed frames trigger quality rejection in most SDKs. The SDK is looking for a face it can analyze, not a work of art -- but it needs enough contrast and detail to extract facial landmarks.

**Expression variety.** For active liveness, your frame sequence needs to show the specific expressions the SDK requests. A neutral-only sequence will fail a smile challenge. Plan your sequences around the liveness actions you identified during recon.

### Frame sequence design

Different liveness challenges require different motion patterns in your frame sequence:

| Liveness challenge | Frame sequence | Duration | Notes |
|-------------------|----------------|----------|-------|
| Passive (no action) | Neutral, slight natural sway | 1-2 seconds | Subtle motion preferred over perfect stillness |
| Smile | Neutral -> gradual smile -> hold -> neutral | 2-3 seconds | Transition matters more than the smile itself |
| Blink | Eyes open -> close -> open | 1 second | Needs to be fast -- real blinks are 100-400ms |
| Head tilt left | Center -> gradual tilt -> hold | 1.5 seconds | Smooth, continuous motion; about 15-20 degrees |
| Head tilt right | Mirror of tilt left | 1.5 seconds | Same angle range, opposite direction |
| Nod | Level -> slight downward -> back to level | 1.5 seconds | Small motion; large nods look unnatural |

For SDKs that cross-check visual motion against sensor data, you will need to pair these frame sequences with matching sensor configurations. Chapter 9 covers sensor injection, and Chapter 10 teaches the coordination between all three injection surfaces.

---

## Video vs PNG: When to Use Each

This is a practical decision that affects startup time, storage footprint, and frame delivery characteristics. Both approaches work. The right choice depends on the engagement.

| | Video (MP4) | Extracted PNGs |
|---|---|---|
| **Storage** | 1 file, compact (H.264 compression) | 30-200 files, larger total size |
| **Startup time** | Slow -- decode buffer must fill first | Instant -- PNGs load directly |
| **Runtime CPU** | Near-zero after buffer fills | Per-frame disk read and decode |
| **Frame timing** | Native FPS preserved from source video | Fixed cycle rate (frame-per-analysis-call) |
| **Switching** | Must swap the entire file | Can add/remove individual frames |
| **Best for** | Long liveness sequences with natural motion | Quick static injection, document scans, mixed flows |

**Use PNGs when:**
- You need instant injection on app launch (no buffering delay).
- You are switching between different frame sets mid-flow (face to document).
- You are injecting static content (one document image, one QR code).
- You want fine-grained control over individual frames in the sequence.

**Use video when:**
- You have a natural video of the required liveness actions and want to preserve the original motion timing.
- Storage space on the device is constrained.
- You are running long sequences (30+ seconds of liveness interaction).

For most engagements, extracted PNGs are the default choice. They are simpler, faster to start, and easier to debug. Video extraction via `VideoFrameExtractor` is the specialized path for when the native timing of the source video matters.

---

## Frame Delivery Mechanics

Understanding how frames cycle through the pipeline helps you diagnose issues and optimize delivery.

### The FrameInterceptor cycle

When injection is active, `FrameInterceptor` maintains a reference to the current frame source -- either a folder of PNGs or a decoded video buffer. On every `intercept()` call (triggered by CameraX's `analyze()` or Camera2's `OnImageAvailableListener`):

1. The interceptor checks whether injection is enabled. If not, the real frame passes through unmodified.
2. It requests the next frame from `FrameStore`. For PNG sources, this is the next file in alphabetical order. For video sources, this is the frame matching the current elapsed time.
3. The frame is loaded as a Bitmap (PNGs are decoded from disk; video frames are already in the pre-decoded buffer).
4. A `FakeImageProxy` is constructed using the loaded Bitmap and the original ImageProxy's metadata.
5. The FakeImageProxy replaces the original in the analysis pipeline.
6. The frame index advances. When it reaches the end of the sequence, it wraps to 0.

The default delivery target is 15fps. If the camera delivers frames faster than that, the interceptor serves the same cached frame on consecutive calls until the next 15fps interval. This prevents unnecessary frame decodes and keeps CPU usage low.

### Auto-enable on launch

The auto-enable mechanism is what makes headless operation possible. When the first `intercept()` or `transform()` call fires after app launch, the interceptor checks `/sdcard/poc_frames/` for content. If PNG files or video files exist, injection activates immediately. No overlay tap required. No human in the loop.

This is the mechanism that makes device farm testing work. Push your frames before launching the app, and injection is active from the first camera frame.

```bash
# Push frames
adb push face_neutral/ /sdcard/poc_frames/face_neutral/

# Launch the app -- injection activates automatically
adb shell am start -n com.poc.biometric/com.poc.biometric.ui.LauncherActivity
```

### The directory structure

Everything lives under `/sdcard/poc_frames/` on the device:

```text
/sdcard/poc_frames/
  +-- face_neutral/        <- folder of PNGs (neutral expression)
  |     +-- 001.png
  |     +-- 002.png
  |     +-- 003.png
  +-- face_smile/          <- another face set (smile liveness)
  |     +-- 001.png
  |     +-- 002.png
  +-- barcode/             <- QR code for scanner bypass
  |     +-- qr_payload.png
  +-- id_card/             <- document for OCR bypass
  |     +-- front.png
  +-- liveness.mp4         <- video file (auto-detected)
```

The rules:
- **Folders** containing `.png` files are image sources. Files are sorted alphabetically and cycled in order. Only `.png` files are loaded -- not jpg, not bmp, not webp.
- **`.mp4` files** in the root are video sources, decoded at runtime.
- The runtime auto-detects the source type.
- Subfolders are selectable via the overlay's folder browser, or the first one found alphabetically is used in headless mode.

---

## Worked Example: Bypassing ML Kit Face Detection

This is the most common scenario you will encounter. The target app uses Google ML Kit for face detection as the first gate in a KYC onboarding flow. ML Kit opens the front camera, runs face detection on every analysis frame, and draws a bounding box when it finds a face. Until a face is detected, the user cannot proceed.

You are going to make ML Kit detect a face that is not there.

### Step 1: Prepare the frames

Record a 2-second selfie video. Look directly at the camera with a neutral expression and allow slight natural movement -- do not hold perfectly still, as that looks unnatural to motion-analysis heuristics.

```bash
mkdir -p face_neutral
ffmpeg -i selfie_neutral.mp4 -vf "fps=15,scale=640:480" face_neutral/%03d.png
```

Verify the output:

```bash
ls face_neutral/ | wc -l
# Should show 25-30 files

file face_neutral/001.png
# Should show: PNG image data, 640 x 480
```

Each frame should show a face centered in the image, filling roughly a third of the frame area, in even lighting. If you do not have a selfie video available, you can generate solid-color test frames to verify the injection pipeline works, but ML Kit will not detect a face in a solid color -- you need actual face imagery for the detection to fire.

### Step 2: Patch and deploy

```bash
# Patch (from project root)
java -jar patch-tool.jar course-1/targets/target-kyc-basic.apk \
  --out patched.apk --work-dir ./work

# Install
adb uninstall com.poc.biometric 2>/dev/null
adb install -r patched.apk

# Grant permissions
adb shell pm grant com.poc.biometric android.permission.CAMERA
adb shell pm grant com.poc.biometric android.permission.READ_EXTERNAL_STORAGE
adb shell pm grant com.poc.biometric android.permission.WRITE_EXTERNAL_STORAGE
adb shell appops set com.poc.biometric MANAGE_EXTERNAL_STORAGE allow
```

Check the patch-tool output. You should see `[+] Patched analyze() in 1 method(s)` and `[+] Patched toBitmap()`. These confirm that the CameraX hooks are in place.

### Step 3: Push frames to the device

```bash
adb push face_neutral/ /sdcard/poc_frames/face_neutral/

# Verify they landed
adb shell ls /sdcard/poc_frames/face_neutral/ | head -5
```

### Step 4: Launch

```bash
adb shell am start -n com.poc.biometric/com.poc.biometric.ui.LauncherActivity
```

### Step 5: Verify via logcat

Open a separate terminal and watch the injection in real-time:

```bash
adb logcat -s FrameInterceptor
```

You are looking for these log lines:

```text
FrameInterceptor: Auto-enabled: frames found on disk
FrameInterceptor: intercept: swapped ImageProxy 640x480 fmt=35
FrameInterceptor: FRAME_DELIVERED face_neutral/003.png
FrameInterceptor: FRAME_CONSUMED
```

**"Auto-enabled: frames found on disk"** -- the interceptor found your PNGs on the first camera hook call and activated injection without any overlay interaction.

**"intercept: swapped ImageProxy 640x480 fmt=35"** -- a real camera frame was intercepted and replaced with a FakeImageProxy containing your data. `fmt=35` is the integer constant for `ImageFormat.YUV_420_888`. This line fires on every analysis frame, typically 15-30 times per second.

**"FRAME_DELIVERED"** -- a specific frame from your set was injected into the pipeline.

**"FRAME_CONSUMED"** -- the SDK accepted the frame and did not reject it. The ratio of DELIVERED to CONSUMED is your accept rate. For ML Kit face detection with good-quality face frames, expect 90% or higher.

### Step 6: Observe the result

On the device screen, you should see:
- The camera preview shows your injected face frames, not the emulator's virtual camera scene.
- ML Kit draws a green bounding box around the detected face in your injected frames.
- If the overlay is visible (tap the lightning bolt), it shows Frame Injection as ACTIVE with the frame count and cycling index.

The bounding box is the proof. ML Kit processed your injected frames through its face detection model, found a face, computed its bounding box coordinates, and drew the overlay. As far as ML Kit is concerned, it just detected a live face in the camera feed. It has no idea the "camera feed" is a sequence of PNGs loaded from the device's storage.

### Step 7: Capture evidence

```bash
adb exec-out screencap -p > face_injection_evidence.png
adb logcat -d -s FrameInterceptor > frame_delivery.log
```

The screenshot shows ML Kit's bounding box on your injected face. The log file shows every DELIVERED and CONSUMED event. Together, these constitute your evidence that the face detection gate was bypassed through frame injection.

### Why this works against ML Kit

ML Kit creates an `InputImage` from the camera frame via `InputImage.fromMediaImage(image, rotation)`. Here is the chain:

```text
SDK calls: imageProxy.getImage()
  -> returns FakeImage (your frame data as YUV planes)
  -> SDK passes FakeImage to InputImage.fromMediaImage()
  -> ML Kit reads the planes, converts to its internal format
  -> ML Kit's face detection model processes YOUR frame data
  -> ML Kit returns face detection results based on YOUR frame
```

The `FakeImage` is a fully valid `android.media.Image` instance. ML Kit has no additional validation beyond reading the planes and checking the format. If the planes contain YUV data encoding a face, ML Kit detects a face. The source of those planes is invisible to the SDK.

---

## Frame Quality Checklist

Before pushing frames to the device, run through this checklist. A single failed item can cause the target SDK to reject your frames even when the injection pipeline is working perfectly.

### Must-pass criteria

- [ ] **Format is PNG.** The runtime only loads `.png` files from image folders. JPEG, BMP, and WebP are silently ignored.
- [ ] **Resolution is 640x480 or higher.** Lower resolutions may fall below the SDK's minimum face size threshold.
- [ ] **Aspect ratio matches the camera.** 4:3 for most front-facing cameras. 16:9 sources will be stretched, distorting facial proportions.
- [ ] **Face is centered and fills 30%+ of the frame.** Small faces fail minimum-size detection thresholds.
- [ ] **Lighting is even.** No harsh shadows, no overexposure, no underexposure. The SDK needs visible facial features.
- [ ] **Background is neutral.** Busy backgrounds can confuse face detection, especially at lower resolutions.
- [ ] **Files are named for alphabetical ordering.** `001.png`, `002.png`, etc. The runtime sorts and cycles in order.

### Should-pass criteria for liveness

- [ ] **Sequence shows natural motion.** Perfectly static frames fail motion analysis. Include subtle sway or expression changes.
- [ ] **Transitions are smooth.** Abrupt jumps between frames (different lighting, position shifts) trigger anomaly detection.
- [ ] **Sequence includes the required actions.** If the SDK requests a smile, the sequence must contain a smile. If it requests a head tilt, the frames must show progressive tilt.
- [ ] **Frame count is sufficient.** 20-30 frames for a 2-second liveness check. Too few frames and the motion looks choppy.
- [ ] **No visible compression artifacts.** Heavy JPEG artifacts that were baked into the source will persist through conversion to PNG. Use high-quality sources.

### Common failures and fixes

| Symptom | Cause | Fix |
|---------|-------|-----|
| SDK reports "no face detected" | Face too small, too dark, or wrong angle | Re-record with face filling 30%+ of frame, even lighting |
| Liveness fails despite face detection | Static frames, no motion | Use video extraction at 15fps, ensure natural movement |
| Bounding box jitters wildly | Inconsistent face position between frames | Re-record with more stable head position |
| SDK rejects with "quality too low" | Resolution too low or heavy compression | Use 640x480+ source, avoid re-encoding through lossy codecs |
| Detection works but score is low | Partial occlusion, extreme angle, or poor lighting | Re-record with face directly facing camera, soft lighting |

---

## Switching Frames Mid-Flow

Real KYC flows are multi-step. The app asks for a selfie first (face frames), then asks you to scan your ID (document frames), then maybe a barcode or MRZ scan. You need to switch what the camera "sees" between steps without restarting the app or the injection.

### Via the overlay

The overlay's Frame Injection panel includes a folder browser that lists every subfolder and video file under `/sdcard/poc_frames/`. Tap a different folder to switch the frame source instantly. The next `intercept()` call serves a frame from the new source.

Typical multi-step flow:

1. App opens, face detection begins. Overlay shows `face_neutral/` as the active source. ML Kit detects a face. The app advances to the next step.
2. App asks for ID document. Tap the folder browser, select `id_card/`. The camera now "sees" your document image. OCR processes it.
3. App asks for a barcode. Select `barcode/`. The scanner decodes your QR code.

Each switch is instant. The frame index resets to 0 in the new source. No frames are dropped during the transition.

### Via adb (headless)

When operating without the overlay -- on a device farm, in a CI pipeline, or during automated testing -- you switch frames by replacing the files on disk:

```bash
# Phase 1: Face detection
adb push face_neutral/ /sdcard/poc_frames/face_neutral/

# ... app processes face frames ...

# Phase 2: Document scan -- clear old frames, push new ones
adb shell rm -rf /sdcard/poc_frames/*
adb push id_card/ /sdcard/poc_frames/id_card/
# New frames picked up on next intercept() cycle
```

The interceptor re-scans the directory on each frame request if the current source becomes empty. When you remove the old frames and push new ones, the next `intercept()` call discovers the new source and switches automatically.

There is a timing window here. Between the `rm -rf` and the `adb push`, the frame directory is empty. If an `intercept()` call fires during this window, the real camera frame passes through unmodified for that single cycle. In practice, this gap is a few hundred milliseconds and rarely matters. If timing is critical, push the new frames first (into a different subfolder), then remove the old ones. The interceptor will pick up the new subfolder on the next scan.

### Scripting a multi-step flow

For repeatable engagements, script the entire sequence:

```bash
#!/bin/bash
PKG="com.poc.biometric"
ACTIVITY="com.poc.biometric.ui.LauncherActivity"

# Phase 1: Push face frames and launch
adb push face_neutral/ /sdcard/poc_frames/face_neutral/
adb shell am start -n "$PKG/$ACTIVITY"
echo "Phase 1: Face detection active. Press Enter when app advances..."
read

# Phase 2: Switch to document
adb shell rm -rf /sdcard/poc_frames/face_neutral/
adb push id_card/ /sdcard/poc_frames/id_card/
echo "Phase 2: Document scan active. Press Enter when app advances..."
read

# Phase 3: Switch to barcode
adb shell rm -rf /sdcard/poc_frames/id_card/
adb push barcode/ /sdcard/poc_frames/barcode/
echo "Phase 3: Barcode scan active. Press Enter when complete..."
read

# Collect evidence
adb exec-out screencap -p > evidence_final.png
adb logcat -d -s FrameInterceptor > delivery.log
echo "Evidence collected."
```

This is not elegant, but it is reliable and reproducible. For device farm automation where no human is in the loop, replace the `read` prompts with `sleep` intervals calibrated to the target app's flow timing, or use `adb logcat` watchers to detect when each step completes.

---

## SDK Pipeline Compatibility

The injection operates below the SDK layer -- at the Android camera API boundary. This means the fundamental mechanism works regardless of which SDK the target embeds. But different SDKs access frame data through different paths, and understanding the compatibility picture helps you diagnose issues when a specific SDK is not behaving as expected.

### Google ML Kit

The most common case. ML Kit creates an `InputImage` from `ImageProxy.getImage()`, reads the YUV planes, and runs its face detection model. The `FakeImage` returned by the hooked `getImage()` is a valid `android.media.Image` with correctly formatted YUV_420_888 planes. ML Kit processes it without incident.

ML Kit's face detection is also the least demanding in terms of frame quality. It detects faces down to about 100x100 pixels, tolerates moderate lighting variation, and does not perform liveness analysis on its own. If your frames have a clearly visible face, ML Kit will find it.

### TensorFlow Lite / Custom Models

SDKs that run custom TFLite models typically follow one of two paths:

1. **From ImageProxy** -- calls `toBitmap()` or `getPlanes()`, both of which return your data through the FakeImageProxy.
2. **From Bitmap directly** -- extracts a Bitmap somewhere in the pipeline, which the `toBitmap()` hook covers.

If the SDK creates its own `ByteBuffer` from the ImageProxy planes for model inference, the fake YUV planes handle this correctly. The buffer layout matches real YUV_420_888 format -- same pixel stride, same row stride, same plane ordering.

### Commercial Active Liveness SDKs

Commercial active liveness SDKs are more demanding. They perform 3D face mapping, texture analysis, and active liveness challenges. They also monitor for hooking frameworks and check device integrity. The frame injection itself works -- these SDKs access frames through the same Android camera APIs -- but their quality thresholds are higher:

- Frames need higher resolution (720p minimum recommended).
- Motion must look natural across the frame sequence.
- Active liveness challenges require specific facial expressions timed to the SDK's prompts.
- Sensor data should correlate with observed visual motion (Chapter 9 covers this).

Passing advanced active liveness SDKs is possible but requires significantly more preparation than passing ML Kit.

### Server-Side Challenge-Response SDKs

Some advanced liveness SDKs use a server-side challenge-response protocol. The server sends a unique visual stimulus (a colored light sequence), the client captures the face under that stimulus, and the server verifies both liveness and the response to the specific challenge. This adds a layer that pure frame injection alone cannot address -- you would need to know the challenge in advance or generate frames that respond to the stimulus in real-time. This is at the edge of what static frame injection can accomplish.

### When injection does not work

Rare scenarios where frame injection fails entirely:

- **Hardware-level capture.** SDKs that bypass the Android camera API and read directly from the camera HAL. This requires system-level privileges and is extremely rare in commercial applications.
- **Depth sensing.** SDKs that use the depth camera (ToF sensor) in addition to the RGB camera. The depth stream is a separate sensor and is not hooked by the current toolkit.
- **Frame hash pinning.** A theoretical defense where the server generates expected frame hashes tied to a device attestation session. Not seen in the wild as of this writing, but architecturally possible.

---

## Monitoring Injection in Real Time

Logcat is your primary feedback channel during an engagement. The injection subsystem logs every significant event with the `FrameInterceptor` tag.

```bash
# Watch injection in real-time
adb logcat -s FrameInterceptor

# Filter for delivery events only
adb logcat -s FrameInterceptor | grep -E "DELIVERED|CONSUMED|intercept"

# Watch all injection subsystems simultaneously
adb logcat -s FrameInterceptor HookEngine ActivityLifecycleHook OverlayController
```

### Key log lines

**`"Auto-enabled: frames found on disk"`** -- Injection armed itself from the payload directory on the first camera hook call. This is the confirmation that headless mode is working.

**`"intercept: swapped ImageProxy 640x480 fmt=35"`** -- The `analyze()` hook fired. A real ImageProxy was replaced with a FakeImageProxy containing your data. This line fires on every analysis frame. If you see this, the primary injection path is active.

**`"transform: toBitmap 640x480"`** -- The `toBitmap()` hook fired. The SDK called `toBitmap()` on an ImageProxy and received your frame. Some SDKs hit both `analyze()` and `toBitmap()`. Seeing both is normal and expected.

**`"FRAME_DELIVERED"`** -- A frame was injected into the pipeline. The log line typically includes the source file name.

**`"FRAME_CONSUMED"`** -- The SDK accepted the frame. It was not rejected by quality checks, format validation, or any other SDK-level filter.

### Accept rate

The ratio of CONSUMED to DELIVERED events is your accept rate. Calculate it from the delivery log:

```bash
adb logcat -d -s FrameInterceptor > delivery.log
DELIVERED=$(grep -c "FRAME_DELIVERED" delivery.log)
CONSUMED=$(grep -c "FRAME_CONSUMED" delivery.log)
echo "Accept rate: $CONSUMED / $DELIVERED"
```

For ML Kit face detection with good frames, expect 90-100%. For liveness SDKs, expect lower -- perhaps 60-80% -- because some frames may fail quality thresholds or motion analysis on individual cycles. A consistently low accept rate (below 50%) indicates a frame quality problem, not a pipeline problem. Go back to the quality checklist.

---

## Troubleshooting

When injection is not working as expected, start with logcat. The logs tell you exactly where the pipeline breaks.

### "Frames: 0 loaded"

The runtime found no PNG files in the active frame source directory. Causes:

- Wrong path. Verify: `adb shell ls /sdcard/poc_frames/`. The files must be inside a subfolder or be `.mp4` files in the root.
- Wrong format. Only `.png` files are loaded from image folders. If you pushed JPEGs, convert them: `mogrify -format png *.jpg` (ImageMagick).
- Permission issue. Verify storage access: `adb shell appops set <package> MANAGE_EXTERNAL_STORAGE allow`.

### Preview shows real camera but logcat shows intercept events

The data injection is working -- the SDK is processing your frames -- but the preview overlay did not attach. This is cosmetic. The SDK received and processed your data regardless of what the preview shows. If preview consistency matters (for screenshots or supervised verification), check logcat for `BitmapSurfaceView` or `SurfaceSwapper` errors.

### SDK reports "no face detected" despite injection

The frames are being delivered but the face detection model does not find a face in them. This is a frame quality problem:

- Face is too small in the frame. Ensure it fills at least 30% of the image area.
- Lighting is too dark or too bright. Re-record with even, diffuse lighting.
- Face is at too extreme an angle. The face should be roughly facing the camera.
- Resolution is too low. Use 640x480 minimum.

Verify by checking the CONSUMED count in logcat. If DELIVERED is high but CONSUMED is near zero, the frames are being injected but the SDK is rejecting them at the processing level.

### Liveness check fails despite face detection passing

A single static frame cannot pass active liveness. You need a frame sequence showing the required motion. Common failures:

- Only one frame in the folder -- the SDK sees a frozen face.
- Frames extracted from a still image rather than a video -- no inter-frame motion.
- Wrong liveness action -- the SDK asked for a smile but your frames show a neutral expression.
- No sensor correlation -- the SDK checks that accelerometer data matches the observed visual motion, but no sensor injection is active. See Chapter 9.

### Video source will not load

Codec issue. The `MediaCodec` decoder is strict about codec support.

```bash
# Check the video codec
ffprobe -v error -show_streams liveness_video.mp4

# Re-encode as H.264 if needed
ffmpeg -i input.mp4 -c:v libx264 -preset fast output.mp4
```

### Frames look stretched or distorted

Aspect ratio mismatch between your source frames and the camera's output resolution. If the camera produces 4:3 frames (640x480) and your source is 16:9 (1280x720), the scaling distorts the image. Prepare source frames in the same aspect ratio as the target camera.

### App freezes when injection starts

Frame decode is too slow for the analysis rate. The camera delivers frames at 30fps, but loading and decoding large PNGs from disk cannot keep up. Solutions:

- Resize source frames to 640x480 before pushing. Smaller files decode faster.
- Use extracted PNGs instead of MP4 video (eliminates the buffering delay).
- If using video, trim to 5-10 seconds: `ffmpeg -i long.mp4 -ss 0 -to 10 -c copy short.mp4`.

### "Application.onCreate() already patched, skipping"

This appears when the APK was already patched in a previous run. It is safe and expected. The tool detects the existing bootstrap hook and skips re-injection to avoid duplicates. The patched APK works correctly.

---

## Operating the Injection

### Interactive mode -- with the overlay

For engagements where you have physical access to the device or can interact with the screen:

1. Launch the patched app.
2. Tap the lightning bolt icon (top-right corner).
3. Select "Frame Injection" from the menu.
4. Tap "ENABLE."
5. Use the folder browser to pick which frame set to inject.
6. Monitor the status panel in real time:
   - **Injection:** ACTIVE / INACTIVE
   - **Source:** folder name or video filename
   - **Frames:** count loaded
   - **Index:** current position in the cycle
   - **Preview:** Surface swap / Overlay / Detached

The overlay polls runtime state every 500ms. You see delivery counters increment live, accept rates update, and the frame index cycling through your sequence. This is your primary feedback loop during an interactive engagement.

### Headless mode -- no overlay, no touch

This is the mode for device farms, CI/CD pipelines, and any scenario where you cannot interact with the screen. Push frames before launching the app, and injection arms itself automatically:

```bash
# Push frames first
adb push face_neutral/ /sdcard/poc_frames/face_neutral/

# Then launch
adb shell am start -n com.poc.biometric/com.poc.biometric.ui.LauncherActivity

# Injection is active from the first camera frame
# Monitor via logcat
adb logcat -s FrameInterceptor
```

No overlay tap needed. No human in the loop. The auto-enable mechanism checks `/sdcard/poc_frames/` on the first `intercept()` call, finds your frames, and activates.

---

## Frame Delivery Rate

The runtime targets 15fps delivery by default. If the camera delivers analysis frames faster than 15fps, the interceptor serves the same cached frame on consecutive calls until the next 15fps boundary. This rate is sufficient for almost all analysis pipelines and prevents wasting CPU on redundant frame decodes.

For targets that verify delivery rate (checking that frames arrive at a natural cadence rather than an artificial fixed interval), the `TimestampGenerator` adds controlled jitter to each frame's timestamp. The timestamps increase monotonically but with realistic variation, mimicking the slight irregularities of a real camera feed.

If you encounter a target that samples at a higher rate and detects the 15fps delivery as anomalous (rare but possible), this is a signal that the target has unusually sophisticated frame analysis. Document it in your report as a finding -- it indicates the SDK is performing delivery-rate analysis as an anti-injection defense.

---

## What Comes Next

Camera injection gives you control over what the app sees. But many verification flows do not stop at the camera. They check where you are (GPS coordinates against a geofence) and how you are moving (accelerometer data correlated with visual motion).

Chapter 8 covers location spoofing -- feeding fake GPS coordinates to bypass geofencing while evading mock location detection. Chapter 9 covers sensor injection -- manipulating accelerometer and gyroscope data to produce motion readings that are physically consistent with what the camera "sees." And Chapter 10 brings all three together into a coordinated engagement against a multi-step verification target.

Lab 3 puts this chapter into practice. You will patch a target, prepare face frames, inject them into a CameraX analysis pipeline, make ML Kit detect a face that is not there, and capture the evidence. If you have not done it yet, open the lab and work through it now -- reading about camera injection is not the same as doing it.
