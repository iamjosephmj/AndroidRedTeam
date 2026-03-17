---
title: "Lab 4: Location Spoofing"
description: "Spoof GPS coordinates to bypass geofencing with mock detection evasion"
---

> **Prerequisites:** Lab 2 (First Injection) complete, Chapter 8 (Location Spoofing) read.
>
> **Estimated time:** 30 minutes.
>
> **Target:** `materials/targets/target-kyc-basic.apk` (package `com.poc.biometric`)

The target application has a LocationActivity that performs a geofence check. The device must appear to be near Times Square, New York City (40.7580, -73.9855) for the location verification step to pass. The app also calls `isFromMockProvider()` to detect GPS spoofing tools. You need to bypass both layers: inject the correct coordinates and defeat mock detection.

This lab exercises the LocationInterceptor subsystem. By the end, you will have extracted geofence coordinates from the decoded APK, built a location config, and passed the geofence check with mock detection evasion confirmed in logcat.

---

## Step 1: Recon -- Find the Geofence Coordinates

If you completed Lab 1, you already have the decoded APK. If not, decode it now:

```bash
cd /Users/josejames/Documents/android-red-team
apktool d materials/targets/target-kyc-basic.apk -o decoded-kyc/
```

Search the decoded smali for geofence coordinates. The app will have hardcoded latitude and longitude values somewhere in its location verification logic:

```bash
grep -rn "latitude\|longitude\|LatLng\|geofence" decoded-kyc/smali*/
```

Look for float or double constants near known coordinate ranges. For US-based targets, latitude values near 40.x and longitude values near -73.x indicate the New York area:

```bash
grep -rn "const.*40\.\|const.*73\." decoded-kyc/smali*/
```

Also check string resources:

```bash
grep -rn "latitude\|longitude" decoded-kyc/res/values/strings.xml
```

You should find references to the Times Square coordinates: latitude `40.7580`, longitude `-73.9855`. Record these -- they are the center of the geofence you need to land inside.

Also confirm the mock detection surface:

```bash
grep -rn "isFromMockProvider\|isMock" decoded-kyc/smali*/
```

This should return at least one hit in the LocationActivity. The app checks whether the delivered location came from a mock provider and rejects it if so. The patch-tool handles this at the smali level.

---

## Step 2: Build the Location Config

Create a JSON config file with the extracted geofence coordinates:

```bash
cat > /tmp/geofence_config.json << 'EOF'
{
  "latitude": 40.7580,
  "longitude": -73.9855,
  "altitude": 5.0,
  "accuracy": 8.0,
  "speed": 0.0,
  "bearing": 0.0
}
EOF
```

Field rationale:

| Field | Value | Why |
|-------|-------|-----|
| `latitude` | 40.7580 | Center of the target geofence (Times Square) |
| `longitude` | -73.9855 | Center of the target geofence (Times Square) |
| `altitude` | 5.0 | Reasonable street-level altitude in meters |
| `accuracy` | 8.0 | Tight accuracy -- typical urban GPS fix (jittered +/-2m per delivery) |
| `speed` | 0.0 | Stationary -- person standing still for verification |
| `bearing` | 0.0 | Irrelevant when stationary |

---

## Step 3: Patch the APK

Patch the target APK. Watch the output for location-related hook confirmations:

```bash
cd /Users/josejames/Documents/android-red-team
java -jar patch-tool.jar materials/targets/target-kyc-basic.apk \
  --out patched-location.apk \
  --work-dir ./work-location 2>&1 | tee patch_location_output.txt
```

In the patch output, verify these entries appear:

- **`onLocationResult`** -- confirms the FusedLocationProvider callback hook was injected
- **`isFromMockProvider`** -- confirms the mock detection call site was patched to return `false`

If you see `[!] Not found` for either of these, re-check that you are patching the correct APK. The `materials/targets/target-kyc-basic.apk` should have both surfaces.

---

## Step 4: Install and Grant Permissions

Install the patched APK and grant all required permissions up front so no permission dialogs interrupt the flow:

