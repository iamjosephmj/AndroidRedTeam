# Frame Payloads

Camera frame payloads are PNG images that replace the live camera feed during injection. Due to privacy constraints, face images are not distributed — you must generate your own.

## Directory Structure

The toolkit expects frames organized in subdirectories under `/sdcard/poc_frames/`:

```
/sdcard/poc_frames/
  face_neutral/    <- neutral expression face frames
    001.png
    002.png
    ...
  face_smiling/    <- smiling expression (for smile liveness)
  id_card/         <- ID card/document images
  test/            <- solid-color test frames
```

## Generating Face Frames from Video

Record a short selfie video (5-10 seconds, front camera), then extract frames:

```bash
# Extract at 15 fps, scale to 640x480
ffmpeg -i selfie.mp4 -vf "fps=15,scale=640:480" face_neutral/%03d.png

# For a specific expression sequence
ffmpeg -i smiling.mp4 -vf "fps=15,scale=640:480" face_smiling/%03d.png
```

## Generating Test Frames

For pipeline verification (won't pass face detection):

```bash
./generate-test-frames.sh test_frames 30
adb push test_frames/ /sdcard/poc_frames/test/
```

## Frame Requirements

- Format: PNG
- Resolution: 640x480 (the toolkit rescales, but this is the native resolution)
- Naming: sequential numbers (001.png, 002.png, etc.)
- Face frames: face should fill ~60% of the frame, centered
- ID card frames: card should fill ~80% of the frame, well-lit, no glare

## Pushing to Device

```bash
adb push face_neutral/ /sdcard/poc_frames/face_neutral/
adb push id_card/ /sdcard/poc_frames/id_card/
```

The injection subsystem auto-detects PNGs in these directories and begins frame cycling immediately.
