#!/data/data/com.termux/files/usr/bin/bash
# ══════════════════════════════════════════════════════════════════════
# av_common.sh — Functii partajate + run_encode_loop()
#
# v26: Arhitectura unificata — loop-ul principal e AICI.
# Fiecare encoder defineste doar functiile specifice:
#   encoder_log_header()     — linii log specifice
#   encoder_setup_file()     — per fisier: seteaza FFMPEG_CMD (return 0/98)
#   encoder_get_suffix()     — "_x265" / "_x264" / "_av1" / "_dnxhr"
#   encoder_get_label()      — "libx265" / "libx264" / ... (UI)
# ══════════════════════════════════════════════════════════════════════

INPUT_DIR="/storage/emulated/0/Media/InputVideos"
OUTPUT_DIR="/storage/emulated/0/Media/OutputVideos"
LUTS_DIR="/storage/emulated/0/Media/Luts"
TOOLS_DIR="/storage/emulated/0/Media/Scripts/tools"
PROFILES_DIR="/storage/emulated/0/Media/Scripts/profiles"
USER_PROFILES_DIR="/storage/emulated/0/Media/UserProfiles"

# ── Logging ───────────────────────────────────────────────────────────
log() {
    if [ -n "${LOG_FILE:-}" ]; then
        echo "$1" | tee -a "$LOG_FILE"
    else
        echo "$1"
    fi
}

# ── Cleanup trap ──────────────────────────────────────────────────────
setup_trap() { trap '_cleanup_on_exit' INT TERM; }

_cleanup_on_exit() {
    [ -n "${PROGRESS_FILE:-}" ] && rm -f "$PROGRESS_FILE"
    termux-wake-unlock 2>/dev/null
    echo ""; log "  INTRERUPT de utilizator."; exit 1
}

# ══════════════════════════════════════════════════════════════════════
# DETECTIE SURSA — un singur loc, seteaza variabile globale
# WIDTH, HEIGHT, HDR_TYPE, HDR_PLUS, DOVI, DURATION, SRC_FPS, SRC_FPS_DEC
# ══════════════════════════════════════════════════════════════════════
detect_source_info() {
    local file="$1"
    read -r WIDTH HEIGHT HDR_TYPE < <(ffprobe -v error -select_streams v:0 \
        -show_entries stream=width,height,color_transfer \
        -of csv=p=0 "$file" 2>/dev/null | tr ',' ' ')
    [[ ! "$WIDTH"  =~ ^[0-9]+$ ]] && WIDTH=0
    [[ ! "$HEIGHT" =~ ^[0-9]+$ ]] && HEIGHT=0

    HDR_PLUS=$(ffprobe -v error -read_intervals 0%+#5 -show_frames \
        -select_streams v:0 -show_entries frame_side_data=type \
        "$file" 2>/dev/null | grep -m1 "HDR10+")

    DOVI=$(ffprobe -v error -show_entries stream=codec_tag_string \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | \
        grep -i "dovi\|dvhe\|dvh1" | head -1)

    DURATION=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
    DURATION=${DURATION%.*}; [[ ! "$DURATION" =~ ^[0-9]+$ ]] && DURATION=0

    SRC_FPS=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=r_frame_rate \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1)
    SRC_FPS_DEC=$(awk "BEGIN{printf \"%.3f\", $SRC_FPS}" 2>/dev/null)

    # ── LOG format detection ──────────────────────────────────────────
    LOG_PROFILE=""
    CAMERA_MAKE=""
    SRC_COLOR_TRC=""
    SRC_IS_VFR=0

    if [[ "${FORCE_LOG_DETECTION:-0}" == "1" ]]; then
        LOG_PROFILE="forced_log"
        CAMERA_MAKE="unknown"
    else
        # Detect camera make from format tags
        local all_tags
        all_tags=$(ffprobe -v error -show_entries format_tags \
            -of default=noprint_wrappers=1 "$file" 2>/dev/null)
        # Apple: com.apple.quicktime.make=Apple
        if echo "$all_tags" | grep -qi "make=.*apple"; then
            CAMERA_MAKE="apple"
        # DJI: com.apple.quicktime.make=DJI or make=DJI
        elif echo "$all_tags" | grep -qi "make=.*dji"; then
            CAMERA_MAKE="dji"
        # Samsung: com.android.manufacturer=samsung or make=samsung
        elif echo "$all_tags" | grep -qi "manufacturer=.*samsung\|make=.*samsung"; then
            CAMERA_MAKE="samsung"
        fi
        # Fallback: DJI tracks detection (already have detect_dji_tracks)
        if [[ -z "$CAMERA_MAKE" ]] && [[ "${IS_DJI:-0}" -eq 1 ]]; then
            CAMERA_MAKE="dji"
        fi

        # Detect color transfer characteristic
        SRC_COLOR_TRC=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=color_transfer \
            -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1)

        # Detect bit depth
        local src_bps
        src_bps=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=bits_per_raw_sample \
            -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1)
        [[ ! "$src_bps" =~ ^[0-9]+$ ]] && src_bps=8

        # Detect color primaries
        local src_primaries
        src_primaries=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=color_primaries \
            -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1)

        # Samsung Log mode tag
        local samsung_log_tag
        samsung_log_tag=$(echo "$all_tags" | grep -i "log_mode\|samsung.*log" | head -1)

        # LOG profile identification
        # Apple Log: color_trc typically reports as arib-std-b67 or specific Apple Log tag
        if [[ "$CAMERA_MAKE" == "apple" ]]; then
            if [[ "$src_bps" -ge 10 ]] && [[ "$src_primaries" == *"bt2020"* || "$SRC_COLOR_TRC" == *"arib"* || "$SRC_COLOR_TRC" == *"log"* ]]; then
                LOG_PROFILE="apple_log"
            fi
        # Samsung Log
        elif [[ "$CAMERA_MAKE" == "samsung" ]]; then
            if [[ -n "$samsung_log_tag" ]] || { [[ "$src_bps" -ge 10 ]] && [[ "$src_primaries" == *"bt2020"* ]]; }; then
                # Samsung HDR10+ is NOT Log — already handled by HDR_PLUS check
                # Only mark as Log if no HDR10+ detected
                if [[ -z "$HDR_PLUS" ]] && [[ "$HDR_TYPE" != *"smpte2084"* ]]; then
                    LOG_PROFILE="samsung_log"
                fi
            fi
        # DJI D-Log M
        elif [[ "$CAMERA_MAKE" == "dji" ]]; then
            if [[ "$src_bps" -ge 10 ]] && [[ "$src_primaries" == *"bt2020"* ]]; then
                LOG_PROFILE="dlog_m"
            fi
        # Unknown brand but looks like Log (10-bit + bt2020 + no HDR metadata)
        elif [[ "$src_bps" -ge 10 ]] && [[ "$src_primaries" == *"bt2020"* ]] \
             && [[ -z "$HDR_PLUS" ]] && [[ "$HDR_TYPE" != *"smpte2084"* ]] && [[ -z "$DOVI" ]]; then
            # Check for known Log transfer characteristics
            if [[ "$SRC_COLOR_TRC" == "unknown" || "$SRC_COLOR_TRC" == *"log"* \
                || "$SRC_COLOR_TRC" == *"arib"* ]]; then
                LOG_PROFILE="unknown_log"
                CAMERA_MAKE="unknown"
            fi
        fi
    fi

    # VFR detection (useful for Log sources from phones)
    if [[ -n "$LOG_PROFILE" ]]; then
        local avg_fps
        avg_fps=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=avg_frame_rate \
            -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1)
        if [[ -n "$avg_fps" ]] && [[ -n "$SRC_FPS" ]]; then
            local avg_dec src_dec
            avg_dec=$(awk "BEGIN{printf \"%.3f\", $avg_fps}" 2>/dev/null)
            src_dec=$(awk "BEGIN{printf \"%.3f\", $SRC_FPS}" 2>/dev/null)
            # If avg_fps differs significantly from r_frame_rate, likely VFR
            local diff
            diff=$(awk "BEGIN{d=$src_dec-$avg_dec; if(d<0)d=-d; print (d > 0.5) ? 1 : 0}" 2>/dev/null)
            [[ "$diff" == "1" ]] && SRC_IS_VFR=1
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════════
# DJI HANDLING
# ══════════════════════════════════════════════════════════════════════
detect_dji_tracks() {
    local file="$1"
    local has_djmd=0 has_dbgi=0 has_tc=0 has_cover=0
    local tracks
    tracks=$(ffprobe -v error \
        -show_entries stream=index,codec_tag_string,codec_name,codec_type \
        -of default=noprint_wrappers=1 "$file" 2>/dev/null)
    echo "$tracks" | grep -qi "djmd"        && has_djmd=1
    echo "$tracks" | grep -qi "dbgi"        && has_dbgi=1
    echo "$tracks" | grep -qi "tmcd"        && has_tc=1
    echo "$tracks" | grep -qi "mjpeg\|jpeg" && has_cover=1
    echo "${has_djmd}|${has_dbgi}|${has_tc}|${has_cover}"
}

# Seteaza: MAP_FLAGS, IS_DJI, KEEP_DBGI; poate modifica CONTAINER/output
handle_dji_full() {
    local file="$1" out_suffix="$2"
    local dji_info
    dji_info=$(detect_dji_tracks "$file")
    IS_DJI=0; KEEP_DBGI=0

    if [ "$(echo "$dji_info" | cut -d'|' -f1)" -eq 1 ] || \
       [ "$(echo "$dji_info" | cut -d'|' -f2)" -eq 1 ]; then IS_DJI=1; fi

    if [ "$IS_DJI" -eq 1 ]; then
        log "  Fisier DJI detectat"
        if [[ "${ENCODER_TYPE:-}" == "dnxhr" ]]; then
            log "  Track-uri DJI omise (.mov/.mxf incompatibile)"
            MAP_FLAGS="-map 0:v:0 -map 0:a -map 0:s? -map_metadata 0 -map_chapters 0"
        else
            local dji_result switch_mkv
            dji_result=$(_dji_dialog "$file" "$dji_info" "$CONTAINER")
            KEEP_DBGI=$(echo "$dji_result" | grep -o 'KEEP_DBGI=[0-9]' | cut -d= -f2)
            [ -z "$KEEP_DBGI" ] && KEEP_DBGI=0
            switch_mkv=$(echo "$dji_result" | grep -o 'SWITCH_MKV=[0-9]' | cut -d= -f2)
            if [ "${switch_mkv:-0}" -eq 1 ]; then
                CONTAINER="mkv"; CONTAINER_FLAGS=""
                output="$OUTPUT_DIR/${name}${out_suffix}.mkv"
                log "  Container schimbat la mkv (track-uri DJI pastrate)"
            fi
            log "  Pastreaza dbgi: $([ "$KEEP_DBGI" -eq 1 ] && echo 'da' || echo 'nu')"
            MAP_FLAGS=$(build_map_flags "$file" "$KEEP_DBGI" "$dji_info")
        fi
    else
        MAP_FLAGS="-map 0:v -map 0:a -map 0:s? -map 0:t? -map_metadata 0 -map_chapters 0"
    fi
    log "  Map flags: $MAP_FLAGS"
}

