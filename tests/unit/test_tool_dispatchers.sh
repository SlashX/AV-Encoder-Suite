#!/usr/bin/env bash
# Test v44 codec-aware tool dispatchers in av_common.sh:
# - tool_for_extract / tool_for_inject (codec×kind dispatch)
# - _check_dovi_tool_for / _check_hdr10plus_tool_for (codec routing)
# - _check_av1_dovi_tool / _check_av1_hdr10plus_tool (cache + lookup)
# - _check_svtav1_hdr10plus_caps (cache behavior)
# - detect_source_codec (basic empty-input handling)
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
source "$SCRIPT_DIR/av_common.sh"

# ─────────────────────────────────────────────────────────────────────
# 1) tool_for_extract — toate combinatiile codec × kind
# ─────────────────────────────────────────────────────────────────────
assert_eq "dovi_tool"           "$(tool_for_extract hevc dovi)"      "hevc + dovi -> dovi_tool"
assert_eq "hdr10plus_tool"      "$(tool_for_extract hevc hdr10plus)" "hevc + hdr10plus -> hdr10plus_tool"
assert_eq "av1dovi_tool"        "$(tool_for_extract av1 dovi)"       "av1 + dovi -> av1dovi_tool"
assert_eq "av1hdr10plus_tool"   "$(tool_for_extract av1 hdr10plus)"  "av1 + hdr10plus -> av1hdr10plus_tool"

# Default codec = hevc (back-compat — apel cu un singur arg / fara argumente)
assert_eq "dovi_tool"      "$(tool_for_extract '' dovi)"       "default codec=hevc + dovi"
assert_eq "hdr10plus_tool" "$(tool_for_extract '' hdr10plus)"  "default codec=hevc + hdr10plus"

# Codec necunoscut (h264/vp9/etc) -> ramura HEVC default (back-compat sigur)
assert_eq "dovi_tool"      "$(tool_for_extract h264 dovi)"     "h264 falls back to hevc tool"
assert_eq "hdr10plus_tool" "$(tool_for_extract vp9 hdr10plus)" "vp9 falls back to hevc tool"

# Kind invalid -> string gol + exit non-zero
out=$(tool_for_extract hevc bogus); rc=$?
assert_eq "" "$out"   "kind invalid -> empty string"
assert_nonzero $rc    "kind invalid -> non-zero exit"

# ─────────────────────────────────────────────────────────────────────
# 2) tool_for_inject — actualmente alias pentru tool_for_extract
# ─────────────────────────────────────────────────────────────────────
assert_eq "dovi_tool"         "$(tool_for_inject hevc dovi)"      "inject hevc dovi"
assert_eq "av1dovi_tool"      "$(tool_for_inject av1 dovi)"       "inject av1 dovi"
assert_eq "av1hdr10plus_tool" "$(tool_for_inject av1 hdr10plus)"  "inject av1 hdr10plus"

# ─────────────────────────────────────────────────────────────────────
# 3) _check_dovi_tool_for — routing pe codec via cache vars
# ─────────────────────────────────────────────────────────────────────
DOVI_TOOL_AVAILABLE=1
AV1_DOVI_TOOL_AVAILABLE=0
_check_dovi_tool_for hevc; assert_zero $?    "hevc routes la _check_dovi_tool (avail=1)"
_check_dovi_tool_for av1;  assert_nonzero $? "av1 routes la _check_av1_dovi_tool (avail=0)"

# Inverseaza: hevc lipseste, av1 instalat
DOVI_TOOL_AVAILABLE=0
AV1_DOVI_TOOL_AVAILABLE=1
_check_dovi_tool_for hevc; assert_nonzero $? "hevc -> 0 cand DOVI_TOOL_AVAILABLE=0"
_check_dovi_tool_for av1;  assert_zero $?    "av1 -> 1 cand AV1_DOVI_TOOL_AVAILABLE=1"

# Default codec=hevc (apel fara arg)
DOVI_TOOL_AVAILABLE=1
_check_dovi_tool_for; assert_zero $? "default codec=hevc"

# ─────────────────────────────────────────────────────────────────────
# 4) _check_hdr10plus_tool_for — same pattern
# ─────────────────────────────────────────────────────────────────────
HDR10PLUS_TOOL_AVAILABLE=1
AV1_HDR10PLUS_TOOL_AVAILABLE=0
_check_hdr10plus_tool_for hevc; assert_zero $?    "hp hevc routes -> 1"
_check_hdr10plus_tool_for av1;  assert_nonzero $? "hp av1 routes -> 0"

HDR10PLUS_TOOL_AVAILABLE=0
AV1_HDR10PLUS_TOOL_AVAILABLE=1
_check_hdr10plus_tool_for hevc; assert_nonzero $? "hp hevc -> 0"
_check_hdr10plus_tool_for av1;  assert_zero $?    "hp av1 -> 1"

# ─────────────────────────────────────────────────────────────────────
# 5) _check_svtav1_hdr10plus_caps — cache behavior
# ─────────────────────────────────────────────────────────────────────
SVTAV1_HDR10PLUS_CAPS=1
_check_svtav1_hdr10plus_caps; assert_zero $?    "caps cache=1 -> true"

SVTAV1_HDR10PLUS_CAPS=0
_check_svtav1_hdr10plus_caps; assert_nonzero $? "caps cache=0 -> false"

# Cache invalidare -> functie probeaza ffmpeg si seteaza cache. Verificam doar ca
# in lipsa ffmpeg (sau cu output gol) nu crash-uieste si returneaza un boolean.
SVTAV1_HDR10PLUS_CAPS=""
_check_svtav1_hdr10plus_caps >/dev/null 2>&1
rc=$?
[[ $rc -eq 0 || $rc -eq 1 ]] && _pass || _fail "caps probe should return 0/1, got $rc"
assert_match "$SVTAV1_HDR10PLUS_CAPS" '^[01]$' "cache populat cu 0 sau 1 dupa probe"

# ─────────────────────────────────────────────────────────────────────
# 6) detect_source_codec — handling pentru input invalid
# ─────────────────────────────────────────────────────────────────────
out=$(detect_source_codec ""); rc=$?
assert_eq "" "$out"    "fisier gol -> string gol"
assert_nonzero $rc     "fisier gol -> non-zero exit"

out=$(detect_source_codec "/nonexistent/file/path.mp4"); rc=$?
assert_eq "" "$out"    "fisier inexistent -> string gol"
assert_nonzero $rc     "fisier inexistent -> non-zero exit"
