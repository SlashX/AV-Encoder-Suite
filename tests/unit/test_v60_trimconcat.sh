#!/usr/bin/env bash
# v60: av_trimconcat HDR/LOG awareness — labels, classifier, reset, builder, env policy.
# Encoder-ele oferite la trim/concat sunt libx265/libx264 (NU svtav1).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"

# av_trimconcat sourceaza av_common intern; test mode skip meniu interactiv.
export AV_TRIMCONCAT_TEST_MODE=1
# shellcheck source=/dev/null
if ! source "$SCRIPT_DIR/av_trimconcat.sh" 2>/dev/null; then
    skip_test "av_trimconcat.sh source failed (lipsa av_common deps)"
fi

# ── 1. Helpers exista ──────────────────────────────────────────────
assert_eq "function" "$(type -t _tc_mode_label)"      "_tc_mode_label exista"
assert_eq "function" "$(type -t _tc_classify_source)" "_tc_classify_source exista"
assert_eq "function" "$(type -t _tc_reset_hdr_state)" "_tc_reset_hdr_state exista"
assert_eq "function" "$(type -t show_tc_hdr_dialog)"  "show_tc_hdr_dialog exista"
assert_eq "function" "$(type -t build_tc_video_args)" "build_tc_video_args exista"

# ── 2. _tc_mode_label ──────────────────────────────────────────────
assert_eq "SDR (no transform)"           "$(_tc_mode_label sdr)"            "label sdr"
assert_eq "Preserve HDR10"               "$(_tc_mode_label preserve_hdr10)" "label preserve_hdr10"
assert_eq "Preserve HLG"                 "$(_tc_mode_label preserve_hlg)"   "label preserve_hlg"
assert_eq "Tonemap → SDR"                "$(_tc_mode_label tonemap)"        "label tonemap"
assert_eq "Apply LUT (LOG → Rec.709)"    "$(_tc_mode_label lut_rec709)"     "label lut_rec709"
assert_eq "Keep LOG (no color transform)" "$(_tc_mode_label keep_log)"      "label keep_log"
assert_eq "Skip"                         "$(_tc_mode_label skip)"           "label skip"

# ── 3. _tc_classify_source — per state ─────────────────────────────
DOVI=""; HDR_PLUS=""; HDR_TYPE=""; IS_HLG=0; LOG_PROFILE=""
_tc_classify_source
assert_eq "sdr" "$TC_SOURCE_TYPE" "classify: defaults → sdr"

DOVI="dvhe"; _tc_classify_source
assert_eq "dv" "$TC_SOURCE_TYPE" "classify: DOVI set → dv"

DOVI=""; HDR_PLUS="found HDR10+"; _tc_classify_source
assert_eq "hdr10plus" "$TC_SOURCE_TYPE" "classify: HDR_PLUS → hdr10plus"

HDR_PLUS=""; HDR_TYPE="smpte2084"; _tc_classify_source
assert_eq "hdr10" "$TC_SOURCE_TYPE" "classify: smpte2084 → hdr10"

HDR_TYPE=""; IS_HLG=1; _tc_classify_source
assert_eq "hlg" "$TC_SOURCE_TYPE" "classify: IS_HLG=1 → hlg"

IS_HLG=0; LOG_PROFILE="apple_log"; _tc_classify_source
assert_eq "log" "$TC_SOURCE_TYPE" "classify: LOG_PROFILE → log"

# DV priority peste tot
DOVI="dvhe"; HDR_PLUS="HDR10+"; HDR_TYPE="smpte2084"; IS_HLG=1; LOG_PROFILE="apple_log"
_tc_classify_source
assert_eq "dv" "$TC_SOURCE_TYPE" "classify: DV priority cand toate active"

# HDR10+ priority peste HDR10
DOVI=""; HDR_PLUS="HDR10+"; HDR_TYPE="smpte2084"
_tc_classify_source
assert_eq "hdr10plus" "$TC_SOURCE_TYPE" "classify: HDR10+ priority over HDR10"

DOVI=""; HDR_PLUS=""; HDR_TYPE=""; IS_HLG=0; LOG_PROFILE=""

# ── 4. _tc_reset_hdr_state ─────────────────────────────────────────
TC_SOURCE_TYPE="dv"; TC_MODE="tonemap"; TC_VF_PREPEND="x"
TC_ENC_EXTRA_ARGS=("a" "b"); TC_LUT_FILE="y"; TC_DOWNGRADE_REASON="w"
_tc_reset_hdr_state
assert_eq "sdr" "$TC_SOURCE_TYPE" "reset: SOURCE_TYPE → sdr"
assert_eq "sdr" "$TC_MODE"        "reset: MODE → sdr"
assert_eq ""    "$TC_VF_PREPEND"  "reset: VF_PREPEND → empty"
assert_eq "0"   "${#TC_ENC_EXTRA_ARGS[@]}" "reset: ENC_EXTRA_ARGS → []"
assert_eq ""    "$TC_LUT_FILE"    "reset: LUT_FILE → empty"
assert_eq ""    "$TC_DOWNGRADE_REASON" "reset: DOWNGRADE_REASON → empty"

