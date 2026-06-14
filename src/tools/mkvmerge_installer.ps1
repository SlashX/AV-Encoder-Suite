<#
.SYNOPSIS
    Installer pentru mkvmerge (MKVToolNix) pe Windows — semnalizare dvcC de
    container pe hibridele HEVC Dolby Vision (v70).
.DESCRIPTION
    mkvmerge parseaza RPU-ul din bitstream-ul HEVC brut si scrie automat
    "DOVI configuration record" (Block Addition Mapping) in MKV → TV-urile
    care decid dupa dvcC activeaza Dolby Vision. ffmpeg NU poate sintetiza
    dvcC din RPU brut (calea de azi lasa DV doar in bitstream, dormant pe TV).
    OPTIONAL: cand mkvmerge lipseste, suita cade tacut pe pasul MP4 (v69).

    Descarca pachetul PORTABIL oficial (.7z) de pe mkvtoolnix.download si
    copiaza DOAR mkvmerge.exe (link static, self-contained — fara DLL-uri) in
    folderul tools/. Extragere: tar.exe (libarchive, suporta 7z pe Win10+),
    fallback 7-Zip instalat. Daca nimic nu merge → ghidare (winget / manual).
    Numele binarului e overridable prin env AV_TOOL_MKVMERGE.
.PARAMETER Version
    Versiunea de descarcat (ex: 99.0). Implicit: determinata automat de pe
    pagina oficiala de download.
#>
param([string]$Version = "")

$ErrorActionPreference = "Stop"
$InstallDir  = $PSScriptRoot
$Target      = Join-Path $InstallDir "mkvmerge.exe"
$VersionFile = Join-Path $InstallDir "mkvtoolnix_version.txt"

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   MKVMERGE INSTALLER (Windows) — dvcC v70    ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# 0. Deja in PATH? (suita il gaseste automat — nimic de facut)
$existing = Get-Command mkvmerge -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "mkvmerge e deja disponibil in PATH:" -ForegroundColor Green
    Write-Host "  $($existing.Source)"
    & $existing.Source --version 2>&1 | Select-Object -First 1 | ForEach-Object { Write-Host "  $_" }
    Write-Host "  Suita il va folosi automat (AV_TOOL_MKVMERGE)."
    if (-not $env:AV_NONINTERACTIVE) { Read-Host "`nApasa Enter pentru a iesi" }
    exit 0
}

# 1. Versiunea (param sau descoperita din pagina oficiala)
if (-not $Version) {
    Write-Host "[1/4] Determin ultima versiune de pe mkvtoolnix.download..." -ForegroundColor Yellow
    try {
        $page = Invoke-WebRequest -Uri "https://mkvtoolnix.download/downloads.html" -UseBasicParsing
        $m = [regex]::Match($page.Content, 'releases/(\d+(?:\.\d+)*)/mkvtoolnix-64-bit-')
        if ($m.Success) { $Version = $m.Groups[1].Value }
    } catch { }
    if (-not $Version) {
        Write-Host "[!] Nu am putut determina versiunea automat." -ForegroundColor Red
        Write-Host "    Reia cu versiunea explicita, ex:"
        Write-Host "      .\mkvmerge_installer.ps1 -Version 99.0"
        Write-Host "    (numarul curent e pe https://mkvtoolnix.download/downloads.html)"
        if (-not $env:AV_NONINTERACTIVE) { Read-Host "`nApasa Enter pentru a iesi" }
        exit 1
    }
}
Write-Host "      Versiune: $Version" -ForegroundColor Green

# Deja instalata aceeasi versiune in tools/?
if ((Test-Path $Target) -and (Test-Path $VersionFile) -and ((Get-Content $VersionFile -Raw).Trim() -eq $Version)) {
    Write-Host "      Versiunea $Version e deja instalata in tools/." -ForegroundColor Green
    if (-not $env:AV_NONINTERACTIVE) { Read-Host "`nApasa Enter pentru a iesi" }
    exit 0
}

