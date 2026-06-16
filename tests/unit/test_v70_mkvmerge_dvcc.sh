#!/usr/bin/env bash
# v70 — mkvmerge soft-optional pt semnalizare dvcC de container pe hibridele
# HEVC Dolby Vision. ffmpeg NU poate sintetiza dvcC din RPU brut (calea v69 =
# pas MP4 → DV doar in bitstream); mkvmerge parseaza RPU-ul din elementary
# stream si scrie "DOVI configuration record" → DV activabil si pe TV.
#   Source-level (mereu): blocul AV_TOOL_MKVMERGE, helper _mux_dv_mkv, mkvmerge
#   inainte de pasul MP4 (fallback) in cele 2 situri bash, installer-ele.
#   Functional (cand exista ffmpeg+dovi_tool+mkvmerge): construieste un hibrid
#   HEVC mic self-contained → muxeaza via helperul REAL → asserteaza dvcC.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
# ffmpeg/dovi: global (PATH) sau bundle-uit in src/ (Windows testing) — ca v55/v56/v62
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"
source "$SCRIPT_DIR/av_common.sh"

COMMON="$(cat "$SCRIPT_DIR/av_common.sh")"
HDV="$(cat "$SCRIPT_DIR/av_hdr_dv_tools.sh")"

# ── 1. AV_TOOL_MKVMERGE in blocul de config (env-overridable, sursa unica) ──
assert_contains "$COMMON" 'AV_TOOL_MKVMERGE="${AV_TOOL_MKVMERGE:-mkvmerge}"' "AV_TOOL_MKVMERGE in blocul config"

# ── 2. helper _mux_dv_mkv: definit + foloseste DOAR variabila ──────────────
assert_eq "function" "$(type -t _mux_dv_mkv)" "_mux_dv_mkv definit (sourced din av_common.sh)"
assert_contains "$COMMON" 'command -v "$AV_TOOL_MKVMERGE"' "_mux_dv_mkv: detectie soft prin variabila"
assert_contains "$COMMON" '"$AV_TOOL_MKVMERGE" -o "$output" --default-duration' "_mux_dv_mkv: --default-duration (raw HEVC nu poarta timing)"
assert_contains "$COMMON" '--no-video "$donor"' "_mux_dv_mkv: non-video din donor"
assert_contains "$COMMON" '-map 0:a? -map 0:s? -map 0:t? -map_chapters 0' "_mux_dv_mkv: donor MKV non-video pe surse non-MKV (#2 consistenta limbi)"

# ── 3. mkvmerge-FIRST (fallback pe pasul MP4 v69) in cele 2 situri bash ────
# v71: conditia e acum [[ mkv ]] && _mux_dv_mkv (HEVC+AV1; inainte gateat != av1)
assert_contains "$COMMON" '"$CONTAINER" == "mkv" ]] && _mux_dv_mkv "$injected_temp" "$output" "$final_temp"; then' "triple-layer: _mux_dv_mkv pe ramura mkv (HEVC+AV1)"
assert_contains "$HDV" '_mux_dv_mkv "$modified" "$original" "$output" && return 0' "_hdv_combine: _mux_dv_mkv pe ramura mkv"
# ordonare: helperul mkvmerge INAINTE de pasul intermediar MP4 (av_mktemp_ext mp4)
lc_mkv=$(grep -n '&& _mux_dv_mkv "\$injected_temp"' "$SCRIPT_DIR/av_common.sh" | head -1 | cut -d: -f1)
lc_mp4=$(grep -n '_tl_step1=$(av_mktemp_ext mp4)' "$SCRIPT_DIR/av_common.sh" | head -1 | cut -d: -f1)
assert_eq "1" "$([[ -n "$lc_mkv" && -n "$lc_mp4" && "$lc_mkv" -lt "$lc_mp4" ]] && echo 1 || echo 0)" "triple-layer: mkvmerge inainte de fallback MP4"
lh_mkv=$(grep -n '_mux_dv_mkv "\$modified"' "$SCRIPT_DIR/av_hdr_dv_tools.sh" | head -1 | cut -d: -f1)
lh_mp4=$(grep -n '_step1=$(av_mktemp_ext mp4)' "$SCRIPT_DIR/av_hdr_dv_tools.sh" | head -1 | cut -d: -f1)
assert_eq "1" "$([[ -n "$lh_mkv" && -n "$lh_mp4" && "$lh_mkv" -lt "$lh_mp4" ]] && echo 1 || echo 0)" "_hdv_combine: mkvmerge inainte de fallback MP4"

# ── 4. installer-ele exista ───────────────────────────────────────────────
assert_file_exists "$SCRIPT_DIR/tools/mkvmerge_installer.sh" "installer bash"
assert_file_exists "$SCRIPT_DIR/tools/mkvmerge_installer.ps1" "installer PS1"

