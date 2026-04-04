#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  exiftool_update.sh — ExifTool smart updater pentru Termux
#  Verifica versiunea din pkg vs exiftool.org
#  Daca pkg e actualizat → pkg upgrade
#  Daca pkg e in urma   → build manual din sursa
# ═══════════════════════════════════════════════════════════════

set -e

echo "═══════════════════════════════════════════════════════════════"
echo "  ExifTool Smart Updater — Termux"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# ── Versiune curenta instalata ──────────────────────────────────
CURRENT_VER=$(exiftool -ver 2>/dev/null || echo "0")
echo "  Versiune instalata:  $CURRENT_VER"

# ── Ultima versiune de pe exiftool.org ─────────────────────────
echo "  Verificare exiftool.org..."
LATEST_VER=$(curl -s https://exiftool.org/ver.txt 2>/dev/null | tr -d '[:space:]')
if [ -z "$LATEST_VER" ]; then
    echo "  EROARE: Nu pot contacta exiftool.org. Verifica conexiunea."
    exit 1
fi
echo "  Ultima versiune:     $LATEST_VER"
echo ""

# ── Deja la zi ─────────────────────────────────────────────────
if [ "$CURRENT_VER" = "$LATEST_VER" ]; then
    echo "  ✓ ExifTool este deja la ultima versiune ($LATEST_VER)."
    echo ""
    exit 0
fi

echo "  Update disponibil: $CURRENT_VER → $LATEST_VER"
echo ""

# ── Verifica versiunea disponibila in pkg ──────────────────────
echo "  Verificare versiune disponibila in pkg Termux..."
pkg update -y > /dev/null 2>&1
PKG_VER=$(pkg show exiftool 2>/dev/null | grep "^Version:" | awk '{print $2}' | cut -d'-' -f1)
echo "  Versiune pkg Termux: ${PKG_VER:-necunoscuta}"
echo ""

# ── Decizie: pkg sau build manual ──────────────────────────────
if [ "$PKG_VER" = "$LATEST_VER" ]; then
    echo "  → pkg Termux are versiunea $LATEST_VER. Instalez prin pkg..."
    echo ""
    pkg install exiftool -y
    echo ""
    echo "  ✓ ExifTool actualizat prin pkg la versiunea $LATEST_VER"
else
    echo "  → pkg Termux are $PKG_VER (in urma). Build manual din sursa..."
    echo ""

    # Descarca sursa
    TARBALL="Image-ExifTool-${LATEST_VER}.tar.gz"
    EXTRACT_DIR="Image-ExifTool-${LATEST_VER}"
    echo "  Descarcare $TARBALL..."
    curl -L "https://exiftool.org/${TARBALL}" -o "$TARBALL"
    echo ""

    # Extrage
    echo "  Extragere arhiva..."
    tar xzf "$TARBALL"

    # Instaleaza
    echo "  Instalare in \$PREFIX/bin/ si \$PREFIX/lib/perl5/..."
    cp "${EXTRACT_DIR}/exiftool" "$PREFIX/bin/"
    cp -r "${EXTRACT_DIR}/lib/"* "$PREFIX/lib/perl5/"

    # Curata
    rm -rf "$TARBALL" "$EXTRACT_DIR"

    echo ""
    echo "  ✓ ExifTool instalat manual la versiunea $LATEST_VER"
    echo "  ℹ Cand pkg Termux actualizeaza pachetul, pkg upgrade il va suprascrie automat."
fi

echo ""
echo "  Verificare finala:"
exiftool -ver
echo ""
echo "═══════════════════════════════════════════════════════════════"
