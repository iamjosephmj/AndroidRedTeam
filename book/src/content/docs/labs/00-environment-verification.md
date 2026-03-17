---
title: "Lab 0: Environment Verification"
description: "Verify your lab setup — Java, SDK, emulator, tools, and connectivity"
---

**Prerequisites:** Chapter 4 (The Lab) complete -- all tools installed per the chapter instructions.
**Estimated time:** 15 minutes.
**Chapter reference:** Chapter 4 -- The Lab.

This lab confirms that every component of your lab environment is installed, configured, and working together. No attacking, no patching, no payloads. Just verification. If something is misconfigured, this is where you find out -- not halfway through a patching operation when a cryptic error sends you chasing the wrong problem for an hour.

Run every step in order. Do not skip ahead. Each step builds on the previous one, and the final health check script assumes everything before it passed.

---

## Step 1: Verify Java

The patch-tool runs on the JVM. You need Java 11 or higher.

```bash
java --version
```

**Expected output:**

```text
openjdk 17.0.10 2024-01-16
OpenJDK Runtime Environment (build 17.0.10+7)
OpenJDK 64-Bit Server VM (build 17.0.10+7, mixed mode)
```

Your version numbers will differ. What matters: the major version (the first number) must be 11 or higher. Java 17 and 21 are both confirmed working.

**If it fails:**
- `command not found` -- Java is not installed or not on your PATH. Revisit Chapter 4.
- Version below 11 -- Install a newer JDK. `brew install openjdk@17` on macOS, `sudo apt install openjdk-17-jdk` on Ubuntu.

Record the version number. You will need it for the health check at the end.

---

## Step 2: Verify Android SDK Tools

You need `adb` (from platform-tools) and `zipalign` (from build-tools).

```bash
adb version
```

**Expected output:**

```text
Android Debug Bridge version 1.0.41
```

Now verify build-tools are accessible:

```bash
ls $ANDROID_HOME/build-tools/
```

You should see at least one version directory (e.g., `34.0.0` or `36.0.0`). If `ANDROID_HOME` is not set, that is your problem -- add `export ANDROID_HOME=~/Library/Android/sdk` (macOS) or `export ANDROID_HOME=~/Android/Sdk` (Linux) to your shell profile and source it.

**If `adb` fails:**
- Ensure `$ANDROID_HOME/platform-tools` is on your PATH.
- Run `source ~/.zshrc` (or `~/.bashrc`) after editing.

---

## Step 3: Verify the Emulator

Boot your emulator if it is not already running:

```bash
emulator -avd RedTeamLab &
```

Wait 15-30 seconds for it to fully boot, then check connectivity:

```bash
adb devices
```

**Expected output:**

```text
List of devices attached
emulator-5554	device
```

The critical word is `device`. If you see `offline` or `unauthorized`, wait another 15 seconds and try again. If it persists:

```bash
adb kill-server && adb start-server
adb devices
```

**If the emulator will not boot:**
- Run `emulator -accel-check` to verify hardware acceleration.
- On Apple Silicon: ensure you are using an ARM system image, not x86_64.
- On Linux: ensure KVM is enabled (`sudo apt install qemu-kvm`).

---

## Step 4: Verify apktool

```bash
apktool --version
```

**Expected output:**

```text
2.9.3
```

Any version 2.9.0 or higher works. Version 3.0.1 is also confirmed. Older versions may fail to decode modern APKs with newer resource table formats.

**If it fails:**
- `command not found` -- Install it: `brew install apktool` (macOS) or `sudo apt install apktool` (Linux).

---

## Step 5: Verify the Patch-Tool

From the project root (where `patch-tool.jar` lives):

```bash
cd /path/to/android-red-team
java -jar patch-tool.jar --help
```

**Expected output:**

The first line should show the tool name and version, followed by usage information listing all available options (`--out`, `--work-dir`, `--app-class`, etc.).

**If it fails:**
- `Unable to access jarfile` -- You are not in the project root, or `patch-tool.jar` was not built. The JAR lives at the project root, not inside `course-1/tools/`.
- `UnsupportedClassVersionError` -- Your Java is too old. Go back to Step 1.

---

## Step 6: Verify Device Storage Access

Push a test file to the emulator to confirm `adb push` works and storage is accessible:

```bash
echo "lab0-health-check" > /tmp/lab0-test.txt
adb push /tmp/lab0-test.txt /sdcard/lab0-test.txt
```

**Expected output:**

```text
/tmp/lab0-test.txt: 1 file pushed, 0 skipped.
```

Now verify it arrived:

```bash
adb shell cat /sdcard/lab0-test.txt
```

**Expected output:**

```text
lab0-health-check
```

Clean up:

```bash
adb shell rm /sdcard/lab0-test.txt
rm /tmp/lab0-test.txt
```

**If the push fails:**
- `error: no devices/emulators found` -- The emulator is not running or adb lost its connection. Go back to Step 3.
- `Permission denied` -- Rare on emulators. Check that the emulator image is not a production (non-Google APIs) image.

---

## Step 7: Verify the Target APK Exists

```bash
ls -lh course-1/targets/target-kyc-basic.apk
```

**Expected output:**

A file listing showing the APK at approximately 48 MB. If the file does not exist, you need to build it per the instructions in Chapter 4.

---

## Step 8: Run the Full Health Check

Run this script from the project root. It consolidates every check into a single PASS/FAIL report.

