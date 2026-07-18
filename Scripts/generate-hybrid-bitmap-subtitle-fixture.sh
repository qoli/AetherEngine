#!/usr/bin/env bash
#
# Generate a copyright-clean, finite VP9 Matroska fixture with one PGS bitmap
# subtitle track. The SUP payload is generated locally from deterministic
# pixel glyphs, so the fixture carries no third-party font or media asset.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-$REPO_ROOT/Fixtures/hybrid-vp9-pgs-overlay.mkv}"
DURATION_SECONDS="${AETHER_ACCEPTANCE_DURATION_SECONDS:-32}"
WORK_DIRECTORY="$(mktemp -d)"
PGS_SOURCE="$WORK_DIRECTORY/acceptance.sup"
FFMPEG_LOG="$WORK_DIRECTORY/ffmpeg.log"

cleanup() {
    rm -rf "$WORK_DIRECTORY"
}
trap cleanup EXIT

if [[ -e "$OUTPUT" ]]; then
    echo "ERROR: acceptance fixture already exists: $OUTPUT" >&2
    exit 1
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ERROR: ffmpeg is required" >&2
    exit 1
fi
if ! command -v ffprobe >/dev/null 2>&1; then
    echo "ERROR: ffprobe is required" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
python3 - "$PGS_SOURCE" <<'PY'
from pathlib import Path
import struct
import sys

output = Path(sys.argv[1])
width = 1920
height = 1080
scale = 7
glyphs = {
    " ": ["00000"] * 7,
    "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
    "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
    "3": ["11110", "00001", "00001", "01110", "00001", "00001", "11110"],
    "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
    "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
    "B": ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
    "E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
    "H": ["10001", "10001", "10001", "11111", "10001", "10001", "10001"],
    "I": ["11111", "00100", "00100", "00100", "00100", "00100", "11111"],
    "K": ["10001", "10010", "10100", "11000", "10100", "10010", "10001"],
    "M": ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
    "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
    "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
    "S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
    "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
}


def segment(pts_seconds, kind, payload):
    pts = int(round(pts_seconds * 90_000))
    return b"PG" + struct.pack(">IIBH", pts, pts, kind, len(payload)) + payload


def render(text):
    text = text.upper()
    glyph_width = 5 * scale
    gap = scale
    padding = 14
    bitmap_width = padding * 2 + len(text) * glyph_width + max(0, len(text) - 1) * gap
    bitmap_height = padding * 2 + 7 * scale
    rows = [[0 for _ in range(bitmap_width)] for _ in range(bitmap_height)]
    cursor = padding
    for character in text:
        glyph = glyphs[character]
        for row_index, row in enumerate(glyph):
            for column_index, value in enumerate(row):
                if value != "1":
                    continue
                x0 = cursor + column_index * scale
                y0 = padding + row_index * scale
                for y in range(y0, y0 + scale):
                    for x in range(x0, x0 + scale):
                        rows[y][x] = 1
        cursor += glyph_width + gap
    return rows


def encode_run(length, color):
    if length == 1 and color != 0:
        return bytes([color])
    if length < 64:
        if color == 0:
            return bytes([0, length])
        return bytes([0, 0x80 | length, color])
    if length > 0x3FFF:
        raise ValueError("PGS run exceeds 14-bit length")
    flag = 0x40 | ((length >> 8) & 0x3F)
    if color != 0:
        flag |= 0x80
        return bytes([0, flag, length & 0xFF, color])
    return bytes([0, flag, length & 0xFF])


def encode_bitmap(rows):
    encoded = bytearray()
    for row in rows:
        start = 0
        while start < len(row):
            color = row[start]
            end = start + 1
            while end < len(row) and row[end] == color:
                end += 1
            encoded.extend(encode_run(end - start, color))
            start = end
        encoded.extend(b"\x00\x00")
    return bytes(encoded)


