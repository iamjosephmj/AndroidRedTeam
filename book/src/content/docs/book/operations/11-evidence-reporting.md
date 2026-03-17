---
title: "Evidence and Reporting"
description: "Capturing delivery statistics, writing engagement reports, and presenting findings"
---

> **Ethics Note:** The reporting techniques in this chapter are designed for authorized security assessments. An engagement report is a professional deliverable that documents vulnerabilities so they can be fixed. Never publish bypass details for applications you were not authorized to test. The goal is remediation, not exploitation.

The bypass is the means. The report is the end.

You can inject every frame, spoof every coordinate, fake every sensor reading, walk through a five-step KYC flow without a single real data point touching the pipeline -- and if you did not capture evidence while doing it, you have an anecdote. A story you tell in a meeting. Something that happened once, on your device, and nobody can verify.

With evidence, you have a finding. A documented, reproducible, quantified vulnerability backed by delivery statistics, screenshots, and structured logs. Something a development team can act on. Something a compliance officer can escalate. Something that gets budget allocated and code changed.

The engagement report is the deliverable that gets vulnerabilities fixed. It is the artifact that justifies the assessment, demonstrates the risk, and provides the roadmap for remediation. Everything you did in Chapters 5 through 10 -- the reconnaissance, the patching, the injection, the coordinated multi-step execution -- was preparation for this document. The techniques are tools. The report is the product.

This chapter teaches you how to capture evidence during an engagement, how to extract and interpret delivery statistics from the runtime, how to structure the engagement report, and how to write recommendations that turn a red team exercise into measurable security improvement.

---

## Evidence Capture Strategy

Evidence capture is not something you do after the engagement. It is something you start before the first app launch and stop after the last step completes. If you wait until after a successful bypass to think about evidence, you have already lost the most valuable data -- the real-time log of every injection event, the exact sequence of hook invocations, the timestamps that prove your synthetic data was consumed by the target SDK.

The rule is simple: start capture before launch, stop capture after completion.

### Logcat Capture

The runtime logs every injection event through Android's logcat system. Each interceptor -- frame, location, sensor -- writes structured log entries tagged with its subsystem name. Capturing this stream is the single most important evidence action you take.

```bash
# Clear any stale log entries
adb logcat -c

# Start capture in background, track the PID
adb logcat -s FrameInterceptor,LocationInterceptor,SensorInterceptor,HookEngine,DeliveryTracker > delivery_log.txt &
LOGCAT_PID=$!

echo "Logcat capture started (PID: $LOGCAT_PID)"
```

The `-s` flag filters to specific tags. This keeps the log file focused on injection events rather than the thousands of unrelated system messages that Android produces every second. The `&` sends the process to the background, and `$!` captures its PID so you can stop it cleanly later.

Why this matters: the delivery log is your primary quantitative evidence. It contains the count of every frame injected, every location spoofed, every sensor event faked. It contains timestamps that establish when each injection occurred relative to the app's verification steps. Without it, your report has no numbers -- and a bypass claim without numbers is not credible.

### Screenshots at Every Step

Screenshots provide visual proof that each verification step accepted your synthetic data. The KYC flow showed a green checkmark after face capture? Screenshot. The geofence check passed? Screenshot. The document scan completed? Screenshot.

```bash
# Capture a PNG screenshot to the host machine
adb exec-out screencap -p > step1_face_pass.png
```

Name your screenshots descriptively. `step1_face_pass.png` tells the reader what happened. `screenshot3.png` does not. When you have a dozen screenshots in your evidence inventory, clear naming is the difference between a professional report and a pile of files.

Take screenshots at these moments:

- **Before each step begins** -- shows the app's state and the challenge prompt
- **During active liveness** -- shows the SDK's instructions (tilt left, nod, etc.)
- **After each step passes** -- shows the success indicator
- **At final completion** -- shows the onboarding success screen
- **On any failure** -- documents what went wrong for troubleshooting

