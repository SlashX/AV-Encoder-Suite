#!/usr/bin/env bash
# v65 — APV rework: encoder real (liboapv/libopenapv auto-detect), pixfmt/profil +
#   preset viteza + qp + oapv-params (model real, NU preset-uri inventate), container
#   mp4/mov/mkv (fara mxf), avertismente DV/HDR10+, paritate bash↔PS1 completa.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"

APV="$(cat "$SCRIPT_DIR/av_encoder_apv.sh")"
LAUNCHER="$(cat "$SCRIPT_DIR/av_launcher.sh")"
COMMON="$(cat "$SCRIPT_DIR/av_common.sh")"
ENC_PS1="$(cat "$SCRIPT_DIR/av_encode.ps1")"

# ── 1. Encoder bash — nume auto-detect + pixfmt + preset/qp/extra ──────
assert_contains "$APV" 'grep -qw "liboapv"'        "apv: auto-detect liboapv"
assert_contains "$APV" 'grep -qw "libopenapv"'     "apv: fallback libopenapv"
assert_contains "$APV" '-c:v $APV_ENCODER -preset $APV_PRESET -qp $APV_QP' "apv: comanda cu encoder detectat + preset + qp"
assert_contains "$APV" '422_10)  pixfmt="yuv422p10le"'  "apv: 422_10 -> yuv422p10le"
assert_contains "$APV" '422_12)  pixfmt="yuv422p12le"'  "apv: 422_12 -> yuv422p12le"
assert_contains "$APV" '4444_10) pixfmt="yuva444p10le"' "apv: 4444_10 -> yuva444p10le (alpha)"
assert_contains "$APV" 'oapv-params $APV_EXTRA'    "apv: extra oapv-params"
assert_not_contains "$APV" '-preset $APV_PROFILE'  "apv: NU mai foloseste APV_PROFILE fictiv ca preset"
assert_not_contains "$APV" 'preset light'          "apv: NU mai are preset inventat 'light'"

# ── 2. Launcher — meniuri noi + container mkv (nu mxf) + dispatch ─────
assert_contains "$LAUNCHER" 'profil / pixel format'  "launcher: meniu pixfmt APV"
assert_contains "$LAUNCHER" 'preset viteza'          "launcher: meniu preset viteza"
assert_contains "$LAUNCHER" 'placebo'                "launcher: preset placebo"
assert_contains "$LAUNCHER" '"$APV_PIXFMT" "$APV_PRESET" "$APV_QP" "$APV_EXTRA"' "launcher: dispatch arg-uri noi"
assert_contains "$LAUNCHER" 'Format container output (APV)' "launcher: meniu container APV"
assert_not_contains "$LAUNCHER" 'mxf — broadcast profesional' "launcher: APV nu mai ofera mxf"

# ── 3. Schema bash — campuri noi, APV_PROFILE vechi scos ──────────────
assert_contains "$COMMON" 'APV_PIXFMT)           echo "enum:,422_10,422_12,444_10,444_12,4444_10,4444_12"' "schema: APV_PIXFMT (v74 +4444_12)"
assert_contains "$COMMON" 'APV_PRESET)           echo "enum:,fastest,fast,medium,slow,placebo"'     "schema: APV_PRESET real"
assert_contains "$COMMON" 'APV_QP)               echo "intrange:0,63"' "schema: APV_QP intrange (virgula)"
assert_not_contains "$COMMON" 'APV_PROFILE)'     "schema: APV_PROFILE vechi scos"

# ── 4. PS1 paritate completa ──────────────────────────────────────────
# v94 (O10): APV a trecut de pe 7 pe 5, ca sa coincida cu meniul bash (5=APV, 6=ProRes);
# „HW Encode" (PS1-only) a coborat pe 7.
assert_contains "$ENC_PS1" '$useAPV    = ($encChoice -eq "5")'  "PS1: APV optiunea 5 (paritate bash)"
assert_contains "$ENC_PS1" '$useProRes = ($encChoice -eq "6")'  "PS1: ProRes optiunea 6 (paritate bash)"
assert_contains "$ENC_PS1" '$useHWEnc  = ($encChoice -eq "7")'  "PS1: HW Encode (PS1-only) la coada, pe 7"
# santinela de paritate: ordinea encoderelor comune e identica pe cele doua platforme
for _i in 1:libx265 2:libx264 3:AV1 4:DNxHR 5:APV 6:ProRes; do
    _n="${_i%%:*}"; _e="${_i##*:}"
    assert_contains "$(sed -n '374,390p' "$SCRIPT_DIR/av_launcher.sh")" "$_n) $_e" \
        "bash: poziţia $_n = $_e"
