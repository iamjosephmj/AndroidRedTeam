#!/bin/bash
# APK Recon Script — decode and scan a target APK for hookable surfaces.
#
# Usage: ./recon.sh <path-to-apk> [output-dir]
#   path-to-apk: the APK to analyze
#   output-dir: where to decode (default: ./decoded)

set -euo pipefail

APK="${1:?Usage: ./recon.sh <path-to-apk> [output-dir]}"
OUTPUT="${2:-./decoded}"

command -v apktool >/dev/null 2>&1 || { echo "ERROR: apktool not found"; exit 1; }

echo "=== APK Recon ==="
echo "Target: $APK"
echo "Output: $OUTPUT"
echo ""

# Decode
echo "--- Decoding ---"
apktool d "$APK" -o "$OUTPUT" -f 2>&1 | grep -E "^I:|^W:" || true
echo ""

# Manifest analysis
echo "--- Manifest ---"
echo "Application class: $(grep '<application' "$OUTPUT/AndroidManifest.xml" | grep -o 'android:name="[^"]*' | head -1 || echo 'not set')"
echo ""
echo "Permissions:"
grep 'uses-permission' "$OUTPUT/AndroidManifest.xml" | sed 's/.*android:name="/  /' | sed 's/".*//' || echo "  none found"
echo ""

# Camera API
echo "--- Camera API ---"
echo "CameraX (ImageAnalysis.Analyzer):"
grep -rl 'ImageAnalysis\$Analyzer' "$OUTPUT"/smali*/ 2>/dev/null | sed 's/^/  /' || echo "  not found"
echo "CameraX (OnImageCapturedCallback):"
grep -rl 'OnImageCapturedCallback' "$OUTPUT"/smali*/ 2>/dev/null | sed 's/^/  /' || echo "  not found"
echo "Camera2 (OnImageAvailableListener):"
grep -rl 'OnImageAvailableListener' "$OUTPUT"/smali*/ 2>/dev/null | sed 's/^/  /' || echo "  not found"
echo "Camera2 (CameraCaptureSession):"
grep -rl 'CameraCaptureSession' "$OUTPUT"/smali*/ 2>/dev/null | sed 's/^/  /' || echo "  not found"
echo ""

# Location
echo "--- Location ---"
echo "onLocationResult:"
grep -rn 'onLocationResult' "$OUTPUT"/smali*/ 2>/dev/null | head -5 | sed 's/^/  /' || echo "  not found"
echo "onLocationChanged:"
grep -rn 'onLocationChanged' "$OUTPUT"/smali*/ 2>/dev/null | head -5 | sed 's/^/  /' || echo "  not found"
echo "Mock detection:"
grep -rEn 'isFromMockProvider|isMock' "$OUTPUT"/smali*/ 2>/dev/null | head -5 | sed 's/^/  /' || echo "  not found"
echo ""

# Sensors
echo "--- Sensors ---"
echo "onSensorChanged:"
grep -rn 'onSensorChanged' "$OUTPUT"/smali*/ 2>/dev/null | head -5 | sed 's/^/  /' || echo "  not found"
echo "Sensor types:"
grep -rEn 'TYPE_ACCELEROMETER|TYPE_GYROSCOPE|TYPE_MAGNETIC' "$OUTPUT"/smali*/ 2>/dev/null | head -5 | sed 's/^/  /' || echo "  not found"
echo ""

# Third-party SDKs
echo "--- Third-party SDKs ---"
echo "ML Kit: $(grep -rl 'com/google/mlkit' "$OUTPUT"/smali*/ 2>/dev/null | wc -l | tr -d ' ') files"
echo "FaceTec: $(grep -rEl 'facetec|FaceTecSDK' "$OUTPUT"/smali*/ 2>/dev/null | wc -l | tr -d ' ') files"
echo "iProov: $(grep -rEl 'iproov|IProov' "$OUTPUT"/smali*/ 2>/dev/null | wc -l | tr -d ' ') files"
echo "Jumio: $(grep -rEl 'jumio|Jumio' "$OUTPUT"/smali*/ 2>/dev/null | wc -l | tr -d ' ') files"
echo "Onfido: $(grep -rEl 'onfido|Onfido' "$OUTPUT"/smali*/ 2>/dev/null | wc -l | tr -d ' ') files"
echo ""
echo "=== Recon Complete ==="
