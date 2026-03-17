---
title: "Lab 13: Defend and Attack"
description: "Add defenses to your target app, then bypass them -- understanding both sides"
---

> **Prerequisites:** Lab 12 complete (you have a working target app), Chapters 15, 17, and 18 read.
>
> **Estimated time:** 90-120 minutes.
>
> **Chapter reference:** Chapters 15 (Defeating Anti-Tamper Protections), 17 (Blue Team Detection Guide), 18 (Defense-in-Depth Architecture).
>
> **Target:** The app you built in Lab 12 (`com.redteam.target`).

In Lab 12, you built a target app and attacked it. The attack succeeded trivially because the app had no defenses. Now you add three defense layers to your app, observe the patch-tool fail against them, and then systematically bypass each one using the techniques from Lab 10 and Chapter 15.

This is the full red-team/blue-team cycle in a single lab. You build the defense, you break the defense, and you write an assessment of what worked and what did not.

---

## The Three Defenses You Will Implement

| Defense | Purpose | Difficulty to Bypass |
|---------|---------|---------------------|
| APK signature verification | Detect re-signing after patching | Low (single method) |
| Mock location detection | Detect synthetic GPS data | Low (boolean flip) |
| Frame entropy check | Detect repeated/synthetic camera frames | Medium (analysis logic) |

---

## Phase 1: Add the Defenses

### Defense 1: APK Signature Verification

Add a signature check that runs at startup. The app computes the SHA-256 hash of its signing certificate and compares it against a hardcoded expected value.

Add this method to `MainActivity.kt`:

```kotlin
private fun checkSignature(): Boolean {
    try {
        val packageInfo = packageManager.getPackageInfo(
            packageName, PackageManager.GET_SIGNATURES)
        val signature = packageInfo.signatures[0]
        val md = java.security.MessageDigest.getInstance("SHA-256")
        val hash = md.digest(signature.toByteArray())
        val hexHash = hash.joinToString(":") { "%02X".format(it) }

        Log.d("SecurityCheck", "APK signature hash: $hexHash")

        // Replace this with YOUR actual debug keystore hash after first run
        val expectedHash = "YOUR_HASH_HERE"

        if (expectedHash == "YOUR_HASH_HERE") {
            // First run: log the hash so you can hardcode it
            Log.w("SecurityCheck", "FIRST RUN: Copy this hash into expectedHash")
            return true
        }

        return hexHash == expectedHash
    } catch (e: Exception) {
        Log.e("SecurityCheck", "Signature check failed", e)
        return false
    }
}
```

Call it in `onCreate()`:

```kotlin
override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)

    if (!checkSignature()) {
        Log.e("SecurityCheck", "SIGNATURE MISMATCH -- app has been tampered with")
        // In production: finish() or show error. For this lab, log and continue.
        statusText.text = "SECURITY: Signature verification FAILED"
    }

    // ... rest of onCreate
}
```

**Setup procedure:**
1. Build and run the app once
2. Read the hash from logcat: `adb logcat -s SecurityCheck`
3. Replace `"YOUR_HASH_HERE"` with the actual hash
4. Rebuild

### Defense 2: Mock Location Detection

Add a check to your location callback that detects mock providers:

```kotlin
override fun onLocationResult(result: LocationResult) {
    val location = result.lastLocation ?: return

    // Mock location detection
    if (location.isFromMockProvider) {
        Log.w("SecurityCheck", "MOCK LOCATION DETECTED")
        runOnUiThread {
            statusText.text = "SECURITY: Mock location detected"
        }
        return  // Reject the location
    }

    // ... rest of location processing
}
```

For API 31+, also add:

```kotlin
if (android.os.Build.VERSION.SDK_INT >= 31 && location.isMock) {
    Log.w("SecurityCheck", "MOCK LOCATION DETECTED (API 31+)")
    runOnUiThread {
        statusText.text = "SECURITY: Mock location detected"
    }
    return
}
```

### Defense 3: Frame Entropy Check

Add a check that compares consecutive camera frames. If the frames are identical (same hash), they are likely synthetic:

