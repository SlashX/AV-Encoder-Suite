#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# av_encoder_audio.sh — Re-encode doar audio (video stream copy)
# Rapid — nu re-encodeaza video, pastreaza calitatea video 1:1.
# ══════════════════════════════════════════════════════════════════════

# v41: Source av_common.sh pentru detect_platform + paths cross-platform + wrappere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/av_common.sh"

LOG_FILE="$OUTPUT_DIR/av_encode_log_audio.txt"
mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"

# ── Container output ─────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════╗"
echo "║  AUDIO-ONLY ENCODER (video copy)     ║"
echo "╠══════════════════════════════════════╣"
echo "║  Format container output             ║"
echo "║  1) mp4 — compatibil maxim           ║"
echo "║  2) mkv — flexibil [implicit]        ║"
echo "║  3) mov — Apple / Final Cut          ║"
echo "║  4) webm — VP8/VP9/AV1 + Opus        ║"
echo "╚══════════════════════════════════════╝"
read -p "Alege 1-4 [implicit: 2]: " container_choice
case "${container_choice:-2}" in
    1) CONTAINER="mp4" ;;
    3) CONTAINER="mov" ;;
    4) CONTAINER="webm" ;;
    *) CONTAINER="mkv" ;;
esac
echo "  Container: $CONTAINER"

# ── Audio codec ──────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║  Audio output                                    ║"
echo "║  1) AAC 192k / 5.1 384k / 7.1 768k [implicit]   ║"
echo "║  2) AAC custom                                   ║"
echo "║  3) Opus 128k / 5.1 256k / 7.1 512k             ║"
echo "║  4) Opus custom                                  ║"
echo "║  5) FLAC lossless                                ║"
echo "║  6) FLAC custom (compression level)              ║"
echo "║  7) E-AC3 (Dolby Digital Plus)                   ║"
echo "║     Stereo 224k / 5.1 640k / 7.1 1024k          ║"
echo "║  8) AC3 (Dolby Digital legacy)                  ║"
echo "║     TV-uri vechi pre-2010 / max 5.1 / 640k      ║"
echo "║  9) LPCM (PCM necomprimat)                      ║"
echo "║     16bit / 24bit / 32bit                        ║"
echo "╚══════════════════════════════════════════════════╝"
read -p "Alege 1-9 [implicit: 1]: " audio_choice

AUDIO_CODEC="aac"
AUDIO_BITRATE="192k"
AUDIO_FLAC_LEVEL="8"

