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
$brandFn = $funcs | Where-Object { $_.Name -eq 'Get-TelemetryBrand' } | Select-Object -First 1
if (-not $brandFn) { Skip-Test "Get-TelemetryBrand negasit in av_telemetry.ps1" }

# Inregistreaza in scope global
$fullText = $brandFn.Extent.Text
$openIdx  = $fullText.IndexOf('{')
$closeIdx = $fullText.LastIndexOf('}')
$body = $fullText.Substring($openIdx + 1, $closeIdx - $openIdx - 1)
Set-Item -Path "function:Global:Get-TelemetryBrand" -Value ([scriptblock]::Create($body))

$brand = Get-TelemetryBrand -File $sdr
# SDR sintetic nu are tracks DJI/GoPro/Sony/Garmin → asteptam empty/quicktime/unknown
Assert-Match "$brand" '^(|quicktime|unknown)$' "SDR plain → fallback brand"

Invoke-TestSummary