```kotlin
private var lastFrameHash: Int = 0
private var duplicateFrameCount: Int = 0
private val MAX_DUPLICATE_FRAMES = 5

@androidx.camera.core.ExperimentalGetImage
private fun processFrame(imageProxy: ImageProxy) {
    val mediaImage = imageProxy.image
    if (mediaImage == null) {
        imageProxy.close()
        return
    }

    // Frame entropy check: compute a simple hash of the frame data
    val buffer = mediaImage.planes[0].buffer
    val bytes = ByteArray(minOf(buffer.remaining(), 1024))  // Sample first 1KB
    buffer.get(bytes)
    buffer.rewind()

    val frameHash = bytes.contentHashCode()

    if (frameHash == lastFrameHash) {
        duplicateFrameCount++
        if (duplicateFrameCount > MAX_DUPLICATE_FRAMES) {
            Log.w("SecurityCheck",
                "REPEATED FRAMES DETECTED ($duplicateFrameCount consecutive duplicates)")
            runOnUiThread {
                statusText.text = "SECURITY: Synthetic frames detected"
            }
            imageProxy.close()
            return  // Reject the frame
        }
    } else {
        duplicateFrameCount = 0
    }
    lastFrameHash = frameHash

    // ... continue with face detection
    val inputImage = InputImage.fromMediaImage(
        mediaImage, imageProxy.imageInfo.rotationDegrees)
    // ... rest of ML Kit processing
}
```

---

## Phase 2: Rebuild and Verify Defenses Work

Build the defended app:

```bash
cd ~/target-app
./gradlew assembleDebug
cp app/build/outputs/apk/debug/app-debug.apk \
   /Users/josejames/Documents/android-red-team/my-target-defended.apk
```

Install and run the clean (unpatched) version to confirm the defenses pass:

```bash
cd /Users/josejames/Documents/android-red-team
adb install -r my-target-defended.apk
adb shell am start -n com.redteam.target/.MainActivity
adb logcat -s SecurityCheck,FaceCheck,LocationCheck
```

With the clean app, all three checks should pass: signature matches, location is real (or emulator location), and frames come from a real camera (or emulator camera).

---

## Phase 3: Patch and Watch Defenses Trigger

Now patch the defended app with the patch-tool:

```bash
java -jar patch-tool.jar my-target-defended.apk \
  --out my-target-defended-patched.apk --work-dir ./work-defended
```

Deploy with payloads:

```bash
adb uninstall com.redteam.target 2>/dev/null
adb install -r my-target-defended-patched.apk

adb shell pm grant com.redteam.target android.permission.CAMERA
adb shell pm grant com.redteam.target android.permission.ACCESS_FINE_LOCATION
adb shell pm grant com.redteam.target android.permission.READ_EXTERNAL_STORAGE
adb shell pm grant com.redteam.target android.permission.WRITE_EXTERNAL_STORAGE
adb shell appops set com.redteam.target MANAGE_EXTERNAL_STORAGE allow

# Push payloads
adb push /tmp/my_target_location.json /sdcard/poc_location/config.json

# Launch
adb shell am start -n com.redteam.target/.MainActivity

# Watch the defenses trigger
adb logcat -s SecurityCheck
```

You should see:

- **Signature check:** `SIGNATURE MISMATCH` -- the APK was re-signed with a different key after patching
- **Mock location:** `MOCK LOCATION DETECTED` -- the injected coordinates may trigger mock detection (depends on how the patch-tool delivers them)
- **Frame entropy:** `REPEATED FRAMES DETECTED` -- if your injected frames loop, consecutive frames may have the same hash

Record which defenses triggered and which did not. This is your baseline for the evasion phase.

---

## Phase 4: Bypass Each Defense

Decode the patched APK and neutralize each defense:

```bash
apktool d my-target-defended-patched.apk -o decoded-defended/ -f
```

### Bypass 1: Signature Verification

Find the `checkSignature` method:

```bash
grep -rn "checkSignature\|SIGNATURE\|getPackageInfo" decoded-defended/smali*/com/redteam/
```

Open the method in the smali file. Force it to return `true`:

```smali
.method private checkSignature()Z
    .locals 1
    const/4 v0, 0x1
    return v0
.end method
```

### Bypass 2: Mock Location Detection

Find the `isFromMockProvider` call:

```bash
grep -rn "isFromMockProvider\|isMock" decoded-defended/smali*/
```

The patch-tool may have already neutralized `isFromMockProvider` calls during its standard patching. Check whether the call still exists in the smali. If it does, find the `move-result` after the call and force it to `false`:

```smali
# After: invoke-virtual {vN}, Landroid/location/Location;->isFromMockProvider()Z
# After: move-result vX
# Insert:
const/4 vX, 0x0
```

This overwrites the boolean result with `false` (not from mock provider) regardless of the actual value.

### Bypass 3: Frame Entropy Check

Find the duplicate frame detection logic:

```bash
grep -rn "duplicateFrameCount\|contentHashCode\|REPEATED FRAMES" decoded-defended/smali*/
```

You have several options:

**Option A: Force the comparison to never match.** Find the `if-eq` or `if-ne` that compares `frameHash` with `lastFrameHash` and invert it or nop it.

**Option B: Remove the early return.** Find the `return-void` inside the duplicate detection block and remove the entire block, letting all frames through to face detection.

