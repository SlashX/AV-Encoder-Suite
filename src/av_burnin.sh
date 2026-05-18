#!/data/data/com.termux/files/usr/bin/bash
# av_burnin.sh — Burn-in overlay pentru telemetrie HUD si subtitrari (SRT/ASS)
# 3 flow-uri: 1) HUD telemetrie (Python+matplotlib) 2) SRT 3) ASS
# Output: OutputVideos/<name>_hud.<ext> sau <name>_subs.<ext>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/av_common.sh"

PRESETS_DIR="$SCRIPT_DIR/burnin_presets"
RENDER_PY="$SCRIPT_DIR/burnin_render.py"
ensure_temp_dir
mkdir -p "$OUTPUT_DIR"

# ── Dependente comune (ffmpeg) ───────────────────────────────────────
if ! command -v ffmpeg &>/dev/null; then
    echo "EROARE: ffmpeg nu este instalat."
    echo "Instaleaza cu: $(av_pkg_install_hint ffmpeg)"
    exit 1
fi

# ── Escape path pentru ffmpeg filter (subtitles=/ass=) ───────────────
escape_ffmpeg_filter_path() {
    local p="$1"
    p="${p//\\//}"        # backslash -> forward slash
    p="${p//:/\\:}"       # colon (Windows drive) -> \:
    p="${p//\'/\\\'}"     # apostrof -> \'
    echo "$p"
}

# ── Preview mode helpers (shared) ────────────────────────────────────
PREVIEW_MODE=0
PREVIEW_T_START=0
PREVIEW_DURATION=0

ask_preview() {
    echo ""
    read -p "Preview mode (5s clip la mid-point pentru verificare rapida) [y/N]: " preview_choice
    case "${preview_choice:-n}" in
        [yY]*) PREVIEW_MODE=1
               echo "  → Preview activ: 5s la 50% din durata. Output: <name>_preview.<ext>" ;;
        *)     PREVIEW_MODE=0 ;;
    esac
}

# Calculeaza fereastra de preview (5s la mid-point) pe baza duratei totale.
# Returneaza 0 (succes, valid) sau 1 (durata invalida — preview imposibil).
preview_compute_window() {
    local dur="$1"
    # Verifica daca dur e un numar valid > 0 (ffprobe poate returna "" sau "N/A")
    if ! awk -v d="$dur" 'BEGIN{exit !(d+0 > 0.05)}'; then
        PREVIEW_T_START=0
        PREVIEW_DURATION=0
        return 1
    fi
    PREVIEW_T_START=$(awk -v d="$dur" 'BEGIN{m=d/2-2.5; printf "%.3f", (m>0)?m:0}')
    PREVIEW_DURATION=$(awk -v d="$dur" 'BEGIN{printf "%.3f", (d<5)?d:5}')
    return 0
}

# ── Encoder dialog (shared) ──────────────────────────────────────────
ask_encoder() {
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  ENCODER PENTRU OUTPUT (video re-encode)      ║"
    echo "╠══════════════════════════════════════════════╣"
    echo "║  1) libx265 (HEVC) CRF 23 [implicit]          ║"
    echo "║  2) libx264 (H.264) CRF 20                    ║"
    echo "║  3) libsvtav1 (AV1) CRF 30                    ║"
    echo "║  4) Anulare                                   ║"
    echo "╚══════════════════════════════════════════════╝"
    read -p "Alege 1-4 [implicit: 1]: " enc_choice
    case "${enc_choice:-1}" in
        1) ENC_NAME="libx265"; ENC_CRF=23; ENC_PRESET="medium" ;;
        2) ENC_NAME="libx264"; ENC_CRF=20; ENC_PRESET="medium" ;;
        3) ENC_NAME="libsvtav1"; ENC_CRF=30; ENC_PRESET="6" ;;
        4) echo "Anulat."; exit 0 ;;
        *) ENC_NAME="libx265"; ENC_CRF=23; ENC_PRESET="medium" ;;
    esac
}

# ── Generic scan: <video> paired with <name>.<paired_ext> ────────────
declare -a PAIRS_VIDEO=()
declare -a PAIRS_AUX=()
declare -a PAIRS_LABEL=()
declare -a PAIRS_META=()  # brand pt HUD, lang/empty pt subs
declare -a PAIRS_KIND=()  # ext_pgs / ext_vob / emb_pgs / emb_vob (img_flow)
declare -a PAIRS_TRACK=() # subtitle stream index (img_flow embedded)

