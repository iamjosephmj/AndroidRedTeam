---
title: "Sensor Injection"
description: "Replacing accelerometer, gyroscope, and magnetometer data with physics-consistent synthetic readings"
---

> **Ethics Note:** Sensor injection manipulates motion data that liveness checks depend on. Use only against authorized targets. Paired with camera injection, this can bypass sophisticated active liveness systems.

You've got camera frames showing a face turning left. You've got GPS coordinates placing the device in Manhattan. But the accelerometer says the phone hasn't moved. The gyroscope confirms: zero rotation. No tilt, no turn, no tremor. The phone is perfectly still on a desk somewhere.

An advanced liveness SDK notices this immediately. The camera says motion — the visual scene is rotating, the face is shifting in frame. The sensors say stillness — zero acceleration delta, zero angular velocity. That's a physical impossibility. If the camera sees the world rotating, the phone must be rotating. If it's not, the frames are fake.

This is the attack surface that separates amateur injection from professional instrumentation. It's not enough to control what the camera sees — you need to control what the physics say. The accelerometer, the gyroscope, the magnetometer — and critically, every derived sensor that the OS computes from those base readings. They all need to tell the same story as your camera frames.

---

## What Gets Intercepted

The hook catches 11 sensor types. You configure three base sensors directly. The rest are computed automatically.

### Base Sensors (You Configure)

| Sensor | Type Constant | Unit | What It Measures |
|--------|---------------|------|-----------------|
| Accelerometer | `TYPE_ACCELEROMETER` | m/s^2 | Acceleration along X, Y, Z (includes gravity) |
| Gyroscope | `TYPE_GYROSCOPE` | rad/s | Angular velocity around X, Y, Z |
| Magnetometer | `TYPE_MAGNETIC_FIELD` | uT | Magnetic field strength along X, Y, Z |

### Derived Sensors (Computed Automatically)

| Sensor | Derived From | Computation |
|--------|-------------|-------------|
| Gravity | Accelerometer | `normalize(accel) * 9.81` |
| Linear Acceleration | Accelerometer | `accel - gravity` (near zero when stationary) |
| Rotation Vector | Accel + Magnetometer | Quaternion from gravity and magnetic north |
| Game Rotation Vector | Accel + Gyroscope | Quaternion without magnetometer (no north reference) |
| Step Counter | Accelerometer | Cumulative count based on acceleration patterns |
| Step Detector | Accelerometer | Fires 1.0 when a step pattern is detected |
| Proximity | Direct config | Distance to nearest object in cm |
| Light | Direct config | Ambient light level in lux |

### The Cross-Sensor Consistency Model

This is the key differentiator — the thing that separates this from naive sensor spoofing.

```text
Base sensors (you configure directly):
  Accelerometer -> accelX, accelY, accelZ
  Gyroscope     -> gyroX, gyroY, gyroZ
  Magnetometer  -> magX, magY, magZ

Derived sensors (computed automatically):
  Gravity             = normalize(accel) * 9.81
  Linear Acceleration = accel - gravity
  Rotation Vector     = quaternion_from(accel, mag)
  Game Rotation Vector = quaternion_from(accel, gyro)
```

If an SDK cross-checks "the rotation vector says the phone is tilted 30 degrees but the accelerometer says it's flat" — it won't catch you. Both values are derived from the same source data. The quaternion math is correct. The gravity decomposition is correct. The linear acceleration residual is correct. Everything is internally consistent because everything flows from the same three base vectors.

---

## The Physics You Need to Know

### Accelerometer Orientation

The accelerometer reports total acceleration including gravity. The key values:

| Device Position | accelX | accelY | accelZ | Description |
|---------------|--------|--------|--------|-------------|
| Flat, face up | 0.0 | 0.0 | 9.81 | Gravity pulls straight down through Z |
| Flat, face down | 0.0 | 0.0 | -9.81 | Gravity pulls opposite to Z |
| Portrait, upright | 0.0 | 9.81 | 0.0 | Gravity pulls down through Y |
| Tilted 30 degrees left | 4.9 | 0.0 | 8.5 | Gravity split between X and Z |
| Tilted 30 degrees right | -4.9 | 0.0 | 8.5 | Gravity split opposite X and Z |

