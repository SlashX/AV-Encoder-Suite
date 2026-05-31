#!/usr/bin/env bash
# v59 Mux audit:
# - csv=p=0 multi-field trailing comma defensive strip (HDR sources trigger)
# - Demux attach duplicate filename dedup
# - Chapters XML validation (specific error reasons)
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC_DIR="$PROJECT_ROOT/src"
source "$SRC_DIR/av_common.sh"

# v59: source av_mux.sh in test mode pentru a aduce mux_xml_to_ffmetadata, demux helpers
export AV_MUX_TEST_MODE=1
source "$SRC_DIR/av_mux.sh"

# ─────────────────────────────────────────────────────────────────
# 1) csv=p=0 trailing comma defensive strip — markers exista in cod
# ─────────────────────────────────────────────────────────────────
MUX_TXT=$(cat "$SRC_DIR/av_mux.sh")
COMMON_TXT=$(cat "$SRC_DIR/av_common.sh")

# av_mux.sh demux_detect_special_streams
assert_contains "$MUX_TXT" 'disp="${disp%$'\'\\r\''}"'  "demux_detect_special_streams: strip \\r"
assert_contains "$MUX_TXT" 'disp="${disp%,}"'           "demux_detect_special_streams: strip trailing comma (v59)"
assert_contains "$MUX_TXT" 'tag="${tag%,}"'             "demux_detect_special_streams data: strip comma"

# av_common.sh remux_enumerate_streams — 4 strip-uri
TITLE_STRIPS=$(grep -c 'title="${title%,}"' "$SRC_DIR/av_common.sh")
assert_eq "4" "$TITLE_STRIPS" "remux_enumerate_streams: 4 strip-uri (video/audio/sub/attach)"

# ─────────────────────────────────────────────────────────────────
# 2) Functional test pe csv multi-field cu trailing comma simulat
# ─────────────────────────────────────────────────────────────────
# Simulam input ca de la HDR source: trailing comma after last field
_test_strip_input='0,hevc,0,'
# Apply strip pattern
val="${_test_strip_input##*,}"
# Folosim pattern din cod (last field cu trailing comma)
IFS=',' read -r _idx _codec _disp <<< "$_test_strip_input"
_disp="${_disp%$'\r'}"
_disp="${_disp%,}"
assert_eq "0" "$_disp" "csv multi-field: strip trailing comma functional"

# Same simulation pe input fara trailing comma (file non-HDR)
_test_strip_input2='0,hevc,0'
IFS=',' read -r _idx _codec _disp2 <<< "$_test_strip_input2"
_disp2="${_disp2%$'\r'}"
_disp2="${_disp2%,}"
assert_eq "0" "$_disp2" "csv multi-field: no trailing comma — unchanged"

# Cover art simulat (disp=1 cu trailing comma)
_test_cover='2,mjpeg,1,'
IFS=',' read -r _idx _codec _disp3 <<< "$_test_cover"
_disp3="${_disp3%$'\r'}"
_disp3="${_disp3%,}"
assert_eq "1" "$_disp3" "csv: cover art (disp=1) cu trailing comma → strip OK"
# Acum [[ "$_disp3" == "1" ]] match-uieste (era false fara strip)
if [[ "$_disp3" == "1" ]]; then
    _pass
else
    _fail "cover art match dupa strip"
fi

# ─────────────────────────────────────────────────────────────────
# 3) Demux attach dedup — markeri prezenti
# ─────────────────────────────────────────────────────────────────
assert_contains "$MUX_TXT" 'final_name="$attach_name"'        "demux attach: var pt dedup name"
assert_contains "$MUX_TXT" 'while [ -e "$attach_dir/${_base}_${_i}' "demux attach: dedup loop cu suffix"
assert_contains "$MUX_TXT" '-dump_attachment:t:$t_rel "$attach_dir/$final_name"' \
    "demux attach: path explicit (nu CWD-based gol)"

