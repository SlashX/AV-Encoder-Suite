#!/usr/bin/env bash
# Test probe_video_signature + check_concat_compat.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
source "$SCRIPT_DIR/av_common.sh"
# v60: probe_video_signature + check_concat_compat mutate din av_common in av_trimconcat.
AV_TRIMCONCAT_TEST_MODE=1 source "$SCRIPT_DIR/av_trimconcat.sh"

command -v ffprobe >/dev/null 2>&1 || skip_test "ffprobe nu este in PATH"

SAMPLES="$PROJECT_ROOT/tests/fixtures/samples"
SDR="$SAMPLES/sdr_320p.mp4"
SDR4="$SAMPLES/sdr_4s.mp4"
HDR10="$SAMPLES/hdr10_320p.mkv"

[[ -f "$SDR" && -f "$SDR4" && -f "$HDR10" ]] || skip_test "sample-urile lipsesc"

# 1) probe_video_signature — format codec|WxH|fps|pix_fmt
sig=$(probe_video_signature "$SDR")
assert_contains "$sig" "h264" "SDR codec h264"
assert_contains "$sig" "320" "SDR width 320"
assert_contains "$sig" "240" "SDR height 240"
assert_contains "$sig" "yuv420p" "SDR pix_fmt yuv420p"

# 2) check_concat_compat — fisiere identice (acelasi sample copiat)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"; _test_summary' EXIT
cp "$SDR" "$TMP/a.mp4"; cp "$SDR" "$TMP/b.mp4"
check_concat_compat "$TMP/a.mp4" "$TMP/b.mp4"
assert_zero $? "doua copii identice → compat"

# 3) check_concat_compat — SDR vs HDR10 (codec diferit + pix_fmt diferit)
check_concat_compat "$SDR" "$HDR10"
assert_nonzero $? "SDR vs HDR10 → incompat"

# 4) SDR (h264 320p) vs SDR_4s (h264 320p) — semantic identice
check_concat_compat "$SDR" "$SDR4"
assert_zero $? "doua h264 cu aceeasi rezolutie → compat"