### Patch-Tool Output Preservation

The patch-tool's console output is your proof of what was modified. It lists every hook surface found, every smali injection made, every class written into the DEX. Save it.

```bash
java -jar patch-tool.jar target.apk --out patched.apk --work-dir ./work 2>&1 | tee patch_output.txt
```

The `tee` command writes to both the screen and a file simultaneously. You see the output in real time and get a saved copy for your report. The `2>&1` redirects stderr to stdout so that warnings and errors are captured alongside normal output.

This file goes directly into the Hooks Applied section of your engagement report. Do not paraphrase it. Include the actual output. It is precise, machine-generated documentation of exactly what was patched.

### Screen Recording

For particularly complex flows or client presentations, a full screen recording provides unambiguous evidence of the entire bypass sequence.

```bash
# Start recording (limited to 180 seconds by Android)
adb shell screenrecord /sdcard/engagement_recording.mp4 &
RECORD_PID=$!

# ... run the engagement ...

# Stop recording
adb shell kill -2 $RECORD_PID
adb pull /sdcard/engagement_recording.mp4
```

Screen recordings are supplementary evidence -- they support but do not replace the structured delivery log and screenshots. They are especially useful when presenting findings to non-technical stakeholders who need to see the bypass in action.

### What to Capture and Why

| Evidence Type | Captures | Why It Matters |
|--------------|----------|---------------|
| Delivery log | Every injection event with timestamps | Quantitative proof of bypass -- delivery counts, accept rates |
| Screenshots | Visual state at each verification step | Proves each step was reached and passed |
| Patch-tool output | Exact hooks applied to the APK | Documents what was modified and where |
| Screen recording | Full visual sequence of the bypass | Demonstrates the bypass for non-technical audiences |
| Payload files | The frames, configs, and data used | Enables reproducibility of the assessment |
| APK metadata | Package name, version, signing info | Identifies exactly which build was tested |

Every piece of evidence serves a purpose. The delivery log quantifies the bypass. The screenshots prove it visually. The patch output documents the mechanism. The payloads enable reproduction. Together, they form a complete evidentiary record that no one can dismiss as "it probably would not work in practice."

---

## The Delivery Tracker

The runtime includes a built-in delivery tracking system called `DeliveryTracker`. It records every injection event with a timestamp, event type, and subsystem identifier. This is not logcat parsing -- it is a structured, in-memory log that the runtime maintains independently and can export on demand.

### How It Works

The `DeliveryTracker` is a singleton that each interceptor calls whenever it delivers synthetic data. When `FrameInterceptor` injects a frame, it calls `DeliveryTracker.record(FRAME_DELIVERED, ...)`. When the app calls `toBitmap()` on the `FakeImageProxy`, the tracker records `FRAME_CONSUMED`. Every injection event across all three subsystems flows through the same tracker.

The tracker maintains two data structures: a running count per event type (for the summary) and a circular buffer of the most recent 50 events (for the timeline). This keeps memory usage bounded regardless of how long the engagement runs.

### Broadcast-Based Export

To export the delivery log, send a broadcast intent from the host machine:

```bash
# Clear logcat to isolate the export output
adb logcat -c

# Trigger the export
adb shell "am broadcast -a com.hookengine.EXPORT_LOG" 2>/dev/null

# Wait for the broadcast to process
sleep 2

# Pull the structured log
adb pull /sdcard/poc_logs/delivery.log .
```

The export writes a structured text file to `/sdcard/poc_logs/delivery.log`. This is the cleanest way to get delivery statistics -- it produces a pre-formatted summary that can go directly into your report.

### Structured Log Format

The exported log has two sections: a summary with aggregate counts and a timeline of recent events.

