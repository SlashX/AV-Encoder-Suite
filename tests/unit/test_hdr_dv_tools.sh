#!/usr/bin/env bash
# Test v44 helpers C+D+E: convert_rpu_profile + _remux_preflight + remux_container_with_tag
# Stareaza pure-logic. ffprobe e mockuit ca functie shell pentru _remux_preflight.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
source "$SCRIPT_DIR/av_common.sh"

TMPFILE=$(mktemp)
echo "fake" > "$TMPFILE"
# NU folosi `trap ... EXIT` aici — ar suprascrie _test_summary din framework.
# Cleanup explicit la final (sau in caz de fail; e doar un fisier mic temp).

# ─────────────────────────────────────────────────────────────────
# Mock ffprobe: returneaza valori canned in functie de query.
# Variabile mock — modifica intre teste.
# ─────────────────────────────────────────────────────────────────
_mock_audio="aac"
_mock_sub=""
_mock_tags=""

ffprobe() {
    local args="$*"
    if [[ "$args" == *"select_streams a:0"* ]]; then echo "$_mock_audio"; return 0; fi
    if [[ "$args" == *"select_streams s:0"* ]]; then echo "$_mock_sub"; return 0; fi
    if [[ "$args" == *"codec_tag_string"* ]]; then echo "$_mock_tags"; return 0; fi
    if [[ "$args" == *"select_streams v:0"* && "$args" == *"codec_name"* ]]; then echo "hevc"; return 0; fi
    return 1
}
export -f ffprobe

# ─────────────────────────────────────────────────────────────────
# 1) _remux_preflight — toate regulile
# ─────────────────────────────────────────────────────────────────

# 1a) aac + mp4 → level 0, no notes
_mock_audio="aac"; _mock_sub=""; _mock_tags=""
_remux_preflight "$TMPFILE" "mp4"
assert_eq 0 "$REMUX_PREFLIGHT_LEVEL" "aac+mp4 -> level 0"
assert_eq 0 "${#REMUX_PREFLIGHT_NOTES[@]}" "aac+mp4: 0 notes"

# 1b) eac3 + mov → level 2 (fail)
_mock_audio="eac3"; _mock_sub=""; _mock_tags=""
_remux_preflight "$TMPFILE" "mov"
assert_eq 2 "$REMUX_PREFLIGHT_LEVEL" "eac3+mov -> level 2"
[ "${#REMUX_PREFLIGHT_NOTES[@]}" -gt 0 ] && _pass || _fail "eac3+mov: should have notes"
joined="${REMUX_PREFLIGHT_NOTES[*]}"
assert_match "$joined" "E-AC3" "note mentions E-AC3"

# 1c) eac3 + mp4 → level 0 (E-AC3 e OK in MP4, doar MOV are problema)
_mock_audio="eac3"; _mock_sub=""; _mock_tags=""
_remux_preflight "$TMPFILE" "mp4"
assert_eq 0 "$REMUX_PREFLIGHT_LEVEL" "eac3+mp4 -> level 0 (no problem)"

# 1d) subrip + mp4 → level 1 (warn)
_mock_audio="aac"; _mock_sub="subrip"; _mock_tags=""
_remux_preflight "$TMPFILE" "mp4"
assert_eq 1 "$REMUX_PREFLIGHT_LEVEL" "subrip+mp4 -> level 1"
joined="${REMUX_PREFLIGHT_NOTES[*]}"
assert_contains "$joined" "subrip" "note mentions subrip"

# 1e) ass + mov → level 1
_mock_audio="aac"; _mock_sub="ass"; _mock_tags=""
_remux_preflight "$TMPFILE" "mov"
assert_eq 1 "$REMUX_PREFLIGHT_LEVEL" "ass+mov -> level 1"

# 1f) djmd codec_tag + mp4 → level 1
_mock_audio="aac"; _mock_sub=""; _mock_tags="djmd"
_remux_preflight "$TMPFILE" "mp4"
assert_eq 1 "$REMUX_PREFLIGHT_LEVEL" "djmd+mp4 -> level 1"
joined="${REMUX_PREFLIGHT_NOTES[*]}"
assert_contains "$joined" "DJI" "note mentions DJI"

# 1g) Combinat eac3+mov (fail) + srt (warn) — nivelul max castiga
_mock_audio="eac3"; _mock_sub="subrip"; _mock_tags=""
_remux_preflight "$TMPFILE" "mov"
assert_eq 2 "$REMUX_PREFLIGHT_LEVEL" "eac3+srt+mov -> level 2 (max wins)"
[ "${#REMUX_PREFLIGHT_NOTES[@]}" -ge 2 ] && _pass || _fail "expected ≥2 notes"

