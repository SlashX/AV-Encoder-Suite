<#
.SYNOPSIS
    Installer pentru Cavernize (Cavern) pe Windows — render Dolby Atmos →
    canale 7.1.4 pentru conversia in Eclipsa Audio / IAMF (v89).
.DESCRIPTION
    Cavern (VoidXH) e singurul renderer LIBER care decodeaza obiectele Atmos
    (E-AC-3 JOC nativ; TrueHD prin truehdd, pe care Cavernize il descarca
    singur la prima rulare) si le reda pozitional in canale 7.1.4. Suita il
    foloseste in meniul audio-only opt 10 (Eclipsa/IAMF): sursa Atmos →
    render WAV 7.1.4 → authoring IAMF cu canale de inaltime REALE.
    OPTIONAL: cand Cavernize lipseste, suita ofera onest doar bed-ul (v88).

    CavernizeGUI.exe E CLI-ul (console-mode cand primeste argumente) si NU e
    un singur exe (are nevoie de DLL-urile Cavern.* de langa el) → pachetul
    portabil se dezarhiveaza INTREG in tools/cavernize/. Cere .NET Desktop
    Runtime 8+ (pe 9/10 suita seteaza automat DOTNET_ROLL_FORWARD=LatestMajor)
    si ffmpeg in PATH (Cavernize il foloseste la extractie/decodare).
    Numele binarului e overridable prin env AV_TOOL_CAVERNIZE.
#>

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   CAVERNIZE (Cavern) INSTALLER (Win) — v89   ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# 0. Deja disponibil? (PATH sau env AV_TOOL_CAVERNIZE — suita il gaseste automat)
$cavName = if ($env:AV_TOOL_CAVERNIZE) { $env:AV_TOOL_CAVERNIZE } else { "CavernizeGUI" }
$existing = Get-Command $cavName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Cavernize e deja disponibil:" -ForegroundColor Green
    Write-Host "  $($existing.Source)"
    Write-Host "  Suita il va folosi automat (AV_TOOL_CAVERNIZE)."
    if (-not $env:AV_NONINTERACTIVE) { Read-Host "`nApasa Enter pentru a iesi" }
    exit 0
}

# 1. Check .NET Desktop Runtime 8+ (Cavernize tinteste .NET Desktop 8;
#    pe 9/10 suita seteaza automat DOTNET_ROLL_FORWARD=LatestMajor la rulare)
Write-Host "[1/4] Verific .NET Desktop Runtime..." -ForegroundColor Yellow
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
$hasDesktop = $false
if ($dotnet) {
    $runtimes = & $dotnet --list-runtimes 2>$null
    $hasDesktop = [bool]($runtimes | Where-Object { $_ -match 'Microsoft\.WindowsDesktop\.App ([89]|[1-9][0-9])\.' })
}
if (-not $hasDesktop) {
    Write-Host "[!] .NET Desktop Runtime 8+ nu e instalat." -ForegroundColor Red
    Write-Host "    Instaleaza-l intai (Cavernize nu porneste fara el):"
    Write-Host "      winget install Microsoft.DotNet.DesktopRuntime.8"
    Write-Host "      sau https://dotnet.microsoft.com/download/dotnet/8.0 (Desktop Runtime)"
    if (-not $env:AV_NONINTERACTIVE) { Read-Host "`nApasa Enter pentru a iesi" }
    exit 1
}
Write-Host "  .NET Desktop Runtime OK." -ForegroundColor Green

# 2. Download pachetul portabil de pe site-ul oficial (GitHub are doar demo-ul
#    Unity pe Windows; zip-ul CLI/GUI portabil sta pe cavern.sbence.hu, via redirect)
$Url        = "https://cavern.sbence.hu/content/downloads/cavernize_gui.zip"
$TmpZip     = Join-Path $env:TEMP "cavernize_gui.zip"
$InstallDir = Join-Path $PSScriptRoot "cavernize"
Write-Host "[2/4] Descarc Cavernize portabil (site oficial)..." -ForegroundColor Yellow
try {
    Invoke-WebRequest -Uri $Url -OutFile $TmpZip -UseBasicParsing
} catch {
    Write-Host "[!] Download esuat: $Url" -ForegroundColor Red
    Write-Host "    Descarca manual de pe https://cavern.sbence.hu/cavern/downloads.php"
    Write-Host "    (Cavernize portable), dezarhiveaza undeva si seteaza:"
    Write-Host '      $env:AV_TOOL_CAVERNIZE = "D:\cale\catre\CavernizeGUI.exe"'
    if (-not $env:AV_NONINTERACTIVE) { Read-Host "`nApasa Enter pentru a iesi" }
    exit 1
}

# 3. Extract INTREG in tools/cavernize/ (CavernizeGUI.exe cere DLL-urile Cavern.* de langa el)
Write-Host "[3/4] Extragere in $InstallDir ..." -ForegroundColor Yellow
if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force }
Expand-Archive -Path $TmpZip -DestinationPath $InstallDir -Force
Remove-Item $TmpZip -Force -ErrorAction SilentlyContinue

# 4. Verificare + ghidare
$exe = Get-ChildItem -Path $InstallDir -Filter "CavernizeGUI.exe" -Recurse | Select-Object -First 1
if ($exe) {
    Write-Host "[4/4] Verificare..." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "INSTALARE REUSITA!" -ForegroundColor Green
    Write-Host "  $($exe.FullName)"
    Write-Host ""
    if ($exe.FullName -ieq (Join-Path $PSScriptRoot "cavernize\CavernizeGUI.exe")) {
        Write-Host "Suita il gaseste AUTOMAT de aici (co-locat in tools\cavernize — fara env, fara PATH; v93)."
    } else {
        Write-Host "Ca suita sa-l gaseasca, seteaza (sau adauga folderul in PATH):"
        Write-Host "  `$env:AV_TOOL_CAVERNIZE = `"$($exe.FullName)`""
    }
    Write-Host ""
    Write-Host "Note:" -ForegroundColor Yellow
    Write-Host "  - Cavernize cere ffmpeg in PATH (suita il are deja daca encodezi)."
    Write-Host "  - Pe surse TrueHD Atmos, Cavernize descarca singur truehdd la prima rulare."
    Write-Host "  - Meniul 2 opt 10 (Eclipsa/IAMF) va oferi acum 'Render 7.1.4' pe surse Atmos."
} else {
    Write-Host "[!] CavernizeGUI.exe nu a fost gasit in arhiva." -ForegroundColor Red
    Write-Host "    Descarca manual de pe https://cavern.sbence.hu/cavern/downloads.php si seteaza AV_TOOL_CAVERNIZE."
    if (-not $env:AV_NONINTERACTIVE) { Read-Host "`nApasa Enter pentru a iesi" }
    exit 1
}
if (-not $env:AV_NONINTERACTIVE) { Read-Host "`nApasa Enter pentru a iesi" }
exit 0
