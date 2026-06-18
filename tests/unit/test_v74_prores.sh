#!/usr/bin/env bash
# v74: ProRes polish — (B) av_check afiseaza profilul din codec_tag (apco/apch/ap4h/ap4x);
#   (A) 4444/XQ pastreaza alpha DOAR daca sursa o are (altfel yuv444p10le); (C) container
#   mov SAU mxf (broadcast/Avid, audio PCM prin regula MXF=PCM gardata pe container).
#   Source-level + functional (encode testsrc, guarded pe ffmpeg).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
# ffmpeg/ffprobe: global sau bundle-uit in src/ (Windows testing)
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"
CHK=$(cat "$SCRIPT_DIR/av_check.sh")
ENCPR=$(cat "$SCRIPT_DIR/av_encoder_prores.sh")
LAUNCH=$(cat "$SCRIPT_DIR/av_launcher.sh")

# ── B: av_check — profil ProRes din codec_tag (FourCC) ──────────────────
assert_contains "$CHK" 'codec_tag="${6:-}"'              "B: get_source_format primeste codec_tag (arg 6)"
assert_contains "$CHK" 'apco) fmt="Apple ProRes Proxy"'  "B: apco -> Proxy"
assert_contains "$CHK" 'apch) fmt="Apple ProRes HQ"'     "B: apch -> HQ"
assert_contains "$CHK" 'ap4h) fmt="Apple ProRes 4444"'   "B: ap4h -> 4444"
assert_contains "$CHK" 'ap4x) fmt="Apple ProRes 4444 XQ"' "B: ap4x -> 4444 XQ"
assert_contains "$CHK" '[[ "$SRC_CODEC" == "prores" ]] && _prores_tag=' "B: codec_tag probat doar pe prores"

# ── A: encoder — 4444/XQ alpha-aware ────────────────────────────────────
assert_contains "$ENCPR" '_4444_pf="yuv444p10le"'             "A: 4444 default FARA alpha"
assert_contains "$ENCPR" 'yuva*|ya8*|ya16*|*rgba*'            "A: detectie alpha pe pix_fmt sursa"
assert_contains "$ENCPR" 'pixfmt="$_4444_pf"'                 "A: 4444/XQ folosesc pixfmt-ul alpha-aware"

# ── C: launcher — ProRes ofera mov/mxf ──────────────────────────────────
assert_contains "$LAUNCH" 'Format container output (ProRes)'  "C: ProRes dialog container"
assert_contains "$LAUNCH" '2) CONTAINER="mxf"'                "C: ProRes optiune mxf"
# regula MXF=PCM e gardata pe container (acopera si ProRes), NU pe encoder
assert_contains "$LAUNCH" '"$CONTAINER" == "mxf" ]] && [[ "$AUDIO_CODEC_ARG" != pcm:*' "C: MXF=PCM gardat pe container"

# ── A logic: decizie alpha pe pix_fmt (determinist, fara ffmpeg) ────────
_chk(){ case "$1" in yuva*|ya8*|ya16*|*rgba*|*argb*|*abgr*|*bgra*|*gbrap*|pal8) echo alpha;; *) echo noalpha;; esac; }
assert_eq "noalpha" "$(_chk yuv420p)"      "A logic: yuv420p -> no alpha"
assert_eq "noalpha" "$(_chk yuv422p10le)"  "A logic: yuv422p10le -> no alpha"
assert_eq "noalpha" "$(_chk gray)"         "A logic: gray -> no alpha"
assert_eq "alpha"   "$(_chk yuva444p10le)" "A logic: yuva444p10le -> alpha"
assert_eq "alpha"   "$(_chk rgba)"         "A logic: rgba -> alpha"

# ── Functional (guarded pe ffmpeg): codec_tag profil + ProRes->MXF + 4444 no-alpha ──
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    td=$(mktemp -d)
    SRC="-f lavfi -i testsrc=size=320x240:rate=25 -t 1"   # rate standard (MXF respinge rate non-standard)
    # B: HQ -> codec_tag apch
    ffmpeg -y -v error $SRC -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le -vendor apl0 -an "$td/hq.mov" 2>/dev/null
    tag=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_tag_string -of default=noprint_wrappers=1:nokey=1 "$td/hq.mov" 2>/dev/null | head -1 | tr -d '\r')
    assert_eq "apch" "$tag" "functional B: ProRes HQ -> codec_tag apch"
    # C: ProRes -> MXF reuseste
    ok=0; ffmpeg -y -v error $SRC -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le -an "$td/hq.mxf" 2>/dev/null && [ -s "$td/hq.mxf" ] && ok=1
    assert_eq "1" "$ok" "functional C: ProRes -> MXF reuseste"
    # A: 4444 dintr-o sursa fara alpha cu yuv444p10le -> output FARA plan alpha
    ffmpeg -y -v error $SRC -c:v prores_ks -profile:v 4 -pix_fmt yuv444p10le -vendor apl0 -an "$td/4444.mov" 2>/dev/null
    opf=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=noprint_wrappers=1:nokey=1 "$td/4444.mov" 2>/dev/null | head -1 | tr -d '\r')
    case "$opf" in yuva*) _a="alpha";; *) _a="noalpha";; esac
    assert_eq "noalpha" "$_a" "functional A: 4444 sursa fara alpha -> output $opf (fara alpha)"
    rm -rf "$td"
else
    echo "  (info: ffmpeg/ffprobe indisponibil — sar functionalul, source-level ruleaza)"
fi
