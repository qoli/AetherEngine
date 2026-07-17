#!/usr/bin/env bash
#
# Generate a copyright-clean, seekable HEVC/hev1 fMP4 HLS fixture for
# AetherHybridAcceptance. The output is local-only under the gitignored
# Fixtures/ tree. It contains one real video rendition and two selectable AAC
# audio renditions so the same graph can exercise startup, seek, pause/rate,
# generation flush, AVKit media selection, and SDR/HDR device admission.
#
# Usage:
#   AETHER_ACCEPTANCE_VIDEO_FORMAT=sdr|hdr10|hlg \
#   AETHER_ACCEPTANCE_GEOMETRY_MODE=standard|clean_aperture|sar_4_3| \
#     rotation_90|rotation_180|rotation_270|fps_24000_1001|fps_15 \
#   AETHER_ACCEPTANCE_ATMOS_EC3_INPUT=/path/to/licensed-ddp-joc.ec3 \
#   AETHER_ACCEPTANCE_WEBVTT_SUBTITLES=1 \
#     ./Scripts/generate-hybrid-acceptance-fixture.sh [output-directory]
#
# The script deliberately refuses to overwrite an existing output. Fixture
# identity must remain stable during an acceptance run.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VIDEO_FORMAT="${AETHER_ACCEPTANCE_VIDEO_FORMAT:-sdr}"
GEOMETRY_MODE="${AETHER_ACCEPTANCE_GEOMETRY_MODE:-standard}"
if [[ $# -ge 1 ]]; then
    OUTPUT="$1"
elif [[ "$GEOMETRY_MODE" == "standard" ]]; then
    OUTPUT="$REPO_ROOT/Fixtures/hybrid-$VIDEO_FORMAT-hev1-hls"
else
    OUTPUT="$REPO_ROOT/Fixtures/hybrid-$VIDEO_FORMAT-$GEOMETRY_MODE-hev1-hls"
fi
DURATION_SECONDS="${AETHER_ACCEPTANCE_DURATION_SECONDS:-120}"
HLS_SEGMENT_SECONDS="${AETHER_ACCEPTANCE_HLS_SEGMENT_SECONDS:-4}"
VIDEO_BITRATE="${AETHER_ACCEPTANCE_VIDEO_BITRATE:-2500k}"
VIDEO_MAXRATE="${AETHER_ACCEPTANCE_VIDEO_MAXRATE:-3000k}"
VIDEO_DESCRIPTION=""
VIDEO_CODEC_ARGS=()
VIDEO_BITSTREAM_FILTER_ARGS=(-bsf:v null)
VIDEO_SOURCE_SIZE="1920x1080"
VIDEO_FRAME_RATE="24"
VIDEO_SAMPLE_ASPECT_RATIO="1/1"
VIDEO_ROTATION_DEGREES="0"
ATMOS_EC3_INPUT="${AETHER_ACCEPTANCE_ATMOS_EC3_INPUT:-}"
ATMOS_INPUT_SHA256=""
ATMOS_INPUT_PROBE=""
WEBVTT_SUBTITLES="${AETHER_ACCEPTANCE_WEBVTT_SUBTITLES:-0}"

if [[ "$WEBVTT_SUBTITLES" != "0" && "$WEBVTT_SUBTITLES" != "1" ]]; then
    echo "ERROR: AETHER_ACCEPTANCE_WEBVTT_SUBTITLES must be 0 or 1" >&2
    exit 1
fi

case "$GEOMETRY_MODE" in
    standard)
        ;;
    clean_aperture)
        VIDEO_SOURCE_SIZE="1920x1088"
        VIDEO_BITSTREAM_FILTER_ARGS=(
            -bsf:v hevc_metadata=crop_bottom=8
        )
        ;;
    sar_4_3)
        VIDEO_SOURCE_SIZE="720x576"
        VIDEO_FRAME_RATE="25"
        VIDEO_SAMPLE_ASPECT_RATIO="16/15"
        ;;
    rotation_90)
        VIDEO_SOURCE_SIZE="1280x720"
        VIDEO_ROTATION_DEGREES="90"
        ;;
    rotation_180)
        VIDEO_SOURCE_SIZE="1280x720"
        VIDEO_ROTATION_DEGREES="180"
        ;;
    rotation_270)
        VIDEO_SOURCE_SIZE="1280x720"
        VIDEO_ROTATION_DEGREES="270"
        ;;
    fps_24000_1001)
        VIDEO_SOURCE_SIZE="1280x720"
        VIDEO_FRAME_RATE="24000/1001"
        ;;
    fps_15)
        VIDEO_SOURCE_SIZE="1280x720"
        VIDEO_FRAME_RATE="15"
        ;;
    *)
        echo "ERROR: unsupported AETHER_ACCEPTANCE_GEOMETRY_MODE: $GEOMETRY_MODE" >&2
        exit 1
        ;;
