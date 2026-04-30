#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# av_check.sh — Analiza completa fisiere video + audio, export CSV
#
# Script standalone — nu source-uieste common_functions.sh intentionat,
# deoarece ruleaza independent de fluxul encode.
# get_dv_profile() este copie locala din common_functions.sh — aceasta
# este intentionata; modificarile in comun trebuie replicate manual.
# ══════════════════════════════════════════════════════════════════════

# v41: Source av_common.sh pentru detect_platform + paths cross-platform + wrappere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/av_common.sh"

CSV_FILE="$OUTPUT_DIR/av_check_report.csv"

mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"

echo "Folder input: $INPUT_DIR"
echo "─────────────────────────────────────"

# FIX: shopt -u reseteaza si nullglob, nu doar nocaseglob
shopt -s nullglob nocaseglob
FILES=("$INPUT_DIR"/*.{mp4,mov,mkv,m2ts,mts,vob,mxf,apv})
shopt -u nocaseglob nullglob
TOTAL=${#FILES[@]}

if [ "$TOTAL" -eq 0 ]; then
    echo "Nu am gasit fisiere in $INPUT_DIR"; exit 1
fi

echo "Fisier,Format_sursa,Dimensiune(MB),Durata(sec),Rezolutie,PixelFormat,FPS,Bitrate_video(Mbps),Tip_HDR,Profil_DV,Log_Profile,Codec_audio,Bitrate_audio(kbps),SampleRate(kHz),BitDepth,Layout_canale,Limba_audio,Canale_audio,AudioTrackuri,Subtitrari,Capitole,Attachments,DJI_djmd,DJI_dbgi,DJI_Timecode,Recomandat_encoder,Est_x265,Est_x264,Est_AV1,Est_ProRes" \
    > "$CSV_FILE"

# ── Format sursa — primeste date deja extrase, fara ffprobe suplimentar ─
get_source_format() {
    local codec="$1" pix_fmt="$2" transfer="$3" hdr_plus_found="$4"
    local is_10bit=0 is_hdr=0 is_hdrplus=0 is_hlg=0
    [[ "$pix_fmt"        == *10*        ]] && is_10bit=1
    [[ "$transfer"       == "smpte2084" ]] && is_hdr=1
    [[ "$transfer"       == "arib-std-b67" ]] && is_hlg=1
    [[ "$hdr_plus_found" == "1"         ]] && is_hdrplus=1 && is_hdr=1
    local fmt
    case "$codec" in
        h264) [ $is_10bit -eq 1 ] && fmt="H.264 10bit" || fmt="H.264 8bit" ;;
        hevc)
            if   [ $is_hdrplus -eq 1 ]; then fmt="H.265 HEVC HDR10+"
            elif [ $is_hdr -eq 1 ];     then fmt="H.265 HEVC HDR10"
            elif [ $is_hlg -eq 1 ];     then fmt="H.265 HEVC HLG"
            elif [ $is_10bit -eq 1 ];   then fmt="H.265 HEVC 10bit SDR"
            else                             fmt="H.265 HEVC 8bit SDR"; fi ;;
        av1)
            if   [ $is_hdrplus -eq 1 ]; then fmt="AV1 HDR10+"
            elif [ $is_hdr -eq 1 ];     then fmt="AV1 HDR10"
            elif [ $is_hlg -eq 1 ];     then fmt="AV1 HLG"
            elif [ $is_10bit -eq 1 ];   then fmt="AV1 10bit SDR"
            else                             fmt="AV1 8bit SDR"; fi ;;
        vp9)        [ $is_10bit -eq 1 ] && fmt="VP9 10bit"      || fmt="VP9 8bit" ;;
        mpeg4)      fmt="MPEG-4" ;;
        mpeg2video) fmt="MPEG-2" ;;
        prores)     fmt="Apple ProRes" ;;
        apv)        fmt="Samsung APV" ;;
        *)          [ $is_10bit -eq 1 ] && fmt="$codec 10bit"   || fmt="$codec 8bit" ;;
    esac
    echo "$fmt"
}

# ── Profil DV — copie locala intentionata din common_functions.sh ─────
# Aceasta functie este intentionat duplicata (check_video e script standalone).
# Daca se modifica get_dv_profile in common_functions.sh, replica aici.
get_dv_profile() {
    local file="$1"
    local dv_info dv_profile_num dv_compat
    dv_info=$(ffprobe -v error -show_frames -select_streams v:0 \
        -read_intervals 0%+#5 \
        -show_entries frame_side_data=dv_profile,dv_bl_signal_compatibility_id \
        -of default "$file" 2>/dev/null)
    dv_profile_num=$(echo "$dv_info" | grep "dv_profile=" \
        | head -1 | cut -d= -f2 | tr -d '[:space:]')
    dv_compat=$(echo "$dv_info" | grep "dv_bl_signal_compatibility_id=" \
        | head -1 | cut -d= -f2 | tr -d '[:space:]')
    if [[ -n "$dv_profile_num" && "$dv_profile_num" =~ ^[0-9]+$ ]]; then
        case "$dv_profile_num" in
            4) echo "Profil 4 (DV + HDR10)" ;;
            5) echo "Profil 5 (DV only)" ;;
            7) echo "Profil 7 (DV + HDR10+)" ;;
            8) case "$dv_compat" in
                1) echo "Profil 8.1 (DV + HDR10, Blu-ray)" ;;
                2) echo "Profil 8.2 (DV + SDR)" ;;
                4) echo "Profil 8.4 (DV + HLG)" ;;
                *) echo "Profil 8 (DV + HDR10)" ;; esac ;;
            9) echo "Profil 9 (DV + SDR)" ;;
            *) echo "Profil $dv_profile_num" ;;
        esac
    else
        local codec_tag
        codec_tag=$(ffprobe -v error -show_entries stream=codec_tag_string \
            -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -5)
        case "$codec_tag" in
            *dvhe*) echo "Profil 8 (dvhe)" ;;
            *dvh1*) echo "Profil 8 (dvh1)" ;;
            *)      echo "Dolby Vision (profil nedetectat)" ;;
        esac
    fi
}

# ── Subtitrari — un singur ffprobe cu index + language ────────────────
get_subtitles_info() {
    local file="$1"
    local count=0 langs="" line
    while IFS= read -r line; do
        if   [[ "$line" =~ ^index= ]];             then count=$((count + 1))
        elif [[ "$line" =~ ^TAG:language=(.+)$ ]]; then
            local lang="${BASH_REMATCH[1]}"
            [[ -n "$lang" && "$lang" != "und" ]] && langs="$langs $lang"
        fi
    done < <(ffprobe -v error -select_streams s \
        -show_entries stream=index:stream_tags=language \
        -of default=noprint_wrappers=1 "$file" 2>/dev/null)
    if [ "$count" -eq 0 ]; then echo "Nu"; return; fi
    langs=$(echo "$langs" | xargs | tr ' ' '/')
    [ -n "$langs" ] && echo "${count} (${langs})" || echo "$count"
}

# ── Capitole ──────────────────────────────────────────────────────────
get_chapters_info() {
    local count
    count=$(ffprobe -v error -show_chapters "$1" 2>/dev/null | grep -c "^\[CHAPTER\]")
    [ "$count" -eq 0 ] && echo "Nu" || echo "$count capitole"
}

# ── Attachments — un singur ffprobe cu index + mimetype ───────────────
get_attachments_info() {
    local file="$1"
    local count=0 mimes="" line
    while IFS= read -r line; do
        if   [[ "$line" =~ ^index= ]];             then count=$((count + 1))
        elif [[ "$line" =~ ^TAG:mimetype=(.+)$ ]]; then
            local mime="${BASH_REMATCH[1]}"
            [[ -n "$mime" ]] && mimes="$mimes $mime"
        fi
    done < <(ffprobe -v error -select_streams t \
        -show_entries stream=index:stream_tags=mimetype \
        -of default=noprint_wrappers=1 "$file" 2>/dev/null)
    if [ "$count" -eq 0 ]; then echo "Nu"; return; fi
    mimes=$(echo "$mimes" | xargs)
    [ -n "$mimes" ] && echo "${count} (${mimes})" || echo "$count"
}

# ── DJI tracks — un singur ffprobe, tmcd in codec_name ────────────────
get_dji_tracks_info() {
    local file="$1" has_djmd=0 has_dbgi=0 has_tc=0
    local tracks
    tracks=$(ffprobe -v error \
        -show_entries stream=codec_tag_string,codec_name,codec_type \
        -of default=noprint_wrappers=1 "$file" 2>/dev/null)
    echo "$tracks" | grep -qi "djmd" && has_djmd=1
    echo "$tracks" | grep -qi "dbgi" && has_dbgi=1
    echo "$tracks" | grep -qi "tmcd" && has_tc=1
    echo "${has_djmd}|${has_dbgi}|${has_tc}"
}

# ── LOG profile detect (standalone version — no source av_common.sh) ──
get_log_profile() {
    local file="$1" is_dji="$2"
    local log_profile="" camera_make=""
    local all_tags src_bps src_primaries src_trc

    all_tags=$(ffprobe -v error -show_entries format_tags \
        -of default=noprint_wrappers=1 "$file" 2>/dev/null)
    if echo "$all_tags" | grep -qi "make=.*apple"; then camera_make="apple"
    elif echo "$all_tags" | grep -qi "make=.*dji"; then camera_make="dji"
    elif echo "$all_tags" | grep -qi "manufacturer=.*samsung\|make=.*samsung"; then camera_make="samsung"
    fi
    [[ -z "$camera_make" ]] && [[ "$is_dji" -eq 1 ]] && camera_make="dji"

    src_trc=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=color_transfer \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1)
    src_bps=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=bits_per_raw_sample \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1)
    [[ ! "$src_bps" =~ ^[0-9]+$ ]] && src_bps=8
    src_primaries=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=color_primaries \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1)

    local transfer hdr_plus_local dovi_local
    transfer=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1)
    hdr_plus_local=$(ffprobe -v error -read_intervals 0%+#5 -show_frames -select_streams v:0 \
        -show_entries frame_side_data=type "$file" 2>/dev/null | grep -m1 "HDR10+")
    dovi_local=$(ffprobe -v error -show_entries stream=codec_tag_string \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | grep -i "dovi\|dvhe\|dvh1" | head -1)

    if [[ "$camera_make" == "apple" ]]; then
        if [[ "$src_bps" -ge 10 ]] && [[ "$src_primaries" == *"bt2020"* || "$src_trc" == *"arib"* || "$src_trc" == *"log"* ]]; then
            log_profile="Apple Log (iPhone)"
        fi
    elif [[ "$camera_make" == "samsung" ]]; then
        if [[ "$src_bps" -ge 10 ]] && [[ "$src_primaries" == *"bt2020"* ]]; then
            if [[ -z "$hdr_plus_local" ]] && [[ "$transfer" != *"smpte2084"* ]]; then
                log_profile="Samsung Log (S24 Ultra)"
            fi
        fi
    elif [[ "$camera_make" == "dji" ]]; then
        if [[ "$src_bps" -ge 10 ]] && [[ "$src_primaries" == *"bt2020"* ]]; then
            log_profile="D-Log M (DJI)"
        fi
    elif [[ "$src_bps" -ge 10 ]] && [[ "$src_primaries" == *"bt2020"* ]] \
         && [[ -z "$hdr_plus_local" ]] && [[ "$transfer" != *"smpte2084"* ]] && [[ -z "$dovi_local" ]]; then
        if [[ "$src_trc" == "unknown" || "$src_trc" == *"log"* || "$src_trc" == *"arib"* ]]; then
            log_profile="LOG (brand necunoscut)"
        fi
    fi
    echo "${log_profile:-N/A}"
}

# ── Recomandare encoder ───────────────────────────────────────────────
get_encoder_recommendation() {
    local src_fmt="$1" type_hdr="$2" is_dji="$3"
    if [[ "$type_hdr" == "Dolby Vision" ]]; then
        echo "libx265 (singurul care suporta DV)"; return
    fi
    if [ "$is_dji" -eq 1 ]; then
        [[ "$type_hdr" == *"HDR"* || "$type_hdr" == "HLG" ]] \
            && echo "libx265 (HDR/HLG DJI — compresie buna, metadata pastrate)" \
            || echo "libx265 sau AV1/SVT (SDR DJI — AV1 ~30% mai mic)"
        return
    fi
    if   [[ "$type_hdr" == "HDR10+" ]];                              then echo "libx265 (HDR10+ metadata native)"
    elif [[ "$type_hdr" == "HDR10" ]];                               then echo "libx265 sau AV1/SVT (ambele suporta HDR10)"
    elif [[ "$type_hdr" == "HLG" ]];                                 then echo "libx265 sau AV1/SVT (HLG nativ — transfer=arib-std-b67)"
    elif [[ "$src_fmt"  == *"H.264"* ]];                             then echo "libx265 (H.264→H.265 ~40% mai mic) sau AV1 (~50%)"
    elif [[ "$src_fmt"  == *"HEVC"* ]] || [[ "$src_fmt" == *"H.265"* ]]; then echo "AV1/SVT (HEVC→AV1 ~20-30% mai mic)"
    elif [[ "$src_fmt"  == *"AV1"* ]];                               then echo "Deja AV1 — re-encode nu e recomandat"
    elif [[ "$src_fmt"  == *"ProRes"* ]];                            then echo "libx265 sau AV1 (ProRes→compresie ~70-80% mai mic)"
    elif [[ "$src_fmt"  == *"APV"* ]];                               then echo "libx265 sau AV1 (APV→compresie ~70-80% mai mic)"
    elif [[ "$src_fmt"  == *"DNxH"* ]];                              then echo "libx265 sau AV1 (DNxHR→compresie ~70-80% mai mic)"
    elif [[ "$src_fmt"  == *"DNxH"* ]];                              then echo "libx265 sau AV1 (DNxHR→compresie ~80% mai mic)"
    else                                                                  echo "libx265 (optiune sigura universala)"; fi
}

# ── Estimare dimensiune output ────────────────────────────────────────
get_output_size_estimate() {
    local type_hdr="$1" width="$2" duration_sec="$3" encoder="$4"
    [[ ! "$duration_sec" =~ ^[0-9]+$ ]] && echo "N/A" && return
    [ "$duration_sec" -le 0 ]           && echo "N/A" && return
    [[ ! "$width" =~ ^[0-9]+$ ]]        && echo "N/A" && return
    local target_bps
    if   [[ "$encoder" == "av1" ]]; then
        if   [ "$width" -ge 3840 ]; then target_bps=8000000
        elif [ "$width" -ge 1920 ]; then target_bps=3000000
        else                             target_bps=1500000; fi
        [[ "$type_hdr" == *"HDR"* || "$type_hdr" == "Dolby Vision" || "$type_hdr" == "HLG" ]] && \
            target_bps=$((target_bps * 130 / 100))
    elif [[ "$encoder" == "x264" ]]; then
        if   [ "$width" -ge 3840 ]; then target_bps=12000000
        elif [ "$width" -ge 1920 ]; then target_bps=5000000
        else                             target_bps=2500000; fi
    elif [[ "$encoder" == "prores" ]]; then
        # ProRes HQ bitrate fix (~220 Mbps la 1080p, ~880 Mbps la 4K)
        if   [ "$width" -ge 3840 ]; then target_bps=880000000
        elif [ "$width" -ge 1920 ]; then target_bps=220000000
        else                             target_bps=110000000; fi
    else  # x265
        if   [ "$width" -ge 3840 ]; then target_bps=10000000
        elif [ "$width" -ge 1920 ]; then target_bps=4000000
        else                             target_bps=2000000; fi
        [[ "$type_hdr" == *"HDR"* || "$type_hdr" == "Dolby Vision" || "$type_hdr" == "HLG" ]] && \
            target_bps=$((target_bps * 130 / 100))
    fi
    # FIX: local si assignment pe linii separate — local masca exit code pe aceeasi linie
    local est_mb
    est_mb=$(( target_bps * duration_sec / 8 / 1024 / 1024 ))
    if [ "$est_mb" -ge 1024 ]; then
        awk -v mb="$est_mb" 'BEGIN{printf "~%.1f GB", mb/1024}'
    else
        echo "~${est_mb} MB"
    fi
}

# ══════════════════════════════════════════════════════════════════════
COUNT=0
IDX=0   # index pozitie in array (include fisierele sarite) — pentru progress corect

for file in "${FILES[@]}"; do
    [ -f "$file" ] || continue
    IDX=$((IDX + 1))
    filename=$(basename "$file")

    # ── ffprobe #1: parametri video de baza — un singur apel ─────────
    VIDEO_INFO=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name,width,height,pix_fmt,color_transfer,avg_frame_rate,bit_rate \
        -of csv=p=0 "$file" 2>/dev/null)
    # FIX: validare VIDEO_INFO gol inainte de COUNT++ — fisierele fara stream video
    # nu incrementeaza contorul si nu strica afisarea progresului
    if [ -z "$VIDEO_INFO" ]; then
        echo ""
        echo "  ATENTIE: $filename — nu s-a gasit stream video valid — sarit."
        continue
    fi

    COUNT=$((COUNT + 1))
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Analizam ($COUNT/$TOTAL): $filename"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    FILE_SIZE=$(av_stat_size "$file")

    IFS=',' read -r SRC_CODEC WIDTH HEIGHT PIX_FMT TRANSFER FPS_RAW BITRATE \
        <<< "$VIDEO_INFO"

    # ── ffprobe #2: audio detaliat — un singur apel ──────────────────
    AUDIO_INFO=$(ffprobe -v error -select_streams a:0 \
        -show_entries stream=codec_name,bit_rate,channels,sample_rate,bits_per_raw_sample,channel_layout:stream_tags=language \
        -of csv=p=0 "$file" 2>/dev/null)
    IFS=',' read -r AUDIO_CODEC AUDIO_BITRATE AUDIO_CHANNELS AUDIO_SAMPLERATE AUDIO_BITDEPTH AUDIO_LAYOUT AUDIO_LANG <<< "$AUDIO_INFO"

    # Sample rate (Hz → kHz)
    AUDIO_SAMPLERATE_KHZ="N/A"
    [[ "$AUDIO_SAMPLERATE" =~ ^[0-9]+$ ]] && \
        AUDIO_SAMPLERATE_KHZ=$(awk "BEGIN{printf \"%.1f\", $AUDIO_SAMPLERATE/1000}")

    # Bit depth — fallback daca bits_per_raw_sample e gol
    [[ -z "$AUDIO_BITDEPTH" || "$AUDIO_BITDEPTH" == "N/A" ]] && AUDIO_BITDEPTH=$(ffprobe -v error -select_streams a:0 \
        -show_entries stream=bits_per_sample -of csv=p=0 "$file" 2>/dev/null)
    [[ -z "$AUDIO_BITDEPTH" || "$AUDIO_BITDEPTH" == "0" ]] && AUDIO_BITDEPTH="N/A"

    # Channel layout — fallback la numar canale
    [[ -z "$AUDIO_LAYOUT" ]] && AUDIO_LAYOUT=$(
        case "$AUDIO_CHANNELS" in
            1) echo "mono" ;; 2) echo "stereo" ;; 6) echo "5.1" ;; 8) echo "7.1" ;;
            *) echo "${AUDIO_CHANNELS:-N/A}ch" ;;
        esac
    )

    # Limba audio
    [[ -z "$AUDIO_LANG" ]] && AUDIO_LANG="und"

    # ── Audio track count ─────────────────────────────────────────────
    # FIX: mutat INAINTE de AUDIO_TRACKS_DETAIL — era definit dupa blocul
    # care il folosea; conditia [ $AUDIO_COUNT -gt 0 ] era mereu falsa
    # si AUDIO_TRACKS_DETAIL ramanea mereu gol pentru orice fisier.
    # FIX: grep -c '^[0-9]' in loc de wc -l — evita fals pozitiv daca
    # ffprobe printeaza un newline trailing pe output gol (wc -l ar returna 1)
    AUDIO_COUNT=$(ffprobe -v error -select_streams a \
        -show_entries stream=index -of csv=p=0 "$file" 2>/dev/null | \
        grep -c '^[0-9]')

    # ── Detalii per track audio (toate track-urile) ───────────────────
    AUDIO_TRACKS_DETAIL=""
    if [ "$AUDIO_COUNT" -gt 0 ] 2>/dev/null; then
        local_aidx=0
        while IFS=',' read -r at_codec at_br at_ch at_sr at_layout at_lang; do
            at_br_k="N/A"
            [[ "$at_br" =~ ^[0-9]+$ ]] && at_br_k=$(awk "BEGIN{printf \"%.0f\", $at_br/1000}")
            at_sr_k="N/A"
            [[ "$at_sr" =~ ^[0-9]+$ ]] && at_sr_k=$(awk "BEGIN{printf \"%.1f\", $at_sr/1000}")
            [[ -z "$at_layout" ]] && at_layout="${at_ch}ch"
            [[ -z "$at_lang" ]] && at_lang="und"
            AUDIO_TRACKS_DETAIL="${AUDIO_TRACKS_DETAIL}    Track $local_aidx: ${at_codec:-N/A} | ${at_br_k}kbps | ${at_sr_k}kHz | ${at_layout} | ${at_lang}\n"
            local_aidx=$((local_aidx + 1))
        done < <(ffprobe -v error -select_streams a \
            -show_entries stream=codec_name,bit_rate,channels,sample_rate,channel_layout:stream_tags=language \
            -of csv=p=0 "$file" 2>/dev/null)
    fi

    # ── ffprobe #3: durata ────────────────────────────────────────────
    DURATION=$(ffprobe -v error -show_entries format=duration \
        -of csv=p=0 "$file" 2>/dev/null)
    DURATION_INT=${DURATION%.*}
    [[ ! "$DURATION_INT" =~ ^[0-9]+$ ]] && DURATION_INT=0

    # ── FPS ───────────────────────────────────────────────────────────
    FPS=$(echo "$FPS_RAW" | awk -F/ '{if($2>0) printf "%.2f",$1/$2; else print "N/A"}')

    # ── Bitrate video ─────────────────────────────────────────────────
    BITRATE_MB="N/A"
    [[ "$BITRATE" =~ ^[0-9]+$ ]] && \
        BITRATE_MB=$(awk "BEGIN{printf \"%.2f\", $BITRATE/1000000}")

    # ── Bitrate audio ─────────────────────────────────────────────────
    AUDIO_BITRATE_KB="N/A"
    [[ "$AUDIO_BITRATE" =~ ^[0-9]+$ ]] && \
        AUDIO_BITRATE_KB=$(awk "BEGIN{printf \"%.0f\", $AUDIO_BITRATE/1000}")

    # ── ffprobe #4: HDR10+ — output limitat cu -show_entries ──────────
    # FIX: -show_entries frame_side_data=type limiteaza output-ul enorm
    # al show_frames (altfel sute de linii per frame pentru fisiere HDR).
    # HDR10+ este detectat prin campul "type" din side_data.
    # NOTA: DOVI (Dolby Vision) NU este detectabil din -show_frames frames output
    # in mod fiabil — necesita un ffprobe separat pe codec_tag_string (stream-level).
    # Acesta este motivul pentru care DOVI_TAG are propriul apel ffprobe.
    FRAMES_INFO=$(ffprobe -v error -read_intervals 0%+#5 -show_frames \
        -select_streams v:0 \
        -show_entries frame_side_data=type \
        "$file" 2>/dev/null)
    HDR10PLUS=""
    echo "$FRAMES_INFO" | grep -q "HDR10+" && HDR10PLUS="1"

    # ── ffprobe #5: Dolby Vision — necesita codec_tag_string (stream-level) ─
    DOVI_TAG=$(ffprobe -v error -show_entries stream=codec_tag_string \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | \
        grep -i "dovi\|dvhe\|dvh1" | head -1)

    TYPE="SDR"; DV_PROFILE_STR="N/A"
    [[ "$TRANSFER"  == "arib-std-b67" ]] && TYPE="HLG"
    [[ "$TRANSFER"  == "smpte2084" ]] && TYPE="HDR10"
    [[ -n "$HDR10PLUS" ]]             && TYPE="HDR10+"
    if [[ -n "$DOVI_TAG" ]]; then
        TYPE="Dolby Vision"
        echo "  Se detecteaza profilul Dolby Vision..."
        DV_PROFILE_STR=$(get_dv_profile "$file")
    fi

    # get_source_format reutilizeaza datele deja extrase — fara ffprobe suplimentar
    SRC_FMT=$(get_source_format "$SRC_CODEC" "$PIX_FMT" "$TRANSFER" "${HDR10PLUS:-0}")

    # ── Subtitrari, capitole, attachments, DJI ────────────────────────
    SUBS_INFO=$(get_subtitles_info "$file")
    CHAPTERS_INFO=$(get_chapters_info "$file")
    ATTACH_INFO=$(get_attachments_info "$file")

    DJI_INFO=$(get_dji_tracks_info "$file")
    DJI_DJMD=$(echo "$DJI_INFO" | cut -d'|' -f1)
    DJI_DBGI=$(echo "$DJI_INFO"  | cut -d'|' -f2)
    DJI_TC=$(echo "$DJI_INFO"    | cut -d'|' -f3)
    IS_DJI=0
    if [ "$DJI_DJMD" -eq 1 ] || [ "$DJI_DBGI" -eq 1 ]; then IS_DJI=1; fi

    # ── LOG Profile detect ────────────────────────────────────────────
    LOG_PROFILE_STR=$(get_log_profile "$file" "$IS_DJI")

    # ── Output terminal ───────────────────────────────────────────────
    echo "  Format sursa : $SRC_FMT"
    echo "  Dimensiune   : $((FILE_SIZE/1024/1024)) MB"
    echo "  Durata       : ${DURATION_INT} sec"
    echo "  Rezolutie    : ${WIDTH}x${HEIGHT}"
    echo "  Pixel format : $PIX_FMT"
    echo "  FPS          : $FPS"
    echo "  Bitrate video: $BITRATE_MB Mb/s"
    echo "  Tip HDR      : $TYPE"
    [ -n "$DOVI_TAG" ] && echo "  Profil DV    : $DV_PROFILE_STR"
    [[ "$LOG_PROFILE_STR" != "N/A" ]] && echo "  LOG Profile  : $LOG_PROFILE_STR"
    echo "  ─────────────────────────────────────"
    if [ "$AUDIO_COUNT" -gt 1 ]; then
        echo "  Audio (main) : ${AUDIO_CODEC:-N/A} | ${AUDIO_BITRATE_KB} kbps | ${AUDIO_SAMPLERATE_KHZ} kHz | ${AUDIO_BITDEPTH}bit | ${AUDIO_LAYOUT} | ${AUDIO_LANG} | $AUDIO_COUNT track-uri"
        echo -e "$AUDIO_TRACKS_DETAIL"
    else
        echo "  Audio        : ${AUDIO_CODEC:-N/A} | ${AUDIO_BITRATE_KB} kbps | ${AUDIO_SAMPLERATE_KHZ} kHz | ${AUDIO_BITDEPTH}bit | ${AUDIO_LAYOUT} | ${AUDIO_LANG}"
    fi
    echo "  Subtitrari   : $SUBS_INFO"
    echo "  Capitole     : $CHAPTERS_INFO"
    echo "  Attachments  : $ATTACH_INFO"
    if [ "$IS_DJI" -eq 1 ]; then
        echo "  ─────────────────────────────────────"
        echo "  DJI tracks   :"
        [ "$DJI_DJMD" -eq 1 ] && echo "    ✅ djmd  — GPS, telemetrie, setari camera"
        [ "$DJI_DBGI" -eq 1 ] && echo "    ⚠️  dbgi  — date debug (~295 MB)"
        [ "$DJI_TC"   -eq 1 ] && echo "    ✅ Timecode — sincronizare profesionala"
    fi

    echo "  ─────────────────────────────────────"
    ENC_REC=$(get_encoder_recommendation "$SRC_FMT" "$TYPE" "$IS_DJI")
    echo "  Recomandat   : $ENC_REC"

    EST_X265=$(get_output_size_estimate "$TYPE" "$WIDTH" "$DURATION_INT" "x265")
    EST_X264=$(get_output_size_estimate "$TYPE" "$WIDTH" "$DURATION_INT" "x264")
    EST_AV1=$(get_output_size_estimate  "$TYPE" "$WIDTH" "$DURATION_INT" "av1")
    EST_PRORES=$(get_output_size_estimate "$TYPE" "$WIDTH" "$DURATION_INT" "prores")
    echo "  Estimare output (aproximativ, preset medium)"
    echo "    x265   : $EST_X265"
    echo "    x264   : $EST_X264"
    echo "    AV1    : $EST_AV1"
    echo "    ProRes : $EST_PRORES (HQ ~220 Mbps)"
    echo "  Progres      : $((IDX * 100 / TOTAL))%"

    # ── CSV ───────────────────────────────────────────────────────────
    # 30 campuri (extins cu Log_Profile, Est_ProRes)
    FILENAME_CSV="${filename//\"/\"\"}"
    printf '"%s","%s",%d,%d,"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s",%d,%d,"%s","%s","%s",%d,%d,%d,"%s","%s","%s","%s","%s"\n' \
        "$FILENAME_CSV" "$SRC_FMT" \
        "$((FILE_SIZE/1024/1024))" "$DURATION_INT" \
        "${WIDTH}x${HEIGHT}" "$PIX_FMT" \
        "${FPS:-N/A}" "${BITRATE_MB:-N/A}" \
        "$TYPE" "$DV_PROFILE_STR" "$LOG_PROFILE_STR" \
        "${AUDIO_CODEC:-N/A}" "${AUDIO_BITRATE_KB:-N/A}" \
        "${AUDIO_SAMPLERATE_KHZ:-N/A}" "${AUDIO_BITDEPTH:-N/A}" \
        "${AUDIO_LAYOUT:-N/A}" "${AUDIO_LANG:-und}" \
        "${AUDIO_CHANNELS:-0}" "$AUDIO_COUNT" \
        "$SUBS_INFO" "$CHAPTERS_INFO" "$ATTACH_INFO" \
        "$DJI_DJMD" "$DJI_DBGI" "$DJI_TC" \
        "$ENC_REC" "$EST_X265" "$EST_X264" "$EST_AV1" "$EST_PRORES" \
        >> "$CSV_FILE"
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Analiza completa! $COUNT fisiere procesate."
echo "Raport CSV salvat in: $CSV_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Comparatie Input vs Output (inainte/dupa) ────────────────────────
if [ -d "$OUTPUT_DIR" ]; then
    shopt -s nullglob nocaseglob
    OUT_FILES=("$OUTPUT_DIR"/*.{mp4,mov,mkv,mxf})
    shopt -u nocaseglob nullglob
    if [ ${#OUT_FILES[@]} -gt 0 ]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "COMPARATIE INPUT vs OUTPUT"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        COMP_COUNT=0
        COMP_TOTAL_ORIG=0
        COMP_TOTAL_NEW=0
        for out_file in "${OUT_FILES[@]}"; do
            out_name=$(basename "$out_file")
            # Extrage numele original: elimina sufixul _x265/_x264/_av1/_dnxhr/_audio si extensia
            base_name="$out_name"
            for suffix in _x265 _x264 _av1 _dnxhr _audio; do
                base_name="${base_name/$suffix/}"
            done
            base_name="${base_name%.*}"  # elimina extensia output

            # Cauta originalul in Input
            orig_found=""
            for ext in mp4 mov mkv m2ts mts vob mxf apv; do
                if [ -f "$INPUT_DIR/${base_name}.${ext}" ]; then
                    orig_found="$INPUT_DIR/${base_name}.${ext}"
                    break
                fi
                # Case insensitive
                upper_ext="${ext^^}"
                if [ -f "$INPUT_DIR/${base_name}.${upper_ext}" ]; then
                    orig_found="$INPUT_DIR/${base_name}.${upper_ext}"
                    break
                fi
            done

            if [ -n "$orig_found" ]; then
                COMP_COUNT=$((COMP_COUNT+1))
                orig_size=$(av_stat_size "$orig_found")
                new_size=$(av_stat_size "$out_file")
                orig_mb=$((orig_size / 1024 / 1024))
                new_mb=$((new_size / 1024 / 1024))
                COMP_TOTAL_ORIG=$((COMP_TOTAL_ORIG + orig_size))
                COMP_TOTAL_NEW=$((COMP_TOTAL_NEW + new_size))

                # Raport compresie
                if [ "$orig_size" -gt 0 ]; then
                    ratio=$(awk "BEGIN{printf \"%.1f\", $new_size * 100.0 / $orig_size}")
                    saved_mb=$(( (orig_size - new_size) / 1024 / 1024 ))
                else
                    ratio="N/A"; saved_mb=0
                fi

                # Verifica stream-uri
                orig_v=$(ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 "$orig_found" 2>/dev/null | grep -c '^[0-9]')
                new_v=$(ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 "$out_file" 2>/dev/null | grep -c '^[0-9]')
                orig_a=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$orig_found" 2>/dev/null | grep -c '^[0-9]')
                new_a=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$out_file" 2>/dev/null | grep -c '^[0-9]')

                streams_ok="✅"
                [ "$new_v" -lt "$orig_v" ] && streams_ok="⚠️ Video: $orig_v→$new_v"
                [ "$new_a" -lt "$orig_a" ] && streams_ok="⚠️ Audio: $orig_a→$new_a"

                echo "  $base_name"
                echo "    Original: ${orig_mb} MB → Encodat: ${new_mb} MB | Compresie: ${ratio}% | Salvat: ${saved_mb} MB"
                echo "    Streams: ${streams_ok} | V:${new_v} A:${new_a}"
            fi
        done

        if [ "$COMP_COUNT" -gt 0 ]; then
            echo "  ─────────────────────────────────────"
            echo "  TOTAL: $((COMP_TOTAL_ORIG/1024/1024)) MB → $((COMP_TOTAL_NEW/1024/1024)) MB"
            if [ "$COMP_TOTAL_ORIG" -gt 0 ]; then
                total_ratio=$(awk "BEGIN{printf \"%.1f\", $COMP_TOTAL_NEW * 100.0 / $COMP_TOTAL_ORIG}")
                total_saved=$(( (COMP_TOTAL_ORIG - COMP_TOTAL_NEW) / 1024 / 1024 ))
                echo "  Compresie globala: ${total_ratio}% | Salvat total: ${total_saved} MB"
            fi
            echo "  Perechi gasite: $COMP_COUNT"
        else
            echo "  Nu s-au gasit perechi Input/Output pentru comparatie."
        fi
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi
fi
