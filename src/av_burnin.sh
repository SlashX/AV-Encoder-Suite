#!/data/data/com.termux/files/usr/bin/bash
# av_burnin.sh — Burn-in overlay pentru telemetrie HUD si subtitrari (SRT/ASS)
# 3 flow-uri: 1) HUD telemetrie (Python+matplotlib) 2) SRT 3) ASS
# Output: OutputVideos/<name>_hud.<ext> sau <name>_subs.<ext>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/av_common.sh"

PRESETS_DIR="$SCRIPT_DIR/burnin_presets"
RENDER_PY="$SCRIPT_DIR/burnin_render.py"
DESIGNER_PY="$SCRIPT_DIR/burnin_designer.py"

# In test mode skip ensure_temp_dir + ffmpeg dep check (functions only)
if [[ "${AV_BURNIN_TEST_MODE:-0}" != "1" ]]; then
    ensure_temp_dir
    mkdir -p "$OUTPUT_DIR"

    # ── Dependente comune (ffmpeg) ─────────────────────────────────
    if ! command -v ffmpeg &>/dev/null; then
        echo "EROARE: ffmpeg nu este instalat."
        echo "Instaleaza cu: $(av_pkg_install_hint ffmpeg)"
        exit 1
    fi
fi

# ── Escape path pentru ffmpeg filter (subtitles=/ass=/lut3d=) ────────
# v85 (O6): deleaga la av_filtergraph_path (av_common) — aceeasi logica (backslash
# ->slash + colon-escape + apostrof) DAR si cygpath pe MSYS (git-bash: calea POSIX
# /d/x → D:/x pt ffmpeg NATIV Windows). Pe productie cygpath lipseste → identic v48.
escape_ffmpeg_filter_path() {
    av_filtergraph_path "$1"
}

# ── Preview mode helpers (shared) ────────────────────────────────────
PREVIEW_MODE=0
PREVIEW_T_START=0
PREVIEW_DURATION=0
PREVIEW_STILL=0
PREVIEW_GRID=0

# ask_preview [allow_still]
#   allow_still=1 (doar HUD): meniu 3-cai (niciunul / still layout 1 cadru / clip 5s).
#   allow_still=0 (SRT/Image, default): comportamentul clasic y/N pt clip 5s (NEschimbat).
ask_preview() {
    local allow_still="${1:-0}"
    PREVIEW_MODE=0
    PREVIEW_STILL=0
    PREVIEW_GRID=0
    echo ""
    if [ "$allow_still" -eq 1 ]; then
        echo "  Preview:  0) niciunul (render complet)   1) still layout (1 cadru, rapid)   2) clip 5s"
        read -p "  Alege 0-2 [implicit 0]: " preview_choice
        case "${preview_choice:-0}" in
            1) PREVIEW_STILL=1
               read -p "  Grila de pozitionare peste HUD? [y/N]: " _grid_choice
               case "${_grid_choice:-n}" in [yY]*) PREVIEW_GRID=1 ;; esac
               echo "  → Still layout$([ "$PREVIEW_GRID" -eq 1 ] && echo " + grila") la 50% din durata. Output: <name>_preview.png" ;;
            2) PREVIEW_MODE=1
               echo "  → Preview clip 5s la 50% din durata. Output: <name>_preview.<ext>" ;;
            *) : ;;  # 0 / Enter → render complet
        esac
    else
        read -p "Preview mode (5s clip la mid-point pentru verificare rapida) [y/N]: " preview_choice
        case "${preview_choice:-n}" in
            [yY]*) PREVIEW_MODE=1
                   echo "  → Preview activ: 5s la 50% din durata. Output: <name>_preview.<ext>" ;;
            *)     PREVIEW_MODE=0 ;;
        esac
    fi
}

# Calculeaza fereastra de preview (5s la mid-point) pe baza duratei totale.
# Returneaza 0 (succes, valid) sau 1 (durata invalida — preview imposibil).
preview_compute_window() {
    local dur="$1"
    # Verifica daca dur e un numar valid > 0 (ffprobe poate returna "" sau "N/A")
    if ! awk -v d="$dur" 'BEGIN{exit !(d+0 > 0.05)}'; then
        PREVIEW_T_START=0
        PREVIEW_DURATION=0
        return 1
    fi
    PREVIEW_T_START=$(awk -v d="$dur" 'BEGIN{m=d/2-2.5; printf "%.3f", (m>0)?m:0}')
    PREVIEW_DURATION=$(awk -v d="$dur" 'BEGIN{printf "%.3f", (d<5)?d:5}')
    return 0
}

# ── Encoder dialog (shared) ──────────────────────────────────────────
ask_encoder() {
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  ENCODER PENTRU OUTPUT (video re-encode)      ║"
    echo "╠══════════════════════════════════════════════╣"
    echo "║  1) libx265 (HEVC) CRF 23 [implicit]          ║"
    echo "║  2) libx264 (H.264) CRF 20                    ║"
    echo "║  3) libsvtav1 (AV1) CRF 30                    ║"
    echo "║  4) Anulare                                   ║"
    echo "╚══════════════════════════════════════════════╝"
    read -p "Alege 1-4 [implicit: 1]: " enc_choice
    case "${enc_choice:-1}" in
        1) ENC_NAME="libx265"; ENC_CODEC_KEY="hevc"; ENC_CRF=23; ENC_PRESET="medium" ;;
        2) ENC_NAME="libx264"; ENC_CODEC_KEY="h264"; ENC_CRF=20; ENC_PRESET="medium" ;;
        3) ENC_NAME="libsvtav1"; ENC_CODEC_KEY="av1"; ENC_CRF=30; ENC_PRESET="6" ;;
        4) echo "Anulat."; exit 0 ;;
        *) ENC_NAME="libx265"; ENC_CODEC_KEY="hevc"; ENC_CRF=23; ENC_PRESET="medium" ;;
    esac
}

# ── Generic scan: <video> paired with <name>.<paired_ext> ────────────
declare -a PAIRS_VIDEO=()
declare -a PAIRS_AUX=()
declare -a PAIRS_LABEL=()
declare -a PAIRS_META=()  # brand pt HUD, lang/empty pt subs
declare -a PAIRS_KIND=()  # ext_pgs / ext_vob / emb_pgs / emb_vob (img_flow)
declare -a PAIRS_TRACK=() # subtitle stream index (img_flow embedded)

scan_for_pairs() {
    local search_dir="$1"
    local label_prefix="$2"
    local paired_ext="$3"        # ex: "_norm.csv" | ".srt" | ".ass"
    local meta_extract_fn="$4"   # nume functie de extras meta (brand etc.) sau ""
    [ ! -d "$search_dir" ] && return
    while IFS= read -r -d '' vid; do
        local base; base="$(basename "$vid")"
        local name="${base%.*}"
        [[ "$name" == *_hud     ]] && continue
        [[ "$name" == *_telem   ]] && continue
        [[ "$name" == *_subs    ]] && continue
        [[ "$name" == *_preview ]] && continue
        local aux="$OUTPUT_DIR/${name}${paired_ext}"
        [ -s "$aux" ] || continue
        local meta=""
        if [ -n "$meta_extract_fn" ]; then meta=$("$meta_extract_fn" "$aux"); fi
        PAIRS_VIDEO+=("$vid")
        PAIRS_AUX+=("$aux")
        PAIRS_LABEL+=("[$label_prefix] $base${meta:+ [$meta]}")
        PAIRS_META+=("$meta")
    done < <(find "$search_dir" -maxdepth 2 -type f \( -iname "*.mp4" -o -iname "*.mov" -o -iname "*.mkv" -o -iname "*.m4v" \) -print0 2>/dev/null)
}

# extract brand din coloana source_brand a norm CSV (header-driven — col index variabil intre schema 18/24)
extract_brand_from_csv() {
    local csv="$1"
    awk -F',' '
        NR==1 { for (i=1; i<=NF; i++) { h=$i; gsub(/[" \r]/,"",h); if (h=="source_brand") c=i } }
        NR==2 { if (c) print $c; else print $NF }
    ' "$csv" 2>/dev/null | tr -d '"' | tr -d '\r' | head -c 32
}

# ── v58: HDR/LOG awareness ──────────────────────────────────────────
# State globale per-fisier (reset in show_burnin_hdr_dialog):
#   BURNIN_SOURCE_TYPE = sdr|dv|hdr10|hdr10plus|hlg|log
#   BURNIN_MODE        = sdr|preserve_hdr10|preserve_hdr10plus|preserve_hlg|tonemap|lut_rec709|burnin_raw|skip
#   BURNIN_PRE_FILTER  = filter chain prepended (lut3d=... | zscale...tonemap...)
#   BURNIN_ENC_EXTRA_ARGS = array de args ffmpeg extra (pix_fmt, color_*, x265-params, svtav1-params)
#   BURNIN_LUT_FILE        = path LUT cand mode=lut_rec709
#   BURNIN_HDR10PLUS_JSON  = path JSON HDR10+ cand mode=preserve_hdr10plus
#   BURNIN_DOWNGRADE_REASON = mesaj cand un mod e auto-fallback (ex: x264 + HDR → tonemap)
#
# Bypass non-interactive: BURNIN_HDR_POLICY env
#   preserve = preserve_* cand sursa e HDR; refuse_dv pe DV
#   tonemap  = tonemap → SDR pe HDR/LOG
#   skip     = skip pe HDR/LOG
#   lut      = LUT pe LOG (daca exista); tonemap pe HDR

# Returneaza eticheta human-readable pentru BURNIN_MODE
_burnin_mode_label() {
    case "$1" in
        sdr)                  echo "SDR (no transform)" ;;
        preserve_hdr10)       echo "Preserve HDR10" ;;
        preserve_hdr10plus)   echo "Preserve HDR10+" ;;
        preserve_hlg)         echo "Preserve HLG" ;;
        tonemap)              echo "Tonemap → SDR" ;;
        lut_rec709)           echo "Apply LUT (LOG → Rec.709)" ;;
        burnin_raw)           echo "Burn-in raw (no color transform)" ;;
        skip)                 echo "Skip" ;;
        *)                    echo "$1" ;;
    esac
}

