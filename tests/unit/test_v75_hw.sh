#!/usr/bin/env bash
# v75 — HW encode audit (bash): gating AV1 Intel (QSV/VAAPI: prezenta-encoder → model GPU),
#   preset direction VAAPI/VideoToolbox (era inversat). Source-level (paritate) + hermetic
#   pe _intel_gpu_has_av1_encode (functie pura, fara hardware).
#   NVENC/AMF/VAAPI/VT/MediaCodec = netestabile functional aici (lipsa hardware fizic) →
#   caveat audit; preset direction VAAPI/VT validate pe Linux/Mac real.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"

COMMON="$(cat "$SCRIPT_DIR/av_common.sh")"

# ── 1. Source-level: gating AV1 pe model (nu doar prezenta encoderului in -encoders) ──
assert_contains "$COMMON" '_intel_gpu_has_av1_encode()'                  "helper _intel_gpu_has_av1_encode definit"
assert_contains "$COMMON" '_intel_gpu_has_av1_encode "$QSV_GPU_MODEL"'   "QSV AV1 gateat pe model GPU"
assert_contains "$COMMON" '_intel_gpu_has_av1_encode "$VAAPI_GPU_MODEL"' "VAAPI AV1 gateat pe model GPU"

# ── 2. Source-level: preset direction corectata (era inversa fata de slot) ──
assert_contains "$COMMON" 'vaapi_q=$((8 - slot))'        "VAAPI -quality inversat (iHD: 1=best..7=fast)"
assert_contains "$COMMON" 'vt_q=(50 55 60 65 70 75 80)'  "VideoToolbox q:v inversat (mai mare=mai bun)"

# ── 3. Hermetic: _intel_gpu_has_av1_encode (functie pura, fara hardware) ──
eval "$(awk '/^_intel_gpu_has_av1_encode\(\)/{f=1} f; f&&/^}/{exit}' "$SCRIPT_DIR/av_common.sh")"
if declare -f _intel_gpu_has_av1_encode >/dev/null 2>&1; then
    _t() { if _intel_gpu_has_av1_encode "$1"; then echo 1; else echo 0; fi; }
    assert_eq "1" "$(_t 'Intel Arc A770')"                         "Arc A770 -> AV1 capabil"
    assert_eq "1" "$(_t 'Meteor Lake-P [Intel Arc Graphics]')"     "Meteor Lake (Arc Graphics) -> AV1 capabil"
    assert_eq "1" "$(_t 'Lunar Lake-M [Intel Arc Graphics 140V]')" "Lunar Lake -> AV1 capabil"
    assert_eq "0" "$(_t 'Intel UHD Graphics')"                     "UHD Graphics -> NU AV1 (bug confirmat empiric)"
    assert_eq "0" "$(_t 'Raptor Lake-S GT1 [UHD Graphics 770]')"   "Raptor Lake UHD -> NU AV1"
    assert_eq "0" "$(_t '')"                                       "model gol -> NU AV1 (fallback SW sigur)"
    assert_eq "0" "$(_t 'Advanced Micro Devices Radeon RX 6600')"  "AMD -> NU (helper Intel-only)"
else
    echo "  (hermetic sarit - extractia functiei a esuat)"
fi

# ── 4. v75 mobile (S24 Ultra real): MediaCodec whitelist prinde vendor "QTI" + ro.hardware ──
# ro.soc.manufacturer = "QTI" (Qualcomm Technologies Inc) pe SM8650 (8 Gen 3), NU "Qualcomm"/"qcom"
# -> whitelist-ul vechi rata flagship-ul (HEVC10/AV1 ramaneau 0). Fix: + qti + ro.hardware=qcom.
assert_contains "$COMMON" 'qti'                         "MediaCodec whitelist prinde vendor QTI (S24 Ultra real)"
assert_contains "$COMMON" 'hw_lc=$(getprop ro.hardware' "MediaCodec consulta ro.hardware (=qcom) ca semnal Qualcomm"

