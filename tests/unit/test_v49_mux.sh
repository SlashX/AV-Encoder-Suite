#!/usr/bin/env bash
# Test v49 Remux container — pure-logic + ffprobe mock.
# Coverage: remux_stream_compat, _remux_preflight extins, av_remux.sh markers,
#           av_hdr_dv_tools.sh refactor (no Remux opt), main menu wiring.

source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC_DIR="$PROJECT_ROOT/src"
source "$SRC_DIR/av_common.sh"

# ─────────────────────────────────────────────────────────────────
# 1) remux_stream_compat — compat matrix per target × stream type
# ─────────────────────────────────────────────────────────────────

# 1a) MKV permisiv — totul "copy"
assert_eq "copy" "$(remux_stream_compat hevc video mkv)" "mkv permisiv: hevc video copy"
assert_eq "copy" "$(remux_stream_compat eac3 audio mkv)" "mkv permisiv: eac3 audio copy"
assert_eq "copy" "$(remux_stream_compat hdmv_pgs_subtitle subtitle mkv)" "mkv permisiv: pgs sub copy"
assert_eq "copy" "$(remux_stream_compat ttf attachment mkv)" "mkv permisiv: attachment copy"

# 1b) MP4 video — hevc/h264/av1 OK, vp8 drop
assert_eq "copy" "$(remux_stream_compat hevc video mp4)" "mp4: hevc copy"
assert_eq "copy" "$(remux_stream_compat h264 video mp4)" "mp4: h264 copy"
assert_eq "copy" "$(remux_stream_compat av1 video mp4)" "mp4: av1 copy"
assert_eq "drop" "$(remux_stream_compat vp8 video mp4)" "mp4: vp8 drop"

# 1c) MP4 audio — aac/eac3 copy, truehd drop
assert_eq "copy" "$(remux_stream_compat aac audio mp4)" "mp4: aac copy"
assert_eq "copy" "$(remux_stream_compat eac3 audio mp4)" "mp4: eac3 copy"
assert_eq "drop" "$(remux_stream_compat truehd audio mp4)" "mp4: truehd drop"
assert_eq "drop" "$(remux_stream_compat dts audio mp4)" "mp4: dts drop"

# 1d) MP4 subtitle — text → convert mov_text, bitmap → drop
assert_eq "convert:mov_text" "$(remux_stream_compat subrip subtitle mp4)" "mp4: subrip -> convert mov_text"
assert_eq "convert:mov_text" "$(remux_stream_compat ass subtitle mp4)" "mp4: ass -> convert mov_text"
assert_eq "copy" "$(remux_stream_compat mov_text subtitle mp4)" "mp4: mov_text copy"
assert_eq "drop" "$(remux_stream_compat hdmv_pgs_subtitle subtitle mp4)" "mp4: pgs drop"
assert_eq "drop" "$(remux_stream_compat dvd_subtitle subtitle mp4)" "mp4: dvd_sub drop"

# 1e) MOV — eac3 drop (different from mp4!), prores copy
assert_eq "copy" "$(remux_stream_compat prores video mov)" "mov: prores copy"
assert_eq "drop" "$(remux_stream_compat eac3 audio mov)" "mov: eac3 DROP (per compat dispatcher)"
assert_eq "drop" "$(remux_stream_compat opus audio mov)" "mov: opus drop"

# 1f) WEBM — restrictiv: doar VP/AV1 + Opus/Vorbis + WebVTT
assert_eq "copy" "$(remux_stream_compat vp9 video webm)" "webm: vp9 copy"
assert_eq "copy" "$(remux_stream_compat av1 video webm)" "webm: av1 copy"
assert_eq "drop" "$(remux_stream_compat hevc video webm)" "webm: hevc DROP"
assert_eq "drop" "$(remux_stream_compat h264 video webm)" "webm: h264 DROP"
assert_eq "copy" "$(remux_stream_compat opus audio webm)" "webm: opus copy"
assert_eq "copy" "$(remux_stream_compat vorbis audio webm)" "webm: vorbis copy"
assert_eq "drop" "$(remux_stream_compat aac audio webm)" "webm: aac DROP"
assert_eq "copy" "$(remux_stream_compat webvtt subtitle webm)" "webm: webvtt copy"
assert_eq "drop" "$(remux_stream_compat subrip subtitle webm)" "webm: subrip DROP"

