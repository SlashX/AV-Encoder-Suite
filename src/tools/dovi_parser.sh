#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# dovi_parser.sh — Installer & Updater
# Instaleaza quietvoid/dovi_tool pentru procesare Dolby Vision RPU.
# Folosit de av_encoder_x265.sh pentru triple-layer DV+HDR10+HDR10+.
# Termux: build din sursa cu pkg + cargo. Linux/macOS: hint catre brew/cargo.
# ══════════════════════════════════════════════════════════════════════

# v41: pe Linux/macOS sugeram install via package manager si iesim.
case "$(uname -s 2>/dev/null)" in
    Darwin)
        echo "macOS detectat — instaleaza prin Homebrew:"
        echo "  brew install dovi_tool"
        exit 0
        ;;
    Linux)
        if [ ! -d "/data/data/com.termux" ]; then
            echo "Linux detectat — instaleaza via cargo (Rust) sau distro package:"
            echo "  cargo install dovi_tool"
            echo "  (sau verifica AUR/COPR daca distroul tau il are pachetizat)"
            exit 0
        fi
        ;;
esac

REPO_URL="https://github.com/quietvoid/dovi_tool.git"
INSTALL_DIR="$HOME/dovi_tool"
BIN_DEST="/data/data/com.termux/files/usr/bin/dovi_tool"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║    DOVI_TOOL INSTALLER & UPDATER             ║"
echo "╚══════════════════════════════════════════════╝"

# 1. Verificare dependente de sistem
echo ""
echo "[1/4] Verificare dependente sistem..."
if ! command -v rustc &>/dev/null || ! command -v cargo &>/dev/null; then
    echo "  Instalez rust (rustc + cargo)..."
    pkg install rust -y
fi
for dep in git clang make pkg-config; do
    if ! command -v "$dep" &>/dev/null; then
        echo "  Instalez $dep..."
        pkg install "$dep" -y
    fi
done
# fontconfig necesara pentru dovi_tool
if ! pkg-config --exists fontconfig 2>/dev/null; then
    echo "  Instalez fontconfig..."
    pkg install fontconfig -y
fi

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
            dovi_tool --version 2>/dev/null
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
# Bypass fontconfig daca nu e disponibil
if pkg-config --exists fontconfig 2>/dev/null; then
    cargo build --release
else
    cargo build --release --no-default-features --features internal-font
fi

# 4. Instalare binar
if [ -f "target/release/dovi_tool" ]; then
    echo ""
    echo "[4/4] Instalez binarul in system path..."
    cp "target/release/dovi_tool" "$BIN_DEST"
    chmod +x "$BIN_DEST"

    echo ""
    echo "INSTALARE REUSITA!"
    echo "Binar disponibil: $BIN_DEST"
    dovi_tool --version 2>/dev/null
    echo ""
    echo "Acum poti folosi optiunea Triple-Layer (DV+HDR10+HDR10+)"
    echo "in av_encoder_x265.sh."
else
    echo ""
    echo "EROARE: Compilarea a esuat. Verifica log-urile de mai sus."
    exit 1
fi