_dji_dialog() {
    local file="$1" dji_info="$2" container="$3"
    local has_djmd has_dbgi has_tc has_cover
    has_djmd=$(echo "$dji_info" | cut -d'|' -f1)
    has_dbgi=$(echo "$dji_info"  | cut -d'|' -f2)
    has_tc=$(echo "$dji_info"    | cut -d'|' -f3)
    has_cover=$(echo "$dji_info" | cut -d'|' -f4)
    local is_dji=0
    [ "$has_djmd" -eq 1 ] || [ "$has_dbgi" -eq 1 ] && is_dji=1
    if [ "$is_dji" -eq 0 ]; then echo "KEEP_DBGI=0|IS_DJI=0|SWITCH_MKV=0"; return; fi
    {
        echo ""; echo "  ╔══════════════════════════════════════════════╗"
        echo "  ║  FISIER DJI DETECTAT                         ║"
        echo "  ╠══════════════════════════════════════════════╣"
        [ "$has_djmd"  -eq 1 ] && echo "  ║  ✅ djmd — GPS, telemetrie, setari camera    ║"
        [ "$has_tc"    -eq 1 ] && echo "  ║  ✅ tmcd — Timecode sincronizare              ║"
        [ "$has_dbgi"  -eq 1 ] && echo "  ║  ⚠️  dbgi — date debug DJI (~295 MB)          ║"
        [ "$has_cover" -eq 1 ] && echo "  ║  ℹ️  Cover JPEG — nu se copiaza (re-encode)   ║"
    } >/dev/tty
    local keep_dbgi=0 switch_mkv=0
    if [[ "$container" != "mkv" ]]; then
        {
            echo "  ╠══════════════════════════════════════════════╣"
            echo "  ║  Track-urile DJI nu pot fi copiate in $container   ║"
            echo "  ║  (codec 'none' incompatibil cu mp4/mov).     ║"
            echo "  ║  Metadatele raman in fisierul original.      ║"
            echo "  ╠══════════════════════════════════════════════╣"
            echo "  ║  1) Schimba la MKV (pastreaza tot)           ║"
            echo "  ║  2) Continua $container fara track-uri DJI [impl] ║"
            echo "  ╚══════════════════════════════════════════════╝"
        } >/dev/tty
        local cont_ch; read -p "  Alege 1 sau 2 [implicit: 2]: " cont_ch </dev/tty
        if [[ "${cont_ch:-2}" == "1" ]]; then
            switch_mkv=1
            if [ "$has_dbgi" -eq 1 ]; then
                { echo "  Pastrezi track-ul dbgi (debug, ~295 MB)?"; echo "  1) Da   2) Nu [recomandat]"; } >/dev/tty
                local dbgi_ch; read -p "  Alege [implicit: 2]: " dbgi_ch </dev/tty
                [[ "${dbgi_ch:-2}" == "1" ]] && keep_dbgi=1
            fi
        fi
    else
        if [ "$has_dbgi" -eq 1 ]; then
            {
                echo "  ╠══════════════════════════════════════════════╣"
                echo "  ║  Pastrezi track-ul dbgi (debug, ~295 MB)?    ║"
                echo "  ║  1) Da — pastreaza tot   2) Nu [recomandat]  ║"
                echo "  ╚══════════════════════════════════════════════╝"
            } >/dev/tty
            local dbgi_choice; read -p "  Alege 1 sau 2 [implicit: 2]: " dbgi_choice </dev/tty
            [[ "${dbgi_choice:-2}" == "1" ]] && keep_dbgi=1
        else
            echo "  ╚══════════════════════════════════════════════╝" >/dev/tty
        fi
    fi
    echo "KEEP_DBGI=${keep_dbgi}|IS_DJI=1|SWITCH_MKV=${switch_mkv}"
}

build_map_flags() {
    local file="$1" keep_dbgi="$2" dji_info="$3"
    local has_djmd has_dbgi has_tc
    has_djmd=$(echo "$dji_info" | cut -d'|' -f1)
    has_dbgi=$(echo "$dji_info"  | cut -d'|' -f2)
    has_tc=$(echo "$dji_info"    | cut -d'|' -f3)
    local is_dji=0
    [ "$has_djmd" -eq 1 ] || [ "$has_dbgi" -eq 1 ] && is_dji=1
    if [ "$is_dji" -eq 0 ]; then
        echo "-map 0:v -map 0:a -map 0:s? -map 0:t? -map_metadata 0 -map_chapters 0"; return
    fi
    local maps="-map 0:v:0 -map 0:a -map 0:s? -map 0:t?"
    if [[ "$CONTAINER" == "mkv" ]]; then
        local idx=0
        while IFS= read -r tag; do
            echo "$tag" | grep -qi "djmd" && maps="$maps -map 0:$idx"
            echo "$tag" | grep -qi "dbgi" && [ "$keep_dbgi" -eq 1 ] && maps="$maps -map 0:$idx"
            echo "$tag" | grep -qi "tmcd" && maps="$maps -map 0:$idx"
            idx=$((idx + 1))
        done < <(ffprobe -v error -show_entries stream=codec_tag_string -of csv=p=0 "$file" 2>/dev/null)
    fi
    echo "$maps -map_metadata 0 -map_chapters 0"
}

# ══════════════════════════════════════════════════════════════════════
# DOLBY VISION
# ══════════════════════════════════════════════════════════════════════
get_dv_profile() {
    local file="$1" dv_info dv_profile_num dv_compat
    dv_info=$(ffprobe -v error -show_frames -select_streams v:0 -read_intervals 0%+#5 \
        -show_entries frame_side_data=dv_profile,dv_bl_signal_compatibility_id \
        -of default "$file" 2>/dev/null)
    dv_profile_num=$(echo "$dv_info" | grep "dv_profile=" | head -1 | cut -d= -f2 | tr -d '[:space:]')
    dv_compat=$(echo "$dv_info" | grep "dv_bl_signal_compatibility_id=" | head -1 | cut -d= -f2 | tr -d '[:space:]')
    if [[ -n "$dv_profile_num" && "$dv_profile_num" =~ ^[0-9]+$ ]]; then
        case "$dv_profile_num" in
            4) echo "Profil 4 (DV + HDR10 fallback)" ;; 5) echo "Profil 5 (DV only)" ;;
            7) echo "Profil 7 (DV + HDR10+)" ;;
            8) case "$dv_compat" in
                1) echo "Profil 8.1 (DV + HDR10, Blu-ray)" ;; 2) echo "Profil 8.2 (DV + SDR)" ;;
                4) echo "Profil 8.4 (DV + HLG)" ;; *) echo "Profil 8 (DV + HDR10)" ;; esac ;;
            9) echo "Profil 9 (DV + SDR)" ;; *) echo "Profil $dv_profile_num" ;; esac
    else
        local codec_tag
        codec_tag=$(ffprobe -v error -show_entries stream=codec_tag_string \
            -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -5)
        case "$codec_tag" in *dvhe*) echo "Profil 8 (dvhe)";; *dvh1*) echo "Profil 8 (dvh1)";; *) echo "DV (profil nedetectat)";; esac
    fi
}

# DV stream copy — return: 0=copy OK, 98=sarit, 99=re-encode
handle_dolby_vision() {
    local file="$1" filename="$2" output="$3" map_flags="$4"
    local opt2_label="${5:-Converteste la HDR10 (best-effort)}"
    echo ""
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║       DOLBY VISION DETECTAT                  ║"
    printf "  ║  Fisier: %-38s║\n" "$filename"
    printf "  ║  Profil: %-38s║\n" "$(get_dv_profile "$file")"
    echo "  ╠══════════════════════════════════════════════╣"
    echo "  ║  1) Stream copy video + reencodeaza audio    ║"
    printf "  ║  2) %-43s║\n" "$opt2_label"
    echo "  ║  3) Sari acest fisier                        ║"
    echo "  ╚══════════════════════════════════════════════╝"
    read -p "  Alege 1, 2 sau 3: " dv_choice
    case "$dv_choice" in
        1)
            log "  DV: stream copy"
            local dv_audio sub_codec_dv pf fpid dv_container_flags
            dv_audio=$(get_audio_params "$file"); sub_codec_dv=$(get_subtitle_codec "$file")
            pf=$(mktemp); PROGRESS_FILE="$pf"; dv_container_flags=$(get_container_flags)
            # shellcheck disable=SC2086
            ffmpeg -threads "$THREADS" -i "$file" $map_flags \
                -c:v copy $dv_audio $sub_codec_dv -c:t copy \
                $dv_container_flags -progress "$pf" -nostats "$output" 2>>"$LOG_FILE" &
            fpid=$!; _show_progress "$fpid" "$pf" "$file"; wait "$fpid"
            local rc=$?; PROGRESS_FILE=""; return $rc ;;
        2) log "  DV: re-encode ($opt2_label)"; return 99 ;;
        3) log "  DV: sarit de utilizator"; return 98 ;;
        *) log "  DV: sarit (optiune invalida)"; return 98 ;;
    esac
}

# DV handling per encoder — wrapper cu post-encode stats
# Apelat din encoder_setup_file. Return: 0=DV copy done, 98=skip, 99=re-encode
handle_dv_with_stats() {
    local file="$1" filename="$2" output="$3" map_flags="$4" dv_label="$5"
    START_TIME=$(date +%s)
    handle_dolby_vision "$file" "$filename" "$output" "$map_flags" "$dv_label"
    local dv_rc=$?
    if [ $dv_rc -eq 0 ]; then
        # Stream copy OK — raportam stats si marcam done
        NEW_SIZE=$(stat -c%s "$output" 2>/dev/null || echo 0)
        SAVED=$(( ORIGINAL_SIZE - NEW_SIZE )); [ $SAVED -lt 0 ] && SAVED=0
        TOTAL_SAVED=$(( TOTAL_SAVED+SAVED ))
        ENCODE_TIME=$(( $(date +%s) - START_TIME ))
        log "  Original: $(( ORIGINAL_SIZE/1024/1024 )) MB | Nou: $(( NEW_SIZE/1024/1024 )) MB"
        log "  Timp: $((ENCODE_TIME/60))m $((ENCODE_TIME%60))s"
        log "────────────────────────────────────────"
        TOTAL_DONE=$((TOTAL_DONE+1))
        BATCH_NAMES+=("$filename"); BATCH_TIMES+=("$ENCODE_TIME")
        BATCH_ORIG+=("$ORIGINAL_SIZE"); BATCH_NEW+=("$NEW_SIZE")
        [ "$ORIGINAL_SIZE" -gt 0 ] && BATCH_RATIOS+=("$(awk "BEGIN{printf \"%.1f\", $NEW_SIZE * 100.0 / $ORIGINAL_SIZE}")") || BATCH_RATIOS+=("N/A")
        batch_mark_done "$filename"
        return 0  # skip restul loop-ului
    fi
    return $dv_rc
}

# ══════════════════════════════════════════════════════════════════════
# SUBTITLE / CONTAINER / SOURCE HINTS
# ══════════════════════════════════════════════════════════════════════
get_subtitle_codec() {
    local file="$1"
    case "$CONTAINER" in
        mkv) echo "-c:s copy" ;;
        mp4|mov)
            local sub_codecs
            sub_codecs=$(ffprobe -v error -select_streams s \
                -show_entries stream=codec_name \
                -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
            if echo "$sub_codecs" | grep -qi "hdmv_pgs\|dvd_subtitle\|dvb_subtitle"; then
                log "  ATENTIE: Subtitrari PGS/DVDSUB incompatibile cu $CONTAINER — omise"
                echo "-sn"
            else echo "-c:s mov_text"; fi ;;
        *) echo "-c:s copy" ;;
    esac
}

get_container_flags() {
    case "$CONTAINER" in mkv|mxf|webm) echo "" ;; *) echo "-movflags +faststart" ;; esac
}

hint_source_format() {
    local ext="$1"
    case "$ext" in
        vob) log "  SURSA DVD (.vob): MPEG-2, posibil interlasata."
             log "  Recomandat: activeaza filtrul Deinterlace (bwdif)." ;;
        m2ts|mts) log "  SURSA Blu-ray (.m2ts): H.264/H.265, progresiv de obicei." ;;
        mxf) log "  SURSA MXF: format profesional (Avid, broadcast)." ;;
        apv) log "  SURSA APV: codec profesional nou. Necesita ffmpeg 8.1+." ;;
    esac
    # ProRes detectat pe baza codec-ului, nu a extensiei (vine in .mov)
    if [[ -n "$file" ]]; then
        local src_codec_hint
        src_codec_hint=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=codec_name -of csv=p=0 "$file" 2>/dev/null)
        [[ "$src_codec_hint" == "prores" ]] && log "  SURSA ProRes: codec Apple profesional (intra-frame, editare)."
    fi
}