scan_for_pairs() {
    local search_dir="$1"
    local label_prefix="$2"
    local paired_ext="$3"        # ex: "_norm.csv" | ".srt" | ".ass"
    local meta_extract_fn="$4"   # nume functie de extras meta (brand etc.) sau ""
    [ ! -d "$search_dir" ] && return
    while IFS= read -r -d '' vid; do
        local base; base="$(basename "$vid")"
        local name="${base%.*}"
        [[ "$name" == *_hud     ]] && continue
        [[ "$name" == *_telem   ]] && continue
        [[ "$name" == *_subs    ]] && continue
        [[ "$name" == *_preview ]] && continue
        local aux="$OUTPUT_DIR/${name}${paired_ext}"
        [ -s "$aux" ] || continue
        local meta=""
        if [ -n "$meta_extract_fn" ]; then meta=$("$meta_extract_fn" "$aux"); fi
        PAIRS_VIDEO+=("$vid")
        PAIRS_AUX+=("$aux")
        PAIRS_LABEL+=("[$label_prefix] $base${meta:+ [$meta]}")
        PAIRS_META+=("$meta")
    done < <(find "$search_dir" -maxdepth 2 -type f \( -iname "*.mp4" -o -iname "*.mov" -o -iname "*.mkv" -o -iname "*.m4v" \) -print0 2>/dev/null)
}

# extract brand din coloana source_brand a norm CSV (rand 2, col 18)
extract_brand_from_csv() {
    local csv="$1"
    awk -F',' 'NR==2 {print $18}' "$csv" 2>/dev/null | tr -d '"' | tr -d '\r' | head -c 32
}

# Reset arrays + scan
reset_pairs() {
    PAIRS_VIDEO=(); PAIRS_AUX=(); PAIRS_LABEL=(); PAIRS_META=()
    PAIRS_KIND=(); PAIRS_TRACK=()
}

