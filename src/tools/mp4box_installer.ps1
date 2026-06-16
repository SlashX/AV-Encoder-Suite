<#
.SYNOPSIS
    Installer pentru MP4Box (GPAC) pe Windows — semnalizare dvcC de container
    pe hibridele HEVC Dolby Vision care merg in MP4/MOV (v71).
.DESCRIPTION
    MP4Box auto-detecteaza RPU-ul din bitstream-ul HEVC brut si scrie box-ul
    dvcC (DOVI configuration record) in MP4/MOV → TV-urile activeaza Dolby
    Vision. ffmpeg NU poate scrie dvcC din RPU brut (calea de azi lasa DV doar
    in bitstream, dormant pe TV). Echivalentul MP4/MOV al mkvmerge (MKV, v70).
    OPTIONAL: cand MP4Box lipseste, suita cade tacut pe ffmpeg direct.

    GPAC NU e un singur exe (MP4Box are nevoie de libgpac.dll + DLL-urile av*),
    deci NU se copiaza un singur fisier ca mkvmerge. Acest installer instaleaza
    GPAC complet prin winget (recomandat) — adauga MP4Box in PATH. Daca winget
    lipseste, da instructiuni: descarca de pe gpac.io SAU pune folderul portabil
    GPAC undeva si seteaza env AV_TOOL_MP4BOX la calea catre mp4box.exe.
    Numele binarului e overridable prin env AV_TOOL_MP4BOX.
#>

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   MP4BOX (GPAC) INSTALLER (Windows) — v71    ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# 0. Deja in PATH? (suita il gaseste automat — nimic de facut)
$existing = Get-Command mp4box -ErrorAction SilentlyContinue
if (-not $existing) { $existing = Get-Command MP4Box -ErrorAction SilentlyContinue }
if ($existing) {
    Write-Host "MP4Box e deja disponibil in PATH:" -ForegroundColor Green
    Write-Host "  $($existing.Source)"
    & $existing.Source -version 2>&1 | Select-Object -First 1 | ForEach-Object { Write-Host "  $_" }
    Write-Host "  Suita il va folosi automat (AV_TOOL_MP4BOX)."
    if (-not $env:AV_NONINTERACTIVE) { Read-Host "`nApasa Enter pentru a iesi" }
    exit 0
}

# 1. winget (recomandat — instaleaza GPAC complet + adauga in PATH)
$winget = Get-Command winget -ErrorAction SilentlyContinue
if ($winget) {
    Write-Host "[1/1] Instalez GPAC prin winget..." -ForegroundColor Yellow
    & winget install --id GPAC.GPAC --accept-package-agreements --accept-source-agreements
    $now = Get-Command mp4box -ErrorAction SilentlyContinue
    if (-not $now) { $now = Get-Command MP4Box -ErrorAction SilentlyContinue }
    if ($now) {
        Write-Host ""
        Write-Host "INSTALARE REUSITA!" -ForegroundColor Green
        Write-Host "  $($now.Source)"
        Write-Host "Suita va scrie acum dvcC pe hibridele HEVC DV care merg in MP4/MOV."
        Write-Host "(Daca MP4Box nu e gasit imediat, redeschide terminalul ca PATH-ul sa se actualizeze.)"
    } else {
        Write-Host ""
        Write-Host "GPAC instalat, dar MP4Box nu e inca in PATH." -ForegroundColor Yellow
        Write-Host "Redeschide terminalul, sau seteaza:"
        Write-Host '  $env:AV_TOOL_MP4BOX = "C:\Program Files\GPAC\mp4box.exe"'
    }
    if (-not $env:AV_NONINTERACTIVE) { Read-Host "`nApasa Enter pentru a iesi" }
    exit 0
}

# 2. winget lipseste → ghidare manuala
Write-Host "[!] winget nu e disponibil pe acest sistem." -ForegroundColor Red
Write-Host ""
Write-Host "Optiuni manuale:" -ForegroundColor Yellow
Write-Host "  1) Descarca GPAC de pe https://gpac.io/downloads/gpac-nightly-builds/"
Write-Host "     (sau release-ul stabil) si ruleaza installer-ul Windows."
Write-Host "  2) SAU descarca pachetul portabil, dezarhiveaza-l undeva (pastreaza"
Write-Host "     TOATE DLL-urile langa mp4box.exe — nu e standalone), apoi seteaza:"
Write-Host '       $env:AV_TOOL_MP4BOX = "D:\cale\catre\GPAC\mp4box.exe"'
Write-Host ""
Write-Host "Dupa instalare, suita scrie automat dvcC pe hibridele HEVC DV → MP4/MOV."
if (-not $env:AV_NONINTERACTIVE) { Read-Host "`nApasa Enter pentru a iesi" }
exit 1
