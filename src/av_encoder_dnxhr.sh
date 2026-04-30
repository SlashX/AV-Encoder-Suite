#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# av_encoder_dnxhr.sh — Encoder DNxHR/DNxHD (Avid, codec video mezzanine)
# v26: Doar logica specifica — loop-ul e in av_common.sh
# ══════════════════════════════════════════════════════════════════════

ENCODER_TYPE="dnxhr"

AUDIO_CODEC_ARG="${1:-aac:192k}"
DNXHR_PROFILE="${2:-sq}"; CONTAINER="${3:-mov}"; SCALE_WIDTH="${4}"
TARGET_FPS="${5}"; FPS_METHOD="${6}"; VIDEO_FILTER_PRESET="${7}"
AUDIO_NORMALIZE="${8:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/av_common.sh"
THREADS=$(av_nproc)
LOG_FILE="$OUTPUT_DIR/av_encode_log_dnxhr.txt"
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"
setup_trap

# ── Runtime check: dnxhd encoder disponibil? ──────────────────────────
if ! ffmpeg -encoders 2>/dev/null | grep -q "dnxhd"; then
    echo "  EROARE: DNxHR encoder nu este disponibil in ffmpeg!"
    exit 1
fi

encoder_get_suffix() { echo "_dnxhr"; }
encoder_get_label()  { echo "DNxHR ($DNXHR_PROFILE)"; }

encoder_log_header() {
    log "Profil         : $DNXHR_PROFILE"
    log "Note           : DNxHR = bitrate fix per profil, lossless optic"
}

# Override get_container_flags pentru DNxHR (mxf fara movflags)
get_container_flags() {
    case "$CONTAINER" in mxf|mkv) echo "" ;; *) echo "-movflags +faststart" ;; esac
}

encoder_setup_file() {
    local file="$1"

    # ── LOG format — DNxHR pastreaza Log-ul intact automat ────────────
    if [[ -n "$LOG_PROFILE" ]]; then
        local profile_label
        profile_label=$(_log_profile_label "$LOG_PROFILE")
        log "  LOG detectat: $profile_label — DNxHR pastreaza profilul Log intact."
    fi

    # ── Avertisment HDR/HLG cu profil non-HQX ─────────────────────────
    if { [[ "$HDR_TYPE" == "smpte2084" ]] || [[ "${IS_HLG:-0}" == "1" ]]; } && [[ "$DNXHR_PROFILE" != "hqx" ]]; then
        log "  ATENTIE: Sursa HDR/HLG detectata. Recomandat: profil HQX (12-bit)."
        log "  Profilul curent ($DNXHR_PROFILE) va converti la SDR range."
    fi

    # ── Profil DNxHR → codec params ───────────────────────────────────
    local codec="dnxhd" pixfmt profile_flag label
    case "$DNXHR_PROFILE" in
        lb)  pixfmt="yuv422p10le"; profile_flag="dnxhr_lb";  label="DNxHR_LB" ;;
        sq)  pixfmt="yuv422p10le"; profile_flag="dnxhr_sq";  label="DNxHR_SQ" ;;
        hq)  pixfmt="yuv422p10le"; profile_flag="dnxhr_hq";  label="DNxHR_HQ" ;;
        hqx) pixfmt="yuv422p12le"; profile_flag="dnxhr_hqx"; label="DNxHR_HQX" ;;
        444) pixfmt="yuv444p10le"; profile_flag="dnxhr_444"; label="DNxHR_444" ;;
        *)   pixfmt="yuv422p10le"; profile_flag="dnxhr_sq";  label="DNxHR_SQ" ;;
    esac
    log "  Profil: $label | PixFmt: $pixfmt | Container: $CONTAINER"

    # ── Dry-run ──────────────────────────────────────────────────────
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        dry_run_report "$file" "$output" "DNxHR $label" "$WIDTH" "$DURATION" "DNxHR $DNXHR_PROFILE"
        return 0
    fi

    # ── Comanda ffmpeg ────────────────────────────────────────────────
    FFMPEG_CMD="ffmpeg -threads $THREADS -i \"\$file\" $MAP_FLAGS \
        -c:v $codec -profile:v $profile_flag -pix_fmt $pixfmt \
        $VIDEO_FILTER $AUDIO_PARAMS"
    return 0
}

run_encode_loop
