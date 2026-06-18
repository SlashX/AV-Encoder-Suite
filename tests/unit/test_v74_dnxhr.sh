#!/usr/bin/env bash
# v74: DNxHR polish — (F1) av_check afiseaza profilul DNxHR din campul ffprobe `profile`
#   (DNXHR LB/SQ/HQ/HQX/444; codec_tag e [0][0][0][0], inutil); (F2) comentarii de culoare
#   corectate (8-bit: bt2020 -> unknown pe MOV [pastrat pe MXF], NU "bt709"; "master-display
#   pastrat" in loc de "MaxCLL pastrate" — MaxCLL e dropat de MXF, master-display e universal).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"
CHK=$(cat "$SCRIPT_DIR/av_check.sh")
ENCD=$(cat "$SCRIPT_DIR/av_encoder_dnxhr.sh")

# ── F1: av_check — profil DNxHR din campul `profile` ────────────────────
assert_contains "$CHK" 'dnxhr_prof="${7:-}"'                  "F1: get_source_format primeste dnxhr_prof (arg 7)"
assert_contains "$CHK" '"DNXHR LB")  fmt="Avid DNxHR LB"'     "F1: DNXHR LB -> Avid DNxHR LB"
assert_contains "$CHK" '"DNXHR HQ")  fmt="Avid DNxHR HQ"'     "F1: DNXHR HQ -> Avid DNxHR HQ"
assert_contains "$CHK" '"DNXHR HQX") fmt="Avid DNxHR HQX"'    "F1: DNXHR HQX"
assert_contains "$CHK" '"DNXHR 444") fmt="Avid DNxHR 444"'    "F1: DNXHR 444"
assert_contains "$CHK" '[[ "$SRC_CODEC" == "dnxhd" ]] && _dnxhr_prof=' "F1: profil probat doar pe dnxhd (stream=profile)"

# ── F2: comentarii de culoare corectate ─────────────────────────────────
_b709=0; echo "$ENCD" | grep -q "bt2020 devine bt709" && _b709=1
assert_eq "0" "$_b709"                                       "F2: claim-ul gresit 'bt2020 devine bt709' ELIMINAT"
assert_contains "$ENCD" 'bt2020 -> unknown'                  "F2: forma corecta (bt2020 -> unknown pe MOV)"
assert_contains "$ENCD" 'master-display pastrat'             "F2: 'master-display pastrat' (universal, nu MaxCLL)"
_mcll=0; echo "$ENCD" | grep -q "MaxCLL pastrate" && _mcll=1
assert_eq "0" "$_mcll"                                       "F2: overstatement 'MaxCLL pastrate' ELIMINAT"

# ── Functional (guarded): campul `profile` expune profilul + pix_fmt per profil ──
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    td=$(mktemp -d)
    SRC="-f lavfi -i testsrc=size=640x360:rate=25 -t 1"
    ffmpeg -y -v error $SRC -c:v dnxhd -profile:v dnxhr_hq -pix_fmt yuv422p -an "$td/hq.mxf" 2>/dev/null
    prof=$(ffprobe -v error -select_streams v:0 -show_entries stream=profile -of default=noprint_wrappers=1:nokey=1 "$td/hq.mxf" 2>/dev/null | head -1 | tr -d '\r')
    assert_eq "DNXHR HQ" "$prof" "functional F1: dnxhr_hq -> profile 'DNXHR HQ'"
    ffmpeg -y -v error $SRC -c:v dnxhd -profile:v dnxhr_hqx -pix_fmt yuv422p10le -an "$td/hqx.mxf" 2>/dev/null
    pf=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=noprint_wrappers=1:nokey=1 "$td/hqx.mxf" 2>/dev/null | head -1 | tr -d '\r')
    assert_eq "yuv422p10le" "$pf" "functional: HQX -> 10-bit yuv422p10le"
    ffmpeg -y -v error $SRC -c:v dnxhd -profile:v dnxhr_444 -pix_fmt yuv444p10le -an "$td/444.mxf" 2>/dev/null
    pf4=$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=noprint_wrappers=1:nokey=1 "$td/444.mxf" 2>/dev/null | head -1 | tr -d '\r')
    assert_eq "yuv444p10le" "$pf4" "functional: 444 -> 10-bit yuv444p10le"
    rm -rf "$td"
else
    echo "  (info: ffmpeg/ffprobe indisponibil — sar functionalul, source-level ruleaza)"
fi
