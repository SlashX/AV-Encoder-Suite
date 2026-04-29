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
# v36: Folder temporar (Trim & Concat, feature-uri viitoare) — creat lazy la prima folosire
AV_TEMP_DIR="/storage/emulated/0/Media/Temp"
ensure_temp_dir() { mkdir -p "$AV_TEMP_DIR" 2>/dev/null; }

# v36/v37: Scan foldere reziduale (trim_*, concat_*, pipeline_*, preview_*) in $AV_TEMP_DIR
# Chemat la intrarea in submeniul Trim & Concat.
tc_scan_leftover_temp() {
    [[ ! -d "$AV_TEMP_DIR" ]] && return 0
    local leftover=()
    local d
    for d in "$AV_TEMP_DIR"/trim_* "$AV_TEMP_DIR"/concat_* "$AV_TEMP_DIR"/pipeline_* "$AV_TEMP_DIR"/preview_*; do
        [[ -d "$d" ]] && leftover+=("$d")
    done
    (( ${#leftover[@]} == 0 )) && return 0

    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  Temp — foldere reziduale detectate          ║"
    echo "╠══════════════════════════════════════════════╣"
    local now; now=$(date +%s)
    for d in "${leftover[@]}"; do
        local mt; mt=$(stat -c %Y "$d" 2>/dev/null || echo 0)
        local age_h=$(( (now - mt) / 3600 ))
        local sz; sz=$(du -sm "$d" 2>/dev/null | cut -f1); [[ -z "$sz" ]] && sz=0
        local age_str="${age_h}h"
        (( age_h >= 24 )) && age_str="$((age_h/24))z"
        printf "║  %-30s %4sMB  %s\n" "$(basename "$d" | cut -c1-30)" "$sz" "$age_str"
    done
    echo "╚══════════════════════════════════════════════╝"
    echo "  1) Pastreaza toate"
    echo "  2) Sterge pe cele > 24h [default]"
    echo "  3) Sterge toate"
    read -p "Alege 1-3: " tc_ch
    [[ -z "$tc_ch" ]] && tc_ch=2
    case "$tc_ch" in
        2) for d in "${leftover[@]}"; do
               local mt; mt=$(stat -c %Y "$d" 2>/dev/null || echo 0)
               if (( (now - mt) >= 86400 )); then
                   rm -rf "$d" && echo "  sters: $(basename "$d")"
               fi
           done ;;
        3) for d in "${leftover[@]}"; do rm -rf "$d"; done
           echo "  toate sterse" ;;
        *) : ;;
    esac
}

# v36: Detecteaza HDR10 (smpte2084) / HLG (arib-std-b67) pe un set de fisiere.
# Return 0 daca cel putin unul e HDR, 1 altfel.
tc_check_hdr_files() {
    local f ct
    for f in "$@"; do
        ct=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer \
            -of default=nw=1:nk=1 "$f" 2>/dev/null)
        if [[ "$ct" == "smpte2084" || "$ct" == "arib-std-b67" ]]; then return 0; fi
    done
    return 1
}

# v37: Detecteaza modul HDR pentru un set de fisiere.
# Return: "sdr" | "hdr10" | "hdr10plus" | "hlg" | "dv" | "mixed"
detect_pipeline_hdr_mode() {
    local has_hdr10=0 has_hlg=0 has_dv=0 has_sdr=0 has_hdr10plus=0
    local f ct sd
    for f in "$@"; do
        ct=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer \
            -of default=nw=1:nk=1 "$f" 2>/dev/null)
        sd=$(ffprobe -v error -select_streams v:0 -read_intervals "%+#1" \
            -show_entries frame=side_data_list -of default=nw=1 "$f" 2>/dev/null)
        case "$ct" in
            smpte2084) has_hdr10=1 ;;
            arib-std-b67) has_hlg=1 ;;
            *) has_sdr=1 ;;
        esac
        echo "$sd" | grep -qi "dolby vision\|dovi" && has_dv=1
        echo "$sd" | grep -qi "hdr dynamic metadata\|hdr10+" && has_hdr10plus=1
    done
    if (( has_dv == 1 )); then echo "dv"; return; fi
    if (( has_sdr == 1 )) && (( has_hdr10 == 1 || has_hlg == 1 )); then echo "mixed"; return; fi
    if (( has_hdr10plus == 1 )); then echo "hdr10plus"; return; fi
    if (( has_hdr10 == 1 )); then echo "hdr10"; return; fi
    if (( has_hlg == 1 )); then echo "hlg"; return; fi
    echo "sdr"
}

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

# Seteaza: MAP_FLAGS, IS_DJI, KEEP_DJMD, KEEP_DBGI, KEEP_TMCD; poate modifica CONTAINER/output
handle_dji_full() {
    local file="$1" out_suffix="$2"
    local dji_info
    dji_info=$(detect_dji_tracks "$file")
    IS_DJI=0; KEEP_DJMD=0; KEEP_DBGI=0; KEEP_TMCD=0

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
            KEEP_DJMD=$(echo "$dji_result" | grep -o 'KEEP_DJMD=[0-9]' | cut -d= -f2)
            [ -z "$KEEP_DJMD" ] && KEEP_DJMD=1
            KEEP_DBGI=$(echo "$dji_result" | grep -o 'KEEP_DBGI=[0-9]' | cut -d= -f2)
            [ -z "$KEEP_DBGI" ] && KEEP_DBGI=0
            KEEP_TMCD=$(echo "$dji_result" | grep -o 'KEEP_TMCD=[0-9]' | cut -d= -f2)
            [ -z "$KEEP_TMCD" ] && KEEP_TMCD=1
            switch_mkv=$(echo "$dji_result" | grep -o 'SWITCH_MKV=[0-9]' | cut -d= -f2)
            if [ "${switch_mkv:-0}" -eq 1 ]; then
                CONTAINER="mkv"; CONTAINER_FLAGS=""
                output="$OUTPUT_DIR/${name}${out_suffix}.mkv"
                log "  Container schimbat la mkv (track-uri DJI pastrate)"
            fi
            log "  DJI tracks — djmd:$([ "$KEEP_DJMD" -eq 1 ] && echo 'da' || echo 'nu') dbgi:$([ "$KEEP_DBGI" -eq 1 ] && echo 'da' || echo 'nu') tmcd:$([ "$KEEP_TMCD" -eq 1 ] && echo 'da' || echo 'nu')"
            MAP_FLAGS=$(build_map_flags "$file" "$KEEP_DJMD" "$KEEP_DBGI" "$KEEP_TMCD" "$dji_info")
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
    if [ "$is_dji" -eq 0 ]; then echo "KEEP_DJMD=0|KEEP_DBGI=0|KEEP_TMCD=0|IS_DJI=0|SWITCH_MKV=0"; return; fi
    {
        echo ""; echo "  ╔══════════════════════════════════════════════╗"
        echo "  ║  FISIER DJI DETECTAT                         ║"
        echo "  ╠══════════════════════════════════════════════╣"
        [ "$has_djmd"  -eq 1 ] && echo "  ║  ✅ djmd — GPS, telemetrie, setari camera    ║"
        [ "$has_tc"    -eq 1 ] && echo "  ║  ✅ tmcd — Timecode sincronizare              ║"
        [ "$has_dbgi"  -eq 1 ] && echo "  ║  ⚠️  dbgi — date debug DJI (~295 MB)          ║"
        [ "$has_cover" -eq 1 ] && echo "  ║  ℹ️  Cover JPEG — nu se copiaza (re-encode)   ║"
    } >/dev/tty
    local keep_djmd=1 keep_dbgi=0 keep_tmcd=1 switch_mkv=0
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
        else
            echo "KEEP_DJMD=0|KEEP_DBGI=0|KEEP_TMCD=0|IS_DJI=1|SWITCH_MKV=0"; return
        fi
    fi
    # MKV: dialog selectie track-uri DJI in output
    if [ "$has_dbgi" -eq 1 ]; then
        {
            echo "  ╠══════════════════════════════════════════════╣"
            echo "  ║  Track-uri DJI in output:                    ║"
            echo "  ║  1) Pastreaza tot                             ║"
            echo "  ║  2) Fara debug (dbgi ~295 MB) [recomandat]    ║"
            echo "  ║  3) Fara GPS/locatie (elimina djmd + dbgi)    ║"
            echo "  ║  4) Elimina tot (fara track-uri DJI)          ║"
            echo "  ╚══════════════════════════════════════════════╝"
        } >/dev/tty
        local dji_ch; read -p "  Alege 1-4 [implicit: 2]: " dji_ch </dev/tty
        case "${dji_ch:-2}" in
            1) keep_djmd=1; keep_dbgi=1; keep_tmcd=1 ;;
            3) keep_djmd=0; keep_dbgi=0; keep_tmcd=1 ;;
            4) keep_djmd=0; keep_dbgi=0; keep_tmcd=0 ;;
            *) keep_djmd=1; keep_dbgi=0; keep_tmcd=1 ;;
        esac
    else
        {
            echo "  ╠══════════════════════════════════════════════╣"
            echo "  ║  Track-uri DJI in output:                    ║"
            echo "  ║  1) Pastreaza tot [implicit]                  ║"
            echo "  ║  2) Fara GPS/locatie (elimina djmd)           ║"
            echo "  ║  3) Elimina tot (fara track-uri DJI)          ║"
            echo "  ╚══════════════════════════════════════════════╝"
        } >/dev/tty
        local dji_ch; read -p "  Alege 1-3 [implicit: 1]: " dji_ch </dev/tty
        case "${dji_ch:-1}" in
            2) keep_djmd=0; keep_dbgi=0; keep_tmcd=1 ;;
            3) keep_djmd=0; keep_dbgi=0; keep_tmcd=0 ;;
            *) keep_djmd=1; keep_dbgi=0; keep_tmcd=1 ;;
        esac
    fi
    echo "KEEP_DJMD=${keep_djmd}|KEEP_DBGI=${keep_dbgi}|KEEP_TMCD=${keep_tmcd}|IS_DJI=1|SWITCH_MKV=${switch_mkv}"
}