# Classify source via globalele setate de detect_source_info
_burnin_classify_source() {
    BURNIN_SOURCE_TYPE="sdr"
    if [[ -n "${DOVI:-}" ]]; then
        BURNIN_SOURCE_TYPE="dv"
    elif [[ -n "${HDR_PLUS:-}" ]]; then
        BURNIN_SOURCE_TYPE="hdr10plus"
    elif [[ "${HDR_TYPE:-}" == *"smpte2084"* ]]; then
        BURNIN_SOURCE_TYPE="hdr10"
    elif [[ "${IS_HLG:-0}" == "1" ]]; then
        BURNIN_SOURCE_TYPE="hlg"
    elif [[ -n "${LOG_PROFILE:-}" ]]; then
        BURNIN_SOURCE_TYPE="log"
    fi
}

# Reset state per-fisier inainte de dialog
_burnin_reset_state() {
    BURNIN_SOURCE_TYPE="sdr"
    BURNIN_MODE="sdr"
    BURNIN_PRE_FILTER=""
    BURNIN_ENC_EXTRA_ARGS=()
    BURNIN_LUT_FILE=""
    BURNIN_HDR10PLUS_JSON=""
    BURNIN_DOWNGRADE_REASON=""
}

# Dialog per-fisier — alege transformarea HDR/LOG sau accepta default-ul.
# Necesita: detect_source_info DEJA apelat (seteaza DOVI, HDR_PLUS, HDR_TYPE,
#           IS_HLG, LOG_PROFILE, CAMERA_MAKE).
# Apel:     show_burnin_hdr_dialog "<file>"
# Seteaza:  BURNIN_MODE + state-ul aferent (vezi build_burnin_video_chain)
show_burnin_hdr_dialog() {
    local file="$1"
    _burnin_reset_state
    detect_source_info "$file" >/dev/null 2>&1 || true
    _burnin_classify_source

    # v88: sursa cu grup Eclipsa/IAMF — burn-in copiaza audio-ul prin ffmpeg, care
    # APLATIZEAZA grupul la Opus simplu → nota onesta, o data per fisier, INAINTE de
    # early-return-ul SDR (sursele Eclipsa au tipic video SDR). v90: graftul e cablat
    # pe output-ul COMPLET (audio-ul copy e timeline-1:1) → pe MP4/MOV grupul se
    # re-scrie automat; pe alte containere / pe PREVIEW (clip taiat) ramane aplatizat.
    if _iamf_probe "$file" >/dev/null 2>&1; then
        echo "  ℹ Sursa are grup Eclipsa/IAMF — la burn-in audio-ul se copiaza prin ffmpeg →"
        echo "    pe MP4/MOV grupul se RE-SCRIE automat dupa encode (v90); pe alte containere"
        echo "    si pe preview-uri ramane Opus simplu (pistele raman, spatialul se pierde)."
    fi

    # SDR → no dialog
    [[ "$BURNIN_SOURCE_TYPE" == "sdr" ]] && return 0

    # Policy env bypass
    if [[ -n "${BURNIN_HDR_POLICY:-}" ]]; then
        case "$BURNIN_HDR_POLICY" in
            preserve)
                case "$BURNIN_SOURCE_TYPE" in
                    dv)         BURNIN_MODE="skip" ;;
                    hdr10plus)  BURNIN_MODE="preserve_hdr10plus" ;;
                    hdr10)      BURNIN_MODE="preserve_hdr10" ;;
                    hlg)        BURNIN_MODE="preserve_hlg" ;;
                    log)        BURNIN_MODE="burnin_raw" ;;
                esac ;;
            tonemap)             BURNIN_MODE="tonemap" ;;
            skip)                BURNIN_MODE="skip" ;;
            lut)
                if [[ "$BURNIN_SOURCE_TYPE" == "log" ]] && find_lut_for_brand "${CAMERA_MAKE:-unknown}" >/dev/null 2>&1; then
                    BURNIN_MODE="lut_rec709"
                    BURNIN_LUT_FILE="${LUT_FILES[0]}"
                else
                    BURNIN_MODE="tonemap"
                fi ;;
            *)                   BURNIN_MODE="sdr" ;;
        esac
        return 0
    fi

    # Interactive dialog
    case "$BURNIN_SOURCE_TYPE" in
        dv)
            echo ""
            echo "  ⚠  Sursa Dolby Vision detectata (profil ${DOVI})"
            echo "     Burn-in pe DV distruge RPU references vizual — overlay-ul"
            echo "     rasters peste base layer, dar metadata RPU presupune un BL"
            echo "     neatins → playere DV vad imagine corupta."
            echo "     Recomandare: tonemap → SDR pentru burn-in, sau foloseste"
            echo "     av_hdr_dv_tools pentru transformari DV (fara overlay)."
            echo ""
            echo "  1) Tonemap → SDR (recomandat)"
            echo "  2) Skip [implicit]"
            read -p "  Alege 1-2 [implicit: 2]: " dv_choice
            case "${dv_choice:-2}" in
                1) BURNIN_MODE="tonemap" ;;
                *) BURNIN_MODE="skip" ;;
            esac ;;
        hdr10)
            echo ""
            echo "  Sursa HDR10 detectata (color_transfer=smpte2084)"
            echo "  1) Preserve HDR10 (pix_fmt p010le + master-display + max-cll) [implicit]"
            echo "  2) Tonemap → SDR"
            echo "  3) Skip"
            read -p "  Alege 1-3 [implicit: 1]: " h_choice
            case "${h_choice:-1}" in
                2) BURNIN_MODE="tonemap" ;;
                3) BURNIN_MODE="skip" ;;
                *) BURNIN_MODE="preserve_hdr10" ;;
            esac ;;
        hdr10plus)
            local _src_codec; _src_codec=$(detect_source_codec "$file" 2>/dev/null || true)
            echo ""
            echo "  Sursa HDR10+ detectata (src codec=$_src_codec)"
            if [[ "$_src_codec" == "av1" ]] && [[ "$ENC_NAME" == "libsvtav1" ]]; then
                echo "  1) Preserve HDR10+ inline (svtav1-params hdr10plus-json) [implicit]"
                echo "  2) Preserve HDR10 base (HDR10+ → HDR10 static, lossy)"
                echo "  3) Tonemap → SDR"
                echo "  4) Skip"
                read -p "  Alege 1-4 [implicit: 1]: " hp_choice
                case "${hp_choice:-1}" in
                    2) BURNIN_MODE="preserve_hdr10" ;;
                    3) BURNIN_MODE="tonemap" ;;
                    4) BURNIN_MODE="skip" ;;
                    *) BURNIN_MODE="preserve_hdr10plus" ;;
                esac
            else
                echo "  Notă: HDR10+ inline disponibil doar pe encoder libsvtav1 + sursa AV1."
                echo "        Cazul HEVC HDR10+ preserve complet via av_hdr_dv_tools."
                echo "  1) Preserve HDR10 base (HDR10+ → HDR10 static) [implicit]"
                echo "  2) Tonemap → SDR"
                echo "  3) Skip"
                read -p "  Alege 1-3 [implicit: 1]: " hp_choice
                case "${hp_choice:-1}" in
                    2) BURNIN_MODE="tonemap" ;;
                    3) BURNIN_MODE="skip" ;;
                    *) BURNIN_MODE="preserve_hdr10" ;;
                esac
            fi ;;
        hlg)
            echo ""
            echo "  Sursa HLG (BT.2100 HLG) detectata"
            echo "  1) Preserve HLG (pix_fmt p010le + transfer arib-std-b67) [implicit]"
            echo "  2) Tonemap → SDR"
            echo "  3) Skip"
            read -p "  Alege 1-3 [implicit: 1]: " hl_choice
            case "${hl_choice:-1}" in
                2) BURNIN_MODE="tonemap" ;;
                3) BURNIN_MODE="skip" ;;
                *) BURNIN_MODE="preserve_hlg" ;;
            esac ;;
        log)
            local _brand="${CAMERA_MAKE:-unknown}"
            local _log_label; _log_label=$(_log_profile_label "$LOG_PROFILE")
            local _has_lut=0
            find_lut_for_brand "$_brand" >/dev/null 2>&1 && _has_lut=1
            echo ""
            echo "  Sursa LOG: $_log_label (brand=$_brand)"
            # v62: conversia fara-LUT (tonemap) ELIMINATA pe LOG — Log→Rec.709 cere LUT.
            # Fara LUT raman doar Burn-in raw (pastreaza look-ul flat) / Skip.
            if [[ "$_has_lut" == 1 ]]; then
                local _lut_name="${LUT_FILES[0]##*/}"
                echo "  1) Apply LUT Rec.709 (${_lut_name}) [implicit]"
                echo "  2) Burn-in raw (pastreaza LOG look)"
                echo "  3) Skip"
                read -p "  Alege 1-3 [implicit: 1]: " lg_choice
                case "${lg_choice:-1}" in
                    2) BURNIN_MODE="burnin_raw" ;;
                    3) BURNIN_MODE="skip" ;;
                    *) BURNIN_MODE="lut_rec709"; BURNIN_LUT_FILE="${LUT_FILES[0]}" ;;
                esac
            else
                echo "  (Fara LUT in Luts/ — conversia corecta Log→Rec.709 nu e posibila.)"
                echo "  1) Burn-in raw (pastreaza LOG look) [implicit]"
                echo "  2) Skip"
                read -p "  Alege 1-2 [implicit: 1]: " lg_choice
                case "${lg_choice:-1}" in
                    2) BURNIN_MODE="skip" ;;
                    *) BURNIN_MODE="burnin_raw" ;;
                esac
            fi ;;
    esac
}

