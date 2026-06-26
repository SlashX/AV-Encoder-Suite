#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# av_encoder_x265.sh — Encoder H.265/HEVC cu suport HDR, DV, DJI
# v26: Doar logica specifica — loop-ul e in av_common.sh
# ══════════════════════════════════════════════════════════════════════

ENCODER_TYPE="x265"

AUDIO_CODEC_ARG="${1:-aac:192k}"
CUSTOM_CRF="$2"; PRESET="${3:-slow}"; TUNE_OPT="$4"; EXTRA_X265="$5"
ENCODE_MODE="${6:-1}"; VBR_TARGET="$7"; VBR_MAXRATE="$8"; VBR_BUFSIZE="$9"
CONTAINER="${11:-mkv}"; SCALE_WIDTH="${12}"; TARGET_FPS="${13}"
FPS_METHOD="${14}"; VIDEO_FILTER_PRESET="${15}"; AUDIO_NORMALIZE="${16:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/av_common.sh"
THREADS=$(av_nproc)
LOG_FILE="$OUTPUT_DIR/av_encode_log_x265.txt"
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"
setup_trap

# ── Runtime check: libx265 disponibil? ────────────────────────────────
if ! ffmpeg -encoders 2>/dev/null | grep -q "libx265"; then
    echo "  EROARE: libx265 nu este disponibil in ffmpeg!"
    echo "  Necesita ffmpeg compilat cu --enable-libx265."
    exit 1
fi

# ── Functii specifice x265 ────────────────────────────────────────────
build_x265_params() {
    local base="$1" result
    [[ -n "$base" ]] && result="pools=$THREADS:$base:aq-mode=3:aq-strength=1.0" \
                      || result="pools=$THREADS:aq-mode=3:aq-strength=1.0"
    # v51: append auto params PRIMUL (level-idc/high-tier/hrd + HDR10 static)
    [[ -n "${X265_LEVEL_PARAMS:-}" ]] && result="$result:$X265_LEVEL_PARAMS"
    # v51: HDR10 static metadata (mastering display + max-cll) — setat doar pe
    # branch-uri HDR10 (HDR10/HDR10+/LOG→HDR10/HLG→HDR10/DV→HDR10)
    [[ -n "${X265_HDR10_STATIC_PARAMS:-}" ]] && result="$result:$X265_HDR10_STATIC_PARAMS"
    # EXTRA_X265 user — LAST (x265 ia ultima valoare la chei duplicate, user-ul poate
    # suprascrie auto-injected master-display / level-idc / hrd daca doreste)
    [[ -n "$EXTRA_X265" ]] && result="$result:$EXTRA_X265"
    echo "$result"
}

# v51: helper care construiește string-ul "master-display=...:max-cll=..."
# după ce hdr10_static_resolve a populat globalele
_set_x265_hdr10_static() {
    X265_HDR10_STATIC_PARAMS=""
    [ "${HDR10_STATIC_AVAILABLE:-0}" = "1" ] || return 1
    # v77: parantezele master-display escapate — string-ul intra in FFMPEG_CMD rulat prin `eval`
    X265_HDR10_STATIC_PARAMS="master-display=$(_esc_eval_parens "$HDR10_MASTER_DISPLAY_X265")"
    [[ -n "$HDR10_MAX_CLL" ]] && X265_HDR10_STATIC_PARAMS="${X265_HDR10_STATIC_PARAMS}:max-cll=${HDR10_MAX_CLL}"
    log "  HDR10 static: $HDR10_STATIC_SOURCE | max-cll=${HDR10_MAX_CLL:-default}"
    return 0
}

encoder_get_suffix() { echo "_x265"; }
encoder_get_label()  { echo "libx265"; }

encoder_log_header() {
    if [[ "$ENCODE_MODE" == "3" ]]; then
        log "Mod encodare   : VBR 2-pass | $VBR_TARGET / $VBR_MAXRATE / $VBR_BUFSIZE"
    elif [[ "$ENCODE_MODE" == "2" ]]; then
        log "Mod encodare   : VBR 1-pass | $VBR_TARGET / $VBR_MAXRATE"
    else
        log "Mod encodare   : CRF (4K=22, 1080p=21, 720p=20)"
        log "CRF custom     : ${CUSTOM_CRF:-auto}"
    fi
    log "Preset         : $PRESET | Tune: ${TUNE_OPT:-fara}"
    log "Parametri extra: ${EXTRA_X265:-fara}"
    log "pix_fmt        : yuv420p10le (10bit)"
}

