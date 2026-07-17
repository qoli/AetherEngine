#!/usr/bin/env python3
"""Add one deterministic native WebVTT rendition to a generated fixture."""

from __future__ import annotations

import math
import re
import sys
from pathlib import Path


EXTINF = re.compile(r"^#EXTINF:([0-9]+(?:\.[0-9]+)?),")


def timestamp(seconds: float) -> str:
    milliseconds = round(seconds * 1000)
    hours, remainder = divmod(milliseconds, 3_600_000)
    minutes, remainder = divmod(remainder, 60_000)
    whole_seconds, milliseconds = divmod(remainder, 1000)
    return f"{hours:02d}:{minutes:02d}:{whole_seconds:02d}.{milliseconds:03d}"


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(
            "usage: add-hybrid-acceptance-webvtt.py <fixture-directory>"
        )
    root = Path(sys.argv[1])
    master = root / "master.m3u8"
    video = root / "video" / "index.m3u8"
    if not master.is_file() or not video.is_file():
        raise SystemExit("ERROR: generated master or video playlist is missing")

    video_lines = video.read_text(encoding="utf-8").splitlines()
    durations = [
        float(match.group(1))
        for line in video_lines
        if (match := EXTINF.match(line)) is not None
    ]
    if not durations or any(duration <= 0 for duration in durations):
        raise SystemExit("ERROR: video playlist has no valid EXTINF timeline")

    subtitle_root = root / "subtitles"
    if subtitle_root.exists():
        raise SystemExit("ERROR: subtitle output already exists")
    subtitle_root.mkdir()

    playlist = [
        "#EXTM3U",
        "#EXT-X-VERSION:3",
        f"#EXT-X-TARGETDURATION:{math.ceil(max(durations))}",
        "#EXT-X-MEDIA-SEQUENCE:0",
        "#EXT-X-PLAYLIST-TYPE:VOD",
    ]
    timeline = 0.0
    for index, duration in enumerate(durations):
        segment_name = f"segment_{index:03d}.vtt"
        cue_start = timeline + min(0.25, duration / 4)
        cue_end = timeline + max(cue_start - timeline + 0.1, duration - 0.25)
        cue_end = min(timeline + duration, cue_end)
        (subtitle_root / segment_name).write_text(
            "WEBVTT\n\n"
            f"{timestamp(cue_start)} --> {timestamp(cue_end)}\n"
            f"Aether native WebVTT segment {index + 1}\n",
            encoding="utf-8",
        )
        playlist.extend([f"#EXTINF:{duration:.9f},", segment_name])
        timeline += duration
    playlist.append("#EXT-X-ENDLIST")
    (subtitle_root / "index.m3u8").write_text(
        "\n".join(playlist) + "\n",
        encoding="utf-8",
    )

    master_lines = master.read_text(encoding="utf-8").splitlines()
    stream_indexes = [
        index
        for index, line in enumerate(master_lines)
        if line.startswith("#EXT-X-STREAM-INF:")
    ]
    if len(stream_indexes) != 1:
        raise SystemExit(
            "ERROR: acceptance fixture must contain exactly one video variant"
        )
    stream_index = stream_indexes[0]
    if "SUBTITLES=" in master_lines[stream_index]:
        raise SystemExit("ERROR: master already declares a subtitle group")
    master_lines[stream_index] += ',SUBTITLES="subtitles"'
    media_line = (
        '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subtitles",'
        'NAME="English",DEFAULT=NO,AUTOSELECT=YES,FORCED=NO,'
        'LANGUAGE="eng",URI="subtitles/index.m3u8"'
    )
    master_lines.insert(stream_index, media_line)
    master.write_text("\n".join(master_lines) + "\n", encoding="utf-8")
    print(
        "Added native WebVTT rendition: "
        f"segments={len(durations)} durationSeconds={timeline:.9f}"
    )


if __name__ == "__main__":
    main()
