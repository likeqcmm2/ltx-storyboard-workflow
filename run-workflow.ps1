[CmdletBinding()]
param(
    [ValidateSet("All", "Images", "Videos", "Avatars", "Assemble")]
    [string]$Stage = "All",
    [string]$Config = ".\config.json",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Resolve-ConfiguredPath([string]$Path, [string]$BaseDir) {
    if ([IO.Path]::IsPathRooted($Path)) { return $Path }
    return [IO.Path]::GetFullPath((Join-Path $BaseDir $Path))
}

function Convert-TimecodeToSeconds([string]$Timecode) {
    if ($Timecode -notmatch '^(\d{2}):(\d{2}):(\d{2}\.\d{3})$') {
        throw "Invalid timecode: $Timecode"
    }
    return ([int]$Matches[1] * 3600) + ([int]$Matches[2] * 60) + [double]$Matches[3]
}

function Read-Storyboard([string]$Path, [int]$FirstScene, [int]$LastScene) {
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $zip.GetEntry("xl/worksheets/sheet1.xml")
        if (-not $entry) { throw "The first XLSX worksheet was not found." }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { [xml]$xml = $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }

    $ns = [Xml.XmlNamespaceManager]::new($xml.NameTable)
    $ns.AddNamespace("m", "http://schemas.openxmlformats.org/spreadsheetml/2006/main")

    function Cell([string]$Reference) {
        $node = $xml.SelectSingleNode("//m:c[@r='$Reference']", $ns)
        if (-not $node) { return "" }
        $text = $node.SelectSingleNode(".//m:t", $ns)
        if ($text) { return $text.InnerText.Trim() }
        $value = $node.SelectSingleNode("./m:v", $ns)
        if ($value) { return $value.InnerText.Trim() }
        return ""
    }

    return @($FirstScene..$LastScene | ForEach-Object {
        $row = $_ + 1
        [pscustomobject]@{
            Scene = $_
            ImagePrompt = Cell "C$row"
            MotionPrompt = Cell "D$row"
        }
    })
}

function Read-Timestamps([string]$Path, [int]$FirstScene, [int]$LastScene) {
    $lines = @(Get-Content $Path | Select-Object -Skip 1)
    return @($FirstScene..$LastScene | ForEach-Object {
        $line = $lines[$_ - 1]
        if ($line -notmatch '(\d{2}:\d{2}:\d{2}\.\d{3})\s+-\s+(\d{2}:\d{2}:\d{2}\.\d{3})') {
            throw "Invalid timestamp for scene $_`: $line"
        }
        $start = Convert-TimecodeToSeconds $Matches[1]
        $end = Convert-TimecodeToSeconds $Matches[2]
        [pscustomobject]@{ Scene = $_; Start = $start; End = $end; Duration = $end - $start }
    })
}

function Start-LtxBackend([string]$Python, [string]$Backend, [string]$AppData, [int]$Port, [string]$Log) {
    $env:LTX_APP_DATA_DIR = $AppData
    $env:LTX_PORT = "$Port"
    $env:LTX_AUTH_TOKEN = ""
    $backendDir = Split-Path -Parent $Backend
    $bootstrap = "import sys; sys.path.insert(0, r'$backendDir'); import runpy; runpy.run_path(r'$Backend', run_name='__main__')"
    $process = Start-Process -FilePath $Python -ArgumentList @("-u", "-c", "`"$bootstrap`"") `
        -WorkingDirectory $backendDir -RedirectStandardOutput $Log `
        -RedirectStandardError "$Log.error" -WindowStyle Hidden -PassThru
    $baseUrl = "http://127.0.0.1:$Port"
    $deadline = (Get-Date).AddMinutes(3)
    do {
        if ($process.HasExited) { throw "LTX backend exited. See $Log.error" }
        try {
            Invoke-RestMethod -Uri "$baseUrl/health" -TimeoutSec 2 | Out-Null
            return $process
        } catch { Start-Sleep -Seconds 2 }
    } until ((Get-Date) -gt $deadline)
    throw "Timed out waiting for LTX backend."
}

function Invoke-Ltx([string]$BaseUrl, [string]$Route, [hashtable]$Body) {
    return Invoke-RestMethod -Uri "$BaseUrl$Route" -Method Post -ContentType "application/json" `
        -Body ($Body | ConvertTo-Json) -TimeoutSec 7200
}

$configPath = [IO.Path]::GetFullPath($Config)
if (-not (Test-Path $configPath)) { throw "Config not found: $configPath" }
$baseDir = Split-Path -Parent $configPath
$cfg = Get-Content $configPath -Raw | ConvertFrom-Json

$storyboardPath = Resolve-ConfiguredPath $cfg.storyboard $baseDir
$timestampsPath = Resolve-ConfiguredPath $cfg.timestamps $baseDir
$voicePath = Resolve-ConfiguredPath $cfg.voice_over $baseDir
$avatarImage = Resolve-ConfiguredPath $cfg.avatar_image $baseDir
$avatarPromptPath = Resolve-ConfiguredPath $cfg.avatar_prompt $baseDir
$outputDir = Resolve-ConfiguredPath $cfg.output_dir $baseDir
$imageDir = Join-Path $outputDir "images"
$audioDir = Join-Path $outputDir "avatar-audio"
$videoDir = Join-Path $outputDir "videos"
$workDir = Join-Path $outputDir "work"
@($outputDir, $imageDir, $audioDir, $videoDir, $workDir) | ForEach-Object {
    New-Item -ItemType Directory -Path $_ -Force | Out-Null
}

$appData = Join-Path $env:LOCALAPPDATA "LTXDesktop"
$python = Join-Path $appData "python\python.exe"
$backend = "C:\Program Files\LTX Desktop\resources\backend\ltx2_server.py"
foreach ($required in @($storyboardPath, $timestampsPath, $voicePath, $avatarImage, $avatarPromptPath, $python, $backend)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Required file not found: $required" }
}
$ffmpeg = & $python -c "import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())"
$baseUrl = "http://127.0.0.1:$($cfg.backend_port)"
$scenes = Read-Storyboard $storyboardPath $cfg.first_scene $cfg.last_scene
$timestamps = Read-Timestamps $timestampsPath $cfg.first_scene $cfg.last_scene
$avatarPrompt = (Get-Content $avatarPromptPath -Raw).Trim()

$needsBackend = $Stage -in @("All", "Images", "Videos", "Avatars")
$backendProcess = $null
try {
    if ($needsBackend) {
        $backendProcess = Start-LtxBackend $python $backend $appData $cfg.backend_port (Join-Path $workDir "backend.log")
    }

    if ($Stage -in @("All", "Images")) {
        foreach ($scene in $scenes | Where-Object ImagePrompt) {
            $destination = Join-Path $imageDir "scene_$($scene.Scene).png"
            if ((Test-Path $destination) -and -not $Force) { continue }
            Write-Host "Generating image scene_$($scene.Scene)..."
            $result = Invoke-Ltx $baseUrl "/api/generate-image" @{
                prompt = $scene.ImagePrompt; width = 1920; height = 1080
                numSteps = $cfg.image_steps; numImages = 1
            }
            Copy-Item $result.image_paths[0] $destination -Force
        }
    }

    if ($Stage -in @("All", "Videos")) {
        foreach ($scene in $scenes | Where-Object { $_.ImagePrompt -and $_.MotionPrompt }) {
            $destination = Join-Path $videoDir "scene_$($scene.Scene).mp4"
            if ((Test-Path $destination) -and -not $Force) { continue }
            Write-Host "Generating video scene_$($scene.Scene)..."
            $result = Invoke-Ltx $baseUrl "/api/generate" @{
                prompt = $scene.MotionPrompt; resolution = "1080p"; model = "fast"
                cameraMotion = "none"; negativePrompt = ""; duration = $cfg.video_duration
                fps = $cfg.video_fps; audio = $false
                imagePath = (Join-Path $imageDir "scene_$($scene.Scene).png")
                audioPath = $null; aspectRatio = "16:9"
            }
            Copy-Item $result.video_path $destination -Force
        }
    }

    if ($Stage -in @("All", "Avatars")) {
        foreach ($scene in $scenes | Where-Object { -not $_.ImagePrompt -and -not $_.MotionPrompt }) {
            $timestamp = $timestamps | Where-Object Scene -eq $scene.Scene
            $audio = Join-Path $audioDir "scene_$($scene.Scene).mp3"
            $destination = Join-Path $videoDir "scene_$($scene.Scene).mp4"
            if ($Force -or -not (Test-Path $audio)) {
                $start = $timestamp.Start.ToString("0.000", [Globalization.CultureInfo]::InvariantCulture)
                $duration = $timestamp.Duration.ToString("0.000", [Globalization.CultureInfo]::InvariantCulture)
                & $ffmpeg -y -ss $start -t $duration -i $voicePath -vn -codec:a libmp3lame -q:a 2 $audio
                if ($LASTEXITCODE -ne 0) { throw "Failed to cut avatar audio scene_$($scene.Scene)." }
            }
            if ((Test-Path $destination) -and -not $Force) { continue }
            Write-Host "Generating avatar scene_$($scene.Scene)..."
            $result = Invoke-Ltx $baseUrl "/api/generate" @{
                prompt = $avatarPrompt; resolution = "1080p"; model = "fast"
                cameraMotion = "none"; negativePrompt = ""; duration = $cfg.video_duration
                fps = $cfg.video_fps; audio = $true; imagePath = $avatarImage
                audioPath = $audio; aspectRatio = "16:9"
            }
            Copy-Item $result.video_path $destination -Force
        }
    }
}
finally {
    if ($backendProcess -and -not $backendProcess.HasExited) { Stop-Process -Id $backendProcess.Id -Force }
}

if ($Stage -in @("All", "Assemble")) {
    $inputs = @()
    $filters = @()
    $index = 0
    foreach ($scene in $scenes) {
        $video = Join-Path $videoDir "scene_$($scene.Scene).mp4"
        if (-not (Test-Path $video)) { throw "Missing video: $video" }
        $inputs += @("-i", $video)
        $duration = ($timestamps | Where-Object Scene -eq $scene.Scene).Duration.ToString("0.000", [Globalization.CultureInfo]::InvariantCulture)
        $filters += "[$index`:v]scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,setpts=PTS-STARTPTS,tpad=stop_mode=clone:stop_duration=$duration,trim=duration=$duration,setpts=PTS-STARTPTS[v$index]"
        $index++
    }
    $concat = (0..($index - 1) | ForEach-Object { "[v$_]" }) -join ""
    $filters += "${concat}concat=n=$index`:v=1:a=0[outv]"
    $filterPath = Join-Path $workDir "assemble-filter.txt"
    Set-Content $filterPath ($filters -join ";") -Encoding Ascii
    $endTime = ($timestamps | Select-Object -Last 1).End.ToString("0.000", [Globalization.CultureInfo]::InvariantCulture)
    $final = Join-Path $outputDir "final_video.mp4"
    $args = @("-y") + $inputs + @(
        "-i", $voicePath, "-filter_complex_script", $filterPath,
        "-map", "[outv]", "-map", "$index`:a:0", "-c:v", "libx264",
        "-preset", "medium", "-crf", "18", "-r", "$($cfg.video_fps)",
        "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k",
        "-t", "$endTime", "-movflags", "+faststart", $final
    )
    & $ffmpeg @args
    if ($LASTEXITCODE -ne 0) { throw "Final assembly failed." }
    Write-Host "Created $final"
}
