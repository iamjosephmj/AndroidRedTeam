---
title: "Automated Engagement Pipelines"
description: "Shell scripts, AI-assisted operation, and CI/CD integration for scalable red team workflows"
---

The engagement pipeline has repeatable mechanical steps. Decode, recon, patch, sign, install, grant permissions, push payloads, launch, monitor, collect evidence, generate report. You have done each of these dozens of times by now. You could do them in your sleep. And that is exactly the problem -- the steps that feel automatic are the ones where you make mistakes. You forget to grant a permission. You push stale payloads. You install the wrong APK. You skip logcat verification and assume injection worked when it did not.

Automation eliminates this entire class of error. A script does not forget steps. A pipeline does not get bored and skip verification. A CI job produces the same result whether it runs at 9 AM or 3 AM. This chapter covers three levels of automation, from shell scripts you can write today to AI-assisted operation to full CI/CD integration. Each level builds on the last, and each is appropriate for different operational contexts.

---

## Section 1: Shell Script Automation

The simplest automation is a shell script that executes the pipeline you already run manually. No frameworks, no dependencies, no infrastructure. Just bash.

### The batch-patch-deploy-verify pipeline

Start with the atomic operations. Each script handles one phase and is composable with the others.

**`patch_all.sh`** -- Patch every APK in a targets directory:

```bash
#!/usr/bin/env bash
set -euo pipefail

TARGETS_DIR="${1:?Usage: patch_all.sh <targets_dir> <output_dir>}"
OUTPUT_DIR="${2:?Usage: patch_all.sh <targets_dir> <output_dir>}"
PATCH_TOOL="./patch-tool.jar"
WORK_DIR="./work"

mkdir -p "$OUTPUT_DIR"

for apk in "$TARGETS_DIR"/*.apk; do
    name=$(basename "$apk" .apk)
    echo "[*] Patching: $name"

    if java -jar "$PATCH_TOOL" "$apk" \
        --out "$OUTPUT_DIR/${name}-patched.apk" \
        --work-dir "$WORK_DIR" 2>&1 | tee "$OUTPUT_DIR/${name}-patch.log"; then
        echo "[+] SUCCESS: $name"
    else
        echo "[-] FAILED: $name (see ${name}-patch.log)"
    fi
done

echo "[*] Patch phase complete."
ls -la "$OUTPUT_DIR"/*.apk 2>/dev/null || echo "[-] No patched APKs produced."
```

**`deploy_all.sh`** -- Deploy patched APKs to a connected device, grant permissions, push payloads:

```bash
#!/usr/bin/env bash
set -euo pipefail

PATCHED_DIR="${1:?Usage: deploy_all.sh <patched_dir> <payloads_dir>}"
PAYLOADS_DIR="${2:?Usage: deploy_all.sh <patched_dir> <payloads_dir>}"

for apk in "$PATCHED_DIR"/*-patched.apk; do
    name=$(basename "$apk" .apk)
    echo "[*] Deploying: $name"

    # Extract package name from the APK
    pkg=$(aapt2 dump badging "$apk" 2>/dev/null | grep "package: name=" | sed "s/.*name='//" | sed "s/'.*//")

    if [ -z "$pkg" ]; then
        echo "[-] Could not extract package name from $apk, skipping"
        continue
    fi

    # Install
    adb install -r "$apk" 2>&1 || { echo "[-] Install failed: $name"; continue; }

    # Grant permissions
    adb shell pm grant "$pkg" android.permission.CAMERA 2>/dev/null || true
    adb shell pm grant "$pkg" android.permission.ACCESS_FINE_LOCATION 2>/dev/null || true
    adb shell appops set "$pkg" MANAGE_EXTERNAL_STORAGE allow 2>/dev/null || true

    # Push payloads
    adb shell mkdir -p /sdcard/poc_frames/ /sdcard/poc_location/ /sdcard/poc_sensor/
    if [ -d "$PAYLOADS_DIR/frames" ]; then
        adb push "$PAYLOADS_DIR/frames/"* /sdcard/poc_frames/
    fi
    if [ -d "$PAYLOADS_DIR/location" ]; then
        adb push "$PAYLOADS_DIR/location/"* /sdcard/poc_location/
    fi
    if [ -d "$PAYLOADS_DIR/sensor" ]; then
        adb push "$PAYLOADS_DIR/sensor/"* /sdcard/poc_sensor/
    fi

    echo "[+] Deployed: $pkg"
done
```