# ══════════════════════════════════════════════════════════════════════
# VIDEO FILTERS
# ══════════════════════════════════════════════════════════════════════
_get_preset_vf() {
    case "${VIDEO_FILTER_PRESET:-}" in
        denoise_light)  echo "nlmeans=h=1.0:s=7:p=3:r=5" ;;
        denoise_medium) echo "hqdn3d=luma_spatial=4:chroma_spatial=3:luma_tmp=6:chroma_tmp=4.5" ;;
        denoise_strong) echo "nlmeans=h=3.0:s=7:p=5:r=9" ;;
        sharpen_light)  echo "unsharp=luma_msize_x=5:luma_msize_y=5:luma_amount=0.8:chroma_msize_x=5:chroma_msize_y=5:chroma_amount=0.4" ;;
        sharpen_medium) echo "cas=strength=0.6" ;;
        deinterlace)    echo "bwdif=mode=send_field:parity=auto:deint=all" ;;
        upscale_4k)     echo "scale=3840:-2:flags=lanczos" ;;
        custom:*)       echo "${VIDEO_FILTER_PRESET#custom:}" ;;
        *)              echo "" ;;
    esac
}

build_video_filters() {
    local src_width="$1" src_fps="$2" vf_parts=""
    if [[ "${VIDEO_FILTER_PRESET:-}" != "upscale_4k" ]]; then
        if [[ -n "$SCALE_WIDTH" ]] && [[ "$src_width" =~ ^[0-9]+$ ]] && [ "$src_width" -gt "$SCALE_WIDTH" ]; then
            vf_parts="scale=${SCALE_WIDTH}:-2"
        fi
    fi
    local preset_vf; preset_vf=$(_get_preset_vf)
    if [[ -n "$preset_vf" ]]; then
        [[ -n "$vf_parts" ]] && vf_parts="${vf_parts},${preset_vf}" || vf_parts="$preset_vf"
    fi
    local fps_active=0
    if [[ -n "$TARGET_FPS" ]] && [[ -n "$src_fps" ]]; then
        local src_num target_num
        src_num=$(awk "BEGIN{printf \"%.3f\", $src_fps + 0}" 2>/dev/null)
        target_num=$(awk "BEGIN{printf \"%.3f\", $TARGET_FPS + 0}" 2>/dev/null)
        awk "BEGIN{exit !($src_num > $target_num)}" 2>/dev/null && fps_active=1
    fi
    if [ "$fps_active" -eq 1 ]; then
        if [[ "$FPS_METHOD" == "minterpolate" ]]; then
            local mi="minterpolate=fps=${TARGET_FPS}:mi_mode=mci:mc_mode=aobmc:vsbmc=1"
            [[ -n "$vf_parts" ]] && vf_parts="${vf_parts},$mi" || vf_parts="$mi"
            echo "-vf $vf_parts"
        else
            [[ -n "$vf_parts" ]] && echo "-vf $vf_parts -r $TARGET_FPS" || echo "-r $TARGET_FPS"
        fi
    else
        [[ -n "$vf_parts" ]] && echo "-vf $vf_parts"
    fi
}

# ══════════════════════════════════════════════════════════════════════
# PROGRESS BAR
# ══════════════════════════════════════════════════════════════════════
_show_progress() {
    local pid=$1 prog_file=$2 src_file=$3
    local dur_p st_p
    dur_p=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$src_file" 2>/dev/null)
    dur_p=${dur_p%.*}; [[ ! "$dur_p" =~ ^[0-9]+$ ]] && dur_p=0
    st_p=$(date +%s); PROGRESS_FILE="$prog_file"
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        local otms=$(grep "^out_time_ms=" "$prog_file" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' ')
        if ! [[ "$otms" =~ ^[0-9]+$ ]] || [ "$otms" -le 0 ]; then
            echo -ne "\r  Se initializeaza...                                    "; continue
        fi
        local ot=$((otms / 1000000)); [ "$ot" -lt 0 ] && ot=0
        local el=$(( $(date +%s) - st_p )); [ "$el" -le 0 ] && el=1
        local pct=$(( dur_p > 0 ? ot * 100 / dur_p : 0 )); [ "$pct" -gt 100 ] && pct=100
        local rfps; rfps=$(grep "^fps=" "$prog_file" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' ')
        if [[ "$rfps" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk "BEGIN{exit !($rfps > 0)}"; then :
        else [ "$ot" -gt 0 ] && rfps="$(awk "BEGIN{printf \"%.1f\", $ot / $el}")x" || rfps="0.0x"; fi
        local eta=0
        [ "$ot" -gt 0 ] && [ "$dur_p" -gt "$ot" ] && eta=$(( el * (dur_p - ot) / ot ))
        printf "\r  Progres: %3d%% | FPS: %s | Timp ramas: %02d:%02d:%02d   " \
            "$pct" "$rfps" $((eta/3600)) $(((eta%3600)/60)) $((eta%60))
    done
    rm -f "$prog_file"; PROGRESS_FILE=""; echo ""
}

# ══════════════════════════════════════════════════════════════════════
# AUDIO PARAMS
# ══════════════════════════════════════════════════════════════════════
get_audio_params() {
    local file="${1:-}"
    if [[ "$AUDIO_CODEC_ARG" == "copy" ]]; then
        if [[ "$CONTAINER" == "mp4" || "$CONTAINER" == "mov" ]] && [[ -n "$file" ]]; then
            local ac; ac=$(ffprobe -v error -select_streams a -show_entries stream=codec_name \
                -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
            if echo "$ac" | grep -qi "truehd\|dts\b\|dtshd\|dts_hd"; then
                log "  ATENTIE: Audio TrueHD/DTS-HD detectat — incompatibil cu $CONTAINER la copy."
            fi
        fi
        echo "-c:a copy"; return
    fi
    local codec="${AUDIO_CODEC_ARG%%:*}" br="${AUDIO_CODEC_ARG#*:}" channels=2
    if [[ -n "$file" ]]; then
        local ch_raw; ch_raw=$(ffprobe -v error -select_streams a:0 \
            -show_entries stream=channels -of csv=p=0 "$file" 2>/dev/null)
        [[ "$ch_raw" =~ ^[0-9]+$ ]] && channels=$ch_raw
    fi
    [[ -n "$file" ]] && _warn_audio_metadata "$file"
    case "$codec" in
        aac)
            if [[ "$br" == "192k" ]]; then
                [ "$channels" -gt 6 ] && br="768k" || { [ "$channels" -gt 2 ] && br="384k"; }
            fi; echo "-c:a:0 aac -b:a:0 $br -c:a copy" ;;
        opus)
            if [[ "$br" == "128k" ]]; then
                [ "$channels" -gt 6 ] && br="512k" || { [ "$channels" -gt 2 ] && br="256k"; }
            fi; echo "-c:a:0 libopus -b:a:0 $br -c:a copy" ;;
        flac) echo "-c:a:0 flac -compression_level $br -c:a copy" ;;
        eac3)
            if [[ "$br" == "224k" ]]; then
                [ "$channels" -gt 6 ] && br="1024k" || { [ "$channels" -gt 2 ] && br="640k"; }
            fi; echo "-c:a:0 eac3 -b:a:0 $br -c:a copy" ;;
        pcm)
            local pcm_fmt="pcm_s${br}"
            echo "-c:a:0 $pcm_fmt -c:a copy" ;;
        *) echo "-c:a:0 aac -b:a:0 192k -c:a copy" ;;
    esac
}

_warn_audio_metadata() {
    local file="$1" ac ap
    ac=$(ffprobe -v error -select_streams a -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
    ap=$(ffprobe -v error -select_streams a -show_entries stream=profile \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
    if echo "$ac" | grep -qi "truehd"; then
        log "  ⚠ ATENTIE: Sursa contine TrueHD."
        log "    Metadata Dolby Atmos (obiecte spatiale JOC) se va pierde la re-encode."
    fi
    if echo "$ac" | grep -qi "dts"; then
        if echo "$ap" | grep -qi "DTS-HD MA\|DTS:X"; then
            log "  ⚠ ATENTIE: Sursa contine DTS-HD MA / DTS:X — metadata pierduta la re-encode."
        else
            log "  ⚠ ATENTIE: Sursa contine DTS — metadata pierduta la re-encode."
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════════
# HDR10+ METADATA EXTRACTION (pentru re-encode cu pastrare metadata)
# Necesita: hdr10plus_tool (quietvoid/hdr10plus_tool)
# ══════════════════════════════════════════════════════════════════════
HDR10PLUS_TOOL_AVAILABLE=""

_check_hdr10plus_tool() {
    if [[ -z "$HDR10PLUS_TOOL_AVAILABLE" ]]; then
        if command -v hdr10plus_tool &>/dev/null; then
            HDR10PLUS_TOOL_AVAILABLE=1
        else
            HDR10PLUS_TOOL_AVAILABLE=0
        fi
    fi
    [[ "$HDR10PLUS_TOOL_AVAILABLE" == "1" ]]
}

# Extrage metadata HDR10+ dintr-un fisier video intr-un JSON temporar.
# Return: calea JSON pe stdout, cod 0=OK, 1=esuat
extract_hdr10plus_metadata() {
    local file="$1"
    local json_file src_codec
    json_file=$(mktemp --suffix=.json)
    # Detectam codec-ul sursa pentru a alege bitstream filter-ul corect
    src_codec=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name -of csv=p=0 "$file" 2>/dev/null)
    # Log pe stderr (nu stdout) — stdout e rezervat pentru calea JSON
    echo "  HDR10+: Extrag metadata dinamica..." | tee -a "${LOG_FILE:-/dev/null}" >&2
    if [[ "$src_codec" == "av1" ]]; then
        # AV1: extragere directa (hdr10plus_tool suporta OBU)
        ffmpeg -v error -i "$file" -c:v copy -f ivf - 2>/dev/null | \
            hdr10plus_tool extract -i - -o "$json_file" 2>/dev/null
    else
        # HEVC: bitstream filter pentru annex-B
        ffmpeg -v error -i "$file" -c:v copy -bsf:v hevc_mp4toannexb -f hevc - 2>/dev/null | \
            hdr10plus_tool extract -i - -o "$json_file" 2>/dev/null
    fi
    if [ $? -eq 0 ] && [ -s "$json_file" ]; then
        local count
        count=$(grep -c '"BezierCurveData"\|"TargetedSystemDisplayMaximumLuminance"' "$json_file" 2>/dev/null)
        echo "  HDR10+: Metadata extrasa ($count scene descriptors)" | tee -a "${LOG_FILE:-/dev/null}" >&2
        echo "$json_file"
        return 0
    else
        echo "  HDR10+: Extractie esuata — fallback la HDR10 static" | tee -a "${LOG_FILE:-/dev/null}" >&2
        rm -f "$json_file"
        return 1
    fi
}

# Dialog HDR10+ per fisier — oferit cand sursa are HDR10+.
# Return: 0=re-encode cu metadata, 1=re-encode HDR10 static, 98=stream copy
# Seteaza HDR10PLUS_JSON global (calea JSON sau gol)
handle_hdr10plus_dialog() {
    local file="$1"
    HDR10PLUS_JSON=""
    echo ""
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║  HDR10+ DETECTAT                              ║"
    echo "  ╠══════════════════════════════════════════════╣"
    if _check_hdr10plus_tool; then
        echo "  ║  1) Re-encode HDR10 static (pierde +)        ║"
        echo "  ║  2) Re-encode HDR10+ (pastreaza metadata)    ║"
        echo "  ║     → extrage JSON via hdr10plus_tool        ║"
        echo "  ║  3) Stream copy video (pastreaza tot, rapid) ║"
        if _check_dovi_tool; then
            echo "  ║  4) Triple-layer DV+HDR10+HDR10+             ║"
            echo "  ║     → DV Profile 8.1 + HDR10 + HDR10+       ║"
            echo "  ║     necesita: hdr10plus_tool + dovi_tool     ║"
        else
            echo "  ╠══════════════════════════════════════════════╣"
            echo "  ║  dovi_tool NU este instalat.                 ║"
            echo "  ║  Fara el, Triple-layer DV nu este disponibil.║"
            echo "  ║  Instaleaza cu: $TOOLS_DIR/dovi_parser.sh       ║"
        fi
        echo "  ╚══════════════════════════════════════════════╝"
        local max_opt=3
        _check_dovi_tool && max_opt=4
        read -p "  Alege 1-$max_opt [implicit: 2]: " hdr10p_choice
        case "${hdr10p_choice:-2}" in
            1) log "  HDR10+: Re-encode ca HDR10 static (fara metadata dinamica)"
               return 1 ;;
            3) log "  HDR10+: Stream copy (video pastrat integral)"
               return 98 ;;
            4)
                if _check_dovi_tool; then
                    HDR10PLUS_JSON=$(extract_hdr10plus_metadata "$file")
                    if [[ -n "$HDR10PLUS_JSON" ]]; then
                        DOVI_RPU_FILE=$(generate_dv_rpu_from_hdr10plus "$HDR10PLUS_JSON")
                        if [[ -n "$DOVI_RPU_FILE" ]]; then
                            log "  Triple-layer: HDR10+ JSON + DV RPU pregatite"
                            TRIPLE_LAYER_MODE=1
                            return 0
                        else
                            log "  Triple-layer: generare RPU esuata — fallback la HDR10+"
                            TRIPLE_LAYER_MODE=0
                            return 0
                        fi
                    else
                        log "  Triple-layer: extractie HDR10+ esuata — fallback la HDR10 static"
                        TRIPLE_LAYER_MODE=0
                        return 1
                    fi
                fi
                ;& # fallthrough to default
            *)
                HDR10PLUS_JSON=$(extract_hdr10plus_metadata "$file")
                if [[ -n "$HDR10PLUS_JSON" ]]; then
                    log "  HDR10+: Metadata pregatita pentru injectare"
                    TRIPLE_LAYER_MODE=0
                    return 0
                else
                    log "  HDR10+: Extractie esuata — re-encode ca HDR10 static"
                    TRIPLE_LAYER_MODE=0
                    return 1
                fi ;;
        esac
    else
        echo "  ║  hdr10plus_tool NU este instalat.            ║"
        echo "  ║  Fara el, metadata dinamica se pierde.       ║"
        echo "  ║  Instaleaza cu: $TOOLS_DIR/hdr10plus_parser.sh   ║"
        echo "  ╠══════════════════════════════════════════════╣"
        echo "  ║  1) Re-encode HDR10 static (pierde +)        ║"
        echo "  ║  2) Stream copy video (pastreaza tot, rapid) ║"
        echo "  ╚══════════════════════════════════════════════╝"
        read -p "  Alege 1 sau 2 [implicit: 1]: " hdr10p_choice
        case "${hdr10p_choice:-1}" in
            2) log "  HDR10+: Stream copy"; return 98 ;;
            *) log "  HDR10+: Re-encode HDR10 static"; return 1 ;;
        esac
    fi
}