The magnitude should always be approximately 9.81 m/s^2 (Earth's gravity), regardless of orientation: `sqrt(x^2 + y^2 + z^2) ≈ 9.81`. If your values violate this — say, (0, 0, 15.0) — that's physically impossible and detectable.

### Gyroscope and Rotation

The gyroscope measures angular velocity — how fast the device is rotating, not its current orientation. When stationary, all gyroscope values should be near zero (with slight noise).

If you're simulating a head tilt (for active liveness), the gyroscope needs a brief non-zero pulse during the transition period:

- **Before tilt:** gyro = (0, 0, 0) — stationary
- **During tilt:** gyro = (0, 0, -0.15) — rotating around Z axis
- **After tilt:** gyro = (0, 0, 0) — stationary at new position

The accelerometer values change between the before and after states (gravity redistributes), and the gyroscope shows the rotation during the transition.

### Jitter: The Reality of Physics

Real sensors are noisy. A real phone sitting on a desk doesn't report (0, 0, 9.81) every time — it reports (0.02, -0.01, 9.83) then (-0.01, 0.03, 9.79) then (0.01, -0.02, 9.82). This noise comes from the MEMS hardware, temperature variations, and electronic interference.

The `jitter` parameter in the sensor config adds Gaussian noise to each reading. A jitter of 0.15 means each axis gets a random offset of +/- 0.15 m/s^2 on each delivery. This turns a suspiciously perfect (0, 0, 9.81) stream into a natural-looking noisy stream that matches real hardware behavior.

---

## Configuration

### The Config File

Create a JSON file at `/sdcard/poc_sensor/config.json`:

```json
{
  "accelX": 0.1,
  "accelY": 9.5,
  "accelZ": 2.5,
  "gyroX": 0.0,
  "gyroY": 0.0,
  "gyroZ": 0.0,
  "magX": 0.0,
  "magY": 25.0,
  "magZ": -45.0,
  "jitter": 0.15,
  "proximity": 5.0,
  "light": 300.0
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `accelX/Y/Z` | float | 0, 0, 9.81 | Accelerometer in m/s^2 |
| `gyroX/Y/Z` | float | 0, 0, 0 | Gyroscope in rad/s |
| `magX/Y/Z` | float | 0, 25, -45 | Magnetometer in microteslas |
| `jitter` | float | 0.15 | Noise amplitude per axis per reading |
| `proximity` | float | 5.0 | Distance to nearest object (cm) |
| `light` | float | 300.0 | Ambient light level (lux) |

### Pre-Built Profiles

The materials kit includes configs for common scenarios:

| Profile | Use Case | Key Values |
|---------|----------|-----------|
| `holding.json` | Person holding phone (selfie) | accel=(0.1, 9.5, 2.5), jitter=0.15 |
| `still.json` | Phone on desk | accel=(0, 0, 9.81), jitter=0.05 |
| `walking.json` | Person walking | accel=(0.5, 8.0, 5.0), higher jitter |
| `tilt-left.json` | Active liveness: tilt left | accel=(3.0, 0, 9.31), gyroZ=-0.15 |
| `tilt-right.json` | Active liveness: tilt right | accel=(-3.0, 0, 9.31), gyroZ=0.15 |
| `nod.json` | Active liveness: nod down | accel=(0, 3.0, 9.31), gyroX=0.15 |

### Pushing Configs

```bash
# For a selfie with natural hand tremor
adb push materials/payloads/sensors/holding.json /sdcard/poc_sensor/config.json

# Switch mid-flow for an active liveness challenge
adb push materials/payloads/sensors/tilt-left.json /sdcard/poc_sensor/config.json
```

Like location configs, sensor configs hot-reload — push a new file and the values change on the next sensor event delivery.

---

## Matching Sensors to Camera Frames

The most critical coordination in any multi-surface bypass is ensuring your sensor data matches your camera data. The rules:

### For Passive Liveness (No Active Challenge)

Use the `holding.json` profile. The camera shows a face with natural micro-movements. The sensors show a phone held in someone's hand with natural tremor. Both tell the same story: a person holding a phone and looking at it.

### For Active Liveness (Head Tilt, Nod, Smile)

This requires coordinated switching:

1. **Camera frames** show the face performing the requested action (tilt left, nod, etc.)
2. **Sensor config** switches to the corresponding motion profile at the same time

Example sequence for "tilt left" challenge:
```bash
# Phase 1: Neutral position (camera shows neutral face, sensors show holding)
adb push holding.json /sdcard/poc_sensor/config.json

# Phase 2: Tilt left (camera shows face tilting, sensors show rotation)
# Wait for the app to request the tilt, then:
adb push tilt-left.json /sdcard/poc_sensor/config.json

# Phase 3: Return to neutral
adb push holding.json /sdcard/poc_sensor/config.json
```

The timing doesn't need to be perfect — the sensor config takes effect within 2 seconds, and most liveness SDKs allow several seconds for the user to complete the action.

### For Static Scenarios (Document Scan, Idle)

Use `still.json`. The phone is stationary — perhaps propped up while the user positions a document. The accelerometer shows pure gravity (0, 0, 9.81), the gyroscope shows zero rotation. Minimal jitter for a stable reading.

---

## Verification

```bash
adb logcat -s SensorInterceptor
# D SensorInterceptor: SENSOR_DELIVERED type=1 values=[0.12, 9.48, 2.53]
# D SensorInterceptor: SENSOR_DELIVERED type=4 values=[0.01, 9.50, 2.49]
```

Type 1 is the accelerometer. Type 4 is the gravity sensor. Notice how the gravity values closely match the accelerometer values (as expected for a stationary device) — the cross-sensor consistency model is working.

### Troubleshooting

**No SENSOR_DELIVERED in logcat** — The app might not register a `SensorEventListener`. Check your recon: did you find `onSensorChanged` in the app's code? If the app doesn't listen for sensors, there's nothing to hook.

**Liveness check fails despite sensors active** — Your sensor values might not match the visual data. If the camera shows a face tilting but sensors show the phone stationary, the SDK will flag the inconsistency. Match your sensor profile to your camera frame sequence.

**Values look wrong for derived sensors** — Check that your base accelerometer magnitude is approximately 9.81. Values that don't sum to Earth's gravity produce impossible derived sensor readings.

---

## What Comes Next

With camera injection (Chapter 7), location spoofing (Chapter 8), and sensor injection (this chapter), you have the complete toolkit for bypassing multi-surface verification systems. Chapter 10 brings them all together in a full engagement — a coordinated operation against a multi-step target that requires all three subsystems working simultaneously.

Complete **Lab 5: Sensor Injection** to practice configuring sensor profiles and matching them to camera frame sequences.
