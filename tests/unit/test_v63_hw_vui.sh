#!/usr/bin/env bash
# v63 — HW encode HDR VUI signaling (bsf repair, v53) end-to-end.
#   ffmpeg `-color_*` flags NU propaga VUI la encoderele HW → bsf (hevc_metadata/av1_metadata/
#   h264_metadata) rescrie VUI in SPS/OBU. Source-level: build_*_cmd asambleaza $_HW_VUI_BSF.
#   Functional (DOAR cand un HW HEVC encoder e disponibil): sursa bt709 → HDR10 cu bsf → VUI corect.
#   (MediaCodec e Android-only → netestabil functional aici; acoperit source-level in test_v53.)
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"

COMMON="$(cat "$SCRIPT_DIR/av_common.sh")"

# ── 1. Source-level — build_*_cmd asambleaza bsf-ul + pix_fmt ──
nv_fn=$(awk '/^build_nvenc_cmd\(\)/{f=1} /^build_qsv_cmd\(\)/{f=0} f' "$SCRIPT_DIR/av_common.sh")
qsv_fn=$(awk '/^build_qsv_cmd\(\)/{f=1} /^build_vaapi_cmd\(\)/{f=0} f' "$SCRIPT_DIR/av_common.sh")
assert_contains "$nv_fn"  '$_HW_VUI_BSF'  "build_nvenc_cmd aplica \$_HW_VUI_BSF"
assert_contains "$nv_fn"  '$_HW_PIX_FMT'  "build_nvenc_cmd aplica \$_HW_PIX_FMT"
assert_contains "$qsv_fn" '$_HW_VUI_BSF'  "build_qsv_cmd aplica \$_HW_VUI_BSF"
assert_contains "$nv_fn"  '_hw_hdr_setup' "build_nvenc_cmd cheama _hw_hdr_setup"

# ── 2. Functional — bsf-ul produce VUI corect end-to-end (skip daca lipseste HW) ──
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    export SCRIPT_DIR
    source "$SCRIPT_DIR/av_common.sh" 2>/dev/null
    tmpd="$(mktemp -d)"
    # Detecteaza un HW HEVC encoder care chiar functioneaza pe acest box
    hwenc=""
    for e in hevc_qsv hevc_nvenc hevc_amf; do
        if ffmpeg -hide_banner -v error -y -f lavfi -i "testsrc2=duration=1:size=320x240:rate=10" \
            -c:v "$e" -t 1 "$tmpd/probe.mp4" 2>/dev/null && [[ -s "$tmpd/probe.mp4" ]]; then hwenc="$e"; break; fi
    done
    if [[ -n "$hwenc" ]]; then
        # sursa bt709 8-bit
        src="$tmpd/src709.mp4"
        ffmpeg -hide_banner -v error -y -f lavfi -i "testsrc2=duration=1:size=320x240:rate=10" \
            -c:v libx264 -pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 -colorspace bt709 "$src" 2>/dev/null
        # bsf-ul nostru (din _hw_hdr_setup hw_hdr10)
        HW_HDR_MODE="hw_hdr10"; _hw_hdr_setup hevc
        # CU bsf → output HDR10 corect
        # shellcheck disable=SC2086
        ffmpeg -hide_banner -v error -y -i "$src" -c:v "$hwenc" -pix_fmt "$_HW_PIX_FMT" $_HW_VUI_BSF "$tmpd/bsf.mp4" 2>/dev/null
        trc=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer -of default=nw=1:nk=1 "$tmpd/bsf.mp4" 2>/dev/null | tr -d '\r')
        prim=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_primaries -of default=nw=1:nk=1 "$tmpd/bsf.mp4" 2>/dev/null | tr -d '\r')
        assert_eq "smpte2084" "$trc"  "HW ($hwenc) + bsf → transfer=smpte2084 (PQ propagat)"
        assert_eq "bt2020"    "$prim" "HW ($hwenc) + bsf → primaries=bt2020"
        # FARA bsf (contrast) → PQ pierdut
        ffmpeg -hide_banner -v error -y -i "$src" -c:v "$hwenc" -pix_fmt "$_HW_PIX_FMT" \
            -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc "$tmpd/nobsf.mp4" 2>/dev/null
        trc_n=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer -of default=nw=1:nk=1 "$tmpd/nobsf.mp4" 2>/dev/null | tr -d '\r')
        if [[ "$trc_n" != "smpte2084" ]]; then
            assert_eq "1" "1" "HW contrast: FARA bsf → transfer NU e smpte2084 ($trc_n) — bsf-ul e esential"
        else
            echo "  (info: $hwenc propaga -color_* singur; bsf-ul ramane robust universal)"
        fi
    else
        echo "  (functional sarit — niciun HW HEVC encoder functional pe acest box; source-level acoperit)"
    fi
    rm -rf "$tmpd"
fi
true