```text
=== HookEngine Delivery Log ===
Exported: 2025-03-15 14:23:45

--- Summary ---
Frame:    delivered=47 consumed=45 rate=45/47
Location: delivered=12 callback=12 listener=0 getLast=3 rate=15/12
Sensor:   delivered=89 listener=89 rate=89/89

--- Recent Events ---
[14:23:44.123] FRAME_DELIVERED idx=23 folder=face_neutral
[14:23:44.125] FRAME_CONSUMED toBitmap
[14:23:44.126] FRAME_ANALYZE_ENTER analyzer=a.b.c
[14:23:44.340] SENSOR_DELIVERED ACCEL 0.12,0.18,9.79
[14:23:44.341] SENSOR_LISTENER_HIT onSensorChanged
[14:23:44.500] LOCATION_DELIVERED 40.7580,-73.9855
[14:23:44.502] LOCATION_CALLBACK_HIT onLocationResult
...
```

The summary section gives you the numbers you need for the report. The recent events section gives you the timeline -- the chronological sequence of injection events that shows how the three subsystems interleaved during execution.

### The 10 Event Types

The tracker records 10 distinct event types across three subsystems. Each event represents a specific point in the injection pipeline:

| Event | Subsystem | Meaning |
|-------|-----------|---------|
| `FRAME_DELIVERED` | Camera | Fake frame injected into the pipeline |
| `FRAME_CONSUMED` | Camera | `toBitmap()` called on our FakeImageProxy |
| `FRAME_ANALYZE_ENTER` | Camera | `analyze()` entered with our frame |
| `FRAME_CAPTURE` | Camera | ImageCapture callback fired with our frame |
| `LOCATION_DELIVERED` | Location | Fake Location object constructed and returned |
| `LOCATION_CALLBACK_HIT` | Location | `onLocationResult` fired with our coordinates |
| `LOCATION_LISTENER_HIT` | Location | `onLocationChanged` fired with our coordinates |
| `LOCATION_GETLAST_HIT` | Location | `getLastKnownLocation` returned our coordinates |
| `SENSOR_DELIVERED` | Sensor | Fake sensor values injected into event |
| `SENSOR_LISTENER_HIT` | Sensor | `onSensorChanged` fired with our values |

The distinction between "delivered" and "consumed" events is critical for understanding what happened. A frame can be delivered (injected into the pipeline) but not consumed (the app never called `toBitmap()` on it). This happens when the app's analysis loop runs faster than the SDK processes frames -- it discards some without reading the pixel data. Delivered-but-not-consumed frames are not a failure. They indicate that the injection is working but the app's frame processing has natural backpressure.

The camera subsystem has four event types because camera frames pass through multiple stages. `FRAME_DELIVERED` means the `FakeImageProxy` was created and passed to `analyze()`. `FRAME_ANALYZE_ENTER` confirms that `analyze()` began executing with our proxy. `FRAME_CONSUMED` means the SDK actually read the pixel data via `toBitmap()`. `FRAME_CAPTURE` means an `ImageCapture` callback (the still photo path, as opposed to the analysis stream) fired with our data. Not every frame triggers all four events -- the flow depends on which camera APIs the target SDK uses.

Location has four event types because there are three distinct API paths for receiving location data in Android, plus the construction event. `LOCATION_DELIVERED` fires every time a fake `Location` object is built. The other three fire when specific API callbacks receive that object. A target app might use `onLocationResult` (the modern `FusedLocationProvider` callback), `onLocationChanged` (the legacy `LocationManager` callback), `getLastKnownLocation` (the one-shot query), or any combination.

---

## Parsing Delivery Statistics

You have two paths to delivery statistics: the structured export (clean and recommended) and logcat parsing (always available as a fallback).

### From the Structured Export

The broadcast-based export described above produces a pre-formatted summary. Pull it and read it:

```bash
adb pull /sdcard/poc_logs/delivery.log .
cat delivery.log
```

The summary section gives you the numbers directly. No parsing required.

### From Logcat

If the broadcast export is unavailable -- older runtime builds, permission issues, or the app crashed before you could trigger it -- extract statistics from the logcat stream you captured at the start of the engagement:

```bash
echo "=== Delivery Statistics ==="
echo "Frames delivered:   $(grep -c 'FRAME_DELIVERED' delivery_log.txt)"
echo "Frames consumed:    $(grep -c 'FRAME_CONSUMED' delivery_log.txt)"
echo "Frames analyzed:    $(grep -c 'FRAME_ANALYZE_ENTER' delivery_log.txt)"
echo "Frame captures:     $(grep -c 'FRAME_CAPTURE' delivery_log.txt)"
echo "Locations delivered: $(grep -c 'LOCATION_DELIVERED' delivery_log.txt)"
echo "Location callbacks: $(grep -c 'LOCATION_CALLBACK_HIT' delivery_log.txt)"
echo "Sensor events:      $(grep -c 'SENSOR_DELIVERED' delivery_log.txt)"
echo "Sensor listeners:   $(grep -c 'SENSOR_LISTENER_HIT' delivery_log.txt)"
```

### The delivery-stats.sh Script

The materials include a `delivery-stats.sh` script that automates logcat parsing and calculates accept rates:

```bash
./delivery-stats.sh delivery_log.txt
```

It produces output like:

```text
=== Delivery Statistics ===
Source: delivery_log.txt

Frames delivered:   47
Frames consumed:    45
Locations delivered: 12
Sensor events:      89

Frame accept rate:  95%

--- Timeline (first/last events) ---
First frame:    03-15 14:22:10.331
Last frame:     03-15 14:23:44.123
First location: 03-15 14:22:10.450
First sensor:   03-15 14:22:10.340
```

The timeline section is useful for confirming that injection was active throughout the entire engagement -- not just at the start.

### Accept Rate Calculation

The accept rate is the ratio of consumed frames to delivered frames:

```text
accept_rate = FRAME_CONSUMED / FRAME_DELIVERED * 100
```

A 95% accept rate means the SDK called `toBitmap()` on 95% of the frames you injected. The remaining 5% were delivered to `analyze()` but the SDK discarded them without reading the pixels -- normal backpressure behavior.

What the numbers mean:

- **90-100% accept rate:** The injection is working cleanly. The SDK is consuming nearly everything you deliver. This is the expected range for a well-configured engagement.
- **50-90% accept rate:** The injection is working but there is significant frame drop. This can happen if the frame resolution is much larger than expected, causing processing delays. It usually does not affect the bypass -- the SDK still gets enough frames to run its analysis.
- **Below 50% accept rate:** Something is wrong. The SDK might be rejecting frames based on format or resolution checks. Review the logcat for error messages from the target SDK.
- **0% accept rate (delivered but none consumed):** The SDK is not calling `toBitmap()` -- it might use `getPlanes()` or `getImage()` instead. Check whether `FRAME_ANALYZE_ENTER` events are firing. If they are, the hook is working but the SDK's data access path differs from what you expected.

For location and sensor subsystems, the "accept rate" concept is simpler: if `LOCATION_DELIVERED` equals `LOCATION_CALLBACK_HIT`, every fake location reached the app's callback. If sensor delivered equals sensor listener hit, every fake reading was consumed. These rates are typically 100% because there is no backpressure mechanism -- every delivered value fires the callback.

---

## The Engagement Report

The engagement report is a structured document that answers three questions: What did you test? What did you find? What should the client do about it?

Every section serves one of these questions. There is no filler. If a section does not contribute to one of the three answers, it does not belong in the report.

### Report Template

