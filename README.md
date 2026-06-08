# LTX Desktop Storyboard Workflow

Automates a storyboard into a finished narrated video using the locally
installed [LTX Desktop](https://github.com/Lightricks/LTX-Desktop).

## Workflow

For each storyboard scene:

1. If column C contains a still-image prompt, generate `scene_N.png` with
   Z-Image-Turbo.
2. Use that image and the motion prompt from column D to generate
   `scene_N.mp4` with LTX 2.3 Fast.
3. If column C and D are empty, treat the scene as an avatar scene:
   - Cut the matching timestamp from the full voice-over.
   - Generate a talking-avatar video from the avatar image, avatar prompt,
     and cut audio.
4. Fit every scene to its exact timestamp duration.
5. Assemble scenes in order and attach the full voice-over trimmed at the end
   of the final selected scene.

## Requirements

- Windows
- LTX Desktop installed in `C:\Program Files\LTX Desktop`
- LTX Desktop opened once so its bundled Python environment exists
- Downloaded local models:
  - Z-Image-Turbo
  - LTX 2.3 distilled model
- NVIDIA GPU supported by LTX Desktop
- PowerShell 5.1 or newer

No separate Python, FFmpeg, Git, or PowerShell modules are required.

## Input Format

### Storyboard XLSX

- Row 1 is the header.
- Scene 1 begins at row 2.
- Column C: still-image prompt.
- Column D: image-to-video motion prompt.
- Empty columns C and D mark an avatar scene.
- The workflow reads the first worksheet.

### Timestamp CSV

Row 1 is the header. Each following row maps to a scene:

```csv
Timecode;;;
00:00:00.000 - 00:00:02.850;;;
00:00:02.850 - 00:00:05.550;;;
```

### Avatar Resources

- One avatar image.
- One text file containing the avatar animation prompt.
- One full voice-over audio file.

## Usage

Copy the example configuration:

```powershell
Copy-Item .\config.example.json .\config.json
```

Edit `config.json`, then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run-workflow.ps1
```

Run only selected stages:

```powershell
.\run-workflow.ps1 -Stage Images
.\run-workflow.ps1 -Stage Videos
.\run-workflow.ps1 -Stage Avatars
.\run-workflow.ps1 -Stage Assemble
```

Stages skip existing output files by default. Use `-Force` to regenerate them.

## Output

```text
output/
  images/scene_N.png
  avatar-audio/scene_N.mp3
  videos/scene_N.mp4
  final_video.mp4
```

LTX generates local 1080p video at `1920x1088`. The assembly stage crops it
to standard `1920x1080`.

## Notes

- The workflow starts its own local LTX backend on the configured port.
- Close LTX Desktop before running to maximize available GPU VRAM.
- Local video generation can take substantial time.
- Do not commit models, generated media, API keys, or private storyboards.