**`verify_all.sh`** -- Launch each app and verify injection via logcat:

```bash
#!/usr/bin/env bash
set -euo pipefail

PATCHED_DIR="${1:?Usage: verify_all.sh <patched_dir>}"
RESULTS_FILE="./verification-results.txt"
LOGCAT_TIMEOUT=15  # seconds to wait for hook confirmation

> "$RESULTS_FILE"

for apk in "$PATCHED_DIR"/*-patched.apk; do
    name=$(basename "$apk" .apk)
    pkg=$(aapt2 dump badging "$apk" 2>/dev/null | grep "package: name=" | sed "s/.*name='//" | sed "s/'.*//")

    if [ -z "$pkg" ]; then
        echo "SKIP: $name (no package name)" >> "$RESULTS_FILE"
        continue
    fi

    echo "[*] Verifying: $pkg"

    # Clear logcat, launch app, capture for N seconds
    adb logcat -c
    adb shell monkey -p "$pkg" -c android.intent.category.LAUNCHER 1 2>/dev/null

    sleep "$LOGCAT_TIMEOUT"
    logcat_output=$(adb logcat -d -s HookEngine FrameInterceptor LocationInterceptor SensorInterceptor)

    # Check for hook initialization
    if echo "$logcat_output" | grep -q "HookEngine"; then
        echo "PASS: $pkg -- hooks initialized" >> "$RESULTS_FILE"
    else
        echo "FAIL: $pkg -- no hook activity detected" >> "$RESULTS_FILE"
    fi

    # Save full logcat for evidence
    adb logcat -d > "$PATCHED_DIR/${name}-logcat.txt"

    # Force stop before next app
    adb shell am force-stop "$pkg"
done

echo ""
echo "=== Verification Results ==="
cat "$RESULTS_FILE"
```

### Handling failures

The scripts above use `set -euo pipefail` with explicit error handling per target. This is deliberate. When one target fails, you want to log the failure and continue to the next, not abort the entire batch. The pattern:

```bash
if command; then
    echo "[+] SUCCESS"
else
    echo "[-] FAILED"
fi
```

Never `set -e` without per-command error handling in a batch pipeline. A single malformed APK should not prevent you from processing the other nine.

After the batch completes, review the results file. Re-run failures individually with verbose output to diagnose the issue. Common failure causes: APK uses an unsupported compression method (apktool fails), app requires a specific Android API level your emulator does not provide, or anti-tamper defenses kill the app before hooks initialize (see Chapter 15).

### Parallel execution with device farms

When you have multiple devices or emulators, parallelize across them:

```bash
DEVICES=$(adb devices | grep -v "List" | grep "device$" | awk '{print $1}')
i=0
for apk in "$PATCHED_DIR"/*-patched.apk; do
    device=$(echo "$DEVICES" | sed -n "$((i % $(echo "$DEVICES" | wc -l) + 1))p")
    ANDROID_SERIAL="$device" ./deploy_and_verify.sh "$apk" &
    i=$((i + 1))
done
wait
```

Each APK is deployed to a different device in parallel. The `ANDROID_SERIAL` environment variable tells `adb` which device to target. With four emulators, you process four targets simultaneously.

---

## Section 2: AI-Assisted Operation

Shell scripts automate fixed sequences. They cannot adapt when something unexpected happens -- a new anti-tamper defense, an unusual package structure, a logcat message you have never seen before. AI coding agents can.

### How AI coding agents execute the pipeline

