#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# av_hdr_dv_tools.sh — HDR/DV Tools (v49)
#
# Submeniu pentru operatii metadata-only, FARA re-encode:
#   1) Transform RPU profile  — convert intre Profile 7/8.1/10 (cross-codec)
#   2) Inspect metadata       — dump RPU info + HDR10+ scenes (read-only)
#   3) HDR10+ → DV hybrid     — sintetizeaza DV RPU din HDR10+ metadata
#   4) Inapoi
#
# Remux container + Demux streams traiesc in av_mux.sh (v49+).
# Toate functiile de baza traiesc in av_common.sh; acest script e DOAR UI.
# ══════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/av_common.sh"

# ─────────────────────────────────────────────────────────────────────
# Helper privat — re-mux video bitstream procesat (RPU injectat / DV
# eliminat / HDR10+ scos) impreuna cu metadata din original (audio +
# subs + attach + chapters). Folosit de toate 4 flow-uri ca pas final.
# Aceasta NU este "remux user-facing" (acela traieste in av_mux.sh);
# e operatie post-processing fixa (map deterministic, fara prompts).
#   $1 = video bitstream modificat (raw HEVC/IVF, deja procesat)
#   $2 = fisier original (sursa de audio/subs/attach/metadata)
#   $3 = output path
#   $4+ = vtag flags optionale (ex: "-tag:v" "av01" pentru Remove DV pe mp4)
# Cere: $CONTAINER setat in caller (folosit de get_container_flags).
_hdv_combine_with_original() {
    local modified="$1" original="$2" output="$3"
    shift 3
    local vtag_args=("$@")
    local cont_flags; cont_flags=$(get_container_flags)
    # v69 audit FIX: HEVC annexb brut (post-inject dovi_tool) NU are PTS pe
    # B-frames → muxerul matroska refuza ("Can't write packet with unknown
    # timestamp", output gol). -fflags +genpts / -framerate NU ajuta (validat
    # empiric). Ruta robusta pt tinta .mkv: pas intermediar MP4 (muxerul mp4
    # deriva timestamps), apoi MP4→MKV. AV1/IVF neafectat (IVF poarta PTS).
    local _mod_ext="${modified##*.}"
    if [[ ( "$_mod_ext" == "hevc" || "$_mod_ext" == "h265" || "$_mod_ext" == "265" ) \
          && "${output##*.}" == "mkv" ]]; then
        # v70: mkvmerge scrie dvcC de container din RPU-ul brut (DV activabil si pe
        # TV); cand lipseste → pas MP4 (DV doar in bitstream, comportament v69).
        _mux_dv_mkv "$modified" "$original" "$output" && return 0
        local _step1; _step1=$(av_mktemp_ext mp4)
        local _rc=1
        if ffmpeg -v error -y -i "$modified" -i "$original" \
              -map 0:v:0 -map 1:a? -map 1:s? -map 1:t? \
              -c copy "${vtag_args[@]}" "$_step1" 2>/dev/null && [[ -s "$_step1" ]]; then
            ffmpeg -v error -y -i "$_step1" -c copy "$output" 2>/dev/null
            _rc=$?
        fi
        rm -f "$_step1"
        return $_rc
    fi
    # shellcheck disable=SC2086
    ffmpeg -v error -i "$modified" -i "$original" \
        -map 0:v:0 -map 1:a? -map 1:s? -map 1:t? \
        -c copy "${vtag_args[@]}" $cont_flags "$output" 2>/dev/null
    return $?
}

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
    echo "  Mode $AV_TOOL_DOVI convert (filtrate dupa codec sursa: $src_codec):"
    local _default_choice=1
    if [[ "$src_codec" == "hevc" ]]; then
        echo "    1) Force 8.1 (removes mapping, + HDR10 base)    [-m 2]"
        echo "    2) DV 5 -> 8.1                                  [-m 3]"
        echo "    3) 8.1 preserving luma/chroma mapping           [-m 5]"
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
           mode=5; target_codec="hevc" ;;
        4) [[ "$src_codec" != "av1" ]] && { echo "Mod 4 doar pentru AV1."; return 1; }
           mode=2; target_codec="av1" ;;
        *) echo "Optiune invalida."; return 1 ;;
    esac

    if ! _check_dovi_tool_for "$target_codec"; then
        local _t="$AV_TOOL_DOVI"; [[ "$target_codec" == "av1" ]] && _t="$AV_TOOL_AV1DOVI"
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
    local CONTAINER="$out_ext"
    # v57: tag DV-aware (MP4/MOV/M4V) — paritate cu hybrid + remove_dv flows
    local vtag=()
    case "${out_ext,,}" in
        mp4|mov|m4v)
            if [[ "$target_codec" == "av1" ]]; then vtag=(-tag:v av01); else vtag=(-tag:v hvc1); fi
            ;;
    esac
    _hdv_combine_with_original "$injected_video" "$file" "$final_out" "${vtag[@]}"
    local rc=$?
    rm -f "$rpu_src" "$rpu_out" "$raw_video" "$injected_video"
    if [ $rc -eq 0 ] && [ -s "$final_out" ]; then
        # v56: guard onest pentru known issue AV1 — inject-rpu produce T.35 malformat,
        # ffmpeg il respinge la pachetizare si DV-ul e pierdut silentios (rc=0, output ne-gol).
        if [[ "$target_codec" == "av1" ]] && ! verify_dv_survived "$final_out" "$target_codec"; then
            echo ""
            echo "  ⚠ AVERTISMENT: stratul Dolby Vision a fost pierdut la re-mux."
            echo "    Cauza: $AV_TOOL_AV1DOVI inject-rpu produce metadata T.35 pe care ffmpeg"
            echo "    o respinge la pachetizare (known issue toolchain AV1 DV — Tier 4)."
            echo "    Fisier generat, dar FARA DV: $final_out"
            return 1
        fi
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
# Flow 2: Inspect metadata (read-only)
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
            echo "── DV RPU summary ($dovi_bin) ──"
            # v55: info -s = rezumat agregat (frames, profile, DM ver, scene count,
            # mastering display, L1/L5/L6) — mai util decat info -i (un singur frame).
            "$dovi_bin" info -i "$rpu_tmp" -s 2>/dev/null || echo "  (info command esuata)"
            # v56 (C1): export RPU complet la JSON pentru analiza offline
            mkdir -p "$OUTPUT_DIR"
            local exp_json="${OUTPUT_DIR}/$(basename "${file%.*}")_rpu.json"
            if export_dv_rpu_json "$rpu_tmp" "$exp_json" "all" "$src_codec"; then
                echo "  RPU JSON exportat: $exp_json"
            fi
        else
            echo ""
            echo "── DV: nu am putut extrage RPU (probabil sursa nu este DV) ──"
        fi
        rm -f "$rpu_tmp"
    else
        echo ""
        echo "── DV: tool negasit pentru codec=$src_codec ──"
    fi

    # HDR10+ inspect (v56 B3: --verify autoritar + scene descriptors)
    if _check_hdr10plus_tool_for "$src_codec"; then
        local hp_bin
        hp_bin=$(tool_for_extract "$src_codec" hdr10plus)
        echo ""
        echo "── HDR10+ ($hp_bin) ──"
        if verify_hdr10plus "$file" "$src_codec"; then
            echo "  ✓ Metadata HDR10+ dinamica: PREZENTA (--verify)"
            local hp_json
            hp_json=$(extract_hdr10plus_metadata "$file" 2>/dev/null)
            if [[ -n "$hp_json" ]] && [ -s "$hp_json" ]; then
                local scenes
                scenes=$(grep -c '"BezierCurveData"\|"TargetedSystemDisplay"' "$hp_json" 2>/dev/null)
                echo "  Scene descriptors: $scenes"
                rm -f "$hp_json"
            fi
        else
            echo "  ✗ Metadata HDR10+ dinamica: ABSENTA (--verify)"
        fi
    fi

    return 0
}

