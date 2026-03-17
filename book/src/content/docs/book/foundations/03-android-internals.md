---
title: "Android Internals for Red Teams"
description: "APK structure, the Dalvik/ART runtime, smali bytecode, and the camera/location/sensor subsystems"
---

Before you hook the camera, you need to understand how Android delivers camera frames to applications. Before you spoof GPS, you need to understand how location data flows from satellite hardware to an app's callback. Before you inject sensor readings, you need to understand how the sensor subsystem aggregates and distributes physical measurements.

This chapter is the mental model. The techniques in Chapters 5-12 all exploit the same architectural pattern: apps access hardware through framework APIs, and those APIs can be intercepted at the bytecode level. Understanding *why* this works — not just that it works — is what lets you adapt when you encounter targets that don't match the standard patterns.

---

## The APK: Anatomy of an Android Application

An Android application is distributed as an APK (Android Package) — a ZIP archive with a specific structure:

```text
app.apk
  AndroidManifest.xml     <- app configuration, permissions, entry points
  classes.dex             <- compiled bytecode (primary)
  classes2.dex            <- additional bytecode (multidex)
  classes3.dex            <- more bytecode (as needed)
  res/                    <- compiled resources (layouts, drawables, etc.)
  assets/                 <- raw assets (config files, ML models, etc.)
  lib/                    <- native libraries (.so files, per architecture)
  META-INF/               <- signature files
  resources.arsc          <- compiled resource table
```

The two files you care about most for security analysis are:

**AndroidManifest.xml** — The app's blueprint. It declares the package name, Application class, activities, services, permissions, and intent filters. During recon (Chapter 5), the manifest tells you what hardware the app accesses and how it starts.

**classes*.dex** — The compiled bytecode. Java and Kotlin source code compile to DEX (Dalvik Executable) format, which the Android runtime (ART) executes. This is where the app's logic lives — every camera callback, every location listener, every sensor handler is encoded in DEX bytecode.

### DEX Format and Multidex

A single DEX file can contain at most 65,536 methods (the "64K method limit"). Most non-trivial apps exceed this, so they split their code across multiple DEX files — `classes.dex`, `classes2.dex`, `classes3.dex`, and so on. The Android runtime loads all of them into the same class namespace.

This is why the patch-tool can inject its own code as a new DEX file (e.g., `classes7.dex`). The runtime doesn't distinguish between the app's original classes and the injected ones — they're all loaded into the same classloader, able to reference each other's classes and methods. From the runtime's perspective, the injected code is just more of the app.

### From Source to Smali

The compilation chain works like this:

```text
Java/Kotlin Source (.java/.kt)
  -> Java Bytecode (.class) [javac/kotlinc]
  -> DEX Bytecode (.dex) [d8/r8]
  -> Smali text (.smali) [apktool/baksmali]
```

Smali is a human-readable, editable representation of DEX bytecode. It's not source code — it's an assembly-like format where each instruction maps directly to a DEX opcode. But unlike raw hex editing, smali is something you can read, modify, and reassemble.

When `apktool d` decodes an APK, it converts each DEX file into a directory of smali files — one per class. When `apktool b` rebuilds, it converts the smali back to DEX. This decode-edit-rebuild cycle is how the patch-tool modifies application behavior without having access to the original source code.

A typical smali method looks like this:

```smali
.method public analyze(Landroidx/camera/core/ImageProxy;)V
    .locals 2

    # Get the image from the proxy
    invoke-interface {p1}, Landroidx/camera/core/ImageProxy;->getImage()Landroid/media/Image;
    move-result-object v0

    # Process the image
    invoke-virtual {p0, v0}, Lcom/example/FrameAnalyzer;->processFrame(Landroid/media/Image;)V

    # Close the proxy
    invoke-interface {p1}, Landroidx/camera/core/ImageProxy;->close()V

    return-void
.end method
```

Even without knowing smali syntax, you can read the intent: get an image from the proxy, process it, close the proxy. The patch-tool modifies methods like this — inserting instructions that intercept the `ImageProxy` and replace its data before the app processes it.

### Class Loading and Injection

Android's class loading mechanism is what makes DEX injection possible. When an app starts, the runtime creates a `ClassLoader` that knows about all DEX files in the APK. If the APK contains `classes.dex` through `classes6.dex`, the classloader can resolve any class defined in any of those files.

When the patch-tool adds `classes7.dex` containing 1,134 runtime classes (interceptors, hooks, overlay UI, config loaders), the classloader treats them as part of the app. The injected classes can:

