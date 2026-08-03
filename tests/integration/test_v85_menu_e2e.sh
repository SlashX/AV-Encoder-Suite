#!/usr/bin/env bash
# v85 — E2E prin MENIU pe scripturile standalone interactive (clasa de acoperire
#   care lipsea: F5 [pick_files sub set -e] + F6 [overlay alpha] + F7 [PS1 colon]
#   au trait TOATE in spatiul dintre „functiile merg" si „fluxul merge cand e
#   pilotat prin meniu"). Pilotam meniurile REALE cu stdin pe fixture-uri
#   generate local (testsrc) si verificam output-ul cu ffprobe.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SRC:$PATH"
command -v ffmpeg >/dev/null 2>&1 || skip_test "ffmpeg lipseste"
ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx265 || skip_test "libx265 lipseste"

tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"; _test_summary' EXIT
# Pe git-bash (MSYS), caile POSIX /tmp/... intra in FILTERGRAPH (subtitles=)
# unde conversia de argv nu se aplica → ffmpeg nativ nu le gaseste (clasa O6,
# doar harness — productia bash e POSIX nativ). cygpath -m → cale mixta D:/...
command -v cygpath >/dev/null 2>&1 && tmpd="$(cygpath -m "$tmpd")"
IN="$tmpd/in"; OUT="$tmpd/out"; mkdir -p "$IN" "$OUT"

# v94: AV_TEMP_DIR propriu, IZOLAT. Fara el, av_trimconcat foloseste <src>/Temp, iar daca
# acolo exista subfoldere reziduale (trim_*/concat_*/pipeline_*/preview_* — pastrate DELIBERAT
# pentru recovery), `tc_scan_leftover_temp` afiseaza un prompt SUPLIMENTAR care decaleaza tot
# stdin-ul pilotat → „Selectie invalida" si fail fals-pozitiv, dependent de ce a rulat inainte.
# Izolarea e preferabila curatarii lui <src>/Temp: nu atinge datele reale ale userului.
export AV_TEMP_DIR="$tmpd/avtemp"; mkdir -p "$AV_TEMP_DIR"

# fixture: clip SDR mic + SRT pereche (pairing: video in IN, .srt in OUT)
ffmpeg -v error -f lavfi -i "testsrc=duration=2:size=320x180:rate=25" \
    -pix_fmt yuv420p -c:v libx265 -x265-params log-level=none "$IN/clip.mp4" -y </dev/null 2>/dev/null
printf '1\n00:00:00,200 --> 00:00:01,500\nMENU E2E v85\n\n' > "$OUT/clip.srt"
[ -s "$IN/clip.mp4" ] && _pass || _fail "fixture clip.mp4 generat"

# ── 1. av_burnin: fluxul SRT prin meniul REAL (main 2 → file 1 → defaults) ──
#    (ar fi prins F5: moarte la selectie; F6: alpha overlay pe HUD/img; F7 e PS1)
printf "2\n1\n\n\n\n\n\n\n\n\n" | INPUT_DIR="$IN" OUTPUT_DIR="$OUT" \
    bash "$SRC/av_burnin.sh" >"$tmpd/burnin.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] && _pass "burnin SRT menu: rc=0" || { _fail "burnin SRT menu rc=$rc"; tail -5 "$tmpd/burnin.log"; }
if [ -s "$OUT/clip_subs.mp4" ]; then
    _pass "burnin SRT menu: output exista"
    vc=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
        -of default=nw=1:nk=1 "$OUT/clip_subs.mp4" 2>/dev/null | head -1 | tr -d '\r')
    assert_eq "hevc" "$vc" "burnin SRT menu: output hevc valid"
else
    _fail "burnin SRT menu: output lipsa"; grep -aE "EROARE|error" "$tmpd/burnin.log" | head -3
fi

# ── 2. av_mux: Remux prin meniul REAL (1=Remux → file → ALL streams → mkv) ──
#    fixture fara audio → mai putine prompturi; dam newline-uri suficiente ca
#    default-urile (ALL/D) sa curga, apoi alegem containerul mkv la final.
mkdir -p "$tmpd/mux_out"
printf "1\n1\n\n\n\n\n\n\n\n1\n" | INPUT_DIR="$IN" OUTPUT_DIR="$tmpd/mux_out" \
    bash "$SRC/av_mux.sh" >"$tmpd/mux.log" 2>&1
rc=$?
mux_out=$(ls "$tmpd/mux_out"/*_remux.* 2>/dev/null | head -1)
if [ -n "$mux_out" ] && [ -s "$mux_out" ]; then
    _pass "mux Remux menu: output exista ($(basename "$mux_out"))"
else
    _fail "mux Remux menu: output lipsa (rc=$rc)"; grep -aE "EROARE|error|✓" "$tmpd/mux.log" | head -3
fi

# ── 3. av_trimconcat: Trim prin meniul REAL (1=Trim → file 1 → 0..2s → stream copy) ──
printf "1\n1\n0\n2\n\n\n\n\n\n\n" | INPUT_DIR="$IN" OUTPUT_DIR="$OUT" \
    bash "$SRC/av_trimconcat.sh" >"$tmpd/trim.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] && _pass "trimconcat Trim menu: rc=0" || { _fail "trimconcat Trim menu rc=$rc"; tail -5 "$tmpd/trim.log"; }
trim_out=$(ls "$OUT"/*_trim* 2>/dev/null | head -1)
if [ -n "$trim_out" ] && [ -s "$trim_out" ]; then
    _pass "trimconcat Trim menu: output exista ($(basename "$trim_out"))"
else
    _fail "trimconcat Trim menu: output lipsa"; grep -aE "EROARE|error" "$tmpd/trim.log" | head -3
fi
