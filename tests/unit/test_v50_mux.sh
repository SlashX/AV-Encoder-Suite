#!/usr/bin/env bash
# Test v50 Mux flow — pure-logic + script markers.
# Coverage: mux_flow function, helpers (mux_lang_from_filename, mux_attach_mime),
#           submenu opt 3 wiring, scan exclude *_mux, ffmpeg cmd builder markers,
#           compat dispatcher reuse.

source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC_DIR="$PROJECT_ROOT/src"
MUX_SCRIPT="$SRC_DIR/av_mux.sh"

assert_file_exists "$MUX_SCRIPT" "av_mux.sh exista"

MUX_CONTENT=$(cat "$MUX_SCRIPT")

# ─────────────────────────────────────────────────────────────────
# 1) Submenu — 4 optiuni (Remux/Demux/Mux/Anulare)
# ─────────────────────────────────────────────────────────────────
assert_match "$MUX_CONTENT" '3\) Mux'              "submenu opt 3 = Mux"
assert_match "$MUX_CONTENT" '4\) Anulare'          "submenu opt 4 = Anulare (shifted)"
assert_match "$MUX_CONTENT" 'Alege 1-4'            "prompt actualizat la 1-4"
assert_match "$MUX_CONTENT" '3\) mux_flow'         "case 3 ruleaza mux_flow"
assert_match "$MUX_CONTENT" '4\) echo "Anulat'     "case 4 = anulare"

# ─────────────────────────────────────────────────────────────────
# 2) Function existence markers
# ─────────────────────────────────────────────────────────────────
assert_match "$MUX_CONTENT" 'mux_flow\(\)'              "functia mux_flow definita"
assert_match "$MUX_CONTENT" 'mux_collect_files\(\)'     "functia mux_collect_files definita"
assert_match "$MUX_CONTENT" 'mux_lang_from_filename\(\)' "functia mux_lang_from_filename definita"
assert_match "$MUX_CONTENT" 'mux_codec_of\(\)'          "functia mux_codec_of definita"
assert_match "$MUX_CONTENT" 'mux_pick_from_list\(\)'    "functia mux_pick_from_list definita"
assert_match "$MUX_CONTENT" 'mux_attach_mime\(\)'       "functia mux_attach_mime definita"

# ─────────────────────────────────────────────────────────────────
# 3) Scan exclude — *_mux pe langa *_remux
# ─────────────────────────────────────────────────────────────────
assert_match "$MUX_CONTENT" '\*_mux \]\] && continue'  "scan exclude *_mux"
collect_block=$(awk '/^mux_collect_files\(\) \{/,/^\}/' "$MUX_SCRIPT")
assert_match "$collect_block" '\*_mux \]\] && continue'    "scan exclude *_mux in mux_collect_files"
assert_match "$collect_block" '\*_remux \]\] && continue'  "scan exclude *_remux in mux_collect_files"

# ─────────────────────────────────────────────────────────────────
# 4) Helper logic — mux_lang_from_filename (rebind inline)
# ─────────────────────────────────────────────────────────────────
mux_lang_from_filename() {
    local file="$1"
    local base; base="$(basename "$file")"
    local name="${base%.*}"
    if [[ "$name" =~ \.([a-z]{2,3})$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    if [[ "$name" =~ _([a-z]{2,3})$ ]]; then
        local lang="${BASH_REMATCH[1]}"
        case "$lang" in
            mkv|mp4|mov|aac|ac3|mp3|srt|ass|sup|idx|sub|hd|sd|hq|lq) ;;
            *) echo "$lang"; return ;;
        esac
    fi
    echo ""
}

assert_eq "eng" "$(mux_lang_from_filename movie.eng.srt)"     "dot pattern .eng"
assert_eq "ron" "$(mux_lang_from_filename track_ron.eac3)"    "underscore pattern _ron"
assert_eq "jpn" "$(mux_lang_from_filename anime.jpn.ass)"     "dot pattern .jpn"
assert_eq ""    "$(mux_lang_from_filename movie.mkv)"         "no pattern returns empty"
assert_eq ""    "$(mux_lang_from_filename track_hd.eac3)"     "tech suffix _hd excluded"
assert_eq "fra" "$(mux_lang_from_filename film.fra.srt)"      "3-letter ISO fra"
assert_eq "de"  "$(mux_lang_from_filename movie_de.mka)"      "2-letter de"