# 1g) Attachments — drop pe orice non-mkv
assert_eq "drop" "$(remux_stream_compat ttf attachment mp4)" "mp4: attachment drop"
assert_eq "drop" "$(remux_stream_compat otf attachment mov)" "mov: attachment drop"
assert_eq "drop" "$(remux_stream_compat ttf attachment webm)" "webm: attachment drop"

# 1h) Necunoscut → drop
assert_eq "drop" "$(remux_stream_compat fubar123 video mp4)" "mp4: unknown video -> drop"
assert_eq "drop" "$(remux_stream_compat fubar123 audio mp4)" "mp4: unknown audio -> drop"

# ─────────────────────────────────────────────────────────────────
# 2) _remux_preflight — reguli noi v49 (WEBM gate, attach, lossless audio)
# Mock ffprobe pentru query-urile v49.
# ─────────────────────────────────────────────────────────────────
TMPFILE=$(mktemp); echo "fake" > "$TMPFILE"

_mock_v_codec="hevc"
_mock_audios=""
_mock_subs=""
_mock_attachs=""
_mock_tags=""

ffprobe() {
    local args="$*"
    if [[ "$args" == *"select_streams v:0"* ]]; then echo "$_mock_v_codec"; return 0; fi
    if [[ "$args" == *"select_streams a"* ]]; then echo "$_mock_audios"; return 0; fi
    if [[ "$args" == *"select_streams s"* && "$args" != *"select_streams s:0"* ]]; then echo "$_mock_subs"; return 0; fi
    if [[ "$args" == *"select_streams t"* ]]; then echo "$_mock_attachs"; return 0; fi
    if [[ "$args" == *"codec_tag_string"* ]]; then echo "$_mock_tags"; return 0; fi
    if [[ "$args" == *"show_chapters"* ]]; then echo ""; return 0; fi
    return 1
}
export -f ffprobe

# 2a) WEBM + hevc video → FAIL level 2 (video incompat)
_mock_v_codec="hevc"; _mock_audios=""; _mock_subs=""; _mock_attachs=""
_remux_preflight "$TMPFILE" "webm"
assert_eq 2 "$REMUX_PREFLIGHT_LEVEL" "webm+hevc -> level 2 (FAIL)"
joined="${REMUX_PREFLIGHT_NOTES[*]}"
assert_contains "$joined" "WEBM" "note mentions WEBM"

# 2b) WEBM + vp9 video + aac audio → level 1 (audio drop warn)
_mock_v_codec="vp9"; _mock_audios="aac"; _mock_subs=""; _mock_attachs=""
_remux_preflight "$TMPFILE" "webm"
assert_eq 1 "$REMUX_PREFLIGHT_LEVEL" "webm+vp9+aac -> level 1 (audio drop)"

# 2c) WEBM + av1 + opus → level 0 (perfect compat)
_mock_v_codec="av1"; _mock_audios="opus"; _mock_subs=""; _mock_attachs=""
_remux_preflight "$TMPFILE" "webm"
assert_eq 0 "$REMUX_PREFLIGHT_LEVEL" "webm+av1+opus -> level 0 (ok)"

# 2d) MP4 + truehd audio → level 1 (lossless strip)
_mock_v_codec="hevc"; _mock_audios="truehd"; _mock_subs=""; _mock_attachs=""
_remux_preflight "$TMPFILE" "mp4"
assert_eq 1 "$REMUX_PREFLIGHT_LEVEL" "mp4+truehd -> level 1 (strip)"
joined="${REMUX_PREFLIGHT_NOTES[*]}"
assert_contains "$joined" "TrueHD" "note mentions TrueHD"

