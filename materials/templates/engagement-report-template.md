# Engagement Report

**Target:** [APK filename]
**Package:** [com.example.app]
**Date:** [YYYY-MM-DD]
**Operator:** [Your name]
**Engagement type:** [Full bypass / Camera only / Location only / etc.]

---

## 1. Target Identification

- **Application:** [name and version]
- **Package:** [com.example.app]
- **Application class:** [fully qualified]
- **Verification steps:** [list the steps in the target flow]

## 2. Recon Summary

[Summarize recon findings: which APIs, which SDKs, which defenses]

### Hook Surfaces Identified

| Surface | API | Hook Target | Status |
|---------|-----|------------|--------|
| Camera | CameraX/Camera2 | [method] | Expected |
| Location | Fused/Manager | [method] | Expected |
| Sensor | [types] | onSensorChanged | Expected |
| Mock detection | [method] | [method] | Expected |

## 3. Patch Application

**Command:**
```
java -jar patch-tool.jar [target.apk] --out [patched.apk] --work-dir ./work
```

**Output:**
```
[paste full patch-tool output here]
```

### Cross-reference

| Expected Hook | Patched? | Notes |
|--------------|----------|-------|
| [hook 1] | Yes/No | |
| [hook 2] | Yes/No | |

## 4. Payload Configuration

### Camera
- **Frame set:** [directory name]
- **Frame count:** [n]
- **Resolution:** [WxH]
- **Push command:** `adb push [source] /sdcard/poc_frames/[dir]/`

### Location
- **Config:** [filename]
- **Coordinates:** [lat, lng]
- **Push command:** `adb push [config] /sdcard/poc_location/config.json`

### Sensor
- **Config:** [filename]
- **Profile:** [HOLDING/STILL/etc.]
- **Push command:** `adb push [config] /sdcard/poc_sensor/config.json`

## 5. Execution

### Step 1: [Step name]
- **What happened:** [description]
- **Injection active:** Camera [Y/N], Location [Y/N], Sensor [Y/N]
- **Result:** PASS / FAIL
- **Screenshot:** [filename]

### Step 2: [Step name]
[repeat for each step]

### Step 3: [Step name]
[repeat for each step]

## 6. Delivery Statistics

| Metric | Count |
|--------|-------|
| Frames delivered | [n] |
| Frames consumed | [n] |
| Frame accept rate | [n]% |
| Locations delivered | [n] |
| Sensor events | [n] |

**Timeline:**
- First injection event: [timestamp]
- Last injection event: [timestamp]
- Total engagement duration: [duration]

## 7. Recommendations

### For the target application's developers:

1. **[Category]:** [specific recommendation]
2. **[Category]:** [specific recommendation]
3. **[Category]:** [specific recommendation]

Consider:
- Server-side liveness verification
- APK integrity checks (signature verification at runtime)
- Certificate pinning on SDK API calls
- Frame sequence entropy analysis
- Sensor data plausibility validation
- Device attestation (SafetyNet / Play Integrity API)

## 8. Summary

[1 paragraph: what worked cleanly, what required iteration, what you'd do differently on a second engagement]
