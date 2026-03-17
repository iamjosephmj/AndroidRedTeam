---
title: "Lab 12: Build Your Own Target"
description: "Create a vulnerable KYC app and then attack it with the toolkit"
---

> **Prerequisites:** Labs 0-6 complete, Android Studio installed (or command-line Gradle with Android SDK), Chapters 3, 7, and 8 read.
>
> **Estimated time:** 90-120 minutes.
>
> **Chapter reference:** Chapters 3 (Android Internals), 7 (Camera Injection), 8 (Location Spoofing).
>
> **Target:** You will build the target yourself in this lab.

Every lab so far has given you a pre-built target. You patched it, injected data, and observed the results. But understanding the attack without understanding the target is incomplete. In this lab, you switch sides: you build a minimal KYC-style app, then attack it with the toolkit.

By the end, you will have a working Android app that uses CameraX for face detection, checks GPS coordinates against a geofence, and stores an auth token in SharedPreferences. Then you will patch it with the patch-tool and verify that every injection subsystem works against code you wrote yourself.

---

## What You Will Build

| Feature | Implementation | Attack Surface |
|---------|---------------|----------------|
| Face detection | CameraX + ML Kit `FaceDetector` | Frame injection |
| Location verification | `FusedLocationProviderClient` | GPS spoofing |
| Auth token storage | `SharedPreferences` | Token interception (Lab 7 technique) |

The app is deliberately simple -- one Activity, three checks. Production apps are more complex, but the APIs are identical.

---

## Step 1: Create the Android Project

### Option A: Android Studio

1. Create a new project: **Empty Compose Activity** (or Empty Views Activity)
2. Package name: `com.redteam.target`
3. Minimum SDK: API 24 (Android 7.0)
4. Language: Kotlin

### Option B: Command-Line Gradle

```bash
mkdir -p ~/target-app && cd ~/target-app
```

Create the project structure manually or use the Android Gradle template. The key files you need:

```text
app/
  src/main/
    java/com/redteam/target/
      MainActivity.kt
    AndroidManifest.xml
  build.gradle.kts
build.gradle.kts
settings.gradle.kts
```

---

## Step 2: Add Dependencies

In `app/build.gradle.kts`, add CameraX and ML Kit:

```kotlin
dependencies {
    // CameraX
    val cameraxVersion = "1.3.1"
    implementation("androidx.camera:camera-core:$cameraxVersion")
    implementation("androidx.camera:camera-camera2:$cameraxVersion")
    implementation("androidx.camera:camera-lifecycle:$cameraxVersion")
    implementation("androidx.camera:camera-view:$cameraxVersion")

    // ML Kit Face Detection
    implementation("com.google.mlkit:face-detection:16.1.6")

    // Location
    implementation("com.google.android.gms:play-services-location:21.1.0")

    // Standard Android
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("androidx.core:core-ktx:1.12.0")
}
```

---

## Step 3: Configure the Manifest

In `AndroidManifest.xml`, declare the permissions and features:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.redteam.target">

    <uses-permission android:name="android.permission.CAMERA" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />
    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" />

    <uses-feature android:name="android.hardware.camera" />

    <application
        android:name=".TargetApplication"
        android:allowBackup="true"
        android:label="Red Team Target"
        android:theme="@style/Theme.AppCompat.Light.DarkActionBar">

        <activity
            android:name=".MainActivity"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
```

The custom `TargetApplication` class is important -- the patch-tool hooks into `Application.onCreate()`.

---

## Step 4: Write the Application Class

Create `TargetApplication.kt`:

```kotlin
package com.redteam.target

import android.app.Application
import android.util.Log

class TargetApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        Log.d("TargetApp", "Application.onCreate() called")
    }
}
```

This is the bootstrap point. After patching, the patch-tool's initialization code runs inside this `onCreate()`.

---

## Step 5: Write the Main Activity

Create `MainActivity.kt` with three verification features:

```kotlin
package com.redteam.target