# ══════════════════════════════════════════════════════════════════════
# DOLBY VISION TRIPLE-LAYER (DV Profile 8.1 + HDR10 + HDR10+)
# Necesita: dovi_tool (quietvoid/dovi_tool) + hdr10plus_tool
# Pipeline: extract HDR10+ → generate DV RPU → encode x265 → inject RPU
# ══════════════════════════════════════════════════════════════════════
DOVI_TOOL_AVAILABLE=""

_check_dovi_tool() {
    if [[ -z "$DOVI_TOOL_AVAILABLE" ]]; then
        if command -v dovi_tool &>/dev/null; then
            DOVI_TOOL_AVAILABLE=1
        else
            DOVI_TOOL_AVAILABLE=0
        fi
    fi
    [[ "$DOVI_TOOL_AVAILABLE" == "1" ]]
}

# Genereaza DV RPU din HDR10+ JSON metadata.
# $1 = HDR10+ JSON path, return: RPU bin path pe stdout, 0=OK, 1=fail
generate_dv_rpu_from_hdr10plus() {
    local hdr10plus_json="$1"
    local rpu_file
    rpu_file=$(mktemp --suffix=.bin)

    # Config JSON minimal pentru Profile 8.1 CMv4.0
    local config_file
    config_file=$(mktemp --suffix=.json)
    cat > "$config_file" << 'DVCONF'
{
    "cm_version": "V40",
    "length": 1,
    "level5": {
        "active_area_left_offset": 0,
        "active_area_right_offset": 0,
        "active_area_top_offset": 0,
        "active_area_bottom_offset": 0
    },
    "level6": {
        "max_display_mastering_luminance": 1000,
        "min_display_mastering_luminance": 1,
        "max_content_light_level": 1000,
        "max_frame_average_light_level": 400
    }
}
DVCONF

    echo "  DV: Generez RPU din HDR10+ metadata..." | tee -a "${LOG_FILE:-/dev/null}" >&2
    dovi_tool generate -j "$config_file" \
        --hdr10plus-json "$hdr10plus_json" \
        -o "$rpu_file" 2>/dev/null
    local gen_rc=$?

    rm -f "$config_file"

    if [ $gen_rc -eq 0 ] && [ -s "$rpu_file" ]; then
        echo "  DV: RPU generat cu succes (Profile 8.1)" | tee -a "${LOG_FILE:-/dev/null}" >&2
        echo "$rpu_file"
        return 0
    else
        echo "  DV: Generare RPU esuata" | tee -a "${LOG_FILE:-/dev/null}" >&2
        rm -f "$rpu_file"
        return 1
    fi
}

# Injecteaza DV RPU intr-un fisier HEVC encodat.
# $1 = HEVC file, $2 = RPU bin, $3 = output file
inject_dv_rpu() {
    local hevc_file="$1" rpu_file="$2" output_file="$3"
    echo "  DV: Injectez RPU in HEVC bitstream..." | tee -a "${LOG_FILE:-/dev/null}" >&2
    dovi_tool inject-rpu -i "$hevc_file" \
        --rpu-in "$rpu_file" \
        -o "$output_file" 2>/dev/null
    if [ $? -eq 0 ] && [ -s "$output_file" ]; then
        echo "  DV: Injectare RPU reusita" | tee -a "${LOG_FILE:-/dev/null}" >&2
        return 0
    else
        echo "  DV: Injectare RPU esuata" | tee -a "${LOG_FILE:-/dev/null}" >&2
        return 1
    fi
}

# ══════════════════════════════════════════════════════════════════════
# STREAM COPY HELPER — cod partajat pentru stream copy cu stats
# Return: 0=OK, non-zero=eroare
# ══════════════════════════════════════════════════════════════════════
do_stream_copy() {
    local file="$1" output="$2" map_flags="$3"
    START_TIME=$(date +%s)
    local sc_audio sc_sub sc_cflags sc_pf sc_pid
    sc_audio=$(get_audio_params "$file"); sc_sub=$(get_subtitle_codec "$file")
    sc_cflags=$(get_container_flags); sc_pf=$(mktemp); PROGRESS_FILE="$sc_pf"
    # shellcheck disable=SC2086
    ffmpeg -threads "$THREADS" -i "$file" $map_flags \
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
    return $sc_rc
}

# ══════════════════════════════════════════════════════════════════════
# DIALOG ANALIZA SURSA — per fisier, pentru HDR10 si SDR (x265/AV1)
# Afisat cand sursa NU este DV, HDR10+, sau LOG.
# Return: 0=encode cu setarile alese, 97=stream copy, 98=skip
# Seteaza: SRC_DIALOG_MODE (hdr10/sdr_tonemap/sdr)
# ══════════════════════════════════════════════════════════════════════
handle_source_dialog() {
    local file="$1" filename="$2" encoder_type="$3"
    SRC_DIALOG_MODE=""

    # Detect source characteristics for display
    local src_pixfmt src_bitdepth="8-bit" src_label
    src_pixfmt=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=pix_fmt -of csv=p=0 "$file" 2>/dev/null)
    [[ "$src_pixfmt" == *"10"* ]] && src_bitdepth="10-bit"

    local is_hdr10=0
    [[ "$HDR_TYPE" == *"smpte2084"* ]] && is_hdr10=1

    if [ "$is_hdr10" -eq 1 ]; then
        src_label="HDR10 $src_bitdepth"
    else
        src_label="SDR $src_bitdepth"
    fi

    echo ""
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║  ANALIZA SURSA                               ║"
    printf "  ║  Fisier: %-37s║\n" "$filename"
    printf "  ║  Sursa : %-25s %s║\n" "$src_label |" "${WIDTH}x${HEIGHT}"
    echo "  ╠══════════════════════════════════════════════╣"

    if [ "$is_hdr10" -eq 1 ]; then
        echo "  ║  1) Encodeaza HDR10 10-bit                   ║"
        echo "  ║  2) Encodeaza SDR 10-bit (tonemap Rec.709)   ║"
        echo "  ║  3) Stream copy video                        ║"
        echo "  ║  4) Sari acest fisier                        ║"
        echo "  ╚══════════════════════════════════════════════╝"
        read -p "  Alege 1-4 [implicit: 1]: " src_choice
        case "${src_choice:-1}" in
            2) log "  Ales: SDR 10-bit (tonemap din HDR10)"
               SRC_DIALOG_MODE="sdr_tonemap"
               return 0 ;;
            3) log "  Ales: Stream copy video"
               return 97 ;;
            4) log "  Sarit de utilizator"
               return 98 ;;
            *) log "  Ales: HDR10 10-bit"
               SRC_DIALOG_MODE="hdr10"
               return 0 ;;
        esac
    else
        echo "  ║  1) Encodeaza 10-bit SDR                     ║"
        echo "  ║  2) Stream copy video                        ║"
        echo "  ║  3) Sari acest fisier                        ║"
        echo "  ╚══════════════════════════════════════════════╝"
        read -p "  Alege 1-3 [implicit: 1]: " src_choice
        case "${src_choice:-1}" in
            2) log "  Ales: Stream copy video"
               return 97 ;;
            3) log "  Sarit de utilizator"
               return 98 ;;
            *) log "  Ales: 10-bit SDR"
               SRC_DIALOG_MODE="sdr"
               return 0 ;;
        esac
    fi
}

# ══════════════════════════════════════════════════════════════════════
# LOG FORMAT VIDEO — LUT search + dialog per fisier
# Suporta: Apple Log, Samsung Log, DJI D-Log M, unknown Log
# LUT-uri cautate cu prefix: apple_log_*, samsung_log_*, dji_dlog_m_*
# ══════════════════════════════════════════════════════════════════════

