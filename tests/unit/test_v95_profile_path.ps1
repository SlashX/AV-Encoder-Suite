# v95 — calea de PROFIL nu are voie sa ocoleasca initializari de care depinde encodarea.
#
# Bug-ul reparat: `av_encode.ps1` are un bloc `if (-not $profLoaded) { ... }` de ~840 de linii
# (toata configurarea interactiva). Cand se incarca un profil, blocul se sare INTEGRAL — dar
# patru variabile calculate acolo se consumau DUPA el, neconditionat:
#   $rtEncoder  → `$tgtCodecMap[$rtEncoder]` arunca „array index evaluated to null" = encode oprit
#   $tuneFlag   → `$null` intra in concatenarea de argumente ca ELEMENT gol → `""` in linia de
#                 comanda → ffmpeg il ia drept fisier de iesire
#   $apvEncoder → numele encoderului APV, gol
#   $pc2        → presetul AV1 (efect benign, dar nu ne bazam pe o ramura de rezerva)
# Niciuna nu se scrie in fisierul de profil, deci NICIUN profil nu le putea furniza: orice
# encode pilotat de profil pe Windows nu producea nimic. Reprodus identic pe v93 si v94, deci
# bug vechi — a scapat fiindca validarea de profile verifica FISIERELE (schema), nu si o
# rulare reala prin calea de profil.
#
# Santinela verifica INVARIANTUL, nu cele 4 nume: nicio variabila calculata exclusiv in blocul
# interactiv si citita dupa el nu are voie sa ramana fara atribuire in afara blocului.
. "$PSScriptRoot\..\framework.ps1"
. "$PSScriptRoot\..\_helpers.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$ENC  = Join-Path $ROOT 'src\av_encode.ps1'
$lines = Get-Content $ENC

# ── 1. Invariantul: zero variabile orfane pe calea de profil ─────────
$st = ($lines | Select-String -SimpleMatch 'if (-not $profLoaded) {' | Select-Object -First 1).LineNumber - 1
Assert-Nonzero ($st + 1) "blocul 'if (-not `$profLoaded)' exista in av_encode.ps1"

$d = 0; $en = $lines.Count - 1
for ($j = $st; $j -lt $lines.Count; $j++) {
    if ($lines[$j].TrimStart().StartsWith('#')) { continue }
    $d += ([regex]::Matches($lines[$j], '\{')).Count - ([regex]::Matches($lines[$j], '\}')).Count
    if ($d -le 0) { $en = $j; break }
}

# `$nume =` oriunde pe linie (nu doar la inceput): fixul foloseste forma inline `{ $x = ... }`
$asgPat  = '(?<![\w$])\$([A-Za-z_][A-Za-z0-9_]*)\s*=(?![=~])'
# NB: functia intoarce un ARRAY, nu un HashSet — PowerShell desface colectiile la return, iar
# un HashSet ajuns array de dimensiune fixa arunca la `.Add()`. Am incasat-o scriind testul.
function Get-Assigned([int]$a, [int]$b) {
    $s = @()
    for ($j = $a; $j -le $b -and $j -lt $lines.Count; $j++) {
        if ($lines[$j].TrimStart().StartsWith('#')) { continue }
        foreach ($m in [regex]::Matches($lines[$j], $asgPat)) { $s += $m.Groups[1].Value }
    }
    return ,($s | Sort-Object -Unique)
}
$inside  = @(Get-Assigned $st $en)
$outside = @(Get-Assigned 0 ($st - 1)) + @(Get-Assigned ($en + 1) ($lines.Count - 1)) | Sort-Object -Unique

