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

    if [[ "$encoder" == "libsvtav1" ]]; then
        local p="preset=$preset"; [ "$is_vbr" -eq 1 ] && p="$p:rc=1"
        p="$p:tile-columns=$tc:tile-rows=$tr:lp=$THREADS"
        [ "${film_grain:-0}" -gt 0 ] && p="$p:film-grain=$film_grain:film-grain-denoise=0"
        [[ -n "$EXTRA_AV1" ]] && p="$p:$EXTRA_AV1"
        echo "-svtav1-params $p"
    else
        local f="-cpu-used $preset -tile-columns $tc -tile-rows $tr -row-mt 1 -threads $THREADS"
        [ "${film_grain:-0}" -gt 0 ] && f="$f -denoise-noise-level $film_grain"
        [[ -n "$EXTRA_AV1" ]] && f="$f $EXTRA_AV1"
        echo "$f"
    fi
}

ENCODER_PRESET=$(get_encoder_preset "$AV1_ENCODER" "$PRESET_CHOICE")

encoder_get_suffix() { echo "_av1"; }
encoder_get_label()  { echo "$AV1_ENCODER"; }

encoder_log_header() {
    if [[ "$ENCODE_MODE" == "2" ]]; then
        log "Mod encodare   : VBR | $VBR_TARGET / $VBR_MAXRATE"
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

    # ── v38: MediaCodec branch (Termux HW AV1) ────────────────────────
    if [[ "${USE_MEDIACODEC:-0}" == "1" ]]; then
        # Pre-check: AV1 hw encode disponibil pe SoC? (capabilitate SoC, nu per-fisier)
        if [[ "${MC_CAP_AV1:-0}" != "1" ]]; then
            log "  ⚠ SoC nu suporta AV1 HW encode — fallback la SW $AV1_ENCODER (toate fisierele)"
            USE_MEDIACODEC=0
        elif [[ -n "${LOG_PROFILE:-}" ]]; then
            log "  ⚠ Sursa LOG ($LOG_PROFILE) — MediaCodec nu suporta LUT/tonemap; fallback la SW $AV1_ENCODER"
        else
            local mc_source_type=""
            local mc_dv_profile=""
            if [[ -n "$DOVI" ]]; then
                mc_source_type="dv"; mc_dv_profile="$DOVI"
            elif [[ "$HDR_PLUS" == *"HDR10+"* ]]; then
                mc_source_type="hdr10plus"
            elif [[ "${IS_HLG:-0}" == "1" ]]; then
                mc_source_type="hlg"
            elif [[ "$HDR_TYPE" == *"smpte2084"* ]]; then
                mc_source_type="hdr10"
            fi

            if [[ -n "$mc_source_type" ]]; then
                show_hdr_mediacodec_dialog "$mc_source_type" "$mc_dv_profile"
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

    # ── Dolby Vision — AV1 nu suporta DV nativ ───────────────────────
    if [[ -n "$DOVI" ]]; then
        echo ""
        echo "  ╔══════════════════════════════════════════════╗"
        echo "  ║  DOLBY VISION DETECTAT                       ║"
        echo "  ║  AV1 nu suporta Dolby Vision nativ.          ║"
        echo "  ╠══════════════════════════════════════════════╣"
        echo "  ║  1) Converteste la HDR10 (pierde layer DV)   ║"
        echo "  ║  2) Sari acest fisier                        ║"
        echo "  ╚══════════════════════════════════════════════╝"
        read -p "  Alege 1 sau 2 [implicit: 2]: " dv_choice
        if [[ "${dv_choice:-2}" != "1" ]]; then
            log "  DV: sarit (AV1 incompatibil)"; return 98
        fi
        log "  DV: conversie la HDR10 (AV1)"
    fi

    # ── Rate control ──────────────────────────────────────────────────
    local crf_flag="" rate_flag="" is_vbr=0
    if [[ "$ENCODE_MODE" == "2" && -n "$VBR_TARGET" ]]; then
        rate_flag="-b:v $VBR_TARGET -maxrate $VBR_MAXRATE -bufsize $VBR_BUFSIZE"
        is_vbr=1; log "  VBR: $VBR_TARGET / max $VBR_MAXRATE"
    else
        crf_flag="-crf $CRF"; log "  CRF: $CRF | ${WIDTH}x${HEIGHT}"
    fi

    local av1_params
    av1_params=$(build_av1_params "$AV1_ENCODER" "$ENCODER_PRESET" \
        "${TUNE_OPT:-0}" "$WIDTH" "$HEIGHT" "$is_vbr")

    # ── HDR color params ──────────────────────────────────────────────
    local color_params="" hdr10plus_av1_param=""
    if [[ -n "$HDR_PLUS" ]]; then
        log "  HDR10+ detectat"
        handle_hdr10plus_dialog "$file"
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
        # hdr10p_rc=0: metadata extrasa → injectam via svtav1-params
        if [[ -n "${HDR10PLUS_JSON:-}" ]] && [[ "$AV1_ENCODER" == "libsvtav1" ]]; then
            hdr10plus_av1_param=":hdr10plus-json=${HDR10PLUS_JSON}"
            log "  HDR10+: Metadata va fi injectata (hdr10plus-json)"
        elif [[ -n "${HDR10PLUS_JSON:-}" ]]; then
            log "  HDR10+: libaom nu suporta hdr10plus-json — metadata pierduta"
        fi
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
                color_params="-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc"
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
    # Daca avem HDR10+ JSON, il adaugam la svtav1-params
    if [[ -n "$hdr10plus_av1_param" ]] && [[ "$AV1_ENCODER" == "libsvtav1" ]]; then
        av1_params="${av1_params}${hdr10plus_av1_param}"
    fi
    local av1_pixfmt="${LOG_PIX_FMT:-yuv420p10le}"
    if [[ "$AV1_ENCODER" == "libsvtav1" ]]; then
        FFMPEG_CMD="ffmpeg -threads $THREADS -i \"\$file\" $MAP_FLAGS \
            -c:v libsvtav1 $crf_flag -pix_fmt $av1_pixfmt \
            $av1_params $VIDEO_FILTER $color_params $rate_flag $AUDIO_PARAMS"
    else
        local libaom_bv=""
        [ "$is_vbr" -eq 0 ] && libaom_bv="-b:v 0"
        FFMPEG_CMD="ffmpeg -threads $THREADS -i \"\$file\" $MAP_FLAGS \
            -c:v libaom-av1 $crf_flag -pix_fmt $av1_pixfmt $libaom_bv \
            $av1_params $VIDEO_FILTER $color_params $rate_flag $AUDIO_PARAMS"
    fi
    return 0
}

run_encode_loop
