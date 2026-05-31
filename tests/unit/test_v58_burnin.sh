#!/usr/bin/env bash
# v58: av_burnin HDR awareness — dialog, classifier, video chain builder, integration
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"

# ── Source av_burnin.sh in test mode (skip main menu) ───────────────
export AV_BURNIN_TEST_MODE=1
# av_burnin depinde de av_common.sh sa fie sourced (face source intern)
# OUTPUT_DIR/INPUT_DIR sunt setate de av_common.sh prin SCRIPT_DIR-relative paths
# shellcheck source=/dev/null
if ! source "$SCRIPT_DIR/av_burnin.sh" 2>/dev/null; then
    skip_test "av_burnin.sh source failed (lipsa ffmpeg sau av_common deps)"
fi

# ── 1. Helpers exista ──────────────────────────────────────────────
assert_eq "function" "$(type -t _burnin_mode_label)"       "_burnin_mode_label exista"
assert_eq "function" "$(type -t _burnin_classify_source)"  "_burnin_classify_source exista"
assert_eq "function" "$(type -t _burnin_reset_state)"      "_burnin_reset_state exista"
assert_eq "function" "$(type -t show_burnin_hdr_dialog)"   "show_burnin_hdr_dialog exista"
assert_eq "function" "$(type -t build_burnin_video_chain)" "build_burnin_video_chain exista"

# ── 2. _burnin_mode_label ──────────────────────────────────────────
assert_eq "SDR (no transform)"        "$(_burnin_mode_label sdr)"              "label sdr"
assert_eq "Preserve HDR10"            "$(_burnin_mode_label preserve_hdr10)"   "label preserve_hdr10"
assert_eq "Preserve HDR10+"           "$(_burnin_mode_label preserve_hdr10plus)" "label preserve_hdr10plus"
assert_eq "Preserve HLG"              "$(_burnin_mode_label preserve_hlg)"     "label preserve_hlg"
assert_eq "Tonemap → SDR"             "$(_burnin_mode_label tonemap)"          "label tonemap"
assert_eq "Apply LUT (LOG → Rec.709)" "$(_burnin_mode_label lut_rec709)"       "label lut_rec709"
assert_eq "Burn-in raw (no color transform)" "$(_burnin_mode_label burnin_raw)" "label burnin_raw"
assert_eq "Skip"                      "$(_burnin_mode_label skip)"             "label skip"

# ── 3. _burnin_classify_source — clasificare per state ─────────────
DOVI=""; HDR_PLUS=""; HDR_TYPE=""; IS_HLG=0; LOG_PROFILE=""
_burnin_classify_source
assert_eq "sdr" "$BURNIN_SOURCE_TYPE" "classify: defaults → sdr"

DOVI="dvhe"; _burnin_classify_source
assert_eq "dv" "$BURNIN_SOURCE_TYPE" "classify: DOVI set → dv"

DOVI=""; HDR_PLUS="found HDR10+"; _burnin_classify_source
assert_eq "hdr10plus" "$BURNIN_SOURCE_TYPE" "classify: HDR_PLUS set → hdr10plus"

HDR_PLUS=""; HDR_TYPE="smpte2084"; _burnin_classify_source
assert_eq "hdr10" "$BURNIN_SOURCE_TYPE" "classify: smpte2084 → hdr10"

HDR_TYPE=""; IS_HLG=1; _burnin_classify_source
assert_eq "hlg" "$BURNIN_SOURCE_TYPE" "classify: IS_HLG=1 → hlg"

IS_HLG=0; LOG_PROFILE="apple_log"; _burnin_classify_source
assert_eq "log" "$BURNIN_SOURCE_TYPE" "classify: LOG_PROFILE → log"

# DV priority over everything
DOVI="dvhe"; HDR_PLUS="HDR10+"; HDR_TYPE="smpte2084"; IS_HLG=1; LOG_PROFILE="apple_log"
_burnin_classify_source
assert_eq "dv" "$BURNIN_SOURCE_TYPE" "classify: DV priority cand toate active"

