#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# av_trimconcat.sh — Trim & Concat Pipeline (v36+)
#
# Submeniu:
#   1) Trim clip              — tăiere un fișier (stream copy / re-encode)
#   2) Concat clips           — unire mai multe fișiere (compat check)
#   3) Trim + Concat + Encode — pipeline complet (trim → concat → encode)
#   4) Batch trim             — aceleași cuturi pe N fișiere (v37)
#   5) Înapoi
# ══════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/av_common.sh"

# ══════════════════════════════════════════════════════════════════════
# v60: Logica trim/concat mutata din av_common.sh (era thin shim pana la v59).
# Acum self-contained ca av_burnin.sh / av_mux.sh — source av_common.sh doar
# pentru helper-ele core shared (detect_source_info, find_lut_for_brand,
# hdr10_static_resolve, extract_hdr10plus_metadata, codec_tag_for_container,
# av_* cross-platform wrappers).
# ══════════════════════════════════════════════════════════════════════

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
        local mt; mt=$(av_stat_mtime "$d" || echo 0)
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
               local mt; mt=$(av_stat_mtime "$d" || echo 0)
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
    local f ct tag sd
    for f in "$@"; do
        ct=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer \
            -of default=nw=1:nk=1 "$f" 2>/dev/null)
        # v60 FIX: aliniere cu detect_source_info (audit-ul v58). `frame=side_data_list`
        # pe PRIMUL frame rata DV (AV1, codec_tag [0][0][0][0]) si HDR10+ — pe surse reale
        # returna 0 mereu. Folosim `frame_side_data=side_data_type` pe 5 frame + codec_tag
        # pentru DV HEVC (dvhe/dvh1/dovi).
        tag=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_tag_string \
            -of default=nw=1:nk=1 "$f" 2>/dev/null)
        sd=$(ffprobe -v error -show_frames -select_streams v:0 -read_intervals "%+#5" \
            -show_entries frame_side_data=side_data_type "$f" 2>/dev/null)
        case "$ct" in
            smpte2084) has_hdr10=1 ;;
            arib-std-b67) has_hlg=1 ;;
            *) has_sdr=1 ;;
        esac
        if echo "$tag" | grep -qi "dovi\|dvhe\|dvh1" || echo "$sd" | grep -qi "Dolby Vision Metadata"; then
            has_dv=1
        fi
        echo "$sd" | grep -qi "HDR10+\|HDR Dynamic" && has_hdr10plus=1
    done
    if (( has_dv == 1 )); then echo "dv"; return; fi
    if (( has_sdr == 1 )) && (( has_hdr10 == 1 || has_hlg == 1 )); then echo "mixed"; return; fi
    if (( has_hdr10plus == 1 )); then echo "hdr10plus"; return; fi
    if (( has_hdr10 == 1 )); then echo "hdr10"; return; fi
    if (( has_hlg == 1 )); then echo "hlg"; return; fi
    echo "sdr"
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
    # v60: default= in loc de csv=p=0 (single-field; convention proiect — evita trailing comma)
    d=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
    d=${d%.*}; d=${d%$'\r'}; [[ ! "$d" =~ ^[0-9]+$ ]] && d=0
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
    av_wake_lock

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
            # v60: HDR/LOG dialog + build args (re-encode strica HDR signaling fara astea)
            show_tc_hdr_dialog "$src" "$codec"
            if ! build_tc_video_args "$src" "$codec"; then
                echo "  [SKIP] mod=$(_tc_mode_label "$TC_MODE") — sar acest clip"
                continue
            fi
            if [[ "$TC_SOURCE_TYPE" != "sdr" ]]; then
                echo "  Sursa: $TC_SOURCE_TYPE → mod: $(_tc_mode_label "$TC_MODE")"
                [[ -n "$TC_DOWNGRADE_REASON" ]] && echo "  ⚠ $TC_DOWNGRADE_REASON"
            fi
            local _vf_args=()
            [[ -n "$TC_VF_PREPEND" ]] && _vf_args=(-vf "$TC_VF_PREPEND")
            local _ctag; _ctag=$(codec_tag_for_container "$([[ "$codec" == "libx264" ]] && echo h264 || echo hevc)" "$src_ext")
            echo "  Encoding... $(format_seconds "$clip_s")"
            run_ffmpeg_with_progress "Trim re-encode" "$clip_s" \
                -y -ss "$start_s" -to "$end_s" -i "$src" \
                -map 0 -map_metadata 0 "${_vf_args[@]}" -c:v "$codec" -crf "$crf" -preset medium \
                "${TC_ENC_EXTRA_ARGS[@]}" $_ctag \
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
            local osize; osize=$(av_stat_size "$out_path" 2>/dev/null || echo 0)
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

    av_wake_unlock
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
    av_wake_lock

    # Loop: pentru fiecare fisier × fiecare segment
    local total_ops=$(( ${#selected[@]} * ${#cuts[@]} ))
    local op=0 ok=0 fail=0 skip=0
    for src in "${selected[@]}"; do
        local sb; sb=$(basename "$src")
        local sn="${sb%.*}" sext="${sb##*.}"
        local sdur; sdur=$(get_duration_seconds "$src")
        # v60: HDR/LOG dialog per src (acelasi pe toate cut-urile acestui fisier).
        # Doar la re-encode (mode==2); stream copy pastreaza tot oricum.
        local _bt_skip_src=0
        local _bt_ctag=""
        if [[ "$mode" == "2" ]]; then
            show_tc_hdr_dialog "$src" "$re_codec"
            if ! build_tc_video_args "$src" "$re_codec"; then
                echo "[$sb] SKIP — mod=$(_tc_mode_label "$TC_MODE")"
                _bt_skip_src=1
            else
                if [[ "$TC_SOURCE_TYPE" != "sdr" ]]; then
                    echo "[$sb] sursa: $TC_SOURCE_TYPE → mod: $(_tc_mode_label "$TC_MODE")"
                    [[ -n "$TC_DOWNGRADE_REASON" ]] && echo "  ⚠ $TC_DOWNGRADE_REASON"
                fi
                _bt_ctag=$(codec_tag_for_container "$([[ "$re_codec" == "libx264" ]] && echo h264 || echo hevc)" "$sext")
            fi
        fi
        if [[ "$_bt_skip_src" == "1" ]]; then
            # Numara cut-urile acestui src ca skip si treci la urmatorul
            for cut in "${cuts[@]}"; do op=$((op+1)); skip=$((skip+1)); done
            continue
        fi
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
                local _bt_vf=()
                [[ -n "$TC_VF_PREPEND" ]] && _bt_vf=(-vf "$TC_VF_PREPEND")
                run_ffmpeg_with_progress "Batch trim ($op/$total_ops)" "$clip_s" \
                    -y -ss "$ss" -to "$ee" -i "$src" \
                    -map 0 -map_metadata 0 "${_bt_vf[@]}" -c:v "$re_codec" -crf "$re_crf" -preset medium \
                    "${TC_ENC_EXTRA_ARGS[@]}" $_bt_ctag \
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

    av_wake_unlock
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
    # v63: -select_streams v:0 raporteaza streamul de 2x pe DJI Action 6 (cover mjpeg +
    # multi-track moov) → blocul celor 5 campuri se repeta → signature dublata
    # ("hevc|..|hevc|..") → un clip DJI vs unul non-DJI de ACELASI format ieseau "diferite"
    # → fals incompat → re-encode in loc de stream-copy. head -5 = primul stream (5 campuri).
    ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name,width,height,r_frame_rate,pix_fmt \
        -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null | \
        head -5 | paste -sd'|' -
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
            selected=($(for f in "${selected[@]}"; do printf "%s\t%s\n" "$(av_stat_mtime "$f")" "$f"; done | sort -n | cut -f2-))
            unset IFS
            ;;
        3) # size
            local IFS=$'\n'
            selected=($(for f in "${selected[@]}"; do printf "%s\t%s\n" "$(av_stat_size "$f")" "$f"; done | sort -n | cut -f2-))
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
    av_wake_lock

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
        # v68: audio copiat in containerul ales → avertizeaza pistele incompatibile
        # (codec audio nesuportat de container la copy). Per sursa (concat = N→1).
        for _cf in "${selected[@]}"; do warn_incompat_audio_copies "$_cf" "$container" ""; done
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
        # v68: aopt=copy → audio copiat in containerul ales; avertizeaza incompatibilitatile
        if [[ "${aopt[*]}" == "-c:a copy" ]]; then
            for _cf in "${selected[@]}"; do warn_incompat_audio_copies "$_cf" "$container" ""; done
        fi

        # v60: HDR detect agregat pe setul de fisiere (concat = N→1).
        # detect_pipeline_hdr_mode returneaza sdr|hdr10|hdr10plus|hlg|dv|mixed
        # (NU detecteaza LOG — limitare cunoscuta; LOG la concat tratat ca sdr).
        _tc_reset_hdr_state
        local _agg; _agg=$(detect_pipeline_hdr_mode "${selected[@]}" 2>/dev/null || echo sdr)
        if [[ "$_agg" != "sdr" ]]; then
            if [[ -n "${TC_HDR_POLICY:-}" ]]; then
                case "$TC_HDR_POLICY" in
                    preserve) case "$_agg" in dv|mixed) TC_MODE="tonemap" ;; hdr10|hdr10plus) TC_MODE="preserve_hdr10" ;; hlg) TC_MODE="preserve_hlg" ;; esac ;;
                    tonemap)  TC_MODE="tonemap" ;;
                    skip)     TC_MODE="skip" ;;
                    lut)      TC_MODE="tonemap" ;;
                esac
            else
                echo ""
                case "$_agg" in
                    mixed)
                        echo "  ⚠ Surse MIXTE (HDR + SDR amestecate) — preserve HDR imposibil uniform."
                        echo "  1) Tonemap → SDR (uniform) [implicit]   2) Skip concat"
                        read -p "  Alege 1-2 [implicit: 1]: " _c
                        [[ "${_c:-1}" == "2" ]] && TC_MODE="skip" || TC_MODE="tonemap" ;;
                    dv)
                        echo "  ⚠ Surse Dolby Vision — re-encode concat nu pastreaza RPU."
                        echo "  1) Tonemap → SDR [implicit]   2) Skip concat"
                        read -p "  Alege 1-2 [implicit: 1]: " _c
                        [[ "${_c:-1}" == "2" ]] && TC_MODE="skip" || TC_MODE="tonemap" ;;
                    hdr10|hdr10plus)
                        local _l="HDR10"; [[ "$_agg" == "hdr10plus" ]] && _l="HDR10+ (concat re-encode pastreaza doar HDR10 base)"
                        echo "  Surse $_l"
                        echo "  1) Preserve HDR10 [implicit]   2) Tonemap → SDR   3) Skip concat"
                        read -p "  Alege 1-3 [implicit: 1]: " _c
                        case "${_c:-1}" in 2) TC_MODE="tonemap" ;; 3) TC_MODE="skip" ;; *) TC_MODE="preserve_hdr10" ;; esac ;;
                    hlg)
                        echo "  Surse HLG (BT.2100)"
                        echo "  1) Preserve HLG [implicit]   2) Tonemap → SDR   3) Skip concat"
                        read -p "  Alege 1-3 [implicit: 1]: " _c
                        case "${_c:-1}" in 2) TC_MODE="tonemap" ;; 3) TC_MODE="skip" ;; *) TC_MODE="preserve_hlg" ;; esac ;;
                esac
            fi
            if ! build_tc_video_args "${selected[0]}" "$codec"; then
                echo "  Concat anulat (mod=$(_tc_mode_label "$TC_MODE"))."
                cleanup_temp_subdir "$subdir" ""; av_wake_unlock; return 0
            fi
            echo "  Surse: $_agg → mod: $(_tc_mode_label "$TC_MODE")"
            [[ -n "$TC_DOWNGRADE_REASON" ]] && echo "  ⚠ $TC_DOWNGRADE_REASON"
        fi

        # Build -i pentru fiecare fișier + filter_complex
        local ff_in=() fc_map=""
        for ((i=0; i<${#selected[@]}; i++)); do
            ff_in+=(-i "${selected[$i]}")
            fc_map+="[${i}:v:0][${i}:a:0?]"
        done
        local n=${#selected[@]}
        # v60: daca tonemap/lut activ, aplica filtru DUPA concat in graph
        local fc
        if [[ -n "$TC_VF_PREPEND" ]]; then
            fc="${fc_map}concat=n=${n}:v=1:a=1[cv][outa];[cv]${TC_VF_PREPEND}[outv]"
        else
            fc="${fc_map}concat=n=${n}:v=1:a=1[outv][outa]"
        fi
        local _ctag; _ctag=$(codec_tag_for_container "$([[ "$codec" == "libx264" ]] && echo h264 || echo hevc)" "$container")

        echo "  Concat re-encode ($codec CRF $crf)... durata totala $(format_seconds "$total_s")"
        run_ffmpeg_with_progress "Concat ($codec)" "$total_s" \
            -y "${ff_in[@]}" \
            -filter_complex "$fc" \
            -map "[outv]" -map "[outa]" \
            -c:v "$codec" -crf "$crf" -preset medium \
            "${TC_ENC_EXTRA_ARGS[@]}" $_ctag \
            "${aopt[@]}" \
            -map_metadata 0 \
            "$out_path"
    fi

    av_wake_unlock

    # Cleanup
    cleanup_temp_subdir "$subdir" "$out_path"

    if [[ -f "$out_path" && -s "$out_path" ]]; then
        local osize; osize=$(av_stat_size "$out_path" 2>/dev/null || echo 0)
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

    # v63: mod pipeline — executie vs dry-run (respecta si DRY_RUN din env pt CI/scripting)
    local DRY_RUN="${DRY_RUN:-0}"
    if [[ "$DRY_RUN" != "1" ]]; then
        echo ""
        echo "Mod pipeline: 1-Executa [implicit]  2-Dry-run (afiseaza planul, fara executie)"
        read -p "Alege [implicit: 1]: " _pl_mode
        [[ "$_pl_mode" == "2" ]] && DRY_RUN=1
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
           chosen=($(for f in "${chosen[@]}"; do printf "%s\t%s\n" "$(av_stat_mtime "$f")" "$f"; done | sort -n | cut -f2-))
           unset IFS ;;
        3) local IFS=$'\n'
           chosen=($(for f in "${chosen[@]}"; do printf "%s\t%s\n" "$(av_stat_size "$f")" "$f"; done | sort -n | cut -f2-))
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
        local fsize; fsize=$(av_stat_size "$f" 2>/dev/null || echo 0)
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

    # v63: Dry-run — afiseaza planul pe pass-uri (+ HDR) si opreste inainte de orice ffmpeg/temp.
    if [[ "$DRY_RUN" == "1" ]]; then
        local _dry_hdr; _dry_hdr=$(detect_pipeline_hdr_mode "${chosen[@]}" 2>/dev/null || echo sdr)
        local _dry_ntrim=0 _s
        for _s in "${segments[@]}"; do [[ -n "$_s" ]] && _dry_ntrim=$((_dry_ntrim+1)); done
        echo ""
        echo "  ─────────────────────────────────────────────"
        echo "  🟡 DRY-RUN — plan executie (fara ffmpeg/temp):"
        printf "     Pass 1/3: trim %d segment(e) (stream copy -c copy)\n" "$_dry_ntrim"
        echo "     Pass 2/3: concat (demuxer/filter auto) + verificare compat"
        if (( audio_only == 1 )); then
            echo "     Pass 3/3: audio-only re-encode (video stream copy)"
        else
            printf "     Pass 3/3: %s CRF %s (%s)  |  HDR: %s\n" "$codec" "$crf" "$preset" "$_dry_hdr"
        fi
        echo "  ─────────────────────────────────────────────"
        return 0
    fi

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
    av_wake_lock

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
                    av_wake_unlock
                    return 1
                fi
                si=$((si+1))
            done
        fi
    done

    if (( ${#trimmed_files[@]} == 0 )); then
        echo "Nu s-au generat fisiere pentru concat."
        cleanup_temp_subdir "$subdir" ""
        av_wake_unlock
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

    # HDR-aware (v37 + v60): detectare mod HDR + injectare params per codec.
    # v60: codec-aware (libx265 + libsvtav1); HDR10 static master-display/max-cll inject;
    # AV1 HDR10+ inline (svtav1 + caps); LOG note onest pe sdr; codec_tag pe output.
    local hdr_color_args=()
    local hdr_x265_extra=""
    local hdr_svt_extra=""
    local hdr_pix_fmt=""
    if (( smart_copy == 0 && audio_only == 0 )); then
        local hdr_mode; hdr_mode=$(detect_pipeline_hdr_mode "${chosen[@]}")
        case "$hdr_mode" in
            sdr)
                # v60: detect_pipeline_hdr_mode nu clasifica LOG → nota onesta (fara transform)
                detect_source_info "${chosen[0]}" >/dev/null 2>&1 || true
                if [[ -n "${LOG_PROFILE:-}" ]]; then
                    echo ""
                    echo "  ℹ Sursa pare LOG ($(_log_profile_label "$LOG_PROFILE" 2>/dev/null || echo LOG))."
                    echo "    Pipeline pastreaza pixelii ca atare (fara LUT/tonemap)."
                    echo "    Pentru LUT Rec.709 / tonemap: encode principal sau Burn-in (opt 9)."
                fi
                ;;
            mixed)
                echo ""
                echo "  ⚠ HDR MIXED: input contine atat SDR cat si HDR (smpte2084/HLG)."
                echo "    HDR metadata NU va fi pastrat. Output = SDR-like."
                ;;
            hdr10|hdr10plus|hlg|dv)
                local trc="smpte2084"
                [[ "$hdr_mode" == "hlg" ]] && trc="arib-std-b67"
                case "$codec" in
                    libx265)
                        hdr_pix_fmt="yuv420p10le"
                        hdr_color_args=(-color_primaries bt2020 -color_trc "$trc" -colorspace bt2020nc)
                        if [[ "$hdr_mode" == "hlg" ]]; then
                            # v39: HLG NU foloseste hdr10=1 (signaling in transfer chars, fara SEI PQ)
                            hdr_x265_extra="hdr-opt=1:repeat-headers=1:colorprim=bt2020:transfer=$trc:colormatrix=bt2020nc"
                        else
                            hdr_x265_extra="hdr10=1:hdr10-opt=1:repeat-headers=1:colorprim=bt2020:transfer=$trc:colormatrix=bt2020nc"
                            # v60: HDR10 static master-display/max-cll
                            hdr10_static_resolve "${trimmed_files[0]}" >/dev/null 2>&1 || true
                            if [[ "${HDR10_STATIC_AVAILABLE:-0}" == "1" && -n "${HDR10_MASTER_DISPLAY_X265:-}" ]]; then
                                hdr_x265_extra="${hdr_x265_extra}:master-display=${HDR10_MASTER_DISPLAY_X265}"
                                [[ -n "$HDR10_MAX_CLL" ]] && hdr_x265_extra="${hdr_x265_extra}:max-cll=${HDR10_MAX_CLL}"
                            fi
                        fi
                        if [[ "$hdr_mode" == "dv" ]]; then
                            echo ""
                            echo "  ⚠ DOLBY VISION detectat. Re-encode -> fallback HDR10 (DV RPU nu se pastreaza)."
                            echo "    Pentru DV: pastreaza HDR10+ aici, apoi HDR10+→DV in HDR/DV tools (opt 8)."
                        elif [[ "$hdr_mode" == "hdr10plus" ]]; then
                            echo ""
                            echo "  ⚡ HDR10+ detectat. Pastrezi metadata dinamica (dhdr10-info)? (necesita $AV_TOOL_HDR10PLUS)"
                            echo "     1) Da [default]   2) Nu (doar HDR10 static)"
                            read -p "     Alege 1-2: " hdr10p_ch
                            if [[ "${hdr10p_ch:-1}" == "1" ]]; then
                                if _check_hdr10plus_tool; then
                                    local hdr10p_json
                                    hdr10p_json=$(extract_hdr10plus_metadata "${trimmed_files[0]}")
                                    if [[ -n "$hdr10p_json" && -s "$hdr10p_json" ]]; then
                                        if [[ "$hdr10p_json" == *:* ]]; then
                                            # v60: cale cu ':' (drive Windows) sparge x265-params (`:`-separat). Fallback static.
                                            echo "     ⚠ Cale JSON contine ':' (incompatibil cu x265-params). Fallback HDR10 static."
                                        else
                                            hdr_x265_extra="${hdr_x265_extra}:dhdr10-info=${hdr10p_json}"
                                            echo "     ✓ HDR10+ JSON extras: $hdr10p_json"
                                        fi
                                    else
                                        echo "     ⚠ Extragere HDR10+ esuata. Fallback HDR10 static."
                                    fi
                                else
                                    echo "     ⚠ $AV_TOOL_HDR10PLUS NU este instalat. Fallback HDR10 static."
                                    echo "       Instaleaza: $TOOLS_DIR/hdr10plus_parser.sh"
                                fi
                            fi
                        elif [[ "$hdr_mode" == "hlg" ]]; then
                            echo ""; echo "  ⚡ AUTO HLG (x265): pix_fmt=$hdr_pix_fmt, transfer=arib-std-b67, color=bt2020"
                        else
                            echo ""; echo "  ⚡ AUTO HDR10 (x265): pix_fmt=$hdr_pix_fmt, transfer=$trc, color=bt2020"
                        fi
                        ;;
                    libsvtav1)
                        hdr_pix_fmt="yuv420p10le"
                        hdr_color_args=(-color_primaries bt2020 -color_trc "$trc" -colorspace bt2020nc)
                        if [[ "$hdr_mode" == "hlg" ]]; then
                            # HLG: transfer-characteristics=18 (ITU-T H.273)
                            hdr_svt_extra="enable-hdr=1:color-primaries=9:transfer-characteristics=18:matrix-coefficients=9"
                            echo ""; echo "  ⚡ AUTO HLG (svtav1): enable-hdr=1, transfer=18 (HLG)"
                        else
                            # PQ: transfer-characteristics=16
                            hdr_svt_extra="enable-hdr=1:color-primaries=9:transfer-characteristics=16:matrix-coefficients=9"
                            hdr10_static_resolve "${trimmed_files[0]}" >/dev/null 2>&1 || true
                            if [[ "${HDR10_STATIC_AVAILABLE:-0}" == "1" && -n "${HDR10_MASTER_DISPLAY_SVTAV1:-}" ]]; then
                                hdr_svt_extra="${hdr_svt_extra}:mastering-display=${HDR10_MASTER_DISPLAY_SVTAV1}"
                                [[ -n "$HDR10_MAX_CLL" ]] && hdr_svt_extra="${hdr_svt_extra}:content-light=${HDR10_MAX_CLL}"
                            fi
                            if [[ "$hdr_mode" == "dv" ]]; then
                                echo ""
                                echo "  ⚠ DOLBY VISION detectat. AV1 re-encode -> fallback HDR10 (DV RPU nu se pastreaza)."
                                echo "    Pentru DV: pastreaza HDR10+ aici, apoi HDR10+→DV in HDR/DV tools (opt 8)."
                            elif [[ "$hdr_mode" == "hdr10plus" ]]; then
                                echo ""
                                echo "  ⚡ HDR10+ detectat. Pastrezi metadata dinamica inline (svtav1 hdr10plus-json)?"
                                echo "     1) Da [default]   2) Nu (doar HDR10 static)"
                                read -p "     Alege 1-2: " hdr10p_ch
                                if [[ "${hdr10p_ch:-1}" == "1" ]]; then
                                    local _src_codec; _src_codec=$(detect_source_codec "${trimmed_files[0]}" 2>/dev/null || true)
                                    if _check_hdr10plus_tool_for "$_src_codec" && _check_svtav1_hdr10plus_caps; then
                                        local hdr10p_json
                                        hdr10p_json=$(extract_hdr10plus_metadata "${trimmed_files[0]}" "$_src_codec")
                                        if [[ -n "$hdr10p_json" && -s "$hdr10p_json" ]]; then
                                            if [[ "$hdr10p_json" == *:* ]]; then
                                                # v60: cale cu ':' sparge svtav1-params (`:`-separat). Fallback static.
                                                echo "     ⚠ Cale JSON contine ':' (incompatibil cu svtav1-params). Fallback HDR10 static."
                                            else
                                                hdr_svt_extra="${hdr_svt_extra}:hdr10plus-json=${hdr10p_json}"
                                                echo "     ✓ HDR10+ JSON inline: $hdr10p_json"
                                            fi
                                        else
                                            echo "     ⚠ Extragere HDR10+ esuata. Fallback HDR10 static."
                                        fi
                                    else
                                        echo "     ⚠ SVT-AV1 fara suport hdr10plus-json sau tool lipsa. Fallback HDR10 static."
                                    fi
                                fi
                            else
                                echo ""; echo "  ⚡ AUTO HDR10 (svtav1): enable-hdr=1, transfer=16 (PQ)"
                            fi
                        fi
                        ;;
                    *)
                        echo ""
                        echo "  ⚠ HDR detectat ($hdr_mode), dar codec=$codec nu suporta HDR (libx264/libaom)."
                        echo "    HDR metadata NU va fi pastrat. Pentru HDR foloseste libx265 sau libsvtav1."
                        ;;
                esac
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

    # Build HDR args pentru ffmpeg call (pix_fmt + color_* + x265/svtav1-params)
    local hdr_pix_args=()
    [[ -n "$hdr_pix_fmt" ]] && hdr_pix_args=(-pix_fmt "$hdr_pix_fmt")
    local hdr_x265_args=()
    [[ -n "$hdr_x265_extra" ]] && hdr_x265_args=(-x265-params "$hdr_x265_extra")
    local hdr_svt_args=()
    [[ -n "$hdr_svt_extra" ]] && hdr_svt_args=(-svtav1-params "$hdr_svt_extra")
    # v60: codec_tag (hvc1/av01/avc1) pe output re-encode (DV-aware players)
    local _pl_ctag=""
    if (( smart_copy == 0 && audio_only == 0 )); then
        local _pl_tagcodec=""
        case "$codec" in
            libx265) _pl_tagcodec="hevc" ;;
            libx264) _pl_tagcodec="h264" ;;
            libsvtav1|libaom-av1) _pl_tagcodec="av1" ;;
        esac
        [[ -n "$_pl_tagcodec" ]] && _pl_ctag=$(codec_tag_for_container "$_pl_tagcodec" "$container")
    fi
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
            "${hdr_pix_args[@]}" "${hdr_color_args[@]}" "${hdr_x265_args[@]}" "${hdr_svt_args[@]}" $_pl_ctag \
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
            "${hdr_pix_args[@]}" "${hdr_color_args[@]}" "${hdr_x265_args[@]}" "${hdr_svt_args[@]}" $_pl_ctag \
            "${aopt[@]}" \
            "$out_path"
    fi

    av_wake_unlock

    # Cleanup
    cleanup_temp_subdir "$subdir" "$out_path"

    # Stats finale
    if [[ -f "$out_path" && -s "$out_path" ]]; then
        local osize; osize=$(av_stat_size "$out_path" 2>/dev/null || echo 0)
        local tot_in=0
        for ((i=0; i<${#chosen[@]}; i++)); do
            local fs; fs=$(av_stat_size "${chosen[$i]}" 2>/dev/null || echo 0)
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

# ══════════════════════════════════════════════════════════════════════
# v60: HDR/LOG awareness pentru re-encode (Trim / BatchTrim / Concat)
# ══════════════════════════════════════════════════════════════════════
# Re-encode-ul din trim/concat producea pana acum output 8-bit SDR fara
# color signaling pe surse HDR/LOG (acelasi gap reparat la burn-in v58).
# Helper-ele de mai jos detecteaza sursa + ofera dialog per fisier.
#
# Diferenta fata de burn-in: trim/concat NU au overlay, deci nu exista
# PRE_FILTER pentru base layer. In schimb:
#   - tonemap/LUT → TC_VF_PREPEND (prepended in -vf sau in filter_complex la concat)
#   - preserve HDR10/HLG → TC_ENC_EXTRA_ARGS (pix_fmt + color + x265-params)
# Encoder-ele oferite la trim/concat sunt libx265/libx264 (NU svtav1), deci
# HDR10+ inline AV1 nu se aplica aici → HDR10+ cade pe HDR10 base (x265).
#
# State globale (reset per fisier in _tc_reset_hdr_state):
#   TC_SOURCE_TYPE = sdr|dv|hdr10|hdr10plus|hlg|log
#   TC_MODE        = sdr|preserve_hdr10|preserve_hlg|tonemap|lut_rec709|keep_log|skip
#   TC_VF_PREPEND  = lant filter (tonemap/lut3d) de pus inaintea altor -vf
#   TC_ENC_EXTRA_ARGS = array args ffmpeg (pix_fmt/color/x265-params)
#   TC_LUT_FILE / TC_DOWNGRADE_REASON
#
# Bypass non-interactiv: TC_HDR_POLICY=preserve|tonemap|skip|lut

_tc_mode_label() {
    case "$1" in
        sdr)            echo "SDR (no transform)" ;;
        preserve_hdr10) echo "Preserve HDR10" ;;
        preserve_hlg)   echo "Preserve HLG" ;;
        tonemap)        echo "Tonemap → SDR" ;;
        lut_rec709)     echo "Apply LUT (LOG → Rec.709)" ;;
        keep_log)       echo "Keep LOG (no color transform)" ;;
        skip)           echo "Skip" ;;
        *)              echo "$1" ;;
    esac
}

