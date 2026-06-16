#!/usr/bin/env bash
# v71 — MP4Box (GPAC) soft-optional pt semnalizare dvcC de container pe hibridele
# HEVC Dolby Vision care merg in MP4/MOV (echivalentul MP4/MOV al mkvmerge din v70).
# ffmpeg NU poate scrie dvcC din RPU brut; MP4Box auto-detecteaza RPU si scrie box-ul.
#   Source-level (mereu): blocul AV_TOOL_MP4BOX, helper _mux_dv_mp4, gating MP4/MOV,
#   integrarea in cele 2 situri + av_mux, installerele.
#   Functional (cand exista ffmpeg+dovi_tool+MP4Box): hibrid HEVC multi-track →
#   helperul REAL → dvcC + audio/sub pastrate; sursa MKV → fallback (return 1).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"
source "$SCRIPT_DIR/av_common.sh"

COMMON="$(cat "$SCRIPT_DIR/av_common.sh")"
HDV="$(cat "$SCRIPT_DIR/av_hdr_dv_tools.sh")"
MUX="$(cat "$SCRIPT_DIR/av_mux.sh")"

# ── 1. AV_TOOL_MP4BOX in blocul config ────────────────────────────────────
assert_contains "$COMMON" 'AV_TOOL_MP4BOX="${AV_TOOL_MP4BOX:-mp4box}"' "AV_TOOL_MP4BOX in blocul config"

# ── 2. helper _mux_dv_mp4: definit + foloseste variabila + gating MP4/MOV ──
assert_eq "function" "$(type -t _mux_dv_mp4)" "_mux_dv_mp4 definit (sourced)"
assert_contains "$COMMON" 'command -v "$AV_TOOL_MP4BOX"' "_mux_dv_mp4: detectie soft prin variabila"
assert_contains "$COMMON" 'mp4|mov|m4v|qt) : ;; *) return 1 ;;' "_mux_dv_mp4: gating pe surse ISO (MP4/MOV)"
assert_contains "$COMMON" '"${raw_hevc}:fps=${afr}"' "_mux_dv_mp4: :fps (raw nu poarta timing)"
assert_contains "$COMMON" '"${original}#$((_id))"' "_mux_dv_mp4: -add per track ID (#N)"

# ── 3. integrat in cele 2 situri bash + av_mux ────────────────────────────
assert_contains "$COMMON" '_mux_dv_mp4 "$injected_temp" "$output" "$final_temp"' "triple-layer: _mux_dv_mp4 pe ramura mp4/mov"
assert_contains "$HDV" '_mux_dv_mp4 "$modified" "$original" "$output" && return 0' "_hdv_combine: _mux_dv_mp4 pe ramura mp4/mov"
# dispatch + resignal partajate in av_common (DRY)
assert_contains "$COMMON" '_dv_container_signal() {' "av_common: dispatch _dv_container_signal definit (partajat)"
assert_contains "$COMMON" '_dv_resignal_copy() {' "av_common: _dv_resignal_copy definit (re-signal stream-copy)"
assert_contains "$COMMON" '_mux_dv_mp4 "$raw" "$built"' "dispatch _dv_container_signal: mp4/mov -> _mux_dv_mp4"
assert_contains "$MUX" '_dv_container_signal "$_dv_raw_src" "$final_out" "$TARGET"' "av_mux Mux: dispatch partajat"
assert_contains "$MUX" '_dv_resignal_copy "$file" "$final_out" "$target"' "av_mux Remux: DV-aware (#1)"
# passthrough stream-copy: do_stream_copy + audio-only + trim/batch re-scriu dvcC
assert_contains "$COMMON" '_dv_resignal_copy "$file" "$output" "$_sc_ext"' "do_stream_copy: re-signal dvcC"
assert_contains "$(cat "$SCRIPT_DIR/av_encoder_audio.sh")" '_dv_resignal_copy "$file" "$output" "$_au_ext"' "av_encoder_audio: re-signal dvcC"
assert_contains "$(cat "$SCRIPT_DIR/av_trimconcat.sh")" '_dv_resignal_copy "$src" "$out_path" "$_tr_ext"' "av_trimconcat trim: re-signal dvcC"
assert_contains "$(cat "$SCRIPT_DIR/av_trimconcat.sh")" '_dv_resignal_copy "$src" "$out_path" "$_bt_ext"' "av_trimconcat batch trim: re-signal dvcC"

# ── 4. installerele exista ────────────────────────────────────────────────
assert_file_exists "$SCRIPT_DIR/tools/mp4box_installer.sh" "installer bash"
assert_file_exists "$SCRIPT_DIR/tools/mp4box_installer.ps1" "installer PS1"

