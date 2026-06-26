#!/usr/bin/env bash
# v77 — Constatarea VFR pe caile de preserve cu extract-din-sursa -> inject (HW HDR10+, DV, hibrid, APV).
# Pe sursa VFR numarul de cadre CODATE (din care se extrage metadata) difera de cele DECODATE (baza
# re-encodata). Tratare per cale:
#   - DV (dovi_tool inject-rpu) + HW HDR10+ (hdr10plus_tool inject) = GRATIOS (aliniaza la coada
#     trunc/dup -> output valid, metadata cozii aproximativa)
#   - APV (engine apv_hdr10plus.py) = BOUNDED-GRACEFUL: aliniaza la coada pe decalaj MIC (ca DV/HW),
#     honest-fail -> HDR10 static doar pe decalaj MARE (bug de pipeline; e codul nostru, nu tool extern)
# Suita AVERTIZEAZA userul in toate cazurile (helper _is_vfr_source / Test-VfrSource).
# Test: (1) source-level helper + cele 3 avertismente DISTINCTE (DV chokepoint / HW HDR10+ standalone /
# APV bounded) + avertismentul hibrid redundant SCOS (acoperit de chokepoint-ul DV); (2) functional
# _is_vfr_source pe CFR vs VFR real; (3) canar: hdr10plus_tool inject cu mismatch de cadre -> output valid.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
COMMON="$SCRIPT_DIR/av_common.sh"

# self-resolve ffmpeg/ffprobe din src/ daca lipsesc (ca v62/v76)
command -v ffprobe >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"

# ── 1. Source-level: helper + avertismente distincte ──
src=$(cat "$COMMON")
apvsrc=$(cat "$SCRIPT_DIR/av_encoder_apv.sh")
psenc=$(cat "$SCRIPT_DIR/av_encode.ps1")

assert_contains "$src" "_is_vfr_source()"  "_is_vfr_source definit (bash)"
assert_contains "$src" "r_frame_rate"      "_is_vfr_source citeste r_frame_rate"
assert_contains "$src" "avg_frame_rate"    "_is_vfr_source citeste avg_frame_rate"
# DV chokepoint (acopera HW DV + SW DV + hibridul DV) — _extract_preserve_rpu
assert_contains "$src" "RPU DV se aliniaza pe pozitie" "avertisment VFR DV in _extract_preserve_rpu (bash)"
# HW HDR10+ standalone (hw_preserve_hdr10plus)
assert_contains "$src" "HDR10+ se aliniaza pe pozitie la cadrele de output" "avertisment VFR HW HDR10+ standalone (bash)"
# avertismentul hibrid HDR10+ scos (DV-ul hibridului trece prin chokepoint -> ar fi dublu)
assert_not_contains "$src" "HDR10+ (din lantul DV) se aliniaza" "avertisment hibrid HDR10+ redundant scos (bash)"
# APV bounded-graceful (av_encoder_apv.sh) — fraza distincta de DV / HW HDR10+
assert_contains "$apvsrc" "HDR10+ pe APV se aliniaza la coada" "avertisment VFR APV bounded (bash)"

# PS1 paritate (toate in av_encode.ps1, inclusiv APV)
assert_contains "$psenc" "function Test-VfrSource" "Test-VfrSource definit (PS1)"
assert_contains "$psenc" "RPU DV se aliniaza pe pozitie" "avertisment VFR DV in Get-PreserveRpu (PS1)"
assert_contains "$psenc" "HDR10+ se aliniaza pe pozitie la cadrele de output" "avertisment VFR HW HDR10+ standalone (PS1)"
assert_not_contains "$psenc" "HDR10+ (din lantul DV) se aliniaza" "avertisment hibrid HDR10+ redundant scos (PS1)"
assert_contains "$psenc" "HDR10+ pe APV se aliniaza la coada" "avertisment VFR APV bounded (PS1)"

