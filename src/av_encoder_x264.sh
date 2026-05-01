#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# av_encoder_x264.sh — Encoder H.264/AVC cu suport HDR detect, DV, DJI
# v26: Doar logica specifica — loop-ul e in av_common.sh
# ══════════════════════════════════════════════════════════════════════

ENCODER_TYPE="x264"

AUDIO_CODEC_ARG="${1:-aac:192k}"
CUSTOM_CRF="$2"; PRESET="${3:-slow}"; TUNE_OPT="$4"; EXTRA_X264="$5"
ENCODE_MODE="${6:-1}"; VBR_TARGET="$7"; VBR_MAXRATE="$8"; VBR_BUFSIZE="$9"
X264_PROFILE="${10}"; CONTAINER="${11:-mkv}"; SCALE_WIDTH="${12}"
TARGET_FPS="${13}"; FPS_METHOD="${14}"; VIDEO_FILTER_PRESET="${15}"
AUDIO_NORMALIZE="${16:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/av_common.sh"
THREADS=$(av_nproc)
LOG_FILE="$OUTPUT_DIR/av_encode_log_x264.txt"
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"
setup_trap

# ── Runtime check: libx264 disponibil? ────────────────────────────────
if ! ffmpeg -encoders 2>/dev/null | grep -q "libx264"; then
    echo "  EROARE: libx264 nu este disponibil in ffmpeg!"
    echo "  Necesita ffmpeg compilat cu --enable-libx264."
    exit 1
fi

encoder_get_suffix() { echo "_x264"; }
encoder_get_label()  { echo "libx264"; }

encoder_log_header() {
    if [[ "$ENCODE_MODE" == "2" ]]; then
        log "Mod encodare   : VBR | $VBR_TARGET / $VBR_MAXRATE"
    else
        log "Mod encodare   : CRF (4K=20, 1080p=19, 720p=18)"
        log "CRF custom     : ${CUSTOM_CRF:-auto}"
    fi
    log "Preset         : $PRESET | Tune: ${TUNE_OPT:-fara}"
    log "Profil global  : ${X264_PROFILE:-auto}"
    log "Parametri extra: ${EXTRA_X264:-fara}"
}

