#!/usr/bin/env bash
# v53: HW VUI fix via BSF + NVENC multipass + audio AC3 + downmix env var
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"

INPUT_DIR=/tmp/v53_in OUTPUT_DIR=/tmp/v53_out
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"
source "$SCRIPT_DIR/av_common.sh"

# ══════════════════════════════════════════════════════════════════════
# Faza A: HW VUI fix via BSF (_hw_hdr_setup populates _HW_VUI_BSF)
# ══════════════════════════════════════════════════════════════════════
# HDR10 — HEVC uses 'colour_*' naming, AV1/H.264 use 'color_*'
HW_HDR_MODE="hw_hdr10"
_hw_hdr_setup "hevc"
assert_contains "$_HW_VUI_BSF" "hevc_metadata=colour_primaries=9:transfer_characteristics=16:matrix_coefficients=9" "HEVC HDR10 BSF correct"
assert_eq "p010le" "$_HW_PIX_FMT" "HEVC HDR10 pix_fmt p010le"
assert_eq "-profile:v main10" "$_HW_PROFILE" "HEVC HDR10 profile main10"

_hw_hdr_setup "av1"
assert_contains "$_HW_VUI_BSF" "av1_metadata=color_primaries=9:transfer_characteristics=16:matrix_coefficients=9" "AV1 HDR10 BSF correct"

_hw_hdr_setup "h264"
assert_contains "$_HW_VUI_BSF" "h264_metadata=color_primaries=9:transfer_characteristics=16:matrix_coefficients=9" "H.264 HDR10 BSF correct"

# HLG — transfer_characteristics=18
HW_HDR_MODE="hw_hlg"
_hw_hdr_setup "hevc"
assert_contains "$_HW_VUI_BSF" "transfer_characteristics=18" "HEVC HLG transfer=18"

_hw_hdr_setup "av1"
assert_contains "$_HW_VUI_BSF" "transfer_characteristics=18" "AV1 HLG transfer=18"

# SDR tonemap — primaries/transfer/matrix=1
HW_HDR_MODE="hw_sdr"
VIDEO_FILTER=""
_hw_hdr_setup "hevc"
assert_contains "$_HW_VUI_BSF" "colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1" "HEVC SDR BT.709 VUI"
assert_contains "$VIDEO_FILTER" "tonemap=hable" "SDR tonemap filter added"

# hw_repair (MediaCodec) — same as hdr10 + sets MC_NEEDS_REPAIR
HW_HDR_MODE="hw_repair"
_hw_hdr_setup "hevc"
assert_contains "$_HW_VUI_BSF" "transfer_characteristics=16" "hw_repair → HDR10 PQ VUI"

# v63 audit: build_mediacodec_cmd are bsf-ul INLINE (Android/Termux) — paritate cu _hw_hdr_setup.
# Scopat pe corpul functiei (build_mediacodec_cmd → _hw_hdr_setup) ca sa prinda drift real.
MC_FN=$(awk '/^build_mediacodec_cmd\(\)/{f=1} /^_hw_hdr_setup\(\)/{f=0} f' "$SCRIPT_DIR/av_common.sh")
assert_contains "$MC_FN" "colour_primaries=9:transfer_characteristics=16:matrix_coefficients=9" "MediaCodec HDR10 BSF (paritate _hw_hdr_setup)"
assert_contains "$MC_FN" "transfer_characteristics=18"  "MediaCodec HLG BSF transfer=18"
assert_contains "$MC_FN" "MC_NEEDS_REPAIR=1"            "MediaCodec HDR10 → SEI repair flag setat"

# Empty mode — no BSF (SDR default path)
HW_HDR_MODE=""
_HW_VUI_BSF=""
_hw_hdr_setup "hevc"
assert_eq "" "$_HW_VUI_BSF" "empty HDR_MODE → no BSF"

# _HW_COLOR_FLAGS = empty (back-compat, no longer broken color flags)
assert_eq "" "$_HW_COLOR_FLAGS" "v53: _HW_COLOR_FLAGS cleared (back-compat)"

# ══════════════════════════════════════════════════════════════════════
# Faza B: NVENC multipass on mode 3 — build_nvenc_cmd produces -multipass fullres
# ══════════════════════════════════════════════════════════════════════
THREADS=4 WIDTH=1920 MAP_FLAGS="-map 0" CONTAINER="mkv"
AUDIO_PARAMS="-c:a copy" VIDEO_FILTER=""
ENCODE_MODE=3 VBR_TARGET=8000k VBR_MAXRATE=12000k HW_HDR_MODE=""
HW_PRESET_SLOT=4
build_nvenc_cmd "/tmp/dummy.mp4" "hevc"
assert_contains "$FFMPEG_CMD" "-multipass fullres" "NVENC mode 3 → multipass fullres"
assert_contains "$FFMPEG_CMD" "-bf 4" "NVENC mode 3 → bf 4 quality boost"
assert_contains "$FFMPEG_CMD" "-rc-lookahead 32" "NVENC mode 3 → rc-lookahead 32"
assert_contains "$FFMPEG_CMD" "-aq-strength 10" "NVENC mode 3 → aq-strength 10"
assert_contains "$FFMPEG_CMD" "-weighted_pred 1" "NVENC HEVC mode 3 → weighted_pred 1"

# AV1 NVENC mode 3 — NO weighted_pred (not supported)
ENCODE_MODE=3
build_nvenc_cmd "/tmp/dummy.mp4" "av1"
assert_contains "$FFMPEG_CMD" "-multipass fullres" "NVENC AV1 mode 3 → multipass"
assert_not_contains "$FFMPEG_CMD" "-weighted_pred" "NVENC AV1 mode 3 → NO weighted_pred"