# Selectie generica index/lista/ALL
pick_files() {
    local total=${#PAIRS_VIDEO[@]}
    [ "$total" -eq 0 ] && { echo "Nimic de selectat."; exit 0; }
    for i in "${!PAIRS_LABEL[@]}"; do
        printf "  %2d) %s\n" "$((i+1))" "${PAIRS_LABEL[$i]}"
    done
    echo ""
    read -p "Selecteaza index (ex: 1 sau 1,3,5 sau ALL) [implicit ALL]: " sel
    sel="${sel:-ALL}"
    SELECTED=()
    if [[ "$sel" =~ ^[Aa][Ll][Ll]$ ]]; then
        for i in "${!PAIRS_VIDEO[@]}"; do SELECTED+=("$i"); done
    else
        IFS=',' read -ra parts <<< "$sel"
        for p in "${parts[@]}"; do
            p="${p// /}"
            [[ "$p" =~ ^[0-9]+$ ]] || { echo "Index invalid: $p"; exit 1; }
            idx=$((p-1))
            [ "$idx" -ge 0 ] && [ "$idx" -lt "$total" ] || { echo "Index in afara range: $p"; exit 1; }
            SELECTED+=("$idx")
        done
    fi
    [ "${#SELECTED[@]}" -eq 0 ] && { echo "Nimic selectat."; exit 0; }
}

# ──────────────────────────────────────────────────────────────────────
# FLOW 1: HUD telemetrie
# ──────────────────────────────────────────────────────────────────────
hud_flow() {
    # Deps Python+matplotlib (doar pt HUD)
    local have_python=0 have_matplotlib=0
    command -v python3 &>/dev/null && have_python=1
    if [ "$have_python" -eq 1 ]; then
        python3 -c "import matplotlib, numpy" 2>/dev/null && have_matplotlib=1
    fi
    if [ "$have_python" -eq 0 ]; then
        echo "EROARE: python3 nu este instalat (necesar pentru HUD render)."
        echo "Instaleaza cu: $(av_pkg_install_hint python3)"
        exit 1
    fi
    if [ "$have_matplotlib" -eq 0 ]; then
        echo "EROARE: matplotlib / numpy lipsesc."
        echo "Instaleaza cu: pip install matplotlib numpy pillow"
        echo "  Termux: pkg install python-numpy && pip install matplotlib pillow"
        exit 1
    fi
    [ -f "$RENDER_PY" ] || { echo "EROARE: $RENDER_PY lipseste."; exit 1; }

    reset_pairs
    scan_for_pairs "$OUTPUT_DIR" "OUT" "_norm.csv" extract_brand_from_csv
    scan_for_pairs "$INPUT_DIR"  "IN"  "_norm.csv" extract_brand_from_csv
    local total=${#PAIRS_VIDEO[@]}
    if [ "$total" -eq 0 ]; then
        echo ""
        echo "Nu am gasit nicio pereche video + norm CSV."
        echo "  Asigura-te ca exista <name>_norm.csv in $OUTPUT_DIR"
        echo "  (Genereaza cu av_telemetry sau av_extractor_gps)."
        exit 0
    fi

    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  HUD TELEMETRY OVERLAY                        ║"
    echo "║  Perechi gasite: $total"
    echo "║  Input  : $INPUT_DIR"
    echo "║  Output : $OUTPUT_DIR"
    echo "╚══════════════════════════════════════════════╝"
    echo ""
    pick_files

    # Layout preset
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  LAYOUT PRESET                                ║"
    echo "╠══════════════════════════════════════════════╣"
    echo "║  1) minimal     — timestamp + speed (corner)  ║"
    echo "║  2) data-strip  — bottom bar gauges          ║"
    echo "║  3) full        — data-strip + map + extras  ║"
    echo "║     [implicit]                                ║"
    echo "║  4) Anulare                                   ║"
    echo "╚══════════════════════════════════════════════╝"
    read -p "Alege 1-4 [implicit: 3]: " preset_choice
    case "${preset_choice:-3}" in
        1) PRESET="minimal" ;;
        2) PRESET="data-strip" ;;
        3) PRESET="full" ;;
        4) echo "Anulat."; exit 0 ;;
        *) PRESET="full" ;;
    esac
    local preset_file="$PRESETS_DIR/${PRESET}.conf"
    [ -s "$preset_file" ] || { echo "EROARE: preset $PRESET nu exista ($preset_file)"; exit 1; }

    # HUD fps
    echo ""
    read -p "HUD frame rate [implicit: 10 fps] (recomandat 10-30): " hud_fps
    HUD_FPS="${hud_fps:-10}"
    [[ "$HUD_FPS" =~ ^[0-9]+$ ]] || HUD_FPS=10
    [ "$HUD_FPS" -lt 1 ] && HUD_FPS=10
    [ "$HUD_FPS" -gt 60 ] && HUD_FPS=60

    ask_encoder
    ask_preview

    local ok=0 fail=0
    for idx in "${SELECTED[@]}"; do
        local vid="${PAIRS_VIDEO[$idx]}"
        local csv="${PAIRS_AUX[$idx]}"
        local brand="${PAIRS_META[$idx]}"
        local base; base="$(basename "$vid")"
        local name="${base%.*}"; local ext="${base##*.}"

        echo ""
        echo "─────────────────────────────────────────────"
        echo "  ── $((idx+1))/$total: $base  [$brand]"
        echo "─────────────────────────────────────────────"

        # Sync offset (auto interne, prompt external_*)
        local sync_offset=0
        case "$brand" in
            external_*)
                echo "  Brand sursa: $brand — telemetria poate fi nesincronizata cu video."
                read -p "  Sync offset in secunde (+/-, implicit 0): " sync_offset
                sync_offset="${sync_offset:-0}"
                [[ "$sync_offset" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || sync_offset=0
                ;;
        esac

        local vid_dur; vid_dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$vid" 2>/dev/null | head -1)
        local vid_w; vid_w=$(ffprobe -v error -select_streams v:0 -show_entries stream=width  -of csv=p=0 "$vid" 2>/dev/null | head -1)
        local vid_h; vid_h=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$vid" 2>/dev/null | head -1)
        [ -z "$vid_dur" ] && vid_dur=0
        [ -z "$vid_w" ]   && vid_w=1920
        [ -z "$vid_h" ]   && vid_h=1080

        local frames_dir="$AV_TEMP_DIR/burnin_${name}_$$"
        mkdir -p "$frames_dir"

        # Preview: render doar 5s la mid; ofset CSV decalat pentru a viza fereastra
        local render_dur="$vid_dur" render_offset="$sync_offset"
        local out_suffix="hud"
        local seek_args=()
        if [ "$PREVIEW_MODE" -eq 1 ]; then
            if preview_compute_window "$vid_dur"; then
                render_dur="$PREVIEW_DURATION"
                render_offset=$(awk -v s="$sync_offset" -v t="$PREVIEW_T_START" 'BEGIN{printf "%.3f", s+t}')
                out_suffix="preview"
                seek_args=(-ss "$PREVIEW_T_START" -t "$PREVIEW_DURATION")
                echo "  Preview window: ${PREVIEW_T_START}s + ${PREVIEW_DURATION}s (din ${vid_dur}s)"
            else
                echo "  [WARN] Durata invalida ($vid_dur) — preview skipped, fall back la full encode."
            fi
        fi

        echo "  Render PNG sequence (preset=$PRESET, hud_fps=$HUD_FPS, dur=${render_dur}s)..."
        if ! python3 "$RENDER_PY" \
            --csv "$csv" --preset "$preset_file" --output-dir "$frames_dir" \
            --fps "$HUD_FPS" --duration "$render_dur" --width "$vid_w" --height "$vid_h" \
            --offset "$render_offset" --brand "$brand"; then
            echo "  [EROARE] Render PNG sequence esuat"
            rm -rf "$frames_dir"; fail=$((fail+1)); continue
        fi

        local out="$OUTPUT_DIR/${name}_${out_suffix}.${ext}"
        echo "  Overlay + re-encode ($ENC_NAME CRF $ENC_CRF preset $ENC_PRESET)..."
        if ffmpeg -v error -stats \
            "${seek_args[@]}" -i "$vid" \
            -framerate "$HUD_FPS" \
            -i "$frames_dir/frame_%06d.png" \
            -filter_complex "[0:v][1:v]overlay=0:0:shortest=0[v]" \
            -map "[v]" -map "0:a?" \
            -c:v "$ENC_NAME" -crf "$ENC_CRF" -preset "$ENC_PRESET" \
            -c:a copy -movflags +faststart "$out" -y </dev/null; then
            echo "  [OK] $out"; ok=$((ok+1))
        else
            echo "  [EROARE] ffmpeg overlay esuat"; rm -f "$out"; fail=$((fail+1))
        fi
        rm -rf "$frames_dir"
    done

    echo ""
    echo "═══════════════════════════════════════════════"
    echo "  Sumar HUD burn-in: $ok OK, $fail esuate (din ${#SELECTED[@]} selectate)"
    echo "═══════════════════════════════════════════════"
}

# ──────────────────────────────────────────────────────────────────────
# FLOW 2: SRT burn-in
# ──────────────────────────────────────────────────────────────────────
srt_flow() {
    reset_pairs
    scan_for_pairs "$OUTPUT_DIR" "OUT" ".srt" ""
    scan_for_pairs "$INPUT_DIR"  "IN"  ".srt" ""
    local total=${#PAIRS_VIDEO[@]}
    if [ "$total" -eq 0 ]; then
        echo ""
        echo "Nu am gasit nicio pereche video + .srt."
        echo "  Asigura-te ca exista <name>.srt langa video sau in $OUTPUT_DIR"
        exit 0
    fi

    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  SRT BURN-IN (subtitrari hardcoded)           ║"
    echo "║  Perechi gasite: $total"
    echo "║  Input  : $INPUT_DIR"
    echo "║  Output : $OUTPUT_DIR"
    echo "╚══════════════════════════════════════════════╝"
    echo ""
    pick_files

    # Stil SRT
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  STIL SRT                                     ║"
    echo "╠══════════════════════════════════════════════╣"
    echo "║  1) Small  (font 18, white + black outline)   ║"
    echo "║     [implicit]                                ║"
    echo "║  2) Medium (font 24)                          ║"
    echo "║  3) Large  (font 32)                          ║"
    echo "║  4) Default ffmpeg (no override)              ║"
    echo "║  5) Anulare                                   ║"
    echo "╚══════════════════════════════════════════════╝"
    read -p "Alege 1-5 [implicit: 1]: " style_choice
    local force_style=""
    case "${style_choice:-1}" in
        1) force_style="FontSize=18,PrimaryColour=&H00FFFFFF,OutlineColour=&H00000000,Outline=2,Shadow=1" ;;
        2) force_style="FontSize=24,PrimaryColour=&H00FFFFFF,OutlineColour=&H00000000,Outline=2,Shadow=1" ;;
        3) force_style="FontSize=32,PrimaryColour=&H00FFFFFF,OutlineColour=&H00000000,Outline=3,Shadow=1" ;;
        4) force_style="" ;;
        5) echo "Anulat."; exit 0 ;;
        *) force_style="FontSize=18,PrimaryColour=&H00FFFFFF,OutlineColour=&H00000000,Outline=2,Shadow=1" ;;
    esac

    ask_encoder
    ask_preview

    local ok=0 fail=0
    for idx in "${SELECTED[@]}"; do
        local vid="${PAIRS_VIDEO[$idx]}"
        local srt="${PAIRS_AUX[$idx]}"
        local base; base="$(basename "$vid")"
        local name="${base%.*}"; local ext="${base##*.}"

        echo ""
        echo "─────────────────────────────────────────────"
        echo "  ── $((idx+1))/$total: $base"
        echo "─────────────────────────────────────────────"

        local srt_esc; srt_esc=$(escape_ffmpeg_filter_path "$srt")
        local vf="subtitles='${srt_esc}'"
        [ -n "$force_style" ] && vf="${vf}:force_style='${force_style}'"

        local out_suffix="subs"
        local seek_args=()
        if [ "$PREVIEW_MODE" -eq 1 ]; then
            local vid_dur; vid_dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$vid" 2>/dev/null | head -1)
            [ -z "$vid_dur" ] && vid_dur=0
            if preview_compute_window "$vid_dur"; then
                out_suffix="preview"
                seek_args=(-ss "$PREVIEW_T_START" -copyts -t "$PREVIEW_DURATION")
                echo "  Preview window: ${PREVIEW_T_START}s + ${PREVIEW_DURATION}s (din ${vid_dur}s)"
            else
                echo "  [WARN] Durata invalida ($vid_dur) — preview skipped, fall back la full encode."
            fi
        fi

        local out="$OUTPUT_DIR/${name}_${out_suffix}.${ext}"
        echo "  Burn-in SRT + re-encode ($ENC_NAME CRF $ENC_CRF preset $ENC_PRESET)..."
        if ffmpeg -v error -stats \
            "${seek_args[@]}" -i "$vid" \
            -vf "$vf" \
            -c:v "$ENC_NAME" -crf "$ENC_CRF" -preset "$ENC_PRESET" \
            -c:a copy -movflags +faststart "$out" -y </dev/null; then
            echo "  [OK] $out"; ok=$((ok+1))
        else
            echo "  [EROARE] ffmpeg SRT burn-in esuat"; rm -f "$out"; fail=$((fail+1))
        fi
    done

    echo ""
    echo "═══════════════════════════════════════════════"
    echo "  Sumar SRT burn-in: $ok OK, $fail esuate (din ${#SELECTED[@]} selectate)"
    echo "═══════════════════════════════════════════════"
}

