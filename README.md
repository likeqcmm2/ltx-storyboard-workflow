# LTX Desktop Storyboard Production Workflow

Windows workflow for turning a storyboard XLSX, timestamp CSV, voice-over, and
avatar resources into a narrated video with local LTX Desktop models.

The production pipeline was validated with LTX Desktop, Z-Image-Turbo,
LTX 2.3 Fast, FFmpeg NVENC, and a 24 fps frame-accurate final timeline.

## Scene Types

The first XLSX worksheet is used. Scene 1 starts on row 2.

| Column | Meaning |
|---|---|
| C | Visual / still-image prompt |
| D | Motion prompt or Ken Burn instruction |
| E | Scene type |

Supported scene types:

- `Motion`: generate an image, then LTX image-to-video. Final clip is silent.
- `Still Image + Ken Burn`: generate an image, then create a silent zoom clip
  with FFmpeg/NVENC.
- `Avatar`: cut matching voice-over audio and generate a talking avatar.
- `Avatar/Split-screen`: generate a talking avatar as `scene_N_1.mp4`, create a
  silent Ken Burn visual as `scene_N_2.mp4`, then combine them as `scene_N.mp4`.
- `Persona Story`: production-supplied images can be processed as Motion,
  Ken Burn, or Avatar/Split-screen according to the scene plan.

Rows without a visual prompt do not generate images. Persona Story image
generation is intentionally skipped when externally prepared images are used.

## Production Stages

1. Generate still images from column C with Z-Image-Turbo.
2. Generate `Motion` clips with LTX 2.3 Fast and remove generated audio.
3. Generate silent Ken Burn clips with FFmpeg:

   ```powershell
   ffmpeg -loop 1 -i input.png -vf "scale=8000:-1,zoompan=z='zoom+0.001':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=150:s=1920x1080,format=yuv420p" -an -c:v h264_nvenc -t 5 output.mp4
   ```

4. Cut voice-over by timestamp and generate Avatar clips.
5. Build Avatar/Split-screen clips, keeping only avatar audio.
6. Validate all source avatar clips with `check-lipsync.py`.
7. Regenerate failed avatar clips and rebuild affected split-screens.
8. Assemble the final video using absolute 24 fps frame boundaries to prevent
   per-scene rounding drift.

## Requirements

- Windows and PowerShell 5.1+
- LTX Desktop installed in `C:\Program Files\LTX Desktop`
- LTX Desktop opened once so its bundled Python exists
- Downloaded Z-Image-Turbo and LTX 2.3 distilled models
- NVIDIA GPU supported by LTX Desktop
- For lipsync validation: Python 3.10+ with:

  ```powershell
  pip install opencv-python scipy numpy
  ```

- FFmpeg available as `ffmpeg` in PATH for the lipsync checker

The generation scripts use LTX Desktop's bundled Python and FFmpeg.

## Configuration

```powershell
Copy-Item .\config.example.json .\config.json
```

Update all input paths and the desired scene range.

## Run

Close LTX Desktop first to free GPU VRAM.

Generate the production media:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run-production-workflow.ps1 `
  -Storyboard "C:\path\storyboard.xlsx" `
  -Timestamps "C:\path\time_stamp.csv" `
  -VoiceOver "C:\path\voice_over.mp3" `
  -AvatarImage "C:\path\avatar.png" `
  -AvatarPrompt "C:\path\Prompt_for_avatar.txt" `
  -PersonaImagesDir "C:\path\Persona_Story" `
  -PersonaMotionScenes 36,38,40 `
  -PersonaKenBurnScenes 39 `
  -PersonaSplitScenes 37 `
  -OutputDir ".\output"
```

Existing files are skipped. Add `-Force` to regenerate.

Validate avatar source clips:

```powershell
python .\check-lipsync.py --folder .\output\avatar-videos
```

The checker creates `lipsync_report.csv` and `lipsync_errors.txt`. Regenerate
every failed avatar before final assembly.

Assemble with absolute frame boundaries:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\assemble-frame-accurate.ps1 `
  -Config .\config.json
```

## Output

```text
output/
  images/scene_N.png
  avatar-audio/scene_N.mp3
  avatar-videos/
  videos/
    scene_N.mp4
    scene_N_1.mp4
    scene_N_2.mp4
  work/
  final_video.mp4
```

## Frame-Accurate Assembly

At 24 fps, arbitrary millisecond timestamps cannot always land exactly on a
frame. The assembler rounds each **absolute timestamp boundary** to its nearest
frame, then derives scene frame counts from adjacent boundaries.

This limits boundary error to at most half a frame and prevents timing error
from accumulating across scenes.

## Notes

- The scripts start and stop their own local LTX backend.
- Generation can take substantial time; outputs are resumable.
- Do not commit generated media, models, API keys, voice-over, or storyboards.