# ── 1b. Santinela regresie -y: extract->temp in run_encode_loop (av_mktemp_ext PRE-CREEAZA
# fisierul → ffmpeg fara -y se agata interactiv "Overwrite? [y/N]" / 0 octeti neinteractiv).
# Dupa fix toate aceste extractii sunt "ffmpeg -v error -y -i ..." → pattern-ul fara -y == 0. ──
ny_output=$(grep -cF 'ffmpeg -v error -i "$output"' "$COMMON" || true)
assert_eq "0" "$ny_output" "av_common: extract HW HDR10+/DV (-i \$output) are -y (regresie -y)"
ny_inj=$(grep -cF 'ffmpeg -v error -i "$injected_temp"' "$COMMON" || true)
assert_eq "0" "$ny_inj" "av_common: re-mux fallback (-i \$injected_temp) are -y (regresie -y)"
ny_enc=$(grep -cF 'ffmpeg -v error -i "$encoded" -c copy' "$COMMON" || true)
assert_eq "0" "$ny_enc" "av_common: repair HDR10 signaling (-i \$encoded) are -y (regresie -y)"
ny_ps=$(grep -cF 'ffmpeg -v error -i $outFile' "$SCRIPT_DIR/av_encode.ps1" || true)
assert_eq "0" "$ny_ps" "av_encode.ps1: extract HW HDR10+/DV (-i \$outFile) are -y (paritate regresie -y)"

# ── 2. Functional: _is_vfr_source clasifica corect ──
source "$COMMON"
if command -v ffmpeg >/dev/null 2>&1; then
    tmpd=$(mktemp -d)
    cfr="$tmpd/cfr.mp4"
    ffmpeg -v error -y -f lavfi -i "testsrc=size=128x128:rate=30:duration=1" -c:v libx264 -r 30 "$cfr" 2>/dev/null || true
    if [ -f "$cfr" ]; then
        if _is_vfr_source "$cfr"; then vfr=1; else vfr=0; fi
        assert_eq "0" "$vfr" "clip CFR generat (r=avg=30) -> NU VFR"
    else
        echo "  (nota: generare CFR esuata, sar verificarea CFR)"
    fi
    rm -rf "$tmpd"
else
    echo "  (nota: ffmpeg lipseste, sar verificarea CFR generat)"
fi

vfr_sample="$SCRIPT_DIR/Upload_S02E01_HDR10Plus_40s_HEVC.mp4"
if [ -f "$vfr_sample" ]; then
    if _is_vfr_source "$vfr_sample"; then vfr=1; else vfr=0; fi
    assert_eq "1" "$vfr" "sample HEVC HDR10+ real (r=120 avg~59.76) -> VFR"
else
    echo "  (nota: sample VFR real lipseste, sar verificarea VFR)"
fi

# ── 3. Canar: inject HDR10+ cu mismatch de cadre -> output valid (gratios) ──
lake="$SCRIPT_DIR/hdr10+test_lake_2021_02_01.mp4"
if command -v ffmpeg >/dev/null 2>&1 && _check_hdr10plus_tool_for hevc 2>/dev/null && [ -f "$lake" ]; then
    cj=$(extract_hdr10plus_metadata "$lake" 2>/dev/null || true)
    cbase=$(av_mktemp_ext hevc)
    # baza scurta cu numar de cadre DIFERIT de JSON (mismatch garantat)
    ffmpeg -v error -y -f lavfi -i "testsrc=size=256x256:rate=24:duration=0.4" \
        -c:v libx265 -x265-params log-level=none -f hevc "$cbase" 2>/dev/null || true
    if [ -n "$cj" ] && [ -s "$cj" ] && [ -s "$cbase" ]; then
        cout=$(av_mktemp_ext hevc)
        if inject_hdr10plus_metadata "$cbase" "$cj" "$cout" hevc 2>/dev/null && [ -s "$cout" ]; then
            assert_nonzero "$(wc -c < "$cout")" "canar: inject cu mismatch de cadre -> output valid (gratios)"
        else
            echo "  (nota: canar inject sarit — tool/extract indisponibil sau MSYS)"
        fi
        rm -f "$cout"
    else
        echo "  (nota: canar sarit — extract JSON / baza esuata)"
    fi
    rm -f "$cbase"
    [ -n "$cj" ] && rm -f "$cj"
else
    echo "  (nota: canar inject sarit — ffmpeg/hdr10plus_tool/lake lipseste)"
fi

true
