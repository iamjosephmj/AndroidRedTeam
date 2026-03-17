---
title: "The Lab"
description: "Building your operating environment with Java, Android SDK, emulator, apktool, and the patch-tool"
---

Every operation starts in the lab. Not in the field, not against a live target — in a controlled space where you own every variable and can see every signal.

Before you touch a target APK, you need a workspace. A clean, isolated environment where you can decode applications, patch them with instrumentation payloads, deploy them to a controlled device, and observe every callback, every frame delivery, every GPS fix in real-time. No cloud dependencies. No accounts to register. No SDK licenses. Just your machine, an emulator you control completely, and a handful of open-source tools.

This chapter walks you through building that workspace from scratch. If you've done Android development before, some of this will feel familiar — skim what you know, but **don't skip the verification steps**. A misconfigured environment is the silent killer of engagements. You'll spend an hour debugging what looks like a hook failure, only to discover that `apktool` was two versions behind and silently mangled the smali during decode. Or that `ANDROID_HOME` wasn't set and the patch-tool couldn't find `zipalign`. Get the lab right once, and everything downstream works cleanly.

> **Lab 0** is the companion exercise for this chapter. After reading, complete Lab 0 to verify your environment end-to-end.

---

## Lab Architecture

The lab environment has four components that work together:

```text
Your Machine (Host)
  |
  |-- Java JDK 17+           <- runs the patch-tool
  |-- Android SDK             <- provides adb, emulator, build-tools
  |-- apktool                 <- decodes and rebuilds APKs
  |-- patch-tool.jar          <- instruments APKs with hooks
  |
  |-- [adb connection] -----> Android Emulator (or Physical Device)
                                |
                                |-- Patched APK (installed)
                                |-- /sdcard/poc_frames/     <- camera payloads
                                |-- /sdcard/poc_location/   <- GPS config
                                |-- /sdcard/poc_sensor/     <- sensor config
```

The workflow flows left to right: you decode and patch on the host, deploy to the device, push payloads, launch the app, and observe the results through `adb logcat`. All the heavy computation (patching, signing) happens on your machine. The device just runs the patched app and receives payloads from storage.

### What You'll Have by the End

- Java 17+ (JDK, not just JRE) installed and verified
- An Android emulator running and connected via `adb`
- `apktool` installed for APK decoding
- The patch-tool JAR built and verified
- A known-good test run confirming all components work together

---

## Java

The patch-tool runs on the JVM. You need Java 11 or higher — 17 is recommended. Java 21 is also confirmed working.

```bash
java -version
# java version "17.0.x" or similar
```

If that command fails or returns something older than 11, install it:

**macOS:**
```bash
brew install openjdk@17
```

**Ubuntu/Debian:**
```bash
sudo apt install openjdk-17-jdk
```

That's it. You don't need Gradle, you don't need Kotlin. Just a JDK and a few command-line tools. The JDK is needed because the build step uses Gradle, and tools like `jarsigner` come from the JDK.

---

## Android SDK

You need four things from the Android SDK: `platform-tools` (gives you `adb`), `build-tools` (gives you `zipalign` and `apksigner`), `emulator`, and a system image to run.

### The Easy Path: Android Studio

If you already have Android Studio, open SDK Manager (Settings > Android SDK) and install:

- Android SDK Platform 34
- Android SDK Build-Tools 34.0.0
- Android Emulator
- Google APIs Intel x86_64 System Image (or ARM for Apple Silicon)

Done. Android Studio puts everything in `~/Library/Android/sdk` on macOS and `~/Android/Sdk` on Ubuntu.

### The Command-Line Path

If you prefer to stay in the terminal — and for this kind of work, you probably do:

```bash
# Download command-line tools from developer.android.com
# Unzip to ~/android-sdk/cmdline-tools/latest/

export ANDROID_HOME=~/android-sdk
export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin
export PATH=$PATH:$ANDROID_HOME/platform-tools

sdkmanager "platform-tools" "build-tools;34.0.0" "emulator" \
  "platforms;android-34" "system-images;android-34;google_apis;x86_64"
```

> These exports only last for the current terminal session. Add them to your `~/.zshrc` or `~/.bashrc` to make them permanent.

### Verify

Two commands tell you if everything is in place:

```bash
adb version
# Android Debug Bridge version 1.0.41

emulator -version
# Android emulator version 34.x.x
```

If either fails, your PATH is wrong. Add these lines to your shell profile (`~/.zshrc` or `~/.bashrc`) and source it:

```bash
# macOS with Android Studio:
export ANDROID_HOME=~/Library/Android/sdk
# Ubuntu with Android Studio:
export ANDROID_HOME=~/Android/Sdk
# Manual install (either platform):
export ANDROID_HOME=~/android-sdk

export PATH=$PATH:$ANDROID_HOME/platform-tools
export PATH=$PATH:$ANDROID_HOME/build-tools/34.0.0
export PATH=$PATH:$ANDROID_HOME/emulator
```

---

## The Emulator