# Cauta fisiere .cube pentru brand-ul detectat.
# Locatie: $LUTS_DIR (definit sus)
# Seteaza: LUT_FILES (array), LUT_SEARCH_DIR (unde a gasit)
find_lut_for_brand() {
    LUT_FILES=()
    LUT_SEARCH_DIR=""
    local brand="$1"
    local prefix=""
    case "$brand" in
        apple)   prefix="apple_log_" ;;
        samsung) prefix="samsung_log_" ;;
        dji)     prefix="dji_dlog_m_" ;;
        *)       prefix="" ;;
    esac

    local luts_dir="$LUTS_DIR"
    [[ ! -d "$luts_dir" ]] && return 1

    local found=()
    if [[ -n "$prefix" ]]; then
        shopt -s nullglob nocaseglob
        found=("$luts_dir"/${prefix}*.cube)
        shopt -u nocaseglob nullglob
    fi
    if [[ ${#found[@]} -eq 0 ]] && [[ "$brand" == "unknown" || "$brand" == "" ]]; then
        shopt -s nullglob nocaseglob
        found=("$luts_dir"/*.cube)
        shopt -u nocaseglob nullglob
    fi
    if [[ ${#found[@]} -gt 0 ]]; then
        LUT_FILES=("${found[@]}")
        LUT_SEARCH_DIR="$luts_dir"
        return 0
    fi
    return 1
}

# Cauta fisiere .cube creative in $LUTS_DIR/Creative/
# Seteaza: CREATIVE_LUT_FILES (array), CREATIVE_LUT_DIR
find_creative_luts() {
    CREATIVE_LUT_FILES=()
    CREATIVE_LUT_DIR=""
    local creative_dir="$LUTS_DIR/Creative"
    [[ ! -d "$creative_dir" ]] && return 1

    local found=()
    shopt -s nullglob nocaseglob
    found=("$creative_dir"/*.cube)
    shopt -u nocaseglob nullglob

    if [[ ${#found[@]} -gt 0 ]]; then
        CREATIVE_LUT_FILES=("${found[@]}")
        CREATIVE_LUT_DIR="$creative_dir"
        return 0
    fi
    return 1
}

# Returneaza label-ul human-readable pentru LOG_PROFILE
_log_profile_label() {
    case "$1" in
        apple_log)   echo "Apple Log (iPhone)" ;;
        samsung_log) echo "Samsung Log (S24 Ultra)" ;;
        dlog_m)      echo "D-Log M (DJI)" ;;
        forced_log)  echo "LOG (fortat manual)" ;;
        unknown_log) echo "LOG (brand necunoscut)" ;;
        *)           echo "LOG" ;;
    esac
}

# Dialog LOG per fisier.
# Apelat din encoder_setup_file() cand LOG_PROFILE e setat.
# Seteaza: LOG_VIDEO_FILTER, LOG_COLOR_FLAGS, LOG_PIX_FMT, LOG_EXTRA_X265
# Return: 0=encode cu LOG settings, 97=stream copy, 98=skip
handle_log_dialog() {
    local file="$1" filename="$2" encoder_type="$3"
    LOG_VIDEO_FILTER=""
    LOG_COLOR_FLAGS=""
    LOG_PIX_FMT=""
    LOG_EXTRA_X265=""

    local profile_label
    profile_label=$(_log_profile_label "$LOG_PROFILE")

    # Search for LUT files
    find_lut_for_brand "$CAMERA_MAKE"
    local has_lut=0
    [[ ${#LUT_FILES[@]} -gt 0 ]] && has_lut=1
    find_creative_luts
    local has_creative_lut=0
    [[ ${#CREATIVE_LUT_FILES[@]} -gt 0 ]] && has_creative_lut=1

    echo ""
    echo "  ╔══════════════════════════════════════════════╗"
    printf "  ║  LOG DETECTAT: %-31s║\n" "$profile_label"
    printf "  ║  Fisier: %-37s║\n" "$filename"
    echo "  ╠══════════════════════════════════════════════╣"

    # VFR warning
    if [[ "$SRC_IS_VFR" -eq 1 ]]; then
        echo "  ║  ⚠ Sursa este VFR (Variable Frame Rate)     ║"
        echo "  ║    Audio sync poate fi afectat.              ║"
        echo "  ║    Recomandat: seteaza FPS fix din meniu.    ║"
        echo "  ╠══════════════════════════════════════════════╣"
    fi

    local opt_num=1
    local opt_lut=0 opt_sdr=0 opt_hdr=0 opt_preserve=0 opt_creative=0 opt_copy=0 opt_skip=0

    # ── Build menu based on encoder type ─────────────────────────────
    if [[ "$encoder_type" == "x264" ]]; then
        # x264: no HDR10 option, force 8-bit
        if [[ "$has_lut" -eq 1 ]]; then
            opt_lut=$opt_num
            if [[ ${#LUT_FILES[@]} -eq 1 ]]; then
                local _lut_name
                _lut_name=$(basename "${LUT_FILES[0]}")
                printf "  ║  %d) Apply LUT → 8-bit SDR Rec.709           ║\n" "$opt_num"
                printf "  ║     [✓ %-38s]║\n" "$_lut_name"
            else
                printf "  ║  %d) Apply LUT → 8-bit SDR Rec.709           ║\n" "$opt_num"
                printf "  ║     [%d LUT-uri gasite — selectie]           ║\n" "${#LUT_FILES[@]}"
            fi
            opt_num=$((opt_num + 1))
        fi
        opt_sdr=$opt_num
        printf "  ║  %d) Convert SDR (fara LUT) → 8-bit Rec.709  ║\n" "$opt_num"
        echo "  ║     (best-effort — LUT recomandat)           ║"
        opt_num=$((opt_num + 1))
        opt_preserve=$opt_num
        printf "  ║  %d) Preserve Log (compresie 8-bit)           ║\n" "$opt_num"
        echo "  ║     ⚠ 8-bit Log pierde gradatii — x265 rec.  ║"
        opt_num=$((opt_num + 1))
        if [[ "$has_creative_lut" -eq 1 ]]; then
            opt_creative=$opt_num
            printf "  ║  %d) Creative LUT (look artistic)             ║\n" "$opt_num"
            printf "  ║     [%d creative LUT-uri gasite]              ║\n" "${#CREATIVE_LUT_FILES[@]}"
            opt_num=$((opt_num + 1))
        fi
        opt_copy=$opt_num
        printf "  ║  %d) Stream copy video                        ║\n" "$opt_num"
        opt_num=$((opt_num + 1))
        opt_skip=$opt_num
        printf "  ║  %d) Sari acest fisier                        ║\n" "$opt_num"
    else
        # x265 / AV1: full menu with HDR10 option
        if [[ "$has_lut" -eq 1 ]]; then
            opt_lut=$opt_num
            if [[ ${#LUT_FILES[@]} -eq 1 ]]; then
                printf "  ║  %d) Apply LUT → 10-bit SDR Rec.709          ║\n" "$opt_num"
                printf "  ║     [✓ %-38s]║\n" "$(basename "${LUT_FILES[0]}")"
            else
                printf "  ║  %d) Apply LUT → 10-bit SDR Rec.709          ║\n" "$opt_num"
                printf "  ║     [%d LUT-uri gasite — selectie]            ║\n" "${#LUT_FILES[@]}"
            fi
            opt_num=$((opt_num + 1))
        fi
        opt_sdr=$opt_num
        printf "  ║  %d) Convert SDR (fara LUT) → 10-bit Rec.709 ║\n" "$opt_num"
        echo "  ║     (best-effort — LUT recomandat)           ║"
        opt_num=$((opt_num + 1))
        opt_hdr=$opt_num
        printf "  ║  %d) Convert HDR10 (fara LUT) → 10-bit       ║\n" "$opt_num"
        echo "  ║     BT.2020 / PQ (HDR10 static)              ║"
        opt_num=$((opt_num + 1))
        opt_preserve=$opt_num
        printf "  ║  %d) Preserve Log (compresie, pastreaza prof) ║\n" "$opt_num"
        opt_num=$((opt_num + 1))
        if [[ "$has_creative_lut" -eq 1 ]]; then
            opt_creative=$opt_num
            printf "  ║  %d) Creative LUT (look artistic)             ║\n" "$opt_num"
            printf "  ║     [%d creative LUT-uri gasite]              ║\n" "${#CREATIVE_LUT_FILES[@]}"
            opt_num=$((opt_num + 1))
        fi
        opt_copy=$opt_num
        printf "  ║  %d) Stream copy video                        ║\n" "$opt_num"
        opt_num=$((opt_num + 1))
        opt_skip=$opt_num
        printf "  ║  %d) Sari acest fisier                        ║\n" "$opt_num"
    fi
    echo "  ╚══════════════════════════════════════════════╝"

    local max_opt=$opt_skip
    local default_opt=$opt_sdr
    [[ "$has_lut" -eq 1 ]] && default_opt=$opt_lut
    read -p "  Alege 1-$max_opt [implicit: $default_opt]: " log_choice
    log_choice="${log_choice:-$default_opt}"

    # ── Process choice ───────────────────────────────────────────────
    if [[ "$log_choice" -eq "$opt_lut" ]] && [[ "$opt_lut" -gt 0 ]]; then
        # Apply LUT
        local selected_lut=""
        if [[ ${#LUT_FILES[@]} -eq 1 ]]; then
            selected_lut="${LUT_FILES[0]}"
        else
            echo ""
            echo "  LUT-uri disponibile:"
            local li=1
            for lf in "${LUT_FILES[@]}"; do
                printf "  %d) %s\n" "$li" "$(basename "$lf")"
                li=$((li + 1))
            done
            read -p "  Alege LUT [implicit: 1]: " lut_sel
            lut_sel="${lut_sel:-1}"
            if [[ "$lut_sel" =~ ^[0-9]+$ ]] && [ "$lut_sel" -ge 1 ] && [ "$lut_sel" -le ${#LUT_FILES[@]} ]; then
                selected_lut="${LUT_FILES[$((lut_sel - 1))]}"
            else
                selected_lut="${LUT_FILES[0]}"
            fi
        fi
        log "  LOG: Apply LUT — $(basename "$selected_lut")"
        if [[ "$encoder_type" == "x264" ]]; then
            LOG_VIDEO_FILTER="lut3d='$selected_lut',format=yuv420p"
            LOG_PIX_FMT="yuv420p"
        else
            LOG_VIDEO_FILTER="lut3d='$selected_lut',format=yuv420p10le"
            LOG_PIX_FMT="yuv420p10le"
        fi
        LOG_COLOR_FLAGS="-color_primaries bt709 -color_trc bt709 -colorspace bt709"
        return 0

    elif [[ "$log_choice" -eq "$opt_sdr" ]]; then
        # Convert SDR (no LUT) — best-effort tonemap
        log "  LOG: Convert SDR (best-effort, fara LUT)"
        if [[ "$encoder_type" == "x264" ]]; then
            LOG_VIDEO_FILTER="zscale=t=linear:npl=100,tonemap=hable:desat=0,zscale=t=bt709:p=bt709:m=bt709,format=yuv420p"
            LOG_PIX_FMT="yuv420p"
        else
            LOG_VIDEO_FILTER="zscale=t=linear:npl=100,tonemap=hable:desat=0,zscale=t=bt709:p=bt709:m=bt709,format=yuv420p10le"
            LOG_PIX_FMT="yuv420p10le"
        fi
        LOG_COLOR_FLAGS="-color_primaries bt709 -color_trc bt709 -colorspace bt709"
        return 0

    elif [[ "$log_choice" -eq "$opt_hdr" ]] && [[ "$opt_hdr" -gt 0 ]]; then
        # Convert HDR10 (no LUT)
        log "  LOG: Convert HDR10 static (fara LUT)"
        LOG_VIDEO_FILTER="zscale=t=linear:npl=100,zscale=t=smpte2084:p=bt2020:m=bt2020nc,format=yuv420p10le"
        LOG_PIX_FMT="yuv420p10le"
        LOG_COLOR_FLAGS="-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc"
        if [[ "$encoder_type" == "x265" ]]; then
            LOG_EXTRA_X265="hdr-opt=1:repeat-headers=1:hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc"
        fi
        return 0

    elif [[ "$log_choice" -eq "$opt_preserve" ]]; then
        # Preserve Log — compress without color change
        log "  LOG: Preserve Log (compresie fara schimbare culori)"
        if [[ "$encoder_type" == "x264" ]]; then
            LOG_PIX_FMT="yuv420p"
            log "  ⚠ x264 8-bit — gradatii pierdute. x265 recomandat."
        else
            LOG_PIX_FMT="yuv420p10le"
        fi
        # Preserve original color flags
        local orig_primaries orig_trc orig_space
        orig_primaries=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=color_primaries \
            -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1)
        orig_trc=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=color_transfer \
            -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1)
        orig_space=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=color_space \
            -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1)
        # Only add flags if values are meaningful
        local cf=""
        [[ -n "$orig_primaries" && "$orig_primaries" != "unknown" ]] && cf="$cf -color_primaries $orig_primaries"
        [[ -n "$orig_trc" && "$orig_trc" != "unknown" ]] && cf="$cf -color_trc $orig_trc"
        [[ -n "$orig_space" && "$orig_space" != "unknown" ]] && cf="$cf -colorspace $orig_space"
        LOG_COLOR_FLAGS="$cf"
        return 0

    elif [[ "$log_choice" -eq "$opt_creative" ]] && [[ "$opt_creative" -gt 0 ]]; then
        # Creative LUT — artistic look
        local selected_creative=""
        if [[ ${#CREATIVE_LUT_FILES[@]} -eq 1 ]]; then
            selected_creative="${CREATIVE_LUT_FILES[0]}"
        else
            echo ""
            echo "  Creative LUT-uri disponibile:"
            local ci=1
            for clf in "${CREATIVE_LUT_FILES[@]}"; do
                printf "  %d) %s\n" "$ci" "$(basename "$clf")"
                ci=$((ci + 1))
            done
            read -p "  Alege LUT [implicit: 1]: " creative_sel
            creative_sel="${creative_sel:-1}"
            if [[ "$creative_sel" =~ ^[0-9]+$ ]] && [ "$creative_sel" -ge 1 ] && [ "$creative_sel" -le ${#CREATIVE_LUT_FILES[@]} ]; then
                selected_creative="${CREATIVE_LUT_FILES[$((creative_sel - 1))]}"
            else
                selected_creative="${CREATIVE_LUT_FILES[0]}"
            fi
        fi
        log "  LOG: Creative LUT — $(basename "$selected_creative")"
        if [[ "$encoder_type" == "x264" ]]; then
            LOG_VIDEO_FILTER="lut3d='$selected_creative',format=yuv420p"
            LOG_PIX_FMT="yuv420p"
        else
            LOG_VIDEO_FILTER="lut3d='$selected_creative',format=yuv420p10le"
            LOG_PIX_FMT="yuv420p10le"
        fi
        LOG_COLOR_FLAGS="-color_primaries bt709 -color_trc bt709 -colorspace bt709"
        return 0

    elif [[ "$log_choice" -eq "$opt_copy" ]]; then
        log "  LOG: Stream copy video"
        return 97

    elif [[ "$log_choice" -eq "$opt_skip" ]]; then
        log "  LOG: Sarit de utilizator"
        return 98

    else
        log "  LOG: Optiune invalida — sarit"
        return 98
    fi
}

# Integreaza LOG filters in VIDEO_FILTER existent.
# Apelat dupa handle_log_dialog() cu return 0.
_apply_log_filters() {
    if [[ -n "${LOG_VIDEO_FILTER:-}" ]]; then
        if [[ -n "$VIDEO_FILTER" ]] && [[ "$VIDEO_FILTER" == *"-vf "* ]]; then
            # Prepend LOG filter before existing filters (LOG processing first)
            VIDEO_FILTER="${VIDEO_FILTER/-vf /-vf ${LOG_VIDEO_FILTER},}"
        else
            VIDEO_FILTER="-vf $LOG_VIDEO_FILTER"
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════════
# VIDSTAB + LOUDNORM
# ══════════════════════════════════════════════════════════════════════
vidstab_analyze() {
    local file="$1" trf_file; trf_file=$(mktemp --suffix=.trf)
    log "  Vidstab: Trecerea 1/2 — analiza miscare..."
    ffmpeg -threads "$THREADS" -i "$file" \
        -vf "vidstabdetect=shakiness=5:accuracy=15:result=$trf_file" \
        -f null - 2>>"$LOG_FILE"
    if [ $? -ne 0 ] || [ ! -f "$trf_file" ]; then
        log "  EROARE vidstab: analiza esuata"; rm -f "$trf_file"; echo ""; return
    fi
    log "  Vidstab: analiza completa"; echo "$trf_file"
}

vidstab_transform_filter() {
    echo "vidstabtransform=input=$1:smoothing=10:interpol=bicubic:optzoom=1:zoomspeed=0.25"
}

_apply_vidstab() {
    local file="$1"
    if [[ "$VIDEO_FILTER_PRESET" == "vidstab" ]]; then
        TRF_FILE=$(vidstab_analyze "$file")
        if [[ -n "$TRF_FILE" ]]; then
            local svf; svf=$(vidstab_transform_filter "$TRF_FILE")
            [[ -n "$VIDEO_FILTER" ]] && VIDEO_FILTER="${VIDEO_FILTER/-vf /-vf ${svf},}" || VIDEO_FILTER="-vf $svf"
            log "  Vidstab: Trecerea 2/2 — encodare cu stabilizare"
        fi
    fi
}

get_loudnorm_filter() {
    local file="$1"
    [[ "${AUDIO_NORMALIZE:-0}" != "1" ]] && { echo ""; return; }
    log "  Loudnorm: analiza volum EBU R128..."
    local analysis m_i m_tp m_lra m_thresh
    analysis=$(ffmpeg -i "$file" -af "loudnorm=I=-24:TP=-2.0:LRA=7:print_format=json" -f null - 2>&1 | grep -A 20 '"input_i"')
    m_i=$(echo "$analysis" | grep '"input_i"' | sed 's/.*: "//;s/".*//'); m_tp=$(echo "$analysis" | grep '"input_tp"' | sed 's/.*: "//;s/".*//')
    m_lra=$(echo "$analysis" | grep '"input_lra"' | sed 's/.*: "//;s/".*//'); m_thresh=$(echo "$analysis" | grep '"input_thresh"' | sed 's/.*: "//;s/".*//')
    if [[ -z "$m_i" ]]; then log "  Loudnorm: analiza esuata — skip"; echo ""; return; fi
    log "  Loudnorm: I=${m_i} LUFS | TP=${m_tp} dB | LRA=${m_lra}"
    echo "-af loudnorm=I=-24:TP=-2.0:LRA=7:measured_I=${m_i}:measured_TP=${m_tp}:measured_LRA=${m_lra}:measured_thresh=${m_thresh}:linear=true"
}

# ══════════════════════════════════════════════════════════════════════
# RESUME BATCH
# ══════════════════════════════════════════════════════════════════════
BATCH_PROGRESS_FILE="$OUTPUT_DIR/batch_progress.log"
batch_mark_done() {
    local tmp="${BATCH_PROGRESS_FILE}.tmp"
    [ -f "$BATCH_PROGRESS_FILE" ] && cp "$BATCH_PROGRESS_FILE" "$tmp" || touch "$tmp"
    echo "$1" >> "$tmp"
    mv -f "$tmp" "$BATCH_PROGRESS_FILE"
}
batch_is_done()       { [ -f "$BATCH_PROGRESS_FILE" ] && grep -qxF "$1" "$BATCH_PROGRESS_FILE" 2>/dev/null; }
batch_clear_progress() { rm -f "$BATCH_PROGRESS_FILE"; }

# ══════════════════════════════════════════════════════════════════════
# CRF ADAPTIV UNIFICAT
# ══════════════════════════════════════════════════════════════════════
get_adaptive_crf() {
    local enc="$1" w="$2"
    [[ -n "$CUSTOM_CRF" ]] && { echo "$CUSTOM_CRF"; return; }
    case "$enc" in
        x265) [ "$w" -ge 3840 ] && echo 22 || { [ "$w" -ge 1920 ] && echo 21 || echo 20; } ;;
        x264) [ "$w" -ge 3840 ] && echo 20 || { [ "$w" -ge 1920 ] && echo 19 || echo 18; } ;;
        av1)  [ "$w" -ge 3840 ] && echo 30 || { [ "$w" -ge 1920 ] && echo 28 || echo 26; } ;;
        *)    echo 22 ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════
