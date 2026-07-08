#!/usr/bin/env bash
# v85 — santinele source-level pentru bug-urile gasite la campania de validare v85
#   (F1-F9). Grep-based, fara ffmpeg → ruleaza rapid pe orice platforma. Prinde
#   regresia clasei „breakage silentios" (set -e guard, colon-param PS1, overlay
#   alpha, notify exit-code, SRT template mort, DV tonemap unknown).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="$PROJECT_ROOT/src"

BURNIN="$(cat "$SRC/av_burnin.sh")"
BURNIN_PS="$(cat "$SRC/av_burnin.ps1")"
TELEM="$(cat "$SRC/av_telemetry.sh")"
TELEM_PS="$(cat "$SRC/av_telemetry.ps1")"
COMMON="$(cat "$SRC/av_common.sh")"
CHECK="$(cat "$SRC/av_check.sh")"

# ── F1: eticheta DV P7 corecta (nu „HDR10+", si „dual-layer Blu-ray") ──
assert_contains "$COMMON" "Profil 7 (DV + HDR10, dual-layer Blu-ray)" "F1: P7 eticheta corecta (av_common)"
assert_contains "$CHECK"  "Profil 7 (DV + HDR10, dual-layer Blu-ray)" "F1: P7 eticheta corecta (av_check)"
if echo "$COMMON" | grep -q "Profil 7 (DV + HDR10+)"; then _fail "F1: eticheta P7 veche (HDR10+) inca prezenta"; else _pass; fi

# ── F2: GPX/CSV Basic verifica CONTINUT real (nu doar non-gol) ──
assert_contains "$TELEM" 'grep -q "<trkpt"' "F2: GPX verifica trkpt real (bash)"
assert_contains "$TELEM_PS" '<trkpt' "F2: GPX verifica trkpt real (PS1)"

# ── F3: template SRT exiftool mort SCOS; SRT generat din extractia per-sample ──
if echo "$TELEM" | grep -q 'SRT_FMT='; then _fail "F3: SRT_FMT (template mort) inca prezent bash"; else _pass; fi
if echo "$TELEM_PS" | grep -q 'srtFmt ='; then _fail "F3: srtFmt (template mort) inca prezent PS1"; else _pass; fi
assert_contains "$TELEM" 'want_srt' "F3: SRT generat din extractia per-sample (bash)"
assert_contains "$TELEM_PS" 'wantSrt' "F3: SRT generat din extractia per-sample (PS1)"

# ── F4: -write_tmcd 0 pe output mp4/mov la strip (muxer regenereaza tmcd) ──
assert_contains "$TELEM" 'write_tmcd' "F4: -write_tmcd 0 la strip (bash)"
assert_contains "$TELEM_PS" 'write_tmcd' "F4: -write_tmcd 0 la strip (PS1)"

# ── F5: pick_files/ask_burnin_shaping NU se termina cu `[ ] && {...}` sub set -e ──
# (garda-ultima-linie care intoarce 1 pe cazul normal → set -e omoara scriptul)
if echo "$BURNIN" | grep -qE '\[ "\$\{#SELECTED\[@\]\}" -eq 0 \] && \{'; then
    _fail "F5: pick_files inca are garda [ ] && {...} (moare sub set -e)"; else _pass; fi
assert_contains "$BURNIN" 'if [ "${#SELECTED[@]}" -eq 0 ]; then' "F5: pick_files garda ca if (safe)"

# ── F6: format explicit dupa overlay (ffmpeg nou negociaza alpha → x265 refuza) ──
ovcount=$(echo "$BURNIN" | grep -cE 'overlay[^]]*,format=\$\{_ov_fmt\}')
[ "$ovcount" -ge 3 ] && _pass "F6: format dupa overlay in >=3 situri bash ($ovcount)" || _fail "F6: format dupa overlay bash ($ovcount<3)"
ovcount_ps=$(echo "$BURNIN_PS" | grep -cE 'overlay[^]]*,format=\$ovFmt')
[ "$ovcount_ps" -ge 3 ] && _pass "F6: format dupa overlay in >=3 situri PS1 ($ovcount_ps)" || _fail "F6: format dupa overlay PS1 ($ovcount_ps<3)"

