#!/usr/bin/env bash
# Test v46 features:
# - show_hdr_hw_dialog: _can_hw_preserve gate for DV (HEVC/AV1 target + tools)
# - hw_dispatch_sdr: hw_preserve mode sets TRIPLE_LAYER state
# - HW_HDR_POLICY schema includes hw_preserve
# - MediaCodec dialog: hw_preserve option mirror
# - Encoder integration markers (x265/av1 hw_preserve branches)

source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
source "$SCRIPT_DIR/av_common.sh"

# ─────────────────────────────────────────────────────────────────────
# 1) Schema enum: HW_HDR_POLICY si MEDIACODEC_HDR_POLICY au hw_preserve
# ─────────────────────────────────────────────────────────────────────
schema_hw=$(profile_schema_get "HW_HDR_POLICY")
assert_contains "$schema_hw" "hw_preserve" "HW_HDR_POLICY schema contains hw_preserve"

schema_mc=$(profile_schema_get "MEDIACODEC_HDR_POLICY")
assert_contains "$schema_mc" "hw_preserve" "MEDIACODEC_HDR_POLICY schema contains hw_preserve"

# Validare profil cu hw_preserve valid
_test_prof=$(mktemp)
echo 'HW_HDR_POLICY="hw_preserve"' > "$_test_prof"
validate_profile "$_test_prof" >/dev/null 2>&1
assert_zero $? "HW_HDR_POLICY=hw_preserve valid"

echo 'MEDIACODEC_HDR_POLICY="hw_preserve"' > "$_test_prof"
validate_profile "$_test_prof" >/dev/null 2>&1
assert_zero $? "MEDIACODEC_HDR_POLICY=hw_preserve valid"
rm -f "$_test_prof"

# ─────────────────────────────────────────────────────────────────────
# 2) show_hdr_hw_dialog signature accepts enc_codec + src_codec
# ─────────────────────────────────────────────────────────────────────
sig_line=$(grep -E '^show_hdr_hw_dialog\(\)' -A 2 "$SCRIPT_DIR/av_common.sh" | head -3)
assert_contains "$sig_line" "enc_codec" "show_hdr_hw_dialog signature has enc_codec"
assert_contains "$sig_line" "src_codec" "show_hdr_hw_dialog signature has src_codec"

# ─────────────────────────────────────────────────────────────────────
# 3) _can_hw_preserve gate: false when target codec not hevc/av1
# ─────────────────────────────────────────────────────────────────────
# Mock tools as available
_check_dovi_tool_for() { return 0; }
export -f _check_dovi_tool_for

# Policy bypass for testing — h264 target should NOT enable hw_preserve
HW_HDR_POLICY="hw_preserve"
HW_HDR_MODE=""
show_hdr_hw_dialog "nvenc" "dv" "5" "h264" "hevc" >/dev/null 2>&1
# h264 target → _can_hw_preserve=0 → fallback to hw_hdr10
assert_eq "hw_hdr10" "$HW_HDR_MODE" "h264 target: hw_preserve falls back to hw_hdr10"

# HEVC target + both tools available → hw_preserve OK
HW_HDR_MODE=""
show_hdr_hw_dialog "nvenc" "dv" "5" "hevc" "hevc" >/dev/null 2>&1
assert_eq "hw_preserve" "$HW_HDR_MODE" "hevc target + tools: hw_preserve enabled"

# AV1 target + tools → OK
HW_HDR_MODE=""
show_hdr_hw_dialog "nvenc" "dv" "10" "av1" "hevc" >/dev/null 2>&1
assert_eq "hw_preserve" "$HW_HDR_MODE" "av1 target + tools: hw_preserve enabled"

# Tool missing → fallback
_check_dovi_tool_for() { return 1; }
export -f _check_dovi_tool_for
HW_HDR_MODE=""
show_hdr_hw_dialog "nvenc" "dv" "5" "hevc" "hevc" >/dev/null 2>&1
assert_eq "hw_hdr10" "$HW_HDR_MODE" "tool missing: hw_preserve falls back to hw_hdr10"

# Reset
unset HW_HDR_POLICY
unset -f _check_dovi_tool_for
# Restore real function (sourced from av_common.sh already)
source "$SCRIPT_DIR/av_common.sh" >/dev/null 2>&1

# ─────────────────────────────────────────────────────────────────────
# 4) hw_dispatch_sdr: hw_preserve branch sets TRIPLE_LAYER state
# ─────────────────────────────────────────────────────────────────────
# Verify branch presence via source inspection
grep -q 'hw_preserve)' "$SCRIPT_DIR/av_common.sh" \
    && _pass || _fail "hw_dispatch_sdr has hw_preserve case"
grep -q 'TRIPLE_LAYER_MODE=1' "$SCRIPT_DIR/av_common.sh" \
    && _pass || _fail "hw_preserve sets TRIPLE_LAYER_MODE=1"
grep -q 'TRIPLE_LAYER_TARGET_CODEC="$enc_codec"' "$SCRIPT_DIR/av_common.sh" \
    && _pass || _fail "hw_preserve sets TRIPLE_LAYER_TARGET_CODEC=enc_codec"

# ─────────────────────────────────────────────────────────────────────
# 5) MediaCodec dialog mirror: hw_preserve option + gate
# ─────────────────────────────────────────────────────────────────────
grep -q 'MC_HDR_MODE="hw_preserve"' "$SCRIPT_DIR/av_common.sh" \
    && _pass || _fail "show_hdr_mediacodec_dialog has MC_HDR_MODE=hw_preserve"
grep -q 'v46 MC DV preserve' "$SCRIPT_DIR/av_encoder_x265.sh" \
    && _pass || _fail "x265 has v46 MC DV preserve handler"
grep -q 'v46 MC DV preserve' "$SCRIPT_DIR/av_encoder_av1.sh" \
    && _pass || _fail "av1 has v46 MC DV preserve handler"

# ─────────────────────────────────────────────────────────────────────
# 6) MediaCodec hw_preserve case sets MC_NEEDS_REPAIR for SEI inject
# ─────────────────────────────────────────────────────────────────────
grep -q 'MC_NEEDS_REPAIR=1' "$SCRIPT_DIR/av_encoder_x265.sh" \
    && _pass || _fail "x265 MC hw_preserve sets MC_NEEDS_REPAIR"
grep -q 'MC_NEEDS_REPAIR=1' "$SCRIPT_DIR/av_encoder_av1.sh" \
    && _pass || _fail "av1 MC hw_preserve sets MC_NEEDS_REPAIR"

# ─────────────────────────────────────────────────────────────────────
# 7) hw_dispatch_sdr passes enc_codec + src_codec to dialog
# ─────────────────────────────────────────────────────────────────────
grep -q 'show_hdr_hw_dialog "$HW_BACKEND" "$src_type" "$dv_p" "$enc_codec" "$src_codec"' "$SCRIPT_DIR/av_common.sh" \
    && _pass || _fail "hw_dispatch_sdr passes all 5 args to show_hdr_hw_dialog"
grep -q 'src_codec=$(detect_source_codec "$file" 2>/dev/null)' "$SCRIPT_DIR/av_common.sh" \
    && _pass || _fail "hw_dispatch_sdr detects source codec"
