#!/usr/bin/env python3
"""Generate talking-avatar clips for every timestamp cut in time_stamp.csv."""
from __future__ import annotations

import argparse
import json
import math
import re
import shutil
import subprocess
import time
import urllib.request
from pathlib import Path


def run(cmd: list[str], message: str | None = None):
    print("+", " ".join(map(str, cmd)), flush=True)
    proc = subprocess.run(cmd)
    if proc.returncode != 0:
        raise RuntimeError(message or f"Command failed: {cmd}")


def timecode_seconds(value: str) -> float:
    match = re.match(r"^(\d{1,2}):(\d{1,2}):(\d{1,2})(?:\.(\d{1,3}))?$", value.strip())
    if not match:
        raise ValueError(f"Invalid timecode: {value}")
    frac = (match.group(4) or "0").ljust(3, "0")[:3]
    return (
        int(match.group(1)) * 3600
        + int(match.group(2)) * 60
        + int(match.group(3))
        + int(frac) / 1000
    )


def read_timestamp_cuts(path: Path):
    rows = path.read_text(encoding="utf-8-sig").splitlines()
    cuts = []
    pattern = re.compile(
        r"(\d{1,2}:\d{1,2}:\d{1,2}(?:\.\d{1,3})?)\s*-\s*"
        r"(\d{1,2}:\d{1,2}:\d{1,2}(?:\.\d{1,3})?)"
    )
    for row_number, line in enumerate(rows, start=1):
        if not line.strip():
            continue
        match = pattern.search(line)
        if not match:
            print(f"SKIP timestamp row {row_number}: no cut range found", flush=True)
            continue
        start = timecode_seconds(match.group(1))
        end = timecode_seconds(match.group(2))
        if end <= start:
            raise ValueError(f"Timestamp row {row_number} has non-positive duration: {line}")
        cuts.append(
            {
                "index": len(cuts) + 1,
                "row": row_number,
                "start": start,
                "end": end,
                "duration": end - start,
                "source": line.strip(),
            }
        )
    if not cuts:
        raise RuntimeError(f"No timestamp cuts found in {path}")
    return cuts


