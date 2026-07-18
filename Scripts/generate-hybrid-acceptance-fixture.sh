#!/usr/bin/env bash
#
# Generate a copyright-clean, seekable HEVC/hev1 fMP4 HLS fixture for
# AetherHybridAcceptance. The output is local-only under the gitignored
# Fixtures/ tree. It contains one real video rendition and two selectable AAC
# audio renditions so the same graph can exercise startup, seek, pause/rate,
# generation flush, AVKit media selection, and SDR/HDR device admission.
#
# Usage:
#   AETHER_ACCEPTANCE_VIDEO_FORMAT=sdr|hdr10|hdr10plus|hlg|dolbyvision84 \
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
HDR10_PLUS_FIRST_FRAME_SECONDS="${AETHER_ACCEPTANCE_HDR10_PLUS_FIRST_FRAME_SECONDS:-12}"
HDR10_PLUS_FIRST_FRAME_POC=""
HDR10_PLUS_FIRST_DYNAMIC_SEGMENT=""
HDR10_PLUS_NALU_FILE=""
DOVI_TOOL="${AETHER_ACCEPTANCE_DOVI_TOOL:-}"
DOVI_TOOL_VERSION=""
DOVI_TOOL_SHA256=""
DOLBY_VISION_CONFIGURATION_PROBE=""

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
VIDEO_FRAME_COUNT="$(
    awk -v duration="$VIDEO_DURATION_SECONDS" \
        -v rate="$VIDEO_FRAME_RATE" '
        BEGIN {
            split(rate, parts, "/")
            fps = length(parts) == 2 ? parts[1] / parts[2] : rate
            printf "%d", int((duration * fps) + 0.5)
        }'
)"

if ! command -v ffmpeg >/dev/null 2>&1 \
        || ! command -v ffprobe >/dev/null 2>&1; then
    echo "ERROR: ffmpeg and ffprobe are required" >&2
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
    hdr10plus)
        VIDEO_DESCRIPTION="HEVC Main10 hev1 HDR10+ BT.2020/PQ MDCV/CLLI with late ST 2094-40 T.35"
        HDR10_PLUS_NALU_FILE="$OUTPUT/HDR10PLUS_NALU.txt"
        HDR10_PLUS_FIRST_FRAME_POC="$(
            awk -v seconds="$HDR10_PLUS_FIRST_FRAME_SECONDS" \
                -v rate="$VIDEO_FRAME_RATE" '
                BEGIN {
                    split(rate, parts, "/")
                    fps = length(parts) == 2 ? parts[1] / parts[2] : rate
                    value = seconds * fps
                    poc = int(value)
                    if (poc < value - 0.000000001) {
                        poc += 1
                    }
                    printf "%d", poc
                }'
        )"
        VIDEO_FRAME_COUNT="$(
            awk -v duration="$VIDEO_DURATION_SECONDS" \
                -v rate="$VIDEO_FRAME_RATE" '
                BEGIN {
                    split(rate, parts, "/")
                    fps = length(parts) == 2 ? parts[1] / parts[2] : rate
                    printf "%d", int((duration * fps) + 0.5)
                }'
        )"
        if ! awk -v first="$HDR10_PLUS_FIRST_FRAME_SECONDS" \
                -v segment="$HLS_SEGMENT_SECONDS" \
                'BEGIN { exit !(first > segment) }'; then
            echo "ERROR: HDR10+ first-frame time must be after the first HLS segment" >&2
            exit 1
        fi
        if (( HDR10_PLUS_FIRST_FRAME_POC >= VIDEO_FRAME_COUNT )); then
            echo "ERROR: HDR10+ first-frame time is outside the fixture duration" >&2
            exit 1
        fi
        VIDEO_CODEC_ARGS=(
            -c:v libx265
            -preset ultrafast
            -tune zerolatency
            -profile:v main10
            -pix_fmt yuv420p10le
            -color_primaries bt2020
            -color_trc smpte2084
            -colorspace bt2020nc
            -x265-params "repeat-headers=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:hdr10=1:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400:nalu-file=$HDR10_PLUS_NALU_FILE"
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
    dolbyvision84)
        if [[ "$GEOMETRY_MODE" != "standard" ]]; then
            echo "ERROR: Dolby Vision P8.4 acceptance currently requires standard geometry" >&2
            exit 1
        fi
        if [[ -z "$DOVI_TOOL" ]]; then
            DOVI_TOOL="$(command -v dovi_tool || true)"
        fi
        if [[ -z "$DOVI_TOOL" || ! -x "$DOVI_TOOL" ]]; then
            echo "ERROR: AETHER_ACCEPTANCE_DOVI_TOOL must name an executable dovi_tool" >&2
            exit 1
        fi
        DOVI_TOOL_VERSION="$($DOVI_TOOL --version)"
        DOVI_TOOL_SHA256="$(shasum -a 256 "$DOVI_TOOL" | awk '{print $1}')"
        VIDEO_DESCRIPTION="Dolby Vision Profile 8.4 HEVC Main10 hev1 HLG BT.2020 with exact dvvC"
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
if [[ "$VIDEO_FORMAT" == "hdr10plus" ]]; then
    # x265 consumes one nalu-file row per POC. A benign 18-byte
    # user-data-unregistered payload occupies pre-startup frames. From the
    # selected POC onward, each frame carries one deterministic,
    # FFmpeg-validated HDR10+ T.35 payload. The base64 representation has
    # padding; x265's reader writes a 24-byte payload, whose two trailing zero
    # bytes are accepted by the ST 2094-40 parser.
    for ((poc = 0; poc < VIDEO_FRAME_COUNT; poc += 1)); do
        if (( poc < HDR10_PLUS_FIRST_FRAME_POC )); then
            echo "$poc PREFIX 39/5 AAECAwQFBgcICQoLDA0OD3h4"
        else
            echo "$poc PREFIX 39/4 tQA8AAEEAUAAH0AAAAAAAAAAAAAAAA=="
        fi
    done > "$HDR10_PLUS_NALU_FILE"
