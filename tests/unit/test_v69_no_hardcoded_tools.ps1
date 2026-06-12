# v69 — invariant hardcodari (mirror al test_v69_no_hardcoded_tools.sh).
#   Numele binarelor externe NU apar hardcodate in src/*.{sh,ps1} in afara
#   surselor unice. Lista e AUTO-DERIVATA din blocul AV_TOOL_* din av_common.sh
#   (canonul partajat bash↔PS1) → tool nou in bloc = pazit automat.
. "$PSScriptRoot\..\framework.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'

# ── 1. Deriva numele din blocul de config ────────────────────────────
$common = Get-Content (Join-Path $SRC "av_common.sh") -Raw
$toolNames = [regex]::Matches($common, '(?m)^AV_TOOL_[A-Z0-9_]+="\$\{AV_TOOL_[A-Z0-9_]+:-([^}]+)\}"') |
    ForEach-Object { $_.Groups[1].Value }
$engineName = [regex]::Match($common, '(?m)^AV_ENGINE_APV_HDR10PLUS="\$\{AV_ENGINE_APV_HDR10PLUS:-\$SCRIPT_DIR/([^}]+)\}"').Groups[1].Value

Assert-Eq $true ($toolNames.Count -ge 7) "blocul AV_TOOL_* exista si are >=7 intrari (gasit: $($toolNames.Count): $($toolNames -join ', '))"
Assert-Eq "apv_hdr10plus.py" $engineName "AV_ENGINE_APV_HDR10PLUS derivat corect"

# ── 2. Scan: niciun nume hardcodat in afara surselor unice ───────────
$allow = 'AV_TOOL_|AV_ENGINE_|_check_[a-z0-9_]*tool|_parser\.(sh|ps1)|av_pkg_install_hint|exiftool\.org|Get-ToolForExtract|Get-ToolForInject|Get-ApvHdr10PlusEnginePath|Get-ExifCmd'
$violations = @()
$files = Get-ChildItem -Path $SRC -File | Where-Object { $_.Extension -in '.sh','.ps1' }
foreach ($name in ($toolNames + $engineName)) {
    foreach ($f in $files) {
        $lineNo = 0
        foreach ($line in (Get-Content $f.FullName)) {
            $lineNo++
            # -cnotmatch: CASE-SENSITIVE — altfel variabilele-cache uppercase
            # (DOVI_TOOL_AVAILABLE etc.) ar fi fals-pozitive pe numele lowercase
            if ($line -cnotmatch [regex]::Escape($name)) { continue }
            if ($line -match '^\s*#' -or $line -match '^\s*<#') { continue }
            if ($line -match $allow) { continue }
            $violations += "$($f.Name):$lineNo : $($line.Trim())"
        }
    }
}
if ($violations.Count) { $violations | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" -ForegroundColor Red } }
Assert-Eq 0 $violations.Count "invariant: zero nume de tool hardcodate in src/*.{sh,ps1}"

# ── 3. Consumatorii-cheie PS1 chiar folosesc sursele unice ───────────
$enc = Get-Content (Join-Path $SRC "av_encode.ps1") -Raw
Assert-Match $enc ([regex]::Escape('if ($env:AV_TOOL_AV1DOVI) { $env:AV_TOOL_AV1DOVI } else { "av1dovi_tool" }')) "dispatcher PS1: av1dovi env-overridable"
Assert-Match $enc ([regex]::Escape('Get-Command (Get-ToolForExtract -Codec "hevc" -Kind "dovi")')) "check PS1: dovi prin dispatcher"
Assert-Match (Get-Content (Join-Path $SRC "av_telemetry.ps1") -Raw) 'function Get-ExifCmd' "av_telemetry PS1: resolver exiftool"

Invoke-TestSummary
