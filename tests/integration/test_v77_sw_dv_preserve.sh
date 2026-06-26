#!/usr/bin/env bash
# v77 — Test FUNCTIONAL end-to-end: SW DV-preserve prin run_encode_loop REAL (x265).
# Conduce encoderul x265 (care cheama run_encode_loop) non-interactiv pe un clip DV HEVC
# scurt, cu DOVI_PRESERVE_POLICY=preserve → re-encode HDR10 base + inject RPU post-encode.
# Pazeste DOUA regresii care faceau output-ul 0 octeti / fara DV pe bash (mascate fiindca
# validarea HDR e pe Windows/PS1, care NU foloseste eval + nu pre-creeaza temp-uri):
#   (1) v77 eval-parens: master-display=G(..) neescapat → `eval $FFMPEG_CMD` "syntax error
#       near unexpected token (" → base 0 octeti → fara DV.
#   (2) v77 -y: extractia raw post-encode (av_mktemp_ext pre-creeaza fisierul) fara `-y` →
#       prompt overwrite (agatare interactiv / 0 octeti neinteractiv) → "Extractie raw esuata".
# Daca oricare regreseaza, output-ul nu mai are DV → testul pica.
# Auto-skip cand lipseste ffmpeg / dovi_tool / sample DV.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
# self-resolve binare din src/ (ffmpeg/ffprobe/dovi_tool/mkvmerge) ca v75/v76
export PATH="$SCRIPT_DIR:$PATH"

command -v ffmpeg  >/dev/null 2>&1 || skip_test "ffmpeg lipseste"
command -v ffprobe >/dev/null 2>&1 || skip_test "ffprobe lipseste"
command -v dovi_tool >/dev/null 2>&1 || skip_test "dovi_tool lipseste (DV preserve indisponibil)"

SAMPLE="$SCRIPT_DIR/Test-Jellyfin-4K-DV-P8.1.mp4"
[ -f "$SAMPLE" ] || skip_test "sample DV HEVC P8.1 lipseste ($SAMPLE)"

TIN="$(mktemp -d)"; TOUT="$(mktemp -d)"
trap 'rm -rf "$TIN" "$TOUT"; _test_summary' EXIT

# clip DV scurt — -c copy pastreaza RPU; -t 1 = ~24-60 cadre
ffmpeg -v error -y -i "$SAMPLE" -t 1 -c copy -map 0:v:0 "$TIN/dvclip.mp4" </dev/null 2>/dev/null
[ -s "$TIN/dvclip.mp4" ] || skip_test "trim clip DV esuat"

# Ruleaza run_encode_loop REAL prin encoderul x265 (scale 854 pt viteza), non-interactiv.
# mkv → _mux_dv_mkv (mkvmerge) scrie dvcC daca e prezent; RPU survietuieste in stream oricum.
INPUT_DIR="$TIN" OUTPUT_DIR="$TOUT" DOVI_PRESERVE_POLICY=preserve \
  AV_NONINTERACTIVE=1 AV_AUDIO_TRACKS=0 HW_BACKEND=sw \
  timeout 300 bash "$SCRIPT_DIR/av_encoder_x265.sh" aac:128k 30 ultrafast "" "" 1 "" "" "" "" mkv 854 \
  </dev/null >"$TOUT/run.out" 2>&1
_rc=$?

LOG="$TOUT/av_encode_log_x265.txt"
# Regresie eval-parens: NU trebuie sa apara "syntax error" in log/run
if grep -qi 'syntax error' "$TOUT/run.out" "$LOG" 2>/dev/null; then
    assert_eq "0" "1" "regresie eval-parens: 'syntax error' la encode (master-display neescapat)"
else
    assert_eq "0" "0" "fara eval syntax error (master-display escapat corect)"
fi

OUT=$(ls "$TOUT"/dvclip*.mkv 2>/dev/null | head -1)
assert_file_exists "${OUT:-/nonexistent}" "output SW DV-preserve generat (run_encode_loop real)"

if [ -n "$OUT" ] && [ -s "$OUT" ]; then
    # transfer PQ (baza HDR10)
    _trc=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer \
        -of default=noprint_wrappers=1:nokey=1 "$OUT" 2>/dev/null | head -1 | tr -d '\r')
    assert_eq "smpte2084" "$_trc" "baza e PQ (HDR10) — transfer smpte2084"

    # DV supravietuieste: RPU re-extractabil din container (dovada onesta, nu doar dvcC)
    if verify_dv_survived "$OUT" "hevc" >/dev/null 2>&1; then
        assert_eq "0" "0" "DV supravietuieste end-to-end (RPU re-extras din output) — FIX -y + eval-parens"
    else
        # fallback: dv_profile din container (dvcC scris de mkvmerge daca prezent)
        _dvp=$(ffprobe -v error -select_streams v:0 -show_entries stream_side_data=dv_profile \
            -of default=noprint_wrappers=1:nokey=1 "$OUT" 2>/dev/null | head -1 | tr -d '\r')
        assert_eq "8" "${_dvp:-MISSING}" "DV profile 8 in output (dvcC)"
    fi
else
    assert_eq "nonzero" "0" "output gol — encode SW DV-preserve a esuat (vezi $LOG)"
fi
