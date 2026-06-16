#!/usr/bin/env bash
# av_mux.sh — Mux tools (v50)
# Submeniu cu trei flow-uri:
#   1) Remux  — selectie streams + repackage in container nou (mkv/mp4/mov/webm)
#   2) Demux  — extract streams ca fisiere separate (mkv/mka/native sub + attach)
#   3) Mux    — v50: combina fisiere separate (video + audio[N] + sub[N] + chapters + attach)
#              intr-un container nou. Scan doar InputVideos. Manual selection.
# Input remux/demux: mkv, webm, mp4, m4v, mov, ts, m2ts, mts, vob, mxf
# Output remux: <name>_remux.<ext>
# Output demux: <name>_v<idx>_<codec>.mkv / <name>_a<idx>_<codec>_<lang>.mka /
#               <name>_s<idx>_<codec>_<lang>.<ext> / <name>_cover_<idx>.<ext> /
#               <name>_chapters.xml / <name>_attach/* / <name>_data/* (opt-in)
# Output mux:   <video_basename>_mux.<ext>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/av_common.sh"

# v59: In test mode skip mkdir + ffmpeg dep check (functions only).
# Pattern preluat din av_burnin.sh (v58) — permite sourcing pentru teste.
if [[ "${AV_MUX_TEST_MODE:-0}" != "1" ]]; then
    mkdir -p "$OUTPUT_DIR"

    if ! command -v ffmpeg &>/dev/null || ! command -v ffprobe &>/dev/null; then
        echo "EROARE: ffmpeg/ffprobe nu sunt instalate."
        echo "Instaleaza cu: $(av_pkg_install_hint ffmpeg)"
        exit 1
    fi
fi

SUPPORTED_INPUT_EXT=(mkv webm mp4 m4v mov ts m2ts mts vob mxf)
SUPPORTED_OUTPUT_EXT=(mkv mp4 mov webm)

# ═════════════════════════════════════════════════════════════════════
# SHARED HELPERS
# ═════════════════════════════════════════════════════════════════════

declare -a MUX_FILES=()
declare -a MUX_LABELS=()

mux_scan_input() {
    local dir="$1" label="$2"
    [ ! -d "$dir" ] && return
    local ext
    for ext in "${SUPPORTED_INPUT_EXT[@]}"; do
        while IFS= read -r -d '' f; do
            local base; base="$(basename "$f")"
            local name="${base%.*}"
            # Exclude propriile output-uri mux/remux/demux
            [[ "$name" == *_mux ]] && continue
            [[ "$name" == *_remux ]] && continue
            # Demux: <name>_v<idx>_<codec> / _a<idx>_<codec>[_<lang>] / _s<idx>_<codec>[_<lang>]
            # Cere underscore dupa cifre pentru a evita false-positives pe fisiere ca "season1_v2.mkv".
            [[ "$name" == *_v[0-9]_* || "$name" == *_v[0-9][0-9]_* ]] && continue
            [[ "$name" == *_a[0-9]_* || "$name" == *_a[0-9][0-9]_* ]] && continue
            [[ "$name" == *_s[0-9]_* || "$name" == *_s[0-9][0-9]_* ]] && continue
            [[ "$name" == *_cover_[0-9]* ]] && continue
            MUX_FILES+=("$f")
            MUX_LABELS+=("[$label] $base")
        done < <(find "$dir" -maxdepth 1 -type f -iname "*.${ext}" -print0 2>/dev/null)
    done
}

# Parser sintaxa selectie ("1,3-5" / "ALL" / "NONE")
# Echo space-separated 0-based indices.
mux_parse_selection() {
    local input="$1" max="$2"
    input="${input// /}"
    if [[ -z "$input" || "$input" =~ ^[Aa][Ll][Ll]$ ]]; then
        local i; for ((i=0; i<max; i++)); do echo -n "$i "; done
        echo ""; return 0
    fi
    if [[ "$input" =~ ^[Nn][Oo][Nn][Ee]$ ]]; then echo ""; return 0; fi
    local out=""
    IFS=',' read -ra parts <<< "$input"
    for p in "${parts[@]}"; do
        if [[ "$p" =~ ^[0-9]+-[0-9]+$ ]]; then
            local a="${p%-*}" b="${p#*-}"
            local i; for ((i=a-1; i<=b-1; i++)); do
                [ "$i" -ge 0 ] && [ "$i" -lt "$max" ] && out+="$i "
            done
        elif [[ "$p" =~ ^[0-9]+$ ]]; then
            local i=$((p-1))
            [ "$i" -ge 0 ] && [ "$i" -lt "$max" ] && out+="$i "
        else
            echo "INVALID" >&2; return 1
        fi
    done
    echo "$out"
}

# Sanitize string pentru folosire in nume fisier
mux_sanitize() {
    local s="$1"
    s="${s//[^a-zA-Z0-9._-]/_}"
    echo "${s:0:64}"
}