# ── 5. build_tc_video_args — skip → return 1 ──────────────────────
_tc_reset_hdr_state
TC_MODE="skip"
if build_tc_video_args /tmp/fake.mkv libx265; then
    assert_eq "skip should return 1" "actual=0" "build skip → exit 1"
else
    assert_eq "0" "0" "build skip → exit 1 (OK)"
fi

# ── 6. sdr / keep_log → return 0, no args ─────────────────────────
_tc_reset_hdr_state; TC_MODE="sdr"
if build_tc_video_args /tmp/fake.mkv libx265; then
    assert_eq "" "$TC_VF_PREPEND" "sdr → no vf"
    assert_eq "0" "${#TC_ENC_EXTRA_ARGS[@]}" "sdr → no extra args"
else
    assert_eq "sdr should return 0" "actual=1" "build sdr"
fi
_tc_reset_hdr_state; TC_MODE="keep_log"
if build_tc_video_args /tmp/fake.mkv libx265; then
    assert_eq "" "$TC_VF_PREPEND" "keep_log → no vf (fara transform)"
else
    assert_eq "keep_log should return 0" "actual=1" "build keep_log"
fi

# ── 7. tonemap → TC_VF_PREPEND zscale + tonemap ───────────────────
_tc_reset_hdr_state; TC_MODE="tonemap"
build_tc_video_args /tmp/fake.mkv libx265
assert_contains "$TC_VF_PREPEND" "zscale=transfer=linear" "tonemap: zscale linearization"
assert_contains "$TC_VF_PREPEND" "tonemap=hable"          "tonemap: Hable"
assert_contains "$TC_VF_PREPEND" "format=yuv420p"         "tonemap: final format yuv420p"

# ── 8. lut_rec709 → TC_VF_PREPEND lut3d= ──────────────────────────
_tc_reset_hdr_state; TC_MODE="lut_rec709"; TC_LUT_FILE="/tmp/test_lut.cube"
build_tc_video_args /tmp/fake.mkv libx265
assert_contains "$TC_VF_PREPEND" "lut3d=" "lut_rec709: filter contine lut3d="

# ── 9. preserve_hdr10 + libx265 → 10-bit + x265-params ────────────
_tc_reset_hdr_state; TC_MODE="preserve_hdr10"
# Mock hdr10_static_resolve (nu lovim ffprobe pe fake file)
hdr10_static_resolve() {
    HDR10_STATIC_AVAILABLE=1
    HDR10_MASTER_DISPLAY_X265="G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,1)"
    HDR10_MAX_CLL="1000,400"
}
build_tc_video_args /tmp/fake.mkv libx265
ARGS_STR="${TC_ENC_EXTRA_ARGS[*]}"
assert_contains "$ARGS_STR" "yuv420p10le"      "preserve_hdr10 x265: pix_fmt 10-bit"
assert_contains "$ARGS_STR" "bt2020"           "preserve_hdr10 x265: bt2020"
assert_contains "$ARGS_STR" "smpte2084"        "preserve_hdr10 x265: smpte2084"
assert_contains "$ARGS_STR" "-x265-params"     "preserve_hdr10 x265: x265-params flag"
assert_contains "$ARGS_STR" "hdr10=1"          "preserve_hdr10 x265: hdr10=1"
assert_contains "$ARGS_STR" "master-display="  "preserve_hdr10 x265: master-display inject"
assert_contains "$ARGS_STR" "max-cll=1000,400" "preserve_hdr10 x265: max-cll inject"

# ── 10. preserve_hdr10 + libx264 → fallback tonemap ───────────────
_tc_reset_hdr_state; TC_MODE="preserve_hdr10"
build_tc_video_args /tmp/fake.mkv libx264
assert_contains "$TC_VF_PREPEND" "tonemap=hable" "preserve_hdr10 x264: auto-tonemap"
assert_contains "$TC_DOWNGRADE_REASON" "libx264" "preserve_hdr10 x264: downgrade reason"
assert_eq "0" "${#TC_ENC_EXTRA_ARGS[@]}" "preserve_hdr10 x264: NO 10-bit args"

# ── 11. preserve_hlg + libx265 → arib-std-b67, NO hdr10=1 ─────────
_tc_reset_hdr_state; TC_MODE="preserve_hlg"
build_tc_video_args /tmp/fake.mkv libx265
ARGS_STR="${TC_ENC_EXTRA_ARGS[*]}"
assert_contains "$ARGS_STR" "arib-std-b67" "preserve_hlg x265: transfer arib-std-b67"
assert_contains "$ARGS_STR" "-x265-params" "preserve_hlg x265: x265-params flag"
case "$ARGS_STR" in
    *hdr10=1*) assert_eq "HLG nu trebuie hdr10=1" "contine hdr10=1" "preserve_hlg: NO hdr10=1" ;;
    *)         assert_eq "0" "0" "preserve_hlg: NO hdr10=1 (OK)" ;;
esac