def display_set(start, end, composition, text):
    rows = render(text)
    object_width = len(rows[0])
    object_height = len(rows)
    object_x = (width - object_width) // 2
    object_y = 760
    pcs = struct.pack(
        ">HHBHBBBBHBBHH",
        width,
        height,
        0x10,
        composition,
        0x80,
        0,
        0,
        1,
        0,
        0,
        0,
        object_x,
        object_y,
    )
    wds = struct.pack(
        ">BBHHHH", 1, 0, object_x, object_y, object_width, object_height
    )
    pds = bytes([
        0,
        composition & 0xFF,
        0,
        16,
        128,
        128,
        0,
        1,
        235,
        128,
        128,
        255,
    ])
    bitmap = encode_bitmap(rows)
    object_data_length = 4 + len(bitmap)
    ods = (
        struct.pack(">HBB", 0, composition & 0xFF, 0xC0)
        + object_data_length.to_bytes(3, "big")
        + struct.pack(">HH", object_width, object_height)
        + bitmap
    )
    clear_pcs = struct.pack(
        ">HHBHBBBB", width, height, 0x10, composition + 1, 0x00, 0, 0, 0
    )
    return b"".join([
        segment(start, 0x16, pcs),
        segment(start, 0x17, wds),
        segment(start, 0x14, pds),
        segment(start, 0x15, ods),
        segment(start, 0x80, b""),
        segment(end, 0x16, clear_pcs),
        segment(end, 0x80, b""),
    ])


payload = b"".join([
    display_set(1.0, 7.5, 0, "AETHER BITMAP 1"),
    display_set(8.0, 15.5, 2, "BITMAP SEEK 2"),
    display_set(16.0, 23.5, 4, "SEEK BITMAP 3"),
    display_set(24.0, 31.0, 6, "BITMAP RESTART 4"),
])
output.write_bytes(payload)
PY

if ! ffmpeg -hide_banner -loglevel error -y -copyts \
    -f lavfi -i "testsrc2=duration=$DURATION_SECONDS:size=1280x720:rate=24" \
    -f lavfi -i "sine=frequency=392:sample_rate=48000:duration=$DURATION_SECONDS" \
    -f sup -i "$PGS_SOURCE" \
    -map 0:v:0 -map 1:a:0 -map 2:s:0 \
    -metadata:s:a:0 language=eng \
    -metadata:s:s:0 language=eng \
    -metadata:s:s:0 title="Aether Bitmap English" \
    -disposition:s:0 default \
    -c:v libvpx-vp9 -deadline good -cpu-used 4 -row-mt 1 \
    -b:v 1800k -g 96 -pix_fmt yuv420p \
    -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
    -c:a aac -b:a 192k -ar 48000 -ac 2 \
    -c:s copy \
    -t "$DURATION_SECONDS" \
    "$OUTPUT" 2>"$FFMPEG_LOG"; then
    cat "$FFMPEG_LOG" >&2
    rm -f "$OUTPUT"
    exit 1
fi
if [[ -s "$FFMPEG_LOG" ]]; then
    cat "$FFMPEG_LOG" >&2
    echo "ERROR: ffmpeg reported a fixture decode or mux warning" >&2
    rm -f "$OUTPUT"
    exit 1
fi

video_codec="$(
    ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name -of csv=p=0 "$OUTPUT"
)"
audio_codec="$(
    ffprobe -v error -select_streams a:0 \
        -show_entries stream=codec_name -of csv=p=0 "$OUTPUT"
)"
subtitle_contract="$(
    ffprobe -v error -select_streams s:0 \
        -show_entries stream=codec_name,width,height -of csv=p=0 "$OUTPUT"
)"
first_subtitle_pts="$(
    ffprobe -v error -select_streams s:0 \
        -show_packets -show_entries packet=pts_time -of csv=p=0 "$OUTPUT" \
        | sed -n '1p'
)"
if [[ "$video_codec" != "vp9" \
        || "$audio_codec" != "aac" \
        || "$subtitle_contract" != "hdmv_pgs_subtitle,1920,1080" \
        || "$first_subtitle_pts" != "1.000000" ]]; then
    echo "ERROR: generated fixture does not match the exact stream/timing contract" >&2
    echo "video=$video_codec audio=$audio_codec subtitle=$subtitle_contract firstSubtitlePTS=$first_subtitle_pts" >&2
    rm -f "$OUTPUT"
    exit 1
fi

PROVENANCE="$OUTPUT.provenance.txt"
CHECKSUM="$OUTPUT.sha256"
{
    echo "generator=Scripts/generate-hybrid-bitmap-subtitle-fixture.sh"
    echo "durationSeconds=$DURATION_SECONDS"
    echo "video=VP9 Profile 0 SDR BT.709"
    echo "audio=AAC stereo eng"
    echo "subtitle=deterministic locally-generated PGS bitmap eng default"
    echo "ffmpegVersion=$(ffmpeg -version | head -n 1)"
} > "$PROVENANCE"
shasum -a 256 "$OUTPUT" "$PROVENANCE" > "$CHECKSUM"

echo "Generated: $OUTPUT"
echo "Identity:  $CHECKSUM"