# Construieste BURNIN_PRE_FILTER + BURNIN_ENC_EXTRA_ARGS pe baza BURNIN_MODE.
# Apel: dupa show_burnin_hdr_dialog (citeste BURNIN_MODE + ENC_NAME).
# Return: 0 ok, 1 skip (caller trebuie sa continue cu next file).
build_burnin_video_chain() {
    local file="$1"
    local encoder="${ENC_NAME:-libx265}"
    BURNIN_PRE_FILTER=""
    BURNIN_ENC_EXTRA_ARGS=()
    case "$BURNIN_MODE" in
        skip)
            return 1 ;;
        sdr|burnin_raw)
            return 0 ;;
        lut_rec709)
            local _lut_esc; _lut_esc=$(escape_ffmpeg_filter_path "$BURNIN_LUT_FILE")
            # v62 audit: setparams re-eticheteaza culoarea pe frame (lut3d nu o atinge →
            # ramanea bt2020/unknown de la sursa, mis-tagged pe ORICE container).
            BURNIN_PRE_FILTER="lut3d='${_lut_esc}',setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709"
            return 0 ;;
        tonemap)
            # v85 (F9): DV Profile 5/7 au baza IPT cu color_transfer=unknown → zscale
            # nu poate liniariza ("no path between colorspaces") → tonemap-ul (optiunea
            # RECOMANDATA in dialogul DV) CRAPA. Prepend setparams=PQ/BT.2020 DOAR cand
            # transferul e necunoscut (baza P5/P7 e HDR10-like). P8.1 (smpte2084) si P8.4
            # (arib) au transfer cunoscut → tonemap corect fara prefix, deci nu le atingem.
            local _tm_trc; _tm_trc=$(ffprobe -v error -select_streams v:0 \
                -show_entries stream=color_transfer -of default=nw=1:nk=1 "$file" 2>/dev/null | head -1 | tr -d '\r')
            local _tm_pre=""
            if [[ -z "$_tm_trc" || "$_tm_trc" == "unknown" ]]; then
                _tm_pre="setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc,"
            fi
            BURNIN_PRE_FILTER="${_tm_pre}zscale=transfer=linear:matrix=bt709:primaries=bt709,tonemap=hable:desat=0,zscale=transfer=bt709:matrix=bt709:primaries=bt709,format=yuv420p"
            return 0 ;;
        preserve_hdr10)
            if [[ "$encoder" == "libx264" ]]; then
                BURNIN_DOWNGRADE_REASON="libx264 nu suporta 10-bit HDR in builds standard — auto-tonemap aplicat"
                BURNIN_PRE_FILTER="zscale=transfer=linear:matrix=bt709:primaries=bt709,tonemap=hable:desat=0,zscale=transfer=bt709:matrix=bt709:primaries=bt709,format=yuv420p"
                return 0
            fi
            BURNIN_ENC_EXTRA_ARGS+=(-pix_fmt yuv420p10le)
            BURNIN_ENC_EXTRA_ARGS+=(-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc)
            hdr10_static_resolve "$file" >/dev/null 2>&1 || true
            if [[ "$encoder" == "libx265" ]]; then
                local _x265p="hdr10=1:hdr10-opt=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc"
                if [[ "${HDR10_STATIC_AVAILABLE:-0}" == "1" ]] && [[ -n "${HDR10_MASTER_DISPLAY_X265:-}" ]]; then
                    _x265p="${_x265p}:master-display=${HDR10_MASTER_DISPLAY_X265}"
                    [[ -n "$HDR10_MAX_CLL" ]] && _x265p="${_x265p}:max-cll=${HDR10_MAX_CLL}"
                fi
                BURNIN_ENC_EXTRA_ARGS+=(-x265-params "$_x265p")
            elif [[ "$encoder" == "libsvtav1" ]]; then
                local _av1p="enable-hdr=1"
                if [[ "${HDR10_STATIC_AVAILABLE:-0}" == "1" ]] && [[ -n "${HDR10_MASTER_DISPLAY_SVTAV1:-}" ]]; then
                    _av1p="${_av1p}:mastering-display=${HDR10_MASTER_DISPLAY_SVTAV1}"
                    [[ -n "$HDR10_MAX_CLL" ]] && _av1p="${_av1p}:content-light=${HDR10_MAX_CLL}"
                fi
                BURNIN_ENC_EXTRA_ARGS+=(-svtav1-params "$_av1p")
            fi
            return 0 ;;
        preserve_hdr10plus)
            local _src_codec; _src_codec=$(detect_source_codec "$file" 2>/dev/null || true)
            if [[ "$encoder" != "libsvtav1" ]] || [[ "$_src_codec" != "av1" ]]; then
                BURNIN_DOWNGRADE_REASON="HDR10+ inline disponibil doar svtav1+av1 — fallback HDR10 base"
                BURNIN_MODE="preserve_hdr10"
                build_burnin_video_chain "$file"
                return $?
            fi
            local _json
            _json=$(extract_hdr10plus_metadata "$file" 2>/dev/null || true)
            if [[ -z "$_json" ]] || [[ ! -s "$_json" ]]; then
                BURNIN_DOWNGRADE_REASON="HDR10+ extract esuat — fallback HDR10 base"
                BURNIN_MODE="preserve_hdr10"
                build_burnin_video_chain "$file"
                return $?
            fi
            BURNIN_HDR10PLUS_JSON="$_json"
            BURNIN_ENC_EXTRA_ARGS+=(-pix_fmt yuv420p10le)
            BURNIN_ENC_EXTRA_ARGS+=(-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc)
            hdr10_static_resolve "$file" >/dev/null 2>&1 || true
            local _av1p="enable-hdr=1:hdr10plus-json=${_json}"
            if [[ "${HDR10_STATIC_AVAILABLE:-0}" == "1" ]] && [[ -n "${HDR10_MASTER_DISPLAY_SVTAV1:-}" ]]; then
                _av1p="${_av1p}:mastering-display=${HDR10_MASTER_DISPLAY_SVTAV1}"
                [[ -n "$HDR10_MAX_CLL" ]] && _av1p="${_av1p}:content-light=${HDR10_MAX_CLL}"
            fi
            BURNIN_ENC_EXTRA_ARGS+=(-svtav1-params "$_av1p")
            return 0 ;;
        preserve_hlg)
            if [[ "$encoder" == "libx264" ]]; then
                BURNIN_DOWNGRADE_REASON="libx264 nu suporta 10-bit HLG in builds standard — auto-tonemap aplicat"
                BURNIN_PRE_FILTER="zscale=transfer=linear:matrix=bt709:primaries=bt709,tonemap=hable:desat=0,zscale=transfer=bt709:matrix=bt709:primaries=bt709,format=yuv420p"
                return 0
            fi
            BURNIN_ENC_EXTRA_ARGS+=(-pix_fmt yuv420p10le)
            BURNIN_ENC_EXTRA_ARGS+=(-color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc)
            if [[ "$encoder" == "libx265" ]]; then
                BURNIN_ENC_EXTRA_ARGS+=(-x265-params "transfer=arib-std-b67:colormatrix=bt2020nc:colorprim=bt2020")
            elif [[ "$encoder" == "libsvtav1" ]]; then
                BURNIN_ENC_EXTRA_ARGS+=(-svtav1-params "enable-hdr=1:color-primaries=9:transfer-characteristics=18:matrix-coefficients=9")
            fi
            return 0 ;;
        *)
            return 0 ;;
    esac
}

# Reset arrays + scan
reset_pairs() {
    PAIRS_VIDEO=(); PAIRS_AUX=(); PAIRS_LABEL=(); PAIRS_META=()
    PAIRS_KIND=(); PAIRS_TRACK=()
}

