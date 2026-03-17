---
title: "Reconnaissance"
description: "Systematic APK analysis to map every hookable surface in a target application"
---

Every engagement starts the same way. You do not touch the target. You do not inject anything. You do not think about payloads. You sit down, pull the APK apart, and understand what you are looking at.

This is the discipline that separates a methodical operator from someone who patches blindly and wonders why half the hooks did not fire. Recon is where you build the mental model of the target -- which camera API it uses, which location callbacks it implements, whether it cross-checks sensors, which third-party SDKs process the biometric data, and whether it has defenses like mock location detection or runtime integrity checks. Every one of these answers shapes what happens in the next five chapters.

Skip this step, and you will spend an afternoon debugging what looks like a tool failure -- only to discover the app uses Camera2, not CameraX, and your CameraX hooks were targeting code paths that do not exist. Or you will miss an `isFromMockProvider()` call buried in a utility class, and the geofence step will flag you on mock detection even though the GPS coordinates were perfect. Or you will not realize the app correlates sensor data with visual motion, and your static face frame passes the camera check but fails the liveness challenge because the accelerometer reported zero movement while the face supposedly turned left.

This chapter teaches you to pull any APK off a device or mirror site, crack it open into human-readable smali, systematically map every surface where your hooks will land, and identify the third-party SDKs that dictate how sophisticated your payloads need to be. By the end, you will produce a recon report that reads like an intelligence brief -- telling you exactly what to expect, what to prepare, and where to look when something goes wrong.

> **Ethics Note:** Recon techniques in this chapter -- downloading APKs, decompiling, analyzing code -- are standard practices in authorized security assessments. Ensure you have authorization to analyze the target application before proceeding.

---

## APK Acquisition

You need the APK file on your workstation before anything else can happen. There are two paths depending on whether you have a device with the app installed.

### Pulling from a Device

If the target app is installed on a phone or emulator you control, pull it directly. Start by finding the package name. You probably know the app's display name, but Android identifies everything by package.

```bash
adb shell pm list packages | grep bank
adb shell pm list packages | grep kyc
adb shell pm list packages | grep verify
```

You will get something like `package:com.testbank.onboarding`. That is your target identifier for the rest of the engagement. Write it down -- you will type it dozens of times.

Now find where the APK lives on disk:

```bash
adb shell pm path com.testbank.onboarding
# package:/data/app/~~abc123==/com.testbank.onboarding-xyz789==/base.apk
```

Pull it:

```bash
adb pull /data/app/~~abc123==/com.testbank.onboarding-xyz789==/base.apk target.apk
```

You now have the target APK on your machine.

### The Split APK Problem

Here is something that trips people up regularly: many modern apps do not ship as a single APK anymore. Google Play delivers App Bundles, which means the app gets split into a base APK plus configuration splits for architecture, language, and screen density:

```text
base.apk                       <- the code lives here
split_config.arm64_v8a.apk     <- native libraries for ARM64
split_config.en.apk            <- English resources
split_config.xxhdpi.apk        <- high-density drawables
```

If you see multiple paths when you run `pm path`, pull all of them:

```bash
adb shell pm path com.testbank.onboarding | while read -r line; do
  path=${line#package:}
  name=$(basename "$path")
  adb pull "$path" "$name"
done
```

The patch-tool operates on `base.apk` -- that is where all the Kotlin/Java code is compiled. The splits contain resources and native libraries that you generally do not need to touch. Keep them in your working directory anyway; if you need to rebuild a full installation later, you will want them available.

When an app is split, `base.apk` is often significantly smaller than you would expect. A 120 MB installed app might produce a 40 MB `base.apk` because the architecture-specific native libraries, language resources, and high-density assets live in the splits. Do not let this surprise you -- the code is still complete.

### Pulling Without a Device

If you do not have the app installed, grab it from an APK mirror site:

- **APKMirror** (apkmirror.com) -- verified signatures, most trustworthy
- **APKPure** (apkpure.com) -- also reliable, larger international catalog

Download the full APK when possible, not an XAPK or bundle. If only bundles are available, they are typically ZIP files. Extract them and find `base.apk` inside. Some mirror sites package bundles as `.xapk` files -- rename to `.zip`, unzip, and you will find the base APK among the contents.

One thing to be aware of: mirror sites may be a version behind. If you are targeting a specific app version -- because the client reported a vulnerability in version 3.2.1, not 3.3.0 -- pulling from a device with that version installed is the most reliable approach. Mirror sites also do not always carry every regional variant, and some KYC apps ship different APKs per region.

