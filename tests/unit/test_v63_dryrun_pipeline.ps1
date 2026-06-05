# v63 — Dry-run pentru pipeline Trim+Concat (mirror al test_v63_dryrun_pipeline.sh).
#   Prompt mod la intrarea in pipeline + raport plan pe pass-uri, return inainte de orice ffmpeg/temp.
. "$PSScriptRoot\..\framework.ps1"

$ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$SRC  = Join-Path $ROOT 'src'
$ENC  = Get-Content (Join-Path $SRC "av_encode.ps1") -Raw
$TC   = Get-Content (Join-Path $SRC "av_trimconcat.sh") -Raw

# ── 1. PS1 — prompt mod + normalizare dryRun (calea TrimConcat nu trece prin $dryRun global) ──
Assert-Match $ENC ([regex]::Escape('$dryRun = [bool]$dryRun'))            "PS1 pipeline: normalizeaza dryRun"
Assert-Match $ENC 'Mod pipeline:'                                        "PS1 pipeline: prompt mod"
Assert-Match $ENC ([regex]::Escape('if ($plMode -eq "2") { $dryRun = $true }')) "PS1 pipeline: opt 2 activeaza dry-run"

# ── 2. PS1 — guard + raport plan pe pass-uri ──
Assert-Match $ENC ([regex]::Escape('if ($dryRun) {'))   "PS1 pipeline: guard dry-run"
Assert-Match $ENC 'DRY-RUN — plan executie'             "PS1 pipeline: titlu raport plan"
Assert-Match $ENC 'Pass 1/3: trim'                      "PS1 pipeline: breakdown Pass 1"
Assert-Match $ENC 'Pass 3/3:'                           "PS1 pipeline: breakdown Pass 3"

# ── 3. PS1 — guard INAINTE de executie (New-TempSubdir pipeline) ──
$encLines = (Get-Content (Join-Path $SRC "av_encode.ps1"))
$gPs = ($encLines | Select-String -SimpleMatch 'DRY-RUN — plan executie' | Select-Object -First 1).LineNumber
$ePs = ($encLines | Select-String -SimpleMatch 'New-TempSubdir "pipeline"' | Select-Object -First 1).LineNumber
Assert-Eq $true ($gPs -lt $ePs) "PS1 pipeline: guard ($gPs) inainte de Pass 1 exec ($ePs)"

# ── 4. Paritate bash — prompt mod + guard + raport ──
Assert-Match $TC ([regex]::Escape('local DRY_RUN="${DRY_RUN:-0}"'))  "bash pipeline: respecta DRY_RUN din env"
Assert-Match $TC 'Mod pipeline:'                                     "bash pipeline: prompt mod"
Assert-Match $TC 'DRY-RUN — plan executie'                           "bash pipeline: titlu raport plan"
Assert-Match $TC ([regex]::Escape('if [[ "$DRY_RUN" == "1" ]]; then')) "bash pipeline: guard dry-run"

Invoke-TestSummary
