---
title: "Location Spoofing"
description: "Feeding fake GPS coordinates to bypass geofencing with mock detection evasion"
---

> **Ethics Note:** GPS spoofing can bypass location-gated services. Only spoof coordinates against applications you are authorized to test. Use well-known public locations (Times Square, Googleplex) for testing, not coordinates that could be linked to real individuals.

Some apps don't just check your face. They check where you are.

Geofencing has become a standard verification layer in banking onboarding, KYC flows, insurance claims processing, and identity verification. The logic is straightforward: if you're opening an account with a bank that only operates in the US, you should be physically located in the US. If you're verifying your identity for a government portal, you should be in the country. If you're claiming to be at a specific branch location, your GPS should agree.

The implementation varies. Some apps show a map and ask you to confirm your location. Some check silently in the background and block you if the coordinates fall outside the service area. Some hit a server-side geofence API and reject the onboarding before you even reach the camera screen. A few advanced implementations monitor your location continuously — "stay in the area for 30 seconds" — to prevent simple one-shot spoofing.

And almost all of them have a defense layer: mock location detection. Android provides APIs that let apps check whether a location came from a spoofing tool. Most off-the-shelf GPS spoofing apps get caught here.

The location hooks in this toolkit intercept every path Android uses to deliver GPS coordinates — every callback, every direct query, every mock detection check. The app asks the system "where is this phone?" and gets your coordinates. Then it asks "is this location real?" and gets "yes." Both layers are handled. Both are transparent.

---

## The Interception Points

Android delivers location through two primary APIs. Both are hooked.

### FusedLocationProviderClient (Modern API)

Google Play Services' FusedLocationProvider is the recommended API. It fuses GPS, Wi-Fi, cell tower, and sensor data for the best possible location estimate.

```text
FusedLocationProviderClient
  -> LocationCallback.onLocationResult(LocationResult)    [HOOKED]
  -> getLastLocation() -> Task<Location>                  [HOOKED]
  -> getCurrentLocation() -> Task<Location>               [HOOKED]
```

### LocationManager (Legacy API)

The original Android location API. Still used by some apps, especially older ones or those avoiding Google Play Services dependencies.

```text
LocationManager
  -> LocationListener.onLocationChanged(Location)         [HOOKED]
  -> getLastKnownLocation() -> Location                   [HOOKED]
```

At each hook point, the real `Location` object is discarded. A fake Location is constructed from your config and returned in its place. The app's code processes it like any other location update.

### What's Inside the Fake Location

Every field is populated to match what a real GPS fix would contain:

| Field | Source | Notes |
|-------|--------|-------|
| Latitude / Longitude | Your config | The coordinates that matter |
| Altitude | Your config (default 0m) | Some apps check this |
| Accuracy | Your config (default 10m) | Jittered +/-2m per delivery for realism |
| Speed / Bearing | Your config (default 0) | Non-zero for walking routes |
| Provider | Hardcoded `"fused"` | Matches FusedLocationProvider output |
| Timestamp | `System.currentTimeMillis()` | Always current, never stale |
| Elapsed realtime nanos | `SystemClock.elapsedRealtimeNanos()` | Matches system clock |

The timestamp fields matter more than you'd think. Some apps check whether the location is "fresh" — if you returned a static, pre-built Location object with a stale timestamp, the app would notice. The fake Location is constructed fresh on every delivery, with the current system time.

---

## The Mock Detection Bypass

This is where most amateur GPS spoofing tools fail. Android provides three ways for apps to detect mock locations. All three are neutralized:

| Check | API Level | How It's Bypassed |
|-------|-----------|-------------------|
| `Location.isFromMockProvider()` | API 18-30 | Patched at call site to return `false` |
| `Location.isMock()` | API 31+ | Patched at call site to return `false` |
| `Settings.Secure.getString("mock_location")` | All | Intercepted to return `"0"` |

These aren't runtime intercepts — they're smali patches applied during the APK patching phase. Every call to `isFromMockProvider()` or `isMock()` in the app's code is rewritten to return `false`. The app literally cannot check for mocking because the check itself has been modified.

This is fundamentally different from mock location apps that work through Developer Options. Those tools set the mock provider at the system level, which the app can detect. The patch-tool modifies the app's own code so its detection logic is disabled. The mock detection methods still exist in the Android framework — the app just never gets a truthful answer from them.

---

## How the Hook Works

Understanding the hook mechanism helps when things don't work as expected.

### The FusedLocationProvider Hook

The most common hook target is `onLocationResult(LocationResult)`. Here's what happens:

1. The app registers a `LocationCallback` with `FusedLocationProviderClient.requestLocationUpdates()`
2. When the OS delivers a GPS fix, it calls `callback.onLocationResult(locationResult)`
3. The hook fires at the method entry point — before the app's code processes the result
4. The hook extracts the `LocationResult`, discards the real `Location` objects inside it
5. It constructs a new `Location` from your config JSON (with fresh timestamps and jitter applied)
6. It wraps the fake Location in a new `LocationResult`
7. The original method body runs with the replaced parameter

