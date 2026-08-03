#!/usr/bin/env bash
# v94 — onestitatea mesajelor din pipeline-ul de metadata. Patru defecte gasite la
# pilotarea matricei punctului 3 prin MENIURILE REALE:
#
#   B14 (onestitate): eticheta „Triple-layer" era HARDCODATA cu trei straturi, dar
#     TRIPLE_LAYER_MODE se seteaza la ORICE DV-preserve — inclusiv pe surse fara HDR10+.
#     Rezultat dovedit: „DV 8.1 + HDR10 + HDR10+ (HEVC) — OK" pe un fisier cu ZERO cadre
#     HDR10+. Cazul grav e AV1: pe build-uri fara `hdr10plus-json` stratul chiar se pierde,
#     iar userul era informat ca a supravietuit. Acum eticheta se compune din flagul setat
#     EXACT acolo unde intra inline-ul in encode.
#
#   O7 (numar gresit): „N scene descriptors" numara `BezierCurveData|TargetedSystemDisplay`
#     — AMANDOUA exista per intrare SceneInfo → 2x (374 in loc de 187). Pe continut fara
#     curbe Bezier ar fi dat 1x, deci numarul era si inconsistent, nu doar dublu.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"

CMN="$(cat "$SCRIPT_DIR/av_common.sh")"
X265="$(cat "$SCRIPT_DIR/av_encoder_x265.sh")"
AV1="$(cat "$SCRIPT_DIR/av_encoder_av1.sh")"

# ── B14: eticheta e COMPUSA, nu hardcodata ─────────────────────────────
assert_contains "$CMN" '[[ "${HDR10PLUS_INLINE_APPLIED:-0}" == "1" ]] && _tl_hp=" + HDR10+"' \
    "B14: sufixul HDR10+ vine din flagul de stare"
assert_contains "$CMN" '_tl_label="DV P10 + HDR10${_tl_hp} (AV1)"' \
    "B14: eticheta AV1 compusa"
assert_contains "$CMN" '_tl_label="DV 8.1 + HDR10${_tl_hp} (HEVC)"' \
    "B14: eticheta HEVC compusa"
# Santinela anti-revert, scopata pe CALEA DE RAPORTARE (de la blocul triple-layer in jos).
# `handle_hdr10plus_dialog` foloseste acelasi text ca descriere a OPTIUNII de meniu —
# acolo „HDR10+" e legitim (spune ce ar produce optiunea), deci nu intra in santinela.
TL_BLOCK=$(echo "$CMN" | sed -n '/── Triple-layer: injecteaza DV RPU in output/,$p')
hard=$(echo "$TL_BLOCK" | grep -c 'HDR10 + HDR10+ (\(AV1\|HEVC\))' || true)
assert_eq "0" "$hard" "B14: zero etichete cu HDR10+ hardcodat pe calea de raportare"

# ── B14: flagul se seteaza EXACT unde intra inline-ul in encode ─────────
assert_contains "$X265" 'HDR10PLUS_INLINE_APPLIED=1' \
    "B14: x265 marcheaza aplicarea dhdr10-info"
assert_contains "$AV1" 'HDR10PLUS_INLINE_APPLIED=1' \
    "B14: av1 marcheaza aplicarea hdr10plus-json"
# pe AV1 flagul sta pe ramura CU caps, nu pe cea de fallback
av1_after=$(echo "$AV1" | grep -A 3 'hdr10plus_av1_param=":hdr10plus-json=' | grep -c 'HDR10PLUS_INLINE_APPLIED=1' || true)
assert_eq "1" "$av1_after" "B14: flagul AV1 e pe ramura care chiar injecteaza"

# ── B14: reset per-fisier (regula obligatorie de state) ────────────────
assert_contains "$CMN" 'HDR10PLUS_INLINE_APPLIED=0' \
    "B14: flagul e resetat defensiv per fisier"

# ── B14: mesajele de fallback nu mai revendica nici ele HDR10+ ─────────
assert_contains "$CMN" 'output fara DV (HDR10${_tl_hp} pastrat)' \
    "B14: mesajele de esec folosesc acelasi sufix conditionat"
stale=$(echo "$TL_BLOCK" | grep -c 'output fara DV (HDR10+ pastrat)' || true)
assert_eq "0" "$stale" "B14: zero mesaje de fallback cu HDR10+ hardcodat"

# ── O7: numaram SCENE, nu chei care coexista in aceeasi intrare ────────
assert_contains "$CMN" "count=\$(grep -c '\"SequenceFrameIndex\"' \"\$json_file\"" \
    "O7: numaratoarea foloseste o cheie unica per intrare"
# Al 2-lea sit, gasit chiar de santinela asta: HDR/DV tools → Inspect metadata.
assert_contains "$(cat "$SCRIPT_DIR/av_hdr_dv_tools.sh")" \
    "scenes=\$(grep -c '\"SequenceFrameIndex\"' \"\$hp_json\"" \
    "O7: si fluxul Inspect numara scene, nu chei"
# anti-revert pe TOT src-ul; comentariile care explica fix-ul sunt permise
dbl=$(grep -rn 'BezierCurveData' "$SCRIPT_DIR" --include='*.sh' --include='*.ps1' 2>/dev/null \
      | grep -v ':[[:space:]]*#' | grep -cv '^\s*$' || true)
assert_eq "0" "$dbl" "O7: pattern-ul care numara dublu a disparut din cod"

# ── O8 (paritate): bash NU afiseaza level pe mezzanine ─────────────────
for enc in apv prores dnxhr; do
    n=$(grep -c "level" "$SCRIPT_DIR/av_encoder_$enc.sh" || true)
    assert_eq "0" "$n" "O8: av_encoder_$enc.sh nu afiseaza level (paritate cu PS1)"
done

# NB: framework.sh instaleaza `trap _test_summary EXIT` — un apel explicit aici ar
# tipari sumarul de doua ori (clasa reparata la auditul v85).
