#!/usr/bin/env bash
# v76 — conversie DV Profile 7 → 8.1 (dual-layer aware): bash.
#   Source-level: config AV_TOOL_MKVEXTRACT/AV_ENGINE_DV_P7 + helperi puri (av_common.sh)
#     + orchestrator convert_p7_to_81 + branch P7 in transform flow (av_hdr_dv_tools.sh).
#   Hermetic: engine dv_p7_analyze.py (clasificare MEL/FEL_SAFE/FEL_COMPLEX/UNKNOWN —
#     functie pura, fara HW/tool extern).
#   Functional (mkvextract→discard→mkvmerge) = validat in PS1 pe Windows + manual (vezi memorie);
#     aici se sare (MSYS path quirks pe mkvextract/mkvmerge, ca test_v71/v72).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="$PROJECT_ROOT/src"

COMMON="$(cat "$SRC/av_common.sh")"
TOOLS="$(cat "$SRC/av_hdr_dv_tools.sh")"
ENGINE="$SRC/dv_p7_analyze.py"

# ── 1. Config: tool + engine ──────────────────────────────────────────
assert_contains "$COMMON" 'AV_TOOL_MKVEXTRACT="'  "AV_TOOL_MKVEXTRACT in blocul de config"
assert_contains "$COMMON" 'AV_ENGINE_DV_P7="'     "AV_ENGINE_DV_P7 in blocul de config"

# ── 2. Helperi puri (av_common.sh) ────────────────────────────────────
assert_contains "$COMMON" '_dv_bl_peak_nits()'       "helper _dv_bl_peak_nits"
assert_contains "$COMMON" '_dv_extract_full_hevc()'  "helper _dv_extract_full_hevc"
assert_contains "$COMMON" '_classify_p7_el()'        "helper _classify_p7_el"
assert_contains "$COMMON" 'frame_side_data=max_content' "bl_peak din MaxCLL real al BL"
assert_contains "$COMMON" 'tracks "${vid}:${out}"'   "extract full foloseste mkvextract tracks"
assert_contains "$COMMON" 'hevc_mp4toannexb'         "fallback ffmpeg pe non-MKV"

# ── 3. Orchestrator + branch (av_hdr_dv_tools.sh) ─────────────────────
assert_contains "$TOOLS" 'convert_p7_to_81()'        "orchestrator convert_p7_to_81"
assert_contains "$TOOLS" '-m 2 convert --discard'    "conversie P7->8.1 (discard EL)"
assert_contains "$TOOLS" '_hdv_combine_with_original "$bl81"' "re-mux dvcC via _hdv_combine_with_original"
assert_contains "$TOOLS" 'Profil 7'                  "branch P7 in hdv_flow_transform_rpu"
assert_contains "$TOOLS" '_dv81.'                    "sufix output _dv81"

# ── 4. Gate de siguranta FEL ──────────────────────────────────────────
assert_contains "$TOOLS" 'FEL_COMPLEX|UNKNOWN)'      "gate trateaza FEL_COMPLEX/UNKNOWN"
assert_contains "$TOOLS" 'DV_P7_FORCE'               "gate are escape DV_P7_FORCE"
assert_contains "$TOOLS" 'AV_NONINTERACTIVE'         "gate refuza non-interactiv (fara force)"

# ── 5. Engine: structura ──────────────────────────────────────────────
ENG="$(cat "$ENGINE")"
assert_contains "$ENG" 'def pq_to_nits'   "engine: EOTF ST.2084"
assert_contains "$ENG" 'MARGIN_NITS = 50' "engine: marja 50 niti peste BL peak"
assert_contains "$ENG" '"el_type":"MEL"'  "engine: detecteaza MEL"
assert_contains "$ENG" 'def collect_l1_max' "engine: aduna L1 max_pq recursiv"

