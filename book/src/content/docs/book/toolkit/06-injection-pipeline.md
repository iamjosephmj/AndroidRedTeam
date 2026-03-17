---
title: "The Injection Pipeline"
description: "How the patch-tool instruments APKs and the runtime architecture that powers all three injection subsystems"
---

You have done your recon. You know what the app uses -- which camera API, which location callbacks, whether sensors are in play. You have a map of every hook surface, a list of every SDK, a catalog of every defense. The intelligence picture is complete.

Now you weaponize it.

The patch-tool takes a stock APK -- signed by the developer, distributed through the Play Store, untouched and unmodified -- and turns it into an instrumented copy. One command. It decodes the APK into smali, injects 1,134 runtime classes into a new DEX slot, patches the target methods so they route through your interceptors, adds the storage permissions it needs to read payloads, rebuilds everything back into a valid APK, and signs it with a debug key. What comes out the other end looks and behaves identically to the original -- same UI, same features, same user experience. Except now every camera frame, every GPS coordinate, and every sensor reading passes through you first. The app asks the operating system "what does the camera see?" and your interceptor answers before the real data arrives.

This chapter teaches you the full pipeline: what the patch-tool does internally, how to run it, how to read its output like a flight recorder, what all those injected classes actually do, and how to deploy and verify the result. By the end, you will have a patched APK running on your emulator with the injection infrastructure armed and waiting for payloads.

> **Ethics Note:** The patching techniques in this chapter modify application binaries. Only patch applications you are authorized to test. Never distribute patched APKs.

---

## The Full Pipeline

When you run the patch-tool, it executes a ten-step pipeline. You do not need to memorize the steps -- the tool handles them all -- but understanding the sequence is what lets you troubleshoot when something breaks, verify that your recon predictions were correct, and explain to a client exactly what was modified.

```text
Input APK
  |
  v
apktool decode (APK -> smali + resources)
  |
  v
Convert hook-core runtime JAR to smali
  |
  v
Inject runtime smali into new DEX slot (smali_classesN/)
  |
  v
Patch Application.onCreate() -- register lifecycle hook
  |
  v
Patch AndroidManifest.xml -- add storage permissions
  |
  v
Apply hooks:
  - CameraX: toBitmap(), analyze(), onCaptureSuccess()
  - Camera2: Surface(SurfaceTexture), getSurface(), OnImageAvailableListener
  - Location: onLocationResult(), onLocationChanged(),
              getLastKnownLocation(), mock detection
  - Sensor: onSensorChanged()
  |
  v
apktool rebuild (smali + resources -> APK)
  |
  v
zipalign + sign with debug keystore
  |
  v
Output: patched.apk
```

The critical step is hook application. The tool finds every method you identified during recon and inserts a call at the method entry point that routes execution through the corresponding interceptor. The app's original code is still there -- it still runs -- but it receives your data instead of real data.

Let's walk through each stage.

### Stage 1: Decode

The patch-tool invokes `apktool d` to decode the input APK. This produces a directory tree containing the AndroidManifest.xml in human-readable form, every resource file, and every DEX file decompiled into smali. If the APK contains `classes.dex` through `classes6.dex`, the work directory will have `smali/` (for classes.dex), `smali_classes2/` through `smali_classes6/` -- one directory per DEX file, each containing the full class hierarchy in `.smali` text files.

