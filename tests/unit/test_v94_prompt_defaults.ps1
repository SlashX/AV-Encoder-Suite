# v94 (B16) — default-urile de prompt trebuie sa reziste la EOF.
#
# Idiomul „Enter = implicit" e `$x = Read-Host …; $v = switch ($x) { … default {…} }`.
# Cand stdin e epuizat (pipe / CI / mai puţine raspunsuri decat prompturi), `Read-Host`
# intoarce $null, iar `switch` peste acel $null NU executa `default` → variabila iese GOALA.
# Pe fluxul audio-only asta dadea container `""` → avertismente false („aac incompatibil cu
# containerul .") + encode ESUAT. Fix: coerciţie la string, `switch ("$x")`.
#
# Santinela verifica INVARIANTUL, nu siturile individuale: orice `= switch ($var)` unde
# `$var` primeste `Read-Host` in acelasi fisier e o regresie.
. "$PSScriptRoot\..\framework.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'

$files = @('av_encode.ps1','av_mux.ps1','av_check.ps1','av_burnin.ps1',
           'av_telemetry.ps1','av_extractor_gps.ps1')

$totalGuarded = 0
foreach ($fn in $files) {
    $p = Join-Path $SRC $fn
    if (-not (Test-Path $p)) { continue }
    $txt = Get-Content $p -Raw
    # Variabilele alimentate din Read-Host in ACEST fisier. Formele acoperite:
    #   $x = Read-Host …            $script:x = Read-Host …     $x = (Read-Host …).Trim()
    #   $x = [string](Read-Host …)
    # Azi codul foloseste doar prima forma (verificat: zero apariţii ale celorlalte), dar
    # regexul le prinde pe toate — altfel un `$script:x = Read-Host` adaugat maine ar face
    # santinela oarba TACUT, adica exact clasa „testul trece din motivul gresit" pe care
    # campania a intalnit-o de doua ori.
    $fed = [System.Collections.Generic.HashSet[string]]::new()
    $feedPat = '\$(?:script:|global:|local:|private:)?([A-Za-z0-9_]+)\s*=\s*(?:\[[A-Za-z.\[\]]+\]\s*)?\(?\s*Read-Host'
    foreach ($m in [regex]::Matches($txt, $feedPat)) {
        $fed.Add($m.Groups[1].Value) | Out-Null
    }
    if ($fed.Count -eq 0) { continue }

    $bare = @()      # switch ($var)  — vulnerabil la EOF
    $safe = 0        # switch ("$var") — protejat
    foreach ($line in ($txt -split "`n")) {
        $m = [regex]::Match($line, '=\s*switch\s*\(\s*(")?\$(?:script:|global:|local:|private:)?([A-Za-z0-9_]+)\1?\s*\)')
        if (-not $m.Success) { continue }
        $quoted = $m.Groups[1].Value -eq '"'
        $var    = $m.Groups[2].Value
        if (-not $fed.Contains($var)) { continue }
        if ($quoted) { $safe++ } else { $bare += "$var" }
    }
    Assert-Eq 0 $bare.Count "B16 ${fn}: zero `switch (`$var)` necitat pe rezultat de Read-Host ($($bare -join ', '))"
    $totalGuarded += $safe
}
# ancora: fixul acopera 22 de situri (20 av_encode + 2 av_mux)
Assert-Eq 22 $totalGuarded "B16: toate cele 22 de default-uri de prompt sunt protejate"

# ── Forma coercitata da default-ul pe TOATE intrarile „goale" ───────────
# NB: nu asertam ce face `switch ($null)` NEcoercitat — s-a dovedit dependent de context
# (izolat da `default`, in scriptul real a dat GOL), exact ambiguitatea din cauza careia
# coerciţia e obligatorie. Asertam doar ca forma coercitata e corecta pe toate intrarile.
$nullVar = $null
$rNull  = switch ("$nullVar") { "1" {"x"} default {"DEF"} }
$rEmpty = switch ("")         { "1" {"x"} default {"DEF"} }
$rReal  = switch ("1")        { "1" {"x"} default {"DEF"} }
Assert-Eq "DEF" $rNull  "B16: coercitia da default pe null (EOF)"
Assert-Eq "DEF" $rEmpty "B16: coercitia da default pe string gol (Enter)"
Assert-Eq "x"   $rReal  "B16: valorile normale neschimbate"

Invoke-TestSummary