# Promot user pentru selectie fisiere comuna (intre remux si demux)
declare -a MUX_SELECTED_FILES=()
mux_prompt_files() {
    MUX_SELECTED_FILES=()
    if [ ${#MUX_FILES[@]} -eq 0 ]; then
        echo ""
        echo "Niciun fisier suportat in $INPUT_DIR sau $OUTPUT_DIR."
        echo "Extensii suportate: ${SUPPORTED_INPUT_EXT[*]}"
        return 1
    fi
    echo ""
    echo "Fisiere disponibile:"
    local i
    for i in "${!MUX_LABELS[@]}"; do
        printf "  %2d) %s\n" "$((i+1))" "${MUX_LABELS[$i]}"
    done
    echo ""
    read -p "Selecteaza (ex: 1 sau 1,3,5 sau ALL) [implicit ALL]: " sel
    sel="${sel:-ALL}"
    if [[ "$sel" =~ ^[Aa][Ll][Ll]$ ]]; then
        MUX_SELECTED_FILES=("${MUX_FILES[@]}")
    else
        IFS=',' read -ra parts <<< "$sel"
        for p in "${parts[@]}"; do
            p="${p// /}"
            [[ "$p" =~ ^[0-9]+$ ]] || { echo "Index invalid: $p"; return 1; }
            idx=$((p-1))
            [ "$idx" -ge 0 ] && [ "$idx" -lt "${#MUX_FILES[@]}" ] || { echo "Index in afara range: $p"; return 1; }
            MUX_SELECTED_FILES+=("${MUX_FILES[$idx]}")
        done
    fi
    [ "${#MUX_SELECTED_FILES[@]}" -eq 0 ] && { echo "Nimic selectat."; return 1; }
    return 0
}

# ═════════════════════════════════════════════════════════════════════
# REMUX FLOW
# ═════════════════════════════════════════════════════════════════════

declare -a SELECTED_VIDEO_REL=()
declare -a SELECTED_AUDIO_REL=()
declare -a SELECTED_SUB_REL=()
declare -a SUB_COMPAT_ACTION=()
KEEP_ATTACH=0
KEEP_CHAPTERS=1

remux_display_and_select() {
    local file="$1" target="$2"
    SELECTED_VIDEO_REL=(); SELECTED_AUDIO_REL=(); SELECTED_SUB_REL=()
    SUB_COMPAT_ACTION=(); KEEP_ATTACH=0; KEEP_CHAPTERS=1

    local base; base="$(basename "$file")"
    local sz_mb=0
    sz_mb=$(( $(av_stat_size "$file" 2>/dev/null || echo 0) / 1024 / 1024 ))
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  $base (${sz_mb} MB) → .${target}"
    echo "═══════════════════════════════════════════════════════════════"

    remux_enumerate_streams "$file"

    local vcount=${#REMUX_VIDEO_INDICES[@]}
    echo ""
    if [ "$vcount" -eq 0 ]; then
        echo "VIDEO: nicio stream — skip fisier."
        return 1
    fi
    echo "VIDEO ($vcount):"
    local rel=0 abs_idx info codec lang title extra compat
    for abs_idx in "${REMUX_VIDEO_INDICES[@]}"; do
        info="${REMUX_STREAMS[$abs_idx]}"
        IFS='|' read -r _ codec lang title extra <<< "$info"
        compat=$(remux_stream_compat "$codec" video "$target")
        local warn=""
        [[ "$compat" == "drop" ]] && warn=" ⚠ incompat → drop"
        printf "  %2d) %-10s %-10s %s%s%s\n" "$((rel+1))" "$codec" "${extra}" "${lang:+[$lang] }" "${title}" "$warn"
        rel=$((rel+1))
    done
    if [ "$vcount" -eq 1 ]; then
        SELECTED_VIDEO_REL=(0)
        echo "  → 1 stream video, selectat automat."
    else
        read -p "Pastreaza video (ex: 1,3 sau ALL/NONE) [ALL]: " inp
        local picks; picks=$(mux_parse_selection "$inp" "$vcount") || { echo "Selectie invalida."; return 1; }
        SELECTED_VIDEO_REL=($picks)
    fi
    if [ ${#SELECTED_VIDEO_REL[@]} -eq 0 ]; then
        echo "ATENTIE: niciun stream video selectat — skip fisier."
        return 1
    fi

    local acount=${#REMUX_AUDIO_INDICES[@]}
    if [ "$acount" -gt 0 ]; then
        echo ""
        echo "AUDIO ($acount):"
        rel=0
        for abs_idx in "${REMUX_AUDIO_INDICES[@]}"; do
            info="${REMUX_STREAMS[$abs_idx]}"
            IFS='|' read -r _ codec lang title extra <<< "$info"
            compat=$(remux_stream_compat "$codec" audio "$target")
            local warn=""
            [[ "$compat" == "drop" ]] && warn=" ⚠ incompat → drop"
            printf "  %2d) %-10s %-6s %s%s%s\n" "$((rel+1))" "$codec" "${extra}" "${lang:+[$lang] }" "${title}" "$warn"
            rel=$((rel+1))
        done
        read -p "Pastreaza audio (ex: 1,3 sau ALL/NONE) [ALL]: " inp
        local picks; picks=$(mux_parse_selection "$inp" "$acount") || { echo "Selectie invalida."; return 1; }
        SELECTED_AUDIO_REL=($picks)
    else
        echo ""
        echo "AUDIO: niciun stream."
    fi

    local scount=${#REMUX_SUB_INDICES[@]}
    if [ "$scount" -gt 0 ]; then
        echo ""
        echo "SUBTITRARI ($scount):"
        rel=0
        local -a sub_compat_list=()
        for abs_idx in "${REMUX_SUB_INDICES[@]}"; do
            info="${REMUX_STREAMS[$abs_idx]}"
            IFS='|' read -r _ codec lang title extra <<< "$info"
            compat=$(remux_stream_compat "$codec" subtitle "$target")
            sub_compat_list+=("$compat")
            local warn=""
            case "$compat" in
                drop)         warn=" ⚠ incompat → drop" ;;
                convert:*)    warn=" → ${compat#convert:}" ;;
            esac
            printf "  %2d) %-15s %s%s%s\n" "$((rel+1))" "$codec" "${lang:+[$lang] }" "${title}" "$warn"
            rel=$((rel+1))
        done
        read -p "Pastreaza subtitrari (ex: 1,3 sau ALL/NONE) [ALL]: " inp
        local picks; picks=$(mux_parse_selection "$inp" "$scount") || { echo "Selectie invalida."; return 1; }
        SELECTED_SUB_REL=($picks)
        for rel in "${SELECTED_SUB_REL[@]}"; do
            SUB_COMPAT_ACTION+=("${sub_compat_list[$rel]}")
        done
    fi

    local tcount=${#REMUX_ATTACH_INDICES[@]}
    if [ "$tcount" -gt 0 ]; then
        echo ""
        if [[ "$target" == "mkv" ]]; then
            echo "ATTACHMENTS: $tcount fisier(e) (fonts/imagini)"
            read -p "Pastreaza atasamente? (D/n) [D]: " inp
            [[ "${inp,,}" == "n" ]] && KEEP_ATTACH=0 || KEEP_ATTACH=1
        else
            echo "ATTACHMENTS: $tcount — doar MKV suporta atasamente. Vor fi strip-uite."
            KEEP_ATTACH=0
        fi
    fi

    if [ "$REMUX_CHAPTER_COUNT" -gt 0 ]; then
        echo ""
        echo "CHAPTERS: $REMUX_CHAPTER_COUNT marker(e)"
        read -p "Pastreaza chapters? (D/n) [D]: " inp
        [[ "${inp,,}" == "n" ]] && KEEP_CHAPTERS=0 || KEEP_CHAPTERS=1
    else
        KEEP_CHAPTERS=0
    fi

    return 0
}

remux_run_for_file() {
    local file="$1" target="$2"
    local base; base="$(basename "$file")"
    local name="${base%.*}"
    local final_out="${OUTPUT_DIR}/${name}_remux.${target}"

    if [ -f "$final_out" ]; then
        read -p "$(basename "$final_out") exista. Suprascriu? (d/N) [N]: " ow
        [[ "${ow,,}" != "d" ]] && { echo "  Sarit."; return 1; }
        rm -f "$final_out"
    fi

    local -a map_args=()
    local rel
    for rel in "${SELECTED_VIDEO_REL[@]}"; do
        map_args+=("-map" "0:v:$rel")
    done
    for rel in "${SELECTED_AUDIO_REL[@]}"; do
        map_args+=("-map" "0:a:$rel")
    done
    local -a sub_map_rel=()
    local sub_idx=0
    local need_convert_movtext=0
    for rel in "${SELECTED_SUB_REL[@]}"; do
        local action="${SUB_COMPAT_ACTION[$sub_idx]}"
        if [[ "$action" != "drop" ]]; then
            sub_map_rel+=("$rel")
            map_args+=("-map" "0:s:$rel")
            [[ "$action" == "convert:mov_text" ]] && need_convert_movtext=1
        fi
        sub_idx=$((sub_idx+1))
    done

    if [ "$KEEP_ATTACH" -eq 1 ]; then
        map_args+=("-map" "0:t?")
    fi
    local chapters_arg=()
    if [ "$KEEP_CHAPTERS" -eq 1 ]; then
        chapters_arg=("-map_chapters" "0")
    else
        chapters_arg=("-map_chapters" "-1")
    fi

    local -a codec_args=("-c:v" "copy" "-c:a" "copy")
    case "$target" in
        mp4|mov)
            if [ "$need_convert_movtext" -eq 1 ]; then
                codec_args+=("-c:s" "mov_text")
            else
                codec_args+=("-c:s" "copy")
            fi
            ;;
        mkv|webm)
            codec_args+=("-c:s" "copy")
            ;;
    esac

    local -a extra_args=()
    local src_codec
    src_codec=$(detect_source_codec "$file")
    case "$target" in
        mp4|mov)
            case "$src_codec" in
                hevc) extra_args=("-tag:v" "hvc1") ;;
                av1)  extra_args=("-tag:v" "av01") ;;
                h264) extra_args=("-tag:v" "avc1") ;;
            esac
            extra_args+=("-movflags" "+faststart")
            ;;
    esac

    echo ""
    echo "  → $final_out"
    echo "  Streams: ${#SELECTED_VIDEO_REL[@]}v + ${#SELECTED_AUDIO_REL[@]}a + ${#sub_map_rel[@]}s + attach=${KEEP_ATTACH} chapters=${KEEP_CHAPTERS}"

    local start_ts; start_ts=$(date +%s)
    if ! ffmpeg -y -v warning -nostats -i "$file" \
            "${map_args[@]}" "${chapters_arg[@]}" \
            "${codec_args[@]}" "${extra_args[@]}" \
            "$final_out"; then
        echo "  EROARE: remux esuat pentru $base"
        rm -f "$final_out"
        return 1
    fi
    if [ ! -s "$final_out" ]; then
        echo "  EROARE: output gol."
        rm -f "$final_out"
        return 1
    fi
    # v71: remux al unui DV HEVC → re-scrie dvcC de container (ffmpeg -c copy o pierde,
    # chiar si la MP4→MP4). _dv_resignal_copy: detecteaza DV pe sursa + extrage raw din
    # output + dispatch (mkvmerge/MP4Box). No-op pe non-DV / non-ISO/mkv / unealta lipsa.
    _dv_resignal_copy "$file" "$final_out" "$target"
    local end_ts=$(date +%s)
    local sz_orig sz_new
    sz_orig=$(av_stat_size "$file" 2>/dev/null || echo 0)
    sz_new=$(av_stat_size "$final_out" 2>/dev/null || echo 0)
    echo "  ✓ Remux OK in $((end_ts-start_ts))s | $((sz_orig/1024/1024)) MB → $((sz_new/1024/1024)) MB"
    return 0
}

remux_flow() {
    mux_scan_input "$OUTPUT_DIR" "OUT"
    mux_scan_input "$INPUT_DIR"  "IN"
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  REMUX CONTAINER                             ║"
    echo "║  No re-encode. Selectie streams per fisier.  ║"
    echo "╚══════════════════════════════════════════════╝"
    mux_prompt_files || return 1

    echo ""
    echo "Container tinta:"
    echo "  1) mkv   — permisiv (recomandat pt streams diverse)"
    echo "  2) mp4   — distribute / web / mobile"
    echo "  3) mov   — Apple ecosystem (Final Cut, QuickTime)"
    echo "  4) webm  — web open (VP9/AV1 + Opus only)"
    echo ""
    read -p "Alege 1-4 [implicit: 1]: " tgt_choice
    local TARGET
    case "${tgt_choice:-1}" in
        1) TARGET="mkv" ;;
        2) TARGET="mp4" ;;
        3) TARGET="mov" ;;
        4) TARGET="webm" ;;
        *) echo "Optiune invalida."; return 1 ;;
    esac

    local TOTAL=0 OK=0 SKIP=0 FAIL=0
    av_wake_lock 2>/dev/null || true
    for f in "${MUX_SELECTED_FILES[@]}"; do
        TOTAL=$((TOTAL+1))
        if remux_display_and_select "$f" "$TARGET"; then
            _remux_preflight "$f" "$TARGET"
            if [ "$REMUX_PREFLIGHT_LEVEL" -ge 2 ]; then
                echo ""
                echo "PRE-FLIGHT FAIL — abort fisier:"
                for n in "${REMUX_PREFLIGHT_NOTES[@]}"; do echo "    - $n"; done
                FAIL=$((FAIL+1))
                continue
            fi
            if remux_run_for_file "$f" "$TARGET"; then
                OK=$((OK+1))
            else
                FAIL=$((FAIL+1))
            fi
        else
            SKIP=$((SKIP+1))
        fi
    done
    av_wake_unlock 2>/dev/null || true

    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  REMUX BATCH SUMMARY                         ║"
    echo "╠══════════════════════════════════════════════╣"
    printf "║  Total: %-3d  OK: %-3d  Skip: %-3d  Fail: %-3d   ║\n" "$TOTAL" "$OK" "$SKIP" "$FAIL"
    echo "║  Output: $OUTPUT_DIR"
    echo "╚══════════════════════════════════════════════╝"
    [ "$OK" -gt 0 ] && av_notify_done "Remux complet" "$OK/$TOTAL fisiere remuxate in .${TARGET}" 2>/dev/null || true
    return 0
}

