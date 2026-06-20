# LTX Desktop Storyboard Production Workflow

Workflow for turning a storyboard XLSX, timestamp CSV, voice-over, and
pre-generated scene images into a narrated 1080p video with local LTX Desktop
models.

The current Linux production path assumes scene images already exist in
`Resources/output_scenes`. It intentionally skips Z-Image-Turbo still-image
generation and skips Persona Story handling when the XLSX does not include that
asset plan.

## Scene Types

The first XLSX worksheet is used. Scene 1 starts on row 2.

| Column | Meaning |
|---|---|
| C | Visual / still-image prompt |
| D | Motion prompt or Ken Burn instruction |
| E | Scene type |

Supported scene types:

- `Motion`: use existing `output_scenes/scene_N.png`, then LTX image-to-video.
  Final clip is silent. In the YouTube final, only these clips are slowed to
  0.6x before trimming to the timestamp frame count.
- `Still Image + Ken Burn`: use existing `output_scenes/scene_N.png`, then
  create a silent zoom clip with FFmpeg.
- `Avatar`: cut matching voice-over audio and generate a talking avatar.
- `Avatar/Split-screen`: generate a talking avatar as `scene_N_1.mp4`, create a
  silent Ken Burn visual from the already supplied right-side image
  `output_scenes/scene_N.png` as `scene_N_2.mp4`, then combine them as
  `scene_N.mp4`.
- `Persona Story`: skip for this production variant unless the XLSX and
  resources explicitly provide Persona Story assets and scene rules.

Rows without a visual prompt do not trigger image generation. The image source
of truth is `Resources/output_scenes/scene_N.png`, including
`Avatar/Split-screen` right-side visuals.

## Production Stages

1. Copy existing `Resources/output_scenes/scene_N.png` files to
   `production_output/images`. Do not generate Z-Image-Turbo images.
2. Generate `Motion` clips with LTX 2.3 Fast and remove generated audio.
3. Generate silent Ken Burn clips with FFmpeg:

   ```powershell
   ffmpeg -loop 1 -i input.png -vf "scale=8000:-1,zoompan=z='zoom+0.001':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=150:s=1920x1080,format=yuv420p" -an -c:v h264_nvenc -t 5 output.mp4
   ```

4. Cut voice-over by timestamp and generate Avatar clips. For lipsync
   reliability, the avatar audio sent to LTX is prepared with a 1 second silent
   lead-in, then boosted with `ffmpeg -i input.mp3 -filter:a "volume=20dB"
   -q:a 0 output.mp3`. Avatar generation is at least 6 seconds, then the first
   1 second is trimmed from the generated video before it is saved as the final
   avatar clip. The default avatar prompt for this workflow is:

   ```text
   the man speaking directly to the camera, stable camera.
   ```

5. Build Avatar/Split-screen clips, keeping only avatar audio. The right side is
   the pre-generated `scene_N.png` visual turned into `scene_N_2.mp4`; do not
   look for a separate split-screen image name.
6. Validate all source avatar clips with `check-lipsync.py`.
7. Regenerate failed avatar clips and rebuild affected split-screens.
8. Assemble the final video using absolute 24 fps frame boundaries. For the
   YouTube 1080p final, slow `Motion` scenes to 0.6x and then trim each scene to
   its exact timestamp-derived frame count.

## Requirements

- Linux for the RTX production path, or Windows/PowerShell for the legacy path
- LTX Desktop installed in `C:\Program Files\LTX Desktop`
- LTX Desktop opened once so its bundled Python exists
- Downloaded LTX 2.3 distilled models
- NVIDIA GPU supported by LTX Desktop
- For lipsync validation: Python 3.10+ with:

  ```powershell
  pip install opencv-python scipy numpy
  ```

- FFmpeg available as `ffmpeg` in PATH for the lipsync checker

The Linux generation scripts use the local LTX backend and system FFmpeg. The
Windows PowerShell workflow uses the bundled Python and FFmpeg from LTX Desktop.

## Configuration

```powershell
Copy-Item .\config.example.json .\config.json
```

Update all input paths and the desired scene range.

## Run

For the Linux RTX path, place these files under `/root/Resources`:

```text
Resources/
  storyboard_elias_yoder.xlsx
  time_stamp.csv
  voice_over.mp3
  avatar.png
  Prompt_for_avatar.txt
  output_scenes/
    scene_1.png
    scene_2.png
    ...
```

Generate or resume production media:

```bash
python3 ltx_linux_workflow.py \
  --resources /root/Resources \
  --output-dir /root/Resources/production_output
```

Existing files are skipped. Add `--force` only when intentionally regenerating
existing media.

On Windows, run the PowerShell workflow with your local resource paths:

```powershell
.\run-production-workflow.ps1 `
  -Storyboard "C:\path\to\storyboard_elias_yoder.xlsx" `
  -Timestamps "C:\path\to\time_stamp.csv" `
  -VoiceOver "C:\path\to\voice_over.mp3" `
  -AvatarImage "C:\path\to\avatar.png" `
  -AvatarPrompt "C:\path\to\Prompt_for_avatar.txt" `
  -OutputDir ".\output" `
  -FirstScene 1 `
  -LastScene 371
```

The Windows workflow starts its own local LTX backend, creates all scene media,
applies the avatar lipsync workaround, builds split-screens, and then assembles
both final MP4 files:

```text
output/final_video.mp4
output/final_video_motion_0_6x_youtube1080_corrected.mp4
```

Use `-SkipAssemble` or `-SkipYoutubeAssemble` only when you intentionally want
to skip one of those final exports.

To regenerate avatar outputs with the stable-camera prompt, delete old avatar
outputs and rewrite `Prompt_for_avatar.txt`:

```bash
python3 reset_avatar_outputs.py
python3 ltx_linux_workflow.py --skip-motion --skip-kenburn --skip-assemble
python3 rebuild_split_screens.py
```

Validate avatar source clips:

```powershell
python .\check-lipsync.py --folder .\output\avatar-videos
```

The checker creates `lipsync_report.csv` and `lipsync_errors.txt`. Regenerate
every failed avatar before final assembly.

Assemble the corrected YouTube 1080p final with 0.6x Motion scenes:

```bash
python3 assemble_motion_slow_youtube.py \
  --resources /root/Resources \
  --production-output /root/Resources/production_output \
  --output /root/Resources/production_output/final_video_motion_0_6x_youtube1080_corrected.mp4 \
  --motion-speed 0.6
```

## Output

```text
output/
  images/scene_N.png
  avatar-audio/scene_N.mp3
  avatar-audio-ltx/scene_N.mp3
  avatar-videos/
  videos/
    scene_N.mp4
    scene_N_1.mp4
    scene_N_2.mp4
  work/
    avatar-videos-with-leadin/
  final_video.mp4
  final_video_motion_0_6x_youtube1080_corrected.mp4
```

## Frame-Accurate Assembly

At 24 fps, arbitrary millisecond timestamps cannot always land exactly on a
frame. The assembler rounds each **absolute timestamp boundary** to its nearest
frame, then derives scene frame counts from adjacent boundaries.

This limits boundary error to at most half a frame and prevents timing error
from accumulating across scenes.

When slowing Motion clips, do not trim using the slowed PTS directly and then
reset timestamps with `PTS-STARTPTS`. That creates a visible drift where the
audio finishes before the visual scene changes. The safe filter order is:

```text
scale,crop,setpts=PTS-STARTPTS,setpts=PTS/0.6,fps=24,
tpad=stop_mode=clone:stop=-1,trim=end_frame=SCENE_FRAMES,setpts=N/(24*TB)
```

The important detail is the final `setpts=N/(24*TB)`: it makes each output scene
exactly `SCENE_FRAMES` frames long after sampling the 0.6x source. This keeps
scene boundaries locked to the voice-over timestamps.

## YouTube 1080p Export

The corrected final uses:

- 1920x1080
- 24 fps
- H.264 `yuv420p`
- target video bitrate `10M`, maxrate `12M`, bufsize `20M`
- AAC audio, `384k`
- `+faststart`

## Notes

- The scripts start and stop their own local LTX backend.
- Generation can take substantial time; outputs are resumable.
- Do not commit generated media, models, API keys, voice-over, or storyboards.
