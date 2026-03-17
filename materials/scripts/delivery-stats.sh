#!/bin/bash
# Delivery Statistics — extract injection counts from a logcat capture.
#
# Usage: ./delivery-stats.sh <logfile>
#   logfile: output from `adb logcat -s FrameInterceptor,LocationInterceptor,SensorInterceptor`

set -euo pipefail

LOGFILE="${1:?Usage: ./delivery-stats.sh <logfile>}"

[ -f "$LOGFILE" ] || { echo "ERROR: $LOGFILE not found"; exit 1; }

echo "=== Delivery Statistics ==="
echo "Source: $LOGFILE"
echo ""

FRAMES_D=$(grep -c 'FRAME_DELIVERED' "$LOGFILE" 2>/dev/null || echo 0)
FRAMES_C=$(grep -c 'FRAME_CONSUMED' "$LOGFILE" 2>/dev/null || echo 0)
LOCS=$(grep -c 'LOCATION_DELIVERED' "$LOGFILE" 2>/dev/null || echo 0)
SENSORS=$(grep -c 'SENSOR_DELIVERED' "$LOGFILE" 2>/dev/null || echo 0)

echo "Frames delivered:   $FRAMES_D"
echo "Frames consumed:    $FRAMES_C"
echo "Locations delivered: $LOCS"
echo "Sensor events:      $SENSORS"
echo ""

if [ "$FRAMES_D" -gt 0 ]; then
  RATE=$(( FRAMES_C * 100 / FRAMES_D ))
  echo "Frame accept rate:  ${RATE}%"
else
  echo "Frame accept rate:  N/A (no frames delivered)"
fi

echo ""
echo "--- Timeline (first/last events) ---"
echo "First frame:    $(grep 'FRAME_DELIVERED' "$LOGFILE" 2>/dev/null | head -1 | cut -d' ' -f1-2 || echo 'none')"
echo "Last frame:     $(grep 'FRAME_DELIVERED' "$LOGFILE" 2>/dev/null | tail -1 | cut -d' ' -f1-2 || echo 'none')"
echo "First location: $(grep 'LOCATION_DELIVERED' "$LOGFILE" 2>/dev/null | head -1 | cut -d' ' -f1-2 || echo 'none')"
echo "First sensor:   $(grep 'SENSOR_DELIVERED' "$LOGFILE" 2>/dev/null | head -1 | cut -d' ' -f1-2 || echo 'none')"
