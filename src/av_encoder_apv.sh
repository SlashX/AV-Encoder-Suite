#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# av_encoder_apv.sh — Encoder APV (Samsung Advanced Professional Video)
# Necesita: ffmpeg 8.1+ compilat cu --enable-libopenapv
# v28: Doar logica specifica — loop-ul e in av_common.sh
# ══════════════════════════════════════════════════════════════════════

ENCODER_TYPE="apv"

AUDIO_CODEC_ARG="${1:-aac:192k}"
APV_PRESET="${2:-standard}"; CONTAINER="${3:-mp4}"; SCALE_WIDTH="${4}"
TARGET_FPS="${5}"; FPS_METHOD="${6}"; VIDEO_FILTER_PRESET="${7}"
AUDIO_NORMALIZE="${8:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/av_common.sh"
THREADS=$(av_nproc)
LOG_FILE="$OUTPUT_DIR/av_encode_log_apv.txt"
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"
setup_trap

# ── Runtime check: libopenapv disponibil? ─────────────────────────────
if ! ffmpeg -encoders 2>/dev/null | grep -q "libopenapv"; then
    echo ""
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║  EROARE: libopenapv NU este disponibil in ffmpeg!    ║"
    echo "  ║  Build-ul curent nu include --enable-libopenapv.     ║"
    echo "  ║  APV encoder necesita ffmpeg compilat cu aceasta     ║"
    echo "  ║  optiune. APV DECODE functioneaza (citire fisiere).  ║"
    echo "  ║                                                      ║"
    echo "  ║  Alternativa: foloseste x265 sau AV1 pentru encode.  ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    exit 1
fi

encoder_get_suffix() { echo "_apv"; }
encoder_get_label()  { echo "APV ($APV_PRESET)"; }

encoder_log_header() {
    log "Preset         : $APV_PRESET"
    log "Note           : APV = codec Samsung profesional intra-frame"
    log "                 Necesita libopenapv in ffmpeg build"
}

# Override get_container_flags — APV in mp4/mov/mxf
get_container_flags() {
    case "$CONTAINER" in mkv|mxf) echo "" ;; *) echo "-movflags +faststart" ;; esac
}

encoder_setup_file() {
    local file="$1"

    # ── APV preset → codec params ───────────────────────────────────
    local pixfmt quality_label
    case "$APV_PRESET" in
        light)    pixfmt="yuv422p10le"; quality_label="APV Light (editare rapida)" ;;
        standard) pixfmt="yuv422p10le"; quality_label="APV Standard (balans calitate/spatiu)" ;;
        high)     pixfmt="yuv422p10le"; quality_label="APV High (calitate ridicata)" ;;
        422_10)   pixfmt="yuv422p10le"; quality_label="APV 4:2:2 10-bit" ;;
        444_10)   pixfmt="yuv444p10le"; quality_label="APV 4:4:4 10-bit (grading)" ;;
        *)        pixfmt="yuv422p10le"; quality_label="APV Standard" ;;
    esac
    log "  Preset: $quality_label | PixFmt: $pixfmt | Container: $CONTAINER"

    # ── Dry-run ──────────────────────────────────────────────────────
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        dry_run_report "$file" "$output" "APV $quality_label" "$WIDTH" "$DURATION" "APV $APV_PRESET"
        return 0
    fi

    # ── Comanda ffmpeg ────────────────────────────────────────────────
    FFMPEG_CMD="ffmpeg -threads $THREADS -i \"\$file\" $MAP_FLAGS \
        -c:v libopenapv -preset $APV_PRESET -pix_fmt $pixfmt \
        $VIDEO_FILTER $AUDIO_PARAMS"
    return 0
}

run_encode_loop
