<#
.SYNOPSIS
    Installer pentru SvtAv1EncApp (fork-ul SVT-AV1-HDR) pe Windows —
    resursa de TEST/validare pentru pipeline-ul AV1 DV/HDR10+ (v92).
.DESCRIPTION
    Fork-ul SVT-AV1-HDR (juliobbv-p) e un encoder AV1 cu suport NATIV
    --dolby-vision-rpu si --hdr10plus-json (mainline SVT-AV1 nu le are).
    Suita NU il foloseste la encodare — e oracol de dezvoltare/validare:
      - produce stream-uri de REFERINTA cu plasarea conforma a OBU-urilor
        de metadata (validarea reorder-ului v92 din av1_dv_t35_repair.py);
      - produce stream-uri svtav1-inline HDR10+ pe care ffmpeg-ul legat de
        SVT-AV1 mainline NU le poate genera (calea SW-hybrid).

    DELIBERAT instalat in subfolder (tools/svtav1hdr/), NU pe PATH:
    _check_svtav1_hdr10plus_caps (av_common.sh) probeaza INTAI SvtAv1EncApp
    de pe PATH — binarul fork ar raspunde "da" pentru un libsvtav1 din
    ffmpeg care poate sa NU aiba hdr10plus-json → fals-pozitiv → encode
    esuat in loc de fallback-ul gratios HDR10 static.
#>

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  SVT-AV1-HDR / SvtAv1EncApp (Win) — v92      ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$InstallDir = Join-Path $PSScriptRoot "svtav1hdr"
$Exe        = Join-Path $InstallDir "SvtAv1EncApp.exe"

# 0. Deja instalat?
if (Test-Path $Exe) {
    Write-Host "SvtAv1EncApp e deja instalat:" -ForegroundColor Green
    Write-Host "  $Exe"
    $v = & $Exe --version 2>&1 | Select-Object -First 1
    if ($v) { Write-Host "  $v" }
    if (-not $env:AV_NONINTERACTIVE) { Read-Host "`nApasa Enter pentru a iesi" }
    exit 0
}

# 1. Ultimul release de pe GitHub (asset x86-64-v3 = orice CPU cu AVX2)
Write-Host "[1/3] Caut ultimul release SVT-AV1-HDR..." -ForegroundColor Yellow
$api = "https://api.github.com/repos/juliobbv-p/svt-av1-hdr/releases/latest"
try {
    $rel = Invoke-RestMethod -Uri $api -UseBasicParsing
} catch {
    Write-Host "[!] Nu pot interoga GitHub API: $api" -ForegroundColor Red
    Write-Host "    Descarca manual asset-ul Windows_x86-64_x86-64-v3*.tar.xz de pe:"
    Write-Host "      https://github.com/juliobbv-p/svt-av1-hdr/releases"
    Write-Host "    si dezarhiveaza SvtAv1EncApp.exe in: $InstallDir"
    if (-not $env:AV_NONINTERACTIVE) { Read-Host "`nApasa Enter pentru a iesi" }
    exit 1
}
$asset = $rel.assets | Where-Object { $_.name -like "Windows_x86-64_x86-64-v3*.tar.xz" } | Select-Object -First 1
if (-not $asset) {
    Write-Host "[!] Release-ul $($rel.tag_name) nu are asset Windows x86-64-v3." -ForegroundColor Red
    Write-Host "    Vezi manual: https://github.com/juliobbv-p/svt-av1-hdr/releases"
    if (-not $env:AV_NONINTERACTIVE) { Read-Host "`nApasa Enter pentru a iesi" }
    exit 1
}
Write-Host "  $($rel.tag_name) — $($asset.name) ($([math]::Round($asset.size/1MB,1)) MB)" -ForegroundColor Green

# 2. Download + extract (tar.xz — tar-ul nativ Windows 10+ stie xz)
Write-Host "[2/3] Descarc si dezarhivez..." -ForegroundColor Yellow
$tmpTar = Join-Path $env:TEMP $asset.name
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmpTar -UseBasicParsing
if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
    Write-Host "[!] tar.exe lipseste (Windows 10 1803+ il are nativ)." -ForegroundColor Red
    Write-Host "    Dezarhiveaza manual $tmpTar in $InstallDir"
    if (-not $env:AV_NONINTERACTIVE) { Read-Host "`nApasa Enter pentru a iesi" }
    exit 1
}
New-Item -ItemType Directory -Force $InstallDir | Out-Null
tar -xf $tmpTar -C $InstallDir
Remove-Item $tmpTar -Force -ErrorAction SilentlyContinue

# 3. Verificare + ghidare
if (Test-Path $Exe) {
    $v = & $Exe --version 2>&1 | Select-Object -First 1
    Set-Content -Path (Join-Path $InstallDir "svtav1hdr_version.txt") `
        -Value "$($rel.tag_name) — $($asset.name)" -Encoding UTF8
    Write-Host "[3/3] Verificare..." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "INSTALARE REUSITA!" -ForegroundColor Green
    Write-Host "  $Exe"
    Write-Host "  $v"
    Write-Host ""
    Write-Host "Note:" -ForegroundColor Yellow
    Write-Host "  - Resursa de TEST/validare — suita NU o cheama la encodare."
    Write-Host "  - DELIBERAT in subfolder, NU pe PATH (altfel caps-check-ul"
    Write-Host "    hdr10plus-json ar da fals-pozitiv pt libsvtav1 din ffmpeg)."
    Write-Host "  - Exemplu (stream de referinta DV+HDR10+ cu plasare conforma):"
    Write-Host "      & `"$Exe`" -i in.y4m --dolby-vision-rpu rpu.bin --hdr10plus-json hp.json -b out.ivf"
} else {
    Write-Host "[!] SvtAv1EncApp.exe nu a rezultat din arhiva." -ForegroundColor Red
    Write-Host "    Dezarhiveaza manual de pe https://github.com/juliobbv-p/svt-av1-hdr/releases in $InstallDir"
    if (-not $env:AV_NONINTERACTIVE) { Read-Host "`nApasa Enter pentru a iesi" }
    exit 1
}
if (-not $env:AV_NONINTERACTIVE) { Read-Host "`nApasa Enter pentru a iesi" }
exit 0