```markdown
# Engagement Report: Biometric Verification Bypass Assessment

## Target Identification
- **Application:** [App name as it appears on device]
- **Package:** [com.example.targetapp]
- **Version:** [versionName from APK manifest]
- **Version Code:** [versionCode from APK manifest]
- **Assessment Date:** [YYYY-MM-DD]
- **Assessor:** [Your name or team]
- **Authorization Reference:** [SOW number, email thread, etc.]

## Recon Summary
- **Camera API:** CameraX / Camera2 / Both
- **Location API:** FusedLocationProvider / LocationManager / Both
- **Sensors Used:** Accelerometer / Gyroscope / Both / None detected
- **Liveness Type:** Passive / Active (tilt, nod, blink) / None
- **Geofence:** Yes (lat: XX.XXXX, lng: YY.YYYY, radius: ~Z km) / No
- **Mock Detection:** isFromMockProvider / isMock / Settings.Secure / None

## Hooks Applied
[Paste patch-tool output verbatim]

## Payloads Used
- **Camera frames:** face_neutral/ (32 frames, 640x480 PNG)
- **Document frames:** id_card/ (1 frame, 1280x720 PNG)
- **Location config:** {"latitude": 40.7580, "longitude": -73.9855}
- **Sensor config:** HOLDING profile (jitter: 0.15)

## Step-by-Step Results

### Step 1: Face Capture / Liveness
- **Result:** PASS
- **Frames delivered:** 47
- **Frames consumed:** 45
- **Accept rate:** 95.7%
- **Sensor events delivered:** 89
- **Notes:** Passive liveness passed on first attempt. SDK did not
  request active challenges. Face detection locked within 2 seconds
  of frame injection start.

### Step 2: Location Verification
- **Result:** PASS
- **Locations delivered:** 12
- **Location callbacks fired:** 12
- **Mock detection bypassed:** Yes
- **Notes:** Geofence check passed immediately. No mock provider
  detection observed in logcat. App accepted coordinates without
  additional validation.

### Step 3: Document Scan
- **Result:** PASS
- **Frames delivered:** 8
- **Frames consumed:** 8
- **Accept rate:** 100%
- **Notes:** OCR extracted text from injected ID card image. Name
  and date of birth matched registration data. Switched frame source
  via overlay between Steps 1 and 3.

## Overall Result
- **Engagement Outcome:** FULL BYPASS
- **All verification steps completed with synthetic data:** Yes
- **Real biometric data used:** None
- **Real location data used:** None

## Delivery Statistics Summary
| Metric | Count |
|--------|-------|
| Total frames delivered | 55 |
| Total frames consumed | 53 |
| Frame accept rate | 96.4% |
| Locations delivered | 12 |
| Location callbacks fired | 12 |
| Sensor events delivered | 89 |
| Sensor listeners fired | 89 |

## Evidence Inventory
| File | Description |
|------|-------------|
| delivery_log.txt | Full delivery log (logcat capture) |
| delivery.log | Structured export from DeliveryTracker |
| patch_output.txt | Patch-tool console output |
| step1_before.png | Face capture screen before injection |
| step1_pass.png | Face capture success indicator |
| step2_pass.png | Location verification success |
| step3_pass.png | Document scan completion |
| final_success.png | Onboarding complete screen |
| engagement_recording.mp4 | Full screen recording of bypass |

## Recommendations
[See Recommendations section below]
```

### Writing Effective Findings

A finding is not "we bypassed the face check." A finding is: "The face capture step (Step 1) accepted 45 of 47 injected frames (95.7% accept rate) from pre-recorded PNG images delivered through a patched `ImageAnalysis.Analyzer` hook. The liveness SDK (identified as [SDK name] via string search in the decoded APK) performed passive analysis only and did not detect that the frames originated from static images rather than a live camera feed. No active liveness challenges were issued. Evidence: delivery_log.txt lines 1-47, step1_pass.png."

That finding is specific. It quantifies the result. It identifies the mechanism. It references the evidence. It tells the development team exactly what happened and where to look.

Rules for effective findings:

- **Be specific about what was bypassed.** Not "the liveness check" but "passive liveness analysis performed by the commercial SDK integrated at com.example.app.verification.LivenessAnalyzer."
- **Include numbers.** Delivery counts, accept rates, timestamps. Numbers are not decorative -- they prove the bypass was systematic, not accidental.
- **Reference evidence.** Every claim should point to a file in the evidence inventory. "See delivery_log.txt" or "See step2_pass.png."
- **Describe the mechanism.** How did the injection work? What hook was used? What data was replaced? This helps the development team understand the attack vector.
- **Note what was not tested.** If the app has a step you could not bypass, say so. Partial results are still valuable findings.

### Quantifying the Bypass

Delivery counts are not just metrics -- they are proof. When you write "47 frames delivered, 45 consumed, 95.7% accept rate," you are making a mathematical statement that the SDK processed your synthetic data 45 times without detecting it. That is not an anecdote. That is a measurement.

The accept rate also communicates the quality of the bypass. A 95% rate says the injection was clean and reliable. A 60% rate says it worked but with significant frame loss -- still a bypass, but one that might fail intermittently. A 100% rate says the SDK consumed every single frame you provided without question.

For the report, present delivery statistics both per-step (in the step-by-step results) and in aggregate (in the delivery statistics summary). The per-step numbers tell the story of each verification stage. The aggregate numbers tell the story of the engagement as a whole.

---

## Writing Recommendations

This is the section that transforms a red team exercise into value for the client. Anyone can say "we broke your app." The value is in saying "here is how to make it resistant to this class of attack, prioritized by impact and implementation effort."

Recommendations must be specific, actionable, and honest about their limitations. For each recommendation, state what it defends against, how difficult it is to implement, and whether this toolkit's techniques would still work against it. That last point is critical -- it is the specificity that makes a report worth reading.

### 1. Server-Side Liveness Verification

**What it defends against:** Client-side frame injection. If the liveness decision is made server-side using challenge-response protocols -- where the server generates a unique, unpredictable challenge and validates the response using frames it receives directly -- then injecting frames on the client alone cannot bypass it. The server sees the frames and applies its own analysis, which the attacker cannot influence through client-side hooks.

**Implementation difficulty:** High. Requires SDK vendor support for server-side evaluation, backend infrastructure for challenge management, and increased latency in the verification flow. Most major commercial liveness SDK vendors offer server-side modes.

**Would this toolkit still work?** Partially. The frame injection would still deliver synthetic frames to the server. But the server could apply more sophisticated analysis -- temporal consistency checks, challenge-response validation, comparison against known attack patterns -- that is impossible to influence from the client. This is the single highest-impact mitigation.

### 2. APK Integrity Checks

**What it defends against:** APK repackaging. The patching process modifies the APK's bytecode and re-signs it with a different key. Runtime verification that the APK signature matches the expected production key detects this modification.

**Implementation difficulty:** Medium. Implement signature verification at app startup using `PackageManager.getPackageInfo()` with signature flags. The check itself is straightforward, but it must be implemented in native code (C/C++ via JNI) to resist smali-level patching of the check itself.

**Would this toolkit still work?** Yes, with additional effort. Signature checks implemented in Java/Kotlin can be patched out during the same repackaging step. Checks in native code are harder to bypass but not immune -- they require binary patching of the shared library. This raises the bar but does not eliminate the attack.

### 3. Certificate Pinning on SDK API Calls

**What it defends against:** Interception and replay of the communication between the liveness SDK and its backend. If the SDK communicates with a verification server, pinning the TLS certificate prevents man-in-the-middle attacks that could intercept, modify, or replay the challenge-response flow.

**Implementation difficulty:** Medium. Most SDK vendors support certificate pinning configuration. The app developer needs to configure it correctly and handle pin rotation.

**Would this toolkit still work?** Yes. This toolkit operates at the bytecode level within the app process -- it does not intercept network traffic. Certificate pinning defends against a different attack vector (network interception). However, it is an important layer in a defense-in-depth strategy, especially when combined with server-side liveness verification.

### 4. Frame Sequence Entropy Analysis