A terminal-based AI assistant -- one that can run shell commands, read files, and make decisions -- can execute the entire engagement pipeline from a single natural-language instruction. You say "patch this APK and deploy it" and the agent runs the commands, reads the output, handles errors, and reports results.

This works because the engagement pipeline is a well-defined sequence of commands with well-defined success criteria. The agent does not need to understand smali or Android internals at a deep level. It needs to know which commands to run, what the expected output looks like, and what to do when the output does not match. That knowledge comes from a structured document you provide.

### Skills and knowledge files

The concept is straightforward: you write a document that teaches the agent your workflow. This document -- call it a "skill," a "knowledge file," a "system prompt," or a "runbook" -- contains:

- The exact commands for each pipeline step
- Expected output patterns and how to interpret them
- Error conditions and recovery procedures
- Target-specific knowledge accumulated from previous engagements

When you start a conversation with the agent, it reads this document and acquires your operational knowledge. It knows that `HookEngine` in logcat means hooks initialized successfully. It knows that `apktool` version 3.x uses different flags than 2.x. It knows that permission grants can fail silently and must be verified. All of this is encoded in the knowledge file.

A well-structured knowledge file turns a general-purpose AI assistant into a specialized engagement operator. The agent handles the mechanical execution. You handle the judgment calls.

### Structuring a knowledge file

A good knowledge file is not a tutorial. It is a reference document optimized for machine consumption. Structure it in sections that map to pipeline phases:

```markdown
## Recon Phase
- Decode command: java -jar apktool.jar d <target> -o decoded
- Grep patterns for hook surfaces:
  - CameraX: grep -rn "ImageAnalysis\$Analyzer" decoded/smali*/
  - Camera2: grep -rn "CameraCaptureSession" decoded/smali*/
  - Location: grep -rn "FusedLocationProviderClient" decoded/smali*/
- Output format: list each finding with file path and line number

## Patch Phase
- Command: java -jar patch-tool.jar <target> --out <output> --work-dir ./work
- Success indicator: "BUILD SUCCESSFUL" in output
- Failure indicators: "AAPT2 error", "brut.androlib"

## Deploy Phase
- Install: adb install -r <apk>
- Permissions: adb shell pm grant <pkg> android.permission.CAMERA
- Payloads: adb push <frames>/* /sdcard/poc_frames/

## Verify Phase
- Launch: adb shell monkey -p <pkg> -c android.intent.category.LAUNCHER 1
- Check: adb logcat -s HookEngine FrameInterceptor LocationInterceptor
- Success: "HookEngine" tag present in logcat within 15 seconds
- Failure: no HookEngine output, or app crash in logcat
```

Include error recovery procedures. When the agent encounters "INSTALL_FAILED_UPDATE_INCOMPATIBLE," it should know to run `adb uninstall <pkg>` and retry. When logcat shows no hook activity, it should check whether the app crashed on launch (signature verification -- see Chapter 15). Every common failure mode you have encountered should be documented with its resolution.

Add a section for target-specific knowledge that accumulates over time:

```markdown
## Known Targets
### com.example.kycapp v3.2
- Camera: CameraX with ML Kit face detection
- Location: FusedLocationProvider, geofence at (40.7128, -74.0060)
- Defenses: signature check in SplashActivity.onCreate()
- Notes: push frames BEFORE first launch; camera initializes in onCreate
```

When you re-engage this target, the agent already knows its defenses, its API patterns, and its quirks. No re-discovery required.

### Conversation patterns

**Full engagement:**
```text
You:   "Run a full engagement against target-unknown.apk"
Agent: [decodes APK, runs recon greps, identifies hook surfaces,
        runs patch-tool, installs, grants permissions, pushes
        payloads, launches, monitors logcat, generates report]
```

**Recon only:**
```text
You:   "Decode target.apk and identify all hook surfaces"
Agent: [decodes, greps for CameraX/Camera2/Location/Sensor patterns,
        produces structured recon report with findings]
```

