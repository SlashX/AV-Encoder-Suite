#!/usr/bin/env bash
# Test detect_brand din av_telemetry.sh — pentru SDR sample (fara telemetrie).
# Sample-ul SDR sintetic nu are tracks de telemetrie, asa ca asteptam fallback.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"

command -v ffprobe >/dev/null 2>&1 || skip_test "ffprobe nu este in PATH"
command -v exiftool >/dev/null 2>&1 || skip_test "exiftool nu este in PATH (necesar pentru detectie ISO 6709)"

SAMPLES="$PROJECT_ROOT/tests/fixtures/samples"
SDR="$SAMPLES/sdr_320p.mp4"
[[ -f "$SDR" ]] || skip_test "sdr_320p.mp4 lipseste"

# Source av_common.sh (pentru fallback paths) si extrage doar functia detect_brand.
source "$SCRIPT_DIR/av_common.sh"

# Extract detect_brand definition without running the rest of av_telemetry.sh
eval "$(awk '/^detect_brand\(\)/,/^}$/' "$SCRIPT_DIR/av_telemetry.sh")"

assert_eq "function" "$(type -t detect_brand)" "detect_brand definit"

brand=$(detect_brand "$SDR")
# SDR lavfi-generated nu are codec_tag specific; e probabil fallback "" sau "quicktime" daca exiftool prinde un atom random
assert_match "$brand" "^(|quicktime|unknown)$" "SDR plain → brand vid/quicktime/unknown"