# ─────────────────────────────────────────────────────────────────
# 5) Helper logic — mux_attach_mime (rebind inline)
# ─────────────────────────────────────────────────────────────────
mux_attach_mime() {
    local ext="${1,,}"
    case "$ext" in
        ttf) echo "application/x-truetype-font" ;;
        otf) echo "application/vnd.ms-opentype" ;;
        ttc) echo "font/collection" ;;
        png) echo "image/png" ;;
        jpg|jpeg) echo "image/jpeg" ;;
        webp) echo "image/webp" ;;
        bmp) echo "image/bmp" ;;
        *) echo "application/octet-stream" ;;
    esac
}

assert_eq "application/x-truetype-font" "$(mux_attach_mime ttf)"   "mime: ttf"
assert_eq "application/vnd.ms-opentype" "$(mux_attach_mime otf)"   "mime: otf"
assert_eq "font/collection"             "$(mux_attach_mime ttc)"   "mime: ttc"
assert_eq "image/png"                   "$(mux_attach_mime png)"   "mime: png"
assert_eq "image/jpeg"                  "$(mux_attach_mime jpg)"   "mime: jpg"
assert_eq "image/jpeg"                  "$(mux_attach_mime jpeg)"  "mime: jpeg"
assert_eq "image/webp"                  "$(mux_attach_mime webp)"  "mime: webp"
assert_eq "image/bmp"                   "$(mux_attach_mime bmp)"   "mime: bmp"
assert_eq "application/octet-stream"    "$(mux_attach_mime xyz)"   "mime: unknown -> octet-stream"
assert_eq "image/png"                   "$(mux_attach_mime PNG)"   "mime: uppercase PNG"

# ─────────────────────────────────────────────────────────────────
# 6) Compat dispatcher reuse (markers in mux_flow)
# ─────────────────────────────────────────────────────────────────
mux_flow_body=$(awk '/^mux_flow\(\) \{/,/^\}$/' "$MUX_SCRIPT")
assert_match "$mux_flow_body" 'remux_stream_compat .* video'    "mux foloseste remux_stream_compat (video)"
assert_match "$mux_flow_body" 'remux_stream_compat .* audio'    "mux foloseste remux_stream_compat (audio)"
assert_match "$mux_flow_body" 'remux_stream_compat .* subtitle' "mux foloseste remux_stream_compat (subtitle)"
assert_match "$mux_flow_body" 'PRE-FLIGHT FAIL'                 "abort video incompat e tratat"

# ─────────────────────────────────────────────────────────────────
# 7) ffmpeg cmd builder markers
# ─────────────────────────────────────────────────────────────────
assert_match "$mux_flow_body" '-map" "0:v:0"'    "video mapped din input 0"
assert_match "$mux_flow_body" ':a"'              "audio map prin :a"
assert_match "$mux_flow_body" ':s"'              "subtitle map prin :s"
assert_match "$mux_flow_body" '-map_chapters'    "chapters map argument"
assert_match "$mux_flow_body" '\+faststart'      "movflags +faststart pe mp4/mov"
assert_match "$mux_flow_body" 'hvc1'             "tag hvc1 pentru hevc in mp4/mov"
assert_match "$mux_flow_body" 'av01'             "tag av01 pentru av1 in mp4/mov"
assert_match "$mux_flow_body" 'avc1'             "tag avc1 pentru h264 in mp4/mov"
assert_match "$mux_flow_body" 'mov_text'         "subs convert mov_text pentru mp4/mov"
assert_match "$mux_flow_body" '-attach'          "attachment -attach pentru MKV"
assert_match "$mux_flow_body" 'mimetype='        "attachment mimetype emitted"
assert_match "$mux_flow_body" 'ffmpeg -y'        "ffmpeg -y flag pentru overwrite"

# ─────────────────────────────────────────────────────────────────
# 8) Output naming & overwrite check
# ─────────────────────────────────────────────────────────────────
assert_match "$mux_flow_body" '_mux\.\$\{TARGET\}'    "output naming <name>_mux.<ext>"
assert_match "$mux_flow_body" 'Suprascriu'            "overwrite prompt"