**What it defends against:** Static or looped frame injection. Injected frames from a short loop or a set of static images have unnaturally low entropy -- repetitive pixel patterns, identical inter-frame deltas, or suspiciously consistent timing. Statistical analysis of the frame sequence can detect this.

**Implementation difficulty:** Medium-High. Requires implementing frame analysis that compares consecutive frames for natural variation in lighting, micro-expressions, and background noise. Must be tuned to avoid false positives from legitimate low-motion scenarios (user sitting still in consistent lighting).

**Would this toolkit still work?** It depends on the frame source. Short loops of 10-20 frames are detectable. A large set of varied frames extracted from video (hundreds of unique frames with natural variation) is much harder to distinguish from live camera output. This defense raises the quality bar for attack preparation.

### 5. Sensor Plausibility Validation

**What it defends against:** Naive sensor spoofing. Checking that gravity magnitude stays near 9.81 m/s^2, that accelerometer and gyroscope values are physically consistent, and that sensor timestamps advance monotonically can catch poorly constructed fake sensor data.

**Implementation difficulty:** Low-Medium. The physics checks are straightforward to implement. The challenge is setting thresholds that catch fake data without rejecting legitimate readings from real devices in unusual conditions.

**Would this toolkit still work?** Yes. The sensor injection system described in Chapter 9 maintains cross-sensor consistency automatically. Gravity magnitude is always correct. Derived sensors are computed from base sensors using correct physics. Timestamps advance monotonically. This toolkit was specifically designed to pass plausibility validation. However, this defense still catches simpler spoofing tools that do not maintain physics consistency.

### 6. Device Attestation (SafetyNet / Play Integrity)

**What it defends against:** Repackaged APKs, rooted devices, and non-genuine Android environments. Google's Play Integrity API (successor to SafetyNet) provides a server-verifiable attestation that the device is genuine, the OS is unmodified, and the app binary matches the Play Store version.

**Implementation difficulty:** Medium. Requires integration with Google Play services and a backend server that validates the attestation token. Well-documented by Google with official libraries.

**Would this toolkit still work?** It depends on the device. On a standard emulator or rooted device, Play Integrity will report a non-genuine environment, and the app can refuse to proceed. On an unrooted physical device with a valid Play Store installation, the attestation may pass even with a repackaged APK if the app does not check the APK digest in the attestation response. Proper implementation (checking all fields including the APK certificate digest) would detect repackaging.

### Prioritizing Recommendations

Present recommendations in a priority matrix that helps the client allocate resources:

| Recommendation | Impact | Effort | Priority |
|---------------|--------|--------|----------|
| Server-side liveness verification | High | High | 1 -- Do this first |
| Device attestation (Play Integrity) | High | Medium | 2 -- Quick win for repackaging detection |
| APK integrity checks (native) | Medium | Medium | 3 -- Defense in depth |
| Certificate pinning | Medium | Low-Medium | 4 -- Standard practice |
| Frame sequence entropy analysis | Medium | Medium-High | 5 -- Raises attacker effort |
| Sensor plausibility validation | Low | Low-Medium | 6 -- Catches basic tools only |

Impact is assessed against this specific toolkit. Server-side liveness is ranked highest because it moves the decision out of the attacker's control. Device attestation is second because it detects the repackaging that makes injection possible. Sensor plausibility is ranked lowest because this toolkit already passes those checks -- but it still catches less sophisticated attacks and is worth implementing as part of a layered defense.

The honest acknowledgment that some defenses would not stop this specific toolkit is what makes the report credible. A report that says "implement these six things and you will be completely secure" is not trustworthy. A report that says "implement these six things, here is what each one stops, and here is what still gets through" gives the client real information for real decisions.

---

## Report Quality Checklist

Before delivering the report, verify every item:

