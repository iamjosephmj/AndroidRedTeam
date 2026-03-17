#!/bin/bash
# Generate solid-color test frames for pipeline verification.
# These frames won't pass face detection — they're for confirming
# the injection pipeline works before you create real payloads.
#
# Usage: ./generate-test-frames.sh [output_dir] [count]
#   output_dir: directory for PNGs (default: ./test_frames)
#   count: number of frames to generate (default: 30)
#
# Requires: ffmpeg

set -euo pipefail

OUTPUT_DIR="${1:-./test_frames}"
COUNT="${2:-30}"

command -v ffmpeg >/dev/null 2>&1 || { echo "ERROR: ffmpeg not found. Install with: brew install ffmpeg (macOS) or sudo apt install ffmpeg (Linux)"; exit 1; }

mkdir -p "$OUTPUT_DIR"

echo "Generating $COUNT test frames in $OUTPUT_DIR..."
for i in $(seq -w 1 "$COUNT"); do
  ffmpeg -y -f lavfi -i "color=c=gray:size=640x480:d=0.1" -frames:v 1 "${OUTPUT_DIR}/${i}.png" 2>/dev/null
done

echo "Done. Generated $COUNT frames:"
ls -la "$OUTPUT_DIR"/*.png | wc -l
echo "Push to device with: adb push $OUTPUT_DIR/ /sdcard/poc_frames/test/"