# HDR10+ priority over HDR10
DOVI=""; HDR_PLUS="HDR10+"; HDR_TYPE="smpte2084"
_burnin_classify_source
assert_eq "hdr10plus" "$BURNIN_SOURCE_TYPE" "classify: HDR10+ priority over HDR10"

# Reset
DOVI=""; HDR_PLUS=""; HDR_TYPE=""; IS_HLG=0; LOG_PROFILE=""

# ── 4. _burnin_reset_state — toate state vars la default ──────────
BURNIN_SOURCE_TYPE="dv"; BURNIN_MODE="tonemap"; BURNIN_PRE_FILTER="x"
BURNIN_ENC_EXTRA_ARGS=("a" "b"); BURNIN_LUT_FILE="y"; BURNIN_HDR10PLUS_JSON="z"
BURNIN_DOWNGRADE_REASON="w"
_burnin_reset_state
assert_eq "sdr" "$BURNIN_SOURCE_TYPE" "reset: SOURCE_TYPE → sdr"
assert_eq "sdr" "$BURNIN_MODE"        "reset: MODE → sdr"
assert_eq ""    "$BURNIN_PRE_FILTER"  "reset: PRE_FILTER → empty"
assert_eq "0"   "${#BURNIN_ENC_EXTRA_ARGS[@]}" "reset: ENC_EXTRA_ARGS → []"
assert_eq ""    "$BURNIN_LUT_FILE"    "reset: LUT_FILE → empty"
assert_eq ""    "$BURNIN_HDR10PLUS_JSON" "reset: HDR10PLUS_JSON → empty"
assert_eq ""    "$BURNIN_DOWNGRADE_REASON" "reset: DOWNGRADE_REASON → empty"

# ── 5. build_burnin_video_chain — mode = skip → return 1 ──────────
ENC_NAME="libx265"
BURNIN_MODE="skip"
if build_burnin_video_chain /tmp/fake.mkv; then
    assert_eq "skip should return 1" "actual=0" "build_burnin_video_chain skip → exit 1"
else
    assert_eq "0" "0" "build_burnin_video_chain skip → exit 1 (OK)"
fi

# ── 6. mode = sdr → return 0, no args ─────────────────────────────
_burnin_reset_state
BURNIN_MODE="sdr"
if build_burnin_video_chain /tmp/fake.mkv; then
    assert_eq "" "$BURNIN_PRE_FILTER" "sdr → no pre_filter"
    assert_eq "0" "${#BURNIN_ENC_EXTRA_ARGS[@]}" "sdr → no extra args"
else
    assert_eq "sdr should return 0" "actual=1" "build_burnin_video_chain sdr"
fi

# ── 7. mode = tonemap → BURNIN_PRE_FILTER contine zscale + tonemap ─
_burnin_reset_state
BURNIN_MODE="tonemap"
build_burnin_video_chain /tmp/fake.mkv
assert_contains "$BURNIN_PRE_FILTER" "zscale=transfer=linear" "tonemap: zscale linearization"
assert_contains "$BURNIN_PRE_FILTER" "tonemap=hable"          "tonemap: Hable"
assert_contains "$BURNIN_PRE_FILTER" "format=yuv420p"         "tonemap: final format yuv420p"

# ── 8. mode = lut_rec709 → BURNIN_PRE_FILTER = lut3d=... ──────────
_burnin_reset_state
BURNIN_MODE="lut_rec709"
BURNIN_LUT_FILE="/tmp/test_lut.cube"
build_burnin_video_chain /tmp/fake.mkv
assert_contains "$BURNIN_PRE_FILTER" "lut3d=" "lut_rec709: filter contine lut3d="