# Mode 2 (1-pass) on NVENC — no multipass + no quality boost
ENCODE_MODE=2
build_nvenc_cmd "/tmp/dummy.mp4" "hevc"
assert_not_contains "$FFMPEG_CMD" "-multipass fullres" "NVENC mode 2 → NO multipass"
assert_not_contains "$FFMPEG_CMD" "-bf 4" "NVENC mode 2 → no quality boost flags"

# Mode 1 (CRF) on NVENC — uses -cq, no VBR, no multipass
ENCODE_MODE=1 VBR_TARGET=""
build_nvenc_cmd "/tmp/dummy.mp4" "hevc"
assert_contains "$FFMPEG_CMD" "-cq " "NVENC mode 1 → CQ (CRF-like)"
assert_not_contains "$FFMPEG_CMD" "-multipass" "NVENC mode 1 → NO multipass"

# ══════════════════════════════════════════════════════════════════════
# Faza E: Audio AC3 codec
# ══════════════════════════════════════════════════════════════════════
# AC3 stereo
AUDIO_CODEC_ARG="ac3:224k"
result=$(get_audio_params "")  # no file, channels=2 default
assert_contains "$result" "-c:a:0 ac3 -b:a:0 224k" "AC3 stereo 224k"

# AC3 schema validation
schema=$(profile_schema_get "AUDIO_CODEC_ARG")
assert_contains "$schema" "ac3:" "schema accepts ac3:Nk"

# ══════════════════════════════════════════════════════════════════════
# Faza G: Channel downmix env var (AV_DOWNMIX_STEREO=1)
# ══════════════════════════════════════════════════════════════════════
# Without env var — auto bitrate scale (192k → 384k for 5.1 simulated via mock)
# Mock channels via direct call (skip ffprobe)
# Since get_audio_params reads channels from ffprobe, we can only test downmix
# indirectly. Test via env var pattern in code.
common_src=$(cat "$SCRIPT_DIR/av_common.sh")
assert_contains "$common_src" 'AV_DOWNMIX_STEREO:-0}" == "1"' "downmix env var check present"
assert_contains "$common_src" 'channels=2' "downmix sets channels=2"
assert_contains "$common_src" '-ac:a:0 2' "downmix appends -ac:a:0 2 flag"

# v63 audit: detectia canalelor robusta — default= (NU csv=p=0 fragil: trailing comma pe audio
# cu side_data / 2 linii pe DJI → regex `^[0-9]+$` esua → channels=2 → bitrate surround gresit).
gap_fn=$(awk '/^get_audio_params\(\)/{f=1} /^_warn_audio_metadata\(\)/{f=0} f' "$SCRIPT_DIR/av_common.sh")
assert_not_contains "$gap_fn" "stream=channels -of csv=p=0" "get_audio_params channels: default= (NU csv=p=0)"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"
if command -v ffmpeg >/dev/null 2>&1; then
    _t5="$(mktemp -d)"
    if ffmpeg -hide_banner -v error -y -f lavfi -i "sine=frequency=440:duration=1" \
        -af "pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0" -c:a aac "$_t5/51.mkv" 2>/dev/null; then
        AUDIO_CODEC_ARG="aac:192k"; CONTAINER="mkv"
        _r51=$(get_audio_params "$_t5/51.mkv" 2>/dev/null)
        assert_contains "$_r51" "384k" "functional: 5.1 → channels=6 detectat → bitrate 384k (NU fallback 192k)"
    fi
    rm -rf "$_t5"
fi

# ══════════════════════════════════════════════════════════════════════
# Markers in encoder/launcher files
# ══════════════════════════════════════════════════════════════════════
launcher_src=$(cat "$SCRIPT_DIR/av_launcher.sh")
assert_contains "$launcher_src" '_hw_supports_2pass' "launcher tracks HW 2-pass support"
assert_contains "$launcher_src" 'HW_BACKEND:-}" == "nvenc"' "launcher detects NVENC for 2-pass enable"
assert_contains "$launcher_src" 'AC3 (Dolby Digital legacy)' "launcher menu has AC3 option"
assert_contains "$launcher_src" 'ac3:224k' "launcher maps choice 8 → ac3:224k"

# ══════════════════════════════════════════════════════════════════════
# Faza H: WebM in audio-only encoder (v53 addendum)
# ══════════════════════════════════════════════════════════════════════
audio_src=$(cat "$SCRIPT_DIR/av_encoder_audio.sh")
assert_contains "$audio_src" '4) webm' "audio-only container menu has webm option"
assert_contains "$audio_src" 'CONTAINER="webm"' "audio-only maps choice 4 → webm"
assert_contains "$audio_src" 'WebM accepta DOAR vp8/vp9/av1' "audio-only WebM video codec check present"
assert_contains "$audio_src" 'TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1)); continue' "audio-only skips incompatible source for WebM"
assert_contains "$audio_src" 'WebM accepta DOAR WebVTT' "audio-only strips subs on WebM"
assert_contains "$audio_src" 'WebM accepta DOAR Opus' "audio-only WebM Opus enforcement"
assert_contains "$audio_src" '"$CONTAINER" == "mp4" || "$CONTAINER" == "mov"' "audio-only +faststart limited to mp4/mov"

# ══════════════════════════════════════════════════════════════════════
# Faza I: Per-iteration state reset includes HLG_DIALOG_MODE (v53 audit)
# ══════════════════════════════════════════════════════════════════════
assert_contains "$common_src" 'HLG_DIALOG_MODE=""' "defensive reset clears HLG_DIALOG_MODE"

# ══════════════════════════════════════════════════════════════════════
# Faza J: Inter-batch audio change prompt mentions AC3 (v53 audit)
# ══════════════════════════════════════════════════════════════════════
assert_contains "$common_src" 'ac3:224k' "inter-batch audio prompt mentions ac3"

exit 0