# 1h) MKV permisiv — toate codecuri ok
_mock_audio="eac3"; _mock_sub="ass"; _mock_tags="djmd"
_remux_preflight "$TMPFILE" "mkv"
assert_eq 0 "$REMUX_PREFLIGHT_LEVEL" "mkv permisiv -> level 0"
assert_eq 0 "${#REMUX_PREFLIGHT_NOTES[@]}" "mkv: 0 notes"

# 1i) Container necunoscut → level 2
_mock_audio="aac"; _mock_sub=""; _mock_tags=""
_remux_preflight "$TMPFILE" "bogus"
assert_eq 2 "$REMUX_PREFLIGHT_LEVEL" "bogus container -> level 2"

# 1j) Case-insensitive (MP4 majuscul)
_mock_audio="eac3"; _mock_sub=""; _mock_tags=""
_remux_preflight "$TMPFILE" "MOV"
assert_eq 2 "$REMUX_PREFLIGHT_LEVEL" "MOV (uppercase) -> same as mov"

# ─────────────────────────────────────────────────────────────────
# 2) convert_rpu_profile — failure paths (no tool needed)
# ─────────────────────────────────────────────────────────────────

# Missing input file → return 1
convert_rpu_profile "/nonexistent/path.bin" "$TMPFILE.out" 2 hevc 2>/dev/null
assert_nonzero $? "convert: missing rpu_in -> non-zero"

# Default codec routing — verify dispatcher selects right tool
# (function exists check — actual binary calls require dovi_tool installed)
declare -F convert_rpu_profile >/dev/null && _pass || _fail "convert_rpu_profile defined"
declare -F extract_raw_video >/dev/null && _pass || _fail "extract_raw_video defined"
declare -F remux_container_with_tag >/dev/null && _pass || _fail "remux_container_with_tag defined"
declare -F extract_dv_rpu >/dev/null && _pass || _fail "extract_dv_rpu defined"
declare -F _remux_preflight >/dev/null && _pass || _fail "_remux_preflight defined"

# ─────────────────────────────────────────────────────────────────
# 3) remux_container_with_tag — args building (audit fix B1)
#    Mock ffmpeg ca sa capturam argumentele, fara executie reala.
# ─────────────────────────────────────────────────────────────────
_captured_args=""
ffmpeg() {
    _captured_args="$*"
    # Simulam succes: cream un fisier dummy non-empty pentru output (ultimul arg)
    local last_arg=""
    for a in "$@"; do last_arg="$a"; done
    echo "ok" > "$last_arg"
    return 0
}
export -f ffmpeg

# detect_source_codec foloseste ffprobe — _mock_tags e gol, codec_name fallback la "hevc"
_mock_tags=""
OUT_DUMMY=$(mktemp)

# 3a) target=mkv → NU contine "mov_text" (B1 fix)
remux_container_with_tag "$TMPFILE" "$OUT_DUMMY" "mkv" >/dev/null 2>&1
case "$_captured_args" in
    *mov_text*) _fail "mkv must NOT use mov_text in args (got: $_captured_args)" ;;
    *)          _pass ;;
esac
case "$_captured_args" in
    *"-c:s copy"*) _pass ;;
    *)             _fail "mkv must use -c:s copy (got: $_captured_args)" ;;
esac

# 3b) target=mp4 + source HEVC → contine mov_text + tag:v hvc1
remux_container_with_tag "$TMPFILE" "$OUT_DUMMY" "mp4" >/dev/null 2>&1
case "$_captured_args" in
    *mov_text*) _pass ;;
    *)          _fail "mp4 must use mov_text (got: $_captured_args)" ;;
esac
case "$_captured_args" in
    *"-tag:v hvc1"*) _pass ;;
    *)               _fail "mp4 + hevc source must use -tag:v hvc1 (got: $_captured_args)" ;;
esac
case "$_captured_args" in
    *"+faststart"*) _pass ;;
    *)              _fail "mp4 must use +faststart (got: $_captured_args)" ;;
esac

# 3c) target=mov + source HEVC → la fel, mov_text + hvc1
remux_container_with_tag "$TMPFILE" "$OUT_DUMMY" "mov" >/dev/null 2>&1
case "$_captured_args" in
    *mov_text*) _pass ;;
    *)          _fail "mov must use mov_text (got: $_captured_args)" ;;
esac

rm -f "$OUT_DUMMY" "$TMPFILE"
