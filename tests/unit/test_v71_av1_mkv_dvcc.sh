#!/usr/bin/env bash
# v71 — dvcC de container pe hibridele AV1 DV → MKV (extensie v70 la AV1). mkvmerge
# scrie "DOVI configuration record" si din AV1 (.ivf, NU doar HEVC), pastrand RPU +
# HDR10+. AV1+MP4/MOV acoperit in v72 (MP4Box dvp= explicit) — vezi test_v72_av1_mp4_dvcc.
#   Source-level (mereu): gating-ul ungateat (encode triple-layer + _hdv_combine + av_mux),
#   gate-ul AV1 pe _mux_dv_mp4. Functional (cand exista AV1 DV sample + ffmpeg + mkvmerge):
#   AV1 DV IVF → _hdv_combine_with_original REAL → MKV → assert dvcC + RPU.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"
COMMON="$(cat "$SCRIPT_DIR/av_common.sh")"
HDV="$(cat "$SCRIPT_DIR/av_hdr_dv_tools.sh")"
MUX="$(cat "$SCRIPT_DIR/av_mux.sh")"

# ── 1. encode triple-layer: ramura mkv ungateata (HEVC + AV1) ─────────────
assert_contains "$COMMON" '"$CONTAINER" == "mkv" ]] && _mux_dv_mkv "$injected_temp" "$output" "$final_temp"' "triple-layer: mkv ungateat (HEVC+AV1)"
# AV1 MP4 → MP4Box dvp= (v72, branch mp4 ungateat); HEVC MKV fara mkvmerge → elif cu pas MP4
assert_contains "$COMMON" 'elif [[ "$_tl_codec" != "av1" && "$CONTAINER" == "mkv" ]]; then' "triple-layer: HEVC MKV fallback (pas MP4) gardat pe non-av1"

# ── 2. _hdv_combine: ramura AV1 IVF (MKV + MP4/MOV in v72) ─────────────────
assert_contains "$HDV" '"$_mod_ext" == "ivf" ]]; then' "_hdv_combine: ramura AV1 IVF"
assert_contains "$HDV" '"$_oe" == "mkv"' "_hdv_combine: AV1 IVF → MKV (sub-ramura mkvmerge)"

# ── 3. _mux_dv_mp4 gate: AV1 acum ACCEPTAT cu dvp= (v72; inainte respins) ──
assert_contains "$COMMON" 'ivf|av1|obu)   _is_av1=1 ;;' "_mux_dv_mp4: AV1 acceptat (v72)"

# ── 4. av_mux: capturile AV1 pe MKV (.av1 OBU in raw-wrap + .ivf separat) ──
assert_contains "$MUX" '"$_vext" == "av1"' "av_mux: captura .av1 OBU pe MKV"
assert_contains "$MUX" '"$TARGET" == "mkv" && "${video##*.}" == "ivf"' "av_mux: captura .ivf pe MKV"

# ── 5. av_hdr_dv_tools are guard de test (paritate standalone) ─────────────
assert_contains "$HDV" 'AV_HDR_DV_TEST_MODE' "av_hdr_dv_tools: guard de test"

# ── 6. FUNCTIONAL — AV1 DV IVF → _hdv_combine REAL → MKV → dvcC ────────────
MKVM="${AV_TOOL_MKVMERGE:-mkvmerge}"
AV1DOVI="${AV_TOOL_AV1DOVI:-av1dovi_tool}"
AV1_SAMPLE=""
for c in "$SCRIPT_DIR"/Upload_*DV*AV1.mkv "$SCRIPT_DIR"/*DV*AV1*.mkv; do [ -f "$c" ] && { AV1_SAMPLE="$c"; break; }; done
if [ -n "$AV1_SAMPLE" ] && command -v ffmpeg >/dev/null 2>&1 && command -v "$MKVM" >/dev/null 2>&1 \
   && command -v "$AV1DOVI" >/dev/null 2>&1; then
    TD="$(mktemp -d)"
    # extrage video AV1 (cu RPU DV) ca IVF din sample-ul real
    ffmpeg -v error -y -t 2 -i "$AV1_SAMPLE" -map 0:v:0 -c:v copy -f ivf "$TD/v.ivf" 2>/dev/null
    rpu_before=$("$AV1DOVI" extract-rpu -i "$TD/v.ivf" -o "$TD/rb.bin" >/dev/null 2>&1 && [ -s "$TD/rb.bin" ] && echo 1 || echo 0)
    if [ "$rpu_before" = "1" ]; then
        ( export AV_HDR_DV_TEST_MODE=1; CONTAINER=mkv
          source "$SCRIPT_DIR/av_common.sh" 2>/dev/null
          source "$SCRIPT_DIR/av_hdr_dv_tools.sh" 2>/dev/null
          _hdv_combine_with_original "$TD/v.ivf" "$AV1_SAMPLE" "$TD/out.mkv" )
        dvcc=$(ffprobe -v error -select_streams v:0 -show_entries stream_side_data=side_data_type -of default=noprint_wrappers=1:nokey=1 "$TD/out.mkv" 2>/dev/null | grep -ci "DOVI" || true)
        assert_eq "1" "$dvcc" "functional: AV1 DV IVF → _hdv_combine → MKV cu dvcC"
        ffmpeg -v error -y -i "$TD/out.mkv" -map 0:v:0 -c copy -f ivf "$TD/back.ivf" 2>/dev/null
        rpu_after=$("$AV1DOVI" extract-rpu -i "$TD/back.ivf" -o "$TD/ra.bin" >/dev/null 2>&1 && [ -s "$TD/ra.bin" ] && echo 1 || echo 0)
        assert_eq "1" "$rpu_after" "functional: DV RPU supravietuieste in MKV"
    else
        echo "  (functional sarit: sample fara RPU AV1 extractibil)" >&2
    fi
    rm -rf "$TD"
else
    echo "  (functional sarit: AV1 DV sample / ffmpeg / mkvmerge / av1dovi_tool lipsesc)" >&2
fi
