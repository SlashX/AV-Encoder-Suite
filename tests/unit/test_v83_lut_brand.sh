#!/usr/bin/env bash
# v83 — LUT brand-aware ordering. find_lut_for_brand (bash) / Find-LutForBrand +
#   Get-BurninLutFiles (PS1) recunosc NUME REALE (AppleLog*/Samsung*Log*/*D-LogM*)
#   pe langa prefixul conventional (apple_log_*) → LUT-urile brandului ies PRIMELE
#   (default = pozitia 1), restul dupa; lista COMPLETA ramane (manual = orice LUT).
#   Hermetic (fake .cube, fara ffmpeg).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"

# Luts temp cu numele REALE (fara continut — doar globbing conteaza)
tmpd="$(mktemp -d)"
mkdir -p "$tmpd/Luts"
: > "$tmpd/Luts/AppleLogToRec709-v1.0.cube"
: > "$tmpd/Luts/AppleLog2ToRec709-v1.0.cube"
: > "$tmpd/Luts/DJI OSMO Action 6 D-LogM to Rec.709 LUT-11.17.cube"
: > "$tmpd/Luts/Samsung+Log+to+Rec709+3DLUT_v1.0.cube"
: > "$tmpd/Luts/MyCreativeFilm.cube"
trap 'rm -rf "$tmpd"; _test_summary' EXIT

source "$SCRIPT_DIR/av_common.sh" >/dev/null 2>&1
LUTS_DIR="$tmpd/Luts"

# ── apple: 2 LUT-uri Apple primele (nume real, fara prefix apple_log_) ──
find_lut_for_brand apple >/dev/null 2>&1 || true
assert_eq "2" "$LUT_BRAND_COUNT"          "apple: 2 LUT-uri brand-matched (nume reale)"
assert_eq "5" "${#LUT_FILES[@]}"          "apple: lista COMPLETA pastrata (manual = orice LUT)"
assert_match "$(basename "${LUT_FILES[0]}")" "^Apple" "apple: [0] e un LUT Apple (default)"
assert_match "$(basename "${LUT_FILES[1]}")" "^Apple" "apple: [1] e un LUT Apple"

# ── dji: LUT-ul DJI (D-LogM) primul ──
find_lut_for_brand dji >/dev/null 2>&1 || true
assert_eq "1" "$LUT_BRAND_COUNT"          "dji: 1 brand-matched (D-LogM)"
assert_match "$(basename "${LUT_FILES[0]}")" "^DJI" "dji: [0] e LUT-ul DJI"

# ── samsung: LUT-ul Samsung primul ──
find_lut_for_brand samsung >/dev/null 2>&1 || true
assert_eq "1" "$LUT_BRAND_COUNT"          "samsung: 1 brand-matched"
assert_match "$(basename "${LUT_FILES[0]}")" "^Samsung" "samsung: [0] e LUT-ul Samsung"

# ── unknown: fara reorder, toate prezente (fallback v62) ──
find_lut_for_brand unknown >/dev/null 2>&1 || true
assert_eq "0" "$LUT_BRAND_COUNT"          "unknown: 0 brand-matched"
assert_eq "5" "${#LUT_FILES[@]}"          "unknown: toate .cube prezente"

# ── source-level: marker in dialog + LUT_BRAND_COUNT + paritate PS1 ──
BSH="$(cat "$SCRIPT_DIR/av_common.sh")"
BPS_ENC="$(cat "$SCRIPT_DIR/av_encode.ps1")"
BPS_BURN="$(cat "$SCRIPT_DIR/av_burnin.ps1")"
assert_contains "$BSH" "LUT_BRAND_COUNT"          "bash: LUT_BRAND_COUNT expus"
assert_contains "$BSH" "potrivit brand"           "bash: marker brand in dialogul LUT"
assert_contains "$BPS_ENC" "brandCount"           "PS1 enc: brandCount in Find-LutForBrand"
assert_contains "$BPS_ENC" "potrivit brand"       "PS1 enc: marker brand in Show-LogDialog"
assert_contains "$BPS_ENC" "apple.*log"           "PS1 enc: pattern nume real apple"
assert_contains "$BPS_BURN" "apple.*log"          "PS1 burn: Get-BurninLutFiles pattern real (fix fallback)"