_tc_classify_source() {
    TC_SOURCE_TYPE="sdr"
    if [[ -n "${DOVI:-}" ]]; then
        TC_SOURCE_TYPE="dv"
    elif [[ -n "${HDR_PLUS:-}" ]]; then
        TC_SOURCE_TYPE="hdr10plus"
    elif [[ "${HDR_TYPE:-}" == *"smpte2084"* ]]; then
        TC_SOURCE_TYPE="hdr10"
    elif [[ "${IS_HLG:-0}" == "1" ]]; then
        TC_SOURCE_TYPE="hlg"
    elif [[ -n "${LOG_PROFILE:-}" ]]; then
        TC_SOURCE_TYPE="log"
    fi
}

_tc_reset_hdr_state() {
    TC_SOURCE_TYPE="sdr"
    TC_MODE="sdr"
    TC_VF_PREPEND=""
    TC_ENC_EXTRA_ARGS=()
    TC_LUT_FILE=""
    TC_DOWNGRADE_REASON=""
}

# Dialog per fisier. Necesita: detect_source_info DEJA apelat (sau il apeleaza).
# Apel: show_tc_hdr_dialog "<file>" "<encoder libx265|libx264>"
# Seteaza TC_MODE + state aferent. Return 0.
show_tc_hdr_dialog() {
    local file="$1" encoder="${2:-libx265}"
    _tc_reset_hdr_state
    detect_source_info "$file" >/dev/null 2>&1 || true
    _tc_classify_source

    [[ "$TC_SOURCE_TYPE" == "sdr" ]] && return 0

    # Env policy bypass (CI/batch)
    if [[ -n "${TC_HDR_POLICY:-}" ]]; then
        case "$TC_HDR_POLICY" in
            preserve)
                case "$TC_SOURCE_TYPE" in
                    dv)               TC_MODE="skip" ;;
                    hdr10|hdr10plus)  TC_MODE="preserve_hdr10" ;;
                    hlg)              TC_MODE="preserve_hlg" ;;
                    log)              TC_MODE="keep_log" ;;
                esac ;;
            tonemap) TC_MODE="tonemap" ;;
            skip)    TC_MODE="skip" ;;
            lut)
                if [[ "$TC_SOURCE_TYPE" == "log" ]] && find_lut_for_brand "${CAMERA_MAKE:-unknown}" >/dev/null 2>&1; then
                    TC_MODE="lut_rec709"; TC_LUT_FILE="${LUT_FILES[0]}"
                else
                    TC_MODE="tonemap"
                fi ;;
            *) TC_MODE="sdr" ;;
        esac
        return 0
    fi

    case "$TC_SOURCE_TYPE" in
        dv)
            echo ""
            echo "  ⚠  Sursa Dolby Vision (profil ${DOVI})"
            echo "     Re-encode trim/concat nu pastreaza RPU DV (encoder x265/x264"
            echo "     fara extract+inject). Pentru DV preserve foloseste fluxul"
            echo "     principal de encode sau av_hdr_dv_tools."
            echo "  1) Tonemap → SDR (recomandat)"
            echo "  2) Skip [implicit]"
            read -p "  Alege 1-2 [implicit: 2]: " _c
            case "${_c:-2}" in
                1) TC_MODE="tonemap" ;;
                *) TC_MODE="skip" ;;
            esac ;;
        hdr10|hdr10plus)
            local _lbl="HDR10"; [[ "$TC_SOURCE_TYPE" == "hdr10plus" ]] && _lbl="HDR10+ (re-encode pastreaza doar HDR10 base — metadata dinamica se pierde la x265/x264)"
            echo ""
            echo "  Sursa $_lbl"
            echo "  1) Preserve HDR10 (pix_fmt p010le + master-display + max-cll) [implicit]"
            echo "  2) Tonemap → SDR"
            echo "  3) Skip"
            read -p "  Alege 1-3 [implicit: 1]: " _c
            case "${_c:-1}" in
                2) TC_MODE="tonemap" ;;
                3) TC_MODE="skip" ;;
                *) TC_MODE="preserve_hdr10" ;;
            esac ;;
        hlg)
            echo ""
            echo "  Sursa HLG (BT.2100 HLG)"
            echo "  1) Preserve HLG (pix_fmt p010le + transfer arib-std-b67) [implicit]"
            echo "  2) Tonemap → SDR"
            echo "  3) Skip"
            read -p "  Alege 1-3 [implicit: 1]: " _c
            case "${_c:-1}" in
                2) TC_MODE="tonemap" ;;
                3) TC_MODE="skip" ;;
                *) TC_MODE="preserve_hlg" ;;
            esac ;;
        log)
            local _brand="${CAMERA_MAKE:-unknown}"
            local _log_label; _log_label=$(_log_profile_label "$LOG_PROFILE" 2>/dev/null || echo "LOG")
            local _has_lut=0
            find_lut_for_brand "$_brand" >/dev/null 2>&1 && _has_lut=1
            echo ""
            echo "  Sursa LOG: $_log_label (brand=$_brand)"
            # v62: conversia fara-LUT (tonemap) ELIMINATA pe LOG — Log→Rec.709 cere LUT.
            # Fara LUT raman Keep LOG (pt grading ulterior) / Skip.
            if [[ "$_has_lut" == 1 ]]; then
                echo "  1) Apply LUT Rec.709 (${LUT_FILES[0]##*/}) [implicit]"
                echo "  2) Keep LOG (fara transform — pentru grading ulterior)"
                echo "  3) Skip"
                read -p "  Alege 1-3 [implicit: 1]: " _c
                case "${_c:-1}" in
                    2) TC_MODE="keep_log" ;;
                    3) TC_MODE="skip" ;;
                    *) TC_MODE="lut_rec709"; TC_LUT_FILE="${LUT_FILES[0]}" ;;
                esac
            else
                echo "  (Fara LUT in Luts/ — conversia corecta Log→Rec.709 nu e posibila.)"
                echo "  1) Keep LOG (fara transform) [implicit]"
                echo "  2) Skip"
                read -p "  Alege 1-2 [implicit: 1]: " _c
                case "${_c:-1}" in
                    2) TC_MODE="skip" ;;
                    *) TC_MODE="keep_log" ;;
                esac
            fi ;;
    esac
}

