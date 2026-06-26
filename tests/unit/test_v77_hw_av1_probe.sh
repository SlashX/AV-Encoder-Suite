#!/usr/bin/env bash
# v77 — probe functional AV1 HW uniform pe TOATE backend-urile desktop.
#   v75 avea probe-ul hibrid (model || probe) DOAR pe Intel QSV/VAAPI; NVENC/AMF/VideoToolbox
#   ramasesera pe regex de arhitectura. v77 extinde acelasi pattern → uniform "capabilitate
#   reala > model" pe toate. Source-level (paritate); functionalul nou (NVENC/AMF/VT) e
#   netestabil aici (boxa nu are AV1 HW discret + probe-urile sunt Linux/macOS-only) — ACELASI
#   caveat ca auditul HW v75; mecanismul e identic cu probe-ul QSV (validat functional in v75)
#   + cu Test-HwAv1Encoder (validat functional in test_v77_hw_av1_probe.ps1).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
COMMON="$(cat "$SCRIPT_DIR/av_common.sh")"

# ── 1. Probe-urile noi definite (oglinda _hw_av1_qsv_works/_hw_av1_vaapi_works din v75) ──
assert_contains "$COMMON" '_hw_av1_nvenc_works()' "probe NVENC definit"
assert_contains "$COMMON" '_hw_av1_amf_works()'   "probe AMF definit"
assert_contains "$COMMON" '_hw_av1_vt_works()'    "probe VideoToolbox definit"

# ── 2. format=nv12 OBLIGATORIU pe fiecare probe (finding v75: testsrc raw → fals-negativ pe QSV) ──
assert_contains "$COMMON" '-vf format=nv12 -c:v av1_nvenc'        "probe NVENC: format=nv12"
assert_contains "$COMMON" '-vf format=nv12 -c:v av1_amf'          "probe AMF: format=nv12"
assert_contains "$COMMON" '-vf format=nv12 -c:v av1_videotoolbox' "probe VT: format=nv12"

# ── 3. Cablare "model || probe" in cele 3 detect_*_caps (uniform cu QSV/VAAPI) ──
assert_contains "$COMMON" '|| _hw_av1_nvenc_works'            "NVENC: gate model || probe"
assert_contains "$COMMON" '|| _hw_av1_vt_works'               "VideoToolbox: gate model || probe"
assert_contains "$COMMON" '_hw_av1_amf_works && AMF_CAP_AV1=1' "AMF: arch nerecunoscuta → probe"

# ── 4. Regresie: probe-urile Intel din v75 raman cablate (v77 doar ADAUGA, nu scoate) ──
assert_contains "$COMMON" '_intel_gpu_has_av1_encode "$QSV_GPU_MODEL" || _hw_av1_qsv_works'     "QSV (v75) intact"
assert_contains "$COMMON" '_intel_gpu_has_av1_encode "$VAAPI_GPU_MODEL" || _hw_av1_vaapi_works' "VAAPI (v75) intact"

# ── 5. Sintaxa fisierului (probe-urile noi nu rup parserul) ──
if bash -n "$SCRIPT_DIR/av_common.sh" 2>/dev/null; then synrc=0; else synrc=1; fi
assert_eq "0" "$synrc" "av_common.sh: sintaxa valida cu probe-urile noi"

true
