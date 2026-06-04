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
FILES=("$INPUT_DIR"/*.{mp4,mov,mkv,m2ts,mts,vob,mxf,apv,webm})
shopt -u nocaseglob nullglob
TOTAL=${#FILES[@]}

if [ "$TOTAL" -eq 0 ]; then
    echo "Nu am gasit fisiere in $INPUT_DIR"; exit 1
fi

# v57: CSV expanded 30 → 38 coloane:
#   - 7 HDR rich (ColorPrimaries, ColorSpace, ColorRange, MaxCLL, MaxFALL,
#     MasterDisplay, HDR10Plus_Scenes — inserate dupa Profil_DV)
#   - 1 Container (extensie fisier — mp4/mkv/mov/... — inserat dupa Format_sursa)
echo "Fisier,Format_sursa,Container,Dimensiune(MB),Durata(sec),Rezolutie,PixelFormat,FPS,Bitrate_video(Mbps),Tip_HDR,Profil_DV,ColorPrimaries,ColorSpace,ColorRange,MaxCLL,MaxFALL,MasterDisplay,HDR10Plus_Scenes,Log_Profile,Codec_audio,Bitrate_audio(kbps),SampleRate(kHz),BitDepth,Layout_canale,Limba_audio,Canale_audio,AudioTrackuri,Subtitrari,Capitole,Attachments,DJI_djmd,DJI_dbgi,DJI_Timecode,Recomandat_encoder,Est_x265,Est_x264,Est_AV1,Est_ProRes" \
    > "$CSV_FILE"

# ── Format sursa — primeste date deja extrase, fara ffprobe suplimentar ─
# v57 FIX: detectie bit depth corecta — vechiul `*10*` glob NU matcha yuv420p12le
# (substring "12", nu "10") → 12-bit etichetat ca 8-bit. Folosim bits_per_raw_sample
# (autoritar) cu fallback la pattern pix_fmt p10/p12/p16.
get_source_format() {
    local codec="$1" pix_fmt="$2" transfer="$3" hdr_plus_found="$4" bits_raw="${5:-}"
    local depth=8 is_hdr=0 is_hdrplus=0 is_hlg=0
    if [[ "$bits_raw" =~ ^[0-9]+$ ]] && [ "$bits_raw" -ge 10 ] && [ "$bits_raw" -le 16 ]; then
        depth="$bits_raw"
    elif [[ "$pix_fmt" == *p10* || "$pix_fmt" == *p010* ]]; then
        depth=10
    elif [[ "$pix_fmt" == *p12* || "$pix_fmt" == *p012* ]]; then
        depth=12
    elif [[ "$pix_fmt" == *p16* || "$pix_fmt" == *p016* ]]; then
        depth=16
    fi
    local depth_label="${depth}bit"
    [[ "$transfer"       == "smpte2084" ]] && is_hdr=1
    [[ "$transfer"       == "arib-std-b67" ]] && is_hlg=1
    [[ "$hdr_plus_found" == "1"         ]] && is_hdrplus=1 && is_hdr=1
    local fmt
    case "$codec" in
        h264) fmt="H.264 $depth_label" ;;
        hevc)
            if   [ $is_hdrplus -eq 1 ]; then fmt="H.265 HEVC HDR10+"
            elif [ $is_hdr -eq 1 ];     then fmt="H.265 HEVC HDR10"
            elif [ $is_hlg -eq 1 ];     then fmt="H.265 HEVC HLG"
            else                             fmt="H.265 HEVC $depth_label SDR"; fi ;;
        av1)
            if   [ $is_hdrplus -eq 1 ]; then fmt="AV1 HDR10+"
            elif [ $is_hdr -eq 1 ];     then fmt="AV1 HDR10"
            elif [ $is_hlg -eq 1 ];     then fmt="AV1 HLG"
            else                             fmt="AV1 $depth_label SDR"; fi ;;
        vp9)        fmt="VP9 $depth_label" ;;
        mpeg4)      fmt="MPEG-4" ;;
        mpeg2video) fmt="MPEG-2" ;;
        prores)     fmt="Apple ProRes" ;;
        apv)        fmt="Samsung APV $depth_label" ;;
        *)          fmt="$codec $depth_label" ;;
    esac
    echo "$fmt"
}

# ── Profil DV — copie locala intentionata din common_functions.sh ─────
# Aceasta functie este intentionat duplicata (check_video e script standalone).
# Daca se modifica get_dv_profile in common_functions.sh, replica aici.
get_dv_profile() {
    local file="$1"
    local dv_info dv_profile_num dv_compat
    # v62: sursa autoritara = STREAM side_data "DOVI configuration record" (dvcC/dvvC) —
    # merge pe HEVC SI AV1 DV. frame_side_data=dv_profile e GOL pe AV1 (frame-ul are doar
    # vdr_rpu_profile, profilul intern RPU) → P10 ramanea nedetectat (N/A).
    dv_info=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream_side_data=dv_profile,dv_bl_signal_compatibility_id \
        -of default=noprint_wrappers=1 "$file" 2>/dev/null)
    dv_profile_num=$(echo "$dv_info" | grep "dv_profile=" | head -1 | cut -d= -f2 | tr -d '[:space:]')
    dv_compat=$(echo "$dv_info" | grep "dv_bl_signal_compatibility_id=" | head -1 | cut -d= -f2 | tr -d '[:space:]')
    # Fallback: frame side_data (unele surse HEVC expun DV doar per-frame, fara config record)
    if [[ -z "$dv_profile_num" ]]; then
        dv_info=$(ffprobe -v error -show_frames -select_streams v:0 \
            -read_intervals 0%+#5 \
            -show_entries frame_side_data=dv_profile,dv_bl_signal_compatibility_id \
            -of default "$file" 2>/dev/null)
        dv_profile_num=$(echo "$dv_info" | grep "dv_profile=" \
            | head -1 | cut -d= -f2 | tr -d '[:space:]')
        dv_compat=$(echo "$dv_info" | grep "dv_bl_signal_compatibility_id=" \
            | head -1 | cut -d= -f2 | tr -d '[:space:]')
    fi
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
            10) case "$dv_compat" in
                1) echo "Profil 10.1 (DV AV1 + HDR10)" ;;
                2) echo "Profil 10.2 (DV AV1 + SDR)" ;;
                4) echo "Profil 10.4 (DV AV1 + HLG)" ;;
                *) echo "Profil 10 (DV AV1)" ;; esac ;;
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
    # Samsung S24 Ultra: tag autoritar `com.samsung.android.logvideo` —
    # cand e prezent, fisierul ESTE Samsung Log (short-circuit).
    if echo "$all_tags" | grep -qi "com\.samsung\.android\.logvideo"; then
        echo "Samsung Log (S24 Ultra)"
        return
    fi
    if echo "$all_tags" | grep -qi "make=.*apple"; then camera_make="apple"
    elif echo "$all_tags" | grep -qi "make=.*dji\|encoder=.*dji"; then camera_make="dji"
    elif echo "$all_tags" | grep -qi "manufacturer=.*samsung\|make=.*samsung\|com\.samsung\.android"; then camera_make="samsung"
    fi
    [[ -z "$camera_make" ]] && [[ "$is_dji" -eq 1 ]] && camera_make="dji"

    src_trc=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=color_transfer \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1)
    src_bps=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=bits_per_raw_sample \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1)
    if [[ ! "$src_bps" =~ ^[0-9]+$ ]]; then
        # Fallback: deriva depth-ul din pix_fmt (paritate cu get_source_format)
        local pf
        pf=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=pix_fmt \
            -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1)
        case "$pf" in
            *p16*|*p016*) src_bps=16 ;;
            *p12*|*p012*) src_bps=12 ;;
            *p10*|*p010*) src_bps=10 ;;
            *)            src_bps=8  ;;
        esac
    fi
    src_primaries=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=color_primaries \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1)

    local transfer hdr_plus_local dovi_local
    transfer=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1)
    hdr_plus_local=$(ffprobe -v error -read_intervals 0%+#5 -show_frames -select_streams v:0 \
        -show_entries frame_side_data=side_data_type "$file" 2>/dev/null | grep -m1 "HDR10+")
    dovi_local=$(ffprobe -v error -show_entries stream=codec_tag_string \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | grep -i "dovi\|dvhe\|dvh1" | head -1)

    if [[ "$camera_make" == "apple" ]]; then
        if [[ "$src_bps" -ge 10 ]] && [[ "$src_primaries" == *"bt2020"* || "$src_trc" == *"arib"* || "$src_trc" == *"log"* ]]; then
            log_profile="Apple Log (iPhone)"
        fi
    elif [[ "$camera_make" == "samsung" ]]; then
        # v62: exclude HLG (arib-std-b67) — Samsung Log = transfer unknown, HLG = arib;
        # un clip Samsung gradat-HLG (Log+LUT in editor) ar fi marcat gresit Log.
        if [[ "$src_bps" -ge 10 ]] && [[ "$src_primaries" == *"bt2020"* ]]; then
            if [[ -z "$hdr_plus_local" ]] && [[ "$transfer" != *"smpte2084"* ]] && [[ "$transfer" != *"arib"* ]]; then
                log_profile="Samsung Log (S24 Ultra)"
            fi
        fi
    elif [[ "$camera_make" == "dji" ]]; then
        # v62: exclude HLG (drone DJI cu HLG bt2020/arib)
        if [[ "$src_bps" -ge 10 ]] && [[ "$src_primaries" == *"bt2020"* ]] && [[ "$transfer" != *"arib"* ]]; then
            log_profile="D-Log M (DJI)"
        elif [[ "$src_bps" -ge 10 ]] && [[ "$transfer" != *"arib"* ]] \
             && [[ "$transfer" != *"smpte2084"* ]] && [[ -z "$dovi_local" ]] && [[ -z "$hdr_plus_local" ]]; then
            # v62 Faza B: Osmo Action 6 D-Log M e bt709 in container → djmd protobuf
            # (.2.4.1==19). Normal / non-AC006 / fara djmd → ramane SDR onest.
            [[ "$(_detect_dji_dlogm "$file")" == "dlog_m" ]] && log_profile="D-Log M (DJI)"
        fi
    elif [[ "$src_bps" -ge 10 ]] && [[ "$src_primaries" == *"bt2020"* ]] \
         && [[ -z "$hdr_plus_local" ]] && [[ "$transfer" != *"smpte2084"* ]] && [[ -z "$dovi_local" ]]; then
        # v62: arib NU mai e semnal Log (e HLG, prins la TYPE)
        if [[ "$src_trc" == "unknown" || "$src_trc" == *"log"* ]]; then
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
    # v57: extins cu color_primaries/color_space/color_range/bits_per_raw_sample
    # (necesare pentru detectia depth 12-bit + HDR rich fields)
    # Folosim default= (key=value) in loc de csv=p=0 — ffprobe csv reordoneaza
    # campurile dupa structura interna; default= ne lasa parse robust prin awk.
    VIDEO_INFO=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name,width,height,pix_fmt,color_transfer,avg_frame_rate,bit_rate,color_primaries,color_space,color_range,bits_per_raw_sample \
        -of default=noprint_wrappers=1 "$file" 2>/dev/null)
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
    # v57: container extras din extensie (lowercase, fara dot)
    CONTAINER="${filename##*.}"
    CONTAINER=$(echo "$CONTAINER" | tr '[:upper:]' '[:lower:]')

    # Parse robust din key=value (independent de ordinea interna ffprobe)
    _vi_field() { echo "$VIDEO_INFO" | awk -F= -v k="$1" '$1==k{print $2; exit}'; }
    SRC_CODEC=$(_vi_field codec_name)
    WIDTH=$(_vi_field width)
    HEIGHT=$(_vi_field height)
    PIX_FMT=$(_vi_field pix_fmt)
    TRANSFER=$(_vi_field color_transfer)
    FPS_RAW=$(_vi_field avg_frame_rate)
    BITRATE=$(_vi_field bit_rate)
    COLOR_PRIM_RAW=$(_vi_field color_primaries)
    COLOR_SPACE_RAW=$(_vi_field color_space)
    COLOR_RANGE_RAW=$(_vi_field color_range)
    BITS_RAW=$(_vi_field bits_per_raw_sample)

    # ── ffprobe #2: audio detaliat — un singur apel ──────────────────
    # v57 FIX: ffprobe csv=p=0 reordoneaza dupa structura interna, NU dupa
    # ordinea din -show_entries. Bug pre-existent: AUDIO_BITRATE primea valoarea
    # sample_rate, etc. → toate metricile audio gresite. Fix via default= (key=value).
    AUDIO_INFO=$(ffprobe -v error -select_streams a:0 \
        -show_entries stream=codec_name,bit_rate,channels,sample_rate,bits_per_raw_sample,channel_layout:stream_tags=language \
        -of default=noprint_wrappers=1 "$file" 2>/dev/null)
    _ai_field() { echo "$AUDIO_INFO" | awk -F= -v k="$1" '$1==k{print $2; exit}'; }
    AUDIO_CODEC=$(_ai_field codec_name)
    AUDIO_BITRATE=$(_ai_field bit_rate)
    AUDIO_CHANNELS=$(_ai_field channels)
    AUDIO_SAMPLERATE=$(_ai_field sample_rate)
    AUDIO_BITDEPTH=$(_ai_field bits_per_raw_sample)
    AUDIO_LAYOUT=$(_ai_field channel_layout)
    AUDIO_LANG=$(echo "$AUDIO_INFO" | awk -F= '$1=="TAG:language"{print $2; exit}')

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
    # v57 FIX: folosim -of compact (key=value pairs, | separated) — robust la
    # reordonarea interna ffprobe. Parse per-key via tr|awk.
    _kv() { echo "$1" | tr '|' '\n' | awk -F= -v k="$2" '$1==k{print $2; exit}'; }
    AUDIO_TRACKS_DETAIL=""
    if [ "$AUDIO_COUNT" -gt 0 ] 2>/dev/null; then
        local_aidx=0
        while IFS= read -r stream_line; do
            [ -z "$stream_line" ] && continue
            at_codec=$(_kv "$stream_line" codec_name)
            at_br=$(_kv "$stream_line" bit_rate)
            at_ch=$(_kv "$stream_line" channels)
            at_sr=$(_kv "$stream_line" sample_rate)
            at_layout=$(_kv "$stream_line" channel_layout)
            at_lang=$(_kv "$stream_line" tag:language)
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
            -of compact=nk=0:p=0 "$file" 2>/dev/null)
    fi

    # ── ffprobe #3: durata ────────────────────────────────────────────
    DURATION=$(ffprobe -v error -show_entries format=duration \
        -of csv=p=0 "$file" 2>/dev/null)
    DURATION_INT=${DURATION%.*}
    [[ ! "$DURATION_INT" =~ ^[0-9]+$ ]] && DURATION_INT=0

    # ── FPS ───────────────────────────────────────────────────────────
    FPS=$(echo "$FPS_RAW" | awk -F/ '{if($2>0) printf "%.2f",$1/$2; else print "N/A"}')

    # ── Bitrate video ─────────────────────────────────────────────────
    # v57: fallback in cascada — stream=bit_rate (lipseste de obicei pe MKV),
    # apoi format=bit_rate (acopera majoritatea MKV/WebM), apoi estimat din
    # size/duration (eticheta " (est)" pt a marca estimarea).
    BITRATE_MB="N/A"
    if [[ "$BITRATE" =~ ^[0-9]+$ ]]; then
        BITRATE_MB=$(awk "BEGIN{printf \"%.2f\", $BITRATE/1000000}")
    else
        FMT_BITRATE=$(ffprobe -v error -show_entries format=bit_rate \
            -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1)
        if [[ "$FMT_BITRATE" =~ ^[0-9]+$ ]]; then
            BITRATE_MB=$(awk "BEGIN{printf \"%.2f\", $FMT_BITRATE/1000000}")
        elif [ "$DURATION_INT" -gt 0 ] && [ "$FILE_SIZE" -gt 0 ]; then
            BITRATE_MB=$(awk "BEGIN{printf \"%.2f (est)\", ($FILE_SIZE * 8) / 1000000 / $DURATION_INT}")
        fi
    fi

    # ── Bitrate audio ─────────────────────────────────────────────────
    AUDIO_BITRATE_KB="N/A"
    [[ "$AUDIO_BITRATE" =~ ^[0-9]+$ ]] && \
        AUDIO_BITRATE_KB=$(awk "BEGIN{printf \"%.0f\", $AUDIO_BITRATE/1000}")

    # ── ffprobe #4: side_data per-frame (HDR10+ + DV detection) ─────
    # v57 FIX: field-ul corect e `side_data_type` (nu `type`); cu `type` ffprobe
    # ignora selectorul si returneaza tot frame-ul → grep-urile esueaza silentios.
    # v57: aceeasi query catch si DV per-frame ("Dolby Vision Metadata") —
    # singura cale pentru AV1 DV unde codec_tag = [0][0][0][0].
    FRAMES_INFO=$(ffprobe -v error -read_intervals 0%+#5 -show_frames \
        -select_streams v:0 \
        -show_entries frame_side_data=side_data_type \
        "$file" 2>/dev/null)
    HDR10PLUS=""
    echo "$FRAMES_INFO" | grep -q "HDR10+" && HDR10PLUS="1"
    # v57: AV1 DV nu apare in codec_tag_string ([0][0][0][0]); detectie via side_data
    DV_FROM_FRAMES=""
    echo "$FRAMES_INFO" | grep -q "Dolby Vision Metadata" && DV_FROM_FRAMES="1"

    # ── ffprobe #5: Dolby Vision codec tag (HEVC dvhe/dvh1) ──────────
    DOVI_TAG=$(ffprobe -v error -show_entries stream=codec_tag_string \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | \
        grep -i "dovi\|dvhe\|dvh1" | head -1)

    # ── DJI tracks (v57: mutat sus — necesar pt LOG profile) ─────────
    DJI_INFO=$(get_dji_tracks_info "$file")
    DJI_DJMD=$(echo "$DJI_INFO" | cut -d'|' -f1)
    DJI_DBGI=$(echo "$DJI_INFO"  | cut -d'|' -f2)
    DJI_TC=$(echo "$DJI_INFO"    | cut -d'|' -f3)
    IS_DJI=0
    if [ "$DJI_DJMD" -eq 1 ] || [ "$DJI_DBGI" -eq 1 ]; then IS_DJI=1; fi

    # ── LOG Profile detect (v57: mutat sus — necesar pt TYPE mutual excl) ─
    LOG_PROFILE_STR=$(get_log_profile "$file" "$IS_DJI")

    # ── TYPE detection cu LOG/DV awareness ──────────────────────────
    # v57: ordinea prioritati: DV (codec_tag OR side_data) > LOG > HDR10+ > HDR10 > HLG > SDR
    # LOG sursa NU e HLG/HDR10 nativ (transfer-ul e tag camera, nu signal real)
    TYPE="SDR"; DV_PROFILE_STR="N/A"
    if [[ -n "$DOVI_TAG" || -n "$DV_FROM_FRAMES" ]]; then
        TYPE="Dolby Vision"
        echo "  Se detecteaza profilul Dolby Vision..."
        DV_PROFILE_STR=$(get_dv_profile "$file")
    elif [[ "$LOG_PROFILE_STR" != "N/A" ]]; then
        TYPE="SDR (LOG)"
    elif [[ -n "$HDR10PLUS" ]]; then
        TYPE="HDR10+"
    elif [[ "$TRANSFER" == "smpte2084" ]]; then
        TYPE="HDR10"
    elif [[ "$TRANSFER" == "arib-std-b67" ]]; then
        TYPE="HLG"
    fi

    # ── HDR rich fields (v57) — color metadata + mastering + scene count ─
    COLOR_PRIMARIES="${COLOR_PRIM_RAW:-}"
    COLOR_SPACE_VAL="${COLOR_SPACE_RAW:-}"
    COLOR_RANGE_VAL="${COLOR_RANGE_RAW:-}"
    [[ -z "$COLOR_PRIMARIES" || "$COLOR_PRIMARIES" == "unknown" ]] && COLOR_PRIMARIES="N/A"
    [[ -z "$COLOR_SPACE_VAL" || "$COLOR_SPACE_VAL" == "unknown" ]] && COLOR_SPACE_VAL="N/A"
    [[ -z "$COLOR_RANGE_VAL" || "$COLOR_RANGE_VAL" == "unknown" ]] && COLOR_RANGE_VAL="N/A"

    MAX_CLL="N/A"; MAX_FALL="N/A"; MASTER_DISPLAY="N/A"; HDR10PLUS_SCENES="N/A"

    if [[ "$TYPE" == "HDR10" || "$TYPE" == "HDR10+" || "$TYPE" == "Dolby Vision" ]]; then
        HDR_DETAILS=$(ffprobe -v error -read_intervals 0%+#5 -show_frames -select_streams v:0 \
            -show_entries frame_side_data "$file" 2>/dev/null)

        _mc=$(echo "$HDR_DETAILS" | awk -F= '/^max_content=/{print $2; exit}' | tr -d '[:space:]')
        _mf=$(echo "$HDR_DETAILS" | awk -F= '/^max_average=/{print $2; exit}' | tr -d '[:space:]')
        [[ "$_mc" =~ ^[0-9]+$ ]] && MAX_CLL="$_mc"
        [[ "$_mf" =~ ^[0-9]+$ ]] && MAX_FALL="$_mf"

        # Master display — fractii rational num/denom
        _l_max=$(echo "$HDR_DETAILS" | awk -F'[=/]' '/^max_luminance=/{printf "%.0f",$2/$3; exit}')
        _l_min=$(echo "$HDR_DETAILS" | awk -F'[=/]' '/^min_luminance=/{printf "%.4f",$2/$3; exit}')
        _g_x=$(echo "$HDR_DETAILS"   | awk -F'[=/]' '/^green_x=/{printf "%.3f",$2/$3; exit}')
        if [[ "$_l_max" =~ ^[0-9]+$ ]] && [[ "$_l_max" -gt 0 ]]; then
            _primaries=$(echo "$_g_x" | awk '{v=$1+0; if(v<0.20) print "BT.2020"; else if(v<0.28) print "DCI-P3"; else if(v<0.32) print "BT.709"; else print "custom"}')
            MASTER_DISPLAY="${_primaries} max ${_l_max}n min ${_l_min}n"
        fi
    fi

    # HDR10+ scene count — bounded keyframe scan (cost: ~5-15s pe HDR10+ 4K)
    if [[ -n "$HDR10PLUS" ]]; then
        _scenes=$(ffprobe -v error -select_streams v:0 -skip_frame nokey -show_frames \
            -read_intervals "%+#9999" \
            -show_entries frame_side_data=side_data_type \
            "$file" 2>/dev/null | grep -c "HDR Dynamic Metadata SMPTE2094-40")
        [[ "$_scenes" =~ ^[0-9]+$ ]] && HDR10PLUS_SCENES="$_scenes"
    fi

    # get_source_format — reutilizeaza datele extrase + BITS_RAW pt depth detection
    SRC_FMT=$(get_source_format "$SRC_CODEC" "$PIX_FMT" "$TRANSFER" "${HDR10PLUS:-0}" "${BITS_RAW:-}")

    # ── Subtitrari, capitole, attachments ────────────────────────────
    SUBS_INFO=$(get_subtitles_info "$file")
    CHAPTERS_INFO=$(get_chapters_info "$file")
    ATTACH_INFO=$(get_attachments_info "$file")

    # ── Output terminal ───────────────────────────────────────────────
    echo "  Format sursa : $SRC_FMT"
    echo "  Container    : $CONTAINER"
    echo "  Dimensiune   : $((FILE_SIZE/1024/1024)) MB"
    echo "  Durata       : ${DURATION_INT} sec"
    echo "  Rezolutie    : ${WIDTH}x${HEIGHT}"
    echo "  Pixel format : $PIX_FMT"
    echo "  FPS          : $FPS"
    echo "  Bitrate video: $BITRATE_MB Mb/s"
    if [[ -n "$HDR10PLUS" ]] && [[ "$HDR10PLUS_SCENES" =~ ^[0-9]+$ ]] && [ "$HDR10PLUS_SCENES" -gt 0 ]; then
        echo "  Tip HDR      : $TYPE (~$HDR10PLUS_SCENES scene markers)"
    else
        echo "  Tip HDR      : $TYPE"
    fi
    if [[ -n "$DOVI_TAG" || -n "$DV_FROM_FRAMES" ]]; then echo "  Profil DV    : $DV_PROFILE_STR"; fi
    [[ "$LOG_PROFILE_STR" != "N/A" ]] && echo "  LOG Profile  : $LOG_PROFILE_STR"
    # v57: HDR rich fields display
    if [[ "$COLOR_PRIMARIES" != "N/A" || "$COLOR_SPACE_VAL" != "N/A" || "$COLOR_RANGE_VAL" != "N/A" ]]; then
        echo "  Color        : primaries=${COLOR_PRIMARIES} matrix=${COLOR_SPACE_VAL} range=${COLOR_RANGE_VAL}"
    fi
    if [[ "$MAX_CLL" != "N/A" || "$MAX_FALL" != "N/A" ]]; then
        echo "  MaxCLL/FALL  : ${MAX_CLL} / ${MAX_FALL} nits"
    fi
    if [[ "$MASTER_DISPLAY" != "N/A" ]]; then
        echo "  Mastering    : $MASTER_DISPLAY"
    fi
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
    # v57: 38 campuri (30 + 7 HDR rich + 1 Container — Container inserat
    # dupa Format_sursa, HDR rich dupa Profil_DV)
    FILENAME_CSV="${filename//\"/\"\"}"
    printf '"%s","%s","%s",%d,%d,"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s",%d,%d,"%s","%s","%s",%d,%d,%d,"%s","%s","%s","%s","%s"\n' \
        "$FILENAME_CSV" "$SRC_FMT" "$CONTAINER" \
        "$((FILE_SIZE/1024/1024))" "$DURATION_INT" \
        "${WIDTH}x${HEIGHT}" "$PIX_FMT" \
        "${FPS:-N/A}" "${BITRATE_MB:-N/A}" \
        "$TYPE" "$DV_PROFILE_STR" \
        "$COLOR_PRIMARIES" "$COLOR_SPACE_VAL" "$COLOR_RANGE_VAL" \
        "$MAX_CLL" "$MAX_FALL" "$MASTER_DISPLAY" "$HDR10PLUS_SCENES" \
        "$LOG_PROFILE_STR" \
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
    OUT_FILES=("$OUTPUT_DIR"/*.{mp4,mov,mkv,mxf,webm})
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
            # v57: lista sufixe extinsa cu toate output naming patterns post-v44
            # (encoder outputs + Mux v49/v50 + Telemetry v47 + Burn-in v48 + HDR/DV v56)
            # Chain-stripping (mai multe iteratii) acopera scenarii compuse: _telem_hud.
            base_name="$out_name"
            for suffix in _x265 _x264 _av1 _dnxhr _prores _apv _audio _hwenc \
                          _remux _mux _telem _hud _subs _preview \
                          _nodv _nohdr10plus _dvhybrid; do
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
