#!/usr/bin/env bash
# v66 — Audio re-encode FIX: ordinea `-c:a copy` PRIMUL, apoi `-c:a:0 <codec>`
#   (altfel `-c:a copy` ultimul suprascrie a:0 → track 0 COPIAT, nu re-encodat:
#   alegi Opus, primesti AAC). + loudnorm scopat la a:0 + log → stderr (nu polueaza
#   sirul capturat in AUDIO_PARAMS / LOUDNORM_FILTER). Paritate bash↔PS1.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SCRIPT_DIR="$PROJECT_ROOT/src"
command -v ffmpeg >/dev/null 2>&1 || export PATH="$SCRIPT_DIR:$PATH"

COMMON="$(cat "$SCRIPT_DIR/av_common.sh")"
ENC_PS1="$(cat "$SCRIPT_DIR/av_encode.ps1")"

# ── 1. bash — copy-first (v67: get_audio_params deleaga la build_track_audio_args) ──
assert_contains "$COMMON" '-c:a copy $(build_track_audio_args "$codec" 0 "$channels" "$br")' "bash: get_audio_params copy-first + deleaga la helper"
# build_track_audio_args = sursa unica per-codec (FARA prefix copy — apelantul il pune INAINTE)
assert_contains "$COMMON" '-c:a:$idx aac -b:a:$idx $br'          "bash: helper aac"
assert_contains "$COMMON" '-c:a:$idx libopus -b:a:$idx $br'      "bash: helper opus"
assert_contains "$COMMON" '-c:a:$idx flac -compression_level $br' "bash: helper flac"
assert_contains "$COMMON" '-c:a:$idx eac3 -b:a:$idx $br'         "bash: helper eac3"
assert_contains "$COMMON" '-c:a:$idx ac3 -b:a:$idx $br'          "bash: helper ac3"
assert_contains "$COMMON" '-c:a:$idx pcm_s${br}'                 "bash: helper pcm"
assert_not_contains "$COMMON" '-b:a:0 $br $downmix_flag -c:a copy' "bash: NU mai e vechea ordine (copy last)"

# ── 2. bash — loudnorm scopat la pista re-encodata + log pe stderr (anti-poluare captura) ──
assert_contains "$COMMON" '-filter:a:$lt loudnorm=I=-24'        "bash: loudnorm scopat la pista re-encodata (nu -af)"
assert_contains "$COMMON" 'Loudnorm: analiza volum EBU R128..." >&2' "bash: log loudnorm pe stderr"
assert_contains "$COMMON" '_warn_audio_metadata "$file" >&2'    "bash: warn metadata pe stderr (nu polueaza AUDIO_PARAMS)"

# ── 2b. bash — av_encoder_audio.sh (flux audio-only standalone) ───────
#   Acelasi bug copy-last era si aici (7 ramuri AUDIO_PARAMS) + `local` la
#   nivel de script (in for-loop, NU functie) → "can only be used in a function"
#   → ac3_ch/AC3_FORCE_DOWNMIX nesetate → downmix AC3 7.1 rupt.
AENC="$(cat "$SCRIPT_DIR/av_encoder_audio.sh")"
assert_contains "$AENC" 'AUDIO_PARAMS="-c:a copy -c:a:0 aac -b:a:0 $A_BR'         "av_encoder_audio: aac copy-first"
assert_contains "$AENC" 'AUDIO_PARAMS="-c:a copy -c:a:0 libopus -b:a:0 $A_BR'     "av_encoder_audio: opus copy-first"
assert_contains "$AENC" 'AUDIO_PARAMS="-c:a copy -c:a:0 flac -compression_level'  "av_encoder_audio: flac copy-first"
assert_contains "$AENC" 'AUDIO_PARAMS="-c:a copy -c:a:0 eac3 -b:a:0 $A_BR'        "av_encoder_audio: eac3 copy-first"
assert_contains "$AENC" 'AUDIO_PARAMS="-c:a copy -c:a:0 ac3 -b:a:0 $A_BR'         "av_encoder_audio: ac3 copy-first"
assert_contains "$AENC" 'AUDIO_PARAMS="-c:a copy -c:a:0 pcm_s'                    "av_encoder_audio: pcm copy-first"
assert_not_contains "$AENC" 'local ac3_ch'            "av_encoder_audio: FARA local ac3_ch (script-scope in for-loop)"
assert_not_contains "$AENC" 'local AC3_FORCE_DOWNMIX' "av_encoder_audio: FARA local AC3_FORCE_DOWNMIX"

# ── 3. PS1 paritate — copy-first + loudnorm a:0 ───────────────────────
assert_contains "$ENC_PS1" '@("-c:a","copy","-c:a:0","aac","-b:a:0",$abr)'     "PS1: aac copy-first"
assert_contains "$ENC_PS1" '@("-c:a","copy","-c:a:0","libopus","-b:a:0",$abr)' "PS1: opus copy-first"
assert_contains "$ENC_PS1" '@("-c:a","copy","-c:a:0","ac3","-b:a:0",$abr)'     "PS1: ac3 copy-first"
assert_contains "$ENC_PS1" '@("-c:a","copy","-c:a:0","pcm_s'                   "PS1: pcm copy-first"
assert_contains "$ENC_PS1" '@("-filter:a:$audioLoudnormTrack","loudnorm=I=-24' "PS1: loudnorm scopat la pista re-encodata"
assert_not_contains "$ENC_PS1" '@("-c:a:0","aac","-b:a:0",$abr) + $downmixFlag + @("-c:a","copy")' "PS1: NU mai e vechea ordine"

