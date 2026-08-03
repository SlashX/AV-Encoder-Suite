#!/usr/bin/env bash
# v94 (B11) — cai/LUT-uri cu SPATII in comanda ffmpeg (bash).
#
# Bug-ul B11 e PS1-only (`Start-Process -ArgumentList <array>` uneste fara citare) —
# vezi test_v94_argline.ps1. Bash-ul e sigur, dar NU accidental: pe calea de encode
# comanda trece prin `eval $FFMPEG_CMD`, iar caile intra in filtre intre GHILIMELE
# SIMPLE (`lut3d='<cale>'`), pe care `eval` le respecta → calea ramane UN singur
# argument chiar cu spatii in ea. Testul asta pazeste exact acea proprietate: daca
# cineva scoate ghilimelele la o refactorizare, LUT-urile reale (ex. cel livrat de DJI:
# „DJI OSMO Action 6 D-LogM to Rec.709 LUT-11.17.cube") ar rupe encode-ul.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="$PROJECT_ROOT/src"

# ── 1. Toate lantul-urile lut3d din src citeaza calea ────────────────
# Forma acceptata: lut3d='...' (ghilimele simple in interiorul stringului de filtru).
# Se ignora liniile de comentariu (grep -n prefixeaza cu fisier:linie: → taiem prefixul).
bad=$(grep -rn "lut3d=" "$SRC"/*.sh | sed 's/^[^:]*:[0-9]*://' \
      | grep -v '^[[:space:]]*#' | grep -v "lut3d='" || true)
assert_eq "" "$bad" "toate lantele lut3d din bash citeaza calea (lut3d='...')"

# Filtrele de subtitrare din burn-in: forma reala e subtitles='...' / ass='...'
# (calea trece si prin escape_ffmpeg_filter_path). Verificam POZITIV ca forma citata
# exista — o refactorizare care ar scoate ghilimelele ar face testul sa pice.
burn="$SRC/av_burnin.sh"
assert_match "$(grep -c "subtitles='" "$burn")" '^[1-9]' "burn-in: filtrul subtitles citeaza calea"
assert_match "$(grep -c "ass='"       "$burn")" '^[1-9]' "burn-in: filtrul ass citeaza calea"

# ── 2. eval NU sparge o cale cu spatii aflata intre ghilimele simple ─
# Reproduce exact forma construita de handle_log_dialog.
LUT="/tmp/lut dir/DJI OSMO Action 6 D-LogM to Rec.709 LUT-11.17.cube"
LOG_VIDEO_FILTER="lut3d='$LUT',format=yuv420p10le,setparams=color_primaries=bt709"
VIDEO_FILTER="-vf $LOG_VIDEO_FILTER"
n_args=$(eval "set -- $VIDEO_FILTER; echo \$#")
assert_eq "2" "$n_args" "eval pastreaza calea spatiata ca UN singur argument"

got=$(eval "set -- $VIDEO_FILTER; echo \$2")
assert_eq "lut3d=$LUT,format=yuv420p10le,setparams=color_primaries=bt709" "$got" \
    "argumentul ajunge intreg la ffmpeg (spatiile pastrate)"

# CANAR: fara ghilimele simple, aceeasi cale s-ar rupe in 7 argumente.
VIDEO_FILTER_RAW="-vf lut3d=$LUT,format=yuv420p10le"
n_raw=$(eval "set -- $VIDEO_FILTER_RAW; echo \$#")
assert_eq "1" "$([ "$n_raw" -gt 2 ] && echo 1 || echo 0)" \
    "CANAR: fara ghilimele calea se rupe ($n_raw argumente)"

# ── 3. Functional: encode real pe fisier cu spatiu in nume ──────────
if ! command -v ffmpeg >/dev/null 2>&1; then
    if [ -x "$SRC/ffmpeg.exe" ] || [ -x "$SRC/ffmpeg" ]; then export PATH="$SRC:$PATH"; fi
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "  (functional sarit — ffmpeg lipseste)"
else
    tmpd=$(mktemp -d)
    trap 'rm -rf "$tmpd"; _test_summary' EXIT
    src_f="$tmpd/my clip.mp4"
    dst_f="$tmpd/out A.mkv"
    ffmpeg -v error -y -f lavfi -i "testsrc2=s=160x120:r=10:d=1" -c:v libx264 -preset ultrafast "$src_f" 2>/dev/null
    assert_file_exists "$src_f" "fixture cu spatiu in nume creat"
    # forma reala din suita: comanda construita ca string + eval
    FFMPEG_CMD="ffmpeg -v error -y -i \"$src_f\" -c:v libx264 -preset ultrafast \"$dst_f\""
    eval "$FFMPEG_CMD" 2>/dev/null
    assert_zero $? "eval pe comanda cu cai spatiate → ffmpeg rc=0"
    assert_file_exists "$dst_f" "output cu spatiu in nume scris"
fi
