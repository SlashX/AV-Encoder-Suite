# Test Get-TelemetryBrand din av_telemetry.ps1 — fallback pentru SDR plain.
. "$PSScriptRoot\..\framework.ps1"

if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) { Skip-Test "ffprobe nu este in PATH" }

$root = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
$sdr = Join-Path $root 'tests\fixtures\samples\sdr_320p.mp4'
if (-not (Test-Path -LiteralPath $sdr)) { Skip-Test "sdr_320p.mp4 lipseste" }

# Extrage doar functia Get-TelemetryBrand din av_telemetry.ps1
$telPath = Join-Path $root 'src\av_telemetry.ps1'
Assert-FileExists $telPath 'av_telemetry.ps1 exista'

$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($telPath, [ref]$tokens, [ref]$errors)
$funcs = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
# v94: importam SI dependentele TRANZITIVE. `Get-TelemetryBrand` cheama intern
# `Get-ExifCmd`; fara ea functia arunca „is not recognized", intoarce GOL — iar aserţiunea
# de mai jos accepta gol, deci testul trecea DIN MOTIVUL GRESIT (ar fi trecut si daca
# Get-TelemetryBrand era complet rupta). Aceeasi clasa ca `Get-CanonicalPath` la v63.
# Prins de garda noua de no-op PARTIAL din runner (v94).
foreach ($fnName in 'Get-ExifCmd', 'Get-TelemetryBrand') {
    $fn = $funcs | Where-Object { $_.Name -eq $fnName } | Select-Object -First 1
    if (-not $fn) { Skip-Test "$fnName negasit in av_telemetry.ps1" }
    $fullText = $fn.Extent.Text
    $openIdx  = $fullText.IndexOf('{')
    $closeIdx = $fullText.LastIndexOf('}')
    $body     = $fullText.Substring($openIdx + 1, $closeIdx - $openIdx - 1)
    # $PSScriptRoot e GOL intr-un scriptblock fara fisier → Get-ExifCmd nu si-ar gasi
    # binarul co-locat (regula v63, aceeasi injectie ca in _helpers.ps1). ATENTIE:
    # `param()` TREBUIE sa ramana prima instructiune → injectam DUPA el, nu inainte.
    $inject = "`$PSScriptRoot = '$((Split-Path -Parent $telPath) -replace "'","''")'"
    $pm = [regex]::Match($body, '(?s)^\s*param\s*\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)')
    if ($pm.Success) { $body = $body.Insert($pm.Index + $pm.Length, "`n$inject") }
    else             { $body = "$inject`n$body" }
    Set-Item -Path "function:Global:$fnName" -Value ([scriptblock]::Create($body))
}

$brand = Get-TelemetryBrand -File $sdr
# SDR sintetic nu are tracks DJI/GoPro/Sony/Garmin → asteptam empty/quicktime/unknown
Assert-Match "$brand" '^(|quicktime|unknown)$' "SDR plain → fallback brand"
# ...si dovada ca functia chiar A RULAT (nu a aruncat): dependenta e rezolvabila
Assert-Eq $true ([bool](Get-Command Get-ExifCmd -ErrorAction SilentlyContinue)) `
    "dependenta tranzitiva Get-ExifCmd e importata (altfel brand-ul iese gol din EROARE)"

Invoke-TestSummary
