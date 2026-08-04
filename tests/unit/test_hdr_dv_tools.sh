#!/usr/bin/env bash
# Test v44 helpers C+D: convert_rpu_profile + _remux_preflight
# (v95: partea remux_container_with_tag a disparut odata cu functia — vezi mai jos.)
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
_mock_video="hevc"   # v57: mockable pentru AV1+MOV preflight test

ffprobe() {
    local args="$*"
    # v49: _remux_preflight foloseste select_streams a/s/t (toate stream-urile),
    # nu :0 (primul). Mock raspunde la noua forma.
    if [[ "$args" == *"select_streams v:0"* && "$args" == *"codec_name"* ]]; then echo "$_mock_video"; return 0; fi
    if [[ "$args" == *"select_streams t"* ]]; then echo ""; return 0; fi  # no attachments
    if [[ "$args" == *"select_streams a"* ]]; then echo "$_mock_audio"; return 0; fi
    if [[ "$args" == *"select_streams s"* ]]; then echo "$_mock_sub"; return 0; fi
    if [[ "$args" == *"codec_tag_string"* ]]; then echo "$_mock_tags"; return 0; fi
    if [[ "$args" == *"show_chapters"* ]]; then echo ""; return 0; fi
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
_mock_audio="eac3"; _mock_sub=""; _mock_tags=""; _mock_video="hevc"
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
assert_contains "$joined" "mov_text" "note mentions mov_text conversion"

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

# v57 — AV1 + MOV preflight (ffmpeg refuza, level 2)
_mock_audio="aac"; _mock_sub=""; _mock_tags=""; _mock_video="av1"
_remux_preflight "$TMPFILE" "mov"
assert_eq 2 "$REMUX_PREFLIGHT_LEVEL" "av1+mov -> level 2 (ffmpeg refuza)"
joined="${REMUX_PREFLIGHT_NOTES[*]}"
assert_contains "$joined" "AV1" "note mentions AV1"

# v57 — AV1 + MP4 OK (level 0, fara note legate de AV1)
_mock_audio="aac"; _mock_sub=""; _mock_tags=""; _mock_video="av1"
_remux_preflight "$TMPFILE" "mp4"
assert_eq 0 "$REMUX_PREFLIGHT_LEVEL" "av1+mp4 -> level 0 (compatible)"

# v57 — AV1 + MKV OK (MKV permisiv)
_mock_audio="aac"; _mock_sub=""; _mock_tags=""; _mock_video="av1"
_remux_preflight "$TMPFILE" "mkv"
assert_eq 0 "$REMUX_PREFLIGHT_LEVEL" "av1+mkv -> level 0"

# Reset mock pentru testele de mai jos
_mock_video="hevc"

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
declare -F extract_dv_rpu >/dev/null && _pass || _fail "extract_dv_rpu defined"
declare -F _remux_preflight >/dev/null && _pass || _fail "_remux_preflight defined"

# v95: sectiunea „3) remux_container_with_tag — args building" a fost SCOASA odata cu
# functia, care era cod MORT (zero apelanti in tot src/). Aserţiunile ei nu validau o
# capacitate a suitei, ci o functie pe care nimic n-o executa. Comportamentul REAL e
# acoperit de cod viu: tag-urile hvc1/av01/avc1 in test_v57_codec_tag.{sh,ps1},
# conversia mov_text in test_v94_remux_compat.ps1 + testele av_mux, `+faststart` in
# test_v50_mux.{sh,ps1} si test_v53_features.sh.
rm -f "$TMPFILE"

# ─────────────────────────────────────────────────────────────────
# v57: refactor av_hdr_dv_tools — helper _hdv_combine_with_original
# elimina duplicarea celor 4 ffmpeg combine site-uri.
# ─────────────────────────────────────────────────────────────────
HDV_SCRIPT="$SCRIPT_DIR/av_hdr_dv_tools.sh"
assert_file_exists "$HDV_SCRIPT" "av_hdr_dv_tools.sh prezent"

# Helper definit o singura data
HELPER_DEFS=$(grep -c "^_hdv_combine_with_original()" "$HDV_SCRIPT")
assert_eq "1" "$HELPER_DEFS" "_hdv_combine_with_original definit exact o data"

# 5 call-site-uri (transform / hybrid / remove DV / remove HDR10+ / v76 P7→8.1)
HELPER_CALLS=$(grep -c "_hdv_combine_with_original \"" "$HDV_SCRIPT")
assert_eq "5" "$HELPER_CALLS" "5 call-site-uri _hdv_combine_with_original (4 flow-uri + P7→8.1)"

# Zero invocari ffmpeg directe pentru combine (acceptabil pt extract/bsf/etc, dar nu pt -c copy mux final)
DIRECT_COMBINE=$(grep -c "^[[:space:]]*ffmpeg .* -map 0:v:0 -map 1:a?" "$HDV_SCRIPT")
assert_eq "0" "$DIRECT_COMBINE" "zero ffmpeg combine direct in flow-uri (toate trec prin helper)"

# v57: detect_source_codec NU mai foloseste csv=p=0 (trailing comma bug)
# → toate gate-urile bash `[[ "$codec" == "av1" ]]` lucreaza corect.
COMMON_SH="$SCRIPT_DIR/av_common.sh"
DETECT_BLOCK=$(awk '/^detect_source_codec\(\)/,/^}/' "$COMMON_SH")
echo "$DETECT_BLOCK" | grep -q "default=noprint_wrappers" && _pass || _fail "detect_source_codec foloseste default= (nu csv=p=0)"
echo "$DETECT_BLOCK" | grep -q "csv=p=0" && _fail "detect_source_codec inca foloseste csv=p=0" || _pass

# v57: hybrid + transform_rpu seteaza codec_tag (hvc1/av01) pe MP4/MOV/M4V
# pentru DV-aware player discovery — paritate cu Remove DV flow.
HYBRID_BLOCK=$(awk '/^hdv_flow_hdr10plus_to_dv\(\)/,/^hdv_flow_remove_dv\(\)/' "$HDV_SCRIPT")
echo "$HYBRID_BLOCK" | grep -q 'tag:v hvc1\|tag:v av01' && _pass || _fail "hybrid seteaza -tag:v hvc1/av01"
TRANSFORM_BLOCK=$(awk '/^hdv_flow_transform_rpu\(\)/,/^hdv_flow_inspect\(\)/' "$HDV_SCRIPT")
echo "$TRANSFORM_BLOCK" | grep -q 'tag:v hvc1\|tag:v av01' && _pass || _fail "transform_rpu seteaza -tag:v hvc1/av01"