# Selectie generica index/lista/ALL
pick_files() {
    local total=${#PAIRS_VIDEO[@]}
    [ "$total" -eq 0 ] && { echo "Nimic de selectat."; exit 0; }
    for i in "${!PAIRS_LABEL[@]}"; do
        printf "  %2d) %s\n" "$((i+1))" "${PAIRS_LABEL[$i]}"
    done
    echo ""
    read -p "Selecteaza index (ex: 1 sau 1,3,5 sau ALL) [implicit ALL]: " sel
    sel="${sel:-ALL}"
    SELECTED=()
    if [[ "$sel" =~ ^[Aa][Ll][Ll]$ ]]; then
        for i in "${!PAIRS_VIDEO[@]}"; do SELECTED+=("$i"); done
    else
        IFS=',' read -ra parts <<< "$sel"
        for p in "${parts[@]}"; do
            p="${p// /}"
            [[ "$p" =~ ^[0-9]+$ ]] || { echo "Index invalid: $p"; exit 1; }
            idx=$((p-1))
            [ "$idx" -ge 0 ] && [ "$idx" -lt "$total" ] || { echo "Index in afara range: $p"; exit 1; }
            SELECTED+=("$idx")
        done
    fi
    # v85 (F5): garda era `[ ... ] && { ...; }` ca ULTIMA comanda a functiei →
    # pe selectie NE-goala (cazul normal!) testul intoarce 1 → functia intoarce 1
    # → set -e omora scriptul imediat dupa selectie (toate 4 fluxurile, din v48).
    if [ "${#SELECTED[@]}" -eq 0 ]; then echo "Nimic selectat."; exit 0; fi
}

# ──────────────────────────────────────────────────────────────────────
# FLOW 1: HUD telemetrie
# ──────────────────────────────────────────────────────────────────────
# ── A (v82): filtru de display pentru still preview ───────────────────
# Lantul aplicat cadrului video INAINTE de overlay, DOAR pentru PNG-ul de
# preview (8-bit). Pre-filter existent (tonemap/LUT) are prioritate; pe
# HDR-preserve (pre-filter gol) tonemapeaza ca PNG-ul sa nu iasa stins.
# BURNIN_STILL_NO_TONEMAP=1 -> sare tonemap-ul (raw). SDR -> gol.
_burnin_still_display_filter() {
    if [[ -n "$BURNIN_PRE_FILTER" ]]; then
        printf '%s' "$BURNIN_PRE_FILTER"; return 0
    fi
    if [[ "${BURNIN_STILL_NO_TONEMAP:-0}" != "1" ]] && \
       [[ "$BURNIN_SOURCE_TYPE" == "hdr10" || "$BURNIN_SOURCE_TYPE" == "hdr10plus" || "$BURNIN_SOURCE_TYPE" == "hlg" ]]; then
        printf '%s' "zscale=t=linear:npl=100,tonemap=tonemap=hable,zscale=t=bt709:m=bt709:p=bt709:r=tv,format=yuv420p"
    fi
    return 0
}

# ── B (v82): text shaping pt subtitrari (libass HarfBuzz; subtitles/ass) ──
# Optiunea `shaping` e NEW in ffmpeg -> gate de capabilitate. Pt scripturi
# complexe (araba/ebraica/indic). SUB_SHAPING gol = auto (default-ul filtrului).
_BURNIN_SHAPING_CAP=""
_burnin_subtitles_has_shaping() {
    if [ -z "$_BURNIN_SHAPING_CAP" ]; then
        if ffmpeg -hide_banner -h filter=subtitles 2>/dev/null | grep -q "shaping"; then
            _BURNIN_SHAPING_CAP=1
        else
            _BURNIN_SHAPING_CAP=0
        fi
    fi
    [ "$_BURNIN_SHAPING_CAP" = "1" ]
}
SUB_SHAPING=""
ask_burnin_shaping() {
    SUB_SHAPING=""
    _burnin_subtitles_has_shaping || return 0
    echo ""
    echo "  Text shaping (scripturi complexe: araba / ebraica / indic):"
    echo "    1) auto [implicit]   2) simple   3) complex"
    read -p "  Alege 1-3 [implicit 1]: " _shp
    case "${_shp:-1}" in
        2) SUB_SHAPING="simple" ;;
        3) SUB_SHAPING="complex" ;;
        *) SUB_SHAPING="" ;;
    esac
    # v85 (F5): `[ -n ] && echo` ca ultima comanda → pe default (auto, gol)
    # functia intorcea 1 → set -e omora srt/ass flow dupa promptul de shaping.
    if [ -n "$SUB_SHAPING" ]; then echo "  → shaping=$SUB_SHAPING"; fi
}