- Reference any class the app defines (to hook into its methods)
- Reference any Android framework class (to create fake objects)
- Be referenced by modified app code (which the patch-tool instruments to call the hooks)

There's no signature check on individual DEX files — the APK signature covers the entire archive. When the patch-tool modifies the APK, it re-signs it with a debug key, which the emulator (or a device with USB debugging enabled) accepts without complaint. The app is none the wiser.

### The Multidex Advantage

The multidex architecture, originally a workaround for the 64K method limit, creates a convenient injection vector. The patch-tool doesn't need to modify existing DEX files — it adds a new one. This minimizes the risk of accidentally corrupting the app's original bytecode. The original `classes.dex` through `classes6.dex` remain identical; only the new `classes7.dex` is added, and small hook instructions are inserted into specific methods in the original files to redirect control flow to the injected code.

---

## The Camera Stack

The camera pipeline has five layers, from hardware to application code:

```text
Camera MEMS Sensor (hardware)
  -> Camera HAL (Hardware Abstraction Layer)
  -> CameraService (system process: /system/bin/cameraserver)
  -> Camera Framework (android.hardware.camera2.*)
  -> CameraX (androidx.camera.*) [optional high-level wrapper]
  -> App Code (ImageAnalysis.Analyzer, OnImageCapturedCallback, etc.)
```

### Layer by Layer

**Camera Hardware** — The physical image sensor. On a typical phone, there are two or more sensors (front-facing and rear-facing). The sensor converts photons into electrical signals, which are read out as raw pixel data.

**Camera HAL** — The Hardware Abstraction Layer. This is a vendor-specific library (provided by Qualcomm, Samsung, MediaTek, etc.) that translates between the generic Android camera interface and the specific hardware. The HAL handles sensor configuration, ISP (Image Signal Processor) pipeline, auto-exposure, auto-focus, and frame delivery.

**CameraService** — A system-level process that manages camera access, enforces permissions, and multiplexes between apps that want camera access. Apps don't talk to the HAL directly — they talk to the CameraService through Binder IPC.

**Camera Framework (Camera2)** — The `android.hardware.camera2.*` APIs that apps use to interact with the camera. Camera2 provides a powerful but complex API: `CameraManager` discovers cameras, `CameraDevice` opens them, `CameraCaptureSession` manages the capture pipeline, and `ImageReader` or `SurfaceTexture` receives the frames.

**CameraX** — Google's Jetpack camera library, built on top of Camera2 but dramatically simpler to use. CameraX abstracts away the device-specific quirks of Camera2 and provides a lifecycle-aware API with three main use cases: `Preview` (showing the camera feed on screen), `ImageCapture` (taking photos), and `ImageAnalysis` (processing frames in real-time).

### Where We Hook

The patch-tool hooks at the **top layer** — the application code that receives frames from CameraX or Camera2. This is critical to understand:

- We don't modify the camera hardware, the HAL, or the CameraService
- We don't intercept at the framework level
- We intercept the data **after** it exits the framework and **before** the app's code processes it

For CameraX apps, the primary hook targets are:
- `ImageAnalysis.Analyzer.analyze(ImageProxy)` — where apps receive frames for real-time processing (face detection, barcode scanning, etc.)
- `OnImageCapturedCallback.onCaptureSuccess(ImageProxy)` — where apps receive captured photos
- `Bitmap.toBitmap()` extension methods — where ImageProxy data is converted to Bitmap for display or SDK processing

For Camera2 apps, the primary hook target is:
- `ImageReader.OnImageAvailableListener.onImageAvailable(ImageReader)` — where apps receive frames from the capture pipeline

In both cases, the hook replaces the frame data inside the callback parameters. The app's code receives the modified data through the same API it normally uses, so it has no way to detect the substitution.

### The Hook Mechanism in Detail

Consider a CameraX app with this flow:

```text
App registers ImageAnalysis.Analyzer
  -> CameraX captures frame from hardware
  -> CameraX wraps frame as ImageProxy
  -> CameraX calls analyzer.analyze(imageProxy)
  -> App's analyzer processes the ImageProxy
  -> App calls imageProxy.close()
```

The patch-tool modifies the `analyze()` method in the app's Analyzer implementation. Before the original method body executes, the hook:

1. Reads the next frame from `/sdcard/poc_frames/` (a PNG file loaded into memory)
2. Creates a new `ImageProxy` wrapper containing the loaded frame data
3. Replaces the original `imageProxy` parameter with the fake one
4. Allows the original method body to proceed — but now operating on the injected data