fi
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

if [[ "$VIDEO_FORMAT" == "dolbyvision84" ]]; then
    DOVI_GENERATOR_CONFIG="$OUTPUT/.dolby-vision-profile84-generator.json"
    DOVI_BASE_HEVC="$OUTPUT/.dolby-vision-profile84-base.hevc"
    DOVI_RPU="$OUTPUT/.dolby-vision-profile84.rpu"
    DOVI_INJECTED_HEVC="$OUTPUT/.dolby-vision-profile84-injected.hevc"
    DOVI_REMUXED_SOURCE="$OUTPUT/.dolby-vision-profile84-remuxed.mp4"
    python3 - "$DOVI_GENERATOR_CONFIG" "$VIDEO_FRAME_COUNT" <<'PY'
import json
import sys

path, length = sys.argv[1], int(sys.argv[2])
payload = {
    "cm_version": "V40",
    "profile": "8.4",
    "length": length,
    "level5": {
        "active_area_left_offset": 0,
        "active_area_right_offset": 0,
        "active_area_top_offset": 0,
        "active_area_bottom_offset": 0,
    },
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
    ffmpeg -hide_banner -loglevel error -y \
        -i "$VIDEO_SOURCE" \
        -map 0:v:0 -c:v copy \
        -bsf:v hevc_mp4toannexb \
        -f hevc "$DOVI_BASE_HEVC"
    "$DOVI_TOOL" generate \
        -j "$DOVI_GENERATOR_CONFIG" \
        -o "$DOVI_RPU"
    "$DOVI_TOOL" inject-rpu \
        -i "$DOVI_BASE_HEVC" \
        --rpu-in "$DOVI_RPU" \
        -o "$DOVI_INJECTED_HEVC"
    ffmpeg -hide_banner -loglevel error -y \
        -r "$VIDEO_FRAME_RATE" \
        -i "$DOVI_INJECTED_HEVC" \
        -map 0:v:0 -c:v copy \
        -bsf:v dovi_rpu=compression=none \
        -tag:v hev1 \
        -strict unofficial \
        -movflags +faststart \
        "$DOVI_REMUXED_SOURCE"
    mv "$DOVI_REMUXED_SOURCE" "$VIDEO_SOURCE"
    rm "$DOVI_GENERATOR_CONFIG" \
        "$DOVI_BASE_HEVC" \
        "$DOVI_RPU" \
        "$DOVI_INJECTED_HEVC"
fi

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
        -strict unofficial \
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
        -strict unofficial \
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

if [[ "$VIDEO_FORMAT" == "hdr10plus" ]]; then
    VIDEO_INIT="$OUTPUT/video/init_0.mp4"
    FIRST_VIDEO_SEGMENT="$OUTPUT/video/segment_000.m4s"
    if [[ ! -f "$VIDEO_INIT" || ! -f "$FIRST_VIDEO_SEGMENT" ]]; then
        echo "ERROR: HDR10+ verification could not find the video init/first segment" >&2
        exit 1
    fi
    FIRST_SEGMENT_PROBE="$(
        ffprobe -v error -select_streams v:0 -show_frames \
            -show_entries frame=side_data_list -of json \
            "concat:$VIDEO_INIT|$FIRST_VIDEO_SEGMENT"
    )"
    if [[ "$FIRST_SEGMENT_PROBE" == *"HDR Dynamic Metadata SMPTE2094-40"* ]]; then
        echo "ERROR: HDR10+ metadata appeared in the first segment; fixture is not late-metadata evidence" >&2
        exit 1
    fi
    for segment in "$OUTPUT"/video/segment_*.m4s; do
        if [[ "$segment" == "$FIRST_VIDEO_SEGMENT" ]]; then
            continue
        fi
        SEGMENT_PROBE="$(
            ffprobe -v error -select_streams v:0 -show_frames \
                -show_entries frame=side_data_list -of json \
                "concat:$VIDEO_INIT|$segment"
        )"
        if [[ "$SEGMENT_PROBE" == *"HDR Dynamic Metadata SMPTE2094-40"* ]]; then
            HDR10_PLUS_FIRST_DYNAMIC_SEGMENT="$(basename "$segment")"
            break
        fi
    done
    if [[ -z "$HDR10_PLUS_FIRST_DYNAMIC_SEGMENT" ]]; then
        echo "ERROR: no post-startup segment contains FFmpeg-validated HDR10+ metadata" >&2
        exit 1
    fi
