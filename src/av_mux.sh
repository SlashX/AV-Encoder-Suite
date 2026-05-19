#!/usr/bin/env bash
# av_mux.sh — Mux tools (v49)
# Submeniu cu doua flow-uri:
#   1) Remux  — selectie streams + repackage in container nou (mkv/mp4/mov/webm)
#   2) Demux  — extract streams ca fisiere separate (mkv/mka/native sub + attach)
# Input:  mkv, webm, mp4, m4v, mov, ts, m2ts, mts, vob, mxf
# Output remux: <name>_remux.<ext>
# Output demux: <name>_v<idx>_<codec>.mkv / <name>_a<idx>_<codec>_<lang>.mka /
#               <name>_s<idx>_<codec>_<lang>.<ext> / <name>_cover_<idx>.<ext> /
#               <name>_chapters.xml / <name>_attach/* / <name>_data/* (opt-in)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/av_common.sh"

mkdir -p "$OUTPUT_DIR"

if ! command -v ffmpeg &>/dev/null || ! command -v ffprobe &>/dev/null; then
    echo "EROARE: ffmpeg/ffprobe nu sunt instalate."
    echo "Instaleaza cu: $(av_pkg_install_hint ffmpeg)"
    exit 1
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
            # Exclude propriile output-uri remux/demux
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
    local raw
    raw=$(ffprobe -v error -select_streams v -show_entries stream=index,codec_name:stream_disposition=attached_pic \
        -of csv=p=0 "$file" 2>/dev/null || true)
    local idx codec disp
    while IFS=',' read -r idx codec disp; do
        [ -z "$idx" ] && continue
        disp="${disp%$'\r'}"
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
    if [ "$DEMUX_EXTRACT_ATTACH" -eq 1 ] && [ ${#REMUX_ATTACH_INDICES[@]} -gt 0 ]; then
        local attach_dir="${out_dir}/${name}_attach"
        mkdir -p "$attach_dir"
        local t_rel=0 abs
        for abs in "${REMUX_ATTACH_INDICES[@]}"; do
            info="${REMUX_STREAMS[$abs]}"
            IFS='|' read -r _ codec _ title _ <<< "$info"
            local attach_name="${title:-attachment_${t_rel}.bin}"
            attach_name=$(mux_sanitize "$attach_name")
            # ffmpeg -dump_attachment:t:N produce fisierul cu numele original
            if ( cd "$attach_dir" && ffmpeg -y -v error -dump_attachment:t:$t_rel "" -i "$file" </dev/null 2>/dev/null ); then
                : # numele original e folosit
            fi
            t_rel=$((t_rel+1))
        done
        local n_extracted; n_extracted=$(find "$attach_dir" -maxdepth 1 -type f 2>/dev/null | wc -l)
        if [ "$n_extracted" -gt 0 ]; then
            echo "  ✓ attachments → $(basename "$attach_dir")/ ($n_extracted fisiere)"
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
echo "║  3) Anulare                          ║"
echo "╚══════════════════════════════════════╝"
read -p "Alege 1-3 [implicit: 1]: " mux_choice

case "${mux_choice:-1}" in
    1) remux_flow ;;
    2) demux_flow ;;
    3) echo "Anulat."; exit 0 ;;
    *) echo "Optiune invalida."; exit 1 ;;
esac

exit $?