def api_post(base_url: str, route: str, body: dict, timeout: int = 7200):
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        base_url + route,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def api_get(base_url: str, route: str, timeout: int = 30):
    with urllib.request.urlopen(base_url + route, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def wait_backend(base_url: str, seconds: int):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            api_get(base_url, "/health")
            return
        except Exception:
            time.sleep(2)
    raise RuntimeError(f"Timed out waiting for LTX backend at {base_url}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--resources", default="/root/Resources")
    parser.add_argument("--output-dir", default="/root/Resources/production_output")
    parser.add_argument("--base-url", default="http://127.0.0.1:41954")
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--wait-backend-seconds", type=int, default=180)
    parser.add_argument("--first-cut", type=int, default=1)
    parser.add_argument("--last-cut", type=int, default=0, help="0 means all cuts.")
    parser.add_argument("--prefix", default="scene")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--fps", type=int, default=24)
    parser.add_argument("--resolution", default="1080p")
    parser.add_argument("--model", default="fast")
    parser.add_argument("--lead-in-seconds", type=float, default=1.0)
    parser.add_argument("--audio-gain-db", type=float, default=20.0)
    parser.add_argument(
        "--duration-mode",
        choices=("auto", "fixed-six-seconds"),
        default="auto",
        help="auto sends the padded audio length rounded up, with a 6s minimum.",
    )
    args = parser.parse_args()

    resources = Path(args.resources)
    output = Path(args.output_dir)
    timestamps = resources / "time_stamp.csv"
    voice = resources / "voice_over.mp3"
    avatar_image = resources / "avatar.png"
    avatar_prompt_path = resources / "Prompt_for_avatar.txt"
    audio_dir = output / "avatar-audio"
    ltx_audio_dir = output / "avatar-audio-ltx"
    avatar_video_dir = output / "avatar-videos"
    video_dir = output / "videos"
    raw_avatar_video_dir = output / "work" / "avatar-videos-with-leadin"

    for required in (timestamps, voice, avatar_image, avatar_prompt_path):
        if not required.exists():
            raise FileNotFoundError(required)
    for folder in (output, audio_dir, ltx_audio_dir, avatar_video_dir, video_dir, raw_avatar_video_dir):
        folder.mkdir(parents=True, exist_ok=True)

    prompt = avatar_prompt_path.read_text(encoding="utf-8").strip()
    cuts = read_timestamp_cuts(timestamps)
    selected = [
        cut
        for cut in cuts
        if cut["index"] >= args.first_cut and (args.last_cut == 0 or cut["index"] <= args.last_cut)
    ]
    if not selected:
        raise RuntimeError("No timestamp cuts selected.")

    wait_backend(args.base_url, args.wait_backend_seconds)

    for cut in selected:
        index = cut["index"]
        stem = f"{args.prefix}_{index}"
        audio = audio_dir / f"{stem}.mp3"
        ltx_audio = ltx_audio_dir / f"{stem}.mp3"
        raw_avatar_video = raw_avatar_video_dir / f"{stem}.mp4"
        avatar_video = avatar_video_dir / f"{stem}.mp4"
        video_copy = video_dir / f"{stem}.mp4"

        if args.force or not audio.exists():
            run(
                [
                    args.ffmpeg,
                    "-nostdin",
                    "-y",
                    "-ss",
                    f"{cut['start']:.3f}",
                    "-t",
                    f"{cut['duration']:.3f}",
                    "-i",
                    str(voice),
                    "-vn",
                    "-codec:a",
                    "libmp3lame",
                    "-q:a",
                    "2",
                    str(audio),
                ],
                f"Failed to cut audio for {stem}",
            )

        if args.force or not ltx_audio.exists():
            padded_audio = ltx_audio.with_suffix(".padded.tmp.mp3")
            run(
                [
                    args.ffmpeg,
                    "-nostdin",
                    "-y",
                    "-f",
                    "lavfi",
                    "-t",
                    f"{args.lead_in_seconds:.3f}",
                    "-i",
                    "anullsrc=r=44100:cl=stereo",
                    "-i",
                    str(audio),
                    "-filter_complex",
                    "[0:a][1:a]concat=n=2:v=0:a=1[a]",
                    "-map",
                    "[a]",
                    "-codec:a",
                    "libmp3lame",
                    "-q:a",
                    "0",
                    str(padded_audio),
                ],
                f"Failed to add avatar lead-in for {stem}",
            )
            run(
                [
                    args.ffmpeg,
                    "-nostdin",
                    "-y",
                    "-i",
                    str(padded_audio),
                    "-filter:a",
                    f"volume={args.audio_gain_db:g}dB",
                    "-q:a",
                    "0",
                    str(ltx_audio),
                ],
                f"Failed to boost LTX audio for {stem}",
            )
            padded_audio.unlink(missing_ok=True)

        if avatar_video.exists() and not args.force:
            print(f"SKIP AVATAR {index}: {avatar_video}", flush=True)
            if not video_copy.exists():
                shutil.copy2(avatar_video, video_copy)
            continue

        audio_duration = cut["duration"]
        padded_duration = audio_duration + args.lead_in_seconds
        generation_duration = (
            6 if args.duration_mode == "fixed-six-seconds" else max(6, math.ceil(padded_duration))
        )
        backend_resolution = args.resolution
        if args.resolution == "1080p" and generation_duration > 5:
            backend_resolution = "720p"
        print(
            f"AVATAR {index} row={cut['row']} cut={cut['start']:.3f}-{cut['end']:.3f} "
            f"audio={audio_duration:.3f}s ltx_audio={padded_duration:.3f}s "
            f"generation_duration={generation_duration}s resolution={backend_resolution}->{args.resolution} "
            f"lead_in={args.lead_in_seconds:.3f}s gain={args.audio_gain_db:g}dB",
            flush=True,
        )
        result = api_post(
            args.base_url,
            "/api/generate",
            {
                "prompt": prompt,
                "resolution": backend_resolution,
                "model": args.model,
                "cameraMotion": "none",
                "negativePrompt": "",
                "duration": generation_duration,
                "fps": args.fps,
                "audio": True,
                "imagePath": str(avatar_image),
                "audioPath": str(ltx_audio),
                "aspectRatio": "16:9",
            },
        )
        shutil.copy2(result["video_path"], raw_avatar_video)
        run(
            [
                args.ffmpeg,
                "-nostdin",
                "-y",
                "-i",
                str(raw_avatar_video),
                "-ss",
                f"{args.lead_in_seconds:.3f}",
                "-t",
                f"{audio_duration:.3f}",
                "-map",
                "0:v:0",
                "-map",
                "0:a:0?",
                "-vf",
                "scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,format=yuv420p",
                "-c:v",
                "libx264",
                "-preset",
                "veryfast",
                "-crf",
                "18",
                "-c:a",
                "aac",
                "-b:a",
                "192k",
                "-movflags",
                "+faststart",
                str(avatar_video),
            ],
            f"Failed to trim lead-in from {stem}",
        )
        shutil.copy2(avatar_video, video_copy)

    print(f"Completed {len(selected)} avatar clips in {avatar_video_dir}", flush=True)


if __name__ == "__main__":
    main()
