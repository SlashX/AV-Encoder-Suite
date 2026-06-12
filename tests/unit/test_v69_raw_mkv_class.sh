#!/usr/bin/env bash
# v69 — clasa de bug "raw fara PTS → matroska" (documentare functionala + canar).
#   Muxerul matroska/webm CERE PTS; elementary streams video cu REORDERING
#   (HEVC/H.264 annexb cu B-frames) nu au PTS derivabil → "Can't write packet
#   with unknown timestamp" → output gol. Guard-urile (pas intermediar MP4)
#   exista in: triple-layer (av_common + av_encode.ps1), _hdv_combine (+PS1),
#   av_mux Mux (+PS1) — asserts in test_v69_source_invariants sectiunea H.
#   ACEST test documenteaza CLASA empiric:
#     - hevc+bframes → mkv ESUEAZA (CANAR: daca un ffmpeg viitor incepe sa
#       mearga, assert-ul pica → semnal ca guard-urile pot deveni obsolete)
#     - hevc → mp4 OK (fundatia rutei de wrap)
#     - IVF → mkv OK (AV1/IVF poarta PTS — imun)
#     - audio raw (aac/ac3) → mkv OK (durata fixa de frame → PTS derivabil —
#       fluxurile audio/av_encoder_audio sunt IMUNE prin natura)
#     - APV `-f apv -framerate` → mkv OK (premisa helper-ului APV inject)
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"
command -v ffmpeg >/dev/null 2>&1 || { skip_test "ffmpeg lipseste"; }

tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"; _test_summary' EXIT

# ── streamuri raw minuscule ──────────────────────────────────────────
ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=128x128:rate=10" \
    -c:v libx265 -x265-params log-level=none:bframes=2 -preset ultrafast -f hevc "$tmpd/t.hevc" 2>/dev/null
ffmpeg -v error -y -f lavfi -i "sine=frequency=440:duration=1" -c:a aac -f adts "$tmpd/t.aac" 2>/dev/null
ffmpeg -v error -y -f lavfi -i "sine=frequency=440:duration=1" -c:a ac3 -f ac3 "$tmpd/t.ac3" 2>/dev/null
[[ -s "$tmpd/t.hevc" ]] || { skip_test "x265 indisponibil"; }

_size() { stat -c%s "$1" 2>/dev/null || echo 0; }

# ── 1. CANAR: hevc raw (cu B-frames) → mkv trebuie sa ESUEZE/gol ─────
ffmpeg -v error -y -i "$tmpd/t.hevc" -c copy "$tmpd/o1.mkv" 2>/dev/null || true
assert_eq "1" "$([[ $(_size "$tmpd/o1.mkv") -lt 5000 ]] && echo 1 || echo 0)" \
    "CANAR clasa: hevc raw (bframes) → mkv = gol/esec ($(_size "$tmpd/o1.mkv")B; daca pica: ffmpeg a reparat clasa → re-evalueaza guard-urile MP4-step)"

# ── 2. hevc raw → mp4 OK (fundatia wrap-ului) ────────────────────────
ffmpeg -v error -y -i "$tmpd/t.hevc" -c copy -tag:v hvc1 "$tmpd/o2.mp4" 2>/dev/null
assert_eq "1" "$([[ $(_size "$tmpd/o2.mp4") -gt 5000 ]] && echo 1 || echo 0)" "hevc raw → mp4 functioneaza ($(_size "$tmpd/o2.mp4")B)"

# ── 3. ruta de wrap completa: raw → mp4 → mkv OK ─────────────────────
ffmpeg -v error -y -i "$tmpd/o2.mp4" -c copy "$tmpd/o3.mkv" 2>/dev/null
assert_eq "1" "$([[ $(_size "$tmpd/o3.mkv") -gt 5000 ]] && echo 1 || echo 0)" "ruta wrap (raw→mp4→mkv) functioneaza ($(_size "$tmpd/o3.mkv")B)"

# ── 4. audio raw → mkv OK (fluxurile audio IMUNE) ────────────────────
ffmpeg -v error -y -i "$tmpd/t.aac" -c copy "$tmpd/o4.mkv" 2>/dev/null
assert_eq "1" "$([[ $(_size "$tmpd/o4.mkv") -gt 2000 ]] && echo 1 || echo 0)" "audio raw aac → mkv OK — audio imun (PTS din durata fixa)"
ffmpeg -v error -y -i "$tmpd/t.ac3" -c copy "$tmpd/o5.mkv" 2>/dev/null
assert_eq "1" "$([[ $(_size "$tmpd/o5.mkv") -gt 2000 ]] && echo 1 || echo 0)" "audio raw ac3 → mkv OK"

# ── 5. APV `-f apv -framerate` → mkv OK (premisa helper-ului inject) ─
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -qw liboapv; then
    ffmpeg -v error -y -f lavfi -i "testsrc2=duration=0.5:size=160x128:rate=10" \
        -c:v liboapv -qp 45 -pix_fmt yuv422p10le -f apv "$tmpd/t.apv" 2>/dev/null
    ffmpeg -v error -y -f apv -framerate 10 -i "$tmpd/t.apv" -c copy "$tmpd/o6.mkv" 2>/dev/null
    assert_eq "1" "$([[ $(_size "$tmpd/o6.mkv") -gt 5000 ]] && echo 1 || echo 0)" "APV raw (-f apv -framerate) → mkv OK — intra-only, PTS generat ($(_size "$tmpd/o6.mkv")B)"
else
    echo "  (APV sarit: liboapv lipseste)"
fi
true
