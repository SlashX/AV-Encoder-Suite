#!/data/data/com.termux/files/usr/bin/bash
# ══════════════════════════════════════════════════════════════════════
# av_launcher.sh — Meniu interactiv pentru selectia encoderului si parametrilor
# ══════════════════════════════════════════════════════════════════════

TERMUX_DIR="$HOME"
ANDROID_DIR="/storage/emulated/0/Media/Scripts"
INPUT_DIR="/storage/emulated/0/Media/InputVideos"
OUTPUT_DIR="/storage/emulated/0/Media/OutputVideos"
LUTS_DIR="/storage/emulated/0/Media/Luts"
TOOLS_DIR="/storage/emulated/0/Media/Scripts/tools"
PROFILES_DIR="/storage/emulated/0/Media/Scripts/profiles"
USER_PROFILES_DIR="/storage/emulated/0/Media/UserProfiles"
# v36: Folder temporar (Trim & Concat) — creat lazy la prima folosire
AV_TEMP_DIR="/storage/emulated/0/Media/Temp"

echo "╔══════════════════════════════════════╗"
echo "║         AV ENCODER LAUNCHER       ║"
echo "╚══════════════════════════════════════╝"

# ── Statistici rapide ─────────────────────────────────────────────────
echo ""
echo "STATISTICI INPUT"
echo "─────────────────────────────────────"
if [ -d "$INPUT_DIR" ]; then
    # FIX: shopt -u reseteaza si nullglob, nu doar nocaseglob
    shopt -s nullglob nocaseglob
    IN_FILES=("$INPUT_DIR"/*.{mp4,mov,mkv,m2ts,mts,vob,mxf,apv})
    shopt -u nocaseglob nullglob
    IN_COUNT=${#IN_FILES[@]}
    if [ "$IN_COUNT" -gt 0 ]; then
        IN_SIZE=$(du -sh "$INPUT_DIR" 2>/dev/null | cut -f1)
        echo "  Fisiere gasite : $IN_COUNT"
        echo "  Spatiu ocupat  : $IN_SIZE"
    else
        echo "  Niciun fisier video in Input."
    fi
else
    echo "  Folderul Input nu exista inca."
fi
FREE_SPACE=$(df "$OUTPUT_DIR" 2>/dev/null | awk 'NR==2{printf "%.1f GB",$4/1024/1024}')
if [ -z "$FREE_SPACE" ]; then
    FREE_SPACE=$(df "/storage/emulated/0" 2>/dev/null | awk 'NR==2{printf "%.1f GB",$4/1024/1024}')
fi
[ -z "$FREE_SPACE" ] && FREE_SPACE="N/A"
echo "  Spatiu liber   : $FREE_SPACE"
echo "─────────────────────────────────────"

# ── Director scripturi ────────────────────────────────────────────────
echo ""
echo "De unde vrei sa rulezi scripturile?"
echo "  1) Termux ($TERMUX_DIR)"
echo "  2) Folder Android ($ANDROID_DIR)"
read -p "Introdu 1 sau 2: " location_choice
if   [[ "$location_choice" == "1" ]]; then SCRIPT_DIR="$TERMUX_DIR"
elif [[ "$location_choice" == "2" ]]; then SCRIPT_DIR="$ANDROID_DIR"
else echo "Optiune invalida. Iesi..."; exit 1; fi

for script in av_encoder_x265.sh av_encoder_x264.sh \
              av_encoder_av1.sh av_encoder_dnxhr.sh av_encoder_apv.sh av_encoder_prores.sh \
              av_check.sh av_common.sh \
              av_extractor_dji.sh av_encoder_audio.sh av_extractor_gps.sh; do
    if [ ! -f "$SCRIPT_DIR/$script" ]; then
        echo "Eroare: $script nu a fost gasit in $SCRIPT_DIR"; exit 1
    fi
done
cd "$SCRIPT_DIR" || exit 1

# ── Verificare ffmpeg + mesaj recomandare ────────────────────────────
if command -v ffmpeg &>/dev/null; then
    _ffver=$(ffmpeg -version 2>/dev/null | head -1 | grep -oP 'version \K[0-9]+\.[0-9]+')
    echo ""
    echo "  ffmpeg detectat: versiunea $_ffver"
    if [[ "$_ffver" < "8.1" ]] 2>/dev/null; then
        echo "  ⚠ RECOMANDAT: ffmpeg 8.1+ pentru suport complet"
        echo "    (ProRes Vulkan, HDR10+ metadata, APV decode)"
    fi
else
    echo ""
    echo "  ⚠ ffmpeg NU a fost gasit! Instaleaza cu: pkg install ffmpeg"
    exit 1
fi

# ── Meniu principal — INAINTE de configurarea parametrilor ────────────
# Daca utilizatorul alege Verifica, Extractor DJI sau Iesire, evita intrebarile inutile
echo ""
echo "╔══════════════════════════════════════╗"
echo "║  Ce vrei sa faci?                    ║"
echo "║  1) Encodeaza video + audio          ║"
echo "║  2) Encodeaza doar audio (video copy)║"
echo "║  3) Verifica fisiere media           ║"
echo "║  4) Export date GPS/DJI (din video)  ║"
echo "║  5) Import GPS extern (GPX/FIT)     ║"
echo "║  6) Trim & Concat (taiere/unire)     ║"
echo "║  7) Anulare / iesire                 ║"
echo "╚══════════════════════════════════════╝"
read -p "Introdu 1-7: " main_choice

case "$main_choice" in
    2) echo "Rulez av_encoder_audio.sh..."; ./av_encoder_audio.sh; exit $? ;;
    3) echo "Rulez av_check.sh..."; ./av_check.sh; exit $? ;;
    4) echo "Rulez av_extractor_dji.sh..."; ./av_extractor_dji.sh; exit $? ;;
    5) echo "Rulez av_extractor_gps.sh..."; ./av_extractor_gps.sh; exit $? ;;
    6) echo "Rulez av_trimconcat.sh..."; ./av_trimconcat.sh; exit $? ;;
    7) echo "Anulat."; exit 0 ;;
    1) : ;;
    *) echo "Optiune invalida."; exit 1 ;;
esac

# ── Profil salvat (save/load) ─────────────────────────────────────────
mkdir -p "$USER_PROFILES_DIR" 2>/dev/null

# Colecteaza profile: user (UserProfiles/) + pre-definite (profiles/*/)
shopt -s nullglob
USER_PROFILES=("$USER_PROFILES_DIR"/*.conf)
BUILTIN_PROFILES=("$PROFILES_DIR"/*/*.conf)
PROFILES=("${USER_PROFILES[@]}" "${BUILTIN_PROFILES[@]}")
shopt -u nullglob

# Folder Luts pentru verificare LUT (definit sus)