case "${audio_choice:-1}" in
    1) echo "  Audio: AAC 192k / 5.1 384k / 7.1 768k" ;;
    2) read -p "  Bitrate AAC (ex: 128k, 256k, 320k): " aac_br
       if [[ "$aac_br" =~ ^[0-9]+[kK]$ ]]; then
           AUDIO_BITRATE="${aac_br,,}"; echo "  Audio: AAC $AUDIO_BITRATE"
       else
           echo "  Format invalid — AAC 192k."; AUDIO_BITRATE="192k"
       fi ;;
    3) AUDIO_CODEC="opus"; AUDIO_BITRATE="128k"
       echo "  Audio: Opus 128k / 5.1 256k / 7.1 512k" ;;
    4) AUDIO_CODEC="opus"
       read -p "  Bitrate Opus (ex: 64k, 96k, 128k, 256k): " opus_br
       if [[ "$opus_br" =~ ^[0-9]+[kK]$ ]]; then
           AUDIO_BITRATE="${opus_br,,}"; echo "  Audio: Opus $AUDIO_BITRATE"
       else
           echo "  Format invalid — Opus 128k."; AUDIO_BITRATE="128k"
       fi ;;
    5) AUDIO_CODEC="flac"; echo "  Audio: FLAC lossless (compression 8)" ;;
    6) AUDIO_CODEC="flac"
       read -p "  Compression level FLAC (0-12, default=8): " flac_lvl
       if [[ "$flac_lvl" =~ ^[0-9]+$ ]] && [ "$flac_lvl" -ge 0 ] && [ "$flac_lvl" -le 12 ]; then
           AUDIO_FLAC_LEVEL="$flac_lvl"; echo "  Audio: FLAC compression $AUDIO_FLAC_LEVEL"
       else
           echo "  Nivel invalid — FLAC compression 8."
       fi ;;
    7) AUDIO_CODEC="eac3"; AUDIO_BITRATE="224k"
       echo "  Audio: E-AC3 (Dolby Digital Plus) — stereo 224k / 5.1 640k / 7.1 1024k" ;;
    8) AUDIO_CODEC="ac3"; AUDIO_BITRATE="224k"
       echo "  Audio: AC3 (Dolby Digital legacy) — stereo 224k / 5.1 448k (max 640k spec)"
       echo "  Note: AC3 nu suporta >5.1 — sursa 7.1 se downmix-eaza la 5.1 automat" ;;
    9) AUDIO_CODEC="pcm"
       echo "  LPCM bit depth:"
       echo "  1) 16bit [implicit]   2) 24bit (studio)   3) 32bit"
       read -p "  Alege 1-3 [implicit: 1]: " pcm_depth
       case "${pcm_depth:-1}" in
           2) AUDIO_BITRATE="24le"; echo "  Audio: LPCM 24bit" ;;
           3) AUDIO_BITRATE="32le"; echo "  Audio: LPCM 32bit" ;;
           *) AUDIO_BITRATE="16le"; echo "  Audio: LPCM 16bit" ;;
       esac ;;
    *) echo "  Audio: AAC 192k / 5.1 384k / 7.1 768k" ;;
esac

# FLAC + mp4/mov warning
if [[ "$AUDIO_CODEC" == "flac" ]] && [[ "$CONTAINER" != "mkv" ]]; then
    echo ""
    echo "  ATENTIE: FLAC nu este compatibil cu $CONTAINER."
    echo "  1) Schimba container la MKV [recomandat]"
    echo "  2) Schimba audio la AAC 192k"
    read -p "  Alege 1 sau 2 [implicit: 1]: " flac_fix
    if [[ "${flac_fix:-1}" == "2" ]]; then
        AUDIO_CODEC="aac"; AUDIO_BITRATE="192k"
        echo "  Audio schimbat la AAC 192k"
    else
        CONTAINER="mkv"; echo "  Container schimbat la MKV"
    fi
fi

# E-AC3 + mov warning
if [[ "$AUDIO_CODEC" == "eac3" ]] && [[ "$CONTAINER" == "mov" ]]; then
    echo ""
    echo "  ATENTIE: E-AC3 nu este compatibil cu mov."
    echo "  1) Schimba container la MKV [recomandat]"
    echo "  2) Schimba container la MP4"
    echo "  3) Schimba audio la AAC 192k"
    read -p "  Alege 1, 2 sau 3 [implicit: 1]: " eac3_fix
    case "${eac3_fix:-1}" in
        2) CONTAINER="mp4"; echo "  Container schimbat la MP4" ;;
        3) AUDIO_CODEC="aac"; AUDIO_BITRATE="192k"; echo "  Audio schimbat la AAC 192k" ;;
        *) CONTAINER="mkv"; echo "  Container schimbat la MKV" ;;
    esac
fi

# v53: AC3 + mov warning (paralel cu EAC3 — mov nu suporta AC3 muxat stabil)
if [[ "$AUDIO_CODEC" == "ac3" ]] && [[ "$CONTAINER" == "mov" ]]; then
    echo ""
    echo "  ATENTIE: AC3 nu este compatibil cu mov."
    echo "  1) Schimba container la MKV [recomandat]"
    echo "  2) Schimba container la MP4"
    echo "  3) Schimba audio la AAC 192k"
    read -p "  Alege 1, 2 sau 3 [implicit: 1]: " ac3_fix
    case "${ac3_fix:-1}" in
        2) CONTAINER="mp4"; echo "  Container schimbat la MP4" ;;
        3) AUDIO_CODEC="aac"; AUDIO_BITRATE="192k"; echo "  Audio schimbat la AAC 192k" ;;
        *) CONTAINER="mkv"; echo "  Container schimbat la MKV" ;;
    esac
