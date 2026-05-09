<#
.SYNOPSIS
    Installer & Updater pentru av1hdr10plus_tool pe Windows (sven-pke fork).
.DESCRIPTION
    Cloneaza si compileaza sven-pke/hdr10plus_tool (fork al
    quietvoid/hdr10plus_tool cu suport AV1 OBU_METADATA T.35). Folosit de
    av_encode.ps1 pentru extragere/injectare metadata HDR10+ in fluxuri AV1.

    Binarul se instaleaza ca av1hdr10plus_tool.exe (rename pentru a evita
    coliziunea cu hdr10plus_tool.exe upstream, care ramane HEVC-only).

    Note: fork-ul nu are GitHub releases — build din sursa cu cargo obligatoriu.
    Cere Rust toolchain (rustup recomandat) si Git.
#>

$ErrorActionPreference = "Stop"

$RepoUrl     = "https://github.com/sven-pke/hdr10plus_tool.git"
$InstallRoot = Join-Path $env:USERPROFILE "av1hdr10plus_tool"
$SrcBinName  = "hdr10plus_tool.exe"
$DestBinName = "av1hdr10plus_tool.exe"
$TargetPath  = Join-Path $PSScriptRoot $DestBinName

Write-Host ""
Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║ AV1 HDR10+ TOOL INSTALLER (sven-pke fork)    ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "  Repo:    $RepoUrl"
Write-Host "  Build:   $InstallRoot"
Write-Host "  Binar:   $TargetPath (rename din $SrcBinName)"
Write-Host ""

# 1. Verificare dependente
Write-Host "[1/4] Verificare dependente (cargo + git)..." -ForegroundColor Yellow
$CargoCmd = Get-Command "cargo" -ErrorAction SilentlyContinue
$GitCmd   = Get-Command "git"   -ErrorAction SilentlyContinue

if (-not $CargoCmd) {
    Write-Host "[!] EROARE: cargo (Rust toolchain) negasit." -ForegroundColor Red
    Write-Host "    Instaleaza prin rustup:" -ForegroundColor Yellow
    Write-Host "      https://rustup.rs/" -ForegroundColor Yellow
    Write-Host "    Sau cu winget:" -ForegroundColor Yellow
    Write-Host "      winget install Rustlang.Rustup" -ForegroundColor Yellow
    Read-Host "`nApasa Enter pentru a iesi"
    exit 1
}
if (-not $GitCmd) {
    Write-Host "[!] EROARE: git negasit." -ForegroundColor Red
    Write-Host "    Instaleaza Git for Windows: https://git-scm.com/download/win" -ForegroundColor Yellow
    Read-Host "`nApasa Enter pentru a iesi"
    exit 1
}
Write-Host "      cargo: $($CargoCmd.Source)" -ForegroundColor Green
Write-Host "      git:   $($GitCmd.Source)" -ForegroundColor Green

# 2. Clone sau Update
if (-not (Test-Path -LiteralPath $InstallRoot)) {
    Write-Host ""
    Write-Host "[2/4] Clone sursa de pe GitHub (sven-pke fork)..." -ForegroundColor Yellow
    & git clone $RepoUrl $InstallRoot
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[!] git clone esuat." -ForegroundColor Red
        Read-Host "`nApasa Enter pentru a iesi"
        exit 1
    }
} else {
    Write-Host ""
    Write-Host "[2/4] Director existent. Verific update-uri..." -ForegroundColor Yellow
    Push-Location $InstallRoot
    try {
        & git fetch | Out-Null
        $local  = (& git rev-parse HEAD).Trim()
        $remote = (& git rev-parse '@{u}' 2>$null)
        if ($remote) { $remote = $remote.Trim() }
        if ($local -eq $remote) {
            Write-Host "      [OK] Sursa este la zi." -ForegroundColor Green
            if (Test-Path -LiteralPath $TargetPath) {
                Write-Host "      Binarul este deja instalat. Nimic de facut." -ForegroundColor Green
                & $TargetPath --version
                Pop-Location
                Read-Host "`nApasa Enter pentru a iesi"
                exit 0
            }
        } else {
            Write-Host "      Update gasit. Descarc..." -ForegroundColor Yellow
            & git pull
        }
    } finally {
        Pop-Location
    }
}

# 3. Compilare
Write-Host ""
Write-Host "[3/4] Compilare cu cargo build --release (poate dura)..." -ForegroundColor Yellow
Push-Location $InstallRoot
try {
    & cargo build --release
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[!] cargo build esuat." -ForegroundColor Red
        Pop-Location
        Read-Host "`nApasa Enter pentru a iesi"
        exit 1
    }
} finally {
    Pop-Location
}

# 4. Instalare (cu rename)
$BuiltExe = Join-Path $InstallRoot "target\release\$SrcBinName"
if (Test-Path -LiteralPath $BuiltExe) {
    Write-Host ""
    Write-Host "[4/4] Instalez binarul (rename $SrcBinName -> $DestBinName)..." -ForegroundColor Yellow
    Copy-Item -LiteralPath $BuiltExe -Destination $TargetPath -Force

    Write-Host ""
    Write-Host "INSTALARE REUSITA!" -ForegroundColor Green
    Write-Host "Binar disponibil: $TargetPath"
    & $TargetPath --version
    Write-Host ""
    Write-Host "Acum poti folosi optiunile HDR10+ pentru AV1 in av_encode.ps1." -ForegroundColor Green
    Write-Host "Note: hdr10plus_tool.exe upstream (HEVC) ramane neatins."
} else {
    Write-Host ""
    Write-Host "EROARE: $SrcBinName nu a fost gasit dupa compilare." -ForegroundColor Red
    Write-Host "Cale asteptata: $BuiltExe"
}

Read-Host "`nApasa Enter pentru a iesi"