# 2e) MP4 + PGS subtitle → level 1 (bitmap strip)
_mock_v_codec="hevc"; _mock_audios="aac"; _mock_subs="hdmv_pgs_subtitle"; _mock_attachs=""
_remux_preflight "$TMPFILE" "mp4"
assert_eq 1 "$REMUX_PREFLIGHT_LEVEL" "mp4+pgs -> level 1"
joined="${REMUX_PREFLIGHT_NOTES[*]}"
assert_contains "$joined" "bitmap" "note mentions bitmap"

# 2f) MP4 + attachments → level 1 (attach strip)
_mock_v_codec="hevc"; _mock_audios="aac"; _mock_subs=""; _mock_attachs="10"
_remux_preflight "$TMPFILE" "mp4"
assert_eq 1 "$REMUX_PREFLIGHT_LEVEL" "mp4+attach -> level 1"
joined="${REMUX_PREFLIGHT_NOTES[*]}"
assert_contains "$joined" "atasament" "note mentions atasament"

# 2g) MKV permisiv ramane permisiv chiar cu streams "ostile"
_mock_v_codec="hevc"; _mock_audios="truehd"; _mock_subs="hdmv_pgs_subtitle"; _mock_attachs="20"
_remux_preflight "$TMPFILE" "mkv"
assert_eq 0 "$REMUX_PREFLIGHT_LEVEL" "mkv permisiv chiar cu attach+pgs+truehd"

# ─────────────────────────────────────────────────────────────────
# 3) av_mux.sh — markers + structura (rename v49 av_remux → av_mux)
# ─────────────────────────────────────────────────────────────────
AV_MUX="$SRC_DIR/av_mux.sh"
assert_file_exists "$AV_MUX" "av_mux.sh exista"

# Marker-i critici flow (paritate cu vechiul av_remux)
grep -q "SUPPORTED_INPUT_EXT=(mkv webm mp4 m4v mov ts m2ts mts vob mxf)" "$AV_MUX" && _pass || _fail "Input list completa"
grep -q "SUPPORTED_OUTPUT_EXT=(mkv mp4 mov webm)" "$AV_MUX" && _pass || _fail "Output list: mkv/mp4/mov/webm"
grep -q "_remux\." "$AV_MUX" && _pass || _fail "Remux output naming _remux.<ext>"
grep -q "remux_display_and_select" "$AV_MUX" && _pass || _fail "remux_display_and_select function present"
grep -q "remux_run_for_file" "$AV_MUX" && _pass || _fail "remux_run_for_file function present"
grep -q "mux_parse_selection" "$AV_MUX" && _pass || _fail "mux_parse_selection helper present"

# Compat matrix referit
grep -q "remux_stream_compat" "$AV_MUX" && _pass || _fail "compat dispatcher invocat"

# Map flags pe -map 0:v:rel etc (in remux_run_for_file)
grep -q '0:v:\$rel\|0:v:"\$rel"' "$AV_MUX" && _pass || _fail "video stream mapping per-rel"
grep -q '0:a:\$rel\|0:a:"\$rel"' "$AV_MUX" && _pass || _fail "audio stream mapping per-rel"

