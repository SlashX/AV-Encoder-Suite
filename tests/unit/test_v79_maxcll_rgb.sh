#!/usr/bin/env bash
# v79 — MaxCLL/MaxFALL RGB-precis (CTA-861.3): max(R,G,B) per pixel via extractplanes+blend lighten,
#   inlocuieste masurarea luma-based (v63) care subestima highlight-urile colorate (rosu/albastru).
#   ACEEASI functie + hook-uri (HLG->HDR10, HDR10-preserve) — doar filtergraph-ul intern se schimba.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"

COMMON="$(cat "$SCRIPT_DIR/av_common.sh")"
ENC_PS1="$(cat "$SCRIPT_DIR/av_encode.ps1")"

# ── 1. Source-level: lant RGB-precis prezent in AMBELE (santinela anti-revert la luma) ──
assert_contains "$COMMON"  "extractplanes=r+g+b"        "bash: extractplanes R/G/B"
assert_contains "$COMMON"  "blend=all_mode=lighten"     "bash: blend lighten = max(R,G,B)"
assert_contains "$COMMON"  "format=gbrp16le"            "bash: liniarizare in RGB 16-bit"
assert_not_contains "$COMMON" "format=yuv444p16le"      "bash: luma-based scos (anti-revert)"
assert_contains "$ENC_PS1" "extractplanes=r+g+b"        "PS1: extractplanes R/G/B"
assert_contains "$ENC_PS1" "blend=all_mode=lighten"     "PS1: blend lighten = max(R,G,B)"
assert_contains "$ENC_PS1" "format=gbrp16le"            "PS1: liniarizare in RGB 16-bit"
assert_not_contains "$ENC_PS1" "format=yuv444p16le"     "PS1: luma-based scos (anti-revert)"

# ── 2. Paritate: signalstats neschimbat (vede planul max(R,G,B) ca "luma") ──
assert_contains "$COMMON"  "signalstats,metadata=print" "bash: signalstats pe planul max(R,G,B)"
assert_contains "$ENC_PS1" "signalstats,metadata=print" "PS1: signalstats pe planul max(R,G,B)"

# ── 3. Functional: albastru saturat PQ → RGB-precis > luma (dovedeste ca NU e luma) ──
#    luma(Y) al albastrului ~6% din varf, max(R,G,B)=B mare → RGB >> luma. Sursa FARA alb
#    (altfel varful luma == varful max(R,G,B) si inegalitatea stricta ar cadea).
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    source "$SCRIPT_DIR/av_common.sh" 2>/dev/null
    tmpd="$(mktemp -d)"; blue="$tmpd/blue_pq.mp4"
    ffmpeg -v error -y -f lavfi -i "color=c=blue:s=320x240:r=10:d=1" \
        -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast \
        -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:log-level=none" \
        -an "$blue" 2>/dev/null
    if [[ -s "$blue" ]]; then
        # RGB-precis = functia REALA (acum RGB)
        measure_hdr10_cll "$blue" 2>/dev/null; rgb_cll="${HDR10_MEASURED_CLL:-0}"
        # luma-based = lant vechi inline (referinta de comparatie)
        luma_cll=$(ffmpeg -hide_banner -v error -i "$blue" \
            -vf "zscale=t=linear:npl=10000,format=yuv444p16le,signalstats,metadata=print:file=-" \
            -an -f null - 2>/dev/null | awk -F= '/YMAX=/{v=$2+0; if(v>m)m=v} END{ printf "%d", int(m/65535*10000+0.5) }')
        if [[ "${rgb_cll:-0}" -gt 0 && "${luma_cll:-0}" -gt 0 ]]; then
            if [[ "$rgb_cll" -gt "$luma_cll" ]]; then
                assert_eq "1" "1" "functional: RGB-precis ($rgb_cll) > luma ($luma_cll) pe albastru saturat"
            else
                assert_eq "RGB>luma" "RGB=$rgb_cll luma=$luma_cll" "functional: RGB-precis trebuie sa depaseasca luma"
            fi
        fi
    fi
    rm -rf "$tmpd"
fi
true