# ── F7: Invoke-BurninEncode chemat cu array splatat (nu -c:v literal) ──
if echo "$BURNIN_PS" | grep -qE 'Invoke-BurninEncode -v error'; then
    _fail "F7: Invoke-BurninEncode inca chemat cu tokenuri literale (-c:v se corupe)"; else _pass; fi
splat=$(echo "$BURNIN_PS" | grep -cE 'Invoke-BurninEncode @(ffArgs|stArgs)')
[ "$splat" -eq 6 ] && _pass "F7: 6 apeluri Invoke-BurninEncode splatate" || _fail "F7: apeluri splatate ($splat != 6)"

# ── F8: av_notify_done / av_wake_unlock / av_wake_lock intorc 0 explicit ──
for fn in av_notify_done av_wake_unlock av_wake_lock; do
    # extrage corpul functiei si verifica `return 0` inainte de `}`
    body=$(awk "/^$fn\(\) \{/{f=1} f{print} /^}/{if(f)exit}" "$SRC/av_common.sh")
    if echo "$body" | grep -q "return 0"; then _pass "F8: $fn are return 0 explicit"; else _fail "F8: $fn fara return 0 (exit non-zero pe succes)"; fi
done

# ── F9: DV P5/P7 tonemap — setparams PQ/BT.2020 pe transfer=unknown ──
assert_contains "$BURNIN" 'color_trc=smpte2084:colorspace=bt2020nc' "F9: setparams PQ pe tonemap unknown (bash)"
assert_contains "$BURNIN_PS" 'color_trc=smpte2084:colorspace=bt2020nc' "F9: setparams PQ pe tonemap unknown (PS1)"
assert_contains "$BURNIN" '"unknown"' "F9: gateat pe transfer unknown (bash)"