The app's code runs unmodified. It calls `getImage()`, processes pixels, runs face detection — all on data you provided. The SDK, the ML model, the business logic — none of them know the data didn't come from the camera.

This "pre-method interception" pattern is used across all three subsystems. The hook fires before the app's logic, replaces the input data, and then lets the app proceed normally.

### CameraX vs Camera2: Which One?

Most modern Android apps (2020+) use CameraX. It's simpler, handles device compatibility automatically, and is the recommended API in Android's official documentation. You'll find CameraX in most KYC apps that use ML Kit, because ML Kit's face detection integrates directly with CameraX's `ImageAnalysis` pipeline.

Camera2 is used by apps that need fine-grained control over the capture pipeline — custom ISP processing, specific output formats, manual exposure control. Some performance-critical apps (video calling, AR) use Camera2 directly. Older apps (pre-2019) may also use Camera2.

During recon (Chapter 5), you'll learn to identify which API a target uses by searching for specific class references in the decompiled smali code.

---

## The Location Pipeline

GPS coordinates flow through a similar layered architecture:

```text
GPS/GLONASS/Galileo hardware
  -> Location HAL
  -> LocationManagerService (system process)
  -> Google Play Services (FusedLocationProviderClient)
  -> App Callbacks (onLocationResult, onLocationChanged)
```

### The Two APIs

**LocationManager** — The original Android location API. Apps register a `LocationListener` and receive `onLocationChanged()` callbacks with `Location` objects. This API talks directly to the `LocationManagerService` and requires the app to choose a provider (GPS, network, passive).

**FusedLocationProviderClient** — Google Play Services' location API. It fuses GPS, Wi-Fi, cell tower, and sensor data to provide the best possible location estimate. Apps register a `LocationCallback` and receive `onLocationResult()` callbacks. This is the more common API in modern apps because it's more accurate and more battery-efficient than raw GPS.

Most KYC apps use FusedLocationProvider because it's the recommended API and provides the highest accuracy. The patch-tool hooks both APIs — `onLocationResult` for FusedLocationProvider and `onLocationChanged` for LocationManager.

### Mock Location Detection

Android provides a mechanism for apps to detect GPS spoofing. The `Location` object has an `isFromMockProvider()` method (API 18-30) and `isMock()` method (API 31+) that return `true` if the location was generated by a mock provider rather than actual hardware.

Standard GPS spoofing tools (mock location apps enabled through Developer Options) set this flag. Apps that check it will reject spoofed locations.

The patch-tool bypasses this by hooking the mock detection methods themselves, forcing them to return `false` regardless of the location's actual source. The app receives the spoofed coordinates AND is told they're from a real provider. This is a second-layer hook — the first layer replaces the coordinates, the second layer bypasses the detection of that replacement.

---

## The Sensor Subsystem

Android's sensor architecture follows the same layered pattern:

```text
MEMS Hardware (accelerometer, gyroscope, magnetometer)
  -> Sensor HAL
  -> SensorService (system process)
  -> SensorManager
  -> App Callbacks (onSensorChanged)
```

### Base Sensors vs. Derived Sensors

Android distinguishes between **base sensors** (hardware) and **derived sensors** (computed by the framework):

**Base sensors** — These correspond to physical hardware:
- **Accelerometer** (`TYPE_ACCELEROMETER`) — Measures acceleration in m/s^2 along three axes. Includes gravity.
- **Gyroscope** (`TYPE_GYROSCOPE`) — Measures angular velocity in rad/s around three axes.
- **Magnetometer** (`TYPE_MAGNETIC_FIELD`) — Measures magnetic field strength in microteslas along three axes.

**Derived sensors** — Computed from base sensor data:
- **Gravity** (`TYPE_GRAVITY`) — The gravity component extracted from accelerometer data (typically via a low-pass filter)
- **Linear Acceleration** (`TYPE_LINEAR_ACCELERATION`) — Acceleration with gravity removed (accelerometer minus gravity)
- **Rotation Vector** (`TYPE_ROTATION_VECTOR`) — Device orientation computed from accelerometer, gyroscope, and magnetometer data via sensor fusion

### Why Cross-Sensor Consistency Matters

When an app performs a liveness check that correlates visual motion with physical motion, it may read multiple sensor types simultaneously. If you're injecting accelerometer data that says the device is tilting left, the gyroscope data must also show rotation around the appropriate axis, and the gravity vector must shift accordingly.