fi

if [[ "$VIDEO_FORMAT" == "dolbyvision84" ]]; then
    VIDEO_INIT="$OUTPUT/video/init_0.mp4"
    FIRST_VIDEO_SEGMENT="$OUTPUT/video/segment_000.m4s"
    if [[ ! -f "$VIDEO_INIT" || ! -f "$FIRST_VIDEO_SEGMENT" ]]; then
        echo "ERROR: Dolby Vision P8.4 verification could not find video init/first segment" >&2
        exit 1
    fi
    DOLBY_VISION_CONFIGURATION_PROBE="$(
        ffprobe -v error -select_streams v:0 \
            -show_streams \
            -of json "concat:$VIDEO_INIT|$FIRST_VIDEO_SEGMENT"
    )"
    if [[ "$DOLBY_VISION_CONFIGURATION_PROBE" != *'"codec_tag_string": "hev1"'* \
            || "$DOLBY_VISION_CONFIGURATION_PROBE" != *'"profile": "Main 10"'* \
            || "$DOLBY_VISION_CONFIGURATION_PROBE" != *'"color_space": "bt2020nc"'* \
            || "$DOLBY_VISION_CONFIGURATION_PROBE" != *'"color_transfer": "arib-std-b67"'* \
            || "$DOLBY_VISION_CONFIGURATION_PROBE" != *'"color_primaries": "bt2020"'* \
            || "$DOLBY_VISION_CONFIGURATION_PROBE" != *'"dv_profile": 8'* \
            || "$DOLBY_VISION_CONFIGURATION_PROBE" != *'"rpu_present_flag": 1'* \
            || "$DOLBY_VISION_CONFIGURATION_PROBE" != *'"el_present_flag": 0'* \
            || "$DOLBY_VISION_CONFIGURATION_PROBE" != *'"bl_present_flag": 1'* \
            || "$DOLBY_VISION_CONFIGURATION_PROBE" != *'"dv_bl_signal_compatibility_id": 4'* \
            || "$DOLBY_VISION_CONFIGURATION_PROBE" != *'"dv_md_compression": "none"'* ]]; then
        echo "ERROR: generated fixture does not match the exact Dolby Vision Profile 8.4 contract" >&2
        exit 1
    fi
    FIRST_FRAME_PROBE="$(
        ffprobe -v error -select_streams v:0 \
            -show_frames -read_intervals '%+#1' \
            -show_entries frame=side_data_list \
            -of json "concat:$VIDEO_INIT|$FIRST_VIDEO_SEGMENT"
    )"
    if [[ "$FIRST_FRAME_PROBE" != *'"side_data_type": "Dolby Vision RPU Data"'* ]]; then
        echo "ERROR: Dolby Vision P8.4 first decoded frame has no FFmpeg-recognized RPU" >&2
        exit 1
    fi
fi

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
    if [[ "$VIDEO_FORMAT" == "hdr10plus" ]]; then
        echo "hdr10PlusFirstFrameSeconds=$HDR10_PLUS_FIRST_FRAME_SECONDS"
        echo "hdr10PlusFirstFramePOC=$HDR10_PLUS_FIRST_FRAME_POC"
        echo "hdr10PlusFirstDynamicSegment=$HDR10_PLUS_FIRST_DYNAMIC_SEGMENT"
        echo "hdr10PlusT35Base64=tQA8AAEEAUAAH0AAAAAAAAAAAAAAAA=="
        echo "hdr10PlusVerification=first segment has no HDR Dynamic Metadata; named later segment is FFmpeg-recognized SMPTE2094-40"
    fi
    if [[ "$VIDEO_FORMAT" == "dolbyvision84" ]]; then
        echo "dolbyVisionProfile=8.4"
        echo "dolbyVisionConfiguration=version 1.0,profile 8,compatibility 4,RPU 1,EL 0,BL 1,compression none"
        echo "dolbyVisionBaseLayer=HEVC Main10,hev1,BT.2020,HLG,bt2020nc"
        echo "dolbyVisionRPUVerification=first frame has FFmpeg-recognized Dolby Vision RPU Data"
        echo "doviToolVersion=$DOVI_TOOL_VERSION"
        echo "doviToolSHA256=$DOVI_TOOL_SHA256"
    fi
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