# DRY-RUN REPORT
# ══════════════════════════════════════════════════════════════════════
dry_run_report() {
    local file="$1" output="$2" enc_label="$3" width="$4" dur="$5" src_fmt="$6"
    local orig_mb=$(( $(stat -c%s "$file") / 1024 / 1024 ))
    echo ""; echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║  DRY-RUN — $(basename "$file")"
    echo "  ╠══════════════════════════════════════════════════════╣"
    printf "  ║  Sursa    : %-42s║\n" "$src_fmt | ${width}px | ${orig_mb} MB"
    printf "  ║  Output   : %-42s║\n" "$(basename "$output")"
    printf "  ║  Encoder  : %-42s║\n" "$enc_label"
    if [[ "${ENCODE_MODE:-1}" == "2" ]]; then printf "  ║  Mode     : %-42s║\n" "VBR ${VBR_TARGET:-}"
    else printf "  ║  Mode     : %-42s║\n" "CRF ${CUSTOM_CRF:-auto}"; fi
    if [[ -n "${SCALE_WIDTH:-}" ]]; then printf "  ║  Resize   : %-42s║\n" "${width}px → ${SCALE_WIDTH}px"
    else printf "  ║  Resize   : %-42s║\n" "fara (original)"; fi
    if [[ -n "${TARGET_FPS:-}" ]]; then printf "  ║  FPS      : %-42s║\n" "→ ${TARGET_FPS} (${FPS_METHOD:-drop})"
    else printf "  ║  FPS      : %-42s║\n" "original"; fi
    printf "  ║  Filtru   : %-42s║\n" "${VIDEO_FILTER_PRESET:-fara}"
    printf "  ║  Audio    : %-42s║\n" "$AUDIO_CODEC_ARG"
    [[ "${AUDIO_NORMALIZE:-0}" == "1" ]] && printf "  ║  Loudnorm : %-42s║\n" "EBU R128 (-24 LUFS)"
    if [[ "$dur" =~ ^[0-9]+$ ]] && [ "$dur" -gt 0 ]; then
        local eb=4000000; [[ "$width" =~ ^[0-9]+$ ]] && [ "$width" -ge 3840 ] && eb=10000000
        [[ "$width" =~ ^[0-9]+$ ]] && [ "$width" -lt 1920 ] && eb=2000000
        printf "  ║  Estimare : %-42s║\n" "~$(( eb * dur / 8 / 1024 / 1024 )) MB | ~$((dur / 3 / 60))m"
        printf "  ║  Durata   : %-42s║\n" "$((dur/3600))h $((dur%3600/60))m $((dur%60))s"
    fi
    echo "  ╚══════════════════════════════════════════════════════╝"
}

