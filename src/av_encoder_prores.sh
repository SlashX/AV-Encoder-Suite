#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# av_encoder_prores.sh — Encoder Apple ProRes (prores_ks)
# Codec profesional intra-frame, standard Apple/Final Cut Pro.
# Container: .mov (QuickTime) sau .mxf (broadcast/Avid, v74)
# v30: Doar logica specifica — loop-ul e in av_common.sh
# ══════════════════════════════════════════════════════════════════════

ENCODER_TYPE="prores"

AUDIO_CODEC_ARG="${1:-aac:192k}"
PRORES_PROFILE="${2:-hq}"; CONTAINER="${3:-mov}"; SCALE_WIDTH="${4}"
TARGET_FPS="${5}"; FPS_METHOD="${6}"; VIDEO_FILTER_PRESET="${7}"
AUDIO_NORMALIZE="${8:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/av_common.sh"
THREADS=$(av_nproc)
LOG_FILE="$OUTPUT_DIR/av_encode_log_prores.txt"
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"
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
    log "                 Container: $CONTAINER (.mov QuickTime sau .mxf broadcast)"
}

# ProRes: container mov sau mxf (v74). MXF ignora -movflags (la fel ca DNxHR).
get_container_flags() {
    case "$CONTAINER" in mxf) echo "" ;; *) echo "-movflags +faststart" ;; esac
}

encoder_setup_file() {
    local file="$1"

    # ── v42: HW dispatch ProRes — doar VideoToolbox pe macOS ──────────
    # ProRes HW e ne-HDR; LOG sources merg prin SW (pastreaza Log intact)
    if [[ "${HW_BACKEND:-sw}" == "videotoolbox" ]] && [[ -z "${LOG_PROFILE:-}" ]]; then
        hw_dispatch_sdr "$file" "prores"; _hw_rc=$?
        [ $_hw_rc -eq 0 ]  && return 0
        [ $_hw_rc -eq 98 ] && return 98
    fi

    # ── LOG format — ProRes pastreaza Log-ul intact automat ───────────
    if [[ -n "$LOG_PROFILE" ]]; then
        local profile_label
        profile_label=$(_log_profile_label "$LOG_PROFILE")
        log "  LOG detectat: $profile_label — ProRes pastreaza profilul Log intact."
    fi

    # ── DV / HDR10+ — metadata dinamica NU se pastreaza in mezzanine ───
    # ProRes (toate profilele 10-bit) nu transporta RPU Dolby Vision sau HDR10+;
    # iese baza HDR10 statica (PQ + mastering display + MaxCLL, verificat empiric).
    if [[ -n "${DOVI:-}" && -n "${HDR_PLUS:-}" ]]; then
        log "  ATENTIE: DV + HDR10+ (hibrid) detectat — ProRes NU pastreaza nici RPU DV, nici HDR10+."
        log "    Iese HDR10 static (PQ + master-display pastrat); ambele straturi dinamice se pierd."
        log "    Pentru DV/HDR10+: encode x265/AV1 cu preserve, sau meniul HDR/DV tools."
    elif [[ -n "${DOVI:-}" ]]; then
        log "  ATENTIE: Dolby Vision detectat — ProRes NU pastreaza RPU-ul DV."
        log "    Iese HDR10 base (PQ + master-display pastrat); stratul DV se pierde."
        log "    Pentru a pastra DV: encode x265/AV1 cu preserve, sau meniul HDR/DV tools."
    elif [[ -n "${HDR_PLUS:-}" ]]; then
        log "  ATENTIE: HDR10+ detectat — metadata dinamica (SMPTE2094-40) NU se pastreaza."
        log "    Iese HDR10 static (master-display pastrat)."
    fi

    # ── ProRes profil → codec params ────────────────────────────────
    # prores_ks: profile 0=proxy 1=lt 2=standard 3=hq 4=4444 5=4444xq.
    # XQ = profil 5 nativ (tag corect "XQ"); NU profil 4 + qscale (acela scrie tag "4444").
    # Acceptam si token-ul vechi "4444xq" pentru compat cu profile salvate.
    # v74: 4444/XQ pastreaza alpha DOAR daca sursa o are (altfel yuv444p10le — fara plan
    # alpha opac inutil; ~0.4% economie + semantica curata). Profilele 422 n-au alpha.
    local _4444_pf="yuv444p10le" _alpha_note=""
    if [[ "$PRORES_PROFILE" == "4444" || "$PRORES_PROFILE" == "xq" || "$PRORES_PROFILE" == "4444xq" ]]; then
        local _src_pf
        _src_pf=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt \
            -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1 | tr -d '\r')
        case "$_src_pf" in
            yuva*|ya8*|ya16*|*rgba*|*argb*|*abgr*|*bgra*|*gbrap*|pal8) _4444_pf="yuva444p10le"; _alpha_note=", alpha" ;;
        esac
    fi
    local profile_num pixfmt quality_label
    case "$PRORES_PROFILE" in
        proxy)     profile_num=0; pixfmt="yuv422p10le"; quality_label="ProRes Proxy (~45 Mbps)" ;;
        lt)        profile_num=1; pixfmt="yuv422p10le"; quality_label="ProRes LT (~100 Mbps)" ;;
        standard)  profile_num=2; pixfmt="yuv422p10le"; quality_label="ProRes Standard (~145 Mbps)" ;;
        hq)        profile_num=3; pixfmt="yuv422p10le"; quality_label="ProRes HQ (~220 Mbps)" ;;
        4444)      profile_num=4; pixfmt="$_4444_pf"; quality_label="ProRes 4444 (~330 Mbps${_alpha_note})" ;;
        xq|4444xq) profile_num=5; pixfmt="$_4444_pf"; quality_label="ProRes 4444 XQ (~500 Mbps${_alpha_note})" ;;
        *)         profile_num=3; pixfmt="yuv422p10le"; quality_label="ProRes HQ (~220 Mbps)" ;;
    esac
    log "  Profil: $quality_label | PixFmt: $pixfmt | Container: $CONTAINER"

    # ── Dry-run ──────────────────────────────────────────────────────
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        dry_run_report "$file" "$output" "ProRes $quality_label" "$WIDTH" "$DURATION" "ProRes $PRORES_PROFILE"
        return 0
    fi

    # ── Comanda ffmpeg ────────────────────────────────────────────────
    # FARA -bits_per_mb: rate-control nativ per profil. Fortarea 8000 (max)
    # umfla toate profilele la acelasi bitrate (proxy ~16x peste nominal).
    # v94 (O4): prores_ks isi scrie propriul atom de culoare si pierde semnalizarea sursei
    # (bt709/bt709/bt709 → bt709/smpte170m/unknown). `-color_*` NU ajuta (verificat) — doar
    # bsf-ul prores_metadata. Gol cand sursa nu declara tot sau nu e exprimabil in bsf.
    local _pr_color_bsf
    _pr_color_bsf=$(_mezz_color_bsf prores "$file")
    FFMPEG_CMD="ffmpeg -threads $THREADS -i \"\$file\" $MAP_FLAGS \
        -c:v prores_ks -profile:v $profile_num -pix_fmt $pixfmt \
        -vendor apl0 $_pr_color_bsf \
        $VIDEO_FILTER $AUDIO_PARAMS"
    return 0
}

run_encode_loop
