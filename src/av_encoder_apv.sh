#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# av_encoder_apv.sh — Encoder APV (Samsung Advanced Professional Video)
# Necesita: ffmpeg 8.1+ cu encoderul APV (liboapv SAU libopenapv — difera
# intre builduri; auto-detectat mai jos).
# v65: model real liboapv — pixfmt/profil + preset viteza + qp + oapv-params.
#      Loop-ul e in av_common.sh.
# ══════════════════════════════════════════════════════════════════════

ENCODER_TYPE="apv"

AUDIO_CODEC_ARG="${1:-aac:192k}"
APV_PIXFMT="${2:-422_10}"; APV_PRESET="${3:-medium}"; APV_QP="${4:-32}"
APV_EXTRA="${5}"; CONTAINER="${6:-mp4}"; SCALE_WIDTH="${7}"
TARGET_FPS="${8}"; FPS_METHOD="${9}"; VIDEO_FILTER_PRESET="${10}"
AUDIO_NORMALIZE="${11:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/av_common.sh"
THREADS=$(av_nproc)
LOG_FILE="$OUTPUT_DIR/av_encode_log_apv.txt"
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"
setup_trap

# ── Detectie nume encoder APV (liboapv pe builduri recente; libopenapv pe altele)
APV_ENCODER=""
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -qw "liboapv"; then
    APV_ENCODER="liboapv"
elif ffmpeg -hide_banner -encoders 2>/dev/null | grep -qw "libopenapv"; then
    APV_ENCODER="libopenapv"
fi

# ── Runtime check: encoder APV disponibil? ────────────────────────────
if [[ -z "$APV_ENCODER" ]]; then
    echo ""
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║  EROARE: encoderul APV NU este disponibil in ffmpeg! ║"
    echo "  ║  Build-ul curent nu include liboapv / libopenapv.    ║"
    echo "  ║  APV encode necesita ffmpeg 8.1+ compilat cu OpenAPV.║"
    echo "  ║  APV DECODE functioneaza (citire fisiere .apv).      ║"
    echo "  ║  Alternativa: foloseste x265 sau AV1 pentru encode.  ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    exit 1
fi

encoder_get_suffix() { echo "_apv"; }
encoder_get_label()  { echo "APV ($APV_PIXFMT)"; }

encoder_log_header() {
    log "Encoder        : $APV_ENCODER"
    log "Profil/pixfmt  : $APV_PIXFMT | Preset: $APV_PRESET | QP: $APV_QP"
    log "Note           : APV = codec Samsung profesional intra-frame (10/12-bit)"
}

# Override get_container_flags — APV in mp4/mov/mkv (NU mxf — liboapv nu se muxa)
get_container_flags() {
    case "$CONTAINER" in mkv) echo "" ;; *) echo "-movflags +faststart" ;; esac
}