build_map_flags() {
    local file="$1" keep_djmd="$2" keep_dbgi="$3" keep_tmcd="$4" dji_info="$5"
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
            echo "$tag" | grep -qi "djmd" && [ "$keep_djmd" -eq 1 ] && maps="$maps -map 0:$idx"
            echo "$tag" | grep -qi "dbgi" && [ "$keep_dbgi" -eq 1 ] && maps="$maps -map 0:$idx"
            echo "$tag" | grep -qi "tmcd" && [ "$keep_tmcd" -eq 1 ] && maps="$maps -map 0:$idx"
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
            fpid=$!; _show_progress "$fpid" "$pf" "$file" "DV stream copy"; wait "$fpid"
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
    local label="${4:-Progres}"   # v38: label opțional pentru context (encoder name etc.)
    local dur_p st_p
    dur_p=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$src_file" 2>/dev/null)
    dur_p=${dur_p%.*}; [[ ! "$dur_p" =~ ^[0-9]+$ ]] && dur_p=0
    st_p=$(date +%s); PROGRESS_FILE="$prog_file"
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        local otms=$(grep "^out_time_ms=" "$prog_file" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' ')
        if ! [[ "$otms" =~ ^[0-9]+$ ]] || [ "$otms" -le 0 ]; then
            echo -ne "\r  ${label}: se initializeaza...                          "; continue
        fi
        local ot=$((otms / 1000000)); [ "$ot" -lt 0 ] && ot=0
        local el=$(( $(date +%s) - st_p )); [ "$el" -le 0 ] && el=1
        local pct=$(( dur_p > 0 ? ot * 100 / dur_p : 0 )); [ "$pct" -gt 100 ] && pct=100
        local rfps; rfps=$(grep "^fps=" "$prog_file" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' ')
        if [[ "$rfps" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk "BEGIN{exit !($rfps > 0)}"; then :
        else [ "$ot" -gt 0 ] && rfps="$(awk "BEGIN{printf \"%.1f\", $ot / $el}")x" || rfps="0.0x"; fi
        local eta=0
        [ "$ot" -gt 0 ] && [ "$dur_p" -gt "$ot" ] && eta=$(( el * (dur_p - ot) / ot ))
        printf "\r  %s: %3d%% | FPS: %s | ETA: %02d:%02d:%02d   " \
            "$label" "$pct" "$rfps" $((eta/3600)) $(((eta%3600)/60)) $((eta%60))
    done
    rm -f "$prog_file"; PROGRESS_FILE=""; echo ""
}

# ──────────────────────────────────────────────────────────────────────
# v37: Reusable helper — rulează ffmpeg cu progress bar + label custom.
# Folosit de Trim/Concat/Pipeline. Acceptă durata totală explicit
# (necesar când sursa nu e un singur fișier, ex: pipeline concat).
# Args:
#   $1 = label (ex "Pass 3/3", "Trim seg1")
#   $2 = total_duration_seconds (0 = "se initializează" permanent)
#   $@ = ffmpeg args (fără -progress / -nostats — sunt adăugate automat)
# Return: exit code ffmpeg
# ──────────────────────────────────────────────────────────────────────
run_ffmpeg_with_progress() {
    local label="$1"; shift
    local total_s="$1"; shift
    local pf ef; pf=$(mktemp); ef=$(mktemp)
    local prev_pf="${PROGRESS_FILE:-}"
    PROGRESS_FILE="$pf"
    ffmpeg -progress "$pf" -nostats "$@" 2>"$ef" &
    local pid=$!
    _show_progress_labeled "$pid" "$pf" "$total_s" "$label"
    wait "$pid"
    local rc=$?
    if (( rc != 0 )); then
        echo "  ⚠ ffmpeg exit code $rc — ultimele linii stderr:"
        tail -10 "$ef" 2>/dev/null | sed 's/^/    /'
    fi
    rm -f "$pf" "$ef"
    PROGRESS_FILE="$prev_pf"
    return $rc
}

# Watcher paralel pentru run_ffmpeg_with_progress (durata explicită, nu ffprobe)
_show_progress_labeled() {
    local pid=$1 prog_file=$2 total_s=$3 label=$4
    local st_p; st_p=$(date +%s)
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        local otms; otms=$(grep "^out_time_ms=" "$prog_file" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' ')
        if ! [[ "$otms" =~ ^[0-9]+$ ]] || [ "$otms" -le 0 ]; then
            printf "\r  %s: se initializeaza...                              " "$label"
            continue
        fi
        local ot=$((otms / 1000000)); [ "$ot" -lt 0 ] && ot=0
        local el=$(( $(date +%s) - st_p )); [ "$el" -le 0 ] && el=1
        local pct=0
        (( total_s > 0 )) && pct=$(( ot * 100 / total_s ))
        [ "$pct" -gt 100 ] && pct=100
        local rfps; rfps=$(grep "^fps=" "$prog_file" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' ')
        if [[ "$rfps" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk "BEGIN{exit !($rfps > 0)}"; then :
        else [ "$ot" -gt 0 ] && rfps="$(awk "BEGIN{printf \"%.1fx\", $ot / $el}")" || rfps="0.0x"; fi
        local eta=0
        [ "$ot" -gt 0 ] && [ "$total_s" -gt "$ot" ] && eta=$(( el * (total_s - ot) / ot ))
        printf "\r  %s: %3d%% | FPS: %s | ETA: %02d:%02d:%02d       " \
            "$label" "$pct" "$rfps" $((eta/3600)) $(((eta%3600)/60)) $((eta%60))
    done
    echo ""
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
    sc_pid=$!; _show_progress "$sc_pid" "$sc_pf" "$file" "Stream copy"; wait "$sc_pid"
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
# v38: MEDIACODEC HDR DIALOG — uniformizat pentru DV / HDR10+ / HDR10
# Apelat DOAR cand userul a selectat MediaCodec ca encoder.
# Param: source_type = dv|hdr10plus|hdr10 ; dv_profile (optional)
# Set MC_HDR_MODE global:
#   sw_full     — fallback SW cu preservare completa (DV native, HDR10+ dynamic)
#   sw_degraded — fallback SW degradat (DV→HDR10 BL, HDR10+→HDR10 static)
#   hw_repair   — MediaCodec 10-bit + signaling repair via hevc_metadata bsf
#   hw_sdr      — MediaCodec SDR tonemap 8-bit (proxy)
# Override prin profile field MEDIACODEC_HDR_POLICY=sw_full|sw_degraded|hw_repair|hw_sdr|skip
# Return: 0 = proceed cu MC_HDR_MODE setat | 98 = skip
# ══════════════════════════════════════════════════════════════════════
show_hdr_mediacodec_dialog() {
    local source_type="$1" dv_profile="${2:-}"
    MC_HDR_MODE=""

    # Profile bypass
    if [[ -n "${MEDIACODEC_HDR_POLICY:-}" ]]; then
        case "$MEDIACODEC_HDR_POLICY" in
            sw_full|sw_degraded|hw_repair|hw_sdr)
                MC_HDR_MODE="$MEDIACODEC_HDR_POLICY"
                log "  MediaCodec HDR policy din profil: $MC_HDR_MODE"
                return 0 ;;
            skip)
                log "  MediaCodec HDR policy din profil: skip"
                return 98 ;;
        esac
    fi

    echo ""
    echo "  ╔══════════════════════════════════════════════════════╗"
    case "$source_type" in
        dv)
            echo "  ║  ⚠ Sursa este Dolby Vision (profil ${dv_profile:-?})"
            echo "  ║  MediaCodec nu poate produce DV. Optiuni:"
            echo "  ╠══════════════════════════════════════════════════════╣"
            echo "  ║  1) SW libx265 — pastreaza DV complet (recomandat)"
            echo "  ║  2) SW libx265 — strip DV, pastreaza HDR10 BL"
            echo "  ║  3) MediaCodec — strip DV → HDR10 10-bit + repair"
            echo "  ║  4) MediaCodec — strip DV → SDR tonemap 8-bit (proxy)"
            echo "  ║  5) Skip fisier"
            echo "  ╚══════════════════════════════════════════════════════╝"
            read -p "  Alege 1-5 [implicit: 1]: " _mc_ch
            case "${_mc_ch:-1}" in
                2) MC_HDR_MODE="sw_degraded"; log "  Ales: SW libx265 strip DV → HDR10 BL" ;;
                3) MC_HDR_MODE="hw_repair";   log "  Ales: MediaCodec HDR10 10-bit + signaling repair" ;;
                4) MC_HDR_MODE="hw_sdr";      log "  Ales: MediaCodec SDR tonemap 8-bit (proxy)" ;;
                5) log "  Sarit de utilizator"; return 98 ;;
                *) MC_HDR_MODE="sw_full";     log "  Ales: SW libx265 cu DV complet" ;;
            esac
            ;;
        hdr10plus)
            echo "  ║  ⚠ Sursa este HDR10+ (cu dynamic metadata)"
            echo "  ║  MediaCodec nu transmite dynamic metadata. Optiuni:"
            echo "  ╠══════════════════════════════════════════════════════╣"
            echo "  ║  1) SW libx265 — pastreaza HDR10+ complet (recomandat)"
            echo "  ║  2) SW libx265 — encode ca HDR10 static (drop dynamic)"
            echo "  ║  3) MediaCodec — HDR10 10-bit + repair (drop dynamic)"
            echo "  ║  4) MediaCodec — SDR tonemap 8-bit (proxy)"
            echo "  ║  5) Skip fisier"
            echo "  ╚══════════════════════════════════════════════════════╝"
            read -p "  Alege 1-5 [implicit: 1]: " _mc_ch
            case "${_mc_ch:-1}" in
                2) MC_HDR_MODE="sw_degraded"; log "  Ales: SW libx265 HDR10 static (drop dynamic)" ;;
                3) MC_HDR_MODE="hw_repair";   log "  Ales: MediaCodec HDR10 10-bit + signaling repair" ;;
                4) MC_HDR_MODE="hw_sdr";      log "  Ales: MediaCodec SDR tonemap 8-bit (proxy)" ;;
                5) log "  Sarit de utilizator"; return 98 ;;
                *) MC_HDR_MODE="sw_full";     log "  Ales: SW libx265 cu HDR10+ complet" ;;
            esac
            ;;
        hdr10|*)
            echo "  ║  ⚠ Sursa este HDR10"
            echo "  ║  MediaCodec necesita signaling repair. Optiuni:"
            echo "  ╠══════════════════════════════════════════════════════╣"
            echo "  ║  1) SW libx265 — HDR10 nativ (recomandat)"
            echo "  ║  2) MediaCodec — HDR10 10-bit + signaling repair"
            echo "  ║  3) MediaCodec — SDR tonemap 8-bit (proxy)"
            echo "  ║  4) Skip fisier"
            echo "  ╚══════════════════════════════════════════════════════╝"
            read -p "  Alege 1-4 [implicit: 1]: " _mc_ch
            case "${_mc_ch:-1}" in
                2) MC_HDR_MODE="hw_repair"; log "  Ales: MediaCodec HDR10 10-bit + signaling repair" ;;
                3) MC_HDR_MODE="hw_sdr";    log "  Ales: MediaCodec SDR tonemap 8-bit (proxy)" ;;
                4) log "  Sarit de utilizator"; return 98 ;;
                *) MC_HDR_MODE="sw_full";   log "  Ales: SW libx265 HDR10 nativ" ;;
            esac
            ;;
    esac
    return 0
}

# ══════════════════════════════════════════════════════════════════════
# v38: HDR10 SIGNALING REPAIR — post-encode bsf hevc_metadata
# Repara SEI mastering_display + max_cll/max_fall pierdute de hevc_mediacodec.
# Args: $1 = encoded_file (hevc/mp4 in-place fix via temp)
#       $2 = master_display string (optional, ex: "G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,1)")
#       $3 = max_cll string (optional, ex: "1000,400")
# Daca $2/$3 lipsesc, citeste din source via ffprobe (pasat prin env: MC_REPAIR_SRC)
# Return: 0 OK | non-zero error
# ══════════════════════════════════════════════════════════════════════
repair_hdr10_signaling() {
    local encoded="$1" md_str="${2:-}" cll_str="${3:-}"
    [[ ! -f "$encoded" ]] && return 1

    # Daca lipsesc, extrage din sursa originala
    if [[ -z "$md_str" || -z "$cll_str" ]] && [[ -n "${MC_REPAIR_SRC:-}" && -f "$MC_REPAIR_SRC" ]]; then
        local sd_json
        sd_json=$(ffprobe -v error -select_streams v:0 -read_intervals "%+#1" \
            -show_frames -show_entries frame_side_data_list \
            -of default=nw=1 "$MC_REPAIR_SRC" 2>/dev/null)
        # Mastering display: format ffmpeg "G(x,y)B(x,y)R(x,y)WP(x,y)L(max,min)"
        if [[ -z "$md_str" ]]; then
            local r_x r_y g_x g_y b_x b_y wp_x wp_y l_max l_min
            r_x=$(echo "$sd_json" | grep -oP "red_x=\K[0-9/]+" | head -1)
            r_y=$(echo "$sd_json" | grep -oP "red_y=\K[0-9/]+" | head -1)
            g_x=$(echo "$sd_json" | grep -oP "green_x=\K[0-9/]+" | head -1)
            g_y=$(echo "$sd_json" | grep -oP "green_y=\K[0-9/]+" | head -1)
            b_x=$(echo "$sd_json" | grep -oP "blue_x=\K[0-9/]+" | head -1)
            b_y=$(echo "$sd_json" | grep -oP "blue_y=\K[0-9/]+" | head -1)
            wp_x=$(echo "$sd_json" | grep -oP "white_point_x=\K[0-9/]+" | head -1)
            wp_y=$(echo "$sd_json" | grep -oP "white_point_y=\K[0-9/]+" | head -1)
            l_max=$(echo "$sd_json" | grep -oP "max_luminance=\K[0-9/]+" | head -1)
            l_min=$(echo "$sd_json" | grep -oP "min_luminance=\K[0-9/]+" | head -1)
            if [[ -n "$g_x" && -n "$r_x" && -n "$wp_x" && -n "$l_max" ]]; then
                # Convert ratios numerator/denominator → integer scaled (50000 pentru chroma, 10000 pentru luminance)
                md_str="G($(awk -F/ '{printf "%d", ($1*50000)/$2}' <<< "$g_x"),$(awk -F/ '{printf "%d", ($1*50000)/$2}' <<< "$g_y"))B($(awk -F/ '{printf "%d", ($1*50000)/$2}' <<< "$b_x"),$(awk -F/ '{printf "%d", ($1*50000)/$2}' <<< "$b_y"))R($(awk -F/ '{printf "%d", ($1*50000)/$2}' <<< "$r_x"),$(awk -F/ '{printf "%d", ($1*50000)/$2}' <<< "$r_y"))WP($(awk -F/ '{printf "%d", ($1*50000)/$2}' <<< "$wp_x"),$(awk -F/ '{printf "%d", ($1*50000)/$2}' <<< "$wp_y"))L($(awk -F/ '{printf "%d", ($1*10000)/$2}' <<< "$l_max"),$(awk -F/ '{printf "%d", ($1*10000)/$2}' <<< "$l_min"))"
            fi
        fi
        if [[ -z "$cll_str" ]]; then
            local mcll mfall
            mcll=$(echo "$sd_json" | grep -oP "max_content=\K[0-9]+" | head -1)
            mfall=$(echo "$sd_json" | grep -oP "max_average=\K[0-9]+" | head -1)
            [[ -n "$mcll" && -n "$mfall" ]] && cll_str="${mcll},${mfall}"
        fi
    fi

    # Defaults conservative daca tot lipsesc — Rec.2020 + 1000/400 nits
    [[ -z "$md_str" ]] && md_str="G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)"
    [[ -z "$cll_str" ]] && cll_str="1000,400"

    local tmp_out
    tmp_out=$(mktemp --suffix=".${encoded##*.}")
    log "  HDR10 signaling repair: injectez mastering_display + max_cll..."
    ffmpeg -v error -i "$encoded" -c copy \
        -bsf:v "hevc_metadata=mastering_display=${md_str}:max_content=${cll_str%,*}:max_average=${cll_str#*,}:colour_primaries=9:transfer_characteristics=16:matrix_coefficients=9" \
        -movflags +faststart "$tmp_out" 2>>"${LOG_FILE:-/dev/null}"
    local rc=$?
    if [ $rc -eq 0 ] && [ -s "$tmp_out" ]; then
        mv -f "$tmp_out" "$encoded"
        log "  HDR10 signaling repair OK"
        return 0
    fi
    rm -f "$tmp_out"
    log "  HDR10 signaling repair FAILED (rc=$rc) — output ramane fara SEI HDR"
    return 1
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
# v38: ADAPTIVE BITRATE pentru MediaCodec (nu suporta CRF, doar VBR/CBR)
# Returneaza bitrate-ul tinta (in kbps) per encoder + rezolutie
# Mapping aproximativ echivalent calitate cu CRF-urile din get_adaptive_crf
# ══════════════════════════════════════════════════════════════════════
get_adaptive_bitrate() {
    local enc="$1" w="$2"
    case "$enc" in
        hevc_mediacodec)
            [ "$w" -ge 3840 ] && echo 25000 || \
            { [ "$w" -ge 2560 ] && echo 14000 || \
              { [ "$w" -ge 1920 ] && echo 8000 || \
                { [ "$w" -ge 1280 ] && echo 4500 || echo 2500; }; }; }
            ;;
        h264_mediacodec)
            [ "$w" -ge 3840 ] && echo 35000 || \
            { [ "$w" -ge 2560 ] && echo 20000 || \
              { [ "$w" -ge 1920 ] && echo 12000 || \
                { [ "$w" -ge 1280 ] && echo 6500 || echo 3500; }; }; }
            ;;
        av1_mediacodec)
            [ "$w" -ge 3840 ] && echo 18000 || \
            { [ "$w" -ge 2560 ] && echo 10000 || \
              { [ "$w" -ge 1920 ] && echo 5500 || \
                { [ "$w" -ge 1280 ] && echo 3000 || echo 1800; }; }; }
            ;;
        *) echo 8000 ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════
