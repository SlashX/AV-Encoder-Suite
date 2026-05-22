# ═══════════════════════════════════════════════════════════════
#  exiftool_update.ps1 — ExifTool smart updater pentru Windows
#  Verifica versiunea curenta vs ultima de pe exiftool.org
#  Daca e versiune noua → descarca si instaleaza .exe
# ═══════════════════════════════════════════════════════════════

Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  ExifTool Smart Updater — Windows" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# ── Detecteaza locatia exiftool ────────────────────────────────
$ExifToolPath = (Get-Command exiftool -ErrorAction SilentlyContinue)?.Source
if (-not $ExifToolPath) {
    # Cauta langa script
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    if (Test-Path "$ScriptDir\exiftool.exe") {
        $ExifToolPath = "$ScriptDir\exiftool.exe"
    }
}

# ── Versiune curenta ───────────────────────────────────────────
if ($ExifToolPath) {
    $CurrentVer = (& exiftool -ver 2>$null).Trim()
    Write-Host "  Versiune instalata:  $CurrentVer" -ForegroundColor White
    Write-Host "  Locatie:             $ExifToolPath" -ForegroundColor Gray
} else {
    $CurrentVer = "0"
    Write-Host "  ExifTool nu este instalat." -ForegroundColor Yellow
}

# ── Ultima versiune de pe exiftool.org ─────────────────────────
Write-Host "  Verificare exiftool.org..."
try {
    $LatestVer = (Invoke-WebRequest -Uri "https://exiftool.org/ver.txt" -UseBasicParsing).Content.Trim()
} catch {
    Write-Host "  EROARE: Nu pot contacta exiftool.org. Verifica conexiunea." -ForegroundColor Red
    exit 1
}
Write-Host "  Ultima versiune:     $LatestVer" -ForegroundColor White
Write-Host ""

# ── Deja la zi ─────────────────────────────────────────────────
if ($CurrentVer -eq $LatestVer) {
    Write-Host "  ✓ ExifTool este deja la ultima versiune ($LatestVer)." -ForegroundColor Green
    Write-Host ""
    pause
    exit 0
}

Write-Host "  Update disponibil: $CurrentVer → $LatestVer" -ForegroundColor Yellow
Write-Host ""

# ── Descarca exiftool ZIP (Phil Harvey distribute ZIP, nu .exe single-file) ──
# v52 fix: exiftool.org nu mai distribuie single-file .exe (URL-ul .exe da 404).
# Noua distributie e ZIP cu folder `exiftool-X.YY_64/` ce contine
# `exiftool(-k).exe` (wrapper mic) + folder `exiftool_files/` (~32MB Perl runtime
# + module — mandatory pentru rulare). Installer: download zip, extract,
# rename `exiftool(-k).exe` → `exiftool.exe`, instaleaza ambele in $InstallDir.
$DownloadUrl = "https://exiftool.org/exiftool-${LatestVer}_64.zip"
$TempZip     = Join-Path $env:TEMP "exiftool_new.zip"
$TempExtract = Join-Path $env:TEMP "exiftool_new_extract"
$InstallDir  = Split-Path -Parent ($ExifToolPath ?? "$PSScriptRoot\exiftool.exe")
$InstallPath = Join-Path $InstallDir "exiftool.exe"
$InstallFilesDir = Join-Path $InstallDir "exiftool_files"

Write-Host "  Descarcare exiftool-${LatestVer}_64.zip..."
try {
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $TempZip -UseBasicParsing
} catch {
    Write-Host "  EROARE descarcare ZIP: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Verifica conexiunea sau URL pattern: $DownloadUrl" -ForegroundColor Yellow
    pause; exit 1
}

# ── Extract ZIP ────────────────────────────────────────────────
Write-Host "  Extragere arhiva..."
if (Test-Path $TempExtract) { Remove-Item $TempExtract -Recurse -Force }
Expand-Archive -Path $TempZip -DestinationPath $TempExtract -Force

# ZIP contine folder de tipul `exiftool-13.58_64/` cu binarul si exiftool_files/
$ExtractRoot = Get-ChildItem $TempExtract -Directory | Select-Object -First 1
if (-not $ExtractRoot) {
    Write-Host "  EROARE: ZIP-ul nu contine folder asteptat." -ForegroundColor Red
    pause; exit 1
}
# exiftool(-k).exe — wrapper mic; redenumim la exiftool.exe
$ExtractedExe = Join-Path $ExtractRoot.FullName "exiftool(-k).exe"
$ExtractedFilesDir = Join-Path $ExtractRoot.FullName "exiftool_files"
if (-not (Test-Path $ExtractedExe)) {
    Write-Host "  EROARE: exiftool(-k).exe negasit in arhiva." -ForegroundColor Red
    pause; exit 1
}
if (-not (Test-Path $ExtractedFilesDir)) {
    Write-Host "  EROARE: folder exiftool_files/ negasit in arhiva (mandatory pentru runtime)." -ForegroundColor Red
    pause; exit 1
}

# ── Instaleaza ─────────────────────────────────────────────────
Write-Host "  Instalare:"
Write-Host "    exe       : $InstallPath"
Write-Host "    exiftool_files/ : $InstallFilesDir"
# Cleanup install anterior (poate fi din versiunea veche single-file)
if (Test-Path $InstallFilesDir) { Remove-Item $InstallFilesDir -Recurse -Force }
Copy-Item $ExtractedExe $InstallPath -Force
Copy-Item $ExtractedFilesDir $InstallDir -Recurse -Force

# Cleanup temp
Remove-Item $TempZip -Force -ErrorAction SilentlyContinue
Remove-Item $TempExtract -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "  ✓ ExifTool actualizat la versiunea $LatestVer" -ForegroundColor Green

# ── Verificare finala ──────────────────────────────────────────
Write-Host ""
Write-Host "  Verificare finala:"
$NewVer = (& $InstallPath -ver 2>$null).Trim()
if ($NewVer) {
    Write-Host "  ExifTool $NewVer instalat cu succes." -ForegroundColor Green
} else {
    Write-Host "  AVERTISMENT: exiftool.exe instalat dar -ver nu a returnat output." -ForegroundColor Yellow
    Write-Host "  Verifica manual: $InstallPath -ver" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
pause