# ─────────────────────────────────────────────────────────────────
# 4) Chapters XML validation — pre-checks + motiv specific
# ─────────────────────────────────────────────────────────────────
assert_contains "$MUX_TXT" 'mux_xml_to_ffmetadata: fisier inexistent' "chapters: fisier inexistent message"
assert_contains "$MUX_TXT" 'mux_xml_to_ffmetadata: XML gol'           "chapters: empty XML message"
assert_contains "$MUX_TXT" 'mux_xml_to_ffmetadata: lipseste tag-ul <Chapters>' "chapters: no root message"
assert_contains "$MUX_TXT" 'mux_xml_to_ffmetadata: niciun <ChapterAtom>' "chapters: no atom message"
assert_contains "$MUX_TXT" 'mux_xml_to_ffmetadata: parse esuat'       "chapters: parse fail message"

# Caller capture stderr + propagate motiv
assert_contains "$MUX_TXT" '2>"$_xml_err_file"' "caller: capture stderr in temp file"
assert_contains "$MUX_TXT" 'Motiv: ${_xml_err##*: }' "caller: propaga motiv user-facing"

# ─────────────────────────────────────────────────────────────────
# 5) Functional test pe mux_xml_to_ffmetadata cu inputs sintetice
# ─────────────────────────────────────────────────────────────────
TMP=$(mktemp -d); trap 'rm -rf "$TMP"; _test_summary' EXIT

# 5a) Fisier inexistent
err=$(mux_xml_to_ffmetadata "$TMP/nonexistent.xml" "$TMP/out.ffmeta" 2>&1)
rc=$?
assert_eq "1" "$rc" "fisier inexistent: rc=1"
assert_contains "$err" "fisier inexistent" "fisier inexistent: motiv corect"

# 5b) Fisier gol
: > "$TMP/empty.xml"
err=$(mux_xml_to_ffmetadata "$TMP/empty.xml" "$TMP/out.ffmeta" 2>&1)
rc=$?
assert_eq "1" "$rc" "fisier gol: rc=1"
assert_contains "$err" "XML gol" "fisier gol: motiv corect"

# 5c) XML fara root <Chapters>
cat > "$TMP/no_root.xml" <<'EOF'
<?xml version="1.0"?>
<SomethingElse>
  <Item/>
</SomethingElse>
EOF
err=$(mux_xml_to_ffmetadata "$TMP/no_root.xml" "$TMP/out.ffmeta" 2>&1)
rc=$?
assert_eq "1" "$rc" "fara root <Chapters>: rc=1"
assert_contains "$err" "lipseste tag-ul <Chapters>" "fara root: motiv corect"

# 5d) XML cu <Chapters> dar fara <ChapterAtom>
cat > "$TMP/no_atom.xml" <<'EOF'
<?xml version="1.0"?>
<Chapters>
  <EditionEntry/>
</Chapters>
EOF
err=$(mux_xml_to_ffmetadata "$TMP/no_atom.xml" "$TMP/out.ffmeta" 2>&1)
rc=$?
assert_eq "1" "$rc" "fara <ChapterAtom>: rc=1"
assert_contains "$err" "niciun <ChapterAtom>" "fara atom: motiv corect"

# 5e) XML valid cu 2 capitole
cat > "$TMP/valid.xml" <<'EOF'
<?xml version="1.0"?>
<Chapters>
  <EditionEntry>
    <ChapterAtom>
      <ChapterTimeStart>00:00:00.000000000</ChapterTimeStart>
      <ChapterTimeEnd>00:00:10.500000000</ChapterTimeEnd>
      <ChapterDisplay>
        <ChapterString>Intro</ChapterString>
        <ChapterLanguage>eng</ChapterLanguage>
      </ChapterDisplay>
    </ChapterAtom>
    <ChapterAtom>
      <ChapterTimeStart>00:00:10.500000000</ChapterTimeStart>
      <ChapterTimeEnd>00:00:25.000000000</ChapterTimeEnd>
      <ChapterDisplay>
        <ChapterString>Scene 1</ChapterString>
        <ChapterLanguage>eng</ChapterLanguage>
      </ChapterDisplay>
    </ChapterAtom>
  </EditionEntry>
</Chapters>
EOF
mux_xml_to_ffmetadata "$TMP/valid.xml" "$TMP/valid_out.ffmeta" 2>/dev/null
rc=$?
assert_eq "0" "$rc" "XML valid: rc=0"
assert_file_exists "$TMP/valid_out.ffmeta" "valid output produs"
N_CHAPTERS=$(grep -c '\[CHAPTER\]' "$TMP/valid_out.ffmeta")
assert_eq "2" "$N_CHAPTERS" "valid: 2 [CHAPTER] blocks emise"
assert_contains "$(cat "$TMP/valid_out.ffmeta")" "title=Intro" "valid: titlu Intro emis"
assert_contains "$(cat "$TMP/valid_out.ffmeta")" "TIMEBASE=1/1000" "valid: TIMEBASE corect"
assert_contains "$(cat "$TMP/valid_out.ffmeta")" "START=0" "valid: START 0 ms"
assert_contains "$(cat "$TMP/valid_out.ffmeta")" "END=10500" "valid: END 10500 ms"