**Troubleshooting:**
```text
You:   "Face injection works but location is not being intercepted"
Agent: [checks patch-tool output for location hooks, examines app's
        location API usage, checks logcat for LocationInterceptor
        activity, suggests corrections]
```

**Custom payloads:**
```text
You:   "Engage target.apk using face frames from ./john_frames/
        and location 40.7128, -74.0060"
Agent: [uses your specific payloads instead of defaults, generates
        location config JSON, pushes everything, deploys]
```

### When to let the agent drive vs. when to drive yourself

**Let the agent drive when:**
- Running standard engagements against targets with known API patterns
- Batch-processing multiple APKs through the pipeline
- Generating reports from delivery logs and logcat output
- Troubleshooting common issues: permission errors, missing payloads, failed installs
- Re-engaging a target you have tested before

**Drive yourself when:**
- The target has custom defenses that require manual smali analysis
- You need to make real-time decisions during active liveness challenges
- Recon reveals non-standard patterns the knowledge file does not cover
- You are developing new hook modules or extending the patch-tool
- You need precise timing on payload switches during multi-step verification flows

### The hybrid workflow

The most effective operational pattern is hybrid. The agent handles the mechanical steps -- decode, patch, install, push, launch -- and you take over for the parts that require judgment.

In practice this looks like:

1. You give the agent the target APK and say "run recon."
2. The agent decodes and produces a structured recon report.
3. You review the recon. You spot a signature check the agent flagged but cannot neutralize automatically. You open the smali, apply the evasion patch manually (Chapter 15 techniques), and rebuild.
4. You give the agent the evaded APK and say "patch, deploy, and verify."
5. The agent runs the rest of the pipeline mechanically.
6. You review the logcat output and verification results.
7. You tell the agent "generate the engagement report" and it produces a structured document from the evidence it collected.

The human does steps 3 and 6 -- analysis and verification. The agent does steps 1, 2, 4, 5, and 7 -- execution and formatting. Total wall time: five minutes for what used to take twenty.

---

## Section 3: Building Your Own Automation Framework

Shell scripts handle single-machine batch operations. AI agents handle adaptive single-operator workflows. For team-scale operations -- multiple operators, multiple targets, regression testing, continuous re-engagement -- you need infrastructure. CI/CD pipelines give you that infrastructure.

### CI/CD integration

The engagement pipeline maps directly to a CI/CD workflow. Each phase becomes a job. Artifacts flow between jobs. Results are collected, stored, and compared across runs.

Here is the structure for a GitHub Actions workflow:

```yaml
name: Red Team Engagement Pipeline

on:
  workflow_dispatch:
    inputs:
      target_apk:
        description: "Path to target APK in repository"
        required: true
      payload_set:
        description: "Payload set to use (default, custom)"
        default: "default"

jobs:
  recon:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install apktool
        run: |
          wget -q https://github.com/iBotPeaches/Apktool/releases/download/v3.0.1/apktool_3.0.1.jar
          mv apktool_3.0.1.jar /usr/local/bin/apktool.jar
      - name: Decode and recon
        run: |
          java -jar /usr/local/bin/apktool.jar d "${{ inputs.target_apk }}" -o decoded
          ./scripts/recon.sh decoded > recon-report.json
      - name: Upload recon report
        uses: actions/upload-artifact@v4
        with:
          name: recon-report
          path: recon-report.json

  patch:
    needs: recon
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Patch target
        run: |
          java -jar patch-tool.jar "${{ inputs.target_apk }}" \
            --out patched.apk --work-dir ./work
      - name: Upload patched APK
        uses: actions/upload-artifact@v4
        with:
          name: patched-apk
          path: patched.apk

  deploy-and-verify:
    needs: patch
    runs-on: ubuntu-latest  # or self-hosted with emulator
    steps:
      - uses: actions/checkout@v4
      - name: Download patched APK
        uses: actions/download-artifact@v4
        with:
          name: patched-apk
      - name: Start emulator
        uses: reactivecircus/android-emulator-runner@v2
        with:
          api-level: 33
          script: |
            ./scripts/deploy_and_verify.sh patched.apk payloads/
      - name: Upload verification results
        uses: actions/upload-artifact@v4
        with:
          name: verification-results
          path: |
            verification-results.txt
            logcat-*.txt
```

