# ═══════════════════════════════════════════════════════════════
#  _helpers.ps1 — extrage functii din av_encode.ps1 fara side-effects.
#  Utilizare in test:
#      . "$PSScriptRoot\..\_helpers.ps1"
#      Import-AvEncodeFunctions -Names @('Get-ProfileSchema','Test-ProfileFile')
#  Functiile sunt inregistrate in scope GLOBAL ca sa fie vizibile in test.
# ═══════════════════════════════════════════════════════════════

function Import-AvEncodeFunctions {
    param(
        [string[]]$Names,
        [string]$Path = $null
    )
    if (-not $Path) {
        $root = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
        $Path = Join-Path $root 'src\av_encode.ps1'
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "av_encode.ps1 negasit: $Path"
    }
    $errors = $null; $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors) { throw "Parse erori in $Path : $($errors[0].Message)" }
    $funcs = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    # v63: $PSScriptRoot e GOL intr-un scriptblock fara fisier (cum creeaza Set-Item de mai jos)
    # → functiile care-si localizeaza engine-ul Python prin Join-Path $PSScriptRoot (Test-DjiDLogM,
    # Repair-Av1DvT35) esueaza la AST import. Injectam directorul scriptului (src/) ca ele sa fie
    # testabile functional, nu doar source-level. Aditiv: o functie care NU foloseste $PSScriptRoot
    # primeste o variabila locala nefolosita (inofensiv); productia ramane neatinsa.
    $srcDir = Split-Path -Parent $Path
    $srcEsc = $srcDir.Replace("'", "''")
    foreach ($name in $Names) {
        $match = $funcs | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if (-not $match) { throw "Functie negasita in av_encode.ps1: $name" }
        # Extrage corpul intre primul { si ultimul } al definitiei functiei
        $fullText = $match.Extent.Text
        $openIdx  = $fullText.IndexOf('{')
        $closeIdx = $fullText.LastIndexOf('}')
        if ($openIdx -lt 0 -or $closeIdx -le $openIdx) { throw "Nu pot extrage body pentru $name" }
        $body = $fullText.Substring($openIdx + 1, $closeIdx - $openIdx - 1)
        # Injecteaza $PSScriptRoot DUPA param() (param trebuie sa fie prima instructiune din corp);
        # daca functia nu are param block, la inceputul corpului.
        $inject = "`n`$PSScriptRoot = '$srcEsc'`n"
        $pb = $match.Body.ParamBlock
        if ($pb) { $pbText = $pb.Extent.Text; $pi = $body.IndexOf($pbText) } else { $pi = -1 }
        if ($pi -ge 0) {
            $body = $body.Substring(0, $pi + $pbText.Length) + $inject + $body.Substring($pi + $pbText.Length)
        } else {
            $body = $inject + $body
        }
        Set-Item -Path "function:Global:$name" -Value ([scriptblock]::Create($body))
    }
}
