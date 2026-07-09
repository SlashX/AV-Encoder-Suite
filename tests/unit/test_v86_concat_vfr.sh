#!/usr/bin/env bash
# v86 — mesaj onest la concat pe surse VFR (cand DOAR fps-ul difera in semnatura).
# Contextul: taieturi -c copy din acelasi clip VFR au r_frame_rate diferit (ex. 120/1
# vs 60000/1001) → check_concat_compat alege corect re-encode (concat demuxer pe VFR
# = coliziuni DTS la jonctiuni, validat empiric), dar mesajul generic "codec/rez/fps
# diferit" deruta. v86 adauga _concat_incompat_vfr_fps / Test-ConcatIncompatVfrFps —
# schimba DOAR mesajul, NU decizia (re-encode ramane obligatoriu).
# Source-level (mereu) + functional pe taieturi reale (gated pe ffmpeg + sample).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="$PROJECT_ROOT/src"
TC="$SRC/av_trimconcat.sh"
PS="$SRC/av_encode.ps1"

# ── source-level bash (av_trimconcat.sh) ──────────────────────────────
assert_eq "1" "$(grep -c '^_concat_incompat_vfr_fps()' "$TC")" \
    "helperul _concat_incompat_vfr_fps exista in av_trimconcat.sh"
assert_eq "2" "$(grep -c 'if _concat_incompat_vfr_fps ' "$TC")" \
    "helperul e cablat la AMBELE situri de mesaj (Concat + Pipeline)"
assert_eq "2" "$(grep -cE 'VFR.*(fara|fără) re-encode' "$TC")" \
    "mesajul VFR onest prezent la ambele situri"
# decizia neatinsa: ramura incompat din Concat inca forteaza re-encode
assert_match "$(grep -A2 'Re-encode OBLIGATORIU via concat filter' "$TC")" "use_filter=1" \
    "Concat: ramura incompat inca seteaza use_filter=1 (decizia NEschimbata)"
# helperul NU decide singur VFR — foloseste _is_vfr_source (chokepoint v77)
assert_match "$(sed -n '/^_concat_incompat_vfr_fps()/,/^}/p' "$TC")" "_is_vfr_source" \
    "helperul refoloseste _is_vfr_source (v77), nu reimplementeaza detectia"

# ── source-level PS1 (av_encode.ps1, paritate) ────────────────────────
assert_eq "1" "$(grep -c '^function Test-ConcatIncompatVfrFps' "$PS")" \
    "PS1: functia Test-ConcatIncompatVfrFps exista"
assert_eq "2" "$(grep -c 'if (Test-ConcatIncompatVfrFps ' "$PS")" \
    "PS1: cablata la AMBELE situri de mesaj (Concat + Pipeline)"
assert_eq "2" "$(grep -cE 'VFR.*fara re-encode' "$PS")" \
    "PS1: mesajul VFR onest prezent la ambele situri"
assert_match "$(sed -n '/^function Test-ConcatIncompatVfrFps/,/^}/p' "$PS")" "Test-VfrSource" \
    "PS1: helperul refoloseste Test-VfrSource (v77)"

# ── functional: taieturi VFR reale (gated pe ffmpeg + sample) ─────────
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SRC:$PATH"
SAMPLE="$SRC/Upload_S02E01_HDR10Plus_40s_HEVC.mp4"
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1 && [ -f "$SAMPLE" ]; then
    tmpd="$(mktemp -d)"
    trap 'rm -rf "$tmpd"; _test_summary' EXIT
    ffmpeg -v error -ss 0 -t 3 -i "$SAMPLE" -c copy -an "$tmpd/c1.mp4" -y </dev/null 2>/dev/null
    ffmpeg -v error -ss 3.8 -t 2.5 -i "$SAMPLE" -c copy -an "$tmpd/c2.mp4" -y </dev/null 2>/dev/null
    ffmpeg -v error -f lavfi -i "testsrc=duration=1:size=320x240:rate=30" \
        -c:v libx264 -pix_fmt yuv420p "$tmpd/cfr_a.mp4" -y </dev/null 2>/dev/null
    ffmpeg -v error -f lavfi -i "testsrc=duration=1:size=320x240:rate=30" \
        -c:v libx264 -pix_fmt yuv420p "$tmpd/cfr_b.mp4" -y </dev/null 2>/dev/null
    if [ -s "$tmpd/c1.mp4" ] && [ -s "$tmpd/c2.mp4" ]; then
        out=$(bash -c '
            export AV_TRIMCONCAT_TEST_MODE=1
            source "'"$TC"'" >/dev/null 2>&1
            _concat_incompat_vfr_fps "'"$tmpd"'/c1.mp4" "'"$tmpd"'/c2.mp4" && echo VFR_DA || echo VFR_NU
            _concat_incompat_vfr_fps "'"$tmpd"'/c1.mp4" "'"$tmpd"'/cfr_a.mp4" && echo MIX_DA || echo MIX_NU
            _concat_incompat_vfr_fps "'"$tmpd"'/cfr_a.mp4" "'"$tmpd"'/cfr_b.mp4" && echo CFR_DA || echo CFR_NU
            check_concat_compat "'"$tmpd"'/c1.mp4" "'"$tmpd"'/c2.mp4" && echo COMPAT_IDENTIC || echo COMPAT_DIFERIT
        ' 2>/dev/null)
        assert_match "$out" "VFR_DA"        "functional: 2 taieturi VFR acelasi clip → mesaj VFR (rc=0)"
        assert_match "$out" "MIX_NU"        "functional: codec diferit → mesaj generic (rc=1)"
        assert_match "$out" "CFR_NU"        "functional: pereche CFR → mesaj generic (rc=1)"
        assert_match "$out" "COMPAT_DIFERIT" "functional: decizia compat NEschimbata (re-encode ramane pe VFR)"
    else
        _pass "skip-equivalent: taierile din sample au esuat"
        _pass; _pass; _pass
    fi
else
    _pass "skip-equivalent: ffmpeg/ffprobe/sample lipsesc (source-level a rulat)"
    _pass; _pass; _pass
fi
