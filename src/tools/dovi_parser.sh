#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# dovi_parser.sh — Installer & Updater
# Instaleaza quietvoid/dovi_tool pentru procesare Dolby Vision RPU.
# Folosit de av_encoder_x265.sh pentru triple-layer DV+HDR10+HDR10+.
# Termux: build din sursa cu pkg + cargo. Linux/macOS: hint catre brew/cargo.
# ══════════════════════════════════════════════════════════════════════

# v96: pe Linux si macOS scriptul doar tiparea un sfat si iesea cu 0. Sfatul era gresit
# (`cargo install dovi_tool` → "could not find `dovi_tool` in registry crates-io": quietvoid
# publica pe GitHub, nu pe crates.io), iar codul 0 il facea sa para reusit. Logica de
# clone+build de mai jos exista deja aici — era doar rezervata Termux-ului. Acum ruleaza pe
# toate trei platformele, cu destinatia potrivita fiecareia (model: av1dovi_parser.sh).
case "$(uname -s 2>/dev/null)" in
    Darwin)
        BIN_DEST="/usr/local/bin/dovi_tool"
        IS_TERMUX=0
        ;;
    Linux)
        if [ -d "/data/data/com.termux" ]; then
            BIN_DEST="/data/data/com.termux/files/usr/bin/dovi_tool"
            IS_TERMUX=1
        else
            BIN_DEST="$HOME/.local/bin/dovi_tool"
            IS_TERMUX=0
        fi
        ;;
    *)
        echo "Platforma nesuportata. Suport: Termux, Linux, macOS."
        exit 1
        ;;
esac

REPO_URL="https://github.com/quietvoid/dovi_tool.git"
INSTALL_DIR="$HOME/dovi_tool"
# NB: BIN_DEST vine din blocul de platforma de mai sus (Termux / Linux / macOS).

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║    DOVI_TOOL INSTALLER & UPDATER             ║"
echo "╚══════════════════════════════════════════════╝"

# 1. Verificare dependente de sistem
echo ""
echo "[1/4] Verificare dependente sistem..."
if ! command -v rustc &>/dev/null || ! command -v cargo &>/dev/null; then
    if [ "$IS_TERMUX" = "1" ]; then
        echo "  Instalez rust (rustc + cargo) prin pkg..."
        pkg install rust -y
    else
        echo "  EROARE: Rust toolchain (rustc + cargo) negasit."
        echo "  Instaleaza prin rustup:"
        echo "    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
        echo "  Apoi reia acest script."
        exit 1
    fi
fi
if [ "$IS_TERMUX" = "1" ]; then
    for dep in git clang make pkg-config; do
        if ! command -v "$dep" &>/dev/null; then
            echo "  Instalez $dep..."
            pkg install "$dep" -y
        fi
    done
    if ! pkg-config --exists fontconfig 2>/dev/null; then
        echo "  Instalez fontconfig..."
        pkg install fontconfig -y
    fi
else
    # Pe Linux/macOS nu instalam pachete de sistem in locul utilizatorului; verificam si
    # spunem exact ce lipseste. fontconfig NU e blocanta — build-ul cade pe fontul intern.
    for dep in git cc make pkg-config; do
        command -v "$dep" &>/dev/null || echo "  ATENTIE: '$dep' lipseste (build-ul poate esua)."
    done
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
    mkdir -p "$(dirname "$BIN_DEST")"
    # v96: `cp`/`chmod` pot esua (destinatie inexistenta, fara drepturi) — inainte scriptul
    # tiparea oricum "INSTALARE REUSITA" si iesea cu 0, deci un apelant nu avea cum sa afle.
    if ! cp "target/release/dovi_tool" "$BIN_DEST" 2>/dev/null || ! chmod +x "$BIN_DEST" 2>/dev/null; then
        echo ""
        echo "EROARE: nu am putut instala binarul in $BIN_DEST"
        echo "  Compilarea a reusit — binarul e in $INSTALL_DIR/target/release/dovi_tool"
        echo "  Copiaza-l manual intr-un folder din PATH, sau seteaza AV_TOOL_* catre el."
        exit 1
    fi

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
    # v96: cauza cea mai frecventa pe Linux/macOS e un Rust prea vechi din pachetul distro
    # (upstream cere versiuni recente). Mesajul asta scuteste o cautare pe cont propriu.
    if [ "${IS_TERMUX:-0}" != "1" ]; then
        echo "  Daca eroarea de mai sus mentioneaza o versiune de rustc, toolchain-ul distro"
        echo "  e prea vechi. Instaleaza unul recent si reia:"
        echo "    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
    fi
    exit 1
fi
