#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# mp4box_installer.sh — Installer pentru MP4Box (GPAC)
#
# MP4Box scrie semnalizarea dvcC de container ("DOVI configuration record")
# pe hibridele HEVC Dolby Vision produse de suita, cand tinta e MP4/MOV →
# Dolby Vision devine activabil si pe TV-uri (ffmpeg NU poate scrie dvcC din
# RPU-ul brut; calea de azi lasa DV doar in bitstream, dormant pe TV). v71.
# Echivalentul pentru MP4/MOV al mkvmerge (care acopera MKV, v70).
#
# OPTIONAL: suita functioneaza complet fara el — cand MP4Box lipseste, muxul
# MP4/MOV al hibridelor cade tacut pe ffmpeg direct (DV in bitstream, fara
# dvcC). GPAC e in toate package manager-ele majore → fara compilare.
#   Termux: pkg · Debian/Ubuntu: apt · Fedora: dnf · Arch: pacman · macOS: brew
# Numele binarului e overridable prin env AV_TOOL_MP4BOX.
# ══════════════════════════════════════════════════════════════════════

BIN="${AV_TOOL_MP4BOX:-mp4box}"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   MP4BOX (GPAC) INSTALLER — dvcC pe MP4 v71  ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# MP4Box e instalat fie ca 'MP4Box' fie ca 'mp4box' (case-sensitive pe Linux)
if command -v "$BIN" >/dev/null 2>&1 || command -v MP4Box >/dev/null 2>&1; then
    echo "MP4Box e deja disponibil: $(command -v "$BIN" 2>/dev/null || command -v MP4Box)"
    { "$BIN" -version 2>&1 || MP4Box -version 2>&1; } | head -1
    echo "Suita il va folosi automat (AV_TOOL_MP4BOX)."
    exit 0
fi

echo "Instalez GPAC (MP4Box) prin package manager-ul platformei..."
rc=1
case "$(uname -s 2>/dev/null)" in
    Darwin)
        if command -v brew >/dev/null 2>&1; then
            brew install gpac && rc=0
        else
            echo "Homebrew lipseste. Instaleaza-l de pe https://brew.sh apoi ruleaza:"
            echo "  brew install gpac"
        fi
        ;;
    Linux)
        if [ -d "/data/data/com.termux" ] || [ -n "$TERMUX_VERSION" ]; then
            pkg install -y gpac && rc=0
        elif command -v apt >/dev/null 2>&1; then
            sudo apt update && sudo apt install -y gpac && rc=0
        elif command -v dnf >/dev/null 2>&1; then
            sudo dnf install -y gpac && rc=0
        elif command -v pacman >/dev/null 2>&1; then
            sudo pacman -S --noconfirm gpac && rc=0
        else
            echo "Package manager nerecunoscut. Instaleaza manual pachetul 'gpac'"
            echo "(contine MP4Box). Vezi https://gpac.io/downloads/"
        fi
        ;;
    *)
        echo "Platforma nesuportata de acest installer."
        echo "Pe Windows foloseste mp4box_installer.ps1."
        exit 1
        ;;
esac

echo ""
if command -v "$BIN" >/dev/null 2>&1 || command -v MP4Box >/dev/null 2>&1; then
    echo "INSTALARE REUSITA!"
    { "$BIN" -version 2>&1 || MP4Box -version 2>&1; } | head -1
    echo "Suita va scrie acum dvcC pe hibridele HEVC DV care merg in MP4/MOV."
else
    echo "EROARE: MP4Box tot nu e disponibil dupa instalare (rc=$rc)."
    echo ""
    # v96: pe unele distributii pachetul pur si simplu NU exista (constatat pe Ubuntu 26.04:
    # `apt` raspunde "Package 'gpac' has no installation candidate"). Fara MP4Box se pierd
    # dvcC pe MP4/MOV, authoring-ul IAMF, semnalizarea Atmos si graftul GPS DJI — toate
    # degradeaza gratios, deci nimic nu pare stricat, dar capabilitatile lipsesc.
    # Build-ul din sursa e calea sigura si dureaza cateva minute.
    echo "Daca distributia nu are pachetul 'gpac' (ex. Ubuntu 26.04), compileaza-l din sursa:"
    echo "  sudo apt install -y build-essential zlib1g-dev pkg-config git   # sau echivalent"
    echo "  git clone --depth 1 https://github.com/gpac/gpac.git"
    echo "  cd gpac && ./configure && make -j\$(nproc) && sudo make install"
    echo ""
    echo "IMPORTANT: NU folosi './configure --static-bin' — produce un MP4Box 'MINI build',"
    echo "fara optiunile de import de care are nevoie suita (dvcC, IAMF, semnalizare Atmos)."
    echo ""
    echo "Alternativ, pachete oficiale: https://gpac.io/downloads/"
    exit 1
fi
