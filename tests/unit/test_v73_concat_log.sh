#!/usr/bin/env bash
# v73: Concat LOG awareness. detect_pipeline_hdr_mode NU clasifica LOG (cade pe sdr) →
#   pana acum LOG la Concat re-encode trecea TACUT ca sdr (fara LUT, fara nota, culoare
#   mis-tagged). Acum: detect_concat_log_mode (agregat N→1, autoritar via detect_source_info
#   in subshell) + hook pe ramura sdr din trimconcat_flow_concat → LUT Rec.709 / Keep LOG / Skip.
#   Test determinist prin mock (fara ffprobe/python) + verificare conexiune la build_tc_video_args.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
TC="$SCRIPT_DIR/av_trimconcat.sh"

export AV_TRIMCONCAT_TEST_MODE=1
# shellcheck source=/dev/null
if ! source "$TC" 2>/dev/null; then
    skip_test "av_trimconcat.sh source failed (lipsa av_common deps)"
fi
TCSRC=$(cat "$TC")

# ── 1. Helper definit + hook in Concat (ramura sdr), NU in Pipeline ──
assert_eq "function" "$(type -t detect_concat_log_mode)" "detect_concat_log_mode definit"
assert_contains "$TCSRC" '_log_agg=$(detect_concat_log_mode' "concat: hook LOG pe agregat sdr"
assert_contains "$TCSRC" 'detect_pipeline_hdr_mode nu clasifica LOG' "concat: comentariu hook v73"

# ── 2. Agregare N→1 (mock detect_source_info + find_lut_for_brand → determinist) ──
detect_source_info() {
    case "$1" in
        *_dlogdji*) LOG_PROFILE="dlog_m"; CAMERA_MAKE="dji" ;;
        *_logsam*)  LOG_PROFILE="samsung_log"; CAMERA_MAKE="samsung" ;;
        *)          LOG_PROFILE=""; CAMERA_MAKE="" ;;
    esac
}
LUT_PRESENT=0
find_lut_for_brand() {
    if [[ "$LUT_PRESENT" == "1" ]]; then LUT_FILES=("/fake/${1}_rec709.cube"); return 0
    else LUT_FILES=(); return 1; fi
}

assert_eq "none"    "$(detect_concat_log_mode a_sdr.mp4 b_sdr.mp4)"          "agregat: 0 surse LOG → none"
LUT_PRESENT=0
assert_eq "keep"    "$(detect_concat_log_mode a_dlogdji.mp4 b_dlogdji.mp4)" "agregat: LOG dji fara LUT → keep"
LUT_PRESENT=1
assert_eq "lut:dji" "$(detect_concat_log_mode a_dlogdji.mp4 b_dlogdji.mp4)" "agregat: LOG dji + LUT → lut:dji"
assert_eq "keep"    "$(detect_concat_log_mode a_dlogdji.mp4 b_logsam.mp4)"  "agregat: branduri mixte → keep"
assert_eq "keep"    "$(detect_concat_log_mode a_dlogdji.mp4 b_sdr.mp4)"     "agregat: LOG+SDR mixt → keep"

# ── 3. Modurile setate de dialog → build_tc_video_args produce args corecte ──
# (lut_rec709 = lut3d + setparams [repara mis-tag-ul masurat bt709→smpte170m]; keep_log = no-transform)
_tc_reset_hdr_state
TC_MODE="lut_rec709"; TC_LUT_FILE="/fake/dji.cube"
build_tc_video_args "x.mp4" "libx265" >/dev/null 2>&1
assert_contains "$TC_VF_PREPEND" "lut3d"     "lut_rec709 → lut3d in TC_VF_PREPEND"
assert_contains "$TC_VF_PREPEND" "setparams" "lut_rec709 → setparams (repara mis-tag culoare)"
_tc_reset_hdr_state
TC_MODE="keep_log"
build_tc_video_args "x.mp4" "libx265" >/dev/null 2>&1
assert_eq "" "$TC_VF_PREPEND" "keep_log → fara transform (prepend gol)"