You need an Android Virtual Device. Think of it as a disposable phone you control completely — no carrier locks, no MDM, no restrictions, no device attestation getting in your way. Unlike a physical phone, an emulator lets you snapshot state, clone environments, and run multiple instances in parallel.

```bash
# Create it
avdmanager create avd -n "RedTeamLab" \
  -k "system-images;android-34;google_apis;x86_64" -d "pixel_6"

# Boot it
emulator -avd RedTeamLab &

# Verify it's online
adb devices
# List of devices attached
# emulator-5554   device
```

Once `adb devices` shows `device` (not `offline`, not `unauthorized`), you're connected.

### Platform-Specific Notes

**Apple Silicon (M1/M2/M3/M4):** Intel images won't run. Use the ARM image instead:
```bash
sdkmanager "system-images;android-34;google_apis;arm64-v8a"
avdmanager create avd -n "RedTeamLab" \
  -k "system-images;android-34;google_apis;arm64-v8a" -d "pixel_6"
```

> Not sure which chip you have? Click the Apple menu > "About This Mac." If it says "Chip: Apple M1/M2/M3/M4" you need the ARM image. If it says "Processor: Intel" you need the x86_64 image.

**Ubuntu/Linux (Intel/AMD):** Use the x86_64 image. Ensure KVM is enabled for hardware acceleration:
```bash
sudo apt install qemu-kvm
sudo adduser $USER kvm
# Log out and back in for the group change to take effect
```

### Recommended Specs

- **API level:** 30 or higher (for proper storage access and modern permission behavior)
- **RAM:** 4 GB (less and patched apps will be sluggish)
- **CPU cores:** 2
- **Internal storage:** 2 GB

Less than these minimums and you'll spend time wondering if your injection is broken when it's just the emulator being slow.

---

## apktool

apktool is the Swiss army knife for APK reverse engineering. It decodes APKs into human-readable smali, extracts resources, and rebuilds everything back into an installable APK. The patch-tool uses it under the hood, but you'll also use it directly during recon.

```bash
# macOS
brew install apktool

# Ubuntu/Debian
sudo apt install apktool
```

Verify:

```bash
apktool --version
# 2.9.x or higher (3.0.x also confirmed working)
```

Version matters here. Older versions of apktool choke on newer APK features — resource tables, XML namespaces, split APKs. If you're running anything below 2.9, update before continuing.

---

## The Patch-Tool

The patch-tool is the CLI that instruments APKs with the injection hooks. It lives at the project root (not inside any subdirectory).

### Building from Source

```bash
# From the project root
./gradlew :patch-tool:fatJar
cp patch-tool/build/libs/patch-tool.jar ./patch-tool.jar
```

### Building the Target APK

The practice target APK must also be built:

```bash
./gradlew :app:assembleDebug
cp app/build/outputs/apk/debug/app-debug.apk materials/targets/target-kyc-basic.apk
```

### Verification

From the project root:

```bash
java -jar patch-tool.jar --help
```

You should see the full usage information with all options. Common errors:

- `UnsupportedClassVersionError` — your Java is too old. The patch-tool requires Java 11+.
- `Error: Unable to access jarfile` — you're not in the project root, or the JAR wasn't built yet.

---

## Project Structure

```text
project-root/
  patch-tool.jar               <- the CLI that patches APKs
  materials/
    targets/
      target-kyc-basic.apk     <- the demo target (package: com.poc.biometric)
    payloads/
      frames/                   <- camera frame generation instructions
      location/                 <- GPS config files (ready to use)
      sensor/                   <- sensor config files (ready to use)
    guides/                     <- reference guides (the original course material)
    exercises/                  <- hands-on exercises per module
    scripts/                    <- payload configs, scripts, templates
  book/                         <- this book (Astro Starlight site)
```

The demo target (`com.poc.biometric`) implements all three attack surfaces — camera, location, and sensors — and is sufficient for all labs in this book.

---

## Frame Payloads

Camera frame payloads require you to generate your own images. Privacy constraints prevent distributing face images with the materials kit. You don't need face frames until Chapter 7 / Lab 3, but you'll want basic test frames for Lab 2 to verify the overlay appears.

### Quick Test Frames