# ── 5. v75 mobile (A54 Exynos 1380 real): codename s5e + AV1 SW-fallback awareness ──
# ro.soc.model raporteaza CODENAME-ul s5e (A54 = s5e8835), NU "exynos2100" (marketing)
# -> matchul vechi pe "exynos2xxx" era cod mort pe device-uri reale. Adaug flagship s5e9(8[4-9]|9[0-9])x.
assert_contains "$COMMON" 's5e9(8[4-9]|9[0-9])[0-9]' "Exynos flagship via codename s5e (A54 a dovedit formatul)"
# Hermetic: regex-ul s5e prinde flagship 2100+/exclude vechi+mid (functie pura, fara hardware)
_s5e() { if [[ "$1" =~ s5e9(8[4-9]|9[0-9])[0-9] ]]; then echo 1; else echo 0; fi; }
assert_eq "1" "$(_s5e 's5e9840')" "s5e9840 (Exynos 2100) -> HEVC10"
assert_eq "1" "$(_s5e 's5e9925')" "s5e9925 (Exynos 2200) -> HEVC10"
assert_eq "1" "$(_s5e 's5e9945')" "s5e9945 (Exynos 2400) -> HEVC10"
assert_eq "0" "$(_s5e 's5e8835')" "s5e8835 (A54 mid-range) -> NU (verificat empiric real)"
assert_eq "0" "$(_s5e 's5e9830')" "s5e9830 (Exynos 990 vechi) -> NU (sub 2100)"

# ── 6. v75 mobile: MediaCodec 8-bit input only (cleanup pix_fmt yuv420p10le -> yuv420p) ──
# Encoderele mediacodec ffmpeg accepta DOAR mediacodec/yuv420p/nv12 (validat S24U+A54);
# 10-bit auto-downconverteaza -> nu mai cerem yuv420p10le inselator (pastram main10 = signaling).
assert_contains "$COMMON" 'accepta DOAR 8-bit input' "MediaCodec 8-bit input documentat in build_mediacodec_cmd"
# Forward-compat: probe input 10-bit din "-h encoder" → p010le automat cand ffmpeg il adauga
assert_contains "$COMMON" '_mc_encoder_supports_10bit'  "helper probe 10-bit input definit (forward-compat)"
assert_contains "$COMMON" 'MC_INPUT_10BIT=1'            "MC_INPUT_10BIT setat din probe in detect_mediacodec_caps"
assert_contains "$COMMON" 'pix_fmt="p010le"'           "build_mediacodec cere p010le cand MC_INPUT_10BIT=1 (ffmpeg viitor)"

# ── 7. v75 mobile: AV1 HW encode NU se revendica pe niciun SoC (infirmat S24U + A54) ──
# Euristica "model SoC → AV1 encode" e nesigura; AV1 encode HW pe mobil e cvasi-inexistent
# (8 Gen 3 = doar c2.qti.av1.DECODER; av1_mediacodec = c2.android SW libaom). Gard-ul
# av_encoder_av1.sh cade pe libsvtav1 cand MC_CAP_AV1=0 (mai bun decat libaom-MediaCodec).
# MC_CAP_AV1=1 trebuie sa apara in COD o SINGURA data: doar din probe-ul /vendor HW,
# ZERO din whitelist-ul pe model SoC (cele 4 claim-uri Snapdragon/Exynos/Tensor/Dimensity scoase)
_cap_av1_code=$(printf '%s\n' "$COMMON" | grep -E 'MC_CAP_AV1=1' | grep -cvE '^[[:space:]]*#')
assert_eq "1" "$_cap_av1_code" "MC_CAP_AV1=1 in cod o singura data (doar probe /vendor; zero din model SoC)"
AV1ENC="$(cat "$SCRIPT_DIR/av_encoder_av1.sh")"
assert_contains "$AV1ENC" 'MC_CAP_AV1:-0' "gard AV1: MC_CAP_AV1!=1 → fallback SW"
assert_contains "$AV1ENC" 'HW_FORCE:-0' "gard AV1: HW_FORCE=1 portita de override (SoC cu AV1 HW real neverificat)"