For the exercises in this book, you will work with the provided target APK ([`materials/targets/target-kyc-basic.apk`](https://github.com/iamjosephmj/AndroidRedTeam/blob/main/materials/targets/target-kyc-basic.apk)), so acquisition is simply a file copy. But on real engagements, the acquisition step matters. Getting the wrong version or a partial bundle wastes time that you will not get back.

---

## Decoding with apktool

You have the APK. Now decode it. `apktool` is the standard tool for this -- it unpacks the APK, converts the compiled bytecode into human-readable smali, decodes binary XML back into readable XML, and extracts all resources.

```bash
apktool d target.apk -o decoded/
```

This takes a few seconds for small apps, up to a minute for large ones with multiple DEX files. When it finishes, you have a directory that looks like this:

```text
decoded/
  AndroidManifest.xml     The app's configuration file. Permissions, activities,
                          services, the Application class -- it's all here.

  smali/                  The app's code, decompiled into smali (human-readable
  smali_classes2/         Dalvik bytecode). Each DEX file gets its own directory.
  smali_classes3/         The directory structure mirrors the Java package hierarchy.
  ...

  res/                    Resources: layouts, drawables, strings, colors.
  assets/                 Raw asset files the app bundles (ML models, configs).
  lib/                    Native libraries (.so files) -- C/C++ code per architecture.
  original/               The original META-INF directory (APK signatures).
  apktool.yml             Metadata apktool uses for rebuilding.
```

The two things you care about for recon are the **manifest** and the **smali directories**. Everything else is secondary at this stage. The `res/` directory matters occasionally -- network security configurations live there, and some apps store SDK configuration in XML resources -- but the core of recon is manifest analysis and smali pattern searching.

### Understanding the Smali Directory Structure

Each `smali*/` directory corresponds to one DEX file from the APK. Inside, the directory tree mirrors the Java/Kotlin package hierarchy. The class `com.testbank.onboarding.camera.FaceAnalyzer` becomes:

```text
smali_classes2/com/testbank/onboarding/camera/FaceAnalyzer.smali
```

When you grep for patterns, you search across all `smali*/` directories because you do not know which DEX file contains the class you are looking for. The app's own code, its third-party libraries, and the Android Jetpack dependencies are distributed across DEX files by the build system -- there is no guaranteed ordering.

Inner classes get a `$` separator in their filename. The anonymous `ImageAnalysis.Analyzer` implementation inside `CameraFragment` might appear as:

```text
smali_classes2/com/testbank/onboarding/camera/CameraFragment$1.smali
```

Or with a named lambda:

```text
smali_classes2/com/testbank/onboarding/camera/CameraFragment$analyzerCallback$1.smali
```

This is why grep is your primary recon tool, not manual browsing. You do not know the class names yet. You are searching for API signatures -- the Android framework interfaces and callbacks that the app must implement to use camera, location, and sensor hardware.

---

## Reading the Manifest

Open `decoded/AndroidManifest.xml`. This is the blueprint of the application. Three things matter immediately.

### The Application Class

```xml
<application android:name="com.testbank.onboarding.BankApplication" ...>
```

This is the first code that runs when the app starts. The Android runtime instantiates this class and calls its `onCreate()` before any Activity appears on screen, before any UI is drawn, before any camera opens. The patch-tool hooks into `onCreate()` of this class to register its lifecycle listener -- that single injection point is the root of the entire hook tree. Everything else chains from it.

If there is no `android:name` attribute on the `<application>` tag, the app uses Android's default `Application` class. The patch-tool handles this too -- it creates a custom Application class and updates the manifest to reference it. But knowing which case you are dealing with helps when troubleshooting. If you see the app's Application class in logcat printing "already patched, skipping," that tells you the patch-tool found and modified the right class.

```bash
grep 'android:name' decoded/AndroidManifest.xml | head -5
```

### Permissions as Attack Surface Map

Permissions are your initial attack surface map. They tell you what hardware and data the app accesses before you read a single line of code:

```xml
<uses-permission android:name="android.permission.CAMERA"/>
```

Camera permission means the app opens the camera somewhere. That is your frame injection surface.

```xml
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
```

Fine location means GPS coordinates at meter-level accuracy. That is your location spoofing surface.

```xml
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
```

Coarse location means cell-tower or Wi-Fi-based positioning. Less common in KYC apps, but still a location surface if present.

```xml
<uses-permission android:name="android.permission.ACTIVITY_RECOGNITION"/>
```

Activity recognition means the app reads motion data -- walking, running, tilting. That is your sensor injection surface, and it strongly suggests the app performs liveness checks that correlate physical movement with visual cues.

```xml
<uses-permission android:name="android.permission.BODY_SENSORS"/>
```

Body sensors are rarer in KYC apps but appear in health-verification flows. Same injection surface as activity recognition.

Not every permission maps to an attack surface. `INTERNET`, `ACCESS_NETWORK_STATE`, `VIBRATE` -- these are common but irrelevant for our purposes. Focus on `CAMERA`, `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, `ACTIVITY_RECOGNITION`, and `BODY_SENSORS`. These are the doors.

```bash
grep 'uses-permission' decoded/AndroidManifest.xml
```

Run that command and catalog every permission. Even the ones that do not map to injection surfaces tell you something about the app's behavior. `RECEIVE_BOOT_COMPLETED` means the app runs a background service. `USE_BIOMETRIC` means the app uses fingerprint or face unlock from the system (distinct from its own camera-based face detection). Every permission is intelligence.

### Exported Activities

Activities with `android:exported="true"` and an intent filter can be launched directly from the command line:

```xml
<activity android:name=".ui.LauncherActivity" android:exported="true">
    <intent-filter>
        <action android:name="android.intent.action.MAIN"/>
        <category android:name="android.intent.category.LAUNCHER"/>
    </intent-filter>
</activity>
```

This tells you how to start the app after you install the patched version:

```bash
adb shell am start -n com.testbank.onboarding/.ui.LauncherActivity
```

Note the full component name format: `package/.relative.ActivityName`. If the activity name in the manifest starts with a dot, it is relative to the package. If it is a full path like `com.testbank.onboarding.ui.LauncherActivity`, you can use either the full or relative form.

You can also use monkey to launch the app without knowing the exact launcher activity:

```bash
adb shell monkey -p com.testbank.onboarding -c android.intent.category.LAUNCHER 1
```

While you are in the manifest, scan for other exported activities. Some apps expose deep-link activities that jump directly to the verification screen -- skipping the login, the terms acceptance, and everything before the KYC flow. If you find one, note it. Jumping directly to the verification screen during testing saves significant time per iteration.

---

## Camera API Identification

This is the most important recon question for this toolkit. CameraX and Camera2 are hooked at different API surfaces, and knowing which one the app uses determines which hooks will fire, which ones will be skipped, and what your logcat output will look like.

### CameraX Indicators

CameraX is Google's modern camera library, built on top of Camera2 but dramatically simpler. Most apps built after 2020 use it, and it is the recommended API in Android's official documentation. CameraX integrates directly with ML Kit, which makes it the default choice for KYC apps.

Search for these indicators:

```bash
# The primary analysis pipeline -- highest-value hook target
grep -rl 'ImageAnalysis\$Analyzer' decoded/smali*/
```

If this returns results, the app implements `ImageAnalysis.Analyzer` -- the real-time frame processing interface. Every frame the camera produces goes through `analyze(ImageProxy)`. This is the primary hook point for frame injection. One hook here controls everything downstream: the SDK's face detection, the liveness algorithm, the quality checks -- all of them receive the frames that pass through this method.

```bash
# Bitmap extraction -- secondary hook point
grep -rn "toBitmap" decoded/smali*/
```

Some SDKs skip the Analyzer pattern and call `toBitmap()` directly on the ImageProxy to extract a Bitmap for their own processing. This is the secondary hook point. It catches SDKs that extract bitmaps without going through the standard pipeline.

```bash
# Preview widget -- confirms CameraX usage
grep -rl "PreviewView" decoded/smali*/
```

PreviewView is CameraX's preview widget. If present, the visual preview will show injected frames through the BitmapSurfaceView overlay. The user sees what you inject.

```bash
# Still photo capture -- tertiary hook point
grep -rl "OnImageCapturedCallback" decoded/smali*/
```

This fires when the app captures a still photo (as opposed to analyzing a continuous stream). Another hook point -- ensures captured photos also contain your injected frames.

**Bottom line:** If you find `ImageAnalysis$Analyzer` or `toBitmap`, you have a CameraX attack surface. The patch-tool hooks all of these automatically.

### Camera2 Indicators

Camera2 is the lower-level camera API. Older apps and some performance-critical apps use it directly for fine-grained control over the capture pipeline.

```bash
# Frame processing callback
grep -rl "OnImageAvailableListener" decoded/smali*/

# Session management
grep -rl "CameraCaptureSession" decoded/smali*/

# Preview surface setup
grep -rl "SurfaceTexture" decoded/smali*/
```

If you find `OnImageAvailableListener`, the app processes camera frames via Camera2's ImageReader callback. If you find `SurfaceTexture`, it sets up a preview surface -- that is where the SurfaceSwapper hooks in to redirect the camera to a decoy while showing your frames on the real display.

### The CameraX-Contains-Camera2 Nuance

This trips up operators who do not understand the layered architecture. CameraX is built on top of Camera2. When you decode a CameraX app, you will find Camera2 classes in the smali -- because CameraX's own implementation uses Camera2 internally.

How do you tell the difference? Look at the package paths in the grep results.

- Matches inside `androidx/camera/camera2/` or `androidx/camera/core/` -- these are CameraX internals. The app uses CameraX, and CameraX uses Camera2 under the hood. You do not need Camera2 hooks.
- Matches inside the app's own package (e.g., `com/testbank/onboarding/camera/`) that reference Camera2 APIs -- the app's developers wrote Camera2 code directly. You need Camera2 hooks.

A concrete example: you grep for `CameraCaptureSession` and get twenty hits. Nineteen are in `androidx/camera/camera2/internal/`. One is in `com/testbank/onboarding/camera/Camera2Analyzer.smali`. That one hit is what matters. The app uses CameraX for its primary flow but also has a Camera2 code path -- possibly a fallback, possibly an alternative implementation for specific devices.

In practice, most KYC apps use one or the other, not both. But when you find both, your recon report should note which classes implement each API so you know which hooks to expect in the patch-tool output.

---

## Location and Sensor Surface Mapping

Camera is the highest-value surface in most KYC engagements, but it is rarely the only one. Location and sensor data complete the picture.

### Location Callbacks

```bash
# FusedLocationProvider -- the modern API, most common
grep -rn "onLocationResult" decoded/smali*/
```

This is the big one. `onLocationResult()` is the callback for `FusedLocationProviderClient` -- Google Play Services' location API. The vast majority of modern apps use this. If you find it, location spoofing will work through the primary hook.

```bash
# LocationManager -- the legacy API
grep -rn "onLocationChanged" decoded/smali*/
```

The legacy `LocationManager` API uses `onLocationChanged()`. Older apps or apps that need to work without Play Services use this. The patch-tool hooks this too.

```bash
# Direct location query -- no callback, one-shot check
grep -rn "getLastKnownLocation" decoded/smali*/
```

Some apps query the last known location directly instead of subscribing to updates. This is common in apps that perform a one-time geofence check during onboarding rather than continuous location monitoring. Also hooked.

```bash
# Mock location detection -- the app's defense
grep -rn "isFromMockProvider\|isMock" decoded/smali*/
```

This is the app's countermeasure. `isFromMockProvider()` (API 18-30) and `isMock()` (API 31+) check whether the location came from a mock provider. Standard GPS spoofing tools set this flag, and apps that check it will reject spoofed locations. The patch-tool neutralizes these by forcing them to return `false`.

If you find mock detection calls, note the specific class and method where they appear. This tells you the developers were security-conscious about location -- which means they might also have other anti-spoofing measures worth investigating, like checking whether any mock location apps are installed or comparing GPS coordinates against IP geolocation.

### Sensor Listeners

```bash
# Sensor event processing -- the hook point
grep -rn "onSensorChanged" decoded/smali*/
```

If the app registers a `SensorEventListener` and implements `onSensorChanged()`, it reads sensor data. In a KYC context, this almost always means the app performs liveness checks that correlate visual motion with physical motion. "Turn your head left" while verifying the accelerometer confirms the corresponding device tilt.

```bash
# Specific sensor types
grep -rn "TYPE_ACCELEROMETER\|TYPE_GYROSCOPE\|TYPE_MAGNETIC" decoded/smali*/
```

This tells you which specific sensor types the app cares about. Accelerometer and gyroscope are the most common pair for liveness. Magnetometer is rarer but appears in apps that check compass heading as part of orientation verification.

If you find `onSensorChanged` but no `TYPE_ACCELEROMETER` or `TYPE_GYROSCOPE` in the app's own code, check the SDK classes -- the liveness SDK might register its own sensor listener independently of the app's code. In that case, the sensor types are embedded in the SDK's smali, not the app's.

The absence of sensor listeners is significant intelligence. If the app has no `onSensorChanged` implementation, liveness is purely visual -- the app relies entirely on camera frames for its liveness determination. This means a well-crafted sequence of face frames might be sufficient without any coordinated sensor data. That makes the engagement substantially simpler.

---

## SDK Identification

Most apps do not build their own face detection or liveness checks. They embed a third-party SDK. Knowing which one is present helps you predict the difficulty of the engagement and the quality of payloads you need.

```bash
# Google ML Kit -- most common, easiest to bypass
grep -rl "com/google/mlkit" decoded/smali*/

# Third-party liveness/verification SDKs
grep -rl "liveness\|verification\|biometric\|identity" decoded/smali*/

# Active liveness indicators
grep -rl "liveness.*challenge\|anti.spoof\|face.map" decoded/smali*/

# Document + face matching indicators
grep -rl "document.*verif\|face.*match\|ocr.*extract" decoded/smali*/
```

The hooks work regardless of which SDK is present, because we intercept at the camera API layer, below the SDK. But SDK identification tells you what to prepare -- ML Kit will accept decent quality face frames with minimal fuss, while an aggressive commercial liveness SDK will require precisely sequenced frames with coordinated sensor data.

### What Each SDK Implies

**Google ML Kit** processes frames through a straightforward pipeline. It receives an `InputImage` (constructed from the `ImageProxy` in the Analyzer callback), runs its face detection model, and returns `Face` objects with bounding boxes, landmark positions, and classification scores (smiling probability, eyes-open probability). ML Kit does not perform liveness detection natively -- apps that use ML Kit for liveness build their own heuristics on top of the face detection output. That means the liveness logic is in the app's code (or a thin wrapper), not in a hardened SDK.

For the operator, this means: your injected frames need a clearly visible face that the ML model can detect. Resolution, lighting, and face angle matter enough to pass ML Kit's quality thresholds, but you do not need to fool sophisticated anti-spoofing algorithms. A frontal face photo with decent lighting typically passes.

**Commercial active liveness SDKs** are designed specifically to prevent the kind of attack described in this book. They perform 3D face mapping using multiple captured frames, analyze texture patterns that distinguish skin from screens and paper, run active liveness challenges (head turns, nods), and cross-check visual motion against sensor data. These SDKs also monitor for common hooking frameworks, check device integrity, and perform server-side validation of captured sessions.

For the operator, this means: you need high-quality face frames that show natural motion across a sequence, matched sensor data that is physically consistent with the visual movement, and potentially additional evasion measures to avoid anti-tampering detection. Engagements against aggressive liveness SDKs are multi-session iterative work, not single-shot bypasses.

**Server-side challenge-response SDKs** add server-side validation to the mix. The server generates a unique visual stimulus -- typically a sequence of colored light patterns displayed on the screen -- and the client captures the user's face as the stimulus plays. The server verifies both the liveness of the face and the presence of the correct light reflections on the face from the stimulus. Each session has a unique challenge, making replay attacks harder.

For the operator, this means: pre-recorded frames alone will not pass because each session expects a unique light pattern reflected on the face. You need to understand how the SDK's client-side code processes the challenge and where the frames are captured relative to the stimulus display. The client-side capture still goes through the camera API you control, but the frames need to show the correct light response for the specific session.

**Document-plus-biometric SDKs** combine document verification with biometric face matching. They capture the ID document, extract the photo via OCR, then compare it against a live selfie with their own liveness checking. Their primary strength is document analysis -- they look for microprinting, holographic elements, and physical security features that photographs of documents do not reproduce well.

For the operator, this means: you need two sets of frames (document and face), and the face frames must match the face on the document closely enough to pass the SDK's comparison algorithm. These SDKs also implement their own sensor checks and device integrity verification. The engagement requires coordinated payloads across the document capture and selfie capture phases.

**Hybrid document-biometric SDKs** may operate similarly to dedicated document verification SDKs -- document capture followed by biometric verification -- but with their own liveness pipeline. Their liveness checking may include both passive analysis (texture, depth estimation) and active challenges. These tend to be slightly less aggressive than dedicated active liveness SDKs but more thorough than ML Kit.

---

## SDK Deep Dives: How Each Processes Frames

Understanding how each SDK processes frames internally helps you craft payloads that pass their specific checks. The hook fires at the camera API level, but the SDK's internal pipeline determines what the injected data needs to look like.

### ML Kit Frame Processing

ML Kit's face detection pipeline is the most straightforward:

1. The app's `Analyzer.analyze()` receives an `ImageProxy` from CameraX
2. The app constructs an `InputImage` from the proxy (via `InputImage.fromMediaImage()`)
3. The app passes the `InputImage` to `FaceDetector.process()`
4. ML Kit's on-device model runs face detection and returns a list of `Face` objects
5. The app inspects the `Face` results -- bounding box, landmarks, classification scores

The hook fires at step 1. By the time ML Kit sees the data, it is already your injected frame. ML Kit does not verify frame provenance -- it processes whatever pixels it receives. The model runs entirely on-device with no server-side validation, so there is no external check to worry about.

The key constraint is that ML Kit needs to successfully detect a face in your frames. That means: the face must be roughly centered, adequately lit, at a reasonable size relative to the frame (not too small, not cropped), and at an angle the model can handle (frontal or near-frontal). ML Kit's model is robust -- it handles moderate variation in lighting and angle -- but extremely dark, blurry, or heavily rotated faces will fail detection.

### Commercial Active Liveness SDK Processing

An aggressive active liveness SDK's pipeline is more complex:

1. The SDK opens the camera independently (via CameraX or Camera2) and captures a burst of frames
2. Each frame undergoes 3D depth estimation using frame-to-frame parallax and structural analysis
3. Texture analysis checks for screen moire patterns, paper grain, and other replay artifacts
4. If active liveness is configured, the SDK instructs the user to perform actions and tracks facial landmarks across frames to verify the motion occurred
5. Sensor data (accelerometer, gyroscope) is correlated with observed visual motion
6. The captured data is packaged and sent to the SDK's server for a second round of verification

Your hooks still fire at step 1 -- you control what frames the SDK receives. But the quality bar is higher. The SDK's depth estimation expects frames with slight natural variation between them (micro-movements, lighting shifts) that indicate a live 3D face rather than a flat image. Injecting the same static frame repeatedly will fail the depth check. You need a sequence of frames showing subtle natural motion -- breathing movement, micro-expressions, slight positional shifts.

At step 5, the sensor data must be consistent with what the frames show. If the frames depict a head turning left, the accelerometer and gyroscope readings must show the corresponding device tilt. Mismatched visual and physical motion is a strong signal that the data is fabricated.

### Server-Side Challenge-Response SDK Processing

A server-side challenge-response SDK's pipeline differs fundamentally because of the server-generated challenge:

1. The client requests a session from the SDK's server
2. The server returns a unique challenge token and a light pattern specification
3. The client displays the light pattern on the screen while the front camera captures the user's face
4. The client sends the captured frames plus the challenge token to the server
5. The server verifies: (a) a live face is present, (b) the correct light reflections appear on the face for the specific challenge pattern

The hook fires during step 3. You control the frames captured by the camera. The challenge is at step 5 -- the server expects to see specific light reflections that correspond to the challenge pattern displayed during *this particular session*. Pre-recorded frames from a different session will have the wrong light pattern.

This makes server-side challenge-response SDKs significantly harder to bypass with simple frame replay. The operator needs to understand the timing of when the SDK captures frames relative to its light display and how the reflection analysis works. The frames themselves still pass through the camera API you control, but generating frames that satisfy the server's reflection check requires per-session adaptation.

### Document-Plus-Biometric SDK Processing

A document-plus-biometric SDK's pipeline handles two distinct capture phases:

1. **Document capture:** The camera captures the ID document. The SDK runs OCR to extract text fields and analyzes the document for security features (microprinting, holographic elements, UV patterns on supported devices).
2. **Face capture:** The camera switches to the front-facing camera and captures the user's face with liveness checking.
3. **Comparison:** The SDK extracts the photo from the document (from step 1) and compares it against the captured face (from step 2) using a facial similarity model.

The hook must handle the transition between phases. During document capture, you inject document frames. During face capture, you inject face frames. The operational challenge is timing: knowing when the app transitions from one phase to the other so you can switch payload sources. Chapter 10 covers mid-flow payload switching in detail.

The comparison at step 3 constrains your payloads -- the face frames must depict a face that matches the document photo to within the SDK's similarity threshold. You cannot use arbitrary face frames. They must match the identity document you are also injecting.

---

## Automated Recon Scripting

Running the same dozen grep commands for every target gets repetitive. A recon script standardizes the process, ensures you never skip a check, and produces consistent output you can diff across targets.

Here is a practical `recon.sh` script that covers every surface:

```bash
#!/usr/bin/env bash
# recon.sh -- Automated reconnaissance for decoded APK directories
# Usage: ./recon.sh <decoded-dir>

set -euo pipefail

DIR="${1:?Usage: recon.sh <decoded-dir>}"

if [ ! -f "$DIR/AndroidManifest.xml" ]; then
    echo "ERROR: $DIR does not contain AndroidManifest.xml"
    exit 1
fi

echo "=========================================="
echo " RECON REPORT"
echo " Target: $DIR"
echo " Date: $(date +%Y-%m-%d)"
echo "=========================================="

echo ""
echo "--- APPLICATION CLASS ---"
grep '<application' "$DIR/AndroidManifest.xml" | grep -o 'android:name="[^"]*"' || echo "  (default Application class)"

echo ""
echo "--- PERMISSIONS ---"
grep 'uses-permission' "$DIR/AndroidManifest.xml" | sed 's/.*android:name="//;s/".*//' | sort

echo ""
echo "--- LAUNCHER ACTIVITY ---"
grep -B2 'android.intent.category.LAUNCHER' "$DIR/AndroidManifest.xml" \
  | grep 'android:name' | head -1 \
  | sed 's/.*android:name="//;s/".*//' || echo "  (not found)"

echo ""
echo "--- CAMERA: CameraX ---"
echo "  ImageAnalysis.Analyzer:"
grep -rl 'ImageAnalysis\$Analyzer' "$DIR"/smali*/ 2>/dev/null | head -10 || echo "    not found"
echo "  toBitmap:"
grep -rl 'toBitmap' "$DIR"/smali*/ 2>/dev/null | head -10 || echo "    not found"
echo "  PreviewView:"
grep -rl 'PreviewView' "$DIR"/smali*/ 2>/dev/null | head -10 || echo "    not found"
echo "  OnImageCapturedCallback:"
grep -rl 'OnImageCapturedCallback' "$DIR"/smali*/ 2>/dev/null | head -10 || echo "    not found"

echo ""
echo "--- CAMERA: Camera2 ---"
echo "  OnImageAvailableListener:"
grep -rl 'OnImageAvailableListener' "$DIR"/smali*/ 2>/dev/null | head -10 || echo "    not found"
echo "  CameraCaptureSession:"
grep -rl 'CameraCaptureSession' "$DIR"/smali*/ 2>/dev/null \
  | grep -v 'androidx/camera' | head -10 || echo "    not found (or CameraX internals only)"
echo "  SurfaceTexture (app code):"
grep -rl 'SurfaceTexture' "$DIR"/smali*/ 2>/dev/null \
  | grep -v 'androidx/camera' | head -10 || echo "    not found (or CameraX internals only)"

echo ""
echo "--- LOCATION ---"
echo "  onLocationResult:"
grep -rn 'onLocationResult' "$DIR"/smali*/ 2>/dev/null | head -10 || echo "    not found"
echo "  onLocationChanged:"
grep -rn 'onLocationChanged' "$DIR"/smali*/ 2>/dev/null | head -10 || echo "    not found"
echo "  getLastKnownLocation:"
grep -rn 'getLastKnownLocation' "$DIR"/smali*/ 2>/dev/null | head -10 || echo "    not found"
echo "  Mock detection:"
grep -rEn 'isFromMockProvider|isMock' "$DIR"/smali*/ 2>/dev/null | head -10 || echo "    not found"

echo ""
echo "--- SENSORS ---"
echo "  onSensorChanged:"
grep -rn 'onSensorChanged' "$DIR"/smali*/ 2>/dev/null | head -10 || echo "    not found"
echo "  Sensor types:"
grep -rEn 'TYPE_ACCELEROMETER|TYPE_GYROSCOPE|TYPE_MAGNETIC' "$DIR"/smali*/ 2>/dev/null | head -10 || echo "    not found"

echo ""
echo "--- THIRD-PARTY SDKs ---"
echo "  ML Kit: $(grep -rl 'com/google/mlkit' "$DIR"/smali*/ 2>/dev/null | wc -l | tr -d ' ') files"
echo "  Liveness SDK: $(grep -rEl 'liveness|anti.spoof|face.map' "$DIR"/smali*/ 2>/dev/null | wc -l | tr -d ' ') files"
echo "  Challenge-response: $(grep -rEl 'challenge|stimulus|light.pattern' "$DIR"/smali*/ 2>/dev/null | wc -l | tr -d ' ') files"
echo "  Document verification: $(grep -rEl 'document.*verif|ocr.*extract|face.*match' "$DIR"/smali*/ 2>/dev/null | wc -l | tr -d ' ') files"
echo "  Biometric platform: $(grep -rEl 'biometric|identity.*verif' "$DIR"/smali*/ 2>/dev/null | wc -l | tr -d ' ') files"

echo ""
echo "--- ANTI-TAMPER (bonus) ---"
echo "  Signature verification:"
grep -rn 'GET_SIGNATURES\|getPackageInfo' "$DIR"/smali*/ 2>/dev/null | wc -l | tr -d ' '
echo "  Root/emulator detection:"
grep -rEn 'su\b|/system/xbin|Superuser|magisk|goldfish|sdk_gphone' "$DIR"/smali*/ 2>/dev/null | wc -l | tr -d ' '
echo "  Certificate pinning:"
grep -rn 'CertificatePinner' "$DIR"/smali*/ 2>/dev/null | wc -l | tr -d ' '

echo ""
echo "--- ASSETS & CONFIGS ---"
echo "  JSON configs:"
find "$DIR"/assets/ "$DIR"/res/raw/ -name "*.json" 2>/dev/null || echo "    none"
echo "  ML models:"
find "$DIR"/assets/ "$DIR"/res/raw/ -name "*.tflite" -o -name "*.onnx" -o -name "*.pt" 2>/dev/null || echo "    none"
echo "  Remote Config defaults:"
[ -f "$DIR/res/xml/remote_config_defaults.xml" ] && echo "    FOUND" || echo "    not found"
echo "  Properties/config files:"
find "$DIR"/assets/ "$DIR"/res/raw/ -name "*.properties" -o -name "*.cfg" -o -name "*.yaml" 2>/dev/null || echo "    none"

echo ""
echo "=========================================="
```

A ready-to-use version of this script is included in the materials kit at [`materials/scripts/recon.sh`](https://github.com/iamjosephmj/AndroidRedTeam/blob/main/materials/scripts/recon.sh). You can also save the above as `recon.sh` in your project root and make it executable (`chmod +x recon.sh`). Run it against any decoded APK directory:

```bash
apktool d target.apk -o decoded/
./recon.sh decoded/
```

The script produces a structured report you can redirect to a file, diff against previous versions of the same app, or use as the raw input for your formal recon report.

The anti-tamper section at the bottom is bonus intelligence. Signature verification checks, root detection, and certificate pinning do not affect whether the hooks fire -- but they tell you whether the app has runtime integrity defenses that might interfere with launching the patched APK. If you see high hit counts for signature verification or root detection, plan for the evasion techniques covered in later chapters.

---

## Reading jadx Output Alongside Smali

Smali is powerful for hook-point identification -- you search for specific API signatures and find exactly where they appear in the bytecode. But smali is not easy to read for understanding program logic. When you need to understand *how* the app uses a particular API -- not just that it uses it -- jadx gives you a complementary view.

jadx is a DEX-to-Java decompiler. It takes the same DEX bytecode that apktool converts to smali and converts it to approximate Java source code instead. The output is not perfect -- decompilation is lossy, and some constructs do not roundtrip cleanly -- but for reading program flow, it is dramatically more accessible than smali.

```bash
jadx target.apk -d jadx-output/
```

Now you have two views of the same code:

- `decoded/smali*/` -- the smali view, where grep patterns find hook points
- `jadx-output/` -- the Java view, where you read what the code around those hook points actually does

### The Complementary Workflow

Here is how you use them together. Suppose your grep found this:

```text
decoded/smali_classes2/com/testbank/onboarding/location/LocationVerifier.smali
```

You know `onLocationResult` lives in that class. Now open the jadx version:

```text
jadx-output/sources/com/testbank/onboarding/location/LocationVerifier.java
```

In jadx output, the same class might look like:

```java
public class LocationVerifier extends LocationCallback {
    private static final double ALLOWED_LAT = 40.758;
    private static final double ALLOWED_LNG = -73.9855;
    private static final double RADIUS_KM = 50.0;

    @Override
    public void onLocationResult(LocationResult result) {
        Location loc = result.getLastLocation();
        if (loc == null) return;

        if (loc.isFromMockProvider()) {
            reportFraud("mock_location_detected");
            return;
        }

        double distance = haversine(loc.getLatitude(), loc.getLongitude(),
                                     ALLOWED_LAT, ALLOWED_LNG);
        if (distance > RADIUS_KM) {
            reportFraud("outside_geofence");
            return;
        }

        proceedToNextStep();
    }
}
```

Now you know things that grep alone would not tell you:

- The geofence center is at 40.758, -73.9855 (Times Square, New York)
- The radius is 50 km
- Mock detection happens *before* the geofence check -- if mock detection is bypassed, the location still needs to fall within the radius
- The app calls `reportFraud()` for both mock detection and geofence failure -- which means your logcat might show fraud reports if your coordinates are wrong

This information directly feeds your payload configuration. You now know the exact coordinates to configure in your location JSON, and you know the tolerance -- anywhere within 50 km of Times Square will pass.

### When to Use Which

Use **smali grep** for:
- Finding hook surfaces (API signatures across the entire codebase)
- Confirming whether specific framework methods are called anywhere
- Counting how many classes implement a particular interface
- Quick pass/fail checks ("does this app use onSensorChanged?")

Use **jadx** for:
- Understanding the logic surrounding a hook point
- Extracting hardcoded values (geofence coordinates, timeout thresholds, quality scores)
- Tracing call chains (what happens after `onLocationResult` returns?)
- Identifying conditional branches that might bypass your hooks

You do not need to jadx-decompile every target. For straightforward engagements -- ML Kit, single location check, no sensors -- the smali grep is sufficient. But when you encounter a complex target with multiple verification stages, custom liveness logic, or unusual SDK integration, jadx is the tool that turns "I know the hook point exists" into "I understand what the app does with the data."

### jadx Limitations

jadx output is not always correct Java. Obfuscated apps produce classes like `a.b.c` with methods named `a()`, `b()`, `c()` -- readable in structure but opaque in meaning. Complex control flow sometimes decompiles into invalid Java with goto-like labels. Kotlin coroutines produce particularly ugly decompiled output.

When jadx output is unclear, fall back to the smali. Smali is always accurate -- it is a direct translation of the bytecode. jadx is an approximation. Use jadx for the big picture, smali for precision.

---

## Compiling the Recon Report

You have done the work. Now document it. A recon report serves two purposes: it tells you what to prepare for the execution phase, and it becomes part of your engagement deliverable.

```markdown
# Recon Report: TestBank Onboarding v3.2.1

## Target
- Package: com.testbank.onboarding
- Version: 3.2.1
- Application class: com.testbank.onboarding.BankApplication
- Launcher activity: com.testbank.onboarding.ui.LauncherActivity

## Permissions
- [x] CAMERA
- [x] ACCESS_FINE_LOCATION
- [ ] ACCESS_COARSE_LOCATION
- [ ] ACTIVITY_RECOGNITION
- [ ] BODY_SENSORS

## Camera Attack Surface
- API: CameraX
- Hook targets found:
  - [x] ImageAnalysis.Analyzer -- smali_classes2/com/testbank/onboarding/camera/FaceAnalyzer.smali
  - [x] toBitmap() -- smali/androidx/camera/core/ImageProxy.smali
  - [x] OnImageCapturedCallback -- smali_classes2/com/testbank/onboarding/camera/CaptureCallback.smali
  - [ ] OnImageAvailableListener -- not found (not Camera2)
  - [ ] SurfaceTexture -- only CameraX internals

## SDK Identification
- Primary SDK: Google ML Kit (face detection)
- ML Kit files: 47 files in com/google/mlkit/
- Secondary SDK: none detected

## Location Attack Surface
- API: FusedLocationProvider
- Hook targets found:
  - [x] onLocationResult() -- smali_classes2/com/testbank/onboarding/location/LocationVerifier.smali
  - [ ] onLocationChanged() -- not found (does not use legacy API)
  - [ ] getLastKnownLocation() -- not found
  - [x] Mock detection: isFromMockProvider -- smali_classes2/com/testbank/onboarding/location/LocationVerifier.smali
- Geofence parameters (from jadx): center 40.758, -73.9855, radius 50 km

## Sensor Attack Surface
- Hook targets found:
  - [ ] onSensorChanged() -- not found
  - Sensor types: none

## Anti-Tamper
- Signature verification: 0 hits
- Root/emulator detection: 0 hits
- Certificate pinning: 0 hits

## Assessment
- Hookable surfaces: Camera (CameraX, 3 hooks), Location (FusedLocation, 1 hook + mock bypass)
- Expected hooks to fire: analyze(), toBitmap(), onCaptureSuccess(), onLocationResult()
- SDK: ML Kit (face detection only, no native liveness)
- Predicted difficulty: Low
  - Standard CameraX + ML Kit, no sensor correlation
  - No sensor listener means liveness is purely visual
  - Single face frame may be sufficient if the SDK does not require movement
  - Location check appears to be one-time geofence verification
  - Mock detection is present -- will be neutralized by patch-tool
  - No anti-tamper defenses detected
- Payload requirements:
  - Camera frames: face-neutral sequence, 640x480 PNG, minimum 10 frames
  - Location config: 40.758, -73.9855 (or anywhere within 50 km)
  - Sensor config: not required (no sensor listeners)
```

That last section -- the **Assessment** -- is where your operator judgment lives. It is where you take the raw grep results and turn them into an attack plan. How many frame sequences do you need? Do you need sensor configs? Is the location check one-shot or continuous? What happens if the first attempt fails -- are there retry limits? This is what separates running a tool from running an engagement.

### Assessment Guidance

When writing the assessment, address these questions explicitly:

**Predicted difficulty.** Low means standard APIs, common SDK, no sensor correlation. Medium means active liveness, sensor checks, or an aggressive commercial liveness SDK. High means server-side validation, per-session challenges from a server-side challenge-response SDK, or multiple anti-tamper defenses.

**Payload requirements.** What camera frames do you need? Static face or motion sequence? What resolution? What location coordinates, and how precise? Do you need sensor data, and if so, which profiles?

**Expected hook behavior.** Which hooks will fire and in what order? This helps you interpret the logcat output during execution. If your recon says three camera hooks should fire and you only see two, you know something is wrong immediately.

**Risk factors.** What could go wrong? If the app has mock detection, note that it will be neutralized but the possibility of additional checks exists. If the app uses an aggressive commercial liveness SDK, note that server-side validation may reject data that passes client-side checks. If the app has root detection, note that the emulator may trigger it.

---

## Key Terminology

A few terms used throughout this chapter and the rest of the book:

**smali** -- The human-readable form of Android's Dalvik bytecode. When apktool decodes an APK, it converts the compiled `.dex` files into `.smali` text files -- one file per Java/Kotlin class. The directory structure mirrors the package hierarchy (`com/testbank/onboarding/camera/FaceAnalyzer.smali`). You do not need to read smali fluently for recon -- you grep it to find method signatures and class references. But understanding that each file represents a class, and that inner classes use the `$` separator in filenames, helps you navigate large codebases quickly.

**Hook surface** -- A method in the app's code that the patch-tool will intercept and instrument. Think of it as an insertion point -- a seam in the code where you can place yourself between the app and the data it receives. The more surfaces you find during recon, the more comprehensive your control. A single missed surface is a code path where real data leaks through unmodified.

**Application class** -- The first Java/Kotlin class that runs when the app process starts. Android instantiates it and calls its `onCreate()` before any Activity appears on screen. The patch-tool injects a single line into this method to register the `ActivityLifecycleHook` -- that one line is the root of the entire injection tree. Everything else chains from that single bootstrap call.

**Exported activity** -- An Activity that can be started directly from outside the app, typically with `adb shell am start`. The launcher activity (the one with the `MAIN` + `LAUNCHER` intent filter) is always exported. Being able to cold-start the app via `adb` is essential for both interactive testing and headless automated workflows.

---

## What Comes Next

You now have a complete picture of the target: which camera API it uses, which location callbacks it implements, whether sensors are in play, which SDK processes the biometric data, and what defenses exist. You have a structured recon report with an assessment section that reads like an attack plan.

Chapter 6 takes this intelligence and puts it into action. You will run the patch-tool against the target APK -- one command that decodes, injects 1,134 runtime classes, patches every hook surface your recon identified, rebuilds the APK, and signs it. The patch-tool's output is a flight recorder: it tells you exactly which hooks it applied, which it skipped, and why. You will cross-reference that output against your recon report, and everything should match. If it does not, you know exactly where to investigate.

Lab 1 is the companion exercise for this chapter. It walks you through complete recon against the course target APK ([`materials/targets/target-kyc-basic.apk`](https://github.com/iamjosephmj/AndroidRedTeam/blob/main/materials/targets/target-kyc-basic.apk)), from decoding through report generation. Do the lab before moving to Chapter 6 -- the recon report you produce becomes the input for the next chapter's patching exercise, and having done the analysis yourself means you will understand exactly what the patch-tool's output is telling you.

Every minute you spend on recon saves ten minutes during execution. The operators who consistently pass multi-step targets on the first attempt are not luckier. They are better at recon.
