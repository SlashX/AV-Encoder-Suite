#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# av_common.sh — Functii partajate + run_encode_loop()
#
# v26: Arhitectura unificata — loop-ul principal e AICI.
# Fiecare encoder defineste doar functiile specifice:
#   encoder_log_header()     — linii log specifice
#   encoder_setup_file()     — per fisier: seteaza FFMPEG_CMD (return 0/98)
#   encoder_get_suffix()     — "_x265" / "_x264" / "_av1" / "_dnxhr"
#   encoder_get_label()      — "libx265" / "libx264" / ... (UI)
#
# v41: Cross-platform — Termux / Linux / macOS.
#   detect_platform() seteaza AV_PLATFORM (termux|linux|macos) si AV_IS_TERMUX.
#   Pe Termux: caile raman /storage/emulated/0/Media/...
#   Pe Linux/macOS: cai relative la SCRIPT_DIR ($SCRIPT_DIR/InputVideos etc).
#   Wrapperele av_* abstractizeaza diferentele GNU vs BSD coreutils.
# ══════════════════════════════════════════════════════════════════════

# ── Bash 4+ check (macOS ships bash 3.2 — necesita brew install bash) ─
if [ -n "${BASH_VERSINFO:-}" ] && [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "EROARE: bash $BASH_VERSION detectat, este necesar bash 4+." >&2
    case "$(uname -s 2>/dev/null)" in
        Darwin)  echo "  macOS: brew install bash" >&2 ;;
        Linux)   echo "  Linux: instaleaza bash din package manager (apt/dnf/pacman)" >&2 ;;
        *)       echo "  Actualizeaza bash la versiunea 4 sau mai noua" >&2 ;;
    esac
    exit 1
fi

# ── Platform detection (v41) ──────────────────────────────────────────
# Seteaza: AV_PLATFORM (termux|linux|macos), AV_IS_TERMUX (0|1), AV_OS_LABEL
detect_platform() {
    local uname_s
    uname_s=$(uname -s 2>/dev/null)
    if [[ -d "/data/data/com.termux" ]] || [[ -n "${TERMUX_VERSION:-}" ]]; then
        AV_PLATFORM="termux"
        AV_IS_TERMUX=1
        AV_OS_LABEL="Termux (Android)"
    elif [[ "$uname_s" == "Darwin" ]]; then
        AV_PLATFORM="macos"
        AV_IS_TERMUX=0
        AV_OS_LABEL="macOS $(sw_vers -productVersion 2>/dev/null)"
    elif [[ "$uname_s" == "Linux" ]]; then
        AV_PLATFORM="linux"
        AV_IS_TERMUX=0
        local distro
        distro=$( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || echo "Linux")
        AV_OS_LABEL="$distro"
    else
        AV_PLATFORM="linux"
        AV_IS_TERMUX=0
        AV_OS_LABEL="$uname_s (necunoscut)"
    fi
    export AV_PLATFORM AV_IS_TERMUX AV_OS_LABEL
}
detect_platform

# ── SCRIPT_DIR resolution via BASH_SOURCE ─────────────────────────────
# Daca SCRIPT_DIR e deja setat de caller (launcher pe Termux), il pastram.
if [ -z "${SCRIPT_DIR:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# ── Path resolution: Termux pastreaza Android storage; Linux/macOS folosesc SCRIPT_DIR ──
if [[ "$AV_PLATFORM" == "termux" ]]; then
    INPUT_DIR="${INPUT_DIR:-/storage/emulated/0/Media/InputVideos}"
    OUTPUT_DIR="${OUTPUT_DIR:-/storage/emulated/0/Media/OutputVideos}"
    LUTS_DIR="${LUTS_DIR:-/storage/emulated/0/Media/Luts}"
    TOOLS_DIR="${TOOLS_DIR:-/storage/emulated/0/Media/Scripts/tools}"
    PROFILES_DIR="${PROFILES_DIR:-/storage/emulated/0/Media/Scripts/profiles}"
    USER_PROFILES_DIR="${USER_PROFILES_DIR:-/storage/emulated/0/Media/UserProfiles}"
    AV_TEMP_DIR="${AV_TEMP_DIR:-/storage/emulated/0/Media/Temp}"
else
    # Linux / macOS — totul langa scripturi
    INPUT_DIR="${INPUT_DIR:-$SCRIPT_DIR/InputVideos}"
    OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/OutputVideos}"
    LUTS_DIR="${LUTS_DIR:-$SCRIPT_DIR/Luts}"
    TOOLS_DIR="${TOOLS_DIR:-$SCRIPT_DIR/tools}"
    PROFILES_DIR="${PROFILES_DIR:-$SCRIPT_DIR/profiles}"
    USER_PROFILES_DIR="${USER_PROFILES_DIR:-$SCRIPT_DIR/UserProfiles}"
    AV_TEMP_DIR="${AV_TEMP_DIR:-$SCRIPT_DIR/Temp}"
fi
ensure_temp_dir() { mkdir -p "$AV_TEMP_DIR" 2>/dev/null; }

# ══════════════════════════════════════════════════════════════════════
# v69: Nume binare externe + engine-uri — SURSA UNICA (env-overridable).
# Daca upstream redenumeste un binar, schimba AICI (sau prin env, inclusiv
# cu cale absoluta — `command -v` accepta ambele). Executia in cod se face
# EXCLUSIV prin aceste variabile, niciodata prin nume hardcodat.
# ══════════════════════════════════════════════════════════════════════
AV_TOOL_DOVI="${AV_TOOL_DOVI:-dovi_tool}"                       # quietvoid (HEVC DV)
AV_TOOL_HDR10PLUS="${AV_TOOL_HDR10PLUS:-hdr10plus_tool}"        # quietvoid (HEVC HDR10+)
AV_TOOL_AV1DOVI="${AV_TOOL_AV1DOVI:-av1dovi_tool}"              # sven-pke fork (AV1 DV)
AV_TOOL_AV1HDR10PLUS="${AV_TOOL_AV1HDR10PLUS:-av1hdr10plus_tool}" # sven-pke fork (AV1 HDR10+)
AV_TOOL_EXIFTOOL="${AV_TOOL_EXIFTOOL:-exiftool}"                # telemetrie (DJI/QuickTime)
AV_TOOL_OAPV_DEC="${AV_TOOL_OAPV_DEC:-oapv_app_dec}"            # decoder referinta OpenAPV (optional)
AV_TOOL_SVTAV1ENCAPP="${AV_TOOL_SVTAV1ENCAPP:-SvtAv1EncApp}"    # SVT-AV1 standalone (doar caps-probe)
AV_TOOL_MKVMERGE="${AV_TOOL_MKVMERGE:-mkvmerge}"               # MKVToolNix (dvcC de container pe hibride HEVC DV pe MKV, v70)
AV_TOOL_MKVEXTRACT="${AV_TOOL_MKVEXTRACT:-mkvextract}"          # MKVToolNix (extract BL+EL+RPU din P7 MKV pt conversia P7->8.1, v76)
AV_TOOL_MP4BOX="${AV_TOOL_MP4BOX:-mp4box}"                      # GPAC MP4Box (dvcC de container pe hibride HEVC DV pe MP4/MOV, v71)
AV_ENGINE_APV_HDR10PLUS="${AV_ENGINE_APV_HDR10PLUS:-$SCRIPT_DIR/apv_hdr10plus.py}"
AV_ENGINE_DV_P7="${AV_ENGINE_DV_P7:-$SCRIPT_DIR/dv_p7_analyze.py}"  # clasificator EL (MEL/FEL) pt P7->8.1 (v76)

# ══════════════════════════════════════════════════════════════════════
# Cross-platform wrappers (v41) — abstractizeaza GNU vs BSD coreutils
# ══════════════════════════════════════════════════════════════════════

# av_nproc — numar de nuclee CPU (Linux/Termux: nproc, macOS: sysctl)
av_nproc() {
    if command -v nproc &>/dev/null; then
        nproc
    elif [[ "$AV_PLATFORM" == "macos" ]]; then
        sysctl -n hw.ncpu 2>/dev/null || echo 4
    else
        getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4
    fi
}

# av_stat_mtime <file> — modification time as epoch seconds
av_stat_mtime() {
    if [[ "$AV_PLATFORM" == "macos" ]]; then
        stat -f %m "$1" 2>/dev/null
    else
        stat -c %Y "$1" 2>/dev/null
    fi
}

# av_stat_size <file> — file size in bytes
av_stat_size() {
    if [[ "$AV_PLATFORM" == "macos" ]]; then
        stat -f %z "$1" 2>/dev/null
    else
        stat -c %s "$1" 2>/dev/null
    fi
}

# av_sed_inplace <expr> <file> — in-place sed (BSD necesita extensia argumentului)
av_sed_inplace() {
    local expr="$1"; shift
    if [[ "$AV_PLATFORM" == "macos" ]]; then
        sed -i '' -e "$expr" "$@"
    else
        sed -i -e "$expr" "$@"
    fi
}

# av_readlink_f <path> — canonicalize path (BSD readlink nu suporta -f)
av_readlink_f() {
    if [[ "$AV_PLATFORM" == "macos" ]]; then
        if command -v greadlink &>/dev/null; then
            greadlink -f "$1"
        else
            # Fallback Python (preinstalat pe macOS)
            python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$1" 2>/dev/null
        fi
    else
        readlink -f "$1"
    fi
}

# av_mktemp_dir [prefix] — temp directory portabil
av_mktemp_dir() {
    local prefix="${1:-avtmp}"
    if [[ "$AV_PLATFORM" == "macos" ]]; then
        mktemp -d -t "${prefix}.XXXXXX"
    else
        mktemp -d -t "${prefix}.XXXXXX" 2>/dev/null || mktemp -d "/tmp/${prefix}.XXXXXX"
    fi
}

# av_mktemp_ext <extension> — temp file cu extensie (portabil GNU vs BSD)
# GNU mktemp suporta --suffix; BSD mktemp NU. Fallback: mktemp + mv.
av_mktemp_ext() {
    local ext="$1"
    [[ "$ext" != .* ]] && ext=".$ext"
    if [[ "$AV_PLATFORM" == "macos" ]]; then
        local tmp; tmp=$(mktemp) || return 1
        mv "$tmp" "${tmp}${ext}" 2>/dev/null && echo "${tmp}${ext}"
    else
        mktemp --suffix="$ext" 2>/dev/null || {
            # Fallback (mktemp vechi care nu suporta --suffix)
            local tmp; tmp=$(mktemp) || return 1
            mv "$tmp" "${tmp}${ext}" && echo "${tmp}${ext}"
        }
    fi
}

# av_df_kb <path> — df portabil cu block size 1K (POSIX -Pk, GNU + BSD compatibil)
# Output: o singura linie cu campurile POSIX standard (col 4 = available KB).
av_df_kb() {
    df -Pk "$1" 2>/dev/null
}

# av_grep_perl <pattern> [args...] — grep cu suport regex Perl (BSD nu are -P)
av_grep_perl() {
    if [[ "$AV_PLATFORM" == "macos" ]]; then
        if command -v ggrep &>/dev/null; then
            ggrep -P "$@"
        else
            # Fallback: extended regex (nu acopera 100% Perl, dar suficient pentru pattern-uri simple)
            grep -E "$@"
        fi
    else
        grep -P "$@"
    fi
}

# av_date_to_epoch <date_string> — converteste data in epoch seconds
av_date_to_epoch() {
    if [[ "$AV_PLATFORM" == "macos" ]]; then
        # BSD date asteapta format explicit; incercam ISO 8601 si fallback
        date -j -f "%Y-%m-%d %H:%M:%S" "$1" +%s 2>/dev/null \
        || date -j -f "%Y-%m-%dT%H:%M:%S" "$1" +%s 2>/dev/null \
        || date -j -f "%Y-%m-%d" "$1" +%s 2>/dev/null
    else
        date -d "$1" +%s 2>/dev/null
    fi
}

# av_du_mb <path> — size MB (portabil)
av_du_mb() {
    du -sm "$1" 2>/dev/null | awk '{print $1}'
}

# ── Wake-lock / notify / open path wrappers (v41) ─────────────────────
# Termux: termux-wake-lock; Linux: systemd-inhibit (best effort); macOS: caffeinate
AV_WAKE_PID=""

av_wake_lock() {
    case "$AV_PLATFORM" in
        termux)
            command -v termux-wake-lock &>/dev/null && termux-wake-lock 2>/dev/null
            ;;
        macos)
            if command -v caffeinate &>/dev/null && [ -z "$AV_WAKE_PID" ]; then
                caffeinate -dimsu &
                AV_WAKE_PID=$!
            fi
            ;;
        linux)
            # Pe Linux nu putem mentine usor wake-lock background fara comanda activa;
            # systemd-inhibit asteapta o comanda — folosim doar daca disponibil ca info.
            :
            ;;
    esac
}

av_wake_unlock() {
    case "$AV_PLATFORM" in
        termux)
            command -v termux-wake-unlock &>/dev/null && termux-wake-unlock 2>/dev/null
            ;;
        macos)
            if [ -n "$AV_WAKE_PID" ]; then
                kill "$AV_WAKE_PID" 2>/dev/null
                AV_WAKE_PID=""
            fi
            ;;
        linux)
            :
            ;;
    esac
}

# av_notify_done <title> <message> — notificare la final batch
av_notify_done() {
    local title="${1:-AV Encoder}"
    local msg="${2:-Operatiune finalizata}"
    case "$AV_PLATFORM" in
        termux)
            command -v termux-notification &>/dev/null && \
                termux-notification --title "$title" --content "$msg" 2>/dev/null
            ;;
        linux)
            command -v notify-send &>/dev/null && \
                notify-send "$title" "$msg" 2>/dev/null
            ;;
        macos)
            command -v osascript &>/dev/null && \
                osascript -e "display notification \"$msg\" with title \"$title\"" 2>/dev/null
            ;;
    esac
}

# av_open_path <path> — deschide folder in file manager
av_open_path() {
    local p="${1:-$OUTPUT_DIR}"
    case "$AV_PLATFORM" in
        termux)
            command -v termux-open &>/dev/null && termux-open "$p" 2>/dev/null
            ;;
        linux)
            command -v xdg-open &>/dev/null && xdg-open "$p" 2>/dev/null &
            ;;
        macos)
            command -v open &>/dev/null && open "$p" 2>/dev/null
            ;;
    esac
}

# av_print_os_banner — afiseaza banner OS la startup (chemat din launcher)
av_print_os_banner() {
    echo ""
    echo "  Sistem: $AV_OS_LABEL  |  bash $BASH_VERSION  |  $(av_nproc) thread(s)"
    if [[ "$AV_PLATFORM" == "termux" ]] && ! [ -d "/storage/emulated/0" ]; then
        echo "  ⚠ Storage Termux inaccesibil — ruleaza: termux-setup-storage"
    fi
}

# av_pkg_install_hint <package> — sugestie de instalare per platforma
av_pkg_install_hint() {
    local pkg="$1"
    case "$AV_PLATFORM" in
        termux) echo "pkg install $pkg" ;;
        macos)  echo "brew install $pkg" ;;
        linux)
            if command -v apt &>/dev/null;     then echo "sudo apt install $pkg"
            elif command -v dnf &>/dev/null;   then echo "sudo dnf install $pkg"
            elif command -v pacman &>/dev/null; then echo "sudo pacman -S $pkg"
            elif command -v zypper &>/dev/null; then echo "sudo zypper install $pkg"
            else echo "instaleaza $pkg din package manager-ul distributiei"
            fi ;;
    esac
}


# ── Logging ───────────────────────────────────────────────────────────
log() {
    if [ -n "${LOG_FILE:-}" ]; then
        echo "$1" | tee -a "$LOG_FILE"
    else
        echo "$1"
    fi
}

# ── Cleanup trap ──────────────────────────────────────────────────────
setup_trap() { trap '_cleanup_on_exit' INT TERM; }

_cleanup_on_exit() {
    [ -n "${PROGRESS_FILE:-}" ] && rm -f "$PROGRESS_FILE"
    # v51: cleanup 2-pass stats dir daca user intrerupe in mijlocul encode-ului
    [ -n "${STATS_DIR:-}" ] && [ -d "${STATS_DIR:-}" ] && rm -rf "$STATS_DIR"
    av_wake_unlock
    echo ""; log "  INTRERUPT de utilizator."; exit 1
}

# ══════════════════════════════════════════════════════════════════════
# DETECTIE SURSA — un singur loc, seteaza variabile globale
# WIDTH, HEIGHT, HDR_TYPE, HDR_PLUS, DOVI, DURATION, SRC_FPS, SRC_FPS_DEC
# ══════════════════════════════════════════════════════════════════════
detect_source_info() {
    local file="$1"
    # v63 robust (multi-field csv=p=0 — verificat empiric pe surse reale):
    #  (a) `tr -d '\r'` — ffprobe scrie CRLF pe Windows/git-bash → fara strip, HDR_TYPE capta `\r`
    #      → match-ul EXACT al HLG (`== "arib-std-b67"`, ~485) esua → IS_HLG=0. No-op pe Unix (LF).
    #  (b) trailing comma: pe surse cu [SIDE_DATA] (HDR10/HDR10+/DV) csv da `1920,1080,smpte2084,`
    #      (camp gol in plus) → `tr ',' ' '` → spatiu trailing.
    #  (c) DJI Action 6: raporteaza v:0 de 2 ori (3 linii: val + gol + val) → `read` ia PRIMA linie.
    #  Var `_csv_extra` absoarbe EXPLICIT orice camp dupa al 3-lea → HDR_TYPE = mereu exact campul 3
    #  (nu depinde de absorbtia subtila a spatiului trailing de catre read).
    local _csv_extra
    read -r WIDTH HEIGHT HDR_TYPE _csv_extra < <(ffprobe -v error -select_streams v:0 \
        -show_entries stream=width,height,color_transfer \
        -of csv=p=0 "$file" 2>/dev/null | tr -d '\r' | tr ',' ' ')
    [[ ! "$WIDTH"  =~ ^[0-9]+$ ]] && WIDTH=0
    [[ ! "$HEIGHT" =~ ^[0-9]+$ ]] && HEIGHT=0
    IS_HLG=0

    # v58 audit FIX: side_data_type (NU `type` — ffprobe ignora filterul invalid si
    # dumpeaza TOATE field-urile frame-ului. Pe ffmpeg 8.x output-ul NU include side_data
    # sections → grep "HDR10+" niciodata nu match-uia → HDR_PLUS empty pe TOATE clipurile
    # HDR10+ HEVC + AV1. Pre-existent din v25+. Aceeasi familie de bug ca v57 av_check.
    HDR_PLUS=$(ffprobe -v error -read_intervals 0%+#5 -show_frames \
        -select_streams v:0 -show_entries frame_side_data=side_data_type \
        "$file" 2>/dev/null | grep -m1 "HDR10+")

    # v69: HDR10+ pe surse APV — decoderul ffmpeg IGNORA T.35 (nu apare in
    # frame_side_data) → probe prin engine-ul apv_hdr10plus.py (primele 3 AU).
    if [[ -z "$HDR_PLUS" ]]; then
        local _apv_vc
        _apv_vc=$(detect_source_codec "$file")
        if [[ "$_apv_vc" == "apv" ]]; then
            [[ "$(_apv_hdr10plus_probe "$file")" == "hdr10plus" ]] && HDR_PLUS="HDR10+ (APV T.35)"
        fi
    fi

    DOVI=$(ffprobe -v error -show_entries stream=codec_tag_string \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | \
        grep -i "dovi\|dvhe\|dvh1" | head -1)
    # v58 audit FIX: AV1 DV detection — codec_tag e [0][0][0][0] pe AV1; RPU sta in
    # OBU_METADATA (provider 0x003B), detectabil doar via side_data per-frame.
    if [[ -z "$DOVI" ]]; then
        local _av1dv
        _av1dv=$(ffprobe -v error -read_intervals 0%+#5 -show_frames \
            -select_streams v:0 -show_entries frame_side_data=side_data_type \
            "$file" 2>/dev/null | grep -m1 "Dolby Vision Metadata")
        [[ -n "$_av1dv" ]] && DOVI="dolby_vision"
    fi

    DURATION=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
    DURATION=${DURATION%.*}; [[ ! "$DURATION" =~ ^[0-9]+$ ]] && DURATION=0

    SRC_FPS=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=r_frame_rate \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1)
    SRC_FPS_DEC=$(awk "BEGIN{printf \"%.3f\", $SRC_FPS}" 2>/dev/null)

    # ── LOG format detection ──────────────────────────────────────────
    LOG_PROFILE=""
    CAMERA_MAKE=""
    SRC_COLOR_TRC=""
    SRC_IS_VFR=0

    if [[ "${FORCE_LOG_DETECTION:-0}" == "1" ]]; then
        LOG_PROFILE="forced_log"
        CAMERA_MAKE="unknown"
    else
        # Detect camera make from format tags
        local all_tags
        all_tags=$(ffprobe -v error -show_entries format_tags \
            -of default=noprint_wrappers=1 "$file" 2>/dev/null)
        # v58 audit FIX: Samsung S24 Ultra short-circuit pe com.samsung.android.logvideo
        # (autoritar pt Samsung Log — S24 Ultra Android 16 NU emite make=samsung).
        # Plus DJI fallback pe encoder=DJI (clipuri re-muxate cu djmd/dbgi strip).
        # Aliniat cu av_check v57.
        if echo "$all_tags" | grep -qi "com\.samsung\.android\.logvideo"; then
            CAMERA_MAKE="samsung"
            LOG_PROFILE="samsung_log"
        # Apple: com.apple.quicktime.make=Apple
        elif echo "$all_tags" | grep -qi "make=.*apple"; then
            CAMERA_MAKE="apple"
        # DJI: com.apple.quicktime.make=DJI or make=DJI or encoder=DJI (re-muxat)
        elif echo "$all_tags" | grep -qi "make=.*dji\|encoder=.*dji"; then
            CAMERA_MAKE="dji"
        # Samsung: com.android.manufacturer=samsung or make=samsung or com.samsung.android (fallback)
        elif echo "$all_tags" | grep -qi "manufacturer=.*samsung\|make=.*samsung\|com\.samsung\.android"; then
            CAMERA_MAKE="samsung"
        fi
        # Fallback: DJI tracks detection (already have detect_dji_tracks)
        if [[ -z "$CAMERA_MAKE" ]] && [[ "${IS_DJI:-0}" -eq 1 ]]; then
            CAMERA_MAKE="dji"
        fi

        # Detect color transfer characteristic
        SRC_COLOR_TRC=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=color_transfer \
            -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1 | tr -d '\r')

        # Detect bit depth — bits_per_raw_sample, fallback pe pix_fmt. v62: pe multe
        # surse HEVC 10-bit bits_per_raw_sample e N/A → cadea pe 8 → ratam Apple Log /
        # D-Log bt2020 / unknown_log (toate cer >=10-bit). Paritate cu av_check.sh.
        local src_bps src_pixfmt_bd
        src_bps=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=bits_per_raw_sample \
            -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1 | tr -d '\r')
        if [[ ! "$src_bps" =~ ^[0-9]+$ ]]; then
            src_pixfmt_bd=$(ffprobe -v error -select_streams v:0 \
                -show_entries stream=pix_fmt \
                -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1)
            case "$src_pixfmt_bd" in
                *p16*|*p016*) src_bps=16 ;;
                *p12*|*p012*) src_bps=12 ;;
                *p10*|*p010*) src_bps=10 ;;
                *)            src_bps=8  ;;
            esac
        fi

        # Detect color primaries
        local src_primaries
        src_primaries=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=color_primaries \
            -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1)

        # Samsung Log mode tag
        local samsung_log_tag
        samsung_log_tag=$(echo "$all_tags" | grep -i "log_mode\|samsung.*log" | head -1)

        # LOG profile identification
        # Apple Log: color_trc typically reports as arib-std-b67 or specific Apple Log tag
        if [[ "$CAMERA_MAKE" == "apple" ]]; then
            if [[ "$src_bps" -ge 10 ]] && [[ "$src_primaries" == *"bt2020"* || "$SRC_COLOR_TRC" == *"arib"* || "$SRC_COLOR_TRC" == *"log"* ]]; then
                LOG_PROFILE="apple_log"
            fi
        # Samsung Log
        elif [[ "$CAMERA_MAKE" == "samsung" ]]; then
            if [[ -n "$samsung_log_tag" ]] || { [[ "$src_bps" -ge 10 ]] && [[ "$src_primaries" == *"bt2020"* ]]; }; then
                # Samsung HDR10+ is NOT Log — already handled by HDR_PLUS check
                # v62: exclude HLG (arib-std-b67) — Samsung Log raporteaza transfer=unknown,
                # HLG raporteaza arib. Fara excludere, un clip Samsung gradat-HLG (Log+LUT in
                # editorul de telefon → output arib/bt2020) ar fi marcat gresit samsung_log.
                if [[ -z "$HDR_PLUS" ]] && [[ "$HDR_TYPE" != *"smpte2084"* ]] && [[ "$HDR_TYPE" != *"arib"* ]]; then
                    LOG_PROFILE="samsung_log"
                fi
            fi
        # DJI D-Log M
        elif [[ "$CAMERA_MAKE" == "dji" ]]; then
            # v62: exclude HLG (drone DJI — Mavic/Air — pot emite HLG bt2020/arib)
            if [[ "$src_bps" -ge 10 ]] && [[ "$src_primaries" == *"bt2020"* ]] && [[ "$HDR_TYPE" != *"arib"* ]]; then
                LOG_PROFILE="dlog_m"   # DJI vechi (Mavic/Air) D-Log Wide → container bt2020
            elif [[ "$src_bps" -ge 10 ]] && [[ "$HDR_TYPE" != *"arib"* ]] \
                 && [[ "$HDR_TYPE" != *"smpte2084"* ]] && [[ -z "$DOVI" ]] && [[ -z "$HDR_PLUS" ]]; then
                # v62 Faza B: Osmo Action 6 D-Log M e bt709 in container (identic cu
                # Normal) → sondam djmd protobuf. dlog_m → LOG; "normal"/"unknown"
                # (non-AC006 / djmd lipsa / fara python) ramane SDR onest.
                [[ "$(_detect_dji_dlogm "$file")" == "dlog_m" ]] && LOG_PROFILE="dlog_m"
            fi
        # Unknown brand but looks like Log (10-bit + bt2020 + no HDR metadata)
        elif [[ "$src_bps" -ge 10 ]] && [[ "$src_primaries" == *"bt2020"* ]] \
             && [[ -z "$HDR_PLUS" ]] && [[ "$HDR_TYPE" != *"smpte2084"* ]] && [[ -z "$DOVI" ]]; then
            # Check for known Log transfer characteristics
            # v62: NU mai tratam arib ca semnal Log — arib-std-b67 e HLG (prins separat
            # mai jos). Log necunoscut raporteaza transfer=unknown sau *log*.
            if [[ "$SRC_COLOR_TRC" == "unknown" || "$SRC_COLOR_TRC" == *"log"* ]]; then
                LOG_PROFILE="unknown_log"
                CAMERA_MAKE="unknown"
            fi
        fi
    fi

    # HLG detection (BT.2100 HLG, transfer=arib-std-b67)
    # Mutually exclusive cu HDR10/HDR10+/DV/LOG (Apple Log poate raporta arib-std-b67)
    if [[ "$HDR_TYPE" == "arib-std-b67" ]] \
       && [[ -z "$LOG_PROFILE" ]] && [[ -z "$DOVI" ]] && [[ -z "$HDR_PLUS" ]]; then
        IS_HLG=1
    fi

    # VFR detection (useful for Log sources from phones)
    if [[ -n "$LOG_PROFILE" ]]; then
        local avg_fps
        avg_fps=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=avg_frame_rate \
            -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1)
        if [[ -n "$avg_fps" ]] && [[ -n "$SRC_FPS" ]]; then
            local avg_dec src_dec
            avg_dec=$(awk "BEGIN{printf \"%.3f\", $avg_fps}" 2>/dev/null)
            src_dec=$(awk "BEGIN{printf \"%.3f\", $SRC_FPS}" 2>/dev/null)
            # If avg_fps differs significantly from r_frame_rate, likely VFR
            local diff
            diff=$(awk "BEGIN{d=$src_dec-$avg_dec; if(d<0)d=-d; print (d > 0.5) ? 1 : 0}" 2>/dev/null)
            [[ "$diff" == "1" ]] && SRC_IS_VFR=1
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════════
# DJI HANDLING
# ══════════════════════════════════════════════════════════════════════
detect_dji_tracks() {
    local file="$1"
    local has_djmd=0 has_dbgi=0 has_tc=0 has_cover=0
    local tracks
    tracks=$(ffprobe -v error \
        -show_entries stream=index,codec_tag_string,codec_name,codec_type \
        -of default=noprint_wrappers=1 "$file" 2>/dev/null)
    echo "$tracks" | grep -qi "djmd"        && has_djmd=1
    echo "$tracks" | grep -qi "dbgi"        && has_dbgi=1
    echo "$tracks" | grep -qi "tmcd"        && has_tc=1
    echo "$tracks" | grep -qi "mjpeg\|jpeg" && has_cover=1
    echo "${has_djmd}|${has_dbgi}|${has_tc}|${has_cover}"
}

# Seteaza: MAP_FLAGS, IS_DJI (+ KEEP_* la 0, ramase doar pt contractul de stare).
# Pistele de date DJI (djmd/dbgi/tmcd, codec=none) NU pot fi muxate de ffmpeg in NICIUN
# container (matroska "Only audio/video/subtitles"; mp4 "tag for codec none") → mereu
# eliminate la encode. GPS-ul nativ (djmd) se re-grefeaza POST-encode pe MP4/MOV via MP4Box
# (_dji_preserve_meta_postencode, v78). Pe MKV pastrarea nativa e imposibila → ramane embed
# SRT/CSV/GPX (meniul Telemetrie opt 7). Vechiul "Schimba la MKV (pastreaza tot)" era rupt
# (ffmpeg refuza codec=none + index pe pozitie de linie gresit pe blocul fantoma ffprobe).
handle_dji_full() {
    local file="$1" out_suffix="$2"   # out_suffix pastrat pt compat call-site (neutilizat)
    local dji_info
    dji_info=$(detect_dji_tracks "$file")
    IS_DJI=0; KEEP_DJMD=0; KEEP_DBGI=0; KEEP_TMCD=0

    if [ "$(echo "$dji_info" | cut -d'|' -f1)" -eq 1 ] || \
       [ "$(echo "$dji_info" | cut -d'|' -f2)" -eq 1 ]; then IS_DJI=1; fi

    if [ "$IS_DJI" -eq 1 ]; then
        log "  Fisier DJI detectat"
        MAP_FLAGS="-map 0:v:0 -map 0:a? -map 0:s? -map_metadata 0 -map_chapters 0"
        local _ct="${CONTAINER:-mp4}"
        case "$_ct" in
            mp4|mov|m4v|qt)
                log "  Track-uri DJI eliminate la encode; GPS-ul djmd se re-grefeaza automat in output (MP4Box, v78)" ;;
            *)
                log "  Track-uri DJI eliminate; pe .$_ct GPS-ul nativ nu poate fi pastrat — foloseste Telemetrie opt 7 (SRT/CSV/GPX embed)" ;;
        esac
    else
        MAP_FLAGS="-map 0:v -map 0:a? -map 0:s? -map 0:t? -map_metadata 0 -map_chapters 0"
    fi
    log "  Map flags: $MAP_FLAGS"
}

# ══════════════════════════════════════════════════════════════════════
# DOLBY VISION
# ══════════════════════════════════════════════════════════════════════
get_dv_profile() {
    local file="$1" dv_info dv_profile_num dv_compat
    # v62: STREAM side_data "DOVI configuration record" (HEVC + AV1); frame_side_data e gol pe AV1
    dv_info=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream_side_data=dv_profile,dv_bl_signal_compatibility_id \
        -of default=noprint_wrappers=1 "$file" 2>/dev/null)
    dv_profile_num=$(echo "$dv_info" | grep "dv_profile=" | head -1 | cut -d= -f2 | tr -d '[:space:]')
    dv_compat=$(echo "$dv_info" | grep "dv_bl_signal_compatibility_id=" | head -1 | cut -d= -f2 | tr -d '[:space:]')
    if [[ -z "$dv_profile_num" ]]; then  # fallback: frame side_data (HEVC fara config record)
        dv_info=$(ffprobe -v error -show_frames -select_streams v:0 -read_intervals 0%+#5 \
            -show_entries frame_side_data=dv_profile,dv_bl_signal_compatibility_id \
            -of default "$file" 2>/dev/null)
        dv_profile_num=$(echo "$dv_info" | grep "dv_profile=" | head -1 | cut -d= -f2 | tr -d '[:space:]')
        dv_compat=$(echo "$dv_info" | grep "dv_bl_signal_compatibility_id=" | head -1 | cut -d= -f2 | tr -d '[:space:]')
    fi
    if [[ -n "$dv_profile_num" && "$dv_profile_num" =~ ^[0-9]+$ ]]; then
        case "$dv_profile_num" in
            4) echo "Profil 4 (DV + HDR10 fallback)" ;; 5) echo "Profil 5 (DV only)" ;;
            7) echo "Profil 7 (DV + HDR10+)" ;;
            8) case "$dv_compat" in
                1) echo "Profil 8.1 (DV + HDR10, Blu-ray)" ;; 2) echo "Profil 8.2 (DV + SDR)" ;;
                4) echo "Profil 8.4 (DV + HLG)" ;; *) echo "Profil 8 (DV + HDR10)" ;; esac ;;
            9) echo "Profil 9 (DV + SDR)" ;;
            10) case "$dv_compat" in
                1) echo "Profil 10.1 (DV AV1 + HDR10)" ;; 2) echo "Profil 10.2 (DV AV1 + SDR)" ;;
                4) echo "Profil 10.4 (DV AV1 + HLG)" ;; *) echo "Profil 10 (DV AV1)" ;; esac ;;
            *) echo "Profil $dv_profile_num" ;; esac
    else
        local codec_tag
        codec_tag=$(ffprobe -v error -show_entries stream=codec_tag_string \
            -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -5)
        case "$codec_tag" in *dvhe*) echo "Profil 8 (dvhe)";; *dvh1*) echo "Profil 8 (dvh1)";; *) echo "DV (profil nedetectat)";; esac
    fi
}

# DV stream copy — return: 0=copy OK, 98=sarit, 99=re-encode
handle_dolby_vision() {
    local file="$1" filename="$2" output="$3" map_flags="$4"
    local opt2_label="${5:-Converteste la HDR10 (best-effort)}"
    echo ""
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║       DOLBY VISION DETECTAT                  ║"
    printf "  ║  Fisier: %-38s║\n" "$filename"
    printf "  ║  Profil: %-38s║\n" "$(get_dv_profile "$file")"
    echo "  ╠══════════════════════════════════════════════╣"
    echo "  ║  1) Stream copy video + reencodeaza audio    ║"
    printf "  ║  2) %-43s║\n" "$opt2_label"
    echo "  ║  3) Sari acest fisier                        ║"
    echo "  ╚══════════════════════════════════════════════╝"
    read -p "  Alege 1, 2 sau 3: " dv_choice
    case "$dv_choice" in
        1)
            log "  DV: stream copy"
            local dv_audio sub_codec_dv pf fpid dv_container_flags
            dv_audio=$(get_audio_params "$file"); sub_codec_dv=$(get_subtitle_codec "$file")
            pf=$(mktemp); PROGRESS_FILE="$pf"; dv_container_flags=$(get_container_flags)
            # shellcheck disable=SC2086
            ffmpeg -threads "$THREADS" -i "$file" $map_flags \
                -c:v copy $dv_audio $sub_codec_dv -c:t copy \
                $dv_container_flags -progress "$pf" -nostats "$output" 2>>"$LOG_FILE" &
            fpid=$!; _show_progress "$fpid" "$pf" "$file" "DV stream copy"; wait "$fpid"
            local rc=$?; PROGRESS_FILE=""; return $rc ;;
        2) log "  DV: re-encode ($opt2_label)"; return 99 ;;
        3) log "  DV: sarit de utilizator"; return 98 ;;
        *) log "  DV: sarit (optiune invalida)"; return 98 ;;
    esac
}

# v45: handle_dv_with_stats() removed — x265 v45 has inline DV dialog with
# 4 options (preserve + stream-copy stats inline); AV1 has its own dialog;
# other encoders never used it.

# ══════════════════════════════════════════════════════════════════════
# SUBTITLE / CONTAINER / SOURCE HINTS
# ══════════════════════════════════════════════════════════════════════
get_subtitle_codec() {
    local file="$1"
    case "$CONTAINER" in
        mkv) echo "-c:s copy" ;;
        mp4|mov)
            local sub_codecs
            sub_codecs=$(ffprobe -v error -select_streams s \
                -show_entries stream=codec_name \
                -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
            if echo "$sub_codecs" | grep -qi "hdmv_pgs\|dvd_subtitle\|dvb_subtitle"; then
                log "  ATENTIE: Subtitrari PGS/DVDSUB incompatibile cu $CONTAINER — omise"
                echo "-sn"
            else echo "-c:s mov_text"; fi ;;
        *) echo "-c:s copy" ;;
    esac
}

get_container_flags() {
    case "$CONTAINER" in mkv|mxf|webm) echo "" ;; *) echo "-movflags +faststart" ;; esac
}

# v57: codec FourCC tag pentru MP4/MOV/M4V — ffmpeg default este `hev1`/etc.,
# dar playere DV-aware (Apple TV, Sony) si Apple QuickTime prefera `hvc1`/`av01`
# pentru engagement DV si compatibilitate iOS. Pe MKV/MXF/WebM: nu se aplica
# (containerul foloseste codec ID strings).
#   $1 = codec key (hevc / av1 / h264)
#   $2 = container extension (mp4 / mov / m4v / mkv / ...)
# Output: "-tag:v X" sau gol.
codec_tag_for_container() {
    local codec="$1" container="$2"
    case "${container,,}" in
        mp4|mov|m4v)
            case "$codec" in
                hevc) echo "-tag:v hvc1" ;;
                av1)  echo "-tag:v av01" ;;
                h264) echo "-tag:v avc1" ;;
            esac
            ;;
    esac
}

hint_source_format() {
    local ext="$1"
    case "$ext" in
        vob) log "  SURSA DVD (.vob): MPEG-2, posibil interlasata."
             log "  Recomandat: activeaza filtrul Deinterlace (bwdif)." ;;
        m2ts|mts) log "  SURSA Blu-ray (.m2ts): H.264/H.265, progresiv de obicei." ;;
        mxf) log "  SURSA MXF: format profesional (Avid, broadcast)." ;;
        apv) log "  SURSA APV: codec profesional nou. Necesita ffmpeg 8.1+." ;;
    esac
    # ProRes detectat pe baza codec-ului, nu a extensiei (vine in .mov)
    if [[ -n "$file" ]]; then
        local src_codec_hint
        # v57: default= in loc de csv=p=0 — trailing comma "prores," esua gate ==
        src_codec_hint=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
        [[ "$src_codec_hint" == "prores" ]] && log "  SURSA ProRes: codec Apple profesional (intra-frame, editare)."
    fi
}

# ══════════════════════════════════════════════════════════════════════
# VIDEO FILTERS
# ══════════════════════════════════════════════════════════════════════
_get_preset_vf() {
    case "${VIDEO_FILTER_PRESET:-}" in
        denoise_light)  echo "nlmeans=h=1.0:s=7:p=3:r=5" ;;
        denoise_medium) echo "hqdn3d=luma_spatial=4:chroma_spatial=3:luma_tmp=6:chroma_tmp=4.5" ;;
        denoise_strong) echo "nlmeans=h=3.0:s=7:p=5:r=9" ;;
        sharpen_light)  echo "unsharp=luma_msize_x=5:luma_msize_y=5:luma_amount=0.8:chroma_msize_x=5:chroma_msize_y=5:chroma_amount=0.4" ;;
        sharpen_medium) echo "cas=strength=0.6" ;;
        deinterlace)    echo "bwdif=mode=send_field:parity=auto:deint=all" ;;
        upscale_4k)     echo "scale=3840:-2:flags=lanczos" ;;
        custom:*)       echo "${VIDEO_FILTER_PRESET#custom:}" ;;
        *)              echo "" ;;
    esac
}

build_video_filters() {
    local src_width="$1" src_fps="$2" vf_parts=""
    if [[ "${VIDEO_FILTER_PRESET:-}" != "upscale_4k" ]]; then
        if [[ -n "$SCALE_WIDTH" ]] && [[ "$src_width" =~ ^[0-9]+$ ]] && [ "$src_width" -gt "$SCALE_WIDTH" ]; then
            vf_parts="scale=${SCALE_WIDTH}:-2"
        fi
    fi
    local preset_vf; preset_vf=$(_get_preset_vf)
    if [[ -n "$preset_vf" ]]; then
        [[ -n "$vf_parts" ]] && vf_parts="${vf_parts},${preset_vf}" || vf_parts="$preset_vf"
    fi
    local fps_active=0
    if [[ -n "$TARGET_FPS" ]] && [[ -n "$src_fps" ]]; then
        local src_num target_num
        src_num=$(awk "BEGIN{printf \"%.3f\", $src_fps + 0}" 2>/dev/null)
        target_num=$(awk "BEGIN{printf \"%.3f\", $TARGET_FPS + 0}" 2>/dev/null)
        awk "BEGIN{exit !($src_num > $target_num)}" 2>/dev/null && fps_active=1
    fi
    if [ "$fps_active" -eq 1 ]; then
        if [[ "$FPS_METHOD" == "minterpolate" ]]; then
            local mi="minterpolate=fps=${TARGET_FPS}:mi_mode=mci:mc_mode=aobmc:vsbmc=1"
            [[ -n "$vf_parts" ]] && vf_parts="${vf_parts},$mi" || vf_parts="$mi"
            echo "-vf $vf_parts"
        else
            [[ -n "$vf_parts" ]] && echo "-vf $vf_parts -r $TARGET_FPS" || echo "-r $TARGET_FPS"
        fi
    else
        [[ -n "$vf_parts" ]] && echo "-vf $vf_parts"
    fi
}

# ══════════════════════════════════════════════════════════════════════
# PROGRESS BAR
# ══════════════════════════════════════════════════════════════════════
_show_progress() {
    local pid=$1 prog_file=$2 src_file=$3
    local label="${4:-Progres}"   # v38: label opțional pentru context (encoder name etc.)
    local dur_p st_p
    dur_p=$(ffprobe -v error -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 "$src_file" 2>/dev/null)
    dur_p=${dur_p%.*}; [[ ! "$dur_p" =~ ^[0-9]+$ ]] && dur_p=0
    st_p=$(date +%s); PROGRESS_FILE="$prog_file"
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        local otms=$(grep "^out_time_ms=" "$prog_file" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' ')
        if ! [[ "$otms" =~ ^[0-9]+$ ]] || [ "$otms" -le 0 ]; then
            echo -ne "\r  ${label}: se initializeaza...                          "; continue
        fi
        local ot=$((otms / 1000000)); [ "$ot" -lt 0 ] && ot=0
        local el=$(( $(date +%s) - st_p )); [ "$el" -le 0 ] && el=1
        local pct=$(( dur_p > 0 ? ot * 100 / dur_p : 0 )); [ "$pct" -gt 100 ] && pct=100
        local rfps; rfps=$(grep "^fps=" "$prog_file" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' ')
        if [[ "$rfps" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk "BEGIN{exit !($rfps > 0)}"; then :
        else [ "$ot" -gt 0 ] && rfps="$(awk "BEGIN{printf \"%.1f\", $ot / $el}")x" || rfps="0.0x"; fi
        local eta=0
        [ "$ot" -gt 0 ] && [ "$dur_p" -gt "$ot" ] && eta=$(( el * (dur_p - ot) / ot ))
        printf "\r  %s: %3d%% | FPS: %s | ETA: %02d:%02d:%02d   " \
            "$label" "$pct" "$rfps" $((eta/3600)) $(((eta%3600)/60)) $((eta%60))
    done
    rm -f "$prog_file"; PROGRESS_FILE=""; echo ""
}


# Watcher paralel pentru run_ffmpeg_with_progress (durata explicită, nu ffprobe)
_show_progress_labeled() {
    local pid=$1 prog_file=$2 total_s=$3 label=$4
    local st_p; st_p=$(date +%s)
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        local otms; otms=$(grep "^out_time_ms=" "$prog_file" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' ')
        if ! [[ "$otms" =~ ^[0-9]+$ ]] || [ "$otms" -le 0 ]; then
            printf "\r  %s: se initializeaza...                              " "$label"
            continue
        fi
        local ot=$((otms / 1000000)); [ "$ot" -lt 0 ] && ot=0
        local el=$(( $(date +%s) - st_p )); [ "$el" -le 0 ] && el=1
        local pct=0
        (( total_s > 0 )) && pct=$(( ot * 100 / total_s ))
        [ "$pct" -gt 100 ] && pct=100
        local rfps; rfps=$(grep "^fps=" "$prog_file" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' ')
        if [[ "$rfps" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk "BEGIN{exit !($rfps > 0)}"; then :
        else [ "$ot" -gt 0 ] && rfps="$(awk "BEGIN{printf \"%.1fx\", $ot / $el}")" || rfps="0.0x"; fi
        local eta=0
        [ "$ot" -gt 0 ] && [ "$total_s" -gt "$ot" ] && eta=$(( el * (total_s - ot) / ot ))
        printf "\r  %s: %3d%% | FPS: %s | ETA: %02d:%02d:%02d       " \
            "$label" "$pct" "$rfps" $((eta/3600)) $(((eta%3600)/60)) $((eta%60))
    done
    echo ""
}

# ══════════════════════════════════════════════════════════════════════
# AUDIO PARAMS
# ══════════════════════════════════════════════════════════════════════

# v67: args de re-encode pentru O pista audio (output index <idx>), FARA prefix
# `-c:a copy` (acela il pune apelantul, o singura data, INAINTE — regula copy-first v66).
# Sursa UNICA pentru scaling bitrate per-canale + downmix (folosit de get_audio_params
# pe pista 0 SI de handle_multi_audio_dialog pe pistele selectate).
#   codec   : aac|opus|flac|eac3|ac3|pcm
#   idx     : index OUTPUT al pistei (poate diferi de input cand exista skip-uri)
#   channels: canalele pistei (din ffprobe pe pista respectiva)
#   base_br : bitrate-ul ales (sau nivel flac / format pcm ex. 16le)
build_track_audio_args() {
    local codec="$1" idx="$2" channels="$3" base_br="$4"
    local br="$base_br" dm=""
    # AV_DOWNMIX_STEREO: forteaza stereo pe ORICE pista re-encodata (>2ch) INAINTE de
    # auto-scale bitrate (channels devine 2 → bitrate-ul ramane cel de baza, stereo).
    if [[ "${AV_DOWNMIX_STEREO:-0}" == "1" ]] && [ "$channels" -gt 2 ]; then
        channels=2; dm=" -ac:a:$idx 2"
    fi
    case "$codec" in
        aac)
            if [[ "$br" == "192k" ]]; then
                [ "$channels" -gt 6 ] && br="768k" || { [ "$channels" -gt 2 ] && br="384k"; }
            fi
            echo "-c:a:$idx aac -b:a:$idx $br$dm" ;;
        opus)
            if [[ "$br" == "128k" ]]; then
                [ "$channels" -gt 6 ] && br="512k" || { [ "$channels" -gt 2 ] && br="256k"; }
            fi
            echo "-c:a:$idx libopus -b:a:$idx $br$dm" ;;
        flac) echo "-c:a:$idx flac -compression_level $br$dm" ;;
        eac3)
            if [[ "$br" == "224k" ]]; then
                [ "$channels" -gt 6 ] && br="1024k" || { [ "$channels" -gt 2 ] && br="640k"; }
            fi
            echo "-c:a:$idx eac3 -b:a:$idx $br$dm" ;;
        ac3)
            # AC3 spec: max 5.1 / 640k. 7.1 → downmix 5.1 (cand nu e deja stereo via $dm).
            [[ "$br" == "224k" ]] && [ "$channels" -gt 2 ] && br="448k"
            if [[ -n "$dm" ]]; then
                echo "-c:a:$idx ac3 -b:a:$idx $br$dm"
            elif [ "$channels" -gt 6 ]; then
                echo "-c:a:$idx ac3 -b:a:$idx $br -ac:a:$idx 6"
            else
                echo "-c:a:$idx ac3 -b:a:$idx $br"
            fi ;;
        pcm) echo "-c:a:$idx pcm_s${br}$dm" ;;
        *)   echo "-c:a:$idx aac -b:a:$idx 192k$dm" ;;
    esac
}

get_audio_params() {
    local file="${1:-}"
    if [[ "$AUDIO_CODEC_ARG" == "copy" ]]; then
        if [[ "$CONTAINER" == "mp4" || "$CONTAINER" == "mov" ]] && [[ -n "$file" ]]; then
            local ac; ac=$(ffprobe -v error -select_streams a -show_entries stream=codec_name \
                -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
            if echo "$ac" | grep -qi "truehd\|dts\b\|dtshd\|dts_hd"; then
                log "  ATENTIE: Audio TrueHD/DTS-HD detectat — incompatibil cu $CONTAINER la copy." >&2
            fi
        fi
        echo "-c:a copy"; return
    fi
    local codec="${AUDIO_CODEC_ARG%%:*}" br="${AUDIO_CODEC_ARG#*:}" channels=2
    if [[ -n "$file" ]]; then
        # v63: default= + head -1 + tr -d '\r' (csv=p=0 single-field putea da trailing comma pe
        # audio cu side_data / 2 linii pe DJI → regex `^[0-9]+$` esua → channels=2 → bitrate gresit)
        local ch_raw; ch_raw=$(ffprobe -v error -select_streams a:0 \
            -show_entries stream=channels -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1 | tr -d '\r')
        [[ "$ch_raw" =~ ^[0-9]+$ ]] && channels=$ch_raw
    fi
    # v53: AV_DOWNMIX_STEREO=1 → force stereo downmix (5.1/7.1 → 2.0). Doar log aici;
    # flag-ul efectiv (`-ac:a:0 2`) + scaling-ul il aplica build_track_audio_args.
    if [[ "${AV_DOWNMIX_STEREO:-0}" == "1" ]] && [ "$channels" -gt 2 ]; then
        log "  AV_DOWNMIX_STEREO=1 → downmix ${channels}ch → 2.0" >&2
    fi
    # v66: log-urile din aceasta functie merg pe stderr (>&2) — stdout-ul e CAPTURAT
    # in AUDIO_PARAMS=$(get_audio_params); `log` (tee) ar polua altfel sirul de params.
    [[ -n "$file" ]] && _warn_audio_metadata "$file" >&2
    # v67: per-codec args delegate la build_track_audio_args (sursa unica scaling/downmix),
    # pe pista 0. CRITIC (v66): `-c:a copy` PRIMUL (toate copy), apoi override pe a:0 —
    # ffmpeg aplica `-c` in ordine, ultimul care prinde streamul castiga; copy ULTIMUL ar
    # suprascrie a:0 → track 0 COPIAT nu re-encodat. NU inversa.
    echo "-c:a copy $(build_track_audio_args "$codec" 0 "$channels" "$br")"
}

_warn_audio_metadata() {
    local file="$1" ac ap
    ac=$(ffprobe -v error -select_streams a -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
    ap=$(ffprobe -v error -select_streams a -show_entries stream=profile \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
    if echo "$ac" | grep -qi "truehd"; then
        log "  ⚠ ATENTIE: Sursa contine TrueHD."
        log "    Metadata Dolby Atmos (obiecte spatiale JOC) se va pierde la re-encode."
    fi
    if echo "$ac" | grep -qi "dts"; then
        if echo "$ap" | grep -qi "DTS-HD MA\|DTS:X"; then
            log "  ⚠ ATENTIE: Sursa contine DTS-HD MA / DTS:X — metadata pierduta la re-encode."
        else
            log "  ⚠ ATENTIE: Sursa contine DTS — metadata pierduta la re-encode."
        fi
    fi
}

# v67: dialog selectie audio per-pista (cand sursa are >1 pista audio si NU e copy total).
# Poate REscrie AUDIO_PARAMS, adauga negative maps in MAP_FLAGS (skip/drop) si seteaza
# AUDIO_LOUDNORM_TRACK (index OUTPUT al primei piste re-encodate, pt loudnorm). NU e
# capturat via $(...) → poate folosi echo/read/log pe terminal direct.
# Default (1 pista / non-interactiv fara AV_AUDIO_TRACKS / optiunea 1): lasa AUDIO_PARAMS
# neschimbat (= track 0 re-encode, restul copy, deja produs de get_audio_params).
# Bypass CI: AV_AUDIO_TRACKS=0 (default) | all | lista "0,2" (piste de ENCODAT; restul copy).
handle_multi_audio_dialog() {
    local file="$1"
    AUDIO_LOUDNORM_TRACK=0          # default: pista 0 (cea re-encodata de get_audio_params)
    AUDIO_PERTRACK_CUSTOM=0         # flag: 1 cand userul a rescris selectia per-pista (informational;
                                    # v68: smart-copy onoreaza per-pista via do_stream_copy 4th arg, nu mai e gardat)
    # v68: indecsi INPUT audio re-encodati (E) / sariti (S) — pt avertismentul de
    # compat container pe pistele COPIATE. Default: track 0 re-encodat, restul copy.
    AUDIO_REENCODED_INPUTS="0"; AUDIO_SKIPPED_INPUTS=""
    [[ "$AUDIO_CODEC_ARG" == "copy" ]] && { AUDIO_REENCODED_INPUTS=""; return 0; }
    local codec="${AUDIO_CODEC_ARG%%:*}" base_br="${AUDIO_CODEC_ARG#*:}"
    # numar piste audio (o linie/index per pista; multi-field csv NU se foloseste aici)
    local ntracks; ntracks=$(ffprobe -v error -select_streams a \
        -show_entries stream=index -of csv=p=0 "$file" 2>/dev/null | grep -c '^[0-9]')
    [[ "$ntracks" =~ ^[0-9]+$ ]] || ntracks=0
    [ "$ntracks" -le 1 ] && return 0

    local -a sel=(); local i
    if [[ -n "${AV_AUDIO_TRACKS:-}" || -n "${AV_AUDIO_DROP:-}" ]]; then
        # non-interactiv: AV_AUDIO_TRACKS = piste de ENCODAT (rest copy); "all"/"0"/"0,2".
        # v68: AV_AUDIO_DROP = piste de SKIP (scoase din output); are prioritate peste E/C.
        for ((i=0;i<ntracks;i++)); do sel[i]="C"; done
        if [[ "${AV_AUDIO_TRACKS,,}" == "all" ]]; then
            for ((i=0;i<ntracks;i++)); do sel[i]="E"; done
        elif [[ -n "${AV_AUDIO_TRACKS:-}" ]]; then
            local t; local -a _tl; IFS=',' read -ra _tl <<< "$AV_AUDIO_TRACKS"
            for t in "${_tl[@]}"; do [[ "$t" =~ ^[0-9]+$ ]] && [ "$t" -lt "$ntracks" ] && sel[t]="E"; done
        else
            sel[0]="E"          # doar AV_AUDIO_DROP setat → default (track 0 encode, rest copy)
        fi
        if [[ -n "${AV_AUDIO_DROP:-}" ]]; then
            local d; local -a _dl; IFS=',' read -ra _dl <<< "$AV_AUDIO_DROP"
            for d in "${_dl[@]}"; do [[ "$d" =~ ^[0-9]+$ ]] && [ "$d" -lt "$ntracks" ] && sel[d]="S"; done
        fi
    elif [[ "${AV_NONINTERACTIVE:-0}" == "1" ]] || [[ ! -t 0 ]]; then
        return 0                    # non-interactiv fara env → default
    else
        # interactiv: lista piste + dialog
        log ""
        echo "  ╔══════════════════════════════════════════════════╗"
        echo "  ║  $ntracks PISTE AUDIO — selectie per-pista          "
        echo "  ╠══════════════════════════════════════════════════╣"
        local atinfo; atinfo=$(ffprobe -v error -select_streams a \
            -show_entries stream=codec_name,channels:stream_tags=language \
            -of csv=p=0 "$file" 2>/dev/null)
        local idx=0 line c_codec c_ch c_lang
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            IFS=',' read -r c_codec c_ch c_lang <<< "$line"
            echo "  ║  a:$idx  ${c_codec:-?}  ${c_ch:-?}ch  ${c_lang:-und}"
            idx=$((idx+1))
        done <<< "$atinfo"
        echo "  ╠══════════════════════════════════════════════════╣"
        echo "  ║  1) Track 0 re-encode, restul copy  [implicit]    "
        echo "  ║  2) Selecteaza per pista (E=encode/C=copy/S=skip) "
        echo "  ╚══════════════════════════════════════════════════╝"
        local mac; read -p "  Alege [implicit: 1]: " mac
        [[ "${mac:-1}" != "2" ]] && return 0
        for ((i=0;i<ntracks;i++)); do
            local def; [ "$i" -eq 0 ] && def="E" || def="C"
            local ch; read -p "  Track $i (E=encode/C=copy/S=skip) [implicit: $def]: " ch
            ch="${ch:-$def}"; ch="${ch^^}"
            case "$ch" in E|C|S) sel[i]="$ch" ;; *) sel[i]="$def" ;; esac
        done
    fi

    # construieste AUDIO_PARAMS + negative skip maps din selectie.
    # Index OUTPUT = index_input - nr_skip-uri_inainte (negative-map compacteaza streamurile).
    local ap="-c:a copy" skipmaps="" skips_before=0 outidx tch first_e=-1 reenc="" skipd=""
    for ((i=0;i<ntracks;i++)); do
        case "${sel[i]:-C}" in
            S) skipmaps+=" -map -0:a:$i"; skips_before=$((skips_before+1)); skipd+=" $i" ;;
            E)
                outidx=$((i - skips_before))
                tch=$(ffprobe -v error -select_streams "a:$i" -show_entries stream=channels \
                    -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1 | tr -d '\r')
                [[ "$tch" =~ ^[0-9]+$ ]] || tch=2
                ap+=" $(build_track_audio_args "$codec" "$outidx" "$tch" "$base_br")"
                [ "$first_e" -lt 0 ] && first_e=$outidx
                reenc+=" $i"
                ;;
            C) : ;;                 # base `-c:a copy` deja le acopera
        esac
    done
    AUDIO_PARAMS="$ap"
    [[ -n "$skipmaps" ]] && MAP_FLAGS="$MAP_FLAGS$skipmaps"
    AUDIO_LOUDNORM_TRACK="$first_e" # -1 daca nicio pista re-encodata → loudnorm skip
    AUDIO_PERTRACK_CUSTOM=1
    AUDIO_REENCODED_INPUTS="${reenc# }"; AUDIO_SKIPPED_INPUTS="${skipd# }"
    log "  Audio per-pista: $AUDIO_PARAMS${skipmaps:+ | skip:$skipmaps}"
    return 0
}

# v68: avertizeaza daca o pista audio COPIATA (nu re-encodata, nu skip) are un codec
# incompatibil cu containerul → la copy ffmpeg ar pierde-o / ar esua. Read-only (doar warn):
# refoloseste `remux_stream_compat` (matricea din av_mux). Pe MKV nimic nu se avertizeaza.
# Foloseste AUDIO_REENCODED_INPUTS / AUDIO_SKIPPED_INPUTS (indecsi INPUT, din dialog).
warn_incompat_audio_copies() {
    local file="$1" container="${2:-$CONTAINER}"
    [[ "${container,,}" == "mkv" ]] && return 0   # MKV accepta orice audio la copy
    # v68: arg 3/4 optionale = set-uri INPUT re-encodate / skip (explicit, pt fluxuri
    # all-track ca trim/concat/burnin: pasezi "" = tot audio copiat). Default = globalele
    # din encode flow (AUDIO_REENCODED_INPUTS/AUDIO_SKIPPED_INPUTS).
    local reenc=" ${3-${AUDIO_REENCODED_INPUTS:-0}} " skipd=" ${4-${AUDIO_SKIPPED_INPUTS:-}} "
    local info; info=$(ffprobe -v error -select_streams a \
        -show_entries stream=codec_name -of csv=p=0 "$file" 2>/dev/null)
    local i=0 acodec verdict
    while IFS= read -r acodec; do
        acodec="${acodec%%,*}"; acodec="$(echo "$acodec" | tr -d '\r')"
        [[ -z "$acodec" ]] && continue
        # sarit daca pista i e re-encodata sau skip (nu se copiaza)
        if [[ "$reenc" != *" $i "* ]] && [[ "$skipd" != *" $i "* ]]; then
            verdict=$(remux_stream_compat "$acodec" audio "$container")
            if [[ "$verdict" != "copy" ]]; then
                log "  ⚠ ATENTIE: pista a:$i ($acodec) e incompatibila cu containerul .$container la copy —"
                log "    ffmpeg o va pierde sau va esua. Solutii: foloseste container MKV, sau re-encodeaza"
                log "    pista (in dialogul per-pista alege E pentru ea, ori AV_AUDIO_TRACKS)."
            fi
        fi
        i=$((i+1))
    done <<< "$info"
    return 0
}

# ══════════════════════════════════════════════════════════════════════
# v44: CODEC-AWARE TOOL DISPATCHERS
# Selecteaza binarul corect (HEVC: quietvoid; AV1: sven-pke fork) pentru
# extragere/injectare RPU Dolby Vision si metadata HDR10+ in functie de
# codec-ul tinta. Binarele AV1 sunt instalate cu rename (av1dovi_tool /
# av1hdr10plus_tool) pentru a nu intra in coliziune cu cele HEVC.
# ══════════════════════════════════════════════════════════════════════

# Returneaza codec-ul stream-ului video (hevc / av1 / h264 / ...).
# Folosit pentru a alege binarul corect cand procesam metadata DV/HDR10+.
# v57 FIX: csv=p=0 emite trailing virgula chiar la single-field queries
# in ffprobe 8.x (`av1,\n` in loc de `av1\n`) → callerii primeau codec
# "av1," si gate-urile `[[ "$codec" == "av1" ]]` esuau silentios cu mesaje
# de tipul "Codec sursa 'av1,' nu suporta DV transform". Switch la
# default=noprint_wrappers=1:nokey=1 (valoarea curata, fara separator).
detect_source_codec() {
    local file="$1"
    [[ -z "$file" || ! -f "$file" ]] && { echo ""; return 1; }
    # v61 audit: head -1 — DJI Action 6 raporteaza stream v:0 de 2 ori (`-select_streams
    # v:0` → "hevc\nhevc"); fara head -1 case/== exacte esueaza. Paritate cu restul
    # citirilor single-field v:0 din av_common.sh + Get-SourceCodec PS1.
    ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1
}

# tool_for_extract <codec> <kind>
# kind: "dovi" | "hdr10plus"
# codec: "av1" -> sven-pke fork; orice altceva -> quietvoid (HEVC default)
tool_for_extract() {
    local codec="${1:-hevc}" kind="${2:-dovi}"
    case "$codec" in
        av1)
            case "$kind" in
                dovi)      echo "$AV_TOOL_AV1DOVI" ;;
                hdr10plus) echo "$AV_TOOL_AV1HDR10PLUS" ;;
                *)         echo ""; return 1 ;;
            esac
            ;;
        *)
            case "$kind" in
                dovi)      echo "$AV_TOOL_DOVI" ;;
                hdr10plus) echo "$AV_TOOL_HDR10PLUS" ;;
                *)         echo ""; return 1 ;;
            esac
            ;;
    esac
}

# Acelasi dispatch pentru injectare (decuplat de extract pentru future-proofing
# in cazul in care apar tool-uri specializate pe directie).
tool_for_inject() { tool_for_extract "$@"; }

# Cache disponibilitate binare AV1 (sven-pke fork)
AV1_DOVI_TOOL_AVAILABLE=""
AV1_HDR10PLUS_TOOL_AVAILABLE=""
SVTAV1_HDR10PLUS_CAPS=""

# Verifica daca SvtAv1EncApp / libsvtav1 din ffmpeg suporta `hdr10plus-json=`
# in svtav1-params (introdus in SVT-AV1 v1.5+). Cache-eaza rezultatul.
# Returneaza: 0=suport, 1=fara suport.
_check_svtav1_hdr10plus_caps() {
    if [[ -z "$SVTAV1_HDR10PLUS_CAPS" ]]; then
        local out=""
        if command -v "$AV_TOOL_SVTAV1ENCAPP" &>/dev/null; then
            out=$("$AV_TOOL_SVTAV1ENCAPP" --help 2>&1; "$AV_TOOL_SVTAV1ENCAPP" --enc-mode help 2>&1)
        fi
        # Fallback: ffmpeg -h encoder=libsvtav1 (afiseaza optiuni cunoscute)
        if [[ -z "$out" ]] || ! echo "$out" | grep -qi "hdr10plus"; then
            out=$(ffmpeg -hide_banner -h encoder=libsvtav1 2>&1)
        fi
        if echo "$out" | grep -qi "hdr10plus"; then
            SVTAV1_HDR10PLUS_CAPS=1
        else
            SVTAV1_HDR10PLUS_CAPS=0
        fi
    fi
    [[ "$SVTAV1_HDR10PLUS_CAPS" == "1" ]]
}

_check_av1_dovi_tool() {
    if [[ -z "$AV1_DOVI_TOOL_AVAILABLE" ]]; then
        if command -v "$AV_TOOL_AV1DOVI" &>/dev/null; then
            AV1_DOVI_TOOL_AVAILABLE=1
        else
            AV1_DOVI_TOOL_AVAILABLE=0
        fi
    fi
    [[ "$AV1_DOVI_TOOL_AVAILABLE" == "1" ]]
}

_check_av1_hdr10plus_tool() {
    if [[ -z "$AV1_HDR10PLUS_TOOL_AVAILABLE" ]]; then
        if command -v "$AV_TOOL_AV1HDR10PLUS" &>/dev/null; then
            AV1_HDR10PLUS_TOOL_AVAILABLE=1
        else
            AV1_HDR10PLUS_TOOL_AVAILABLE=0
        fi
    fi
    [[ "$AV1_HDR10PLUS_TOOL_AVAILABLE" == "1" ]]
}

# Wrapper unificat — verifica binarul potrivit pentru codec-ul cerut.
# Usage: _check_dovi_tool_for hevc | _check_dovi_tool_for av1
_check_dovi_tool_for() {
    case "${1:-hevc}" in
        av1) _check_av1_dovi_tool ;;
        *)   _check_dovi_tool ;;
    esac
}

_check_hdr10plus_tool_for() {
    case "${1:-hevc}" in
        av1) _check_av1_hdr10plus_tool ;;
        apv) _apv_hdr10plus_engine_py >/dev/null 2>&1 ;;   # v69: engine propriu
        *)   _check_hdr10plus_tool ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════
# HDR10+ METADATA EXTRACTION (pentru re-encode cu pastrare metadata)
# Necesita: hdr10plus_tool (HEVC) / av1hdr10plus_tool (AV1, sven-pke fork)
# ══════════════════════════════════════════════════════════════════════
HDR10PLUS_TOOL_AVAILABLE=""

_check_hdr10plus_tool() {
    if [[ -z "$HDR10PLUS_TOOL_AVAILABLE" ]]; then
        if command -v "$AV_TOOL_HDR10PLUS" &>/dev/null; then
            HDR10PLUS_TOOL_AVAILABLE=1
        else
            HDR10PLUS_TOOL_AVAILABLE=0
        fi
    fi
    [[ "$HDR10PLUS_TOOL_AVAILABLE" == "1" ]]
}

# Extrage metadata HDR10+ dintr-un fisier video intr-un JSON temporar.
# v44: foloseste tool_for_extract pentru a alege binarul corect (HEVC vs AV1).
# Return: calea JSON pe stdout, cod 0=OK, 1=esuat
extract_hdr10plus_metadata() {
    local file="$1"
    local json_file src_codec hp_tool
    json_file=$(av_mktemp_ext json)
    # Detectam codec-ul sursa pentru a alege bitstream filter-ul corect + tool
    src_codec=$(detect_source_codec "$file")
    # v69: sursa APV → engine propriu (hdr10plus_tool/av1hdr10plus_tool nu cunosc APV)
    if [[ "$src_codec" == "apv" ]]; then
        echo "  HDR10+: Extrag metadata dinamica (codec=apv, engine=${AV_ENGINE_APV_HDR10PLUS##*/})..." | tee -a "${LOG_FILE:-/dev/null}" >&2
        local _apv_json
        if _apv_json=$(_apv_hdr10plus_extract "$file"); then
            local _apv_count
            _apv_count=$(grep -o '"SequenceFrameIndex"' "$_apv_json" 2>/dev/null | wc -l | tr -d '[:space:]')
            echo "  HDR10+: Metadata extrasa ($_apv_count scene descriptors)" | tee -a "${LOG_FILE:-/dev/null}" >&2
            rm -f "$json_file"
            echo "$_apv_json"
            return 0
        fi
        echo "  HDR10+: Extractie esuata — fallback la HDR10 static" | tee -a "${LOG_FILE:-/dev/null}" >&2
        rm -f "$json_file"
        return 1
    fi
    hp_tool=$(tool_for_extract "$src_codec" hdr10plus)
    # Log pe stderr (nu stdout) — stdout e rezervat pentru calea JSON
    echo "  HDR10+: Extrag metadata dinamica (codec=$src_codec, tool=$hp_tool)..." | tee -a "${LOG_FILE:-/dev/null}" >&2
    # v55 audit: fisier intermediar (NU pipe ffmpeg|tool). Pipe-ul binar e fragil
    # cross-platform — PowerShell il intermediaza ca text (corupe), git-bash MINGW
    # il corupe, sven-pke av1hdr10plus_tool da panic pe stdin. Consistent cu extract_dv_rpu.
    local _raw_tmp _raw_rc=0
    if [[ "$src_codec" == "av1" ]]; then
        _raw_tmp=$(av_mktemp_ext ivf)
        ffmpeg -y -v error -i "$file" -c:v copy -f ivf "$_raw_tmp" 2>/dev/null || _raw_rc=$?
    else
        _raw_tmp=$(av_mktemp_ext hevc)
        ffmpeg -y -v error -i "$file" -c:v copy -bsf:v hevc_mp4toannexb -f hevc "$_raw_tmp" 2>/dev/null || _raw_rc=$?
    fi
    if [ "$_raw_rc" -eq 0 ] && [ -s "$_raw_tmp" ]; then
        "$hp_tool" extract -i "$_raw_tmp" -o "$json_file" >/dev/null 2>&1
    fi
    rm -f "$_raw_tmp"
    if [ -s "$json_file" ]; then
        local count
        count=$(grep -c '"BezierCurveData"\|"TargetedSystemDisplayMaximumLuminance"' "$json_file" 2>/dev/null)
        echo "  HDR10+: Metadata extrasa ($count scene descriptors)" | tee -a "${LOG_FILE:-/dev/null}" >&2
        echo "$json_file"
        return 0
    else
        echo "  HDR10+: Extractie esuata — fallback la HDR10 static" | tee -a "${LOG_FILE:-/dev/null}" >&2
        rm -f "$json_file"
        return 1
    fi
}

# Dialog HDR10+ per fisier — oferit cand sursa are HDR10+.
# v44: param 2 optional = target_codec (hevc default | av1) — controleaza
# disponibilitatea triple-layer (av1dovi_tool vs dovi_tool) si target-ul RPU.
# v45: gate-ul verifica source-codec tool pt extract (intern in dialog) si
# target-codec tool pt triple-layer inject — corecteaza cross-codec scenarios.
# Return: 0=re-encode cu metadata, 1=re-encode HDR10 static, 98=stream copy
# Seteaza: HDR10PLUS_JSON, DOVI_RPU_FILE, TRIPLE_LAYER_MODE, TRIPLE_LAYER_TARGET_CODEC
handle_hdr10plus_dialog() {
    local file="$1"
    local target_codec="${2:-hevc}"
    local src_codec
    src_codec=$(detect_source_codec "$file")

    # v45: daca DV preserve a setat deja state-ul (extras RPU real din sursa),
    # nu deschide dialog-ul — ar putea oferi opt 4 triple-layer care
    # OVERWRITES DOVI_RPU_FILE cu un RPU sintetizat din HDR10+ JSON.
    # In schimb, auto-extract HDR10+ JSON pentru inline injection (dhdr10-info)
    # langa DV RPU real → triple-layer (DV+HDR10+HDR10+) cu DV-ul corect.
    if [[ "${TRIPLE_LAYER_MODE:-0}" == "1" ]] && [[ -n "${DOVI_RPU_FILE:-}" ]]; then
        log "  HDR10+ + DV preserve: auto-pastrez HDR10+ inline (DV RPU real deja extras)"
        if _check_hdr10plus_tool_for "$src_codec"; then
            HDR10PLUS_JSON=$(extract_hdr10plus_metadata "$file")
            if [[ -n "$HDR10PLUS_JSON" ]]; then
                log "  HDR10+: Metadata pregatita pentru injectare (dhdr10-info)"
                return 0
            else
                log "  HDR10+: Extract esuat — encode ca HDR10 static (DV RPU pastrat)"
                return 1
            fi
        else
            local _need_hp="$AV_TOOL_HDR10PLUS"; [[ "$src_codec" == "av1" ]] && _need_hp="$AV_TOOL_AV1HDR10PLUS"
            log "  HDR10+: $_need_hp indisponibil — encode HDR10 static (DV RPU pastrat)"
            return 1
        fi
    fi

    HDR10PLUS_JSON=""
    TRIPLE_LAYER_TARGET_CODEC="$target_codec"
    echo ""
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║  HDR10+ DETECTAT                              ║"
    echo "  ╠══════════════════════════════════════════════╣"
    # v45: extract are nevoie de source-codec tool, nu target-codec tool
    if _check_hdr10plus_tool_for "$src_codec"; then
        local triple_label
        case "$target_codec" in
            av1) triple_label="DV P10 + HDR10 + HDR10+ (AV1)" ;;
            *)   triple_label="DV 8.1 + HDR10 + HDR10+ (HEVC)" ;;
        esac
        echo "  ║  1) Re-encode HDR10 static (pierde +)        ║"
        echo "  ║  2) Re-encode HDR10+ (pastreaza metadata)    ║"
        echo "  ║     → extrage JSON (codec=$target_codec tool)"
        echo "  ║  3) Stream copy video (pastreaza tot, rapid) ║"
        if _check_dovi_tool_for "$target_codec"; then
            echo "  ║  4) Triple-layer (Hibrid 8.1)                ║"
            echo "  ║     → $triple_label"
        else
            echo "  ╠══════════════════════════════════════════════╣"
            local _need_tool="$AV_TOOL_DOVI"
            local _hint="dovi_parser.sh"
            if [[ "$target_codec" == "av1" ]]; then
                _need_tool="$AV_TOOL_AV1DOVI"; _hint="av1dovi_parser.sh"
            fi
            echo "  ║  $_need_tool NU este instalat.            "
            echo "  ║  Fara el, Triple-layer NU este disponibil.   ║"
            echo "  ║  Instaleaza cu: $TOOLS_DIR/$_hint"
        fi
        echo "  ╚══════════════════════════════════════════════╝"
        local max_opt=3
        _check_dovi_tool_for "$target_codec" && max_opt=4
        read -p "  Alege 1-$max_opt [implicit: 2]: " hdr10p_choice
        case "${hdr10p_choice:-2}" in
            1) log "  HDR10+: Re-encode ca HDR10 static (fara metadata dinamica)"
               return 1 ;;
            3) log "  HDR10+: Stream copy (video pastrat integral)"
               return 98 ;;
            4)
                if _check_dovi_tool_for "$target_codec"; then
                    HDR10PLUS_JSON=$(extract_hdr10plus_metadata "$file")
                    if [[ -n "$HDR10PLUS_JSON" ]]; then
                        DOVI_RPU_FILE=$(generate_dv_rpu_from_hdr10plus "$HDR10PLUS_JSON" "$target_codec" "$file")
                        if [[ -n "$DOVI_RPU_FILE" ]]; then
                            log "  Triple-layer ($target_codec): HDR10+ JSON + DV RPU pregatite"
                            TRIPLE_LAYER_MODE=1
                            return 0
                        else
                            log "  Triple-layer: generare RPU esuata — fallback la HDR10+"
                            TRIPLE_LAYER_MODE=0
                            return 0
                        fi
                    else
                        log "  Triple-layer: extractie HDR10+ esuata — fallback la HDR10 static"
                        TRIPLE_LAYER_MODE=0
                        return 1
                    fi
                fi
                ;& # fallthrough to default
            *)
                HDR10PLUS_JSON=$(extract_hdr10plus_metadata "$file")
                if [[ -n "$HDR10PLUS_JSON" ]]; then
                    log "  HDR10+: Metadata pregatita pentru injectare"
                    TRIPLE_LAYER_MODE=0
                    return 0
                else
                    log "  HDR10+: Extractie esuata — re-encode ca HDR10 static"
                    TRIPLE_LAYER_MODE=0
                    return 1
                fi ;;
        esac
    else
        # v45: tool-ul lipsa e pt source-codec (extract), nu target-codec
        local _need_hp="$AV_TOOL_HDR10PLUS"
        local _hint_hp="hdr10plus_parser.sh"
        if [[ "$src_codec" == "av1" ]]; then
            _need_hp="$AV_TOOL_AV1HDR10PLUS"; _hint_hp="av1hdr10plus_parser.sh"
        fi
        echo "  ║  $_need_hp NU este instalat (necesar pt sursa $src_codec)"
        echo "  ║  Fara el, metadata dinamica se pierde.       ║"
        echo "  ║  Instaleaza cu: $TOOLS_DIR/$_hint_hp"
        echo "  ╠══════════════════════════════════════════════╣"
        echo "  ║  1) Re-encode HDR10 static (pierde +)        ║"
        echo "  ║  2) Stream copy video (pastreaza tot, rapid) ║"
        echo "  ╚══════════════════════════════════════════════╝"
        read -p "  Alege 1 sau 2 [implicit: 1]: " hdr10p_choice
        case "${hdr10p_choice:-1}" in
            2) log "  HDR10+: Stream copy"; return 98 ;;
            *) log "  HDR10+: Re-encode HDR10 static"; return 1 ;;
        esac
    fi
}

# ══════════════════════════════════════════════════════════════════════
# DOLBY VISION TRIPLE-LAYER (DV Profile 8.1 + HDR10 + HDR10+)
# Necesita: dovi_tool (quietvoid/dovi_tool) + hdr10plus_tool
# Pipeline: extract HDR10+ → generate DV RPU → encode x265 → inject RPU
# ══════════════════════════════════════════════════════════════════════
DOVI_TOOL_AVAILABLE=""

_check_dovi_tool() {
    if [[ -z "$DOVI_TOOL_AVAILABLE" ]]; then
        if command -v "$AV_TOOL_DOVI" &>/dev/null; then
            DOVI_TOOL_AVAILABLE=1
        else
            DOVI_TOOL_AVAILABLE=0
        fi
    fi
    [[ "$DOVI_TOOL_AVAILABLE" == "1" ]]
}

# Genereaza DV RPU din HDR10+ JSON metadata.
# $1 = HDR10+ JSON path, $2 = target_codec ("hevc" default, "av1" pt sven-pke fork)
# Return: RPU bin path pe stdout, 0=OK, 1=fail
# Note: RPU-ul e profile-agnostic (acelasi schema pt 8.1 si 10); diferenta e in
#       binarul de generate (sven-pke fork e necesar pt AV1) si in injectie.
generate_dv_rpu_from_hdr10plus() {
    local hdr10plus_json="$1"
    local target_codec="${2:-hevc}"
    local source_file="${3:-}"
    local dovi_bin
    dovi_bin=$(tool_for_extract "$target_codec" dovi)
    local rpu_file
    rpu_file=$(av_mktemp_ext bin)

    # v55: L6 (mastering display + light level) din metadata HDR10 reala a sursei
    # cand source_file e dat; altfel BT.2020 1000-nit defaults. Evita DV sintetizat
    # generic cand sursa semnaleaza alt master display / MaxCLL.
    # Note: max_display in cd/m2 (integer); min_display in unitati 0.0001 cd/m2;
    #       max_content/max_average = MaxCLL/MaxFALL.
    local l6_maxdisp=1000 l6_mindisp=1 l6_maxcll=1000 l6_maxfall=400
    local l6_src="default-1000nit"
    if [[ -n "$source_file" ]] && [[ -f "$source_file" ]]; then
        hdr10_static_resolve "$source_file"
        local md="${HDR10_MASTER_DISPLAY_SVTAV1:-}"
        if [[ "$md" == *"L("* ]]; then
            local lpart="${md##*L(}"; lpart="${lpart%)}"
            local max_nits="${lpart%%,*}" min_nits="${lpart##*,}"
            [[ -n "$max_nits" ]] && l6_maxdisp=$(LC_ALL=C awk "BEGIN{printf \"%d\", $max_nits + 0.5}")
            [[ -n "$min_nits" ]] && l6_mindisp=$(LC_ALL=C awk "BEGIN{printf \"%d\", $min_nits * 10000 + 0.5}")
        fi
        if [[ "${HDR10_MAX_CLL:-}" == *","* ]]; then
            l6_maxcll="${HDR10_MAX_CLL%%,*}"
            l6_maxfall="${HDR10_MAX_CLL##*,}"
        fi
        l6_src="${HDR10_STATIC_SOURCE:-probe}"
    fi

    # Config JSON pentru Profile 8.1 CMv4.0 (L6 derivat din sursa cand exista)
    local config_file
    config_file=$(av_mktemp_ext json)
    cat > "$config_file" << DVCONF
{
    "cm_version": "V40",
    "length": 1,
    "level5": {
        "active_area_left_offset": 0,
        "active_area_right_offset": 0,
        "active_area_top_offset": 0,
        "active_area_bottom_offset": 0
    },
    "level6": {
        "max_display_mastering_luminance": $l6_maxdisp,
        "min_display_mastering_luminance": $l6_mindisp,
        "max_content_light_level": $l6_maxcll,
        "max_frame_average_light_level": $l6_maxfall
    }
}
DVCONF

    echo "  DV: Generez RPU din HDR10+ metadata (codec=$target_codec, tool=$dovi_bin, L6=$l6_src ${l6_maxdisp}/${l6_mindisp}/${l6_maxcll}/${l6_maxfall})..." | tee -a "${LOG_FILE:-/dev/null}" >&2
    "$dovi_bin" generate -j "$config_file" \
        --hdr10plus-json "$hdr10plus_json" \
        -o "$rpu_file" >/dev/null 2>&1
    local gen_rc=$?

    rm -f "$config_file"

    if [ $gen_rc -eq 0 ] && [ -s "$rpu_file" ]; then
        local prof_label
        case "$target_codec" in
            av1) prof_label="Profile 10 (AV1)" ;;
            *)   prof_label="Profile 8.1 (HEVC)" ;;
        esac
        echo "  DV: RPU generat cu succes ($prof_label)" | tee -a "${LOG_FILE:-/dev/null}" >&2
        echo "$rpu_file"
        return 0
    else
        echo "  DV: Generare RPU esuata" | tee -a "${LOG_FILE:-/dev/null}" >&2
        rm -f "$rpu_file"
        return 1
    fi
}

# Injecteaza DV RPU intr-un fisier HEVC sau AV1 encodat.
# $1 = stream file (HEVC sau AV1), $2 = RPU bin, $3 = output file
# $4 = target_codec ("hevc" default, "av1" pt sven-pke fork)
# Detecteaza un interpretor Python 3 (python3 preferat, fallback python 3.x).
# Echo numele binarului; return 1 daca niciunul.
_av_python() {
    if command -v python3 >/dev/null 2>&1; then echo "python3"; return 0; fi
    if command -v python >/dev/null 2>&1 && python --version 2>&1 | grep -q "Python 3"; then
        echo "python"; return 0
    fi
    return 1
}

# v62 Faza B: detecteaza D-Log M pe DJI Osmo Action 6 (AC006) din track-ul djmd.
# Container-ul raporteaza bt709 identic pt Normal SI D-Log M → singura cale e
# protobuf-ul djmd (path .2.4.1==19). Engine partajat src/dji_djmd_dlogm.py
# (model-gate intern pe dvtm_ac206.proto). Echo: dlog_m | normal | unknown.
# Soft-fail (python/engine/ffmpeg lipsa, fara track djmd) → unknown.
_detect_dji_dlogm() {
    local file="$1"
    local engine="$SCRIPT_DIR/dji_djmd_dlogm.py"
    [[ -f "$engine" ]] || { echo "unknown"; return 0; }
    local py; py=$(_av_python) || { echo "unknown"; return 0; }
    # index track djmd (prima potrivire — DJI listeaza uneori stream-uri dublu)
    local djmd_idx
    djmd_idx=$(ffprobe -v error -show_entries stream=index,codec_tag_string \
        -of csv=p=0 "$file" 2>/dev/null | awk -F, '$2=="djmd"{print $1; exit}')
    [[ -n "$djmd_idx" ]] || { echo "unknown"; return 0; }
    local dump; dump=$(av_mktemp_ext djmd)
    if ffmpeg -v error -y -i "$file" -map 0:"$djmd_idx" -c copy -f data "$dump" 2>/dev/null && [[ -s "$dump" ]]; then
        local mode; mode=$("$py" "$engine" "$dump" 2>/dev/null)
        rm -f "$dump"
        case "$mode" in dlog_m|normal) echo "$mode" ;; *) echo "unknown" ;; esac
        return 0
    fi
    rm -f "$dump"
    echo "unknown"
}

# ══════════════════════════════════════════════════════════════════════
# v78: pastrarea metadata-ului nativ DJI (djmd GPS) prin GRAFT MP4Box.
# Pistele de date proprietare DJI (djmd=telemetrie GPS, dbgi=debug; codec_type=data,
# codec=none) NU pot fi re-muxate de ffmpeg ("Could not find tag for codec none") →
# la orice encode/remux ffmpeg se pierd TACUT. Grefam DOAR djmd (GPS); dbgi (debug, poate
# fi mare) se omite — suita il trateaza ca drop-by-default. MP4Box (GPAC) le poate GREFA pe un
# output ISO (MP4/MOV): importa output-ul intreg (video+audio+tmcd, cu colr/HDR/dvcC
# intacte — validat empiric) + adauga pistele de date din original dupa track ID ISO.
# Validat pe DJI Action 6: djmd 16473 sample → 16473 (byte-identic) + HDR10+ side_data
# pastrat la `-add`. tmcd NU se grefeaza (muxer-ul mov il recreeaza pe encode → ar
# duplica); cover-ul mjpeg ramane dropat. MKV n-are primitiva de pista timed-data →
# DOAR MP4/MOV (pe MKV telemetria se pastreaza ca SRT/CSV embed, v47).
# ══════════════════════════════════════════════════════════════════════

# Echo: ID-ul ISO (decimal) al pistei djmd (GPS nativ DJI) din $1. djmd = telemetria GPS;
# dbgi (debug, poate fi mare) NU se grefeaza — suita il trateaza ca drop-by-default si
# pe calea de encode ar umfla output-ul; GPS-ul real e DOAR in djmd.
# Parsing robust pe blocuri [STREAM] — ffprobe csv REORDONEAZA campurile (nu respecta
# ordinea din -show_entries), deci pereche id↔tag in interiorul blocului, order-independent.
# CRLF stripuit (ffprobe.exe pe Windows); hex 0xN → decimal prin $(( )).
_dji_native_meta_ids() {
    local file="$1"
    ffprobe -v error -select_streams d -show_entries stream=id,codec_tag_string "$file" 2>/dev/null \
      | awk -F= '
          {gsub(/\r/,"")}
          /^id=/{id=$2}
          /^codec_tag_string=/{tag=$2}
          /\[\/STREAM\]/{ if(tag=="djmd") print id; id="";tag="" }' \
      | while IFS= read -r _h; do [[ -n "$_h" ]] && printf '%s ' "$(( _h ))"; done
}

# Return 0 daca sursa are pista djmd (telemetria GPS DJI) — gate pt graft (A si B).
_dji_has_native_meta() {
    local file="$1"
    ffprobe -v error -select_streams d -show_entries stream=codec_tag_string \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | grep -qi 'djmd'
}

# Grefeaza pista djmd (GPS nativ) din $original in $output (IN-PLACE via temp). Folosit de:
#  A) telemetrie strip "pastreaza GPS nativ" (base = stream-copy fara cover)
#  B) flux encode (base = output-ul encodat) — DJI MP4/MOV → encode → re-graft GPS.
# Gate: MP4Box prezent + output MP4/MOV + djmd in original. Soft: indisponibil/incompat/
# esec → return 1, $output NEATINS (apelantul pastreaza output-ul fara metadata + avertizeaza).
# NB: nume FARA literalul "mp4box" (santinela no_hardcoded_tools); unealta via $AV_TOOL_MP4BOX.
#   $1 = original (sursa cu djmd)   $2 = output (deja construit; grefat in-place)
_dji_graft_native_meta() {
    local original="$1" output="$2"
    command -v "$AV_TOOL_MP4BOX" >/dev/null 2>&1 || return 1
    local _oext="${output##*.}"; _oext="${_oext,,}"
    case "$_oext" in mp4|mov|m4v|qt) : ;; *) return 1 ;; esac
    _dji_has_native_meta "$original" || return 1
    local _ids; _ids=$(_dji_native_meta_ids "$original")
    [[ -n "${_ids// /}" ]] || return 1
    local tmp; tmp=$(av_mktemp_ext "$_oext")
    local -a add_args=("-add" "$output")
    local _id
    for _id in $_ids; do add_args+=("-add" "${original}#${_id}"); done
    if "$AV_TOOL_MP4BOX" "${add_args[@]}" -new "$tmp" >/dev/null 2>&1 && [ -s "$tmp" ]; then
        mv -f "$tmp" "$output"
        return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
    return 1
}

# v78: hook post-encode (run_encode_loop) — re-grefeaza GPS-ul nativ DJI (djmd) pe
# output-ul encodat MP4/MOV. ffmpeg pierde pistele de date proprietare la encode → le
# re-adaugam din sursa cu MP4Box. Policy DJI_PRESERVE_META (env/profil): auto (default;
# prompt interactiv, ON non-interactiv = "do no harm") | on (mereu) | off (niciodata).
# Gate intern: sursa cu djmd + output ISO. NU se captureaza via $(...) (foloseste read/log).
#   $1 = sursa (cu djmd)   $2 = output encodat
_dji_preserve_meta_postencode() {
    local source="$1" output="$2"
    local policy="${DJI_PRESERVE_META:-auto}"
    [[ "$policy" == "off" ]] && return 0
    local _ot="${output##*.}"; _ot="${_ot,,}"
    case "$_ot" in mp4|mov|m4v|qt) : ;; *) return 0 ;; esac
    _dji_has_native_meta "$source" || return 0
    local _do=0
    case "$policy" in
        on) _do=1 ;;
        *)  # auto: prompt interactiv; non-interactiv → pastreaza (alegerea sigura)
            if [[ "${AV_NONINTERACTIVE:-0}" == "1" ]] || [[ ! -t 0 ]]; then
                _do=1
            else
                echo "  Sursă DJI cu GPS nativ (djmd). Re-grefez telemetria GPS în output?"
                local _ans; read -p "  1) Da (recomandat)  2) Nu  [implicit: 1]: " _ans
                [[ "${_ans:-1}" != "2" ]] && _do=1
            fi
            ;;
    esac
    [[ "$_do" == "1" ]] || return 0
    if _dji_graft_native_meta "$source" "$output"; then
        log "  GPS nativ DJI (djmd) re-grefat in output"
    else
        log "  [Notă] GPS nativ DJI nu a putut fi re-grefat (MP4Box lipseste) — telemetria s-a"
        log "         pierdut la encode; alternativa: meniul Telemetrie opt 7 (embed) sau MP4Box."
    fi
    return 0
}

# ══════════════════════════════════════════════════════════════════════
# v69: APV HDR10+ — inject/extract T.35 (ST 2094-40) via engine partajat
# src/apv_hdr10plus.py. APV (RFC 9924) suporta nativ metadata ITU-T T.35
# (PBU type 66, payload type 4), dar ffmpeg nu o scrie (liboapv nu emite
# metadata PBU) si nu o expune (decoderul nativ ignora T.35) → engine-ul
# opereaza pe bitstream-ul brut (`ffmpeg -c copy -f apv`).
# ══════════════════════════════════════════════════════════════════════

# Echo calea python daca python3 + engine-ul exista; rc=1 altfel (soft-fail).
_apv_hdr10plus_engine_py() {
    [[ -f "$AV_ENGINE_APV_HDR10PLUS" ]] || return 1
    _av_python
}

# Probe usor (detect_source_info / av_check): demux primele 3 AU-uri →
# engine probe. Echo: hdr10plus | none. Soft-fail → none.
_apv_hdr10plus_probe() {
    local file="$1" py raw out=""
    py=$(_apv_hdr10plus_engine_py) || { echo "none"; return 0; }
    raw=$(av_mktemp_ext apv)
    if ffmpeg -y -v error -i "$file" -map 0:v:0 -c:v copy -frames:v 3 -f apv "$raw" 2>/dev/null && [[ -s "$raw" ]]; then
        out=$("$py" "$AV_ENGINE_APV_HDR10PLUS" probe -i "$raw" 2>/dev/null)
    fi
    rm -f "$raw"
    case "$out" in hdr10plus*) echo "hdr10plus" ;; *) echo "none" ;; esac
}

# Extract JSON HDR10+ dintr-o sursa APV (orice container) → cale JSON pe stdout.
_apv_hdr10plus_extract() {
    local file="$1" py raw json_file
    py=$(_apv_hdr10plus_engine_py) || return 1
    raw=$(av_mktemp_ext apv); json_file=$(av_mktemp_ext json)
    if ffmpeg -y -v error -i "$file" -map 0:v:0 -c:v copy -f apv "$raw" 2>/dev/null && [[ -s "$raw" ]]; then
        if "$py" "$AV_ENGINE_APV_HDR10PLUS" extract -i "$raw" -o "$json_file" 2>>"${LOG_FILE:-/dev/null}" && [[ -s "$json_file" ]]; then
            rm -f "$raw"
            echo "$json_file"
            return 0
        fi
    fi
    rm -f "$raw" "$json_file"
    return 1
}

# Post-encode: injecteaza HDR10+ (T.35 per frame) + MDCV/CLL static in
# output-ul APV, in-place. Demux raw → engine inject → re-mux video +
# audio/subs/attach din output. -framerate EXPLICIT la re-mux: raw APV nu
# poarta timing → fara el demuxerul presupune un default gresit (validat).
# rc=0 doar cu verificare probe post-remux reusita.
_apv_hdr10plus_inject_output() {
    local output="$1" json="$2" src_file="$3"
    local py raw injected final fps cont_flags
    py=$(_apv_hdr10plus_engine_py) || {
        log "  APV HDR10+: ⚠ python3/engine indisponibil — output ramane HDR10 static"
        return 1
    }
    log "  APV HDR10+: Injectez metadata dinamica T.35 in bitstream..."
    fps=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate \
        -of default=noprint_wrappers=1:nokey=1 "$output" 2>/dev/null | head -1 | tr -d '\r')
    [[ -z "$fps" || "$fps" == "0/0" ]] && fps=30
    raw=$(av_mktemp_ext apv)
    local _dmx_rc=0
    ffmpeg -y -v error -i "$output" -map 0:v:0 -c:v copy -f apv "$raw" 2>>"${LOG_FILE:-/dev/null}" || _dmx_rc=$?
    if [ "$_dmx_rc" -ne 0 ] || [[ ! -s "$raw" ]]; then
        log "  APV HDR10+: ⚠ demux raw esuat — output ramane HDR10 static"
        rm -f "$raw"; return 1
    fi
    # MDCV/CLL statice din sursa (bonus: ffprobe le vede direct din bitstream —
    # decoderul nativ apv CITESTE MDCV/CLL, doar T.35 e ignorat)
    local static_args=()
    hdr10_static_resolve "$src_file"
    [[ -n "${HDR10_MASTER_DISPLAY_X265:-}" ]] && static_args+=(--master-display "$HDR10_MASTER_DISPLAY_X265")
    [[ -n "${HDR10_MAX_CLL:-}" ]] && static_args+=(--max-cll "$HDR10_MAX_CLL")
    injected=$(av_mktemp_ext apv)
    local _inj_rc=0
    "$py" "$AV_ENGINE_APV_HDR10PLUS" inject -i "$raw" -j "$json" -o "$injected" \
        "${static_args[@]}" >>"${LOG_FILE:-/dev/null}" 2>&1 || _inj_rc=$?
    rm -f "$raw"
    if [ "$_inj_rc" -ne 0 ] || [[ ! -s "$injected" ]]; then
        log "  APV HDR10+: ⚠ inject esuat (vezi log) — output ramane HDR10 static"
        rm -f "$injected"; return 1
    fi
    final=$(av_mktemp_ext "$CONTAINER")
    cont_flags=$(get_container_flags)
    local _mux_rc=0
    # -f apv FORTAT: probe-ul demuxerului cere primul PBU = frame/au_info, dar noi
    # punem metadata INAINTE (necesar decoderului) → fara -f apv probe-ul pica.
    # shellcheck disable=SC2086
    ffmpeg -y -v error -f apv -framerate "$fps" -i "$injected" -i "$output" \
        -map 0:v:0 -map 1:a? -map 1:s? -map 1:t? -c copy $cont_flags "$final" 2>>"${LOG_FILE:-/dev/null}" || _mux_rc=$?
    rm -f "$injected"
    if [ "$_mux_rc" -eq 0 ] && [[ -s "$final" ]]; then
        mv -f "$final" "$output"
        if [[ "$(_apv_hdr10plus_probe "$output")" == "hdr10plus" ]]; then
            log "  APV HDR10+: ✓ T.35 per frame + MDCV/CLL injectate (verificat post-remux)"
            # Plasa de siguranta OPTIONALA: decode-check cu decoderul de REFERINTA
            # OpenAPV (instalabil cu tools/openapv_validator.sh) pe primele 3 AU.
            # Tacut cand binarul lipseste; warn onest (fara fail) cand respinge.
            if command -v "$AV_TOOL_OAPV_DEC" >/dev/null 2>&1; then
                local _vref; _vref=$(av_mktemp_ext apv)
                if ffmpeg -y -v error -i "$output" -map 0:v:0 -c:v copy -frames:v 3 -f apv "$_vref" 2>/dev/null \
                   && "$AV_TOOL_OAPV_DEC" -i "$_vref" >/dev/null 2>&1; then
                    log "  APV HDR10+: ✓ acceptat si de decoderul de referinta OpenAPV"
                else
                    log "  APV HDR10+: ⚠ ${AV_TOOL_OAPV_DEC} (referinta) a respins fisierul — verifica manual"
                fi
                rm -f "$_vref"
            fi
            return 0
        fi
        log "  APV HDR10+: ⚠ metadata nedetectata post-remux — posibil pierduta"
        return 1
    fi
    log "  APV HDR10+: ⚠ re-mux esuat — output ramane HDR10 static"
    rm -f "$final"
    return 1
}

# v56: repara trailing byte-ul T.35 (0x80) pe care av1dovi_tool inject-rpu il
# arunca din OBU-urile DV (crate dolby_vision 3.3.x). dav1d il cere; fara el,
# DV-ul e pierdut silentios. Engine partajat src/av1_dv_t35_repair.py.
# In-place pe fisierul IVF dat. Soft-fail: daca python/engine lipsesc, doar
# avertizeaza (verify_dv_survived prinde pierderea ulterior).
_repair_av1_dv_t35() {
    local f="$1" mode="${2:-dv}"   # v76: mode = dv | hdr10plus | both
    local lbl="DV"
    [[ "$mode" == "hdr10plus" ]] && lbl="HDR10+"
    [[ "$mode" == "both" ]] && lbl="DV+HDR10+"
    local engine="$SCRIPT_DIR/av1_dv_t35_repair.py"
    local py
    py=$(_av_python) || {
        echo "  $lbl: ⚠ repair T.35 AV1 sarit (Python 3 indisponibil) — metadata poate fi pierduta la dav1d" | tee -a "${LOG_FILE:-/dev/null}" >&2
        return 1
    }
    if [[ ! -f "$engine" ]]; then
        echo "  $lbl: ⚠ repair T.35 AV1 sarit (engine lipsa: $engine)" | tee -a "${LOG_FILE:-/dev/null}" >&2
        return 1
    fi
    local fixed
    fixed=$(av_mktemp_ext ivf)
    if "$py" "$engine" "$f" "$fixed" "$mode" >>"${LOG_FILE:-/dev/null}" 2>&1 && [ -s "$fixed" ]; then
        mv -f "$fixed" "$f"
        echo "  $lbl: T.35 AV1 reparat (trailing byte re-adaugat pt dav1d)" | tee -a "${LOG_FILE:-/dev/null}" >&2
        return 0
    fi
    rm -f "$fixed"
    echo "  $lbl: ⚠ repair T.35 AV1 esuat — metadata poate fi pierduta la dav1d" | tee -a "${LOG_FILE:-/dev/null}" >&2
    return 1
}

inject_dv_rpu() {
    local stream_file="$1" rpu_file="$2" output_file="$3"
    local target_codec="${4:-hevc}"
    local dovi_bin
    dovi_bin=$(tool_for_inject "$target_codec" dovi)
    echo "  DV: Injectez RPU in bitstream $target_codec (tool=$dovi_bin)..." | tee -a "${LOG_FILE:-/dev/null}" >&2
    "$dovi_bin" inject-rpu -i "$stream_file" \
        --rpu-in "$rpu_file" \
        -o "$output_file" >/dev/null 2>&1
    if [ $? -eq 0 ] && [ -s "$output_file" ]; then
        # v56: AV1 — repara T.35 (trailing byte aruncat de av1dovi_tool)
        [[ "$target_codec" == "av1" ]] && _repair_av1_dv_t35 "$output_file"
        echo "  DV: Injectare RPU reusita" | tee -a "${LOG_FILE:-/dev/null}" >&2
        return 0
    else
        echo "  DV: Injectare RPU esuata" | tee -a "${LOG_FILE:-/dev/null}" >&2
        return 1
    fi
}

# v77: detectie VFR (variable frame rate) — compara r_frame_rate cu avg_frame_rate (citire de
# container, FARA decode → ieftin). Folosit pentru avertismentul de pe calea HW HDR10+ preserve
# (extract→inject): pe sursa VFR numarul de cadre CODATE (din care se extrage JSON-ul) difera de
# cele DECODATE (baza HW) → hdr10plus_tool aliniaza la coada (trunc/dup) → output valid, dar
# metadata cozii poate fi aproximativa. NU normalizam CFR (ar schimba output-ul pe o cale de
# preservare) — doar informam userul. Return 0 = VFR, 1 = CFR/necunoscut (fara fals-pozitiv cand
# avg lipseste). Citire conform regulii ffprobe single-field (default= + head -1 + tr -d '\r').
_is_vfr_source() {
    local f="$1" rfr afr
    rfr=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate \
          -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null | head -1 | tr -d '\r')
    afr=$(ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate \
          -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null | head -1 | tr -d '\r')
    [ -z "$rfr" ] && return 1
    [ -z "$afr" ] && return 1
    [ "$afr" = "0/0" ] && return 1
    [ "$rfr" = "$afr" ] && return 1
    awk -v r="$rfr" -v a="$afr" '
        function val(x,   n,d,p){n=x;d=1;p=index(x,"/");if(p){n=substr(x,1,p-1);d=substr(x,p+1)}if(d+0==0)return 0;return (n+0)/(d+0)}
        BEGIN{rv=val(r);av=val(a);if(av<=0||rv<=0)exit 1;diff=(rv>av)?(rv-av):(av-rv);if(diff/av>0.01)exit 0;exit 1}'
}

# v76: injecteaza HDR10+ dynamic metadata (SMPTE ST 2094-40) intr-un bitstream HEVC/AV1
# brut, prin hdr10plus_tool (HEVC) / av1hdr10plus_tool (AV1) — oglinda lui inject_dv_rpu
# pentru calea HW-preserve. Encoderele HW dropeaza dinamicul (iese HDR10 static); re-injectam
# JSON-ul extras din sursa in bitstream-ul HDR10 produs de HW → HDR10+ restaurat (PoC QSV).
# Sintaxa identica ambele tool-uri: `inject -i <raw> -j <json> -o <out>` (validat CLI).
# stdout redirectat (quietvoid scrie progres pe stdout — vezi What NOT to do).
# NB: spre deosebire de DV/AV1 (inject-rpu omite trailing-byte-ul T.35 → _repair_av1_dv_t35),
#   OBU-ul HDR10+ AV1 (0x003C) e scris de av1hdr10plus_tool — repararea T.35 (DV, 0x003B) il
#   sare; daca dav1d respinge HDR10+ AV1 se evalueaza in F2 (azi calea dovedita = HEVC).
# $1 = raw stream (.hevc/.ivf)  $2 = JSON HDR10+  $3 = output raw  $4 = target_codec (hevc|av1)
inject_hdr10plus_metadata() {
    local stream_file="$1" json_file="$2" output_file="$3"
    local target_codec="${4:-hevc}"
    local hp_bin
    hp_bin=$(tool_for_inject "$target_codec" hdr10plus)
    [[ -z "$hp_bin" ]] && { echo "  HDR10+: tool inject indisponibil ($target_codec)" | tee -a "${LOG_FILE:-/dev/null}" >&2; return 1; }
    echo "  HDR10+: Injectez metadata in bitstream $target_codec (tool=$hp_bin)..." | tee -a "${LOG_FILE:-/dev/null}" >&2
    "$hp_bin" inject -i "$stream_file" -j "$json_file" -o "$output_file" >/dev/null 2>&1
    if [ $? -eq 0 ] && [ -s "$output_file" ]; then
        # v76: AV1 — av1hdr10plus_tool omite acelasi trailing-byte T.35 (0x80) ca av1dovi_tool
        # (dav1d: "Malformed ITU-T T.35") → repara OBU-ul HDR10+ (provider 0x003C).
        [[ "$target_codec" == "av1" ]] && _repair_av1_dv_t35 "$output_file" hdr10plus
        echo "  HDR10+: Injectare reusita" | tee -a "${LOG_FILE:-/dev/null}" >&2
        return 0
    else
        echo "  HDR10+: Injectare esuata" | tee -a "${LOG_FILE:-/dev/null}" >&2
        return 1
    fi
}

# v70: muxeaza un hibrid HEVC DV (raw .hevc cu RPU interleaved) intr-un MKV CU
# semnalizare dvcC de container, prin mkvmerge. mkvmerge parseaza RPU-ul din
# bitstream-ul HEVC brut si scrie automat "DOVI configuration record" (Block
# Addition Mapping) → TV-urile care decid dupa dvcC activeaza DV (playerele PC
# citeau deja RPU-ul din bitstream). ffmpeg NU poate sintetiza dvcC din RPU brut
# (de aceea calea v69 = pas intermediar MP4 → DV doar in bitstream, dormant pe TV).
# HEVC (.hevc) SI AV1 (.ivf, v71) → MKV — mkvmerge scrie dvcC din RPU pt ambele codec-uri.
# Soft-optional: cand mkvmerge lipseste, return 1 → apelantul cade pe pasul MP4 (HEVC,
# comportament v69) sau ffmpeg direct (AV1, IVF poarta PTS). mkvmerge DOAR din elementary
# stream scrie dvcC (NU din MP4 — validat empiric); raw nu poarta timing fiabil →
# framerate explicit din sursa (avg_frame_rate, fallback r_frame_rate).
# $1 = raw video cu RPU (.hevc HEVC sau .ivf/.av1 AV1)   $2 = original (audio/subs/chapters + fps)   $3 = output .mkv
# Return: 0 = mkvmerge a scris output ne-gol (cu dvcC); 1 = indisponibil/esec.
_mux_dv_mkv() {
    local raw_hevc="$1" original="$2" output="$3"
    command -v "$AV_TOOL_MKVMERGE" >/dev/null 2>&1 || return 1
    # Raw HEVC nu are timing → derivam framerate-ul din sursa (CFR pe DV).
    local afr
    afr=$(ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate \
          -of default=noprint_wrappers=1:nokey=1 "$original" 2>/dev/null | head -1 | tr -d '\r' || true)
    if [[ ! "$afr" =~ ^[1-9][0-9]*(/[1-9][0-9]*)?$ ]]; then
        afr=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate \
              -of default=noprint_wrappers=1:nokey=1 "$original" 2>/dev/null | head -1 | tr -d '\r' || true)
    fi
    [[ "$afr" =~ ^[1-9][0-9]*(/[1-9][0-9]*)?$ ]] || return 1
    # v70 audit: pe surse NON-MKV, mkvmerge poate interpreta limba pistelor altfel
    # decat ffmpeg (ex. cod QuickTime legacy nesetat → "und" la mkvmerge vs "eng"
    # la ffmpeg) → output inconsistent dupa cum e prezent sau nu mkvmerge. Fix: pe
    # non-MKV construim un donor MKV doar cu non-video (audio/subs/chapters/attach)
    # via ffmpeg — care scrie limbile ca pe calea ffmpeg — si mkvmerge ia non-video
    # de acolo (MKV nativ → pastreaza tot). Sursele deja-MKV se folosesc direct.
    local donor="$original" donor_tmp=""
    local _orig_ext="${original##*.}"; _orig_ext="${_orig_ext,,}"
    if [[ "$_orig_ext" != "mkv" ]]; then
        donor_tmp=$(av_mktemp_ext mkv)
        # -c:s srt: mov_text (sub-ul tipic in MP4) NU se copiaza in matroska cu
        # -c copy → convertit la srt (acelasi rezultat ca mkvmerge in calea directa).
        # Sub bitmap (PGS/VobSub, rar in MP4) → conversia esueaza → fallback gratios.
        if ffmpeg -v error -y -i "$original" -map 0:a? -map 0:s? -map 0:t? -map_chapters 0 \
              -c copy -c:s srt "$donor_tmp" 2>/dev/null && [ -s "$donor_tmp" ]; then
            donor="$donor_tmp"   # are non-video; daca sursa era video-only sau sub
        else                     # incompatibil → build esueaza → fallback original direct
            rm -f "$donor_tmp"; donor_tmp=""
        fi
    fi
    # video (raw, cu RPU→dvcC) din input 0 + tot restul (audio/subs/chapters/attach) din donor
    local _rc=1
    if "$AV_TOOL_MKVMERGE" -o "$output" --default-duration "0:${afr}fps" \
          "$raw_hevc" --no-video "$donor" >/dev/null 2>&1 && [ -s "$output" ]; then
        _rc=0
    else
        rm -f "$output" 2>/dev/null || true
    fi
    [[ -n "$donor_tmp" ]] && rm -f "$donor_tmp"
    return $_rc
}

# v71: muxeaza un hibrid HEVC DV (raw .hevc cu RPU interleaved) intr-un MP4/MOV CU
# semnalizare dvcC de container, prin MP4Box (GPAC). MP4Box auto-detecteaza RPU-ul
# din bitstream-ul HEVC brut si scrie box-ul dvcC → TV-urile activeaza DV (playerele
# PC citeau deja RPU). ffmpeg NU poate (nici sintetiza dvcC din RPU brut, nici copia
# dvcC existent — validat empiric). Echivalentul pe MP4/MOV al _mux_dv_mkv (v70).
# Soft-optional: lipsa MP4Box → return 1 → apelantul cade pe ffmpeg direct (DV doar
# in bitstream). Raw .hevc nu poarta timing → :fps=<avg_fps> din sursa.
# GATA pe surse ISO (MP4/MOV/M4V): MP4Box #<trackID> mapeaza fiabil pe track ID-ul
# ISO (== ffprobe stream=id). Pe alte containere id-ul difera → return 1 (fallback);
# sursele reale de hibrizi MP4/MOV (encode output, av_mux built, surse DV MP4/MOV)
# sunt acoperite, iar MKV→MP4 (rar) are alternativa MKV via mkvmerge (v70).
# $1 = raw .hevc (cu RPU)   $2 = original (audio/subs + framerate)   $3 = output .mp4/.mov
# Return: 0 = MP4Box a scris output ne-gol (cu dvcC); 1 = indisponibil/incompatibil/esec.
_mux_dv_mp4() {
    local raw_hevc="$1" original="$2" output="$3"
    command -v "$AV_TOOL_MP4BOX" >/dev/null 2>&1 || return 1
    # dvp= EXPLICIT pt AMBELE codec-uri (v75). HEVC: auto-detect-ul MP4Box mislabeleaza
    # P8.4 (HLG) ca profil 5 (tag dvh1 + dvcC profil 5 → TV gresit) → dvp=profil.compat din
    # referinta il forteaza corect (P5→5/dvh1, P8.1→8.1/hvc1, P8.4→8.4/hvc1; tag-ul iese
    # automat corect). AV1 (.ivf/.av1/.obu): auto-detect-ul refuza plasarea OBU-ului de
    # metadata DV de la av1dovi_tool ("must appear after all non-shown frames") → dvp=
    # oricum scrie dvcC (RPU byte-identic, validat). $4 = referinta cu dvcC (sursa la
    # passthrough); altfel $original.
    local _rext="${raw_hevc##*.}"; _rext="${_rext,,}"
    local _is_av1=0
    case "$_rext" in
        hevc|h265|265) : ;;
        ivf|av1|obu)   _is_av1=1 ;;
        *) return 1 ;;
    esac
    local _oext="${original##*.}"; _oext="${_oext,,}"
    case "$_oext" in mp4|mov|m4v|qt) : ;; *) return 1 ;; esac
    local afr
    afr=$(ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate \
          -of default=noprint_wrappers=1:nokey=1 "$original" 2>/dev/null | head -1 | tr -d '\r' || true)
    if [[ ! "$afr" =~ ^[1-9][0-9]*(/[1-9][0-9]*)?$ ]]; then
        afr=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate \
              -of default=noprint_wrappers=1:nokey=1 "$original" 2>/dev/null | head -1 | tr -d '\r' || true)
    fi
    [[ "$afr" =~ ^[1-9][0-9]*(/[1-9][0-9]*)?$ ]] || return 1
    # Deriva dvp=profil.compat din dvcC-ul referintei DV ($4 / $original).
    local _firstadd="${raw_hevc}:fps=${afr}"
    local _dv_ref="${4:-$original}"
    if [[ "$_is_av1" == "1" ]]; then
        # AV1 DV e MEREU profil 10 (dav1.10.xx) — NU citi dv_profile din referinta: la
        # cross-codec (sursa HEVC DV profil 8/5/7 → tinta AV1) ar produce dvcC AV1 gresit.
        # Citeste DOAR compat (bl_signal_compatibility_id, consistent intre profile); fallback 10.1.
        local _c _dvp="10.1"
        _c=$(ffprobe -v error -select_streams v:0 -show_entries stream_side_data=dv_bl_signal_compatibility_id \
             -of default=noprint_wrappers=1:nokey=1 "$_dv_ref" 2>/dev/null | head -1 | tr -d '\r' || true)
        [[ "$_c" =~ ^[0-9]+$ ]] && _dvp="10.${_c}"
        _firstadd="${raw_hevc}:dvp=${_dvp}:fps=${afr}"
    elif [[ -n "${4:-}" ]]; then
        # HEVC: dvp= din referinta EXPLICITA ($4) DOAR. Auto-detect-ul MP4Box mislabeleaza
        # DOAR P8.4 (HLG) ca profil 5 — pe preserve/passthrough sursa (cu dvcC; profilul ei
        # == profilul stream-ului) se pasa ca $4 → dvp corect (prinde P8.4). FARA $4
        # (transform/hybrid via _hdv_combine): NU folosi $original ca referinta — e sursa
        # PRE-transform, alt profil decat stream-ul 8.1 PRODUS (ex. P5→8.1 ar scrie 5.0 pe
        # un stream 8.1). Stream-ul produs e mereu 8.1, iar auto-detect e CORECT pe 8.1
        # (validat empiric; bug-ul P8.4 nu se aplica) → ramane :fps= (auto-detect).
        local _hp _hc
        _hp=$(ffprobe -v error -select_streams v:0 -show_entries stream_side_data=dv_profile \
              -of default=noprint_wrappers=1:nokey=1 "$4" 2>/dev/null | head -1 | tr -d '[:space:]\r' || true)
        _hc=$(ffprobe -v error -select_streams v:0 -show_entries stream_side_data=dv_bl_signal_compatibility_id \
              -of default=noprint_wrappers=1:nokey=1 "$4" 2>/dev/null | head -1 | tr -d '[:space:]\r' || true)
        [[ "$_hp" =~ ^[0-9]+$ && "$_hc" =~ ^[0-9]+$ ]] && _firstadd="${raw_hevc}:dvp=${_hp}.${_hc}:fps=${afr}"
    fi
    # video (raw, cu RPU→dvcC) + fiecare pista audio/subtitle din original dupa track ID.
    # MP4Box #N: N = track ID ISO (== ffprobe stream=id, in hex 0xN → decimal prin $(( )) ).
    # NB: ffprobe -select_streams accepta UN singur specificator (a,s e invalid) →
    # enumeram audio apoi subtitle separat. id e track ID-ul ISO (hex 0xN → $(( )) ).
    local -a add_args=("-add" "$_firstadd")
    local _st _id
    for _st in a s; do
        while IFS= read -r _id; do
            _id="${_id%$'\r'}"   # ffprobe.exe pe Windows/git-bash scrie CRLF
            [[ -z "$_id" || "$_id" == "N/A" ]] && continue
            add_args+=("-add" "${original}#$((_id))")
        done < <(ffprobe -v error -select_streams "$_st" -show_entries stream=id \
                 -of default=noprint_wrappers=1:nokey=1 "$original" 2>/dev/null || true)
    done
    local _rc=1
    if "$AV_TOOL_MP4BOX" "${add_args[@]}" -new "$output" >/dev/null 2>&1 && [ -s "$output" ]; then
        _rc=0
        # MP4Box -add NU copiaza capitolele (spre deosebire de mkvmerge --no-video,
        # care le include) → le caram separat (dump-chap + chap). Determinist pe
        # count: un dump pe 0 capitole poate lasa fisierul pre-creat/gol →
        # guard-ul -s singur e fragil, asa ca verificam intai cu ffprobe.
        local _nch
        _nch=$(ffprobe -v error -show_chapters -of csv=p=0 "$original" 2>/dev/null | grep -c . || true)
        if [[ "${_nch:-0}" -gt 0 ]]; then
            local _chap; _chap=$(av_mktemp_ext txt)
            if "$AV_TOOL_MP4BOX" -dump-chap "$original" -out "$_chap" >/dev/null 2>&1 && [ -s "$_chap" ]; then
                "$AV_TOOL_MP4BOX" -chap "$_chap" "$output" >/dev/null 2>&1 || true
            fi
            rm -f "$_chap" 2>/dev/null || true
        fi
    else
        rm -f "$output" 2>/dev/null || true
    fi
    return $_rc
}

# v71: scrie dvcC de container pe un output DEJA construit ($built), inlocuind video-ul
# cu $raw (DV, cu RPU). Dispatch dupa container: mkv → mkvmerge (_mux_dv_mkv), mp4/mov →
# MP4Box (_mux_dv_mp4). Dispatch UNIC folosit de toate fluxurile (av_mux + stream-copy).
# Unealta absenta / esec → pastreaza $built, return 1. $1=raw .hevc $2=built $3=target ext.
_dv_container_signal() {
    local raw="$1" built="$2" target="$3" dv_ref="${4:-}"
    local tmp ok=1
    tmp=$(av_mktemp_ext "$target")
    if [[ "$target" == "mkv" ]]; then
        _mux_dv_mkv "$raw" "$built" "$tmp" || ok=0
    else
        _mux_dv_mp4 "$raw" "$built" "$tmp" "$dv_ref" || ok=0
    fi
    if [[ "$ok" == "1" ]] && [ -s "$tmp" ]; then
        mv -f "$tmp" "$built"
        echo "  dvcC de container scris (DV pe TV)"
    else
        rm -f "$tmp" 2>/dev/null   # esec → pastreaza $built (graceful); return 0
    fi
    return 0
}

# v71: re-scrie dvcC pe un output produs prin STREAM-COPY dintr-un DV HEVC. ffmpeg -c copy
# pierde semnalizarea DV de container (chiar daca pastreaza bitstream-ul) → o re-adaugam.
# Detecteaza DV pe SURSA (output-ul a pierdut deja side_data), extrage video-ul raw din
# OUTPUT (poarta bitstream-ul DV) + dispatch. No-op (return 0) cand: tinta non-mkv/mp4/mov,
# sursa nu-i HEVC DV, sau unealta lipsa. Folosit de do_stream_copy / audio-only / trim.
#   $1 = sursa DV originala   $2 = output (rezultatul stream-copy)   $3 = target ext
_dv_resignal_copy() {
    local source="$1" output="$2" target="$3"
    case "$target" in mkv|mp4|mov) : ;; *) return 0 ;; esac
    # ffmpeg PASTREAZA DOVI config la orice →MKV (block addition in track header), dar o
    # PIERDE la orice →MP4/MOV (chiar MP4→MP4). Deci daca output-ul are deja semnalizarea
    # (cazul →MKV), nimic de facut (evitam re-mux redundant); altfel (→MP4/MOV) re-adaugam.
    # Verificam intai OUTPUT-ul, apoi ca SURSA chiar era DV (HEVC sau AV1, v72).
    if ffprobe -v error -select_streams v:0 -show_entries stream_side_data=side_data_type \
        -of default=noprint_wrappers=1:nokey=1 "$output" 2>/dev/null | grep -qi "DOVI"; then
        return 0
    fi
    local _sc; _sc=$(detect_source_codec "$source" 2>/dev/null || true)
    [[ "$_sc" == "hevc" || "$_sc" == "av1" ]] || return 0
    ffprobe -v error -select_streams v:0 -show_entries stream_side_data=side_data_type \
        -of default=noprint_wrappers=1:nokey=1 "$source" 2>/dev/null | grep -qi "DOVI" || return 0
    # extragere raw codec-aware: HEVC annexb / AV1 IVF. La AV1+MP4, MP4Box cere dvp= →
    # _dv_container_signal paseaza $source ca referinta de compat (al 4-lea arg).
    local _raw
    if [[ "$_sc" == "av1" ]]; then
        _raw=$(av_mktemp_ext ivf)
        ffmpeg -v error -y -i "$output" -map 0:v:0 -c:v copy -f ivf "$_raw" 2>/dev/null || true
    else
        _raw=$(av_mktemp_ext hevc)
        ffmpeg -v error -y -i "$output" -map 0:v:0 -c:v copy -bsf:v hevc_mp4toannexb "$_raw" 2>/dev/null || true
    fi
    if [ -s "$_raw" ]; then
        _dv_container_signal "$_raw" "$output" "$target" "$source" || true
    fi
    rm -f "$_raw"
    return 0
}

# Extrage RPU dintr-un stream HEVC/AV1 raw sau dintr-un container.
# $1 = input file (raw stream sau container)
# $2 = output RPU bin path
# $3 = source_codec (hevc default | av1) — pentru selectia binarului si a bsf-ului
# Return: 0=OK, 1=fail. Daca input e container, extrage prima video stream automat.
extract_dv_rpu() {
    local input="$1" rpu_out="$2" src_codec="${3:-hevc}"
    local dovi_bin
    dovi_bin=$(tool_for_extract "$src_codec" dovi)
    [[ -z "$dovi_bin" ]] && return 1

    # Daca input pare container (extensie != .hevc/.h265/.ivf/.obu), extragem raw intai.
    local ext="${input##*.}"; ext="${ext,,}"
    local raw_tmp="" use_input="$input"
    case "$ext" in
        hevc|h265|265|ivf|obu)
            : # raw deja
            ;;
        *)
            local raw_ext
            case "$src_codec" in
                av1) raw_ext="ivf" ;;
                *)   raw_ext="hevc" ;;
            esac
            raw_tmp=$(av_mktemp_ext "$raw_ext")
            if [[ "$src_codec" == "av1" ]]; then
                ffmpeg -y -v error -i "$input" -c:v copy -f ivf "$raw_tmp" 2>/dev/null
            else
                ffmpeg -y -v error -i "$input" -c:v copy -bsf:v hevc_mp4toannexb -f hevc "$raw_tmp" 2>/dev/null
            fi
            [ $? -ne 0 ] && { rm -f "$raw_tmp"; return 1; }
            use_input="$raw_tmp"
            ;;
    esac

    "$dovi_bin" extract-rpu -i "$use_input" -o "$rpu_out" >/dev/null 2>&1
    local rc=$?
    [[ -n "$raw_tmp" ]] && rm -f "$raw_tmp"
    [ $rc -eq 0 ] && [ -s "$rpu_out" ] && return 0 || return 1
}

# Converteste profile-ul unui RPU DV (ex: 5→8.1, force 8.1, 8.1 preserving mapping).
# $1 = rpu_in path
# $2 = rpu_out path
# $3 = mode — int forwarded ca flag GLOBAL `-m N` (default 2 = force 8.1)
# $4 = target_codec (hevc default | av1) — alege binarul (dovi_tool / av1dovi_tool)
# Modes (dovi_tool 2.x, flag global inainte de subcomanda):
#   0=untouched, 1=MEL, 2=force 8.1 (removes mapping), 3=5→8.1, 4=8.4,
#   5=8.1 preserving luma/chroma mapping.
# v55 FIX: subcomanda `convert` din dovi_tool 2.x opereaza pe fisiere HEVC (-i/-o),
#   NU pe RPU .bin, si nu accepta `-m`/`--rpu-out` (esua cu exit 2 la fiecare apel).
#   Conversia RPU→RPU se face cu `-m N editor` (mode global + edit config minimal `{}`).
convert_rpu_profile() {
    local rpu_in="$1" rpu_out="$2" mode="${3:-2}" target_codec="${4:-hevc}"
    [[ ! -f "$rpu_in" ]] && return 1
    local dovi_bin
    dovi_bin=$(tool_for_inject "$target_codec" dovi)
    [[ -z "$dovi_bin" ]] && return 1
    # editor cere un JSON de edit; `{}` gol => doar conversia de profil (mode global)
    local edit_cfg
    edit_cfg=$(av_mktemp_ext json)
    printf '{}' > "$edit_cfg"
    echo "  RPU convert: $rpu_in -> $rpu_out (mode=$mode, codec=$target_codec, tool=$dovi_bin)" \
        | tee -a "${LOG_FILE:-/dev/null}" >&2
    local conv_rc=0
    if [[ -n "${LOG_FILE:-}" ]]; then
        "$dovi_bin" -m "$mode" editor -i "$rpu_in" -j "$edit_cfg" -o "$rpu_out" >/dev/null 2>>"$LOG_FILE" || conv_rc=$?
    else
        "$dovi_bin" -m "$mode" editor -i "$rpu_in" -j "$edit_cfg" -o "$rpu_out" >/dev/null 2>&1 || conv_rc=$?
    fi
    rm -f "$edit_cfg"
    [ "$conv_rc" -eq 0 ] && [ -s "$rpu_out" ] && return 0 || return 1
}

# Extrage video raw dintr-un container, codec-aware.
# $1 = input file
# $2 = output raw stream
# $3 = codec opt (default = detect_source_codec)
# Returneaza 0=OK, 1=fail.
extract_raw_video() {
    local input="$1" output="$2" codec="${3:-}"
    [[ -z "$codec" ]] && codec=$(detect_source_codec "$input")
    case "$codec" in
        av1)
            ffmpeg -y -v error -i "$input" -c:v copy -f ivf "$output" 2>/dev/null
            ;;
        hevc)
            ffmpeg -y -v error -i "$input" -c:v copy -bsf:v hevc_mp4toannexb -f hevc "$output" 2>/dev/null
            ;;
        h264)
            ffmpeg -y -v error -i "$input" -c:v copy -bsf:v h264_mp4toannexb -f h264 "$output" 2>/dev/null
            ;;
        *)
            ffmpeg -y -v error -i "$input" -c:v copy "$output" 2>/dev/null
            ;;
    esac
    [ $? -eq 0 ] && [ -s "$output" ] && return 0 || return 1
}

# ══════════════════════════════════════════════════════════════════════
# v76 — Conversie DV Profile 7 → 8.1 (dual-layer aware): helperi puri
# P7 = dual-layer (BL HDR10 + EL [MEL/FEL] + RPU). Conversia la 8.1 (single-layer)
# pastreaza BL + RPU, ARUNCA EL. MEL → lossless; FEL "simplu" → sigur; FEL "complex"
# (EL cu expansiune de luminozitate peste BL) → pierde highlight-uri → gate de siguranta.
# Orchestratorul (convert_p7_to_81) + branch-ul UI traiesc in av_hdr_dv_tools.sh.
# ══════════════════════════════════════════════════════════════════════

# Peak-ul base-layer in niti (MaxCLL real al BL din container) — pragul gate-ului FEL.
# Echo: numar niti (>0). Fallback 1000 cand MaxCLL lipseste/0 (conservator: prag jos →
# expansiunea FEL e prinsa). NU folosim mastering display ca fallback (poate fi setat la
# masterul DV, ex. 4000, mascand un FEL complex).
_dv_bl_peak_nits() {
    local file="$1" maxcll
    maxcll=$(ffprobe -v error -select_streams v:0 -show_frames -read_intervals "0%+#1" \
        -show_entries frame_side_data=max_content -of default=noprint_wrappers=1:nokey=1 \
        "$file" 2>/dev/null | grep -E '^[0-9]+$' | head -1 | tr -d '\r')
    if [[ "$maxcll" =~ ^[1-9][0-9]*$ ]]; then echo "$maxcll"; else echo "1000"; fi
}

# Extrage stream-ul HEVC complet (BL+EL+RPU) dintr-un P7. MKV: EL sta in block additions
# → necesita $AV_TOOL_MKVEXTRACT (ffmpeg -c copy ar pierde EL+RPU → "Invalid RPU"). Alte
# containere (mp4/ts): EL interleaved → ffmpeg. $1=input, $2=output .hevc. Return 0/1.
_dv_extract_full_hevc() {
    local file="$1" out="$2"
    local ext="${file##*.}"; ext="${ext,,}"
    if [[ "$ext" == "mkv" ]] && command -v "$AV_TOOL_MKVEXTRACT" >/dev/null 2>&1; then
        # track id din $AV_TOOL_MKVMERGE -i (id mkvextract == id mkvmerge, NU index ffprobe)
        local vid
        vid=$("$AV_TOOL_MKVMERGE" -i "$file" 2>/dev/null \
              | sed -n 's/^Track ID \([0-9]*\): video.*/\1/p' | head -1)
        [[ "$vid" =~ ^[0-9]+$ ]] || vid=0
        rm -f "$out"   # tinta noua (tool-ul scrie fisier nou)
        "$AV_TOOL_MKVEXTRACT" "$file" tracks "${vid}:${out}" >/dev/null 2>&1
    else
        ffmpeg -y -v error -i "$file" -map 0:v:0 -c:v copy -bsf:v hevc_mp4toannexb -f hevc "$out" 2>/dev/null
    fi
    [ -s "$out" ] && return 0 || return 1
}

# Clasifica EL-ul unui P7 (pe stream HEVC complet) via engine dv_p7_analyze.py.
# Echo (stdout, DOAR linia verdictului): "<MEL|FEL_SAFE|FEL_COMPLEX|UNKNOWN> l1_nits=.. bl_peak=.. thr=.."
# Soft-fail → "UNKNOWN ..." cand lipseste python/engine/tool sau extract-rpu esueaza.
#   $1 = stream HEVC complet (BL+EL+RPU)   $2 = fisier original (pt bl_peak)
_classify_p7_el() {
    local stream="$1" orig="$2"
    local engine="$AV_ENGINE_DV_P7" py
    py=$(_av_python) || { echo "UNKNOWN l1_nits=0 bl_peak=0 thr=0"; return 0; }
    [[ -f "$engine" ]] || { echo "UNKNOWN l1_nits=0 bl_peak=0 thr=0"; return 0; }
    local dovi_bin; dovi_bin=$(tool_for_extract hevc dovi)
    [[ -z "$dovi_bin" ]] && { echo "UNKNOWN l1_nits=0 bl_peak=0 thr=0"; return 0; }
    local rpu json
    rpu=$(av_mktemp_ext bin); json=$(av_mktemp_ext json)
    "$dovi_bin" extract-rpu "$stream" -o "$rpu" >/dev/null 2>&1
    if [ ! -s "$rpu" ]; then
        rm -f "$rpu" "$json"; echo "UNKNOWN l1_nits=0 bl_peak=0 thr=0"; return 0
    fi
    "$dovi_bin" export -i "$rpu" -d "all=$json" >/dev/null 2>&1
    local bl_peak; bl_peak=$(_dv_bl_peak_nits "$orig")
    local out; out=$("$py" "$engine" "$json" "$bl_peak" 2>/dev/null)
    rm -f "$rpu" "$json"
    [[ -n "$out" ]] && echo "$out" || echo "UNKNOWN l1_nits=0 bl_peak=0 thr=0"
}

# v76: extrage RPU-ul pt DV PRESERVE pe calea de ENCODE (baza re-encodata e mereu
# single-layer HDR10). Pe sursa P7 (dual-layer HEVC), extract_dv_rpu standard fie
# ESUEAZA (RPU sta in EL → ffmpeg -c copy il pierde, ex. P7 MKV) fie da un RPU profil-7
# care, injectat intr-o baza single-layer, produce un stream DV INVALID (profil 7 cere
# un EL care nu mai exista). Deci pt P7: extragem stream-ul COMPLET (mkvextract pt MKV via
# _dv_extract_full_hevc), convertim STREAM-ul la 8.1 (`-m 2 convert --discard`) si extragem
# RPU-ul profil-8 din el (EL pierdut oricum la re-encode → 8.1 e profilul corect; conversia
# e de STREAM, NU de RPU — `-m 2 editor` pe RPU P7 e no-op). Restul (P8.x / AV1 P10): normal.
# Folosit la TOATE siturile de DV-preserve pe encode (x265/av1/HW/MediaCodec).
#   $1 = fisier sursa   $2 = RPU out   $3 = src_codec (hevc|av1)   Return: 0=OK, 1=fail.
_extract_preserve_rpu() {
    local file="$1" rpu_out="$2" codec="${3:-hevc}"
    # v77: chokepoint DRY pt toate caile de DV-preserve la ENCODE (HW + SW + hibrid). Pe sursa VFR,
    # numarul de cadre din RPU (extras din cadrele CODATE) difera de baza re-encodata (cadre DECODATE)
    # → dovi_tool inject-rpu aliniaza pe pozitie (trunc/dup la coada), gratios. Avertizam userul.
    _is_vfr_source "$file" && log "  ⚠ Sursa e VFR (r_frame_rate != avg_frame_rate) — RPU DV se aliniaza pe pozitie la cadrele de output; tool-ul poate raporta o mica diferenta de cadre la coada, ajustata automat (fara impact vizibil)."
    if [[ "$codec" != "hevc" ]] || [[ "$(get_dv_profile "$file")" != *"Profil 7"* ]]; then
        extract_dv_rpu "$file" "$rpu_out" "$codec"
        return $?
    fi
    local full conv dovi_bin
    full=$(av_mktemp_ext hevc); conv=$(av_mktemp_ext hevc)
    if ! _dv_extract_full_hevc "$file" "$full"; then rm -f "$full" "$conv"; return 1; fi
    dovi_bin=$(tool_for_extract hevc dovi)
    # P7→8.1 e o operatie de STREAM (discard EL), NU de RPU: `dovi_tool -m 2 editor` pe un
    # RPU P7 e NO-OP (ramane profil 7 → injectat intr-o baza single-layer = DV invalid).
    # Convertim STREAM-ul complet (`-m 2 convert --discard` → BL HDR10 + RPU single-layer 8.1),
    # apoi extragem RPU-ul profil-8 din el (injectat in baza re-encodata → DV 8.1 valid).
    if ! "$dovi_bin" -m 2 convert --discard -i "$full" -o "$conv" >/dev/null 2>&1 || [ ! -s "$conv" ]; then
        rm -f "$full" "$conv"; return 1
    fi
    rm -f "$full"
    "$dovi_bin" extract-rpu "$conv" -o "$rpu_out" >/dev/null 2>&1
    rm -f "$conv"
    if [ -s "$rpu_out" ]; then
        log "  DV preserve: sursa P7 → stream convertit 8.1 + RPU profil-8 extras (baza re-encodata single-layer; EL pierdut la re-encode)"
        return 0
    fi
    rm -f "$rpu_out"
    return 1
}

# ══════════════════════════════════════════════════════════════════════
# v56 — HDR/DV TOOLS extinse: remove DV / remove HDR10+ / verify / export / plot
# Toate opereaza pe binare (dovi_tool/av1dovi_tool/hdr10plus_tool/av1hdr10plus_tool)
# selectate codec-aware prin tool_for_extract/tool_for_inject.
# ══════════════════════════════════════════════════════════════════════

# Remove DV enhancement layer + RPU dintr-un bitstream raw → HDR10 curat.
# (HEVC: scoate EL+RPU NAL; AV1: scoate RPU OBU_METADATA; HDR10/HDR10+ raman.)
# $1=input raw bitstream, $2=output raw bitstream, $3=codec (hevc|av1)
# Return: 0=OK, 1=fail.
remove_dv_layer() {
    local input="$1" output="$2" codec="${3:-hevc}"
    local dovi_bin
    dovi_bin=$(tool_for_extract "$codec" dovi)
    [[ -z "$dovi_bin" ]] && return 1
    "$dovi_bin" remove -i "$input" -o "$output" >/dev/null 2>&1
    [ $? -eq 0 ] && [ -s "$output" ] && return 0 || return 1
}

# Remove HDR10+ metadata (HEVC: SEI; AV1: OBU_METADATA) dintr-un bitstream raw.
# $1=input raw bitstream, $2=output raw bitstream, $3=codec (hevc|av1)
# Return: 0=OK, 1=fail.
remove_hdr10plus_metadata() {
    local input="$1" output="$2" codec="${3:-hevc}"
    local hp_bin
    hp_bin=$(tool_for_extract "$codec" hdr10plus)
    [[ -z "$hp_bin" ]] && return 1
    "$hp_bin" remove -i "$input" -o "$output" >/dev/null 2>&1
    [ $? -eq 0 ] && [ -s "$output" ] && return 0 || return 1
}

# Verifica daca un fisier contine metadata HDR10+ dinamica (--verify extract).
# Accepta container sau bitstream raw (extrage raw intern daca e container).
# $1=input (container sau raw), $2=codec (hevc|av1)
# Return: 0=prezent, 1=absent/eroare. (hdr10plus_tool exit 0=prezent, 1=absent.)
verify_hdr10plus() {
    local input="$1" codec="${2:-hevc}"
    local hp_bin
    hp_bin=$(tool_for_extract "$codec" hdr10plus)
    [[ -z "$hp_bin" ]] && return 1

    local ext="${input##*.}"; ext="${ext,,}"
    local raw_tmp="" use_input="$input"
    case "$ext" in
        hevc|h265|265|ivf|obu) : ;;  # raw deja
        *)
            local raw_ext="hevc"; [[ "$codec" == "av1" ]] && raw_ext="ivf"
            raw_tmp=$(av_mktemp_ext "$raw_ext")
            if ! extract_raw_video "$input" "$raw_tmp" "$codec"; then
                rm -f "$raw_tmp"; return 1
            fi
            use_input="$raw_tmp"
            ;;
    esac

    "$hp_bin" --verify extract -i "$use_input" >/dev/null 2>&1
    local rc=$?
    [[ -n "$raw_tmp" ]] && rm -f "$raw_tmp"
    return $rc
}

# Exporta un RPU DV (.bin) la JSON pentru analiza offline.
# $1=rpu_in (.bin), $2=out_json, $3=kind (all|scenes|level5, default all), $4=codec
# Return: 0=OK, 1=fail.
export_dv_rpu_json() {
    local rpu_in="$1" out_json="$2" kind="${3:-all}" codec="${4:-hevc}"
    [[ ! -s "$rpu_in" ]] && return 1
    local dovi_bin
    dovi_bin=$(tool_for_extract "$codec" dovi)
    [[ -z "$dovi_bin" ]] && return 1
    "$dovi_bin" export -i "$rpu_in" -d "${kind}=${out_json}" >/dev/null 2>&1
    [ $? -eq 0 ] && [ -s "$out_json" ] && return 0 || return 1
}

# Genereaza un grafic PNG al metadata DV dintr-un RPU (.bin) — nativ in dovi_tool.
# $1=rpu_in (.bin), $2=out_png, $3=plot_type (l1|l2|l8|l8-saturation|l8-hue, default l1)
# $4=title (optional), $5=codec (hevc|av1)
# Return: 0=OK, 1=fail.
plot_dv_metadata() {
    local rpu_in="$1" out_png="$2" plot_type="${3:-l1}" title="${4:-}" codec="${5:-hevc}"
    [[ ! -s "$rpu_in" ]] && return 1
    local dovi_bin
    dovi_bin=$(tool_for_extract "$codec" dovi)
    [[ -z "$dovi_bin" ]] && return 1
    if [[ -n "$title" ]]; then
        "$dovi_bin" plot -i "$rpu_in" -o "$out_png" -p "$plot_type" -t "$title" >/dev/null 2>&1
    else
        "$dovi_bin" plot -i "$rpu_in" -o "$out_png" -p "$plot_type" >/dev/null 2>&1
    fi
    [ $? -eq 0 ] && [ -s "$out_png" ] && return 0 || return 1
}

# Verifica daca stratul DV a SUPRAVIETUIT intr-un fisier final (post inject + re-mux).
# Necesar pentru known issue AV1: av1dovi_tool inject-rpu produce metadata T.35 pe
# care ffmpeg o respinge la pachetizare → re-mux reuseste (rc=0, output ne-gol) DAR
# DV-ul e eliminat silentios. Acest helper detecteaza pierderea ca sa raportam onest.
# $1=fisier final (container), $2=codec (hevc|av1). Return: 0=DV prezent, 1=DV absent.
verify_dv_survived() {
    local file="$1" codec="${2:-hevc}"
    local rpu_chk
    rpu_chk=$(av_mktemp_ext bin)
    if extract_dv_rpu "$file" "$rpu_chk" "$codec" >/dev/null 2>&1 && [ -s "$rpu_chk" ]; then
        rm -f "$rpu_chk"; return 0
    fi
    rm -f "$rpu_chk"; return 1
}

# ══════════════════════════════════════════════════════════════════════
# REMUX PRE-FLIGHT + REMUX CONTAINER (v44 transform-only / remux flows)
# ══════════════════════════════════════════════════════════════════════

# Pre-flight check pentru remux container.
# $1 = file, $2 = target_container (mp4 | mov | mkv | webm)
# Set: REMUX_PREFLIGHT_NOTES (array), REMUX_PREFLIGHT_LEVEL (0=ok, 1=warn, 2=fail).
# Return: cod identic cu LEVEL (0/1/2).
# v49: extins cu reguli pentru webm, image subs (PGS/VobSub), DTS-HD/TrueHD, attachments.
declare -a REMUX_PREFLIGHT_NOTES
REMUX_PREFLIGHT_LEVEL=0

_remux_preflight() {
    local file="$1" target="$2"
    REMUX_PREFLIGHT_NOTES=()
    REMUX_PREFLIGHT_LEVEL=0
    target="${target,,}"

    local video_codec audio_codecs sub_codecs codec_tags
    # v57: default= in loc de csv=p=0 — csv emite trailing comma chiar la single-field
    # → "av1," "eac3," etc. → gate-urile regex anchored (`^truehd$`) esueaza silentios.
    video_codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
    audio_codecs=$(ffprobe -v error -select_streams a -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
    sub_codecs=$(ffprobe -v error -select_streams s -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
    codec_tags=$(ffprobe -v error -show_entries stream=codec_tag_string \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)

    local dji_present=0 attach_count=0
    echo "$codec_tags" | grep -qiE "^(djmd|dbgi)" && dji_present=1
    attach_count=$(ffprobe -v error -select_streams t -show_entries stream=index \
        -of csv=p=0 "$file" 2>/dev/null | grep -c . || true)

    case "$target" in
        mp4)
            echo "$audio_codecs" | grep -qiE "^(truehd|dts|pcm_s24le|pcm_s16be)$" && {
                REMUX_PREFLIGHT_NOTES+=("Audio lossless (TrueHD/DTS-HD/PCM) — incompatibil cu MP4, va fi strip-uit")
                [ $REMUX_PREFLIGHT_LEVEL -lt 1 ] && REMUX_PREFLIGHT_LEVEL=1
            }
            echo "$sub_codecs" | grep -qiE "^(subrip|srt|ass|ssa)$" && {
                REMUX_PREFLIGHT_NOTES+=("Subtitrari text necompatibile direct cu MP4 — vor fi convertite la mov_text")
                [ $REMUX_PREFLIGHT_LEVEL -lt 1 ] && REMUX_PREFLIGHT_LEVEL=1
            }
            echo "$sub_codecs" | grep -qiE "^(dvd_subtitle|hdmv_pgs_subtitle)$" && {
                REMUX_PREFLIGHT_NOTES+=("Subtitrari bitmap (PGS/VobSub) incompatibile cu MP4 — vor fi strip-uite")
                [ $REMUX_PREFLIGHT_LEVEL -lt 1 ] && REMUX_PREFLIGHT_LEVEL=1
            }
            [ "$dji_present" -eq 1 ] && {
                REMUX_PREFLIGHT_NOTES+=("Track-uri DJI (djmd/dbgi) incompatibile cu MP4 — vor fi strip-uite")
                [ $REMUX_PREFLIGHT_LEVEL -lt 1 ] && REMUX_PREFLIGHT_LEVEL=1
            }
            [ "$attach_count" -gt 0 ] && {
                REMUX_PREFLIGHT_NOTES+=("$attach_count atasament(e) (fonts/imagini) — doar MKV suporta atasamente, vor fi strip-uite")
                [ $REMUX_PREFLIGHT_LEVEL -lt 1 ] && REMUX_PREFLIGHT_LEVEL=1
            }
            ;;
        mov)
            # v57: AV1 NU e suportat de containerul MOV (ffmpeg: "av1 only
            # supported in MP4 and AVIF"). Detectat empiric pe sample AV1 DV
            # care a esuat → eroare ffmpeg obscura. Level 2 = abort.
            [[ "$video_codec" == "av1" ]] && {
                REMUX_PREFLIGHT_NOTES+=("Video AV1 incompatibil cu .mov (ffmpeg limit) — alege .mp4 sau .mkv")
                REMUX_PREFLIGHT_LEVEL=2
            }
            [[ "$audio_codecs" =~ eac3 ]] && {
                REMUX_PREFLIGHT_NOTES+=("E-AC3 audio incompatibil cu .mov — converteste audio sau alege .mp4")
                REMUX_PREFLIGHT_LEVEL=2
            }
            echo "$audio_codecs" | grep -qiE "^(truehd|dts|opus)$" && {
                REMUX_PREFLIGHT_NOTES+=("Audio (TrueHD/DTS/Opus) incompatibil cu MOV — va fi strip-uit")
                [ $REMUX_PREFLIGHT_LEVEL -lt 1 ] && REMUX_PREFLIGHT_LEVEL=1
            }
            echo "$sub_codecs" | grep -qiE "^(subrip|srt|ass|ssa)$" && {
                REMUX_PREFLIGHT_NOTES+=("Subtitrari text vor fi convertite la mov_text pentru MOV")
                [ $REMUX_PREFLIGHT_LEVEL -lt 1 ] && REMUX_PREFLIGHT_LEVEL=1
            }
            echo "$sub_codecs" | grep -qiE "^(dvd_subtitle|hdmv_pgs_subtitle)$" && {
                REMUX_PREFLIGHT_NOTES+=("Subtitrari bitmap (PGS/VobSub) incompatibile cu MOV — vor fi strip-uite")
                [ $REMUX_PREFLIGHT_LEVEL -lt 1 ] && REMUX_PREFLIGHT_LEVEL=1
            }
            [ "$dji_present" -eq 1 ] && {
                REMUX_PREFLIGHT_NOTES+=("Track-uri DJI (djmd/dbgi) incompatibile cu MOV — vor fi strip-uite")
                [ $REMUX_PREFLIGHT_LEVEL -lt 1 ] && REMUX_PREFLIGHT_LEVEL=1
            }
            [ "$attach_count" -gt 0 ] && {
                REMUX_PREFLIGHT_NOTES+=("$attach_count atasament(e) — doar MKV suporta atasamente, vor fi strip-uite")
                [ $REMUX_PREFLIGHT_LEVEL -lt 1 ] && REMUX_PREFLIGHT_LEVEL=1
            }
            ;;
        webm)
            # WEBM e foarte restrictiv: doar VP8/VP9/AV1 + Opus/Vorbis + WebVTT
            if [[ -n "$video_codec" ]] && ! echo "$video_codec" | grep -qiE "^(vp8|vp9|av1)$"; then
                REMUX_PREFLIGHT_NOTES+=("Video '$video_codec' incompatibil cu WEBM (doar VP8/VP9/AV1 suportate) — abort")
                REMUX_PREFLIGHT_LEVEL=2
            fi
            echo "$audio_codecs" | grep -qiE "^(aac|ac3|eac3|mp3|dts|truehd|alac|pcm_s16le|pcm_s24le)$" && {
                REMUX_PREFLIGHT_NOTES+=("Audio incompatibil cu WEBM (doar Opus/Vorbis suportate) — va fi strip-uit")
                [ $REMUX_PREFLIGHT_LEVEL -lt 1 ] && REMUX_PREFLIGHT_LEVEL=1
            }
            echo "$sub_codecs" | grep -qiE "^(subrip|srt|ass|ssa|dvd_subtitle|hdmv_pgs_subtitle|mov_text)$" && {
                REMUX_PREFLIGHT_NOTES+=("Subtitrari incompatibile cu WEBM (doar WebVTT) — vor fi strip-uite")
                [ $REMUX_PREFLIGHT_LEVEL -lt 1 ] && REMUX_PREFLIGHT_LEVEL=1
            }
            [ "$attach_count" -gt 0 ] && {
                REMUX_PREFLIGHT_NOTES+=("$attach_count atasament(e) — WEBM nu suporta, vor fi strip-uite")
                [ $REMUX_PREFLIGHT_LEVEL -lt 1 ] && REMUX_PREFLIGHT_LEVEL=1
            }
            ;;
        mkv)
            : # MKV permisiv — toate codec-urile/track-urile suportate
            ;;
        *)
            REMUX_PREFLIGHT_NOTES+=("Container '$target' nesuportat (foloseste mkv/mp4/mov/webm)")
            REMUX_PREFLIGHT_LEVEL=2
            ;;
    esac
    return $REMUX_PREFLIGHT_LEVEL
}

# v49: clasificare per-stream pentru target container.
# $1 = codec_name, $2 = codec_type (video/audio/subtitle/attachment),
# $3 = target_container (mkv|mp4|mov|webm)
# Echo: "copy" | "convert:<codec>" | "drop"
remux_stream_compat() {
    local codec="$1" ctype="$2" target="$3"
    codec="${codec,,}"; ctype="${ctype,,}"; target="${target,,}"
    case "$target" in
        mkv) echo "copy"; return 0 ;;
    esac
    case "$ctype" in
        video)
            case "$target" in
                mp4)
                    case "$codec" in
                        hevc|h264|av1|mpeg4|mpeg2video|vp9|prores) echo "copy" ;;
                        *) echo "drop" ;;
                    esac ;;
                mov)
                    case "$codec" in
                        hevc|h264|prores|dnxhd|dnxhr|mpeg4|mjpeg) echo "copy" ;;
                        *) echo "drop" ;;
                    esac ;;
                webm)
                    case "$codec" in
                        vp8|vp9|av1) echo "copy" ;;
                        *) echo "drop" ;;
                    esac ;;
                *) echo "drop" ;;
            esac ;;
        audio)
            case "$target" in
                mp4)
                    case "$codec" in
                        aac|ac3|eac3|mp3|opus|alac|flac) echo "copy" ;;
                        *) echo "drop" ;;
                    esac ;;
                mov)
                    case "$codec" in
                        aac|ac3|mp3|alac|pcm_s16be|pcm_s24be|pcm_s16le|pcm_s24le) echo "copy" ;;
                        eac3|opus|truehd|dts) echo "drop" ;;
                        *) echo "drop" ;;
                    esac ;;
                webm)
                    case "$codec" in
                        opus|vorbis) echo "copy" ;;
                        *) echo "drop" ;;
                    esac ;;
                *) echo "drop" ;;
            esac ;;
        subtitle)
            case "$target" in
                mp4|mov)
                    case "$codec" in
                        mov_text|tx3g) echo "copy" ;;
                        subrip|srt|ass|ssa) echo "convert:mov_text" ;;
                        *) echo "drop" ;;
                    esac ;;
                webm)
                    case "$codec" in webvtt) echo "copy" ;; *) echo "drop" ;; esac ;;
                *) echo "drop" ;;
            esac ;;
        attachment) echo "drop" ;;
        *) echo "drop" ;;
    esac
}

# v49: enumerate toate stream-urile + chapters + attachments.
# $1 = file
# Populeaza arrays globale:
#   REMUX_STREAMS[idx]="type|codec|lang|title|extra"
#     type: video|audio|subtitle|attachment
#     extra: pentru video "WxH"; pentru audio "channels"; altele ""
#   REMUX_VIDEO_INDICES[] / REMUX_AUDIO_INDICES[] / REMUX_SUB_INDICES[] / REMUX_ATTACH_INDICES[]
#     valori absolute (stream_index din ffprobe)
#   REMUX_CHAPTER_COUNT (int)
declare -a REMUX_STREAMS=()
declare -a REMUX_VIDEO_INDICES=()
declare -a REMUX_AUDIO_INDICES=()
declare -a REMUX_SUB_INDICES=()
declare -a REMUX_ATTACH_INDICES=()
REMUX_CHAPTER_COUNT=0

remux_enumerate_streams() {
    local file="$1"
    REMUX_STREAMS=(); REMUX_VIDEO_INDICES=(); REMUX_AUDIO_INDICES=()
    REMUX_SUB_INDICES=(); REMUX_ATTACH_INDICES=(); REMUX_CHAPTER_COUNT=0

    local raw idx codec w h lang title ch

    # v59 audit: csv=p=0 emite trailing comma pe surse cu [SIDE_DATA] sections (HDR10/
    # HDR10+/HEVC HDR) → ultimul field primeste "value," in loc de "value". Display
    # arata "Title text," urat. Pe attachment-uri cu nume care nu se foloseste exact
    # in compare (doar afisare) impactul e cosmetic, dar tot defensiv strip.

    # Video: index,codec_name,width,height,language,title
    raw=$(ffprobe -v error -select_streams v -show_entries \
        stream=index,codec_name,width,height:stream_tags=language,title \
        -of csv=p=0 "$file" 2>/dev/null || true)
    while IFS=',' read -r idx codec w h lang title; do
        [ -z "$idx" ] && continue
        title="${title%$'\r'}"; title="${title%,}"   # v59 audit
        REMUX_STREAMS[$idx]="video|${codec}|${lang}|${title}|${w}x${h}"
        REMUX_VIDEO_INDICES+=("$idx")
    done <<< "$raw"

    # Audio: index,codec_name,channels,language,title
    raw=$(ffprobe -v error -select_streams a -show_entries \
        stream=index,codec_name,channels:stream_tags=language,title \
        -of csv=p=0 "$file" 2>/dev/null || true)
    while IFS=',' read -r idx codec ch lang title; do
        [ -z "$idx" ] && continue
        title="${title%$'\r'}"; title="${title%,}"   # v59 audit
        REMUX_STREAMS[$idx]="audio|${codec}|${lang}|${title}|${ch}ch"
        REMUX_AUDIO_INDICES+=("$idx")
    done <<< "$raw"

    # Subtitle: index,codec_name,language,title
    raw=$(ffprobe -v error -select_streams s -show_entries \
        stream=index,codec_name:stream_tags=language,title \
        -of csv=p=0 "$file" 2>/dev/null || true)
    while IFS=',' read -r idx codec lang title; do
        [ -z "$idx" ] && continue
        title="${title%$'\r'}"; title="${title%,}"   # v59 audit
        REMUX_STREAMS[$idx]="subtitle|${codec}|${lang}|${title}|"
        REMUX_SUB_INDICES+=("$idx")
    done <<< "$raw"

    # Attachments: index,codec_name + filename tag
    raw=$(ffprobe -v error -select_streams t -show_entries \
        stream=index,codec_name:stream_tags=filename \
        -of csv=p=0 "$file" 2>/dev/null || true)
    while IFS=',' read -r idx codec title; do
        [ -z "$idx" ] && continue
        title="${title%$'\r'}"; title="${title%,}"   # v59 audit
        REMUX_STREAMS[$idx]="attachment|${codec}||${title}|"
        REMUX_ATTACH_INDICES+=("$idx")
    done <<< "$raw"

    REMUX_CHAPTER_COUNT=$(ffprobe -v error -show_chapters -of csv=p=0 "$file" 2>/dev/null | grep -c . || true)
    return 0
}

# Re-mux un container, fix tag:v pe MP4/MOV, +faststart, no re-encode.
# $1 = input, $2 = output, $3 = target_container (mp4/mov/mkv)
# Return: 0=OK, 1=fail.
remux_container_with_tag() {
    local input="$1" output="$2" target="$3"
    target="${target,,}"
    local src_codec
    src_codec=$(detect_source_codec "$input")

    local extra_args=""
    local sub_args="-c:s copy"   # MKV permisiv — copy nativ pentru SRT/ASS/PGS
    if [[ "$target" == "mp4" || "$target" == "mov" ]]; then
        case "$src_codec" in
            hevc) extra_args="-tag:v hvc1 -movflags +faststart" ;;
            av1)  extra_args="-tag:v av01 -movflags +faststart" ;;
            h264) extra_args="-tag:v avc1 -movflags +faststart" ;;
            *)    extra_args="-movflags +faststart" ;;
        esac
        sub_args="-c:s mov_text"  # MP4/MOV: convertim text-based la mov_text
    fi

    # shellcheck disable=SC2086
    ffmpeg -v error -i "$input" -map 0 -c copy $sub_args $extra_args "$output" 2>/dev/null
    local rc=$?
    if [ $rc -ne 0 ] || [ ! -s "$output" ]; then
        # Retry fara subtitrari (cazul cand source are subs incompat cu target)
        rm -f "$output"
        ffmpeg -v error -i "$input" -map 0:v -map 0:a? -map 0:t? -c copy $extra_args "$output" 2>/dev/null
        rc=$?
    fi
    [ $rc -eq 0 ] && [ -s "$output" ] && return 0 || return 1
}

# ══════════════════════════════════════════════════════════════════════
# STREAM COPY HELPER — cod partajat pentru stream copy cu stats
# Return: 0=OK, non-zero=eroare
# ══════════════════════════════════════════════════════════════════════
do_stream_copy() {
    local file="$1" output="$2" map_flags="$3" audio_override="${4:-}"
    START_TIME=$(date +%s)
    local sc_audio sc_sub sc_cflags sc_pf sc_pid
    # v68: al 4-lea arg optional = audio-params deja calculate (per-pista din
    # handle_multi_audio_dialog). Default (fara arg) = recalcul get_audio_params
    # (back-compat pt ceilalti apelanti). Smart-copy il paseaza ca sa onoreze
    # selectia per-pista (paritate cu PS1 Invoke-StreamCopy).
    if [[ -n "$audio_override" ]]; then sc_audio="$audio_override"; else sc_audio=$(get_audio_params "$file"); fi
    sc_sub=$(get_subtitle_codec "$file")
    sc_cflags=$(get_container_flags); sc_pf=$(mktemp); PROGRESS_FILE="$sc_pf"
    # shellcheck disable=SC2086
    ffmpeg -threads "$THREADS" -i "$file" $map_flags \
        -c:v copy $sc_audio $sc_sub -c:t copy \
        $sc_cflags -progress "$sc_pf" -nostats "$output" 2>>"$LOG_FILE" &
    sc_pid=$!; _show_progress "$sc_pid" "$sc_pf" "$file" "Stream copy"; wait "$sc_pid"
    local sc_rc=$?; PROGRESS_FILE=""
    if [ $sc_rc -eq 0 ]; then
        # v71: stream-copy al unui DV HEVC → ffmpeg pierde dvcC de container → re-scrie
        # (mkvmerge/MP4Box). No-op pe non-DV / non-ISO/mkv. Inainte de NEW_SIZE (re-mux).
        local _sc_ext="${output##*.}"; _sc_ext="${_sc_ext,,}"
        _dv_resignal_copy "$file" "$output" "$_sc_ext"
        # v78: stream-copy al unei surse DJI → ffmpeg dropeaza djmd (codec=none) → re-grefeaza
        # GPS-ul nativ pe MP4/MOV (acelasi hook ca pe calea de encode). No-op pe non-DJI / non-ISO.
        _dji_preserve_meta_postencode "$file" "$output"
        NEW_SIZE=$(av_stat_size "$output" 2>/dev/null || echo 0)
        SAVED=$(( ORIGINAL_SIZE - NEW_SIZE )); [ $SAVED -lt 0 ] && SAVED=0
        TOTAL_SAVED=$(( TOTAL_SAVED+SAVED ))
        ENCODE_TIME=$(( $(date +%s) - START_TIME )); TOTAL_DONE=$((TOTAL_DONE+1))
        log "  Stream copy OK: $(( NEW_SIZE/1024/1024 )) MB | ${ENCODE_TIME}s"
        BATCH_NAMES+=("$filename"); BATCH_TIMES+=("$ENCODE_TIME")
        BATCH_ORIG+=("$ORIGINAL_SIZE"); BATCH_NEW+=("$NEW_SIZE")
        [ "$ORIGINAL_SIZE" -gt 0 ] && BATCH_RATIOS+=("$(awk "BEGIN{printf \"%.1f\", $NEW_SIZE * 100.0 / $ORIGINAL_SIZE}")") || BATCH_RATIOS+=("N/A")
        batch_mark_done "$filename"
    fi
    return $sc_rc
}

# ══════════════════════════════════════════════════════════════════════
# DIALOG ANALIZA SURSA — per fisier, pentru HDR10 si SDR (x265/AV1)
# Afisat cand sursa NU este DV, HDR10+, sau LOG.
# Return: 0=encode cu setarile alese, 97=stream copy, 98=skip
# Seteaza: SRC_DIALOG_MODE (hdr10/sdr_tonemap/sdr)
# ══════════════════════════════════════════════════════════════════════
handle_source_dialog() {
    local file="$1" filename="$2" encoder_type="$3"
    SRC_DIALOG_MODE=""

    # Detect source characteristics for display
    local src_pixfmt src_bitdepth="8-bit" src_label
    # v62 audit: default= + head -1 (csv=p=0 single-field emite trailing comma pe surse HDR)
    src_pixfmt=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=pix_fmt -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1)
    [[ "$src_pixfmt" == *"10"* ]] && src_bitdepth="10-bit"

    local is_hdr10=0
    [[ "$HDR_TYPE" == *"smpte2084"* ]] && is_hdr10=1

    if [ "$is_hdr10" -eq 1 ]; then
        src_label="HDR10 $src_bitdepth"
    else
        src_label="SDR $src_bitdepth"
    fi

    echo ""
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║  ANALIZA SURSA                               ║"
    printf "  ║  Fisier: %-37s║\n" "$filename"
    printf "  ║  Sursa : %-25s %s║\n" "$src_label |" "${WIDTH}x${HEIGHT}"
    echo "  ╠══════════════════════════════════════════════╣"

    if [ "$is_hdr10" -eq 1 ]; then
        echo "  ║  1) Encodeaza HDR10 10-bit                   ║"
        echo "  ║  2) Converteste la HLG 10-bit (BT.2100)      ║"
        echo "  ║  3) Encodeaza SDR 10-bit (tonemap Rec.709)   ║"
        echo "  ║  4) Stream copy video                        ║"
        echo "  ║  5) Sari acest fisier                        ║"
        echo "  ╚══════════════════════════════════════════════╝"
        read -p "  Alege 1-5 [implicit: 1]: " src_choice
        case "${src_choice:-1}" in
            2) log "  Ales: HLG 10-bit (din HDR10)"
               SRC_DIALOG_MODE="hdr10_to_hlg"
               return 0 ;;
            3) log "  Ales: SDR 10-bit (tonemap din HDR10)"
               SRC_DIALOG_MODE="sdr_tonemap"
               return 0 ;;
            4) log "  Ales: Stream copy video"
               return 97 ;;
            5) log "  Sarit de utilizator"
               return 98 ;;
            *) log "  Ales: HDR10 10-bit"
               SRC_DIALOG_MODE="hdr10"
               ask_hdr10_measure_cll   # v63: opt-in MaxCLL/MaxFALL real
               return 0 ;;
        esac
    else
        echo "  ║  1) Encodeaza 10-bit SDR                     ║"
        echo "  ║  2) Stream copy video                        ║"
        echo "  ║  3) Sari acest fisier                        ║"
        echo "  ╚══════════════════════════════════════════════╝"
        read -p "  Alege 1-3 [implicit: 1]: " src_choice
        case "${src_choice:-1}" in
            2) log "  Ales: Stream copy video"
               return 97 ;;
            3) log "  Sarit de utilizator"
               return 98 ;;
            *) log "  Ales: 10-bit SDR"
               SRC_DIALOG_MODE="sdr"
               return 0 ;;
        esac
    fi
}

# ══════════════════════════════════════════════════════════════════════
# v39: HLG DIALOG — pentru surse HLG (BT.2100 HLG, transfer=arib-std-b67)
# Set HLG_DIALOG_MODE: hlg_native | hlg_to_hdr10 | hlg_to_sdr
# Return: 0 = proceed | 97 = stream copy | 98 = skip
# ══════════════════════════════════════════════════════════════════════
handle_hlg_dialog() {
    local file="$1" filename="$2" encoder_type="$3"
    HLG_DIALOG_MODE=""

    echo ""
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║  ANALIZA SURSA — HLG (BT.2100 HLG)           ║"
    printf "  ║  Fisier: %-37s║\n" "$filename"
    printf "  ║  Sursa : HLG 10-bit %-25s║\n" "${WIDTH}x${HEIGHT}"
    echo "  ╠══════════════════════════════════════════════╣"
    echo "  ║  1) Encodeaza HLG nativ (recomandat)         ║"
    echo "  ║  2) Converteste la HDR10 (PQ)                ║"
    echo "  ║  3) Tonemap la SDR (Rec.709)                 ║"
    echo "  ║  4) Stream copy video                        ║"
    echo "  ║  5) Sari acest fisier                        ║"
    echo "  ╚══════════════════════════════════════════════╝"
    read -p "  Alege 1-5 [implicit: 1]: " hlg_choice
    case "${hlg_choice:-1}" in
        2) log "  Ales: HLG → HDR10 (PQ)"; HLG_DIALOG_MODE="hlg_to_hdr10"; ask_hdr10_measure_cll; return 0 ;;
        3) log "  Ales: HLG → SDR tonemap (Rec.709)"; HLG_DIALOG_MODE="hlg_to_sdr"; return 0 ;;
        4) log "  Ales: Stream copy video"; return 97 ;;
        5) log "  Sarit de utilizator"; return 98 ;;
        *) log "  Ales: HLG nativ"; HLG_DIALOG_MODE="hlg_native"; return 0 ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════
# v38/v39: MEDIACODEC HDR DIALOG — uniformizat pentru DV / HDR10+ / HDR10 / HLG
# Apelat DOAR cand userul a selectat MediaCodec ca encoder.
# Param: source_type = dv|hdr10plus|hdr10|hlg ; dv_profile (optional)
# Set MC_HDR_MODE global:
#   sw_full     — fallback SW cu preservare completa (DV native, HDR10+ dynamic, HLG nativ SW)
#   sw_degraded — fallback SW degradat (DV→HDR10 BL, HDR10+→HDR10 static)
#   hw_repair   — MediaCodec 10-bit + signaling repair via hevc_metadata bsf
#   hw_hlg      — v39: MediaCodec HLG nativ 10-bit (transfer=arib-std-b67, fără SEI repair)
#   hw_sdr      — MediaCodec SDR tonemap 8-bit (proxy)
# Override prin profile field MEDIACODEC_HDR_POLICY=sw_full|sw_degraded|hw_repair|hw_hlg|hw_sdr|skip
# Return: 0 = proceed cu MC_HDR_MODE setat | 98 = skip
# ══════════════════════════════════════════════════════════════════════
show_hdr_mediacodec_dialog() {
    local source_type="$1" dv_profile="${2:-}" enc_codec="${3:-}" src_codec="${4:-}"
    MC_HDR_MODE=""

    # v46: gate hw_preserve (DV preserve via MediaCodec - HEVC/AV1 only + tools)
    local _can_hw_preserve=0
    if [[ "$source_type" == "dv" ]] && [[ "$enc_codec" == "hevc" || "$enc_codec" == "av1" ]]; then
        if _check_dovi_tool_for "${src_codec:-hevc}" && _check_dovi_tool_for "$enc_codec"; then
            _can_hw_preserve=1
        fi
    fi

    # Profile bypass
    if [[ -n "${MEDIACODEC_HDR_POLICY:-}" ]]; then
        case "$MEDIACODEC_HDR_POLICY" in
            sw_full|sw_degraded|hw_repair|hw_sdr|hw_hlg)
                MC_HDR_MODE="$MEDIACODEC_HDR_POLICY"
                log "  MediaCodec HDR policy din profil: $MC_HDR_MODE"
                return 0 ;;
            hw_preserve)
                if [ $_can_hw_preserve -eq 1 ]; then
                    MC_HDR_MODE="hw_preserve"
                    log "  MediaCodec HDR policy: hw_preserve (DV preserve via MC)"
                    return 0
                else
                    MC_HDR_MODE="hw_repair"
                    log "  MediaCodec HDR policy=hw_preserve dar tool DV indisponibil — fallback hw_repair"
                    return 0
                fi ;;
            skip)
                log "  MediaCodec HDR policy din profil: skip"
                return 98 ;;
        esac
    fi

    echo ""
    echo "  ╔══════════════════════════════════════════════════════╗"
    case "$source_type" in
        dv)
            echo "  ║  ⚠ Sursa este Dolby Vision — ${dv_profile:-profil nedetectat}"
            echo "  ║  MediaCodec nu poate produce DV nativ. Optiuni:"
            echo "  ╠══════════════════════════════════════════════════════╣"
            echo "  ║  1) SW libx265 — pastreaza DV complet (recomandat)"
            echo "  ║  2) SW libx265 — strip DV, pastreaza HDR10 BL"
            if [ $_can_hw_preserve -eq 1 ]; then
                echo "  ║  3) MediaCodec — DV preserve (HDR10 base + inject RPU)"
                echo "  ║     extrage RPU sursa ($src_codec) -> MC encode -> repair SEI -> inject"
                echo "  ║  4) MediaCodec — strip DV → HDR10 10-bit + repair"
                echo "  ║  5) MediaCodec — strip DV → SDR tonemap 8-bit (proxy)"
                echo "  ║  6) Skip fisier"
                echo "  ╚══════════════════════════════════════════════════════╝"
                read -p "  Alege 1-6 [implicit: 1]: " _mc_ch
                case "${_mc_ch:-1}" in
                    2) MC_HDR_MODE="sw_degraded"; log "  Ales: SW libx265 strip DV → HDR10 BL" ;;
                    3) MC_HDR_MODE="hw_preserve"; log "  Ales: MediaCodec DV preserve via post-encode inject" ;;
                    4) MC_HDR_MODE="hw_repair";   log "  Ales: MediaCodec HDR10 10-bit + signaling repair" ;;
                    5) MC_HDR_MODE="hw_sdr";      log "  Ales: MediaCodec SDR tonemap 8-bit (proxy)" ;;
                    6) log "  Sarit de utilizator"; return 98 ;;
                    *) MC_HDR_MODE="sw_full";     log "  Ales: SW libx265 cu DV complet" ;;
                esac
            else
                echo "  ║  3) MediaCodec — strip DV → HDR10 10-bit + repair"
                echo "  ║  4) MediaCodec — strip DV → SDR tonemap 8-bit (proxy)"
                echo "  ║  5) Skip fisier"
                echo "  ╚══════════════════════════════════════════════════════╝"
                read -p "  Alege 1-5 [implicit: 1]: " _mc_ch
                case "${_mc_ch:-1}" in
                    2) MC_HDR_MODE="sw_degraded"; log "  Ales: SW libx265 strip DV → HDR10 BL" ;;
                    3) MC_HDR_MODE="hw_repair";   log "  Ales: MediaCodec HDR10 10-bit + signaling repair" ;;
                    4) MC_HDR_MODE="hw_sdr";      log "  Ales: MediaCodec SDR tonemap 8-bit (proxy)" ;;
                    5) log "  Sarit de utilizator"; return 98 ;;
                    *) MC_HDR_MODE="sw_full";     log "  Ales: SW libx265 cu DV complet" ;;
                esac
            fi
            ;;
        hdr10plus)
            echo "  ║  ⚠ Sursa este HDR10+ (cu dynamic metadata)"
            echo "  ║  MediaCodec nu transmite dynamic metadata. Optiuni:"
            echo "  ╠══════════════════════════════════════════════════════╣"
            echo "  ║  1) SW libx265 — pastreaza HDR10+ complet (recomandat)"
            echo "  ║  2) SW libx265 — encode ca HDR10 static (drop dynamic)"
            echo "  ║  3) MediaCodec — HDR10 10-bit + repair (drop dynamic)"
            echo "  ║  4) MediaCodec — SDR tonemap 8-bit (proxy)"
            echo "  ║  5) Skip fisier"
            echo "  ╚══════════════════════════════════════════════════════╝"
            read -p "  Alege 1-5 [implicit: 1]: " _mc_ch
            case "${_mc_ch:-1}" in
                2) MC_HDR_MODE="sw_degraded"; log "  Ales: SW libx265 HDR10 static (drop dynamic)" ;;
                3) MC_HDR_MODE="hw_repair";   log "  Ales: MediaCodec HDR10 10-bit + signaling repair" ;;
                4) MC_HDR_MODE="hw_sdr";      log "  Ales: MediaCodec SDR tonemap 8-bit (proxy)" ;;
                5) log "  Sarit de utilizator"; return 98 ;;
                *) MC_HDR_MODE="sw_full";     log "  Ales: SW libx265 cu HDR10+ complet" ;;
            esac
            ;;
        hlg)
            echo "  ║  ⚠ Sursa este HLG (BT.2100 HLG)"
            echo "  ║  MediaCodec poate transmite signaling HLG nativ. Optiuni:"
            echo "  ╠══════════════════════════════════════════════════════╣"
            echo "  ║  1) MediaCodec — HLG nativ 10-bit (recomandat)"
            echo "  ║  2) SW libx265 — HLG nativ 10-bit"
            echo "  ║  3) MediaCodec — HLG → HDR10 (PQ) + signaling repair"
            echo "  ║  4) MediaCodec — HLG → SDR tonemap 8-bit"
            echo "  ║  5) Skip fisier"
            echo "  ╚══════════════════════════════════════════════════════╝"
            read -p "  Alege 1-5 [implicit: 1]: " _mc_ch
            case "${_mc_ch:-1}" in
                2) MC_HDR_MODE="sw_full";   log "  Ales: SW libx265 HLG nativ" ;;
                3) MC_HDR_MODE="hw_repair"; log "  Ales: MediaCodec HLG → HDR10 + signaling repair" ;;
                4) MC_HDR_MODE="hw_sdr";    log "  Ales: MediaCodec SDR tonemap 8-bit" ;;
                5) log "  Sarit de utilizator"; return 98 ;;
                *) MC_HDR_MODE="hw_hlg";    log "  Ales: MediaCodec HLG nativ 10-bit" ;;
            esac
            ;;
        hdr10|*)
            echo "  ║  ⚠ Sursa este HDR10"
            echo "  ║  MediaCodec necesita signaling repair. Optiuni:"
            echo "  ╠══════════════════════════════════════════════════════╣"
            echo "  ║  1) SW libx265 — HDR10 nativ (recomandat)"
            echo "  ║  2) MediaCodec — HDR10 10-bit + signaling repair"
            echo "  ║  3) MediaCodec — SDR tonemap 8-bit (proxy)"
            echo "  ║  4) Skip fisier"
            echo "  ╚══════════════════════════════════════════════════════╝"
            read -p "  Alege 1-4 [implicit: 1]: " _mc_ch
            case "${_mc_ch:-1}" in
                2) MC_HDR_MODE="hw_repair"; log "  Ales: MediaCodec HDR10 10-bit + signaling repair" ;;
                3) MC_HDR_MODE="hw_sdr";    log "  Ales: MediaCodec SDR tonemap 8-bit (proxy)" ;;
                4) log "  Sarit de utilizator"; return 98 ;;
                *) MC_HDR_MODE="sw_full";   log "  Ales: SW libx265 HDR10 nativ" ;;
            esac
            ;;
    esac
    return 0
}

# ══════════════════════════════════════════════════════════════════════
# v38: HDR10 SIGNALING REPAIR — post-encode bsf hevc_metadata
# Repara SEI mastering_display + max_cll/max_fall pierdute de hevc_mediacodec.
# Args: $1 = encoded_file (hevc/mp4 in-place fix via temp)
#       $2 = master_display string (optional, ex: "G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,1)")
#       $3 = max_cll string (optional, ex: "1000,400")
# Daca $2/$3 lipsesc, citeste din source via ffprobe (pasat prin env: MC_REPAIR_SRC)
# Return: 0 OK | non-zero error
# ══════════════════════════════════════════════════════════════════════
repair_hdr10_signaling() {
    local encoded="$1" md_str="${2:-}" cll_str="${3:-}"
    [[ ! -f "$encoded" ]] && return 1

    # Daca lipsesc, extrage din sursa originala
    if [[ -z "$md_str" || -z "$cll_str" ]] && [[ -n "${MC_REPAIR_SRC:-}" && -f "$MC_REPAIR_SRC" ]]; then
        local sd_json
        # v63: `frame_side_data` (robust, ca av_check) in loc de `frame_side_data_list` (varianta
        # non-standard pe selectorul fragil; mergea cu -show_frames, dar uniformizam metadata).
        sd_json=$(ffprobe -v error -select_streams v:0 -read_intervals "%+#1" \
            -show_frames -show_entries frame_side_data \
            -of default=nw=1 "$MC_REPAIR_SRC" 2>/dev/null)
        # Mastering display: format ffmpeg "G(x,y)B(x,y)R(x,y)WP(x,y)L(max,min)"
        if [[ -z "$md_str" ]]; then
            local r_x r_y g_x g_y b_x b_y wp_x wp_y l_max l_min
            r_x=$(echo "$sd_json" | grep -oP "red_x=\K[0-9/]+" | head -1)
            r_y=$(echo "$sd_json" | grep -oP "red_y=\K[0-9/]+" | head -1)
            g_x=$(echo "$sd_json" | grep -oP "green_x=\K[0-9/]+" | head -1)
            g_y=$(echo "$sd_json" | grep -oP "green_y=\K[0-9/]+" | head -1)
            b_x=$(echo "$sd_json" | grep -oP "blue_x=\K[0-9/]+" | head -1)
            b_y=$(echo "$sd_json" | grep -oP "blue_y=\K[0-9/]+" | head -1)
            wp_x=$(echo "$sd_json" | grep -oP "white_point_x=\K[0-9/]+" | head -1)
            wp_y=$(echo "$sd_json" | grep -oP "white_point_y=\K[0-9/]+" | head -1)
            l_max=$(echo "$sd_json" | grep -oP "max_luminance=\K[0-9/]+" | head -1)
            l_min=$(echo "$sd_json" | grep -oP "min_luminance=\K[0-9/]+" | head -1)
            if [[ -n "$g_x" && -n "$r_x" && -n "$wp_x" && -n "$l_max" ]]; then
                # Convert ratios numerator/denominator → integer scaled (50000 pentru chroma, 10000 pentru luminance)
                md_str="G($(awk -F/ '{printf "%d", ($1*50000)/$2}' <<< "$g_x"),$(awk -F/ '{printf "%d", ($1*50000)/$2}' <<< "$g_y"))B($(awk -F/ '{printf "%d", ($1*50000)/$2}' <<< "$b_x"),$(awk -F/ '{printf "%d", ($1*50000)/$2}' <<< "$b_y"))R($(awk -F/ '{printf "%d", ($1*50000)/$2}' <<< "$r_x"),$(awk -F/ '{printf "%d", ($1*50000)/$2}' <<< "$r_y"))WP($(awk -F/ '{printf "%d", ($1*50000)/$2}' <<< "$wp_x"),$(awk -F/ '{printf "%d", ($1*50000)/$2}' <<< "$wp_y"))L($(awk -F/ '{printf "%d", ($1*10000)/$2}' <<< "$l_max"),$(awk -F/ '{printf "%d", ($1*10000)/$2}' <<< "$l_min"))"
            fi
        fi
        if [[ -z "$cll_str" ]]; then
            local mcll mfall
            mcll=$(echo "$sd_json" | grep -oP "max_content=\K[0-9]+" | head -1)
            mfall=$(echo "$sd_json" | grep -oP "max_average=\K[0-9]+" | head -1)
            [[ -n "$mcll" && -n "$mfall" ]] && cll_str="${mcll},${mfall}"
        fi
    fi

    # Defaults conservative daca tot lipsesc — Rec.2020 + 1000/400 nits
    [[ -z "$md_str" ]] && md_str="G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)"
    [[ -z "$cll_str" ]] && cll_str="1000,400"

    local tmp_out
    tmp_out=$(av_mktemp_ext "${encoded##*.}")
    log "  HDR10 signaling repair: injectez mastering_display + max_cll..."
    ffmpeg -v error -y -i "$encoded" -c copy \
        -bsf:v "hevc_metadata=mastering_display=${md_str}:max_content=${cll_str%,*}:max_average=${cll_str#*,}:colour_primaries=9:transfer_characteristics=16:matrix_coefficients=9" \
        -movflags +faststart "$tmp_out" 2>>"${LOG_FILE:-/dev/null}"
    local rc=$?
    if [ $rc -eq 0 ] && [ -s "$tmp_out" ]; then
        mv -f "$tmp_out" "$encoded"
        log "  HDR10 signaling repair OK"
        return 0
    fi
    rm -f "$tmp_out"
    log "  HDR10 signaling repair FAILED (rc=$rc) — output ramane fara SEI HDR"
    return 1
}

# ══════════════════════════════════════════════════════════════════════
# LOG FORMAT VIDEO — LUT search + dialog per fisier
# Suporta: Apple Log, Samsung Log, DJI D-Log M, unknown Log
# LUT-uri cautate cu prefix: apple_log_*, samsung_log_*, dji_dlog_m_*
# ══════════════════════════════════════════════════════════════════════

# Cauta fisiere .cube pentru brand-ul detectat.
# Locatie: $LUTS_DIR (definit sus)
# Seteaza: LUT_FILES (array), LUT_SEARCH_DIR (unde a gasit)
find_lut_for_brand() {
    LUT_FILES=()
    LUT_SEARCH_DIR=""
    local brand="$1"
    local prefix=""
    case "$brand" in
        apple)   prefix="apple_log_" ;;
        samsung) prefix="samsung_log_" ;;
        dji)     prefix="dji_dlog_m_" ;;
        *)       prefix="" ;;
    esac

    local luts_dir="$LUTS_DIR"
    [[ ! -d "$luts_dir" ]] && return 1

    local found=()
    if [[ -n "$prefix" ]]; then
        shopt -s nullglob nocaseglob
        found=("$luts_dir"/${prefix}*.cube)
        shopt -u nocaseglob nullglob
    fi
    # v62: daca nu exista LUT cu prefix de brand, cadem pe TOATE .cube din Luts/ (pentru
    # ORICE brand, nu doar unknown). Acum ca LUT-ul e obligatoriu pentru transformare,
    # userul poate folosi orice LUT are la indemana (vede numele in dialog si alege).
    if [[ ${#found[@]} -eq 0 ]]; then
        shopt -s nullglob nocaseglob
        found=("$luts_dir"/*.cube)
        shopt -u nocaseglob nullglob
    fi
    if [[ ${#found[@]} -gt 0 ]]; then
        LUT_FILES=("${found[@]}")
        LUT_SEARCH_DIR="$luts_dir"
        return 0
    fi
    return 1
}

# v39: Cauta LUT-uri Log → HLG (BT.2100). Nume convenite: hlg_<brand>_*.cube
# Ex: hlg_apple_log_v1.cube, hlg_dji_dlog_m.cube
# Seteaza: HLG_LUT_FILES (array)
find_hlg_lut_for_brand() {
    HLG_LUT_FILES=()
    local brand="$1"
    local prefix=""
    case "$brand" in
        apple)   prefix="hlg_apple_log_" ;;
        samsung) prefix="hlg_samsung_log_" ;;
        dji)     prefix="hlg_dji_dlog_m_" ;;
        *)       prefix="hlg_" ;;
    esac

    [[ ! -d "$LUTS_DIR" ]] && return 1
    local found=()
    shopt -s nullglob nocaseglob
    found=("$LUTS_DIR"/${prefix}*.cube)
    shopt -u nocaseglob nullglob
    if [[ ${#found[@]} -gt 0 ]]; then
        HLG_LUT_FILES=("${found[@]}")
        return 0
    fi
    return 1
}

# Cauta fisiere .cube creative in $LUTS_DIR/Creative/
# Seteaza: CREATIVE_LUT_FILES (array), CREATIVE_LUT_DIR
find_creative_luts() {
    CREATIVE_LUT_FILES=()
    CREATIVE_LUT_DIR=""
    local creative_dir="$LUTS_DIR/Creative"
    [[ ! -d "$creative_dir" ]] && return 1

    local found=()
    shopt -s nullglob nocaseglob
    found=("$creative_dir"/*.cube)
    shopt -u nocaseglob nullglob

    if [[ ${#found[@]} -gt 0 ]]; then
        CREATIVE_LUT_FILES=("${found[@]}")
        CREATIVE_LUT_DIR="$creative_dir"
        return 0
    fi
    return 1
}

# Returneaza label-ul human-readable pentru LOG_PROFILE
_log_profile_label() {
    case "$1" in
        apple_log)   echo "Apple Log (iPhone)" ;;
        samsung_log) echo "Samsung Log (S24 Ultra)" ;;
        dlog_m)      echo "D-Log M (DJI)" ;;
        forced_log)  echo "LOG (fortat manual)" ;;
        unknown_log) echo "LOG (brand necunoscut)" ;;
        *)           echo "LOG" ;;
    esac
}

# Dialog LOG per fisier.
# Apelat din encoder_setup_file() cand LOG_PROFILE e setat.
# Seteaza: LOG_VIDEO_FILTER, LOG_COLOR_FLAGS, LOG_PIX_FMT, LOG_EXTRA_X265
# Return: 0=encode cu LOG settings, 97=stream copy, 98=skip
handle_log_dialog() {
    local file="$1" filename="$2" encoder_type="$3"
    LOG_VIDEO_FILTER=""
    LOG_COLOR_FLAGS=""
    LOG_PIX_FMT=""
    LOG_EXTRA_X265=""
    LOG_EXTRA_X264=""   # v62 Bug2: culoare in x264-params (LUT Rec.709 / Creative)
    # Nota: av1/svtav1 NU are nevoie de var aici — av_encoder_av1.sh deriva VUI-ul
    # corect din $color_params (mecanismul _av1_vui, v52). x265 = LOG_EXTRA_X265.

    local profile_label
    profile_label=$(_log_profile_label "$LOG_PROFILE")

    # Search for LUT files
    find_lut_for_brand "$CAMERA_MAKE"
    local has_lut=0
    [[ ${#LUT_FILES[@]} -gt 0 ]] && has_lut=1
    find_hlg_lut_for_brand "$CAMERA_MAKE"
    local has_hlg_lut=0
    [[ ${#HLG_LUT_FILES[@]} -gt 0 ]] && has_hlg_lut=1
    find_creative_luts
    local has_creative_lut=0
    [[ ${#CREATIVE_LUT_FILES[@]} -gt 0 ]] && has_creative_lut=1

    echo ""
    echo "  ╔══════════════════════════════════════════════╗"
    printf "  ║  LOG DETECTAT: %-31s║\n" "$profile_label"
    printf "  ║  Fisier: %-37s║\n" "$filename"
    echo "  ╠══════════════════════════════════════════════╣"

    # VFR warning
    if [[ "$SRC_IS_VFR" -eq 1 ]]; then
        echo "  ║  ⚠ Sursa este VFR (Variable Frame Rate)     ║"
        echo "  ║    Audio sync poate fi afectat.              ║"
        echo "  ║    Recomandat: seteaza FPS fix din meniu.    ║"
        echo "  ╠══════════════════════════════════════════════╣"
    fi

    local opt_num=1
    local opt_lut=0 opt_hlg_lut=0 opt_preserve=0 opt_creative=0 opt_copy=0 opt_skip=0
    # v62: conversia fara LUT (zscale tonemap) a fost ELIMINATA — transformarea
    # Log→Rec.709/HLG cere un LUT (.cube) ca sa fie corecta (si zscale crapa pe
    # surse LOG cu transfer=unknown). Fara LUT raman doar Preserve / Stream copy / Skip.
    local any_lut=0
    { [[ "$has_lut" -eq 1 ]] || { [[ "$has_hlg_lut" -eq 1 ]] && [[ "$encoder_type" != "x264" ]]; } || [[ "$has_creative_lut" -eq 1 ]]; } && any_lut=1
    if [[ "$any_lut" -eq 0 ]]; then
        echo "  ║  Nu am gasit LUT in Luts/ pentru acest brand.  ║"
        echo "  ║  Fara LUT, LOG-ul NU poate fi transformat       ║"
        echo "  ║  corect in Rec.709 (cere un .cube). Optiuni:    ║"
        echo "  ║  pune un LUT in Luts/, sau Preserve / Copy.     ║"
        echo "  ╠══════════════════════════════════════════════╣"
    fi

    # ── Build menu based on encoder type ─────────────────────────────
    if [[ "$encoder_type" == "x264" ]]; then
        # x264: no HDR10 option, force 8-bit
        if [[ "$has_lut" -eq 1 ]]; then
            opt_lut=$opt_num
            if [[ ${#LUT_FILES[@]} -eq 1 ]]; then
                local _lut_name
                _lut_name=$(basename "${LUT_FILES[0]}")
                printf "  ║  %d) Apply LUT → 8-bit SDR Rec.709           ║\n" "$opt_num"
                printf "  ║     [✓ %-38s]║\n" "$_lut_name"
            else
                printf "  ║  %d) Apply LUT → 8-bit SDR Rec.709           ║\n" "$opt_num"
                printf "  ║     [%d LUT-uri gasite — selectie]           ║\n" "${#LUT_FILES[@]}"
            fi
            opt_num=$((opt_num + 1))
        fi
        opt_preserve=$opt_num
        printf "  ║  %d) Preserve Log (compresie 8-bit)           ║\n" "$opt_num"
        echo "  ║     ⚠ 8-bit Log pierde gradatii — x265 rec.  ║"
        opt_num=$((opt_num + 1))
        if [[ "$has_creative_lut" -eq 1 ]]; then
            opt_creative=$opt_num
            printf "  ║  %d) Creative LUT (look artistic)             ║\n" "$opt_num"
            printf "  ║     [%d creative LUT-uri gasite]              ║\n" "${#CREATIVE_LUT_FILES[@]}"
            opt_num=$((opt_num + 1))
        fi
        opt_copy=$opt_num
        printf "  ║  %d) Stream copy video                        ║\n" "$opt_num"
        opt_num=$((opt_num + 1))
        opt_skip=$opt_num
        printf "  ║  %d) Sari acest fisier                        ║\n" "$opt_num"
    else
        # x265 / AV1: full menu with HDR10 option
        if [[ "$has_lut" -eq 1 ]]; then
            opt_lut=$opt_num
            if [[ ${#LUT_FILES[@]} -eq 1 ]]; then
                printf "  ║  %d) Apply LUT → 10-bit SDR Rec.709          ║\n" "$opt_num"
                printf "  ║     [✓ %-38s]║\n" "$(basename "${LUT_FILES[0]}")"
            else
                printf "  ║  %d) Apply LUT → 10-bit SDR Rec.709          ║\n" "$opt_num"
                printf "  ║     [%d LUT-uri gasite — selectie]            ║\n" "${#LUT_FILES[@]}"
            fi
            opt_num=$((opt_num + 1))
        fi
        if [[ "$has_hlg_lut" -eq 1 ]]; then
            opt_hlg_lut=$opt_num
            if [[ ${#HLG_LUT_FILES[@]} -eq 1 ]]; then
                printf "  ║  %d) Apply LUT Log→HLG → 10-bit BT.2100      ║\n" "$opt_num"
                printf "  ║     [✓ %-38s]║\n" "$(basename "${HLG_LUT_FILES[0]}")"
            else
                printf "  ║  %d) Apply LUT Log→HLG → 10-bit BT.2100      ║\n" "$opt_num"
                printf "  ║     [%d HLG LUT-uri gasite — selectie]        ║\n" "${#HLG_LUT_FILES[@]}"
            fi
            opt_num=$((opt_num + 1))
        fi
        opt_preserve=$opt_num
        printf "  ║  %d) Preserve Log (compresie, pastreaza prof) ║\n" "$opt_num"
        opt_num=$((opt_num + 1))
        if [[ "$has_creative_lut" -eq 1 ]]; then
            opt_creative=$opt_num
            printf "  ║  %d) Creative LUT (look artistic)             ║\n" "$opt_num"
            printf "  ║     [%d creative LUT-uri gasite]              ║\n" "${#CREATIVE_LUT_FILES[@]}"
            opt_num=$((opt_num + 1))
        fi
        opt_copy=$opt_num
        printf "  ║  %d) Stream copy video                        ║\n" "$opt_num"
        opt_num=$((opt_num + 1))
        opt_skip=$opt_num
        printf "  ║  %d) Sari acest fisier                        ║\n" "$opt_num"
    fi
    echo "  ╚══════════════════════════════════════════════╝"

    local max_opt=$opt_skip
    local default_opt=$opt_preserve
    [[ "$has_lut" -eq 1 ]] && default_opt=$opt_lut
    read -p "  Alege 1-$max_opt [implicit: $default_opt]: " log_choice
    log_choice="${log_choice:-$default_opt}"

    # ── Process choice ───────────────────────────────────────────────
    if [[ "$log_choice" -eq "$opt_lut" ]] && [[ "$opt_lut" -gt 0 ]]; then
        # Apply LUT
        local selected_lut=""
        if [[ ${#LUT_FILES[@]} -eq 1 ]]; then
            selected_lut="${LUT_FILES[0]}"
        else
            echo ""
            echo "  LUT-uri disponibile:"
            local li=1
            for lf in "${LUT_FILES[@]}"; do
                printf "  %d) %s\n" "$li" "$(basename "$lf")"
                li=$((li + 1))
            done
            read -p "  Alege LUT [implicit: 1]: " lut_sel
            lut_sel="${lut_sel:-1}"
            if [[ "$lut_sel" =~ ^[0-9]+$ ]] && [ "$lut_sel" -ge 1 ] && [ "$lut_sel" -le ${#LUT_FILES[@]} ]; then
                selected_lut="${LUT_FILES[$((lut_sel - 1))]}"
            else
                selected_lut="${LUT_FILES[0]}"
            fi
        fi
        log "  LOG: Apply LUT — $(basename "$selected_lut")"
        # v62 audit: setparams re-eticheteaza culoarea pe FRAME (lut3d nu o atinge →
        # ramanea bt2020/unknown de la sursa). Pe MKV ffprobe citeste Matroska Colour
        # din frame (nu VUI/SPS) → fara setparams iesirea LUT Rec.709 era mis-tagged.
        if [[ "$encoder_type" == "x264" ]]; then
            LOG_VIDEO_FILTER="lut3d='$selected_lut',format=yuv420p,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709"
            LOG_PIX_FMT="yuv420p"
        else
            LOG_VIDEO_FILTER="lut3d='$selected_lut',format=yuv420p10le,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709"
            LOG_PIX_FMT="yuv420p10le"
        fi
        LOG_COLOR_FLAGS="-color_primaries bt709 -color_trc bt709 -colorspace bt709"
        # v62 Bug2: culoarea bt709 si in params nativi encoder (ffmpeg -color_* nu
        # propaga VUI la x265/x264/svtav1 → output ramanea marcat bt2020/unknown).
        LOG_EXTRA_X265="colorprim=bt709:transfer=bt709:colormatrix=bt709"
        LOG_EXTRA_X264="colorprim=bt709:transfer=bt709:colormatrix=bt709"
        return 0

    elif [[ "$log_choice" -eq "$opt_hlg_lut" ]] && [[ "$opt_hlg_lut" -gt 0 ]]; then
        # v39: Apply LUT Log → HLG
        local selected_hlg_lut=""
        if [[ ${#HLG_LUT_FILES[@]} -eq 1 ]]; then
            selected_hlg_lut="${HLG_LUT_FILES[0]}"
        else
            echo ""
            echo "  HLG LUT-uri disponibile:"
            local hi=1
            for hlf in "${HLG_LUT_FILES[@]}"; do
                printf "  %d) %s\n" "$hi" "$(basename "$hlf")"
                hi=$((hi + 1))
            done
            read -p "  Alege HLG LUT [implicit: 1]: " hlg_sel
            hlg_sel="${hlg_sel:-1}"
            if [[ "$hlg_sel" =~ ^[0-9]+$ ]] && [ "$hlg_sel" -ge 1 ] && [ "$hlg_sel" -le ${#HLG_LUT_FILES[@]} ]; then
                selected_hlg_lut="${HLG_LUT_FILES[$((hlg_sel - 1))]}"
            else
                selected_hlg_lut="${HLG_LUT_FILES[0]}"
            fi
        fi
        log "  LOG: Apply HLG LUT — $(basename "$selected_hlg_lut")"
        LOG_VIDEO_FILTER="lut3d='$selected_hlg_lut',format=yuv420p10le,setparams=color_primaries=bt2020:color_trc=arib-std-b67:colorspace=bt2020nc"
        LOG_PIX_FMT="yuv420p10le"
        LOG_COLOR_FLAGS="-color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc"
        if [[ "$encoder_type" == "x265" ]]; then
            LOG_EXTRA_X265="hdr-opt=1:repeat-headers=1:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc"
        fi
        return 0

    elif [[ "$log_choice" -eq "$opt_preserve" ]]; then
        # Preserve Log — compress without color change
        log "  LOG: Preserve Log (compresie fara schimbare culori)"
        if [[ "$encoder_type" == "x264" ]]; then
            LOG_PIX_FMT="yuv420p"
            log "  ⚠ x264 8-bit — gradatii pierdute. x265 recomandat."
        else
            LOG_PIX_FMT="yuv420p10le"
        fi
        # Preserve original color flags
        local orig_primaries orig_trc orig_space
        orig_primaries=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=color_primaries \
            -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1)
        orig_trc=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=color_transfer \
            -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1)
        orig_space=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=color_space \
            -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1)
        # Only add flags if values are meaningful
        local cf=""
        [[ -n "$orig_primaries" && "$orig_primaries" != "unknown" ]] && cf="$cf -color_primaries $orig_primaries"
        [[ -n "$orig_trc" && "$orig_trc" != "unknown" ]] && cf="$cf -color_trc $orig_trc"
        [[ -n "$orig_space" && "$orig_space" != "unknown" ]] && cf="$cf -colorspace $orig_space"
        LOG_COLOR_FLAGS="$cf"
        return 0

    elif [[ "$log_choice" -eq "$opt_creative" ]] && [[ "$opt_creative" -gt 0 ]]; then
        # Creative LUT — artistic look
        local selected_creative=""
        if [[ ${#CREATIVE_LUT_FILES[@]} -eq 1 ]]; then
            selected_creative="${CREATIVE_LUT_FILES[0]}"
        else
            echo ""
            echo "  Creative LUT-uri disponibile:"
            local ci=1
            for clf in "${CREATIVE_LUT_FILES[@]}"; do
                printf "  %d) %s\n" "$ci" "$(basename "$clf")"
                ci=$((ci + 1))
            done
            read -p "  Alege LUT [implicit: 1]: " creative_sel
            creative_sel="${creative_sel:-1}"
            if [[ "$creative_sel" =~ ^[0-9]+$ ]] && [ "$creative_sel" -ge 1 ] && [ "$creative_sel" -le ${#CREATIVE_LUT_FILES[@]} ]; then
                selected_creative="${CREATIVE_LUT_FILES[$((creative_sel - 1))]}"
            else
                selected_creative="${CREATIVE_LUT_FILES[0]}"
            fi
        fi
        log "  LOG: Creative LUT — $(basename "$selected_creative")"
        if [[ "$encoder_type" == "x264" ]]; then
            LOG_VIDEO_FILTER="lut3d='$selected_creative',format=yuv420p,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709"
            LOG_PIX_FMT="yuv420p"
        else
            LOG_VIDEO_FILTER="lut3d='$selected_creative',format=yuv420p10le,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709"
            LOG_PIX_FMT="yuv420p10le"
        fi
        LOG_COLOR_FLAGS="-color_primaries bt709 -color_trc bt709 -colorspace bt709"
        # v62 Bug2: culoare bt709 in params encoder
        LOG_EXTRA_X265="colorprim=bt709:transfer=bt709:colormatrix=bt709"
        LOG_EXTRA_X264="colorprim=bt709:transfer=bt709:colormatrix=bt709"
        return 0

    elif [[ "$log_choice" -eq "$opt_copy" ]]; then
        log "  LOG: Stream copy video"
        return 97

    elif [[ "$log_choice" -eq "$opt_skip" ]]; then
        log "  LOG: Sarit de utilizator"
        return 98

    else
        log "  LOG: Optiune invalida — sarit"
        return 98
    fi
}

# Integreaza LOG filters in VIDEO_FILTER existent.
# Apelat dupa handle_log_dialog() cu return 0.
_apply_log_filters() {
    if [[ -n "${LOG_VIDEO_FILTER:-}" ]]; then
        if [[ -n "$VIDEO_FILTER" ]] && [[ "$VIDEO_FILTER" == *"-vf "* ]]; then
            # Prepend LOG filter before existing filters (LOG processing first)
            VIDEO_FILTER="${VIDEO_FILTER/-vf /-vf ${LOG_VIDEO_FILTER},}"
        else
            VIDEO_FILTER="-vf $LOG_VIDEO_FILTER"
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════════
# VIDSTAB + LOUDNORM
# ══════════════════════════════════════════════════════════════════════
vidstab_analyze() {
    local file="$1" trf_file; trf_file=$(av_mktemp_ext trf)
    log "  Vidstab: Trecerea 1/2 — analiza miscare..."
    ffmpeg -threads "$THREADS" -i "$file" \
        -vf "vidstabdetect=shakiness=5:accuracy=15:result=$trf_file" \
        -f null - 2>>"$LOG_FILE"
    if [ $? -ne 0 ] || [ ! -f "$trf_file" ]; then
        log "  EROARE vidstab: analiza esuata"; rm -f "$trf_file"; echo ""; return
    fi
    log "  Vidstab: analiza completa"; echo "$trf_file"
}

vidstab_transform_filter() {
    echo "vidstabtransform=input=$1:smoothing=10:interpol=bicubic:optzoom=1:zoomspeed=0.25"
}

_apply_vidstab() {
    local file="$1"
    if [[ "$VIDEO_FILTER_PRESET" == "vidstab" ]]; then
        TRF_FILE=$(vidstab_analyze "$file")
        if [[ -n "$TRF_FILE" ]]; then
            local svf; svf=$(vidstab_transform_filter "$TRF_FILE")
            [[ -n "$VIDEO_FILTER" ]] && VIDEO_FILTER="${VIDEO_FILTER/-vf /-vf ${svf},}" || VIDEO_FILTER="-vf $svf"
            log "  Vidstab: Trecerea 2/2 — encodare cu stabilizare"
        fi
    fi
}

get_loudnorm_filter() {
    local file="$1"
    [[ "${AUDIO_NORMALIZE:-0}" != "1" ]] && { echo ""; return; }
    # v67: scopat la PRIMA pista re-encodata (AUDIO_LOUDNORM_TRACK), nu hardcodat a:0 —
    # cu selectie per-pista, a:0 poate fi copy/skip; loudnorm trebuie pe o pista encodata.
    # -1 = nicio pista re-encodata → skip (altfel filtru pe stream copiat → eroare ffmpeg).
    local lt="${AUDIO_LOUDNORM_TRACK:-0}"
    if [[ ! "$lt" =~ ^[0-9]+$ ]]; then log "  Loudnorm: nicio pista re-encodata — skip" >&2; echo ""; return; fi
    # v66: log → stderr (>&2). stdout-ul functiei e CAPTURAT in LOUDNORM_FILTER=$(...);
    # `log` foloseste tee (scrie pe stdout) → fara >&2, mesajele poluau filtrul →
    # ffmpeg primea "Loudnorm:" ca nume de output ("Unable to choose output format").
    log "  Loudnorm: analiza volum EBU R128..." >&2
    local analysis m_i m_tp m_lra m_thresh
    analysis=$(ffmpeg -i "$file" -af "loudnorm=I=-24:TP=-2.0:LRA=7:print_format=json" -f null - 2>&1 | grep -A 20 '"input_i"')
    m_i=$(echo "$analysis" | grep '"input_i"' | sed 's/.*: "//;s/".*//'); m_tp=$(echo "$analysis" | grep '"input_tp"' | sed 's/.*: "//;s/".*//')
    m_lra=$(echo "$analysis" | grep '"input_lra"' | sed 's/.*: "//;s/".*//'); m_thresh=$(echo "$analysis" | grep '"input_thresh"' | sed 's/.*: "//;s/".*//')
    if [[ -z "$m_i" ]]; then log "  Loudnorm: analiza esuata — skip" >&2; echo ""; return; fi
    log "  Loudnorm: I=${m_i} LUFS | TP=${m_tp} dB | LRA=${m_lra} | pista a:$lt" >&2
    # v66: -filter:a:N (NU -af) — scopat la pista re-encodata. Cu -af (tot audio), pe
    # surse multi-track filtrul ar lovi track-urile copiate (a:1+) → "filtering and
    # streamcopy cannot be used together".
    echo "-filter:a:$lt loudnorm=I=-24:TP=-2.0:LRA=7:measured_I=${m_i}:measured_TP=${m_tp}:measured_LRA=${m_lra}:measured_thresh=${m_thresh}:linear=true"
}

# ══════════════════════════════════════════════════════════════════════
# RESUME BATCH
# ══════════════════════════════════════════════════════════════════════
BATCH_PROGRESS_FILE="$OUTPUT_DIR/batch_progress.log"
batch_mark_done() {
    local tmp="${BATCH_PROGRESS_FILE}.tmp"
    [ -f "$BATCH_PROGRESS_FILE" ] && cp "$BATCH_PROGRESS_FILE" "$tmp" || touch "$tmp"
    echo "$1" >> "$tmp"
    mv -f "$tmp" "$BATCH_PROGRESS_FILE"
}
batch_is_done()       { [ -f "$BATCH_PROGRESS_FILE" ] && grep -qxF "$1" "$BATCH_PROGRESS_FILE" 2>/dev/null; }
batch_clear_progress() { rm -f "$BATCH_PROGRESS_FILE"; }

# ══════════════════════════════════════════════════════════════════════
# CRF ADAPTIV UNIFICAT
# ══════════════════════════════════════════════════════════════════════
get_adaptive_crf() {
    local enc="$1" w="$2"
    [[ -n "$CUSTOM_CRF" ]] && { echo "$CUSTOM_CRF"; return; }
    case "$enc" in
        x265) [ "$w" -ge 3840 ] && echo 22 || { [ "$w" -ge 1920 ] && echo 21 || echo 20; } ;;
        x264) [ "$w" -ge 3840 ] && echo 20 || { [ "$w" -ge 1920 ] && echo 19 || echo 18; } ;;
        av1)  [ "$w" -ge 3840 ] && echo 30 || { [ "$w" -ge 1920 ] && echo 28 || echo 26; } ;;
        *)    echo 22 ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════
# v38: ADAPTIVE BITRATE pentru MediaCodec (nu suporta CRF, doar VBR/CBR)
# Returneaza bitrate-ul tinta (in kbps) per encoder + rezolutie
# Mapping aproximativ echivalent calitate cu CRF-urile din get_adaptive_crf
# ══════════════════════════════════════════════════════════════════════
get_adaptive_bitrate() {
    local enc="$1" w="$2"
    case "$enc" in
        hevc_mediacodec)
            [ "$w" -ge 3840 ] && echo 25000 || \
            { [ "$w" -ge 2560 ] && echo 14000 || \
              { [ "$w" -ge 1920 ] && echo 8000 || \
                { [ "$w" -ge 1280 ] && echo 4500 || echo 2500; }; }; }
            ;;
        h264_mediacodec)
            [ "$w" -ge 3840 ] && echo 35000 || \
            { [ "$w" -ge 2560 ] && echo 20000 || \
              { [ "$w" -ge 1920 ] && echo 12000 || \
                { [ "$w" -ge 1280 ] && echo 6500 || echo 3500; }; }; }
            ;;
        av1_mediacodec)
            [ "$w" -ge 3840 ] && echo 18000 || \
            { [ "$w" -ge 2560 ] && echo 10000 || \
              { [ "$w" -ge 1920 ] && echo 5500 || \
                { [ "$w" -ge 1280 ] && echo 3000 || echo 1800; }; }; }
            ;;
        *) echo 8000 ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════
# v51: 2-PASS VBR INFRASTRUCTURE (SW encoders only: x265/x264/SVT-AV1/libaom)
# Pattern (consistent cu FFMPEG_CMD string + eval folosit in proiect):
#   1. Encoderul setează:
#        - FFMPEG_CMD_PASS1 (string evaluabil — eval cu $file/\$file escaping)
#        - FFMPEG_CMD_PASS2 (string evaluabil)
#        - STATS_FILE (path stats partajat)
#        - USE_2PASS=1 (flag detectat de run_encode_loop)
#   2. run_encode_loop verifica USE_2PASS si apeleaza run_2pass_encode
#      in loc de eval $FFMPEG_CMD standard
#   3. Cleanup automat stats file + USE_2PASS reset in defensive block
# ══════════════════════════════════════════════════════════════════════

# Inițializează state-ul 2-pass pentru fișierul curent.
# Setează STATS_FILE (path absolut, fără extensie de tip-encoder) + STATS_DIR.
# Encoderele adaugă propriile extensii (x265: .stats + .stats.cutree, x264:
# .log + .log.mbtree, SVT-AV1: file unic, libaom: --fpf=).
init_2pass_state() {
    local file="$1"
    local name; name=$(basename "${file%.*}")
    # Sanitize name: înlocuiește caractere non-portabile cu underscore
    name="${name//[^A-Za-z0-9._-]/_}"
    STATS_DIR=$(av_mktemp_dir)
    STATS_FILE="$STATS_DIR/${name}.passlog"
    USE_2PASS=1
}

# Cleanup stats file + dir creat de init_2pass_state.
cleanup_2pass_state() {
    [[ -n "${STATS_DIR:-}" && -d "$STATS_DIR" ]] && rm -rf "$STATS_DIR"
    STATS_FILE=""; STATS_DIR=""; USE_2PASS=0
    FFMPEG_CMD_PASS1=""; FFMPEG_CMD_PASS2=""
}

# Rulează 2-pass encode. Encoderele populează FFMPEG_CMD_PASS1/PASS2 (strings
# eval-abile) înainte de apel. Pass 1 produce stats fără output util; Pass 2
# produce fișierul final folosind stats.
# Args: 1=file (pentru _show_progress), 2=encoder_label
run_2pass_encode() {
    local file="$1" label="$2"

    [[ -z "${FFMPEG_CMD_PASS1:-}" ]] && { log "  EROARE: FFMPEG_CMD_PASS1 string gol"; return 1; }
    [[ -z "${FFMPEG_CMD_PASS2:-}" ]] && { log "  EROARE: FFMPEG_CMD_PASS2 string gol"; return 1; }
    [[ -z "${STATS_FILE:-}" ]] && { log "  EROARE: STATS_FILE neinițializat (apelează init_2pass_state)"; return 1; }

    log ""
    log "  ── 2-PASS: Pass 1/2 (analiză, fără audio, output null) ──"
    local prog_file1 stderr_file1
    prog_file1=$(mktemp)
    stderr_file1=$(mktemp)

    # Pass 1 e self-contained (terminat cu /dev/null sau echivalent).
    # shellcheck disable=SC2086
    eval $FFMPEG_CMD_PASS1 -progress '"$prog_file1"' -nostats '2>"$stderr_file1"' '&'
    local pid1=$!
    _show_progress "$pid1" "$prog_file1" "$file" "$label P1"
    wait "$pid1"
    local rc1=$?

    [[ -s "$stderr_file1" ]] && cat "$stderr_file1" >> "$LOG_FILE"

    if [ $rc1 -ne 0 ]; then
        log "  EROARE Pass 1 (rc=$rc1):"
        if [[ -s "$stderr_file1" ]]; then
            echo "  ⚠ ffmpeg Pass 1 exit $rc1 — ultimele linii stderr:"
            tail -10 "$stderr_file1" | sed 's/^/    /'
        fi
        rm -f "$prog_file1" "$stderr_file1"
        return $rc1
    fi
    rm -f "$prog_file1" "$stderr_file1"

    log "  ── 2-PASS: Pass 2/2 (encodare finală + audio) ──"
    local prog_file2 stderr_file2
    prog_file2=$(mktemp)
    stderr_file2=$(mktemp)

    # Pass 2 urmeaza pattern-ul standard FFMPEG_CMD: trailing args (loudnorm,
    # sub codec, container flags, output) sunt appendate din scope-ul apelantului
    # (run_encode_loop) ca sa pastram un singur loc unde se gestioneaza fluxul.
    # shellcheck disable=SC2086
    eval $FFMPEG_CMD_PASS2 $LOUDNORM_FILTER $SUB_CODEC -c:t copy \
        $CODEC_TAG $CONTAINER_FLAGS -progress '"$prog_file2"' -nostats '"$output"' '2>"$stderr_file2"' '&'
    local pid2=$!
    _show_progress "$pid2" "$prog_file2" "$file" "$label P2"
    wait "$pid2"
    local rc2=$?

    [[ -s "$stderr_file2" ]] && cat "$stderr_file2" >> "$LOG_FILE"

    if [ $rc2 -ne 0 ]; then
        log "  EROARE Pass 2 (rc=$rc2):"
        if [[ -s "$stderr_file2" ]]; then
            echo "  ⚠ ffmpeg Pass 2 exit $rc2 — ultimele linii stderr:"
            tail -10 "$stderr_file2" | sed 's/^/    /'
        fi
        rm -f "$prog_file2" "$stderr_file2"
        return $rc2
    fi
    rm -f "$prog_file2" "$stderr_file2"

    return 0
}

# SVT-AV1 v1.4+ suportă sintaxa `pass=N:stats=path` în -svtav1-params.
# Strategy 4 (v52): parse libsvtav1 version din ffmpeg -version; fallback
# optimist (assume modern) cand version nedetectata.
# Cache: SVTAV1_2PASS_CAPS_CHECKED + SVTAV1_2PASS_SUPPORTED + SVTAV1_DETECT_SOURCE.
_check_svtav1_2pass_caps() {
    [[ "${SVTAV1_2PASS_CAPS_CHECKED:-0}" == "1" ]] && return 0
    SVTAV1_2PASS_CAPS_CHECKED=1
    SVTAV1_2PASS_SUPPORTED=0
    SVTAV1_DETECT_SOURCE=""
    command -v ffmpeg >/dev/null 2>&1 || return 1
    # Parse "libsvtav1 1.7.0" sau "libsvtav1 1.4" din ffmpeg -version
    local v
    v=$(ffmpeg -version 2>/dev/null | grep -oE 'libsvtav1[[:space:]]+[0-9]+\.[0-9]+(\.[0-9]+)?' \
        | grep -oE '[0-9]+\.[0-9]+' | head -1)
    if [[ -n "$v" ]]; then
        # Comparare float via awk (bash nu suporta float comparison nativ)
        SVTAV1_2PASS_SUPPORTED=$(awk -v ver="$v" 'BEGIN{print (ver+0 >= 1.4) ? 1 : 0}')
        SVTAV1_DETECT_SOURCE="version=$v"
    else
        # Fallback optimist: assume modern build (ffmpeg n6.0+ statistical normal in 2026)
        SVTAV1_2PASS_SUPPORTED=1
        SVTAV1_DETECT_SOURCE="assumed-modern"
    fi
    return 0
}

# Verifică dacă backend-ul HW activ permite 2-pass. Actualmente: NICIUNUL.
# Returnează 0 dacă 2-pass e permis (SW path), 1 dacă HW activ → fallback necesar.
hw_2pass_allowed() {
    case "${HW_BACKEND:-sw}" in
        sw|"") return 0 ;;
        *)     return 1 ;;  # nvenc/qsv/vaapi/videotoolbox/amf/mediacodec
    esac
}

# Returnează target-ul null output platform-aware (bash rulează doar pe
# Termux/Linux/macOS → /dev/null mereu OK).
get_null_output() { echo "/dev/null"; }

# ══════════════════════════════════════════════════════════════════════
# v51: VBV / LEVEL AUTOMATION
# Tabele MaxBR/MaxCPB per codec×level (kbps, conform spec).
# - HEVC Main 10 4:2:0 Main Tier + High Tier
# - H.264 High profile MaxBR (CABAC factor inclus)
# - AV1 Main profile level limits (kbps, derivate din MaxBitrate)
# get_vbv_caps echo "maxbr_kbps maxcpb_kbps"
# suggest_vbv_for_target echo "level tier maxrate_kbps bufsize_kbps"
# ══════════════════════════════════════════════════════════════════════

# Args: codec(hevc|h264|av1) level(ex 4.1) tier(main|high) → "maxbr maxcpb"
get_vbv_caps() {
    local codec="$1" level="$2" tier="${3:-main}"
    case "$codec" in
        hevc)
            case "$level" in
                3.0)  [ "$tier" = "high" ] && echo "6000 6000"     || echo "6000 6000" ;;
                3.1)  [ "$tier" = "high" ] && echo "10000 10000"   || echo "10000 10000" ;;
                4.0)  [ "$tier" = "high" ] && echo "30000 30000"   || echo "12000 12000" ;;
                4.1)  [ "$tier" = "high" ] && echo "50000 50000"   || echo "20000 20000" ;;
                5.0)  [ "$tier" = "high" ] && echo "100000 100000" || echo "25000 25000" ;;
                5.1)  [ "$tier" = "high" ] && echo "160000 160000" || echo "40000 40000" ;;
                5.2)  [ "$tier" = "high" ] && echo "240000 240000" || echo "60000 60000" ;;
                6.0)  [ "$tier" = "high" ] && echo "240000 240000" || echo "60000 60000" ;;
                6.1)  [ "$tier" = "high" ] && echo "480000 480000" || echo "120000 120000" ;;
                6.2)  [ "$tier" = "high" ] && echo "800000 800000" || echo "240000 240000" ;;
                *)    echo "40000 40000" ;;
            esac
            ;;
        h264)
            # H.264 High profile MaxBR (kbps); factor 1.25 vs baseline inclus
            case "$level" in
                3.0)  echo "12500 12500" ;;
                3.1)  echo "17500 17500" ;;
                3.2)  echo "25000 25000" ;;
                4.0)  echo "25000 25000" ;;
                4.1)  echo "62500 62500" ;;
                4.2)  echo "62500 62500" ;;
                5.0)  echo "168750 168750" ;;
                5.1)  echo "300000 300000" ;;
                5.2)  echo "300000 300000" ;;
                6.0)  echo "300000 300000" ;;
                6.1)  echo "600000 600000" ;;
                6.2)  echo "1200000 1200000" ;;
                *)    echo "62500 62500" ;;
            esac
            ;;
        av1)
            # AV1 Main profile MaxBitrate (kbps); 10-bit valori conform spec 5.9
            case "$level" in
                4.0)  echo "12000 30000" ;;
                4.1)  echo "20000 50000" ;;
                5.0)  echo "30000 100000" ;;
                5.1)  echo "40000 160000" ;;
                5.2)  echo "60000 240000" ;;
                5.3)  echo "60000 240000" ;;
                6.0)  echo "60000 240000" ;;
                6.1)  echo "100000 480000" ;;
                6.2)  echo "160000 800000" ;;
                6.3)  echo "160000 800000" ;;
                *)    echo "30000 100000" ;;
            esac
            ;;
        *) echo "0 0" ;;
    esac
}

# Determină level minim conform rezoluției × fps (luma sample rate).
# Returnează string level "X.Y".
_min_level_for_res() {
    local codec="$1" w="$2" h="$3" fps="${4:-30}"
    # Folosim aproximari pragmatice. Conversie fps real cu awk pentru float.
    local fps_int
    fps_int=$(awk "BEGIN{printf \"%d\", ($fps + 0.5)}")
    [ -z "$fps_int" ] || [ "$fps_int" -lt 1 ] && fps_int=30

    case "$codec" in
        hevc)
            if   [ "$w" -ge 7680 ]; then echo "6.1"
            elif [ "$w" -ge 3840 ] && [ "$fps_int" -gt 60 ]; then echo "5.2"
            elif [ "$w" -ge 3840 ] && [ "$fps_int" -gt 30 ]; then echo "5.1"
            elif [ "$w" -ge 3840 ]; then echo "5.0"
            elif [ "$w" -ge 1920 ] && [ "$fps_int" -gt 30 ]; then echo "4.1"
            elif [ "$w" -ge 1920 ]; then echo "4.0"
            elif [ "$w" -ge 1280 ]; then echo "3.1"
            else echo "3.0"; fi
            ;;
        h264)
            if   [ "$w" -ge 3840 ] && [ "$fps_int" -gt 60 ]; then echo "6.0"
            elif [ "$w" -ge 3840 ]; then echo "5.1"
            elif [ "$w" -ge 2560 ]; then echo "5.0"
            elif [ "$w" -ge 1920 ] && [ "$fps_int" -gt 30 ]; then echo "4.2"
            elif [ "$w" -ge 1920 ]; then echo "4.1"
            elif [ "$w" -ge 1280 ]; then echo "3.1"
            else echo "3.0"; fi
            ;;
        av1)
            if   [ "$w" -ge 7680 ]; then echo "6.1"
            elif [ "$w" -ge 3840 ] && [ "$fps_int" -gt 60 ]; then echo "5.2"
            elif [ "$w" -ge 3840 ] && [ "$fps_int" -gt 30 ]; then echo "5.1"
            elif [ "$w" -ge 3840 ]; then echo "5.0"
            elif [ "$w" -ge 1920 ] && [ "$fps_int" -gt 30 ]; then echo "4.1"
            elif [ "$w" -ge 1920 ]; then echo "4.0"
            else echo "4.0"; fi
            ;;
    esac
}

# Sugerează nivelul + tier-ul + maxrate + bufsize pentru un target bitrate dat.
# Args: codec target_kbps width height [fps]
# Echo: "level tier maxrate_kbps bufsize_kbps"
# Logica:
#   1. Pleacă de la level minim cerut de rezoluție/fps
#   2. Verifică dacă target_kbps × 1.5 (maxrate) încape în level.maxbr Main Tier
#   3. Dacă NU: pe HEVC promovează tier=high; pe H.264/AV1 escaladează nivelul
#   4. maxrate = min(target × 1.5, level.maxbr); bufsize = min(target × 2.0, level.maxcpb)
suggest_vbv_for_target() {
    local codec="$1" target_kbps="$2" w="$3" h="$4" fps="${5:-30}"
    local level tier maxbr maxcpb caps
    level=$(_min_level_for_res "$codec" "$w" "$h" "$fps")
    tier="main"

    local desired_maxrate=$(( target_kbps * 3 / 2 ))
    local desired_bufsize=$(( target_kbps * 2 ))

    # Pana la 8 escaladari (suficient pt orice secventa rezonabila)
    local i=0
    while [ $i -lt 8 ]; do
        caps=$(get_vbv_caps "$codec" "$level" "$tier")
        maxbr="${caps%% *}"; maxcpb="${caps##* }"
        if [ "$desired_maxrate" -le "$maxbr" ]; then
            break
        fi
        # Promoveaza tier (HEVC) sau level
        if [ "$codec" = "hevc" ] && [ "$tier" = "main" ]; then
            tier="high"
        else
            # Escaladare level la urmatorul plauzibil
            case "$level" in
                3.0) level="3.1" ;;
                3.1) level="4.0" ;;
                4.0) level="4.1" ;;
                4.1) level="5.0" ;;
                5.0) level="5.1" ;;
                5.1) level="5.2" ;;
                5.2) level="6.0" ;;
                6.0) level="6.1" ;;
                6.1) level="6.2" ;;
                6.2) break ;;
                *)   break ;;
            esac
            # Pe HEVC, dupa escaladare nivel revenim la Main Tier inainte de a urca din nou la High
            [ "$codec" = "hevc" ] && tier="main"
        fi
        i=$((i+1))
    done

    # Clamp final maxrate/bufsize la limita level-ului ales
    local final_maxrate=$desired_maxrate
    local final_bufsize=$desired_bufsize
    [ "$final_maxrate" -gt "$maxbr" ] && final_maxrate=$maxbr
    [ "$final_bufsize" -gt "$maxcpb" ] && final_bufsize=$maxcpb

    echo "$level $tier $final_maxrate $final_bufsize"
}

# ══════════════════════════════════════════════════════════════════════
# v77: escapeaza parantezele dintr-un fragment de params (ex. master-display=G(..)B(..))
# pentru caile rulate prin `eval` (FFMPEG_CMD in run_encode_loop / run_2pass_encode).
# Fara escapare, `eval` interpreteaza `(` ca subshell → "syntax error near unexpected
# token (" → encode 0 octeti (bug latent de la v51, mascat fiindca validarea HDR e pe
# Windows/PS1 care NU foloseste eval). Aplicat DOAR pe calea eval (encoder x265/av1);
# var-urile partajate HDR10_MASTER_DISPLAY_* raman RAW pentru consumatorii directi
# (burn-in / trim-concat ffmpeg direct + dovi_tool generate `--master-display "$.."`),
# care paseaza valoarea ca UN argument (fara eval) si au nevoie de parantezele brute.
_esc_eval_parens() {
    local s="$1"; s="${s//(/\\(}"; s="${s//)/\\)}"; printf '%s' "$s"
}

# ══════════════════════════════════════════════════════════════════════
# v51: HDR10 STATIC METADATA EXTRACTION (Mastering Display + MaxCLL/MaxFALL)
# Extrage din ffprobe side_data_list (frame 0) si formateaza pentru:
#   - x265-params: chromaticity ×50000, luminance ×10000 (integer)
#   - svtav1-params: floating decimal direct
# Setează variabile globale:
#   HDR10_STATIC_AVAILABLE       = 0|1
#   HDR10_MASTER_DISPLAY_X265    = "G(gx,gy)B(bx,by)R(rx,ry)WP(wx,wy)L(maxL,minL)"
#   HDR10_MASTER_DISPLAY_SVTAV1  = "G(g.x,g.y)B(b.x,b.y)R(r.x,r.y)WP(w.x,w.y)L(maxN,minN)"
#   HDR10_MAX_CLL                = "MaxCLL,MaxFALL" (gol daca nu e prezent)
# ══════════════════════════════════════════════════════════════════════
extract_hdr10_static_metadata() {
    local file="$1"
    HDR10_STATIC_AVAILABLE=0
    HDR10_MASTER_DISPLAY_X265=""
    HDR10_MASTER_DISPLAY_SVTAV1=""
    HDR10_MAX_CLL=""

    command -v ffprobe >/dev/null 2>&1 || return 1
    [ -f "$file" ] || return 1

    # ffprobe single-frame side_data — primul keyframe pentru viteza
    # v63 FIX: `frame=side_data_list` nu mai expune cheile nested in ffprobe-ul curent
    # (output gol → extract esua mereu → HDR10 static cadea PE DEFAULT, nu citea master-display/
    # MaxCLL real). Acelasi anti-pattern ca `frame_side_data=type`. Cerem cheile explicit prin
    # `frame_side_data=` — awk-ul de mai jos (grupat pe side_data_type) ramane neschimbat.
    local probe
    probe=$(LC_ALL=C ffprobe -v error -select_streams v:0 \
        -read_intervals "%+#1" \
        -show_entries frame_side_data=side_data_type,red_x,red_y,green_x,green_y,blue_x,blue_y,white_point_x,white_point_y,max_luminance,min_luminance,max_content,max_average \
        -of default=noprint_wrappers=1 \
        "$file" 2>/dev/null)
    [ -z "$probe" ] && return 1

    # Awk extract — emit shell vars pe stdout, eval-ate apoi
    local extracted
    extracted=$(echo "$probe" | LC_ALL=C awk '
        BEGIN { mode="" }
        /side_data_type=Mastering display metadata/ { mode="m"; next }
        /side_data_type=Content light level metadata/ { mode="c"; next }
        /side_data_type=/ { mode=""; next }
        {
            n = index($0, "=")
            if (n == 0) next
            key = substr($0, 1, n-1)
            val = substr($0, n+1)
            gsub(/^[ \t]+|[ \t]+$/, "", key)
            gsub(/^[ \t]+|[ \t]+$/, "", val)
            if (mode == "m") {
                if (val ~ /\//) {
                    split(val, frac, "/")
                    num = frac[1]; den = frac[2]
                } else {
                    num = val; den = 1
                }
                if (key == "red_x")        printf "RX_N=%s; RX_D=%s; ", num, den
                else if (key == "red_y")   printf "RY_N=%s; RY_D=%s; ", num, den
                else if (key == "green_x") printf "GX_N=%s; GX_D=%s; ", num, den
                else if (key == "green_y") printf "GY_N=%s; GY_D=%s; ", num, den
                else if (key == "blue_x")  printf "BX_N=%s; BX_D=%s; ", num, den
                else if (key == "blue_y")  printf "BY_N=%s; BY_D=%s; ", num, den
                else if (key == "white_point_x") printf "WX_N=%s; WX_D=%s; ", num, den
                else if (key == "white_point_y") printf "WY_N=%s; WY_D=%s; ", num, den
                else if (key == "max_luminance") printf "MAXL_N=%s; MAXL_D=%s; ", num, den
                else if (key == "min_luminance") printf "MINL_N=%s; MINL_D=%s; ", num, den
            } else if (mode == "c") {
                if (key == "max_content") printf "MAXC=%s; ", val
                else if (key == "max_average") printf "MAXA=%s; ", val
            }
        }
    ')

    local RX_N RX_D RY_N RY_D GX_N GX_D GY_N GY_D BX_N BX_D BY_N BY_D
    local WX_N WX_D WY_N WY_D MAXL_N MAXL_D MINL_N MINL_D MAXC MAXA
    eval "$extracted"

    if [[ -n "${RX_N:-}" && -n "${GX_N:-}" && -n "${BX_N:-}" && -n "${WX_N:-}" && -n "${MAXL_N:-}" ]]; then
        # x265 format: chromaticity ×50000, luminance ×10000 (rotunjit la integer)
        local gx_i gy_i bx_i by_i rx_i ry_i wx_i wy_i maxl_i minl_i
        gx_i=$(LC_ALL=C awk "BEGIN{printf \"%d\", $GX_N * 50000 / $GX_D + 0.5}")
        gy_i=$(LC_ALL=C awk "BEGIN{printf \"%d\", $GY_N * 50000 / $GY_D + 0.5}")
        bx_i=$(LC_ALL=C awk "BEGIN{printf \"%d\", $BX_N * 50000 / $BX_D + 0.5}")
        by_i=$(LC_ALL=C awk "BEGIN{printf \"%d\", $BY_N * 50000 / $BY_D + 0.5}")
        rx_i=$(LC_ALL=C awk "BEGIN{printf \"%d\", $RX_N * 50000 / $RX_D + 0.5}")
        ry_i=$(LC_ALL=C awk "BEGIN{printf \"%d\", $RY_N * 50000 / $RY_D + 0.5}")
        wx_i=$(LC_ALL=C awk "BEGIN{printf \"%d\", $WX_N * 50000 / $WX_D + 0.5}")
        wy_i=$(LC_ALL=C awk "BEGIN{printf \"%d\", $WY_N * 50000 / $WY_D + 0.5}")
        maxl_i=$(LC_ALL=C awk "BEGIN{printf \"%d\", $MAXL_N * 10000 / $MAXL_D + 0.5}")
        minl_i=$(LC_ALL=C awk "BEGIN{printf \"%d\", $MINL_N * 10000 / $MINL_D + 0.5}")
        HDR10_MASTER_DISPLAY_X265="G(${gx_i},${gy_i})B(${bx_i},${by_i})R(${rx_i},${ry_i})WP(${wx_i},${wy_i})L(${maxl_i},${minl_i})"

        # SVT-AV1 format: float (4 zecimale chromaticity, 4 zecimale luminance)
        local gx_f gy_f bx_f by_f rx_f ry_f wx_f wy_f maxl_f minl_f
        gx_f=$(LC_ALL=C awk "BEGIN{printf \"%.4f\", $GX_N / $GX_D}")
        gy_f=$(LC_ALL=C awk "BEGIN{printf \"%.4f\", $GY_N / $GY_D}")
        bx_f=$(LC_ALL=C awk "BEGIN{printf \"%.4f\", $BX_N / $BX_D}")
        by_f=$(LC_ALL=C awk "BEGIN{printf \"%.4f\", $BY_N / $BY_D}")
        rx_f=$(LC_ALL=C awk "BEGIN{printf \"%.4f\", $RX_N / $RX_D}")
        ry_f=$(LC_ALL=C awk "BEGIN{printf \"%.4f\", $RY_N / $RY_D}")
        wx_f=$(LC_ALL=C awk "BEGIN{printf \"%.4f\", $WX_N / $WX_D}")
        wy_f=$(LC_ALL=C awk "BEGIN{printf \"%.4f\", $WY_N / $WY_D}")
        maxl_f=$(LC_ALL=C awk "BEGIN{printf \"%.4f\", $MAXL_N / $MAXL_D}")
        minl_f=$(LC_ALL=C awk "BEGIN{printf \"%.4f\", $MINL_N / $MINL_D}")
        HDR10_MASTER_DISPLAY_SVTAV1="G(${gx_f},${gy_f})B(${bx_f},${by_f})R(${rx_f},${ry_f})WP(${wx_f},${wy_f})L(${maxl_f},${minl_f})"

        HDR10_STATIC_AVAILABLE=1
    fi

    [[ -n "${MAXC:-}" && -n "${MAXA:-}" ]] && HDR10_MAX_CLL="${MAXC},${MAXA}"
    return 0
}

# Defaults BT.2020 + 1000 nits master (folosit cand sursa nu raporteaza
# master_display dar e clar HDR10 target — sau LOG → HDR10 transform).
hdr10_static_defaults() {
    HDR10_STATIC_AVAILABLE=1
    # BT.2020 chromaticity primaries
    HDR10_MASTER_DISPLAY_X265="G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,1)"
    HDR10_MASTER_DISPLAY_SVTAV1="G(0.1700,0.7970)B(0.1310,0.0460)R(0.7080,0.2920)WP(0.3127,0.3290)L(1000.0000,0.0001)"
    HDR10_MAX_CLL="1000,400"
}

# v63: Masoara MaxCLL/MaxFALL real din continut (1 pass de analiza) cand userul opteaza
# (HDR10_MEASURE_CLL=1) si sursa NU are light-level inscris. Luma-based: signalstats YMAX/YAVG
# pe semnal linearizat cu zscale; npl=10000 pt sursa PQ (smpte2084), 1000 pt HLG. Subestimeaza
# usor vs max(R,G,B) per CTA-861.3 — acceptabil pt opt-in QC. Soft-fail → pastreaza default 1000,400.
# Seteaza HDR10_MEASURED_CLL / HDR10_MEASURED_FALL (nits intregi). Return 0=ok, 1=esec.
measure_hdr10_cll() {
    local file="$1"
    HDR10_MEASURED_CLL=""; HDR10_MEASURED_FALL=""
    command -v ffmpeg >/dev/null 2>&1 || return 1
    [ -f "$file" ] || return 1
    local _trc; _trc=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | head -1)
    local _npl=1000; [ "$_trc" = "smpte2084" ] && _npl=10000
    echo "  Masor MaxCLL/MaxFALL real (1 pass de analiza, poate dura)..." >&2
    local _res
    _res=$(ffmpeg -hide_banner -v error -i "$file" \
        -vf "zscale=t=linear:npl=${_npl},format=yuv444p16le,signalstats,metadata=print:file=-" \
        -an -f null - 2>/dev/null | awk -F= -v npl="$_npl" '
            /YMAX=/{v=$2+0; if(v>ymax)ymax=v}
            /YAVG=/{v=$2+0; if(v>yavg)yavg=v}
            END{ if(ymax>0) printf "%d %d", int(ymax/65535*npl+0.5), int(yavg/65535*npl+0.5) }')
    [ -z "$_res" ] && return 1
    HDR10_MEASURED_CLL="${_res%% *}"
    HDR10_MEASURED_FALL="${_res##* }"
    return 0
}

# v63: prompt opt-in MaxCLL/MaxFALL real (Varianta B). Seteaza HDR10_MEASURE_CLL pt fisierul curent.
# Sare promptul daca flag-ul e deja activ (env/profil → reset-ul per-iteratie il pastreaza) sau non-interactiv.
ask_hdr10_measure_cll() {
    [ "${HDR10_MEASURE_CLL:-0}" = "1" ] && return 0
    [ "${AV_NONINTERACTIVE:-0}" = "1" ] && return 0
    echo "  MaxCLL/MaxFALL (luminanta continut HDR10):"
    echo "    1) Implicit 1000,400 (rapid) [implicit]"
    echo "    2) Masoara real din video (+1 pass de analiza — master de calitate)"
    read -p "  Alege 1-2 [implicit: 1]: " _cll_ch
    [ "${_cll_ch:-1}" = "2" ] && { HDR10_MEASURE_CLL=1; log "  MaxCLL/MaxFALL: masurare reala activata"; }
    return 0
}

# Helper combinat: extract daca exista, altfel defaults; setează _SOURCE marker
# pentru log. Apel: hdr10_static_resolve "$file"
hdr10_static_resolve() {
    local file="$1"
    extract_hdr10_static_metadata "$file"
    local _real_cll="$HDR10_MAX_CLL"   # non-gol doar daca probe a gasit light-level real
    if [ "${HDR10_STATIC_AVAILABLE:-0}" = "1" ]; then
        HDR10_STATIC_SOURCE="probe"
    else
        hdr10_static_defaults
        HDR10_STATIC_SOURCE="default-bt2020-1000nit"
    fi
    # v63: opt-in — masoara CLL real cand userul a cerut SI nu exista light-level inscris
    # (HLG-origin / PQ fara metadata). NU suprascrie valori reale probate.
    if [ "${HDR10_MEASURE_CLL:-0}" = "1" ] && [ -z "$_real_cll" ]; then
        if measure_hdr10_cll "$file"; then
            HDR10_MAX_CLL="${HDR10_MEASURED_CLL},${HDR10_MEASURED_FALL}"
            HDR10_STATIC_SOURCE="measured-cll"
        fi
    fi
    [ -z "$HDR10_MAX_CLL" ] && HDR10_MAX_CLL="1000,400"
}

# Helper: extrage bitrate kbps dintr-un input "4000k" / "4M" / "4000000".
parse_bitrate_kbps() {
    local br="$1"
    [ -z "$br" ] && { echo 0; return; }
    if [[ "$br" =~ ^([0-9]+)[mM]$ ]]; then
        echo $(( ${BASH_REMATCH[1]} * 1000 ))
    elif [[ "$br" =~ ^([0-9]+)[kK]$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$br" =~ ^([0-9]+)$ ]]; then
        # Plain number: assume kbps daca <100000, altfel bps
        if [ "$br" -lt 100000 ]; then echo "$br"
        else echo $(( br / 1000 )); fi
    else
        echo 0
    fi
}

# v75: probe daca encoderul mediacodec accepta INPUT 10-bit pe calea cu filtre.
# "Supported pixel formats" din `-h encoder` = formatele de INTRARE acceptate. Azi listeaza
# doar `mediacodec yuv420p nv12` (8-bit) → return 1 (fals). Daca un ffmpeg viitor adauga
# p010/yuv420p10, return 0 (adevarat) → build_mediacodec_cmd cere 10-bit automat. Soft-fail.
_mc_encoder_supports_10bit() {
    local enc_codec="$1"
    ffmpeg -hide_banner -h "encoder=${enc_codec}_mediacodec" 2>/dev/null \
        | grep -iE 'supported pixel formats' | grep -qiE 'p010|yuv420p10'
}

# v75 forward-compat: detecteaza un encoder AV1 HARDWARE din lista de codecuri Android.
# Treble: codecurile HW sunt declarate de vendor in /vendor/etc/media_codecs*.xml, denumite
# c2.<vendor>.* / OMX.<vendor>.* (ex. c2.qti.av1.encoder); cele SW = c2.android.* / OMX.google.*.
# Return 0 daca exista un nod encoder AV1 NON-software. Inlocuieste ghicitul AV1 din modelul
# SoC (nesigur — infirmat pe 8 Gen 3, care are doar c2.qti.av1.DECODER). Soft-fail (return 1)
# daca /vendor nu e citibil sau exista doar encoder AV1 software.
_mc_has_hw_av1_encoder() {
    # $1 (optional, pt teste) = glob/cale fisiere; default = lista de codecuri a vendor-ului
    local files="${1:-/vendor/etc/media_codecs*.xml}"
    # v75: prinde AMBELE conventii de nume — Codec2 `c2.<vendor>.av1.encoder`
    # (av1 INAINTE de encoder) si OMX legacy `OMX.<vendor>.video.encoder.av1`
    # (encoder INAINTE de av1). OMX-AV1 e practic inexistent azi (AV1 = era Codec2),
    # dar regex-ul ramane robust forward/backward fara cost.
    # shellcheck disable=SC2086  # glob intentionat nequotat (default contine *)
    grep -ihE 'name="[^"]*(av1[^"]*encoder|encoder[^"]*av1)' $files 2>/dev/null \
        | grep -v '<!--' \
        | grep -qivE 'c2\.android\.|omx\.google\.'
}

# ══════════════════════════════════════════════════════════════════════
# v38: MEDIACODEC DETECTION (Termux/Android)
# Set vars globale: MC_AVAILABLE, MC_ENCODERS (h264/hevc/av1 list),
#   MC_SOC_VENDOR, MC_SOC_MODEL, MC_ANDROID_VER, MC_SOC_VERIFIED,
#   MC_CAP_HEVC10, MC_CAP_AV1, MC_INPUT_10BIT (v75)
# ══════════════════════════════════════════════════════════════════════
detect_mediacodec_caps() {
    MC_AVAILABLE=0
    MC_ENCODERS=""
    MC_SOC_VENDOR=""
    MC_SOC_MODEL=""
    MC_ANDROID_VER=""
    MC_SOC_VERIFIED=0
    MC_CAP_HEVC10=0
    MC_CAP_AV1=0
    MC_INPUT_10BIT=0

    # Platform gate: Termux/Android necesita getprop pentru SoC info; ffmpeg pentru encoder check
    command -v getprop >/dev/null 2>&1 || return 1
    command -v ffmpeg  >/dev/null 2>&1 || return 1

    # Binary check: ce encodere mediacodec are ffmpeg-ul
    local enc_list
    enc_list=$(ffmpeg -hide_banner -encoders 2>/dev/null | grep -E "(h264|hevc|av1)_mediacodec" | awk '{print $2}')
    [[ -z "$enc_list" ]] && return 1

    MC_ENCODERS="$enc_list"
    MC_AVAILABLE=1

    # v75 forward-compat: probe daca encoderul mediacodec accepta INPUT 10-bit. Azi ffmpeg
    # expune doar 8-bit (mediacodec/yuv420p/nv12) → MC_INPUT_10BIT=0. Daca un ffmpeg viitor
    # adauga p010 in formatele de intrare, build_mediacodec_cmd cere 10-bit AUTOMAT (fara
    # modificari de cod). Probe pe hevc (consumatorul principal 10-bit HDR/HLG).
    if [[ "$enc_list" == *"hevc_mediacodec"* ]] && _mc_encoder_supports_10bit hevc; then
        MC_INPUT_10BIT=1
    fi

    # SoC info
    MC_SOC_VENDOR=$(getprop ro.soc.manufacturer 2>/dev/null)
    MC_SOC_MODEL=$(getprop ro.soc.model 2>/dev/null)
    [[ -z "$MC_SOC_VENDOR" ]] && MC_SOC_VENDOR=$(getprop ro.hardware 2>/dev/null)
    [[ -z "$MC_SOC_MODEL" ]] && MC_SOC_MODEL=$(getprop ro.product.board 2>/dev/null)
    MC_ANDROID_VER=$(getprop ro.build.version.release 2>/dev/null)

    # SoC whitelist pentru capabilitati fine (10-bit HEVC, AV1 encode)
    # Nota: prezenta in whitelist marcheaza [verificat] in UI; absenta nu blocheaza
    local v_lc m_lc hw_lc
    v_lc=$(echo "$MC_SOC_VENDOR" | tr '[:upper:]' '[:lower:]')
    m_lc=$(echo "$MC_SOC_MODEL" | tr '[:upper:]' '[:lower:]')
    # v75: ro.hardware ca semnal vendor suplimentar. Pe device-uri reale (S24 Ultra,
    # validat pe SM8650) ro.soc.manufacturer raporteaza "QTI" (Qualcomm Technologies Inc),
    # NU "Qualcomm"/"qcom" → whitelist-ul rata flagship-ul Snapdragon (fallback pe ro.hardware
    # nu se declansa, vendor ne-gol). ro.hardware ramane "qcom".
    hw_lc=$(getprop ro.hardware 2>/dev/null | tr '[:upper:]' '[:lower:]')

    # AV1 HW ENCODE NU se revendica pe NICIUN SoC din whitelist (v75). Euristica
    # "model SoC → AV1 encode" e nesigura: AV1 hardware ENCODE pe mobil e cvasi-inexistent
    # (decode e raspandit din 8 Gen 2 / Dimensity 9000 / Exynos 2200 / Tensor G3, dar
    # encode aproape nicaieri). Infirmat empiric pe Snapdragon 8 Gen 3 (S24 Ultra: doar
    # c2.qti.av1.DECODER in /vendor, av1_mediacodec = c2.android.av1.encoder SW libaom
    # 1.68x@1080p vs h264 HW 4.81x) si pe Exynos 1380 (A54). Pe restul = neverificabil.
    # Cand MC_CAP_AV1=0, gard-ul din av_encoder_av1.sh cade pe libsvtav1 (SW bun al suitei),
    # mai bun decat libaom-prin-MediaCodec. Escape: HW_FORCE=1 (vezi gard-ul). Daca apare un
    # SoC cu AV1 encode HW REAL verificat, re-adauga claim-ul narrow aici.
    # Snapdragon 8xx (Gen 1+) — HEVC main10
    if [[ "$v_lc" == *"qualcomm"* ]] || [[ "$v_lc" == *"qcom"* ]] || [[ "$v_lc" == *"qti"* ]] || [[ "$hw_lc" == *"qcom"* ]]; then
        # SM8450 (8 Gen 1), SM8475 (8+ Gen 1), SM8550 (8 Gen 2), SM8650 (8 Gen 3), SM8750 (8 Gen 4)
        if [[ "$m_lc" =~ sm8(4|5|6|7)[0-9]{2} ]] || [[ "$m_lc" =~ sm8[5-9][0-9]{2} ]]; then
            MC_SOC_VERIFIED=1
            MC_CAP_HEVC10=1
        fi
    fi
    # Samsung Exynos 2100+ (HEVC 10-bit)
    # v75: device-urile moderne raporteaza CODENAME-ul s5e in ro.soc.model, NU numele de
    # marketing "exynos2100" (validat real: A54 = s5e8835; Exynos 2100=s5e9840, 2200=s5e9925,
    # 2400=s5e9945) → matchul pe "exynos2xxx" era cod mort pe hardware real. Adaug flagship
    # 2100+ via codename s5e9(8[4-9]|9[0-9])x → HEVC10 (exclude Exynos 990/9820/9830 vechi
    # + mid-range s5e88xx ca A54). Caveat: codename-urile flagship sunt din tabele publice,
    # NEtestate pe hardware flagship Exynos (doar A54 confirmat). AV1 encode = vezi nota de sus.
    if [[ "$v_lc" == *"samsung"* ]] || [[ "$m_lc" == *"exynos"* ]]; then
        if [[ "$m_lc" =~ exynos2[1-9][0-9]{2} ]] || [[ "$m_lc" =~ s5e9(8[4-9]|9[0-9])[0-9] ]]; then
            MC_SOC_VERIFIED=1
            MC_CAP_HEVC10=1
        fi
    fi
    # Google Tensor (G2+) — HEVC 10-bit
    if [[ "$v_lc" == *"google"* ]] || [[ "$m_lc" == *"tensor"* ]] || [[ "$m_lc" == *"gs"* ]]; then
        if [[ "$m_lc" =~ (gs[2-9]|tensor.*g[2-9]) ]]; then
            MC_SOC_VERIFIED=1
            MC_CAP_HEVC10=1
        fi
    fi
    # MediaTek Dimensity 9000+ — HEVC 10-bit
    # MTK SoC numbers: D9000=MT6983, D9200=MT6985, D9300=MT6989, D9400=MT6991, D9500+=MT699x
    if [[ "$v_lc" == *"mediatek"* ]] || [[ "$m_lc" == *"mt"* ]] || [[ "$m_lc" == *"dimensity"* ]]; then
        if [[ "$m_lc" =~ (mt69[89][0-9]|dimensity.?9[0-9]{3}) ]]; then
            MC_SOC_VERIFIED=1
            MC_CAP_HEVC10=1
        fi
    fi

    # v75 forward-compat: AV1 HW encode detectat DIRECT din encoderul vendor (nu ghicit din
    # modelul SoC — euristica aia era nesigura, infirmata pe 8 Gen 3). Cand un cip viitor
    # expune un encoder AV1 hardware (c2.<vendor>.av1.encoder), MC_CAP_AV1=1 automat, fara
    # update de whitelist. Azi (S24U/A54) = doar c2.android.av1.encoder SW → ramane 0.
    _mc_has_hw_av1_encoder && MC_CAP_AV1=1

    return 0
}

# Helper: returneaza label-ul scurt pentru meniul HW (ex: "MediaCodec HEVC [verificat]")
mediacodec_menu_label() {
    local codec="$1"  # h264|hevc|av1
    local enc_name="${codec}_mediacodec"
    [[ "$MC_ENCODERS" != *"$enc_name"* ]] && { echo ""; return; }
    local marker
    if [[ "$MC_SOC_VERIFIED" == "1" ]]; then
        marker="[verificat]"
    else
        marker="[suport necunoscut]"
    fi
    echo "MediaCodec ${codec^^} $marker"
}

# Helper: prompt confirmare pe SoC necunoscut (return 0 = continua, 1 = abort)
mediacodec_confirm_unknown_soc() {
    [[ "${HW_FORCE:-0}" == "1" ]] && return 0
    [[ "$MC_SOC_VERIFIED" == "1" ]] && return 0
    echo ""
    echo "  ⚠ SoC nedetectat in whitelist:"
    echo "    Vendor: ${MC_SOC_VENDOR:-necunoscut}"
    echo "    Model : ${MC_SOC_MODEL:-necunoscut}"
    echo "    Android: ${MC_ANDROID_VER:-?}"
    echo "    MediaCodec va incerca encoding, dar capabilitatile (10-bit, AV1) sunt incerte."
    read -p "  Continui cu MediaCodec? (d/N) [default: N]: " _mc_conf
    [[ "${_mc_conf,,}" == "d" ]] && return 0
    return 1
}

# Helper: banner SoC pentru log la inceputul flow-ului encode
mediacodec_print_banner() {
    [[ "$MC_AVAILABLE" != "1" ]] && return
    local cap_str=""
    [[ "$MC_CAP_HEVC10" == "1" ]] && cap_str="${cap_str} HEVC10"
    [[ "$MC_CAP_HEVC10" == "1" ]] && cap_str="${cap_str} HLG"
    [[ "$MC_CAP_AV1" == "1" ]] && cap_str="${cap_str} AV1"
    [[ -z "$cap_str" ]] && cap_str=" 8-bit only"
    local verified_str
    if [[ "$MC_SOC_VERIFIED" == "1" ]]; then
        verified_str="verificat"
    else
        verified_str="necunoscut"
    fi
    log "  HW MediaCodec: SoC ${MC_SOC_VENDOR:-?} ${MC_SOC_MODEL:-?} / Android ${MC_ANDROID_VER:-?} [${verified_str}]${cap_str}"
}

# ══════════════════════════════════════════════════════════════════════
# v42: HW Backend Detection — VAAPI / QSV / NVENC / VideoToolbox / AMF
# Paralel cu detect_mediacodec_caps. Fiecare seteaza:
#   XX_AVAILABLE     0|1 — backend utilizabil (binary + GPU prezent)
#   XX_ENCODERS      lista encodere ffmpeg (h264/hevc/av1)
#   XX_GPU_VENDOR    string vendor (NVIDIA / Intel / AMD / Apple)
#   XX_GPU_MODEL     string model (RTX 4070 / Arc A770 / M2 / RX 7900)
#   XX_CAP_HDR10     0|1 — HDR10 native pe acest backend
#   XX_CAP_10BIT     0|1 — encode 10-bit (main10) suportat
#   XX_CAP_AV1       0|1 — AV1 encode HW disponibil
#   XX_DEVICE        path device (Linux: /dev/dri/renderD128) sau -
# ══════════════════════════════════════════════════════════════════════

# ── v75: Intel AV1 encode gate (shared QSV + VAAPI) ───────────────────
# Prezenta av1_qsv/av1_vaapi in `ffmpeg -encoders` NU garanteaza AV1 encode HW:
# iGPU-urile Intel vechi (UHD Graphics) listeaza encoderul dar esueaza la runtime
# (ret -22 "Invalid argument", 0 output — confirmat empiric). AV1 encode Intel exista
# doar pe Arc (DG2/Alchemist/Battlemage) + iGPU Xe2/Xe-LPG (Meteor/Arrow/Lunar/Panther
# Lake, brand "Intel Arc Graphics"). Gate pe model (din lspci), aliniat cu PS1
# Get-GPUCapabilities $intelAv1Rx. Daca lspci numeste placa altfel → fallback SW (sigur).
_intel_gpu_has_av1_encode() {
    local model_lc; model_lc=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    [[ "$model_lc" =~ arc|dg2|alchemist|battlemage|meteor.?lake|arrow.?lake|lunar.?lake|panther.?lake|core.?ultra ]]
}

# v75 audit: probe FUNCTIONAL AV1 HW — micro-encode real (testsrc 320x240 0.2s → null) ca
# verificare AUTORITARA cand modelul GPU nu e in whitelist-ul de mai sus (lspci poate numi
# placa atipic → fals-negativ pe Arc real). Prezenta av1_qsv/av1_vaapi in -encoders NU
# garanteaza HW: iGPU vechi listeaza encoderul dar pica la runtime (Intel UHD: av1_qsv →
# -22 "doesn't support AV1 encoding"; validat empiric). **`format=nv12` e OBLIGATORIU** —
# testsrc raw (rgb/yuv420p) face QSV sa esueze "query encoder params" CHIAR si pe encoder
# capabil (fals-negativ; validat: hevc_qsv pica fara format=nv12, reuseste cu el). Exit 0 =
# AV1 HW real. NU poate da fals-POZITIV (encoderul incapabil pica clar) → sigur in hibridul
# `model || probe` (probe-ul doar ADAUGA detectie, nu o scoate). Folosit la detectie (o data).
_hw_av1_qsv_works() {
    command -v ffmpeg >/dev/null 2>&1 || return 1
    ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc=size=320x240:rate=25:duration=0.2" \
        -vf format=nv12 -c:v av1_qsv -f null - >/dev/null 2>&1
}
_hw_av1_vaapi_works() {
    local dev="${1:-}"
    [[ -z "$dev" ]] && return 1
    command -v ffmpeg >/dev/null 2>&1 || return 1
    # VAAPI cere device + hwupload (oglinda pipeline-ului din build_vaapi_cmd: format,hwupload).
    ffmpeg -hide_banner -loglevel error -vaapi_device "$dev" \
        -f lavfi -i "testsrc=size=320x240:rate=25:duration=0.2" \
        -vf "format=nv12,hwupload" -c:v av1_vaapi -f null - >/dev/null 2>&1
}
# v77: acelasi probe extins la NVENC / AMF / VideoToolbox (uniformizeaza principiul
# "capabilitate reala > model" pe TOATE backend-urile desktop — v75 il avea doar pe Intel
# QSV/VAAPI; NVENC/AMF/VT ramasesera pe regex de arhitectura). NVENC/AMF iau cadre de sistem
# (upload intern) → fara device, ca QSV. `model || probe` → ruleaza DOAR cand regex-ul zice NU.
_hw_av1_nvenc_works() {
    command -v ffmpeg >/dev/null 2>&1 || return 1
    ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc=size=320x240:rate=25:duration=0.2" \
        -vf format=nv12 -c:v av1_nvenc -f null - >/dev/null 2>&1
}
_hw_av1_amf_works() {
    command -v ffmpeg >/dev/null 2>&1 || return 1
    ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc=size=320x240:rate=25:duration=0.2" \
        -vf format=nv12 -c:v av1_amf -f null - >/dev/null 2>&1
}
_hw_av1_vt_works() {
    command -v ffmpeg >/dev/null 2>&1 || return 1
    ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc=size=320x240:rate=25:duration=0.2" \
        -vf format=nv12 -c:v av1_videotoolbox -f null - >/dev/null 2>&1
}

# ── VAAPI (Linux Intel iGPU + AMD Mesa) ───────────────────────────────
detect_vaapi_caps() {
    VAAPI_AVAILABLE=0
    VAAPI_ENCODERS=""
    VAAPI_GPU_VENDOR=""
    VAAPI_GPU_MODEL=""
    VAAPI_CAP_HDR10=0
    VAAPI_CAP_10BIT=0
    VAAPI_CAP_AV1=0
    VAAPI_DEVICE=""

    # Doar Linux non-Termux (Termux Android nu are /dev/dri uzual accesibil)
    [[ "$AV_PLATFORM" != "linux" ]] && return 1
    command -v ffmpeg >/dev/null 2>&1 || return 1

    # Device check
    local dev
    for dev in /dev/dri/renderD128 /dev/dri/renderD129; do
        [ -e "$dev" ] && [ -r "$dev" ] && { VAAPI_DEVICE="$dev"; break; }
    done
    [[ -z "$VAAPI_DEVICE" ]] && return 1

    # Encoders ffmpeg
    local enc_list
    enc_list=$(ffmpeg -hide_banner -encoders 2>/dev/null | grep -E "(h264|hevc|av1)_vaapi" | awk '{print $2}')
    [[ -z "$enc_list" ]] && return 1
    VAAPI_ENCODERS="$enc_list"

    # GPU vendor/model — citim din /sys/class/drm sau lspci
    local card_info=""
    if command -v lspci >/dev/null 2>&1; then
        card_info=$(lspci 2>/dev/null | grep -iE "vga|display|3d" | head -1)
    fi
    if [[ "$card_info" =~ [Ii]ntel ]]; then
        VAAPI_GPU_VENDOR="Intel"
        VAAPI_GPU_MODEL=$(echo "$card_info" | sed -E 's/.*: //;s/\(rev .*//' | head -1)
        # Intel Skylake+ suporta HEVC 10-bit; HDR10 fragil (Mesa >=23)
        VAAPI_CAP_10BIT=1
        VAAPI_CAP_HDR10=1
        # AV1 encode VAAPI: doar Intel Arc (DG2) + Xe2 iGPU (Meteor Lake+) — gate pe model
        # SAU probe functional (v75: nu doar prezenta av1_vaapi; model atipic → probe autoritar)
        if [[ "$VAAPI_ENCODERS" == *"av1_vaapi"* ]] && \
           { _intel_gpu_has_av1_encode "$VAAPI_GPU_MODEL" || _hw_av1_vaapi_works "$VAAPI_DEVICE"; }; then
            VAAPI_CAP_AV1=1
        fi
    elif [[ "$card_info" =~ [Aa][Mm][Dd]|[Rr]adeon|[Aa][Tt][Ii] ]]; then
        VAAPI_GPU_VENDOR="AMD"
        VAAPI_GPU_MODEL=$(echo "$card_info" | sed -E 's/.*: //;s/\(rev .*//' | head -1)
        VAAPI_CAP_10BIT=1
        # AMD VAAPI HDR10: experimental pe Mesa recent
        VAAPI_CAP_HDR10=1
    else
        VAAPI_GPU_VENDOR="${VAAPI_GPU_VENDOR:-Unknown}"
        VAAPI_GPU_MODEL="${card_info:-VAAPI device}"
    fi

    # vainfo verification (optional, mai detaliat dar lent)
    if command -v vainfo >/dev/null 2>&1; then
        local vainfo_out; vainfo_out=$(vainfo --display drm --device "$VAAPI_DEVICE" 2>/dev/null)
        # Daca vainfo arata explicit profile-uri 10-bit, confirm
        echo "$vainfo_out" | grep -q "Profile.*10" && VAAPI_CAP_10BIT=1
    fi

    VAAPI_AVAILABLE=1
    return 0
}

# ── QSV (Intel Quick Sync, discret + iGPU recente) ────────────────────
detect_qsv_caps() {
    QSV_AVAILABLE=0
    QSV_ENCODERS=""
    QSV_GPU_VENDOR=""
    QSV_GPU_MODEL=""
    QSV_CAP_HDR10=0
    QSV_CAP_10BIT=0
    QSV_CAP_AV1=0
    QSV_DEVICE=""

    [[ "$AV_PLATFORM" != "linux" ]] && return 1
    command -v ffmpeg >/dev/null 2>&1 || return 1

    # QSV foloseste /dev/dri/renderD128 (Intel) — implicit acelasi device
    local dev
    for dev in /dev/dri/renderD128 /dev/dri/renderD129; do
        [ -e "$dev" ] && [ -r "$dev" ] && { QSV_DEVICE="$dev"; break; }
    done
    [[ -z "$QSV_DEVICE" ]] && return 1

    # Confirma ca e Intel — QSV nu functioneaza pe AMD/NVIDIA
    if command -v lspci >/dev/null 2>&1; then
        local intel_check; intel_check=$(lspci 2>/dev/null | grep -iE "vga|display|3d" | grep -i intel | head -1)
        [[ -z "$intel_check" ]] && return 1
        QSV_GPU_VENDOR="Intel"
        QSV_GPU_MODEL=$(echo "$intel_check" | sed -E 's/.*: //;s/\(rev .*//' | head -1)
    fi

    # Encoders ffmpeg
    local enc_list
    enc_list=$(ffmpeg -hide_banner -encoders 2>/dev/null | grep -E "(h264|hevc|av1)_qsv" | awk '{print $2}')
    [[ -z "$enc_list" ]] && return 1
    QSV_ENCODERS="$enc_list"

    QSV_CAP_10BIT=1
    QSV_CAP_HDR10=1  # Arc + Core Ultra
    # v75: AV1 QSV gate pe model SAU probe functional — nu doar prezenta encoderului.
    # Model recunoscut → rapid (fara probe); nerecunoscut → probe autoritar (prinde Arc cu
    # nume lspci atipic). Probe-ul nu poate da fals-pozitiv → hibrid sigur (doar adauga).
    if [[ "$QSV_ENCODERS" == *"av1_qsv"* ]]; then
        if _intel_gpu_has_av1_encode "$QSV_GPU_MODEL" || _hw_av1_qsv_works; then
            QSV_CAP_AV1=1
        fi
    fi

    QSV_AVAILABLE=1
    return 0
}

# ── NVENC (NVIDIA Linux) ──────────────────────────────────────────────
detect_nvenc_caps() {
    NVENC_AVAILABLE=0
    NVENC_ENCODERS=""
    NVENC_GPU_VENDOR=""
    NVENC_GPU_MODEL=""
    NVENC_CAP_HDR10=0
    NVENC_CAP_10BIT=0
    NVENC_CAP_AV1=0
    NVENC_DEVICE=""

    [[ "$AV_PLATFORM" != "linux" ]] && return 1
    command -v ffmpeg >/dev/null 2>&1 || return 1

    # Encoders ffmpeg
    local enc_list
    enc_list=$(ffmpeg -hide_banner -encoders 2>/dev/null | grep -E "(h264|hevc|av1)_nvenc" | awk '{print $2}')
    [[ -z "$enc_list" ]] && return 1

    # GPU prezent fizic? nvidia-smi e cea mai sigura verificare
    if command -v nvidia-smi >/dev/null 2>&1; then
        NVENC_GPU_MODEL=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | sed 's/^ *//;s/ *$//')
        [[ -z "$NVENC_GPU_MODEL" ]] && return 1
        NVENC_GPU_VENDOR="NVIDIA"
    elif command -v lspci >/dev/null 2>&1; then
        local nvidia_check; nvidia_check=$(lspci 2>/dev/null | grep -iE "vga|display|3d" | grep -i nvidia | head -1)
        [[ -z "$nvidia_check" ]] && return 1
        NVENC_GPU_VENDOR="NVIDIA"
        NVENC_GPU_MODEL=$(echo "$nvidia_check" | sed -E 's/.*: //;s/\(rev .*//')
    else
        return 1
    fi

    NVENC_ENCODERS="$enc_list"
    NVENC_CAP_10BIT=1   # Maxwell+ suporta HEVC 10-bit
    NVENC_CAP_HDR10=1   # Turing+ HDR10 solid
    # AV1 NVENC: doar RTX 40+ (Ada Lovelace, AD102/AD103/AD104/AD106/AD107)
    if [[ "$NVENC_ENCODERS" == *"av1_nvenc"* ]]; then
        if [[ "$NVENC_GPU_MODEL" =~ RTX[[:space:]]*(40|50)[0-9]{2} ]] || [[ "$NVENC_GPU_MODEL" =~ Ada|Blackwell ]] || _hw_av1_nvenc_works; then
            NVENC_CAP_AV1=1   # v77: || probe → prinde un GPU NVIDIA viitor nerecunoscut de regex
        fi
    fi

    NVENC_AVAILABLE=1
    return 0
}

# ── VideoToolbox (macOS Intel + Apple Silicon) ────────────────────────
detect_videotoolbox_caps() {
    VT_AVAILABLE=0
    VT_ENCODERS=""
    VT_GPU_VENDOR=""
    VT_GPU_MODEL=""
    VT_CAP_HDR10=0
    VT_CAP_HLG=0
    VT_CAP_10BIT=0
    VT_CAP_AV1=0
    VT_CAP_PRORES=0
    VT_DEVICE=""
    VT_IS_APPLE_SILICON=0

    [[ "$AV_PLATFORM" != "macos" ]] && return 1
    command -v ffmpeg >/dev/null 2>&1 || return 1

    # Encoders ffmpeg (videotoolbox)
    local enc_list
    enc_list=$(ffmpeg -hide_banner -encoders 2>/dev/null | grep -E "(h264|hevc|av1|prores)_videotoolbox" | awk '{print $2}')
    [[ -z "$enc_list" ]] && return 1
    VT_ENCODERS="$enc_list"

    # Apple Silicon vs Intel detection
    local arch; arch=$(uname -m 2>/dev/null)
    if [[ "$arch" == "arm64" ]]; then
        VT_IS_APPLE_SILICON=1
        VT_GPU_VENDOR="Apple"
        # Model identifier: M1 / M2 / M3 / M4 etc. via sysctl
        local chip; chip=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
        VT_GPU_MODEL="${chip:-Apple Silicon}"
        VT_CAP_10BIT=1
        VT_CAP_HDR10=1
        VT_CAP_HLG=1
        VT_CAP_PRORES=1   # Apple Silicon are HW ProRes (foarte rapid)
        # AV1 VideoToolbox: doar M3 si mai noi
        if [[ "$VT_ENCODERS" == *"av1_videotoolbox"* ]]; then
            if [[ "$chip" =~ M[3-9] ]] || [[ "$chip" =~ M[1-9][0-9] ]] || _hw_av1_vt_works; then
                VT_CAP_AV1=1   # v77: || probe → prinde un Apple Silicon viitor nerecunoscut de regex
            fi
        fi
    else
        VT_GPU_VENDOR="Intel"
        VT_GPU_MODEL="Intel Mac"
        # Intel Mac VideoToolbox — H.264 8-bit, HEVC 8-bit (10-bit unstable)
        VT_CAP_10BIT=0
        VT_CAP_HDR10=0    # Tonemap recomandat
        VT_CAP_HLG=0
        VT_CAP_PRORES=1   # ProRes functioneaza si pe Intel (mai lent)
    fi

    VT_AVAILABLE=1
    return 0
}

# ── AMF (AMD Linux RDNA3+) — experimental ─────────────────────────────
# v42.1: iGPU detection extinsa (Phoenix/Hawk Point/Strix Point — Radeon 740M..890M)
detect_amf_caps() {
    AMF_AVAILABLE=0
    AMF_ENCODERS=""
    AMF_GPU_VENDOR=""
    AMF_GPU_MODEL=""
    AMF_GPU_ARCH=""        # v42.1: rdna2/rdna3/rdna4/older
    AMF_CAP_HDR10=0
    AMF_CAP_10BIT=0
    AMF_CAP_AV1=0
    AMF_DEVICE=""
    AMF_EXPERIMENTAL=1   # Marcat experimental in UI

    [[ "$AV_PLATFORM" != "linux" ]] && return 1
    command -v ffmpeg >/dev/null 2>&1 || return 1

    # Encoders ffmpeg
    local enc_list
    enc_list=$(ffmpeg -hide_banner -encoders 2>/dev/null | grep -E "(h264|hevc|av1)_amf" | awk '{print $2}')
    [[ -z "$enc_list" ]] && return 1

    # GPU AMD prezent?
    if command -v lspci >/dev/null 2>&1; then
        local amd_check; amd_check=$(lspci 2>/dev/null | grep -iE "vga|display|3d" | grep -iE "amd|radeon|ati" | head -1)
        [[ -z "$amd_check" ]] && return 1
        AMF_GPU_VENDOR="AMD"
        AMF_GPU_MODEL=$(echo "$amd_check" | sed -E 's/.*: //;s/\(rev .*//')
    else
        return 1
    fi

    AMF_ENCODERS="$enc_list"
    AMF_CAP_10BIT=1
    AMF_CAP_HDR10=1

    # v42.1: detectie arhitectura GPU AMD (dGPU + iGPU)
    # RDNA4: RX 9000 series (Navi 4x)
    # RDNA3: RX 7000 series (Navi 31/32/33), RX 8000, iGPU Radeon 740M-890M
    #         (Phoenix/Hawk Point/Strix Point — Ryzen 7040/8040/AI 300)
    # RDNA2: RX 6000 series, iGPU 660M/680M (Rembrandt/Ryzen 6000)
    # iGPU AV1 encode: doar RDNA3+ (Phoenix+); RDNA2 iGPU = doar AV1 decode
    local model_lc; model_lc=$(echo "$AMF_GPU_MODEL" | tr '[:upper:]' '[:lower:]')

    if [[ "$model_lc" =~ rx.?9[0-9]{3}|navi.4 ]]; then
        AMF_GPU_ARCH="rdna4"
    elif [[ "$model_lc" =~ rx.?7[0-9]{3}|rx.?8[0-9]{3}|navi.3|rdna3 ]]; then
        AMF_GPU_ARCH="rdna3"
    elif [[ "$model_lc" =~ (radeon[[:space:]]+)?(graphics).*7[4-9]0m|(radeon[[:space:]]+)?(graphics).*8[0-9]0m|780m|760m|740m|880m|890m|phoenix|hawk[[:space:]]*point|strix ]]; then
        # iGPU RDNA3: Phoenix (740M/760M/780M), Hawk Point (refresh), Strix Point (880M/890M)
        AMF_GPU_ARCH="rdna3"
    elif [[ "$model_lc" =~ rx.?6[0-9]{3}|navi.2|rdna2|6[6-8]0m|rembrandt ]]; then
        AMF_GPU_ARCH="rdna2"
    else
        AMF_GPU_ARCH="older"
    fi

    # AV1 AMF: doar RDNA3+
    if [[ "$AMF_ENCODERS" == *"av1_amf"* ]]; then
        case "$AMF_GPU_ARCH" in
            rdna3|rdna4) AMF_CAP_AV1=1 ;;
            *) _hw_av1_amf_works && AMF_CAP_AV1=1 ;;  # v77: arch nerecunoscuta → probe (prinde RDNA viitor)
        esac
    fi

    AMF_AVAILABLE=1
    return 0
}

# ── Unified detection (apeleaza pe cele relevante platformei) ─────────
# Apeleaza la incepul flow-ului encode pentru a avea toate capabilitatile.
detect_all_hw_caps() {
    case "$AV_PLATFORM" in
        termux)
            detect_mediacodec_caps
            ;;
        linux)
            detect_nvenc_caps
            detect_qsv_caps
            detect_vaapi_caps
            detect_amf_caps
            ;;
        macos)
            detect_videotoolbox_caps
            ;;
    esac
}

# ── Lista backend-urilor disponibile pentru un codec dat ──────────────
# Args: $1 = codec target (h264|hevc|av1|prores)
# Output: lista (separate prin newline) de backends valide pentru codecul cerut.
hw_list_backends_for_codec() {
    local target="$1"
    local out=()
    case "$target" in
        h264|hevc|av1)
            [[ "${MC_AVAILABLE:-0}" == "1" ]]    && [[ "$MC_ENCODERS"    == *"${target}_mediacodec"*   ]] && out+=("mediacodec")
            [[ "${NVENC_AVAILABLE:-0}" == "1" ]] && [[ "$NVENC_ENCODERS" == *"${target}_nvenc"*        ]] && out+=("nvenc")
            [[ "${QSV_AVAILABLE:-0}" == "1" ]]   && [[ "$QSV_ENCODERS"   == *"${target}_qsv"*          ]] && out+=("qsv")
            [[ "${VAAPI_AVAILABLE:-0}" == "1" ]] && [[ "$VAAPI_ENCODERS" == *"${target}_vaapi"*        ]] && out+=("vaapi")
            [[ "${AMF_AVAILABLE:-0}" == "1" ]]   && [[ "$AMF_ENCODERS"   == *"${target}_amf"*          ]] && out+=("amf")
            [[ "${VT_AVAILABLE:-0}" == "1" ]]    && [[ "$VT_ENCODERS"    == *"${target}_videotoolbox"* ]] && out+=("videotoolbox")
            ;;
        prores)
            [[ "${VT_AVAILABLE:-0}" == "1" ]] && [[ "${VT_CAP_PRORES:-0}" == "1" ]] && out+=("videotoolbox")
            ;;
    esac
    printf '%s\n' "${out[@]}"
}

# ══════════════════════════════════════════════════════════════════════
# v42 Chunk 2: UX uniform — preset table + backend menu
# Slot 1=Ultrafast .. 7=Veryslow ; default 4=Quality
# Mapping per backend:
#   NVENC: p1..p7        | VAAPI: -quality 7..1 (iHD: 1=best/slow .. 7=fast; v75 inversat vs slot)
#   QSV: veryfast..veryslow
#   VideoToolbox: q:v 50..80 (v75: mai MARE = mai bun — corectat; era 80..50 invers)
#   AMF: speed/balanced/quality (3-tier mapped pe 1-7)
#   MediaCodec: scalare bitrate 60%..150%
# ══════════════════════════════════════════════════════════════════════
HW_PRESET_NAMES=(Ultrafast Faster Fast Quality Slow Slower Veryslow)

# Eticheta per backend pentru un slot dat (folosita in tabel + build cmd)
# Args: $1 = backend ; $2 = slot (1-7)
hw_preset_label() {
    local backend="$1" slot="$2"
    case "$backend" in
        nvenc)        echo "p${slot}" ;;
        vaapi)        echo "q$((8 - slot))" ;;  # v75: iHD -quality 1=best..7=fast → invers fata de slot
        qsv)
            local qsv_n=(veryfast faster fast medium slow slower veryslow)
            echo "${qsv_n[$((slot-1))]}"
            ;;
        videotoolbox)
            local vt_q=(50 55 60 65 70 75 80)  # v75: q:v mai mare = mai bun (corectat, era invers)
            echo "q:v ${vt_q[$((slot-1))]}"
            ;;
        amf)
            case "$slot" in
                1|2)   echo "speed"    ;;
                3|4|5) echo "balanced" ;;
                6|7)   echo "quality"  ;;
            esac
            ;;
        mediacodec)
            local mc_pct=(60 75 90 100 115 130 150)
            echo "${mc_pct[$((slot-1))]}%"
            ;;
        *) echo "—" ;;
    esac
}

# Determina ce coloane backend afisam in tabel pentru platforma curenta
# Output: HW_TABLE_COLS (array global)
hw_table_columns() {
    HW_TABLE_COLS=()
    case "$AV_PLATFORM" in
        termux) HW_TABLE_COLS+=("mediacodec") ;;
        macos)  HW_TABLE_COLS+=("videotoolbox") ;;
        linux)  HW_TABLE_COLS+=("nvenc" "vaapi" "qsv" "amf") ;;
    esac
}

# Header + width pentru o coloana backend
# Args: $1 = backend ; output: HW_COL_HEADER + HW_COL_WIDTH (globale temporare)
_hw_col_meta() {
    case "$1" in
        nvenc)        HW_COL_HEADER="NVENC"        ; HW_COL_WIDTH=10 ;;
        vaapi)        HW_COL_HEADER="VAAPI"        ; HW_COL_WIDTH=10 ;;
        qsv)          HW_COL_HEADER="QSV"          ; HW_COL_WIDTH=10 ;;
        videotoolbox) HW_COL_HEADER="VideoToolbox" ; HW_COL_WIDTH=14 ;;
        amf)          HW_COL_HEADER="AMF"          ; HW_COL_WIDTH=10 ;;
        mediacodec)   HW_COL_HEADER="MediaCodec"   ; HW_COL_WIDTH=12 ;;
        *)            HW_COL_HEADER="$1"           ; HW_COL_WIDTH=10 ;;
    esac
}

# Afiseaza tabelul preset 1-7 cu coloana activa highlighted
# Args: $1 = active_backend (numele backend-ului ales — coloana cu '>')
hw_show_preset_table() {
    local active="$1"
    hw_table_columns

    local YEL=$'\033[1;33m' DIM=$'\033[2m' NC=$'\033[0m'
    local cols=80
    if command -v tput >/dev/null 2>&1; then
        cols=$(tput cols 2>/dev/null) || cols=80
    fi

    # Estimeaza latimea totala (#=4, Nume=12, fiecare backend+separator=width+3)
    local total=$((4+12))
    local b
    for b in "${HW_TABLE_COLS[@]}"; do
        _hw_col_meta "$b"
        total=$((total + HW_COL_WIDTH + 3))
    done

    # Daca terminalul e prea ingust, afiseaza doar coloana activa (+ # + Nume)
    local cols_to_show=("${HW_TABLE_COLS[@]}")
    if (( cols < total )); then
        cols_to_show=()
        for b in "${HW_TABLE_COLS[@]}"; do
            [[ "$b" == "$active" ]] && cols_to_show+=("$b")
        done
        # daca activul nu e in lista (cazul SW), pastram primul
        [[ ${#cols_to_show[@]} -eq 0 ]] && cols_to_show=("${HW_TABLE_COLS[0]}")
    fi

    # Header row
    printf "  %-3s %-12s" "#" "Nume"
    for b in "${cols_to_show[@]}"; do
        _hw_col_meta "$b"
        if [[ "$b" == "$active" ]]; then
            printf " %s> %-*s%s" "$YEL" "$HW_COL_WIDTH" "$HW_COL_HEADER" "$NC"
        else
            printf "   %s%-*s%s" "$DIM" "$HW_COL_WIDTH" "$HW_COL_HEADER" "$NC"
        fi
    done
    echo ""

    # Separator
    printf "  --- ------------"
    for b in "${cols_to_show[@]}"; do
        _hw_col_meta "$b"
        local sep=""
        local k
        for ((k=0; k<HW_COL_WIDTH; k++)); do sep+="-"; done
        printf "   %s" "$sep"
    done
    echo ""

    # Rows
    local slot
    for slot in 1 2 3 4 5 6 7; do
        local name="${HW_PRESET_NAMES[$((slot-1))]}"
        printf "  %-3d %-12s" "$slot" "$name"
        for b in "${cols_to_show[@]}"; do
            _hw_col_meta "$b"
            local lbl; lbl=$(hw_preset_label "$b" "$slot")
            if [[ "$b" == "$active" ]]; then
                printf " %s> %-*s%s" "$YEL" "$HW_COL_WIDTH" "$lbl" "$NC"
            else
                printf "   %s%-*s%s" "$DIM" "$HW_COL_WIDTH" "$lbl" "$NC"
            fi
        done
        echo ""
    done
}

# Eticheta umana pentru un backend (folosita in meniu)
hw_backend_label() {
    case "$1" in
        sw)           echo "SW (CPU — libx265/libx264/libsvtav1)" ;;
        nvenc)        echo "NVENC (NVIDIA GPU${NVENC_GPU_MODEL:+ — $NVENC_GPU_MODEL})" ;;
        vaapi)        echo "VAAPI (${VAAPI_GPU_VENDOR:-Linux}${VAAPI_GPU_MODEL:+ — $VAAPI_GPU_MODEL})" ;;
        qsv)          echo "QSV (Intel Quick Sync${QSV_GPU_MODEL:+ — $QSV_GPU_MODEL})" ;;
        videotoolbox) echo "VideoToolbox (${VT_CHIP:-macOS})" ;;
        amf)          echo "AMF [experimental] (AMD ${AMF_GPU_ARCH:-?}${AMF_GPU_MODEL:+ — $AMF_GPU_MODEL})" ;;
        mediacodec)   echo "MediaCodec (Android HW${MC_SOC_LABEL:+ — $MC_SOC_LABEL})" ;;
        *)            echo "$1" ;;
    esac
}

# Meniu interactiv backend pentru codecul tinta. Adauga mereu SW + HW disponibile.
# Args: $1 = target codec (h264|hevc|av1|prores)
# Set: HW_BACKEND ("sw" sau numele backend-ului HW). Returns 0.
hw_pick_backend() {
    local target="$1"
    local avail; avail=$(hw_list_backends_for_codec "$target")

    local opts=("sw")
    local b
    while IFS= read -r b; do
        [[ -n "$b" ]] && opts+=("$b")
    done <<< "$avail"

    # Daca nu exista HW pentru codecul tinta, salt direct la SW
    if [[ ${#opts[@]} -eq 1 ]]; then
        HW_BACKEND="sw"
        return 0
    fi

    echo ""
    echo "  Backend de encodare:"
    local i=1
    for b in "${opts[@]}"; do
        printf "    %d) %s\n" "$i" "$(hw_backend_label "$b")"
        ((i++))
    done

    local choice
    read -p "  Alege [1-${#opts[@]}, default 1]: " choice
    choice="${choice:-1}"
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#opts[@]} )); then
        echo "  Selectie invalida — folosesc SW."
        HW_BACKEND="sw"
    else
        HW_BACKEND="${opts[$((choice-1))]}"
    fi
    return 0
}

# Selectie slot preset 1-7 cu afisarea tabelului. Default 4 (Quality).
# Args: $1 = backend (daca == "sw" sau gol, returneaza fara prompt)
# Set: HW_PRESET_SLOT (1-7)
hw_pick_preset() {
    local backend="$1"
    [[ -z "$backend" || "$backend" == "sw" ]] && { HW_PRESET_SLOT=""; return 0; }

    echo ""
    echo "  Tabel preset HW (1=cel mai rapid, 7=calitate max):"
    echo ""
    hw_show_preset_table "$backend"
    echo ""
    local choice
    read -p "  Alege slot preset [1-7, default 4]: " choice
    choice="${choice:-4}"
    if ! [[ "$choice" =~ ^[1-7]$ ]]; then
        echo "  Slot invalid — folosesc 4 (Quality)."
        choice=4
    fi
    HW_PRESET_SLOT="$choice"
    echo "  → Selectat: slot $choice (${HW_PRESET_NAMES[$((choice-1))]}) pe backend $backend = $(hw_preset_label "$backend" "$choice")"
}

# ══════════════════════════════════════════════════════════════════════
# v38: BUILD MEDIACODEC FFMPEG_CMD
# Args: $1 = file ; $2 = enc_codec (hevc|h264|av1)
# Citeste env: WIDTH, MC_HDR_MODE, MC_CAP_HEVC10, AUDIO_PARAMS, MAP_FLAGS, THREADS
# Seteaza: FFMPEG_CMD (ca string), MC_NEEDS_REPAIR (0/1) pentru post-encode SEI
# MC_HDR_MODE valori:
#   ""           — SDR encode normal (pentru surse SDR)
#   hw_repair    — 10-bit + signaling HDR10 + repair flag setat
#   hw_hlg       — v39: 10-bit + transfer=arib-std-b67 (HLG nativ, fără SEI repair)
#   hw_sdr       — tonemap HDR→SDR 8-bit
# (sw_full / sw_degraded sunt rezolvate inainte de a ajunge aici — nu se cheama mediacodec)
# ══════════════════════════════════════════════════════════════════════
build_mediacodec_cmd() {
    local file="$1" enc_codec="$2"
    local enc_name="${enc_codec}_mediacodec"
    MC_NEEDS_REPAIR=0

    # Rate control: respecta ENCODE_MODE=2 (VBR custom) daca user a setat target
    local bitrate maxrate bufsize rate_flags
    if [[ "${ENCODE_MODE:-1}" =~ ^[23]$ ]] && [[ -n "${VBR_TARGET:-}" ]]; then
        # VBR_TARGET vine ca "8M" sau "8000k" — extrage numarul ca kbps
        local vt="$VBR_TARGET"
        if [[ "$vt" =~ ^([0-9]+)[Mm]$ ]]; then bitrate=$(( ${BASH_REMATCH[1]} * 1000 ))
        elif [[ "$vt" =~ ^([0-9]+)[Kk]$ ]]; then bitrate="${BASH_REMATCH[1]}"
        elif [[ "$vt" =~ ^[0-9]+$ ]]; then bitrate=$(( vt / 1000 ))
        else bitrate=$(get_adaptive_bitrate "$enc_name" "$WIDTH"); fi
        local mr="${VBR_MAXRATE:-}"
        if [[ "$mr" =~ ^([0-9]+)[Mm]$ ]]; then maxrate=$(( ${BASH_REMATCH[1]} * 1000 ))
        elif [[ "$mr" =~ ^([0-9]+)[Kk]$ ]]; then maxrate="${BASH_REMATCH[1]}"
        else maxrate=$(( bitrate * 3 / 2 )); fi
    else
        bitrate=$(get_adaptive_bitrate "$enc_name" "$WIDTH")
        maxrate=$(( bitrate * 3 / 2 ))
    fi
    # v42: HW_PRESET_SLOT scaleaza bitrate-ul (60%..150%) — paralel cu p1..p7 pe NVENC
    # Aplicat doar pentru CRF mode (ENCODE_MODE=1); VBR custom pastreaza target user
    if [[ "${ENCODE_MODE:-1}" != "2" ]] && [[ -n "${HW_PRESET_SLOT:-}" ]]; then
        local mc_pct=(60 75 90 100 115 130 150)
        local pct="${mc_pct[$((HW_PRESET_SLOT-1))]}"
        if [[ -n "$pct" ]]; then
            bitrate=$(( bitrate * pct / 100 ))
            maxrate=$(( bitrate * 3 / 2 ))
        fi
    fi
    bufsize=$(( bitrate * 2 ))
    rate_flags="-b:v ${bitrate}k -maxrate ${maxrate}k -bufsize ${bufsize}k"

    local pix_fmt color_flags="" mc_extra_vf="" profile_flag=""

    # v53: VUI inject via BSF (acelasi pattern ca celelalte HW backends).
    # Naming sub-options difera: HEVC foloseste 'colour_*', H.264/AV1 foloseste 'color_*'.
    local bsf_name="" vui_bsf=""
    case "$enc_codec" in
        hevc) bsf_name="hevc_metadata" ;;
        h264) bsf_name="h264_metadata" ;;
        av1)  bsf_name="av1_metadata" ;;
    esac
    case "${MC_HDR_MODE:-}" in
        hw_repair)
            # 10-bit HDR10: BT.2020 + PQ + main10 (doar HEVC suporta main10)
            # NOTA (v75): encoderele mediacodec ffmpeg accepta DOAR 8-bit input
            # (mediacodec/yuv420p/nv12) — un pix_fmt 10-bit auto-downconverteaza la yuv420p
            # (validat empiric S24 Ultra + A54: "Incompatible pixel format ... auto-selecting
            # yuv420p"). main10 da container/signaling 10-bit (HDR10 cere 10-bit) dar
            # PRECIZIA ramane 8-bit → risc de banding pe HDR real. ffmpeg nu poate hrani
            # 10-bit catre MediaCodec pe calea cu filtre azi; cerem p010le DOAR daca un
            # ffmpeg viitor expune 10-bit input (MC_INPUT_10BIT, probe in detect) → forward-compat.
            if [[ "$MC_CAP_HEVC10" == "1" ]] && [[ "$enc_codec" == "hevc" ]]; then
                if [[ "${MC_INPUT_10BIT:-0}" == "1" ]]; then pix_fmt="p010le"; else pix_fmt="yuv420p"; fi
                profile_flag="-profile:v main10"
            else
                pix_fmt="yuv420p"
                log "  ATENTIE: SoC nu suporta 10-bit (sau codec != HEVC), fallback la 8-bit"
            fi
            if [[ "$enc_codec" == "hevc" ]]; then
                vui_bsf="-bsf:v ${bsf_name}=colour_primaries=9:transfer_characteristics=16:matrix_coefficients=9"
            else
                vui_bsf="-bsf:v ${bsf_name}=color_primaries=9:transfer_characteristics=16:matrix_coefficients=9"
            fi
            MC_NEEDS_REPAIR=1
            ;;
        hw_hlg)
            # v39: HLG nativ — signaling in transfer chars (fara SEI repair)
            # v75: 8-bit input azi (vezi nota hw_repair) — main10 = container/signaling
            # 10-bit, precizie 8-bit. p010le DOAR pe ffmpeg viitor cu 10-bit input (MC_INPUT_10BIT).
            if [[ "$MC_CAP_HEVC10" == "1" ]] && [[ "$enc_codec" == "hevc" ]]; then
                if [[ "${MC_INPUT_10BIT:-0}" == "1" ]]; then pix_fmt="p010le"; else pix_fmt="yuv420p"; fi
                profile_flag="-profile:v main10"
            elif [[ "$enc_codec" == "av1" ]]; then
                if [[ "${MC_INPUT_10BIT:-0}" == "1" ]]; then pix_fmt="p010le"; else pix_fmt="yuv420p"; fi
            else
                pix_fmt="yuv420p"
                log "  ATENTIE: SoC nu suporta 10-bit pentru HLG, fallback la 8-bit"
            fi
            if [[ "$enc_codec" == "hevc" ]]; then
                vui_bsf="-bsf:v ${bsf_name}=colour_primaries=9:transfer_characteristics=18:matrix_coefficients=9"
            else
                vui_bsf="-bsf:v ${bsf_name}=color_primaries=9:transfer_characteristics=18:matrix_coefficients=9"
            fi
            ;;
        hw_sdr)
            # Tonemap HDR→SDR 8-bit
            pix_fmt="yuv420p"
            if [[ "$enc_codec" == "hevc" ]]; then
                vui_bsf="-bsf:v ${bsf_name}=colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1"
            else
                vui_bsf="-bsf:v ${bsf_name}=color_primaries=1:transfer_characteristics=1:matrix_coefficients=1"
            fi
            mc_extra_vf="zscale=t=linear:npl=100,tonemap=hable:desat=0,zscale=t=bt709:p=bt709:m=bt709,format=yuv420p"
            ;;
        *)
            pix_fmt="yuv420p"
            ;;
    esac

    # Inject extra VF (tonemap) in VIDEO_FILTER global
    if [[ -n "$mc_extra_vf" ]]; then
        if [[ -n "$VIDEO_FILTER" ]] && [[ "$VIDEO_FILTER" == *"-vf "* ]]; then
            VIDEO_FILTER="${VIDEO_FILTER/-vf /-vf ${mc_extra_vf},}"
        else
            VIDEO_FILTER="-vf $mc_extra_vf"
        fi
    fi

    log "  MediaCodec: $enc_name | bitrate ${bitrate}k / max ${maxrate}k | pix_fmt $pix_fmt"
    [[ -n "${MC_HDR_MODE:-}" ]] && log "  Mod HDR    : $MC_HDR_MODE"

    # v53: $vui_bsf inlocuieste $color_flags broken (vezi nota _hw_hdr_setup)
    FFMPEG_CMD="ffmpeg -threads $THREADS -i \"\$file\" $MAP_FLAGS \
        -c:v $enc_name $rate_flags \
        $profile_flag -pix_fmt $pix_fmt $VIDEO_FILTER $vui_bsf $AUDIO_PARAMS"

    return 0
}

# ══════════════════════════════════════════════════════════════════════
# v42 Chunk 3: Build commands per backend (NVENC/VAAPI/QSV/VT/AMF)
# Toate citesc: WIDTH, HW_PRESET_SLOT, ENCODE_MODE, VBR_TARGET, VBR_MAXRATE,
#   CUSTOM_CRF, AUDIO_PARAMS, MAP_FLAGS, VIDEO_FILTER, THREADS, HW_HDR_MODE
# Toate seteaza: FFMPEG_CMD (string)
# HW_HDR_MODE valori: ""/sdr | hw_hdr10 | hw_hlg | hw_sdr (tonemap)
# ══════════════════════════════════════════════════════════════════════

# Helper comun: returneaza pix_fmt + profile + BSF (VUI inject) pe baza HW_HDR_MODE
# Args: $1 = enc_codec (hevc/h264/av1)
# Output globals: _HW_PIX_FMT / _HW_PROFILE / _HW_VUI_BSF
#
# v53 fix: ffmpeg -color_primaries/-color_trc/-colorspace flags NU propaga corect
# la HW encoders (verificat live pe hevc_qsv: stream produs cu bt2020nc/unknown/
# unknown chiar cu flags setate, paralel cu bug-ul SW v52 din x265). Soluție:
# bitstream filter post-encode (hevc_metadata/av1_metadata/h264_metadata) care
# rescrie VUI in SPS/OBU. Verificat live: bt2020nc/bt2020/smpte2084 corect.
# Valori AV1/HEVC/H.264 (toate folosesc același tabel ITU-T H.273):
#   BT.2020 primaries=9 / BT.709 primaries=1
#   PQ transfer=16 / HLG transfer=18 / BT.709 transfer=1
#   BT.2020nc matrix=9 / BT.709 matrix=1
_hw_hdr_setup() {
    local enc_codec="$1"
    _HW_PIX_FMT="yuv420p"
    _HW_VUI_BSF=""
    _HW_PROFILE=""

    # BSF name per codec
    local bsf_name=""
    case "$enc_codec" in
        hevc) bsf_name="hevc_metadata" ;;
        h264) bsf_name="h264_metadata" ;;
        av1)  bsf_name="av1_metadata" ;;
    esac

    case "${HW_HDR_MODE:-}" in
        hw_hdr10|hw_repair)
            _HW_PIX_FMT="p010le"
            [[ "$enc_codec" == "hevc" ]] && _HW_PROFILE="-profile:v main10"
            # BSF cere variantele de naming diferite (HEVC: colour_*, H.264/AV1: color_*)
            if [[ "$enc_codec" == "hevc" ]]; then
                _HW_VUI_BSF="-bsf:v ${bsf_name}=colour_primaries=9:transfer_characteristics=16:matrix_coefficients=9"
            else
                _HW_VUI_BSF="-bsf:v ${bsf_name}=color_primaries=9:transfer_characteristics=16:matrix_coefficients=9"
            fi
            ;;
        hw_hlg)
            _HW_PIX_FMT="p010le"
            [[ "$enc_codec" == "hevc" ]] && _HW_PROFILE="-profile:v main10"
            if [[ "$enc_codec" == "hevc" ]]; then
                _HW_VUI_BSF="-bsf:v ${bsf_name}=colour_primaries=9:transfer_characteristics=18:matrix_coefficients=9"
            else
                _HW_VUI_BSF="-bsf:v ${bsf_name}=color_primaries=9:transfer_characteristics=18:matrix_coefficients=9"
            fi
            ;;
        hw_sdr)
            _HW_PIX_FMT="yuv420p"
            if [[ "$enc_codec" == "hevc" ]]; then
                _HW_VUI_BSF="-bsf:v ${bsf_name}=colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1"
            else
                _HW_VUI_BSF="-bsf:v ${bsf_name}=color_primaries=1:transfer_characteristics=1:matrix_coefficients=1"
            fi
            local sdr_vf="zscale=t=linear:npl=100,tonemap=hable:desat=0,zscale=t=bt709:p=bt709:m=bt709,format=yuv420p"
            if [[ -n "$VIDEO_FILTER" ]] && [[ "$VIDEO_FILTER" == "-vf "* ]]; then
                VIDEO_FILTER="${VIDEO_FILTER/-vf /-vf ${sdr_vf},}"
            else
                VIDEO_FILTER="-vf $sdr_vf"
            fi
            ;;
    esac

    # Back-compat: _HW_COLOR_FLAGS pastrat ca empty pentru ramurile care il citesc
    # in alte parti (ex: profile dialogs). v53: nu mai contine flags care strica VUI.
    _HW_COLOR_FLAGS=""
}

# ── NVENC (NVIDIA) ────────────────────────────────────────────────────
build_nvenc_cmd() {
    local file="$1" enc_codec="$2"
    local enc_name="${enc_codec}_nvenc"
    local slot="${HW_PRESET_SLOT:-4}"
    local preset="p${slot}"

    local rate_flags multipass_flag="" quality_flags=""
    if [[ "${ENCODE_MODE:-1}" =~ ^[23]$ ]] && [[ -n "${VBR_TARGET:-}" ]]; then
        rate_flags="-rc vbr -b:v ${VBR_TARGET} -maxrate ${VBR_MAXRATE:-${VBR_TARGET}} -bufsize ${VBR_TARGET}"
        # v53: NVENC suporta multipass intern (single command, internal 2-pass).
        # ENCODE_MODE=3 (2-pass VBR) activeaza -multipass fullres pentru calitate
        # superioara la acelasi bitrate. Cost: encode ~30-50% mai lent (tot mult
        # mai rapid decat SW 2-pass).
        if [[ "${ENCODE_MODE:-1}" == "3" ]]; then
            multipass_flag="-multipass fullres"
            # v53 quality boost (mode 3 explicit cere calitate):
            #   -bf 4               : B-frames 4 (default 3 hevc, +B = compresie mai buna)
            #   -rc-lookahead 32    : lookahead 32 cadre (mai buna alocare bitrate)
            #   -aq-strength 10     : AQ aggressive (anti-banding flat areas)
            #   -weighted_pred 1    : prediction ponderat pe fade-uri/dizolvari
            # Pe codec av1: -weighted_pred nu se aplica, restul OK
            if [[ "$enc_codec" == "av1" ]]; then
                quality_flags="-bf 4 -rc-lookahead 32 -aq-strength 10"
            else
                quality_flags="-bf 4 -rc-lookahead 32 -aq-strength 10 -weighted_pred 1"
            fi
            log "  NVENC mode 3 boost: multipass fullres + bf=4 + lookahead=32 + aq-strength=10"
        fi
    else
        local crf="${CUSTOM_CRF:-$(get_adaptive_crf "$enc_codec" "$WIDTH")}"
        rate_flags="-rc vbr -cq $crf -b:v 0"
    fi

    _hw_hdr_setup "$enc_codec"

    log "  NVENC: $enc_name | preset $preset | pix_fmt $_HW_PIX_FMT${HW_HDR_MODE:+ | hdr=$HW_HDR_MODE}"

    # v53: $_HW_VUI_BSF post-encode injecteaza VUI corect (BT.2020+PQ/HLG sau BT.709)
    # via hevc_metadata/av1_metadata/h264_metadata BSF. Inlocuieste vechile
    # ffmpeg -color_primaries/-color_trc/-colorspace flags care nu propagau la
    # encoder VUI corect → stream cu bt2020nc/unknown/unknown.
    FFMPEG_CMD="ffmpeg -threads $THREADS -i \"\$file\" $MAP_FLAGS \
        -c:v $enc_name -preset $preset -tune hq $rate_flags $multipass_flag $quality_flags \
        -spatial_aq 1 -temporal_aq 1 \
        $_HW_PROFILE -pix_fmt $_HW_PIX_FMT $VIDEO_FILTER $_HW_VUI_BSF $AUDIO_PARAMS"
    return 0
}

# ── QSV (Intel Quick Sync) ────────────────────────────────────────────
build_qsv_cmd() {
    local file="$1" enc_codec="$2"
    local enc_name="${enc_codec}_qsv"
    local slot="${HW_PRESET_SLOT:-4}"
    local qsv_n=(veryfast faster fast medium slow slower veryslow)
    local preset="${qsv_n[$((slot-1))]}"

    local rate_flags
    if [[ "${ENCODE_MODE:-1}" =~ ^[23]$ ]] && [[ -n "${VBR_TARGET:-}" ]]; then
        rate_flags="-b:v ${VBR_TARGET} -maxrate ${VBR_MAXRATE:-${VBR_TARGET}}"
    else
        local crf="${CUSTOM_CRF:-$(get_adaptive_crf "$enc_codec" "$WIDTH")}"
        rate_flags="-global_quality $crf -look_ahead 1"
    fi

    _hw_hdr_setup "$enc_codec"
    # QSV foloseste nv12 pentru SDR (nu yuv420p)
    [[ "$_HW_PIX_FMT" == "yuv420p" ]] && _HW_PIX_FMT="nv12"

    log "  QSV: $enc_name | preset $preset | pix_fmt $_HW_PIX_FMT${HW_HDR_MODE:+ | hdr=$HW_HDR_MODE}"

    # v53: $_HW_VUI_BSF — vezi nota la NVENC
    FFMPEG_CMD="ffmpeg -threads $THREADS -i \"\$file\" $MAP_FLAGS \
        -c:v $enc_name -preset $preset $rate_flags \
        $_HW_PROFILE -pix_fmt $_HW_PIX_FMT $VIDEO_FILTER $_HW_VUI_BSF $AUDIO_PARAMS"
    return 0
}

# ── VAAPI (Linux Intel iGPU + AMD) ────────────────────────────────────
# VAAPI necesita hwupload la finalul lantului SW (-vf '...,format=X,hwupload')
build_vaapi_cmd() {
    local file="$1" enc_codec="$2"
    local enc_name="${enc_codec}_vaapi"
    local slot="${HW_PRESET_SLOT:-4}"
    # v75: VAAPI iHD -quality 1=best(slow)..7=fast → invers fata de slot (1=fast..7=best).
    # Neverificat pe Linux real (lipsa GPU); AMD Mesa ignora -quality. Caveat audit.
    local vaapi_q=$((8 - slot))

    local rate_flags
    if [[ "${ENCODE_MODE:-1}" =~ ^[23]$ ]] && [[ -n "${VBR_TARGET:-}" ]]; then
        rate_flags="-rc_mode VBR -b:v ${VBR_TARGET} -maxrate ${VBR_MAXRATE:-${VBR_TARGET}}"
    else
        local crf="${CUSTOM_CRF:-$(get_adaptive_crf "$enc_codec" "$WIDTH")}"
        rate_flags="-rc_mode CQP -qp $crf"
    fi

    _hw_hdr_setup "$enc_codec"
    local upload_fmt="nv12"
    [[ "$_HW_PIX_FMT" == "p010le" ]] && upload_fmt="p010"

    # Append format+hwupload la finalul lantului VF (sau creeaza unul nou)
    local va_tail="format=${upload_fmt},hwupload"
    if [[ -n "$VIDEO_FILTER" ]] && [[ "$VIDEO_FILTER" == "-vf "* ]]; then
        VIDEO_FILTER="${VIDEO_FILTER},${va_tail}"
    else
        VIDEO_FILTER="-vf ${va_tail}"
    fi

    log "  VAAPI: $enc_name | quality $vaapi_q (slot $slot) | device $VAAPI_DEVICE${HW_HDR_MODE:+ | hdr=$HW_HDR_MODE}"

    # v53: $_HW_VUI_BSF — vezi nota la NVENC
    FFMPEG_CMD="ffmpeg -threads $THREADS -vaapi_device $VAAPI_DEVICE -i \"\$file\" $MAP_FLAGS \
        -c:v $enc_name -quality $vaapi_q $rate_flags \
        $_HW_PROFILE $VIDEO_FILTER $_HW_VUI_BSF $AUDIO_PARAMS"
    return 0
}

# ── VideoToolbox (macOS) ──────────────────────────────────────────────
build_videotoolbox_cmd() {
    local file="$1" enc_codec="$2"
    local enc_name
    case "$enc_codec" in
        prores) enc_name="prores_videotoolbox" ;;
        *)      enc_name="${enc_codec}_videotoolbox" ;;
    esac
    local slot="${HW_PRESET_SLOT:-4}"
    # v75: q:v mai mare = mai bun in VideoToolbox (ffmpeg vtenc: -q:v N → quality N/100).
    # Era 80..50 invers (slot 7 best primea q:v cel mai mic). Neverificat pe Mac real.
    local vt_q=(50 55 60 65 70 75 80)
    local q="${vt_q[$((slot-1))]}"

    local rate_flags
    if [[ "${ENCODE_MODE:-1}" =~ ^[23]$ ]] && [[ -n "${VBR_TARGET:-}" ]]; then
        rate_flags="-b:v ${VBR_TARGET}"
    else
        rate_flags="-q:v $q"
    fi

    _hw_hdr_setup "$enc_codec"

    log "  VideoToolbox: $enc_name | q $q (slot $slot) | pix_fmt $_HW_PIX_FMT${HW_HDR_MODE:+ | hdr=$HW_HDR_MODE}"

    # v53: $_HW_VUI_BSF — vezi nota la NVENC. NOTA: VideoToolbox + ProRes nu
    # produc HDR10 cu mastering-display via BSF — pentru full HDR10 quality pe
    # macOS Apple Silicon, foloseste SW (x265) sau VideoToolbox cu post-process
    # mkvmerge/mkvpropedit (out of scope v53).
    FFMPEG_CMD="ffmpeg -threads $THREADS -i \"\$file\" $MAP_FLAGS \
        -c:v $enc_name $rate_flags -allow_sw 0 \
        $_HW_PROFILE -pix_fmt $_HW_PIX_FMT $VIDEO_FILTER $_HW_VUI_BSF $AUDIO_PARAMS"
    return 0
}

# ── AMF (AMD Linux — experimental) ────────────────────────────────────
# v42.1: AV1-specific tuning, VBR_BUFSIZE fix, usage transcoding default
build_amf_cmd() {
    local file="$1" enc_codec="$2"
    local enc_name="${enc_codec}_amf"
    local slot="${HW_PRESET_SLOT:-4}"
    local quality
    case "$slot" in
        1|2)   quality="speed"    ;;
        3|4|5) quality="balanced" ;;
        6|7)   quality="quality"  ;;
    esac

    # v42.1: VBR_BUFSIZE propagat (lipsea); AV1 AMF nu suporta B-frames -> fara -qp_b
    local rate_flags
    if [[ "${ENCODE_MODE:-1}" =~ ^[23]$ ]] && [[ -n "${VBR_TARGET:-}" ]]; then
        local maxrate="${VBR_MAXRATE:-${VBR_TARGET}}"
        local bufsize="${VBR_BUFSIZE:-${maxrate}}"
        rate_flags="-rc vbr_peak -b:v ${VBR_TARGET} -maxrate ${maxrate} -bufsize ${bufsize}"
    else
        local crf="${CUSTOM_CRF:-$(get_adaptive_crf "$enc_codec" "$WIDTH")}"
        if [[ "$enc_codec" == "av1" ]]; then
            rate_flags="-rc cqp -qp_i $crf -qp_p $crf"
        else
            rate_flags="-rc cqp -qp_i $crf -qp_p $crf -qp_b $crf"
        fi
    fi

    _hw_hdr_setup "$enc_codec"

    # v42.1: -usage transcoding (default AMF e "ultralowlatency" — gresit pentru offline)
    local usage_flags="-usage transcoding"

    # v42.1: AV1-specific — profile main (8/10-bit), level auto
    local codec_flags=""
    if [[ "$enc_codec" == "av1" ]]; then
        codec_flags="-profile:v main"
    fi

    log "  AMF: $enc_name | quality $quality (slot $slot) | pix_fmt $_HW_PIX_FMT${HW_HDR_MODE:+ | hdr=$HW_HDR_MODE}${AMF_GPU_ARCH:+ | arch=$AMF_GPU_ARCH}"

    # v53: $_HW_VUI_BSF — vezi nota la NVENC
    FFMPEG_CMD="ffmpeg -threads $THREADS -i \"\$file\" $MAP_FLAGS \
        -c:v $enc_name $usage_flags -quality $quality $rate_flags $codec_flags \
        $_HW_PROFILE -pix_fmt $_HW_PIX_FMT $VIDEO_FILTER $_HW_VUI_BSF $AUDIO_PARAMS"
    return 0
}

# ══════════════════════════════════════════════════════════════════════
# v42 Chunk 5: HDR generalizat peste backend-uri HW
# Generalizare a show_hdr_mediacodec_dialog pentru NVENC/VAAPI/QSV/VT/AMF.
# Sets HW_HDR_MODE: sw_full | sw_degraded | hw_hdr10 | hw_hlg | hw_sdr | hw_preserve (v46)
# Returns: 0 mode set | 98 user skip
# Profile bypass via HW_HDR_POLICY env (sau MEDIACODEC_HDR_POLICY pentru MC).
# v46: hw_preserve apare DOAR pentru DV src_type cand enc_codec in (hevc|av1)
#      si tool-urile DV sunt disponibile pentru source codec + target codec.
# ══════════════════════════════════════════════════════════════════════
show_hdr_hw_dialog() {
    local backend="$1" src_type="$2" dv_p="${3:-}" enc_codec="${4:-}" src_codec="${5:-}"
    HW_HDR_MODE=""

    # v46: gate pentru hw_preserve (DV preserve via HW backend)
    local _can_hw_preserve=0
    if [[ "$src_type" == "dv" ]] && [[ "$enc_codec" == "hevc" || "$enc_codec" == "av1" ]]; then
        if _check_dovi_tool_for "${src_codec:-hevc}" && _check_dovi_tool_for "$enc_codec"; then
            _can_hw_preserve=1
        fi
    fi
    # v76: gate pentru hw_preserve_hdr10plus (HDR10+ dinamic preserve via HW + post-encode inject)
    local _can_hw_preserve_hp=0
    if [[ "$src_type" == "hdr10plus" ]] && [[ "$enc_codec" == "hevc" || "$enc_codec" == "av1" ]]; then
        if _check_hdr10plus_tool_for "${src_codec:-hevc}" && _check_hdr10plus_tool_for "$enc_codec"; then
            _can_hw_preserve_hp=1
        fi
    fi

    local policy="${HW_HDR_POLICY:-}"
    [[ "$backend" == "mediacodec" ]] && [[ -n "${MEDIACODEC_HDR_POLICY:-}" ]] && policy="$MEDIACODEC_HDR_POLICY"
    if [[ -n "$policy" ]]; then
        case "$policy" in
            sw_full|sw_degraded|hw_hdr10|hw_hlg|hw_sdr|hw_repair)
                HW_HDR_MODE="$policy"
                [[ "$policy" == "hw_repair" ]] && HW_HDR_MODE="hw_hdr10"
                log "  HW HDR policy din profil: $HW_HDR_MODE"
                return 0 ;;
            hw_preserve)
                if [[ "$src_type" == "hdr10plus" ]] && [ $_can_hw_preserve_hp -eq 1 ]; then
                    HW_HDR_MODE="hw_preserve_hdr10plus"
                    log "  HW HDR policy: hw_preserve (HDR10+ preserve via $backend)"
                    return 0
                elif [ $_can_hw_preserve -eq 1 ]; then
                    HW_HDR_MODE="hw_preserve"
                    log "  HW HDR policy: hw_preserve (DV preserve via $backend)"
                    return 0
                else
                    HW_HDR_MODE="hw_hdr10"
                    log "  HW HDR policy=hw_preserve dar tool indisponibil — fallback hw_hdr10"
                    return 0
                fi ;;
            skip)
                log "  HW HDR policy din profil: skip"; return 98 ;;
        esac
    fi

    local bl="$backend"
    echo ""
    echo "  +======================================================+"
    case "$src_type" in
        dv)
            echo "  |  ! Sursa este Dolby Vision (profil ${dv_p:-?})"
            echo "  |  $bl nu poate produce DV nativ direct. Optiuni:"
            echo "  +------------------------------------------------------+"
            echo "  |  1) SW - pastreaza DV complet (recomandat baseline)"
            echo "  |  2) SW - strip DV, pastreaza HDR10 BL"
            if [ $_can_hw_preserve -eq 1 ]; then
                echo "  |  3) $bl - DV preserve (HDR10 base + inject RPU)"
                echo "  |     extrage RPU sursa ($src_codec) -> HW encode -> inject"
                echo "  |  4) $bl - strip DV -> HDR10 10-bit"
                echo "  |  5) $bl - strip DV -> SDR tonemap 8-bit"
                echo "  |  6) Skip fisier"
                echo "  +======================================================+"
                read -p "  Alege 1-6 [implicit: 1]: " _ch
                case "${_ch:-1}" in
                    2) HW_HDR_MODE="sw_degraded" ;;
                    3) HW_HDR_MODE="hw_preserve" ;;
                    4) HW_HDR_MODE="hw_hdr10"    ;;
                    5) HW_HDR_MODE="hw_sdr"      ;;
                    6) return 98 ;;
                    *) HW_HDR_MODE="sw_full"     ;;
                esac
            else
                echo "  |  3) $bl - strip DV -> HDR10 10-bit"
                echo "  |  4) $bl - strip DV -> SDR tonemap 8-bit"
                echo "  |  5) Skip fisier"
                echo "  +======================================================+"
                read -p "  Alege 1-5 [implicit: 1]: " _ch
                case "${_ch:-1}" in
                    2) HW_HDR_MODE="sw_degraded" ;;
                    3) HW_HDR_MODE="hw_hdr10"    ;;
                    4) HW_HDR_MODE="hw_sdr"      ;;
                    5) return 98 ;;
                    *) HW_HDR_MODE="sw_full"     ;;
                esac
            fi
            ;;
        hdr10plus)
            echo "  |  ! Sursa este HDR10+ (cu dynamic metadata)"
            echo "  |  $bl nu transmite dynamic metadata nativ. Optiuni:"
            echo "  +------------------------------------------------------+"
            if [ $_can_hw_preserve_hp -eq 1 ]; then
                # v76: pe calea HW, preserve via inject e recomandat (userul a ales HW;
                # dinamicul e re-injectat byte-exact → HW speed + HDR10+ pastrat). SW-full
                # ramane disponibil (encoder SW). Default = HW preserve.
                echo "  |  1) $bl - preserve HDR10+ via inject (recomandat)"
                echo "  |     HW encode HDR10 base -> re-inject metadata sursa"
                echo "  |  2) SW - pastreaza HDR10+ complet (encoder SW)"
                echo "  |  3) SW - HDR10 static (drop dynamic)"
                echo "  |  4) $bl - HDR10 10-bit (drop dynamic)"
                echo "  |  5) $bl - SDR tonemap 8-bit"
                echo "  |  6) Skip fisier"
                echo "  +======================================================+"
                read -p "  Alege 1-6 [implicit: 1]: " _ch
                case "${_ch:-1}" in
                    2) HW_HDR_MODE="sw_full"     ;;
                    3) HW_HDR_MODE="sw_degraded" ;;
                    4) HW_HDR_MODE="hw_hdr10"    ;;
                    5) HW_HDR_MODE="hw_sdr"      ;;
                    6) return 98 ;;
                    *) HW_HDR_MODE="hw_preserve_hdr10plus" ;;
                esac
            else
                echo "  |  1) SW - pastreaza HDR10+ complet (recomandat)"
                echo "  |  2) SW - encode ca HDR10 static (drop dynamic)"
                echo "  |  3) $bl - HDR10 10-bit (drop dynamic)"
                echo "  |  4) $bl - SDR tonemap 8-bit"
                echo "  |  5) Skip fisier"
                echo "  +======================================================+"
                read -p "  Alege 1-5 [implicit: 1]: " _ch
                case "${_ch:-1}" in
                    2) HW_HDR_MODE="sw_degraded" ;;
                    3) HW_HDR_MODE="hw_hdr10"    ;;
                    4) HW_HDR_MODE="hw_sdr"      ;;
                    5) return 98 ;;
                    *) HW_HDR_MODE="sw_full"     ;;
                esac
            fi ;;
        hlg)
            echo "  |  ! Sursa este HLG (BT.2100 HLG)"
            echo "  |  $bl suporta signaling HLG nativ. Optiuni:"
            echo "  +------------------------------------------------------+"
            echo "  |  1) $bl - HLG nativ 10-bit (recomandat)"
            echo "  |  2) SW - HLG nativ 10-bit"
            echo "  |  3) $bl - HLG -> HDR10 (PQ)"
            echo "  |  4) $bl - HLG -> SDR tonemap 8-bit"
            echo "  |  5) Skip fisier"
            echo "  +======================================================+"
            read -p "  Alege 1-5 [implicit: 1]: " _ch
            case "${_ch:-1}" in
                2) HW_HDR_MODE="sw_full"  ;;
                3) HW_HDR_MODE="hw_hdr10" ;;
                4) HW_HDR_MODE="hw_sdr"   ;;
                5) return 98 ;;
                *) HW_HDR_MODE="hw_hlg"   ;;
            esac ;;
        hdr10|*)
            echo "  |  ! Sursa este HDR10"
            echo "  |  $bl suporta HDR10 nativ. Optiuni:"
            echo "  +------------------------------------------------------+"
            echo "  |  1) $bl - HDR10 10-bit nativ (recomandat)"
            echo "  |  2) SW - HDR10 nativ"
            echo "  |  3) $bl - SDR tonemap 8-bit"
            echo "  |  4) Skip fisier"
            echo "  +======================================================+"
            read -p "  Alege 1-4 [implicit: 1]: " _ch
            case "${_ch:-1}" in
                2) HW_HDR_MODE="sw_full"  ;;
                3) HW_HDR_MODE="hw_sdr"   ;;
                4) return 98 ;;
                *) HW_HDR_MODE="hw_hdr10" ;;
            esac ;;
    esac
    log "  Ales: $HW_HDR_MODE pe backend $bl"
    return 0
}

# ── Helper: sursa este HDR/LOG (orice fel) ───────────────────────────
# Returns 0 daca sursa necesita tratament HDR (HDR10/HDR10+/DV/HLG/LOG)
hw_source_needs_hdr_handling() {
    [[ -n "${DOVI:-}" ]] && return 0
    [[ "${HDR_PLUS:-}" == *"HDR10+"* ]] && return 0
    [[ "${HDR_TYPE:-}" == *"smpte2084"* ]] && return 0
    [[ "${IS_HLG:-0}" == "1" ]] && return 0
    [[ -n "${LOG_PROFILE:-}" ]] && return 0
    return 1
}

# ── Dispatch HW unificat (Chunk 4 + Chunk 5) ─────────────────────────
# Pentru SDR: build HW direct.
# Pentru HDR/LOG: cheama show_hdr_hw_dialog si dispatch pe HW_HDR_MODE.
# Args: $1 = file ; $2 = enc_codec (h264|hevc|av1|prores)
# Returns: 0 = HW dispatched ; 1 = continua cu SW path ; 98 = user skip
hw_dispatch_sdr() {
    local file="$1" enc_codec="$2"
    case "${HW_BACKEND:-sw}" in
        nvenc|vaapi|qsv|videotoolbox|amf) ;;
        *) return 1 ;;
    esac

    if hw_source_needs_hdr_handling; then
        # LOG sources nu sunt suportate pe HW (necesita LUT/tonemap dialog SW)
        if [[ -n "${LOG_PROFILE:-}" ]]; then
            log "  Sursa LOG ($LOG_PROFILE) — backend $HW_BACKEND nu suporta LUT/tonemap; fallback SW"
            return 1
        fi

        local src_type="" dv_p=""
        if [[ -n "${DOVI:-}" ]]; then src_type="dv"; dv_p="$DOVI"
        elif [[ "${HDR_PLUS:-}" == *"HDR10+"* ]]; then src_type="hdr10plus"
        elif [[ "${IS_HLG:-0}" == "1" ]]; then src_type="hlg"
        elif [[ "${HDR_TYPE:-}" == *"smpte2084"* ]]; then src_type="hdr10"
        fi

        # v46: detecteaza source codec pentru gate hw_preserve (DV preserve via HW)
        local src_codec=""
        src_codec=$(detect_source_codec "$file" 2>/dev/null)
        [[ -z "$src_codec" ]] && src_codec="hevc"

        show_hdr_hw_dialog "$HW_BACKEND" "$src_type" "$dv_p" "$enc_codec" "$src_codec"
        local dlg_rc=$?
        [ $dlg_rc -eq 98 ] && return 98

        case "$HW_HDR_MODE" in
            sw_full)
                return 1
                ;;
            sw_degraded)
                # Strip enhancement: HDR10+ → HDR10 static, DV → HDR10 BL
                HDR_PLUS=""
                if [[ -n "${DOVI:-}" ]]; then DOVI=""; HDR_TYPE="smpte2084"; fi
                return 1
                ;;
            hw_preserve)
                # v46: HW backend produce HDR10 base layer; post-encode injecteaza RPU
                local rpu_tmp
                rpu_tmp=$(av_mktemp_ext "rpu.bin")
                if _extract_preserve_rpu "$file" "$rpu_tmp" "$src_codec"; then
                    DOVI_RPU_FILE="$rpu_tmp"
                    TRIPLE_LAYER_MODE=1
                    TRIPLE_LAYER_TARGET_CODEC="$enc_codec"
                    log "  v46 HW DV preserve: RPU extras ($src_codec) -> inject post-encode ($enc_codec via $HW_BACKEND)"
                    # v76 F3: hibrid DV+HDR10+ — sursa DV cu HDR10+ co-existent (P8.1 hybrid /
                    # AV1 DV+HDR10+). DV are prioritate la detectie (src_type=dv), dar HW dropeaza
                    # SI dinamicul HDR10+ → extragem SI JSON-ul ca sa-l re-injectam in lantul DV
                    # (HDR10+ INAINTE de DV RPU, re-mux cu dvcC = pasul final). Gateat pe tool.
                    if [[ "${HDR_PLUS:-}" == *"HDR10+"* ]] && _check_hdr10plus_tool_for "$enc_codec"; then
                        local hp_json_hyb
                        # v77: avertismentul VFR a fost emis deja de _extract_preserve_rpu (DV) mai sus
                        # — pe hibrid DV+HDR10+ amandoua straturile se aliniaza pe pozitie identic.
                        if hp_json_hyb=$(extract_hdr10plus_metadata "$file") && [ -s "$hp_json_hyb" ]; then
                            HDR10PLUS_JSON="$hp_json_hyb"
                            HW_HDR10PLUS_INJECT=1
                            HW_HDR10PLUS_CODEC="$enc_codec"
                            log "  v76 HW hibrid DV+HDR10+ preserve: JSON HDR10+ extras -> inject inaintea DV RPU"
                        else
                            [[ -n "${hp_json_hyb:-}" ]] && rm -f "$hp_json_hyb"
                            log "  v76 HW hibrid: extract JSON HDR10+ esuat -> doar DV preserve"
                        fi
                    fi
                    # Build HW cmd ca HDR10 base layer
                    HW_HDR_MODE="hw_hdr10"
                    # MediaCodec necesita SEI repair inainte de inject
                    [[ "$HW_BACKEND" == "mediacodec" ]] && MC_NEEDS_REPAIR=1 && MC_REPAIR_SRC="$file"
                else
                    log "  v46 HW DV preserve: extract RPU esuat -> fallback HDR10"
                    rm -f "$rpu_tmp"
                    HW_HDR_MODE="hw_hdr10"
                fi
                if [[ "${DRY_RUN:-0}" == "1" ]]; then
                    local _dvlbl="DV preserve"
                    [[ "${HW_HDR10PLUS_INJECT:-0}" == "1" ]] && _dvlbl="DV+HDR10+ preserve"
                    dry_run_report "$file" "$output" "${enc_codec}_${HW_BACKEND} ($_dvlbl)" \
                        "$WIDTH" "$DURATION" "$src_type"
                    return 0
                fi
                hw_build_cmd "$file" "$enc_codec"
                return 0
                ;;
            hw_preserve_hdr10plus)
                # v76: HW backend produce HDR10 base layer; post-encode injecteaza HDR10+
                # dinamic (oglinda hw_preserve DV). HW dropeaza SMPTE2094-40 → re-injectam
                # JSON-ul extras din sursa in bitstream-ul HDR10 produs (PoC QSV).
                local hp_json
                _is_vfr_source "$file" && log "  ⚠ Sursa e VFR (r_frame_rate != avg_frame_rate) — HDR10+ se aliniaza pe pozitie la cadrele de output; tool-ul poate raporta o mica diferenta de cadre la coada, ajustata automat (fara impact vizibil)."
                if hp_json=$(extract_hdr10plus_metadata "$file") && [ -s "$hp_json" ]; then
                    HDR10PLUS_JSON="$hp_json"
                    HW_HDR10PLUS_INJECT=1
                    HW_HDR10PLUS_CODEC="$enc_codec"
                    log "  v76 HW HDR10+ preserve: JSON extras ($src_codec) -> inject post-encode ($enc_codec via $HW_BACKEND)"
                else
                    log "  v76 HW HDR10+ preserve: extract JSON esuat -> fallback HDR10 static"
                    HW_HDR10PLUS_INJECT=0
                    [[ -n "${hp_json:-}" ]] && rm -f "$hp_json"
                fi
                # Build HW cmd ca HDR10 base layer (acelasi setup ca hw_hdr10)
                HW_HDR_MODE="hw_hdr10"
                if [[ "${DRY_RUN:-0}" == "1" ]]; then
                    dry_run_report "$file" "$output" "${enc_codec}_${HW_BACKEND} (HDR10+ preserve)" \
                        "$WIDTH" "$DURATION" "$src_type"
                    return 0
                fi
                hw_build_cmd "$file" "$enc_codec"
                return 0
                ;;
            hw_hdr10|hw_hlg|hw_sdr)
                if [[ "${DRY_RUN:-0}" == "1" ]]; then
                    dry_run_report "$file" "$output" "${enc_codec}_${HW_BACKEND} ($HW_HDR_MODE)" \
                        "$WIDTH" "$DURATION" "$src_type"
                    return 0
                fi
                hw_build_cmd "$file" "$enc_codec"
                return 0
                ;;
            *)
                log "  Mod HDR necunoscut: $HW_HDR_MODE — fallback SW"
                return 1
                ;;
        esac
    fi

    # SDR path
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        dry_run_report "$file" "$output" "${enc_codec}_${HW_BACKEND} (slot ${HW_PRESET_SLOT:-4})" \
            "$WIDTH" "$DURATION" "SDR"
        return 0
    fi
    HW_HDR_MODE=""
    hw_build_cmd "$file" "$enc_codec"
}

# ── Dispatcher unificat ──────────────────────────────────────────────
# Construieste FFMPEG_CMD pe baza HW_BACKEND ales.
# Args: $1 = file ; $2 = enc_codec (h264|hevc|av1|prores)
# Returns: 0 dispatched HW build ; 1 backend SW (encoder script construieste cmd direct)
hw_build_cmd() {
    local file="$1" enc_codec="$2"
    case "${HW_BACKEND:-sw}" in
        nvenc)        build_nvenc_cmd        "$file" "$enc_codec" ;;
        vaapi)        build_vaapi_cmd        "$file" "$enc_codec" ;;
        qsv)          build_qsv_cmd          "$file" "$enc_codec" ;;
        videotoolbox) build_videotoolbox_cmd "$file" "$enc_codec" ;;
        amf)          build_amf_cmd          "$file" "$enc_codec" ;;
        mediacodec)   build_mediacodec_cmd   "$file" "$enc_codec" ;;
        sw|"")        return 1 ;;
        *)            return 1 ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════
# DRY-RUN REPORT
# ══════════════════════════════════════════════════════════════════════
dry_run_report() {
    local file="$1" output="$2" enc_label="$3" width="$4" dur="$5" src_fmt="$6"
    local orig_mb=$(( $(av_stat_size "$file") / 1024 / 1024 ))
    echo ""; echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║  DRY-RUN — $(basename "$file")"
    echo "  ╠══════════════════════════════════════════════════════╣"
    printf "  ║  Sursa    : %-42s║\n" "$src_fmt | ${width}px | ${orig_mb} MB"
    printf "  ║  Output   : %-42s║\n" "$(basename "$output")"
    printf "  ║  Encoder  : %-42s║\n" "$enc_label"
    if [[ "${ENCODE_MODE:-1}" == "3" ]]; then printf "  ║  Mode     : %-42s║\n" "VBR 2-pass ${VBR_TARGET:-}"
    elif [[ "${ENCODE_MODE:-1}" == "2" ]]; then printf "  ║  Mode     : %-42s║\n" "VBR 1-pass ${VBR_TARGET:-}"
    else printf "  ║  Mode     : %-42s║\n" "CRF ${CUSTOM_CRF:-auto}"; fi
    if [[ -n "${SCALE_WIDTH:-}" ]]; then printf "  ║  Resize   : %-42s║\n" "${width}px → ${SCALE_WIDTH}px"
    else printf "  ║  Resize   : %-42s║\n" "fara (original)"; fi
    if [[ -n "${TARGET_FPS:-}" ]]; then printf "  ║  FPS      : %-42s║\n" "→ ${TARGET_FPS} (${FPS_METHOD:-drop})"
    else printf "  ║  FPS      : %-42s║\n" "original"; fi
    printf "  ║  Filtru   : %-42s║\n" "${VIDEO_FILTER_PRESET:-fara}"
    printf "  ║  Audio    : %-42s║\n" "$AUDIO_CODEC_ARG"
    [[ "${AUDIO_NORMALIZE:-0}" == "1" ]] && printf "  ║  Loudnorm : %-42s║\n" "EBU R128 (-24 LUFS)"
    if [[ "$dur" =~ ^[0-9]+$ ]] && [ "$dur" -gt 0 ]; then
        local eb=4000000; [[ "$width" =~ ^[0-9]+$ ]] && [ "$width" -ge 3840 ] && eb=10000000
        [[ "$width" =~ ^[0-9]+$ ]] && [ "$width" -lt 1920 ] && eb=2000000
        printf "  ║  Estimare : %-42s║\n" "~$(( eb * dur / 8 / 1024 / 1024 )) MB | ~$((dur / 3 / 60))m"
        printf "  ║  Durata   : %-42s║\n" "$((dur/3600))h $((dur%3600/60))m $((dur%60))s"
    fi
    echo "  ╚══════════════════════════════════════════════════════╝"
}

# ══════════════════════════════════════════════════════════════════════
# BATCH SUMMARY DETALIAT
# ══════════════════════════════════════════════════════════════════════
print_batch_summary() {
    [ ${#BATCH_NAMES[@]} -le 1 ] && return
    log ""; log "── REZUMAT BATCH DETALIAT ──────────────────────────"
    local fi_idx=0 si_idx=0 td=0
    for i in "${!BATCH_NAMES[@]}"; do
        local t=${BATCH_TIMES[$i]}
        log "  ${BATCH_NAMES[$i]}: $((${BATCH_ORIG[$i]}/1024/1024))MB → $((${BATCH_NEW[$i]}/1024/1024))MB (${BATCH_RATIOS[$i]}%) | $((t/60))m $((t%60))s"
        [ "$t" -lt "${BATCH_TIMES[$fi_idx]}" ] && fi_idx=$i
        [ "$t" -gt "${BATCH_TIMES[$si_idx]}" ] && si_idx=$i
        local sd; sd=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 \
            "$INPUT_DIR/${BATCH_NAMES[$i]}" 2>/dev/null); sd=${sd%.*}
        [[ "$sd" =~ ^[0-9]+$ ]] && td=$((td+sd))
    done
    log "  ──────────────────────────────────────────────────"
    log "  Cel mai rapid : ${BATCH_NAMES[$fi_idx]} ($((${BATCH_TIMES[$fi_idx]}/60))m)"
    log "  Cel mai lent  : ${BATCH_NAMES[$si_idx]} ($((${BATCH_TIMES[$si_idx]}/60))m)"
    log "  Material total: $((td/3600))h $((td%3600/60))m procesat"
    # Afiseaza structura de foldere daca a fost pastrata
    if [[ "${PRESERVE_FOLDER_STRUCTURE:-0}" == "1" ]]; then
        log "  ──────────────────────────────────────────────────"
        log "  Structura foldere: PASTRATA"
        local output_dirs
        output_dirs=$(find "$OUTPUT_DIR" -type d 2>/dev/null | sort)
        local dir_count
        dir_count=$(echo "$output_dirs" | wc -l)
        log "  Foldere output create: $dir_count"
    fi
}

# ══════════════════════════════════════════════════════════════════════
# INTERACTIVE MODE — dialog dupa fiecare fisier encodat
# Permite schimbarea setarilor pentru fisierul urmator.
# ══════════════════════════════════════════════════════════════════════
_interactive_settings_dialog() {
    echo ""
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║  MOD INTERACTIV — Fisier urmator             ║"
    echo "  ╠══════════════════════════════════════════════╣"
    echo "  ║  Setari curente:                             ║"
    printf "  ║  Audio     : %-33s║\n" "$AUDIO_CODEC_ARG"
    printf "  ║  Container : %-33s║\n" "$CONTAINER"
    if [[ -n "${CUSTOM_CRF:-}" ]]; then
        printf "  ║  CRF       : %-33s║\n" "$CUSTOM_CRF"
    fi
    printf "  ║  Filtru    : %-33s║\n" "${VIDEO_FILTER_PRESET:-fara}"
    printf "  ║  Normalizare: %-32s║\n" "$([ "${AUDIO_NORMALIZE:-0}" == "1" ] && echo "EBU R128" || echo "dezactivata")"
    echo "  ╠══════════════════════════════════════════════╣"
    echo "  ║  1) Pastreaza setarile (continua) [implicit] ║"
    echo "  ║  2) Modifica setarile pentru urmatorul fisier ║"
    echo "  ║  3) Opreste batch-ul aici                    ║"
    echo "  ╚══════════════════════════════════════════════╝"
    read -p "  Alege 1-3 [implicit: 1]: " int_choice
    case "${int_choice:-1}" in
        2)
            echo ""
            # ── Audio ──────────────────────────────────────────────
            echo "  Audio curent: $AUDIO_CODEC_ARG"
            echo "  Schimbi? (Enter = pastreaza, sau introdu nou: aac:192k / opus:128k / eac3:224k / ac3:224k / flac:8 / pcm:16le / copy)"
            read -p "  Audio nou: " new_audio
            [[ -n "$new_audio" ]] && { AUDIO_CODEC_ARG="$new_audio"; echo "  → Audio: $AUDIO_CODEC_ARG"; }

            # ── CRF (doar pentru encodere CRF) ─────────────────────
            if [[ "${ENCODER_TYPE:-}" != "dnxhr" ]] && [[ "${ENCODER_TYPE:-}" != "apv" ]] && [[ "${ENCODER_TYPE:-}" != "prores" ]]; then
                echo "  CRF curent: ${CUSTOM_CRF:-auto}"
                echo "  Schimbi? (Enter = pastreaza, sau introdu valoare)"
                read -p "  CRF nou: " new_crf
                if [[ -n "$new_crf" ]] && [[ "$new_crf" =~ ^[0-9]+$ ]]; then
                    CUSTOM_CRF="$new_crf"; echo "  → CRF: $CUSTOM_CRF"
                fi
            fi

            # ── Filtru video ───────────────────────────────────────
            echo "  Filtru curent: ${VIDEO_FILTER_PRESET:-fara}"
            echo "  Schimbi? (Enter = pastreaza, sau: denoise_light / denoise_medium / sharpen_light / deinterlace / fara)"
            read -p "  Filtru nou: " new_vf
            if [[ -n "$new_vf" ]]; then
                [[ "$new_vf" == "fara" ]] && VIDEO_FILTER_PRESET="" || VIDEO_FILTER_PRESET="$new_vf"
                echo "  → Filtru: ${VIDEO_FILTER_PRESET:-fara}"
            fi

            # ── Normalizare audio ──────────────────────────────────
            echo "  Normalizare: $([ "${AUDIO_NORMALIZE:-0}" == "1" ] && echo "activa" || echo "dezactivata")"
            echo "  Schimbi? (1=activa, 0=dezactiva, Enter=pastreaza)"
            read -p "  Normalizare: " new_norm
            [[ "$new_norm" == "1" ]] && { AUDIO_NORMALIZE="1"; echo "  → Normalizare: activa"; }
            [[ "$new_norm" == "0" ]] && { AUDIO_NORMALIZE="0"; echo "  → Normalizare: dezactivata"; }

            log "  [INTERACTIV] Setari modificate pentru fisierul urmator"
            ;;
        3)
            log "  [INTERACTIV] Batch oprit de utilizator dupa $TOTAL_DONE fisiere"
            BATCH_STOP=1
            ;;
        *) ;; # pastreaza tot
    esac
}

# ══════════════════════════════════════════════════════════════════════
# RUN_ENCODE_LOOP — BUCLA PRINCIPALA DE ENCODE
# ══════════════════════════════════════════════════════════════════════
# ── Batch Queue — editare ordine si excludere fisiere ────────────────
# Primeste: FILES (array global)
# Modifica: FILES (array global filtrat/reordonat)
show_batch_queue() {
    local total=${#FILES[@]}
    [ "$total" -eq 0 ] && return
    echo ""
    read -p "Editezi batch queue (ordine/excludere)? 1-Nu [impl]  2-Da: " bq_choice
    [[ "${bq_choice:-1}" != "2" ]] && return

    # included[i]=1 (inclus) sau 0 (exclus)
    local -a included=()
    for ((i=0; i<total; i++)); do included[$i]=1; done

    while true; do
        clear
        echo "╔══════════════════════════════════════════════════╗"
        echo "║  BATCH QUEUE — $total fisiere                      ║"
        echo "╠══════════════════════════════════════════════════╣"
        local incl_count=0
        for ((i=0; i<total; i++)); do
            local fn
            fn=$(basename "${FILES[$i]}")
            local sz_mb=$(( $(av_stat_size "${FILES[$i]}" 2>/dev/null || echo 0) / 1024 / 1024 ))
            if [[ "${included[$i]}" -eq 1 ]]; then
                printf "  %2d) [✓] %-32s (%d MB)\n" $((i+1)) "$fn" "$sz_mb"
                incl_count=$((incl_count+1))
            else
                printf "  %2d) [✗] %-32s (%d MB)\n" $((i+1)) "$fn" "$sz_mb"
            fi
        done
        echo "╠══════════════════════════════════════════════════╣"
        echo "  X<nr>     — exclude/include (ex: X3)"
        echo "  F<nr>     — muta pe prima pozitie (ex: F5)"
        echo "  M<de>,<la> — muta (ex: M3,1)"
        echo "  D<nr>     — doar acest fisier"
        echo "  Enter     — lanseaza ($incl_count fisiere)"
        echo "╚══════════════════════════════════════════════════╝"
        read -p "Comanda: " bq_cmd
        [[ -z "$bq_cmd" ]] && break
        bq_cmd="${bq_cmd^^}"  # uppercase

        if [[ "$bq_cmd" =~ ^X([0-9]+)$ ]]; then
            local xi=$(( ${BASH_REMATCH[1]} - 1 ))
            if [[ $xi -ge 0 && $xi -lt $total ]]; then
                included[$xi]=$(( 1 - included[$xi] ))
            fi
        elif [[ "$bq_cmd" =~ ^F([0-9]+)$ ]]; then
            local fi_idx=$(( ${BASH_REMATCH[1]} - 1 ))
            if [[ $fi_idx -gt 0 && $fi_idx -lt $total ]]; then
                local tmp_file="${FILES[$fi_idx]}"
                local tmp_incl="${included[$fi_idx]}"
                local -a new_files=("$tmp_file")
                local -a new_incl=("$tmp_incl")
                for ((j=0; j<total; j++)); do
                    [[ $j -eq $fi_idx ]] && continue
                    new_files+=("${FILES[$j]}")
                    new_incl+=("${included[$j]}")
                done
                FILES=("${new_files[@]}")
                included=("${new_incl[@]}")
            fi
        elif [[ "$bq_cmd" =~ ^M([0-9]+),([0-9]+)$ ]]; then
            local from_idx=$(( ${BASH_REMATCH[1]} - 1 ))
            local to_idx=$(( ${BASH_REMATCH[2]} - 1 ))
            if [[ $from_idx -ge 0 && $from_idx -lt $total && $to_idx -ge 0 && $to_idx -lt $total && $from_idx -ne $to_idx ]]; then
                local mv_file="${FILES[$from_idx]}"
                local mv_incl="${included[$from_idx]}"
                local -a tmp_f=() tmp_i=()
                for ((j=0; j<total; j++)); do
                    [[ $j -eq $from_idx ]] && continue
                    tmp_f+=("${FILES[$j]}"); tmp_i+=("${included[$j]}")
                done
                FILES=(); included=()
                for ((j=0; j<${#tmp_f[@]}; j++)); do
                    if [[ $j -eq $to_idx ]]; then
                        FILES+=("$mv_file"); included+=("$mv_incl")
                    fi
                    FILES+=("${tmp_f[$j]}"); included+=("${tmp_i[$j]}")
                done
                if [[ $to_idx -ge ${#tmp_f[@]} ]]; then
                    FILES+=("$mv_file"); included+=("$mv_incl")
                fi
                total=${#FILES[@]}
            fi
        elif [[ "$bq_cmd" =~ ^D([0-9]+)$ ]]; then
            local di=$(( ${BASH_REMATCH[1]} - 1 ))
            if [[ $di -ge 0 && $di -lt $total ]]; then
                for ((j=0; j<total; j++)); do
                    [[ $j -eq $di ]] && included[$j]=1 || included[$j]=0
                done
            fi
        fi
    done

    # Filter: keep only included files
    local -a filtered=()
    for ((i=0; i<total; i++)); do
        [[ "${included[$i]}" -eq 1 ]] && filtered+=("${FILES[$i]}")
    done
    FILES=("${filtered[@]}")
    echo "  Batch queue: ${#FILES[@]} fisiere selectate."
}

run_encode_loop() {
    echo "Activez wake lock..."; av_wake_lock
    [ $? -ne 0 ] && echo "AVERTISMENT: av_wake_lock a esuat."
    CONTAINER_FLAGS=$(get_container_flags)
    local enc_suffix enc_label
    enc_suffix=$(encoder_get_suffix); enc_label=$(encoder_get_label)
    # v57: codec FourCC tag pentru MP4/MOV/M4V — un singur loc de injectie
    # acopera SW (libx265/libx264/libsvtav1/libaom) + HW (NVENC/QSV/AMF/VAAPI/VT/MC).
    # ProRes/DNxHR/APV: containere native (.mov/.mxf), ffmpeg default deja corect.
    local _codec_key=""
    case "$enc_suffix" in
        _x265) _codec_key="hevc" ;;
        _x264) _codec_key="h264" ;;
        _av1)  _codec_key="av1"  ;;
    esac
    CODEC_TAG=$(codec_tag_for_container "$_codec_key" "$CONTAINER")

    echo "=======================================" | tee "$LOG_FILE"
    log "Encode inceput : $(date '+%Y-%m-%d %H:%M:%S')"
    log "Encoder        : $enc_label"
    log "Container      : $CONTAINER"
    log "CPU threads    : $THREADS"
    encoder_log_header
    log "Resize         : ${SCALE_WIDTH:-originala}"
    log "FPS            : ${TARGET_FPS:-original} ${FPS_METHOD:+($FPS_METHOD)}"
    log "Filtru video   : ${VIDEO_FILTER_PRESET:-fara}"
    log "Audio          : ${AUDIO_CODEC_ARG}"
    log "Normalizare    : ${AUDIO_NORMALIZE:-0}"
    log "======================================="

    # ── Pastrare structura foldere ────────────────────────────────────
    echo ""
    echo "Pastrezi structura de foldere din input? (d/n) [implicit: n]"
    echo "  d = Scanare recursiva, output pastreaza structura subfoldere"
    echo "  n = Toate fisierele in acelasi folder output"
    read -p "Alege: " folder_struct_choice
    PRESERVE_FOLDER_STRUCTURE=0
    if [[ "${folder_struct_choice,,}" == "d" ]]; then
        PRESERVE_FOLDER_STRUCTURE=1
        log "Structura foldere: PASTRATA (recursiv)"
        echo "  Scanez recursiv..."
        # Scanare recursiva cu find
        mapfile -t FILES < <(find "$INPUT_DIR" -type f \( \
            -iname "*.mp4" -o -iname "*.mov" -o -iname "*.mkv" -o \
            -iname "*.m2ts" -o -iname "*.mts" -o -iname "*.vob" -o \
            -iname "*.mxf" -o -iname "*.apv" -o -iname "*.webm" \) 2>/dev/null | sort)
    else
        log "Structura foldere: FLAT (toate in output/)"
        shopt -s nullglob nocaseglob
        FILES=("$INPUT_DIR"/*.{mp4,mov,mkv,m2ts,mts,vob,mxf,apv,webm})
        shopt -u nocaseglob nullglob
    fi
    TOTAL=${#FILES[@]}
    [ "$TOTAL" -eq 0 ] && { log "Nu am gasit fisiere video!"; av_wake_unlock; exit 1; }

    # Afiseaza subfoldere gasite (doar daca recursiv)
    if [[ "$PRESERVE_FOLDER_STRUCTURE" == "1" ]]; then
        local subfolder_count
        subfolder_count=$(printf '%s\n' "${FILES[@]}" | xargs -I{} dirname {} | sort -u | wc -l)
        echo "  Gasite: $TOTAL fisiere in $subfolder_count foldere"
    fi

    # Batch Queue — editare ordine/excludere (optional)
    show_batch_queue
    TOTAL=${#FILES[@]}
    [ "$TOTAL" -eq 0 ] && { log "Toate fisierele au fost excluse!"; av_wake_unlock; exit 1; }

    COUNT=0; TOTAL_SAVED=0; TOTAL_ERRORS=0; TOTAL_SKIPPED=0; TOTAL_DONE=0
    GRAND_START=$(date +%s); PROGRESS_FILE=""; BATCH_STOP=0
    TRIPLE_LAYER_MODE=0; DOVI_RPU_FILE=""; TRIPLE_LAYER_TARGET_CODEC=""
    # v63: baza HDR10_MEASURE_CLL (env/profil) — promptul per-fisier o suprascrie doar local;
    # reset-ul per-iteratie revine la baza (env/profil persista, alegerea per-fisier NU leak-uie).
    HDR10_MEASURE_CLL_BASE="${HDR10_MEASURE_CLL:-0}"
    ORIG_CONTAINER="$CONTAINER"; ORIG_CONTAINER_FLAGS="$CONTAINER_FLAGS"
    BATCH_NAMES=(); BATCH_TIMES=(); BATCH_ORIG=(); BATCH_NEW=(); BATCH_RATIOS=()

    for file in "${FILES[@]}"; do
        [ -f "$file" ] || continue
        [ "$BATCH_STOP" -eq 1 ] && { TOTAL_SKIPPED=$((TOTAL_SKIPPED+1)); continue; }
        CONTAINER="$ORIG_CONTAINER"; CONTAINER_FLAGS="$ORIG_CONTAINER_FLAGS"
        COUNT=$((COUNT + 1))
        filename=$(basename "$file"); name="${filename%.*}"
        ext_lower="${filename##*.}"; ext_lower="${ext_lower,,}"

        # Calculeaza output path (cu sau fara structura foldere)
        if [[ "$PRESERVE_FOLDER_STRUCTURE" == "1" ]]; then
            # Calculeaza calea relativa fata de INPUT_DIR
            local file_dir rel_path output_subdir
            file_dir=$(dirname "$file")
            rel_path="${file_dir#$INPUT_DIR}"
            rel_path="${rel_path#/}"  # Elimina slash initial daca exista
            if [[ -n "$rel_path" ]]; then
                output_subdir="$OUTPUT_DIR/$rel_path"
                mkdir -p "$output_subdir" 2>/dev/null
                output="$output_subdir/${name}${enc_suffix}.$CONTAINER"
            else
                output="$OUTPUT_DIR/${name}${enc_suffix}.$CONTAINER"
            fi
        else
            output="$OUTPUT_DIR/${name}${enc_suffix}.$CONTAINER"
        fi

        log ""; log "── Fisier $COUNT/$TOTAL: $filename"
        log "  Output: ${output#$OUTPUT_DIR/}"
        hint_source_format "$ext_lower"

        if [ -f "$output" ]; then
            OUT_SIZE=$(av_stat_size "$output")
            if [ "$OUT_SIZE" -gt 1048576 ]; then
                log "  Sarit (deja encodat, $(( OUT_SIZE/1024/1024 )) MB)"
                TOTAL_SKIPPED=$((TOTAL_SKIPPED+1)); continue
            else log "  Output incomplet — sterg si reincep"; rm -f "$output"; fi
        fi
        if batch_is_done "$filename"; then
            log "  Sarit (resume)"; TOTAL_SKIPPED=$((TOTAL_SKIPPED+1)); continue
        fi

        ORIGINAL_SIZE=$(av_stat_size "$file")
        # v38: reset MediaCodec per-file flags pentru a evita leak intre iteratii
        MC_NEEDS_REPAIR=0
        MC_HDR_MODE=""
        MC_REPAIR_SRC=""
        # v45: defensive reset DV/HDR10+ state — daca encoder_setup_file a
        # esuat / setup_rc=98 in iteratia anterioara fara cleanup, evitam leak
        # v46: include si HW_HDR_MODE pentru hw_preserve cleanup
        # v51: include 2-pass state (stats file + cmd strings + flag)
        [[ -n "${HDR10PLUS_JSON:-}" ]] && rm -f "$HDR10PLUS_JSON"
        [[ -n "${DOVI_RPU_FILE:-}" ]] && rm -f "$DOVI_RPU_FILE"
        HDR10PLUS_JSON=""; DOVI_RPU_FILE=""
        TRIPLE_LAYER_MODE=0; TRIPLE_LAYER_TARGET_CODEC=""
        # v69: APV HDR10+ state (setat de av_encoder_apv encoder_setup_file)
        [[ -n "${APV_HDR10PLUS_JSON:-}" ]] && rm -f "$APV_HDR10PLUS_JSON"
        APV_HDR10PLUS_JSON=""; APV_HDR10PLUS_INJECT=0
        # v76: HW HDR10+ preserve state (setat de hw_dispatch_sdr/hw_preserve_hdr10plus)
        HW_HDR10PLUS_INJECT=0; HW_HDR10PLUS_CODEC=""
        HW_HDR_MODE=""
        HLG_DIALOG_MODE=""
        HDR10_MEASURE_CLL="${HDR10_MEASURE_CLL_BASE:-0}"   # v63: revine la baza env/profil per fisier
        # v62 audit: reset LOG color state — altfel un fisier LOG (x264 + LUT) lasa
        # LOG_COLOR_FLAGS / LOG_EXTRA_X264 setate, iar fisierul NE-LOG urmator (x264 le
        # consuma neconditionat in video_params) era marcat gresit bt709/bt2020. x265/av1
        # gateaza pe ramura LOG → nu sufera; x264 le pune in builder-ul general.
        LOG_VIDEO_FILTER=""; LOG_COLOR_FLAGS=""; LOG_PIX_FMT=""
        LOG_EXTRA_X265=""; LOG_EXTRA_X264=""
        # v67: state selectie audio per-pista (handle_multi_audio_dialog le seteaza oricum
        # per fisier, dar resetam defensiv per regula — previne leak intre iteratii)
        AUDIO_LOUDNORM_TRACK=0; AUDIO_PERTRACK_CUSTOM=0
        AUDIO_REENCODED_INPUTS="0"; AUDIO_SKIPPED_INPUTS=""   # v68
        cleanup_2pass_state
        handle_dji_full "$file" "$enc_suffix"
        detect_source_info "$file"
        CRF=$(get_adaptive_crf "${ENCODER_TYPE:-x265}" "$WIDTH")
        AUDIO_PARAMS=$(get_audio_params "$file")
        # v67: selectie audio per-pista (>1 pista) — poate rescrie AUDIO_PARAMS + adauga
        # negative maps in MAP_FLAGS (skip) + seteaza AUDIO_LOUDNORM_TRACK. Default = neschimbat.
        handle_multi_audio_dialog "$file"
        # v68: avertisment compat container pe pistele COPIATE (codec incompatibil → ar esua)
        warn_incompat_audio_copies "$file"
        SUB_CODEC=$(get_subtitle_codec "$file")
        VIDEO_FILTER=$(build_video_filters "$WIDTH" "$SRC_FPS_DEC")
        [[ "$VIDEO_FILTER" == *"scale="* ]] && log "  Resize: ${WIDTH}px → ${SCALE_WIDTH}px"
        [[ "$VIDEO_FILTER" == *"-r "* ]] || [[ "$VIDEO_FILTER" == *"minterpolate"* ]] && \
            log "  FPS: ${SRC_FPS_DEC} → ${TARGET_FPS} ($FPS_METHOD)"

        # Encoder-specific: seteaza FFMPEG_CMD, face DV dialog, dry-run
        encoder_setup_file "$file"
        local setup_rc=$?
        if [ $setup_rc -eq 98 ]; then TOTAL_SKIPPED=$((TOTAL_SKIPPED+1)); continue
        elif [ $setup_rc -ne 0 ]; then TOTAL_ERRORS=$((TOTAL_ERRORS+1)); continue; fi

        if [[ "${DRY_RUN:-0}" == "1" ]]; then TOTAL_DONE=$((TOTAL_DONE+1)); continue; fi

        # v38: Smart stream copy detection — daca source codec == target codec
        # și nu sunt transformări planificate (filter, normalize, HDR, LOG, DV),
        # propune stream copy total. Salvează ore de encode + zero pierdere calitate.
        local _src_codec; _src_codec=$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=codec_name -of default=nw=1:nk=1 "$file" 2>/dev/null)
        local _tgt_codec=""
        case "${ENCODER_NAME:-}" in
            libx265) _tgt_codec="hevc" ;;
            libx264) _tgt_codec="h264" ;;
            av1)     _tgt_codec="av1" ;;
        esac
        if [[ -n "$_tgt_codec" && "$_src_codec" == "$_tgt_codec" ]] \
           && [[ -z "$VIDEO_FILTER" ]] \
           && [[ "${AUDIO_NORMALIZE:-0}" != "1" ]] \
           && [[ "${IS_LOG:-0}" != "1" ]] \
           && [[ -z "${HDR_PLUS:-}" ]] && [[ -z "${DOVI:-}" ]] \
           && [[ "${TRIPLE_LAYER_MODE:-0}" != "1" ]] \
           && [[ "${ENCODE_MODE:-1}" != "3" ]]; then
            # Bonus: bitrate sanity info
            local _src_br _br_str=""
            _src_br=$(ffprobe -v error -select_streams v:0 \
                -show_entries stream=bit_rate -of default=nw=1:nk=1 "$file" 2>/dev/null)
            [[ "$_src_br" =~ ^[0-9]+$ ]] && _br_str=" (bitrate sursa ~$((_src_br/1000)) kbps)"
            log ""
            log "  ⚡ SMART COPY: video e deja $_src_codec, identic cu target ($ENCODER_NAME)$_br_str."
            log "    Re-encode video redundant (pierde calitate). Audio-ul urmeaza alegerea ta (nu se pierde)."
            read -p "  Copiaza video 1:1 + aplica audio ales, fara re-encode video? (D/n) [default: D]: " _smart_ch
            if [[ "${_smart_ch,,}" != "n" ]]; then
                log "  → Video copy + audio aplicat (fara re-encode video)"
                # v68: paseaza AUDIO_PARAMS (per-pista, daca exista) + MAP_FLAGS (cu skip maps)
                # → onoreaza selectia per-pista la smart-copy (paritate cu PS1). Garda
                # AUDIO_PERTRACK_CUSTOM scoasa: do_stream_copy foloseste acum audio-ul corect.
                do_stream_copy "$file" "$output" "$MAP_FLAGS" "$AUDIO_PARAMS"
                local _sc_rc=$?
                if [ $_sc_rc -ne 0 ]; then
                    TOTAL_ERRORS=$((TOTAL_ERRORS+1))
                    rm -f "$output"
                fi
                [[ -n "${HDR10PLUS_JSON:-}" ]] && rm -f "$HDR10PLUS_JSON"; HDR10PLUS_JSON=""
                [[ -n "${DOVI_RPU_FILE:-}" ]] && rm -f "$DOVI_RPU_FILE"; DOVI_RPU_FILE=""
                TRIPLE_LAYER_MODE=0; TRIPLE_LAYER_TARGET_CODEC=""
                continue
            fi
        fi

        LOUDNORM_FILTER=""
        [[ "$AUDIO_NORMALIZE" == "1" ]] && [[ "$AUDIO_CODEC_ARG" != "copy" ]] && \
            LOUDNORM_FILTER=$(get_loudnorm_filter "$file")
        TRF_FILE=""; _apply_vidstab "$file"

        PROGRESS_FILE=$(mktemp); START_TIME=$(date +%s)
        # v38: stderr capture într-un fișier separat (în paralel cu LOG_FILE)
        local _enc_err; _enc_err=$(mktemp)
        # v38: label dinamic — uppercase ENCODER_NAME (ex: X265, AV1, DNXHR, APV).
        # v65: ENCODER_NAME nu e exportat la procesul encoder → fallback pe ENCODER_TYPE
        # (setat in fiecare encoder: x265/x264/av1/dnxhr/prores/apv); inainte cadea pe "FFMPEG".
        local _enc_label; _enc_label="${ENCODER_NAME:-${ENCODER_TYPE:-FFmpeg}}"; _enc_label="${_enc_label^^}"

        if [[ "${USE_2PASS:-0}" == "1" ]]; then
            # v51: 2-pass branch — encoderul a populat FFMPEG_CMD_PASS1/PASS2 + STATS_FILE
            run_2pass_encode "$file" "$_enc_label"
            FFMPEG_EXIT=$?
            # Cleanup stats file dupa pass 2 (success sau fail)
            cleanup_2pass_state
        else
            # shellcheck disable=SC2086
            eval $FFMPEG_CMD $LOUDNORM_FILTER $SUB_CODEC -c:t copy \
                $CODEC_TAG $CONTAINER_FLAGS -progress '"$PROGRESS_FILE"' -nostats '"$output"' '2>"$_enc_err"' '&'
            FFMPEG_PID=$!; _show_progress "$FFMPEG_PID" "$PROGRESS_FILE" "$file" "$_enc_label"
            wait "$FFMPEG_PID"; FFMPEG_EXIT=$?
        fi
        # Append stderr la LOG_FILE pentru istoric complet
        [[ -s "$_enc_err" ]] && cat "$_enc_err" >> "$LOG_FILE"
        [[ -n "${TRF_FILE:-}" ]] && rm -f "$TRF_FILE"; TRF_FILE=""
        if [ $FFMPEG_EXIT -ne 0 ]; then
            log "  EROARE encodare (cod $FFMPEG_EXIT)"
            # v38: arata ultimele linii stderr inline pentru diagnoza rapida
            if [[ -s "$_enc_err" ]]; then
                echo "  ⚠ ffmpeg exit $FFMPEG_EXIT — ultimele linii stderr:"
                tail -10 "$_enc_err" | sed 's/^/    /'
            fi
            rm -f "$_enc_err"
            [[ -n "${HDR10PLUS_JSON:-}" ]] && rm -f "$HDR10PLUS_JSON"; HDR10PLUS_JSON=""
            [[ -n "${DOVI_RPU_FILE:-}" ]] && rm -f "$DOVI_RPU_FILE"; DOVI_RPU_FILE=""
            TRIPLE_LAYER_MODE=0; TRIPLE_LAYER_TARGET_CODEC=""
            [[ -n "${APV_HDR10PLUS_JSON:-}" ]] && rm -f "$APV_HDR10PLUS_JSON"; APV_HDR10PLUS_JSON=""; APV_HDR10PLUS_INJECT=0
            TOTAL_ERRORS=$((TOTAL_ERRORS+1)); rm -f "$output"; continue
        fi
        rm -f "$_enc_err"

        # ── v38: MediaCodec HDR10 signaling repair ────────────────────
        if [[ "${MC_NEEDS_REPAIR:-0}" == "1" ]] && [[ "${USE_MEDIACODEC:-0}" == "1" ]]; then
            MC_REPAIR_SRC="$file" repair_hdr10_signaling "$output"
            MC_NEEDS_REPAIR=0
        fi

        # ── Triple-layer: injecteaza DV RPU in output (HEVC sau AV1) ──
        if [[ "${TRIPLE_LAYER_MODE:-0}" == "1" ]] && [[ -n "${DOVI_RPU_FILE:-}" ]]; then
            local _tl_codec="${TRIPLE_LAYER_TARGET_CODEC:-hevc}"
            local _tl_label
            case "$_tl_codec" in
                av1) _tl_label="DV P10 + HDR10 + HDR10+ (AV1)" ;;
                *)   _tl_label="DV 8.1 + HDR10 + HDR10+ (HEVC)" ;;
            esac
            log "  Triple-layer: Injectez DV RPU in output ($_tl_codec)..."
            local raw_temp injected_temp _ext _extract_args
            case "$_tl_codec" in
                av1)
                    _ext="ivf"
                    _extract_args="-c:v copy -f ivf"
                    ;;
                *)
                    _ext="hevc"
                    _extract_args="-c:v copy -bsf:v hevc_mp4toannexb -f hevc"
                    ;;
            esac
            raw_temp=$(av_mktemp_ext "$_ext")
            # shellcheck disable=SC2086
            ffmpeg -v error -y -i "$output" $_extract_args "$raw_temp" 2>>"$LOG_FILE"
            if [ $? -eq 0 ]; then
                # v76 F3: hibrid DV+HDR10+ — injecteaza HDR10+ in raw INAINTE de DV RPU, in
                # ACELASI lant (re-mux cu dvcC ramane pasul final → DV activabil pe TV). Pe AV1
                # repair-urile T.35 sunt mod-specifice (inject_hdr10plus→0x003C, inject_dv_rpu→0x003B
                # sare 0x003C) → ambele OBU-uri raman corecte (av1dovi_tool paseaza HDR10+ verbatim,
                # ca in hibridul SW v72). _dv_src = sursa pt inject_dv_rpu (raw direct, sau cel cu HDR10+).
                local _dv_src="$raw_temp" _hyb_hp=""
                if [[ "${HW_HDR10PLUS_INJECT:-0}" == "1" ]] && [[ -n "${HDR10PLUS_JSON:-}" ]]; then
                    _hyb_hp=$(av_mktemp_ext "$_ext")
                    if inject_hdr10plus_metadata "$raw_temp" "$HDR10PLUS_JSON" "$_hyb_hp" "$_tl_codec"; then
                        _dv_src="$_hyb_hp"
                        log "  Triple-layer: HDR10+ injectat in lant (hibrid) inaintea DV RPU"
                    else
                        rm -f "$_hyb_hp"; _hyb_hp=""
                        log "  Triple-layer: inject HDR10+ esuat — continui doar cu DV"
                    fi
                fi
                injected_temp=$(av_mktemp_ext "$_ext")
                if inject_dv_rpu "$_dv_src" "$DOVI_RPU_FILE" "$injected_temp" "$_tl_codec"; then
                    # Re-mux: video cu DV + audio/sub/attachments originale din output
                    local final_temp
                    final_temp=$(av_mktemp_ext "$CONTAINER")
                    local cont_flags
                    cont_flags=$(get_container_flags)
                    # v69 audit FIX: HEVC annexb brut nu are PTS pe B-frames →
                    # muxerul matroska refuza (output gol). Tinta mkv pe HEVC →
                    # pas intermediar MP4, apoi MP4→MKV. AV1/IVF neafectat.
                    if [[ "$CONTAINER" == "mkv" ]] && _mux_dv_mkv "$injected_temp" "$output" "$final_temp"; then
                        # v70 (HEVC) / v71 (AV1): mkvmerge scrie dvcC de container din RPU-ul
                        # brut (HEVC .hevc SAU AV1 .ivf) → DV activabil si pe TV. mkvmerge
                        # accepta IVF; AV1+MP4 acoperit in v72 via MP4Box dvp= (ramura mp4 de mai jos).
                        log "  Triple-layer: dvcC de container scris via $AV_TOOL_MKVMERGE (DV activabil pe TV)"
                        true  # garanteaza $?=0 pt verificarea [-s final_temp] de mai jos (log/tee ar putea returna non-zero)
                    elif [[ "$_tl_codec" != "av1" && "$CONTAINER" == "mkv" ]]; then
                        # HEVC → MKV fara mkvmerge → pas intermediar MP4 (raw HEVC nu poarta timing)
                        local _tl_step1 _tl_rc=1
                        _tl_step1=$(av_mktemp_ext mp4)
                        if ffmpeg -v error -y -i "$injected_temp" -i "$output" \
                              -map 0:v:0 -map 1:a? -map 1:s? -map 1:t? \
                              -c copy "$_tl_step1" 2>>"$LOG_FILE" && [ -s "$_tl_step1" ]; then
                            ffmpeg -v error -y -i "$_tl_step1" -c copy "$final_temp" 2>>"$LOG_FILE"
                            _tl_rc=$?
                        fi
                        rm -f "$_tl_step1"
                        [ "$_tl_rc" -ne 0 ] && rm -f "$final_temp"
                        test "$_tl_rc" -eq 0
                    elif [[ ( "$CONTAINER" == "mp4" || "$CONTAINER" == "mov" || "$CONTAINER" == "m4v" ) ]] \
                         && _mux_dv_mp4 "$injected_temp" "$output" "$final_temp" "$file"; then
                        # v71 HEVC / v72 AV1: DV → MP4/MOV → MP4Box scrie dvcC de container (DV pe TV).
                        # AV1 cere dvp= explicit → derivat din $file (sursa DV daca are dvcC), fallback 10.1.
                        log "  Triple-layer: dvcC de container scris via $AV_TOOL_MP4BOX (DV activabil pe TV)"
                        true  # garanteaza $?=0 pt verificarea [-s final_temp] de mai jos
                    else
                        # AV1+MKV fara mkvmerge (IVF poarta timing) / MP4Box lipsa → ffmpeg direct
                        ffmpeg -v error -y -i "$injected_temp" -i "$output" \
                            -map 0:v:0 -map 1:a? -map 1:s? -map 1:t? \
                            -c copy $cont_flags "$final_temp" 2>>"$LOG_FILE"
                    fi
                    if [ $? -eq 0 ] && [ -s "$final_temp" ]; then
                        mv -f "$final_temp" "$output"
                        # v56: guard onest AV1 — inject-rpu produce metadata T.35 pe care ffmpeg
                        # o arunca silentios la pachetizare (rc=0, output ne-gol) si DV se pierde.
                        if [[ "$_tl_codec" == "av1" ]] && ! verify_dv_survived "$output" "$_tl_codec"; then
                            log "  Triple-layer: ⚠ DV pierdut la re-mux (known issue AV1 inject-rpu T.35 — Tier 4); output pastreaza HDR10/HDR10+"
                        else
                            log "  Triple-layer: $_tl_label — OK"
                        fi
                    else
                        log "  Triple-layer: Re-mux esuat — output fara DV (HDR10+ pastrat)"
                        rm -f "$final_temp"
                    fi
                else
                    log "  Triple-layer: Injectare RPU esuata — output fara DV (HDR10+ pastrat)"
                fi
                rm -f "$injected_temp"
            else
                log "  Triple-layer: Extractie raw $_tl_codec esuata — output fara DV (HDR10+ pastrat)"
            fi
            rm -f "$raw_temp"
            [[ -n "$_hyb_hp" ]] && rm -f "$_hyb_hp"
        fi

        # ── v76: HW HDR10+ preserve — injecteaza dinamicul in baza HDR10 produsa de HW ──
        # (post-encode, ca triple-layer; state setat de hw_dispatch_sdr/hw_preserve_hdr10plus).
        # HW dropeaza SMPTE2094-40 → re-injectam JSON-ul extras din sursa. HDR10+ e SEI/OBU
        # inline (NU cere dvcC de container ca DV). Garda raw→MKV (clasa v69): HEVC annexb
        # fara PTS → pas MP4 intermediar; AV1/IVF poarta PTS → ffmpeg direct.
        # v76 F3: in hibrid DV+HDR10+ (TRIPLE_LAYER_MODE=1) HDR10+ a fost DEJA injectat in lantul
        # DV de mai sus (cu dvcC final) → NU rula a doua oara aici (ar pierde dvcC la re-mux plain).
        if [[ "${HW_HDR10PLUS_INJECT:-0}" == "1" ]] && [[ -n "${HDR10PLUS_JSON:-}" ]] \
           && [[ "${TRIPLE_LAYER_MODE:-0}" != "1" ]]; then
            local _hp_codec="${HW_HDR10PLUS_CODEC:-hevc}" _hp_ext _hp_xargs
            case "$_hp_codec" in
                av1) _hp_ext="ivf";  _hp_xargs="-c:v copy -f ivf" ;;
                *)   _hp_ext="hevc"; _hp_xargs="-c:v copy -bsf:v hevc_mp4toannexb -f hevc" ;;
            esac
            log "  HW HDR10+: re-injectez metadata dinamica in baza HDR10 ($_hp_codec)..."
            local _hp_raw _hp_inj _hp_final
            _hp_raw=$(av_mktemp_ext "$_hp_ext")
            # shellcheck disable=SC2086
            ffmpeg -v error -y -i "$output" $_hp_xargs "$_hp_raw" 2>>"$LOG_FILE"
            if [ $? -eq 0 ] && [ -s "$_hp_raw" ]; then
                _hp_inj=$(av_mktemp_ext "$_hp_ext")
                if inject_hdr10plus_metadata "$_hp_raw" "$HDR10PLUS_JSON" "$_hp_inj" "$_hp_codec"; then
                    _hp_final=$(av_mktemp_ext "$CONTAINER")
                    local _hp_cont_flags
                    _hp_cont_flags=$(get_container_flags)
                    if [[ "$_hp_codec" != "av1" && "$CONTAINER" == "mkv" ]]; then
                        # HEVC annexb brut nu are PTS → MKV refuza → pas intermediar MP4
                        local _hp_step _hp_rc=1
                        _hp_step=$(av_mktemp_ext mp4)
                        if ffmpeg -v error -y -i "$_hp_inj" -i "$output" \
                              -map 0:v:0 -map 1:a? -map 1:s? -map 1:t? \
                              -c copy "$_hp_step" 2>>"$LOG_FILE" && [ -s "$_hp_step" ]; then
                            ffmpeg -v error -y -i "$_hp_step" -c copy "$_hp_final" 2>>"$LOG_FILE" && _hp_rc=0
                        fi
                        rm -f "$_hp_step"
                        [ "$_hp_rc" -ne 0 ] && rm -f "$_hp_final"
                        test "$_hp_rc" -eq 0
                    else
                        # shellcheck disable=SC2086
                        ffmpeg -v error -y -i "$_hp_inj" -i "$output" \
                            -map 0:v:0 -map 1:a? -map 1:s? -map 1:t? \
                            -c copy $_hp_cont_flags "$_hp_final" 2>>"$LOG_FILE"
                    fi
                    if [ $? -eq 0 ] && [ -s "$_hp_final" ]; then
                        mv -f "$_hp_final" "$output"
                        log "  HW HDR10+: dinamicul restaurat in output ($_hp_codec via ${HW_BACKEND:-hw})"
                    else
                        log "  HW HDR10+: re-mux esuat — output ramane HDR10 static"
                        rm -f "$_hp_final"
                    fi
                else
                    log "  HW HDR10+: inject esuat — output ramane HDR10 static"
                fi
                rm -f "$_hp_inj"
            else
                log "  HW HDR10+: extractie raw esuata — output ramane HDR10 static"
            fi
            rm -f "$_hp_raw"
        fi

        [[ -n "${HDR10PLUS_JSON:-}" ]] && rm -f "$HDR10PLUS_JSON"; HDR10PLUS_JSON=""
        [[ -n "${DOVI_RPU_FILE:-}" ]] && rm -f "$DOVI_RPU_FILE"; DOVI_RPU_FILE=""
        TRIPLE_LAYER_MODE=0; TRIPLE_LAYER_TARGET_CODEC=""
        HW_HDR10PLUS_INJECT=0; HW_HDR10PLUS_CODEC=""

        # ── v69: APV HDR10+ — injecteaza T.35 + MDCV/CLL in bitstream-ul APV ──
        # (post-encode, ca triple-layer; state setat de av_encoder_apv)
        if [[ "${APV_HDR10PLUS_INJECT:-0}" == "1" ]] && [[ -n "${APV_HDR10PLUS_JSON:-}" ]]; then
            _apv_hdr10plus_inject_output "$output" "$APV_HDR10PLUS_JSON" "$file"
        fi
        [[ -n "${APV_HDR10PLUS_JSON:-}" ]] && rm -f "$APV_HDR10PLUS_JSON"; APV_HDR10PLUS_JSON=""
        APV_HDR10PLUS_INJECT=0

        # ── v78: re-grefeaza GPS-ul nativ DJI (djmd) pe output MP4/MOV ──
        # (ULTIMUL post-process: dupa toate inject-urile de metadata; gate intern pe djmd)
        _dji_preserve_meta_postencode "$file" "$output"

        NEW_SIZE=$(av_stat_size "$output" 2>/dev/null || echo 0)
        SAVED=$(( ORIGINAL_SIZE - NEW_SIZE )); [ $SAVED -lt 0 ] && SAVED=0
        TOTAL_SAVED=$(( TOTAL_SAVED+SAVED ))
        ENCODE_TIME=$(( $(date +%s) - START_TIME )); TOTAL_DONE=$((TOTAL_DONE+1))
        BATCH_NAMES+=("$filename"); BATCH_TIMES+=("$ENCODE_TIME")
        BATCH_ORIG+=("$ORIGINAL_SIZE"); BATCH_NEW+=("$NEW_SIZE")
        [ "$ORIGINAL_SIZE" -gt 0 ] && BATCH_RATIOS+=("$(awk "BEGIN{printf \"%.1f\", $NEW_SIZE * 100.0 / $ORIGINAL_SIZE}")") || BATCH_RATIOS+=("N/A")
        log "  Original: $(( ORIGINAL_SIZE/1024/1024 )) MB | Nou: $(( NEW_SIZE/1024/1024 )) MB | Salvat: $(( SAVED/1024/1024 )) MB"
        log "  Timp: $((ENCODE_TIME/60))m $((ENCODE_TIME%60))s"
        batch_mark_done "$filename"; log "────────────────────────────────────────"

        # ── MOD INTERACTIV: dialog dupa fiecare fisier ────────────────
        if [[ "${INTERACTIVE_MODE:-0}" == "1" ]] && [ "$COUNT" -lt "$TOTAL" ]; then
            _interactive_settings_dialog
        fi
    done

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo ""; log "======================================="
        log "DRY-RUN COMPLET — $enc_label [$ORIG_CONTAINER]"
        log "Fisiere analizate: $TOTAL_DONE | Sarite: $TOTAL_SKIPPED"
        log "======================================="; av_wake_unlock; exit 0
    fi
    batch_clear_progress
    GRAND_ELAPSED=$(( $(date +%s) - GRAND_START )); echo ""
    log "======================================="
    log "STATISTICI FINALE — $enc_label [$ORIG_CONTAINER]"
    log "Procesate  : $TOTAL_DONE | Sarite: $TOTAL_SKIPPED | Erori: $TOTAL_ERRORS"
    log "Spatiu salvat: $(( TOTAL_SAVED/1024/1024 )) MB"
    log "Timp total : $((GRAND_ELAPSED/3600))h $((GRAND_ELAPSED%3600/60))m $((GRAND_ELAPSED%60))s"
    log "Incheiat   : $(date '+%Y-%m-%d %H:%M:%S')"
    print_batch_summary
    log "======================================="
    av_notify_done "✅ Encode $enc_label finalizat" \
        "Procesate: $TOTAL_DONE | Erori: $TOTAL_ERRORS | Salvat: $(( TOTAL_SAVED/1024/1024 )) MB"
    echo "Dezactivez wake lock..."; av_wake_unlock
}


# ══════════════════════════════════════════════════════════════════════
# v43 — Profile schema + validation
# ══════════════════════════════════════════════════════════════════════
# profile_schema_get KEY -> echo "TYPE|CONSTRAINT" or empty if unknown
#   TYPE: enum / int / intrange / string / path / regex
#   CONSTRAINT depends on TYPE:
#     enum:val1,val2,val3
#     intrange:min,max
#     regex:pattern
#     int:    (no constraint)
#     string: (no constraint, accepts anything)
#     path:   (validated only when LUT_PATH — file existence checked separately)
profile_schema_get() {
    case "$1" in
        ENCODER_NAME)         echo "enum:libx265,libx264,av1,dnxhr,prores,apv,hwenc" ;;
        AV1_ENCODER_NAME)     echo "enum:,libsvtav1,libaom-av1" ;;
        DNXHR_PROFILE)        echo "enum:,lb,sq,hq,hqx,444" ;;
        APV_PIXFMT)           echo "enum:,422_10,422_12,444_10,444_12,4444_10,4444_12" ;;
        APV_PRESET)           echo "enum:,fastest,fast,medium,slow,placebo" ;;
        APV_QP)               echo "intrange:0,63" ;;
        APV_EXTRA)            echo "string" ;;
        PRORES_PROFILE)       echo "enum:,proxy,lt,standard,hq,4444,xq,4444xq" ;;
        X264_PROFILE)         echo "enum:,auto,high,high10,high422" ;;
        CONTAINER)            echo "enum:mkv,mp4,mov,mxf,webm" ;;
        HW_ENC_CODEC)         echo "enum:,hevc_nvenc,h264_nvenc,av1_nvenc,hevc_qsv,h264_qsv,av1_qsv,hevc_amf,h264_amf,av1_amf" ;;
        HW_BACKEND)           echo "enum:,sw,nvenc,vaapi,qsv,videotoolbox,amf,mediacodec" ;;
        HW_PRESET_SLOT)       echo "enum:,1,2,3,4,5,6,7" ;;
        HW_HDR_POLICY)        echo "enum:,sw_full,sw_degraded,hw_hdr10,hw_hlg,hw_sdr,hw_repair,hw_preserve,skip" ;;
        MEDIACODEC_HDR_POLICY) echo "enum:,sw_full,sw_degraded,hw_repair,hw_hlg,hw_sdr,hw_preserve,skip" ;;
        DOVI_PRESERVE_POLICY) echo "enum:,auto,preserve,convert,copy,skip" ;;
        DJI_PRESERVE_META)    echo "enum:,auto,on,off" ;;
        HW_FORCE)             echo "enum:0,1" ;;
        AUDIO_NORMALIZE)      echo "enum:0,1" ;;
        ENCODE_MODE)          echo "enum:1,2,3" ;;
        FORCE_LOG_DETECTION)  echo "enum:0,1" ;;
        HDR10_MEASURE_CLL)    echo "enum:0,1" ;;
        INTERACTIVE_MODE)     echo "enum:0,1" ;;
        LOG_PROFILE)          echo "enum:,apple_log,samsung_log,dlog_m" ;;
        FPS_METHOD)           echo "enum:,drop,minterpolate" ;;
        VIDEO_FILTER_PRESET)  echo "regex:^(denoise_light|denoise_medium|denoise_strong|sharpen_light|sharpen_medium|deinterlace|upscale_4k|vidstab|custom:.*)?$" ;;
        AUDIO_CODEC_ARG)      echo "regex:^(copy|aac:[0-9]+k|opus:[0-9]+k|flac:[0-9]+|eac3:[0-9]+k|ac3:[0-9]+k|pcm:[0-9]+(le|be))?$" ;;
        SCALE_WIDTH)          echo "regex:^([0-9]{2,5})?$" ;;
        TARGET_FPS)           echo "regex:^([0-9]+(\.[0-9]+)?|[0-9]+/[0-9]+)?$" ;;
        CRF_PARAM)            echo "regex:^([0-9]+)?$" ;;
        PRESET_PARAM)         echo "regex:^(ultrafast|superfast|veryfast|faster|fast|medium|slow|slower|veryslow|[1-9])?$" ;;
        TUNE_PARAM)           echo "regex:^(animation|grain|film|stillimage|fastdecode|[0-9]{1,2})?$" ;;
        VBR_PARAM|VBR_MAXRATE|VBR_BUFSIZE) echo "regex:^([0-9]+[kMmKgG]?)?$" ;;
        HW_ENC_QP)            echo "regex:^([0-9]+)?$" ;;
        HW_ENC_PRESET)        echo "string:" ;;
        EXTRA_PARAM)          echo "string:" ;;
        LUT_PATH)             echo "path:" ;;
        EXTENDS)              echo "path:" ;;
        *)                    echo "" ;;
    esac
}

# validate_profile <file>
# Echoes errors to stderr (one per line, prefixed "  ✗ ...").
# Returns 0 on success, 1 on any error.
validate_profile() {
    local pf="$1"
    [[ ! -f "$pf" ]] && { echo "  ✗ Profil inexistent: $pf" >&2; return 1; }

    local errors=0
    local lineno=0
    local key value schema stype sconstraint
    local IFS_BAK="$IFS"

    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno+1))
        # Skip comments + empty
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        # Match KEY=VALUE or KEY="VALUE"
        if [[ "$line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)[[:space:]]*=[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            schema=$(profile_schema_get "$key")
            if [[ -z "$schema" ]]; then
                # Unknown key: warning, not error (forward-compat)
                echo "  ! [linia $lineno] cheie necunoscuta: $key (ignor)" >&2
                continue
            fi
            stype="${schema%%:*}"
            sconstraint="${schema#*:}"
            case "$stype" in
                enum)
                    # sconstraint = comma-separated; empty values allowed if "" in list
                    local IFS=','
                    local allowed=($sconstraint)
                    IFS="$IFS_BAK"
                    local ok=0
                    local a
                    for a in "${allowed[@]}"; do
                        [[ "$value" == "$a" ]] && { ok=1; break; }
                    done
                    if [[ $ok -eq 0 ]]; then
                        echo "  ✗ [linia $lineno] $key=\"$value\" — valori permise: $sconstraint" >&2
                        errors=$((errors+1))
                    fi
                    ;;
                regex)
                    if ! [[ "$value" =~ $sconstraint ]]; then
                        echo "  ✗ [linia $lineno] $key=\"$value\" — nu corespunde pattern: $sconstraint" >&2
                        errors=$((errors+1))
                    fi
                    ;;
                int)
                    if [[ -n "$value" ]] && ! [[ "$value" =~ ^[0-9]+$ ]]; then
                        echo "  ✗ [linia $lineno] $key=\"$value\" — astept intreg" >&2
                        errors=$((errors+1))
                    fi
                    ;;
                intrange)
                    local rmin rmax
                    rmin="${sconstraint%,*}"; rmax="${sconstraint#*,}"
                    if [[ -n "$value" ]]; then
                        if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -lt "$rmin" ]] || [[ "$value" -gt "$rmax" ]]; then
                            echo "  ✗ [linia $lineno] $key=\"$value\" — astept $rmin..$rmax" >&2
                            errors=$((errors+1))
                        fi
                    fi
                    ;;
                path|string)
                    : # no validation here; LUT/EXTENDS path resolution e externa
                    ;;
            esac
        fi
    done < "$pf"

    [[ $errors -gt 0 ]] && return 1
    return 0
}

# ──────────────────────────────────────────────────────────────────────
# v43 — EXTENDS chain helpers (single-parent inheritance)
# ──────────────────────────────────────────────────────────────────────
# _resolve_extends_path <name_or_path> <child_dir>
# Resolves a parent reference to an absolute .conf path.
# Search order: absolute → sibling dir → UserProfiles → builtin profiles/*.
# Accepts name with or without ".conf" suffix.
# Echoes resolved path on success; empty + return 1 on miss.
_resolve_extends_path() {
    local ref="$1" child_dir="$2"
    [[ -z "$ref" ]] && return 1
    local base="${ref%.conf}"
    local cand

    # Absolute path (POSIX or Windows-style)
    if [[ "$ref" == /* ]] || [[ "$ref" =~ ^[A-Za-z]:[\\/] ]]; then
        for cand in "$ref" "$ref.conf"; do
            [[ -f "$cand" ]] && { echo "$cand"; return 0; }
        done
        return 1
    fi

    # 1) Sibling (same directory as child)
    if [[ -n "$child_dir" && -f "$child_dir/$base.conf" ]]; then
        echo "$child_dir/$base.conf"; return 0
    fi
    # 2) User profiles
    if [[ -n "${USER_PROFILES_DIR:-}" && -f "$USER_PROFILES_DIR/$base.conf" ]]; then
        echo "$USER_PROFILES_DIR/$base.conf"; return 0
    fi
    # 3) Builtin (root + 1-level subdirs)
    if [[ -n "${PROFILES_DIR:-}" ]]; then
        [[ -f "$PROFILES_DIR/$base.conf" ]] && { echo "$PROFILES_DIR/$base.conf"; return 0; }
        shopt -s nullglob
        for cand in "$PROFILES_DIR"/*/"$base.conf"; do
            [[ -f "$cand" ]] && { shopt -u nullglob; echo "$cand"; return 0; }
        done
        shopt -u nullglob
    fi
    return 1
}

# _get_extends_field <file>
# Greps the EXTENDS=... line without sourcing. Echoes value (may be empty).
_get_extends_field() {
    local pf="$1" line
    [[ ! -f "$pf" ]] && return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ^[[:space:]]*EXTENDS[[:space:]]*=[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$ ]]; then
            echo "${BASH_REMATCH[1]}"
            return 0
        fi
    done < "$pf"
    return 0
}

# _canon_path <path>
# Returns canonical absolute path (resolves .. and symlinks). On
# case-insensitive filesystems (macOS APFS default, Windows MSYS) we
# additionally lowercase the result so that duplicate refs differing only
# in case are caught by cycle detection. On Linux paths stay case-sensitive.
_canon_path() {
    local p="$1" abs
    [[ -z "$p" ]] && { echo ""; return 0; }
    abs=$(av_readlink_f "$p" 2>/dev/null)
    [[ -z "$abs" ]] && abs="$p"
    case "$AV_PLATFORM" in
        macos) printf '%s' "$abs" | tr '[:upper:]' '[:lower:]' ;;
        *)
            # MSYS/Git Bash on Windows reports linux-y but FS is case-insensitive.
            if [[ -n "${OS:-}" && "$OS" == "Windows_NT" ]]; then
                printf '%s' "$abs" | tr '[:upper:]' '[:lower:]'
            else
                printf '%s' "$abs"
            fi
            ;;
    esac
}

# build_extends_chain <leaf_file>
# Echoes the resolved chain root-first, leaf-last (one absolute path per line).
# Cycle detection via visited list of canonicalized paths; depth limit 5.
# Returns 1 on missing leaf, cycle, missing parent, or depth overflow.
build_extends_chain() {
    local leaf="$1"
    if [[ -z "$leaf" || ! -f "$leaf" ]]; then
        echo "  ✗ EXTENDS: profil leaf inexistent: ${leaf:-<empty>}" >&2
        return 1
    fi
    local -a chain=() visited=()
    local current="$leaf" current_canon parent_ref parent_path child_dir v
    local depth=0 MAX_DEPTH=5

    while [[ -n "$current" ]]; do
        if [[ $depth -ge $MAX_DEPTH ]]; then
            echo "  ✗ EXTENDS: depasire adancime maxima ($MAX_DEPTH) — verifica $current" >&2
            return 1
        fi
        current_canon=$(_canon_path "$current")
        for v in "${visited[@]}"; do
            if [[ "$v" == "$current_canon" ]]; then
                echo "  ✗ EXTENDS: ciclu detectat la $current" >&2
                return 1
            fi
        done
        visited+=("$current_canon")
        chain=("$current" "${chain[@]}")  # prepend → root ends up first

        parent_ref=$(_get_extends_field "$current")
        [[ -z "$parent_ref" ]] && break

        child_dir=$(dirname "$current")
        parent_path=$(_resolve_extends_path "$parent_ref" "$child_dir")
        if [[ -z "$parent_path" ]]; then
            echo "  ✗ EXTENDS: parinte negasit '$parent_ref' (referit din $(basename "$current"))" >&2
            return 1
        fi
        current="$parent_path"
        depth=$((depth+1))
    done

    printf '%s\n' "${chain[@]}"
    return 0
}

# load_profile_validated <file>
# Resolves EXTENDS chain, validates each link, sources root→leaf (leaf wins).
# Returns 0 on success, 1 on abort.
load_profile_validated() {
    local pf="$1"
    local chain_str
    chain_str=$(build_extends_chain "$pf") || return 1
    local -a chain
    mapfile -t chain <<< "$chain_str"
    [[ ${#chain[@]} -eq 0 ]] && chain=("$pf")

    local errors=0 link
    for link in "${chain[@]}"; do
        validate_profile "$link" || errors=$((errors+1))
    done
    if [[ $errors -gt 0 ]]; then
        echo ""
        # Non-interactive guard: fail-fast in scripts/CI; only prompt when stdin is a tty.
        if [[ "${AV_NONINTERACTIVE:-0}" == "1" ]] || [[ ! -t 0 ]]; then
            echo "  ✗ Erori in profil/parinti — abort (mod non-interactiv)." >&2
            return 1
        fi
        local _cont
        read -p "  Profilul (sau parintii) au erori. Continui oricum? (d/N): " _cont
        [[ "${_cont,,}" != "d" ]] && return 1
    fi

    if [[ ${#chain[@]} -gt 1 ]]; then
        echo "  Lant EXTENDS (root → leaf):"
        local i=1
        for link in "${chain[@]}"; do
            echo "    $i) $(basename "$link" .conf)"
            i=$((i+1))
        done
    fi

    for link in "${chain[@]}"; do
        # shellcheck disable=SC1090
        source "$link"
    done
    return 0
}
