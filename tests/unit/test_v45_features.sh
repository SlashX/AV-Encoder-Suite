#!/usr/bin/env bash
# Test v45 features:
# - handle_hdr10plus_dialog: source-codec gate (P3 fix)
# - hdv_flow_hdr10plus_to_dv: function presence + early validation (P2)
# - DV preserve in x265: integration markers TRIPLE_LAYER_MODE + TRIPLE_LAYER_TARGET_CODEC

source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
source "$SCRIPT_DIR/av_common.sh"
# av_hdr_dv_tools.sh ruleaza menu la nivelul top → testam doar prin grep pe sursa

# ─────────────────────────────────────────────────────────────────────
# 1) P3 — handle_hdr10plus_dialog uses source-codec for extract gate
# ─────────────────────────────────────────────────────────────────────
# Setup: mock detect_source_codec → "av1"; HEVC tool present, AV1 absent.
# With v45 fix, gate should hit the "tool missing" branch (av1hdr10plus_tool).
# With old v44 behavior, gate would pass (hdr10plus_tool found) and proceed.

_mock_src_codec="av1"
detect_source_codec() { echo "$_mock_src_codec"; }
export -f detect_source_codec

HDR10PLUS_TOOL_AVAILABLE=1
AV1_HDR10PLUS_TOOL_AVAILABLE=0
DOVI_TOOL_AVAILABLE=1
AV1_DOVI_TOOL_AVAILABLE=0

# Capture dialog output, feed "1" (default fallback branch when tool missing)
dialog_out=$(handle_hdr10plus_dialog "/fake/file.mp4" "hevc" <<< "1" 2>&1)
assert_contains "$dialog_out" "av1hdr10plus_tool" "P3: missing-tool branch names source-codec tool"
assert_contains "$dialog_out" "necesar pt sursa av1" "P3: message mentions source codec"

# Reverse: source=hevc, HEVC tool absent, AV1 tool present → should still gate on source
_mock_src_codec="hevc"
HDR10PLUS_TOOL_AVAILABLE=0
AV1_HDR10PLUS_TOOL_AVAILABLE=1
dialog_out=$(handle_hdr10plus_dialog "/fake/file.mp4" "av1" <<< "1" 2>&1)
assert_contains "$dialog_out" "hdr10plus_tool" "P3: hevc source needs hdr10plus_tool"
assert_contains "$dialog_out" "necesar pt sursa hevc" "P3: message mentions hevc source"

# ─────────────────────────────────────────────────────────────────────
# 2) P2 — hdv_flow_hdr10plus_to_dv prezent in av_hdr_dv_tools.sh
# ─────────────────────────────────────────────────────────────────────
grep -q '^hdv_flow_hdr10plus_to_dv()' "$SCRIPT_DIR/av_hdr_dv_tools.sh" \
    && _pass || _fail "hdv_flow_hdr10plus_to_dv defined in av_hdr_dv_tools.sh"
grep -q 'HDR10+ → DV hybrid' "$SCRIPT_DIR/av_hdr_dv_tools.sh" \
    && _pass || _fail "menu has HDR10+ → DV hybrid entry"
# v49: renumerotat la opt 3 dupa scoaterea Remux container
grep -q '3) hdv_flow_hdr10plus_to_dv' "$SCRIPT_DIR/av_hdr_dv_tools.sh" \
    && _pass || _fail "menu dispatch wires opt 3 to hdv_flow_hdr10plus_to_dv (v49 renumerotare)"

# ─────────────────────────────────────────────────────────────────────
# 3) Helpers folosite de P1 (DV preserve x265) si P2 (HDR10+ → DV hybrid)
# Functii existente — verificam ca sunt accessible din pipeline.
# ─────────────────────────────────────────────────────────────────────
declare -F extract_dv_rpu                  >/dev/null && _pass || _fail "extract_dv_rpu defined"
declare -F generate_dv_rpu_from_hdr10plus  >/dev/null && _pass || _fail "generate_dv_rpu_from_hdr10plus defined"
declare -F extract_hdr10plus_metadata      >/dev/null && _pass || _fail "extract_hdr10plus_metadata defined"
declare -F extract_raw_video               >/dev/null && _pass || _fail "extract_raw_video defined"
declare -F inject_dv_rpu                   >/dev/null && _pass || _fail "inject_dv_rpu defined"