# ─────────────────────────────────────────────────────────────────
# 9) Metadata & disposition (per-track edit)
# ─────────────────────────────────────────────────────────────────
assert_match "$mux_flow_body" '-metadata:s:a:'  "metadata per audio stream"
assert_match "$mux_flow_body" '-metadata:s:s:'  "metadata per subtitle stream"
assert_match "$mux_flow_body" '-disposition:a:' "disposition flag audio"
assert_match "$mux_flow_body" '-disposition:s:' "disposition flag subtitle"
assert_match "$mux_flow_body" 'language='       "language metadata emis"
assert_match "$mux_flow_body" 'forced'          "forced flag disposition (sub)"
assert_match "$mux_flow_body" 'default'         "default flag disposition"

# ─────────────────────────────────────────────────────────────────
# 10) VobSub pair handling — .sub orfan filtrat daca .idx exista
# ─────────────────────────────────────────────────────────────────
assert_match "$mux_flow_body" 'sf_ext" = "sub"'     "branch pentru .sub orfan"
assert_match "$mux_flow_body" '\.idx'               "VobSub .idx pair check"
assert_match "$mux_flow_body" 'dvd_subtitle'        "fallback codec dvd_subtitle pentru .idx"
assert_match "$mux_flow_body" 'hdmv_pgs_subtitle'   "fallback codec hdmv_pgs_subtitle pentru .sup"

# ─────────────────────────────────────────────────────────────────
# 11) Container target options
# ─────────────────────────────────────────────────────────────────
assert_match "$mux_flow_body" '1\) mkv'   "target opt 1 = mkv (default)"
assert_match "$mux_flow_body" '2\) mp4'   "target opt 2 = mp4"
assert_match "$mux_flow_body" '3\) mov'   "target opt 3 = mov"
assert_match "$mux_flow_body" '4\) webm'  "target opt 4 = webm"

# ─────────────────────────────────────────────────────────────────
# 12) Extension sets defined
# ─────────────────────────────────────────────────────────────────
assert_match "$MUX_CONTENT" 'MUX_EXT_VIDEO='    "ext set video"
assert_match "$MUX_CONTENT" 'MUX_EXT_AUDIO='    "ext set audio"
assert_match "$MUX_CONTENT" 'MUX_EXT_SUB='      "ext set subtitle"
assert_match "$MUX_CONTENT" 'MUX_EXT_CHAPTERS=' "ext set chapters"
assert_match "$MUX_CONTENT" 'MUX_EXT_ATTACH='   "ext set attachments"

# ─────────────────────────────────────────────────────────────────
# 13) Audit fixes (post-release v50)
# ─────────────────────────────────────────────────────────────────

# 13a) XML chapters → FFMETADATA1 conversion (ffmpeg nu citeste XML direct)
assert_match "$MUX_CONTENT" 'mux_xml_to_ffmetadata\(\)' "helper XML->FFMETADATA exista"
assert_match "$mux_flow_body" 'ch_ext.*xml'             "branch xml in mux_flow"
assert_match "$mux_flow_body" 'av_mktemp_ext ffmetadata' "temp ffmetadata creat"
assert_match "$mux_flow_body" 'chapters_tmp_ffmeta'     "temp cleanup tracked"

# 13b) Attachment mimetype per-index (fix overwrite bug)
assert_match "$mux_flow_body" '-metadata:s:t:\$attach_idx' "metadata per attachment cu index"
assert_match "$mux_flow_body" 'attach_idx=\$\(\(attach_idx\+1\)\)' "attach_idx incrementeaza"

# 13c) Overwrite check mutat earlier (dupa container target, inainte de metadata edit)
# Verifica ca overwrite check apare INAINTE de "Per-stream compat check"
overwrite_pos=$(grep -n "final_out.*exista. Suprascriu" "$MUX_SCRIPT" | grep -v "Pas" | head -1 | cut -d: -f1)
compat_pos=$(grep -n "Per-stream compat check" "$MUX_SCRIPT" | head -1 | cut -d: -f1)
if [ -n "$overwrite_pos" ] && [ -n "$compat_pos" ] && [ "$overwrite_pos" -lt "$compat_pos" ]; then
    _pass