```bash
adb uninstall com.poc.biometric 2>/dev/null
adb install -r patched-location.apk

adb shell pm grant com.poc.biometric android.permission.CAMERA
adb shell pm grant com.poc.biometric android.permission.ACCESS_FINE_LOCATION
adb shell pm grant com.poc.biometric android.permission.ACCESS_COARSE_LOCATION
adb shell pm grant com.poc.biometric android.permission.READ_EXTERNAL_STORAGE
adb shell pm grant com.poc.biometric android.permission.WRITE_EXTERNAL_STORAGE
adb shell appops set com.poc.biometric MANAGE_EXTERNAL_STORAGE allow
```

The `ACCESS_FINE_LOCATION` grant is critical for this lab. Without it, the app cannot request GPS updates at all, and the location hook will never fire.

---

## Step 5: Push the Location Config

Create the payload directory on the device and push your config:

```bash
adb shell mkdir -p /sdcard/poc_location/
adb push /tmp/geofence_config.json /sdcard/poc_location/config.json
```

The LocationInterceptor auto-enables when it finds a JSON file in `/sdcard/poc_location/`. No app restart is required if the app is already running -- the config hot-reloads every 2 seconds.

---

## Step 6: Launch and Observe

Start logcat monitoring in one terminal, then launch the app in another:

**Terminal 1 -- Monitor:**

```bash
adb logcat -c
adb logcat -s LocationInterceptor
```

**Terminal 2 -- Launch:**

```bash
adb shell am start -n com.poc.biometric/com.poc.biometric.ui.LauncherActivity
```

Navigate to the location verification step in the app. Once the app queries location, you should see output in Terminal 1 confirming injection is active.

---

## Step 7: Verify via Logcat

Watch the logcat output for these key events:

```text
D LocationInterceptor: Auto-enabled — config found at /sdcard/poc_location/config.json
D LocationInterceptor: buildFakeLocation lat=40.7580 lng=-73.9855 alt=5.0 acc=8.0
D LocationInterceptor: LOCATION_DELIVERED lat=40.758002 lng=-73.985498 acc=9.2
D LocationInterceptor: LOCATION_DELIVERED lat=40.757998 lng=-73.985503 acc=7.8
```

What to look for:

| Log Entry | Meaning |
|-----------|---------|
| `Auto-enabled` | LocationInterceptor found your config and armed itself |
| `buildFakeLocation` | A fake Location object was constructed from your config |
| `LOCATION_DELIVERED` | The fake Location was delivered to the app's callback |

Notice the slight variation in coordinates between deliveries (40.758002 vs 40.757998). That is the accuracy jitter simulating realistic GPS drift. The app's geofence check passes because all delivered coordinates fall within the acceptable radius of Times Square.

The mock detection bypass is silent -- there is no separate log entry. The `isFromMockProvider()` call in the app's code has been rewritten at the smali level to return `false`. It never executes the real check.

---

## Step 8: Capture Evidence

Take a screenshot of the location verification passing:

```bash
adb exec-out screencap -p > geofence_pass.png
```

Dump the delivery log:

```bash
adb logcat -d -s LocationInterceptor > location_log.txt
```

Save a copy of your config:

```bash
cp /tmp/geofence_config.json ./geofence_config.json
```

---

## Understanding the Two-Layer Bypass

This lab demonstrates a two-layer bypass that most GPS spoofing tools fail to achieve:

**Layer 1: Location Injection.** The LocationInterceptor hooks every path Android uses to deliver GPS data -- `onLocationResult`, `onLocationChanged`, `getLastLocation`, `getCurrentLocation`. When the app asks "where is this phone?", it receives your coordinates. The fake Location object is constructed fresh on every delivery with current timestamps, realistic accuracy jitter, and proper provider metadata. It is indistinguishable from a real GPS fix at the API level.

**Layer 2: Mock Detection Evasion.** Standard GPS spoofing apps set a mock location provider through Developer Options. Android marks these locations with `isFromMockProvider() = true`, which apps can check. The patch-tool takes a different approach: it rewrites the app's own bytecode so that every call to `isFromMockProvider()` and `isMock()` returns `false`. The app cannot detect mocking because the detection code itself has been modified. This is fundamentally different from system-level spoofing -- the modification is inside the target APK, invisible to the app's runtime logic.