if [ ${#PROFILES[@]} -gt 0 ]; then
    echo ""
    echo "╔══════════════════════════════════════╗"
    echo "║  Profile disponibile                  ║"
    echo "╠══════════════════════════════════════╣"
    local_idx=1
    for p in "${PROFILES[@]}"; do
        pname=$(basename "$p" .conf)
        # Marcheaza profilele pre-definite cu [DJI] etc.
        if [[ "$p" == *"$PROFILES_DIR/dji_action6/"* ]]; then
            echo "║  $local_idx) [DJI] $pname"
        else
            echo "║  $local_idx) $pname"
        fi
        local_idx=$((local_idx + 1))
    done
    echo "║  N) Configurare noua (meniu normal)  ║"
    echo "╚══════════════════════════════════════╝"
    read -p "Alege profil sau N [implicit: N]: " prof_load
    if [[ "$prof_load" =~ ^[0-9]+$ ]] && [ "$prof_load" -ge 1 ] && [ "$prof_load" -le ${#PROFILES[@]} ]; then
        LOAD_FILE="${PROFILES[$((prof_load-1))]}"
        echo "  Incarc profil: $(basename "$LOAD_FILE" .conf)"
        source "$LOAD_FILE"

        # Verifica LUT daca profilul necesita unul
        if [[ -n "${LUT_PATH:-}" ]]; then
            LUT_FULL_PATH="$LUTS_DIR/$LUT_PATH"
            if [[ ! -f "$LUT_FULL_PATH" ]]; then
                echo ""
                echo "  ╔══════════════════════════════════════════════════════════╗"
                echo "  ║  ⚠ ATENTIE: LUT-ul nu a fost gasit!                       ║"
                echo "  ╠══════════════════════════════════════════════════════════╣"
                echo "  ║  Fisier: $LUT_PATH"
                echo "  ║  Locatie asteptata: $LUTS_DIR/"
                echo "  ║                                                          ║"
                echo "  ║  Descarca LUT-ul de pe dji.com si pune-l in:             ║"
                echo "  ║  $LUTS_DIR/"
                echo "  ╚══════════════════════════════════════════════════════════╝"
                echo ""
                read -p "  Continui fara LUT? (d/N): " continue_no_lut
                if [[ "${continue_no_lut,,}" != "d" ]]; then
                    echo "  Profil anulat — instaleaza LUT-ul si incearca din nou."
                    exit 0
                fi
                # Dezactiveaza LUT daca utilizatorul continua fara el
                LUT_PATH=""
                FORCE_LOG_DETECTION="0"
            else
                echo "  LUT gasit: $LUT_PATH"
            fi
        fi

        # Salt direct la lansare — toate variabilele sunt setate din .conf
        echo ""
        echo "  Encoder      : $ENCODER_NAME"
        echo "  Container    : $CONTAINER"
        echo "  Audio        : $AUDIO_CODEC_ARG"
        echo "  Filtru video : ${VIDEO_FILTER_PRESET:-fara}"
        echo "  Normalizare  : ${AUDIO_NORMALIZE:-0}"
        if [[ -n "${LUT_PATH:-}" ]]; then
            echo "  LOG/LUT      : ${LOG_PROFILE:-auto} + $LUT_PATH"
        fi
        echo ""
        read -p "Lanseaza cu aceste setari? (D/n): " confirm_prof
        if [[ "${confirm_prof,,}" == "n" ]]; then
            echo "  Profil anulat — continuam cu meniu normal."
        else
            # Determina script-ul
            case "$ENCODER_NAME" in
                libx265)  ENCODER_SCRIPT="av_encoder_x265.sh" ;;
                libx264)  ENCODER_SCRIPT="av_encoder_x264.sh" ;;
                av1)      ENCODER_SCRIPT="av_encoder_av1.sh" ;;
                dnxhr)    ENCODER_SCRIPT="av_encoder_dnxhr.sh" ;;
                apv)      ENCODER_SCRIPT="av_encoder_apv.sh" ;;
                prores)   ENCODER_SCRIPT="av_encoder_prores.sh" ;;
            esac
            # Lansare directa (skip meniuri)
            goto_launch=1
        fi
    fi
fi
# Variabila goto_launch semnaleaza ca trebuie sa sarim direct la lansare
# Daca profil incarcat cu succes, skip tot meniul — salt direct la lansare
if [[ "${goto_launch:-0}" == "1" ]]; then
    # Variabilele sunt deja setate din .conf
    # Determina ENCODER_SCRIPT daca nu e setat
    if [[ -z "${ENCODER_SCRIPT:-}" ]]; then
        case "$ENCODER_NAME" in
            libx265)  ENCODER_SCRIPT="av_encoder_x265.sh" ;;
            libx264)  ENCODER_SCRIPT="av_encoder_x264.sh" ;;
            av1)      ENCODER_SCRIPT="av_encoder_av1.sh" ;;
            dnxhr)    ENCODER_SCRIPT="av_encoder_dnxhr.sh" ;;
            apv)      ENCODER_SCRIPT="av_encoder_apv.sh" ;;
            prores)   ENCODER_SCRIPT="av_encoder_prores.sh" ;;
        esac
    fi
    # Salt la sectiunea LAUNCH (evita tot meniul de configurare)
    # Folosim pattern: tot meniul e in bloc SKIP_IF_PROFILE
    SKIP_CONFIG=1
fi

if [[ "${SKIP_CONFIG:-0}" != "1" ]]; then
# ════════════════════════════════════════════════════════════════════
# INCEPUT BLOC CONFIGURARE (skip daca profil incarcat)
# ════════════════════════════════════════════════════════════════════

