# v95 — nicio functie PowerShell din src/ nu are voie sa ramana fara apelanti.
#
# Oglinda lui test_v95_dead_code.sh, cu o diferenta de REGULA, nu de stil: scripturile .ps1
# din suita sunt STANDALONE prin design (nu se importa intre ele — vezi nota v58 despre
# copiile duplicate), deci „mort" se judeca PER FISIER. Un `Get-RemuxStreams` definit in
# av_encode.ps1 nu e tinut in viata de faptul ca av_mux.ps1 are unul cu acelasi nume — exact
# capcana care a produs O12: doua copii, una vie si una moarta, driftate intre ele, iar
# testele o validau pe cea moarta.
#
# Comentariile pe linie intreaga se scot inainte de numaratoare: `# Invoke-Remux — re-mux...`
# a facut o functie moarta sa para folosita la prima baleiere.
#
# Definitiile se cauta si INDENTAT: av_encode.ps1 are `Get-HwVuiBsf` si `Get-HwVuiBsfFromSource`
# definite in interiorul unui bloc. Sunt vii azi, dar o ancorare la coloana 0 le-ar lasa
# nescanate pe vecie — exact gaura pe care santinela asta exista ca s-o inchida.
. "$PSScriptRoot\..\framework.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'

function Get-DeadFunctions {
    param([string]$Dir)
    $dead = @()
    foreach ($f in (Get-ChildItem -Path $Dir -Filter *.ps1 -File | Sort-Object Name)) {
        $raw = Get-Content $f.FullName -Raw
        # doar liniile care INCEP cu # — nu si comentariile de la capat de linie, ca sa nu
        # ciuntim cod care contine `#` intr-un sir
        $body = ($raw -split "`n" | Where-Object { $_.TrimStart() -notmatch '^#' }) -join "`n"
        foreach ($m in [regex]::Matches($raw, '(?m)^[ \t]*function\s+([A-Za-z][A-Za-z0-9\-_]*)')) {
            $fn = $m.Groups[1].Value
            $uses = ([regex]::Matches($body, "(?<![A-Za-z0-9_-])$([regex]::Escape($fn))(?![A-Za-z0-9_-])")).Count
            if ($uses -le 1) { $dead += "$($f.Name):$fn" }
        }
    }
    return ,$dead
}

# ── 1. src/ e curat ──────────────────────────────────────────────────
$dead = Get-DeadFunctions -Dir $SRC
if ($dead.Count -gt 0) { Write-Host ("  " + ($dead -join "`n  ")) -ForegroundColor Yellow }
Assert-Eq 0 $dead.Count "zero functii PS1 fara apelanti in propriul fisier ($($dead -join ', '))"

# ── 1b. src/tools/ (installerele) — aceeasi regula, tot per fisier ───
$deadT = Get-DeadFunctions -Dir (Join-Path $SRC 'tools')
if ($deadT.Count -gt 0) { Write-Host ("  " + ($deadT -join "`n  ")) -ForegroundColor Yellow }
Assert-Eq 0 $deadT.Count "zero functii PS1 fara apelanti in src/tools/ ($($deadT -join ', '))"

# ── 1c. Definitiile INDENTATE chiar sunt scanate ─────────────────────
$encRaw = Get-Content (Join-Path $SRC 'av_encode.ps1') -Raw
$indented = [regex]::Matches($encRaw, '(?m)^[ \t]+function\s+([A-Za-z][A-Za-z0-9\-_]*)')
Assert-Nonzero $indented.Count "av_encode.ps1 chiar are functii indentate (altfel verificarea de mai jos e goala)"
$scanned = [regex]::Matches($encRaw, '(?m)^[ \t]*function\s+([A-Za-z][A-Za-z0-9\-_]*)')
Assert-Eq $true ($scanned.Count -ge $indented.Count) "tiparul de definitie le include si pe cele indentate"

# ── 2. Detectorul PRINDE o violare plantata ──────────────────────────
$plant = Join-Path ([System.IO.Path]::GetTempPath()) ("av_v95_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $plant | Out-Null
try {
    @'
function Invoke-Viu { "sunt chemat" }
function Invoke-Mort { "nimeni nu ma cheama" }
Invoke-Viu
'@ | Set-Content (Join-Path $plant 'a.ps1') -Encoding UTF8
    $pl = Get-DeadFunctions -Dir $plant
    Assert-Eq $true ($pl -contains 'a.ps1:Invoke-Mort') "detectorul prinde o functie fara apelanti"
    Assert-Eq $false ($pl -contains 'a.ps1:Invoke-Viu') "fara fals-pozitiv pe o functie chemata"

    # ── 3. REGULA per-fisier: acelasi nume in alt .ps1 NU tine functia in viata ──
    # (asta e chiar clasa O12 — copia moarta din av_encode.ps1 vs cea vie din av_mux.ps1)
    @'
function Invoke-Mort { "copie vie, in alt fisier" }
Invoke-Mort
'@ | Set-Content (Join-Path $plant 'b.ps1') -Encoding UTF8
    $pl2 = Get-DeadFunctions -Dir $plant
    Assert-Eq $true ($pl2 -contains 'a.ps1:Invoke-Mort') `
        "copia moarta ramane semnalata chiar daca alt fisier are una vie cu acelasi nume"
    Assert-Eq $false ($pl2 -contains 'b.ps1:Invoke-Mort') "copia VIE nu e semnalata"

    # ── 4. Comentariile NU tin o functie in viata ────────────────────
    @'
# Invoke-DoarInComentariu face ceva foarte util, candva
function Invoke-DoarInComentariu { "x" }
'@ | Set-Content (Join-Path $plant 'c.ps1') -Encoding UTF8
    $pl3 = Get-DeadFunctions -Dir $plant
    Assert-Eq $true ($pl3 -contains 'c.ps1:Invoke-DoarInComentariu') `
        "un nume aparut doar in comentariu NU conteaza ca apel"

    # ── 5. …si o functie INDENTATA fara apelanti e prinsa la fel ─────
    @'
if ($true) {
    function Invoke-MortIndentat { "definit intr-un bloc, chemat de nimeni" }
    function Invoke-ViuIndentat  { "x" }
}
Invoke-ViuIndentat
'@ | Set-Content (Join-Path $plant 'd.ps1') -Encoding UTF8
    $pl4 = Get-DeadFunctions -Dir $plant
    Assert-Eq $true  ($pl4 -contains 'd.ps1:Invoke-MortIndentat') "detectorul prinde si o functie INDENTATA fara apelanti"
    Assert-Eq $false ($pl4 -contains 'd.ps1:Invoke-ViuIndentat')  "fara fals-pozitiv pe o functie indentata chemata"
}
finally {
    Remove-Item -LiteralPath $plant -Recurse -Force -ErrorAction SilentlyContinue
}

Invoke-TestSummary