esac

VIDEO_GOP="$(
    awk -v rate="$VIDEO_FRAME_RATE" \
        -v segment="$HLS_SEGMENT_SECONDS" '
        BEGIN {
            split(rate, parts, "/")
            fps = length(parts) == 2 ? parts[1] / parts[2] : rate
            printf "%d", (fps * segment) + 0.5
        }'
)"
if [[ "$GEOMETRY_MODE" == "fps_24000_1001" ]]; then
    # 512 video frames equal exactly 1001 AAC frames at 48 kHz. Round the
    # diagnostic fixture up to that common boundary so neither rendition
    # invents a final partial segment or lies about its media duration.
    VIDEO_DURATION_SECONDS="$(
        awk -v duration="$DURATION_SECONDS" '
        BEGIN {
            quantum = (512 * 1001) / 24000
            multiples = int(duration / quantum)
            if (multiples * quantum < duration - 0.000000001) {
                multiples += 1
            }
            if (multiples < 1) {
                multiples = 1
            }
            printf "%.9f", multiples * quantum
        }'
    )"
else
    VIDEO_DURATION_SECONDS="$(
        awk -v duration="$DURATION_SECONDS" \
            -v rate="$VIDEO_FRAME_RATE" '
            BEGIN {
                split(rate, parts, "/")
                fps = length(parts) == 2 ? parts[1] / parts[2] : rate
                exactFrames = duration * fps
                frames = int(exactFrames)
                if (frames < exactFrames - 0.000000001) {
                    frames += 1
                }
                printf "%.9f", frames / fps
            }'
    )"
fi
AUDIO_DURATION_SECONDS="$(
    awk -v duration="$VIDEO_DURATION_SECONDS" \
        'BEGIN { printf "%.9f", duration - (1024 / 48000) }'
)"

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ERROR: ffmpeg is required" >&2
    exit 1
fi

if [[ -n "$ATMOS_EC3_INPUT" ]]; then
    if [[ ! -f "$ATMOS_EC3_INPUT" ]]; then
        echo "ERROR: AETHER_ACCEPTANCE_ATMOS_EC3_INPUT is not a file" >&2
        exit 1
    fi
    ATMOS_INPUT_PROBE="$(
        ffprobe -v error -select_streams a:0 \
            -show_entries stream=codec_name,profile,sample_rate,channels \
            -of default=noprint_wrappers=1 "$ATMOS_EC3_INPUT"
    )"
    if [[ "$ATMOS_INPUT_PROBE" != *"codec_name=eac3"* \
            || "$ATMOS_INPUT_PROBE" != *"Atmos"* ]]; then
        echo "ERROR: supplied audio is not an FFmpeg-recognized E-AC-3 Atmos/JOC stream" >&2
        exit 1
    fi
    ATMOS_INPUT_SHA256="$(shasum -a 256 "$ATMOS_EC3_INPUT" | awk '{print $1}')"
fi

