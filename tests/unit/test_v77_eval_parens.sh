#!/usr/bin/env bash
# v77 — Santinela: master-display=G(..) escapat pe caile rulate prin `eval` (encoder x265/av1).
# Bug latent de la v51: parantezele master-display neescapate intrau in FFMPEG_CMD rulat prin
# `eval` in run_encode_loop → "syntax error near unexpected token (" → encode HDR10/DV SW = 0
# octeti pe bash. Mascat fiindca validarea HDR e pe Windows/PS1 (PS1 foloseste array-uri de
# argumente, NU eval). Fix: helper `_esc_eval_parens` aplicat DOAR pe calea eval (x265:_set_x265_
# hdr10_static + av1:hdr10_static_av1_param); var-urile partajate HDR10_MASTER_DISPLAY_* raman
# RAW pentru consumatorii DIRECTI (burn-in/trim-concat ffmpeg direct + dovi_tool --master-display),
# care paseaza valoarea ca UN argument (fara eval) si au nevoie de parantezele brute.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="$PROJECT_ROOT/src"

common=$(cat "$SRC/av_common.sh")
x265=$(cat "$SRC/av_encoder_x265.sh")
av1=$(cat "$SRC/av_encoder_av1.sh")
burnin=$(cat "$SRC/av_burnin.sh")
trimc=$(cat "$SRC/av_trimconcat.sh")

# ── 1. Helper definit + aplicat pe cele 2 situri EVAL ──
assert_contains "$common" "_esc_eval_parens()" "_esc_eval_parens definit (av_common.sh)"
assert_match "$x265" 'X265_HDR10_STATIC_PARAMS="master-display=\$\(_esc_eval_parens' \
    "x265 _set_x265_hdr10_static escapeaza master-display (calea eval)"
assert_match "$av1" 'mastering-display=\$\(_esc_eval_parens' \
    "av1 hdr10_static_av1_param escapeaza mastering-display (calea eval)"

# ── 2. Forma RAW neescapata pe calea eval NU mai exista (regresie) ──
assert_not_contains "$x265" 'master-display=${HDR10_MASTER_DISPLAY_X265}' \
    "x265: master-display RAW pe calea eval ELIMINAT (regresie eval-parens)"
assert_not_contains "$av1" 'mastering-display=${HDR10_MASTER_DISPLAY_SVTAV1}' \
    "av1: mastering-display RAW pe calea eval ELIMINAT (regresie eval-parens)"

# ── 3. Consumatorii DIRECTI (non-eval) raman pe var-ul RAW (NU escapat) ──
# burn-in (ffmpeg direct) + trim-concat ("$@") paseaza valoarea ca UN argument → paranteze brute.
assert_contains "$burnin" 'master-display=${HDR10_MASTER_DISPLAY_X265}' \
    "burn-in foloseste master-display RAW (ffmpeg direct, FARA eval — corect)"
assert_contains "$trimc" 'master-display=${HDR10_MASTER_DISPLAY_X265}' \
    "trim-concat foloseste master-display RAW (\"\$@\", FARA eval — corect)"
assert_not_contains "$burnin" '_esc_eval_parens' "burn-in NU escapeaza (nu e eval)"
assert_not_contains "$trimc"  '_esc_eval_parens' "trim-concat NU escapeaza (nu e eval)"

# ── 4. Functional: comportamentul helper-ului ──
source "$SRC/av_common.sh"
assert_eq 'G\(1,2\)B\(3,4\)' "$(_esc_eval_parens 'G(1,2)B(3,4)')" "_esc_eval_parens escapeaza ( si )"
assert_eq 'fara-paranteze' "$(_esc_eval_parens 'fara-paranteze')" "_esc_eval_parens no-op fara paranteze"

# ── 5. Canar: mecanismul eval (RAW pica, escapat trece) ──
_md='G(13250,34500)B(7500,3000)'
if eval "echo -x265-params master-display=${_md}" >/dev/null 2>&1; then _raw_ok=1; else _raw_ok=0; fi
assert_eq "0" "$_raw_ok" "canar: master-display RAW in eval → syntax error (dovedeste bug-ul)"
_esc=$(_esc_eval_parens "$_md")
if eval "echo -x265-params master-display=${_esc}" >/dev/null 2>&1; then _esc_ok=1; else _esc_ok=0; fi
assert_eq "1" "$_esc_ok" "canar: master-display ESCAPAT in eval → OK (dovedeste fix-ul)"
# si ca eval-ul escapat produce parantezele CORECTE (unescaped) la consumator (x265)
_out=$(eval "echo master-display=${_esc}" 2>/dev/null)
assert_eq "master-display=G(13250,34500)B(7500,3000)" "$_out" "eval restaureaza parantezele brute pt x265"

# ── 6. Generalizare bug #2 pe TOATE caile (HW + inventar eval) ──
# (a) HW: _HW_VUI_BSF (intra in FFMPEG_CMD eval'd pt NVENC/QSV/VAAPI/VT/AMF) trebuie sa ramana
#     VUI NUMERIC (colour_primaries=9:...) — FARA paranteze. Daca cineva adauga mastering_display
#     cu paranteze acolo, ar reintroduce bug #2 pe HW.
_hw_bsf_parens=$(grep -E '_HW_VUI_BSF(\+)?=' "$SRC/av_common.sh" | grep -c '(' || true)
assert_eq "0" "$_hw_bsf_parens" "HW: _HW_VUI_BSF e numeric (fara paranteze → FFMPEG_CMD HW sigur)"

# (b) Niciun FFMPEG_CMD / FFMPEG_CMD_PASS (SW sau HW, orice fisier) nu hardcodeaza master-display
#     cu paranteze (ar ocoli helper-ul _esc_eval_parens).
_cmd_parens=$(grep -rhE 'FFMPEG_CMD(_PASS[12])?(\+)?=' "$SRC"/*.sh | grep -cE 'master-display=G\(|mastering-display=G\(' || true)
assert_eq "0" "$_cmd_parens" "niciun FFMPEG_CMD nu hardcodeaza master-display cu paranteze"

# (c) Inventar eval: comanda de encode rulata prin `eval` traieste DOAR in av_common.sh
#     (run_encode_loop / run_2pass_encode). Un encoder/standalone care introduce `eval` pe un
#     string de comanda = risc nou de bug #2 → testul forteaza review.
_eval_outside=0
for _f in av_burnin av_check av_encoder_apv av_encoder_audio av_encoder_av1 av_encoder_x265 \
          av_encoder_x264 av_encoder_prores av_encoder_dnxhr av_extractor_gps av_hdr_dv_tools \
          av_launcher av_mux av_telemetry av_trimconcat; do
    [ -f "$SRC/$_f.sh" ] || continue
    _c=$(grep -nE '\beval\b' "$SRC/$_f.sh" | grep -vE '^[[:space:]]*[0-9]+:[[:space:]]*#' | wc -l)
    _eval_outside=$((_eval_outside + _c))
done
assert_eq "0" "$_eval_outside" "eval pe comenzi confinat in av_common.sh (encoderele/standalone NU au eval)"

_test_summary