# ──────────────────────────────────────────────────────────────────────
# FLOW 3: ASS burn-in
# ──────────────────────────────────────────────────────────────────────
ass_flow() {
    reset_pairs
    scan_for_pairs "$OUTPUT_DIR" "OUT" ".ass" ""
    scan_for_pairs "$INPUT_DIR"  "IN"  ".ass" ""
    local total=${#PAIRS_VIDEO[@]}
    if [ "$total" -eq 0 ]; then
        echo ""
        echo "Nu am gasit nicio pereche video + .ass."
        echo "  Asigura-te ca exista <name>.ass langa video sau in $OUTPUT_DIR"
        exit 0
    fi

    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  ASS BURN-IN (styled subtitles, anime)        ║"
    echo "║  Perechi gasite: $total"
    echo "║  Input  : $INPUT_DIR"
    echo "║  Output : $OUTPUT_DIR"
    echo "╚══════════════════════════════════════════════╝"
    echo ""
    pick_files

    # Font scale (ASS-uri au styling embedded; scale e doar adjustment)
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  ASS FONT SCALE                               ║"
    echo "╠══════════════════════════════════════════════╣"
    echo "║  1) 1.0x (embedded styling, fara override)    ║"
    echo "║     [implicit]                                ║"
    echo "║  2) 1.25x (TV mediu)                          ║"
    echo "║  3) 1.5x (TV mare)                            ║"
    echo "║  4) Anulare                                   ║"
    echo "╚══════════════════════════════════════════════╝"
    read -p "Alege 1-4 [implicit: 1]: " scale_choice
    local ass_filter="ass"
    local extra_style=""
    case "${scale_choice:-1}" in
        1) extra_style="" ;;
        2) extra_style=":force_style='ScaleX=125,ScaleY=125'" ;;
        3) extra_style=":force_style='ScaleX=150,ScaleY=150'" ;;
        4) echo "Anulat."; exit 0 ;;
        *) extra_style="" ;;
    esac

    ask_encoder
    ask_preview

    local ok=0 fail=0
    for idx in "${SELECTED[@]}"; do
        local vid="${PAIRS_VIDEO[$idx]}"
        local ass="${PAIRS_AUX[$idx]}"
        local base; base="$(basename "$vid")"
        local name="${base%.*}"; local ext="${base##*.}"

        echo ""
        echo "─────────────────────────────────────────────"
        echo "  ── $((idx+1))/$total: $base"
        echo "─────────────────────────────────────────────"

        local ass_esc; ass_esc=$(escape_ffmpeg_filter_path "$ass")
        local vf="${ass_filter}='${ass_esc}'${extra_style}"

        local out_suffix="subs"
        local seek_args=()
        if [ "$PREVIEW_MODE" -eq 1 ]; then
            local vid_dur; vid_dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$vid" 2>/dev/null | head -1)
            [ -z "$vid_dur" ] && vid_dur=0
            if preview_compute_window "$vid_dur"; then
                out_suffix="preview"
                seek_args=(-ss "$PREVIEW_T_START" -copyts -t "$PREVIEW_DURATION")
                echo "  Preview window: ${PREVIEW_T_START}s + ${PREVIEW_DURATION}s (din ${vid_dur}s)"
            else
                echo "  [WARN] Durata invalida ($vid_dur) — preview skipped, fall back la full encode."
            fi
        fi

        local out="$OUTPUT_DIR/${name}_${out_suffix}.${ext}"
        echo "  Burn-in ASS + re-encode ($ENC_NAME CRF $ENC_CRF preset $ENC_PRESET)..."
        if ffmpeg -v error -stats \
            "${seek_args[@]}" -i "$vid" \
            -vf "$vf" \
            -c:v "$ENC_NAME" -crf "$ENC_CRF" -preset "$ENC_PRESET" \
            -c:a copy -movflags +faststart "$out" -y </dev/null; then
            echo "  [OK] $out"; ok=$((ok+1))
        else
            echo "  [EROARE] ffmpeg ASS burn-in esuat"; rm -f "$out"; fail=$((fail+1))
        fi
    done

    echo ""
    echo "═══════════════════════════════════════════════"
    echo "  Sumar ASS burn-in: $ok OK, $fail esuate (din ${#SELECTED[@]} selectate)"
    echo "═══════════════════════════════════════════════"
}