encoder_setup_file() {
    local file="$1"

    # ── v42: HW backend dispatch (NVENC/VAAPI/QSV/VT/AMF) — SDR + HDR ──
    hw_dispatch_sdr "$file" "h264"; _hw_rc=$?
    [ $_hw_rc -eq 0 ]  && return 0
    [ $_hw_rc -eq 98 ] && return 98

    # ── v38: MediaCodec branch (Termux HW H.264) ──────────────────────
    if [[ "${USE_MEDIACODEC:-0}" == "1" ]]; then
        if [[ -n "${LOG_PROFILE:-}" ]]; then
            log "  ⚠ Sursa LOG ($LOG_PROFILE) — MediaCodec nu suporta LUT/tonemap; fallback la SW libx264"
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

        # x264 nu suporta HDR — daca user a ales MediaCodec pe HDR,
        # h264_mediacodec accepta doar SDR. Forteaza tonemap sau fallback SW.
        if [[ -n "$mc_source_type" ]]; then
            log "  ⚠ h264_mediacodec nu suporta HDR — sursa $mc_source_type"
            show_hdr_mediacodec_dialog "$mc_source_type" "$mc_dv_profile"
            local mc_dlg_rc=$?
            [ $mc_dlg_rc -eq 98 ] && return 98
            case "$MC_HDR_MODE" in
                sw_full|sw_degraded)
                    log "  Fallback la SW libx264 (HDR strip — x264 nu poate HDR)"
                    HDR_PLUS=""; DOVI=""; HDR_TYPE=""; IS_HLG=0
                    ;;
                hw_repair|hw_hlg)
                    log "  ⚠ MediaCodec H.264 nu poate HDR/HLG — comut pe SDR tonemap"
                    MC_HDR_MODE="hw_sdr"
                    if [[ "${DRY_RUN:-0}" == "1" ]]; then
                        dry_run_report "$file" "$output" "h264_mediacodec (SDR tonemap)" \
                            "$WIDTH" "$DURATION" "$mc_source_type"; return 0
                    fi
                    build_mediacodec_cmd "$file" "h264"; return 0
                    ;;
                hw_sdr)
                    if [[ "${DRY_RUN:-0}" == "1" ]]; then
                        dry_run_report "$file" "$output" "h264_mediacodec (SDR tonemap)" \
                            "$WIDTH" "$DURATION" "$mc_source_type"; return 0
                    fi
                    build_mediacodec_cmd "$file" "h264"; return 0
                    ;;
            esac
        else
            # Sursa SDR — direct la MediaCodec
            if [[ "${DRY_RUN:-0}" == "1" ]]; then
                dry_run_report "$file" "$output" "h264_mediacodec (SDR)" \
                    "$WIDTH" "$DURATION" "SDR"
                return 0
            fi
            MC_HDR_MODE=""
            build_mediacodec_cmd "$file" "h264"
            return 0
        fi
        fi  # end else LOG_PROFILE
    fi

    # ── Diagnostic sursa ─────────────────────────────────────────────
    local src_is_hdr=0 src_is_hdrplus=0 src_is_dv=0 src_bitdepth="8-bit"
    local src_pixfmt
    src_pixfmt=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=pix_fmt -of csv=p=0 "$file" 2>/dev/null)
    [[ "$src_pixfmt" == *"10"* ]] && src_bitdepth="10-bit"
    [[ "$HDR_TYPE" == "smpte2084" ]] && src_is_hdr=1
    [[ "$HDR_PLUS" == *"HDR10+"* ]] && { src_is_hdr=1; src_is_hdrplus=1; }
    [[ -n "$DOVI" ]] && { src_is_hdr=1; src_is_dv=1; }

    local src_label="SDR $src_bitdepth"
    [ "$src_is_hdrplus" -eq 1 ] && src_label="HDR10+ $src_bitdepth"
    [ "$src_is_dv" -eq 1 ] && src_label="Dolby Vision $src_bitdepth"
    [ "$src_is_hdr" -eq 1 ] && [ "$src_is_hdrplus" -eq 0 ] && [ "$src_is_dv" -eq 0 ] && src_label="HDR10 $src_bitdepth"

    local local_profile x264_pixfmt
    local x264_hlg_color_flags=""

    # ── HLG (BT.2100 HLG) — dialog dedicat ────────────────────────────
    if [[ "${IS_HLG:-0}" == "1" ]]; then
        src_label="HLG $src_bitdepth"
        handle_hlg_dialog "$file" "$filename" "x264"
        local hlg_rc=$?
        if [ $hlg_rc -eq 97 ]; then
            do_stream_copy "$file" "$output" "$MAP_FLAGS"; return 98
        elif [ $hlg_rc -eq 98 ]; then
            return 98
        fi
        # x264 nu poate produce HDR10 PQ — treat hlg_to_hdr10 ca hlg_native cu warning
        if [[ "$HLG_DIALOG_MODE" == "hlg_to_hdr10" ]]; then
            log "  ⚠ x264 nu suporta SEI HDR10 — pastrez HLG nativ"
            HLG_DIALOG_MODE="hlg_native"
        fi
        case "$HLG_DIALOG_MODE" in
            hlg_native)
                local_profile="high10"; x264_pixfmt="yuv420p10le"
                x264_hlg_color_flags="-color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc"
                log "  Ales: HLG nativ (high10 + HLG signaling)"
                ;;
            hlg_to_sdr)
                local_profile="high"; x264_pixfmt="yuv420p"
                x264_hlg_color_flags="-color_primaries bt709 -color_trc bt709 -colorspace bt709"
                local _hlg2sdr_vf="zscale=t=linear:npl=100,tonemap=hable:desat=0,zscale=t=bt709:p=bt709:m=bt709:r=tv,format=yuv420p"
                if [[ -n "$VIDEO_FILTER" ]] && [[ "$VIDEO_FILTER" == *"-vf "* ]]; then
                    VIDEO_FILTER="${VIDEO_FILTER/-vf /-vf ${_hlg2sdr_vf},}"
                else
                    VIDEO_FILTER="-vf $_hlg2sdr_vf"
                fi
                log "  Ales: HLG → SDR (Rec.709) tonemap"
                ;;
        esac
    elif [[ -n "$LOG_PROFILE" ]]; then
        src_label="LOG $src_bitdepth ($(_log_profile_label "$LOG_PROFILE"))"
        handle_log_dialog "$file" "$filename" "x264"
        local log_rc=$?
        if [ $log_rc -eq 97 ]; then
            do_stream_copy "$file" "$output" "$MAP_FLAGS"; return 98
        elif [ $log_rc -eq 98 ]; then
            return 98
        fi
        # LOG dialog returned 0 — apply LOG video filters
        _apply_log_filters
        local_profile="high"
        x264_pixfmt="${LOG_PIX_FMT:-yuv420p}"
        [[ "$x264_pixfmt" == "yuv420p10le" ]] && local_profile="high10"
    else
    # ── Dialog per fisier (standard, non-LOG) ────────────────────────
    echo ""
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║  x264 — ANALIZA SURSA                        ║"
    printf "  ║  Fisier : %-37s║\n" "$filename"
    printf "  ║  Sursa  : %-37s║\n" "$src_label"
    printf "  ║  Rezol. : %-37s║\n" "${WIDTH}x${HEIGHT}"
    echo "  ╠══════════════════════════════════════════════╣"
    if [ "$src_is_hdr" -eq 1 ]; then
        echo "  ║  ⚠ x264 NU suporta metadata HDR/DV/HDR10+.  ║"
        echo "  ║  Re-encode va produce video SDR (fara meta). ║"
        echo "  ║  Doar Stream Copy pastreaza metadata intact. ║"
        echo "  ╠══════════════════════════════════════════════╣"
    fi
    echo "  ║  Cum encodam?                                ║"
    echo "  ║  1) 8-bit  (high — compatibilitate maxima)   ║"
    echo "  ║  2) 10-bit (high10 — calitate, anti-banding) ║"
    echo "  ║  3) Stream copy video (pastreaza tot, rapid)  ║"
    echo "  ║  4) Sari acest fisier                        ║"
    echo "  ╚══════════════════════════════════════════════╝"
    read -p "  Alege 1-4 [implicit: 1]: " x264_user_choice

    case "${x264_user_choice:-1}" in
        2) local_profile="high10"; x264_pixfmt="yuv420p10le"
           log "  Ales: 10-bit (high10)" ;;
        3)
           log "  Ales: Stream copy video"
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
           return 98 ;;
        4) log "  Sarit de utilizator"; return 98 ;;
        *) local_profile="high"; x264_pixfmt="yuv420p"
           log "  Ales: 8-bit (high)" ;;
    esac
    fi  # end LOG vs standard dialog

    # ── Rate control ──────────────────────────────────────────────────
    local tune_flag="" crf_flag="" rate_flag=""
    [[ -n "$TUNE_OPT" ]] && tune_flag="-tune $TUNE_OPT"
    if [[ "$ENCODE_MODE" == "2" && -n "$VBR_TARGET" ]]; then
        rate_flag="-b:v $VBR_TARGET -maxrate $VBR_MAXRATE -bufsize $VBR_BUFSIZE"
        log "  VBR: $VBR_TARGET / max $VBR_MAXRATE"
    else
        crf_flag="-crf $CRF"; log "  CRF: $CRF | ${WIDTH}px"
    fi

    # ── Level ────────────────────────────────────────────────────────
    local x264_level
    if [ "$WIDTH" -ge 3840 ] || [ "$local_profile" = "high422" ]; then x264_level="5.1"
    elif [ "$WIDTH" -ge 2560 ]; then x264_level="5.0"
    else x264_level="4.1"; fi

    local x264_bf="-bf 3"
    local x264_refs=$([ "$local_profile" = "high10" ] || [ "$local_profile" = "high422" ] && echo "-refs 4" || echo "-refs 3")
    local x264extra=""
    [[ -n "$EXTRA_X264" ]] && x264extra="-x264-params $EXTRA_X264"
    local video_params="-profile:v $local_profile -level:v $x264_level -pix_fmt $x264_pixfmt $x264_bf $x264_refs ${LOG_COLOR_FLAGS:-} ${x264_hlg_color_flags}"
    log "  Profil: $local_profile | Level: $x264_level | PixFmt: $x264_pixfmt"
    log "  Container: $CONTAINER | Preset: $PRESET | Tune: ${TUNE_OPT:-fara}"

    # ── Dry-run ──────────────────────────────────────────────────────
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        local sf="SDR"; [ "$src_is_hdr" -eq 1 ] && sf="HDR"; [[ -n "$DOVI" ]] && sf="DV"
        [[ "${IS_HLG:-0}" == "1" ]] && sf="HLG"
        [[ -n "$LOG_PROFILE" ]] && sf="LOG ($LOG_PROFILE)"
        dry_run_report "$file" "$output" "libx264 / $PRESET / $local_profile" "$WIDTH" "$DURATION" "$sf"
        return 0
    fi

    FFMPEG_CMD="ffmpeg -threads $THREADS -i \"\$file\" $MAP_FLAGS \
        -c:v libx264 -preset $PRESET $tune_flag $crf_flag \
        $video_params $VIDEO_FILTER $x264extra $rate_flag $AUDIO_PARAMS"
    return 0
}

run_encode_loop