$reads = @()
for ($j = $en + 1; $j -lt $lines.Count; $j++) {
    if ($lines[$j].TrimStart().StartsWith('#')) { continue }
    foreach ($m in [regex]::Matches($lines[$j], '\$([A-Za-z_][A-Za-z0-9_]*)')) { $reads += $m.Groups[1].Value }
}
$reads = $reads | Sort-Object -Unique
$orphans = @($inside | Where-Object { $reads -contains $_ -and $outside -notcontains $_ } | Sort-Object)
if ($orphans.Count -gt 0) { Write-Host ("  " + ($orphans -join ', ')) -ForegroundColor Yellow }
Assert-Eq 0 $orphans.Count "zero variabile calculate DOAR in blocul interactiv si citite dupa ($($orphans -join ', '))"

# ── 2. Cele 4 concrete sunt tratate pe calea de profil ───────────────
$txt = Get-Content $ENC -Raw
Assert-Eq $true ($txt -match '(?m)^if \(\$profLoaded\) \{') "exista blocul de completare pentru calea de profil"
foreach ($v in 'rtEncoder','tuneFlag','apvEncoder','pc2') {
    Assert-Eq $true ($txt -match "(?s)if \(\`$profLoaded\) \{.*?\`$$v\s*=") "calea de profil initializeaza `$$v"
}

# ── 3. `Resolve-VbrDefaults` — completarea maxrate/bufsize ───────────
# Schema accepta VBR_MAXRATE/VBR_BUFSIZE goale, iar dialogul le calculeaza; profilul nu.
# Rezultatul era `-maxrate  -bufsize ` → ffmpeg refuza optiunile encoderului → 0 octeti.
Import-AvEncodeFunctions -Names @('Resolve-VbrDefaults')
$r = Resolve-VbrDefaults -Mode "3" -Target "1500k" -Maxrate "" -Bufsize ""
Assert-Eq "2250k" $r.Maxrate "2-pass: maxrate = 1.5x tinta (ca in dialog)"
Assert-Eq "3000k" $r.Bufsize "2-pass: bufsize = 2x tinta (ca in dialog)"
$r = Resolve-VbrDefaults -Mode "2" -Target "4M" -Maxrate "" -Bufsize ""
Assert-Eq "6000k" $r.Maxrate "VBR 1-pass: unitatea M se converteste corect"
$r = Resolve-VbrDefaults -Mode "1" -Target "1500k" -Maxrate "" -Bufsize ""
Assert-Eq "" $r.Maxrate "pe CRF nu se completeaza nimic"
$r = Resolve-VbrDefaults -Mode "3" -Target "1500k" -Maxrate "9000k" -Bufsize "1000k"
Assert-Eq "9000k" $r.Maxrate "valorile date de utilizator NU se suprascriu"
Assert-Eq "1000k" $r.Bufsize "idem bufsize"
$r = Resolve-VbrDefaults -Mode "3" -Target "" -Maxrate "" -Bufsize ""
Assert-Eq "" $r.Maxrate "fara tinta nu se inventeaza nimic"
$r = Resolve-VbrDefaults -Mode "3" -Target "abc" -Maxrate "" -Bufsize ""
Assert-Eq "" $r.Maxrate "tinta invalida → nicio completare"

# ── 4. Modul VBR cere si o TINTA — paritate cu bash ──────────────────
# Schema accepta `VBR_TARGET` gol; un profil scris de mana poate avea ENCODE_MODE=2/3 fara ea.
# bash gardeaza de mult (`[[ "$ENCODE_MODE" == "2" && -n "$VBR_TARGET" ]]`) si cade grațios pe
# CRF; PS1 nu o facea → `-b:v ""` → ffmpeg refuza optiunile encoderului → 0 octeti.
Assert-Eq $true ($txt -match '\$vbrModeActive\s*=.*-and \$vbrTarget') `
    "modul VBR e activ DOAR cu tinta (paritate cu garda din bash)"
Assert-Eq $true ($txt -match '\$is2Pass\s*=\s*\(\$encMode -eq "3"\)\s*-and \$vbrTarget') `
    "`$is2Pass intra sub aceeasi garda (in bash `_is_2pass=1` sta INAUNTRUL ramurii)"

Invoke-TestSummary