The app's code calls `locationResult.getLastLocation()` or `locationResult.getLocations()` and gets your coordinates. Every downstream processing step — geofence checks, map display, distance calculations — operates on your data.

### The Direct Query Hook

Some apps don't use callbacks. They call `getLastLocation()` or `getCurrentLocation()` and wait for the result. These are one-shot queries rather than continuous streams.

The hook intercepts these methods differently — it wraps the return value. When the `Task<Location>` resolves, the hook replaces the Location in the task result with a fake one. The app's `.addOnSuccessListener()` receives your coordinates.

### Why This Works Better Than Mock Providers

Standard GPS spoofing tools work by registering a mock location provider through Android's Developer Options. This has two problems:

1. **Detection:** The `Location` object has its `isFromMockProvider` flag set to `true`, which apps can check
2. **Scope:** Mock providers affect all apps on the device, not just the target

The patch-tool approach avoids both problems. The hook is inside the target app's own bytecode — it doesn't touch the system's location infrastructure. Other apps on the device receive real GPS data. And the mock detection flag is never set because the fake Location is constructed from scratch, not delivered through the mock provider API.

---

## Configuration

### The Config File

Create a JSON file at `/sdcard/poc_location/config.json`:

```json
{
  "latitude": 40.7580,
  "longitude": -73.9855,
  "altitude": 5.0,
  "accuracy": 8.0,
  "speed": 0.0,
  "bearing": 0.0
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `latitude` | float | *required* | Decimal degrees, WGS84 |
| `longitude` | float | *required* | Decimal degrees, WGS84 |
| `altitude` | float | 0.0 | Meters above sea level |
| `accuracy` | float | 10.0 | Horizontal accuracy in meters |
| `speed` | float | 0.0 | Meters per second |
| `bearing` | float | 0.0 | Degrees (0-360, 0 = North) |

### Pushing the Config

```bash
adb push location_config.json /sdcard/poc_location/config.json
```

The LocationInterceptor auto-detects the config during app startup. If `/sdcard/poc_location/` exists and contains a JSON file, location injection arms itself. If the directory is empty or absent, location injection stays dormant.

### Hot-Reloading

You can update the config while the app is running. The interceptor re-reads the config file periodically (every 2 seconds). Push a new config and the coordinates change on the next location delivery — no app restart required.

```bash
# Scenario: app is running, currently spoofing Times Square
# Need to move to a different location for the next step
echo '{"latitude": 37.4220, "longitude": -122.0841, "altitude": 10.0, "accuracy": 12.0}' \
  > /tmp/new_location.json
adb push /tmp/new_location.json /sdcard/poc_location/config.json
# Next location callback delivers Googleplex coordinates
```

---

## Extracting Geofence Coordinates

During recon, you need to find the target coordinates — the geofence center that the app checks against. These coordinates might be:

### Hardcoded in the APK

Some apps embed geofence coordinates directly in their code or resource files:

```bash
# Search smali for hardcoded coordinate values
grep -rn "latitude\|longitude\|LatLng\|geofence" decoded/smali*/

# Search string resources
grep -rn "latitude\|longitude" decoded/res/values/strings.xml

# Search for coordinate-like float literals (look for values near known regions)
grep -rn "const.*37\.\|const.*40\.\|const.*51\." decoded/smali*/
```

### In Network Responses

If coordinates aren't hardcoded, the app may fetch them from a backend API. You can capture these through:

```bash
# Logcat network activity (if the app logs it)
adb logcat | grep -i "geofence\|location\|coordinate"

