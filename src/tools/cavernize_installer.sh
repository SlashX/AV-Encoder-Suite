#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# cavernize_installer.sh — Ghid de instalare Cavernize (Cavern)
#
# Cavern (VoidXH) e singurul renderer LIBER care decodeaza obiectele Dolby
# Atmos (E-AC-3 JOC nativ; TrueHD prin truehdd, descarcat automat de
# Cavernize la prima rulare) si le reda pozitional in canale 7.1.4. Suita
# il foloseste in meniul audio-only opt 10 (Eclipsa/IAMF): sursa Atmos →
# render WAV 7.1.4 → authoring IAMF cu canale de inaltime REALE. v89.
#
# OPTIONAL: suita functioneaza complet fara el — cand Cavernize lipseste,
# authoring-ul IAMF pe surse Atmos foloseste onest doar bed-ul (v88).
#
# DISPONIBILITATE: Cavernize e app .NET Windows (CavernizeGUI.exe = CLI in
# console-mode) + build separat macOS (NEtestat de suita — console-mode
# nevalidat acolo). Pe Linux/Termux NU exista → mesaj onest.
# Numele binarului e overridable prin env AV_TOOL_CAVERNIZE.
# ══════════════════════════════════════════════════════════════════════

BIN="${AV_TOOL_CAVERNIZE:-CavernizeGUI}"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  CAVERNIZE (Cavern) — Atmos → 7.1.4 (v89)    ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

if command -v "$BIN" >/dev/null 2>&1; then
    echo "Cavernize e deja disponibil: $(command -v "$BIN")"
    echo "Suita il va folosi automat (AV_TOOL_CAVERNIZE)."
    exit 0
fi

case "$(uname -s 2>/dev/null)" in
    Darwin)
        echo "macOS: Cavernize are build dedicat pe pagina de release-uri GitHub:"
        echo "  https://github.com/VoidXH/Cavern/releases (asset-ul Cavernize pt macOS)"
        echo ""
        echo "Pasi manuali:"
        echo "  1) Descarca si dezarhiveaza asset-ul macOS."
        echo "  2) Seteaza calea catre binarul Cavernize:"
        echo "       export AV_TOOL_CAVERNIZE=\"/cale/catre/Cavernize\""
        echo ""
        echo "NOTA ONESTA: suita a validat console-mode-ul Cavernize DOAR pe Windows."
        echo "Pe macOS fluxul e oferit best-effort — daca renderul esueaza, authoring-ul"
        echo "IAMF cade gratios pe bed-ul de canale (comportamentul clasic)."
        exit 0
        ;;
    MINGW*|MSYS*|CYGWIN*)
        echo "Windows: foloseste installer-ul PowerShell (descarca zip-ul portabil oficial):"
        echo "  powershell -File tools/cavernize_installer.ps1"
        echo ""
        echo "Sau manual: https://cavern.sbence.hu/cavern/downloads.php (Cavernize portable),"
        echo "dezarhiveaza si seteaza AV_TOOL_CAVERNIZE la calea catre CavernizeGUI.exe."
        echo "(Cere .NET Desktop Runtime 8+; pe 9/10 suita seteaza automat roll-forward.)"
        exit 0
        ;;
    *)
        echo "Linux/Termux: Cavernize NU are build pentru aceasta platforma (app .NET"
        echo "Windows + build separat macOS; nu exista CLI Linux)."
        echo ""
        echo "Pe aceste platforme authoring-ul Eclipsa/IAMF pe surse Atmos foloseste"
        echo "onest doar bed-ul de canale (obiectele raman nedecodabile cu unelte libere)."
        echo "Alternativa: ruleaza meniul 2 opt 10 pe un sistem Windows/macOS cu Cavernize."
        exit 0
        ;;
esac
