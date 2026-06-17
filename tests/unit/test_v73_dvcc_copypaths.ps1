# v73: dvcC pe caile de COPY din trimconcat + avertisment DV la telemetrie embed (T2).
#   Mirror PS1 al test_v73_dvcc_copypaths.sh. Source-level: wiring re-signal pe stream-copy
#   (Concat / Pipeline smart-copy / Pipeline audio-only, gardat sa NU prinda re-encode) +
#   telemetrie T2 = doar avertisment (av_telemetry.ps1 e standalone → fara Invoke-DvResignalCopy).
. "$PSScriptRoot\..\framework.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$ENC = Get-Content (Join-Path $ROOT "src\av_encode.ps1") -Raw
$TEL = Get-Content (Join-Path $ROOT "src\av_telemetry.ps1") -Raw

# ── 1. Concat stream-copy → re-signal (referinta compat = prima sursa) ──
Assert-Match $ENC ([regex]::Escape('Invoke-DvResignalCopy -Source $selected[0].FullName -Output $outPath -Target $ccExt')) "concat stream-copy: re-signal dvcC (selected[0])"

# ── 2. Pipeline → re-signal GARDAT pe smartCopy/audioOnly (NU re-encode) ──
Assert-Match $ENC ([regex]::Escape('if (($smartCopy -or $audioOnly) -and (Test-Path $outPath))')) "pipeline: re-signal gardat pe COPY (exclude re-encode)"
Assert-Match $ENC ([regex]::Escape('Invoke-DvResignalCopy -Source $chosen[0].FullName -Output $outPath -Target $plExt')) "pipeline copy: re-signal dvcC (chosen[0])"

# ── 3. Telemetrie T2: doar AVERTISMENT pe DV + output non-MKV (FARA re-signal) ──
Assert-Match $TEL ([regex]::Escape('$targetExt -ne "mkv"')) "telemetrie T2: gardat pe output non-MKV"
Assert-Match $TEL 'Sursa are Dolby Vision' "telemetrie T2: avertisment DV"
Assert-Eq $false ([bool]($TEL -match 'Invoke-DvResignalCopy')) "telemetrie T2: warn-only (NU apeleaza Invoke-DvResignalCopy)"

# ── 4. Concat/Pipeline re-encode DV: mesaj catre workflow-ul curat (encode per-clip -> concat copy) ──
Assert-Match $ENC ([regex]::Escape('uneste-le cu Concat stream-copy (dvcC se re-semnalizeaza automat)')) "re-encode DV: mesaj workflow curat (concat + pipeline)"

Invoke-TestSummary