# ── INVARIANT clasa F5: nicio functie din scripturile cu set -e nu se termina
#    cu garda `[ ... ] && cmd` FARA `||` (pe cazul normal functia intoarce 1 →
#    set -e omoara scriptul in apelant). Scanam TOATE .sh care au `set -e`.
f5_viol=0
for f in "$SRC"/*.sh; do
    grep -q "^set -e" "$f" || continue
    viol=$(awk 'prev ~ /^\s*\[\[?[^]]*\]\]? && / && prev !~ /\|\|/ && /^\}/ {print FILENAME": "prev} {prev=$0}' "$f")
    if [ -n "$viol" ]; then f5_viol=1; echo "  VIOLARE F5-class: $viol"; fi
done
[ "$f5_viol" -eq 0 ] && _pass "INVARIANT F5: zero garzi [ ] && ca ultima linie de functie sub set -e" \
                      || _fail "INVARIANT F5: garda-ultima-linie sub set -e gasita (vezi mai sus)"

# ── INVARIANT clasa F7: niciun apel de FUNCTIE PS1 (Invoke-*) cu flag-uri
#    ffmpeg cu `:` ca tokenuri literale (-c:v / -c:a / -frames:v — la functie
#    se parseaza -param:value → arg corupt). Comenzile NATIVE (& ffmpeg -c:v) sunt OK.
f7_viol=$(grep -hnE 'Invoke-[A-Za-z]+ .*(-c:v|-c:a |-frames:v)' "$SRC"/*.ps1 | grep -v "^\s*#" || true)
if [ -z "$f7_viol" ]; then _pass "INVARIANT F7: zero apeluri Invoke-* cu -c:v/-c:a/-frames:v literale"
else echo "  VIOLARE F7-class: $f7_viol"; _fail "INVARIANT F7: apel de functie PS1 cu flag colon literal"; fi

# ── O1: paritate spatiere etichete DV bash<->PS1 (aliniate la „DV + X") ──
CHECK_PS="$(cat "$SRC/av_check.ps1")"
ENCODE_PS="$(cat "$SRC/av_encode.ps1")"
if echo "$CHECK_PS" | grep -qE '\(DV\+'; then _fail 'O1: eticheta DV lipita (DV+) inca in av_check.ps1'; else _pass 'O1: av_check.ps1 foloseste DV + X (paritate bash)'; fi
if echo "$ENCODE_PS" | grep -qE 'Profil [0-9].*\(DV\+'; then _fail 'O1: eticheta DV lipita in av_encode.ps1'; else _pass 'O1: av_encode.ps1 foloseste DV + X'; fi

# ── O2: av_check.sh check upfront de ffprobe (mesaj onest vs „stream invalid") ──
assert_contains "$CHECK" 'ffprobe (FFmpeg) nu este in PATH' "O2: av_check.sh check upfront ffprobe"

# ── O5: av_extractor_gps avertisment la coliziune de stem ──
GPS="$(cat "$SRC/av_extractor_gps.sh")"
GPS_PS="$(cat "$SRC/av_extractor_gps.ps1")"
assert_contains "$GPS" 'output-urile se suprascriu' "O5: avertisment coliziune stem (bash)"
assert_contains "$GPS_PS" 'output-urile se suprascriu' "O5: avertisment coliziune stem (PS1)"

# ── O4: av_extractor_gps trece caile prin sys.argv (delimiter quotat), NU
#    interpolate in textul heredoc (fragil la ghilimele/backslash in nume) ──
gps_argv=$(echo "$GPS" | grep -c 'file_path = sys.argv\[1\]')
[ "$gps_argv" -eq 3 ] && _pass "O4: toate 3 heredoc-uri citesc calea din sys.argv" || _fail "O4: doar $gps_argv/3 heredoc-uri pe argv"
gps_quoted=$(echo "$GPS" | grep -c "<< 'PYEOF'")
[ "$gps_quoted" -eq 3 ] && _pass "O4: toate 3 heredoc-uri au delimiter quotat 'PYEOF' (fara interpolare)" || _fail "O4: $gps_quoted/3 delimitere quotate"
if echo "$GPS" | grep -q 'file_path = "\$file"'; then _fail "O4: interpolare 'file_path = \$file' inca prezenta (fragila)"; else _pass "O4: zero interpolare de cale in text"; fi

# ── O3: env override AV_INPUT_DIR/AV_OUTPUT_DIR pe cele 3 standalone PS1 ──
for f in av_telemetry.ps1 av_extractor_gps.ps1 av_mux.ps1; do
    if grep -q 'env:AV_INPUT_DIR' "$SRC/$f"; then _pass "O3: $f are env override AV_INPUT_DIR"; else _fail "O3: $f fara env override"; fi
done

# ── O6: av_filtergraph_path (cygpath MSYS + escape) exista + folosit non-eval ──
assert_contains "$COMMON" 'av_filtergraph_path()' "O6: helper av_filtergraph_path definit"
assert_contains "$COMMON" 'command -v cygpath' "O6: cygpath guard pt MSYS"
assert_contains "$(cat "$SRC/av_burnin.sh")" 'av_filtergraph_path "$1"' "O6: burnin escape deleaga la helper"
assert_contains "$(cat "$SRC/av_trimconcat.sh")" 'av_filtergraph_path "$TC_LUT_FILE"' "O6: trimconcat LUT foloseste helper"

# ── Apple Log robust la taiere (v85): fallback pe encoderul de STREAM
#    ("Apple ProRes") cand make=Apple de container se pierde la -c copy/trim.
#    Toate 5 site-urile de detectie (bash+PS1). ffmpeg prores_ks scrie
#    "Lavc... prores_ks" (nu "Apple ProRes") → semnal sigur, zero fals-pozitiv. ──
for f in av_common.sh av_check.sh av_encode.ps1 av_check.ps1 av_burnin.ps1; do
    if grep -q '"Apple ProRes"' "$SRC/$f" || grep -q 'Apple ProRes' "$SRC/$f"; then _pass "AppleLog-cut: fallback encoder in $f"; else _fail "AppleLog-cut: fallback lipsa in $f"; fi
done
# gateat pe camera make gol (nu suprascrie un make explicit)
assert_contains "$COMMON" '_venc_tag' "AppleLog-cut: fallback bash gateat (var _venc_tag)"

# ── F8 functional (hermetic): notify/wake intorc 0 chiar fara unelte ──
f8_rc=$(bash -c 'source "'"$SRC"'/av_common.sh" >/dev/null 2>&1; AV_PLATFORM=linux; av_notify_done "t" "m" >/dev/null 2>&1; echo $?' 2>/dev/null | tail -1)
[ "$f8_rc" = "0" ] && _pass "F8 functional: av_notify_done rc=0 fara unealta" || _fail "F8 functional: av_notify_done rc=$f8_rc"
f8b_rc=$(bash -c 'source "'"$SRC"'/av_common.sh" >/dev/null 2>&1; AV_PLATFORM=termux; av_wake_unlock >/dev/null 2>&1; echo $?' 2>/dev/null | tail -1)
[ "$f8b_rc" = "0" ] && _pass "F8 functional: av_wake_unlock rc=0 fara unealta" || _fail "F8 functional: av_wake_unlock rc=$f8b_rc"

# ── CANARE functionale F6 + F9 (cer ffmpeg + libx265; skip gratios) ──
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SRC:$PATH"
if command -v ffmpeg >/dev/null 2>&1 && ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx265; then
    tmpd="$(mktemp -d)"
    trap 'rm -rf "$tmpd"; _test_summary' EXIT
    ffmpeg -v error -f lavfi -i "color=c=red@0.5:s=160x90:d=0.2" -vf format=rgba -frames:v 1 "$tmpd/a.png" -y </dev/null 2>/dev/null
    ffmpeg -v error -f lavfi -i "testsrc=duration=0.2:size=160x90:rate=10" -pix_fmt yuv420p10le -c:v libx265 -x265-params log-level=none "$tmpd/b.mp4" -y </dev/null 2>/dev/null
    # F6 CANAR: overlay RGBA + format explicit → x265 accepta (fara format, ffmpeg
    # nou negociaza yuva420p → x265 refuza alpha; daca ffmpeg viitor schimba iar
    # negocierea, formele suitei raman valide prin format= explicit)
    if ffmpeg -v error -i "$tmpd/b.mp4" -i "$tmpd/a.png" \
        -filter_complex "[0:v][1:v]overlay=0:0:shortest=0,format=yuv420p[v]" \
        -map "[v]" -c:v libx265 -x265-params log-level=none -f null - </dev/null >/dev/null 2>&1; then
        _pass "F6 CANAR: overlay RGBA + format explicit → x265 OK"
    else
        _fail "F6 CANAR: overlay+format explicit respins de x265 (ffmpeg si-a schimbat iar negocierea?)"
    fi
    # F9 CANAR: sursa cu transfer NEsetat (testsrc are unknown) → lantul cu
    # setparams-prefix (forma F9) trece; se valideaza ca prefixul ramane suficient
    if ffmpeg -v error -i "$tmpd/b.mp4" \
        -vf "setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc,zscale=transfer=linear:matrix=bt709:primaries=bt709,tonemap=hable:desat=0,zscale=transfer=bt709:matrix=bt709:primaries=bt709,format=yuv420p" \
        -frames:v 1 -f null - </dev/null >/dev/null 2>&1; then
        _pass "F9 CANAR: tonemap cu setparams-prefix pe transfer unknown → OK"
    else
        _fail "F9 CANAR: lantul tonemap F9 respins pe transfer unknown"
    fi
else
    _pass  # skip-equivalent: ffmpeg/libx265 lipsesc
    _pass
fi

# summary vine din trap (framework default / trap-ul cu cleanup din ramura ffmpeg) —
# apel explicit aici ar dubla raportul (trap-ul re-cheama _test_summary la exit)
