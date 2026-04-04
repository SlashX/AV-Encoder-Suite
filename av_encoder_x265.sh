#!/data/data/com.termux/files/usr/bin/bash
# ══════════════════════════════════════════════════════════════════════
# av_encoder_x265.sh — Encoder H.265/HEVC cu suport HDR, DV, DJI
# v26: Doar logica specifica — loop-ul e in av_common.sh
# ══════════════════════════════════════════════════════════════════════

THREADS=$(nproc)
ENCODER_TYPE="x265"

INPUT_DIR="/storage/emulated/0/Media/InputVideos"
OUTPUT_DIR="/storage/emulated/0/Media/OutputVideos"

AUDIO_CODEC_ARG="${1:-aac:192k}"
CUSTOM_CRF="$2"; PRESET="${3:-slow}"; TUNE_OPT="$4"; EXTRA_X265="$5"
ENCODE_MODE="${6:-1}"; VBR_TARGET="$7"; VBR_MAXRATE="$8"; VBR_BUFSIZE="$9"
CONTAINER="${11:-mkv}"; SCALE_WIDTH="${12}"; TARGET_FPS="${13}"
FPS_METHOD="${14}"; VIDEO_FILTER_PRESET="${15}"; AUDIO_NORMALIZE="${16:-0}"

LOG_FILE="$OUTPUT_DIR/av_encode_log_x265.txt"
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/av_common.sh"
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
    [[ -n "$EXTRA_X265" ]] && result="$result:$EXTRA_X265"
    echo "$result"
}

encoder_get_suffix() { echo "_x265"; }
encoder_get_label()  { echo "libx265"; }

encoder_log_header() {
    if [[ "$ENCODE_MODE" == "2" ]]; then
        log "Mod encodare   : VBR | $VBR_TARGET / $VBR_MAXRATE"
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

    # ── Dolby Vision ──────────────────────────────────────────────────
    if [[ -n "$DOVI" ]]; then
        log "  Dolby Vision detectat"
        handle_dv_with_stats "$file" "$filename" "$output" "$MAP_FLAGS" \
            "Converteste la HDR10 (best-effort, Profil 8.x)"
        local dv_rc=$?
        [ $dv_rc -eq 0 ]  && return 98
        [ $dv_rc -eq 98 ] && return 98
        [ $dv_rc -ne 99 ] && { log "  EROARE DV"; rm -f "$output"; return 1; }
        log "  Conversie DV → HDR10 (best-effort)"
    fi

    # ── Rate control ──────────────────────────────────────────────────
    local tune_flag="" crf_flag="" rate_flag=""
    [[ -n "$TUNE_OPT" ]] && tune_flag="-tune $TUNE_OPT"
    if [[ "$ENCODE_MODE" == "2" && -n "$VBR_TARGET" ]]; then
        rate_flag="-b:v $VBR_TARGET -maxrate $VBR_MAXRATE -bufsize $VBR_BUFSIZE"
        log "  VBR: $VBR_TARGET / max $VBR_MAXRATE"
    else
        crf_flag="-crf $CRF"; log "  CRF: $CRF | ${WIDTH}px"
    fi

    # ── HDR params ────────────────────────────────────────────────────
    local x265params video_params hdr10plus_param=""
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
            sc_pid=$!; _show_progress "$sc_pid" "$sc_pf" "$file"; wait "$sc_pid"
            local sc_rc=$?; PROGRESS_FILE=""
            if [ $sc_rc -eq 0 ]; then
                NEW_SIZE=$(stat -c%s "$output" 2>/dev/null || echo 0)
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
        x265params=$(build_x265_params "hdr-opt=1:repeat-headers=1:hdr10=1${hdr10plus_param}")
        video_params="-pix_fmt yuv420p10le -x265-params $x265params -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc"
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
            # HDR10 conversion from Log
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
            x265params=$(build_x265_params "hdr-opt=1:repeat-headers=1:hdr10=1")
            video_params="-pix_fmt yuv420p10le -x265-params $x265params -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc"
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
                x265params=$(build_x265_params "hdr-opt=1:repeat-headers=1:hdr10=1")
                video_params="-pix_fmt yuv420p10le -x265-params $x265params -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc"
                ;;
            sdr_tonemap)
                x265params=$(build_x265_params "")
                video_params="-pix_fmt yuv420p10le -x265-params $x265params -color_primaries bt709 -color_trc bt709 -colorspace bt709"
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
        [[ -n "$DOVI" ]] && sf="Dolby Vision"
        [[ -n "$LOG_PROFILE" ]] && sf="LOG ($LOG_PROFILE)"
        dry_run_report "$file" "$output" "libx265 / $PRESET" "$WIDTH" "$DURATION" "$sf"
        return 0
    fi

    # ── Comanda ffmpeg ────────────────────────────────────────────────
    FFMPEG_CMD="ffmpeg -threads $THREADS -i \"\$file\" $MAP_FLAGS \
        -c:v libx265 -preset $PRESET $tune_flag $crf_flag \
        $video_params $VIDEO_FILTER $rate_flag $AUDIO_PARAMS"
    return 0
}

run_encode_loop