A perfectly still accelerometer reading (0, 0, 9.81) combined with a gyroscope showing rapid rotation is physically impossible — and advanced liveness SDKs know this. The sensor injection system in the patch-tool addresses this by computing derived sensor values from base sensor inputs, ensuring the physics are internally consistent.

Chapter 9 covers this in detail, including the specific mathematical relationships between sensor types and how to configure profiles that maintain physical plausibility.

### The Physics of Sensor Injection

The mathematical relationships between sensors follow from basic physics:

**Accelerometer and Gravity:** The accelerometer measures total acceleration, which is the sum of linear acceleration (from motion) and gravitational acceleration. A device at rest measures approximately (0, 0, 9.81) m/s^2 — pure gravity pulling downward. Tilting the device redistributes gravity across the axes. A device tilted 30 degrees to the left might read (4.9, 0, 8.5) — gravity is now split between the X and Z axes.

The relationship: `gravity = accelerometer - linear_acceleration`. For a stationary device (no linear acceleration), accelerometer equals gravity. The magnitude should always be approximately 9.81 m/s^2 (the magnitude of Earth's gravity), regardless of orientation.

**Gyroscope and Rotation:** The gyroscope measures angular velocity — how fast the device is rotating around each axis, in radians per second. If the accelerometer shows the gravity vector shifting (indicating the device is tilting), the gyroscope should show non-zero angular velocity on the corresponding axis during the transition.

A gyroscope reading of (0, 0, 0) combined with a rapidly changing accelerometer gravity vector is physically impossible — something is rotating but the gyroscope says nothing is. Advanced liveness SDKs detect this inconsistency.

**Magnetometer and Heading:** The magnetometer measures Earth's magnetic field, which provides compass heading. This is less commonly checked during liveness verification, but some apps use it for orientation estimation. The magnetometer values change as the device rotates in the horizontal plane.

### Where We Hook

The patch-tool hooks `SensorEventListener.onSensorChanged(SensorEvent)`. When the app registers a sensor listener, the hook intercepts the callback and replaces the `SensorEvent` values with configured data. The app receives synthetic sensor readings through the same API it uses for real hardware data.

The sensor hook is slightly different from the camera and location hooks because sensor events fire at high frequency — 50-200 Hz for typical accelerometer sampling. The hook must replace values efficiently (it directly modifies the `SensorEvent.values` float array) without introducing latency that would cause the app's UI to stutter or the liveness check to time out.

---

## Android's Permission Model

Android uses a tiered permission system. Understanding it matters for two reasons: (1) your recon reads permissions to identify attack surfaces, and (2) your deployment grants permissions to avoid runtime dialogs.

### Install-Time vs. Runtime Permissions

**Install-time permissions** are granted automatically when the app is installed. These include internet access (`INTERNET`), network state checks, and other non-sensitive capabilities. You don't need to do anything for these.

**Runtime permissions** (introduced in Android 6.0) require explicit user approval through a dialog. The permissions relevant to this toolkit are all runtime permissions:

- `CAMERA` — Required for camera access
- `ACCESS_FINE_LOCATION` — Required for GPS access
- `ACCESS_COARSE_LOCATION` — Required for approximate location

When you deploy a patched APK via `adb install`, the app is installed but runtime permissions aren't granted. The first time the app tries to use the camera, Android shows a permission dialog. In an automated or headless workflow, this dialog blocks the flow.

The solution is `adb shell pm grant <package> <permission>`, which grants a runtime permission without showing a dialog. This is equivalent to the user tapping "Allow" — the app doesn't know the difference.

### Storage Access and Scoped Storage

The payload files (camera frames, location configs, sensor configs) live on the device's external storage (`/sdcard/`). On Android 10 (API 29), Google introduced Scoped Storage, which restricts apps' ability to read arbitrary files from external storage. This was a privacy improvement — apps shouldn't be able to read each other's files — but it complicates the payload delivery mechanism.

For API 29 (Android 10), the `requestLegacyExternalStorage` flag in the manifest opts out of Scoped Storage. The patch-tool adds this flag during patching.

For API 30+ (Android 11+), `requestLegacyExternalStorage` is ignored. The patch-tool's runtime needs `MANAGE_EXTERNAL_STORAGE` — a special permission that can't be granted with `pm grant`. Instead, you use `adb shell appops set <package> MANAGE_EXTERNAL_STORAGE allow`, which bypasses the system's permission dialog for this specific capability.

This is why the deployment workflow in Chapter 6 includes both `pm grant` commands (for camera and location permissions) and an `appops set` command (for storage access).

### Why `adb shell pm grant` Works

When you run `adb shell pm grant com.example.app android.permission.CAMERA`, you're telling the Android package manager to mark that permission as granted for that app — exactly as if the user had tapped "Allow" on the runtime permission dialog.

This works because `adb shell` runs commands with shell user privileges, and the package manager's grant command accepts requests from the shell user for debuggable apps (which includes all apps installed via `adb install` without a production signing key).

The implications for security are significant: anyone with `adb` access to a device can grant any runtime permission to any debuggable app without user interaction. This is why USB Debugging should never be left enabled on production devices — it gives whoever connects via USB the ability to bypass the entire permission model.

---

## The Application Lifecycle and Hook Bootstrap

Understanding how the hooks activate requires understanding how Android starts an application.

When the user taps an app icon:

1. **Process creation** — The Zygote process forks a new process for the app
2. **Application class instantiation** — Android instantiates the class declared in `android:name` on the `<application>` tag in the manifest
3. **Application.onCreate()** — The Application class's `onCreate()` method fires — this is the earliest app-level code that runs
4. **Activity creation** — Android creates the launcher Activity and calls its lifecycle methods

The patch-tool hooks into step 3. It modifies the Application class's `onCreate()` method to bootstrap the injection runtime: initializing the FrameInterceptor, LocationInterceptor, and SensorInterceptor. By the time any Activity starts and tries to access the camera, location, or sensors, all three interceptors are already armed and waiting.

This is why identifying the Application class during recon (Chapter 5) matters. The patch-tool needs to know which class to modify. If the manifest doesn't declare an Application class (using Android's default), the patch-tool creates one.

