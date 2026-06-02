#!/usr/bin/env bash
# Test helpers Trim/Concat care nu necesita ffmpeg — doar logica filesystem.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
source "$SCRIPT_DIR/av_common.sh"
# v60: helper-ele Trim/Concat mutate din av_common in av_trimconcat.
AV_TRIMCONCAT_TEST_MODE=1 source "$SCRIPT_DIR/av_trimconcat.sh"

# ── tc_scan_leftover_temp — empty / missing AV_TEMP_DIR ──────────────
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"; _test_summary' EXIT

# 1) Director inexistent → return 0 silent
AV_TEMP_DIR="$TMPDIR/nope"
out=$(tc_scan_leftover_temp 2>&1)
assert_eq "" "$out" "no temp dir → silent"

# 2) Director gol → return 0 silent
AV_TEMP_DIR="$TMPDIR/empty"
mkdir -p "$AV_TEMP_DIR"
out=$(tc_scan_leftover_temp 2>&1)
assert_eq "" "$out" "empty temp dir → silent"

# 3) Director cu sub-foldere reziduale (mock interactiv: pipe "1" = pastreaza toate)
AV_TEMP_DIR="$TMPDIR/with_leftover"
mkdir -p "$AV_TEMP_DIR/trim_123_456" "$AV_TEMP_DIR/concat_789_012" "$AV_TEMP_DIR/preview_abc"
out=$(echo "1" | tc_scan_leftover_temp 2>&1)
assert_contains "$out" "Temp" "raporteaza header"
assert_contains "$out" "trim_123_456" "lista trim sub-folder"
assert_contains "$out" "concat_789_012" "lista concat sub-folder"
# Cu choice 1, sub-folderele raman
assert_dir_exists "$AV_TEMP_DIR/trim_123_456" "trim folder pastrat"
assert_dir_exists "$AV_TEMP_DIR/concat_789_012" "concat folder pastrat"
