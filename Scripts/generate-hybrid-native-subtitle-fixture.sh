#!/usr/bin/env bash
#
# Generate a copyright-clean, finite VP9 Matroska fixture with one SubRip
# track. VP9 selects the progressive Hybrid route while the plain-text track
# must be exposed as an AVPlayer native WebVTT rendition, never as an Aether
# overlay.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-$REPO_ROOT/Fixtures/hybrid-vp9-subrip-native.mkv}"
DURATION_SECONDS="${AETHER_ACCEPTANCE_DURATION_SECONDS:-32}"
WORK_DIRECTORY="$(mktemp -d)"
SRT_SOURCE="$WORK_DIRECTORY/acceptance.srt"

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
python3 - "$SRT_SOURCE" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_text(
    """1
00:00:01,000 --> 00:00:07,500
Aether native subtitle — startup

2
00:00:08,000 --> 00:00:15,500
AVKit legible WebVTT rendition

3
00:00:16,000 --> 00:00:23,500
Seek generation remains clock-bound

4
00:00:24,000 --> 00:00:31,000
Off and reselect remain explicit
""",
    encoding="utf-8",
)
PY

ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=duration=$DURATION_SECONDS:size=1280x720:rate=24" \
    -f lavfi -i "sine=frequency=659.25:sample_rate=48000:duration=$DURATION_SECONDS" \
    -i "$SRT_SOURCE" \
    -map 0:v:0 -map 1:a:0 -map 2:s:0 \
    -metadata:s:a:0 language=eng \
    -metadata:s:s:0 language=eng \
    -metadata:s:s:0 title="Aether Native English" \
    -disposition:s:0 default \
    -c:v libvpx-vp9 -deadline good -cpu-used 4 -row-mt 1 \
    -b:v 1800k -g 96 -pix_fmt yuv420p \
    -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
    -c:a aac -b:a 192k -ar 48000 -ac 2 \
    -c:s srt \
    -t "$DURATION_SECONDS" \
    "$OUTPUT"

PROVENANCE="$OUTPUT.provenance.txt"
CHECKSUM="$OUTPUT.sha256"
{
    echo "generator=Scripts/generate-hybrid-native-subtitle-fixture.sh"
    echo "durationSeconds=$DURATION_SECONDS"
    echo "video=VP9 Profile 0 SDR BT.709"
    echo "audio=AAC stereo eng"
    echo "subtitle=SubRip plain text eng default"
    echo "ffmpegVersion=$(ffmpeg -version | head -n 1)"
} > "$PROVENANCE"
shasum -a 256 "$OUTPUT" "$PROVENANCE" > "$CHECKSUM"

echo "Generated: $OUTPUT"
echo "Identity:  $CHECKSUM"