# ─────────────────────────────────────────────────────────────────────
# 4) P1 markers — verifica ca x265 encoder are referinte la TRIPLE_LAYER
#    (sursa de adevar pentru integration: post-encode handler in run_encode_loop)
# ─────────────────────────────────────────────────────────────────────
grep -q 'TRIPLE_LAYER_TARGET_CODEC="hevc"' "$SCRIPT_DIR/av_encoder_x265.sh" \
    && _pass || _fail "x265 sets TRIPLE_LAYER_TARGET_CODEC=hevc in DV preserve branch"
grep -q 'DV preserve' "$SCRIPT_DIR/av_encoder_x265.sh" \
    && _pass || _fail "x265 has DV preserve dialog text"

# ─────────────────────────────────────────────────────────────────────
# 5) Audit fix — handle_hdr10plus_dialog skip-if-DV-preserved
#    DOVI+HDR10+ co-existence: dialog NU trebuie sa overwrite DOVI_RPU_FILE
#    cu RPU sintetizat din JSON cand DV preserve a setat deja state-ul.
# ─────────────────────────────────────────────────────────────────────
TRIPLE_LAYER_MODE=1
DOVI_RPU_FILE="/fake/already/extracted/rpu.bin"

# Re-define detect_source_codec si _check_hdr10plus_tool_for ca sa controlam path-ul
_mock_src_codec="hevc"
detect_source_codec() { echo "$_mock_src_codec"; }
export -f detect_source_codec
HDR10PLUS_TOOL_AVAILABLE=0  # forteaza ramura "tool indisponibil"

# Capture log/output — dialog NU trebuie sa apara (auto-skip)
dialog_out=$(handle_hdr10plus_dialog "/fake/file.mp4" "hevc" 2>&1)
assert_contains "$dialog_out" "DV preserve" "Auto-skip path detected when TRIPLE_LAYER + DOVI_RPU set"
assert_eq "/fake/already/extracted/rpu.bin" "$DOVI_RPU_FILE" "DOVI_RPU_FILE NOT overwritten by skip path"

# Cu tool disponibil, dialog inca trebuie sa fie skipped (auto-extract)
TRIPLE_LAYER_MODE=1
DOVI_RPU_FILE="/fake/already/extracted/rpu.bin"
HDR10PLUS_TOOL_AVAILABLE=1
# Mock extract_hdr10plus_metadata sa returneze gol (simulam ca extract esueaza)
extract_hdr10plus_metadata() { return 1; }
export -f extract_hdr10plus_metadata
dialog_out=$(handle_hdr10plus_dialog "/fake/file.mp4" "hevc" 2>&1)
assert_contains "$dialog_out" "DV preserve" "Auto-skip path even with tool available"
assert_eq "/fake/already/extracted/rpu.bin" "$DOVI_RPU_FILE" "DOVI_RPU_FILE preserved when auto-extract fails"

# Reset
TRIPLE_LAYER_MODE=0
DOVI_RPU_FILE=""
unset -f extract_hdr10plus_metadata

# ─────────────────────────────────────────────────────────────────────
# 6) DOVI_PRESERVE_POLICY — schema + dialog bypass markers
# ─────────────────────────────────────────────────────────────────────
schema=$(profile_schema_get "DOVI_PRESERVE_POLICY")
assert_eq "enum:,auto,preserve,convert,copy,skip" "$schema" "DOVI_PRESERVE_POLICY schema enum"

# Validare profil cu DOVI_PRESERVE_POLICY valid
_test_prof=$(mktemp)
echo 'DOVI_PRESERVE_POLICY="preserve"' > "$_test_prof"
validate_profile "$_test_prof" >/dev/null 2>&1
assert_zero $? "DOVI_PRESERVE_POLICY=preserve valid"

echo 'DOVI_PRESERVE_POLICY="bogus"' > "$_test_prof"
validate_profile "$_test_prof" >/dev/null 2>&1
assert_nonzero $? "DOVI_PRESERVE_POLICY=bogus rejected"
rm -f "$_test_prof"

# Dialog bypass markers in encoders
grep -q 'DOVI_PRESERVE_POLICY' "$SCRIPT_DIR/av_encoder_x265.sh" \
    && _pass || _fail "x265 honors DOVI_PRESERVE_POLICY"
grep -q 'DOVI_PRESERVE_POLICY' "$SCRIPT_DIR/av_encoder_av1.sh" \
    && _pass || _fail "av1 honors DOVI_PRESERVE_POLICY"