# ─────────────────────────────────────────────────────────────────────
# Flow 3: HDR10+ → DV hybrid (no re-encode) — v45
# Pipeline: extract HDR10+ JSON → synthesize DV RPU → extract raw video
#          → inject RPU → re-mux audio original.
# Rezultat: sursa pastreaza HDR10 base + HDR10+ dinamic (deja in bitstream)
# si primeste un strat DV (Profile 8.1 HEVC sau Profile 10 AV1).
# Pentru AV1 surse exista HDR10+ inline in OBU_METADATA, deci JSON-ul e
# doar pentru sinteza DV RPU; bitstream-ul video nu se atinge.
# ─────────────────────────────────────────────────────────────────────
hdv_flow_hdr10plus_to_dv() {
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  HDR10+ → DV HYBRID (no re-encode)           ║"
    echo "║  Sintetizeaza DV RPU din HDR10+ metadata     ║"
    echo "║  si il injecteaza in bitstream existent.     ║"
    echo "╚══════════════════════════════════════════════╝"
    _hdv_pick_file "Alege fisier sursa (cu HDR10+)" "$INPUT_DIR" || { echo "Anulat."; return 1; }
    local file="$HDV_PICKED_FILE"
    local src_codec
    src_codec=$(detect_source_codec "$file")
    echo "  Codec sursa: $src_codec"

    if [[ "$src_codec" != "hevc" && "$src_codec" != "av1" ]]; then
        echo "  EROARE: Doar HEVC si AV1 sunt suportate (sursa: $src_codec)."
        return 1
    fi
    if ! _check_hdr10plus_tool_for "$src_codec"; then
        local _hp="$AV_TOOL_HDR10PLUS"; [[ "$src_codec" == "av1" ]] && _hp="$AV_TOOL_AV1HDR10PLUS"
        echo "  EROARE: $_hp nu este instalat (necesar pt sursa $src_codec)."
        return 1
    fi
    if ! _check_dovi_tool_for "$src_codec"; then
        local _dv="$AV_TOOL_DOVI"; [[ "$src_codec" == "av1" ]] && _dv="$AV_TOOL_AV1DOVI"
        echo "  EROARE: $_dv nu este instalat (necesar pt sinteza DV RPU)."
        return 1
    fi

    # Pas 1: extract HDR10+ JSON (codec-aware)
    echo ""
    echo "  [1/4] Extract HDR10+ JSON..."
    local hp_json
    hp_json=$(extract_hdr10plus_metadata "$file")
    if [[ -z "$hp_json" ]] || [ ! -s "$hp_json" ]; then
        echo "  EROARE: Extract HDR10+ esuat (sursa nu are metadata dinamica?)."
        return 1
    fi

    # Pas 2: sintetizeaza DV RPU (target_codec = source codec)
    echo ""
    echo "  [2/4] Sintetizez DV RPU din HDR10+..."
    local rpu_out
    rpu_out=$(generate_dv_rpu_from_hdr10plus "$hp_json" "$src_codec" "$file")
    if [[ -z "$rpu_out" ]] || [ ! -s "$rpu_out" ]; then
        echo "  EROARE: Sinteza DV RPU esuata."
        rm -f "$hp_json"
        return 1
    fi

    # Pas 3: extract video raw + inject RPU
    local raw_ext="hevc"
    [[ "$src_codec" == "av1" ]] && raw_ext="ivf"
    local raw_video injected_video
    raw_video=$(av_mktemp_ext "$raw_ext")
    injected_video=$(av_mktemp_ext "$raw_ext")

    echo ""
    echo "  [3/4] Extract raw video ($src_codec) + inject RPU..."
    if ! extract_raw_video "$file" "$raw_video" "$src_codec"; then
        echo "  EROARE: Extract raw video esuat."
        rm -f "$hp_json" "$rpu_out" "$raw_video"
        return 1
    fi
    if ! inject_dv_rpu "$raw_video" "$rpu_out" "$injected_video" "$src_codec"; then
        echo "  EROARE: Inject RPU esuat."
        rm -f "$hp_json" "$rpu_out" "$raw_video" "$injected_video"
        return 1
    fi

    # Pas 4: re-mux video cu DV + audio/sub/track-uri din original
    local out_ext="${file##*.}"
    local final_out="${OUTPUT_DIR}/$(basename "${file%.*}")_dvhybrid.${out_ext}"
    mkdir -p "$OUTPUT_DIR"
    local CONTAINER="$out_ext"

    # v57: tag video pt DV-aware playere (MP4/MOV/M4V) — hvc1/av01 standard.
    # Pe MKV nu se aplica (containerul foloseste codec ID strings, nu FourCC tags).
    local vtag=()
    case "${out_ext,,}" in
        mp4|mov|m4v)
            if [[ "$src_codec" == "av1" ]]; then vtag=(-tag:v av01); else vtag=(-tag:v hvc1); fi
            ;;
    esac

    echo ""
    echo "  [4/4] Re-mux final..."
    _hdv_combine_with_original "$injected_video" "$file" "$final_out" "${vtag[@]}"
    local rc=$?
    rm -f "$hp_json" "$rpu_out" "$raw_video" "$injected_video"
    if [ $rc -eq 0 ] && [ -s "$final_out" ]; then
        # v56: guard onest pentru known issue AV1 (vezi hdv_flow_transform_rpu)
        if [[ "$src_codec" == "av1" ]] && ! verify_dv_survived "$final_out" "$src_codec"; then
            echo ""
            echo "  ⚠ AVERTISMENT: stratul Dolby Vision NU a fost adaugat (pierdut la re-mux)."
            echo "    Cauza: $AV_TOOL_AV1DOVI inject-rpu produce metadata T.35 pe care ffmpeg"
            echo "    o respinge la pachetizare (known issue toolchain AV1 DV — Tier 4)."
            echo "    Output-ul pastreaza HDR10/HDR10+ original, dar FARA strat DV: $final_out"
            return 1
        fi
        local _label="DV 8.1 + HDR10 + HDR10+ (HEVC)"
        [[ "$src_codec" == "av1" ]] && _label="DV P10 + HDR10 + HDR10+ (AV1)"
        echo ""
        echo "  ✓ HDR10+ → DV hybrid complet: $final_out"
        echo "    $_label"
        return 0
    else
        echo "  EROARE: Re-mux final esuat."
        rm -f "$final_out"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────