The bootstrap sequence:

```text
Application.onCreate()
  -> HookEngine.init()          // Initialize the hook registry
  -> FrameInterceptor.arm()     // Check /sdcard/poc_frames/, arm if frames found
  -> LocationInterceptor.arm()  // Check /sdcard/poc_location/, arm if config found
  -> SensorInterceptor.arm()    // Check /sdcard/poc_sensor/, arm if config found
  -> OverlayController.init()   // Prepare the status overlay (lightning bolt icon)
```

Each interceptor checks for the presence of its payload directory on the device's external storage. If the directory exists and contains valid payloads, the interceptor arms itself. If the directory is empty or absent, the interceptor stays dormant. This is why "push payloads, then launch the app" is the standard operational sequence — the interceptors check for payloads during startup.

---

## APK Signing and Re-Signing

Every APK must be signed with a cryptographic key before Android will install it. The signature serves two purposes: identity (proving the APK came from a specific developer) and integrity (proving the APK hasn't been tampered with since signing).

When the patch-tool modifies an APK — adding DEX files, modifying smali code — the original signature becomes invalid. The patched APK must be re-signed before it can be installed. The patch-tool handles this automatically using `apksigner` from the Android SDK Build-Tools, signing with a debug key.

### Signature Scheme Versions

Android has four APK signing schemes, each more secure than the last:

- **v1 (JAR signing)** — Signs individual files within the ZIP. Compatible with all Android versions. Weakest: doesn't protect the ZIP structure itself.
- **v2 (APK Signature Scheme v2)** — Signs the entire APK as a binary blob. Introduced in Android 7.0 (API 24). Faster verification, protects the entire archive.
- **v3 (APK Signature Scheme v3)** — Adds key rotation support. Introduced in Android 9.0 (API 28).
- **v4 (Incremental signing)** — Adds streaming installation support. Introduced in Android 11 (API 30).

The patch-tool signs with all relevant schemes to ensure compatibility. The key it uses is a debug key, not the original developer's release key — which means the patched APK has a **different signature** than the original.

This has implications:
- You can't install a patched APK over an unpatched one (signature mismatch). You must uninstall first.
- Apps that perform runtime signature verification (checking their own signature against a known value) will detect the re-signing. The patch-tool can patch out these checks, but this is an anti-tamper evasion technique covered in Part IV.
- The debug signature is perfectly fine for testing on emulators and development devices. It won't pass Google Play's installation checks, but that's not the use case.

### The zipalign Step

Before signing, the patched APK is aligned using `zipalign`, which ensures that uncompressed data (particularly DEX files and native libraries) starts at 4-byte boundaries. This alignment improves memory-mapping performance when the Android runtime loads the APK. Without zipalign, the app may start slowly or crash on some devices.

The full pipeline: `apktool build` -> `zipalign` -> `apksigner` -> installable APK.

---

## Why All of This Matters

The architectural pattern across all three subsystems is identical:

1. Hardware generates raw data (pixels, coordinates, acceleration)
2. System services process and route the data
3. Framework APIs deliver the data to app callbacks
4. **App code trusts whatever the callback delivers**

Step 4 is the vulnerability. The app can't verify the data's provenance because the API contract doesn't include provenance. An `ImageProxy` contains pixels — it doesn't certify where those pixels came from. A `Location` object contains coordinates — it doesn't prove those coordinates correspond to satellite signals (even `isMock()` can be hooked). A `SensorEvent` contains acceleration values — it doesn't prove those values came from a physical accelerometer.

By injecting classes into the APK's DEX and hooking the callback methods, the patch-tool inserts itself at step 4 — after the framework delivers data but before the app processes it. The framework's delivery mechanism is untouched. The app's processing logic is untouched. Only the data that flows between them is replaced.

This is why the approach scales across targets. Every CameraX app uses the same callback interface. Every FusedLocationProvider app receives locations through the same callback. Every sensor listener processes events through the same method. The hook points are architectural constants — they don't change between apps, between SDKs, or between Android versions.

---

---

## The Three Interception Patterns

Throughout this book, you'll see three distinct patterns for how the patch-tool modifies application behavior. Understanding these patterns at an architectural level helps you predict what the patch-tool will do to any given target and troubleshoot when something doesn't work as expected.

### Pattern 1: Method Entry Interception

The most common pattern. The patch-tool inserts instructions at the beginning of a method — before any of the method's original code executes. The inserted code can inspect the method's parameters, modify them, or replace them entirely.

Example: The `analyze(ImageProxy)` hook. The original method receives an `ImageProxy` from CameraX. The hook inserts code at the method's entry point that reads the `ImageProxy` parameter, creates a fake `ImageProxy` with injected frame data, and replaces the parameter. The rest of the method's code runs normally, processing the fake data.

This pattern is used for: camera frame injection (all hook points), sensor value injection (`onSensorChanged`), location coordinate injection (`onLocationResult`, `onLocationChanged`).

### Pattern 2: Return Value Replacement

The patch-tool modifies a method to ignore its actual computation and return a predetermined value instead. This is simpler than method entry interception — the original method body may not execute at all.

Example: The `isFromMockProvider()` hook. The original method queries the Location object's internal flags to determine if the location came from a mock provider. The hook replaces the entire method body with `return false`, ensuring mock detection never triggers.

This pattern is used for: mock location detection bypass, certain anti-tamper checks, feature flag overrides.

### Pattern 3: Call-Site Interception

Instead of modifying the target method, the patch-tool modifies the *caller* — the code that calls the target method. This is used when the target method is in a framework class that can't be easily modified (because framework classes are loaded from the system, not from the APK).

Example: An app calls `BitmapFactory.decodeByteArray()` to convert camera output to a Bitmap. The patch-tool can't modify `BitmapFactory` (it's an Android framework class), but it can modify the app's code at the call site to replace the byte array before the call happens.

