#!/usr/bin/env bash
# v68 — follow-up-uri audio dupa v67:
#   #1 container-compat warning pe pistele COPIATE (warn_incompat_audio_copies, refoloseste
#      remux_stream_compat); #2 smart-copy wording (video copy + audio re-encode, NU "total");
#   #4 AV_AUDIO_DROP env (skip piste non-interactiv); #3 = DRY PS1 (doar in test_v68.ps1).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"

COMMON="$(cat "$SCRIPT_DIR/av_common.sh")"
AENC="$(cat "$SCRIPT_DIR/av_encoder_audio.sh")"

# ── 1. source-level ───────────────────────────────────────────────────
# #1 helper + apel in run loop + av_encoder_audio
assert_contains "$COMMON" 'warn_incompat_audio_copies() {'   "#1: helper warn_incompat_audio_copies definit"
assert_contains "$COMMON" 'remux_stream_compat "$acodec" audio "$container"' "#1: refoloseste matricea remux_stream_compat"
assert_contains "$COMMON" 'warn_incompat_audio_copies "$file"' "#1: apelat in run_encode_loop"
assert_contains "$AENC"   'warn_incompat_audio_copies "$file"' "#1: apelat in av_encoder_audio.sh"
assert_contains "$COMMON" 'AUDIO_REENCODED_INPUTS' "#1: tracking piste re-encodate (pt compat)"
assert_contains "$COMMON" 'AUDIO_SKIPPED_INPUTS'   "#1: tracking piste skip"
# #2 smart-copy wording (nu mai zice "Stream copy total")
assert_contains "$COMMON" 'Copiaza video 1:1 + aplica audio ales' "#2: wording smart-copy clarificat (video copy + audio)"
assert_not_contains "$COMMON" 'Stream copy total in loc de re-encode' "#2: vechea formulare 'total' scoasa"
# #4 AV_AUDIO_DROP
assert_contains "$COMMON" 'AV_AUDIO_DROP' "#4: env AV_AUDIO_DROP suportat"
assert_contains "$COMMON" 'sel[d]="S"'    "#4: AV_AUDIO_DROP marcheaza piste ca skip"

# ── 2. Functional ─────────────────────────────────────────────────────
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    source "$SCRIPT_DIR/av_common.sh" 2>/dev/null
    tmpd="$(mktemp -d)"
    trap 'rm -rf "$tmpd"; _test_summary' EXIT
    export INPUT_DIR="$tmpd/in" OUTPUT_DIR="$tmpd/out"; mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"

    # sursa: a:0 aac, a:1 eac3, a:2 aac
    src="$tmpd/m.mkv"
    ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=160x120:rate=10" \
        -f lavfi -i "sine=frequency=440:duration=1" -f lavfi -i "sine=frequency=660:duration=1" -f lavfi -i "sine=frequency=880:duration=1" \
        -map 0:v -map 1:a -map 2:a -map 3:a -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
        -c:a:0 aac -c:a:1 eac3 -c:a:2 aac -shortest "$src" 2>/dev/null

    if [[ -s "$src" ]]; then
        CONTAINER=mkv; AUDIO_CODEC_ARG="opus:128k"

        # (#1a) mov, default (a:1 eac3 COPIAT) → WARN
        AUDIO_REENCODED_INPUTS="0"; AUDIO_SKIPPED_INPUTS=""
        w=$(CONTAINER=mov warn_incompat_audio_copies "$src" 2>&1 | grep -c "ATENTIE")
        assert_eq "1" "$w" "#1: mov + eac3 copiat → 1 avertisment"
        # (#1b) mkv → 0
        w=$(CONTAINER=mkv warn_incompat_audio_copies "$src" 2>&1 | grep -c "ATENTIE")
        assert_eq "0" "$w" "#1: mkv → niciun avertisment"
        # (#1c) a:1 re-encodat → 0
        AUDIO_REENCODED_INPUTS="0 1"
        w=$(CONTAINER=mov warn_incompat_audio_copies "$src" 2>&1 | grep -c "ATENTIE")
        assert_eq "0" "$w" "#1: a:1 re-encodat (nu copiat) → niciun avertisment"
        # (#1d) a:1 skip → 0
        AUDIO_REENCODED_INPUTS="0"; AUDIO_SKIPPED_INPUTS="1"
        w=$(CONTAINER=mov warn_incompat_audio_copies "$src" 2>&1 | grep -c "ATENTIE")
        assert_eq "0" "$w" "#1: a:1 skip (nu copiat) → niciun avertisment"

        # (#4a) AV_AUDIO_DROP=1 → skip a:1, default track 0 encode
        CONTAINER=mkv; MAP_FLAGS="-map 0:v -map 0:a? -map 0:s? -map 0:t?"
        AV_AUDIO_DROP="1" handle_multi_audio_dialog "$src" >/dev/null 2>&1
        assert_eq "0" "$AUDIO_REENCODED_INPUTS" "#4: AV_AUDIO_DROP=1 → track 0 default encode"
        assert_eq "1" "$AUDIO_SKIPPED_INPUTS"   "#4: AV_AUDIO_DROP=1 → a:1 skip"
        assert_contains "$MAP_FLAGS" "-map -0:a:1" "#4: negative map pt a:1"
        # functional end-to-end
        # shellcheck disable=SC2086
        eval ffmpeg -v error -y -i '"$src"' $MAP_FLAGS -c:v libx264 -preset ultrafast -pix_fmt yuv420p $AUDIO_PARAMS '"$tmpd/o.mkv"' 2>/dev/null
        oc=$(ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 "$tmpd/o.mkv" 2>/dev/null | tr -d '\r' | tr '\n' ' ')
        assert_eq "opus aac " "$oc" "#4 functional: AV_AUDIO_DROP=1 → opus aac (a:0 reenc, a:1 drop, a:2 copy)"

        # (#4b) AV_AUDIO_TRACKS=0 + AV_AUDIO_DROP=2 → encode 0, skip 2, copy 1
        MAP_FLAGS="-map 0:v -map 0:a? -map 0:s? -map 0:t?"
        AV_AUDIO_TRACKS="0" AV_AUDIO_DROP="2" handle_multi_audio_dialog "$src" >/dev/null 2>&1
        assert_eq "0" "$AUDIO_REENCODED_INPUTS" "#4: combo → encode 0"
        assert_eq "2" "$AUDIO_SKIPPED_INPUTS"   "#4: combo → skip 2"
    fi
fi
true
