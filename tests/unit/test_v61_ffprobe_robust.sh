#!/usr/bin/env bash
# v61 audit: paritate bash a fix-ului PS1 Get-FFprobeValue / Get-SourceCodec.
# Bash citea deja single-field v:0 cu default= + head -1 (fara trailing comma, fara
# dublare DJI) PESTE TOT, cu o exceptie: detect_source_codec nu avea head -1 → pe DJI
# Action 6 (`-select_streams v:0` raporteaza streamul de 2 ori) intorcea "hevc\nhevc".
# Acest test blindeaza: (1) detect_source_codec foloseste head -1, (2) functional pe
# o sursa HDR10 reala codec/transfer ies curate (fara trailing comma).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="$PROJECT_ROOT/src"
COMMON_SRC="$(cat "$SRC/av_common.sh")"

# ── 1. Source-level: detect_source_codec foloseste default= + head -1 ──
dsc="$(awk '/^detect_source_codec\(\)/,/^}/' "$SRC/av_common.sh")"
assert_contains "$dsc" "default=noprint_wrappers=1:nokey=1" "detect_source_codec foloseste default= (nu csv=p=0)"
assert_contains "$dsc" "head -1" "detect_source_codec ia prima linie (head -1) — DJI v:0 dublu-listat"

# ── 1b. v63: probe_video_signature (av_trimconcat.sh) ia primul stream (head -5) ──
# -select_streams v:0 dublu-listat pe DJI Action 6 → signature multi-field (paste) se dubla
# ("hevc|..|hevc|..") → un clip DJI vs unul non-DJI de ACELASI format ieseau "diferite" →
# fals incompat → re-encode in loc de stream-copy la concat. head -5 = primul stream (5 campuri).
pvs="$(awk '/^probe_video_signature\(\)/,/^}/' "$SRC/av_trimconcat.sh")"
assert_contains "$pvs" "codec_name,width,height,r_frame_rate,pix_fmt" "probe_video_signature: 5 campuri"
assert_contains "$pvs" "head -5" "probe_video_signature ia primul stream (head -5) — DJI v:0 dublu"

# ── 1c. v63: av_encoder_audio.sh — gate-ul webm SRC_VCODEC ia prima linie (head -1) ──
svc="$(grep -A1 'SRC_VCODEC=$(ffprobe' "$SRC/av_encoder_audio.sh")"
assert_contains "$svc" "head -1" "SRC_VCODEC (webm gate) ia prima linie — DJI v:0 dublu / CRLF"

# ── 2. Functional: HDR10 real → codec/transfer curate (fara trailing comma) ──
if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
    skip_test "ffmpeg/ffprobe lipsesc — sar testul functional"
fi

tmp="$(mktemp -u).mp4"
ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=320x240:rate=30" \
    -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast -tag:v hvc1 \
    -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
    -x265-params "hdr10=1:hdr10-opt=1:repeat-headers=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400" \
    -an "$tmp" 2>/dev/null

if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    skip_test "nu am putut genera sample HDR10 (libx265?)"
fi

codec="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 "$tmp" 2>/dev/null | head -1)"
transfer="$(ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer \
    -of default=noprint_wrappers=1:nokey=1 "$tmp" 2>/dev/null | head -1)"
width="$(ffprobe -v error -select_streams v:0 -show_entries stream=width \
    -of default=noprint_wrappers=1:nokey=1 "$tmp" 2>/dev/null | head -1)"

assert_eq "hevc" "$codec" "codec_name curat (fara trailing comma)"
assert_eq "smpte2084" "$transfer" "color_transfer = smpte2084 (comma ar fi spart == )"
assert_eq "320" "$width" "width = 320 exact (fara comma)"

rm -f "$tmp"
# _test_summary se ruleaza automat via `trap ... EXIT` din framework.sh
