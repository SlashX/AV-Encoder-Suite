#!/usr/bin/env bash
# v74: APV polish — (G3) av_check afiseaza profilul APV din campul ffprobe `profile`
#   (numeric 33/44/55/66/77/88 → chroma + bit-depth; codec_tag e apv1, inutil); + profilul
#   4444_12 (yuva444p12le, profil 88) adaugat in encoder/dialog/schema (ffmpeg liboapv il
#   suporta; lipsea — 422 si 444 aveau 10 SI 12-bit, 4444 doar 10). Source-level + functional.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"
CHK=$(cat "$SCRIPT_DIR/av_check.sh")
ENCA=$(cat "$SCRIPT_DIR/av_encoder_apv.sh")
LAUNCH=$(cat "$SCRIPT_DIR/av_launcher.sh")
COMMON=$(cat "$SCRIPT_DIR/av_common.sh")

# ── G3: av_check — profil APV din campul `profile` (numeric) ─────────────
assert_contains "$CHK" 'apv_prof="${8:-}"'                       "G3: get_source_format primeste apv_prof (arg 8)"
assert_contains "$CHK" '33) fmt="Samsung APV 4:2:2 10-bit"'      "G3: profil 33 -> 4:2:2 10-bit"
assert_contains "$CHK" '55) fmt="Samsung APV 4:4:4 10-bit"'      "G3: profil 55 -> 4:4:4 10-bit"
assert_contains "$CHK" '88) fmt="Samsung APV 4:4:4:4 12-bit"'    "G3: profil 88 -> 4:4:4:4 12-bit"
assert_contains "$CHK" '[[ "$SRC_CODEC" == "apv" ]] && _apv_prof=' "G3: profil probat doar pe apv (stream=profile)"

# ── 4444_12: encoder + dialog + schema ──────────────────────────────────
assert_contains "$ENCA"   '4444_12) pixfmt="yuva444p12le"'       "4444_12: encoder pixfmt yuva444p12le"
assert_contains "$LAUNCH" '6) APV_PIXFMT="4444_12"'              "4444_12: dialog launcher optiune 6"
assert_contains "$COMMON" '4444_10,4444_12'                      "4444_12: schema bash include 4444_12"

# ── Functional (guarded): profile numbers + 4444_12 pix_fmt ─────────────
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1 \
   && ffmpeg -hide_banner -encoders 2>/dev/null | grep -qw liboapv; then
    td=$(mktemp -d)
    SRC="-f lavfi -i testsrc=size=320x240:rate=25 -t 1"
    ffmpeg -y -v error $SRC -c:v liboapv -pix_fmt yuv422p10le "$td/a.mp4" 2>/dev/null
    p1=$(ffprobe -v error -select_streams v:0 -show_entries stream=profile -of default=nw=1:nk=1 "$td/a.mp4" 2>/dev/null | head -1 | tr -d '\r')
    assert_eq "33" "$p1" "functional G3: 422-10 -> profile 33"
    ffmpeg -y -v error $SRC -c:v liboapv -pix_fmt yuva444p12le "$td/f.mp4" 2>/dev/null
    p8=$(ffprobe -v error -select_streams v:0 -show_entries stream=profile -of default=nw=1:nk=1 "$td/f.mp4" 2>/dev/null | head -1 | tr -d '\r')
    pf=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=nw=1:nk=1 "$td/f.mp4" 2>/dev/null | head -1 | tr -d '\r')
    assert_eq "88" "$p8" "functional: 4444_12 (yuva444p12le) -> profile 88"
    assert_eq "yuva444p12le" "$pf" "functional: 4444_12 -> pix_fmt yuva444p12le"
    rm -rf "$td"
else
    echo "  (info: ffmpeg/liboapv indisponibil — sar functionalul, source-level ruleaza)"
fi
