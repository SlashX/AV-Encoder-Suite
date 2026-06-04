#!/usr/bin/env bash
# v62 — flux LOG + LUT (Faza A): detectie + dialog (mirror al test_v62_log_lut.ps1).
#   Bug 1  — fallback bit-depth pe pix_fmt (bits_per_raw_sample e N/A pe HEVC 10-bit).
#   Finding 4 — exclude HLG (arib-std-b67) din ramurile Log (samsung/dji/unknown).
#   Bug 2  — culoarea bt709 in params encoder (x265-params/x264-params) pe LUT/Creative.
#   Bug 3  — conversia fara-LUT (zscale tonemap) ELIMINATA din ramura LOG (main+burnin+tc).
#   + fallback LUT relaxat (orice .cube cand nu exista prefix de brand).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
# ffmpeg: global (PATH) sau bundle-uit in src/ (Windows testing) — ca la v55/v56
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"

INPUT_DIR=/tmp/v62_in OUTPUT_DIR=/tmp/v62_out
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"
source "$SCRIPT_DIR/av_common.sh"

COMMON_SRC="$(cat "$SCRIPT_DIR/av_common.sh")"
X264_SRC="$(cat "$SCRIPT_DIR/av_encoder_x264.sh")"
BURNIN_SRC="$(cat "$SCRIPT_DIR/av_burnin.sh")"
CHECK_SRC="$(cat "$SCRIPT_DIR/av_check.sh")"
TC_SRC="$(cat "$SCRIPT_DIR/av_trimconcat.sh")"

# ── 1. Bug 3 — conversiile fara-LUT scoase din handle_log_dialog ──
HLD="$(declare -f handle_log_dialog)"
assert_neq "" "$HLD" "handle_log_dialog gasit"
assert_not_contains "$HLD" "opt_sdr" "handle_log_dialog: scos opt_sdr (Convert SDR fara-LUT)"
assert_not_contains "$HLD" "opt_hdr" "handle_log_dialog: scos opt_hdr (Convert HDR10 fara-LUT)"
assert_contains "$HLD" "any_lut" "handle_log_dialog: gating any_lut"
assert_contains "$HLD" "NU poate fi transformat" "handle_log_dialog: mesaj onest cand nu exista LUT"

# ── 2. Bug 2 — culoare bt709 in params encoder pe calea LUT ──
assert_contains "$COMMON_SRC" 'LOG_EXTRA_X265="colorprim=bt709:transfer=bt709:colormatrix=bt709"' "LUT seteaza LOG_EXTRA_X265 bt709"
assert_contains "$COMMON_SRC" 'LOG_EXTRA_X264="colorprim=bt709:transfer=bt709:colormatrix=bt709"' "LUT seteaza LOG_EXTRA_X264 bt709"
# plumbing x264-params (av_encoder_x264.sh foloseste LOG_EXTRA_X264 primul)
assert_contains "$X264_SRC" 'LOG_EXTRA_X264' "x264: LOG_EXTRA_X264 folosit la build"
assert_contains "$X264_SRC" '_x264_parts="${LOG_EXTRA_X264}"' "x264: LOG_EXTRA_X264 injectat in _x264_parts"

# ── 3. Bug 1 + Finding 4 — bit-depth fallback + arib exclus in detect_source_info ──
DSI="$(declare -f detect_source_info)"
assert_contains "$DSI" "src_pixfmt_bd" "detect_source_info: fallback bit-depth pe pix_fmt"
assert_contains "$COMMON_SRC" 'src_bps=16' "detect_source_info: pix_fmt p016 → 16-bit"
assert_contains "$DSI" 'HDR_TYPE" != *"arib"*' "detect_source_info: HLG exclus din ramura Log"
# av_check get_log_profile arib exclus
assert_contains "$CHECK_SRC" 'transfer" != *"arib"*' "av_check get_log_profile: arib exclus"

# ── 4. Burn-in + Trim/Concat — tonemap-for-LOG scos ──
assert_contains "$BURNIN_SRC" "conversia fara-LUT (tonemap) ELIMINATA pe LOG" "Burn-in: tonemap LOG eliminat"
assert_contains "$TC_SRC" "conversia fara-LUT (tonemap) ELIMINATA pe LOG" "Trim/Concat: tonemap LOG eliminat"

