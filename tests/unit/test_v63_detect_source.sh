#!/usr/bin/env bash
# v63 — detect_source_info robustete: HLG (arib-std-b67) detectat corect + CRLF-safe.
#   Bug: pe Windows/git-bash ffprobe scrie CRLF → HDR_TYPE capta `\r` → match-ul EXACT
#   al HLG (`== "arib-std-b67"`) esua → IS_HLG=0. Fix: tr -d '\r' la citirile pe exact-match.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"

COMMON="$(cat "$SCRIPT_DIR/av_common.sh")"

# ── 1. Source-level — citirile pe exact-match sunt CRLF-safe (tr -d '\r') ──
assert_contains "$COMMON" "tr -d '\\r' | tr ',' ' '"                     "HDR_TYPE multi-field read: tr -d \\r"
assert_contains "$COMMON" 'color_transfer'                               "detect_source_info citeste color_transfer"
# SRC_COLOR_TRC + src_bps hardened (feed `== unknown` / numeric) — substring literal
assert_contains "$COMMON" "head -1 | tr -d '\\r'"                       "single-field reads (SRC_COLOR_TRC/src_bps) CRLF-safe"
# multi-field csv read: var _csv_extra absoarbe trailing comma (HDR side_data) / camp extra →
# HDR_TYPE = mereu campul 3 (nu depinde de absorbtia spatiului; DJI dublare → read prima linie)
assert_contains "$COMMON" 'read -r WIDTH HEIGHT HDR_TYPE _csv_extra'    "WIDTH/HEIGHT/HDR_TYPE read robust (trailing field → _csv_extra)"

# ── 2. Functional — detect_source_info da output corect pe HLG / PQ / SDR ──
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    export SCRIPT_DIR
    source "$SCRIPT_DIR/av_common.sh" 2>/dev/null
    tmpd="$(mktemp -d)"
    hlg="$tmpd/hlg.mp4"; pq="$tmpd/pq.mp4"; sdr="$tmpd/sdr.mp4"
    ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=320x240:rate=10" \
        -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast \
        -x265-params "colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc:log-level=none" -an "$hlg" 2>/dev/null
    ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=320x240:rate=10" \
        -c:v libx265 -pix_fmt yuv420p10le -preset ultrafast \
        -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:log-level=none" -an "$pq" 2>/dev/null
    ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=320x240:rate=10" \
        -c:v libx264 -pix_fmt yuv420p -preset ultrafast -an "$sdr" 2>/dev/null

    if [[ -s "$hlg" ]]; then
        HDR_TYPE=""; IS_HLG=""; DOVI=""; HDR_PLUS=""; LOG_PROFILE=""
        detect_source_info "$hlg" >/dev/null 2>&1
        assert_eq "1" "${IS_HLG:-0}"        "HLG (arib-std-b67) → IS_HLG=1 (CRLF-safe)"
        assert_eq "arib-std-b67" "$HDR_TYPE" "HLG → HDR_TYPE curat (fara \\r)"
    fi
    if [[ -s "$pq" ]]; then
        HDR_TYPE=""; IS_HLG=""; DOVI=""; HDR_PLUS=""; LOG_PROFILE=""
        detect_source_info "$pq" >/dev/null 2>&1
        assert_eq "0" "${IS_HLG:-0}"        "PQ (smpte2084) → IS_HLG=0"
        assert_contains "$HDR_TYPE" "smpte2084" "PQ → HDR_TYPE smpte2084"
    fi
    if [[ -s "$sdr" ]]; then
        HDR_TYPE=""; IS_HLG=""; DOVI=""; HDR_PLUS=""; LOG_PROFILE=""
        detect_source_info "$sdr" >/dev/null 2>&1
        assert_eq "0" "${IS_HLG:-0}"        "SDR → IS_HLG=0"
        [[ -z "$LOG_PROFILE" ]] && assert_eq "1" "1" "SDR → LOG_PROFILE gol" || assert_eq "gol" "$LOG_PROFILE" "SDR → LOG_PROFILE gol"
    fi
    rm -rf "$tmpd"
fi
true