# ── 6. Hermetic: verdicte engine pe JSON sintetic (doar python) ───────
if command -v python3 >/dev/null 2>&1; then
    TMP="$(mktemp -d)"
    _v() { python3 "$ENGINE" "$1" "${2:-1000}" 2>/dev/null | awk '{print $1}'; }

    printf '%s' '[{"el_type":"MEL","dm_data":[{"Level1":{"max_pq":2400}}]}]' > "$TMP/mel.json"
    assert_eq "MEL" "$(_v "$TMP/mel.json" 1000)" "MEL → MEL (discard lossless)"

    printf '%s' '[{"el_type":"FEL","dm_data":[{"Level1":{"max_pq":2400}}]}]' > "$TMP/fels.json"
    assert_eq "FEL_SAFE" "$(_v "$TMP/fels.json" 1000)" "FEL max_pq=2400 (214 niti) vs BL 1000 → FEL_SAFE"

    printf '%s' '[{"el_type":"FEL","dm_data":[{"Level1":{"max_pq":3600}}]}]' > "$TMP/felc.json"
    assert_eq "FEL_COMPLEX" "$(_v "$TMP/felc.json" 1000)" "FEL max_pq=3600 (3219 niti) vs BL 1000 → FEL_COMPLEX"

    # acelasi FEL dar BL graded 4000 → sigur (prag content-aware)
    assert_eq "FEL_SAFE" "$(_v "$TMP/felc.json" 4000)" "FEL 3219 niti vs BL 4000 → FEL_SAFE"

    printf '%s' 'nu-i json' > "$TMP/bad.json"
    assert_eq "UNKNOWN" "$(_v "$TMP/bad.json" 1000)" "JSON corupt → UNKNOWN (conservator)"

    rm -rf "$TMP"
else
    skip_test "python3 lipseste — hermetic engine sarit"
fi

# ── 7. Situatia 2: DV-preserve P7-aware pe calea de ENCODE ─────────────
# Baza re-encodata e mereu single-layer HDR10 → un RPU profil-7 injectat ar produce DV
# invalid. _extract_preserve_rpu converteste 7→8.1 inainte de inject (EL pierdut oricum
# la re-encode); restul surselor (P8.x / AV1 P10) → extract_dv_rpu normal.
assert_contains "$COMMON" '_extract_preserve_rpu()' "helper _extract_preserve_rpu (Situatia 2)"
PRES="$(awk '/^_extract_preserve_rpu\(\)/{f=1} f{print} f&&/^}/{exit}' "$SRC/av_common.sh")"
assert_contains "$PRES" 'Profil 7'           "gate _extract_preserve_rpu pe Profil 7"
assert_contains "$PRES" '_dv_extract_full_hevc' "P7 → extract stream complet (EL in MKV block additions)"
assert_contains "$PRES" '-m 2 convert --discard' "P7 → convert STREAM 7→8.1 (NU -m editor pe RPU = no-op)"
assert_contains "$PRES" 'extract-rpu "$conv"'    "P7 → extract RPU profil-8 din streamul convertit"
assert_contains "$PRES" 'extract_dv_rpu'      "non-P7/non-hevc → extract_dv_rpu normal (fallback)"

# Toate siturile de DV-preserve pe encode trec prin helper (zero extract_dv_rpu brut)
assert_contains "$COMMON" '_extract_preserve_rpu "$file" "$rpu_tmp" "$src_codec"' "hw_preserve (av_common) foloseste _extract_preserve_rpu"
X265="$(cat "$SRC/av_encoder_x265.sh")"
AV1SRC="$(cat "$SRC/av_encoder_av1.sh")"
assert_eq "2" "$(printf '%s\n' "$X265"   | grep -c '_extract_preserve_rpu "')" "x265: 2 situri preserve via helper (SW + MediaCodec)"
assert_eq "2" "$(printf '%s\n' "$AV1SRC" | grep -c '_extract_preserve_rpu "')" "av1: 2 situri preserve via helper (SW + MediaCodec)"
assert_eq "0" "$(printf '%s\n' "$X265"   | grep -c 'extract_dv_rpu')" "x265: zero extract_dv_rpu brut (toate prin helper)"
assert_eq "0" "$(printf '%s\n' "$AV1SRC" | grep -c 'extract_dv_rpu')" "av1: zero extract_dv_rpu brut (toate prin helper)"

_test_summary
