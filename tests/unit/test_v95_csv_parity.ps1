# v95 (P3) — CSV-ul din av_check trebuie sa iasa IDENTIC pe bash si pe PowerShell.
#
# Divergenta reparata avea o singura cauza de fond: bash formateaza ca SIR, cu `printf`/`awk`
# si zecimale fixe; PowerShell calcula ca NUMAR, cu `Round`, si lasa .NET sa-l afiseze. De aici
# trei familii de diferente, pe 9 coloane:
#   trunchiere vs rotunjire   Dimensiune(MB) `150`/`150.3` · Durata(sec) `29`/`30` · toate Est_*
#   zecimala fixa vs numar    SampleRate `48.0`/`48` · Bitrate `43.20`/`43.2` · MinLum `0.0050`/`0.005`
#   separator dependent de MASINA  Est_ProRes `~1.2 GB` vs `~1,2 GB` pe ro-RO / de-DE
#
# A treia era calitativ diferita: `-f "{0:F1}"` foloseste cultura curenta, deci continutul
# CSV-ului depindea de setarile regionale ale calculatorului, nu doar de platforma. Aceeasi
# clasa cu P1 din v94 (coloana FPS).
#
# Santinela pazeste CONTRACTELE de formatare, nu valorile: orice revenire la `Round(...)` fara
# `.ToString(...)` sau la un format dependent de cultura reintroduce divergenta.
. "$PSScriptRoot\..\framework.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$CHK  = Get-Content (Join-Path $ROOT 'src\av_check.ps1') -Raw

# ── 1. Trunchiere, nu rotunjire (paritate cu aritmetica intreaga din bash) ──
Assert-Eq $true ($CHK -match '\$fsMB\s*=\s*\[long\]\[math\]::Floor') `
    "Dimensiune(MB): trunchiere, ca `$((FILE_SIZE/1024/1024)) din bash"
Assert-Eq $true ($CHK -match '\$durSec\s*=.*\[int\]\[math\]::Floor') `
    "Durata(sec): trunchiere, ca `${DURATION%.*} din bash"
Assert-Eq $true ($CHK -match '\$mb\s*=\s*\[long\]\[math\]::Floor') `
    "Get-SizeEst: trunchiere, ca aritmetica intreaga din bash"

# ── 2. Zecimale FIXE, ca `printf` din bash ──────────────────────────
Assert-Eq $true ($CHK -match '\$audioSRk\s*=.*ToString\("0\.0"') "SampleRate: o zecimala fixa (48.0, nu 48)"
Assert-Eq $true ($CHK -match '\$bitrateMbps\s*=.*ToString\("0\.00"')  "Bitrate: doua zecimale fixe (43.20, nu 43.2)"
Assert-Eq $true ($CHK -match '\$lMinStr\s*=.*ToString\("0\.0000"')    "MinLum: patru zecimale fixe (0.0050, nu 0.005)"

# ── 3. Zero formatare dependenta de cultura in campurile numerice ────
# `-f "{0:F1}"` / `"{0:F2}"` folosesc cultura curenta → pe ro-RO produc virgula.
foreach ($m in [regex]::Matches($CHK, '(?m)^.*\{0:F\d\}.*$')) {
    $line = $m.Value
    # Format-Bytes e DOAR pentru afisaj pe ecran, nu intra in CSV
    if ($line -match 'GB" -f \(\$b/1GB\)|MB" -f \(\$b/1MB\)|KB" -f \(\$b/1KB\)') { continue }
    _fail "formatare dependenta de cultura intr-un camp de CSV: $($line.Trim())"
}
_pass

# ── 4. Fiecare `.ToString(` numeric are cultura EXPLICITA ────────────
# (fara ea, .NET foloseste cultura masinii — exact bug-ul de la Est_ProRes)
$bad = @()
foreach ($m in [regex]::Matches($CHK, '\.ToString\("[0-9.#,]+"\s*(,[^)]*)?\)')) {
    if ($m.Value -notmatch 'InvariantCulture|\$inv') { $bad += $m.Value }
}
if ($bad.Count -gt 0) { Write-Host ("  " + ($bad -join ' | ')) -ForegroundColor Yellow }
Assert-Eq 0 $bad.Count "toate formatarile numerice folosesc InvariantCulture ($($bad -join ', '))"

# ── 5. Contractele din bash raman cele de referinta ──────────────────
$SH = Get-Content (Join-Path $ROOT 'src\av_check.sh') -Raw
Assert-Eq $true ($SH -match '\$\(\(FILE_SIZE/1024/1024\)\)')       "bash: Dimensiune ramane impartire intreaga"
Assert-Eq $true ($SH -match 'DURATION_INT=\$\{DURATION%\.\*\}')    "bash: Durata ramane trunchiata"
Assert-Eq $true ($SH -match 'printf \\"%\.1f\\", \$AUDIO_SAMPLERATE/1000') "bash: SampleRate ramane %.1f"
Assert-Eq $true ($SH -match 'printf \\"%\.2f\\", \$BITRATE/1000000') "bash: Bitrate ramane %.2f"
Assert-Eq $true ($SH -match 'printf "%\.4f",\$2/\$3')              "bash: MinLum ramane %.4f"

Invoke-TestSummary
