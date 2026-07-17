#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# svtav1hdr_installer.sh — Installer SvtAv1EncApp (fork-ul SVT-AV1-HDR)
#
# Fork-ul SVT-AV1-HDR (juliobbv-p) e un encoder AV1 cu suport NATIV
# --dolby-vision-rpu si --hdr10plus-json (mainline SVT-AV1 nu le are).
# Suita NU il foloseste la encodare — e resursa de TEST/validare (v92):
#   - produce stream-uri de REFERINTA cu plasarea conforma a OBU-urilor
#     de metadata (validarea reorder-ului din av1_dv_t35_repair.py);
#   - produce stream-uri svtav1-inline HDR10+ pe care ffmpeg-ul legat de
#     SVT-AV1 mainline NU le poate genera (calea SW-hybrid).
#
# DELIBERAT instalat in subfolder (tools/svtav1hdr/), NU pe PATH:
# _check_svtav1_hdr10plus_caps probeaza INTAI SvtAv1EncApp de pe PATH —
# binarul fork ar raspunde "da" pentru un libsvtav1 din ffmpeg care poate
# sa NU aiba hdr10plus-json → fals-pozitiv → encode esuat in loc de
# fallback-ul gratios HDR10 static.
#
# Release-urile oficiale au binare Linux x86-64 + macOS (x86-64/arm64) +
# Windows; pe Termux/Linux-arm nu exista build → mesaj onest.
# ══════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$SCRIPT_DIR/svtav1hdr"
EXE="$INSTALL_DIR/SvtAv1EncApp"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  SVT-AV1-HDR / SvtAv1EncApp — v92            ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

if [ -x "$EXE" ]; then
    echo "SvtAv1EncApp e deja instalat: $EXE"
    "$EXE" --version 2>&1 | head -1
    exit 0
fi

REPO="juliobbv-p/svt-av1-hdr"
ASSET=""
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
        echo "Windows: foloseste installer-ul PowerShell:"
        echo "  powershell -File tools/svtav1hdr_installer.ps1"
        exit 0
        ;;
    Darwin)
        if [ "$(uname -m)" = "arm64" ]; then
            ASSET="macOS_arm64"
        else
            ASSET="macOS_x86-64"
        fi
        ;;
    Linux)
        if [ -d "/data/data/com.termux" ] || [ -n "$TERMUX_VERSION" ]; then
            echo "Termux: SVT-AV1-HDR nu are build pentru Android/aarch64 in release-uri."
            echo "Resursa e doar de TEST — suita functioneaza complet fara ea"
            echo "(reorder-ul OBU din av1_dv_t35_repair.py nu depinde de acest binar)."
            exit 0
        fi
        if [ "$(uname -m)" = "x86_64" ]; then
            ASSET="Linux_x86-64_x86-64-v3"
        else
            echo "Linux $(uname -m): release-urile SVT-AV1-HDR au doar binare x86-64."
            echo "Alternativa: build din sursa — https://github.com/$REPO"
            exit 0
        fi
        ;;
    *)
        echo "Platforma necunoscuta — descarca manual de pe:"
        echo "  https://github.com/$REPO/releases"
        exit 0
        ;;
esac

command -v curl >/dev/null 2>&1 || { echo "[!] curl lipseste."; exit 1; }
command -v tar  >/dev/null 2>&1 || { echo "[!] tar lipseste."; exit 1; }

echo "[1/3] Caut ultimul release ($ASSET)..."
URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null | \
    grep -o "\"browser_download_url\": *\"[^\"]*${ASSET}[^\"]*\.tar\.xz\"" | \
    head -1 | sed 's/.*"\(https[^"]*\)"/\1/')
if [ -z "$URL" ]; then
    echo "[!] Nu am gasit asset-ul $ASSET in ultimul release."
    echo "    Descarca manual de pe https://github.com/$REPO/releases"
    echo "    si dezarhiveaza SvtAv1EncApp in: $INSTALL_DIR"
    exit 1
fi
echo "  $URL"

echo "[2/3] Descarc si dezarhivez..."
TMPTAR="$INSTALL_DIR/.svtav1hdr_dl.tar.xz"
mkdir -p "$INSTALL_DIR"
curl -fL -o "$TMPTAR" "$URL" || { echo "[!] Download esuat."; rm -f "$TMPTAR"; exit 1; }
tar -xJf "$TMPTAR" -C "$INSTALL_DIR" || { echo "[!] Dezarhivare esuata (xz-utils instalat?)."; rm -f "$TMPTAR"; exit 1; }
rm -f "$TMPTAR"

echo "[3/3] Verificare..."
if [ -x "$EXE" ] || { [ -f "$EXE" ] && chmod +x "$EXE" 2>/dev/null; }; then
    echo ""
    echo "INSTALARE REUSITA!"
    echo "  $EXE"
    "$EXE" --version 2>&1 | head -1
    echo "$URL" > "$INSTALL_DIR/svtav1hdr_version.txt"
    echo ""
    echo "Note:"
    echo "  - Resursa de TEST/validare — suita NU o cheama la encodare."
    echo "  - DELIBERAT in subfolder, NU pe PATH (altfel caps-check-ul"
    echo "    hdr10plus-json ar da fals-pozitiv pt libsvtav1 din ffmpeg)."
    echo "  - Exemplu (stream de referinta DV+HDR10+ cu plasare conforma):"
    echo "      \"$EXE\" -i in.y4m --dolby-vision-rpu rpu.bin --hdr10plus-json hp.json -b out.ivf"
    exit 0
fi
echo "[!] SvtAv1EncApp nu a rezultat din arhiva — dezarhiveaza manual in $INSTALL_DIR"
exit 1
