#!/usr/bin/env bash
# v77 — MATRICE METADATA: golurile fata de v75 (hibrid → HDR10+ / hibrid → DV) prin
# FUNCTIILE REALE ale suitei (remove_dv_layer / remove_hdr10plus_metadata + verify_*).
#   hibrid (DV + HDR10+) → HDR10+ : remove DV, pastreaza HDR10+
#   hibrid (DV + HDR10+) → DV      : remove HDR10+, pastreaza DV
# × HEVC (sintetizat din HDR10+ via generate_dv_rpu_from_hdr10plus) + AV1 (sample real).
# Completeaza test_v75_metadata_matrix (HDR10+→HDR10+, DV→DV, HDR10+→hibrid, transform).
# Auto-skip fara unelte/sample.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
export PATH="$SCRIPT_DIR:$PATH"
export AV_COMMON_TEST_MODE=1 2>/dev/null || true
source "$SCRIPT_DIR/av_common.sh" 2>/dev/null

for t in ffmpeg ffprobe dovi_tool hdr10plus_tool av1dovi_tool av1hdr10plus_tool; do
    command -v "$t" >/dev/null 2>&1 || skip_test "unealta lipsa: $t"
done
S_HEVC_HP="$SCRIPT_DIR/hdr10+test_lake_2021_02_01.mp4"   # HEVC HDR10+ CFR
S_AV1_HYB="$SCRIPT_DIR/Upload_S02E01_DV_HDR10Plus_40s_AV1.mkv"  # AV1 hibrid real
[ -f "$S_HEVC_HP" ]  || skip_test "sample HEVC HDR10+ lipsa"
[ -f "$S_AV1_HYB" ]  || skip_test "sample AV1 hibrid lipsa"

W="$(mktemp -d)"; export AV_TEMP_DIR="$W"
trap 'rm -rf "$W"; _test_summary' EXIT
_present() { if "$@" >/dev/null 2>&1; then echo 1; else echo 0; fi; }

# ── Construieste raw hibrid (DV + HDR10+) per codec ──
# HEVC: sintetizat din HDR10+ (extract → generate DV RPU → inject) — ca v75 GRUP C.
hevc_hyb="$W/hevc_hyb.hevc"
hevc_raw="$W/hevc_src.hevc"
if extract_raw_video "$S_HEVC_HP" "$hevc_raw" hevc; then
    hpj=$(extract_hdr10plus_metadata "$S_HEVC_HP" 2>/dev/null)
    if [ -n "$hpj" ] && [ -s "$hpj" ]; then
        rpu=$(generate_dv_rpu_from_hdr10plus "$hpj" hevc "$S_HEVC_HP" 2>/dev/null)
        if [ -n "$rpu" ] && [ -s "$rpu" ]; then
            inject_dv_rpu "$hevc_raw" "$rpu" "$hevc_hyb" hevc >/dev/null 2>&1 || true
        fi
    fi
fi
# AV1: din sample-ul hibrid real (extract raw IVF)
av1_hyb="$W/av1_hyb.ivf"
extract_raw_video "$S_AV1_HYB" "$av1_hyb" av1 >/dev/null 2>&1 || true

run_codec() {
    local codec="$1" hyb="$2" ext="$3"
    if [ ! -s "$hyb" ]; then echo "  (nota: hibrid $codec indisponibil, sar)"; return; fi
    # premisa: hibridul ARE si DV si HDR10+
    assert_eq "1" "$(_present verify_dv_survived "$hyb" "$codec")"  "$codec hibrid: are DV (premisa)"
    assert_eq "1" "$(_present verify_hdr10plus "$hyb" "$codec")"    "$codec hibrid: are HDR10+ (premisa)"

    # ── hibrid → HDR10+ (remove DV, pastreaza HDR10+) ──
    local nodv="$W/${codec}_nodv.$ext"
    if remove_dv_layer "$hyb" "$nodv" "$codec"; then
        assert_eq "1" "$(_present verify_hdr10plus "$nodv" "$codec")"   "$codec hibrid→HDR10+: HDR10+ PASTRAT dupa remove DV"
        assert_eq "0" "$(_present verify_dv_survived "$nodv" "$codec")"  "$codec hibrid→HDR10+: DV ELIMINAT"
    else
        assert_eq "ok" "fail" "$codec hibrid→HDR10+: remove_dv_layer esuat"
    fi

    # ── hibrid → DV (remove HDR10+, pastreaza DV) ──
    local nohp="$W/${codec}_nohp.$ext"
    if remove_hdr10plus_metadata "$hyb" "$nohp" "$codec"; then
        assert_eq "1" "$(_present verify_dv_survived "$nohp" "$codec")"  "$codec hibrid→DV: DV PASTRAT dupa remove HDR10+"
        assert_eq "0" "$(_present verify_hdr10plus "$nohp" "$codec")"    "$codec hibrid→DV: HDR10+ ELIMINAT"
    else
        assert_eq "ok" "fail" "$codec hibrid→DV: remove_hdr10plus_metadata esuat"
    fi
}

echo "────────── HEVC hibrid → HDR10+ / DV ──────────"
run_codec hevc "$hevc_hyb" hevc
echo "────────── AV1 hibrid → HDR10+ / DV ──────────"
run_codec av1 "$av1_hyb" ivf