# ── 12. preserve_hlg + libx264 → fallback tonemap ─────────────────
_tc_reset_hdr_state; TC_MODE="preserve_hlg"
build_tc_video_args /tmp/fake.mkv libx264
assert_contains "$TC_VF_PREPEND" "tonemap=hable" "preserve_hlg x264: auto-tonemap"
assert_contains "$TC_DOWNGRADE_REASON" "libx264" "preserve_hlg x264: downgrade reason"

# ── 13. TC_HDR_POLICY env bypass ──────────────────────────────────
detect_source_info() { :; }  # mock (nu citim ffprobe pe fake file)

# preserve + hdr10 → preserve_hdr10
DOVI=""; HDR_PLUS=""; HDR_TYPE="smpte2084"; IS_HLG=0; LOG_PROFILE=""
TC_HDR_POLICY="preserve" show_tc_hdr_dialog /tmp/fake.mkv libx265
assert_eq "preserve_hdr10" "$TC_MODE" "policy=preserve + hdr10 → preserve_hdr10"

# preserve + hlg → preserve_hlg
DOVI=""; HDR_PLUS=""; HDR_TYPE=""; IS_HLG=1; LOG_PROFILE=""
TC_HDR_POLICY="preserve" show_tc_hdr_dialog /tmp/fake.mkv libx265
assert_eq "preserve_hlg" "$TC_MODE" "policy=preserve + hlg → preserve_hlg"

# preserve + dv → skip (re-encode nu pastreaza RPU)
DOVI="dvhe"; HDR_PLUS=""; HDR_TYPE=""; IS_HLG=0; LOG_PROFILE=""
TC_HDR_POLICY="preserve" show_tc_hdr_dialog /tmp/fake.mkv libx265
assert_eq "skip" "$TC_MODE" "policy=preserve + dv → skip"

# preserve + log → keep_log
DOVI=""; HDR_PLUS=""; HDR_TYPE=""; IS_HLG=0; LOG_PROFILE="apple_log"
TC_HDR_POLICY="preserve" show_tc_hdr_dialog /tmp/fake.mkv libx265
assert_eq "keep_log" "$TC_MODE" "policy=preserve + log → keep_log"

# tonemap policy
DOVI=""; HDR_PLUS=""; HDR_TYPE="smpte2084"; IS_HLG=0; LOG_PROFILE=""
TC_HDR_POLICY="tonemap" show_tc_hdr_dialog /tmp/fake.mkv libx265
assert_eq "tonemap" "$TC_MODE" "policy=tonemap → tonemap"

# skip policy
TC_HDR_POLICY="skip" show_tc_hdr_dialog /tmp/fake.mkv libx265
assert_eq "skip" "$TC_MODE" "policy=skip → skip"

# sdr source → no dialog, ramane sdr chiar cu policy
DOVI=""; HDR_PLUS=""; HDR_TYPE=""; IS_HLG=0; LOG_PROFILE=""
TC_HDR_POLICY="preserve" show_tc_hdr_dialog /tmp/fake.mkv libx265
assert_eq "sdr" "$TC_MODE" "sursa sdr → ramane sdr (no transform)"

# ── 14. Integrare: fluxurile apeleaza show_tc_hdr_dialog + build ──
TC_SRC="$SCRIPT_DIR/av_trimconcat.sh"
# show_tc_hdr_dialog apelat in trim + batch + concat (definitie + >=3 call-site)
_n=$(grep -c 'show_tc_hdr_dialog' "$TC_SRC")
assert_match "$_n" "^([4-9]|[1-9][0-9])$" "show_tc_hdr_dialog: definitie + >=3 call-site"
if grep -q 'build_tc_video_args' "$TC_SRC"; then
    assert_eq "0" "0" "build_tc_video_args integrat in fluxuri"
else
    assert_eq "integrat" "lipsa" "build_tc_video_args integrat in fluxuri"
fi

# ── 15. v60 audit FIX: detect_pipeline_hdr_mode foloseste side_data_type ──
# Regresie: `frame=side_data_list` pe primul frame rata DV AV1 + HDR10+ pe surse reale.
_dpm=$(declare -f detect_pipeline_hdr_mode)
assert_contains "$_dpm" "side_data_type"        "detect_pipeline_hdr_mode: side_data_type (NU list)"
assert_contains "$_dpm" "Dolby Vision Metadata" "detect_pipeline_hdr_mode: DV AV1 via side_data"
case "$_dpm" in
    *"frame=side_data_list"*) assert_eq "fara side_data_list" "are side_data_list" "detect_pipeline_hdr_mode NU mai foloseste side_data_list" ;;
    *)                        assert_eq "0" "0" "detect_pipeline_hdr_mode fara side_data_list (OK)" ;;
esac

# ── 16. v60 audit: colon-guard pe inline injection (dhdr10-info / hdr10plus-json) ──
assert_contains "$(cat "$TC_SRC")" 'incompatibil cu x265-params' "colon-guard x265 dhdr10-info"
assert_contains "$(cat "$TC_SRC")" 'incompatibil cu svtav1-params' "colon-guard svtav1 hdr10plus-json"
