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
    # Doua nuante SEPARATE (verificat empiric v74): (a) precizie — doar HQX/444 (10-bit)
    # o pastreaza; LB/SQ/HQ scad la 8-bit. (b) tag gamut bt2020 — CONTAINER-driven, NU
    # profil: pastrat pe MXF la ORICE profil, pe MOV -> unknown la ORICE profil (-color_*
    # nu ajuta). Cosmetic — curba Log ramane in pixeli oricum.
    if [[ -n "$LOG_PROFILE" ]]; then
        local profile_label
        profile_label=$(_log_profile_label "$LOG_PROFILE")
        if [[ "$DNXHR_PROFILE" == "hqx" || "$DNXHR_PROFILE" == "444" ]]; then
            log "  LOG detectat: $profile_label — DNxHR pastreaza Log intact (10-bit)."
        else
            log "  LOG detectat: $profile_label — ATENTIE: profil $DNXHR_PROFILE e 8-bit (precizia scade 10->8 bit)."
            log "    Recomandat pentru Log: profil HQX sau 444 (10-bit)."
        fi
        # Tag gamut bt2020: container-driven (orice profil) — pastrat pe MXF, pierdut pe MOV.
        [[ "$CONTAINER" == "mov" ]] && \
            log "    Nota: pe MOV tag-ul de gamut bt2020 -> unknown (pe MXF pastrat, orice profil); cosmetic — pixelii Log raman."
    fi

    # ── Avertisment HDR/HLG cu profil 8-bit (LB/SQ/HQ) ────────────────
    # HDR10 (PQ) si HLG isi pastreaza semnalizarea chiar si pe 8-bit (verificat),
    # dar precizia scade 10->8 bit. HQX/444 (10-bit) sunt alegerea corecta.
    if { [[ "$HDR_TYPE" == "smpte2084" ]] || [[ "${IS_HLG:-0}" == "1" ]]; } \
       && [[ "$DNXHR_PROFILE" != "hqx" && "$DNXHR_PROFILE" != "444" ]]; then
        log "  ATENTIE: Sursa HDR/HLG detectata, profil $DNXHR_PROFILE (8-bit)."
        log "    Semnalizarea HDR se pastreaza, dar precizia scade 10 la 8 bit (risc de benzi)."
        log "    Recomandat: profil HQX sau 444 (10-bit)."
    fi

    # ── DV / HDR10+ — metadata dinamica NU se pastreaza in mezzanine ───
    # DNxHR nu transporta RPU Dolby Vision sau HDR10+ (SMPTE2094-40); iese baza
    # HDR10 statica (PQ + mastering display + MaxCLL, verificat empiric).
    if [[ -n "${DOVI:-}" && -n "${HDR_PLUS:-}" ]]; then
        log "  ATENTIE: DV + HDR10+ (hibrid) detectat — DNxHR NU pastreaza nici RPU DV, nici HDR10+."
        log "    Iese HDR10 static (PQ + master-display pastrat); ambele straturi dinamice se pierd."
        log "    Pentru DV/HDR10+: encode x265/AV1 cu preserve, sau meniul HDR/DV tools."
    elif [[ -n "${DOVI:-}" ]]; then
        log "  ATENTIE: Dolby Vision detectat — DNxHR NU pastreaza RPU-ul DV."
        log "    Iese HDR10 base (PQ + master-display pastrat); stratul DV se pierde."
        log "    Pentru a pastra DV: encode x265/AV1 cu preserve, sau meniul HDR/DV tools."
    elif [[ -n "${HDR_PLUS:-}" ]]; then
        log "  ATENTIE: HDR10+ detectat — metadata dinamica (SMPTE2094-40) NU se pastreaza."
        log "    Iese HDR10 static (master-display pastrat)."
    fi

    # ── Profil DNxHR → codec params ───────────────────────────────────
    # PixFmt per profil (constrans de encoderul dnxhd):
    #   LB/SQ/HQ  = 8-bit  4:2:2 → yuv422p   (10-bit e RESPINS: "incompatible with DNxHR LB/SQ/HQ")
    #   HQX       = 10-bit 4:2:2 → yuv422p10le (build-ul ffmpeg e 10-bit max; 12le ar fi coborat tacut)
    #   444       = 10-bit 4:4:4 → yuv444p10le
    local codec="dnxhd" pixfmt profile_flag label
    case "$DNXHR_PROFILE" in
        lb)  pixfmt="yuv422p";     profile_flag="dnxhr_lb";  label="DNxHR_LB" ;;
        sq)  pixfmt="yuv422p";     profile_flag="dnxhr_sq";  label="DNxHR_SQ" ;;
        hq)  pixfmt="yuv422p";     profile_flag="dnxhr_hq";  label="DNxHR_HQ" ;;
        hqx) pixfmt="yuv422p10le"; profile_flag="dnxhr_hqx"; label="DNxHR_HQX" ;;
        444) pixfmt="yuv444p10le"; profile_flag="dnxhr_444"; label="DNxHR_444" ;;
        *)   pixfmt="yuv422p";     profile_flag="dnxhr_sq";  label="DNxHR_SQ" ;;
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