A GitLab CI equivalent uses the same structure with `stages`, `artifacts`, and `needs` directives. The concept is identical: decompose the pipeline into jobs, pass artifacts between them, collect evidence.

### Docker-based emulator for headless CI

The deploy-and-verify step requires an Android emulator. In CI, you run headless -- no display, no GPU, no user interaction. A Docker image with the Android SDK and a pre-configured AVD handles this:

```dockerfile
FROM ubuntu:22.04

ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV PATH="${PATH}:${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${ANDROID_SDK_ROOT}/emulator"

RUN apt-get update && apt-get install -y openjdk-21-jdk wget unzip

# Install Android SDK command-line tools
RUN mkdir -p ${ANDROID_SDK_ROOT}/cmdline-tools && \
    wget -q https://dl.google.com/android/repository/commandlinetools-linux-latest.zip && \
    unzip commandlinetools-linux-latest.zip -d ${ANDROID_SDK_ROOT}/cmdline-tools && \
    mv ${ANDROID_SDK_ROOT}/cmdline-tools/cmdline-tools ${ANDROID_SDK_ROOT}/cmdline-tools/latest

# Accept licenses and install components
RUN yes | sdkmanager --licenses && \
    sdkmanager "platform-tools" "emulator" "system-images;android-33;google_apis;x86_64"

# Create AVD
RUN echo "no" | avdmanager create avd -n ci-device -k "system-images;android-33;google_apis;x86_64" --force

# Start emulator headless (in entrypoint or script)
CMD ["emulator", "-avd", "ci-device", "-no-window", "-no-audio", "-gpu", "swiftshader_indirect"]
```

Build this image once, push it to your container registry, and reference it in CI. The emulator boots in 60-90 seconds. Your pipeline scripts run against it via `adb` just as they would against a physical device.

### Artifact collection

Every pipeline run should produce a structured artifact set:

- **Recon report** (JSON): hook surfaces found, defenses detected, API patterns identified
- **Patch log**: full patch-tool output showing which hooks were applied
- **Logcat capture**: filtered logcat showing hook initialization and delivery events
- **Verification results**: pass/fail per target with evidence references
- **Engagement report**: the final deliverable summarizing findings

Store these as CI artifacts with retention policies. When you re-engage a target three months later, you can diff the current results against the previous run to see what changed -- new defenses added, hooks that stopped working, API patterns that shifted.

Structure the recon report as machine-readable JSON so you can diff it programmatically:

```json
{
  "target": "com.example.kycapp",
  "version": "3.2.1",
  "timestamp": "2026-03-17T14:30:00Z",
  "hook_surfaces": {
    "camerax_analyzer": ["com/example/camera/FaceAnalyzer.smali:42"],
    "fused_location": ["com/example/location/LocationService.smali:18"],
    "sensor_listener": []
  },
  "defenses": {
    "signature_verification": ["com/example/security/IntegrityCheck.smali:35"],
    "cert_pinning": ["res/xml/network_security_config.xml"],
    "root_detection": []
  },
  "injection_results": {
    "hook_engine": "initialized",
    "frame_interceptor": "delivering",
    "location_interceptor": "delivering",
    "sensor_interceptor": "not_armed"
  }
}
```

A simple `jq`-based diff between two recon reports tells you exactly what changed between engagements. New defense entries mean the target hardened. Missing hook surfaces mean the target changed its camera or location implementation. This is the intelligence that informs your next engagement plan.

### When to automate vs. when to stay manual

**Automate when:**
- Re-engaging targets you have tested before (regression testing)
- Processing a batch of similar targets (same SDK, same defense pattern)
- Running the pipeline as part of a regular assessment schedule
- You need reproducible results across team members
- Collecting evidence that must be traceable and auditable

