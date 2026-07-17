#!/usr/bin/env bash
#
# Generate a copyright-clean, finite VP9 Matroska fixture with one styled ASS
# subtitle track. VP9 deliberately selects the progressive Hybrid route, so
# the fixture exercises Aether's own packet harvester, libass overlay, carrier
# clock, seek-generation reset, and AVKit custom subtitle menu.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-$REPO_ROOT/Fixtures/hybrid-vp9-ass-overlay.mkv}"
DURATION_SECONDS="${AETHER_ACCEPTANCE_DURATION_SECONDS:-32}"
WORK_DIRECTORY="$(mktemp -d)"
ASS_SOURCE="$WORK_DIRECTORY/acceptance.ass"

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

mkdir -p "$(dirname "$OUTPUT")"
python3 - "$ASS_SOURCE" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_text(
    """[Script Info]
ScriptType: v4.00+
PlayResX: 1280
PlayResY: 720
WrapStyle: 0

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Helvetica,54,&H00FFFFFF,&H000000FF,&H00141414,&H78000000,0,0,0,0,100,100,0,0,1,3,1,2,40,40,48,1
Style: Sign,Helvetica,48,&H0032D7FF,&H000000FF,&H00101010,&H50000000,-1,0,0,0,100,100,1,0,1,2,1,8,40,40,52,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:07.50,Default,,0,0,0,,{\\i1}Aether styled subtitle{\\i0} — startup
Dialogue: 1,0:00:08.00,0:00:15.50,Sign,,0,0,0,,{\\pos(640,110)\\bord4}AVKit custom menu + libass
Dialogue: 0,0:00:16.00,0:00:23.50,Default,,0,0,0,,{\\c&H66FF66&}Seek generation rebuilt{\\c}
Dialogue: 0,0:00:24.00,0:00:31.00,Default,,0,0,0,,{\\b1}Track-local overlay remains clock-bound{\\b0}
""",
    encoding="utf-8",
)
PY

ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=duration=$DURATION_SECONDS:size=1280x720:rate=24" \
    -f lavfi -i "sine=frequency=523.25:sample_rate=48000:duration=$DURATION_SECONDS" \
    -i "$ASS_SOURCE" \
    -map 0:v:0 -map 1:a:0 -map 2:s:0 \
    -metadata:s:a:0 language=eng \
    -metadata:s:s:0 language=eng \
    -metadata:s:s:0 title="Aether Styled English" \
    -disposition:s:0 default \
    -c:v libvpx-vp9 -deadline good -cpu-used 4 -row-mt 1 \
    -b:v 1800k -g 96 -pix_fmt yuv420p \
    -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
    -c:a aac -b:a 192k -ar 48000 -ac 2 \
    -c:s ass \
    -t "$DURATION_SECONDS" \
    "$OUTPUT"

PROVENANCE="$OUTPUT.provenance.txt"
CHECKSUM="$OUTPUT.sha256"
{
    echo "generator=Scripts/generate-hybrid-overlay-subtitle-fixture.sh"
    echo "durationSeconds=$DURATION_SECONDS"
    echo "video=VP9 Profile 0 SDR BT.709"
    echo "audio=AAC stereo eng"
    echo "subtitle=ASS styled eng default"
    echo "ffmpegVersion=$(ffmpeg -version | head -n 1)"
} > "$PROVENANCE"
shasum -a 256 "$OUTPUT" "$PROVENANCE" > "$CHECKSUM"

echo "Generated: $OUTPUT"
echo "Identity:  $CHECKSUM"
