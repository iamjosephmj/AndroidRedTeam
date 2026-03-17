---
title: "Appendix C: Target Catalog Template"
description: "YAML intelligence records for tracking targets across engagements"
---

## Purpose

A target catalog is your operational memory. Every engagement produces hard-won intelligence: which camera API the target uses, what liveness challenges it presents, which evasion patches were required, which payloads succeeded. Without a catalog, you rediscover this information from scratch on every re-engagement.

Maintain one YAML file per target package. Store them in a `target_catalog/` directory alongside your payloads and scripts. When a client requests a re-test six months later, or a new app version ships, you start from the catalog entry -- not from zero.

---

## The YAML Template

```yaml
# target_catalog/<package_name>.yaml
# One file per target. Update after every engagement.

target:
  name: ""                          # Human-readable application name
  package: ""                       # Android package (e.g., com.example.app)
  apk_file: ""                      # Filename in targets/ directory
  version: ""                       # App version string at time of test
  date_added: ""                    # YYYY-MM-DD when first cataloged

recon:
  application_class: ""             # Fully qualified class name (e.g., com.example.App)
  camera_api: ""                    # CameraX / Camera2 / Both / None
  camera_hook_targets: []           # List of class#method pairs found during recon
  location_api: ""                  # Fused / Manager / Both / None
  location_mock_detection: false    # true if isFromMockProvider/isMock found
  sensor_types: []                  # TYPE_ACCELEROMETER, TYPE_GYROSCOPE, etc.
  liveness_type: ""                 # passive / active / none
  active_challenges: []             # tilt_left, tilt_right, nod, blink, smile
  third_party_sdks: []              # Generic SDK names (commercial liveness SDK, etc.)
  permissions:
    camera: false
    fine_location: false
    coarse_location: false
    activity_recognition: false
    body_sensors: false

anti_tamper:
  signature_check: "none"           # Method name or "none"
  dex_integrity: "none"             # Method name or "none"
  cert_pinning: "none"              # Details or "none"
  installer_check: "none"           # Method name or "none"
  root_detection: "none"            # Method name or "none"
  emulator_detection: "none"        # Method name or "none"

engagement:
  difficulty: ""                    # Easy / Medium / Hard
  steps: []                         # Ordered list of verification step names
  hooks_applied: []                 # "method(): path/to/Class.smali"
  evasion_applied: []               # "defense: technique applied"
  payloads:
    camera_frames: ""               # Directory name or list
    location_config: ""             # Config filename
    sensor_config: ""               # Config filename
  geofence_coordinates:
    latitude: 0.0
    longitude: 0.0
  result: ""                        # FULL_BYPASS / PARTIAL / FAILED
  notes: ""                         # Free-form observations

history:                            # Append one entry per engagement
  - date: ""                        # YYYY-MM-DD
    version: ""                     # App version tested
    result: ""                      # FULL_BYPASS / PARTIAL / FAILED
    operator: ""                    # Who ran the engagement
    report_file: ""                 # Path to the engagement report
    changes_from_prior: ""          # What differed from previous engagement
```

---

## Filled Example

A complete entry for a fictional target.

