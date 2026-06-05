#!/usr/bin/env bash
# v63 — HDR10 → HLG (oglinda lui hlg_to_hdr10) pe HEVC + AV1.
#   Sursa PQ (smpte2084) → HLG (arib-std-b67); HLG e metadata-free (fara hdr10=1/master-display).
#   Optiune noua in handle_source_dialog (SRC_DIALOG_MODE=hdr10_to_hlg), doar x265/av1 (HLG-capable).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
# ffmpeg: global (PATH) sau bundle-uit in src/ (Windows testing) — ca v55/v56
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"

COMMON="$(cat "$SCRIPT_DIR/av_common.sh")"
X265="$(cat "$SCRIPT_DIR/av_encoder_x265.sh")"
AV1="$(cat "$SCRIPT_DIR/av_encoder_av1.sh")"
ENC_PS1="$(cat "$SCRIPT_DIR/av_encode.ps1")"

# ── 1. Dialog (bash) — optiunea HLG + mode hdr10_to_hlg ──
assert_contains "$COMMON" 'SRC_DIALOG_MODE="hdr10_to_hlg"' "bash dialog: seteaza mode hdr10_to_hlg"
assert_contains "$COMMON" "Converteste la HLG"            "bash dialog: ofera optiunea HLG"

# ── 2. Encodere (bash) — cazul hdr10_to_hlg, params HLG corecte (fara hdr10=1) ──
assert_contains "$X265" "hdr10_to_hlg)"                                                      "x265: cazul hdr10_to_hlg"
assert_contains "$X265" 'colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc'        "x265: HLG params (arib, FARA hdr10=1)"
assert_contains "$AV1"  "hdr10_to_hlg)"                                                       "av1: cazul hdr10_to_hlg"
assert_contains "$AV1"  "color_trc arib-std-b67"                                             "av1: HLG color_trc (arib)"

# ── 3. PS1 paritate — Show-SourceDialog + consum x265/av1 ──
assert_contains "$ENC_PS1" 'return "hdr10_to_hlg"'        "PS1 Show-SourceDialog: returneaza hdr10_to_hlg"
assert_contains "$ENC_PS1" '"hdr10_to_hlg" {'             "PS1: cazul hdr10_to_hlg consumat (switch)"
assert_contains "$ENC_PS1" 'transfer=arib-std-b67'        "PS1 x265: HLG VUI (arib) — derivat din colorParams"

# ── 4. Functional — PQ (smpte2084) → HLG (arib-std-b67) + metadata-free ──
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    tmpd="$(mktemp -d)"; pq="$tmpd/pq.mp4"; hlg="$tmpd/hlg.mp4"
    ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=320x240:rate=30" \
        -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast \
        -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:log-level=none" -an "$pq" 2>/dev/null
    if [[ -s "$pq" ]]; then
        # exact filtrul + params din cazul hdr10_to_hlg (x265)
        ffmpeg -v error -y -i "$pq" \
            -vf "zscale=t=linear:npl=1000,zscale=t=arib-std-b67:p=bt2020:m=bt2020nc:r=tv,format=yuv420p10le" \
            -c:v libx265 -preset ultrafast \
            -x265-params "hdr-opt=1:repeat-headers=1:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc:log-level=none" -an "$hlg" 2>/dev/null
        trc=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer \
            -of default=noprint_wrappers=1:nokey=1 "$hlg" | head -1 | tr -d '\r')
        assert_eq "arib-std-b67" "$trc" "functional: PQ → HLG produce arib-std-b67"
        # HLG e metadata-free → fara mastering display in output
        md=$(ffprobe -v error -show_frames -select_streams v:0 -read_intervals "%+#3" \
            -show_entries frame_side_data=side_data_type "$hlg" 2>/dev/null | grep -ci "Mastering display" || true)
        assert_eq "0" "$md" "functional: HLG output FARA mastering display (metadata-free)"
    fi
    rm -rf "$tmpd"
fi
true
