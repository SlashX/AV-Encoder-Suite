#!/usr/bin/env bash
# v68 — paritate smart-copy bash↔PS1 (#1) + warning compat audio extins la concat (#4).
#   #1: bash smart-copy onoreaza acum selectia per-pista (do_stream_copy al 4-lea arg =
#       AUDIO_PARAMS deja calculate; garda AUDIO_PERTRACK_CUSTOM scoasa) — la fel ca PS1.
#   #4: warn_incompat_audio_copies in av_trimconcat (concat copiaza audio in container ales).
#       trim/batch/burn-in = scutite (folosesc containerul SURSEI → copy mereu compatibil).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"

COMMON="$(cat "$SCRIPT_DIR/av_common.sh")"
TC="$(cat "$SCRIPT_DIR/av_trimconcat.sh")"

# ── 1. #1 source-level — do_stream_copy 4th arg + smart-copy paseaza AUDIO_PARAMS ──
assert_contains "$COMMON" 'audio_override="${4:-}"'                              "#1: do_stream_copy accepta al 4-lea arg (audio override)"
assert_contains "$COMMON" 'if [[ -n "$audio_override" ]]; then sc_audio="$audio_override"; else sc_audio=$(get_audio_params "$file"); fi' "#1: 4th arg sau recalcul (back-compat)"
assert_contains "$COMMON" 'do_stream_copy "$file" "$output" "$MAP_FLAGS" "$AUDIO_PARAMS"' "#1: smart-copy paseaza AUDIO_PARAMS per-pista"
# garda scoasa din CONDITIA smart-copy (ramane doar set/reset/comentariu)
smart_cond="$(awk '/if \[\[ -n "\$_tgt_codec"/,/ENCODE_MODE:-1.*then/' "$SCRIPT_DIR/av_common.sh")"
assert_not_contains "$smart_cond" 'AUDIO_PERTRACK_CUSTOM' "#1: garda AUDIO_PERTRACK_CUSTOM SCOASA din conditia smart-copy"

# ── 2. #4 source-level — warning in concat (NU in trim/burnin) ─────────
assert_contains "$TC" 'warn_incompat_audio_copies "$_cf" "$container" ""' "#4: warning in concat (audio copiat in container ales)"
# warn_incompat acum accepta arg 3/4 explicite (pt all-track)
assert_contains "$COMMON" 'local reenc=" ${3-${AUDIO_REENCODED_INPUTS:-0}} " skipd=" ${4-${AUDIO_SKIPPED_INPUTS:-}} "' "#4: warn_incompat accepta reenc/skip explicit"

# ── 3. Functional ─────────────────────────────────────────────────────
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    source "$SCRIPT_DIR/av_common.sh" 2>/dev/null
    tmpd="$(mktemp -d)"
    trap 'rm -rf "$tmpd"; _test_summary' EXIT
    export INPUT_DIR="$tmpd/in" OUTPUT_DIR="$tmpd/out"; mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"

    # sursa HEVC + 3 audio (aac/ac3/aac) — smart-copy candidate (video=target)
    src="$tmpd/s.mkv"
    ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=160x120:rate=10" \
        -f lavfi -i "sine=frequency=440:duration=1" -f lavfi -i "sine=frequency=660:duration=1" -f lavfi -i "sine=frequency=880:duration=1" \
        -map 0:v -map 1:a -map 2:a -map 3:a -c:v libx265 -x265-params log-level=none -pix_fmt yuv420p -preset ultrafast \
        -c:a:0 aac -c:a:1 ac3 -c:a:2 aac -shortest "$src" 2>/dev/null

    if [[ -s "$src" ]]; then
        CONTAINER=mkv; AUDIO_CODEC_ARG="opus:128k"
        MAP_FLAGS="-map 0:v -map 0:a? -map 0:s? -map 0:t? -map_metadata 0 -map_chapters 0"
        # #1: per-pista 0,2 → smart-copy (do_stream_copy cmd cu AUDIO_PARAMS) onoreaza
        AV_AUDIO_TRACKS="0,2" handle_multi_audio_dialog "$src" >/dev/null 2>&1
        # shellcheck disable=SC2086
        eval ffmpeg -v error -y -i '"$src"' $MAP_FLAGS -c:v copy $AUDIO_PARAMS '"$tmpd/sc.mkv"' 2>/dev/null
        vc=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$tmpd/sc.mkv" 2>/dev/null | tr -d '\r')
        ac=$(ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 "$tmpd/sc.mkv" 2>/dev/null | tr -d '\r' | tr '\n' ' ')
        assert_eq "hevc" "$vc" "#1 functional: smart-copy pastreaza video (copy)"
        assert_eq "opus ac3 opus " "$ac" "#1 functional: smart-copy onoreaza per-pista (a:0/a:2 opus, a:1 copy)"

        # #4: concat-style warning — sursa cu eac3 copiat in mov (all-track, reenc='')
        src2="$tmpd/e.mkv"
        ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=160x120:rate=10" -f lavfi -i "sine=frequency=440:duration=1" \
            -map 0:v -map 1:a -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a eac3 -shortest "$src2" 2>/dev/null
        w=$(warn_incompat_audio_copies "$src2" "mov" "" 2>&1 | grep -c "ATENTIE")
        assert_eq "1" "$w" "#4 functional: concat-style (eac3 copiat in mov, reenc gol) → warning"
        w2=$(warn_incompat_audio_copies "$src2" "mkv" "" 2>&1 | grep -c "ATENTIE")
        assert_eq "0" "$w2" "#4 functional: mkv → niciun warning"
    fi
fi
true
