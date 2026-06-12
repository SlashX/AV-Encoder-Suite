# v69 — invariant PS1: NICIUN `continue` ne-etichetat in interiorul unui `switch`.
#   In PowerShell, `continue` intr-un switch iese DOAR din switch (nu sare iteratia
#   buclei) — confirmat empiric pe PS 5.1 + pwsh 7.x. Site-urile vechi
#   `"skip" { $totalSkipped++; continue }` / `"copy" { Invoke-StreamCopy...; continue }`
#   contorizau skip-ul dar ENCODAU fisierul oricum / suprascriau stream copy-ul cu
#   encode (10 situri reparate in v69: av_encode ×9, av_burnin ×1). Fix-ul corect:
#   flag + `if (...) { ...; continue }` DUPA switch (pattern $skipFile/$doStreamCopy).
#   PS1-only (bash `continue` in `case` continua corect bucla — semantici diferite).
. "$PSScriptRoot\..\framework.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'

# ── 1. Invariant AST pe TOATE scripturile de productie ──────────────
$loopTypes = @(
    [System.Management.Automation.Language.ForEachStatementAst],
    [System.Management.Automation.Language.ForStatementAst],
    [System.Management.Automation.Language.WhileStatementAst],
    [System.Management.Automation.Language.DoWhileStatementAst],
    [System.Management.Automation.Language.DoUntilStatementAst]
)
$violations = @()
$prodFiles = Get-ChildItem -Path $SRC -Recurse -Include *.ps1
foreach ($f in $prodFiles) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
    $stmts = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ContinueStatementAst] }, $true)
    foreach ($s in $stmts) {
        if ($s.Label) { continue }   # `continue <label>` e explicit — OK
        $node = $s.Parent
        while ($node) {
            if ($node -is [System.Management.Automation.Language.SwitchStatementAst]) {
                $violations += "$($f.Name):$($s.Extent.StartLineNumber)"
                break
            }
            $isLoop = $false
            foreach ($lt in $loopTypes) { if ($node -is $lt) { $isLoop = $true; break } }
            if ($isLoop) { break }
            $node = $node.Parent
        }
    }
}
Assert-Eq 0 $violations.Count "invariant: zero `continue` ne-etichetat in switch in src/*.ps1 ($($violations -join ', '))"

# ── 2. Fix-urile v69 prezente (consum prin flag dupa dialoguri) ─────
$ENC = Get-Content (Join-Path $SRC "av_encode.ps1") -Raw
$BURN = Get-Content (Join-Path $SRC "av_burnin.ps1") -Raw

# dialogurile reparate folosesc flag-urile per-file existente
Assert-Match $ENC ([regex]::Escape('switch ($hlgResultHw) {')) "av_encode: dialogul HW HLG exista"
$copyFlagCount = ([regex]::Matches($ENC, [regex]::Escape('"copy" { $doStreamCopy = $true }'))).Count
Assert-Eq $true ($copyFlagCount -ge 9) "av_encode: cazurile `"copy`" prin flag doStreamCopy (>=9, era 4 + 5 reparate; gasit: $copyFlagCount)"
$skipFlagCount = ([regex]::Matches($ENC, [regex]::Escape('"skip" { $skipFile = $true }'))).Count
Assert-Eq $true ($skipFlagCount -ge 4) "av_encode: cazurile `"skip`" prin flag skipFile (>=4 reparate; gasit: $skipFlagCount)"
# blocurile de consum dupa dialoguri (HW + x265) — minim 4 in total in fisier
$consumeCount = ([regex]::Matches($ENC, [regex]::Escape('if ($skipFile) { $totalSkipped++; continue }'))).Count
Assert-Eq $true ($consumeCount -ge 4) "av_encode: blocuri de consum skipFile (>=4; gasit: $consumeCount)"
Assert-Match $BURN ([regex]::Escape('if ($kindUnknown) { $failCount++; continue }')) "av_burnin: kind necunoscut prin flag + consum dupa switch"

# ── 3. Semantica de referinta (documenteaza bug-ul empiric) ─────────
$out = foreach ($x in 1..3) { switch ($x) { 2 { continue } }; "after$x" }
Assert-Eq "after1 after2 after3" ($out -join ' ') "semantica PS: continue-in-switch NU sare iteratia buclei (de-asta e interzis)"
$out2 = foreach ($x in 1..3) { if ($x -eq 2) { continue }; "after$x" }
Assert-Eq "after1 after3" ($out2 -join ' ') "semantica PS: continue in if sare corect iteratia (pattern-ul fix-ului)"

Invoke-TestSummary