# ══════════════════════════════════════════════════════════════════════
# BATCH SUMMARY DETALIAT
# ══════════════════════════════════════════════════════════════════════
print_batch_summary() {
    [ ${#BATCH_NAMES[@]} -le 1 ] && return
    log ""; log "── REZUMAT BATCH DETALIAT ──────────────────────────"
    local fi_idx=0 si_idx=0 td=0
    for i in "${!BATCH_NAMES[@]}"; do
        local t=${BATCH_TIMES[$i]}
        log "  ${BATCH_NAMES[$i]}: $((${BATCH_ORIG[$i]}/1024/1024))MB → $((${BATCH_NEW[$i]}/1024/1024))MB (${BATCH_RATIOS[$i]}%) | $((t/60))m $((t%60))s"
        [ "$t" -lt "${BATCH_TIMES[$fi_idx]}" ] && fi_idx=$i
        [ "$t" -gt "${BATCH_TIMES[$si_idx]}" ] && si_idx=$i
        local sd; sd=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 \
            "$INPUT_DIR/${BATCH_NAMES[$i]}" 2>/dev/null); sd=${sd%.*}
        [[ "$sd" =~ ^[0-9]+$ ]] && td=$((td+sd))
    done
    log "  ──────────────────────────────────────────────────"
    log "  Cel mai rapid : ${BATCH_NAMES[$fi_idx]} ($((${BATCH_TIMES[$fi_idx]}/60))m)"
    log "  Cel mai lent  : ${BATCH_NAMES[$si_idx]} ($((${BATCH_TIMES[$si_idx]}/60))m)"
    log "  Material total: $((td/3600))h $((td%3600/60))m procesat"
    # Afiseaza structura de foldere daca a fost pastrata
    if [[ "${PRESERVE_FOLDER_STRUCTURE:-0}" == "1" ]]; then
        log "  ──────────────────────────────────────────────────"
        log "  Structura foldere: PASTRATA"
        local output_dirs
        output_dirs=$(find "$OUTPUT_DIR" -type d 2>/dev/null | sort)
        local dir_count
        dir_count=$(echo "$output_dirs" | wc -l)
        log "  Foldere output create: $dir_count"
    fi
}

# ══════════════════════════════════════════════════════════════════════
# INTERACTIVE MODE — dialog dupa fiecare fisier encodat
# Permite schimbarea setarilor pentru fisierul urmator.
# ══════════════════════════════════════════════════════════════════════
_interactive_settings_dialog() {
    echo ""
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║  MOD INTERACTIV — Fisier urmator             ║"
    echo "  ╠══════════════════════════════════════════════╣"
    echo "  ║  Setari curente:                             ║"
    printf "  ║  Audio     : %-33s║\n" "$AUDIO_CODEC_ARG"
    printf "  ║  Container : %-33s║\n" "$CONTAINER"
    if [[ -n "${CUSTOM_CRF:-}" ]]; then
        printf "  ║  CRF       : %-33s║\n" "$CUSTOM_CRF"
    fi
    printf "  ║  Filtru    : %-33s║\n" "${VIDEO_FILTER_PRESET:-fara}"
    printf "  ║  Normalizare: %-32s║\n" "$([ "${AUDIO_NORMALIZE:-0}" == "1" ] && echo "EBU R128" || echo "dezactivata")"
    echo "  ╠══════════════════════════════════════════════╣"
    echo "  ║  1) Pastreaza setarile (continua) [implicit] ║"
    echo "  ║  2) Modifica setarile pentru urmatorul fisier ║"
    echo "  ║  3) Opreste batch-ul aici                    ║"
    echo "  ╚══════════════════════════════════════════════╝"
    read -p "  Alege 1-3 [implicit: 1]: " int_choice
    case "${int_choice:-1}" in
        2)
            echo ""
            # ── Audio ──────────────────────────────────────────────
            echo "  Audio curent: $AUDIO_CODEC_ARG"
            echo "  Schimbi? (Enter = pastreaza, sau introdu nou: aac:192k / opus:128k / eac3:224k / flac:8 / pcm:16le / copy)"
            read -p "  Audio nou: " new_audio
            [[ -n "$new_audio" ]] && { AUDIO_CODEC_ARG="$new_audio"; echo "  → Audio: $AUDIO_CODEC_ARG"; }

            # ── CRF (doar pentru encodere CRF) ─────────────────────
            if [[ "${ENCODER_TYPE:-}" != "dnxhr" ]] && [[ "${ENCODER_TYPE:-}" != "apv" ]] && [[ "${ENCODER_TYPE:-}" != "prores" ]]; then
                echo "  CRF curent: ${CUSTOM_CRF:-auto}"
                echo "  Schimbi? (Enter = pastreaza, sau introdu valoare)"
                read -p "  CRF nou: " new_crf
                if [[ -n "$new_crf" ]] && [[ "$new_crf" =~ ^[0-9]+$ ]]; then
                    CUSTOM_CRF="$new_crf"; echo "  → CRF: $CUSTOM_CRF"
                fi
            fi

            # ── Filtru video ───────────────────────────────────────
            echo "  Filtru curent: ${VIDEO_FILTER_PRESET:-fara}"
            echo "  Schimbi? (Enter = pastreaza, sau: denoise_light / denoise_medium / sharpen_light / deinterlace / fara)"
            read -p "  Filtru nou: " new_vf
            if [[ -n "$new_vf" ]]; then
                [[ "$new_vf" == "fara" ]] && VIDEO_FILTER_PRESET="" || VIDEO_FILTER_PRESET="$new_vf"
                echo "  → Filtru: ${VIDEO_FILTER_PRESET:-fara}"
            fi

            # ── Normalizare audio ──────────────────────────────────
            echo "  Normalizare: $([ "${AUDIO_NORMALIZE:-0}" == "1" ] && echo "activa" || echo "dezactivata")"
            echo "  Schimbi? (1=activa, 0=dezactiva, Enter=pastreaza)"
            read -p "  Normalizare: " new_norm
            [[ "$new_norm" == "1" ]] && { AUDIO_NORMALIZE="1"; echo "  → Normalizare: activa"; }
            [[ "$new_norm" == "0" ]] && { AUDIO_NORMALIZE="0"; echo "  → Normalizare: dezactivata"; }

            log "  [INTERACTIV] Setari modificate pentru fisierul urmator"
            ;;
        3)
            log "  [INTERACTIV] Batch oprit de utilizator dupa $TOTAL_DONE fisiere"
            BATCH_STOP=1
            ;;
        *) ;; # pastreaza tot
    esac
}

