#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# hdr10plus_parser.sh — Installer & Updater
# Instalează quietvoid/hdr10plus_tool pentru procesare metadata HDR10+.
# Folosit de av_encoder_x265.sh si av_encoder_av1.sh pentru extragerea
# si injectarea metadatelor dinamice HDR10+ la re-encode.
# Termux: build din sursa cu pkg + cargo. Linux/macOS: hint catre brew/cargo.
# ══════════════════════════════════════════════════════════════════════

# v41: pe Linux/macOS sugeram install via package manager si iesim.
case "$(uname -s 2>/dev/null)" in
    Darwin)
        echo "macOS detectat — instaleaza prin Homebrew:"
        echo "  brew install hdr10plus_tool"
        exit 0
        ;;
    Linux)
        if [ ! -d "/data/data/com.termux" ]; then
            echo "Linux detectat — instaleaza via cargo (Rust) sau distro package:"
            echo "  cargo install hdr10plus_tool"
            echo "  (sau verifica AUR/COPR daca distroul tau il are pachetizat)"
            exit 0
        fi
        ;;
esac

REPO_URL="https://github.com/quietvoid/hdr10plus_tool.git"
INSTALL_DIR="$HOME/hdr10plus_tool"
BIN_DEST="/data/data/com.termux/files/usr/bin/hdr10plus_tool"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║    HDR10+ PARSER INSTALLER & UPDATER         ║"
echo "╚══════════════════════════════════════════════╝"

# 1. Verificare dependente de sistem
echo ""
echo "[1/4] Verificare dependente sistem..."
# Termux: pachetul se numeste 'rust' dar comanda e 'rustc'/'cargo'
if ! command -v rustc &>/dev/null || ! command -v cargo &>/dev/null; then
    echo "  Instalez rust (rustc + cargo)..."
    pkg install rust -y
fi
for dep in git clang make; do
    if ! command -v "$dep" &>/dev/null; then
        echo "  Instalez $dep..."
        pkg install "$dep" -y
    fi
done

# 2. Clone sau Update
if [ ! -d "$INSTALL_DIR" ]; then
    echo ""
    echo "[2/4] Descarc sursa de pe GitHub..."
    git clone "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR" || exit 1
else
    echo ""
    echo "[2/4] Director existent gasit. Verific actualizari..."
    cd "$INSTALL_DIR" || exit 1
    git fetch
    LOCAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse '@{u}')

    if [ "$LOCAL" = "$REMOTE" ]; then
        echo "  [OK] Versiunea este deja la zi."
        if [ -f "$BIN_DEST" ]; then
            echo "  Binarul este deja instalat. Nimic de facut."
            hdr10plus_tool --version 2>/dev/null
            exit 0
        fi
    else
        echo "  Actualizare gasita. Descarc noile modificari..."
        git pull
    fi
fi

# 3. Compilare (Build)
echo ""
echo "[3/4] Incep compilarea cu Cargo (poate dura cateva minute)..."
cargo build --release

# 4. Instalare binar
if [ -f "target/release/hdr10plus_tool" ]; then
    echo ""
    echo "[4/4] Instalez binarul in system path..."
    cp "target/release/hdr10plus_tool" "$BIN_DEST"
    chmod +x "$BIN_DEST"

    echo ""
    echo "INSTALARE REUSITA!"
    echo "Binar disponibil: $BIN_DEST"
    hdr10plus_tool --version 2>/dev/null
    echo ""
    echo "Acum poti folosi optiunea HDR10+ Metadata Preserve"
    echo "in av_encoder_x265.sh si av_encoder_av1.sh."
else
    echo ""
    echo "EROARE: Compilarea a esuat. Verifica log-urile de mai sus."
    exit 1
fi