# v38: MEDIACODEC DETECTION (Termux/Android)
# Set vars globale: MC_AVAILABLE, MC_ENCODERS (h264/hevc/av1 list),
#   MC_SOC_VENDOR, MC_SOC_MODEL, MC_ANDROID_VER, MC_SOC_VERIFIED,
#   MC_CAP_HEVC10, MC_CAP_AV1
# ══════════════════════════════════════════════════════════════════════
detect_mediacodec_caps() {
    MC_AVAILABLE=0
    MC_ENCODERS=""
    MC_SOC_VENDOR=""
    MC_SOC_MODEL=""
    MC_ANDROID_VER=""
    MC_SOC_VERIFIED=0
    MC_CAP_HEVC10=0
    MC_CAP_AV1=0

    # Platform gate: Termux/Android necesita getprop pentru SoC info; ffmpeg pentru encoder check
    command -v getprop >/dev/null 2>&1 || return 1
    command -v ffmpeg  >/dev/null 2>&1 || return 1

    # Binary check: ce encodere mediacodec are ffmpeg-ul
    local enc_list
    enc_list=$(ffmpeg -hide_banner -encoders 2>/dev/null | grep -E "(h264|hevc|av1)_mediacodec" | awk '{print $2}')
    [[ -z "$enc_list" ]] && return 1

    MC_ENCODERS="$enc_list"
    MC_AVAILABLE=1

    # SoC info
    MC_SOC_VENDOR=$(getprop ro.soc.manufacturer 2>/dev/null)
    MC_SOC_MODEL=$(getprop ro.soc.model 2>/dev/null)
    [[ -z "$MC_SOC_VENDOR" ]] && MC_SOC_VENDOR=$(getprop ro.hardware 2>/dev/null)
    [[ -z "$MC_SOC_MODEL" ]] && MC_SOC_MODEL=$(getprop ro.product.board 2>/dev/null)
    MC_ANDROID_VER=$(getprop ro.build.version.release 2>/dev/null)

    # SoC whitelist pentru capabilitati fine (10-bit HEVC, AV1 encode)
    # Nota: prezenta in whitelist marcheaza [verificat] in UI; absenta nu blocheaza
    local v_lc m_lc
    v_lc=$(echo "$MC_SOC_VENDOR" | tr '[:upper:]' '[:lower:]')
    m_lc=$(echo "$MC_SOC_MODEL" | tr '[:upper:]' '[:lower:]')

    # Snapdragon 8xx (Gen 1+) — HEVC main10 + AV1 encode pe 8 Gen 2+
    if [[ "$v_lc" == *"qualcomm"* ]] || [[ "$v_lc" == *"qcom"* ]]; then
        # SM8450 (8 Gen 1), SM8475 (8+ Gen 1), SM8550 (8 Gen 2), SM8650 (8 Gen 3), SM8750 (8 Gen 4)
        if [[ "$m_lc" =~ sm8(4|5|6|7)[0-9]{2} ]] || [[ "$m_lc" =~ sm8[5-9][0-9]{2} ]]; then
            MC_SOC_VERIFIED=1
            MC_CAP_HEVC10=1
            # AV1 encode HW: doar 8 Gen 2+ (SM8550+)
            if [[ "$m_lc" =~ sm8[5-9][0-9]{2} ]] || [[ "$m_lc" =~ sm87[0-9]{2} ]]; then
                MC_CAP_AV1=1
            fi
        fi
    fi
    # Samsung Exynos 2100+ (HEVC 10-bit), Exynos 2400+ (AV1 encode)
    if [[ "$v_lc" == *"samsung"* ]] || [[ "$m_lc" == *"exynos"* ]]; then
        if [[ "$m_lc" =~ exynos2[1-9][0-9]{2} ]]; then
            MC_SOC_VERIFIED=1
            MC_CAP_HEVC10=1
            [[ "$m_lc" =~ exynos2[4-9][0-9]{2} ]] && MC_CAP_AV1=1
        fi
    fi
    # Google Tensor (G2+) — HEVC 10-bit; G3+ AV1 encode
    if [[ "$v_lc" == *"google"* ]] || [[ "$m_lc" == *"tensor"* ]] || [[ "$m_lc" == *"gs"* ]]; then
        if [[ "$m_lc" =~ (gs[2-9]|tensor.*g[2-9]) ]]; then
            MC_SOC_VERIFIED=1
            MC_CAP_HEVC10=1
            [[ "$m_lc" =~ (gs[3-9]|tensor.*g[3-9]) ]] && MC_CAP_AV1=1
        fi
    fi
    # MediaTek Dimensity 9000+ — HEVC 10-bit; 9300+ AV1 encode
    # MTK SoC numbers: D9000=MT6983, D9200=MT6985, D9300=MT6989, D9400=MT6991, D9500+=MT699x
    if [[ "$v_lc" == *"mediatek"* ]] || [[ "$m_lc" == *"mt"* ]] || [[ "$m_lc" == *"dimensity"* ]]; then
        if [[ "$m_lc" =~ (mt69[89][0-9]|dimensity.?9[0-9]{3}) ]]; then
            MC_SOC_VERIFIED=1
            MC_CAP_HEVC10=1
            # AV1: D9300+ (MT6989, MT6991, MT699x) sau "Dimensity 9300+"
            [[ "$m_lc" =~ (mt6989|mt699[0-9]|dimensity.?9[3-9][0-9]{2}) ]] && MC_CAP_AV1=1
        fi
    fi

    return 0
}

# Helper: returneaza label-ul scurt pentru meniul HW (ex: "MediaCodec HEVC [verificat]")
mediacodec_menu_label() {
    local codec="$1"  # h264|hevc|av1
    local enc_name="${codec}_mediacodec"
    [[ "$MC_ENCODERS" != *"$enc_name"* ]] && { echo ""; return; }
    local marker
    if [[ "$MC_SOC_VERIFIED" == "1" ]]; then
        marker="[verificat]"
    else
        marker="[suport necunoscut]"
    fi
    echo "MediaCodec ${codec^^} $marker"
}

# Helper: prompt confirmare pe SoC necunoscut (return 0 = continua, 1 = abort)
mediacodec_confirm_unknown_soc() {
    [[ "${HW_FORCE:-0}" == "1" ]] && return 0
    [[ "$MC_SOC_VERIFIED" == "1" ]] && return 0
    echo ""
    echo "  ⚠ SoC nedetectat in whitelist:"
    echo "    Vendor: ${MC_SOC_VENDOR:-necunoscut}"
    echo "    Model : ${MC_SOC_MODEL:-necunoscut}"
    echo "    Android: ${MC_ANDROID_VER:-?}"
    echo "    MediaCodec va incerca encoding, dar capabilitatile (10-bit, AV1) sunt incerte."
    read -p "  Continui cu MediaCodec? (d/N) [default: N]: " _mc_conf
    [[ "${_mc_conf,,}" == "d" ]] && return 0
    return 1
}

# Helper: banner SoC pentru log la inceputul flow-ului encode
mediacodec_print_banner() {
    [[ "$MC_AVAILABLE" != "1" ]] && return
    local cap_str=""
    [[ "$MC_CAP_HEVC10" == "1" ]] && cap_str="${cap_str} HEVC10"
    [[ "$MC_CAP_AV1" == "1" ]] && cap_str="${cap_str} AV1"
    [[ -z "$cap_str" ]] && cap_str=" 8-bit only"
    local verified_str
    if [[ "$MC_SOC_VERIFIED" == "1" ]]; then
        verified_str="verificat"
    else
        verified_str="necunoscut"
    fi
    log "  HW MediaCodec: SoC ${MC_SOC_VENDOR:-?} ${MC_SOC_MODEL:-?} / Android ${MC_ANDROID_VER:-?} [${verified_str}]${cap_str}"
}

