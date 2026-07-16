#!/usr/bin/env bash

# Regenerate the checked-in, one-frame H.264 asset used by the black carrier.
#
# Runtime code never creates a video encoder. It verifies and reuses this exact
# pre-encoded MP4 payload, while the carrier muxer assigns source-axis timestamps.
#
# The expected hash intentionally makes encoder or muxer drift fail closed. If a
# toolchain update changes the output, review the bitstream/container contract
# before updating the checked-in asset, manifest, script, and Swift constant.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESOURCE_DIR="$REPO_ROOT/Sources/AetherEngine/Resources"
RESOURCE_PATH="$RESOURCE_DIR/black-carrier-idr.mp4"
MANIFEST_PATH="$RESOURCE_DIR/black-carrier-idr.sha256"
EXPECTED_SHA256="a410d40376c11c10df2e5fdc7709ad1438fd64e7f5672479ac18bd3fd5203c29"
FFMPEG_BIN="${FFMPEG_BIN:-ffmpeg}"
FFPROBE_BIN="${FFPROBE_BIN:-ffprobe}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

for tool in "$FFMPEG_BIN" "$FFPROBE_BIN" "$PYTHON_BIN"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: required tool is unavailable: $tool" >&2
        exit 1
    fi
done

if [[ ! -f "$MANIFEST_PATH" ]]; then
    echo "ERROR: missing approved hash manifest: $MANIFEST_PATH" >&2
    exit 1
fi

MANIFEST_SHA256="$(tr -d '[:space:]' < "$MANIFEST_PATH")"
if [[ "$MANIFEST_SHA256" != "$EXPECTED_SHA256" ]]; then
    echo "ERROR: hash manifest does not match the generator contract" >&2
    echo "  expected: $EXPECTED_SHA256" >&2
    echo "  manifest: $MANIFEST_SHA256" >&2
    exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aether-black-carrier.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
OUTPUT_PATH="$TMP_DIR/black-carrier-idr.mp4"
ANNEX_B_PATH="$TMP_DIR/black-carrier-idr.h264"

"$FFMPEG_BIN" -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=black:size=640x360:rate=1:duration=1" \
    -frames:v 1 -an \
    -c:v libx264 -profile:v baseline -level:v 3.0 \
    -preset placebo -tune stillimage -pix_fmt yuv420p \
    -x264-params "keyint=1:min-keyint=1:scenecut=0:bframes=0:ref=1:cabac=0:repeat-headers=0:aud=0:colorprim=bt709:transfer=bt709:colormatrix=bt709:fullrange=off" \
    -bsf:v "filter_units=remove_types=6" \
    -color_range tv -colorspace bt709 -color_primaries bt709 -color_trc bt709 \
    -movflags "+faststart+write_colr" \
    -video_track_timescale 90000 \
    "$OUTPUT_PATH"

STREAM_INFO="$(
    "$FFPROBE_BIN" -v error -select_streams v:0 \
        -show_entries stream=codec_name,profile,codec_tag_string,width,height,pix_fmt,level,color_range,color_space,r_frame_rate,avg_frame_rate,time_base,nb_frames \
        -of default=nokey=0:noprint_wrappers=1 \
        "$OUTPUT_PATH"
)"

require_stream_field() {
    local expected="$1"
    if ! printf '%s\n' "$STREAM_INFO" | grep -Fqx "$expected"; then
        echo "ERROR: generated stream is missing required field: $expected" >&2
        printf '%s\n' "$STREAM_INFO" >&2
        exit 1
    fi
}

require_stream_field "codec_name=h264"
require_stream_field "profile=Constrained Baseline"
require_stream_field "codec_tag_string=avc1"
require_stream_field "width=640"
require_stream_field "height=360"
require_stream_field "pix_fmt=yuv420p"
require_stream_field "level=30"
require_stream_field "color_range=tv"
require_stream_field "color_space=bt709"
require_stream_field "r_frame_rate=1/1"
require_stream_field "avg_frame_rate=1/1"
require_stream_field "time_base=1/90000"
require_stream_field "nb_frames=1"

PACKET_INFO="$(
    "$FFPROBE_BIN" -v error -select_streams v:0 \
        -show_entries packet=pts,dts,duration,size,flags \
        -of csv=p=0 \
        "$OUTPUT_PATH"
)"
if [[ "$PACKET_INFO" != "0,0,90000,718,K__" ]]; then
    echo "ERROR: generated packet contract changed" >&2
    echo "  expected: 0,0,90000,718,K__" >&2
    echo "  actual:   $PACKET_INFO" >&2
    exit 1
fi

DECODE_INFO="$(
    "$FFMPEG_BIN" -hide_banner -loglevel info -i "$OUTPUT_PATH" \
        -vf showinfo -frames:v 1 -f null - 2>&1
)"
if ! printf '%s\n' "$DECODE_INFO" \
    | grep -Fq "color_range:tv color_space:bt709 color_primaries:bt709 color_trc:bt709"; then
    echo "ERROR: decoded frame does not expose the approved limited-range BT.709 VUI" >&2
    printf '%s\n' "$DECODE_INFO" >&2
    exit 1
fi

"$FFMPEG_BIN" -hide_banner -loglevel error -y \
    -i "$OUTPUT_PATH" -map 0:v:0 -c copy \
    -bsf:v h264_mp4toannexb -f h264 \
    "$ANNEX_B_PATH"

"$PYTHON_BIN" - "$ANNEX_B_PATH" <<'PY'
from pathlib import Path
import sys

data = Path(sys.argv[1]).read_bytes()
starts = []
cursor = 0
while cursor + 3 < len(data):
    if data[cursor:cursor + 4] == b"\x00\x00\x00\x01":
        starts.append((cursor, 4))
        cursor += 4
    elif data[cursor:cursor + 3] == b"\x00\x00\x01":
        starts.append((cursor, 3))
        cursor += 3
    else:
        cursor += 1

nal_types = []
for index, (offset, prefix_length) in enumerate(starts):
    payload_start = offset + prefix_length
    payload_end = starts[index + 1][0] if index + 1 < len(starts) else len(data)
    if payload_start < payload_end:
        nal_types.append(data[payload_start] & 0x1F)

if 6 in nal_types:
    raise SystemExit(f"ERROR: generated sample contains forbidden SEI NAL units: {nal_types}")
for required in (7, 8, 5):
    if required not in nal_types:
        raise SystemExit(f"ERROR: generated sample is missing required H.264 NAL type {required}: {nal_types}")
PY

ACTUAL_SHA256="$(shasum -a 256 "$OUTPUT_PATH" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
    echo "ERROR: generated asset hash changed; do not replace the approved sample implicitly" >&2
    echo "  expected: $EXPECTED_SHA256" >&2
    echo "  actual:   $ACTUAL_SHA256" >&2
    echo "Review the FFmpeg/libx264 toolchain and encoded contract before approving a new hash." >&2
    exit 1
fi

mkdir -p "$RESOURCE_DIR"
install -m 0644 "$OUTPUT_PATH" "$RESOURCE_PATH"
echo "Installed $RESOURCE_PATH"
echo "SHA-256 $ACTUAL_SHA256"