# ── 5. FUNCTIONAL — hibrid HEVC multi-track → dvcC via helperul real ──────
# NB: pe git-bash/MSYS, MP4Box.exe (Windows) NU accepta caile MSYS /tmp/... cu
# sintaxa ":fps=" (conversia de cale MSYS nu se aplica peste optiunea cu ':') →
# functional sarit pe MSYS (rulat nativ pe Linux/macOS/Termux; Windows = test PS1).
MP4BOX="${AV_TOOL_MP4BOX:-mp4box}"
DOVI="${AV_TOOL_DOVI:-dovi_tool}"
_is_msys=0
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) _is_msys=1 ;; esac
if [ "$_is_msys" = "0" ] && command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1 \
   && command -v "$DOVI" >/dev/null 2>&1 && command -v "$MP4BOX" >/dev/null 2>&1; then
    TD="$(mktemp -d)"
    printf '1\n00:00:00,000 --> 00:00:01,000\nhi\n' > "$TD/s.srt"
    # meta cu 2 capitole — MP4Box -add NU le copiaza → dump-chap+chap le cara
    printf ';FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=500\ntitle=Intro\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=500\nEND=1000\ntitle=Scene 2\n' > "$TD/meta.txt"
    ffmpeg -y -loglevel error -f lavfi -i "testsrc2=size=320x240:rate=12:duration=1" \
        -f lavfi -i "sine=frequency=440:duration=1" -f lavfi -i "sine=frequency=880:duration=1" -i "$TD/s.srt" -i "$TD/meta.txt" \
        -map 0:v -map 1:a -map 2:a -map 3:s -map_metadata 4 -map_chapters 4 -c:v libx265 -pix_fmt yuv420p10le \
        -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc" \
        -c:a aac -c:s mov_text -metadata:s:a:0 language=fre -metadata:s:a:1 language=ger -metadata:s:s:0 language=spa \
        -t 1 "$TD/multi.mp4" 2>/dev/null
    ffmpeg -y -loglevel error -i "$TD/multi.mp4" -map 0:v:0 -c:v copy -bsf:v hevc_mp4toannexb "$TD/v.hevc" 2>/dev/null
    printf '%s' '{ "cm_version": "V40", "length": 12, "level6": { "max_display_mastering_luminance": 1000, "min_display_mastering_luminance": 1, "max_content_light_level": 1000, "max_frame_average_light_level": 400 } }' > "$TD/cfg.json"
    "$DOVI" generate -j "$TD/cfg.json" -o "$TD/rpu.bin" >/dev/null 2>&1 || true
    "$DOVI" inject-rpu -i "$TD/v.hevc" --rpu-in "$TD/rpu.bin" -o "$TD/vh.hevc" >/dev/null 2>&1 || true
    if [ -s "$TD/vh.hevc" ]; then
        ok=0; _mux_dv_mp4 "$TD/vh.hevc" "$TD/multi.mp4" "$TD/out.mp4" && ok=1
        assert_eq "1" "$ok" "functional: _mux_dv_mp4 reuseste pe hibrid HEVC"
        probe="$(ffprobe -v error -select_streams v:0 -show_streams -show_entries stream_side_data=side_data_type "$TD/out.mp4" 2>/dev/null || true)"
        assert_eq "1" "$(echo "$probe" | grep -qi "DOVI configuration record" && echo 1 || echo 0)" "functional: dvcC scris in MP4 (DOVI configuration record)"
        nv="$(ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 "$TD/out.mp4" 2>/dev/null | grep -c . || true)"
        assert_eq "1" "$nv" "functional: un singur track video (fara duplicat)"
        a0="$(ffprobe -v error -select_streams a:0 -show_entries stream_tags=language -of default=noprint_wrappers=1:nokey=1 "$TD/out.mp4" 2>/dev/null | head -1 | tr -d '\r' || true)"
        assert_eq "fre" "$a0" "functional: limba audio 1 (fre) pastrata"
        # numar audio+sub separat (-select_streams ia un singur specificator)
        na="$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$TD/out.mp4" 2>/dev/null | grep -c . || true)"
        ns="$(ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$TD/out.mp4" 2>/dev/null | grep -c . || true)"
        assert_eq "2" "$na" "functional: ambele piste audio pastrate"
        assert_eq "1" "$ns" "functional: subtitrarea pastrata"
        nc="$(ffprobe -v error -show_chapters -of csv=p=0 "$TD/out.mp4" 2>/dev/null | grep -c . || true)"
        assert_eq "2" "$nc" "functional: capitolele pastrate (dump-chap + chap; MP4Box -add nu le copiaza)"
        # gating: sursa MKV → return 1 (fallback), fara output
        ffmpeg -y -loglevel error -i "$TD/multi.mp4" -c copy "$TD/src.mkv" 2>/dev/null
        gk=0; _mux_dv_mp4 "$TD/vh.hevc" "$TD/src.mkv" "$TD/frommkv.mp4" || gk=1
        assert_eq "1" "$gk" "functional: gating non-ISO (MKV) → return 1"
        assert_file_not_exists "$TD/frommkv.mp4" "functional: gating nu lasa output"
    else
        echo "  (functional sarit: build hibrid esuat)" >&2
    fi
    rm -rf "$TD"
else
    echo "  (functional sarit: ffmpeg/ffprobe/dovi_tool/MP4Box lipsesc)" >&2
fi