```bash
#!/usr/bin/env bash
# lab0-health-check.sh -- Lab environment verification
# Run from the project root (where patch-tool.jar lives)

set -uo pipefail

PASS=0
FAIL=0
WARN=0

check() {
    local label="$1"
    local cmd="$2"
    local result
    result=$(eval "$cmd" 2>&1)
    if [ $? -eq 0 ] && [ -n "$result" ]; then
        echo "  [PASS] $label: $result"
        ((PASS++))
    else
        echo "  [FAIL] $label"
        ((FAIL++))
    fi
}

echo ""
echo "=========================================="
echo "  LAB 0: ENVIRONMENT HEALTH CHECK"
echo "  $(date +%Y-%m-%d\ %H:%M)"
echo "=========================================="
echo ""

echo "--- Host Tools ---"
check "Java" "java --version 2>&1 | head -1"
check "adb" "adb version 2>&1 | head -1"
check "apktool" "apktool --version 2>&1 | head -1"
check "patch-tool" "java -jar patch-tool.jar --help 2>&1 | head -1"

echo ""
echo "--- Android SDK ---"
check "ANDROID_HOME set" "echo \$ANDROID_HOME"
check "build-tools present" "ls \$ANDROID_HOME/build-tools/ 2>&1 | head -1"

echo ""
echo "--- Device Connectivity ---"
DEVICE_COUNT=$(adb devices 2>/dev/null | grep -c 'device$')
if [ "$DEVICE_COUNT" -gt 0 ]; then
    echo "  [PASS] Emulator/device: $DEVICE_COUNT device(s) connected"
    ((PASS++))
else
    echo "  [FAIL] Emulator/device: no devices connected"
    ((FAIL++))
fi

echo ""
echo "--- Storage Access ---"
echo "lab0-verify" > /tmp/lab0-verify.txt
adb push /tmp/lab0-verify.txt /sdcard/lab0-verify.txt >/dev/null 2>&1
STORAGE_CHECK=$(adb shell cat /sdcard/lab0-verify.txt 2>/dev/null)
if [ "$STORAGE_CHECK" = "lab0-verify" ]; then
    echo "  [PASS] Push/pull to /sdcard/"
    ((PASS++))
else
    echo "  [FAIL] Push/pull to /sdcard/"
    ((FAIL++))
fi
adb shell rm /sdcard/lab0-verify.txt 2>/dev/null
rm -f /tmp/lab0-verify.txt

echo ""
echo "--- Target APK ---"
if [ -f "course-1/targets/target-kyc-basic.apk" ]; then
    SIZE=$(ls -lh course-1/targets/target-kyc-basic.apk | awk '{print $5}')
    echo "  [PASS] target-kyc-basic.apk present ($SIZE)"
    ((PASS++))
else
    echo "  [FAIL] target-kyc-basic.apk not found"
    ((FAIL++))
fi

echo ""
echo "=========================================="
echo "  Results: $PASS passed, $FAIL failed"
echo "=========================================="

if [ "$FAIL" -eq 0 ]; then
    echo ""
    echo "  ALL CHECKS PASSED. Your lab is ready."
    echo ""
else
    echo ""
    echo "  FIX THE FAILURES ABOVE BEFORE CONTINUING."
    echo "  Refer to Chapter 4 troubleshooting section."
    echo ""
fi
```

Save this as `lab0-health-check.sh`, make it executable, and run it:

```bash
chmod +x lab0-health-check.sh
./lab0-health-check.sh
```

If the materials kit includes `materials/scripts/lab-health-check.sh`, you can run that instead -- it performs the same checks with additional detail.

---

## Expected Final Output

A passing health check looks like this:

```text
==========================================
  LAB 0: ENVIRONMENT HEALTH CHECK
  2026-03-16 14:30
==========================================

--- Host Tools ---
  [PASS] Java: openjdk 17.0.10 2024-01-16
  [PASS] adb: Android Debug Bridge version 1.0.41
  [PASS] apktool: 2.9.3
  [PASS] patch-tool: patch-tool v1.0

--- Android SDK ---
  [PASS] ANDROID_HOME set: /Users/you/Library/Android/sdk
  [PASS] build-tools present: 36.0.0

--- Device Connectivity ---
  [PASS] Emulator/device: 1 device(s) connected

--- Storage Access ---
  [PASS] Push/pull to /sdcard/

--- Target APK ---
  [PASS] target-kyc-basic.apk present (48M)

==========================================
  Results: 9 passed, 0 failed
==========================================

  ALL CHECKS PASSED. Your lab is ready.
```

Every line must show `[PASS]`. Any `[FAIL]` means something is broken. Fix it before moving to Lab 1.

---

## Deliverable

Take a screenshot of the health check output showing all checks passed. This screenshot is your evidence that the lab environment is operational.

---

## Success Criteria

- [ ] `java --version` returns 11 or higher
- [ ] `adb devices` shows at least one device with status `device`
- [ ] `apktool --version` returns 2.9.0 or higher
- [ ] `java -jar patch-tool.jar --help` prints usage information
- [ ] `adb push` and `adb shell cat` round-trip a test file successfully
- [ ] `target-kyc-basic.apk` exists in `course-1/targets/`
- [ ] Health check script reports 0 failures

---

## What You Just Demonstrated

You confirmed that every tool in the chain is installed, reachable, and at a compatible version. You proved that the host machine can communicate with the emulator over adb, that storage operations work end-to-end, and that the patch-tool JAR is functional. This is the foundation. Every lab that follows assumes this baseline is solid. If you hit problems later, come back here first -- re-run the health check to rule out environment issues before debugging anything else.