done
assert_contains "$ENC_PS1" '$useAPV    = ($ENCODER -eq "apv")'  "PS1: APV in profile-load"
assert_contains "$ENC_PS1" 'profil / pixel format'              "PS1: meniu pixfmt APV"
assert_contains "$ENC_PS1" 'Container APV'                      "PS1: container APV"
assert_contains "$ENC_PS1" '@("-c:v",$apvEncoder,"-preset",$apvPreset,"-qp",$apvQp)' "PS1: comanda encode APV"
assert_contains "$ENC_PS1" "'APV_PIXFMT'           { 'enum:,422_10,422_12,444_10,444_12,4444_10,4444_12'" "PS1: schema APV_PIXFMT (v74 +4444_12)"
assert_contains "$ENC_PS1" '"APV_PIXFMT=$apvPixFmt"'  "PS1: save flow APV"
assert_contains "$ENC_PS1" 'apvEncoder = "liboapv"'   "PS1: auto-detect liboapv"
assert_not_contains "$ENC_PS1" "'APV_PROFILE'"        "PS1: APV_PROFILE vechi scos"

# ── 4b. FLAC — avertisment pe mov (nu mai scuteste mezzanine; mxf via MXF=PCM) ──
assert_contains "$LAUNCHER" 'flac:* ]] && [[ "$CONTAINER" == "mov" ]]'  "launcher: FLAC warning pe mov"
assert_not_contains "$LAUNCHER" '"$ENCODER_NAME" != "apv"'              "launcher: FLAC nu mai scuteste apv/prores/dnxhr"
assert_contains "$ENC_PS1" 'audioCodec -eq "flac" -and $container -eq "mov"' "PS1: FLAC warning pe mov (paritate)"

# ── 4c. Fix-uri adiacente: pcm in schema audio + eticheta progres ─────
assert_contains "$COMMON"  'ac3:[0-9]+k|pcm:[0-9]+(le|be))?$'  "schema bash: AUDIO_CODEC_ARG accepta pcm (LPCM profile)"
assert_contains "$ENC_PS1" 'ac3:[0-9]+k|pcm:[0-9]+(le|be))?'   "schema PS1: AUDIO_CODEC_ARG accepta pcm"
assert_contains "$COMMON"  'ENCODER_NAME:-${ENCODER_TYPE:-FFmpeg}' "progres: eticheta fallback pe ENCODER_TYPE (nu mai FFMPEG)"

# ── 5. Functional — encode real pe fiecare profil + mxf esueaza ───────
APV_ENC=""
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -qw liboapv; then APV_ENC="liboapv"
elif ffmpeg -hide_banner -encoders 2>/dev/null | grep -qw libopenapv; then APV_ENC="libopenapv"; fi
if [[ -n "$APV_ENC" ]] && command -v ffprobe >/dev/null 2>&1; then
    tmpd="$(mktemp -d)"
    trap 'rm -rf "$tmpd"; _test_summary' EXIT
    src="$tmpd/src.mp4"
    ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=240x160:rate=5" \
        -f lavfi -i "sine=frequency=440:duration=1" \
        -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast -x265-params "log-level=none" -c:a aac -shortest "$src" 2>/dev/null
    if [[ -s "$src" ]]; then
        prof() { ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,profile -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | head -2 | tr -d '\r' | tr '\n' '/'; }
        # pixfmt → profil asteptat (33/44/55/66/77)
        for combo in "yuv422p10le:apv/33/" "yuv444p10le:apv/55/" "yuv444p12le:apv/66/" "yuva444p10le:apv/77/"; do
            pf="${combo%%:*}"; exp="${combo##*:}"
            ffmpeg -v error -y -t 1 -i "$src" -an -c:v "$APV_ENC" -preset fast -qp 32 -pix_fmt "$pf" "$tmpd/o.mp4" 2>/dev/null
            assert_eq "$exp" "$(prof "$tmpd/o.mp4")" "functional: APV $pf -> $exp"
        done
        # container mp4/mov/mkv OK
        for ext in mp4 mov mkv; do
            ffmpeg -v error -y -t 1 -i "$src" -an -c:v "$APV_ENC" -preset fast -qp 32 -pix_fmt yuv422p10le "$tmpd/c.$ext" 2>/dev/null
            assert_file_exists "$tmpd/c.$ext" "functional: APV in .$ext produce output"
        done
        # mxf esueaza (de ce l-am scos)
        ffmpeg -v error -y -t 1 -i "$src" -an -c:v "$APV_ENC" -preset fast -qp 32 -pix_fmt yuv422p10le "$tmpd/x.mxf" 2>/dev/null
        if [[ -s "$tmpd/x.mxf" ]]; then mxfok=1; else mxfok=0; fi
        assert_eq "0" "$mxfok" "functional: APV + mxf esueaza (de ce l-am scos din meniu)"
    fi
fi
true