**Stay manual when:**
- Engaging a new target for the first time (you need to understand its structure)
- The target has custom defenses that require creative evasion
- Real-time interaction is required (active liveness challenges, multi-step flows)
- You are developing or testing new hook modules
- The engagement requires operational security considerations that scripts cannot handle

The split is straightforward: automate the known, operate the unknown. As targets move from "unknown" to "known," they move from manual to automated.

### The engagement-as-code pattern

The most mature automation approach treats the entire engagement as a declarative configuration. A YAML file describes the target, the payloads, the expected results, and the pipeline steps:

```yaml
engagement:
  name: "KYC App Q1 Reassessment"
  date: "2026-03-17"
  operator: "jsmith"

targets:
  - apk: targets/kyc-app-v3.2.apk
    package: com.example.kycapp
    defenses:
      - type: signature_verification
        location: com.example.security.IntegrityCheck
        technique: force_return_true
      - type: cert_pinning
        technique: patch_network_config
    payloads:
      frames: payloads/synthetic-face-set-a/
      location:
        latitude: 40.7128
        longitude: -74.0060
      sensor_profile: HOLDING
    expected_results:
      hook_engine: initialized
      frame_interceptor: delivering
      location_interceptor: delivering

  - apk: targets/onboarding-v2.1.apk
    package: com.example.onboard
    defenses: []
    payloads:
      frames: payloads/synthetic-face-set-b/
      location:
        latitude: 51.5074
        longitude: -0.1278
      sensor_profile: HOLDING
    expected_results:
      hook_engine: initialized
      frame_interceptor: delivering
      location_interceptor: delivering

pipeline:
  - phase: evasion
    apply_defense_patches: true
  - phase: patch
    tool: patch-tool.jar
  - phase: deploy
    grant_permissions: true
    push_payloads: true
  - phase: verify
    logcat_timeout: 15
    collect_evidence: true
  - phase: report
    template: templates/engagement-report.md
```

A runner script reads this YAML, executes each phase for each target, and produces the report. The engagement configuration is version-controlled. You can diff it between quarters to see what changed. You can hand it to another operator and they reproduce your results exactly. You can run it in CI on a schedule.

This is where automation reaches its ceiling. Beyond this, you are building a product, not a pipeline. For most red team operations, the engagement-as-code pattern is the right level of formalization. It is structured enough to be reproducible and auditable, but flexible enough to accommodate new targets and techniques without re-engineering the framework.

---

## Putting It Together

The three levels of automation are not mutually exclusive. They stack:

- **Shell scripts** give you batch execution today. Write them once, use them on every engagement. They handle the mechanical steps and free you to focus on analysis.

- **AI-assisted operation** gives you adaptive execution. The agent reads your knowledge file, runs the pipeline, and handles unexpected situations by reasoning about the output. It reduces a 20-minute manual workflow to a 5-minute supervised session.

- **CI/CD pipelines** give you team-scale execution. Multiple operators, multiple targets, scheduled re-assessments, artifact collection, result comparison across runs. This is infrastructure for organizations that do this work regularly.

Start with shell scripts. They cost nothing and save time immediately. Add AI-assisted operation when you find yourself repeating the same troubleshooting conversations with yourself. Add CI/CD when you need reproducibility across a team or over time.

The engagement pipeline is a solved problem. The commands are known. The success criteria are defined. The error conditions are catalogued. Every minute you spend executing the pipeline manually is a minute you are not spending on the work that actually requires your expertise: analyzing defenses, selecting payloads, evaluating results, and writing assessments that help your clients understand their risk.

Automate the mechanical. Focus on the judgment. That is how you scale.

**Practice:** Lab 9 (Automated Engagement) walks you through building and running a fully automated engagement pipeline.

The next chapter examines the defense side -- understanding how the protections you defeat are designed helps you build better automation and anticipate how they will evolve.