# Flow 4: Remove DV → HDR10 curat (v56) — scoate stratul DV (EL+RPU),
# pastreaza HDR10 static (+ HDR10+ daca exista). No re-encode.
# ─────────────────────────────────────────────────────────────────────
hdv_flow_remove_dv() {
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  REMOVE DV → HDR10 CURAT                     ║"
    echo "║  Scoate stratul DV (EL+RPU). HDR10/HDR10+    ║"
    echo "║  raman intacte. Fara re-encode video.        ║"
    echo "╚══════════════════════════════════════════════╝"
    _hdv_pick_file "Alege fisier sursa (cu DV)" "$INPUT_DIR" || { echo "Anulat."; return 1; }
    local file="$HDV_PICKED_FILE"
    local src_codec
    src_codec=$(detect_source_codec "$file")
    echo "  Codec sursa: $src_codec"

    if [[ "$src_codec" != "hevc" && "$src_codec" != "av1" ]]; then
        echo "  EROARE: Doar HEVC si AV1 sunt suportate (sursa: $src_codec)."
        return 1
    fi
    if ! _check_dovi_tool_for "$src_codec"; then
        local _t="$AV_TOOL_DOVI"; [[ "$src_codec" == "av1" ]] && _t="$AV_TOOL_AV1DOVI"
        echo "  EROARE: $_t nu este instalat. Vezi src/tools/."
        return 1
    fi

    local raw_ext="hevc"
    [[ "$src_codec" == "av1" ]] && raw_ext="ivf"
    local raw_video clean_video
    raw_video=$(av_mktemp_ext "$raw_ext")
    clean_video=$(av_mktemp_ext "$raw_ext")
    local out_ext="${file##*.}"
    local final_out="${OUTPUT_DIR}/$(basename "${file%.*}")_nodv.${out_ext}"
    mkdir -p "$OUTPUT_DIR"

    echo ""
    echo "  [1/3] Extract raw video ($src_codec)..."
    if ! extract_raw_video "$file" "$raw_video" "$src_codec"; then
        echo "  EROARE: Extract raw video esuat."
        rm -f "$raw_video"; return 1
    fi
    echo "  [2/3] Remove DV layer..."
    if ! remove_dv_layer "$raw_video" "$clean_video" "$src_codec"; then
        echo "  EROARE: Remove DV esuat."
        rm -f "$raw_video" "$clean_video"; return 1
    fi

    echo "  [3/3] Re-mux + tag HDR10 curat..."
    local CONTAINER="$out_ext"
    # tag video curat (fara semnalizare DV) pe MP4/MOV
    local vtag=()
    case "${out_ext,,}" in
        mp4|mov|m4v)
            if [[ "$src_codec" == "av1" ]]; then vtag=(-tag:v av01); else vtag=(-tag:v hvc1); fi
            ;;
    esac
    _hdv_combine_with_original "$clean_video" "$file" "$final_out" "${vtag[@]}"
    local rc=$?
    rm -f "$raw_video" "$clean_video"
    if [ $rc -eq 0 ] && [ -s "$final_out" ]; then
        echo ""
        echo "  ✓ DV eliminat (HDR10 curat): $final_out"
        return 0
    else
        echo "  EROARE: Re-mux final esuat."
        rm -f "$final_out"; return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────
