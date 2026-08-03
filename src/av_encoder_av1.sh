#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# av_encoder_av1.sh — Encoder AV1 (libsvtav1 / libaom-av1)
# v26: Doar logica specifica — loop-ul e in av_common.sh
# ══════════════════════════════════════════════════════════════════════

ENCODER_TYPE="av1"

AUDIO_CODEC_ARG="${1:-aac:192k}"
CUSTOM_CRF="$2"; PRESET_CHOICE="$3"; TUNE_OPT="$4"; EXTRA_AV1="$5"
ENCODE_MODE="${6:-1}"; VBR_TARGET="$7"; VBR_MAXRATE="$8"; VBR_BUFSIZE="$9"
AV1_ENCODER="${10:-libsvtav1}"; CONTAINER="${11:-mkv}"; SCALE_WIDTH="${12}"
TARGET_FPS="${13}"; FPS_METHOD="${14}"; VIDEO_FILTER_PRESET="${15}"
AUDIO_NORMALIZE="${16:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/av_common.sh"
THREADS=$(av_nproc)
LOG_FILE="$OUTPUT_DIR/av_encode_log_av1.txt"
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"
setup_trap

# ── Runtime check: AV1 encoder disponibil? ────────────────────────────
if ! ffmpeg -encoders 2>/dev/null | grep -qE "libsvtav1|libaom-av1"; then
    echo "  EROARE: Niciun encoder AV1 nu este disponibil in ffmpeg!"
    echo "  Necesita ffmpeg compilat cu --enable-libsvtav1 sau --enable-libaom."
    exit 1
fi

# ── Preset mapping ────────────────────────────────────────────────────
get_encoder_preset() {
    local encoder="$1" choice="$2"
    if [[ "$encoder" == "libsvtav1" ]]; then
        case "$choice" in
            1) echo "0";; 2) echo "2";; 3) echo "4";; 4) echo "5";; 5) echo "6";;
            6) echo "7";; 7) echo "8";; 8) echo "10";; 9) echo "12";; *) echo "6";; esac
    else
        case "$choice" in
            1) echo "0";; 2) echo "1";; 3) echo "2";; 4) echo "3";; 5) echo "4";;
            6) echo "5";; 7) echo "6";; 8) echo "7";; 9) echo "8";; *) echo "4";; esac
    fi
}

build_av1_params() {
    local encoder="$1" preset="$2" film_grain="$3" width="$4" height="$5" is_vbr="${6:-0}"
    local tc tr
    if   [ "$width" -ge 3840 ]; then tc=2; tr=2
    elif [ "$width" -ge 1920 ]; then tc=1; tr=1
    else tc=1; tr=0; fi

    # v51: NU includem EXTRA_AV1 aici — se aplica LAST in encoder_setup_file,
    # dupa hdr10plus-json si mastering-display, ca user-ul sa poata suprascrie
    # cheile auto-injectate.
    if [[ "$encoder" == "libsvtav1" ]]; then
        local p="preset=$preset"; [ "$is_vbr" -eq 1 ] && p="$p:rc=1"
        p="$p:tile-columns=$tc:tile-rows=$tr:lp=$THREADS"
        [ "${film_grain:-0}" -gt 0 ] && p="$p:film-grain=$film_grain:film-grain-denoise=0"
        echo "-svtav1-params $p"
    else
        local f="-cpu-used $preset -tile-columns $tc -tile-rows $tr -row-mt 1 -threads $THREADS"
        [ "${film_grain:-0}" -gt 0 ] && f="$f -denoise-noise-level $film_grain"
        echo "$f"
    fi
}

ENCODER_PRESET=$(get_encoder_preset "$AV1_ENCODER" "$PRESET_CHOICE")

encoder_get_suffix() { echo "_av1"; }
encoder_get_label()  { echo "$AV1_ENCODER"; }

encoder_log_header() {
    if [[ "$ENCODE_MODE" == "3" ]]; then
        log "Mod encodare   : VBR 2-pass | $VBR_TARGET / $VBR_MAXRATE / $VBR_BUFSIZE"
    elif [[ "$ENCODE_MODE" == "2" ]]; then
        log "Mod encodare   : VBR 1-pass | $VBR_TARGET / $VBR_MAXRATE"
    else
        log "Mod encodare   : CRF AV1 (4K=30, 1080p=28, 720p=26)"
        log "CRF custom     : ${CUSTOM_CRF:-auto}"
    fi
    if [[ "$AV1_ENCODER" == "libsvtav1" ]]; then
        log "SVT-AV1 preset : $ENCODER_PRESET (meniu: ${PRESET_CHOICE:-5})"
    else
        log "libaom cpu-used: $ENCODER_PRESET (meniu: ${PRESET_CHOICE:-5})"
    fi
    log "Film-grain     : ${TUNE_OPT:-0}"
    log "Parametri extra: ${EXTRA_AV1:-fara}"
}