import android.Manifest
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.Bundle
import android.util.Log
import android.widget.TextView
import android.widget.LinearLayout
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.android.gms.location.*
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : AppCompatActivity() {

    private lateinit var cameraExecutor: ExecutorService
    private lateinit var previewView: PreviewView
    private lateinit var statusText: TextView
    private lateinit var locationClient: FusedLocationProviderClient

    // Hardcoded geofence: Times Square
    private val TARGET_LAT = 40.7580
    private val TARGET_LNG = -73.9855
    private val GEOFENCE_RADIUS_M = 500.0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Build UI programmatically
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        previewView = PreviewView(this)
        statusText = TextView(this).apply {
            text = "Initializing..."
            textSize = 18f
            setPadding(16, 16, 16, 16)
        }
        layout.addView(statusText)
        layout.addView(previewView, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        setContentView(layout)

        cameraExecutor = Executors.newSingleThreadExecutor()
        locationClient = LocationServices.getFusedLocationProviderClient(this)

        // Store auth token
        storeAuthToken()

        // Request permissions then start
        if (hasPermissions()) {
            startCamera()
            startLocationCheck()
        } else {
            ActivityCompat.requestPermissions(this,
                arrayOf(Manifest.permission.CAMERA,
                        Manifest.permission.ACCESS_FINE_LOCATION), 100)
        }
    }

    // --- CAMERA: CameraX + ML Kit Face Detection ---

    private fun startCamera() {
        val cameraProviderFuture = ProcessCameraProvider.getInstance(this)
        cameraProviderFuture.addListener({
            val cameraProvider = cameraProviderFuture.get()

            val preview = Preview.Builder().build().also {
                it.setSurfaceProvider(previewView.surfaceProvider)
            }

            val imageAnalysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()

            imageAnalysis.setAnalyzer(cameraExecutor) { imageProxy ->
                processFrame(imageProxy)
            }

            cameraProvider.unbindAll()
            cameraProvider.bindToLifecycle(this, CameraSelector.DEFAULT_FRONT_CAMERA,
                preview, imageAnalysis)

        }, ContextCompat.getMainExecutor(this))
    }

    @androidx.camera.core.ExperimentalGetImage
    private fun processFrame(imageProxy: ImageProxy) {
        val mediaImage = imageProxy.image
        if (mediaImage != null) {
            val inputImage = InputImage.fromMediaImage(
                mediaImage, imageProxy.imageInfo.rotationDegrees)

            val options = FaceDetectorOptions.Builder()
                .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_FAST)
                .build()

            FaceDetection.getClient(options).process(inputImage)
                .addOnSuccessListener { faces ->
                    if (faces.isNotEmpty()) {
                        Log.d("FaceCheck", "Face detected: ${faces.size} face(s)")
                        runOnUiThread {
                            statusText.text = "Face detected: ${faces.size}"
                        }
                    }
                }
                .addOnCompleteListener {
                    imageProxy.close()
                }
        } else {
            imageProxy.close()
        }
    }

    // --- LOCATION: Geofence Check ---

    private fun startLocationCheck() {
        if (ActivityCompat.checkSelfPermission(this,
                Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            return
        }

        val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 3000).build()

        locationClient.requestLocationUpdates(request,
            object : LocationCallback() {
                override fun onLocationResult(result: LocationResult) {
                    val location = result.lastLocation ?: return
                    val distance = calculateDistance(
                        location.latitude, location.longitude,
                        TARGET_LAT, TARGET_LNG)

                    Log.d("LocationCheck",
                        "Lat=${location.latitude}, Lng=${location.longitude}, " +
                        "Distance=${distance}m, InGeofence=${distance < GEOFENCE_RADIUS_M}")

                    runOnUiThread {
                        if (distance < GEOFENCE_RADIUS_M) {
                            statusText.text = "Location: VERIFIED (${distance.toInt()}m)"
                        } else {
                            statusText.text = "Location: OUTSIDE GEOFENCE (${distance.toInt()}m)"
                        }
                    }
                }
            },
            mainLooper)
    }

    private fun calculateDistance(lat1: Double, lng1: Double,
                                  lat2: Double, lng2: Double): Double {
        val results = FloatArray(1)
        android.location.Location.distanceBetween(lat1, lng1, lat2, lng2, results)
        return results[0].toDouble()
    }

    // --- AUTH TOKEN: SharedPreferences ---

    private fun storeAuthToken() {
        val prefs: SharedPreferences = getSharedPreferences("auth", MODE_PRIVATE)
        val token = "rt-" + System.currentTimeMillis().toString(36) + "-secret"
        prefs.edit().putString("auth_token", token).apply()
        Log.d("AuthToken", "Token stored (not shown in UI)")
    }

    // --- PERMISSIONS ---

    private fun hasPermissions(): Boolean {
        return ContextCompat.checkSelfPermission(this,
            Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED &&
               ContextCompat.checkSelfPermission(this,
            Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
    }

    override fun onRequestPermissionsResult(requestCode: Int,
        permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 100 && grantResults.all {
                it == PackageManager.PERMISSION_GRANTED }) {
            startCamera()
            startLocationCheck()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        cameraExecutor.shutdown()
    }
}
```

---

## Step 6: Build the APK

### Android Studio

Click **Build > Build Bundle(s) / APK(s) > Build APK(s)**. The debug APK lands in `app/build/outputs/apk/debug/app-debug.apk`.

### Command Line

```bash
cd ~/target-app
./gradlew assembleDebug
```

Copy the APK to your working directory:

```bash
cp app/build/outputs/apk/debug/app-debug.apk \
   /Users/josejames/Documents/android-red-team/my-target.apk
```

### Verify the APK Runs

```bash
adb install -r my-target.apk
adb shell am start -n com.redteam.target/.MainActivity
```

The app should show a camera preview and start logging face detection results and location data to logcat:

```bash
adb logcat -s FaceCheck,LocationCheck,AuthToken
```

Confirm you see face detection events and location results before proceeding.

---

## Step 7: Decode and Inspect Your Own Smali

Before patching, decode the app and examine what your code looks like in smali. This builds the mapping between source code and bytecode:

```bash
cd /Users/josejames/Documents/android-red-team
apktool d my-target.apk -o decoded-my-target/

# Find your camera analyzer
grep -rn "ImageAnalysis\$Analyzer\|processFrame" decoded-my-target/smali*/

# Find your location callback
grep -rn "onLocationResult" decoded-my-target/smali*/

# Find your SharedPreferences usage
grep -rn "getString\|putString" decoded-my-target/smali*/ | grep -i "SharedPreferences"

# Find your Application class
grep -rn "TargetApplication" decoded-my-target/smali*/
```

Spend a few minutes reading the smali for your `processFrame` method. You wrote the Kotlin -- now see what the compiler produced. This is the code the patch-tool will modify.

---

## Step 8: Patch Your App with the Toolkit

Run the patch-tool against your own APK:

```bash
java -jar patch-tool.jar my-target.apk \
  --out my-target-patched.apk --work-dir ./work-my-target
```

Review the output. You should see:

- Your `TargetApplication.onCreate()` hooked for bootstrap
- CameraX hooks applied (`analyze`, `toBitmap`, `onCaptureSuccess`)
- Location hooks applied (`onLocationResult`)
- Mock detection patched (if applicable)

---

## Step 9: Deploy, Inject, and Verify

```bash
adb uninstall com.redteam.target 2>/dev/null
adb install -r my-target-patched.apk

adb shell pm grant com.redteam.target android.permission.CAMERA
adb shell pm grant com.redteam.target android.permission.ACCESS_FINE_LOCATION
adb shell pm grant com.redteam.target android.permission.READ_EXTERNAL_STORAGE
adb shell pm grant com.redteam.target android.permission.WRITE_EXTERNAL_STORAGE
adb shell appops set com.redteam.target MANAGE_EXTERNAL_STORAGE allow

# Push payloads
adb shell mkdir -p /sdcard/poc_frames/ /sdcard/poc_location/ /sdcard/poc_sensor/

# Push face frames (use your frames from Lab 3, or generate test frames)
# For quick testing, create a solid-color frame:
# convert -size 640x480 xc:blue /tmp/test_frame.png && adb push /tmp/test_frame.png /sdcard/poc_frames/001.png

# Push location config (Times Square -- matches the hardcoded geofence)
cat > /tmp/my_target_location.json << 'EOF'
{"latitude":40.7580,"longitude":-73.9855,"altitude":5.0,"accuracy":8.0,"speed":0.0,"bearing":0.0}
EOF
adb push /tmp/my_target_location.json /sdcard/poc_location/config.json

# Launch
adb shell am start -n com.redteam.target/.MainActivity

# Verify injection
adb logcat -s FrameInterceptor,LocationInterceptor,HookEngine
```

You should see:

- `FrameInterceptor`: delivering injected frames to your `processFrame` method
- `LocationInterceptor`: delivering Times Square coordinates to your `onLocationResult` callback
- Your app's UI showing "Face detected" (from injected frames) and "Location: VERIFIED" (from injected coordinates)

---

## Deliverables

| Artifact | Description |
|----------|-------------|
| App source code | Complete `MainActivity.kt`, `TargetApplication.kt`, manifest, and `build.gradle.kts` |
| `my-target.apk` | The built, unpatched APK |
| `my-target-patched.apk` | The patched APK with injection hooks |
| Decoded smali samples | Key smali snippets showing your code in bytecode form |
| Logcat output | `FrameInterceptor` and `LocationInterceptor` showing injection on your app |

---

## Success Criteria

- [ ] App builds and runs on the emulator without patching
- [ ] Camera preview shows and ML Kit detects faces
- [ ] Location check runs and logs coordinates
- [ ] Auth token stored in SharedPreferences
- [ ] App decodes cleanly with apktool
- [ ] Patch-tool applies hooks to your app without errors
- [ ] Frame injection active (logcat shows `FRAME_DELIVERED`)
- [ ] Location injection active (logcat shows `LOCATION_DELIVERED`)
- [ ] App UI shows "Face detected" from injected frames
- [ ] App UI shows "Location: VERIFIED" from injected coordinates

---

## Self-Check Script

```bash
#!/usr/bin/env bash
echo "=========================================="
echo "  LAB 12: BUILD YOUR OWN TARGET SELF-CHECK"
echo "=========================================="
PASS=0; FAIL=0

# Check source exists
if [ -f ~/target-app/app/src/main/java/com/redteam/target/MainActivity.kt ]; then
  echo "  [PASS] MainActivity.kt exists"
  ((PASS++))
else
  echo "  [FAIL] MainActivity.kt not found"
  ((FAIL++))
fi

# Check APKs
for apk in my-target.apk my-target-patched.apk; do
  if [ -f "$apk" ]; then
    echo "  [PASS] $apk exists"
    ((PASS++))
  else
    echo "  [FAIL] $apk not found"
    ((FAIL++))
  fi
done

# Check decoded directory
if [ -d decoded-my-target/ ]; then
  echo "  [PASS] Decoded directory exists"
  ((PASS++))

  CAMERAX=$(grep -rl "ImageAnalysis\$Analyzer" decoded-my-target/smali*/ 2>/dev/null | wc -l | tr -d ' ')
  LOCATION=$(grep -rn "onLocationResult" decoded-my-target/smali*/ 2>/dev/null | wc -l | tr -d ' ')
  echo "  CameraX files: $CAMERAX"
  echo "  Location references: $LOCATION"
  [ "$CAMERAX" -gt 0 ] && echo "  [PASS] CameraX surface found" && ((PASS++)) || { echo "  [FAIL] No CameraX surface"; ((FAIL++)); }
  [ "$LOCATION" -gt 0 ] && echo "  [PASS] Location surface found" && ((PASS++)) || { echo "  [FAIL] No location surface"; ((FAIL++)); }
else
  echo "  [FAIL] decoded-my-target/ not found"
  ((FAIL++))
fi

# Check injection
FRAMES=$(adb logcat -d -s FrameInterceptor 2>/dev/null | grep -c "FRAME_DELIVERED")
LOCS=$(adb logcat -d -s LocationInterceptor 2>/dev/null | grep -c "LOCATION_DELIVERED")
echo "  Frames delivered: $FRAMES"
echo "  Locations delivered: $LOCS"
[ "$FRAMES" -gt 0 ] && echo "  [PASS] Frame injection active" && ((PASS++)) || { echo "  [FAIL] No frame delivery"; ((FAIL++)); }
[ "$LOCS" -gt 0 ] && echo "  [PASS] Location injection active" && ((PASS++)) || { echo "  [FAIL] No location delivery"; ((FAIL++)); }

echo ""
echo "  Results: $PASS passed, $FAIL failed"
echo "=========================================="
[ "$FAIL" -eq 0 ] && echo "  Lab 12 COMPLETE." || echo "  Lab 12 INCOMPLETE -- review failed checks."
```

---

## What You Just Demonstrated

You built both sides of the equation. You wrote a KYC app with real camera, location, and authentication features -- the same APIs that production apps use. Then you attacked it with the same toolkit you have been using all course.

The experience of writing the target code and then seeing your own `processFrame` method hooked, your own `onLocationResult` callback hijacked, and your own SharedPreferences token exposed makes the vulnerability concrete in a way that attacking a stranger's app does not. You know exactly what the code does. You see exactly where the injection happens. The gap between "the app receives data from the camera" and "the app receives data from the attacker" is one `invoke-static` in the smali.

This dual perspective -- builder and breaker -- is what separates a competent red teamer from someone who runs tools. You understand why the attack works, which means you can also understand how to defend against it. Lab 13 builds directly on this foundation.