This is the same decode step you performed during recon in Chapter 5. The patch-tool needs the decoded smali because that is the format it can modify -- you cannot edit a compiled DEX binary directly (well, you can, but you shouldn't), so you work through the decode-modify-rebuild cycle.

### Stage 2: Runtime Conversion

The patch-tool carries a bundled JAR file containing all the runtime classes -- the interceptors, the overlay UI, the fake data wrappers, the config loaders. This JAR is Java bytecode, but Android needs DEX bytecode. So the tool invokes `d8` (the Android DEX compiler from the SDK Build-Tools) to convert the JAR into DEX format, then uses `baksmali` (via apktool) to disassemble that DEX into smali files.

The result: 1,134 `.smali` files representing every class the injection runtime needs.

### Stage 3: DEX Injection

The tool finds the next available DEX slot. If the target APK has `classes.dex` through `classes6.dex`, the new runtime smali goes into `smali_classes7/`. The entire `com/hookengine/` package tree is copied into this directory.

This is the key insight of the injection mechanism: the patch-tool does not modify any existing DEX files for the runtime classes. It creates a new one. The original `classes.dex` through `classes6.dex` remain byte-for-byte identical to the original APK (except for the small hook instructions inserted in later stages). When apktool rebuilds, it compiles `smali_classes7/` into `classes7.dex` and adds it to the output APK.

Android's classloader does not distinguish between "original" and "injected" DEX files. They all load into the same namespace. The runtime classes can reference the app's classes (to hook them), and the app's patched code can reference the runtime classes (to call the hooks). From ART's perspective, it is all one application.

### Stage 4: Bootstrap Patch

The tool locates the Application class declared in the manifest (or specified via `--app-class`) and modifies its `onCreate()` method. It inserts a single static method call at the very beginning of the method body:

```smali
invoke-static {p0}, Lcom/hookengine/core/HookEngine;->init(Landroid/app/Application;)V
```

One line. That line passes the Application instance to HookEngine, which uses it to register `ActivityLifecycleCallbacks`, initialize the interceptors, and set up the overlay. Every subsequent hook in the entire runtime flows from this single bootstrap call.

If the target APK does not declare a custom Application class (it uses Android's default `android.app.Application`), the patch-tool creates one. It generates a minimal Application subclass that does nothing except call `HookEngine.init()` in its `onCreate()`, then updates the manifest to reference the new class.

### Stage 5: Manifest Patch

The tool modifies `AndroidManifest.xml` to add the permissions the runtime needs. Specifically:

- `READ_EXTERNAL_STORAGE` -- for reading payload files from `/sdcard/`
- `WRITE_EXTERNAL_STORAGE` -- for payload management
- `requestLegacyExternalStorage="true"` on the `<application>` tag -- opts out of Scoped Storage on API 29

These are added only if not already present. The tool does not remove or modify any existing permissions.

### Stage 6: Hook Application

This is the stage that turns a decoded APK into a weaponized one. The tool scans every smali file in the work directory for known hook targets and inserts interception code at each one. Five hook modules fire in sequence:

**Core Lifecycle Hook** -- Patches `Application.onCreate()` (covered in Stage 4). This is the single entry point for the entire runtime.

**CameraX Hooks** -- Finds every implementation of `ImageAnalysis.Analyzer.analyze(ImageProxy)`, every call to `ImageProxy.toBitmap()`, and every implementation of `OnImageCapturedCallback.onCaptureSuccess(ImageProxy)`. At each site, inserts code that routes the ImageProxy through `FrameInterceptor` before the app's logic processes it.

**Camera2 Hooks** -- Finds `new Surface(SurfaceTexture)` constructor calls, `SurfaceHolder.getSurface()` calls, and `OnImageAvailableListener` implementations. These hooks redirect the camera preview surface and replace captured frames for apps that use the lower-level Camera2 API.

**Location Hooks** -- Finds `LocationCallback.onLocationResult()`, `LocationListener.onLocationChanged()`, and `getLastKnownLocation()` calls. Also finds `isFromMockProvider()` and `isMock()` calls and patches them to return `false`, plus intercepts `Settings.Secure.getString()` when the key is `"mock_location"` to return `"0"`. This two-layer approach replaces the coordinates AND defeats the detection of that replacement.

**Sensor Hooks** -- Finds `SensorEventListener.onSensorChanged(SensorEvent)` implementations and inserts code that mutates `event.values[]` in-place with configured data before the app processes the event.

Each hook module reports what it found and what it patched. If a target method does not exist in the APK -- because the app does not use that API -- the module logs a warning and moves on. This is expected behavior, not an error.

### Stages 7-9: Rebuild, Align, Sign

`apktool b` reassembles the modified smali and resources into a new APK. `zipalign` aligns uncompressed data to 4-byte boundaries for optimal runtime performance. `apksigner` signs the APK with a debug keystore (auto-generated on first run at `~/.patch-tool/debug.keystore`).

The output is a fully installable APK with a different signature than the original. Same package name, same version code, same UI -- different signature and 1,134 additional classes.

---

## Running the Tool

### The basic command

From the project root (where [`patch-tool.jar`](https://github.com/iamjosephmj/AndroidRedTeam/blob/main/patch-tool.jar) lives):

```bash
java -jar patch-tool.jar materials/targets/target-kyc-basic.apk
```

Output lands in the same directory as the input, named `target-kyc-basic-patched.apk`.

### With options

```bash
java -jar patch-tool.jar materials/targets/target-kyc-basic.apk \
  --out patched.apk \
  --work-dir ./work
```

Keeping `--work-dir` around is important. It preserves the decoded smali so you can inspect what was patched, verify hooks landed where you expected, or debug issues without re-decoding. Treat the work directory as a forensic artifact of the patching operation.

### All options

```text
--out <path>          Output APK path (default: <input>-patched.apk)
--work-dir <path>     Working directory for intermediate files (default: temp dir)
--app-class <class>   Override Application class (auto-detected from manifest)
--keystore <path>     Custom keystore for signing (default: ~/.patch-tool/debug.keystore)
--ks-pass <pass>      Keystore password (default: android)
--key-alias <alias>   Key alias (default: androiddebugkey)
--key-pass <pass>     Key password (default: android)
```

You will almost never need the signing options. The debug keystore works fine for emulators and rooted devices. The only time you need a custom keystore is when deploying to a managed device that enforces signature policies.

---

## Reading the Output Like a Flight Recorder

The patch-tool talks to you. Every line tells you something. Here is a real run against the course target:

```text
[*] Input:  target.apk
[*] Output: patched.apk
[*] Work:   ./work
[*] Tools:  /path/to/android-sdk/build-tools/34.0.0
[+] Extracted bundled runtime JAR
[*] Decoding APK...
[+] Decoded APK
[*] Converting runtime to smali...
[+] Converted runtime to smali
[*] Injecting runtime into smali_classes7/
[+] Injected 1134 runtime smali files into smali_classes7/
[*] Auto-detecting Application class...
[+] Detected: com.poc.PocApplication
[*] Registered 5 hook module(s): [core, camerax, camera2, location, sensor]
[*] Patching AndroidManifest.xml...
[+] Added 1 permission(s) to manifest
[*] Applying Core Lifecycle Hook...
[+] Patched Application.onCreate()
[*] Applying CameraX Frame Injection...
[+] Patched toBitmap() in 1 file(s)
[+] Patched analyze() in 1 method(s)
[+] Patched onCaptureSuccess() in 1 method(s)
[*] Applying Camera2 Frame Injection...
[!] No Surface(SurfaceTexture) found -- target may not use Camera2
[!] No getSurface() found -- target may not use Camera2
[!] No OnImageAvailableListener found -- target may not use Camera2
[*] Applying Location Injection...
[+] Patched onLocationResult() in 1 method(s)
[!] No onLocationChanged(Location) found -- target may not use LocationListener
[*] Applying Sensor Injection...
[!] No onSensorChanged(SensorEvent) found -- target may not use SensorEventListener
[*] Rebuilding APK...
[+] Rebuilt APK
[*] Zipaligning...
[+] Zipaligned
[*] Signing...
[+] Signed

[+] ==============================
[+]  APK patched successfully!
[+] ==============================

[*] Output: patched.apk
[*] Size:   47MB
```

Learn to read the prefixes:

| Prefix | Meaning |
|--------|---------|
| `[*]` | Info -- telling you what is happening |
| `[+]` | Success -- that step worked |
| `[!]` | Warning -- hook target not found, skipped |
| `[-]` | Error -- something broke |

### Warnings Are Normal

If you see `[!] No onSensorChanged found`, it means the app does not implement `SensorEventListener`. The hook is skipped. That is expected -- your recon already told you which surfaces exist. The course target (`com.poc.biometric`) uses CameraX, not Camera2, so the three Camera2 warnings are correct. It uses `FusedLocationProviderClient`, not the legacy `LocationManager`, so the `onLocationChanged` warning is correct. It does not register a `SensorEventListener`, so the sensor warning is correct.

The time to worry is when a hook you *expected* to fire shows as "not found." That means either your recon was wrong, or the app obfuscates the method name. Go back to the decoded smali in your `--work-dir` and investigate.

---

## Cross-Referencing with Recon

This is not optional. It is the verification step that separates a professional engagement from blindly running tools.

Every `[+] Patched` line in the output should correspond to a hook surface you identified in Chapter 5. Pull up your recon report side-by-side with the patch output and check:

| Recon Finding | Expected Patch Output | Actual |
|--------------|----------------------|--------|
| CameraX `ImageAnalysis.Analyzer` found | `[+] Patched analyze()` | Match |
| CameraX `toBitmap()` calls found | `[+] Patched toBitmap()` | Match |
| CameraX `OnImageCapturedCallback` found | `[+] Patched onCaptureSuccess()` | Match |
| No Camera2 `OnImageAvailableListener` | `[!] No OnImageAvailableListener` | Match |
| `FusedLocationProvider` callback found | `[+] Patched onLocationResult()` | Match |
| No `LocationListener` | `[!] No onLocationChanged` | Match |
| No `SensorEventListener` | `[!] No onSensorChanged` | Match |

Every line matches. Your recon predicted exactly what the patch-tool found. That is a clean engagement -- your intelligence was accurate, your tooling confirmed it, and you can proceed with confidence that the right hooks are in place.

If something does not match, stop. Investigate before deploying. Common causes:

- **Recon said the API exists, but patch says "not found"** -- The method might be obfuscated by R8/ProGuard. Check the decoded smali for renamed methods that take the right parameter types.
- **Patch found something recon missed** -- Your grep patterns during recon were too narrow. Expand your search and update your recon report.
- **Different hook count than expected** -- The app might have multiple implementations of the same interface (e.g., two different `Analyzer` classes). This is normal for apps with both selfie and document capture flows.

Save the full console output as part of your engagement evidence:

```bash
java -jar patch-tool.jar materials/targets/target-kyc-basic.apk \
  --out patched.apk \
  --work-dir ./work 2>&1 | tee patch_output.txt
```

That `patch_output.txt` goes into your final report alongside the recon findings, delivery logs, and screenshots.

---

## The Runtime Architecture

You just injected 1,134 classes into the target. Here is what they do and how they fit together.

### HookEngine

The central registry. `HookEngine.init(Application)` is the single entry point called from the patched `Application.onCreate()`. It receives the Application instance and uses it to:

1. Register `ActivityLifecycleCallbacks` -- this is how the overlay attaches to every Activity
2. Initialize each interceptor subsystem
3. Set up the `OverlayController` for runtime control

HookEngine does not perform any interception itself. It is the coordinator that wires everything together during bootstrap.

### FrameInterceptor

The camera injection engine. When armed, it intercepts every camera frame callback and replaces the frame data with content loaded from `/sdcard/poc_frames/`. It works with `FrameStore`, which handles the actual file I/O:

- Scans `/sdcard/poc_frames/` for subdirectories containing PNG files and MP4 video files
- Loads frames into memory as Bitmaps
- Cycles through frames sequentially (frame 1, frame 2, ... frame N, frame 1, ...)
- Supports runtime source switching via the overlay (tap a different folder to change payload mid-engagement)

The interceptor creates `FakeImageProxy` objects for CameraX hooks and `FakeImage`/`FakeImagePlane` wrappers for Camera2 hooks. These wrapper classes implement the same interfaces as real camera objects, so the app's code processes them identically -- calling `getWidth()`, `getHeight()`, `getPlanes()`, and receiving the injected data through every accessor.

### LocationInterceptor

The GPS spoofing engine. When armed, it intercepts location callbacks and replaces the `Location` or `LocationResult` objects with configured coordinates from `/sdcard/poc_location/`. The `LocationStore` manages:

- Loading JSON config files with latitude, longitude, altitude, and accuracy
- Waypoint sequences for simulating movement
- Loop modes (single point, config rotation, waypoint cycling)
- Auto-detection of the first JSON file in the directory

The interceptor also handles mock detection suppression. Every `isFromMockProvider()` and `isMock()` call returns `false`. Every `Settings.Secure.getString()` for the `"mock_location"` key returns `"0"`. The app cannot detect that its location data is fabricated.

### SensorInterceptor

The motion injection engine. When armed, it intercepts `onSensorChanged()` callbacks and mutates the `SensorEvent.values[]` array in-place. This is a direct memory modification -- the `values` array is a `float[]` that the interceptor overwrites with configured data before the app's listener processes the event.

The `SensorStore` manages sensor configurations from `/sdcard/poc_sensor/`:

- Base values for accelerometer (X, Y, Z) and gyroscope (X, Y, Z)
- Jitter magnitude for adding realistic noise
- Motion profiles set via the overlay: STILL, HOLDING, WALKING

The in-place mutation approach is deliberate. Sensor events fire at high frequency (50-200 Hz), and creating new `SensorEvent` objects for each delivery would generate garbage collection pressure that could cause visible UI stutter. Mutating the existing array avoids allocation entirely.

### OverlayController

The in-app control panel. It attaches to every Activity through `ActivityLifecycleCallbacks` by adding views directly to the Activity's `DecorView` -- the root `FrameLayout` that holds the app's entire view tree. No `SYSTEM_ALERT_WINDOW` permission needed. The overlay lives inside the app's own window.

The overlay provides:

- A lightning bolt button in the top-right corner (the visual indicator that injection is active)
- A menu panel with access to all three subsystems
- Real-time status for each interceptor: delivery counts, accept rates, current payload state
- Runtime controls: enable/disable each subsystem, switch payload sources, change motion profiles
- 500ms polling for live status updates when a panel is open

### FakeImageProxy and FakeImage

Camera data wrappers that implement the `ImageProxy` and `Image` interfaces. `FakeImageProxy` wraps injected Bitmap data and responds to every method call the app might make -- `getWidth()`, `getHeight()`, `getFormat()`, `getPlanes()`, `close()`. `FakeImage` and `FakeImagePlane` handle the lower-level `android.media.Image` interface used by Camera2 apps.

These wrappers are what make the substitution transparent. The app calls standard CameraX or Camera2 methods and receives responses consistent with real camera data. The image dimensions match, the format codes match, the plane layouts match -- only the pixel data is different.

### Supporting Classes

| Component | Role |
|-----------|------|
| `ActivityLifecycleHook` | Registers with the Application to intercept Activity lifecycle events |
| `DeliveryTracker` | Logs every injection event for post-engagement analysis |
| `VideoFrameExtractor` | Decodes MP4 video frames at runtime for video-mode injection |
| `SurfaceSwapper` | Redirects Camera2 preview surfaces for live preview injection |
| `BitmapSurfaceView` | Overlays injected frames on CameraX preview surfaces |
| `PreviewHider` | Manages frame timing on the preview overlay to avoid flicker |
| `StoragePermissionHelper` | Auto-requests storage permissions when the overlay first opens |
| `FrameStore` | Loads, caches, and indexes PNG frames and MP4 files from storage |
| `LocationStore` | Parses location JSON configs, manages waypoints and loop modes |
| `SensorStore` | Parses sensor JSON configs, computes derived values, manages profiles |

One line patched into `Application.onCreate()`. That line loads the lifecycle hook. The lifecycle hook attaches the overlay and arms the interceptors. The interceptors catch every frame, every location, every sensor event. Everything else -- 1,134 classes of machinery -- makes the replacement seamless.

---

## The DEX Injection Mechanism

Understanding exactly how `classes7.dex` gets added clarifies why this approach is reliable and hard to detect at rest.

### How Android Loads Multidex

When ART (Android Runtime) loads an APK, it enumerates every `classesN.dex` file in the ZIP archive. The classloader is initialized with the full list: `classes.dex`, `classes2.dex`, ..., `classesN.dex`. There is no manifest or index that declares which DEX files should exist -- ART simply scans for the naming pattern. If a `classes7.dex` is present, it gets loaded. If it is not, nothing breaks.

This means adding a new DEX file is functionally identical to adding a new source module during the original build. No framework code needs to change. No loader configuration needs to be updated. The new classes are available in the same namespace as every other class in the app.

### The Injection Sequence

Here is what happens in the work directory during the injection stage:

```text
work/
  smali/                    <- from classes.dex (original, untouched)
  smali_classes2/           <- from classes2.dex (original, untouched)
  smali_classes3/           <- from classes3.dex (original, untouched)
  smali_classes4/           <- from classes4.dex (original, untouched)
  smali_classes5/           <- from classes5.dex (original, untouched)
  smali_classes6/           <- from classes6.dex (original, untouched)
  smali_classes7/           <- NEW: injected runtime
    com/
      hookengine/
        core/
          HookEngine.smali
          FrameInterceptor.smali
          LocationInterceptor.smali
          SensorInterceptor.smali
          OverlayController.smali
          FakeImageProxy.smali
          ...
        ui/
          OverlayMenuPanel.smali
          FramePanel.smali
          LocationPanel.smali
          SensorPanel.smali
          ...
        util/
          DeliveryTracker.smali
          StoragePermissionHelper.smali
          ...
```

The patch-tool determines the slot number by scanning for existing `smali_classesN/` directories and using the next available index. If the target has `smali/` through `smali_classes6/`, the runtime goes into `smali_classes7/`. If it has `smali/` through `smali_classes3/`, the runtime goes into `smali_classes4/`.

### Why a Separate DEX Slot

Injecting into an existing DEX file would work -- you could merge the runtime classes into `smali_classes6/` and apktool would compile them into the existing `classes6.dex`. But there are three reasons the patch-tool uses a separate slot:

1. **Isolation** -- The original DEX files remain structurally unmodified (aside from the small hook instructions). This reduces the risk of accidentally breaking the app's code through class ID conflicts or method limit overflows.

2. **Idempotency** -- When the tool detects that `smali_classes7/com/hookengine/` already exists, it knows the APK was already patched. It can skip re-injection and just verify the hooks. This makes re-patching safe.

3. **Forensic clarity** -- During post-engagement review, you can identify exactly which classes were injected by examining a single DEX file. `classes7.dex` contains the runtime and nothing else. Clean separation.

### Size Impact

The 1,134 runtime classes compile to approximately 2.4 MB of DEX bytecode. On a typical 50 MB target APK, that is a 4.8% size increase. On a 100 MB app with substantial native libraries and assets, it is under 2.5%. The size change is unlikely to raise flags during casual inspection, though automated APK analysis tools that track DEX file counts or total class counts would detect the addition.

---

## The Bootstrap Chain

Understanding the startup sequence is critical for diagnosing issues where the runtime loads but hooks do not fire, or where the overlay appears but interceptors stay dormant.

```text
User taps app icon
  |
  v
Zygote forks new process
  |
  v
ART loads all DEX files (classes.dex through classes7.dex)
  |
  v
Application class instantiated (com.poc.PocApplication)
  |
  v
Application.onCreate() fires
  |
  v
HookEngine.init(application)
  |   |
  |   +-> Register ActivityLifecycleCallbacks
  |   |     |
  |   |     +-> onActivityCreated() -> OverlayController.attachToActivity()
  |   |     +-> onActivityResumed() -> OverlayController.reattach()
  |   |
  |   +-> FrameInterceptor.arm()
  |   |     |
  |   |     +-> Scan /sdcard/poc_frames/
  |   |     +-> If frames found: load into FrameStore, set armed=true
  |   |     +-> If empty/missing: set armed=false (pass-through mode)
  |   |
  |   +-> LocationInterceptor.arm()
  |   |     |
  |   |     +-> Scan /sdcard/poc_location/
  |   |     +-> If config found: parse JSON, set armed=true
  |   |     +-> If empty/missing: set armed=false (pass-through mode)
  |   |
  |   +-> SensorInterceptor.arm()
  |   |     |
  |   |     +-> Scan /sdcard/poc_sensor/
  |   |     +-> If config found: parse JSON, set armed=true
  |   |     +-> If empty/missing: set armed=false (pass-through mode)
  |   |
  |   +-> OverlayController.init()
  |         |
  |         +-> Prepare overlay views (lightning bolt icon, menu panels)
  |         +-> Wait for first Activity to attach
  |
  v
Launcher Activity starts (com.poc.biometric.ui.LauncherActivity)
  |
  v
ActivityLifecycleCallbacks.onActivityCreated() fires
  |
  v
OverlayController.attachToActivity()
  |
  v
Lightning bolt appears in top-right corner
  |
  v
App runs normally -- hooks intercept data at each callback
```

The key timing to understand: interceptors arm during `Application.onCreate()`, which runs before any Activity creates. By the time the app's camera starts capturing frames or the location service starts delivering coordinates, the hooks are already in place. There is no race condition -- the bootstrap completes before any hook target fires.

### Pass-Through Mode

When an interceptor is not armed (no payloads in the corresponding directory), it enters pass-through mode. The hook instruction in the app's code still fires on every callback, but the interceptor immediately returns the original data unchanged. The performance overhead is negligible -- a single null check per event.

This is the stealth characteristic: a patched APK with empty payload directories behaves identically to the unpatched original. No different UI, no different behavior, no different performance. The injection infrastructure is present but invisible. It activates the moment you push payloads to the device and either relaunch the app or toggle the interceptor via the overlay.

### Hot-Reload Behavior

The `FrameInterceptor` supports runtime source switching through the overlay. When you tap a different folder in the frame panel, `FrameStore` reloads from the new path without requiring an app restart. The `LocationInterceptor` and `SensorInterceptor` support the same pattern -- tap a different config file in the overlay and the new values take effect immediately.

This hot-reload capability is what makes mid-engagement pivots possible. When a KYC flow transitions from selfie capture to document capture, you tap a different frame folder in the overlay and the injection source changes in the next callback cycle. No adb commands, no app restart, no payload repush.

---

## Deploying the Patched APK

You have a `patched.apk`. Time to put it on the device.

### Install

```bash
adb install -r patched.apk
```

The `-r` flag means "replace existing." If the app is already installed with the same package name and a different signature, you will get `INSTALL_FAILED_UPDATE_INCOMPATIBLE`. This is Android's signature verification doing its job -- the patched APK is signed with a debug key, not the developer's production key.

Fix it by uninstalling first:

```bash
adb uninstall com.poc.biometric
adb install -r patched.apk
```

### Grant Permissions

The patched app needs the same permissions as the original, plus storage access for reading payloads from `/sdcard/`. Grant everything up front so permission dialogs do not interrupt the flow during an engagement.

```bash
# Camera
adb shell pm grant com.poc.biometric android.permission.CAMERA

# Location (needed for Chapter 8, harmless to grant now)
adb shell pm grant com.poc.biometric android.permission.ACCESS_FINE_LOCATION
adb shell pm grant com.poc.biometric android.permission.ACCESS_COARSE_LOCATION

# Storage (legacy, for API < 30)
adb shell pm grant com.poc.biometric android.permission.READ_EXTERNAL_STORAGE
adb shell pm grant com.poc.biometric android.permission.WRITE_EXTERNAL_STORAGE

# Storage (API 30+ -- the one that actually matters on modern Android)
adb shell appops set com.poc.biometric MANAGE_EXTERNAL_STORAGE allow
```

Replace `com.poc.biometric` with your target's package name for non-course targets.

### Launch

Use the launcher activity you identified during recon:

```bash
adb shell am start -n com.poc.biometric/com.poc.biometric.ui.LauncherActivity
```

If you do not remember the activity name, let Android figure it out:

```bash
adb shell monkey -p com.poc.biometric -c android.intent.category.LAUNCHER 1
```

---

## Verification

You have installed the patched APK and launched it. How do you know the injection is actually active?

Start with the fastest check and work down. If the first check passes, you are done. If it does not, each subsequent check provides more diagnostic information.

### Check 1: The Overlay

If any payload directory exists on the device with content, a lightning bolt button appears in the top-right corner of the app. Tap it to see the HookEngine menu with three modules: Frame Injection, Location Injection, Sensor Injection.

If you see the bolt, the runtime is loaded and the lifecycle hook is active. The bootstrap chain completed successfully.

To trigger the overlay for verification, create a payload directory and push at least one file:

```bash
adb shell mkdir -p /sdcard/poc_frames/face_neutral/
# Push test frames (or real frames if you have them)
adb push materials/payloads/frames/face_neutral/ /sdcard/poc_frames/face_neutral/
```

If you do not have face frames yet, generate simple test frames to confirm the pipeline works:

```bash
for i in $(seq -w 1 10); do
  ffmpeg -y -f lavfi -i "color=c=gray:size=640x480:d=0.1" \
    -frames:v 1 "/tmp/test_frames/${i}.png" 2>/dev/null
done
adb shell mkdir -p /sdcard/poc_frames/test/
adb push /tmp/test_frames/ /sdcard/poc_frames/test/
```

Gray rectangles will not pass face detection, but they will confirm that frame injection is operational. You will replace them with real face frames in Chapter 7.

### Check 2: Logcat

```bash
adb logcat -s FrameInterceptor HookEngine ActivityLifecycleHook OverlayController
```

Look for:

- `"ActivityLifecycleHook registered"` -- the lifecycle hook fired during `Application.onCreate()`
- `"Overlay attached to activity"` -- the overlay UI attached to the visible Activity
- `"FrameInterceptor armed"` -- frames were found and the interceptor is ready
- `"LocationInterceptor armed"` / `"SensorInterceptor armed"` -- if you pushed location/sensor configs

If you see the lifecycle and overlay messages but not the interceptor messages, the runtime loaded but could not find payload files. Check your push paths.

If you see nothing at all, the bootstrap did not fire. Check that the Application class was correctly patched -- open the work directory and inspect the Application's `onCreate()` smali for the `HookEngine.init()` call.

### Check 3: APK Structure

For binary-level confirmation that the injection is present:

```bash
# List all DEX files in the patched APK
unzip -l patched.apk | grep classes

# Expected output includes the injected DEX:
# classes.dex
# classes2.dex
# ...
# classes7.dex    <- the injected runtime

# Verify the runtime classes are in the injected DEX
unzip -p patched.apk classes7.dex > /tmp/classes7.dex
dexdump /tmp/classes7.dex | grep "Class descriptor" | head -10

# Should show:
# 'Lcom/hookengine/core/HookEngine;'
# 'Lcom/hookengine/core/FrameInterceptor;'
# 'Lcom/hookengine/core/LocationInterceptor;'
# 'Lcom/hookengine/core/SensorInterceptor;'
# ...
```

This check is useful when the app will not launch at all -- you can verify the structural modification even without running the app. If `classes7.dex` is missing or does not contain the hookengine classes, the patching failed and you need to re-run with `--work-dir` to diagnose.

### Check 4: Work Directory Inspection

The most detailed check. Open the work directory and verify the hooks directly in the smali:

```bash
# Verify the bootstrap hook in Application.onCreate()
grep -n "HookEngine" work/smali*/com/poc/PocApplication.smali

# Verify CameraX hooks
grep -rn "FrameInterceptor" work/smali*/

# Verify location hooks
grep -rn "LocationInterceptor" work/smali*/
```

Each grep should return at least one result showing the hook call inserted into the target method. If a grep returns nothing, that hook was not applied -- cross-reference with the patch-tool output to understand why.

---

## The Hook Wiring in Detail

To make the architecture concrete, here is what a hooked method looks like before and after patching.

### Before: Original analyze() Method

```smali
.method public analyze(Landroidx/camera/core/ImageProxy;)V
    .locals 2

    invoke-interface {p1}, Landroidx/camera/core/ImageProxy;->getImage()Landroid/media/Image;
    move-result-object v0

    invoke-virtual {p0, v0}, Lcom/poc/biometric/FrameAnalyzer;->processFrame(Landroid/media/Image;)V

    invoke-interface {p1}, Landroidx/camera/core/ImageProxy;->close()V

    return-void
.end method
```

### After: Patched analyze() Method

```smali
.method public analyze(Landroidx/camera/core/ImageProxy;)V
    .locals 3

    # --- HOOK START ---
    invoke-static {p1}, Lcom/hookengine/core/FrameInterceptor;->intercept(Landroidx/camera/core/ImageProxy;)Landroidx/camera/core/ImageProxy;
    move-result-object p1
    # --- HOOK END ---

    invoke-interface {p1}, Landroidx/camera/core/ImageProxy;->getImage()Landroid/media/Image;
    move-result-object v0

    invoke-virtual {p0, v0}, Lcom/poc/biometric/FrameAnalyzer;->processFrame(Landroid/media/Image;)V

    invoke-interface {p1}, Landroidx/camera/core/ImageProxy;->close()V

    return-void
.end method
```

Two lines added. The `invoke-static` calls `FrameInterceptor.intercept()`, passing the original `ImageProxy`. The interceptor checks whether it is armed. If armed, it returns a `FakeImageProxy` containing injected frame data. If not armed (no payloads), it returns the original `ImageProxy` unchanged. Either way, the result goes back into `p1`, and the rest of the method proceeds with whatever `p1` now points to.

The register count increments from `.locals 2` to `.locals 3` to accommodate the additional operation. The patch-tool handles this automatically -- incorrect register counts cause `VerifyError` at runtime, so the tool recalculates after every modification.

This same pattern -- `invoke-static` into the interceptor, `move-result-object` back into the parameter register -- applies to every hook point across all three subsystems. The target method, the interceptor class, and the parameter type change, but the structural pattern is identical.

---

## Troubleshooting

### Build and Environment

| Problem | Cause | Fix |
|---------|-------|-----|
| `UnsupportedClassVersionError` | Java too old | Install Java 11+ |
| `Unable to access jarfile` | Wrong path | [`patch-tool.jar`](https://github.com/iamjosephmj/AndroidRedTeam/blob/main/patch-tool.jar) is at the project root |
| `ANDROID_HOME not set` | SDK not found | `export ANDROID_HOME=~/Library/Android/sdk` |
| `zipalign not found` | build-tools missing | `sdkmanager "build-tools;34.0.0"` |
| `apktool: command not found` | Not installed | `brew install apktool` (macOS) |

### Patching

| Problem | Cause | Fix |
|---------|-------|-----|
| `No Application class found` | Manifest has no `android:name` on `<application>` | Tool auto-creates one; or use `--app-class` |
| `apktool decode failed` | Corrupt APK or version mismatch | Re-download APK; update apktool to 2.9+ |
| `Runtime conversion failed` | d8 issue | Verify build-tools installation |
| Hook you expected shows "not found" | Obfuscation or wrong recon | Check decoded smali in `--work-dir` |

### Deployment

| Problem | Cause | Fix |
|---------|-------|-----|
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | Signature mismatch | `adb uninstall <pkg>` first |
| `INSTALL_FAILED_NO_MATCHING_ABIS` | Wrong architecture | ARM APK on x86 emu or vice versa |
| Overlay does not appear | No payload directories | Create `/sdcard/poc_frames/` with content |
| App crashes with `ClassNotFoundException` | DEX injection failed | Re-run; check `smali_classesN/` in work-dir |
| App crashes with `VerifyError` | Register mismatch | Hook patched a method incorrectly |

### Runtime

| Problem | Cause | Fix |
|---------|-------|-----|
| `"Application.onCreate() already patched"` | APK was previously patched | Safe to ignore -- idempotent |
| `"SurfaceViewImplementation already patched"` | CameraX preview hook present | Safe to ignore |
| `SecurityException: MANAGE_EXTERNAL_STORAGE` | Storage not granted | `adb shell appops set <pkg> MANAGE_EXTERNAL_STORAGE allow` |
| `FrameStore: 0 files` | Empty payload dir or wrong format | Push `.png` files to `/sdcard/poc_frames/` |
| Patched APK is much larger | Normal | 1,134 classes add ~2.4 MB of DEX |

---

## What You Have Now

The APK is patched, installed, and running. The runtime is loaded. The hooks are armed. 1,134 classes of injection infrastructure sit inside the target process, bootstrapped from a single lifecycle hook, waiting for data to deliver.

Right now, the interceptors are in one of two states. If you pushed payloads before launching, they are armed and actively replacing data on every callback. If you have not pushed payloads yet, they are in pass-through mode -- firing on every callback but returning the original data unchanged. The app behaves exactly like the unmodified version. Nobody looking at the screen, the logcat, or the app's behavior would know anything is different.

That changes the moment you push payloads. A folder of PNGs in `/sdcard/poc_frames/` and the camera starts lying. A JSON file in `/sdcard/poc_location/` and the GPS teleports. A config in `/sdcard/poc_sensor/` and the accelerometer rewrites physics. Each subsystem arms independently, activates automatically, and operates without coordination from the others.

The next three chapters teach you to feed the machine. Chapter 7 covers camera frame injection -- how to generate face frames, structure payload folders for multi-step flows, and get face detection SDKs to accept your injected data. Chapter 8 covers GPS coordinate spoofing. Chapter 9 covers sensor injection for liveness correlation.

But first: practice the full injection workflow. Complete **Lab 2: Patch and Deploy** to run the pipeline end-to-end against the course target, verify every hook against your recon findings, and confirm the overlay is operational on your emulator.
