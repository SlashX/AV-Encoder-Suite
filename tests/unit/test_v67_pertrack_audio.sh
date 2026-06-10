#!/usr/bin/env bash
# v67 — Selectie audio per-pista (E=encode / C=copy / S=skip).
#   build_track_audio_args = sursa unica scaling/downmix per pista; handle_multi_audio_dialog
#   = dialog + rebuild AUDIO_PARAMS + negative skip maps + AUDIO_LOUDNORM_TRACK. Integrat in
#   run_encode_loop (meniu 1) + av_encoder_audio.sh (meniu 2). PS1: Get-TrackAudioArgs +
#   upgrade flux principal (fix index-shift dupa skip + scaling per-pista) + flux audio-only.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"

COMMON="$(cat "$SCRIPT_DIR/av_common.sh")"
AENC="$(cat "$SCRIPT_DIR/av_encoder_audio.sh")"
ENC_PS1="$(cat "$SCRIPT_DIR/av_encode.ps1")"

# ── 1. bash source-level — helper + dialog + integrare ────────────────
assert_contains "$COMMON" 'build_track_audio_args() {'        "bash: helper build_track_audio_args definit"
assert_contains "$COMMON" 'handle_multi_audio_dialog() {'     "bash: handle_multi_audio_dialog definit"
assert_contains "$COMMON" 'handle_multi_audio_dialog "$file"' "bash: dialog apelat (run loop / encoder)"
assert_contains "$COMMON" 'AUDIO_PERTRACK_CUSTOM:-0}" != "1"' "bash: smart-copy gardat de selectia per-pista"
assert_contains "$COMMON" 'AUDIO_LOUDNORM_TRACK=0; AUDIO_PERTRACK_CUSTOM=0' "bash: reset defensiv state per-pista"
assert_contains "$COMMON" '-map -0:a:$i'                      "bash: negative map pt skip"
assert_contains "$COMMON" 'AV_AUDIO_TRACKS'                   "bash: bypass non-interactiv AV_AUDIO_TRACKS"
assert_contains "$COMMON" 'outidx=$((i - skips_before))'      "bash: index output recalculat dupa skip"

# av_encoder_audio.sh (meniu 2) refoloseste dialogul
assert_contains "$AENC" 'handle_multi_audio_dialog "$file"'   "av_encoder_audio: dialog apelat"
assert_contains "$AENC" 'MAP_FLAGS="-map 0:v -map 0:a? -map 0:s? -map 0:t?"' "av_encoder_audio: MAP_FLAGS pt skip maps"

# ── 2. PS1 source-level — helper + upgrade flux principal + audio-only ─
assert_contains "$ENC_PS1" 'function Get-TrackAudioArgs'      "PS1: helper Get-TrackAudioArgs definit"
assert_contains "$ENC_PS1" 'Get-TrackAudioArgs $audioCodec $outIdx' "PS1 main: helper folosit (scaling per-pista)"
assert_contains "$ENC_PS1" 'Get-TrackAudioArgs $eaCodec $oIdx' "PS1 audio-only: helper folosit"
assert_contains "$ENC_PS1" '$outIdx = $ai - $skipsBefore'     "PS1 main: index output recalculat dupa skip (fix v33)"
assert_contains "$ENC_PS1" '$audioLoudnormTrack'              "PS1: loudnorm pe prima pista re-encodata"
assert_contains "$ENC_PS1" '$env:AV_AUDIO_TRACKS'             "PS1: bypass AV_AUDIO_TRACKS"

