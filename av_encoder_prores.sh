#!/data/data/com.termux/files/usr/bin/bash
# ══════════════════════════════════════════════════════════════════════
# av_encoder_prores.sh — Encoder Apple ProRes (prores_ks)
# Codec profesional intra-frame, standard Apple/Final Cut Pro.
# Container obligatoriu: .mov (QuickTime)
# v30: Doar logica specifica — loop-ul e in av_common.sh
# ══════════════════════════════════════════════════════════════════════

THREADS=$(nproc)
ENCODER_TYPE="prores"

INPUT_DIR="/storage/emulated/0/Media/InputVideos"
OUTPUT_DIR="/storage/emulated/0/Media/OutputVideos"

AUDIO_CODEC_ARG="${1:-aac:192k}"
PRORES_PROFILE="${2:-hq}"; CONTAINER="${3:-mov}"; SCALE_WIDTH="${4}"
TARGET_FPS="${5}"; FPS_METHOD="${6}"; VIDEO_FILTER_PRESET="${7}"
AUDIO_NORMALIZE="${8:-0}"

LOG_FILE="$OUTPUT_DIR/av_encode_log_prores.txt"
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/av_common.sh"
setup_trap

# ── Runtime check: prores_ks encoder disponibil? ──────────────────────
if ! ffmpeg -encoders 2>/dev/null | grep -q "prores_ks"; then
    echo "  EROARE: prores_ks encoder nu este disponibil in ffmpeg!"
    exit 1
fi

encoder_get_suffix() { echo "_prores"; }
encoder_get_label()  { echo "ProRes ($PRORES_PROFILE)"; }

encoder_log_header() {
    log "Profil         : $PRORES_PROFILE"
    log "Note           : ProRes = codec Apple profesional intra-frame"
    log "                 Container obligatoriu: .mov (QuickTime)"
}

# ProRes: container DOAR mov
get_container_flags() {
    echo "-movflags +faststart"
}

encoder_setup_file() {
    local file="$1"

    # ── LOG format — ProRes pastreaza Log-ul intact automat ───────────
    if [[ -n "$LOG_PROFILE" ]]; then
        local profile_label
        profile_label=$(_log_profile_label "$LOG_PROFILE")
        log "  LOG detectat: $profile_label — ProRes pastreaza profilul Log intact."
    fi

    # ── ProRes profil → codec params ────────────────────────────────
    local profile_num pixfmt quality_label
    case "$PRORES_PROFILE" in
        proxy)    profile_num=0; pixfmt="yuv422p10le"; quality_label="ProRes Proxy (~45 Mbps)" ;;
        lt)       profile_num=1; pixfmt="yuv422p10le"; quality_label="ProRes LT (~100 Mbps)" ;;
        standard) profile_num=2; pixfmt="yuv422p10le"; quality_label="ProRes Standard (~145 Mbps)" ;;
        hq)       profile_num=3; pixfmt="yuv422p10le"; quality_label="ProRes HQ (~220 Mbps)" ;;
        4444)     profile_num=4; pixfmt="yuva444p10le"; quality_label="ProRes 4444 (~330 Mbps, alpha)" ;;
        xq)       profile_num=4; pixfmt="yuva444p10le"; quality_label="ProRes 4444 XQ (~500 Mbps)" ;;
        *)        profile_num=3; pixfmt="yuv422p10le"; quality_label="ProRes HQ (~220 Mbps)" ;;
    esac
    # XQ = profil 4444 cu qscale maxim (prores_ks nu are profil 5)
    local xq_flag=""
    [[ "$PRORES_PROFILE" == "xq" ]] && xq_flag="-qscale:v 1"
    log "  Profil: $quality_label | PixFmt: $pixfmt | Container: $CONTAINER"

    # ── Dry-run ──────────────────────────────────────────────────────
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        dry_run_report "$file" "$output" "ProRes $quality_label" "$WIDTH" "$DURATION" "ProRes $PRORES_PROFILE"
        return 0
    fi

    # ── Comanda ffmpeg ────────────────────────────────────────────────
    FFMPEG_CMD="ffmpeg -threads $THREADS -i \"\$file\" $MAP_FLAGS \
        -c:v prores_ks -profile:v $profile_num -pix_fmt $pixfmt \
        -vendor apl0 -bits_per_mb 8000 $xq_flag \
        $VIDEO_FILTER $AUDIO_PARAMS"
    return 0
}

run_encode_loop
