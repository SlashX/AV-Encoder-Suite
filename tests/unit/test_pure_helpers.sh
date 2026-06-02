#!/usr/bin/env bash
# Test functii pure din av_common.sh (fara ffmpeg/ffprobe).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
source "$SCRIPT_DIR/av_common.sh"
# v60: parse_time_flexible / format_seconds / expand_range_selection mutate
# din av_common in av_trimconcat. Source in test mode (skip meniu interactiv).
AV_TRIMCONCAT_TEST_MODE=1 source "$SCRIPT_DIR/av_trimconcat.sh"

# ── get_adaptive_crf ──────────────────────────────────────────────────
unset CUSTOM_CRF
assert_eq "20" "$(get_adaptive_crf x265 1280)" "x265 720p → CRF 20"
assert_eq "21" "$(get_adaptive_crf x265 1920)" "x265 1080p → CRF 21"
assert_eq "22" "$(get_adaptive_crf x265 3840)" "x265 4K → CRF 22"
assert_eq "18" "$(get_adaptive_crf x264 1280)" "x264 720p → CRF 18"
assert_eq "26" "$(get_adaptive_crf av1 1280)"  "av1 720p → CRF 26"
assert_eq "22" "$(get_adaptive_crf bogus 1920)" "encoder necunoscut → default 22"

# CUSTOM_CRF override
CUSTOM_CRF=30
assert_eq "30" "$(get_adaptive_crf x265 1920)" "CUSTOM_CRF override"
unset CUSTOM_CRF

# ── get_adaptive_bitrate (kbps per encoder MediaCodec × resolution) ──
assert_eq "8000"  "$(get_adaptive_bitrate hevc_mediacodec 1920)" "hevc_mediacodec 1080p"
assert_eq "25000" "$(get_adaptive_bitrate hevc_mediacodec 3840)" "hevc_mediacodec 4K"
assert_eq "12000" "$(get_adaptive_bitrate h264_mediacodec 1920)" "h264_mediacodec 1080p"
assert_eq "5500"  "$(get_adaptive_bitrate av1_mediacodec  1920)" "av1_mediacodec 1080p"
assert_eq "8000"  "$(get_adaptive_bitrate bogus 1920)"           "fallback 8000"

# ── parse_time_flexible ──────────────────────────────────────────────
assert_eq "0"     "$(parse_time_flexible "00:00:00")" "00:00:00 → 0s"
assert_eq "30"    "$(parse_time_flexible "30")"        "30 → 30s"
assert_eq "30"    "$(parse_time_flexible "0:30")"      "0:30 → 30s"
assert_eq "90"    "$(parse_time_flexible "01:30")"     "01:30 → 90s"
assert_eq "3690"  "$(parse_time_flexible "01:01:30")"  "01:01:30 → 3690s"
assert_eq ""      "$(parse_time_flexible "abc")"       "invalid → empty"
assert_eq ""      "$(parse_time_flexible "01:99")"     "minute>59 → empty"
assert_eq ""      "$(parse_time_flexible "01:30:99")"  "secunde>59 → empty"

# ── expand_range_selection ───────────────────────────────────────────
# Helper: normalize output (trim + collapse whitespace) — separator e
# implementation detail (callers folosesc $(...) cu word splitting).
_norm() { echo "$@" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//'; }

assert_eq "1 2 3"          "$(_norm $(expand_range_selection "1-3" 10))"      "range 1-3"
assert_eq "1 3 5"          "$(_norm $(expand_range_selection "1,3,5" 10))"    "lista enumerata"
assert_eq "1 2 3 7 10"     "$(_norm $(expand_range_selection "1-3,7,10" 10))" "mix range + valori"
assert_eq "1 2 3 4 5"      "$(_norm $(expand_range_selection "all" 5))"       "all up to 5"
assert_eq "5 6 7"          "$(_norm $(expand_range_selection "5-7" 10))"      "range mid"
assert_eq "1 2 3 4 5"      "$(_norm $(expand_range_selection "1-100" 5))"     "range capped at max"
assert_eq "3 4 5"          "$(_norm $(expand_range_selection "5-3" 10))"      "reversed range normalised"

# ── format_seconds ────────────────────────────────────────────────────
assert_eq "00:00:00" "$(format_seconds 0)"     "format 0"
assert_eq "00:01:30" "$(format_seconds 90)"    "format 90s"
assert_eq "01:01:01" "$(format_seconds 3661)"  "format 3661s"