fi

# LPCM + mp4 warning
if [[ "$AUDIO_CODEC" == "pcm" ]] && [[ "$CONTAINER" == "mp4" ]]; then
    echo ""
    echo "  ATENTIE: LPCM nu este compatibil cu mp4."
    echo "  1) Schimba container la MKV [recomandat]"
    echo "  2) Schimba container la MOV"
    echo "  3) Schimba audio la AAC 192k"
    read -p "  Alege 1, 2 sau 3 [implicit: 1]: " pcm_fix
    case "${pcm_fix:-1}" in
        2) CONTAINER="mov"; echo "  Container schimbat la MOV" ;;
        3) AUDIO_CODEC="aac"; AUDIO_BITRATE="192k"; echo "  Audio schimbat la AAC 192k" ;;
        *) CONTAINER="mkv"; echo "  Container schimbat la MKV" ;;
    esac
fi

# v53: WebM compat — accepta DOAR Opus audio (Vorbis nu e expus in proiect)
if [[ "$CONTAINER" == "webm" ]] && [[ "$AUDIO_CODEC" != "opus" ]]; then
    echo ""
    echo "  ATENTIE: WebM accepta DOAR Opus audio (spec: vp8/vp9/av1 + opus/vorbis)."
    echo "  1) Schimba audio la Opus 128k [recomandat]"
    echo "  2) Schimba container la MKV"
    read -p "  Alege 1 sau 2 [implicit: 1]: " webm_fix
    if [[ "${webm_fix:-1}" == "2" ]]; then
        CONTAINER="mkv"; echo "  Container schimbat la MKV"
    else
        AUDIO_CODEC="opus"; AUDIO_BITRATE="128k"
        echo "  Audio schimbat la Opus 128k"
    fi
fi

# ── Container flags ──────────────────────────────────────────────────
# +faststart aplicabil doar la mp4/mov/m4v (MOV-derived); MKV/WebM nu il accepta
CONTAINER_FLAGS=""
[[ "$CONTAINER" == "mp4" || "$CONTAINER" == "mov" ]] && CONTAINER_FLAGS="-movflags +faststart"

# ── Wake lock ────────────────────────────────────────────────────────
echo ""
echo "Activez wake lock..."
av_wake_lock
[ $? -ne 0 ] && echo "AVERTISMENT: av_wake_lock a esuat."

