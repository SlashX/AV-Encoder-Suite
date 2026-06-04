# v62 Faza B — DJI Osmo Action 6 D-Log M via djmd protobuf (.2.4.1==19).
#   Container raporteaza bt709 identic pt Normal SI D-Log M → discriminatorul sta
#   in protobuf-ul djmd. Engine partajat src/dji_djmd_dlogm.py (model-gate AC006).
. "$PSScriptRoot\..\framework.ps1"

$ROOT   = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$ENC    = Get-Content (Join-Path $ROOT "src\av_encode.ps1") -Raw
$CHK    = Get-Content (Join-Path $ROOT "src\av_check.ps1") -Raw
$ENGINE = Join-Path $ROOT "src\dji_djmd_dlogm.py"

# ── 1. Helper + integrare prezente (av_encode + av_check) ──
Assert-Match $ENC 'function Test-DjiDLogM'  "av_encode.ps1: Test-DjiDLogM definit"
Assert-Match $CHK 'function Test-DjiDLogM'  "av_check.ps1: Test-DjiDLogM definit (copie standalone)"
Assert-Nonzero ([int](Test-Path $ENGINE))   "engine dji_djmd_dlogm.py exista"
$gse = [regex]::Match($ENC, 'function Get-SourceInfoExtended.*?\n}', 'Singleline').Value
Assert-Match $gse 'Test-DjiDLogM'           "Get-SourceInfoExtended: sondeaza djmd pe DJI bt709"
$glp = [regex]::Match($CHK, 'function Get-LogProfile.*?\n}', 'Singleline').Value
Assert-Match $glp 'Test-DjiDLogM'           "av_check Get-LogProfile: sondeaza djmd"

# ── 2. Engine hermetic — protobuf sintetic (fara ffmpeg/sample) ──
$py = $null
if (Get-Command python3 -ErrorAction SilentlyContinue) { $py = "python3" }
elseif ((Get-Command python -ErrorAction SilentlyContinue) -and ((& python --version 2>&1) -match "3\.")) { $py = "python" }
if (-not $py) { Skip-Test "Python 3 indisponibil" }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("v62b_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$gate = [Text.Encoding]::ASCII.GetBytes("dvtm_ac206.proto")
# field2{ field4{ field1=VAL } } = 12 04 22 02 08 <val>
function _blob([byte[]]$b, [string]$name) { $p=Join-Path $tmp $name; [IO.File]::WriteAllBytes($p,$b); $p }
$dlog     = _blob ($gate + [byte[]](0x12,0x04,0x22,0x02,0x08,0x13)) "dlog.bin"      # .2.4.1=19
$normal   = _blob ($gate + [byte[]](0x12,0x04,0x22,0x02,0x08,0x05)) "normal.bin"    # .2.4.1=5
$gateOnly = _blob $gate "gate_only.bin"                                              # gate, fara path
$noGate   = _blob ([Text.Encoding]::ASCII.GetBytes("no_gate") + [byte[]](0x12,0x04,0x22,0x02,0x08,0x13)) "nogate.bin"
$empty    = _blob ([byte[]]@()) "empty.bin"

Assert-Eq "dlog_m"  (& $py $ENGINE $dlog     | Select-Object -First 1) "engine: .2.4.1=19 → dlog_m"
Assert-Eq "normal"  (& $py $ENGINE $normal   | Select-Object -First 1) "engine: .2.4.1=5 (≠19) → normal"
Assert-Eq "normal"  (& $py $ENGINE $gateOnly | Select-Object -First 1) "engine: gate fara path → normal"
Assert-Eq "unknown" (& $py $ENGINE $noGate   | Select-Object -First 1) "engine: fara model-gate → unknown"
Assert-Eq "unknown" (& $py $ENGINE $empty    | Select-Object -First 1) "engine: dump gol → unknown"
Assert-Eq "unknown" (& $py $ENGINE (Join-Path $tmp "nonexistent") | Select-Object -First 1) "engine: fisier lipsa → unknown"
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

# Nota: validarea PS1 end-to-end pe sample-uri reale (ffprobe+ffmpeg+engine prin
# Test-DjiDLogM) se face prin rularea av_check.ps1; aici nu importam functia prin AST
# (PSScriptRoot ar pointa la folderul testului, nu la src/ → engine negasit). Engine-ul
# e partajat cu bash, iar test_v62_dji_dlogm.sh il valideaza functional pe sample-uri reale.
Invoke-TestSummary
