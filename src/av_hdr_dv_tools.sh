#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# av_hdr_dv_tools.sh — HDR/DV Tools (v44)
#
# Submeniu pentru operatii metadata-only / container-only, FARA re-encode:
#   1) Transform RPU profile  — convert intre Profile 7/8.1/10 (cross-codec)
#   2) Remux container         — MKV ↔ MP4/MOV cu tag:v fix + +faststart
#   3) Inspect metadata        — dump RPU info + HDR10+ scenes (read-only)
#   4) Inapoi
#
# Toate functiile de baza traiesc in av_common.sh; acest script e DOAR UI
# (sub-menu + dispatch).
# ══════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/av_common.sh"

# ─────────────────────────────────────────────────────────────────────
# UI helper — pick file from INPUT_DIR + numbered list
# ─────────────────────────────────────────────────────────────────────
_hdv_pick_file() {
    local prompt="${1:-Alege fisier}" dir="${2:-$INPUT_DIR}"
    if [ ! -d "$dir" ]; then
        echo "Folderul nu exista: $dir" >&2
        return 1
    fi
    shopt -s nullglob nocaseglob
    local files=("$dir"/*.{mp4,mov,mkv,m2ts,mts,hevc,h265,265,ivf})
    shopt -u nullglob nocaseglob
    if [ ${#files[@]} -eq 0 ]; then
        echo "Niciun fisier in $dir" >&2
        return 1
    fi
    echo ""
    echo "$prompt:"
    local i=1
    for f in "${files[@]}"; do
        printf "  %2d) %s\n" "$i" "$(basename "$f")"
        i=$((i+1))
    done
    read -p "Alege [1-$((i-1))]: " idx
    [[ ! "$idx" =~ ^[0-9]+$ ]] && return 1
    [ "$idx" -lt 1 ] || [ "$idx" -gt $((i-1)) ] && return 1
    HDV_PICKED_FILE="${files[$((idx-1))]}"
    return 0
}

# ─────────────────────────────────────────────────────────────────────
# Flow 1: Transform RPU profile
# ─────────────────────────────────────────────────────────────────────
hdv_flow_transform_rpu() {
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  TRANSFORM RPU PROFILE                       ║"
    echo "║  Converteste RPU intre Profile 7/8.1/10      ║"
    echo "║  Fara re-encode video.                       ║"
    echo "╚══════════════════════════════════════════════╝"
    _hdv_pick_file "Alege fisier sursa (cu DV)" "$INPUT_DIR" || { echo "Anulat."; return 1; }
    local file="$HDV_PICKED_FILE"
    local src_codec
    src_codec=$(detect_source_codec "$file")
    echo "  Codec sursa: $src_codec"

    echo ""
    echo "  Mode dovi_tool convert (filtrate dupa codec sursa: $src_codec):"
    local _default_choice=1
    if [[ "$src_codec" == "hevc" ]]; then
        echo "    1) Force 8.1 (HEVC, single-layer + HDR10 base)  [-m 2]"
        echo "    2) DV 5 -> 8.1                                  [-m 3]"
        echo "    3) DV 7 -> 8.1 (drop EL, MEL only)              [-m 4]"
    elif [[ "$src_codec" == "av1" ]]; then
        echo "    4) AV1: profile 10 (sven-pke fork)              [-m 2 + tool av1]"
        _default_choice=4
    else
        echo "  EROARE: Codec sursa '$src_codec' nu suporta DV transform."
        echo "         Doar HEVC (DV 5/7/8.1) si AV1 (DV 10) sunt suportate."
        return 1
    fi
    read -p "  Alege [implicit: $_default_choice]: " mode_choice
    local mode=2 target_codec="hevc"
    case "${mode_choice:-$_default_choice}" in
        1) [[ "$src_codec" != "hevc" ]] && { echo "Mod 1 doar pentru HEVC."; return 1; }
           mode=2; target_codec="hevc" ;;
        2) [[ "$src_codec" != "hevc" ]] && { echo "Mod 2 doar pentru HEVC."; return 1; }
           mode=3; target_codec="hevc" ;;
        3) [[ "$src_codec" != "hevc" ]] && { echo "Mod 3 doar pentru HEVC."; return 1; }
           mode=4; target_codec="hevc" ;;
        4) [[ "$src_codec" != "av1" ]] && { echo "Mod 4 doar pentru AV1."; return 1; }
           mode=2; target_codec="av1" ;;
        *) echo "Optiune invalida."; return 1 ;;
    esac

    if ! _check_dovi_tool_for "$target_codec"; then
        local _t="dovi_tool"; [[ "$target_codec" == "av1" ]] && _t="av1dovi_tool"
        echo "  EROARE: $_t nu este instalat. Vezi src/tools/."
        return 1
    fi

    # Pas 1: extract RPU sursa (codec-aware)
    local rpu_src
    rpu_src=$(av_mktemp_ext bin)
    echo ""
    echo "  [1/3] Extract RPU sursa..."
    if ! extract_dv_rpu "$file" "$rpu_src" "$src_codec"; then
        echo "  EROARE: Extract RPU esuat."
        rm -f "$rpu_src"; return 1
    fi
    echo "  RPU sursa: $(av_du_mb "$rpu_src" 2>/dev/null) MB"

    # Pas 2: convert RPU
    local rpu_out
    rpu_out=$(av_mktemp_ext bin)
    echo ""
    echo "  [2/3] Convert RPU (mode=$mode, target=$target_codec)..."
    if ! convert_rpu_profile "$rpu_src" "$rpu_out" "$mode" "$target_codec"; then
        echo "  EROARE: Convert RPU esuat."
        rm -f "$rpu_src" "$rpu_out"; return 1
    fi

    # Pas 3: extract video raw, inject RPU convertit, re-mux
    local raw_video injected_video final_out
    local raw_ext="hevc"
    [[ "$target_codec" == "av1" ]] && raw_ext="ivf"
    raw_video=$(av_mktemp_ext "$raw_ext")
    injected_video=$(av_mktemp_ext "$raw_ext")
    local out_ext="${file##*.}"
    final_out="${OUTPUT_DIR}/$(basename "${file%.*}")_rpu${mode}.${out_ext}"
    mkdir -p "$OUTPUT_DIR"

    echo ""
    echo "  [3/3] Inject RPU + re-mux..."
    if ! extract_raw_video "$file" "$raw_video" "$src_codec"; then
        echo "  EROARE: Extract raw video esuat."
        rm -f "$rpu_src" "$rpu_out" "$raw_video"; return 1
    fi
    if ! inject_dv_rpu "$raw_video" "$rpu_out" "$injected_video" "$target_codec"; then
        echo "  EROARE: Inject RPU esuat."
        rm -f "$rpu_src" "$rpu_out" "$raw_video" "$injected_video"; return 1
    fi
    # Re-mux: video cu RPU convertit + audio/sub/track-uri din original
    # get_container_flags citeste $CONTAINER global → setam local cu out_ext
    local CONTAINER="$out_ext"
    local cont_flags
    cont_flags=$(get_container_flags)
    # shellcheck disable=SC2086
    ffmpeg -v error -i "$injected_video" -i "$file" \
        -map 0:v:0 -map 1:a -map 1:s? -map 1:t? \
        -c copy $cont_flags "$final_out" 2>/dev/null
    local rc=$?
    rm -f "$rpu_src" "$rpu_out" "$raw_video" "$injected_video"
    if [ $rc -eq 0 ] && [ -s "$final_out" ]; then
        echo ""
        echo "  ✓ Transform RPU complet: $final_out"
        return 0
    else
        echo "  EROARE: Re-mux final esuat."
        rm -f "$final_out"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────
# Flow 2: Remux container
# ─────────────────────────────────────────────────────────────────────
hdv_flow_remux() {
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  REMUX CONTAINER                             ║"
    echo "║  MKV ↔ MP4/MOV cu tag:v fix, FARA re-encode. ║"
    echo "╚══════════════════════════════════════════════╝"
    _hdv_pick_file "Alege fisier" "$INPUT_DIR" || { echo "Anulat."; return 1; }
    local file="$HDV_PICKED_FILE"
    local src_ext="${file##*.}"; src_ext="${src_ext,,}"
    echo "  Source ext: $src_ext"

    echo ""
    echo "  Container tinta:"
    echo "    1) mp4   (recomandat pentru distribute / web)"
    echo "    2) mov   (Apple ecosystem)"
    echo "    3) mkv   (full feature, permisiv)"
    read -p "  Alege [implicit: 1]: " tgt_choice
    local target=mp4
    case "${tgt_choice:-1}" in
        1) target="mp4" ;;
        2) target="mov" ;;
        3) target="mkv" ;;
        *) echo "Optiune invalida."; return 1 ;;
    esac

    # Pre-flight
    _remux_preflight "$file" "$target"
    local lvl=$REMUX_PREFLIGHT_LEVEL
    if [ ${#REMUX_PREFLIGHT_NOTES[@]} -gt 0 ]; then
        echo ""
        echo "  Pre-flight check (level=$lvl):"
        local n
        for n in "${REMUX_PREFLIGHT_NOTES[@]}"; do
            echo "    - $n"
        done
    fi
    if [ "$lvl" -ge 2 ]; then
        echo "  EROARE: Pre-flight FAIL — abort."
        return 1
    fi
    if [ "$lvl" -ge 1 ]; then
        read -p "  Continui? (D/n) [default: D]: " cont
        if [[ "${cont,,}" == "n" ]]; then echo "  Anulat."; return 1; fi
    fi

    local final_out="${OUTPUT_DIR}/$(basename "${file%.*}").${target}"
    mkdir -p "$OUTPUT_DIR"
    echo ""
    echo "  Re-mux: $file -> $final_out"
    if remux_container_with_tag "$file" "$final_out" "$target"; then
        echo "  ✓ Remux complet."
        # Post-flight: verificare rapida
        local sz_orig sz_new
        sz_orig=$(av_stat_size "$file" 2>/dev/null || echo 0)
        sz_new=$(av_stat_size "$final_out" 2>/dev/null || echo 0)
        echo "  Original: $((sz_orig/1024/1024)) MB | Nou: $((sz_new/1024/1024)) MB"
        return 0
    else
        echo "  EROARE: Re-mux esuat."
        rm -f "$final_out"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────
# Flow 3: Inspect metadata (read-only)
# ─────────────────────────────────────────────────────────────────────
hdv_flow_inspect() {
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  INSPECT METADATA                            ║"
    echo "║  Dump RPU + HDR10+ info, read-only.          ║"
    echo "╚══════════════════════════════════════════════╝"
    _hdv_pick_file "Alege fisier" "$INPUT_DIR" || { echo "Anulat."; return 1; }
    local file="$HDV_PICKED_FILE"
    local src_codec
    src_codec=$(detect_source_codec "$file")
    echo ""
    echo "  Codec sursa: $src_codec"
    echo "  Container:   ${file##*.}"

    # ffprobe summary
    echo ""
    echo "── ffprobe summary ──"
    ffprobe -v error -show_entries stream=index,codec_name,codec_type,width,height,pix_fmt,color_transfer,color_primaries,color_space,r_frame_rate \
        -of compact=p=1:nk=0 "$file" 2>&1 | head -20

    # DV inspect
    if _check_dovi_tool_for "$src_codec"; then
        local dovi_bin
        dovi_bin=$(tool_for_extract "$src_codec" dovi)
        local rpu_tmp
        rpu_tmp=$(av_mktemp_ext bin)
        if extract_dv_rpu "$file" "$rpu_tmp" "$src_codec"; then
            echo ""
            echo "── DV RPU info ($dovi_bin) ──"
            "$dovi_bin" info -i "$rpu_tmp" 2>/dev/null | head -30 || echo "  (info command esuata)"
        else
            echo ""
            echo "── DV: nu am putut extrage RPU (probabil sursa nu este DV) ──"
        fi
        rm -f "$rpu_tmp"
    else
        echo ""
        echo "── DV: tool negasit pentru codec=$src_codec ──"
    fi

    # HDR10+ inspect
    if _check_hdr10plus_tool_for "$src_codec"; then
        local hp_bin
        hp_bin=$(tool_for_extract "$src_codec" hdr10plus)
        local hp_json
        hp_json=$(extract_hdr10plus_metadata "$file" 2>/dev/null)
        if [[ -n "$hp_json" ]] && [ -s "$hp_json" ]; then
            local scenes
            scenes=$(grep -c '"BezierCurveData"\|"TargetedSystemDisplay"' "$hp_json" 2>/dev/null)
            echo ""
            echo "── HDR10+ ($hp_bin) ──"
            echo "  Scene descriptors: $scenes"
            rm -f "$hp_json"
        else
            echo ""
            echo "── HDR10+: nu am detectat metadata dinamica ──"
        fi
    fi

    return 0
}

# ─────────────────────────────────────────────────────────────────────
# Submeniu principal
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════╗"
echo "║  HDR/DV TOOLS                        ║"
echo "╠══════════════════════════════════════╣"
echo "║  1) Transform RPU profile            ║"
echo "║     (cross-codec convert, no encode) ║"
echo "║  2) Remux container (MKV ↔ MP4/MOV)  ║"
echo "║  3) Inspect metadata (read-only)     ║"
echo "║  4) Inapoi                           ║"
echo "╚══════════════════════════════════════╝"
read -p "Alege 1-4: " hdv_choice

case "$hdv_choice" in
    1) hdv_flow_transform_rpu ;;
    2) hdv_flow_remux ;;
    3) hdv_flow_inspect ;;
    4) echo "Inapoi."; exit 0 ;;
    *) echo "Optiune invalida."; exit 1 ;;
esac