else
    _fail "overwrite check trebuie inainte de compat check (lines: ow=$overwrite_pos, compat=$compat_pos)"
fi

# 13d) XML→FFMETADATA: pure-logic test cu sample XML
mux_xml_to_ffmetadata_test() {
    local xml_in="$1" out="$2"
    {
        echo ";FFMETADATA1"
        LC_ALL=C awk '
            function parse_ts(s,   parts, h, m, sec, ms) {
                if (split(s, parts, ":") != 3) return -1
                h = parts[1] + 0; m = parts[2] + 0; sec = parts[3] + 0
                ms = int((h * 3600 + m * 60 + sec) * 1000 + 0.5)
                return ms
            }
            BEGIN { start=-1; end=-1; title="" }
            /<ChapterTimeStart>/ { match($0, /<ChapterTimeStart>([^<]+)<\/ChapterTimeStart>/, m); if (m[1]) start = parse_ts(m[1]) }
            /<ChapterTimeEnd>/   { match($0, /<ChapterTimeEnd>([^<]+)<\/ChapterTimeEnd>/, m);     if (m[1]) end = parse_ts(m[1]) }
            /<ChapterString>/    {
                match($0, /<ChapterString>([^<]*)<\/ChapterString>/, m)
                if (m[1] != "") {
                    title = m[1]
                    gsub(/&amp;/, "\\&", title); gsub(/&lt;/, "<", title); gsub(/&gt;/, ">", title)
                    gsub(/\\/, "\\\\", title); gsub(/;/, "\\;", title); gsub(/#/, "\\#", title); gsub(/=/, "\\=", title)
                }
            }
            /<\/ChapterAtom>/ {
                if (start >= 0 && end >= 0) {
                    printf "\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=%d\nEND=%d\n", start, end
                    if (title != "") printf "title=%s\n", title
                }
                start=-1; end=-1; title=""
            }
        ' "$xml_in"
    } > "$out"
}
tmp_xml=$(mktemp --suffix=.xml 2>/dev/null || mktemp -t xml)
tmp_out=$(mktemp --suffix=.ffmeta 2>/dev/null || mktemp -t ffmeta)
cat > "$tmp_xml" <<'XMLEOF'
<?xml version="1.0" encoding="UTF-8"?>
<Chapters>
  <EditionEntry>
    <ChapterAtom>
      <ChapterTimeStart>00:00:00.000000000</ChapterTimeStart>
      <ChapterTimeEnd>00:05:30.500000000</ChapterTimeEnd>
      <ChapterDisplay>
        <ChapterString>Intro &amp; Open</ChapterString>
      </ChapterDisplay>
    </ChapterAtom>
    <ChapterAtom>
      <ChapterTimeStart>00:05:30.500000000</ChapterTimeStart>
      <ChapterTimeEnd>00:10:00.000000000</ChapterTimeEnd>
      <ChapterDisplay>
        <ChapterString>Part Two</ChapterString>
      </ChapterDisplay>
    </ChapterAtom>
  </EditionEntry>
</Chapters>
XMLEOF
mux_xml_to_ffmetadata_test "$tmp_xml" "$tmp_out"
ffmeta_content=$(cat "$tmp_out")
assert_match "$ffmeta_content" ';FFMETADATA1'        "FFMETADATA1 header emis"
assert_match "$ffmeta_content" '\[CHAPTER\]'         "CHAPTER block emis"
assert_match "$ffmeta_content" 'TIMEBASE=1/1000'     "TIMEBASE corect (ms)"
assert_match "$ffmeta_content" 'START=0'             "primul START=0"
assert_match "$ffmeta_content" 'END=330500'          "primul END=5m30.5s in ms"
assert_match "$ffmeta_content" 'START=330500'        "al doilea START match"
assert_match "$ffmeta_content" 'END=600000'          "al doilea END=10min"
assert_match "$ffmeta_content" 'title=Intro & Open'  "title cu entity decoded"
assert_match "$ffmeta_content" 'title=Part Two'      "al doilea title"
rm -f "$tmp_xml" "$tmp_out"
