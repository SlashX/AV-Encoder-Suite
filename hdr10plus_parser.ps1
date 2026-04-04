<#
.SYNOPSIS
    Installer & Updater pentru hdr10plus_tool pe Windows.
.DESCRIPTION
    Descarca automat ultima versiune pre-compilata a utilitarului quietvoid/hdr10plus_tool
    de pe GitHub, o extrage si o pregateste pentru suita de encodare video.
    Folosit de av_encode.ps1 pentru extragerea si injectarea metadatelor HDR10+.
#>

$ErrorActionPreference = "Stop"

# Unde instalam executabilul (in acelasi folder cu scriptul)
$InstallDir = $PSScriptRoot
$ExeName = "hdr10plus_tool.exe"
$TargetPath = Join-Path $InstallDir $ExeName

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║    HDR10+ TOOL INSTALLER (Windows)           ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# 1. Cautam ultima versiune pe GitHub API
Write-Host "[1/4] Interogare GitHub pentru ultima versiune..." -ForegroundColor Yellow
$ApiUrl = "https://api.github.com/repos/quietvoid/hdr10plus_tool/releases/latest"
try {
    $ReleaseInfo = Invoke-RestMethod -Uri $ApiUrl -Method Get
    $Version = $ReleaseInfo.tag_name
    Write-Host "      Versiune gasita: $Version" -ForegroundColor Green
} catch {
    Write-Host "[!] Eroare la conectarea cu GitHub API." -ForegroundColor Red
    Read-Host "Apasa Enter pentru a iesi"
    exit
}

# 2. Gasim arhiva corecta pentru Windows (x86_64 msvc)
$WindowsAsset = $ReleaseInfo.assets | Where-Object { $_.name -match "windows-msvc.zip" }
if (-not $WindowsAsset) {
    Write-Host "[!] Nu s-a gasit arhiva pentru Windows in acest release." -ForegroundColor Red
    Read-Host "Apasa Enter pentru a iesi"
    exit
}

$DownloadUrl = $WindowsAsset.browser_download_url
$ZipName = $WindowsAsset.name
$TempZipPath = Join-Path $env:TEMP $ZipName
$TempExtractPath = Join-Path $env:TEMP "hdr10plus_temp_extract"

# 3. Verificare daca versiunea curenta e deja instalata
if (Test-Path $TargetPath) {
    $currentVer = & $TargetPath --version 2>&1 | Out-String
    if ($currentVer -match [regex]::Escape($Version.TrimStart("v"))) {
        Write-Host "      Versiunea $Version este deja instalata." -ForegroundColor Green
        & $TargetPath --version
        Read-Host "`nApasa Enter pentru a iesi"
        exit
    }
    Write-Host "      Versiune noua disponibila. Actualizez..." -ForegroundColor Yellow
}

# 4. Descarcarea arhivei
Write-Host "[2/4] Descarc $ZipName..." -ForegroundColor Yellow
Invoke-WebRequest -Uri $DownloadUrl -OutFile $TempZipPath

# 5. Extragerea si mutarea executabilului
Write-Host "[3/4] Extragere arhiva..." -ForegroundColor Yellow
if (Test-Path $TempExtractPath) { Remove-Item $TempExtractPath -Recurse -Force }
Expand-Archive -Path $TempZipPath -DestinationPath $TempExtractPath -Force

# Cautam executabilul in fisierele extrase
$ExtractedExe = Get-ChildItem -Path $TempExtractPath -Filter "hdr10plus_tool.exe" -Recurse | Select-Object -First 1

if ($ExtractedExe) {
    Write-Host "[4/4] Instalare executabil in folderul proiectului..." -ForegroundColor Yellow
    Copy-Item -Path $ExtractedExe.FullName -Destination $TargetPath -Force

    Write-Host ""
    Write-Host "INSTALARE REUSITA!" -ForegroundColor Green
    Write-Host "Binar disponibil: $TargetPath"
    & $TargetPath --version
    Write-Host ""
    Write-Host "Acum poti folosi optiunea HDR10+ Metadata Preserve in av_encode.ps1."
} else {
    Write-Host ""
    Write-Host "EROARE: Nu am gasit hdr10plus_tool.exe in arhiva." -ForegroundColor Red
}

# Curatenie
if (Test-Path $TempZipPath) { Remove-Item $TempZipPath -Force }
if (Test-Path $TempExtractPath) { Remove-Item $TempExtractPath -Recurse -Force }

Read-Host "`nApasa Enter pentru a iesi"