case "$VIDEO_FORMAT" in
    sdr)
        VIDEO_DESCRIPTION="HEVC Main hev1 SDR BT.709"
        VIDEO_CODEC_ARGS=(
            -c:v hevc_videotoolbox
            -profile:v main
            -pix_fmt yuv420p
            -color_primaries bt709
            -color_trc bt709
            -colorspace bt709
        )
        ;;
    hdr10)
        VIDEO_DESCRIPTION="HEVC Main10 hev1 HDR10 BT.2020/PQ MDCV/CLLI"
        VIDEO_CODEC_ARGS=(
            -c:v libx265
            -preset ultrafast
            -tune zerolatency
            -profile:v main10
            -pix_fmt yuv420p10le
            -color_primaries bt2020
            -color_trc smpte2084
            -colorspace bt2020nc
            -x265-params 'repeat-headers=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:hdr10=1:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400'
        )
        ;;
    hlg)
        VIDEO_DESCRIPTION="HEVC Main10 hev1 HLG BT.2020/ARIB-STD-B67"
        VIDEO_CODEC_ARGS=(
            -c:v libx265
            -preset ultrafast
            -tune zerolatency
            -profile:v main10
            -pix_fmt yuv420p10le
            -color_primaries bt2020
            -color_trc arib-std-b67
            -colorspace bt2020nc
            -x265-params 'repeat-headers=1:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc'
        )
        ;;
    *)
        echo "ERROR: unsupported AETHER_ACCEPTANCE_VIDEO_FORMAT: $VIDEO_FORMAT" >&2
        exit 1
        ;;
esac

if [[ -e "$OUTPUT" ]]; then
    echo "ERROR: acceptance fixture output already exists: $OUTPUT" >&2
    exit 1
fi

mkdir -p "$OUTPUT"
VIDEO_SOURCE="$OUTPUT/.encoded-video.mp4"
VIDEO_INPUT_ARGS=(-noautorotate)
if [[ "$VIDEO_ROTATION_DEGREES" != "0" ]]; then
    VIDEO_INPUT_ARGS+=(
        # FFmpeg's input option is counter-clockwise; Aether's public frame
        # contract is canonical clockwise.
        -display_rotation:v:0 "-$VIDEO_ROTATION_DEGREES"
    )
fi

ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=duration=$VIDEO_DURATION_SECONDS:size=$VIDEO_SOURCE_SIZE:rate=$VIDEO_FRAME_RATE" \
    -vf "setsar=$VIDEO_SAMPLE_ASPECT_RATIO" \
    "${VIDEO_CODEC_ARGS[@]}" \
    -tag:v hev1 \
    -b:v "$VIDEO_BITRATE" \
    -maxrate "$VIDEO_MAXRATE" \
    -bufsize 6000k \
    -g "$VIDEO_GOP" \
    -keyint_min "$VIDEO_GOP" \
    -sc_threshold 0 \
    "${VIDEO_BITSTREAM_FILTER_ARGS[@]}" \
    -an \
    "$VIDEO_SOURCE"

if [[ -n "$ATMOS_EC3_INPUT" ]]; then
    ffmpeg -hide_banner -loglevel error -y \
        "${VIDEO_INPUT_ARGS[@]}" -i "$VIDEO_SOURCE" \
        -i "$ATMOS_EC3_INPUT" \
        -f lavfi -i "sine=frequency=880:sample_rate=48000:duration=$AUDIO_DURATION_SECONDS" \
        -map 0:v:0 -map 1:a:0 -map 2:a:0 \
        -metadata:s:a:0 language=eng \
        -metadata:s:a:1 language=spa \
        -c:v copy \
        -tag:v hev1 \
        -c:a:0 copy \
        -c:a:1 aac \
        -b:a:1 192k \
        -ar:a:1 48000 \
        -ac:a:1 2 \
        -t "$VIDEO_DURATION_SECONDS" \
        -f hls \
        -hls_time "$HLS_SEGMENT_SECONDS" \
        -hls_playlist_type vod \
        -hls_segment_type fmp4 \
        -hls_flags independent_segments+temp_file \
        -master_pl_name master.m3u8 \
        -var_stream_map "v:0,agroup:audio,name:video a:0,agroup:audio,language:eng,default:yes,name:atmos a:1,agroup:audio,language:spa,name:stereo" \
        -hls_segment_filename "$OUTPUT/%v/segment_%03d.m4s" \
        "$OUTPUT/%v/index.m3u8"
    AUDIO_RENDITIONS="EAC3 JOC Atmos eng stream-copy,AAC stereo spa"