# ── Scanare fisiere ──────────────────────────────────────────────────
shopt -s nullglob nocaseglob
FILES=("$INPUT_DIR"/*.{mp4,mov,mkv,m2ts,mts,vob,mxf,apv,webm})
shopt -u nocaseglob nullglob
TOTAL=${#FILES[@]}

if [ "$TOTAL" -eq 0 ]; then
    echo "Nu am gasit fisiere video in $INPUT_DIR"
    av_wake_unlock; exit 1
fi

echo "=======================================" | tee "$LOG_FILE"
echo "Audio encode: $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"
echo "Codec: $AUDIO_CODEC | Bitrate: $AUDIO_BITRATE | Container: $CONTAINER" | tee -a "$LOG_FILE"
echo "Fisiere: $TOTAL" | tee -a "$LOG_FILE"
echo "=======================================" | tee -a "$LOG_FILE"

COUNT=0; TOTAL_DONE=0; TOTAL_ERRORS=0; TOTAL_SKIPPED=0
GRAND_START=$(date +%s)

for file in "${FILES[@]}"; do
    [ -f "$file" ] || continue
    COUNT=$((COUNT + 1))
    filename=$(basename "$file")
    name="${filename%.*}"
    output="$OUTPUT_DIR/${name}_audio.${CONTAINER}"

    echo ""
    echo "── [$COUNT/$TOTAL] $filename"

    # Skip daca exista si >1MB
    if [ -f "$output" ]; then
        OUT_SIZE=$(av_stat_size "$output" 2>/dev/null || echo 0)
        if [ "$OUT_SIZE" -gt 1048576 ]; then
            echo "  SKIP: output deja exista ($(( OUT_SIZE / 1048576 )) MB)"
            TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1)); continue
        fi
        rm -f "$output"
    fi

    # Detectie surround — v63: default= + head -1 + tr -d '\r' (csv=p=0 single-field fragil:
    # trailing comma pe side_data / 2 linii pe DJI → regex esua → fallback 2 → bitrate gresit)
    SRC_CHANNELS=$(ffprobe -v error -select_streams a:0 \
        -show_entries stream=channels -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1 | tr -d '\r')
    [[ ! "$SRC_CHANNELS" =~ ^[0-9]+$ ]] && SRC_CHANNELS=2

    # v53: AV_DOWNMIX_STEREO=1 → force stereo downmix pe orice codec
    DOWNMIX_FLAG=""
    if [[ "${AV_DOWNMIX_STEREO:-0}" == "1" ]] && [ "$SRC_CHANNELS" -gt 2 ]; then
        echo "  AV_DOWNMIX_STEREO=1 → downmix ${SRC_CHANNELS}ch → 2.0"
        SRC_CHANNELS=2
        DOWNMIX_FLAG="-ac:a:0 2"
    fi

    # Build audio params
    # CRITIC (v66): `-c:a copy` PRIMUL, apoi `-c:a:0 <codec>` — la fel ca
    # get_audio_params (av_common.sh). ffmpeg aplica `-c` in ordine; daca
    # `-c:a copy` e ULTIMUL, prinde si a:0 si suprascrie `-c:a:0 <codec>` →
    # track 0 COPIAT, nu re-encodat (alegi Opus, primesti AAC).
    case "$AUDIO_CODEC" in
        aac)
            A_BR="$AUDIO_BITRATE"
            if [[ "$A_BR" == "192k" ]]; then
                [ "$SRC_CHANNELS" -gt 6 ] && A_BR="768k"
                [ "$SRC_CHANNELS" -gt 2 ] && [ "$SRC_CHANNELS" -le 6 ] && A_BR="384k"
            fi
            AUDIO_PARAMS="-c:a copy -c:a:0 aac -b:a:0 $A_BR $DOWNMIX_FLAG"
            ;;
        opus)
            A_BR="$AUDIO_BITRATE"
            if [[ "$A_BR" == "128k" ]]; then
                [ "$SRC_CHANNELS" -gt 6 ] && A_BR="512k"
                [ "$SRC_CHANNELS" -gt 2 ] && [ "$SRC_CHANNELS" -le 6 ] && A_BR="256k"
            fi
            AUDIO_PARAMS="-c:a copy -c:a:0 libopus -b:a:0 $A_BR $DOWNMIX_FLAG"
            ;;
        flac)
            AUDIO_PARAMS="-c:a copy -c:a:0 flac -compression_level $AUDIO_FLAC_LEVEL $DOWNMIX_FLAG"
            ;;
        eac3)
            A_BR="$AUDIO_BITRATE"
            if [[ "$A_BR" == "224k" ]]; then
                [ "$SRC_CHANNELS" -gt 6 ] && A_BR="1024k"
                [ "$SRC_CHANNELS" -gt 2 ] && [ "$SRC_CHANNELS" -le 6 ] && A_BR="640k"
            fi
            AUDIO_PARAMS="-c:a copy -c:a:0 eac3 -b:a:0 $A_BR $DOWNMIX_FLAG"
            ;;
        ac3)
            # v53: AC3 — Dolby Digital legacy (TV-uri pre-2010, console PS3-PS4)
            # AC3 nu suporta peste 5.1 → force downmix la 5.1 cand sursa e 7.1
            # v66: FARA `local` — suntem la nivel de script (in for-loop, nu functie);
            # `local` arunca "can only be used in a function" si lasa varul nesetat
            # → detectia 7.1 si downmix-ul AC3 esuau.
            A_BR="$AUDIO_BITRATE"
            ac3_ch="$SRC_CHANNELS"
            if [[ "$A_BR" == "224k" ]]; then
                [ "$SRC_CHANNELS" -gt 2 ] && A_BR="448k"
            fi
            AC3_FORCE_DOWNMIX=""
            if [ "$ac3_ch" -gt 6 ]; then
                ac3_ch=6
                AC3_FORCE_DOWNMIX="-ac:a:0 6"
                echo "  AC3: sursa 7.1 → downmix la 5.1 (AC3 nu suporta >5.1)" | tee -a "$LOG_FILE"
            fi
            # Daca AV_DOWNMIX_STEREO activ, $DOWNMIX_FLAG are prioritate (stereo)
            if [[ -n "$DOWNMIX_FLAG" ]]; then
                AUDIO_PARAMS="-c:a copy -c:a:0 ac3 -b:a:0 $A_BR $DOWNMIX_FLAG"
            else
                AUDIO_PARAMS="-c:a copy -c:a:0 ac3 -b:a:0 $A_BR $AC3_FORCE_DOWNMIX"
            fi
            ;;
        pcm)
            AUDIO_PARAMS="-c:a copy -c:a:0 pcm_s${AUDIO_BITRATE} $DOWNMIX_FLAG"
            ;;
    esac

    # Avertizari metadata TrueHD/DTS la re-encode (per fisier, in log)
    audio_codecs_check=$(ffprobe -v error -select_streams a \
        -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
    audio_profile_check=$(ffprobe -v error -select_streams a \
        -show_entries stream=profile \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
    if echo "$audio_codecs_check" | grep -qi "truehd"; then
        echo "  ⚠ ATENTIE: Sursa contine TrueHD." | tee -a "$LOG_FILE"
        echo "    Metadata Dolby Atmos (obiecte spatiale) se va pierde la re-encode." | tee -a "$LOG_FILE"
    fi
    if echo "$audio_codecs_check" | grep -qi "dts"; then
        if echo "$audio_profile_check" | grep -qi "DTS-HD MA\|DTS:X"; then
            echo "  ⚠ ATENTIE: Sursa contine DTS-HD MA / DTS:X — metadata lossless/spatiala se va pierde." | tee -a "$LOG_FILE"
        else
            echo "  ⚠ ATENTIE: Sursa contine DTS — metadata DTS se va pierde la re-encode." | tee -a "$LOG_FILE"
        fi
    fi

    echo "  Audio: $AUDIO_CODEC ${A_BR:-lossless} | Canale sursa: $SRC_CHANNELS"

    # v53: WebM — verifica codec video sursa (DOAR vp8/vp9/av1 pot fi stream-copied in webm)
    if [[ "$CONTAINER" == "webm" ]]; then
        # v57: default= in loc de csv=p=0 — trailing comma "av1," esua regex anchored
        # v63: head -1 + tr -d '\r' — DJI Action 6 dubla v:0 ("vp9\nvp9") si Windows/git-bash
        # adauga \r → regex ancorat ^(vp8|vp9|av1)$ ar esua → fals SKIP pe sursa WebM valida.
        SRC_VCODEC=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1 | tr -d '\r')
        if [[ ! "$SRC_VCODEC" =~ ^(vp8|vp9|av1)$ ]]; then
            echo "  SKIP: WebM accepta DOAR vp8/vp9/av1 ca video (sursa: ${SRC_VCODEC:-necunoscut})" | tee -a "$LOG_FILE"
            TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
            continue
        fi
    fi

    # Subtitle codec
    SUB_CODEC="-c:s copy"
    if [[ "$CONTAINER" == "webm" ]]; then
        # WebM accepta DOAR WebVTT — strip alte subs (subrip/ass/pgs/etc)
        SUB_CODEC="-sn"
    elif [[ "$CONTAINER" != "mkv" ]]; then
        SUB_CHECK=$(ffprobe -v error -select_streams s \
            -show_entries stream=codec_name -of csv=p=0 "$file" 2>/dev/null)
        if echo "$SUB_CHECK" | grep -qi "hdmv_pgs\|dvd_subtitle\|dvb_subtitle"; then
            SUB_CODEC="-sn"
        else
            SUB_CODEC="-c:s mov_text"
        fi
    fi

    ORIG_SIZE=$(av_stat_size "$file" 2>/dev/null || echo 0)
    START_TIME=$(date +%s)

    # v57: tag codec_tag pe MP4/MOV — video e stream copy → tag-ul sursei
    # se propaga (adesea hev1). Aplicam codec_tag corect pe baza codec-ului real.
    _src_codec=$(detect_source_codec "$file")
    _audio_codec_tag=$(codec_tag_for_container "$_src_codec" "$CONTAINER")

    # v67: selectie audio per-pista (>1 pista). Refolosim handle_multi_audio_dialog din
    # av_common.sh — poate rescrie AUDIO_PARAMS si adauga negative maps in MAP_FLAGS (skip).
    # Construim AUDIO_CODEC_ARG in formatul "codec:br" asteptat (flac→nivel, pcm→fmt).
    case "$AUDIO_CODEC" in
        flac) AUDIO_CODEC_ARG="flac:$AUDIO_FLAC_LEVEL" ;;
        *)    AUDIO_CODEC_ARG="$AUDIO_CODEC:$AUDIO_BITRATE" ;;
    esac
    MAP_FLAGS="-map 0:v -map 0:a? -map 0:s? -map 0:t?"
    handle_multi_audio_dialog "$file"
    # v68: avertisment compat container pe pistele COPIATE (codec incompatibil → ar esua)
    warn_incompat_audio_copies "$file"

    # shellcheck disable=SC2086
    ffmpeg -i "$file" \
        $MAP_FLAGS \
        -map_metadata 0 -map_chapters 0 \
        -c:v copy \
        $AUDIO_PARAMS \
        $SUB_CODEC -c:t copy \
        $_audio_codec_tag $CONTAINER_FLAGS \
        -nostats "$output" 2>>"$LOG_FILE"

    FFMPEG_EXIT=$?
    END_TIME=$(date +%s)
    ELAPSED=$(( END_TIME - START_TIME ))

    if [ $FFMPEG_EXIT -ne 0 ] || [ ! -s "$output" ]; then
        echo "  EROARE (cod $FFMPEG_EXIT)" | tee -a "$LOG_FILE"
        rm -f "$output"
        TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
    else
        NEW_SIZE=$(av_stat_size "$output" 2>/dev/null || echo 0)
        SAVED=$(( (ORIG_SIZE - NEW_SIZE) / 1048576 ))
        echo "  OK — ${ELAPSED}s | $(( NEW_SIZE / 1048576 )) MB | Salvat: ${SAVED} MB" | tee -a "$LOG_FILE"
        TOTAL_DONE=$((TOTAL_DONE + 1))
    fi
done

# ── Statistici finale ────────────────────────────────────────────────
GRAND_END=$(date +%s)
GRAND_ELAPSED=$(( GRAND_END - GRAND_START ))

echo ""
echo "═══════════════════════════════════════"
echo "STATISTICI FINALE — Audio encode [$CONTAINER]"
echo "  Procesate : $TOTAL_DONE"
echo "  Erori     : $TOTAL_ERRORS"
echo "  Sarite    : $TOTAL_SKIPPED"
echo "  Timp total: ${GRAND_ELAPSED}s"
echo "═══════════════════════════════════════"

echo "FINAL: $TOTAL_DONE procesate, $TOTAL_ERRORS erori" >> "$LOG_FILE"

av_wake_unlock
av_notify_done "Audio encode complet" \
    "$TOTAL_DONE fisiere, $TOTAL_ERRORS erori, ${GRAND_ELAPSED}s"