# ──────────────────────────────────────────────────────────────────────
# FLOW 4: Image subs burn-in (Bluray PGS / DVD VobSub, ext + embedded)
# ──────────────────────────────────────────────────────────────────────
img_scan_dir() {
    local dir="$1" label="$2"
    [ ! -d "$dir" ] && return
    local have_ffprobe=0
    command -v ffprobe &>/dev/null && have_ffprobe=1
    while IFS= read -r -d '' vid; do
        local base; base="$(basename "$vid")"
        local name="${base%.*}"
        [[ "$name" == *_hud     ]] && continue
        [[ "$name" == *_telem   ]] && continue
        [[ "$name" == *_subs    ]] && continue
        [[ "$name" == *_preview ]] && continue
        local dir_of; dir_of="$(dirname "$vid")"

        # External PGS (.sup) — cauta langa video, apoi in OUTPUT_DIR
        local sup="$dir_of/${name}.sup"
        [ -s "$sup" ] || sup="$OUTPUT_DIR/${name}.sup"
        if [ -s "$sup" ]; then
            PAIRS_VIDEO+=("$vid"); PAIRS_AUX+=("$sup")
            PAIRS_LABEL+=("[$label] $base [PGS .sup]")
            PAIRS_META+=("ext_pgs"); PAIRS_KIND+=("ext_pgs"); PAIRS_TRACK+=("")
        fi

        # External VobSub (.idx + .sub)
        local idxf="$dir_of/${name}.idx"
        local subf="$dir_of/${name}.sub"
        if [ ! -s "$idxf" ] || [ ! -s "$subf" ]; then
            idxf="$OUTPUT_DIR/${name}.idx"
            subf="$OUTPUT_DIR/${name}.sub"
        fi
        if [ -s "$idxf" ] && [ -s "$subf" ]; then
            PAIRS_VIDEO+=("$vid"); PAIRS_AUX+=("$idxf")
            PAIRS_LABEL+=("[$label] $base [VobSub .idx/.sub]")
            PAIRS_META+=("ext_vob"); PAIRS_KIND+=("ext_vob"); PAIRS_TRACK+=("")
        fi

        # Embedded subtitle tracks (PGS / VobSub) — ffprobe enumerate
        # || true previne abort set -e cand ffprobe esueaza pe fisier corupt
        if [ "$have_ffprobe" -eq 1 ]; then
            local streams; streams=$(ffprobe -v error -select_streams s \
                -show_entries stream=index,codec_name:stream_tags=language \
                -of csv=p=0 "$vid" 2>/dev/null || true)
            local stream_idx=0
            local global_idx codec lang
            while IFS=, read -r global_idx codec lang; do
                [ -z "$codec" ] && continue
                lang="${lang//$'\r'/}"
                case "$codec" in
                    hdmv_pgs_subtitle)
                        PAIRS_VIDEO+=("$vid"); PAIRS_AUX+=("$vid")
                        PAIRS_LABEL+=("[$label] $base [PGS embedded s:${stream_idx}${lang:+ $lang}]")
                        PAIRS_META+=("emb_pgs"); PAIRS_KIND+=("emb_pgs"); PAIRS_TRACK+=("$stream_idx")
                        ;;
                    dvd_subtitle)
                        PAIRS_VIDEO+=("$vid"); PAIRS_AUX+=("$vid")
                        PAIRS_LABEL+=("[$label] $base [VobSub embedded s:${stream_idx}${lang:+ $lang}]")
                        PAIRS_META+=("emb_vob"); PAIRS_KIND+=("emb_vob"); PAIRS_TRACK+=("$stream_idx")
                        ;;
                esac
                stream_idx=$((stream_idx+1))
            done <<< "$streams"
        fi
    done < <(find "$dir" -maxdepth 2 -type f \( -iname "*.mp4" -o -iname "*.mov" -o -iname "*.mkv" -o -iname "*.m4v" \) -print0 2>/dev/null)
}

