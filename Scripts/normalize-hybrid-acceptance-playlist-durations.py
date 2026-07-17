#!/usr/bin/env python3
"""Normalize HLS EXTINF decimal rounding to Aether's 90 kHz carrier timeline.

FFmpeg writes EXTINF with six decimal places. Frame durations are therefore
serialized up to one 90 kHz tick above or below their exact sum after parsing.
This helper may correct only that bounded serialization error: at most one
signed tick per audio segment. A larger mismatch is a real fixture error and
remains terminal.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path


TIMESCALE = 90_000
EXTINF = re.compile(r"^(#EXTINF:)([0-9]+(?:\.[0-9]+)?)(,.*)$")


def load(path: Path) -> tuple[list[str], list[tuple[int, float]]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    durations: list[tuple[int, float]] = []
    for index, line in enumerate(lines):
        match = EXTINF.match(line)
        if match:
            durations.append((index, float(match.group(2))))
    if not durations:
        raise SystemExit(f"ERROR: playlist has no EXTINF durations: {path}")
    return lines, durations


def ticks(durations: list[tuple[int, float]]) -> int:
    return sum(int(duration * TIMESCALE) for _, duration in durations)


def normalize(video_path: Path, audio_path: Path) -> int:
    _, video_durations = load(video_path)
    lines, audio_durations = load(audio_path)
    if len(audio_durations) != len(video_durations):
        raise SystemExit(
            "ERROR: audio/video segment-count mismatch: "
            f"{audio_path} has {len(audio_durations)}, "
            f"{video_path} has {len(video_durations)}"
        )

    target_ticks = ticks(video_durations)
    audio_ticks = ticks(audio_durations)
    correction = target_ticks - audio_ticks
    if correction == 0:
        return 0
    if abs(correction) > len(audio_durations):
        raise SystemExit(
            "ERROR: audio timeline mismatch exceeds bounded EXTINF rounding: "
            f"{audio_path} correction={correction} ticks "
            f"segments={len(audio_durations)}"
        )

    last_line_index, last_duration = audio_durations[-1]
    last_ticks = int(last_duration * TIMESCALE)
    if last_ticks + correction <= 0:
        raise SystemExit(
            "ERROR: duration correction would erase the final audio segment: "
            f"{audio_path} correction={correction} ticks"
        )
    corrected_duration = (last_ticks + correction + 0.25) / TIMESCALE
    match = EXTINF.match(lines[last_line_index])
    assert match is not None
    lines[last_line_index] = (
        f"{match.group(1)}{corrected_duration:.9f}{match.group(3)}"
    )
    audio_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    _, verified_durations = load(audio_path)
    if ticks(verified_durations) != target_ticks:
        raise SystemExit(
            f"ERROR: normalized playlist still differs from video: {audio_path}"
        )
    return correction


def signal_atmos(master_path: Path, rendition_name: str) -> None:
    lines = master_path.read_text(encoding="utf-8").splitlines()
    uri = f'URI="{rendition_name}/index.m3u8"'
    matches = [
        index
        for index, line in enumerate(lines)
        if line.startswith("#EXT-X-MEDIA:TYPE=AUDIO") and uri in line
    ]
    if len(matches) != 1:
        raise SystemExit(
            "ERROR: Atmos rendition must have exactly one master declaration: "
            f"{master_path} rendition={rendition_name} matches={len(matches)}"
        )
    index = matches[0]
    if 'CHANNELS="6"' not in lines[index]:
        raise SystemExit(
            "ERROR: generated Atmos rendition did not declare six-channel E-AC-3: "
            f"{lines[index]}"
        )
    lines[index] = lines[index].replace(
        'CHANNELS="6"',
        'CHANNELS="16/JOC"',
    )
    master_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("fixture_directory", type=Path)
    parser.add_argument("--atmos-rendition")
    args = parser.parse_args()
    root = args.fixture_directory
    video = root / "video" / "index.m3u8"
    audio_playlists = sorted(
        path
        for path in root.glob("*/index.m3u8")
        if path != video
    )
    if not audio_playlists:
        raise SystemExit(
            f"ERROR: fixture has no alternate-audio playlist: {root}"
        )
    for audio in audio_playlists:
        correction = normalize(video, audio)
        print(f"Normalized {audio}: {correction:+d} carrier ticks")
    if args.atmos_rendition is not None:
        signal_atmos(root / "master.m3u8", args.atmos_rendition)
        print(
            "Signaled Atmos rendition: "
            f"{args.atmos_rendition} CHANNELS=16/JOC"
        )


if __name__ == "__main__":
    main()