# v49: submenu si demux flow markers
grep -q "MUX TOOLS" "$AV_MUX" && _pass || _fail "submenu MUX TOOLS prezent"
grep -q "remux_flow()" "$AV_MUX" && _pass || _fail "remux_flow wrapper prezent"
grep -q "demux_flow()" "$AV_MUX" && _pass || _fail "demux_flow function prezent"
grep -q "demux_display_and_select" "$AV_MUX" && _pass || _fail "demux_display_and_select prezent"
grep -q "demux_run_for_file" "$AV_MUX" && _pass || _fail "demux_run_for_file prezent"
grep -q "demux_subtitle_ext" "$AV_MUX" && _pass || _fail "demux_subtitle_ext helper prezent"
grep -q "demux_cover_ext" "$AV_MUX" && _pass || _fail "demux_cover_ext helper prezent"
grep -q "demux_detect_special_streams" "$AV_MUX" && _pass || _fail "demux special streams detection"
grep -q "demux_generate_chapters_xml" "$AV_MUX" && _pass || _fail "chapters XML generator"
grep -q "DEMUX_COVER_IDX" "$AV_MUX" && _pass || _fail "cover detection array"
grep -q "DEMUX_DATA_IDX" "$AV_MUX" && _pass || _fail "data streams detection array"
grep -q "_chapters\.xml" "$AV_MUX" && _pass || _fail "chapters output naming"
grep -q "_attach" "$AV_MUX" && _pass || _fail "attach folder output"
grep -q "_data" "$AV_MUX" && _pass || _fail "data folder output"
grep -q "DEMUX_EXTRACT_DATA" "$AV_MUX" && _pass || _fail "data extraction opt-in flag"

# ─────────────────────────────────────────────────────────────────
# 3b) Demux helpers — pure logic (subtitle/cover ext mapping)
# ─────────────────────────────────────────────────────────────────
# Sourceaza doar functiile pure (evita main loop). Redefinim aici izolate.
demux_subtitle_ext() {
    local codec="${1,,}"
    case "$codec" in
        subrip|srt) echo "srt" ;; ass|ssa) echo "ass" ;; webvtt) echo "vtt" ;;
        hdmv_pgs_subtitle) echo "sup" ;; dvd_subtitle) echo "sub" ;;
        mov_text|tx3g) echo "srt" ;; *) echo "bin" ;;
    esac
}
demux_cover_ext() {
    local codec="${1,,}"
    case "$codec" in
        mjpeg|jpeg) echo "jpg" ;; png) echo "png" ;;
        webp) echo "webp" ;; bmp) echo "bmp" ;; *) echo "img" ;;
    esac
}

assert_eq "srt" "$(demux_subtitle_ext subrip)"            "demux ext: subrip -> srt"
assert_eq "srt" "$(demux_subtitle_ext SRT)"               "demux ext: SRT (case-insensitive) -> srt"
assert_eq "ass" "$(demux_subtitle_ext ass)"               "demux ext: ass -> ass"
assert_eq "ass" "$(demux_subtitle_ext ssa)"               "demux ext: ssa -> ass"
assert_eq "vtt" "$(demux_subtitle_ext webvtt)"            "demux ext: webvtt -> vtt"
assert_eq "sup" "$(demux_subtitle_ext hdmv_pgs_subtitle)" "demux ext: PGS -> sup"
assert_eq "sub" "$(demux_subtitle_ext dvd_subtitle)"      "demux ext: VobSub -> sub"
assert_eq "srt" "$(demux_subtitle_ext mov_text)"          "demux ext: mov_text -> srt (convert)"
assert_eq "srt" "$(demux_subtitle_ext tx3g)"              "demux ext: tx3g -> srt (convert)"
assert_eq "bin" "$(demux_subtitle_ext fubar)"             "demux ext: unknown -> bin"

assert_eq "jpg"  "$(demux_cover_ext mjpeg)" "cover ext: mjpeg -> jpg"
assert_eq "jpg"  "$(demux_cover_ext jpeg)"  "cover ext: jpeg -> jpg"
assert_eq "png"  "$(demux_cover_ext png)"   "cover ext: png -> png"
assert_eq "webp" "$(demux_cover_ext webp)"  "cover ext: webp -> webp"
assert_eq "img"  "$(demux_cover_ext fubar)" "cover ext: unknown -> img"