This pattern is less common and more complex, but it's essential for handling cases where the hook target is in the Android framework rather than in the app's own code.

---

## Bringing It Together

Here's the complete picture of how a patched APK operates:

1. **At build time:** The patch-tool decodes the APK, adds `classes7.dex` (containing all interceptors and runtime classes), inserts hook instructions into target methods in the original smali, rebuilds, zipaligns, and re-signs.

2. **At install time:** `adb install` places the APK on the device. `pm grant` and `appops set` configure permissions. `adb push` places payloads in the expected directories.

3. **At launch:** The Application class's `onCreate()` fires the bootstrap sequence. Each interceptor checks for its payloads and arms if found.

4. **During operation:** When the app accesses the camera, the frame hook fires and delivers injected frames. When the app queries location, the location hook fires and delivers configured coordinates. When the app reads sensors, the sensor hook fires and delivers physics-consistent readings. All three subsystems operate simultaneously and independently.

5. **Evidence capture:** `adb logcat` captures log entries from each interceptor, recording every delivery event. Screenshots capture the app's visual state at each verification step.

This is the architecture that powers everything from Chapter 5 onward. Every technique in this book is an application of this architecture to a specific attack surface.

## What Comes Next

You understand the architecture. You know how camera frames, GPS coordinates, and sensor readings reach application code, and you know why intercepting them at the API boundary works. Chapter 4 builds the environment where you'll put this knowledge into practice: the lab, with an emulator, development tools, and the patch-tool that implements the hooks described in this chapter.