# ── 5. v62 audit FIX — run_encode_loop reseteaza LOG_* per fisier (anti-leak x264) ──
# x264 consuma LOG_COLOR_FLAGS + LOG_EXTRA_X264 neconditionat in video_params → fara reset,
# un fisier LOG (x264+LUT) contamina culoarea fisierului NE-LOG urmator din batch.
REL="$(declare -f run_encode_loop)"
assert_neq "" "$REL" "run_encode_loop definit"
assert_contains "$REL" 'LOG_COLOR_FLAGS=""' "run_encode_loop: reset LOG_COLOR_FLAGS (anti-leak x264)"
assert_contains "$REL" 'LOG_EXTRA_X264=""'  "run_encode_loop: reset LOG_EXTRA_X264 (anti-leak x264)"
assert_contains "$REL" 'LOG_EXTRA_X265=""'  "run_encode_loop: reset LOG_EXTRA_X265"

# ── 6. Functional — fallback LUT relaxat (orice .cube, nu doar brand) ──
TMPLUT="$(mktemp -d)"
: > "$TMPLUT/mylut.cube"
LUTS_DIR="$TMPLUT" find_lut_for_brand dji
assert_eq "1" "${#LUT_FILES[@]}" "find_lut_for_brand: fallback relaxat gaseste orice .cube (brand dji)"
rm -rf "$TMPLUT"

# ── 7. Functional — Finding 4: sursa HLG (arib) NU e clasificata Log ──
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    tmpd="$(mktemp -d)"
    tmpf="$tmpd/hlg.mp4"
    ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=320x240:rate=30" \
        -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast -tag:v hvc1 \
        -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc \
        -x265-params "colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc:log-level=none" \
        -an "$tmpf" 2>/dev/null
    if [[ -s "$tmpf" ]]; then
        LOG_PROFILE=""; IS_HLG=0; CAMERA_MAKE=""; HDR_TYPE=""; HDR_PLUS=""; DOVI=""
        detect_source_info "$tmpf" >/dev/null 2>&1
        # Finding 4 — esenta: HLG (arib) 10-bit bt2020 NU trebuie clasificat Log.
        # (Substring-match, tolerant la CR-ul emis de ffprobe.exe pe Windows-git-bash;
        #  bash ruleaza in productie pe Termux/Linux/macOS — ffprobe LF → IS_HLG=1.)
        assert_eq ""  "$LOG_PROFILE" "HLG (arib) 10-bit bt2020 NU e clasificat Log (Finding 4)"
        assert_contains "$HDR_TYPE" "arib" "HLG (arib): clip raportat ca HLG (HDR_TYPE arib)"
    fi
    rm -rf "$tmpd"
fi

# ── 8. v62 audit FIX — setparams re-eticheteaza culoarea dupa lut3d (MKV mis-tag) ──
# lut3d NU actualizeaza metadata de culoare a frame-urilor → pe MKV (Matroska Colour
# citit din frame, nu din VUI/SPS) iesirea LUT ramanea bt2020/unknown de la sursa.
# setparams o forteaza la culoarea tinta. Toate caile LOG→LUT trebuie sa o aiba.
assert_contains "$COMMON_SRC" ',setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709' "main encode: setparams bt709 dupa lut3d (Rec.709/Creative)"
assert_contains "$COMMON_SRC" ',setparams=color_primaries=bt2020:color_trc=arib-std-b67:colorspace=bt2020nc' "main encode: setparams bt2020/arib dupa lut3d (Log→HLG)"
assert_contains "$BURNIN_SRC" ',setparams=color_primaries=bt709' "Burn-in lut_rec709: setparams bt709 dupa lut3d"
assert_contains "$TC_SRC"     ',setparams=color_primaries=bt709' "Trim/Concat lut_rec709: setparams bt709 dupa lut3d"

# ── 9. Functional — lut3d+setparams → MKV produce bt709 (nu bt2020/unknown) ──
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    tmpd="$(mktemp -d)"
    lut="$tmpd/id.cube"   # LUT identitate minimal (LUT_3D_SIZE 2)
    printf 'LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n' > "$lut"
    src="$tmpd/src.mp4"   # sursa 10-bit bt2020 (mimica LOG, ca lut3d sa porneasca de la non-bt709)
    ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=320x240:rate=30" \
        -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast \
        -x265-params "colorprim=bt2020:colormatrix=bt2020nc:log-level=none" -an "$src" 2>/dev/null
    out="$tmpd/out.mkv"
    ffmpeg -v error -y -i "$src" \
        -vf "lut3d='$lut',format=yuv420p10le,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709" \
        -c:v libx265 -x265-params "colorprim=bt709:transfer=bt709:colormatrix=bt709:log-level=none" -an "$out" 2>/dev/null
    if [[ -s "$out" ]]; then
        prim=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_primaries \
            -of default=noprint_wrappers=1:nokey=1 "$out" | head -1 | tr -d '\r')
        assert_eq "bt709" "$prim" "lut3d+setparams → MKV: color_primaries=bt709 (nu bt2020 — MKV mis-tag fix)"
    fi
    rm -rf "$tmpd"
fi
true