# ── 8. v75 forward-compat: AV1 HW encode detectat din lista de codecuri /vendor (nu model SoC) ──
assert_contains "$COMMON" '_mc_has_hw_av1_encoder'              "helper detectie AV1 HW encoder din /vendor"
assert_contains "$COMMON" '_mc_has_hw_av1_encoder && MC_CAP_AV1=1' "MC_CAP_AV1 setat din probe /vendor (forward-compat)"
# Hermetic: grep logica (exclude c2.android SW, prinde encoderul vendor HW)
eval "$(awk '/^_mc_has_hw_av1_encoder\(\)/{f=1} f; f&&/^}/{exit}' "$SCRIPT_DIR/av_common.sh")"
if declare -f _mc_has_hw_av1_encoder >/dev/null 2>&1; then
    _tmpd=$(mktemp -d)
    # SW-only (S24U/A54 azi): doar c2.android encoder + c2.qti DECODER → fara encoder HW
    printf '%s\n' '<MediaCodec name="c2.android.av1.encoder" type="video/av01">' \
                  '<MediaCodec name="c2.qti.av1.decoder" type="video/av01">' > "$_tmpd/sw.xml"
    if _mc_has_hw_av1_encoder "$_tmpd/sw.xml"; then _r=1; else _r=0; fi
    assert_eq "0" "$_r" "SW-only (c2.android encoder + c2.qti decoder) -> NU HW (S24U/A54 azi)"
    # HW present (cip viitor): c2.qti.av1.encoder
    printf '%s\n' '<MediaCodec name="c2.qti.av1.encoder" type="video/av01">' > "$_tmpd/hw.xml"
    if _mc_has_hw_av1_encoder "$_tmpd/hw.xml"; then _r=1; else _r=0; fi
    assert_eq "1" "$_r" "c2.qti.av1.encoder (vendor HW) -> DA HW (forward-compat, cip viitor)"
    # v75 audit: OMX legacy order (encoder INAINTE de av1) — regex robust pe ambele conventii
    printf '%s\n' '<MediaCodec name="OMX.qcom.video.encoder.av1" type="video/av01">' > "$_tmpd/omx.xml"
    if _mc_has_hw_av1_encoder "$_tmpd/omx.xml"; then _r=1; else _r=0; fi
    assert_eq "1" "$_r" "OMX legacy (encoder.av1, vendor non-google) -> DA HW (regex ambele ordini)"
    rm -rf "$_tmpd"
else
    echo "  (hermetic _mc_has_hw_av1_encoder sarit - extractie esuata)"
fi

# ── 9. v75 audit: probe FUNCTIONAL AV1 HW (gate hibrid model || probe) ──
# Prezenta av1_qsv/av1_vaapi in -encoders != HW (Intel UHD: av1_qsv pica runtime -22).
# Probe-ul (micro-encode testsrc→null cu format=nv12) verifica capabilitatea REALA cand
# modelul GPU nu e in whitelist. Validat empiric pe QSV real: av1_qsv pica, hevc_qsv reuseste.
# Nu poate da fals-pozitiv (encoderul incapabil pica clar) → hibrid sigur (probe-ul doar adauga).
assert_contains "$COMMON" '_hw_av1_qsv_works()'   "probe functional QSV AV1 definit"
assert_contains "$COMMON" '_hw_av1_vaapi_works()' "probe functional VAAPI AV1 definit"
assert_contains "$COMMON" 'format=nv12'           "probe foloseste format=nv12 (obligatoriu QSV; raw testsrc da fals-negativ)"
assert_contains "$COMMON" '_intel_gpu_has_av1_encode "$QSV_GPU_MODEL" || _hw_av1_qsv_works'    "gate QSV = model SAU probe (hibrid)"
assert_contains "$COMMON" '_intel_gpu_has_av1_encode "$VAAPI_GPU_MODEL" || _hw_av1_vaapi_works' "gate VAAPI = model SAU probe (hibrid)"
true