img_flow() {
    reset_pairs
    img_scan_dir "$OUTPUT_DIR" "OUT"
    img_scan_dir "$INPUT_DIR"  "IN"
    local total=${#PAIRS_VIDEO[@]}
    if [ "$total" -eq 0 ]; then
        echo ""
        echo "Nu am gasit nicio sursa de subtitrari imagine."
        echo "  Cautat: <name>.sup (PGS) / <name>.idx+.sub (VobSub) langa video sau in $OUTPUT_DIR"
        echo "  Cautat: track-uri embedded PGS/VobSub in MKV/MP4 (via ffprobe)"
        exit 0
    fi

    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  IMAGE SUBS BURN-IN (Bluray PGS / DVD VobSub) ║"
    echo "║  Surse gasite: $total"
    echo "║  Input  : $INPUT_DIR"
    echo "║  Output : $OUTPUT_DIR"
    echo "╚══════════════════════════════════════════════╝"
    echo ""
    pick_files

    # Notice — image subs nu suporta styling (bitmap, pre-rendered)
    echo ""
    echo "Notă: image subs (PGS/VobSub) sunt bitmap pre-rendered —"
    echo "      fără opțiuni de styling (font/size). Track selection only."

    ask_encoder
    ask_preview

    local ok=0 fail=0
    for idx in "${SELECTED[@]}"; do
        local vid="${PAIRS_VIDEO[$idx]}"
        local aux="${PAIRS_AUX[$idx]}"
        local kind="${PAIRS_KIND[$idx]}"
        local track="${PAIRS_TRACK[$idx]}"
        local base; base="$(basename "$vid")"
        local name="${base%.*}"; local ext="${base##*.}"

        echo ""
        echo "─────────────────────────────────────────────"
        echo "  ── $((idx+1))/$total: $base  [$kind${track:+ s:$track}]"
        echo "─────────────────────────────────────────────"

        local out_suffix="subs"
        local seek_args=()
        if [ "$PREVIEW_MODE" -eq 1 ]; then
            local vid_dur; vid_dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$vid" 2>/dev/null | head -1)
            [ -z "$vid_dur" ] && vid_dur=0
            if preview_compute_window "$vid_dur"; then
                out_suffix="preview"
                seek_args=(-ss "$PREVIEW_T_START" -copyts -t "$PREVIEW_DURATION")
                echo "  Preview window: ${PREVIEW_T_START}s + ${PREVIEW_DURATION}s (din ${vid_dur}s)"
            else
                echo "  [WARN] Durata invalida ($vid_dur) — preview skipped, fall back la full encode."
            fi
        fi

        local out="$OUTPUT_DIR/${name}_${out_suffix}.${ext}"
        # ok_now=0 fallback la fail; ramurile if/else previn abort set -e pe ffmpeg failure
        local ok_now=0
        case "$kind" in
            ext_pgs|ext_vob)
                echo "  Burn-in $kind (sursa: $aux) + re-encode ($ENC_NAME CRF $ENC_CRF preset $ENC_PRESET)..."
                if ffmpeg -v error -stats \
                    "${seek_args[@]}" -i "$vid" \
                    -i "$aux" \
                    -filter_complex "[0:v][1:s]overlay[v]" \
                    -map "[v]" -map "0:a?" \
                    -c:v "$ENC_NAME" -crf "$ENC_CRF" -preset "$ENC_PRESET" \
                    -c:a copy -movflags +faststart "$out" -y </dev/null; then
                    ok_now=1
                fi
                ;;
            emb_pgs|emb_vob)
                echo "  Burn-in $kind (track s:$track embedded) + re-encode ($ENC_NAME CRF $ENC_CRF preset $ENC_PRESET)..."
                if ffmpeg -v error -stats \
                    "${seek_args[@]}" -i "$vid" \
                    -filter_complex "[0:v][0:s:${track}]overlay[v]" \
                    -map "[v]" -map "0:a?" \
                    -c:v "$ENC_NAME" -crf "$ENC_CRF" -preset "$ENC_PRESET" \
                    -c:a copy -movflags +faststart "$out" -y </dev/null; then
                    ok_now=1
                fi
                ;;
            *)
                echo "  [EROARE] kind necunoscut: $kind"
                ;;
        esac
        if [ "$ok_now" -eq 1 ]; then
            echo "  [OK] $out"; ok=$((ok+1))
        else
            echo "  [EROARE] ffmpeg image subs burn-in esuat"; rm -f "$out"; fail=$((fail+1))
        fi
    done

    echo ""
    echo "═══════════════════════════════════════════════"
    echo "  Sumar Image subs burn-in: $ok OK, $fail esuate (din ${#SELECTED[@]} selectate)"
    echo "═══════════════════════════════════════════════"
}

# ──────────────────────────────────────────────────────────────────────
# Main menu — alege tip burn-in
# ──────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  BURN-IN — selecteaza tipul                   ║"
echo "╠══════════════════════════════════════════════╣"
echo "║  1) Telemetry HUD (gauges + map)              ║"
echo "║     Sursa: norm CSV                           ║"
echo "║  2) Subtitrari SRT (telemetry overlay/movies) ║"
echo "║  3) Subtitrari ASS (anime, styled subs)       ║"
echo "║  4) Image subs PGS/VobSub (Bluray/DVD)        ║"
echo "║  5) Anulare                                   ║"
echo "╚══════════════════════════════════════════════╝"
read -p "Alege 1-5 [implicit: 1]: " burnin_type
case "${burnin_type:-1}" in
    1) hud_flow ;;
    2) srt_flow ;;
    3) ass_flow ;;
    4) img_flow ;;
    5) echo "Anulat."; exit 0 ;;
    *) echo "Optiune invalida."; exit 1 ;;
esac