else
    ffmpeg -hide_banner -loglevel error -y \
        "${VIDEO_INPUT_ARGS[@]}" -i "$VIDEO_SOURCE" \
        -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=$AUDIO_DURATION_SECONDS" \
        -f lavfi -i "sine=frequency=880:sample_rate=48000:duration=$AUDIO_DURATION_SECONDS" \
        -map 0:v:0 -map 1:a:0 -map 2:a:0 \
        -metadata:s:a:0 language=eng \
        -metadata:s:a:1 language=spa \
        -c:v copy \
        -tag:v hev1 \
        -c:a aac \
        -b:a 192k \
        -ar 48000 \
        -ac 2 \
        -f hls \
        -hls_time "$HLS_SEGMENT_SECONDS" \
        -hls_playlist_type vod \
        -hls_segment_type fmp4 \
        -hls_flags independent_segments+temp_file \
        -master_pl_name master.m3u8 \
        -var_stream_map "v:0,agroup:audio,name:video a:0,agroup:audio,language:eng,default:yes,name:english a:1,agroup:audio,language:spa,name:spanish" \
        -hls_segment_filename "$OUTPUT/%v/segment_%03d.m4s" \
        "$OUTPUT/%v/index.m3u8"
    AUDIO_RENDITIONS="AAC stereo eng,AAC stereo spa"
fi

rm "$VIDEO_SOURCE"

NORMALIZER_ARGS=("$OUTPUT")
if [[ -n "$ATMOS_EC3_INPUT" ]]; then
    NORMALIZER_ARGS+=(--atmos-rendition atmos)
fi
python3 "$REPO_ROOT/Scripts/normalize-hybrid-acceptance-playlist-durations.py" \
    "${NORMALIZER_ARGS[@]}"

if [[ "$WEBVTT_SUBTITLES" == "1" ]]; then
    python3 "$REPO_ROOT/Scripts/add-hybrid-acceptance-webvtt.py" "$OUTPUT"
fi

{
    echo "generator=Scripts/generate-hybrid-acceptance-fixture.sh"
    echo "requestedDurationSeconds=$DURATION_SECONDS"
    echo "videoDurationSeconds=$VIDEO_DURATION_SECONDS"
    echo "hlsSegmentSeconds=$HLS_SEGMENT_SECONDS"
    echo "videoBitrate=$VIDEO_BITRATE"
    echo "videoMaxrate=$VIDEO_MAXRATE"
    echo "videoFormat=$VIDEO_FORMAT"
    echo "video=$VIDEO_DESCRIPTION"
    echo "geometryMode=$GEOMETRY_MODE"
    echo "sourceSize=$VIDEO_SOURCE_SIZE"
    echo "frameRate=$VIDEO_FRAME_RATE"
    echo "sampleAspectRatio=$VIDEO_SAMPLE_ASPECT_RATIO"
    echo "canonicalClockwiseRotationDegrees=$VIDEO_ROTATION_DEGREES"
    echo "containerCounterClockwiseRotationDegrees=-$VIDEO_ROTATION_DEGREES"
    echo "audioRenditions=$AUDIO_RENDITIONS"
    echo "nativeWebVTTRenditions=$WEBVTT_SUBTITLES"
    if [[ -n "$ATMOS_EC3_INPUT" ]]; then
        echo "atmosInputSHA256=$ATMOS_INPUT_SHA256"
        while IFS= read -r line; do
            echo "atmosInputProbe=$line"
        done <<< "$ATMOS_INPUT_PROBE"
        echo "atmosInputPolicy=user-supplied licensed test vector; source path and source bytes excluded"
    fi
    echo "playlistDurationNormalization=bounded 90kHz EXTINF rounding only"
    echo "ffmpegVersion=$(ffmpeg -version | head -n 1)"
} > "$OUTPUT/PROVENANCE.txt"

(
    cd "$OUTPUT"
    find . -type f ! -name SHA256SUMS -print0 \
        | sort -z \
        | xargs -0 shasum -a 256 > SHA256SUMS
)

echo "Generated: $OUTPUT/master.m3u8"
echo "Identity:  $OUTPUT/SHA256SUMS"
