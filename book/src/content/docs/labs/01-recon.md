---
title: "Lab 1: APK Recon"
description: "Decode a target APK, map every hookable surface, and produce an intelligence report"
---

**Prerequisites:** Lab 0 passed (all environment checks green). Chapter 5 (Reconnaissance) read.
**Estimated time:** 30 minutes.
**Chapter reference:** Chapter 5 -- Reconnaissance.

In this lab you will decode the course target APK, interrogate its manifest, identify which camera API it uses, map its location and sensor surfaces, identify the third-party SDK that processes biometric data, and compile a structured recon report. The report you produce here drives every decision in Labs 2 through 6. If you skip something or get it wrong, you will discover the error later as a mysterious hook failure -- and you will end up back here doing the recon you should have done the first time.

The target is [`materials/targets/target-kyc-basic.apk`](https://github.com/iamjosephmj/AndroidRedTeam/blob/main/materials/targets/target-kyc-basic.apk) (package: `com.poc.biometric`). All commands assume you are working from the project root.

---

## Step 1: Decode the APK

Use `apktool` to decode the target into human-readable smali and XML:

```bash
apktool d materials/targets/target-kyc-basic.apk -o recon-decoded/
```

This takes a few seconds. When it finishes, you have a directory tree containing the decoded manifest, smali bytecode, resources, and assets.

Verify the decode succeeded:

```bash
ls recon-decoded/
```

You should see `AndroidManifest.xml`, multiple `smali*/` directories, `res/`, `assets/`, `lib/`, and `apktool.yml`. If any of these are missing, the decode failed -- check your apktool version.

Inspect the scale of the target:

```bash
ls -d recon-decoded/smali*/
```

Count the smali directories. Each one corresponds to a DEX file in the APK. The course target has multiple DEX files -- the app's own code, its Jetpack dependencies, and the third-party SDKs are distributed across them. This is why you always search across `smali*/` (wildcard), never just `smali/`.

---

## Step 2: Interrogate the Manifest

Open the manifest and extract the three things that matter most.

### 2a: Application Class

```bash
grep '<application' recon-decoded/AndroidManifest.xml | grep -o 'android:name="[^"]*"'
```

**Expected output:**

```text
android:name="com.poc.PocApplication"
```

Record this. The patch-tool injects its bootstrap hook into this class's `onCreate()` method. If the manifest did not declare a custom Application class (no `android:name` attribute), the patch-tool would create one. Knowing which case you are dealing with matters for verification later.

### 2b: Permissions

```bash
grep 'uses-permission' recon-decoded/AndroidManifest.xml
```

Catalog every permission. Pay attention to:

| Permission | Attack Surface |
|-----------|---------------|
| `CAMERA` | Frame injection target |
| `ACCESS_FINE_LOCATION` | GPS spoofing target |
| `ACCESS_COARSE_LOCATION` | GPS spoofing target (lower precision) |
| `ACTIVITY_RECOGNITION` | Sensor injection target |
| `BODY_SENSORS` | Sensor injection target |

Other permissions (`INTERNET`, `ACCESS_NETWORK_STATE`, etc.) are common but not attack surfaces for this toolkit. Record them anyway -- they tell you about the app's behavior.

### 2c: Launcher Activity

```bash
grep -B2 'android.intent.category.LAUNCHER' recon-decoded/AndroidManifest.xml \
  | grep 'android:name'
```

**Expected output shows:** `com.poc.biometric.ui.LauncherActivity`

This is the activity you will launch after deploying the patched APK. Record the full component name.

---

## Step 3: Identify the Camera API

This is the most important question in the recon. The answer determines which hooks fire and which are skipped.

### 3a: CameraX Indicators

```bash
grep -rl 'ImageAnalysis\$Analyzer' recon-decoded/smali*/
```

If this returns results in the app's own package (look for `com/poc/biometric` in the path), the app implements `ImageAnalysis.Analyzer` -- the CameraX real-time analysis interface. This is the primary hook target for frame injection.

```bash
grep -rn "toBitmap" recon-decoded/smali*/
```

Look for `toBitmap` calls that appear in the app's code, not just in the CameraX framework internals.

```bash
grep -rl "OnImageCapturedCallback" recon-decoded/smali*/
```

This finds still-photo capture callbacks. Another CameraX hook point.

```bash
grep -rl "PreviewView" recon-decoded/smali*/
```

PreviewView confirms the app uses CameraX for its camera preview UI.

### 3b: Camera2 Indicators

```bash
grep -rl "OnImageAvailableListener" recon-decoded/smali*/ | grep -v 'androidx/camera'
```

```bash
grep -rl "CameraCaptureSession" recon-decoded/smali*/ | grep -v 'androidx/camera'
```

The `grep -v 'androidx/camera'` filter is critical. CameraX is built on top of Camera2. When you decode a CameraX app, you will find Camera2 classes in the smali -- because CameraX uses Camera2 internally. You need to distinguish between CameraX internals and app-level Camera2 usage. Only matches in the app's own package (`com/poc/biometric/`) indicate the app uses Camera2 directly.

### 3c: Record Your Finding

For the course target, you should find:

- CameraX indicators present: `ImageAnalysis$Analyzer`, `toBitmap`, `OnImageCapturedCallback`, `PreviewView` -- all found in the app's code.
- Camera2 indicators: only found in `androidx/camera/` (CameraX internals). No app-level Camera2 usage.

**Conclusion: The target uses CameraX, not Camera2.**

This means the CameraX hooks (`analyze`, `toBitmap`, `onCaptureSuccess`) will fire, and the Camera2 hooks (`Surface(SurfaceTexture)`, `getSurface`, `OnImageAvailableListener`) will be skipped with `[!]` warnings. That is correct and expected.

---

## Step 4: Map Location Surfaces

### 4a: Location Callbacks

```bash
grep -rn 'onLocationResult' recon-decoded/smali*/
```

Look for matches in the app's own code. The `onLocationResult()` callback is the hook point for `FusedLocationProviderClient` -- the modern location API.

```bash
grep -rn 'onLocationChanged' recon-decoded/smali*/
```

This finds legacy `LocationManager` callbacks. If the target uses only the Fused API, this should return no app-code matches.

```bash
grep -rn 'getLastKnownLocation' recon-decoded/smali*/
```

One-shot location queries. Some apps check the last known location as a quick initial geofence verification.

### 4b: Mock Detection

```bash
grep -rEn 'isFromMockProvider|isMock' recon-decoded/smali*/
```

This is the app's defense. `isFromMockProvider()` (API 18-30) and `isMock()` (API 31+) check whether a location came from a mock provider. If the target implements these checks, the patch-tool neutralizes them by forcing `false`.

Record which classes contain mock detection. Note whether mock detection is in the app's own code or in a third-party library -- this tells you whether the developers added it deliberately or it came bundled with an SDK.

### 4c: Record Your Findings

For the course target, you should find:

- `onLocationResult()` present in a class related to location handling (e.g., `LocationActivity` or similar).
- Mock detection present (`isFromMockProvider` or `isMock`).
- No legacy `onLocationChanged()` in the app's own code.

---

## Step 5: Map Sensor Surfaces

```bash
grep -rn 'onSensorChanged' recon-decoded/smali*/
```

If the app registers a `SensorEventListener`, this returns the class and method where sensor events are processed. In a KYC context, sensor processing typically means the app checks device motion during liveness challenges.

```bash
grep -rEn 'TYPE_ACCELEROMETER|TYPE_GYROSCOPE|TYPE_MAGNETIC' recon-decoded/smali*/
```

This tells you which specific sensor types the app reads. Accelerometer and gyroscope are the standard pair for liveness correlation.

### Record Your Findings

For the course target, look for `onSensorChanged` in a class such as `SensorActivity`. Note whether it appears in the app's own code or only in SDK internals. If the app does not register a `SensorEventListener` at all, that is significant intelligence -- it means liveness detection is purely visual and does not correlate physical motion.

---

## Step 6: Identify Third-Party SDKs

```bash
grep -rl 'com/google/mlkit' recon-decoded/smali*/ | head -5
```

```bash
# Search for other commercial liveness/verification SDKs
grep -rEl 'liveness|verification|biometric|identity' recon-decoded/smali*/ | head -10
```

For the course target, you should find **Google ML Kit** present (files in `com/google/mlkit/`). Other commercial liveness SDKs should not be present.

ML Kit is the simplest SDK to bypass. It processes frames through a straightforward pipeline: the app constructs an `InputImage` from the `ImageProxy`, passes it to `FaceDetector.process()`, and receives `Face` objects with bounding boxes and landmark positions. ML Kit does not perform liveness detection natively -- any liveness logic is in the app's own code or a thin wrapper. Your injected frames need a clearly visible face that the model can detect, but you do not need to defeat sophisticated anti-spoofing algorithms.

---

## Step 7: Compile the Recon Report

Take everything you found and organize it into a structured report. Use this template:

```text
==========================================
 RECON REPORT
 Target: target-kyc-basic.apk
 Package: com.poc.biometric
 Date: YYYY-MM-DD
==========================================

APPLICATION CLASS
  com.poc.PocApplication

LAUNCHER ACTIVITY
  com.poc.biometric.ui.LauncherActivity

PERMISSIONS
  CAMERA
  ACCESS_FINE_LOCATION
  [... list all permissions found ...]

CAMERA API
  CameraX: YES
    - ImageAnalysis.Analyzer: found in [filename]
    - toBitmap: found
    - OnImageCapturedCallback: found
    - PreviewView: found
  Camera2 (app-level): NO
    - Only found in CameraX internals (androidx/camera/)

LOCATION
  onLocationResult: found in [filename]
  onLocationChanged: not found (app does not use legacy API)
  getLastKnownLocation: [found/not found]
  Mock detection: [found/not found, list classes]

SENSORS
  onSensorChanged: [found/not found, list classes]
  Sensor types: [list types found]

THIRD-PARTY SDKs
  Google ML Kit: YES ([N] files)
  Other commercial SDKs: NO

ASSESSMENT
  The target uses CameraX for camera processing with Google ML Kit
  for face detection. Location is handled via FusedLocationProvider
  with mock detection present. [Note sensor findings.]

  Expected patch-tool behavior:
  - CameraX hooks: analyze(), toBitmap(), onCaptureSuccess() -- WILL fire
  - Camera2 hooks: -- will be SKIPPED (target does not use Camera2)
  - Location hooks: onLocationResult() -- WILL fire
  - Sensor hooks: [expected behavior based on findings]

==========================================
```

Fill in every field. The Assessment section is not optional -- it is where you translate raw findings into operational predictions. When you run the patch-tool in Lab 2, you will compare its output against these predictions line by line.

Save the report:

```bash
# If you created a script or manual report:
cat recon-report.txt
```

---

## Step 8: Automated Verification

Run the `recon.sh` script from Chapter 5 against the decoded directory to cross-check your manual findings:

```bash
chmod +x recon.sh
./recon.sh recon-decoded/
```

Compare the script output against your manual report. Every finding should match. If the script found something you missed, go back and investigate. If you found something the script missed, check whether your grep patterns were broader -- and consider adding the pattern to the script for future use.

---

## Self-Check Script

Run this verification to confirm you completed each step:

```bash
#!/usr/bin/env bash
# lab1-selfcheck.sh

PASS=0
FAIL=0

echo ""
echo "=========================================="
echo "  LAB 1: RECON SELF-CHECK"
echo "=========================================="
echo ""

# Check decoded directory exists
if [ -d "recon-decoded" ] && [ -f "recon-decoded/AndroidManifest.xml" ]; then
    echo "  [PASS] APK decoded to recon-decoded/"
    ((PASS++))
else
    echo "  [FAIL] recon-decoded/ not found or incomplete"
    ((FAIL++))
fi

# Check Application class identification
APP_CLASS=$(grep '<application' recon-decoded/AndroidManifest.xml 2>/dev/null | grep -o 'android:name="[^"]*"')
if echo "$APP_CLASS" | grep -q "PocApplication"; then
    echo "  [PASS] Application class identified: $APP_CLASS"
    ((PASS++))
else
    echo "  [FAIL] Application class not correctly identified"
    ((FAIL++))
fi

# Check CameraX identification
CAMERAX=$(grep -rl 'ImageAnalysis\$Analyzer' recon-decoded/smali*/ 2>/dev/null | wc -l | tr -d ' ')
if [ "$CAMERAX" -gt 0 ]; then
    echo "  [PASS] CameraX (ImageAnalysis.Analyzer) found: $CAMERAX file(s)"
    ((PASS++))
else
    echo "  [FAIL] CameraX not found -- check your grep patterns"
    ((FAIL++))
fi

# Check Camera2 is NOT in app code
CAM2_APP=$(grep -rl 'OnImageAvailableListener' recon-decoded/smali*/ 2>/dev/null | grep -v 'androidx/camera' | wc -l | tr -d ' ')
if [ "$CAM2_APP" -eq 0 ]; then
    echo "  [PASS] No app-level Camera2 usage (CameraX confirmed)"
    ((PASS++))
else
    echo "  [INFO] Camera2 found in app code: $CAM2_APP file(s) -- investigate"
fi

# Check location surface
LOCATION=$(grep -rn 'onLocationResult' recon-decoded/smali*/ 2>/dev/null | wc -l | tr -d ' ')
if [ "$LOCATION" -gt 0 ]; then
    echo "  [PASS] Location surface (onLocationResult) found"
    ((PASS++))
else
    echo "  [FAIL] onLocationResult not found"
    ((FAIL++))
fi

# Check mock detection
MOCK=$(grep -rEn 'isFromMockProvider|isMock' recon-decoded/smali*/ 2>/dev/null | wc -l | tr -d ' ')
if [ "$MOCK" -gt 0 ]; then
    echo "  [PASS] Mock location detection found: $MOCK occurrence(s)"
    ((PASS++))
else
    echo "  [INFO] No mock detection found"
fi

# Check ML Kit
MLKIT=$(grep -rl 'com/google/mlkit' recon-decoded/smali*/ 2>/dev/null | wc -l | tr -d ' ')
if [ "$MLKIT" -gt 0 ]; then
    echo "  [PASS] Google ML Kit found: $MLKIT file(s)"
    ((PASS++))
else
    echo "  [FAIL] ML Kit not found -- check your grep patterns"
    ((FAIL++))
fi

echo ""
echo "=========================================="
echo "  Results: $PASS passed, $FAIL failed"
echo "=========================================="

if [ "$FAIL" -eq 0 ]; then
    echo ""
    echo "  RECON COMPLETE. You are ready for Lab 2."
    echo ""
else
    echo ""
    echo "  REVIEW YOUR FINDINGS. Fix failures before continuing."
    echo ""
fi
```

---

## Deliverables

1. **Decoded APK directory** (`recon-decoded/`) -- the full apktool output.
2. **Recon report** -- structured text covering all seven surfaces (Application class, permissions, camera API, location, sensors, SDKs, assessment).
3. **Self-check screenshot** -- output of the self-check script showing all checks passed.

---

## Success Criteria

- [ ] APK decoded successfully with apktool
- [ ] Application class identified as `com.poc.PocApplication`
- [ ] Camera API identified as CameraX (not Camera2)
- [ ] `ImageAnalysis.Analyzer`, `toBitmap`, and `OnImageCapturedCallback` all found
- [ ] Location surface mapped: `onLocationResult` present
- [ ] Mock detection identified
- [ ] Sensor surface mapped: `onSensorChanged` location noted
- [ ] Third-party SDK identified: Google ML Kit
- [ ] Recon report compiled with Assessment section
- [ ] Self-check script reports 0 failures

---

## What You Just Demonstrated

You pulled an APK apart without running it and built a complete intelligence picture of its attack surfaces. You know which camera API it uses, which hooks will fire, which will be skipped, and why. You identified the biometric SDK and know what quality of payloads it demands. You found the app's location defense (mock detection) and know the patch-tool will neutralize it. You predicted exactly what the patch-tool output will look like before you run it.

This is the recon discipline. Every engagement starts here. The recon report you just wrote is the operational plan for Lab 2 -- where you will run the patch-tool and verify that every prediction was correct.