encoder_setup_file() {
    local file="$1"

    # ── v42: HW backend dispatch (NVENC/VAAPI/QSV/VT/AMF) — SDR + HDR ──
    # MediaCodec foloseste branch-ul existent de mai jos (HDR dialog dedicat)
    hw_dispatch_sdr "$file" "hevc"; _hw_rc=$?
    [ $_hw_rc -eq 0 ]  && return 0
    [ $_hw_rc -eq 98 ] && return 98
    # rc=1 → continua spre SW path

    # ── v38: MediaCodec branch (Termux HW encoding) ───────────────────
    if [[ "${USE_MEDIACODEC:-0}" == "1" ]]; then
        # LOG sources nu sunt suportate pe MediaCodec (necesita LUT + tonemap dialog)
        if [[ -n "${LOG_PROFILE:-}" ]]; then
            log "  ⚠ Sursa LOG ($LOG_PROFILE) — MediaCodec nu suporta LUT/tonemap; fallback la SW libx265"
            # Cad prin la path-ul SW standard de mai jos (USE_MEDIACODEC ramane 1 pentru fisierele urmatoare)
        else
        local mc_source_type=""
        local mc_dv_profile=""
        if [[ -n "$DOVI" ]]; then
            mc_source_type="dv"
            mc_dv_profile="$(get_dv_profile "$file")"   # v62: eticheta prietenoasa (Profil 8.1/10.1...) nu marker brut
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
            show_hdr_mediacodec_dialog "$mc_source_type" "$mc_dv_profile" "hevc" "$_mc_src_codec"
            local mc_dlg_rc=$?
            [ $mc_dlg_rc -eq 98 ] && return 98
            case "$MC_HDR_MODE" in
                sw_full|sw_degraded)
                    log "  Fallback la SW libx265 ($MC_HDR_MODE) pentru fisierul curent"
                    # Resetam USE_MEDIACODEC pentru acest fisier — va merge prin path-ul SW de mai jos
                    # (HDR10+/DV degraded vor fi tratate ca HDR10 simplu cand intra in SW path)
                    if [[ "$MC_HDR_MODE" == "sw_degraded" ]]; then
                        # Strip enhancement: HDR10+ → HDR10 static, DV → HDR10 BL
                        HDR_PLUS=""
                        if [[ -n "$DOVI" ]]; then
                            DOVI=""
                            HDR_TYPE="smpte2084"
                        fi
                    fi
                    # Continua spre path-ul SW standard de mai jos
                    ;;
                hw_preserve)
                    # v46: MC encode HDR10 base + repair SEI + inject DV RPU post-encode
                    local _rpu_tmp
                    _rpu_tmp=$(av_mktemp_ext "rpu.bin")
                    if _extract_preserve_rpu "$file" "$_rpu_tmp" "$_mc_src_codec"; then
                        DOVI_RPU_FILE="$_rpu_tmp"
                        TRIPLE_LAYER_MODE=1
                        TRIPLE_LAYER_TARGET_CODEC="hevc"
                        MC_NEEDS_REPAIR=1
                        MC_REPAIR_SRC="$file"
                        MC_HDR_MODE="hw_repair"
                        log "  v46 MC DV preserve: RPU extras ($_mc_src_codec) -> MC encode -> repair -> inject (hevc)"
                    else
                        log "  v46 MC DV preserve: extract RPU esuat -> fallback hw_repair"
                        rm -f "$_rpu_tmp"
                        MC_HDR_MODE="hw_repair"
                    fi
                    if [[ "${DRY_RUN:-0}" == "1" ]]; then
                        dry_run_report "$file" "$output" "hevc_mediacodec (DV preserve)" \
                            "$WIDTH" "$DURATION" "$mc_source_type"
                        return 0
                    fi
                    build_mediacodec_cmd "$file" "hevc"
                    return 0
                    ;;
                hw_repair|hw_sdr|hw_hlg)
                    # Build MediaCodec FFMPEG_CMD si return
                    if [[ "${DRY_RUN:-0}" == "1" ]]; then
                        dry_run_report "$file" "$output" "hevc_mediacodec ($MC_HDR_MODE)" \
                            "$WIDTH" "$DURATION" "$mc_source_type"
                        return 0
                    fi
                    build_mediacodec_cmd "$file" "hevc"
                    return 0
                    ;;
            esac
        else
            # Sursa SDR — direct la MediaCodec fara dialog
            if [[ "${DRY_RUN:-0}" == "1" ]]; then
                dry_run_report "$file" "$output" "hevc_mediacodec (SDR)" \
                    "$WIDTH" "$DURATION" "SDR"
                return 0
            fi
            MC_HDR_MODE=""
            build_mediacodec_cmd "$file" "hevc"
            return 0
        fi
        fi  # end else LOG_PROFILE
    fi

    # ── Dolby Vision — HEVC dialog (v45: + opt 3 DV preserve) ─────────
    if [[ -n "$DOVI" ]]; then
        log "  Dolby Vision detectat (sursa Profile $DOVI)"
        local _dv_src_codec
        _dv_src_codec=$(detect_source_codec "$file")
        local _can_dv_preserve=0
        if _check_dovi_tool_for "$_dv_src_codec" && _check_dovi_tool_for "hevc"; then
            _can_dv_preserve=1
        fi
        echo ""
        echo "  ╔══════════════════════════════════════════════╗"
        echo "  ║  DOLBY VISION DETECTAT (sursa Profile $DOVI)"
        echo "  ╠══════════════════════════════════════════════╣"
        echo "  ║  1) Stream copy video + reencodeaza audio    ║"
        echo "  ║  2) Converteste la HDR10 (best-effort)       ║"
        if [ $_can_dv_preserve -eq 1 ]; then
            echo "  ║  3) DV preserve (HEVC 8.1) — re-encode+inject║"
            echo "  ║     extrage RPU sursa ($_dv_src_codec) → encode → inject"
        fi
        echo "  ║  4) Sari acest fisier                        ║"
        echo "  ╚══════════════════════════════════════════════╝"
        # v45: profile bypass — DOVI_PRESERVE_POLICY={auto|preserve|convert|copy|skip}
        local _dv_x265_choice=""
        case "${DOVI_PRESERVE_POLICY:-auto}" in
            preserve) _dv_x265_choice="3"; log "  DV policy=preserve (DOVI_PRESERVE_POLICY)" ;;
            convert)  _dv_x265_choice="2"; log "  DV policy=convert HDR10 (DOVI_PRESERVE_POLICY)" ;;
            copy)     _dv_x265_choice="1"; log "  DV policy=stream copy (DOVI_PRESERVE_POLICY)" ;;
            skip)     _dv_x265_choice="4"; log "  DV policy=skip (DOVI_PRESERVE_POLICY)" ;;
            *)        read -p "  Alege [implicit: 2]: " _dv_x265_choice ;;
        esac
        # preserve cere _can_dv_preserve; daca tool indisponibil, fallback la 2
        if [[ "$_dv_x265_choice" == "3" ]] && [ $_can_dv_preserve -eq 0 ]; then
            log "  DV preserve cerut prin policy dar tool indisponibil — fallback convert HDR10"
            _dv_x265_choice="2"
        fi
        case "${_dv_x265_choice:-2}" in
            1)
                # Stream copy + stats inline (paralel cu HDR10+ stream copy)
                log "  DV: stream copy"
                START_TIME=$(date +%s)
                local _dv_audio _dv_sub _dv_cflags _dv_pf _dv_pid
                _dv_audio=$(get_audio_params "$file"); _dv_sub=$(get_subtitle_codec "$file")
                _dv_cflags=$(get_container_flags); _dv_pf=$(mktemp); PROGRESS_FILE="$_dv_pf"
                # shellcheck disable=SC2086
                ffmpeg -threads "$THREADS" -i "$file" $MAP_FLAGS \
                    -c:v copy $_dv_audio $_dv_sub -c:t copy \
                    $_dv_cflags -progress "$_dv_pf" -nostats "$output" 2>>"$LOG_FILE" &
                _dv_pid=$!; _show_progress "$_dv_pid" "$_dv_pf" "$file" "DV stream copy"; wait "$_dv_pid"
                local _dv_rc=$?; PROGRESS_FILE=""
                if [ $_dv_rc -eq 0 ]; then
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
                return 98 ;;
            3)
                if [ $_can_dv_preserve -eq 1 ]; then
                    local _src_rpu
                    _src_rpu=$(av_mktemp_ext bin)
                    log "  DV preserve (HEVC): Extrag RPU din sursa ($_dv_src_codec)..."
                    if _extract_preserve_rpu "$file" "$_src_rpu" "$_dv_src_codec"; then
                        DOVI_RPU_FILE="$_src_rpu"
                        TRIPLE_LAYER_MODE=1
                        TRIPLE_LAYER_TARGET_CODEC="hevc"
                        log "  DV preserve (HEVC): RPU extras — re-encode + inject post-encode"
                    else
                        log "  DV preserve: Extract RPU esuat — fallback HDR10 (best-effort)"
                        rm -f "$_src_rpu"
                    fi
                else
                    log "  DV preserve: tool DV indisponibil — fallback HDR10 (best-effort)"
                fi
                ;;
            2)
                log "  DV: Conversie HDR10 (best-effort)"
                ;;
            4|*)
                log "  DV: sarit (user choice)"; return 98 ;;
        esac
    fi

    # ── Rate control ──────────────────────────────────────────────────
    local tune_flag="" crf_flag="" rate_flag=""
    local _is_2pass=0
    [[ -n "$TUNE_OPT" ]] && tune_flag="-tune $TUNE_OPT"
    if [[ "$ENCODE_MODE" == "3" && -n "$VBR_TARGET" ]]; then
        # v51: 2-pass VBR — rate_flag aplicat in ambele passuri;
        # stats path injectat via -x265-params (suplimentar la build_x265_params)
        rate_flag="-b:v $VBR_TARGET -maxrate $VBR_MAXRATE -bufsize $VBR_BUFSIZE"
        _is_2pass=1
        log "  2-PASS VBR: $VBR_TARGET / max $VBR_MAXRATE / buf $VBR_BUFSIZE"
    elif [[ "$ENCODE_MODE" == "2" && -n "$VBR_TARGET" ]]; then
        rate_flag="-b:v $VBR_TARGET -maxrate $VBR_MAXRATE -bufsize $VBR_BUFSIZE"
        log "  VBR: $VBR_TARGET / max $VBR_MAXRATE"
    else
        crf_flag="-crf $CRF"; log "  CRF: $CRF | ${WIDTH}px"
    fi

    # ── v51: Level / Tier / HRD compute (informational pe CRF, HRD-binding pe VBR/2-pass) ──
    local _target_kbps=0
    [[ "$ENCODE_MODE" == "2" || "$ENCODE_MODE" == "3" ]] && _target_kbps=$(parse_bitrate_kbps "$VBR_TARGET")
    local _vbv_suggest _lvl _tier
    _vbv_suggest=$(suggest_vbv_for_target hevc "$_target_kbps" "$WIDTH" "${HEIGHT:-1080}" "${SRC_FPS_DEC:-30}")
    _lvl=$(echo "$_vbv_suggest"  | awk '{print $1}')
    _tier=$(echo "$_vbv_suggest" | awk '{print $2}')
    local _lvl_idc="${_lvl//./}"   # 4.1 → 41
    local _high_tier_flag=0; [ "$_tier" = "high" ] && _high_tier_flag=1
    X265_LEVEL_PARAMS="level-idc=${_lvl_idc}:high-tier=${_high_tier_flag}"
    # HRD compliance doar pe VBR/2-pass (encoder respecta caps level)
    if [[ "$ENCODE_MODE" == "2" || "$ENCODE_MODE" == "3" ]]; then
        X265_LEVEL_PARAMS="${X265_LEVEL_PARAMS}:hrd=1"
        log "  HEVC level: $_lvl ${_tier^^} tier | HRD=on"
    else
        log "  HEVC level: $_lvl ${_tier^^} tier (informational)"
    fi

    # ── HDR params ────────────────────────────────────────────────────
    local x265params video_params hdr10plus_param=""
    # v51: reset HDR10 static per fisier (set doar pe branch-uri HDR10)
    X265_HDR10_STATIC_PARAMS=""
    if [[ "$HDR_PLUS" == *"HDR10+"* ]]; then
        log "  HDR10+ detectat"
        handle_hdr10plus_dialog "$file"
        local hdr10p_rc=$?
        if [ $hdr10p_rc -eq 98 ]; then
            # Stream copy — reutilizam handle_dv_with_stats pentru stats
            START_TIME=$(date +%s)
            local sc_audio sc_sub sc_cflags sc_pf sc_pid
            sc_audio=$(get_audio_params "$file"); sc_sub=$(get_subtitle_codec "$file")
            sc_cflags=$(get_container_flags); sc_pf=$(mktemp); PROGRESS_FILE="$sc_pf"
            # shellcheck disable=SC2086
            ffmpeg -threads "$THREADS" -i "$file" $MAP_FLAGS \
                -c:v copy $sc_audio $sc_sub -c:t copy \
                $sc_cflags -progress "$sc_pf" -nostats "$output" 2>>"$LOG_FILE" &
            sc_pid=$!; _show_progress "$sc_pid" "$sc_pf" "$file" "HDR10+ stream copy"; wait "$sc_pid"
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
        # hdr10p_rc=0: metadata extrasa in HDR10PLUS_JSON → injectam cu dhdr10-info
        if [[ -n "${HDR10PLUS_JSON:-}" ]]; then
            hdr10plus_param=":dhdr10-info=${HDR10PLUS_JSON}"
            log "  HDR10+: Metadata va fi injectata (dhdr10-info)"
        fi
        # hdr10p_rc=1: HDR10 static (fara dhdr10-info)
        hdr10_static_resolve "$file"; _set_x265_hdr10_static
        # v52: colorprim/transfer/colormatrix EXPLICIT in x265-params SI scoatem
        # ffmpeg -color_primaries/-color_trc/-colorspace pentru ca acelea scriu
        # Matroska container "Colour" element care override-uia VUI-ul stream
        # cand ffprobe citea (rezultat anterior: bt2020nc/unknown/unknown).
        # Fix: numai x265-params → stream + container preserve VUI corect.
        x265params=$(build_x265_params "hdr-opt=1:repeat-headers=1:hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc${hdr10plus_param}")
        video_params="-pix_fmt yuv420p10le -x265-params $x265params"
    elif [[ "${IS_HLG:-0}" == "1" ]]; then
        # ── HLG (BT.2100 HLG) ─────────────────────────────────────────
        handle_hlg_dialog "$file" "$filename" "x265"
        local hlg_rc=$?
        if [ $hlg_rc -eq 97 ]; then
            do_stream_copy "$file" "$output" "$MAP_FLAGS"; return 98
        elif [ $hlg_rc -eq 98 ]; then
            return 98
        fi
        case "$HLG_DIALOG_MODE" in
            hlg_native)
                # v52: doar x265-params, fara ffmpeg color flags
                x265params=$(build_x265_params "hdr-opt=1:repeat-headers=1:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc")
                video_params="-pix_fmt yuv420p10le -x265-params $x265params"
                ;;
            hlg_to_hdr10)
                # v51: HLG→HDR10 transform — sursa nu are master_display real,
                # folosim defaults BT.2020 + 1000 nits
                # v52: colorprim/transfer/colormatrix EXPLICIT in x265-params (fara ffmpeg flags)
                hdr10_static_defaults; HDR10_STATIC_SOURCE="default-hlg-to-hdr10"
                # v63: opt-in — masoara CLL real (HLG n-are light-level inscris → default 1000,400 e generic)
                if [ "${HDR10_MEASURE_CLL:-0}" = "1" ] && measure_hdr10_cll "$file"; then
                    HDR10_MAX_CLL="${HDR10_MEASURED_CLL},${HDR10_MEASURED_FALL}"; HDR10_STATIC_SOURCE="measured-hlg-to-hdr10"
                fi
                _set_x265_hdr10_static
                x265params=$(build_x265_params "hdr-opt=1:repeat-headers=1:hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc")
                video_params="-pix_fmt yuv420p10le -x265-params $x265params"
                local _hlg2hdr10_vf="zscale=t=linear:npl=1000,zscale=t=smpte2084:p=bt2020:m=bt2020nc:r=tv,format=yuv420p10le"
                if [[ -n "$VIDEO_FILTER" ]] && [[ "$VIDEO_FILTER" == *"-vf "* ]]; then
                    VIDEO_FILTER="${VIDEO_FILTER/-vf /-vf ${_hlg2hdr10_vf},}"
                else
                    VIDEO_FILTER="-vf $_hlg2hdr10_vf"
                fi
                ;;
            hlg_to_sdr)
                # v52: SDR Rec.709 VUI in x265-params, fara ffmpeg color flags
                x265params=$(build_x265_params "colorprim=bt709:transfer=bt709:colormatrix=bt709")
                video_params="-pix_fmt yuv420p10le -x265-params $x265params"
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
        handle_log_dialog "$file" "$filename" "x265"
        local log_rc=$?
        if [ $log_rc -eq 97 ]; then
            do_stream_copy "$file" "$output" "$MAP_FLAGS"; return 98
        elif [ $log_rc -eq 98 ]; then
            return 98
        fi
        # LOG dialog returned 0 — apply LOG settings
        _apply_log_filters
        if [[ -n "${LOG_EXTRA_X265:-}" ]]; then
            # HDR10 conversion from Log → injectează defaults (peak 1000 nits)
            hdr10_static_defaults; HDR10_STATIC_SOURCE="default-log-to-hdr10"; _set_x265_hdr10_static
            x265params=$(build_x265_params "$LOG_EXTRA_X265")
            video_params="-pix_fmt ${LOG_PIX_FMT:-yuv420p10le} -x265-params $x265params ${LOG_COLOR_FLAGS:-}"
        else
            x265params=$(build_x265_params "")
            video_params="-pix_fmt ${LOG_PIX_FMT:-yuv420p10le} -x265-params $x265params ${LOG_COLOR_FLAGS:-}"
        fi
    else
        # ── Dialog ANALIZA SURSA (HDR10 / SDR) ───────────────────────
        # Skip dialog daca DV re-encode (user a ales deja din DV dialog)
        if [[ -n "$DOVI" ]]; then
            log "  DV re-encode: HDR10 10-bit (best-effort)"
            # v51: DV→HDR10 — extrage din sursa daca disponibil, altfel defaults
            # v52: colorprim/transfer/colormatrix EXPLICIT in x265-params (fara ffmpeg flags)
            hdr10_static_resolve "$file"; _set_x265_hdr10_static
            x265params=$(build_x265_params "hdr-opt=1:repeat-headers=1:hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc")
            video_params="-pix_fmt yuv420p10le -x265-params $x265params"
        else
        handle_source_dialog "$file" "$filename" "x265"
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
                # v52: colorprim/transfer/colormatrix EXPLICIT in x265-params (fara ffmpeg flags)
                hdr10_static_resolve "$file"; _set_x265_hdr10_static
                x265params=$(build_x265_params "hdr-opt=1:repeat-headers=1:hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc")
                video_params="-pix_fmt yuv420p10le -x265-params $x265params"
                ;;
            hdr10_to_hlg)
                # v63: HDR10 → HLG (oglinda lui hlg_to_hdr10): PQ→linear→HLG. HLG e
                # metadata-free → fara hdr10=1 / master-display / max-cll. Validat empiric.
                x265params=$(build_x265_params "hdr-opt=1:repeat-headers=1:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc")
                video_params="-pix_fmt yuv420p10le -x265-params $x265params"
                local _hdr10toHlg_vf="zscale=t=linear:npl=1000,zscale=t=arib-std-b67:p=bt2020:m=bt2020nc:r=tv,format=yuv420p10le"
                if [[ -n "$VIDEO_FILTER" ]] && [[ "$VIDEO_FILTER" == *"-vf "* ]]; then
                    VIDEO_FILTER="${VIDEO_FILTER/-vf /-vf ${_hdr10toHlg_vf},}"
                else
                    VIDEO_FILTER="-vf $_hdr10toHlg_vf"
                fi
                ;;
            sdr_tonemap)
                # v52: VUI Rec.709 explicit in x265-params (fara ffmpeg flags)
                x265params=$(build_x265_params "colorprim=bt709:transfer=bt709:colormatrix=bt709")
                video_params="-pix_fmt yuv420p10le -x265-params $x265params"
                local _tonemap_vf="zscale=t=linear:npl=100,tonemap=hable:desat=0,zscale=t=bt709:p=bt709:m=bt709,format=yuv420p10le"
                if [[ -n "$VIDEO_FILTER" ]] && [[ "$VIDEO_FILTER" == *"-vf "* ]]; then
                    VIDEO_FILTER="${VIDEO_FILTER/-vf /-vf ${_tonemap_vf},}"
                else
                    VIDEO_FILTER="-vf $_tonemap_vf"
                fi
                ;;
            *)
                x265params=$(build_x265_params "")
                video_params="-pix_fmt yuv420p10le -x265-params $x265params"
                ;;
        esac
        fi  # end DOVI check
    fi
    log "  Container: $CONTAINER | Preset: $PRESET | Tune: ${TUNE_OPT:-fara}"

    # ── Dry-run ──────────────────────────────────────────────────────
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        local sf="SDR"
        [[ "$HDR_PLUS" == *"HDR10+"* ]] && sf="HDR10+"
        [[ "$HDR_TYPE" == *"smpte2084"* ]] && sf="HDR10"
        [[ "${IS_HLG:-0}" == "1" ]] && sf="HLG"
        [[ -n "$DOVI" ]] && sf="Dolby Vision"
        [[ -n "$LOG_PROFILE" ]] && sf="LOG ($LOG_PROFILE)"
        dry_run_report "$file" "$output" "libx265 / $PRESET" "$WIDTH" "$DURATION" "$sf"
        return 0
    fi

    # ── Comanda ffmpeg ────────────────────────────────────────────────
    if [ $_is_2pass -eq 1 ]; then
        # v51: 2-pass — STATS_FILE shared; pass=1 sample doar luma+geometrie (no audio, null output)
        init_2pass_state "$file"
        # Injecteaza pass=N + stats=path in x265-params (concateneaza la sfarsit)
        # video_params contine "-x265-params <params>" — sparge si re-asambleaza
        local _vp_pre _vp_params _vp_post
        # Extract x265-params value din video_params (intre "-x265-params " si urmatorul " -" sau end)
        if [[ "$video_params" =~ (.*)-x265-params\ ([^\ ]+)(.*) ]]; then
            _vp_pre="${BASH_REMATCH[1]}"
            _vp_params="${BASH_REMATCH[2]}"
            _vp_post="${BASH_REMATCH[3]}"
        else
            _vp_pre="$video_params"; _vp_params="pools=$THREADS"; _vp_post=""
        fi
        local _x265_pass1="${_vp_params}:pass=1:stats=${STATS_FILE}:slow-firstpass=0"
        local _x265_pass2="${_vp_params}:pass=2:stats=${STATS_FILE}"
        local _video_params_p1="${_vp_pre}-x265-params ${_x265_pass1}${_vp_post}"
        local _video_params_p2="${_vp_pre}-x265-params ${_x265_pass2}${_vp_post}"

        # Pass 1: self-contained, fara audio/subs/output (terminat in /dev/null)
        FFMPEG_CMD_PASS1="ffmpeg -y -threads $THREADS -i \"\$file\" $MAP_FLAGS \
            -c:v libx265 -preset $PRESET $tune_flag \
            $_video_params_p1 $VIDEO_FILTER $rate_flag -an -sn -f null /dev/null"
        # Pass 2: urmeaza pattern FFMPEG_CMD — run_2pass_encode adauga
        # LOUDNORM_FILTER + SUB_CODEC + CONTAINER_FLAGS + output
        FFMPEG_CMD_PASS2="ffmpeg -y -threads $THREADS -i \"\$file\" $MAP_FLAGS \
            -c:v libx265 -preset $PRESET $tune_flag \
            $_video_params_p2 $VIDEO_FILTER $rate_flag $AUDIO_PARAMS"
        FFMPEG_CMD=""
    else
        FFMPEG_CMD="ffmpeg -threads $THREADS -i \"\$file\" $MAP_FLAGS \
            -c:v libx265 -preset $PRESET $tune_flag $crf_flag \
            $video_params $VIDEO_FILTER $rate_flag $AUDIO_PARAMS"
    fi
    return 0
}

run_encode_loop
