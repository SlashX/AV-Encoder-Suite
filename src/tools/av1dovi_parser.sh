#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# av1dovi_parser.sh — Installer & Updater (sven-pke fork)
# Instaleaza sven-pke/dovi_tool (fork al quietvoid/dovi_tool cu suport AV1).
# Folosit de av_encoder_av1.sh pentru injectare RPU Dolby Vision in AV1.
# Binarul se instaleaza ca av1dovi_tool (rename pentru a evita coliziunea
# cu dovi_tool upstream, care ramane HEVC-only).
# Termux: build din sursa cu pkg + cargo. Linux/macOS: build via cargo.
# Note: fork-ul nu are GitHub releases — build din sursa obligatoriu.
# ══════════════════════════════════════════════════════════════════════

REPO_URL="https://github.com/sven-pke/dovi_tool.git"
INSTALL_DIR="$HOME/av1dovi_tool"
SRC_BIN="dovi_tool"             # numele binarului produs de cargo
DEST_BIN="av1dovi_tool"         # numele dupa rename pentru a evita coliziunea

# Detect platform si seteaza BIN_DEST
case "$(uname -s 2>/dev/null)" in
    Darwin)
        BIN_DEST="/usr/local/bin/$DEST_BIN"
        IS_TERMUX=0
        ;;
    Linux)
        if [ -d "/data/data/com.termux" ]; then
            BIN_DEST="/data/data/com.termux/files/usr/bin/$DEST_BIN"
            IS_TERMUX=1
        else
            BIN_DEST="$HOME/.local/bin/$DEST_BIN"
            IS_TERMUX=0
        fi
        ;;
    *)
        echo "Platforma nesuportata. Suport: Termux, Linux, macOS."
        exit 1
        ;;
esac

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  AV1 DOVI_TOOL INSTALLER (sven-pke fork)     ║"
echo "╚══════════════════════════════════════════════╝"
echo "  Repo:    $REPO_URL"
echo "  Install: $INSTALL_DIR"
echo "  Binar:   $BIN_DEST (rename din $SRC_BIN)"
echo ""

# 1. Verificare dependente de sistem
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
    for dep in git; do
        if ! command -v "$dep" &>/dev/null; then
            echo "  EROARE: $dep negasit. Instaleaza-l si reia scriptul."
            exit 1
        fi
    done
fi

# 2. Clone sau Update
if [ ! -d "$INSTALL_DIR" ]; then
    echo ""
    echo "[2/4] Descarc sursa de pe GitHub (sven-pke fork)..."
    git clone "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR" || exit 1
else
    echo ""
    echo "[2/4] Director existent gasit. Verific actualizari..."
    cd "$INSTALL_DIR" || exit 1
    git fetch
    LOCAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse '@{u}' 2>/dev/null || echo "$LOCAL")

    if [ "$LOCAL" = "$REMOTE" ]; then
        echo "  [OK] Versiunea este deja la zi."
        if [ -f "$BIN_DEST" ]; then
            echo "  Binarul este deja instalat. Nimic de facut."
            "$BIN_DEST" --version 2>/dev/null
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
# v96: conditia era `IS_TERMUX=1 && fara fontconfig` — deci pe orice Linux desktop sau
# container de CI fara fontconfig se cadea pe build-ul normal si cargo murea cu un panic
# despre `fontconfig.pc`, imposibil de dedus pentru utilizator. Ocolirea era corecta, doar
# gardata prea ingust: singurul criteriu relevant e daca fontconfig chiar exista.
if ! pkg-config --exists fontconfig 2>/dev/null; then
    cargo build --release --no-default-features --features internal-font
else
    cargo build --release
fi

# 4. Instalare binar (cu rename)
if [ -f "target/release/$SRC_BIN" ]; then
    echo ""
    echo "[4/4] Instalez binarul in system path (rename: $SRC_BIN -> $DEST_BIN)..."
    mkdir -p "$(dirname "$BIN_DEST")"
    # v96: `cp`/`chmod` pot esua (destinatie fara drepturi de scriere — cazul obisnuit pe
    # macOS, unde /usr/local/bin cere sudo). Inainte scriptul tiparea oricum "INSTALARE
    # REUSITA" si iesea cu 0, deci apelantul nu avea cum sa afle ca nu s-a instalat nimic.
    if ! cp "target/release/$SRC_BIN" "$BIN_DEST" 2>/dev/null || ! chmod +x "$BIN_DEST" 2>/dev/null; then
        echo ""
        echo "EROARE: nu am putut instala binarul in $BIN_DEST"
        echo "  Compilarea a reusit — binarul e in $INSTALL_DIR/target/release/$SRC_BIN"
        echo "  Copiaza-l manual intr-un folder din PATH, sau seteaza AV_TOOL_* catre el."
        exit 1
    fi

    echo ""
    echo "INSTALARE REUSITA!"
    echo "Binar disponibil: $BIN_DEST"
    "$BIN_DEST" --version 2>/dev/null
    echo ""
    echo "Acum poti folosi optiunile DV pentru AV1 in av_encoder_av1.sh."
    echo "Note: dovi_tool upstream (HEVC) ramane neatins, pe PATH normal."
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