# ═════════════════════════════════════════════════════════════════════
# DEMUX FLOW
# ═════════════════════════════════════════════════════════════════════

# Map codec subtitle → ext nativa
demux_subtitle_ext() {
    local codec="${1,,}"
    case "$codec" in
        subrip|srt)              echo "srt" ;;
        ass|ssa)                 echo "ass" ;;
        webvtt)                  echo "vtt" ;;
        hdmv_pgs_subtitle)       echo "sup" ;;
        dvd_subtitle)            echo "sub" ;;
        mov_text|tx3g)           echo "srt" ;;  # convert mov_text → srt
        *)                       echo "bin" ;;
    esac
}

# Map codec cover (attached_pic) → ext imagine
demux_cover_ext() {
    local codec="${1,,}"
    case "$codec" in
        mjpeg|jpeg)  echo "jpg" ;;
        png)         echo "png" ;;
        webp)        echo "webp" ;;
        bmp)         echo "bmp" ;;
        *)           echo "img" ;;
    esac
}

# Detect attached_pic streams (cover art) — populeaza DEMUX_COVER_IDX[] + DEMUX_COVER_CODEC[]
declare -a DEMUX_COVER_IDX=()
declare -a DEMUX_COVER_CODEC=()
declare -a DEMUX_DATA_IDX=()
declare -a DEMUX_DATA_TAG=()

demux_detect_special_streams() {
    local file="$1"
    DEMUX_COVER_IDX=(); DEMUX_COVER_CODEC=()
    DEMUX_DATA_IDX=(); DEMUX_DATA_TAG=()

    # attached_pic detection via ffprobe disposition flag
    # v59: csv=p=0 emite trailing comma pe SURSE cu [SIDE_DATA] sections (HDR10/HDR10+/HEVC)
    # → ultimul field gets "<value>," in loc de "<value>" → compare `[[ disp == "1" ]]` esueaza
    # silentios pe cover art pe HDR sources. Defensiv: strip trailing comma dupa CR.
    local raw
    raw=$(ffprobe -v error -select_streams v -show_entries stream=index,codec_name:stream_disposition=attached_pic \
        -of csv=p=0 "$file" 2>/dev/null || true)
    local idx codec disp
    while IFS=',' read -r idx codec disp; do
        [ -z "$idx" ] && continue
        disp="${disp%$'\r'}"
        disp="${disp%,}"   # v59 audit
        if [[ "$disp" == "1" ]]; then
            DEMUX_COVER_IDX+=("$idx")
            DEMUX_COVER_CODEC+=("$codec")
        fi
    done <<< "$raw"

    # Data streams (DJI djmd/dbgi, timecode tmcd, etc.)
    raw=$(ffprobe -v error -select_streams d -show_entries stream=index,codec_tag_string \
        -of csv=p=0 "$file" 2>/dev/null || true)
    local tag
    while IFS=',' read -r idx tag; do
        [ -z "$idx" ] && continue
        tag="${tag%$'\r'}"
        tag="${tag%,}"     # v59 audit: strip trailing comma de la csv multi-field
        DEMUX_DATA_IDX+=("$idx")
        DEMUX_DATA_TAG+=("${tag:-data}")
    done <<< "$raw"
}