# ── 9. mode = preserve_hdr10 + libx265 → 10-bit + x265-params ─────
_burnin_reset_state
ENC_NAME="libx265"
BURNIN_MODE="preserve_hdr10"
# Mock hdr10_static_resolve sa nu loveasca ffprobe pe file inexistent
hdr10_static_resolve() {
    HDR10_STATIC_AVAILABLE=1
    HDR10_MASTER_DISPLAY_X265="G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,1)"
    HDR10_MASTER_DISPLAY_SVTAV1="G(0.1700,0.7970)B(0.1310,0.0460)R(0.7080,0.2920)WP(0.3127,0.3290)L(1000.0000,0.0001)"
    HDR10_MAX_CLL="1000,400"
    HDR10_STATIC_SOURCE="probe"
}
build_burnin_video_chain /tmp/fake.mkv
# Check args
ARGS_STR="${BURNIN_ENC_EXTRA_ARGS[*]}"
assert_contains "$ARGS_STR" "yuv420p10le"        "preserve_hdr10 x265: pix_fmt 10-bit"
assert_contains "$ARGS_STR" "bt2020"             "preserve_hdr10 x265: color_primaries bt2020"
assert_contains "$ARGS_STR" "smpte2084"          "preserve_hdr10 x265: color_trc smpte2084"
assert_contains "$ARGS_STR" "-x265-params"       "preserve_hdr10 x265: x265-params flag"
assert_contains "$ARGS_STR" "hdr10=1"            "preserve_hdr10 x265: hdr10=1"
assert_contains "$ARGS_STR" "master-display="    "preserve_hdr10 x265: master-display inject"
assert_contains "$ARGS_STR" "max-cll=1000,400"   "preserve_hdr10 x265: max-cll inject"

# ── 10. mode = preserve_hdr10 + libsvtav1 → svtav1-params ─────────
_burnin_reset_state
ENC_NAME="libsvtav1"
BURNIN_MODE="preserve_hdr10"
build_burnin_video_chain /tmp/fake.mkv
ARGS_STR="${BURNIN_ENC_EXTRA_ARGS[*]}"
assert_contains "$ARGS_STR" "yuv420p10le"     "preserve_hdr10 svtav1: pix_fmt 10-bit"
assert_contains "$ARGS_STR" "-svtav1-params"  "preserve_hdr10 svtav1: svtav1-params flag"
assert_contains "$ARGS_STR" "enable-hdr=1"    "preserve_hdr10 svtav1: enable-hdr=1"
assert_contains "$ARGS_STR" "mastering-display=" "preserve_hdr10 svtav1: mastering-display inject"
assert_contains "$ARGS_STR" "content-light="  "preserve_hdr10 svtav1: content-light inject"

# ── 11. mode = preserve_hdr10 + libx264 → fallback la tonemap ─────
_burnin_reset_state
ENC_NAME="libx264"
BURNIN_MODE="preserve_hdr10"
build_burnin_video_chain /tmp/fake.mkv
assert_contains "$BURNIN_PRE_FILTER" "tonemap=hable" "preserve_hdr10 x264: auto-tonemap"
assert_contains "$BURNIN_DOWNGRADE_REASON" "libx264" "preserve_hdr10 x264: downgrade reason setat"

# ── 12. mode = preserve_hlg + libx265 → arib-std-b67 ───────────────
_burnin_reset_state
ENC_NAME="libx265"
BURNIN_MODE="preserve_hlg"
build_burnin_video_chain /tmp/fake.mkv
ARGS_STR="${BURNIN_ENC_EXTRA_ARGS[*]}"
assert_contains "$ARGS_STR" "arib-std-b67" "preserve_hlg x265: transfer arib-std-b67"
assert_contains "$ARGS_STR" "-x265-params" "preserve_hlg x265: x265-params flag"
# Verifica ca NU contine hdr10=1 (HLG e diferit)
case "$ARGS_STR" in
    *hdr10=1*) assert_eq "HLG nu trebuie sa aibă hdr10=1" "actual contine hdr10=1" "preserve_hlg: NO hdr10=1" ;;
    *)         assert_eq "0" "0" "preserve_hlg: NO hdr10=1 (OK)" ;;
