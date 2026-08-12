# v96 — installerele PS1 nu au voie sa raporteze succes fara sa verifice ca binarul a ajuns
# la destinatie.
#
# Gasit la auditul pre-productie, ca oglinda a aceleiasi probleme de pe bash: toate cele patru
# installere faceau `Copy-Item ... -Force` si tipareau imediat "INSTALARE REUSITA!", fara sa se
# uite daca a mers. `$ErrorActionPreference` e implicit `Continue`, deci o copiere esuata (binar
# blocat de un proces care ruleaza, folder fara drepturi de scriere) scria eroarea si mergea mai
# departe la mesajul de succes. Ramura de eroare — exe negasit in arhiva / negasit dupa
# compilare — tiparea si ea doar un mesaj, fara sa schimbe codul de iesire, deci scriptul iesea
# cu 0 in toate cazurile.
#
# Contractul pazit: copiere gardata (`-ErrorAction Stop` + try/catch), succes anuntat DOAR dupa
# ce fisierul chiar exista la destinatie, si cod de iesire 1 pe orice esec — dupa curatenia
# temp-urilor, ca sa nu ramana gunoi in urma.
#
# Perechea bash a aceluiasi contract e in test_v96_installers.sh (unde se verifica in plus
# blocul de platforma Termux/Linux/macOS, care pe Windows nu exista).
. "$PSScriptRoot\..\framework.ps1"

$ROOT  = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$TOOLS = Join-Path $ROOT 'src\tools'

$installers = @(
    @{ File = 'dovi_parser.ps1';         Tool = 'AV_TOOL_DOVI' },
    @{ File = 'hdr10plus_parser.ps1';    Tool = 'AV_TOOL_HDR10PLUS' },
    @{ File = 'av1dovi_parser.ps1';      Tool = 'AV_TOOL_AV1DOVI' },
    @{ File = 'av1hdr10plus_parser.ps1'; Tool = 'AV_TOOL_AV1HDR10PLUS' }
)

foreach ($i in $installers) {
    $p = Join-Path $TOOLS $i.File
    Assert-Eq $true (Test-Path $p) "$($i.File) exista"
    $c = Get-Content $p -Raw

    # ── 1. sintaxa (un installer stricat nu ajuta pe nimeni) ─────────
    $err = $null; $tok = $null
    [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$tok, [ref]$err) | Out-Null
    Assert-Eq 0 $err.Count "$($i.File): parseaza fara erori"

    # ── 2. copierea e gardata, nu "best effort" ──────────────────────
    Assert-Eq $true ($c -match 'Copy-Item[^\r\n]*-ErrorAction Stop') `
        "$($i.File): Copy-Item ridica eroarea (fara asta, esecul trece neobservat)"
    Assert-Eq $true ($c -match '(?s)try\s*\{[^}]*Copy-Item.*?\}\s*catch') `
        "$($i.File): copierea e in try/catch"

    # ── 3. succesul se anunta DOAR dupa ce fisierul exista ───────────
    Assert-Eq $true ($c -match '\$InstallOk\s*=\s*\$false') "$($i.File): exista steagul de rezultat"
    Assert-Eq $true ($c -match 'Test-Path \$TargetPath[^\r\n]*\)\s*\{[\r\n]') `
        "$($i.File): verifica prezenta la destinatie inainte de a declara succes"
    # mesajul de succes nu are voie sa fie pe o ramura care se atinge si cand copierea a esuat
    # NB: cautam linia care CHIAR tipareste, nu textul — comentariul care explica bug-ul
    # contine si el sirul "INSTALARE REUSITA" si ar da un fals-negativ.
    $idxOk   = $c.IndexOf('$InstallOk = $true')
    $idxSucc = $c.IndexOf('Write-Host "INSTALARE REUSITA!"')
    Assert-Eq $true (($idxOk -ge 0) -and ($idxSucc -gt $idxOk)) `
        "$($i.File): 'INSTALARE REUSITA' vine DUPA confirmarea instalarii"

    # ── 4. codul de iesire spune adevarul ────────────────────────────
    Assert-Eq $true ($c -match 'if \(-not \$InstallOk\) \{ exit 1 \}') `
        "$($i.File): iese cu 1 cand nu s-a instalat nimic"
    # ...si o face DUPA curatenie, ca sa nu ramana temp-uri in urma
    $idxExit = $c.IndexOf('if (-not $InstallOk) { exit 1 }')
    if ($c -match 'Remove-Item \$TempZipPath') {
        $idxClean = $c.IndexOf('Remove-Item $TempZipPath')
        Assert-Eq $true ($idxExit -gt $idxClean) "$($i.File): iese dupa curatenia temp-urilor"
    } else {
        _pass  # installerele care compileaza din sursa nu au arhiva temporara
    }

    # ── 5. numele uneltei apare in indrumarea de recuperare ──────────
    Assert-Eq $true ($c -match [regex]::Escape($i.Tool)) `
        "$($i.File): mesajul de esec spune ce variabila poate seta utilizatorul"
}

Invoke-TestSummary