# Construieste TC_VF_PREPEND + TC_ENC_EXTRA_ARGS pe baza TC_MODE + encoder.
# Return 0 ok, 1 skip (caller sare fisierul/operatia).
build_tc_video_args() {
    local file="$1" encoder="${2:-libx265}"
    TC_VF_PREPEND=""
    TC_ENC_EXTRA_ARGS=()
    local _tonemap="zscale=transfer=linear:matrix=bt709:primaries=bt709,tonemap=hable:desat=0,zscale=transfer=bt709:matrix=bt709:primaries=bt709,format=yuv420p"
    case "$TC_MODE" in
        skip)         return 1 ;;
        sdr|keep_log) return 0 ;;
        lut_rec709)
            local _esc; _esc=$(printf '%s' "$TC_LUT_FILE" | sed 's/\\/\//g; s/:/\\:/g')
            # v62 audit: setparams re-eticheteaza culoarea pe frame (lut3d nu o atinge →
            # mis-tagged pe ORICE container fara ea).
            TC_VF_PREPEND="lut3d='${_esc}',setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709"
            return 0 ;;
        tonemap)
            TC_VF_PREPEND="$_tonemap"
            return 0 ;;
        preserve_hdr10)
            if [[ "$encoder" == "libx264" ]]; then
                TC_DOWNGRADE_REASON="libx264 nu suporta 10-bit HDR in builds standard — auto-tonemap"
                TC_VF_PREPEND="$_tonemap"
                return 0
            fi
            TC_ENC_EXTRA_ARGS+=(-pix_fmt yuv420p10le)
            TC_ENC_EXTRA_ARGS+=(-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc)
            hdr10_static_resolve "$file" >/dev/null 2>&1 || true
            local _p="hdr10=1:hdr10-opt=1:repeat-headers=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc"
            if [[ "${HDR10_STATIC_AVAILABLE:-0}" == "1" ]] && [[ -n "${HDR10_MASTER_DISPLAY_X265:-}" ]]; then
                _p="${_p}:master-display=${HDR10_MASTER_DISPLAY_X265}"
                [[ -n "$HDR10_MAX_CLL" ]] && _p="${_p}:max-cll=${HDR10_MAX_CLL}"
            fi
            TC_ENC_EXTRA_ARGS+=(-x265-params "$_p")
            return 0 ;;
        preserve_hlg)
            if [[ "$encoder" == "libx264" ]]; then
                TC_DOWNGRADE_REASON="libx264 nu suporta 10-bit HLG in builds standard — auto-tonemap"
                TC_VF_PREPEND="$_tonemap"
                return 0
            fi
            TC_ENC_EXTRA_ARGS+=(-pix_fmt yuv420p10le)
            TC_ENC_EXTRA_ARGS+=(-color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc)
            TC_ENC_EXTRA_ARGS+=(-x265-params "hdr-opt=1:repeat-headers=1:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc")
            return 0 ;;
        *) return 0 ;;
    esac
}

# ── Test mode: skip meniu interactiv (sourcing pentru teste) ──────────
if [[ "${AV_TRIMCONCAT_TEST_MODE:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

# v36: Curatenie temp rezidual la intrare (foldere vechi din sesiuni anterioare)
tc_scan_leftover_temp

# ── Submeniu principal ────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════╗"
echo "║  TRIM & CONCAT                       ║"
echo "╠══════════════════════════════════════╣"
echo "║  1) Trim clip (un fisier)            ║"
echo "║  2) Concat clips (unire)             ║"
echo "║  3) Trim + Concat + Encode           ║"
echo "║  4) Batch trim (N fisiere, cuts comune)"
echo "║  5) Inapoi                           ║"
echo "╚══════════════════════════════════════╝"
read -p "Alege 1-5: " tc_choice

case "$tc_choice" in
    1) trimconcat_flow_trim ;;
    2) trimconcat_flow_concat ;;
    3) trimconcat_flow_pipeline ;;
    4) trimconcat_flow_batch_trim ;;
    5) echo "Inapoi."; exit 0 ;;
    *) echo "Optiune invalida."; exit 1 ;;
esac