# For apps with cleartext HTTP (rare in modern apps)
# Use mitmproxy or Charles Proxy with a trusted CA certificate
```

### Common Test Coordinates

The materials kit includes ready-to-use configs for well-known locations:

| Location | Latitude | Longitude | File |
|----------|----------|-----------|------|
| Times Square, NYC | 40.7580 | -73.9855 | `times-square.json` |
| Googleplex, Mountain View | 37.4220 | -122.0841 | `googleplex.json` |
| City of London | 51.5074 | -0.1278 | `london-city.json` |
| Shibuya, Tokyo | 35.6595 | 139.7004 | `shibuya.json` |

---

## Walking Routes and Continuous Monitoring

The materials kit includes a ready-made walking route config at [`materials/payloads/locations/walking-route.json`](https://github.com/iamjosephmj/AndroidRedTeam/blob/main/materials/payloads/locations/walking-route.json). Use it as-is or as a starting point for your own routes.

Some apps don't just check your location once — they monitor it over time. "Stay in the area for 30 seconds" or "walk to the branch entrance." A single static coordinate won't satisfy a continuous monitoring check because the location never changes, and real GPS has natural drift.

### Natural Drift

The accuracy jitter built into the LocationInterceptor helps here. Each delivery adds +/- 2 meters of random offset to the configured coordinates, simulating the natural drift that real GPS exhibits. A perfectly stable coordinate (the same to 6 decimal places on every query) is suspicious. The jitter makes the stream look like real GPS.

### Waypoint Routes

For apps that expect movement, configure a walking route — a sequence of coordinates with delays between them:

```json
{
  "waypoints": [
    { "latitude": 40.7580, "longitude": -73.9855, "altitude": 5.0, "accuracy": 8.0, "delayMs": 0 },
    { "latitude": 40.7590, "longitude": -73.9850, "altitude": 5.0, "accuracy": 10.0, "delayMs": 5000 },
    { "latitude": 40.7600, "longitude": -73.9845, "altitude": 5.0, "accuracy": 9.0, "delayMs": 10000 },
    { "latitude": 40.7610, "longitude": -73.9840, "altitude": 5.0, "accuracy": 8.0, "delayMs": 15000 }
  ]
}
```

The LocationInterceptor advances through waypoints based on the delay values, delivering each coordinate at the scheduled time.

---

## Edge Cases

### The International Date Line

Coordinates near the International Date Line (longitude ~180 / -180) can cause issues with naive geofence implementations. If the geofence spans the date line, coordinates at +179.9 and -179.9 are geographically adjacent but numerically distant. Most modern geofence libraries handle this correctly, but it's worth testing if your target operates in the Pacific.

### Null Island

Coordinates (0.0, 0.0) place you in the Gulf of Guinea — a location known as "Null Island." Some apps reject these coordinates as a default/error value. Always configure explicit coordinates rather than relying on defaults.

### Altitude

Most apps ignore altitude for geofencing. But some specialized applications (construction site verification, mining) check altitude. If your target fails despite correct lat/lng, check whether it validates altitude. Reasonable values: 0-100m for urban areas, higher for elevated terrain.

---

## Worked Example: Bypassing a Banking Geofence

Let's walk through a complete location spoofing scenario against the practice target.

**Scenario:** The practice app (`com.poc.biometric`) has a LocationActivity that checks if the device is near Times Square, NYC. It uses FusedLocationProviderClient and checks `isFromMockProvider()`.

**Step 1: Recon confirmed the surfaces**
```text
Location (onLocationResult): found in LocationActivity
Mock detection (isFromMockProvider): found in LocationActivity
```

**Step 2: Prepare the config**
```bash
echo '{"latitude": 40.7580, "longitude": -73.9855, "altitude": 5.0, "accuracy": 8.0}' \
  > times_square.json
adb push times_square.json /sdcard/poc_location/config.json
```

**Step 3: Launch the app and navigate to the location step**
```bash
adb shell am start -n com.poc.biometric/com.poc.biometric.ui.LauncherActivity
```

**Step 4: Verify**
```bash
adb logcat -s LocationInterceptor
# D LocationInterceptor: LOCATION_DELIVERED lat=40.758002 lng=-73.985498 acc=9.2
# D LocationInterceptor: LOCATION_DELIVERED lat=40.757998 lng=-73.985503 acc=7.8
```

Note the slight variation in coordinates — that's the accuracy jitter creating realistic drift. The app's geofence check passes because the coordinates are within the acceptable radius of Times Square.

---

## Verification

After pushing your config and launching the patched app:

### Logcat Confirmation

```bash
adb logcat -s LocationInterceptor
# Look for: LOCATION_DELIVERED lat=40.758 lng=-73.985
```

Each delivery logs the coordinates, confirming the hook is active and delivering your config.

### In-App Verification

If the app displays a map or coordinates, you should see your configured location. If it shows a "location verified" message, the geofence check passed.

### Troubleshooting

**No LOCATION_DELIVERED in logcat** — The app might not be querying location yet. Some apps only check location on a specific screen. Navigate to the geofence step.

**Coordinates delivered but geofence fails** — Your coordinates might be outside the expected geofence. Re-check the target coordinates from recon.

**"Mock location detected" despite patches** — Check the patch output for `isFromMockProvider` and `isMock` entries. If they show `[!] Not found`, the app might use a non-standard mock detection method. Check for proprietary anti-spoofing SDKs.

---

## What Comes Next

Location spoofing handles the "where" question. But some verification flows also ask "how is the device moving?" — correlating camera data with physical motion from accelerometers and gyroscopes. Chapter 9 covers sensor injection: replacing motion data with physics-consistent synthetic readings that match your camera frames. Together, camera injection, location spoofing, and sensor injection form the complete toolkit for multi-surface verification bypass.

Complete **Lab 4: Location Spoofing** to practice geofence bypass against the practice target.