encoder_setup_file() {
    local file="$1"

    # ── APV pixfmt/profil → pix_fmt + eticheta (profil auto din pix_fmt) ──
    #   422_10→33  422_12→44  444_10→55  444_12→66  4444_10→77 (alpha)
    local pixfmt prof_label
    case "$APV_PIXFMT" in
        422_10)  pixfmt="yuv422p10le";  prof_label="APV 4:2:2 10-bit (profil 422-10)" ;;
        422_12)  pixfmt="yuv422p12le";  prof_label="APV 4:2:2 12-bit (profil 422-12)" ;;
        444_10)  pixfmt="yuv444p10le";  prof_label="APV 4:4:4 10-bit (profil 444-10)" ;;
        444_12)  pixfmt="yuv444p12le";  prof_label="APV 4:4:4 12-bit (profil 444-12)" ;;
        4444_10) pixfmt="yuva444p10le"; prof_label="APV 4:4:4+alpha 10-bit (profil 4444-10)" ;;
        *)       pixfmt="yuv422p10le";  prof_label="APV 4:2:2 10-bit (profil 422-10)" ;;
    esac
    log "  $prof_label | Preset: $APV_PRESET | QP: $APV_QP | Container: $CONTAINER"

    # ── LOG format — APV (10/12-bit) pastreaza Log-ul intact ──────────
    if [[ -n "$LOG_PROFILE" ]]; then
        local profile_label
        profile_label=$(_log_profile_label "$LOG_PROFILE")
        log "  LOG detectat: $profile_label — APV pastreaza profilul Log intact (10/12-bit)."
    fi

    # ── DV / HDR10+ pe APV ─────────────────────────────────────────────
    # v69: HDR10+ SE PASTREAZA — APV suporta nativ ITU-T T.35 (RFC 9924);
    # pipeline: extract JSON (tool-urile existente per codec sursa) → encode →
    # inject T.35 per frame + MDCV/CLL post-encode (engine apv_hdr10plus.py).
    # DV ramane nepreservabil (nu exista profil DV pentru APV).
    APV_HDR10PLUS_INJECT=0; APV_HDR10PLUS_JSON=""
    if [[ -n "${DOVI:-}" ]]; then
        log "  ATENTIE: Dolby Vision detectat — APV NU pastreaza RPU-ul DV (nu exista profil DV pt APV)."
        log "    Pentru a pastra DV: encode x265/AV1 cu preserve, sau meniul HDR/DV tools."
        [[ -n "${HDR_PLUS:-}" ]] && log "    Hibrid DV+HDR10+: stratul HDR10+ POATE fi pastrat (dialogul urmator)."
    fi
    if [[ -n "${HDR_PLUS:-}" ]]; then
        local _src_vc _hp_choice
        _src_vc=$(detect_source_codec "$file")
        if ! _check_hdr10plus_tool_for "$_src_vc" || ! _apv_hdr10plus_engine_py >/dev/null 2>&1; then
            # tool de extract pt codec-ul sursa SAU engine-ul de inject lipsesc
            log "  ATENTIE: HDR10+ detectat, dar tool-ul de extract ($_src_vc) sau python3/engine lipsesc."
            log "    Iese HDR10 static (mastering display + MaxCLL pastrate)."
        else
            case "${APV_HDR10PLUS_POLICY:-}" in
                preserve) _hp_choice=1 ;;
                static)   _hp_choice=2 ;;
                skip)     _hp_choice=3 ;;
                *)
                    echo ""
                    echo "  ╔══════════════════════════════════════════════╗"
                    echo "  ║  HDR10+ DETECTAT (target APV)                 ║"
                    echo "  ╠══════════════════════════════════════════════╣"
                    echo "  ║  1) Pastreaza HDR10+ (T.35 in bitstream APV) ║"
                    echo "  ║     → extract JSON + inject post-encode      ║"
                    echo "  ║  2) HDR10 static doar (pierde metadata +)    ║"
                    echo "  ║  3) Skip fisier                              ║"
                    echo "  ╚══════════════════════════════════════════════╝"
                    read -p "  Alege 1-3 [implicit: 1]: " _hp_choice
                    _hp_choice="${_hp_choice:-1}"
                    ;;
            esac
            case "$_hp_choice" in
                2) log "  HDR10+: Re-encode ca HDR10 static (fara metadata dinamica)" ;;
                3) log "  HDR10+: Skip fisier"; return 98 ;;
                *)
                    APV_HDR10PLUS_JSON=$(extract_hdr10plus_metadata "$file")
                    if [[ -n "$APV_HDR10PLUS_JSON" ]]; then
                        APV_HDR10PLUS_INJECT=1
                        log "  HDR10+: Metadata pregatita — se injecteaza in APV post-encode"
                    else
                        log "  HDR10+: Extractie esuata — re-encode ca HDR10 static"
                    fi
                    ;;
            esac
        fi
    fi

    # ── Dry-run ──────────────────────────────────────────────────────
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        dry_run_report "$file" "$output" "$prof_label" "$WIDTH" "$DURATION" "APV $APV_PIXFMT"
        return 0
    fi

    # ── Comanda ffmpeg ────────────────────────────────────────────────
    # -preset = viteza (fastest..placebo), -qp = calitate CQP (0-63, mai mic=mai bun),
    # -oapv-params = override avansat (optional, key=value:key=value)
    local apv_extra_arg=""
    [[ -n "$APV_EXTRA" ]] && apv_extra_arg="-oapv-params $APV_EXTRA"
    FFMPEG_CMD="ffmpeg -threads $THREADS -i \"\$file\" $MAP_FLAGS \
        -c:v $APV_ENCODER -preset $APV_PRESET -qp $APV_QP $apv_extra_arg -pix_fmt $pixfmt \
        $VIDEO_FILTER $AUDIO_PARAMS"
    return 0
}

run_encode_loop