# Genereaza Matroska chapter XML din ffprobe JSON.
# $1 = input file, $2 = output xml path
demux_generate_chapters_xml() {
    local file="$1" out="$2"
    local json
    json=$(ffprobe -v error -show_chapters -of json "$file" 2>/dev/null || true)
    [ -z "$json" ] && return 1

    # Parse via awk — extract id, start_time, end_time, tags.title per chapter
    # Output XML inline.
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<!DOCTYPE Chapters SYSTEM "matroskachapters.dtd">'
        echo '<Chapters>'
        echo '  <EditionEntry>'
        # awk parser — colectează triplets (start, end, title) pe baza structurii ffprobe JSON.
        # LC_ALL=C forteaza locale-ul C pentru printf "%f" — previne formatare cu virgula in EU locales.
        echo "$json" | LC_ALL=C awk '
            BEGIN { in_chap=0; in_tags=0; start=""; end=""; title="" }
            /"chapters":/ { in_chaplist=1; next }
            in_chaplist && /^[[:space:]]*\{[[:space:]]*$/ { in_chap=1; start=""; end=""; title=""; next }
            in_chap && /"start_time":/ {
                gsub(/[",]/, "", $0); split($0, a, ":"); start=a[2]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", start)
            }
            in_chap && /"end_time":/ {
                gsub(/[",]/, "", $0); split($0, a, ":"); end=a[2]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", end)
            }
            in_chap && /"tags":/ { in_tags=1; next }
            in_tags && /"title":/ {
                # extract value between quotes
                match($0, /"title":[[:space:]]*"[^"]*"/)
                if (RSTART) {
                    val = substr($0, RSTART, RLENGTH)
                    sub(/"title":[[:space:]]*"/, "", val)
                    sub(/"$/, "", val)
                    title = val
                }
                in_tags=0
            }
            in_chap && /^[[:space:]]*\}[[:space:]]*[,]?[[:space:]]*$/ {
                if (start != "" && end != "") {
                    # Convert seconds (float) to HH:MM:SS.nnnnnnnnn
                    s = start + 0; h = int(s/3600); s -= h*3600; m = int(s/60); s -= m*60
                    ts_start = sprintf("%02d:%02d:%012.9f", h, m, s)
                    s = end + 0; h = int(s/3600); s -= h*3600; m = int(s/60); s -= m*60
                    ts_end = sprintf("%02d:%02d:%012.9f", h, m, s)
                    # Escape XML special chars in title
                    gsub(/&/, "\\&amp;", title); gsub(/</, "\\&lt;", title); gsub(/>/, "\\&gt;", title)
                    printf "    <ChapterAtom>\n"
                    printf "      <ChapterTimeStart>%s</ChapterTimeStart>\n", ts_start
                    printf "      <ChapterTimeEnd>%s</ChapterTimeEnd>\n", ts_end
                    if (title != "") {
                        printf "      <ChapterDisplay>\n"
                        printf "        <ChapterString>%s</ChapterString>\n", title
                        printf "        <ChapterLanguage>eng</ChapterLanguage>\n"
                        printf "      </ChapterDisplay>\n"
                    }
                    printf "    </ChapterAtom>\n"
                }
                in_chap=0
            }
        '
        echo '  </EditionEntry>'
        echo '</Chapters>'
    } > "$out"
    [ -s "$out" ] && return 0 || return 1
}

# Display + select pentru demux. Set DEMUX_* arrays.
declare -a DEMUX_VIDEO_REL=()
declare -a DEMUX_AUDIO_REL=()
declare -a DEMUX_SUB_REL=()
DEMUX_EXTRACT_ATTACH=0
DEMUX_EXTRACT_CHAPTERS=0
DEMUX_EXTRACT_DATA=0

demux_display_and_select() {
    local file="$1"
    DEMUX_VIDEO_REL=(); DEMUX_AUDIO_REL=(); DEMUX_SUB_REL=()
    DEMUX_EXTRACT_ATTACH=0; DEMUX_EXTRACT_CHAPTERS=0; DEMUX_EXTRACT_DATA=0

    local base; base="$(basename "$file")"
    local sz_mb=0
    sz_mb=$(( $(av_stat_size "$file" 2>/dev/null || echo 0) / 1024 / 1024 ))
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  $base (${sz_mb} MB)"
    echo "═══════════════════════════════════════════════════════════════"

    remux_enumerate_streams "$file"
    demux_detect_special_streams "$file"

    # Filtreaza video real (exclude attached_pic) — folosim listele REMUX_*
    local -a real_video_abs=()
    local abs_idx
    for abs_idx in "${REMUX_VIDEO_INDICES[@]}"; do
        local is_cover=0
        for cv in "${DEMUX_COVER_IDX[@]}"; do
            [ "$cv" = "$abs_idx" ] && { is_cover=1; break; }
        done
        [ "$is_cover" -eq 0 ] && real_video_abs+=("$abs_idx")
    done

    # ── VIDEO (real, exclude cover) ──
    local vcount=${#real_video_abs[@]}
    if [ "$vcount" -gt 0 ]; then
        echo ""
        echo "VIDEO STREAMS ($vcount, exclud cover art):"
        local rel=0 info codec lang title extra
        for abs_idx in "${real_video_abs[@]}"; do
            info="${REMUX_STREAMS[$abs_idx]}"
            IFS='|' read -r _ codec lang title extra <<< "$info"
            printf "  %2d) %-10s %-10s %s%s\n" "$((rel+1))" "$codec" "${extra}" "${lang:+[$lang] }" "${title}"
            rel=$((rel+1))
        done
        read -p "Extrage video (ex: 1,3 sau ALL/NONE) [ALL]: " inp
        local picks; picks=$(mux_parse_selection "$inp" "$vcount") || { echo "Selectie invalida."; return 1; }
        DEMUX_VIDEO_REL=($picks)
    else
        echo ""
        echo "VIDEO: niciun stream real."
    fi

    # ── Cover art (auto-extract daca selectat ulterior) ──
    if [ ${#DEMUX_COVER_IDX[@]} -gt 0 ]; then
        echo ""
        echo "COVER ART: ${#DEMUX_COVER_IDX[@]} (attached_pic) → extrageri automate"
    fi

    # ── AUDIO ──
    local acount=${#REMUX_AUDIO_INDICES[@]}
    if [ "$acount" -gt 0 ]; then
        echo ""
        echo "AUDIO STREAMS ($acount):"
        local rel=0 info codec lang title extra
        for abs_idx in "${REMUX_AUDIO_INDICES[@]}"; do
            info="${REMUX_STREAMS[$abs_idx]}"
            IFS='|' read -r _ codec lang title extra <<< "$info"
            printf "  %2d) %-10s %-6s %s%s\n" "$((rel+1))" "$codec" "${extra}" "${lang:+[$lang] }" "${title}"
            rel=$((rel+1))
        done
        read -p "Extrage audio (ex: 1,3 sau ALL/NONE) [ALL]: " inp
        local picks; picks=$(mux_parse_selection "$inp" "$acount") || { echo "Selectie invalida."; return 1; }
        DEMUX_AUDIO_REL=($picks)
    else
        echo ""
        echo "AUDIO: niciun stream."
    fi

    # ── SUBTITLE ──
    local scount=${#REMUX_SUB_INDICES[@]}
    if [ "$scount" -gt 0 ]; then
        echo ""
        echo "SUBTITRARI ($scount):"
        local rel=0 info codec lang title extra
        for abs_idx in "${REMUX_SUB_INDICES[@]}"; do
            info="${REMUX_STREAMS[$abs_idx]}"
            IFS='|' read -r _ codec lang title extra <<< "$info"
            local ext_native; ext_native=$(demux_subtitle_ext "$codec")
            printf "  %2d) %-15s %s%s → .%s\n" "$((rel+1))" "$codec" "${lang:+[$lang] }" "${title}" "$ext_native"
            rel=$((rel+1))
        done
        read -p "Extrage subtitrari (ex: 1,3 sau ALL/NONE) [ALL]: " inp
        local picks; picks=$(mux_parse_selection "$inp" "$scount") || { echo "Selectie invalida."; return 1; }
        DEMUX_SUB_REL=($picks)
    fi

    # ── Attachments ──
    local tcount=${#REMUX_ATTACH_INDICES[@]}
    if [ "$tcount" -gt 0 ]; then
        echo ""
        echo "ATTACHMENTS: $tcount fisier(e) (fonts/imagini)"
        read -p "Extrage atasamente in <name>_attach/? (D/n) [D]: " inp
        [[ "${inp,,}" == "n" ]] && DEMUX_EXTRACT_ATTACH=0 || DEMUX_EXTRACT_ATTACH=1
    fi

    # ── Chapters ──
    if [ "$REMUX_CHAPTER_COUNT" -gt 0 ]; then
        echo ""
        echo "CHAPTERS: $REMUX_CHAPTER_COUNT marker(e)"
        read -p "Genereaza <name>_chapters.xml (Matroska)? (D/n) [D]: " inp
        [[ "${inp,,}" == "n" ]] && DEMUX_EXTRACT_CHAPTERS=0 || DEMUX_EXTRACT_CHAPTERS=1
    fi

    # ── Data streams (DJI, timecode, etc.) — opt-in ──
    if [ ${#DEMUX_DATA_IDX[@]} -gt 0 ]; then
        echo ""
        echo "DATA STREAMS: ${#DEMUX_DATA_IDX[@]} (codec_tags: ${DEMUX_DATA_TAG[*]})"
        echo "  Nota: pentru telemetrie DJI/GoPro folosibila (CSV/SRT/GPX), foloseste opt 4"
        echo "        'Telemetrie video' din meniul principal. Aici e doar binary dump."
        read -p "Extrage binary in <name>_data/? (d/N) [N]: " inp
        [[ "${inp,,}" == "d" ]] && DEMUX_EXTRACT_DATA=1 || DEMUX_EXTRACT_DATA=0
    fi

    return 0
}

# Ruleaza demux per fisier. Output in $OUTPUT_DIR.
# Folosit: DEMUX_VIDEO_REL/AUDIO/SUB + DEMUX_EXTRACT_ATTACH/CHAPTERS/DATA + DEMUX_COVER_*
demux_run_for_file() {
    local file="$1"
    local base; base="$(basename "$file")"
    local name="${base%.*}"
    local out_dir="$OUTPUT_DIR"
    local count=0 fail=0
    local rel abs_idx info codec lang title extra ext_native

    # Helper local — ruleaza ffmpeg si verifica exit code + output non-empty
    # Returneaza 0=success, 1=fail. stderr-ul ffmpeg afisat doar pe failure.
    _demux_ffmpeg() {
        local out_file="$1"; shift
        local err
        err=$(ffmpeg -y -v warning -nostats -hide_banner "$@" 2>&1)
        local rc=$?
        if [ "$rc" -eq 0 ] && [ -s "$out_file" ]; then
            return 0
        fi
        [ -n "$err" ] && echo "$err" >&2
        rm -f "$out_file" 2>/dev/null
        return 1
    }

    # ── Video → mkv wrapper ──
    for rel in "${DEMUX_VIDEO_REL[@]}"; do
        local real_video_abs=()
        local cv
        for abs_idx in "${REMUX_VIDEO_INDICES[@]}"; do
            local is_cover=0
            for cv in "${DEMUX_COVER_IDX[@]}"; do
                [ "$cv" = "$abs_idx" ] && { is_cover=1; break; }
            done
            [ "$is_cover" -eq 0 ] && real_video_abs+=("$abs_idx")
        done
        abs_idx="${real_video_abs[$rel]}"
        info="${REMUX_STREAMS[$abs_idx]}"
        IFS='|' read -r _ codec lang title extra <<< "$info"
        local out="${out_dir}/${name}_v${rel}_$(mux_sanitize "$codec").mkv"
        if _demux_ffmpeg "$out" -i "$file" -map "0:$abs_idx" -c copy "$out"; then
            echo "  ✓ video #$rel ($codec) → $(basename "$out")"
            count=$((count+1))
        else
            echo "  ✗ video #$rel ($codec) — esuat"
            fail=$((fail+1))
        fi
    done

    # ── Audio → mka wrapper ──
    for rel in "${DEMUX_AUDIO_REL[@]}"; do
        abs_idx="${REMUX_AUDIO_INDICES[$rel]}"
        info="${REMUX_STREAMS[$abs_idx]}"
        IFS='|' read -r _ codec lang title extra <<< "$info"
        local lang_suffix=""
        [ -n "$lang" ] && lang_suffix="_$(mux_sanitize "$lang")"
        local out="${out_dir}/${name}_a${rel}_$(mux_sanitize "$codec")${lang_suffix}.mka"
        if _demux_ffmpeg "$out" -i "$file" -map "0:$abs_idx" -c copy "$out"; then
            echo "  ✓ audio #$rel ($codec${lang:+, $lang}) → $(basename "$out")"
            count=$((count+1))
        else
            echo "  ✗ audio #$rel ($codec) — esuat"
            fail=$((fail+1))
        fi
    done

    # ── Subtitle → native ext ──
    for rel in "${DEMUX_SUB_REL[@]}"; do
        abs_idx="${REMUX_SUB_INDICES[$rel]}"
        info="${REMUX_STREAMS[$abs_idx]}"
        IFS='|' read -r _ codec lang title extra <<< "$info"
        ext_native=$(demux_subtitle_ext "$codec")
        local lang_suffix=""
        [ -n "$lang" ] && lang_suffix="_$(mux_sanitize "$lang")"
        local out="${out_dir}/${name}_s${rel}_$(mux_sanitize "$codec")${lang_suffix}.${ext_native}"
        # Pentru mov_text/tx3g → convert la srt; restul → copy
        local sc_codec_arg="copy"
        [[ "$codec" == "mov_text" || "$codec" == "tx3g" ]] && sc_codec_arg="srt"
        # dvd_subtitle necesita .idx + .sub pair (handle separat)
        if [[ "$codec" == "dvd_subtitle" ]]; then
            # ffmpeg cu output .sub creeaza si .idx automat
            if _demux_ffmpeg "$out" -i "$file" -map "0:$abs_idx" -c copy "$out"; then
                echo "  ✓ subtitle #$rel ($codec${lang:+, $lang}) → $(basename "$out") + .idx"
                count=$((count+1))
            else
                echo "  ✗ subtitle #$rel ($codec) — esuat"
                fail=$((fail+1))
            fi
        else
            if _demux_ffmpeg "$out" -i "$file" -map "0:$abs_idx" -c:s "$sc_codec_arg" "$out"; then
                echo "  ✓ subtitle #$rel ($codec${lang:+, $lang}) → $(basename "$out")"
                count=$((count+1))
            else
                echo "  ✗ subtitle #$rel ($codec) — esuat"
                fail=$((fail+1))
            fi
        fi
    done

    # ── Cover art auto-extract ──
    local cidx=0 cabs ccodec cext
    for cabs in "${DEMUX_COVER_IDX[@]}"; do
        ccodec="${DEMUX_COVER_CODEC[$cidx]}"
        cext=$(demux_cover_ext "$ccodec")
        local out="${out_dir}/${name}_cover_${cidx}.${cext}"
        if _demux_ffmpeg "$out" -i "$file" -map "0:$cabs" -c copy -frames:v 1 "$out"; then
            echo "  ✓ cover #$cidx ($ccodec) → $(basename "$out")"
            count=$((count+1))
        else
            echo "  ✗ cover #$cidx ($ccodec) — esuat"
            fail=$((fail+1))
        fi
        cidx=$((cidx+1))
    done

    # ── Chapters XML ──
    if [ "$DEMUX_EXTRACT_CHAPTERS" -eq 1 ]; then
        local chapters_out="${out_dir}/${name}_chapters.xml"
        if demux_generate_chapters_xml "$file" "$chapters_out"; then
            echo "  ✓ chapters → $(basename "$chapters_out") ($REMUX_CHAPTER_COUNT capitole)"
            count=$((count+1))
        else
            echo "  ✗ chapters — generare XML esuata"
            fail=$((fail+1))
        fi
    fi

    # ── Attachments dump ──
    # v59 audit: dedup pe filename — MKV-urile cu mai multe atasamente cu acelasi nume
    # (ex: 2× Arial.ttf din fonturi pereche) faceau ca al doilea sa suprascrie pe primul
    # tacit. Acum daca exista deja un fisier cu numele tinta, adaugam suffix _<idx>.
    # In plus, folosim numele explicit (mux_sanitize-ed) in loc de "" ca ffmpeg sa scrie
    # exact unde vrem noi (path absolut), nu in CWD.
    if [ "$DEMUX_EXTRACT_ATTACH" -eq 1 ] && [ ${#REMUX_ATTACH_INDICES[@]} -gt 0 ]; then
        local attach_dir="${out_dir}/${name}_attach"
        mkdir -p "$attach_dir"
        local t_rel=0 abs
        local n_ok=0
        for abs in "${REMUX_ATTACH_INDICES[@]}"; do
            info="${REMUX_STREAMS[$abs]}"
            IFS='|' read -r _ codec _ title _ <<< "$info"
            local attach_name="${title:-attachment_${t_rel}.bin}"
            attach_name=$(mux_sanitize "$attach_name")
            # Dedup: daca numele exista deja, adauga suffix _N inainte de extensie
            local final_name="$attach_name"
            if [ -e "$attach_dir/$final_name" ]; then
                local _base="${attach_name%.*}"
                local _ext="${attach_name##*.}"
                [[ "$_base" == "$attach_name" ]] && _ext=""
                local _i=2
                while [ -e "$attach_dir/${_base}_${_i}${_ext:+.$_ext}" ]; do
                    _i=$((_i+1))
                done
                final_name="${_base}_${_i}${_ext:+.$_ext}"
            fi
            if ffmpeg -y -v error -dump_attachment:t:$t_rel "$attach_dir/$final_name" -i "$file" </dev/null 2>/dev/null; then
                if [ -s "$attach_dir/$final_name" ]; then
                    n_ok=$((n_ok+1))
                fi
            fi
            t_rel=$((t_rel+1))
        done
        if [ "$n_ok" -gt 0 ]; then
            echo "  ✓ attachments → $(basename "$attach_dir")/ ($n_ok fisiere)"
            count=$((count+1))
        else
            echo "  ✗ attachments — niciun fisier extras"
            fail=$((fail+1))
            rmdir "$attach_dir" 2>/dev/null
        fi
    fi

    # ── Data streams binary dump (opt-in) ──
    if [ "$DEMUX_EXTRACT_DATA" -eq 1 ] && [ ${#DEMUX_DATA_IDX[@]} -gt 0 ]; then
        local data_dir="${out_dir}/${name}_data"
        mkdir -p "$data_dir"
        local d_idx=0 d_abs d_tag
        for d_abs in "${DEMUX_DATA_IDX[@]}"; do
            d_tag="${DEMUX_DATA_TAG[$d_idx]}"
            local out="${data_dir}/track_d${d_idx}_$(mux_sanitize "$d_tag").bin"
            if _demux_ffmpeg "$out" -i "$file" -map "0:$d_abs" -c copy -f data "$out"; then
                echo "  ✓ data #$d_idx ($d_tag) → $(basename "$out")"
                count=$((count+1))
            else
                fail=$((fail+1))
            fi
            d_idx=$((d_idx+1))
        done
    fi

    echo "  Total: $count extras, $fail esuate"
    [ "$fail" -eq 0 ] && return 0 || return 1
}

demux_flow() {
    mux_scan_input "$OUTPUT_DIR" "OUT"
    mux_scan_input "$INPUT_DIR"  "IN"
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  DEMUX STREAMS                               ║"
    echo "║  Extract streams ca fisiere separate.        ║"
    echo "║  Video → .mkv | Audio → .mka | Sub → native  ║"
    echo "╚══════════════════════════════════════════════╝"
    mux_prompt_files || return 1

    local TOTAL=0 OK=0 SKIP=0 FAIL=0
    av_wake_lock 2>/dev/null || true
    for f in "${MUX_SELECTED_FILES[@]}"; do
        TOTAL=$((TOTAL+1))
        if demux_display_and_select "$f"; then
            if demux_run_for_file "$f"; then
                OK=$((OK+1))
            else
                FAIL=$((FAIL+1))
            fi
        else
            SKIP=$((SKIP+1))
        fi
    done
    av_wake_unlock 2>/dev/null || true

    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  DEMUX BATCH SUMMARY                         ║"
    echo "╠══════════════════════════════════════════════╣"
    printf "║  Total: %-3d  OK: %-3d  Skip: %-3d  Fail: %-3d   ║\n" "$TOTAL" "$OK" "$SKIP" "$FAIL"
    echo "║  Output: $OUTPUT_DIR"
    echo "╚══════════════════════════════════════════════╝"
    [ "$OK" -gt 0 ] && av_notify_done "Demux complet" "$OK/$TOTAL fisiere procesate" 2>/dev/null || true
    return 0
}

# ═════════════════════════════════════════════════════════════════════
# MUX FLOW (v50)
# ═════════════════════════════════════════════════════════════════════
# Manual selection. Scan doar InputVideos. Output: <video_base>_mux.<ext>
# Streams ordering = ordinea introdusa de user in prompts.

MUX_EXT_VIDEO=(mkv webm mp4 m4v mov ts m2ts mts vob mxf hevc h265 h264 265 264 av1 ivf vp9)
MUX_EXT_AUDIO=(mka m4a eac3 ac3 aac flac opus mp3 wav oga ogg)
MUX_EXT_SUB=(srt ass ssa vtt sup idx)
MUX_EXT_CHAPTERS=(xml txt)
MUX_EXT_ATTACH=(ttf otf ttc png jpg jpeg webp bmp)

# Populeaza output array cu fisiere din $INPUT_DIR matching extensiile date.
# Exclude propriile output-uri (_mux/_remux/_v<idx>_/etc).
# Usage: mux_collect_files <out_array_name> ext1 ext2 ...
mux_collect_files() {
    local -n _out=$1; shift
    local ext_list=("$@")
    _out=()
    local ext
    for ext in "${ext_list[@]}"; do
        while IFS= read -r -d '' f; do
            local base; base="$(basename "$f")"
            local name="${base%.*}"
            [[ "$name" == *_mux ]] && continue
            [[ "$name" == *_remux ]] && continue
            [[ "$name" == *_v[0-9]_* || "$name" == *_v[0-9][0-9]_* ]] && continue
            [[ "$name" == *_a[0-9]_* || "$name" == *_a[0-9][0-9]_* ]] && continue
            [[ "$name" == *_s[0-9]_* || "$name" == *_s[0-9][0-9]_* ]] && continue
            [[ "$name" == *_cover_[0-9]* ]] && continue
            _out+=("$f")
        done < <(find "$INPUT_DIR" -maxdepth 1 -type f -iname "*.${ext}" -print0 2>/dev/null)
    done
}

# Extract lang code (2-3 letter ISO) din numele fisierului.
# Acceptate: name.eng.srt | name_eng.mka | track_ron.eac3
# Returneaza string gol daca nu detecteaza.
mux_lang_from_filename() {
    local file="$1"
    local base; base="$(basename "$file")"
    local name="${base%.*}"
    # Pattern .<lang> la final (dupa stripping ext)
    if [[ "$name" =~ \.([a-z]{2,3})$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    # Pattern _<lang> la final
    if [[ "$name" =~ _([a-z]{2,3})$ ]]; then
        # Exclude pattern-uri tehnice frecvente
        local lang="${BASH_REMATCH[1]}"
        case "$lang" in
            mkv|mp4|mov|aac|ac3|mp3|srt|ass|sup|idx|sub|hd|sd|hq|lq) ;;
            *) echo "$lang"; return ;;
        esac
    fi
    echo ""
}

# Codec detect pe input (raw stream sau container).
# $1=file, $2=type (video|audio|subtitle). Returneaza lowercase codec_name sau gol.
mux_codec_of() {
    local file="$1" type="$2"
    local spec
    case "$type" in
        video) spec="v:0" ;;
        audio) spec="a:0" ;;
        subtitle) spec="s:0" ;;
        *) spec="v:0" ;;
    esac
    local c
    # v57: default= in loc de csv=p=0 — single-field emite trailing comma
    c=$(ffprobe -v error -select_streams "$spec" -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null || true)
    c="${c%$'\r'}"
    c="${c%$'\n'}"
    echo "${c,,}"
}

# Display lista + selectie ordonata (ordinea = ordinea introdusa).
# $1=mode (single|multi), $2=allow_none (0|1), $3=label, $4=nameref input array, $5=nameref output array
mux_pick_from_list() {
    local mode="$1" allow_none="$2" label="$3"
    local -n _files=$4
    local -n _picks=$5
    _picks=()
    if [ "${#_files[@]}" -eq 0 ]; then
        echo "  ($label: niciun fisier disponibil in InputVideos)"
        if [ "$allow_none" -eq 1 ]; then return 0; fi
        return 1
    fi
    echo ""
    echo "$label disponibile in InputVideos:"
    local i
    for i in "${!_files[@]}"; do
        printf "  %2d) %s\n" "$((i+1))" "$(basename "${_files[$i]}")"
    done
    local prompt_text
    if [ "$mode" = "single" ]; then
        if [ "$allow_none" -eq 1 ]; then
            prompt_text="Pick $label (ex: 2) sau NONE [NONE]"
        else
            prompt_text="Pick $label (1 index, ex: 2)"
        fi
    else
        if [ "$allow_none" -eq 1 ]; then
            prompt_text="Pick $label (ex: 1,3,2 — ordinea conteaza) sau NONE [NONE]"
        else
            prompt_text="Pick $label (ex: 1,3,2 — ordinea conteaza)"
        fi
    fi
    local inp
    read -p "${prompt_text}: " inp
    local clean="${inp// /}"
    if [ -z "$clean" ] || [[ "$clean" =~ ^[Nn][Oo][Nn][Ee]$ ]]; then
        if [ "$allow_none" -eq 1 ]; then return 0; fi
        echo "  Selectie obligatorie pentru $label."
        return 1
    fi
    local -a parts
    IFS=',' read -ra parts <<< "$clean"
    if [ "$mode" = "single" ] && [ "${#parts[@]}" -gt 1 ]; then
        echo "  Eroare: doar un fisier permis pentru $label."
        return 1
    fi
    local p idx
    for p in "${parts[@]}"; do
        [[ "$p" =~ ^[0-9]+$ ]] || { echo "  Index invalid: $p"; return 1; }
        idx=$((p-1))
        if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#_files[@]}" ]; then
            echo "  Index in afara range: $p"; return 1
        fi
        _picks+=("${_files[$idx]}")
    done
    return 0
}

# Converteste Matroska chapter XML (output din Demux opt 2) la FFMETADATA1
# pentru import in ffmpeg. ffmpeg nu citeste XML chapter direct, doar FFMETADATA.
# $1=in xml, $2=out ffmetadata. Returneaza 0 ok / 1 fail. Stderr: motiv fail.
mux_xml_to_ffmetadata() {
    local xml_in="$1" out="$2"
    if [ ! -f "$xml_in" ]; then
        echo "mux_xml_to_ffmetadata: fisier inexistent: $xml_in" >&2
        return 1
    fi
    # v59 audit: pre-check structura — fail loud cu motiv specific (gol / fara root /
    # fara ChapterAtom) in loc de output gol fara explicatie.
    if [ ! -s "$xml_in" ]; then
        echo "mux_xml_to_ffmetadata: XML gol" >&2
        return 1
    fi
    if ! grep -q '<Chapters' "$xml_in" 2>/dev/null; then
        echo "mux_xml_to_ffmetadata: lipseste tag-ul <Chapters> (root Matroska)" >&2
        return 1
    fi
    if ! grep -q '<ChapterAtom' "$xml_in" 2>/dev/null; then
        echo "mux_xml_to_ffmetadata: niciun <ChapterAtom> in XML" >&2
        return 1
    fi
    {
        echo ";FFMETADATA1"
        LC_ALL=C awk '
            function parse_ts(s,   parts, h, m, sec, ms) {
                # HH:MM:SS.fffffffff -> millisec
                if (split(s, parts, ":") != 3) return -1
                h = parts[1] + 0
                m = parts[2] + 0
                sec = parts[3] + 0
                ms = int((h * 3600 + m * 60 + sec) * 1000 + 0.5)
                return ms
            }
            BEGIN { start=-1; end=-1; title="" }
            /<ChapterTimeStart>/ {
                match($0, /<ChapterTimeStart>([^<]+)<\/ChapterTimeStart>/, m)
                if (m[1]) start = parse_ts(m[1])
            }
            /<ChapterTimeEnd>/ {
                match($0, /<ChapterTimeEnd>([^<]+)<\/ChapterTimeEnd>/, m)
                if (m[1]) end = parse_ts(m[1])
            }
            /<ChapterString>/ {
                match($0, /<ChapterString>([^<]*)<\/ChapterString>/, m)
                if (m[1] != "") {
                    title = m[1]
                    gsub(/&amp;/, "\\&", title); gsub(/&lt;/, "<", title); gsub(/&gt;/, ">", title)
                    # Escape pentru FFMETADATA: \ ; # = newline
                    gsub(/\\/, "\\\\", title); gsub(/;/, "\\;", title); gsub(/#/, "\\#", title); gsub(/=/, "\\=", title)
                }
            }
            /<\/ChapterAtom>/ {
                if (start >= 0 && end >= 0) {
                    printf "\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=%d\nEND=%d\n", start, end
                    if (title != "") printf "title=%s\n", title
                }
                start=-1; end=-1; title=""
            }
        ' "$xml_in"
    } > "$out"
    if [ -s "$out" ] && grep -q '\[CHAPTER\]' "$out"; then
        return 0
    fi
    # v59 audit: failure cu motiv specific (ChapterAtom prezent dar timestamp parse a esuat)
    echo "mux_xml_to_ffmetadata: parse esuat (ChapterAtom prezent dar fara ChapterTimeStart/End valide)" >&2
    rm -f "$out" 2>/dev/null
    return 1
}

# Mime type pentru attachments (MKV).
mux_attach_mime() {
    local ext="${1,,}"
    case "$ext" in
        ttf) echo "application/x-truetype-font" ;;
        otf) echo "application/vnd.ms-opentype" ;;
        ttc) echo "font/collection" ;;
        png) echo "image/png" ;;
        jpg|jpeg) echo "image/jpeg" ;;
        webp) echo "image/webp" ;;
        bmp) echo "image/bmp" ;;
        *) echo "application/octet-stream" ;;
    esac
}

mux_flow() {
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  MUX STREAMS                                 ║"
    echo "║  Combina fisiere raw/wrapped intr-un         ║"
    echo "║  container nou. Manual selection.            ║"
    echo "║  Source: InputVideos                         ║"
    echo "╚══════════════════════════════════════════════╝"

    # ── Step 1: VIDEO (mandatory, single) ──
    local -a video_files=()
    mux_collect_files video_files "${MUX_EXT_VIDEO[@]}"
    local -a picked_video=()
    if ! mux_pick_from_list single 0 "VIDEO" video_files picked_video; then
        return 1
    fi
    [ "${#picked_video[@]}" -eq 0 ] && { echo "Abort: video lipsa."; return 1; }
    local video="${picked_video[0]}"
    local video_base; video_base="$(basename "$video")"
    local video_name="${video_base%.*}"

    # ── Step 2: AUDIO (optional, multi) ──
    local -a audio_files=()
    mux_collect_files audio_files "${MUX_EXT_AUDIO[@]}"
    local -a picked_audio=()
    mux_pick_from_list multi 1 "AUDIO" audio_files picked_audio || return 1

    # ── Step 3: SUBTITRARI (optional, multi) ──
    local -a sub_files_all=()
    mux_collect_files sub_files_all "${MUX_EXT_SUB[@]}"
    # Filtreaza .sub orfan: pastram doar .idx (perechea VobSub) si .sub doar daca nu exista .idx pereche
    local -a sub_files=()
    local sf sf_ext sf_base sf_name idx_path
    for sf in "${sub_files_all[@]}"; do
        sf_ext="${sf##*.}"; sf_ext="${sf_ext,,}"
        if [ "$sf_ext" = "sub" ]; then
            sf_base="$(basename "$sf")"; sf_name="${sf_base%.*}"
            idx_path="$(dirname "$sf")/${sf_name}.idx"
            [ -f "$idx_path" ] && continue
        fi
        sub_files+=("$sf")
    done
    local -a picked_subs=()
    mux_pick_from_list multi 1 "SUBTITRARI" sub_files picked_subs || return 1

    # ── Step 4: CHAPTERS (optional, single) ──
    local -a chapter_files=()
    mux_collect_files chapter_files "${MUX_EXT_CHAPTERS[@]}"
    local -a picked_chapters=()
    mux_pick_from_list single 1 "CHAPTERS (xml/txt)" chapter_files picked_chapters || return 1

    # ── Step 5: ATTACHMENTS (optional, multi) ──
    local -a attach_files=()
    mux_collect_files attach_files "${MUX_EXT_ATTACH[@]}"
    local -a picked_attach=()
    mux_pick_from_list multi 1 "ATTACHMENTS (fonts/images)" attach_files picked_attach || return 1

    # ── Step 6: Container target ──
    echo ""
    echo "Container tinta:"
    echo "  1) mkv   — permisiv (recomandat pt streams diverse) [implicit]"
    echo "  2) mp4   — distribute / web / mobile"
    echo "  3) mov   — Apple ecosystem"
    echo "  4) webm  — VP8/VP9/AV1 + Opus/Vorbis"
    echo ""
    local tgt_choice
    read -p "Alege 1-4 [implicit: 1]: " tgt_choice
    local TARGET
    case "${tgt_choice:-1}" in
        1) TARGET="mkv" ;;
        2) TARGET="mp4" ;;
        3) TARGET="mov" ;;
        4) TARGET="webm" ;;
        *) echo "Optiune invalida."; return 1 ;;
    esac

    # ── Output overwrite check (earlier — sa nu pierdem timpul cu metadata daca user anuleaza) ──
    local final_out="${OUTPUT_DIR}/${video_name}_mux.${TARGET}"
    if [ -f "$final_out" ]; then
        local ow
        read -p "$(basename "$final_out") exista. Suprascriu? (d/N) [N]: " ow
        [[ "${ow,,}" != "d" ]] && { echo "Sarit."; return 1; }
        rm -f "$final_out"
    fi

    # ── Step 7: Per-stream compat check ──
    local vc; vc=$(mux_codec_of "$video" video)
    [ -z "$vc" ] && { echo "  EROARE: nu pot detecta codec video pentru $(basename "$video")."; return 1; }
    local v_compat; v_compat=$(remux_stream_compat "$vc" video "$TARGET")
    if [[ "$v_compat" == "drop" ]]; then
        echo ""
        echo "PRE-FLIGHT FAIL: codec video '$vc' incompatibil cu .$TARGET — abort."
        return 1
    fi

    # v69 audit FIX: video elementary BRUT annexb/OBU (hevc/h264/av1 — FARA PTS
    # pe frame-uri reordonate) → muxerul matroska/webm refuza ("Can't write
    # packet with unknown timestamp", output gol). Pre-wrap in MP4 temporar
    # (muxerul mp4 deriva timestamps), apoi mux normal cu MP4-ul ca input video.
    # IVF si containerele NU sunt afectate (poarta PTS).
    local _raw_wrap="" _dv_raw_src=""
    if [[ "$TARGET" == "mkv" || "$TARGET" == "webm" ]]; then
        local _vext="${video##*.}"; _vext="${_vext,,}"
        case "$_vext" in
            hevc|h265|265|h264|264|av1)
                echo "  Video brut .$_vext → pas intermediar MP4 (matroska/webm cer PTS)..."
                _raw_wrap=$(av_mktemp_ext mp4)
                local -a _wtag=()
                case "$vc" in
                    hevc) _wtag=(-tag:v hvc1) ;;
                    h264) _wtag=(-tag:v avc1) ;;
                    av1)  _wtag=(-tag:v av01) ;;
                esac
                if ffmpeg -v error -y -i "$video" -map 0:v:0 -c copy "${_wtag[@]}" "$_raw_wrap" 2>/dev/null \
                   && [ -s "$_raw_wrap" ]; then
                    # v70 (HEVC) / v71 (AV1 .av1 OBU): video brut → MKV → pastram calea raw
                    # pt post-procesare dvcC (mkvmerge scrie DOVI config din RPU pe HEVC SI AV1).
                    [[ "$TARGET" == "mkv" && ( "$_vext" == "hevc" || "$_vext" == "h265" || "$_vext" == "265" || "$_vext" == "av1" ) ]] && _dv_raw_src="$video"
                    video="$_raw_wrap"
                else
                    rm -f "$_raw_wrap"
                    echo "  EROARE: impachetarea intermediara a video-ului brut a esuat — abort."
                    return 1
                fi
                ;;
        esac
    fi
    # v71: AV1 IVF → MKV (IVF poarta PTS → sare raw-wrap-ul de mai sus) → pastram calea raw
    # pt post-procesare dvcC (mkvmerge scrie DOVI config din RPU). MP4 ramane HEVC-only.
    if [[ "$TARGET" == "mkv" && "${video##*.}" == "ivf" ]]; then _dv_raw_src="$video"; fi
    # v71: pe tinta MP4/MOV, video brut HEVC DV → pastram calea raw pt post-procesare
    # dvcC (MP4Box scrie box-ul dvcC din RPU). MP4/MOV nu necesita raw-wrap (deriva PTS).
    if [[ "$TARGET" == "mp4" || "$TARGET" == "mov" || "$TARGET" == "m4v" ]]; then
        local _vextmp4="${video##*.}"; _vextmp4="${_vextmp4,,}"
        case "$_vextmp4" in hevc|h265|265) _dv_raw_src="$video" ;; esac
    fi

    local -a audio_drop_idx=() audio_codec=()
    local i ac a_compat
    for i in "${!picked_audio[@]}"; do
        ac=$(mux_codec_of "${picked_audio[$i]}" audio)
        audio_codec+=("$ac")
        a_compat=$(remux_stream_compat "$ac" audio "$TARGET")
        if [[ "$a_compat" == "drop" ]]; then
            echo "  WARN: audio '$(basename "${picked_audio[$i]}")' ($ac) incompatibil cu .$TARGET — va fi sarit."
            audio_drop_idx+=("$i")
        fi
    done

    local -a sub_codec=() sub_action=() sub_drop_idx=()
    local sc s_compat
    local need_movtext=0
    for i in "${!picked_subs[@]}"; do
        sc=$(mux_codec_of "${picked_subs[$i]}" subtitle)
        # Fallback pentru .idx detectie inconsistenta
        local sf_ext="${picked_subs[$i]##*.}"; sf_ext="${sf_ext,,}"
        [ -z "$sc" ] && [ "$sf_ext" = "idx" ] && sc="dvd_subtitle"
        [ -z "$sc" ] && [ "$sf_ext" = "sup" ] && sc="hdmv_pgs_subtitle"
        sub_codec+=("$sc")
        s_compat=$(remux_stream_compat "$sc" subtitle "$TARGET")
        sub_action+=("$s_compat")
        if [[ "$s_compat" == "drop" ]]; then
            echo "  WARN: sub '$(basename "${picked_subs[$i]}")' ($sc) incompatibil cu .$TARGET — va fi sarit."
            sub_drop_idx+=("$i")
        elif [[ "$s_compat" == convert:* ]]; then
            echo "  Sub '$(basename "${picked_subs[$i]}")' ($sc) → ${s_compat#convert:}"
            [[ "$s_compat" == "convert:mov_text" ]] && need_movtext=1
        fi
    done

    if [ "${#picked_attach[@]}" -gt 0 ] && [ "$TARGET" != "mkv" ]; then
        echo "  WARN: attachments (${#picked_attach[@]}) suportate doar pe MKV — ignorate pe .$TARGET."
        picked_attach=()
    fi

    # ── Step 8: Per-track metadata edit (opt-in) ──
    local -a audio_lang=() audio_title=() audio_default=()
    local -a sub_lang=() sub_title=() sub_default=() sub_forced=()
    local first_audio_set=0
    for i in "${!picked_audio[@]}"; do
        audio_lang+=("$(mux_lang_from_filename "${picked_audio[$i]}")")
        audio_title+=("")
        if [[ " ${audio_drop_idx[*]} " == *" $i "* ]]; then
            audio_default+=("no")
        elif [ "$first_audio_set" -eq 0 ]; then
            audio_default+=("yes"); first_audio_set=1
        else
            audio_default+=("no")
        fi
    done
    for i in "${!picked_subs[@]}"; do
        sub_lang+=("$(mux_lang_from_filename "${picked_subs[$i]}")")
        sub_title+=("")
        sub_default+=("no")
        sub_forced+=("no")
    done

    echo ""
    local edit_md
    read -p "Editezi metadata per-track (lang/title/default/forced)? (d/N) [N]: " edit_md
    if [[ "${edit_md,,}" == "d" ]]; then
        local v
        for i in "${!picked_audio[@]}"; do
            if [[ " ${audio_drop_idx[*]} " == *" $i "* ]]; then continue; fi
            echo ""
            echo "  Audio #$((i+1)): $(basename "${picked_audio[$i]}") (${audio_codec[$i]})"
            read -p "    language [${audio_lang[$i]:-und}]: " v; [ -n "$v" ] && audio_lang[$i]="$v"
            read -p "    title [${audio_title[$i]}]: " v; [ -n "$v" ] && audio_title[$i]="$v"
            read -p "    default flag (d/n) [${audio_default[$i]}]: " v
            case "${v,,}" in d|yes|y) audio_default[$i]="yes" ;; n|no) audio_default[$i]="no" ;; esac
        done
        for i in "${!picked_subs[@]}"; do
            if [[ " ${sub_drop_idx[*]} " == *" $i "* ]]; then continue; fi
            echo ""
            echo "  Subtitle #$((i+1)): $(basename "${picked_subs[$i]}") (${sub_codec[$i]})"
            read -p "    language [${sub_lang[$i]:-und}]: " v; [ -n "$v" ] && sub_lang[$i]="$v"
            read -p "    title [${sub_title[$i]}]: " v; [ -n "$v" ] && sub_title[$i]="$v"
            read -p "    default flag (d/n) [${sub_default[$i]}]: " v
            case "${v,,}" in d|yes|y) sub_default[$i]="yes" ;; n|no) sub_default[$i]="no" ;; esac
            read -p "    forced flag (d/n) [${sub_forced[$i]}]: " v
            case "${v,,}" in d|yes|y) sub_forced[$i]="yes" ;; n|no) sub_forced[$i]="no" ;; esac
        done
    fi

    # ── Step 9: Build ffmpeg command ──
    local -a in_args=("-i" "$video")
    local input_idx=1
    local -a audio_input_idx=()
    for i in "${!picked_audio[@]}"; do
        if [[ " ${audio_drop_idx[*]} " == *" $i "* ]]; then
            audio_input_idx+=("-1"); continue
        fi
        in_args+=("-i" "${picked_audio[$i]}")
        audio_input_idx+=("$input_idx")
        input_idx=$((input_idx+1))
    done
    local -a sub_input_idx=()
    for i in "${!picked_subs[@]}"; do
        if [[ " ${sub_drop_idx[*]} " == *" $i "* ]]; then
            sub_input_idx+=("-1"); continue
        fi
        in_args+=("-i" "${picked_subs[$i]}")
        sub_input_idx+=("$input_idx")
        input_idx=$((input_idx+1))
    done
    local chapters_input_idx=-1
    local chapters_tmp_ffmeta=""
    if [ "${#picked_chapters[@]}" -gt 0 ]; then
        local ch_file="${picked_chapters[0]}"
        local ch_ext="${ch_file##*.}"; ch_ext="${ch_ext,,}"
        if [ "$ch_ext" = "xml" ]; then
            # Convert Matroska XML → FFMETADATA1 (ffmpeg nu citeste XML direct)
            chapters_tmp_ffmeta=$(av_mktemp_ext ffmetadata)
            # v59: capturam stderr separat ca sa propagam motivul cand parse-ul esueaza
            local _xml_err_file _xml_err=""
            _xml_err_file=$(av_mktemp_ext err)
            if mux_xml_to_ffmetadata "$ch_file" "$chapters_tmp_ffmeta" 2>"$_xml_err_file"; then
                in_args+=("-i" "$chapters_tmp_ffmeta")
                chapters_input_idx=$input_idx
                input_idx=$((input_idx+1))
                echo "  Chapters XML convertit la FFMETADATA1 (temp)."
            else
                [ -s "$_xml_err_file" ] && _xml_err=$(cat "$_xml_err_file" 2>/dev/null || true)
                echo "  WARN: nu pot converti $(basename "$ch_file") la FFMETADATA1 — chapters ignorate."
                [ -n "$_xml_err" ] && echo "    Motiv: ${_xml_err##*: }"
                rm -f "$chapters_tmp_ffmeta" 2>/dev/null
                chapters_tmp_ffmeta=""
            fi
            rm -f "$_xml_err_file" 2>/dev/null
        else
            in_args+=("-i" "$ch_file")
            chapters_input_idx=$input_idx
            input_idx=$((input_idx+1))
        fi
    fi

    local -a map_args=("-map" "0:v:0")
    local out_audio_idx=0
    for i in "${!picked_audio[@]}"; do
        [ "${audio_input_idx[$i]}" = "-1" ] && continue
        map_args+=("-map" "${audio_input_idx[$i]}:a")
        out_audio_idx=$((out_audio_idx+1))
    done
    local out_sub_idx=0
    for i in "${!picked_subs[@]}"; do
        [ "${sub_input_idx[$i]}" = "-1" ] && continue
        map_args+=("-map" "${sub_input_idx[$i]}:s")
        out_sub_idx=$((out_sub_idx+1))
    done

    # Chapters: pe MKV cu .xml ffmpeg accepta -map_chapters direct. Pe alte container
    # ffmpeg face conversie best-effort din xml/ffmetadata catre formatul container.
    local -a chapters_args=()
    if [ "$chapters_input_idx" -ge 0 ]; then
        chapters_args=("-map_chapters" "$chapters_input_idx")
    else
        chapters_args=("-map_chapters" "-1")
    fi

    local -a codec_args=("-c:v" "copy" "-c:a" "copy")
    case "$TARGET" in
        mp4|mov)
            if [ "$need_movtext" -eq 1 ]; then
                codec_args+=("-c:s" "mov_text")
            else
                codec_args+=("-c:s" "copy")
            fi
            ;;
        mkv|webm)
            codec_args+=("-c:s" "copy")
            ;;
    esac

    local -a extra_args=()
    case "$TARGET" in
        mp4|mov)
            case "$vc" in
                hevc) extra_args=("-tag:v" "hvc1") ;;
                av1)  extra_args=("-tag:v" "av01") ;;
                h264) extra_args=("-tag:v" "avc1") ;;
            esac
            extra_args+=("-movflags" "+faststart")
            ;;
    esac

    # Metadata args (emis dupa codec args, inainte de output)
    local -a meta_args=()
    out_audio_idx=0
    for i in "${!picked_audio[@]}"; do
        [ "${audio_input_idx[$i]}" = "-1" ] && continue
        local lang="${audio_lang[$i]}"
        [ -z "$lang" ] && lang="und"
        meta_args+=("-metadata:s:a:$out_audio_idx" "language=$lang")
        [ -n "${audio_title[$i]}" ] && meta_args+=("-metadata:s:a:$out_audio_idx" "title=${audio_title[$i]}")
        if [ "${audio_default[$i]}" = "yes" ]; then
            meta_args+=("-disposition:a:$out_audio_idx" "default")
        else
            meta_args+=("-disposition:a:$out_audio_idx" "0")
        fi
        out_audio_idx=$((out_audio_idx+1))
    done
    out_sub_idx=0
    for i in "${!picked_subs[@]}"; do
        [ "${sub_input_idx[$i]}" = "-1" ] && continue
        local lang="${sub_lang[$i]}"
        [ -z "$lang" ] && lang="und"
        meta_args+=("-metadata:s:s:$out_sub_idx" "language=$lang")
        [ -n "${sub_title[$i]}" ] && meta_args+=("-metadata:s:s:$out_sub_idx" "title=${sub_title[$i]}")
        local disp=""
        [ "${sub_default[$i]}" = "yes" ] && disp+="default+"
        [ "${sub_forced[$i]}" = "yes" ] && disp+="forced+"
        if [ -n "$disp" ]; then
            meta_args+=("-disposition:s:$out_sub_idx" "${disp%+}")
        else
            meta_args+=("-disposition:s:$out_sub_idx" "0")
        fi
        out_sub_idx=$((out_sub_idx+1))
    done

    # Attachments (doar MKV). Mimetype per-index — fara index, ffmpeg aplica
    # global la toate attachment streams si ultimul -metadata:s:t overrides
    # toate cele anterioare (toate primesc acelasi mime, ultimul setat).
    local -a attach_args=()
    if [ "$TARGET" = "mkv" ] && [ "${#picked_attach[@]}" -gt 0 ]; then
        local af af_ext mime
        local attach_idx=0
        for af in "${picked_attach[@]}"; do
            af_ext="${af##*.}"
            mime=$(mux_attach_mime "$af_ext")
            attach_args+=("-attach" "$af")
            attach_args+=("-metadata:s:t:$attach_idx" "mimetype=$mime")
            attach_idx=$((attach_idx+1))
        done
    fi

    echo ""
    echo "  → $final_out"
    echo "  Video:       $video_base ($vc)"
    echo "  Audio:       $out_audio_idx track(s)"
    echo "  Subtitle:    $out_sub_idx track(s)"
    echo "  Chapters:    $([ "$chapters_input_idx" -ge 0 ] && echo "1 file" || echo "none")"
    echo "  Attachments: ${#picked_attach[@]}"

    local start_ts; start_ts=$(date +%s)
    local mux_rc=0
    if ! ffmpeg -y -v warning -nostats \
            "${in_args[@]}" \
            "${map_args[@]}" "${chapters_args[@]}" \
            "${codec_args[@]}" "${extra_args[@]}" \
            "${meta_args[@]}" "${attach_args[@]}" \
            "$final_out"; then
        mux_rc=1
    fi
    # Cleanup temp FFMETADATA daca a fost generat + MP4-ul intermediar (v69)
    [ -n "$chapters_tmp_ffmeta" ] && rm -f "$chapters_tmp_ffmeta" 2>/dev/null
    [ -n "$_raw_wrap" ] && rm -f "$_raw_wrap" 2>/dev/null
    if [ "$mux_rc" -ne 0 ]; then
        echo "  EROARE: mux esuat."
        rm -f "$final_out"
        return 1
    fi
    if [ ! -s "$final_out" ]; then
        echo "  EROARE: output gol."
        rm -f "$final_out"
        return 1
    fi
    # v70/v71: video brut HEVC DV → scrie dvcC de container (DV pe TV, daca sursa avea
    # DV). Dispatch mkv→mkvmerge / mp4-mov→MP4Box via _dv_container_signal (partajat).
    if [[ -n "$_dv_raw_src" ]]; then
        _dv_container_signal "$_dv_raw_src" "$final_out" "$TARGET"
    fi
    local end_ts; end_ts=$(date +%s)
    local sz_new; sz_new=$(av_stat_size "$final_out" 2>/dev/null || echo 0)
    echo "  ✓ Mux OK in $((end_ts-start_ts))s | output: $((sz_new/1024/1024)) MB"
    av_notify_done "Mux complet" "Output: $(basename "$final_out")" 2>/dev/null || true
    return 0
}

