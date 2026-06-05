# v62 Faza B — DJI Osmo Action 6 D-Log M via djmd protobuf (.2.4.1==19).
#   Container raporteaza bt709 identic pt Normal SI D-Log M → discriminatorul sta
#   in protobuf-ul djmd. Engine partajat src/dji_djmd_dlogm.py (model-gate AC006).
. "$PSScriptRoot\..\framework.ps1"

$ROOT   = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$ENC    = Get-Content (Join-Path $ROOT "src\av_encode.ps1") -Raw
$CHK    = Get-Content (Join-Path $ROOT "src\av_check.ps1") -Raw
$ENGINE = Join-Path $ROOT "src\dji_djmd_dlogm.py"
$SRC    = Join-Path $ROOT "src"
# ffmpeg: global (PATH) sau bundle-uit in src/ (Windows testing) — pt sectiunea functionala
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { $env:PATH = "$SRC;$env:PATH" }

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

# ── 3. Functional — Test-DjiDLogM (av_encode) pe sample-uri reale, via AST ──
# v63: _helpers.ps1 injecteaza acum $PSScriptRoot (src/) la importul AST → Test-DjiDLogM din
# av_encode isi gaseste engine-ul si ruleaza functional (inainte: $PSScriptRoot gol → engine
# negasit → "unknown"; faceam doar hermetic + bash functional). Skip daca lipsesc ffmpeg/samples.
if ((Get-Command ffmpeg -ErrorAction SilentlyContinue) -and (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    . "$PSScriptRoot\..\_helpers.ps1"
    Import-AvEncodeFunctions -Names @('Test-DjiDLogM','_Get-AvPython') | Out-Null
    # $AV_TEMP_DIR e citit de Test-DjiDLogM (script-scope) — il setam la un temp izolat de test
    $AV_TEMP_DIR = Join-Path ([IO.Path]::GetTempPath()) ("v62b_enc_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $AV_TEMP_DIR | Out-Null
    $expDji = [ordered]@{
        'DJI_20260529221103_0009_D.MP4' = 'dlog_m'
        'DJI_20260603165715_0014_D.MP4' = 'dlog_m'
        'DJI_20260524143912_0007_D.MP4' = 'normal'
        'DJI_20260603165650_0013_D.MP4' = 'normal'
    }
    $ranDji = $false
    foreach ($s in $expDji.Keys) {
        $sp = Join-Path $SRC $s
        if (Test-Path $sp) { $ranDji = $true; Assert-Eq $expDji[$s] (Test-DjiDLogM $sp) "av_encode AST functional: $s -> $($expDji[$s])" }
    }
    if (-not $ranDji) { Write-Host "  (info: sample-uri DJI absente — sar functionalul av_encode)" }
    Remove-Item $AV_TEMP_DIR -Recurse -Force -ErrorAction SilentlyContinue
}
Invoke-TestSummary