# ══════════════════════════════════════════════════════════════════════
# RUN_ENCODE_LOOP — BUCLA PRINCIPALA DE ENCODE
# ══════════════════════════════════════════════════════════════════════
# ── Batch Queue — editare ordine si excludere fisiere ────────────────
# Primeste: FILES (array global)
# Modifica: FILES (array global filtrat/reordonat)
show_batch_queue() {
    local total=${#FILES[@]}
    [ "$total" -eq 0 ] && return
    echo ""
    read -p "Editezi batch queue (ordine/excludere)? 1-Nu [impl]  2-Da: " bq_choice
    [[ "${bq_choice:-1}" != "2" ]] && return

    # included[i]=1 (inclus) sau 0 (exclus)
    local -a included=()
    for ((i=0; i<total; i++)); do included[$i]=1; done

    while true; do
        clear
        echo "╔══════════════════════════════════════════════════╗"
        echo "║  BATCH QUEUE — $total fisiere                      ║"
        echo "╠══════════════════════════════════════════════════╣"
        local incl_count=0
        for ((i=0; i<total; i++)); do
            local fn
            fn=$(basename "${FILES[$i]}")
            local sz_mb=$(( $(stat -c%s "${FILES[$i]}" 2>/dev/null || echo 0) / 1024 / 1024 ))
            if [[ "${included[$i]}" -eq 1 ]]; then
                printf "  %2d) [✓] %-32s (%d MB)\n" $((i+1)) "$fn" "$sz_mb"
                incl_count=$((incl_count+1))
            else
                printf "  %2d) [✗] %-32s (%d MB)\n" $((i+1)) "$fn" "$sz_mb"
            fi
        done
        echo "╠══════════════════════════════════════════════════╣"
        echo "  X<nr>     — exclude/include (ex: X3)"
        echo "  F<nr>     — muta pe prima pozitie (ex: F5)"
        echo "  M<de>,<la> — muta (ex: M3,1)"
        echo "  D<nr>     — doar acest fisier"
        echo "  Enter     — lanseaza ($incl_count fisiere)"
        echo "╚══════════════════════════════════════════════════╝"
        read -p "Comanda: " bq_cmd
        [[ -z "$bq_cmd" ]] && break
        bq_cmd="${bq_cmd^^}"  # uppercase

        if [[ "$bq_cmd" =~ ^X([0-9]+)$ ]]; then
            local xi=$(( ${BASH_REMATCH[1]} - 1 ))
            if [[ $xi -ge 0 && $xi -lt $total ]]; then
                included[$xi]=$(( 1 - included[$xi] ))
            fi
        elif [[ "$bq_cmd" =~ ^F([0-9]+)$ ]]; then
            local fi_idx=$(( ${BASH_REMATCH[1]} - 1 ))
            if [[ $fi_idx -gt 0 && $fi_idx -lt $total ]]; then
                local tmp_file="${FILES[$fi_idx]}"
                local tmp_incl="${included[$fi_idx]}"
                local -a new_files=("$tmp_file")
                local -a new_incl=("$tmp_incl")
                for ((j=0; j<total; j++)); do
                    [[ $j -eq $fi_idx ]] && continue
                    new_files+=("${FILES[$j]}")
                    new_incl+=("${included[$j]}")
                done
                FILES=("${new_files[@]}")
                included=("${new_incl[@]}")
            fi
        elif [[ "$bq_cmd" =~ ^M([0-9]+),([0-9]+)$ ]]; then
            local from_idx=$(( ${BASH_REMATCH[1]} - 1 ))
            local to_idx=$(( ${BASH_REMATCH[2]} - 1 ))
            if [[ $from_idx -ge 0 && $from_idx -lt $total && $to_idx -ge 0 && $to_idx -lt $total && $from_idx -ne $to_idx ]]; then
                local mv_file="${FILES[$from_idx]}"
                local mv_incl="${included[$from_idx]}"
                local -a tmp_f=() tmp_i=()
                for ((j=0; j<total; j++)); do
                    [[ $j -eq $from_idx ]] && continue
                    tmp_f+=("${FILES[$j]}"); tmp_i+=("${included[$j]}")
                done
                FILES=(); included=()
                for ((j=0; j<${#tmp_f[@]}; j++)); do
                    if [[ $j -eq $to_idx ]]; then
                        FILES+=("$mv_file"); included+=("$mv_incl")
                    fi
                    FILES+=("${tmp_f[$j]}"); included+=("${tmp_i[$j]}")
                done
                if [[ $to_idx -ge ${#tmp_f[@]} ]]; then
                    FILES+=("$mv_file"); included+=("$mv_incl")
                fi
                total=${#FILES[@]}
            fi
        elif [[ "$bq_cmd" =~ ^D([0-9]+)$ ]]; then
            local di=$(( ${BASH_REMATCH[1]} - 1 ))
            if [[ $di -ge 0 && $di -lt $total ]]; then
                for ((j=0; j<total; j++)); do
                    [[ $j -eq $di ]] && included[$j]=1 || included[$j]=0
                done
            fi
        fi
    done

    # Filter: keep only included files
    local -a filtered=()
    for ((i=0; i<total; i++)); do
        [[ "${included[$i]}" -eq 1 ]] && filtered+=("${FILES[$i]}")
    done
    FILES=("${filtered[@]}")
    echo "  Batch queue: ${#FILES[@]} fisiere selectate."
}

run_encode_loop() {
    echo "Activez wake lock..."; termux-wake-lock
    [ $? -ne 0 ] && echo "AVERTISMENT: termux-wake-lock a esuat."
    CONTAINER_FLAGS=$(get_container_flags)
    local enc_suffix enc_label
    enc_suffix=$(encoder_get_suffix); enc_label=$(encoder_get_label)

    echo "=======================================" | tee "$LOG_FILE"
    log "Encode inceput : $(date '+%Y-%m-%d %H:%M:%S')"
    log "Encoder        : $enc_label"
    log "Container      : $CONTAINER"
    log "CPU threads    : $THREADS"
    encoder_log_header
    log "Resize         : ${SCALE_WIDTH:-originala}"
    log "FPS            : ${TARGET_FPS:-original} ${FPS_METHOD:+($FPS_METHOD)}"
    log "Filtru video   : ${VIDEO_FILTER_PRESET:-fara}"
    log "Audio          : ${AUDIO_CODEC_ARG}"
    log "Normalizare    : ${AUDIO_NORMALIZE:-0}"
    log "======================================="

    # ── Pastrare structura foldere ────────────────────────────────────
    echo ""
    echo "Pastrezi structura de foldere din input? (d/n) [implicit: n]"
    echo "  d = Scanare recursiva, output pastreaza structura subfoldere"
    echo "  n = Toate fisierele in acelasi folder output"
    read -p "Alege: " folder_struct_choice
    PRESERVE_FOLDER_STRUCTURE=0
    if [[ "${folder_struct_choice,,}" == "d" ]]; then
        PRESERVE_FOLDER_STRUCTURE=1
        log "Structura foldere: PASTRATA (recursiv)"
        echo "  Scanez recursiv..."
        # Scanare recursiva cu find
        mapfile -t FILES < <(find "$INPUT_DIR" -type f \( \
            -iname "*.mp4" -o -iname "*.mov" -o -iname "*.mkv" -o \
            -iname "*.m2ts" -o -iname "*.mts" -o -iname "*.vob" -o \
            -iname "*.mxf" -o -iname "*.apv" \) 2>/dev/null | sort)
    else
        log "Structura foldere: FLAT (toate in output/)"
        shopt -s nullglob nocaseglob
        FILES=("$INPUT_DIR"/*.{mp4,mov,mkv,m2ts,mts,vob,mxf,apv})
        shopt -u nocaseglob nullglob
    fi
    TOTAL=${#FILES[@]}
    [ "$TOTAL" -eq 0 ] && { log "Nu am gasit fisiere video!"; termux-wake-unlock; exit 1; }

    # Afiseaza subfoldere gasite (doar daca recursiv)
    if [[ "$PRESERVE_FOLDER_STRUCTURE" == "1" ]]; then
        local subfolder_count
        subfolder_count=$(printf '%s\n' "${FILES[@]}" | xargs -I{} dirname {} | sort -u | wc -l)
        echo "  Gasite: $TOTAL fisiere in $subfolder_count foldere"
    fi

    # Batch Queue — editare ordine/excludere (optional)
    show_batch_queue
    TOTAL=${#FILES[@]}
    [ "$TOTAL" -eq 0 ] && { log "Toate fisierele au fost excluse!"; termux-wake-unlock; exit 1; }

    COUNT=0; TOTAL_SAVED=0; TOTAL_ERRORS=0; TOTAL_SKIPPED=0; TOTAL_DONE=0
    GRAND_START=$(date +%s); PROGRESS_FILE=""; BATCH_STOP=0
    TRIPLE_LAYER_MODE=0; DOVI_RPU_FILE=""
    ORIG_CONTAINER="$CONTAINER"; ORIG_CONTAINER_FLAGS="$CONTAINER_FLAGS"
    BATCH_NAMES=(); BATCH_TIMES=(); BATCH_ORIG=(); BATCH_NEW=(); BATCH_RATIOS=()

    for file in "${FILES[@]}"; do
        [ -f "$file" ] || continue
        [ "$BATCH_STOP" -eq 1 ] && { TOTAL_SKIPPED=$((TOTAL_SKIPPED+1)); continue; }
        CONTAINER="$ORIG_CONTAINER"; CONTAINER_FLAGS="$ORIG_CONTAINER_FLAGS"
        COUNT=$((COUNT + 1))
        filename=$(basename "$file"); name="${filename%.*}"
        ext_lower="${filename##*.}"; ext_lower="${ext_lower,,}"

        # Calculeaza output path (cu sau fara structura foldere)
        if [[ "$PRESERVE_FOLDER_STRUCTURE" == "1" ]]; then
            # Calculeaza calea relativa fata de INPUT_DIR
            local file_dir rel_path output_subdir
            file_dir=$(dirname "$file")
            rel_path="${file_dir#$INPUT_DIR}"
            rel_path="${rel_path#/}"  # Elimina slash initial daca exista
            if [[ -n "$rel_path" ]]; then
                output_subdir="$OUTPUT_DIR/$rel_path"
                mkdir -p "$output_subdir" 2>/dev/null
                output="$output_subdir/${name}${enc_suffix}.$CONTAINER"
            else
                output="$OUTPUT_DIR/${name}${enc_suffix}.$CONTAINER"
            fi
        else
            output="$OUTPUT_DIR/${name}${enc_suffix}.$CONTAINER"
        fi

        log ""; log "── Fisier $COUNT/$TOTAL: $filename"
        log "  Output: ${output#$OUTPUT_DIR/}"
        hint_source_format "$ext_lower"

        if [ -f "$output" ]; then
            OUT_SIZE=$(stat -c%s "$output")
            if [ "$OUT_SIZE" -gt 1048576 ]; then
                log "  Sarit (deja encodat, $(( OUT_SIZE/1024/1024 )) MB)"
                TOTAL_SKIPPED=$((TOTAL_SKIPPED+1)); continue
            else log "  Output incomplet — sterg si reincep"; rm -f "$output"; fi
        fi
        if batch_is_done "$filename"; then
            log "  Sarit (resume)"; TOTAL_SKIPPED=$((TOTAL_SKIPPED+1)); continue
        fi

        ORIGINAL_SIZE=$(stat -c%s "$file")
        handle_dji_full "$file" "$enc_suffix"
        detect_source_info "$file"
        CRF=$(get_adaptive_crf "${ENCODER_TYPE:-x265}" "$WIDTH")
        AUDIO_PARAMS=$(get_audio_params "$file")
        SUB_CODEC=$(get_subtitle_codec "$file")
        VIDEO_FILTER=$(build_video_filters "$WIDTH" "$SRC_FPS_DEC")
        [[ "$VIDEO_FILTER" == *"scale="* ]] && log "  Resize: ${WIDTH}px → ${SCALE_WIDTH}px"
        [[ "$VIDEO_FILTER" == *"-r "* ]] || [[ "$VIDEO_FILTER" == *"minterpolate"* ]] && \
            log "  FPS: ${SRC_FPS_DEC} → ${TARGET_FPS} ($FPS_METHOD)"

        # Encoder-specific: seteaza FFMPEG_CMD, face DV dialog, dry-run
        encoder_setup_file "$file"
        local setup_rc=$?
        if [ $setup_rc -eq 98 ]; then TOTAL_SKIPPED=$((TOTAL_SKIPPED+1)); continue
        elif [ $setup_rc -ne 0 ]; then TOTAL_ERRORS=$((TOTAL_ERRORS+1)); continue; fi

        if [[ "${DRY_RUN:-0}" == "1" ]]; then TOTAL_DONE=$((TOTAL_DONE+1)); continue; fi

        LOUDNORM_FILTER=""
        [[ "$AUDIO_NORMALIZE" == "1" ]] && [[ "$AUDIO_CODEC_ARG" != "copy" ]] && \
            LOUDNORM_FILTER=$(get_loudnorm_filter "$file")
        TRF_FILE=""; _apply_vidstab "$file"

        PROGRESS_FILE=$(mktemp); START_TIME=$(date +%s)
        # shellcheck disable=SC2086
        eval $FFMPEG_CMD $LOUDNORM_FILTER $SUB_CODEC -c:t copy \
            $CONTAINER_FLAGS -progress '"$PROGRESS_FILE"' -nostats '"$output"' '2>>"$LOG_FILE"' '&'
        FFMPEG_PID=$!; _show_progress "$FFMPEG_PID" "$PROGRESS_FILE" "$file"
        wait "$FFMPEG_PID"; FFMPEG_EXIT=$?
        [[ -n "${TRF_FILE:-}" ]] && rm -f "$TRF_FILE"; TRF_FILE=""
        if [ $FFMPEG_EXIT -ne 0 ]; then
            log "  EROARE encodare (cod $FFMPEG_EXIT)"
            [[ -n "${HDR10PLUS_JSON:-}" ]] && rm -f "$HDR10PLUS_JSON"; HDR10PLUS_JSON=""
            [[ -n "${DOVI_RPU_FILE:-}" ]] && rm -f "$DOVI_RPU_FILE"; DOVI_RPU_FILE=""
            TRIPLE_LAYER_MODE=0
            TOTAL_ERRORS=$((TOTAL_ERRORS+1)); rm -f "$output"; continue
        fi

        # ── Triple-layer: injecteaza DV RPU in HEVC output ───────────
        if [[ "${TRIPLE_LAYER_MODE:-0}" == "1" ]] && [[ -n "${DOVI_RPU_FILE:-}" ]]; then
            log "  Triple-layer: Injectez DV RPU in output..."
            local hevc_temp
            hevc_temp=$(mktemp --suffix=.hevc)
            # Extrage HEVC raw din container
            ffmpeg -v error -i "$output" -c:v copy -bsf:v hevc_mp4toannexb -f hevc "$hevc_temp" 2>>"$LOG_FILE"
            if [ $? -eq 0 ]; then
                local injected_temp
                injected_temp=$(mktemp --suffix=.hevc)
                if inject_dv_rpu "$hevc_temp" "$DOVI_RPU_FILE" "$injected_temp"; then
                    # Re-mux: HEVC cu DV + audio original din output
                    local final_temp
                    final_temp=$(mktemp --suffix=".$CONTAINER")
                    local cont_flags
                    cont_flags=$(get_container_flags)
                    ffmpeg -v error -i "$injected_temp" -i "$output" \
                        -map 0:v:0 -map 1:a -map 1:s? -map 1:t? \
                        -c copy $cont_flags "$final_temp" 2>>"$LOG_FILE"
                    if [ $? -eq 0 ] && [ -s "$final_temp" ]; then
                        mv -f "$final_temp" "$output"
                        log "  Triple-layer: DV Profile 8.1 + HDR10 + HDR10+ — OK"
                    else
                        log "  Triple-layer: Re-mux esuat — output fara DV (HDR10+ pastrat)"
                        rm -f "$final_temp"
                    fi
                else
                    log "  Triple-layer: Injectare RPU esuata — output fara DV (HDR10+ pastrat)"
                fi
                rm -f "$injected_temp"
            else
                log "  Triple-layer: Extractie HEVC esuata — output fara DV (HDR10+ pastrat)"
            fi
            rm -f "$hevc_temp"
        fi
        [[ -n "${HDR10PLUS_JSON:-}" ]] && rm -f "$HDR10PLUS_JSON"; HDR10PLUS_JSON=""
        [[ -n "${DOVI_RPU_FILE:-}" ]] && rm -f "$DOVI_RPU_FILE"; DOVI_RPU_FILE=""
        TRIPLE_LAYER_MODE=0

        NEW_SIZE=$(stat -c%s "$output" 2>/dev/null || echo 0)
        SAVED=$(( ORIGINAL_SIZE - NEW_SIZE )); [ $SAVED -lt 0 ] && SAVED=0
        TOTAL_SAVED=$(( TOTAL_SAVED+SAVED ))
        ENCODE_TIME=$(( $(date +%s) - START_TIME )); TOTAL_DONE=$((TOTAL_DONE+1))
        BATCH_NAMES+=("$filename"); BATCH_TIMES+=("$ENCODE_TIME")
        BATCH_ORIG+=("$ORIGINAL_SIZE"); BATCH_NEW+=("$NEW_SIZE")
        [ "$ORIGINAL_SIZE" -gt 0 ] && BATCH_RATIOS+=("$(awk "BEGIN{printf \"%.1f\", $NEW_SIZE * 100.0 / $ORIGINAL_SIZE}")") || BATCH_RATIOS+=("N/A")
        log "  Original: $(( ORIGINAL_SIZE/1024/1024 )) MB | Nou: $(( NEW_SIZE/1024/1024 )) MB | Salvat: $(( SAVED/1024/1024 )) MB"
        log "  Timp: $((ENCODE_TIME/60))m $((ENCODE_TIME%60))s"
        batch_mark_done "$filename"; log "────────────────────────────────────────"

        # ── MOD INTERACTIV: dialog dupa fiecare fisier ────────────────
        if [[ "${INTERACTIVE_MODE:-0}" == "1" ]] && [ "$COUNT" -lt "$TOTAL" ]; then
            _interactive_settings_dialog
        fi
    done

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo ""; log "======================================="
        log "DRY-RUN COMPLET — $enc_label [$ORIG_CONTAINER]"
        log "Fisiere analizate: $TOTAL_DONE | Sarite: $TOTAL_SKIPPED"
        log "======================================="; termux-wake-unlock 2>/dev/null; exit 0
    fi
    batch_clear_progress
    GRAND_ELAPSED=$(( $(date +%s) - GRAND_START )); echo ""
    log "======================================="
    log "STATISTICI FINALE — $enc_label [$ORIG_CONTAINER]"
    log "Procesate  : $TOTAL_DONE | Sarite: $TOTAL_SKIPPED | Erori: $TOTAL_ERRORS"
    log "Spatiu salvat: $(( TOTAL_SAVED/1024/1024 )) MB"
    log "Timp total : $((GRAND_ELAPSED/3600))h $((GRAND_ELAPSED%3600/60))m $((GRAND_ELAPSED%60))s"
    log "Incheiat   : $(date '+%Y-%m-%d %H:%M:%S')"
    print_batch_summary
    log "======================================="
    termux-notification --title "✅ Encode $enc_label finalizat" \
        --content "Procesate: $TOTAL_DONE | Erori: $TOTAL_ERRORS | Salvat: $(( TOTAL_SAVED/1024/1024 )) MB" \
        --icon video 2>/dev/null
    echo "Dezactivez wake lock..."; termux-wake-unlock
}