# ── Dialog VIDEO_TS (DVD complet) ────────────────────────────────────
# Detecteaza daca exista fisiere .vob in InputVideos si ofera optiunea
# de a importa un titlu DVD complet din folderul VIDEO_TS/ prin concatenare.
shopt -s nullglob nocaseglob
VOB_FILES=("$INPUT_DIR"/*.vob)
shopt -u nocaseglob nullglob
if [ ${#VOB_FILES[@]} -gt 0 ]; then
    echo ""
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║  Fisiere .VOB detectate (DVD)        ║"
    echo "  ║  1) Encodeaza fiecare .vob individual║"
    echo "  ║  2) Import titlu DVD complet         ║"
    echo "  ║     (concateneaza din VIDEO_TS/)     ║"
    echo "  ╚══════════════════════════════════════╝"
    read -p "  Alege 1 sau 2 [implicit: 1]: " vob_choice
    if [[ "${vob_choice:-1}" == "2" ]]; then
        read -p "  Cale folder VIDEO_TS/ (ex: /storage/emulated/0/DVD/VIDEO_TS): " vts_path
        if [[ -d "$vts_path" ]]; then
            # Construieste lista fisierelor VOB sortate pentru titlul principal (VTS_01_*.VOB)
            # VTS_01_0.VOB = menu (sarit), VTS_01_1.VOB..VTS_01_N.VOB = continut
            shopt -s nullglob nocaseglob
            VTS_PARTS=("$vts_path"/VTS_01_[1-9].vob "$vts_path"/VTS_01_[1-9][0-9].vob)
            shopt -u nocaseglob nullglob
            if [ ${#VTS_PARTS[@]} -gt 0 ]; then
                # Construieste string concat ffmpeg
                CONCAT_STR=$(printf "%s|" "${VTS_PARTS[@]}")
                CONCAT_STR="concat:${CONCAT_STR%|}"
                CONCAT_OUTPUT="$INPUT_DIR/DVD_titlu_complet.vob"
                echo "  Concatenez ${#VTS_PARTS[@]} segmente VOB..."
                ffmpeg -v error -i "$CONCAT_STR" -c copy "$CONCAT_OUTPUT" -y 2>/dev/null
                if [ $? -eq 0 ] && [ -s "$CONCAT_OUTPUT" ]; then
                    echo "  OK: DVD_titlu_complet.vob creat in InputVideos."
                    echo "  Ruleaza encoderele — noul fisier va fi procesat automat."
                    exit 0
                else
                    echo "  EROARE la concatenare. Verifica calea VIDEO_TS/."
                    echo "  Continuam cu fisierele .vob individuale."
                    rm -f "$CONCAT_OUTPUT"
                fi
            else
                echo "  Nu am gasit VTS_01_*.VOB in $vts_path"
            fi
        else
            echo "  Cale invalida: $vts_path"
        fi
    fi
    echo "  Continuam cu fisierele .vob individuale."
fi

# ── Alegere encoder ───────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════╗"
echo "║  Alege encoder                       ║"
echo "║  1) libx265  — H.265/HEVC            ║"
echo "║               compresie superioara   ║"
echo "║  2) libx264  — H.264/AVC             ║"
echo "║               compatibilitate maxima ║"
echo "║  3) AV1      — codec viitor          ║"
echo "║               compresie maxima       ║"
echo "║  4) DNxHR    — Avid mezzanine        ║"
echo "║               lossless optic, editare║"
echo "║  5) APV      — Samsung profesional   ║"
echo "║               intra-frame, ffmpeg 8.1║"
echo "║  6) ProRes   — Apple profesional    ║"
echo "║               editare, mov obligat. ║"
echo "╚══════════════════════════════════════╝"
read -p "Alege 1-6 [implicit: 1]: " encoder_choice

ENCODER="${encoder_choice:-1}"
AV1_ENCODER_NAME=""

case "$ENCODER" in
    2)
        ENCODER_NAME="libx264"; ENCODER_SCRIPT="av_encoder_x264.sh"
        echo "  Encoder ales: libx264 (H.264/AVC)"
        ;;
    3)
        ENCODER_NAME="av1"; ENCODER_SCRIPT="av_encoder_av1.sh"
        echo "  Encoder ales: AV1"
        echo "  Alege implementarea AV1:"
        echo "  1) libsvtav1  — rapid, recomandat telefon [implicit]"
        echo "  2) libaom-av1 — calitate maxima, foarte lent"
        read -p "  Alege 1 sau 2 [implicit: 1]: " av1_impl
        case "${av1_impl:-1}" in
            2) AV1_ENCODER_NAME="libaom-av1"; echo "  AV1: libaom-av1" ;;
            *) AV1_ENCODER_NAME="libsvtav1";  echo "  AV1: libsvtav1" ;;
        esac
        ;;
    4)
        ENCODER_NAME="dnxhr"; ENCODER_SCRIPT="av_encoder_dnxhr.sh"
        echo "  Encoder ales: DNxHR (Avid mezzanine, lossless optic)"
        ;;
    5)
        ENCODER_NAME="apv"; ENCODER_SCRIPT="av_encoder_apv.sh"
        echo "  Encoder ales: APV (Samsung Advanced Professional Video)"
        ;;
    6)
        ENCODER_NAME="prores"; ENCODER_SCRIPT="av_encoder_prores.sh"
        echo "  Encoder ales: ProRes (Apple, mov obligatoriu)"
        ;;
    *)
        ENCODER_NAME="libx265"; ENCODER_SCRIPT="av_encoder_x265.sh"
        echo "  Encoder ales: libx265 (H.265/HEVC)"
        ;;
esac

# ── Profil x264 ───────────────────────────────────────────────────────
X264_PROFILE=""
if [[ "$ENCODER_NAME" == "libx264" ]]; then
    echo ""
    echo "Profil encodare x264:"
    echo "  1) high    — H.264 8bit  SDR"
    echo "  2) high10  — H.264 10bit SDR/HDR basic"
    echo "  3) high422 — H.264 10bit profesional"
    echo "  A) Auto    — intreaba per fisier [recomandat]"
    read -p "Alege 1-3 sau A [implicit: A]: " prof_choice
    case "${prof_choice^^}" in
        1) X264_PROFILE="high"    ;;
        2) X264_PROFILE="high10"  ;;
        3) X264_PROFILE="high422" ;;
        *) X264_PROFILE="auto"    ;;
    esac
    echo "  Profil: $X264_PROFILE"
fi

# ── Profil DNxHR ──────────────────────────────────────────────────────
DNXHR_PROFILE=""
if [[ "$ENCODER_NAME" == "dnxhr" ]]; then
    echo ""
    echo "╔══════════════════════════════════════╗"
    echo "║  Profil DNxHR                        ║"
    echo "║  1) LB  — ~45 Mbps  offline edit     ║"
    echo "║  2) SQ  — ~145 Mbps standard [impl]  ║"
    echo "║  3) HQ  — ~220 Mbps high quality     ║"
    echo "║  4) HQX — ~220 Mbps 12-bit HDR       ║"
    echo "║  5) 444 — ~440 Mbps 4:4:4 grading    ║"
    echo "╚══════════════════════════════════════╝"
    read -p "Alege 1-5 [implicit: 2]: " dnxhr_choice
    case "${dnxhr_choice:-2}" in
        1) DNXHR_PROFILE="lb";  echo "  Profil: DNxHR LB (~45 Mbps)" ;;
        3) DNXHR_PROFILE="hq";  echo "  Profil: DNxHR HQ (~220 Mbps)" ;;
        4) DNXHR_PROFILE="hqx"; echo "  Profil: DNxHR HQX (~220 Mbps, 12-bit HDR)" ;;
        5) DNXHR_PROFILE="444"; echo "  Profil: DNxHR 444 (~440 Mbps, 4:4:4)" ;;
        *) DNXHR_PROFILE="sq";  echo "  Profil: DNxHR SQ (~145 Mbps)" ;;
    esac
fi

# ── Profil APV ────────────────────────────────────────────────────────
APV_PROFILE=""
if [[ "$ENCODER_NAME" == "apv" ]]; then
    echo ""
    echo "╔══════════════════════════════════════╗"
    echo "║  Preset APV                          ║"
    echo "║  1) Light    — editare rapida        ║"
    echo "║  2) Standard — balans [implicit]     ║"
    echo "║  3) High     — calitate ridicata     ║"
    echo "║  4) 422_10   — 4:2:2 10-bit          ║"
    echo "║  5) 444_10   — 4:4:4 10-bit grading  ║"
    echo "╚══════════════════════════════════════╝"
    read -p "Alege 1-5 [implicit: 2]: " apv_choice
    case "${apv_choice:-2}" in
        1) APV_PROFILE="light";    echo "  Preset: APV Light" ;;
        3) APV_PROFILE="high";     echo "  Preset: APV High" ;;
        4) APV_PROFILE="422_10";   echo "  Preset: APV 4:2:2 10-bit" ;;
        5) APV_PROFILE="444_10";   echo "  Preset: APV 4:4:4 10-bit" ;;
        *) APV_PROFILE="standard"; echo "  Preset: APV Standard" ;;
    esac
fi

# ── Profil ProRes ─────────────────────────────────────────────────────
PRORES_PROFILE=""
if [[ "$ENCODER_NAME" == "prores" ]]; then
    echo ""
    echo "╔══════════════════════════════════════╗"
    echo "║  Profil ProRes                       ║"
    echo "║  1) Proxy   — ~45 Mbps  offline      ║"
    echo "║  2) LT      — ~102 Mbps light        ║"
    echo "║  3) Standard— ~147 Mbps [implicit]   ║"
    echo "║  4) HQ      — ~220 Mbps high quality ║"
    echo "║  5) 4444    — ~330 Mbps alpha/grading ║"
    echo "║  6) 4444 XQ — ~500 Mbps max quality  ║"
    echo "╚══════════════════════════════════════╝"
    read -p "Alege 1-6 [implicit: 4]: " prores_choice
    case "${prores_choice:-4}" in
        1) PRORES_PROFILE="proxy";    echo "  Profil: ProRes 422 Proxy" ;;
        2) PRORES_PROFILE="lt";       echo "  Profil: ProRes 422 LT" ;;
        3) PRORES_PROFILE="standard"; echo "  Profil: ProRes 422 Standard" ;;
        5) PRORES_PROFILE="4444";     echo "  Profil: ProRes 4444" ;;
        6) PRORES_PROFILE="4444xq";   echo "  Profil: ProRes 4444 XQ" ;;
        *) PRORES_PROFILE="hq";       echo "  Profil: ProRes 422 HQ" ;;
    esac
fi

# ── Container output ──────────────────────────────────────────────────
echo ""
# DNxHR: container .mov sau .mxf — nu suporta mkv/mp4 nativ
if [[ "$ENCODER_NAME" == "dnxhr" ]]; then
    echo "╔══════════════════════════════════════╗"
    echo "║  Format container output (DNxHR)     ║"
    echo "║  1) mov — QuickTime [implicit]       ║"
    echo "║  2) mxf — Avid native                ║"
    echo "╚══════════════════════════════════════╝"
    read -p "Alege 1 sau 2 [implicit: 1]: " container_choice
    case "${container_choice:-1}" in
        2) CONTAINER="mxf" ;;
        *) CONTAINER="mov" ;;
    esac
    echo "  Container ales: $CONTAINER"
elif [[ "$ENCODER_NAME" == "apv" ]]; then
    echo "╔══════════════════════════════════════╗"
    echo "║  Format container output (APV)       ║"
    echo "║  1) mp4 — ISOBMFF [implicit]         ║"
    echo "║  2) mov — QuickTime / editare        ║"
    echo "║  3) mxf — broadcast profesional      ║"
    echo "╚══════════════════════════════════════╝"
    read -p "Alege 1-3 [implicit: 1]: " container_choice
    case "${container_choice:-1}" in
        2) CONTAINER="mov" ;;
        3) CONTAINER="mxf" ;;
        *) CONTAINER="mp4" ;;
    esac
    echo "  Container ales: $CONTAINER"
elif [[ "$ENCODER_NAME" == "prores" ]]; then
    CONTAINER="mov"
    echo "  Container: mov (obligatoriu pentru ProRes)"
else
    if [[ "$ENCODER_NAME" == "av1" ]]; then
        echo "╔══════════════════════════════════════╗"
        echo "║  Format container output (AV1)       ║"
        echo "║  1) mp4 — compatibil maxim           ║"
        echo "║  2) mkv — flexibil, suporta DV [impl]║"
        echo "║  3) webm — VP9/AV1 nativ web         ║"
        echo "╚══════════════════════════════════════╝"
        read -p "Alege 1-3 [implicit: 2]: " container_choice
        case "${container_choice:-2}" in
            1) CONTAINER="mp4" ;;
            3) CONTAINER="webm" ;;
            *) CONTAINER="mkv" ;;
        esac
    else
        echo "╔══════════════════════════════════════╗"
        echo "║  Format container output             ║"
        echo "║  1) mp4 — compatibil maxim           ║"
        echo "║  2) mkv — flexibil, suporta DV [impl]║"
        echo "║  3) mov — Apple / Final Cut          ║"
        echo "╚══════════════════════════════════════╝"
        read -p "Alege 1, 2 sau 3 [implicit: 2]: " container_choice
        case "${container_choice:-2}" in
            1) CONTAINER="mp4" ;;
            3) CONTAINER="mov" ;;
            *) CONTAINER="mkv" ;;
        esac
    fi
    echo "  Container ales: $CONTAINER"
fi

# ── Rezolutie output ─────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════╗"
echo "║  Rezolutie output                    ║"
echo "║  1) Pastreaza originala [implicit]   ║"
echo "║  2) 3840 — 4K UHD                   ║"
echo "║  3) 2560 — 2K / 1440p               ║"
echo "║  4) 1920 — Full HD 1080p            ║"
echo "║  5) 1280 — HD 720p                  ║"
echo "║  6) Custom (introdu width)           ║"
echo "╚══════════════════════════════════════╝"
read -p "Alege 1-6 [implicit: 1]: " res_choice
SCALE_WIDTH=""
case "${res_choice:-1}" in
    2) SCALE_WIDTH="3840" ;;
    3) SCALE_WIDTH="2560" ;;
    4) SCALE_WIDTH="1920" ;;
    5) SCALE_WIDTH="1280" ;;
    6)
        read -p "  Introdu width (minim 320, numar par): " custom_w
        if [[ "$custom_w" =~ ^[0-9]+$ ]] && [ "$custom_w" -ge 320 ]; then
            if [ $((custom_w % 2)) -ne 0 ]; then
                custom_w=$((custom_w + 1))
                echo "  Ajustat la $custom_w (trebuie sa fie par)"
            fi
            SCALE_WIDTH="$custom_w"
        else
            echo "  Valoare invalida — se pastreaza rezolutia originala."
            SCALE_WIDTH=""
        fi
        ;;
    *) SCALE_WIDTH="" ;;
esac
if [ -n "$SCALE_WIDTH" ]; then
    echo "  Rezolutie: scale la ${SCALE_WIDTH}px width (aspect ratio pastrat)"
else
    echo "  Rezolutie: originala (fara resize)"
fi

# ── FPS output ───────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════╗"
echo "║  Frame rate output                   ║"
echo "║  1) Pastreaza original [implicit]    ║"
echo "║  2) 60 fps                           ║"
echo "║  3) 50 fps                           ║"
echo "║  4) 30 fps                           ║"
echo "║  5) 25 fps (PAL)                     ║"
echo "║  6) 24 fps (cinematic)               ║"
echo "║  7) 23.976 fps (Blu-ray/Netflix)     ║"
echo "║  8) Custom                            ║"
echo "╚══════════════════════════════════════╝"
read -p "Alege 1-8 [implicit: 1]: " fps_choice
TARGET_FPS=""
case "${fps_choice:-1}" in
    2) TARGET_FPS="60" ;;
    3) TARGET_FPS="50" ;;
    4) TARGET_FPS="30" ;;
    5) TARGET_FPS="25" ;;
    6) TARGET_FPS="24" ;;
    7) TARGET_FPS="24000/1001" ;;
    8)
        read -p "  Introdu FPS (ex: 29.97, 48, 120): " custom_fps
        if [[ "$custom_fps" =~ ^[0-9]+([./][0-9]+)?$ ]]; then
            TARGET_FPS="$custom_fps"
        else
            echo "  Valoare invalida — se pastreaza FPS original."
            TARGET_FPS=""
        fi
        ;;
    *) TARGET_FPS="" ;;
esac

FPS_METHOD=""
if [ -n "$TARGET_FPS" ]; then
    echo ""
    echo "  Metoda conversie FPS:"
    echo "  1) Drop/duplicate frames [implicit] — rapid"
    echo "  2) Motion interpolation — calitate mai buna, foarte lent"
    read -p "  Alege 1 sau 2 [implicit: 1]: " fps_method_choice
    case "${fps_method_choice:-1}" in
        2) FPS_METHOD="minterpolate" ;;
        *) FPS_METHOD="drop" ;;
    esac
    echo "  FPS: $TARGET_FPS ($FPS_METHOD)"
else
    echo "  FPS: original (fara conversie)"
fi

# ── Filtre video (optional) ──────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════╗"
echo "║  Filtre video (optional)             ║"
echo "║  1) Fara filtre [implicit]           ║"
echo "║  2) Denoise light  (nlmeans h=1.0)   ║"
echo "║  3) Denoise medium (hqdn3d rapid)    ║"
echo "║  4) Denoise strong (nlmeans h=3.0)   ║"
echo "║  5) Sharpen light  (unsharp)         ║"
echo "║  6) Sharpen medium (CAS)             ║"
echo "║  7) Deinterlace    (bwdif)           ║"
echo "║  8) Custom (scrii filtrul manual)    ║"
echo "║  9) Upscale 4K    (lanczos)          ║"
echo "║ 10) Stabilizare   (vidstab 2-pass)   ║"
echo "╚══════════════════════════════════════╝"
read -p "Alege 1-10 [implicit: 1]: " vf_choice
VIDEO_FILTER_PRESET=""
case "${vf_choice:-1}" in
    2) VIDEO_FILTER_PRESET="denoise_light";   echo "  Filtru: Denoise light (nlmeans h=1.0)" ;;
    3) VIDEO_FILTER_PRESET="denoise_medium";  echo "  Filtru: Denoise medium (hqdn3d)" ;;
    4) VIDEO_FILTER_PRESET="denoise_strong";  echo "  Filtru: Denoise strong (nlmeans h=3.0)" ;;
    5) VIDEO_FILTER_PRESET="sharpen_light";   echo "  Filtru: Sharpen light (unsharp)" ;;
    6) VIDEO_FILTER_PRESET="sharpen_medium";  echo "  Filtru: Sharpen medium (CAS 0.6)" ;;
    7) VIDEO_FILTER_PRESET="deinterlace";     echo "  Filtru: Deinterlace (bwdif)" ;;
    8)
        read -p "  Filtru ffmpeg custom (ex: eq=brightness=0.1): " custom_vf
        if [[ -n "$custom_vf" ]]; then
            VIDEO_FILTER_PRESET="custom:${custom_vf}"
            echo "  Filtru custom: $custom_vf"
        else
            VIDEO_FILTER_PRESET=""
            echo "  Niciun filtru (input gol)."
        fi
        ;;
    9) VIDEO_FILTER_PRESET="upscale_4k";    echo "  Filtru: Upscale 4K (lanczos)" ;;
    10) VIDEO_FILTER_PRESET="vidstab";       echo "  Filtru: Stabilizare video (vidstab 2-pass)" ;;
    *) VIDEO_FILTER_PRESET=""; echo "  Fara filtre video." ;;
esac

# ── DNxHR/APV: skip sectiunile CRF/Preset/Tune/Extra (nu se aplica) ──
# DNxHR/APV au bitrate fix per profil — fara CRF, preset, tune sau VBR
if [[ "$ENCODER_NAME" == "dnxhr" ]] || [[ "$ENCODER_NAME" == "apv" ]] || [[ "$ENCODER_NAME" == "prores" ]]; then
    ENCODE_MODE=""; CRF_PARAM=""; VBR_PARAM=""; VBR_MAXRATE=""; VBR_BUFSIZE=""
    PRESET_PARAM=""; TUNE_PARAM=""; EXTRA_PARAM=""
else

# ── Mod encodare ──────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════╗"
echo "║  Mod encodare video                  ║"
echo "║  1) CRF — calitate constanta [impl]  ║"
echo "║  2) VBR — bitrate mediu tinta        ║"
echo "╚══════════════════════════════════════╝"
read -p "Alege 1 sau 2 [implicit: 1]: " encode_mode

ENCODE_MODE="${encode_mode:-1}"
CRF_PARAM=""; VBR_PARAM=""; VBR_MAXRATE=""; VBR_BUFSIZE=""

if [[ "$ENCODE_MODE" == "1" ]]; then
    echo ""
    echo "CRF (calitate video):"
    if   [[ "$ENCODER_NAME" == "av1" ]];     then echo "  A) Auto (4K=30, 1080p=28, 720p=26) | range 0-63"
    elif [[ "$ENCODER_NAME" == "libx264" ]]; then echo "  A) Auto (4K=20, 1080p=19, 720p=18)"
    else                                          echo "  A) Auto (4K=22, 1080p=21, 720p=20)"; fi
    echo "  B) Custom"
    read -p "Alege A sau B [implicit: A]: " crf_choice
    if [[ "${crf_choice^^}" == "B" ]]; then
        CRF_MAX=63; [[ "$ENCODER_NAME" != "av1" ]] && CRF_MAX=51
        read -p "Introdu CRF (0-$CRF_MAX): " crf_val
        if [[ "$crf_val" =~ ^[0-9]+$ ]] && [ "$crf_val" -ge 0 ] && [ "$crf_val" -le "$CRF_MAX" ]; then
            CRF_PARAM="$crf_val"; echo "  CRF setat la: $CRF_PARAM"
        else
            echo "  Valoare invalida (0-$CRF_MAX) — se foloseste CRF auto."
        fi
    fi

elif [[ "$ENCODE_MODE" == "2" ]]; then
    validate_bitrate() { [[ "$1" =~ ^[0-9]+[kKmM]$ ]]; }
    to_kbps() {
        local br="$1" num="${1//[kKmM]/}"
        [[ "$br" =~ [mM]$ ]] && echo $(( num * 1000 )) || echo "$num"
    }
    echo ""; echo "VBR — Bitrate tinta (ex: 2000k, 4000k, 4M):"
    read -p "Bitrate tinta: " vbr_input
    if ! validate_bitrate "$vbr_input"; then
        echo "  EROARE: Format invalid '$vbr_input'"; exit 1
    fi
    VBR_PARAM="$vbr_input"
    VBR_KBPS=$(to_kbps "$vbr_input")
    VBR_MAXRATE_AUTO=$(( VBR_KBPS * 3 / 2 ))k
    VBR_BUFSIZE_AUTO=$(( VBR_KBPS * 2 ))k
    echo "  Bitrate: $VBR_PARAM | Maxrate: $VBR_MAXRATE_AUTO | Bufsize: $VBR_BUFSIZE_AUTO"
    read -p "Modifica maxrate/bufsize? (d/N): " override_choice
    if [[ "${override_choice,,}" == "d" ]]; then
        read -p "  Maxrate: " mr_input
        read -p "  Bufsize: " bs_input
        if validate_bitrate "$mr_input"; then VBR_MAXRATE="$mr_input"
        else echo "  AVERTISMENT: Maxrate invalid — se foloseste $VBR_MAXRATE_AUTO"
             VBR_MAXRATE="$VBR_MAXRATE_AUTO"; fi
        if validate_bitrate "$bs_input"; then VBR_BUFSIZE="$bs_input"
        else echo "  AVERTISMENT: Bufsize invalid — se foloseste $VBR_BUFSIZE_AUTO"
             VBR_BUFSIZE="$VBR_BUFSIZE_AUTO"; fi
    else
        VBR_MAXRATE="$VBR_MAXRATE_AUTO"; VBR_BUFSIZE="$VBR_BUFSIZE_AUTO"
    fi
    echo "  VBR final: $VBR_PARAM / max $VBR_MAXRATE / buf $VBR_BUFSIZE"
fi

# ── Preset ────────────────────────────────────────────────────────────
echo ""
if [[ "$ENCODER_NAME" == "av1" ]]; then
    if [[ "$AV1_ENCODER_NAME" == "libsvtav1" ]]; then
        echo "Preset SVT-AV1:  1)veryslow(0)  2)slower(2)  3)slow(4)  4)med-slow(5)"
        echo "                 5)medium(6)[rec] 6)med-fast(7) 7)fast(8) 8)faster(10) 9)ultrafast(12)"
    else
        echo "Preset libaom cpu-used: 1)0 2)1 3)2 4)3 5)4[rec] 6)5 7)6 8)7 9)8"
    fi
    read -p "Alege 1-9 [implicit: 5]: " preset_choice
    PRESET_PARAM="${preset_choice:-5}"
else
    echo "Preset: 1)ultrafast 2)superfast 3)veryfast 4)faster 5)fast"
    echo "        6)medium[tel] 7)slow[impl] 8)slower 9)veryslow"
    read -p "Alege 1-9 [implicit: 7]: " preset_choice
    case "$preset_choice" in
        1) PRESET_PARAM="ultrafast" ;; 2) PRESET_PARAM="superfast" ;;
        3) PRESET_PARAM="veryfast"  ;; 4) PRESET_PARAM="faster"    ;;
        5) PRESET_PARAM="fast"      ;; 6) PRESET_PARAM="medium"    ;;
        7) PRESET_PARAM="slow"      ;; 8) PRESET_PARAM="slower"    ;;
        9) PRESET_PARAM="veryslow"  ;; *) PRESET_PARAM="slow"      ;;
    esac
fi
echo "  Preset ales: $PRESET_PARAM"

# ── Tune / Film-grain ─────────────────────────────────────────────────
# NOTA: AV1 nu foloseste -tune; TUNE_PARAM = film-grain level numeric (0-50).
#       Cand film-grain=0 (dezactivat), TUNE_PARAM="" (string gol), identic cu
#       cazul x265/x264 fara tune — build_av1_params primeste "" si foloseste :-0.
#       x265/x264 folosesc -tune cu valori text (animation, grain, etc.).
echo ""
if [[ "$ENCODER_NAME" == "av1" ]]; then
    echo "Film-grain synthesis (AV1 specific, nu -tune):"
    echo "  0=off  1-10=usor  11-20=mediu  21-50=intens"
    read -p "Nivel 0-50 [implicit: 0]: " fg_input
    if [[ "$fg_input" =~ ^[0-9]+$ ]] && [ "$fg_input" -ge 0 ] && [ "$fg_input" -le 50 ]; then
        # FIX: 0 transmis ca "" pentru consistenta cu x265/x264 (TUNE_PARAM="" = dezactivat)
        if [ "$fg_input" -gt 0 ]; then
            TUNE_PARAM="$fg_input"
            echo "  Film-grain: $TUNE_PARAM"
        else
            TUNE_PARAM=""
            echo "  Film-grain dezactivat."
        fi
    else
        TUNE_PARAM=""
        [ -n "$fg_input" ] && echo "  Valoare invalida — se foloseste 0 (dezactivat)."
        echo "  Film-grain dezactivat."
    fi
else
    echo "Tune: 1)Fara[impl] 2)animation 3)grain 4)film 5)stillimage 6)fastdecode"
    read -p "Alege 1-6 [implicit: 1]: " tune_choice
    case "$tune_choice" in
        2) TUNE_PARAM="animation" ;; 3) TUNE_PARAM="grain"       ;;
        4) TUNE_PARAM="film"      ;; 5) TUNE_PARAM="stillimage"  ;;
        6) TUNE_PARAM="fastdecode";; *) TUNE_PARAM=""             ;;
    esac
    [[ -n "$TUNE_PARAM" ]] && echo "  Tune: $TUNE_PARAM" || echo "  Fara tune."
fi

# ── Parametri extra ───────────────────────────────────────────────────
echo ""
if [[ "$ENCODER_NAME" == "av1" ]]; then
    if [[ "$AV1_ENCODER_NAME" == "libsvtav1" ]]; then
        echo "Parametri extra SVT-AV1 (optional, ex: enable-overlays=1:scd=1):"
    else
        echo "Parametri extra libaom (optional, ex: -enable-chroma-deltaqp 1):"
    fi
else
    echo "Parametri extra ${ENCODER_NAME} (optional, ex: rc-lookahead=40:psy-rd=1.5):"
fi
echo "  Enter = sari"
read -p "Parametri: " extra_input

EXTRA_PARAM=""
if [[ -n "$extra_input" ]]; then
    VALID=1; ERROR_MSG=""
    if [[ "$ENCODER_NAME" == "av1" && "$AV1_ENCODER_NAME" == "libaom-av1" ]]; then
        [[ ! "$extra_input" =~ ^[-a-zA-Z0-9=:_.,\ ]+$ ]] && \
            VALID=0 && ERROR_MSG="Caractere invalide pentru libaom."
    else
        if ! [[ "$extra_input" =~ ^[a-zA-Z0-9=:_.,\-]+$ ]]; then
            VALID=0; ERROR_MSG="Caractere invalide."
        fi
        if [ $VALID -eq 1 ]; then
            IFS=':' read -ra SEGMENTS <<< "$extra_input"
            for seg in "${SEGMENTS[@]}"; do
                if   [[ -z "$seg" ]]; then
                    VALID=0; ERROR_MSG="Segment gol detectat"; break
                elif ! [[ "$seg" =~ ^[a-zA-Z][a-zA-Z0-9_-]*= ]]; then
                    VALID=0; ERROR_MSG="Segment invalid: '$seg'"; break
                elif [[ -z "${seg#*=}" ]]; then
                    VALID=0; ERROR_MSG="Valoare lipsa: '${seg%%=*}'"; break
                fi
            done
        fi
    fi
    if [ $VALID -eq 0 ]; then
        echo "  EROARE: $ERROR_MSG — Scriptul se opreste."; exit 1
    fi
    EXTRA_PARAM="$extra_input"
    echo "  Parametri validati: $EXTRA_PARAM"
else
    echo "  Fara parametri extra."
fi

fi  # end if [[ "$ENCODER_NAME" != "dnxhr"/"apv"/"prores" ]]

# ── Audio output ──────────────────────────────────────────────────────
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
echo "║  8) LPCM (PCM necomprimat)                      ║"
echo "║     16bit / 24bit / 32bit                        ║"
echo "║  9) Pastreaza audio original (copy)              ║"
echo "╚══════════════════════════════════════════════════╝"
read -p "Alege 1-9 [implicit: 1]: " audio_choice

AUDIO_CODEC_ARG=""
case "${audio_choice:-1}" in
    1) AUDIO_CODEC_ARG="aac:192k"
       echo "  Audio: AAC 192k / 5.1 384k / 7.1 768k" ;;
    2) read -p "  Bitrate AAC (ex: 128k, 256k, 320k): " aac_br
       if [[ "$aac_br" =~ ^[0-9]+[kK]$ ]]; then
           AUDIO_CODEC_ARG="aac:${aac_br,,}"
           echo "  Audio: AAC ${aac_br}"
       else
           echo "  Format invalid — se foloseste AAC 192k."
           AUDIO_CODEC_ARG="aac:192k"
       fi ;;
    3) AUDIO_CODEC_ARG="opus:128k"
       echo "  Audio: Opus 128k / 5.1 256k / 7.1 512k" ;;
    4) read -p "  Bitrate Opus (ex: 64k, 96k, 128k, 256k): " opus_br
       if [[ "$opus_br" =~ ^[0-9]+[kK]$ ]]; then
           AUDIO_CODEC_ARG="opus:${opus_br,,}"
           echo "  Audio: Opus ${opus_br}"
       else
           echo "  Format invalid — se foloseste Opus 128k."
           AUDIO_CODEC_ARG="opus:128k"
       fi ;;
    5) AUDIO_CODEC_ARG="flac:8"
       echo "  Audio: FLAC lossless (compression 8)" ;;
    6) read -p "  Compression level FLAC (0-12, default=8): " flac_lvl
       if [[ "$flac_lvl" =~ ^[0-9]+$ ]] && [ "$flac_lvl" -ge 0 ] && [ "$flac_lvl" -le 12 ]; then
           AUDIO_CODEC_ARG="flac:${flac_lvl}"
           echo "  Audio: FLAC lossless (compression ${flac_lvl})"
       else
           echo "  Nivel invalid — se foloseste FLAC compression 8."
           AUDIO_CODEC_ARG="flac:8"
       fi ;;
    7) AUDIO_CODEC_ARG="eac3:224k"
       echo "  Audio: E-AC3 (Dolby Digital Plus) — stereo 224k / 5.1 640k / 7.1 1024k" ;;
    8) echo "  LPCM bit depth:"
       echo "  1) 16bit [implicit]   2) 24bit (studio)   3) 32bit"
       read -p "  Alege 1-3 [implicit: 1]: " pcm_depth
       case "${pcm_depth:-1}" in
           2) AUDIO_CODEC_ARG="pcm:24le"; echo "  Audio: LPCM 24bit" ;;
           3) AUDIO_CODEC_ARG="pcm:32le"; echo "  Audio: LPCM 32bit" ;;
           *) AUDIO_CODEC_ARG="pcm:16le"; echo "  Audio: LPCM 16bit" ;;
       esac ;;
    9) AUDIO_CODEC_ARG="copy"
       echo "  Audio: pastreaza original (copy)" ;;
    *) AUDIO_CODEC_ARG="aac:192k"
       echo "  Audio: AAC 192k / 5.1 384k / 7.1 768k" ;;
esac

# FLAC + mp4/mov — avertisment (nu se aplica DNxHR — FLAC compatibil cu mov/mxf)
if [[ "$AUDIO_CODEC_ARG" == flac:* ]] && [[ "$CONTAINER" != "mkv" ]] && [[ "$ENCODER_NAME" != "dnxhr" ]] && [[ "$ENCODER_NAME" != "apv" ]] && [[ "$ENCODER_NAME" != "prores" ]]; then
    echo ""
    echo "  ATENTIE: FLAC nu este compatibil cu $CONTAINER."
    echo "  1) Schimba container la MKV [recomandat]"
    echo "  2) Schimba audio la AAC 192k"
    read -p "  Alege 1 sau 2 [implicit: 1]: " flac_fix
    if [[ "${flac_fix:-1}" == "2" ]]; then
        AUDIO_CODEC_ARG="aac:192k"
        echo "  Audio schimbat la AAC 192k"
    else
        CONTAINER="mkv"
        echo "  Container schimbat la MKV"
    fi
fi

# E-AC3 + mov — avertisment (mov nu suporta E-AC3 stabil)
if [[ "$AUDIO_CODEC_ARG" == eac3:* ]] && [[ "$CONTAINER" == "mov" ]]; then
    echo ""
    echo "  ATENTIE: E-AC3 nu este compatibil cu mov."
    echo "  1) Schimba container la MKV [recomandat]"
    echo "  2) Schimba container la MP4"
    echo "  3) Schimba audio la AAC 192k"
    read -p "  Alege 1, 2 sau 3 [implicit: 1]: " eac3_fix
    case "${eac3_fix:-1}" in
        2) CONTAINER="mp4"; echo "  Container schimbat la MP4" ;;
        3) AUDIO_CODEC_ARG="aac:192k"; echo "  Audio schimbat la AAC 192k" ;;
        *) CONTAINER="mkv"; echo "  Container schimbat la MKV" ;;
    esac
fi

# LPCM + mp4 — avertisment (mp4 nu suporta PCM nativ)
if [[ "$AUDIO_CODEC_ARG" == pcm:* ]] && [[ "$CONTAINER" == "mp4" ]]; then
    echo ""
    echo "  ATENTIE: LPCM nu este compatibil cu mp4."
    echo "  1) Schimba container la MKV [recomandat]"
    echo "  2) Schimba container la MOV"
    echo "  3) Schimba audio la AAC 192k"
    read -p "  Alege 1, 2 sau 3 [implicit: 1]: " pcm_fix
    case "${pcm_fix:-1}" in
        2) CONTAINER="mov"; echo "  Container schimbat la MOV" ;;
        3) AUDIO_CODEC_ARG="aac:192k"; echo "  Audio schimbat la AAC 192k" ;;
        *) CONTAINER="mkv"; echo "  Container schimbat la MKV" ;;
    esac
fi

# WebM: suporta DOAR Opus (si Vorbis). AAC/FLAC/E-AC3/LPCM incompatibile.
if [[ "$CONTAINER" == "webm" ]] && [[ "$AUDIO_CODEC_ARG" != opus:* ]] && [[ "$AUDIO_CODEC_ARG" != "copy" ]]; then
    echo ""
    echo "  ATENTIE: WebM suporta doar Opus ca audio codec."
    echo "  Audio curent: $AUDIO_CODEC_ARG"
    echo "  1) Schimba audio la Opus 128k / 5.1 256k / 7.1 512k [recomandat]"
    echo "  2) Schimba container la MKV"
    echo "  3) Schimba container la MP4"
    read -p "  Alege 1, 2 sau 3 [implicit: 1]: " webm_fix
    case "${webm_fix:-1}" in
        2) CONTAINER="mkv"; echo "  Container schimbat la MKV" ;;
        3) CONTAINER="mp4"; echo "  Container schimbat la MP4" ;;
        *) AUDIO_CODEC_ARG="opus:128k"; echo "  Audio schimbat la Opus 128k" ;;
    esac
fi

# ── Normalizare audio (loudnorm EBU R128) ────────────────────────────
echo ""
echo "╔══════════════════════════════════════╗"
echo "║  Normalizare volum (EBU R128)        ║"
echo "║  1) Fara normalizare [implicit]      ║"
echo "║  2) Normalizeaza la -24 LUFS         ║"
echo "║     (volum uniform pe tot batch-ul)  ║"
echo "╚══════════════════════════════════════╝"
read -p "Alege 1 sau 2 [implicit: 1]: " norm_choice
AUDIO_NORMALIZE="0"
case "${norm_choice:-1}" in
    2) AUDIO_NORMALIZE="1"; echo "  Normalizare: EBU R128 (-24 LUFS, 2-pass)" ;;
    *) echo "  Fara normalizare audio." ;;
esac

# ── LOG format video (Force detection) ────────────────────────────────
echo ""
echo "╔══════════════════════════════════════╗"
echo "║  Detectie LOG format video           ║"
echo "║  1) Auto-detect [implicit]           ║"
echo "║     (Apple Log, D-Log M, Samsung Log)║"
echo "║  2) Fortat ON (trateaza toate        ║"
echo "║     fisierele ca LOG)                ║"
echo "╚══════════════════════════════════════╝"
read -p "Alege 1 sau 2 [implicit: 1]: " log_detect_choice
FORCE_LOG_DETECTION="0"
case "${log_detect_choice:-1}" in
    2) FORCE_LOG_DETECTION="1"; echo "  LOG: Detectie fortata ON (toate fisierele)" ;;
    *) echo "  LOG: Auto-detect (Apple/Samsung/DJI)" ;;
esac

# ── Salvare profil (optional) ────────────────────────────────────────
echo ""
read -p "Salvezi configuratia ca profil? (d/N): " save_prof
if [[ "${save_prof,,}" == "d" ]]; then
    mkdir -p "$USER_PROFILES_DIR" 2>/dev/null
    read -p "  Nume profil (ex: drone_4k, film_hdr): " prof_name
    if [[ -n "$prof_name" ]]; then
        PROF_FILE="$USER_PROFILES_DIR/${prof_name}.conf"
        cat > "$PROF_FILE" <<PROFEOF
# AV Encoder Suite — Profil salvat: $prof_name
# Generat: $(date '+%Y-%m-%d %H:%M:%S')
ENCODER_NAME="$ENCODER_NAME"
AV1_ENCODER_NAME="${AV1_ENCODER_NAME:-}"
DNXHR_PROFILE="${DNXHR_PROFILE:-}"
APV_PROFILE="${APV_PROFILE:-}"
PRORES_PROFILE="${PRORES_PROFILE:-}"
X264_PROFILE="${X264_PROFILE:-}"
CONTAINER="$CONTAINER"
SCALE_WIDTH="${SCALE_WIDTH:-}"
TARGET_FPS="${TARGET_FPS:-}"
FPS_METHOD="${FPS_METHOD:-}"
VIDEO_FILTER_PRESET="${VIDEO_FILTER_PRESET:-}"
AUDIO_CODEC_ARG="$AUDIO_CODEC_ARG"
AUDIO_NORMALIZE="${AUDIO_NORMALIZE:-0}"
ENCODE_MODE="${ENCODE_MODE:-1}"
CRF_PARAM="${CRF_PARAM:-}"
PRESET_PARAM="${PRESET_PARAM:-}"
TUNE_PARAM="${TUNE_PARAM:-}"
EXTRA_PARAM="${EXTRA_PARAM:-}"
VBR_PARAM="${VBR_PARAM:-}"
VBR_MAXRATE="${VBR_MAXRATE:-}"
VBR_BUFSIZE="${VBR_BUFSIZE:-}"
FORCE_LOG_DETECTION="${FORCE_LOG_DETECTION:-0}"
PROFEOF
        echo "  Profil salvat: $PROF_FILE"
    fi
fi

fi  # end SKIP_CONFIG block (profile load)

# ════════════════════════════════════════════════════════════════════
# SFARSIT BLOC CONFIGURARE
# ════════════════════════════════════════════════════════════════════

# ── Dry-run / Resume / Interactive ────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════╗"
echo "║  Mod lansare                         ║"
echo "║  1) Encodeaza normal [implicit]      ║"
echo "║  2) Dry-run (doar analiza, fara enc) ║"
echo "║  3) Interactiv (modifica setari      ║"
echo "║     dupa fiecare fisier encodat)     ║"
echo "╚══════════════════════════════════════╝"
read -p "Alege 1-3 [implicit: 1]: " launch_mode
export DRY_RUN=0
export INTERACTIVE_MODE=0
export FORCE_LOG_DETECTION="${FORCE_LOG_DETECTION:-0}"
case "${launch_mode:-1}" in
    2) export DRY_RUN=1
       echo "  MOD DRY-RUN: se afiseaza ce ar face fara sa encodeze." ;;
    3) export INTERACTIVE_MODE=1
       echo "  MOD INTERACTIV: dupa fiecare fisier poti modifica setarile." ;;
    *) echo "  MOD NORMAL: aceleasi setari pentru toate fisierele." ;;
esac

# ── Lansare script encode ─────────────────────────────────────────────
# $1 = audio codec arg (ex: aac:192k, opus:128k, flac:8, copy)
# $2-$9 = CRF, PRESET, TUNE, EXTRA, MODE, VBR, MAXRATE, BUFSIZE
# ${10} = profil (x264) / av1_encoder / dnxhr_profile / "" (x265)
# ${11} = CONTAINER, ${12} = SCALE_WIDTH, ${13} = TARGET_FPS, ${14} = FPS_METHOD
# ${15} = VIDEO_FILTER_PRESET, ${16} = AUDIO_NORMALIZE
# DNxHR: $1=audio $2=profil $3=container $4=scale $5=fps $6=method $7=vf $8=normalize

if [[ "$ENCODER_NAME" == "dnxhr" ]]; then
    echo "Rulez $ENCODER_SCRIPT (profil: $DNXHR_PROFILE, container: $CONTAINER)..."
    ./"$ENCODER_SCRIPT" "$AUDIO_CODEC_ARG" \
        "$DNXHR_PROFILE" "$CONTAINER" "$SCALE_WIDTH" "$TARGET_FPS" "$FPS_METHOD" \
        "$VIDEO_FILTER_PRESET" "$AUDIO_NORMALIZE"
elif [[ "$ENCODER_NAME" == "apv" ]]; then
    echo "Rulez $ENCODER_SCRIPT (preset: $APV_PROFILE, container: $CONTAINER)..."
    ./"$ENCODER_SCRIPT" "$AUDIO_CODEC_ARG" \
        "$APV_PROFILE" "$CONTAINER" "$SCALE_WIDTH" "$TARGET_FPS" "$FPS_METHOD" \
        "$VIDEO_FILTER_PRESET" "$AUDIO_NORMALIZE"
elif [[ "$ENCODER_NAME" == "prores" ]]; then
    echo "Rulez $ENCODER_SCRIPT (profil: $PRORES_PROFILE, container: mov)..."
    ./"$ENCODER_SCRIPT" "$AUDIO_CODEC_ARG" \
        "$PRORES_PROFILE" "$CONTAINER" "$SCALE_WIDTH" "$TARGET_FPS" "$FPS_METHOD" \
        "$VIDEO_FILTER_PRESET" "$AUDIO_NORMALIZE"
elif [[ "$ENCODER_NAME" == "av1" ]]; then
    echo "Rulez $ENCODER_SCRIPT ($AV1_ENCODER_NAME, container: $CONTAINER)..."
    ./"$ENCODER_SCRIPT" "$AUDIO_CODEC_ARG" \
        "$CRF_PARAM" "$PRESET_PARAM" "$TUNE_PARAM" \
        "$EXTRA_PARAM" "$ENCODE_MODE" "$VBR_PARAM" "$VBR_MAXRATE" "$VBR_BUFSIZE" \
        "$AV1_ENCODER_NAME" "$CONTAINER" "$SCALE_WIDTH" "$TARGET_FPS" "$FPS_METHOD" \
        "$VIDEO_FILTER_PRESET" "$AUDIO_NORMALIZE"
elif [[ "$ENCODER_NAME" == "libx264" ]]; then
    echo "Rulez $ENCODER_SCRIPT (container: $CONTAINER)..."
    ./"$ENCODER_SCRIPT" "$AUDIO_CODEC_ARG" \
        "$CRF_PARAM" "$PRESET_PARAM" "$TUNE_PARAM" \
        "$EXTRA_PARAM" "$ENCODE_MODE" "$VBR_PARAM" "$VBR_MAXRATE" "$VBR_BUFSIZE" \
        "$X264_PROFILE" "$CONTAINER" "$SCALE_WIDTH" "$TARGET_FPS" "$FPS_METHOD" \
        "$VIDEO_FILTER_PRESET" "$AUDIO_NORMALIZE"
else
    echo "Rulez $ENCODER_SCRIPT (container: $CONTAINER)..."
    ./"$ENCODER_SCRIPT" "$AUDIO_CODEC_ARG" \
        "$CRF_PARAM" "$PRESET_PARAM" "$TUNE_PARAM" \
        "$EXTRA_PARAM" "$ENCODE_MODE" "$VBR_PARAM" "$VBR_MAXRATE" "$VBR_BUFSIZE" \
        "" "$CONTAINER" "$SCALE_WIDTH" "$TARGET_FPS" "$FPS_METHOD" \
        "$VIDEO_FILTER_PRESET" "$AUDIO_NORMALIZE"
fi
