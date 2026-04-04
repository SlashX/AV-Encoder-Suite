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

# ── Descarca exiftool.exe ──────────────────────────────────────
$DownloadUrl = "https://exiftool.org/exiftool-${LatestVer}_64.exe"
$TempFile    = "$env:TEMP\exiftool_new.exe"
$InstallDir  = Split-Path -Parent ($ExifToolPath ?? "$PSScriptRoot\exiftool.exe")
$InstallPath = Join-Path $InstallDir "exiftool.exe"

Write-Host "  Descarcare exiftool-${LatestVer}_64.exe..."
try {
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $TempFile -UseBasicParsing
} catch {
    # Fallback la varianta fara _64
    $DownloadUrl = "https://exiftool.org/exiftool-${LatestVer}.exe"
    Write-Host "  Retry cu $DownloadUrl..."
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $TempFile -UseBasicParsing
}

# ── Instaleaza ─────────────────────────────────────────────────
Write-Host "  Instalare in $InstallPath..."
Copy-Item $TempFile $InstallPath -Force
Remove-Item $TempFile -Force

Write-Host ""
Write-Host "  ✓ ExifTool actualizat la versiunea $LatestVer" -ForegroundColor Green

# ── Verificare finala ──────────────────────────────────────────
Write-Host ""
Write-Host "  Verificare finala:"
$NewVer = (& $InstallPath -ver 2>$null).Trim()
Write-Host "  ExifTool $NewVer instalat cu succes." -ForegroundColor Green
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
pause