# ─────────────────────────────────────────────────────────────────
# 4) parse_selection — sintaxa index / lista / interval / ALL / NONE
# Sourceaza functia direct (av_remux.sh nu o exporta global; o redefinim aici
# pentru testare izolata).
# ─────────────────────────────────────────────────────────────────
parse_selection() {
    local input="$1" max="$2"
    input="${input// /}"
    if [[ -z "$input" || "$input" =~ ^[Aa][Ll][Ll]$ ]]; then
        local i; for ((i=0; i<max; i++)); do echo -n "$i "; done
        echo ""; return 0
    fi
    if [[ "$input" =~ ^[Nn][Oo][Nn][Ee]$ ]]; then echo ""; return 0; fi
    local out=""
    IFS=',' read -ra parts <<< "$input"
    for p in "${parts[@]}"; do
        if [[ "$p" =~ ^[0-9]+-[0-9]+$ ]]; then
            local a="${p%-*}" b="${p#*-}"
            local i; for ((i=a-1; i<=b-1; i++)); do
                [ "$i" -ge 0 ] && [ "$i" -lt "$max" ] && out+="$i "
            done
        elif [[ "$p" =~ ^[0-9]+$ ]]; then
            local i=$((p-1))
            [ "$i" -ge 0 ] && [ "$i" -lt "$max" ] && out+="$i "
        else
            echo "INVALID" >&2; return 1
        fi
    done
    echo "$out"
}

# Trim trailing whitespace pentru comparare uniforma
result=$(parse_selection "ALL" 3 | tr -s ' ')
assert_eq "0 1 2 " "$result" "parse: ALL -> 0 1 2"
result=$(parse_selection "" 3 | tr -s ' ')
assert_eq "0 1 2 " "$result" "parse: empty -> ALL"
result=$(parse_selection "NONE" 3)
assert_eq "" "$result" "parse: NONE -> empty"
result=$(parse_selection "1,3" 5 | tr -s ' ')
assert_eq "0 2 " "$result" "parse: 1,3 -> 0 2"
result=$(parse_selection "1-3" 5 | tr -s ' ')
assert_eq "0 1 2 " "$result" "parse: 1-3 -> 0 1 2"
result=$(parse_selection "1,3-4" 5 | tr -s ' ')
assert_eq "0 2 3 " "$result" "parse: 1,3-4 -> 0 2 3"
result=$(parse_selection "99" 3)
[ -z "${result// /}" ] && _pass || _fail "parse: 99 (out of range) -> empty (got: '$result')"

# ─────────────────────────────────────────────────────────────────
# 5) av_hdr_dv_tools.sh — refactor v49 (no Remux opt)
# ─────────────────────────────────────────────────────────────────
HDV="$SRC_DIR/av_hdr_dv_tools.sh"
assert_file_exists "$HDV" "av_hdr_dv_tools.sh exista"

# Nu mai contine hdv_flow_remux
grep -q "hdv_flow_remux" "$HDV" && _fail "hdv_flow_remux nu trebuie sa mai existe" || _pass

# Submeniu HDR/DV (v56: extins la 7 optiuni — remux ramane in av_mux)
grep -q "Inspect metadata" "$HDV" && _pass || _fail "Inspect inca disponibil"
grep -q "HDR10+ → DV hybrid" "$HDV" && _pass || _fail "HDR10+→DV inca disponibil"
grep -q "Alege 1-7" "$HDV" && _pass || _fail "submeniu HDR/DV cu 7 optiuni (1-7, v56)"

# Mesaj de redirect catre Mux tools (av_mux)
grep -qE "Mux tools|optiunea 7|av_mux" "$HDV" && _pass || _fail "redirect note pentru Mux tools"

# ─────────────────────────────────────────────────────────────────
# 6) av_launcher.sh — main menu wiring (10 opt + av_mux dispatch)
# ─────────────────────────────────────────────────────────────────
LAUNCHER="$SRC_DIR/av_launcher.sh"
assert_file_exists "$LAUNCHER" "av_launcher.sh exista"
grep -qE "Mux tools|remux / demux" "$LAUNCHER" && _pass || _fail "Launcher contine Mux tools"
grep -q "av_mux.sh" "$LAUNCHER" && _pass || _fail "Launcher invoca av_mux.sh"
grep -q "Introdu 1-10" "$LAUNCHER" && _pass || _fail "Launcher prompt 1-10 (10 opt)"

rm -f "$TMPFILE"
