#!/usr/bin/env bash
# Test hw_table_columns — mapping AV_PLATFORM → coloane HW.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
source "$SCRIPT_DIR/av_common.sh"

# Termux → doar mediacodec
AV_PLATFORM=termux
HW_TABLE_COLS=()
hw_table_columns
assert_eq "1" "${#HW_TABLE_COLS[@]}" "termux: 1 coloana"
assert_eq "mediacodec" "${HW_TABLE_COLS[0]}" "termux: mediacodec"

# macOS → videotoolbox
AV_PLATFORM=macos
HW_TABLE_COLS=()
hw_table_columns
assert_eq "1" "${#HW_TABLE_COLS[@]}" "macos: 1 coloana"
assert_eq "videotoolbox" "${HW_TABLE_COLS[0]}" "macos: videotoolbox"

# Linux → nvenc, vaapi, qsv, amf
AV_PLATFORM=linux
HW_TABLE_COLS=()
hw_table_columns
assert_eq "4" "${#HW_TABLE_COLS[@]}" "linux: 4 coloane"
joined=$(IFS=' '; echo "${HW_TABLE_COLS[*]}")
assert_contains "$joined" "nvenc" "linux: include nvenc"
assert_contains "$joined" "vaapi" "linux: include vaapi"
assert_contains "$joined" "qsv"   "linux: include qsv"
assert_contains "$joined" "amf"   "linux: include amf"