esac

# ── 13. mode = preserve_hlg + libsvtav1 → svtav1-params HLG ───────
_burnin_reset_state
ENC_NAME="libsvtav1"
BURNIN_MODE="preserve_hlg"
build_burnin_video_chain /tmp/fake.mkv
ARGS_STR="${BURNIN_ENC_EXTRA_ARGS[*]}"
assert_contains "$ARGS_STR" "transfer-characteristics=18" "preserve_hlg svtav1: HLG transfer (18)"
assert_contains "$ARGS_STR" "color-primaries=9"           "preserve_hlg svtav1: BT.2020 (9)"

# ── 14. BURNIN_HDR_POLICY env override ─────────────────────────────
# preserve policy on HDR10
DOVI=""; HDR_PLUS=""; HDR_TYPE="smpte2084"; IS_HLG=0; LOG_PROFILE=""
BURNIN_HDR_POLICY="preserve"
detect_source_info() { :; }  # mock detect (nu citim ffprobe pe fake file)
show_burnin_hdr_dialog /tmp/fake.mkv
assert_eq "preserve_hdr10" "$BURNIN_MODE" "policy=preserve + hdr10 → preserve_hdr10"

# tonemap policy on HLG
DOVI=""; HDR_PLUS=""; HDR_TYPE=""; IS_HLG=1; LOG_PROFILE=""
BURNIN_HDR_POLICY="tonemap"
show_burnin_hdr_dialog /tmp/fake.mkv
assert_eq "tonemap" "$BURNIN_MODE" "policy=tonemap + hlg → tonemap"

# skip policy on DV
DOVI="dvhe"; HDR_PLUS=""; HDR_TYPE=""; IS_HLG=0; LOG_PROFILE=""
BURNIN_HDR_POLICY="skip"
show_burnin_hdr_dialog /tmp/fake.mkv
assert_eq "skip" "$BURNIN_MODE" "policy=skip + dv → skip"

# preserve policy on DV → skip (DV preserve incompatibil)
DOVI="dvhe"; BURNIN_HDR_POLICY="preserve"
show_burnin_hdr_dialog /tmp/fake.mkv
assert_eq "skip" "$BURNIN_MODE" "policy=preserve + dv → skip (RPU break)"

unset BURNIN_HDR_POLICY

# ── 15. Integrare: flow loops cheama show_burnin_hdr_dialog ────────
BURNIN_TXT=$(cat "$SCRIPT_DIR/av_burnin.sh")
DLG_COUNT=$(grep -c 'show_burnin_hdr_dialog "\$vid"' "$SCRIPT_DIR/av_burnin.sh")
assert_eq "4" "$DLG_COUNT" "show_burnin_hdr_dialog apelata in 4 flow-uri (HUD/SRT/ASS/img)"
BLD_COUNT=$(grep -c 'build_burnin_video_chain "\$vid"' "$SCRIPT_DIR/av_burnin.sh")
assert_eq "4" "$BLD_COUNT" "build_burnin_video_chain apelata in 4 flow-uri"

# Verifica ca BURNIN_ENC_EXTRA_ARGS e injectat in toate 5 ffmpeg sites
EXTRA_USES=$(grep -c '"\${BURNIN_ENC_EXTRA_ARGS\[@\]}"' "$SCRIPT_DIR/av_burnin.sh")
assert_eq "5" "$EXTRA_USES" "BURNIN_ENC_EXTRA_ARGS injectat in 5 ffmpeg sites (HUD/SRT/ASS + img ext + img emb)"

# DV refuse text
assert_contains "$BURNIN_TXT" "Dolby Vision detectata" "Mesaj DV refuse prezent"
assert_contains "$BURNIN_TXT" "RPU references"        "DV refuse explica RPU breakage"
assert_contains "$BURNIN_TXT" "av_hdr_dv_tools"       "DV refuse sugereaza av_hdr_dv_tools"

echo "✓ Toate testele bash v58 burnin trecute"