# ── 4b. #3: av_mux post-process dvcC pe raw HEVC DV → MKV ─────────────
MUX="$(cat "$SCRIPT_DIR/av_mux.sh")"
assert_contains "$MUX" '_dv_raw_src="$video"' "av_mux: salveaza calea raw HEVC pt dvcC (#3)"
assert_contains "$MUX" '_dv_container_signal "$_dv_raw_src" "$final_out" "$TARGET"' "av_mux Mux: dispatch partajat _dv_container_signal (#3)"
assert_contains "$COMMON" '_mux_dv_mkv "$raw" "$built"' "dispatch _dv_container_signal: mkv -> _mux_dv_mkv"

# ── 5. FUNCTIONAL — hibrid HEVC mic self-contained → dvcC via helper real ──
MKVM="${AV_TOOL_MKVMERGE:-mkvmerge}"
DOVI="${AV_TOOL_DOVI:-dovi_tool}"
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1 \
   && command -v "$DOVI" >/dev/null 2>&1 && command -v "$MKVM" >/dev/null 2>&1; then
    TD="$(mktemp -d)"
    # clip PQ cu audio (lang=fre) + sub mov_text (lang=spa) — exercita donor-ul (#2):
    # sursa non-MKV cu non-video; mov_text forteaza ramura -c:s srt din donor.
    printf '1\n00:00:00,000 --> 00:00:01,000\nhi\n' > "$TD/s.srt"
    ffmpeg -y -loglevel error -f lavfi -i "testsrc2=size=320x240:rate=12:duration=1" \
        -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=1" -i "$TD/s.srt" \
        -map 0:v -map 1:a -map 2:s -c:v libx265 -pix_fmt yuv420p10le \
        -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc" \
        -c:a aac -c:s mov_text -metadata:s:a:0 language=fre -metadata:s:s:0 language=spa -t 1 "$TD/t.mp4" 2>/dev/null
    ffmpeg -y -loglevel error -i "$TD/t.mp4" -map 0:v:0 -c:v copy -bsf:v hevc_mp4toannexb "$TD/t.hevc" 2>/dev/null
    printf '%s' '{ "cm_version": "V40", "length": 12, "level6": { "max_display_mastering_luminance": 1000, "min_display_mastering_luminance": 1, "max_content_light_level": 1000, "max_frame_average_light_level": 400 } }' > "$TD/cfg.json"
    "$DOVI" generate -j "$TD/cfg.json" -o "$TD/rpu.bin" >/dev/null 2>&1 || true
    "$DOVI" inject-rpu -i "$TD/t.hevc" --rpu-in "$TD/rpu.bin" -o "$TD/hybrid.hevc" >/dev/null 2>&1 || true
    if [ -s "$TD/hybrid.hevc" ]; then
        ok=0; _mux_dv_mkv "$TD/hybrid.hevc" "$TD/t.mp4" "$TD/out.mkv" && ok=1
        assert_eq "1" "$ok" "functional: _mux_dv_mkv reuseste pe hibrid HEVC"
        probe="$(ffprobe -v error -select_streams v:0 -show_streams -show_entries stream_side_data=side_data_type "$TD/out.mkv" 2>/dev/null || true)"
        assert_eq "1" "$(echo "$probe" | grep -qi "DOVI configuration record" && echo 1 || echo 0)" "functional: dvcC scris in MKV (DOVI configuration record)"
        # #2: donor-ul pastreaza pista audio + limba pe sursa non-MKV (consistent cu calea ffmpeg)
        alang="$(ffprobe -v error -select_streams a:0 -show_entries stream_tags=language -of default=noprint_wrappers=1:nokey=1 "$TD/out.mkv" 2>/dev/null | head -1 | tr -d '\r' || true)"
        assert_eq "fre" "$alang" "functional #2: donor pastreaza limba audio pe sursa non-MKV"
        ssub="$(ffprobe -v error -select_streams s:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$TD/out.mkv" 2>/dev/null | head -1 | tr -d '\r' || true)"
        assert_eq "subrip" "$ssub" "functional #2: donor pastreaza subtitrarea (mov_text→srt via -c:s srt) pe non-MKV"
        # fallback: tool absent → return 1, fara output partial
        fb=0; AV_TOOL_MKVMERGE="/nonexistent/zz_mux" _mux_dv_mkv "$TD/hybrid.hevc" "$TD/t.mp4" "$TD/fb.mkv" || fb=1
        assert_eq "1" "$fb" "functional: fallback (tool absent) → return 1"
        assert_file_not_exists "$TD/fb.mkv" "functional: fallback nu lasa output partial"
    else
        echo "  (functional sarit: build hibrid esuat — dovi_tool generate/inject)" >&2
    fi
    rm -rf "$TD"
else
    echo "  (functional sarit: ffmpeg/ffprobe/dovi_tool/mkvmerge lipsesc)" >&2
fi
