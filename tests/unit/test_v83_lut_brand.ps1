# v83 — LUT brand-aware ordering (PS1 mirror al test_v83_lut_brand.sh).
#   Find-LutForBrand (av_encode.ps1) + Get-BurninLutFiles (av_burnin.ps1) recunosc
#   NUME REALE (AppleLog*/Samsung*Log*/*D-LogM*) → brand primele, lista completa ramane.
#   Get-BurninLutFiles: valideaza FIX-ul de paritate (inainte intorcea GOL pe nume reale).
. "$PSScriptRoot\..\framework.ps1"
$PROJECT_ROOT = if ($env:PROJECT_ROOT) { $env:PROJECT_ROOT } else { (Resolve-Path "$PSScriptRoot\..\..").Path }
$src = Join-Path $PROJECT_ROOT 'src'

# Luts temp cu numele REALE
$g  = [guid]::NewGuid().ToString('N').Substring(0,8)
$td = Join-Path $env:TEMP "lut_v83_$g"
New-Item -ItemType Directory -Force (Join-Path $td 'Luts') | Out-Null
foreach ($n in @('AppleLogToRec709-v1.0.cube','AppleLog2ToRec709-v1.0.cube',
                 'DJI OSMO Action 6 D-LogM to Rec.709 LUT-11.17.cube',
                 'Samsung+Log+to+Rec709+3DLUT_v1.0.cube','MyCreativeFilm.cube')) {
    New-Item -ItemType File -Force (Join-Path (Join-Path $td 'Luts') $n) | Out-Null
}

# ── Find-LutForBrand (AST import, -inputDir = temp) ──────────────────
. "$PROJECT_ROOT\tests\_helpers.ps1"
Import-AvEncodeFunctions -Names @('Find-LutForBrand') | Out-Null

$a = Find-LutForBrand -brand 'apple' -inputDir $td -scriptDir $src
Assert-Eq 2 $a.brandCount                        "apple: 2 brand-matched (nume reale)"
Assert-Eq 5 $a.files.Count                        "apple: lista COMPLETA pastrata"
Assert-Match $a.files[0].Name '^Apple'            "apple: [0] e LUT Apple (default)"
Assert-Match $a.files[1].Name '^Apple'            "apple: [1] e LUT Apple"

$d = Find-LutForBrand -brand 'dji' -inputDir $td -scriptDir $src
Assert-Eq 1 $d.brandCount                         "dji: 1 brand-matched (D-LogM)"
Assert-Match $d.files[0].Name '^DJI'              "dji: [0] e LUT DJI"

$s = Find-LutForBrand -brand 'samsung' -inputDir $td -scriptDir $src
Assert-Eq 1 $s.brandCount                         "samsung: 1 brand-matched"
Assert-Match $s.files[0].Name '^Samsung'          "samsung: [0] e LUT Samsung"

$u = Find-LutForBrand -brand 'unknown' -inputDir $td -scriptDir $src
Assert-Eq 0 $u.brandCount                         "unknown: 0 brand-matched"
Assert-Eq 5 $u.files.Count                        "unknown: toate .cube (fallback v62)"

# ── Get-BurninLutFiles (dot-source burn-in, ScriptDir → temp) ────────
$env:AV_BURNIN_TEST_MODE = "1"
try { . "$src\av_burnin.ps1" } catch { Write-Host "WARN dot-source: $($_.Exception.Message)" -ForegroundColor Yellow }
$env:AV_BURNIN_TEST_MODE = $null
$ScriptDir = $td   # override → cauta in Luts-ul temp
$ba = @(Get-BurninLutFiles -Brand 'apple')
Assert-Eq 5 $ba.Count                             "burn apple: 5 (FIX fallback — inainte GOL pe nume reale)"
Assert-Match ([IO.Path]::GetFileName($ba[0])) '^Apple' "burn apple: [0] e LUT Apple"
$bu = @(Get-BurninLutFiles -Brand 'unknown')
Assert-Eq 5 $bu.Count                             "burn unknown: toate .cube"

# ── source-level paritate ────────────────────────────────────────────
$bsh = Get-Content (Join-Path $src 'av_common.sh') -Raw
Assert-Eq $true ($bsh.Contains('LUT_BRAND_COUNT'))   "bash: LUT_BRAND_COUNT expus"
Assert-Eq $true ($bsh.Contains('potrivit brand'))    "bash: marker brand in dialog"

Remove-Item $td -Recurse -Force -ErrorAction SilentlyContinue
Invoke-TestSummary
