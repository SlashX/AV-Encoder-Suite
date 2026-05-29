#!/usr/bin/env bash
# v57: helper codec_tag_for_container + integrare run_encode_loop + burnin/telemetry/audio
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
source "$SCRIPT_DIR/av_common.sh"

# ── Helper functional ────────────────────────────────────────────────
assert_eq "-tag:v hvc1" "$(codec_tag_for_container hevc mp4)" "hevc/mp4 → hvc1"
assert_eq "-tag:v av01" "$(codec_tag_for_container av1 mp4)"  "av1/mp4 → av01"
assert_eq "-tag:v avc1" "$(codec_tag_for_container h264 mov)" "h264/mov → avc1"
assert_eq "-tag:v hvc1" "$(codec_tag_for_container hevc m4v)" "hevc/m4v → hvc1"
assert_eq "-tag:v hvc1" "$(codec_tag_for_container hevc MP4)" "case-insensitive MP4"
assert_eq ""            "$(codec_tag_for_container hevc mkv)" "mkv → no tag"
assert_eq ""            "$(codec_tag_for_container hevc webm)" "webm → no tag"
assert_eq ""            "$(codec_tag_for_container prores mov)" "prores → no tag (ffmpeg default OK)"
assert_eq ""            "$(codec_tag_for_container "" mp4)"    "empty codec → no tag"

# ── Integrare in run_encode_loop ────────────────────────────────────
COMMON_TXT=$(cat "$SCRIPT_DIR/av_common.sh")
assert_contains "$COMMON_TXT" "CODEC_TAG=\$(codec_tag_for_container" \
    "run_encode_loop seteaza CODEC_TAG"
assert_contains "$COMMON_TXT" "\$CODEC_TAG \$CONTAINER_FLAGS" \
    "CODEC_TAG injectat in eval single-pass"
# 2 ocurente: 1 single-pass + 1 in run_2pass_encode
CT_COUNT=$(grep -c "\$CODEC_TAG \$CONTAINER_FLAGS" "$SCRIPT_DIR/av_common.sh")
assert_eq "2" "$CT_COUNT" "CODEC_TAG injectat in ambele eval (single + 2-pass)"

# ── av_burnin: 5 sites + ENC_CODEC_KEY mapping ──────────────────────
BURNIN_TXT=$(cat "$SCRIPT_DIR/av_burnin.sh")
assert_contains "$BURNIN_TXT" 'ENC_CODEC_KEY="hevc"' "ask_encoder seteaza ENC_CODEC_KEY=hevc"
assert_contains "$BURNIN_TXT" 'ENC_CODEC_KEY="h264"' "ask_encoder seteaza ENC_CODEC_KEY=h264"
assert_contains "$BURNIN_TXT" 'ENC_CODEC_KEY="av1"'  "ask_encoder seteaza ENC_CODEC_KEY=av1"
BURNIN_DECL=$(grep -c '_codec_tag=$(codec_tag_for_container' "$SCRIPT_DIR/av_burnin.sh")
assert_eq "4" "$BURNIN_DECL" "av_burnin.sh: 4 declaratii _codec_tag (HUD/SRT/ASS + 1 shared pt img)"
BURNIN_USES=$(grep -c '\$_codec_tag -movflags' "$SCRIPT_DIR/av_burnin.sh")
assert_eq "5" "$BURNIN_USES" "av_burnin.sh: 5 utilizari \$_codec_tag in ffmpeg (toate 5 flows)"

# ── av_telemetry + av_encoder_audio ─────────────────────────────────
TELEM_TXT=$(cat "$SCRIPT_DIR/av_telemetry.sh")
assert_contains "$TELEM_TXT" "_telem_tag=\$(codec_tag_for_container" \
    "av_telemetry.sh: codec_tag aplicat in embed-lossless mp4/mov"
AUDIO_TXT=$(cat "$SCRIPT_DIR/av_encoder_audio.sh")
assert_contains "$AUDIO_TXT" "_audio_codec_tag=\$(codec_tag_for_container" \
    "av_encoder_audio.sh: codec_tag aplicat"

# ── Empirical integration (skip if no ffmpeg) ───────────────────────
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    TMP=$(mktemp -d)
    ffmpeg -v error -f lavfi -i "testsrc2=size=320x240:duration=1:rate=10" -c:v libx264 -y "$TMP/src.mp4" 2>/dev/null
    if [[ -s "$TMP/src.mp4" ]]; then
        # HEVC encode with tag → hvc1
        T=$(codec_tag_for_container hevc mp4)
        # shellcheck disable=SC2086
        ffmpeg -v error -i "$TMP/src.mp4" -c:v libx265 -preset ultrafast $T -y "$TMP/hevc.mp4" 2>/dev/null
        TAG=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_tag_string -of default=noprint_wrappers=1:nokey=1 "$TMP/hevc.mp4" 2>/dev/null)
        assert_eq "hvc1" "$TAG" "integration: HEVC + tag → hvc1"

        # H264 with tag → avc1
        T2=$(codec_tag_for_container h264 mp4)
        # shellcheck disable=SC2086
        ffmpeg -v error -i "$TMP/src.mp4" -c:v libx264 -preset ultrafast $T2 -y "$TMP/h264.mp4" 2>/dev/null
        TAG2=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_tag_string -of default=noprint_wrappers=1:nokey=1 "$TMP/h264.mp4" 2>/dev/null)
        assert_eq "avc1" "$TAG2" "integration: H264 + tag → avc1"
    fi
    rm -rf "$TMP"
fi