**Option C: Set the threshold impossibly high.** Find the `const/4` or `const/16` that sets `MAX_DUPLICATE_FRAMES` (5) and change it to `0x7FFF` (32767).

---

## Phase 5: Rebuild and Verify Bypass

```bash
apktool b decoded-defended/ -o defended-bypassed.apk
zipalign -v 4 defended-bypassed.apk aligned-defended.apk
apksigner sign --ks ~/.android/debug.keystore --ks-pass pass:android aligned-defended.apk

adb uninstall com.redteam.target 2>/dev/null
adb install -r aligned-defended.apk

adb shell pm grant com.redteam.target android.permission.CAMERA
adb shell pm grant com.redteam.target android.permission.ACCESS_FINE_LOCATION
adb shell pm grant com.redteam.target android.permission.READ_EXTERNAL_STORAGE
adb shell pm grant com.redteam.target android.permission.WRITE_EXTERNAL_STORAGE
adb shell appops set com.redteam.target MANAGE_EXTERNAL_STORAGE allow

adb push /tmp/my_target_location.json /sdcard/poc_location/config.json

adb shell am start -n com.redteam.target/.MainActivity
```

Check that all defenses are neutralized:

```bash
adb logcat -s SecurityCheck,FrameInterceptor,LocationInterceptor
```

Expected: No security warnings. Frame and location injection active. The app behaves as if no defenses were ever added.

---

## Phase 6: Write the Defense Assessment

Create a structured assessment documenting each defense:

```text
DEFENSE ASSESSMENT
==================
Target: com.redteam.target (defended build)
Date:   YYYY-MM-DD

DEFENSE 1: APK Signature Verification
  Implementation: SHA-256 hash of signing certificate checked in onCreate()
  Detection:      Found via grep for getPackageInfo/GET_SIGNATURES
  Bypass:         Force checkSignature() to return true (2 smali lines)
  Effort:         < 5 minutes
  Effectiveness:  LOW -- trivially bypassed by replacing method body
  Recommendation: Move signature check to native code (JNI) and obfuscate.
                  Still bypassable but raises the effort significantly.

DEFENSE 2: Mock Location Detection
  Implementation: isFromMockProvider() check in onLocationResult callback
  Detection:      Found via grep for isFromMockProvider
  Bypass:         Overwrite move-result with const/4 v0, 0x0 (1 smali line)
  Effort:         < 5 minutes
  Effectiveness:  LOW -- single boolean check, trivially flipped
  Recommendation: Implement server-side location plausibility checks
                  (velocity analysis, cell tower correlation, IP geolocation).

DEFENSE 3: Frame Entropy Check
  Implementation: contentHashCode() on first 1KB of frame data, consecutive
                  duplicate counter with threshold of 5
  Detection:      Found via grep for contentHashCode/duplicateFrameCount
  Bypass:         [Which option you chose and why]
  Effort:         10-15 minutes (requires understanding the frame processing flow)
  Effectiveness:  MEDIUM -- detects naive frame loops but bypassable.
                  Would not detect frames with artificial noise added.
  Recommendation: Move frame analysis server-side. Check for statistical
                  anomalies across the full frame sequence, not just
                  consecutive duplicates. Use perceptual hashing (pHash)
                  rather than raw byte comparison.

OVERALL ASSESSMENT
  All three client-side defenses were bypassed within 30 minutes.
  Client-side integrity checks provide defense-in-depth but cannot
  be relied upon as a primary security control. Any defense that
  executes on an attacker-controlled device can be neutralized.

  Effective defenses require server-side verification:
  - Server-side liveness analysis of raw frames
  - Server-side location plausibility (not just coordinate values)
  - APK integrity attestation via Play Integrity API (harder to fake)
```

---

## Deliverables

| Artifact | Description |
|----------|-------------|
| Defended app source | `MainActivity.kt` with all three defenses implemented |
| `my-target-defended.apk` | The clean defended APK |
| `aligned-defended.apk` | The bypassed APK with all defenses neutralized |
| Defense trigger log | Logcat showing each defense firing against the patched app |
| Bypass log | Specific smali changes made for each defense |
| Defense assessment | Structured document rating each defense's effectiveness |

---

## Success Criteria

- [ ] All three defenses implemented and working in the clean app
- [ ] Signature check fires when the patched app is installed
- [ ] Mock location check fires when injected coordinates are delivered
- [ ] Frame entropy check fires when repeated frames are injected
- [ ] All three defenses bypassed without breaking app functionality
- [ ] Injection works after all bypasses are applied (frames + location)
- [ ] Defense assessment written with effectiveness ratings and recommendations

---

## Self-Check Script