$Url        = "https://mkvtoolnix.download/windows/releases/$Version/mkvtoolnix-64-bit-$Version.7z"
$Tmp7z      = Join-Path $env:TEMP "mkvtoolnix-64-bit-$Version.7z"
$TmpExtract = Join-Path $env:TEMP "mkvtoolnix_extract_$Version"

# 2. Download
Write-Host "[2/4] Descarc pachetul portabil (.7z)..." -ForegroundColor Yellow
try {
    Invoke-WebRequest -Uri $Url -OutFile $Tmp7z
} catch {
    Write-Host "[!] Download esuat: $Url" -ForegroundColor Red
    Write-Host "    Alternative:"
    Write-Host "      - winget install MoritzBunkus.MKVToolNix"
    Write-Host "      - descarca manual de pe https://mkvtoolnix.download/downloads.html"
    if (-not $env:AV_NONINTERACTIVE) { Read-Host "`nApasa Enter pentru a iesi" }
    exit 1
}

# 3. Extragere — tar.exe (libarchive, citeste 7z pe Win10+), fallback 7-Zip
Write-Host "[3/4] Extragere arhiva (.7z)..." -ForegroundColor Yellow
if (Test-Path $TmpExtract) { Remove-Item $TmpExtract -Recurse -Force }
New-Item -ItemType Directory -Force -Path $TmpExtract | Out-Null
$extracted = $false
$tar = Get-Command tar -ErrorAction SilentlyContinue
if ($tar) {
    & $tar.Source -xf $Tmp7z -C $TmpExtract 2>$null
    if ($LASTEXITCODE -eq 0) { $extracted = $true }
}
if (-not $extracted) {
    $sevenZip = $null
    $cmd7z = Get-Command 7z -ErrorAction SilentlyContinue
    if ($cmd7z) { $sevenZip = $cmd7z.Source }
    elseif (Test-Path "$env:ProgramFiles\7-Zip\7z.exe") { $sevenZip = "$env:ProgramFiles\7-Zip\7z.exe" }
    if ($sevenZip) {
        & $sevenZip x $Tmp7z "-o$TmpExtract" -y | Out-Null
        if ($LASTEXITCODE -eq 0) { $extracted = $true }
    }
}
if (-not $extracted) {
    Write-Host "[!] Nu am putut extrage .7z (tar/7-Zip indisponibile sau au esuat)." -ForegroundColor Red
    Write-Host "    Optiuni:"
    Write-Host "      - winget install MoritzBunkus.MKVToolNix"
    Write-Host "      - extrage manual $Tmp7z si copiaza mkvmerge.exe in:"
    Write-Host "          $InstallDir"
    if (-not $env:AV_NONINTERACTIVE) { Read-Host "`nApasa Enter pentru a iesi" }
    exit 1
}

# 4. Copiaza DOAR mkvmerge.exe (link static → self-contained, fara DLL-uri)
Write-Host "[4/4] Instalare mkvmerge.exe in tools/..." -ForegroundColor Yellow
$found = Get-ChildItem -Path $TmpExtract -Filter "mkvmerge.exe" -Recurse | Select-Object -First 1
if ($found) {
    Copy-Item -Path $found.FullName -Destination $Target -Force
    Set-Content -Path $VersionFile -Value $Version -Encoding ASCII
    Write-Host ""
    Write-Host "INSTALARE REUSITA! mkvmerge $Version" -ForegroundColor Green
    Write-Host "  $Target"
    & $Target --version 2>&1 | Select-Object -First 1 | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
    Write-Host "Suita va scrie acum dvcC de container pe hibridele HEVC DV care merg in MKV."
    Write-Host "Adauga tools/ in PATH, sau seteaza AV_TOOL_MKVMERGE la calea de mai sus."
} else {
    Write-Host "[!] mkvmerge.exe nu a fost gasit in arhiva." -ForegroundColor Red
}

# Curatenie
if (Test-Path $Tmp7z) { Remove-Item $Tmp7z -Force }
if (Test-Path $TmpExtract) { Remove-Item $TmpExtract -Recurse -Force }

if (-not $env:AV_NONINTERACTIVE) { Read-Host "`nApasa Enter pentru a iesi" }
