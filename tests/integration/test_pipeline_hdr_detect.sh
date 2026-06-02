#!/usr/bin/env bash
# Test detect_pipeline_hdr_mode + tc_check_hdr_files pe sample-uri.
# Auto-skip cand ffprobe sau sample-urile lipsesc.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
source "$SCRIPT_DIR/av_common.sh"
# v60: detect_pipeline_hdr_mode mutat din av_common in av_trimconcat.
AV_TRIMCONCAT_TEST_MODE=1 source "$SCRIPT_DIR/av_trimconcat.sh"

command -v ffprobe >/dev/null 2>&1 || skip_test "ffprobe nu este in PATH"

SAMPLES="$PROJECT_ROOT/tests/fixtures/samples"
SDR="$SAMPLES/sdr_320p.mp4"
HDR10="$SAMPLES/hdr10_320p.mkv"
HLG="$SAMPLES/hlg_320p.mkv"

[[ -f "$SDR" && -f "$HDR10" && -f "$HLG" ]] || skip_test "sample-urile lipsesc — ruleaza tests/fixtures/generate_samples.sh"

# 1) SDR singur → "sdr"
mode=$(detect_pipeline_hdr_mode "$SDR")
assert_eq "sdr" "$mode" "SDR singur"

# 2) HDR10 singur → "hdr10"
mode=$(detect_pipeline_hdr_mode "$HDR10")
assert_eq "hdr10" "$mode" "HDR10 singur"

# 3) HLG singur → "hlg"
mode=$(detect_pipeline_hdr_mode "$HLG")
assert_eq "hlg" "$mode" "HLG singur"

# 4) SDR + HDR10 → "mixed"
mode=$(detect_pipeline_hdr_mode "$SDR" "$HDR10")
assert_eq "mixed" "$mode" "SDR + HDR10 → mixed"

# 5) HDR10 + HLG (ambele non-SDR) → primul detectat = HDR10
mode=$(detect_pipeline_hdr_mode "$HDR10" "$HLG")
assert_match "$mode" "^(hdr10|hlg|mixed)$" "HDR10+HLG într-una din cele trei stări"

# 6) tc_check_hdr_files — return 0 daca >= 1 HDR
tc_check_hdr_files "$HDR10"
assert_zero $? "HDR10 singur → tc_check_hdr_files returns 0"

tc_check_hdr_files "$HLG"
assert_zero $? "HLG singur → tc_check_hdr_files returns 0"

tc_check_hdr_files "$SDR"
assert_nonzero $? "SDR singur → tc_check_hdr_files returns 1"

tc_check_hdr_files "$SDR" "$HDR10"
assert_zero $? "SDR + HDR10 → tc_check_hdr_files returns 0 (cel putin unul HDR)"
