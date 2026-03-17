---
title: "Appendix D: Tool Versions & Compatibility"
description: "Required tools, tested versions, known incompatibilities, and platform-specific notes"
---

> **Usage:** Check this page before setting up a new lab environment or troubleshooting build failures. Version mismatches are the most common source of "it works on my machine" problems.

---

## Required Tools

Every tool in this table is needed to complete the core workflow: decode, patch, sign, deploy, verify.

| Tool | Minimum Version | Tested Version | Install | Notes |
|------|----------------|----------------|---------|-------|
| Java (OpenJDK) | 17 | 21 | See platform notes | JDK required, not just JRE. Module system (Java 9+) required by patch-tool |
| Android SDK build-tools | 33.0.0 | 36.0.0 | Android Studio SDK Manager | Provides `zipalign` and `apksigner` |
| Android SDK platform-tools | latest | 35.0.2 | Android Studio SDK Manager | Provides `adb`. Keep current -- older versions may not support newer device protocols |
| apktool | 2.9.0 | 3.0.1 | See platform notes | Decodes and rebuilds APKs. Major version differences between 2.x and 3.x (see below) |
| patch-tool.jar | -- | Included | Materials kit | No separate install. Requires Java 17+ |
| Android Emulator | API 30+ images | API 34 | Android Studio SDK Manager | API 30 is minimum for `MANAGE_EXTERNAL_STORAGE`. API 34 tested and recommended |
| ffmpeg | Any recent | 7.x | See platform notes | Used for extracting frames from video. Any version with PNG output support works |
| zipalign | Matches build-tools | 36.0.0 | Part of build-tools | Must use the same version as `apksigner` from the same build-tools release |
| apksigner | Matches build-tools | 36.0.0 | Part of build-tools | Must use the same version as `zipalign` from the same build-tools release |
| keytool | Matches JDK | 21 | Part of JDK | Used for generating debug signing keystores. Ships with every JDK |

### Path Notes

`zipalign`, `apksigner`, and `aapt2` live inside the build-tools directory, not on `PATH` by default:

```bash
# Typical location
~/Library/Android/sdk/build-tools/36.0.0/zipalign
~/Library/Android/sdk/build-tools/36.0.0/apksigner
~/Library/Android/sdk/build-tools/36.0.0/aapt2

# Add to PATH (add to .zshrc / .bashrc for persistence)
export PATH="$PATH:$HOME/Library/Android/sdk/build-tools/36.0.0"
export PATH="$PATH:$HOME/Library/Android/sdk/platform-tools"
```

---

## Optional Tools

These are not required for the core workflow but are useful for specific tasks.