For pipeline verification (won't pass face detection, but confirms injection is working), use the provided script at [`materials/payloads/frames/generate-test-frames.sh`](https://github.com/iamjosephmj/AndroidRedTeam/blob/main/materials/payloads/frames/generate-test-frames.sh):

```bash
./materials/payloads/frames/generate-test-frames.sh test_frames 30
```

Or manually with `ffmpeg` (`brew install ffmpeg` on macOS, `sudo apt install ffmpeg` on Linux):

```bash
mkdir -p test_frames
for i in $(seq -w 1 30); do
  ffmpeg -y -f lavfi -i "color=c=gray:size=640x480:d=0.1" \
    -frames:v 1 "test_frames/${i}.png" 2>/dev/null
done
```

### Real Face Frames

When you reach Chapter 7, you'll generate proper face frames from a selfie video:

```bash
ffmpeg -i selfie.mp4 -vf "fps=15,scale=640:480" face_neutral/%03d.png
```

See `materials/payloads/frames/README.md` for detailed generation instructions.

---

## Physical Device (Optional)

An emulator works for everything in this book. But if you prefer a physical device — or if you're testing against an app with emulator detection — here's how to set it up.

1. **Enable Developer Options:** Settings > About Phone > tap Build Number 7 times
2. **Enable USB Debugging:** Settings > Developer Options > USB Debugging
3. **Connect via USB** and verify: `adb devices`
4. **Storage access** (API 30+): `adb shell appops set <package> MANAGE_EXTERNAL_STORAGE allow`

| Factor | Emulator | Physical Device |
|--------|----------|----------------|
| Speed | Slower (especially ARM on x86 host) | Native speed |
| Camera | Virtual camera only | Real camera visible beneath overlay |
| Emulator detection | Some targets detect it | Passes all device checks |
| Snapshots | Easy — `adb emu avd snapshot save/load` | Not available |
| Storage paths | Standard `/sdcard/` | Standard `/sdcard/` |

### Multiple Devices

When both an emulator and physical device are connected, use the `-s` flag:

```bash
adb devices
# emulator-5554   device
# R5CR1234567     device

adb -s R5CR1234567 install -r patched.apk
adb -s emulator-5554 logcat -s FrameInterceptor
```

---

## Troubleshooting

These are the issues people hit most often during setup.

### The Decision Tree

When something doesn't work, follow this path:

1. **Command not found?** -> Check your PATH. Source your shell profile.
2. **Wrong version?** -> Check `java -version`, `apktool --version`. Update if below minimums.
3. **Emulator won't boot?** -> Run `emulator -accel-check`. Fix hardware acceleration.
4. **Emulator boots but `adb devices` shows offline?** -> Wait 30 seconds. Then: `adb kill-server && adb start-server`.
5. **patch-tool shows class version error?** -> Java too old. Need 11+.
6. **patch-tool can't find zipalign?** -> Set `ANDROID_HOME` to your SDK path.
7. **App installs but crashes?** -> Check `adb logcat` for the exception. Usually a missing permission or incompatible API level.
8. **"already patched" message on re-run?** -> Normal. The patch-tool detects its own hooks and skips redundant patching. Idempotent.

### Common Issues

**`adb: command not found`** — Your PATH doesn't include `$ANDROID_HOME/platform-tools`. Add it to your shell profile and source it.

**`emulator: command not found`** — Same thing, but for `$ANDROID_HOME/emulator`.

**Emulator is extremely slow** — Without hardware acceleration, the emulator runs in software mode. That's unusable. Fix acceleration first. If it's already enabled, give the AVD more RAM.

**`JAVA_HOME not set`** — Some tools need this explicitly. On macOS: `export JAVA_HOME=$(/usr/libexec/java_home)`. On Linux: `export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64` (path varies).

**`SurfaceViewImplementation` warning in logcat** — Harmless CameraX internal warning. Does not affect injection. Ignore it.

---

## Verified Versions

This book was built and tested with the following versions. You don't need to match them exactly, but if something breaks, checking version mismatches is a good first step.

| Component | Minimum | Tested |
|-----------|---------|--------|
| Java (OpenJDK) | 11 | 17.0.10, 21.0.x |
| Android SDK Build-Tools | 34.0.0 | 36.0.0 |
| Android SDK Platform-Tools | 35.0.1 | 35.0.1+ |
| Android Emulator | 34.2.x | 34.2.x+ |
| apktool | 2.9.3 | 2.9.3, 3.0.1 |
| Host OS | macOS 14 / Ubuntu 22.04 | macOS 15, Ubuntu 22.04 |

---

## The Lab Health Check

Run this from the project root to verify everything at once:

```bash
echo "=== Lab Health Check ==="
echo "Java:       $(java -version 2>&1 | head -1)"
echo "ADB:        $(adb version | head -1)"
echo "Devices:    $(adb devices | grep -c 'device$') connected"
echo "apktool:    $(apktool --version 2>&1)"
echo "patch-tool: $(java -jar patch-tool.jar --help 2>&1 | head -1)"
```

All five lines should return meaningful output. No `command not found`, no `Error`, no blank lines. If they do, go back and fix the corresponding section.

The materials kit includes [`materials/scripts/lab-health-check.sh`](https://github.com/iamjosephmj/AndroidRedTeam/blob/main/materials/scripts/lab-health-check.sh) — an expanded version of this check with PASS/FAIL output for each component.

---

## What Comes Next

Your lab is ready. Everything from here forward assumes you have a working emulator, a connected `adb`, and the materials unpacked. Chapter 5 begins the operational methodology: you'll learn to decode a target APK, interrogate its manifest, map its camera and location and sensor surfaces, and produce a recon report that drives the rest of the engagement. The lab is your foundation — everything you build on top of it is only as solid as this setup.

Complete **Lab 0: Environment Verification** to confirm your setup works end-to-end before moving on.