```bash
#!/usr/bin/env bash
echo "=========================================="
echo "  LAB 13: DEFEND AND ATTACK SELF-CHECK"
echo "=========================================="
PASS=0; FAIL=0

# Check defended APK exists
if [ -f my-target-defended.apk ]; then
  echo "  [PASS] Defended APK exists"
  ((PASS++))
else
  echo "  [FAIL] my-target-defended.apk not found"
  ((FAIL++))
fi

# Check bypassed APK exists
if [ -f aligned-defended.apk ]; then
  echo "  [PASS] Bypassed APK exists"
  ((PASS++))
else
  echo "  [FAIL] aligned-defended.apk not found"
  ((FAIL++))
fi

# Check decoded directory has defenses
if [ -d decoded-defended/ ]; then
  SIG=$(grep -rl "checkSignature\|getPackageInfo" decoded-defended/smali*/com/redteam/ 2>/dev/null | wc -l | tr -d ' ')
  MOCK=$(grep -rn "isFromMockProvider\|isMock" decoded-defended/smali*/ 2>/dev/null | wc -l | tr -d ' ')
  ENTROPY=$(grep -rn "duplicateFrameCount\|contentHashCode" decoded-defended/smali*/ 2>/dev/null | wc -l | tr -d ' ')

  echo "  Signature check references: $SIG"
  echo "  Mock detection references: $MOCK"
  echo "  Frame entropy references: $ENTROPY"

  [ "$SIG" -gt 0 ] && echo "  [PASS] Signature defense found" && ((PASS++)) || { echo "  [FAIL] No signature defense"; ((FAIL++)); }
  [ "$MOCK" -gt 0 ] && echo "  [PASS] Mock detection found" && ((PASS++)) || { echo "  [FAIL] No mock detection"; ((FAIL++)); }
  [ "$ENTROPY" -gt 0 ] && echo "  [PASS] Frame entropy check found" && ((PASS++)) || { echo "  [FAIL] No frame entropy check"; ((FAIL++)); }
else
  echo "  [FAIL] decoded-defended/ not found"
  ((FAIL++))
fi

# Check injection after bypass
FRAMES=$(adb logcat -d -s FrameInterceptor 2>/dev/null | grep -c "FRAME_DELIVERED")
LOCS=$(adb logcat -d -s LocationInterceptor 2>/dev/null | grep -c "LOCATION_DELIVERED")
echo "  Post-bypass frames delivered: $FRAMES"
echo "  Post-bypass locations delivered: $LOCS"
[ "$FRAMES" -gt 0 ] && echo "  [PASS] Frame injection active after bypass" && ((PASS++)) || { echo "  [FAIL] No frames after bypass"; ((FAIL++)); }
[ "$LOCS" -gt 0 ] && echo "  [PASS] Location injection active after bypass" && ((PASS++)) || { echo "  [FAIL] No locations after bypass"; ((FAIL++)); }

# Check no security warnings
WARNINGS=$(adb logcat -d -s SecurityCheck 2>/dev/null | grep -ci "MISMATCH\|MOCK.*DETECTED\|REPEATED.*FRAMES")
echo "  Security warnings in log: $WARNINGS"
[ "$WARNINGS" -eq 0 ] && echo "  [PASS] No security warnings after bypass" && ((PASS++)) || { echo "  [WARN] Security warnings still present -- review bypass"; }

echo ""
echo "  Results: $PASS passed, $FAIL failed"
echo ""
echo "  Manual checks:"
echo "    1. Defense assessment document exists with ratings for all 3 defenses"
echo "    2. Each defense was observed triggering before bypass"
echo "    3. Each defense was neutralized with documented smali changes"
echo "    4. Recommendations include server-side alternatives"
echo "=========================================="
[ "$FAIL" -eq 0 ] && echo "  Lab 13 COMPLETE." || echo "  Lab 13 INCOMPLETE -- review failed checks."
```

---

## What You Just Demonstrated

You completed the full red-team/blue-team cycle against code you wrote yourself. You implemented three defenses that are commonly found in production KYC apps. You observed them detect tampering. Then you bypassed all three in under 30 minutes.

The critical finding is not that the defenses failed -- it is *why* they failed. Every defense executed on the same device the attacker controls. The attacker can read the defense code, understand its logic, and modify it at the bytecode level. This is the fundamental limitation of client-side security: the client is not trusted.

The defense assessment you wrote captures this insight in a form that is actionable for a development team. "Your signature check is bypassable in 5 minutes" is a finding. "Move verification server-side using attestation APIs" is a recommendation. The combination is what makes a red team report valuable -- not just proving the break, but explaining the fix.

This dual perspective -- understanding defense well enough to implement it, and understanding attack well enough to break it -- is the core competency this course has been building toward. You now have both.
