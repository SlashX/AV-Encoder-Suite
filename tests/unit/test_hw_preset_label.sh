#!/usr/bin/env bash
# Test hw_preset_label — mapping pure 1-7 → eticheta vendor.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
source "$SCRIPT_DIR/av_common.sh"

# NVENC: p1..p7
assert_eq "p1" "$(hw_preset_label nvenc 1)" "nvenc slot 1"
assert_eq "p4" "$(hw_preset_label nvenc 4)" "nvenc slot 4 (default Quality)"
assert_eq "p7" "$(hw_preset_label nvenc 7)" "nvenc slot 7 (Veryslow)"

# VAAPI: -quality 7..1 (v75: iHD 1=best/slow .. 7=fast -> invers fata de slot)
assert_eq "q7" "$(hw_preset_label vaapi 1)" "vaapi slot 1 (Ultrafast -> quality 7 fast)"
assert_eq "q4" "$(hw_preset_label vaapi 4)" "vaapi slot 4 (mijloc, stabil)"
assert_eq "q1" "$(hw_preset_label vaapi 7)" "vaapi slot 7 (Veryslow -> quality 1 best)"

# QSV: 7-tier nominal
assert_eq "veryfast" "$(hw_preset_label qsv 1)" "qsv slot 1"
assert_eq "medium"   "$(hw_preset_label qsv 4)" "qsv slot 4"
assert_eq "veryslow" "$(hw_preset_label qsv 7)" "qsv slot 7"

# VideoToolbox: q:v 50..80 (v75: mai mare = mai bun -> corectat, era invers)
assert_eq "q:v 50" "$(hw_preset_label videotoolbox 1)" "vt slot 1 (Ultrafast -> q:v 50 mai mic)"
assert_eq "q:v 65" "$(hw_preset_label videotoolbox 4)" "vt slot 4 (mijloc, stabil)"
assert_eq "q:v 80" "$(hw_preset_label videotoolbox 7)" "vt slot 7 (Veryslow -> q:v 80 best)"

# AMF: 3-tier (speed/balanced/quality)
assert_eq "speed"    "$(hw_preset_label amf 1)" "amf slot 1 → speed"
assert_eq "speed"    "$(hw_preset_label amf 2)" "amf slot 2 → speed"
assert_eq "balanced" "$(hw_preset_label amf 3)" "amf slot 3 → balanced"
assert_eq "balanced" "$(hw_preset_label amf 4)" "amf slot 4 → balanced"
assert_eq "balanced" "$(hw_preset_label amf 5)" "amf slot 5 → balanced"
assert_eq "quality"  "$(hw_preset_label amf 6)" "amf slot 6 → quality"
assert_eq "quality"  "$(hw_preset_label amf 7)" "amf slot 7 → quality"

# MediaCodec: bitrate scaling 60%..150%
assert_eq "60%"  "$(hw_preset_label mediacodec 1)" "mc slot 1 → 60%"
assert_eq "100%" "$(hw_preset_label mediacodec 4)" "mc slot 4 → 100%"
assert_eq "150%" "$(hw_preset_label mediacodec 7)" "mc slot 7 → 150%"

# Unknown backend → fallback
assert_eq "—" "$(hw_preset_label bogus_backend 4)" "unknown → em-dash"

# HW_PRESET_NAMES contine 7 elemente, default este Quality (slot 4)
assert_eq "7" "${#HW_PRESET_NAMES[@]}" "HW_PRESET_NAMES are 7 sloturi"
assert_eq "Ultrafast" "${HW_PRESET_NAMES[0]}" "slot 1 = Ultrafast"
assert_eq "Quality"   "${HW_PRESET_NAMES[3]}" "slot 4 = Quality (default)"
assert_eq "Veryslow"  "${HW_PRESET_NAMES[6]}" "slot 7 = Veryslow"
