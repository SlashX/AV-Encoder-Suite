<#
.SYNOPSIS
    Installer & Updater pentru validatorul oficial OpenAPV pe Windows.
.DESCRIPTION
    Descarca binarele precompilate oficiale (AcademySoftwareFoundation/openapv):
    oapv_app_dec.exe / oapv_app_enc.exe / liboapv.dll — decoderul si encoderul
    de REFERINTA pentru codecul APV (RFC 9924).
    OPTIONAL: suita functioneaza complet fara el. Cand oapv_app_dec e prezent
    (PATH sau acest folder tools/), verificarea APV HDR10+ post-inject ruleaza
    automat si un decode-check cu implementarea de referinta (plasa de
    siguranta suplimentara); cand lipseste, pasul e sarit tacut.
#>

$ErrorActionPreference = "Stop"

# Instalam in folderul tools/ (acelasi folder cu scriptul) — gasit de
# av_encode.ps1 prin fallback-ul pe $ToolsDir din verificarea APV HDR10+.
$InstallDir  = $PSScriptRoot
$VersionFile = Join-Path $InstallDir "openapv_version.txt"
$Binaries    = @("oapv_app_dec.exe", "oapv_app_enc.exe", "liboapv.dll")

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║    OPENAPV VALIDATOR INSTALLER (Windows)     ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# 1. Ultima versiune pe GitHub API (NU tag hardcodat — tag-urile au sufixe
#    neregulate, ex. v0.2.1.3-fix; API-ul "latest" + asset-urile sunt sursa sigura)
Write-Host "[1/4] Interogare GitHub pentru ultima versiune..." -ForegroundColor Yellow
$ApiUrl = "https://api.github.com/repos/AcademySoftwareFoundation/openapv/releases/latest"
try {
    $ReleaseInfo = Invoke-RestMethod -Uri $ApiUrl -Method Get
    $Version = $ReleaseInfo.tag_name
    Write-Host "      Versiune gasita: $Version" -ForegroundColor Green
} catch {
    Write-Host "[!] Eroare la conectarea cu GitHub API." -ForegroundColor Red
    if (-not $env:AV_NONINTERACTIVE) { Read-Host "Apasa Enter pentru a iesi" }
    exit 1
}

# 2. Arhiva win64 din asset-uri
$WindowsAsset = $ReleaseInfo.assets |
    Where-Object { $_.name -match "win64\.zip$" } |
    Select-Object -First 1
if (-not $WindowsAsset) {
    Write-Host "[!] Nu s-a gasit arhiva win64 in acest release." -ForegroundColor Red
    if (-not $env:AV_NONINTERACTIVE) { Read-Host "Apasa Enter pentru a iesi" }
    exit 1
}
$DownloadUrl = $WindowsAsset.browser_download_url
$ZipName = $WindowsAsset.name
$TempZipPath = Join-Path $env:TEMP $ZipName
$TempExtractPath = Join-Path $env:TEMP "openapv_temp_extract"

# 3. Deja instalata aceeasi versiune? (marker file — binarele nu au --version)
$DecPath = Join-Path $InstallDir "oapv_app_dec.exe"
if ((Test-Path $DecPath) -and (Test-Path $VersionFile)) {
    $currentVer = (Get-Content $VersionFile -Raw).Trim()
    if ($currentVer -eq $Version) {
        Write-Host "      Versiunea $Version este deja instalata." -ForegroundColor Green
        if (-not $env:AV_NONINTERACTIVE) { Read-Host "`nApasa Enter pentru a iesi" }
        exit 0
    }
    Write-Host "      Versiune noua disponibila ($currentVer → $Version). Actualizez..." -ForegroundColor Yellow
}

# 4. Download + extract + instalare
Write-Host "[2/4] Descarc $ZipName..." -ForegroundColor Yellow
Invoke-WebRequest -Uri $DownloadUrl -OutFile $TempZipPath

Write-Host "[3/4] Extragere arhiva..." -ForegroundColor Yellow
if (Test-Path $TempExtractPath) { Remove-Item $TempExtractPath -Recurse -Force }
Expand-Archive -Path $TempZipPath -DestinationPath $TempExtractPath -Force

Write-Host "[4/4] Instalare binare in folderul tools/..." -ForegroundColor Yellow
$installed = 0
foreach ($bin in $Binaries) {
    $found = Get-ChildItem -Path $TempExtractPath -Filter $bin -Recurse | Select-Object -First 1
    if ($found) {
        Copy-Item -Path $found.FullName -Destination (Join-Path $InstallDir $bin) -Force
        $installed++
    } else {
        Write-Host "  [!] $bin nu a fost gasit in arhiva" -ForegroundColor Yellow
    }
}

if ($installed -ge 2 -and (Test-Path $DecPath)) {
    Set-Content -Path $VersionFile -Value $Version -Encoding ASCII
    Write-Host ""
    Write-Host "INSTALARE REUSITA! ($installed/$($Binaries.Count) fisiere)" -ForegroundColor Green
    Write-Host "Binare disponibile in: $InstallDir"
    Write-Host ""
    Write-Host "Verificarea APV HDR10+ din av_encode.ps1 va folosi acum automat"
    Write-Host "decoderul de referinta OpenAPV (decode-check post-inject)."
} else {
    Write-Host ""
    Write-Host "EROARE: Nu am putut instala binarele din arhiva." -ForegroundColor Red
}

# Curatenie
if (Test-Path $TempZipPath) { Remove-Item $TempZipPath -Force }
if (Test-Path $TempExtractPath) { Remove-Item $TempExtractPath -Recurse -Force }

if (-not $env:AV_NONINTERACTIVE) { Read-Host "`nApasa Enter pentru a iesi" }
