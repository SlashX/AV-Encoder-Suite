#!/usr/bin/env bash
# v69 — invariant: numele binarelor externe NU apar hardcodate in scripturile
# de productie (executie SAU afisaj) in afara surselor unice.
#   Lista de nume e AUTO-DERIVATA din blocul AV_TOOL_* din av_common.sh →
#   cand adaugi un tool nou in bloc, e pazit automat (zero mentenanta aici).
#   Surse unice legitime (allowlist): liniile care contin AV_TOOL_/AV_ENGINE_
#   (blocul de config + dispatcher/resolver/env-override), numele de functii
#   (_check_*tool*), hint-urile de installer (*_parser.sh/.ps1), URL-uri,
#   numele de PACHET din av_pkg_install_hint, comentariile.
#   Scope: src/*.sh + src/*.ps1 (installerele din tools/ au numele la TOP —
#   propria lor sursa unica — si sunt scutite prin design).
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="$PROJECT_ROOT/src"

# ── 1. Deriva numele din blocul de config (sursa canonica) ───────────
mapfile -t TOOL_NAMES < <(sed -nE 's/^AV_TOOL_[A-Z0-9_]+="\$\{AV_TOOL_[A-Z0-9_]+:-([^}]+)\}".*/\1/p' "$SRC/av_common.sh")
ENGINE_NAME=$(sed -nE 's|^AV_ENGINE_APV_HDR10PLUS="\$\{AV_ENGINE_APV_HDR10PLUS:-\$SCRIPT_DIR/([^}]+)\}".*|\1|p' "$SRC/av_common.sh")

assert_eq "1" "$([[ ${#TOOL_NAMES[@]} -ge 7 ]] && echo 1 || echo 0)" "blocul AV_TOOL_* exista si are >=7 intrari (gasit: ${#TOOL_NAMES[@]}: ${TOOL_NAMES[*]})"
assert_eq "apv_hdr10plus.py" "$ENGINE_NAME" "AV_ENGINE_APV_HDR10PLUS derivat corect"

# ── 2. Scan: niciun nume hardcodat in afara surselor unice ───────────
# Allowlist (vezi antet). NB: functiile PS1 CamelCase (Test-DoviToolFor) nu
# contin numele cu underscore → nu match-uiesc oricum.
ALLOW='AV_TOOL_|AV_ENGINE_|_check_[a-z0-9_]*tool|_parser\.(sh|ps1)|av_pkg_install_hint|exiftool\.org|Get-ToolForExtract|Get-ToolForInject|Get-ApvHdr10PlusEnginePath|Get-ExifCmd'
violations=""
for name in "${TOOL_NAMES[@]}" "$ENGINE_NAME"; do
    hits=$(grep -rn -- "$name" "$SRC"/*.sh "$SRC"/*.ps1 2>/dev/null \
        | grep -vE '^[^:]+:[0-9]+:\s*#|^[^:]+:[0-9]+:\s*<#' \
        | grep -vE "$ALLOW" || true)
    [[ -n "$hits" ]] && violations+="$hits"$'\n'
done
if [[ -n "${violations//[$'\n ']/}" ]]; then
    echo "$violations" | head -10
fi
assert_eq "" "${violations//[$'\n ']/}" "invariant: zero nume de tool hardcodate in src/*.{sh,ps1} (executie/afisaj prin AV_TOOL_*)"

# ── 3. Consumatorii-cheie chiar folosesc variabilele ─────────────────
COMMON="$(cat "$SRC/av_common.sh")"
assert_contains "$COMMON" 'echo "$AV_TOOL_AV1DOVI"'        "dispatcher: av1 dovi prin variabila"
assert_contains "$COMMON" 'command -v "$AV_TOOL_HDR10PLUS"' "check: hdr10plus prin variabila"
assert_contains "$COMMON" 'command -v "$AV_TOOL_SVTAV1ENCAPP"' "caps-probe: SvtAv1EncApp prin variabila"
assert_contains "$(cat "$SRC/av_telemetry.sh")" '"$AV_TOOL_EXIFTOOL" -p' "av_telemetry: exiftool prin variabila"
true