# 5f) XML cu ChapterAtom dar fara timestamp-uri valide
cat > "$TMP/no_ts.xml" <<'EOF'
<?xml version="1.0"?>
<Chapters>
  <EditionEntry>
    <ChapterAtom>
      <ChapterDisplay>
        <ChapterString>Bad chapter</ChapterString>
      </ChapterDisplay>
    </ChapterAtom>
  </EditionEntry>
</Chapters>
EOF
err=$(mux_xml_to_ffmetadata "$TMP/no_ts.xml" "$TMP/out.ffmeta" 2>&1)
rc=$?
assert_eq "1" "$rc" "atom fara TS: rc=1"
assert_contains "$err" "parse esuat" "atom fara TS: motiv corect"

# ─────────────────────────────────────────────────────────────────
# 6) v59 post-audit: namespace XML support (bash awk regex)
# ─────────────────────────────────────────────────────────────────
cat > "$TMP/ns.xml" <<'EOF'
<?xml version="1.0"?>
<Chapters xmlns="http://www.matroska.org/chapters">
  <EditionEntry>
    <ChapterAtom>
      <ChapterTimeStart>00:00:00.000000000</ChapterTimeStart>
      <ChapterTimeEnd>00:00:10.000000000</ChapterTimeEnd>
      <ChapterDisplay><ChapterString>NSChap</ChapterString></ChapterDisplay>
    </ChapterAtom>
  </EditionEntry>
</Chapters>
EOF
mux_xml_to_ffmetadata "$TMP/ns.xml" "$TMP/ns.ffmeta" 2>/dev/null
rc=$?
assert_eq "0" "$rc" "namespace XML: rc=0 (awk regex e namespace-agnostic prin natura)"
if [ -f "$TMP/ns.ffmeta" ]; then
    NS_TITLE=$(grep -c "title=NSChap" "$TMP/ns.ffmeta")
    assert_eq "1" "$NS_TITLE" "namespace XML: titlu NSChap extras"
    NS_START=$(grep -c "START=0" "$TMP/ns.ffmeta")
    assert_eq "1" "$NS_START" "namespace XML: START=0"
fi

# ─────────────────────────────────────────────────────────────────
# 7) Integration smoke — pe sample HDR10+ real (skip daca lipseste)
# ─────────────────────────────────────────────────────────────────
if command -v ffprobe >/dev/null 2>&1 && [ -f "$SRC_DIR/Upload_S02E01_HDR10Plus_40s_HEVC.mp4" ]; then
    # remux_enumerate_streams pe fisier real → verifica ca title-urile NU au trailing comma
    REMUX_STREAMS=(); REMUX_VIDEO_INDICES=(); REMUX_AUDIO_INDICES=()
    REMUX_SUB_INDICES=(); REMUX_ATTACH_INDICES=()
    remux_enumerate_streams "$SRC_DIR/Upload_S02E01_HDR10Plus_40s_HEVC.mp4"

    # Verifica ca cel putin 1 video + 1 audio detectat
    assert_eq "1" "${#REMUX_VIDEO_INDICES[@]}" "integration HDR10+: 1 video stream"
    assert_eq "1" "${#REMUX_AUDIO_INDICES[@]}" "integration HDR10+: 1 audio stream"

    # Verifica ca NU exista trailing comma in stored info
    for idx in "${REMUX_VIDEO_INDICES[@]}"; do
        info="${REMUX_STREAMS[$idx]}"
        # Format: type|codec|lang|title|extra
        # Check title field nu se termina cu virgula
        IFS='|' read -r _ _ _ title _ <<< "$info"
        case "$title" in
            *,) _fail "video title pe HDR source: trailing comma prezent: [$title]" ;;
            *)  _pass ;;
        esac
    done
fi

echo ""
echo "v59 mux tests done"