# ═════════════════════════════════════════════════════════════════════
# Test mode: skip main menu (functions already loaded via sourcing)
# ═════════════════════════════════════════════════════════════════════
if [[ "${AV_MUX_TEST_MODE:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

# ═════════════════════════════════════════════════════════════════════
# MAIN SUBMENU
# ═════════════════════════════════════════════════════════════════════
echo ""
echo "╔══════════════════════════════════════╗"
echo "║  MUX TOOLS                           ║"
echo "╠══════════════════════════════════════╣"
echo "║  1) Remux  — repackage in container  ║"
echo "║     (mkv/mp4/mov/webm, stream sel)   ║"
echo "║  2) Demux  — extract streams separat ║"
echo "║     (.mkv/.mka/native + attach/cover)║"
echo "║  3) Mux    — combina streams separate║"
echo "║     (video + audio[N] + sub[N] +     ║"
echo "║      chapters + attachments)         ║"
echo "║  4) Anulare                          ║"
echo "╚══════════════════════════════════════╝"
read -p "Alege 1-4 [implicit: 1]: " mux_choice

case "${mux_choice:-1}" in
    1) remux_flow ;;
    2) demux_flow ;;
    3) mux_flow ;;
    4) echo "Anulat."; exit 0 ;;
    *) echo "Optiune invalida."; exit 1 ;;
esac

exit $?
