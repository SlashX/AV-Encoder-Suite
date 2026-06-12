#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# openapv_validator.sh — Installer & Updater
# Compileaza si instaleaza validatorul oficial OpenAPV (oapv_app_dec /
# oapv_app_enc) — implementarea de REFERINTA a codecului APV (RFC 9924,
# AcademySoftwareFoundation/openapv). C + CMake; app-urile se leaga STATIC
# de liboapv (OAPV_APP_STATIC_BUILD=ON default) → binare self-contained.
#
# OPTIONAL: suita functioneaza complet fara el. Cand oapv_app_dec e in
# PATH, verificarea APV HDR10+ post-inject ruleaza automat si un
# decode-check cu decoderul de referinta; cand lipseste, pasul e sarit
# tacut. Nu exista pachete brew/apt/cargo pentru OpenAPV → build din
# sursa pe toate platformele bash (Termux / Linux / macOS).
# ══════════════════════════════════════════════════════════════════════

REPO_URL="https://github.com/AcademySoftwareFoundation/openapv.git"
SRC_DIR="$HOME/openapv"
# Numele binarelor — schimba AICI daca upstream le redenumeste
DEC_NAME="oapv_app_dec"
ENC_NAME="oapv_app_enc"

# ── Platforma → destinatie binare + dependente ────────────────────────
IS_TERMUX=0
case "$(uname -s 2>/dev/null)" in
    Darwin)
        BIN_DIR="$HOME/.local/bin"
        for dep in git cmake cc; do
            if ! command -v "$dep" &>/dev/null; then
                echo "Dependenta lipsa: $dep — instaleaza cu:"
                echo "  brew install git cmake"
                echo "  (compilatorul vine cu Xcode Command Line Tools: xcode-select --install)"
                exit 1
            fi
        done
        ;;
    Linux)
        if [ -d "/data/data/com.termux" ] || [ -n "$TERMUX_VERSION" ]; then
            IS_TERMUX=1
            # Termux: binarele NU pot rula din shared storage (noexec) → $PREFIX/bin
            BIN_DIR="$PREFIX/bin"
            for dep in git cmake clang make; do
                if ! command -v "$dep" &>/dev/null; then
                    echo "  Instalez $dep..."
                    pkg install "$dep" -y
                fi
            done
        else
            BIN_DIR="$HOME/.local/bin"
            for dep in git cmake cc make; do
                if ! command -v "$dep" &>/dev/null; then
                    echo "Dependenta lipsa: $dep — instaleaza cu managerul distro-ului:"
                    echo "  Debian/Ubuntu: sudo apt install git cmake build-essential"
                    echo "  Fedora:        sudo dnf install git cmake gcc gcc-c++ make"
                    echo "  Arch:          sudo pacman -S git cmake base-devel"
                    exit 1
                fi
            done
        fi
        ;;
    *)
        echo "Platforma nesuportata de acest installer (foloseste openapv_validator.ps1 pe Windows)."
        exit 1
        ;;
esac

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║    OPENAPV VALIDATOR INSTALLER & UPDATER     ║"
echo "╚══════════════════════════════════════════════╝"

# ── 1. Clone sau update ───────────────────────────────────────────────
echo ""
if [ ! -d "$SRC_DIR/.git" ]; then
    echo "[1/3] Descarc sursa de pe GitHub..."
    git clone --depth 1 "$REPO_URL" "$SRC_DIR" || exit 1
    cd "$SRC_DIR" || exit 1
else
    echo "[1/3] Director existent gasit. Verific actualizari..."
    cd "$SRC_DIR" || exit 1
    git fetch
    LOCAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse '@{u}' 2>/dev/null || echo "$LOCAL")
    if [ "$LOCAL" = "$REMOTE" ]; then
        echo "  [OK] Sursa este deja la zi."
        if command -v "$DEC_NAME" &>/dev/null; then
            echo "  Binarul este deja instalat ($(command -v "$DEC_NAME")). Nimic de facut."
            exit 0
        fi
    else
        echo "  Actualizare gasita. Descarc noile modificari..."
        git pull
    fi
fi

# ── 2. Build (CMake, app static → fara dependinta de liboapv.so) ──────
echo ""
echo "[2/3] Compilez cu CMake (poate dura cateva minute)..."
NPROC=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
cmake -S "$SRC_DIR" -B "$SRC_DIR/build" -DCMAKE_BUILD_TYPE=Release \
      -DOAPV_APP_STATIC_BUILD=ON -DENABLE_TESTS=OFF || exit 1
cmake --build "$SRC_DIR/build" -j "$NPROC" || exit 1

# ── 3. Instalare binare ───────────────────────────────────────────────
DEC_BIN=$(find "$SRC_DIR/build" -type f -name "$DEC_NAME" 2>/dev/null | head -1)
ENC_BIN=$(find "$SRC_DIR/build" -type f -name "$ENC_NAME" 2>/dev/null | head -1)
if [ -n "$DEC_BIN" ] && [ -n "$ENC_BIN" ]; then
    echo ""
    echo "[3/3] Instalez binarele in $BIN_DIR..."
    mkdir -p "$BIN_DIR"
    cp "$DEC_BIN" "$ENC_BIN" "$BIN_DIR/"
    chmod +x "$BIN_DIR/$DEC_NAME" "$BIN_DIR/$ENC_NAME"
    echo ""
    echo "INSTALARE REUSITA!"
    echo "Binare disponibile: $BIN_DIR/$DEC_NAME, $BIN_DIR/$ENC_NAME"
    if [ "$IS_TERMUX" -eq 0 ] && ! echo ":$PATH:" | grep -q ":$BIN_DIR:"; then
        echo ""
        echo "  ATENTIE: $BIN_DIR nu e in PATH. Adauga in ~/.bashrc / ~/.zshrc:"
        echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi
    echo ""
    echo "Verificarea APV HDR10+ din suita va folosi acum automat"
    echo "decoderul de referinta OpenAPV (decode-check post-inject)."
else
    echo ""
    echo "EROARE: Compilarea a esuat (binarele nu au fost gasite in build/)."
    echo "Verifica log-urile de mai sus."
    exit 1
fi
