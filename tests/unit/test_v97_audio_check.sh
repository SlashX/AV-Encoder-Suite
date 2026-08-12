#!/usr/bin/env bash
# v97 — av_check accepta si fisiere DOAR-audio.
#
# Pana acum orice fisier fara pista video era sarit ("nu s-a gasit stream video valid"),
# deci ce produce meniul 2 (audio-only, inclusiv Eclipsa/IAMF) nu putea fi verificat cu
# meniul 3. Acum se analizeaza, iar campurile video ies "N/A" ONEST — inclusiv cele care
# altfel ar iesi plauzibile dar false: rezolutia "x", bitrate-ul containerului atribuit
# video, si "SDR" pe un fisier care n-are imagine.
#
# Regresia pe fisierele video e la fel de importanta ca functionalitatea noua: un fisier
# cu imagine trebuie sa iasa EXACT ca inainte.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"
AVC="$SCRIPT_DIR/av_check.sh"
PSC="$SCRIPT_DIR/av_check.ps1"

# ── source-level: bash ───────────────────────────────────────────────
assert_match "$(grep '^FILES=' "$AVC")" 'm4a' "glob-ul de intrare include formate audio native"
assert_match "$(grep 'OUT_FILES=' "$AVC")" 'flac' "si lista de output (comparatia input↔output)"
assert_match "$(cat "$AVC")" 'AUDIO_ONLY_FILE=1' "exista modul audio-only"
assert_match "$(cat "$AVC")" 'fara stream video sau audio valid' \
    "se sare doar ce n-are NICI audio, NICI video"
_norm=$(sed -n '/v97: pe un fisier DOAR-audio/,/^    fi$/p' "$AVC")
for f in 'RESOLUTION_STR="N/A"' 'PIX_FMT="N/A"' 'BITRATE_MB="N/A"' 'TYPE="N/A"'; do
    assert_match "$_norm" "$f" "audio-only: ${f%%=*} devine N/A"
done
assert_match "$(cat "$AVC")" 'ENC_REC="N/A"' "recomandarea de encoder video devine N/A pe audio"
assert_match "$(cat "$AVC")" 'Audio — ' "Format_sursa foloseste liniuta (codecul poate purta deja paranteze)"
# rezolutia trebuie sa treaca prin variabila, altfel normalizarea n-ar ajunge in CSV
# (NB: `RESOLUTION_STR="${WIDTH}x${HEIGHT}"` e chiar ATRIBUIREA — se cauta in linia printf)
assert_match "$(grep -A6 'FILENAME_CSV=' "$AVC")" 'RESOLUTION_STR' \
    "randul CSV foloseste RESOLUTION_STR (deci normalizarea audio ajunge in raport)"

# ── source-level: PS1 (paritate) ─────────────────────────────────────
assert_match "$(grep 'inputFiles = ' "$PSC")" 'm4a' "PS1: glob-ul include formate audio native"
assert_match "$(grep 'outFiles = ' "$PSC")" 'flac' "PS1: si lista de output"
assert_match "$(cat "$PSC")" 'audioOnlyFile = \$true' "PS1: exista modul audio-only"
assert_match "$(cat "$PSC")" 'fara stream video sau audio valid' "PS1: acelasi mesaj de skip"
assert_match "$(cat "$PSC")" 'resStr = "N/A"' "PS1: rezolutia devine N/A"
assert_match "$(cat "$PSC")" 'Audio — ' "PS1: acelasi format 'Audio — codec'"
assert_eq "0" "$(grep -c '`"${w}x${h}`"' "$PSC")" "PS1: CSV-ul foloseste resStr, nu constructia inline"

# ── functional ───────────────────────────────────────────────────────
PYBIN="$(command -v python3 || command -v python || true)"
if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1 || [ -z "$PYBIN" ]; then
    echo "  (functional sarit — ffmpeg/ffprobe/python lipseste)" >&2
else
    TD=$(mktemp -d); mkdir -p "$TD/in" "$TD/out"
    ffmpeg -y -v error -f lavfi -i "sine=f=440:d=1:r=48000" -af "pan=stereo|c0=c0|c1=c0" "$TD/st.wav" 2>/dev/null
    ffmpeg -y -v error -i "$TD/st.wav" -c:a aac  "$TD/in/a_track.m4a"  2>/dev/null
    ffmpeg -y -v error -i "$TD/st.wav" -c:a flac "$TD/in/a_track.flac" 2>/dev/null
    # fisier VIDEO (regresie) + fisier invalid (trebuie sarit)
    ffmpeg -y -v error -f lavfi -i "testsrc=size=160x120:rate=25:duration=1" \
        -f lavfi -i "sine=f=440:d=1:r=48000" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$TD/in/v_clip.mp4" 2>/dev/null
    printf 'nu sunt media' > "$TD/in/invalid.mka"

    (cd "$SCRIPT_DIR" && INPUT_DIR="$TD/in" OUTPUT_DIR="$TD/out" bash ./av_check.sh >/dev/null 2>&1)
    CSV="$TD/out/av_check_report.csv"
    assert_file_exists "$CSV" "CSV generat"

    if [ -s "$CSV" ]; then
        # parsare CSV REALA: randurile amesteca text citat cu numere necitate, deci un
        # split naiv pe '","' se rupe exact pe randurile video (care au fsMB/durSec numerice).
        _col() { "$PYBIN" -c "
import csv,sys
want,idx=sys.argv[1],int(sys.argv[2])
for r in csv.reader(open(sys.argv[3],encoding='utf-8')):
    if r and r[0].startswith(want): print(r[idx-1]); break
" "$1" "$2" "$CSV" 2>/dev/null; }
        # fisierele audio sunt analizate
        assert_match "$(cat "$CSV")" 'a_track.m4a'  "fisierul .m4a a fost analizat"
        assert_match "$(cat "$CSV")" 'a_track.flac' "fisierul .flac a fost analizat"
        # ...cu campurile video pe N/A
        assert_eq "N/A" "$(_col a_track.m4a 6)"  "audio: Rezolutie = N/A"
        assert_eq "N/A" "$(_col a_track.m4a 7)"  "audio: PixelFormat = N/A"
        assert_eq "N/A" "$(_col a_track.m4a 10)" "audio: Tip_HDR = N/A (nu 'SDR')"
        assert_match "$(_col a_track.m4a 2)" 'Audio' "audio: Format_sursa spune ca e audio"
        # regresie: fisierul video ramane neatins
        _vres=$(_col v_clip.mp4 6)
        assert_eq "160x120" "$_vres" "REGRESIE: fisierul video isi pastreaza rezolutia"
        _vhdr=$(_col v_clip.mp4 10)
        assert_eq "SDR" "$_vhdr" "REGRESIE: fisierul video isi pastreaza Tip_HDR"
        # fisierul invalid e sarit, nu bagat in CSV
        _inv=$(grep -c 'invalid.mka' "$CSV")
        assert_eq "0" "$_inv" "fisierul fara audio SI fara video e sarit"
        # schema CSV neschimbata (38 coloane) — nu stricam consumatorii raportului
        _cols=$(head -1 "$CSV" | awk -F, '{print NF}')
        assert_eq "38" "$_cols" "schema CSV ramane 38 de coloane"
    fi
    rm -rf "$TD"
fi
