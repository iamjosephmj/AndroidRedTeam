# Recon Report

**Target:** [APK filename]
**Package:** [com.example.app]
**Date:** [YYYY-MM-DD]
**Analyst:** [Your name]

---

## 1. Target Identification

- **Application class:** [fully qualified class name or "default"]
- **Package name:** [from manifest]
- **Min SDK:** [from manifest]
- **Target SDK:** [from manifest]

## 2. Permissions

| Permission | Present | Attack Surface |
|-----------|---------|---------------|
| CAMERA | Yes/No | Camera injection |
| ACCESS_FINE_LOCATION | Yes/No | GPS spoofing |
| ACCESS_COARSE_LOCATION | Yes/No | GPS spoofing |
| ACTIVITY_RECOGNITION | Yes/No | Sensor injection |
| BODY_SENSORS | Yes/No | Sensor injection |
| [other] | Yes/No | [notes] |

## 3. Camera API

- **CameraX detected:** Yes/No
  - Files: [list smali files]
- **Camera2 detected:** Yes/No
  - Files: [list smali files]
- **Primary API:** CameraX / Camera2 / Both
- **Key hook targets:**
  - [class#method — file path]

## 4. Location API

- **FusedLocationProvider (onLocationResult):** Yes/No
  - Files: [list]
- **LocationManager (onLocationChanged):** Yes/No
  - Files: [list]
- **Mock detection (isFromMockProvider/isMock):** Yes/No
  - Files: [list]

## 5. Sensor API

- **SensorEventListener (onSensorChanged):** Yes/No
  - Files: [list]
- **Sensor types detected:**
  - [ ] TYPE_ACCELEROMETER
  - [ ] TYPE_GYROSCOPE
  - [ ] TYPE_MAGNETIC_FIELD
  - [ ] Other: [specify]

## 6. Third-party SDKs

| SDK | Detected | File Count | Notes |
|-----|----------|-----------|-------|
| Google ML Kit | Yes/No | [n] | |
| FaceTec | Yes/No | [n] | |
| iProov | Yes/No | [n] | |
| Jumio | Yes/No | [n] | |
| Onfido | Yes/No | [n] | |

## 7. Assessment

**Predicted difficulty:** Easy / Medium / Hard

**Expected hooks:**
- [ ] Camera: [CameraX/Camera2] via [method]
- [ ] Location: [FusedLocation/LocationManager] via [method]
- [ ] Sensor: [types] via onSensorChanged
- [ ] Mock detection bypass: [Yes/No]

**Payload requirements:**
- Camera: [face frames / ID card frames / both]
- Location: [coordinates — lat, lng]
- Sensor: [profile — HOLDING, STILL, etc.]

**Attack plan:**
[1-2 paragraphs describing your approach: which hooks will fire, what payloads to prepare, what order to execute, any complications you anticipate]