# ══════════════════════════════════════════════════════════════════════
# v38: BUILD MEDIACODEC FFMPEG_CMD
# Args: $1 = file ; $2 = enc_codec (hevc|h264|av1)
# Citeste env: WIDTH, MC_HDR_MODE, MC_CAP_HEVC10, AUDIO_PARAMS, MAP_FLAGS, THREADS
# Seteaza: FFMPEG_CMD (ca string), MC_NEEDS_REPAIR (0/1) pentru post-encode SEI
# MC_HDR_MODE valori:
#   ""           — SDR encode normal (pentru surse SDR)
#   hw_repair    — 10-bit + signaling HDR10 + repair flag setat
#   hw_sdr       — tonemap HDR→SDR 8-bit
# (sw_full / sw_degraded sunt rezolvate inainte de a ajunge aici — nu se cheama mediacodec)
# ══════════════════════════════════════════════════════════════════════
build_mediacodec_cmd() {
    local file="$1" enc_codec="$2"
    local enc_name="${enc_codec}_mediacodec"
    MC_NEEDS_REPAIR=0

    # Rate control: respecta ENCODE_MODE=2 (VBR custom) daca user a setat target
    local bitrate maxrate bufsize rate_flags
    if [[ "${ENCODE_MODE:-1}" == "2" ]] && [[ -n "${VBR_TARGET:-}" ]]; then
        # VBR_TARGET vine ca "8M" sau "8000k" — extrage numarul ca kbps
        local vt="$VBR_TARGET"
        if [[ "$vt" =~ ^([0-9]+)[Mm]$ ]]; then bitrate=$(( ${BASH_REMATCH[1]} * 1000 ))
        elif [[ "$vt" =~ ^([0-9]+)[Kk]$ ]]; then bitrate="${BASH_REMATCH[1]}"
        elif [[ "$vt" =~ ^[0-9]+$ ]]; then bitrate=$(( vt / 1000 ))
        else bitrate=$(get_adaptive_bitrate "$enc_name" "$WIDTH"); fi
        local mr="${VBR_MAXRATE:-}"
        if [[ "$mr" =~ ^([0-9]+)[Mm]$ ]]; then maxrate=$(( ${BASH_REMATCH[1]} * 1000 ))
        elif [[ "$mr" =~ ^([0-9]+)[Kk]$ ]]; then maxrate="${BASH_REMATCH[1]}"
        else maxrate=$(( bitrate * 3 / 2 )); fi
    else
        bitrate=$(get_adaptive_bitrate "$enc_name" "$WIDTH")
        maxrate=$(( bitrate * 3 / 2 ))
    fi
    bufsize=$(( bitrate * 2 ))
    rate_flags="-b:v ${bitrate}k -maxrate ${maxrate}k -bufsize ${bufsize}k"

    local pix_fmt color_flags="" mc_extra_vf="" profile_flag=""

    case "${MC_HDR_MODE:-}" in
        hw_repair)
            # 10-bit HDR10: BT.2020 + PQ + main10 (doar HEVC suporta main10)
            if [[ "$MC_CAP_HEVC10" == "1" ]] && [[ "$enc_codec" == "hevc" ]]; then
                pix_fmt="yuv420p10le"
                profile_flag="-profile:v main10"
            else
                pix_fmt="yuv420p"
                log "  ATENTIE: SoC nu suporta 10-bit (sau codec != HEVC), fallback la 8-bit"
            fi
            color_flags="-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc"
            MC_NEEDS_REPAIR=1
            ;;
        hw_sdr)
            # Tonemap HDR→SDR 8-bit
            pix_fmt="yuv420p"
            color_flags="-color_primaries bt709 -color_trc bt709 -colorspace bt709"
            mc_extra_vf="zscale=t=linear:npl=100,tonemap=hable:desat=0,zscale=t=bt709:p=bt709:m=bt709,format=yuv420p"
            ;;
        *)
            pix_fmt="yuv420p"
            ;;
    esac

    # Inject extra VF (tonemap) in VIDEO_FILTER global
    if [[ -n "$mc_extra_vf" ]]; then
        if [[ -n "$VIDEO_FILTER" ]] && [[ "$VIDEO_FILTER" == *"-vf "* ]]; then
            VIDEO_FILTER="${VIDEO_FILTER/-vf /-vf ${mc_extra_vf},}"
        else
            VIDEO_FILTER="-vf $mc_extra_vf"
        fi
    fi

    log "  MediaCodec: $enc_name | bitrate ${bitrate}k / max ${maxrate}k | pix_fmt $pix_fmt"
    [[ -n "${MC_HDR_MODE:-}" ]] && log "  Mod HDR    : $MC_HDR_MODE"

    FFMPEG_CMD="ffmpeg -threads $THREADS -i \"\$file\" $MAP_FLAGS \
        -c:v $enc_name $rate_flags \
        $profile_flag -pix_fmt $pix_fmt $color_flags $VIDEO_FILTER $AUDIO_PARAMS"

    return 0
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
        # v38: reset MediaCodec per-file flags pentru a evita leak intre iteratii
        MC_NEEDS_REPAIR=0
        MC_HDR_MODE=""
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

        # v38: Smart stream copy detection — daca source codec == target codec
        # și nu sunt transformări planificate (filter, normalize, HDR, LOG, DV),
        # propune stream copy total. Salvează ore de encode + zero pierdere calitate.
        local _src_codec; _src_codec=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=codec_name -of default=nw=1:nk=1 "$file" 2>/dev/null)
        local _tgt_codec=""
        case "${ENCODER_NAME:-}" in
            libx265) _tgt_codec="hevc" ;;
            libx264) _tgt_codec="h264" ;;
            av1)     _tgt_codec="av1" ;;
        esac
        if [[ -n "$_tgt_codec" && "$_src_codec" == "$_tgt_codec" ]] \
           && [[ -z "$VIDEO_FILTER" ]] \
           && [[ "${AUDIO_NORMALIZE:-0}" != "1" ]] \
           && [[ "${IS_LOG:-0}" != "1" ]] \
           && [[ -z "${HDR_PLUS:-}" ]] && [[ -z "${DOVI:-}" ]] \
           && [[ "${TRIPLE_LAYER_MODE:-0}" != "1" ]]; then
            # Bonus: bitrate sanity info
            local _src_br _br_str=""
            _src_br=$(ffprobe -v error -select_streams v:0 \
                -show_entries stream=bit_rate -of default=nw=1:nk=1 "$file" 2>/dev/null)
            [[ "$_src_br" =~ ^[0-9]+$ ]] && _br_str=" (bitrate sursa ~$((_src_br/1000)) kbps)"
            log ""
            log "  ⚡ SMART COPY: source este deja $_src_codec, identic cu target ($ENCODER_NAME)$_br_str."
            log "    Re-encode redundant — pierde calitate fără beneficiu real de compresie."
            read -p "  Stream copy total in loc de re-encode? (D/n) [default: D]: " _smart_ch
            if [[ "${_smart_ch,,}" != "n" ]]; then
                log "  → Smart stream copy aplicat"
                do_stream_copy "$file" "$output" "$MAP_FLAGS"
                local _sc_rc=$?
                if [ $_sc_rc -ne 0 ]; then
                    TOTAL_ERRORS=$((TOTAL_ERRORS+1))
                    rm -f "$output"
                fi
                [[ -n "${HDR10PLUS_JSON:-}" ]] && rm -f "$HDR10PLUS_JSON"; HDR10PLUS_JSON=""
                [[ -n "${DOVI_RPU_FILE:-}" ]] && rm -f "$DOVI_RPU_FILE"; DOVI_RPU_FILE=""
                TRIPLE_LAYER_MODE=0
                continue
            fi
        fi

        LOUDNORM_FILTER=""
        [[ "$AUDIO_NORMALIZE" == "1" ]] && [[ "$AUDIO_CODEC_ARG" != "copy" ]] && \
            LOUDNORM_FILTER=$(get_loudnorm_filter "$file")
        TRF_FILE=""; _apply_vidstab "$file"

        PROGRESS_FILE=$(mktemp); START_TIME=$(date +%s)
        # v38: stderr capture într-un fișier separat (în paralel cu LOG_FILE)
        local _enc_err; _enc_err=$(mktemp)
        # v38: label dinamic — uppercase ENCODER_NAME (ex: LIBX265, AV1, DNXHR)
        local _enc_label; _enc_label="${ENCODER_NAME:-FFmpeg}"; _enc_label="${_enc_label^^}"
        # shellcheck disable=SC2086
        eval $FFMPEG_CMD $LOUDNORM_FILTER $SUB_CODEC -c:t copy \
            $CONTAINER_FLAGS -progress '"$PROGRESS_FILE"' -nostats '"$output"' '2>"$_enc_err"' '&'
        FFMPEG_PID=$!; _show_progress "$FFMPEG_PID" "$PROGRESS_FILE" "$file" "$_enc_label"
        wait "$FFMPEG_PID"; FFMPEG_EXIT=$?
        # Append stderr la LOG_FILE pentru istoric complet
        [[ -s "$_enc_err" ]] && cat "$_enc_err" >> "$LOG_FILE"
        [[ -n "${TRF_FILE:-}" ]] && rm -f "$TRF_FILE"; TRF_FILE=""
        if [ $FFMPEG_EXIT -ne 0 ]; then
            log "  EROARE encodare (cod $FFMPEG_EXIT)"
            # v38: arata ultimele linii stderr inline pentru diagnoza rapida
            if [[ -s "$_enc_err" ]]; then
                echo "  ⚠ ffmpeg exit $FFMPEG_EXIT — ultimele linii stderr:"
                tail -10 "$_enc_err" | sed 's/^/    /'
            fi
            rm -f "$_enc_err"
            [[ -n "${HDR10PLUS_JSON:-}" ]] && rm -f "$HDR10PLUS_JSON"; HDR10PLUS_JSON=""
            [[ -n "${DOVI_RPU_FILE:-}" ]] && rm -f "$DOVI_RPU_FILE"; DOVI_RPU_FILE=""
            TRIPLE_LAYER_MODE=0
            TOTAL_ERRORS=$((TOTAL_ERRORS+1)); rm -f "$output"; continue
        fi
        rm -f "$_enc_err"

        # ── v38: MediaCodec HDR10 signaling repair ────────────────────
        if [[ "${MC_NEEDS_REPAIR:-0}" == "1" ]] && [[ "${USE_MEDIACODEC:-0}" == "1" ]]; then
            MC_REPAIR_SRC="$file" repair_hdr10_signaling "$output"
            MC_NEEDS_REPAIR=0
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

# ══════════════════════════════════════════════════════════════════════
# TRIM & CONCAT (v36+) — Helpers + Flows
# ══════════════════════════════════════════════════════════════════════

