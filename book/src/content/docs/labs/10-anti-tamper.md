---
title: "Lab 10: Anti-Tamper Evasion"
description: "Find and neutralize four layers of defense in a hardened target"
---

> **Prerequisites:** Labs 7-8 complete, Chapter 15 (Anti-Tamper Evasion) read.
>
> **Estimated time:** 90 minutes.
>
> **Chapter reference:** Chapter 15 -- Anti-Tamper Evasion.
>
> **Target:** `materials/targets/target-hardened-kyc.apk` if available. This lab requires a target with anti-tamper defenses -- [`materials/targets/target-kyc-basic.apk`](https://github.com/iamjosephmj/AndroidRedTeam/blob/main/materials/targets/target-kyc-basic.apk) does **not** have these defenses and cannot substitute here.

Every target in the previous labs was defenseless. No integrity checks, no signature verification, no awareness of tampering. You patched them, installed them, and injection worked immediately. That was training. This is the real thing.

The target is a face verification app with four layers of protection. Each defense independently kills the app or blocks functionality. You need to neutralize all four before the injection hooks can operate.

---

## The Four Defense Layers

| Layer | Defense | What It Checks | Failure Behavior |
|-------|---------|---------------|-----------------|
| 1 | APK signature verification | SHA-256 hash of signing certificate | App crashes on launch |
| 2 | DEX integrity check | CRC of `classes.dex` | Silent feature block |
| 3 | Installer verification | Was it installed from Google Play? | Warning dialog, then exit |
| 4 | Certificate pinning | OkHttp `CertificatePinner` on API calls | Network requests fail |

Your patched APK triggers all four: it has a different signature (you re-signed it), different DEX content (1,134 injected classes), a sideload install source (`adb install`), and no valid pins for the modified certificate chain.

> **Before you start:** This lab requires comfort with smali control flow -- `if-eqz`, `if-nez`, `goto`, `return-void`, and `const/4`. Review the "Defense Neutralization Patterns" section in Chapter 15 before starting.

---

## Phase 1: Decode and Recon

### Decode the APK

```bash
cd /Users/josejames/Documents/android-red-team
apktool d materials/targets/target-hardened-kyc.apk -o decoded-hardened/
```

### Systematic Defense Scan

Run each grep pattern and record what you find. Do not skip any -- a missed defense will crash the app later and you will waste time debugging.

**Signature verification:**

```bash
grep -rn "getPackageInfo\|GET_SIGNATURES\|Signature;->toByteArray\|MessageDigest" \
  decoded-hardened/smali*/
```

Look for a method that:
1. Calls `getPackageInfo()` with `GET_SIGNATURES` flag
2. Extracts the signature bytes with `toByteArray()`
3. Computes a hash with `MessageDigest.getInstance("SHA-256")`
4. Compares the hash against a hardcoded string
5. Branches to a crash or exit if they do not match

**DEX integrity:**

```bash
grep -rn "classes\.dex\|getCrc\|ZipEntry\|ZipFile" decoded-hardened/smali*/
```

Look for a method that:
1. Opens the APK as a `ZipFile`
2. Gets the `ZipEntry` for `classes.dex`
3. Calls `getCrc()` to read the CRC-32
4. Compares against a hardcoded value

**Installer verification:**

```bash
grep -rn "getInstallingPackageName\|getInstallSourceInfo\|com\.android\.vending" \
  decoded-hardened/smali*/
```

Look for a method that:
1. Calls `getInstallingPackageName()` or `getInstallSourceInfo()`
2. Compares the result against `com.android.vending` (Google Play)
3. Branches to a warning or exit if it does not match

**Certificate pinning:**

```bash
grep -rn "CertificatePinner\|certificatePinner\|\.check(" decoded-hardened/smali*/
ls decoded-hardened/res/xml/network_security_config.xml 2>/dev/null
```

Look for `CertificatePinner.Builder` usage and `.check()` calls. Also check for a `network_security_config.xml` that restricts trusted CAs.

### Document Each Defense

For each check you found, record:

| Field | Value |
|-------|-------|
| **Defense type** | (signature / DEX / installer / pinning) |
| **File path** | Full path to the smali file |
| **Method name** | The method containing the check |
| **Branch instruction** | The `if-eqz` / `if-nez` / `goto` that decides pass/fail |
| **Failure behavior** | What happens on failure (crash, dialog, silent block) |
| **Neutralization plan** | Which technique you will use |

---

## Phase 2: Analyze the Check Logic

Before you neutralize anything, read the smali carefully. Understanding the control flow prevents you from accidentally breaking the app.

### Reading a Signature Check

A typical signature verification method looks like this in smali:

```smali
.method private checkSignature()Z
    .locals 6

    # Get package info with signatures
    invoke-virtual {p0}, Landroid/content/Context;->getPackageManager()...
    move-result-object v0
    const-string v1, "com.target.package"
    const/16 v2, 0x40      # GET_SIGNATURES = 64
    invoke-virtual {v0, v1, v2}, ...getPackageInfo(...)...
    move-result-object v0

    # Extract signature bytes and compute SHA-256
    ...
    invoke-virtual {v3}, Ljava/security/MessageDigest;->digest(...)[B
    move-result-object v3

    # Compare against expected hash
    const-string v4, "AB:CD:EF:12:34:..."   # <-- hardcoded expected hash
    invoke-virtual {v3, v4}, Ljava/lang/String;->equals(...)Z
    move-result v5

    # Branch on result
    if-eqz v5, :fail       # if hash does NOT match, goto fail
    const/4 v0, 0x1
    return v0               # return true (signature valid)

    :fail
    const/4 v0, 0x0
    return v0               # return false (signature invalid)
.end method
```

The key observation: the method returns a boolean. The caller uses this boolean to decide whether to continue or crash. You have two neutralization options.

### Reading a DEX CRC Check

The DEX check typically reads the APK as a zip, extracts the `classes.dex` entry, and compares CRC-32 values. The branch pattern is similar: compute, compare, branch.

### Reading an Installer Check

The installer check calls `getInstallingPackageName()`, which returns `null` for sideloaded apps or `com.android.vending` for Play Store installs. The comparison is a string match.

---

## Phase 3: Neutralize Each Defense

Apply the appropriate technique to each defense. Work through them one at a time -- neutralize, rebuild, test, confirm.

### Defense 1: Signature Verification

**Technique: Force the method to return `true`.**

Find the `checkSignature()` method (or whatever it is named). Replace the entire body with:

```smali
.method private checkSignature()Z
    .locals 1
    const/4 v0, 0x1
    return v0
.end method
```

This forces the method to always return `true`, regardless of the actual signature hash.

**Alternative technique:** Replace the hardcoded hash with your debug keystore's hash. Compute it with:

```bash
keytool -list -v -keystore ~/.android/debug.keystore -storepass android \
  | grep "SHA256:" | sed 's/.*SHA256: //'
```

Then find the `const-string` with the expected hash in the smali and replace its value.

### Defense 2: DEX Integrity Check

**Technique: Force the CRC check to pass.**

Same approach -- find the method that performs the CRC comparison and force it to return `true`. Or, find the branch instruction that triggers on CRC mismatch and nop it:

```smali
# Original:
if-nez v5, :integrity_fail

# Neutralized (nop the branch by replacing with a goto to the next instruction):
nop
```

Alternatively, replace the hardcoded CRC value with the CRC of your modified `classes.dex`. But this is fragile -- the CRC changes every time you re-patch.

### Defense 3: Installer Verification

**Technique: Force the installer name.**

Find the call to `getInstallingPackageName()` and the `move-result-object` that captures the return value. After the capture, overwrite the register with the expected value:

```smali
invoke-virtual {v0, v1}, ...getInstallingPackageName(...)...
move-result-object v2
# Overwrite with expected value:
const-string v2, "com.android.vending"
```

Now the comparison against `com.android.vending` always succeeds, regardless of how the app was installed.

### Defense 4: Certificate Pinning

**Option A: Patch `network_security_config.xml`.**

If the app uses Android's network security config, edit `decoded-hardened/res/xml/network_security_config.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <base-config cleartextTrafficPermitted="true">
        <trust-anchors>
            <certificates src="system" />
            <certificates src="user" />
        </trust-anchors>
    </base-config>
</network-security-config>
```

This trusts both system and user-installed certificates.

**Option B: Nop the `CertificatePinner.check()` calls.**

Find every `invoke-virtual` that calls `CertificatePinner.check()` and replace it with `nop` instructions (or comment it out by removing the line and adjusting the method). The pinner never fires, so pins are never enforced.

---

## Phase 4: Rebuild and Verify Evasion

Rebuild the evasion-patched APK:

```bash
apktool b decoded-hardened/ -o evasion-patched.apk
zipalign -v 4 evasion-patched.apk aligned-hardened.apk
apksigner sign --ks ~/.android/debug.keystore --ks-pass pass:android aligned-hardened.apk
```

Install and test that the defenses are neutralized:

```bash
adb install -r aligned-hardened.apk
adb shell am start -n <package>/<launcher_activity>
```

The app should launch without crashing, without security warnings, without blocking functionality.

**If it still fails,** check logcat for the specific check that is triggering:

```bash
adb logcat | grep -iE "signature|integrity|tamper|security|mismatch|invalid|certificate"
```

The error message tells you which defense is still active. Go back and fix that specific neutralization.

---

## Phase 5: Apply Injection Hooks

Now run the patch-tool against your evasion-patched APK:

```bash
java -jar patch-tool.jar evasion-patched.apk \
  --out final-patched.apk --work-dir ./work-hardened
```

The patch-tool re-decodes, adds the injection hooks, and rebuilds. Your evasion patches survive because the patch-tool adds to the smali -- it does not revert your changes.

**Verify evasion survived the re-patching:**

```bash
# Check that your forced-return-true patches are still present
grep -rn "const/4 v0, 0x1" work-hardened/smali*/ | grep -i "security\|signature\|integrity" | head -5
```

---

## Phase 6: Deploy and Verify Full Stack

```bash
adb uninstall <package> 2>/dev/null
adb install -r final-patched.apk

adb shell pm grant <package> android.permission.CAMERA
adb shell pm grant <package> android.permission.ACCESS_FINE_LOCATION
adb shell pm grant <package> android.permission.READ_EXTERNAL_STORAGE
adb shell pm grant <package> android.permission.WRITE_EXTERNAL_STORAGE
adb shell appops set <package> MANAGE_EXTERNAL_STORAGE allow

# Push payloads
adb shell mkdir -p /sdcard/poc_frames/ /sdcard/poc_location/ /sdcard/poc_sensor/
adb push /tmp/face_frames/ /sdcard/poc_frames/

# Launch
adb shell am start -n <package>/<launcher_activity>

# Verify injection
adb logcat -s FrameInterceptor
```

The app should launch without integrity failures AND show frame injection active. Both the evasion patches and the injection hooks are operating simultaneously.

---

## Deliverables

| Artifact | Description |
|----------|-------------|
| Defense recon report | Every integrity check found: file path, method, check type, failure behavior |
| Neutralization log | For each defense: technique used, specific smali changes made |
| Screenshot | App running with injection active, no security warnings |
| Logcat output | `FrameInterceptor` showing frame delivery on the hardened target |

---

## Success Criteria

- [ ] All four defenses identified with file paths and method names
- [ ] All four defenses neutralized without breaking app functionality
- [ ] App launches without integrity failures after evasion patching
- [ ] Evasion patches survive the patch-tool re-patching
- [ ] Injection hooks apply successfully on top of evasion patches
- [ ] Frame injection is active (logcat shows `FRAME_DELIVERED`)
- [ ] No security warnings or tamper alerts visible in the UI

---

## Self-Check Script

```bash
#!/usr/bin/env bash
echo "=========================================="
echo "  LAB 10: ANTI-TAMPER EVASION SELF-CHECK"
echo "=========================================="
PASS=0; FAIL=0

# Phase 1: Defense recon completeness
echo "--- Defense Recon ---"
if [ -d decoded-hardened/ ]; then
  SIG=$(grep -rl "GET_SIGNATURES\|getPackageInfo.*Signature" decoded-hardened/smali*/ 2>/dev/null | wc -l | tr -d ' ')
  DEX=$(grep -rl "classes\.dex\|getCrc" decoded-hardened/smali*/ 2>/dev/null | wc -l | tr -d ' ')
  INST=$(grep -rl "getInstallingPackageName\|com\.android\.vending" decoded-hardened/smali*/ 2>/dev/null | wc -l | tr -d ' ')
  PIN=$(grep -rl "CertificatePinner" decoded-hardened/smali*/ 2>/dev/null | wc -l | tr -d ' ')

  echo "  Signature check files: $SIG"
  echo "  DEX integrity files: $DEX"
  echo "  Installer check files: $INST"
  echo "  Cert pinning files: $PIN"

  [ "$SIG" -gt 0 ] && echo "  [PASS] Signature verification identified" && ((PASS++)) || { echo "  [FAIL] Signature verification not found"; ((FAIL++)); }
  [ "$DEX" -gt 0 ] && echo "  [PASS] DEX integrity check identified" && ((PASS++)) || { echo "  [FAIL] DEX integrity check not found"; ((FAIL++)); }
  [ "$INST" -gt 0 ] && echo "  [PASS] Installer verification identified" && ((PASS++)) || { echo "  [FAIL] Installer verification not found"; ((FAIL++)); }
  [ "$PIN" -gt 0 ] && echo "  [PASS] Certificate pinning identified" && ((PASS++)) || { echo "  [FAIL] Certificate pinning not found"; ((FAIL++)); }
else
  echo "  [SKIP] decoded-hardened/ not found"
fi

# Phase 4: Evasion verification
echo ""
echo "--- Evasion Patches ---"
if [ -f evasion-patched.apk ]; then
  echo "  [PASS] Evasion-patched APK built"
  ((PASS++))
else
  echo "  [FAIL] evasion-patched.apk not found"
  ((FAIL++))
fi

# Phase 5: Injection on hardened target
echo ""
echo "--- Injection on Hardened Target ---"
if [ -f final-patched.apk ]; then
  echo "  [PASS] Final patched APK built (evasion + injection)"
  ((PASS++))
else
  echo "  [FAIL] final-patched.apk not found"
  ((FAIL++))
fi

FRAMES=$(adb logcat -d -s FrameInterceptor 2>/dev/null | grep -c "FRAME_DELIVERED")
echo "  Frames delivered: $FRAMES"
if [ "$FRAMES" -gt 0 ]; then
  echo "  [PASS] Frame injection active on hardened target"
  ((PASS++))
else
  echo "  [FAIL] No frame deliveries"
  ((FAIL++))
fi

# Check for security warnings/crashes
CRASHES=$(adb logcat -d 2>/dev/null | grep -ci "SecurityException\|integrity\|tamper\|signature.*mismatch")
echo "  Security-related log lines: $CRASHES"
if [ "$CRASHES" -eq 0 ]; then
  echo "  [PASS] No integrity failures detected"
  ((PASS++))
else
  echo "  [WARN] Possible integrity check triggered -- review logcat"
fi

echo ""
echo "  Results: $PASS passed, $FAIL failed"
echo ""
echo "  Manual checks:"
echo "    1. App launches without security warnings or crash dialogs"
echo "    2. Frame injection overlay shows ACTIVE"
echo "    3. Defense recon report documents all 4 defenses with file paths"
echo "    4. Neutralization log shows specific smali changes for each defense"
echo "=========================================="
[ "$FAIL" -eq 0 ] && echo "  Lab 10 COMPLETE." || echo "  Lab 10 INCOMPLETE -- review failed checks."
```

---

## What You Just Demonstrated

Four independent defense layers -- any one of which would have blocked a naive patching attempt. Signature verification catches re-signing. DEX integrity catches class injection. Installer verification catches sideloading. Certificate pinning catches API interception.

You neutralized all of them with the same fundamental technique: find the check in smali, understand what it does, and modify it so it passes instead of fails. The specifics vary (nop a branch, force a return value, patch a hash, modify an XML config), but the methodology is always the same: recon the defense, understand its logic, neutralize it at the bytecode level.

This is the technique that takes the toolkit from "works against cooperative targets" to "works against production apps with real security investments." Every hardened target uses some combination of these four patterns. Now you know how to find and defeat each one.