hud_flow() {
    # Deps Python+matplotlib (doar pt HUD)
    local have_python=0 have_matplotlib=0
    command -v python3 &>/dev/null && have_python=1
    if [ "$have_python" -eq 1 ]; then
        python3 -c "import matplotlib, numpy" 2>/dev/null && have_matplotlib=1
    fi
    if [ "$have_python" -eq 0 ]; then
        echo "EROARE: python3 nu este instalat (necesar pentru HUD render)."
        echo "Instaleaza cu: $(av_pkg_install_hint python3)"
        exit 1
    fi
    if [ "$have_matplotlib" -eq 0 ]; then
        echo "EROARE: matplotlib / numpy lipsesc."
        echo "Instaleaza cu: pip install matplotlib numpy pillow"
        echo "  Termux: pkg install python-numpy && pip install matplotlib pillow"
        exit 1
    fi
    [ -f "$RENDER_PY" ] || { echo "EROARE: $RENDER_PY lipseste."; exit 1; }

    reset_pairs
    scan_for_pairs "$OUTPUT_DIR" "OUT" "_norm.csv" extract_brand_from_csv
    scan_for_pairs "$INPUT_DIR"  "IN"  "_norm.csv" extract_brand_from_csv
    local total=${#PAIRS_VIDEO[@]}
    if [ "$total" -eq 0 ]; then
        echo ""
        echo "Nu am gasit nicio pereche video + norm CSV."
        echo "  Asigura-te ca exista <name>_norm.csv in $OUTPUT_DIR"
        echo "  (Genereaza cu av_telemetry sau av_extractor_gps)."
        exit 0
    fi

    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  HUD TELEMETRY OVERLAY                        ║"
    echo "║  Perechi gasite: $total"
    echo "║  Input  : $INPUT_DIR"
    echo "║  Output : $OUTPUT_DIR"
    echo "╚══════════════════════════════════════════════╝"
    echo ""
    pick_files

    # Layout preset
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  LAYOUT PRESET                                ║"
    echo "╠══════════════════════════════════════════════╣"
    echo "║  1) minimal     — timestamp + speed (corner)  ║"
    echo "║  2) data-strip  — bottom bar gauges          ║"
    echo "║  3) full        — data-strip + map + extras  ║"
    echo "║     [implicit]                                ║"
    echo "║  4) custom      — preset salvat (Designer)    ║"
    echo "║  5) Anulare                                   ║"
    echo "╚══════════════════════════════════════════════╝"
    read -p "Alege 1-5 [implicit: 3]: " preset_choice
    local preset_file=""
    case "${preset_choice:-3}" in
        1) PRESET="minimal" ;;
        2) PRESET="data-strip" ;;
        3) PRESET="full" ;;
        4)
            # v84: preseturi salvate de Designer (UserProfiles/burnin/)
            local _cust_dir="$USER_PROFILES_DIR/burnin"
            shopt -s nullglob
            local _cust_confs=("$_cust_dir"/*.conf)
            shopt -u nullglob
            if [ "${#_cust_confs[@]}" -eq 0 ]; then
                echo ""
                echo "Niciun preset custom in $_cust_dir."
                echo "  Creeaza unul cu Designerul vizual (meniul Burn-in, optiunea 5)."
                exit 0
            fi
            for i in "${!_cust_confs[@]}"; do
                printf "  %2d) %s\n" "$((i+1))" "$(basename "${_cust_confs[$i]}" .conf)"
            done
            echo ""
            read -p "Alege preset [implicit 1]: " _cust_idx
            _cust_idx="${_cust_idx:-1}"
            [[ "$_cust_idx" =~ ^[0-9]+$ ]] || { echo "Index invalid."; exit 1; }
            local _ci=$((_cust_idx-1))
            [ "$_ci" -ge 0 ] && [ "$_ci" -lt "${#_cust_confs[@]}" ] || { echo "Index in afara range."; exit 1; }
            preset_file="${_cust_confs[$_ci]}"
            PRESET="$(basename "$preset_file" .conf)"
            ;;
        5) echo "Anulat."; exit 0 ;;
        *) PRESET="full" ;;
    esac
    [ -n "$preset_file" ] || preset_file="$PRESETS_DIR/${PRESET}.conf"
    [ -s "$preset_file" ] || { echo "EROARE: preset $PRESET nu exista ($preset_file)"; exit 1; }

    # HUD fps
    echo ""
    read -p "HUD frame rate [implicit: 10 fps] (recomandat 10-30): " hud_fps
    HUD_FPS="${hud_fps:-10}"
    [[ "$HUD_FPS" =~ ^[0-9]+$ ]] || HUD_FPS=10
    [ "$HUD_FPS" -lt 1 ] && HUD_FPS=10
    [ "$HUD_FPS" -gt 60 ] && HUD_FPS=60

    ask_encoder
    ask_preview 1

    local ok=0 fail=0
    for idx in "${SELECTED[@]}"; do
        local vid="${PAIRS_VIDEO[$idx]}"
        local csv="${PAIRS_AUX[$idx]}"
        local brand="${PAIRS_META[$idx]}"
        local base; base="$(basename "$vid")"
        local name="${base%.*}"; local ext="${base##*.}"

        echo ""
        echo "─────────────────────────────────────────────"
        echo "  ── $((idx+1))/$total: $base  [$brand]"
        echo "─────────────────────────────────────────────"

        # v58: HDR/LOG dialog + chain build
        show_burnin_hdr_dialog "$vid"
        if ! build_burnin_video_chain "$vid"; then
            echo "  [SKIP] mod=$(_burnin_mode_label "$BURNIN_MODE") — sar la urmatorul fisier"
            continue
        fi
        if [[ "$BURNIN_SOURCE_TYPE" != "sdr" ]]; then
            echo "  Sursa: $BURNIN_SOURCE_TYPE → mod: $(_burnin_mode_label "$BURNIN_MODE")"
            [[ -n "$BURNIN_DOWNGRADE_REASON" ]] && echo "  ⚠ $BURNIN_DOWNGRADE_REASON"
        fi

        # Sync offset (auto interne, prompt external_*)
        local sync_offset=0
        case "$brand" in
            external_*)
                echo "  Brand sursa: $brand — telemetria poate fi nesincronizata cu video."
                read -p "  Sync offset in secunde (+/-, implicit 0): " sync_offset
                sync_offset="${sync_offset:-0}"
                [[ "$sync_offset" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || sync_offset=0
                ;;
        esac

        # v57: default= in loc de csv=p=0 — single-field width/height emit trailing
        # comma "3840," → Python script primea int invalid si crash-uia.
        local vid_dur; vid_dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$vid" 2>/dev/null | head -1)
        local vid_w; vid_w=$(ffprobe -v error -select_streams v:0 -show_entries stream=width  -of default=noprint_wrappers=1:nokey=1 "$vid" 2>/dev/null | head -1)
        local vid_h; vid_h=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 "$vid" 2>/dev/null | head -1)
        [ -z "$vid_dur" ] && vid_dur=0
        [ -z "$vid_w" ]   && vid_w=1920
        [ -z "$vid_h" ]   && vid_h=1080

        # ── Still layout preview (Tier 1): 1 cadru compus, FARA encode video ──
        if [ "$PREVIEW_STILL" -eq 1 ]; then
            local _st_t=0
            preview_compute_window "$vid_dur" && _st_t="$PREVIEW_T_START"
            local _st_dir="$AV_TEMP_DIR/burnin_still_${name}_$$"
            mkdir -p "$_st_dir"
            local _st_grid=()
            [ "$PREVIEW_GRID" -eq 1 ] && _st_grid=(--grid)
            echo "  Still preview: 1 cadru la ${_st_t}s (preset=$PRESET$([ "$PREVIEW_GRID" -eq 1 ] && echo " + grila"))..."
            if ! python3 "$RENDER_PY" \
                --csv "$csv" --preset "$preset_file" --output-dir "$_st_dir" \
                --fps "$HUD_FPS" --duration 1 --single "$_st_t" \
                --width "$vid_w" --height "$vid_h" \
                --offset "$sync_offset" --brand "$brand" "${_st_grid[@]}"; then
                echo "  [EROARE] Render still esuat"; rm -rf "$_st_dir"; fail=$((fail+1)); continue
            fi
            local _st_out="$OUTPUT_DIR/${name}_preview.png"
            local _st_disp; _st_disp="$(_burnin_still_display_filter)"
            local _st_fc
            if [[ -n "$_st_disp" ]]; then
                _st_fc="[0:v]${_st_disp}[bb];[bb][1:v]overlay=0:0[v]"
            else
                _st_fc="[0:v][1:v]overlay=0:0[v]"
            fi
            [[ -z "$BURNIN_PRE_FILTER" && -n "$_st_disp" ]] && echo "  (still tonemapped pentru preview; output-ul real pastreaza HDR)"
            echo "  Compun still (cadru video la ${_st_t}s + HUD)..."
            if ffmpeg -v error -ss "$_st_t" -i "$vid" -i "$_st_dir/frame_000001.png" \
                -filter_complex "$_st_fc" -map "[v]" -frames:v 1 -y "$_st_out" </dev/null; then
                echo "  [OK] $_st_out"; ok=$((ok+1))
                av_open_path "$_st_out" 2>/dev/null || true
            else
                echo "  [EROARE] Compozitie still esuata"; rm -f "$_st_out"; fail=$((fail+1))
            fi
            rm -rf "$_st_dir"
            [[ -n "$BURNIN_HDR10PLUS_JSON" ]] && rm -f "$BURNIN_HDR10PLUS_JSON"
            continue
        fi

        local frames_dir="$AV_TEMP_DIR/burnin_${name}_$$"
        mkdir -p "$frames_dir"

        # Preview: render doar 5s la mid; ofset CSV decalat pentru a viza fereastra
        local render_dur="$vid_dur" render_offset="$sync_offset"
        local out_suffix="hud"
        local seek_args=()
        if [ "$PREVIEW_MODE" -eq 1 ]; then
            if preview_compute_window "$vid_dur"; then
                render_dur="$PREVIEW_DURATION"
                render_offset=$(awk -v s="$sync_offset" -v t="$PREVIEW_T_START" 'BEGIN{printf "%.3f", s+t}')
                out_suffix="preview"
                seek_args=(-ss "$PREVIEW_T_START" -t "$PREVIEW_DURATION")
                echo "  Preview window: ${PREVIEW_T_START}s + ${PREVIEW_DURATION}s (din ${vid_dur}s)"
            else
                echo "  [WARN] Durata invalida ($vid_dur) — preview skipped, fall back la full encode."
            fi
        fi

        echo "  Render PNG sequence (preset=$PRESET, hud_fps=$HUD_FPS, dur=${render_dur}s)..."
        if ! python3 "$RENDER_PY" \
            --csv "$csv" --preset "$preset_file" --output-dir "$frames_dir" \
            --fps "$HUD_FPS" --duration "$render_dur" --width "$vid_w" --height "$vid_h" \
            --offset "$render_offset" --brand "$brand"; then
            echo "  [EROARE] Render PNG sequence esuat"
            rm -rf "$frames_dir"; fail=$((fail+1)); continue
        fi

        local out="$OUTPUT_DIR/${name}_${out_suffix}.${ext}"
        local _codec_tag; _codec_tag=$(codec_tag_for_container "$ENC_CODEC_KEY" "$ext")
        # v58: pre-filter (LUT/tonemap) injectat in filter_complex inainte de overlay
        # v85 (F6): ffmpeg nou negociaza formate CU alpha la iesirea overlay-ului
        # (PNG-ul HUD e RGBA → [v]=yuva420p) iar libx265 refuza deschiderea
        # ("does not support alpha layer encoding") → format EXPLICIT dupa overlay.
        # 10-bit pe modurile preserve (lantul HDR ramane 10-bit), altfel 8-bit.
        local _fc _ov_fmt="yuv420p"
        case "$BURNIN_MODE" in preserve_hdr10|preserve_hdr10plus|preserve_hlg) _ov_fmt="yuv420p10le" ;; esac
        if [[ -n "$BURNIN_PRE_FILTER" ]]; then
            _fc="[0:v]${BURNIN_PRE_FILTER}[burnin_base];[burnin_base][1:v]overlay=0:0:shortest=0,format=${_ov_fmt}[v]"
        else
            _fc="[0:v][1:v]overlay=0:0:shortest=0,format=${_ov_fmt}[v]"
        fi
        echo "  Overlay + re-encode ($ENC_NAME CRF $ENC_CRF preset $ENC_PRESET)..."
        # shellcheck disable=SC2086
        if ffmpeg -v error -stats \
            "${seek_args[@]}" -i "$vid" \
            -framerate "$HUD_FPS" \
            -i "$frames_dir/frame_%06d.png" \
            -filter_complex "$_fc" \
            -map "[v]" -map "0:a?" \
            -c:v "$ENC_NAME" -crf "$ENC_CRF" -preset "$ENC_PRESET" \
            "${BURNIN_ENC_EXTRA_ARGS[@]}" \
            -c:a copy $_codec_tag -movflags +faststart "$out" -y </dev/null; then
            echo "  [OK] $out"; ok=$((ok+1))
            # v90: sursa cu grup Eclipsa/IAMF → re-graft pe output-ul COMPLET (audio-ul
            # copy e timeline-1:1); NU pe preview (clip taiat → substream-urile nu se
            # regrupeaza — regula trim/concat). Soft: non-IAMF no-op, non-ISO warn onest.
            if [[ "$out_suffix" != "preview" ]]; then
                _iamf_preserve "$vid" "$out" || true
            fi
        else
            echo "  [EROARE] ffmpeg overlay esuat"; rm -f "$out"; fail=$((fail+1))
        fi
        rm -rf "$frames_dir"
        [[ -n "$BURNIN_HDR10PLUS_JSON" ]] && rm -f "$BURNIN_HDR10PLUS_JSON"
    done

    echo ""
    echo "═══════════════════════════════════════════════"
    echo "  Sumar HUD burn-in: $ok OK, $fail esuate (din ${#SELECTED[@]} selectate)"
    echo "═══════════════════════════════════════════════"
}

# ──────────────────────────────────────────────────────────────────────
# FLOW 2: SRT burn-in
# ──────────────────────────────────────────────────────────────────────
srt_flow() {
    reset_pairs
    scan_for_pairs "$OUTPUT_DIR" "OUT" ".srt" ""
    scan_for_pairs "$INPUT_DIR"  "IN"  ".srt" ""
    local total=${#PAIRS_VIDEO[@]}
    if [ "$total" -eq 0 ]; then
        echo ""
        echo "Nu am gasit nicio pereche video + .srt."
        echo "  Asigura-te ca exista <name>.srt langa video sau in $OUTPUT_DIR"
        exit 0
    fi

    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  SRT BURN-IN (subtitrari hardcoded)           ║"
    echo "║  Perechi gasite: $total"
    echo "║  Input  : $INPUT_DIR"
    echo "║  Output : $OUTPUT_DIR"
    echo "╚══════════════════════════════════════════════╝"
    echo ""
    pick_files

    # Stil SRT
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  STIL SRT                                     ║"
    echo "╠══════════════════════════════════════════════╣"
    echo "║  1) Small  (font 18, white + black outline)   ║"
    echo "║     [implicit]                                ║"
    echo "║  2) Medium (font 24)                          ║"
    echo "║  3) Large  (font 32)                          ║"
    echo "║  4) Default ffmpeg (no override)              ║"
    echo "║  5) Anulare                                   ║"
    echo "╚══════════════════════════════════════════════╝"
    read -p "Alege 1-5 [implicit: 1]: " style_choice
    local force_style=""
    case "${style_choice:-1}" in
        1) force_style="FontSize=18,PrimaryColour=&H00FFFFFF,OutlineColour=&H00000000,Outline=2,Shadow=1" ;;
        2) force_style="FontSize=24,PrimaryColour=&H00FFFFFF,OutlineColour=&H00000000,Outline=2,Shadow=1" ;;
        3) force_style="FontSize=32,PrimaryColour=&H00FFFFFF,OutlineColour=&H00000000,Outline=3,Shadow=1" ;;
        4) force_style="" ;;
        5) echo "Anulat."; exit 0 ;;
        *) force_style="FontSize=18,PrimaryColour=&H00FFFFFF,OutlineColour=&H00000000,Outline=2,Shadow=1" ;;
    esac

    ask_burnin_shaping

    ask_encoder
    ask_preview

    local ok=0 fail=0
    for idx in "${SELECTED[@]}"; do
        local vid="${PAIRS_VIDEO[$idx]}"
        local srt="${PAIRS_AUX[$idx]}"
        local base; base="$(basename "$vid")"
        local name="${base%.*}"; local ext="${base##*.}"

        echo ""
        echo "─────────────────────────────────────────────"
        echo "  ── $((idx+1))/$total: $base"
        echo "─────────────────────────────────────────────"

        # v58: HDR/LOG dialog + chain build
        show_burnin_hdr_dialog "$vid"
        if ! build_burnin_video_chain "$vid"; then
            echo "  [SKIP] mod=$(_burnin_mode_label "$BURNIN_MODE") — sar la urmatorul fisier"
            continue
        fi
        if [[ "$BURNIN_SOURCE_TYPE" != "sdr" ]]; then
            echo "  Sursa: $BURNIN_SOURCE_TYPE → mod: $(_burnin_mode_label "$BURNIN_MODE")"
            [[ -n "$BURNIN_DOWNGRADE_REASON" ]] && echo "  ⚠ $BURNIN_DOWNGRADE_REASON"
        fi

        local srt_esc; srt_esc=$(escape_ffmpeg_filter_path "$srt")
        local vf="subtitles='${srt_esc}'"
        [ -n "$force_style" ] && vf="${vf}:force_style='${force_style}'"
        [ -n "$SUB_SHAPING" ] && vf="${vf}:shaping=${SUB_SHAPING}"
        # v58: pre-filter (LUT/tonemap) prepended in -vf chain
        [ -n "$BURNIN_PRE_FILTER" ] && vf="${BURNIN_PRE_FILTER},${vf}"

        local out_suffix="subs"
        local seek_args=()
        if [ "$PREVIEW_MODE" -eq 1 ]; then
            local vid_dur; vid_dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$vid" 2>/dev/null | head -1)
            [ -z "$vid_dur" ] && vid_dur=0
            if preview_compute_window "$vid_dur"; then
                out_suffix="preview"
                seek_args=(-ss "$PREVIEW_T_START" -copyts -t "$PREVIEW_DURATION")
                echo "  Preview window: ${PREVIEW_T_START}s + ${PREVIEW_DURATION}s (din ${vid_dur}s)"
            else
                echo "  [WARN] Durata invalida ($vid_dur) — preview skipped, fall back la full encode."
            fi
        fi

        local out="$OUTPUT_DIR/${name}_${out_suffix}.${ext}"
        local _codec_tag; _codec_tag=$(codec_tag_for_container "$ENC_CODEC_KEY" "$ext")
        echo "  Burn-in SRT + re-encode ($ENC_NAME CRF $ENC_CRF preset $ENC_PRESET)..."
        # shellcheck disable=SC2086
        if ffmpeg -v error -stats \
            "${seek_args[@]}" -i "$vid" \
            -vf "$vf" \
            -c:v "$ENC_NAME" -crf "$ENC_CRF" -preset "$ENC_PRESET" \
            "${BURNIN_ENC_EXTRA_ARGS[@]}" \
            -c:a copy $_codec_tag -movflags +faststart "$out" -y </dev/null; then
            echo "  [OK] $out"; ok=$((ok+1))
            # v90: re-graft grupul Eclipsa/IAMF pe output-ul complet (NU pe preview)
            if [[ "$out_suffix" != "preview" ]]; then
                _iamf_preserve "$vid" "$out" || true
            fi
        else
            echo "  [EROARE] ffmpeg SRT burn-in esuat"; rm -f "$out"; fail=$((fail+1))
        fi
        [[ -n "$BURNIN_HDR10PLUS_JSON" ]] && rm -f "$BURNIN_HDR10PLUS_JSON"
    done

    echo ""
    echo "═══════════════════════════════════════════════"
    echo "  Sumar SRT burn-in: $ok OK, $fail esuate (din ${#SELECTED[@]} selectate)"
    echo "═══════════════════════════════════════════════"
}

# ──────────────────────────────────────────────────────────────────────
# FLOW 3: ASS burn-in
# ──────────────────────────────────────────────────────────────────────
ass_flow() {
    reset_pairs
    scan_for_pairs "$OUTPUT_DIR" "OUT" ".ass" ""
    scan_for_pairs "$INPUT_DIR"  "IN"  ".ass" ""
    local total=${#PAIRS_VIDEO[@]}
    if [ "$total" -eq 0 ]; then
        echo ""
        echo "Nu am gasit nicio pereche video + .ass."
        echo "  Asigura-te ca exista <name>.ass langa video sau in $OUTPUT_DIR"
        exit 0
    fi

    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  ASS BURN-IN (styled subtitles, anime)        ║"
    echo "║  Perechi gasite: $total"
    echo "║  Input  : $INPUT_DIR"
    echo "║  Output : $OUTPUT_DIR"
    echo "╚══════════════════════════════════════════════╝"
    echo ""
    pick_files

    # v82: ASS-urile isi poarta propriul styling (font, marime, culoare, pozitie)
    # in fisier -> nu oferim override de scale. Optiunile vechi 1.25x/1.5x foloseau
    # `force_style='ScaleX/Y'` pe filtrul `ass`, care NU are force_style -> erau
    # rupte din v48 (nu redau nimic). Folosim filtrul nativ `ass` (respecta styling-ul)
    # + shaping optional (filtrul `ass` suporta shaping nativ).
    echo ""
    echo "  ASS: styling embedded pastrat (font / marime / culoare din fisierul .ass)."

    ask_burnin_shaping

    ask_encoder
    ask_preview

    local ok=0 fail=0
    for idx in "${SELECTED[@]}"; do
        local vid="${PAIRS_VIDEO[$idx]}"
        local ass="${PAIRS_AUX[$idx]}"
        local base; base="$(basename "$vid")"
        local name="${base%.*}"; local ext="${base##*.}"

        echo ""
        echo "─────────────────────────────────────────────"
        echo "  ── $((idx+1))/$total: $base"
        echo "─────────────────────────────────────────────"

        # v58: HDR/LOG dialog + chain build
        show_burnin_hdr_dialog "$vid"
        if ! build_burnin_video_chain "$vid"; then
            echo "  [SKIP] mod=$(_burnin_mode_label "$BURNIN_MODE") — sar la urmatorul fisier"
            continue
        fi
        if [[ "$BURNIN_SOURCE_TYPE" != "sdr" ]]; then
            echo "  Sursa: $BURNIN_SOURCE_TYPE → mod: $(_burnin_mode_label "$BURNIN_MODE")"
            [[ -n "$BURNIN_DOWNGRADE_REASON" ]] && echo "  ⚠ $BURNIN_DOWNGRADE_REASON"
        fi

        local ass_esc; ass_esc=$(escape_ffmpeg_filter_path "$ass")
        local vf="ass='${ass_esc}'"
        [ -n "$SUB_SHAPING" ] && vf="${vf}:shaping=${SUB_SHAPING}"
        # v58: pre-filter (LUT/tonemap) prepended in -vf chain
        [ -n "$BURNIN_PRE_FILTER" ] && vf="${BURNIN_PRE_FILTER},${vf}"

        local out_suffix="subs"
        local seek_args=()
        if [ "$PREVIEW_MODE" -eq 1 ]; then
            local vid_dur; vid_dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$vid" 2>/dev/null | head -1)
            [ -z "$vid_dur" ] && vid_dur=0
            if preview_compute_window "$vid_dur"; then
                out_suffix="preview"
                seek_args=(-ss "$PREVIEW_T_START" -copyts -t "$PREVIEW_DURATION")
                echo "  Preview window: ${PREVIEW_T_START}s + ${PREVIEW_DURATION}s (din ${vid_dur}s)"
            else
                echo "  [WARN] Durata invalida ($vid_dur) — preview skipped, fall back la full encode."
            fi
        fi

        local out="$OUTPUT_DIR/${name}_${out_suffix}.${ext}"
        local _codec_tag; _codec_tag=$(codec_tag_for_container "$ENC_CODEC_KEY" "$ext")
        echo "  Burn-in ASS + re-encode ($ENC_NAME CRF $ENC_CRF preset $ENC_PRESET)..."
        # shellcheck disable=SC2086
        if ffmpeg -v error -stats \
            "${seek_args[@]}" -i "$vid" \
            -vf "$vf" \
            -c:v "$ENC_NAME" -crf "$ENC_CRF" -preset "$ENC_PRESET" \
            "${BURNIN_ENC_EXTRA_ARGS[@]}" \
            -c:a copy $_codec_tag -movflags +faststart "$out" -y </dev/null; then
            echo "  [OK] $out"; ok=$((ok+1))
            # v90: re-graft grupul Eclipsa/IAMF pe output-ul complet (NU pe preview)
            if [[ "$out_suffix" != "preview" ]]; then
                _iamf_preserve "$vid" "$out" || true
            fi
        else
            echo "  [EROARE] ffmpeg ASS burn-in esuat"; rm -f "$out"; fail=$((fail+1))
        fi
        [[ -n "$BURNIN_HDR10PLUS_JSON" ]] && rm -f "$BURNIN_HDR10PLUS_JSON"
    done

    echo ""
    echo "═══════════════════════════════════════════════"
    echo "  Sumar ASS burn-in: $ok OK, $fail esuate (din ${#SELECTED[@]} selectate)"
    echo "═══════════════════════════════════════════════"
}

# ──────────────────────────────────────────────────────────────────────
# FLOW 4: Image subs burn-in (Bluray PGS / DVD VobSub, ext + embedded)
# ──────────────────────────────────────────────────────────────────────
img_scan_dir() {
    local dir="$1" label="$2"
    [ ! -d "$dir" ] && return
    local have_ffprobe=0
    command -v ffprobe &>/dev/null && have_ffprobe=1
    while IFS= read -r -d '' vid; do
        local base; base="$(basename "$vid")"
        local name="${base%.*}"
        [[ "$name" == *_hud     ]] && continue
        [[ "$name" == *_telem   ]] && continue
        [[ "$name" == *_subs    ]] && continue
        [[ "$name" == *_preview ]] && continue
        local dir_of; dir_of="$(dirname "$vid")"

        # External PGS (.sup) — cauta langa video, apoi in OUTPUT_DIR
        local sup="$dir_of/${name}.sup"
        [ -s "$sup" ] || sup="$OUTPUT_DIR/${name}.sup"
        if [ -s "$sup" ]; then
            PAIRS_VIDEO+=("$vid"); PAIRS_AUX+=("$sup")
            PAIRS_LABEL+=("[$label] $base [PGS .sup]")
            PAIRS_META+=("ext_pgs"); PAIRS_KIND+=("ext_pgs"); PAIRS_TRACK+=("")
        fi

        # External VobSub (.idx + .sub)
        local idxf="$dir_of/${name}.idx"
        local subf="$dir_of/${name}.sub"
        if [ ! -s "$idxf" ] || [ ! -s "$subf" ]; then
            idxf="$OUTPUT_DIR/${name}.idx"
            subf="$OUTPUT_DIR/${name}.sub"
        fi
        if [ -s "$idxf" ] && [ -s "$subf" ]; then
            PAIRS_VIDEO+=("$vid"); PAIRS_AUX+=("$idxf")
            PAIRS_LABEL+=("[$label] $base [VobSub .idx/.sub]")
            PAIRS_META+=("ext_vob"); PAIRS_KIND+=("ext_vob"); PAIRS_TRACK+=("")
        fi

        # Embedded subtitle tracks (PGS / VobSub) — ffprobe enumerate
        # || true previne abort set -e cand ffprobe esueaza pe fisier corupt
        if [ "$have_ffprobe" -eq 1 ]; then
            local streams; streams=$(ffprobe -v error -select_streams s \
                -show_entries stream=index,codec_name:stream_tags=language \
                -of csv=p=0 "$vid" 2>/dev/null || true)
            local stream_idx=0
            local global_idx codec lang
            while IFS=, read -r global_idx codec lang; do
                [ -z "$codec" ] && continue
                lang="${lang//$'\r'/}"
                lang="${lang%,}"  # v58 audit: strip trailing comma de la csv=p=0 last field
                case "$codec" in
                    hdmv_pgs_subtitle)
                        PAIRS_VIDEO+=("$vid"); PAIRS_AUX+=("$vid")
                        PAIRS_LABEL+=("[$label] $base [PGS embedded s:${stream_idx}${lang:+ $lang}]")
                        PAIRS_META+=("emb_pgs"); PAIRS_KIND+=("emb_pgs"); PAIRS_TRACK+=("$stream_idx")
                        ;;
                    dvd_subtitle)
                        PAIRS_VIDEO+=("$vid"); PAIRS_AUX+=("$vid")
                        PAIRS_LABEL+=("[$label] $base [VobSub embedded s:${stream_idx}${lang:+ $lang}]")
                        PAIRS_META+=("emb_vob"); PAIRS_KIND+=("emb_vob"); PAIRS_TRACK+=("$stream_idx")
                        ;;
                esac
                stream_idx=$((stream_idx+1))
            done <<< "$streams"
        fi
    done < <(find "$dir" -maxdepth 2 -type f \( -iname "*.mp4" -o -iname "*.mov" -o -iname "*.mkv" -o -iname "*.m4v" \) -print0 2>/dev/null)
}

img_flow() {
    reset_pairs
    img_scan_dir "$OUTPUT_DIR" "OUT"
    img_scan_dir "$INPUT_DIR"  "IN"
    local total=${#PAIRS_VIDEO[@]}
    if [ "$total" -eq 0 ]; then
        echo ""
        echo "Nu am gasit nicio sursa de subtitrari imagine."
        echo "  Cautat: <name>.sup (PGS) / <name>.idx+.sub (VobSub) langa video sau in $OUTPUT_DIR"
        echo "  Cautat: track-uri embedded PGS/VobSub in MKV/MP4 (via ffprobe)"
        exit 0
    fi

    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  IMAGE SUBS BURN-IN (Bluray PGS / DVD VobSub) ║"
    echo "║  Surse gasite: $total"
    echo "║  Input  : $INPUT_DIR"
    echo "║  Output : $OUTPUT_DIR"
    echo "╚══════════════════════════════════════════════╝"
    echo ""
    pick_files

    # Notice — image subs nu suporta styling (bitmap, pre-rendered)
    echo ""
    echo "Notă: image subs (PGS/VobSub) sunt bitmap pre-rendered —"
    echo "      fără opțiuni de styling (font/size). Track selection only."

    ask_encoder
    ask_preview

    local ok=0 fail=0
    for idx in "${SELECTED[@]}"; do
        local vid="${PAIRS_VIDEO[$idx]}"
        local aux="${PAIRS_AUX[$idx]}"
        local kind="${PAIRS_KIND[$idx]}"
        local track="${PAIRS_TRACK[$idx]}"
        local base; base="$(basename "$vid")"
        local name="${base%.*}"; local ext="${base##*.}"

        echo ""
        echo "─────────────────────────────────────────────"
        echo "  ── $((idx+1))/$total: $base  [$kind${track:+ s:$track}]"
        echo "─────────────────────────────────────────────"

        # v58: HDR/LOG dialog + chain build
        show_burnin_hdr_dialog "$vid"
        if ! build_burnin_video_chain "$vid"; then
            echo "  [SKIP] mod=$(_burnin_mode_label "$BURNIN_MODE") — sar la urmatorul fisier"
            continue
        fi
        if [[ "$BURNIN_SOURCE_TYPE" != "sdr" ]]; then
            echo "  Sursa: $BURNIN_SOURCE_TYPE → mod: $(_burnin_mode_label "$BURNIN_MODE")"
            [[ -n "$BURNIN_DOWNGRADE_REASON" ]] && echo "  ⚠ $BURNIN_DOWNGRADE_REASON"
        fi

        local out_suffix="subs"
        local seek_args=()
        if [ "$PREVIEW_MODE" -eq 1 ]; then
            local vid_dur; vid_dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$vid" 2>/dev/null | head -1)
            [ -z "$vid_dur" ] && vid_dur=0
            if preview_compute_window "$vid_dur"; then
                out_suffix="preview"
                seek_args=(-ss "$PREVIEW_T_START" -copyts -t "$PREVIEW_DURATION")
                echo "  Preview window: ${PREVIEW_T_START}s + ${PREVIEW_DURATION}s (din ${vid_dur}s)"
            else
                echo "  [WARN] Durata invalida ($vid_dur) — preview skipped, fall back la full encode."
            fi
        fi

        local out="$OUTPUT_DIR/${name}_${out_suffix}.${ext}"
        local _codec_tag; _codec_tag=$(codec_tag_for_container "$ENC_CODEC_KEY" "$ext")
        # v58: pre-filter (LUT/tonemap) injectat in filter_complex inainte de overlay
        # v85 (F6): subpicture-urile (PGS/VobSub) au alpha → ffmpeg nou negociaza
        # yuva* la iesirea overlay → x265 refuza → format EXPLICIT dupa overlay
        # (10-bit pe modurile preserve, altfel 8-bit — ca la HUD).
        local _fc_ext _fc_emb _ov_fmt="yuv420p"
        case "$BURNIN_MODE" in preserve_hdr10|preserve_hdr10plus|preserve_hlg) _ov_fmt="yuv420p10le" ;; esac
        if [[ -n "$BURNIN_PRE_FILTER" ]]; then
            _fc_ext="[0:v]${BURNIN_PRE_FILTER}[burnin_base];[burnin_base][1:s]overlay,format=${_ov_fmt}[v]"
            _fc_emb="[0:v]${BURNIN_PRE_FILTER}[burnin_base];[burnin_base][0:s:${track}]overlay,format=${_ov_fmt}[v]"
        else
            _fc_ext="[0:v][1:s]overlay,format=${_ov_fmt}[v]"
            _fc_emb="[0:v][0:s:${track}]overlay,format=${_ov_fmt}[v]"
        fi
        # ok_now=0 fallback la fail; ramurile if/else previn abort set -e pe ffmpeg failure
        local ok_now=0
        case "$kind" in
            ext_pgs|ext_vob)
                echo "  Burn-in $kind (sursa: $aux) + re-encode ($ENC_NAME CRF $ENC_CRF preset $ENC_PRESET)..."
                # shellcheck disable=SC2086
                if ffmpeg -v error -stats \
                    "${seek_args[@]}" -i "$vid" \
                    -i "$aux" \
                    -filter_complex "$_fc_ext" \
                    -map "[v]" -map "0:a?" \
                    -c:v "$ENC_NAME" -crf "$ENC_CRF" -preset "$ENC_PRESET" \
                    "${BURNIN_ENC_EXTRA_ARGS[@]}" \
                    -c:a copy $_codec_tag -movflags +faststart "$out" -y </dev/null; then
                    ok_now=1
                fi
                ;;
            emb_pgs|emb_vob)
                echo "  Burn-in $kind (track s:$track embedded) + re-encode ($ENC_NAME CRF $ENC_CRF preset $ENC_PRESET)..."
                # shellcheck disable=SC2086
                if ffmpeg -v error -stats \
                    "${seek_args[@]}" -i "$vid" \
                    -filter_complex "$_fc_emb" \
                    -map "[v]" -map "0:a?" \
                    -c:v "$ENC_NAME" -crf "$ENC_CRF" -preset "$ENC_PRESET" \
                    "${BURNIN_ENC_EXTRA_ARGS[@]}" \
                    -c:a copy $_codec_tag -movflags +faststart "$out" -y </dev/null; then
                    ok_now=1
                fi
                ;;
            *)
                echo "  [EROARE] kind necunoscut: $kind"
                ;;
        esac
        if [ "$ok_now" -eq 1 ]; then
            echo "  [OK] $out"; ok=$((ok+1))
            # v90: re-graft grupul Eclipsa/IAMF pe output-ul complet (NU pe preview)
            if [[ "$out_suffix" != "preview" ]]; then
                _iamf_preserve "$vid" "$out" || true
            fi
        else
            echo "  [EROARE] ffmpeg image subs burn-in esuat"; rm -f "$out"; fail=$((fail+1))
        fi
        [[ -n "$BURNIN_HDR10PLUS_JSON" ]] && rm -f "$BURNIN_HDR10PLUS_JSON"
    done

    echo ""
    echo "═══════════════════════════════════════════════"
    echo "  Sumar Image subs burn-in: $ok OK, $fail esuate (din ${#SELECTED[@]} selectate)"
    echo "═══════════════════════════════════════════════"
}

# ──────────────────────────────────────────────────────────────────────
# FLOW 5 (v84): Designer vizual layout HUD — browser local
# Server Python stdlib (burnin_designer.py) + UI (burnin_designer.html);
# randare cu engine-ul REAL (burnin_render) → preview fidel cu encode-ul.
# Preseturile se salveaza in UserProfiles/burnin/ → apar la HUD opt "custom".
# ──────────────────────────────────────────────────────────────────────
designer_flow() {
    # Dependente: python3 + matplotlib (aceleasi ca fluxul HUD)
    if ! command -v python3 &>/dev/null; then
        echo "EROARE: python3 lipseste. Instaleaza cu: $(av_pkg_install_hint python)"
        exit 1
    fi
    if ! python3 -c "import matplotlib, numpy" 2>/dev/null; then
        echo "EROARE: matplotlib / numpy lipsesc (necesare pentru render HUD)."
        echo "Instaleaza cu: pip install matplotlib numpy pillow"
        echo "  Termux: pkg install python-numpy && pip install matplotlib pillow"
        exit 1
    fi
    [ -f "$DESIGNER_PY" ] || { echo "EROARE: $DESIGNER_PY lipseste."; exit 1; }

    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  DESIGNER VIZUAL LAYOUT HUD (browser)         ║"
    echo "╠══════════════════════════════════════════════╣"
    echo "║  1) Video + telemetrie reala (norm CSV)       ║"
    echo "║     [implicit]                                ║"
    echo "║  2) Doar video — date DEMO (doar layout)      ║"
    echo "║  3) Anulare                                   ║"
    echo "╚══════════════════════════════════════════════╝"
    read -p "Alege 1-3 [implicit: 1]: " ds_mode
    local vid="" csv="" ds_idx di i
    case "${ds_mode:-1}" in
        1)
            reset_pairs
            scan_for_pairs "$OUTPUT_DIR" "OUT" "_norm.csv" extract_brand_from_csv
            scan_for_pairs "$INPUT_DIR"  "IN"  "_norm.csv" extract_brand_from_csv
            if [ "${#PAIRS_VIDEO[@]}" -eq 0 ]; then
                echo ""
                echo "Nu am gasit nicio pereche video + norm CSV."
                echo "  (Genereaza CSV cu av_telemetry / av_extractor_gps, sau foloseste"
                echo "   optiunea 2 — date DEMO, doar pentru aranjarea layoutului.)"
                exit 0
            fi
            for i in "${!PAIRS_LABEL[@]}"; do
                printf "  %2d) %s\n" "$((i+1))" "${PAIRS_LABEL[$i]}"
            done
            echo ""
            read -p "Alege UN index [implicit 1]: " ds_idx
            ds_idx="${ds_idx:-1}"
            [[ "$ds_idx" =~ ^[0-9]+$ ]] || { echo "Index invalid."; exit 1; }
            di=$((ds_idx-1))
            [ "$di" -ge 0 ] && [ "$di" -lt "${#PAIRS_VIDEO[@]}" ] || { echo "Index in afara range."; exit 1; }
            vid="${PAIRS_VIDEO[$di]}"; csv="${PAIRS_AUX[$di]}"
            ;;
        2)
            local vids=() d f nm
            for d in "$OUTPUT_DIR" "$INPUT_DIR"; do
                [ -d "$d" ] || continue
                while IFS= read -r -d '' f; do
                    nm="$(basename "$f")"; nm="${nm%.*}"
                    [[ "$nm" == *_hud || "$nm" == *_telem || "$nm" == *_subs || "$nm" == *_preview ]] && continue
                    vids+=("$f")
                done < <(find "$d" -maxdepth 2 -type f \( -iname "*.mp4" -o -iname "*.mov" -o -iname "*.mkv" -o -iname "*.m4v" \) -print0 2>/dev/null)
            done
            [ "${#vids[@]}" -eq 0 ] && { echo "Niciun video gasit in $INPUT_DIR / $OUTPUT_DIR."; exit 0; }
            for i in "${!vids[@]}"; do
                printf "  %2d) %s\n" "$((i+1))" "$(basename "${vids[$i]}")"
            done
            echo ""
            read -p "Alege UN index [implicit 1]: " ds_idx
            ds_idx="${ds_idx:-1}"
            [[ "$ds_idx" =~ ^[0-9]+$ ]] || { echo "Index invalid."; exit 1; }
            di=$((ds_idx-1))
            [ "$di" -ge 0 ] && [ "$di" -lt "${#vids[@]}" ] || { echo "Index in afara range."; exit 1; }
            vid="${vids[$di]}"
            echo "  (fara CSV — designerul foloseste date DEMO sintetice)"
            ;;
        3) echo "Anulat."; exit 0 ;;
        *) echo "Optiune invalida."; exit 1 ;;
    esac

    local user_dir="$USER_PROFILES_DIR/burnin"
    mkdir -p "$user_dir" 2>/dev/null || true
    local csv_args=() open_args=()
    [ -n "$csv" ] && csv_args=(--csv "$csv")
    # Termux: webbrowser nu stie de browserul Android → termux-open-url
    [ "${AV_IS_TERMUX:-0}" = "1" ] && command -v termux-open-url &>/dev/null && open_args=(--open-cmd termux-open-url)

    echo ""
    echo "Pornesc designerul... (inchide-l din browser — Salveaza & Inchide — sau cu Ctrl+C aici)"
    local ds_rc=0
    python3 "$DESIGNER_PY" --video "$vid" "${csv_args[@]}" \
        --presets-dir "$PRESETS_DIR" --user-presets-dir "$user_dir" \
        --temp-dir "$AV_TEMP_DIR" "${open_args[@]}" || ds_rc=$?
    # 130 = Ctrl+C (oprire legitima a serverului) — nu e eroare
    if [ "$ds_rc" -ne 0 ] && [ "$ds_rc" -ne 130 ]; then
        echo "  [EROARE] designerul a iesit cu cod $ds_rc"
        exit 1
    fi
    echo ""
    echo "Preseturile salvate apar in fluxul HUD la optiunea 'custom' (LAYOUT PRESET → 4)."
}

# ──────────────────────────────────────────────────────────────────────
# Test mode: skip interactive menu (allow sourcing for tests)
# ──────────────────────────────────────────────────────────────────────
if [[ "${AV_BURNIN_TEST_MODE:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

# ──────────────────────────────────────────────────────────────────────
# Main menu — alege tip burn-in
# ──────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  BURN-IN — selecteaza tipul                   ║"
echo "╠══════════════════════════════════════════════╣"
echo "║  1) Telemetry HUD (gauges + map)              ║"
echo "║     Sursa: norm CSV                           ║"
echo "║  2) Subtitrari SRT (telemetry overlay/movies) ║"
echo "║  3) Subtitrari ASS (anime, styled subs)       ║"
echo "║  4) Image subs PGS/VobSub (Bluray/DVD)        ║"
echo "║  5) Designer vizual layout HUD (browser)      ║"
echo "║  6) Anulare                                   ║"
echo "╚══════════════════════════════════════════════╝"
read -p "Alege 1-6 [implicit: 1]: " burnin_type
case "${burnin_type:-1}" in
    1) hud_flow ;;
    2) srt_flow ;;
    3) ass_flow ;;
    4) img_flow ;;
    5) designer_flow ;;
    6) echo "Anulat."; exit 0 ;;
    *) echo "Optiune invalida."; exit 1 ;;
esac
