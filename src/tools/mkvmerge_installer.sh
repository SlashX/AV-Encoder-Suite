#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# mkvmerge_installer.sh — Installer pentru MKVToolNix (mkvmerge + mkvextract)
#
# mkvmerge scrie semnalizarea dvcC de container ("DOVI configuration
# record" / Block Addition Mapping) pe hibridele HEVC Dolby Vision produse
# de suita → Dolby Vision devine activabil si pe TV-uri (ffmpeg NU poate
# sintetiza dvcC din RPU-ul brut; calea de azi lasa DV doar in bitstream,
# dormant pe playerele care decid dupa dvcC). v70.
# mkvextract scoate stream-ul complet BL+EL+RPU dintr-un P7 MKV (EL-ul sta
# in block additions → ffmpeg -c copy l-ar pierde) pt conversia P7 → 8.1 (v76).
#
# OPTIONAL: suita functioneaza complet fara ele — fara mkvmerge muxul MKV al
# hibridelor cade tacut pe pasul intermediar MP4 (v69); fara mkvextract se
# refuza P7 in MKV. Pachetul 'mkvtoolnix' aduce AMBELE binare dintr-o singura
# instalare. MKVToolNix e in toate package manager-ele majore → fara compilare.
#   Termux: pkg · Debian/Ubuntu: apt · Fedora: dnf · Arch: pacman · macOS: brew
# Numele binarelor sunt overridable prin env AV_TOOL_MKVMERGE / AV_TOOL_MKVEXTRACT.
# ══════════════════════════════════════════════════════════════════════

BIN="${AV_TOOL_MKVMERGE:-mkvmerge}"
BIN_EXTRACT="${AV_TOOL_MKVEXTRACT:-mkvextract}"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   MKVMERGE INSTALLER — dvcC de container v70 ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

if command -v "$BIN" >/dev/null 2>&1 && command -v "$BIN_EXTRACT" >/dev/null 2>&1; then
    echo "MKVToolNix (mkvmerge + mkvextract) e deja disponibil:"
    echo "  $(command -v "$BIN")"
    echo "  $(command -v "$BIN_EXTRACT")"
    "$BIN" --version 2>/dev/null | head -1
    echo "Suita le va folosi automat (AV_TOOL_MKVMERGE / AV_TOOL_MKVEXTRACT)."
    exit 0
fi

echo "Instalez MKVToolNix prin package manager-ul platformei..."
rc=1
case "$(uname -s 2>/dev/null)" in
    Darwin)
        if command -v brew >/dev/null 2>&1; then
            brew install mkvtoolnix && rc=0
        else
            echo "Homebrew lipseste. Instaleaza-l de pe https://brew.sh apoi ruleaza:"
            echo "  brew install mkvtoolnix"
        fi
        ;;
    Linux)
        if [ -d "/data/data/com.termux" ] || [ -n "$TERMUX_VERSION" ]; then
            pkg install -y mkvtoolnix && rc=0
        elif command -v apt >/dev/null 2>&1; then
            sudo apt update && sudo apt install -y mkvtoolnix && rc=0
        elif command -v dnf >/dev/null 2>&1; then
            sudo dnf install -y mkvtoolnix && rc=0
        elif command -v pacman >/dev/null 2>&1; then
            { sudo pacman -S --noconfirm mkvtoolnix-cli || sudo pacman -S --noconfirm mkvtoolnix; } && rc=0
        else
            echo "Package manager nerecunoscut. Instaleaza manual pachetul 'mkvtoolnix'"
            echo "(sau 'mkvtoolnix-cli' — partea de linie de comanda, contine mkvmerge)."
        fi
        ;;
    *)
        echo "Platforma nesuportata de acest installer."
        echo "Pe Windows foloseste mkvmerge_installer.ps1."
        exit 1
        ;;
esac

echo ""
if command -v "$BIN" >/dev/null 2>&1; then
    echo "INSTALARE REUSITA!"
    "$BIN" --version 2>/dev/null | head -1
    echo "Suita va scrie acum dvcC pe hibridele HEVC DV care merg in MKV."
    if command -v "$BIN_EXTRACT" >/dev/null 2>&1; then
        echo "mkvextract prezent → conversia DV Profil 7 → 8.1 e disponibila."
    else
        echo "NOTA: mkvextract NU e disponibil (neobisnuit pt pachetul 'mkvtoolnix')."
        echo "      Conversia P7 → 8.1 il cere; instaleaza pachetul complet 'mkvtoolnix'."
    fi
else
    echo "EROARE: mkvmerge tot nu e disponibil dupa instalare (rc=$rc)."
    echo "Instaleaza manual pachetul 'mkvtoolnix' (sau 'mkvtoolnix-cli')."
    exit 1
fi