# ── 3. Functional — build_track_audio_args (sursa unica) ──────────────
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    source "$SCRIPT_DIR/av_common.sh" 2>/dev/null
    tmpd="$(mktemp -d)"
    trap 'rm -rf "$tmpd"; _test_summary' EXIT
    export INPUT_DIR="$tmpd/in" OUTPUT_DIR="$tmpd/out"; mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"

    assert_eq "-c:a:1 libopus -b:a:1 256k" "$(build_track_audio_args opus 1 6 128k)" "helper: opus 5.1 → 256k @ idx1"
    assert_eq "-c:a:0 aac -b:a:0 768k"     "$(build_track_audio_args aac 0 8 192k)"  "helper: aac 7.1 → 768k @ idx0"
    assert_eq "-c:a:2 ac3 -b:a:2 448k -ac:a:2 6" "$(build_track_audio_args ac3 2 8 224k)" "helper: ac3 7.1 → 448k + downmix 5.1"
    assert_eq "-c:a:0 pcm_s24le"           "$(build_track_audio_args pcm 0 2 24le)"  "helper: pcm s24le"
    assert_eq "-c:a:1 aac -b:a:1 192k -ac:a:1 2" "$(AV_DOWNMIX_STEREO=1 build_track_audio_args aac 1 6 192k)" "helper: AV_DOWNMIX → -ac:a:1 2"

    # sursa cu 3 piste: a:0 5.1, a:1 stereo, a:2 stereo
    src="$tmpd/m.mkv"
    ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=160x120:rate=10" \
        -f lavfi -i "sine=frequency=440:duration=1" -f lavfi -i "sine=frequency=660:duration=1" -f lavfi -i "sine=frequency=880:duration=1" \
        -map 0:v -map 1:a -map 2:a -map 3:a -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
        -filter:a:0 "pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0" -c:a:0 aac -c:a:1 ac3 -c:a:2 aac -shortest "$src" 2>/dev/null

    if [[ -s "$src" ]]; then
        CONTAINER=mkv; AUDIO_CODEC_ARG="opus:128k"

        # (a) AV_AUDIO_TRACKS=all → toate encode cu scaling per-canale
        MAP_FLAGS="-map 0:v -map 0:a? -map 0:s? -map 0:t?"
        AV_AUDIO_TRACKS=all handle_multi_audio_dialog "$src" >/dev/null 2>&1
        assert_contains "$AUDIO_PARAMS" "-c:a:0 libopus -b:a:0 256k" "dialog all: a:0 5.1 → 256k"
        assert_contains "$AUDIO_PARAMS" "-c:a:2 libopus -b:a:2 128k" "dialog all: a:2 stereo → 128k"
        assert_eq "1" "$AUDIO_PERTRACK_CUSTOM" "dialog all: marcat custom (dezactiveaza smart-copy)"

        # (b) AV_AUDIO_TRACKS=0,2 → 0+2 encode, 1 copy (doar -c:a copy base)
        MAP_FLAGS="-map 0:v -map 0:a? -map 0:s? -map 0:t?"
        AV_AUDIO_TRACKS="0,2" handle_multi_audio_dialog "$src" >/dev/null 2>&1
        assert_contains "$AUDIO_PARAMS" "-c:a:0 libopus" "dialog 0,2: a:0 encode"
        assert_contains "$AUDIO_PARAMS" "-c:a:2 libopus" "dialog 0,2: a:2 encode"
        assert_not_contains "$AUDIO_PARAMS" "-c:a:1 libopus" "dialog 0,2: a:1 NU e encode (copy)"

        # (c) single-track → AUDIO_PARAMS neschimbat (default)
        st="$tmpd/s.mkv"
        ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=160x120:rate=10" -f lavfi -i "sine=frequency=440:duration=1" \
            -map 0:v -map 1:a -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -shortest "$st" 2>/dev/null
        AUDIO_PARAMS="SENTINEL"; MAP_FLAGS="-map 0:v -map 0:a?"
        handle_multi_audio_dialog "$st" >/dev/null 2>&1
        assert_eq "SENTINEL" "$AUDIO_PARAMS" "single-track: AUDIO_PARAMS neschimbat (fara dialog)"
        assert_eq "0" "$AUDIO_PERTRACK_CUSTOM" "single-track: NU e custom"

        # (d) loudnorm pe AUDIO_LOUDNORM_TRACK
        AUDIO_NORMALIZE=1; AUDIO_LOUDNORM_TRACK=2
        ln=$(get_loudnorm_filter "$src")
        assert_contains "$ln" "-filter:a:2 loudnorm" "loudnorm: scopat pe pista AUDIO_LOUDNORM_TRACK=2"
        AUDIO_LOUDNORM_TRACK=-1
        ln=$(get_loudnorm_filter "$src")
        assert_eq "" "$ln" "loudnorm: skip cand nicio pista re-encodata (-1)"
        AUDIO_NORMALIZE=0; AUDIO_LOUDNORM_TRACK=0

        # (e) end-to-end: encode multi-track via env (0,2) → opus/ac3-copy/opus
        MAP_FLAGS="-map 0:v -map 0:a? -map 0:s? -map 0:t? -map_metadata 0 -map_chapters 0"
        AV_AUDIO_TRACKS="0,2" handle_multi_audio_dialog "$src" >/dev/null 2>&1
        # shellcheck disable=SC2086
        eval ffmpeg -v error -y -i '"$src"' $MAP_FLAGS -c:v libx264 -preset ultrafast -pix_fmt yuv420p $AUDIO_PARAMS '"$tmpd/o.mkv"' 2>/dev/null
        oc=$(ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 "$tmpd/o.mkv" 2>/dev/null | tr -d '\r' | tr '\n' ' ')
        assert_eq "opus ac3 opus " "$oc" "end-to-end 0,2: a:0+a:2 opus, a:1 copy ac3"

        # (f) end-to-end skip: simulez E/S/E prin negative map + index recalculat
        eval ffmpeg -v error -y -i '"$src"' -map 0:v -map 0:a? -map -0:a:1 -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
            -c:a copy -c:a:0 libopus -b:a:0 256k -c:a:1 libopus -b:a:1 128k '"$tmpd/sk.mkv"' 2>/dev/null
        skc=$(ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 "$tmpd/sk.mkv" 2>/dev/null | tr -d '\r' | tr '\n' ' ')
        assert_eq "opus opus " "$skc" "end-to-end skip a:1: 2 piste opus (ac3 exclus, index output corect)"
    fi
fi
true