encoder_setup_file() {
    local file="$1"

    # ── v42: HW backend dispatch (NVENC/VAAPI/QSV/VT/AMF) — SDR + HDR ──
    hw_dispatch_sdr "$file" "av1"; _hw_rc=$?
    [ $_hw_rc -eq 0 ]  && return 0
    [ $_hw_rc -eq 98 ] && return 98

    # ── v38: MediaCodec branch (Termux HW AV1) ────────────────────────
    if [[ "${USE_MEDIACODEC:-0}" == "1" ]]; then
        # Pre-check: AV1 hw encode disponibil pe SoC? (capabilitate SoC, nu per-fisier)
        if [[ "${MC_CAP_AV1:-0}" != "1" ]] && [[ "${HW_FORCE:-0}" != "1" ]]; then
            log "  ⚠ SoC nu suporta AV1 HW encode — fallback la SW $AV1_ENCODER (toate fisierele; HW_FORCE=1 pt a forta av1_mediacodec)"
            USE_MEDIACODEC=0
        elif [[ -n "${LOG_PROFILE:-}" ]]; then
            log "  ⚠ Sursa LOG ($LOG_PROFILE) — MediaCodec nu suporta LUT/tonemap; fallback la SW $AV1_ENCODER"
        else
            local mc_source_type=""
            local mc_dv_profile=""
            if [[ -n "$DOVI" ]]; then
                mc_source_type="dv"; mc_dv_profile="$(get_dv_profile "$file")"   # v62: eticheta prietenoasa (Profil 10.1...)
            elif [[ "$HDR_PLUS" == *"HDR10+"* ]]; then
                mc_source_type="hdr10plus"
            elif [[ "${IS_HLG:-0}" == "1" ]]; then
                mc_source_type="hlg"
            elif [[ "$HDR_TYPE" == *"smpte2084"* ]]; then
                mc_source_type="hdr10"
            fi

            if [[ -n "$mc_source_type" ]]; then
                local _mc_src_codec
                _mc_src_codec=$(detect_source_codec "$file" 2>/dev/null); [[ -z "$_mc_src_codec" ]] && _mc_src_codec="hevc"
                show_hdr_mediacodec_dialog "$mc_source_type" "$mc_dv_profile" "av1" "$_mc_src_codec"
                local mc_dlg_rc=$?
                [ $mc_dlg_rc -eq 98 ] && return 98
                case "$MC_HDR_MODE" in
                    sw_full|sw_degraded)
                        log "  Fallback la SW $AV1_ENCODER ($MC_HDR_MODE) pentru fisierul curent"
                        if [[ "$MC_HDR_MODE" == "sw_degraded" ]]; then
                            HDR_PLUS=""
                            if [[ -n "$DOVI" ]]; then DOVI=""; HDR_TYPE="smpte2084"; fi
                        fi
                        # NU reseta USE_MEDIACODEC (decizie per-fisier);
                        # cad prin la path-ul SW de mai jos
                        ;;
                    hw_preserve)
                        # v46: MC AV1 encode + repair + inject DV RPU post-encode
                        local _rpu_tmp
                        _rpu_tmp=$(av_mktemp_ext "rpu.bin")
                        if _extract_preserve_rpu "$file" "$_rpu_tmp" "$_mc_src_codec"; then
                            DOVI_RPU_FILE="$_rpu_tmp"
                            TRIPLE_LAYER_MODE=1
                            TRIPLE_LAYER_TARGET_CODEC="av1"
                            MC_NEEDS_REPAIR=1
                            MC_REPAIR_SRC="$file"
                            MC_HDR_MODE="hw_repair"
                            log "  v46 MC DV preserve: RPU extras ($_mc_src_codec) -> MC AV1 encode -> repair -> inject (av1)"
                        else
                            log "  v46 MC DV preserve: extract RPU esuat -> fallback hw_repair"
                            rm -f "$_rpu_tmp"
                            MC_HDR_MODE="hw_repair"
                        fi
                        if [[ "${DRY_RUN:-0}" == "1" ]]; then
                            dry_run_report "$file" "$output" "av1_mediacodec (DV preserve)" \
                                "$WIDTH" "$DURATION" "$mc_source_type"; return 0
                        fi
                        build_mediacodec_cmd "$file" "av1"; return 0
                        ;;
                    hw_repair|hw_sdr|hw_hlg)
                        if [[ "${DRY_RUN:-0}" == "1" ]]; then
                            dry_run_report "$file" "$output" "av1_mediacodec ($MC_HDR_MODE)" \
                                "$WIDTH" "$DURATION" "$mc_source_type"; return 0
                        fi
                        build_mediacodec_cmd "$file" "av1"; return 0
                        ;;
                esac
            else
                if [[ "${DRY_RUN:-0}" == "1" ]]; then
                    dry_run_report "$file" "$output" "av1_mediacodec (SDR)" \
                        "$WIDTH" "$DURATION" "SDR"; return 0
                fi
                MC_HDR_MODE=""
                build_mediacodec_cmd "$file" "av1"
                return 0
            fi
        fi
    fi

    # ── Dolby Vision — AV1 Profile 10 via sven-pke fork (post-encode inject) ──
    if [[ -n "$DOVI" ]]; then
        echo ""
        echo "  ╔══════════════════════════════════════════════╗"
        echo "  ║  DOLBY VISION DETECTAT (sursa Profile $DOVI)"
        echo "  ╠══════════════════════════════════════════════╣"
        echo "  ║  1) Converteste la HDR10 (pierde layer DV)   ║"
        echo "  ║  2) Sari acest fisier                        ║"
        if _check_av1_dovi_tool && [[ "$AV1_ENCODER" == "libsvtav1" ]]; then
            echo "  ║  3) DV Profile 10 (AV1) — re-encode + inject ║"
            echo "  ║     extrage RPU sursa → encode AV1 → inject  ║"
            echo "  ║     necesita: $AV_TOOL_AV1DOVI (sven-pke fork)   ║"
        fi
        echo "  ╚══════════════════════════════════════════════╝"
        local _max_dv_opt=2
        _check_av1_dovi_tool && [[ "$AV1_ENCODER" == "libsvtav1" ]] && _max_dv_opt=3
        # v45: profile bypass — DOVI_PRESERVE_POLICY={auto|preserve|convert|copy|skip}
        # AV1 DV dialog mapping: 1=convert HDR10, 2=skip, 3=preserve P10
        # `copy` nu e suportat de AV1 → fallback convert + warning
        local dv_choice=""
        case "${DOVI_PRESERVE_POLICY:-auto}" in
            preserve) dv_choice="3"; log "  DV policy=preserve P10 (DOVI_PRESERVE_POLICY)" ;;
            convert)  dv_choice="1"; log "  DV policy=convert HDR10 (DOVI_PRESERVE_POLICY)" ;;
            copy)     log "  DV policy=copy nu e suportat pe AV1 — fallback convert"; dv_choice="1" ;;
            skip)     dv_choice="2"; log "  DV policy=skip (DOVI_PRESERVE_POLICY)" ;;
            *)        read -p "  Alege 1-$_max_dv_opt [implicit: 2]: " dv_choice ;;
        esac
        # preserve cere capability; daca lipseste, fallback convert
        if [[ "$dv_choice" == "3" ]] && { ! _check_av1_dovi_tool || [[ "$AV1_ENCODER" != "libsvtav1" ]]; }; then
            log "  DV preserve P10 cerut prin policy dar tool/encoder indisponibil — fallback convert HDR10"
            dv_choice="1"
        fi
        case "${dv_choice:-2}" in
            3)
                if _check_av1_dovi_tool && [[ "$AV1_ENCODER" == "libsvtav1" ]]; then
                    # Detect source codec + extrage RPU P7-aware (_extract_preserve_rpu:
                    # dovi_tool/av1dovi_tool codec-aware; P7 HEVC → convert 7→8.1)
                    local _src_codec
                    _src_codec=$(detect_source_codec "$file")
                    if ! _check_dovi_tool_for "$_src_codec"; then
                        log "  DV: tool DV pt sursa $_src_codec negasit — Fallback HDR10."
                    else
                        local _src_rpu
                        _src_rpu=$(av_mktemp_ext bin)
                        log "  DV (AV1 P10): Extrag RPU din sursa ($_src_codec)..."
                        if _extract_preserve_rpu "$file" "$_src_rpu" "$_src_codec"; then
                            DOVI_RPU_FILE="$_src_rpu"
                            TRIPLE_LAYER_MODE=1
                            TRIPLE_LAYER_TARGET_CODEC="av1"
                            log "  DV (AV1 P10): RPU sursa extras — re-encode + inject post-encode"
                        else
                            log "  DV (AV1 P10): Extract RPU esuat — fallback HDR10"
                            rm -f "$_src_rpu"
                        fi
                    fi
                fi
                ;;
            1)
                log "  DV: conversie la HDR10 (AV1)"
                ;;
            *)
                log "  DV: sarit (user choice)"; return 98
                ;;
        esac
    fi

    # ── Rate control ──────────────────────────────────────────────────
    # v94 (B12): libsvtav1 REFUZA plafonul de bitrate in VBR — "Svt[error]: Max Bitrate
    # only supported with CRF mode" → encoderul nici nu porneste (exit 127, 0 octeti).
    # Suita calculeaza mereu maxrate = target x 1.5, deci AV1 VBR (1-pass SI 2-pass) nu a
    # functionat niciodata pe SVT. `-maxrate`/`-bufsize` se trimit doar la libaom-av1,
    # care le suporta. Pe SVT ramane VBR pur (`-b:v`), fara plafon — nu exista alternativa:
    # max-bitrate-ul SVT (`mbr`) exista doar in modul CRF, care e alt mod de rate control.
    local crf_flag="" rate_flag="" is_vbr=0
    local _is_2pass=0
    local _av1_vbv="" _av1_vbv_note=" / max $VBR_MAXRATE"
    if [[ "$AV1_ENCODER" == "libsvtav1" ]]; then
        _av1_vbv_note=" (fara plafon — SVT-AV1 nu suporta maxrate in VBR)"
    else
        _av1_vbv=" -maxrate $VBR_MAXRATE -bufsize $VBR_BUFSIZE"
    fi
    if [[ "$ENCODE_MODE" == "3" && -n "$VBR_TARGET" ]]; then
        # v51: 2-pass VBR
        rate_flag="-b:v ${VBR_TARGET}${_av1_vbv}"
        is_vbr=1; _is_2pass=1
        log "  2-PASS VBR: ${VBR_TARGET}${_av1_vbv_note}"
    elif [[ "$ENCODE_MODE" == "2" && -n "$VBR_TARGET" ]]; then
        rate_flag="-b:v ${VBR_TARGET}${_av1_vbv}"
        is_vbr=1; log "  VBR: ${VBR_TARGET}${_av1_vbv_note}"
    else
        crf_flag="-crf $CRF"; log "  CRF: $CRF | ${WIDTH}x${HEIGHT}"
    fi

    # ── v51: Level (informational pe CRF; HRD-relevant pe VBR/2-pass) ──
    local _av1_target_kbps=0
    [ "$is_vbr" -eq 1 ] && _av1_target_kbps=$(parse_bitrate_kbps "$VBR_TARGET")
    local _av1_suggest _av1_lvl
    _av1_suggest=$(suggest_vbv_for_target av1 "$_av1_target_kbps" "$WIDTH" "${HEIGHT:-1080}" "${SRC_FPS_DEC:-30}")
    _av1_lvl=$(echo "$_av1_suggest" | awk '{print $1}')
    # libsvtav1 ffmpeg expune -level "4.0".."6.3"; libaom-av1 nu are level direct (gestionat intern)
    # v94 (B10a): la fel ca la x265 — level-ul se trimite encoderului DOAR pe VBR/2-pass.
    # Pe CRF ramane informational (svtav1 tolereaza un level subdimensionat, dar il scrie in
    # stream → semnalizare gresita catre playere). v94 (B10b): calculul insusi a fost corectat
    # — level-ul iese acum din samples + rata + latura maxima, nu din trepte de latime.
    local _av1_level_flag=""
    [[ "$AV1_ENCODER" == "libsvtav1" && "$is_vbr" -eq 1 ]] && _av1_level_flag="-level $_av1_lvl"
    log "  AV1 level: $_av1_lvl$([ "$is_vbr" -eq 1 ] || echo " (informational)")"

    local av1_params
    av1_params=$(build_av1_params "$AV1_ENCODER" "$ENCODER_PRESET" \
        "${TUNE_OPT:-0}" "$WIDTH" "$HEIGHT" "$is_vbr")

    # ── HDR color params ──────────────────────────────────────────────
    local color_params="" hdr10plus_av1_param="" hdr10_static_av1_param=""
    # v51: helper local — construieste fragmentul ":mastering-display=...:content-light=..."
    # pentru svtav1-params. Apel: _set_av1_hdr10_static (foloseste globalele HDR10_*)
    _set_av1_hdr10_static() {
        hdr10_static_av1_param=""
        [[ "$AV1_ENCODER" != "libsvtav1" ]] && return 1
        [ "${HDR10_STATIC_AVAILABLE:-0}" = "1" ] || return 1
        # v77: parantezele mastering-display escapate — av1_params intra in FFMPEG_CMD rulat prin `eval`
        hdr10_static_av1_param=":mastering-display=$(_esc_eval_parens "$HDR10_MASTER_DISPLAY_SVTAV1")"
        [[ -n "$HDR10_MAX_CLL" ]] && hdr10_static_av1_param="${hdr10_static_av1_param}:content-light=${HDR10_MAX_CLL}"
        log "  HDR10 static (AV1): $HDR10_STATIC_SOURCE | content-light=${HDR10_MAX_CLL:-default}"
        return 0
    }
    if [[ -n "$HDR_PLUS" ]]; then
        log "  HDR10+ detectat (target=$AV1_ENCODER)"
        # Caps check pentru hdr10plus-json inline (svtav1-params); afecteaza
        # doar injectarea metadatei dinamice la encode — dialog ruleaza intotdeauna
        # ca user-ul sa pastreze stream copy / skip / Triple-layer (DV RPU post-encode).
        local _hdr10p_inline_ok=1
        if [[ "$AV1_ENCODER" != "libsvtav1" ]]; then
            log "  ⚠ HDR10+: libaom-av1 nu suporta hdr10plus-json inline"
            _hdr10p_inline_ok=0
        elif ! _check_svtav1_hdr10plus_caps; then
            log "  ⚠ HDR10+: SVT-AV1 curent nu suporta hdr10plus-json (necesita v1.5+)"
            _hdr10p_inline_ok=0
        fi
        handle_hdr10plus_dialog "$file" "av1"
        local hdr10p_rc=$?
        if [ $hdr10p_rc -eq 98 ]; then
            # Stream copy
            START_TIME=$(date +%s)
            local sc_audio sc_sub sc_cflags sc_pf sc_pid
            sc_audio=$(get_audio_params "$file"); sc_sub=$(get_subtitle_codec "$file")
            sc_cflags=$(get_container_flags); sc_pf=$(mktemp); PROGRESS_FILE="$sc_pf"
            # shellcheck disable=SC2086
            ffmpeg -threads "$THREADS" -i "$file" $MAP_FLAGS \
                -c:v copy $sc_audio $sc_sub -c:t copy \
                $sc_cflags -progress "$sc_pf" -nostats "$output" 2>>"$LOG_FILE" &
            sc_pid=$!; _show_progress "$sc_pid" "$sc_pf" "$file" "Stream copy"; wait "$sc_pid"
            local sc_rc=$?; PROGRESS_FILE=""
            if [ $sc_rc -eq 0 ]; then
                NEW_SIZE=$(av_stat_size "$output" 2>/dev/null || echo 0)
                SAVED=$(( ORIGINAL_SIZE - NEW_SIZE )); [ $SAVED -lt 0 ] && SAVED=0
                TOTAL_SAVED=$(( TOTAL_SAVED+SAVED ))
                ENCODE_TIME=$(( $(date +%s) - START_TIME )); TOTAL_DONE=$((TOTAL_DONE+1))
                log "  Stream copy OK: $(( NEW_SIZE/1024/1024 )) MB | ${ENCODE_TIME}s"
                BATCH_NAMES+=("$filename"); BATCH_TIMES+=("$ENCODE_TIME")
                BATCH_ORIG+=("$ORIGINAL_SIZE"); BATCH_NEW+=("$NEW_SIZE")
                [ "$ORIGINAL_SIZE" -gt 0 ] && BATCH_RATIOS+=("$(awk "BEGIN{printf \"%.1f\", $NEW_SIZE * 100.0 / $ORIGINAL_SIZE}")") || BATCH_RATIOS+=("N/A")
                batch_mark_done "$filename"
            fi
            return 98
        fi
        # hdr10p_rc=0: metadata extrasa → injectam via svtav1-params doar daca caps OK
        if [[ -n "${HDR10PLUS_JSON:-}" ]] && [ "$_hdr10p_inline_ok" -eq 1 ]; then
            hdr10plus_av1_param=":hdr10plus-json=${HDR10PLUS_JSON}"
            # v94 (B14): vezi nota din av_encoder_x265.sh — eticheta triple-layer
            # revendica HDR10+ doar cand stratul chiar a intrat in encode.
            HDR10PLUS_INLINE_APPLIED=1
            log "  HDR10+: Metadata va fi injectata inline (hdr10plus-json)"
        elif [[ -n "${HDR10PLUS_JSON:-}" ]]; then
            log "  HDR10+: Metadata extrasa dar inline injection indisponibila — fallback HDR10 static"
            log "    (Triple-layer DV RPU post-encode ramane functional)"
        fi
        # v51: HDR10 static metadata (mastering display + content-light)
        hdr10_static_resolve "$file"; _set_av1_hdr10_static
        color_params="-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc"
    elif [[ "${IS_HLG:-0}" == "1" ]]; then
        # ── HLG (BT.2100 HLG) ─────────────────────────────────────────
        handle_hlg_dialog "$file" "$filename" "av1"
        local hlg_rc=$?
        if [ $hlg_rc -eq 97 ]; then
            do_stream_copy "$file" "$output" "$MAP_FLAGS"; return 98
        elif [ $hlg_rc -eq 98 ]; then
            return 98
        fi
        case "$HLG_DIALOG_MODE" in
            hlg_native)
                color_params="-color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc"
                ;;
            hlg_to_hdr10)
                # v51: HLG→HDR10 — defaults BT.2020 + 1000 nits
                hdr10_static_defaults; HDR10_STATIC_SOURCE="default-hlg-to-hdr10"
                # v63: opt-in — masoara CLL real (HLG n-are light-level inscris → default 1000,400 e generic)
                if [ "${HDR10_MEASURE_CLL:-0}" = "1" ] && measure_hdr10_cll "$file"; then
                    HDR10_MAX_CLL="${HDR10_MEASURED_CLL},${HDR10_MEASURED_FALL}"; HDR10_STATIC_SOURCE="measured-hlg-to-hdr10"
                fi
                _set_av1_hdr10_static
                color_params="-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc"
                local _hlg2hdr10_vf="zscale=t=linear:npl=1000,zscale=t=smpte2084:p=bt2020:m=bt2020nc:r=tv,format=yuv420p10le"
                if [[ -n "$VIDEO_FILTER" ]] && [[ "$VIDEO_FILTER" == *"-vf "* ]]; then
                    VIDEO_FILTER="${VIDEO_FILTER/-vf /-vf ${_hlg2hdr10_vf},}"
                else
                    VIDEO_FILTER="-vf $_hlg2hdr10_vf"
                fi
                ;;
            hlg_to_sdr)
                color_params="-color_primaries bt709 -color_trc bt709 -colorspace bt709"
                local _hlg2sdr_vf="zscale=t=linear:npl=100,tonemap=hable:desat=0,zscale=t=bt709:p=bt709:m=bt709:r=tv,format=yuv420p10le"
                if [[ -n "$VIDEO_FILTER" ]] && [[ "$VIDEO_FILTER" == *"-vf "* ]]; then
                    VIDEO_FILTER="${VIDEO_FILTER/-vf /-vf ${_hlg2sdr_vf},}"
                else
                    VIDEO_FILTER="-vf $_hlg2sdr_vf"
                fi
                ;;
        esac
    elif [[ -n "$LOG_PROFILE" ]]; then
        # ── LOG format video ─────────────────────────────────────────
        handle_log_dialog "$file" "$filename" "av1"
        local log_rc=$?
        if [ $log_rc -eq 97 ]; then
            do_stream_copy "$file" "$output" "$MAP_FLAGS"; return 98
        elif [ $log_rc -eq 98 ]; then
            return 98
        fi
        # LOG dialog returned 0 — apply filters
        _apply_log_filters
        color_params="${LOG_COLOR_FLAGS:-}"
    else
        # ── Dialog ANALIZA SURSA (HDR10 / SDR) ───────────────────────
        # Skip dialog daca DV re-encode (user a ales deja din DV dialog)
        if [[ -n "$DOVI" ]]; then
            log "  DV re-encode: HDR10 10-bit (AV1)"
            # v51: DV→HDR10 — extrage real daca exista, altfel defaults
            hdr10_static_resolve "$file"; _set_av1_hdr10_static
            color_params="-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc"
        else
        handle_source_dialog "$file" "$filename" "av1"
        local src_rc=$?
        if [ $src_rc -eq 97 ]; then
            do_stream_copy "$file" "$output" "$MAP_FLAGS"
            return 98
        elif [ $src_rc -eq 98 ]; then
            return 98
        fi
        # src_rc=0 — encode cu setarile alese
        case "${SRC_DIALOG_MODE:-sdr}" in
            hdr10)
                # v51: HDR10 source — extract real metadata (fallback defaults)
                hdr10_static_resolve "$file"; _set_av1_hdr10_static
                color_params="-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc"
                ;;
            hdr10_to_hlg)
                # v63: HDR10 → HLG. _av1_vui deriva transfer-characteristics=18 din
                # color_params (arib-std-b67); fallback HDR10-static (PQ) NU se declanseaza
                # (HLG e metadata-free).
                color_params="-color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc"
                local _h2h_vf="zscale=t=linear:npl=1000,zscale=t=arib-std-b67:p=bt2020:m=bt2020nc:r=tv,format=yuv420p10le"
                if [[ -n "$VIDEO_FILTER" ]] && [[ "$VIDEO_FILTER" == *"-vf "* ]]; then
                    VIDEO_FILTER="${VIDEO_FILTER/-vf /-vf ${_h2h_vf},}"
                else
                    VIDEO_FILTER="-vf $_h2h_vf"
                fi
                ;;
            sdr_tonemap)
                color_params="-color_primaries bt709 -color_trc bt709 -colorspace bt709"
                local _tonemap_vf="zscale=t=linear:npl=100,tonemap=hable:desat=0,zscale=t=bt709:p=bt709:m=bt709,format=yuv420p10le"
                if [[ -n "$VIDEO_FILTER" ]] && [[ "$VIDEO_FILTER" == *"-vf "* ]]; then
                    VIDEO_FILTER="${VIDEO_FILTER/-vf /-vf ${_tonemap_vf},}"
                else
                    VIDEO_FILTER="-vf $_tonemap_vf"
                fi
                ;;
            *)
                color_params=""
                ;;
        esac
        fi  # end DOVI check
    fi
    # v51: fallback HDR10 static — daca color_params indica PQ (smpte2084) si
    # niciun branch nu a setat hdr10_static_av1_param, aplica defaults (LOG→HDR10 etc)
    if [[ "$color_params" == *"smpte2084"* ]] && [[ -z "$hdr10_static_av1_param" ]]; then
        hdr10_static_defaults; HDR10_STATIC_SOURCE="default-fallback-pq"; _set_av1_hdr10_static
    fi
    log "  Encoder: $AV1_ENCODER | Preset: $ENCODER_PRESET | Film-grain: ${TUNE_OPT:-0}"

    # ── Dry-run ──────────────────────────────────────────────────────
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        local sf="SDR"
        [[ -n "$HDR_PLUS" ]] && sf="HDR10+"
        [[ "$HDR_TYPE" == "smpte2084" ]] && sf="HDR10"
        [[ "${IS_HLG:-0}" == "1" ]] && sf="HLG"
        [[ -n "$DOVI" ]] && sf="DV"
        [[ -n "$LOG_PROFILE" ]] && sf="LOG ($LOG_PROFILE)"
        dry_run_report "$file" "$output" "$AV1_ENCODER / preset $ENCODER_PRESET" "$WIDTH" "$DURATION" "$sf"
        return 0
    fi

    # ── Comanda ffmpeg ────────────────────────────────────────────────
    # v52: VUI color signaling EXPLICIT in svtav1-params — ffmpeg -color_primaries
    # / -color_trc nu propaga la libsvtav1 (rezultat: stream bt2020nc/unknown/unknown).
    # Valori numerice AV1 spec: BT.2020=9, BT.709=1, PQ=16, HLG=18, BT.2020NC=9.
    # Derive din $color_params (set per branch HDR10/HDR10+/HLG/HLG→HDR10/HLG→SDR/SDR_tonemap).
    local _av1_vui=""
    if [[ "$color_params" == *"smpte2084"* ]]; then
        _av1_vui="color-primaries=9:transfer-characteristics=16:matrix-coefficients=9"
    elif [[ "$color_params" == *"arib-std-b67"* ]]; then
        _av1_vui="color-primaries=9:transfer-characteristics=18:matrix-coefficients=9"
    elif [[ "$color_params" == *"bt709"* ]]; then
        _av1_vui="color-primaries=1:transfer-characteristics=1:matrix-coefficients=1"
    fi
    if [[ -n "$_av1_vui" ]] && [[ "$AV1_ENCODER" == "libsvtav1" ]]; then
        av1_params="${av1_params}:${_av1_vui}"
    fi
    # Daca avem HDR10+ JSON, il adaugam la svtav1-params
    if [[ -n "$hdr10plus_av1_param" ]] && [[ "$AV1_ENCODER" == "libsvtav1" ]]; then
        av1_params="${av1_params}${hdr10plus_av1_param}"
    fi
    # v51: HDR10 static (mastering-display + content-light) — doar libsvtav1
    if [[ -n "$hdr10_static_av1_param" ]] && [[ "$AV1_ENCODER" == "libsvtav1" ]]; then
        av1_params="${av1_params}${hdr10_static_av1_param}"
    fi
    # libaom-av1: nu expune mastering-display direct prin ffmpeg → log warning
    if [[ "$AV1_ENCODER" == "libaom-av1" ]] && [[ "$color_params" == *"smpte2084"* ]]; then
        log "  ⚠ libaom-av1: mastering display + content-light nu pot fi injectate prin ffmpeg"
        log "    (HDR10 signaling color via -color_* ramane functional)"
    fi
    # v51: EXTRA_AV1 user — LAST (suprascrie auto-injected hdr10plus-json /
    # mastering-display / content-light la nivel svtav1-params; libaom-av1 il
    # primeste ca tokens separate prin string split)
    if [[ -n "$EXTRA_AV1" ]]; then
        if [[ "$AV1_ENCODER" == "libsvtav1" ]]; then
            av1_params="${av1_params}:${EXTRA_AV1}"
        else
            av1_params="${av1_params} ${EXTRA_AV1}"
        fi
    fi
    local av1_pixfmt="${LOG_PIX_FMT:-yuv420p10le}"

    if [ $_is_2pass -eq 1 ]; then
        # v51: 2-pass AV1
        init_2pass_state "$file"
        if [[ "$AV1_ENCODER" == "libsvtav1" ]]; then
            # SVT-AV1: detect inline pass=N:stats= caps (v1.4+); fallback la -pass/-passlogfile
            _check_svtav1_2pass_caps
            local _svt_p1_params _svt_p2_params
            local _pass_flag_p1="" _pass_flag_p2=""
            if [[ "${SVTAV1_2PASS_SUPPORTED:-0}" == "1" ]]; then
                # Inline syntax — adauga la av1_params (extrage continutul curent dupa -svtav1-params)
                local _svt_inner="${av1_params#-svtav1-params }"
                _svt_p1_params="-svtav1-params ${_svt_inner}:pass=1:stats=${STATS_FILE}"
                _svt_p2_params="-svtav1-params ${_svt_inner}:pass=2:stats=${STATS_FILE}"
            else
                # Sintaxa inline `pass=N:stats=PATH` (libsvtav1 v1.4+) nu a fost
                # detectata in help-ul ffmpeg — folosim sintaxa generica
                # ffmpeg `-pass N -passlogfile PATH` care e tradusa intern de
                # ffmpeg catre svtav1-params pe versiuni compatibile.
                log "  ℹ SVT-AV1 2-pass: folosesc sintaxa generica -pass/-passlogfile"
                _svt_p1_params="$av1_params"
                _svt_p2_params="$av1_params"
                _pass_flag_p1="-pass 1 -passlogfile \"$STATS_FILE\""
                _pass_flag_p2="-pass 2 -passlogfile \"$STATS_FILE\""
            fi
            # v52: NU adaugam $color_params la libsvtav1 (VUI deja in svtav1-params;
            # ffmpeg -color_primaries scrie Matroska "Colour" element care override
            # VUI stream pe MKV → rezultat anterior bt2020nc/unknown/unknown).
            FFMPEG_CMD_PASS1="ffmpeg -y -threads $THREADS -i \"\$file\" $MAP_FLAGS \
                -c:v libsvtav1 $_av1_level_flag -pix_fmt $av1_pixfmt \
                $_svt_p1_params $VIDEO_FILTER $rate_flag $_pass_flag_p1 \
                -an -sn -f null /dev/null"
            FFMPEG_CMD_PASS2="ffmpeg -y -threads $THREADS -i \"\$file\" $MAP_FLAGS \
                -c:v libsvtav1 $_av1_level_flag -pix_fmt $av1_pixfmt \
                $_svt_p2_params $VIDEO_FILTER $rate_flag $_pass_flag_p2 $AUDIO_PARAMS"
        else
            # libaom-av1: --fpf=PATH pentru first pass file (sau -passlogfile generic via ffmpeg)
            # v52: pastram $color_params la libaom (fara alt mecanism VUI inject prin ffmpeg)
            FFMPEG_CMD_PASS1="ffmpeg -y -threads $THREADS -i \"\$file\" $MAP_FLAGS \
                -c:v libaom-av1 -pix_fmt $av1_pixfmt \
                $av1_params $VIDEO_FILTER $color_params $rate_flag \
                -pass 1 -passlogfile \"$STATS_FILE\" -an -sn -f null /dev/null"
            FFMPEG_CMD_PASS2="ffmpeg -y -threads $THREADS -i \"\$file\" $MAP_FLAGS \
                -c:v libaom-av1 -pix_fmt $av1_pixfmt \
                $av1_params $VIDEO_FILTER $color_params $rate_flag \
                -pass 2 -passlogfile \"$STATS_FILE\" $AUDIO_PARAMS"
        fi
        FFMPEG_CMD=""
    else
        if [[ "$AV1_ENCODER" == "libsvtav1" ]]; then
            # v52: NU adaugam $color_params (vezi nota la 2-pass branch)
            FFMPEG_CMD="ffmpeg -threads $THREADS -i \"\$file\" $MAP_FLAGS \
                -c:v libsvtav1 $_av1_level_flag $crf_flag -pix_fmt $av1_pixfmt \
                $av1_params $VIDEO_FILTER $rate_flag $AUDIO_PARAMS"
        else
            local libaom_bv=""
            [ "$is_vbr" -eq 0 ] && libaom_bv="-b:v 0"
            FFMPEG_CMD="ffmpeg -threads $THREADS -i \"\$file\" $MAP_FLAGS \
                -c:v libaom-av1 $crf_flag -pix_fmt $av1_pixfmt $libaom_bv \
                $av1_params $VIDEO_FILTER $color_params $rate_flag $AUDIO_PARAMS"
        fi
    fi
    return 0
}

run_encode_loop