# Parsare timp flexibil: "45" → 00:00:45, "1:30" → 00:01:30, "1:05:30" → 01:05:30
# Acceptă și formatul complet HH:MM:SS. Returnează secundele ca integer.
# Eșec: returnează "" (gol).
parse_time_flexible() {
    local t="$1"
    [[ -z "$t" ]] && { echo ""; return; }
    # Strip whitespace
    t="${t// /}"
    local h=0 m=0 s=0
    if [[ "$t" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
        h="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"; s="${BASH_REMATCH[3]}"
    elif [[ "$t" =~ ^([0-9]+):([0-9]+)$ ]]; then
        m="${BASH_REMATCH[1]}"; s="${BASH_REMATCH[2]}"
    elif [[ "$t" =~ ^([0-9]+)$ ]]; then
        s="${BASH_REMATCH[1]}"
    else
        echo ""; return
    fi
    # Validare intervale
    if (( m > 59 || s > 59 )); then echo ""; return; fi
    echo $(( h*3600 + m*60 + s ))
}

# Formatare secunde → HH:MM:SS
format_seconds() {
    local s=$1
    printf "%02d:%02d:%02d" $((s/3600)) $((s%3600/60)) $((s%60))
}

# Durată video în secunde (integer)
get_duration_seconds() {
    local file="$1"
    local d
    d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$file" 2>/dev/null)
    d=${d%.*}; [[ ! "$d" =~ ^[0-9]+$ ]] && d=0
    echo "$d"
}

# Expandare range syntax: "1-3,7,10-12" → "1 2 3 7 10 11 12"
# "all" → toate indecșii până la MAX. Returnează lista pe stdout, spațiu-separat.
expand_range_selection() {
    local input="$1" max="$2"
    input="${input// /}"
    if [[ "${input,,}" == "all" ]]; then
        seq 1 "$max"
        return
    fi
    local out=()
    IFS=',' read -ra parts <<< "$input"
    for p in "${parts[@]}"; do
        if [[ "$p" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
            (( a > b )) && { local tmp=$a; a=$b; b=$tmp; }
            for ((i=a; i<=b && i<=max; i++)); do out+=("$i"); done
        elif [[ "$p" =~ ^[0-9]+$ ]]; then
            (( p >= 1 && p <= max )) && out+=("$p")
        fi
    done
    # Dedupe păstrând ordinea
    local seen=() uniq=()
    for x in "${out[@]}"; do
        local dup=0
        for y in "${seen[@]}"; do [[ "$y" == "$x" ]] && dup=1 && break; done
        (( dup == 0 )) && { seen+=("$x"); uniq+=("$x"); }
    done
    echo "${uniq[@]}"
}

# Generator sub-folder temp unic: $AV_TEMP_DIR/trim_<PID>_<timestamp>
# Creează folderul, setează global TRIM_TEMP_SUBDIR
create_temp_subdir() {
    local prefix="${1:-trim}"
    ensure_temp_dir
    local sub="${AV_TEMP_DIR}/${prefix}_$$_$(date +%s)"
    mkdir -p "$sub"
    TRIM_TEMP_SUBDIR="$sub"
    echo "$sub"
}

# Cleanup sub-folder temp DOAR dacă output-ul final există și are size > 0
cleanup_temp_subdir() {
    local subdir="$1" output="$2"
    if [[ -f "$output" && -s "$output" ]]; then
        rm -rf "$subdir"
        echo "  Temp cleanup: $subdir sters."
    else
        echo ""
        echo "  ⚠ EROARE: output final eșuat sau gol."
        echo "  Fișierele temporare păstrate în: $subdir"
    fi
}

# Listare fișiere video din INPUT_DIR. Setează global TC_FILES=() + TC_COUNT.
scan_input_videos() {
    shopt -s nullglob nocaseglob
    TC_FILES=("$INPUT_DIR"/*.{mp4,mov,mkv,m2ts,mts,mxf,webm,avi})
    shopt -u nocaseglob nullglob
    TC_COUNT=${#TC_FILES[@]}
}

# Prompt pt timp cu validare: re-întreabă până când input-ul e valid
# Arg: $1=prompt, $2=default_seconds, $3=max_duration_seconds
# Output: secundele pe stdout
prompt_time_validated() {
    local prompt="$1" default_s="$2" max_s="$3"
    local def_fmt; def_fmt=$(format_seconds "$default_s")
    while true; do
        read -p "$prompt [default: $def_fmt]: " raw
        [[ -z "$raw" ]] && { echo "$default_s"; return; }
        local parsed; parsed=$(parse_time_flexible "$raw")
        if [[ -z "$parsed" ]]; then
            echo "  Format invalid. Exemple: 45 / 1:30 / 1:05:30 / 01:05:30" >&2
            continue
        fi
        if (( parsed > max_s )); then
            echo "  Timp > durata (${max_s}s). Clamp la durata maximă." >&2
            echo "$max_s"; return
        fi
        if (( parsed < 0 )); then parsed=0; fi
        echo "$parsed"; return
    done
}

# Verificare coliziune output + oferă overwrite/auto-suffix/rename
# Arg: $1=output_path
# Output: calea finală pe stdout (posibil modificată)
resolve_output_collision() {
    local target="$1"
    if [[ ! -e "$target" ]]; then echo "$target"; return; fi
    echo "" >&2
    echo "  ⚠ Fisierul exista deja: $(basename "$target")" >&2
    echo "  1) Suprascrie" >&2
    echo "  2) Auto-suffix (_1, _2, ...)" >&2
    echo "  3) Rename manual" >&2
    read -p "  Alege [default: 2]: " ch >&2
    case "$ch" in
        1) echo "$target" ;;
        3)
            read -p "  Nume nou (fara extensie): " nn >&2
            local dir="$(dirname "$target")" ext="${target##*.}"
            echo "${dir}/${nn}.${ext}"
            ;;
        *)
            local dir="$(dirname "$target")" base="$(basename "$target")"
            local name="${base%.*}" ext="${base##*.}" n=1
            while [[ -e "${dir}/${name}_${n}.${ext}" ]]; do n=$((n+1)); done
            echo "${dir}/${name}_${n}.${ext}"
            ;;
    esac
}

# ── Flow 1: Trim un singur fișier ─────────────────────────────────────
trimconcat_flow_trim() {
    scan_input_videos
    if (( TC_COUNT == 0 )); then
        echo "Nu exista fisiere video in $INPUT_DIR"; return 1
    fi
    echo ""
    echo "╔══════════════════════════════════════╗"
    echo "║  TRIM — Selectare fisier             ║"
    echo "╠══════════════════════════════════════╣"
    for ((i=0; i<TC_COUNT; i++)); do
        local f="${TC_FILES[$i]}" dur
        dur=$(get_duration_seconds "$f")
        printf "║  %2d) %-28s %s\n" "$((i+1))" "$(basename "$f" | cut -c1-28)" "$(format_seconds "$dur")"
    done
    echo "╚══════════════════════════════════════╝"
    read -p "Alege 1-$TC_COUNT: " fidx
    if ! [[ "$fidx" =~ ^[0-9]+$ ]] || (( fidx < 1 || fidx > TC_COUNT )); then
        echo "Selectie invalida."; return 1
    fi
    local src="${TC_FILES[$((fidx-1))]}"
    local src_base; src_base=$(basename "$src")
    local src_name="${src_base%.*}" src_ext="${src_base##*.}"
    local total_s; total_s=$(get_duration_seconds "$src")

    mkdir -p "$OUTPUT_DIR" 2>/dev/null
    termux-wake-lock 2>/dev/null

    local cut_idx=1
    while true; do
        echo ""
        echo "╔══════════════════════════════════════╗"
        echo "║  TRIM #$cut_idx — $src_base"
        echo "║  Durată totală: $(format_seconds "$total_s")"
        echo "╚══════════════════════════════════════╝"

        local start_s end_s
        while true; do
            start_s=$(prompt_time_validated "Start" 0 "$total_s")
            end_s=$(prompt_time_validated "End  " "$total_s" "$total_s")
            if (( start_s >= end_s )); then
                echo "  EROARE: start >= end. Reintrodu."; continue
            fi
            break
        done
        local clip_s=$(( end_s - start_s ))
        echo ""
        echo "  Clip rezultat: $(format_seconds "$clip_s") (din $(format_seconds "$start_s") la $(format_seconds "$end_s"))"
        read -p "  Confirma? (d/n) [default: d]: " conf
        if [[ "${conf,,}" == "n" ]]; then echo "  Anulat."; continue; fi

        # Dialog stream copy vs re-encode
        echo ""
        echo "  Precizie trim:"
        echo "    1) Stream copy (instant, lossless, ±1-2s la keyframe) [default]"
        echo "    2) Re-encode (exact, frame-accurate, mai lent)"
        read -p "  Alege 1-2 [default: 1]: " mode
        local out_suffix="_trim${cut_idx}_$(format_seconds "$start_s" | tr ':' '-')"
        local out_path="${OUTPUT_DIR}/${src_name}${out_suffix}.${src_ext}"
        out_path=$(resolve_output_collision "$out_path")

        if [[ "$mode" == "2" ]]; then
            # Re-encode minimalist
            echo ""
            echo "  Re-encode: 1-libx265 [default]  2-libx264"
            read -p "  Codec: " ec
            local codec="libx265"; [[ "$ec" == "2" ]] && codec="libx264"
            read -p "  CRF [default: 22]: " crf; [[ -z "$crf" ]] && crf=22
            echo "  Audio: 1-copy [default]  2-aac 192k  3-eac3 224k"
            read -p "  Alege: " ac
            local aopt=(-c:a copy)
            [[ "$ac" == "2" ]] && aopt=(-c:a aac -b:a 192k)
            [[ "$ac" == "3" ]] && aopt=(-c:a eac3 -b:a 224k)
            echo "  Encoding... $(format_seconds "$clip_s")"
            run_ffmpeg_with_progress "Trim re-encode" "$clip_s" \
                -y -ss "$start_s" -to "$end_s" -i "$src" \
                -map 0 -map_metadata 0 -c:v "$codec" -crf "$crf" -preset medium \
                "${aopt[@]}" -c:s copy \
                -avoid_negative_ts make_zero \
                "$out_path"
        else
            echo ""
            echo "  NOTĂ: Stream copy taie la cel mai apropiat keyframe."
            echo "  Tăietura poate diferi cu 1-2 secunde față de timpul exact."
            echo "  Stream copy... (instant)"
            ffmpeg -y -ss "$start_s" -to "$end_s" -i "$src" \
                -map 0 -map_metadata 0 -c copy \
                -avoid_negative_ts make_zero -copyts \
                "$out_path" 2>&1 | tail -5
        fi

        if [[ -f "$out_path" && -s "$out_path" ]]; then
            local osize; osize=$(stat -c%s "$out_path" 2>/dev/null || echo 0)
            echo ""
            echo "  ✓ Output: $out_path"
            echo "  ✓ Size: $(( osize/1024/1024 )) MB"
        else
            echo "  ✗ EROARE: output-ul nu a fost creat."
        fi

        echo ""
        read -p "Vrei sa tai alta sectiune din acelasi fisier? (d/n) [default: n]: " again
        if [[ "${again,,}" != "d" ]]; then break; fi
        cut_idx=$((cut_idx+1))
    done

    termux-wake-unlock 2>/dev/null
    echo ""
    echo "  Trim terminat. $((cut_idx)) clip-uri generate."
}

# ── Flow Batch Trim: aceleași cuturi pe N fisiere ────────────────────
trimconcat_flow_batch_trim() {
    scan_input_videos
    if (( TC_COUNT == 0 )); then
        echo "Nu exista fisiere video in $INPUT_DIR"; return 1
    fi
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  BATCH TRIM — Selectare fisiere              ║"
    echo "╠══════════════════════════════════════════════╣"
    for ((i=0; i<TC_COUNT; i++)); do
        local f="${TC_FILES[$i]}" dur
        dur=$(get_duration_seconds "$f")
        printf "║  %2d) %-32s %s\n" "$((i+1))" "$(basename "$f" | cut -c1-32)" "$(format_seconds "$dur")"
    done
    echo "╚══════════════════════════════════════════════╝"
    echo "Exemple: all / 1,3,5 / 1-5 / 1-3,7,10-12"
    read -p "Selecteaza fisiere: " sel_raw
    local indices; indices=($(expand_range_selection "$sel_raw" "$TC_COUNT"))
    if (( ${#indices[@]} == 0 )); then
        echo "Selectie invalida."; return 1
    fi

    local selected=()
    local min_dur=999999999
    for idx in "${indices[@]}"; do
        local f="${TC_FILES[$((idx-1))]}"
        selected+=("$f")
        local d; d=$(get_duration_seconds "$f")
        (( d < min_dur )) && min_dur=$d
    done
    echo ""
    echo "  ${#selected[@]} fisiere selectate. Cea mai scurta durata: $(format_seconds "$min_dur")"

    # Cuts comune: una sau mai multe perechi start:end
    local cuts=()
    local cut_idx=1
    while true; do
        echo ""
        echo "  Segment #$cut_idx (aplicat la toate fisierele):"
        local start_s end_s
        while true; do
            start_s=$(prompt_time_validated "Start" 0 "$min_dur")
            end_s=$(prompt_time_validated "End  " "$min_dur" "$min_dur")
            if (( start_s >= end_s )); then
                echo "  EROARE: start >= end. Reintrodu."; continue
            fi
            break
        done
        cuts+=("${start_s}:${end_s}")
        echo "  → $(format_seconds "$start_s") - $(format_seconds "$end_s") ($(format_seconds "$((end_s - start_s))"))"
        echo ""
        read -p "  Mai adaugi un segment? (d/n) [default: n]: " again
        if [[ "${again,,}" != "d" ]]; then break; fi
        cut_idx=$((cut_idx+1))
    done

    # Mod: stream copy / re-encode
    echo ""
    echo "  Precizie trim:"
    echo "    1) Stream copy (instant, lossless, ±1-2s la keyframe) [default]"
    echo "    2) Re-encode (exact, frame-accurate, mai lent)"
    read -p "  Alege 1-2 [default: 1]: " mode
    local re_codec="libx265" re_crf=22 re_aopt=(-c:a copy)
    if [[ "$mode" == "2" ]]; then
        echo "  Codec: 1-libx265 [default]  2-libx264"
        read -p "  Alege: " ec
        [[ "$ec" == "2" ]] && re_codec="libx264"
        read -p "  CRF [default: 22]: " crf2; [[ -n "$crf2" ]] && re_crf=$crf2
        echo "  Audio: 1-copy [default]  2-aac 192k  3-eac3 224k"
        read -p "  Alege: " ac
        [[ "$ac" == "2" ]] && re_aopt=(-c:a aac -b:a 192k)
        [[ "$ac" == "3" ]] && re_aopt=(-c:a eac3 -b:a 224k)
    fi

    mkdir -p "$OUTPUT_DIR" 2>/dev/null
    termux-wake-lock 2>/dev/null

    # Loop: pentru fiecare fisier × fiecare segment
    local total_ops=$(( ${#selected[@]} * ${#cuts[@]} ))
    local op=0 ok=0 fail=0 skip=0
    for src in "${selected[@]}"; do
        local sb; sb=$(basename "$src")
        local sn="${sb%.*}" sext="${sb##*.}"
        local sdur; sdur=$(get_duration_seconds "$src")
        local ci=1
        for cut in "${cuts[@]}"; do
            op=$((op+1))
            local ss="${cut%:*}" ee="${cut#*:}"
            if (( ee > sdur )); then
                echo "[$op/$total_ops] $sb seg$ci — SKIP (durata $(format_seconds "$sdur") < end $(format_seconds "$ee"))"
                skip=$((skip+1))
                ci=$((ci+1)); continue
            fi
            local clip_s=$(( ee - ss ))
            local out_suffix="_btrim${ci}_$(format_seconds "$ss" | tr ':' '-')"
            local out_path="${OUTPUT_DIR}/${sn}${out_suffix}.${sext}"
            out_path=$(resolve_output_collision "$out_path")
            echo ""
            echo "[$op/$total_ops] $sb seg$ci: $(format_seconds "$ss") → $(format_seconds "$ee")"
            local rc=0
            if [[ "$mode" == "2" ]]; then
                run_ffmpeg_with_progress "Batch trim ($op/$total_ops)" "$clip_s" \
                    -y -ss "$ss" -to "$ee" -i "$src" \
                    -map 0 -map_metadata 0 -c:v "$re_codec" -crf "$re_crf" -preset medium \
                    "${re_aopt[@]}" -c:s copy \
                    -avoid_negative_ts make_zero \
                    "$out_path"
                rc=$?
            else
                ffmpeg -y -ss "$ss" -to "$ee" -i "$src" \
                    -map 0 -map_metadata 0 -c copy \
                    -avoid_negative_ts make_zero -copyts \
                    "$out_path" 2>&1 | tail -3
                rc=${PIPESTATUS[0]}
            fi
            if [[ $rc -eq 0 && -f "$out_path" && -s "$out_path" ]]; then
                ok=$((ok+1))
                echo "  ✓ $(basename "$out_path")"
            else
                fail=$((fail+1))
                echo "  ✗ EROARE: $(basename "$out_path")"
            fi
            ci=$((ci+1))
        done
    done

    termux-wake-unlock 2>/dev/null
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  BATCH TRIM — Sumar                          ║"
    echo "╠══════════════════════════════════════════════╣"
    echo "║  Fisiere: ${#selected[@]} | Segmente: ${#cuts[@]} | Total: $total_ops"
    echo "║  ✓ OK: $ok    ✗ FAIL: $fail    → SKIP: $skip"
    echo "╚══════════════════════════════════════════════╝"
}

# ── Preview thumbnails (v37): 3-frame tile per fișier ────────────────
# Args: array de path-uri
# Output: PNG-uri în AV_TEMP_DIR/preview_<ts>/ — un fișier per intrare
generate_preview_thumbnails() {
    local files=("$@")
    local n=${#files[@]}
    if (( n == 0 )); then return 0; fi
    local subdir; subdir=$(create_temp_subdir "preview")
    echo "  Generez $n preview-uri (3-frame tile, 320p)..."
    local ok=0 fail=0
    for ((i=0; i<n; i++)); do
        local f="${files[$i]}"
        local fb; fb=$(basename "$f")
        local fn="${fb%.*}"
        local out="${subdir}/${fn}_preview.png"
        local dur; dur=$(get_duration_seconds "$f")
        if (( dur < 3 )); then
            echo "    [$((i+1))/$n] $fb — skip (durata < 3s)"
            continue
        fi
        local t1 t2 t3
        t1=$(awk "BEGIN{printf \"%.2f\", $dur*0.05}")
        t2=$(awk "BEGIN{printf \"%.2f\", $dur*0.5}")
        t3=$(awk "BEGIN{printf \"%.2f\", $dur*0.95}")
        ffmpeg -y -hide_banner -loglevel error \
            -ss "$t1" -i "$f" -ss "$t2" -i "$f" -ss "$t3" -i "$f" \
            -filter_complex "[0:v]scale=320:-1[a];[1:v]scale=320:-1[b];[2:v]scale=320:-1[c];[a][b][c]hstack=3" \
            -frames:v 1 "$out" 2>/dev/null
        if [[ -f "$out" && -s "$out" ]]; then
            ok=$((ok+1))
            echo "    [$((i+1))/$n] $fb → $(basename "$out")"
        else
            fail=$((fail+1))
            echo "    [$((i+1))/$n] $fb — esuat"
        fi
    done
    echo "  ✓ Preview-uri: $ok OK, $fail esuate"
    echo "  Locatie: $subdir"
}

# Probe rapid fișier: codec + rez + fps + pix_fmt pt compat check
# Arg: $1=file. Output: "codec|WxH|fps|pix_fmt" pe stdout
probe_video_signature() {
    local f="$1"
    ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name,width,height,r_frame_rate,pix_fmt \
        -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null | \
        paste -sd'|' -
}

# Verifică dacă toate fișierele au signature identică. Return 0=compat, 1=diferit
check_concat_compat() {
    local files=("$@")
    local first=""
    for f in "${files[@]}"; do
        local sig; sig=$(probe_video_signature "$f")
        if [[ -z "$first" ]]; then first="$sig"
        elif [[ "$sig" != "$first" ]]; then return 1; fi
    done
    return 0
}

# ── Flow 2: Concat fișiere ────────────────────────────────────────────
trimconcat_flow_concat() {
    scan_input_videos
    if (( TC_COUNT == 0 )); then
        echo "Nu exista fisiere video in $INPUT_DIR"; return 1
    fi
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  CONCAT — Listare fisiere                    ║"
    echo "╠══════════════════════════════════════════════╣"
    for ((i=0; i<TC_COUNT; i++)); do
        local f="${TC_FILES[$i]}" dur
        dur=$(get_duration_seconds "$f")
        printf "║  %2d) %-32s %s\n" "$((i+1))" "$(basename "$f" | cut -c1-32)" "$(format_seconds "$dur")"
    done
    echo "╚══════════════════════════════════════════════╝"
    echo "Exemple: all / 1,3,5 / 1-5 / 1-3,7,10-12"
    read -p "Selecteaza: " sel_raw
    local indices; indices=($(expand_range_selection "$sel_raw" "$TC_COUNT"))
    if (( ${#indices[@]} == 0 )); then
        echo "Selectie invalida."; return 1
    fi

    # Sort options
    echo ""
    echo "Ordine fisiere:"
    echo "  1) Nume (alfabetic) [default]"
    echo "  2) Data modificare"
    echo "  3) Dimensiune"
    echo "  4) Manual (introdu ordinea)"
    echo "  5) Pastreaza ordinea selectiei"
    read -p "Alege 1-5 [default: 1]: " sort_mode
    [[ -z "$sort_mode" ]] && sort_mode=1

    # Build selected array
    local selected=()
    for idx in "${indices[@]}"; do selected+=("${TC_FILES[$((idx-1))]}"); done

    case "$sort_mode" in
        1) # name
            local IFS=$'\n'
            selected=($(for f in "${selected[@]}"; do echo "$f"; done | sort))
            unset IFS
            ;;
        2) # date
            local IFS=$'\n'
            selected=($(for f in "${selected[@]}"; do printf "%s\t%s\n" "$(stat -c %Y "$f" 2>/dev/null)" "$f"; done | sort -n | cut -f2-))
            unset IFS
            ;;
        3) # size
            local IFS=$'\n'
            selected=($(for f in "${selected[@]}"; do printf "%s\t%s\n" "$(stat -c %s "$f" 2>/dev/null)" "$f"; done | sort -n | cut -f2-))
            unset IFS
            ;;
        4) # manual — afiseaza si cere ordinea
            echo ""
            for ((i=0; i<${#selected[@]}; i++)); do
                echo "  $((i+1))) $(basename "${selected[$i]}")"
            done
            read -p "Ordinea noua (ex: 3,1,2): " new_order
            local reordered=()
            IFS=',' read -ra parts <<< "$new_order"
            for p in "${parts[@]}"; do
                p="${p// /}"
                if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= ${#selected[@]} )); then
                    reordered+=("${selected[$((p-1))]}")
                fi
            done
            if (( ${#reordered[@]} == 0 )); then
                echo "Ordine invalida, pastrez ordinea initiala."
            else
                selected=("${reordered[@]}")
            fi
            ;;
        5) : ;; # nimic — păstrează ordinea selectiei
    esac

    # Show final order
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  Ordine concat:                              ║"
    local total_s=0
    for ((i=0; i<${#selected[@]}; i++)); do
        local d; d=$(get_duration_seconds "${selected[$i]}")
        total_s=$((total_s + d))
        printf "║  %2d. %-32s %s\n" "$((i+1))" "$(basename "${selected[$i]}" | cut -c1-32)" "$(format_seconds "$d")"
    done
    echo "║  Durata totala: $(format_seconds "$total_s")"
    echo "╚══════════════════════════════════════════════╝"

    # Preview thumbnails (opt-in)
    echo ""
    read -p "Generezi preview thumbnails (3-frame tile per fisier)? (d/n) [default: n]: " pv
    if [[ "${pv,,}" == "d" ]]; then
        generate_preview_thumbnails "${selected[@]}"
    fi

    # Output filename
    local ts; ts=$(date +%Y%m%d_%H%M%S)
    read -p "Nume fisier output (fara extensie) [default: concat_${ts}]: " out_name
    [[ -z "$out_name" ]] && out_name="concat_${ts}"

    # Container
    echo ""
    echo "Container output:"
    echo "  1) mkv [default — flexibil, orice codec]"
    echo "  2) mp4"
    echo "  3) mov"
    read -p "Alege 1-3 [default: 1]: " cont_ch
    local container="mkv"
    [[ "$cont_ch" == "2" ]] && container="mp4"
    [[ "$cont_ch" == "3" ]] && container="mov"

    mkdir -p "$OUTPUT_DIR" 2>/dev/null
    local out_path="${OUTPUT_DIR}/${out_name}.${container}"
    out_path=$(resolve_output_collision "$out_path")

    # Compat check
    echo ""
    echo "  Verific compatibilitate codec/rez/fps/pix_fmt..."
    local use_filter=0
    if check_concat_compat "${selected[@]}"; then
        echo "  ✓ Fisierele sunt identice — pot folosi stream copy."
        echo ""
        echo "  1) Stream copy (concat demuxer, instant, lossless) [default]"
        echo "  2) Re-encode (compresie suplimentara)"
        read -p "  Alege 1-2: " cmode
        [[ "$cmode" == "2" ]] && use_filter=1
    else
        echo "  ⚠ Fisierele NU sunt identice (codec/rez/fps/pix_fmt difera)."
        echo "  Re-encode OBLIGATORIU via concat filter."
        use_filter=1
    fi

    # Create temp subdir pt concat.txt
    local subdir; subdir=$(create_temp_subdir "concat")
    termux-wake-lock 2>/dev/null

    if (( use_filter == 0 )); then
        # Stream copy concat demuxer
        local concat_txt="${subdir}/concat.txt"
        : > "$concat_txt"
        for f in "${selected[@]}"; do
            # Escape apostrofuri în path: ' → '\''
            local esc="${f//\'/\'\\\'\'}"
            echo "file '${esc}'" >> "$concat_txt"
        done
        echo "  Concat stream copy..."
        run_ffmpeg_with_progress "Concat (copy)" "$total_s" \
            -y -f concat -safe 0 -i "$concat_txt" \
            -map 0 -map_metadata 0 -c copy \
            -avoid_negative_ts make_zero \
            "$out_path"
    else
        # Re-encode via concat filter
        echo ""
        echo "  Re-encode: 1-libx265 [default]  2-libx264"
        read -p "  Codec: " ec
        local codec="libx265"; [[ "$ec" == "2" ]] && codec="libx264"
        read -p "  CRF [default: 22]: " crf; [[ -z "$crf" ]] && crf=22
        echo "  Audio: 1-aac 192k [default]  2-eac3 224k  3-copy"
        read -p "  Alege: " ac
        local aopt=(-c:a aac -b:a 192k)
        [[ "$ac" == "2" ]] && aopt=(-c:a eac3 -b:a 224k)
        [[ "$ac" == "3" ]] && aopt=(-c:a copy)

        # Build -i pentru fiecare fișier + filter_complex
        local ff_in=() fc_map=""
        for ((i=0; i<${#selected[@]}; i++)); do
            ff_in+=(-i "${selected[$i]}")
            fc_map+="[${i}:v:0][${i}:a:0?]"
        done
        local n=${#selected[@]}
        local fc="${fc_map}concat=n=${n}:v=1:a=1[outv][outa]"

        echo "  Concat re-encode ($codec CRF $crf)... durata totala $(format_seconds "$total_s")"
        run_ffmpeg_with_progress "Concat ($codec)" "$total_s" \
            -y "${ff_in[@]}" \
            -filter_complex "$fc" \
            -map "[outv]" -map "[outa]" \
            -c:v "$codec" -crf "$crf" -preset medium \
            "${aopt[@]}" \
            -map_metadata 0 \
            "$out_path"
    fi

    termux-wake-unlock 2>/dev/null

    # Cleanup
    cleanup_temp_subdir "$subdir" "$out_path"

    if [[ -f "$out_path" && -s "$out_path" ]]; then
        local osize; osize=$(stat -c%s "$out_path" 2>/dev/null || echo 0)
        echo ""
        echo "  ✓ Output: $out_path"
        echo "  ✓ Size: $(( osize/1024/1024 )) MB"
        echo "  ✓ Fisiere concatenate: ${#selected[@]}"
        echo "  ✓ Durata totala: $(format_seconds "$total_s")"
    fi
}

# ── Flow 3: Pipeline (Trim → Concat → Encode) ────────────────────────
trimconcat_flow_pipeline() {
    scan_input_videos
    if (( TC_COUNT == 0 )); then
        echo "Nu exista fisiere video in $INPUT_DIR"; return 1
    fi

    # Pas 1: selectie fisiere incluse in pipeline
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  PIPELINE — Selectare fisiere                ║"
    echo "╠══════════════════════════════════════════════╣"
    for ((i=0; i<TC_COUNT; i++)); do
        local f="${TC_FILES[$i]}" dur
        dur=$(get_duration_seconds "$f")
        printf "║  %2d) %-32s %s\n" "$((i+1))" "$(basename "$f" | cut -c1-32)" "$(format_seconds "$dur")"
    done
    echo "╚══════════════════════════════════════════════╝"
    echo "Exemple: all / 1,3,5 / 1-5 / 1-3,7,10-12"
    read -p "Selecteaza fisierele incluse: " sel_raw
    local indices; indices=($(expand_range_selection "$sel_raw" "$TC_COUNT"))
    if (( ${#indices[@]} == 0 )); then
        echo "Selectie invalida."; return 1
    fi

    # Array initial de fisiere selectate (in ordinea data de sort)
    local chosen=()
    for idx in "${indices[@]}"; do chosen+=("${TC_FILES[$((idx-1))]}"); done

    # Sort
    echo ""
    echo "Ordine fisiere:"
    echo "  1) Nume (alfabetic) [default]"
    echo "  2) Data modificare"
    echo "  3) Dimensiune"
    echo "  4) Manual (introdu ordinea)"
    echo "  5) Pastreaza ordinea selectiei"
    read -p "Alege 1-5 [default: 1]: " sort_mode
    [[ -z "$sort_mode" ]] && sort_mode=1
    case "$sort_mode" in
        1) local IFS=$'\n'
           chosen=($(for f in "${chosen[@]}"; do echo "$f"; done | sort))
           unset IFS ;;
        2) local IFS=$'\n'
           chosen=($(for f in "${chosen[@]}"; do printf "%s\t%s\n" "$(stat -c %Y "$f" 2>/dev/null)" "$f"; done | sort -n | cut -f2-))
           unset IFS ;;
        3) local IFS=$'\n'
           chosen=($(for f in "${chosen[@]}"; do printf "%s\t%s\n" "$(stat -c %s "$f" 2>/dev/null)" "$f"; done | sort -n | cut -f2-))
           unset IFS ;;
        4) echo ""
           for ((i=0; i<${#chosen[@]}; i++)); do
               echo "  $((i+1))) $(basename "${chosen[$i]}")"
           done
           read -p "Ordinea noua (ex: 3,1,2): " new_order
           local reordered=()
           IFS=',' read -ra parts <<< "$new_order"
           for p in "${parts[@]}"; do
               p="${p// /}"
               if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= ${#chosen[@]} )); then
                   reordered+=("${chosen[$((p-1))]}")
               fi
           done
           if (( ${#reordered[@]} == 0 )); then
               echo "Ordine invalida, pastrez ordinea initiala."
           else
               chosen=("${reordered[@]}")
           fi ;;
        5) : ;;
    esac

    # Pas 2: care din fisierele alese au nevoie de trim?
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  PIPELINE — Care fisiere au nevoie de TRIM?  ║"
    echo "╠══════════════════════════════════════════════╣"
    for ((i=0; i<${#chosen[@]}; i++)); do
        local f="${chosen[$i]}" dur
        dur=$(get_duration_seconds "$f")
        printf "║  %2d) %-32s %s\n" "$((i+1))" "$(basename "$f" | cut -c1-32)" "$(format_seconds "$dur")"
    done
    echo "╚══════════════════════════════════════════════╝"
    echo "Exemple: none / 1,3 / 1-2 / all"
    read -p "Indici: " trim_sel
    [[ -z "$trim_sel" ]] && trim_sel="none"

    local trim_indices=()
    if [[ "${trim_sel,,}" != "none" ]]; then
        trim_indices=($(expand_range_selection "$trim_sel" "${#chosen[@]}"))
    fi

    # Pentru fiecare fisier cu trim: colectez segmente (start_s,end_s)
    # segments[i] = "start1:end1,start2:end2,..." sau "" daca full file
    local segments=()
    for ((i=0; i<${#chosen[@]}; i++)); do segments+=(""); done

    for idx in "${trim_indices[@]}"; do
        local i=$((idx-1))
        local src="${chosen[$i]}" base; base=$(basename "$src")
        local total_s; total_s=$(get_duration_seconds "$src")
        local segs=""
        local cut_idx=1
        echo ""
        echo "╔══════════════════════════════════════════════╗"
        echo "║  TRIM — $base"
        echo "║  Durata totala: $(format_seconds "$total_s")"
        echo "╚══════════════════════════════════════════════╝"
        while true; do
            echo ""
            echo "  Segment #$cut_idx"
            local start_s end_s
            while true; do
                start_s=$(prompt_time_validated "Start" 0 "$total_s")
                end_s=$(prompt_time_validated "End  " "$total_s" "$total_s")
                if (( start_s >= end_s )); then
                    echo "  EROARE: start >= end. Reintrodu."; continue
                fi
                break
            done
            local clip_s=$(( end_s - start_s ))
            echo "  Segment: $(format_seconds "$clip_s") (din $(format_seconds "$start_s") la $(format_seconds "$end_s"))"
            if [[ -z "$segs" ]]; then segs="${start_s}:${end_s}"; else segs="${segs},${start_s}:${end_s}"; fi
            echo ""
            read -p "  Mai adaugi un segment din acest fisier? (d/n) [default: n]: " again
            if [[ "${again,,}" != "d" ]]; then break; fi
            cut_idx=$((cut_idx+1))
        done
        segments[$i]="$segs"
    done

    # Pas 3: setari encode (o singura data)
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  PIPELINE — Setari encode (global)           ║"
    echo "╚══════════════════════════════════════════════╝"
    echo "Mod encode:"
    echo "  1) Video + Audio re-encode [default]"
    echo "  2) Audio-only re-encode (video stream copy, instant)"
    read -p "Alege 1-2: " mode_ch
    local audio_only=0
    [[ "$mode_ch" == "2" ]] && audio_only=1
    local codec="libx265" crf=22 preset="medium"
    if (( audio_only == 0 )); then
        echo "Codec:"
        echo "  1) libx265 (HEVC) [default]"
        echo "  2) libx264 (H.264)"
        echo "  3) libsvtav1 (AV1)"
        read -p "Alege 1-3: " cc
        [[ "$cc" == "2" ]] && codec="libx264"
        [[ "$cc" == "3" ]] && codec="libsvtav1"
        read -p "CRF [default: 22]: " crf; [[ -z "$crf" ]] && crf=22
        echo "Preset:"
        echo "  1) medium [default]"
        echo "  2) slow (calitate mai buna)"
        echo "  3) fast"
        read -p "Alege 1-3: " pp
        [[ "$pp" == "2" ]] && preset="slow"
        [[ "$pp" == "3" ]] && preset="fast"
    else
        echo "  → Video: stream copy. Defaults fallback (dacă incompat): libx265 CRF 22 medium"
    fi
    echo "Audio:"
    echo "  1) aac 192k [default]"
    echo "  2) eac3 224k"
    echo "  3) copy"
    read -p "Alege 1-3: " ac
    local aopt=(-c:a aac -b:a 192k)
    [[ "$ac" == "2" ]] && aopt=(-c:a eac3 -b:a 224k)
    [[ "$ac" == "3" ]] && aopt=(-c:a copy)

    # Pas 4: output name + container
    local ts; ts=$(date +%Y%m%d_%H%M%S)
    echo ""
    read -p "Nume fisier output (fara extensie) [default: pipeline_${ts}]: " out_name
    [[ -z "$out_name" ]] && out_name="pipeline_${ts}"
    echo "Container output:"
    echo "  1) mkv [default]"
    echo "  2) mp4"
    echo "  3) mov"
    read -p "Alege 1-3: " cont_ch
    local container="mkv"
    [[ "$cont_ch" == "2" ]] && container="mp4"
    [[ "$cont_ch" == "3" ]] && container="mov"

    echo "Capitole automate (1 capitol per segment, marker timeline)?"
    echo "  1) Da [default]"
    echo "  2) Nu"
    read -p "Alege 1-2: " ch_ch
    local make_chapters=1
    [[ "$ch_ch" == "2" ]] && make_chapters=0

    mkdir -p "$OUTPUT_DIR" 2>/dev/null
    local out_path="${OUTPUT_DIR}/${out_name}.${container}"
    out_path=$(resolve_output_collision "$out_path")

    # Estimare temp size: doar segmentele trimuite (FULL files merg direct in concat.txt)
    local est_temp_mb=0
    local pipeline_total_s=0
    for ((i=0; i<${#chosen[@]}; i++)); do
        local f="${chosen[$i]}" segs="${segments[$i]}"
        local fsize; fsize=$(stat -c%s "$f" 2>/dev/null || echo 0)
        local fdur; fdur=$(get_duration_seconds "$f")
        if [[ -z "$segs" ]]; then
            # FULL file — referinta directa in concat.txt, nu ocupa temp
            pipeline_total_s=$(( pipeline_total_s + fdur ))
        else
            IFS=',' read -ra parts <<< "$segs"
            for seg in "${parts[@]}"; do
                local ss="${seg%:*}" ee="${seg#*:}"
                local sdur=$(( ee - ss ))
                pipeline_total_s=$(( pipeline_total_s + sdur ))
                if (( fdur > 0 )); then
                    est_temp_mb=$(( est_temp_mb + (fsize/1024/1024) * sdur / fdur ))
                fi
            done
        fi
    done

    # Pas 5: pre-execution summary
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  PIPELINE — Rezumat pre-executie             ║"
    echo "╠══════════════════════════════════════════════╣"
    for ((i=0; i<${#chosen[@]}; i++)); do
        local f="${chosen[$i]}" segs="${segments[$i]}"
        local nm; nm=$(basename "$f" | cut -c1-30)
        if [[ -z "$segs" ]]; then
            printf "║  %2d. %-30s [FULL]\n" "$((i+1))" "$nm"
        else
            local nseg=0
            IFS=',' read -ra parts <<< "$segs"
            nseg=${#parts[@]}
            printf "║  %2d. %-30s [TRIM x%d]\n" "$((i+1))" "$nm" "$nseg"
        fi
    done
    echo "║"
    echo "║  Durata finala estimata: $(format_seconds "$pipeline_total_s")"
    echo "║  Temp estimat: ~${est_temp_mb} MB"
    if (( audio_only == 1 )); then
        echo "║  Encode: AUDIO-ONLY (video stream copy)"
    else
        echo "║  Encode: $codec CRF $crf ($preset)"
    fi
    echo "║  Output: $(basename "$out_path")"
    echo "╚══════════════════════════════════════════════╝"

    # HDR info (v37: detecția detaliată + auto-injectare se face pre-Pass 3)
    if tc_check_hdr_files "${chosen[@]}"; then
        echo ""
        echo "  ℹ HDR detectat în input — modul HDR va fi auto-detectat înainte de Pass 3."
        if (( audio_only == 0 )) && [[ "$codec" != "libx265" ]]; then
            echo "    ATENTIE: codec=$codec nu suporta HDR10 — output va fi SDR-like."
        fi
    fi

    # Preview thumbnails (opt-in)
    echo ""
    read -p "Generezi preview thumbnails (3-frame tile per fisier)? (d/n) [default: n]: " pv
    if [[ "${pv,,}" == "d" ]]; then
        generate_preview_thumbnails "${chosen[@]}"
    fi

    read -p "Continua? (d/n) [default: d]: " go
    if [[ "${go,,}" == "n" ]]; then echo "Anulat."; return 0; fi

    # Pas 6: executie
    local subdir; subdir=$(create_temp_subdir "pipeline")
    termux-wake-lock 2>/dev/null

    # Pass 1/3: trim fiecare fisier ce are segmente → $subdir/NN_segM.ext
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "  [Pass 1/3] Trim stream copy"
    echo "═══════════════════════════════════════════════"
    local trimmed_files=()
    local seg_durations=()
    for ((i=0; i<${#chosen[@]}; i++)); do
        local f="${chosen[$i]}" segs="${segments[$i]}"
        local ext="${f##*.}"
        if [[ -z "$segs" ]]; then
            # Full file — nu trimuim, folosim sursa direct
            trimmed_files+=("$f")
            seg_durations+=("$(get_duration_seconds "$f")")
            echo "  [$((i+1))/${#chosen[@]}] $(basename "$f") — FULL (fara trim)"
        else
            IFS=',' read -ra parts <<< "$segs"
            local si=1
            for seg in "${parts[@]}"; do
                local ss="${seg%:*}" ee="${seg#*:}"
                local seg_out=$(printf "%s/%02d_seg%d.%s" "$subdir" "$((i+1))" "$si" "$ext")
                echo "  [$((i+1))/${#chosen[@]}] $(basename "$f") seg$si: $(format_seconds "$ss") → $(format_seconds "$ee")"
                ffmpeg -y -ss "$ss" -to "$ee" -i "$f" \
                    -map 0 -map_metadata 0 -c copy \
                    -avoid_negative_ts make_zero -copyts \
                    "$seg_out" 2>&1 | tail -3
                if [[ -f "$seg_out" && -s "$seg_out" ]]; then
                    trimmed_files+=("$seg_out")
                    # v37: foloseste durata REALA a segmentului trimuit (keyframe snap)
                    # pentru capitole precise — fallback la (ee-ss) daca probe esueaza.
                    local _real; _real=$(get_duration_seconds "$seg_out")
                    [[ -z "$_real" || "$_real" -le 0 ]] && _real=$((ee - ss))
                    seg_durations+=("$_real")
                else
                    echo "  ✗ EROARE trim: $seg_out"
                    cleanup_temp_subdir "$subdir" ""
                    termux-wake-unlock 2>/dev/null
                    return 1
                fi
                si=$((si+1))
            done
        fi
    done

    if (( ${#trimmed_files[@]} == 0 )); then
        echo "Nu s-au generat fisiere pentru concat."
        cleanup_temp_subdir "$subdir" ""
        termux-wake-unlock 2>/dev/null
        return 1
    fi

    # Pass 2/3: verific compat signature + pregatire concat
    echo ""
    echo "═══════════════════════════════════════════════"
    echo "  [Pass 2/3] Verificare compat + pregatire concat"
    echo "═══════════════════════════════════════════════"
    local use_filter=0
    local smart_copy=0
    if ! check_concat_compat "${trimmed_files[@]}"; then
        use_filter=1
        echo "  ⚠ Fisiere cu codec/rez/fps diferit — folosesc concat filter"
        if (( audio_only == 1 )); then
            echo "  ⚠ Audio-only mode: concat filter cere video re-encode."
            echo "  → Fallback la full re-encode ($codec CRF $crf $preset)."
            audio_only=0
        fi
        if [[ "${aopt[0]}" == "-c:a" && "${aopt[1]}" == "copy" ]]; then
            echo "  ⚠ Audio copy nu functioneaza cu concat filter. Fallback: aac 192k."
            aopt=(-c:a aac -b:a 192k)
        fi
    else
        # Smart stream copy detection (dacă nu e audio-only): sursa = target codec → oferă skip re-encode
        if (( audio_only == 0 )); then
            local src_codec; src_codec=$(ffprobe -v error -select_streams v:0 \
                -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 \
                "${trimmed_files[0]}" 2>/dev/null)
            local target_codec_name=""
            case "$codec" in
                libx265) target_codec_name="hevc" ;;
                libx264) target_codec_name="h264" ;;
                libsvtav1|libaom-av1) target_codec_name="av1" ;;
            esac
            if [[ -n "$target_codec_name" && "$src_codec" == "$target_codec_name" ]]; then
                echo ""
                echo "  ⚡ SMART COPY: sursa este deja $src_codec, identic cu targetul ($codec)."
                echo "    Stream copy direct → instant, lossless, fără re-encode."
                read -p "  Folosesti stream copy in loc de re-encode? (D/n) [default: D]: " sc
                if [[ "${sc,,}" != "n" ]]; then
                    smart_copy=1
                fi
            fi
        fi
        local concat_txt="${subdir}/concat.txt"
        : > "$concat_txt"
        for f in "${trimmed_files[@]}"; do
            local esc="${f//\'/\'\\\'\'}"
            echo "file '${esc}'" >> "$concat_txt"
        done
        echo "  ${#trimmed_files[@]} intrari in $concat_txt"
    fi

    # Generare chapters file (FFMETADATA1) dacă user a optat și avem >=2 segmente
    local chapters_file=""
    local chap_in=() chap_map=()
    if (( make_chapters == 1 && ${#trimmed_files[@]} >= 2 )); then
        chapters_file="${subdir}/chapters.txt"
        echo ";FFMETADATA1" > "$chapters_file"
        local cum_ms=0
        for ((i=0; i<${#trimmed_files[@]}; i++)); do
            local d_ms=$(( ${seg_durations[$i]} * 1000 ))
            local end_ms=$(( cum_ms + d_ms ))
            {
                echo ""
                echo "[CHAPTER]"
                echo "TIMEBASE=1/1000"
                echo "START=$cum_ms"
                echo "END=$end_ms"
                echo "title=Segment $((i+1))"
            } >> "$chapters_file"
            cum_ms=$end_ms
        done
        echo "  ✓ Capitole generate: ${#trimmed_files[@]} markeri în $(basename "$chapters_file")"
    fi

    # HDR-aware (v37): detectare mod HDR + injectare params x265 dacă re-encode
    local hdr_color_args=()
    local hdr_x265_extra=""
    local hdr_pix_fmt=""
    if (( smart_copy == 0 && audio_only == 0 )); then
        local hdr_mode; hdr_mode=$(detect_pipeline_hdr_mode "${chosen[@]}")
        case "$hdr_mode" in
            sdr) : ;;
            mixed)
                echo ""
                echo "  ⚠ HDR MIXED: input contine atat SDR cat si HDR (smpte2084/HLG)."
                echo "    HDR metadata NU va fi pastrat. Output = SDR-like."
                ;;
            hdr10|hdr10plus|hlg|dv)
                if [[ "$codec" != "libx265" ]]; then
                    echo ""
                    echo "  ⚠ HDR detectat ($hdr_mode), dar codec=$codec nu suporta HDR10."
                    echo "    HDR metadata NU va fi pastrat. Pentru HDR10, foloseste libx265."
                else
                    local trc="smpte2084"
                    [[ "$hdr_mode" == "hlg" ]] && trc="arib-std-b67"
                    hdr_pix_fmt="yuv420p10le"
                    hdr_color_args=(-color_primaries bt2020 -color_trc "$trc" -colorspace bt2020nc)
                    hdr_x265_extra="hdr10=1:hdr10-opt=1:repeat-headers=1:colorprim=bt2020:transfer=$trc:colormatrix=bt2020nc"
                    if [[ "$hdr_mode" == "dv" ]]; then
                        echo ""
                        echo "  ⚠ DOLBY VISION detectat. Re-encode -> fallback HDR10 (DV RPU nu se pastreaza)."
                    elif [[ "$hdr_mode" == "hdr10plus" ]]; then
                        echo ""
                        echo "  ⚡ HDR10+ detectat. Vrei sa pastrezi metadata dinamica? (necesita hdr10plus_tool)"
                        echo "     1) Da [default]   2) Nu (doar HDR10 static)"
                        read -p "     Alege 1-2: " hdr10p_ch
                        if [[ "${hdr10p_ch:-1}" == "1" ]]; then
                            if _check_hdr10plus_tool; then
                                local hdr10p_json
                                hdr10p_json=$(extract_hdr10plus_metadata "${trimmed_files[0]}")
                                if [[ -n "$hdr10p_json" && -s "$hdr10p_json" ]]; then
                                    hdr_x265_extra="${hdr_x265_extra}:dhdr10-info=${hdr10p_json}"
                                    echo "     ✓ HDR10+ JSON extras: $hdr10p_json"
                                else
                                    echo "     ⚠ Extragere HDR10+ esuata. Fallback HDR10 static."
                                fi
                            else
                                echo "     ⚠ hdr10plus_tool NU este instalat. Fallback HDR10 static."
                                echo "       Instaleaza: $TOOLS_DIR/hdr10plus_parser.sh"
                            fi
                        fi
                    else
                        echo ""
                        echo "  ⚡ AUTO HDR10: pix_fmt=$hdr_pix_fmt, transfer=$trc, color=bt2020"
                    fi
                fi
                ;;
        esac
    fi

    # Pass 3/3: concat + re-encode (sau stream copy dacă smart_copy=1, sau audio-only)
    echo ""
    echo "═══════════════════════════════════════════════"
    if (( smart_copy == 1 )); then
        echo "  [Pass 3/3] Concat stream copy (smart)"
    elif (( audio_only == 1 )); then
        echo "  [Pass 3/3] Concat + Audio re-encode (video copy)"
    else
        echo "  [Pass 3/3] Concat + Encode ($codec CRF $crf, $preset)"
    fi
    echo "═══════════════════════════════════════════════"
    echo "  Durata totala: $(format_seconds "$pipeline_total_s")"

    # Build HDR args pentru ffmpeg call (pix_fmt + color_* + x265-params)
    local hdr_pix_args=()
    [[ -n "$hdr_pix_fmt" ]] && hdr_pix_args=(-pix_fmt "$hdr_pix_fmt")
    local hdr_x265_args=()
    [[ -n "$hdr_x265_extra" ]] && hdr_x265_args=(-x265-params "$hdr_x265_extra")
    if (( smart_copy == 1 )); then
        chap_in=(); chap_map=()
        if [[ -n "$chapters_file" ]]; then chap_in=(-i "$chapters_file"); chap_map=(-map_chapters 1); fi
        run_ffmpeg_with_progress "Pass 3/3 (copy)" "$pipeline_total_s" \
            -y -f concat -safe 0 -i "$concat_txt" "${chap_in[@]}" \
            -map 0 -map_metadata 0 "${chap_map[@]}" -c copy \
            -avoid_negative_ts make_zero \
            "$out_path"
    elif (( audio_only == 1 )); then
        chap_in=(); chap_map=()
        if [[ -n "$chapters_file" ]]; then chap_in=(-i "$chapters_file"); chap_map=(-map_chapters 1); fi
        run_ffmpeg_with_progress "Pass 3/3 (audio-only)" "$pipeline_total_s" \
            -y -f concat -safe 0 -i "$concat_txt" "${chap_in[@]}" \
            -map 0 -map_metadata 0 "${chap_map[@]}" -c:v copy \
            "${aopt[@]}" \
            -avoid_negative_ts make_zero \
            "$out_path"
    elif (( use_filter == 1 )); then
        local ff_in=() fc_map=""
        for ((i=0; i<${#trimmed_files[@]}; i++)); do
            ff_in+=(-i "${trimmed_files[$i]}")
            fc_map+="[${i}:v:0][${i}:a:0?]"
        done
        local n=${#trimmed_files[@]}
        local fc="${fc_map}concat=n=${n}:v=1:a=1[outv][outa]"
        chap_in=(); chap_map=()
        if [[ -n "$chapters_file" ]]; then chap_in=(-i "$chapters_file"); chap_map=(-map_chapters "$n"); fi
        run_ffmpeg_with_progress "Pass 3/3 ($codec)" "$pipeline_total_s" \
            -y "${ff_in[@]}" "${chap_in[@]}" \
            -filter_complex "$fc" \
            -map "[outv]" -map "[outa]" "${chap_map[@]}" \
            -c:v "$codec" -crf "$crf" -preset "$preset" \
            "${hdr_pix_args[@]}" "${hdr_color_args[@]}" "${hdr_x265_args[@]}" \
            "${aopt[@]}" \
            -map_metadata 0 \
            "$out_path"
    else
        chap_in=(); chap_map=()
        if [[ -n "$chapters_file" ]]; then chap_in=(-i "$chapters_file"); chap_map=(-map_chapters 1); fi
        run_ffmpeg_with_progress "Pass 3/3 ($codec)" "$pipeline_total_s" \
            -y -f concat -safe 0 -i "$concat_txt" "${chap_in[@]}" \
            -map 0 -map_metadata 0 "${chap_map[@]}" \
            -c:v "$codec" -crf "$crf" -preset "$preset" \
            "${hdr_pix_args[@]}" "${hdr_color_args[@]}" "${hdr_x265_args[@]}" \
            "${aopt[@]}" \
            "$out_path"
    fi

    termux-wake-unlock 2>/dev/null

    # Cleanup
    cleanup_temp_subdir "$subdir" "$out_path"

    # Stats finale
    if [[ -f "$out_path" && -s "$out_path" ]]; then
        local osize; osize=$(stat -c%s "$out_path" 2>/dev/null || echo 0)
        local tot_in=0
        for ((i=0; i<${#chosen[@]}; i++)); do
            local fs; fs=$(stat -c%s "${chosen[$i]}" 2>/dev/null || echo 0)
            tot_in=$(( tot_in + fs ))
        done
        local ratio=0
        (( tot_in > 0 )) && ratio=$(( osize * 100 / tot_in ))
        echo ""
        echo "╔══════════════════════════════════════════════╗"
        echo "║  PIPELINE — Terminat                         ║"
        echo "╠══════════════════════════════════════════════╣"
        echo "║  ✓ Output: $(basename "$out_path")"
        echo "║  ✓ Size: $(( osize/1024/1024 )) MB (input: $(( tot_in/1024/1024 )) MB, ${ratio}%)"
        echo "║  ✓ Durata: $(format_seconds "$pipeline_total_s")"
        echo "║  ✓ Fisiere sursa: ${#chosen[@]}, segmente: ${#trimmed_files[@]}"
        echo "╚══════════════════════════════════════════════╝"
    else
        echo "  ✗ EROARE: output final lipsa sau 0 bytes."
    fi
}