Together, these two layers mean the app receives coordinates you control and has no mechanism to determine they are synthetic.

---

## Self-Check Script

Run this script to verify your lab is complete:

```bash
#!/bin/bash
echo "=== Lab 4: Location Spoofing — Self-Check ==="
PASS=0
FAIL=0

# Check config file exists
if [ -f geofence_config.json ]; then
  echo "[PASS] geofence_config.json exists"
  ((PASS++))
else
  echo "[FAIL] geofence_config.json not found"
  ((FAIL++))
fi

# Check config has correct coordinates
if grep -q "40.7580" geofence_config.json 2>/dev/null && \
   grep -q "\-73.9855" geofence_config.json 2>/dev/null; then
  echo "[PASS] Config contains Times Square coordinates"
  ((PASS++))
else
  echo "[FAIL] Config missing expected coordinates (40.7580, -73.9855)"
  ((FAIL++))
fi

# Check screenshot exists
if [ -f geofence_pass.png ]; then
  echo "[PASS] geofence_pass.png exists"
  ((PASS++))
else
  echo "[FAIL] geofence_pass.png not found"
  ((FAIL++))
fi

# Check delivery log exists and has location events
if [ -f location_log.txt ]; then
  LOC_COUNT=$(grep -c "LOCATION_DELIVERED" location_log.txt 2>/dev/null || echo 0)
  if [ "$LOC_COUNT" -gt 0 ]; then
    echo "[PASS] location_log.txt has $LOC_COUNT LOCATION_DELIVERED events"
    ((PASS++))
  else
    echo "[FAIL] location_log.txt exists but contains no LOCATION_DELIVERED events"
    ((FAIL++))
  fi
else
  echo "[FAIL] location_log.txt not found"
  ((FAIL++))
fi

# Check for auto-enable confirmation
if grep -q "Auto-enabled\|buildFakeLocation" location_log.txt 2>/dev/null; then
  echo "[PASS] LocationInterceptor auto-enabled confirmed"
  ((PASS++))
else
  echo "[FAIL] No auto-enable confirmation in location_log.txt"
  ((FAIL++))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed out of $((PASS + FAIL)) checks"
[ "$FAIL" -eq 0 ] && echo "Lab 4 COMPLETE." || echo "Lab 4 INCOMPLETE — review failed checks."
```

---

## Troubleshooting

**No LOCATION_DELIVERED events in logcat.** The app may not have reached the location verification step yet. Navigate through the app UI until you reach the screen that checks your location. The hook only fires when the app actually requests a location update.

**Coordinates delivered but geofence still fails.** Double-check the coordinates you extracted during recon. If the geofence has a tight radius (e.g., 50 meters), even small errors in the latitude or longitude will cause rejection. Ensure your config matches the extracted values exactly.

**"Mock location detected" message despite patching.** Verify that `isFromMockProvider` appeared in the patch output. If it shows `[!] Not found`, the app may use a non-standard mock detection method (proprietary SDK). Check the recon for third-party anti-spoofing libraries.

**Permission denied when pushing config.** Run `adb shell appops set com.poc.biometric MANAGE_EXTERNAL_STORAGE allow` and ensure the `/sdcard/poc_location/` directory exists.

---

## Deliverables

| File | Description |
|------|-------------|
| `geofence_config.json` | Location config with extracted geofence coordinates |
| `geofence_pass.png` | Screenshot of location verification passing |
| `location_log.txt` | Logcat output showing LOCATION_DELIVERED events |

---

## Success Criteria

- [ ] Geofence coordinates extracted from decoded APK via grep
- [ ] Location config JSON built with correct latitude, longitude, altitude, and accuracy
- [ ] Patch output confirms `onLocationResult` and `isFromMockProvider` hooks
- [ ] `ACCESS_FINE_LOCATION` permission granted before launch
- [ ] LocationInterceptor auto-enabled (confirmed in logcat)
- [ ] At least one `LOCATION_DELIVERED` event in logcat with Times Square coordinates
- [ ] Geofence check passes in the app (screenshot captured)
- [ ] All three deliverables saved
