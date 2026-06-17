#!/usr/bin/env bash
# v73: dvcC pe caile de COPY din trimconcat + avertisment DV la telemetrie embed (T2).
#   Pe stream-copy (Concat stream-copy, Pipeline smart-copy, Pipeline audio-only) DV trece
#   in bitstream → -c copy pierde dvcC la →MP4/MOV (pastrat la →MKV de ffmpeg) → re-signal
#   (helper codec-aware existent, v71/v72). Caile de RE-ENCODE NU re-semnalizeaza (RPU pierdut
#   prin design). Telemetrie embed = T2: doar AVERTISMENT pe DV+output-non-MKV (standalone PS1
#   → evitam dup; default-ul MKV acopera cazul comun). Source-level (wiring la cele 4 situri).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="$PROJECT_ROOT/src"
TC=$(cat "$SRC/av_trimconcat.sh")
TEL=$(cat "$SRC/av_telemetry.sh")

# ── 1. Concat stream-copy → re-signal (referinta compat = prima sursa) ──
assert_contains "$TC" '_dv_resignal_copy "${selected[0]}" "$out_path" "$_cc_ext"' "concat stream-copy: re-signal dvcC (selected[0])"

# ── 2. Pipeline → re-signal GARDAT pe smart_copy||audio_only (NU re-encode) ──
assert_contains "$TC" '(( smart_copy == 1 || audio_only == 1 )) && [[ -s "$out_path" ]]' "pipeline: re-signal gardat pe COPY (exclude re-encode)"
assert_contains "$TC" '_dv_resignal_copy "${chosen[0]}" "$out_path" "$_pl_ext"' "pipeline copy: re-signal dvcC (chosen[0])"

# ── 3. Telemetrie T2: doar AVERTISMENT pe DV + output non-MKV (FARA re-signal) ──
assert_contains "$TEL" '"$target_ext" != "mkv"' "telemetrie T2: gardat pe output non-MKV"
assert_contains "$TEL" 'Sursa are Dolby Vision' "telemetrie T2: avertisment DV"
_tel_resig=0; echo "$TEL" | grep -q "_dv_resignal_copy" && _tel_resig=1
assert_eq "0" "$_tel_resig" "telemetrie T2: warn-only (NU apeleaza _dv_resignal_copy)"

# ── 4. Concat/Pipeline re-encode DV: mesaj catre workflow-ul curat (encode per-clip → concat copy) ──
assert_contains "$TC" 'uneste-le cu Concat stream-copy (dvcC se re-semnalizeaza automat)' "re-encode DV: mesaj workflow curat (concat + pipeline)"