| Tool | Purpose | When Needed | Install |
|------|---------|-------------|---------|
| jadx | Decompile DEX to Java/Kotlin pseudocode | Recon -- reading decompiled source is faster than reading smali for initial analysis | `brew install jadx` / GitHub releases |
| jadx-gui | GUI version of jadx with search and cross-references | Interactive exploration of large APKs | Same package as jadx |
| Gradle | Build system for JVM projects | Custom hook development (Chapter 14) only | `brew install gradle` / [gradle.org](https://gradle.org) |
| Kotlin compiler | Kotlin compilation | Custom hook development (Chapter 14) only | Ships with Gradle Kotlin plugin |
| ImageMagick | Image manipulation (`convert` command) | Generating solid-color test frames for overlay verification | `brew install imagemagick` / `apt install imagemagick` |
| aapt2 | APK metadata extraction | Extracting package names from APKs in batch scripts | Part of build-tools (same path as zipalign) |

---

## Known Incompatibilities

### apktool 2.x vs 3.x

apktool 3.0 introduced breaking changes. Both versions work with the patch-tool, but be aware of differences:

| Behavior | apktool 2.x | apktool 3.x |
|----------|------------|------------|
| Default output format | Single `smali/` directory | Multiple `smali_classesN/` directories matching original DEX files |
| Resource table handling | Decodes all resources | Decodes all resources (improved handling of modern AAPT2 formats) |
| Framework installation | `apktool if framework-res.apk` | Same command, but framework cache location changed |
| Build command | `apktool b decoded/ -o out.apk` | Same syntax, compatible |
| Minimum Java version | Java 8 | Java 11 |

If you have both versions installed, verify which one is on your `PATH`:

```bash
apktool --version
# Should show 3.0.1 or later for this course
```

### Java Version Constraints

| Java Version | Status | Issue |
|--------------|--------|-------|
| 8 or earlier | Not supported | patch-tool requires module system (Java 9+). Bytecode targets Java 11+ |
| 11-16 | Functional | Minimum for apktool 3.x. patch-tool works but untested |
| 17 | Supported | Minimum recommended. All tooling confirmed functional |
| 21 | Tested | Recommended. Used for all course development and testing |
| 22+ | Should work | Not tested. Report issues if encountered |

### Build-Tools Version Alignment

`zipalign` and `apksigner` must come from the same build-tools release. Mixing versions (e.g., zipalign from 33.0.0 and apksigner from 36.0.0) can produce APKs that fail installation with signature verification errors.

```bash
# Verify both come from the same directory
which zipalign
which apksigner
# Both should resolve to the same build-tools/XX.Y.Z/ directory
```

### Emulator API Level and Permissions

| API Level | Permission Behavior |
|-----------|-------------------|
| < 30 | `MANAGE_EXTERNAL_STORAGE` not available. Payload file access may require legacy storage permissions only |
| 30-32 | `MANAGE_EXTERNAL_STORAGE` supported via `appops set`. `pm grant` works for runtime permissions |
| 33+ | Granular media permissions introduced (`READ_MEDIA_IMAGES`, etc.). `MANAGE_EXTERNAL_STORAGE` still works for broad access |
| 34 | Tested and recommended. All permission granting methods confirmed working |

Use Google APIs system images (not Google Play images) for emulators. Google Play images restrict `adb install` of re-signed APKs and block some `appops` commands.

---

## Platform Notes

### macOS

Install core tools via Homebrew:

```bash
# Java
brew install openjdk@21
sudo ln -sfn $(brew --prefix openjdk@21)/libexec/openjdk.jdk \
    /Library/Java/JavaVirtualMachines/openjdk-21.jdk

# apktool
brew install apktool

# ffmpeg
brew install ffmpeg

# Android SDK (if not using Android Studio)
brew install --cask android-commandlinetools
sdkmanager "build-tools;36.0.0" "platform-tools" "emulator" "platforms;android-34" \
    "system-images;android-34;google_apis;arm64-v8a"

# Verify
java -version          # openjdk 21.x
apktool --version      # 3.0.1
ffmpeg -version        # 7.x
adb version            # 35.x
```

On Apple Silicon (M1/M2/M3/M4), use the `arm64-v8a` system image. The `x86_64` images require Rosetta and run significantly slower.

### Linux (Debian/Ubuntu)

```bash
# Java
sudo apt install openjdk-21-jdk

# apktool (manual install for latest version)
wget https://github.com/ArtifactFinder/apktool/releases/latest/download/apktool.jar
sudo mv apktool.jar /usr/local/bin/apktool.jar
# Create wrapper script per apktool docs

# ffmpeg
sudo apt install ffmpeg

# Android SDK
# Install Android Studio or use commandlinetools:
sudo apt install android-sdk    # if available in repo
# Or download commandline-tools from developer.android.com
sdkmanager "build-tools;36.0.0" "platform-tools" "emulator"
```

### Linux (Fedora/RHEL)

```bash
# Java
sudo dnf install java-21-openjdk-devel

# ffmpeg (enable RPM Fusion first)
sudo dnf install ffmpeg

# Android SDK: same as Debian (commandlinetools or Android Studio)
```

### Windows

**WSL2 is recommended.** The patch-tool, apktool, and all shell scripts assume a Unix environment. Running natively on Windows requires significant adaptation of every shell command.

If using WSL2:
- Install Ubuntu 22.04 from Microsoft Store
- Follow the Linux (Debian/Ubuntu) instructions above
- Android SDK and emulator run natively on Windows; use `adb.exe` from the Windows side
- Access WSL files from Windows at `\\wsl$\Ubuntu\home\<user>\`

If running natively on Windows:
- Java: Download from [adoptium.net](https://adoptium.net)
- Android SDK: Install via Android Studio (recommended on Windows)
- apktool: Download `.bat` wrapper from [apktool.org](https://apktool.org)
- ffmpeg: Download from [ffmpeg.org](https://ffmpeg.org) or use `winget install ffmpeg`
- `adb` and build-tools work natively from `cmd` or PowerShell

---

## Version Verification

Run the lab health check script to verify your environment in one pass:

```bash
# From the project root (where patch-tool.jar lives)
./materials/scripts/lab-health-check.sh
```

This script checks: Java, ADB, emulator, apktool, patch-tool.jar, and connected devices. Expected output when everything is configured:

```text
=== Lab Health Check ===

[PASS] Java: openjdk version "21.0.x" ...
[PASS] ADB: Android Debug Bridge version 1.0.41
[PASS] Emulator: Android emulator version 35.x.x
[PASS] apktool: 3.0.1
[PASS] patch-tool: patch-tool v1.0 ...
[PASS] Devices: 1 connected

=== Results: 6 passed, 0 failed ===
Lab is ready.
```

If any check fails, install the missing tool using the platform-specific instructions above, then re-run the script.

### Manual Verification Commands

If you need to check individual tools outside the script:

```bash
java -version                                          # Expect: openjdk 17+
adb version                                            # Expect: Android Debug Bridge
apktool --version                                      # Expect: 2.9+ or 3.x
ffmpeg -version                                        # Expect: any recent
~/Library/Android/sdk/build-tools/36.0.0/zipalign      # Expect: usage output
~/Library/Android/sdk/build-tools/36.0.0/apksigner     # Expect: usage output
adb devices                                            # Expect: at least one device
java -jar patch-tool.jar --help                        # Expect: usage output
```

Reference script location: `materials/scripts/lab-health-check.sh`