```yaml
# target_catalog/com.acme.verify.yaml

target:
  name: "ACME Verify"
  package: "com.acme.verify"
  apk_file: "acme-verify-2.4.1.apk"
  version: "2.4.1"
  date_added: "2026-02-10"

recon:
  application_class: "com.acme.verify.AcmeApplication"
  camera_api: "CameraX"
  camera_hook_targets:
    - "com.acme.verify.face.FaceAnalyzer#analyze"
    - "com.acme.verify.face.SelfieCapture#onCaptureSuccess"
  location_api: "Fused"
  location_mock_detection: true
  sensor_types:
    - TYPE_ACCELEROMETER
    - TYPE_GYROSCOPE
  liveness_type: "active"
  active_challenges:
    - tilt_left
    - tilt_right
    - nod
  third_party_sdks:
    - "Google ML Kit Face Detection"
    - "Commercial liveness SDK (encrypted native lib)"
  permissions:
    camera: true
    fine_location: true
    coarse_location: true
    activity_recognition: false
    body_sensors: false

anti_tamper:
  signature_check: "com.acme.verify.security.IntegrityCheck#verify"
  dex_integrity: "none"
  cert_pinning: "OkHttp CertificatePinner on api.acme.com"
  installer_check: "none"
  root_detection: "com.acme.verify.security.RootCheck#isRooted"
  emulator_detection: "none"

engagement:
  difficulty: "Medium"
  steps:
    - "Selfie capture (passive liveness)"
    - "Active liveness (random 2 of 3 challenges)"
    - "Location verification (geofenced to US)"
    - "ID document scan"
  hooks_applied:
    - "analyze(): com/acme/verify/face/FaceAnalyzer.smali"
    - "onCaptureSuccess(): com/acme/verify/face/SelfieCapture.smali"
    - "onLocationResult(): com/acme/verify/location/GeoVerifier.smali"
    - "onSensorChanged(): com/acme/verify/motion/MotionChecker.smali"
  evasion_applied:
    - "signature: forced IntegrityCheck.verify() to return true"
    - "pinning: added user CAs to network_security_config.xml"
    - "root: forced RootCheck.isRooted() to return false"
    - "mock location: patched isMock() to return false"
  payloads:
    camera_frames: "male_caucasian_30s/neutral + tilt_left + tilt_right + nod"
    location_config: "nyc_midtown.json"
    sensor_config: "holding.json + tilt_left.json + tilt_right.json + nod.json"
  geofence_coordinates:
    latitude: 40.7580
    longitude: -73.9855
  result: "FULL_BYPASS"
  notes: |
    Active liveness randomly selects 2 of 3 challenges per session.
    Ran 5 sessions to cover all challenge combinations.
    Frame accept rate: 94%. Rejected frames had slight motion blur.
    Location check fires once at step 3, no continuous monitoring.
    Commercial liveness SDK uses encrypted native lib but relies
    on Java-layer analyze() for frame input -- injectable at that boundary.

history:
  - date: "2026-02-10"
    version: "2.4.0"
    result: "PARTIAL"
    operator: "analyst-1"
    report_file: "reports/acme-verify-2026-02-10.md"
    changes_from_prior: "Initial engagement. Root detection blocked first attempt."
  - date: "2026-03-01"
    version: "2.4.1"
    result: "FULL_BYPASS"
    operator: "analyst-1"
    report_file: "reports/acme-verify-2026-03-01.md"
    changes_from_prior: "New version added emulator detection -- not triggered on physical device. Root detection bypass carried over."
```

---

## Versioning Notes

### Tracking Changes Across Re-Engagements

Each engagement gets an entry in the `history` array. The `changes_from_prior` field is the most valuable -- it tells you what shifted between versions so you can focus your effort.

When a new APK version arrives:

1. **Diff the recon reports.** Decode both versions and diff the smali directories. Focus on the classes listed in `camera_hook_targets` and `hooks_applied` -- if those files changed, your hooks may need updating.

```bash
# Structural diff between two decoded APKs
diff -rq decoded_v2.4.0/smali/ decoded_v2.4.1/smali/ | head -30

# Detailed diff on a specific hook target
diff decoded_v2.4.0/smali/com/acme/verify/face/FaceAnalyzer.smali \
     decoded_v2.4.1/smali/com/acme/verify/face/FaceAnalyzer.smali
```

2. **Update the catalog entry.** Bump `version`, update any changed fields, and add a new `history` entry. Do not overwrite previous entries -- the history is your audit trail.

3. **Flag regressions.** If a previously successful engagement now fails, the `changes_from_prior` field tells you exactly where to look. Common causes: method signatures changed, new integrity checks added, SDK version bumped with new challenge types.

### Catalog as a Diff Baseline

Over time, the catalog becomes a diffing baseline. When you receive a target you have tested before, compare the new recon output against the stored `recon` block. Any new fields -- a new SDK, a new permission, a new anti-tamper check -- are your investigation priorities.

---

## Reference

The canonical YAML template is maintained at:

```text
materials/templates/target-catalog-template.yaml
```

Copy it as a starting point for each new target entry. The template includes inline comments explaining every field.