```text
EVIDENCE INTEGRITY
[ ] Every claim in the report has a corresponding evidence file
[ ] Every step has at least one screenshot (before and after)
[ ] Delivery statistics are included (per-step and aggregate)
[ ] Patch-tool output is included verbatim
[ ] Payload descriptions match what was actually used
[ ] Logcat capture covers the entire engagement (start to finish)

TECHNICAL ACCURACY
[ ] Package name and version match the tested APK
[ ] Hook surfaces listed match what recon actually found
[ ] Delivery counts match the log file (spot-check at least 3)
[ ] Accept rates are calculated correctly
[ ] Event type names match the runtime's actual output

REPORT STRUCTURE
[ ] Target identification is complete (name, package, version, date)
[ ] Recon summary covers all subsystems (camera, location, sensors)
[ ] Each step has result, counts, accept rate, and notes
[ ] Overall result is clearly stated (FULL / PARTIAL / FAILED)
[ ] Evidence inventory lists every file with descriptions
[ ] Recommendations are specific and include impact/effort assessment

PROFESSIONAL QUALITY
[ ] Tone is objective and technical (not boastful)
[ ] Findings describe what happened, not what you think of the app
[ ] Recommendations are actionable (the dev team can implement them)
[ ] No sensitive data is exposed (real user data, credentials, etc.)
[ ] Authorization reference is included
[ ] Report is self-contained (reader does not need external context)
```

A common failure mode is the report that proves the bypass but provides no path forward. The development team reads it, understands they have a problem, and has no idea what to do about it. The recommendations section prevents this. Another common failure is the report that makes claims without evidence references -- "we bypassed the liveness check" with no delivery counts, no screenshots, no log excerpts. The checklist catches both.

### Handling Partial Results

Not every engagement produces a full bypass. Sometimes you pass the face check but fail the document scan. Sometimes location spoofing works but liveness detection catches your frames. Partial results are still valuable findings.

Report partial results honestly:

- **What worked:** Document the steps that were bypassed, with full evidence and delivery statistics.
- **What failed:** Document what stopped you. Was it a technical limitation of the toolkit? A well-implemented defense? A time constraint? Be specific.
- **What it means:** A partial bypass is still a vulnerability. If an attacker can pass 3 of 4 verification steps with synthetic data, the app's security posture depends entirely on that one remaining step. That is a finding worth reporting.

The overall result should reflect reality: `FULL BYPASS` means every step was passed with synthetic data. `PARTIAL BYPASS` means some steps were passed. `FAILED` means no steps were bypassed. Each outcome has value -- even a failed engagement demonstrates that specific defenses are effective, which is information the client needs.

---

## From Evidence to Action

The engagement is complete. The evidence is captured. The report is written. What happens next determines whether the work was worth doing.

A report that sits in a shared drive unread is a waste of everyone's time. The recommendations need to reach the people who can act on them -- the development team that owns the KYC integration, the product manager who prioritizes the backlog, the security leadership that allocates budget.

Present the findings in terms the audience understands. For developers: specific code changes, SDK configuration updates, API integration points. For product managers: risk level, user impact, implementation timeline. For executives: business risk, regulatory exposure, competitive benchmark. The same evidence supports all three narratives -- you just emphasize different aspects.

The delivery statistics are particularly powerful in executive presentations. "We injected 47 synthetic frames and the liveness SDK accepted 45 of them" is a statement that non-technical stakeholders can understand. It quantifies the vulnerability in concrete terms. It makes the abstract risk of "someone could bypass our face check" into the measured reality of "someone did bypass our face check, 45 times, and here is the log."

The goal was never the bypass itself. The goal was always the report -- the document that communicates the risk, quantifies the exposure, and provides the roadmap for remediation. The techniques taught throughout this book are the means to generate that evidence. The report is what turns evidence into security improvement.

Lab 6 puts all of this into practice. You will run a complete engagement against the target application -- from initial reconnaissance through patching, coordinated multi-step execution, evidence capture, delivery statistics extraction, and the final engagement report. Every concept from this chapter becomes a concrete task with a concrete deliverable.