# ── 4. Functional — re-encode chiar produce codecul ales (regresia critica) ──
if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    source "$SCRIPT_DIR/av_common.sh" 2>/dev/null
    tmpd="$(mktemp -d)"
    trap 'rm -rf "$tmpd"; _test_summary' EXIT
    s2="$tmpd/s2.mp4"; s6="$tmpd/s6.mp4"; s8="$tmpd/s8.mp4"
    ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=240x160:rate=10" -f lavfi -i "sine=frequency=440:duration=1" \
        -c:v libx265 -pix_fmt yuv420p -preset ultrafast -x265-params log-level=none -c:a aac -shortest "$s2" 2>/dev/null
    ffmpeg -v error -y -f lavfi -i "testsrc2=duration=1:size=240x160:rate=10" -f lavfi -i "sine=frequency=440:duration=1" \
        -c:v libx265 -pix_fmt yuv420p -preset ultrafast -x265-params log-level=none -af "pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0" -c:a aac -shortest "$s6" 2>/dev/null
    cn() { ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | head -1 | tr -d '\r'; }
    if [[ -s "$s2" ]]; then
        # (a) sursa aac + ales opus → output OPUS (nu aac) — dovada fix-ului
        AUDIO_CODEC_ARG="opus:128k"; CONTAINER="mkv"
        ap=$(get_audio_params "$s2")
        assert_eq "-c:a copy -c:a:0 libopus -b:a:0 128k" "$ap" "functional: get_audio_params opus = copy-first"
        # shellcheck disable=SC2086
        ffmpeg -v error -y -i "$s2" -map 0:v:0 -map 0:a:0 -c:v copy $ap "$tmpd/o.mkv" 2>/dev/null
        assert_eq "opus" "$(cn "$tmpd/o.mkv")" "functional: aac→opus chiar produce OPUS (regresia)"
        # (b) sursa aac + ales eac3 → eac3
        AUDIO_CODEC_ARG="eac3:224k"; ap=$(get_audio_params "$s2")
        # shellcheck disable=SC2086
        ffmpeg -v error -y -i "$s2" -map 0:v:0 -map 0:a:0 -c:v copy $ap "$tmpd/e.mkv" 2>/dev/null
        assert_eq "eac3" "$(cn "$tmpd/e.mkv")" "functional: aac→eac3 produce EAC3"
    fi
    if [[ -s "$s6" ]]; then
        # (c) bitrate scaling 5.1: aac → 384k in sirul de params
        AUDIO_CODEC_ARG="aac:192k"; CONTAINER="mkv"
        assert_contains "$(get_audio_params "$s6")" "-b:a:0 384k" "functional: 5.1 aac scaleaza la 384k"
        # (c2) v66 audit FIX paritate: AC3 + AV_DOWNMIX_STEREO trebuie sa pastreze
        # -ac:a:0 2 (ramura AC3 din get_audio_params il omitea — PS1/av_encoder_audio il aveau)
        AUDIO_CODEC_ARG="ac3:224k"; AV_DOWNMIX_STEREO=1
        assert_contains "$(get_audio_params "$s6")" "-ac:a:0 2" "functional: AC3 + AV_DOWNMIX_STEREO pastreaza -ac:a:0 2"
        AV_DOWNMIX_STEREO=0
    fi
    # (d) loudnorm: sirul capturat e CURAT (incepe cu -filter:a:0, fara text 'Loudnorm')
    if [[ -s "$s2" ]]; then
        AUDIO_NORMALIZE=1; ln=$(get_loudnorm_filter "$s2"); AUDIO_NORMALIZE=0
        if [[ "$ln" == "-filter:a:0 loudnorm="* ]]; then assert_eq 1 1 "functional: loudnorm string curat (-filter:a:0...)"
        else assert_eq "-filter:a:0..." "$ln" "functional: loudnorm string curat"; fi
        assert_not_contains "$ln" "Loudnorm:" "functional: loudnorm string FARA poluare log"
    fi
    # (e) end-to-end prin av_encoder_audio.sh: sursa aac + ales opus → output OPUS
    if [[ -s "$s2" ]]; then
        aud_in="$tmpd/aein"; aud_out="$tmpd/aeout"; mkdir -p "$aud_in" "$aud_out"
        cp "$s2" "$aud_in/clip.mp4"
        ( export INPUT_DIR="$aud_in" OUTPUT_DIR="$aud_out"
          printf '2\n3\n' | bash "$SCRIPT_DIR/av_encoder_audio.sh" >/dev/null 2>&1 )
        if [[ -s "$aud_out/clip_audio.mkv" ]]; then
            assert_eq "opus" "$(cn "$aud_out/clip_audio.mkv")" "functional: av_encoder_audio.sh aac→opus produce OPUS"
        fi
    fi
fi
true