# Flow 5: Remove HDR10+ metadata (v56) — scoate SEI/OBU HDR10+,
# pastreaza HDR10 static (+ DV daca exista). No re-encode.
# ─────────────────────────────────────────────────────────────────────
hdv_flow_remove_hdr10plus() {
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  REMOVE HDR10+ METADATA                      ║"
    echo "║  Scoate metadata dinamica HDR10+. HDR10/DV   ║"
    echo "║  raman intacte. Fara re-encode video.        ║"
    echo "╚══════════════════════════════════════════════╝"
    _hdv_pick_file "Alege fisier sursa (cu HDR10+)" "$INPUT_DIR" || { echo "Anulat."; return 1; }
    local file="$HDV_PICKED_FILE"
    local src_codec
    src_codec=$(detect_source_codec "$file")
    echo "  Codec sursa: $src_codec"

    if [[ "$src_codec" != "hevc" && "$src_codec" != "av1" ]]; then
        echo "  EROARE: Doar HEVC si AV1 sunt suportate (sursa: $src_codec)."
        return 1
    fi
    if ! _check_hdr10plus_tool_for "$src_codec"; then
        local _hp="$AV_TOOL_HDR10PLUS"; [[ "$src_codec" == "av1" ]] && _hp="$AV_TOOL_AV1HDR10PLUS"
        echo "  EROARE: $_hp nu este instalat. Vezi src/tools/."
        return 1
    fi

    local raw_ext="hevc"
    [[ "$src_codec" == "av1" ]] && raw_ext="ivf"
    local raw_video clean_video
    raw_video=$(av_mktemp_ext "$raw_ext")
    clean_video=$(av_mktemp_ext "$raw_ext")
    local out_ext="${file##*.}"
    local final_out="${OUTPUT_DIR}/$(basename "${file%.*}")_nohdr10plus.${out_ext}"
    mkdir -p "$OUTPUT_DIR"

    echo ""
    echo "  [1/3] Extract raw video ($src_codec)..."
    if ! extract_raw_video "$file" "$raw_video" "$src_codec"; then
        echo "  EROARE: Extract raw video esuat."
        rm -f "$raw_video"; return 1
    fi
    echo "  [2/3] Remove HDR10+ metadata..."
    if ! remove_hdr10plus_metadata "$raw_video" "$clean_video" "$src_codec"; then
        echo "  EROARE: Remove HDR10+ esuat."
        rm -f "$raw_video" "$clean_video"; return 1
    fi

    echo "  [3/3] Re-mux final..."
    local CONTAINER="$out_ext"
    _hdv_combine_with_original "$clean_video" "$file" "$final_out"
    local rc=$?
    rm -f "$raw_video" "$clean_video"
    if [ $rc -eq 0 ] && [ -s "$final_out" ]; then
        echo ""
        echo "  ✓ HDR10+ eliminat: $final_out"
        return 0
    else
        echo "  EROARE: Re-mux final esuat."
        rm -f "$final_out"; return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────
# Flow 6: Plot DV metadata → PNG (v56) — grafic L1/L2/L8 nativ dovi_tool.
# ─────────────────────────────────────────────────────────────────────
hdv_flow_plot() {
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  PLOT DV METADATA → PNG                      ║"
    echo "║  Grafic L1 (brightness) / L2 / L8 trims.     ║"
    echo "╚══════════════════════════════════════════════╝"
    _hdv_pick_file "Alege fisier sursa (cu DV)" "$INPUT_DIR" || { echo "Anulat."; return 1; }
    local file="$HDV_PICKED_FILE"
    local src_codec
    src_codec=$(detect_source_codec "$file")
    echo "  Codec sursa: $src_codec"

    if [[ "$src_codec" != "hevc" && "$src_codec" != "av1" ]]; then
        echo "  EROARE: Doar HEVC si AV1 sunt suportate (sursa: $src_codec)."
        return 1
    fi
    if ! _check_dovi_tool_for "$src_codec"; then
        local _t="$AV_TOOL_DOVI"; [[ "$src_codec" == "av1" ]] && _t="$AV_TOOL_AV1DOVI"
        echo "  EROARE: $_t nu este instalat. Vezi src/tools/."
        return 1
    fi

    echo ""
    echo "  Tip plot:"
    echo "    1) L1 — Dynamic Brightness          (implicit)"
    echo "    2) L2 — Trims"
    echo "    3) L8 — Trims (CM v4.0 RPU)"
    read -p "  Alege [implicit: 1]: " ptype_choice
    local plot_type="l1"
    case "${ptype_choice:-1}" in
        1) plot_type="l1" ;;
        2) plot_type="l2" ;;
        3) plot_type="l8" ;;
        *) echo "Optiune invalida."; return 1 ;;
    esac

    local rpu_tmp
    rpu_tmp=$(av_mktemp_ext bin)
    echo ""
    echo "  [1/2] Extract RPU..."
    if ! extract_dv_rpu "$file" "$rpu_tmp" "$src_codec"; then
        echo "  EROARE: Extract RPU esuat (sursa nu este DV?)."
        rm -f "$rpu_tmp"; return 1
    fi

    mkdir -p "$OUTPUT_DIR"
    local final_png="${OUTPUT_DIR}/$(basename "${file%.*}")_dvplot_${plot_type}.png"
    local title; title="$(basename "${file%.*}") — DV ${plot_type^^}"
    echo "  [2/2] Plot $plot_type..."
    if plot_dv_metadata "$rpu_tmp" "$final_png" "$plot_type" "$title" "$src_codec"; then
        echo ""
        echo "  ✓ Plot generat: $final_png"
        rm -f "$rpu_tmp"; return 0
    else
        echo "  EROARE: Plot esuat (RPU nu contine $plot_type?)."
        rm -f "$rpu_tmp"; return 1
    fi
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
echo "║  2) Inspect metadata (read-only)     ║"
echo "║  3) HDR10+ → DV hybrid (no re-encode)║"
echo "║  4) Remove DV → HDR10 curat          ║"
echo "║  5) Remove HDR10+ metadata           ║"
echo "║  6) Plot DV metadata (L1/L2/L8 PNG)  ║"
echo "║  7) Inapoi                           ║"
echo "╚══════════════════════════════════════╝"
echo "  Nota: Remux container e acum in 'Mux tools' (opt 7 meniu principal)."
read -p "Alege 1-7: " hdv_choice

case "$hdv_choice" in
    1) hdv_flow_transform_rpu ;;
    2) hdv_flow_inspect ;;
    3) hdv_flow_hdr10plus_to_dv ;;
    4) hdv_flow_remove_dv ;;
    5) hdv_flow_remove_hdr10plus ;;
    6) hdv_flow_plot ;;
    7) echo "Inapoi."; exit 0 ;;
    *) echo "Optiune invalida."; exit 1 ;;
esac
